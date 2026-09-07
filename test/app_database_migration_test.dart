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

  for (final previousVersion in [9, 10]) {
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
