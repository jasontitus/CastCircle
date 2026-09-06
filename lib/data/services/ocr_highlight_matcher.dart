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

  static String normalize(String s) =>
      s.toLowerCase().replaceAll(_junkRe, ' ').replaceAll(_wsRe, ' ').trim();

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
      final afterOk = endIdx == haystack.length || haystack[endIdx] == ' ';
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
    final candidates = prepareCandidates([for (final line in lines) line.text]);

    // Micro-targets ("a", "no.") overlap-match half the page; only an
    // exact line hit is trustworthy for them.
    if (normTarget.length < 6) {
      // Word-boundary containment against the line and its post-cue body;
      // among candidates prefer the matching representation closest in
      // length to the target.
      var bestIdx = -1;
      var bestExcess = 1 << 30;
      for (var i = 0; i < candidates.length; i++) {
        final candidate = candidates[i];
        if (candidate.body == normTarget) return [_rectOf(lines[i])];
        if (normTarget.length < 4) continue;

        String? matched;
        if (_containsWord(candidate.body, normTarget)) {
          matched = candidate.body;
        } else if (_containsWord(candidate.full, normTarget)) {
          matched = candidate.full;
        }
        if (matched == null) continue;

        final excess = matched.length - normTarget.length;
        if (excess >= 0 && excess < bestExcess) {
          bestExcess = excess;
          bestIdx = i;
        }
      }
      // A short target buried in a much longer line is not a confident
      // location — better to say so than to point at the wrong place.
      if (bestIdx >= 0 && bestExcess <= 25) {
        return [_rectOf(lines[bestIdx])];
      }
      return const [];
    }
    final targetTokens = normTarget.split(' ').toSet();

    var bestIdx = -1;
    var bestScore = 0.0;
    for (var i = 0; i < candidates.length; i++) {
      final candidate = candidates[i];
      if (candidate.full.isEmpty) continue;
      final score = math.max(
        _score(normTarget, targetTokens, candidate.full, candidate.fullTokens),
        candidate.body == candidate.full
            ? 0.0
            : _score(
                normTarget,
                targetTokens,
                candidate.body,
                candidate.bodyTokens,
              ),
      );
      if (score > bestScore) {
        bestScore = score;
        bestIdx = i;
      }
    }
    // Below this the "match" is likely a couple of stray shared words.
    if (bestIdx < 0 || bestScore < 0.45) return const [];

    // A speech's SECOND raw line often outscores its first (the first
    // carries the cue prefix) — walk backward using the cached token sets.
    var startIdx = bestIdx;
    while (startIdx > 0 && bestIdx - startIdx < 3) {
      final prevTokens = candidates[startIdx - 1].fullTokens;
      if (prevTokens.isEmpty) break;
      final overlap = _overlapCount(targetTokens, prevTokens);
      if (overlap / math.max(prevTokens.length, 1) < 0.5) break;
      startIdx--;
    }

    final rects = <Rect>[
      for (var j = startIdx; j <= bestIdx; j++) _rectOf(lines[j]),
    ];

    // Extend over following lines while they keep covering target tokens
    // the matched region hasn't consumed yet (multi-line dialogue).
    final consumed = <String>{
      for (var j = startIdx; j <= bestIdx; j++) ...candidates[j].fullTokens,
    };
    var remaining = targetTokens.difference(consumed);
    var i = bestIdx + 1;
    while (i < lines.length && rects.length < 4 && remaining.length >= 2) {
      final nextTokens = candidates[i].fullTokens;
      if (nextTokens.isEmpty) break;
      final overlap = _overlapCount(remaining, nextTokens);
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
    return bestPreparedMatch(
      target,
      prepareCandidates(candidates),
      minScore: minScore,
      strongScore: strongScore,
      start: start,
      end: end,
    );
  }

  /// Normalize and tokenize a candidate set once when several adjacent
  /// targets will be matched against the same OCR page/document window.
  static List<OcrMatchCandidate> prepareCandidates(List<String> candidates) {
    return [
      for (var i = 0; i < candidates.length; i++)
        (() {
          final full = normalize(candidates[i]);
          final body = normalize(stripCue(candidates[i]));
          final fullTokens = full.isEmpty
              ? const <String>{}
              : full.split(' ').toSet();
          return OcrMatchCandidate(
            index: i,
            full: full,
            body: body,
            fullTokens: fullTokens,
            bodyTokens: body == full
                ? fullTokens
                : body.isEmpty
                ? const <String>{}
                : body.split(' ').toSet(),
          );
        })(),
    ];
  }

  /// Match against candidates prepared by [prepareCandidates].
  static ({int index, double score})? bestPreparedMatch(
    String target,
    List<OcrMatchCandidate> candidates, {
    double minScore = 0.45,
    double strongScore = 0.8,
    int start = 0,
    int? end,
  }) {
    final normTarget = normalize(target);
    if (normTarget.isEmpty) return null;
    final targetTokens = normTarget.split(' ').toSet();
    final last = end == null || end > candidates.length
        ? candidates.length
        : end;
    var bestIdx = -1;
    var best = 0.0;
    for (var i = start; i < last; i++) {
      final candidate = candidates[i];
      if (candidate.full.isEmpty) continue;
      final score = math.max(
        _score(normTarget, targetTokens, candidate.full, candidate.fullTokens),
        candidate.body == candidate.full
            ? 0.0
            : _score(
                normTarget,
                targetTokens,
                candidate.body,
                candidate.bodyTokens,
              ),
      );
      // LOCALITY FIRST: the caller scans forward through a document, so the
      // earliest STRONG match is the right one. Only when nothing is strong
      // does the best weak candidate win.
      if (score >= strongScore) {
        return (index: candidate.index, score: score);
      }
      if (score > best) {
        best = score;
        bestIdx = candidate.index;
      }
    }
    if (bestIdx < 0 || best < minScore) return null;
    return (index: bestIdx, score: best);
  }

  static Rect _rectOf(OcrPageLine l) =>
      Rect.fromLTWH(l.left, l.top, l.width, l.height);
  static int _overlapCount(Set<String> a, Set<String> b) {
    final smaller = a.length <= b.length ? a : b;
    final larger = identical(smaller, a) ? b : a;
    var count = 0;
    for (final token in smaller) {
      if (larger.contains(token)) count++;
    }
    return count;
  }

  static double _score(
    String normTarget,
    Set<String> targetTokens,
    String normLine,
    Set<String> lineTokens,
  ) {
    // Strong: substantial containment either way. A candidate fragment
    // contained in a long target earns perfection only when it covers a
    // meaningful share of the target's words; generic fragments otherwise
    // cannot tie a later exact source.
    if (normLine.length >= 8 && _containsWord(normTarget, normLine)) {
      final overlap = _overlapCount(targetTokens, lineTokens);
      final targetCoverage = targetTokens.isEmpty
          ? 0.0
          : overlap / targetTokens.length;
      if (targetCoverage >= 0.5) return 1.0;
    }
    if (normTarget.length >= 8 && _containsWord(normLine, normTarget)) {
      return 1.0;
    }
    // Medium: same opening (heavily-rewritten lines).
    if (normLine.length >= 12 &&
        normTarget.length >= 12 &&
        normLine.substring(0, 12) == normTarget.substring(0, 12)) {
      return 0.8;
    }
    final overlap = _overlapCount(targetTokens, lineTokens);
    if (overlap < 2 || targetTokens.isEmpty || lineTokens.isEmpty) return 0.0;
    // A parsed line is often assembled from several raw OCR lines, so partial
    // candidates remain usable. Tiny candidates are scored on target coverage.
    final denom = lineTokens.length >= 3
        ? math.min(targetTokens.length, lineTokens.length)
        : targetTokens.length;
    final score = 0.9 * overlap / denom;
    // Contained fragments with little target coverage must remain below the
    // early-return threshold so a later exact candidate gets considered.
    if (_containsWord(normTarget, normLine)) return math.min(score, 0.79);
    return score;
  }
}

class OcrMatchCandidate {
  final int index;
  final String full;
  final String body;
  final Set<String> fullTokens;
  final Set<String> bodyTokens;

  const OcrMatchCandidate({
    required this.index,
    required this.full,
    required this.body,
    required this.fullTokens,
    required this.bodyTokens,
  });
}
