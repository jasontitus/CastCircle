# Pi sweep review — CastCircle

Exhaustive per-file pass: 2 code files across 1 batches — model ds4/GLM-5.3-Flash-Q2:off — 2026-08-29.

## Findings

- [low] linux/runner/my_application.cc:87 — `g_strdupv(*arguments + 1)` assumes `*arguments` is non-NULL and has ≥1 element; if the launcher passes an empty argv the runner dereferences past the array — crash at startup — guard with a length check before advancing the pointer.
- [low] linux/runner/my_application.cc:89-94 — `g_autoptr(GError) error` is declared but the failure path only logs `error->message` after `g_application_register` fails; if registration fails with error==NULL (allowed when the function returns FALSE without setting error per some GLib versions' contract only when error is NULL-initialized — here it is, so safe) — no defect; withdrawn.
- [medium] linux/runner/my_application.cc:90-94 — on `g_application_register` failure the code logs and sets `*exit_status = 1` but still returns TRUE, so `g_application_run` treats the command line as handled and the app exits with status 1 without any user-visible error dialog; combined with `G_APPLICATION_NON_UNIQUE` (147) this silently swallows registration errors — acceptable for a runner, but the warning is the only signal — no change needed beyond confirming severity.
- [low] linux/runner/my_application.cc:143-147 — `g_set_prgname(APPLICATION_ID)` is called before `g_object_new`, but `APPLICATION_ID` is defined in `my_application.h` (not shown); if it differs from the binary name expected by desktop files the window title set at 48/52 ("castcircle") may mismatch — assumption only, no defect exhibited.
- [info] linux/runner/my_application.cc:48,52 — window/header-bar title is hardcoded to "castcircle" while the application id comes from `APPLICATION_ID`; verify these are intentionally consistent (no defect exhibited by inlined code alone).

## Coverage
linux/runner/main.cc — clean
linux/runner/my_application.cc — findings: 2

## Run stats

input 3504 tok (+1089 cached), output 419 tok — sync requests, discounted — 2 files in 0m (7200.0 files/h, 0.0 min/batch)
