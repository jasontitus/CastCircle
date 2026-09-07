import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/responsive.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/script_models.dart';
import '../../data/models/cast_member_model.dart';
import '../../data/models/voice_preset.dart';
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

  Future<void> _toggleGender(
    WidgetRef ref,
    ScriptCharacter char,
    ParsedScript script,
  ) async {
    final newGender = switch (char.gender) {
      CharacterGender.female => CharacterGender.male,
      CharacterGender.male => CharacterGender.nonGendered,
      CharacterGender.nonGendered => CharacterGender.female,
    };

    final production = ref.read(currentProductionProvider);
    if (production != null) {
      try {
        await VoiceConfigService.instance.setGender(
          production.id,
          char.name,
          newGender,
        );
      } catch (e) {
        DebugLogService.instance.logError(
          LogCategory.general,
          'Gender update failed for "${char.name}"',
          e,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showAutoToast(
          const SnackBar(
            content: Text("Couldn't save the gender change. Please try again."),
          ),
        );
        return;
      }
      if (!mounted) return;
    }

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
              try {
                await VoiceConfigService.instance.setLocale(
                  production.id,
                  char.name,
                  value,
                );
              } catch (e) {
                DebugLogService.instance.logError(
                  LogCategory.general,
                  'Dialect update failed for "${char.name}"',
                  e,
                );
                if (!mounted) return;
                ScaffoldMessenger.of(this.context).showAutoToast(
                  const SnackBar(
                    content: Text(
                      "Couldn't save the dialect change. Please try again.",
                    ),
                  ),
                );
                return;
              }
              if (!mounted) return;
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
    final sharedCount = script.lines
        .where((line) => line.multiCharacters.contains(char.name))
        .length;
    final removedCount = script.lines
        .where(
          (line) =>
              (line.lineType == LineType.dialogue ||
                  line.lineType == LineType.song) &&
              line.character == char.name &&
              !line.multiCharacters.contains(char.name),
        )
        .length;
    final sharedDetail = sharedCount == 0
        ? ''
        : ' ${char.name} will also be removed from $sharedCount shared '
              'line(s); the other speakers and dialogue will remain.';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${char.name}"?'),
        content: Text(
          'This will remove $removedCount line(s) attributed only to '
          '${char.name}.$sharedDetail Any cast assignments and saved voice '
          'settings for ${char.name} will also be removed. This cannot be '
          'undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(context);
              await _applyDeleteWithCleanup(ref, char.name);
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
      if (!mounted) return;
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
            failures.add(
              member.displayName.isNotEmpty ? member.displayName : oldName,
            );
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

  Future<void> _applyDeleteWithCleanup(WidgetRef ref, String charName) async {
    final production = ref.read(currentProductionProvider);
    final initialScript = ref.read(currentScriptProvider);
    if (production == null || initialScript == null) return;

    final productionState = ref.read(currentProductionProvider.notifier);
    final scriptState = ref.read(currentScriptProvider.notifier);
    final castNotifier = ref.read(castMembersProvider.notifier);
    final repository = ref.read(productionRepositoryProvider);
    final supa = SupabaseService.instance;
    final voiceConfig = VoiceConfigService.instance;
    final requiresCloud =
        production.organizerId.isNotEmpty && production.organizerId != 'local';

    if (requiresCloud && !supa.isSignedIn) {
      if (mounted) {
        ScaffoldMessenger.of(context).showAutoToast(
          const SnackBar(
            content: Text(
              'Sign in before deleting this character so shared cast '
              'assignments can be removed safely.',
            ),
          ),
        );
      }
      return;
    }

    late final List<CastMemberModel> assigned;
    late final List<CastMemberModel> remoteAssigned;
    late final Map<String, CharacterVoiceConfig> voiceOverrides;
    late final Map<String, CharacterGender> genders;
    late final Map<String, String> locales;
    try {
      assigned = (await repository.getCastMembers(
        production.id,
      )).where((member) => member.characterName == charName).toList();
      voiceOverrides = await voiceConfig.getOverrides(production.id);
      genders = await voiceConfig.getGenders(production.id);
      locales = await voiceConfig.getLocales(production.id);
      if (requiresCloud) {
        final rows = await supa.fetchCastMembers(production.id);
        remoteAssigned = [
          for (final row in rows)
            if ((row['character_name'] as String? ?? '') == charName)
              CastMemberModel(
                id: row['id'] as String,
                productionId: production.id,
                userId: row['user_id'] as String?,
                characterName: charName,
                displayName: row['display_name'] as String? ?? '',
                contactInfo: row['contact_info'] as String?,
                role: CastRole.fromString(row['role'] as String? ?? 'actor'),
                invitedAt: row['invited_at'] == null
                    ? null
                    : DateTime.tryParse(row['invited_at'] as String),
                joinedAt: row['joined_at'] == null
                    ? null
                    : DateTime.tryParse(row['joined_at'] as String),
              ),
        ];
      } else {
        remoteAssigned = const [];
      }
    } catch (e) {
      DebugLogService.instance.logError(
        LogCategory.general,
        'Could not snapshot "$charName" before deletion',
        e,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showAutoToast(
          const SnackBar(
            content: Text(
              "Couldn't prepare a safe character deletion. Nothing changed.",
            ),
          ),
        );
      }
      return;
    }

    Future<void> restoreDependencies() async {
      try {
        await voiceConfig.removeCharacterSettings(production.id, charName);
        final override = voiceOverrides[charName];
        if (override != null) {
          await voiceConfig.setOverride(production.id, override);
        }
        final gender = genders[charName];
        if (gender != null) {
          await voiceConfig.setGender(production.id, charName, gender);
        }
        final locale = locales[charName];
        if (locale != null) {
          await voiceConfig.setLocale(production.id, charName, locale);
        }
      } catch (e) {
        DebugLogService.instance.logError(
          LogCategory.general,
          'Voice rollback failed for "$charName"',
          e,
        );
      }
      for (final member in assigned) {
        try {
          await repository.saveCastMember(member);
        } catch (e) {
          DebugLogService.instance.logError(
            LogCategory.general,
            'Local cast rollback failed for ${member.id}',
            e,
          );
        }
      }
      for (final member in remoteAssigned) {
        try {
          await supa.restoreCastMember(member);
        } catch (e) {
          DebugLogService.instance.logError(
            LogCategory.network,
            'Cloud cast rollback failed for ${member.id}',
            e,
          );
        }
      }
    }

    try {
      if (requiresCloud) {
        final remoteIds = {
          for (final member in remoteAssigned) member.id,
          for (final member in assigned) member.id,
        };
        for (final id in remoteIds) {
          await supa.removeCastMember(id);
        }
      }
      await voiceConfig.removeCharacterSettings(production.id, charName);
      for (final member in assigned) {
        await repository.deleteCastMember(member.id);
      }
    } catch (e) {
      await restoreDependencies();
      DebugLogService.instance.logError(
        LogCategory.general,
        'Character cleanup failed for "$charName"',
        e,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showAutoToast(
          SnackBar(
            content: Text(
              "Couldn't safely remove $charName. The deletion was rolled "
              'back; check your connection and try again.',
            ),
            duration: const Duration(seconds: 6),
          ),
        );
      }
      return;
    }

    final isStillCurrent = productionState.state?.id == production.id;
    final baseScript = isStillCurrent
        ? (scriptState.state ?? initialScript)
        : initialScript;
    final updated = _scriptWithoutCharacter(baseScript, charName);
    try {
      await repository.saveScriptLines(production.id, updated.lines);
      await repository.saveScenes(production.id, updated.scenes);
    } catch (e) {
      await restoreDependencies();
      try {
        await repository.saveScriptLines(production.id, baseScript.lines);
        await repository.saveScenes(production.id, baseScript.scenes);
      } catch (rollbackError) {
        DebugLogService.instance.logError(
          LogCategory.general,
          'Script rollback failed after deleting "$charName"',
          rollbackError,
        );
      }
      DebugLogService.instance.logError(
        LogCategory.general,
        'Script persistence failed while deleting "$charName"',
        e,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showAutoToast(
          const SnackBar(
            content: Text(
              "The character couldn't be saved as deleted, so the operation "
              'was rolled back.',
            ),
            duration: Duration(seconds: 6),
          ),
        );
      }
      return;
    }

    // The production-scoped repository operation always completes. Only
    // provider/UI updates depend on this production still being current.
    if (productionState.state?.id == production.id) {
      try {
        await castNotifier.loadForProduction(production.id);
      } catch (e) {
        DebugLogService.instance.logError(
          LogCategory.general,
          'Cast provider refresh failed after deleting "$charName"',
          e,
        );
      }
      if (productionState.state?.id != production.id) return;
      scriptState.state = updated;
      if (mounted) scheduleScriptSave(ref);
    }
  }

  ParsedScript _scriptWithoutCharacter(ParsedScript script, String charName) {
    final updatedLines = <ScriptLine>[];
    for (final line in script.lines) {
      if (line.lineType != LineType.dialogue &&
          line.lineType != LineType.song) {
        updatedLines.add(line);
        continue;
      }

      if (line.multiCharacters.contains(charName)) {
        final remaining = line.multiCharacters
            .where((name) => name != charName)
            .toList();
        if (remaining.isEmpty) continue;
        updatedLines.add(
          line.copyWith(
            character: remaining.join(', '),
            multiCharacters: remaining.length == 1 ? const [] : remaining,
          ),
        );
        continue;
      }

      if (line.character != charName) updatedLines.add(line);
    }

    return _buildRebuiltScript(script, updatedLines);
  }

  void _rebuildScript(
    WidgetRef ref,
    ParsedScript script,
    List<ScriptLine> updatedLines, {
    String? renamedFrom,
    String? renamedTo,
  }) {
    ref.read(currentScriptProvider.notifier).state = _buildRebuiltScript(
      script,
      updatedLines,
      renamedFrom: renamedFrom,
      renamedTo: renamedTo,
    );
    scheduleScriptSave(ref);
  }

  ParsedScript _buildRebuiltScript(
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
      if (carried != null)
        existingGenders.putIfAbsent(renamedTo, () => carried);
    }
    final charCounts = <String, int>{};
    for (final line in updatedLines) {
      if (line.lineType != LineType.dialogue &&
          line.lineType != LineType.song) {
        continue;
      }
      final speakers = line.multiCharacters.isNotEmpty
          ? line.multiCharacters
          : [line.character];
      for (final speaker in speakers) {
        if (speaker.isNotEmpty) {
          charCounts[speaker] = (charCounts[speaker] ?? 0) + 1;
        }
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

    return ParsedScript(
      title: script.title,
      lines: updatedLines,
      characters: charList,
      scenes: updatedScenes,
      rawText: script.rawText,
    );
  }
}
