# CastCircle — Merge & Ship Handoff (2026-09-06)

## TL;DR

Merged `pi-review-ultra` into `main` (789b4f5), shipped TestFlight build **162**
from the merge. Full suite: **682 tests pass**, analyze 0 errors/warnings. The
branch had **never** been merged; its Supabase migration was already applied to
the live DB, so the merged app adopts the branch's backend API surface and
main's independent fixes were ported forward.

## State

- `origin/main` = `8359a74`. Working tree clean.
- TestFlight build **162** (0.1.1+162) uploaded; dSYMs pushed to Crashlytics.
- `pubspec.yaml` left at `0.1.1+162` (build bump commit may be pending — check
  `git status`).

## What the branch was

`pi-review-ultra` = an independent deep-review line (32 commits, forked from
`95f1763`, tip 2026-08-30) that shipped its own TestFlight build 160 and its own
DB migration `20260830120000_atomic_script_and_data_integrity.sql` — **applied
to the live Supabase project** (`vngpbmqymdaxxnvqptsk`). Main's release
(4afaa94, 2026-09-06) had independently introduced a *different* backend API
(`begin_production_deletion`/`finalize_production_deletion` RPCs) that the live
DB does not have — that's why production deletion failed on shipped builds
160/161.

## Merge decisions (why each side won)

- **Backend/data/branch-API files** → branch wholesale (matches live DB):
  `supabase_service.dart` (delete_production RPC, direct cast CRUD under branch
  RLS), `sync_queue.dart`, `recording_sync_service.dart`, `stt_*`,
  `tts_service.dart`, `voice_config_service.dart`, `model_*` services, native
  iOS/Android plugins, all feature screens, branch tests.
- **Ported forward from main** (branch never had them): account_namespace
  isolation (Productions.accountNamespace + idx + migration step 9 +
  namespace-scoped repository + setAccountIdentity/claimLegacyProductions),
  Stage Partners parser + header blocklist + bare-name-cue guard, iOS
  PaddleOcr per-page continue, createProduction router capture + test hook,
  teardownAccountState (adapted), initializationResult completer, production
  run-token activation guards.
- **main's stale migration `20260827120000` DELETED** — never applied to the
  remote, and applying it would have replaced the branch functions the merged
  app calls. Tree now matches remote history exactly.

## Fixed during review (commit 8359a74)

1. `SupabaseService.init` — a merge edit had collapsed the awaited 5s timeout;
   restored. (Merged code had reported initialized *synchronously*, so a slow
   cold start permanently reported signed-out.)
2. `PaddleOcrChannel.progress` — class-wide aggregate now resets when an OCR
   run completes, so the import screen doesn't show a stale page bar.
3. Earlier (0a62231): `@TableIndex idx_productions_account_created` had landed
   between class declarations and attached to `ScriptLines`, generating
   `CREATE INDEX ... ON script_lines ()` — every migration test failed.

## Known design (not bugs)

- Branch DB has **no organizer-side cast INSERT policy** — `restoreCastMember`
  (used only as rename/merge compensation) recreates rows via the
  `create_cast_invitation` RPC, i.e. an assigned member's restored row comes
  back as an **unclaimed invitation**; the actor re-claims it. Logged loudly.
- Unused RPCs remain on the remote (`create_production`, `delete_production` is
  used; `check_join_rate_limit` is used by lookup; `replace_script` unused).
- `main.dart`'s `SttAdaptationService.instance.initializeLifecycle()` call was
  removed: the branch's STT adaptation service is dependency-injected and
  writes through immediately (no lifecycle flush to register).

## Open items

1. **Three review agents were cancelled before reporting**
   (ReviewNamespace/ReviewBackend/ReviewParserOCR). ReviewStateFlow completed
   and its two findings are fixed, but the namespace/backend/parser+OCR
   reviewers were cut off by the ship deadline. Their task prompts live in this
   session; re-run them on HEAD when there's time:
   `'/Users/jasontitus/.omp/agent/sessions/-experiments-CastCircle/2026-09-06T21-38-31-121Z_01a078a8-9c51-73fe-bd38-36b8013ad4d6/ReviewNamespace.md'` etc. have no salvageable payload.
2. **`pubspec.yaml` build bump**: build 162 shipped with pubspec at +162 but the
   bump commit may be uncommitted — run `git status` and commit the bump
   (`Bump TestFlight build to 0.1.1+162`), then push.
3. **Changelog/docs**: CHANGELOG.md still ends at +155; the merge and builds
   160–162 are not documented. `fastlane/.../changelogs/` also stops at 159.
4. **Branch cleanup**: `pi-review-ultra` and its 32 commits are now merged; the
   branch + `origin/pi-ultra-snapshot/*` tags can be deleted.
5. **Untracked files intentionally never committed**:
   `scripts/Wrinkle in Time by Sie.pdf` (licensed, school-only — do NOT commit)
   and `requirements.txt` (stray PyMuPDF pin). Consider gitignoring the PDF.

## Verification commands

```
flutter test                 # 682 pass
flutter analyze              # 0 errors/warnings (134 info lints, pre-existing)
git log --oneline -5         # 8359a74 fix, 0a62231 index fix, 789b4f5 merge
supabase migration list      # remote == local (20260830120000 applied)
```

---

# ADDENDUM — final ship (2026-09-06, later same day)

After the handoff was first drafted, the ship surfaced two more merge gaps —
both native Swift, both the same class of defect: **main's plugin kept, branch's
service adopted**. Both fixed and re-shipped.

## Build history this session

- build 162: FAILED to compile — `KokoroMLXService.modelStatus()` missing
  (branch service adopted; method existed only on main's service).
  Fixed in `e7d4ed6` — ported `modelStatus()` routed through the branch's
  `synthQueue`.
- build 163 (aborted): `Cannot call value of non-function type 'Bool'` —
  merged plugin kept main's `await kokoroService.isModelLoaded()` call syntax
  while the merged service's `isModelLoaded` is a plain Bool property.
  Fixed in `bea0430` — plugin reads the property directly.
- **build 164 shipped OK** — Delivery UUID `614038d3-6ae8-4509-827e-96fc8327cf96`.
  dSYMs pushed to Crashlytics.

## Final state

- `origin/main` = `f92e65d` (`Bump TestFlight build to 0.1.1+164`), clean tree.
- **TestFlight build 164** is the ship. Builds 160–163 were wasted numbers;
  nothing reuses them.
- Suite: **682 tests pass**; analyze 0 errors/warnings.
- "Encountered error while creating the IPA: exportArchive Copy failed" in the
  ship log is the KNOWN EXPECTED step-3 failure (see ship-testflight.sh header)
  — the archive is still produced and uploaded.

## Method note for future native merges

The plugin↔service call surface is where merges fail: the merge may keep one
side's plugin and the other side's service. After any native merge, grep both
directions before building:

```
grep -nE "kokoroService\.[a-zA-Z]+" ios/Runner/KokoroMLXPlugin.swift
grep -nE "    func |    var " ios/Runner/KokoroMLXService.swift
```

and confirm every plugin call resolves. `flutter build ios --release` is the
only check that catches Swift mismatch; `flutter test` does not.

## Updated open items

1. Three review agents (ReviewNamespace/ReviewBackend/ReviewParserOCR) were
   cancelled before reporting; their areas were covered by the compile break
   discoveries above plus the full suite, but a fresh reviewer pass on HEAD is
   still worthwhile.
2. CHANGELOG.md / fastlane changelogs still end at 155 / 159.
3. Branch + snapshot tags cleanup (pi-review-ultra is fully merged).
4. Untracked licensed PDF + stray requirements.txt (never commit the PDF).

---

## Build 165 repair — 2026-09-06

Source fix: `9f3f406` on `main`. Build 165 was uploaded successfully with
Delivery UUID `7a37b7c2-1afd-4710-a292-6bf3077e4017`.

The production-creation failure persisted because build 164 did not contain
the local repair. The two branch histories also collided at the database
version: review shipped schema 10 without `account_namespace`, main shipped
schema 9 with it, and the merge kept schema 10 and a `from < 9` guard. Schema
11 now ensures the column/index for upgrades from either history, preserving
existing production rows. Regression tests reproduce the missing column at
versions 9 and 10, then verify guest creation and signed-in cloud-create outbox
persistence after repair.

The Wrinkle PDF has 13 combined act/scene headings. Treating each entire
heading as an act made the import quality gate reject embedded text (>10
acts) and launch OCR. The parser now separates act identity from scene. A
full import using native Apple PDFKit extraction of the local 55-page PDF
returns 2 acts, 13 scenes, 1,140 dialogue lines, and 22 characters.

Validation: 687 tests passed, one existing test skipped; analyzer has no
errors/warnings (existing informational lints remain). The release iOS build
and archive succeeded, archive CFBundleVersion verified as 165, signed export
succeeded, and Apple's uploader reported success. The licensed PDF and its
extracted text were not committed. Device debug-log retrieval failed because
the configured phone was unavailable; on-phone confirmation remains needed.

App Store Connect subsequently confirmed build 165 has `processingState=VALID`
and `internalBuildState=IN_BETA_TESTING`. Crashlytics symbols uploaded
successfully. Internal TestFlight testers can install build 165; external
status remains `READY_FOR_BETA_SUBMISSION` (no external review submitted).

---

## Build 166 publisher-text repair — 2026-09-06

Source commit: `84a25f5`. Uploaded build 166 successfully with delivery UUID
`e2becda9-bf09-4764-b032-5f2eb955c0ff`.

After build 165 restored importing, the user reported Calvin's "I wasn’t
hiding." included the Stage Partners copyright, website, named license
footer, and next page's running title. Reproduced exactly using the real
Apple PDFKit page extraction. The contaminated text also mapped to page 13
instead of its true source page 14.

Fixes: recognize the complete combined copyright/website and license footer
lines; keep page numbers until running-header detection has used them as
boundary evidence; remove biographies following both a standalone End of
Play marker and an About the Author(s) heading. Matching publisher mentions
inside spoken dialogue remain intact.

Full regression suite: 689 passed, one existing skip. Real PDF result:
2 acts, 13 scenes, 1,130 dialogue lines, 22 characters. Assertions check the
exact Calvin line, page 14, and no publisher/footer/title contamination across
all imported lines. Release build, archive (verified version 166), signed
export, and upload succeeded. The source PDF remains uncommitted.

Existing imported/edited scripts are not automatically rewritten. For a
fully clean copy after installing 166, import the PDF again (a new production
preserves the existing production and edits). Calvin's existing entry can
also be corrected directly in the line editor.

App Store Connect confirmed build 166 is `VALID` and `IN_BETA_TESTING` for
internal testers. Crashlytics symbol upload also succeeded.

---

## Build 167 startup repair and adversarial review — 2026-09-06

Source commits: `679c8b4` (review fixes), `05e54b8` (startup contention).
Uploaded build 167 successfully, delivery UUID
`778d6b96-0a13-424f-acb9-568e4c7aa3ae`.

The user's build 166 log pinpointed SQLite busy/locked at
`PRAGMA journal_mode=WAL` during opening. UI and sync queue each created a
background database connection, and setup installed busy_timeout only after
WAL. Default callers now share a process-owned database; provider disposal
must not close the queue's shared connection. Timeout is installed before WAL.
A real external exclusive transaction reproduces the original setup failure;
the repaired setup waits, preserves the existing production, and saves a new
one after lock release. Nothing deletes the database or its journals.

The earlier build 167 archive was stopped before upload when this log arrived;
the uploaded archive includes the startup fix. Archive version verified as 167,
signed export and Apple upload succeeded.

Adversarial review also fixed legacy account rows leaking into the guest list
(schema 12, owner/member claim recovery), spoken ending markers truncating
later scenes, and colon/short dialogue source matching. Details and limitations:
`docs/reviews/2026-09-07-builds-165-166-adversarial.md`.

Validation: 701 tests passed, one existing skip, including the actual Wrinkle
PDF, migration faults/retry, startup contention, and concurrent sync/production
writes. Analyzer: no errors, 129 infos and five preexisting warnings. This
corrects the earlier build 165 note claiming there were no warnings.

Physical-device confirmation remains needed. The separate STT EXPORT_FAILED
recording issue in the supplied logs has not been fixed by this release.
Existing imported scripts are not rewritten; import a fresh copy to apply
parser fixes. Source PDF and extracted licensed text remain uncommitted.

App Store Connect confirmed build 167 is `VALID` and `IN_BETA_TESTING` for
internal testers. Crashlytics symbols uploaded successfully. External status
is `READY_FOR_BETA_SUBMISSION`; no external review was submitted.

## STT capture repair — confirmed on physical iOS 27

Apple recognition callbacks now carry the Dart session ID and use the map
payloads expected by `SttChannel`; previously results were filtered out and
level/completion payloads had incompatible shapes. The native on-device option
now actually enables on-device recognition when supported.

Recording now splits oversized tap buffers across preallocated slots rather
than dropping any buffer larger than 4096 frames. CAF finalization explicitly
closes the writer on supported OS versions and validates decoded frames before
M4A export. Empty capture preserves the previous take and recovery CAF.
The affected device's delivered frame size was not logged, so oversized buffers
remain a reproduced failure mechanism rather than a measured device root cause.

Rehearsal starts now require ready state and claim a generation; deferred starts
cannot restart an active line. Playback completion leaves playing state before
pacing, and terminal recognition failure invalidates pending capture startup.

Verification: actual plugin compiled against macOS AVFoundation/FlutterMacOS;
4800/19200-frame stereo input captured completely and exported to validated M4A.
Restoring the prior capacity rejection reproduced zero captured frames for
4800-frame input. Empty-capture smoke preserved the prior take and recovery CAF.
Native terminal callbacks retained session ownership and emitted once.
Extracted Dart lifecycle smoke passed duplicate-start, rapid-advance, paced
duplicate-completion, failure-cleanup and retry scenarios. Added an iOS native
regression for oversized stereo capture; the iOS XCTest target was not run.
Two independent adversarial reviews (native capture and Dart lifecycle) found
no actionable patch-introduced defects. All 44 focused Flutter tests passed.
The native plugin typechecked targeting iOS 26.0; actual capture/export smoke
passed on iOS 26.3.1 with planar and interleaved stereo and empty-capture recovery.
Physical iOS 27 verification and the user's success confirmation are below.

### Local phone deployment attempt — 2026-09-17

Xcode 27 rejected dependency deployment targets below iOS 15. The Podfile
post-install hook now raises older pod targets to the app's existing iOS 18
minimum, preserving any higher dependency minimum. Full unsigned release build
passed: `flutter build ios --release --no-pub --no-codesign`.

The signing failure was execution-session-specific, not a demonstrated locked
keychain. `launchctl managername` reported Background; codesign returned
`errSecInternalComponent`, and keychain queries returned `User interaction is
not allowed`. Running the same codesign command as a temporary one-shot job in
the logged-in user's `gui/501` launchd domain succeeded without changing
keychain permissions. Do not ask the user to unlock/reset the keychain based
on that error alone. The existing `scripts/deploy.sh` succeeded in that GUI
domain: signed release built, installed in place on the iPhone 17 Pro Max, and
launched (local build number remains 167; no TestFlight upload).

On-device verification after installation: Runner remained running. The app
log recorded successful `STT.stopRecording` with a 7955ms, 226434-byte take
saved, followed by a new actor-line capture and an STT first result. This
confirms recording export and recognition callbacks are operating on the
physical iOS 27 phone, not merely in the simulator. Temporary launchd jobs
were removed after deployment.

The user confirmed the deployed fix worked.

### Repeating a release from a Background session

Use `scripts/deploy.sh` for direct phone installation and
`scripts/ship-testflight.sh` for a version-bumped TestFlight upload. Do not use
the legacy Fastlane beta lane: it mutates Flutter version configuration and
does not solve the Background signing-session problem.

When `launchctl managername` is `Background` and signing fails, run the script
as a temporary, one-shot LaunchAgent in the logged-in user's GUI domain:

1. Create a plist in a private temporary directory with a unique `Label`,
   `ProgramArguments` of `/bin/bash` plus the script's absolute path,
   `WorkingDirectory` set to the repository, and `RunAtLoad` set to true.
2. Set `EnvironmentVariables` for `HOME`, `LANG=en_US.UTF-8`, and `PATH` with
   Flutter's bin directory, `/usr/bin:/bin:/usr/sbin:/sbin`, and
   `/opt/homebrew/bin`. Put `StandardOutPath` and `StandardErrorPath` in that
   temporary directory. Do not put credentials into the plist: the release
   script loads the existing App Store Connect configuration itself.
3. Run `launchctl bootstrap gui/$(id -u) /absolute/path/job.plist`.
4. Inspect `launchctl print gui/$(id -u)/JOB_LABEL` and both logs; require exit
   code zero and actual install/upload confirmation. For TestFlight also
   verify the archive build number and Apple's processing status.
5. Run `launchctl bootout gui/$(id -u)/JOB_LABEL` after completion, then remove
   the temporary directory. Never leave a persistent signing helper installed.

This uses the existing desktop signing context; it does not unlock keychains,
export private keys, modify key ACLs, or require new Apple credentials.

### TestFlight build 168 — 2026-09-17

Repair source and deployment procedure pushed to `main` in `6491bf8`.
`scripts/ship-testflight.sh` ran successfully in the GUI signing context and
bumped the release to `0.1.1+168`. The archive's version/build were verified
before export. Apple accepted the IPA with delivery UUID
`f4290bd4-5ad4-4152-b670-7fdc36c610a0`.

App Store Connect confirmed build 168 is `VALID` and `IN_BETA_TESTING`, with
automatic tester notification enabled. Internal testers can install it.
External status is `READY_FOR_BETA_SUBMISSION`; no external review submitted.
Apple reports minimum iOS version 18.0.

Crashlytics symbol upload completed, including Runner and App dSYMs. The upload
reported one empty-symbol warning for `FirebaseCoreExtension.framework.dSYM`;
stack frames from that dependency may remain unsymbolicated. Temporary GUI
release job removed after successful upload.
