import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  /// rebuilding the list for each one, so state updates are throttled.
  /// Bookkeeping (last-seen times) still happens every time.
  static const Duration _uiThrottle = Duration(milliseconds: 250);

  /// Fallback eviction window. Peers normally announce a goodbye (handled
  /// by [removeNow]), but one that walks out of range or crashes never
  /// gets to say it.
  static const Duration _staleAfter = Duration(seconds: 20);

  final Map<int, DateTime> _lastSeen = {};
  final Map<int, DateTime> _lastEmitted = {};

  @override
  Map<int, Peer> build() {
    final evictionTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _evictStale(),
    );
    ref.onDispose(evictionTimer.cancel);
    return const {};
  }

  void applySighting(PeerSighting sighting) {
    final now = DateTime.now();
    _lastSeen[sighting.id] = now;

    final existing = state[sighting.id];
    final lastEmitted = _lastEmitted[sighting.id];
    if (existing != null &&
        lastEmitted != null &&
        now.difference(lastEmitted) < _uiThrottle) {
      return;
    }
    _lastEmitted[sighting.id] = now;

    state = {
      ...state,
      sighting.id: Peer(
        id: sighting.id,
        status: PeerStatus.fromCode(sighting.statusCode),
        colorIndex: sighting.colorIndex,
        deviceKind: sighting.deviceKind,
        // Keep the old measurement if this sighting didn't carry one.
        rssi: sighting.rssi ?? existing?.rssi,
        distance: sighting.distance ?? existing?.distance,
        firstSeen: existing?.firstSeen ?? now,
        lastSeen: now,
      ),
    };
  }

  /// The peer said goodbye, so drop it right away instead of waiting for
  /// eviction.
  void removeNow(int peerId) {
    _lastSeen.remove(peerId);
    _lastEmitted.remove(peerId);
    if (!state.containsKey(peerId)) return;
    state = {...state}..remove(peerId);
    unawaited(ref.read(methodChannelProvider).forgetPeer(peerId));
  }

  void clear() {
    _lastSeen.clear();
    _lastEmitted.clear();
    state = const {};
  }

  void _evictStale() {
    final cutoff = DateTime.now().subtract(_staleAfter);
    final stale = _lastSeen.entries
        .where((entry) => entry.value.isBefore(cutoff))
        .map((entry) => entry.key)
        .toList();
    if (stale.isEmpty) return;

    final next = {...state};
    for (final id in stale) {
      next.remove(id);
      _lastSeen.remove(id);
      _lastEmitted.remove(id);
      // Tell the native side too so it can free the distance model.
      unawaited(ref.read(methodChannelProvider).forgetPeer(id));
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
