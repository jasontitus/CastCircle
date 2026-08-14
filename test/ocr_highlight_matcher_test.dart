import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/services/ocr_highlight_matcher.dart';
import 'package:castcircle/data/services/paddle_ocr_channel.dart';

OcrPageLine _l(String text, double top) => OcrPageLine(
    text: text, left: 0.1, top: top, width: 0.8, height: 0.03);

void main() {
  final page = <OcrPageLine>[
    _l('PRIDE AND PREJUDICE', 0.05),
    _l('DARCY. She is tolerable, but', 0.30),
    _l('not handsome enough to tempt me.', 0.33),
    _l('BINGLEY. I would not be so fastidious', 0.36),
    _l('as you are for a kingdom!', 0.39),
  ];

  test('exact line highlights its box', () {
    final rects = OcrHighlightMatcher.locate(
        'I would not be so fastidious as you are for a kingdom!', page);
    expect(rects, isNotEmpty);
    expect(rects.first.top, closeTo(0.36, 0.001));
    // Extends over the second raw line of the same speech.
    expect(rects.length, 2);
    expect(rects[1].top, closeTo(0.39, 0.001));
  });

  test('garbled OCR text still matches via normalization/prefix', () {
    // Junk chars + spacing the parser would have cleaned.
    final rects = OcrHighlightMatcher.locate(
        'She is tolerable,| but at ifiient', page);
    expect(rects, isNotEmpty);
    expect(rects.first.top, closeTo(0.30, 0.001));
  });

  test('unrelated text highlights nothing', () {
    final rects = OcrHighlightMatcher.locate(
        'completely different words entirely elsewhere', page);
    expect(rects, isEmpty);
  });

  test('tiny fragments cannot false-match', () {
    final rects = OcrHighlightMatcher.locate('a', page);
    expect(rects, isEmpty);
  });
}
