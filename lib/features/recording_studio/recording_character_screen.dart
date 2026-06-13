import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../providers/production_providers.dart';

class RecordingCharacterScreen extends ConsumerWidget {
  const RecordingCharacterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final script = ref.watch(currentScriptProvider);

    if (script == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Recording Studio')),
        body: const Center(child: Text('No script loaded')),
      );
    }

    final recordings = ref.watch(recordingsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Record Lines'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.library_music_outlined),
            tooltip: 'Browse Recordings',
            onPressed: () => context.push('/recordings'),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Choose a character to record:',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: script.characters.length,
              itemBuilder: (context, index) {
                final char = script.characters[index];
                final color = AppTheme.colorForCharacter(char.colorIndex);
                final charLines = script.linesForCharacter(char.name);
                final recordedCount = charLines
                    .where((l) => recordings.containsKey(l.id))
                    .length;
                final progress = charLines.isEmpty
                    ? 0.0
                    : recordedCount / charLines.length;

                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: color,
                      child: Text(
                        char.name[0],
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(char.name),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${char.lineCount} lines'),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(
                          value: progress,
                          backgroundColor:
                              color.withValues(alpha: 0.1),
                          color: color,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$recordedCount / ${charLines.length} recorded',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                    trailing: const Icon(Icons.mic),
                    onTap: () {
                      ref.read(recordingCharacterProvider.notifier).state =
                          char.name;
                      context.push('/recording-studio');
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
