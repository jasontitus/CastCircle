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
const _ccRepo =
    String.fromEnvironment('CASTCIRCLE_REPO', defaultValue: '.');


const _pack =
    '$_ccRepo/.asr-eval/kokoro-en-fp16-v1_0';

Future<void> _stagePack() async {
  final docs = (await getApplicationDocumentsDirectory()).path;
  final dest = Directory('$docs/models/kokoro-en-fp16-v1_0');
  if (dest.existsSync()) return;
  dest.createSync(recursive: true);
  for (final f in Directory(_pack).listSync(recursive: true)) {
    final rel = f.path.substring(_pack.length + 1);
    if (f is Directory) {
      Directory('${dest.path}/$rel').createSync(recursive: true);
    } else if (f is File) {
      File('${dest.path}/$rel').parent.createSync(recursive: true);
      f.copySync('${dest.path}/$rel');
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('queue semantics: sequential, prefetch, urgent supersede', () async {
    await _stagePack();
    expect(await ModelManager.instance.isKokoroReady(), true,
        reason: 'staged pack not detected');

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

    // 3. Urgent supersedes stale urgent: the first (long) line aborts.
    final stale = svc.synthesize(
        'It is a truth universally acknowledged that a single man in '
        'possession of a good fortune must be in want of a wife, however '
        'little known the feelings or views of such a man may be on his '
        'first entering a neighbourhood.',
        voice: 'af_heart',
        urgent: true);
    await Future.delayed(const Duration(milliseconds: 200)); // mid-generate
    final sw = Stopwatch()..start();
    final urgent = await svc.synthesize('The line that matters now.',
        voice: 'am_adam', urgent: true);
    sw.stop();
    expect(urgent, isNotNull);
    expect(await stale, isNull, reason: 'stale urgent line must abort');
    print('PROBE: urgent completed in ${sw.elapsedMilliseconds}ms '
        '(stale aborted)');

    // 4. Urgent aborts an in-flight PREFETCH too (it re-synthesizes on
    // demand later; the live line must not wait behind it).
    final prefetch = svc.synthesize(
        'However little known the feelings or views of such a man may be '
        'on his first entering a neighbourhood, this truth is so well fixed '
        'in the minds of the surrounding families.',
        voice: 'bf_emma');
    await Future.delayed(const Duration(milliseconds: 200));
    final sw2 = Stopwatch()..start();
    final live = await svc.synthesize('Quick — my cue.',
        voice: 'am_adam', urgent: true);
    sw2.stop();
    expect(live, isNotNull);
    expect(await prefetch, isNull,
        reason: 'in-flight prefetch must yield to an urgent line');
    print('PROBE: urgent jumped prefetch in ${sw2.elapsedMilliseconds}ms');

    await svc.stop();
    print('PROBE: ALL OK');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
