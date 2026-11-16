package com.example.ble_proximity_bridge

import io.heraldprox.herald.sensor.SensorDelegate
import io.heraldprox.herald.sensor.datatype.Data
import io.heraldprox.herald.sensor.datatype.ImmediateSendData
import io.heraldprox.herald.sensor.datatype.Location
import io.heraldprox.herald.sensor.datatype.PayloadData
import io.heraldprox.herald.sensor.datatype.Proximity
import io.heraldprox.herald.sensor.datatype.SensorState
import io.heraldprox.herald.sensor.datatype.SensorType
import io.heraldprox.herald.sensor.datatype.TargetIdentifier

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
) : SensorDelegate {

    interface Listener {
        fun onSighting(peerId: Long, status: Int, color: Int, deviceKind: Int, rssi: Double?)

        fun onGone(peerId: Long)
    }

    /** The last Bluetooth state Herald reported, for the stats line. */
    @Volatile
    var bluetoothState: SensorState? = null
        private set

    private val stats = Counters()

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
