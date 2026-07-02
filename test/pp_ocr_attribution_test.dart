import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/services/script_parser.dart';
import 'package:castcircle/data/models/script_models.dart';

/// Attribution regression tests against the REAL PaddleOCR output of the
/// Jon Jory "Pride and Prejudice" 82-page scan (test/fixtures/pp_ocr_raw.txt,
/// captured from the actual macOS pipeline). Every expectation below was
/// verified against the printed PDF pages, not against another parse.
void main() {
  late ParsedScript script;
  late List<ScriptLine> dialogue;

  setUpAll(() {
    final raw = File('test/fixtures/pp_ocr_raw.txt').readAsStringSync();
    script = ScriptParser().parse(raw, title: 'Pride and Prejudice');
    dialogue =
        script.lines.where((l) => l.lineType == LineType.dialogue).toList();
  });

  ScriptLine? lineContaining(String probe) {
    for (final l in dialogue) {
      if (l.text.contains(probe)) return l;
    }
    return null;
  }

  test('major Jory roles all present with plausible line counts', () {
    final counts = {
      for (final c in script.characters) c.name: c.lineCount,
    };
    expect(counts['ELIZABETH'], greaterThan(250));
    expect(counts['MRS. BENNET'], greaterThan(100));
    expect(counts['DARCY'], greaterThan(90));
    expect(counts['MR. BENNET'], greaterThan(60));
    expect(counts['JANE'], greaterThan(50));
    expect(counts['MRS. GARDINER'], greaterThan(20));
  });

  test('no bare-title characters survive (MRS/MR fragments)', () {
    final names = script.characters.map((c) => c.name).toSet();
    expect(names, isNot(contains('MRS')));
    expect(names, isNot(contains('MR')));
  });

  test('OCR comma-cue "MRS, BENNET." attributes to MRS. BENNET (print p8)',
      () {
    final l = lineContaining('Now see what an excellent father');
    expect(l, isNotNull);
    expect(l!.character, 'MRS. BENNET');
  });

  test('OCR no-space cue "MRS.BENNET." attributes to MRS. BENNET (print p78)',
      () {
    final l = lineContaining('Mr. Darcy is here Elizabeth');
    expect(l, isNotNull);
    expect(l!.character, 'MRS. BENNET');
  });

  test('continuation after centered direction keeps the speaker (print p72)',
      () {
    // BINGLEY: "Indeed. (A change of subject.) Excellent shooting this
    // season, eh Darcy?" — the continuation used to be silently DROPPED.
    final l = lineContaining('Excellent shooting this season');
    expect(l, isNotNull, reason: 'line must not be dropped');
    expect(l!.character, 'BINGLEY');
  });

  test('DARCY keeps speaking after (A pause.) (print p72)', () {
    // DARCY: "Quite well. (A pause.) Very well."
    final idx = dialogue.indexWhere(
        (l) => l.character == 'DARCY' && l.text.contains('Quite well'));
    expect(idx, greaterThanOrEqualTo(0));
    final after = dialogue
        .skip(idx + 1)
        .take(2)
        .where((l) => l.character == 'DARCY' && l.text.contains('Very well'));
    expect(after, isNotEmpty,
        reason: '"Very well." after (A pause.) must stay with DARCY');
  });

  test('print-verified MRS. BENNET lines are hers (not MR. BENNET)', () {
    for (final probe in [
      'It is a long time, Mr. Bingley',
      'Indeed I have palpitations',
      'Will Lady Catherine not come in',
    ]) {
      final l = lineContaining(probe);
      expect(l, isNotNull, reason: 'missing: $probe');
      expect(l!.character, 'MRS. BENNET', reason: probe);
    }
  });

  test('overall dialogue volume in expected range', () {
    // 1127 before the dropped-continuation fix; the fix should ADD lines.
    expect(dialogue.length, greaterThan(1100));
    expect(dialogue.length, lessThan(1350));
  });
}
