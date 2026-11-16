package com.example.ble_proximity_bridge

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.heraldprox.herald.sensor.data.SensorLoggerLevel
import java.util.UUID

/**
 * Registers the platform channels and handles method calls. These names
 * must stay in sync with lib/src/bridge/channel_names.dart.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val METHOD_CHANNEL = "ble_proximity_bridge/methods"
        const val EVENT_CHANNEL = "ble_proximity_bridge/events"

        // Diagnostics: see docs/logging.md and LogChannels in Dart.
        const val LOG_METHOD_CHANNEL = "ble_proximity_bridge/log"
        const val LOG_EVENT_CHANNEL = "ble_proximity_bridge/logs"
        const val LOG_METHOD_CONFIGURE = "configure"
        const val LOG_METHOD_WRITE = "write"
        const val LOG_ARG_LEVEL = "level"
        const val LOG_ARG_HERALD = "herald"
        const val LOG_ARG_LINES = "lines"
        const val LOG_ARG_FILE = "file"
        const val LOG_ARG_ECHO = "echo"

        const val METHOD_START = "start"
        const val METHOD_STOP = "stop"
        const val METHOD_UPDATE_STATUS = "updateStatus"
        const val METHOD_FORGET_PEER = "forgetPeer"

        const val ARG_SESSION_ID = "sessionId"
        const val ARG_PEER_ID = "peerId"
        const val ARG_MOCK = "mock"
        const val ARG_STATUS = "status"
        const val ARG_COLOR = "color"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        BridgeLog.start(applicationContext)
        BridgeLog.i(
            "activity",
            "Flutter engine attached; service ${if (ProximityService.instance() != null) "already running" else "not running"}",
        )
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, METHOD_CHANNEL)
            .setMethodCallHandler(::handleMethodCall)

        // The service owns the sink. If it is not up yet, park the sink
        // here and let the service claim it in onCreate.
        EventChannel(messenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    val service = ProximityService.instance()
                    if (service != null) {
                        service.onListen(arguments, events)
                    } else {
                        BridgeLog.i("sink", "Dart subscribed before the service exists; parking the sink")
                        ProximityService.parkPendingSink(events)
                    }
                }

                override fun onCancel(arguments: Any?) {
                    val service = ProximityService.instance()
                    if (service != null) {
                        service.onCancel(arguments)
                    } else {
                        BridgeLog.i("sink", "Dart cancelled; dropping the parked sink")
                        ProximityService.parkPendingSink(null)
                    }
                }
            })

        MethodChannel(messenger, LOG_METHOD_CHANNEL).setMethodCallHandler(::handleLogCall)
        EventChannel(messenger, LOG_EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    BridgeLog.attachDart(events)
                }

                override fun onCancel(arguments: Any?) {
                    BridgeLog.attachDart(null)
                }
            })
    }

    override fun onDestroy() {
        // The service (and BLE) can outlive the activity, e.g. after a swipe
        // away; the next activity reattaches to it.
        BridgeLog.i(
            "activity",
            "destroyed (finishing=$isFinishing, service ${if (ProximityService.instance() != null) "keeps running" else "not running"})",
        )
        super.onDestroy()
    }

    private fun handleLogCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            LOG_METHOD_WRITE -> {
                val lines = call.argument<List<String>>(LOG_ARG_LINES).orEmpty()
                BridgeLog.writeFromDart(lines)
                result.success(null)
            }
            LOG_METHOD_CONFIGURE -> {
                val level = BridgeLog.Level.parse(call.argument<String>(LOG_ARG_LEVEL))
                val herald = when (call.argument<String>(LOG_ARG_HERALD)) {
                    "off" -> SensorLoggerLevel.off
                    "fault" -> SensorLoggerLevel.fault
                    "info" -> SensorLoggerLevel.info
                    "debug" -> SensorLoggerLevel.debug
                    else -> null
                }
                BridgeLog.configure(level, herald)
                // flutter run already shows every logcat line from the app's
                // process, so Dart must not print native lines again. Dart
                // prints its own lines here (no `printsDart` in the answer):
                // they go to logcat, which never makes the writer wait.
                result.success(
                    mapOf(LOG_ARG_FILE to BridgeLog.currentFile?.absolutePath, LOG_ARG_ECHO to false),
                )
            }
            else -> result.notImplemented()
        }
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            METHOD_START -> handleStart(call, result)
            METHOD_STOP -> handleStop(result)
            METHOD_UPDATE_STATUS -> handleUpdateStatus(call, result)
            METHOD_FORGET_PEER -> handleForgetPeer(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleStart(call: MethodCall, result: MethodChannel.Result) {
        val sessionId = call.argument<String>(ARG_SESSION_ID)
        // Dart ints can arrive as Integer or Long, so normalize through Number.
        val peerId = call.argument<Number>(ARG_PEER_ID)?.toLong()
        val mock = call.argument<Boolean>(ARG_MOCK) ?: false
        BridgeLog.i(
            "method",
            "start session=$sessionId self=${peerId?.let(::peerHex)} mock=$mock",
        )
        if (sessionId == null || peerId == null) {
            reject(result, "start", "bad_args", "start requires sessionId and peerId")
            return
        }
        // Validate here: the service turns sessionId into the BLE service UUID
        // and can only report problems after Dart has been told "accepted".
        if (!isCanonicalUuid(sessionId) || peerId < 0) {
            reject(result, "start", "bad_args", "sessionId must be a UUID string and peerId non-negative")
            return
        }

        // Refuse here rather than in the service: a service started with
        // startForegroundService() that stops without promoting crashes the app.
        if (!mock && !ProximityService.hasBluetoothPermissions(this)) {
            BridgeLog.w("method", "start: ${ProximityService.describePermissions(this)}")
            reject(result, "start", "permission_denied", "Bluetooth permissions are not granted")
            return
        }

        try {
            val command = ProximityService.nextCommand()
            val intent = Intent(this, ProximityService::class.java)
                .putExtra(ProximityService.EXTRA_SESSION_ID, sessionId)
                .putExtra(ProximityService.EXTRA_PEER_ID, peerId)
                .putExtra(ProximityService.EXTRA_MOCK, mock)
                .putExtra(ProximityService.EXTRA_COMMAND, command)
            if (!mock && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                // Mock mode does not need Bluetooth permissions, so a plain
                // service start is enough.
                startService(intent)
            }
            BridgeLog.i(
                "method",
                "start accepted as command #$command " +
                    "(${if (!mock && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) "foreground" else "plain"} service start)",
            )
            result.success(true)
        } catch (e: Exception) {
            BridgeLog.e("method", "start: Android refused to start ProximityService", e)
            result.error("start_failed", e.message, null)
        }
    }

    private fun handleStop(result: MethodChannel.Result) {
        // Stopping when already stopped is fine. The service stays warm so
        // the next start can reuse the Herald stack. Taking a command number
        // also cancels a start that Android has not delivered yet.
        val command = ProximityService.nextCommand()
        val service = ProximityService.instance()
        BridgeLog.i(
            "method",
            "stop as command #$command (service ${if (service != null) "running=${service.isRunning}" else "not created"})",
        )
        service?.stopProximity()
        result.success(null)
    }

    private fun reject(result: MethodChannel.Result, method: String, code: String, message: String) {
        BridgeLog.w("method", "$method rejected: $code: $message")
        result.error(code, message, null)
    }

    private fun isCanonicalUuid(value: String): Boolean = try {
        // UUID.fromString also accepts short forms like "1-2-3-4-5"; iOS does
        // not, so require the round trip to match.
        UUID.fromString(value).toString().equals(value, ignoreCase = true)
    } catch (e: IllegalArgumentException) {
        false
    }

    private fun handleUpdateStatus(call: MethodCall, result: MethodChannel.Result) {
        val status = call.argument<Int>(ARG_STATUS)
        val color = call.argument<Int>(ARG_COLOR)
        if (status == null || color == null) {
            reject(result, "updateStatus", "bad_args", "updateStatus requires status and color")
            return
        }
        // Gate on isRunning, not just on the supplier: the supplier stays
        // warm across logical stops so lingering peers can read the offline
        // payload, but updateStatus is only valid while a source runs.
        val service = ProximityService.instance()
        val supplier = if (service?.isRunning == true) service.payloadSupplier else null
        if (supplier == null) {
            reject(result, "updateStatus", "not_running", "updateStatus requires a running bridge")
            return
        }
        BridgeLog.i("method", "updateStatus status=$status color=$color")
        supplier.update(status, color)
        result.success(null)
    }

    private fun handleForgetPeer(call: MethodCall, result: MethodChannel.Result) {
        val peerId = call.argument<Number>(ARG_PEER_ID)?.toLong()
        if (peerId == null) {
            reject(result, "forgetPeer", "bad_args", "forgetPeer requires peerId")
            return
        }
        BridgeLog.d("method") { "forgetPeer ${peerHex(peerId)}" }
        ProximityService.instance()?.distanceEstimator?.forget(peerId)
        result.success(null)
    }
}
