import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/recording_sync_service.dart';

/// In-memory stand-in for the Supabase backend (Storage + recordings table),
/// shared between "devices" in tests the way the real cloud is shared
/// between cast members.
class FakeCloud implements RecordingCloud {
  bool ready = true;
  String? userId;

  /// recordings table rows
  final List<Map<String, dynamic>> rows = [];

  /// storage: object path → bytes
  final Map<String, List<int>> storage = {};

  int downloadCount = 0;
  int uploadSequence = 0;

  @override
  bool get isReady => ready;

  @override
  String? get currentUserId => userId;

  @override
  Future<List<Map<String, dynamic>>> fetchRecordings(
    String productionId,
  ) async {
    return rows
        .where((r) => r['production_id'] == productionId)
        .map(Map<String, dynamic>.from)
        .toList();
  }

  @override
  Future<String> uploadRecording({
    required String productionId,
    required String characterName,
    required String lineId,
    required File audioFile,
  }) async {
    final path = '$productionId/$characterName/$lineId-${++uploadSequence}.m4a';
    storage[path] = await audioFile.readAsBytes();
    return 'https://fake.supabase.co/storage/v1/object/public/recordings/'
        '${Uri.encodeFull(path)}';
  }

  @override
  Future<String?> saveRecordingMetadata({
    required String productionId,
    required String lineId,
    required String audioUrl,
    required int durationMs,
    DateTime? recordedAt,
  }) async {
    final activeUserId = userId;
    if (activeUserId == null) throw StateError('No active fake user');
    final previousIndex = rows.indexWhere(
      (r) =>
          r['production_id'] == productionId &&
          r['line_id'] == lineId &&
          r['user_id'] == activeUserId,
    );
    final previousUrl = previousIndex < 0
        ? null
        : rows[previousIndex]['audio_url'] as String?;
    if (previousIndex >= 0) rows.removeAt(previousIndex);
    rows.add({
      'production_id': productionId,
      'line_id': lineId,
      'user_id': activeUserId,
      'audio_url': audioUrl,
      'duration_ms': durationMs,
      'recorded_at': (recordedAt ?? DateTime.now()).toUtc().toIso8601String(),
    });
    return previousUrl;
  }

  String pathForUrl(String audioUrl) {
    const marker = '/recordings/';
    final index = audioUrl.indexOf(marker);
    return index >= 0
        ? Uri.decodeFull(audioUrl.substring(index + marker.length))
        : audioUrl;
  }

  @override
  Future<void> deleteRecordingByUrl(String audioUrl) async {
    storage.remove(pathForUrl(audioUrl));
  }

  @override
  Future<Uint8List> downloadRecordingByUrl(String audioUrl) async {
    downloadCount++;
    final path = pathForUrl(audioUrl);
    final bytes = storage[path];
    if (bytes == null) {
      throw Exception('Object not found: $path');
    }
    return Uint8List.fromList(bytes);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const productionId = 'prod-1';
  late Directory tempDir;
  late FakeCloud cloud;
  late Map<RecordingSyncService, int> runTokens;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('recording_sync_test');
    cloud = FakeCloud();
    runTokens = {};
  });

  tearDown(() async {
    // Realtime/background downloads can still be writing into tempDir as the
    // test ends; macOS throws ENOTEMPTY if the recursive delete races them.
    // Retry briefly, then give up.
    for (var attempt = 0; ; attempt++) {
      try {
        await tempDir.delete(recursive: true);
        break;
      } on FileSystemException {
        if (attempt >= 10) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  /// Create a sync service representing one cast member's device.
  RecordingSyncService deviceFor(String name) {
    final dir = Directory('${tempDir.path}/$name/recording_cache')
      ..createSync(recursive: true);
    return RecordingSyncService.forTesting(cloud, cacheDirectory: dir.path);
  }

  int runTokenFor(RecordingSyncService service) => runTokens.putIfAbsent(
    service,
    () => service.activateProduction(productionId),
  );

  /// Write a local recording file and return its model.
  Future<Recording> makeLocalRecording(
    String device,
    String lineId,
    String character, {
    DateTime? recordedAt,
    List<int>? bytes,
  }) async {
    final dir = Directory('${tempDir.path}/$device/recordings')
      ..createSync(recursive: true);
    final file = File('${dir.path}/$lineId.m4a');
    await file.writeAsBytes(bytes ?? List.filled(128, 42));
    return Recording(
      id: 'rec_$lineId',
      scriptLineId: lineId,
      character: character,
      localPath: file.path,
      durationMs: 2500,
      recordedAt: recordedAt ?? DateTime(2026, 5, 1, 10),
    );
  }

  group('upload catch-up', () {
    test(
      'uploads local recordings missing from cloud and reports URLs',
      () async {
        final service = deviceFor('actorA');
        cloud.userId = 'user-a';
        final recording = await makeLocalRecording(
          'actorA',
          'line-1',
          'HAMLET',
        );

        final uploadedUrls = <String, String>{};

        await service.syncForProduction(
          productionId: productionId,
          runToken: runTokenFor(service),
          localRecordings: {'line-1': recording},
          onLocalUploaded:
              (uploadedProductionId, lineId, recordingId, url) async {
                expect(uploadedProductionId, productionId);
                expect(recordingId, recording.id);
                uploadedUrls[lineId] = url;
              },
        );

        expect(cloud.rows, hasLength(1));
        final row = cloud.rows.single;
        expect(row['line_id'], 'line-1');
        expect(row['user_id'], 'user-a');
        // recordedAt must be the actual recording time, not upload time
        expect(
          DateTime.parse(row['recorded_at'] as String).toLocal(),
          recording.recordedAt,
        );
        final remoteUrl = row['audio_url'] as String;
        expect(uploadedUrls['line-1'], remoteUrl);
        expect(cloud.storage[cloud.pathForUrl(remoteUrl)], isNotNull);
      },
    );

    test(
      'uploads when a remoteUrl hint has no authoritative cloud row',
      () async {
        final service = deviceFor('actorA');
        cloud.userId = 'user-a';
        final recording = await makeLocalRecording(
          'actorA',
          'line-1',
          'HAMLET',
        );

        await service.syncForProduction(
          productionId: productionId,
          runToken: runTokenFor(service),
          localRecordings: {
            'line-1': recording.copyWith(remoteUrl: 'https://already.up/x.m4a'),
          },
        );

        expect(cloud.rows, hasLength(1));
        expect(cloud.storage, hasLength(1));
      },
    );

    test('skips upload when cloud copy is same age or newer', () async {
      final service = deviceFor('actorA');
      cloud.userId = 'user-a';
      final recording = await makeLocalRecording(
        'actorA',
        'line-1',
        'HAMLET',
        recordedAt: DateTime(2026, 5, 1, 10),
      );

      // Cloud already has a newer take (e.g. recorded on another device)
      await cloud.saveRecordingMetadata(
        productionId: productionId,
        lineId: 'line-1',
        audioUrl: 'https://fake/recordings/$productionId/HAMLET/line-1.m4a',
        durationMs: 2000,
        recordedAt: DateTime(2026, 5, 2, 10),
      );

      await service.syncForProduction(
        productionId: productionId,
        runToken: runTokenFor(service),
        localRecordings: {'line-1': recording},
      );

      expect(cloud.storage, isEmpty); // nothing uploaded
    });

    test(
      're-uploads when the local take is newer (re-record recovery)',
      () async {
        final service = deviceFor('actorA');
        cloud.userId = 'user-a';

        // Old cloud copy from a previous run
        await cloud.saveRecordingMetadata(
          productionId: productionId,
          lineId: 'line-1',
          audioUrl:
              'https://fake.supabase.co/storage/v1/object/public/'
              'recordings/$productionId/HAMLET/line-1.m4a',
          durationMs: 2000,
          recordedAt: DateTime(2026, 5, 1, 10),
        );

        // Newer local re-record whose queue upload was lost (e.g. app killed)
        final newTake = await makeLocalRecording(
          'actorA',
          'line-1',
          'HAMLET',
          recordedAt: DateTime(2026, 5, 3, 10),
          bytes: List.filled(64, 9),
        );

        await service.syncForProduction(
          productionId: productionId,
          runToken: runTokenFor(service),
          localRecordings: {'line-1': newTake},
        );

        // Upsert replaced the row, not duplicated it, and cleanup retained the
        // newly uploaded unique object rather than deleting it as superseded.
        final lineRows = cloud.rows.where((r) => r['line_id'] == 'line-1');
        expect(lineRows, hasLength(1));
        final remoteUrl = lineRows.single['audio_url'] as String;
        expect(cloud.storage[cloud.pathForUrl(remoteUrl)], List.filled(64, 9));
        expect(
          DateTime.parse(lineRows.single['recorded_at'] as String).toLocal(),
          DateTime(2026, 5, 3, 10),
        );
      },
    );
  });

  group('download for rehearsal', () {
    test('downloads other cast members\' recordings into the cache', () async {
      // Actor A records and uploads
      final deviceA = deviceFor('actorA');
      cloud.userId = 'user-a';
      final aTake = await makeLocalRecording(
        'actorA',
        'line-1',
        'HAMLET',
        bytes: [1, 2, 3, 4],
      );
      await deviceA.syncForProduction(
        productionId: productionId,
        runToken: runTokenFor(deviceA),
        localRecordings: {'line-1': aTake},
      );

      // Actor B opens the production on their device
      final deviceB = deviceFor('actorB');
      cloud.userId = 'user-b';
      final readyLines = <String>[];

      final downloaded = await deviceB.syncForProduction(
        productionId: productionId,
        runToken: runTokenFor(deviceB),
        localRecordings: {},
        myUserId: 'user-b',
        onRecordingReady: (readyProductionId, lineId, path) {
          expect(readyProductionId, productionId);
          readyLines.add(lineId);
        },
      );

      expect(downloaded, 1);
      expect(readyLines, ['line-1']);

      // B can now resolve A's recording for playback, keyed by line id
      final cached = await deviceB.getCachedRecordings(productionId);
      expect(cached, contains('line-1'));
      expect(cached['line-1']!.character, 'HAMLET');
      expect(File(cached['line-1']!.localPath).readAsBytesSync(), [1, 2, 3, 4]);
    });

    test('cache survives an app restart: hydrates from manifest, plays '
        'offline, and skips re-downloads online', () async {
      // Actor A uploads; actor B downloads once.
      final deviceA = deviceFor('actorA');
      cloud.userId = 'user-a';
      final aTake = await makeLocalRecording(
        'actorA',
        'line-1',
        'HAMLET',
        bytes: [9, 9, 9],
      );
      await deviceA.syncForProduction(
        productionId: productionId,
        runToken: runTokenFor(deviceA),
        localRecordings: {'line-1': aTake},
      );
      final deviceB = deviceFor('actorB');
      cloud.userId = 'user-b';
      await deviceB.syncForProduction(
        productionId: productionId,
        runToken: runTokenFor(deviceB),
        localRecordings: {},
        myUserId: 'user-b',
      );
      await deviceB.flushManifest();
      final downloadsBefore = cloud.downloadCount;

      // "Restart": fresh service instance, SAME cache directory, OFFLINE.
      final deviceBRestarted = RecordingSyncService.forTesting(
        cloud,
        cacheDirectory: '${tempDir.path}/actorB/recording_cache',
      );
      cloud.ready = false;
      await deviceBRestarted.hydrateCache();
      final cached = await deviceBRestarted.getCachedRecordings(productionId);
      expect(
        cached,
        contains('line-1'),
        reason: 'downloaded recording must be playable offline after restart',
      );
      expect(File(cached['line-1']!.localPath).readAsBytesSync(), [9, 9, 9]);

      // Back online: sync must not re-download the cached file.
      cloud.ready = true;
      final downloaded = await deviceBRestarted.syncForProduction(
        productionId: productionId,
        runToken: runTokenFor(deviceBRestarted),
        localRecordings: {},
        myUserId: 'user-b',
      );
      expect(downloaded, 0);
      expect(cloud.downloadCount, downloadsBefore);
    });

    test('cached recordings do not leak into OTHER productions', () async {
      // Actor A uploads to prod-1; actor B downloads them.
      final deviceA = deviceFor('actorA');
      cloud.userId = 'user-a';
      final aTake = await makeLocalRecording('actorA', 'line-1', 'HAMLET');
      await deviceA.syncForProduction(
        productionId: productionId,
        runToken: runTokenFor(deviceA),
        localRecordings: {'line-1': aTake},
      );
      final deviceB = deviceFor('actorB');
      cloud.userId = 'user-b';
      await deviceB.syncForProduction(
        productionId: productionId,
        runToken: runTokenFor(deviceB),
        localRecordings: {},
        myUserId: 'user-b',
      );
      expect(
        await deviceB.getCachedRecordings(productionId),
        contains('line-1'),
      );

      // A brand-new production on the same device must see NONE of them —
      // this leak made a fresh production flag every cached recording as
      // "orphaned" (the "11 shared recordings don't match" banner).
      expect(await deviceB.getCachedRecordings('prod-brand-new'), isEmpty);

      // Same across a restart (manifest round-trip preserves the scoping).
      await deviceB.flushManifest();
      final restarted = RecordingSyncService.forTesting(
        cloud,
        cacheDirectory: '${tempDir.path}/actorB/recording_cache',
      );
      await restarted.hydrateCache();
      expect(
        await restarted.getCachedRecordings(productionId),
        contains('line-1'),
      );
      expect(await restarted.getCachedRecordings('prod-brand-new'), isEmpty);
    });

    test('does not re-download an up-to-date cached recording', () async {
      final deviceA = deviceFor('actorA');
      cloud.userId = 'user-a';
      final aTake = await makeLocalRecording('actorA', 'line-1', 'HAMLET');
      await deviceA.syncForProduction(
        productionId: productionId,
        runToken: runTokenFor(deviceA),
        localRecordings: {'line-1': aTake},
      );

      final deviceB = deviceFor('actorB');
      cloud.userId = 'user-b';
      await deviceB.syncForProduction(
        productionId: productionId,
        runToken: runTokenFor(deviceB),
        localRecordings: {},
      );
      final downloadsAfterFirst = cloud.downloadCount;

      final downloaded = await deviceB.syncForProduction(
        productionId: productionId,
        runToken: runTokenFor(deviceB),
        localRecordings: {},
      );

      expect(downloaded, 0);
      expect(cloud.downloadCount, downloadsAfterFirst);
    });

    test(
      're-downloads when the cloud copy is newer (re-record propagates)',
      () async {
        final deviceA = deviceFor('actorA');
        cloud.userId = 'user-a';
        final firstTake = await makeLocalRecording(
          'actorA',
          'line-1',
          'HAMLET',
          recordedAt: DateTime(2026, 5, 1, 10),
          bytes: [1, 1, 1],
        );
        await deviceA.syncForProduction(
          productionId: productionId,
          runToken: runTokenFor(deviceA),
          localRecordings: {'line-1': firstTake},
        );

        final deviceB = deviceFor('actorB');
        cloud.userId = 'user-b';
        await deviceB.syncForProduction(
          productionId: productionId,
          runToken: runTokenFor(deviceB),
          localRecordings: {},
        );
        expect(
          (await deviceB.getCachedRecordings(productionId))['line-1'],
          isNotNull,
        );

        // Actor A re-records the line
        cloud.userId = 'user-a';
        final secondTake = await makeLocalRecording(
          'actorA',
          'line-1',
          'HAMLET',
          recordedAt: DateTime(2026, 5, 2, 10),
          bytes: [2, 2, 2],
        );
        await deviceA.syncForProduction(
          productionId: productionId,
          runToken: runTokenFor(deviceA),
          localRecordings: {'line-1': secondTake},
        );

        // Actor B's next sync picks up the new take
        cloud.userId = 'user-b';
        final downloaded = await deviceB.syncForProduction(
          productionId: productionId,
          runToken: runTokenFor(deviceB),
          localRecordings: {},
        );

        expect(downloaded, 1);
        expect(
          File(
            (await deviceB.getCachedRecordings(
              productionId,
            ))['line-1']!.localPath,
          ).readAsBytesSync(),
          [2, 2, 2],
        );
      },
    );

    test('re-downloads when the cached file was deleted from disk', () async {
      final deviceA = deviceFor('actorA');
      cloud.userId = 'user-a';
      final aTake = await makeLocalRecording('actorA', 'line-1', 'HAMLET');
      await deviceA.syncForProduction(
        productionId: productionId,
        runToken: runTokenFor(deviceA),
        localRecordings: {'line-1': aTake},
      );

      final deviceB = deviceFor('actorB');
      cloud.userId = 'user-b';
      await deviceB.syncForProduction(
        productionId: productionId,
        runToken: runTokenFor(deviceB),
        localRecordings: {},
      );

      // Simulate the OS (or user) clearing the cache file
      final cachedPath = deviceB.getCachedPath(productionId, 'line-1')!;
      File(cachedPath).deleteSync();
      expect(
        await deviceB.getCachedRecordings(productionId),
        isNot(contains('line-1')),
      );

      final downloaded = await deviceB.syncForProduction(
        productionId: productionId,
        runToken: runTokenFor(deviceB),
        localRecordings: {},
      );

      expect(downloaded, 1);
      expect(
        await deviceB.getCachedRecordings(productionId),
        contains('line-1'),
      );
    });

    test(
      'keeps my own recording rather than downloading someone else\'s',
      () async {
        // Another actor somehow recorded my line too
        final deviceA = deviceFor('actorA');
        cloud.userId = 'user-a';
        final aTake = await makeLocalRecording('actorA', 'line-1', 'HAMLET');
        await deviceA.syncForProduction(
          productionId: productionId,
          runToken: runTokenFor(deviceA),
          localRecordings: {'line-1': aTake},
        );

        // I already have my own local take of line-1
        final deviceB = deviceFor('actorB');
        cloud.userId = 'user-b';
        final myTake = await makeLocalRecording(
          'actorB',
          'line-1',
          'HAMLET',
          recordedAt: DateTime(2026, 6, 1),
        );

        final downloaded = await deviceB.syncForProduction(
          productionId: productionId,
          runToken: runTokenFor(deviceB),
          localRecordings: {
            'line-1': myTake.copyWith(remoteUrl: 'https://up/x.m4a'),
          },
        );

        expect(downloaded, 0);
      },
    );
  });

  group('realtime updates', () {
    test('downloads a new recording announced via realtime', () async {
      // Actor A uploads
      final deviceA = deviceFor('actorA');
      cloud.userId = 'user-a';
      final aTake = await makeLocalRecording(
        'actorA',
        'line-9',
        'OPHELIA',
        bytes: [9, 9],
      );
      await deviceA.syncForProduction(
        productionId: productionId,
        runToken: runTokenFor(deviceA),
        localRecordings: {'line-9': aTake},
      );
      final row = cloud.rows.single;

      // Actor B receives the realtime INSERT payload
      final deviceB = deviceFor('actorB');
      cloud.userId = 'user-b';
      final readyLines = <String>[];

      await deviceB.handleRealtimeRecording(
        Map<String, dynamic>.from(row),
        productionId: productionId,
        runToken: runTokenFor(deviceB),
        myUserId: 'user-b',
        onRecordingReady: (readyProductionId, lineId, path) {
          expect(readyProductionId, productionId);
          readyLines.add(lineId);
        },
      );

      expect(readyLines, ['line-9']);
      final cached = (await deviceB.getCachedRecordings(
        productionId,
      ))['line-9'];
      expect(cached, isNotNull);
      expect(cached!.character, 'OPHELIA');
      expect(File(cached.localPath).readAsBytesSync(), [9, 9]);
    });

    test('ignores realtime events for my own recordings', () async {
      final deviceA = deviceFor('actorA');
      cloud.userId = 'user-a';

      await deviceA.handleRealtimeRecording(
        {
          'line_id': 'line-1',
          'user_id': 'user-a',
          'audio_url':
              'https://fake/recordings/$productionId/HAMLET/line-1.m4a',
          'recorded_at': DateTime(2026, 5, 1).toIso8601String(),
          'duration_ms': 1000,
        },
        productionId: productionId,
        runToken: runTokenFor(deviceA),
        myUserId: 'user-a',
      );

      expect(cloud.downloadCount, 0);
      expect(await deviceA.getCachedRecordings(productionId), isEmpty);
    });
  });

  group('character extraction from storage URL', () {
    test('parses character segment after production id', () {
      final url =
          'https://x.supabase.co/storage/v1/object/public/recordings/'
          'prod-1/HAMLET/line-1.m4a';
      expect(
        RecordingSyncService.extractCharacterFromUrl(url, 'prod-1'),
        'HAMLET',
      );
    });

    test('decodes percent-encoded names with spaces', () {
      final url =
          'https://x.supabase.co/storage/v1/object/public/recordings/'
          'prod-1/LADY%20MACBETH/line-1.m4a';
      expect(
        RecordingSyncService.extractCharacterFromUrl(url, 'prod-1'),
        'LADY MACBETH',
      );
    });

    test('falls back to unknown for malformed URLs', () {
      expect(
        RecordingSyncService.extractCharacterFromUrl('', 'prod-1'),
        'unknown',
      );
      expect(
        RecordingSyncService.extractCharacterFromUrl(
          'https://x.co/other/path.m4a',
          'prod-1',
        ),
        'unknown',
      );
    });
  });

  group('end-to-end: save lines after a run, castmate hears them', () {
    test('full round trip across two devices', () async {
      // ── Actor A finishes a run-through; captured lines were saved
      //    locally and (as if the queue drained) synced to the cloud.
      final deviceA = deviceFor('actorA');
      cloud.userId = 'user-a';
      final lines = {
        'line-1': await makeLocalRecording(
          'actorA',
          'line-1',
          'HAMLET',
          bytes: [10],
        ),
        'line-2': await makeLocalRecording(
          'actorA',
          'line-2',
          'HAMLET',
          bytes: [20],
        ),
        'line-3': await makeLocalRecording(
          'actorA',
          'line-3',
          'HAMLET',
          bytes: [30],
        ),
      };
      await deviceA.syncForProduction(
        productionId: productionId,
        runToken: runTokenFor(deviceA),
        localRecordings: lines,
      );
      expect(cloud.rows, hasLength(3));

      // ── Actor B opens the production and runs the same scene.
      final deviceB = deviceFor('actorB');
      cloud.userId = 'user-b';
      final downloaded = await deviceB.syncForProduction(
        productionId: productionId,
        runToken: runTokenFor(deviceB),
        localRecordings: {},
      );
      expect(downloaded, 3);

      // The understudy/castmate map used by the rehearsal playback chain
      // resolves every one of Actor A's lines to a playable local file.
      final castmateRecordings = await deviceB.getCachedRecordings(
        productionId,
      );
      for (final lineId in lines.keys) {
        final rec = castmateRecordings[lineId];
        expect(rec, isNotNull, reason: 'missing recording for $lineId');
        expect(rec!.character, 'HAMLET');
        expect(File(rec.localPath).existsSync(), isTrue);
      }
      expect(File(castmateRecordings['line-2']!.localPath).readAsBytesSync(), [
        20,
      ]);

      // ── Actor A re-records one line in the studio; B picks it up.
      cloud.userId = 'user-a';
      final retake = await makeLocalRecording(
        'actorA',
        'line-2',
        'HAMLET',
        recordedAt: DateTime(2026, 6, 1),
        bytes: [99],
      );
      await deviceA.syncForProduction(
        productionId: productionId,
        runToken: runTokenFor(deviceA),
        localRecordings: {'line-2': retake},
      );

      cloud.userId = 'user-b';
      await deviceB.syncForProduction(
        productionId: productionId,
        runToken: runTokenFor(deviceB),
        localRecordings: {},
      );
      expect(
        File(
          (await deviceB.getCachedRecordings(
            productionId,
          ))['line-2']!.localPath,
        ).readAsBytesSync(),
        [99],
      );
    });
  });
}
