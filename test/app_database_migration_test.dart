import 'dart:io';

import 'package:castcircle/data/database/app_database.dart';
import 'package:castcircle/data/models/production_models.dart' as models;
import 'package:castcircle/data/repositories/production_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('database_migration_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  AppDatabase open(File file) =>
      AppDatabase.forTesting(NativeDatabase(file, logStatements: false));

  Future<List<String>> indexColumns(AppDatabase db, String indexName) async {
    final rows = await db.customSelect('PRAGMA index_info("$indexName")').get();
    rows.sort((a, b) => a.read<int>('seqno').compareTo(b.read<int>('seqno')));
    return rows.map((row) => row.read<String>('name')).toList();
  }

  for (final previousVersion in [9, 10, 11]) {
    test(
      'v$previousVersion preserves assigned accounts, script data, and repeated opens',
      () async {
        final file = File('${tempDir.path}/assigned-$previousVersion.sqlite');
        var db = open(file);
        await db.customStatement(
          "INSERT INTO productions (id, title, organizer_id, account_namespace, created_at) "
          "VALUES ('alice', 'Alice script', 'alice', 'alice', 1700000000), "
          "('bob', 'Bob script', 'bob', 'bob', 1700000000), "
          "('joined', 'Joined script', 'other-owner', '__guest__', 1700000000)",
        );
        await db.customStatement(
          "INSERT INTO script_lines (id, production_id, line_number, order_index, line_text, line_type) "
          "VALUES ('line', 'alice', 1, 0, 'Keep this dialogue.', 'dialogue')",
        );
        await db.customStatement(
          "INSERT INTO cast_members (id, production_id, user_id, character_name, role) "
          "VALUES ('member', 'joined', 'alice', 'CALVIN', 'primary')",
        );
        await db.customStatement('PRAGMA user_version = $previousVersion');
        await db.close();
        for (var attempt = 0; attempt < 2; attempt++) {
          db = open(file);
          expect(await db.getAllProductions('__guest__'), isEmpty);
          await db.claimLegacyProductions('alice');
          expect(
            (await db.getAllProductions('alice')).map((p) => p.id),
            unorderedEquals(['alice', 'joined']),
          );
          expect((await db.getAllProductions('bob')).single.id, 'bob');
          expect(
            (await db.getScriptLines('alice')).single.lineText,
            'Keep this dialogue.',
          );
          await db.close();
        }
      },
    );
  }

  test('bad namespace index does not advance version or erase rows', () async {
    final file = File('${tempDir.path}/namespace-index-failure.sqlite');
    var db = open(file);
    await db.customStatement(
      "INSERT INTO productions (id, title) VALUES ('keep', 'Keep me')",
    );
    await db.customStatement('DROP INDEX idx_productions_account_created');
    await db.customStatement(
      'CREATE INDEX idx_productions_account_created ON productions (title)',
    );
    await db.customStatement('PRAGMA user_version = 10');
    await db.close();
    db = open(file);
    await expectLater(db.getAllProductions('__guest__'), throwsStateError);
    await db.close();
    int? observedVersion;
    db = AppDatabase.forTesting(
      NativeDatabase(
        file,
        setup: (raw) {
          observedVersion = raw.userVersion;
          raw.execute('DROP INDEX idx_productions_account_created');
        },
      ),
    );
    addTearDown(db.close);
    expect((await db.getAllProductions('__guest__')).single.id, 'keep');
    expect(observedVersion, 10);
    expect(await indexColumns(db, 'idx_productions_account_created'), [
      'account_namespace',
      'created_at',
    ]);
  });

  test(
    'migration does not expose legacy account rows to a guest or another user',
    () async {
      final file = File('${tempDir.path}/legacy-accounts.sqlite');
      var db = open(file);
      for (final row in [
        ['guest', 'local'],
        ['alice', 'alice'],
        ['bob', 'bob'],
      ]) {
        await db.customStatement(
          'INSERT INTO productions (id, title, organizer_id, created_at) VALUES (?, ?, ?, ?)',
          [row[0], row[0], row[1], 1700000000],
        );
      }
      await db.customStatement('DROP INDEX idx_productions_account_created');
      await db.customStatement(
        'ALTER TABLE productions DROP COLUMN account_namespace',
      );
      await db.customStatement('PRAGMA user_version = 10');
      await db.close();
      db = open(file);
      addTearDown(db.close);
      expect((await db.getAllProductions('__guest__')).map((p) => p.id), [
        'guest',
      ]);
      await db.claimLegacyProductions('alice');
      expect(
        (await db.getAllProductions('alice')).map((p) => p.id),
        unorderedEquals(['guest', 'alice']),
      );
      expect(await db.getAllProductions('__guest__'), isEmpty);
      await db.claimLegacyProductions('bob');
      expect((await db.getAllProductions('bob')).map((p) => p.id), ['bob']);
    },
  );

  for (final previousVersion in [9, 10, 11]) {
    test(
      'repairs branch schema v$previousVersion without losing productions',
      () async {
        final file = File('${tempDir.path}/branch-$previousVersion.sqlite');
        var db = open(file);
        await db.customStatement(
          "INSERT INTO productions (id, title, organizer_id, created_at) "
          "VALUES ('existing', 'Existing script', 'local', 1700000000)",
        );
        await db.customStatement('DROP INDEX idx_productions_account_created');
        await db.customStatement(
          'ALTER TABLE productions DROP COLUMN account_namespace',
        );
        await db.customStatement('PRAGMA user_version = $previousVersion');
        await db.close();

        db = open(file);
        addTearDown(db.close);
        final guest = ProductionRepository(db);
        expect((await guest.getAllProductions()).single.id, 'existing');
        await guest.saveProduction(
          models.Production(
            id: 'guest-new',
            title: 'Guest production',
            organizerId: 'local',
            createdAt: DateTime.now(),
            status: models.ProductionStatus.draft,
          ),
        );
        final signedIn = ProductionRepository(db, accountNamespace: 'user-1');
        await signedIn.saveProductionPendingCloudCreate(
          models.Production(
            id: 'cloud-new',
            title: 'Cloud production',
            organizerId: 'user-1',
            createdAt: DateTime.now(),
            status: models.ProductionStatus.draft,
          ),
        );
        expect(
          (await guest.getAllProductions()).map((p) => p.id),
          unorderedEquals(['existing', 'guest-new']),
        );
        expect((await signedIn.getAllProductions()).single.id, 'cloud-new');
        expect(
          (await signedIn.getProductionCloudCreates()).single.productionId,
          'cloud-new',
        );
        expect(await indexColumns(db, 'idx_productions_account_created'), [
          'account_namespace',
          'created_at',
        ]);
        final version = await db
            .customSelect('PRAGMA user_version')
            .getSingle();
        expect(version.read<int>('user_version'), db.schemaVersion);
      },
    );
  }

  test(
    'already-applied migration targets advance only after verification',
    () async {
      final file = File('${tempDir.path}/partial.sqlite');
      var db = open(file);
      await db.getAllProductions('__guest__');
      await db.customStatement('PRAGMA user_version = 1');
      await db.close();

      db = open(file);
      await db.getAllProductions('__guest__');
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);
      expect(await indexColumns(db, 'idx_script_lines_production_order'), [
        'production_id',
        'order_index',
      ]);
      final queueColumns = await db
          .customSelect('PRAGMA table_info("sync_queue_jobs")')
          .get();
      expect(
        queueColumns.map((row) => row.read<String>('name')),
        containsAll(['queue_key', 'payload', 'state', 'remote_url']),
      );
      await db.close();
    },
  );

  test('missing prior index is recreated with its exact structure', () async {
    final file = File('${tempDir.path}/missing-index.sqlite');
    var db = open(file);
    await db.getAllProductions('__guest__');
    await db.customStatement('DROP INDEX idx_recordings_production_line');
    await db.customStatement('PRAGMA user_version = 5');
    await db.close();

    db = open(file);
    await db.getAllProductions('__guest__');
    expect(await indexColumns(db, 'idx_recordings_production_line'), [
      'production_id',
      'script_line_id',
    ]);
    await db.close();
  });

  test('same index name with a wrong definition aborts the upgrade', () async {
    final file = File('${tempDir.path}/wrong-index.sqlite');
    var db = open(file);
    await db.getAllProductions('__guest__');
    await db.customStatement('DROP INDEX idx_recordings_production_line');
    await db.customStatement(
      'CREATE INDEX idx_recordings_production_line '
      'ON recordings (script_line_id)',
    );
    await db.customStatement('PRAGMA user_version = 5');
    await db.close();

    db = open(file);
    await expectLater(db.getAllProductions('__guest__'), throwsStateError);
    await db.close();
  });
}
