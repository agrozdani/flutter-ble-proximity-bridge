import CoreBluetooth
import Flutter
import Foundation
import Herald

/// Runs the proximity source (Herald's BLE stack or the mock source) and
/// streams sightings to Flutter. iOS counterpart of ProximityService.
///
/// The Herald SensorArray is created once and reused across stop/start.
/// Rebuilding it doesn't work reliably: Herald's CoreBluetooth managers use
/// fixed restore identifiers, so a new stack would race the old one, and
/// Herald's receiver stop() skips its cleanup entirely if scanning wasn't
/// active at that moment. Even a clean stop leaves peers that are connected
/// to us connected, and our stopped stack keeps answering their payload
/// reads, so "stopped" has to be said in the protocol itself: stop flags our
/// payload offline and sends a goodbye frame to the peers we're connected
/// to, start sends a hello. See StatusPayloadSupplier for the frame format.
final class ProximityController: NSObject, FlutterStreamHandler {

  static let shared = ProximityController()

  /// How often we re-read a peer's payload. Every install uses the same
  /// value, so it also caps how stale our payload can be on a connected
  /// peer if a goodbye/hello frame gets lost. 15s is fine for a demo.
  private static let payloadRefreshSeconds: Foundation.TimeInterval = 15

  /// Gives the goodbye frame a moment to reach peers before we stop.
  private static let goodbyeFlushSeconds: Foundation.TimeInterval = 0.3

  /// How long a hello, or a goodbye from an Android device, outvotes the
  /// payload Herald has cached for that peer. After a hello, the next re-read
  /// replaces the cached copy within one refresh interval; two leave room for
  /// a slow one. A stopped Android device can't be re-read at all, so its
  /// goodbye simply runs out.
  private static let frameOverrideSeconds = 2 * payloadRefreshSeconds

  /// The same for a goodbye from an iPhone, which stops advertising
  /// `goodbyeFlushSeconds` after sending it; see FrameOverrides. 5 s covers
  /// that, one keep-alive notification Herald may already have scheduled
  /// (it sends them 2 s apart), and slack.
  private static let iphoneGoodbyeOverrideSeconds: Foundation.TimeInterval = 5

  /// How long the newest payload revision a peer sent us is remembered after
  /// it last arrived in a frame or a read; cached copies don't count (see
  /// FrameOverrides). Long enough to outlast stale relays between our
  /// re-reads. A 7-bit revision can only be misread as older if the peer
  /// changed its payload more than 64 times between two such arrivals, which
  /// are at most this far apart while it is remembered. Here the payload only
  /// changes on user actions (a status or color change; a stop/start is two
  /// changes); an app that changes it faster has to stay below that rate.
  private static let revisionMemorySeconds: Foundation.TimeInterval = 60

  /// How often the bridge's state is summarized in the log (native.stats).
  private static let statsIntervalSeconds = 15

  private enum SourceMode {
    case idle
    case ble
    case mock
  }

  private(set) var payloadSupplier: StatusPayloadSupplier?
  let distanceEstimator = DistanceEstimator()
  private let frameOverrides = FrameOverrides(
    ttlSeconds: frameOverrideSeconds, iphoneGoodbyeTtlSeconds: iphoneGoodbyeOverrideSeconds,
    revisionMemorySeconds: revisionMemorySeconds)

  /// Herald's delegate: turns its payload callbacks into sightings. Lazy only
  /// because the closures capture self; it is first used on the main thread
  /// when the host is built, before Herald can call it.
  private lazy var payloadPipeline = PayloadPipeline(
    frameOverrides: frameOverrides,
    isActive: { [weak self] in self?.sourceMode == .ble },
    localPeerId: { [weak self] in self?.localPeerId },
    onSighting: { [weak self] peerId, status, color, deviceKind, rssi in
      self?.handleSighting(
        peerId: peerId, status: status, color: color, deviceKind: deviceKind, rssi: rssi)
    },
    onGone: { [weak self] peerId in self?.emitGone(peerId: peerId) })

  /// The Herald host, kept for the life of the process. Only a session id
  /// change rebuilds it.
  private var sensorArray: SensorArray?
  private var bleHostSessionId: String?

  private var mockSource: MockPeerSource?
  private var pendingQuiesce: DispatchWorkItem?

  // Written on the main thread, read from Herald's callback queues, so
  // access goes through a lock — same discipline as the event sink.
  private let stateLock = NSLock()
  private var _sourceMode: SourceMode = .idle
  private var sourceMode: SourceMode {
    get {
      stateLock.lock()
      defer { stateLock.unlock() }
      return _sourceMode
    }
    set {
      stateLock.lock()
      defer { stateLock.unlock() }
      _sourceMode = newValue
    }
  }

  // The id we broadcast as, for recognizing our own payload when a relay
  // hands it back. Same threading as sourceMode: `payloadSupplier` itself is
  // main-thread-only and must not be touched from Herald's queues.
  private var _localPeerId: Int?
  private var localPeerId: Int? {
    get {
      stateLock.lock()
      defer { stateLock.unlock() }
      return _localPeerId
    }
    set {
      stateLock.lock()
      defer { stateLock.unlock() }
      _localPeerId = newValue
    }
  }

  // Herald calls us on its own queues, and Flutter sinks are main-thread
  // only and can be detached by onCancel at any time. So: hop to the main
  // queue, then read the sink under the lock right before invoking it.
  private var eventSink: FlutterEventSink?
  private let sinkLock = NSLock()

  // What went to Dart, for the stats line; main thread only. "nosink"
  // counts events dropped because Dart was not listening.
  private var emitted: [(kind: String, count: Int)] = []
  private var emittedTotals: [String: Int] = [:]
  private var droppedWithoutSink = 0
  private var statsTimer: DispatchSourceTimer?

  private override init() {
    super.init()
    // A dispatch timer, not a Timer: it also fires while a scroll view is
    // tracking a touch.
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(
      deadline: .now() + .seconds(Self.statsIntervalSeconds),
      repeating: .seconds(Self.statsIntervalSeconds))
    timer.setEventHandler { [weak self] in self?.logStats() }
    timer.resume()
    statsTimer = timer
  }

  /// True while a source (BLE or mock) is logically running.
  var isRunning: Bool {
    sourceMode != .idle
  }

  // MARK: - Lifecycle (driven by method calls from Dart)

  func start(peerId: Int, sessionId: String, mock: Bool) {
    BridgeLog.i(
      "controller",
      "start mock=\(mock) session=\(sessionId) self=\(peerHex(peerId)) was=\(sourceMode)"
        + (pendingQuiesce != nil ? " (cancels the pending host stop)" : ""))
    if !mock { BridgeLog.i("ble", "authorization \(BridgeLog.bluetoothAuthorization())") }
    // Cancel any pending stop; a quick restart keeps the host running.
    pendingQuiesce?.cancel()
    pendingQuiesce = nil
    mockSource?.stop()
    mockSource = nil
    distanceEstimator.clear()
    // frameOverrides is kept: the host, and with it Herald's cached payloads,
    // survives our stop/start, so the overrides still apply.
    localPeerId = peerId

    if mock {
      // A cancelled stop may have left the host running, so always quiesce.
      // No-op when there's no host.
      quiesceBleHost()
      // Mock mode has no transport, but the supplier still holds the status
      // this device broadcasts so updateStatus keeps working. Reuse the BLE
      // host's supplier if one exists — the host keeps serving whatever
      // supplier it was built with.
      if let supplier = payloadSupplier {
        supplier.updatePeerId(peerId)
      } else {
        payloadSupplier = StatusPayloadSupplier(peerId: peerId)
      }
      startMockSource()
    } else {
      startOrResumeBleHost(sessionId: sessionId, peerId: peerId)
    }
  }

  func stop() {
    BridgeLog.i("controller", "stop (mode was \(sourceMode))")
    pendingQuiesce?.cancel()
    pendingQuiesce = nil
    mockSource?.stop()
    mockSource = nil
    // Flip the mode first so anything Herald still delivers is no longer
    // reported (PayloadPipeline still records it).
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
      BridgeLog.i("host", "resuming the existing Herald host (same session)")
      supplier.updatePeerId(peerId)
      supplier.setOffline(false)
      sourceMode = .ble
      host.start()
      // Tell connected peers we're back, otherwise they'd keep our cached
      // offline payload until their next re-read.
      if let frame = supplier.currentFrame() {
        sendFrame(frame, kind: "hello", via: host)
      }
      sendReady()
      return
    }

    // Whatever supplier exists at this point (an earlier session's, or mock
    // mode's) holds the status Dart pushed last; the new one takes it over.
    let previousSupplier = payloadSupplier

    // A different session id means a different service UUID, so the host
    // has to be rebuilt. The demo's fixed session id never hits this.
    if let host = sensorArray {
      BridgeLog.i(
        "host",
        "session id changed (\(bleHostSessionId ?? "-") → \(sessionId)); rebuilding the Herald host")
      host.stop()
      sensorArray = nil
      bleHostSessionId = nil
      payloadSupplier = nil
    }

    // The session UUID doubles as the BLE service UUID, so only devices on
    // the same session find each other. Herald's standard and legacy
    // (pre-2.1) services are off to keep us isolated from other Herald apps;
    // legacy detection is on by default.
    BLESensorConfiguration.payloadDataUpdateTimeInterval = Self.payloadRefreshSeconds
    BLESensorConfiguration.customServiceUUID = CBUUID(string: sessionId)
    BLESensorConfiguration.customServiceDetectionEnabled = true
    BLESensorConfiguration.customServiceAdvertisingEnabled = true
    BLESensorConfiguration.standardHeraldServiceDetectionEnabled = false
    BLESensorConfiguration.standardHeraldServiceAdvertisingEnabled = false
    BLESensorConfiguration.legacyHeraldServiceDetectionEnabled = false
    BLESensorConfiguration.logLevel = BridgeLog.heraldLevel
    BLESensorConfiguration.mobilitySensorEnabled = nil

    BridgeLog.i(
      "host",
      "building a Herald host: service=\(sessionId) refresh=\(Int(Self.payloadRefreshSeconds))s "
        + "herald log=\(BridgeLog.heraldLevel.rawValue)")
    let supplier = StatusPayloadSupplier.forRebuiltHost(peerId: peerId, previous: previousSupplier)
    // A new host starts with an empty Herald cache, so overrides of the old
    // one's cached payloads no longer apply.
    frameOverrides.clearAll()
    let host = SensorArray(supplier)
    host.add(delegate: payloadPipeline)
    payloadSupplier = supplier
    sensorArray = host
    bleHostSessionId = sessionId
    sourceMode = .ble
    host.start()
    BridgeLog.i("host", "Herald host started; broadcasting \(supplier.describe())")
    sendReady()
  }

  /// Flags us offline, pushes a goodbye to connected peers, then stops the
  /// host once the write has had time to land.
  private func quiesceBleHost() {
    guard let host = sensorArray else { return }

    payloadSupplier?.setOffline(true)
    if let frame = payloadSupplier?.currentFrame() {
      sendFrame(frame, kind: "goodbye", via: host)
    }

    let work = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      self.pendingQuiesce = nil
      // A start raced in during the flush window, leave the host up.
      guard self.sourceMode != .ble else {
        BridgeLog.i("host", "BLE restarted within the goodbye flush window; host left running")
        return
      }
      host.stop()
      BridgeLog.i("host", "Herald host stopped after the goodbye")
    }
    pendingQuiesce = work
    BridgeLog.i("host", "quiescing: host stops in \(Self.goodbyeFlushSeconds)s unless a start cancels it")
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.goodbyeFlushSeconds, execute: work)
  }

  /// Pushes one goodbye/hello frame. Herald 2.2.0 for iOS queues a write to
  /// every peer it is connected to as a central and always returns true, so
  /// the log cannot say how many peers it reached; the receivers' logs show
  /// who got it (`native.pipeline frame`).
  private func sendFrame(_ frame: Data, kind: String, via host: SensorArray) {
    BridgeLog.i(
      "frame", "sending \(kind) \(StatusPayloadSupplier.describe(frame)) to connected peers")
    _ = host.immediateSendAll(data: frame)
  }

  private func startMockSource() {
    let source = MockPeerSource { [weak self] peerId, status, color, deviceKind, rssi in
      self?.handleSighting(
        peerId: peerId, status: status, color: color, deviceKind: deviceKind, rssi: rssi)
    }
    mockSource = source
    sourceMode = .mock
    source.start()
    BridgeLog.i(
      "mock",
      "mock source started (3 synthetic peers, 1 sighting each per second); broadcasting "
        + (payloadSupplier?.describe() ?? "nothing"))
    sendReady()
  }

  // MARK: - Sighting pipeline
  // Herald's payload callbacks go to payloadPipeline, which calls back into
  // handleSighting and emitGone.

  /// Common path for BLE and mock sightings.
  private func handleSighting(
    peerId: Int, status: Int, color: Int, deviceKind: Int, rssi: Double?
  ) {
    guard sourceMode != .idle else { return }
    var estimate: DistanceEstimator.Estimate?
    if let rssi = rssi {
      estimate = distanceEstimator.addSampleDetailed(
        peerId: peerId, rssi: rssi, senderDeviceKind: deviceKind)
    }
    let distance = estimate?.distance
    BridgeLog.d(
      "emit",
      "peer \(peerHex(peerId)) st=\(status) col=\(color) \(deviceKindName(deviceKind)) "
        + Self.describeMeasurement(rssi: rssi, estimate: estimate))

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

  private static func describeMeasurement(rssi: Double?, estimate: DistanceEstimator.Estimate?)
    -> String
  {
    guard let rssi = rssi else { return "no rssi" }
    guard let estimate = estimate else { return "rssi=\(rssi) (no estimate)" }
    return String(
      format: "rssi=%.0f median=%.1f smooth=%.1f n=%d %@ → %.1fm", rssi, estimate.median,
      estimate.smoothed, estimate.samples, estimate.iosCutoffs ? "iosCutoffs" : "androidCutoffs",
      estimate.distance)
  }

  private func emitGone(peerId: Int) {
    // Free the distance model now rather than waiting for Dart's forgetPeer.
    distanceEstimator.forget(peerId: peerId)
    BridgeLog.i("emit", "gone \(peerHex(peerId))")
    emit(["type": "gone", "id": peerId])
  }

  private func sendReady() {
    BridgeLog.i("emit", "ready (mode \(sourceMode))")
    emit(["type": "ready"])
  }

  private func emit(_ event: [String: Any]) {
    let kind = event["type"] as? String ?? "?"
    // Hop to the main thread first (Flutter requires it), then read the
    // sink under the lock — onCancel can detach it while the hop is queued,
    // and a detached sink must not be invoked.
    DispatchQueue.main.async {
      self.sinkLock.lock()
      let sink = self.eventSink
      self.sinkLock.unlock()
      guard let sink = sink else {
        if self.droppedWithoutSink == 0 {
          BridgeLog.i("sink", "Dart is not listening; dropping events until it does (first: \(kind))")
        }
        self.droppedWithoutSink += 1
        self.count("nosink")
        return
      }
      sink(event)
      self.count(kind)
    }
  }

  /// Main thread.
  private func count(_ kind: String) {
    if let index = emitted.firstIndex(where: { $0.kind == kind }) {
      emitted[index].count += 1
    } else {
      emitted.append((kind, 1))
    }
    emittedTotals[kind, default: 0] += 1
  }

  /// One summary line every `statsIntervalSeconds` while a source or the
  /// host is up, plus one line per peer that has a distance model or a
  /// remembered payload. Main thread.
  private func logStats() {
    guard isRunning || sensorArray != nil else { return }
    let herald = payloadPipeline.takeStats()
    // A stopped host that hears nothing has nothing to report.
    if !isRunning && herald == "none" && emitted.isEmpty { return }
    let events =
      emitted.isEmpty
      ? "none"
      : emitted.map { "\($0.kind)=+\($0.count)/\(emittedTotals[$0.kind] ?? 0)" }.joined(
        separator: " ")
    emitted.removeAll()
    sinkLock.lock()
    let sinkState = eventSink != nil ? "on" : "OFF"
    sinkLock.unlock()
    BridgeLog.i(
      "stats",
      "mode=\(sourceMode) host=\(sensorArray != nil ? "up" : "none") "
        + "bt=\(payloadPipeline.bluetoothState?.rawValue ?? "?") sink=\(sinkState) "
        + "\(payloadSupplier?.describe() ?? "no payload") | herald: \(herald) | to dart: \(events)")

    var models: [Int: DistanceEstimator.Snapshot] = [:]
    for snapshot in distanceEstimator.snapshot() { models[snapshot.peerId] = snapshot }
    let remembered = frameOverrides.snapshot()
    for peerId in Set(models.keys).union(remembered.keys).sorted() {
      let distance =
        models[peerId].map {
          String(
            format: "smooth=%.1f n=%d → %.1fm last sample %.1fs ago", $0.last.smoothed,
            $0.last.samples, $0.last.distance, $0.lastSampleAge)
        } ?? "no distance model"
      BridgeLog.i(
        "stats",
        "  peer \(peerHex(peerId)) \(distance) | \(remembered[peerId] ?? "nothing remembered")")
    }
  }

  // MARK: - FlutterStreamHandler

  func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    sinkLock.lock()
    eventSink = events
    sinkLock.unlock()
    BridgeLog.i(
      "sink",
      "Dart subscribed to events (running=\(isRunning)"
        + (droppedWithoutSink > 0 ? ", \(droppedWithoutSink) dropped meanwhile)" : ")"))
    droppedWithoutSink = 0
    // If the source was already running when Dart subscribed, the original
    // ready event went nowhere. Send it again.
    if isRunning {
      sendReady()
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sinkLock.lock()
    eventSink = nil
    sinkLock.unlock()
    BridgeLog.i("sink", "Dart cancelled its event subscription")
    return nil
  }
}
