import CoreBluetooth
import Flutter
import Foundation
import Herald
import os.log

/// Runs the proximity source (Herald's BLE stack or the mock source) and
/// streams sightings to Flutter. iOS counterpart of ProximityService.
///
/// The Herald SensorArray is created once and reused across stop/start.
/// Rebuilding it doesn't work: Herald's CoreBluetooth managers use fixed
/// restore identifiers and iOS won't allow two of those alive at once, and
/// Herald's stop() can skip teardown depending on where its scan/advertise
/// cycle happens to be. Peers that are already connected also stay
/// connected, so "stopped" has to be said in the protocol itself: stop
/// flags our payload offline and sends a goodbye frame to connected peers,
/// start sends a hello. See StatusPayloadSupplier for the frame format.
final class ProximityController: NSObject, SensorDelegate, FlutterStreamHandler {

  static let shared = ProximityController()

  /// How often peers re-read our payload. Caps how stale a cached payload
  /// can be if a goodbye/hello frame gets lost. 15s is fine for a demo.
  private static let payloadRefreshSeconds: Foundation.TimeInterval = 15

  /// Gives the goodbye frame a moment to reach peers before we stop.
  private static let goodbyeFlushSeconds: Foundation.TimeInterval = 0.3

  private enum SourceMode {
    case idle
    case ble
    case mock
  }

  private(set) var payloadSupplier: StatusPayloadSupplier?
  let distanceEstimator = DistanceEstimator()

  /// The Herald host, kept for the life of the process. Only a session id
  /// change rebuilds it.
  private var sensorArray: SensorArray?
  private var bleHostSessionId: String?

  private var mockSource: MockPeerSource?
  private var sourceMode: SourceMode = .idle
  private var pendingQuiesce: DispatchWorkItem?

  // Herald calls us on its own queues, and Flutter sinks are main-thread
  // only and can be detached by onCancel at any time. So: read the sink
  // under the lock, then hop to the main queue.
  private var eventSink: FlutterEventSink?
  private let sinkLock = NSLock()

  private override init() {
    super.init()
  }

  private var isSourceRunning: Bool {
    sourceMode != .idle
  }

  // MARK: - Lifecycle (driven by method calls from Dart)

  func start(peerId: Int, sessionId: String, mock: Bool) {
    // Cancel any pending stop; a quick restart keeps the host running.
    pendingQuiesce?.cancel()
    pendingQuiesce = nil
    mockSource?.stop()
    mockSource = nil
    distanceEstimator.clear()

    if mock {
      // A cancelled stop may have left the host running, so always quiesce.
      // No-op when there's no host.
      quiesceBleHost()
      startMockSource()
    } else {
      startOrResumeBleHost(sessionId: sessionId, peerId: peerId)
    }
  }

  func stop() {
    pendingQuiesce?.cancel()
    pendingQuiesce = nil
    mockSource?.stop()
    mockSource = nil
    // Flip the mode first so anything Herald still delivers gets ignored.
    sourceMode = .idle
    distanceEstimator.clear()
    // Host may still be running even if the current source was mock/idle.
    quiesceBleHost()
    // Host and supplier stay around: the supplier serves the offline
    // payload to lingering connections, and the host is reused next start.
  }

  // MARK: - BLE host

  private func startOrResumeBleHost(sessionId: String, peerId: Int) {
    // Host already exists for this session, just turn it back on.
    if let host = sensorArray, bleHostSessionId == sessionId,
      let supplier = payloadSupplier
    {
      supplier.updatePeerId(peerId)
      supplier.setOffline(false)
      sourceMode = .ble
      host.start()
      // Tell connected peers we're back, otherwise they'd keep our cached
      // offline payload until their next re-read.
      if let frame = supplier.currentFrame() {
        _ = host.immediateSendAll(data: frame)
      }
      sendReady()
      return
    }

    // A different session id means a different service UUID, so the host
    // has to be rebuilt. The demo's fixed session id never hits this.
    if let host = sensorArray {
      os_log("Session id changed; rebuilding BLE host", type: .info)
      host.stop()
      sensorArray = nil
      bleHostSessionId = nil
      payloadSupplier = nil
    }

    // The session UUID doubles as the BLE service UUID, so only devices on
    // the same session find each other. Herald's standard service is off to
    // keep us isolated from other Herald apps.
    BLESensorConfiguration.payloadDataUpdateTimeInterval = Self.payloadRefreshSeconds
    BLESensorConfiguration.customServiceUUID = CBUUID(string: sessionId)
    BLESensorConfiguration.customServiceDetectionEnabled = true
    BLESensorConfiguration.customServiceAdvertisingEnabled = true
    BLESensorConfiguration.standardHeraldServiceDetectionEnabled = false
    BLESensorConfiguration.standardHeraldServiceAdvertisingEnabled = false
    BLESensorConfiguration.logLevel = .off
    BLESensorConfiguration.mobilitySensorEnabled = nil

    let supplier = StatusPayloadSupplier(peerId: peerId)
    let host = SensorArray(supplier)
    host.add(delegate: self)
    payloadSupplier = supplier
    sensorArray = host
    bleHostSessionId = sessionId
    sourceMode = .ble
    host.start()
    sendReady()
  }

  /// Flags us offline, pushes a goodbye to connected peers, then stops the
  /// host once the write has had time to land.
  private func quiesceBleHost() {
    guard let host = sensorArray else { return }

    payloadSupplier?.setOffline(true)
    if let frame = payloadSupplier?.currentFrame() {
      _ = host.immediateSendAll(data: frame)
    }

    let work = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      self.pendingQuiesce = nil
      // A start raced in during the flush window, leave the host up.
      guard self.sourceMode != .ble else { return }
      host.stop()
    }
    pendingQuiesce = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.goodbyeFlushSeconds, execute: work)
  }

  private func startMockSource() {
    let source = MockPeerSource { [weak self] peerId, status, color, deviceKind, rssi in
      self?.handleSighting(
        peerId: peerId, status: status, color: color, deviceKind: deviceKind, rssi: rssi)
    }
    mockSource = source
    sourceMode = .mock
    source.start()
    sendReady()
  }

  // MARK: - Herald SensorDelegate
  // Herald reports through overloads of sensor(). We only care about the
  // ones that carry a payload.

  func sensor(_ sensor: SensorType, didDetect: TargetIdentifier) {
    // Advertisement seen, payload not read yet.
  }

  func sensor(_ sensor: SensorType, didRead: PayloadData, fromTarget: TargetIdentifier) {
    // Payload read over GATT, no fresh RSSI in this callback.
    handlePayload(didRead.data, proximity: nil)
  }

  func sensor(_ sensor: SensorType, didReceive: Data, fromTarget: TargetIdentifier) {
    // Goodbye/hello frames. Same 16-byte payload, same pipeline.
    handlePayload(didReceive, proximity: nil)
  }

  func sensor(_ sensor: SensorType, didMeasure: Proximity, fromTarget: TargetIdentifier) {
    // RSSI without payload: we cannot attribute it to a peer id yet.
  }

  func sensor(_ sensor: SensorType, didVisit: Location?) {
    // Location sensing is not enabled.
  }

  func sensor(_ sensor: SensorType, didShare: [PayloadData], fromTarget: TargetIdentifier) {
    // Payloads relayed by another peer (helps with iOS background limits).
    for payload in didShare {
      handlePayload(payload.data, proximity: nil)
    }
  }

  func sensor(
    _ sensor: SensorType, didMeasure: Proximity, fromTarget: TargetIdentifier,
    withPayload: PayloadData
  ) {
    // The main callback: payload and RSSI together.
    handlePayload(withPayload.data, proximity: didMeasure)
  }

  func sensor(_ sensor: SensorType, didUpdateState: SensorState) {
    // Bluetooth state changes. Could be surfaced to the UI if wanted.
  }

  // MARK: - Sighting pipeline

  private func handlePayload(_ data: Data, proximity: Proximity?) {
    // Ignore anything from connections that outlived a stop.
    guard sourceMode == .ble else { return }
    guard let peerId = StatusPayloadSupplier.peerId(from: data),
      let status = StatusPayloadSupplier.status(from: data),
      let color = StatusPayloadSupplier.color(from: data),
      let deviceKind = StatusPayloadSupplier.deviceKind(from: data),
      let offline = StatusPayloadSupplier.isOffline(from: data)
    else {
      os_log("Dropping malformed payload (%d bytes)", type: .info, data.count)
      return
    }

    if offline {
      // Peer said goodbye (or we read its cached offline payload).
      emitGone(peerId: peerId)
      return
    }
    handleSighting(
      peerId: peerId, status: status, color: color, deviceKind: deviceKind,
      rssi: proximity?.value)
  }

  /// Common path for BLE and mock sightings.
  private func handleSighting(
    peerId: Int, status: Int, color: Int, deviceKind: Int, rssi: Double?
  ) {
    guard sourceMode != .idle else { return }
    var distance: Double?
    if let rssi = rssi {
      distance = distanceEstimator.addSample(
        peerId: peerId, rssi: rssi, senderDeviceKind: deviceKind)
    }

    var event: [String: Any] = [
      "type": "peer",
      "id": peerId,
      "status": status,
      "color": color,
      "device": deviceKind,
    ]
    if let rssi = rssi { event["rssi"] = rssi }
    if let distance = distance { event["distance"] = distance }

    emit(event)
  }

  private func emitGone(peerId: Int) {
    // Free the distance model now rather than waiting for Dart's forgetPeer.
    distanceEstimator.forget(peerId: peerId)
    emit(["type": "gone", "id": peerId])
  }

  private func sendReady() {
    emit(["type": "ready"])
  }

  private func emit(_ event: [String: Any]) {
    sinkLock.lock()
    let sink = eventSink
    sinkLock.unlock()
    guard let sink = sink else { return }
    // Flutter wants sink calls on the main thread.
    DispatchQueue.main.async {
      sink(event)
    }
  }

  // MARK: - FlutterStreamHandler

  func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    sinkLock.lock()
    eventSink = events
    sinkLock.unlock()
    // If the source was already running when Dart subscribed, the original
    // ready event went nowhere. Send it again.
    if isSourceRunning {
      sendReady()
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sinkLock.lock()
    eventSink = nil
    sinkLock.unlock()
    return nil
  }
}
