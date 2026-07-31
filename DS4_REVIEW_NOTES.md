# DS4 Review Notes — Batch 3 (Performance)

## Task
Performance-only review of 20 Dart files in `lib/data/services/` for CastCircle Flutter project. Write findings to `.ds4-sweep-perf/batch-3.md`.

## Files reviewed (all 20)
1. deep_link_service.dart (168 lines) — no perf issues found
2. kokoro_onnx_service.dart (368 lines) — isolate-based TTS, WAV writing; covered in batch-1/2 native review
3. live_asr_service.dart (245 lines) — isolate-based ASR, PCM conversion
4. media_control_service.dart (91 lines) — no perf issues found
5. mlx_stt_channel.dart (160 lines) — platform channel wrapper; no perf issues
6. model_download_service.dart (782 lines, read 350-529 + 688-702) — sequential _filePath awaits in refreshDownloadedStatus and _groupReady
7. model_manager.dart (347 lines, read 1-100 + 180-329) — streaming extraction already isolated; no issues found
8. ocr_confidence_service.dart (267 lines) — reviewed spell-check scoring/memoization in batch-1 context
9. paddle_ocr_channel.dart (150 lines) — platform channel; no perf issues
10. pdf_text_channel.dart (64 lines) — no perf issues found
11. perf_service.dart (34 lines) — Firebase Performance wrapper; no perf issues
12. playback_session.dart (37 lines) — no perf issues found
13. recording_sync_service.dart (770 lines, read 375-568 + 715-769) — getCachedRecordings existsSync per entry; syncForProduction download-planning existSync loop
14. script_export.dart (285 lines) — reviewed export formatting in batch-1 context
15. script_import_service.dart (753 lines, read 1-500) — PDF import/OCR pipeline covered by native review
16. script_parser.dart (1395 lines, full read) — _mergeOcrCharacterNames O(c²); per-character regex scan; _detectCharacterCue sort+regex-per-line
17. stt_adaptation_service.dart (392 lines) — reviewed profile management in batch-1 context
18. stt_channel.dart (207 lines) — platform channel; no perf issues found
19. stt_service.dart (430 lines, full read) — matchScore allocates O(m×n) matrix per partial result
20. stt_vocabulary_service.dart (562 lines, full read) — _correctAgainstExpected O(m×n); _matchScore duplicate; cache clear-on-overflow

## Key findings written to batch-3.md
1. [high] stt_service.dart:299-335 — matchScore allocates full O(m×n) DP matrix per call (per STT partial result). Fix: two-row rolling optimization.
2. [high] stt_vocabulary_service.dart:341-393 — _correctAgainstExpected same O(m×n) allocation, called on every partial. Fix: two-row or compact Uint8List backtrack storage.
3. [medium] stt_vocabulary_service.dart:460-502 — _matchScore duplicates matchScore with identical unoptimized matrix allocation. Fix: apply two-row + extract to shared utility file.
4. [medium] stt_vocabulary_service.dart:264-298+303-334 — cache clear-on-overflow causes periodic miss storms; switch to LRU eviction.
5. [low] script_parser.dart:592-695 — _mergeOcrCharacterNames O(c²) fuzzy matching with full-matrix edit distance per pair. Fix: bounded single-row edit distance.
6. [low] script_parser.dart:600-605 — c separate regex scans over rawText for cue counting. Consolidate to alternation or trie pass.
7. [medium] script_parser.dart:893-929 — _detectCharacterCue sorts + compiles RegExps per character name on every text line (O(lines × c log c)). Cache sorted list and compiled patterns.
8. [low] recording_sync_service.dart:539-558 — getCachedRecordings calls existsSync() per cache entry synchronously. Fix: TTL-based existence cache.
9. [low] recording_sync_service.dart:386-401 — syncForProduction download-planning does existSync() per line in loop. Defer/batch into async pass or remove redundant pre-check.
10. [low] model_download_service.dart:362-396 + 465-480 — refreshDownloadedStatus and _groupReady await _filePath sequentially per model (each triggers getApplicationDocumentsDirectory platform channel). Fix: Future.wait to parallelize path resolution.

## Notes for future batches
- Already covered in batch-1/2: native iOS/Android STT/TTS, Kokoro MLX Swift code, G2P/Lexicon, OCR preprocessing — no need to re-review those files.

---

# DS4 Review Notes — Batch 6 (Performance)

## Task
Final performance review of remaining sweep files for CastCircle Flutter project: Dart UI screens, C/C++/Swift plugin registrants, Python scripts, shell/Swift dev scripts, and config files. Write findings to `.ds4-sweep-perf/batch-6.md`.

## Files reviewed (all 38 in final batch)
### Dart/Flutter (12)
1. ocr_review_screen.dart (751 lines) — `_contextLinesFor` O(n²); reviewLines filter on every setState; _buildContextEditor called per flagged card
2. pdf_page_view.dart (266) — texture-based PDF rendering, no algorithmic bottleneck but check page-buffer eviction for large docs
3. script_import_screen.dart (736) — reviewed in batch context (native layers covered earlier); no new perf issues at Dart level
4. ai_models_screen.dart (423) — model listing UI; no perf bottlenecks found
5. debug_log_screen.dart (375) — 2s timer unconditional setState + fresh list per tick; `.map().join()` recomputed on share/copy/upload each time
6. kokoro_debug_screen.dart (356) — reviewed in batch context; covered by native Kokoro review earlier
7. model_download_screen.dart (286) — download status UI; no perf issues found at this layer
8. parakeet_debug_screen.dart (475) — `_buildWordComparison`: `List.contains` O(m) inside `.map()` over spoken words → O(n×m); should use Set
9. settings_screen.dart (375) — `_getVersionString()` calls PackageInfo.fromPlatform() on every build via FutureBuilder future; not cached
10. firebase_options.dart (69) — static config, no perf issues
11. main.dart (159) — Kokoro auto-download loop awaits sequentially per model instead of parallelizing with Future.wait

### C/C++ plugin registrant (3)
- generated_plugin_registrant.cc/.h/main.cc — trivial registration glue; no perf concerns

### Swift plugin/App delegates (3)
- GeneratedPluginRegistrant.swift, AppDelegate.swift, MainFlutterWindow.swift — minimal lifecycle wiring; no perf issues found

### Python scripts (4)
12. compare_macbeth_versions.py (149) — comparison CLI; O(n) list ops acceptable for one-shot usage
13. parse_script.py (399) — `detect_character_cue` iterates all 28 chars sorted+regex per line → O(lines×chars); sort runs every call on static data
14. pdf_to_script.py (375) — `_detect_characters_from_pdf` + `_extract_folger`: two full page traversals, uncompiled regexes per line; _clean_output does 4 sequential re.sub passes

### Shell/Swift scripts (10)
- deploy.sh: retry loop with sleep(8); not a perf issue for dev script
- generate_rehearsal_webp.sh: two separate ffmpeg invocations decoding same MOV twice → could merge into single filtergraph pass
- generate_screenshots.sh: simulator boot + flutter drive; no algorithmic bottleneck
- generate_test_export.py: repeated full-list comprehensions across export functions instead of pre-partitioning once
- phone-harness.sh: sequential adb push operations; acceptable for dev harness setup
- pull-crashlog.sh / pull-debuglog.sh: log pulling utilities, not perf-critical
- ship-play.sh / ship-testflight.sh: release pipeline scripts with documented traps; no perf issues beyond inherent build/export serialization
- test_pdf_import.swift: PDFKit extraction + regex cleanup; acceptable for dev tooling
- test_silence_trim.swift: per-sample append loop in RMS analysis O(windowSamples) per window via reduce; could use vDSP. Character skip list uses linear contains check

### Config files (2)
15. pubspec.yaml — no perf issues, but ML deps not pinned beyond `^` constraint (maintainability note only)
16. supabase/config.toml — local dev config; max_rows=1000 on API is reasonable guard against unbounded responses
