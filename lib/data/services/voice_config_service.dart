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

  /// Get the voice preset for a production.
  ///
  /// If no preset has been explicitly set, defaults based on [locale]:
  /// 'en-GB' → Victorian English, otherwise → Modern American.
  Future<VoicePreset> getPreset(String productionId,
      {String locale = 'en-US'}) async {
    final prefs = await _preferences;
    final presetId = prefs.getString('voice_preset_$productionId');
    if (presetId != null) return VoicePresets.byId(presetId);
    return locale == 'en-GB'
        ? VoicePresets.victorianEnglish
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

  // ── Adjacency-Aware Voice Assignment ─────────────────────

  /// Assign voices to characters so that characters who speak near each
  /// other in the script get different voices.
  ///
  /// Uses graph coloring: builds an adjacency set (characters who speak
  /// within [window] lines of each other), then assigns voices greedily
  /// to minimize collisions.
  static Map<String, String> assignVoicesFromScript({
    required List<ScriptLine> lines,
    required List<ScriptCharacter> characters,
    required List<String> femaleVoices,
    required List<String> maleVoices,
    Map<String, CharacterGender> genderOverrides = const {},
    int window = 3,
  }) {
    if (characters.isEmpty) return {};

    // 1. Build adjacency: which characters speak near each other
    final adjacency = <String, Set<String>>{};
    final dialogueLines = lines
        .where((l) => l.lineType == LineType.dialogue && l.character.isNotEmpty)
        .toList();

    for (var i = 0; i < dialogueLines.length; i++) {
      final a = dialogueLines[i].character;
      adjacency.putIfAbsent(a, () => {});
      // Look at the next [window] speakers
      for (var j = i + 1; j < dialogueLines.length && j <= i + window; j++) {
        final b = dialogueLines[j].character;
        if (a != b) {
          adjacency.putIfAbsent(b, () => {});
          adjacency[a]!.add(b);
          adjacency[b]!.add(a);
        }
      }
    }

    // 2. Order characters by number of neighbors (most constrained first)
    final ordered = characters.toList()
      ..sort((a, b) {
        final na = adjacency[a.name]?.length ?? 0;
        final nb = adjacency[b.name]?.length ?? 0;
        if (na != nb) return nb.compareTo(na); // most neighbors first
        return b.lineCount.compareTo(a.lineCount); // then by prominence
      });

    // 3. Greedy assignment: pick the first voice not used by neighbors
    final assignment = <String, String>{};

    for (final char in ordered) {
      final gender = genderOverrides[char.name] ?? char.gender;
      final pool = gender == CharacterGender.male
          ? maleVoices
          : femaleVoices.isNotEmpty ? femaleVoices : maleVoices;

      if (pool.isEmpty) continue;

      // Voices used by adjacent characters
      final neighborVoices = <String>{};
      for (final neighbor in adjacency[char.name] ?? <String>{}) {
        final v = assignment[neighbor];
        if (v != null) neighborVoices.add(v);
      }

      // Pick first voice not used by a neighbor
      String? chosen;
      for (final voice in pool) {
        if (!neighborVoices.contains(voice)) {
          chosen = voice;
          break;
        }
      }

      // If all voices are taken by neighbors, pick the least-used one
      chosen ??= _leastUsedVoice(pool, assignment.values.toList());
      assignment[char.name] = chosen;
    }

    return assignment;
  }

  static String _leastUsedVoice(List<String> pool, List<String> used) {
    final counts = <String, int>{};
    for (final v in pool) {
      counts[v] = 0;
    }
    for (final v in used) {
      if (counts.containsKey(v)) counts[v] = counts[v]! + 1;
    }
    return counts.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
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

  // ── Per-Character Locale Override ────────────────────────

  /// Get all character locale overrides for a production.
  /// Characters without an override use the production's default locale.
  Future<Map<String, String>> getLocales(String productionId) async {
    final prefs = await _preferences;
    final json = prefs.getString('character_locales_$productionId');
    if (json == null) return {};

    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return map.map((key, value) => MapEntry(key, value as String));
    } catch (e) {
      debugPrint('VoiceConfig: Failed to parse locales: $e');
      return {};
    }
  }

  /// Get the locale for a specific character, or null (use production default).
  Future<String?> getLocale(
      String productionId, String characterName) async {
    final locales = await getLocales(productionId);
    return locales[characterName];
  }

  /// Set a locale override for a specific character.
  Future<void> setLocale(
      String productionId, String characterName, String? locale) async {
    final locales = await getLocales(productionId);
    if (locale == null) {
      locales.remove(characterName);
    } else {
      locales[characterName] = locale;
    }
    final prefs = await _preferences;
    await prefs.setString(
        'character_locales_$productionId', jsonEncode(locales));
  }

  // ── Resolved Voice Assignment ───────────────────────────

  /// Resolve the final voice ID for a character, considering preset + overrides.
  ///
  /// Priority: per-character override > preset pool (round-robin by index).
  /// [locale] is used to pick the right default preset if none is explicitly set.
  Future<String> resolveVoice(
    String productionId,
    String characterName,
    int characterIndex, {
    bool isFemale = true,
    String locale = 'en-US',
  }) async {
    // Check for per-character override first
    final override = await getOverride(productionId, characterName);
    if (override != null) return override.voiceId;

    // Fall back to preset pool (locale-aware default)
    final preset = await getPreset(productionId, locale: locale);
    final pool = isFemale ? preset.femaleVoices : preset.maleVoices;
    final voices = pool.isNotEmpty
        ? pool
        : [...preset.femaleVoices, ...preset.maleVoices];
    if (voices.isEmpty) return 'af_heart';
    return voices[characterIndex % voices.length];
  }

  /// Resolve the speed for a character (override speed or preset default).
  Future<double> resolveSpeed(
      String productionId, String characterName,
      {String locale = 'en-US'}) async {
    final override = await getOverride(productionId, characterName);
    if (override != null) return override.speed;

    final preset = await getPreset(productionId, locale: locale);
    return preset.defaultSpeed;
  }
}
