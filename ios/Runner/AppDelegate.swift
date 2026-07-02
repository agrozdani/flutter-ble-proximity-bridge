import Flutter
import UIKit
import os.log

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

  // MARK: - Application lifecycle

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // iOS can relaunch a killed app in the background to deliver Bluetooth
    // events. These launch keys are the only way to tell that happened.
    if let centrals = launchOptions?[.bluetoothCentrals] as? [String], !centrals.isEmpty {
      os_log("Launched for Bluetooth central state restoration", type: .info)
    }
    if let peripherals = launchOptions?[.bluetoothPeripherals] as? [String], !peripherals.isEmpty {
      os_log("Launched for Bluetooth peripheral state restoration", type: .info)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    setupBridgeChannels(messenger: engineBridge.applicationRegistrar.messenger())
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

  // MARK: - Method handlers

  private func handleStart(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let sessionId = args[sessionIdArg] as? String,
      let peerId = args[peerIdArg] as? Int
    else {
      result(FlutterError(code: "bad_args", message: "start requires sessionId and peerId", details: nil))
      return
    }
    let mock = args[mockArg] as? Bool ?? false

    ProximityController.shared.start(peerId: peerId, sessionId: sessionId, mock: mock)
    result(true)
  }

  private func handleStop(result: @escaping FlutterResult) {
    // Stopping while not running is fine; Dart calls stop defensively.
    ProximityController.shared.stop()
    result(nil)
  }

  private func handleUpdateStatus(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let status = args[statusArg] as? Int,
      let color = args[colorArg] as? Int
    else {
      result(FlutterError(code: "bad_args", message: "updateStatus requires status and color", details: nil))
      return
    }
    // Gate on isRunning, not just on the supplier: the supplier stays warm
    // across logical stops so lingering peers can read the offline payload,
    // but updateStatus is only valid while a source runs.
    let controller = ProximityController.shared
    guard controller.isRunning, let supplier = controller.payloadSupplier else {
      result(FlutterError(code: "not_running", message: "updateStatus requires a running bridge", details: nil))
      return
    }
    supplier.update(status: status, color: color)
    result(nil)
  }

  private func handleForgetPeer(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let peerId = args[peerIdArg] as? Int
    else {
      result(FlutterError(code: "bad_args", message: "forgetPeer requires peerId", details: nil))
      return
    }
    ProximityController.shared.distanceEstimator.forget(peerId: peerId)
    result(nil)
  }
}
