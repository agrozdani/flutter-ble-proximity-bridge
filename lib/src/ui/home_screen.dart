import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../providers/bridge_provider.dart';
import '../providers/peers_provider.dart';
import 'peer_tile.dart';
import 'permissions.dart';
import 'status_picker.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  // Mock by default in debug so the app just works on simulators.
  bool _mockMode = kDebugMode;

  Future<void> _start() async {
    if (!_mockMode) {
      final granted = await ensureProximityPermissions();
      if (!granted) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Bluetooth permissions are required'),
            action: SnackBarAction(
              label: 'Settings',
              onPressed: openAppSettings,
            ),
          ),
        );
        return;
      }
    }
    await ref.read(bridgeProvider.notifier).start(mock: _mockMode);
  }

  @override
  Widget build(BuildContext context) {
    final bridge = ref.watch(bridgeProvider);
    final peers = ref.watch(sortedPeersProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('BLE Proximity Bridge'),
        actions: [_PhaseChip(phase: bridge.phase)],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Your broadcast', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  const StatusPicker(),
                  if (bridge.isRunning && bridge.localPeerId != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Broadcasting as Peer '
                      '${bridge.localPeerId!.toRadixString(16).toUpperCase().padLeft(8, '0')}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ),
          Card(
            margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Mock peers'),
                  subtitle: const Text(
                    'Synthetic sightings — works on simulators, no '
                    'Bluetooth or permissions needed',
                  ),
                  value: _mockMode,
                  // No switching transports while running; stop first.
                  onChanged:
                      bridge.phase == BridgePhase.idle ||
                          bridge.phase == BridgePhase.error
                      ? (value) => setState(() => _mockMode = value)
                      : null,
                ),
                if (bridge.error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      bridge.error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: switch (bridge.phase) {
                    BridgePhase.idle || BridgePhase.error => FilledButton.icon(
                      onPressed: _start,
                      icon: const Icon(Icons.radar),
                      label: const Text('Start'),
                    ),
                    BridgePhase.starting => const FilledButton(
                      onPressed: null,
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                    BridgePhase.running => FilledButton.tonalIcon(
                      onPressed: () => ref.read(bridgeProvider.notifier).stop(),
                      icon: const Icon(Icons.stop),
                      label: const Text('Stop'),
                    ),
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Text(
              'Nearby peers (${peers.length})',
              style: theme.textTheme.titleMedium,
            ),
          ),
          Expanded(
            child: peers.isEmpty
                ? Center(
                    child: Text(
                      bridge.isRunning
                          ? 'Listening for peers…'
                          : 'Start the bridge to discover peers',
                      style: theme.textTheme.bodyMedium!.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: peers.length,
                    itemBuilder: (context, index) =>
                        PeerTile(peer: peers[index]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _PhaseChip extends StatelessWidget {
  const _PhaseChip({required this.phase});

  final BridgePhase phase;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = switch (phase) {
      BridgePhase.idle => ('idle', scheme.outline),
      BridgePhase.starting => ('starting', scheme.tertiary),
      BridgePhase.running => ('running', scheme.primary),
      BridgePhase.error => ('error', scheme.error),
    };
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Row(
        children: [
          Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 6),
          Text(label),
        ],
      ),
    );
  }
}
