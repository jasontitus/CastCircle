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
  name: 'idx_recordings_production_line',
  columns: {#productionId, #scriptLineId},
)
class Recordings extends Table {
  TextColumn get id => text()();
  TextColumn get productionId => text().references(Productions, #id)();
  TextColumn get scriptLineId => text().references(ScriptLines, #id)();
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
  TextColumn get productionId => text().references(Productions, #id)();
  TextColumn get userId => text().nullable()();
  TextColumn get characterName => text()();
  TextColumn get displayName => text().withDefault(const Constant(''))();
  TextColumn get role => text()(); // organizer, primary, understudy
  DateTimeColumn get invitedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get joinedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class SyncQueueRow {
  final String key;
  final String payload;
  final String state;
  final String? remoteUrl;

  const SyncQueueRow({
    required this.key,
    required this.payload,
    required this.state,
    this.remoteUrl,
  });
}

class ProductionCloudCreateRow {
  final String productionId;
  final String status;
  final int attemptCount;
  final String? lastError;

  const ProductionCloudCreateRow({
    required this.productionId,
    required this.status,
    required this.attemptCount,
    this.lastError,
  });
}

class SttSampleRow {
  final String productionId;
  final String actorId;
  final String audioPath;
  final String transcript;
  final int durationMs;
  final DateTime recordedAt;

  const SttSampleRow({
    required this.productionId,
    required this.actorId,
    required this.audioPath,
    required this.transcript,
    required this.durationMs,
    required this.recordedAt,
  });
}

class SttProfileMetadataRow {
  final String productionId;
  final String actorId;
  final String status;
  final String? adapterPath;
  final DateTime? lastTrainedAt;
  final double? wordErrorRate;

  const SttProfileMetadataRow({
    required this.productionId,
    required this.actorId,
    required this.status,
    this.adapterPath,
    this.lastTrainedAt,
    this.wordErrorRate,
  });
}

class PendingCastInvitationRow {
  final String localMemberId;
  final String productionId;
  final String characterName;
  final String displayName;
  final String? contactInfo;
  final String role;
  final DateTime createdAt;
  final int attemptCount;
  final String? lastError;

  const PendingCastInvitationRow({
    required this.localMemberId,
    required this.productionId,
    required this.characterName,
    required this.displayName,
    this.contactInfo,
    required this.role,
    required this.createdAt,
    this.attemptCount = 0,
    this.lastError,
  });
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
  int get schemaVersion => 12;

  Future<bool> _columnExists(String table, String column) async {
    final rows = await customSelect('PRAGMA table_info("$table")').get();
    return rows.any((row) => row.read<String>('name') == column);
  }

  bool _isExactDuplicate(Object error, String target, {required bool index}) {
    final message = error.toString().toLowerCase();
    final escaped = RegExp.escape(target.toLowerCase());
    final pattern = index
        ? RegExp('index\\s+["`]?$escaped["`]?\\s+already exists(?:\\W|\$)')
        : RegExp('duplicate column name:\\s*["`]?$escaped["`]?(?:\\W|\$)');
    return pattern.hasMatch(message);
  }

  Future<void> _ensureColumn(
    String table,
    String column,
    Future<void> Function() create,
  ) async {
    if (await _columnExists(table, column)) return;
    try {
      await create();
    } catch (error) {
      if (!_isExactDuplicate(error, column, index: false) ||
          !await _columnExists(table, column)) {
        DebugLogService.instance.logError(
          LogCategory.general,
          'DB migration failed: $table.$column',
          error,
        );
        rethrow;
      }
    }
    if (!await _columnExists(table, column)) {
      throw StateError('Migration did not create $table.$column');
    }
  }

  Future<void> _ensureIndex(
    Index index,
    String table,
    List<String> expectedColumns,
    Future<void> Function() create,
  ) async {
    final existing = await _indexShapeForTable(table, index.entityName);
    if (existing != null) {
      if (!existing.unique && _sameColumns(existing.columns, expectedColumns)) {
        return;
      }
      throw StateError(
        'Index ${index.entityName} exists with '
        '${existing.columns}, unique=${existing.unique}; '
        'expected $expectedColumns, unique=false',
      );
    }
    try {
      await create();
    } catch (error) {
      final actual = await _indexShapeForTable(table, index.entityName);
      if (!_isExactDuplicate(error, index.entityName, index: true) ||
          actual == null ||
          actual.unique ||
          !_sameColumns(actual.columns, expectedColumns)) {
        DebugLogService.instance.logError(
          LogCategory.general,
          'DB migration failed: index ${index.entityName}',
          error,
        );
        rethrow;
      }
    }
    final actual = await _indexShapeForTable(table, index.entityName);
    if (actual == null ||
        actual.unique ||
        !_sameColumns(actual.columns, expectedColumns)) {
      throw StateError(
        'Migration created ${index.entityName} with '
        '${actual?.columns}, unique=${actual?.unique}; '
        'expected $expectedColumns, unique=false',
      );
    }
  }

  Future<({List<String> columns, bool unique})?> _indexShapeForTable(
    String table,
    String name,
  ) async {
    final indexes = await customSelect('PRAGMA index_list("$table")').get();
    final matches = indexes
        .where((row) => row.read<String>('name') == name)
        .toList();
    if (matches.isEmpty) return null;
    final rows = await customSelect('PRAGMA index_info("$name")').get();
    rows.sort((a, b) => a.read<int>('seqno').compareTo(b.read<int>('seqno')));
    return (
      columns: rows.map((row) => row.read<String>('name')).toList(),
      unique: matches.single.read<int>('unique') != 0,
    );
  }

  static bool _sameColumns(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  Future<void> _ensureAuxiliarySchema() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS sync_queue_jobs (
        queue_key TEXT PRIMARY KEY NOT NULL,
        payload TEXT NOT NULL,
        state TEXT NOT NULL,
        remote_url TEXT,
        updated_at INTEGER NOT NULL
      )
    ''');
    await customStatement('''
      CREATE TABLE IF NOT EXISTS production_cloud_creates (
        production_id TEXT PRIMARY KEY NOT NULL,
        status TEXT NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        updated_at INTEGER NOT NULL
      )
    ''');
    await customStatement('''
      CREATE TABLE IF NOT EXISTS stt_samples (
        production_id TEXT NOT NULL,
        actor_id TEXT NOT NULL,
        audio_path TEXT NOT NULL,
        transcript TEXT NOT NULL,
        duration_ms INTEGER NOT NULL,
        recorded_at INTEGER NOT NULL,
        PRIMARY KEY (production_id, audio_path)
      )
    ''');
    await customStatement('''
      CREATE INDEX IF NOT EXISTS idx_stt_samples_production_actor
      ON stt_samples (production_id, actor_id)
    ''');
    await customStatement('''
      CREATE TABLE IF NOT EXISTS stt_profile_metadata (
        production_id TEXT NOT NULL,
        actor_id TEXT NOT NULL,
        status TEXT NOT NULL,
        adapter_path TEXT,
        last_trained_at INTEGER,
        word_error_rate REAL,
        PRIMARY KEY (production_id, actor_id)
      )
    ''');
    await customStatement('''
      CREATE TABLE IF NOT EXISTS stt_legacy_migrations (
        production_id TEXT PRIMARY KEY NOT NULL,
        migrated_at INTEGER NOT NULL
      )
    ''');
    await customStatement('''
      CREATE TABLE IF NOT EXISTS pending_cast_invitations (
        local_member_id TEXT PRIMARY KEY NOT NULL,
        production_id TEXT NOT NULL,
        character_name TEXT NOT NULL,
        display_name TEXT NOT NULL,
        contact_info TEXT,
        role TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT
      )
    ''');
    await customStatement('''
      CREATE INDEX IF NOT EXISTS idx_pending_cast_invitations_production
      ON pending_cast_invitations (production_id)
    ''');

    const required = <String, List<String>>{
      'sync_queue_jobs': [
        'queue_key',
        'payload',
        'state',
        'remote_url',
        'updated_at',
      ],
      'production_cloud_creates': [
        'production_id',
        'status',
        'attempt_count',
        'last_error',
        'updated_at',
      ],
      'stt_samples': [
        'production_id',
        'actor_id',
        'audio_path',
        'transcript',
        'duration_ms',
        'recorded_at',
      ],
      'stt_profile_metadata': [
        'production_id',
        'actor_id',
        'status',
        'adapter_path',
        'last_trained_at',
        'word_error_rate',
      ],
      'stt_legacy_migrations': ['production_id', 'migrated_at'],
      'pending_cast_invitations': [
        'local_member_id',
        'production_id',
        'character_name',
        'display_name',
        'contact_info',
        'role',
        'created_at',
        'attempt_count',
        'last_error',
      ],
    };
    for (final entry in required.entries) {
      for (final column in entry.value) {
        if (!await _columnExists(entry.key, column)) {
          throw StateError(
            'Auxiliary table ${entry.key} has no required column $column',
          );
        }
      }
    }
    const auxiliaryIndexes = <String, (String, List<String>)>{
      'idx_stt_samples_production_actor': (
        'stt_samples',
        ['production_id', 'actor_id'],
      ),
      'idx_pending_cast_invitations_production': (
        'pending_cast_invitations',
        ['production_id'],
      ),
    };
    for (final entry in auxiliaryIndexes.entries) {
      final shape = await _indexShapeForTable(entry.value.$1, entry.key);
      if (shape == null ||
          shape.unique ||
          !_sameColumns(shape.columns, entry.value.$2)) {
        throw StateError(
          'Auxiliary index ${entry.key} has ${shape?.columns}, '
          'unique=${shape?.unique}; expected ${entry.value.$2}, unique=false',
        );
      }
    }
  }

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) async {
      await migrator.createAll();
      await _ensureAuxiliarySchema();
    },
    onUpgrade: (migrator, from, to) async {
      if (from < 2) {
        await _ensureColumn(
          'productions',
          'locale',
          () => migrator.addColumn(productions, productions.locale),
        );
      }
      if (from < 3) {
        await _ensureColumn(
          'productions',
          'join_code',
          () => migrator.addColumn(productions, productions.joinCode),
        );
      }
      if (from < 4) {
        await _ensureColumn(
          'script_lines',
          'ocr_confidence',
          () => migrator.addColumn(scriptLines, scriptLines.ocrConfidence),
        );
      }
      if (from < 5) {
        await _ensureColumn(
          'script_lines',
          'source_page',
          () => migrator.addColumn(scriptLines, scriptLines.sourcePage),
        );
        await _ensureColumn(
          'script_lines',
          'source_line_on_page',
          () => migrator.addColumn(scriptLines, scriptLines.sourceLineOnPage),
        );
      }
      if (from < 6) {
        await _ensureIndex(
          idxScriptLinesProductionOrder,
          'script_lines',
          const ['production_id', 'order_index'],
          () => migrator.createIndex(idxScriptLinesProductionOrder),
        );
        await _ensureIndex(
          idxScenesProduction,
          'scenes',
          const ['production_id'],
          () => migrator.createIndex(idxScenesProduction),
        );
        await _ensureIndex(
          idxRecordingsProductionLine,
          'recordings',
          const ['production_id', 'script_line_id'],
          () => migrator.createIndex(idxRecordingsProductionLine),
        );
        await _ensureIndex(
          idxCastMembersProduction,
          'cast_members',
          const ['production_id'],
          () => migrator.createIndex(idxCastMembersProduction),
        );
      }
      if (from < 7) {
        await _ensureColumn(
          'script_lines',
          'multi_characters',
          () => migrator.addColumn(scriptLines, scriptLines.multiCharacters),
        );
      }
      // The review branch shipped schema 10 without account_namespace.
      // Main shipped schema 9 with it, then the merge kept version 10.
      // Repair both histories, including devices already on the merged build.
      if (from < 12) {
        await _ensureColumn(
          'productions',
          'account_namespace',
          () => migrator.addColumn(productions, productions.accountNamespace),
        );
        await _ensureIndex(
          idxProductionsAccountCreated,
          'productions',
          const ['account_namespace', 'created_at'],
          () => migrator.createIndex(idxProductionsAccountCreated),
        );
      }
      // The old unscoped branch could cache productions from several users.
      // Do not expose those rows as guest data while waiting for sign-in.
      // Ownership/cast membership is checked when claiming the legacy bucket.
      if (from < 12) {
        await customStatement("""
          UPDATE productions SET account_namespace = '__legacy__'
          WHERE account_namespace = '__guest__'
            AND organizer_id IS NOT NULL
            AND organizer_id NOT IN ('', 'local')
        """);
      }
      await _ensureAuxiliarySchema();
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
      into(productions).insert(entry, mode: InsertMode.insertOrReplace);

  Future<bool> updateProduction(ProductionsCompanion entry) =>
      update(productions).replace(entry);

  Future<int> deleteProduction(String id) =>
      (delete(productions)..where((p) => p.id.equals(id))).go();

  /// Delete the relational graph as one unit. File cleanup deliberately lives
  /// outside this transaction in the repository.
  Future<void> deleteProductionWithRelations(String id) =>
      transaction(() async {
        await deleteRecordingsForProduction(id);
        await deleteScriptLinesForProduction(id);
        await deleteScenesForProduction(id);
        await deleteCastForProduction(id);
        await customUpdate(
          'DELETE FROM production_cloud_creates WHERE production_id = ?',
          variables: [Variable.withString(id)],
        );
        await customUpdate(
          'DELETE FROM pending_cast_invitations WHERE production_id = ?',
          variables: [Variable.withString(id)],
        );
        await customUpdate(
          'DELETE FROM stt_samples WHERE production_id = ?',
          variables: [Variable.withString(id)],
        );
        await customUpdate(
          'DELETE FROM stt_profile_metadata WHERE production_id = ?',
          variables: [Variable.withString(id)],
        );
        await customUpdate(
          'DELETE FROM stt_legacy_migrations WHERE production_id = ?',
          variables: [Variable.withString(id)],
        );
        final deleted = await deleteProduction(id);
        if (deleted != 1) {
          throw StateError(
            'Expected to delete one production $id, deleted $deleted',
          );
        }
      });

  /// Move guest and unclaimed legacy productions into [userId]'s namespace after sign-in.
  /// Claims rows the user organizes, rows they joined as cast, and rows
  /// created signed-out (organizer_id='local'), which cannot match any user
  /// id but belong to whoever signs in on this device.
  Future<void> claimLegacyProductions(String userId) async {
    await transaction(() async {
      await customUpdate(
        '''
          UPDATE productions
          SET account_namespace = ?
          WHERE account_namespace IN ('__guest__', '__legacy__')
            AND (
              organizer_id = ?
              OR organizer_id = 'local'
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

  Future<int> deleteScriptLinesForProduction(String productionId) => (delete(
    scriptLines,
  )..where((l) => l.productionId.equals(productionId))).go();

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

  /// Mark a recording as uploaded only when the immutable local take matches.
  Future<int> markRecordingUploaded(
    String productionId,
    String scriptLineId,
    String remoteUrl, {
    String? expectedRecordingId,
    DateTime? expectedRecordedAt,
  }) =>
      (update(recordings)..where(
            (r) =>
                r.productionId.equals(productionId) &
                r.scriptLineId.equals(scriptLineId) &
                (expectedRecordingId != null
                    ? r.id.equals(expectedRecordingId)
                    : expectedRecordedAt != null
                    ? r.recordedAt.equals(expectedRecordedAt)
                    : const Constant(true)),
          ))
          .write(RecordingsCompanion(remoteUrl: Value(remoteUrl)));

  Future<int> deleteRecordingsForProduction(String productionId) => (delete(
    recordings,
  )..where((r) => r.productionId.equals(productionId))).go();

  Future<int> deleteRecording(String id) =>
      (delete(recordings)..where((r) => r.id.equals(id))).go();

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

  // ── Incremental sync queue persistence ──────────────

  Future<List<SyncQueueRow>> loadSyncQueueRows() async {
    final rows = await customSelect(
      'SELECT queue_key, payload, state, remote_url '
      'FROM sync_queue_jobs ORDER BY updated_at',
    ).get();
    return [
      for (final row in rows)
        SyncQueueRow(
          key: row.read<String>('queue_key'),
          payload: row.read<String>('payload'),
          state: row.read<String>('state'),
          remoteUrl: row.readNullable<String>('remote_url'),
        ),
    ];
  }

  Future<void> upsertSyncQueueRow(SyncQueueRow row) async {
    await customStatement(
      'INSERT INTO sync_queue_jobs '
      '(queue_key, payload, state, remote_url, updated_at) VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(queue_key) DO UPDATE SET payload=excluded.payload, '
      'state=excluded.state, remote_url=excluded.remote_url, '
      'updated_at=excluded.updated_at',
      [
        row.key,
        row.payload,
        row.state,
        row.remoteUrl,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  Future<void> insertSyncQueueRowIfAbsent(SyncQueueRow row) => customStatement(
    'INSERT INTO sync_queue_jobs '
    '(queue_key, payload, state, remote_url, updated_at) VALUES (?, ?, ?, ?, ?) '
    'ON CONFLICT(queue_key) DO NOTHING',
    [
      row.key,
      row.payload,
      row.state,
      row.remoteUrl,
      DateTime.now().millisecondsSinceEpoch,
    ],
  );

  Future<void> deleteSyncQueueRow(String key) async {
    await customUpdate(
      'DELETE FROM sync_queue_jobs WHERE queue_key = ?',
      variables: [Variable.withString(key)],
    );
  }

  Future<void> clearSyncQueueRows() =>
      customStatement('DELETE FROM sync_queue_jobs');

  // ── Production cloud-create outbox ──────────────────

  Future<void> insertProductionWithCloudCreate(
    ProductionsCompanion production,
  ) => transaction(() async {
    await into(
      productions,
    ).insert(production, mode: InsertMode.insertOrReplace);
    await customStatement(
      'INSERT INTO production_cloud_creates '
      '(production_id, status, attempt_count, last_error, updated_at) '
      "VALUES (?, 'pending', 0, NULL, ?) "
      'ON CONFLICT(production_id) DO UPDATE SET status=excluded.status, '
      'last_error=NULL, updated_at=excluded.updated_at',
      [production.id.value, DateTime.now().millisecondsSinceEpoch],
    );
  });

  Future<List<ProductionCloudCreateRow>> loadProductionCloudCreates() async {
    final rows = await customSelect(
      'SELECT production_id, status, attempt_count, last_error '
      'FROM production_cloud_creates ORDER BY updated_at',
    ).get();
    return [
      for (final row in rows)
        ProductionCloudCreateRow(
          productionId: row.read<String>('production_id'),
          status: row.read<String>('status'),
          attemptCount: row.read<int>('attempt_count'),
          lastError: row.readNullable<String>('last_error'),
        ),
    ];
  }

  Future<void> markProductionCloudCreateFailed(
    String productionId,
    Object error,
  ) async {
    final changed = await customUpdate(
      "UPDATE production_cloud_creates SET status = 'failed', "
      'attempt_count = attempt_count + 1, last_error = ?, updated_at = ? '
      'WHERE production_id = ?',
      variables: [
        Variable.withString(error.toString()),
        Variable.withInt(DateTime.now().millisecondsSinceEpoch),
        Variable.withString(productionId),
      ],
    );
    if (changed != 1) {
      throw StateError(
        'No cloud-create outbox row for production $productionId',
      );
    }
  }

  Future<void> markProductionCloudCreateSynced(String productionId) async {
    final changed = await customUpdate(
      'DELETE FROM production_cloud_creates WHERE production_id = ?',
      variables: [Variable.withString(productionId)],
    );
    if (changed != 1) {
      throw StateError(
        'No cloud-create outbox row for production $productionId',
      );
    }
  }

  Future<void> markProductionCloudDeletionPending(String productionId) async {
    await customUpdate(
      "UPDATE production_cloud_creates SET status = 'deleting', "
      'last_error = NULL, updated_at = ? WHERE production_id = ?',
      variables: [
        Variable.withInt(DateTime.now().millisecondsSinceEpoch),
        Variable.withString(productionId),
      ],
    );
  }

  Future<void> resumeProductionCloudCreate(String productionId) async {
    await customUpdate(
      "UPDATE production_cloud_creates SET status = 'pending', "
      'last_error = NULL, updated_at = ? WHERE production_id = ?',
      variables: [
        Variable.withInt(DateTime.now().millisecondsSinceEpoch),
        Variable.withString(productionId),
      ],
    );
  }

  /// Cloud deletion is already committed. Remove any create retry marker even
  /// when it was previously cleared by a successful create.
  Future<void> cancelProductionCloudCreate(String productionId) async {
    await customUpdate(
      'DELETE FROM production_cloud_creates WHERE production_id = ?',
      variables: [Variable.withString(productionId)],
    );
  }

  // ── STT adaptation rows ─────────────────────────────

  Future<List<SttSampleRow>> loadSttSamples(String productionId) async {
    final rows = await customSelect(
      'SELECT production_id, actor_id, audio_path, transcript, duration_ms, '
      'recorded_at FROM stt_samples WHERE production_id = ? '
      'ORDER BY recorded_at',
      variables: [Variable.withString(productionId)],
    ).get();
    return [
      for (final row in rows)
        SttSampleRow(
          productionId: row.read<String>('production_id'),
          actorId: row.read<String>('actor_id'),
          audioPath: row.read<String>('audio_path'),
          transcript: row.read<String>('transcript'),
          durationMs: row.read<int>('duration_ms'),
          recordedAt: DateTime.fromMillisecondsSinceEpoch(
            row.read<int>('recorded_at'),
          ),
        ),
    ];
  }

  Future<List<SttProfileMetadataRow>> loadSttProfileMetadata(
    String productionId,
  ) async {
    final rows = await customSelect(
      'SELECT production_id, actor_id, status, adapter_path, last_trained_at, '
      'word_error_rate FROM stt_profile_metadata WHERE production_id = ?',
      variables: [Variable.withString(productionId)],
    ).get();
    return [
      for (final row in rows)
        SttProfileMetadataRow(
          productionId: row.read<String>('production_id'),
          actorId: row.read<String>('actor_id'),
          status: row.read<String>('status'),
          adapterPath: row.readNullable<String>('adapter_path'),
          lastTrainedAt: _dateFromMilliseconds(
            row.readNullable<int>('last_trained_at'),
          ),
          wordErrorRate: row.readNullable<double>('word_error_rate'),
        ),
    ];
  }

  static DateTime? _dateFromMilliseconds(int? value) =>
      value == null ? null : DateTime.fromMillisecondsSinceEpoch(value);

  Future<void> upsertSttSample(SttSampleRow row) => customStatement(
    'INSERT INTO stt_samples '
    '(production_id, actor_id, audio_path, transcript, duration_ms, recorded_at) '
    'VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(production_id, audio_path) '
    'DO UPDATE SET actor_id=excluded.actor_id, transcript=excluded.transcript, '
    'duration_ms=excluded.duration_ms, recorded_at=excluded.recorded_at',
    [
      row.productionId,
      row.actorId,
      row.audioPath,
      row.transcript,
      row.durationMs,
      row.recordedAt.millisecondsSinceEpoch,
    ],
  );

  Future<void> upsertSttProfileMetadata(
    SttProfileMetadataRow row,
  ) => customStatement(
    'INSERT INTO stt_profile_metadata '
    '(production_id, actor_id, status, adapter_path, last_trained_at, word_error_rate) '
    'VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(production_id, actor_id) '
    'DO UPDATE SET status=excluded.status, adapter_path=excluded.adapter_path, '
    'last_trained_at=excluded.last_trained_at, '
    'word_error_rate=excluded.word_error_rate',
    [
      row.productionId,
      row.actorId,
      row.status,
      row.adapterPath,
      row.lastTrainedAt?.millisecondsSinceEpoch,
      row.wordErrorRate,
    ],
  );

  Future<void> upsertSttSampleWithMetadata(
    SttSampleRow sample,
    List<SttProfileMetadataRow> metadata,
  ) => transaction(() async {
    await upsertSttSample(sample);
    for (final profile in metadata) {
      if (profile.productionId != sample.productionId) {
        throw ArgumentError('STT metadata belongs to another production');
      }
      await upsertSttProfileMetadata(profile);
    }
  });

  Future<void> clearSttAdaptation(String productionId) => transaction(() async {
    await customUpdate(
      'DELETE FROM stt_samples WHERE production_id = ?',
      variables: [Variable.withString(productionId)],
    );
    await customUpdate(
      'DELETE FROM stt_profile_metadata WHERE production_id = ?',
      variables: [Variable.withString(productionId)],
    );
  });

  Future<bool> hasSttLegacyMigration(String productionId) async =>
      (await customSelect(
        'SELECT 1 AS present FROM stt_legacy_migrations '
        'WHERE production_id = ? LIMIT 1',
        variables: [Variable.withString(productionId)],
      ).getSingleOrNull()) !=
      null;

  Future<void> migrateLegacySttProfiles(
    String productionId,
    List<SttSampleRow> samples,
    List<SttProfileMetadataRow> metadata,
  ) => transaction(() async {
    if (await hasSttLegacyMigration(productionId)) return;
    for (final sample in samples) {
      if (sample.productionId != productionId) {
        throw ArgumentError('STT sample belongs to another production');
      }
      await upsertSttSample(sample);
    }
    for (final profile in metadata) {
      if (profile.productionId != productionId) {
        throw ArgumentError('STT metadata belongs to another production');
      }
      await upsertSttProfileMetadata(profile);
    }
    await customStatement(
      'INSERT INTO stt_legacy_migrations (production_id, migrated_at) '
      'VALUES (?, ?)',
      [productionId, DateTime.now().millisecondsSinceEpoch],
    );
  });

  // ── Durable cast invitation outbox ──────────────────

  Future<void> saveCastMembersWithInvitations(
    List<CastMembersCompanion> members,
    List<PendingCastInvitationRow> invitations,
  ) => transaction(() async {
    if (members.length != invitations.length) {
      throw ArgumentError('Each local cast member needs one invitation');
    }
    for (var i = 0; i < members.length; i++) {
      final member = members[i];
      final invitation = invitations[i];
      if (!member.id.present || member.id.value != invitation.localMemberId) {
        throw ArgumentError('Cast member and invitation ids differ');
      }
      await into(castMembers).insert(member, mode: InsertMode.insertOrReplace);
      await _upsertPendingCastInvitation(invitation);
    }
  });

  Future<void> _upsertPendingCastInvitation(
    PendingCastInvitationRow row,
  ) => customStatement(
    'INSERT INTO pending_cast_invitations '
    '(local_member_id, production_id, character_name, display_name, '
    'contact_info, role, created_at, attempt_count, last_error) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) '
    'ON CONFLICT(local_member_id) DO UPDATE SET '
    'character_name=excluded.character_name, display_name=excluded.display_name, '
    'contact_info=excluded.contact_info, role=excluded.role',
    [
      row.localMemberId,
      row.productionId,
      row.characterName,
      row.displayName,
      row.contactInfo,
      row.role,
      row.createdAt.millisecondsSinceEpoch,
      row.attemptCount,
      row.lastError,
    ],
  );

  Future<List<PendingCastInvitationRow>> loadPendingCastInvitations({
    String? productionId,
  }) async {
    final rows = await customSelect(
      'SELECT local_member_id, production_id, character_name, display_name, '
      'contact_info, role, created_at, attempt_count, last_error '
      'FROM pending_cast_invitations '
      '${productionId == null ? '' : 'WHERE production_id = ? '}'
      'ORDER BY created_at',
      variables: productionId == null
          ? const []
          : [Variable.withString(productionId)],
    ).get();
    return [
      for (final row in rows)
        PendingCastInvitationRow(
          localMemberId: row.read<String>('local_member_id'),
          productionId: row.read<String>('production_id'),
          characterName: row.read<String>('character_name'),
          displayName: row.read<String>('display_name'),
          contactInfo: row.readNullable<String>('contact_info'),
          role: row.read<String>('role'),
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            row.read<int>('created_at'),
          ),
          attemptCount: row.read<int>('attempt_count'),
          lastError: row.readNullable<String>('last_error'),
        ),
    ];
  }

  Future<void> markCastInvitationFailed(
    String localMemberId,
    Object error,
  ) async {
    final changed = await customUpdate(
      'UPDATE pending_cast_invitations SET attempt_count = attempt_count + 1, '
      'last_error = ? WHERE local_member_id = ?',
      variables: [
        Variable.withString(error.toString()),
        Variable.withString(localMemberId),
      ],
    );
    if (changed != 1) {
      throw StateError('No pending invitation $localMemberId');
    }
  }

  Future<void> reconcileCastInvitation(
    String localMemberId,
    CastMembersCompanion cloudMember,
  ) => reconcileCastInvitations([localMemberId], [cloudMember]);

  Future<void> reconcileCastInvitations(
    List<String> localMemberIds,
    List<CastMembersCompanion> cloudMembers,
  ) => transaction(() async {
    if (localMemberIds.length != cloudMembers.length) {
      throw ArgumentError('Invitation reconciliation lists differ');
    }
    for (var i = 0; i < localMemberIds.length; i++) {
      final localMemberId = localMemberIds[i];
      await deleteCastMember(localMemberId);
      await into(
        castMembers,
      ).insert(cloudMembers[i], mode: InsertMode.insertOrReplace);
      final changed = await customUpdate(
        'DELETE FROM pending_cast_invitations WHERE local_member_id = ?',
        variables: [Variable.withString(localMemberId)],
      );
      if (changed != 1) {
        throw StateError('No pending invitation $localMemberId');
      }
    }
  });
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
