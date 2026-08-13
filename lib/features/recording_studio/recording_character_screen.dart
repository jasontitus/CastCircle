import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/responsive.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/script_models.dart';
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
      body: _CharacterList(script: script, recordings: recordings),
    );
  }
}

/// Body with the per-character line index computed ONCE per build:
/// linesForCharacter scans the whole script, and calling it inside
/// itemBuilder made every newly-visible row an O(script) scan
/// (characters × lines predicate calls per full list build).
class _CharacterList extends ConsumerWidget {
  const _CharacterList({required this.script, required this.recordings});

  final ParsedScript script;
  final Map<String, Recording> recordings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final linesByChar = <String, List<ScriptLine>>{
      for (final c in script.characters) c.name: [],
    };
    for (final l in script.lines) {
      if (l.lineType != LineType.dialogue) continue;
      if (l.multiCharacters.isNotEmpty) {
        for (final name in l.multiCharacters) {
          linesByChar[name]?.add(l);
        }
      } else {
        linesByChar[l.character]?.add(l);
      }
    }
    return Column(
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
            child: ContentConstraint(
              maxWidth: 700,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: script.characters.length,
                itemBuilder: (context, index) {
                  final char = script.characters[index];
                  final color = AppTheme.colorForCharacter(char.colorIndex);
                  final charLines = linesByChar[char.name] ?? const [];
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
                            backgroundColor: color.withValues(alpha: 0.1),
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
          ),
        ],
    );
  }
}
