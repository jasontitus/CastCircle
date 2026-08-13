import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/responsive.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/script_models.dart';
import '../../data/services/debug_log_service.dart';
import '../../data/services/supabase_service.dart';
import '../../data/services/voice_config_service.dart';
import '../../providers/production_providers.dart';
import '../../core/toast.dart';

const _localeOptions = {
  null: 'Production Default',
  'en-US': 'American English',
  'en-GB': 'British English',
};

class CharacterManagerScreen extends ConsumerStatefulWidget {
  const CharacterManagerScreen({super.key});

  @override
  ConsumerState<CharacterManagerScreen> createState() =>
      _CharacterManagerScreenState();
}

class _CharacterManagerScreenState
    extends ConsumerState<CharacterManagerScreen> {
  Map<String, String> _charLocales = {};

  @override
  void initState() {
    super.initState();
    _loadLocales();
  }

  Future<void> _loadLocales() async {
    final production = ref.read(currentProductionProvider);
    if (production != null) {
      final locales = await VoiceConfigService.instance.getLocales(
        production.id,
      );
      if (mounted) setState(() => _charLocales = locales);
    }
  }

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
    final singleLineChars = script.characters
        .where((c) => c.lineCount == 1)
        .toList();
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
                  const Icon(
                    Icons.warning_amber,
                    color: Colors.orange,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${singleLineChars.length} character(s) with only 1 line '
                      '— likely OCR errors. Tap to merge or delete.',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.orange,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // Character list
          Expanded(
            child: ContentConstraint(
              maxWidth: 720,
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
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      title: Text(char.name),
                      subtitle: Text(
                        '${char.lineCount} lines · ${_genderLabel(char.gender)}'
                        '${_charLocales.containsKey(char.name) ? ' · ${_localeOptions[_charLocales[char.name]] ?? _charLocales[char.name]}' : ''}',
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
                            onSelected: (action) => _handleAction(
                              context,
                              ref,
                              action,
                              char,
                              script,
                            ),
                            itemBuilder: (context) => [
                              const PopupMenuItem(
                                value: 'locale',
                                child: ListTile(
                                  leading: Icon(Icons.language),
                                  title: Text('Set Dialect'),
                                  dense: true,
                                ),
                              ),
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
                                  title: Text('Merge into another'),
                                  dense: true,
                                ),
                              ),
                              if (char.lineCount <= 1)
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: ListTile(
                                    leading: Icon(
                                      Icons.delete_outline,
                                      color: Colors.red,
                                    ),
                                    title: Text(
                                      'Delete',
                                      style: TextStyle(color: Colors.red),
                                    ),
                                    dense: true,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                      onTap: () =>
                          _showCharacterDetail(context, ref, char, script),
                    ),
                  );
                },
              ),
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
      VoiceConfigService.instance.setGender(
        production.id,
        char.name,
        newGender,
      );
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
    // Editor mutations used to live in memory only — an app kill, or
    // simply opening another production, silently discarded them.
    scheduleScriptSave(ref);
  }

  void _handleAction(
    BuildContext context,
    WidgetRef ref,
    String action,
    ScriptCharacter char,
    ParsedScript script,
  ) {
    switch (action) {
      case 'locale':
        _setCharacterLocale(context, char);
      case 'rename':
        _renameCharacter(context, ref, char, script);
      case 'merge':
        _mergeCharacter(context, ref, char, script);
      case 'delete':
        _deleteCharacter(context, ref, char, script);
    }
  }

  void _setCharacterLocale(BuildContext context, ScriptCharacter char) {
    final production = ref.read(currentProductionProvider);
    if (production == null) return;
    final currentLocale = _charLocales[char.name];

    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Dialect for ${char.name}'),
        children: _localeOptions.entries.map((e) {
          return RadioListTile<String?>(
            value: e.key,
            groupValue: currentLocale,
            title: Text(e.value),
            onChanged: (value) async {
              await VoiceConfigService.instance.setLocale(
                production.id,
                char.name,
                value,
              );
              setState(() {
                if (value == null) {
                  _charLocales.remove(char.name);
                } else {
                  _charLocales[char.name] = value;
                }
              });
              if (ctx.mounted) Navigator.pop(ctx);
            },
          );
        }).toList(),
      ),
    );
  }

  void _renameCharacter(
    BuildContext context,
    WidgetRef ref,
    ScriptCharacter char,
    ParsedScript script,
  ) {
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

  void _mergeCharacter(
    BuildContext context,
    WidgetRef ref,
    ScriptCharacter char,
    ParsedScript script,
  ) {
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
                  child: Text(
                    target.name[0],
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
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

  void _deleteCharacter(
    BuildContext context,
    WidgetRef ref,
    ScriptCharacter char,
    ParsedScript script,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${char.name}"?'),
        content: Text(
          'This will remove ${char.lineCount} line(s) attributed to ${char.name}. '
          'This cannot be undone.',
        ),
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

  void _showCharacterDetail(
    BuildContext context,
    WidgetRef ref,
    ScriptCharacter char,
    ParsedScript script,
  ) {
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
                    backgroundColor: AppTheme.colorForCharacter(
                      char.colorIndex,
                    ),
                    child: Text(
                      char.name[0],
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          char.name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          '${char.lineCount} lines in ${scenes.length} scenes',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
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
                              color: Colors.grey[600],
                              fontSize: 11,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            line.text,
                            style: const TextStyle(fontSize: 14),
                          ),
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

  /// Rename (or merge) a character everywhere it is keyed by NAME.
  ///
  /// Both the rename and the merge path land here: only the script lines used
  /// to be rewritten, so the cast assignment (local + cloud), the voice
  /// override, the dialect and the gender all stayed pinned to a name the
  /// script no longer contains — the actor showed up as unassigned and their
  /// custom voice vanished.
  Future<void> _applyRename(
    WidgetRef ref,
    ParsedScript script,
    String oldName,
    String newName,
  ) async {
    final updatedLines = script.lines.map((l) {
      if (l.character == oldName) {
        return l.copyWith(character: newName);
      }
      // Also rename within multiCharacters
      if (l.multiCharacters.contains(oldName)) {
        final updated = l.multiCharacters
            .map((c) => c == oldName ? newName : c)
            .toList();
        // Update the combined display name too
        final newDisplayName = updated.join(', ');
        return l.copyWith(character: newDisplayName, multiCharacters: updated);
      }
      return l;
    }).toList();

    _rebuildScript(
      ref,
      script,
      updatedLines,
      renamedFrom: oldName,
      renamedTo: newName,
    );

    final production = ref.read(currentProductionProvider);
    if (production == null) return;

    await _migrateVoiceConfig(production.id, oldName, newName);
    await _migrateCastMembers(production.id, oldName, newName);
  }

  /// Move the persisted voice override, dialect and gender onto [newName].
  Future<void> _migrateVoiceConfig(
    String productionId,
    String oldName,
    String newName,
  ) async {
    try {
      await VoiceConfigService.instance.renameCharacter(
        productionId,
        oldName,
        newName,
      );
      final locales = await VoiceConfigService.instance.getLocales(
        productionId,
      );
      if (mounted) setState(() => _charLocales = locales);
    } catch (e) {
      DebugLogService.instance.logError(
        LogCategory.general,
        'Voice config rename "$oldName" → "$newName" failed',
        e,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showAutoToast(
        SnackBar(
          content: Text(
            'Renamed the script lines, but $newName\'s voice, dialect and '
            'gender settings could not be moved over — set them again in '
            'Cast & Roles.',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  /// Re-point the cast rows (local Drift + cloud) at [newName].
  Future<void> _migrateCastMembers(
    String productionId,
    String oldName,
    String newName,
  ) async {
    final notifier = ref.read(castMembersProvider.notifier);
    final supa = SupabaseService.instance;
    final failures = <String>[];

    try {
      // This screen never loads the cast itself — without this a rename made
      // before ever opening Cast & Roles would see an empty list and skip the
      // migration entirely.
      await notifier.loadForProduction(productionId);
      final affected = ref
          .read(castMembersProvider)
          .where((m) => m.characterName == oldName)
          .toList();

      for (final member in affected) {
        if (supa.isSignedIn) {
          try {
            await supa.renameCastCharacter(
              castMemberId: member.id,
              characterName: newName,
            );
          } catch (e) {
            // Still rename locally so the UI is coherent, but say so: the
            // cloud row wins on the next sync and will revert this.
            failures.add(member.displayName.isNotEmpty
                ? member.displayName
                : oldName);
            DebugLogService.instance.logError(
              LogCategory.network,
              'Cloud cast rename "$oldName" → "$newName" failed for '
              '${member.id}',
              e,
            );
          }
        }
        await notifier.save(member.copyWith(characterName: newName));
      }
    } catch (e) {
      DebugLogService.instance.logError(
        LogCategory.general,
        'Cast rename "$oldName" → "$newName" failed',
        e,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showAutoToast(
        SnackBar(
          content: Text(
            'Renamed the script lines, but the actor assigned to $oldName '
            'could not be moved to $newName — reassign them in Cast & Roles.',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
      return;
    }

    if (failures.isEmpty) return;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showAutoToast(
      SnackBar(
        content: Text(
          'Couldn\'t update the cloud cast for ${failures.join(', ')} — the '
          'old character name will come back on the next sync. Check your '
          'connection and rename again.',
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  void _applyDelete(WidgetRef ref, ParsedScript script, String charName) {
    final updatedLines = script.lines
        .where(
          (l) =>
              !(l.lineType == LineType.dialogue && l.character == charName) &&
              !(l.lineType == LineType.dialogue &&
                  l.multiCharacters.contains(charName)),
        )
        .toList();

    _rebuildScript(ref, script, updatedLines);
  }

  void _rebuildScript(
    WidgetRef ref,
    ParsedScript script,
    List<ScriptLine> updatedLines, {
    String? renamedFrom,
    String? renamedTo,
  }) {
    // Recalculate characters, preserving genders from existing script
    final existingGenders = {
      for (final c in script.characters) c.name: c.gender,
    };
    // A rename rebuilds the list under the NEW name, which has no entry in the
    // map above — without carrying it over the gender resets to the default.
    // putIfAbsent so a merge target keeps its own gender.
    if (renamedFrom != null && renamedTo != null) {
      final carried = existingGenders[renamedFrom];
      if (carried != null) existingGenders.putIfAbsent(renamedTo, () => carried);
    }
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
        .map(
          (e) => ScriptCharacter(
            name: e.key,
            colorIndex: colorIdx++,
            lineCount: e.value,
            gender: existingGenders[e.key] ?? CharacterGender.female,
          ),
        )
        .toList();

    // Scene ranges are POSITIONAL indices into `lines`, so deleting or
    // merging a character (which drops that character's lines) shifts every
    // later scene — rehearsal would then play the wrong slice while the
    // script itself still read correctly. Remap by line id first.
    final remappedScenes = ParsedScript.remapScenes(
      script.scenes,
      script.lines,
      updatedLines,
    );

    // Then recompute each scene's character list from its (new) range.
    // NB: index into updatedLines positionally — the previous code compared
    // `line.orderIndex` against the scene's start/end, which are different
    // domains (the parser numbers orderIndex from 1, a drag-reorder renumbers
    // it from 0), so the membership test was wrong even before any edit.
    final updatedScenes = remappedScenes.map((scene) {
      final sceneChars = <String>{};
      final end = scene.endLineIndex.clamp(0, updatedLines.length - 1);
      for (var i = scene.startLineIndex; i <= end; i++) {
        final line = updatedLines[i];
        if (line.lineType != LineType.dialogue) continue;
        if (line.multiCharacters.isNotEmpty) {
          sceneChars.addAll(line.multiCharacters);
        } else if (line.character.isNotEmpty) {
          sceneChars.add(line.character);
        }
      }
      return scene.copyWith(characters: sceneChars.toList()..sort());
    }).toList();

    ref.read(currentScriptProvider.notifier).state = ParsedScript(
      title: script.title,
      lines: updatedLines,
      characters: charList,
      scenes: updatedScenes,
      rawText: script.rawText,
    );
    // Editor mutations used to live in memory only — an app kill, or
    // simply opening another production, silently discarded them.
    scheduleScriptSave(ref);
  }
}
