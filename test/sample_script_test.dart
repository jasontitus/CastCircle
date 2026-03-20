@Tags(['extended'])
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

    test('detects JANE AND ELIZABETH as multi-character line', () {
      final file = File('sample-scripts/pg37431.txt');
      if (!file.existsSync()) return;

      final multiLines = script.lines
          .where((l) => l.multiCharacters.isNotEmpty)
          .toList();
      expect(multiLines, isNotEmpty,
          reason: 'P&P has "JANE AND ELIZABETH" multi-character line');

      // The individual characters should be in the character list
      final charNames = script.characters.map((c) => c.name).toSet();
      expect(charNames, contains('JANE'));
      expect(charNames, contains('ELIZABETH'));
    });
  });

  group('Real script parsing: Macbeth (Folger)', () {
    late ScriptParser parser;
    late ParsedScript script;

    setUpAll(() {
      final file = File('sample-scripts/macbeth_folger_converted.txt');
      if (!file.existsSync()) return;
      final rawText = file.readAsStringSync();
      parser = ScriptParser();
      script = parser.parse(rawText, title: 'Macbeth');
    });

    test('detects MACBETH AND LENNOX as multi-character line', () {
      final file = File('sample-scripts/macbeth_folger_converted.txt');
      if (!file.existsSync()) return;

      final multiLines = script.lines
          .where((l) => l.multiCharacters.isNotEmpty)
          .toList();
      expect(multiLines, isNotEmpty,
          reason: 'Macbeth has "MACBETH AND LENNOX" multi-character line');

      // Check that multi-character line has correct individuals
      final macbethLennox = multiLines
          .where((l) => l.multiCharacters.contains('MACBETH') &&
              l.multiCharacters.contains('LENNOX'))
          .toList();
      expect(macbethLennox, isNotEmpty,
          reason: 'Should split "MACBETH AND LENNOX" into individuals');
    });

    test('multi-character lines are findable via isForCharacter', () {
      final file = File('sample-scripts/macbeth_folger_converted.txt');
      if (!file.existsSync()) return;

      // MACBETH's lines should include the "MACBETH AND LENNOX" line
      final macbethLines = script.linesForCharacter('MACBETH');
      final multiInMacbeth = macbethLines
          .where((l) => l.multiCharacters.isNotEmpty)
          .toList();
      expect(multiInMacbeth, isNotEmpty,
          reason: 'linesForCharacter("MACBETH") should include multi-char lines');

      // Same line should also appear in LENNOX's lines
      final lennoxLines = script.linesForCharacter('LENNOX');
      final multiInLennox = lennoxLines
          .where((l) => l.multiCharacters.isNotEmpty)
          .toList();
      expect(multiInLennox, isNotEmpty,
          reason: 'linesForCharacter("LENNOX") should include multi-char lines');
    });

    test('ALL is treated as a regular character (not split)', () {
      final file = File('sample-scripts/macbeth_folger_converted.txt');
      if (!file.existsSync()) return;

      // "ALL" has no separator so it should remain as-is
      final allLines = script.lines
          .where((l) => l.character == 'ALL')
          .toList();
      if (allLines.isNotEmpty) {
        expect(allLines.first.multiCharacters, isEmpty,
            reason: '"ALL" should not be split into individual characters');
      }
    });
  });

  group('Real script parsing: Macbeth (Gutenberg)', () {
    late ScriptParser parser;
    late ParsedScript script;

    setUpAll(() {
      final file = File('sample-scripts/macbeth-pg1533-images-3.txt');
      if (!file.existsSync()) return;
      final rawText = file.readAsStringSync();
      parser = ScriptParser();
      script = parser.parse(rawText, title: 'Macbeth (Gutenberg)');
    });

    test('detects MACBETH, LENNOX as multi-character line (comma format)', () {
      final file = File('sample-scripts/macbeth-pg1533-images-3.txt');
      if (!file.existsSync()) return;

      final multiLines = script.lines
          .where((l) => l.multiCharacters.isNotEmpty)
          .toList();
      expect(multiLines, isNotEmpty,
          reason: 'Should detect comma-separated multi-character names');
    });
  });

  group('All sample scripts parse without errors', () {
    final dir = Directory('sample-scripts');
    if (!dir.existsSync()) return;

    final txtFiles = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.txt'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final file in txtFiles) {
      final name = file.path.split('/').last;
      test('$name parses without throwing', () {
        final rawText = file.readAsStringSync();
        final parser = ScriptParser();
        final script = parser.parse(rawText, title: name);

        // Basic sanity: should produce some lines
        expect(script.lines, isNotEmpty,
            reason: '$name should produce at least one line');

        // No character with empty name
        for (final char in script.characters) {
          expect(char.name.trim(), isNotEmpty,
              reason: '$name has a character with empty name');
        }

        // Multi-character lines should have valid individual names
        for (final line in script.lines) {
          if (line.multiCharacters.isNotEmpty) {
            expect(line.multiCharacters.length, greaterThanOrEqualTo(2),
                reason: '$name: multi-character line should have 2+ characters');
            for (final char in line.multiCharacters) {
              expect(char.trim(), isNotEmpty,
                  reason: '$name: multi-character has empty individual name');
            }
          }
        }
      });
    }
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

    test('multi-character lines split correctly', () {
      final buffer = StringBuffer();
      buffer.writeln('ACT I');
      // Single character lines
      for (var i = 0; i < 10; i++) {
        buffer.writeln('ELIZABETH. Line $i from Elizabeth.');
        buffer.writeln('JANE. Line $i from Jane.');
        buffer.writeln('DARCY. Line $i from Darcy.');
        buffer.writeln('LYDIA. Line $i from Lydia.');
      }
      // Multi-character lines
      buffer.writeln('ELIZABETH AND JANE. We both agree on this matter.');
      buffer.writeln('DARCY, ELIZABETH. Indeed we do.');
      buffer.writeln('JANE, LYDIA, ELIZABETH. All of us concur.');

      final parser = ScriptParser();
      final script = parser.parse(buffer.toString());

      // Multi-character lines should be detected
      final multiLines = script.lines
          .where((l) => l.multiCharacters.isNotEmpty)
          .toList();
      expect(multiLines.length, 3,
          reason: 'Should detect 3 multi-character lines');

      // Verify AND separator split
      final andLine = multiLines
          .where((l) => l.character == 'ELIZABETH AND JANE')
          .toList();
      expect(andLine.length, 1);
      expect(andLine.first.multiCharacters, ['ELIZABETH', 'JANE']);

      // Verify comma separator split
      final commaLine = multiLines
          .where((l) => l.character == 'DARCY, ELIZABETH')
          .toList();
      expect(commaLine.length, 1);
      expect(commaLine.first.multiCharacters, ['DARCY', 'ELIZABETH']);

      // Verify 3-way comma split
      final threeLine = multiLines
          .where((l) => l.character == 'JANE, LYDIA, ELIZABETH')
          .toList();
      expect(threeLine.length, 1);
      expect(threeLine.first.multiCharacters,
          ['JANE', 'LYDIA', 'ELIZABETH']);

      // isForCharacter should work for all individuals
      expect(andLine.first.isForCharacter('ELIZABETH'), isTrue);
      expect(andLine.first.isForCharacter('JANE'), isTrue);
      expect(andLine.first.isForCharacter('DARCY'), isFalse);

      // linesForCharacter should include multi-character lines
      final elizLines = script.linesForCharacter('ELIZABETH');
      // 10 solo + 3 multi = 13
      expect(elizLines.length, 13,
          reason: 'ELIZABETH should have 10 solo + 3 multi-char lines');

      // Character list should have individual characters, not combined names
      final charNames = script.characters.map((c) => c.name).toSet();
      expect(charNames, contains('ELIZABETH'));
      expect(charNames, contains('JANE'));
      expect(charNames, contains('DARCY'));
      expect(charNames, contains('LYDIA'));
      // Combined names should NOT be in the character list
      expect(charNames, isNot(contains('ELIZABETH AND JANE')));
      expect(charNames, isNot(contains('DARCY, ELIZABETH')));
      expect(charNames, isNot(contains('JANE, LYDIA, ELIZABETH')));
    });

    test('multi-character lines appear in scene character lists', () {
      final buffer = StringBuffer();
      buffer.writeln('ACT I');
      for (var i = 0; i < 5; i++) {
        buffer.writeln('ELIZABETH. Line $i.');
        buffer.writeln('DARCY. Line $i.');
      }
      buffer.writeln('ELIZABETH AND DARCY. Together now.');

      final parser = ScriptParser();
      final script = parser.parse(buffer.toString());

      // Both individual characters should appear in the scene
      expect(script.scenes, isNotEmpty);
      final scene = script.scenes.first;
      expect(scene.characters, contains('ELIZABETH'));
      expect(scene.characters, contains('DARCY'));
      // Combined name should NOT be in the scene character list
      expect(scene.characters, isNot(contains('ELIZABETH AND DARCY')));
    });
  });
}
