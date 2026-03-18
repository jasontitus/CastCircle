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
  final double? ocrConfidence; // OCR confidence 0.0–1.0, null for non-OCR imports
  final int? sourcePage; // 1-based page from original PDF
  final int? sourceLineOnPage; // 1-based line within that page

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
    this.ocrConfidence,
    this.sourcePage,
    this.sourceLineOnPage,
  });

  /// Page:line reference string (e.g., "p12:5"). Uses source page if
  /// available, otherwise computes from orderIndex.
  String get pageLineRef {
    if (sourcePage != null && sourceLineOnPage != null) {
      return 'p$sourcePage:$sourceLineOnPage';
    }
    // Fallback: compute from position (42 lines per page convention)
    final page = (orderIndex ~/ 42) + 1;
    final line = (orderIndex % 42) + 1;
    return 'p$page:$line';
  }

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
    double? Function()? ocrConfidence,
    int? Function()? sourcePage,
    int? Function()? sourceLineOnPage,
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
      ocrConfidence: ocrConfidence != null ? ocrConfidence() : this.ocrConfidence,
      sourcePage: sourcePage != null ? sourcePage() : this.sourcePage,
      sourceLineOnPage: sourceLineOnPage != null ? sourceLineOnPage() : this.sourceLineOnPage,
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
        if (ocrConfidence != null) 'ocr_confidence': ocrConfidence,
        if (sourcePage != null) 'source_page': sourcePage,
        if (sourceLineOnPage != null) 'source_line_on_page': sourceLineOnPage,
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
        ocrConfidence: (json['ocr_confidence'] as num?)?.toDouble(),
        sourcePage: json['source_page'] as int?,
        sourceLineOnPage: json['source_line_on_page'] as int?,
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
    if (lines.isEmpty) return [];
    // Clamp indices to valid range to handle stale scene data
    final start = scene.startLineIndex.clamp(0, lines.length - 1);
    final end = (scene.endLineIndex + 1).clamp(start, lines.length);
    if (start >= end) return [];
    return lines.sublist(start, end);
  }

  /// Get all lines in a specific act.
  List<ScriptLine> linesInAct(String act) {
    return lines.where((l) => l.act == act).toList();
  }

  /// Get scenes filtered to those containing a specific character.
  List<ScriptScene> scenesForCharacter(String characterName) {
    return scenes.where((s) => s.characters.contains(characterName)).toList();
  }

  /// Find the line index for a page:line reference.
  /// Searches by sourcePage/sourceLineOnPage first, falls back to computed.
  int? indexForRef(int page, int lineOnPage) {
    // Try exact source page match first
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].sourcePage == page && lines[i].sourceLineOnPage == lineOnPage) {
        return i;
      }
    }
    // Fallback: computed from 42 lines/page
    final idx = (page - 1) * 42 + (lineOnPage - 1);
    if (idx < 0 || idx >= lines.length) return null;
    return idx;
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
