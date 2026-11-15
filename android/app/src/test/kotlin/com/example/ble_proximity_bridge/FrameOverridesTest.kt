package com.example.ble_proximity_bridge

import com.example.ble_proximity_bridge.FrameOverrides.Payload
import com.example.ble_proximity_bridge.FrameOverrides.Source
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Same cases as FrameOverridesTests in ios/RunnerTests/RunnerTests.swift. */
class FrameOverridesTest {

    private var clock = 0L
    private val overrides = FrameOverrides(
        ttlMillis = 30_000L,
        iphoneGoodbyeTtlMillis = 5_000L,
        now = { clock },
    )

    // Sent by an Android device, so its frames get the full lifetime.
    private val online = Payload(
        status = 1,
        color = 2,
        deviceKind = StatusPayloadSupplier.DEVICE_KIND_ANDROID,
        offline = false,
    )
    private val offline = online.copy(offline = true)
    private val onlineNewStatus = online.copy(status = 3)

    private val iphoneOnline = online.copy(deviceKind = StatusPayloadSupplier.DEVICE_KIND_IOS)
    private val iphoneOffline = iphoneOnline.copy(offline = true)

    @Test
    fun `without a frame every payload is taken at face value`() {
        assertEquals(online, overrides.resolve(7, Source.CACHED, online))
        assertEquals(offline, overrides.resolve(7, Source.CACHED, offline))
        assertEquals(online, overrides.resolve(7, Source.READ, online))
    }

    @Test
    fun `a frame is reported as it arrived`() {
        assertEquals(offline, overrides.resolve(7, Source.FRAME, offline))
        assertEquals(online, overrides.resolve(7, Source.FRAME, online))
    }

    @Test
    fun `after a goodbye the cached online payload is ignored`() {
        overrides.resolve(7, Source.FRAME, offline)

        assertNull(overrides.resolve(7, Source.CACHED, online))
        // Still ignored on later readings, and without reporting gone again.
        assertNull(overrides.resolve(7, Source.CACHED, online))
        assertNull(overrides.resolve(7, Source.CACHED, offline))
    }

    @Test
    fun `after a hello the cached offline payload does not remove the peer`() {
        overrides.resolve(7, Source.FRAME, onlineNewStatus)

        // The reading is kept, described by the frame rather than the cache.
        assertEquals(onlineNewStatus, overrides.resolve(7, Source.CACHED, offline))
        assertEquals(onlineNewStatus, overrides.resolve(7, Source.CACHED, online))
    }

    @Test
    fun `a fresh read ends the override`() {
        overrides.resolve(7, Source.FRAME, offline)

        assertEquals(online, overrides.resolve(7, Source.READ, online))
        assertEquals(online, overrides.resolve(7, Source.CACHED, online))
    }

    @Test
    fun `a fresh offline read is reported and ends a hello override`() {
        overrides.resolve(7, Source.FRAME, online)

        assertEquals(offline, overrides.resolve(7, Source.READ, offline))
        assertEquals(offline, overrides.resolve(7, Source.CACHED, offline))
    }

    @Test
    fun `an override expires if no fresh read replaces it`() {
        overrides.resolve(7, Source.FRAME, offline)

        clock = 30_000L
        assertNull(overrides.resolve(7, Source.CACHED, online))

        clock = 30_001L
        assertEquals(online, overrides.resolve(7, Source.CACHED, online))
        // Expiry removed the entry rather than just hiding it.
        clock = 0L
        assertEquals(online, overrides.resolve(7, Source.CACHED, online))
    }

    @Test
    fun `a goodbye from an iPhone expires after its shorter lifetime`() {
        overrides.resolve(7, Source.FRAME, iphoneOffline)

        clock = 5_000L
        assertNull(overrides.resolve(7, Source.CACHED, iphoneOnline))

        // A restart the hello never announced shows up again.
        clock = 5_001L
        assertEquals(iphoneOnline, overrides.resolve(7, Source.CACHED, iphoneOnline))
    }

    @Test
    fun `a hello from an iPhone keeps the full lifetime`() {
        overrides.resolve(7, Source.FRAME, iphoneOffline)
        clock = 1_000L
        overrides.resolve(7, Source.FRAME, iphoneOnline)

        clock = 31_000L
        assertEquals(iphoneOnline, overrides.resolve(7, Source.CACHED, iphoneOffline))

        clock = 31_001L
        assertEquals(iphoneOffline, overrides.resolve(7, Source.CACHED, iphoneOffline))
    }

    @Test
    fun `a newer frame replaces the older one and restarts its lifetime`() {
        overrides.resolve(7, Source.FRAME, offline)
        clock = 20_000L
        overrides.resolve(7, Source.FRAME, online)

        clock = 45_000L
        assertEquals(online, overrides.resolve(7, Source.CACHED, offline))
    }

    @Test
    fun `overrides are kept per peer and dropped by clearAll`() {
        overrides.resolve(7, Source.FRAME, offline)

        assertEquals(online, overrides.resolve(8, Source.CACHED, online))
        assertNull(overrides.resolve(7, Source.CACHED, online))

        overrides.clearAll()
        assertEquals(online, overrides.resolve(7, Source.CACHED, online))
    }
}
