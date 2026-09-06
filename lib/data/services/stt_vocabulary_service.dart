import 'package:flutter/foundation.dart'; // also re-exports Int32List

import '../models/script_models.dart';
import 'stt_service.dart';

// Hoisted out of the correction hot path: `RegExp(...)` compiles the pattern
// on every construction, and these ran once per word (sometimes once per
// vocabulary candidate) on every partial STT result.
final _wsRe = RegExp(r'\s+');
final _nonWordRe = RegExp(r'[^\w]');
final _nonWordSpaceRe = RegExp(r'[^\w\s]');
final _nonWordSpaceApostropheRe = RegExp("[^\\w\\s']");
final _tokenPartsRe = RegExp(r"^([^\w]*)([\w']+)([^\w]*)$");

/// Vocabulary-aware post-processing for STT results.
///
/// Extracts vocabulary from the script (character names, unusual words,
/// archaic language) and corrects Whisper transcription errors by matching
/// against known script text. Works at two levels:
///
/// **Per-production:** Builds a vocabulary from all lines in the script.
/// Character names, place names, and period-specific language get corrected
/// automatically (e.g. "Macbeth" not "mac beth", "thou" not "thou's").
///
/// **Per-actor:** Tracks recurring misrecognitions for each actor and
/// learns correction patterns over time (e.g. if actor X's "forsooth"
/// always gets recognized as "for sooth", auto-correct it).
class SttVocabularyService {
  SttVocabularyService._();
  static final instance = SttVocabularyService._();

  // Per-production vocabulary, keyed by productionId
  final Map<String, _ProductionVocabulary> _vocabularies = {};

  // Per-actor correction patterns: productionId:actorId -> {wrong: right}
  final Map<String, Map<String, String>> _actorCorrections = {};

  // The expected line text is identical for every partial result of a line,
  // so its word set is tokenized once per line instead of once per result.
  String? _expectedCacheKey;
  Set<String> _expectedCacheWords = const {};

  // ── Vocabulary Building ──────────────────────────────

  /// Build vocabulary from a parsed script. Call this when a script is loaded.
  void buildFromScript(String productionId, List<ScriptLine> lines) {
    if (!_vocabularies.containsKey(productionId) &&
        _vocabularies.length >= _maxLoadedProductions) {
      clearProduction(_vocabularies.keys.first);
    }

    final vocab = _ProductionVocabulary();

    // Extract character names
    for (final line in lines) {
      if (line.character.isNotEmpty) {
        vocab.characterNames.add(line.character);
        // Split multi-word names
        for (final part in line.character.split(_wsRe)) {
          if (part.length > 2) vocab.importantWords.add(part.toLowerCase());
        }
      }
    }

    // Extract vocabulary from dialogue — preserve apostrophes for
    // contractions and archaic forms ('tis, o'er, don't)
    for (final line in lines) {
      if (line.lineType != LineType.dialogue) continue;
      final words = _tokenize(line.text);
      for (final word in words) {
        vocab.wordFrequency[word] = (vocab.wordFrequency[word] ?? 0) + 1;
      }
      // Also extract words preserving apostrophes for hints
      final rawWords = line.text
          .replaceAll(_nonWordSpaceApostropheRe, '')
          .toLowerCase()
          .split(_wsRe)
          .where((w) => w.isNotEmpty);
      for (final w in rawWords) {
        if (w.contains("'")) {
          vocab.importantWords.add(w); // 'tis, o'er, etc.
        }
      }
    }

    // Find unusual words (appear in script but might confuse generic STT)
    // Words that appear multiple times are likely intentional vocabulary
    for (final entry in vocab.wordFrequency.entries) {
      if (entry.value >= 2 && entry.key.length > 3) {
        vocab.importantWords.add(entry.key);
      }
    }

    _vocabularies[productionId] = vocab;
    debugPrint(
      'SttVocabulary: Built for production $productionId — '
      '${vocab.characterNames.length} characters, '
      '${vocab.importantWords.length} important words',
    );
  }

  /// Get vocabulary hints for the recognizer's contextualStrings.
  ///
  /// Returns character names and important/unusual words from the script.
  /// These are passed alongside per-line hints to improve recognition
  /// of script-specific vocabulary.
  List<String> getScriptHints(String productionId) {
    final vocab = _vocabularies[productionId];
    if (vocab == null) return const [];

    final hints = <String>{};
    // Character names
    hints.addAll(vocab.characterNames);
    // Important words (appear 2+ times, length > 3)
    hints.addAll(vocab.importantWords);
    // Cap at 100 to stay within reasonable limits for contextualStrings
    return hints.take(100).toList();
  }

  /// Clear vocabulary for a production.
  void clearProduction(String productionId) {
    _vocabularies.remove(productionId);
    _actorCorrections.removeWhere((key, _) => key.startsWith('$productionId:'));
  }

  // ── Correction ───────────────────────────────────────

  /// Correct a transcription result using production vocabulary and
  /// optionally the expected line text.
  ///
  /// [recognized] — raw Whisper output
  /// [expectedText] — the script line text we expect (if known)
  /// [productionId] — which production's vocabulary to use
  /// [actorId] — optional actor for per-actor corrections
  String correct({
    required String recognized,
    String? expectedText,
    required String productionId,
    String? actorId,
  }) {
    if (recognized.isEmpty) return recognized;

    var result = recognized;

    // 1. Apply per-actor learned corrections in one token pass. Scanning the
    // whole partial once also guarantees corrections never match substrings
    // inside unrelated words.
    if (actorId != null) {
      final corrections = _actorCorrections['$productionId:$actorId'];
      if (corrections != null && corrections.isNotEmpty) {
        result = _applyLearnedCorrections(result, corrections);
      }
    }

    // 2. Apply vocabulary-based word corrections
    final vocab = _vocabularies[productionId];
    if (vocab != null) {
      result = _correctWithVocabulary(
        result,
        vocab,
        // Words the expected line already contains verbatim are skipped: the
        // whole-script scan could only swap them for a *different* script
        // word, and step 3 would align them straight back. Skipping them
        // keeps the result identical while removing nearly all of the
        // O(words × vocabulary) work on a line the actor is reading right.
        resolvedWords: expectedText == null
            ? null
            : _expectedWordSet(expectedText),
      );
    }

    // 3. If we know the expected line, do targeted correction
    if (expectedText != null) {
      result = _correctAgainstExpected(result, expectedText);
    }

    return result;
  }

  /// After comparing recognized vs expected, learn correction patterns
  /// for this actor. Call this after each successful line match.
  void learnFromAttempt({
    required String productionId,
    required String actorId,
    required String recognized,
    required String expected,
  }) {
    final recognizedWords = _tokenize(recognized);
    final expectedWords = _tokenize(expected);
    final substitutions = _exactAnchoredSubstitutions(
      recognizedWords,
      expectedWords,
    );
    Map<String, String>? corrections;

    for (final (recognizedIndex, expectedIndex) in substitutions) {
      final wrong = recognizedWords[recognizedIndex];
      final right = expectedWords[expectedIndex];
      if (wrong == right || wrong.length < 4 || right.length < 4) continue;

      // Short or proportionally large rewrites are generic words, not
      // high-confidence pronunciations of the same token.
      final maxDistance =
          (wrong.length > right.length ? wrong.length : right.length) ~/ 3;
      final threshold = maxDistance > 2 ? 2 : maxDistance;
      if (_editDistanceAtMost(wrong, right, threshold) > threshold) continue;

      corrections ??= _actorCorrections.putIfAbsent(
        '$productionId:$actorId',
        () => <String, String>{},
      );
      if (corrections.length >= 500 && !corrections.containsKey(wrong)) {
        corrections.remove(corrections.keys.first);
      }
      corrections[wrong] = right;
    }
  }

  /// Get per-actor correction count for display.
  int getActorCorrectionCount(String productionId, String actorId) {
    final key = '$productionId:$actorId';
    return _actorCorrections[key]?.length ?? 0;
  }

  /// Get all learned corrections for an actor (for debug/display).
  Map<String, String> getActorCorrections(String productionId, String actorId) {
    final key = '$productionId:$actorId';
    return Map.unmodifiable(_actorCorrections[key] ?? {});
  }

  // ── Improved Match Score ─────────────────────────────

  /// Enhanced match score that applies vocabulary correction before scoring.
  double correctedMatchScore({
    required String expected,
    required String recognized,
    required String productionId,
    String? actorId,
  }) {
    final corrected = correct(
      recognized: recognized,
      expectedText: expected,
      productionId: productionId,
      actorId: actorId,
    );
    return _matchScore(expected, corrected);
  }

  // ── Internal ─────────────────────────────────────────

  /// The set of words the expected line already contains, cached per line.
  Set<String> _expectedWordSet(String expectedText) {
    if (_expectedCacheKey == expectedText) return _expectedCacheWords;
    _expectedCacheKey = expectedText;
    _expectedCacheWords = _tokenize(expectedText).toSet();
    return _expectedCacheWords;
  }

  /// Correct words using production vocabulary (fuzzy match).
  ///
  /// [resolvedWords] — words the caller already accounts for (the expected
  /// line); they keep their recognized spelling and skip the scan entirely.
  String _correctWithVocabulary(
    String text,
    _ProductionVocabulary vocab, {
    Set<String>? resolvedWords,
  }) {
    final words = text.split(_wsRe);
    final corrected = <String>[];

    for (final word in words) {
      final lower = word.toLowerCase().replaceAll(_nonWordRe, '');
      if (lower.isEmpty || (resolvedWords?.contains(lower) ?? false)) {
        corrected.add(word);
        continue;
      }

      // Memoized per production: partial results repeat the same prefix
      // words several times a second, so each distinct word pays for the
      // vocabulary scan once instead of once per result.
      String? bestMatch;
      if (vocab.correctionCache.containsKey(lower)) {
        bestMatch = vocab.correctionCache[lower];
      } else {
        bestMatch = _bestVocabularyMatch(lower, vocab);
        // Keyed by recognized words, so bound it against a long session.
        if (vocab.correctionCache.length >= _correctionCacheLimit) {
          vocab.correctionCache.clear();
        }
        vocab.correctionCache[lower] = bestMatch;
      }

      corrected.add(bestMatch ?? word);
    }

    return corrected.join(' ');
  }

  /// Closest vocabulary word to [lower] within edit distance 3 (exclusive),
  /// or null. Character names win ties only if strictly closer, and the
  /// first candidate at a given distance wins — same as scanning naively.
  static String? _bestVocabularyMatch(
    String lower,
    _ProductionVocabulary vocab,
  ) {
    String? bestMatch;
    var bestDistance = 3; // max edit distance to consider

    for (final vocabWord in vocab.scanWords) {
      // Edit distance is never less than the length difference, so a
      // candidate this far off can't beat bestDistance — skip the DP.
      // Removes ~90% of the distance computations on a real script.
      if ((vocabWord.length - lower.length).abs() >= bestDistance) continue;
      final dist = _editDistanceAtMost(lower, vocabWord, bestDistance - 1);
      if (dist > 0 && dist < bestDistance) {
        bestDistance = dist;
        bestMatch = vocabWord;
        // Distance 0 is ignored (identical word), so 1 is unbeatable.
        if (bestDistance == 1) return bestMatch;
      }
    }

    // Also check character names (case-preserved)
    for (final part in vocab.nameParts) {
      if ((part.lower.length - lower.length).abs() >= bestDistance) continue;
      final dist = _editDistanceAtMost(lower, part.lower, bestDistance - 1);
      if (dist > 0 && dist < bestDistance) {
        bestDistance = dist;
        bestMatch = part.cased;
        if (bestDistance == 1) return bestMatch;
      }
    }

    return bestMatch;
  }

  /// Correct near-matching words against the expected line with bounded,
  /// ordered lookahead. Recognition partials are cumulative and mostly
  /// aligned, so a small window handles insertions/deletions without rebuilding
  /// an O(recognized × expected) matrix several times per second.
  String _correctAgainstExpected(String recognized, String expected) {
    final recWords = recognized.split(_wsRe);
    final expWords = expected.split(_wsRe);
    if (recWords.isEmpty || expWords.isEmpty) return recognized;

    final recNorm = [
      for (final w in recWords) w.toLowerCase().replaceAll(_nonWordRe, ''),
    ];
    final expNorm = [
      for (final w in expWords) w.toLowerCase().replaceAll(_nonWordRe, ''),
    ];
    final corrected = List<String>.from(recWords);
    for (final (recognizedIndex, expectedIndex) in _alignNearWords(
      recNorm,
      expNorm,
    )) {
      if (recNorm[recognizedIndex] != expNorm[expectedIndex]) {
        corrected[recognizedIndex] = expWords[expectedIndex];
      }
    }
    return corrected.join(' ');
  }

  static List<(int, int)> _alignNearWords(
    List<String> recognized,
    List<String> expected,
  ) {
    const lookahead = 3;
    final aligned = <(int, int)>[];
    var i = 0;
    var j = 0;

    bool near(int ri, int ej) =>
        _editDistanceAtMost(recognized[ri], expected[ej], 2) <= 2;

    while (i < recognized.length && j < expected.length) {
      if (recognized[i] == expected[j]) {
        aligned.add((i, j));
        i++;
        j++;
        continue;
      }

      // Prefer exact anchors over a merely similar positional pair so an
      // insertion/deletion shift does not cascade corrections across a
      // partial result.
      int? exactRecognizedAhead;
      int? exactExpectedAhead;
      for (var offset = 1; offset <= lookahead; offset++) {
        if (exactRecognizedAhead == null &&
            i + offset < recognized.length &&
            recognized[i + offset] == expected[j]) {
          exactRecognizedAhead = offset;
        }
        if (exactExpectedAhead == null &&
            j + offset < expected.length &&
            recognized[i] == expected[j + offset]) {
          exactExpectedAhead = offset;
        }
      }
      if (exactRecognizedAhead != null || exactExpectedAhead != null) {
        if (exactRecognizedAhead != null &&
            (exactExpectedAhead == null ||
                exactRecognizedAhead <= exactExpectedAhead)) {
          i++;
        } else {
          j++;
        }
        continue;
      }

      if (near(i, j)) {
        aligned.add((i, j));
        i++;
        j++;
        continue;
      }

      int? recognizedAhead;
      int? expectedAhead;
      for (var offset = 1; offset <= lookahead; offset++) {
        if (recognizedAhead == null &&
            i + offset < recognized.length &&
            near(i + offset, j)) {
          recognizedAhead = offset;
        }
        if (expectedAhead == null &&
            j + offset < expected.length &&
            near(i, j + offset)) {
          expectedAhead = offset;
        }
      }
      if (recognizedAhead != null &&
          (expectedAhead == null || recognizedAhead <= expectedAhead)) {
        i++;
      } else if (expectedAhead != null) {
        j++;
      } else {
        i++;
        j++;
      }
    }
    return aligned;
  }

  /// Find one-to-one substitution gaps bracketed by unambiguous exact anchors
  /// in a full exact-word LCS alignment. Learning runs only after a completed
  /// attempt, so the full matrix is appropriate here; speculative bounded
  /// positional pairs are never persisted as actor corrections.
  static List<(int, int)> _exactAnchoredSubstitutions(
    List<String> recognized,
    List<String> expected,
  ) {
    if (recognized.length < 2 || expected.length < 2) return const [];
    final m = recognized.length;
    final n = expected.length;
    final width = n + 1;
    final dp = Int32List((m + 1) * width);
    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= n; j++) {
        if (recognized[i - 1] == expected[j - 1]) {
          dp[i * width + j] = dp[(i - 1) * width + j - 1] + 1;
        } else {
          final up = dp[(i - 1) * width + j];
          final left = dp[i * width + j - 1];
          dp[i * width + j] = up > left ? up : left;
        }
      }
    }

    final reversedAnchors = <(int, int)>[];
    var i = m;
    var j = n;
    while (i > 0 && j > 0) {
      if (recognized[i - 1] == expected[j - 1]) {
        reversedAnchors.add((i - 1, j - 1));
        i--;
        j--;
      } else if (dp[(i - 1) * width + j] > dp[i * width + j - 1]) {
        i--;
      } else {
        j--;
      }
    }
    final anchors = reversedAnchors.reversed.toList(growable: false);
    if (anchors.isEmpty) return const [];

    final recognizedFrequency = <String, int>{};
    final expectedFrequency = <String, int>{};
    for (final word in recognized) {
      recognizedFrequency[word] = (recognizedFrequency[word] ?? 0) + 1;
    }
    for (final word in expected) {
      expectedFrequency[word] = (expectedFrequency[word] ?? 0) + 1;
    }

    bool isUniqueAnchor((int, int) anchor) {
      final word = recognized[anchor.$1];
      return recognizedFrequency[word] == 1 && expectedFrequency[word] == 1;
    }

    final substitutions = <(int, int)>[];
    // Virtual start/end anchors admit a one-token prefix or suffix
    // substitution (including a two-word line) when its sole adjacent real
    // anchor is unique. Interior gaps require unique anchors on both sides.
    for (var gapIndex = 0; gapIndex <= anchors.length; gapIndex++) {
      final before = gapIndex == 0 ? const (-1, -1) : anchors[gapIndex - 1];
      final after = gapIndex == anchors.length ? (m, n) : anchors[gapIndex];
      if (after.$1 - before.$1 != 2 || after.$2 - before.$2 != 2) {
        continue;
      }
      if (before.$1 >= 0 && !isUniqueAnchor(before)) continue;
      if (after.$1 < m && !isUniqueAnchor(after)) continue;
      substitutions.add((before.$1 + 1, before.$2 + 1));
    }
    return substitutions;
  }

  static String _applyLearnedCorrections(
    String text,
    Map<String, String> corrections,
  ) {
    return text
        .split(_wsRe)
        .map((token) {
          final parts = _tokenPartsRe.firstMatch(token);
          if (parts == null) return token;
          final normalized = parts
              .group(2)!
              .toLowerCase()
              .replaceAll(_nonWordRe, '');
          final replacement = corrections[normalized];
          if (replacement == null) return token;
          return '${parts.group(1)}$replacement${parts.group(3)}';
        })
        .join(' ');
  }

  /// Levenshtein edit distance, capped at [maxDist].
  ///
  /// Returns the exact distance when it is <= [maxDist], otherwise
  /// [maxDist] + 1 — every caller only compares against a small threshold,
  /// so the exact value beyond the cap is never needed.
  ///
  /// Two reusable rows rather than a full matrix, plus a per-row bail once
  /// the whole row exceeds the cap. The previous version allocated a list
  /// literal for *every* DP cell, which the vocabulary scan ran millions of
  /// times per partial STT result.
  static int _editDistanceAtMost(String a, String b, int maxDist) {
    if (a == b) return 0;
    if (maxDist <= 0) return 1;

    final la = a.length;
    final lb = b.length;
    if (la == 0) return lb <= maxDist ? lb : maxDist + 1;
    if (lb == 0) return la <= maxDist ? la : maxDist + 1;
    if ((la - lb).abs() > maxDist) return maxDist + 1;

    _ensureDpCapacity(lb + 1);
    var prev = _dpPrev;
    var curr = _dpCurr;
    for (var j = 0; j <= lb; j++) {
      prev[j] = j;
    }

    for (var i = 1; i <= la; i++) {
      curr[0] = i;
      var rowMin = i;
      final ca = a.codeUnitAt(i - 1);
      for (var j = 1; j <= lb; j++) {
        var v = prev[j] + 1; // deletion
        final ins = curr[j - 1] + 1;
        if (ins < v) v = ins;
        final sub = prev[j - 1] + (ca == b.codeUnitAt(j - 1) ? 0 : 1);
        if (sub < v) v = sub;
        curr[j] = v;
        if (v < rowMin) rowMin = v;
      }
      // Distances only grow row to row, so nothing below the cap remains.
      if (rowMin > maxDist) return maxDist + 1;
      final swap = prev;
      prev = curr;
      curr = swap;
    }

    final dist = prev[lb];
    return dist <= maxDist ? dist : maxDist + 1;
  }

  // Scratch rows for [_editDistanceAtMost]. The scan is synchronous and
  // non-reentrant, so two buffers are shared across calls instead of
  // allocating a pair per call.
  static Int32List _dpPrev = Int32List(64);
  static Int32List _dpCurr = Int32List(64);

  static void _ensureDpCapacity(int length) {
    if (_dpPrev.length < length) {
      _dpPrev = Int32List(length);
      _dpCurr = Int32List(length);
    }
  }

  /// Match score — delegates to SttService.matchScore. There never was a
  /// real import cycle (neither file imports the other); the previous
  /// hand-inlined copy allocated a full DP matrix per call — on the main
  /// isolate, several times a second during rehearsal — and had already
  /// drifted from the original it claimed to stay in sync with.
  static double _matchScore(String expected, String spoken) =>
      SttService.matchScore(expected, spoken);

  List<String> _tokenize(String text) {
    return text
        .toLowerCase()
        .replaceAll(_nonWordSpaceRe, '')
        .trim()
        .split(_wsRe)
        .where((w) => w.isNotEmpty)
        .toList();
  }
}

/// Maximum number of production vocabularies retained by the process
/// singleton. Opening another production evicts the oldest complete
/// vocabulary and its actor corrections.
const _maxLoadedProductions = 4;

/// Cap on memoized word corrections per production. The keys are recognized
/// words, so a long session with a bad recognizer could otherwise grow it
/// without bound.
const _correctionCacheLimit = 4000;

/// Internal vocabulary data for a production.
class _ProductionVocabulary {
  final Set<String> characterNames = {};
  final Set<String> importantWords = {};
  final Map<String, int> wordFrequency = {};

  /// Memoized `_bestVocabularyMatch` results: recognized word -> correction
  /// (null means "leave it alone").
  final Map<String, String?> correctionCache = {};

  List<String>? _scanWords;
  List<_NamePart>? _nameParts;

  /// Flattened scan inputs, built on the first correction. `buildFromScript`
  /// replaces the whole vocabulary object, so these can never go stale.
  /// Both keep the sets' insertion order: ties in the scan go to the first
  /// candidate seen, so the order is part of the correction behaviour.
  List<String> get scanWords =>
      _scanWords ??= importantWords.toList(growable: false);

  List<_NamePart> get nameParts => _nameParts ??= _buildNameParts();

  List<_NamePart> _buildNameParts() {
    final parts = <_NamePart>[];
    for (final name in characterNames) {
      final nameLower = name.toLowerCase();
      for (final part in nameLower.split(_wsRe)) {
        // Preserve the original casing from the character name
        final idx = nameLower.indexOf(part);
        parts.add(_NamePart(part, name.substring(idx, idx + part.length)));
      }
    }
    return parts;
  }
}

/// One word of a character name: what to match against, and what to emit.
class _NamePart {
  const _NamePart(this.lower, this.cased);
  final String lower;
  final String cased;
}
