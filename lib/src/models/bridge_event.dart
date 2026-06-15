import '../bridge/channel_names.dart';
import 'peer.dart';

/// Events coming from the native side, decoded from raw channel maps.
///
/// Sealed so handlers can switch exhaustively. Types we don't recognize
/// land in [UnknownBridgeEvent] instead of breaking anything.
sealed class BridgeEvent {
  const BridgeEvent();

  static BridgeEvent fromMap(Map<Object?, Object?> map) {
    return switch (map[BridgeEventKeys.type]) {
      BridgeEventKeys.typeReady => const BridgeReady(),
      BridgeEventKeys.typePeer => PeerSighting.fromMap(map),
      BridgeEventKeys.typeGone => PeerGone(map[BridgeEventKeys.id] as int),
      final other => UnknownBridgeEvent('$other'),
    };
  }
}

/// A peer told us it stopped.
///
/// BLE has no goodbye of its own (a stopped device can't kick off peers
/// that are still connected to it), so the bridge sends one at the protocol
/// level. Without this a dead peer would linger until eviction.
class PeerGone extends BridgeEvent {
  const PeerGone(this.id);

  final int id;
}

/// The native side finished initializing and the stream is live.
///
/// Don't push payload updates before this arrives. Native re-sends it to
/// late subscribers, so it can't be missed.
class BridgeReady extends BridgeEvent {
  const BridgeReady();
}

/// An event type we don't know about. Ignored.
class UnknownBridgeEvent extends BridgeEvent {
  const UnknownBridgeEvent(this.type);

  final String type;
}

/// One raw sighting of a nearby peer.
///
/// [rssi] and [distance] are optional: payload reads don't always come with
/// a measurement, and the distance estimate needs a few samples before it
/// produces anything.
class PeerSighting extends BridgeEvent {
  const PeerSighting({
    required this.id,
    required this.statusCode,
    required this.colorIndex,
    required this.deviceKind,
    this.rssi,
    this.distance,
  });

  factory PeerSighting.fromMap(Map<Object?, Object?> map) {
    return PeerSighting(
      id: map[BridgeEventKeys.id] as int,
      statusCode:
          map[BridgeEventKeys.status] as int? ?? PeerStatus.unknown.code,
      colorIndex: map[BridgeEventKeys.color] as int? ?? 0,
      deviceKind: DeviceKind.fromCode(
        map[BridgeEventKeys.device] as int? ?? -1,
      ),
      rssi: (map[BridgeEventKeys.rssi] as num?)?.toDouble(),
      distance: (map[BridgeEventKeys.distance] as num?)?.toDouble(),
    );
  }

  final int id;
  final int statusCode;
  final int colorIndex;
  final DeviceKind deviceKind;
  final double? rssi;
  final double? distance;
}
