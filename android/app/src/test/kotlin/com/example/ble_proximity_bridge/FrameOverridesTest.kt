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
        revisionMemoryMillis = 60_000L,
        now = { clock },
    )

    // Sent by an Android device, so its frames get the full lifetime. These
    // carry no revision (a sender before protocol version 3): the tests up
    // to the revision section pin the frame rule on its own.
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

    // ----- Revisions (protocol version 3) ----------------------------------

    private fun rev(revision: Int, offline: Boolean = false) =
        online.copy(offline = offline, revision = revision)

    private fun iphoneRev(revision: Int, offline: Boolean = false) =
        iphoneOnline.copy(offline = offline, revision = revision)

    @Test
    fun `a frame older than a payload already seen is dropped`() {
        // A goodbye that was stuck in the sender's queue arrives after a
        // read of its newer, online payload.
        assertEquals(rev(5), overrides.resolve(7, Source.READ, rev(5)))

        assertNull(overrides.resolve(7, Source.FRAME, rev(4, offline = true)))
        assertEquals(rev(5), overrides.resolve(7, Source.CACHED, rev(5)))
    }

    @Test
    fun `a read older than the frame does not end it`() {
        overrides.resolve(7, Source.FRAME, rev(5, offline = true))

        // Read just before the goodbye, delivered just after it.
        assertNull(overrides.resolve(7, Source.READ, rev(4)))
        assertNull(overrides.resolve(7, Source.CACHED, rev(4)))
    }

    @Test
    fun `a stale relayed copy is ignored after a fresh offline read`() {
        assertEquals(rev(6, offline = true), overrides.resolve(7, Source.READ, rev(6, offline = true)))

        // A relay still holds the online payload from before the stop.
        assertNull(overrides.resolve(7, Source.READ, rev(5)))
        assertNull(overrides.resolve(7, Source.CACHED, rev(5)))
    }

    @Test
    fun `a stale offline copy does not remove a live peer`() {
        overrides.resolve(7, Source.READ, rev(7))

        // A relay still holds the offline payload from before a restart.
        assertNull(overrides.resolve(7, Source.READ, rev(6, offline = true)))
        assertEquals(rev(7), overrides.resolve(7, Source.CACHED, rev(6, offline = true)))
    }

    @Test
    fun `after an iPhone goodbye runs out, an older cached payload is believed`() {
        overrides.resolve(7, Source.FRAME, iphoneRev(9, offline = true))

        clock = 5_000L
        assertNull(overrides.resolve(7, Source.CACHED, iphoneRev(8)))

        // Readings again: most likely a restart whose hello never arrived.
        clock = 5_001L
        assertEquals(iphoneRev(8), overrides.resolve(7, Source.CACHED, iphoneRev(8)))
    }

    @Test
    fun `a cached payload newer than the frame ends it`() {
        overrides.resolve(7, Source.FRAME, rev(3, offline = true))

        assertEquals(rev(4), overrides.resolve(7, Source.CACHED, rev(4)))
        assertEquals(rev(4), overrides.resolve(7, Source.CACHED, rev(4)))
    }

    @Test
    fun `revisions wrap around`() {
        overrides.resolve(7, Source.READ, rev(127))

        // 0 follows 127.
        assertEquals(rev(0, offline = true), overrides.resolve(7, Source.FRAME, rev(0, offline = true)))
        assertNull(overrides.resolve(7, Source.READ, rev(127)))
    }

    @Test
    fun `revisions half the range apart are not ordered`() {
        overrides.resolve(7, Source.READ, rev(0))

        // Neither newer nor older, so not dropped.
        assertEquals(rev(64, offline = true), overrides.resolve(7, Source.FRAME, rev(64, offline = true)))
    }

    @Test
    fun `a payload without a revision is never stale`() {
        overrides.resolve(7, Source.READ, rev(10))

        assertEquals(offline, overrides.resolve(7, Source.FRAME, offline))
    }

    @Test
    fun `the newest revision is remembered while it keeps being confirmed`() {
        overrides.resolve(7, Source.READ, rev(10))

        clock = 50_000L
        overrides.resolve(7, Source.CACHED, rev(10))

        clock = 110_000L
        assertNull(overrides.resolve(7, Source.FRAME, rev(9, offline = true)))

        // Not confirmed for longer than the memory: forgotten.
        clock = 170_001L
        assertEquals(rev(9, offline = true), overrides.resolve(7, Source.FRAME, rev(9, offline = true)))
    }

    @Test
    fun `a revision not confirmed within the memory is forgotten between sweeps`() {
        clock = 50_000L
        overrides.resolve(7, Source.READ, rev(10))
        // Another peer's payload at 100 s runs the periodic sweep, which
        // keeps peer 7's 50 s old entry.
        clock = 100_000L
        overrides.resolve(8, Source.READ, rev(1))

        // At 120 s peer 7's entry is 70 s old; the next sweep is not due, so
        // the lookup itself must notice it has expired.
        clock = 120_000L
        assertEquals(rev(9, offline = true), overrides.resolve(7, Source.FRAME, rev(9, offline = true)))
    }

    @Test
    fun `clearAll also forgets revisions`() {
        overrides.resolve(7, Source.READ, rev(10))

        overrides.clearAll()
        assertEquals(rev(9, offline = true), overrides.resolve(7, Source.FRAME, rev(9, offline = true)))
    }
}
