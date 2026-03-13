import '../models/script_models.dart';

/// Export a parsed script to various text formats.
class ScriptExporter {
  /// Export to a clean, readable plain text format.
  ///
  /// Format:
  /// ```
  /// ========================================
  /// TITLE
  /// ========================================
  ///
  /// --- ACT I ---
  ///
  /// CHARACTER NAME: Dialogue text here
  /// CHARACTER NAME: (stage direction) Dialogue text
  ///   [Stage direction on its own line]
  /// ```
  static String toPlainText(ParsedScript script) {
    final buf = StringBuffer();

    buf.writeln('=' * 60);
    buf.writeln(script.title.toUpperCase());
    buf.writeln('=' * 60);
    buf.writeln();

    // Cast list
    buf.writeln('CAST OF CHARACTERS');
    buf.writeln('-' * 40);
    for (final char in script.characters) {
      buf.writeln('  ${char.name} (${char.lineCount} lines)');
    }
    buf.writeln();
    buf.writeln('=' * 60);
    buf.writeln();

    // Scene index
    if (script.scenes.isNotEmpty) {
      buf.writeln('SCENES');
      buf.writeln('-' * 40);
      for (var i = 0; i < script.scenes.length; i++) {
        final s = script.scenes[i];
        final charList = s.characters.take(4).join(', ');
        final more = s.characters.length > 4
            ? ' +${s.characters.length - 4} more'
            : '';
        buf.writeln('  ${i + 1}. ${s.displayLabel} [$charList$more]');
      }
      buf.writeln();
      buf.writeln('=' * 60);
      buf.writeln();
    }

    String currentScene = '';
    for (final line in script.lines) {
      // Insert scene headers
      if (line.scene != currentScene && line.scene.isNotEmpty) {
        currentScene = line.scene;
        buf.writeln();
        buf.writeln('=== $currentScene ===');
        buf.writeln();
      }

      switch (line.lineType) {
        case LineType.header:
          buf.writeln();
          buf.writeln('--- ${line.text} ---');
          buf.writeln();
          break;

        case LineType.stageDirection:
          buf.writeln('  [${_stripParens(line.text)}]');
          buf.writeln();
          break;

        case LineType.dialogue:
          final direction = line.stageDirection.isNotEmpty
              ? ' (${line.stageDirection})'
              : '';
          buf.writeln('${line.character}:$direction ${line.text}');
          buf.writeln();
          break;

        case LineType.song:
          buf.writeln('♪ ${line.character}: ${line.text}');
          buf.writeln();
          break;
      }
    }

    return buf.toString();
  }

  /// Export a single scene.
  static String toSceneText(ParsedScript script, ScriptScene scene) {
    final buf = StringBuffer();

    buf.writeln('=' * 60);
    buf.writeln('${scene.displayLabel} — ${script.title}');
    buf.writeln('=' * 60);
    buf.writeln();

    if (scene.description.isNotEmpty) {
      buf.writeln('[${scene.description}]');
      buf.writeln();
    }

    buf.writeln('Characters: ${scene.characters.join(", ")}');
    buf.writeln();
    buf.writeln('-' * 40);
    buf.writeln();

    final lines = script.linesInScene(scene);
    for (final line in lines) {
      switch (line.lineType) {
        case LineType.stageDirection:
          buf.writeln('  [${_stripParens(line.text)}]');
          buf.writeln();
          break;
        case LineType.dialogue:
        case LineType.song:
          final direction = line.stageDirection.isNotEmpty
              ? ' (${line.stageDirection})'
              : '';
          buf.writeln('${line.character}:$direction ${line.text}');
          buf.writeln();
          break;
        case LineType.header:
          buf.writeln('--- ${line.text} ---');
          buf.writeln();
          break;
      }
    }

    return buf.toString();
  }

  /// Export to markdown format (for reading/sharing).
  static String toMarkdown(ParsedScript script) {
    final buf = StringBuffer();

    buf.writeln('# ${script.title}');
    buf.writeln();

    // Cast list
    buf.writeln('## Cast of Characters');
    buf.writeln();
    for (final char in script.characters) {
      buf.writeln('- **${char.name}** (${char.lineCount} lines)');
    }
    buf.writeln();
    buf.writeln('---');
    buf.writeln();

    for (final line in script.lines) {
      switch (line.lineType) {
        case LineType.header:
          buf.writeln('## ${line.text}');
          buf.writeln();
          break;

        case LineType.stageDirection:
          buf.writeln('*${line.text}*');
          buf.writeln();
          break;

        case LineType.dialogue:
          final direction = line.stageDirection.isNotEmpty
              ? ' *(${line.stageDirection})* '
              : ' ';
          buf.writeln('**${line.character}.**$direction${line.text}');
          buf.writeln();
          break;

        case LineType.song:
          buf.writeln('> ♪ **${line.character}.** ${line.text}');
          buf.writeln();
          break;
      }
    }

    return buf.toString();
  }

  /// Export lines for a single character (for personal study).
  static String toCharacterLines(ParsedScript script, String characterName) {
    final buf = StringBuffer();

    buf.writeln('=' * 60);
    buf.writeln('${characterName.toUpperCase()} — ${script.title}');
    buf.writeln('=' * 60);
    buf.writeln();

    final charLines = script.lines
        .where((l) =>
            l.lineType == LineType.dialogue && l.character == characterName)
        .toList();

    buf.writeln('Total lines: ${charLines.length}');
    buf.writeln();

    String currentAct = '';
    for (final line in script.lines) {
      // Track act headers
      if (line.lineType == LineType.header && line.act != currentAct) {
        currentAct = line.act;
        buf.writeln('--- ${line.text} ---');
        buf.writeln();
        continue;
      }

      // Show cue lines (the line before yours) and your lines
      if (line.lineType == LineType.dialogue) {
        if (line.character == characterName) {
          final direction = line.stageDirection.isNotEmpty
              ? ' (${line.stageDirection})'
              : '';
          buf.writeln('  >>> YOU:$direction ${line.text}');
          buf.writeln();
        } else {
          // Show as cue context
          buf.writeln(
              '  ${line.character}: ${_truncate(line.text, 80)}');
        }
      } else if (line.lineType == LineType.stageDirection) {
        buf.writeln('  [${_stripParens(line.text)}]');
      }
    }

    return buf.toString();
  }

  /// Export a cue script (just cue lines + your lines).
  static String toCueScript(ParsedScript script, String characterName) {
    final buf = StringBuffer();

    buf.writeln('CUE SCRIPT: ${characterName.toUpperCase()}');
    buf.writeln(script.title);
    buf.writeln('=' * 60);
    buf.writeln();

    // Find all dialogue lines in order
    final dialogueLines = script.lines
        .where((l) => l.lineType == LineType.dialogue)
        .toList();

    for (var i = 0; i < dialogueLines.length; i++) {
      final line = dialogueLines[i];

      if (line.character == characterName) {
        // Show the cue line (previous line)
        if (i > 0) {
          final cue = dialogueLines[i - 1];
          buf.writeln(
              'CUE (${cue.character}): ...${_lastWords(cue.text, 8)}');
        }
        final direction = line.stageDirection.isNotEmpty
            ? ' (${line.stageDirection})'
            : '';
        buf.writeln('YOU:$direction ${line.text}');
        buf.writeln();
      }
    }

    return buf.toString();
  }

  static String _stripParens(String text) {
    var t = text.trim();
    if (t.startsWith('(')) t = t.substring(1);
    if (t.endsWith(')')) t = t.substring(0, t.length - 1);
    return t.trim();
  }

  static String _truncate(String text, int maxLen) {
    if (text.length <= maxLen) return text;
    return '${text.substring(0, maxLen - 3)}...';
  }

  static String _lastWords(String text, int wordCount) {
    final words = text.split(' ');
    if (words.length <= wordCount) return text;
    return words.sublist(words.length - wordCount).join(' ');
  }
}
