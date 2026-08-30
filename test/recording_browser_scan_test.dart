import 'dart:async';

import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/features/recording_studio/recordings_browser_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Recording recording(String id) => Recording(
    id: id,
    scriptLineId: 'line-$id',
    character: 'ACTOR',
    localPath: '/recordings/$id.m4a',
    durationMs: 1000,
    recordedAt: DateTime.utc(2026),
  );

  test('recording scans bound concurrent filesystem probes', () async {
    final recordings = List.generate(20, (index) => recording('$index'));
    var active = 0;
    var peak = 0;

    final result = await scanRecordingFiles(
      recordings,
      (recording) async {
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(Duration.zero);
        active--;
        return recording.localPath;
      },
      isCurrent: () => true,
      maxConcurrent: 3,
    );

    expect(result, hasLength(20));
    expect(result!.values, everyElement(isTrue));
    expect(peak, lessThanOrEqualTo(3));
  });

  test('older scan completion is discarded after a newer generation', () async {
    final oldCompletion = Completer<String?>();
    var generation = 1;
    final oldScan = scanRecordingFiles(
      [recording('old')],
      (_) => oldCompletion.future,
      isCurrent: () => generation == 1,
    );

    generation = 2;
    final newResult = await scanRecordingFiles(
      [recording('new')],
      (recording) async => recording.localPath,
      isCurrent: () => generation == 2,
    );
    oldCompletion.complete('/recordings/old.m4a');
    final oldResult = await oldScan;

    expect(newResult, {'new': true});
    expect(oldResult, isNull);
  });

  test('recording cache indexes preserve basename and line-id lookup', () {
    const index = RecordingCacheIndex(
      byBasename: {'legacy-name.m4a': '/cache/prod/line-1.m4a'},
      byLineId: {'line-1': '/cache/prod/line-1.m4a'},
    );

    expect(index.byBasename['legacy-name.m4a'], '/cache/prod/line-1.m4a');
    expect(index.byLineId['line-1'], '/cache/prod/line-1.m4a');
  });
}
