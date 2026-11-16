package com.example.ble_proximity_bridge

import io.heraldprox.herald.sensor.datatype.Data
import io.heraldprox.herald.sensor.datatype.PayloadTimestamp
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the 16-byte wire format. RunnerTests.swift on iOS holds the same byte
 * arrays: each platform's encoder must produce its own pairs exactly, and
 * its decoder is run on the other platform's pairs, so the two codecs are
 * checked against each other.
 */
class StatusPayloadSupplierTest {

    private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }

    // Peer id 0x51C0FFEE (three of its bytes are >= 0x80, so a decoder that
    // sign-extends bytes fails), status 2, color 5, protocol version 3.
    // Flags 0x04: revision 2, online. 0x07: revision 3, offline.
    private val androidOnline = bytes(
        0xEE, 0xFF, 0xC0, 0x51, 0, 0, 0, 0, // peer id, little-endian
        2, // status
        5, // color
        1, // device kind: Android
        0x04, // flags: revision << 1 | offline
        3, 0, 0, 0, // protocol version
    )
    private val androidOffline =
        bytes(0xEE, 0xFF, 0xC0, 0x51, 0, 0, 0, 0, 2, 5, 1, 0x07, 3, 0, 0, 0)
    private val iosOnline =
        bytes(0xEE, 0xFF, 0xC0, 0x51, 0, 0, 0, 0, 2, 5, 0, 0x04, 3, 0, 0, 0)
    private val iosOffline =
        bytes(0xEE, 0xFF, 0xC0, 0x51, 0, 0, 0, 0, 2, 5, 0, 0x07, 3, 0, 0, 0)

    // The same payload at revision 127 (flags 0xFE, top bit set) and, once
    // the counter has wrapped, at revision 0 offline (flags 0x01).
    private val androidRevision127 =
        bytes(0xEE, 0xFF, 0xC0, 0x51, 0, 0, 0, 0, 2, 5, 1, 0xFE, 3, 0, 0, 0)
    private val androidRevision0Offline =
        bytes(0xEE, 0xFF, 0xC0, 0x51, 0, 0, 0, 0, 2, 5, 1, 0x01, 3, 0, 0, 0)
    private val iosRevision127 =
        bytes(0xEE, 0xFF, 0xC0, 0x51, 0, 0, 0, 0, 2, 5, 0, 0xFE, 3, 0, 0, 0)
    private val iosRevision0Offline =
        bytes(0xEE, 0xFF, 0xC0, 0x51, 0, 0, 0, 0, 2, 5, 0, 0x01, 3, 0, 0, 0)

    @Test
    fun `encodes the documented layout`() {
        // A fresh counter: the supplier takes revision 1, the update 2, and
        // going offline 3.
        val supplier = StatusPayloadSupplier(0x51C0FFEEL, RevisionCounter())
        supplier.update(2, 5)

        assertArrayEquals(androidOnline, supplier.payload(PayloadTimestamp(), null).value)

        supplier.setOffline(true)
        assertArrayEquals(androidOffline, supplier.currentFrame().value)
    }

    @Test
    fun `decodes the bytes the iOS encoder produces`() {
        val online = Data(iosOnline)
        assertEquals(0x51C0FFEEL, StatusPayloadSupplier.peerIdFrom(online))
        assertEquals(2, StatusPayloadSupplier.statusFrom(online))
        assertEquals(5, StatusPayloadSupplier.colorFrom(online))
        assertEquals(0, StatusPayloadSupplier.deviceKindFrom(online))
        assertEquals(false, StatusPayloadSupplier.isOfflineFrom(online))
        assertEquals(2, StatusPayloadSupplier.revisionFrom(online))
        assertEquals(3L, StatusPayloadSupplier.versionFrom(online))

        val offline = Data(iosOffline)
        assertEquals(0x51C0FFEEL, StatusPayloadSupplier.peerIdFrom(offline))
        assertEquals(true, StatusPayloadSupplier.isOfflineFrom(offline))
        assertEquals(3, StatusPayloadSupplier.revisionFrom(offline))
    }

    @Test
    fun `a revision of 64 or more sets the top bit of the flags`() {
        val revisions = RevisionCounter()
        repeat(125) { revisions.next() }
        val supplier = StatusPayloadSupplier(0x51C0FFEEL, revisions) // revision 126
        supplier.update(2, 5) // 127

        assertArrayEquals(androidRevision127, supplier.currentFrame().value)
        supplier.setOffline(true) // wraps to 0
        assertArrayEquals(androidRevision0Offline, supplier.currentFrame().value)

        val top = Data(iosRevision127)
        assertEquals(127, StatusPayloadSupplier.revisionFrom(top))
        assertEquals(false, StatusPayloadSupplier.isOfflineFrom(top))
        val wrapped = Data(iosRevision0Offline)
        assertEquals(0, StatusPayloadSupplier.revisionFrom(wrapped))
        assertEquals(true, StatusPayloadSupplier.isOfflineFrom(wrapped))
    }

    @Test
    fun `a status change that does not reach the wire takes no revision`() {
        val supplier = StatusPayloadSupplier(1L, RevisionCounter())
        fun revision() = StatusPayloadSupplier.revisionFrom(supplier.currentFrame())

        supplier.update(300, 0)
        assertEquals(2, revision())
        assertEquals(255, StatusPayloadSupplier.statusFrom(supplier.currentFrame()))
        // Also 255 on the wire.
        supplier.update(301, 0)
        assertEquals(2, revision())
    }

    @Test
    fun `a version 2 payload has no revision`() {
        // Version 2 left flags bits 1-7 at 0, so they must not read as one.
        val data = Data(bytes(0xEE, 0xFF, 0xC0, 0x51, 0, 0, 0, 0, 2, 5, 0, 1, 2, 0, 0, 0))

        assertNull(StatusPayloadSupplier.revisionFrom(data))
        assertEquals(true, StatusPayloadSupplier.isOfflineFrom(data))
    }

    @Test
    fun `only a change takes a new revision`() {
        val supplier = StatusPayloadSupplier(1L, RevisionCounter())
        fun revision() = StatusPayloadSupplier.revisionFrom(supplier.currentFrame())

        assertEquals(1, revision())
        supplier.update(0, 0)
        supplier.setOffline(false)
        supplier.updatePeerId(1L)
        assertEquals(1, revision())

        supplier.update(1, 0)
        assertEquals(2, revision())
        supplier.setOffline(true)
        assertEquals(3, revision())
        supplier.updatePeerId(2L)
        assertEquals(4, revision())
    }

    @Test
    fun `a supplier for a rebuilt host adopts the status and continues the revisions`() {
        val revisions = RevisionCounter()
        val previous = StatusPayloadSupplier(1L, revisions)
        previous.update(3, 4)
        previous.setOffline(true)
        val previousRevision = StatusPayloadSupplier.revisionFrom(previous.currentFrame())!!

        val rebuilt = StatusPayloadSupplier.forRebuiltHost(2L, previous, revisions)

        val payload = rebuilt.payload(PayloadTimestamp(), null)
        assertEquals(2L, StatusPayloadSupplier.peerIdFrom(payload))
        assertEquals(3, StatusPayloadSupplier.statusFrom(payload))
        assertEquals(4, StatusPayloadSupplier.colorFrom(payload))
        // Only the status carries over: the new supplier starts online.
        assertEquals(false, StatusPayloadSupplier.isOfflineFrom(payload))
        assertEquals(2L, rebuilt.currentPeerId())
        // Newer than anything the old supplier sent, as a receiver sees it.
        val rebuiltRevision = StatusPayloadSupplier.revisionFrom(payload)!!
        assertTrue(((rebuiltRevision - previousRevision) and 0x7F) in 1..63)
    }

    @Test
    fun `a supplier for a first host starts blank`() {
        val supplier = StatusPayloadSupplier.forRebuiltHost(5L, previous = null, RevisionCounter())

        val payload = supplier.currentFrame()
        assertEquals(5L, StatusPayloadSupplier.peerIdFrom(payload))
        assertEquals(0, StatusPayloadSupplier.statusFrom(payload))
        assertEquals(0, StatusPayloadSupplier.colorFrom(payload))
    }

    @Test
    fun `revisions wrap at 7 bits`() {
        val revisions = RevisionCounter()
        val issued = List(129) { revisions.next() }

        assertEquals((1..127).toList() + listOf(0, 1), issued)
    }

    @Test
    fun `a negative id is written as its bit pattern`() {
        // Herald's UInt64 would clamp it to 0.
        val supplier = StatusPayloadSupplier(-1L, RevisionCounter())

        val idBytes = supplier.currentFrame().value.copyOfRange(0, 8)
        assertArrayEquals(ByteArray(8) { 0xFF.toByte() }, idBytes)
        assertEquals(-1L, StatusPayloadSupplier.peerIdFrom(supplier.currentFrame()))
    }

    @Test
    fun `an id with the top bit set decodes to the same value as on iOS`() {
        val data = Data(bytes(1, 0, 0, 0, 0, 0, 0, 0x80, 0, 0, 0, 0, 3, 0, 0, 0))

        // Swift: Int(bitPattern: 0x8000_0000_0000_0001).
        assertEquals(Long.MIN_VALUE + 1, StatusPayloadSupplier.peerIdFrom(data))
    }

    @Test
    fun `a short payload is dropped, not partially parsed`() {
        val data = Data(ByteArray(15))

        assertNull(StatusPayloadSupplier.peerIdFrom(data))
        assertNull(StatusPayloadSupplier.statusFrom(data))
        assertNull(StatusPayloadSupplier.isOfflineFrom(data))
        assertNull(StatusPayloadSupplier.revisionFrom(data))
        assertNull(StatusPayloadSupplier.peerIdFrom(null))
    }

    @Test
    fun `payloads are described for the log the same way as on iOS`() {
        assertEquals(
            "51C0FFEE android st=2 col=5 rev=2 online v3",
            StatusPayloadSupplier.describe(Data(androidOnline)),
        )
        assertEquals(
            "51C0FFEE ios st=2 col=5 rev=3 OFFLINE v3",
            StatusPayloadSupplier.describe(Data(iosOffline)),
        )
        assertEquals("(malformed)", StatusPayloadSupplier.describe(Data(ByteArray(15))))
        assertEquals("FFFFFFFFFFFFFFFF", peerHex(-1L))
        assertEquals("0B5EAFE7", peerHex(0x0B5EAFE7L))
    }
}
