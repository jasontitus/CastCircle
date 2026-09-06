// Validates KokoroOnnxService's request queue on macOS (the service is
// platform-neutral even though the app only routes to it on Android):
// sequential completion, prefetch-await semantics, and urgent-supersedes-stale
// cancellation — the behaviors behind the rehearsal pipelining fixes.
//
//   flutter test integration_test/kokoro_service_queue_macos_test.dart -d macos
//
// Stages the shipped pack into the app container's Documents/models dir
// (readable copy lives in .asr-eval, reachable via the debug sandbox
// exception), exactly where ModelManager looks.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:castcircle/data/services/kokoro_onnx_service.dart';
import 'package:castcircle/data/services/model_manager.dart';

/// Repo root for fixture/model staging paths. Relative default works when
/// tests run from the checkout root; override with
/// --dart-define=CASTCIRCLE_REPO=/path for other harnesses.
const _ccRepo = String.fromEnvironment('CASTCIRCLE_REPO', defaultValue: '.');

const _pack = '$_ccRepo/.asr-eval/kokoro-en-fp16-v1_0';

Future<void> _stagePack() async {
  final docs = (await getApplicationDocumentsDirectory()).path;
  final models = Directory('$docs/models')..createSync(recursive: true);
  final source = Directory(_pack);
  if (!source.existsSync()) {
    throw StateError('Kokoro fixture pack is missing at $_pack');
  }

  final dest = Directory('${models.path}/kokoro-en-fp16-v1_0');
  final entities = source.listSync(recursive: true, followLinks: false);
  final manifest = <String, int>{
    for (final entity in entities)
      if (entity is File)
        entity.path.substring(_pack.length + 1): entity.lengthSync(),
  };
  if (manifest.isEmpty) {
    throw StateError('Kokoro fixture pack at $_pack contains no files');
  }

  bool matchesManifest(Directory directory) {
    if (!directory.existsSync()) return false;
    final files = directory
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .toList();
    if (files.length != manifest.length) return false;
    return manifest.entries.every((entry) {
      final file = File('${directory.path}/${entry.key}');
      return file.existsSync() && file.lengthSync() == entry.value;
    });
  }

  // Always copy into a fresh sibling before swapping it in. File lengths are
  // enough to catch a failed copy, but never trusted to bless an old pack.

  final staging = Directory('${dest.path}.staging');
  final backup = Directory('${dest.path}.previous');
  if (staging.existsSync()) staging.deleteSync(recursive: true);
  if (backup.existsSync()) backup.deleteSync(recursive: true);
  staging.createSync(recursive: true);

  try {
    for (final entity in entities) {
      final relative = entity.path.substring(_pack.length + 1);
      final stagedPath = '${staging.path}/$relative';
      if (entity is Directory) {
        Directory(stagedPath).createSync(recursive: true);
      } else if (entity is File) {
        File(stagedPath).parent.createSync(recursive: true);
        entity.copySync(stagedPath);
      }
    }

    if (!matchesManifest(staging)) {
      throw StateError('Staged Kokoro fixture failed its file manifest');
    }

    if (dest.existsSync()) dest.renameSync(backup.path);
    try {
      staging.renameSync(dest.path);
    } catch (_) {
      if (!dest.existsSync() && backup.existsSync()) {
        backup.renameSync(dest.path);
      }
      rethrow;
    }
    if (backup.existsSync()) backup.deleteSync(recursive: true);
  } catch (_) {
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    rethrow;
  }
}

void _expectCanceledOrComplete(String? path, String label) {
  if (path == null) return;
  final file = File(path);
  expect(
    file.existsSync(),
    true,
    reason: '$label may complete before cancellation, but must return a file',
  );
  expect(
    file.lengthSync(),
    greaterThan(20000),
    reason: '$label returned truncated audio instead of a complete result',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test(
    'queue semantics: sequential, prefetch, urgent supersede',
    () async {
      await _stagePack();
      expect(
        await ModelManager.instance.isKokoroReady(),
        true,
        reason: 'staged pack not detected',
      );

      final svc = KokoroOnnxService.instance;
      expect(await svc.ensureStarted(), true);

      // 1. Basic synthesis.
      final p1 = await svc.synthesize('A first plain line.', voice: 'af_heart');
      expect(p1, isNotNull);
      expect(File(p1!).lengthSync(), greaterThan(20000));

      // 2. Queued pair (prefetch-style): both complete, in order.
      final results = <String>[];
      await Future.wait([
        svc
            .synthesize('The first of two queued lines.', voice: 'af_heart')
            .then((p) => results.add('a:${p != null}')),
        svc
            .synthesize('And the second, right behind it.', voice: 'am_adam')
            .then((p) => results.add('b:${p != null}')),
      ]);
      expect(results, ['a:true', 'b:true']);

      // 3. Urgent supersedes stale urgent once native generation is in flight.
      // A cancellation that lands after the final native poll may legitimately
      // return complete audio; only a truncated result is forbidden.
      final runId = DateTime.now().microsecondsSinceEpoch;
      final staleStarted = svc.nextGenerationStarted;
      final stale = svc.synthesize(
        'It is a truth universally acknowledged that a single man in '
        'possession of a good fortune must be in want of a wife, however '
        'little known the feelings or views of such a man may be on his '
        'first entering a neighbourhood. Queue probe $runId.',
        voice: 'af_heart',
        urgent: true,
      );
      await staleStarted.timeout(const Duration(seconds: 30));
      final sw = Stopwatch()..start();
      final urgent = await svc.synthesize(
        'The line that matters now.',
        voice: 'am_adam',
        urgent: true,
      );
      sw.stop();
      expect(urgent, isNotNull);
      final staleResult = await stale;
      _expectCanceledOrComplete(staleResult, 'stale urgent line');
      print(
        'PROBE: urgent completed in ${sw.elapsedMilliseconds}ms '
        '(stale ${staleResult == null ? 'aborted' : 'completed first'})',
      );

      // 4. An urgent line also jumps an in-flight PREFETCH. Synchronize on the
      // native start rather than assuming a fixed delay reaches that state.
      final prefetchStarted = svc.nextGenerationStarted;
      final prefetch = svc.synthesize(
        'However little known the feelings or views of such a man may be '
        'on his first entering a neighbourhood, this truth is so well fixed '
        'in the minds of the surrounding families. Prefetch probe $runId.',
        voice: 'bf_emma',
      );
      await prefetchStarted.timeout(const Duration(seconds: 30));
      final sw2 = Stopwatch()..start();
      final live = await svc.synthesize(
        'Quick — my cue.',
        voice: 'am_adam',
        urgent: true,
      );
      sw2.stop();
      expect(live, isNotNull);
      final prefetchResult = await prefetch;
      _expectCanceledOrComplete(prefetchResult, 'in-flight prefetch');
      print(
        'PROBE: urgent jumped prefetch in ${sw2.elapsedMilliseconds}ms '
        '(prefetch ${prefetchResult == null ? 'aborted' : 'completed first'})',
      );

      await svc.stop();
      print('PROBE: ALL OK');
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
