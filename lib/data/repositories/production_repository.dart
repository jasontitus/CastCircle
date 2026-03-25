import 'dart:io';

import 'package:drift/drift.dart';

import '../database/app_database.dart';
import '../models/cast_member_model.dart' as models;
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
      joinCode: Value(production.joinCode),
      createdAt: Value(production.createdAt),
    ));
  }

  Future<void> deleteProduction(String id) async {
    final recordings = await _db.getRecordingsForProduction(id);
    for (final recording in recordings) {
      try {
        final file = File(recording.localPath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        // Best-effort cleanup: deleting the DB row matters more than the file.
      }
    }

    // Cascade: delete related data first
    await _db.deleteRecordingsForProduction(id);
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
      joinCode: row.joinCode,
      createdAt: row.createdAt,
    );
  }

  // ── Cast Members ───────────────────────────────────

  Future<List<models.CastMemberModel>> getCastMembers(
      String productionId) async {
    final rows = await _db.getCastForProduction(productionId);
    return rows.map(_castMemberFromRow).toList();
  }

  Future<void> saveCastMember(models.CastMemberModel member) async {
    await _db.insertCastMember(CastMembersCompanion(
      id: Value(member.id),
      productionId: Value(member.productionId),
      userId: Value(member.userId),
      characterName: Value(member.characterName),
      displayName: Value(member.displayName),
      role: Value(member.role.name),
      invitedAt: Value(member.invitedAt ?? DateTime.now()),
      joinedAt: Value(member.joinedAt),
    ));
  }

  Future<void> deleteCastMember(String id) async {
    await _db.deleteCastMember(id);
  }

  models.CastMemberModel _castMemberFromRow(CastMember row) {
    return models.CastMemberModel(
      id: row.id,
      productionId: row.productionId,
      userId: row.userId,
      characterName: row.characterName,
      displayName: row.displayName,
      role: models.CastRole.values.byName(row.role),
      invitedAt: row.invitedAt,
      joinedAt: row.joinedAt,
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
          ocrConfidence: Value(l.ocrConfidence),
          sourcePage: Value(l.sourcePage),
          sourceLineOnPage: Value(l.sourceLineOnPage),
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
      ocrConfidence: row.ocrConfidence,
      sourcePage: row.sourcePage,
      sourceLineOnPage: row.sourceLineOnPage,
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
