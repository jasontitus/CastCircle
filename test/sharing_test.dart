import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/models/production_models.dart';
import 'package:castcircle/data/models/cast_member_model.dart';
import 'package:castcircle/data/services/supabase_service.dart';
import 'package:castcircle/features/script_editor/cloud_sync_dialog.dart';
import 'package:castcircle/providers/production_providers.dart';

// ── Helpers ──────────────────────────────────────────────

ScriptLine _line({
  String id = '',
  String act = 'ACT I',
  String scene = '',
  int lineNumber = 1,
  int orderIndex = 0,
  String character = 'ELIZABETH',
  String text = 'Hello.',
  LineType lineType = LineType.dialogue,
  String stageDirection = '',
}) =>
    ScriptLine(
      id: id,
      act: act,
      scene: scene,
      lineNumber: lineNumber,
      orderIndex: orderIndex,
      character: character,
      text: text,
      lineType: lineType,
      stageDirection: stageDirection,
    );

void main() {
  // ── buildParsedScript ──────────────────────────────────

  group('buildParsedScript', () {
    test('builds characters sorted by line count descending', () {
      final lines = [
        _line(id: '1', character: 'DARCY', text: 'Line 1', orderIndex: 0),
        _line(id: '2', character: 'ELIZABETH', text: 'Line 2', orderIndex: 1),
        _line(id: '3', character: 'ELIZABETH', text: 'Line 3', orderIndex: 2),
        _line(id: '4', character: 'ELIZABETH', text: 'Line 4', orderIndex: 3),
        _line(id: '5', character: 'DARCY', text: 'Line 5', orderIndex: 4),
      ];

      final script = buildParsedScript('Test', lines);

      expect(script.characters.length, 2);
      expect(script.characters[0].name, 'ELIZABETH');
      expect(script.characters[0].lineCount, 3);
      expect(script.characters[1].name, 'DARCY');
      expect(script.characters[1].lineCount, 2);
    });

    test('assigns sequential colorIndex to characters', () {
      final lines = [
        _line(id: '1', character: 'A', text: 'a', orderIndex: 0),
        _line(id: '2', character: 'B', text: 'b', orderIndex: 1),
        _line(id: '3', character: 'C', text: 'c', orderIndex: 2),
      ];

      final script = buildParsedScript('Test', lines);

      for (var i = 0; i < script.characters.length; i++) {
        expect(script.characters[i].colorIndex, i);
      }
    });

    test('ignores non-dialogue lines for character counts', () {
      final lines = [
        _line(
            id: '1',
            character: '',
            text: 'ACT I',
            lineType: LineType.header,
            orderIndex: 0),
        _line(id: '2', character: 'ELIZABETH', text: 'Hello.', orderIndex: 1),
        _line(
            id: '3',
            character: '',
            text: '(exits)',
            lineType: LineType.stageDirection,
            orderIndex: 2),
      ];

      final script = buildParsedScript('Test', lines);

      expect(script.characters.length, 1);
      expect(script.characters[0].name, 'ELIZABETH');
      expect(script.characters[0].lineCount, 1);
    });

    test('builds scenes from act/scene tags', () {
      final lines = [
        _line(
            id: '1',
            act: 'ACT I',
            scene: 'Ball',
            character: 'ELIZABETH',
            text: 'a',
            orderIndex: 0),
        _line(
            id: '2',
            act: 'ACT I',
            scene: 'Ball',
            character: 'DARCY',
            text: 'b',
            orderIndex: 1),
        _line(
            id: '3',
            act: 'ACT II',
            scene: 'Garden',
            character: 'ELIZABETH',
            text: 'c',
            orderIndex: 2),
      ];

      final script = buildParsedScript('Test', lines);

      expect(script.scenes.length, 2);
      expect(script.scenes[0].act, 'ACT I');
      expect(script.scenes[0].characters, contains('ELIZABETH'));
      expect(script.scenes[0].characters, contains('DARCY'));
      expect(script.scenes[1].act, 'ACT II');
      expect(script.scenes[1].characters, contains('ELIZABETH'));
    });

    test('handles empty lines list', () {
      final script = buildParsedScript('Empty', []);

      expect(script.characters, isEmpty);
      expect(script.scenes, isEmpty);
      expect(script.lines, isEmpty);
    });

    test('preserves all lines in output', () {
      final lines = List.generate(
          50,
          (i) =>
              _line(id: '$i', character: 'CHAR', text: 'Line $i', orderIndex: i));

      final script = buildParsedScript('Big', lines);
      expect(script.lines.length, 50);
    });

    test('sets title correctly', () {
      final script = buildParsedScript('My Production', [
        _line(id: '1', character: 'A', text: 'hi', orderIndex: 0),
      ]);
      expect(script.title, 'My Production');
    });
  });

  // ── diffScriptLines ────────────────────────────────────

  group('diffScriptLines', () {
    test('identical scripts produce all unchanged', () {
      final lines = [
        _line(id: '1', character: 'A', text: 'Hello'),
        _line(id: '2', character: 'B', text: 'World'),
      ];

      final diffs = diffScriptLines(lines, lines);

      expect(diffs.length, 2);
      expect(diffs.every((d) => d.type == DiffType.unchanged), isTrue);
    });

    test('detects added lines in cloud', () {
      final local = [
        _line(id: '1', character: 'A', text: 'Hello'),
      ];
      final cloud = [
        _line(id: '1', character: 'A', text: 'Hello'),
        _line(id: '2', character: 'B', text: 'New line'),
      ];

      final diffs = diffScriptLines(local, cloud);

      expect(diffs.length, 2);
      expect(diffs[0].type, DiffType.unchanged);
      expect(diffs[1].type, DiffType.added);
      expect(diffs[1].cloud!.text, 'New line');
    });

    test('detects removed lines from cloud', () {
      final local = [
        _line(id: '1', character: 'A', text: 'Hello'),
        _line(id: '2', character: 'B', text: 'Goodbye'),
      ];
      final cloud = [
        _line(id: '1', character: 'A', text: 'Hello'),
      ];

      final diffs = diffScriptLines(local, cloud);

      expect(diffs.length, 2);
      expect(diffs[0].type, DiffType.unchanged);
      expect(diffs[1].type, DiffType.removed);
      expect(diffs[1].local!.text, 'Goodbye');
    });

    test('detects changed text', () {
      final local = [
        _line(id: '1', character: 'A', text: 'Original'),
      ];
      final cloud = [
        _line(id: '1', character: 'A', text: 'Modified'),
      ];

      final diffs = diffScriptLines(local, cloud);

      expect(diffs.length, 1);
      expect(diffs[0].type, DiffType.changed);
      expect(diffs[0].local!.text, 'Original');
      expect(diffs[0].cloud!.text, 'Modified');
    });

    test('detects changed character', () {
      final local = [
        _line(id: '1', character: 'A', text: 'Hello'),
      ];
      final cloud = [
        _line(id: '1', character: 'B', text: 'Hello'),
      ];

      final diffs = diffScriptLines(local, cloud);

      expect(diffs[0].type, DiffType.changed);
    });

    test('detects changed lineType', () {
      final local = [
        _line(id: '1', character: 'A', text: 'Hello', lineType: LineType.dialogue),
      ];
      final cloud = [
        _line(
            id: '1',
            character: 'A',
            text: 'Hello',
            lineType: LineType.stageDirection),
      ];

      final diffs = diffScriptLines(local, cloud);

      expect(diffs[0].type, DiffType.changed);
    });

    test('detects changed stageDirection', () {
      final local = [
        _line(id: '1', character: 'A', text: 'Hello', stageDirection: ''),
      ];
      final cloud = [
        _line(
            id: '1',
            character: 'A',
            text: 'Hello',
            stageDirection: '(laughing)'),
      ];

      final diffs = diffScriptLines(local, cloud);

      expect(diffs[0].type, DiffType.changed);
    });

    test('handles both empty', () {
      final diffs = diffScriptLines([], []);
      expect(diffs, isEmpty);
    });

    test('handles local empty, cloud has lines', () {
      final cloud = [
        _line(id: '1', character: 'A', text: 'New'),
      ];

      final diffs = diffScriptLines([], cloud);

      expect(diffs.length, 1);
      expect(diffs[0].type, DiffType.added);
    });

    test('handles cloud empty, local has lines', () {
      final local = [
        _line(id: '1', character: 'A', text: 'Deleted'),
      ];

      final diffs = diffScriptLines(local, []);

      expect(diffs.length, 1);
      expect(diffs[0].type, DiffType.removed);
    });

    test('complex diff with mixed changes', () {
      final local = [
        _line(id: '1', character: 'A', text: 'Same'),
        _line(id: '2', character: 'B', text: 'Changed'),
        _line(id: '3', character: 'C', text: 'Removed'),
      ];
      final cloud = [
        _line(id: '1', character: 'A', text: 'Same'),
        _line(id: '2', character: 'B', text: 'Modified'),
        _line(id: '4', character: 'D', text: 'Added'),
      ];

      final diffs = diffScriptLines(local, cloud);

      expect(diffs.length, 3);
      expect(diffs[0].type, DiffType.unchanged);
      expect(diffs[1].type, DiffType.changed);
      expect(diffs[2].type, DiffType.changed); // position-based: C→D is a change
    });
  });

  // ── Join code generation ───────────────────────────────

  group('Join code generation (extended)', () {
    test('codes are always uppercase', () {
      for (var i = 0; i < 50; i++) {
        final code = SupabaseService.generateJoinCode();
        expect(code, equals(code.toUpperCase()));
      }
    });

    test('codes contain no whitespace', () {
      for (var i = 0; i < 50; i++) {
        final code = SupabaseService.generateJoinCode();
        expect(code.contains(RegExp(r'\s')), false);
      }
    });

    test('codes are exactly 6 alphanumeric characters', () {
      for (var i = 0; i < 50; i++) {
        final code = SupabaseService.generateJoinCode();
        expect(code, matches(RegExp(r'^[A-Z0-9]{6}$')));
      }
    });
  });

  // ── Production sharing model ───────────────────────────

  group('Production sharing model', () {
    test('production with join code preserves it through copyWith', () {
      final prod = Production(
        id: 'p1',
        title: 'Hamlet',
        organizerId: 'user-1',
        createdAt: DateTime(2026, 1, 1),
        status: ProductionStatus.draft,
        joinCode: 'ABC123',
      );

      final updated = prod.copyWith(status: ProductionStatus.castAssigned);
      expect(updated.joinCode, 'ABC123');
      expect(updated.status, ProductionStatus.castAssigned);
    });

    test('production locale defaults to en-US', () {
      final prod = Production(
        id: 'p1',
        title: 'Test',
        organizerId: 'user-1',
        createdAt: DateTime.now(),
        status: ProductionStatus.draft,
      );

      expect(prod.locale, 'en-US');
    });

    test('production locale can be set to en-GB', () {
      final prod = Production(
        id: 'p1',
        title: 'Test',
        organizerId: 'user-1',
        createdAt: DateTime.now(),
        status: ProductionStatus.draft,
        locale: 'en-GB',
      );

      expect(prod.locale, 'en-GB');
    });
  });

  // ── Cast member sharing workflow ───────────────────────

  group('Cast member sharing workflow', () {
    test('invitation to claim lifecycle', () {
      // Organizer creates invitation
      final invitation = CastMemberModel(
        id: 'cm-1',
        productionId: 'prod-1',
        characterName: 'HAMLET',
        displayName: 'John',
        role: CastRole.primary,
        invitedAt: DateTime(2026, 3, 1),
      );

      expect(invitation.hasJoined, false);
      expect(invitation.userId, null);

      // Actor claims invitation
      final claimed = invitation.copyWith(
        userId: 'user-42',
        joinedAt: DateTime(2026, 3, 5),
      );

      expect(claimed.hasJoined, true);
      expect(claimed.userId, 'user-42');
      expect(claimed.characterName, 'HAMLET');
      expect(claimed.role, CastRole.primary);
    });

    test('multiple characters for same production', () {
      const members = [
        CastMemberModel(
          id: 'cm-1',
          productionId: 'prod-1',
          userId: 'user-1',
          characterName: 'HAMLET',
          displayName: 'John',
          role: CastRole.primary,
        ),
        CastMemberModel(
          id: 'cm-2',
          productionId: 'prod-1',
          userId: 'user-2',
          characterName: 'OPHELIA',
          displayName: 'Jane',
          role: CastRole.primary,
        ),
        CastMemberModel(
          id: 'cm-3',
          productionId: 'prod-1',
          userId: 'user-3',
          characterName: 'HAMLET',
          displayName: 'Bob',
          role: CastRole.understudy,
        ),
      ];

      // Find primary for HAMLET
      final hamletPrimary = members.firstWhere(
          (m) => m.characterName == 'HAMLET' && m.role == CastRole.primary);
      expect(hamletPrimary.displayName, 'John');

      // Find understudy for HAMLET
      final hamletUnderstudy = members.firstWhere(
          (m) => m.characterName == 'HAMLET' && m.role == CastRole.understudy);
      expect(hamletUnderstudy.displayName, 'Bob');

      // Unique characters in production
      final chars = members.map((m) => m.characterName).toSet();
      expect(chars, {'HAMLET', 'OPHELIA'});
    });

    test('organizer role maps correctly to Supabase', () {
      const member = CastMemberModel(
        id: 'cm-org',
        productionId: 'prod-1',
        userId: 'user-1',
        characterName: '',
        displayName: 'Director',
        role: CastRole.organizer,
      );

      expect(member.role.toSupabaseString(), 'organizer');
      expect(CastRole.fromString('organizer'), CastRole.organizer);
    });
  });

  // ── Script cloud sync data mapping ─────────────────────

  group('Script cloud sync data mapping', () {
    test('ScriptLine toJson includes all fields for cloud upload', () {
      const line = ScriptLine(
        id: 'line-1',
        act: 'ACT II',
        scene: 'Bedroom',
        lineNumber: 7,
        orderIndex: 42,
        character: 'OPHELIA',
        text: 'Where is the beauteous majesty of Denmark?',
        lineType: LineType.dialogue,
        stageDirection: 'entering distraught',
      );

      final json = line.toJson();

      expect(json['id'], 'line-1');
      expect(json['act'], 'ACT II');
      expect(json['scene'], 'Bedroom');
      expect(json['line_number'], 7);
      expect(json['order_index'], 42);
      expect(json['character'], 'OPHELIA');
      expect(json['text'], 'Where is the beauteous majesty of Denmark?');
      expect(json['line_type'], 'dialogue');
      expect(json['stage_direction'], 'entering distraught');
    });

    test('ScriptLine fromJson recreates from cloud data', () {
      final json = {
        'id': 'cloud-1',
        'act': 'ACT I',
        'scene': 'Throne Room',
        'line_number': 3,
        'order_index': 10,
        'character': 'CLAUDIUS',
        'text': 'Though yet of Hamlet our dear brother\'s death the memory be green.',
        'line_type': 'dialogue',
        'stage_direction': '',
      };

      final line = ScriptLine.fromJson(json);

      expect(line.id, 'cloud-1');
      expect(line.character, 'CLAUDIUS');
      expect(line.act, 'ACT I');
      expect(line.scene, 'Throne Room');
      expect(line.lineType, LineType.dialogue);
    });

    test('ScriptLine fromJson handles missing fields gracefully', () {
      final json = {
        'id': 'min-1',
        'line_number': 1,
        'order_index': 0,
        'text': 'A line with minimal data.',
        'line_type': 'dialogue',
      };

      final line = ScriptLine.fromJson(json);

      expect(line.act, '');
      expect(line.scene, '');
      expect(line.character, '');
      expect(line.stageDirection, '');
    });

    test('ScriptScene toJson and fromJson round-trip for cloud sync', () {
      const scene = ScriptScene(
        id: 'sc-1',
        act: 'ACT III',
        sceneName: 'ACT III, Scene 1',
        location: 'A room in the castle',
        description: 'The "To be" soliloquy',
        startLineIndex: 100,
        endLineIndex: 150,
        characters: ['HAMLET', 'OPHELIA', 'CLAUDIUS', 'POLONIUS'],
      );

      final json = scene.toJson();
      final restored = ScriptScene.fromJson(json);

      expect(restored.id, scene.id);
      expect(restored.act, scene.act);
      expect(restored.sceneName, scene.sceneName);
      expect(restored.characters, scene.characters);
      expect(restored.startLineIndex, scene.startLineIndex);
      expect(restored.endLineIndex, scene.endLineIndex);
    });
  });

  // ── buildParsedScript scene reconstruction ─────────────

  group('buildParsedScript scene reconstruction', () {
    test('groups consecutive lines by act+scene into scenes', () {
      final lines = [
        _line(id: '1', act: 'ACT I', scene: 'Scene 1', character: 'A',
            text: 'hi', orderIndex: 0),
        _line(id: '2', act: 'ACT I', scene: 'Scene 1', character: 'B',
            text: 'hey', orderIndex: 1),
        _line(id: '3', act: 'ACT I', scene: 'Scene 2', character: 'A',
            text: 'bye', orderIndex: 2),
      ];

      final script = buildParsedScript('Test', lines);

      expect(script.scenes.length, 2);
      expect(script.scenes[0].characters, containsAll(['A', 'B']));
      expect(script.scenes[1].characters, contains('A'));
    });

    test('scene line indices are correct', () {
      final lines = [
        _line(id: '1', act: 'ACT I', scene: 'S1', character: 'A',
            text: 'a', orderIndex: 0),
        _line(id: '2', act: 'ACT I', scene: 'S1', character: 'B',
            text: 'b', orderIndex: 1),
        _line(id: '3', act: 'ACT II', scene: 'S1', character: 'C',
            text: 'c', orderIndex: 2),
        _line(id: '4', act: 'ACT II', scene: 'S1', character: 'D',
            text: 'd', orderIndex: 3),
      ];

      final script = buildParsedScript('Test', lines);

      expect(script.scenes[0].startLineIndex, 0);
      expect(script.scenes[0].endLineIndex, 1);
      expect(script.scenes[1].startLineIndex, 2);
      expect(script.scenes[1].endLineIndex, 3);
    });

    test('skips scenes with no dialogue lines', () {
      final lines = [
        _line(
            id: '1',
            act: 'ACT I',
            scene: 'S1',
            character: '',
            text: 'ACT I',
            lineType: LineType.header,
            orderIndex: 0),
        _line(
            id: '2',
            act: 'ACT I',
            scene: 'S2',
            character: 'A',
            text: 'Hello',
            orderIndex: 1),
      ];

      final script = buildParsedScript('Test', lines);

      // Header-only scene is skipped
      expect(script.scenes.length, 1);
      expect(script.scenes[0].characters, contains('A'));
    });

    test('handles single scene spanning entire script', () {
      final lines = List.generate(
          10,
          (i) => _line(
              id: '$i',
              act: 'ACT I',
              scene: 'S1',
              character: i.isEven ? 'A' : 'B',
              text: 'Line $i',
              orderIndex: i));

      final script = buildParsedScript('Test', lines);

      expect(script.scenes.length, 1);
      expect(script.scenes[0].startLineIndex, 0);
      expect(script.scenes[0].endLineIndex, 9);
      expect(script.scenes[0].characters, containsAll(['A', 'B']));
    });

    test('scene names incorporate act and scene tags', () {
      final lines = [
        _line(
            id: '1',
            act: 'ACT III',
            scene: 'Throne Room',
            character: 'KING',
            text: 'Enter!',
            orderIndex: 0),
      ];

      final script = buildParsedScript('Test', lines);

      expect(script.scenes[0].sceneName, contains('ACT III'));
      expect(script.scenes[0].sceneName, contains('Throne Room'));
    });
  });

  // ── Production status workflow ─────────────────────────

  group('Production status workflow', () {
    test('status progresses through expected stages', () {
      var prod = Production(
        id: 'p1',
        title: 'Test',
        organizerId: 'user-1',
        createdAt: DateTime.now(),
        status: ProductionStatus.draft,
      );

      expect(prod.status, ProductionStatus.draft);

      prod = prod.copyWith(status: ProductionStatus.scriptImported);
      expect(prod.status, ProductionStatus.scriptImported);

      prod = prod.copyWith(status: ProductionStatus.castAssigned);
      expect(prod.status, ProductionStatus.castAssigned);

      prod = prod.copyWith(status: ProductionStatus.ready);
      expect(prod.status, ProductionStatus.ready);
    });

    test('all production statuses have string names', () {
      for (final status in ProductionStatus.values) {
        expect(status.name, isNotEmpty);
      }
    });
  });

  // ── DiffType coverage ──────────────────────────────────

  group('DiffType', () {
    test('all types exist', () {
      expect(DiffType.values, containsAll([
        DiffType.added,
        DiffType.removed,
        DiffType.changed,
        DiffType.unchanged,
      ]));
    });
  });

  // ── LineDiff ───────────────────────────────────────────

  group('LineDiff', () {
    test('added diff has cloud line, no local', () {
      final diff = LineDiff(
        type: DiffType.added,
        cloud: _line(id: '1', character: 'A', text: 'New'),
      );

      expect(diff.cloud, isNotNull);
      expect(diff.local, isNull);
    });

    test('removed diff has local line, no cloud', () {
      final diff = LineDiff(
        type: DiffType.removed,
        local: _line(id: '1', character: 'A', text: 'Old'),
      );

      expect(diff.local, isNotNull);
      expect(diff.cloud, isNull);
    });

    test('changed diff has both local and cloud', () {
      final diff = LineDiff(
        type: DiffType.changed,
        local: _line(id: '1', character: 'A', text: 'Before'),
        cloud: _line(id: '1', character: 'A', text: 'After'),
      );

      expect(diff.local, isNotNull);
      expect(diff.cloud, isNotNull);
      expect(diff.local!.text, isNot(diff.cloud!.text));
    });
  });

  // ── Edge cases for diff algorithm ──────────────────────

  group('diffScriptLines edge cases', () {
    test('large script diff performance', () {
      final local = List.generate(
          500,
          (i) => _line(
              id: '$i', character: 'A', text: 'Line $i', orderIndex: i));
      final cloud = List.generate(
          500,
          (i) => _line(
              id: '$i',
              character: 'A',
              text: i == 250 ? 'Changed line' : 'Line $i',
              orderIndex: i));

      final sw = Stopwatch()..start();
      final diffs = diffScriptLines(local, cloud);
      sw.stop();

      expect(diffs.length, 500);
      final changedCount =
          diffs.where((d) => d.type == DiffType.changed).length;
      expect(changedCount, 1);
      // Should complete quickly
      expect(sw.elapsedMilliseconds, lessThan(1000));
    });

    test('completely different scripts', () {
      final local = [
        _line(id: '1', character: 'A', text: 'Hello'),
        _line(id: '2', character: 'B', text: 'World'),
      ];
      final cloud = [
        _line(id: '3', character: 'C', text: 'Goodbye'),
        _line(id: '4', character: 'D', text: 'Cruel'),
        _line(id: '5', character: 'E', text: 'World'),
      ];

      final diffs = diffScriptLines(local, cloud);

      expect(diffs.length, 3);
      // First two positions are "changed" (different content at same index)
      expect(diffs[0].type, DiffType.changed);
      expect(diffs[1].type, DiffType.changed);
      // Third position is "added" (only in cloud)
      expect(diffs[2].type, DiffType.added);
    });

    test('lines with only whitespace differences count as changed', () {
      final local = [
        _line(id: '1', character: 'A', text: 'Hello world'),
      ];
      final cloud = [
        _line(id: '1', character: 'A', text: 'Hello  world'),
      ];

      final diffs = diffScriptLines(local, cloud);

      expect(diffs[0].type, DiffType.changed);
    });
  });
}
