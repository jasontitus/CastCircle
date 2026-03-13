import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';

// Settings providers
final jumpBackLinesProvider = StateProvider<int>(
    (ref) => AppConstants.defaultJumpBackLines);
final playbackSpeedProvider = StateProvider<double>(
    (ref) => AppConstants.defaultPlaybackSpeed);
final matchThresholdProvider = StateProvider<int>(
    (ref) => AppConstants.defaultMatchThreshold);

enum JumpBackTrigger { shake, doubleTap, swipeLeft, keyword }

final jumpBackTriggerProvider = StateProvider<JumpBackTrigger>(
    (ref) => JumpBackTrigger.doubleTap);

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jumpBackLines = ref.watch(jumpBackLinesProvider);
    final playbackSpeed = ref.watch(playbackSpeedProvider);
    final matchThreshold = ref.watch(matchThresholdProvider);
    final jumpBackTrigger = ref.watch(jumpBackTriggerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          _sectionHeader(context, 'Rehearsal'),
          ListTile(
            title: const Text('Jump-back lines'),
            subtitle: Text('Go back $jumpBackLines lines when triggered'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.remove),
                  onPressed: jumpBackLines > 1
                      ? () => ref.read(jumpBackLinesProvider.notifier).state--
                      : null,
                ),
                Text('$jumpBackLines',
                    style: Theme.of(context).textTheme.titleMedium),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: jumpBackLines < 20
                      ? () => ref.read(jumpBackLinesProvider.notifier).state++
                      : null,
                ),
              ],
            ),
          ),
          ListTile(
            title: const Text('Jump-back trigger'),
            subtitle: Text(jumpBackTrigger.name),
            trailing: DropdownButton<JumpBackTrigger>(
              value: jumpBackTrigger,
              onChanged: (v) {
                if (v != null) {
                  ref.read(jumpBackTriggerProvider.notifier).state = v;
                }
              },
              items: JumpBackTrigger.values.map((t) {
                return DropdownMenuItem(
                  value: t,
                  child: Text(t.name),
                );
              }).toList(),
            ),
          ),
          ListTile(
            title: const Text('Playback speed'),
            subtitle: Slider(
              value: playbackSpeed,
              min: 0.5,
              max: 2.0,
              divisions: 6,
              label: '${playbackSpeed}x',
              onChanged: (v) =>
                  ref.read(playbackSpeedProvider.notifier).state = v,
            ),
            trailing: Text('${playbackSpeed}x'),
          ),
          _sectionHeader(context, 'Speech Recognition'),
          ListTile(
            title: const Text('Match threshold'),
            subtitle: Slider(
              value: matchThreshold.toDouble(),
              min: 30,
              max: 100,
              divisions: 14,
              label: '$matchThreshold%',
              onChanged: (v) =>
                  ref.read(matchThresholdProvider.notifier).state =
                      v.round(),
            ),
            trailing: Text('$matchThreshold%'),
          ),
          _sectionHeader(context, 'About'),
          const ListTile(
            title: Text('LineGuide'),
            subtitle: Text('Version ${AppConstants.appVersion}'),
            leading: Icon(Icons.theater_comedy),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}
