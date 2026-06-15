package com.example.ble_proximity_bridge

import android.os.SystemClock

/**
 * Turns raw per-peer RSSI samples into rough distance estimates.
 *
 * Per peer: keep a sliding window of recent samples, take the median to
 * drop outliers, smooth it with a Kalman filter, then map it to a distance
 * bucket. The output is a bucket (0.5 / 1.5 / 3.5 / 8.0 m) on purpose:
 * RSSI jumps around too much for anything more precise.
 */
class DistanceEstimator {

    private val models = HashMap<Long, PeerModel>()

    @Synchronized
    fun clear() {
        models.clear()
    }

    /**
     * Adds one RSSI sample and returns the current estimate, or null until
     * there is enough data. One synchronized operation so BLE callbacks
     * cannot interleave.
     */
    @Synchronized
    fun addSample(peerId: Long, rssi: Double, senderDeviceKind: Int): Double? {
        if (rssi.isNaN()) return null
        val model = models.getOrPut(peerId) { PeerModel(senderDeviceKind) }
        return model.addAndEstimate(rssi)
    }

    /** Frees the model for a peer that left. */
    @Synchronized
    fun forget(peerId: Long) {
        models.remove(peerId)
    }

    private class PeerModel(senderDeviceKind: Int) {
        companion object {
            private const val MAX_SAMPLES = 20
            private const val WINDOW_MILLIS = 30_000L

            // Cutoffs depend on who sent the signal: iPhones usually read
            // hotter than Android phones at the same distance.
            private val RSSI_CUTOFFS_IOS_SENDER = doubleArrayOf(-55.0, -65.0, -75.0)
            private val RSSI_CUTOFFS_ANDROID_SENDER = doubleArrayOf(-70.0, -80.0, -90.0)

            private val BUCKETS_METERS = doubleArrayOf(0.5, 1.5, 3.5, 8.0)
        }

        private val cutoffs =
            if (senderDeviceKind == 0) RSSI_CUTOFFS_IOS_SENDER
            else RSSI_CUTOFFS_ANDROID_SENDER

        // (elapsedRealtime ms, rssi) pairs. elapsedRealtime is monotonic,
        // so clock changes cannot break the window.
        private val window = ArrayDeque<Pair<Long, Double>>()
        private val kalman = KalmanFilter1D(
            measurementNoise = 2.0,
            initialEstimateError = 2.0,
            processNoise = 0.05,
        )

        fun addAndEstimate(rssi: Double): Double? {
            val now = SystemClock.elapsedRealtime()
            window.addLast(now to rssi)
            while (window.size > MAX_SAMPLES) window.removeFirst()
            while (window.isNotEmpty() && now - window.first().first > WINDOW_MILLIS) {
                window.removeFirst()
            }
            if (window.isEmpty()) return null

            val median = medianOf(window.map { it.second })
            val smoothed = kalman.update(median)

            for (i in cutoffs.indices) {
                if (smoothed > cutoffs[i]) return BUCKETS_METERS[i]
            }
            return BUCKETS_METERS.last()
        }

        private fun medianOf(values: List<Double>): Double {
            val sorted = values.sorted()
            val middle = sorted.size / 2
            return if (sorted.size % 2 == 1) sorted[middle]
            else (sorted[middle - 1] + sorted[middle]) / 2.0
        }
    }
}
