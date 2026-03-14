import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/script_models.dart';
import '../models/voice_preset.dart';

/// Service for persisting per-production voice presets and per-character
/// voice overrides via SharedPreferences.
///
/// Keys:
///   - `voice_preset_<productionId>` → preset ID string
///   - `voice_overrides_<productionId>` → JSON-encoded map of character overrides
class VoiceConfigService {
  VoiceConfigService._();
  static final instance = VoiceConfigService._();

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _preferences async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  // ── Production Voice Preset ─────────────────────────────

  /// Get the voice preset for a production (defaults to Modern American).
  Future<VoicePreset> getPreset(String productionId) async {
    final prefs = await _preferences;
    final presetId = prefs.getString('voice_preset_$productionId');
    return presetId != null
        ? VoicePresets.byId(presetId)
        : VoicePresets.modernAmerican;
  }

  /// Set the voice preset for a production.
  Future<void> setPreset(String productionId, String presetId) async {
    final prefs = await _preferences;
    await prefs.setString('voice_preset_$productionId', presetId);
    debugPrint('VoiceConfig: Set preset for $productionId → $presetId');
  }

  // ── Per-Character Voice Overrides ───────────────────────

  /// Get all character voice overrides for a production.
  Future<Map<String, CharacterVoiceConfig>> getOverrides(
      String productionId) async {
    final prefs = await _preferences;
    final json = prefs.getString('voice_overrides_$productionId');
    if (json == null) return {};

    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return map.map((key, value) => MapEntry(
            key,
            CharacterVoiceConfig.fromJson(value as Map<String, dynamic>),
          ));
    } catch (e) {
      debugPrint('VoiceConfig: Failed to parse overrides: $e');
      return {};
    }
  }

  /// Get the voice override for a specific character, or null if using preset.
  Future<CharacterVoiceConfig?> getOverride(
      String productionId, String characterName) async {
    final overrides = await getOverrides(productionId);
    return overrides[characterName];
  }

  /// Set a voice override for a specific character.
  Future<void> setOverride(
      String productionId, CharacterVoiceConfig config) async {
    final overrides = await getOverrides(productionId);
    overrides[config.characterName] = config;
    await _saveOverrides(productionId, overrides);
    debugPrint(
        'VoiceConfig: Override ${config.characterName} → ${config.voiceId}');
  }

  /// Remove a character's voice override (revert to preset).
  Future<void> removeOverride(
      String productionId, String characterName) async {
    final overrides = await getOverrides(productionId);
    overrides.remove(characterName);
    await _saveOverrides(productionId, overrides);
  }

  Future<void> _saveOverrides(
      String productionId, Map<String, CharacterVoiceConfig> overrides) async {
    final prefs = await _preferences;
    final json =
        jsonEncode(overrides.map((key, value) => MapEntry(key, value.toJson())));
    await prefs.setString('voice_overrides_$productionId', json);
  }

  // ── Character Gender ──────────────────────────────────────

  /// Get all character genders for a production.
  Future<Map<String, CharacterGender>> getGenders(
      String productionId) async {
    final prefs = await _preferences;
    final json = prefs.getString('character_genders_$productionId');
    if (json == null) return {};

    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return map.map((key, value) => MapEntry(
            key,
            switch (value) {
              'male' => CharacterGender.male,
              'nonGendered' => CharacterGender.nonGendered,
              _ => CharacterGender.female,
            },
          ));
    } catch (e) {
      debugPrint('VoiceConfig: Failed to parse genders: $e');
      return {};
    }
  }

  /// Set the gender for a specific character.
  Future<void> setGender(
      String productionId, String characterName, CharacterGender gender) async {
    final genders = await getGenders(productionId);
    genders[characterName] = gender;
    final prefs = await _preferences;
    final json = jsonEncode(
        genders.map((key, value) => MapEntry(key, value.name)));
    await prefs.setString('character_genders_$productionId', json);
  }

  // ── Resolved Voice Assignment ───────────────────────────

  /// Resolve the final voice ID for a character, considering preset + overrides.
  ///
  /// Priority: per-character override > preset pool (round-robin by index).
  Future<String> resolveVoice(
    String productionId,
    String characterName,
    int characterIndex, {
    bool isFemale = true,
  }) async {
    // Check for per-character override first
    final override = await getOverride(productionId, characterName);
    if (override != null) return override.voiceId;

    // Fall back to preset pool
    final preset = await getPreset(productionId);
    final pool = isFemale ? preset.femaleVoices : preset.maleVoices;
    final voices = pool.isNotEmpty
        ? pool
        : [...preset.femaleVoices, ...preset.maleVoices];
    if (voices.isEmpty) return 'af_heart';
    return voices[characterIndex % voices.length];
  }

  /// Resolve the speed for a character (override speed or preset default).
  Future<double> resolveSpeed(
      String productionId, String characterName) async {
    final override = await getOverride(productionId, characterName);
    if (override != null) return override.speed;

    final preset = await getPreset(productionId);
    return preset.defaultSpeed;
  }
}
