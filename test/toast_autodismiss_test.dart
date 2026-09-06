import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/core/toast.dart';

/// SnackBar.duration is NOT honoured when the platform reports accessible
/// navigation — Flutter keeps the bar up so a screen-reader user can reach its
/// action. On a device with it enabled every snackbar in the app became
/// permanent (one followed a rehearsal onto the debug-log screen), so all
/// snackbars go through showAutoToast, which enforces the lifetime itself.
void main() {
  testWidgets('toast disappears even with accessibleNavigation on', (
    tester,
  ) async {
    final key = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(
      MediaQuery(
        // The exact condition that disables Flutter's own auto-dismiss.
        data: const MediaQueryData(accessibleNavigation: true),
        child: MaterialApp(
          scaffoldMessengerKey: key,
          home: const Scaffold(body: SizedBox()),
        ),
      ),
    );

    key.currentState!.showAutoToast(
      const SnackBar(
        content: Text('transient'),
        duration: Duration(seconds: 2),
      ),
    );
    await tester.pump();
    expect(find.text('transient'), findsOneWidget);

    // Past the stated duration it must be gone.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(
      find.text('transient'),
      findsNothing,
      reason: 'showAutoToast must force-dismiss regardless of a11y settings',
    );
  });

  testWidgets('plain showSnackBar is the buggy baseline we avoid', (
    tester,
  ) async {
    final key = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(accessibleNavigation: true),
        child: MaterialApp(
          scaffoldMessengerKey: key,
          home: const Scaffold(body: SizedBox()),
        ),
      ),
    );
    key.currentState!.showSnackBar(
      const SnackBar(content: Text('sticky'), duration: Duration(seconds: 2)),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    // Documents the Flutter behaviour that caused the bug.
    expect(find.text('sticky'), findsOneWidget);
    key.currentState!.removeCurrentSnackBar();
    await tester.pumpAndSettle();
  });
}
