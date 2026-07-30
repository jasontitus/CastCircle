// On-phone verification of the wired Android Kokoro engine:
// ModelManager pack discovery → KokoroOnnxService isolate → WAV out,
// exactly the calls TtsService makes during rehearsal.
//
// Sideload the shipped pack (flutter test wipes app data, so push mid-run):
//   adb push .asr-eval/kokoro-en-fp16-v1_0 /data/local/tmp/kpack
//   adb shell run-as com.tiltastech.castcircle sh -c \
//     'mkdir -p app_flutter/models && cp -r /data/local/tmp/kpack \
//      app_flutter/models/kokoro-en-fp16-v1_0'
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:castcircle/data/services/kokoro_onnx_service.dart';
import 'package:castcircle/data/services/model_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('kokoro onnx service synthesizes on device', () async {
    // Wait for the sideload.
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(minutes: 6)) {
      if (await ModelManager.instance.isKokoroReady()) break;
      await Future.delayed(const Duration(seconds: 3));
    }
    print('PROBE: pack ready after ${sw.elapsed}');
    expect(await ModelManager.instance.isKokoroReady(), true,
        reason: 'sideloaded pack not detected');

    final svc = KokoroOnnxService.instance;
    final t0 = Stopwatch()..start();
    expect(await svc.ensureStarted(), true, reason: 'engine must start');
    print('PROBE: engine started in ${t0.elapsedMilliseconds}ms');

    for (final voice in ['af_heart', 'bm_george']) {
      final t = Stopwatch()..start();
      final path = await svc.synthesize(
          'You must allow me to tell you how ardently I admire and love you.',
          voice: voice);
      t.stop();
      expect(path, isNotNull, reason: '$voice synthesis failed');
      final f = File(path!);
      expect(f.existsSync(), true);
      final bytes = f.lengthSync();
      // 24 kHz 16-bit mono: >1 s of audio ≈ >48 KB.
      expect(bytes, greaterThan(48000),
          reason: '$voice produced too little audio ($bytes B)');
      print('PROBE: $voice → ${(bytes / 1000).round()} KB '
          'in ${(t.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
    }

    // Prefetch-style concurrency: two requests queued at once both complete.
    final both = await Future.wait([
      svc.synthesize('The first of two queued lines.', voice: 'af_heart'),
      svc.synthesize('And the second, right behind it.', voice: 'am_adam'),
    ]);
    expect(both.whereType<String>().length, 2, reason: 'queued synth failed');
    print('PROBE: queued pair OK');

    await svc.stop();
    print('PROBE: ALL OK');
  }, timeout: const Timeout(Duration(minutes: 15)));
}
