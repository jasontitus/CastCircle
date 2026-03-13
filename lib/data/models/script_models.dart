/// Line type classification for script parsing.
enum LineType {
  dialogue,
  stageDirection,
  header,
  song,
}

/// A single line in a parsed script.
class ScriptLine {
  final String id;
  final String act;
  final String scene;
  final int lineNumber;
  final int orderIndex;
  final String character; // empty for stage directions and headers
  final String text;
  final LineType lineType;
  final String stageDirection; // inline direction like "(Smiling:)"

  const ScriptLine({
    required this.id,
    required this.act,
    required this.scene,
    required this.lineNumber,
    required this.orderIndex,
    required this.character,
    required this.text,
    required this.lineType,
    this.stageDirection = '',
  });

  ScriptLine copyWith({
    String? id,
    String? act,
    String? scene,
    int? lineNumber,
    int? orderIndex,
    String? character,
    String? text,
    LineType? lineType,
    String? stageDirection,
  }) {
    return ScriptLine(
      id: id ?? this.id,
      act: act ?? this.act,
      scene: scene ?? this.scene,
      lineNumber: lineNumber ?? this.lineNumber,
      orderIndex: orderIndex ?? this.orderIndex,
      character: character ?? this.character,
      text: text ?? this.text,
      lineType: lineType ?? this.lineType,
      stageDirection: stageDirection ?? this.stageDirection,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'act': act,
        'scene': scene,
        'line_number': lineNumber,
        'order_index': orderIndex,
        'character': character,
        'text': text,
        'line_type': lineType.name,
        'stage_direction': stageDirection,
      };

  factory ScriptLine.fromJson(Map<String, dynamic> json) => ScriptLine(
        id: json['id'] as String,
        act: json['act'] as String? ?? '',
        scene: json['scene'] as String? ?? '',
        lineNumber: json['line_number'] as int,
        orderIndex: json['order_index'] as int,
        character: json['character'] as String? ?? '',
        text: json['text'] as String,
        lineType: LineType.values.byName(json['line_type'] as String),
        stageDirection: json['stage_direction'] as String? ?? '',
      );
}

/// A character/role in the production.
class ScriptCharacter {
  final String name;
  final int colorIndex;
  final int lineCount;

  const ScriptCharacter({
    required this.name,
    required this.colorIndex,
    required this.lineCount,
  });
}

/// A complete parsed script.
class ParsedScript {
  final String title;
  final List<ScriptLine> lines;
  final List<ScriptCharacter> characters;
  final String rawText;

  const ParsedScript({
    required this.title,
    required this.lines,
    required this.characters,
    required this.rawText,
  });

  /// Get all lines for a specific character.
  List<ScriptLine> linesForCharacter(String characterName) {
    return lines
        .where((l) =>
            l.lineType == LineType.dialogue && l.character == characterName)
        .toList();
  }

  /// Get all lines in a specific act.
  List<ScriptLine> linesInAct(String act) {
    return lines.where((l) => l.act == act).toList();
  }

  /// Get unique act names in order.
  List<String> get acts {
    final seen = <String>{};
    return lines
        .where((l) => l.act.isNotEmpty && seen.add(l.act))
        .map((l) => l.act)
        .toList();
  }
}
