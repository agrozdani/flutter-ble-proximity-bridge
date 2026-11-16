import Flutter
import Herald
import UIKit

/// Registers the platform channels and dispatches method calls. The channel
/// names here must match lib/src/bridge/channel_names.dart.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  // MARK: - Channel contract

  private let methodChannelName = "ble_proximity_bridge/methods"
  private let eventChannelName = "ble_proximity_bridge/events"

  private let startMethod = "start"
  private let stopMethod = "stop"
  private let updateStatusMethod = "updateStatus"
  private let forgetPeerMethod = "forgetPeer"

  private let sessionIdArg = "sessionId"
  private let peerIdArg = "peerId"
  private let mockArg = "mock"
  private let statusArg = "status"
  private let colorArg = "color"

  // Diagnostics: see docs/logging.md and LogChannels in Dart.
  private let logMethodChannelName = "ble_proximity_bridge/log"
  private let logEventChannelName = "ble_proximity_bridge/logs"
  private let logConfigureMethod = "configure"
  private let logWriteMethod = "write"
  private let logLevelArg = "level"
  private let logHeraldArg = "herald"
  private let logLinesArg = "lines"
  private let logPrintedArg = "printed"
  private let logFileKey = "file"
  private let logEchoKey = "echo"
  private let logPrintsDartKey = "printsDart"

  // MARK: - Engine setup

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // The first log call opens the log file and writes its header.
    BridgeLog.i("app", "Flutter engine initialized; registering channels")
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    setupBridgeChannels(messenger: engineBridge.applicationRegistrar.messenger())
    setupLogChannels(messenger: engineBridge.applicationRegistrar.messenger())
  }

  // MARK: - Channel setup

  private func setupBridgeChannels(messenger: FlutterBinaryMessenger) {
    let methodChannel = FlutterMethodChannel(
      name: methodChannelName, binaryMessenger: messenger)
    let eventChannel = FlutterEventChannel(
      name: eventChannelName, binaryMessenger: messenger)

    // The controller exists from launch, so the stream handler can be
    // registered right away (no pending-sink dance like on Android).
    eventChannel.setStreamHandler(ProximityController.shared)

    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "gone", message: "AppDelegate deallocated", details: nil))
        return
      }
      switch call.method {
      case self.startMethod:
        self.handleStart(call: call, result: result)
      case self.stopMethod:
        self.handleStop(result: result)
      case self.updateStatusMethod:
        self.handleUpdateStatus(call: call, result: result)
      case self.forgetPeerMethod:
        self.handleForgetPeer(call: call, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func setupLogChannels(messenger: FlutterBinaryMessenger) {
    FlutterEventChannel(name: logEventChannelName, binaryMessenger: messenger)
      .setStreamHandler(LogStreamHandler())

    let methods = FlutterMethodChannel(name: logMethodChannelName, binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      let args = call.arguments as? [String: Any]
      switch call.method {
      case self.logWriteMethod:
        // Absent (an older Dart side): Dart printed them.
        BridgeLog.writeFromDart(
          args?[self.logLinesArg] as? [String] ?? [],
          printed: args?[self.logPrintedArg] as? Bool ?? true)
        result(nil)
      case self.logConfigureMethod:
        let herald = (args?[self.logHeraldArg] as? String).flatMap(SensorLoggerLevel.init(rawValue:))
        BridgeLog.configure(
          level: BridgeLog.Level(name: args?[self.logLevelArg] as? String), herald: herald)
        result([
          self.logFileKey: BridgeLog.shared.currentFile?.path as Any,
          self.logEchoKey: BridgeLog.dartShouldEcho,
          self.logPrintsDartKey: BridgeLog.printsDartLines,
        ])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - Method handlers

  private func reject(
    _ result: FlutterResult, _ method: String, code: String, message: String
  ) {
    BridgeLog.w("method", "\(method) rejected: \(code): \(message)")
    result(FlutterError(code: code, message: message, details: nil))
  }

  private func handleStart(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let described = (call.arguments as? [String: Any]).map { args in
      "start session=\(args[sessionIdArg] ?? "nil") "
        + "self=\((args[peerIdArg] as? Int).map(peerHex) ?? "nil") "
        + "mock=\((args[mockArg] as? Bool).map(String.init) ?? "nil")"
    }
    BridgeLog.i("method", described ?? "start without arguments")
    guard let args = call.arguments as? [String: Any],
      let sessionId = args[sessionIdArg] as? String,
      let peerId = args[peerIdArg] as? Int
    else {
      reject(result, "start", code: "bad_args", message: "start requires sessionId and peerId")
      return
    }
    // Validate here, matching Android: the session id becomes the BLE service
    // UUID (CBUUID(string:) raises on malformed input).
    guard UUID(uuidString: sessionId) != nil, peerId >= 0 else {
      reject(
        result, "start", code: "bad_args",
        message: "sessionId must be a UUID string and peerId non-negative")
      return
    }
    let mock = args[mockArg] as? Bool ?? false

    ProximityController.shared.start(peerId: peerId, sessionId: sessionId, mock: mock)
    result(true)
  }

  private func handleStop(result: @escaping FlutterResult) {
    BridgeLog.i("method", "stop (running=\(ProximityController.shared.isRunning))")
    // Stopping while not running is fine; Dart calls stop defensively.
    ProximityController.shared.stop()
    result(nil)
  }

  private func handleUpdateStatus(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let status = args[statusArg] as? Int,
      let color = args[colorArg] as? Int
    else {
      reject(result, "updateStatus", code: "bad_args", message: "updateStatus requires status and color")
      return
    }
    // Gate on isRunning, not just on the supplier: the supplier stays warm
    // across logical stops so lingering peers can read the offline payload,
    // but updateStatus is only valid while a source runs.
    let controller = ProximityController.shared
    guard controller.isRunning, let supplier = controller.payloadSupplier else {
      reject(result, "updateStatus", code: "not_running", message: "updateStatus requires a running bridge")
      return
    }
    BridgeLog.i("method", "updateStatus status=\(status) color=\(color)")
    supplier.update(status: status, color: color)
    result(nil)
  }

  private func handleForgetPeer(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let peerId = args[peerIdArg] as? Int
    else {
      reject(result, "forgetPeer", code: "bad_args", message: "forgetPeer requires peerId")
      return
    }
    BridgeLog.d("method", "forgetPeer \(peerHex(peerId))")
    ProximityController.shared.distanceEstimator.forget(peerId: peerId)
    result(nil)
  }
}

/// The logs event channel: hands the sink to BridgeLog, which flushes the
/// lines logged while nobody listened.
private final class LogStreamHandler: NSObject, FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    BridgeLog.attachDart(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    BridgeLog.attachDart(nil)
    return nil
  }
}
