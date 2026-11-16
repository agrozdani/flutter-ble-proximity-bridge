package com.example.ble_proximity_bridge

import io.heraldprox.herald.sensor.Device
import io.heraldprox.herald.sensor.datatype.Data
import io.heraldprox.herald.sensor.datatype.Int64
import io.heraldprox.herald.sensor.datatype.PayloadData
import io.heraldprox.herald.sensor.datatype.PayloadTimestamp
import io.heraldprox.herald.sensor.datatype.UInt32
import io.heraldprox.herald.sensor.datatype.UInt8
import io.heraldprox.herald.sensor.payload.DefaultPayloadDataSupplier
import java.util.concurrent.atomic.AtomicInteger

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
 * offset 11    UInt8   flags (bit 0 = offline / goodbye,
 *                      bits 1-7 = payload revision, from version 3)
 * offset 12-15 UInt32  protocol version
 * ```
 *
 * The offline flag matters because BLE has no built-in goodbye. The
 * revision lets a receiver tell which of two payloads from the same peer is
 * newer (see FrameOverrides). Decoders are defensive: bad payloads are
 * dropped, not allowed to crash anything.
 */
class StatusPayloadSupplier(
    peerId: Long,
    private val revisions: RevisionCounter = RevisionCounter.shared,
) : DefaultPayloadDataSupplier() {

    companion object {
        const val DEVICE_KIND_IOS = 0
        const val DEVICE_KIND_ANDROID = 1
        const val PROTOCOL_VERSION = 3L
        const val FLAG_OFFLINE = 0x01

        /** The first protocol version whose flags carry a revision. */
        const val FIRST_VERSION_WITH_REVISION = 3L
        private const val REVISION_SHIFT = 1

        /** Revisions are 7 bits (flags bits 1-7) and wrap around. */
        const val REVISION_MASK = 0x7F

        private const val OFFSET_PEER_ID = 0
        private const val OFFSET_STATUS = 8
        private const val OFFSET_COLOR = 9
        private const val OFFSET_DEVICE_KIND = 10
        private const val OFFSET_FLAGS = 11
        private const val OFFSET_VERSION = 12
        private const val PAYLOAD_SIZE = 16

        /**
         * The supplier for a newly built host. It takes over the status and
         * color of the supplier it replaces, if any, so the new host does
         * not broadcast a blank status until Dart's next push.
         */
        fun forRebuiltHost(
            peerId: Long,
            previous: StatusPayloadSupplier?,
            revisions: RevisionCounter = RevisionCounter.shared,
        ): StatusPayloadSupplier =
            StatusPayloadSupplier(peerId, revisions).also { supplier ->
                previous?.let { supplier.adoptStatus(it) }
            }

        fun peerIdFrom(data: Data?): Long? {
            if (data == null || data.value.size < PAYLOAD_SIZE) return null
            // Read the 8 bytes as a bit pattern (Herald's Int64), not through
            // its UInt64: that type clamps anything with the top bit set to 0,
            // while iOS decodes the same bytes as a negative id. Our own ids
            // never get that large, but any device can broadcast one on our
            // service UUID and both platforms must agree on what it decodes to.
            return data.int64(OFFSET_PEER_ID)?.value
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

        /**
         * The payload's revision, or null when it has none: a sender before
         * protocol version 3 leaves flags bits 1-7 at 0.
         */
        fun revisionFrom(data: Data?): Int? {
            val version = versionFrom(data) ?: return null
            if (version < FIRST_VERSION_WITH_REVISION) return null
            val flags = data?.subdata(OFFSET_FLAGS)?.uint8(0)?.value ?: return null
            return (flags shr REVISION_SHIFT) and REVISION_MASK
        }

        fun versionFrom(data: Data?): Long? {
            if (data == null || data.value.size < PAYLOAD_SIZE) return null
            return data.subdata(OFFSET_VERSION)?.uint32(0)?.value
        }

        /**
         * A payload for the log, e.g. `1A2B3C4D android st=2 col=3 rev=17
         * online v3`. Same layout as `describe(_:)` on iOS.
         */
        fun describe(data: Data?): String {
            val peerId = peerIdFrom(data) ?: return "(malformed)"
            val device = deviceKindName(deviceKindFrom(data))
            return "${peerHex(peerId)} $device st=${statusFrom(data)} col=${colorFrom(data)} " +
                "rev=${revisionFrom(data) ?: "-"} " +
                "${if (isOfflineFrom(data) == true) "OFFLINE" else "online"} v${versionFrom(data)}"
        }
    }

    // Herald reads this on BLE threads while the platform thread writes
    // updates, so all access goes through the lock.
    private val lock = Any()
    private var peerId: Long = peerId
    private var status: Int = 0
    private var color: Int = 0
    private var offline: Boolean = false

    // Taken from the shared counter, so it is newer than anything an earlier
    // supplier in this process broadcast under the same peer id.
    private var revision: Int = revisions.next()

    fun updatePeerId(peerId: Long) {
        synchronized(lock) {
            if (this.peerId == peerId) return
            this.peerId = peerId
            revision = revisions.next()
        }
        logChange("new peer id")
    }

    /** The id we currently broadcast as. */
    fun currentPeerId(): Long = synchronized(lock) { peerId }

    /** Takes over the status and color of the supplier this one replaces. */
    fun adoptStatus(previous: StatusPayloadSupplier) {
        val (previousStatus, previousColor) =
            synchronized(previous.lock) { previous.status to previous.color }
        update(previousStatus, previousColor)
    }

    fun update(status: Int, color: Int) {
        // Clamped as Herald's UInt8 writes them, so a change that never
        // reaches the wire (300 to 301) takes no revision. Same as iOS.
        val newStatus = status.coerceIn(0, 255)
        val newColor = color.coerceIn(0, 255)
        synchronized(lock) {
            if (this.status == newStatus && this.color == newColor) return
            this.status = newStatus
            this.color = newColor
            revision = revisions.next()
        }
        logChange("status/color")
    }

    /** While offline, every payload we serve carries the goodbye flag. */
    fun setOffline(offline: Boolean) {
        synchronized(lock) {
            if (this.offline == offline) return
            this.offline = offline
            revision = revisions.next()
        }
        logChange(if (offline) "going offline (goodbye)" else "back online (hello)")
    }

    /**
     * What we broadcast, for the log. Carries `self=`, which tells
     * tool/devlogs.dart which peer id is this device.
     */
    fun describe(): String = synchronized(lock) {
        "self=${peerHex(peerId)} st=$status col=$color rev=$revision " +
            (if (offline) "OFFLINE" else "online")
    }

    private fun logChange(reason: String) {
        BridgeLog.i("payload", "broadcast now ${describe()} ($reason)")
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
            flags = (revision shl REVISION_SHIFT) or (if (offline) FLAG_OFFLINE else 0)
        }

        return PayloadData().apply {
            // Bit-pattern write, matching the decoder above and iOS.
            append(Int64(id))
            append(UInt8(statusNow))
            append(UInt8(colorNow))
            append(UInt8(DEVICE_KIND_ANDROID))
            append(UInt8(flags))
            append(UInt32(PROTOCOL_VERSION))
        }
    }
}

/**
 * Hands out payload revisions. The app uses one counter per process, shared
 * by every supplier: a host rebuilt for a new session keeps the same peer id,
 * so its supplier must carry on above the old one's revisions. Revisions are
 * 7 bits and wrap; receivers compare them with serial-number arithmetic.
 *
 * The counter lives in memory and starts again in every process. That is
 * safe here because Dart picks a new random peer id at every launch. An app
 * that keeps its peer id across launches must persist the counter's last
 * value with it and continue from there: otherwise receivers that still
 * remember the previous launch take the new one's payloads, goodbye
 * included, for older ones (see FrameOverrides).
 */
class RevisionCounter {
    private val last = AtomicInteger(0)

    fun next(): Int = last.incrementAndGet() and StatusPayloadSupplier.REVISION_MASK

    companion object {
        val shared = RevisionCounter()
    }
}
