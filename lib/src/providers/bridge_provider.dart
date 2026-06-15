import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/bridge_event.dart';
import 'channel_providers.dart';
import 'my_status_provider.dart';
import 'peers_provider.dart';

/// Every install of the demo shares this session id so devices find each
/// other out of the box. A real app would mint one per room/group.
const String kDemoSessionId = '7d9c1a4e-3b8f-4c52-a06d-95e417bb2f68';

enum BridgePhase { idle, starting, running, error }

@immutable
class BridgeState {
  const BridgeState({
    this.phase = BridgePhase.idle,
    this.mockMode = false,
    this.localPeerId,
    this.error,
  });

  final BridgePhase phase;
  final bool mockMode;

  /// The id we broadcast, shown in the UI.
  final int? localPeerId;

  final String? error;

  bool get isRunning => phase == BridgePhase.running;
}

final bridgeProvider = NotifierProvider<BridgeController, BridgeState>(
  BridgeController.new,
);

/// Drives the bridge: start/stop, the event subscription, and the ready
/// handshake.
class BridgeController extends Notifier<BridgeState> {
  /// Random id per launch. Persist one if you need peers to recognize you
  /// across restarts; the bridge itself doesn't care.
  final int _localPeerId = Random().nextInt(1 << 31);

  StreamSubscription<BridgeEvent>? _subscription;
  Completer<void>? _ready;
  AppLifecycleListener? _lifecycle;

  /// Set between start() and stop(). Lets the resume hook retry a failed
  /// start after the user comes back from Settings.
  bool _startRequested = false;

  @override
  BridgeState build() {
    _lifecycle = AppLifecycleListener(onResume: _onAppResumed);
    ref.onDispose(() {
      _subscription?.cancel();
      _lifecycle?.dispose();
    });
    return const BridgeState();
  }

  Future<void> start({bool mock = false}) async {
    if (state.phase == BridgePhase.starting || state.isRunning) return;
    _startRequested = true;
    state = BridgeState(
      phase: BridgePhase.starting,
      mockMode: mock,
      localPeerId: _localPeerId,
    );

    // Subscribe before calling start so the ready event can't slip past us.
    // Native also re-sends ready to late subscribers, so the handshake is
    // covered from both ends.
    final ready = Completer<void>();
    _ready = ready;
    await _subscription?.cancel();
    _subscription = ref
        .read(eventChannelProvider)
        .events()
        .listen(_onEvent, onError: _onStreamError);

    try {
      final accepted = await ref
          .read(methodChannelProvider)
          .start(sessionId: kDemoSessionId, peerId: _localPeerId, mock: mock);
      if (!accepted) {
        throw PlatformException(
          code: 'start_rejected',
          message: 'Native side rejected the start request',
        );
      }

      await ready.future.timeout(const Duration(seconds: 10));

      // Native starts with a blank payload; push our current status now.
      final status = ref.read(myStatusProvider);
      await ref
          .read(methodChannelProvider)
          .updateStatus(status: status.status.code, color: status.colorIndex);

      state = BridgeState(
        phase: BridgePhase.running,
        mockMode: mock,
        localPeerId: _localPeerId,
      );
    } on Exception catch (e) {
      await _teardown();
      state = BridgeState(
        phase: BridgePhase.error,
        mockMode: mock,
        localPeerId: _localPeerId,
        error: e is PlatformException ? (e.message ?? e.code) : '$e',
      );
    }
  }

  Future<void> stop() async {
    _startRequested = false;
    await _teardown();
    ref.read(peersProvider.notifier).clear();
    state = const BridgeState();
  }

  void _onEvent(BridgeEvent event) {
    switch (event) {
      case BridgeReady():
        if (!(_ready?.isCompleted ?? true)) _ready!.complete();
      case PeerSighting():
        ref.read(peersProvider.notifier).applySighting(event);
      case PeerGone():
        ref.read(peersProvider.notifier).removeNow(event.id);
      case UnknownBridgeEvent():
        break; // Unknown event type, skip it.
    }
  }

  void _onStreamError(Object error) {
    state = BridgeState(
      phase: BridgePhase.error,
      mockMode: state.mockMode,
      localPeerId: _localPeerId,
      error: '$error',
    );
  }

  /// Retry a failed start when the app comes back to the foreground, e.g.
  /// after the user turned Bluetooth on or granted permissions in Settings.
  void _onAppResumed() {
    if (_startRequested && state.phase == BridgePhase.error) {
      start(mock: state.mockMode);
    }
  }

  Future<void> _teardown() async {
    await _subscription?.cancel();
    _subscription = null;
    _ready = null;
    try {
      await ref.read(methodChannelProvider).stop();
    } on PlatformException {
      // Already stopped is fine. Teardown has to work from any state.
    }
  }
}
