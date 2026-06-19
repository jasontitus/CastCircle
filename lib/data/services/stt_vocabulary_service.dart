import 'package:flutter/foundation.dart';

import '../models/script_models.dart';

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

  // ── Vocabulary Building ──────────────────────────────

  /// Build vocabulary from a parsed script. Call this when a script is loaded.
  void buildFromScript(String productionId, List<ScriptLine> lines) {
    final vocab = _ProductionVocabulary();

    // Extract character names
    for (final line in lines) {
      if (line.character.isNotEmpty) {
        vocab.characterNames.add(line.character);
        // Split multi-word names
        for (final part in line.character.split(RegExp(r'\s+'))) {
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
          .replaceAll(RegExp("[^\\w\\s']"), '')
          .toLowerCase()
          .split(RegExp(r'\s+'))
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
    _actorCorrections.removeWhere(
        (key, _) => key.startsWith('$productionId:'));
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
            RegExp(RegExp.escape(entry.key), caseSensitive: false),
            entry.value,
          );
        }
      }
    }

    // 2. Apply vocabulary-based word corrections
    final vocab = _vocabularies[productionId];
    if (vocab != null) {
      result = _correctWithVocabulary(result, vocab);
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
        if (_editDistance(wrong, right) <= 3) {
          _actorCorrections[key]![wrong] = right;
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

  /// Correct words using production vocabulary (fuzzy match).
  String _correctWithVocabulary(String text, _ProductionVocabulary vocab) {
    final words = text.split(RegExp(r'\s+'));
    final corrected = <String>[];

    for (final word in words) {
      final lower = word.toLowerCase().replaceAll(RegExp(r'[^\w]'), '');
      if (lower.isEmpty) {
        corrected.add(word);
        continue;
      }

      // Check if this word is close to an important vocabulary word
      String? bestMatch;
      int bestDistance = 3; // max edit distance to consider

      for (final vocabWord in vocab.importantWords) {
        final dist = _editDistance(lower, vocabWord);
        if (dist > 0 && dist < bestDistance) {
          bestDistance = dist;
          bestMatch = vocabWord;
        }
      }

      // Also check character names (case-preserved)
      for (final name in vocab.characterNames) {
        final nameLower = name.toLowerCase();
        for (final namePart in nameLower.split(RegExp(r'\s+'))) {
          final dist = _editDistance(lower, namePart);
          if (dist > 0 && dist < bestDistance) {
            bestDistance = dist;
            // Preserve original casing from character name
            final nameIdx = nameLower.indexOf(namePart);
            bestMatch = name.substring(nameIdx, nameIdx + namePart.length);
          }
        }
      }

      corrected.add(bestMatch ?? word);
    }

    return corrected.join(' ');
  }

  /// Correct recognized text against expected text using LCS word alignment.
  ///
  /// Uses dynamic programming to align recognized words to expected words,
  /// then replaces near-matches with the expected word. Works regardless
  /// of whether word counts match.
  String _correctAgainstExpected(String recognized, String expected) {
    final recWords = recognized.split(RegExp(r'\s+'));
    final expWords = expected.split(RegExp(r'\s+'));
    if (recWords.isEmpty || expWords.isEmpty) return recognized;

    // Build LCS alignment matrix
    final m = recWords.length;
    final n = expWords.length;
    final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));

    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= n; j++) {
        final recLower = recWords[i - 1].toLowerCase().replaceAll(RegExp(r'[^\w]'), '');
        final expLower = expWords[j - 1].toLowerCase().replaceAll(RegExp(r'[^\w]'), '');
        if (_editDistance(recLower, expLower) <= 2) {
          dp[i][j] = dp[i - 1][j - 1] + 1;
        } else {
          dp[i][j] = dp[i - 1][j] > dp[i][j - 1]
              ? dp[i - 1][j]
              : dp[i][j - 1];
        }
      }
    }

    // Backtrack to find aligned pairs and replace near-matches
    final corrected = List<String>.from(recWords);
    var i = m, j = n;
    while (i > 0 && j > 0) {
      final recLower = recWords[i - 1].toLowerCase().replaceAll(RegExp(r'[^\w]'), '');
      final expLower = expWords[j - 1].toLowerCase().replaceAll(RegExp(r'[^\w]'), '');
      if (_editDistance(recLower, expLower) <= 2) {
        // Aligned pair — replace with expected word if close but not exact
        if (recLower != expLower) {
          corrected[i - 1] = expWords[j - 1];
        }
        i--;
        j--;
      } else if (dp[i - 1][j] > dp[i][j - 1]) {
        i--; // recognized word not in expected — keep as-is
      } else {
        j--; // expected word not in recognized — skip
      }
    }

    return corrected.join(' ');
  }

  /// Levenshtein edit distance.
  static int _editDistance(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    final matrix = List.generate(
      a.length + 1,
      (_) => List.filled(b.length + 1, 0),
    );

    for (var i = 0; i <= a.length; i++) matrix[i][0] = i;
    for (var j = 0; j <= b.length; j++) matrix[0][j] = j;

    for (var i = 1; i <= a.length; i++) {
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        matrix[i][j] = [
          matrix[i - 1][j] + 1,
          matrix[i][j - 1] + 1,
          matrix[i - 1][j - 1] + cost,
        ].reduce((a, b) => a < b ? a : b);
      }
    }

    return matrix[a.length][b.length];
  }

  /// Match score — delegates to SttService.matchScore (LCS-based).
  static double _matchScore(String expected, String spoken) {
    // Import would create a circular dependency, so inline the call
    // via the same static method. Keep in sync with SttService.matchScore.
    final normalizedExpected = expected
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .trim();
    if (normalizedExpected.isEmpty) return 1.0;

    final expectedWords = normalizedExpected.split(RegExp(r'\s+'));
    final spokenWords = spoken
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .trim()
        .split(RegExp(r'\s+'));

    if (spokenWords.isEmpty || (spokenWords.length == 1 && spokenWords[0].isEmpty)) {
      return 0.0;
    }

    // LCS with fuzzy word matching (edit distance ≤ 1)
    final m = expectedWords.length;
    final n = spokenWords.length;
    final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));

    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= n; j++) {
        final ew = expectedWords[i - 1];
        final sw = spokenWords[j - 1];
        if (ew == sw || ((ew.length - sw.length).abs() <= 1 && _editDistance(ew, sw) <= 1)) {
          dp[i][j] = dp[i - 1][j - 1] + 1;
        } else {
          dp[i][j] = dp[i - 1][j] > dp[i][j - 1]
              ? dp[i - 1][j]
              : dp[i][j - 1];
        }
      }
    }

    return dp[m][n] / m;
  }

  List<String> _tokenize(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
  }
}

/// Internal vocabulary data for a production.
class _ProductionVocabulary {
  final Set<String> characterNames = {};
  final Set<String> importantWords = {};
  final Map<String, int> wordFrequency = {};
  final Map<String, String> lineTexts = {}; // lineId -> text
}
