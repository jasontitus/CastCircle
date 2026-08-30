import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/services/sync_queue.dart';

/// In-memory uploader so queue behavior can be tested without Supabase.
class FakeUploader implements RecordingUploader {
  bool ready = true;
  bool failUpload = false;
  bool failMetadata = false;
  bool failDiscard = false;

  /// Called at the start of each upload, before it resolves — lets tests
  /// enqueue a replacement take while an upload is in flight.
  void Function(SyncJob job)? onUploadStarted;

  final List<SyncJob> uploads = [];
  final List<String> savedUrls = [];
  final List<SyncJob> savedMetadataJobs = [];
  final List<String> discardedUrls = [];
  @override
  bool get isReady => ready;

  @override
  Future<String> upload(SyncJob job) async {
    onUploadStarted?.call(job);
    // Yield so work scheduled by onUploadStarted (e.g. an enqueue) lands
    // mid-flight like a real slow network upload.
    await Future<void>.delayed(Duration.zero);
    if (failUpload) throw Exception('upload failed');
    uploads.add(job);
    return 'https://cloud.example/recordings/'
        '${job.productionId}/${job.characterName}/${job.lineId}/'
        '${uploads.length}.m4a';
  }

  @override
  Future<void> saveMetadata(SyncJob job, String remoteUrl) async {
    if (failMetadata) throw Exception('metadata failed');
    savedMetadataJobs.add(job);
    savedUrls.add(remoteUrl);
  }

  @override
  Future<void> discardUpload(SyncJob job, String remoteUrl) async {
    if (failDiscard) throw Exception('discard failed');
    discardedUrls.add(remoteUrl);
  }
}

class FlakyPersistence implements SyncQueuePersistence {
  int failuresRemaining;
  int writes = 0;
  final Map<String, PersistedSyncJob> rows = {};

  FlakyPersistence(this.failuresRemaining);

  Future<void> _maybeFail() async {
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw FileSystemException('disk unavailable');
    }
    writes++;
  }

  @override
  Future<void> clear() async {
    await _maybeFail();
    rows.clear();
  }

  @override
  Future<void> delete(String queueKey) async {
    await _maybeFail();
    rows.remove(queueKey);
  }

  @override
  Future<List<PersistedSyncJob>> load() async => rows.values.toList();

  @override
  Future<void> upsert(SyncJob job, PersistedSyncJobState state) async {
    await _maybeFail();
    rows[job.queueKey] = PersistedSyncJob(job.snapshot(), state);
  }
}

void main() {
  late Directory tempDir;
  late FakeUploader uploader;
  late SyncQueue queue;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sync_queue_test');
    uploader = FakeUploader();
    queue = SyncQueue.forTesting(uploader);
  });

  tearDown(() async {
    queue.reset();
    try {
      await tempDir.delete(recursive: true);
    } on FileSystemException {
      // A straggler async persist can re-create the file mid-delete
      // (observed as "Directory not empty" under full-suite load).
      await Future.delayed(const Duration(milliseconds: 200));
      await tempDir.delete(recursive: true);
    }
  });

  Future<String> makeAudioFile(String name) async {
    final file = File('${tempDir.path}/$name.m4a');
    await file.writeAsBytes(List.filled(256, 7));
    return file.path;
  }

  group('SyncJob', () {
    test('recordedAt defaults to createdAt', () {
      final created = DateTime(2026, 1, 1);
      final job = SyncJob(
        id: 'job-1',
        productionId: 'prod-1',
        characterName: 'ELIZABETH',
        lineId: 'line-1',
        localPath: '/audio/recording.m4a',
        durationMs: 5000,
        createdAt: created,
      );

      expect(job.recordedAt, created);
      expect(job.retryCount, 0);
    });

    test('keeps explicit recordedAt', () {
      final recorded = DateTime(2026, 1, 2, 12, 30);
      final job = SyncJob(
        id: 'job-1',
        productionId: 'prod-1',
        characterName: 'DARCY',
        lineId: 'line-2',
        localPath: '/audio/rec2.m4a',
        durationMs: 3000,
        createdAt: DateTime(2026, 1, 3),
        recordedAt: recorded,
      );

      expect(job.recordedAt, recorded);
    });

    test('persists immutable recording identity across queue restart', () {
      final job = SyncJob(
        id: 'job-1',
        productionId: 'prod-1',
        characterName: 'DARCY',
        lineId: 'line-2',
        recordingId: 'recording-2',
        localPath: '/audio/rec2.m4a',
        durationMs: 3000,
        createdAt: DateTime.utc(2026),
      );

      expect(SyncJob.fromJson(job.toJson())!.recordingId, 'recording-2');
      final legacyJson = job.toJson()..remove('recordingId');
      expect(SyncJob.fromJson(legacyJson)!.recordingId, isNull);
    });
  });

  group('SyncQueue upload flow', () {
    test('uploads a queued recording and reports success', () async {
      final path = await makeAudioFile('line-1');
      final recorded = DateTime(2026, 5, 1, 9, 15);

      String? uploadedProduction;
      String? uploadedLine;
      String? uploadedUrl;
      queue.onUploaded = (job, url) async {
        uploadedProduction = job.productionId;
        uploadedLine = job.lineId;
        uploadedUrl = url;
      };

      uploader.ready = false; // hold processing until we trigger it
      queue.enqueue(
        productionId: 'prod-1',
        characterName: 'HAMLET',
        lineId: 'line-1',
        localPath: path,
        durationMs: 4200,
        recordedAt: recorded,
      );
      expect(queue.pending, hasLength(1));

      uploader.ready = true;
      await queue.processQueue();

      expect(queue.pending, isEmpty);
      expect(queue.failed, isEmpty);
      expect(uploader.uploads.single.lineId, 'line-1');
      expect(uploader.uploads.single.recordedAt, recorded);
      expect(uploader.savedMetadataJobs.single.durationMs, 4200);
      expect(uploadedProduction, 'prod-1');
      expect(uploadedLine, 'line-1');
      expect(uploadedUrl, contains('prod-1/HAMLET/line-1/1.m4a'));
    });

    test('does nothing while uploader is not ready', () async {
      final path = await makeAudioFile('line-1');
      uploader.ready = false;

      queue.enqueue(
        productionId: 'prod-1',
        characterName: 'HAMLET',
        lineId: 'line-1',
        localPath: path,
        durationMs: 1000,
      );
      await queue.processQueue();

      expect(queue.pending, hasLength(1));
      expect(uploader.uploads, isEmpty);
    });

    test('drops job when local file is missing', () async {
      uploader.ready = false;
      queue.enqueue(
        productionId: 'prod-1',
        characterName: 'HAMLET',
        lineId: 'line-1',
        localPath: '${tempDir.path}/does-not-exist.m4a',
        durationMs: 1000,
      );

      uploader.ready = true;
      await queue.processQueue();

      expect(queue.pending, isEmpty);
      expect(queue.failed, isEmpty);
      expect(uploader.uploads, isEmpty);
    });

    test('re-enqueueing the same line replaces the older job', () async {
      final oldPath = await makeAudioFile('take-1');
      final newPath = await makeAudioFile('take-2');
      uploader.ready = false;

      queue.enqueue(
        productionId: 'prod-1',
        characterName: 'HAMLET',
        lineId: 'line-1',
        localPath: oldPath,
        durationMs: 1000,
      );
      queue.enqueue(
        productionId: 'prod-1',
        characterName: 'HAMLET',
        lineId: 'line-1',
        localPath: newPath,
        durationMs: 2000,
      );

      expect(queue.pending, hasLength(1));
      expect(queue.pending.single.localPath, newPath);
      expect(queue.pending.single.durationMs, 2000);

      // Different lines still queue separately
      queue.enqueue(
        productionId: 'prod-1',
        characterName: 'HAMLET',
        lineId: 'line-2',
        localPath: newPath,
        durationMs: 500,
      );
      expect(queue.pending, hasLength(2));
    });

    test('failed uploads move to failed list and can be retried', () async {
      final path = await makeAudioFile('line-1');
      uploader.ready = false;
      queue.enqueue(
        productionId: 'prod-1',
        characterName: 'HAMLET',
        lineId: 'line-1',
        localPath: path,
        durationMs: 1000,
      );

      uploader.ready = true;
      uploader.failUpload = true;
      await queue.processQueue();

      expect(queue.pending, isEmpty);
      expect(queue.failed, hasLength(1));
      expect(queue.failed.single.retryCount, 1);
      expect(queue.pendingCount, 1);

      // Connectivity restored / retry fires — upload now succeeds
      uploader.failUpload = false;
      await queue.retryNow();

      expect(queue.failed, isEmpty);
      expect(queue.pending, isEmpty);
      expect(uploader.uploads, hasLength(1));
    });

    test('metadata failure also counts as a failed attempt', () async {
      final path = await makeAudioFile('line-1');
      uploader.ready = false;
      queue.enqueue(
        productionId: 'prod-1',
        characterName: 'HAMLET',
        lineId: 'line-1',
        localPath: path,
        durationMs: 1000,
      );

      uploader.ready = true;
      uploader.failMetadata = true;
      await queue.processQueue();

      expect(queue.failed, hasLength(1));
      expect(uploader.savedUrls, isEmpty);
    });

    test('gives up after 5 attempts and reports it', () async {
      final path = await makeAudioFile('line-1');
      SyncJob? abandoned;
      queue.onGaveUp = (job, error) => abandoned = job;

      uploader.ready = false;
      queue.enqueue(
        productionId: 'prod-1',
        characterName: 'HAMLET',
        lineId: 'line-1',
        localPath: path,
        durationMs: 1000,
      );

      uploader.ready = true;
      uploader.failUpload = true;
      await queue.processQueue();
      for (var i = 0; i < 4; i++) {
        await queue.retryNow();
      }

      expect(queue.pending, isEmpty);
      expect(queue.failed, hasLength(1));
      expect(abandoned, isNotNull);
      expect(abandoned!.lineId, 'line-1');
      expect(abandoned!.retryCount, 5);
    });

    test('re-recording while the old take is uploading keeps the new job '
        'and does not mark it uploaded with the stale URL', () async {
      final sharedPath = await makeAudioFile('take-shared');

      final uploadedUrls = <String>[];
      final uploadedRecordingIds = <String?>[];
      queue.onUploaded = (job, url) async {
        uploadedUrls.add(url);
        uploadedRecordingIds.add(job.recordingId);
      };

      uploader.ready = false;
      queue.enqueue(
        productionId: 'prod-1',
        characterName: 'HAMLET',
        lineId: 'line-1',
        recordingId: 'old-take',
        localPath: sharedPath,
        durationMs: 1000,
      );

      // While take-1 is in flight, the actor re-records the line.
      var replacedMidFlight = false;
      uploader.onUploadStarted = (job) {
        if (!replacedMidFlight && job.recordingId == 'old-take') {
          replacedMidFlight = true;
          queue.enqueue(
            productionId: 'prod-1',
            characterName: 'HAMLET',
            lineId: 'line-1',
            recordingId: 'new-take',
            localPath: sharedPath,
            durationMs: 2000,
          );
        }
      };

      uploader.ready = true;
      await queue.processQueue();
      // Drain the microtask-scheduled follow-up pass for the new job.
      await Future<void>.delayed(Duration.zero);
      await queue.processQueue();

      // The NEW take must survive and upload; the stale take-1 object must be
      // durably discarded and must never stamp the replacement row.
      expect(queue.pending, isEmpty);
      expect(queue.failed, isEmpty);
      expect(uploader.uploads.map((j) => j.localPath), contains(sharedPath));
      expect(uploadedUrls, hasLength(1));
      expect(uploadedRecordingIds, ['new-take']);
      expect(uploader.discardedUrls, hasLength(1));
      expect(uploader.discardedUrls.single, isNot(uploadedUrls.single));
      expect(uploader.uploads.last.durationMs, 2000);
      expect(uploader.savedMetadataJobs.last.durationMs, 2000);
    });

    test('persists orphan cleanup until a failed discard can retry', () async {
      final oldPath = await makeAudioFile('orphan-old');
      final newPath = await makeAudioFile('orphan-new');
      uploader.ready = false;
      queue.enqueue(
        productionId: 'prod-1',
        characterName: 'HAMLET',
        lineId: 'line-orphan',
        localPath: oldPath,
        durationMs: 1000,
      );
      var replaced = false;
      uploader.onUploadStarted = (job) {
        if (!replaced) {
          replaced = true;
          queue.enqueue(
            productionId: 'prod-1',
            characterName: 'HAMLET',
            lineId: 'line-orphan',
            localPath: newPath,
            durationMs: 2000,
          );
        }
      };

      uploader
        ..ready = true
        ..failDiscard = true;
      await queue.processQueue();
      expect(queue.failed, hasLength(1));
      expect(queue.failed.single.orphanedRemoteUrls, hasLength(1));
      expect(uploader.uploads.map((job) => job.localPath), [oldPath]);

      uploader.failDiscard = false;
      await queue.retryNow();
      expect(queue.failed, isEmpty);
      expect(queue.pending, isEmpty);
      expect(uploader.discardedUrls, hasLength(1));
      expect(uploader.uploads.map((job) => job.localPath), [oldPath, newPath]);
    });

    test('awaits local persistence before settling an uploaded job', () async {
      final path = await makeAudioFile('delayed-stamp');
      final callbackStarted = Completer<void>();
      final allowCallback = Completer<void>();
      queue.onUploaded = (job, url) async {
        callbackStarted.complete();
        await allowCallback.future;
      };
      uploader.ready = false;
      queue.enqueue(
        productionId: 'prod-1',
        characterName: 'HAMLET',
        lineId: 'line-delayed',
        localPath: path,
        durationMs: 1000,
      );

      uploader.ready = true;
      final processing = queue.processQueue();
      await callbackStarted.future;
      expect(queue.pending, hasLength(1));
      expect(uploader.uploads, hasLength(1));

      allowCallback.complete();
      await processing;
      expect(queue.pending, isEmpty);
    });

    test(
      'retries a failed local stamp without uploading bytes again',
      () async {
        final path = await makeAudioFile('stamp-retry');
        var failStamp = true;
        queue.onUploaded = (job, url) async {
          if (failStamp) throw StateError('zero affected rows');
        };
        uploader.ready = false;
        queue.enqueue(
          productionId: 'prod-1',
          characterName: 'HAMLET',
          lineId: 'line-stamp',
          localPath: path,
          durationMs: 1000,
        );

        uploader.ready = true;
        await queue.processQueue();
        expect(queue.failed, hasLength(1));
        expect(queue.failed.single.remoteUrl, isNotNull);
        expect(uploader.uploads, hasLength(1));

        failStamp = false;
        await queue.retryNow();
        expect(queue.failed, isEmpty);
        expect(uploader.uploads, hasLength(1));
      },
    );

    test(
      'persistence failure stays visible and automatically retries',
      () async {
        final path = await makeAudioFile('durable');
        final persistence = FlakyPersistence(2);
        final durableQueue = SyncQueue.forTesting(
          uploader,
          persistence: persistence,
          persistenceRetryDelay: const Duration(milliseconds: 1),
        );
        uploader.ready = false;
        durableQueue.enqueue(
          productionId: 'prod-1',
          characterName: 'HAMLET',
          lineId: 'line-durable',
          localPath: path,
          durationMs: 1000,
        );

        await Future<void>.delayed(Duration.zero);
        expect(durableQueue.lastPersistenceError, isNotNull);
        expect(durableQueue.persistenceHealthy, isFalse);

        await Future<void>.delayed(const Duration(milliseconds: 20));
        await durableQueue.flushPersistence();
        expect(durableQueue.persistenceHealthy, isTrue);
        expect(persistence.rows, hasLength(1));

        final restored = SyncQueue.forTesting(
          FakeUploader()..ready = false,
          persistence: persistence,
        );
        await restored.flushPersistence();
        expect(restored.pending.single.lineId, 'line-durable');
        durableQueue.stop();
        restored.stop();
      },
    );

    test(
      'offline enqueue performs one keyed persistence mutation per job',
      () async {
        final path = await makeAudioFile('shared-audio');
        final persistence = FlakyPersistence(0);
        final durableQueue = SyncQueue.forTesting(
          uploader,
          persistence: persistence,
        );
        uploader.ready = false;

        for (var i = 0; i < 1000; i++) {
          durableQueue.enqueue(
            productionId: 'prod-1',
            characterName: 'HAMLET',
            lineId: 'line-$i',
            localPath: path,
            durationMs: 1000,
          );
        }
        await durableQueue.flushPersistence();

        expect(persistence.rows, hasLength(1000));
        expect(persistence.writes, 1000);
        expect(durableQueue.durableGeneration, durableQueue.dirtyGeneration);
        durableQueue.stop();
      },
    );

    test(
      'queued uploads survive an app restart via the persistence file',
      () async {
        final persistPath = '${tempDir.path}/sync_queue.json';
        final path1 = await makeAudioFile('line-1');
        final path2 = await makeAudioFile('line-2');
        final goneFilePath = '${tempDir.path}/deleted-later.m4a';
        await File(goneFilePath).writeAsBytes(List.filled(64, 1));

        final q1 = SyncQueue.forTesting(uploader, persistPath: persistPath);
        uploader.ready = false; // offline — jobs stay queued
        q1.enqueue(
          productionId: 'prod-1',
          characterName: 'HAMLET',
          lineId: 'line-1',
          localPath: path1,
          durationMs: 1000,
        );
        q1.enqueue(
          productionId: 'prod-1',
          characterName: 'HAMLET',
          lineId: 'line-2',
          localPath: path2,
          durationMs: 2000,
        );
        q1.enqueue(
          productionId: 'prod-1',
          characterName: 'HAMLET',
          lineId: 'line-3',
          localPath: goneFilePath,
          durationMs: 500,
        );
        await q1.flushPersistence();

        // "App restart": new queue instance, audio for line-3 gone, and line-2
        // was re-recorded live before the restore ran.
        await File(goneFilePath).delete();
        final uploader2 = FakeUploader()..ready = false;
        final q2 = SyncQueue.forTesting(uploader2, persistPath: persistPath);
        final newPath2 = await makeAudioFile('line-2-take2');
        q2.enqueue(
          productionId: 'prod-1',
          characterName: 'HAMLET',
          lineId: 'line-2',
          localPath: newPath2,
          durationMs: 2500,
        );
        await q2.flushPersistence();

        expect(q2.pending, hasLength(2)); // line-1 restored, line-2 live take
        expect(
          q2.pending.map((j) => j.localPath),
          containsAll([path1, newPath2]),
        );
        expect(q2.pending.map((j) => j.lineId), isNot(contains('line-3')));

        uploader2.ready = true;
        await q2.processQueue();
        expect(q2.pending, isEmpty);
        expect(uploader2.uploads, hasLength(2));
        q2.reset();
      },
    );

    test('re-recording a permanently failed line re-queues it fresh', () async {
      final path = await makeAudioFile('line-1');
      uploader.ready = false;
      queue.enqueue(
        productionId: 'prod-1',
        characterName: 'HAMLET',
        lineId: 'line-1',
        localPath: path,
        durationMs: 1000,
      );

      uploader.ready = true;
      uploader.failUpload = true;
      await queue.processQueue();
      expect(queue.failed, hasLength(1));

      // New take for the same line clears the failed job and uploads
      uploader.failUpload = false;
      uploader.ready = false;
      final newPath = await makeAudioFile('take-2');
      queue.enqueue(
        productionId: 'prod-1',
        characterName: 'HAMLET',
        lineId: 'line-1',
        localPath: newPath,
        durationMs: 1500,
      );
      uploader.ready = true;
      await queue.processQueue();

      expect(queue.failed, isEmpty);
      expect(queue.pending, isEmpty);
      expect(uploader.uploads.single.localPath, newPath);
    });
  });
}
