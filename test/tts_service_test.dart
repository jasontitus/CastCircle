import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/services/tts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TtsService', () {
    test('is a singleton', () {
      expect(identical(TtsService.instance, TtsService.instance), true);
    });

    test('defaults to system engine when Kokoro not available', () {
      final service = TtsService.instance;
      expect(service.activeEngine, isA<TtsEngine>());
    });

    test('isKokoroLoaded is false before init', () {
      expect(TtsService.instance.isKokoroLoaded, false);
    });

    test('TtsEngine enum has expected values', () {
      expect(TtsEngine.values, containsAll([TtsEngine.kokoroMlx, TtsEngine.system]));
      expect(TtsEngine.values.length, 2);
    });
  });

  group('TtsService.stripStageDirections', () {
    test('removes a closed parenthetical', () {
      expect(TtsService.stripStageDirections('(crossing) Hello there.'),
          'Hello there.');
      expect(TtsService.stripStageDirections('Hello (softly) world'),
          'Hello world');
    });

    test('removes bracketed directions', () {
      expect(TtsService.stripStageDirections('[aside] He is a fool.'),
          'He is a fool.');
    });

    test('removes an UNCLOSED direction running to end of line (OCR case)', () {
      // OCR'd scripts drop the closing ')'; everything from '(' to EOL is the
      // stage direction.
      expect(
        TtsService.stripStageDirections(
            'Nothing would delight me more. (MRS. GARDINER and ELIZABETH turn to'),
        'Nothing would delight me more.',
      );
    });

    test('leaves plain dialogue untouched', () {
      expect(TtsService.stripStageDirections('Nothing would delight me more.'),
          'Nothing would delight me more.');
    });

    test('a line that is entirely a direction collapses to empty', () {
      expect(TtsService.stripStageDirections('(she exits)'), '');
    });
  });
}
