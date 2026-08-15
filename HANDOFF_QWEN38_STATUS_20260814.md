# Status handoff — CastCircle review work (2026-08-14)

Session handoff note — committed to the branch for continuity. Do not commit
`PI_REVIEW_COVERAGE_DEEPSEEK_V4_PRO.md` — pre-existing, not ours.

## Branch state

- Branch: **`bionic/qwen38-full-review`** — pushed, tracks `origin/bionic/qwen38-full-review`.
- PR (not yet created): https://github.com/jasontitus/CastCircle/pull/new/bionic/qwen38-full-review
- Commits on the branch (newest first):
  - `49356f1` Drop redundant `!` on matchStart (analyzer warning from merged OCR-mapping code)
  - `ec01b68` Merge origin/main into bionic/qwen38-full-review
  - `d94a50d` Fix cast rebuild consistency, ensemble reassignment, PDFKit page mapping, acts leak
  - `a40f7eb` docs: add full code review (Qwen 3.8, 2026-08-14)  ← the review doc, `QWEN38_REVIEW_FULL_20260814.md`
- Branch was cut from `main` at `fdd868f`; `origin/main` has since moved to `f1aba91`
  (7 commits: OCR review-sheet UX, `OcrHighlightMatcher` best-match OCR mapping
  `7ec7dfb`, version bump to `0.1.1+147`) and is fully merged into our branch.

## DONE (committed, verified)

The "correctness batch" — findings #1–#4 of `QWEN38_REVIEW_FULL_20260814.md`:

1. **#1 Shared rebuild helper** — `rebuildCharacters()` top-level function in
   `lib/data/models/script_models.dart`: credits multi-character lines per
   individual (never the combined cue name), sorts by line count desc,
   assigns `colorIndex` in that order, `genderFor` callback with female
   default. All six former inline rebuild sites now route through it:
   - `lib/data/services/script_parser.dart` (`parse()`, gender inference from raw text)
   - `lib/providers/production_providers.dart` (`buildParsedScript` + `loadPersistedScript`
     with saved-gender overrides)
   - `lib/features/script_editor/script_editor_screen.dart` (`_rebuildScript`)
   - `lib/features/script_editor/character_manager_screen.dart` (`_rebuildScript`)
   Unit tests: `test/character_rebuild_test.dart` (6 tests).
2. **#2 Stale ensemble credit** — `script_editor_screen.dart` `_updateLine` clears
   `multiCharacters` (`const []` — `null` means "keep" in `copyWith`) when the line's
   character is reassigned, so rehearsal `isForCharacter` stops matching old ensemble
   members.
   - **Self-decided extra (disclose if it ever becomes a question)**: `_applySplit`
     now carries `multiCharacters` into the second line of a split (previously dropped,
     demoting the shared line to single-speaker). One line, same bug class as #2.
3. **#3 Bounded PDFKit page mapping** — `lib/data/services/script_import_service.dart`:
   - Extracted the OCR path's match closure into static `_lineTextMatch` (shared by the
     confidence-averaging loop in `parseAndMapOcr` and the PDFKit path).
   - `_importFromPdfInner` now normalizes raw lines with `_normForMatch` before mapping.
   - `_findSourcePageFrom` rewritten: normalized search text, bounded window
     (`_sourcePageSearchWindow = 150`), `_lineTextMatch`. Return shape unchanged
     `({int page, int lineOnPage, int rawLineIndex})?` with `lineOnPage: 0`.
   - **Merge note**: upstream `7ec7dfb` replaced the OCR path's first-match scan with
     scored best-match (`OcrHighlightMatcher.bestMatch`) + dual-anchored window
     (46% → 98% locatable). The merge kept upstream's side; `_lineTextMatch` now serves
     the confidence loop + PDFKit path only.
4. **#4 `acts` Expando leak** — `ParsedScript.acts` memo dropped; plain linear scan with
   a comment explaining why it must not be re-memoized.

Plus: merge of `origin/main` (one conflict hunk in `script_import_service.dart`,
resolved in upstream's favor — see #3 note) and the `matchStart!` redundant-assertion
fix from that merged code.

### Verification baselines (post-merge, current)

- `flutter analyze`: **160 issues = 11 warnings + 149 infos**, all pre-existing
  (none in code we wrote). Known remaining `unnecessary_non_null_assertion` is in
  `integration_test/android_rehearsal_harness_test.dart:268` (part of the Low batch).
- `flutter test --exclude-tags extended`: **497/497 passed** (483 pre-existing
  baseline + 6 new ours + 8 upstream). Extended-tag parser corpus tests (~90s)
  are NOT in that count.

## NOT DONE (all unapproved — need user go-ahead before starting)

From `QWEN38_REVIEW_FULL_20260814.md` (sections "Medium", "Low",
"Optimization opportunities", "Structural"):

- **Medium #5**: `supabase_service.dart:671-701` non-atomic delete+insert in
  `saveScriptLines` → server-side transaction / `script_version`.
- **Medium #6**: production delete leaves residue — `SyncQueue` jobs keep uploading
  (no FK on `recordings`), prefs keys (`voice_overrides_<id>`, `character_genders_<id>`,
  `character_locales_<id>`, `voice_preset_<id>`, `rehearsal_pos:<id>:...`) never cleaned.
- **Medium #7**: `debug_log_service.dart:156-176` sync file I/O on caller thread
  (UI isolate) → batch + async flush, keep sync only for `logError`.
- **Medium #8**: `tts_service.dart` / `SttService` dispose leaves `_systemTts`
  (and STT channel) undisposed; document-or-complete the teardown.
- **Medium #9**: `_buildScenesFromLines` mints fresh `Uuid()` per rebuild →
  deterministic scene IDs (hash of act|scene|counter).
- **Low batch**: remaining 11 analyzer warnings (dead `_syncToCloud` in
  `script_editor_screen.dart`, unused imports `main.dart:15` +
  `production_providers.dart:5`, unused `_productionId` field, `voice_clone_service.dart`
  unused import + `_initialized`, redundant null check `rehearsal_screen.dart:3252`,
  `@visibleForTesting` on private `_abbrevRe` `tts_service.dart:488`,
  `android_rehearsal_harness_test.dart:268`); dead `voice_clone_service.dart`
  (self-declared unreferenced, `isReady => false`); shadowed `script` param in
  `_buildScriptView` (`rehearsal_screen.dart:994-999`); deprecated `groupValue` radios
  (`cast_manager_screen.dart:1330`); about-dialog version drift
  (`home_screen.dart:600` '0.1.0' vs pubspec 0.1.1+147 → `PackageInfo`); per-build
  `debugPrint` `production_hub_screen.dart:140`; "LRU cap" naming in
  `audio_level_service.dart:56-58`; `web-editor/` stub status; embedded Supabase
  URL/key in `main.dart:71-74` → `--dart-define`s.
- **Optimizations**: `ScriptParser._detectTitleHeaders` O(n²) (`script_parser.dart:262-281`);
  `_extractLocation` compiles 13 regexes per call (`script_parser.dart:1259-1264`) → hoist;
  `SyncQueue` serial uploads → concurrency 2–3 (pattern in `RecordingSyncService._runPooled`);
  `fetchMyProductions` two round-trips → one joined query/RPC; STT per-partial scoring
  off main isolate (measure first); vocab linear scan → index (only if it grows).
- **Structural**: no CI — add GitHub Actions (analyze fail-on-warnings +
  `flutter test --exclude-tags extended` on PRs, full suite nightly); tighten
  `analysis_options.yaml` (unawaited_futures, prefer_final_locals, …); pin
  vendored Swift Kokoro provenance (`ios/Runner/KokoroVendored/`).

Suggested next-batch order (my recommendation, offered to user): Low cleanup
(mechanical, fast) or CI first.

## Pending decisions / open questions

1. **`pubspec.lock`** — modified in the working tree (side effect of running
   `flutter analyze`/`flutter test` on the local SDK; transitive re-resolution,
   e.g. analyzer 12.1.0→10.0.1). NOT committed, NOT pushed. User asked (twice)
   whether to restore it or leave it — **no answer yet**. Do not include it in any
   future commit without asking.
2. **`_applySplit` multiCharacters carry-over** — our self-decided one-line addition
   beyond the approved scope; disclosed in the session summary. If the user objects,
   it's the single hunk in `script_editor_screen.dart` `_applySplit`
   (`multiCharacters: line.multiCharacters,`).
3. **Next batch choice** — Medium / Low / Optimizations / CI: awaiting user pick.
4. **PR** — branch is pushed; PR not created (user hasn't asked).

## Working tree (do not disturb)

- ` M pubspec.lock` — see decision 1.
- `?? PI_REVIEW_COVERAGE_DEEPSEEK_V4_PRO.md` — pre-existing, not ours, leave alone.
- `HANDOFF_QWEN38_STATUS_20260814.md` — this file; committed with this status note.
- Pre-existing stash `stash@{0}` belongs to `bionic/fix-bugs-performance` — not ours.

## House style / constraints

- Work on `bionic/qwen38-full-review`; no new branches without asking.
- Pushing: user has explicitly requested pushes as needed (branch is pushed;
  don't force-push, don't rewrite pushed history).
- Do not touch/revert unrelated working-tree changes without asking.
- Code style: concise, heavily-commented with *why* (measured field failures);
  review docs are severity-tagged; commits are descriptive.
- Verify after changes: `flutter analyze` (baseline above) +
  `flutter test --exclude-tags extended` (baseline above); mapping changes must
  keep `test/ocr_confidence_mapping_test.dart`,
  `test/ocr_page_mapping_distribution_test.dart`, `test/pdf_import_test.dart`,
  `test/ocr_highlight_hitrate_test.dart` green.
