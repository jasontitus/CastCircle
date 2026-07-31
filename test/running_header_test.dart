import 'package:flutter_test/flutter_test.dart';

import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/script_parser.dart';

/// Running-header stripping. The header must be detected FROM THE TEXT
/// (repeated standalone line), never only from the production title — real
/// productions get named "test5" while the page header says "Pride and
/// Prejudice" — and it must be scrubbed both as standalone lines (with or
/// without page numbers) and when OCR glues it into a dialogue line at a
/// page seam.
void main() {
  const raw = '''
Pride and Prejudice

ACT I

SCENE 1

ELIZABETH. I could easily forgive his pride, if he had not mortified mine.

Pride and Prejudice 12

DARCY. My good opinion once lost is lost for ever.

12 Pride and Prejudice

JANE. He is just what a young man ought to be.

Pride and Prejudice

ELIZABETH. And your defect is a propensity to hate everybody. Pride and Prejudice 13

DARCY. And yours is wilfully to misunderstand them.

Pride and Prejudice
''';

  test('header detected from text even when the production title differs', () {
    final parser = ScriptParser();
    final script = parser.parse(raw, title: 'test5');
    final dialogue =
        script.lines.where((l) => l.lineType == LineType.dialogue).toList();
    expect(dialogue.length, 5);
    for (final l in dialogue) {
      expect(l.text.contains('Pride and Prejudice'), false,
          reason: 'header leaked into: "${l.text}"');
    }
  });

  test('header glued into a line at a page seam is scrubbed in place', () {
    final parser = ScriptParser();
    final script = parser.parse(raw, title: 'whatever');
    final polluted = script.lines.firstWhere(
        (l) => l.text.contains('propensity to hate everybody'));
    expect(polluted.text.trim(), 'And your defect is a propensity to hate everybody.');
  });

  test('lowercase in-dialogue mention of the title survives', () {
    const withMention = '''
Pride and Prejudice

ACT I

ELIZABETH. Where pride and prejudice have led me, I cannot say.

Pride and Prejudice

DARCY. Indeed.

Pride and Prejudice
''';
    final parser = ScriptParser();
    final script = parser.parse(withMention, title: 'test');
    final liz = script.lines
        .firstWhere((l) => l.character == 'ELIZABETH');
    expect(liz.text.contains('pride and prejudice'), true);
  });

  test('a repeated dialogue line (refrain, ends with punctuation) is kept', () {
    const withRefrain = '''
ACT I

JANE. I always speak what I think.

ELIZABETH. Do you?

JANE. I always speak what I think.

DARCY. Hm.

JANE. I always speak what I think.

ELIZABETH. So you say.
''';
    final parser = ScriptParser();
    final script = parser.parse(withRefrain, title: 'test');
    final refrains = script.lines
        .where((l) => l.text.contains('I always speak what I think'))
        .length;
    expect(refrains, 3);
  });

  test('a title matching a character name is never treated as a header', () {
    const macbethish = '''
MACBETH

ACT I

MACBETH. If it were done when 'tis done.

MACBETH

LADY MACBETH. Was the hope drunk?

MACBETH

MACBETH. We will proceed no further in this business.

MACBETH
''';
    final parser = ScriptParser();
    final script = parser.parse(macbethish, title: 'Macbeth');
    // The guard's contract: no speech is deleted (standalone "MACBETH"
    // lines act as cues, never as strippable headers).
    final texts = script.lines
        .where((l) => l.lineType == LineType.dialogue)
        .map((l) => l.text)
        .join('\n');
    expect(texts.contains("If it were done when 'tis done"), true);
    expect(texts.contains('Was the hope drunk'), true);
    expect(texts.contains('We will proceed no further'), true);
  });
}
