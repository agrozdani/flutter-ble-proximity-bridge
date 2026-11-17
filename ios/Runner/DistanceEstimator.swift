import Foundation

/// Turns raw per-peer RSSI samples into rough distance estimates.
///
/// Per peer: keep a sliding window of recent samples, take the median to
/// kill outliers, smooth it with a Kalman filter, then map the result to a
/// distance bucket. The output is a bucket (0.5 / 1.5 / 3.5 / 8.0 m) on
/// purpose: RSSI jumps around several dB at a fixed distance, so anything
/// more precise would just be noise.
final class DistanceEstimator {

  /// One estimate and what it was computed from, for the log.
  struct Estimate {
    let distance: Double
    let median: Double
    let smoothed: Double
    let samples: Int
    /// True when the sender's iPhone cutoffs were used.
    let iosCutoffs: Bool
  }

  /// A peer's model as of its last sample, for the periodic stats line.
  struct Snapshot {
    let peerId: Int
    let last: Estimate
    let lastSampleAge: Double
  }

  /// How long a peer's model outlives its last sample. A peer that walks
  /// away sends no goodbye, so without this every passer-by's model would
  /// stay, and be listed in every stats line, until the bridge stops. Longer
  /// than Dart's longest eviction window (90 s, for Android receivers), so a
  /// model only expires once its peer has sent no RSSI reading for longer
  /// than Dart would keep a silent peer. A peer kept listed meanwhile by
  /// reads or relays alone (they carry no RSSI here) just starts a fresh
  /// model at its next reading.
  static let modelMemorySeconds = 120.0

  /// How often expired models are swept, at most.
  private static let sweepIntervalSeconds = 10.0

  private let now: () -> Double
  private let lock = NSLock()
  private var models: [Int: PeerModel] = [:]
  private var lastSweepAt: Double?

  init(now: @escaping () -> Double = MonotonicClock.seconds) {
    self.now = now
  }

  /// Drops all per-peer history. Called when the bridge stops.
  func clear() {
    lock.lock()
    defer { lock.unlock() }
    models.removeAll()
  }

  /// Adds one RSSI sample and returns the current estimate (from the first
  /// sample on), or nil for a NaN sample. One locked operation so concurrent
  /// BLE callbacks can't interleave.
  func addSample(peerId: Int, rssi: Double, senderDeviceKind: Int) -> Double? {
    addSampleDetailed(peerId: peerId, rssi: rssi, senderDeviceKind: senderDeviceKind)?.distance
  }

  /// `addSample`, with the median and smoothed RSSI behind the estimate.
  func addSampleDetailed(peerId: Int, rssi: Double, senderDeviceKind: Int) -> Estimate? {
    guard !rssi.isNaN else { return nil }
    lock.lock()
    defer { lock.unlock() }
    let time = now()
    sweepIfDue(time)
    let model: PeerModel
    if let existing = models[peerId] {
      model = existing
    } else {
      model = PeerModel(senderDeviceKind: senderDeviceKind)
      models[peerId] = model
    }
    return model.addAndEstimate(rssi, now: time)
  }

  /// The number of peers with a model, expired ones included until swept.
  var modelCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return models.count
  }

  /// Frees the model for a peer that left.
  func forget(peerId: Int) {
    lock.lock()
    defer { lock.unlock() }
    models.removeValue(forKey: peerId)
  }

  func snapshot() -> [Snapshot] {
    lock.lock()
    defer { lock.unlock() }
    let time = now()
    // Every 15 s from the stats line, so a full sweep is cheap here.
    sweep(time)
    return models.compactMap { peerId, model in
      model.last.map {
        Snapshot(peerId: peerId, last: $0, lastSampleAge: time - model.lastSampleAt)
      }
    }
  }

  /// Call with the lock held.
  private func sweepIfDue(_ time: Double) {
    if let last = lastSweepAt, time - last < Self.sweepIntervalSeconds { return }
    sweep(time)
  }

  /// Call with the lock held.
  private func sweep(_ time: Double) {
    lastSweepAt = time
    models = models.filter { time - $0.value.lastSampleAt <= Self.modelMemorySeconds }
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
    private let iosCutoffs: Bool
    private(set) var last: Estimate?
    private(set) var lastSampleAt: Double = 0

    // (monotonic seconds, rssi) pairs. MonotonicClock ignores wall-clock
    // changes and keeps counting while the device sleeps, so neither can
    // distort the window.
    private var window: [(time: Double, rssi: Double)] = []
    private let kalman = KalmanFilter1D(
      measurementNoise: 2.0,
      initialEstimateError: 2.0,
      processNoise: 0.05
    )

    init(senderDeviceKind: Int) {
      iosCutoffs = senderDeviceKind == 0
      cutoffs =
        iosCutoffs
        ? PeerModel.rssiCutoffsIOSSender
        : PeerModel.rssiCutoffsAndroidSender
    }

    func addAndEstimate(_ rssi: Double, now: Double) -> Estimate? {
      window.append((time: now, rssi: rssi))
      if window.count > PeerModel.maxSamples {
        window.removeFirst(window.count - PeerModel.maxSamples)
      }
      window.removeAll { now - $0.time > PeerModel.windowSeconds }
      guard !window.isEmpty else { return nil }

      let median = medianOf(window.map { $0.rssi })
      let smoothed = kalman.update(median)

      var distance = PeerModel.bucketsMeters[PeerModel.bucketsMeters.count - 1]
      for (index, cutoff) in cutoffs.enumerated() where smoothed > cutoff {
        distance = PeerModel.bucketsMeters[index]
        break
      }
      let estimate = Estimate(
        distance: distance, median: median, smoothed: smoothed, samples: window.count,
        iosCutoffs: iosCutoffs)
      last = estimate
      lastSampleAt = now
      return estimate
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
