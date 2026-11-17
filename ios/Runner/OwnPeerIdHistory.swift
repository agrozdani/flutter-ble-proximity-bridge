import Foundation

/// The ids this device broadcast as before its current one, kept across
/// launches so PayloadPipeline can drop them like the current id.
///
/// Ids are per launch (`BridgeController` in Dart). A peer can still hold
/// our payload from an earlier launch: Herald for Android keeps a device's
/// record for up to 15 minutes after its last update
/// (`taskRemoveExpiredDevices`), and when our Bluetooth address has rotated
/// in the meantime it cannot tie that record to us. Its payload sharing then
/// relays the old payload back to us as another device's, and only skips a
/// payload byte-identical to our current one. Without this we would list
/// our own earlier launch as a peer.
///
/// Remembered for `retentionMillis` after the id was replaced, capped at
/// `capacity` ids. Ids are random 31-bit values, so mistaking another
/// device's id for one of ours is not a practical concern.
///
/// Times are wall-clock milliseconds, the only clock that carries across
/// launches and reboots. A clock set back only keeps ids longer, which the
/// cap bounds; one set forward can expire them early.
///
/// `noteCurrent` is called on the main thread; `isPrevious` from Herald's
/// queues. Both go through a lock, and `isPrevious` never touches storage.
final class OwnPeerIdHistory {

  /// Twice Herald for Android's 15-minute device expiry. The record ages
  /// from the old launch's last advertisement, which is before the id is
  /// replaced here, so 15 minutes would already be enough; the rest is slack.
  static let retentionMillis: Int64 = 30 * 60_000

  /// Enough for a relaunch every two minutes for the whole retention.
  static let capacity = 16

  private let write: (String) -> Void
  private let now: () -> Int64
  private let lock = NSLock()
  private var current: Int?
  private var previous: [(peerId: Int, replacedAtMillis: Int64)] = []

  /// `read` and `write` hold the encoded history (`encoded()`); `read` is
  /// called once, here.
  init(
    read: () -> String?,
    write: @escaping (String) -> Void,
    now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
  ) {
    self.write = write
    self.now = now
    if let stored = read() { decode(stored) }
  }

  /// Backed by `UserDefaults.standard`.
  static func standard() -> OwnPeerIdHistory {
    let key = "ownPeerIdHistory"
    return OwnPeerIdHistory(
      read: { UserDefaults.standard.string(forKey: key) },
      write: { UserDefaults.standard.set($0, forKey: key) })
  }

  /// This device now broadcasts as `peerId`. A different id than last
  /// time (in this launch or an earlier one) becomes a previous id.
  func noteCurrent(_ peerId: Int) {
    lock.lock()
    defer { lock.unlock() }
    let nowMillis = now()
    if let old = current, old != peerId {
      previous.removeAll { $0.peerId == old }
      previous.append((old, nowMillis))
    }
    previous.removeAll { $0.peerId == peerId }
    current = peerId
    previous.removeAll { nowMillis - $0.replacedAtMillis > Self.retentionMillis }
    if previous.count > Self.capacity { previous.removeFirst(previous.count - Self.capacity) }
    write(encoded())
  }

  /// Whether `peerId` is one this device broadcast as before its current
  /// id, within the retention.
  func isPrevious(_ peerId: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let nowMillis = now()
    return previous.contains {
      $0.peerId == peerId && nowMillis - $0.replacedAtMillis <= Self.retentionMillis
    }
  }

  /// The previous ids within the retention, oldest first, for the log.
  func previousIds() -> [Int] {
    lock.lock()
    defer { lock.unlock() }
    let nowMillis = now()
    return previous.filter { nowMillis - $0.replacedAtMillis <= Self.retentionMillis }
      .map { $0.peerId }
  }

  /// `current|id@millis,id@millis`, ids in decimal. The same format as
  /// OwnPeerIdHistory.kt, though nothing moves it between platforms.
  private func encoded() -> String {
    (current.map(String.init) ?? "") + "|"
      + previous.map { "\($0.peerId)@\($0.replacedAtMillis)" }.joined(separator: ",")
  }

  /// Anything that does not parse is skipped: losing the history only
  /// brings back the ghost this guards against, nothing worse.
  private func decode(_ text: String) {
    let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return }
    current = Int(parts[0])
    for entry in parts[1].split(separator: ",") {
      let fields = entry.split(separator: "@")
      if fields.count == 2, let id = Int(fields[0]), let at = Int64(fields[1]) {
        previous.append((id, at))
      }
    }
  }
}
