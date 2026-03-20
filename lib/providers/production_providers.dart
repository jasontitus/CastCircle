import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../data/models/cast_member_model.dart';
import '../data/models/production_models.dart';
import '../data/models/script_models.dart';
import '../data/repositories/production_repository.dart';
import '../data/services/debug_log_service.dart';
import '../data/services/deep_link_service.dart';
import '../data/services/script_import_service.dart';
import '../data/services/script_parser.dart';
import '../data/services/voice_config_service.dart';
import '../data/services/analytics_service.dart';
import '../data/services/perf_service.dart';
import '../data/services/supabase_service.dart';
import '../main.dart';

/// Maximum size (in bytes) for a SharedPreferences script backup.
const _maxBackupBytes = 5 * 1024 * 1024; // 5 MB

/// Pending join data from a deep link. Consumed by the join screen.
final pendingJoinProvider = StateProvider<PendingJoin?>((ref) => null);

/// Provider for the character the user is rehearsing as.
final rehearsalCharacterProvider = StateProvider<String?>((ref) => null);

/// Provider for the selected scene to rehearse.
final selectedSceneProvider = StateProvider<ScriptScene?>((ref) => null);

/// Rehearsal mode: full scene readthrough vs cue-response practice vs full readthrough.
enum RehearsalMode { sceneReadthrough, cuePractice, readthrough }

final rehearsalModeProvider =
    StateProvider<RehearsalMode>((ref) => RehearsalMode.sceneReadthrough);

/// When true, the actor's upcoming lines are hidden (blind rehearsal).
final hideMyLinesProvider = StateProvider<bool>((ref) => false);

/// Repository provider — bridges Drift DB with domain models.
final productionRepositoryProvider = Provider<ProductionRepository>((ref) {
  final db = ref.read(databaseProvider);
  return ProductionRepository(db);
});

/// The list of productions the user has.
final productionsProvider =
    StateNotifierProvider<ProductionsNotifier, List<Production>>((ref) {
  final repo = ref.read(productionRepositoryProvider);
  return ProductionsNotifier(repo);
});

class ProductionsNotifier extends StateNotifier<List<Production>> {
  final ProductionRepository _repo;

  ProductionsNotifier(this._repo) : super([]) {
    _load();
  }

  Future<void> _load() async {
    state = await _repo.getAllProductions();
  }

  Future<void> add(Production production) async {
    await _repo.saveProduction(production);
    state = [...state, production];
  }

  Future<void> update(Production production) async {
    await _repo.saveProduction(production);
    state = [
      for (final p in state)
        if (p.id == production.id) production else p,
    ];
  }

  Future<void> remove(String id) async {
    await _repo.deleteProduction(id);
    state = state.where((p) => p.id != id).toList();
  }
}

/// Currently selected production.
final currentProductionProvider = StateProvider<Production?>((ref) => null);

/// Parsed script for the current production.
final currentScriptProvider = StateProvider<ParsedScript?>((ref) => null);

/// Script import service.
final scriptImportServiceProvider = Provider<ScriptImportService>((ref) {
  return ScriptImportService();
});

/// All recordings for the current production, keyed by script line ID.
final recordingsProvider =
    StateNotifierProvider<RecordingsNotifier, Map<String, Recording>>((ref) {
  final repo = ref.read(productionRepositoryProvider);
  return RecordingsNotifier(repo);
});

class RecordingsNotifier extends StateNotifier<Map<String, Recording>> {
  final ProductionRepository _repo;
  String? _productionId;

  RecordingsNotifier(this._repo) : super({});

  /// Load recordings for a given production from the database.
  Future<void> loadForProduction(String productionId) async {
    _productionId = productionId;
    state = await _repo.getRecordings(productionId);
  }

  Future<void> add(Recording recording) async {
    if (_productionId != null) {
      await _repo.saveRecording(_productionId!, recording);
    }
    state = {...state, recording.scriptLineId: recording};
  }

  Future<void> remove(String scriptLineId) async {
    final recording = state[scriptLineId];
    if (recording != null) {
      await _repo.deleteRecording(recording.id);
    }
    state = Map.from(state)..remove(scriptLineId);
  }

  /// Load recordings from a pre-built map (e.g. from recording sync cache).
  void loadFromMap(Map<String, Recording> recordings) {
    state = {...state, ...recordings};
  }

  void clear() {
    _productionId = null;
    state = {};
  }
}

/// Understudy recordings for the current production, keyed by script line ID.
/// These are recordings made by understudies and can be used as fallback
/// when the primary actor hasn't recorded a line.
final understudyRecordingsProvider =
    StateNotifierProvider<RecordingsNotifier, Map<String, Recording>>((ref) {
  final repo = ref.read(productionRepositoryProvider);
  return RecordingsNotifier(repo);
});

/// Character being recorded in the recording studio.
final recordingCharacterProvider = StateProvider<String?>((ref) => null);

/// Cast members for the current production, backed by Drift + Supabase sync.
final castMembersProvider =
    StateNotifierProvider<CastMembersNotifier, List<CastMemberModel>>((ref) {
  final repo = ref.read(productionRepositoryProvider);
  return CastMembersNotifier(repo);
});

class CastMembersNotifier extends StateNotifier<List<CastMemberModel>> {
  final ProductionRepository _repo;
  String? _productionId;

  CastMembersNotifier(this._repo) : super([]);

  /// Load cast members from Drift for the given production.
  Future<void> loadForProduction(String productionId) async {
    _productionId = productionId;
    state = await _repo.getCastMembers(productionId);
  }

  /// Add or update a cast member in Drift and state.
  Future<void> save(CastMemberModel member) async {
    await _repo.saveCastMember(member);
    final idx = state.indexWhere((m) => m.id == member.id);
    if (idx >= 0) {
      state = [
        for (int i = 0; i < state.length; i++)
          if (i == idx) member else state[i],
      ];
    } else {
      state = [...state, member];
    }
  }

  /// Remove a cast member.
  Future<void> remove(String id) async {
    await _repo.deleteCastMember(id);
    state = state.where((m) => m.id != id).toList();
  }

  /// Get the primary actor for a character.
  CastMemberModel? primaryFor(String characterName) {
    try {
      return state.firstWhere(
        (m) => m.characterName == characterName && m.role == CastRole.primary,
      );
    } catch (_) {
      return null;
    }
  }

  /// Get the understudy for a character.
  CastMemberModel? understudyFor(String characterName) {
    try {
      return state.firstWhere(
        (m) =>
            m.characterName == characterName && m.role == CastRole.understudy,
      );
    } catch (_) {
      return null;
    }
  }

  void clear() {
    _productionId = null;
    state = [];
  }
}

/// Persist the current script to the local database, SharedPreferences backup,
/// and push to cloud. Three layers: Drift DB -> SharedPreferences -> Supabase.
/// Call after updating currentScriptProvider when you want changes saved.
Future<void> persistScript(WidgetRef ref) async {
  final trace = PerfService.instance.startTrace('persist_script');
  final script = ref.read(currentScriptProvider);
  final production = ref.read(currentProductionProvider);
  if (script == null || production == null) { trace?.stop(); return; }

  final repo = ref.read(productionRepositoryProvider);
  await repo.saveScriptLines(production.id, script.lines);
  await repo.saveScenes(production.id, script.scenes);

  // Save a JSON backup to SharedPreferences as a second local copy
  try {
    final jsonList = script.lines.map((l) => l.toJson()).toList();
    final jsonString = jsonEncode(jsonList);
    if (jsonString.length <= _maxBackupBytes) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('script_backup_${production.id}', jsonString);
      DebugLogService.instance.log(
        LogCategory.general,
        'Script backup saved to SharedPreferences for ${production.id} '
        '(${script.lines.length} lines, ${jsonString.length} bytes)',
      );
    } else {
      DebugLogService.instance.log(
        LogCategory.general,
        'Script backup skipped — JSON too large '
        '(${jsonString.length} bytes > $_maxBackupBytes)',
      );
    }
  } catch (e) {
    DebugLogService.instance.logError(
      LogCategory.error,
      'SharedPreferences script backup failed',
      e,
    );
    // Non-fatal — Drift save already succeeded
  }

  // Also push to cloud so other cast members can download it
  try {
    await pushScriptToCloud(ref);
    AnalyticsService.instance.logCloudSynced(direction: 'push');
  } catch (e) {
    debugPrint('Cloud sync after persist failed: $e');
    // Non-fatal — local save succeeded
  }
  trace?.stop();
}

/// Fetch cloud script lines for a production. Returns null if Supabase
/// is not initialized or no lines exist in the cloud.
Future<List<ScriptLine>?> fetchCloudScriptLines(String productionId) async {
  final supa = SupabaseService.instance;
  if (!supa.isInitialized || !supa.isSignedIn) return null;

  try {
    final rows = await supa.fetchScriptLines(productionId);
    if (rows.isEmpty) return null;

    return rows.map((row) => ScriptLine(
      id: row['id'] as String,
      act: row['act'] as String? ?? '',
      scene: row['scene'] as String? ?? '',
      lineNumber: row['line_number'] as int? ?? 0,
      orderIndex: row['order_index'] as int? ?? 0,
      character: row['character'] as String? ?? '',
      text: row['line_text'] as String? ?? '',
      lineType: LineType.values.byName(row['line_type'] as String? ?? 'dialogue'),
      stageDirection: row['stage_direction'] as String? ?? '',
    )).toList();
  } catch (e) {
    debugPrint('Cloud sync fetch failed: $e');
    return null;
  }
}

/// Push the current script to the cloud.
Future<void> pushScriptToCloud(WidgetRef ref) async {
  final script = ref.read(currentScriptProvider);
  final production = ref.read(currentProductionProvider);
  final supa = SupabaseService.instance;
  if (script == null || production == null) return;
  if (!supa.isInitialized || !supa.isSignedIn) return;

  try {
    final rows = script.lines.asMap().entries.map((e) => {
      'production_id': production.id,
      'order_index': e.key,
      'act': e.value.act,
      'scene': e.value.scene,
      'line_number': e.value.lineNumber,
      'character': e.value.character,
      'line_text': e.value.text,
      'line_type': e.value.lineType.name,
      'stage_direction': e.value.stageDirection,
    }).toList();

    await supa.saveScriptLines(
      productionId: production.id,
      lines: rows,
    );
  } catch (e) {
    debugPrint('Cloud sync push failed: $e');
    rethrow;
  }
}

/// Build a ParsedScript from a list of ScriptLine objects.
/// Reconstructs scenes from the scene tags already on each line.
ParsedScript buildParsedScript(String title, List<ScriptLine> lines) {
  final charCounts = <String, int>{};
  for (final line in lines) {
    if (line.lineType == LineType.dialogue && line.character.isNotEmpty) {
      if (line.multiCharacters.isNotEmpty) {
        for (final char in line.multiCharacters) {
          charCounts[char] = (charCounts[char] ?? 0) + 1;
        }
      } else {
        charCounts[line.character] = (charCounts[line.character] ?? 0) + 1;
      }
    }
  }
  final characters = charCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final scriptCharacters = characters.asMap().entries.map((e) => ScriptCharacter(
    name: e.value.key,
    colorIndex: e.key,
    lineCount: e.value.value,
    gender: ScriptParser.inferGender(e.value.key),
  )).toList();

  // Rebuild scenes from line scene/act tags
  final scenes = _buildScenesFromLines(lines);

  return ParsedScript(
    title: title,
    lines: lines,
    characters: scriptCharacters,
    scenes: scenes,
    rawText: '',
  );
}

/// Reconstruct ScriptScene objects by grouping consecutive lines
/// that share the same act+scene tag.
List<ScriptScene> _buildScenesFromLines(List<ScriptLine> lines) {
  if (lines.isEmpty) return [];

  final scenes = <ScriptScene>[];
  var sceneStart = 0;
  var currentKey = '${lines.first.act}|${lines.first.scene}';
  var sceneCounter = 0;

  void closeScene(int endIndex) {
    final sceneLines = lines.sublist(sceneStart, endIndex + 1);
    final dialogueLines =
        sceneLines.where((l) => l.lineType == LineType.dialogue).toList();
    if (dialogueLines.isEmpty) {
      sceneStart = endIndex + 1;
      return;
    }

    sceneCounter++;
    final chars = <String>{};
    for (final l in dialogueLines) {
      if (l.multiCharacters.isNotEmpty) {
        chars.addAll(l.multiCharacters);
      } else if (l.character.isNotEmpty) {
        chars.add(l.character);
      }
    }

    final act = sceneLines.first.act;
    final scene = sceneLines.first.scene;
    final sceneName = scene.isNotEmpty
        ? '$act, $scene'
        : '$act, Scene $sceneCounter';

    scenes.add(ScriptScene(
      id: const Uuid().v4(),
      act: act,
      sceneName: sceneName,
      location: scene,
      description: '',
      startLineIndex: sceneStart,
      endLineIndex: endIndex,
      characters: chars.toList()..sort(),
    ));

    sceneStart = endIndex + 1;
  }

  for (var i = 1; i < lines.length; i++) {
    final key = '${lines[i].act}|${lines[i].scene}';
    if (key != currentKey) {
      closeScene(i - 1);
      currentKey = key;
    }
  }
  closeScene(lines.length - 1);

  return scenes;
}

/// Load a saved script from the database for the given production.
/// Falls back to SharedPreferences backup if the Drift DB returns empty.
/// (Cloud fallback is handled by the join flow, not here.)
Future<ParsedScript?> loadPersistedScript(WidgetRef ref, String productionId) async {
  final repo = ref.read(productionRepositoryProvider);
  var lines = await repo.getScriptLines(productionId);
  final scenes = await repo.getScenes(productionId);

  // If Drift DB returned no lines, try recovering from SharedPreferences backup
  if (lines.isEmpty) {
    try {
      final prefs = await SharedPreferences.getInstance();
      final backupJson = prefs.getString('script_backup_$productionId');
      if (backupJson != null && backupJson.isNotEmpty) {
        final jsonList = jsonDecode(backupJson) as List<dynamic>;
        lines = jsonList
            .map((e) => ScriptLine.fromJson(e as Map<String, dynamic>))
            .toList();

        DebugLogService.instance.log(
          LogCategory.error,
          'WARNING: Drift DB empty for $productionId — '
          'recovered ${lines.length} lines from SharedPreferences backup',
        );

        // Re-persist recovered lines back to Drift so future loads are normal
        if (lines.isNotEmpty) {
          await repo.saveScriptLines(productionId, lines);
          DebugLogService.instance.log(
            LogCategory.general,
            'Re-persisted ${lines.length} recovered lines back to Drift DB',
          );
        }
      }
    } catch (e) {
      DebugLogService.instance.logError(
        LogCategory.error,
        'SharedPreferences backup recovery failed for $productionId',
        e,
      );
    }
  }

  if (lines.isEmpty) return null;

  // Rebuild characters from dialogue lines.
  // Multi-character lines credit each individual character.
  final charCounts = <String, int>{};
  for (final line in lines) {
    if (line.lineType == LineType.dialogue && line.character.isNotEmpty) {
      if (line.multiCharacters.isNotEmpty) {
        for (final char in line.multiCharacters) {
          charCounts[char] = (charCounts[char] ?? 0) + 1;
        }
      } else {
        charCounts[line.character] = (charCounts[line.character] ?? 0) + 1;
      }
    }
  }
  final characters = charCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  // Load saved genders
  final savedGenders =
      await VoiceConfigService.instance.getGenders(productionId);

  final scriptCharacters = characters.asMap().entries.map((e) => ScriptCharacter(
        name: e.value.key,
        colorIndex: e.key,
        lineCount: e.value.value,
        gender: savedGenders[e.value.key] ?? ScriptParser.inferGender(e.value.key),
      )).toList();

  // If no scenes were persisted, rebuild from line tags
  final effectiveScenes = scenes.isNotEmpty ? scenes : _buildScenesFromLines(lines);

  return ParsedScript(
    title: '', // Title comes from production
    lines: lines,
    characters: scriptCharacters,
    scenes: effectiveScenes,
    rawText: '',
  );
}
