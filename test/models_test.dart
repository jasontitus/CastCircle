import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/models/production_models.dart';
import 'package:castcircle/data/models/rehearsal_models.dart';

void main() {
  group('ScriptLine', () {
    test('toJson and fromJson round-trip correctly', () {
      const line = ScriptLine(
        id: 'line-1',
        act: 'ACT I',
        scene: 'Ball',
        lineNumber: 5,
        orderIndex: 10,
        character: 'ELIZABETH',
        text: 'What a fine assembly tonight.',
        lineType: LineType.dialogue,
        stageDirection: 'Looking around',
      );

      final json = line.toJson();
      final restored = ScriptLine.fromJson(json);

      expect(restored.id, line.id);
      expect(restored.act, line.act);
      expect(restored.scene, line.scene);
      expect(restored.lineNumber, line.lineNumber);
      expect(restored.orderIndex, line.orderIndex);
      expect(restored.character, line.character);
      expect(restored.text, line.text);
      expect(restored.lineType, line.lineType);
      expect(restored.stageDirection, line.stageDirection);
    });

    test('fromJson handles missing optional fields', () {
      final json = {
        'id': 'line-2',
        'line_number': 1,
        'order_index': 1,
        'text': 'Hello.',
        'line_type': 'dialogue',
      };

      final line = ScriptLine.fromJson(json);
      expect(line.act, '');
      expect(line.scene, '');
      expect(line.character, '');
      expect(line.stageDirection, '');
    });

    test('copyWith creates modified copy', () {
      const original = ScriptLine(
        id: 'line-1',
        act: 'ACT I',
        scene: '',
        lineNumber: 1,
        orderIndex: 1,
        character: 'DARCY',
        text: 'Original text.',
        lineType: LineType.dialogue,
      );

      final modified = original.copyWith(
        text: 'Modified text.',
        character: 'BINGLEY',
      );

      expect(modified.text, 'Modified text.');
      expect(modified.character, 'BINGLEY');
      expect(modified.id, 'line-1'); // unchanged
      expect(modified.act, 'ACT I'); // unchanged
    });
  });

  group('ScriptScene', () {
    test('toJson and fromJson round-trip correctly', () {
      const scene = ScriptScene(
        id: 'scene-1',
        act: 'ACT I',
        sceneName: 'ACT I, Scene 1',
        location: 'Longbourn',
        description: 'The Bennet household',
        startLineIndex: 0,
        endLineIndex: 15,
        characters: ['ELIZABETH', 'MR. BENNET', 'MRS. BENNET'],
      );

      final json = scene.toJson();
      final restored = ScriptScene.fromJson(json);

      expect(restored.id, scene.id);
      expect(restored.act, scene.act);
      expect(restored.sceneName, scene.sceneName);
      expect(restored.location, scene.location);
      expect(restored.description, scene.description);
      expect(restored.startLineIndex, scene.startLineIndex);
      expect(restored.endLineIndex, scene.endLineIndex);
      expect(restored.characters, scene.characters);
    });

    test('displayLabel includes location when present', () {
      const scene = ScriptScene(
        id: 's1',
        act: 'ACT I',
        sceneName: 'ACT I, Scene 1',
        location: 'Longbourn',
        description: '',
        startLineIndex: 0,
        endLineIndex: 5,
        characters: [],
      );

      expect(scene.displayLabel, 'ACT I, Scene 1 — Longbourn');
    });

    test('displayLabel omits dash when location is empty', () {
      const scene = ScriptScene(
        id: 's1',
        act: 'ACT I',
        sceneName: 'ACT I, Scene 1',
        location: '',
        description: '',
        startLineIndex: 0,
        endLineIndex: 5,
        characters: [],
      );

      expect(scene.displayLabel, 'ACT I, Scene 1');
      expect(scene.displayLabel.contains('—'), isFalse);
    });

    test('copyWith preserves unchanged fields', () {
      const scene = ScriptScene(
        id: 's1',
        act: 'ACT I',
        sceneName: 'Scene 1',
        location: 'Longbourn',
        description: 'Opening',
        startLineIndex: 0,
        endLineIndex: 10,
        characters: ['ELIZABETH'],
      );

      final modified = scene.copyWith(location: 'Netherfield');
      expect(modified.location, 'Netherfield');
      expect(modified.sceneName, 'Scene 1');
      expect(modified.characters, ['ELIZABETH']);
    });
  });

  group('Recording', () {
    test('copyWith works correctly', () {
      final recording = Recording(
        id: 'rec-1',
        scriptLineId: 'line-1',
        character: 'DARCY',
        localPath: '/audio/rec1.m4a',
        durationMs: 5000,
        recordedAt: DateTime(2026, 1, 1),
      );

      final withUrl = recording.copyWith(
        remoteUrl: 'https://storage.example.com/rec1.m4a',
      );

      expect(withUrl.remoteUrl, 'https://storage.example.com/rec1.m4a');
      expect(withUrl.localPath, '/audio/rec1.m4a'); // unchanged
      expect(withUrl.character, 'DARCY'); // unchanged
    });

    test('remoteUrl is null by default', () {
      final recording = Recording(
        id: 'rec-1',
        scriptLineId: 'line-1',
        character: 'DARCY',
        localPath: '/audio/rec1.m4a',
        durationMs: 5000,
        recordedAt: DateTime(2026, 1, 1),
      );

      expect(recording.remoteUrl, isNull);
    });
  });

  group('ParsedScript', () {
    final lines = [
      const ScriptLine(
        id: 'h1', act: 'ACT I', scene: '', lineNumber: 0,
        orderIndex: 1, character: '', text: 'ACT I', lineType: LineType.header,
      ),
      const ScriptLine(
        id: 'l1', act: 'ACT I', scene: '', lineNumber: 1,
        orderIndex: 2, character: 'ELIZABETH', text: 'Hello.',
        lineType: LineType.dialogue,
      ),
      const ScriptLine(
        id: 'l2', act: 'ACT I', scene: '', lineNumber: 2,
        orderIndex: 3, character: 'DARCY', text: 'Good day.',
        lineType: LineType.dialogue,
      ),
      const ScriptLine(
        id: 'l3', act: 'ACT I', scene: '', lineNumber: 3,
        orderIndex: 4, character: 'ELIZABETH', text: 'Goodbye.',
        lineType: LineType.dialogue,
      ),
      const ScriptLine(
        id: 'h2', act: 'ACT II', scene: '', lineNumber: 0,
        orderIndex: 5, character: '', text: 'ACT II', lineType: LineType.header,
      ),
      const ScriptLine(
        id: 'l4', act: 'ACT II', scene: '', lineNumber: 1,
        orderIndex: 6, character: 'DARCY', text: 'I love you.',
        lineType: LineType.dialogue,
      ),
    ];

    final scenes = [
      const ScriptScene(
        id: 's1', act: 'ACT I', sceneName: 'Scene 1', location: '',
        description: '', startLineIndex: 0, endLineIndex: 3,
        characters: ['DARCY', 'ELIZABETH'],
      ),
      const ScriptScene(
        id: 's2', act: 'ACT II', sceneName: 'Scene 2', location: '',
        description: '', startLineIndex: 4, endLineIndex: 5,
        characters: ['DARCY'],
      ),
    ];

    final script = ParsedScript(
      title: 'Test',
      lines: lines,
      characters: const [
        ScriptCharacter(name: 'ELIZABETH', colorIndex: 0, lineCount: 2),
        ScriptCharacter(name: 'DARCY', colorIndex: 1, lineCount: 2),
      ],
      scenes: scenes,
      rawText: '',
    );

    test('linesForCharacter filters correctly', () {
      final elizLines = script.linesForCharacter('ELIZABETH');
      expect(elizLines.length, 2);
      expect(elizLines.every((l) => l.character == 'ELIZABETH'), isTrue);
    });

    test('linesForCharacter returns empty for unknown character', () {
      expect(script.linesForCharacter('BINGLEY'), isEmpty);
    });

    test('linesInScene returns correct range', () {
      final sceneLines = script.linesInScene(scenes[0]);
      expect(sceneLines.length, 4);
    });

    test('linesInScene returns empty for out-of-range scene', () {
      const badScene = ScriptScene(
        id: 'bad', act: '', sceneName: '', location: '',
        description: '', startLineIndex: -1, endLineIndex: 100,
        characters: [],
      );
      expect(script.linesInScene(badScene), isEmpty);
    });

    test('linesInAct filters by act', () {
      final act1 = script.linesInAct('ACT I');
      expect(act1.length, 4);
      final act2 = script.linesInAct('ACT II');
      expect(act2.length, 2);
    });

    test('scenesForCharacter filters correctly', () {
      final darcyScenes = script.scenesForCharacter('DARCY');
      expect(darcyScenes.length, 2);

      final elizScenes = script.scenesForCharacter('ELIZABETH');
      expect(elizScenes.length, 1);
    });

    test('acts returns unique act names in order', () {
      expect(script.acts, ['ACT I', 'ACT II']);
    });
  });

  group('Production', () {
    test('copyWith preserves unchanged fields', () {
      final production = Production(
        id: 'prod-1',
        title: 'Pride & Prejudice',
        organizerId: 'user-1',
        createdAt: DateTime(2026, 1, 1),
        status: ProductionStatus.draft,
      );

      final updated = production.copyWith(
        status: ProductionStatus.scriptImported,
      );

      expect(updated.status, ProductionStatus.scriptImported);
      expect(updated.title, 'Pride & Prejudice');
      expect(updated.id, 'prod-1');
    });

    test('ProductionStatus has all expected states', () {
      expect(ProductionStatus.values.length, 6);
      expect(ProductionStatus.values, containsAll([
        ProductionStatus.draft,
        ProductionStatus.scriptImported,
        ProductionStatus.scriptApproved,
        ProductionStatus.castAssigned,
        ProductionStatus.recording,
        ProductionStatus.ready,
      ]));
    });
  });

  group('RehearsalSession', () {
    test('creates with all fields', () {
      final session = RehearsalSession(
        id: 'session-1',
        productionId: 'prod-1',
        sceneId: 'scene-1',
        sceneName: 'ACT I, Scene 1',
        character: 'ELIZABETH',
        startedAt: DateTime(2026, 1, 1, 10, 0),
        endedAt: DateTime(2026, 1, 1, 10, 15),
        totalLines: 20,
        completedLines: 18,
        averageMatchScore: 0.85,
        lineAttempts: [],
        rehearsalMode: 'sceneReadthrough',
      );

      expect(session.character, 'ELIZABETH');
      expect(session.totalLines, 20);
      expect(session.completedLines, 18);
      expect(session.averageMatchScore, 0.85);
    });
  });

  group('LineAttempt', () {
    test('stores attempt data', () {
      final attempt = LineAttempt(
        lineId: 'line-1',
        lineText: 'You are very punctual I see.',
        attemptCount: 2,
        bestScore: 0.92,
        skipped: false,
      );

      expect(attempt.lineId, 'line-1');
      expect(attempt.attemptCount, 2);
      expect(attempt.bestScore, 0.92);
      expect(attempt.skipped, isFalse);
    });
  });
}
