import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/models/production_models.dart';
import 'package:castcircle/features/script_editor/script_editor_screen.dart';
import 'package:castcircle/providers/production_providers.dart';

ScriptLine _line(String id, String text, {double? conf, int? page}) =>
    ScriptLine(
      id: id,
      act: 'ACT I',
      scene: 'Scene 1',
      lineNumber: 0,
      orderIndex: int.parse(id),
      character: 'DARCY',
      text: text,
      lineType: LineType.dialogue,
      ocrConfidence: conf,
      sourcePage: page,
      sourceLineOnPage: 1,
    );

/// The editor's low-OCR walk-through: Prev / Looks right / Next inside the
/// line-edit sheet, for cleaning a script up AFTER the import was accepted.
/// Mirrors the review sheet's tests — those are what caught the field crash.
void main() {
  Future<void> pumpEditor(
    WidgetTester tester,
    ParsedScript script, {
    Production? production,
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 3.0; // 400 x 800 logical (phone)
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentScriptProvider.overrideWith((ref) => script),
          if (production != null)
            currentProductionProvider.overrideWith((ref) => production),
        ],
        child: const MaterialApp(home: ScriptEditorScreen()),
      ),
    );
    await tester.pump();
  }

  testWidgets('walks flagged lines through Prev, Looks right, and Next', (
    tester,
  ) async {
    final script = ParsedScript(
      title: 'T',
      lines: [
        _line('1', 'She is tolerable, but not handsome', conf: 0.4, page: 3),
        _line('2', 'A clean line nobody flagged', conf: 0.99, page: 3),
        _line('3', 'I would not be so fastidious', conf: 0.5, page: 4),
      ],
      characters: const [
        ScriptCharacter(name: 'DARCY', colorIndex: 0, lineCount: 3),
      ],
      scenes: const [],
      rawText: '',
    );
    final production = Production(
      id: 'production-1',
      title: 'T',
      organizerId: 'organizer-1',
      createdAt: DateTime(2026, 1, 1),
      status: ProductionStatus.scriptImported,
      scriptPath: File(
        'sample-scripts/ocr-test-set/macbeth_shakespeare_1898.pdf',
      ).absolute.path,
    );
    await pumpEditor(tester, script, production: production);

    expect(find.textContaining('Low OCR (2)'), findsOneWidget);
    await tester.tap(find.text('She is tolerable, but not handsome'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('Edit Line #1'), findsOneWidget);
    expect(find.text('Low OCR 1 of 2'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Prev'))
          .onPressed,
      isNull,
    );

    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Next'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.widgetWithText(FilledButton, 'Next'));
    await tester.pump();
    expect(find.textContaining('Edit Line #3'), findsOneWidget);
    expect(find.text('Low OCR 2 of 2'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Next'))
          .onPressed,
      isNull,
    );

    await tester.ensureVisible(find.widgetWithText(TextButton, 'Prev'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.widgetWithText(TextButton, 'Prev'));
    await tester.pump();
    expect(find.textContaining('Edit Line #1'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ScriptEditorScreen)),
    );
    // Keep the PDF-backed sheet open, but make the debounced persistence
    // intentionally a no-op in this widget-only test.
    container.read(currentProductionProvider.notifier).state = null;
    await tester.tap(find.widgetWithText(TextButton, 'Looks right'));
    await tester.pump(const Duration(milliseconds: 801));
    expect(find.textContaining('Edit Line #3'), findsOneWidget);
    expect(find.text('Low OCR 1 of 1'), findsOneWidget);

    final updated = container.read(currentScriptProvider)!;
    expect(updated.lines.first.text, 'She is tolerable, but not handsome');
    expect(updated.lines.first.ocrConfidence, isNull);
    expect(updated.lines.last.ocrConfidence, 0.5);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a script with no flagged lines shows no low-OCR filter', (
    tester,
  ) async {
    final script = ParsedScript(
      title: 'T',
      lines: [_line('1', 'All good here', conf: 0.99, page: 1)],
      characters: const [
        ScriptCharacter(name: 'DARCY', colorIndex: 0, lineCount: 1),
      ],
      scenes: const [],
      rawText: '',
    );
    await pumpEditor(tester, script);

    expect(find.textContaining('Low OCR'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
