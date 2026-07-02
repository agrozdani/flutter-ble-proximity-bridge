import 'package:ble_proximity_bridge/src/bridge/channel_names.dart';
import 'package:ble_proximity_bridge/src/models/peer.dart';
import 'package:ble_proximity_bridge/src/providers/bridge_provider.dart';
import 'package:ble_proximity_bridge/src/providers/peers_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// End-to-end test of the Dart half of the bridge: the controller's start
/// sequence (subscribe → invoke start → await ready → push status), peer
/// ingestion into the peers map, and teardown — with the native side played
/// by mock channel handlers.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel(BridgeChannels.methods);
  const eventChannel = EventChannel(BridgeChannels.events);

  final methodCalls = <MethodCall>[];

  setUp(() {
    methodCalls.clear();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          methodCalls.add(call);
          return call.method == BridgeMethods.start ? true : null;
        });

    // Play the native event stream: ready handshake on subscribe, then two
    // sightings of the same peer (the second carrying fresher data).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          eventChannel,
          MockStreamHandler.inline(
            onListen: (arguments, events) {
              events.success({BridgeEventKeys.type: BridgeEventKeys.typeReady});
              events.success({
                BridgeEventKeys.type: BridgeEventKeys.typePeer,
                BridgeEventKeys.id: 7,
                BridgeEventKeys.status: PeerStatus.chatty.code,
                BridgeEventKeys.color: 3,
                BridgeEventKeys.device: 1,
                BridgeEventKeys.rssi: -60.0,
                BridgeEventKeys.distance: 1.5,
              });
              events.success({
                BridgeEventKeys.type: BridgeEventKeys.typePeer,
                BridgeEventKeys.id: 7,
                BridgeEventKeys.status: PeerStatus.busy.code,
                BridgeEventKeys.color: 3,
                BridgeEventKeys.device: 1,
              });
            },
          ),
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(eventChannel, null);
  });

  test('start completes the handshake and ingests peer sightings', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(bridgeProvider.notifier).start(mock: true);

    final bridge = container.read(bridgeProvider);
    expect(bridge.phase, BridgePhase.running);
    expect(bridge.mockMode, isTrue);

    // The controller pushed our broadcast status right after ready.
    expect(
      methodCalls.map((call) => call.method),
      containsAllInOrder([BridgeMethods.start, BridgeMethods.updateStatus]),
    );

    // Both sightings were folded into one peer; measurements from the first
    // sighting survive the second one, which carried none.
    final peer = container.read(peersProvider)[7];
    expect(peer, isNotNull);
    expect(peer!.colorIndex, 3);
    expect(peer.deviceKind, DeviceKind.android);
    expect(peer.rssi, -60.0);
    expect(peer.distance, 1.5);

    await container.read(bridgeProvider.notifier).stop();
    expect(container.read(bridgeProvider).phase, BridgePhase.idle);
    expect(container.read(peersProvider), isEmpty);
    expect(methodCalls.last.method, BridgeMethods.stop);
  });

  test('bridge can stop and start again cleanly', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final controller = container.read(bridgeProvider.notifier);

    await controller.start(mock: true);
    await controller.stop();
    expect(container.read(bridgeProvider).phase, BridgePhase.idle);
    expect(container.read(peersProvider), isEmpty);

    await controller.start(mock: true);

    final bridge = container.read(bridgeProvider);
    expect(bridge.phase, BridgePhase.running);
    expect(
      methodCalls.map((call) => call.method),
      containsAllInOrder([
        BridgeMethods.start,
        BridgeMethods.updateStatus,
        BridgeMethods.stop,
        BridgeMethods.start,
        BridgeMethods.updateStatus,
      ]),
    );
  });

  test('a peer goodbye removes the peer immediately', () async {
    // Replay: ready, a sighting of peer 7, then peer 7's goodbye.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          eventChannel,
          MockStreamHandler.inline(
            onListen: (arguments, events) {
              events.success({BridgeEventKeys.type: BridgeEventKeys.typeReady});
              events.success({
                BridgeEventKeys.type: BridgeEventKeys.typePeer,
                BridgeEventKeys.id: 7,
                BridgeEventKeys.status: PeerStatus.available.code,
                BridgeEventKeys.color: 1,
                BridgeEventKeys.device: 0,
                BridgeEventKeys.rssi: -55.0,
              });
              events.success({
                BridgeEventKeys.type: BridgeEventKeys.typeGone,
                BridgeEventKeys.id: 7,
              });
            },
          ),
        );

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(bridgeProvider.notifier).start(mock: true);
    // start() returns on the ready event; let the queued sighting and
    // goodbye flush through the stream before asserting.
    await pumpEventQueue();

    // The goodbye removed the peer without waiting for staleness eviction,
    // and Dart freed the native distance model for it.
    expect(container.read(peersProvider), isEmpty);
    expect(
      methodCalls
          .where((call) => call.method == BridgeMethods.forgetPeer)
          .map((call) => (call.arguments as Map)[BridgeArgs.peerId]),
      contains(7),
    );
  });

  test('start fails fast when the event stream errors mid-handshake', () async {
    // The stream dying before ready must fail the start immediately, not
    // after the 10 s ready timeout runs out.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          eventChannel,
          MockStreamHandler.inline(
            onListen: (arguments, events) {
              events.error(code: 'boom', message: 'stack died');
            },
          ),
        );

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container
        .read(bridgeProvider.notifier)
        .start(mock: true)
        .timeout(const Duration(seconds: 5));

    final bridge = container.read(bridgeProvider);
    expect(bridge.phase, BridgePhase.error);
    expect(bridge.error, contains('stack died'));
  });

  test('start fails cleanly when the native side rejects it', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          methodCalls.add(call);
          return call.method == BridgeMethods.start ? false : null;
        });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(bridgeProvider.notifier).start(mock: true);

    final bridge = container.read(bridgeProvider);
    expect(bridge.phase, BridgePhase.error);
    expect(bridge.error, isNotNull);
    // Teardown invoked stop defensively even though start never succeeded.
    expect(methodCalls.last.method, BridgeMethods.stop);
  });
}
