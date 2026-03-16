import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/services/script_parser.dart';
import 'package:castcircle/data/services/stt_service.dart';
import 'package:castcircle/data/models/script_models.dart';

void main() {
  group('ScriptParser edge cases', () {
    late ScriptParser parser;

    setUp(() {
      parser = ScriptParser();
    });

    test('handles empty input gracefully', () {
      final result = parser.parse('', title: 'Empty');
      expect(result.lines, isEmpty);
      expect(result.characters, isEmpty);
      expect(result.scenes, isEmpty);
    });

    test('handles input with only stage directions', () {
      const text = '''
(The lights come up.)
(A long pause.)
(Blackout.)
''';
      final result = parser.parse(text, title: 'Directions Only');
      final dialogue = result.lines.where((l) => l.lineType == LineType.dialogue);
      expect(dialogue, isEmpty);
    });

    test('handles single character monologue', () {
      const text = '''
HAMLET. To be, or not to be, that is the question.
HAMLET. Whether 'tis nobler in the mind to suffer.
HAMLET. The slings and arrows of outrageous fortune.
''';
      final result = parser.parse(text, title: 'Monologue');
      expect(result.characters.length, 1);
      expect(result.characters.first.name, 'HAMLET');
      expect(result.characters.first.lineCount, 3);
    });

    test('handles characters with periods in names', () {
      const text = '''
MR. BENNET. I am quite at leisure.
MRS. BENNET. My dear Mr. Bennet!
DR. SMITH. Good evening.
''';
      final result = parser.parse(text, title: 'Dotted Names');
      final charNames = result.characters.map((c) => c.name).toSet();
      expect(charNames, contains('MR. BENNET'));
      expect(charNames, contains('MRS. BENNET'));
    });

    test('filters OCR noise lines', () {
      const text = '''
12 Jon Jory
MR. BENNET. Hello there.
Pride and Prejudice 15
|||
ELIZABETH. Good morning.
42
''';
      final result = parser.parse(text, title: 'Noisy');
      final dialogue = result.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(dialogue.length, 2);
      // No noise should appear in parsed lines
      for (final line in result.lines) {
        expect(line.text, isNot(contains('Jon Jory')));
        expect(line.text, isNot(equals('|||')));
      }
    });

    test('detects multiple acts', () {
      const text = '''
ACT I
ELIZABETH. First act line.
ACT II
DARCY. Second act line.
ACT III
BINGLEY. Third act line.
''';
      final result = parser.parse(text, title: 'Three Acts');
      expect(result.acts, ['ACT I', 'ACT II', 'ACT III']);
    });

    test('handles Shift scene transitions correctly', () {
      const text = '''
ACT I
MR. BENNET. Opening line.
(Shift begins into the Ball.)
ELIZABETH. At the ball now.
DARCY. Indeed.
(Shift begins, returning us to Longbourn.)
MR. BENNET. Back at home.
''';
      final result = parser.parse(text, title: 'Shifts');
      expect(result.scenes.length, greaterThanOrEqualTo(2));

      // Check location extraction
      final ballScene = result.scenes.where((s) => s.location == 'Ball');
      expect(ballScene, isNotEmpty);
    });

    test('preserves inline stage directions', () {
      const text = '''
MARY. (Laughing:) How delightful!
LYDIA. (Running to the window:) A carriage!
''';
      final result = parser.parse(text, title: 'Inline Dirs');
      final maryLine = result.lines.firstWhere(
        (l) => l.character == 'MARY',
      );
      expect(maryLine.stageDirection, contains('Laughing'));
      expect(maryLine.text, contains('delightful'));
    });

    test('handles very long lines', () {
      final longText = 'A' * 1000;
      final text = 'HAMLET. $longText';
      final result = parser.parse(text, title: 'Long');
      final dialogue = result.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(dialogue.length, 1);
      expect(dialogue.first.text.length, 1000);
    });

    test('handles Unicode characters in dialogue', () {
      const text = '''
ELIZABETH. C'est magnifique — truly wonderful!
DARCY. "Indeed," he said, "it's extraordinary."
''';
      final result = parser.parse(text, title: 'Unicode');
      final dialogue = result.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(dialogue.length, 2);
      expect(dialogue[0].text, contains('magnifique'));
      expect(dialogue[1].text, contains('extraordinary'));
    });
  });

  group('SttService.matchScore edge cases', () {
    test('handles extra words in spoken text', () {
      final score = SttService.matchScore(
        'Hello world',
        'Hello beautiful world today',
      );
      // Both expected words are present
      expect(score, 1.0);
    });

    test('handles repeated words — bag-of-words contains check', () {
      final score = SttService.matchScore(
        'yes yes yes',
        'yes',
      );
      // matchScore uses contains(), so "yes" in spoken matches all three "yes"
      // in expected. All 3 expectedWords find "yes" in spokenWords → 3/3 = 1.0
      expect(score, 1.0);
    });

    test('handles very long text', () {
      final expected = List.generate(100, (i) => 'word$i').join(' ');
      final spoken = List.generate(100, (i) => 'word$i').join(' ');
      final score = SttService.matchScore(expected, spoken);
      expect(score, 1.0);
    });

    test('handles empty spoken text', () {
      final score = SttService.matchScore(
        'Hello world',
        '',
      );
      expect(score, 0.0);
    });

    test('both empty returns 1.0', () {
      final score = SttService.matchScore('', '');
      expect(score, 1.0);
    });

    test('ignores mixed punctuation', () {
      final score = SttService.matchScore(
        "Don't you think? Yes, I do!",
        "dont you think yes i do",
      );
      expect(score, 1.0);
    });

    test('handles numbers in text', () {
      final score = SttService.matchScore(
        'I have 3 apples',
        'I have 3 apples',
      );
      expect(score, 1.0);
    });
  });

  group('ScriptParser location detection', () {
    late ScriptParser parser;

    setUp(() {
      parser = ScriptParser();
    });

    test('detects Longbourn', () {
      const text = '''
ACT I
ELIZABETH. Hello.
(Shift begins into Longbourn.)
MR. BENNET. At Longbourn.
''';
      final result = parser.parse(text, title: 'Locations');
      final longbournScene = result.scenes.where(
        (s) => s.location.contains('Longbourn'),
      );
      expect(longbournScene, isNotEmpty);
    });

    test('detects Pemberley', () {
      const text = '''
ACT I
DARCY. Hello.
(Shift begins into Pemberley.)
HOUSEKEEPER. Welcome to Pemberley.
''';
      final result = parser.parse(text, title: 'Pemberley');
      final pemScene = result.scenes.where(
        (s) => s.location.contains('Pemberley'),
      );
      expect(pemScene, isNotEmpty);
    });

    test('detects Netherfield', () {
      const text = '''
ACT I
BINGLEY. Opening.
(Shift begins to Netherfield.)
BINGLEY. At Netherfield now.
''';
      final result = parser.parse(text, title: 'Netherfield');
      final scene = result.scenes.where(
        (s) => s.location.contains('Netherfield'),
      );
      expect(scene, isNotEmpty);
    });
  });

  group('ScriptParser multi-line dialogue', () {
    late ScriptParser parser;

    setUp(() {
      parser = ScriptParser();
    });

    test('continuation lines are joined to character dialogue', () {
      // Lines after a character cue that don't start with a new cue
      // should be treated as continuation
      const text = '''
ELIZABETH. I must confess that I have been
quite wrong about you.
DARCY. And I about you.
''';
      final result = parser.parse(text, title: 'Continuation');
      final elizLines = result.lines.where(
        (l) => l.character == 'ELIZABETH' && l.lineType == LineType.dialogue,
      );
      // Should be a single joined line
      expect(elizLines.length, 1);
      expect(elizLines.first.text, contains('confess'));
      expect(elizLines.first.text, contains('wrong'));
    });
  });
}
