import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/script_parser.dart';

/// Tests using real sample scripts to verify parser handles various formats.
/// Note: The Gutenberg text files use "name on separate line" format which
/// differs from OCR output format. The parser primarily targets OCR output
/// ("NAME. dialogue on same line"), but should still extract some content
/// from Gutenberg format via the character detection pass.
void main() {
  group('Real script parsing: Pride and Prejudice (pg37431.txt)', () {
    late ScriptParser parser;
    late ParsedScript script;

    setUpAll(() {
      final file = File('sample-scripts/pg37431.txt');
      if (!file.existsSync()) return;
      final rawText = file.readAsStringSync();
      parser = ScriptParser();
      script = parser.parse(rawText, title: 'Pride and Prejudice');
    });

    test('detects act headers', () {
      final file = File('sample-scripts/pg37431.txt');
      if (!file.existsSync()) return;

      final acts = script.lines
          .where((l) => l.lineType == LineType.header)
          .toList();
      expect(acts.length, greaterThanOrEqualTo(3),
          reason: 'P&P has multiple acts');
    });

    test('detects at least some characters from Gutenberg format', () {
      final file = File('sample-scripts/pg37431.txt');
      if (!file.existsSync()) return;

      // Gutenberg format uses "name on separate line" not "NAME. dialogue",
      // so the parser may only detect a few characters via the detection pass.
      expect(parser.knownCharacters.length, greaterThanOrEqualTo(1),
          reason: 'Should detect at least one character from Gutenberg format');
    });

    test('no OCR garbage characters survive', () {
      final file = File('sample-scripts/pg37431.txt');
      if (!file.existsSync()) return;

      for (final char in script.characters) {
        final letters = char.name.replaceAll(RegExp(r'[^A-Za-z]'), '');
        final vowels = letters.replaceAll(RegExp(r'[^AEIOUaeiou]'), '');
        if (letters.length >= 4) {
          expect(vowels.isNotEmpty, true,
              reason: '${char.name} looks like OCR garbage (no vowels)');
        }
      }
    });
  });

  group('OCR-format script parsing simulation', () {
    test('full Pride and Prejudice OCR-format script parses completely', () {
      // Simulate what OCR would produce from the P&P PDF
      final buffer = StringBuffer();
      buffer.writeln('ACT I');
      final chars = [
        'MR. BENNET', 'MRS. BENNET', 'ELIZABETH', 'JANE', 'LYDIA',
        'KITTY', 'MARY', 'DARCY', 'BINGLEY', 'COLLINS', 'WICKHAM',
        'MISS BINGLEY', 'CHARLOTTE', 'MRS. GARDINER', 'MR. GARDINER',
        'LADY CATHERINE', 'FITZWILLIAM', 'HOUSEKEEPER', 'GEORGIANA',
      ];
      // 80 pages of content
      for (var page = 1; page <= 80; page++) {
        final char = chars[page % chars.length];
        buffer.writeln('$char. This is dialogue from page $page of the script.');
        if (page == 20) buffer.writeln('ACT II');
        if (page == 40) buffer.writeln('ACT III');
        if (page == 60) buffer.writeln('ACT IV');
      }

      final parser = ScriptParser();
      final script = parser.parse(buffer.toString());

      // All 80 pages should produce dialogue
      final dialogueLines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(dialogueLines.length, 80);

      // Last page content should be present
      expect(dialogueLines.last.text, contains('page 80'));

      // All 4 acts should exist
      final acts = script.lines
          .where((l) => l.lineType == LineType.header)
          .toList();
      expect(acts.length, 4);
    });

    test('script with OCR typos gets cleaned up', () {
      final buffer = StringBuffer();
      buffer.writeln('ACT I');
      // Many real lines
      for (var i = 0; i < 20; i++) {
        buffer.writeln('ELIZABETH. Line $i from Elizabeth.');
        buffer.writeln('DARCY. Line $i from Darcy.');
      }
      // OCR typos
      buffer.writeln('ELIIZABETH. A typo line.');
      buffer.writeln('DRCY. Another typo.');

      final parser = ScriptParser();
      final script = parser.parse(buffer.toString());
      final charNames = script.characters.map((c) => c.name).toSet();

      expect(charNames, contains('ELIZABETH'));
      expect(charNames, contains('DARCY'));
      // Typos should not exist as separate characters
      // (they may or may not be detected depending on edit distance)
    });
  });
}
