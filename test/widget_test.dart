import 'package:flutter_test/flutter_test.dart';
import 'package:lineguide/data/services/script_parser.dart';
import 'package:lineguide/data/services/script_export.dart';
import 'package:lineguide/data/services/stt_service.dart';
import 'package:lineguide/data/models/script_models.dart';
import 'package:lineguide/features/script_editor/validation_panel.dart';

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
(Shift begins into First Ball.)
ELIZABETH. What a fine assembly tonight.
DARCY. It is tolerable I suppose.
BINGLEY. Darcy, you must dance.
(Shift begins, returning us to Longbourn.)
MR. BENNET. Capital Lydia, I hope Mr. Bingley will like it.
MRS. BENNET. We are not in a way to know what Mr. Bingley likes.
ACT II
(Shift begins into Pemberley.)
ELIZABETH. I have been a selfish being all my life.
DARCY. You are too generous to trifle with me.
HOUSEKEEPER. Mr. Darcy is the best landlord and master.
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

  group('Scene Detection', () {
    late ScriptParser parser;

    setUp(() {
      parser = ScriptParser();
    });

    test('detects scenes from Shift stage directions', () {
      final result = parser.parse(_sampleScript, title: 'Test Play');

      expect(result.scenes.length, greaterThanOrEqualTo(3),
          reason: 'Should detect at least 3 scenes '
              '(opening, ball, return to Longbourn or Pemberley)');
    });

    test('scenes have characters listed', () {
      final result = parser.parse(_sampleScript, title: 'Test Play');

      for (final scene in result.scenes) {
        expect(scene.characters, isNotEmpty,
            reason: 'Scene "${scene.sceneName}" should have characters');
      }
    });

    test('ball scene detects Ball location', () {
      final result = parser.parse(_sampleScript, title: 'Test Play');

      final ballScene = result.scenes.where(
        (s) => s.location.contains('Ball'),
      );
      expect(ballScene, isNotEmpty,
          reason: 'Should detect a Ball scene from "Shift begins into First Ball"');
    });

    test('Pemberley scene detected in Act II', () {
      final result = parser.parse(_sampleScript, title: 'Test Play');

      final pemberleyScene = result.scenes.where(
        (s) => s.location.contains('Pemberley'),
      );
      expect(pemberleyScene, isNotEmpty,
          reason: 'Should detect Pemberley from "Shift begins into Pemberley"');
    });

    test('scenes have valid line index ranges', () {
      final result = parser.parse(_sampleScript, title: 'Test Play');

      for (final scene in result.scenes) {
        expect(scene.startLineIndex, greaterThanOrEqualTo(0));
        expect(scene.endLineIndex, lessThan(result.lines.length));
        expect(scene.endLineIndex, greaterThanOrEqualTo(scene.startLineIndex));
      }
    });

    test('linesInScene returns correct subset', () {
      final result = parser.parse(_sampleScript, title: 'Test Play');

      for (final scene in result.scenes) {
        final lines = result.linesInScene(scene);
        expect(lines, isNotEmpty);
        // All lines should be within the scene's act
        for (final line in lines) {
          if (line.lineType == LineType.dialogue) {
            expect(scene.characters, contains(line.character),
                reason:
                    '${line.character} should be in scene ${scene.sceneName}');
          }
        }
      }
    });

    test('scenesForCharacter filters correctly', () {
      final result = parser.parse(_sampleScript, title: 'Test Play');

      final elizabethScenes = result.scenesForCharacter('ELIZABETH');
      expect(elizabethScenes, isNotEmpty);
      for (final scene in elizabethScenes) {
        expect(scene.characters, contains('ELIZABETH'));
      }
    });

    test('scene displayLabel includes location when available', () {
      final result = parser.parse(_sampleScript, title: 'Test Play');

      for (final scene in result.scenes) {
        if (scene.location.isNotEmpty) {
          expect(scene.displayLabel, contains(scene.location));
        }
      }
    });
  });

  group('ScriptExporter', () {
    late ParsedScript script;

    setUp(() {
      final parser = ScriptParser();
      script = parser.parse(_sampleScript, title: 'Test Play');
    });

    test('toPlainText includes cast list and scene index', () {
      final text = ScriptExporter.toPlainText(script);

      expect(text, contains('TEST PLAY'));
      expect(text, contains('CAST OF CHARACTERS'));
      expect(text, contains('SCENES'));
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

    test('toSceneText exports a single scene', () {
      final scene = script.scenes.first;
      final text = ScriptExporter.toSceneText(script, scene);

      expect(text, contains(scene.sceneName));
      expect(text, contains('Characters:'));
    });
  });

  group('SttService.matchScore', () {
    test('exact match returns 1.0', () {
      final score = SttService.matchScore(
        'You are very punctual I see',
        'You are very punctual I see',
      );
      expect(score, 1.0);
    });

    test('case-insensitive match returns 1.0', () {
      final score = SttService.matchScore(
        'You Are Very Punctual',
        'you are very punctual',
      );
      expect(score, 1.0);
    });

    test('partial match returns proportional score', () {
      final score = SttService.matchScore(
        'You are very punctual I see',
        'You are punctual',
      );
      // 3 of 6 words match
      expect(score, closeTo(0.5, 0.1));
    });

    test('no match returns 0', () {
      final score = SttService.matchScore(
        'You are very punctual',
        'something completely different',
      );
      expect(score, 0.0);
    });

    test('ignores punctuation', () {
      final score = SttService.matchScore(
        "It is tolerable, I suppose!",
        "it is tolerable I suppose",
      );
      expect(score, 1.0);
    });

    test('empty expected returns 1.0', () {
      final score = SttService.matchScore('', 'anything');
      expect(score, 1.0);
    });

    test('threshold of 70% works for reasonable delivery', () {
      // Actor says most of the line but misses a word or two
      final score = SttService.matchScore(
        'I have been a selfish being all my life',
        'I have been a selfish being my life',
      );
      // 8 of 9 words
      expect(score, greaterThanOrEqualTo(0.7));
    });
  });

  group('Script Validation', () {
    late ParsedScript script;

    setUp(() {
      final parser = ScriptParser();
      script = parser.parse(_sampleScript, title: 'Test Play');
    });

    test('validates a well-formed script', () {
      final checks = validateScript(script);

      // Should have characters
      final charCheck = checks.firstWhere((c) => c.label == 'Cast list detected');
      expect(charCheck.passed, isTrue);

      // Should have scenes
      final sceneCheck = checks.firstWhere((c) => c.label == 'Scenes detected');
      expect(sceneCheck.passed, isTrue);

      // Should have act structure
      final actCheck = checks.firstWhere((c) => c.label == 'Act structure detected');
      expect(actCheck.passed, isTrue);
    });

    test('detects healthy dialogue ratio', () {
      final checks = validateScript(script);
      final ratioCheck = checks.firstWhere((c) => c.label == 'Healthy dialogue ratio');
      expect(ratioCheck.passed, isTrue);
    });

    test('all lines attributed', () {
      final checks = validateScript(script);
      final attrCheck = checks.firstWhere((c) => c.label == 'All lines attributed');
      expect(attrCheck.passed, isTrue);
    });
  });
}
