package com.example.ble_proximity_bridge

import io.heraldprox.herald.sensor.datatype.ImmediateSendData
import io.heraldprox.herald.sensor.datatype.PayloadData
import io.heraldprox.herald.sensor.datatype.Proximity
import io.heraldprox.herald.sensor.datatype.ProximityMeasurementUnit
import io.heraldprox.herald.sensor.datatype.SensorState
import io.heraldprox.herald.sensor.datatype.SensorType
import io.heraldprox.herald.sensor.datatype.TargetIdentifier
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Drives the pipeline through Herald's own delegate callbacks, so how each
 * callback is classified is under test, not just FrameOverrides. Same cases
 * as PayloadPipelineTests in ios/RunnerTests/RunnerTests.swift, plus the
 * replaced-id rule, which only Android has (see PayloadPipeline).
 *
 * The classification tests use payloads without a revision (protocol
 * version 2): with one, a misclassified read could be dropped as stale and
 * hide the mistake.
 */
class PayloadPipelineTest {

    private var active = true
    private var clock = 0L
    private val events = mutableListOf<String>()
    private val malformed = mutableListOf<Int>()
    private val previousOwnIds = mutableSetOf<Long>()

    private val overrides = FrameOverrides(
        ttlMillis = 30_000L,
        iphoneGoodbyeTtlMillis = 5_000L,
        revisionMemoryMillis = 60_000L,
        now = { 0L },
    )

    private val pipeline = PayloadPipeline(
        overrides,
        isActive = { active },
        localPeerId = { LOCAL_ID },
        listener = object : PayloadPipeline.Listener {
            override fun onSighting(
                peerId: Long,
                status: Int,
                color: Int,
                deviceKind: Int,
                rssi: Double?,
            ) {
                events += "peer $peerId status $status rssi $rssi"
            }

            override fun onGone(peerId: Long) {
                events += "gone $peerId"
            }

            override fun onReplaced(oldPeerId: Long, newPeerId: Long) {
                events += "replaced $oldPeerId by $newPeerId"
            }
        },
        onMalformed = { malformed += it },
        now = { clock },
        previousOwnPeerIdAge = { if (it in previousOwnIds) 60_000L else null },
    )

    private val ble = SensorType.BLE
    private val target = TargetIdentifier("target")

    private fun payload(peerId: Long, offline: Boolean = false, status: Int = 1): PayloadData {
        val bytes = ByteArray(16)
        for (i in 0 until 8) bytes[i] = (peerId shr (8 * i)).toByte()
        bytes[8] = status.toByte()
        bytes[10] = StatusPayloadSupplier.DEVICE_KIND_ANDROID.toByte()
        bytes[11] = if (offline) 1 else 0
        bytes[12] = 2 // protocol version 2: no revision
        return PayloadData(bytes)
    }

    private fun reading(rssi: Double) = Proximity(ProximityMeasurementUnit.RSSI, rssi)

    private fun goodbye(peerId: Long) =
        pipeline.sensor(ble, ImmediateSendData(payload(peerId, offline = true)), target)

    @Test
    fun `a reading with a payload is a sighting with its RSSI`() {
        pipeline.sensor(ble, reading(-60.0), target, payload(7))

        assertEquals(listOf("peer 7 status 1 rssi -60.0"), events)
    }

    @Test
    fun `a read is a sighting without RSSI`() {
        pipeline.sensor(ble, payload(7), target)

        assertEquals(listOf("peer 7 status 1 rssi null"), events)
    }

    @Test
    fun `a frame is reported as it arrived`() {
        goodbye(7)

        assertEquals(listOf("gone 7"), events)
    }

    @Test
    fun `a reading is cached, so it cannot undo a goodbye`() {
        goodbye(7)
        pipeline.sensor(ble, reading(-60.0), target, payload(7))

        assertEquals(listOf("gone 7"), events)
    }

    @Test
    fun `a read is fresh, so it ends a goodbye`() {
        goodbye(7)
        pipeline.sensor(ble, payload(7), target)

        assertEquals(listOf("gone 7", "peer 7 status 1 rssi null"), events)
    }

    @Test
    fun `relayed payloads are cached`() {
        goodbye(7)
        pipeline.sensor(ble, listOf(payload(7), payload(8)), target)

        assertEquals(listOf("gone 7", "peer 8 status 1 rssi null"), events)
    }

    @Test
    fun `our own payload is dropped without being recorded`() {
        goodbye(LOCAL_ID)
        pipeline.sensor(ble, reading(-60.0), target, payload(LOCAL_ID))
        pipeline.sensor(ble, payload(LOCAL_ID), target)

        assertEquals(emptyList<String>(), events)
        // Dropped before FrameOverrides saw it, so it left nothing behind.
        assertEquals(0, overrides.trackedPeerCount())
    }

    @Test
    fun `a payload with one of our earlier ids is dropped without being recorded`() {
        previousOwnIds += 42L
        goodbye(42)
        pipeline.sensor(ble, reading(-60.0), target, payload(42))
        pipeline.sensor(ble, payload(42), target)
        // The case seen on hardware: a relay hands it over.
        pipeline.sensor(ble, listOf(payload(42), payload(8)), target)

        assertEquals(listOf("peer 8 status 1 rssi null"), events)
        // Dropped before FrameOverrides saw it, so it left nothing behind.
        assertEquals(0, overrides.trackedPeerCount())
    }

    @Test
    fun `while inactive nothing is reported, but frames are still recorded`() {
        active = false
        goodbye(7)
        pipeline.sensor(ble, reading(-60.0), target, payload(8))
        assertEquals(emptyList<String>(), events)

        // After the next start, Herald's cached online copy of peer 7 must
        // still lose to the goodbye that arrived while we were stopped.
        active = true
        pipeline.sensor(ble, reading(-60.0), target, payload(7))
        pipeline.sensor(ble, reading(-61.0), target, payload(8))
        assertEquals(listOf("peer 8 status 1 rssi -61.0"), events)
    }

    @Test
    fun `while inactive a read is still recorded`() {
        goodbye(7)
        active = false
        // Read afresh while we are stopped: it ends the goodbye.
        pipeline.sensor(ble, payload(7), target)
        assertEquals(listOf("gone 7"), events)

        // So after the next start, Herald's copy of that read is reported.
        active = true
        pipeline.sensor(ble, reading(-60.0), target, payload(7))
        assertEquals(listOf("gone 7", "peer 7 status 1 rssi -60.0"), events)
    }

    @Test
    fun `a malformed payload is dropped and logged`() {
        pipeline.sensor(ble, PayloadData(ByteArray(15)), target)

        assertEquals(emptyList<String>(), events)
        assertEquals(listOf(15), malformed)
    }

    @Test
    fun `callbacks without a payload are ignored`() {
        pipeline.sensor(ble, target)
        pipeline.sensor(ble, true, target)
        pipeline.sensor(ble, reading(-60.0), target)
        pipeline.sensor(ble, SensorState.on)

        assertEquals(emptyList<String>(), events)
    }

    @Test
    fun `a read of another id from the same device retires the old id`() {
        pipeline.sensor(ble, payload(7), target)
        // The app on that device restarted: Herald still hands over its copy
        // of the last read until it reads the device again.
        clock += 60_000L
        pipeline.sensor(ble, reading(-60.0), target, payload(7))
        clock += 30_000L
        pipeline.sensor(ble, payload(8), target)

        assertEquals(
            listOf(
                "peer 7 status 1 rssi null",
                "peer 7 status 1 rssi -60.0",
                "replaced 7 by 8",
                "peer 8 status 1 rssi null",
            ),
            events,
        )
    }

    @Test
    fun `reads of two devices do not retire each other`() {
        pipeline.sensor(ble, payload(7), target)
        pipeline.sensor(ble, payload(8), TargetIdentifier("other"))
        pipeline.sensor(ble, payload(7), target)

        assertEquals(
            listOf(
                "peer 7 status 1 rssi null",
                "peer 8 status 1 rssi null",
                "peer 7 status 1 rssi null",
            ),
            events,
        )
    }

    @Test
    fun `a cached copy of another id does not retire the old one`() {
        pipeline.sensor(ble, payload(7), target)
        pipeline.sensor(ble, reading(-60.0), target, payload(8))

        assertEquals(listOf("peer 7 status 1 rssi null", "peer 8 status 1 rssi -60.0"), events)
    }

    @Test
    fun `a read is remembered only as long as Herald keeps the device`() {
        pipeline.sensor(ble, payload(7), target)
        clock += 15 * 60_000L + 1
        pipeline.sensor(ble, payload(8), target)

        assertEquals(listOf("peer 7 status 1 rssi null", "peer 8 status 1 rssi null"), events)
    }

    @Test
    fun `while inactive a replaced id is not reported, and is not reported later`() {
        pipeline.sensor(ble, payload(7), target)
        active = false
        pipeline.sensor(ble, payload(8), target)
        active = true
        pipeline.sensor(ble, payload(8), target)

        assertEquals(listOf("peer 7 status 1 rssi null", "peer 8 status 1 rssi null"), events)
    }

    private companion object {
        const val LOCAL_ID = 99L
    }
}
