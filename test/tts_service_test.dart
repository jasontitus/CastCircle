import 'package:flutter_test/flutter_test.dart';
import 'package:lineguide/data/services/tts_service.dart';

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
}
