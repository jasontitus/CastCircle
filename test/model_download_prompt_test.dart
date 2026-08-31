import 'package:castcircle/features/production_hub/production_hub_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Download Now starts immediately and closes the prompt', (
    tester,
  ) async {
    var starts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => ModelDownloadPrompt(
                  isAndroid: false,
                  onDownload: () => starts++,
                ),
              ),
              child: const Text('Show prompt'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Show prompt'));
    await tester.pumpAndSettle();
    expect(find.text('Download AI Models'), findsOneWidget);

    await tester.tap(find.text('Download Now'));
    await tester.pumpAndSettle();

    expect(starts, 1);
    expect(find.text('Download AI Models'), findsNothing);
  });
}
