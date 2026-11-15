package com.example.ble_proximity_bridge

import io.heraldprox.herald.sensor.datatype.Data
import io.heraldprox.herald.sensor.datatype.PayloadTimestamp
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pins the 16-byte wire format. RunnerTests.swift on iOS holds the same four
 * byte arrays: each platform's encoder must produce its own pair exactly,
 * and its decoder is run on the other platform's pair, so the two codecs are
 * checked against each other.
 */
class StatusPayloadSupplierTest {

    private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }

    // Peer id 0x51C0FFEE (three of its bytes are >= 0x80, so a decoder that
    // sign-extends bytes fails), status 2, color 5, protocol version 2.
    private val androidOnline = bytes(
        0xEE, 0xFF, 0xC0, 0x51, 0, 0, 0, 0, // peer id, little-endian
        2, // status
        5, // color
        1, // device kind: Android
        0, // flags
        2, 0, 0, 0, // protocol version
    )
    private val androidOffline =
        bytes(0xEE, 0xFF, 0xC0, 0x51, 0, 0, 0, 0, 2, 5, 1, 1, 2, 0, 0, 0)
    private val iosOnline =
        bytes(0xEE, 0xFF, 0xC0, 0x51, 0, 0, 0, 0, 2, 5, 0, 0, 2, 0, 0, 0)
    private val iosOffline =
        bytes(0xEE, 0xFF, 0xC0, 0x51, 0, 0, 0, 0, 2, 5, 0, 1, 2, 0, 0, 0)

    @Test
    fun `encodes the documented layout`() {
        val supplier = StatusPayloadSupplier(0x51C0FFEEL)
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
        assertEquals(2L, StatusPayloadSupplier.versionFrom(online))

        val offline = Data(iosOffline)
        assertEquals(0x51C0FFEEL, StatusPayloadSupplier.peerIdFrom(offline))
        assertEquals(true, StatusPayloadSupplier.isOfflineFrom(offline))
    }

    @Test
    fun `an id with the top bit set decodes to the same value as on iOS`() {
        val data = Data(bytes(1, 0, 0, 0, 0, 0, 0, 0x80, 0, 0, 0, 0, 2, 0, 0, 0))

        // Swift: Int(bitPattern: 0x8000_0000_0000_0001).
        assertEquals(Long.MIN_VALUE + 1, StatusPayloadSupplier.peerIdFrom(data))
    }

    @Test
    fun `a short payload is dropped, not partially parsed`() {
        val data = Data(ByteArray(15))

        assertNull(StatusPayloadSupplier.peerIdFrom(data))
        assertNull(StatusPayloadSupplier.statusFrom(data))
        assertNull(StatusPayloadSupplier.isOfflineFrom(data))
        assertNull(StatusPayloadSupplier.peerIdFrom(null))
    }

    @Test
    fun `a rebuilt supplier adopts the status of the one it replaces`() {
        val previous = StatusPayloadSupplier(1L)
        previous.update(3, 4)
        previous.setOffline(true)

        val rebuilt = StatusPayloadSupplier(2L)
        rebuilt.adoptStatus(previous)

        val payload = rebuilt.payload(PayloadTimestamp(), null)
        assertEquals(2L, StatusPayloadSupplier.peerIdFrom(payload))
        assertEquals(3, StatusPayloadSupplier.statusFrom(payload))
        assertEquals(4, StatusPayloadSupplier.colorFrom(payload))
        // Only the status carries over: the new supplier starts online.
        assertEquals(false, StatusPayloadSupplier.isOfflineFrom(payload))
        assertEquals(2L, rebuilt.currentPeerId())
    }
}
