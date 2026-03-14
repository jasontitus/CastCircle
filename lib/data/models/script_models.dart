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

/// Gender assigned to a character, used for voice pool selection.
enum CharacterGender { female, male, nonGendered }

/// A character/role in the production.
class ScriptCharacter {
  final String name;
  final int colorIndex;
  final int lineCount;
  final CharacterGender gender;

  const ScriptCharacter({
    required this.name,
    required this.colorIndex,
    required this.lineCount,
    this.gender = CharacterGender.female,
  });

  ScriptCharacter copyWith({
    String? name,
    int? colorIndex,
    int? lineCount,
    CharacterGender? gender,
  }) {
    return ScriptCharacter(
      name: name ?? this.name,
      colorIndex: colorIndex ?? this.colorIndex,
      lineCount: lineCount ?? this.lineCount,
      gender: gender ?? this.gender,
    );
  }
}

/// A scene within the script — the primary unit for rehearsal.
class ScriptScene {
  final String id;
  final String act;
  final String sceneName;
  final String location; // e.g. "Longbourn", "Netherfield Ball"
  final String description; // summary derived from transition direction
  final int startLineIndex; // index into ParsedScript.lines
  final int endLineIndex; // inclusive
  final List<String> characters; // characters who speak in this scene

  const ScriptScene({
    required this.id,
    required this.act,
    required this.sceneName,
    required this.location,
    required this.description,
    required this.startLineIndex,
    required this.endLineIndex,
    required this.characters,
  });

  /// How many dialogue lines in this scene.
  int get dialogueLineCount => characters.isEmpty ? 0 : endLineIndex - startLineIndex + 1;

  /// Display label for scene picker.
  String get displayLabel {
    if (location.isNotEmpty) return '$sceneName — $location';
    return sceneName;
  }

  ScriptScene copyWith({
    String? id,
    String? act,
    String? sceneName,
    String? location,
    String? description,
    int? startLineIndex,
    int? endLineIndex,
    List<String>? characters,
  }) {
    return ScriptScene(
      id: id ?? this.id,
      act: act ?? this.act,
      sceneName: sceneName ?? this.sceneName,
      location: location ?? this.location,
      description: description ?? this.description,
      startLineIndex: startLineIndex ?? this.startLineIndex,
      endLineIndex: endLineIndex ?? this.endLineIndex,
      characters: characters ?? this.characters,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'act': act,
        'scene_name': sceneName,
        'location': location,
        'description': description,
        'start_line_index': startLineIndex,
        'end_line_index': endLineIndex,
        'characters': characters,
      };

  factory ScriptScene.fromJson(Map<String, dynamic> json) => ScriptScene(
        id: json['id'] as String,
        act: json['act'] as String? ?? '',
        sceneName: json['scene_name'] as String,
        location: json['location'] as String? ?? '',
        description: json['description'] as String? ?? '',
        startLineIndex: json['start_line_index'] as int,
        endLineIndex: json['end_line_index'] as int,
        characters: (json['characters'] as List).cast<String>(),
      );
}

/// A recording of a single script line by a cast member.
class Recording {
  final String id;
  final String scriptLineId;
  final String character;
  final String localPath; // local file path for playback
  final String? remoteUrl; // Supabase storage URL (null if not uploaded yet)
  final int durationMs;
  final DateTime recordedAt;

  const Recording({
    required this.id,
    required this.scriptLineId,
    required this.character,
    required this.localPath,
    this.remoteUrl,
    required this.durationMs,
    required this.recordedAt,
  });

  Recording copyWith({
    String? id,
    String? scriptLineId,
    String? character,
    String? localPath,
    String? remoteUrl,
    int? durationMs,
    DateTime? recordedAt,
  }) {
    return Recording(
      id: id ?? this.id,
      scriptLineId: scriptLineId ?? this.scriptLineId,
      character: character ?? this.character,
      localPath: localPath ?? this.localPath,
      remoteUrl: remoteUrl ?? this.remoteUrl,
      durationMs: durationMs ?? this.durationMs,
      recordedAt: recordedAt ?? this.recordedAt,
    );
  }
}

/// A complete parsed script.
class ParsedScript {
  final String title;
  final List<ScriptLine> lines;
  final List<ScriptCharacter> characters;
  final List<ScriptScene> scenes;
  final String rawText;

  const ParsedScript({
    required this.title,
    required this.lines,
    required this.characters,
    required this.scenes,
    required this.rawText,
  });

  /// Get all lines for a specific character.
  List<ScriptLine> linesForCharacter(String characterName) {
    return lines
        .where((l) =>
            l.lineType == LineType.dialogue && l.character == characterName)
        .toList();
  }

  /// Get lines within a specific scene.
  List<ScriptLine> linesInScene(ScriptScene scene) {
    if (scene.startLineIndex < 0 || scene.endLineIndex >= lines.length) {
      return [];
    }
    return lines.sublist(scene.startLineIndex, scene.endLineIndex + 1);
  }

  /// Get all lines in a specific act.
  List<ScriptLine> linesInAct(String act) {
    return lines.where((l) => l.act == act).toList();
  }

  /// Get scenes filtered to those containing a specific character.
  List<ScriptScene> scenesForCharacter(String characterName) {
    return scenes.where((s) => s.characters.contains(characterName)).toList();
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
