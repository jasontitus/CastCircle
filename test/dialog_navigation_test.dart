import 'dart:async';

import 'package:castcircle/data/database/app_database.dart' show AppDatabase;
import 'package:castcircle/data/models/production_models.dart';
import 'package:castcircle/features/home/home_screen.dart';
import 'package:castcircle/main.dart' show databaseProvider;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression coverage for `_HomeScreenState._submitProduction` retaining a
/// usable router after it pops the production-creation dialog.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpHome(
    WidgetTester tester,
    Future<void> Function(Production) createProduction,
  ) async {
    SharedPreferences.setMockInitialValues({'screenshot_mode': true});
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) =>
              HomeScreen(createProduction: createProduction),
        ),
        GoRoute(
          path: '/import',
          builder: (context, state) =>
              const Scaffold(body: Center(child: Text('IMPORT SCREEN'))),
        ),
      ],
    );
    addTearDown(() async {
      router.dispose();
      await database.close();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(database)],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
  }

  Future<void> submitProduction(WidgetTester tester, String title) async {
    await tester.tap(find.text('New Production'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField), title);
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets(
    'real HomeScreen pops, awaits persistence, then navigates with its captured router',
    (tester) async {
      final persistence = Completer<void>();
      Production? submitted;
      await pumpHome(tester, (production) {
        submitted = production;
        return persistence.future;
      });

      await submitProduction(tester, 'Macbeth');

      expect(submitted?.title, 'Macbeth');
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('IMPORT SCREEN'), findsNothing);

      persistence.complete();
      // The first pump resumes _submitProduction after the injected Future;
      // the second builds the route pushed by the captured GoRouter.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('IMPORT SCREEN'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('persistence failure does not navigate', (tester) async {
    await pumpHome(tester, (_) async {
      throw StateError('disk full');
    });

    await submitProduction(tester, 'Macbeth');

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('IMPORT SCREEN'), findsNothing);
    expect(find.text('New Production'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
