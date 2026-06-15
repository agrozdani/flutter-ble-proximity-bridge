import 'package:flutter/services.dart';

import 'channel_names.dart';

/// Typed wrapper around the command channel.
///
/// Keeps the invokeMethod strings in one place and lets tests swap in a
/// mocked channel.
class ProximityMethodChannel {
  ProximityMethodChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(BridgeChannels.methods);

  final MethodChannel _channel;

  /// Starts proximity detection.
  ///
  /// [sessionId] becomes the BLE service UUID, so only devices using the
  /// same id see each other. [peerId] is the id we broadcast as. With
  /// [mock] the native side fakes peers instead of using Bluetooth.
  ///
  /// A true result only means the request was accepted. Wait for the
  /// `ready` event before pushing anything.
  Future<bool> start({
    required String sessionId,
    required int peerId,
    bool mock = false,
  }) async {
    final accepted = await _channel.invokeMethod<bool>(BridgeMethods.start, {
      BridgeArgs.sessionId: sessionId,
      BridgeArgs.peerId: peerId,
      BridgeArgs.mock: mock,
    });
    return accepted ?? false;
  }

  /// Stops proximity detection.
  Future<void> stop() => _channel.invokeMethod<void>(BridgeMethods.stop);

  /// Updates the payload we broadcast. Peers pick it up on their next read.
  Future<void> updateStatus({required int status, required int color}) {
    return _channel.invokeMethod<void>(BridgeMethods.updateStatus, {
      BridgeArgs.status: status,
      BridgeArgs.color: color,
    });
  }

  /// Tells the native side a peer is gone so it can free that peer's
  /// distance model. Without this, native state just keeps growing.
  Future<void> forgetPeer(int peerId) {
    return _channel.invokeMethod<void>(BridgeMethods.forgetPeer, {
      BridgeArgs.peerId: peerId,
    });
  }
}
