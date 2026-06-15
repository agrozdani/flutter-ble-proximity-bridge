import 'package:ble_proximity_bridge/src/models/bridge_event.dart';
import 'package:ble_proximity_bridge/src/models/peer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BridgeEvent.fromMap', () {
    test('decodes a ready event', () {
      final event = BridgeEvent.fromMap({'type': 'ready'});
      expect(event, isA<BridgeReady>());
    });

    test('decodes a full peer sighting', () {
      final event = BridgeEvent.fromMap({
        'type': 'peer',
        'id': 0x1A2B3C4D,
        'status': 2,
        'color': 3,
        'device': 1,
        'rssi': -64.0,
        'distance': 1.5,
      });

      final sighting = event as PeerSighting;
      expect(sighting.id, 0x1A2B3C4D);
      expect(sighting.statusCode, PeerStatus.chatty.code);
      expect(sighting.colorIndex, 3);
      expect(sighting.deviceKind, DeviceKind.android);
      expect(sighting.rssi, -64.0);
      expect(sighting.distance, 1.5);
    });

    test('decodes a sighting without measurements', () {
      // A GATT payload read can arrive without a fresh RSSI sample, and the
      // distance estimator returns nothing until its window has data.
      final event = BridgeEvent.fromMap({
        'type': 'peer',
        'id': 7,
        'status': 0,
        'color': 0,
        'device': 0,
      });

      final sighting = event as PeerSighting;
      expect(sighting.rssi, isNull);
      expect(sighting.distance, isNull);
    });

    test('integer measurements are widened to double', () {
      // The standard codec delivers whole numbers as int even when the
      // native side declared them floating point.
      final event = BridgeEvent.fromMap({
        'type': 'peer',
        'id': 7,
        'status': 0,
        'color': 0,
        'device': 0,
        'rssi': -70,
        'distance': 8,
      });

      final sighting = event as PeerSighting;
      expect(sighting.rssi, -70.0);
      expect(sighting.distance, 8.0);
    });

    test('decodes a peer goodbye', () {
      final event = BridgeEvent.fromMap({'type': 'gone', 'id': 42});
      expect((event as PeerGone).id, 42);
    });

    test('tolerates unknown event types', () {
      final event = BridgeEvent.fromMap({'type': 'something_new'});
      expect(event, isA<UnknownBridgeEvent>());
    });

    test('maps out-of-range codes to unknown enum values', () {
      expect(PeerStatus.fromCode(99), PeerStatus.unknown);
      expect(DeviceKind.fromCode(99), DeviceKind.unknown);
    });
  });
}
