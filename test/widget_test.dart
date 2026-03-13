import 'package:flutter_test/flutter_test.dart';
import 'package:lineguide/data/services/script_parser.dart';
import 'package:lineguide/data/services/script_export.dart';
import 'package:lineguide/data/models/script_models.dart';

const _sampleScript = '''
ACT I
(The lights come up on the Bennet household.)
MR. BENNET. You are very punctual I see. Delighted to have you here at Longbourn.
LYDIA. The eldest, though I cannot see why she must always have the chair.
ELIZABETH. Hush Lydia.
MARY. (Glancing at JANE:) And the prettiest of all.
JANE. Mary, for goodness sake.
MR. BENNET. The next, Elizabeth.
MRS. BENNET. (Entering in a fluster:) My dear Mr. Bennet, have you heard that Netherfield Park is let at last?
MR. BENNET. I have not.
MRS. BENNET. But it is! A single man of large fortune!
ACT II
ELIZABETH. I have been a selfish being all my life.
DARCY. You are too generous to trifle with me.
''';

void main() {
  group('ScriptParser', () {
    late ScriptParser parser;

    setUp(() {
      parser = ScriptParser();
    });

    test('parses dialogue lines with character attribution', () {
      final result = parser.parse(_sampleScript, title: 'Test Play');

      final dialogueLines = result.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();

      expect(dialogueLines.length, greaterThan(8));
      expect(dialogueLines.first.character, 'MR. BENNET');
      expect(dialogueLines.first.text, contains('punctual'));
    });

    test('detects act headers', () {
      final result = parser.parse(_sampleScript, title: 'Test Play');

      final headers = result.lines
          .where((l) => l.lineType == LineType.header)
          .toList();

      expect(headers.length, 2);
      expect(headers[0].text, contains('ACT I'));
      expect(headers[1].text, contains('ACT II'));
    });

    test('detects stage directions', () {
      final result = parser.parse(_sampleScript, title: 'Test Play');

      final directions = result.lines
          .where((l) => l.lineType == LineType.stageDirection)
          .toList();

      expect(directions.length, greaterThanOrEqualTo(1));
      expect(directions.first.text, contains('lights come up'));
    });

    test('extracts inline stage directions', () {
      final result = parser.parse(_sampleScript, title: 'Test Play');

      final maryLine = result.lines.firstWhere(
        (l) => l.character == 'MARY' && l.stageDirection.isNotEmpty,
      );

      expect(maryLine.stageDirection, contains('Glancing'));
      expect(maryLine.text, contains('prettiest'));
    });

    test('builds character list sorted by line count', () {
      final result = parser.parse(_sampleScript, title: 'Test Play');

      expect(result.characters.length, greaterThan(3));
      // MR. BENNET and MRS. BENNET should be in the list
      final charNames = result.characters.map((c) => c.name).toList();
      expect(charNames, contains('MR. BENNET'));
      expect(charNames, contains('ELIZABETH'));
    });

    test('assigns sequential order indices', () {
      final result = parser.parse(_sampleScript, title: 'Test Play');

      for (var i = 1; i < result.lines.length; i++) {
        expect(result.lines[i].orderIndex,
            greaterThan(result.lines[i - 1].orderIndex));
      }
    });
  });

  group('ScriptExporter', () {
    late ParsedScript script;

    setUp(() {
      final parser = ScriptParser();
      script = parser.parse(_sampleScript, title: 'Test Play');
    });

    test('toPlainText includes cast list and all lines', () {
      final text = ScriptExporter.toPlainText(script);

      expect(text, contains('TEST PLAY'));
      expect(text, contains('CAST OF CHARACTERS'));
      expect(text, contains('ELIZABETH'));
      expect(text, contains('MR. BENNET:'));
      expect(text, contains('punctual'));
    });

    test('toMarkdown uses proper formatting', () {
      final md = ScriptExporter.toMarkdown(script);

      expect(md, contains('# Test Play'));
      expect(md, contains('**MR. BENNET.**'));
      expect(md, contains('*'));
    });

    test('toCharacterLines shows character lines with >>> marker', () {
      final text = ScriptExporter.toCharacterLines(script, 'ELIZABETH');

      expect(text, contains('ELIZABETH'));
      expect(text, contains('>>> YOU:'));
      expect(text, contains('Hush Lydia'));
    });

    test('toCueScript shows cue lines before character lines', () {
      final text = ScriptExporter.toCueScript(script, 'ELIZABETH');

      expect(text, contains('CUE SCRIPT: ELIZABETH'));
      expect(text, contains('CUE ('));
      expect(text, contains('YOU:'));
    });
  });
}
