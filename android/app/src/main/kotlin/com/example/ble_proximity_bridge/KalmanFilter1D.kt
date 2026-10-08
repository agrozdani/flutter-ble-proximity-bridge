package com.example.ble_proximity_bridge

import kotlin.math.abs

/**
 * Simple 1-D Kalman-style filter, used here to smooth the median RSSI. It
 * seeds itself with the first measurement so it does not start from zero.
 *
 * Not the textbook form: there is no fixed predict step (P += Q). Instead
 * the error estimate grows by processNoise times how far the estimate just
 * moved, so a steady signal is smoothed harder and harder while a real jump
 * re-opens the gain over a dozen or so samples. processNoise controls how quickly
 * it follows changes: higher reacts faster, lower smooths more.
 */
class KalmanFilter1D(
    private val measurementNoise: Double,
    initialEstimateError: Double,
    private val processNoise: Double,
) {
    init {
        require(measurementNoise > 0) { "measurementNoise must be positive" }
        require(initialEstimateError > 0) { "initialEstimateError must be positive" }
        require(processNoise >= 0) { "processNoise must be non-negative" }
    }

    private var estimateError = initialEstimateError
    private var estimate = 0.0
    private var seeded = false

    fun update(measurement: Double): Double {
        if (!seeded) {
            estimate = measurement
            seeded = true
            return estimate
        }
        val gain = estimateError / (estimateError + measurementNoise)
        val next = estimate + gain * (measurement - estimate)
        estimateError =
            (1.0 - gain) * estimateError + abs(estimate - next) * processNoise
        estimate = next
        return estimate
    }
}
