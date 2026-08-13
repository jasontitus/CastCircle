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

  // Compiled search patterns for the learned corrections above, keyed by the
  // misrecognized word.
  final Map<String, RegExp> _correctionPatterns = {};

  // The expected line text is identical for every partial result of a line,
  // so its word set is tokenized once per line instead of once per result.
  String? _expectedCacheKey;
  Set<String> _expectedCacheWords = const {};

  // ── Vocabulary Building ──────────────────────────────

  /// Build vocabulary from a parsed script. Call this when a script is loaded.
  void buildFromScript(String productionId, List<ScriptLine> lines) {
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

    // Store all unique line texts for line-level matching
    for (final line in lines) {
      if (line.lineType == LineType.dialogue && line.text.isNotEmpty) {
        vocab.lineTexts[line.id] = line.text;
      }
    }

    _vocabularies[productionId] = vocab;
    debugPrint(
      'SttVocabulary: Built for production $productionId — '
      '${vocab.characterNames.length} characters, '
      '${vocab.importantWords.length} important words, '
      '${vocab.lineTexts.length} lines',
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
    // Collect the words whose corrections are being dropped so their
    // compiled patterns go too — _correctionPatterns is process-global and
    // used to grow for the lifetime of the app across every production.
    final droppedWords = <String>{};
    _actorCorrections.removeWhere((key, corrections) {
      if (!key.startsWith('$productionId:')) return false;
      droppedWords.addAll(corrections.keys);
      return true;
    });
    if (droppedWords.isNotEmpty) {
      // A word may also be corrected under another production; only evict
      // patterns no surviving correction map still references.
      final stillUsed = <String>{
        for (final m in _actorCorrections.values) ...m.keys,
      };
      _correctionPatterns
          .removeWhere((w, _) => droppedWords.contains(w) && !stillUsed.contains(w));
    }
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

    // 1. Apply per-actor learned corrections
    if (actorId != null) {
      final key = '$productionId:$actorId';
      final corrections = _actorCorrections[key];
      if (corrections != null) {
        for (final entry in corrections.entries) {
          result = result.replaceAll(
            // Cached: compiling the pattern per learned correction per
            // partial result showed up in the rehearsal profile.
            _correctionPatterns[entry.key] ??=
                RegExp(RegExp.escape(entry.key), caseSensitive: false),
            entry.value,
          );
        }
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
        resolvedWords:
            expectedText == null ? null : _expectedWordSet(expectedText),
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

    if (recognizedWords.length != expectedWords.length) return;

    final key = '$productionId:$actorId';
    _actorCorrections[key] ??= {};

    for (var i = 0; i < recognizedWords.length; i++) {
      if (recognizedWords[i] != expectedWords[i]) {
        final wrong = recognizedWords[i];
        final right = expectedWords[i];
        // Only learn if the wrong version is close enough (likely same word)
        if (_editDistanceAtMost(wrong, right, 3) <= 3) {
          final map = _actorCorrections[key]!;
          // Cap like correctionCache: every entry is a regex pass over every
          // STT partial, so an unbounded map slowly taxes live matching.
          if (map.length >= 500 && !map.containsKey(wrong)) {
            final evict = map.keys.first;
            map.remove(evict);
            _correctionPatterns.remove(evict);
          }
          map[wrong] = right;
        }
      }
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
      String lower, _ProductionVocabulary vocab) {
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

  /// Correct recognized text against expected text using LCS word alignment.
  ///
  /// Uses dynamic programming to align recognized words to expected words,
  /// then replaces near-matches with the expected word. Works regardless
  /// of whether word counts match.
  String _correctAgainstExpected(String recognized, String expected) {
    final recWords = recognized.split(_wsRe);
    final expWords = expected.split(_wsRe);
    if (recWords.isEmpty || expWords.isEmpty) return recognized;

    // Normalize once per word instead of once per DP cell — this used to run
    // two lowercase+regex passes for every (recognized × expected) pair.
    final recNorm = [
      for (final w in recWords) w.toLowerCase().replaceAll(_nonWordRe, '')
    ];
    final expNorm = [
      for (final w in expWords) w.toLowerCase().replaceAll(_nonWordRe, '')
    ];

    // Build LCS alignment matrix. Backtracking needs the whole matrix, so
    // it can't be two-row — but one flat Int32List replaces the
    // list-of-lists (this also runs per recognition partial on the main
    // isolate).
    final m = recWords.length;
    final n = expWords.length;
    final w = n + 1;
    final dp = Int32List((m + 1) * w);

    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= n; j++) {
        if (_editDistanceAtMost(recNorm[i - 1], expNorm[j - 1], 2) <= 2) {
          dp[i * w + j] = dp[(i - 1) * w + (j - 1)] + 1;
        } else {
          final up = dp[(i - 1) * w + j];
          final left = dp[i * w + (j - 1)];
          dp[i * w + j] = up > left ? up : left;
        }
      }
    }

    // Backtrack to find aligned pairs and replace near-matches
    final corrected = List<String>.from(recWords);
    var i = m, j = n;
    while (i > 0 && j > 0) {
      final recLower = recNorm[i - 1];
      final expLower = expNorm[j - 1];
      if (_editDistanceAtMost(recLower, expLower, 2) <= 2) {
        // Aligned pair — replace with expected word if close but not exact
        if (recLower != expLower) {
          corrected[i - 1] = expWords[j - 1];
        }
        i--;
        j--;
      } else if (dp[(i - 1) * w + j] > dp[i * w + (j - 1)]) {
        i--; // recognized word not in expected — keep as-is
      } else {
        j--; // expected word not in recognized — skip
      }
    }

    return corrected.join(' ');
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

/// Cap on memoized word corrections per production. The keys are recognized
/// words, so a long session with a bad recognizer could otherwise grow it
/// without bound.
const _correctionCacheLimit = 4000;

/// Internal vocabulary data for a production.
class _ProductionVocabulary {
  final Set<String> characterNames = {};
  final Set<String> importantWords = {};
  final Map<String, int> wordFrequency = {};
  final Map<String, String> lineTexts = {}; // lineId -> text

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
