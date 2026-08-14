import 'dart:math' as math;
import 'dart:ui';

import 'paddle_ocr_channel.dart';

/// Locates a script line's text among a page's freshly-OCR'd lines so the
/// page viewer can highlight where it came from.
///
/// Matching mirrors the import's page-mapping philosophy: normalize both
/// sides (lowercase, junk → space, collapsed whitespace) so OCR junk and
/// parser cleanup can't break the comparison, then score containment,
/// prefix, and token overlap. A parsed line often spans several consecutive
/// OCR lines, so after the best seed match the highlight greedily extends
/// to following lines whose tokens keep covering the target.
class OcrHighlightMatcher {
  static final _junkRe = RegExp(r'[^a-z0-9 ]');
  static final _wsRe = RegExp(r'\s+');

  static String normalize(String s) => s
      .toLowerCase()
      .replaceAll(_junkRe, ' ')
      .replaceAll(_wsRe, ' ')
      .trim();

  /// Rects (normalized page coordinates) highlighting [target] among
  /// [lines]. Empty when nothing scores well enough to be worth showing —
  /// the caller should say so rather than highlight garbage.
  static List<Rect> locate(String target, List<OcrPageLine> lines) {
    final normTarget = normalize(target);
    if (normTarget.isEmpty || lines.isEmpty) return const [];
    // Micro-targets ("a", "no.") overlap-match half the page; only an
    // exact line hit is trustworthy for them.
    if (normTarget.length < 6) {
      for (final l in lines) {
        if (normalize(l.text) == normTarget) return [_rectOf(l)];
      }
      return const [];
    }
    final targetTokens = normTarget.split(' ').toSet();

    var bestIdx = -1;
    var bestScore = 0.0;
    for (var i = 0; i < lines.length; i++) {
      final normLine = normalize(lines[i].text);
      if (normLine.isEmpty) continue;
      final score = _score(normTarget, targetTokens, normLine);
      if (score > bestScore) {
        bestScore = score;
        bestIdx = i;
      }
    }
    // Below this the "match" is likely a couple of stray shared words.
    if (bestIdx < 0 || bestScore < 0.45) return const [];

    // A speech's SECOND raw line often outscores its first (the first
    // carries the "DARCY." cue prefix, breaking containment) — walk
    // backward to include earlier lines that still cover target tokens,
    // so the highlight starts where the speech starts.
    var startIdx = bestIdx;
    while (startIdx > 0 && bestIdx - startIdx < 3) {
      final prevTokens = normalize(lines[startIdx - 1].text).split(' ').toSet();
      if (prevTokens.isEmpty) break;
      final overlap = targetTokens.intersection(prevTokens).length;
      if (overlap / math.max(prevTokens.length, 1) < 0.5) break;
      startIdx--;
    }

    final rects = <Rect>[
      for (var j = startIdx; j <= bestIdx; j++) _rectOf(lines[j]),
    ];

    // Extend over following lines while they keep covering target tokens
    // the matched region hasn't consumed yet (multi-line dialogue).
    final consumed = <String>{
      for (var j = startIdx; j <= bestIdx; j++)
        ...normalize(lines[j].text).split(' '),
    };
    var remaining = targetTokens.difference(consumed);
    var i = bestIdx + 1;
    while (i < lines.length && rects.length < 4 && remaining.length >= 2) {
      final nextTokens = normalize(lines[i].text).split(' ').toSet();
      if (nextTokens.isEmpty) break;
      final overlap = remaining.intersection(nextTokens).length;
      if (overlap / math.max(nextTokens.length, 1) < 0.5) break;
      rects.add(_rectOf(lines[i]));
      remaining = remaining.difference(nextTokens);
      i++;
    }
    return rects;
  }

  static Rect _rectOf(OcrPageLine l) =>
      Rect.fromLTWH(l.left, l.top, l.width, l.height);

  static double _score(
      String normTarget, Set<String> targetTokens, String normLine) {
    // Strong: substantial containment either way.
    if (normLine.length >= 8 && normTarget.contains(normLine)) return 1.0;
    if (normTarget.length >= 8 && normLine.contains(normTarget)) return 1.0;
    // Medium: same opening (heavily-rewritten lines).
    if (normLine.length >= 12 &&
        normTarget.length >= 12 &&
        normLine.substring(0, 12) == normTarget.substring(0, 12)) {
      return 0.8;
    }
    // Weak: token overlap (Jaccard against the shorter side, so a long OCR
    // line containing most of a short target still scores).
    final lineTokens = normLine.split(' ').toSet();
    final overlap = targetTokens.intersection(lineTokens).length;
    final denom = math.min(targetTokens.length, lineTokens.length);
    if (denom == 0) return 0.0;
    return 0.7 * overlap / denom;
  }
}
