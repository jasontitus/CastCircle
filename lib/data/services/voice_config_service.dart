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

  // Per-production mutation chain: every mutator below is a
  // read-whole-map → modify → write-whole-map over one SharedPreferences
  // blob, so two overlapping calls interleave at the await and the later
  // write silently drops the earlier change (e.g. two overrides set
  // back-to-back from the voice sheet). Chaining serializes them.
  final Map<String, Future<void>> _mutationChains = {};

  Future<T> _serialized<T>(String productionId, Future<T> Function() op) {
    final prev = _mutationChains[productionId] ?? Future<void>.value();
    final run = prev.then((_) => op());
    _mutationChains[productionId] = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  Future<SharedPreferences> get _preferences async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  Future<Map<String, dynamic>?> _loadStoredMap(
    String key,
    String label, {
    required bool rejectCorrupt,
  }) async {
    final prefs = await _preferences;
    final raw = prefs.getString(key);
    if (raw == null) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('stored value is not an object');
      }
      return Map<String, dynamic>.from(decoded);
    } catch (e) {
      debugPrint('VoiceConfig: Failed to parse $label: $e');
      if (rejectCorrupt) {
        throw FormatException(
          'Refusing to overwrite corrupt voice $label',
          raw,
        );
      }
      return null;
    }
  }

  // ── Production Voice Preset ─────────────────────────────

  /// Get the voice preset for a production.
  ///
  /// If no preset has been explicitly set, defaults based on [locale]:
  /// 'en-GB' → Victorian English, otherwise → Modern American.
  Future<VoicePreset> getPreset(
    String productionId, {
    String locale = 'en-US',
  }) async {
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

  /// Get all valid character voice overrides for a production.
  ///
  /// Malformed entries are ignored individually. A wholly corrupt preference
  /// remains readable as an empty map, but mutators reject corruption so they
  /// never overwrite the undecodable raw value with that fallback.
  Future<Map<String, CharacterVoiceConfig>> getOverrides(String productionId) =>
      _loadOverrides(productionId);

  Future<Map<String, CharacterVoiceConfig>> _loadOverrides(
    String productionId, {
    bool rejectCorrupt = false,
  }) async {
    final map = await _loadStoredMap(
      'voice_overrides_$productionId',
      'overrides',
      rejectCorrupt: rejectCorrupt,
    );
    if (map == null) return {};

    final overrides = <String, CharacterVoiceConfig>{};
    for (final entry in map.entries) {
      try {
        final value = entry.value;
        if (value is! Map<String, dynamic>) {
          throw const FormatException('override is not an object');
        }
        overrides[entry.key] = CharacterVoiceConfig.fromJson(value);
      } catch (e) {
        debugPrint(
          'VoiceConfig: Ignoring malformed override "${entry.key}": $e',
        );
      }
    }
    return overrides;
  }

  /// Get the voice override for a specific character, or null if using preset.
  Future<CharacterVoiceConfig?> getOverride(
    String productionId,
    String characterName,
  ) async {
    final overrides = await getOverrides(productionId);
    return overrides[characterName];
  }

  /// Set a voice override for a specific character.
  Future<void> setOverride(String productionId, CharacterVoiceConfig config) =>
      _serialized(productionId, () async {
        final overrides = await _loadOverrides(
          productionId,
          rejectCorrupt: true,
        );
        overrides[config.characterName] = config;
        await _saveOverrides(productionId, overrides);
        debugPrint(
          'VoiceConfig: Override ${config.characterName} → ${config.voiceId}',
        );
      });

  /// Remove a character's voice override (revert to preset).
  Future<void> removeOverride(String productionId, String characterName) =>
      _serialized(productionId, () async {
        final overrides = await _loadOverrides(
          productionId,
          rejectCorrupt: true,
        );
        overrides.remove(characterName);
        await _saveOverrides(productionId, overrides);
      });

  Future<void> _saveOverrides(
    String productionId,
    Map<String, CharacterVoiceConfig> overrides,
  ) async {
    final prefs = await _preferences;
    final json = jsonEncode(
      overrides.map((key, value) => MapEntry(key, value.toJson())),
    );
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

    // 1. Build adjacency: which characters speak near each other.
    // For multi-character lines, use individual characters for adjacency.
    final adjacency = <String, Set<String>>{};
    final dialogueLines = lines
        .where((l) => l.lineType == LineType.dialogue && l.character.isNotEmpty)
        .toList();

    List<String> _charsForLine(ScriptLine l) =>
        l.multiCharacters.isNotEmpty ? l.multiCharacters : [l.character];

    for (var i = 0; i < dialogueLines.length; i++) {
      final aChars = _charsForLine(dialogueLines[i]);
      for (final a in aChars) {
        adjacency.putIfAbsent(a, () => {});
      }
      // Look at the next [window] speakers
      for (var j = i + 1; j < dialogueLines.length && j <= i + window; j++) {
        final bChars = _charsForLine(dialogueLines[j]);
        for (final a in aChars) {
          for (final b in bChars) {
            if (a != b) {
              adjacency.putIfAbsent(b, () => {});
              adjacency[a]!.add(b);
              adjacency[b]!.add(a);
            }
          }
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
          : femaleVoices.isNotEmpty
          ? femaleVoices
          : maleVoices;

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

  /// Get all valid character genders for a production.
  Future<Map<String, CharacterGender>> getGenders(String productionId) =>
      _loadGenders(productionId);

  Future<Map<String, CharacterGender>> _loadGenders(
    String productionId, {
    bool rejectCorrupt = false,
  }) async {
    final map = await _loadStoredMap(
      'character_genders_$productionId',
      'genders',
      rejectCorrupt: rejectCorrupt,
    );
    if (map == null) return {};

    final genders = <String, CharacterGender>{};
    for (final entry in map.entries) {
      final gender = switch (entry.value) {
        'female' => CharacterGender.female,
        'male' => CharacterGender.male,
        'nonGendered' => CharacterGender.nonGendered,
        _ => null,
      };
      if (gender == null) {
        debugPrint(
          'VoiceConfig: Ignoring malformed gender "${entry.key}": ${entry.value}',
        );
      } else {
        genders[entry.key] = gender;
      }
    }
    return genders;
  }

  /// Set the gender for a specific character.
  Future<void> setGender(
    String productionId,
    String characterName,
    CharacterGender gender,
  ) => _serialized(productionId, () async {
    final genders = await _loadGenders(productionId, rejectCorrupt: true);
    genders[characterName] = gender;
    await _saveGenders(productionId, genders);
  });

  Future<void> _saveGenders(
    String productionId,
    Map<String, CharacterGender> genders,
  ) async {
    final prefs = await _preferences;
    final json = jsonEncode(
      genders.map((key, value) => MapEntry(key, value.name)),
    );
    await prefs.setString('character_genders_$productionId', json);
  }

  // ── Per-Character Locale Override ────────────────────────

  /// Get all valid character locale overrides for a production.
  /// Characters without an override use the production's default locale.
  Future<Map<String, String>> getLocales(String productionId) =>
      _loadLocales(productionId);

  Future<Map<String, String>> _loadLocales(
    String productionId, {
    bool rejectCorrupt = false,
  }) async {
    final map = await _loadStoredMap(
      'character_locales_$productionId',
      'locales',
      rejectCorrupt: rejectCorrupt,
    );
    if (map == null) return {};

    final locales = <String, String>{};
    for (final entry in map.entries) {
      final value = entry.value;
      if (value is String) {
        locales[entry.key] = value;
      } else {
        debugPrint(
          'VoiceConfig: Ignoring malformed locale "${entry.key}": $value',
        );
      }
    }
    return locales;
  }

  /// Get the locale for a specific character, or null (use production default).
  Future<String?> getLocale(String productionId, String characterName) async {
    final locales = await getLocales(productionId);
    return locales[characterName];
  }

  /// Set a locale override for a specific character.
  Future<void> setLocale(
    String productionId,
    String characterName,
    String? locale,
  ) => _serialized(productionId, () async {
    final locales = await _loadLocales(productionId, rejectCorrupt: true);
    if (locale == null) {
      locales.remove(characterName);
    } else {
      locales[characterName] = locale;
    }
    await _saveLocales(productionId, locales);
  });

  Future<void> _saveLocales(
    String productionId,
    Map<String, String> locales,
  ) async {
    final prefs = await _preferences;
    await prefs.setString(
      'character_locales_$productionId',
      jsonEncode(locales),
    );
  }

  /// Remove every persisted setting keyed by [characterName].
  ///
  /// All preference families are decoded before any write so a corrupt blob
  /// cannot cause partial cleanup or be overwritten with an empty fallback.
  Future<void> removeCharacterSettings(
    String productionId,
    String characterName,
  ) => _serialized(productionId, () async {
    final overrides = await _loadOverrides(productionId, rejectCorrupt: true);
    final genders = await _loadGenders(productionId, rejectCorrupt: true);
    final locales = await _loadLocales(productionId, rejectCorrupt: true);

    overrides.remove(characterName);
    genders.remove(characterName);
    locales.remove(characterName);

    await _saveOverrides(productionId, overrides);
    await _saveGenders(productionId, genders);
    await _saveLocales(productionId, locales);
  });

  // ── Character Rename / Merge ─────────────────────────────

  /// Re-key every per-character setting from [oldName] to [newName].
  ///
  /// Overrides, genders and locales are all keyed by character NAME, so a
  /// rename that only rewrites the script strands them on a name the script
  /// no longer contains — the custom voice disappears and the gender silently
  /// falls back to the default. An entry already stored under [newName] wins:
  /// a merge folds a character into a real one whose settings must survive.
  Future<void> renameCharacter(
    String productionId,
    String oldName,
    String newName,
  ) async {
    if (oldName == newName) return;
    await _serialized(
      productionId,
      () => _renameLoaded(productionId, oldName, newName),
    );
  }

  Future<void> _renameLoaded(
    String productionId,
    String oldName,
    String newName,
  ) async {
    // Decode every family before writing any of them. If one raw preference is
    // corrupt, reject the whole rename rather than partially re-key settings or
    // overwrite the corrupt blob with an empty fallback.
    final overrides = await _loadOverrides(productionId, rejectCorrupt: true);
    final genders = await _loadGenders(productionId, rejectCorrupt: true);
    final locales = await _loadLocales(productionId, rejectCorrupt: true);

    final movedOverride = overrides.remove(oldName);
    if (movedOverride != null && !overrides.containsKey(newName)) {
      overrides[newName] = CharacterVoiceConfig(
        characterName: newName,
        voiceId: movedOverride.voiceId,
        speed: movedOverride.speed,
      );
    }

    final movedGender = genders.remove(oldName);
    if (movedGender != null) genders.putIfAbsent(newName, () => movedGender);

    final movedLocale = locales.remove(oldName);
    if (movedLocale != null) locales.putIfAbsent(newName, () => movedLocale);

    await _saveOverrides(productionId, overrides);
    await _saveGenders(productionId, genders);
    await _saveLocales(productionId, locales);

    debugPrint('VoiceConfig: Re-keyed "$oldName" → "$newName"');
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
    String productionId,
    String characterName, {
    String locale = 'en-US',
  }) async {
    final override = await getOverride(productionId, characterName);
    if (override != null) return override.speed;

    final preset = await getPreset(productionId, locale: locale);
    return preset.defaultSpeed;
  }
}
