package com.example.ble_proximity_bridge

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Many peers pass by over a long session; their models must not pile up.
 * Same cases as DistanceEstimatorTests in ios/RunnerTests/RunnerTests.swift.
 */
class DistanceEstimatorTest {

    private var clock = 0L
    private val estimator = DistanceEstimator(now = { clock })

    @Test
    fun `a peer that walked away is forgotten after the model memory`() {
        estimator.addSample(1, -60.0, 1)
        estimator.addSample(2, -60.0, 1)

        clock += DistanceEstimator.MODEL_MEMORY_MILLIS
        estimator.addSample(2, -60.0, 1)
        assertEquals(listOf(1L, 2L), estimator.snapshot().map { it.peerId }.sorted())

        clock += 1
        assertEquals(listOf(2L), estimator.snapshot().map { it.peerId })
    }

    @Test
    fun `hundreds of passers-by leave only the recent ones behind`() {
        for (id in 0L until 500L) {
            estimator.addSample(id, -70.0, 0)
            clock += 1_000
        }

        // 500 s of one new peer a second: only about the last 120 remain.
        val remaining = estimator.modelCount
        assert(remaining in 120..131) { "remaining=$remaining" }
    }

    @Test
    fun `a peer that comes back after expiry starts a fresh model`() {
        repeat(5) { estimator.addSample(1, -40.0, 1) }
        clock += DistanceEstimator.MODEL_MEMORY_MILLIS + 20_000

        val estimate = estimator.addSampleDetailed(1, -90.0, 1)!!
        assertEquals(1, estimate.samples)
        assertEquals(-90.0, estimate.median, 0.0)
    }
}
