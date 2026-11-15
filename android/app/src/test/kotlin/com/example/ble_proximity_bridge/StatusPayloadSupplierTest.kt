package com.example.ble_proximity_bridge

import io.heraldprox.herald.sensor.datatype.Data
import io.heraldprox.herald.sensor.datatype.PayloadTimestamp
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pins the 16-byte wire format. The byte arrays here are the same ones the
 * iOS tests (ios/RunnerTests/RunnerTests.swift) use, so the two codecs are
 * checked against one set of golden bytes.
 */
class StatusPayloadSupplierTest {

    private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }

    @Test
    fun `encodes the documented layout`() {
        val supplier = StatusPayloadSupplier(0x1A2B3C4DL)
        supplier.update(2, 5)

        assertArrayEquals(
            bytes(
                0x4D, 0x3C, 0x2B, 0x1A, 0, 0, 0, 0, // peer id, little-endian
                2, // status
                5, // color
                1, // device kind: Android
                0, // flags
                2, 0, 0, 0, // protocol version
            ),
            supplier.payload(PayloadTimestamp(), null).value,
        )

        supplier.setOffline(true)
        assertEquals(1, supplier.currentFrame().value[11].toInt())
    }

    @Test
    fun `decodes a payload written by iOS`() {
        val data = Data(
            bytes(
                0xEE, 0xFF, 0xC0, 0x51, 0, 0, 0, 0,
                3, 4, 0, 1,
                2, 0, 0, 0,
            ),
        )

        assertEquals(0x51C0FFEEL, StatusPayloadSupplier.peerIdFrom(data))
        assertEquals(3, StatusPayloadSupplier.statusFrom(data))
        assertEquals(4, StatusPayloadSupplier.colorFrom(data))
        assertEquals(0, StatusPayloadSupplier.deviceKindFrom(data))
        assertEquals(true, StatusPayloadSupplier.isOfflineFrom(data))
        assertEquals(2L, StatusPayloadSupplier.versionFrom(data))
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
