import Foundation
import Herald

/// Encodes the payload we broadcast and decodes payloads from peers. The
/// same 16 bytes also travel in goodbye/hello frames, which is why the
/// decoders take raw `Data`.
///
/// Wire format (16 bytes, little-endian, must match the Android encoder):
///
/// ```
/// offset 0-7   UInt64  peer id
/// offset 8     UInt8   status code
/// offset 9     UInt8   color index
/// offset 10    UInt8   device kind (0 = iOS, 1 = Android)
/// offset 11    UInt8   flags (bit 0 = offline / goodbye,
///                      bits 1-7 = payload revision, from version 3)
/// offset 12-15 UInt32  protocol version
/// ```
///
/// The offline flag exists because BLE has no goodbye of its own. Peers that
/// are still connected keep reading our payload after we stop, and the flag
/// is how they find out we're gone. The revision lets a receiver tell which
/// of two payloads from the same peer is newer (see FrameOverrides).
///
/// The decoders never throw or crash on bad input; a short or garbled
/// payload is just dropped.
final class StatusPayloadSupplier: PayloadDataSupplier {

  static let payloadSize = 16
  static let deviceKindIOS: UInt8 = 0
  static let protocolVersion: UInt32 = 3
  static let flagOffline: UInt8 = 0x01

  /// The first protocol version whose flags carry a revision.
  static let firstVersionWithRevision = 3
  /// Revisions are 7 bits (flags bits 1-7) and wrap around.
  static let revisionMask = 0x7F
  private static let revisionShift = 1

  // Herald reads from its BLE queues while the platform thread writes,
  // so everything goes through the lock.
  private let lock = NSLock()
  private let revisions: RevisionCounter
  private var peerId: UInt64
  private var status: UInt8 = 0
  private var color: UInt8 = 0
  private var offline = false
  // Taken from the shared counter, so it is newer than anything an earlier
  // supplier in this process broadcast under the same peer id.
  private var revision: Int

  init(peerId: Int, revisions: RevisionCounter = .shared) {
    // Bit-pattern conversion so a negative id round-trips instead of
    // trapping — the Android encoder writes its Long the same way.
    self.peerId = UInt64(bitPattern: Int64(peerId))
    self.revisions = revisions
    self.revision = revisions.next()
  }

  /// The supplier for a newly built host. It takes over the status and color
  /// of the supplier it replaces, if any, so the new host doesn't broadcast a
  /// blank status until Dart's next push.
  static func forRebuiltHost(
    peerId: Int, previous: StatusPayloadSupplier?, revisions: RevisionCounter = .shared
  ) -> StatusPayloadSupplier {
    let supplier = StatusPayloadSupplier(peerId: peerId, revisions: revisions)
    if let previous = previous {
      supplier.adoptStatus(from: previous)
    }
    return supplier
  }

  func update(status: Int, color: Int) {
    lock.lock()
    defer { lock.unlock() }
    let newStatus = UInt8(clamping: status)
    let newColor = UInt8(clamping: color)
    guard newStatus != self.status || newColor != self.color else { return }
    self.status = newStatus
    self.color = newColor
    revision = revisions.next()
  }

  func updatePeerId(_ peerId: Int) {
    lock.lock()
    defer { lock.unlock() }
    let newPeerId = UInt64(bitPattern: Int64(peerId))
    guard newPeerId != self.peerId else { return }
    self.peerId = newPeerId
    revision = revisions.next()
  }

  /// Takes over the status and color of the supplier this one replaces.
  func adoptStatus(from previous: StatusPayloadSupplier) {
    previous.lock.lock()
    let previousStatus = previous.status
    let previousColor = previous.color
    previous.lock.unlock()

    update(status: Int(previousStatus), color: Int(previousColor))
  }

  /// While offline, every payload we serve carries the goodbye flag,
  /// including re-reads from peers whose connections outlived our stop.
  func setOffline(_ value: Bool) {
    lock.lock()
    defer { lock.unlock() }
    guard value != offline else { return }
    offline = value
    revision = revisions.next()
  }

  // MARK: - PayloadDataSupplier

  func payload(_ timestamp: PayloadTimestamp, device: Device?) -> PayloadData? {
    lock.lock()
    let id = peerId
    let statusNow = status
    let colorNow = color
    let flags = UInt8(revision << Self.revisionShift) | (offline ? Self.flagOffline : 0)
    lock.unlock()

    let result = PayloadData()
    result.append(id)  // bytes 0-7
    result.append(statusNow)  // byte 8
    result.append(colorNow)  // byte 9
    result.append(Self.deviceKindIOS)  // byte 10
    result.append(flags)  // byte 11
    result.append(Self.protocolVersion)  // bytes 12-15
    return result
  }

  /// The current payload as raw bytes, for immediate-send frames.
  func currentFrame() -> Data? {
    payload(PayloadTimestamp(), device: nil)?.data
  }

  // MARK: - Decoders (raw Data, shared by payload reads and immediate-send)

  static func peerId(from data: Data) -> Int? {
    guard data.count >= payloadSize, let value = data.uint64(0) else {
      return nil
    }
    // Bit-pattern conversion, not Int(value): an id with the top bit set
    // (any device could broadcast one on our service UUID) must decode as
    // a negative Int — the same value the Android decoder produces —
    // instead of trapping.
    return Int(bitPattern: UInt(value))
  }

  static func status(from data: Data) -> Int? {
    guard data.count >= payloadSize,
      let value = data.advanced(by: 8).uint8(0)
    else { return nil }
    return Int(value)
  }

  static func color(from data: Data) -> Int? {
    guard data.count >= payloadSize,
      let value = data.advanced(by: 9).uint8(0)
    else { return nil }
    return Int(value)
  }

  static func deviceKind(from data: Data) -> Int? {
    guard data.count >= payloadSize,
      let value = data.advanced(by: 10).uint8(0)
    else { return nil }
    return Int(value)
  }

  static func isOffline(from data: Data) -> Bool? {
    guard data.count >= payloadSize,
      let flags = data.advanced(by: 11).uint8(0)
    else { return nil }
    return flags & flagOffline != 0
  }

  /// The payload's revision, or nil when it has none: a sender before
  /// protocol version 3 leaves flags bits 1-7 at 0.
  static func revision(from data: Data) -> Int? {
    guard let version = version(from: data), version >= firstVersionWithRevision,
      let flags = data.advanced(by: 11).uint8(0)
    else { return nil }
    return (Int(flags) >> revisionShift) & revisionMask
  }

  static func version(from data: Data) -> Int? {
    guard data.count >= payloadSize,
      let value = data.advanced(by: 12).uint32(0)
    else { return nil }
    return Int(value)
  }

  // MARK: - Decoder conveniences for Herald PayloadData

  static func peerId(from payload: PayloadData) -> Int? { peerId(from: payload.data) }
  static func status(from payload: PayloadData) -> Int? { status(from: payload.data) }
  static func color(from payload: PayloadData) -> Int? { color(from: payload.data) }
  static func deviceKind(from payload: PayloadData) -> Int? { deviceKind(from: payload.data) }
  static func isOffline(from payload: PayloadData) -> Bool? { isOffline(from: payload.data) }
  static func revision(from payload: PayloadData) -> Int? { revision(from: payload.data) }
  static func version(from payload: PayloadData) -> Int? { version(from: payload.data) }
}

/// Hands out payload revisions. The app uses one counter per process, shared
/// by every supplier: a host rebuilt for a new session keeps the same peer
/// id, so its supplier must carry on above the old one's revisions.
/// Revisions are 7 bits and wrap; receivers compare them with serial-number
/// arithmetic.
///
/// The counter lives in memory and starts again in every process. That is
/// safe here because Dart picks a new random peer id at every launch. An app
/// that keeps its peer id across launches must persist the counter's last
/// value with it and continue from there: otherwise receivers that still
/// remember the previous launch take the new one's payloads, goodbye
/// included, for older ones (see FrameOverrides).
final class RevisionCounter {
  static let shared = RevisionCounter()

  private let lock = NSLock()
  private var last = 0

  func next() -> Int {
    lock.lock()
    defer { lock.unlock() }
    last = (last + 1) & StatusPayloadSupplier.revisionMask
    return last
  }
}
