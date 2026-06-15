import 'peer.dart';

/// The status and color this device is currently broadcasting.
class MyStatus {
  const MyStatus({this.status = PeerStatus.available, this.colorIndex = 0});

  final PeerStatus status;
  final int colorIndex;

  MyStatus copyWith({PeerStatus? status, int? colorIndex}) => MyStatus(
    status: status ?? this.status,
    colorIndex: colorIndex ?? this.colorIndex,
  );
}
