import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/ai_script_structuring_service.dart';

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
  });
}
