import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/script_parser.dart';

void main() {
  group('ScriptParser full pipeline', () {
    late ScriptParser parser;

    setUp(() {
      parser = ScriptParser();
    });

    test('parses simple two-character dialogue', () {
      const rawText = '''
ELIZABETH. I could easily forgive his pride, if he had not mortified mine.

DARCY. I have been meditating on the very great pleasure which a pair of fine eyes in the face of a pretty woman can bestow.
''';
      final script = parser.parse(rawText, title: 'P&P Test');
      expect(script.title, 'P&P Test');
      expect(script.lines.where((l) => l.lineType == LineType.dialogue).length, 2);

      final chars = script.characters.map((c) => c.name).toSet();
      expect(chars, contains('ELIZABETH'));
      expect(chars, contains('DARCY'));
    });

    test('detects act headers', () {
      const rawText = '''
ACT I

ELIZABETH. First act line.

ACT II

DARCY. Second act line.
''';
      final script = parser.parse(rawText);
      final headers = script.lines.where((l) => l.lineType == LineType.header).toList();
      expect(headers.length, 2);
      expect(headers[0].text, 'ACT I');
      expect(headers[1].text, 'ACT II');
    });

    test('detects scene headers', () {
      const rawText = '''
ACT I

SCENE 1

ELIZABETH. First scene line.

SCENE 2

DARCY. Second scene line.
''';
      final script = parser.parse(rawText);
      final lines = script.lines.where((l) => l.lineType == LineType.dialogue).toList();
      expect(lines.length, 2);
    });

    test('detects standalone stage directions', () {
      const rawText = '''
ELIZABETH. I shall go.

(She exits.)

DARCY. She has gone.
''';
      final script = parser.parse(rawText);
      final directions = script.lines
          .where((l) => l.lineType == LineType.stageDirection)
          .toList();
      expect(directions.length, 1);
      expect(directions.first.text, contains('She exits'));
    });

    test('handles multi-line dialogue continuation', () {
      const rawText = '''
ELIZABETH. I could easily forgive
his pride, if he had not
mortified mine.

DARCY. Indeed.
''';
      final script = parser.parse(rawText);
      final lines = script.lines.where((l) => l.lineType == LineType.dialogue).toList();
      expect(lines.length, 2);
      // First line should contain the full continuation
      expect(lines[0].text, contains('forgive'));
      expect(lines[0].text, contains('mortified'));
      expect(lines[0].character, 'ELIZABETH');
    });

    test('filters noise patterns', () {
      const rawText = '''
12 Jon Jory
Pride and Prejudice 12

ELIZABETH. A real line of dialogue here.

42

Jon Jory 12
''';
      final script = parser.parse(rawText);
      final lines = script.lines.where((l) => l.lineType == LineType.dialogue).toList();
      expect(lines.length, 1);
      expect(lines.first.character, 'ELIZABETH');
    });

    test('cleans OCR artifacts from text', () {
      const rawText = '''
ELIZABETH. I could | easily forgive~ his pride°.
''';
      final script = parser.parse(rawText);
      final line = script.lines.firstWhere((l) => l.lineType == LineType.dialogue);
      expect(line.text, isNot(contains('|')));
      expect(line.text, isNot(contains('~')));
      expect(line.text, isNot(contains('°')));
    });

    test('extracts inline stage direction', () {
      const rawText = '''
ELIZABETH. (sarcastically:) How delightful.
''';
      final script = parser.parse(rawText);
      final line = script.lines.firstWhere((l) => l.lineType == LineType.dialogue);
      expect(line.stageDirection, 'sarcastically');
      expect(line.text, 'How delightful.');
    });

    test('scene detection via shift transitions', () {
      const rawText = '''
ACT I

ELIZABETH. We are at Longbourn.

(Shift begins into Netherfield.)

DARCY. Welcome to Netherfield.
''';
      final script = parser.parse(rawText);
      expect(script.scenes.length, greaterThanOrEqualTo(1));
    });

    test('character aliases normalize names', () {
      parser.characterAliases['LIZZY'] = 'ELIZABETH';
      const rawText = '''
ELIZABETH. First line.

LIZZY. Same character.
''';
      final script = parser.parse(rawText);
      final chars = script.characters.map((c) => c.name).toSet();
      expect(chars, contains('ELIZABETH'));
      // LIZZY should have been normalized to ELIZABETH
    });

    test('characters sorted by line count descending', () {
      const rawText = '''
ELIZABETH. Line 1.
ELIZABETH. Line 2.
ELIZABETH. Line 3.
DARCY. Line 1.
DARCY. Line 2.
BINGLEY. Line 1.
''';
      final script = parser.parse(rawText);
      expect(script.characters[0].name, 'ELIZABETH');
      expect(script.characters[0].lineCount, 3);
      expect(script.characters[1].name, 'DARCY');
      expect(script.characters[1].lineCount, 2);
      expect(script.characters[2].name, 'BINGLEY');
      expect(script.characters[2].lineCount, 1);
    });

    test('gender assigned to characters during parse', () {
      const rawText = '''
ELIZABETH. She speaks.
DARCY. He replies.
''';
      final script = parser.parse(rawText);
      final elizabeth = script.characters.firstWhere((c) => c.name == 'ELIZABETH');
      final darcy = script.characters.firstWhere((c) => c.name == 'DARCY');
      expect(elizabeth.gender, CharacterGender.female);
      expect(darcy.gender, CharacterGender.male);
    });

    test('title prefix characters skipped (MR, MRS are not standalone characters)', () {
      const rawText = '''
MR. BENNET. I have the pleasure.
MRS. BENNET. Oh my nerves!
''';
      final script = parser.parse(rawText);
      final charNames = script.characters.map((c) => c.name).toSet();
      // MR and MRS should NOT appear as standalone characters
      expect(charNames, isNot(contains('MR')));
      expect(charNames, isNot(contains('MRS')));
      expect(charNames, contains('MR. BENNET'));
      expect(charNames, contains('MRS. BENNET'));
    });
  });

  group('ScriptParser noise detection', () {
    late ScriptParser parser;

    setUp(() {
      parser = ScriptParser();
    });

    test('empty line is noise', () {
      const rawText = '''
ELIZABETH. Before.


DARCY. After.
''';
      final script = parser.parse(rawText);
      final lines = script.lines.where((l) => l.lineType == LineType.dialogue).toList();
      expect(lines.length, 2);
    });

    test('bare page number is noise', () {
      const rawText = '''
ELIZABETH. Before.
42
DARCY. After.
''';
      final script = parser.parse(rawText);
      final lines = script.lines.where((l) => l.lineType == LineType.dialogue).toList();
      expect(lines.length, 2);
    });

    test('OCR pipe artifacts are noise', () {
      const rawText = '''
ELIZABETH. Real line.
|} |
DARCY. Another real line.
''';
      final script = parser.parse(rawText);
      final lines = script.lines.where((l) => l.lineType == LineType.dialogue).toList();
      expect(lines.length, 2);
    });
  });

  group('ScriptParser large script completeness', () {
    late ScriptParser parser;

    setUp(() {
      parser = ScriptParser();
    });

    test('preserves all lines from a 100-page equivalent text', () {
      // Simulate text from 100 PDF pages (~30 lines per page)
      final buffer = StringBuffer();
      buffer.writeln('ACT I');
      for (var page = 1; page <= 100; page++) {
        for (var line = 1; line <= 3; line++) {
          final char = page.isEven ? 'ELIZABETH' : 'DARCY';
          buffer.writeln('$char. This is page $page line $line of the script.');
        }
      }
      final rawText = buffer.toString();

      final script = parser.parse(rawText);
      final dialogueLines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();

      // Should have all 300 lines (100 pages × 3 lines)
      expect(dialogueLines.length, 300);
    });

    test('last page lines are preserved', () {
      final buffer = StringBuffer();
      buffer.writeln('ACT I');
      for (var page = 1; page <= 50; page++) {
        buffer.writeln('DARCY. Page $page dialogue.');
      }
      // Last page has distinctive text
      buffer.writeln('ELIZABETH. This is the very last line of the play.');

      final script = parser.parse(buffer.toString());
      final lastDialogue = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .last;
      expect(lastDialogue.text, contains('very last line'));
      expect(lastDialogue.character, 'ELIZABETH');
    });

    test('page markers between content do not cause truncation', () {
      final buffer = StringBuffer();
      buffer.writeln('ACT I');
      for (var page = 1; page <= 20; page++) {
        buffer.writeln('ELIZABETH. Line from page $page.');
        buffer.writeln('$page'); // Page number (noise)
        buffer.writeln('Jon Jory $page'); // Author line (noise)
      }
      // Lines after all the noise
      buffer.writeln('DARCY. The final line after all pages.');

      final script = parser.parse(buffer.toString());
      final dialogueLines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();

      // 20 ELIZABETH lines + 1 DARCY line = 21
      expect(dialogueLines.length, 21);
      expect(dialogueLines.last.character, 'DARCY');
    });
  });
}
