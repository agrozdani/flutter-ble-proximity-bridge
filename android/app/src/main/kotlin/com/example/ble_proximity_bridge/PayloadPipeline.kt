package com.example.ble_proximity_bridge

import android.os.SystemClock
import io.heraldprox.herald.sensor.SensorDelegate
import io.heraldprox.herald.sensor.datatype.Data
import io.heraldprox.herald.sensor.datatype.ImmediateSendData
import io.heraldprox.herald.sensor.datatype.Location
import io.heraldprox.herald.sensor.datatype.PayloadData
import io.heraldprox.herald.sensor.datatype.Proximity
import io.heraldprox.herald.sensor.datatype.SensorState
import io.heraldprox.herald.sensor.datatype.SensorType
import io.heraldprox.herald.sensor.datatype.TargetIdentifier
import java.util.Locale

/**
 * Herald's delegate. Maps each callback that carries a payload to where
 * that payload came from, decodes it, drops malformed payloads and our own,
 * lets [FrameOverrides] decide which payload to believe, and reports the
 * outcome to [listener]. Kept free of Android services and Flutter so the
 * whole path can be unit-tested.
 *
 * Every decision is logged (`native.pipeline`), with what FrameOverrides
 * decided and why. The one exception is the most common case, a cached
 * payload taken as it is with an RSSI reading: native.emit logs that
 * sighting together with its distance estimate.
 *
 * Herald calls this on its worker threads; the callbacks it is given must be
 * safe to call there.
 */
class PayloadPipeline(
    private val frameOverrides: FrameOverrides,
    /** Whether outcomes are reported: a BLE source is logically running. */
    private val isActive: () -> Boolean,
    /** The id this device broadcasts as, if any. */
    private val localPeerId: () -> Long?,
    private val listener: Listener,
    private val onMalformed: (size: Int) -> Unit = {},
    private val now: () -> Long = SystemClock::elapsedRealtime,
) : SensorDelegate {

    interface Listener {
        fun onSighting(peerId: Long, status: Int, color: Int, deviceKind: Int, rssi: Double?)

        /** The peer said goodbye, or its payload carries the offline flag. */
        fun onGone(peerId: Long)

        /**
         * The device that broadcast [oldPeerId] now broadcasts [newPeerId]:
         * the app there started again (ids are per launch), so the old id
         * is gone.
         */
        fun onReplaced(oldPeerId: Long, newPeerId: Long)
    }

    /** The last Bluetooth state Herald reported, for the stats line. */
    @Volatile
    var bluetoothState: SensorState? = null
        private set

    private val stats = Counters()

    /** The id last read from each device, by Herald target. */
    private val lastReadIds = HashMap<String, LastRead>()

    private class LastRead(val peerId: Long, val atMillis: Long)

    override fun sensor(sensor: SensorType, didRead: PayloadData, fromTarget: TargetIdentifier) {
        // Payload read over GATT (or written to us by the peer); no RSSI.
        stats.add("read")
        handle(didRead, rssi = null, FrameOverrides.Source.READ, fromTarget)
    }

    override fun sensor(sensor: SensorType, didReceive: ImmediateSendData, fromTarget: TargetIdentifier) {
        // Goodbye/hello frames. Herald 2.2.0 for Android never calls this.
        stats.add("frame")
        handle(didReceive.data, rssi = null, FrameOverrides.Source.FRAME, fromTarget)
    }

    override fun sensor(sensor: SensorType, didShare: List<PayloadData>, fromTarget: TargetIdentifier) {
        // Payloads relayed by another peer.
        stats.add("shared", didShare.size)
        BridgeLog.d("pipeline") { "relay via=${via(fromTarget)} shared ${didShare.size} payload(s)" }
        for (payload in didShare) {
            handle(payload, rssi = null, FrameOverrides.Source.CACHED, fromTarget)
        }
    }

    override fun sensor(
        sensor: SensorType,
        didMeasure: Proximity,
        fromTarget: TargetIdentifier,
        withPayload: PayloadData,
    ) {
        // An RSSI reading together with the payload Herald last read from
        // that peer, which can be up to a refresh interval old.
        stats.add("cached")
        handle(withPayload, didMeasure.value, FrameOverrides.Source.CACHED, fromTarget)
    }

    override fun sensor(sensor: SensorType, didDetect: TargetIdentifier) {
        // Advertisement seen, payload not read yet.
        stats.add("detect")
        BridgeLog.d("pipeline") { "detect via=${via(didDetect)}" }
    }

    override fun sensor(sensor: SensorType, available: Boolean, didDeleteOrDetect: TargetIdentifier) {
        // Device became reachable/unreachable.
        BridgeLog.d("pipeline") { "available=$available via=${via(didDeleteOrDetect)}" }
    }

    override fun sensor(sensor: SensorType, didMeasure: Proximity, fromTarget: TargetIdentifier) {
        // RSSI without payload: it cannot be attributed to a peer id.
        stats.add("rssiOnly")
    }

    override fun sensor(sensor: SensorType, didVisit: Location) {
        // Location sensing is not enabled.
    }

    override fun sensor(sensor: SensorType, didUpdateState: SensorState) {
        if (sensor == SensorType.BLE) {
            // Bluetooth state changes. Not surfaced to Dart, but logged:
            // nothing is found while this is not "on".
            bluetoothState = didUpdateState
            BridgeLog.i("ble", "bluetooth state ${didUpdateState.name}")
        } else {
            // SensorArray.start() and stop() report the array itself as on
            // and off; that confirms the call, it says nothing about the radio.
            BridgeLog.i("ble", "Herald $sensor sensor ${didUpdateState.name}")
        }
    }

    /** Counts since the last call, e.g. `read=2 cached=31 ...`, then resets. */
    fun takeStats(): String = stats.take()

    private fun handle(
        data: Data,
        rssi: Double?,
        source: FrameOverrides.Source,
        target: TargetIdentifier,
    ) {
        val peerId = StatusPayloadSupplier.peerIdFrom(data)
        val status = StatusPayloadSupplier.statusFrom(data)
        val color = StatusPayloadSupplier.colorFrom(data)
        val deviceKind = StatusPayloadSupplier.deviceKindFrom(data)
        val offline = StatusPayloadSupplier.isOfflineFrom(data)
        if (peerId == null || status == null || color == null ||
            deviceKind == null || offline == null
        ) {
            stats.add("malformed")
            BridgeLog.w(
                "pipeline",
                "${label(source)} malformed payload (${data.value.size} bytes) " +
                    "${data.hexEncodedString()} via=${via(target)}",
            )
            onMalformed(data.value.size)
            return
        }

        // Never list ourselves. Herald's Android relay skips handing a peer
        // its own payload by comparing bytes, so a copy that differs from the
        // current one (an older status, an earlier offline flag) can come
        // back to the device it describes. Herald 2.2.0 only relays to iOS
        // peers, so on Android this is a mirror of the iOS check.
        if (peerId == localPeerId()) {
            stats.add("own")
            BridgeLog.d("pipeline") { "${label(source)} own payload ${StatusPayloadSupplier.describe(data)}, dropped" }
            return
        }

        if (source == FrameOverrides.Source.READ) retireReplacedId(peerId, data, target)

        // Resolve even while stopped: Herald keeps its cached copies across
        // our stop/start, so the frames and reads it delivers meanwhile still
        // matter after the next start.
        val resolution = frameOverrides.resolveExplained(
            peerId,
            source,
            FrameOverrides.Payload(
                status, color, deviceKind, offline, StatusPayloadSupplier.revisionFrom(data),
            ),
        )
        val payload = resolution.payload
        val active = isActive()
        log(source, data, rssi, target, resolution, active)

        // Ignore anything from connections that outlived a stop; null means
        // the payload must be ignored (see FrameOverrides).
        if (!active || payload == null) return

        if (payload.offline) {
            // Peer said goodbye, or its payload carries the offline flag.
            listener.onGone(peerId)
        } else {
            listener.onSighting(peerId, payload.status, payload.color, payload.deviceKind, rssi)
        }
    }

    /**
     * A read is the device at that address giving its own id: Herald for
     * Android never relays payloads to Android, so no relayed copy arrives
     * as a read here (on iOS one can, which is why iOS has no such rule).
     * If the last read there gave another id, the app on that device started
     * again under a new one, and the old id is gone. Without this, the old id
     * stays listed: Herald hands over its cached copy of the device's last
     * read with every RSSI reading until it reads the device again, and then
     * Dart waits out its eviction window (seen on a Pixel after an iPad's hot
     * restart: two entries for one iPad for 90 s).
     *
     * Only reads count; a cached copy is Herald's memory of a read. A read is
     * remembered as long as Herald keeps the device ([LAST_READ_MEMORY_MILLIS]).
     */
    private fun retireReplacedId(peerId: Long, data: Data, target: TargetIdentifier) {
        val nowMillis = now()
        val previous = synchronized(lastReadIds) {
            lastReadIds.values.removeAll { nowMillis - it.atMillis > LAST_READ_MEMORY_MILLIS }
            lastReadIds.put(target.value, LastRead(peerId, nowMillis))
        }
        if (previous == null || previous.peerId == peerId) return

        val active = isActive()
        // While stopped, the read itself is counted as whileStopped.
        if (active) stats.add("replaced")
        val ago = String.format(Locale.US, "%.1f", (nowMillis - previous.atMillis) / 1000.0)
        BridgeLog.i(
            "pipeline",
            "read ${StatusPayloadSupplier.describe(data)} via=${via(target)} → replaces " +
                "${peerHex(previous.peerId)}, read from that device ${ago}s ago; " +
                if (active) "${peerHex(previous.peerId)} reported GONE" else "stopped, so not reported",
        )
        if (active) listener.onReplaced(previous.peerId, peerId)
    }

    private fun log(
        source: FrameOverrides.Source,
        data: Data,
        rssi: Double?,
        target: TargetIdentifier,
        resolution: FrameOverrides.Resolution,
        active: Boolean,
    ) {
        val payload = resolution.payload
        val verdict = resolution.verdict
        val outcome = when {
            !active -> "stopped, so not reported"
            payload == null -> "nothing reported"
            payload.offline -> "reported GONE"
            else -> "reported as a sighting"
        }
        stats.add(if (active) verdict.key else "whileStopped")

        // The common case; native.emit logs the sighting.
        val routine = active && source == FrameOverrides.Source.CACHED &&
            verdict == FrameOverrides.Verdict.CACHED_ACCEPTED && payload?.offline == false
        if (routine) return

        // Frames, departures and every override are rare and matter.
        val important = source == FrameOverrides.Source.FRAME ||
            (active && payload?.offline == true) ||
            (verdict != FrameOverrides.Verdict.CACHED_ACCEPTED &&
                verdict != FrameOverrides.Verdict.READ_ACCEPTED)
        if (!important && !BridgeLog.isEnabled(BridgeLog.Level.DEBUG)) return

        val line = buildString {
            append(label(source)).append(' ').append(StatusPayloadSupplier.describe(data))
            if (rssi != null) append(" rssi=").append(rssi.toInt())
            append(" via=").append(via(target))
            append(" → ").append(verdict.description).append("; ").append(outcome)
            append(" [").append(resolution.context).append(']')
        }
        if (important) BridgeLog.i("pipeline", line) else BridgeLog.d("pipeline") { line }
    }

    private fun label(source: FrameOverrides.Source) = when (source) {
        FrameOverrides.Source.READ -> "read"
        FrameOverrides.Source.FRAME -> "frame"
        FrameOverrides.Source.CACHED -> "cached"
    }

    /**
     * Herald's identifier for the remote device. For devices it scans,
     * Herald 2.2.0 for Android builds it from BluetoothDevice.getAddress().
     */
    private fun via(target: TargetIdentifier): String = target.value.take(17)

    private companion object {
        /**
         * How long a device's last read is remembered. Herald for Android
         * deletes a device, and its cached payload with it, 15 minutes after
         * the device was last updated (`taskRemoveExpiredDevices`).
         */
        const val LAST_READ_MEMORY_MILLIS = 15 * 60_000L
    }

    /** Thread-safe named counters. */
    private class Counters {
        private val counts = LinkedHashMap<String, Int>()

        @Synchronized
        fun add(name: String, amount: Int = 1) {
            counts[name] = (counts[name] ?: 0) + amount
        }

        @Synchronized
        fun take(): String {
            val text = if (counts.isEmpty()) {
                "none"
            } else {
                counts.entries.joinToString(" ") { "${it.key}=${it.value}" }
            }
            counts.clear()
            return text
        }
    }
}
