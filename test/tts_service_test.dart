import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:castcircle/data/services/tts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TtsService', () {
    test('is a singleton', () {
      expect(identical(TtsService.instance, TtsService.instance), true);
    });

    test('defaults to system engine when Kokoro is unavailable', () async {
      const kokoroChannel = MethodChannel('com.lineguide/kokoro_mlx');
      const flutterTtsChannel = MethodChannel('flutter_tts');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

      messenger.setMockMethodCallHandler(kokoroChannel, (call) async {
        if (call.method == 'getModelStatus') {
          return <String, dynamic>{'downloaded': false, 'loaded': false};
        }
        if (call.method == 'loadModel') return false;
        return null;
      });
      messenger.setMockMethodCallHandler(flutterTtsChannel, (call) async {
        if (call.method == 'getVoices') return <dynamic>[];
        return true;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(kokoroChannel, null);
        messenger.setMockMethodCallHandler(flutterTtsChannel, null);
      });

      final service = TtsService.instance;
      await service.init();

      expect(service.isKokoroLoaded, isFalse);
      expect(service.activeEngine, TtsEngine.system);
    });

    test('TtsEngine enum has expected values', () {
      expect(
        TtsEngine.values,
        containsAll([
          TtsEngine.kokoroMlx,
          TtsEngine.kokoroOnnx,
          TtsEngine.system,
        ]),
      );
      expect(TtsEngine.values.length, 3);
    });
  });

  group('TtsService.expandAbbreviations', () {
    test('expands the title abbreviations that pepper period scripts', () {
      expect(
        TtsService.expandAbbreviations(
          'Mr. Darcy and Mrs. Bennet met Dr. Long',
        ),
        'Mister Darcy and Missus Bennet met Doctor Long',
      );
    });

    test('removes the false sentence boundary inside a line', () {
      // The period after "Mr" must be GONE so neither our splitter nor
      // Kokoro's internal one pauses after it.
      final out = TtsService.expandAbbreviations(
        'Your Mr. Darcy is so high and conceited.',
      );
      expect(out.contains('Mr.'), false);
      expect(out, 'Your Mister Darcy is so high and conceited.');
    });

    test('leaves ordinary words containing the letters alone', () {
      expect(
        TtsService.expandAbbreviations('Milk St is a street'),
        'Milk St is a street',
      ); // no period → untouched
      expect(
        TtsService.expandAbbreviations('The mist rolled in.'),
        'The mist rolled in.',
      );
      expect(
        TtsService.expandAbbreviations('He grimaced. Mrs. Hill smiled.'),
        'He grimaced. Missus Hill smiled.',
      );
    });

    test('does not touch lowercase or sentence-final ordinary periods', () {
      expect(
        TtsService.expandAbbreviations('I will visit the dr. tomorrow'),
        'I will visit the dr. tomorrow',
      ); // lowercase → left alone
    });
  });

  group('TtsService.stripStageDirections', () {
    test('removes a closed parenthetical', () {
      expect(
        TtsService.stripStageDirections('(crossing) Hello there.'),
        'Hello there.',
      );
      expect(
        TtsService.stripStageDirections('Hello (softly) world'),
        'Hello world',
      );
    });

    test('removes bracketed directions', () {
      expect(
        TtsService.stripStageDirections('[aside] He is a fool.'),
        'He is a fool.',
      );
    });

    test('removes an UNCLOSED direction running to end of line (OCR case)', () {
      // OCR'd scripts drop the closing ')'; everything from '(' to EOL is the
      // stage direction.
      expect(
        TtsService.stripStageDirections(
          'Nothing would delight me more. (MRS. GARDINER and ELIZABETH turn to',
        ),
        'Nothing would delight me more.',
      );
    });

    test('leaves plain dialogue untouched', () {
      expect(
        TtsService.stripStageDirections('Nothing would delight me more.'),
        'Nothing would delight me more.',
      );
    });

    test('a line that is entirely a direction collapses to empty', () {
      expect(TtsService.stripStageDirections('(she exits)'), '');
    });
  });
}
