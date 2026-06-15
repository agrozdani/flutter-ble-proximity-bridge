import Foundation

/// Turns raw per-peer RSSI samples into rough distance estimates.
///
/// Per peer: keep a sliding window of recent samples, take the median to
/// kill outliers, smooth it with a Kalman filter, then map the result to a
/// distance bucket. The output is a bucket (0.5 / 1.5 / 3.5 / 8.0 m) on
/// purpose: RSSI jumps around several dB at a fixed distance, so anything
/// more precise would just be noise.
final class DistanceEstimator {

  private let lock = NSLock()
  private var models: [Int: PeerModel] = [:]

  /// Drops all per-peer history. Called when the bridge stops.
  func clear() {
    lock.lock()
    defer { lock.unlock() }
    models.removeAll()
  }

  /// Adds one RSSI sample and returns the current estimate, or nil until
  /// there's enough data. One locked operation so concurrent BLE callbacks
  /// can't interleave.
  func addSample(peerId: Int, rssi: Double, senderDeviceKind: Int) -> Double? {
    guard !rssi.isNaN else { return nil }
    lock.lock()
    defer { lock.unlock() }
    let model: PeerModel
    if let existing = models[peerId] {
      model = existing
    } else {
      model = PeerModel(senderDeviceKind: senderDeviceKind)
      models[peerId] = model
    }
    return model.addAndEstimate(rssi)
  }

  /// Frees the model for a peer that left.
  func forget(peerId: Int) {
    lock.lock()
    defer { lock.unlock() }
    models.removeValue(forKey: peerId)
  }

  private final class PeerModel {
    private static let maxSamples = 20
    private static let windowSeconds = 30.0

    // Cutoffs depend on who sent the signal: iPhones read hotter than most
    // Androids at the same distance.
    private static let rssiCutoffsIOSSender = [-55.0, -65.0, -75.0]
    private static let rssiCutoffsAndroidSender = [-70.0, -80.0, -90.0]

    private static let bucketsMeters = [0.5, 1.5, 3.5, 8.0]

    private let cutoffs: [Double]

    // (uptime seconds, rssi) pairs. systemUptime is monotonic, so clock
    // changes can't mess up the window.
    private var window: [(time: Double, rssi: Double)] = []
    private let kalman = KalmanFilter1D(
      measurementNoise: 2.0,
      initialEstimateError: 2.0,
      processNoise: 0.05
    )

    init(senderDeviceKind: Int) {
      cutoffs =
        senderDeviceKind == 0
        ? PeerModel.rssiCutoffsIOSSender
        : PeerModel.rssiCutoffsAndroidSender
    }

    func addAndEstimate(_ rssi: Double) -> Double? {
      let now = ProcessInfo.processInfo.systemUptime
      window.append((time: now, rssi: rssi))
      if window.count > PeerModel.maxSamples {
        window.removeFirst(window.count - PeerModel.maxSamples)
      }
      window.removeAll { now - $0.time > PeerModel.windowSeconds }
      guard !window.isEmpty else { return nil }

      let median = medianOf(window.map { $0.rssi })
      let smoothed = kalman.update(median)

      for (index, cutoff) in cutoffs.enumerated() where smoothed > cutoff {
        return PeerModel.bucketsMeters[index]
      }
      return PeerModel.bucketsMeters.last
    }

    private func medianOf(_ values: [Double]) -> Double {
      let sorted = values.sorted()
      let middle = sorted.count / 2
      if sorted.count % 2 == 1 {
        return sorted[middle]
      }
      return (sorted[middle - 1] + sorted[middle]) / 2.0
    }
  }
}
