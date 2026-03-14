import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/script_models.dart';
import '../../data/services/voice_config_service.dart';
import '../../providers/production_providers.dart';

class CharacterManagerScreen extends ConsumerStatefulWidget {
  const CharacterManagerScreen({super.key});

  @override
  ConsumerState<CharacterManagerScreen> createState() =>
      _CharacterManagerScreenState();
}

class _CharacterManagerScreenState
    extends ConsumerState<CharacterManagerScreen> {
  @override
  Widget build(BuildContext context) {
    final script = ref.watch(currentScriptProvider);

    if (script == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Characters')),
        body: const Center(child: Text('No script loaded')),
      );
    }

    // Detect potential issues
    final singleLineChars =
        script.characters.where((c) => c.lineCount == 1).toList();
    final hasIssues = singleLineChars.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text('Characters (${script.characters.length})'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: Column(
        children: [
          // Warnings
          if (hasIssues)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber, color: Colors.orange, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${singleLineChars.length} character(s) with only 1 line '
                      '— likely OCR errors. Tap to merge or delete.',
                      style: const TextStyle(fontSize: 13, color: Colors.orange),
                    ),
                  ),
                ],
              ),
            ),
          // Character list
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: script.characters.length,
              itemBuilder: (context, index) {
                final char = script.characters[index];
                final color = AppTheme.colorForCharacter(char.colorIndex);
                final isSuspect = char.lineCount <= 1;

                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  color: isSuspect
                      ? Colors.orange.withValues(alpha: 0.05)
                      : null,
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: color,
                      child: Text(
                        char.name[0],
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                    title: Text(char.name),
                    subtitle: Text(
                      '${char.lineCount} lines · ${_genderLabel(char.gender)}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Gender toggle
                        IconButton(
                          icon: Icon(
                            _genderIcon(char.gender),
                            color: _genderColor(char.gender),
                            size: 22,
                          ),
                          tooltip: 'Change gender',
                          onPressed: () => _toggleGender(ref, char, script),
                        ),
                        PopupMenuButton<String>(
                          onSelected: (action) =>
                              _handleAction(context, ref, action, char, script),
                          itemBuilder: (context) => [
                            const PopupMenuItem(
                              value: 'rename',
                              child: ListTile(
                                leading: Icon(Icons.edit),
                                title: Text('Rename'),
                                dense: true,
                              ),
                            ),
                            PopupMenuItem(
                              value: 'merge',
                              child: ListTile(
                                leading: const Icon(Icons.merge_type),
                                title: Text(
                                    'Merge into another'),
                                dense: true,
                              ),
                            ),
                            if (char.lineCount <= 1)
                              const PopupMenuItem(
                                value: 'delete',
                                child: ListTile(
                                  leading:
                                      Icon(Icons.delete_outline, color: Colors.red),
                                  title: Text('Delete',
                                      style: TextStyle(color: Colors.red)),
                                  dense: true,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                    onTap: () => _showCharacterDetail(context, ref, char, script),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static String _genderLabel(CharacterGender gender) => switch (gender) {
        CharacterGender.female => 'Female',
        CharacterGender.male => 'Male',
        CharacterGender.nonGendered => 'Non-gendered',
      };

  static IconData _genderIcon(CharacterGender gender) => switch (gender) {
        CharacterGender.female => Icons.female,
        CharacterGender.male => Icons.male,
        CharacterGender.nonGendered => Icons.transgender,
      };

  static Color _genderColor(CharacterGender gender) => switch (gender) {
        CharacterGender.female => Colors.pink,
        CharacterGender.male => Colors.blue,
        CharacterGender.nonGendered => Colors.purple,
      };

  void _toggleGender(WidgetRef ref, ScriptCharacter char, ParsedScript script) {
    final newGender = switch (char.gender) {
      CharacterGender.female => CharacterGender.male,
      CharacterGender.male => CharacterGender.nonGendered,
      CharacterGender.nonGendered => CharacterGender.female,
    };

    // Persist gender
    final production = ref.read(currentProductionProvider);
    if (production != null) {
      VoiceConfigService.instance
          .setGender(production.id, char.name, newGender);
    }

    // Update in-memory script
    final updatedCharacters = script.characters.map((c) {
      if (c.name == char.name) return c.copyWith(gender: newGender);
      return c;
    }).toList();

    ref.read(currentScriptProvider.notifier).state = ParsedScript(
      title: script.title,
      lines: script.lines,
      characters: updatedCharacters,
      scenes: script.scenes,
      rawText: script.rawText,
    );
  }

  void _handleAction(BuildContext context, WidgetRef ref, String action,
      ScriptCharacter char, ParsedScript script) {
    switch (action) {
      case 'rename':
        _renameCharacter(context, ref, char, script);
      case 'merge':
        _mergeCharacter(context, ref, char, script);
      case 'delete':
        _deleteCharacter(context, ref, char, script);
    }
  }

  void _renameCharacter(BuildContext context, WidgetRef ref,
      ScriptCharacter char, ParsedScript script) {
    final controller = TextEditingController(text: char.name);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Character'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'New name',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final newName = controller.text.trim();
              if (newName.isEmpty || newName == char.name) {
                Navigator.pop(context);
                return;
              }
              _applyRename(ref, script, char.name, newName);
              Navigator.pop(context);
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }

  void _mergeCharacter(BuildContext context, WidgetRef ref,
      ScriptCharacter char, ParsedScript script) {
    final targets = script.characters
        .where((c) => c.name != char.name)
        .toList();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Merge "${char.name}" into:'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: targets.length,
            itemBuilder: (context, index) {
              final target = targets[index];
              final color = AppTheme.colorForCharacter(target.colorIndex);
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: color,
                  radius: 14,
                  child: Text(target.name[0],
                      style: const TextStyle(color: Colors.white, fontSize: 12)),
                ),
                title: Text(target.name),
                subtitle: Text('${target.lineCount} lines'),
                onTap: () {
                  _applyRename(ref, script, char.name, target.name);
                  Navigator.pop(context);
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  void _deleteCharacter(BuildContext context, WidgetRef ref,
      ScriptCharacter char, ParsedScript script) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${char.name}"?'),
        content: Text(
            'This will remove ${char.lineCount} line(s) attributed to ${char.name}. '
            'This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              _applyDelete(ref, script, char.name);
              Navigator.pop(context);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _showCharacterDetail(BuildContext context, WidgetRef ref,
      ScriptCharacter char, ParsedScript script) {
    final lines = script.linesForCharacter(char.name);
    final scenes = script.scenesForCharacter(char.name);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor:
                        AppTheme.colorForCharacter(char.colorIndex),
                    child: Text(char.name[0],
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(char.name,
                            style: Theme.of(context).textTheme.titleMedium),
                        Text(
                            '${char.lineCount} lines in ${scenes.length} scenes',
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                padding: const EdgeInsets.all(16),
                itemCount: lines.length,
                itemBuilder: (context, index) {
                  final line = lines[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 32,
                          child: Text(
                            '${line.orderIndex}',
                            style: TextStyle(
                                color: Colors.grey[600], fontSize: 11),
                          ),
                        ),
                        Expanded(
                          child: Text(line.text, style: const TextStyle(fontSize: 14)),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Mutations ─────────────────────────────────────────

  void _applyRename(
      WidgetRef ref, ParsedScript script, String oldName, String newName) {
    final updatedLines = script.lines.map((l) {
      if (l.character == oldName) {
        return l.copyWith(character: newName);
      }
      return l;
    }).toList();

    _rebuildScript(ref, script, updatedLines);
  }

  void _applyDelete(WidgetRef ref, ParsedScript script, String charName) {
    final updatedLines = script.lines
        .where((l) =>
            !(l.lineType == LineType.dialogue && l.character == charName))
        .toList();

    _rebuildScript(ref, script, updatedLines);
  }

  void _rebuildScript(
      WidgetRef ref, ParsedScript script, List<ScriptLine> updatedLines) {
    // Recalculate characters, preserving genders from existing script
    final existingGenders = {
      for (final c in script.characters) c.name: c.gender,
    };
    final charCounts = <String, int>{};
    for (final line in updatedLines) {
      if (line.lineType == LineType.dialogue && line.character.isNotEmpty) {
        charCounts[line.character] = (charCounts[line.character] ?? 0) + 1;
      }
    }
    var colorIdx = 0;
    final characters = charCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final charList = characters
        .map((e) => ScriptCharacter(
              name: e.key,
              colorIndex: colorIdx++,
              lineCount: e.value,
              gender: existingGenders[e.key] ?? CharacterGender.female,
            ))
        .toList();

    // Recalculate scenes with updated characters
    final updatedScenes = script.scenes.map((scene) {
      final sceneChars = <String>{};
      for (final line in updatedLines) {
        if (line.orderIndex >= scene.startLineIndex &&
            line.orderIndex <= scene.endLineIndex &&
            line.lineType == LineType.dialogue &&
            line.character.isNotEmpty) {
          sceneChars.add(line.character);
        }
      }
      return scene.copyWith(characters: sceneChars.toList());
    }).toList();

    ref.read(currentScriptProvider.notifier).state = ParsedScript(
      title: script.title,
      lines: updatedLines,
      characters: charList,
      scenes: updatedScenes,
      rawText: script.rawText,
    );
  }
}
