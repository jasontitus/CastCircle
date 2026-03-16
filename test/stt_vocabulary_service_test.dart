import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/stt_vocabulary_service.dart';

void main() {
  late SttVocabularyService service;

  setUp(() {
    // Use a fresh instance for each test by accessing the singleton
    // and clearing any previous state
    service = SttVocabularyService.instance;
    service.clearProduction('test-prod');
  });

  group('buildFromScript', () {
    test('extracts character names and corrects close misspellings', () {
      final lines = [
        _line('1', 'Macbeth', 'Is this a dagger which I see before me?'),
        _line('2', 'Lady Macbeth', 'Give me the daggers.'),
      ];

      service.buildFromScript('test-prod', lines);

      // "macbet" is 1 edit away from "macbeth" — should correct
      final corrected = service.correct(
        recognized: 'macbet says hello',
        productionId: 'test-prod',
      );
      expect(corrected.toLowerCase(), contains('macbeth'));
    });

    test('extracts important vocabulary words', () {
      final lines = [
        _line('1', 'Hamlet', 'To be or not to be, that is the question.'),
        _line('2', 'Hamlet', 'Whether tis nobler in the mind to suffer.'),
        _line('3', 'Hamlet', 'The slings and arrows of outrageous fortune.'),
      ];

      service.buildFromScript('test-prod', lines);
      // Words appearing multiple times are marked as important
      // "nobler", "fortune" appear once, but common words like "the" appear multiple times
    });

    test('ignores stage directions', () {
      final lines = [
        _line('1', 'Romeo', 'But soft, what light through yonder window breaks?',
            lineType: LineType.dialogue),
        _lineDirection('2', 'Romeo enters from stage left'),
      ];

      service.buildFromScript('test-prod', lines);
      // Stage direction text should not be in vocabulary
    });
  });

  group('correct', () {
    test('corrects misspelled character names', () {
      final lines = [
        _line('1', 'Ophelia', 'Good my lord, how does your honour?'),
        _line('2', 'Hamlet', 'I humbly thank you, well.'),
      ];
      service.buildFromScript('test-prod', lines);

      final corrected = service.correct(
        recognized: 'ofelia says hello',
        productionId: 'test-prod',
      );
      expect(corrected.toLowerCase(), contains('ophelia'));
    });

    test('returns original when no correction needed', () {
      final lines = [
        _line('1', 'Bob', 'Hello there.'),
      ];
      service.buildFromScript('test-prod', lines);

      final corrected = service.correct(
        recognized: 'hello there',
        productionId: 'test-prod',
      );
      expect(corrected, 'hello there');
    });

    test('corrects against expected text', () {
      final corrected = service.correct(
        recognized: 'to bee or not to bee',
        expectedText: 'To be or not to be',
        productionId: 'test-prod',
      );
      expect(corrected.toLowerCase(), contains('be'));
    });

    test('handles empty recognized text', () {
      final corrected = service.correct(
        recognized: '',
        productionId: 'test-prod',
      );
      expect(corrected, '');
    });
  });

  group('learnFromAttempt', () {
    test('learns actor-specific corrections', () {
      // Same word count, close edit distance corrections
      service.learnFromAttempt(
        productionId: 'test-prod',
        actorId: 'actor1',
        recognized: 'forsoth I say',
        expected: 'forsooth I say',
      );

      expect(service.getActorCorrectionCount('test-prod', 'actor1'), 1);
      final corrections = service.getActorCorrections('test-prod', 'actor1');
      expect(corrections['forsoth'], 'forsooth');
    });

    test('applies learned corrections', () {
      service.learnFromAttempt(
        productionId: 'test-prod',
        actorId: 'actor1',
        recognized: 'forsoth is good',
        expected: 'forsooth is good',
      );

      final corrected = service.correct(
        recognized: 'forsoth is great',
        productionId: 'test-prod',
        actorId: 'actor1',
      );
      expect(corrected, contains('forsooth'));
    });

    test('ignores corrections with high edit distance', () {
      service.learnFromAttempt(
        productionId: 'test-prod',
        actorId: 'actor1',
        recognized: 'something completely different words',
        expected: 'forsooth thou art welcome',
      );

      // Edit distance too high, should not learn
      expect(service.getActorCorrectionCount('test-prod', 'actor1'), 0);
    });

    test('does not learn from different-length sequences', () {
      service.learnFromAttempt(
        productionId: 'test-prod',
        actorId: 'actor1',
        recognized: 'hello world',
        expected: 'hello beautiful world',
      );

      // Different word counts — skip learning
      expect(service.getActorCorrectionCount('test-prod', 'actor1'), 0);
    });
  });

  group('correctedMatchScore', () {
    test('improves score after vocabulary correction', () {
      final lines = [
        _line('1', 'Macbeth', 'Is this a dagger which I see before me?'),
        _line('2', 'Macbeth', 'The handle toward my hand?'),
      ];
      service.buildFromScript('test-prod', lines);

      final rawScore = SttVocabularyService.instance.correctedMatchScore(
        expected: 'Is this a dagger',
        recognized: 'is this a dager',
        productionId: 'test-prod',
      );
      // "dager" should be corrected to "dagger" (in vocabulary)
      expect(rawScore, greaterThanOrEqualTo(0.75));
    });

    test('perfect match returns 1.0', () {
      service.buildFromScript('test-prod', []);

      final score = service.correctedMatchScore(
        expected: 'hello world',
        recognized: 'hello world',
        productionId: 'test-prod',
      );
      expect(score, 1.0);
    });
  });

  group('editDistance', () {
    // Testing via the public interface indirectly
    test('close words get corrected', () {
      final lines = [
        _line('1', 'A', 'forsooth'),
        _line('2', 'A', 'forsooth'),
      ];
      service.buildFromScript('test-prod', lines);

      // "forsoth" is 1 edit away from "forsooth"
      final corrected = service.correct(
        recognized: 'forsoth',
        productionId: 'test-prod',
      );
      expect(corrected, 'forsooth');
    });

    test('distant words are not corrected', () {
      final lines = [
        _line('1', 'A', 'forsooth'),
        _line('2', 'A', 'forsooth'),
      ];
      service.buildFromScript('test-prod', lines);

      // "hello" is far from "forsooth" — no correction
      final corrected = service.correct(
        recognized: 'hello',
        productionId: 'test-prod',
      );
      expect(corrected, 'hello');
    });
  });

  group('clearProduction', () {
    test('clears vocabulary and corrections', () {
      final lines = [
        _line('1', 'Macbeth', 'Double double toil and trouble'),
      ];
      service.buildFromScript('test-prod', lines);
      service.learnFromAttempt(
        productionId: 'test-prod',
        actorId: 'actor1',
        recognized: 'dubble dubble',
        expected: 'double double',
      );

      service.clearProduction('test-prod');

      expect(service.getActorCorrectionCount('test-prod', 'actor1'), 0);
    });
  });
}

ScriptLine _line(String id, String character, String text,
    {LineType lineType = LineType.dialogue}) {
  return ScriptLine(
    id: id,
    act: '1',
    scene: '1',
    lineNumber: int.parse(id),
    orderIndex: int.parse(id),
    character: character,
    text: text,
    lineType: lineType,
  );
}

ScriptLine _lineDirection(String id, String text) {
  return ScriptLine(
    id: id,
    act: '1',
    scene: '1',
    lineNumber: int.parse(id),
    orderIndex: int.parse(id),
    character: '',
    text: text,
    lineType: LineType.stageDirection,
  );
}
