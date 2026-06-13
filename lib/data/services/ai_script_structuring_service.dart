import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../models/script_models.dart';
import 'debug_log_service.dart';
import 'on_device_llm_channel.dart';
import 'script_parser.dart';

const _uuid = Uuid();

/// An on-device LLM provider that turns a prompt (and optional page images)
/// into a raw text completion.
///
/// Implemented by [OnDeviceLlmChannel] (Gemma 4 via MLX on iOS / MediaPipe on
/// Android). Abstracted so tests can inject a mock that returns canned JSON
/// without loading a real model.
abstract class OnDeviceLlmProvider {
  /// Whether a model is loaded and ready. When false, callers should fall
  /// back to the heuristic parser.
  bool get isAvailable;

  /// Run a single completion. [imagePaths] are PNG/JPEG page renders for the
  /// multimodal (vision) path; pass an empty list for text-only structuring.
  /// Returns the model's raw text output, or null on failure.
  Future<String?> generate({
    required String prompt,
    List<String> imagePaths = const [],
  });
}

/// Structures raw script text (or page images) into a [ParsedScript] using an
/// on-device multimodal LLM (Gemma 4 E2B by default).
///
/// This is the "smart" fallback for the import pipeline: the fast heuristic
/// [ScriptParser] runs first, and this pass only fires when that result looks
/// poor (or when the caller explicitly opts in), so clean text-based PDFs stay
/// fast and free.
///
/// Two modes, selected by what the caller passes to [structure]:
///   * text-only — feed already-extracted OCR/PDF text. Lighter; fixes format
///     and structure brittleness but inherits OCR errors.
///   * multimodal — feed rendered page images. Heavier; lets the model do
///     OCR + layout + structure together, addressing the root layout problem.
class AiScriptStructuringService {
  AiScriptStructuringService({OnDeviceLlmProvider? provider})
      : _provider = provider ?? OnDeviceLlmChannel.instance;

  final OnDeviceLlmProvider _provider;

  /// Raw text the model produced on the last [structure] call (for debugging).
  String lastRawOutput = '';

  bool get isAvailable => _provider.isAvailable;

  /// Structure a script. Provide [rawText] for the text path and/or
  /// [pageImagePaths] for the multimodal path (at least one is required).
  /// Returns null if the model is unavailable or the output can't be parsed,
  /// so the caller can fall back to the heuristic result.
  Future<ParsedScript?> structure({
    String? rawText,
    List<String> pageImagePaths = const [],
    required String title,
  }) async {
    final log = DebugLogService.instance;
    if (!_provider.isAvailable) {
      log.logError(LogCategory.ai, 'structure skipped — no on-device runtime');
      return null;
    }
    if ((rawText == null || rawText.trim().isEmpty) && pageImagePaths.isEmpty) {
      log.logError(LogCategory.ai, 'structure skipped — no input text or images');
      return null;
    }

    final prompt = _buildPrompt(rawText: rawText, hasImages: pageImagePaths.isNotEmpty);
    log.log(LogCategory.ai,
        'structuring (textChars=${rawText?.length ?? 0}, promptChars=${prompt.length}, images=${pageImagePaths.length})');

    final String? response;
    try {
      response = await _provider.generate(prompt: prompt, imagePaths: pageImagePaths);
    } catch (e) {
      log.logError(LogCategory.ai, 'generate threw', e);
      return null;
    }
    if (response == null) {
      log.logError(LogCategory.ai, 'model returned no output');
      return null;
    }
    lastRawOutput = response;
    final outPreview =
        response.length > 400 ? '${response.substring(0, 400)}…' : response;
    log.log(LogCategory.ai, 'model output (${response.length} chars): $outPreview');

    final json = _extractJsonObject(response);
    if (json == null) {
      final preview = response.length > 180 ? response.substring(0, 180) : response;
      log.logError(LogCategory.ai,
          'no JSON object in model output (got ${response.length} chars): $preview');
      return null;
    }

    try {
      final script = _toParsedScript(json, title: title);
      final dialogue =
          script.lines.where((l) => l.lineType == LineType.dialogue).length;
      log.log(LogCategory.ai,
          'structured → ${script.characters.length} characters, $dialogue lines');
      return script;
    } catch (e) {
      log.logError(LogCategory.ai, 'failed to convert model JSON', e);
      return null;
    }
  }

  /// Build the structuring instruction. Kept deliberately strict about output
  /// shape — small on-device models follow a tight schema far more reliably
  /// than open-ended prose.
  String _buildPrompt({String? rawText, required bool hasImages}) {
    final source = hasImages
        ? 'the page image(s) of a play script'
        : 'the raw extracted text of a play script below';

    final schema = '''
Return ONLY a JSON object, no prose, with this exact shape:
{
  "title": "<play title or empty string>",
  "lines": [
    { "type": "header",    "act": "ACT I", "scene": "Scene 1" },
    { "type": "dialogue",  "act": "ACT I", "scene": "Scene 1",
      "character": "MACBETH", "text": "So foul and fair a day I have not seen." },
    { "type": "stage",     "text": "Enter BANQUO" },
    { "type": "dialogue",  "character": "MACBETH AND BANQUO",
      "characters": ["MACBETH", "BANQUO"], "text": "Speak, if you can: what are you?" }
  ]
}

Rules:
- "type" is one of: "dialogue", "stage", "header".
- Use UPPERCASE character names. Keep honorifics attached: "MRS. ALVING", not "MRS".
- For lines spoken by multiple characters, set "character" to the combined cue
  and "characters" to the array of individuals.
- Emit a "header" line at each act/scene change. Carry the current "act"/"scene"
  onto every dialogue line.
- "stage" lines are stage directions (entrances, exits, action). No "character".
- Preserve dialogue text verbatim; fix obvious OCR garbling only.
- Do not invent characters or lines that are not present.''';

    final buffer = StringBuffer()
      ..writeln('You are a theatrical script parser. Convert $source into '
          'structured JSON for a rehearsal app.')
      ..writeln()
      ..writeln(schema);

    if (rawText != null && rawText.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('--- SCRIPT TEXT ---')
        ..writeln(rawText.trim());
    }
    return buffer.toString();
  }

  /// Pull the first balanced top-level JSON object out of a model completion.
  /// Tolerates ```json fences and leading/trailing prose.
  static Map<String, dynamic>? _extractJsonObject(String raw) {
    var text = raw.trim();
    // Strip markdown code fences if present.
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```').firstMatch(text);
    if (fence != null) text = fence.group(1)!.trim();

    final start = text.indexOf('{');
    if (start < 0) return null;

    // Walk forward tracking brace depth (ignoring braces inside strings).
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == r'\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) {
          final candidate = text.substring(start, i + 1);
          final decoded = jsonDecode(candidate);
          return decoded is Map<String, dynamic> ? decoded : null;
        }
      }
    }
    return null;
  }

  /// Convert the model's JSON into a [ParsedScript], reusing existing gender
  /// inference and building character/scene aggregates the same way the
  /// heuristic parser does so downstream code is unaffected.
  ParsedScript _toParsedScript(Map<String, dynamic> json, {required String title}) {
    final modelTitle = (json['title'] as String?)?.trim();
    final rawBlocks = (json['lines'] as List?) ?? const [];

    final lines = <ScriptLine>[];
    var currentAct = 'ACT I';
    var currentScene = '';
    var sceneLineNum = 0;
    var orderIndex = 0;

    for (final block in rawBlocks) {
      if (block is! Map) continue;
      final type = (block['type'] as String?)?.toLowerCase().trim() ?? 'dialogue';
      final act = (block['act'] as String?)?.trim();
      final scene = (block['scene'] as String?)?.trim();
      final text = (block['text'] as String?)?.trim() ?? '';

      if (act != null && act.isNotEmpty) currentAct = act;
      if (scene != null && scene.isNotEmpty) currentScene = scene;

      switch (type) {
        case 'header':
          orderIndex++;
          sceneLineNum = 0;
          lines.add(ScriptLine(
            id: _uuid.v4(),
            act: currentAct,
            scene: currentScene,
            lineNumber: 0,
            orderIndex: orderIndex,
            character: '',
            text: text.isNotEmpty ? text : currentAct,
            lineType: LineType.header,
          ));
          break;
        case 'stage':
          if (text.isEmpty) continue;
          orderIndex++;
          sceneLineNum++;
          lines.add(ScriptLine(
            id: _uuid.v4(),
            act: currentAct,
            scene: currentScene,
            lineNumber: sceneLineNum,
            orderIndex: orderIndex,
            character: '',
            text: text,
            lineType: LineType.stageDirection,
          ));
          break;
        default: // dialogue
          final character = (block['character'] as String?)?.trim().toUpperCase() ?? '';
          if (character.isEmpty || text.isEmpty) continue;
          final multi = (block['characters'] as List?)
                  ?.map((c) => c.toString().trim().toUpperCase())
                  .where((c) => c.isNotEmpty)
                  .toList() ??
              const <String>[];
          orderIndex++;
          sceneLineNum++;
          lines.add(ScriptLine(
            id: _uuid.v4(),
            act: currentAct,
            scene: currentScene,
            lineNumber: sceneLineNum,
            orderIndex: orderIndex,
            character: character,
            text: text,
            lineType: LineType.dialogue,
            multiCharacters: multi.length >= 2 ? multi : const [],
          ));
      }
    }

    return ParsedScript(
      title: (modelTitle != null && modelTitle.isNotEmpty) ? modelTitle : title,
      lines: lines,
      characters: _buildCharacters(lines),
      scenes: _buildScenes(lines),
      rawText: '',
    );
  }

  /// Aggregate characters with line counts and inferred gender, crediting each
  /// speaker on multi-character lines (mirrors [ScriptParser]).
  static List<ScriptCharacter> _buildCharacters(List<ScriptLine> lines) {
    final counts = <String, int>{};
    for (final line in lines) {
      if (line.lineType != LineType.dialogue || line.character.isEmpty) continue;
      if (line.multiCharacters.isNotEmpty) {
        for (final c in line.multiCharacters) {
          counts[c] = (counts[c] ?? 0) + 1;
        }
      } else {
        counts[line.character] = (counts[line.character] ?? 0) + 1;
      }
    }

    final characters = <ScriptCharacter>[];
    var colorIdx = 0;
    for (final entry in counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value))) {
      characters.add(ScriptCharacter(
        name: entry.key,
        colorIndex: colorIdx++,
        lineCount: entry.value,
        gender: ScriptParser.inferGender(entry.key),
      ));
    }
    return characters;
  }

  /// Group consecutive lines into scenes on (act, scene) changes.
  static List<ScriptScene> _buildScenes(List<ScriptLine> lines) {
    if (lines.isEmpty) return const [];
    final scenes = <ScriptScene>[];
    var start = 0;
    var key = '${lines.first.act}|${lines.first.scene}';
    var counter = 0;

    void close(int endInclusive) {
      final slice = lines.sublist(start, endInclusive + 1);
      final dialogue = slice.where((l) => l.lineType == LineType.dialogue).toList();
      if (dialogue.isEmpty) {
        start = endInclusive + 1;
        return;
      }
      counter++;
      final chars = <String>{};
      for (final l in dialogue) {
        if (l.multiCharacters.isNotEmpty) {
          chars.addAll(l.multiCharacters);
        } else if (l.character.isNotEmpty) {
          chars.add(l.character);
        }
      }
      scenes.add(ScriptScene(
        id: _uuid.v4(),
        act: slice.first.act,
        sceneName: '${slice.first.act}, Scene $counter',
        location: slice.first.scene,
        description: '',
        startLineIndex: start,
        endLineIndex: endInclusive,
        characters: chars.toList()..sort(),
      ));
      start = endInclusive + 1;
    }

    for (var i = 0; i < lines.length; i++) {
      final k = '${lines[i].act}|${lines[i].scene}';
      if (k != key) {
        if (i > start) close(i - 1);
        key = k;
        // Reset the per-act scene counter at act boundaries.
        if (i > 0 && lines[i].act != lines[i - 1].act) counter = 0;
        start = i;
      }
    }
    if (start < lines.length) close(lines.length - 1);
    return scenes;
  }
}
