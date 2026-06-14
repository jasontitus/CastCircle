import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
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

  /// Decode [prompts] with up to [slots] sequences in flight at once, returning
  /// one output per prompt (in order; null on a per-prompt failure). On-device
  /// generation is memory-bandwidth-bound, so decoding N sequences together is
  /// ~N× faster than one at a time; a real implementation keeps [slots] slots
  /// full and refills one the instant its chunk finishes (continuous batching),
  /// so [prompts] may exceed [slots]. [onChunkDone] reports absolute progress
  /// (chunks finished so far, total) as it goes — [baseDone] is the chunk offset
  /// of this group within the whole job and [totalChunks] the job-wide total.
  /// Default is sequential — override for true batched decoding.
  Future<List<String?>> generateBatch(
    List<String> prompts, {
    int? slots,
    void Function(int done, int total)? onChunkDone,
    int baseDone = 0,
    int? totalChunks,
  }) async {
    final total = totalChunks ?? prompts.length;
    final out = <String?>[];
    for (var i = 0; i < prompts.length; i++) {
      out.add(await generate(prompt: prompts[i]));
      onChunkDone?.call(baseDone + i + 1, total);
    }
    return out;
  }
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
    return _parseResponse(response, title);
  }

  /// Parse a model's raw completion into a [ParsedScript], logging diagnostics.
  /// Shared by the single-shot [structure] and the batched [structureChunked].
  /// [startAct]/[startScene] seed act/scene continuity from the previous chunk.
  ParsedScript? _parseResponse(String response, String title,
      {String startAct = 'ACT I', String startScene = ''}) {
    final log = DebugLogService.instance;
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
      final script = _toParsedScript(json,
          title: title, startAct: startAct, startScene: startScene);
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

  /// Structure a long script by splitting it into line windows, running each
  /// through the model, and stitching the results. On-device models can't take
  /// a whole script in one prompt (the full P&P script is ~140k chars — far
  /// over the context window), so real imports must be chunked.
  ///
  /// [onProgress] reports (done, total) chunks; [isCancelled] lets the caller
  /// stop early. [batchSize] chunks are decoded in parallel per model call
  /// (on-device generation is memory-bandwidth-bound, so this is ~Nx faster).
  Future<ParsedScript?> structureChunked({
    required String rawText,
    required String title,
    int linesPerChunk = 60,
    int batchSize = 4,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final log = DebugLogService.instance;
    if (!_provider.isAvailable) {
      log.logError(LogCategory.ai, 'chunked structure skipped — no runtime');
      return null;
    }

    final srcLines = rawText.split('\n');
    final chunks = <String>[];
    for (var i = 0; i < srcLines.length; i += linesPerChunk) {
      final end =
          i + linesPerChunk < srcLines.length ? i + linesPerChunk : srcLines.length;
      final chunk = srcLines.sublist(i, end).join('\n').trim();
      if (chunk.isNotEmpty) chunks.add(chunk);
    }

    // Resume from a checkpoint if one exists for this exact script — a
    // multi-minute run that was backgrounded/killed picks up where it stopped
    // instead of restarting from chunk 1.
    final key = _checkpointKey(title, rawText, linesPerChunk, chunks.length);
    final merged = <ScriptLine>[];
    var startChunk = 0;
    final ckpt = await _loadCheckpoint(key);
    if (ckpt != null) {
      merged.addAll(ckpt.lines);
      startChunk = ckpt.nextChunk;
      log.log(LogCategory.ai,
          'resuming cleanup from checkpoint: chunk ${startChunk + 1}/${chunks.length}, ${merged.length} lines so far');
    }
    final slots = batchSize < 1 ? 1 : batchSize;
    // Hand the native decoder more chunks than it has slots so it can refill a
    // slot the instant one finishes (continuous batching), overlapping the next
    // chunk with the current group's stragglers instead of idling. Kept at 2×
    // slots so cancellation and checkpointing still happen every ~group, not
    // only at the very end of the job.
    final groupSize = slots * 2;
    log.log(LogCategory.ai,
        'chunked structuring: ${chunks.length} chunks (~$linesPerChunk lines each), slots=$slots, group=$groupSize, starting at ${startChunk + 1}');

    // Seed the denominator (and current position) before any chunk completes;
    // per-chunk updates then arrive via onChunkDone from the native decoder.
    onProgress?.call(startChunk, chunks.length);

    // Track the running act/scene so a chunk lacking its own act marker inherits
    // the prior chunk's — across batches and across a resume (seeded from the
    // last checkpointed line).
    var runningAct = merged.isNotEmpty ? merged.last.act : 'ACT I';
    var runningScene = merged.isNotEmpty ? merged.last.scene : '';

    var cancelled = false;
    for (var b = startChunk; b < chunks.length; b += groupSize) {
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        log.log(LogCategory.ai,
            'chunked structuring cancelled at ${b + 1}/${chunks.length} — checkpoint kept for resume');
        break;
      }
      final end = (b + groupSize < chunks.length) ? b + groupSize : chunks.length;
      // Build this group's prompts; the decoder runs `slots` of them at a time.
      final prompts = [
        for (var i = b; i < end; i++) _buildPrompt(rawText: chunks[i], hasImages: false)
      ];
      final outputs = await _provider.generateBatch(
        prompts,
        slots: slots,
        baseDone: b,
        totalChunks: chunks.length,
        onChunkDone: (done, total) => onProgress?.call(done, total),
      );
      for (final out in outputs) {
        if (out == null) continue;
        final parsed = _parseResponse(out, title,
            startAct: runningAct, startScene: runningScene);
        if (parsed != null && parsed.lines.isNotEmpty) {
          merged.addAll(parsed.lines);
          // Carry this chunk's ending act/scene into the next chunk.
          runningAct = parsed.lines.last.act;
          runningScene = parsed.lines.last.scene;
        }
      }
      // Checkpoint after each group so progress survives a kill. The source
      // text + title are stored too, so a resume works even after the app was
      // killed and the in-memory import preview is gone.
      await _saveCheckpoint(key, end, merged, rawText, title);
      onProgress?.call(end, chunks.length);
    }

    // Keep the checkpoint on cancel (for resume); clear it once the run
    // finishes so a later, different cleanup starts clean.
    if (!cancelled) await _deleteCheckpoint();

    if (merged.isEmpty) return null;

    // Renumber order across chunks and rebuild character/scene aggregates.
    var order = 0;
    final lines = merged.map((l) => l.copyWith(orderIndex: ++order)).toList();
    return ParsedScript(
      title: title,
      lines: lines,
      characters: _buildCharacters(lines),
      scenes: _buildScenes(lines),
      rawText: '',
    );
  }

  // ── Checkpoint persistence (resume a long chunked run after a kill) ──────

  /// Stable content signature (FNV-1a) so a resumed run matches the exact
  /// script + chunking it was started with. Deterministic across app restarts
  /// (unlike String.hashCode).
  static String _checkpointKey(
      String title, String rawText, int linesPerChunk, int chunkCount) {
    const fnvPrime = 0x01000193;
    var hash = 0x811c9dc5;
    final s = '$title $linesPerChunk ${rawText.length} $rawText';
    for (var i = 0; i < s.length; i++) {
      hash ^= s.codeUnitAt(i) & 0xff;
      hash = (hash * fnvPrime) & 0xffffffff;
    }
    return '${hash.toRadixString(16)}_$chunkCount';
  }

  Future<File> _checkpointFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/ai_cleanup_checkpoint.json');
  }

  Future<({int nextChunk, List<ScriptLine> lines})?> _loadCheckpoint(
      String key) async {
    try {
      final file = await _checkpointFile();
      if (!file.existsSync()) return null;
      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (data['key'] != key) return null; // different script — ignore
      final lines = (data['lines'] as List)
          .map((j) => ScriptLine.fromJson(j as Map<String, dynamic>))
          .toList();
      return (nextChunk: data['nextChunk'] as int, lines: lines);
    } catch (e) {
      DebugLogService.instance
          .logError(LogCategory.ai, 'checkpoint load failed', e);
      return null;
    }
  }

  /// Source text + title of an in-progress cleanup, for resuming after a kill.
  /// Null when there's no checkpoint.
  Future<({String rawText, String title})?> loadCheckpointMeta() async {
    try {
      final file = await _checkpointFile();
      if (!file.existsSync()) return null;
      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final raw = data['rawText'] as String?;
      if (raw == null || raw.isEmpty) return null;
      return (rawText: raw, title: (data['title'] as String?) ?? 'Script');
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveCheckpoint(String key, int nextChunk, List<ScriptLine> lines,
      String rawText, String title) async {
    try {
      final file = await _checkpointFile();
      final payload = jsonEncode({
        'key': key,
        'nextChunk': nextChunk,
        'rawText': rawText,
        'title': title,
        'lines': lines.map((l) => l.toJson()).toList(),
      });
      // Atomic write: a kill mid-write can't corrupt the live checkpoint.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(payload, flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      DebugLogService.instance
          .logError(LogCategory.ai, 'checkpoint save failed', e);
    }
  }

  Future<void> _deleteCheckpoint() async {
    try {
      final file = await _checkpointFile();
      if (file.existsSync()) await file.delete();
    } catch (_) {/* best effort */}
  }

  /// Build the structuring instruction. Kept deliberately strict about output
  /// shape — small on-device models follow a tight schema far more reliably
  /// than open-ended prose.
  String _buildPrompt({String? rawText, required bool hasImages}) {
    final source = hasImages
        ? 'the page image(s) of a play script'
        : 'the raw extracted text of a play script below';

    // NOTE: the angle-bracket values below are FIELD DESCRIPTIONS, not sample
    // content. Earlier versions used realistic examples ("MACBETH" / "So foul
    // and fair a day…") and small models copied them verbatim into the output
    // whenever a chunk was sparse. Placeholders + an explicit "never copy these"
    // rule + an empty-result escape hatch stop the echoing.
    final schema = '''
Return ONLY a JSON object, no prose. The angle-bracket values below describe
each field — never copy them; fill every field using ONLY the SCRIPT TEXT.
{
  "title": "<the play's title, or an empty string>",
  "lines": [
    { "type": "header",   "act": "<act label>", "scene": "<scene label>" },
    { "type": "dialogue", "act": "<act label>", "scene": "<scene label>",
      "character": "<SPEAKER NAME>", "text": "<the exact words this speaker says>" },
    { "type": "stage",    "text": "<a stage direction>" }
  ]
}

Rules:
- Use ONLY names and words found in the SCRIPT TEXT below. Never output the
  placeholder words above, and never invent characters or lines.
- If the SCRIPT TEXT contains no dialogue, return exactly {"title":"","lines":[]}.
- "type" is one of: "dialogue", "stage", "header".
- Use UPPERCASE character names. Keep honorifics attached: "MRS. ALVING", not "MRS".
- For a line spoken by multiple characters, set "character" to the combined cue
  and add "characters": ["NAME1","NAME2"].
- Emit a "header" line at each act/scene change. Carry the current "act"/"scene"
  onto every following dialogue line.
- Label acts as "ACT I", "ACT II" (Roman numerals) and scenes as "Scene 1",
  "Scene 2". If this excerpt has no clear act/scene marking, leave them "".
- "stage" lines are stage directions (entrances, exits, action), with no character.
- Preserve dialogue text verbatim; fix only obvious OCR garbling.''';

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
  /// Tolerates ```json fences and leading/trailing prose. If the object is
  /// truncated (small models cap output mid-array), salvages the complete
  /// `lines[]` elements rather than discarding the whole chunk.
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
          final decoded = _decodeObject(candidate);
          if (decoded != null) return decoded;
          return _salvageTruncatedObject(text, start);
        }
      }
    }
    // Never balanced → truncated output. Salvage what completed.
    return _salvageTruncatedObject(text, start);
  }

  /// Recover a usable object from output that was cut off before its closing
  /// braces. Pulls the `"lines": [` array and keeps every fully-formed `{…}`
  /// element, dropping the half-written final one, then re-closes the object.
  static Map<String, dynamic>? _salvageTruncatedObject(String text, int start) {
    final linesKey = text.indexOf('"lines"', start);
    if (linesKey < 0) return null;
    final arrStart = text.indexOf('[', linesKey);
    if (arrStart < 0) return null;

    // Collect complete top-level objects within the lines array.
    final elements = <String>[];
    var depth = 0;
    var elemStart = -1;
    var inString = false;
    var escaped = false;
    for (var i = arrStart + 1; i < text.length; i++) {
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
        if (depth == 0) elemStart = i;
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0 && elemStart >= 0) {
          elements.add(text.substring(elemStart, i + 1));
          elemStart = -1;
        }
      } else if (ch == ']' && depth == 0) {
        break; // array closed cleanly
      }
    }
    if (elements.isEmpty) return null;

    final titleMatch =
        RegExp(r'"title"\s*:\s*"((?:[^"\\]|\\.)*)"').firstMatch(text);
    final title = titleMatch?.group(1) ?? '';
    final rebuilt = '{"title":"$title","lines":[${elements.join(',')}]}';
    return _decodeObject(rebuilt);
  }

  /// Decode a JSON object string, tolerating raw control characters that small
  /// models sometimes emit *inside* string values (literal newlines/tabs),
  /// which strict [jsonDecode] rejects. Returns null if it still can't parse.
  static Map<String, dynamic>? _decodeObject(String candidate) {
    for (final s in [candidate, _escapeControlCharsInStrings(candidate)]) {
      try {
        final decoded = jsonDecode(s);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {
        // Try the next (sanitized) form.
      }
    }
    return null;
  }

  /// Escape raw control characters that appear inside JSON string literals so a
  /// strict decoder accepts them. Structure and already-escaped sequences are
  /// left untouched.
  static String _escapeControlCharsInStrings(String s) {
    final out = StringBuffer();
    var inString = false;
    var escaped = false;
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (inString) {
        if (escaped) {
          out.write(ch);
          escaped = false;
          continue;
        }
        if (ch == r'\') {
          out.write(ch);
          escaped = true;
          continue;
        }
        if (ch == '"') {
          out.write(ch);
          inString = false;
          continue;
        }
        final code = ch.codeUnitAt(0);
        if (ch == '\n') {
          out.write(r'\n');
        } else if (ch == '\r') {
          out.write(r'\r');
        } else if (ch == '\t') {
          out.write(r'\t');
        } else if (code < 0x20) {
          out.write('\\u${code.toRadixString(16).padLeft(4, '0')}');
        } else {
          out.write(ch);
        }
        continue;
      }
      out.write(ch);
      if (ch == '"') inString = true;
    }
    return out.toString();
  }

  /// Canonicalize a model act label into "ACT &lt;ROMAN&gt;" ("ACTI", "act 1",
  /// "1", "Act One" → "ACT I"). Returns null when no act number is recognizable
  /// (e.g. "A", "", front-matter noise) so the caller keeps the current act.
  static String? _normalizeAct(String? raw) {
    final n = _ordinalValue(raw, keyword: 'ACT');
    return n == null ? null : 'ACT ${_intToRoman(n)}';
  }

  /// Canonicalize a scene label: a bare number / roman / "Scene N" becomes
  /// "Scene N"; a descriptive location ("A drawing room") is kept verbatim; an
  /// empty value returns null so the current scene carries forward.
  static String? _normalizeScene(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.isEmpty) return null;
    final n = _ordinalValue(s, keyword: 'SCENE');
    return n == null ? s : 'Scene $n';
  }

  /// Pull an ordinal (1-based) out of an act/scene label, but only when the
  /// label is *essentially just* an optional keyword + an ordinal token (Arabic
  /// "2", Roman "II", or word "two"). Returns null for descriptive labels
  /// ("A drawing room") and unrecognizable noise so callers don't mangle them.
  static int? _ordinalValue(String? raw, {required String keyword}) {
    if (raw == null) return null;
    var s = raw.trim().toUpperCase();
    if (s.isEmpty) return null;
    // Strip a leading keyword (ACT/SCENE), whether glued ("ACTII") or spaced
    // ("ACT II"), with any trailing separators.
    s = s.replaceFirst(RegExp('^${keyword}S?[\\s.:#)-]*'), '').trim();
    if (s.isEmpty) return null;
    if (RegExp(r'^\d{1,3}$').hasMatch(s)) return int.tryParse(s);
    const words = {
      'ONE': 1, 'TWO': 2, 'THREE': 3, 'FOUR': 4, 'FIVE': 5,
      'SIX': 6, 'SEVEN': 7, 'EIGHT': 8, 'NINE': 9, 'TEN': 10,
    };
    if (words.containsKey(s)) return words[s];
    return _romanToInt(s);
  }

  /// Strict Roman-numeral parse, capped at 50 (acts/scenes never exceed that),
  /// validated by round-trip so malformed forms ("IIII") and incidental
  /// letter pairs ("DI") are rejected rather than turned into huge numbers.
  static int? _romanToInt(String s) {
    if (s.isEmpty) return null;
    const vals = {'I': 1, 'V': 5, 'X': 10, 'L': 50, 'C': 100, 'D': 500, 'M': 1000};
    var total = 0;
    var prev = 0;
    for (var i = s.length - 1; i >= 0; i--) {
      final v = vals[s[i]];
      if (v == null) return null; // contains a non-Roman character
      if (v < prev) {
        total -= v;
      } else {
        total += v;
        prev = v;
      }
    }
    if (total < 1 || total > 50) return null;
    return _intToRoman(total) == s ? total : null;
  }

  /// Integer → Roman numeral for 1–50 (enough for any act/scene number).
  static String _intToRoman(int n) {
    const table = [
      [50, 'L'], [40, 'XL'], [10, 'X'], [9, 'IX'],
      [5, 'V'], [4, 'IV'], [1, 'I'],
    ];
    var v = n;
    final sb = StringBuffer();
    for (final entry in table) {
      final value = entry[0] as int;
      final symbol = entry[1] as String;
      while (v >= value) {
        sb.write(symbol);
        v -= value;
      }
    }
    return sb.toString();
  }

  /// Convert the model's JSON into a [ParsedScript], reusing existing gender
  /// inference and building character/scene aggregates the same way the
  /// heuristic parser does so downstream code is unaffected.
  ParsedScript _toParsedScript(Map<String, dynamic> json,
      {required String title,
      String startAct = 'ACT I',
      String startScene = ''}) {
    final modelTitle = (json['title'] as String?)?.trim();
    final rawBlocks = (json['lines'] as List?) ?? const [];

    final lines = <ScriptLine>[];
    // Seed from the prior chunk's ending act/scene so a chunk that contains no
    // act marker (common deep inside an act) inherits the right one instead of
    // defaulting back to ACT I.
    var currentAct = startAct;
    var currentScene = startScene;
    var sceneLineNum = 0;
    var orderIndex = 0;

    for (final block in rawBlocks) {
      if (block is! Map) continue;
      final type = (block['type'] as String?)?.toLowerCase().trim() ?? 'dialogue';
      // The model labels acts/scenes inconsistently across independently-
      // structured chunks ("ACTI", "1", "A" for what is all ACT I), which both
      // looks wrong and fragments scene grouping (scenes break on every act|scene
      // key change). Canonicalize to "ACT I"/"Scene 1"; an unrecognizable label
      // (e.g. "A", "") returns null so the current act/scene carries forward
      // instead of being overwritten with noise.
      final act = _normalizeAct(block['act'] as String?);
      final scene = _normalizeScene(block['scene'] as String?);
      final text = (block['text'] as String?)?.trim() ?? '';

      if (act != null) currentAct = act;
      if (scene != null) currentScene = scene;

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
