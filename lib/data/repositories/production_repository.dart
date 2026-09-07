import 'dart:io';

import 'package:drift/drift.dart';

import '../database/app_database.dart';
import '../models/cast_member_model.dart' as models;
import '../models/production_models.dart' as models;
import '../models/script_models.dart' as models;
import '../services/debug_log_service.dart';

const guestAccountNamespace = '__guest__';

/// Repository bridging the Drift database with app-level model objects.
/// Handles conversions between Drift table rows and domain models.
class ProductionRepository {
  final AppDatabase _db;
  final String accountNamespace;
  final Future<void> Function(String path) _deleteRecordingFile;

  ProductionRepository(
    this._db, {
    this.accountNamespace = guestAccountNamespace,
    Future<void> Function(String path)? deleteRecordingFile,
  }) : _deleteRecordingFile =
           deleteRecordingFile ?? _deleteRecordingFileFromDisk;

  static Future<void> _deleteRecordingFileFromDisk(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  // ── Productions ─────────────────────────────────────

  Future<List<models.Production>> getAllProductions() async {
    final rows = await _db.getAllProductions(accountNamespace);
    return rows.map(_productionFromRow).toList();
  }

  Stream<List<models.Production>> watchAllProductions() {
    return _db.watchAllProductions(accountNamespace).map(
      (rows) => rows.map(_productionFromRow).toList(),
    );
  }

  Future<void> saveProduction(models.Production production) async {
    await _db.insertProduction(_productionCompanion(production));
  }

  Future<void> saveProductionPendingCloudCreate(
    models.Production production,
  ) async {
    await _db.insertProductionWithCloudCreate(_productionCompanion(production));
  }

  ProductionsCompanion _productionCompanion(models.Production production) =>
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
      );

  Future<void> deleteProduction(String id) async {
    final recordings = await _db.getRecordingsForProduction(id);
    final paths = recordings.map((recording) => recording.localPath).toList();

    // The relational state is the source of truth and commits atomically.
    // Files are only unlinked after commit so a failed transaction leaves a
    // completely usable production.
    await _db.deleteProductionWithRelations(id);

    for (final path in paths) {
      try {
        await _deleteRecordingFile(path);
      } catch (error) {
        DebugLogService.instance.logError(
          LogCategory.error,
          'Production deletion committed, but recording cleanup failed: $path',
          error,
        );
      }
    }
  }

  Future<models.Production?> getProduction(String id) async {
    final row = await _db.getProduction(id, accountNamespace);
    return row == null ? null : _productionFromRow(row);
  }

  Future<List<ProductionCloudCreateRow>> getProductionCloudCreates() =>
      _db.loadProductionCloudCreates();

  Future<void> markProductionCloudCreateFailed(
    String productionId,
    Object error,
  ) => _db.markProductionCloudCreateFailed(productionId, error);

  Future<void> markProductionCloudCreateSynced(String productionId) =>
      _db.markProductionCloudCreateSynced(productionId);

  Future<void> markProductionCloudDeletionPending(String productionId) =>
      _db.markProductionCloudDeletionPending(productionId);

  Future<void> resumeProductionCloudCreate(String productionId) =>
      _db.resumeProductionCloudCreate(productionId);

  Future<void> cancelProductionCloudCreate(String productionId) =>
      _db.cancelProductionCloudCreate(productionId);

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
    String productionId,
  ) async {
    final rows = await _db.getCastForProduction(productionId);
    return rows.map(_castMemberFromRow).toList();
  }

  Future<void> saveCastMember(models.CastMemberModel member) async {
    await _db.insertCastMember(_castCompanion(member));
  }

  CastMembersCompanion _castCompanion(models.CastMemberModel member) =>
      CastMembersCompanion(
        id: Value(member.id),
        productionId: Value(member.productionId),
        userId: Value(member.userId),
        characterName: Value(member.characterName),
        displayName: Value(member.displayName),
        role: Value(member.role.name),
        invitedAt: Value(member.invitedAt ?? DateTime.now()),
        joinedAt: Value(member.joinedAt),
      );

  Future<void> deleteCastMember(String id) async {
    await _db.deleteCastMember(id);
  }

  Future<void> savePendingCastInvitations(
    List<models.CastMemberModel> members,
  ) async {
    await _db
        .saveCastMembersWithInvitations(members.map(_castCompanion).toList(), [
          for (final member in members)
            PendingCastInvitationRow(
              localMemberId: member.id,
              productionId: member.productionId,
              characterName: member.characterName,
              displayName: member.displayName,
              contactInfo: member.contactInfo,
              role: member.role.name,
              createdAt: member.invitedAt ?? DateTime.now(),
            ),
        ]);
  }

  Future<List<PendingCastInvitationRow>> getPendingCastInvitations({
    String? productionId,
  }) => _db.loadPendingCastInvitations(productionId: productionId);

  Future<void> markCastInvitationFailed(String localMemberId, Object error) =>
      _db.markCastInvitationFailed(localMemberId, error);

  Future<void> reconcileCastInvitation(
    String localMemberId,
    models.CastMemberModel cloudMember,
  ) => _db.reconcileCastInvitation(localMemberId, _castCompanion(cloudMember));

  Future<void> reconcileCastInvitations(
    List<({String localMemberId, models.CastMemberModel cloudMember})>
    reconciliations,
  ) => _db.reconcileCastInvitations(
    [for (final item in reconciliations) item.localMemberId],
    [for (final item in reconciliations) _castCompanion(item.cloudMember)],
  );

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
    String productionId,
    List<models.ScriptLine> lines,
  ) async {
    final companions = lines
        .map(
          (l) => ScriptLinesCompanion(
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
            multiCharacters: Value(l.multiCharacters.join(',')),
          ),
        )
        .toList();
    // Atomic delete + re-insert: a crash/throw between the two would otherwise
    // leave the production with ALL its script lines deleted and none restored
    // (permanent data loss). The transaction makes it all-or-nothing.
    await _db.transaction(() async {
      await _db.deleteScriptLinesForProduction(productionId);
      await _db.insertScriptLines(companions);
    });
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

  Future<void> deleteRecording(String id) async {
    await _db.deleteRecording(id);
  }

  /// Persist the remote URL when the local take has not been superseded.
  Future<bool> markRecordingUploaded(
    String productionId,
    String scriptLineId,
    String remoteUrl, {
    String? expectedRecordingId,
    DateTime? expectedRecordedAt,
  }) async {
    final changed = await _db.markRecordingUploaded(
      productionId,
      scriptLineId,
      remoteUrl,
      expectedRecordingId: expectedRecordingId,
      expectedRecordedAt: expectedRecordedAt,
    );
    final guarded = expectedRecordingId != null || expectedRecordedAt != null;
    if (changed > 1 || (changed == 0 && !guarded)) {
      throw StateError(
        'Expected one recording for $productionId/$scriptLineId, '
        'updated $changed',
      );
    }
    return changed == 1;
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
