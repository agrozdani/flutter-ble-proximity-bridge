/// The status a device broadcasts to nearby peers.
///
/// Only [code] goes over the wire; emoji and label are resolved locally.
/// Codes we don't recognize map to [PeerStatus.unknown].
enum PeerStatus {
  available(0, '😊', 'Available'),
  busy(1, '⛔', 'Busy'),
  chatty(2, '💬', 'Up for a chat'),
  away(3, '🌙', 'Away'),
  unknown(-1, '❓', 'Unknown');

  const PeerStatus(this.code, this.emoji, this.label);

  final int code;
  final String emoji;
  final String label;

  static PeerStatus fromCode(int code) => values.firstWhere(
    (status) => status.code == code,
    orElse: () => PeerStatus.unknown,
  );
}

/// Which platform a peer is running on.
///
/// iPhones report stronger RSSI than most Androids at the same distance,
/// so the distance estimator needs to know who sent the signal. That's why
/// this travels in the payload.
enum DeviceKind {
  ios(0),
  android(1),
  unknown(-1);

  const DeviceKind(this.code);

  final int code;

  static DeviceKind fromCode(int code) => values.firstWhere(
    (kind) => kind.code == code,
    orElse: () => DeviceKind.unknown,
  );
}

/// What we currently know about one nearby peer, built up from many raw
/// sightings by `PeersController`.
class Peer {
  const Peer({
    required this.id,
    required this.status,
    required this.colorIndex,
    required this.deviceKind,
    required this.firstSeen,
    required this.lastSeen,
    this.rssi,
    this.distance,
  });

  final int id;
  final PeerStatus status;
  final int colorIndex;
  final DeviceKind deviceKind;

  /// Last raw signal strength in dBm, if we have one.
  final double? rssi;

  /// Smoothed distance estimate in meters. Always one of the coarse buckets
  /// (0.5 / 1.5 / 3.5 / 8.0) because RSSI is too noisy for anything finer.
  final double? distance;

  final DateTime firstSeen;
  final DateTime lastSeen;

  /// Label for the distance bucket.
  String get distanceLabel => switch (distance) {
    null => 'Searching',
    <= 0.75 => 'Immediate',
    <= 2.0 => 'Near',
    <= 5.0 => 'Medium',
    _ => 'Far',
  };

  /// Hex form of the id, easier on the eyes than a ten-digit number.
  String get shortId => id.toRadixString(16).toUpperCase().padLeft(8, '0');
}
