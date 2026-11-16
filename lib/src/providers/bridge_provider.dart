import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logging/log.dart';
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
  /// Random id per launch, which the bridge relies on: the native payload
  /// revision counter starts again in every process, so peers would take a
  /// new launch under an old id for an older one and ignore its payloads,
  /// goodbye included, for up to about a minute. To keep an id across
  /// restarts, persist the native `RevisionCounter` with it (see the README).
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

  /// The latest teardown (from stop() or a failed start()). start() waits
  /// for it so a stop that is still tearing down reaches native first.
  Future<void> _lastTeardown = Future<void>.value();

  /// How often the bridge's state is summarized in the log (`dart.stats`).
  static const Duration _statsInterval = Duration(seconds: 15);

  /// Events received from native: since the last stats line, and in total.
  final Map<String, int> _eventCounts = {};
  final Map<String, int> _eventTotals = {};

  @override
  BridgeState build() {
    _lifecycle = AppLifecycleListener(onResume: _onAppResumed);
    final statsTimer = Timer.periodic(_statsInterval, (_) => _logStats());
    ref.onDispose(() {
      _subscription?.cancel();
      _lifecycle?.dispose();
      statsTimer.cancel();
    });
    listenSelf(_logTransition);
    // Device logs are merged on this line: it says which id is this device.
    Log.i(
      'bridge',
      'identity self=${peerHex(_localPeerId)} session=$kDemoSessionId',
    );
    return const BridgeState();
  }

  Future<void> start({bool mock = false}) async {
    if (state.phase == BridgePhase.starting || state.isRunning) {
      Log.i('bridge', 'start(mock=$mock) ignored: already ${state.phase.name}');
      return;
    }
    final generation = ++_generation;
    Log.i('bridge', 'start #$generation mock=$mock');
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
    // Native runs commands in arrival order: a stop still tearing down that
    // reached native after this start would end the new session.
    try {
      await _lastTeardown;
    } on Object {
      // Whoever started that teardown gets its error.
    }
    if (generation != _generation) {
      Log.i('bridge', 'start #$generation superseded during the last teardown');
      return;
    }
    _subscription = ref
        .read(eventChannelProvider)
        .events()
        .listen(_onEvent, onError: _onStreamError);
    Log.d('bridge', 'start #$generation subscribed to native events');

    final watch = Stopwatch()..start();
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
      Log.d('bridge', 'start #$generation accepted; waiting for ready (10s)');

      await ready.future.timeout(const Duration(seconds: 10));
      Log.i(
        'bridge',
        'start #$generation ready after ${watch.elapsedMilliseconds}ms',
      );

      // Native starts with a blank payload; push our current status now.
      final pushed = ref.read(myStatusProvider);
      await ref
          .read(methodChannelProvider)
          .updateStatus(status: pushed.status.code, color: pushed.colorIndex);

      // A stop() ran while we waited, so idle was requested; stay there.
      if (generation != _generation) {
        Log.i('bridge', 'start #$generation superseded during the handshake');
        return;
      }
      // The stream reported an error after ready; don't mask it.
      if (state.phase == BridgePhase.error) {
        Log.w('bridge', 'start #$generation: stream failed after ready');
        return;
      }
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
        Log.i('bridge', 'status changed during the handshake; pushing again');
        await ref
            .read(methodChannelProvider)
            .updateStatus(status: latest.status.code, color: latest.colorIndex);
      }
    } on Exception catch (e) {
      // Superseded by a stop() (and maybe a fresh start()): this failure is
      // moot, and tearing down now would kill whatever came after.
      if (generation != _generation) {
        Log.i('bridge', 'start #$generation abandoned (superseded): $e');
        return;
      }
      Log.w(
        'bridge',
        'start #$generation failed after ${watch.elapsedMilliseconds}ms'
            '${e is TimeoutException ? ' (no ready event)' : ''}',
        e,
      );
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
    Log.i('bridge', 'stop #$generation (was ${state.phase.name})');
    _startRequested = false;
    await _teardown();
    // A start() issued while teardown was in flight owns the bridge now.
    if (generation != _generation) {
      Log.i('bridge', 'stop #$generation: a newer start took over');
      return;
    }
    ref.read(peersProvider.notifier).clear();
    state = const BridgeState();
  }

  void _onEvent(BridgeEvent event) {
    final kind = switch (event) {
      BridgeReady() => 'ready',
      PeerSighting() => 'peer',
      PeerGone() => 'gone',
      UnknownBridgeEvent() => 'unknown',
    };
    _eventCounts.update(kind, (count) => count + 1, ifAbsent: () => 1);
    _eventTotals.update(kind, (count) => count + 1, ifAbsent: () => 1);
    switch (event) {
      case BridgeReady():
        final waiting = !(_ready?.isCompleted ?? true);
        Log.i('events', 'ready${waiting ? '' : ' (no start waiting for it)'}');
        if (waiting) _ready!.complete();
      case PeerSighting():
        // Too frequent to log one by one; PeersController logs what changes
        // and native logs every sighting it emits (native.emit).
        ref.read(peersProvider.notifier).applySighting(event);
      case PeerGone():
        Log.i('events', 'gone ${peerHex(event.id)}');
        ref.read(peersProvider.notifier).removeNow(event.id);
      case UnknownBridgeEvent():
        Log.w('events', 'unknown event type "${event.type}" ignored');
    }
  }

  void _onStreamError(Object error) {
    _eventCounts.update('error', (count) => count + 1, ifAbsent: () => 1);
    _eventTotals.update('error', (count) => count + 1, ifAbsent: () => 1);
    // If the handshake is still pending, fail it now instead of letting
    // the ready wait run out its timeout; start()'s catch sets the state.
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      Log.w('events', 'stream error during the handshake', error);
      ready.completeError(error is Exception ? error : Exception('$error'));
      return;
    }
    Log.w('events', 'stream error; bridge → error', error);
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
      Log.i('bridge', 'app resumed after a failure: retrying start');
      start(mock: state.mockMode);
    }
  }

  Future<void> _teardown() => _lastTeardown = _runTeardown();

  Future<void> _runTeardown() async {
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
    Log.d('bridge', 'teardown: events cancelled; stopping native');
    try {
      await ref.read(methodChannelProvider).stop();
    } on PlatformException catch (error) {
      // Already stopped is fine. Teardown has to work from any state.
      Log.d('bridge', 'teardown: native stop failed (ignored): $error');
    }
  }

  void _logTransition(BridgeState? previous, BridgeState next) {
    if (previous == null) return;
    if (previous.phase == next.phase && previous.error == next.error) return;
    final message =
        'phase ${previous.phase.name} → ${next.phase.name}'
        '${next.phase == BridgePhase.idle ? '' : ' mock=${next.mockMode}'}'
        '${next.error == null ? '' : ' error="${next.error}"'}';
    if (next.phase == BridgePhase.error) {
      Log.w('bridge', message);
    } else {
      Log.i('bridge', message);
    }
  }

  /// One summary line every [_statsInterval] while there is anything to
  /// report. Compare its event counts with native's `native.stats` line to
  /// see whether events get lost on the way.
  void _logStats() {
    final peers = ref.read(peersProvider);
    if (state.phase == BridgePhase.idle &&
        peers.isEmpty &&
        _eventCounts.isEmpty) {
      return;
    }
    String counts(String kind) =>
        '$kind=+${_eventCounts[kind] ?? 0}/${_eventTotals[kind] ?? 0}';
    final now = DateTime.now();
    final listed = peers.values.map((peer) {
      final rssi = peer.rssi == null ? '' : ' ${peer.rssi!.round()}dBm';
      final age = now.difference(peer.lastSeen).inMilliseconds / 1000;
      return '${peerHex(peer.id)} ${peer.distanceLabel}$rssi '
          '${peer.status.name}/${peer.colorIndex} ${peer.deviceKind.name} '
          'seen ${age.toStringAsFixed(1)}s ago';
    });
    Log.i(
      'stats',
      'phase=${state.phase.name} mock=${state.mockMode} gen=$_generation '
          'events ${counts('peer')} ${counts('gone')} ${counts('ready')} '
          '${counts('error')} | peers=${peers.length}'
          '${listed.isEmpty ? '' : ': ${listed.join('; ')}'}',
    );
    _eventCounts.clear();
  }
}

/// Fails a ready wait that teardown abandoned, so its start() can return.
class _StartCancelled implements Exception {
  const _StartCancelled();
}
