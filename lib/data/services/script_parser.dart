import 'package:uuid/uuid.dart';

import '../models/script_models.dart';

const _uuid = Uuid();

/// Parses raw OCR text from a play script into structured [ScriptLine] records.
///
/// Handles standard American play format:
///   CHARACTER NAME. Dialogue text here
///   CHARACTER NAME. (Stage direction:) Dialogue text
///   (Standalone stage direction)
///   ACT I / SCENE 1 headers
class ScriptParser {
  /// Known characters — populated during parsing from detected names,
  /// or pre-seeded by the organizer.
  final Set<String> knownCharacters = {};

  /// Character alias normalization map.
  final Map<String, String> characterAliases = {};

  // Noise patterns (page headers, footers, OCR artifacts)
  static final List<RegExp> _noisePatterns = [
    RegExp(r'^\d+\s+\w+\s+\w+$'), // "12 Jon Jory"
    RegExp(r'^\w+\s+\w+\s+\d+$'), // "Jon Jory 12"
    RegExp(r'^Pride and Prejudice\s+\d+$'),
    RegExp(r'^\d+$'), // bare page numbers
    RegExp(r'^[|}\s]+$'), // OCR artifacts
    RegExp(r'^\$[A-Za-z\s]+$'), // OCR noise
  ];

  /// Parse raw text into a [ParsedScript].
  ParsedScript parse(String rawText, {String title = 'Untitled'}) {
    // First pass: detect character names from the text
    _detectCharacters(rawText);

    // Second pass: parse lines
    final lines = _parseLines(rawText);

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
      ));
    }

    return ParsedScript(
      title: title,
      lines: lines,
      characters: characters,
      rawText: rawText,
    );
  }

  /// Detect character names from the raw text using the
  /// "ALL CAPS WORD(S). " pattern.
  void _detectCharacters(String rawText) {
    // Pattern: Start of line, ALL CAPS words (may include periods in names
    // like "MR." or "MRS."), followed by a period and space.
    final pattern = RegExp(
      r'^([A-Z][A-Z.\s,]+(?:,\s*[A-Z][A-Z.\s]+)*)\.\s',
      multiLine: true,
    );

    final matches = pattern.allMatches(rawText);
    for (final match in matches) {
      var name = match.group(1)!.trim();
      // Skip things that are clearly not character names
      if (name.length < 2 || name.length > 50) continue;
      if (RegExp(r'^(ACT|SCENE|SETTING|NOTE|PRODUCTION)\b').hasMatch(name)) {
        continue;
      }
      knownCharacters.add(name);
    }
  }

  /// Normalize a character name using aliases.
  String _normalizeCharacter(String name) {
    return characterAliases[name] ?? name;
  }

  /// Check if a line is noise (page header/footer/OCR artifact).
  bool _isNoise(String line) {
    final stripped = line.trim();
    if (stripped.isEmpty) return true;
    for (final pattern in _noisePatterns) {
      if (pattern.hasMatch(stripped)) return true;
    }
    return false;
  }

  /// Clean OCR artifacts from a line of text.
  String _cleanLine(String text) {
    // Remove stray pipes, tildes, degrees
    text = text.replaceAll(RegExp(r'[|~°]'), '');
    // Remove trailing slash artifacts
    text = text.replaceAll(RegExp(r'\s+[/\\]\s*$'), '');
    // Collapse multiple spaces
    text = text.replaceAll(RegExp(r'  +'), ' ');
    return text.trim();
  }

  /// Try to detect a character cue at the start of a line.
  /// Returns (characterName, dialogueText) or null.
  ({String character, String dialogue})? _detectCharacterCue(String line) {
    // Sort known characters by length (longest first) for greedy match
    final sorted = knownCharacters.toList()
      ..sort((a, b) => b.length.compareTo(a.length));

    for (final char in sorted) {
      final escaped = RegExp.escape(char);
      final pattern = RegExp('^$escaped\\.\\s+(.*)');
      final match = pattern.firstMatch(line);
      if (match != null) {
        return (character: char, dialogue: match.group(1)!);
      }
    }
    return null;
  }

  /// Extract an inline stage direction from dialogue start.
  /// e.g. "(Smiling:) Hello" → (direction: "Smiling", text: "Hello")
  ({String direction, String text}) _extractInlineDirection(String text) {
    final match = RegExp(r'^\(([^)]+?):\)\s*(.*)').firstMatch(text);
    if (match != null) {
      return (direction: match.group(1)!, text: match.group(2)!);
    }
    return (direction: '', text: text);
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

      // ACT headers
      final actMatch = RegExp(r'^ACT\s+([IV]+|\d+)').firstMatch(line);
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

      // SCENE headers
      final sceneMatch =
          RegExp(r'^SCENE\s+(\d+|[IV]+)', caseSensitive: false)
              .firstMatch(line);
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

      // Standalone stage direction
      if (cleaned.startsWith('(') && cleaned.endsWith(')')) {
        flushDialogue();
        currentCharacter = '';
        dialogueParts = [];
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

      // Orphan stage direction starting with (
      if (currentCharacter.isEmpty && cleaned.startsWith('(')) {
        addStageDirection(cleaned);
      }
    }

    // Flush remaining
    flushDialogue();

    return result;
  }
}
