import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/script_models.dart';
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
  Future<void> pumpEditor(WidgetTester tester, ParsedScript script) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 3.0; // 400 x 800 logical (phone)
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        currentScriptProvider.overrideWith((ref) => script),
      ],
      child: const MaterialApp(home: ScriptEditorScreen()),
    ));
    await tester.pump();
  }

  testWidgets('flagged lines are countable and the editor renders them',
      (tester) async {
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
    await pumpEditor(tester, script);

    // The low-OCR filter chip reports both flagged lines — the same set the
    // sheet's walk-through steps through.
    expect(find.textContaining('Low OCR (2)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a script with no flagged lines shows no low-OCR filter',
      (tester) async {
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
