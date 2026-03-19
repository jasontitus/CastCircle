import 'package:simple_spell_checker/simple_spell_checker.dart';
import 'package:simple_spell_checker_en_lan/simple_spell_checker_en_lan.dart';

import '../models/script_models.dart';

/// Scores OCR confidence for script lines using dictionary-based spell checking.
///
/// Uses simple_spell_checker with the English dictionary (~320K words).
/// Loaded on demand and disposed after use to free memory.
class OcrConfidenceService {
  OcrConfidenceService._();
  static final instance = OcrConfidenceService._();

  SimpleSpellChecker? _checker;
  Set<String> _whitelist = {};

  /// Initialize the spell checker (loads dictionary into memory).
  void _ensureLoaded() {
    if (_checker != null) return;
    SimpleSpellCheckerEnRegister.registerLan(preferEnglish: 'en');
    SimpleSpellCheckerEnRegister.registerLan(preferEnglish: 'en-gb');
    _checker = SimpleSpellChecker(language: 'en');
  }

  /// Dispose the spell checker to free memory.
  void dispose() {
    _checker?.dispose();
    _checker = null;
    _whitelist = {};
    SimpleSpellCheckerEnRegister.removeLan();
  }

  /// Build a whitelist from the script's own content:
  /// - Character names and their parts
  /// - Words that appear 3+ times (likely correct proper nouns/place names)
  /// - Common abbreviations and titles
  void _buildWhitelist(List<ScriptLine> lines, List<ScriptCharacter> characters) {
    _whitelist = {};

    // Common titles and abbreviations
    _whitelist.addAll([
      'mr', 'mrs', 'ms', 'dr', 'st', 'sr', 'jr',
      'sir', 'madam', 'lord', 'lady',
    ]);

    // Character names and their parts
    for (final char in characters) {
      for (final part in char.name.split(RegExp(r'[\s.]+' ))) {
        if (part.length >= 2) {
          _whitelist.add(part.toLowerCase());
        }
      }
    }

    // Count word frequencies across all lines — words appearing 3+ times
    // are likely proper nouns (place names, character references) not OCR errors
    final wordCounts = <String, int>{};
    for (final line in lines) {
      final words = line.text
          .split(RegExp(r'[\s.,;:!?()\[\]{}"\/\-–—→]+'))
          .where((w) => w.length >= 2);
      for (final word in words) {
        final lower = word.toLowerCase();
        wordCounts[lower] = (wordCounts[lower] ?? 0) + 1;
      }
    }
    for (final entry in wordCounts.entries) {
      if (entry.value >= 3) {
        _whitelist.add(entry.key);
      }
    }
  }

  bool _isWhitelisted(String word) {
    return _whitelist.contains(word.toLowerCase());
  }

  /// Score a single line of text.
  /// Returns 0.0 (all misspelled) to 1.0 (all correct).
  double scoreLine(String text) {
    _ensureLoaded();
    final words = text
        .split(RegExp(r'[\s.,;:!?()\[\]{}"\/\-–—→]+'))
        .where((w) => w.length >= 2)
        .where((w) => !RegExp(r'^\d+$').hasMatch(w))
        .where((w) => !RegExp(r'^[A-Z][A-Z]+$').hasMatch(w)) // skip ALL CAPS
        .toList();

    if (words.isEmpty) return 1.0;

    int correct = 0;
    for (final word in words) {
      // Check whitelist first (character names, frequent proper nouns, titles)
      if (_isWhitelisted(word)) {
        correct++;
        continue;
      }

      final results = _checker!.checkBuilder<bool>(
        word,
        builder: (w, isCorrect) => isCorrect,
      );
      if (results != null && results.isNotEmpty && results.first) {
        correct++;
      }
    }

    return correct / words.length;
  }

  /// Score all lines in a parsed script, updating ocrConfidence.
  List<ScriptLine> scoreScript(List<ScriptLine> lines,
      {List<ScriptCharacter> characters = const []}) {
    _ensureLoaded();
    _buildWhitelist(lines, characters);

    return lines.map((line) {
      if (line.text.trim().isEmpty) return line;
      if (line.lineType == LineType.header) return line;
      final score = scoreLine(line.text);
      return line.copyWith(ocrConfidence: () => score);
    }).toList();
  }
}
