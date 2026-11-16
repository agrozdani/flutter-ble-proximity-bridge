package com.example.ble_proximity_bridge

import android.util.Log
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
    private val onMalformed: (size: Int) -> Unit = { size ->
        Log.w(TAG, "Dropping malformed payload ($size bytes)")
    },
) : SensorDelegate {

    interface Listener {
        fun onSighting(peerId: Long, status: Int, color: Int, deviceKind: Int, rssi: Double?)

        fun onGone(peerId: Long)
    }

    override fun sensor(sensor: SensorType, didRead: PayloadData, fromTarget: TargetIdentifier) {
        // Payload read over GATT (or written to us by the peer); no RSSI.
        handle(didRead, rssi = null, FrameOverrides.Source.READ)
    }

    override fun sensor(sensor: SensorType, didReceive: ImmediateSendData, fromTarget: TargetIdentifier) {
        // Goodbye/hello frames. Herald 2.2.0 for Android never calls this.
        handle(didReceive.data, rssi = null, FrameOverrides.Source.FRAME)
    }

    override fun sensor(sensor: SensorType, didShare: List<PayloadData>, fromTarget: TargetIdentifier) {
        // Payloads relayed by another peer.
        for (payload in didShare) {
            handle(payload, rssi = null, FrameOverrides.Source.CACHED)
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
        handle(withPayload, didMeasure.value, FrameOverrides.Source.CACHED)
    }

    override fun sensor(sensor: SensorType, didDetect: TargetIdentifier) {
        // Advertisement seen, payload not read yet.
    }

    override fun sensor(sensor: SensorType, available: Boolean, didDeleteOrDetect: TargetIdentifier) {
        // Device became reachable/unreachable.
    }

    override fun sensor(sensor: SensorType, didMeasure: Proximity, fromTarget: TargetIdentifier) {
        // RSSI without payload: it cannot be attributed to a peer id.
    }

    override fun sensor(sensor: SensorType, didVisit: Location) {
        // Location sensing is not enabled.
    }

    override fun sensor(sensor: SensorType, didUpdateState: SensorState) {
        // Bluetooth state changes. Could be surfaced to the UI if needed.
    }

    private fun handle(data: Data, rssi: Double?, source: FrameOverrides.Source) {
        val peerId = StatusPayloadSupplier.peerIdFrom(data)
        val status = StatusPayloadSupplier.statusFrom(data)
        val color = StatusPayloadSupplier.colorFrom(data)
        val deviceKind = StatusPayloadSupplier.deviceKindFrom(data)
        val offline = StatusPayloadSupplier.isOfflineFrom(data)
        if (peerId == null || status == null || color == null ||
            deviceKind == null || offline == null
        ) {
            onMalformed(data.value.size)
            return
        }

        // Never list ourselves. Herald's Android relay skips handing a peer
        // its own payload by comparing bytes, so a copy that differs from the
        // current one (an older status, an earlier offline flag) can come
        // back to the device it describes. Herald 2.2.0 only relays to iOS
        // peers, so on Android this is a mirror of the iOS check.
        if (peerId == localPeerId()) return

        // Resolve even while stopped: Herald keeps its cached copies across
        // our stop/start, so the frames and reads it delivers meanwhile still
        // matter after the next start.
        val payload = frameOverrides.resolve(
            peerId,
            source,
            FrameOverrides.Payload(
                status, color, deviceKind, offline, StatusPayloadSupplier.revisionFrom(data),
            ),
        )

        // Ignore anything from connections that outlived a stop; null means
        // the payload must be ignored (see FrameOverrides).
        if (!isActive() || payload == null) return

        if (payload.offline) {
            // Peer said goodbye, or its payload carries the offline flag.
            listener.onGone(peerId)
        } else {
            listener.onSighting(peerId, payload.status, payload.color, payload.deviceKind, rssi)
        }
    }

    private companion object {
        const val TAG = "PayloadPipeline"
    }
}
