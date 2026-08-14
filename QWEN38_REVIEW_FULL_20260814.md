# Full code review — 2026-08-14 (Qwen 3.8)

Whole-project review of the CastCircle Flutter app: every Dart file under
`lib/` (74 files, ~38k lines) read end-to-end — entry points, app shell,
providers, all 30 data services, all feature screens, Drift schema +
migrations, models, repository — plus the `supabase/` migrations (schema +
RLS spot-checks). Native platform code (Swift/Kotlin plugins) and the
vendored Swift Kokoro MLX implementation under `ios/Runner/KokoroVendored/`
were **not** reviewed in depth; they are outside this review's Dart scope.

Follow-up to the 2026-08-13 DeepSeek-V4-Pro sweeps
(`PI_REVIEW_*_DEEPSEEK_V4_PRO_20260813.md`) — several of those findings are
confirmed fixed here (e.g. `saveScenes` now transactional in
`production_repository.dart`, migration steps no longer swallowed in
`app_database.dart`, rehearsal rebuild-storm and `cacheExtent` fixes landed).

## Baseline verification

| Check | Result |
| --- | --- |
| `flutter analyze` | 156 issues — **11 warnings, 145 infos, 0 errors** |
| `flutter test --exclude-tags extended` | **483/483 passed** (~19 s) |
| Extended parser corpus tests (`extended` tag, ~90 s) | not run |
| Runtime behavior | not exercised on device; findings verified by code reading |

## Overall assessment

An unusually well-engineered codebase. The defensive depth is real, not
performative: generation counters for stale TTS completions
(`tts_service.dart`), epoch guards on isolate restarts
(`live_asr_service.dart`, `kokoro_onnx_service.dart`), atomic temp-file +
rename persistence (`sync_queue.dart`, `recording_sync_service.dart`),
path-traversal rejection at cloud boundaries
(`recording_sync_service.dart` `isSafePathId`), migration steps that
tolerate only the already-applied error (`app_database.dart`), WAL +
`busy_timeout` pragmas, and comments documenting *measured* field failures
("11 s of silence", "35+ s of dead air", "field: iPhone 2026-08-13").
Testing is strong: 42 unit-test files, 14 integration tests, corpus-based
parser tests with an `extended` tag for the slow ones.

The findings below are the gaps that remain.

## Findings

### High (correctness)

1. **[high] `lib/features/script_editor/script_editor_screen.dart:1160-1166, 1213-1219`**
   — `_rebuildScript` / `_updateLine` recount characters using only
   `line.character`, while `ScriptParser.parse`, `buildParsedScript` and
   `loadPersistedScript` all credit each name in `multiCharacters`. After
   editing *any* line in a production with ensemble lines
   ("MACBETH AND LENNOX"): the combined string appears as a phantom
   character (editor chips, cast manager, voice assignment), the
   individuals lose line counts, and — because characters are sorted by
   count — **`colorIndex` reshuffles and cast colors change mid-session**.
   The phantom doesn't survive a restart (load rebuilds with multi-credit),
   so it's easy to miss. Fix: extract one shared `rebuildCharacters(lines,
   {genders})` helper used by all five call sites (parser, two provider
   loaders, two editor methods) and unit-test it. This also removes the
   current 4-way duplication of the counting logic.

2. **[high] `lib/features/script_editor/script_editor_screen.dart:1207-1210`**
   — `_updateLine` doesn't reconcile `multiCharacters` when the character
   is reassigned: a multi-character line re-pointed at a single character
   keeps the stale list, so `ScriptLine.isForCharacter` still matches the
   old ensemble members in rehearsal. Clear/recompute `multiCharacters`
   whenever `newChar != original.character`.

3. **[high] `lib/data/services/script_import_service.dart:711-730`**
   — The PDFKit text-extraction path's `_findSourcePageFrom` scans from the
   cursor **to the end of the document** with un-normalized lowercase
   `contains` in both directions. The OCR path's identical bug (cursor
   leaping to a far false match, then smearing page mapping across the rest
   of the script — every "View page" opening page ~2) was fixed with a
   bounded 150-line window + `_normForMatch` normalization
   (`script_import_service.dart:540-600`, commit 71fb8b8); the PDFKit path
   was not updated. For a short parsed line, a coincidental raw line deep
   in the document moves the cursor there and every later line loses its
   `sourcePage`. Apply the same bounded window + normalized matching (or
   share the code) to `_findSourcePageFrom`.

4. **[high] `lib/data/models/script_models.dart:406-415`**
   — `ParsedScript.acts` memoizes via a **static `Expando`**, which holds
   strong references to its keys. Every `ParsedScript` on which `acts` was
   read (the production hub reads it on every build) stays reachable for
   the app's lifetime — along with its `lines` and its `rawText`, which is
   multi-MB for scanned plays. Over a long editing session this is unbounded
   growth. Drop the memo (a linear scan over a few thousand lines is
   ~microseconds; the screens already memoize around it) or use a capped
   identity-keyed LRU. Related: `rawText` rides along in
   `currentScriptProvider` for the whole session though it's only needed at
   import/re-parse — consider clearing it after the import flow completes.

### Medium (robustness & performance)

5. **[medium] `lib/data/services/supabase_service.dart:671-701`**
   — `saveScriptLines` is a non-atomic delete+insert. A push that dies
   mid-flight leaves a truncated cloud script. `_refreshScriptFromCloud`
   refuses >50% shrinkage (`home_screen.dart:254-266`), but
   `_reconcileCloudScript` (the no-local-script path) and the join flow
   adopt whatever the cloud has. Best fix: make the replace a server-side
   transaction (a `replace_script_lines` RPC, or a PostgREST transaction),
   and/or add a `script_version` column so a partial push is detectable on
   pull.

6. **[medium] `lib/features/home/home_screen.dart:458-560`**
   — Deleting/leaving a production leaves residue:
   - `SyncQueue` jobs for the production keep uploading; the cloud
     `recordings` table has **no FK to productions** (verified in
     `supabase/migrations/20260314061409_initial_schema.sql:106`), so this
     creates orphan storage objects + metadata rows, and after 5 retries the
     user gets an "upload failed" toast for a production that no longer
     exists. Add `SyncQueue.removeForProduction(id)` and call it in
     `_deleteProduction`.
   - Prefs keys never cleaned: `voice_overrides_<id>`,
     `character_genders_<id>`, `character_locales_<id>`,
     `voice_preset_<id>`, and the many `rehearsal_pos:<id>:...`
     checkpoints.

7. **[medium] `lib/data/services/debug_log_service.dart:156-176`**
   — `log()` → `_appendSync` → `writeAsStringSync` runs **on the caller's
   thread**, which is the UI isolate for TTS speak, rehearsal line
   processing, and STT result paths — exactly the frames where the app is
   already doing heavy work. Sync file I/O is a classic sporadic-jank
   source, and the app's own `FrameStatsService` exists to measure exactly
   this. Suggestion: batch entries and flush asynchronously (the 30 s timer
   already exists), keeping the synchronous write only for `logError`
   (the crash-relevant entries).

8. **[medium] `lib/data/services/tts_service.dart:903-907`**
   — `TtsService.dispose()` cancels the player subscription and disposes
   `_audioPlayer` but never disposes `_systemTts` (platform channel +
   AVSpeechSynthesizer). Same story for `SttService.dispose()`/`SttChannel`
   — nothing calls them because these are app-lifetime singletons. Complete
   the teardown or document that `dispose()` is unused and remove the dead
   half.

9. **[medium] `lib/providers/production_providers.dart:700-709`**
   — `_buildScenesFromLines` mints a fresh `Uuid()` for every scene on every
   rebuild, so any load of a production without persisted cloud scenes gets
   different scene IDs each time. Today's consumers mostly survive
   (progress keys use `sceneName`; `remapScenes` preserves IDs), but it's a
   latent trap for anything keyed by scene ID (deep links, future history
   references). A deterministic ID (hash of `act|scene|counter`) would be
   safer.

### Low (cleanup)

- **11 analyzer warnings**: dead `_syncToCloud`
  (`script_editor_screen.dart:1255`); unused imports in `main.dart:15`
  (`deep_link_service.dart`) and `production_providers.dart:5`
  (`foundation`); unused `_productionId` field in `CastMembersNotifier`
  (`production_providers.dart:205`); unused `dart:typed_data` import +
  unused `_initialized` field in `voice_clone_service.dart:5,69`; redundant
  null check `rehearsal_screen.dart:3252`; `@visibleForTesting` on private
  `_abbrevRe` at `tts_service.dart:488` (`invalid_visibility_annotation`);
  `unnecessary_non_null_assertion` in
  `integration_test/android_rehearsal_harness_test.dart:268`.
- **Dead code**: `lib/data/services/voice_clone_service.dart` is
  self-declared unreferenced with a stubbed backend (`isReady => false`) —
  delete it or move it out of `lib/` so it stops shipping and getting
  analyzed.
- **Shadowed parameter**: `_buildScriptView`'s `script` parameter is
  shadowed by a local `ref.read(currentScriptProvider)` and never used
  (`rehearsal_screen.dart:994-999`) — drop the parameter.
- **Deprecated API**: `groupValue` radio usage at
  `cast_manager_screen.dart:1330` (deprecated in Flutter 3.32, migrating to
  `RadioGroup`) — schedule the migration.
- **Version drift**: `showAboutDialog(applicationVersion: '0.1.0')`
  (`home_screen.dart:600`) vs pubspec `0.1.1+140` — use `PackageInfo`
  (already a dependency).
- **Per-build `debugPrint`** in `production_hub_screen.dart:140` — noisy;
  gate behind a debug flag.
- **Naming**: `AudioLevelService` calls its FIFO eviction an "LRU cap"
  (`audio_level_service.dart:56-58`).
- **`web-editor/`** contains only a stub `index.html` while the app links
  out to `castcircle-app.web.app` — document its status or remove the
  directory.
- **Supabase URL + publishable key are embedded defaults** in
  `main.dart:71-74`. Publishable keys are public by design, but making them
  required `--dart-define`s would avoid shipping a stale key into every
  build.

## Optimization opportunities

The hot paths have clearly been profiled (two-row LCS in `stt_service.dart`
and `stt_vocabulary_service.dart`, hoisted regexes throughout the parser,
`Isolate.run` for JSON encode / parse / OCR scoring, pooled sync workers in
`recording_sync_service.dart`, per-row provider `select`s in the rehearsal
screen). Remaining items, in rough value order:

1. **`ScriptParser._detectTitleHeaders`** — `prevNonEmpty`/`nextNonEmpty`
   are O(n) per line → O(n²) worst case over the raw document
   (`script_parser.dart:262-281`). Precompute previous/next non-empty
   indices in one pass.
2. **`ScriptParser._extractLocation`** compiles each of the 13 location
   regexes on every call (`script_parser.dart:1259-1264`); it runs inside
   the scene-detection loops. Hoist to compiled static patterns.
3. **`SyncQueue` uploads serially** — a first-time queue of 50+ recordings
   pays 50 sequential round-trips; `RecordingSyncService._runPooled`
   (concurrency 4) shows the pattern already in the codebase. Concurrency
   2–3 in the queue would cut time significantly with modest storage
   pressure.
4. **`SupabaseService.fetchMyProductions`** is two sequential round-trips
   (cast_members, then productions) — one joined query or RPC would halve
   the home-screen restore latency.
5. **Per-partial scoring pipeline** (vocab correction + LCS + endpointing
   checks) runs on the main isolate several times a second. It's optimized,
   but on low-end Android an isolate with a small work queue would remove
   the last of the STT-path jank risk — measure before doing.
6. **`SttVocabularyService._bestVocabularyMatch`** is a linear scan of all
   "important words" per unknown word (memoized, capped at 4000) — fine
   today; a length-bucketed index or BK-tree would scale if the vocabulary
   grows.

## Structural / process recommendations

- **No CI** (no `.github/`): with 483 unit tests and an analyzer baseline,
  a GitHub Actions job running `flutter analyze` (fail on warnings) +
  `flutter test --exclude-tags extended` on PRs — plus the full suite
  nightly — would prevent regressions like finding #1 (which a test on the
  editor's character rebuild would have caught).
- **Tighten `analysis_options.yaml`**: selectively enable
  `unawaited_futures`, `prefer_final_locals`, `avoid_redundant_argument_values`,
  etc.; the 145 infos are mostly mechanical and would drop quickly.
- **Consolidate the character-rebuild logic** (finding #1) into one tested
  helper — it's the single most duplicated algorithm in the app.
- **Vendored Swift Kokoro** (`ios/Runner/KokoroVendored/`) is a large
  third-party copy maintained in-repo; pin its provenance (source commit,
  license header) in the README to reduce future maintenance risk.

## Suggested follow-up batches

1. **Correctness batch**: #1 (shared character-rebuild helper + unit test),
   #2 (multiCharacters reconciliation), #3 (bounded PDFKit page mapping),
   #4 (drop the `acts` Expando memo). All small, well-scoped.
2. **Robustness batch**: #5 (server-side atomic script replace),
   #6 (production-delete cleanup: sync queue + prefs), #7 (async log
   flushing), #8 (complete singleton teardown), #9 (deterministic scene
   IDs).
3. **Hygiene batch**: 11 analyzer warnings, dead `voice_clone_service`,
   shadowed parameter, About-dialog version, per-build `debugPrint`.
4. **Process batch**: CI pipeline, lint tightening.
