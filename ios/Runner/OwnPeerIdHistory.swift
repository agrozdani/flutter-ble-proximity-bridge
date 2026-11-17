import Foundation

/// The ids this device broadcast as before its current one, kept across
/// launches so PayloadPipeline can drop them like the current id.
///
/// Ids are per `BridgeController` in Dart, so a new one comes with every
/// launch and every hot restart. A peer can still hold our payload from an
/// earlier one: Herald for Android keeps a device's record until it has not
/// been updated for 15 minutes (`taskRemoveExpiredDevices`), and when our
/// Bluetooth address has rotated in the meantime it cannot tie that record
/// to us. Its payload sharing relays records updated in the last 5 minutes
/// (`payloadSharingExpiryTimeInterval`) and only skips a payload
/// byte-identical to the one it last read from us, so it hands the old
/// payload back to us as another device's. Without this we would list our
/// own earlier launch as a peer.
///
/// Remembered for `retentionMillis` after the id was replaced, capped at
/// `capacity` ids. Ids are random 31-bit values, so mistaking another
/// device's id for one of ours is not a practical concern. Ids from mock
/// starts are kept too; they were never broadcast, which is harmless.
///
/// Times are wall-clock milliseconds, the only clock that carries across
/// launches and reboots. A clock set back only keeps ids longer, which the
/// cap bounds; one set forward can expire them early.
///
/// `noteCurrent` is called on the main thread; `isPrevious` from Herald's
/// queues. Both go through a lock, and `isPrevious` never touches storage.
final class OwnPeerIdHistory {

  /// A margin, not a derived bound. Every update to Herald for Android's
  /// record of us resets its 15-minute expiry and its 5-minute sharing
  /// window, and not only our advertisements do that (any field Herald sets
  /// on the record does). On hardware an old id was relayed back about 8
  /// minutes after that launch ended, so something refreshed it after we
  /// left; what, is not known. 30 minutes is twice the record's expiry
  /// counted from the replacement. The drop line logs each id's age, so
  /// field logs show how late relays really come.
  static let retentionMillis: Int64 = 30 * 60_000

  /// Only bounds a clock set back; within the retention it is never
  /// reached in practice (a relaunch or hot restart every 28 s). Checking
  /// 64 ids per payload costs nothing next to decoding it.
  static let capacity = 64

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

  /// Backed by a small file in Application Support, written atomically
  /// before `noteCurrent` returns, so a launch that is killed right after
  /// starting (an Xcode stop, a crash) still leaves its id for the next
  /// one; UserDefaults gives no such guarantee. Excluded from backups: a
  /// restored or migrated device must not take the old device's ids for
  /// its own. A failed write is logged and only brings back the ghost.
  static func standard() -> OwnPeerIdHistory {
    let url = try? FileManager.default
      .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("own-peer-ids.txt")
    return OwnPeerIdHistory(
      read: { url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } },
      write: { text in
        guard var url = url else {
          BridgeLog.w("controller", "own id history not saved: no Application Support directory")
          return
        }
        do {
          try Data(text.utf8).write(to: url, options: .atomic)
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          try url.setResourceValues(values)
        } catch {
          BridgeLog.w("controller", "own id history not saved: \(error)")
        }
      })
  }

  /// This device now broadcasts as `peerId`. A different id than last
  /// time (in this launch or an earlier one) becomes a previous id.
  func noteCurrent(_ peerId: Int) {
    lock.lock()
    let nowMillis = now()
    if let old = current, old != peerId {
      previous.removeAll { $0.peerId == old }
      previous.append((old, nowMillis))
    }
    previous.removeAll { $0.peerId == peerId }
    current = peerId
    previous.removeAll { nowMillis - $0.replacedAtMillis > Self.retentionMillis }
    if previous.count > Self.capacity { previous.removeFirst(previous.count - Self.capacity) }
    let text = encoded()
    lock.unlock()
    // Outside the lock: Herald's queues call isPrevious meanwhile. Only the
    // main thread writes, so writes stay in order.
    write(text)
  }

  /// Whether `peerId` is one this device broadcast as before its current
  /// id, within the retention.
  func isPrevious(_ peerId: Int) -> Bool {
    previousAgeMillis(peerId) != nil
  }

  /// How long ago `peerId` stopped being this device's id, if it is a
  /// previous one within the retention.
  func previousAgeMillis(_ peerId: Int) -> Int64? {
    lock.lock()
    defer { lock.unlock() }
    let nowMillis = now()
    guard let entry = previous.last(where: { $0.peerId == peerId }) else { return nil }
    let age = nowMillis - entry.replacedAtMillis
    return age <= Self.retentionMillis ? age : nil
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
      let fields = entry.split(separator: "@", omittingEmptySubsequences: false)
      if fields.count == 2, let id = Int(fields[0]), let at = Int64(fields[1]) {
        previous.append((id, at))
      }
    }
  }
}
