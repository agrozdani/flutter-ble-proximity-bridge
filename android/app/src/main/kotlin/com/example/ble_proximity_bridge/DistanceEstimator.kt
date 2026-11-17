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
class DistanceEstimator(
    /** Monotonic milliseconds; elapsedRealtime ignores clock changes and counts through sleep. */
    private val now: () -> Long = SystemClock::elapsedRealtime,
) {

    companion object {
        /**
         * How long a peer's model outlives its last sample. A backstop:
         * Dart frees the model of every peer it evicts (`forgetPeer`), but
         * only while it is listening. When the service runs with no Dart
         * listener, or a forgetPeer call is lost, a peer that walks away
         * (no goodbye) would otherwise keep its model, and a line in every
         * stats log, until the bridge stops. Longer than Dart's longest
         * eviction window (90 s, for Android receivers), so it never
         * expires a model before Dart would have dropped the peer for
         * silence; a peer Dart keeps listed through payloads without RSSI
         * just starts a fresh model at its next reading.
         */
        const val MODEL_MEMORY_MILLIS = 120_000L

        /** How often expired models are swept, at most. */
        private const val SWEEP_INTERVAL_MILLIS = 10_000L
    }

    /** One estimate and what it was computed from, for the log. */
    data class Estimate(
        val distance: Double,
        val median: Double,
        val smoothed: Double,
        val samples: Int,
        /** True when the sender's iPhone cutoffs were used. */
        val iosCutoffs: Boolean,
    )

    /** A peer's model as of its last sample, for the periodic stats line. */
    data class Snapshot(val peerId: Long, val last: Estimate, val lastSampleAgeMillis: Long)

    private val models = HashMap<Long, PeerModel>()
    private var lastSweepAt: Long? = null

    @Synchronized
    fun clear() {
        models.clear()
    }

    /**
     * Adds one RSSI sample and returns the current estimate (from the first
     * sample on), or null for a NaN sample. One synchronized operation so BLE
     * callbacks cannot interleave.
     */
    fun addSample(peerId: Long, rssi: Double, senderDeviceKind: Int): Double? =
        addSampleDetailed(peerId, rssi, senderDeviceKind)?.distance

    /** [addSample], with the median and smoothed RSSI behind the estimate. */
    @Synchronized
    fun addSampleDetailed(peerId: Long, rssi: Double, senderDeviceKind: Int): Estimate? {
        if (rssi.isNaN()) return null
        val time = now()
        sweepIfDue(time)
        val model = models.getOrPut(peerId) { PeerModel(senderDeviceKind) }
        return model.addAndEstimate(rssi, time)
    }

    /** The number of peers with a model, expired ones included until swept. */
    @get:Synchronized
    val modelCount: Int
        get() = models.size

    @Synchronized
    fun snapshot(): List<Snapshot> {
        val time = now()
        // Every 15 s from the stats line, so a full sweep is cheap here.
        sweep(time)
        return models.mapNotNull { (peerId, model) ->
            val last = model.last ?: return@mapNotNull null
            Snapshot(peerId, last, time - model.lastSampleAt)
        }
    }

    /** Call while synchronized. */
    private fun sweepIfDue(time: Long) {
        val last = lastSweepAt
        if (last != null && time - last < SWEEP_INTERVAL_MILLIS) return
        sweep(time)
    }

    /** Call while synchronized. */
    private fun sweep(time: Long) {
        lastSweepAt = time
        models.values.removeAll { time - it.lastSampleAt > MODEL_MEMORY_MILLIS }
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

        private val iosCutoffs = senderDeviceKind == 0
        private val cutoffs =
            if (iosCutoffs) RSSI_CUTOFFS_IOS_SENDER
            else RSSI_CUTOFFS_ANDROID_SENDER

        var last: Estimate? = null
            private set
        var lastSampleAt = 0L
            private set

        // (now() ms, rssi) pairs. now() is monotonic, so clock changes
        // cannot break the window.
        private val window = ArrayDeque<Pair<Long, Double>>()
        private val kalman = KalmanFilter1D(
            measurementNoise = 2.0,
            initialEstimateError = 2.0,
            processNoise = 0.05,
        )

        fun addAndEstimate(rssi: Double, now: Long): Estimate? {
            window.addLast(now to rssi)
            while (window.size > MAX_SAMPLES) window.removeFirst()
            while (window.isNotEmpty() && now - window.first().first > WINDOW_MILLIS) {
                window.removeFirst()
            }
            if (window.isEmpty()) return null

            val median = medianOf(window.map { it.second })
            val smoothed = kalman.update(median)

            var distance = BUCKETS_METERS.last()
            for (i in cutoffs.indices) {
                if (smoothed > cutoffs[i]) {
                    distance = BUCKETS_METERS[i]
                    break
                }
            }
            return Estimate(distance, median, smoothed, window.size, iosCutoffs).also {
                last = it
                lastSampleAt = now
            }
        }

        private fun medianOf(values: List<Double>): Double {
            val sorted = values.sorted()
            val middle = sorted.size / 2
            return if (sorted.size % 2 == 1) sorted[middle]
            else (sorted[middle - 1] + sorted[middle]) / 2.0
        }
    }
}
