package com.example.ble_proximity_bridge

import io.heraldprox.herald.sensor.Device
import io.heraldprox.herald.sensor.datatype.Data
import io.heraldprox.herald.sensor.datatype.PayloadData
import io.heraldprox.herald.sensor.datatype.PayloadTimestamp
import io.heraldprox.herald.sensor.datatype.UInt32
import io.heraldprox.herald.sensor.datatype.UInt64
import io.heraldprox.herald.sensor.datatype.UInt8
import io.heraldprox.herald.sensor.payload.DefaultPayloadDataSupplier

/**
 * Encodes the payload we broadcast and decodes payloads from peers. The
 * same 16 bytes also travel in goodbye/hello frames, which is why the
 * decoders take Herald's base [Data] type.
 *
 * Wire format (16 bytes, little-endian, must match iOS exactly):
 *
 * ```
 * offset 0-7   UInt64  peer id
 * offset 8     UInt8   status code
 * offset 9     UInt8   color index
 * offset 10    UInt8   device kind (0 = iOS, 1 = Android)
 * offset 11    UInt8   flags (bit 0 = offline / goodbye)
 * offset 12-15 UInt32  protocol version
 * ```
 *
 * The offline flag matters because BLE has no built-in goodbye. Decoders
 * are defensive: bad payloads are dropped, not allowed to crash anything.
 */
class StatusPayloadSupplier(peerId: Long) : DefaultPayloadDataSupplier() {

    companion object {
        const val DEVICE_KIND_ANDROID = 1
        const val PROTOCOL_VERSION = 2L
        const val FLAG_OFFLINE = 0x01

        private const val OFFSET_PEER_ID = 0
        private const val OFFSET_STATUS = 8
        private const val OFFSET_COLOR = 9
        private const val OFFSET_DEVICE_KIND = 10
        private const val OFFSET_FLAGS = 11
        private const val OFFSET_VERSION = 12
        private const val PAYLOAD_SIZE = 16

        fun peerIdFrom(data: Data?): Long? {
            if (data == null || data.value.size < PAYLOAD_SIZE) return null
            return data.uint64(OFFSET_PEER_ID)?.value
        }

        fun statusFrom(data: Data?): Int? {
            if (data == null || data.value.size < PAYLOAD_SIZE) return null
            return data.subdata(OFFSET_STATUS)?.uint8(0)?.value
        }

        fun colorFrom(data: Data?): Int? {
            if (data == null || data.value.size < PAYLOAD_SIZE) return null
            return data.subdata(OFFSET_COLOR)?.uint8(0)?.value
        }

        fun deviceKindFrom(data: Data?): Int? {
            if (data == null || data.value.size < PAYLOAD_SIZE) return null
            return data.subdata(OFFSET_DEVICE_KIND)?.uint8(0)?.value
        }

        fun isOfflineFrom(data: Data?): Boolean? {
            if (data == null || data.value.size < PAYLOAD_SIZE) return null
            val flags = data.subdata(OFFSET_FLAGS)?.uint8(0)?.value ?: return null
            return flags and FLAG_OFFLINE != 0
        }

        fun versionFrom(data: Data?): Long? {
            if (data == null || data.value.size < PAYLOAD_SIZE) return null
            return data.subdata(OFFSET_VERSION)?.uint32(0)?.value
        }
    }

    // Herald reads this on BLE threads while the platform thread writes
    // updates, so all access goes through the lock.
    private val lock = Any()
    private var peerId: Long = peerId
    private var status: Int = 0
    private var color: Int = 0
    private var offline: Boolean = false

    fun updatePeerId(peerId: Long) {
        synchronized(lock) {
            this.peerId = peerId
        }
    }

    fun update(status: Int, color: Int) {
        synchronized(lock) {
            this.status = status
            this.color = color
        }
    }

    /** While offline, every payload we serve carries the goodbye flag. */
    fun setOffline(offline: Boolean) {
        synchronized(lock) {
            this.offline = offline
        }
    }

    /** Returns the current payload as a goodbye/hello frame. */
    fun currentFrame(): PayloadData = payload(PayloadTimestamp(), null)

    override fun payload(timestamp: PayloadTimestamp, device: Device?): PayloadData {
        val id: Long
        val statusNow: Int
        val colorNow: Int
        val flags: Int
        synchronized(lock) {
            id = peerId
            statusNow = status
            colorNow = color
            flags = if (offline) FLAG_OFFLINE else 0
        }

        return PayloadData().apply {
            append(UInt64(id))
            append(UInt8(statusNow))
            append(UInt8(colorNow))
            append(UInt8(DEVICE_KIND_ANDROID))
            append(UInt8(flags))
            append(UInt32(PROTOCOL_VERSION))
        }
    }
}
