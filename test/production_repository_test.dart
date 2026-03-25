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
