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

    // Extract vocabulary from dialogue
    for (final line in lines) {
      if (line.lineType != LineType.dialogue) continue;
      final words = _tokenize(line.text);
      for (final word in words) {
        vocab.wordFrequency[word] = (vocab.wordFrequency[word] ?? 0) + 1;
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

  /// Correct recognized text against expected text using word alignment.
  String _correctAgainstExpected(String recognized, String expected) {
    final recWords = recognized.split(RegExp(r'\s+'));
    final expWords = expected.split(RegExp(r'\s+'));
    final corrected = <String>[];

    // Simple word-by-word correction for same-length sequences
    if (recWords.length == expWords.length) {
      for (var i = 0; i < recWords.length; i++) {
        final recLower = recWords[i].toLowerCase().replaceAll(RegExp(r'[^\w]'), '');
        final expLower = expWords[i].toLowerCase().replaceAll(RegExp(r'[^\w]'), '');
        if (_editDistance(recLower, expLower) <= 2 && recLower != expLower) {
          corrected.add(expWords[i]);
        } else {
          corrected.add(recWords[i]);
        }
      }
      return corrected.join(' ');
    }

    // Different lengths — just return as-is, vocabulary correction handles it
    return recognized;
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

  /// Match score (same algorithm as SttService.matchScore).
  static double _matchScore(String expected, String spoken) {
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

    int matched = 0;
    for (final word in expectedWords) {
      if (spokenWords.contains(word)) matched++;
    }

    return matched / expectedWords.length;
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
