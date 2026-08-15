import 'dart:io';

import 'package:castcircle/data/services/espeak_heteronyms.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two layers:
///
/// 1. The rewrite itself — pure, fast, always runs.
/// 2. What espeak-ng actually SAYS. A respelling rule is a claim about an
///    external engine, and asserting my own string output would only prove I
///    typed the same regex twice. These cases shell out to espeak-ng when it
///    is installed (`brew install espeak-ng`) and skip otherwise, so CI stays
///    green without pretending the claim was checked.
void main() {
  group('rewrite', () {
    test('fixes the subjunctive and imperative', () {
      expect(EspeakHeteronyms.apply('Long live the King!'),
          'Long liv the King!');
      expect(EspeakHeteronyms.apply('Let him live.'), 'Let him liv.');
      expect(EspeakHeteronyms.apply('May he live long.'), 'May he liv long.');
      expect(EspeakHeteronyms.apply('Live and let live.'),
          'Liv and let liv.');
    });

    test('leaves alone what espeak already gets right', () {
      // Verb forms espeak reads correctly from context.
      for (final s in [
        'I live in Denmark.',
        'We live here.',
        'They live nearby.',
        'To live or not to live.',
        'We must live.',
      ]) {
        expect(EspeakHeteronyms.apply(s), s, reason: s);
      }
      // Adjective uses — respelling these would be an actual regression.
      for (final s in [
        'It was a live performance.',
        'Live theatre is better.',
        'Careful, that is a live wire.',
        'The show went out live.',
      ]) {
        expect(EspeakHeteronyms.apply(s), s, reason: s);
      }
    });

    test('preserves surrounding text and casing', () {
      expect(EspeakHeteronyms.apply('LONG LIVE THE KING'),
          'LONG LIV THE KING');
      expect(EspeakHeteronyms.apply('Long Live the King'),
          'Long Liv the King');
      expect(EspeakHeteronyms.apply(''), '');
      expect(EspeakHeteronyms.apply('No heteronym here.'),
          'No heteronym here.');
    });
  });

  group('espeak-ng agrees', () {
    late final bool available = Process.runSync('which', ['espeak-ng'])
            .exitCode ==
        0;

    String ipa(String text) => (Process.runSync(
                'espeak-ng', ['-v', 'en-gb', '--ipa', '-q', text])
            .stdout as String)
        .replaceAll('\n', ' ')
        .trim();

    /// The wrong reading is the diphthong /aɪv/; the right one is /ɪv/.
    bool saysLong(String out) => out.contains('aɪv');

    test('the rules turn a wrong reading into a right one', () {
      if (!available) {
        markTestSkipped('espeak-ng not installed');
        return;
      }
      for (final line in [
        'Long live the King!',
        'Let him live.',
        'May he live long.',
        'Live and let live.',
      ]) {
        expect(saysLong(ipa(line)), isTrue,
            reason: 'precondition: espeak should mispronounce "$line" — if '
                'this fails espeak improved and the rule may be obsolete');
        expect(saysLong(ipa(EspeakHeteronyms.apply(line))), isFalse,
            reason: 'the rewrite of "$line" should fix it');
      }
    });

    test('untouched lines still sound right', () {
      if (!available) {
        markTestSkipped('espeak-ng not installed');
        return;
      }
      // Verbs espeak already handles: short vowel, and we changed nothing.
      for (final line in ['I live in Denmark.', 'We must live.']) {
        expect(saysLong(ipa(line)), isFalse, reason: line);
      }
      // Adjectives: long vowel is CORRECT here.
      for (final line in ['It was a live performance.', 'Live theatre.']) {
        expect(saysLong(ipa(line)), isTrue, reason: line);
      }
    });
  });
}
