import 'package:ble_proximity_bridge/src/bridge/channel_names.dart';
import 'package:ble_proximity_bridge/src/models/bridge_event.dart';
import 'package:ble_proximity_bridge/src/models/peer.dart';
import 'package:ble_proximity_bridge/src/providers/peers_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The eviction window: how long a peer may go unheard before it is
/// dropped, which depends on how the receiving platform listens.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel(BridgeChannels.methods);
  final forgotten = <int>[];

  setUp(() {
    forgotten.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          if (call.method == BridgeMethods.forgetPeer) {
            forgotten.add((call.arguments as Map)[BridgeArgs.peerId] as int);
          }
          return null;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
  });

  const sighting = PeerSighting(
    id: 7,
    statusCode: 0,
    colorIndex: 1,
    deviceKind: DeviceKind.ios,
    rssi: -60,
    distance: 1.5,
  );

  /// Lists peer 7 on [platform] and returns when it was heard.
  (ProviderContainer, PeersController, DateTime) listPeer(
    TargetPlatform platform,
  ) {
    debugDefaultTargetPlatformOverride = platform;
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final peers = container.read(peersProvider.notifier);
    final heard = DateTime.now();
    peers.applySighting(sighting);
    return (container, peers, heard);
  }

  test(
    'Android keeps a peer through a minute of Herald not listening',
    () async {
      final (container, peers, heard) = listPeer(TargetPlatform.android);

      // Herald for Android went 60 s without scanning while it tried to
      // identify other devices nearby: the peer is still there.
      peers.evictStale(heard.add(const Duration(seconds: 70)));
      expect(container.read(peersProvider).keys, [7]);

      peers.evictStale(heard.add(const Duration(seconds: 91)));
      expect(container.read(peersProvider), isEmpty);
      await pumpEventQueue();
      expect(forgotten, [7]);
    },
  );

  test('iOS drops a peer after 20 s without a sighting', () async {
    final (container, peers, heard) = listPeer(TargetPlatform.iOS);

    peers.evictStale(heard.add(const Duration(seconds: 15)));
    expect(container.read(peersProvider).keys, [7]);

    peers.evictStale(heard.add(const Duration(seconds: 21)));
    expect(container.read(peersProvider), isEmpty);
    await pumpEventQueue();
    expect(forgotten, [7]);
  });
}
