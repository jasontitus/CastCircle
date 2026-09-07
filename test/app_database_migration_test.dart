import 'dart:io';

import 'package:castcircle/data/database/app_database.dart';
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
