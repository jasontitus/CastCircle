import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/script_models.dart';

/// Unit tests for [rebuildCharacters] — the single source of truth for cast
/// derivation (import, persistence load, and every in-session edit path).
///
/// The bug class this guards against: call sites that credited only
/// `line.character` on multi-character lines ("MACBETH AND LENNOX"), which
/// minted phantom characters, deflated the real characters' counts, and
/// reshuffled colors when the cast was rebuilt.
void main() {
  var order = 0;

  /// Convenience constructor for test lines.
  ScriptLine line(
    String character,
    String text, {
    LineType lineType = LineType.dialogue,
    List<String> multiCharacters = const [],
  }) =>
      ScriptLine(
        id: 'line-${order++}',
        act: 'I',
        scene: '1',
        lineNumber: order,
        orderIndex: order,
        character: character,
        text: text,
        lineType: lineType,
        multiCharacters: multiCharacters,
      );

  group('rebuildCharacters', () {
    test('multi-character lines credit each individual, never the combined cue', () {
      final lines = [
        // "MACBETH AND LENNOX" is the cue name; the real cast is the pair.
        line('MACBETH AND LENNOX', 'What, are they not here?',
            multiCharacters: ['MACBETH', 'LENNOX']),
        line('MACBETH', 'I am a man'),
        line('LENNOX', 'So am I'),
      ];

      final chars = rebuildCharacters(lines);

      expect(chars.map((c) => c.name), unorderedEquals(['MACBETH', 'LENNOX']));
      // Combined cue name must NOT appear as a phantom character.
      expect(chars.where((c) => c.name == 'MACBETH AND LENNOX'), isEmpty);
      // MACBETH: 1 multi + 1 solo = 2; LENNOX: 1 multi + 1 solo = 2.
      expect(chars[0].lineCount, 2);
      expect(chars[1].lineCount, 2);
    });

    test('non-dialogue lines and song lines are excluded', () {
      final lines = [
        line('', '(Enter MACBETH, wearing armor)',
            lineType: LineType.stageDirection),
        line('ACT I, SCENE 1', '', lineType: LineType.header),
        line('MACBETH', 'A song, to be sung', lineType: LineType.song),
        line('MACBETH', 'I am a man'),
      ];

      final chars = rebuildCharacters(lines);

      expect(chars, hasLength(1));
      expect(chars.single.name, 'MACBETH');
      expect(chars.single.lineCount, 1);
    });

    test('dialogue lines with an empty character are excluded', () {
      final lines = [
        line('', 'An unattributed line'),
        line('LENNOX', 'A counted line'),
      ];

      final chars = rebuildCharacters(lines);

      expect(chars, hasLength(1));
      expect(chars.single.name, 'LENNOX');
    });

    test('sorts by line count descending and assigns colorIndex in that order',
        () {
      final lines = [
        line('A', 'one'),
        line('B', 'one'),
        line('B', 'two'),
        line('B', 'three'),
      ];

      final chars = rebuildCharacters(lines);

      expect(chars.map((c) => c.name), ['B', 'A']);
      expect(chars.map((c) => c.colorIndex), [0, 1]);
      expect(chars.map((c) => c.lineCount), [3, 1]);
    });

    test('honors genderFor and defaults to female when absent', () {
      final lines = [
        line('MACBETH', 'one'),
        line('LENNOX', 'one'),
      ];

      final chars = rebuildCharacters(
        lines,
        genderFor: (name) =>
            name == 'MACBETH' ? CharacterGender.male : CharacterGender.female,
      );

      expect(
        {for (final c in chars) c.name: c.gender},
        {
          'MACBETH': CharacterGender.male,
          'LENNOX': CharacterGender.female,
        },
      );

      // Without a genderFor, every character defaults to female.
      final defaults = rebuildCharacters(lines);
      expect(defaults.every((c) => c.gender == CharacterGender.female), isTrue);
    });

    test('empty input yields an empty list', () {
      expect(rebuildCharacters(const []), isEmpty);
    });
  });
}
