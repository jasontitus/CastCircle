import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/rehearsal_models.dart';

void main() {
  group('RehearsalSession computed properties', () {
    test('duration calculates correctly', () {
      final session = RehearsalSession(
        id: 's1',
        productionId: 'p1',
        sceneId: 'sc1',
        sceneName: 'Scene 1',
        character: 'ELIZABETH',
        startedAt: DateTime(2026, 1, 1, 10, 0),
        endedAt: DateTime(2026, 1, 1, 10, 15),
        totalLines: 20,
        completedLines: 18,
        averageMatchScore: 0.85,
        lineAttempts: [],
        rehearsalMode: 'sceneReadthrough',
      );

      expect(session.duration, const Duration(minutes: 15));
    });

    test('completionRate is lines completed / total', () {
      final session = RehearsalSession(
        id: 's1',
        productionId: 'p1',
        sceneId: 'sc1',
        sceneName: 'Scene 1',
        character: 'ELIZABETH',
        startedAt: DateTime.now(),
        endedAt: DateTime.now(),
        totalLines: 20,
        completedLines: 15,
        averageMatchScore: 0.8,
        lineAttempts: [],
        rehearsalMode: 'sceneReadthrough',
      );

      expect(session.completionRate, 0.75);
    });

    test('completionRate is 0 when totalLines is 0', () {
      final session = RehearsalSession(
        id: 's1',
        productionId: 'p1',
        sceneId: 'sc1',
        sceneName: 'Scene 1',
        character: 'ELIZABETH',
        startedAt: DateTime.now(),
        endedAt: DateTime.now(),
        totalLines: 0,
        completedLines: 0,
        averageMatchScore: 0.0,
        lineAttempts: [],
        rehearsalMode: 'sceneReadthrough',
      );

      expect(session.completionRate, 0.0);
    });

    test('struggledLines returns lines below 0.7 score', () {
      final attempts = [
        const LineAttempt(
          lineId: 'l1', lineText: 'Easy line', attemptCount: 1,
          bestScore: 0.95, skipped: false,
        ),
        const LineAttempt(
          lineId: 'l2', lineText: 'Hard line', attemptCount: 4,
          bestScore: 0.45, skipped: false,
        ),
        const LineAttempt(
          lineId: 'l3', lineText: 'Medium line', attemptCount: 2,
          bestScore: 0.72, skipped: false,
        ),
        const LineAttempt(
          lineId: 'l4', lineText: 'Skipped line', attemptCount: 1,
          bestScore: 0.3, skipped: true,
        ),
      ];

      final session = RehearsalSession(
        id: 's1',
        productionId: 'p1',
        sceneId: 'sc1',
        sceneName: 'Scene 1',
        character: 'ELIZABETH',
        startedAt: DateTime.now(),
        endedAt: DateTime.now(),
        totalLines: 4,
        completedLines: 3,
        averageMatchScore: 0.6,
        lineAttempts: attempts,
        rehearsalMode: 'sceneReadthrough',
      );

      expect(session.struggledLines.length, 2);
      expect(session.struggledLines.map((a) => a.lineId), containsAll(['l2', 'l4']));
    });

    test('struggledLines is empty when all scores above threshold', () {
      final attempts = [
        const LineAttempt(
          lineId: 'l1', lineText: 'Line 1', attemptCount: 1,
          bestScore: 0.9, skipped: false,
        ),
        const LineAttempt(
          lineId: 'l2', lineText: 'Line 2', attemptCount: 1,
          bestScore: 0.85, skipped: false,
        ),
      ];

      final session = RehearsalSession(
        id: 's1',
        productionId: 'p1',
        sceneId: 'sc1',
        sceneName: 'Scene 1',
        character: 'ELIZABETH',
        startedAt: DateTime.now(),
        endedAt: DateTime.now(),
        totalLines: 2,
        completedLines: 2,
        averageMatchScore: 0.875,
        lineAttempts: attempts,
        rehearsalMode: 'sceneReadthrough',
      );

      expect(session.struggledLines, isEmpty);
    });
  });

  group('LineAttempt', () {
    test('stores all fields correctly', () {
      const attempt = LineAttempt(
        lineId: 'line-42',
        lineText: 'To be or not to be, that is the question.',
        attemptCount: 3,
        bestScore: 0.88,
        skipped: false,
      );

      expect(attempt.lineId, 'line-42');
      expect(attempt.lineText, contains('question'));
      expect(attempt.attemptCount, 3);
      expect(attempt.bestScore, 0.88);
      expect(attempt.skipped, isFalse);
    });

    test('skipped attempt tracking', () {
      const skipped = LineAttempt(
        lineId: 'line-1',
        lineText: 'Difficult line.',
        attemptCount: 1,
        bestScore: 0.2,
        skipped: true,
      );

      expect(skipped.skipped, isTrue);
      expect(skipped.bestScore, lessThan(0.7));
    });
  });
}
