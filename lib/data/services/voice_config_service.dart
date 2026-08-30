import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/script_models.dart';
import '../models/voice_preset.dart';
import 'debug_log_service.dart';

class VoiceOverridesCorruptException implements Exception {
  const VoiceOverridesCorruptException();

  @override
  String toString() =>
      'Voice overrides could not be read. The original settings were preserved.';
}

class PendingVoiceCloudSync {
  const PendingVoiceCloudSync({required this.presetId, this.locale});

  final String presetId;
  final String? locale;
}

/// Service for persisting per-production voice presets and per-character
/// voice overrides via SharedPreferences.
///
/// Keys:
///   - `voice_preset_<productionId>` → preset ID string
///   - `voice_overrides_<productionId>` → versioned JSON override envelope
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

  Future<void> _storeString(
    SharedPreferences prefs,
    String key,
    String value,
  ) async {
    if (!await prefs.setString(key, value)) {
      throw StateError('Voice settings storage rejected a write');
    }
  }

  Future<void> _removeKey(SharedPreferences prefs, String key) async {
    if (!await prefs.remove(key)) {
      throw StateError('Voice settings storage rejected a removal');
    }
  }

  @visibleForTesting
  void resetForTesting() {
    _prefs = null;
    _mutationChains.clear();
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
    await _storeString(prefs, 'voice_preset_$productionId', presetId);
    debugPrint('VoiceConfig: voice preset saved');
  }

  Future<void> markVoiceCloudSyncPending(
    String productionId, {
    required String presetId,
    String? locale,
  }) => _serialized(productionId, () async {
    final prefs = await _preferences;
    await _storeString(
      prefs,
      'voice_cloud_sync_pending_$productionId',
      jsonEncode({
        'version': 1,
        'presetId': presetId,
        if (locale != null) 'locale': locale,
      }),
    );
  });

  Future<PendingVoiceCloudSync?> getPendingVoiceCloudSync(
    String productionId,
  ) async {
    final prefs = await _preferences;
    final encoded = prefs.getString('voice_cloud_sync_pending_$productionId');
    if (encoded == null) return null;
    final decoded = jsonDecode(encoded);
    if (decoded is! Map<String, dynamic> ||
        decoded['version'] != 1 ||
        decoded['presetId'] is! String ||
        (decoded['locale'] != null && decoded['locale'] is! String)) {
      throw const FormatException('invalid pending voice sync record');
    }
    return PendingVoiceCloudSync(
      presetId: decoded['presetId'] as String,
      locale: decoded['locale'] as String?,
    );
  }

  Future<bool> clearPendingVoiceCloudSyncIfMatches(
    String productionId, {
    required String presetId,
    String? locale,
  }) => _serialized(productionId, () async {
    final pending = await getPendingVoiceCloudSync(productionId);
    if (pending == null ||
        pending.presetId != presetId ||
        pending.locale != locale) {
      return false;
    }
    final prefs = await _preferences;
    await _removeKey(prefs, 'voice_cloud_sync_pending_$productionId');
    return true;
  });

  // ── Per-Character Voice Overrides ───────────────────────

  /// Get all character voice overrides for a production.
  ///
  /// The original blob is retained and copied to a quarantine key when it
  /// cannot be decoded. Callers must surface [VoiceOverridesCorruptException];
  /// returning an empty map here would let the next edit erase recoverable
  /// settings.
  Future<Map<String, CharacterVoiceConfig>> getOverrides(
    String productionId,
  ) async {
    final prefs = await _preferences;
    final key = 'voice_overrides_$productionId';
    final encoded = prefs.getString(key);
    if (encoded == null) return {};

    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('override root is not an object');
      }

      Map<String, dynamic> values;
      final isVersionedEnvelope = decoded['version'] is int;
      if (isVersionedEnvelope) {
        if (decoded['version'] != 1 ||
            decoded['overrides'] is! Map<String, dynamic>) {
          throw const FormatException('unsupported override format');
        }
        values = decoded['overrides'] as Map<String, dynamic>;
      } else {
        // Version 0 was the original direct character-name → config map.
        // It remains readable and is migrated to v1 on the next mutation.
        values = decoded;
      }

      return values.map((key, value) {
        if (value is! Map<String, dynamic>) {
          throw const FormatException('override entry is not an object');
        }
        return MapEntry(key, CharacterVoiceConfig.fromJson(value));
      });
    } catch (error, stack) {
      try {
        await _storeString(
          prefs,
          'voice_overrides_quarantine_$productionId',
          encoded,
        );
      } catch (quarantineError, quarantineStack) {
        DebugLogService.instance.logError(
          LogCategory.general,
          'Voice override quarantine write failed',
          quarantineError,
          quarantineStack,
        );
      }
      DebugLogService.instance.logError(
        LogCategory.general,
        'Voice overrides quarantined after decode failure',
        error,
        stack,
      );
      throw const VoiceOverridesCorruptException();
    }
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
        final overrides = await getOverrides(productionId);
        overrides[config.characterName] = config;
        await _saveOverrides(productionId, overrides);
        debugPrint('VoiceConfig: character override saved');
      });

  /// Remove a character's voice override (revert to preset).
  Future<void> removeOverride(String productionId, String characterName) =>
      _serialized(productionId, () async {
        final overrides = await getOverrides(productionId);
        overrides.remove(characterName);
        await _saveOverrides(productionId, overrides);
      });

  Future<void> _saveOverrides(
    String productionId,
    Map<String, CharacterVoiceConfig> overrides,
  ) async {
    final prefs = await _preferences;
    final encoded = jsonEncode({
      'version': 1,
      'overrides': overrides.map((key, value) => MapEntry(key, value.toJson())),
    });
    await _storeString(prefs, 'voice_overrides_$productionId', encoded);
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

  /// Get all character genders for a production.
  Future<Map<String, CharacterGender>> getGenders(String productionId) async {
    final prefs = await _preferences;
    final json = prefs.getString('character_genders_$productionId');
    if (json == null) return {};

    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return map.map(
        (key, value) => MapEntry(key, switch (value) {
          'male' => CharacterGender.male,
          'nonGendered' => CharacterGender.nonGendered,
          _ => CharacterGender.female,
        }),
      );
    } catch (e) {
      DebugLogService.instance.logError(
        LogCategory.general,
        'Voice gender settings decode failed type=${e.runtimeType}',
      );
      return {};
    }
  }

  /// Set the gender for a specific character.
  Future<void> setGender(
    String productionId,
    String characterName,
    CharacterGender gender,
  ) => _serialized(productionId, () async {
    final genders = await getGenders(productionId);
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
    await _storeString(prefs, 'character_genders_$productionId', json);
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
      DebugLogService.instance.logError(
        LogCategory.general,
        'Voice locale settings decode failed type=${e.runtimeType}',
      );
      return {};
    }
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
    final locales = await getLocales(productionId);
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
    await _storeString(
      prefs,
      'character_locales_$productionId',
      jsonEncode(locales),
    );
  }

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
    final overrides = await getOverrides(productionId);
    final movedOverride = overrides.remove(oldName);
    if (movedOverride != null && !overrides.containsKey(newName)) {
      overrides[newName] = CharacterVoiceConfig(
        characterName: newName,
        voiceId: movedOverride.voiceId,
        speed: movedOverride.speed,
      );
    }
    await _saveOverrides(productionId, overrides);

    final genders = await getGenders(productionId);
    final movedGender = genders.remove(oldName);
    if (movedGender != null) genders.putIfAbsent(newName, () => movedGender);
    await _saveGenders(productionId, genders);

    final locales = await getLocales(productionId);
    final movedLocale = locales.remove(oldName);
    if (movedLocale != null) locales.putIfAbsent(newName, () => movedLocale);
    await _saveLocales(productionId, locales);

    debugPrint('VoiceConfig: character settings re-keyed');
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
