# DS4 Performance Review — Triage

Source: `DS4_REVIEW_PERF.md` — full 280-file sweep (8 batches) plus coverage
top-up batches A/B1 re-reviewing the 110 files the sweep fed but never
individually evidenced. Engine: Laguna S 2.1 Q4_K_M `e2ccc05`, nothink,
repetition penalty 1.15 over a 64-token window. 93 raw findings,
deduplicated below and ranked by user-visible impact rather than raw
severity label. Top-up batches B2/B3 (12 remaining large Dart screens) were
still running at commit time; their findings land in a follow-up commit.

## P0 — Core-loop latency users feel every rehearsal

The two hottest paths in the app: TTS synthesis (every spoken line) and live
STT scoring (several times per second while an actor speaks).

1. **BART G2P fallback decoder: no KV-cache, O(n²) decode** —
   `BARTModel.swift:127/145/134/61` (top-up A). For every
   out-of-vocabulary word synthesized, the autoregressive loop re-runs
   self-attention over the entire generated prefix each step (no KV cache),
   re-allocates the growing decoder input via `concatenated` per token,
   forces a GPU→CPU `argMax().item()` sync per token, and re-projects all
   positions through the LM head when only the last is needed. The largest
   single algorithmic issue in the review. Fix order: thread KV caches
   through `BARTDecoderLayer`; project only the final position; keep
   sampling on-device.
2. **MLX `.item()` GPU→CPU sync inside loops** — `KokoroTTS.swift:365-368`
   (per output frame), `:354-359` (per phoneme + `MLX.repeated` churn),
   `TimestampPredictor.swift:43-58` (up to 4 syncs per token, one duplicated
   on the same index; same pattern in the parakeet-stt copy), and the
   Parakeet decode loops — `ParakeetModel.swift:266-267` (two syncs per
   20 ms frame in TDT decode), `:242`/`:409` (per-token extraction of full
   hypotheses). Hundreds of pipeline stalls per synthesis/transcription.
   One fix everywhere: bulk `.asArray()` before the loop.
3. **`KokoroTTS.swift:275-277` attention-mask CPU↔GPU round-trip** —
   MLXArray → Swift `[Bool]` → mapped `[Int]` → new MLXArray, twice across
   the bus per synthesis (also flagged independently in top-up A at
   `:267-275`). Replace with native MLX ops (`.== 0` + `asType`), no host
   copy.
4. **`LSTM.swift:151-152` O(n²) `insert(at: 0)`** in the backward-direction
   LSTM over every timestep — quadratic on every synthesis of a long line.
   Append + reverse once = O(n).
5. **Full DP-matrix allocation on every STT partial** —
   `stt_service.dart:299-335` (`matchScore`), its duplicated twin
   `stt_vocabulary_service.dart:460-502` (`_matchScore`), and
   `stt_vocabulary_service.dart:341-393` (`_correctAgainstExpected`).
   An (m+1)×(n+1) list-of-lists several times a second on the main isolate
   during rehearsal. The optimized two-row pattern already ships in the same
   file family (`_editDistanceAtMost`) — apply it to all three and extract
   one shared scorer (`_correctAgainstExpected` needs the byte-array
   backtrack variant).
6. **Per-sample Swift copy loops on the audio write path** —
   `parakeet-stt AudioUtils.swift:108` (streaming WAV writer, [high]) plus
   three sibling sites (`AudioUtils.swift:42/108`, KokoroVendored debug
   writer). `memcpy`/vDSP one-liners.
7. **Kokoro DurationEncoder/TextEncoder tensor churn** (top-up A) —
   per-layer zeros-then-overwrite allocations, batch-dim
   drop/slice/re-pad cycles, redundant re-masking after every sub-layer,
   per-layer axis swaps, explicit `MLX.broadcast` of constant style vectors
   (`DurationEncoder.swift:86/92/109/114/123-125`, `TextEncoder.swift` CNN
   blocks). Constant-factor waste on every synthesis step; each fix is
   small (allocate once, keep singleton batch, mask once, fix layout).

## P1 — Interaction jank and session-length degradation

8. **`rehearsal_screen.dart:645-647` `ref.listen` registered in `build()`**
   without disposal — listeners accumulate for the widget lifetime; wasted
   work per rebuild and stale closures able to clear TTS prefetch at the
   wrong time. Register once or move to a dedicated child widget.
9. **`script_editor_screen.dart:1089-1173` `_rebuildScript`/`_updateLine`**
   rescan all lines and rebuild + sort the character list on every single
   line edit (O(n + k log k) per keystroke-level action, duplicated in two
   methods). Incremental count delta + one shared helper.
10. **`ocr_review_screen.dart:99-108` `_contextLinesFor`** rebuilds the full
    filtered+sorted list per flagged card inside build → O(n²) with hundreds
    of flagged OCR lines; `:279-280` also refilters `reviewLines` on every
    `setState`. Memoize with a dirty flag.
11. **`rehearsal_screen.dart:928-1042`** — `cacheExtent: 10000` materializes
    ~50–70 offscreen items, each itemBuilder doing an O(characters)
    `indexWhere`; precompute a name→index map and cut the extent to a few
    hundred px.
12. **`script_editor_screen.dart:518-552` `_filteredLines`** — up to 5 list
    materializations + a linear `indexWhere` per build; single-pass rewrite.
13. **`AppleSttPlugin.swift:499-503`** — per-sample `append` + functional
    `reduce` RMS per 50 ms window during audio analysis; ring buffer +
    `vDSP_rmsqv`.
14. **`parakeet_debug_screen.dart:458-472`** — O(spoken × expected)
    `List.contains` inside `.map()` per live STT partial; hoist a `Set`.
14a. **`script_editor_screen.dart:429,757` `TextEditingController` leaks**
    (top-up B3) — controllers allocated per rebuilt detail-panel card and
    per `_editLine` bottom sheet, never disposed; heap and listener lists
    grow steadily through an editing session. Own the controller in State
    (or dispose on sheet close via `.then`).
14b. **`stt_adaptation_service.dart:197,210`** (top-up B2) — `addSample`
    rebuilds the whole samples list via spread on every recorded line
    (two sites); quadratic allocation churn across a session. Use a
    growable list + `.add()` with an unmodifiable view.

## P2 — Import & cold-start paths (one-shot but user-blocking)

15. **`PaddleOcrPlugin.swift:353-361`** per-pixel nested tensorization
    (~285k scalar ops/page) — vImage/vDSP bulk conversion. Same pipeline:
    **`PdfTextPlugin.swift:90`** (top-up A, [high]) builds full-document
    text via `fullText += pageText` per page — O(n²) on long PDFs; collect
    and `joined()` once. Same pattern in the macOS twin
    (`macos/Runner/PdfTextPlugin.swift:68`, top-up B3). Also in import
    (top-up B2): `script_import_service.dart:187` double pass over scored
    lines, and `:452` per-page temp-dir lookup + synchronous delete inside
    the OCR fallback page loop.
16. **`main.dart:120-136`** sequential model downloads on first launch —
    parallelize with bounded concurrency; directly shortens time-to-usable
    for new users.
17. **`script_parser.dart`** — `_mergeOcrCharacterNames` O(c²) fuzzy merge
    with allocating edit-distance (`:592-695`); `_detectCharacterCue`
    re-sorts characters and recompiles up to 4 regexes per text line
    (`:893-929`); per-character full-text `allMatches` cue counts
    (`:600-605`). Cache sorted list + compiled patterns; bounded edit
    distance; one alternation regex.
18. **`DSP.swift:141-162`** mel filterbank rebuilt per call — cache by
    config key. Also `DSP.swift:18` double `reverseArray` per STFT.
19. **Misaki G2P constants** — `Lexicon.swift:68-94` restress early-return;
    `EnglishNum2Word.swift:141/155` hoist sorted tables to statics.
20. **Python import scripts** — `pdf_to_script.py` double page-walk +
    uncompiled regexes; `parse_script.py` per-line per-character regex
    (28 compiles/line → one alternation).
21. **BART model cold-start** (top-up A) — `BARTLayerNorm`
    element-by-element weight copies per layer (`BARTModel.swift:49`),
    per-layer string-key dictionary scans (`:29`), position-ID tensor
    rebuilt per call (`:71`) — bulk-assign tensors, pre-partition weights,
    cache position IDs.

## P3 — Housekeeping (cheap wins, cold or bounded paths)

22. `KokoroMLXService.swift:340` cache prune: full metadata scan + sort per
    trigger, no hysteresis — add a high-water margin (merges the
    [medium]+[low] twin findings).
23. `KokoroMLXService.swift:272-284` WAV header: pre-size + single write;
    vectorize Float→Int16.
24. `recording_sync_service.dart:386-401,539-558` — synchronous
    `existsSync` per entry on provider reads and sync planning; TTL cache /
    batched async checks.
25. `model_download_service.dart:362-396,465-480` — sequential `_filePath`
    awaits (a platform-channel round-trip each); `Future.wait`.
26. `debug_log_screen.dart` — unconditional 2 s `setState` timer + repeated
    `join('\n')`; guard on entry count, memoize. Service side (top-up A):
    `debug_log_service.dart` full-scan `entriesForCategory`, whole-log
    `export()` string build, load-time full-file `split('\n')` —
    pre-bucket by category, stream I/O.
27. `settings_screen.dart:64-71` — new `PackageInfo` future per rebuild;
    cache it.
28. UI double-scans: `script_editor_screen.dart:249,255` low-OCR chip;
    `cloud_sync_dialog.dart:67-72` five passes over the diff list;
    `scene_editor_screen.dart:116` per-chip `indexWhere`; batch-4 lows
    (`join_production_screen`, `cast_manager_screen` share/export,
    `production_hub_screen` scene list double materialization).
29. `tool/` CLI harnesses (batch 8, dev-facing): sequential per-production
    round-trips in `orphan_sweep`; fresh `HttpClient` per call and
    sequential downloads in `sim_multi_user`/`verify_cloud_recordings`;
    O(C×E) roster scoring and per-iteration regex compiles in
    `parse_stats`/`analyze_orphaned_recordings`. Batch/parallelize + hoist.
30. `pdf_page_view.dart` — verify offscreen page-texture eviction (potential
    OOM on very long PDFs).
31. Shell/script lows: single-filtergraph ffmpeg in
    `generate_rehearsal_webp.sh`; vDSP in `test_silence_trim.swift`;
    four sequential full-text regex passes in `test_pdf_import.swift:72-96`
    (top-up B3, dev script).

## Cross-cutting fix themes

- **Bulk-before-loop**: every MLX `.item()`-in-loop site (5 files) fixes the
  same way; a grep for `.item()` inside `for` is a cheap PR gate.
- **KV-cache the autoregressive decoders**: BART fallback is the acute case.
- **Two-row DP**: three copies of the full-matrix LCS coexist with the
  already-optimized pattern — consolidate into one helper.
- **`memcpy`/vDSP over per-sample loops**: 4+ sites.
- **`Future.wait` over sequential awaits**: 4 sites.

## Coverage audit

The host fed all 280 files; per-batch coverage claims reconciled to ~170
files with individual evidence. Batch 2 (75 fed) explicitly reviewed "12
additional files"; batch 1 claimed 48 of 58; batch 5 honestly recorded three
partial reads; batch 7's unnamed remainder was test files. The top-up pass
re-fed all 110 unevidenced files under the same engine config: batch A
(92 vendored ML Swift) passed with 27 findings — including the P0 BART
decoder cluster the original sweep missed — and batches B1/B2/B3 (18 large
Dart/Swift files, including `rehearsal_screen.dart` and
`script_editor_screen.dart` in full) passed with 2/7/5.

**Audit closed.** Every fed file was re-reviewed in a passing batch. Five
top-up files produced no finding line and are clean-by-omission per the
prompt contract ("a file with no issue produces no line"):
`stt_channel.dart`, `supabase_service.dart`, and the macOS
`BackgroundDownloadPlugin/MemoryMonitorPlugin/VisionOcrPlugin` Swift
plugins. Future sweeps will make per-file verdicts mandatory so
clean-by-omission cannot hide a skip (see ds4_analyze README).
