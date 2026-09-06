import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/responsive.dart';
import '../../data/models/production_models.dart';
import '../../data/models/script_models.dart';
import '../../data/models/voice_preset.dart';
import '../../data/services/debug_log_service.dart';
import '../../data/services/supabase_service.dart';
import '../../data/services/tts_service.dart';
import '../../data/services/voice_config_service.dart';
import '../../providers/production_providers.dart';
import '../../core/toast.dart';

/// Screen for configuring production voice preset and per-character overrides.
class VoiceConfigScreen extends ConsumerStatefulWidget {
  const VoiceConfigScreen({super.key});

  @override
  ConsumerState<VoiceConfigScreen> createState() => _VoiceConfigScreenState();
}

class _VoiceConfigScreenState extends ConsumerState<VoiceConfigScreen> {
  final _voiceConfig = VoiceConfigService.instance;
  VoicePreset _currentPreset = VoicePresets.modernAmerican;
  Map<String, CharacterVoiceConfig> _overrides = {};
  Map<String, CharacterGender> _genderOverrides = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final production = ref.read(currentProductionProvider);
    if (production == null) return;

    final preset = await _voiceConfig.getPreset(production.id);
    final overrides = await _voiceConfig.getOverrides(production.id);
    // Saved gender toggles too — without them the voice shown here diverged
    // from the voice rehearsal actually plays (rehearsal passes them).
    final genders = await _voiceConfig.getGenders(production.id);
    if (!mounted) return;
    setState(() {
      _currentPreset = preset;
      _overrides = overrides;
      _genderOverrides = genders;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final script = ref.watch(currentScriptProvider);
    final production = ref.watch(currentProductionProvider);
    final supa = SupabaseService.instance;
    final canEditProductionVoice =
        production == null ||
        production.organizerId.isEmpty ||
        production.organizerId == 'local' ||
        production.organizerId == supa.currentUser?.id;
    final syncProductionVoice =
        supa.isSignedIn && production?.organizerId == supa.currentUser?.id;
    if (script == null || production == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Voice Settings')),
        body: const Center(child: Text('No production loaded')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Voice Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ContentConstraint(
              maxWidth: 700,
              child: ListView(
                children: [
                  if (!canEditProductionVoice)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Text(
                        'Only the production organizer can change the shared '
                        'dialect and voice style.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  // Dialect selector
                  _sectionHeader(context, 'Script Dialect'),
                  _buildDialectSelector(
                    context,
                    production,
                    canEdit: canEditProductionVoice,
                  ),
                  const Divider(height: 32),

                  // Production preset section
                  _sectionHeader(context, 'Production Style'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'Sets the default accent and pacing for all characters. '
                      'You can override individual characters below.',
                      style: TextStyle(color: Colors.grey[500], fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...VoicePresets.all.map(
                    (preset) => _buildPresetTile(
                      preset,
                      production.id,
                      canEdit: canEditProductionVoice,
                      syncToCloud: syncProductionVoice,
                    ),
                  ),
                  const Divider(height: 32),

                  // Per-character overrides section
                  _sectionHeader(context, 'Character Voices'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'Tap a character to assign a specific voice and speed.',
                      style: TextStyle(color: Colors.grey[500], fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Assignment computed ONCE for all tiles (it walks every
                  // script line), with gender overrides so the shown voice
                  // matches rehearsal playback.
                  ...script.characters.map(
                    (char) => _buildCharacterTile(
                      char,
                      production.id,
                      script,
                      _memoAssignment(script),
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
    );
  }

  // Memoized like cast_manager's copy: the full-script adjacency walk +
  // greedy coloring re-ran on every setState (preset tap, dialect toggle)
  // for a script that hadn't changed.
  Map<String, String>? _assignmentCache;
  Object? _assignmentKey;

  Map<String, String> _memoAssignment(ParsedScript script) {
    final key = Object.hash(
      identityHashCode(script.lines),
      _currentPreset.id,
      _genderOverrides.toString(),
    );
    if (_assignmentCache != null && _assignmentKey == key) {
      return _assignmentCache!;
    }
    _assignmentKey = key;
    return _assignmentCache = VoiceConfigService.assignVoicesFromScript(
      lines: script.lines,
      characters: script.characters,
      femaleVoices: _currentPreset.femaleVoices,
      maleVoices: _currentPreset.maleVoices,
      genderOverrides: _genderOverrides,
    );
  }

  Widget _buildPresetTile(
    VoicePreset preset,
    String productionId, {
    required bool canEdit,
    required bool syncToCloud,
  }) {
    final isSelected = _currentPreset.id == preset.id;
    return RadioListTile<String>(
      value: preset.id,
      groupValue: _currentPreset.id,
      title: Text(preset.name),
      subtitle: Text(preset.description),
      secondary: isSelected
          ? Icon(
              Icons.check_circle,
              color: Theme.of(context).colorScheme.primary,
            )
          : null,
      onChanged: !canEdit
          ? null
          : (value) async {
              if (value == null) return;
              try {
                await _voiceConfig.setPreset(productionId, value);
              } catch (e, stack) {
                DebugLogService.instance.logError(
                  LogCategory.general,
                  'Saving the production voice preset failed',
                  e,
                  stack,
                );
                if (mounted) {
                  ScaffoldMessenger.of(context).showAutoToast(
                    const SnackBar(content: Text('Could not save voice style')),
                  );
                }
                return;
              }
              if (!mounted) return;
              setState(() => _currentPreset = VoicePresets.byId(value));

              final supa = SupabaseService.instance;
              if (!syncToCloud) return;
              try {
                await supa.saveVoicePreset(
                  productionId: productionId,
                  presetId: value,
                );
              } catch (e, stack) {
                DebugLogService.instance.logError(
                  LogCategory.network,
                  'Syncing the production voice preset failed',
                  e,
                  stack,
                );
                if (mounted) {
                  ScaffoldMessenger.of(context).showAutoToast(
                    const SnackBar(
                      content: Text(
                        'Voice style saved on this device, but cloud sync '
                        'failed',
                      ),
                    ),
                  );
                }
              }
            },
    );
  }

  Widget _buildCharacterTile(
    ScriptCharacter char,
    String productionId,
    ParsedScript script,
    Map<String, String> autoAssignment,
  ) {
    final override = _overrides[char.name];
    final hasOverride = override != null;
    final presetVoice = autoAssignment[char.name] ?? 'af_heart';
    final activeVoice = hasOverride ? override.voiceId : presetVoice;
    final activeSpeed = hasOverride
        ? override.speed
        : _currentPreset.defaultSpeed;
    final voiceLabel = VoicePresets.voiceLabels[activeVoice] ?? activeVoice;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: hasOverride
            ? Theme.of(context).colorScheme.primary
            : Colors.grey,
        radius: 18,
        child: Text(
          char.name.isEmpty ? '?' : char.name[0],
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
      ),
      title: Text(char.name),
      subtitle: Text(
        hasOverride
            ? '$voiceLabel  ${activeSpeed}x (custom)'
            : '$voiceLabel  ${activeSpeed}x (from preset)',
        style: TextStyle(
          color: hasOverride
              ? Theme.of(context).colorScheme.primary
              : Colors.grey[500],
          fontSize: 12,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasOverride)
            IconButton(
              icon: const Icon(Icons.undo, size: 18),
              tooltip: 'Reset to preset',
              onPressed: () async {
                try {
                  await _voiceConfig.removeOverride(productionId, char.name);
                } catch (e, stack) {
                  DebugLogService.instance.logError(
                    LogCategory.general,
                    'Resetting ${char.name} voice failed',
                    e,
                    stack,
                  );
                  if (mounted) {
                    ScaffoldMessenger.of(context).showAutoToast(
                      const SnackBar(
                        content: Text('Could not reset character voice'),
                      ),
                    );
                  }
                  return;
                }
                if (!mounted) return;
                setState(() => _overrides.remove(char.name));
              },
            ),
          const Icon(Icons.chevron_right, size: 18),
        ],
      ),
      onTap: () => _showCharacterVoiceDialog(
        char,
        productionId,
        activeVoice,
        activeSpeed,
      ),
    );
  }

  void _showCharacterVoiceDialog(
    ScriptCharacter char,
    String productionId,
    String currentVoice,
    double currentSpeed,
  ) {
    String selectedVoice = currentVoice;
    double selectedSpeed = currentSpeed;
    bool isSaving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (ctx, scrollController) => Column(
            children: [
              // Handle bar
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[600],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Header
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        char.name,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    // Preview button
                    IconButton(
                      icon: const Icon(Icons.play_circle_outline),
                      tooltip: 'Preview voice',
                      onPressed: () => _previewVoice(
                        selectedVoice,
                        selectedSpeed,
                        char.name,
                      ),
                    ),
                    FilledButton(
                      onPressed: isSaving
                          ? null
                          : () async {
                              if (isSaving) return;
                              setSheetState(() => isSaving = true);
                              try {
                                await _voiceConfig.setOverride(
                                  productionId,
                                  CharacterVoiceConfig(
                                    characterName: char.name,
                                    voiceId: selectedVoice,
                                    speed: selectedSpeed,
                                  ),
                                );
                                final overrides = await _voiceConfig
                                    .getOverrides(productionId);
                                if (mounted) {
                                  setState(() => _overrides = overrides);
                                }
                                if (ctx.mounted) Navigator.pop(ctx);
                              } catch (e, stack) {
                                DebugLogService.instance.logError(
                                  LogCategory.general,
                                  'Saving ${char.name} voice failed',
                                  e,
                                  stack,
                                );
                                if (ctx.mounted) {
                                  ScaffoldMessenger.of(ctx).showAutoToast(
                                    const SnackBar(
                                      content: Text(
                                        'Could not save character voice',
                                      ),
                                    ),
                                  );
                                }
                              } finally {
                                if (ctx.mounted) {
                                  setSheetState(() => isSaving = false);
                                }
                              }
                            },
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ),
              // Speed slider
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Text('Speed', style: TextStyle(fontSize: 13)),
                    Expanded(
                      child: Slider(
                        value: selectedSpeed,
                        min: 0.5,
                        max: 2.0,
                        divisions: 15,
                        label: '${selectedSpeed.toStringAsFixed(2)}x',
                        onChanged: (v) =>
                            setSheetState(() => selectedSpeed = v),
                      ),
                    ),
                    Text(
                      '${selectedSpeed.toStringAsFixed(2)}x',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
              const Divider(),
              // Voice list
              Expanded(
                child: ListView(
                  controller: scrollController,
                  children: VoicePresets.voiceLabels.entries.map((entry) {
                    final isSelected = selectedVoice == entry.key;
                    return RadioListTile<String>(
                      value: entry.key,
                      groupValue: selectedVoice,
                      title: Text(entry.value),
                      dense: true,
                      onChanged: (v) {
                        if (v != null) {
                          setSheetState(() => selectedVoice = v);
                        }
                      },
                      secondary: isSelected
                          ? IconButton(
                              icon: const Icon(Icons.volume_up, size: 18),
                              onPressed: () => _previewVoice(
                                entry.key,
                                selectedSpeed,
                                char.name,
                              ),
                            )
                          : null,
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Preview a voice by synthesizing a short sample line.
  Future<void> _previewVoice(
    String voiceId,
    double speed,
    String characterName,
  ) async {
    final tts = TtsService.instance;
    if (!tts.isKokoroLoaded) {
      ScaffoldMessenger.of(
        context,
      ).showAutoToast(const SnackBar(content: Text('Kokoro model not loaded')));
      return;
    }

    // Use a short sample that sounds natural
    const sampleText = 'To be, or not to be, that is the question.';

    try {
      // Preview under a scratch name: assigning to the real character
      // permanently mutated the TTS singleton's maps, so any speak() that
      // didn't re-run rehearsal's _assignVoices used the previewed voice
      // instead of the configured one.
      const previewChar = '__voice_preview__';
      tts.assignVoice(previewChar, 0, voiceId: voiceId, speed: speed);
      await tts.speak(sampleText, character: previewChar);
    } catch (e, stack) {
      DebugLogService.instance.logError(
        LogCategory.tts,
        'Voice preview failed for $characterName',
        e,
        stack,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showAutoToast(const SnackBar(content: Text('Preview failed')));
      }
    }
  }

  static const _localeLabels = {
    'en-US': 'American English',
    'en-GB': 'British English',
  };

  Widget _buildDialectSelector(
    BuildContext context,
    Production production, {
    required bool canEdit,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Changing the dialect also updates the default voice preset '
            'and syncs to all cast members.',
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              segments: _localeLabels.entries
                  .map((e) => ButtonSegment(value: e.key, label: Text(e.value)))
                  .toList(),
              selected: {production.locale},
              onSelectionChanged: !canEdit
                  ? null
                  : (selected) async {
                      final locale = selected.first;
                      final updated = production.copyWith(locale: locale);
                      final presetId = locale == 'en-GB'
                          ? 'victorian_english'
                          : 'modern_american';
                      try {
                        await ref
                            .read(productionsProvider.notifier)
                            .update(updated);
                        await _voiceConfig.setPreset(production.id, presetId);
                      } catch (e, stack) {
                        DebugLogService.instance.logError(
                          LogCategory.general,
                          'Saving the production dialect failed',
                          e,
                          stack,
                        );
                        if (mounted) {
                          ScaffoldMessenger.of(context).showAutoToast(
                            const SnackBar(
                              content: Text('Could not save script dialect'),
                            ),
                          );
                        }
                        return;
                      }
                      if (!mounted) return;
                      ref.read(currentProductionProvider.notifier).state =
                          updated;
                      setState(
                        () => _currentPreset = VoicePresets.byId(presetId),
                      );

                      final supa = SupabaseService.instance;
                      if (!supa.isSignedIn ||
                          production.organizerId != supa.currentUser?.id) {
                        return;
                      }
                      try {
                        await supa.saveLocale(
                          productionId: production.id,
                          locale: locale,
                        );
                        await supa.saveVoicePreset(
                          productionId: production.id,
                          presetId: presetId,
                        );
                      } catch (e, stack) {
                        DebugLogService.instance.logError(
                          LogCategory.network,
                          'Syncing the production dialect failed',
                          e,
                          stack,
                        );
                        if (mounted) {
                          ScaffoldMessenger.of(context).showAutoToast(
                            const SnackBar(
                              content: Text(
                                'Dialect saved on this device, but cloud sync '
                                'failed',
                              ),
                            ),
                          );
                        }
                      }
                    },
            ),
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
