import 'package:flutter/material.dart';

import '../models/peer.dart';
import 'palette.dart';

/// One row in the nearby-peers list.
class PeerTile extends StatelessWidget {
  const PeerTile({super.key, required this.peer});

  final Peer peer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rssi = peer.rssi;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: peerColor(peer.colorIndex),
        child: Text(peer.status.emoji, style: const TextStyle(fontSize: 18)),
      ),
      title: Text('Peer ${peer.shortId}'),
      subtitle: Text(
        [
          peer.status.label,
          if (rssi != null) '${rssi.toStringAsFixed(0)} dBm',
        ].join(' · '),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                switch (peer.deviceKind) {
                  DeviceKind.ios => Icons.phone_iphone,
                  DeviceKind.android => Icons.android,
                  DeviceKind.unknown => Icons.device_unknown,
                },
                size: 16,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(width: 4),
              Text(peer.distanceLabel, style: theme.textTheme.labelLarge),
            ],
          ),
          if (peer.distance != null)
            Text(
              '~${peer.distance!.toStringAsFixed(1)} m',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}
