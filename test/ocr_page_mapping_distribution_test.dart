import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/services/script_import_service.dart';
import 'package:castcircle/data/models/script_models.dart';

void main() {
  // Regression for the field failure where every "View page" opened the
  // same overview page: unbounded cursor matching let one garbled line
  // false-match deep into the document and page inheritance smeared a
  // single page across all 1440 lines (14 distinct pages; healthy is ~50).
  test('page mapping stays distributed and monotonic on the real corpus', () {
    final raw = File('test/fixtures/pp_ocr_raw.txt').readAsStringSync();
    final rawLines = raw.split('\n');
    // Approximate the real per-page structure: ~40 raw lines per page.
    final linePageMap = <int, int>{
      for (var i = 0; i < rawLines.length; i++) i: (i ~/ 40) + 1,
    };
    final conf = <int, double>{for (var i = 0; i < rawLines.length; i++) i: 0.9};
    final script =
        ScriptImportService.parseAndMapOcr(raw, 'PP', conf, linePageMap);

    final pages = script.lines.map((l) => l.sourcePage).toList();
    final nullCount = pages.where((p) => p == null).length;
    final dist = <int, int>{};
    for (final p in pages) {
      if (p != null) dist[p] = (dist[p] ?? 0) + 1;
    }
    print('lines=${pages.length} unmapped=$nullCount distinctPages=${dist.length}');
    // Monotonicity spot check: page of line i should not exceed page of i+50 by much.
    final first = script.lines.take(5).map((l) => '${l.sourcePage}').join(',');
    final mid = script.lines.skip(700).take(5).map((l) => '${l.sourcePage}').join(',');
    final last = script.lines.skip(script.lines.length - 5).map((l) => '${l.sourcePage}').join(',');
    print('first5=$first mid5=$mid last5=$last');
    expect(dist.length, greaterThan(30),
        reason: 'a healthy 82-page mapping uses many distinct pages');
    // Monotonic progression: the document's start, middle, and end must
    // land on early, middle, and late pages respectively.
    final firstPage = script.lines.first.sourcePage!;
    final midPage = script.lines[script.lines.length ~/ 2].sourcePage!;
    final lastPage = script.lines.last.sourcePage!;
    expect(firstPage, lessThan(10));
    expect(midPage, greaterThan(firstPage + 20));
    expect(lastPage, greaterThan(midPage + 15));
  });
}
