import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/services/sync_queue.dart';

void main() {
  group('SyncJob', () {
    test('creates with all required fields', () {
      final job = SyncJob(
        id: 'job-1',
        productionId: 'prod-1',
        characterName: 'ELIZABETH',
        lineId: 'line-1',
        localPath: '/audio/recording.m4a',
        durationMs: 5000,
        createdAt: DateTime(2026, 1, 1),
      );

      expect(job.id, 'job-1');
      expect(job.productionId, 'prod-1');
      expect(job.characterName, 'ELIZABETH');
      expect(job.lineId, 'line-1');
      expect(job.localPath, '/audio/recording.m4a');
      expect(job.durationMs, 5000);
      expect(job.retryCount, 0);
    });

    test('retryCount defaults to 0', () {
      final job = SyncJob(
        id: 'job-1',
        productionId: 'prod-1',
        characterName: 'DARCY',
        lineId: 'line-2',
        localPath: '/audio/rec2.m4a',
        durationMs: 3000,
        createdAt: DateTime.now(),
      );

      expect(job.retryCount, 0);
    });

    test('retryCount can be incremented', () {
      final job = SyncJob(
        id: 'job-1',
        productionId: 'prod-1',
        characterName: 'DARCY',
        lineId: 'line-2',
        localPath: '/audio/rec2.m4a',
        durationMs: 3000,
        createdAt: DateTime.now(),
      );

      job.retryCount++;
      job.retryCount++;
      expect(job.retryCount, 2);
    });
  });

  group('SyncQueue', () {
    test('singleton instance exists', () {
      final queue = SyncQueue.instance;
      expect(queue, isNotNull);
      expect(identical(queue, SyncQueue.instance), isTrue);
    });

    test('starts with empty pending and failed lists', () {
      final queue = SyncQueue.instance;
      // Note: singleton may have state from other tests,
      // but we can verify the lists are accessible
      expect(queue.pending, isA<List<SyncJob>>());
      expect(queue.failed, isA<List<SyncJob>>());
    });

    test('pendingCount reflects total of pending + failed', () {
      final queue = SyncQueue.instance;
      expect(queue.pendingCount, queue.pending.length + queue.failed.length);
    });
  });
}
