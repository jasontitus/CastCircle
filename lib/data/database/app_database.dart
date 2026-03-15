import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

part 'app_database.g.dart';

// ── Table Definitions ───────────────────────────────────

class Productions extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get organizerId => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('draft'))();
  TextColumn get scriptPath => text().nullable()();
  TextColumn get locale => text().withDefault(const Constant('en-US'))();
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

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

  @override
  Set<Column> get primaryKey => {id};
}

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
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (migrator, from, to) async {
          if (from < 2) {
            // Add locale column to productions table
            await migrator.addColumn(productions, productions.locale);
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

  Future<int> insertRecording(RecordingsCompanion entry) =>
      into(recordings).insert(entry, mode: InsertMode.insertOrReplace);

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
    return NativeDatabase.createInBackground(file);
  });
}
