import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/script_models.dart';
import '../../data/models/voice_preset.dart';
import '../../data/services/tts_service.dart';
import '../../data/services/voice_config_service.dart';
import '../../providers/production_providers.dart';

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
    setState(() {
      _currentPreset = preset;
      _overrides = overrides;
      _loading = false;
    });
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
      appBar: AppBar(
        title: const Text('Voice Settings'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
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
                ...VoicePresets.all
                    .map((preset) => _buildPresetTile(preset, production.id)),
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
                ...script.characters.map(
                    (char) => _buildCharacterTile(char, production.id, script)),
                const SizedBox(height: 32),
              ],
            ),
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
          ? Icon(Icons.check_circle,
              color: Theme.of(context).colorScheme.primary)
          : null,
      onChanged: (value) async {
        if (value == null) return;
        await _voiceConfig.setPreset(productionId, value);
        setState(() => _currentPreset = VoicePresets.byId(value));
      },
    );
  }

  Widget _buildCharacterTile(
      ScriptCharacter char, String productionId, ParsedScript script) {
    final override = _overrides[char.name];
    final hasOverride = override != null;

    // Determine what voice this character would get from the preset
    final charIndex = script.characters.indexOf(char);
    final pool = switch (char.gender) {
      CharacterGender.female => _currentPreset.femaleVoices,
      CharacterGender.male => _currentPreset.maleVoices,
      CharacterGender.nonGendered => [
        ..._currentPreset.femaleVoices,
        ..._currentPreset.maleVoices,
      ],
    };
    final presetVoice = pool.isNotEmpty
        ? pool[charIndex % pool.length]
        : 'af_heart';
    final activeVoice = hasOverride ? override.voiceId : presetVoice;
    final activeSpeed =
        hasOverride ? override.speed : _currentPreset.defaultSpeed;
    final voiceLabel =
        VoicePresets.voiceLabels[activeVoice] ?? activeVoice;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor:
            hasOverride ? Theme.of(context).colorScheme.primary : Colors.grey,
        radius: 18,
        child: Text(
          char.name[0],
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
                await _voiceConfig.removeOverride(productionId, char.name);
                setState(() => _overrides.remove(char.name));
              },
            ),
          const Icon(Icons.chevron_right, size: 18),
        ],
      ),
      onTap: () => _showCharacterVoiceDialog(
        char, productionId, activeVoice, activeSpeed,
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                          selectedVoice, selectedSpeed, char.name),
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
                        final overrides =
                            await _voiceConfig.getOverrides(productionId);
                        setState(() => _overrides = overrides);
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
                    Text('${selectedSpeed.toStringAsFixed(2)}x',
                        style: const TextStyle(fontSize: 13)),
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
                                  entry.key, selectedSpeed, char.name),
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
      String voiceId, double speed, String characterName) async {
    final tts = TtsService.instance;
    if (!tts.isKokoroLoaded) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kokoro model not loaded')),
      );
      return;
    }

    // Use a short sample that sounds natural
    const sampleText = 'To be, or not to be, that is the question.';

    try {
      // Temporarily assign this voice for preview
      tts.assignVoice(characterName, 0, voiceId: voiceId, speed: speed);
      await tts.speak(sampleText, character: characterName);
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Preview failed')),
        );
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
