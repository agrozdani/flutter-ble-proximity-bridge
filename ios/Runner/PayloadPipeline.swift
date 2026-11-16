import Foundation
import Herald
import os.log

/// Herald's delegate. Maps each callback that carries a payload to where
/// that payload came from, decodes it, drops malformed payloads and our own,
/// lets `FrameOverrides` decide which payload to believe, and reports the
/// outcome. Kept free of Flutter so the whole path can be unit-tested.
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

  /// `isActive` says whether outcomes are reported (a BLE source is
  /// logically running); `localPeerId` is the id this device broadcasts as.
  init(
    frameOverrides: FrameOverrides,
    isActive: @escaping () -> Bool,
    localPeerId: @escaping () -> Int?,
    onSighting: @escaping (Int, Int, Int, Int, Double?) -> Void,
    onGone: @escaping (Int) -> Void,
    onMalformed: @escaping (Int) -> Void = { size in
      os_log("Dropping malformed payload (%d bytes)", type: .info, size)
    }
  ) {
    self.frameOverrides = frameOverrides
    self.isActive = isActive
    self.localPeerId = localPeerId
    self.onSighting = onSighting
    self.onGone = onGone
    self.onMalformed = onMalformed
  }

  // MARK: - Herald SensorDelegate
  // The protocol has empty default implementations; only the callbacks that
  // carry a payload are handled.

  func sensor(_ sensor: SensorType, didRead: PayloadData, fromTarget: TargetIdentifier) {
    // Payload read over GATT (or written to us by the peer); no RSSI.
    handle(didRead.data, rssi: nil, source: .read)
  }

  func sensor(_ sensor: SensorType, didReceive: Data, fromTarget: TargetIdentifier) {
    // Goodbye/hello frames. Same 16-byte payload, same pipeline.
    handle(didReceive, rssi: nil, source: .frame)
  }

  func sensor(_ sensor: SensorType, didShare: [PayloadData], fromTarget: TargetIdentifier) {
    // Payloads relayed by another peer (helps with iOS background limits).
    for payload in didShare {
      handle(payload.data, rssi: nil, source: .cached)
    }
  }

  func sensor(
    _ sensor: SensorType, didMeasure: Proximity, fromTarget: TargetIdentifier,
    withPayload: PayloadData
  ) {
    // An RSSI reading together with the payload Herald last read from that
    // peer, which can be up to a refresh interval old.
    handle(withPayload.data, rssi: didMeasure.value, source: .cached)
  }

  // MARK: - Pipeline

  private func handle(_ data: Data, rssi: Double?, source: FrameOverrides.Source) {
    guard let peerId = StatusPayloadSupplier.peerId(from: data),
      let status = StatusPayloadSupplier.status(from: data),
      let color = StatusPayloadSupplier.color(from: data),
      let deviceKind = StatusPayloadSupplier.deviceKind(from: data),
      let offline = StatusPayloadSupplier.isOffline(from: data)
    else {
      onMalformed(data.count)
      return
    }

    // Never list ourselves. Herald's Android relay skips handing a peer its
    // own payload by comparing bytes, so a copy that differs from the current
    // one (an older status, an earlier offline flag) can come back to the
    // device it describes.
    if peerId == localPeerId() { return }

    // Resolve even while stopped: Herald keeps its cached copies across our
    // stop/start, so the frames and reads it delivers meanwhile still matter
    // after the next start.
    let payload = frameOverrides.resolve(
      peerId: peerId, source: source,
      payload: FrameOverrides.Payload(
        status: status, color: color, deviceKind: deviceKind, offline: offline,
        revision: StatusPayloadSupplier.revision(from: data)))

    // Ignore anything from connections that outlived a stop; nil means the
    // payload must be ignored (see FrameOverrides).
    guard isActive(), let payload = payload else { return }

    if payload.offline {
      // Peer said goodbye, or its payload carries the offline flag.
      onGone(peerId)
    } else {
      onSighting(peerId, payload.status, payload.color, payload.deviceKind, rssi)
    }
  }
}
