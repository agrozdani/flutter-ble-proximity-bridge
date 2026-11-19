import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logging/log.dart';
import '../models/bridge_event.dart';
import '../models/peer.dart';
import 'channel_providers.dart';

final peersProvider = NotifierProvider<PeersController, Map<int, Peer>>(
  PeersController.new,
);

/// Turns the raw sighting stream into one [Peer] per id. Throttles UI
/// updates and evicts peers that go quiet.
class PeersController extends Notifier<Map<int, Peer>> {
  /// BLE can report several sightings per second per peer. No point
  /// rebuilding the list for each one, so measurement-only updates are
  /// throttled to one per peer per window. A sighting that changes what the
  /// peer broadcasts always gets through, and bookkeeping (last-seen times)
  /// happens every time.
  ///
  /// The newest sighting the throttle holds back is shown when the window
  /// ends, unless a newer one was shown first, so the last sighting of a
  /// burst always reaches the list. An Android receiver hears a peer in
  /// bursts about a minute apart (docs/android.md); before, the list kept an
  /// earlier reading of the burst until the next one (on a Pixel Tablet,
  /// 2026-11-16: -51 dBm shown for a minute, the burst had ended at -61).
  static const Duration _uiThrottle = Duration(milliseconds: 250);

  /// Fallback eviction window: how long a peer may go unheard before it is
  /// dropped. Peers normally announce a goodbye (handled by [removeNow]),
  /// but one that walks out of range or crashes never gets to say it, and
  /// an Android receiver never gets goodbyes at all (docs/android.md).
  late final Duration _staleAfter = staleAfterFor(defaultTargetPlatform);

  /// The eviction window on [platform]: how long this device can go without
  /// hearing a peer that is still there.
  ///
  /// - iOS: Herald scans all the time, so a nearby peer is heard every
  ///   second or two, and 20 s of silence means it has gone.
  /// - Android: Herald for Android (2.2.0) listens in bursts. It scans for
  ///   4 s, then stops scanning while it connects, one device at a time, to
  ///   each nearby device it has not identified yet (any Apple device its
  ///   filter lets through), for up to 60 s; a connect can take 8 s to
  ///   time out, and a device that timed out is tried again next time. With
  ///   a few Apple devices around that don't run the app, every cycle takes
  ///   the whole minute, and a peer right next to this device goes unheard
  ///   for about 60 s at a time. 90 s covers one such cycle with margin.
  ///   See docs/android.md.
  @visibleForTesting
  static Duration staleAfterFor(TargetPlatform platform) =>
      platform == TargetPlatform.android
      ? const Duration(seconds: 90)
      : const Duration(seconds: 20);

  final Map<int, DateTime> _lastSeen = {};
  final Map<int, DateTime> _lastEmitted = {};

  /// Per peer: the newest sighting the throttle held back, with when it was
  /// heard, and the timer that shows it when the window ends.
  final Map<int, (PeerSighting, DateTime)> _heldBack = {};
  final Map<int, Timer> _heldBackTimers = {};

  @override
  Map<int, Peer> build() {
    final evictionTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => evictStale(DateTime.now()),
    );
    ref.onDispose(() {
      evictionTimer.cancel();
      _dropAllHeldBack();
    });
    return const {};
  }

  void applySighting(PeerSighting sighting) {
    final now = DateTime.now();
    _lastSeen[sighting.id] = now;

    final existing = state[sighting.id];
    final status = PeerStatus.fromCode(sighting.statusCode);
    final lastEmitted = _lastEmitted[sighting.id];
    final broadcastChanged =
        existing == null ||
        existing.status != status ||
        existing.colorIndex != sighting.colorIndex ||
        existing.deviceKind != sighting.deviceKind;
    // A sighting without a measurement (a payload read, a relay, a frame)
    // must not make the list forget the reading the throttle is holding.
    final measured = _withHeldMeasurement(sighting);
    if (!broadcastChanged && lastEmitted != null) {
      final sinceShown = now.difference(lastEmitted);
      if (sinceShown < _uiThrottle) {
        _heldBack[sighting.id] = (measured, now);
        _heldBackTimers[sighting.id] ??= Timer(
          // At most one window, even if the wall clock was set back.
          sinceShown.isNegative ? _uiThrottle : _uiThrottle - sinceShown,
          () => _showHeldBack(sighting.id),
        );
        return;
      }
    }
    _show(measured, now);
  }

  /// [sighting], with the RSSI and distance of the sighting held back for
  /// its peer when it has none of its own: that reading is newer than what
  /// the list shows.
  PeerSighting _withHeldMeasurement(PeerSighting sighting) {
    final held = _heldBack[sighting.id]?.$1;
    if (sighting.rssi != null || held == null || held.rssi == null) {
      return sighting;
    }
    return PeerSighting(
      id: sighting.id,
      statusCode: sighting.statusCode,
      colorIndex: sighting.colorIndex,
      deviceKind: sighting.deviceKind,
      rssi: held.rssi,
      distance: held.distance,
    );
  }

  /// How many peers have a sighting held back by the throttle.
  @visibleForTesting
  int get heldBackCount => _heldBackTimers.length;

  /// Puts [sighting], heard at [heardAt], in the list.
  void _show(PeerSighting sighting, DateTime heardAt) {
    // Whatever the throttle held back for this peer is older.
    _dropHeldBack(sighting.id);
    _lastEmitted[sighting.id] = DateTime.now();

    final existing = state[sighting.id];
    final peer = Peer(
      id: sighting.id,
      status: PeerStatus.fromCode(sighting.statusCode),
      colorIndex: sighting.colorIndex,
      deviceKind: sighting.deviceKind,
      // Keep the old measurement if this sighting didn't carry one.
      rssi: sighting.rssi ?? existing?.rssi,
      distance: sighting.distance ?? existing?.distance,
      firstSeen: existing?.firstSeen ?? heardAt,
      lastSeen: heardAt,
    );
    _logChange(existing, peer);
    state = {...state, sighting.id: peer};
  }

  /// The throttle window of [peerId] has ended: show what it held back,
  /// unless the peer was removed meanwhile.
  void _showHeldBack(int peerId) {
    _heldBackTimers.remove(peerId);
    final held = _heldBack.remove(peerId);
    if (held == null || !state.containsKey(peerId)) return;
    final (sighting, heardAt) = held;
    _show(sighting, heardAt);
  }

  void _dropHeldBack(int peerId) {
    _heldBack.remove(peerId);
    _heldBackTimers.remove(peerId)?.cancel();
  }

  void _dropAllHeldBack() {
    for (final timer in _heldBackTimers.values) {
      timer.cancel();
    }
    _heldBackTimers.clear();
    _heldBack.clear();
  }

  /// The peer said goodbye, or ([replaced]) its device now broadcasts another
  /// id, so drop it right away instead of waiting for eviction.
  void removeNow(int peerId, {bool replaced = false}) {
    _lastSeen.remove(peerId);
    _lastEmitted.remove(peerId);
    _dropHeldBack(peerId);
    final why = replaced ? 'its device has a new id' : 'goodbye';
    final peer = state[peerId];
    if (peer == null) {
      Log.d('peers', '${peerHex(peerId)} gone ($why), and not listed');
      return;
    }
    Log.i(
      'peers',
      '- ${peerHex(peerId)} removed: $why (listed for '
          '${_seconds(DateTime.now().difference(peer.firstSeen))})',
    );
    state = {...state}..remove(peerId);
    _forget(peerId);
  }

  void clear() {
    if (state.isNotEmpty) Log.i('peers', 'cleared ${state.length} peer(s)');
    _lastSeen.clear();
    _lastEmitted.clear();
    _dropAllHeldBack();
    state = const {};
  }

  /// One line per change a user would see: a new peer, a new status, color
  /// or device kind, or a new distance bucket. Plain RSSI updates are not
  /// logged here (native.emit has every sample).
  void _logChange(Peer? before, Peer after) {
    final id = peerHex(after.id);
    if (before == null) {
      final rssi = after.rssi == null ? '' : ' ${after.rssi!.round()}dBm';
      Log.i(
        'peers',
        '+ $id appeared: ${after.status.name} color=${after.colorIndex} '
            '${after.deviceKind.name} ${after.distanceLabel}$rssi',
      );
      return;
    }
    final changes = [
      if (before.status != after.status)
        'status ${before.status.name}→${after.status.name}',
      if (before.colorIndex != after.colorIndex)
        'color ${before.colorIndex}→${after.colorIndex}',
      if (before.deviceKind != after.deviceKind)
        'device ${before.deviceKind.name}→${after.deviceKind.name}',
      if (before.distanceLabel != after.distanceLabel)
        'distance ${before.distanceLabel}→${after.distanceLabel}'
            '${after.rssi == null ? '' : ' (${after.rssi!.round()}dBm)'}',
    ];
    if (changes.isNotEmpty) Log.i('peers', '~ $id ${changes.join(', ')}');
  }

  void _forget(int peerId) {
    unawaited(
      ref.read(methodChannelProvider).forgetPeer(peerId).catchError((
        Object error,
      ) {
        Log.w('peers', 'forgetPeer ${peerHex(peerId)} failed', error);
      }),
    );
  }

  static String _seconds(Duration duration) =>
      '${(duration.inMilliseconds / 1000).toStringAsFixed(1)}s';

  /// Drops every peer not heard for longer than the eviction window. Runs
  /// every 5 s; [now] is a parameter so tests can move time on.
  @visibleForTesting
  void evictStale(DateTime now) {
    final cutoff = now.subtract(_staleAfter);
    final stale = _lastSeen.entries
        .where((entry) => entry.value.isBefore(cutoff))
        .map((entry) => entry.key)
        .toList();
    if (stale.isEmpty) return;

    final next = {...state};
    for (final id in stale) {
      Log.i(
        'peers',
        '- ${peerHex(id)} evicted: silent for '
            '${_seconds(now.difference(_lastSeen[id]!))} '
            '(limit ${_staleAfter.inSeconds}s)',
      );
      next.remove(id);
      _lastSeen.remove(id);
      _lastEmitted.remove(id);
      _dropHeldBack(id);
      // Tell the native side too so it can free the distance model.
      _forget(id);
    }
    state = next;
  }
}

/// Peers sorted nearest first.
final sortedPeersProvider = Provider<List<Peer>>((ref) {
  final peers = ref.watch(peersProvider).values.toList();
  peers.sort((a, b) {
    final byDistance = (a.distance ?? double.infinity).compareTo(
      b.distance ?? double.infinity,
    );
    return byDistance != 0 ? byDistance : a.id.compareTo(b.id);
  });
  return peers;
});
