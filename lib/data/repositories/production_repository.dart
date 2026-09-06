import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/app_database.dart';
import '../models/cast_member_model.dart' as models;
import '../models/production_models.dart' as models;
import '../models/script_models.dart' as models;

const guestAccountNamespace = '__guest__';

/// Repository bridging the Drift database with app-level model objects.
/// Handles conversions between Drift table rows and domain models.
class ProductionRepository {
  final AppDatabase _db;
  final String accountNamespace;

  ProductionRepository(
    this._db, {
    this.accountNamespace = guestAccountNamespace,
  });

  // ── Productions ─────────────────────────────────────

  Future<List<models.Production>> getAllProductions() async {
    final rows = await _db.getAllProductions(accountNamespace);
    return rows.map(_productionFromRow).toList();
  }

  Stream<List<models.Production>> watchAllProductions() {
    return _db
        .watchAllProductions(accountNamespace)
        .map((rows) => rows.map(_productionFromRow).toList());
  }

  Future<void> saveProduction(models.Production production) async {
    await _db.insertProduction(
      ProductionsCompanion(
        id: Value(production.id),
        accountNamespace: Value(accountNamespace),
        title: Value(production.title),
        organizerId: Value(production.organizerId),
        status: Value(production.status.name),
        scriptPath: Value(production.scriptPath),
        locale: Value(production.locale),
        joinCode: Value(production.joinCode),
        createdAt: Value(production.createdAt),
      ),
    );
  }

  Future<void> deleteProduction(String id) async {
    if (await _db.getProduction(id, accountNamespace) == null) return;
    final recordings = await _db.getRecordingsForProduction(id);

    // The relational delete is all-or-nothing. Files are intentionally cleaned
    // up only after commit: filesystem work cannot participate in SQLite's
    // transaction, and a failed delete must never leave a half-destroyed DB.
    await _db.transaction(() async {
      await _db.deleteRecordingsForProduction(id);
      await _db.deleteScriptLinesForProduction(id);
      await _db.deleteScenesForProduction(id);
      await _db.deleteCastForProduction(id);
      await _db.deleteProduction(id, accountNamespace);
    });

    final paths = <String>{
      for (final recording in recordings) recording.localPath,
    };
    try {
      final docs = await getApplicationDocumentsDirectory();
      paths.add(p.join(docs.path, 'scripts', '$id.pdf'));
    } catch (_) {
      // Resolving Documents is best-effort just like deleting the files.
    }
    await _deleteFilesBestEffort(paths.toList());
  }

  static Future<void> _deleteFilesBestEffort(List<String> paths) async {
    var next = 0;
    final workerCount = paths.length < 8 ? paths.length : 8;
    final workers = List.generate(workerCount, (_) async {
      while (true) {
        final index = next++;
        if (index >= paths.length) return;
        try {
          final file = File(paths[index]);
          if (await file.exists()) await file.delete();
        } catch (_) {
          // Local cleanup is best-effort after the database commit.
        }
      }
    });
    await Future.wait(workers);
  }

  models.Production _productionFromRow(Production row) {
    return models.Production(
      id: row.id,
      title: row.title,
      organizerId: row.organizerId ?? '',
      status:
          models.ProductionStatus.values.asNameMap()[row.status] ??
          models.ProductionStatus.draft,
      scriptPath: row.scriptPath,
      locale: row.locale,
      joinCode: row.joinCode,
      createdAt: row.createdAt,
    );
  }

  // ── Cast Members ───────────────────────────────────

  Future<List<models.CastMemberModel>> getCastMembers(
    String productionId,
  ) async {
    final rows = await _db.getCastForProduction(productionId);
    return rows.map(_castMemberFromRow).toList();
  }

  Future<void> saveCastMember(models.CastMemberModel member) async {
    await _db.insertCastMember(_castCompanion(member));
  }

  Future<void> applyCastMemberChanges({
    required List<models.CastMemberModel> upserts,
    required Set<String> deleteIds,
  }) async {
    if (upserts.isEmpty && deleteIds.isEmpty) return;
    await _db.transaction(() async {
      for (final id in deleteIds) {
        await _db.deleteCastMember(id);
      }
      for (final member in upserts) {
        await _db.insertCastMember(_castCompanion(member));
      }
    });
  }

  static CastMembersCompanion _castCompanion(models.CastMemberModel member) {
    return CastMembersCompanion(
      id: Value(member.id),
      productionId: Value(member.productionId),
      userId: Value(member.userId),
      characterName: Value(member.characterName),
      displayName: Value(member.displayName),
      contactInfo: Value(member.contactInfo),
      role: Value(member.role.name),
      invitedAt: Value(member.invitedAt ?? DateTime.now()),
      joinedAt: Value(member.joinedAt),
    );
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
      contactInfo: row.contactInfo,
      role: models.CastRole.fromString(row.role),
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
    String productionId,
    List<models.ScriptLine> lines,
  ) async {
    final existing = await _db.getScriptLines(productionId);
    final existingById = {for (final row in existing) row.id: row};
    final incomingIds = {for (final line in lines) line.id};
    final removedIds = [
      for (final row in existing)
        if (!incomingIds.contains(row.id)) row.id,
    ];
    final changed = [
      for (final line in lines)
        if (existingById[line.id] == null ||
            !_sameScriptLine(existingById[line.id]!, line))
          ScriptLinesCompanion(
            id: Value(line.id),
            productionId: Value(productionId),
            act: Value(line.act),
            scene: Value(line.scene),
            lineNumber: Value(line.lineNumber),
            orderIndex: Value(line.orderIndex),
            character: Value(line.character),
            lineText: Value(line.text),
            lineType: Value(line.lineType.name),
            stageDirection: Value(line.stageDirection),
            ocrConfidence: Value(line.ocrConfidence),
            sourcePage: Value(line.sourcePage),
            sourceLineOnPage: Value(line.sourceLineOnPage),
            multiCharacters: Value(line.multiCharacters.join(',')),
          ),
    ];

    if (removedIds.isEmpty && changed.isEmpty) return;
    await _db.transaction(() async {
      // Foreign keys are RESTRICT intentionally. A line removed by an edit
      // owns its local take, so remove that take in the same transaction.
      await _db.deleteRecordingsForScriptLines(productionId, removedIds);
      await _db.deleteScriptLines(productionId, removedIds);
      await _db.upsertScriptLines(changed);
    });
  }

  static bool _sameScriptLine(ScriptLine row, models.ScriptLine line) {
    return row.act == line.act &&
        row.scene == line.scene &&
        row.lineNumber == line.lineNumber &&
        row.orderIndex == line.orderIndex &&
        row.character == line.character &&
        row.lineText == line.text &&
        row.lineType == line.lineType.name &&
        row.stageDirection == line.stageDirection &&
        row.ocrConfidence == line.ocrConfidence &&
        row.sourcePage == line.sourcePage &&
        row.sourceLineOnPage == line.sourceLineOnPage &&
        row.multiCharacters == line.multiCharacters.join(',');
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
      lineType:
          models.LineType.values.asNameMap()[row.lineType] ??
          models.LineType.dialogue,
      stageDirection: row.stageDirection,
      ocrConfidence: row.ocrConfidence,
      sourcePage: row.sourcePage,
      sourceLineOnPage: row.sourceLineOnPage,
      multiCharacters: row.multiCharacters.isEmpty
          ? const []
          : row.multiCharacters.split(','),
    );
  }

  // ── Scenes ──────────────────────────────────────────

  Future<List<models.ScriptScene>> getScenes(String productionId) async {
    final rows = await _db.getScenesForProduction(productionId);
    return rows.map(_sceneFromRow).toList();
  }

  Future<void> saveScenes(
    String productionId,
    List<models.ScriptScene> scenes,
  ) async {
    // Delete + reinsert must be atomic (same guarantee saveScriptLines
    // makes): a crash between the two would permanently lose every scene.
    final companions = scenes
        .asMap()
        .entries
        .map(
          (e) => ScenesCompanion(
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
          ),
        )
        .toList();
    await _db.transaction(() async {
      await _db.deleteScenesForProduction(productionId);
      await _db.insertScenes(companions);
    });
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
      characters: row.characters.isEmpty ? [] : row.characters.split(','),
    );
  }

  // ── Recordings ──────────────────────────────────────

  Future<Map<String, models.Recording>> getRecordings(
    String productionId,
  ) async {
    final rows = await _db.getRecordingsForProduction(productionId);
    final map = <String, models.Recording>{};
    for (final row in rows) {
      map[row.scriptLineId] = _recordingFromRow(row);
    }
    return map;
  }

  Future<void> saveRecording(
    String productionId,
    models.Recording recording,
  ) async {
    await _db.insertRecording(
      RecordingsCompanion(
        id: Value(recording.id),
        productionId: Value(productionId),
        scriptLineId: Value(recording.scriptLineId),
        character: Value(recording.character),
        localPath: Value(recording.localPath),
        remoteUrl: Value(recording.remoteUrl),
        durationMs: Value(recording.durationMs),
        recordedAt: Value(recording.recordedAt),
      ),
    );
  }

  Future<void> deleteRecording(String productionId, String recordingId) async {
    if (await _db.getProduction(productionId, accountNamespace) == null) return;
    await _db.deleteRecording(productionId, recordingId);
  }

  /// Persist the remote URL on a recording after a successful upload.
  Future<void> markRecordingUploaded(
    String productionId,
    String scriptLineId,
    String recordingId,
    String remoteUrl,
  ) async {
    await _db.markRecordingUploaded(
      productionId,
      scriptLineId,
      recordingId,
      remoteUrl,
    );
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
