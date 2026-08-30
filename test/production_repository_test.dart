import 'dart:io';

import 'package:castcircle/data/database/app_database.dart' show AppDatabase;
import 'package:castcircle/data/models/cast_member_model.dart';
import 'package:castcircle/data/models/production_models.dart';
import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/repositories/production_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProductionRepository.deleteProduction', () {
    late AppDatabase db;
    late ProductionRepository repository;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repository = ProductionRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('removes recordings, related rows, and local recording files', () async {
      const productionId = 'prod-1';
      final audioFile = File(
        '${Directory.systemTemp.path}/castcircle_delete_test_${DateTime.now().microsecondsSinceEpoch}.m4a',
      );
      await audioFile.writeAsBytes(const [1, 2, 3, 4]);

      await repository.saveProduction(
        Production(
          id: productionId,
          title: 'Hamlet',
          organizerId: 'org-1',
          createdAt: DateTime(2026, 1, 1),
          status: ProductionStatus.draft,
        ),
      );

      await repository.saveScriptLines(productionId, const [
        ScriptLine(
          id: 'line-1',
          act: 'ACT I',
          scene: 'Scene 1',
          lineNumber: 1,
          orderIndex: 1,
          character: 'HAMLET',
          text: 'To be',
          lineType: LineType.dialogue,
        ),
      ]);

      await repository.saveScenes(productionId, const [
        ScriptScene(
          id: 'scene-1',
          act: 'ACT I',
          sceneName: 'Scene 1',
          location: 'Elsinore',
          description: '',
          startLineIndex: 0,
          endLineIndex: 0,
          characters: ['HAMLET'],
        ),
      ]);

      await repository.saveCastMember(
        const CastMemberModel(
          id: 'cast-1',
          productionId: productionId,
          userId: 'user-1',
          characterName: 'HAMLET',
          displayName: 'Actor',
          role: CastRole.primary,
        ),
      );

      await repository.saveRecording(
        productionId,
        Recording(
          id: 'rec-1',
          scriptLineId: 'line-1',
          character: 'HAMLET',
          localPath: audioFile.path,
          durationMs: 1200,
          recordedAt: DateTime(2026, 1, 1),
        ),
      );

      await repository.deleteProduction(productionId);

      expect(await repository.getAllProductions(), isEmpty);
      expect(await repository.getScriptLines(productionId), isEmpty);
      expect(await repository.getScenes(productionId), isEmpty);
      expect(await repository.getCastMembers(productionId), isEmpty);
      expect(await repository.getRecordings(productionId), isEmpty);
      expect(await audioFile.exists(), isFalse);
    });

    test(
      'file cleanup failure does not undo committed relational deletion',
      () async {
        const productionId = 'cleanup-failure';
        final attemptedPaths = <String>[];
        final failingRepository = ProductionRepository(
          db,
          deleteRecordingFile: (path) async {
            attemptedPaths.add(path);
            throw FileSystemException('injected unlink failure', path);
          },
        );
        await failingRepository.saveProduction(
          Production(
            id: productionId,
            title: 'Cleanup',
            organizerId: 'org-1',
            createdAt: DateTime(2026, 1, 1),
            status: ProductionStatus.draft,
          ),
        );
        await failingRepository.saveScriptLines(productionId, const [
          ScriptLine(
            id: 'cleanup-line',
            act: '',
            scene: '',
            lineNumber: 1,
            orderIndex: 1,
            character: 'ACTOR',
            text: 'Line',
            lineType: LineType.dialogue,
          ),
        ]);
        await failingRepository.saveRecording(
          productionId,
          Recording(
            id: 'cleanup-recording',
            scriptLineId: 'cleanup-line',
            character: 'ACTOR',
            localPath: '/recordings/cleanup.m4a',
            durationMs: 500,
            recordedAt: DateTime(2026, 1, 1),
          ),
        );

        await failingRepository.deleteProduction(productionId);

        expect(attemptedPaths, ['/recordings/cleanup.m4a']);
        expect(await failingRepository.getProduction(productionId), isNull);
        expect(await failingRepository.getRecordings(productionId), isEmpty);
      },
    );

    for (final table in const [
      'recordings',
      'script_lines',
      'scenes',
      'cast_members',
      'productions',
    ]) {
      test(
        'failure deleting $table rolls back all relations and keeps files',
        () async {
          final productionId = 'rollback-$table';
          final audioFile = File(
            '${Directory.systemTemp.path}/castcircle_rollback_${table}_${DateTime.now().microsecondsSinceEpoch}.m4a',
          );
          await audioFile.writeAsBytes(const [9, 8, 7]);
          addTearDown(() async {
            if (await audioFile.exists()) await audioFile.delete();
          });
          await repository.saveProduction(
            Production(
              id: productionId,
              title: 'Rollback',
              organizerId: 'org-1',
              createdAt: DateTime(2026, 1, 1),
              status: ProductionStatus.draft,
            ),
          );
          await repository.saveScriptLines(productionId, const [
            ScriptLine(
              id: 'rollback-line',
              act: 'ACT I',
              scene: 'Scene 1',
              lineNumber: 1,
              orderIndex: 1,
              character: 'ACTOR',
              text: 'Keep me',
              lineType: LineType.dialogue,
            ),
          ]);
          await repository.saveScenes(productionId, const [
            ScriptScene(
              id: 'rollback-scene',
              act: 'ACT I',
              sceneName: 'Scene 1',
              location: '',
              description: '',
              startLineIndex: 0,
              endLineIndex: 0,
              characters: ['ACTOR'],
            ),
          ]);
          await repository.saveCastMember(
            CastMemberModel(
              id: 'rollback-cast-$table',
              productionId: productionId,
              userId: 'rollback-user',
              characterName: 'ACTOR',
              displayName: 'Actor',
              role: CastRole.primary,
            ),
          );
          await repository.saveRecording(
            productionId,
            Recording(
              id: 'rollback-recording',
              scriptLineId: 'rollback-line',
              character: 'ACTOR',
              localPath: audioFile.path,
              durationMs: 1000,
              recordedAt: DateTime(2026, 1, 1),
            ),
          );
          await db.customStatement('''
          CREATE TRIGGER fail_${table}_delete
          BEFORE DELETE ON $table
          BEGIN
            SELECT RAISE(ABORT, 'injected $table delete failure');
          END
        ''');

          await expectLater(
            repository.deleteProduction(productionId),
            throwsA(anything),
          );

          expect(
            (await repository.getAllProductions()).single.id,
            productionId,
          );
          expect(await repository.getScriptLines(productionId), hasLength(1));
          expect(await repository.getScenes(productionId), hasLength(1));
          expect(await repository.getCastMembers(productionId), hasLength(1));
          expect(await repository.getRecordings(productionId), hasLength(1));
          expect(await audioFile.exists(), isTrue);
        },
      );
    }

    test('upload stamp requires exactly one affected recording row', () async {
      await expectLater(
        repository.markRecordingUploaded(
          'missing-production',
          'missing-line',
          'https://remote',
        ),
        throwsStateError,
      );
    });

    test('upload stamp cannot overwrite a replacement local take', () async {
      const productionId = 'recording-race';
      await repository.saveProduction(
        Production(
          id: productionId,
          title: 'Hamlet',
          organizerId: 'org-1',
          createdAt: DateTime.utc(2026),
          status: ProductionStatus.draft,
        ),
      );
      await repository.saveRecording(
        productionId,
        Recording(
          id: 'old-take',
          scriptLineId: 'line-1',
          character: 'HAMLET',
          localPath: '/tmp/take.m4a',
          durationMs: 1000,
          recordedAt: DateTime.utc(2026, 1, 1),
        ),
      );
      await repository.saveRecording(
        productionId,
        Recording(
          id: 'new-take',
          scriptLineId: 'line-1',
          character: 'HAMLET',
          localPath: '/tmp/take.m4a',
          durationMs: 2000,
          recordedAt: DateTime.utc(2026, 1, 2),
        ),
      );

      expect(
        await repository.markRecordingUploaded(
          productionId,
          'line-1',
          'https://remote/legacy-old',
          expectedRecordedAt: DateTime.utc(2026, 1, 1),
        ),
        isFalse,
      );
      expect(
        await repository.markRecordingUploaded(
          productionId,
          'line-1',
          'https://remote/old',
          expectedRecordingId: 'old-take',
        ),
        isFalse,
      );
      expect(
        (await repository.getRecordings(productionId)).values.single.remoteUrl,
        isNull,
      );
      expect(
        await repository.markRecordingUploaded(
          productionId,
          'line-1',
          'https://remote/new',
          expectedRecordingId: 'new-take',
        ),
        isTrue,
      );
    });

    test(
      'cloud-create failure remains durable and inspectable for retry',
      () async {
        final file = File(
          '${Directory.systemTemp.path}/castcircle_cloud_outbox_${DateTime.now().microsecondsSinceEpoch}.sqlite',
        );
        var restartDb = AppDatabase.forTesting(NativeDatabase(file));
        var restartRepository = ProductionRepository(restartDb);
        final production = Production(
          id: 'pending-cloud-prod',
          title: 'The Tempest',
          organizerId: 'organizer',
          createdAt: DateTime(2026, 8, 30),
          status: ProductionStatus.draft,
          joinCode: 'ABC123',
        );
        await restartRepository.saveProductionPendingCloudCreate(production);
        await restartRepository.markProductionCloudCreateFailed(
          production.id,
          StateError('offline'),
        );
        await restartDb.close();

        restartDb = AppDatabase.forTesting(NativeDatabase(file));
        restartRepository = ProductionRepository(restartDb);
        var outbox = await restartRepository.getProductionCloudCreates();
        expect(outbox.single.productionId, production.id);
        expect(outbox.single.status, 'failed');
        expect(outbox.single.attemptCount, 1);
        expect(outbox.single.lastError, contains('offline'));
        final restored = await restartRepository.getProduction(production.id);
        expect(restored!.joinCode, 'ABC123');
        expect(restored.title, 'The Tempest');

        await restartRepository.markProductionCloudDeletionPending(
          production.id,
        );
        await restartDb.close();

        restartDb = AppDatabase.forTesting(NativeDatabase(file));
        restartRepository = ProductionRepository(restartDb);
        outbox = await restartRepository.getProductionCloudCreates();
        expect(outbox.single.status, 'deleting');

        await restartRepository.resumeProductionCloudCreate(production.id);
        outbox = await restartRepository.getProductionCloudCreates();
        expect(outbox.single.status, 'pending');

        await restartRepository.markProductionCloudDeletionPending(
          production.id,
        );
        await restartRepository.cancelProductionCloudCreate(production.id);
        expect(await restartRepository.getProductionCloudCreates(), isEmpty);
        expect(await restartRepository.getProduction(production.id), isNotNull);
        await restartDb.close();
        await file.delete();
      },
    );

    test('does not delete another production or its recording', () async {
      final keepFile = File(
        '${Directory.systemTemp.path}/castcircle_keep_test_${DateTime.now().microsecondsSinceEpoch}.m4a',
      );
      await keepFile.writeAsBytes(const [5, 6, 7]);

      await repository.saveProduction(
        Production(
          id: 'delete-me',
          title: 'Macbeth',
          organizerId: 'org-1',
          createdAt: DateTime(2026, 1, 1),
          status: ProductionStatus.draft,
        ),
      );
      await repository.saveProduction(
        Production(
          id: 'keep-me',
          title: 'Lear',
          organizerId: 'org-2',
          createdAt: DateTime(2026, 1, 2),
          status: ProductionStatus.draft,
        ),
      );

      await repository.saveScriptLines('keep-me', const [
        ScriptLine(
          id: 'keep-line',
          act: 'ACT I',
          scene: '',
          lineNumber: 1,
          orderIndex: 1,
          character: 'LEAR',
          text: 'Attend the lords',
          lineType: LineType.dialogue,
        ),
      ]);

      await repository.saveRecording(
        'keep-me',
        Recording(
          id: 'keep-rec',
          scriptLineId: 'keep-line',
          character: 'LEAR',
          localPath: keepFile.path,
          durationMs: 900,
          recordedAt: DateTime(2026, 1, 2),
        ),
      );

      await repository.deleteProduction('delete-me');

      final productions = await repository.getAllProductions();
      expect(productions.map((p) => p.id), contains('keep-me'));
      expect(await repository.getRecordings('keep-me'), isNotEmpty);
      expect(await keepFile.exists(), isTrue);

      await keepFile.delete();
    });
  });
}
