import 'package:flutter_test/flutter_test.dart';
import 'package:lineguide/data/services/stt_service.dart';

void main() {
  group('SttService', () {
    test('is a singleton', () {
      expect(identical(SttService.instance, SttService.instance), true);
    });

    test('isWhisperReady is false before init', () {
      expect(SttService.instance.isWhisperReady, false);
    });

    test('isListening is false initially', () {
      expect(SttService.instance.isListening, false);
    });

    test('isMlxReady is false before init', () {
      expect(SttService.instance.isMlxReady, false);
    });

    test('SttEngine enum has expected values', () {
      expect(SttEngine.values,
          containsAll([SttEngine.mlx, SttEngine.whisper, SttEngine.system]));
      expect(SttEngine.values.length, 3);
    });
  });

  group('SttService.matchScore', () {
    test('perfect match returns 1.0', () {
      expect(
        SttService.matchScore('Hello world', 'hello world'),
        1.0,
      );
    });

    test('partial match returns fraction', () {
      expect(
        SttService.matchScore('Hello beautiful world', 'hello world'),
        closeTo(0.666, 0.01),
      );
    });

    test('no match returns 0.0', () {
      expect(
        SttService.matchScore('Hello world', 'goodbye universe'),
        0.0,
      );
    });

    test('empty expected returns 1.0', () {
      expect(SttService.matchScore('', 'anything'), 1.0);
    });

    test('ignores punctuation', () {
      expect(
        SttService.matchScore(
          "It's a fine day, isn't it?",
          'its a fine day isnt it',
        ),
        1.0,
      );
    });

    test('case insensitive', () {
      expect(
        SttService.matchScore('HELLO WORLD', 'hello world'),
        1.0,
      );
    });

    test('handles extra spoken words gracefully', () {
      // Extra words in spoken should not reduce score
      expect(
        SttService.matchScore('hello', 'hello world goodbye'),
        1.0,
      );
    });
  });
}
