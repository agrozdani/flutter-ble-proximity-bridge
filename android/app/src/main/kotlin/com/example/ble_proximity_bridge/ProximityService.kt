package com.example.ble_proximity_bridge

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.heraldprox.herald.sensor.SensorArray
import io.heraldprox.herald.sensor.SensorDelegate
import io.heraldprox.herald.sensor.ble.BLESensorConfiguration
import io.heraldprox.herald.sensor.data.SensorLoggerLevel
import io.heraldprox.herald.sensor.datatype.Data
import io.heraldprox.herald.sensor.datatype.ImmediateSendData
import io.heraldprox.herald.sensor.datatype.Location
import io.heraldprox.herald.sensor.datatype.PayloadData
import io.heraldprox.herald.sensor.datatype.Proximity
import io.heraldprox.herald.sensor.datatype.SensorState
import io.heraldprox.herald.sensor.datatype.SensorType
import io.heraldprox.herald.sensor.datatype.TargetIdentifier
import io.heraldprox.herald.sensor.datatype.TimeInterval
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference

/**
 * Runs the proximity source (Herald BLE or the mock source) and streams
 * sightings to Flutter. Android counterpart of ProximityController.
 *
 * Real BLE runs as a foreground service so scanning survives backgrounding.
 * The Herald host is reused across stop/start, so a logical stop is sent in
 * the payload with an offline flag plus a goodbye frame.
 */
class ProximityService : Service(), SensorDelegate, EventChannel.StreamHandler {

    companion object {
        private const val TAG = "ProximityService"
        private const val NOTIFICATION_CHANNEL_ID = "proximity_bridge_service"
        private const val NOTIFICATION_ID = 71

        /** How often peers re-read our payload. Limits how stale cached data can get. */
        private val PAYLOAD_REFRESH = TimeInterval(15)

        /** Gives the goodbye frame a moment to reach peers before we stop. */
        private const val GOODBYE_FLUSH_MILLIS = 300L

        const val EXTRA_SESSION_ID = "sessionId"
        const val EXTRA_PEER_ID = "peerId"
        const val EXTRA_MOCK = "mock"

        // Flutter can subscribe before the service exists. Park the sink
        // here so onCreate can claim it later.
        private val instanceRef = AtomicReference<ProximityService?>()
        private val pendingSinkRef = AtomicReference<EventChannel.EventSink?>()

        fun instance(): ProximityService? = instanceRef.get()

        fun parkPendingSink(sink: EventChannel.EventSink?) {
            pendingSinkRef.set(sink)
        }
    }

    private enum class SourceMode { IDLE, BLE, MOCK }

    @Volatile
    var payloadSupplier: StatusPayloadSupplier? = null
        private set

    val distanceEstimator = DistanceEstimator()

    /** The Herald host. Rebuilt only when the session id changes. */
    private var sensorArray: SensorArray? = null
    private var bleHostSessionId: String? = null

    private var mockSource: MockPeerSource? = null
    private var sourceMode = SourceMode.IDLE
    private var pendingQuiesce: Runnable? = null

    // Herald calls us on worker threads. Flutter sink calls must happen on
    // the main thread and the sink can disappear at any time.
    private var eventSink: EventChannel.EventSink? = null
    private val sinkLock = Any()
    private val mainThread = Handler(Looper.getMainLooper())

    private val isSourceRunning: Boolean
        get() = sourceMode != SourceMode.IDLE

    // ----- Service lifecycle -------------------------------------------------

    override fun onCreate() {
        super.onCreate()
        instanceRef.set(this)
        pendingSinkRef.getAndSet(null)?.let {
            Log.i(TAG, "Claiming event sink parked before service creation")
            onListen(null, it)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            // After process death we may be restarted without the original
            // extras. Stay alive and let Dart issue start again later.
            return START_STICKY
        }

        val sessionId = intent.getStringExtra(EXTRA_SESSION_ID)
        val peerId = intent.getLongExtra(EXTRA_PEER_ID, -1L)
        val mock = intent.getBooleanExtra(EXTRA_MOCK, false)
        if (sessionId == null || peerId < 0) {
            Log.e(TAG, "Missing start extras; stopping")
            stopSelf()
            return START_NOT_STICKY
        }

        // A quick restart during the goodbye window keeps the host running.
        pendingQuiesce?.let { mainThread.removeCallbacks(it) }
        pendingQuiesce = null
        mockSource?.stop()
        mockSource = null
        distanceEstimator.clear()

        if (mock) {
            // A racing stop may have left the BLE host running, so always
            // quiesce it before switching to mock mode.
            quiesceBleHost()
            startMockSource()
        } else {
            if (!hasBluetoothPermissions()) {
                Log.w(TAG, "Bluetooth permissions missing; stopping")
                stopSelf()
                return START_NOT_STICKY
            }
            promoteToForeground()
            startOrResumeBleHost(sessionId, peerId)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        // Real teardown: the cached host dies with the service.
        pendingQuiesce?.let { mainThread.removeCallbacks(it) }
        pendingQuiesce = null
        mockSource?.stop()
        mockSource = null
        sensorArray?.stop()
        sensorArray = null
        bleHostSessionId = null
        payloadSupplier = null
        sourceMode = SourceMode.IDLE
        distanceEstimator.clear()
        // Only clear the singleton if we are still the active instance.
        instanceRef.compareAndSet(this, null)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /** Called from MainActivity when Dart invokes stop. */
    fun stopProximity() {
        mockSource?.stop()
        mockSource = null
        // Flip the mode first so any late Herald callbacks get ignored.
        sourceMode = SourceMode.IDLE
        distanceEstimator.clear()
        // The BLE host may still be up even if the current mode was mock.
        quiesceBleHost()
        // Keep the host and supplier around so lingering peers read the
        // offline payload and the next start can reuse the host.
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    // ----- BLE host -----------------------------------------------------------

    private fun startOrResumeBleHost(sessionId: String, peerId: Long) {
        // Host already exists for this session, so just turn it back on.
        val host = sensorArray
        val supplier = payloadSupplier
        if (host != null && supplier != null && bleHostSessionId == sessionId) {
            supplier.updatePeerId(peerId)
            supplier.setOffline(false)
            sourceMode = SourceMode.BLE
            host.start()
            // Tell connected peers we are back so they do not keep our
            // cached offline payload until the next re-read.
            host.immediateSendAll(supplier.currentFrame())
            sendReady()
            return
        }

        // A new session id means a new service UUID, so the host has to be
        // rebuilt. The demo's fixed session id does not hit this path.
        if (host != null) {
            Log.i(TAG, "Session id changed; rebuilding BLE host")
            host.stop()
            sensorArray = null
            bleHostSessionId = null
            payloadSupplier = null
        }

        // The session UUID doubles as the BLE service UUID, so only devices
        // on the same session find each other. Herald's standard service is
        // disabled to keep this app isolated from other Herald traffic.
        BLESensorConfiguration.payloadDataUpdateTimeInterval = PAYLOAD_REFRESH
        BLESensorConfiguration.customServiceUUID = UUID.fromString(sessionId)
        BLESensorConfiguration.customServiceDetectionEnabled = true
        BLESensorConfiguration.customServiceAdvertisingEnabled = true
        BLESensorConfiguration.standardHeraldServiceDetectionEnabled = false
        BLESensorConfiguration.standardHeraldServiceAdvertisingEnabled = false
        BLESensorConfiguration.logLevel = SensorLoggerLevel.off

        val newSupplier = StatusPayloadSupplier(peerId)
        val newHost = SensorArray(applicationContext, newSupplier)
        newHost.add(this)
        payloadSupplier = newSupplier
        sensorArray = newHost
        bleHostSessionId = sessionId
        try {
            sourceMode = SourceMode.BLE
            newHost.start()
            sendReady()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start BLE sensor array", e)
            sensorArray = null
            bleHostSessionId = null
            payloadSupplier = null
            sourceMode = SourceMode.IDLE
            stopSelf()
        }
    }

    /** Flags us offline, sends goodbye frames, then stops the host after a short delay. */
    private fun quiesceBleHost() {
        val host = sensorArray ?: return

        payloadSupplier?.let { supplier ->
            supplier.setOffline(true)
            host.immediateSendAll(supplier.currentFrame())
        }

        val quiesce = Runnable {
            pendingQuiesce = null
            // A BLE start raced in during the flush window, so leave it up.
            if (sourceMode != SourceMode.BLE) host.stop()
        }
        pendingQuiesce = quiesce
        mainThread.postDelayed(quiesce, GOODBYE_FLUSH_MILLIS)
    }

    private fun startMockSource() {
        mockSource = MockPeerSource { peerId, status, color, deviceKind, rssi ->
            handleSighting(peerId, status, color, deviceKind, rssi)
        }.also { it.start() }
        sourceMode = SourceMode.MOCK
        sendReady()
    }

    // ----- Herald SensorDelegate ----------------------------------------------
    // Herald reports through many sensor() overloads. We only care about
    // the ones that carry a payload.

    override fun sensor(sensor: SensorType, didDetect: TargetIdentifier) {
        // Advertisement seen, payload not read yet.
    }

    override fun sensor(sensor: SensorType, available: Boolean, didDeleteOrDetect: TargetIdentifier) {
        // Device became reachable/unreachable.
    }

    override fun sensor(sensor: SensorType, didRead: PayloadData, fromTarget: TargetIdentifier) {
        // Payload read over GATT, no fresh RSSI in this callback.
        handlePayload(didRead, proximity = null)
    }

    override fun sensor(sensor: SensorType, didReceive: ImmediateSendData, fromTarget: TargetIdentifier) {
        // Goodbye/hello frames. Same 16-byte payload, same pipeline.
        handlePayload(didReceive.data, proximity = null)
    }

    override fun sensor(sensor: SensorType, didShare: List<PayloadData>, fromTarget: TargetIdentifier) {
        // Payloads relayed by another peer. This helps with iOS background
        // advertising limits.
        for (payload in didShare) {
            handlePayload(payload, proximity = null)
        }
    }

    override fun sensor(sensor: SensorType, didMeasure: Proximity, fromTarget: TargetIdentifier) {
        // RSSI without payload: we cannot attribute it to a peer id yet.
    }

    override fun sensor(sensor: SensorType, didVisit: Location) {
        // Location sensing is not enabled.
    }

    override fun sensor(
        sensor: SensorType,
        didMeasure: Proximity,
        fromTarget: TargetIdentifier,
        withPayload: PayloadData,
    ) {
        // The workhorse callback: payload and RSSI together.
        handlePayload(withPayload, didMeasure)
    }

    override fun sensor(sensor: SensorType, didUpdateState: SensorState) {
        // Bluetooth state changes. Could be surfaced to the UI if needed.
    }

    // ----- Sighting pipeline --------------------------------------------------

    private fun handlePayload(data: Data, proximity: Proximity?) {
        // Ignore anything from connections that outlived a stop.
        if (sourceMode != SourceMode.BLE) return
        val peerId = StatusPayloadSupplier.peerIdFrom(data)
        val status = StatusPayloadSupplier.statusFrom(data)
        val color = StatusPayloadSupplier.colorFrom(data)
        val deviceKind = StatusPayloadSupplier.deviceKindFrom(data)
        val offline = StatusPayloadSupplier.isOfflineFrom(data)
        if (peerId == null || status == null || color == null ||
            deviceKind == null || offline == null
        ) {
            Log.w(TAG, "Dropping malformed payload (${data.value.size} bytes)")
            return
        }

        if (offline) {
            // Peer said goodbye, or we read its cached offline payload.
            emitGone(peerId)
            return
        }
        handleSighting(peerId, status, color, deviceKind, proximity?.value)
    }

    /** Common path for BLE and mock sightings. */
    private fun handleSighting(
        peerId: Long,
        status: Int,
        color: Int,
        deviceKind: Int,
        rssi: Double?,
    ) {
        if (sourceMode == SourceMode.IDLE) return
        val distance = rssi?.let { distanceEstimator.addSample(peerId, it, deviceKind) }

        val event = hashMapOf<String, Any>(
            "type" to "peer",
            "id" to peerId,
            "status" to status,
            "color" to color,
            "device" to deviceKind,
        )
        if (rssi != null) event["rssi"] = rssi
        if (distance != null) event["distance"] = distance

        mainThread.post { emit(event) }
    }

    private fun emitGone(peerId: Long) {
        // Drop the distance model now instead of waiting for Dart to do it.
        distanceEstimator.forget(peerId)
        val event = hashMapOf<String, Any>("type" to "gone", "id" to peerId)
        mainThread.post { emit(event) }
    }

    private fun sendReady() {
        mainThread.post { emit(hashMapOf<String, Any>("type" to "ready")) }
    }

    private fun emit(event: Map<String, Any>) {
        synchronized(sinkLock) {
            val sink = eventSink ?: return
            try {
                sink.success(event)
            } catch (e: Exception) {
                // Engine teardown can invalidate the sink between the null
                // check and the call, so drop it and stop trying.
                Log.w(TAG, "Event sink rejected event; clearing", e)
                eventSink = null
            }
        }
    }

    // ----- EventChannel.StreamHandler ------------------------------------------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        synchronized(sinkLock) { eventSink = events }
        // If the source was already running when Dart subscribed, the first
        // ready event went nowhere. Send it again.
        if (isSourceRunning) sendReady()
    }

    override fun onCancel(arguments: Any?) {
        // Queued emits become no-ops once the sink is cleared. Do not wipe
        // pending callbacks because quiesce still needs to run.
        synchronized(sinkLock) { eventSink = null }
    }

    // ----- Foreground promotion -------------------------------------------------

    private fun hasBluetoothPermissions(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return listOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_ADVERTISE,
            Manifest.permission.BLUETOOTH_CONNECT,
        ).all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
    }

    private fun promoteToForeground() {
        val notification = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // Permissions may have been revoked after Dart checked them,
            // which makes foreground promotion fail here.
            Log.e(TAG, "Foreground promotion failed", e)
            stopSelf()
        }
    }

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Proximity scanning",
                NotificationManager.IMPORTANCE_LOW,
            )
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Scanning for nearby peers")
            .setContentText("BLE proximity detection is active")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .build()
    }
}
