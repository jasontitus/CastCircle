import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/ocr_confidence_service.dart';

void main() {
  // The spell checker loads the bundled `en` dictionary via the package's
  // registered language data, which needs the Flutter binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = OcrConfidenceService.instance;

  // Inject a small theatrical vocab instead of loading the asset bundle.
  setUp(() {
    service.setTheatricalVocab({'netherfield', 'wickham', 'pemberley'});
  });

  tearDown(service.dispose);

  ScriptLine line(String text, {double? ocrConfidence}) => ScriptLine(
        id: 't',
        act: '',
        scene: '',
        lineNumber: 1,
        orderIndex: 0,
        character: '',
        text: text,
        lineType: LineType.dialogue,
        ocrConfidence: ocrConfidence,
      );

  group('tokenizer', () {
    test('curly open-quote glued to a word scores correctly', () {
      // "“I have no objection” said she" — the curly quote must not glue to "I"
      // and create an invalid token. All words are valid English.
      expect(service.scoreLine('“I have no objection” said she'), 1.0);
    });

    test('curly-apostrophe possessive splits cleanly (Darcy’s)', () {
      // Darcy’s -> darcy (vocab/whitelist) + s; both should not drag the score
      // below 1.0. "her" and "sister" are dictionary words.
      service.setTheatricalVocab({'darcy'});
      expect(service.scoreLine('Darcy’s sister was here'), 1.0);
    });

    test('straight-apostrophe possessive at word edge is stripped', () {
      // "the sister's house" — sister' must strip to sister.
      expect(service.scoreLine("the sister's house"), 1.0);
    });

    test('markdown underscore emphasis is stripped (_emphasis_)', () {
      expect(service.scoreLine('this is _emphasis_ here'), 1.0);
    });

    test('markdown asterisk emphasis is stripped (*bold*)', () {
      expect(service.scoreLine('this is *bold* text'), 1.0);
    });

    test('ALL-CAPS speaker tokens are skipped', () {
      // ELIZABETH is ALL-CAPS and skipped; "speaks" is a real word.
      expect(service.scoreLine('ELIZABETH speaks now'), 1.0);
    });
  });

  group('diacritic strip', () {
    test('spurious accent on a real word still scores valid (speáks)', () {
      expect(service.scoreLine('she speáks softly'), 1.0);
    });

    test('multiple accented real words score valid', () {
      // résumé-style stray accents on common words.
      expect(service.scoreLine('thé qûick brown fox'), 1.0);
    });
  });

  group('theatrical vocab', () {
    test('netherfield is treated as valid', () {
      expect(service.scoreLine('walked to netherfield today'), 1.0);
    });

    test('wickham is treated as valid', () {
      expect(service.scoreLine('wickham arrived early'), 1.0);
    });

    test('a non-vocab garbled token still fails', () {
      // "xqzkw" is not in dict, whitelist, or vocab.
      // "the" + "xqzkw" -> 1 of 2 valid = 0.5.
      final score = service.scoreLine('the xqzkw');
      expect(score, closeTo(0.5, 0.01));
    });
  });

  group('3-way classification (validated thresholds)', () {
    test('clean line with high rec-confidence -> ok', () {
      final scored = service.scoreScript([
        line('I have no objection to the proposal', ocrConfidence: 0.99),
      ]);
      expect(scored.single.reviewStatus, OcrReviewStatus.ok);
    });

    test('garbled line (low dict, decent conf) -> review', () {
      // Mostly nonsense words but a confident OCR pass — high-conf garbage that
      // the dict catches. dict < 0.80, recConf >= 0.65 -> review.
      final scored = service.scoreScript([
        line('xqzkw vbnmq plkjh wrtyu', ocrConfidence: 0.9),
      ]);
      expect(scored.single.reviewStatus, OcrReviewStatus.review);
    });

    test('low rec-conf alone (clean text) -> ok (NOT flagged)', () {
      // dict = 1.0 (valid words) with a middling Paddle recConf 0.70 must NOT
      // flag: PaddleOCR routinely scores good dialogue at 0.65–0.85, so a
      // recConf gate flags ~90% of a clean script (Mac-verified on Pride &
      // Prejudice). The dictionary is the reliable signal.
      final scored = service.scoreScript([
        line('she walked to the house', ocrConfidence: 0.70),
      ]);
      expect(scored.single.reviewStatus, OcrReviewStatus.ok);
    });

    test('low rec-conf AND low dict -> likelyNotScript', () {
      // recConf 0.50 < 0.65 AND dict < 0.50 -> handwriting / margin note.
      final scored = service.scoreScript([
        line('xqzkw vbnmq plkjh', ocrConfidence: 0.50),
      ]);
      expect(scored.single.reviewStatus, OcrReviewStatus.likelyNotScript);
    });

    test('display confidence tracks the dictionary signal, not recConf', () {
      // dict = 1.0 (clean text); a dipped recConf (0.70) must NOT drag the
      // display confidence down, or the editor would highlight clean lines.
      final scored = service.scoreScript([
        line('she walked to the house', ocrConfidence: 0.70),
      ]);
      expect(scored.single.ocrConfidence, closeTo(1.0, 0.001));
    });

    test('null rec-confidence defaults to 1.0 (dict-only gating)', () {
      // No Paddle confidence: clean text -> ok; garbled -> review (not junk,
      // since recConf defaults to 1.0 which is above the junk gate).
      final ok = service.scoreScript([line('she walked home')]);
      expect(ok.single.reviewStatus, OcrReviewStatus.ok);

      final garbled = service.scoreScript([line('xqzkw vbnmq plkjh')]);
      expect(garbled.single.reviewStatus, OcrReviewStatus.review);
    });

    test('classify helper matches the documented gates', () {
      // likelyNotScript: recConf < 0.65 AND dict < 0.50
      expect(OcrConfidenceService.classify(0.40, 0.60),
          OcrReviewStatus.likelyNotScript);
      // review: dict < 0.80 (conf fine)
      expect(OcrConfidenceService.classify(0.70, 0.99),
          OcrReviewStatus.review);
      // ok: clean text (dict high) is NOT flagged by a low recConf alone
      expect(OcrConfidenceService.classify(1.0, 0.80), OcrReviewStatus.ok);
      expect(OcrConfidenceService.classify(1.0, 0.50), OcrReviewStatus.ok);
      // ok: both above gates
      expect(OcrConfidenceService.classify(0.90, 0.90), OcrReviewStatus.ok);
      // boundary: low conf but dict >= 0.50 stays in review, not junk
      expect(OcrConfidenceService.classify(0.60, 0.60),
          OcrReviewStatus.review);
    });
  });

  group('scoreScript bookkeeping', () {
    test('header and empty lines are left untouched', () {
      final header = ScriptLine(
        id: 'h',
        act: 'I',
        scene: '',
        lineNumber: 0,
        orderIndex: 0,
        character: '',
        text: 'ACT I',
        lineType: LineType.header,
      );
      final scored = service.scoreScript([header]);
      expect(scored.single.reviewStatus, OcrReviewStatus.ok);
      // Header confidence is not overwritten.
      expect(scored.single.ocrConfidence, isNull);
    });
  });
}
