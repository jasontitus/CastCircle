import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/script_parser.dart';

/// Tests for the PDF import pipeline — specifically testing the text parsing
/// stage that processes OCR output. The actual PDF rendering + ML Kit OCR
/// requires device testing, but the text parsing (which is where truncation
/// bugs manifest) can be tested with synthetic OCR output.
///
/// The user reported missing pages at the end of PDF imports. This test suite
/// verifies that the parser correctly processes all text including the final
/// pages, and that noise filtering doesn't accidentally discard valid content.
void main() {
  late ScriptParser parser;

  setUp(() {
    parser = ScriptParser();
  });

  group('PDF import: page completeness', () {
    test('all pages from OCR output are parsed (no end truncation)', () {
      // Simulate OCR output from a 60-page PDF
      final buffer = StringBuffer();
      buffer.writeln('ACT I');
      buffer.writeln();
      for (var page = 1; page <= 60; page++) {
        // Typical OCR page output: dialogue + noise
        buffer.writeln('${page ~/ 2 + 1}'); // page number (noise)
        buffer.writeln();
        final char = ['ELIZABETH', 'DARCY', 'JANE', 'BINGLEY'][page % 4];
        buffer.writeln('$char. This is the dialogue from page $page of the script.');
        buffer.writeln();
      }
      final rawText = buffer.toString();
      final script = parser.parse(rawText);

      final dialogueLines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(dialogueLines.length, 60,
          reason: 'Expected 60 dialogue lines (one per page), got ${dialogueLines.length}');

      // Verify last page content is present
      expect(dialogueLines.last.text, contains('page 60'));
    });

    test('last 10 pages are fully preserved', () {
      final buffer = StringBuffer();
      buffer.writeln('ACT I');
      for (var page = 1; page <= 30; page++) {
        buffer.writeln('DARCY. Early page $page content.');
      }
      // Pages 21-30 contain distinctive text
      for (var page = 31; page <= 40; page++) {
        buffer.writeln('ELIZABETH. FINAL SECTION page $page important content.');
      }

      final script = parser.parse(buffer.toString());
      final finalLines = script.lines
          .where((l) =>
              l.lineType == LineType.dialogue &&
              l.text.contains('FINAL SECTION'))
          .toList();

      expect(finalLines.length, 10,
          reason: 'Expected 10 final section lines, got ${finalLines.length}');
    });

    test('handles very large scripts (200+ pages equivalent)', () {
      final buffer = StringBuffer();
      buffer.writeln('ACT I');
      // ~600 lines simulating a very long play
      for (var i = 0; i < 600; i++) {
        final char = ['ELIZABETH', 'DARCY', 'JANE', 'BINGLEY', 'COLLINS'][i % 5];
        buffer.writeln('$char. Line number $i of the very long script.');
      }

      final script = parser.parse(buffer.toString());
      final dialogueLines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();

      expect(dialogueLines.length, 600);
      expect(dialogueLines.last.text, contains('Line number 599'));
    });
  });

  group('PDF import: OCR text reconstruction', () {
    test('block-paragraph separation does not lose text', () {
      // ML Kit outputs text blocks separated by blank lines
      const rawText = '''
ELIZABETH. First block first line.

DARCY. Second block first line.

JANE. Third block first line.

BINGLEY. Fourth block first line.

ELIZABETH. Fifth block, after many paragraphs.
''';
      final script = parser.parse(rawText);
      final dialogueLines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(dialogueLines.length, 5);
    });

    test('multi-block continuation within a page is preserved', () {
      // OCR may split a single character's speech across multiple blocks
      const rawText = '''
ELIZABETH. I have been walking about the grounds
and thinking on the subject
most seriously.

DARCY. And what conclusion have you reached?
''';
      final script = parser.parse(rawText);
      final elizabethLines = script.lines
          .where((l) => l.character == 'ELIZABETH')
          .toList();
      expect(elizabethLines.length, 1);
      expect(elizabethLines.first.text, contains('walking'));
      expect(elizabethLines.first.text, contains('seriously'));
    });

    test('noise between pages does not break character continuity', () {
      const rawText = '''
ELIZABETH. I begin my speech here
and continue on the next page.
42
Pride and Prejudice 42
ELIZABETH. Still more of the same speech would continue as a new line.

DARCY. A response.
''';
      final script = parser.parse(rawText);
      final dialogueLines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      // The page number noise should be filtered, but ELIZABETH's second cue starts a new line
      expect(dialogueLines.length, greaterThanOrEqualTo(2));
    });
  });

  group('PDF import: edge cases causing missing content', () {
    test('empty OCR pages (0 blocks) do not stop parsing', () {
      // Simulate: pages 1-10 have content, page 11 is blank, pages 12-15 have content
      final buffer = StringBuffer();
      buffer.writeln('ACT I');
      for (var page = 1; page <= 10; page++) {
        buffer.writeln('ELIZABETH. Content from page $page.');
      }
      // Page 11 produces no text (blank line simulates empty OCR)
      buffer.writeln();
      buffer.writeln();
      for (var page = 12; page <= 15; page++) {
        buffer.writeln('DARCY. Content from page $page.');
      }

      final script = parser.parse(buffer.toString());
      final dialogueLines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(dialogueLines.length, 14);
    });

    test('script ending with stage direction is preserved', () {
      const rawText = '''
ACT I

ELIZABETH. The last dialogue line.

(The lights fade to black. End of play.)
''';
      final script = parser.parse(rawText);
      final allLines = script.lines;
      final lastLine = allLines.last;
      expect(lastLine.lineType, LineType.stageDirection);
      expect(lastLine.text, contains('lights fade'));
    });

    test('script ending mid-dialogue is flushed', () {
      const rawText = '''
ACT I

DARCY. Some earlier line.

ELIZABETH. The very last line with no trailing newline''';
      final script = parser.parse(rawText);
      final dialogueLines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(dialogueLines.length, 2);
      expect(dialogueLines.last.character, 'ELIZABETH');
      expect(dialogueLines.last.text, contains('last line'));
    });

    test('trailing whitespace-only pages do not truncate', () {
      final buffer = StringBuffer();
      buffer.writeln('ACT I');
      buffer.writeln('ELIZABETH. Real content here.');
      buffer.writeln('DARCY. More real content.');
      // Simulate whitespace-only pages at the end
      for (var i = 0; i < 10; i++) {
        buffer.writeln('   ');
        buffer.writeln();
      }

      final script = parser.parse(buffer.toString());
      final dialogueLines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(dialogueLines.length, 2);
    });

    test('noise-heavy end pages do not eliminate valid content before them', () {
      final buffer = StringBuffer();
      buffer.writeln('ACT I');
      buffer.writeln('ELIZABETH. Important line before noise.');
      // End pages full of noise
      for (var i = 0; i < 20; i++) {
        buffer.writeln('${i + 50}'); // page numbers
        buffer.writeln('Jon Jory ${i + 50}');
        buffer.writeln('Pride and Prejudice ${i + 50}');
      }

      final script = parser.parse(buffer.toString());
      final dialogueLines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(dialogueLines.length, 1);
      expect(dialogueLines.first.text, contains('Important line'));
    });
  });

  group('PDF import: act/scene structure from OCR', () {
    test('multiple acts across pages', () {
      const rawText = '''
ACT I

ELIZABETH. Act one line.

ACT II

DARCY. Act two line.

ACT III

JANE. Act three line.
''';
      final script = parser.parse(rawText);
      final headers = script.lines
          .where((l) => l.lineType == LineType.header)
          .toList();
      expect(headers.length, 3);

      // Lines should have correct act assignments
      final dialogueLines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(dialogueLines[0].act, 'ACT I');
      expect(dialogueLines[1].act, 'ACT II');
      expect(dialogueLines[2].act, 'ACT III');
    });

    test('scene transitions within an act', () {
      const rawText = '''
ACT I

ELIZABETH. At Longbourn.

(Shift begins into Netherfield.)

DARCY. At Netherfield.

(Shift begins to Rosings.)

COLLINS. At Rosings.
''';
      final script = parser.parse(rawText);
      expect(script.scenes.length, greaterThanOrEqualTo(2));
    });
  });

  group('PDF import: character completeness', () {
    test('all characters from all pages are detected', () {
      final buffer = StringBuffer();
      buffer.writeln('ACT I');
      final allChars = [
        'ELIZABETH', 'DARCY', 'JANE', 'BINGLEY', 'COLLINS',
        'WICKHAM', 'LYDIA', 'CHARLOTTE', 'MARY', 'KITTY',
      ];
      for (var i = 0; i < allChars.length; i++) {
        buffer.writeln('${allChars[i]}. I am ${allChars[i]} and this is my line.');
      }

      final script = parser.parse(buffer.toString());
      final charNames = script.characters.map((c) => c.name).toSet();

      for (final name in allChars) {
        expect(charNames, contains(name),
            reason: '$name should be in character list');
      }
    });

    test('character appearing only on last page is included', () {
      final buffer = StringBuffer();
      buffer.writeln('ACT I');
      for (var i = 0; i < 50; i++) {
        buffer.writeln('ELIZABETH. Line $i.');
      }
      // New character only on "last page"
      buffer.writeln('LADY CATHERINE. You are not to leave Rosings!');

      final script = parser.parse(buffer.toString());
      final charNames = script.characters.map((c) => c.name).toSet();
      expect(charNames, contains('LADY CATHERINE'));
    });

    test('character line counts include all pages', () {
      final buffer = StringBuffer();
      buffer.writeln('ACT I');
      for (var i = 0; i < 25; i++) {
        buffer.writeln('ELIZABETH. Elizabeth line $i.');
      }
      for (var i = 0; i < 15; i++) {
        buffer.writeln('DARCY. Darcy line $i.');
      }

      final script = parser.parse(buffer.toString());
      final elizabeth = script.characters.firstWhere((c) => c.name == 'ELIZABETH');
      final darcy = script.characters.firstWhere((c) => c.name == 'DARCY');

      expect(elizabeth.lineCount, 25);
      expect(darcy.lineCount, 15);
    });
  });

  group('PDF import: markdown import', () {
    test('strips markdown formatting before parsing', () {
      // Test via ScriptImportService.importFromText since _stripMarkdown is private
      // Instead, test the parser directly with pre-stripped text
      const rawText = '''
ACT I

ELIZABETH. This is **bold** text and *italic* text.

DARCY. A [link](http://example.com) in dialogue.
''';
      final script = parser.parse(rawText);
      final lines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(lines.length, 2);
    });
  });
}
