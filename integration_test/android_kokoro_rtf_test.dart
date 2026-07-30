// On-phone Kokoro synthesis speed: fp32 v1.0 vs int8 v1.0.
// The Mac showed int8 10× SLOWER than fp32 (ORT quantized-kernel fallback);
// this measures whether Android ARM behaves the same before picking the
// archive the app should download.
//
// Model dirs are sideloaded (see android_live_matching_test.dart recipe) to
//   <documents>/models/kokoro_eval/{fp32,int8}/
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

const _line =
    'You must allow me to tell you how ardently I admire and love you.';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('kokoro rtf on device', () async {
    sherpa.initBindings();
    final docs = (await getApplicationDocumentsDirectory()).path;
    final base = '$docs/models/kokoro_eval';

    // Sideload wait (flutter test reinstalls the app, so files land mid-run).
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(minutes: 6)) {
      if (File('$base/fp32/model.onnx').existsSync() &&
          File('$base/fp16/model.fp16.onnx').existsSync() &&
          File('$base/fp16/READY').existsSync()) {
        break;
      }
      await Future.delayed(const Duration(seconds: 3));
    }
    print('PROBE: models present after ${sw.elapsed}');

    for (final (name, dir, file) in [
      ('fp32-v1_0', '$base/fp32', 'model.onnx'),
      // Our weight-only fp16 conversion (int8 was eliminated: audibly worse
      // and slower than fp32 on both Mac and this phone).
      ('fp16-v1_0', '$base/fp16', 'model.fp16.onnx'),
    ]) {
      for (final threads in [2, 4]) {
        final tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
          model: sherpa.OfflineTtsModelConfig(
            kokoro: sherpa.OfflineTtsKokoroModelConfig(
              model: '$dir/$file',
              voices: '$dir/voices.bin',
              tokens: '$dir/tokens.txt',
              dataDir: '$dir/espeak-ng-data',
              dictDir: '$dir/dict',
              lexicon: '$dir/lexicon-us-en.txt,$dir/lexicon-gb-en.txt',
            ),
            numThreads: threads,
            debug: false,
          ),
        ));
        // Warm-up then timed run.
        tts.generate(text: 'Hello there.', sid: 3, speed: 1.0);
        final t = Stopwatch()..start();
        final audio = tts.generate(text: _line, sid: 3, speed: 1.0);
        t.stop();
        final dur = audio.samples.length / audio.sampleRate;
        print('PROBE: $name threads=$threads '
            'rtf=${(t.elapsedMilliseconds / 1000 / dur).toStringAsFixed(2)} '
            'dur=${dur.toStringAsFixed(1)}s '
            'synth=${(t.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
        tts.free();
      }
    }
    print('PROBE: DONE');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
