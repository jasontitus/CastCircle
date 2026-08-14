import 'package:castcircle/features/onboarding/welcome_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The walkthrough is the first screen a new user meets, so it gets tested at
/// the sizes that have actually broken screens in this app before: a narrow
/// phone, and a narrow phone with the text scale turned up.
Future<void> _pump(WidgetTester tester,
    {Size size = const Size(400, 800), double textScale = 1.0}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: const WelcomeScreen(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opens on the first page and advances through all of them',
      (tester) async {
    await _pump(tester);

    expect(find.textContaining('Rehearse without'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);

    // Walk to the end; the final page swaps Next for the two real actions.
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
    }

    expect(find.textContaining('Invite'), findsWidgets);
    expect(find.text('Next'), findsNothing);
    expect(find.text('Try the demo'), findsOneWidget);
    expect(find.text('Start with my own script'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
  });

  testWidgets('explains how to invite a cast member', (tester) async {
    await _pump(tester);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
    }
    // The specific mechanism, not just the word "invite" — a walkthrough that
    // says "you can invite people" without saying how is decoration.
    expect(find.textContaining('join code'), findsOneWidget);
    expect(find.textContaining('Cast & Roles'), findsOneWidget);
  });

  testWidgets('no overflow on a narrow phone at large text scale',
      (tester) async {
    await _pump(tester, size: const Size(360, 640), textScale: 1.6);

    for (var i = 0; i < 3; i++) {
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });
}
