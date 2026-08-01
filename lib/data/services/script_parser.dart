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

  /// Multi-character name map: combined name → individual character names.
  /// e.g., "ELIZABETH AND JANE" → ["ELIZABETH", "JANE"]
  final Map<String, List<String>> multiCharacterMap = {};

  /// Detected script format (set during parse).
  ScriptFormat _format = ScriptFormat.standard;

  /// Normalized running-header text to drop (the script's own title repeated
  /// at the top of every page). OCR emits it as its own line, and without this
  /// the parse appends it to the PRECEDING speech as a continuation — 33 of
  /// P&P's 1189 lines ended with "Pride and Prejudice" glued on, which makes
  /// them impossible for an actor to match, so rehearsal sat on them until the
  /// silence timeout.
  final Set<String> _titleHeaders = {};

  /// The running headers the last parse detected (normalized) — surfaced so
  /// tests and import diagnostics can verify WHAT would be stripped.
  Set<String> get detectedRunningHeaders => Set.unmodifiable(_titleHeaders);

  /// Original-case scrub patterns for headers GLUED INTO a line: when a
  /// speech crosses a page break, OCR can emit "…Miss Elizabeth Bennet.
  /// Pride and Prejudice 47" as ONE line, which the standalone check above
  /// can never catch. Patterns match the header's exact printed casing (so
  /// dialogue that legitimately says "pride and prejudice" in lowercase is
  /// untouched) with optional adjacent page numbers.
  final List<RegExp> _headerScrubPatterns = [];

  static String _normalizeForHeader(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9 ]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  // Noise patterns (page headers, footers, OCR artifacts)
  static final List<RegExp> _noisePatterns = [
    RegExp(r'^\d+\s+\w+(\s+\w+){0,4}$'), // "12 Author Name" (page num + short text)
    RegExp(r'^\w+(\s+\w+){0,4}\s+\d+$'), // "Author Name 12" (short text + page num)
    RegExp(r'^\d+$'), // bare page numbers
    RegExp(r'^[|}\s]+$'), // OCR artifacts
    RegExp(r'^\$[A-Za-z\s]+$'), // OCR noise
    RegExp(r'^FTLN \d+'), // Folger Through Line Numbers
    RegExp(r'^ACT \d+\. SC\. \d+$'), // Folger running scene headers
    // Title-page / front-matter publishing credits — never dialogue.
    RegExp(r'^adapted by\b', caseSensitive: false),
    RegExp(r'^from the novel by\b', caseSensitive: false),
    RegExp(r'\bjon jory\b', caseSensitive: false), // adapter credit, drop anywhere
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

    // Strip markdown formatting (bold/italic) so character names parse correctly
    // e.g. "**MRS. BENNET.** Hello" → "MRS. BENNET. Hello"
    rawText = _stripMarkdown(rawText);

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

    // Detect multi-character names (e.g., "ELIZABETH AND JANE") and split
    // them into individual characters
    _detectMultiCharacterNames(rawText);

    _detectTitleHeaders(rawText, title);

    // Second pass: parse lines
    final lines = _parseLines(rawText);

    // A shift ANNOUNCED by a direction doesn't start the new scene — the
    // arrival direction does. Must run before scene detection, which reads
    // these tags.
    _deferAnnouncedSceneShifts(lines);

    // Third pass: detect scenes from parsed lines
    final scenes = _detectScenes(lines);

    // Build character list with line counts.
    // Multi-character lines credit each individual character.
    final charCounts = <String, int>{};
    for (final line in lines) {
      if (line.lineType == LineType.dialogue && line.character.isNotEmpty) {
        if (line.multiCharacters.isNotEmpty) {
          for (final char in line.multiCharacters) {
            charCounts[char] = (charCounts[char] ?? 0) + 1;
          }
        } else {
          charCounts[line.character] =
              (charCounts[line.character] ?? 0) + 1;
        }
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

  /// The script's title repeated as a page header, or null when there is no
  /// such header (or stripping it would be unsafe).
  ///
  /// Requires 3+ standalone occurrences — a genuinely spoken line matching the
  /// title wouldn't repeat — and refuses when the title is also a character
  /// name: in Shakespeare the title IS the lead ("Macbeth", "Hamlet"), whose
  /// cue lines normalize to the very same string, so stripping would delete
  /// every one of that character's speeches.
  /// Detect the script's RUNNING HEADERS from the text itself.
  ///
  /// Keying this to the production title was the original sin: productions
  /// get named "test5", so "Pride and Prejudice" was never detected and the
  /// header polluted lines throughout. A running header identifies itself:
  /// the same short line repeating 3+ times standalone. Guards against
  /// stripping real content:
  ///   - never a known character name (Shakespeare's title IS the lead —
  ///     "MACBETH" as a header would delete every cue);
  ///   - 2+ words and 8+ chars (page numbers/short interjections excluded);
  ///   - no terminal sentence punctuation (a repeated dialogue line or song
  ///     refrain ends with . ! ? — headers don't);
  ///   - not a stage direction, act/scene marker, or character cue.
  /// The production [title] additionally seeds a candidate under the
  /// original (looser) rules, preserving the old behavior when the names do
  /// match. At most the 3 most frequent candidates are kept.
  void _detectTitleHeaders(String rawText, String title) {
    _titleHeaders.clear();
    _headerScrubPatterns.clear();

    bool isCharacterName(String norm) {
      for (final c in knownCharacters) {
        if (_normalizeForHeader(c) == norm) return true;
        if (_normalizeForHeader(_normalizeCharacter(c)) == norm) return true;
      }
      return false;
    }

    // Count standalone occurrences of each plausible header line, keeping
    // the first raw (original-case) form for the inline scrub pattern and
    // the line positions for the spread test below.
    final counts = <String, int>{};
    final rawForm = <String, String>{};
    final firstIdx = <String, int>{};
    final lastIdx = <String, int>{};
    final pageEvidence = <String>{};
    final allLines = rawText.split('\n');

    bool isBareNumber(int i) {
      if (i < 0 || i >= allLines.length) return false;
      return RegExp(r'^\d{1,4}$').hasMatch(allLines[i].trim());
    }

    int prevNonEmpty(int i) {
      for (var j = i - 1; j >= 0; j--) {
        if (allLines[j].trim().isNotEmpty) return j;
      }
      return -1;
    }

    int nextNonEmpty(int i) {
      for (var j = i + 1; j < allLines.length; j++) {
        if (allLines[j].trim().isNotEmpty) return j;
      }
      return -1;
    }

    for (var i = 0; i < allLines.length; i++) {
      final t = allLines[i].trim();
      if (t.isEmpty || t.length > 60) continue;
      if (t.startsWith('(') || t.startsWith('[')) continue; // direction
      if (RegExp(r'[.!?]$').hasMatch(t)) continue; // dialogue/refrain
      if (RegExp(
              r'^(ACT|SCENE|ENTER|EXIT|EXEUNT|RE-ENTER|FLOURISH|ALARUM|SONG|MUSIC)\b',
              caseSensitive: false)
          .hasMatch(t)) {
        continue; // structure / unparenthesized stage business
      }
      if (t.endsWith(':') || t.endsWith('.')) continue; // cue-ish
      // A line that parses as a character cue is content, never a header —
      // guards repeated catchphrases whose terminal punctuation OCR dropped
      // ("JANE. I love you" x3 must not become strippable).
      if (_detectCharacterCue(t) != null) continue;
      final hasAdjacentDigits = RegExp(r'^\d+\s+|\s+\d+$').hasMatch(t);
      final norm = _normalizeForHeader(
          t.replaceAll(RegExp(r'^\d+\s+|\s+\d+$'), ''));
      if (norm.length < 8 || !norm.contains(' ')) continue;
      counts[norm] = (counts[norm] ?? 0) + 1;
      rawForm[norm] ??= t.replaceAll(RegExp(r'^\d+\s+|\s+\d+$'), '').trim();
      firstIdx[norm] ??= i;
      lastIdx[norm] = i;
      // The smoking gun only true PAGE headers have: a page number on the
      // same line or on an adjacent line. Refrains, name-on-own-line cues,
      // and stage directions are never numbered.
      if (hasAdjacentDigits ||
          isBareNumber(prevNonEmpty(i)) ||
          isBareNumber(nextNonEmpty(i))) {
        pageEvidence.add(norm);
      }
    }

    // A running header recurs from the FIRST page to the LAST; repeated
    // content (a song refrain, a chanted line) clusters within one number
    // or scene. Require occurrences to span at least half the document.
    bool documentWideSpread(String norm) {
      if (allLines.length < 20) return false;
      final span = (lastIdx[norm]! - firstIdx[norm]!) / allLines.length;
      return span >= 0.5;
    }

    // Real-corpus false positives that motivated the belt AND braces here:
    // Tartuffe's "MADAME PERNELLE" (name-on-own-line cue format the cue
    // detector doesn't parse) and Tempest's "Enter Ariel, and others"
    // (unparenthesized direction) both passed the shape rules — page-number
    // evidence is what neither had.
    final candidates = counts.entries
        .where((e) =>
            e.value >= 3 &&
            !isCharacterName(e.key) &&
            documentWideSpread(e.key) &&
            pageEvidence.contains(e.key))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in candidates.take(3)) {
      _titleHeaders.add(e.key);
    }

    // Title-seeded path (original behavior): the production title, when it
    // matches 3+ standalone lines and isn't a character.
    final normTitle = _normalizeForHeader(title);
    if (normTitle.isNotEmpty &&
        !_titleHeaders.contains(normTitle) &&
        !isCharacterName(normTitle)) {
      var standalone = 0;
      for (final l in rawText.split('\n')) {
        if (_normalizeForHeader(l) == normTitle) standalone++;
      }
      if (standalone >= 3) {
        _titleHeaders.add(normTitle);
        rawForm[normTitle] ??= title;
      }
    }

    // Inline scrub patterns: exact printed casing, flexible whitespace,
    // optional page number on either side.
    for (final norm in _titleHeaders) {
      final raw = rawForm[norm];
      if (raw == null || raw.isEmpty) continue;
      final words = raw.split(RegExp(r'\s+')).map(RegExp.escape).join(r'\s+');
      _headerScrubPatterns
          .add(RegExp('(\\d{1,4}\\s+)?$words(\\s+\\d{1,4})?'));
    }
  }

  /// Remove any glued-in running header from [line] (page-seam OCR joins).
  String _stripInlineHeaders(String line) {
    if (_headerScrubPatterns.isEmpty) return line;
    var out = line;
    for (final re in _headerScrubPatterns) {
      out = out.replaceAll(re, ' ');
    }
    return out == line
        ? line
        : out.replaceAll(RegExp(r'\s+'), ' ').trim();
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
    // "NAME. dialogue" format
    final pattern = RegExp(
      r'^([A-Z][A-Z. ,]+(?:, *[A-Z][A-Z. ]+)*)\. ',
      multiLine: true,
    );
    for (final match in pattern.allMatches(rawText)) {
      _addCharacterCandidate(match.group(1)!);
    }

    // "NAME:" or "NAME (aside):" format (Cyrano, some modern plays)
    final colonPattern = RegExp(
      r'^([A-Z][A-Z ]+?)(?:\s*\([^)]*\))?\s*:\s*$',
      multiLine: true,
    );
    for (final match in colonPattern.allMatches(rawText)) {
      _addCharacterCandidate(match.group(1)!.trim());
    }
  }

  /// Name-on-own-line format: "ALL CAPS NAME." alone on a line.
  void _detectCharactersOwnLine(String rawText) {
    // Character name on own line with trailing period: "MACBETH." — commas
    // allowed so shared cues like "MACBETH, LENNOX." are detected (and then
    // split into individuals by _detectMultiCharacterNames).
    final ownLineWithPeriod = RegExp(
      r'^([A-Z][A-Z. ,]+)\.\s*$',
      multiLine: true,
    );
    for (final match in ownLineWithPeriod.allMatches(rawText)) {
      _addCharacterCandidate(match.group(1)!);
    }

    // Character name on own line WITHOUT period: "MACBETH"
    // (common in PDFKit-extracted text). Must be ALL CAPS, 2-30 chars,
    // followed by a line that looks like dialogue (starts lowercase or
    // with a quote).
    final ownLineNoPeriod = RegExp(
      r'^([A-Z][A-Z ]{1,29})\s*$',
      multiLine: true,
    );
    for (final match in ownLineNoPeriod.allMatches(rawText)) {
      final name = match.group(1)!.trim();
      // Skip common stage directions and headers
      if (_isStageDirectionOrHeader(name)) continue;
      _addCharacterCandidate(name);
    }

    // Dialogue on same line: "MACBETH. Speak if you can."
    final sameLine = RegExp(
      r'^([A-Z][A-Z. ,]+(?:, *[A-Z][A-Z. ]+)*)\. \S',
      multiLine: true,
    );
    for (final match in sameLine.allMatches(rawText)) {
      _addCharacterCandidate(match.group(1)!);
    }
  }

  /// Check if an ALL-CAPS name is actually a stage direction or header.
  static bool _isStageDirectionOrHeader(String name) {
    const skip = {
      'ACT', 'SCENE', 'ENTER', 'EXIT', 'EXEUNT', 'ALARUM', 'ALARUMS',
      'FLOURISH', 'THUNDER', 'LIGHTNING', 'FRONT MATTER', 'CONTENTS',
      'SYNOPSIS', 'CHARACTERS IN THE PLAY', 'TEXTUAL INTRODUCTION',
      'THE TRAGEDY OF MACBETH', 'THE END', 'FINIS',
      'ACT 1', 'ACT 2', 'ACT 3', 'ACT 4', 'ACT 5',
    };
    if (skip.contains(name)) return true;
    // Skip if it starts with Enter/Exit/Exeunt
    if (name.startsWith('ENTER') || name.startsWith('EXIT') ||
        name.startsWith('EXEUNT')) return true;
    return false;
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

    // Reject fragments: very short ALL-CAPS strings that aren't real names
    // (e.g. "EA", "INE" from broken markdown parsing)
    final letters = name.replaceAll(RegExp(r'[^A-Za-z]'), '');
    if (letters.length < 2) return;

    // Reject names that contain ". " followed by more text (e.g. "JANE. MI",
    // "ELIZABETH. E") — these are broken character cue + dialogue fragments
    if (RegExp(r'\.\s+[A-Z]').hasMatch(name) &&
        !name.startsWith('MR') && !name.startsWith('MRS') &&
        !name.startsWith('DR') && !name.startsWith('ST.') &&
        !name.startsWith('SIR')) {
      return;
    }

    knownCharacters.add(name);
  }

  /// Strip markdown bold/italic markers so character names parse correctly.
  /// "**MRS. BENNET.** Hello" → "MRS. BENNET. Hello"
  /// Only strips bold markers (** and ***), not headings or rules,
  /// to avoid breaking plain-text Gutenberg files.
  static String _stripMarkdown(String text) {
    // Bold/bold-italic: ***text*** or **text**
    text = text.replaceAll(RegExp(r'\*{2,3}'), '');
    // Markdown heading markers (only if followed by a letter — avoids
    // stripping Gutenberg *** markers which are already removed)
    text = text.replaceAll(RegExp(r'^#{1,6}\s+(?=[A-Z])', multiLine: true), '');
    return text;
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
      r'^(?:ACT\s+(?:THE\s+)?(?:I(?:\b|$)|1\b|FIRST)\.?|Actus\s+Primus)',
      multiLine: true,
      caseSensitive: false,
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
    // "NAME. dialogue" or "NAME: dialogue" or "NAME:"
    final standardCount = RegExp(
      r'^[A-Z][A-Z. ,]+[.:] \S',
      multiLine: true,
    ).allMatches(rawText).length +
    RegExp(
      r'^[A-Z][A-Z ]+:\s*$',
      multiLine: true,
    ).allMatches(rawText).length;

    final ownLineCount = RegExp(
      r'^[A-Z][A-Z. ]+\.?\s*$',
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

    // 3. Fuzzy match: only merge rare names (≤ 2 occurrences) into common
    // ones. Pick the CLOSEST candidate, not the first within threshold —
    // taking the first in set-iteration order sent "MRS, BENNET" (distance 1
    // from MRS. BENNET) to MR. BENNET (distance 2), swapping the speakers.
    final nameList = knownCharacters.toList();
    for (final name in nameList) {
      if (toRemove.contains(name)) continue;
      final nameCount = counts[name] ?? 0;
      if (nameCount > 2) continue; // Not a rare name — don't fuzzy match
      if (name.length < 4) continue;

      // Scale threshold: short names (≤5 chars) need exact-minus-1, mid
      // names allow 2 edits (prevents MARY→DARCY), and long names (≥8)
      // allow 3 — "MKS BENNEE" → "MRS. BENNET" is 3 edits (field case from
      // a scanned import). The rare-only / first-letter / merge-into-more-
      // common guards all still apply.
      final maxDist = name.length <= 5 ? 1 : (name.length >= 8 ? 3 : 2);
      String? best;
      var bestDist = maxDist + 1;
      var bestCount = -1;
      for (final candidate in nameList) {
        if (candidate == name || toRemove.contains(candidate)) continue;
        final candidateCount = counts[candidate] ?? 0;
        if (candidateCount <= nameCount) continue; // Merge INTO more common name

        // MR. BENNET and MRS. BENNET are edit-distance 1 but are two PEOPLE —
        // never fuzzy-merge names that differ only in their title.
        if (_isConflictingTitleVariant(name, candidate)) continue;
        // OCR rarely corrupts the leading capital; requiring it blocks
        // real-but-rare characters from vanishing into lookalikes (ANNE→JANE).
        if (name[0] != candidate[0]) continue;

        final dist = _editDistance(name, candidate);
        if (dist == 0 || dist > maxDist) continue;
        if (dist < bestDist ||
            (dist == bestDist && candidateCount > bestCount)) {
          best = candidate;
          bestDist = dist;
          bestCount = candidateCount;
        }
      }
      if (best != null) {
        toAlias[name] = best;
        toRemove.add(name);
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

  /// Detect multi-character names in [knownCharacters] and populate
  /// [multiCharacterMap] with the split. Also adds the individual names
  /// to [knownCharacters] so they get proper voice/color assignments.
  void _detectMultiCharacterNames(String rawText) {
    for (final name in knownCharacters.toList()) {
      final parts = _tryMultiCharacterSplit(name);
      if (parts != null && parts.length >= 2) {
        multiCharacterMap[name] = parts;
        // Ensure individual characters are in the known set
        for (final part in parts) {
          knownCharacters.add(part);
        }
        continue;
      }

      // OCR sometimes eats a dual cue's separator outright
      // ("ANNE/LADY CATHERINE." → "ANNEADYCATHERINE.", field case from a
      // scanned import). Recover the split against the known cast — but
      // only for RARE cues: a frequent cue spelled this way is a real
      // name, not a corruption.
      final glued = _tryGluedMultiCharacterSplit(name);
      if (glued != null) {
        final escaped = RegExp.escape(name);
        final count = RegExp('^$escaped\\.\\s', multiLine: true)
            .allMatches(rawText)
            .length;
        if (count <= 2) {
          multiCharacterMap[name] = glued;
          for (final part in glued) {
            knownCharacters.add(part);
          }
        }
      }
    }
  }

  /// "ANNEADYCATHERINE" → [ANNE, LADY CATHERINE]: fires only when the glued
  /// cue ENDS with a known long character name (≤1 edit after stripping
  /// spaces/punctuation — the eaten separator often takes the next letter
  /// with it) and the leftover prefix is a short plausible name.
  List<String>? _tryGluedMultiCharacterSplit(String name) {
    // Cue-corruption recovery only applies to all-caps cue names that are a
    // single glued token: a separator eaten by OCR leaves NO space behind.
    // Multi-word names ("A YOUNG MARQUIS", "ALL THE CADETS") are legitimate
    // compositional cues — splitting those manufactured phantom characters
    // across the Cyrano corpus.
    if (name != name.toUpperCase()) return null;
    if (name.contains(' ')) return null;
    final s = name.replaceAll(RegExp(r'[^A-Z]'), '');
    if (s.length < 10) return null;

    for (final known in knownCharacters) {
      if (known == name) continue;
      final k = known.replaceAll(RegExp(r'[^A-Z]'), '');
      // Suffix candidate must be long (multi-word names like LADY
      // CATHERINE) and leave at least 3 chars of prefix.
      if (k.length < 8 || k.length + 3 > s.length) continue;
      // The suffix may have lost its leading letter to the eaten separator,
      // so try both split points and keep the best: lowest edit distance,
      // then a prefix that's already in the cast, then the longer prefix
      // ("ANNE|[L]ADY CATHERINE" beats "ANN|[E]ADYCATHERINE" on a tie).
      String? bestPrefix;
      var bestDist = 2;
      var bestPrefixKnown = false;
      for (final win in [k.length, k.length - 1]) {
        if (win + 3 > s.length) continue;
        final suffix = s.substring(s.length - win);
        final dist = _editDistance(suffix, k);
        if (dist > 1) continue;
        final prefix = s.substring(0, s.length - win);
        if (prefix.length < 3 || _titlePrefixes.contains(prefix)) continue;
        final prefixIsKnown = knownCharacters
            .any((c) => c.replaceAll(RegExp(r'[^A-Z]'), '') == prefix);
        final better = dist < bestDist ||
            (dist == bestDist &&
                ((prefixIsKnown && !bestPrefixKnown) ||
                    (prefixIsKnown == bestPrefixKnown &&
                        prefix.length > (bestPrefix?.length ?? 0))));
        if (better) {
          bestPrefix = prefix;
          bestDist = dist;
          bestPrefixKnown = prefixIsKnown;
        }
      }
      if (bestPrefix != null) {
        // Prefer the cast's spelling if the prefix is already a known name.
        final prefixKnown = knownCharacters.firstWhere(
            (c) => c.replaceAll(RegExp(r'[^A-Z]'), '') == bestPrefix,
            orElse: () => bestPrefix!);
        return [prefixKnown, known];
      }
    }
    return null;
  }

  /// Try to split a character name into multiple individual characters.
  /// Returns null if this is a single-character name.
  ///
  /// Recognized separators: " AND ", " & ", "/", ", " (between valid names).
  static List<String>? _tryMultiCharacterSplit(String name) {
    // Try each separator in priority order
    for (final separator in [' AND ', ' & ', '/', ', ']) {
      if (!name.contains(separator)) continue;
      final parts = name
          .split(separator)
          .map((p) => p.trim())
          .where((p) => p.isNotEmpty)
          .toList();
      if (parts.length >= 2 &&
          parts.every((p) =>
              _looksLikeCharacterName(p) &&
              // "MRS, BENNET" (OCR comma-for-period) is ONE person, not the
              // pair [MRS, BENNET] — splitting it injected bare title words
              // as characters.
              !_titlePrefixes.contains(p.replaceAll('.', '').trim()))) {
        return parts;
      }
    }
    return null;
  }

  /// Check if a string looks like a character name (ALL CAPS, 2+ chars).
  static bool _looksLikeCharacterName(String s) {
    if (s.length < 2) return false;
    return RegExp(r'^[A-Z][A-Z. ]+$').hasMatch(s);
  }

  /// True when [a] and [b] are the same surname under two DIFFERENT titles
  /// ("MR. BENNET" vs "MRS. BENNET") — distinct people despite a tiny edit
  /// distance, so fuzzy merging must never combine them.
  static bool _isConflictingTitleVariant(String a, String b) {
    final baseA = _stripTitle(a);
    final baseB = _stripTitle(b);
    if (baseA == null || baseB == null) return false;
    return baseA == baseB && a != b;
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
    if (_titleHeaders.isNotEmpty) {
      final norm = _normalizeForHeader(stripped);
      if (_titleHeaders.contains(norm)) return true;
      // "Pride and Prejudice 47" / "47 Pride and Prejudice"
      final noPage =
          norm.replaceAll(RegExp(r'^\d+ +| +\d+$'), '').trim();
      if (_titleHeaders.contains(noPage)) return true;
    }
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
  /// Compiled cue patterns per character, rebuilt only when the character
  /// set or format changes. _detectCharacterCue runs for EVERY text line —
  /// recompiling ~5 regexes per character per line was ~10^5 compilations
  /// on a full-length import.
  List<({String char, RegExp dot, RegExp colonEmpty, RegExp colonInline,
      RegExp? ownLine, RegExp? flexible})>? _cuePatterns;
  int _cuePatternsCharCount = -1;
  ScriptFormat? _cuePatternsFormat;

  List<({String char, RegExp dot, RegExp colonEmpty, RegExp colonInline,
      RegExp? ownLine, RegExp? flexible})> _buildCuePatterns() {
    final sorted = knownCharacters.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final caseSensitive = _format != ScriptFormat.titleCase;
    return [
      for (final char in sorted)
        (() {
          final escaped = RegExp.escape(char);
          final tokens = char
              .split(RegExp(r'[.\s]+'))
              .where((t) => t.isNotEmpty)
              .toList();
          return (
            char: char,
            dot: RegExp('^$escaped\\.\\s+(.*)', caseSensitive: caseSensitive),
            colonEmpty: RegExp('^$escaped(?:\\s*\\([^)]*\\))?\\s*:\$',
                caseSensitive: caseSensitive),
            colonInline: RegExp('^$escaped(?:\\s*\\([^)]*\\))?\\s*:\\s+(.*)',
                caseSensitive: caseSensitive),
            ownLine: _format == ScriptFormat.nameOnOwnLine
                ? RegExp('^$escaped\\.?\$')
                : null,
            flexible: tokens.length < 2
                ? null
                : RegExp(
                    '^${tokens.map(RegExp.escape).join(r'[.,:]?\s*')}\\s*[.:]\\s+(.*)',
                    caseSensitive: caseSensitive),
          );
        })(),
    ];
  }

  ({String character, String dialogue})? _detectCharacterCue(String line) {
    if (_cuePatterns == null ||
        _cuePatternsCharCount != knownCharacters.length ||
        _cuePatternsFormat != _format) {
      _cuePatterns = _buildCuePatterns();
      _cuePatternsCharCount = knownCharacters.length;
      _cuePatternsFormat = _format;
    }
    final patterns = _cuePatterns!;

    for (final p in patterns) {
      // Standard match: "NAME. dialogue..."
      final match = p.dot.firstMatch(line);
      if (match != null) {
        return (character: p.char, dialogue: match.group(1)!);
      }

      // "NAME:" or "NAME (aside):" — colon format (Cyrano etc.)
      if (p.colonEmpty.hasMatch(line)) {
        return (character: p.char, dialogue: '');
      }
      // "NAME: dialogue..." — colon with inline dialogue
      final colonInline = p.colonInline.firstMatch(line);
      if (colonInline != null) {
        return (character: p.char, dialogue: colonInline.group(1)!);
      }

      // Name-on-own-line: "NAME." or "NAME" with nothing after
      if (p.ownLine != null && p.ownLine!.hasMatch(line)) {
        return (character: p.char, dialogue: '');
      }
    }

    // OCR-tolerant second pass: punctuation INSIDE a known multi-word name is
    // routinely misread ("MRS, BENNET. …", "MRS.BENNET. …") which used to
    // shunt the whole line into the previous speaker's dialogue. Allow
    // [.,:] variants and missing spaces between the name's tokens, but keep
    // the trailing cue separator strict ('.' or ':' + space) so dialogue that
    // merely STARTS with a name ("MARY, come here…") is never consumed.
    for (final p in patterns) {
      final flexible = p.flexible;
      if (flexible == null) continue; // single tokens: exact pass covers them
      final match = flexible.firstMatch(line);
      if (match != null) {
        return (character: p.char, dialogue: match.group(1)!);
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

  /// A direction that ANNOUNCES a transition rather than completing it:
  /// "(Shift begins into First Ball.)". The script keeps playing the
  /// outgoing scene across it — the new scene starts at the ARRIVAL
  /// direction, "(The ball begins. ELIZABETH sits to one side…)".
  static final _shiftAnnouncementRe = RegExp(
    r'\b(?:shift|transition|change|crossfade)\s+(?:begins|starts|beginning)\b'
    r'|\bbegins?\s+to\s+(?:shift|change)\b',
    caseSensitive: false,
  );

  /// Move a scene boundary from an announced shift to the arrival direction
  /// that completes it.
  ///
  /// Field report: rehearsing "ACT I, Scene 2" (the Ball) opened with MR.
  /// BENNET's Longbourn line — the scan really does print
  ///   (Shift begins into First Ball.)
  ///   MR. BENNET. Yes, I fear that as I have actually paid the visit…
  ///   (The ball begins. ELIZABETH sits to one side…)
  /// so a line delivered DURING the shift was being swept into the new
  /// scene. Only fires when an arrival direction follows within a few
  /// lines; a lone announcement still starts its scene where it always did.
  void _deferAnnouncedSceneShifts(List<ScriptLine> lines) {
    const lookahead = 4;
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i];
      if (line.lineType != LineType.stageDirection) continue;
      if (line.scene == lines[i - 1].scene) continue; // not a boundary
      if (!_shiftAnnouncementRe.hasMatch(line.text)) continue;

      // Only defer to a direction that names the SAME destination — the
      // arrival that completes this shift ("into First Ball" → "The ball
      // begins"). That keeps the change to moving a boundary a line or two
      // later; it can never create or drop a scene.
      final destination = _extractLocation(line.text);
      if (destination.isEmpty) continue;
      var arrival = -1;
      for (var j = i + 1; j < lines.length && j <= i + lookahead; j++) {
        if (lines[j].lineType != LineType.stageDirection) continue;
        if (_extractLocation(lines[j].text) == destination) {
          arrival = j;
          break;
        }
      }
      if (arrival < 0) continue; // no arrival — keep the existing boundary

      final outgoing = lines[i - 1].scene;
      for (var k = i; k < arrival; k++) {
        lines[k] = lines[k].copyWith(scene: outgoing);
      }
    }
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
        final multiChars = multiCharacterMap[charName] ?? const [];

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
          multiCharacters: multiChars,
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

    // Accumulates a parenthesized stage direction that spans multiple raw
    // lines ("(The ball begins. ELIZABETH sits" … "to one side.)"). Without
    // this, the wrapped continuation lines were glued into the surrounding
    // DIALOGUE as if the speaker said them.
    var pendingDirection = '';

    for (final rawLine in textLines) {
      var line = rawLine.trim();

      // Finish (or keep accumulating) a multi-line parenthetical direction.
      if (pendingDirection.isNotEmpty) {
        final cleanedCont = _cleanLine(line);
        // A new character cue means the direction's ')' was lost by OCR —
        // emit what we have and process the cue normally below.
        final bailToCue =
            cleanedCont.isNotEmpty && _detectCharacterCue(cleanedCont) != null;
        if (!bailToCue) {
          final closeIdx = cleanedCont.indexOf(')');
          if (closeIdx >= 0) {
            addStageDirection(
                '$pendingDirection ${cleanedCont.substring(0, closeIdx + 1)}');
            pendingDirection = '';
            // Dialogue may continue after the direction on the same line;
            // attribute it to the still-current speaker.
            final rest = cleanedCont.substring(closeIdx + 1).trim();
            dialogueParts = [if (rest.isNotEmpty) rest else ''];
            continue;
          }
          if (pendingDirection.length < 400) {
            if (cleanedCont.isNotEmpty) pendingDirection += ' $cleanedCont';
            continue;
          }
        }
        // Bail: runaway accumulation (OCR lost the ')') or a cue arrived.
        addStageDirection(pendingDirection);
        pendingDirection = '';
        dialogueParts = [''];
        // fall through to process this line normally
      }

      // ACT headers — check BEFORE noise filter since "ACT 1" looks like noise.
      // Matches: "ACT I", "ACT 1", "ACT THE FIRST.", "ACT FIRST.",
      // "Actus Primus", but NOT Folger running headers "ACT 2. SC. 1"
      final isRunningHeader = RegExp(r'ACT \d+\. SC\.', caseSensitive: false).hasMatch(line);
      final actMatch = isRunningHeader
          ? null
          : RegExp(
              r'^(?:ACT\s+(?:THE\s+)?(?:[IV]+|\d+|FIRST|SECOND|THIRD|FOURTH|FIFTH)\.?|Actus\s+\w+)',
              caseSensitive: false,
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

      // Scrub any glued-in running header (page-seam OCR joins) BEFORE the
      // noise check, so partially-header lines keep their real content.
      line = _stripInlineHeaders(line);

      // Noise filter (after act/scene checks which look like noise)
      if (_isNoise(line)) continue;

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
        // Acting editions (e.g. Jon Jory's) continue a speech after a
        // centered parenthetical with NO repeated cue — keep the speaker so
        // the continuation is attributed (as its own line) instead of
        // silently dropped. Scene transitions still clear the speaker
        // inside addStageDirection.
        dialogueParts = [''];
        addStageDirection(cleaned);
        continue;
      }

      // Opening fragment of a multi-line parenthetical direction.
      if (cleaned.startsWith('(') && !cleaned.contains(')')) {
        flushDialogue();
        pendingDirection = cleaned;
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

    if (pendingDirection.isNotEmpty) addStageDirection(pendingDirection);
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

      // Gather characters in this scene. For multi-character lines,
      // add each individual character rather than the combined name.
      final chars = <String>{};
      for (final l in dialogueLines) {
        if (l.multiCharacters.isNotEmpty) {
          chars.addAll(l.multiCharacters);
        } else if (l.character.isNotEmpty) {
          chars.add(l.character);
        }
      }

      // Find the transition stage direction for a description.
      // Skip an announcement of the NEXT shift ("(Shift begins into First
      // Ball.)"), which now sits at the tail of this scene — it names where
      // the play is GOING, so using it would label this scene with the next
      // scene's location.
      var description = '';
      for (final l in sceneLines) {
        if (l.lineType == LineType.stageDirection &&
            _isSceneTransition(l.text) &&
            !_shiftAnnouncementRe.hasMatch(l.text)) {
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
