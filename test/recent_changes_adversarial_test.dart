import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/script_parser.dart';
import 'package:castcircle/data/services/ocr_highlight_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('spoken end marker does not truncate intervening scenes', () {
    final script = ScriptParser().parse('''
ACT I
CALVIN:
End of Play.
MEG: We are not finished yet.
MEG: We still have things to say.
CALVIN: Then keep going.
ACT II
CALVIN: This entire act must survive.
MEG: Now we can leave.
(The lights go out.)
End of Play.
About the Authors
This biography is not spoken.
''');
    printOnFailure(
      'RAW: ${script.rawText} ACTS: ${script.acts} LINES: ${script.lines.map((l) => l.text).toList()}',
    );
    final dialogue = script.lines
        .where((l) => l.lineType == LineType.dialogue)
        .toList();
    expect(
      dialogue.map((l) => l.text),
      containsAll([
        'End of Play.',
        'We are not finished yet.',
        'This entire act must survive.',
        'Now we can leave.',
      ]),
    );
    expect(script.acts, ['ACT I', 'ACT II']);
    expect(script.rawText, isNot(contains('This biography')));
  });

  test(
    'author heading much later cannot truncate dialogue after a spoken marker',
    () {
      final script = ScriptParser().parse('''
ACT I
CALVIN:
End of Play.
MEG: You wish. We have another scene.
CALVIN: Here is the ending.
(Curtain.)
About the Authors
A biography.
''');
      expect(
        script.lines.map((l) => l.text).join(' '),
        contains('Here is the ending.'),
      );
    },
  );

  test('short colon cues match their exact dialogue bodies', () {
    for (final cue in ['MEG: No.', 'CHARLES: No.', 'MRS. WHO: No.']) {
      expect(OcrHighlightMatcher.stripCue(cue), 'No.');
      final match = OcrHighlightMatcher.bestMatch('No.', [cue]);
      expect(match?.index, 0, reason: cue);
    }
  });
}
