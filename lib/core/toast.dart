import 'dart:async';

import 'package:flutter/material.dart';

/// Timer that force-hides the current snackbar. Library-private and shared:
/// only one snackbar is on screen at a time, so one timer is enough.
Timer? _hideTimer;

/// Every snackbar in the app goes through [showAutoToast] instead of
/// `showSnackBar`, because `SnackBar.duration` is not reliable.
///
/// Flutter deliberately skips the auto-dismiss timer when the platform reports
/// accessible navigation (`MediaQueryData.accessibleNavigation`) so that a
/// screen-reader user can reach the snackbar's action. On such a device EVERY
/// snackbar stays until something replaces it: during a real rehearsal a
/// 3-second "Saved 9 rehearsal recordings" bar sat on screen for the whole run
/// and then followed the user onto the debug-log screen. Queued snackbars
/// compound it, since each one's timer only starts once it becomes visible.
///
/// So we hide it on a timer we control. The SnackBar's own `duration` is still
/// honoured as the intended lifetime — this just guarantees it is enforced.
extension AutoDismissSnackBar on ScaffoldMessengerState {
  void showAutoToast(SnackBar snackBar) {
    showSnackBar(snackBar);
    _hideTimer?.cancel();
    _hideTimer = Timer(snackBar.duration, () {
      // The messenger outlives individual screens, but it can still be gone by
      // the time this fires (app shutting down); hiding twice is a no-op.
      try {
        hideCurrentSnackBar();
      } catch (_) {}
    });
  }
}
