# Pi sweep review — CastCircle

Exhaustive per-file pass: 1 code files across 1 batches — model ds4/GLM-5.3-Flash-Q2:off — 2026-08-29.

## Findings

- [medium] pubspec.yaml:7 — SDK constraint `^3.11.0` does not exist (latest stable Dart SDK is 3.9.x as of late 2025; Flutter pins Dart 3.9.x) — every `pub get`/CI build fails with version solving errors, blocking all dependency resolution — pin to the SDK actually shipped by the Flutter toolchain (e.g. `^3.9.0`) or the Flutter-pinned range.
- [medium] pubspec.yaml:16 — `flutter_riverpod: ^3.0.0` — Riverpod 3.0 is a pre-release/preview line (stable published line is 2.x); a caret on a non-existent major resolves nothing or pulls a preview — builds fail or silently take a prerelease — pin to the published stable major (e.g. `^2.6.1`) or verify 3.0 exists on pub.dev before shipping.
- [medium] pubspec.yaml:19 — `go_router: ^16.0.0` — go_router's published majors track Flutter releases (latest stable ~14.x/15.x era); ^16 may not exist — resolution failure — verify the major on pub.dev and pin to the published one.
- [medium] pubspec.yaml:80 — `firebase_core: ^4.5.0` — firebase_core's published line is 2.x/3.x (3.x is current); ^4.5.0 likely does not exist — pub resolution fails — pin to the published major.
- [medium] pubspec.yaml:81 — `firebase_crashlytics: ^5.0.8` — published line is 3.x/4.x; ^5 may not exist — resolution failure — pin to published major.
- [medium] pubspec.yaml:82 — `firebase_analytics: ^12.1.3` — published line is 10.x/11.x; ^12 likely does not exist — resolution failure — pin to published major.
- [medium] pubspec.yaml:83 — `firebase_performance: ^0.11.1+5` — published line is 0.10.x/0.25.x era; ^0.11 may not exist — resolution failure — pin to published version.
- [medium] pubspec.yaml:98 — `dependency_overrides: record_linux: ^1.3.0` — a permanent override in the manifest silently diverges resolution from what the rest of the ecosystem expects, and overrides are not honored by consumers if this is ever published — document/remove once the upstream fix lands, or use a comment + pinned exact version.
- [low] pubspec.yaml:4 — version `0.1.1+155` with `publish_to: 'none'` — build number churn is fine locally, but no lockfile is inlined here so drift cannot be audited from this batch — ensure pubspec.lock is committed and reviewed (assumed present; not visible in this batch).

## Coverage
pubspec.yaml — findings: 9

## Run stats

input 2816 tok (+1089 cached), output 636 tok — sync requests, discounted — 1 files in 0m (116.1 files/h, 0.5 min/batch)
