import 'package:uuid/uuid.dart';

import '../models/script_models.dart';

const _uuid = Uuid();

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

  // Noise patterns (page headers, footers, OCR artifacts)
  static final List<RegExp> _noisePatterns = [
    RegExp(r'^\d+\s+\w+\s+\w+$'), // "12 Jon Jory"
    RegExp(r'^\w+\s+\w+\s+\d+$'), // "Jon Jory 12"
    RegExp(r'^Pride and Prejudice\s+\d+$'),
    RegExp(r'^\d+$'), // bare page numbers
    RegExp(r'^[|}\s]+$'), // OCR artifacts
    RegExp(r'^\$[A-Za-z\s]+$'), // OCR noise
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
    // First pass: detect character names from the text
    _detectCharacters(rawText);

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

  /// Detect character names from the raw text using the
  /// "ALL CAPS WORD(S). " pattern.
  void _detectCharacters(String rawText) {
    final pattern = RegExp(
      r'^([A-Z][A-Z.\s,]+(?:,\s*[A-Z][A-Z.\s]+)*)\.\s',
      multiLine: true,
    );

    final matches = pattern.allMatches(rawText);
    for (final match in matches) {
      var name = match.group(1)!.trim();
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

  /// Check if a line is noise.
  bool _isNoise(String line) {
    final stripped = line.trim();
    if (stripped.isEmpty) return true;
    for (final pattern in _noisePatterns) {
      if (pattern.hasMatch(stripped)) return true;
    }
    return false;
  }

  /// Clean OCR artifacts.
  String _cleanLine(String text) {
    text = text.replaceAll(RegExp(r'[|~°]'), '');
    text = text.replaceAll(RegExp(r'\s+[/\\]\s*$'), '');
    text = text.replaceAll(RegExp(r'  +'), ' ');
    return text.trim();
  }

  /// Detect character cue at start of line.
  ({String character, String dialogue})? _detectCharacterCue(String line) {
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

  /// Extract inline stage direction from dialogue.
  ({String direction, String text}) _extractInlineDirection(String text) {
    final match = RegExp(r'^\(([^)]+?):\)\s*(.*)').firstMatch(text);
    if (match != null) {
      return (direction: match.group(1)!, text: match.group(2)!);
    }
    return (direction: '', text: text);
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

      // Explicit SCENE headers (supports "SCENE 1", "SCENE IV", "SCENE 1.2")
      final sceneMatch =
          RegExp(r'^SCENE\s+[\d.IV]+', caseSensitive: false)
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
