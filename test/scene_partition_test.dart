import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/script_parser.dart';

/// Rehearsal plays `linesInScene(scene)` — a POSITIONAL slice — while the
/// editor and export walk `lines`. If the scenes don't partition the lines
/// exactly, the script reads correctly but rehearsal plays the wrong
/// dialogue: the field report was "the lines are all out of order in
/// rehearsal, but the script itself is fine".
///
/// These are invariants of any parse, checked against the real scanned-P&P
/// OCR text plus the sample corpus.
void main() {
  void checkPartition(ParsedScript script, String label) {
    final scenes = script.scenes;
    if (scenes.isEmpty) return;

    // 1. Ranges are ordered, non-overlapping and in-bounds.
    var prevEnd = -1;
    for (final s in scenes) {
      expect(
        s.startLineIndex,
        greaterThanOrEqualTo(0),
        reason: '$label: ${s.sceneName} start out of bounds',
      );
      expect(
        s.endLineIndex,
        lessThan(script.lines.length),
        reason: '$label: ${s.sceneName} end past the last line',
      );
      expect(
        s.startLineIndex,
        lessThanOrEqualTo(s.endLineIndex),
        reason: '$label: ${s.sceneName} inverted range',
      );
      expect(
        s.startLineIndex,
        greaterThan(prevEnd),
        reason:
            '$label: ${s.sceneName} overlaps the previous scene — '
            'rehearsal would replay/skip lines',
      );
      prevEnd = s.endLineIndex;
    }

    // 2. The slice a scene hands rehearsal is exactly the lines at those
    //    indices, in script order (no dialogue silently reordered).
    for (final s in scenes) {
      final slice = script.linesInScene(s);
      expect(
        slice.length,
        s.endLineIndex - s.startLineIndex + 1,
        reason: '$label: ${s.sceneName} slice length mismatch',
      );
      for (var i = 0; i < slice.length; i++) {
        expect(
          identical(slice[i], script.lines[s.startLineIndex + i]),
          true,
          reason: '$label: ${s.sceneName} slice is not the script order',
        );
      }
    }

    // 3. Every dialogue line inside a scene's range belongs to that scene's
    //    act — a line landing in the wrong scene is exactly what the actor
    //    hears as "out of order".
    for (final s in scenes) {
      for (final l in script.linesInScene(s)) {
        if (l.lineType != LineType.dialogue) continue;
        if (l.act.isEmpty || s.act.isEmpty) continue;
        expect(
          l.act,
          s.act,
          reason:
              '$label: "${l.text.substring(0, l.text.length.clamp(0, 30))}" '
              '(act ${l.act}) sits inside ${s.sceneName} (act ${s.act})',
        );
      }
    }
  }

  test('scenes partition the real scanned-P&P OCR text', () {
    final f = File('test/fixtures/pp_ocr_raw.txt');
    if (!f.existsSync()) {
      markTestSkipped('pp_ocr_raw.txt fixture missing');
      return;
    }
    final script = ScriptParser().parse(f.readAsStringSync(), title: 'PP');
    checkPartition(script, 'pp_ocr_raw');
    // Sanity: this fixture really does produce scenes to check.
    expect(script.scenes.length, greaterThan(1));
  });

  test('scenes partition every sample script in the corpus', () {
    final dir = Directory('sample-scripts');
    if (!dir.existsSync()) {
      markTestSkipped('sample-scripts missing');
      return;
    }
    final texts = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.txt'))
        .toList();
    expect(texts, isNotEmpty);
    for (final f in texts) {
      final script = ScriptParser().parse(
        f.readAsStringSync(),
        title: 'corpus',
      );
      checkPartition(script, f.uri.pathSegments.last);
    }
  });

  test('an announced shift does not steal the outgoing scene\'s last line', () {
    // The scan really prints:
    //   (Shift begins into First Ball.)
    //   MR. BENNET. Yes, I fear that as I have actually paid the visit…
    //   (The ball begins. ELIZABETH sits to one side…)
    // Mr. Bennet is finishing the Longbourn conversation DURING the shift,
    // so rehearsing the Ball scene must not open with his line.
    const text = '''
MRS. BENNET. Now see what an excellent father you have girls.

(Shift begins into First Ball.)

MR. BENNET. Yes, I fear that as I have actually paid the visit we cannot escape the acquaintance now.

(The ball begins. ELIZABETH sits to one side. DARCY and BINGLEY stand on the other.)

BINGLEY. Come, Darcy, I hate to see you standing about by yourself.

DARCY. You know how I detest it unless I am particularly acquainted with my partner.
''';
    final script = ScriptParser().parse(text, title: 'seam');
    final ball = script.scenes.firstWhere(
      (s) => s.location == 'Ball',
      orElse: () => throw StateError(
        'no Ball scene: '
        '${script.scenes.map((s) => s.sceneName).toList()}',
      ),
    );
    final firstDialogue = script
        .linesInScene(ball)
        .firstWhere((l) => l.lineType == LineType.dialogue);
    expect(
      firstDialogue.character,
      'BINGLEY',
      reason:
          'the Ball scene must start at the arrival direction, not at '
          'the announcement — got "${firstDialogue.text}"',
    );
    checkPartition(script, 'seam');
  });
}
