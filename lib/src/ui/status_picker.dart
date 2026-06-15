import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/peer.dart';
import '../providers/my_status_provider.dart';
import 'palette.dart';

/// Picker for the status and color we broadcast. Changes go out right away
/// while the bridge is running.
class StatusPicker extends ConsumerWidget {
  const StatusPicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final myStatus = ref.watch(myStatusProvider);
    final controller = ref.read(myStatusProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final status in PeerStatus.values)
              if (status != PeerStatus.unknown)
                ChoiceChip(
                  label: Text('${status.emoji} ${status.label}'),
                  selected: myStatus.status == status,
                  onSelected: (_) => controller.setStatus(status),
                ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            for (var i = 0; i < kPeerColors.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: GestureDetector(
                  onTap: () => controller.setColor(i),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: kPeerColors[i],
                      shape: BoxShape.circle,
                      border: myStatus.colorIndex == i
                          ? Border.all(
                              width: 3,
                              color: Theme.of(context).colorScheme.onSurface,
                            )
                          : null,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
