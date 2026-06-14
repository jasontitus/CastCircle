import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/ai_script_structuring_service.dart';

/// Points the app-documents directory at a temp folder so the checkpoint
/// persistence (normally backed by the path_provider plugin) is exercisable in
/// a unit test instead of silently no-opping.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.docsPath);
  final String docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

/// A mock on-device LLM that returns a canned completion, so the structuring
/// pipeline can be tested without loading a real Gemma 4 model.
class _MockLlm implements OnDeviceLlmProvider {
  _MockLlm(this._response, {this.available = true});
  final String _response;
  final bool available;
  String? lastPrompt;
  List<String>? lastImagePaths;

  @override
  bool get isAvailable => available;

  @override
  Future<String?> generate({
    required String prompt,
    List<String> imagePaths = const [],
  }) async {
    lastPrompt = prompt;
    lastImagePaths = imagePaths;
    return _response;
  }

  @override
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

/// A mock that returns queued responses in order — one per chunk — so chunked
/// structuring can be exercised with different output per chunk.
class _QueueLlm implements OnDeviceLlmProvider {
  _QueueLlm(this._responses);
  final List<String?> _responses;
  int _i = 0;

  @override
  bool get isAvailable => true;

  @override
  Future<String?> generate({
    required String prompt,
    List<String> imagePaths = const [],
  }) async {
    final r = _i < _responses.length ? _responses[_i] : _responses.last;
    _i++;
    return r;
  }

  @override
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

// Canned model output exercising the cases the heuristic parser fails on:
// an honorific name (MRS. ALVING, not "MRS") and a multi-character line.
const _modelJson = '''
{
  "title": "Ghosts",
  "lines": [
    { "type": "header", "act": "ACT I", "scene": "Scene 1" },
    { "type": "stage", "text": "Enter REGINA" },
    { "type": "dialogue", "act": "ACT I", "scene": "Scene 1",
      "character": "MRS. ALVING", "text": "My dear Oswald, how are you?" },
    { "type": "dialogue", "character": "OSWALD", "text": "Better, mother." },
    { "type": "dialogue", "character": "MRS. ALVING AND OSWALD",
      "characters": ["MRS. ALVING", "OSWALD"], "text": "Together at last." }
  ]
}
''';

// Garbled act/scene labels as the on-device model actually emits them across
// independently-structured chunks: "A", "ACTI", "1" (all really ACT I) and
// "ACT II"/"2" for ACT II. The service should canonicalize these.
const _garbledActsJson = '''
{
  "title": "Pride and Prejudice",
  "lines": [
    { "type": "header", "act": "A", "scene": "" },
    { "type": "dialogue", "act": "ACTI", "scene": "1",
      "character": "MRS. BENNET", "text": "Netherfield is let at last." },
    { "type": "dialogue", "act": "1", "scene": "1",
      "character": "MR. BENNET", "text": "Is it?" },
    { "type": "header", "act": "ACT II", "scene": "Scene 2" },
    { "type": "dialogue", "act": "2",
      "character": "LYDIA", "text": "Officers!" }
  ]
}
''';

void main() {
  group('AiScriptStructuringService', () {
    test('converts model JSON into a ParsedScript', () async {
      final svc = AiScriptStructuringService(provider: _MockLlm(_modelJson));
      final script = await svc.structure(rawText: 'irrelevant', title: 'fallback');

      expect(script, isNotNull);
      expect(script!.title, 'Ghosts');

      // Dialogue lines: 3 (two MRS. ALVING credits via the multi line + OSWALD).
      final dialogue =
          script.lines.where((l) => l.lineType == LineType.dialogue).toList();
      expect(dialogue.length, 3);

      // Stage direction and header preserved.
      expect(script.lines.any((l) => l.lineType == LineType.stageDirection), isTrue);
      expect(script.lines.any((l) => l.lineType == LineType.header), isTrue);
    });

    test('preserves honorific names instead of truncating to "MRS"', () async {
      final svc = AiScriptStructuringService(provider: _MockLlm(_modelJson));
      final script = (await svc.structure(rawText: 'x', title: 't'))!;

      final names = script.characters.map((c) => c.name).toSet();
      expect(names, contains('MRS. ALVING'));
      expect(names, isNot(contains('MRS')));
      // Honorific drives correct gender inference.
      final mrsAlving =
          script.characters.firstWhere((c) => c.name == 'MRS. ALVING');
      expect(mrsAlving.gender, CharacterGender.female);
    });

    test('splits multi-character lines and credits each speaker', () async {
      final svc = AiScriptStructuringService(provider: _MockLlm(_modelJson));
      final script = (await svc.structure(rawText: 'x', title: 't'))!;

      final multi = script.lines.firstWhere((l) => l.multiCharacters.isNotEmpty);
      expect(multi.multiCharacters, ['MRS. ALVING', 'OSWALD']);

      // MRS. ALVING speaks one solo line + one shared line = 2 credited lines.
      final mrsAlving =
          script.characters.firstWhere((c) => c.name == 'MRS. ALVING');
      expect(mrsAlving.lineCount, 2);
      // isForCharacter should find the shared line for both speakers.
      expect(multi.isForCharacter('OSWALD'), isTrue);
      expect(multi.isForCharacter('MRS. ALVING'), isTrue);
    });

    test('groups lines into a scene', () async {
      final svc = AiScriptStructuringService(provider: _MockLlm(_modelJson));
      final script = (await svc.structure(rawText: 'x', title: 't'))!;
      expect(script.scenes, hasLength(1));
      expect(script.scenes.first.characters, contains('OSWALD'));
      expect(script.scenes.first.characters, contains('MRS. ALVING'));
    });

    test('tolerates code fences and surrounding prose', () async {
      final wrapped = 'Here is the JSON you asked for:\n```json\n$_modelJson\n```\nDone!';
      final svc = AiScriptStructuringService(provider: _MockLlm(wrapped));
      final script = await svc.structure(rawText: 'x', title: 't');
      expect(script, isNotNull);
      expect(script!.title, 'Ghosts');
    });

    test('passes page image paths through for the multimodal path', () async {
      final mock = _MockLlm(_modelJson);
      final svc = AiScriptStructuringService(provider: mock);
      await svc.structure(pageImagePaths: const ['/tmp/page1.png'], title: 't');
      expect(mock.lastImagePaths, ['/tmp/page1.png']);
    });

    test('returns null when no model is available (heuristic fallback)', () async {
      final svc = AiScriptStructuringService(
          provider: _MockLlm(_modelJson, available: false));
      final script = await svc.structure(rawText: 'x', title: 't');
      expect(script, isNull);
    });

    test('returns null on unparseable model output', () async {
      final svc = AiScriptStructuringService(
          provider: _MockLlm('Sorry, I could not read that script.'));
      final script = await svc.structure(rawText: 'x', title: 't');
      expect(script, isNull);
    });

    test('carries act/scene across chunks when a later chunk omits the act',
        () async {
      // Chunk 1 establishes ACT II; chunk 2 has no act marker and must inherit
      // it instead of resetting to ACT I.
      const chunk1 =
          '{"title":"P","lines":[{"type":"header","act":"ACT II","scene":"Scene 3"},'
          '{"type":"dialogue","act":"ACT II","character":"DARCY","text":"Indeed."}]}';
      const chunk2 =
          '{"title":"P","lines":[{"type":"dialogue","character":"ELIZABETH","text":"Truly."}]}';
      final svc = AiScriptStructuringService(provider: _QueueLlm([chunk1, chunk2]));
      final script = await svc.structureChunked(
          rawText: 'line-a\nline-b', title: 't', linesPerChunk: 1, batchSize: 1);

      final eliza = script!.lines.firstWhere((l) => l.character == 'ELIZABETH');
      expect(eliza.act, 'ACT II'); // inherited from chunk 1
      expect(eliza.scene, 'Scene 3');
    });

    test('aborts (returns null) when a whole group fails to decode', () async {
      // Every chunk returns null = the decoder/GPU wedged; structureChunked must
      // abort and return null rather than present a partial script as complete.
      final svc = AiScriptStructuringService(provider: _QueueLlm([null, null]));
      final script = await svc.structureChunked(
          rawText: 'line-a\nline-b', title: 't', linesPerChunk: 1, batchSize: 1);
      expect(script, isNull);
    });

    test('canonicalizes garbled act/scene labels', () async {
      final svc = AiScriptStructuringService(provider: _MockLlm(_garbledActsJson));
      final script = (await svc.structure(rawText: 'x', title: 't'))!;

      final acts = script.lines.map((l) => l.act).toSet();
      // "A"/"ACTI"/"1" all collapse to "ACT I"; "ACT II"/"2" to "ACT II".
      expect(acts, contains('ACT I'));
      expect(acts, contains('ACT II'));
      // No raw/garbled forms survive.
      expect(acts.any((a) => a == 'ACTI' || a == '1' || a == 'A' || a == '2'),
          isFalse);

      // The "A" header didn't overwrite the default act with noise.
      final bennet = script.lines.firstWhere((l) => l.character == 'MRS. BENNET');
      expect(bennet.act, 'ACT I');
      // A real ordinal scene is canonicalized.
      expect(bennet.scene, 'Scene 1');
      final lydia = script.lines.firstWhere((l) => l.character == 'LYDIA');
      expect(lydia.act, 'ACT II');
    });
  });

  // The cleanup checkpoint persists progress so a killed run can resume — but
  // it must never trap the user in a relaunch loop. A cancelled or
  // permanently-failing checkpoint has to clear itself so the import screen's
  // auto-resume can't restart it forever (the bug these tests pin down).
  group('checkpoint resume budget', () {
    late Directory tempDir;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      tempDir = await Directory.systemTemp.createTemp('ai_ckpt_test');
      PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    });

    tearDown(() async {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    File ckptFile() => File('${tempDir.path}/ai_cleanup_checkpoint.json');

    const validJson =
        '{"title":"P","lines":[{"type":"dialogue","character":"DARCY","text":"Indeed."}]}';

    test('a failing checkpoint is discarded after maxResumeAttempts so it '
        'cannot relaunch the cleanup forever', () async {
      // First run (fresh): every chunk fails → keep the checkpoint, one attempt
      // spent (a wedged GPU might recover in a fresh process).
      final r1 = await AiScriptStructuringService(provider: _QueueLlm([null, null]))
          .structureChunked(
              rawText: 'a\nb', title: 't', linesPerChunk: 1, batchSize: 1);
      expect(r1, isNull);
      expect(ckptFile().existsSync(), isTrue);
      expect(await AiScriptStructuringService().checkpointAttempts(), 1);

      // Second run (resume): fails again → budget spent → checkpoint discarded.
      final r2 = await AiScriptStructuringService(provider: _QueueLlm([null, null]))
          .structureChunked(
              rawText: 'a\nb', title: 't', linesPerChunk: 1, batchSize: 1);
      expect(r2, isNull);
      expect(ckptFile().existsSync(), isFalse,
          reason: 'a spent checkpoint must be gone so resume stops relaunching');
    });

    test('an explicit cancel discards the checkpoint (stop, not pause)',
        () async {
      // 4 chunks → 2 groups. Cancel after the first group: its checkpoint must
      // be cleared, not kept for a resume on the next import-screen visit.
      var checks = 0;
      await AiScriptStructuringService(
              provider: _QueueLlm([validJson, validJson, validJson, validJson]))
          .structureChunked(
        rawText: 'a\nb\nc\nd',
        title: 't',
        linesPerChunk: 1,
        batchSize: 1,
        isCancelled: () => checks++ >= 1, // false at group 1, true at group 2
      );
      expect(ckptFile().existsSync(), isFalse,
          reason: 'cancel must clear the checkpoint');
    });

    test('a model-less resume discards the checkpoint instead of looping '
        '(the deleted-model case)', () async {
      // Seed a checkpoint with one spent attempt while a runtime is present.
      await AiScriptStructuringService(provider: _QueueLlm([null, null]))
          .structureChunked(
              rawText: 'a\nb', title: 't', linesPerChunk: 1, batchSize: 1);
      expect(await AiScriptStructuringService().checkpointAttempts(), 1);

      // Now the model is gone (user deleted it). The resume can't run — it must
      // spend the last attempt and discard, not relaunch forever.
      final r = await AiScriptStructuringService(
              provider: _MockLlm('', available: false))
          .structureChunked(
              rawText: 'a\nb', title: 't', linesPerChunk: 1, batchSize: 1);
      expect(r, isNull);
      expect(ckptFile().existsSync(), isFalse,
          reason: 'a model-less resume must not loop the cleanup forever');
    });

    test('forward progress resets the failure budget', () async {
      // Group 1 succeeds, group 2 fails: because real progress was made, the
      // surviving checkpoint keeps a full retry budget (attempts back to 1, not
      // accumulating), so a transient wedge late in a long script still recovers.
      var checks = 0;
      await AiScriptStructuringService(
              provider: _QueueLlm([validJson, validJson, null, null]))
          .structureChunked(
        rawText: 'a\nb\nc\nd',
        title: 't',
        linesPerChunk: 1,
        batchSize: 1,
        isCancelled: () => false,
      );
      expect(ckptFile().existsSync(), isTrue);
      expect(await AiScriptStructuringService().checkpointAttempts(), 1);
    });
  });
}
