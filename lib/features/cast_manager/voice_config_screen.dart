import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

bool shouldTrackVoiceCloudSync({
  required bool isSignedIn,
  required bool requireCloud,
  required bool hadPending,
  required String organizerId,
}) =>
    isSignedIn ||
    requireCloud ||
    hadPending ||
    (organizerId.isNotEmpty && organizerId != 'local');

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
  bool _syncingVoiceSettings = false;
  String? _voiceSettingsError;
  Future<void> Function()? _retryVoiceSettings;
  String? _loadError;
  String? _overrideLoadError;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final production = ref.read(currentProductionProvider);
    if (production == null) return;

    try {
      final preset = await _voiceConfig.getPreset(production.id);
      final genders = await _voiceConfig.getGenders(production.id);
      final pending = await _voiceConfig.getPendingVoiceCloudSync(
        production.id,
      );
      var overrides = <String, CharacterVoiceConfig>{};
      String? overrideLoadError;
      try {
        overrides = await _voiceConfig.getOverrides(production.id);
      } on VoiceOverridesCorruptException catch (error, stack) {
        overrideLoadError = error.toString();
        DebugLogService.instance.logError(
          LogCategory.general,
          'Character voice overrides are unreadable',
          error,
          stack,
        );
      }
      if (!mounted) return;
      setState(() {
        _currentPreset = preset;
        _overrides = overrides;
        _genderOverrides = genders;
        _overrideLoadError = overrideLoadError;
        _loadError = null;
        _loading = false;
        if (pending != null) {
          _voiceSettingsError =
              'A voice settings change still needs to finish and sync to '
              'the cast.';
          _retryVoiceSettings = pending.locale == null
              ? () => _savePreset(
                  production.id,
                  pending.presetId,
                  requireCloud: true,
                )
              : () => _saveDialect(
                  production,
                  pending.locale!,
                  requireCloud: true,
                );
        }
      });
    } catch (error, stack) {
      DebugLogService.instance.logError(
        LogCategory.general,
        'Voice settings load failed',
        error,
        stack,
      );
      if (!mounted) return;
      setState(() {
        _loadError = 'Voice settings could not be loaded.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final script = ref.watch(currentScriptProvider);
    final production = ref.watch(currentProductionProvider);

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
          : _loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.warning_amber_rounded, size: 40),
                    const SizedBox(height: 12),
                    Text(_loadError!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      onPressed: () {
                        setState(() => _loading = true);
                        _loadConfig();
                      },
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            )
          : ContentConstraint(
              maxWidth: 700,
              child: ListView(
                children: [
                  if (_overrideLoadError != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.warning_amber_rounded),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Saved character voice overrides could not '
                              'be read and were left unchanged. Preset and '
                              'dialect controls remain available; '
                              'character voice editing is disabled.',
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (_voiceSettingsError != null)
                    MaterialBanner(
                      content: Text(_voiceSettingsError!),
                      actions: [
                        TextButton(
                          onPressed: _syncingVoiceSettings
                              ? null
                              : () async {
                                  final retry = _retryVoiceSettings;
                                  if (retry != null) await retry();
                                },
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  if (_syncingVoiceSettings) const LinearProgressIndicator(),
                  // Dialect selector
                  _sectionHeader(context, 'Script Dialect'),
                  _buildDialectSelector(context, production),
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
                    (preset) => _buildPresetTile(preset, production.id),
                  ),
                  const Divider(height: 32),

                  // Per-character overrides section
                  _sectionHeader(context, 'Character Voices'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      _overrideLoadError == null
                          ? 'Tap a character to assign a specific voice '
                                'and speed.'
                          : 'Character voice editing is unavailable '
                                'because saved overrides could not be read.',
                      style: TextStyle(color: Colors.grey[500], fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 8),
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

  Widget _buildPresetTile(VoicePreset preset, String productionId) {
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
      onChanged: _syncingVoiceSettings
          ? null
          : (value) async {
              if (value == null) return;
              await _savePreset(productionId, value);
            },
    );
  }

  Future<void> _savePreset(
    String productionId,
    String presetId, {
    bool requireCloud = false,
  }) async {
    if (mounted) {
      setState(() {
        _syncingVoiceSettings = true;
        _voiceSettingsError = null;
      });
    }
    var localSaved = false;
    final supa = SupabaseService.instance;

    try {
      final hadPending =
          await _voiceConfig.getPendingVoiceCloudSync(productionId) != null;
      final production = ref.read(currentProductionProvider);
      final cloudBacked =
          production?.id == productionId &&
          production!.organizerId.isNotEmpty &&
          production.organizerId != 'local';
      final shouldTrackCloudSync = shouldTrackVoiceCloudSync(
        isSignedIn: supa.isSignedIn,
        requireCloud: requireCloud,
        hadPending: hadPending,
        organizerId: cloudBacked ? production.organizerId : '',
      );
      if (shouldTrackCloudSync) {
        await _voiceConfig.markVoiceCloudSyncPending(
          productionId,
          presetId: presetId,
        );
      }
      await _voiceConfig.setPreset(productionId, presetId);
      localSaved = true;
      if (mounted) {
        setState(() => _currentPreset = VoicePresets.byId(presetId));
      }

      if (!supa.isSignedIn && shouldTrackCloudSync) {
        throw StateError('Sign in is required to finish voice sync');
      }
      if (supa.isSignedIn) {
        await supa.saveVoicePreset(
          productionId: productionId,
          presetId: presetId,
        );
        await _voiceConfig.clearPendingVoiceCloudSyncIfMatches(
          productionId,
          presetId: presetId,
        );
      }
      if (!mounted) return;
      setState(() {
        _retryVoiceSettings = null;
        _voiceSettingsError = null;
      });
    } catch (error, stack) {
      DebugLogService.instance.logError(
        LogCategory.network,
        'Voice preset sync failed',
        error,
        stack,
      );
      if (!mounted) return;
      setState(() {
        _voiceSettingsError = localSaved
            ? 'The voice style was saved on this device but could not be '
                  'synced to the cast.'
            : 'The voice style could not be saved. Your prior setting is '
                  'still active.';
        _retryVoiceSettings = () =>
            _savePreset(productionId, presetId, requireCloud: true);
      });
    } finally {
      if (mounted) {
        setState(() => _syncingVoiceSettings = false);
      }
    }
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
              onPressed: _overrideLoadError != null
                  ? null
                  : () async {
                      await _voiceConfig.removeOverride(
                        productionId,
                        char.name,
                      );
                      if (!mounted) return;
                      setState(() => _overrides.remove(char.name));
                    },
            ),
          Icon(
            _overrideLoadError == null ? Icons.chevron_right : Icons.lock,
            size: 18,
          ),
        ],
      ),
      onTap: _overrideLoadError != null
          ? null
          : () => _showCharacterVoiceDialog(
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
                      onPressed: () async {
                        await _voiceConfig.setOverride(
                          productionId,
                          CharacterVoiceConfig(
                            characterName: char.name,
                            voiceId: selectedVoice,
                            speed: selectedSpeed,
                          ),
                        );
                        final overrides = await _voiceConfig.getOverrides(
                          productionId,
                        );
                        if (mounted) setState(() => _overrides = overrides);
                        if (ctx.mounted) Navigator.pop(ctx);
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
    } on PlatformException {
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

  Widget _buildDialectSelector(BuildContext context, Production production) {
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
              onSelectionChanged: _syncingVoiceSettings
                  ? null
                  : (selected) async {
                      await _saveDialect(production, selected.first);
                    },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _saveDialect(
    Production production,
    String locale, {
    bool requireCloud = false,
  }) async {
    final presetId = locale == 'en-GB'
        ? 'victorian_english'
        : 'modern_american';
    final updated = production.copyWith(locale: locale);
    final productionsNotifier = ref.read(productionsProvider.notifier);
    final currentProduction = ref.read(currentProductionProvider.notifier);

    setState(() {
      _syncingVoiceSettings = true;
      _voiceSettingsError = null;
    });
    var localSaved = false;
    final supa = SupabaseService.instance;

    try {
      final hadPending =
          await _voiceConfig.getPendingVoiceCloudSync(production.id) != null;
      final shouldTrackCloudSync = shouldTrackVoiceCloudSync(
        isSignedIn: supa.isSignedIn,
        requireCloud: requireCloud,
        hadPending: hadPending,
        organizerId: production.organizerId,
      );
      if (shouldTrackCloudSync) {
        await _voiceConfig.markVoiceCloudSyncPending(
          production.id,
          presetId: presetId,
          locale: locale,
        );
      }
      currentProduction.state = updated;
      await productionsNotifier.update(updated);
      await _voiceConfig.setPreset(production.id, presetId);
      localSaved = true;
      if (mounted) {
        setState(() => _currentPreset = VoicePresets.byId(presetId));
      }

      if (!supa.isSignedIn && shouldTrackCloudSync) {
        throw StateError('Sign in is required to finish voice sync');
      }
      if (supa.isSignedIn) {
        await Future.wait<void>([
          supa.saveLocale(productionId: production.id, locale: locale),
          supa.saveVoicePreset(productionId: production.id, presetId: presetId),
        ]);
        await _voiceConfig.clearPendingVoiceCloudSyncIfMatches(
          production.id,
          presetId: presetId,
          locale: locale,
        );
      }
      if (!mounted) return;
      setState(() {
        _retryVoiceSettings = null;
        _voiceSettingsError = null;
      });
    } catch (error, stack) {
      DebugLogService.instance.logError(
        LogCategory.network,
        'Voice dialect sync failed',
        error,
        stack,
      );
      if (!mounted) return;
      setState(() {
        _voiceSettingsError = localSaved
            ? 'The dialect was saved on this device but could not be synced '
                  'completely to the cast.'
            : 'The dialect could not be saved completely. Retry to finish '
                  'the change.';
        _retryVoiceSettings = () =>
            _saveDialect(production, locale, requireCloud: true);
      });
    } finally {
      if (mounted) {
        setState(() => _syncingVoiceSettings = false);
      }
    }
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
