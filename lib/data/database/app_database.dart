import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../services/debug_log_service.dart';

part 'app_database.g.dart';

// ── Table Definitions ───────────────────────────────────

class Productions extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get organizerId => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('draft'))();
  TextColumn get scriptPath => text().nullable()();
  TextColumn get locale => text().withDefault(const Constant('en-US'))();
  TextColumn get joinCode => text().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_script_lines_production_order', columns: {#productionId, #orderIndex})
class ScriptLines extends Table {
  TextColumn get id => text()();
  TextColumn get productionId => text().references(Productions, #id)();
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
  TextColumn get productionId => text().references(Productions, #id)();
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
    name: 'idx_recordings_production_line', columns: {#productionId, #scriptLineId})
class Recordings extends Table {
  TextColumn get id => text()();
  TextColumn get productionId => text().references(Productions, #id)();
  TextColumn get scriptLineId => text().references(ScriptLines, #id)();
  TextColumn get character => text()();
  TextColumn get localPath => text()();
  TextColumn get remoteUrl => text().nullable()();
  IntColumn get durationMs => integer()();
  DateTimeColumn get recordedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_cast_members_production', columns: {#productionId})
class CastMembers extends Table {
  TextColumn get id => text()();
  TextColumn get productionId => text().references(Productions, #id)();
  TextColumn get userId => text().nullable()();
  TextColumn get characterName => text()();
  TextColumn get displayName => text().withDefault(const Constant(''))();
  TextColumn get role => text()(); // organizer, primary, understudy
  DateTimeColumn get invitedAt =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get joinedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// ── Database ────────────────────────────────────────────

@DriftDatabase(tables: [
  Productions,
  ScriptLines,
  Scenes,
  Recordings,
  CastMembers,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  // For testing
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 7;

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
      final alreadyApplied = msg.contains('duplicate column name') ||
          msg.contains('already exists');
      if (alreadyApplied) return;
      DebugLogService.instance
          .logError(LogCategory.general, 'DB migration step failed: $what', e);
      rethrow;
    }
  }

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (migrator, from, to) async {
          if (from < 2) {
            await _step('add productions.locale',
                () => migrator.addColumn(productions, productions.locale));
          }
          if (from < 3) {
            await _step('add productions.join_code',
                () => migrator.addColumn(productions, productions.joinCode));
          }
          if (from < 4) {
            await _step(
                'add script_lines.ocr_confidence',
                () =>
                    migrator.addColumn(scriptLines, scriptLines.ocrConfidence));
          }
          if (from < 5) {
            await _step('add script_lines.source_page',
                () => migrator.addColumn(scriptLines, scriptLines.sourcePage));
            await _step(
                'add script_lines.source_line_on_page',
                () => migrator.addColumn(
                    scriptLines, scriptLines.sourceLineOnPage));
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
              await _step('create index ${index.entityName}',
                  () => migrator.createIndex(index));
            }
          }
          if (from < 7) {
            await _step(
                'add script_lines.multi_characters',
                () => migrator.addColumn(
                    scriptLines, scriptLines.multiCharacters));
          }
        },
      );

  // ── Productions ─────────────────────────────────────

  Future<List<Production>> getAllProductions() =>
      select(productions).get();

  Stream<List<Production>> watchAllProductions() =>
      select(productions).watch();

  Future<Production?> getProduction(String id) =>
      (select(productions)..where((p) => p.id.equals(id)))
          .getSingleOrNull();

  Future<int> insertProduction(ProductionsCompanion entry) =>
      into(productions).insert(entry, mode: InsertMode.insertOrReplace);

  Future<bool> updateProduction(ProductionsCompanion entry) =>
      update(productions).replace(entry);

  Future<int> deleteProduction(String id) =>
      (delete(productions)..where((p) => p.id.equals(id))).go();

  // ── Script Lines ────────────────────────────────────

  Future<List<ScriptLine>> getScriptLines(String productionId) =>
      (select(scriptLines)
            ..where((l) => l.productionId.equals(productionId))
            ..orderBy([(l) => OrderingTerm.asc(l.orderIndex)]))
          .get();

  Future<void> insertScriptLines(List<ScriptLinesCompanion> entries) async {
    await batch((b) {
      b.insertAll(scriptLines, entries, mode: InsertMode.insertOrReplace);
    });
  }

  Future<int> deleteScriptLinesForProduction(String productionId) =>
      (delete(scriptLines)..where((l) => l.productionId.equals(productionId)))
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

  Future<List<Recording>> getRecordingsForProduction(
          String productionId) =>
      (select(recordings)
            ..where((r) => r.productionId.equals(productionId)))
          .get();

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
        await (delete(recordings)
              ..where((r) =>
                  r.productionId.equals(entry.productionId.value) &
                  r.scriptLineId.equals(entry.scriptLineId.value)))
            .go();
      }
      return into(recordings).insert(entry, mode: InsertMode.insertOrReplace);
    });
  }

  /// Mark a recording as uploaded by setting its remote URL.
  Future<int> markRecordingUploaded(
          String productionId, String scriptLineId, String remoteUrl) =>
      (update(recordings)
            ..where((r) =>
                r.productionId.equals(productionId) &
                r.scriptLineId.equals(scriptLineId)))
          .write(RecordingsCompanion(remoteUrl: Value(remoteUrl)));

  Future<int> deleteRecordingsForProduction(String productionId) =>
      (delete(recordings)..where((r) => r.productionId.equals(productionId)))
          .go();

  Future<int> deleteRecording(String id) =>
      (delete(recordings)..where((r) => r.id.equals(id))).go();

  Stream<List<Recording>> watchRecordingsForProduction(
          String productionId) =>
      (select(recordings)
            ..where((r) => r.productionId.equals(productionId)))
          .watch();

  // ── Cast Members ────────────────────────────────────

  Future<List<CastMember>> getCastForProduction(String productionId) =>
      (select(castMembers)
            ..where((c) => c.productionId.equals(productionId)))
          .get();

  Future<int> insertCastMember(CastMembersCompanion entry) =>
      into(castMembers).insert(entry, mode: InsertMode.insertOrReplace);

  Future<int> deleteCastMember(String id) =>
      (delete(castMembers)..where((c) => c.id.equals(id))).go();

  Future<int> deleteCastForProduction(String productionId) =>
      (delete(castMembers)
            ..where((c) => c.productionId.equals(productionId)))
          .go();
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
        db.execute('PRAGMA journal_mode=WAL;');
        db.execute('PRAGMA synchronous=NORMAL;');
        db.execute('PRAGMA busy_timeout=3000;');
      },
    );
  });
}
