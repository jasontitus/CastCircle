import 'package:drift/drift.dart';

import '../database/app_database.dart';
import '../models/production_models.dart' as models;
import '../models/script_models.dart' as models;

/// Repository bridging the Drift database with app-level model objects.
/// Handles conversions between Drift table rows and domain models.
class ProductionRepository {
  final AppDatabase _db;

  ProductionRepository(this._db);

  // ── Productions ─────────────────────────────────────

  Future<List<models.Production>> getAllProductions() async {
    final rows = await _db.getAllProductions();
    return rows.map(_productionFromRow).toList();
  }

  Stream<List<models.Production>> watchAllProductions() {
    return _db.watchAllProductions().map(
        (rows) => rows.map(_productionFromRow).toList());
  }

  Future<void> saveProduction(models.Production production) async {
    await _db.insertProduction(ProductionsCompanion(
      id: Value(production.id),
      title: Value(production.title),
      organizerId: Value(production.organizerId),
      status: Value(production.status.name),
      scriptPath: Value(production.scriptPath),
      locale: Value(production.locale),
      createdAt: Value(production.createdAt),
    ));
  }

  Future<void> deleteProduction(String id) async {
    // Cascade: delete related data first
    await _db.deleteScriptLinesForProduction(id);
    await _db.deleteScenesForProduction(id);
    await _db.deleteCastForProduction(id);
    await _db.deleteProduction(id);
  }

  models.Production _productionFromRow(Production row) {
    return models.Production(
      id: row.id,
      title: row.title,
      organizerId: row.organizerId ?? '',
      status: models.ProductionStatus.values.byName(row.status),
      scriptPath: row.scriptPath,
      locale: row.locale,
      createdAt: row.createdAt,
    );
  }

  // ── Script Lines ────────────────────────────────────

  Future<List<models.ScriptLine>> getScriptLines(String productionId) async {
    final rows = await _db.getScriptLines(productionId);
    return rows.map(_scriptLineFromRow).toList();
  }

  Future<void> saveScriptLines(
      String productionId, List<models.ScriptLine> lines) async {
    await _db.deleteScriptLinesForProduction(productionId);
    final companions = lines.map((l) => ScriptLinesCompanion(
          id: Value(l.id),
          productionId: Value(productionId),
          act: Value(l.act),
          scene: Value(l.scene),
          lineNumber: Value(l.lineNumber),
          orderIndex: Value(l.orderIndex),
          character: Value(l.character),
          lineText: Value(l.text),
          lineType: Value(l.lineType.name),
          stageDirection: Value(l.stageDirection),
        )).toList();
    await _db.insertScriptLines(companions);
  }

  models.ScriptLine _scriptLineFromRow(ScriptLine row) {
    return models.ScriptLine(
      id: row.id,
      act: row.act,
      scene: row.scene,
      lineNumber: row.lineNumber,
      orderIndex: row.orderIndex,
      character: row.character,
      text: row.lineText,
      lineType: models.LineType.values.byName(row.lineType),
      stageDirection: row.stageDirection,
    );
  }

  // ── Scenes ──────────────────────────────────────────

  Future<List<models.ScriptScene>> getScenes(String productionId) async {
    final rows = await _db.getScenesForProduction(productionId);
    return rows.map(_sceneFromRow).toList();
  }

  Future<void> saveScenes(
      String productionId, List<models.ScriptScene> scenes) async {
    await _db.deleteScenesForProduction(productionId);
    final companions = scenes.asMap().entries.map((e) => ScenesCompanion(
          id: Value(e.value.id),
          productionId: Value(productionId),
          sceneName: Value(e.value.sceneName),
          act: Value(e.value.act),
          location: Value(e.value.location),
          description: Value(e.value.description),
          startLineIndex: Value(e.value.startLineIndex),
          endLineIndex: Value(e.value.endLineIndex),
          sortOrder: Value(e.key),
          characters: Value(e.value.characters.join(',')),
        )).toList();
    await _db.insertScenes(companions);
  }

  models.ScriptScene _sceneFromRow(Scene row) {
    return models.ScriptScene(
      id: row.id,
      act: row.act,
      sceneName: row.sceneName,
      location: row.location,
      description: row.description,
      startLineIndex: row.startLineIndex,
      endLineIndex: row.endLineIndex,
      characters: row.characters.isEmpty
          ? []
          : row.characters.split(','),
    );
  }

  // ── Recordings ──────────────────────────────────────

  Future<Map<String, models.Recording>> getRecordings(
      String productionId) async {
    final rows = await _db.getRecordingsForProduction(productionId);
    final map = <String, models.Recording>{};
    for (final row in rows) {
      map[row.scriptLineId] = _recordingFromRow(row);
    }
    return map;
  }

  Future<void> saveRecording(
      String productionId, models.Recording recording) async {
    await _db.insertRecording(RecordingsCompanion(
      id: Value(recording.id),
      productionId: Value(productionId),
      scriptLineId: Value(recording.scriptLineId),
      character: Value(recording.character),
      localPath: Value(recording.localPath),
      remoteUrl: Value(recording.remoteUrl),
      durationMs: Value(recording.durationMs),
      recordedAt: Value(recording.recordedAt),
    ));
  }

  Future<void> deleteRecording(String id) async {
    await _db.deleteRecording(id);
  }

  models.Recording _recordingFromRow(Recording row) {
    return models.Recording(
      id: row.id,
      scriptLineId: row.scriptLineId,
      character: row.character,
      localPath: row.localPath,
      remoteUrl: row.remoteUrl,
      durationMs: row.durationMs,
      recordedAt: row.recordedAt,
    );
  }
}
