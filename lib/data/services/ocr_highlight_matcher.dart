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

  /// Raw OCR lines keep the speaker cue the parser consumed
  /// ("MRS. BENNET. Bingley." → the parsed line is just "Bingley."), so
  /// comparisons must also see the post-cue remainder.
  // GREEDY: a cue is often multi-part ("MR. BENNET. ", "MISS BINGLEY. ").
  // The lazy version stripped only "MR. ", leaving "BENNET" to break
  // containment against the parsed line — the single biggest cause of
  // mis-mapped pages (measured on the P&P corpus).
  static final _cueRe = RegExp(r"^[A-Z][A-Z .,&']{1,30}\.\s+");

  static String stripCue(String s) {
    final m = _cueRe.firstMatch(s);
    if (m == null) return s;
    final rest = s.substring(m.end);
    // An all-caps line ("MRS. BENNET. OH DEAR.") can be eaten whole —
    // keep the original rather than compare against nothing.
    return rest.trim().isEmpty ? s : rest;
  }

  /// Whole-word containment — "jane" must not match "janet".
  static bool _containsWord(String haystack, String needle) {
    var from = 0;
    while (true) {
      final i = haystack.indexOf(needle, from);
      if (i < 0) return false;
      final beforeOk = i == 0 || haystack[i - 1] == ' ';
      final endIdx = i + needle.length;
      final afterOk =
          endIdx == haystack.length || haystack[endIdx] == ' ';
      if (beforeOk && afterOk) return true;
      from = i + 1;
    }
  }

  /// Rects (normalized page coordinates) highlighting [target] among
  /// [lines]. Empty when nothing scores well enough to be worth showing —
  /// the caller should say so rather than highlight garbage.
  static List<Rect> locate(String target, List<OcrPageLine> lines) {
    final normTarget = normalize(target);
    if (normTarget.isEmpty || lines.isEmpty) return const [];
    // Micro-targets ("a", "no.") overlap-match half the page; only an
    // exact line hit is trustworthy for them.
    if (normTarget.length < 6) {
      // Word-boundary containment against the line and its post-cue body;
      // among candidates prefer the one whose body is closest in length to
      // the target ("Jane." prefers the line that IS "Jane.", not a long
      // sentence mentioning Jane).
      OcrPageLine? best;
      var bestExcess = 1 << 30;
      for (final l in lines) {
        final body = normalize(stripCue(l.text));
        final full = normalize(l.text);
        // Exact post-cue body ("MRS. BENNET. La." → "la") is the only
        // confident location for a 2-3 char line; longer short targets may
        // also match inside a line, but only a nearby-length one.
        if (body == normTarget) return [_rectOf(l)];
        if (normTarget.length < 4) continue;
        if (!_containsWord(body, normTarget) &&
            !_containsWord(full, normTarget)) {
          continue;
        }
        final excess = body.length - normTarget.length;
        if (excess >= 0 && excess < bestExcess) {
          bestExcess = excess;
          best = l;
        }
      }
      // A short target buried in a much longer line is not a confident
      // location — better to say so than to point at the wrong place.
      if (best != null && bestExcess <= 25) return [_rectOf(best)];
      return const [];
    }
    final targetTokens = normTarget.split(' ').toSet();

    var bestIdx = -1;
    var bestScore = 0.0;
    for (var i = 0; i < lines.length; i++) {
      final normLine = normalize(lines[i].text);
      if (normLine.isEmpty) continue;
      final normBody = normalize(stripCue(lines[i].text));
      final score = math.max(
        _score(normTarget, targetTokens, normLine),
        normBody == normLine ? 0.0 : _score(normTarget, targetTokens, normBody),
      );
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

  /// Best-scoring candidate for [target] among [candidates] (raw strings),
  /// or null when nothing clears [minScore]. Shared with the IMPORT's
  /// page mapping so both sides agree by construction: the viewer can only
  /// be asked to find a line on the page the import chose using this very
  /// scoring.
  static ({int index, double score})? bestMatch(
    String target,
    List<String> candidates, {
    double minScore = 0.45,
    double strongScore = 0.8,
    int start = 0,
    int? end,
  }) {
    final normTarget = normalize(target);
    if (normTarget.isEmpty) return null;
    final targetTokens = normTarget.split(' ').toSet();
    final last = end == null || end > candidates.length ? candidates.length : end;
    var bestIdx = -1;
    var best = 0.0;
    for (var i = start; i < last; i++) {
      final normLine = normalize(candidates[i]);
      if (normLine.isEmpty) continue;
      final normBody = normalize(stripCue(candidates[i]));
      final score = math.max(
        _score(normTarget, targetTokens, normLine),
        normBody == normLine ? 0.0 : _score(normTarget, targetTokens, normBody),
      );
      // LOCALITY FIRST: the caller scans forward through a document, so the
      // earliest STRONG match is the right one. Taking the global best in
      // the window instead let a distant better-scoring line win, dragging
      // the caller's cursor past everything between (measured: mapping
      // accuracy collapsed from 46% to 14%). Only when nothing is strong
      // does the best weak candidate win.
      if (score >= strongScore) return (index: i, score: score);
      if (score > best) {
        best = score;
        bestIdx = i;
      }
    }
    if (bestIdx < 0 || best < minScore) return null;
    return (index: bestIdx, score: best);
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
    // Weak: how much of the TARGET this line covers. Dividing by the
    // shorter side instead let a one-word OCR line ("Lydia.") score 0.7
    // just by appearing in the target — outscoring the line the text
    // actually came from. Coverage can't be gamed that way, and multi-line
    // speeches are handled by the forward/backward extension, not here.
    final lineTokens = normLine.split(' ').toSet();
    final overlap = targetTokens.intersection(lineTokens).length;
    if (overlap < 2 || targetTokens.isEmpty || lineTokens.isEmpty) return 0.0;
    // A parsed line is often assembled from SEVERAL raw OCR lines, so a raw
    // line covering only part of it must still score well: divide by the
    // shorter side (precision when the raw line is a subset). But a
    // one-or-two-token line ("Lydia.") would then score 1.0 for merely
    // appearing in the target, outscoring the real source line — so tiny
    // lines are scored on target coverage (recall) instead.
    final denom = lineTokens.length >= 3
        ? math.min(targetTokens.length, lineTokens.length)
        : targetTokens.length;
    return 0.9 * overlap / denom;
  }
}
