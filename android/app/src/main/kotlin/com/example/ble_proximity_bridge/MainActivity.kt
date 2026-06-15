package com.example.ble_proximity_bridge

import android.content.Intent
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Registers the platform channels and handles method calls. These names
 * must stay in sync with lib/src/bridge/channel_names.dart.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val TAG = "MainActivity"

        const val METHOD_CHANNEL = "ble_proximity_bridge/methods"
        const val EVENT_CHANNEL = "ble_proximity_bridge/events"

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
                        Log.i(TAG, "Service not running; parking event sink")
                        ProximityService.parkPendingSink(events)
                    }
                }

                override fun onCancel(arguments: Any?) {
                    val service = ProximityService.instance()
                    if (service != null) {
                        service.onCancel(arguments)
                    } else {
                        ProximityService.parkPendingSink(null)
                    }
                }
            })
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
        if (sessionId == null || peerId == null) {
            result.error("bad_args", "start requires sessionId and peerId", null)
            return
        }

        try {
            val intent = Intent(this, ProximityService::class.java)
                .putExtra(ProximityService.EXTRA_SESSION_ID, sessionId)
                .putExtra(ProximityService.EXTRA_PEER_ID, peerId)
                .putExtra(ProximityService.EXTRA_MOCK, mock)
            if (!mock && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                // Mock mode does not need Bluetooth permissions, so a plain
                // service start is enough.
                startService(intent)
            }
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start ProximityService", e)
            result.error("start_failed", e.message, null)
        }
    }

    private fun handleStop(result: MethodChannel.Result) {
        // Stopping when already stopped is fine. The service stays warm so
        // the next start can reuse the Herald stack.
        ProximityService.instance()?.stopProximity()
        result.success(null)
    }

    private fun handleUpdateStatus(call: MethodCall, result: MethodChannel.Result) {
        val status = call.argument<Int>(ARG_STATUS)
        val color = call.argument<Int>(ARG_COLOR)
        if (status == null || color == null) {
            result.error("bad_args", "updateStatus requires status and color", null)
            return
        }
        val supplier = ProximityService.instance()?.payloadSupplier
        if (supplier == null) {
            result.error("not_running", "updateStatus requires a running bridge", null)
            return
        }
        supplier.update(status, color)
        result.success(null)
    }

    private fun handleForgetPeer(call: MethodCall, result: MethodChannel.Result) {
        val peerId = call.argument<Number>(ARG_PEER_ID)?.toLong()
        if (peerId == null) {
            result.error("bad_args", "forgetPeer requires peerId", null)
            return
        }
        ProximityService.instance()?.distanceEstimator?.forget(peerId)
        result.success(null)
    }
}
