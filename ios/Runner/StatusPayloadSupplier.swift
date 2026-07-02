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
/// offset 11    UInt8   flags (bit 0 = offline / goodbye)
/// offset 12-15 UInt32  protocol version
/// ```
///
/// The offline flag exists because BLE has no goodbye of its own. Peers that
/// are still connected keep reading our cached payload after we stop, and
/// the flag is how they find out we're gone.
///
/// The decoders never throw or crash on bad input; a short or garbled
/// payload is just dropped.
final class StatusPayloadSupplier: PayloadDataSupplier {

  static let payloadSize = 16
  static let deviceKindIOS: UInt8 = 0
  static let protocolVersion: UInt32 = 2
  static let flagOffline: UInt8 = 0x01

  // Herald reads from its BLE queues while the platform thread writes,
  // so everything goes through the lock.
  private let lock = NSLock()
  private var peerId: UInt64
  private var status: UInt8 = 0
  private var color: UInt8 = 0
  private var offline = false

  init(peerId: Int) {
    // Bit-pattern conversion so a negative id round-trips instead of
    // trapping — the Android encoder (Kotlin Long) has the same semantics.
    self.peerId = UInt64(bitPattern: Int64(peerId))
  }

  func update(status: Int, color: Int) {
    lock.lock()
    defer { lock.unlock() }
    self.status = UInt8(clamping: status)
    self.color = UInt8(clamping: color)
  }

  func updatePeerId(_ peerId: Int) {
    lock.lock()
    defer { lock.unlock() }
    self.peerId = UInt64(bitPattern: Int64(peerId))
  }

  /// While offline, every payload we serve carries the goodbye flag,
  /// including re-reads from peers whose connections outlived our stop.
  func setOffline(_ value: Bool) {
    lock.lock()
    defer { lock.unlock() }
    offline = value
  }

  // MARK: - PayloadDataSupplier

  func payload(_ timestamp: PayloadTimestamp, device: Device?) -> PayloadData? {
    lock.lock()
    let id = peerId
    let statusNow = status
    let colorNow = color
    let flags: UInt8 = offline ? Self.flagOffline : 0
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
    // a negative Int — matching Kotlin's signed Long — instead of trapping.
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
  static func version(from payload: PayloadData) -> Int? { version(from: payload.data) }
}
