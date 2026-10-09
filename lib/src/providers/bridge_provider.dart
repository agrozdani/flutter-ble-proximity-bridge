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
  /// start when the app comes back to the foreground.
  bool _startRequested = false;

  /// Bumped by every start() and stop(). A call that resumes from an await
  /// after a newer one took over must leave the bridge alone: its teardown
  /// or state write would clobber the newer session.
  int _generation = 0;

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
    final generation = ++_generation;
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
    // The stream can error before the await below is reached; don't let
    // that surface as an unhandled error in the gap.
    ready.future.ignore();
    await _subscription?.cancel();
    if (generation != _generation) return;
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
      final pushed = ref.read(myStatusProvider);
      await ref
          .read(methodChannelProvider)
          .updateStatus(status: pushed.status.code, color: pushed.colorIndex);

      // A stop() ran while we waited, so idle was requested; stay there.
      if (generation != _generation) return;
      // The stream reported an error after ready; don't mask it.
      if (state.phase == BridgePhase.error) return;
      state = BridgeState(
        phase: BridgePhase.running,
        mockMode: mock,
        localPeerId: _localPeerId,
      );

      // A change made while that push was in flight saw the bridge not yet
      // running, so MyStatusController didn't send it. Send it now.
      final latest = ref.read(myStatusProvider);
      if (latest.status != pushed.status ||
          latest.colorIndex != pushed.colorIndex) {
        await ref
            .read(methodChannelProvider)
            .updateStatus(status: latest.status.code, color: latest.colorIndex);
      }
    } on Exception catch (e) {
      // Superseded by a stop() (and maybe a fresh start()): this failure is
      // moot, and tearing down now would kill whatever came after.
      if (generation != _generation) return;
      await _teardown();
      if (generation != _generation) return;
      state = BridgeState(
        phase: BridgePhase.error,
        mockMode: mock,
        localPeerId: _localPeerId,
        error: e is PlatformException ? (e.message ?? e.code) : '$e',
      );
    }
  }

  Future<void> stop() async {
    final generation = ++_generation;
    _startRequested = false;
    await _teardown();
    // A start() issued while teardown was in flight owns the bridge now.
    if (generation != _generation) return;
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
    // If the handshake is still pending, fail it now instead of letting
    // the ready wait run out its timeout; start()'s catch sets the state.
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(error is Exception ? error : Exception('$error'));
      return;
    }
    state = BridgeState(
      phase: BridgePhase.error,
      mockMode: state.mockMode,
      localPeerId: _localPeerId,
      error: error is PlatformException
          ? (error.message ?? error.code)
          : '$error',
    );
  }

  /// Retry a failed start, or a bridge that died, when the app comes back to
  /// the foreground: e.g. Android stopped the service while the app was in
  /// the background, or refused to start it. Bluetooth being off is not a
  /// failure: both platforms start anyway and Herald begins scanning once
  /// Bluetooth comes on.
  void _onAppResumed() {
    if (_startRequested && state.phase == BridgePhase.error) {
      start(mock: state.mockMode);
    }
  }

  Future<void> _teardown() async {
    // Detach everything synchronously, before the first await, so a start()
    // that runs during teardown installs fresh state instead of having it
    // cleared out from under it.
    final subscription = _subscription;
    _subscription = null;
    final ready = _ready;
    _ready = null;
    // A start() still waiting for ready returns now instead of after the
    // timeout.
    if (ready != null && !ready.isCompleted) {
      ready.completeError(const _StartCancelled());
    }
    await subscription?.cancel();
    try {
      await ref.read(methodChannelProvider).stop();
    } on PlatformException {
      // Already stopped is fine. Teardown has to work from any state.
    }
  }
}

/// Fails a ready wait that teardown abandoned, so its start() can return.
class _StartCancelled implements Exception {
  const _StartCancelled();
}
