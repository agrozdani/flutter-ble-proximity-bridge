import Foundation

/// Decides which payload to believe for a peer: the one Herald just handed
/// over, what the peer last announced in a goodbye/hello frame, or the newest
/// payload seen from it.
///
/// A frame is pushed precisely because the receiver's copy of the payload is
/// out of date, but Herald does not update that copy from a frame: it keeps
/// reporting every RSSI reading together with the payload it last *read*.
/// Taken at face value, the stale copy overrules the frame on the next
/// reading — a peer that said goodbye pops back with its old online payload,
/// and a peer that said hello is removed again by its old offline one.
///
/// So a frame is remembered per peer and outvotes cached payloads until a
/// fresh read of that peer's payload supersedes it. Entries also expire, so a
/// frame can't outvote the payload forever if that read never happens.
///
/// A goodbye from an iPhone expires much sooner (`iphoneGoodbyeTtlSeconds`).
/// An iPhone stops advertising and sending keep-alive notifications 0.3 s
/// after its goodbye (one keep-alive already scheduled can still follow
/// within 2 s), so apart from copies relayed by other peers, only readings
/// already under way can still carry its old online payload, and those end
/// within a few seconds. Holding the goodbye longer would hide the peer if it
/// restarts before our next re-read, and its hello can't be counted on to
/// end the goodbye early: Herald's iOS immediateSendAll only reaches peers
/// the sender is connected to as a central, and Herald's stop() drops those
/// connections. An Android sender keeps advertising while its blocking send
/// works through its peers, so its goodbye keeps the full `ttlSeconds`.
///
/// Payloads from protocol version 3 on also carry a revision, which the
/// sender bumps on every change. The newest revision a peer sent us, in a
/// frame or a read, is remembered for `revisionMemorySeconds` after it last
/// arrived that way. Cached copies are never remembered: Herald's own repeats
/// the payload it last read, already reported as a read, and a relay's can be
/// older still, so remembering them would keep an old revision alive for as
/// long as readings repeat it. While a revision is remembered, a frame or
/// read older than it is dropped: a frame delivered late, a read that a frame
/// overtook, or a stale copy relayed by another peer. A cached payload older
/// than it is described by the newest payload instead when that one is
/// online. When the newest is an offline frame whose lifetime has run out,
/// the cached payload is taken at face value: readings carrying the old copy
/// then most likely mean the peer restarted and its hello was lost. Without
/// revisions (older peers), only the frame rule above applies.
///
/// Revisions only order the payloads of one sender process. Each process
/// starts its counter again (see `RevisionCounter`), so a peer id reused by a
/// new process looks older than what is remembered of the old one, and its
/// payloads are dropped or overruled until that memory lapses.
final class FrameOverrides {

  /// Where Herald got the payload it is handing over.
  enum Source {
    /// Just read from the peer, or written to us by it. A relayed payload
    /// Herald doesn't already hold also arrives as a read.
    case read
    /// A goodbye/hello frame the peer pushed to us.
    case frame
    /// Herald's stored copy, attached to an RSSI reading, or a payload in a
    /// relayed list: possibly stale.
    case cached
  }

  /// The decoded fields of one payload; `revision` is nil before version 3.
  struct Payload: Equatable {
    var status: Int
    var color: Int
    var deviceKind: Int
    var offline: Bool
    var revision: Int? = nil
  }

  /// Why `resolveExplained` decided what it did; logged by the pipeline.
  enum Verdict {
    case frameRecorded, frameLate
    case readAccepted, readEndsFrame, readStale
    case cachedAccepted, cachedNewerThanFrame, cachedHiddenByGoodbye, cachedReplacedByHello
    case cachedReplacedByNewest, cachedBelievedAfterGoodbye, cachedDroppedAfterOfflineRead

    var description: String {
      switch self {
      case .frameRecorded: return "frame recorded"
      case .frameLate, .readStale: return "dropped: older than the newest revision"
      case .readAccepted, .cachedAccepted: return "accepted"
      case .readEndsFrame: return "accepted; ends the frame's override"
      case .cachedNewerThanFrame: return "accepted: newer than the frame, which it ends"
      case .cachedHiddenByGoodbye: return "ignored: the peer's goodbye frame outvotes it"
      case .cachedReplacedByHello: return "replaced by the peer's hello frame"
      case .cachedReplacedByNewest: return "replaced by the newest payload (it is older)"
      case .cachedBelievedAfterGoodbye:
        return "accepted: older, but the goodbye ran out (likely a restart whose hello was lost)"
      case .cachedDroppedAfterOfflineRead: return "ignored: older than a read that said offline"
      }
    }
  }

  /// What `resolveExplained` returns: the payload to act on (nil: ignore
  /// it), why, and what it was weighed against, for the log.
  struct Resolution {
    let payload: Payload?
    let verdict: Verdict
    let context: String
  }

  private enum Order {
    case newer, same, older
  }

  private struct Frame {
    let payload: Payload
    let recordedAt: Double
    let lifetime: Double
  }

  private struct Newest {
    let payload: Payload
    let confirmedAt: Double
    let fromFrame: Bool
  }

  private let ttlSeconds: Double
  private let iphoneGoodbyeTtlSeconds: Double
  private let revisionMemorySeconds: Double
  private let now: () -> Double
  private let lock = NSLock()
  private var frames: [Int: Frame] = [:]
  private var newest: [Int: Newest] = [:]
  private var lastSweep: Double

  /// `ttlSeconds` is how long a frame outvotes cached payloads if no fresh
  /// read ends it; `iphoneGoodbyeTtlSeconds` the same for a goodbye sent by
  /// an iPhone; `revisionMemorySeconds` how long a peer's newest revision is
  /// remembered after its last frame or read. `now` is a monotonic clock in
  /// seconds; tests inject their own.
  init(
    ttlSeconds: Double,
    iphoneGoodbyeTtlSeconds: Double,
    revisionMemorySeconds: Double,
    now: @escaping () -> Double = MonotonicClock.seconds
  ) {
    self.ttlSeconds = ttlSeconds
    self.iphoneGoodbyeTtlSeconds = iphoneGoodbyeTtlSeconds
    self.revisionMemorySeconds = revisionMemorySeconds
    self.now = now
    self.lastSweep = now()
  }

  /// Returns the payload to act on for this peer, or nil when `payload` must
  /// be ignored: a cached copy of a peer whose goodbye frame was already
  /// reported, or a payload older than one already seen.
  func resolve(peerId: Int, source: Source, payload: Payload) -> Payload? {
    resolveExplained(peerId: peerId, source: source, payload: payload).payload
  }

  /// `resolve`, plus why.
  func resolveExplained(peerId: Int, source: Source, payload: Payload) -> Resolution {
    lock.lock()
    defer { lock.unlock() }
    sweepIfDue()
    let known = unexpiredNewest(peerId: peerId)
    let stale = known.map { order(payload.revision, $0.payload.revision) == .older } ?? false
    // What this payload is weighed against, before anything changes.
    let context = describe(known, peekFrame(peerId: peerId))
    func result(_ payload: Payload?, _ verdict: Verdict) -> Resolution {
      Resolution(payload: payload, verdict: verdict, context: context)
    }
    // Only what the peer sent us itself is remembered (see above).
    if !stale, source != .cached {
      newest[peerId] = Newest(payload: payload, confirmedAt: now(), fromFrame: source == .frame)
    }

    switch source {
    case .frame:
      // Delivered late: the peer has sent something newer since.
      if stale { return result(nil, .frameLate) }
      frames[peerId] = Frame(payload: payload, recordedAt: now(), lifetime: lifetime(of: payload))
      return result(payload, .frameRecorded)
    case .read:
      // Older than what the peer has sent since: a read a frame overtook,
      // or a stale relayed copy. It changes nothing.
      if stale { return result(nil, .readStale) }
      // Newer than any frame, so the frame's job is done.
      let hadFrame = peekFrame(peerId: peerId) != nil
      frames.removeValue(forKey: peerId)
      return result(payload, hadFrame ? .readEndsFrame : .readAccepted)
    case .cached:
      if let frame = unexpiredFrame(peerId: peerId) {
        // A later frame replaces this one and a later read ends it, so the
        // frame is the newest payload remembered for the peer, and a stale
        // payload is never newer than it.
        if order(payload.revision, frame.payload.revision) == .newer {
          // Herald holds something newer than the frame.
          frames.removeValue(forKey: peerId)
          return result(payload, .cachedNewerThanFrame)
        }
        // After a hello, report the peer as the frame described it.
        return frame.payload.offline
          ? result(nil, .cachedHiddenByGoodbye) : result(frame.payload, .cachedReplacedByHello)
      }
      guard stale, let known = known else { return result(payload, .cachedAccepted) }
      if !known.payload.offline { return result(known.payload, .cachedReplacedByNewest) }
      // The goodbye has run out: likely a restart whose hello never arrived,
      // so believe the reading. Otherwise a fresh read said offline, and
      // this older copy is a relay's.
      return known.fromFrame
        ? result(payload, .cachedBelievedAfterGoodbye) : result(nil, .cachedDroppedAfterOfflineRead)
    }
  }

  /// What is remembered for each peer that still has an unexpired entry,
  /// for the periodic stats line.
  func snapshot() -> [Int: String] {
    lock.lock()
    defer { lock.unlock() }
    var result: [Int: String] = [:]
    for peerId in Set(frames.keys).union(newest.keys) {
      let text = describe(peekNewest(peerId: peerId), peekFrame(peerId: peerId))
      if text != Self.nothingRemembered { result[peerId] = text }
    }
    return result
  }

  func clearAll() {
    lock.lock()
    defer { lock.unlock() }
    frames.removeAll()
    newest.removeAll()
  }

  /// How many peers have an entry, expired or not. For tests.
  func trackedPeerCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return Set(frames.keys).union(newest.keys).count
  }

  private static let nothingRemembered = "nothing remembered"

  /// E.g. `newest rev=17 online (read 3.2s ago) | frame goodbye rev=18 (1.8s
  /// left)`. Call with the lock held.
  private func describe(_ known: Newest?, _ frame: Frame?) -> String {
    if known == nil && frame == nil { return Self.nothingRemembered }
    let time = now()
    var parts: [String] = []
    if let known = known {
      parts.append(
        "newest rev=\(known.payload.revision.map(String.init) ?? "-") "
          + "\(known.payload.offline ? "offline" : "online") "
          + "(\(known.fromFrame ? "frame" : "read") \(Self.seconds(time - known.confirmedAt)) ago)")
    }
    if let frame = frame {
      parts.append(
        "frame \(frame.payload.offline ? "goodbye" : "hello") "
          + "rev=\(frame.payload.revision.map(String.init) ?? "-") "
          + "(\(Self.seconds(frame.lifetime - (time - frame.recordedAt))) left)")
    }
    return parts.joined(separator: " | ")
  }

  private static func seconds(_ value: Double) -> String { String(format: "%.1fs", value) }

  // Lookups for the log: like the two below, but they leave expired entries
  // in place, so logging never changes the state. Call with the lock held.
  private func peekFrame(peerId: Int) -> Frame? {
    guard let entry = frames[peerId], now() - entry.recordedAt <= entry.lifetime else { return nil }
    return entry
  }

  private func peekNewest(peerId: Int) -> Newest? {
    guard let entry = newest[peerId], now() - entry.confirmedAt <= revisionMemorySeconds else {
      return nil
    }
    return entry
  }

  private func lifetime(of frame: Payload) -> Double {
    let fromIphone = frame.deviceKind == Int(StatusPayloadSupplier.deviceKindIOS)
    return frame.offline && fromIphone ? iphoneGoodbyeTtlSeconds : ttlSeconds
  }

  /// Call with the lock held.
  private func unexpiredFrame(peerId: Int) -> Frame? {
    guard let entry = frames[peerId] else { return nil }
    if now() - entry.recordedAt > entry.lifetime {
      frames.removeValue(forKey: peerId)
      return nil
    }
    return entry
  }

  /// Call with the lock held.
  private func unexpiredNewest(peerId: Int) -> Newest? {
    guard let entry = newest[peerId] else { return nil }
    if now() - entry.confirmedAt > revisionMemorySeconds {
      newest.removeValue(forKey: peerId)
      return nil
    }
    return entry
  }

  /// Drops expired entries of peers that are no longer looked up. Call with
  /// the lock held.
  private func sweepIfDue() {
    let time = now()
    guard time - lastSweep > revisionMemorySeconds else { return }
    lastSweep = time
    frames = frames.filter { time - $0.value.recordedAt <= $0.value.lifetime }
    newest = newest.filter { time - $0.value.confirmedAt <= revisionMemorySeconds }
  }

  /// Serial-number comparison of 7-bit revisions: `a` is newer than `b` when
  /// it is 1-63 steps ahead, older when 65-127 ahead. Nil when either is
  /// unknown, or when they are exactly half the range apart.
  private func order(_ a: Int?, _ b: Int?) -> Order? {
    guard let a = a, let b = b else { return nil }
    let distance = (a - b) & StatusPayloadSupplier.revisionMask
    let half = (StatusPayloadSupplier.revisionMask + 1) / 2
    if distance == 0 { return .same }
    if distance < half { return .newer }
    if distance > half { return .older }
    return nil
  }
}
