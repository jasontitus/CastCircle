import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/production_models.dart';
import '../data/models/script_models.dart';
import '../data/services/script_import_service.dart';

/// The list of productions the user has.
final productionsProvider =
    StateNotifierProvider<ProductionsNotifier, List<Production>>((ref) {
  return ProductionsNotifier();
});

class ProductionsNotifier extends StateNotifier<List<Production>> {
  ProductionsNotifier() : super([]);

  void add(Production production) {
    state = [...state, production];
  }

  void update(Production production) {
    state = [
      for (final p in state)
        if (p.id == production.id) production else p,
    ];
  }

  void remove(String id) {
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
  return RecordingsNotifier();
});

class RecordingsNotifier extends StateNotifier<Map<String, Recording>> {
  RecordingsNotifier() : super({});

  void add(Recording recording) {
    state = {...state, recording.scriptLineId: recording};
  }

  void remove(String scriptLineId) {
    state = Map.from(state)..remove(scriptLineId);
  }

  void clear() {
    state = {};
  }
}

/// Character being recorded in the recording studio.
final recordingCharacterProvider = StateProvider<String?>((ref) => null);
