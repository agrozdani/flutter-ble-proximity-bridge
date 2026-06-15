import Foundation

/// Fakes peer sightings so the whole bridge can run on the iOS simulator,
/// which has no Bluetooth at all. Feeds the same callback the real BLE path
/// uses, so everything downstream behaves exactly the same.
final class MockPeerSource {

  typealias SightingHandler = (
    _ peerId: Int, _ status: Int, _ color: Int, _ deviceKind: Int, _ rssi: Double
  ) -> Void

  private static let tickSeconds = 1.0
  private static let rssiFloor = -95.0
  private static let rssiCeiling = -40.0
  private static let statusChangeProbability = 0.03
  private static let statusCount = 4

  private struct MockPeer {
    let id: Int
    var status: Int
    let color: Int
    let deviceKind: Int
    var rssi: Double
  }

  // One "iPhone" up close, two "Androids" further out. RSSI drifts around
  // so the distance buckets visibly change.
  private var peers = [
    MockPeer(id: 0x51C0_FFEE, status: 0, color: 1, deviceKind: 0, rssi: -50.0),
    MockPeer(id: 0x0B5E_AFE7, status: 2, color: 3, deviceKind: 1, rssi: -72.0),
    MockPeer(id: 0xCAFE_D00D, status: 1, color: 4, deviceKind: 1, rssi: -86.0),
  ]

  private let onSighting: SightingHandler
  private var timer: Timer?

  init(onSighting: @escaping SightingHandler) {
    self.onSighting = onSighting
  }

  /// Must be called on the main thread (the timer needs a live run loop).
  func start() {
    stop()
    timer = Timer.scheduledTimer(withTimeInterval: Self.tickSeconds, repeats: true) {
      [weak self] _ in
      self?.emitAll()
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func emitAll() {
    for index in peers.indices {
      peers[index].rssi = min(
        Self.rssiCeiling,
        max(Self.rssiFloor, peers[index].rssi + Double.random(in: -3.0...3.0)))
      if Double.random(in: 0..<1) < Self.statusChangeProbability {
        peers[index].status = Int.random(in: 0..<Self.statusCount)
      }
      let peer = peers[index]
      onSighting(peer.id, peer.status, peer.color, peer.deviceKind, peer.rssi)
    }
  }
}
