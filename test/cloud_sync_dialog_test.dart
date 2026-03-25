import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/features/script_editor/cloud_sync_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptLine _line({
  required String id,
  required int orderIndex,
  String character = 'ELIZABETH',
  String text = 'Hello',
}) {
  return ScriptLine(
    id: id,
    act: 'ACT I',
    scene: 'Scene 1',
    lineNumber: orderIndex,
    orderIndex: orderIndex,
    character: character,
    text: text,
    lineType: LineType.dialogue,
  );
}

void main() {
  group('diffScriptLines', () {
    test('returns unchanged for identical content', () {
      final local = [_line(id: '1', orderIndex: 1, text: 'How are you?')];
      final cloud = [_line(id: '1', orderIndex: 1, text: 'How are you?')];

      final diffs = diffScriptLines(local, cloud);

      expect(diffs, hasLength(1));
      expect(diffs.single.type, DiffType.unchanged);
    });

    test('returns changed when same position has different content', () {
      final local = [_line(id: '1', orderIndex: 1, text: 'Local line')];
      final cloud = [_line(id: '1', orderIndex: 1, text: 'Cloud line')];

      final diffs = diffScriptLines(local, cloud);

      expect(diffs, hasLength(1));
      expect(diffs.single.type, DiffType.changed);
      expect(diffs.single.local?.text, 'Local line');
      expect(diffs.single.cloud?.text, 'Cloud line');
    });

    test('returns added when cloud has extra lines', () {
      final local = [_line(id: '1', orderIndex: 1)];
      final cloud = [
        _line(id: '1', orderIndex: 1),
        _line(id: '2', orderIndex: 2, text: 'New cloud line'),
      ];

      final diffs = diffScriptLines(local, cloud);

      expect(diffs.map((d) => d.type), [DiffType.unchanged, DiffType.added]);
      expect(diffs.last.cloud?.text, 'New cloud line');
    });

    test('returns removed when local has extra lines', () {
      final local = [
        _line(id: '1', orderIndex: 1),
        _line(id: '2', orderIndex: 2, text: 'Only local'),
      ];
      final cloud = [_line(id: '1', orderIndex: 1)];

      final diffs = diffScriptLines(local, cloud);

      expect(diffs.map((d) => d.type), [DiffType.unchanged, DiffType.removed]);
      expect(diffs.last.local?.text, 'Only local');
    });
  });
}
