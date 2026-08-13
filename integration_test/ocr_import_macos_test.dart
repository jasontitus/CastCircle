import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:castcircle/data/services/script_import_service.dart';
import 'package:castcircle/data/models/script_models.dart';

/// Repo root for fixture/model staging paths. Relative default works when
/// tests run from the checkout root; override with
/// --dart-define=CASTCIRCLE_REPO=/path for other harnesses.
const _ccRepo =
    String.fromEnvironment('CASTCIRCLE_REPO', defaultValue: '.');


void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('macOS imports the P&P scan via PaddleOCR with a small review count', (t) async {
    // The reference 82-page image-only scan. It lives outside the app sandbox,
    // so copy it into the sandbox-accessible temp dir before importing — the
    // native PaddleOCR plugin (PDFKit) can only open files inside the container.
    // The full 82-page run through the real on-device PaddleOCR pipeline is slow
    // in debug ONNX (~8-10 s/page), so run this via `flutter drive` (no 12-minute
    // test-harness timeout), e.g.:
    //   flutter drive --driver=test_driver/integration_test.dart \
    //     --target=integration_test/ocr_import_macos_test.dart -d macos
    // Full 82-page image-only scan (under the sandbox-allowed repo root). Run
    // this via `flutter drive --profile` so the plugin's Swift image-processing
    // loops are optimized (≈ phone speed); debug-mode ONNX glue is ~8× slower.
    const src =
        '$_ccRepo/sample-scripts/Pride-Prejudice-SCRIPT.pdf';
    final tmp = await getTemporaryDirectory();
    await tmp.create(recursive: true);
    final pdf = p.join(tmp.path, 'pp_full.pdf');
    // Read-then-write (not File.copy): the sandbox permits reading the source
    // bytes but blocks the cross-container copy syscall.
    await File(pdf).writeAsBytes(await File(src).readAsBytes());

    final parsed = await ScriptImportService().importFromPdf(pdf);
    final dialogue =
        parsed.lines.where((l) => l.lineType == LineType.dialogue).length;
    final review = parsed.lines
        .where((l) => l.reviewStatus == OcrReviewStatus.review)
        .length;
    // ignore: avoid_print
    print(
        'MACOS IMPORT: dialogue=$dialogue characters=${parsed.characters.length} review=$review');
    expect(dialogue, greaterThan(800));
    // Device showed 1016/1127 flagged before the fix; expect a small list now.
    expect(review, lessThan(80));
  }, timeout: const Timeout(Duration(minutes: 20)));
}
