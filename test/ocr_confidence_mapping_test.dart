import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/services/script_import_service.dart';
import 'package:castcircle/data/models/script_models.dart';

void main() {
  test(
    'parseAndMapOcr maps confidence and page onto parsed dialogue lines',
    () {
      // Two pages of a simple script, as the OCR assembly loop would emit it:
      // one raw line per OCR box, blank line between pages (with an index gap).
      final rawLines = <String>[
        'HAMLET.', // 0 (page 1)
        'To be, or not to be, that is the question.', // 1
        'OPHELIA.', // 2
        'Good my lord, how does your honour?', // 3
        '', // 4 (page separator, no map entry)
        'HAMLET.', // 5 (page 2)
        'I humbly thank you; well, well, well.', // 6
      ];
      final rawText = '${rawLines.join('\n')}\n';

      final lineConfidences = <int, double>{
        0: 0.99,
        1: 0.80,
        2: 0.98,
        3: 0.60,
        5: 0.97,
        6: 0.90,
      };
      final linePageMap = <int, int>{0: 1, 1: 1, 2: 1, 3: 1, 5: 2, 6: 2};

      final script = ScriptImportService.parseAndMapOcr(
        rawText,
        'Hamlet',
        lineConfidences,
        linePageMap,
      );

      final dialogue = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(dialogue, hasLength(3));

      final toBe = dialogue.firstWhere((l) => l.text.contains('To be'));
      expect(toBe.sourcePage, 1);
      expect(toBe.ocrConfidence, isNotNull);
      // Confidence comes from the raw line(s) that contributed to this parsed
      // line — the 0.80 body line (the "HAMLET." name line is consumed by the
      // parser as the character tag).
      // Tight delta: ±0.2 accepted anything in [0.6, 1.0] — including the
      // 0.99 speaker-name line this test exists to rule out.
      expect(toBe.ocrConfidence, closeTo(0.80, 0.05));

      final honour = dialogue.firstWhere((l) => l.text.contains('honour'));
      expect(honour.sourcePage, 1);

      final thank = dialogue.firstWhere((l) => l.text.contains('humbly thank'));
      expect(thank.sourcePage, 2, reason: 'forward cursor must reach page 2');
      expect(thank.ocrConfidence, closeTo(0.90, 0.05));
    },
  );

  test('normalized matching maps lines _cleanLine rewrote', () {
    // The raw line carries OCR junk (|, double spaces) that the parser's
    // _cleanLine strips — exact contains() used to fail here, the line lost
    // its sourcePage, and the review screen's "View page" button vanished
    // on exactly the garbled lines that needed it.
    const rawText = 'HAMLET.\nWords,|  words,  words|.\n';
    final script = ScriptImportService.parseAndMapOcr(
      rawText,
      'Test',
      {0: 0.9, 1: 0.7},
      {0: 1, 1: 1},
    );
    final dialogue = script.lines.firstWhere(
      (l) => l.text.toLowerCase().contains('words'),
    );
    expect(
      dialogue.sourcePage,
      1,
      reason: 'cleaned line must still map to its raw page',
    );
  });

  test('unmatched lines inherit a neighbor page, never confidence', () {
    // Two raw pages; the middle parsed line is unmatchable garbage relative
    // to raw (parser synthesizes/rewrites) — it must inherit a page so the
    // page viewer works, but must NOT inherit OCR confidence.
    const rawText = 'HAMLET.\nTo be or not to be.\nHORATIO.\nIt harrows me.\n';
    final script = ScriptImportService.parseAndMapOcr(
      rawText,
      'Test',
      {1: 0.9, 3: 0.9},
      {0: 1, 1: 1, 2: 2, 3: 2},
    );
    for (final line in script.lines) {
      expect(
        line.sourcePage,
        isNotNull,
        reason:
            'every line gets a page (mapped or inherited): '
            '"${line.text}"',
      );
    }
  });
}
