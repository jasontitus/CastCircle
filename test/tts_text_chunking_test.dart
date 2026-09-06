import 'package:flutter_test/flutter_test.dart';

import 'package:castcircle/data/services/tts_service.dart';

// Delegates to the REAL implementation via a @visibleForTesting hook —
// this file used to replicate the algorithm and so verified a copy.
List<String> splitTextForKokoro(String text) =>
    TtsService.splitTextForKokoroTest(text);

void main() {
  group('TTS text chunking (splitTextForKokoro)', () {
    test('short text returns single chunk', () {
      const text = 'Hello, world!';
      final chunks = splitTextForKokoro(text);
      expect(chunks.length, 1);
      expect(chunks.first, text);
    });

    test('text exactly 300 chars returns single chunk', () {
      final text = 'A' * 300;
      final chunks = splitTextForKokoro(text);
      expect(chunks.length, 1);
    });

    test('long text splits at sentence boundaries', () {
      // Create text with multiple sentences that exceed 300 chars
      final text = List.generate(
        10,
        (i) => 'This is sentence number $i which adds some length to the text.',
      ).join(' ');
      expect(text.length, greaterThan(300));

      final chunks = splitTextForKokoro(text);
      expect(chunks.length, greaterThan(1));

      // Each chunk should be ≤ 300 chars
      for (final chunk in chunks) {
        expect(
          chunk.length,
          lessThanOrEqualTo(300),
          reason: 'Chunk too long: ${chunk.length} chars',
        );
      }

      // Reconstructed text should match original (join with space)
      final reconstructed = chunks.join(' ');
      expect(reconstructed, text);
    });

    test('splits at comma boundaries when sentences are too long', () {
      // Single long sentence with commas
      final text =
          List.generate(20, (i) => 'clause number $i').join(', ') + '.';
      expect(text.length, greaterThan(300));

      final chunks = splitTextForKokoro(text);
      for (final chunk in chunks) {
        expect(
          chunk.length,
          lessThanOrEqualTo(300),
          reason: 'Chunk too long: ${chunk.length} chars',
        );
      }
    });

    test('handles text with no punctuation', () {
      final text = 'word ' * 100;
      final chunks = splitTextForKokoro(text.trim());
      // Should still produce chunks, even if they can't split gracefully
      expect(chunks, isNotEmpty);
    });

    test('preserves all text content', () {
      final text =
          'First sentence here. Second sentence there! Third one? '
              'Fourth with semicolons; and more text. ' *
          5;
      final chunks = splitTextForKokoro(text.trim());
      final joined = chunks.join(' ');
      expect(joined, text.trim());
    });

    test('handles exclamation marks and question marks as boundaries', () {
      final text =
          'What is happening! I cannot believe it? This is incredible. ' * 6;
      final chunks = splitTextForKokoro(text.trim());
      expect(chunks.length, greaterThan(1));
      for (final chunk in chunks) {
        expect(chunk.length, lessThanOrEqualTo(300));
      }
    });

    test('empty text returns single empty chunk', () {
      final chunks = splitTextForKokoro('');
      expect(chunks.length, 1);
      expect(chunks.first, '');
    });
  });
}
