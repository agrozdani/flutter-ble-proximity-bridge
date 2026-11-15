import Foundation

/// Decides which payload to believe for a peer: the one Herald just handed
/// over, or what the peer last announced in a goodbye/hello frame.
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

  /// The decoded fields of one payload.
  struct Payload: Equatable {
    var status: Int
    var color: Int
    var deviceKind: Int
    var offline: Bool
  }

  private let ttlSeconds: Double
  private let iphoneGoodbyeTtlSeconds: Double
  private let now: () -> Double
  private let lock = NSLock()
  private var entries: [Int: (frame: Payload, recordedAt: Double, lifetime: Double)] = [:]

  /// `ttlSeconds` is how long a frame outvotes cached payloads if no fresh
  /// read ends it; `iphoneGoodbyeTtlSeconds` the same for a goodbye sent by
  /// an iPhone. `now` is a monotonic clock in seconds; tests inject their own.
  init(
    ttlSeconds: Double,
    iphoneGoodbyeTtlSeconds: Double,
    now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.ttlSeconds = ttlSeconds
    self.iphoneGoodbyeTtlSeconds = iphoneGoodbyeTtlSeconds
    self.now = now
  }

  /// Returns the payload to act on for this peer, or nil when `payload` must
  /// be ignored: a cached copy of a peer whose goodbye frame was already
  /// reported.
  func resolve(peerId: Int, source: Source, payload: Payload) -> Payload? {
    lock.lock()
    defer { lock.unlock() }
    switch source {
    case .read:
      // Newer than any frame, so the frame's job is done.
      entries.removeValue(forKey: peerId)
    case .frame:
      entries[peerId] = (payload, now(), lifetime(of: payload))
    case .cached:
      guard let frame = unexpiredFrame(peerId: peerId) else { return payload }
      // After a hello, report the peer as the frame described it.
      return frame.offline ? nil : frame
    }
    return payload
  }

  func clearAll() {
    lock.lock()
    defer { lock.unlock() }
    entries.removeAll()
  }

  private func lifetime(of frame: Payload) -> Double {
    let fromIphone = frame.deviceKind == Int(StatusPayloadSupplier.deviceKindIOS)
    return frame.offline && fromIphone ? iphoneGoodbyeTtlSeconds : ttlSeconds
  }

  /// Call with the lock held.
  private func unexpiredFrame(peerId: Int) -> Payload? {
    guard let entry = entries[peerId] else { return nil }
    if now() - entry.recordedAt > entry.lifetime {
      entries.removeValue(forKey: peerId)
      return nil
    }
    return entry.frame
  }
}
