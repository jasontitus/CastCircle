# Review verdicts — 2026-08-13

Independent verification (Claude subagents, adversarial re-read of every cited
site) of the two DeepSeek-V4-Pro sweep reports:

- `PI_REVIEW_BUGS_DEEPSEEK_V4_PRO_20260813.md` — 109 findings:
  **50 confirmed / 0 refuted / 1 partial / 58 unsampled**
  (all 2 high + 19 medium verified in depth; 30 lows sampled)
- `PI_REVIEW_PERF_DEEPSEEK_V4_PRO_20260813.md` — 65 findings:
  **34 confirmed / 2 refuted / 12 partial / 17 unsampled**
  (all 24 mediums verified; 24 lows sampled)

An unusually precise bug sweep: nothing refuted outright. The perf sweep is
directionally right but inflates severity on cold paths (see PARTIALs).

## Fix first (correctness/security)

1. **[high] ios/Runner/BackgroundDownloadPlugin.swift:152** — download state is
   RAM-only, dest path never persisted; a background download finishing after
   app termination is discarded (multi-GB silent re-download).
2. **[high] lib/features/script_editor/character_manager_screen.dart:755** —
   `_rebuildScript` keeps stale `startLineIndex`/`endLineIndex` after
   `_applyDelete` shifts lines; rehearsal plays the wrong slice.
   `ParsedScript.remapScenes` exists for exactly this.
3. **[medium] supabase/migrations/20260319000001_join_flow_rpc_v2.sql:54/:19** —
   `claim_cast_invitation` (SECURITY DEFINER) claims any `user_id IS NULL` row
   with no intended-identity check, and `fetch_cast_for_join` (no membership
   check) enumerates the target ids → invitation/role takeover.
4. **[medium] lib/data/repositories/production_repository.dart:175** —
   `saveScenes` delete-then-insert without a transaction (sibling
   `saveScriptLines` does it right); crash mid-save loses all scenes.
5. **[medium] lib/data/database/app_database.dart:128** — every migration step
   swallowed by `catch (_) {}`; Drift still advances `user_version`, so a
   failed `addColumn` is masked forever → "no such column" on later queries.
6. **[medium] lib/features/settings/ai_models_screen.dart:110** — "Delete
   Kokoro voices" runs `clearCache()` which recursively deletes all of
   `Documents/models`, including live-ASR models; UI still shows "Installed".
7. **[medium] ios/.../DataResourcesUtil.swift:21** — silver lexicon loaded with
   `subdirectory:"Resources"` but bundle flattens resources; silently loads
   `[:]`, forcing a BART forward-pass per non-gold word (perf hit too).
8. **[medium] recordings_browser_screen.dart:360** — `Dismissible.onDismissed`
   awaits file+DB deletes before removing from provider state → "dismissed
   widget still in tree" + possible dangling DB row.

Also confirmed, security-adjacent: `debug_reports` INSERT `WITH CHECK (true)`
allows forging rows as another user; recordings UPDATE policy lacks
`WITH CHECK` (row can be repointed); legacy join codes backfilled from a
16.7M-space hex alphabet vs the 31-char generator; join RPC unthrottled;
`supabase_service.dart:485` logs join codes to the exportable debug log;
cast-members INSERT policy allows self-granted `role='organizer'` (no
server-side power, but inconsistent with the RPC); two test suites
(`supabase_join_test`, `supabase_service_test`) sign up against the
**production** Supabase every run; five tests are green-while-asserting-nothing
(`parser_accuracy` ×1 pattern, `stt_vocabulary` ×2, etc.); six integration
tests + `parse_script.py` hardcode absolute developer paths.

## Perf: fix first

1. **[medium] rehearsal_screen.dart:995** — `cacheExtent: 10000` + root-level
   `ref.watch(currentLineIndexProvider)` rebuilds ~145+ offscreen rows on every
   line advance during live rehearsal (the app's core loop). Caveat: rows are
   variable-height — use estimated-offset scrolling, not `itemExtent`.
2. **[medium] pdf_page_view.dart:104** — every page flip re-opens the PDF and
   re-renders at fixed 3× (~17 MB RGBA + decode, no cache) → multi-hundred-ms
   flips and jetsam-scale transients. Keep 8× zoom; add a bounded LRU +
   doc-handle reuse.
3. **[medium ×2 + low] script_parser.dart:1127/1474/64** — 6-7 `RegExp`
   compiles per raw line during import (~10⁵ per import; the file itself
   documents fixing this class before). Trivial `static final` hoists.
4. **[medium ×2] ios ConvWeighted.swift:100 + TextEncoder.swift:102** —
   per-forward weightNorm recompute on every conv layer + scalar-`0.0` masks
   promoting bf16→fp32, every TTS synthesis.
5. **[medium] android AndroidSttPlugin.kt:460** — `releaseRecorder()` joins the
   capture thread on the main thread (≤1.5 s freeze); sibling `stopRecording`
   already has the off-main pattern. (Sub-claim wrong: `dequeueInputBuffer`
   timeout is 10 ms, not 10 s.)
6. **[low ×2] supabase_service.dart:653/721** — unpaginated full `recordings`
   fetch per production open (multi-MB JSON on UI isolate) and 40 serial RTTs
   to save a 4 000-line script — the two biggest sync-latency levers.
7. **Unthrottled download progress family** — macOS
   `BackgroundDownloadPlugin.swift:137` (confirmed) **plus the identical
   unflagged iOS file (report false-negative, matters more)** plus
   `model_manager.dart:327`; sibling `model_download_service.dart:595` shows
   the intended 1 MB-delta throttle.
8. **[low] ocr_review_screen.dart:428** — spread-map prebuilds every review
   card (construction isn't lazy in `ListView`); the in-code comment claiming
   laziness is wrong.

## Refuted / corrected — do not "fix"

- **[medium perf] ios/Runner/PaddleOcrPlugin.swift:253** — "per-pixel heap
  allocation" refuted empirically: `swiftc -O -emit-sil` shows the neighbor
  literal outlined to a `[bare]` immortal global (no alloc, no ARC) in release
  builds.
- **[medium perf] debug_log_service.dart:187** — synchronous append is a
  documented deliberate crash-forensics design (no fsync ⇒ tens of µs); the
  proposed buffered flush would lose the last 30 s exactly when needed.
- **[medium bugs] macos VisionOcrPlugin.swift:97** — missing scale clamp is
  real but the "malicious caller" framing is overstated (only trusted caller
  passes 2.0); add a defensive clamp, nothing more.
- Fix-advice corrections on confirmed findings:
  `kokoro_onnx_service.dart:182` — the mtime touch IS the LRU; move it and
  eviction becomes FIFO. `AppleSttPlugin.swift:382` (bugs report) — don't stop
  the shared engine; serialize `audioFile` on a queue instead.
- Severity deflations (real but cold-path/small): BART decoder O(t²) capped at
  50 steps; `script_models.dart:363` rebuild cost is sub-ms (ListView builds
  ~10 rows); `recording_sync_service.dart:558` runs twice per production open,
  not per rebuild; `parse_script.py:140` — Python `re` caches compiled
  patterns, and the Dart parser already memoizes (the "mirrored on device"
  claim is false).

## Duplicates (one fix each)

Bugs: unguarded `setState`-after-`await` ×4 screens; empty-join-code URI ×2;
delete+insert-no-transaction ×3; `enum.byName` throws ×2; PdfRenderer fd-leak
×2 (Android); hardcoded dev paths ×7; silent-green tests ×5.
Perf: `script_models.dart:363` ≡ `recording_character_screen.dart:59` (exact);
`hasEmbeddedText` sync ×3 platforms; Albert init copy-loops ×3; mean+variance
double reduction ×2; per-line RegExp ×3 sites; unthrottled progress ×3 (incl.
the unflagged iOS one); `KokoroTTS.swift:281` is a self-described non-finding.

## Provenance & cost

Model `deepseek/deepseek-v4-pro:high` (api.deepseek.com), 4-wide live sweeps
over 274 files + refeed. Bugs: $0.91 (934k in / 15.4M cached / 514k out).
Perf: $0.73 (1.06M in / 8.9M cached / 275k out). Repo total ≈ **$1.64** at
2026-08-13 list prices.
