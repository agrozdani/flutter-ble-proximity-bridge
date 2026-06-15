import 'package:ble_proximity_bridge/src/bridge/channel_names.dart';
import 'package:ble_proximity_bridge/src/bridge/proximity_method_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verifies the Dart side of the channel contract: that each wrapper method
/// invokes the agreed method name with the agreed argument keys. The native
/// sides are written against the same contract, so this is the closest thing
/// to a cross-language interface check the bridge has.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(BridgeChannels.methods);
  final bridge = ProximityMethodChannel();
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == BridgeMethods.start ? true : null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('start sends sessionId, peerId and mock flag', () async {
    final accepted = await bridge.start(
      sessionId: 'test-session',
      peerId: 42,
      mock: true,
    );

    expect(accepted, isTrue);
    expect(calls.single.method, BridgeMethods.start);
    expect(calls.single.arguments, {
      BridgeArgs.sessionId: 'test-session',
      BridgeArgs.peerId: 42,
      BridgeArgs.mock: true,
    });
  });

  test('updateStatus sends status and color codes', () async {
    await bridge.updateStatus(status: 2, color: 4);

    expect(calls.single.method, BridgeMethods.updateStatus);
    expect(calls.single.arguments, {BridgeArgs.status: 2, BridgeArgs.color: 4});
  });

  test('forgetPeer sends the peer id', () async {
    await bridge.forgetPeer(1234);

    expect(calls.single.method, BridgeMethods.forgetPeer);
    expect(calls.single.arguments, {BridgeArgs.peerId: 1234});
  });

  test('stop sends no arguments', () async {
    await bridge.stop();

    expect(calls.single.method, BridgeMethods.stop);
    expect(calls.single.arguments, isNull);
  });
}
