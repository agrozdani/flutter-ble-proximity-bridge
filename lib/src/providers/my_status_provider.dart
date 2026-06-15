import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/my_status.dart';
import '../models/peer.dart';
import 'bridge_provider.dart';
import 'channel_providers.dart';

final myStatusProvider = NotifierProvider<MyStatusController, MyStatus>(
  MyStatusController.new,
);

/// Our broadcast status. Pushes changes to the native side while the
/// bridge is running.
class MyStatusController extends Notifier<MyStatus> {
  @override
  MyStatus build() => const MyStatus();

  Future<void> setStatus(PeerStatus status) =>
      _update(state.copyWith(status: status));

  Future<void> setColor(int colorIndex) =>
      _update(state.copyWith(colorIndex: colorIndex));

  Future<void> _update(MyStatus next) async {
    state = next;
    // Nothing to push while the bridge is down; start() sends the latest
    // value right after the handshake.
    if (ref.read(bridgeProvider).isRunning) {
      await ref
          .read(methodChannelProvider)
          .updateStatus(status: next.status.code, color: next.colorIndex);
    }
  }
}
