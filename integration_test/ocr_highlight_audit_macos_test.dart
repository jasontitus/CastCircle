import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/ocr_highlight_matcher.dart';
import 'package:castcircle/data/services/paddle_ocr_channel.dart';
import 'package:castcircle/data/services/script_import_service.dart';
import 'package:castcircle/data/services/vision_ocr_channel.dart';

/// Repo root for fixture paths; override with
/// --dart-define=CASTCIRCLE_REPO=/path.
const _ccRepo =
    String.fromEnvironment('CASTCIRCLE_REPO', defaultValue: '.');

/// End-to-end audit of the page-viewer highlight, on REAL page boundaries:
/// import the P&P scan exactly as the app does, then for every
/// review-flagged line ask the matcher to locate it among its assigned
/// page's OCR lines — i.e. precisely what the viewer does when the user
/// taps "View page".
///
/// Run:
///   flutter drive --profile --driver=test_driver/integration_test.dart \
///     --target=integration_test/ocr_highlight_audit_macos_test.dart -d macos
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('highlight can locate flagged lines on their pages',
      (t) async {
    const src = '$_ccRepo/sample-scripts/Pride-Prejudice-SCRIPT.pdf';
    final tmp = await getTemporaryDirectory();
    final pdf = p.join(tmp.path, 'pp_audit.pdf');
    await File(pdf).writeAsBytes(await File(src).readAsBytes());

    // 1. Per-page OCR, as the viewer's single-page call would return.
    final byPage = <int, List<OcrPageLine>>{};
    final paddle = await PaddleOcrChannel.ocrPdf(pdf);
    if (paddle != null) {
      for (final page in paddle.pages) {
        byPage[page.page] = [
          for (final l in page.lines)
            OcrPageLine(
                text: l.text, left: l.left, top: 0, width: l.width, height: 0),
        ];
      }
      // ignore: avoid_print
      print('ENGINE=paddle pages=${byPage.length}');
    } else {
      final vision = await VisionOcrChannel.ocrPdf(pdf);
      for (final page in vision?.pages ?? const []) {
        byPage[page.page] = [
          for (final l in page.lines)
            OcrPageLine(text: l.text, left: 0, top: 0, width: 1, height: 0),
        ];
      }
      // ignore: avoid_print
      print('ENGINE=vision pages=${byPage.length}');
    }
    expect(byPage, isNotEmpty, reason: 'need per-page OCR to audit');

    // 2. The real import (same call the app makes).
    final parsed = await ScriptImportService().importFromPdf(pdf);

    // 3. For every flagged line, can the viewer find it on its page?
    var flagged = 0, located = 0, foundNearby = 0, foundFar = 0, nowhere = 0;
    final examples = <String>[];
    for (final line in parsed.lines) {
      if (line.reviewStatus == OcrReviewStatus.ok) continue;
      final page = line.sourcePage;
      if (page == null) continue;
      flagged++;
      final onPage = byPage[page] ?? const <OcrPageLine>[];
      if (OcrHighlightMatcher.locate(line.text, onPage).isNotEmpty) {
        located++;
        continue;
      }
      // Where is it really? Neighbors first (off-by-one page assignment),
      // then anywhere.
      var found = -1;
      for (final d in [-1, 1, -2, 2]) {
        final probe = byPage[page + d];
        if (probe == null) continue;
        if (OcrHighlightMatcher.locate(line.text, probe).isNotEmpty) {
          found = page + d;
          break;
        }
      }
      if (found > 0) {
        foundNearby++;
      } else {
        for (final e in byPage.entries) {
          if (OcrHighlightMatcher.locate(line.text, e.value).isNotEmpty) {
            found = e.key;
            break;
          }
        }
        if (found > 0) {
          foundFar++;
        } else {
          nowhere++;
        }
      }
      if (examples.length < 10) {
        final txt = line.text;
        examples.add('p$page → ${found > 0 ? 'p$found' : 'NOWHERE'}: '
            '"${txt.length > 55 ? txt.substring(0, 55) : txt}"');
      }
    }

    // ignore: avoid_print
    print('AUDIT flagged=$flagged located=$located '
        '(${(100 * located / (flagged == 0 ? 1 : flagged)).toStringAsFixed(1)}%) '
        'nearbyPage=$foundNearby farPage=$foundFar nowhere=$nowhere');
    for (final e in examples) {
      // ignore: avoid_print
      print('MISS $e');
    }
    expect(flagged, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 30)));
}
