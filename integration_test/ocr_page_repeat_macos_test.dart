import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:castcircle/data/services/paddle_ocr_channel.dart';

const _ccRepo =
    String.fromEnvironment('CASTCIRCLE_REPO', defaultValue: '.');

/// Field: after removing the first flagged line, EVERY subsequent line in
/// the page viewer reported "Couldn't locate this line on the page" — the
/// signature of the single-page OCR call failing after its first use (the
/// viewer treats a null/failed result as "no match").
///
/// This drives ocrPage repeatedly the way stepping through flagged lines
/// does: same page twice, different pages, and two calls in flight at once.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ocrPage survives repeated and concurrent calls', (t) async {
    const src = '$_ccRepo/sample-scripts/Pride-Prejudice-SCRIPT.pdf';
    final tmp = await getTemporaryDirectory();
    final pdf = p.join(tmp.path, 'pp_repeat.pdf');
    await File(pdf).writeAsBytes(await File(src).readAsBytes());

    // 1. Sequential calls, mixing repeats and different pages.
    for (final page in [12, 12, 13, 14, 13, 20]) {
      final lines = await PaddleOcrChannel.ocrPage(pdf, page);
      // ignore: avoid_print
      print('SEQ page=$page lines=${lines?.length}');
      expect(lines, isNotNull, reason: 'ocrPage returned null for p$page');
      expect(lines, isNotEmpty, reason: 'ocrPage found nothing on p$page');
    }

    // 2. Concurrent calls — stepping fast fires overlapping requests.
    final results = await Future.wait([
      PaddleOcrChannel.ocrPage(pdf, 15),
      PaddleOcrChannel.ocrPage(pdf, 16),
      PaddleOcrChannel.ocrPage(pdf, 17),
    ]);
    for (var i = 0; i < results.length; i++) {
      // ignore: avoid_print
      print('CONC ${15 + i} lines=${results[i]?.length}');
      expect(results[i], isNotNull, reason: 'concurrent call ${15 + i} failed');
      expect(results[i], isNotEmpty);
    }

    // 3. Rects must be usable: normalized, non-degenerate.
    final lines = (await PaddleOcrChannel.ocrPage(pdf, 12))!;
    final withRects =
        lines.where((l) => l.height > 0 && l.width > 0).length;
    // ignore: avoid_print
    print('RECTS $withRects of ${lines.length} lines have a usable rect');
    expect(withRects, greaterThan(lines.length ~/ 2),
        reason: 'most lines need a real bounding rect to highlight');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
