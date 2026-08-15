/// Respellings that fix heteronyms **espeak-ng** gets wrong.
///
/// Scope, deliberately narrow:
///
/// * This is for the Android synthesis path only (sherpa-onnx + espeak-ng).
///   iOS uses Misaki, which resolves heteronyms by part of speech via
///   NLTagger and already says "Long live the King" correctly — and none of
///   these respellings are in Misaki's dictionaries, so applying them there
///   would push known-good words into its fallback network. Engine-specific
///   damage needs an engine-specific fix.
/// * Every rule below was measured against `espeak-ng -v en-gb --ipa`: the
///   pattern produces the WRONG phoneme without the rule and the RIGHT one
///   with it. espeak is already correct for the common cases — "I live in
///   Denmark", "to live", "we must live", and every adjective use ("a live
///   performance", "live theatre") — so those are left alone. Rules that
///   "look sensible" but were not measured don't belong here: a respelling
///   that fires on a word espeak already handles makes the audio worse.
///
/// The failures are the subjunctive ("Long live the King", "Let him live",
/// "May he live") and the sentence-initial imperative ("Live and let live"),
/// where espeak falls back to the adjective reading /laɪv/.
library;

class EspeakHeteronyms {
  EspeakHeteronyms._();

  /// Respelling for the verb "live" (/lɪv/). Not a real word, which is the
  /// point: espeak's letter rules give it the short vowel, and it can never
  /// collide with a dictionary entry.
  static const _liveVerb = 'liv';

  /// Each entry pairs a pattern with the group holding the heteronym, so the
  /// surrounding words survive untouched and the replacement can copy the
  /// original word's capitalisation ("Live and…" must not become "liv and…").
  static final List<(RegExp, int)> _rules = [
    // "Long live the King!" — the subjunctive espeak reads as an adjective.
    (RegExp(r'\b(long\s+)(live)\b', caseSensitive: false), 2),
    // "Let him live", "let them live"
    (
      RegExp(r'\b(let\s+(?:him|her|them|me|us|it)\s+)(live)\b',
          caseSensitive: false),
      2
    ),
    // "…and let live" — the bare object-less form, also read as an adjective.
    (RegExp(r'\b(let\s+)(live)\b', caseSensitive: false), 2),
    // "May he live long"
    (
      RegExp(r'\b(may\s+(?:he|she|they|i|we|you|it)\s+)(live)\b',
          caseSensitive: false),
      2
    ),
    // Sentence-initial imperative: "Live and let live.", "Live!", "Live,
    // then." Bounded to punctuation and a small set of following words on
    // purpose — an unbounded rule would swallow the adjective, as in "Live
    // theatre is better", which espeak already gets right.
    (
      RegExp(
          r'(^|[.!?;:]\s+)(live)(?=\s*[.!?,;:]|\s+(?:and|then|well|long)\b)',
          caseSensitive: false),
      2
    ),
  ];

  /// Copy [original]'s capitalisation onto [replacement].
  static String _matchCase(String original, String replacement) {
    if (original == original.toUpperCase()) return replacement.toUpperCase();
    if (original[0] == original[0].toUpperCase()) {
      return replacement[0].toUpperCase() + replacement.substring(1);
    }
    return replacement;
  }

  /// Apply every respelling to [text].
  ///
  /// Returns [text] unchanged when nothing matches, which is the common case —
  /// this runs on every line of dialogue.
  static String apply(String text) {
    if (text.isEmpty) return text;
    var out = text;
    for (final (pattern, group) in _rules) {
      out = out.replaceAllMapped(pattern, (m) {
        final word = m[group]!;
        final before = m.group(0)!;
        // Rebuild the match with only the heteronym swapped.
        return before.replaceRange(
          before.lastIndexOf(word),
          before.lastIndexOf(word) + word.length,
          _matchCase(word, _liveVerb),
        );
      });
    }
    return out;
  }
}
