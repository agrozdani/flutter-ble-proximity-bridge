package com.example.ble_proximity_bridge

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
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
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong
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

        /**
         * How often we re-read a peer's payload. Every install uses the same
         * value, so it also bounds how stale our payload can be on a peer.
         */
        private val PAYLOAD_REFRESH = TimeInterval(15)

        const val EXTRA_SESSION_ID = "sessionId"
        const val EXTRA_PEER_ID = "peerId"
        const val EXTRA_MOCK = "mock"
        const val EXTRA_COMMAND = "command"

        // Flutter can subscribe before the service exists. Park the sink
        // here so onCreate can claim it later.
        private val instanceRef = AtomicReference<ProximityService?>()
        private val pendingSinkRef = AtomicReference<EventChannel.EventSink?>()

        // startForegroundService() returns before onStartCommand runs, so a
        // stop from Dart can arrive while its start is still in flight. Every
        // start and stop takes a number; a start that is no longer the latest
        // command when it is delivered was cancelled and must not run.
        private val latestCommand = AtomicLong()

        fun instance(): ProximityService? = instanceRef.get()

        /** Called by MainActivity for every start and stop, in call order. */
        fun nextCommand(): Long = latestCommand.incrementAndGet()

        fun parkPendingSink(sink: EventChannel.EventSink?) {
            pendingSinkRef.set(sink)
        }

        /** The runtime permissions real BLE needs (none before Android 12). */
        fun hasBluetoothPermissions(context: Context): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
            return listOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT,
            ).all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
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

    // Written on the main thread, read from Herald's worker threads, so it
    // must be volatile for stops to be visible to in-flight callbacks.
    @Volatile
    private var sourceMode = SourceMode.IDLE

    // Herald's Android immediateSendAll connects to each recent peer in turn
    // and blocks until each exchange finishes, which can take seconds. Frames
    // go out on this thread so the main thread never waits on the radio. One
    // thread keeps goodbye/hello frames in the order they were sent.
    private val frameSender = Executors.newSingleThreadExecutor()

    // Herald calls us on worker threads. Flutter sink calls must happen on
    // the main thread and the sink can disappear at any time.
    private var eventSink: EventChannel.EventSink? = null
    private val sinkLock = Any()
    private val mainThread = Handler(Looper.getMainLooper())

    /** True while a source (BLE or mock) is logically running. */
    val isRunning: Boolean
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
            // A START_STICKY restart after process death: the extras are gone
            // and no Flutter engine is attached, so there is nothing to resume.
            // The service idles until Dart starts it again, or until Android
            // stops it as an idle background service.
            return START_STICKY
        }

        val sessionId = intent.getStringExtra(EXTRA_SESSION_ID)
        val peerId = intent.getLongExtra(EXTRA_PEER_ID, -1L)
        val mock = intent.getBooleanExtra(EXTRA_MOCK, false)
        val command = intent.getLongExtra(EXTRA_COMMAND, -1L)

        // A real-BLE start arrives via startForegroundService(), and a service
        // started that way must call startForeground() before it stops or
        // Android crashes the app. So promote first, then bail out if needed.
        val superseded = command != latestCommand.get()
        if (!mock && !promoteToForeground()) {
            // A superseded start has nothing to report to the current session.
            if (!superseded) failStart("Android refused to start the foreground service")
            return START_NOT_STICKY
        }
        if (superseded) {
            // Dart stopped (or restarted) before Android delivered this start.
            Log.i(TAG, "Start was superseded before delivery; ignoring it")
            stopForeground(STOP_FOREGROUND_REMOVE)
            return START_NOT_STICKY
        }
        if (sessionId == null || peerId < 0) {
            failStart("Missing start extras")
            return START_NOT_STICKY
        }
        if (!mock && !hasBluetoothPermissions(this)) {
            failStart("Bluetooth permissions are not granted")
            return START_NOT_STICKY
        }

        mockSource?.stop()
        mockSource = null
        distanceEstimator.clear()

        if (mock) {
            // A racing stop may have left the BLE host running, so always
            // quiesce it before switching to mock mode. An earlier BLE session
            // the current Dart side never stopped (e.g. the app was swiped away
            // and reopened) may also have left the notification up.
            quiesceBleHost()
            stopForeground(STOP_FOREGROUND_REMOVE)
            // Mock mode has no transport, but the supplier still holds the
            // status this device broadcasts so updateStatus keeps working.
            // Reuse the BLE host's supplier if one exists — the host keeps
            // serving whatever supplier it was built with.
            val supplier = payloadSupplier
            if (supplier == null) {
                payloadSupplier = StatusPayloadSupplier(peerId)
            } else {
                supplier.updatePeerId(peerId)
            }
            startMockSource()
        } else {
            startOrResumeBleHost(sessionId, peerId)
        }
        return START_STICKY
    }

    /** Ends a start that cannot proceed and tells Dart, instead of leaving it to time out. */
    private fun failStart(reason: String) {
        Log.e(TAG, "Start failed: $reason")
        stopForeground(STOP_FOREGROUND_REMOVE)
        emitError("start_failed", reason)
        stopSelf()
    }

    override fun onDestroy() {
        // Android can destroy the service on its own, e.g. a mock-mode (plain,
        // non-foreground) service about a minute after the app is backgrounded.
        // Tell Dart so it does not keep showing a bridge that is gone.
        if (isRunning) emitError("service_stopped", "Android stopped the proximity service")

        // Real teardown: the cached host dies with the service. Frames already
        // queued still go out; nothing new can be queued after this.
        frameSender.shutdown()
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
            // Tell recently seen peers we are back so they do not keep our
            // cached offline payload until the next re-read.
            val hello = supplier.currentFrame()
            frameSender.execute { host.immediateSendAll(hello) }
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
        // on the same session find each other. Herald's standard and legacy
        // (pre-2.1) services are disabled to keep this app isolated from
        // other Herald traffic; legacy detection is on by default.
        BLESensorConfiguration.payloadDataUpdateTimeInterval = PAYLOAD_REFRESH
        BLESensorConfiguration.customServiceUUID = UUID.fromString(sessionId)
        BLESensorConfiguration.customServiceDetectionEnabled = true
        BLESensorConfiguration.customServiceAdvertisingEnabled = true
        BLESensorConfiguration.standardHeraldServiceDetectionEnabled = false
        BLESensorConfiguration.standardHeraldServiceAdvertisingEnabled = false
        BLESensorConfiguration.legacyHeraldServiceDetectionEnabled = false
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
            failStart("Herald failed to start: ${e.message}")
        }
    }

    /** Flags us offline, sends goodbye frames, then stops the host once they are out. */
    private fun quiesceBleHost() {
        val host = sensorArray ?: return

        val goodbye = payloadSupplier?.let { supplier ->
            supplier.setOffline(true)
            supplier.currentFrame()
        }
        frameSender.execute {
            // Returns only after Herald has finished with every peer.
            if (goodbye != null) host.immediateSendAll(goodbye)
            mainThread.post {
                // A BLE start raced in while the goodbye went out, so leave
                // the host up.
                if (sourceMode != SourceMode.BLE) host.stop()
            }
        }
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

    private fun emit(event: Map<String, Any>) = withSink { it.success(event) }

    private fun emitError(code: String, message: String) {
        mainThread.post { withSink { it.error(code, message, null) } }
    }

    /** Runs [send] against the current sink. Main thread only. */
    private fun withSink(send: (EventChannel.EventSink) -> Unit) {
        synchronized(sinkLock) {
            val sink = eventSink ?: return
            try {
                send(sink)
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
        if (isRunning) sendReady()
    }

    override fun onCancel(arguments: Any?) {
        // Queued emits become no-ops once the sink is cleared. Do not wipe
        // pending callbacks because quiesce still needs to run.
        synchronized(sinkLock) { eventSink = null }
    }

    // ----- Foreground promotion -------------------------------------------------

    /** Returns false if Android refused the promotion. */
    private fun promoteToForeground(): Boolean {
        val notification = buildNotification()
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            true
        } catch (e: Exception) {
            // On Android 14+ the connectedDevice type is refused unless a
            // Bluetooth permission is granted. MainActivity checks first, so
            // this is a backstop rather than the normal path.
            Log.e(TAG, "Foreground promotion failed", e)
            false
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
