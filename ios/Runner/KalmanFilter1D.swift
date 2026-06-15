import Foundation

/// Basic 1-D Kalman filter, used here to smooth the median RSSI. Seeds
/// itself with the first measurement so it doesn't have to climb up from
/// zero. processNoise sets how fast it follows changes: higher reacts
/// quicker, lower smooths more.
final class KalmanFilter1D {

  private let measurementNoise: Double
  private let processNoise: Double
  private var estimateError: Double
  private var estimate = 0.0
  private var seeded = false

  init(measurementNoise: Double, initialEstimateError: Double, processNoise: Double) {
    precondition(measurementNoise > 0, "measurementNoise must be positive")
    precondition(initialEstimateError > 0, "initialEstimateError must be positive")
    precondition(processNoise >= 0, "processNoise must be non-negative")
    self.measurementNoise = measurementNoise
    self.estimateError = initialEstimateError
    self.processNoise = processNoise
  }

  func update(_ measurement: Double) -> Double {
    if !seeded {
      estimate = measurement
      seeded = true
      return estimate
    }
    let gain = estimateError / (estimateError + measurementNoise)
    let next = estimate + gain * (measurement - estimate)
    estimateError = (1.0 - gain) * estimateError + abs(estimate - next) * processNoise
    estimate = next
    return estimate
  }
}
