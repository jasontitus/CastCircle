import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/ocr_highlight_matcher.dart';
import 'package:castcircle/data/services/paddle_ocr_channel.dart';
import 'package:castcircle/data/services/script_import_service.dart';

/// Measures how often the page-viewer highlight can find a flagged line on
/// its own page, using the REAL Paddle OCR text of the P&P scan. The viewer
/// re-renders at the same scale as import, so its per-page OCR is
/// effectively the same text this fixture holds.
void main() {
  test('highlight hit rate on real OCR corpus', () {
    final raw = File('test/fixtures/pp_ocr_raw.txt').readAsStringSync();
    final rawLines = raw.split('\n');
    const perPage = 40;
    final linePageMap = <int, int>{
      for (var i = 0; i < rawLines.length; i++) i: (i ~/ perPage) + 1,
    };
    final conf = <int, double>{
      for (var i = 0; i < rawLines.length; i++) i: 0.55, // force flagging
    };
    final script = ScriptImportService.parseAndMapOcr(
      raw,
      'PP',
      conf,
      linePageMap,
    );

    // Page number -> its OCR lines, as the viewer would receive them.
    final byPage = <int, List<OcrPageLine>>{};
    for (var i = 0; i < rawLines.length; i++) {
      final page = linePageMap[i]!;
      final text = rawLines[i].trim();
      if (text.isEmpty) continue;
      (byPage[page] ??= []).add(
        OcrPageLine(
          text: text,
          left: 0.1,
          top: (i % perPage) / perPage,
          width: 0.8,
          height: 0.02,
        ),
      );
    }

    var attempted = 0, hit = 0, nowhere = 0;
    final offBy = <int>[];
    final misses = <String>[];
    for (final line in script.lines) {
      if (line.lineType != LineType.dialogue) continue;
      final page = line.sourcePage;
      if (page == null) continue;
      final pageLines = byPage[page] ?? const <OcrPageLine>[];
      if (pageLines.isEmpty) continue;
      attempted++;
      final rects = OcrHighlightMatcher.locate(line.text, pageLines);
      if (rects.isNotEmpty) {
        hit++;
      } else {
        // Where DOES it live? Search every page to separate matcher
        // failures from page-assignment errors.
        var foundOn = -1;
        for (final entry in byPage.entries) {
          if (OcrHighlightMatcher.locate(line.text, entry.value).isNotEmpty) {
            foundOn = entry.key;
            break;
          }
        }
        if (foundOn > 0) {
          offBy.add(foundOn - page);
        } else {
          nowhere++;
        }
        if (misses.length < 8) {
          final t = line.text;
          final shown = t.length > 60 ? t.substring(0, 60) : t;
          misses.add('assigned p$page found p$foundOn: "$shown"');
        }
      }
    }
    final rate = hit / attempted;
    print('HIT RATE: $hit/$attempted = ${(rate * 100).toStringAsFixed(1)}%');
    final near = offBy.where((d) => d.abs() <= 2).length;
    print(
      'MISSES: ${offBy.length} found on another page '
      '($near within +/-2 pages), $nowhere found nowhere',
    );
    print('--- sample misses ---');
    for (final m in misses) {
      print(m);
    }
    // Pins the fix for the cursor-overshoot collapse (46% → 98%): the
    // import's page mapping and the viewer's highlight share one scorer,
    // so a mapped page must be a page the viewer can find the line on.
    expect(
      rate,
      greaterThan(0.90),
      reason: 'the viewer should locate the large majority of lines',
    );
  });
}
