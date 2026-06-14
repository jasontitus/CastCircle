import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/services/stt_service.dart';

void main() {
  group('SttService', () {
    test('is a singleton', () {
      expect(identical(SttService.instance, SttService.instance), true);
    });

    test('isListening is false initially', () {
      expect(SttService.instance.isListening, false);
    });

    test('isMlxReady is false before init', () {
      expect(SttService.instance.isMlxReady, false);
    });

    test('SttEngine enum has expected values', () {
      expect(SttEngine.values,
          containsAll([SttEngine.mlx, SttEngine.apple]));
      expect(SttEngine.values.length, 2);
    });
  });

  group('SttService.mergeTranscripts', () {
    test('joins carried and partial with a single space', () {
      expect(SttService.mergeTranscripts('to be or not to be', 'that is'),
          'to be or not to be that is');
    });

    test('handles empty sides', () {
      expect(SttService.mergeTranscripts('', 'hello'), 'hello');
      expect(SttService.mergeTranscripts('hello', ''), 'hello');
      expect(SttService.mergeTranscripts('', ''), '');
    });

    test('trims stray whitespace from both fragments', () {
      expect(SttService.mergeTranscripts('  hello  ', '  world  '),
          'hello world');
    });

    test('accumulates across multiple auto-finalizations', () {
      // Simulates Apple's recognizer auto-finalizing at each dramatic
      // pause: each restarted session only hears the next fragment, but
      // the merged transcript keeps the whole line.
      const line = 'To be or not to be that is the question';
      var carried = '';
      for (final fragment in [
        'to be or not to be',
        'that is',
        'the question',
      ]) {
        carried = SttService.mergeTranscripts(carried, fragment);
      }
      expect(SttService.matchScore(line, carried), 1.0);

      // Without carrying, the final fragment alone scores poorly —
      // this is the regression the carried transcript fixes.
      expect(SttService.matchScore(line, 'the question'), lessThan(0.5));
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

    test('ignores parenthetical/bracketed stage directions in the expected line',
        () {
      // The actor says only the dialogue, never the direction — so a perfect
      // delivery of the dialogue should score 1.0 even though the line text
      // contains "(crossing)" / "[aside]".
      expect(SttService.matchScore('Hello (crossing) world', 'hello world'), 1.0);
      expect(SttService.matchScore('[aside] He is a fool', 'he is a fool'), 1.0);
      // Unclosed direction (OCR dropped the ')') running to end of line.
      expect(
        SttService.matchScore(
          'Nothing would delight me more. (MRS. GARDINER and ELIZABETH turn to',
          'nothing would delight me more',
        ),
        1.0,
      );
    });
  });
}
