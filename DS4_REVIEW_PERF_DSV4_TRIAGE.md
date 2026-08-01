# DS4 skill-routed perf sweep (78 findings) — triage vs current HEAD

The sweep reviewed the pre-fix source snapshot; a large fraction is already
addressed by the earlier triage rounds (commits d829d0a, 2ccfc66, 2d3eac4,
d72b9d7, 5ac4c79) or mooted by the parakeet removal (ae4fc0f). Every finding
below was re-checked against current code before classification.

## P0 — cloud-wide latency (fix + apply to live DB)

1. **cast_members lost its (production_id, user_id) index** —
   `20260315_cast_join_code.sql` dropped the unique constraint that backed it
   and nothing re-created an index. `is_production_member` (the RLS USING
   clause on productions / cast_members / recordings / script_lines /
   storage.objects) now seq-scans cast_members per row considered — every
   cloud read degrades as the table grows. Fix: new migration,
   `create index on cast_members (production_id, user_id)`.

## Round A — Dart hot paths & services (cheap, semantics-preserving)

2. stt_service: matchScore/_dialogueOnly/_normalize compile 5+ regexes per
   partial STT result — hoist to static finals (same fix already applied in
   stt_vocabulary_service).
3. tts_service: stripStageDirections + _splitTextForKokoro regexes per
   speak() — hoist (stripStageDirections also runs per quiet-sample check).
4. debug_log_service: `flush: true` fsyncs per log entry on the caller's
   thread during rehearsal — drop it (periodic flush already exists).
5. app_database: no WAL/synchronous/busy_timeout pragmas — add them
   (per-line recording writes currently pay full-journal fsync).
6. ocr_confidence_service: `_wordValidCache` unbounded AND stale across
   imports (whitelist is per-script; cache isn't invalidated) — clear per
   scoreScript. Correctness-adjacent, not just perf.
7. script_import_service: scoreScript runs on the UI isolate (same class of
   work the parse already offloads) — move into the existing Isolate.run;
   hoist _estimateLineConfidence's ~8 per-line regexes.
8. recording_sync_service: _saveManifest re-encodes the whole global cache
   per realtime download — debounce.
9. sync_queue: O(n²) drain via List.remove — index-based drain.
10. script_models: `acts` getter rescans all lines per access — cache.
11. audio_level_service: unbounded gain cache — cap.
12. script_editor `_splitLine` controller never disposed (the round-1 sweep
    fixed the other two sites; this one was missed).
13. rehearsal_history: `state = [session, ...state]` — append instead.

## Round B — screen jank (verified still present)

STATUS: 14-18 done (rehearsal Opacity→alpha + hoisted watches;
recording_studio memos; cast_manager maps + assignment memo;
production_hub maps; browser docs-dir hoist). REMAINING as Round C:
bulk_cast per-keystroke rebuild, voice_config incremental counter +
non-lazy list, _syncCastFromCloud batching, recording_character per-row
map, browser linesById/sort memo, ocr_review true-lazy itemBuilder,
character_manager range pass, scene_editor count precompute, and the
Swift trio (rmsLevel vDSP, download-progress throttle iOS+macOS, G2P
linkRegex + Lexicon stem reuse).

14. rehearsal_screen: `Opacity` wrapper per row forces a saveLayer per item —
    with every row built (cacheExtent), each rebuild hands the raster thread
    hundreds of offscreen buffers. Replace with alpha-blended colors. [high]
15. rehearsal_screen: `ref.watch(fontSize/hideMyLines)` inside itemBuilder —
    a toggle rebuilds every built row; hoist to build().
16. recording_studio: `_myLines` + indexWhere recomputed per build, and
    build ticks at 10 Hz from the duration timer while recording. [high]
17. cast_manager cluster: assignVoicesFromScript per build (inputs change
    rarely) + primaryFor/understudyFor/linesForCharacter linear scans per
    card + unassignedCount O(N×M) + sequential _syncCastFromCloud saves +
    voice_config_service O(chars²) least-used scan + bulk_cast per-keystroke
    full rebuild.
18. recording_character/recordings_browser/production_hub: per-row
    linesForCharacter / per-rebuild linesById+sort / per-row indexWhere +
    linesInScene — precompute maps per build.
19. ocr_review: _buildListChildren eagerly builds every card, itemBuilder
    just indexes it — laziness defeated; make itemBuilder build directly.
20. character_manager: _rebuildScript O(scenes × lines) — single range pass.
21. scene_editor: linesInScene sublist + count per item — precompute counts.

## Swift — safe (no MLX numerics)

22. AppleSttPlugin.rmsLevel: scalar per-sample loop in the 12 Hz tap —
    vDSP_rmsqv.
23. BackgroundDownloadPlugin (iOS + macOS): per-chunk main-thread channel
    progress — throttle to ~5 Hz / byte-delta gate.
24. EnglishG2P: linkRegex compiled per phonemize call — static.
25. Lexicon: stem functions run twice per OOV word — capture once.

## Deferred — requires MLX bit-exactness verification (Mac GPU busy)

The DurationEncoder pad lesson (corr 0.99977 from a "dead" copy removal)
applies to all of these; do NOT take them without harness runs:
- ConvWeighted: weightNorm recomputed per forward; bias reshaped per call.
- AdaINResBlock1: transpose pairs around each conv.
- MLXSTFT: hanning window rebuilt per call.
- Tokenizer per-char String map.
- TextEncoder/DurationEncoder remaining per-layer masks (the sweep's
  "mask once" suggestion is NOT semantics-preserving: conv/LN bleed into
  padding; per-layer re-masking is load-bearing).

## Already fixed (sweep reviewed pre-fix code)

KokoroTTS alignment .item() loops; TimestampPredictor bulk extract; BART
KV-cache/concat/LM-head (argmax .item() once per token kept by design — EOS
gate); LSTM insert(0); iOS+macOS PdfTextPlugin joined(); stt matchScore DP
two-row; parser _detectCharacterCue pattern cache; cloud_sync_dialog single
pass; scene_editor chip map; script_editor detail/edit controllers;
ocr_review _contextLinesFor memo; settings version future; debug_log timer
count-guard; rehearsal itemBuilder indexWhere map.

## Moot (code deleted)

All ParakeetModel/MLXSttPlugin findings (parakeet removed in ae4fc0f).

## Deflated, with reasons

- rehearsal cacheExtent:10000 — deliberate (rows must exist for
  _currentLineKey scrolling); needs a scroll redesign, tracked separately.
- getCachedRecordings existsSync — runs twice per production sync, not per
  provider read; per-file hot case already uses getCachedRecording.
- AndroidSttPlugin onLevel/onPcm 10 Hz bridge crossings + per-chunk
  ByteArray — ~20 small crossings/sec and a 3 KB alloc at 10 Hz are noise
  next to the ASR/TTS work; lowering onLevel cadence would slow endpointing.
- AppleSttPlugin onLevel 12 Hz — same reasoning; endpointing consumes it.
- production_repository per-file delete — one-shot cleanup path.
- Baseline profile plugin — real but an infra project, backlogged.
- tool/ + scripts/ findings — dev-facing CLI, skipped as before.
