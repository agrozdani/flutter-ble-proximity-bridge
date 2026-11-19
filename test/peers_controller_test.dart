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

  /// The UI throttle: at most one list update per peer per 250 ms, and the
  /// last sighting of a burst is still shown. testWidgets, so the throttle's
  /// timer runs on fake time.
  group('the UI throttle', () {
    PeerSighting reading(double rssi, {PeerStatus status = PeerStatus.busy}) =>
        PeerSighting(
          id: 7,
          statusCode: status.code,
          colorIndex: 1,
          deviceKind: DeviceKind.ios,
          rssi: rssi,
          distance: rssi > -55 ? 0.5 : 1.5,
        );

    /// A container whose peer list updates are counted.
    (ProviderContainer, PeersController, List<double?>) listen() {
      final container = ProviderContainer();
      final shown = <double?>[];
      container.listen(peersProvider, (_, peers) => shown.add(peers[7]?.rssi));
      return (container, container.read(peersProvider.notifier), shown);
    }

    testWidgets('shows the last sighting of a burst once the window ends', (
      tester,
    ) async {
      final (container, peers, shown) = listen();
      // As on a Pixel near an iPad (2026-11-16 20:28:07): a burst of
      // readings, then about a minute of silence.
      peers.applySighting(reading(-51));
      peers.applySighting(reading(-66));
      peers.applySighting(reading(-61));
      expect(container.read(peersProvider)[7]!.rssi, -51);

      await tester.pump(const Duration(milliseconds: 250));
      final peer = container.read(peersProvider)[7]!;
      expect(peer.rssi, -61);
      expect(peer.distance, 1.5);
      // Still at most one update per window: the first, then the last.
      expect(shown, [-51, -61]);
      container.dispose();
    });

    testWidgets('a held-back sighting does not bring back a removed peer', (
      tester,
    ) async {
      final (container, peers, _) = listen();
      peers.applySighting(reading(-51));
      peers.applySighting(reading(-61));
      peers.removeNow(7);

      await tester.pump(const Duration(milliseconds: 250));
      expect(container.read(peersProvider), isEmpty);
      container.dispose();
    });

    testWidgets('a change of status shows at once and replaces what was held '
        'back', (tester) async {
      final (container, peers, shown) = listen();
      peers.applySighting(reading(-51));
      peers.applySighting(reading(-61));
      peers.applySighting(reading(-70, status: PeerStatus.away));
      expect(container.read(peersProvider)[7]!.status, PeerStatus.away);

      await tester.pump(const Duration(milliseconds: 250));
      final peer = container.read(peersProvider)[7]!;
      expect(peer.status, PeerStatus.away);
      expect(peer.rssi, -70);
      expect(shown, [-51, -70]);
      container.dispose();
    });

    testWidgets('a stop clears what was held back', (tester) async {
      final (container, peers, _) = listen();
      peers.applySighting(reading(-51));
      peers.applySighting(reading(-61));
      peers.clear();

      await tester.pump(const Duration(milliseconds: 250));
      expect(container.read(peersProvider), isEmpty);
      container.dispose();
    });
  });
}
