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
const _ccRepo = String.fromEnvironment('CASTCIRCLE_REPO', defaultValue: '.');

({
  Map<int, List<OcrMatchCandidate>> preparedByPage,
  Map<String, Set<int>> pagesByToken,
  Map<String, Set<int>> pagesByPrefix,
})
_indexPages(Map<int, List<OcrPageLine>> byPage) {
  final preparedByPage = <int, List<OcrMatchCandidate>>{};
  final pagesByToken = <String, Set<int>>{};
  final pagesByPrefix = <String, Set<int>>{};
  for (final page in byPage.entries) {
    final prepared = OcrHighlightMatcher.prepareCandidates([
      for (final line in page.value) line.text,
    ]);
    preparedByPage[page.key] = prepared;
    for (final candidate in prepared) {
      for (final (text, tokens) in {
        (candidate.full, candidate.fullTokens),
        (candidate.body, candidate.bodyTokens),
      }) {
        for (final token in tokens) {
          pagesByToken.putIfAbsent(token, () => <int>{}).add(page.key);
        }
        if (text.length >= 12) {
          pagesByPrefix
              .putIfAbsent(text.substring(0, 12), () => <int>{})
              .add(page.key);
        }
      }
    }
  }
  return (
    preparedByPage: preparedByPage,
    pagesByToken: pagesByToken,
    pagesByPrefix: pagesByPrefix,
  );
}

bool _containsWord(String haystack, String needle) {
  var from = 0;
  while (true) {
    final index = haystack.indexOf(needle, from);
    if (index < 0) return false;
    final end = index + needle.length;
    if ((index == 0 || haystack[index - 1] == ' ') &&
        (end == haystack.length || haystack[end] == ' ')) {
      return true;
    }
    from = index + 1;
  }
}

bool _preparedLocates(String target, List<OcrMatchCandidate> candidates) {
  final normalized = OcrHighlightMatcher.normalize(target);
  if (normalized.isEmpty || candidates.isEmpty) return false;
  if (normalized.length >= 6) {
    return OcrHighlightMatcher.bestPreparedMatch(target, candidates) != null;
  }

  var bestExcess = 1 << 30;
  for (final candidate in candidates) {
    if (candidate.body == normalized) return true;
    if (normalized.length < 4) continue;
    String? matched;
    if (_containsWord(candidate.body, normalized)) {
      matched = candidate.body;
    } else if (_containsWord(candidate.full, normalized)) {
      matched = candidate.full;
    }
    if (matched != null) {
      final excess = matched.length - normalized.length;
      if (excess >= 0 && excess < bestExcess) bestExcess = excess;
    }
  }
  return bestExcess <= 25;
}

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

  testWidgets(
    'highlight can locate flagged lines on their pages',
    (t) async {
      const src = '$_ccRepo/sample-scripts/Pride-Prejudice-SCRIPT.pdf';
      final tmp = await getTemporaryDirectory();
      final pdf = p.join(tmp.path, 'pp_audit.pdf');
      await File(pdf).writeAsBytes(await File(src).readAsBytes());

      // 1. Per-page OCR, as the viewer's single-page call would return.
      final byPage = <int, List<OcrPageLine>>{};
      final paddleJob = PaddleOcrChannel.startPdf(pdf);
      final paddle = await paddleJob.result;
      VisionPdfResult? vision;
      if (paddle != null) {
        for (final page in paddle.pages) {
          byPage[page.page] = [
            for (final l in page.lines)
              OcrPageLine(
                text: l.text,
                left: l.left,
                top: 0,
                width: l.width,
                height: 0,
              ),
          ];
        }
        // ignore: avoid_print
        print('ENGINE=paddle pages=${byPage.length}');
      } else {
        final visionJob = VisionOcrChannel.startPdf(pdf);
        vision = await visionJob.result;
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

      // 2. The real import (same call the app makes), reusing the completed
      // native OCR result so this audit pays the full-document OCR cost once.
      final parsed = paddle != null
          ? await ScriptImportService().importFromPdf(
              pdf,
              completedPaddleOcr: paddle,
            )
          : await ScriptImportService().importFromPdf(
              pdf,
              completedVisionOcr: vision!,
            );
      final pageIndex = _indexPages(byPage);

      // 3. For every flagged line, can the viewer find it on its page?
      var flagged = 0, located = 0, foundNearby = 0, foundFar = 0, nowhere = 0;
      final examples = <String>[];
      for (final line in parsed.lines) {
        if (line.reviewStatus == OcrReviewStatus.ok) continue;
        final page = line.sourcePage;
        if (page == null) continue;
        flagged++;
        final onPage =
            pageIndex.preparedByPage[page] ?? const <OcrMatchCandidate>[];
        if (_preparedLocates(line.text, onPage)) {
          located++;
          continue;
        }
        // Where is it really? Neighbors first (off-by-one page assignment),
        // then only pages sharing a token or strong prefix. The index avoids
        // re-tokenizing and probing every OCR line for every far miss.
        var found = -1;
        for (final d in [-1, 1, -2, 2]) {
          final probe = pageIndex.preparedByPage[page + d];
          if (probe == null) continue;
          if (_preparedLocates(line.text, probe)) {
            found = page + d;
            break;
          }
        }
        if (found > 0) {
          foundNearby++;
        } else {
          final normalizedTarget = OcrHighlightMatcher.normalize(line.text);
          final candidates = <int>{};
          final pageQuarter = (byPage.length / 4).ceil();
          final maxIndexedPages = pageQuarter < 1
              ? 1
              : pageQuarter > 8
              ? 8
              : pageQuarter;
          final tokenPageSets = [
            for (final token in normalizedTarget.split(' ').toSet())
              if (token.isNotEmpty && pageIndex.pagesByToken[token] != null)
                pageIndex.pagesByToken[token]!,
          ]..sort((a, b) => a.length.compareTo(b.length));
          for (final pages in tokenPageSets) {
            if (pages.length <= maxIndexedPages) candidates.addAll(pages);
          }
          if (normalizedTarget.length >= 12) {
            final prefixPages =
                pageIndex.pagesByPrefix[normalizedTarget.substring(0, 12)];
            if (prefixPages != null && prefixPages.length <= maxIndexedPages) {
              candidates.addAll(prefixPages);
            }
          }
          // A line made entirely of common words still gets a bounded diagnostic
          // probe: use its rarest token rather than rescanning every page.
          if (candidates.isEmpty && tokenPageSets.isNotEmpty) {
            candidates.addAll(tokenPageSets.first.take(maxIndexedPages));
          }
          for (final candidatePage in candidates) {
            final prepared = pageIndex.preparedByPage[candidatePage];
            if (prepared != null && _preparedLocates(line.text, prepared)) {
              found = candidatePage;
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
          examples.add(
            'p$page → ${found > 0 ? 'p$found' : 'NOWHERE'}: '
            '"${txt.length > 55 ? txt.substring(0, 55) : txt}"',
          );
        }
      }

      // ignore: avoid_print
      print(
        'AUDIT flagged=$flagged located=$located '
        '(${(100 * located / (flagged == 0 ? 1 : flagged)).toStringAsFixed(1)}%) '
        'nearbyPage=$foundNearby farPage=$foundFar nowhere=$nowhere',
      );
      for (final e in examples) {
        // ignore: avoid_print
        print('MISS $e');
      }
      expect(flagged, greaterThan(0));
      expect(
        located / flagged,
        greaterThanOrEqualTo(0.80),
        reason:
            'at least 80% of flagged lines must highlight on their '
            'assigned page',
      );
      expect(
        nowhere / flagged,
        lessThanOrEqualTo(0.05),
        reason:
            'no more than 5% of flagged lines may be absent from all '
            'OCR pages',
      );
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
