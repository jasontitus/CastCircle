import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/services/sync_queue.dart';

/// In-memory uploader so queue behavior can be tested without Supabase.
class FakeUploader implements RecordingUploader {
  bool ready = true;
  bool failUpload = false;
  bool failMetadata = false;

  /// Called at the start of each upload, before it resolves — lets tests
  /// enqueue a replacement take while an upload is in flight.
  void Function(SyncJob job)? onUploadStarted;

  final List<SyncJob> uploads = [];
  final List<String> savedUrls = [];
  final List<SyncJob> savedMetadataJobs = [];

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
        '${job.productionId}/${job.characterName}/${job.lineId}.m4a';
  }

  @override
  Future<void> saveMetadata(SyncJob job, String remoteUrl) async {
    if (failMetadata) throw Exception('metadata failed');
    savedMetadataJobs.add(job);
    savedUrls.add(remoteUrl);
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
    await tempDir.delete(recursive: true);
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
  });

  group('SyncQueue upload flow', () {
    test('uploads a queued recording and reports success', () async {
      final path = await makeAudioFile('line-1');
      final recorded = DateTime(2026, 5, 1, 9, 15);

      String? uploadedProduction;
      String? uploadedLine;
      String? uploadedUrl;
      queue.onUploaded = (prodId, lineId, url) {
        uploadedProduction = prodId;
        uploadedLine = lineId;
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
      expect(uploadedUrl, contains('prod-1/HAMLET/line-1.m4a'));
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
      expect(queue.failed, isEmpty);
      expect(abandoned, isNotNull);
      expect(abandoned!.lineId, 'line-1');
      expect(abandoned!.retryCount, 5);
    });

    test(
        're-recording while the old take is uploading keeps the new job '
        'and does not mark it uploaded with the stale URL', () async {
      final oldPath = await makeAudioFile('take-1');
      final newPath = await makeAudioFile('take-2');

      final uploadedUrls = <String>[];
      queue.onUploaded = (prodId, lineId, url) => uploadedUrls.add(url);

      uploader.ready = false;
      queue.enqueue(
        productionId: 'prod-1',
        characterName: 'HAMLET',
        lineId: 'line-1',
        localPath: oldPath,
        durationMs: 1000,
      );

      // While take-1 is in flight, the actor re-records the line.
      var replacedMidFlight = false;
      uploader.onUploadStarted = (job) {
        if (!replacedMidFlight && job.localPath == oldPath) {
          replacedMidFlight = true;
          queue.enqueue(
            productionId: 'prod-1',
            characterName: 'HAMLET',
            lineId: 'line-1',
            localPath: newPath,
            durationMs: 2000,
          );
        }
      };

      uploader.ready = true;
      await queue.processQueue();
      // Drain the microtask-scheduled follow-up pass for the new job.
      await Future<void>.delayed(Duration.zero);
      await queue.processQueue();

      // The NEW take must survive and upload; the stale take-1 URL must not
      // be reported as the upload result for the re-recorded line.
      expect(queue.pending, isEmpty);
      expect(queue.failed, isEmpty);
      expect(uploader.uploads.map((j) => j.localPath), contains(newPath));
      expect(uploadedUrls, isNotEmpty);
      // Exactly one onUploaded for the final state of the line, from take-2's
      // job (both takes share the same remote path, but the old in-flight job
      // must not have claimed it).
      expect(uploadedUrls, hasLength(1));
      expect(uploader.uploads.last.durationMs, 2000);
      expect(uploader.savedMetadataJobs.last.durationMs, 2000);
    });

    test('re-recording a permanently failed line re-queues it fresh',
        () async {
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
