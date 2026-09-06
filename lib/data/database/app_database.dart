import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../services/debug_log_service.dart';

part 'app_database.g.dart';

// ── Table Definitions ───────────────────────────────────

@TableIndex(
  name: 'idx_productions_account_created',
  columns: {#accountNamespace, #createdAt},
)
class Productions extends Table {
  TextColumn get id => text()();
  TextColumn get accountNamespace =>
      text().withDefault(const Constant('__guest__'))();
  TextColumn get title => text()();
  TextColumn get organizerId => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('draft'))();
  TextColumn get scriptPath => text().nullable()();
  TextColumn get locale => text().withDefault(const Constant('en-US'))();
  TextColumn get joinCode => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(
  name: 'idx_script_lines_production_order',
  columns: {#productionId, #orderIndex},
)
class ScriptLines extends Table {
  TextColumn get id => text()();
  TextColumn get productionId =>
      text().references(Productions, #id, onDelete: KeyAction.restrict)();
  TextColumn get act => text().withDefault(const Constant(''))();
  TextColumn get scene => text().withDefault(const Constant(''))();
  IntColumn get lineNumber => integer()();
  IntColumn get orderIndex => integer()();
  TextColumn get character => text().withDefault(const Constant(''))();
  TextColumn get lineText => text()();
  TextColumn get lineType => text()();
  TextColumn get stageDirection => text().withDefault(const Constant(''))();
  RealColumn get ocrConfidence => real().nullable()();
  IntColumn get sourcePage => integer().nullable()();
  IntColumn get sourceLineOnPage => integer().nullable()();

  // Individual characters of a shared/ensemble line ("BOTH", "MACBETH AND
  // LENNOX"), comma-separated like Scenes.characters. Empty = single-character
  // line. Without this column the list was silently dropped on every local
  // save/load, so shared lines degraded after any app restart.
  TextColumn get multiCharacters => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_scenes_production', columns: {#productionId})
class Scenes extends Table {
  TextColumn get id => text()();
  TextColumn get productionId =>
      text().references(Productions, #id, onDelete: KeyAction.restrict)();
  TextColumn get sceneName => text()();
  TextColumn get act => text().withDefault(const Constant(''))();
  TextColumn get location => text().withDefault(const Constant(''))();
  TextColumn get description => text().withDefault(const Constant(''))();
  IntColumn get startLineIndex => integer()();
  IntColumn get endLineIndex => integer()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  // Characters stored as comma-separated string
  TextColumn get characters => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(
  name: 'idx_recordings_production_line',
  columns: {#productionId, #scriptLineId},
)
class Recordings extends Table {
  TextColumn get id => text()();
  TextColumn get productionId =>
      text().references(Productions, #id, onDelete: KeyAction.restrict)();
  TextColumn get scriptLineId =>
      text().references(ScriptLines, #id, onDelete: KeyAction.restrict)();
  TextColumn get character => text()();
  TextColumn get localPath => text()();
  TextColumn get remoteUrl => text().nullable()();
  IntColumn get durationMs => integer()();
  DateTimeColumn get recordedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_cast_members_production', columns: {#productionId})
class CastMembers extends Table {
  TextColumn get id => text()();
  TextColumn get productionId =>
      text().references(Productions, #id, onDelete: KeyAction.restrict)();
  TextColumn get userId => text().nullable()();
  TextColumn get characterName => text()();
  TextColumn get displayName => text().withDefault(const Constant(''))();
  TextColumn get contactInfo => text().nullable()();
  TextColumn get role => text()(); // organizer, primary, understudy
  DateTimeColumn get invitedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get joinedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// ── Database ────────────────────────────────────────────

@DriftDatabase(
  tables: [Productions, ScriptLines, Scenes, Recordings, CastMembers],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  // For testing
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 9;

  /// Runs one migration step, tolerating ONLY the benign already-applied
  /// case (duplicate column/index from a partial earlier upgrade). Anything
  /// else rethrows: Drift advances user_version when onUpgrade returns
  /// normally, so swallowing a real failure here would mask a missing
  /// column FOREVER — every later query then dies with "no such column"
  /// and the migration never re-runs to repair it.
  static Future<void> _step(String what, Future<void> Function() run) async {
    try {
      await run();
    } catch (e) {
      final msg = e.toString();
      final alreadyApplied =
          msg.contains('duplicate column name') ||
          msg.contains('already exists');
      if (alreadyApplied) return;
      DebugLogService.instance.logError(
        LogCategory.general,
        'DB migration step failed: $what',
        e,
      );
      rethrow;
    }
  }

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (migrator, from, to) async {
      if (from < 2) {
        await _step(
          'add productions.locale',
          () => migrator.addColumn(productions, productions.locale),
        );
      }
      if (from < 3) {
        await _step(
          'add productions.join_code',
          () => migrator.addColumn(productions, productions.joinCode),
        );
      }
      if (from < 4) {
        await _step(
          'add script_lines.ocr_confidence',
          () => migrator.addColumn(scriptLines, scriptLines.ocrConfidence),
        );
      }
      if (from < 5) {
        await _step(
          'add script_lines.source_page',
          () => migrator.addColumn(scriptLines, scriptLines.sourcePage),
        );
        await _step(
          'add script_lines.source_line_on_page',
          () => migrator.addColumn(scriptLines, scriptLines.sourceLineOnPage),
        );
      }
      if (from < 6) {
        // Every query filters by productionId; without these, loads are
        // full-table scans that grow with each production imported.
        for (final index in [
          idxScriptLinesProductionOrder,
          idxScenesProduction,
          idxRecordingsProductionLine,
          idxCastMembersProduction,
        ]) {
          await _step(
            'create index ${index.entityName}',
            () => migrator.createIndex(index),
          );
        }
      }
      if (from < 7) {
        await _step(
          'add script_lines.multi_characters',
          () => migrator.addColumn(scriptLines, scriptLines.multiCharacters),
        );
      }
      if (from < 8) {
        await _step(
          'add cast_members.contact_info',
          () => migrator.addColumn(castMembers, castMembers.contactInfo),
        );
      }
      if (from < 9) {
        await _step(
          'add productions.account_namespace',
          () => migrator.addColumn(productions, productions.accountNamespace),
        );
        await _step(
          'create index ${idxProductionsAccountCreated.entityName}',
          () => migrator.createIndex(idxProductionsAccountCreated),
        );
      }
    },
    beforeOpen: (details) async {
      // SQLite does not retroactively validate existing rows when foreign
      // keys are enabled. Remove legacy orphans once on every open before
      // normal writes can encounter a RESTRICT constraint.
      await customStatement('''
            DELETE FROM recordings
            WHERE production_id NOT IN (SELECT id FROM productions)
               OR script_line_id NOT IN (SELECT id FROM script_lines)
               OR NOT EXISTS (
                 SELECT 1 FROM script_lines AS line
                 WHERE line.id = recordings.script_line_id
                   AND line.production_id = recordings.production_id
               )
          ''');
      await customStatement('''
            DELETE FROM script_lines
            WHERE production_id NOT IN (SELECT id FROM productions)
          ''');
      await customStatement('''
            DELETE FROM scenes
            WHERE production_id NOT IN (SELECT id FROM productions)
          ''');
      await customStatement('''
            DELETE FROM cast_members
            WHERE production_id NOT IN (SELECT id FROM productions)
          ''');
    },
  );

  // ── Productions ─────────────────────────────────────

  Future<List<Production>> getAllProductions(String accountNamespace) =>
      (select(
        productions,
      )..where((p) => p.accountNamespace.equals(accountNamespace))).get();

  Stream<List<Production>> watchAllProductions(String accountNamespace) =>
      (select(
        productions,
      )..where((p) => p.accountNamespace.equals(accountNamespace))).watch();

  Future<Production?> getProduction(String id, String accountNamespace) =>
      (select(productions)..where(
            (p) =>
                p.id.equals(id) & p.accountNamespace.equals(accountNamespace),
          ))
          .getSingleOrNull();

  Future<int> insertProduction(ProductionsCompanion entry) =>
      into(productions).insertOnConflictUpdate(entry);

  Future<bool> updateProduction(
    ProductionsCompanion entry,
    String accountNamespace,
  ) async {
    if (!entry.id.present) return false;
    final changed =
        await (update(productions)..where(
              (p) =>
                  p.id.equals(entry.id.value) &
                  p.accountNamespace.equals(accountNamespace),
            ))
            .write(entry);
    return changed > 0;
  }

  Future<int> deleteProduction(String id, String accountNamespace) =>
      (delete(productions)..where(
            (p) =>
                p.id.equals(id) & p.accountNamespace.equals(accountNamespace),
          ))
          .go();

  Future<void> claimLegacyProductions(String userId) async {
    await transaction(() async {
      await customUpdate(
        '''
          UPDATE productions
          SET account_namespace = ?
          WHERE account_namespace = '__guest__'
            AND (
              organizer_id = ?
              OR EXISTS (
                SELECT 1
                FROM cast_members
                WHERE cast_members.production_id = productions.id
                  AND cast_members.user_id = ?
              )
            )
        ''',
        variables: [
          Variable.withString(userId),
          Variable.withString(userId),
          Variable.withString(userId),
        ],
        updates: {productions},
      );
    });
  }

  // ── Script Lines ────────────────────────────────────

  Future<List<ScriptLine>> getScriptLines(String productionId) =>
      (select(scriptLines)
            ..where((l) => l.productionId.equals(productionId))
            ..orderBy([(l) => OrderingTerm.asc(l.orderIndex)]))
          .get();

  Future<void> upsertScriptLines(List<ScriptLinesCompanion> entries) async {
    await batch((b) {
      b.insertAllOnConflictUpdate(scriptLines, entries);
    });
  }

  Future<int> deleteScriptLinesForProduction(String productionId) => (delete(
    scriptLines,
  )..where((l) => l.productionId.equals(productionId))).go();

  Future<int> deleteRecordingsForScriptLines(
    String productionId,
    List<String> lineIds,
  ) => lineIds.isEmpty
      ? Future.value(0)
      : (delete(recordings)..where(
              (r) =>
                  r.productionId.equals(productionId) &
                  r.scriptLineId.isIn(lineIds),
            ))
            .go();

  Future<int> deleteScriptLines(String productionId, List<String> lineIds) =>
      lineIds.isEmpty
      ? Future.value(0)
      : (delete(scriptLines)..where(
              (l) => l.productionId.equals(productionId) & l.id.isIn(lineIds),
            ))
            .go();

  // ── Scenes ──────────────────────────────────────────

  Future<List<Scene>> getScenesForProduction(String productionId) =>
      (select(scenes)
            ..where((s) => s.productionId.equals(productionId))
            ..orderBy([(s) => OrderingTerm.asc(s.sortOrder)]))
          .get();

  Future<void> insertScenes(List<ScenesCompanion> entries) async {
    await batch((b) {
      b.insertAll(scenes, entries, mode: InsertMode.insertOrReplace);
    });
  }

  Future<int> deleteScenesForProduction(String productionId) =>
      (delete(scenes)..where((s) => s.productionId.equals(productionId))).go();

  // ── Recordings ──────────────────────────────────────

  Future<List<Recording>> getRecordingsForProduction(String productionId) =>
      (select(
        recordings,
      )..where((r) => r.productionId.equals(productionId))).get();

  /// Insert a recording, replacing any existing one for the same
  /// (production, line). The primary key is the random `id`, so each re-record
  /// gets a new id and `insertOrReplace` alone would pile up duplicate rows for
  /// the same line. The app treats recordings as one-per-line (see
  /// RecordingsNotifier's `Map<lineId, Recording>`), so we delete the line's
  /// prior row(s) first — atomically, in a transaction. Castmates' recordings
  /// live in the in-memory sync cache, not this table, so they're unaffected.
  Future<int> insertRecording(RecordingsCompanion entry) async {
    return transaction(() async {
      if (entry.productionId.present && entry.scriptLineId.present) {
        await (delete(recordings)..where(
              (r) =>
                  r.productionId.equals(entry.productionId.value) &
                  r.scriptLineId.equals(entry.scriptLineId.value),
            ))
            .go();
      }
      return into(recordings).insert(entry, mode: InsertMode.insertOrReplace);
    });
  }

  /// Mark a recording as uploaded by setting its remote URL.
  Future<int> markRecordingUploaded(
    String productionId,
    String scriptLineId,
    String recordingId,
    String remoteUrl,
  ) =>
      (update(recordings)..where(
            (r) =>
                r.productionId.equals(productionId) &
                r.scriptLineId.equals(scriptLineId) &
                r.id.equals(recordingId),
          ))
          .write(RecordingsCompanion(remoteUrl: Value(remoteUrl)));

  Future<int> deleteRecordingsForProduction(String productionId) => (delete(
    recordings,
  )..where((r) => r.productionId.equals(productionId))).go();

  Future<int> deleteRecording(String productionId, String id) => (delete(
    recordings,
  )..where((r) => r.id.equals(id) & r.productionId.equals(productionId))).go();

  Stream<List<Recording>> watchRecordingsForProduction(String productionId) =>
      (select(
        recordings,
      )..where((r) => r.productionId.equals(productionId))).watch();

  // ── Cast Members ────────────────────────────────────

  Future<List<CastMember>> getCastForProduction(String productionId) => (select(
    castMembers,
  )..where((c) => c.productionId.equals(productionId))).get();

  Future<int> insertCastMember(CastMembersCompanion entry) =>
      into(castMembers).insert(entry, mode: InsertMode.insertOrReplace);

  Future<int> deleteCastMember(String id) =>
      (delete(castMembers)..where((c) => c.id.equals(id))).go();

  Future<int> deleteCastForProduction(String productionId) => (delete(
    castMembers,
  )..where((c) => c.productionId.equals(productionId))).go();
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'lineguide.sqlite'));
    return NativeDatabase.createInBackground(
      file,
      setup: (db) {
        // WAL: readers don't block the per-line recording writes during
        // rehearsal, and commits stop paying a full-journal fsync.
        // synchronous=NORMAL is the standard WAL pairing (durable to app
        // crash; an OS crash can lose the last transactions — acceptable for
        // re-syncable local state). busy_timeout beats sporadic SQLITE_BUSY.
        db.execute('PRAGMA foreign_keys=ON;');
        db.execute('PRAGMA journal_mode=WAL;');
        db.execute('PRAGMA synchronous=NORMAL;');
        db.execute('PRAGMA busy_timeout=3000;');
      },
    );
  });
}
