import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:simple_spell_checker/simple_spell_checker.dart';
import 'package:simple_spell_checker_en_lan/simple_spell_checker_en_lan.dart';

import '../models/script_models.dart';

/// Scores OCR confidence for script lines using dictionary-based spell checking
/// merged with Paddle's per-line recognition confidence.
///
/// Uses simple_spell_checker with the English dictionary (~251K words), a
/// script-derived whitelist, and a bundled theatrical vocabulary
/// (`assets/ocr/theatrical_vocab.txt`, ~2,936 words). Loaded on demand and
/// disposed after use to free memory.
class OcrConfidenceService {
  OcrConfidenceService._();
  static final instance = OcrConfidenceService._();

  /// Path to the bundled theatrical vocabulary asset.
  static const theatricalVocabAsset = 'assets/ocr/theatrical_vocab.txt';

  // ── Merged-signal thresholds (Mac-validated against 88 low-OCR + 2,644 good
  // lines; see /tmp/lowocr/REPORT.md). ──
  /// Dictionary gate for the "review" bucket — the sole driver of "review".
  static const dictReviewThreshold = 0.80;

  /// Low rec-confidence half of the "likely not script" gate.
  static const recConfJunkThreshold = 0.65;

  /// Low dictionary half of the "likely not script" gate.
  static const dictJunkThreshold = 0.50;

  SimpleSpellChecker? _checker;
  Set<String> _whitelist = {};
  Set<String> _theatricalVocab = {};
  bool _vocabLoadAttempted = false;

  // Tokenizer separators. Curly quotes (’ ‘ “ ”), straight quotes, underscores
  // and asterisks (markdown emphasis) are separators so `“I`→`I`,
  // `_emphasis_`→`emphasis`. The trailing-apostrophe strip below handles
  // possessives like `Darcy’s`→`darcy`.
  static final _split = RegExp('[\\s.,;:!?()\\[\\]{}"‘’“”\'_*\\/\\-–—→]+');
  static final _allDigits = RegExp(r'^\d+$');
  static final _allCaps = RegExp(r'^[A-Z][A-Z]+$');
  static final _edgeApostrophes = RegExp("^['‘’]+|['‘’]+\$");

  // Latin diacritic fold — OCR sprinkles spurious accents (speáks → speaks).
  static const _diacriticMap = {
    'á': 'a',
    'à': 'a',
    'â': 'a',
    'ä': 'a',
    'ã': 'a',
    'å': 'a',
    'é': 'e',
    'è': 'e',
    'ê': 'e',
    'ë': 'e',
    'í': 'i',
    'ì': 'i',
    'î': 'i',
    'ï': 'i',
    'ó': 'o',
    'ò': 'o',
    'ô': 'o',
    'ö': 'o',
    'õ': 'o',
    'ú': 'u',
    'ù': 'u',
    'û': 'u',
    'ü': 'u',
    'ñ': 'n',
    'ç': 'c',
    'ý': 'y',
    'ÿ': 'y',
    'Á': 'A',
    'À': 'A',
    'Â': 'A',
    'Ä': 'A',
    'Ã': 'A',
    'Å': 'A',
    'É': 'E',
    'È': 'E',
    'Ê': 'E',
    'Ë': 'E',
    'Í': 'I',
    'Ì': 'I',
    'Î': 'I',
    'Ï': 'I',
    'Ó': 'O',
    'Ò': 'O',
    'Ô': 'O',
    'Ö': 'O',
    'Õ': 'O',
    'Ú': 'U',
    'Ù': 'U',
    'Û': 'U',
    'Ü': 'U',
    'Ñ': 'N',
    'Ç': 'C',
    'Ý': 'Y',
  };

  /// Initialize the spell checker (loads dictionary into memory).
  void _ensureLoaded() {
    if (_checker != null) return;
    SimpleSpellCheckerEnRegister.registerLan(preferEnglish: 'en');
    _checker = SimpleSpellChecker(language: 'en');
  }

  /// Load the bundled theatrical vocabulary into [_theatricalVocab] (once).
  ///
  /// Tolerant of a missing asset (e.g. in unit tests without a bundle) — leaves
  /// the set empty and proceeds with dict + whitelist only.
  Future<void> ensureVocabLoaded() async {
    if (_vocabLoadAttempted) return;
    _vocabLoadAttempted = true;
    try {
      final raw = await rootBundle.loadString(theatricalVocabAsset);
      _theatricalVocab = raw
          .split('\n')
          .map((w) => w.trim().toLowerCase())
          .where((w) => w.isNotEmpty)
          .toSet();
    } catch (e) {
      debugPrint('OCR confidence: theatrical vocab not loaded ($e)');
      _theatricalVocab = {};
    }
  }

  /// Inject a theatrical vocabulary directly (tests, or a background isolate
  /// that can't touch rootBundle — see script_import's Isolate.run scoring).
  void setTheatricalVocab(Set<String> vocab) {
    _theatricalVocab = vocab.map((w) => w.trim().toLowerCase()).toSet();
    _vocabLoadAttempted = true;
  }

  /// The loaded vocab, for handing to a background isolate's scorer.
  Set<String> get theatricalVocab => _theatricalVocab;

  /// Dispose the spell checker to free memory.
  void dispose() {
    _checker?.dispose();
    _checker = null;
    _whitelist = {};
    _theatricalVocab = {};
    _vocabLoadAttempted = false;
    SimpleSpellCheckerEnRegister.removeLan();
  }

  /// Build a whitelist from the script's own content:
  /// - Character names and their parts
  /// - Words that appear 3+ times (likely correct proper nouns/place names)
  /// - Common abbreviations and titles
  void _buildWhitelist(
    List<ScriptLine> lines,
    List<ScriptCharacter> characters,
  ) {
    _whitelist = {};

    // Common titles and abbreviations
    _whitelist.addAll([
      'mr',
      'mrs',
      'ms',
      'dr',
      'st',
      'sr',
      'jr',
      'sir',
      'madam',
      'lord',
      'lady',
    ]);

    // Character names and their parts
    for (final char in characters) {
      for (final part in char.name.split(RegExp(r'[\s.]+'))) {
        if (part.length >= 2) {
          _whitelist.add(part.toLowerCase());
        }
      }
    }

    // Count word frequencies across all lines — words appearing 3+ times
    // are likely proper nouns (place names, character references) not OCR errors
    final wordCounts = <String, int>{};
    for (final line in lines) {
      for (final word in _tokenize(line.text)) {
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

  /// Split a line into scorable words. Curly/straight quotes, underscores and
  /// asterisks act as separators; leading/trailing apostrophes are stripped (so
  /// `Darcy’s`→`darcy` + `s`, `“I`→`I`). ALL-CAPS, pure-digit and single-char
  /// tokens are dropped (speaker names, line numbers).
  List<String> _tokenize(String text) {
    return text
        .split(_split)
        .map((w) => w.replaceAll(_edgeApostrophes, ''))
        .where((w) => w.length >= 2)
        .where((w) => !_allDigits.hasMatch(w))
        .where(
          (w) => !_allCaps.hasMatch(w),
        ) // skip ALL CAPS (speaker names etc.)
        .toList();
  }

  /// Fold Latin diacritics: speáks → speaks (OCR adds spurious accents).
  /// Runs for every word of every OCR'd line — allocate nothing in the
  /// (overwhelmingly common) no-diacritic case instead of splitting the
  /// string into a per-character list.
  static String stripDiacritics(String s) {
    StringBuffer? sb; // created only once a diacritic is actually found
    for (var i = 0; i < s.length; i++) {
      final mapped = _diacriticMap[s[i]];
      if (mapped != null) {
        sb ??= StringBuffer(s.substring(0, i));
        sb.write(mapped);
      } else {
        sb?.write(s[i]);
      }
    }
    return sb?.toString() ?? s;
  }

  /// Scripts repeat vocabulary heavily — memoise so the spell-checker runs
  /// once per distinct word per import, not once per occurrence.
  final _wordValidCache = <String, bool>{};

  bool _isValidWord(String word) => _wordValidCache.putIfAbsent(word, () {
    final stripped = stripDiacritics(word);
    final low = stripped.toLowerCase();
    if (_whitelist.contains(low)) return true;
    if (_theatricalVocab.contains(low)) return true;
    final results = _checker!.checkBuilder<bool>(
      stripped,
      builder: (w, isCorrect) => isCorrect,
    );
    return results != null && results.isNotEmpty && results.first;
  });

  /// Score a single line of text.
  /// Returns 0.0 (all misspelled) to 1.0 (all correct). Text with no scorable
  /// tokens retains the historical 1.0 here; [scoreScript] treats that case
  /// separately because it must produce a conservative review status.
  double scoreLine(String text) {
    _ensureLoaded();
    return _scoreWords(_tokenize(text));
  }

  double _scoreWords(List<String> words) {
    if (words.isEmpty) return 1.0;
    var correct = 0;
    for (final word in words) {
      if (_isValidWord(word)) correct++;
    }
    return correct / words.length;
  }

  /// Classify a line from its merged signal.
  ///
  /// - [dictNew]: valid-word fraction (0.0–1.0) — the reliable "is this text
  ///   actually words?" signal.
  /// - [recConf]: Paddle per-line rec-confidence (0.0–1.0; 1.0 if unknown).
  ///
  /// The dictionary fraction drives the "review" decision. We deliberately do
  /// NOT flag on rec-confidence alone: PaddleOCR's per-line confidence is noisy
  /// and routinely sits at 0.65–0.85 for perfectly-good dialogue, so a recConf
  /// gate flags ~90% of a clean script. Verified on the Mac against real Paddle
  /// output for Jon Jory's *Pride and Prejudice*: of 948 lines the old gate
  /// flagged, 938 had dictNew=1.0 (clean text) and were flagged only by recConf.
  /// rec-confidence is kept solely to corroborate the "likely not script"
  /// (gibberish) bucket, where it must agree with a low dictionary score.
  static OcrReviewStatus classify(double dictNew, double recConf) {
    if (dictNew < dictJunkThreshold && recConf < recConfJunkThreshold) {
      return OcrReviewStatus.likelyNotScript;
    }
    if (dictNew < dictReviewThreshold) {
      return OcrReviewStatus.review;
    }
    return OcrReviewStatus.ok;
  }

  /// Score all lines in a parsed script, updating OCR confidence and review
  /// status.
  ///
  /// Each line's existing [ScriptLine.ocrConfidence] is the recognition
  /// confidence. It is used only with a low dictionary score to identify the
  /// likely-not-script junk bucket. Display confidence and ordinary review
  /// status intentionally follow the dictionary score alone because native
  /// recognition confidence is too noisy for clean dialogue.
  ///
  /// Call [ensureVocabLoaded] before this (the import service does so) to get
  /// the theatrical-vocab boost; it still works without it.
  List<ScriptLine> scoreScript(
    List<ScriptLine> lines, {
    List<ScriptCharacter> characters = const [],
  }) {
    _ensureLoaded();
    _buildWhitelist(lines, characters);
    // The memo's validity depends on the whitelist, which is per-script:
    // without this, a word whitelisted by a PREVIOUS import stays "valid"
    // for every later script (wrong review verdicts), and the cache grows
    // monotonically across imports.
    _wordValidCache.clear();

    return lines.map((line) {
      if (line.text.trim().isEmpty) return line;
      if (line.lineType == LineType.header) return line;

      final words = _tokenize(line.text);
      // Nonempty, non-header text with no dictionary evidence (punctuation,
      // digits, or all-caps OCR debris) must not receive a perfect score.
      final dictNew = words.isEmpty ? 0.0 : _scoreWords(words);
      final recConf = line.ocrConfidence ?? 1.0;
      final status = classify(dictNew, recConf);
      final display = dictNew;

      return line.copyWith(ocrConfidence: () => display, reviewStatus: status);
    }).toList();
  }
}
