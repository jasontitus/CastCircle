import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/production_models.dart';
import '../data/models/script_models.dart';
import '../data/repositories/production_repository.dart';
import '../data/services/script_import_service.dart';
import '../data/services/voice_config_service.dart';
import '../main.dart';

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

/// Persist the current script to the database. Call after updating
/// currentScriptProvider when you want changes saved.
Future<void> persistScript(WidgetRef ref) async {
  final script = ref.read(currentScriptProvider);
  final production = ref.read(currentProductionProvider);
  if (script == null || production == null) return;

  final repo = ref.read(productionRepositoryProvider);
  await repo.saveScriptLines(production.id, script.lines);
  await repo.saveScenes(production.id, script.scenes);
}

/// Load a saved script from the database for the given production.
Future<ParsedScript?> loadPersistedScript(WidgetRef ref, String productionId) async {
  final repo = ref.read(productionRepositoryProvider);
  final lines = await repo.getScriptLines(productionId);
  final scenes = await repo.getScenes(productionId);

  if (lines.isEmpty) return null;

  // Rebuild characters from dialogue lines
  final charCounts = <String, int>{};
  for (final line in lines) {
    if (line.lineType == LineType.dialogue && line.character.isNotEmpty) {
      charCounts[line.character] = (charCounts[line.character] ?? 0) + 1;
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
        gender: savedGenders[e.value.key] ?? CharacterGender.female,
      )).toList();

  return ParsedScript(
    title: '', // Title comes from production
    lines: lines,
    characters: scriptCharacters,
    scenes: scenes,
    rawText: '',
  );
}
