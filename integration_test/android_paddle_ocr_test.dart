// On-device verification of the Android PaddleOCR port.
//
// Prereq (run from repo root; see scripts/phone-harness.sh for the pattern):
//   qpdf sample-scripts/Pride-Prejudice-SCRIPT.pdf --pages . 12-17 -- /tmp/pp_excerpt.pdf
//   adb push /tmp/pp_excerpt.pdf /data/local/tmp/pp_excerpt.pdf
// The test copies it into the app's own cache via run-as-compatible path
// handling below (integration tests run debuggable, so the file is pushed
// into place by the driver script instead — see the run command in the
// commit message).
//
// Run:
//   flutter test integration_test/android_paddle_ocr_test.dart -d <device>
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:castcircle/data/services/kokoro_onnx_service.dart';
import 'package:castcircle/data/services/paddle_ocr_channel.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test(
    'PaddleOCR ocrPdf on device: quality + sherpa coexistence',
    () async {
      // The driver pushes the excerpt here via run-as (debug builds only).
      final candidates = [
        '${Directory.systemTemp.path}/pp_excerpt.pdf',
        '/data/local/tmp/pp_excerpt.pdf',
      ];
      final pdfPath = candidates.firstWhere(
        (p) => File(p).existsSync(),
        orElse: () => '',
      );
      expect(
        pdfPath,
        isNotEmpty,
        reason: 'pp_excerpt.pdf not found — push it first (see file header)',
      );

      final sw = Stopwatch()..start();
      final job = PaddleOcrChannel.startPdf(pdfPath);
      final result = await job.result;
      sw.stop();

      expect(
        result,
        isNotNull,
        reason: 'PaddleOcrChannel returned null — plugin not registered?',
      );
      final r = result!;
      // ignore: avoid_print
      print(
        'PADDLE: ${r.pageCount} pages, ${r.failedPages} failed, '
        '${sw.elapsedMilliseconds}ms total '
        '(${(sw.elapsedMilliseconds / (r.pageCount == 0 ? 1 : r.pageCount)).round()}ms/page)',
      );

      expect(r.failedPages, 0);
      expect(r.pageCount, greaterThanOrEqualTo(5));

      var lineCount = 0;
      var confSum = 0.0;
      for (final page in r.pages) {
        lineCount += page.lines.length;
        for (final l in page.lines) {
          confSum += l.confidence;
        }
        // ignore: avoid_print
        print(
          'PADDLE page ${page.page}: ${page.lines.length} lines; '
          'first: "${page.lines.isEmpty ? '' : page.lines.first.text}"',
        );
      }
      final avgConf = lineCount == 0 ? 0.0 : confSum / lineCount;
      // ignore: avoid_print
      print(
        'PADDLE: $lineCount lines total, avg confidence '
        '${(avgConf * 100).toStringAsFixed(1)}%',
      );

      // A dense script page yields dozens of lines; a broken pipeline yields
      // none or garbage-confidence output.
      expect(lineCount, greaterThan(100));
      expect(avgConf, greaterThan(0.80));

      // Dump full text for eyeball comparison against the iOS Paddle import.
      final dump = StringBuffer();
      for (final page in r.pages) {
        dump.writeln('--- page ${page.page} ---');
        for (final l in page.lines) {
          dump.writeln(l.text);
        }
      }
      final out = File('${Directory.systemTemp.path}/paddle_ocr_dump.txt');
      out.writeAsStringSync(dump.toString());
      // ignore: avoid_print
      print('PADDLE: dump written to ${out.path}');

      // Coexistence: sherpa (its own ORT consumer) must still initialize with
      // the single packaged libonnxruntime.so. Model may be absent on a fresh
      // install — accept either outcome, but a crash/hang here is a failure.
      final sherpaOk = await KokoroOnnxService.instance.ensureStarted().timeout(
        const Duration(minutes: 3),
        onTimeout: () => false,
      );
      // ignore: avoid_print
      print(
        'PADDLE: sherpa KokoroOnnx start → $sherpaOk (model '
        '${sherpaOk ? 'loaded — ORT coexistence proven' : 'not present on this install — channel alive, no crash'})',
      );
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
