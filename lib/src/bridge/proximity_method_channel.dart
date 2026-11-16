import 'package:flutter/services.dart';

import '../logging/log.dart';
import 'channel_names.dart';

/// Typed wrapper around the command channel.
///
/// Keeps the invokeMethod strings in one place and lets tests swap in a
/// mocked channel. Every call is traced to the log (`dart.channel`): what
/// went out, what came back, and how long native took.
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
    final accepted = await _invoke<bool>(BridgeMethods.start, {
      BridgeArgs.sessionId: sessionId,
      BridgeArgs.peerId: peerId,
      BridgeArgs.mock: mock,
    });
    return accepted ?? false;
  }

  /// Stops proximity detection.
  Future<void> stop() => _invoke<void>(BridgeMethods.stop);

  /// Updates the payload we broadcast. Peers pick it up on their next read.
  Future<void> updateStatus({required int status, required int color}) {
    return _invoke<void>(BridgeMethods.updateStatus, {
      BridgeArgs.status: status,
      BridgeArgs.color: color,
    });
  }

  /// Tells the native side a peer is gone so it can free that peer's
  /// distance model. Without this, native state just keeps growing.
  Future<void> forgetPeer(int peerId) {
    return _invoke<void>(BridgeMethods.forgetPeer, {BridgeArgs.peerId: peerId});
  }

  Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    final described = _describe(arguments);
    Log.d('channel', '→ $method$described');
    final watch = Stopwatch()..start();
    try {
      final result = await _channel.invokeMethod<T>(method, arguments);
      Log.d(
        'channel',
        '← $method ok${result == null ? '' : ' $result'} '
            '${watch.elapsedMilliseconds}ms',
      );
      return result;
    } on PlatformException catch (error) {
      Log.w(
        'channel',
        '← $method failed ${error.code}: ${error.message} '
            '${watch.elapsedMilliseconds}ms',
      );
      rethrow;
    } on MissingPluginException {
      Log.e('channel', '← $method: no native handler (channel not registered)');
      rethrow;
    }
  }

  static String _describe(Map<String, Object?>? arguments) {
    if (arguments == null || arguments.isEmpty) return '';
    final parts = arguments.entries.map((entry) {
      final value = entry.value;
      // Peer ids as every log line writes them, so they can be grepped.
      if (entry.key == BridgeArgs.peerId && value is int) {
        return '${entry.key}=${peerHex(value)}';
      }
      return '${entry.key}=$value';
    });
    return ' ${parts.join(' ')}';
  }
}
