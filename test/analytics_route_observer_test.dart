import 'package:castcircle/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Regression tests for [AnalyticsRouteObserver].
///
/// `logScreenView` sets the screen that subsequent Firebase events and
/// engagement time are attributed to, so a pop must log the route being
/// *returned to*. Two ways to get this wrong, both of which shipped or nearly
/// shipped, and both of which these tests pin down:
///
///  * logging the popped route counts every page twice — once on push, once on
///    pop — and leaves attribution on a screen the user already left;
///  * logging on every pop re-logs the host screen each time a dialog or modal
///    sheet is dismissed, inflating whichever screen happens to own dialogs.
void main() {
  late List<String> logged;

  setUp(() => logged = <String>[]);

  Widget buildApp() {
    Widget page(String label) => Scaffold(
      body: Center(
        child: Builder(
          builder: (context) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label),
              ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const AlertDialog(content: Text('dialog')),
                ),
                child: const Text('open dialog'),
              ),
            ],
          ),
        ),
      ),
    );

    return MaterialApp.router(
      routerConfig: GoRouter(
        initialLocation: '/',
        observers: [AnalyticsRouteObserver(logScreenView: logged.add)],
        routes: [
          GoRoute(path: '/', builder: (_, _) => page('Home')),
          GoRoute(path: '/production', builder: (_, _) => page('Hub')),
          GoRoute(path: '/rehearsal', builder: (_, _) => page('Rehearsal')),
        ],
      ),
    );
  }

  testWidgets('logs the initial route under its human-readable name', (
    tester,
  ) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    // Also guards the assumption the observer rests on: go_router exposes the
    // route path as settings.name. If it ever stopped, _logScreen's null guard
    // would swallow everything and the observer would silently log nothing.
    expect(logged, ['Home']);
  });

  testWidgets('a push logs the screen arrived at', (tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    tester.element(find.text('Home')).push('/production');
    await tester.pumpAndSettle();
    expect(logged, ['Home', 'Production Hub']);
  });

  testWidgets('a pop logs the screen returned to, not the one left', (
    tester,
  ) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    tester.element(find.text('Home')).push('/production');
    await tester.pumpAndSettle();
    tester.element(find.text('Hub')).push('/rehearsal');
    await tester.pumpAndSettle();
    tester.element(find.text('Rehearsal')).pop();
    await tester.pumpAndSettle();
    tester.element(find.text('Hub')).pop();
    await tester.pumpAndSettle();

    expect(logged, [
      'Home',
      'Production Hub',
      'Rehearsal',
      'Production Hub',
      'Home',
    ]);
    // No page is counted twice for a single visit...
    expect(logged.where((s) => s == 'Rehearsal').length, 1);
    // ...and the last screen_view matches where the user actually ended up.
    expect(logged.last, 'Home');
  });

  testWidgets('opening and closing a dialog logs nothing', (tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    logged.clear();

    await tester.tap(find.text('open dialog'));
    await tester.pumpAndSettle();
    expect(logged, isEmpty, reason: 'a dialog is not a screen');

    tester.element(find.text('dialog')).pop();
    await tester.pumpAndSettle();
    expect(logged, isEmpty, reason: 'the user never left Home');
  });

  testWidgets('a dialog with explicit routeSettings is still not a screen', (
    tester,
  ) async {
    // The PageRoute filter, not the null-name guard, is what makes this hold.
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    logged.clear();

    final context = tester.element(find.text('Home'));
    showDialog<void>(
      context: context,
      routeSettings: const RouteSettings(name: '/rehearsal'),
      builder: (_) => const AlertDialog(content: Text('named dialog')),
    );
    await tester.pumpAndSettle();
    tester.element(find.text('named dialog')).pop();
    await tester.pumpAndSettle();

    expect(logged, isEmpty);
  });

  testWidgets('didReplace logs the replacing screen', (tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    tester.element(find.text('Home')).pushReplacement('/production');
    await tester.pumpAndSettle();
    expect(logged, ['Home', 'Production Hub']);
  });
}
