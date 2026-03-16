import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/script_parser.dart';

void main() {
  late ScriptParser parser;

  setUp(() {
    parser = ScriptParser();
  });

  group('OCR character name cleanup', () {
    test('fuzzy match merges BNGLEY into BINGLEY', () {
      final buffer = StringBuffer();
      buffer.writeln('ACT I');
      // BINGLEY appears many times
      for (var i = 0; i < 10; i++) {
        buffer.writeln('BINGLEY. Line $i from Bingley.');
      }
      // OCR typo appears once
      buffer.writeln('BNGLEY. A line with a typo in the name.');

      final script = parser.parse(buffer.toString());
      final charNames = script.characters.map((c) => c.name).toSet();

      expect(charNames, contains('BINGLEY'));
      expect(charNames, isNot(contains('BNGLEY')),
          reason: 'BNGLEY should be merged into BINGLEY');

      final bingley = script.characters.firstWhere((c) => c.name == 'BINGLEY');
      expect(bingley.lineCount, 11,
          reason: 'BINGLEY should have 10 + 1 merged line');
    });

    test('fuzzy match merges FHTZWILLIAM into FITZWILLIAM', () {
      final buffer = StringBuffer();
      buffer.writeln('ACT I');
      for (var i = 0; i < 5; i++) {
        buffer.writeln('FITZWILLIAM. Line $i.');
      }
      buffer.writeln('FHTZWILLIAM. OCR typo line.');

      final script = parser.parse(buffer.toString());
      final charNames = script.characters.map((c) => c.name).toSet();

      expect(charNames, contains('FITZWILLIAM'));
      expect(charNames, isNot(contains('FHTZWILLIAM')));
    });

    test('does NOT merge MR. BENNET into MRS. BENNET', () {
      const rawText = '''
ACT I

MR. BENNET. First line.
MR. BENNET. Second line.
MR. BENNET. Third line.

MRS. BENNET. First line.
MRS. BENNET. Second line.
MRS. BENNET. Third line.
''';
      final script = parser.parse(rawText);
      final charNames = script.characters.map((c) => c.name).toSet();

      expect(charNames, contains('MR. BENNET'));
      expect(charNames, contains('MRS. BENNET'));
    });

    test('does NOT merge short distinct names (MARY ≠ DARCY)', () {
      const rawText = '''
ACT I

MARY. A line from Mary.

DARCY. A line from Darcy.
DARCY. Another Darcy line.
''';
      final script = parser.parse(rawText);
      final charNames = script.characters.map((c) => c.name).toSet();

      expect(charNames, contains('MARY'));
      expect(charNames, contains('DARCY'));
    });

    test('strips trailing punctuation from names (LYDIA. .. → LYDIA)', () {
      final buffer = StringBuffer();
      buffer.writeln('ACT I');
      for (var i = 0; i < 5; i++) {
        buffer.writeln('LYDIA. Line $i.');
      }
      // OCR captured trailing dots as part of name
      buffer.writeln('LYDIA. .. The line with trailing dots in name.');

      final script = parser.parse(buffer.toString());
      final charNames = script.characters.map((c) => c.name).toSet();

      expect(charNames, contains('LYDIA'));
      expect(charNames, isNot(contains('LYDIA. ..')));
    });

    test('title variant: MR. DARCY merges into DARCY when DARCY is more common', () {
      final buffer = StringBuffer();
      buffer.writeln('ACT I');
      for (var i = 0; i < 10; i++) {
        buffer.writeln('DARCY. Darcy line $i.');
      }
      buffer.writeln('MR. DARCY. A formal reference to Darcy.');

      final script = parser.parse(buffer.toString());
      final charNames = script.characters.map((c) => c.name).toSet();

      expect(charNames, contains('DARCY'));
      expect(charNames, isNot(contains('MR. DARCY')),
          reason: 'MR. DARCY should merge into DARCY');

      final darcy = script.characters.firstWhere((c) => c.name == 'DARCY');
      expect(darcy.lineCount, 11);
    });

    test('title variant does NOT merge when titled form is more common', () {
      final buffer = StringBuffer();
      buffer.writeln('ACT I');
      // MR. BENNET is the common form — no bare BENNET exists
      for (var i = 0; i < 10; i++) {
        buffer.writeln('MR. BENNET. Line $i.');
      }

      final script = parser.parse(buffer.toString());
      final charNames = script.characters.map((c) => c.name).toSet();

      expect(charNames, contains('MR. BENNET'));
      // No BENNET character should exist
      expect(charNames, isNot(contains('BENNET')));
    });

    test('OCR garbage names with no vowels are removed', () {
      final buffer = StringBuffer();
      buffer.writeln('ACT I');
      buffer.writeln('ELIZABETH. A real line.');
      // OCR garbage — no vowels in 4+ letter name
      buffer.writeln('NNCRTK. Garbage OCR text.');

      final script = parser.parse(buffer.toString());
      final charNames = script.characters.map((c) => c.name).toSet();

      expect(charNames, contains('ELIZABETH'));
      expect(charNames, isNot(contains('NNCRTK')));
    });
  });

  group('OCR dehyphenation', () {
    test('rejoins hyphenated line breaks', () {
      const rawText = '''
ACT I

ELIZABETH. I could easily for-
give his pride, if he had not mor-
tified mine.

DARCY. Indeed.
''';
      final script = parser.parse(rawText);
      final elizabeth = script.lines.firstWhere(
        (l) => l.character == 'ELIZABETH',
      );

      expect(elizabeth.text, contains('forgive'));
      expect(elizabeth.text, contains('mortified'));
      expect(elizabeth.text, isNot(contains('for-')));
    });

    test('preserves intentional hyphens', () {
      const rawText = '''
ACT I

ELIZABETH. She is a well-known woman.
''';
      final script = parser.parse(rawText);
      final line = script.lines.firstWhere(
        (l) => l.character == 'ELIZABETH',
      );

      // "well-known" should NOT be dehyphenated (uppercase after hyphen, or same line)
      expect(line.text, contains('well-known'));
    });

    test('multiple dehyphenations in one text', () {
      const rawText = '''
ACT I

MR. BENNET. If your daugh-
ter should have a dan-
gerous fit of ill-
ness it would be terrible.
''';
      final script = parser.parse(rawText);
      final line = script.lines.firstWhere(
        (l) => l.character == 'MR. BENNET',
      );

      expect(line.text, contains('daughter'));
      expect(line.text, contains('dangerous'));
      expect(line.text, contains('illness'));
    });
  });

  group('OCR trailing noise cleanup', () {
    test('strips trailing bracketed noise from dialogue', () {
      const rawText = '''
ACT I

MR. BENNET. Am I mistaken that there was but one name on the invitation? [I.4 -HIL A leter for Miss Jane
''';
      final script = parser.parse(rawText);
      final line = script.lines.firstWhere(
        (l) => l.character == 'MR. BENNET',
      );

      expect(line.text, contains('invitation'));
      expect(line.text, isNot(contains('[I.4')));
      expect(line.text, isNot(contains('HIL')));
    });
  });

  group('Noise pattern filtering', () {
    test('page number + title lines are noise', () {
      const rawText = '''
ACT I

ELIZABETH. Before.
42 Some Title Here
DARCY. After.
''';
      final script = parser.parse(rawText);
      final lines = script.lines.where((l) => l.lineType == LineType.dialogue).toList();
      expect(lines.length, 2);
    });

    test('title + page number lines are noise', () {
      const rawText = '''
ACT I

ELIZABETH. Before.
Some Title Here 42
DARCY. After.
''';
      final script = parser.parse(rawText);
      final lines = script.lines.where((l) => l.lineType == LineType.dialogue).toList();
      expect(lines.length, 2);
    });
  });
}
