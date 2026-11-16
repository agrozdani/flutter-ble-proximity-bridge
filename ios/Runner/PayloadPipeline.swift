import Foundation
import Herald

/// Herald's delegate. Maps each callback that carries a payload to where
/// that payload came from, decodes it, drops malformed payloads and our own,
/// lets `FrameOverrides` decide which payload to believe, and reports the
/// outcome. Kept free of Flutter so the whole path can be unit-tested.
///
/// Every decision is logged (`native.pipeline`), with what FrameOverrides
/// decided and why. The one exception is the most common case, a cached
/// payload taken as it is with an RSSI reading: native.emit logs that
/// sighting together with its distance estimate.
///
/// Herald calls this on its own queues (one serial delegate queue in Herald
/// 2.2.0); the closures it is given must be safe to call there.
final class PayloadPipeline: SensorDelegate {

  private let frameOverrides: FrameOverrides
  private let isActive: () -> Bool
  private let localPeerId: () -> Int?
  private let onSighting:
    (_ peerId: Int, _ status: Int, _ color: Int, _ deviceKind: Int, _ rssi: Double?) -> Void
  private let onGone: (_ peerId: Int) -> Void
  private let onMalformed: (_ size: Int) -> Void

  private let statsLock = NSLock()
  private var counts: [(name: String, count: Int)] = []
  private var _bluetoothState: SensorState?

  /// `isActive` says whether outcomes are reported (a BLE source is
  /// logically running); `localPeerId` is the id this device broadcasts as.
  init(
    frameOverrides: FrameOverrides,
    isActive: @escaping () -> Bool,
    localPeerId: @escaping () -> Int?,
    onSighting: @escaping (Int, Int, Int, Int, Double?) -> Void,
    onGone: @escaping (Int) -> Void,
    onMalformed: @escaping (Int) -> Void = { _ in }
  ) {
    self.frameOverrides = frameOverrides
    self.isActive = isActive
    self.localPeerId = localPeerId
    self.onSighting = onSighting
    self.onGone = onGone
    self.onMalformed = onMalformed
  }

  /// The last Bluetooth state Herald reported, for the stats line.
  var bluetoothState: SensorState? {
    statsLock.lock()
    defer { statsLock.unlock() }
    return _bluetoothState
  }

  /// Counts since the last call, e.g. `read=2 cached=31 ...`, then resets.
  func takeStats() -> String {
    statsLock.lock()
    defer { statsLock.unlock() }
    let text = counts.isEmpty ? "none" : counts.map { "\($0.name)=\($0.count)" }.joined(separator: " ")
    counts.removeAll()
    return text
  }

  // MARK: - Herald SensorDelegate
  // The protocol has empty default implementations; the callbacks without a
  // payload are only counted or logged.

  func sensor(_ sensor: SensorType, didRead: PayloadData, fromTarget: TargetIdentifier) {
    // Payload read over GATT (or written to us by the peer); no RSSI.
    count("read")
    handle(didRead.data, rssi: nil, source: .read, target: fromTarget)
  }

  func sensor(_ sensor: SensorType, didReceive: Data, fromTarget: TargetIdentifier) {
    // Goodbye/hello frames. Same 16-byte payload, same pipeline.
    count("frame")
    handle(didReceive, rssi: nil, source: .frame, target: fromTarget)
  }

  func sensor(_ sensor: SensorType, didShare: [PayloadData], fromTarget: TargetIdentifier) {
    // Payloads relayed by another peer (helps with iOS background limits).
    count("shared", didShare.count)
    BridgeLog.d("pipeline", "relay via=\(via(fromTarget)) shared \(didShare.count) payload(s)")
    for payload in didShare {
      handle(payload.data, rssi: nil, source: .cached, target: fromTarget)
    }
  }

  func sensor(
    _ sensor: SensorType, didMeasure: Proximity, fromTarget: TargetIdentifier,
    withPayload: PayloadData
  ) {
    // An RSSI reading together with the payload Herald last read from that
    // peer, which can be up to a refresh interval old.
    count("cached")
    handle(withPayload.data, rssi: didMeasure.value, source: .cached, target: fromTarget)
  }

  func sensor(_ sensor: SensorType, didDetect: TargetIdentifier) {
    // A device Herald had not seen before; payload not read yet.
    count("detect")
    BridgeLog.d("pipeline", "detect via=\(via(didDetect))")
  }

  func sensor(_ sensor: SensorType, available: Bool, didDeleteOrDetect: TargetIdentifier) {
    BridgeLog.d("pipeline", "available=\(available) via=\(via(didDeleteOrDetect))")
  }

  func sensor(_ sensor: SensorType, didMeasure: Proximity, fromTarget: TargetIdentifier) {
    // RSSI without payload: it cannot be attributed to a peer id.
    count("rssiOnly")
  }

  func sensor(_ sensor: SensorType, didUpdateState: SensorState) {
    guard sensor == .BLE else {
      // SensorArray.start() and stop() report the array itself as on and
      // off; that confirms the call, it says nothing about the radio.
      BridgeLog.i("ble", "Herald \(sensor.rawValue) sensor \(didUpdateState.rawValue)")
      return
    }
    // Bluetooth state. Not surfaced to Dart, but logged: nothing is found
    // while this is not "on". Herald 2.2.0 reports every CoreBluetooth state
    // other than poweredOn (off, unauthorized, unsupported, ...) as off; the
    // authorization tells them apart.
    statsLock.lock()
    _bluetoothState = didUpdateState
    statsLock.unlock()
    BridgeLog.i(
      "ble",
      "bluetooth state \(didUpdateState.rawValue) "
        + "(authorization \(BridgeLog.bluetoothAuthorization()))")
  }

  // MARK: - Pipeline

  private func handle(
    _ data: Data, rssi: Double?, source: FrameOverrides.Source, target: TargetIdentifier
  ) {
    guard let peerId = StatusPayloadSupplier.peerId(from: data),
      let status = StatusPayloadSupplier.status(from: data),
      let color = StatusPayloadSupplier.color(from: data),
      let deviceKind = StatusPayloadSupplier.deviceKind(from: data),
      let offline = StatusPayloadSupplier.isOffline(from: data)
    else {
      count("malformed")
      BridgeLog.w(
        "pipeline",
        "\(label(source)) malformed payload (\(data.count) bytes) "
          + "\(StatusPayloadSupplier.hex(data)) via=\(via(target))")
      onMalformed(data.count)
      return
    }

    // Never list ourselves. Herald's Android relay skips handing a peer its
    // own payload by comparing bytes, so a copy that differs from the current
    // one (an older status, an earlier offline flag) can come back to the
    // device it describes.
    if peerId == localPeerId() {
      count("own")
      BridgeLog.d(
        "pipeline", "\(label(source)) own payload \(StatusPayloadSupplier.describe(data)), dropped")
      return
    }

    // Resolve even while stopped: Herald keeps its cached copies across our
    // stop/start, so the frames and reads it delivers meanwhile still matter
    // after the next start.
    let resolution = frameOverrides.resolveExplained(
      peerId: peerId, source: source,
      payload: FrameOverrides.Payload(
        status: status, color: color, deviceKind: deviceKind, offline: offline,
        revision: StatusPayloadSupplier.revision(from: data)))
    let active = isActive()
    log(source: source, data: data, rssi: rssi, target: target, resolution: resolution, active: active)

    // Ignore anything from connections that outlived a stop; nil means the
    // payload must be ignored (see FrameOverrides).
    guard active, let payload = resolution.payload else { return }

    if payload.offline {
      // Peer said goodbye, or its payload carries the offline flag.
      onGone(peerId)
    } else {
      onSighting(peerId, payload.status, payload.color, payload.deviceKind, rssi)
    }
  }

  private func log(
    source: FrameOverrides.Source, data: Data, rssi: Double?, target: TargetIdentifier,
    resolution: FrameOverrides.Resolution, active: Bool
  ) {
    let payload = resolution.payload
    let verdict = resolution.verdict
    let outcome: String
    if !active {
      outcome = "stopped, so not reported"
    } else if let payload = payload {
      outcome = payload.offline ? "reported GONE" : "reported as a sighting"
    } else {
      outcome = "nothing reported"
    }
    count(active ? "\(verdict)" : "whileStopped")

    // The common case; native.emit logs the sighting.
    let routine =
      active && source == .cached && verdict == .cachedAccepted && payload?.offline == false
    if routine { return }

    // Frames, departures and every override are rare and matter.
    let important =
      source == .frame || (active && payload?.offline == true)
      || (verdict != .cachedAccepted && verdict != .readAccepted)
    if !important && !BridgeLog.isEnabled(.debug) { return }

    var line = "\(label(source)) \(StatusPayloadSupplier.describe(data))"
    if let rssi = rssi { line += " rssi=\(Int(rssi))" }
    line += " via=\(via(target)) → \(verdict.description); \(outcome) [\(resolution.context)]"
    if important {
      BridgeLog.i("pipeline", line)
    } else {
      BridgeLog.d("pipeline", line)
    }
  }

  private func label(_ source: FrameOverrides.Source) -> String {
    switch source {
    case .read: return "read"
    case .frame: return "frame"
    case .cached: return "cached"
    }
  }

  /// Herald's identifier for the remote device, shortened. Herald 2.2.0 for
  /// iOS gives each device in its BLE database a random UUID of its own (not
  /// CoreBluetooth's identifier), so it only matches Herald's own logs.
  private func via(_ target: TargetIdentifier) -> String {
    String(target.prefix(8))
  }

  private func count(_ name: String, _ amount: Int = 1) {
    statsLock.lock()
    defer { statsLock.unlock() }
    if let index = counts.firstIndex(where: { $0.name == name }) {
      counts[index].count += amount
    } else {
      counts.append((name, amount))
    }
  }
}
