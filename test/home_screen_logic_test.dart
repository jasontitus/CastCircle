import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/features/home/home_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldReuseLoadedScript', () {
    const populatedScript = ParsedScript(
      title: 'Test',
      lines: [
        ScriptLine(
          id: 'line-1',
          act: 'ACT I',
          scene: 'Scene 1',
          lineNumber: 1,
          orderIndex: 1,
          character: 'DARCY',
          text: 'Indeed',
          lineType: LineType.dialogue,
        ),
      ],
      characters: [],
      scenes: [],
      rawText: '',
    );

    test('returns true only for the same production with a loaded script', () {
      expect(
        shouldReuseLoadedScript(
          currentProductionId: 'prod-1',
          targetProductionId: 'prod-1',
          currentScript: populatedScript,
        ),
        isTrue,
      );
    });

    test('returns false when switching productions', () {
      expect(
        shouldReuseLoadedScript(
          currentProductionId: 'prod-1',
          targetProductionId: 'prod-2',
          currentScript: populatedScript,
        ),
        isFalse,
      );
    });

    test('returns false when no script is loaded', () {
      expect(
        shouldReuseLoadedScript(
          currentProductionId: 'prod-1',
          targetProductionId: 'prod-1',
          currentScript: null,
        ),
        isFalse,
      );
    });

    test('returns false when current script is empty', () {
      const emptyScript = ParsedScript(
        title: 'Empty',
        lines: [],
        characters: [],
        scenes: [],
        rawText: '',
      );

      expect(
        shouldReuseLoadedScript(
          currentProductionId: 'prod-1',
          targetProductionId: 'prod-1',
          currentScript: emptyScript,
        ),
        isFalse,
      );
    });
  });
}
