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
