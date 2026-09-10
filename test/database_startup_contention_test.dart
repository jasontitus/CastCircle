import 'dart:io';

import 'package:castcircle/data/database/app_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default database callers share one startup and connection', () {
    final shared = AppDatabase();
    expect(identical(shared, AppDatabase()), isTrue);
    addTearDown(shared.close);
  });

  test('production database setup waits for a transient external lock', () async {
    final dir = await Directory.systemTemp.createTemp(
      'castcircle-startup-lock',
    );
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/database.sqlite');
    final blocker = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(blocker.close);
    await blocker.customStatement(
      "INSERT INTO productions (id, title) VALUES ('keep', 'Existing production')",
    );
    await blocker.customStatement('BEGIN EXCLUSIVE');
    final opening = AppDatabase.forTestingFile(file);
    addTearDown(opening.close);
    final expected = expectLater(
      opening.getAllProductions('__guest__'),
      completion(hasLength(1)),
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await blocker.customStatement('COMMIT');
    await expected;
    await opening.customStatement(
      "INSERT INTO productions (id, title) VALUES ('new', 'New production')",
    );
    expect(
      (await opening.getAllProductions('__guest__')).map((p) => p.id),
      unorderedEquals(['keep', 'new']),
    );
  });
  test(
    'production and sync writes share transactions without losing data',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'castcircle-shared-writes',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/database.sqlite');
      final db = AppDatabase.forTestingFile(file);
      addTearDown(db.close);
      await Future.wait([
        for (var i = 0; i < 20; i++) ...[
          db.transaction(() async {
            await db.customStatement(
              'INSERT INTO productions (id, title) VALUES (?, ?)',
              ['production-$i', 'Production $i'],
            );
            await Future<void>.delayed(const Duration(milliseconds: 2));
          }),
          db.upsertSyncQueueRow(
            SyncQueueRow(key: 'upload-$i', payload: '{}', state: 'pending'),
          ),
        ],
      ]);
      expect(await db.getAllProductions('__guest__'), hasLength(20));
      expect(await db.loadSyncQueueRows(), hasLength(20));
    },
  );
  test(
    'failed production transaction does not roll back concurrent sync writes',
    () async {
      final dir = await Directory.systemTemp.createTemp('castcircle-rollback');
      addTearDown(() => dir.delete(recursive: true));
      final db = AppDatabase.forTestingFile(
        File('${dir.path}/database.sqlite'),
      );
      addTearDown(db.close);
      await db.customStatement(
        "INSERT INTO productions (id, title) VALUES ('keep', 'Existing')",
      );
      final failedWrite = db.transaction(() async {
        await db.customStatement(
          "INSERT INTO productions (id, title) VALUES ('discard', 'Failed')",
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        throw StateError('Injected production failure');
      });
      final failure = expectLater(failedWrite, throwsStateError);
      final sync = db.upsertSyncQueueRow(
        const SyncQueueRow(key: 'keep-upload', payload: '{}', state: 'pending'),
      );
      await Future.wait([failure, sync]);
      expect((await db.getAllProductions('__guest__')).map((p) => p.id), [
        'keep',
      ]);
      expect((await db.loadSyncQueueRows()).map((r) => r.key), ['keep-upload']);
    },
  );
}
