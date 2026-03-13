import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/script_models.dart';
import '../../providers/production_providers.dart';

const _uuid = Uuid();

/// Screen for editing scene boundaries, names, and locations.
///
/// Scenes are the primary unit actors use to organize rehearsal.
/// The organizer needs to:
/// 1. Review auto-detected scenes
/// 2. Split scenes that are too long
/// 3. Merge scenes that are too short
/// 4. Rename scenes and locations for clarity
/// 5. Add new scene breaks as the production evolves
class SceneEditorScreen extends ConsumerStatefulWidget {
  const SceneEditorScreen({super.key});

  @override
  ConsumerState<SceneEditorScreen> createState() => _SceneEditorScreenState();
}

class _SceneEditorScreenState extends ConsumerState<SceneEditorScreen> {
  @override
  Widget build(BuildContext context) {
    final script = ref.watch(currentScriptProvider);

    if (script == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Edit Scenes')),
        body: const Center(child: Text('No script loaded')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Scenes (${script.scenes.length})'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add scene break',
            onPressed: () => _showAddSceneBreak(context, script),
          ),
        ],
      ),
      body: ReorderableListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: script.scenes.length,
        onReorder: (oldIndex, newIndex) {
          // Reorder not implemented for scenes (order is derived from lines)
        },
        itemBuilder: (context, index) {
          final scene = script.scenes[index];
          final sceneLines = script.linesInScene(scene);
          final dialogueCount =
              sceneLines.where((l) => l.lineType == LineType.dialogue).length;

          return Card(
            key: ValueKey(scene.id),
            margin: const EdgeInsets.only(bottom: 12),
            child: ExpansionTile(
              leading: CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              title: Text(
                scene.sceneName,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (scene.location.isNotEmpty)
                    Text(scene.location,
                        style: TextStyle(color: Colors.grey[500])),
                  Text(
                    '$dialogueCount lines \u2022 ${scene.characters.length} characters',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              children: [
                // Character chips
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: scene.characters.map((name) {
                      final charIdx = script.characters
                          .indexWhere((c) => c.name == name);
                      final color = charIdx >= 0
                          ? AppTheme.colorForCharacter(charIdx)
                          : Colors.grey;
                      return Chip(
                        label: Text(name, style: TextStyle(color: color, fontSize: 12)),
                        visualDensity: VisualDensity.compact,
                      );
                    }).toList(),
                  ),
                ),
                if (scene.description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 4),
                    child: Text(
                      scene.description,
                      style: TextStyle(
                        fontStyle: FontStyle.italic,
                        color: Colors.grey[500],
                        fontSize: 12,
                      ),
                    ),
                  ),
                // Action buttons
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.edit, size: 16),
                        label: const Text('Rename'),
                        onPressed: () =>
                            _renameScene(context, script, index),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.call_split, size: 16),
                        label: const Text('Split'),
                        onPressed: dialogueCount > 2
                            ? () =>
                                _splitScene(context, script, index)
                            : null,
                      ),
                      if (index < script.scenes.length - 1)
                        TextButton.icon(
                          icon: const Icon(Icons.merge, size: 16),
                          label: const Text('Merge Next'),
                          onPressed: () =>
                              _mergeScenes(context, script, index),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _renameScene(
      BuildContext context, ParsedScript script, int sceneIndex) {
    final scene = script.scenes[sceneIndex];
    final nameController = TextEditingController(text: scene.sceneName);
    final locationController = TextEditingController(text: scene.location);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Scene'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Scene name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: locationController,
              decoration: const InputDecoration(
                labelText: 'Location',
                border: OutlineInputBorder(),
                hintText: 'e.g., Longbourn, Netherfield Ball',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final updated = scene.copyWith(
                sceneName: nameController.text.trim(),
                location: locationController.text.trim(),
              );
              _updateScene(script, sceneIndex, updated);
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _splitScene(
      BuildContext context, ParsedScript script, int sceneIndex) {
    final scene = script.scenes[sceneIndex];
    final sceneLines = script.linesInScene(scene);
    final dialogueLines =
        sceneLines.where((l) => l.lineType == LineType.dialogue).toList();

    // Default split at the midpoint
    var splitAt = dialogueLines.length ~/ 2;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Split Scene'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Split "${scene.sceneName}" into two scenes.'),
              const SizedBox(height: 16),
              Text('Split after line $splitAt of ${dialogueLines.length}'),
              Slider(
                value: splitAt.toDouble(),
                min: 1,
                max: (dialogueLines.length - 1).toDouble(),
                divisions: dialogueLines.length - 2,
                label: 'After line $splitAt',
                onChanged: (v) =>
                    setDialogState(() => splitAt = v.round()),
              ),
              const SizedBox(height: 8),
              // Show the split point
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'End of Scene A:',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      Text(
                        '${dialogueLines[splitAt - 1].character}: ${_truncate(dialogueLines[splitAt - 1].text, 50)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      const Divider(),
                      Text(
                        'Start of Scene B:',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      Text(
                        '${dialogueLines[splitAt].character}: ${_truncate(dialogueLines[splitAt].text, 50)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                _performSplit(script, sceneIndex, dialogueLines[splitAt].orderIndex);
                Navigator.pop(context);
              },
              child: const Text('Split'),
            ),
          ],
        ),
      ),
    );
  }

  void _mergeScenes(
      BuildContext context, ParsedScript script, int sceneIndex) {
    final scene = script.scenes[sceneIndex];
    final nextScene = script.scenes[sceneIndex + 1];

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Merge Scenes'),
        content: Text(
          'Merge "${scene.sceneName}" and "${nextScene.sceneName}" into one scene?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              _performMerge(script, sceneIndex);
              Navigator.pop(context);
            },
            child: const Text('Merge'),
          ),
        ],
      ),
    );
  }

  void _showAddSceneBreak(BuildContext context, ParsedScript script) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Scene Break'),
        content: const Text(
          'To add a new scene break, open the Script Editor and tap on the '
          'line where you want the new scene to start. Then use the '
          '"Split Scene" action on the scene containing that line.\n\n'
          'Tip: Scene breaks are automatically detected from stage directions '
          'like "Shift begins..." You can also add these manually.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _updateScene(
      ParsedScript script, int index, ScriptScene updated) {
    final scenes = List<ScriptScene>.from(script.scenes);
    scenes[index] = updated;

    // Update scene tags on the lines too
    final updatedLines = script.lines.map((l) {
      if (l.orderIndex >= updated.startLineIndex &&
          l.orderIndex <= updated.endLineIndex) {
        return l.copyWith(scene: updated.location);
      }
      return l;
    }).toList();

    ref.read(currentScriptProvider.notifier).state = ParsedScript(
      title: script.title,
      lines: updatedLines,
      characters: script.characters,
      scenes: scenes,
      rawText: script.rawText,
    );
  }

  void _performSplit(
      ParsedScript script, int sceneIndex, int splitAtOrderIndex) {
    final scene = script.scenes[sceneIndex];
    final scenes = List<ScriptScene>.from(script.scenes);

    // Find the line index in the full lines list
    final splitLineIdx = script.lines
        .indexWhere((l) => l.orderIndex == splitAtOrderIndex);
    if (splitLineIdx < 0) return;

    // Get characters for each half
    final firstHalfLines =
        script.lines.sublist(scene.startLineIndex, splitLineIdx);
    final secondHalfLines =
        script.lines.sublist(splitLineIdx, scene.endLineIndex + 1);

    final firstChars = <String>{};
    for (final l in firstHalfLines) {
      if (l.lineType == LineType.dialogue && l.character.isNotEmpty) {
        firstChars.add(l.character);
      }
    }

    final secondChars = <String>{};
    for (final l in secondHalfLines) {
      if (l.lineType == LineType.dialogue && l.character.isNotEmpty) {
        secondChars.add(l.character);
      }
    }

    // Replace the original with two scenes
    scenes.removeAt(sceneIndex);
    scenes.insert(
      sceneIndex,
      ScriptScene(
        id: _uuid.v4(),
        act: scene.act,
        sceneName: '${scene.sceneName} (Part 1)',
        location: scene.location,
        description: scene.description,
        startLineIndex: scene.startLineIndex,
        endLineIndex: splitLineIdx - 1,
        characters: firstChars.toList()..sort(),
      ),
    );
    scenes.insert(
      sceneIndex + 1,
      ScriptScene(
        id: _uuid.v4(),
        act: scene.act,
        sceneName: '${scene.sceneName} (Part 2)',
        location: scene.location,
        description: '',
        startLineIndex: splitLineIdx,
        endLineIndex: scene.endLineIndex,
        characters: secondChars.toList()..sort(),
      ),
    );

    ref.read(currentScriptProvider.notifier).state = ParsedScript(
      title: script.title,
      lines: script.lines,
      characters: script.characters,
      scenes: scenes,
      rawText: script.rawText,
    );
  }

  void _performMerge(ParsedScript script, int sceneIndex) {
    final scene = script.scenes[sceneIndex];
    final nextScene = script.scenes[sceneIndex + 1];
    final scenes = List<ScriptScene>.from(script.scenes);

    // Merge characters
    final allChars = {...scene.characters, ...nextScene.characters};

    final merged = ScriptScene(
      id: _uuid.v4(),
      act: scene.act,
      sceneName: scene.sceneName,
      location: scene.location,
      description: scene.description,
      startLineIndex: scene.startLineIndex,
      endLineIndex: nextScene.endLineIndex,
      characters: allChars.toList()..sort(),
    );

    scenes.removeAt(sceneIndex + 1);
    scenes[sceneIndex] = merged;

    ref.read(currentScriptProvider.notifier).state = ParsedScript(
      title: script.title,
      lines: script.lines,
      characters: script.characters,
      scenes: scenes,
      rawText: script.rawText,
    );
  }

  String _truncate(String text, int maxLen) {
    if (text.length <= maxLen) return text;
    return '${text.substring(0, maxLen - 3)}...';
  }
}
