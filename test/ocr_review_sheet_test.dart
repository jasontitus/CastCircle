import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/features/script_import/ocr_review_screen.dart';

ScriptLine _line(String id, String text, int page) => ScriptLine(
      id: id,
      act: 'ACT I',
      scene: 'Scene 1',
      lineNumber: 0,
      orderIndex: int.parse(id),
      character: 'DARCY',
      text: text,
      lineType: LineType.dialogue,
      reviewStatus: OcrReviewStatus.review,
      sourcePage: page,
      sourceLineOnPage: 1,
    );

void main() {
  /// Field crash (iOS, build 142): tapping Remove in the page-viewer sheet
  /// killed the app. These drive the real widget so the sheet's
  /// index/teardown handling is exercised, including removing the LAST
  /// remaining flagged line (which pops the sheet).
  Future<void> openSheet(WidgetTester tester, List<ScriptLine> lines) async {
    // Phone width: the single-pane layout with the modal sheet, which is
    // what the field crash was reported on (portrait phone).
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 3.0; // 400 x 800 logical
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: OcrReviewScreen(lines: lines, pdfPath: '/tmp/does-not-exist.pdf'),
    ));
    await tester.pump();
    await tester.tap(find.text('View page').first);
    // Fixed pumps, not pumpAndSettle: the page viewer shows an
    // indeterminate progress indicator that never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('Remove in the page sheet does not crash', (tester) async {
    final lines = [
      _line('1', 'She is tolerable, but not handsome enough', 3),
      _line('2', 'I would not be so fastidious as you are', 4),
      _line('3', 'Which do you mean, and what of him?', 5),
    ];
    await openSheet(tester, lines);
    expect(find.text('Flagged line 1 of 3'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Sheet survives and advances to the next flagged line.
    expect(tester.takeException(), isNull);
    expect(find.text('Flagged line 1 of 2'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6)); // drain the toast timer
  });

  testWidgets('Next/Previous step through flagged lines', (tester) async {
    final lines = [
      _line('1', 'She is tolerable, but not handsome enough', 3),
      _line('2', 'I would not be so fastidious as you are', 4),
    ];
    await openSheet(tester, lines);

    await tester.tap(find.widgetWithText(FilledButton, 'Next'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(find.text('Flagged line 2 of 2'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Prev'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Flagged line 1 of 2'), findsOneWidget);
  });

  testWidgets('the sheet text is editable and Looks right keeps the fix',
      (tester) async {
    final lines = [
      _line('1', 'She is tolerabl, but nut handsom', 3),
      _line('2', 'I would not be so fastidious as you are', 4),
    ];
    await openSheet(tester, lines);

    // Fix the OCR text right in the page sheet...
    await tester.enterText(find.byType(TextField).last,
        'She is tolerable, but not handsome');
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Looks right'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    // ...and the correction is what got committed.
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('Flagged line 1 of 1'), findsOneWidget);
  });

  testWidgets('"Looks right" clears the flag and advances', (tester) async {
    final lines = [
      _line('1', 'She is tolerable, but not handsome enough', 3),
      _line('2', 'I would not be so fastidious as you are', 4),
    ];
    await openSheet(tester, lines);
    expect(find.text('Flagged line 1 of 2'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Looks right'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    // The reviewed line leaves the pending list; the sheet lands on the next.
    expect(find.text('Flagged line 1 of 1'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6)); // drain the toast timer
  });

  testWidgets('removing the last flagged line closes the sheet cleanly',
      (tester) async {
    final lines = [_line('1', 'She is tolerable, but not handsome', 3)];
    await openSheet(tester, lines);

    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.text('Flagged line 1 of 1'), findsNothing);
    await tester.pump(const Duration(seconds: 6)); // drain the toast timer
  });
}
