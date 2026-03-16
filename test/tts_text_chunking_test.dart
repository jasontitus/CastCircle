import 'package:flutter_test/flutter_test.dart';

// TtsService._splitTextForKokoro is private, so we replicate the logic here
// to test the chunking algorithm. This is a unit test for the algorithm itself.
List<String> splitTextForKokoro(String text) {
  if (text.length <= 300) return [text];

  final chunks = <String>[];
  final sentences = text.split(RegExp(r'(?<=[.!?;])\s+'));
  var current = '';

  for (final sentence in sentences) {
    if (current.isEmpty) {
      current = sentence;
    } else if (current.length + sentence.length + 1 <= 300) {
      current = '$current $sentence';
    } else {
      chunks.add(current);
      current = sentence;
    }
  }
  if (current.isNotEmpty) chunks.add(current);

  final result = <String>[];
  for (final chunk in chunks) {
    if (chunk.length <= 300) {
      result.add(chunk);
    } else {
      final parts = chunk.split(RegExp(r'(?<=[,;:])\s+'));
      var sub = '';
      for (final part in parts) {
        if (sub.isEmpty) {
          sub = part;
        } else if (sub.length + part.length + 1 <= 300) {
          sub = '$sub $part';
        } else {
          result.add(sub);
          sub = part;
        }
      }
      if (sub.isNotEmpty) result.add(sub);
    }
  }
  return result;
}

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
      final text = List.generate(10, (i) => 'This is sentence number $i which adds some length to the text.').join(' ');
      expect(text.length, greaterThan(300));

      final chunks = splitTextForKokoro(text);
      expect(chunks.length, greaterThan(1));

      // Each chunk should be ≤ 300 chars
      for (final chunk in chunks) {
        expect(chunk.length, lessThanOrEqualTo(300),
            reason: 'Chunk too long: ${chunk.length} chars');
      }

      // Reconstructed text should match original (join with space)
      final reconstructed = chunks.join(' ');
      expect(reconstructed, text);
    });

    test('splits at comma boundaries when sentences are too long', () {
      // Single long sentence with commas
      final text = List.generate(20, (i) => 'clause number $i').join(', ') + '.';
      expect(text.length, greaterThan(300));

      final chunks = splitTextForKokoro(text);
      for (final chunk in chunks) {
        expect(chunk.length, lessThanOrEqualTo(300),
            reason: 'Chunk too long: ${chunk.length} chars');
      }
    });

    test('handles text with no punctuation', () {
      final text = 'word ' * 100;
      final chunks = splitTextForKokoro(text.trim());
      // Should still produce chunks, even if they can't split gracefully
      expect(chunks, isNotEmpty);
    });

    test('preserves all text content', () {
      final text = 'First sentence here. Second sentence there! Third one? '
          'Fourth with semicolons; and more text. ' * 5;
      final chunks = splitTextForKokoro(text.trim());
      final joined = chunks.join(' ');
      expect(joined, text.trim());
    });

    test('handles exclamation marks and question marks as boundaries', () {
      final text = 'What is happening! I cannot believe it? This is incredible. ' * 6;
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
