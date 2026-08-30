import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/services/tts_service.dart';
import 'package:castcircle/data/services/kokoro_onnx_service.dart';

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

    test('registered voice IDs map exactly and unknown IDs are rejected', () {
      for (final entry in KokoroOnnxService.voiceIds.entries) {
        expect(KokoroOnnxService.speakerIdForVoice(entry.key), entry.value);
        expect(
          TtsService.instance.assignVoice(
            'known-${entry.key}',
            entry.value,
            voiceId: entry.key,
          ),
          isTrue,
        );
      }

      expect(KokoroOnnxService.speakerIdForVoice('unknown_voice'), isNull);
      expect(
        TtsService.instance.assignVoice(
          'bad-override',
          0,
          voiceId: 'unknown_voice',
        ),
        isFalse,
      );
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
