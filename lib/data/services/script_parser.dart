import 'package:uuid/uuid.dart';

import '../models/script_models.dart';

const _uuid = Uuid();

/// Detected script formatting convention.
enum ScriptFormat {
  /// "CHARACTER. Dialogue on same line" (e.g., Pride & Prejudice adaptation)
  standard,

  /// "CHARACTER.\nDialogue on next line" (e.g., Project Gutenberg Macbeth)
  nameOnOwnLine,

  /// "Name. Dialogue" with Title Case names (e.g., First Folio Hamlet)
  titleCase,
}

/// Parses raw OCR text from a play script into structured [ScriptLine] records
/// with automatic scene detection.
///
/// Scene detection strategy (in priority order):
/// 1. Explicit "SCENE N" headers
/// 2. "Shift begins..." stage directions (common in Jon Jory and similar)
/// 3. Location-based transitions: "(At Longbourn)", "(Netherfield drawing room)"
/// 4. Major entrance/exit clusters that indicate a new scene beat
///
/// The organizer can always manually split/merge scenes in the editor.
class ScriptParser {
  /// Known characters — populated during parsing from detected names,
  /// or pre-seeded by the organizer.
  final Set<String> knownCharacters = {};

  /// Character alias normalization map.
  final Map<String, String> characterAliases = {};

  /// Detected script format (set during parse).
  ScriptFormat _format = ScriptFormat.standard;

  // Noise patterns (page headers, footers, OCR artifacts)
  static final List<RegExp> _noisePatterns = [
    RegExp(r'^\d+\s+\w+(\s+\w+){0,4}$'), // "12 Author Name" (page num + short text)
    RegExp(r'^\w+(\s+\w+){0,4}\s+\d+$'), // "Author Name 12" (short text + page num)
    RegExp(r'^\d+$'), // bare page numbers
    RegExp(r'^[|}\s]+$'), // OCR artifacts
    RegExp(r'^\$[A-Za-z\s]+$'), // OCR noise
    RegExp(r'^FTLN \d+'), // Folger Through Line Numbers
    RegExp(r'^ACT \d+\. SC\. \d+$'), // Folger running scene headers
  ];

  /// Patterns that indicate a scene transition in stage directions.
  static final List<RegExp> _sceneTransitionPatterns = [
    // "Shift begins into X" / "Shift begins, returning to X"
    RegExp(r'[Ss]hift\s+begins?', caseSensitive: false),
    // "Shift out of X" / "Shift back to X"
    RegExp(r'[Ss]hift\s+(out|back|into|to)\b', caseSensitive: false),
    // "The shift is complete"
    RegExp(r'shift\s+is\s+complete', caseSensitive: false),
    // Explicit scene markers
    RegExp(r'^SCENE\s+\d', caseSensitive: false),
  ];

  /// Known locations that help label scenes.
  static final List<({String pattern, String location})> _locationPatterns = [
    (pattern: r'Longbourn', location: 'Longbourn'),
    (pattern: r'Netherfield', location: 'Netherfield'),
    (pattern: r'Rosings', location: 'Rosings'),
    (pattern: r'Pemberley', location: 'Pemberley'),
    (pattern: r'London', location: 'London'),
    (pattern: r'parsonage', location: "Collins' Parsonage"),
    (pattern: r'drawing\s+room', location: 'Drawing Room'),
    (pattern: r'garden|grounds|walk', location: 'Gardens'),
    (pattern: r'[Bb]all\b', location: 'Ball'),
    (pattern: r'bare\s+stage', location: 'Open Stage'),
    (pattern: r"Gardiner'?s", location: "Gardiner's Home"),
    (pattern: r'Lady\s+Catherine', location: "Lady Catherine's"),
  ];

  /// Parse raw text into a [ParsedScript] with scenes.
  ParsedScript parse(String rawText, {String title = 'Untitled'}) {
    // Strip Project Gutenberg preamble/postamble if present
    rawText = _stripGutenbergWrapper(rawText);

    // Pre-process: dehyphenate OCR line breaks ("dan-\ngerous" → "dangerous")
    rawText = _dehyphenate(rawText);

    // Auto-detect the script format
    _format = _detectFormat(rawText);

    // First pass: detect character names from the text
    _detectCharacters(rawText);

    // Merge OCR-garbled character names into correct ones
    _mergeOcrCharacterNames(rawText);

    // For title-case format, resolve abbreviated names using stage directions
    if (_format == ScriptFormat.titleCase) {
      _resolveTitleCaseAbbreviations(rawText);
    }

    // Second pass: parse lines
    final lines = _parseLines(rawText);

    // Third pass: detect scenes from parsed lines
    final scenes = _detectScenes(lines);

    // Build character list with line counts
    final charCounts = <String, int>{};
    for (final line in lines) {
      if (line.lineType == LineType.dialogue && line.character.isNotEmpty) {
        charCounts[line.character] =
            (charCounts[line.character] ?? 0) + 1;
      }
    }

    final characters = <ScriptCharacter>[];
    var colorIdx = 0;
    for (final entry
        in charCounts.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value))) {
      characters.add(ScriptCharacter(
        name: entry.key,
        colorIndex: colorIdx++,
        lineCount: entry.value,
        gender: inferGender(entry.key, rawText: rawText),
      ));
    }

    return ParsedScript(
      title: title,
      lines: lines,
      characters: characters,
      scenes: scenes,
      rawText: rawText,
    );
  }

  /// Infer gender from a character name using title prefixes.
  /// Returns male/female/null. Returns null if no title prefix found
  /// (caller should try context-based inference).
  static CharacterGender? _inferGenderFromTitle(String name) {
    final upper = name.toUpperCase();
    // Male titles
    if (upper.startsWith('MR ') || upper.startsWith('MR. ') ||
        upper.startsWith('SIR ') || upper.startsWith('LORD ') ||
        upper.startsWith('COLONEL ') || upper.startsWith('CAPTAIN ') ||
        upper.startsWith('KING ') || upper.startsWith('PRINCE ') ||
        upper.startsWith('DUKE ') || upper.startsWith('COUNT ') ||
        upper.startsWith('REV ') || upper.startsWith('REV. ') ||
        upper.startsWith('DR ') || upper.startsWith('DR. ') ||
        upper.startsWith('FATHER ') || upper.startsWith('BROTHER ')) {
      return CharacterGender.male;
    }
    // Female titles
    if (upper.startsWith('MRS ') || upper.startsWith('MRS. ') ||
        upper.startsWith('MS ') || upper.startsWith('MS. ') ||
        upper.startsWith('MISS ') || upper.startsWith('LADY ') ||
        upper.startsWith('QUEEN ') || upper.startsWith('PRINCESS ') ||
        upper.startsWith('DUCHESS ') || upper.startsWith('COUNTESS ') ||
        upper.startsWith('MOTHER ') || upper.startsWith('SISTER ')) {
      return CharacterGender.female;
    }
    return null;
  }

  /// Infer gender by scanning the raw script for gendered pronouns in
  /// parenthetical stage directions only (not dialogue, which refers to others).
  ///   DARCY. (He crosses...)  → male
  ///   ELIZABETH. (She turns...) → female
  /// Returns null if no pronoun context found.
  static CharacterGender? _inferGenderFromContext(
      String name, String rawText) {
    final escaped = RegExp.escape(name);
    // Only match pronouns INSIDE parentheses (stage directions), not dialogue.
    // Pattern: CHARNAME. (... he/she ...)
    final malePattern = RegExp(
      '$escaped\\.\\s*\\([^)]*\\b[Hh]e\\b[^)]*\\)',
    );
    final femalePattern = RegExp(
      '$escaped\\.\\s*\\([^)]*\\b[Ss]he\\b[^)]*\\)',
    );

    final maleCount = malePattern.allMatches(rawText).length;
    final femaleCount = femalePattern.allMatches(rawText).length;

    if (maleCount > 0 && maleCount > femaleCount) return CharacterGender.male;
    if (femaleCount > 0 && femaleCount > maleCount) {
      return CharacterGender.female;
    }
    return null;
  }

  /// Common English first names used in theatre for gender inference fallback.
  static const _femaleNames = {
    'JANE', 'ELIZABETH', 'MARY', 'ANNE', 'SARAH', 'EMMA', 'ALICE',
    'CHARLOTTE', 'LUCY', 'JULIA', 'JULIET', 'OPHELIA', 'KATE',
    'KATHERINE', 'CATHERINE', 'KITTY', 'LYDIA', 'GEORGIANA', 'PORTIA',
    'VIOLA', 'ROSALIND', 'DESDEMONA', 'CORDELIA', 'HELENA', 'HERMIA',
    'TITANIA', 'MIRANDA', 'BEATRICE', 'HERO', 'CLEOPATRA', 'ANTIGONE',
    'ELECTRA', 'MEDEA', 'NORA', 'HEDDA', 'STELLA', 'BLANCHE', 'LAURA',
    'AMANDA', 'EMILY', 'DOROTHY', 'MARGARET', 'MARTHA', 'ABIGAIL',
    'JESSICA', 'MARIA', 'OLIVIA', 'CELIA', 'PHOEBE', 'BIANCA',
    'DIANA', 'RUTH', 'GRACE', 'HELEN', 'ANNA', 'ROSA', 'CLARA',
    'FLORENCE', 'ELEANOR', 'SYLVIA', 'GWENDOLEN', 'CECILY', 'MABEL',
  };

  static const _maleNames = {
    'JOHN', 'JAMES', 'HENRY', 'WILLIAM', 'THOMAS', 'GEORGE', 'CHARLES',
    'EDWARD', 'RICHARD', 'ROBERT', 'ARTHUR', 'DAVID', 'MICHAEL', 'MARK',
    'PETER', 'PAUL', 'JACK', 'TOM', 'HAMLET', 'ROMEO', 'OTHELLO',
    'MACBETH', 'PROSPERO', 'OBERON', 'PUCK', 'LYSANDER', 'DEMETRIUS',
    'BENEDICK', 'PETRUCHIO', 'IAGO', 'CASSIO', 'ANTONIO', 'SHYLOCK',
    'FALSTAFF', 'CALIBAN', 'ARIEL', 'FITZWILLIAM', 'COLLINS', 'WICKHAM',
    'BINGLEY', 'DARCY', 'STANLEY', 'WILLY', 'TROY', 'WALTER', 'EDMUND',
    'EDGAR', 'KENT', 'GLOUCESTER', 'LEAR', 'HORATIO', 'LAERTES',
    'CLAUDIUS', 'BANQUO', 'MACDUFF', 'ROSS', 'SEBASTIAN', 'FERDINAND',
    'VALENTINE', 'OLIVER', 'ORLANDO', 'TOBY', 'ANDREW', 'MALVOLIO',
    'SIMON', 'RALPH', 'ROGER', 'JOSEPH', 'DANIEL', 'PHILIP', 'FRANK',
    'ALFIE', 'ARCHIE', 'ALBERT', 'ALFRED', 'FREDERICK', 'LEONARD',
  };

  /// Infer gender using title prefixes, common names, script context, then default.
  static CharacterGender inferGender(String name, {String rawText = ''}) {
    // 1. Title prefix (most reliable)
    final fromTitle = _inferGenderFromTitle(name);
    if (fromTitle != null) return fromTitle;

    // 2. Common first names
    final upper = name.toUpperCase().trim();
    if (_femaleNames.contains(upper)) return CharacterGender.female;
    if (_maleNames.contains(upper)) return CharacterGender.male;

    // 3. Pronoun context from stage directions
    if (rawText.isNotEmpty) {
      final fromContext = _inferGenderFromContext(name, rawText);
      if (fromContext != null) return fromContext;
    }

    // 4. Default to female (larger Kokoro voice pool)
    return CharacterGender.female;
  }

  /// Titles/honorifics that are NOT valid character names on their own.
  /// These get captured by the regex when it backtracks on cast list entries
  /// like "MR. BENNET" (no trailing `. dialogue`).
  static const _titlePrefixes = {
    'MR', 'MRS', 'MS', 'DR', 'MISS', 'REV', 'PROF',
  };

  /// Detect character names from the raw text.
  /// Pattern varies by detected [_format].
  void _detectCharacters(String rawText) {
    switch (_format) {
      case ScriptFormat.standard:
        _detectCharactersStandard(rawText);
        break;
      case ScriptFormat.nameOnOwnLine:
        _detectCharactersOwnLine(rawText);
        break;
      case ScriptFormat.titleCase:
        _detectCharactersTitleCase(rawText);
        break;
    }
  }

  /// Standard format: "ALL CAPS NAME. dialogue" on one line.
  void _detectCharactersStandard(String rawText) {
    final pattern = RegExp(
      r'^([A-Z][A-Z. ,]+(?:, *[A-Z][A-Z. ]+)*)\. ',
      multiLine: true,
    );
    for (final match in pattern.allMatches(rawText)) {
      _addCharacterCandidate(match.group(1)!);
    }
  }

  /// Name-on-own-line format: "ALL CAPS NAME." alone on a line.
  void _detectCharactersOwnLine(String rawText) {
    // Also pick up any that have dialogue on the same line (fallback)
    final ownLine = RegExp(
      r'^([A-Z][A-Z. ]+)\.\s*$',
      multiLine: true,
    );
    for (final match in ownLine.allMatches(rawText)) {
      _addCharacterCandidate(match.group(1)!);
    }
    final sameLine = RegExp(
      r'^([A-Z][A-Z. ,]+(?:, *[A-Z][A-Z. ]+)*)\. \S',
      multiLine: true,
    );
    for (final match in sameLine.allMatches(rawText)) {
      _addCharacterCandidate(match.group(1)!);
    }
  }

  /// Title-case format: "Name. dialogue" (e.g., First Folio Shakespeare).
  /// Stores names as UPPERCASE. For large inputs, requires 2+ occurrences
  /// to filter noise; for small inputs, 1 occurrence is enough since
  /// format detection already confirmed title-case style.
  void _detectCharactersTitleCase(String rawText) {
    final pattern = RegExp(
      r'^\s*([A-Z][a-z]+)\.\s',
      multiLine: true,
    );
    final counts = <String, int>{};
    for (final match in pattern.allMatches(rawText)) {
      final name = match.group(1)!.toUpperCase();
      counts[name] = (counts[name] ?? 0) + 1;
    }
    // For small inputs (< 10 total matches), accept names with 1 occurrence
    // since format detection already confirmed title-case style.
    final totalMatches = counts.values.fold<int>(0, (a, b) => a + b);
    final minOccurrences = totalMatches >= 10 ? 2 : 1;
    for (final entry in counts.entries) {
      if (entry.value >= minOccurrences) {
        final name = entry.key;
        if (name.length < 2 || name.length > 50) continue;
        if (RegExp(r'^(ACT|SCENE|SETTING|NOTE|PRODUCTION|ACTUS|SCENA|SCOENA)\b')
            .hasMatch(name)) continue;
        knownCharacters.add(name);
      }
    }
  }

  /// Validate and add a character name candidate.
  void _addCharacterCandidate(String rawName) {
    var name = rawName.trim();
    if (name.length < 2 || name.length > 50) return;
    if (RegExp(r'^(ACT|SCENE|SETTING|NOTE|PRODUCTION)\b').hasMatch(name)) {
      return;
    }
    if (_titlePrefixes.contains(name)) return;
    knownCharacters.add(name);
  }

  /// Strip Project Gutenberg preamble (before "*** START OF") and
  /// postamble (after "*** END OF") if present.
  static String _stripGutenbergWrapper(String text) {
    final startMatch =
        RegExp(r'\*\*\* ?START OF .+\*\*\*.*\n').firstMatch(text);
    if (startMatch != null) {
      text = text.substring(startMatch.end);
    }
    final endMatch = RegExp(r'\*\*\* ?END OF ').firstMatch(text);
    if (endMatch != null) {
      text = text.substring(0, endMatch.start);
    }
    // Strip table of contents + Dramatis Personæ preamble.
    // If "ACT I" (or "Actus") appears more than once, the first is in
    // the TOC and the last is where the actual play starts.
    text = _stripPreamble(text);
    return text;
  }

  /// Strip TOC and cast list that precede the actual play text.
  ///
  /// Detects two patterns:
  /// 1. Duplicate "ACT I" — first is TOC, last is the real start
  /// 2. "Dramatis Personæ" / "Cast of Characters" section
  static String _stripPreamble(String text) {
    // Find all occurrences of the first act header
    final actOnePattern = RegExp(
      r'^(?:ACT\s+I(?:\b|$)|Actus\s+Primus)',
      multiLine: true,
    );
    final matches = actOnePattern.allMatches(text).toList();
    if (matches.length >= 2) {
      // Skip to the last "ACT I" — that's where the real play starts
      text = text.substring(matches.last.start);
    } else if (matches.length == 1) {
      // Only one ACT I, but check for a Dramatis Personæ section before it.
      // Strip everything from "Dramatis" or "Cast of Characters" up to
      // the first ACT header.
      final dramatisMatch = RegExp(
        r'(?:Dramatis\s+Person|Cast\s+of\s+Characters|CHARACTERS)',
        caseSensitive: false,
      ).firstMatch(text);
      if (dramatisMatch != null && dramatisMatch.start < matches[0].start) {
        // Dramatis section is before ACT I — strip from start of text
        // to the ACT I header
        text = text.substring(matches[0].start);
      }
    }
    return text;
  }

  /// Auto-detect the script formatting convention.
  static ScriptFormat _detectFormat(String rawText) {
    // Count lines matching each pattern
    final standardCount = RegExp(
      r'^[A-Z][A-Z. ,]+\. \S',
      multiLine: true,
    ).allMatches(rawText).length;

    final ownLineCount = RegExp(
      r'^[A-Z][A-Z. ]+\.\s*$',
      multiLine: true,
    ).allMatches(rawText).length;

    // Title case: optionally indented capitalized word + period + space + text
    final titleCaseCount = RegExp(
      r'^\s*[A-Z][a-z]+\. \S',
      multiLine: true,
    ).allMatches(rawText).length;

    // Standard format takes priority when it has clear matches
    if (standardCount >= 5 &&
        standardCount >= ownLineCount &&
        standardCount >= titleCaseCount) {
      return ScriptFormat.standard;
    }
    // Name-on-own-line: 2+ matches is enough if it leads
    if (ownLineCount >= 2 && ownLineCount >= titleCaseCount) {
      return ScriptFormat.nameOnOwnLine;
    }
    // Title-case: 2+ matches is enough if it leads
    if (titleCaseCount >= 2 && titleCaseCount > standardCount) {
      return ScriptFormat.titleCase;
    }
    // For very small inputs: if only one format matches, use it
    if (ownLineCount > 0 && standardCount == 0) {
      return ScriptFormat.nameOnOwnLine;
    }
    if (titleCaseCount > 0 && standardCount == 0) {
      return ScriptFormat.titleCase;
    }
    // Default to standard
    return ScriptFormat.standard;
  }

  /// Dehyphenate OCR line breaks: "dan-\ngerous" → "dangerous".
  /// PDF OCR often splits words at line breaks with hyphens.
  static String _dehyphenate(String text) {
    // Match: lowercase letter, hyphen, newline, optional whitespace, lowercase letter
    // This avoids dehyphenating intentional hyphens (e.g., "well-known")
    return text.replaceAllMapped(
      RegExp(r'([a-z])-\n\s*([a-z])'),
      (m) => '${m.group(1)}${m.group(2)}',
    );
  }

  /// Merge OCR-garbled character names into their correct counterparts.
  ///
  /// Handles:
  /// 1. Trailing punctuation: "LYDIA. .." → LYDIA
  /// 2. OCR garbage detection: names with no vowels
  /// 3. Fuzzy matches (edit distance ≤ 2): BNGLEY→BINGLEY, FHTZWILLIAM→FITZWILLIAM
  ///    Only merges when one name is rare (≤ 2 occurrences) — prevents merging
  ///    legitimate characters like MR. BENNET / MRS. BENNET.
  /// 4. Title variant normalization: MR. DARCY→DARCY (only when DARCY is more common)
  void _mergeOcrCharacterNames(String rawText) {
    if (knownCharacters.length < 2) return;

    final toRemove = <String>{};
    final toAlias = <String, String>{};

    // Count how often each character name appears as a cue in the raw text
    final counts = <String, int>{};
    for (final name in knownCharacters) {
      final escaped = RegExp.escape(name);
      counts[name] = RegExp('^$escaped\\.\\s', multiLine: true)
          .allMatches(rawText)
          .length;
    }

    for (final name in knownCharacters) {
      // 1. Strip trailing punctuation/dots from names ("LYDIA. .." → "LYDIA")
      final cleaned = name.replaceAll(RegExp(r'[.\s]+$'), '').trim();
      if (cleaned != name && cleaned.isNotEmpty && knownCharacters.contains(cleaned)) {
        toAlias[name] = cleaned;
        toRemove.add(name);
        continue;
      }

      // 2. OCR garbage: no vowels in a 4+ letter name
      final letters = name.replaceAll(RegExp(r'[^A-Za-z]'), '');
      final vowels = letters.replaceAll(RegExp(r'[^AEIOUaeiou]'), '');
      if (letters.length >= 4 && vowels.isEmpty) {
        toRemove.add(name);
        continue;
      }
    }

    // 3. Fuzzy match: only merge rare names (≤ 2 occurrences) into common ones
    final nameList = knownCharacters.toList();
    for (final name in nameList) {
      if (toRemove.contains(name)) continue;
      final nameCount = counts[name] ?? 0;
      if (nameCount > 2) continue; // Not a rare name — don't fuzzy match

      for (final candidate in nameList) {
        if (candidate == name || toRemove.contains(candidate)) continue;
        final candidateCount = counts[candidate] ?? 0;
        if (candidateCount <= nameCount) continue; // Merge INTO more common name

        final dist = _editDistance(name, candidate);
        // Scale threshold: short names (≤5 chars) need exact-minus-1,
        // longer names allow up to 2 edits. Prevents MARY→DARCY.
        final maxDist = name.length <= 5 ? 1 : 2;
        if (dist > 0 && dist <= maxDist && name.length >= 4) {
          toAlias[name] = candidate;
          toRemove.add(name);
          break;
        }
      }
    }

    // 4. Title variant: "MR. DARCY" when "DARCY" exists and is more common.
    // Only merge rare titled variants (≤ 3 occurrences) — a character like
    // LADY MACBETH (60 lines) is distinct from MACBETH, not a title variant.
    for (final name in nameList) {
      if (toRemove.contains(name)) continue;
      final nameCount = counts[name] ?? 0;
      if (nameCount > 3) continue; // Not a rare variant — keep as distinct
      final withoutTitle = _stripTitle(name);
      if (withoutTitle != null && knownCharacters.contains(withoutTitle)) {
        final baseCount = counts[withoutTitle] ?? 0;
        if (baseCount > nameCount) {
          toAlias[name] = withoutTitle;
          toRemove.add(name);
        }
      }
    }

    // Apply aliases — keep aliased names in knownCharacters so _detectCharacterCue
    // can still match them during parsing. _normalizeCharacter in flushDialogue
    // handles the name normalization. Only remove true garbage (no-vowel names).
    for (final entry in toAlias.entries) {
      characterAliases[entry.key] = entry.value;
    }
    // Only remove garbage names, not aliased ones (they still need cue detection)
    final garbageOnly = toRemove.difference(toAlias.keys.toSet());
    knownCharacters.removeAll(garbageOnly);
  }

  /// For title-case scripts (e.g. First Folio), resolve abbreviated character
  /// names like HAM→HAMLET, HOR→HORATIO using:
  /// 1. Prefix merging among known character names (POL→POLON, BAR→BARN)
  /// 2. Full names extracted from Enter/Exit stage directions
  void _resolveTitleCaseAbbreviations(String rawText) {
    // 1. Prefix merging: merge shorter names into longer ones
    final byLength = knownCharacters.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (var i = 0; i < byLength.length; i++) {
      final longer = byLength[i];
      if (characterAliases.containsKey(longer)) continue;
      for (var j = i + 1; j < byLength.length; j++) {
        final shorter = byLength[j];
        if (characterAliases.containsKey(shorter)) continue;
        if (longer.startsWith(shorter) && shorter.length >= 2) {
          characterAliases[shorter] = longer;
        }
      }
    }

    // 2. Extract full names from Enter/Exit/Exeunt stage directions
    final enterPattern = RegExp(
      r'(?:Enter|Exit|Exeunt|Re-enter)\s+(.+?)(?:\.\s*$|\n)',
      multiLine: true,
    );
    final fullNames = <String>{};
    for (final match in enterPattern.allMatches(rawText)) {
      final text = match.group(1)!;
      for (final word
          in RegExp(r'\b([A-Z][a-z]{2,})\b').allMatches(text)) {
        fullNames.add(word.group(1)!.toUpperCase());
      }
    }

    // Map abbreviated character names → full names from stage directions
    for (final abbrev in knownCharacters.toList()) {
      if (characterAliases.containsKey(abbrev)) {
        // Already aliased by prefix merging — check if the alias target
        // itself can be resolved further
        final current = characterAliases[abbrev]!;
        for (final full in fullNames) {
          if (full.startsWith(current) && full.length > current.length) {
            characterAliases[current] = full;
            knownCharacters.add(full);
            break;
          }
        }
      } else {
        for (final full in fullNames) {
          if (full.startsWith(abbrev) && full.length > abbrev.length) {
            characterAliases[abbrev] = full;
            knownCharacters.add(full);
            break;
          }
        }
      }
    }
  }

  /// Strip title prefix from a name, returning null if no title found.
  static String? _stripTitle(String name) {
    final prefixes = [
      'MR. ', 'MRS. ', 'MS. ', 'MISS ', 'SIR ', 'LORD ', 'LADY ',
      'DR. ', 'REV. ', 'COLONEL ', 'CAPTAIN ', 'MR ', 'MRS ', 'MS ',
    ];
    final upper = name.toUpperCase();
    for (final prefix in prefixes) {
      if (upper.startsWith(prefix) && name.length > prefix.length) {
        return name.substring(prefix.length).trim();
      }
    }
    return null;
  }

  /// Levenshtein edit distance between two strings.
  static int _editDistance(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    final la = a.length, lb = b.length;
    // Use single-row optimization
    var prev = List.generate(lb + 1, (i) => i);
    var curr = List.filled(lb + 1, 0);

    for (var i = 1; i <= la; i++) {
      curr[0] = i;
      for (var j = 1; j <= lb; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        curr[j] = [
          prev[j] + 1, // deletion
          curr[j - 1] + 1, // insertion
          prev[j - 1] + cost, // substitution
        ].reduce((a, b) => a < b ? a : b);
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }
    return prev[lb];
  }

  /// Normalize a character name using aliases (follows chains).
  String _normalizeCharacter(String name) {
    var result = name;
    for (var i = 0; i < 5; i++) {
      final alias = characterAliases[result];
      if (alias == null || alias == result) break;
      result = alias;
    }
    return result;
  }

  /// Check if a line is noise.
  bool _isNoise(String line) {
    final stripped = line.trim();
    if (stripped.isEmpty) return true;
    for (final pattern in _noisePatterns) {
      if (pattern.hasMatch(stripped)) return true;
    }
    return false;
  }

  /// Clean OCR artifacts from text.
  String _cleanLine(String text) {
    text = text.replaceAll(RegExp(r'[|~°]'), '');
    text = text.replaceAll(RegExp(r'\s+[/\\]\s*$'), '');
    text = text.replaceAll(RegExp(r'  +'), ' ');
    // Strip trailing OCR noise: bracketed fragments like "[I.4 -HIL A leter for..."
    text = text.replaceAll(RegExp(r'\s*\[[A-Z0-9][^\]]*$'), '');
    return text.trim();
  }

  /// Detect character cue at start of line.
  ({String character, String dialogue})? _detectCharacterCue(String line) {
    final sorted = knownCharacters.toList()
      ..sort((a, b) => b.length.compareTo(a.length));

    final caseSensitive = _format != ScriptFormat.titleCase;

    for (final char in sorted) {
      final escaped = RegExp.escape(char);
      // Standard match: "NAME. dialogue..."
      final pattern = RegExp(
        '^$escaped\\.\\s+(.*)',
        caseSensitive: caseSensitive,
      );
      final match = pattern.firstMatch(line);
      if (match != null) {
        return (character: char, dialogue: match.group(1)!);
      }

      // Name-on-own-line: "NAME." with nothing after
      if (_format == ScriptFormat.nameOnOwnLine) {
        final ownLine = RegExp('^$escaped\\.\$');
        if (ownLine.hasMatch(line)) {
          return (character: char, dialogue: '');
        }
      }
    }
    return null;
  }

  /// Extract inline stage directions from dialogue.
  ///
  /// Handles three common patterns in play scripts:
  /// 1. Leading: "(Glancing at JANE;) And the prettiest of all."
  /// 2. Trailing: "...now. (The ball begins. ELIZABETH sits to one side.)"
  /// 3. Colon-style: "(To audience:) Mrs. Bennet, to be sure."
  ({String direction, String text}) _extractInlineDirection(String text) {
    var direction = '';
    var dialogue = text;

    // 1. Leading parenthetical: "(Direction) Dialogue..."
    final leadMatch = RegExp(r'^\(([^)]+)\)\s*(.+)').firstMatch(dialogue);
    if (leadMatch != null) {
      direction = leadMatch.group(1)!.replaceAll(RegExp(r':$'), '').trim();
      dialogue = leadMatch.group(2)!;
    }

    // 2. Trailing parenthetical: "...dialogue. (Direction)"
    // Match only after sentence-ending punctuation to avoid stripping
    // dialogue that happens to end with a parenthetical aside.
    final trailMatch =
        RegExp(r'^(.*[.!?])\s+\(([^)]+)\)\s*$').firstMatch(dialogue);
    if (trailMatch != null) {
      dialogue = trailMatch.group(1)!;
      final trailDir = trailMatch.group(2)!;
      direction = direction.isEmpty ? trailDir : '$direction; $trailDir';
    }

    // 3. Legacy colon-style: "(To audience:) dialogue" — already caught
    // by the leading pattern above, but handle the colon variant specifically
    // in case the leading match didn't fire (e.g., no space after paren).
    if (direction.isEmpty) {
      final colonMatch =
          RegExp(r'^\(([^)]+?):\)\s*(.*)').firstMatch(dialogue);
      if (colonMatch != null) {
        direction = colonMatch.group(1)!;
        dialogue = colonMatch.group(2)!;
      }
    }

    // Don't return empty dialogue — if extraction consumed everything,
    // keep the original text as dialogue.
    if (dialogue.trim().isEmpty) {
      return (direction: '', text: text);
    }

    return (direction: direction.trim(), text: dialogue.trim());
  }

  /// Check if a line is an Enter/Exit/Exeunt or other common stage direction.
  /// Covers Shakespeare conventions: entrances, exits, sound/music cues.
  /// Requires keyword followed by whitespace/punctuation/EOL — avoids matching
  /// words like "Alarum'd" (conjugated form in dialogue).
  static bool _isEnterExitLine(String line) {
    return RegExp(
      r"^(?:Enter|Exit|Exeunt|Re-enter|Manet|Manent|Thunder|Alarum|Flourish|Sennet|Retreat|Hautboys|Trumpets|Cornets)(?:\s|[.,;:!]|$)",
      caseSensitive: false,
    ).hasMatch(line);
  }

  /// Check if a stage direction text indicates a scene transition.
  bool _isSceneTransition(String text) {
    for (final pattern in _sceneTransitionPatterns) {
      if (pattern.hasMatch(text)) return true;
    }
    return false;
  }

  /// Extract a location label from transition text.
  String _extractLocation(String text) {
    for (final loc in _locationPatterns) {
      if (RegExp(loc.pattern, caseSensitive: false).hasMatch(text)) {
        return loc.location;
      }
    }
    return '';
  }

  List<ScriptLine> _parseLines(String rawText) {
    final textLines = rawText.split('\n');
    final result = <ScriptLine>[];

    var currentAct = 'ACT I';
    var currentScene = '';
    var currentCharacter = '';
    var dialogueParts = <String>[];
    var sceneLineNum = 0;
    var orderIndex = 0;

    void flushDialogue() {
      if (currentCharacter.isNotEmpty && dialogueParts.isNotEmpty) {
        var fullText = dialogueParts.join(' ');
        fullText = _cleanLine(fullText);
        if (fullText.isEmpty) return;

        final extracted = _extractInlineDirection(fullText);
        final charName = _normalizeCharacter(currentCharacter);

        sceneLineNum++;
        orderIndex++;
        result.add(ScriptLine(
          id: _uuid.v4(),
          act: currentAct,
          scene: currentScene,
          lineNumber: sceneLineNum,
          orderIndex: orderIndex,
          character: charName,
          text: extracted.text.isNotEmpty ? extracted.text : fullText,
          lineType: LineType.dialogue,
          stageDirection: extracted.direction,
        ));
      }
    }

    void addStageDirection(String text) {
      text = _cleanLine(text);
      if (text.isEmpty || text.length < 3) return;

      // Check if this direction triggers a new scene
      if (_isSceneTransition(text)) {
        flushDialogue();
        final location = _extractLocation(text);
        final sceneNum = result
                .where((l) => l.lineType == LineType.header && l.scene.isNotEmpty)
                .length +
            1;
        currentScene = location.isNotEmpty
            ? location
            : 'Scene $sceneNum';
        sceneLineNum = 0;
        currentCharacter = '';
        dialogueParts = [];
      }

      sceneLineNum++;
      orderIndex++;
      result.add(ScriptLine(
        id: _uuid.v4(),
        act: currentAct,
        scene: currentScene,
        lineNumber: sceneLineNum,
        orderIndex: orderIndex,
        character: '',
        text: text,
        lineType: LineType.stageDirection,
      ));
    }

    for (final rawLine in textLines) {
      final line = rawLine.trim();

      if (_isNoise(line)) continue;

      // ACT headers (includes Latin "Actus Primus" etc.)
      final actMatch = RegExp(
        r'^(?:ACT\s+([IV]+|\d+)|Actus\s+\w+)',
      ).firstMatch(line);
      if (actMatch != null) {
        flushDialogue();
        currentAct = line.trim();
        currentScene = '';
        sceneLineNum = 0;
        currentCharacter = '';
        dialogueParts = [];
        orderIndex++;
        result.add(ScriptLine(
          id: _uuid.v4(),
          act: currentAct,
          scene: '',
          lineNumber: 0,
          orderIndex: orderIndex,
          character: '',
          text: currentAct,
          lineType: LineType.header,
        ));
        continue;
      }

      // Explicit SCENE headers (supports "SCENE 1", "SCENE IV", "SCENE 1.2",
      // and Latin "Scena Secunda", "Scoena Prima")
      final sceneMatch = RegExp(
        r'^(?:SCENE\s+[\d.IVXiv]+|Sc[oe]na\s+\w+)',
        caseSensitive: false,
      ).firstMatch(line);
      if (sceneMatch != null) {
        flushDialogue();
        currentScene = line.trim();
        sceneLineNum = 0;
        currentCharacter = '';
        dialogueParts = [];
        continue;
      }

      final cleaned = _cleanLine(line);
      if (cleaned.isEmpty) continue;

      // Character cue
      final cue = _detectCharacterCue(cleaned);
      if (cue != null) {
        flushDialogue();
        currentCharacter = cue.character;
        dialogueParts = [cue.dialogue];
        continue;
      }

      // Standalone stage direction (parenthesized)
      if (cleaned.startsWith('(') && cleaned.endsWith(')')) {
        flushDialogue();
        currentCharacter = '';
        dialogueParts = [];
        addStageDirection(cleaned);
        continue;
      }

      // Bracketed stage direction: [_Exeunt._] or [Exit.]
      if (cleaned.startsWith('[') && cleaned.endsWith(']')) {
        flushDialogue();
        // In Shakespeare formats, dialogue often continues after stage
        // directions (e.g., Macbeth's "Is this a dagger" after [_Exit Servant._]).
        // Preserve currentCharacter so continuation lines are still attributed.
        if (_format == ScriptFormat.standard) {
          currentCharacter = '';
          dialogueParts = [];
        } else {
          dialogueParts = [''];
        }
        addStageDirection(cleaned);
        continue;
      }

      // Enter/Exit/Exeunt stage directions (common in Shakespeare texts)
      if (_isEnterExitLine(cleaned)) {
        flushDialogue();
        if (_format == ScriptFormat.standard) {
          currentCharacter = '';
          dialogueParts = [];
        } else {
          dialogueParts = [''];
        }
        addStageDirection(cleaned);
        continue;
      }

      // Continuation of current dialogue
      if (currentCharacter.isNotEmpty && dialogueParts.isNotEmpty) {
        if (cleaned.length > 2 && RegExp(r'[a-zA-Z]').hasMatch(cleaned)) {
          dialogueParts.add(cleaned);
        }
        continue;
      }

      // Orphan stage direction
      if (currentCharacter.isEmpty && cleaned.startsWith('(')) {
        addStageDirection(cleaned);
      }
    }

    flushDialogue();
    return result;
  }

  /// Detect scenes from parsed lines by finding transition boundaries.
  ///
  /// Strategy:
  /// 1. Scene lines already tagged during parsing (via "Shift begins" etc.)
  /// 2. Group consecutive lines with the same scene tag
  /// 3. For untagged opening sections, create a default scene
  /// 4. Name scenes by location + act
  List<ScriptScene> _detectScenes(List<ScriptLine> lines) {
    if (lines.isEmpty) return [];

    final scenes = <ScriptScene>[];
    var sceneStart = 0;
    var currentSceneTag = lines.first.scene;
    var currentAct = lines.first.act;
    var sceneCounter = 0;

    void closeScene(int endIndex) {
      // Don't create empty scenes
      final sceneLines = lines.sublist(sceneStart, endIndex + 1);
      final dialogueLines = sceneLines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      if (dialogueLines.isEmpty) {
        sceneStart = endIndex + 1;
        return;
      }

      sceneCounter++;

      // Gather characters in this scene
      final chars = <String>{};
      for (final l in dialogueLines) {
        if (l.character.isNotEmpty) chars.add(l.character);
      }

      // Find the transition stage direction for a description
      var description = '';
      for (final l in sceneLines) {
        if (l.lineType == LineType.stageDirection &&
            _isSceneTransition(l.text)) {
          description = l.text;
          break;
        }
      }

      // Determine location from scene tag or transition text
      var location = currentSceneTag;
      if (location.isEmpty && description.isNotEmpty) {
        location = _extractLocation(description);
      }

      final sceneName = '$currentAct, Scene $sceneCounter';

      scenes.add(ScriptScene(
        id: _uuid.v4(),
        act: currentAct,
        sceneName: sceneName,
        location: location,
        description: _cleanDescription(description),
        startLineIndex: sceneStart,
        endLineIndex: endIndex,
        characters: chars.toList()..sort(),
      ));

      sceneStart = endIndex + 1;
    }

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      // ACT boundary → close current scene and reset counter
      if (line.lineType == LineType.header && line.act != currentAct) {
        if (i > sceneStart) {
          closeScene(i - 1);
        }
        currentAct = line.act;
        currentSceneTag = '';
        sceneCounter = 0;
        sceneStart = i;
        continue;
      }

      // Scene boundary: scene tag changed
      if (line.scene != currentSceneTag && line.scene.isNotEmpty) {
        if (i > sceneStart) {
          closeScene(i - 1);
        }
        currentSceneTag = line.scene;
        sceneStart = i;
      }
    }

    // Close final scene
    if (sceneStart < lines.length) {
      closeScene(lines.length - 1);
    }

    return scenes;
  }

  /// Clean a transition stage direction into a readable description.
  String _cleanDescription(String text) {
    if (text.isEmpty) return '';
    // Strip parens
    var t = text.trim();
    if (t.startsWith('(')) t = t.substring(1);
    if (t.endsWith(')')) t = t.substring(0, t.length - 1);
    // Truncate if too long
    if (t.length > 120) t = '${t.substring(0, 117)}...';
    return t.trim();
  }
}
