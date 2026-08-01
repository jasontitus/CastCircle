# DS4 sweep review (perf focus) — CastCircle

Exhaustive per-file pass: 280 code files across 10 batches.

## Findings

# Batch 1 — Performance Review Findings

Scope: performance-only review of every file in the batch list. Security/style findings excluded. Vendored deps (ios/LocalPackages/parakeet-stt Sources and ios/Runner/KokoroVendored/Albert) are out of scope for performance findings per the performance-review skill (skip vendored deps except to establish data sizes), and were reviewed only to establish data sizes. Integration tests are test files, not hot paths.

No performance findings identified in any in-scope (non-vendored, non-test) file.

## Coverage

- analysis_options.yaml — clean
- android/app/build.gradle.kts — clean
- android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt — clean
- android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt — clean
- android/app/src/main/kotlin/com/tiltastech/lineguide/MainActivity.kt — clean
- android/app/src/main/kotlin/com/tiltastech/lineguide/MemoryMonitorPlugin.kt — clean
- android/app/src/main/kotlin/com/tiltastech/lineguide/PdfTextPlugin.kt — clean
- android/app/src/main/kotlin/com/tiltastech/lineguide/StubPlugins.kt — clean
- android/build.gradle.kts — clean
- android/gradle.properties — clean
- android/gradle/wrapper/gradle-wrapper.properties — clean
- android/settings.gradle.kts — clean
- dart_test.yaml — clean
- integration_test/android_kokoro_rtf_test.dart — clean
- integration_test/android_kokoro_service_test.dart — clean
- integration_test/android_live_matching_test.dart — clean
- integration_test/android_rehearsal_harness_test.dart — clean
- integration_test/asr_streaming_macos_test.dart — clean
- integration_test/asr_testwav_transcript_macos_test.dart — clean
- integration_test/kokoro_pack_smoke_macos_test.dart — clean
- integration_test/kokoro_service_queue_macos_test.dart — clean
- integration_test/ocr_dump_macos_test.dart — clean
- integration_test/ocr_import_macos_test.dart — clean
- integration_test/rehearsal_demo_test.dart — clean
- integration_test/screenshot_test.dart — clean
- integration_test/tts_kokoro_compare_macos_test.dart — clean
- ios/LocalPackages/parakeet-stt/Package.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/AudioUtils.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/DSP.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/Generation.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetAlignment.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetAttention.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetAudio.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetConfig.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetConformer.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetCTCLayers.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetDecodingLogic.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetModel.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetRNNTLayers.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetTokenizer.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/STTOutput.swift — clean
- ios/Runner/AppDelegate.swift — clean
- ios/Runner/AppleSttPlugin.swift — clean
- ios/Runner/AudioAnalysisPlugin.swift — clean
- ios/Runner/BackgroundDownloadPlugin.swift — clean
- ios/Runner/ContactPickerPlugin.swift — clean
- ios/Runner/KokoroMLXPlugin.swift — clean
- ios/Runner/KokoroMLXService.swift — clean
- ios/Runner/KokoroVendored/Albert/AlbertEmbeddings.swift — clean
- ios/Runner/KokoroVendored/Albert/AlbertEncoder.swift — clean
- ios/Runner/KokoroVendored/Albert/AlbertIntermediate.swift — clean
- ios/Runner/KokoroVendored/Albert/AlbertLayer.swift — clean
- ios/Runner/KokoroVendored/Albert/AlbertLayerGroup.swift — clean
- ios/Runner/KokoroVendored/Albert/AlbertModelArgs.swift — clean
- ios/Runner/KokoroVendored/Albert/AlbertOutput.swift — clean
- ios/Runner/KokoroVendored/Albert/AlbertSelfAttention.swift — clean
- ios/Runner/KokoroVendored/Albert/AlbertSelfOutput.swift — clean
- ios/Runner/KokoroVendored/Albert/CustomAlbert.swift — clean
# Batch 2 — Performance review findings

- [high] ios/Runner/KokoroVendored/BuildingBlocks/LSTM.swift:151-152 — `allCell.insert(currentCell, at: 0)` / `allHidden.insert(currentHidden, at: 0)` inside the backward-direction loop over `seqLen` — each `insert(at: 0)` shifts every existing element, making the backward LSTM pass O(seqLen²) element moves. At the TTS hot path (duration/text/prosody LSTMs) a ~500-token phoneme sequence costs ~250k element shifts per backward pass, repeated per LSTM layer — the decoder latency scales quadratically with text length. — Smallest safe fix: append during the reversed iteration and `reverse()` the collected arrays once before `stacked`, or build in forward order and reverse the sequence indices.

- [high] ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:366 — `let phonemeIndex: Int = indices[frame].item()` inside `for frame in 0 ..< totalFrames` in `createAlignmentTarget` — each `.item()` is a synchronous host-GPU round trip; `totalFrames` grows with the sum of predicted durations (thousands of frames for a long utterance), so each `generateAudio` call issues thousands of per-frame syncs. Also lines 354-359 build one MLXArray per phoneme (`durations.enumerated().map { MLX.repeated(...) }`) then concatenate, allocating per-phoneme. — Smallest safe fix: hoist the index array to Swift once (`let frames = indices.asArray(Int32.self)`) and iterate the host array; build the one-hot `alignmentArray` with a single host loop over a preallocated buffer.

- [medium] ios/Runner/KokoroVendored/BuildingBlocks/ConvWeighted.swift:100 (and 128) — `let weight = weightNorm(weightV: weightV, weightG: weightG, dim: 0)` recomputed on every forward `callAsFunction` — the L2-norm + normalize + scale of the fixed weight tensor is re-derived per conv-layer forward pass, and ConvWeighted layers run many times per TTS utterance (decoder, generator, adain blocks). Each call is a full tensor reduction (`sum(x*x)` + `sqrt` + divide) on a weight that never changes after load. — Smallest safe fix: compute the normalized weight once at `init` and store it as a `let` (weights are immutable after load).

- [medium] ios/Runner/MisakiVendored/English/Lexicon/Lexicon.swift:172 — `[stem_s, stem_ed, stem_ing].contains(where: { fn in fn(wl, tag, stress, ctx).0 != nil })` eagerly invokes all three stem functions on `wl` (array literal forces full evaluation), then lines 184-190 re-run `stem_s`, `stem_ed`, `stem_ing` on `candidate` (usually == wl) for the real result — so every unknown word on the transcription hot path pays for the stem work twice (6 stem evaluations instead of 3), each doing dictionary lookups. — Smallest safe fix: compute the three stem results once into a tuple and reuse for both the existence check and the lookup, or check membership by calling a single short-circuiting helper instead of the array literal.

- [medium] ios/Runner/MisakiVendored/English/FallbackNetwork/BARTModel.swift:145 — `decoderInput = concatenated([decoderInput, newToken], axis: 1)` inside the autoregressive `generate` loop — each step reallocates/copies the entire growing decoder sequence (O(seq_len) per step, O(maxLength²) total), plus the per-step `decode` re-runs all decoder layers. — Smallest safe fix: preallocate a `[Int32]` buffer of `maxLength` and slice it per step instead of re-concatenating, keeping the inherent per-step decode cost.

- [medium] lib/data/services/audio_level_service.dart:30 — `final Map<String, double> _gainCache = {}` is an insert-only cache keyed by recording file path with no eviction, TTL, or max size; `volumeFor` writes on every uncached path and only `invalidate`/`clear` remove entries. It grows monotonically with every distinct recording ever analyzed over the app's lifetime (paths are stable per production). — Smallest safe fix: cap it (e.g. LRU/TTL by path, or drop entries when the count exceeds a bound), or clear on production switch.

- [low] ios/Runner/KokoroVendored/TTSEngine/TimestampPredictor.swift:44-45,57-58 — `predictionDuration[i].item()`, `predictionDuration[i..<j].sum().item()`, `predictionDuration[j].item()` inside the `for t in tokens` loop — each `.item()` is a host-GPU sync, so timestamp prediction does one sync per token (bounded by token count up to ~510). — Smallest safe fix: convert `predictionDuration` to a Swift `[Float]` once with `asArray` and index the host array.

- [low] ios/Runner/MLXSttPlugin.swift:208 — `fullText += token` inside the `for try await event in stream` transcription loop — string accumulation copies the whole transcript per token (O(n²) bytes over the transcript length). — Smallest safe fix: accumulate into a `StringBuffer`/list and join once, or append per token is fine given short transcripts (kept as low).

- [low] ios/Runner/PdfTextPlugin.swift:80-81 — `fullText += pageText; fullText += "\n"` inside `for i in 0..<pageCount` — string accumulation copies the whole extracted text per page (O(pageCount²) bytes over the document). — Smallest safe fix: collect page strings into a list and `join('\n')` once.

- [low] lib/data/services/debug_log_service.dart:184 — `File(path).writeAsStringSync('${entry.toLine()}\n', mode: FileMode.append, flush: true)` per `log` entry — an unbuffered synchronous file open/write/flush syscall per log record on the rehearsal path. Deliberate for crash survival, but every rehearsal event (STT/TTS/line-match logs) pays a sync syscall. — Smallest safe fix: keep a single open file handle and only `flush` at checkpoints (e.g. every N entries) while preserving the crash-survival intent.

- [low] ios/Runner/MisakiVendored/English/Num2Word/EnglishNum2Word.swift:141,155 — `midNumWords.sorted(by: ...)` and `cards.sorted(by: ...)` are re-sorted on every recursive `toCardinal` call (including per-digit calls in `toDecimal`) even though the arrays never change — constant-factor waste on the number-to-words path. — Smallest safe fix: store the arrays pre-sorted as stored constants/let.

- [medium] lib/data/models/script_models.dart:350 — `indexForRef` does a linear scan `for (var i = 0; i < lines.length; i++)` over the full `ScriptLine` list per call with no index; called repeatedly during rehearsal/page-ref matching this is O(n) per lookup and O(n²) if invoked per line over a multi-thousand-line script. — Smallest safe fix: build a `Map<(int page, int line), int>` once, or sort by (sourcePage, sourceLineOnPage) once and binary-search.

## Review notes

Searches run: `.item()` host-sync greps; `insert(at: 0)`/`removeAt(0)`/`shift`/`pop(0)`; `contains(where:)`; `sorted(`; `concatenated(`; `+=` string accumulation; `cache`/`Map` registries; `firstWhere`/linear scans over collections.

Dismissed false positives (with bound reasoning):
- `Lexicon.applyStress` inner `for j` vowel scan (L67) and `contains(where:)` stress scans (L107-115) are O(phoneme-length), phoneme strings are a few chars — bounded small.
- `EnglishG2P.tokenize` feature×token nested loop (L225) is O(#markdown-links × #words), links are a handful — bounded small.
- `EnglishG2P.retokenize` `arr[left..<right].contains` (L439) is the greedy segmentation contraction — the range shrinks each iteration.
- `debug_log_service.dart:161` `_entries.removeAt(0)` is bounded by `maxEntries = 500` (fixed) — low constant, not reported.
- `VoicePresets.byId` `firstWhere` over a constant 8-element list — bounded config.
- `production_repository.deleteProduction` per-recording file deletes are a one-time cold cleanup path.
- Most MLX tensor files (norm, conv, attention) are vectorized MLX ops with no per-element Swift loops; loop counts are model-config-bounded.

## Coverage

- ios/Runner/KokoroVendored/BuildingBlocks/AdaIN1d.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/AdainResBlk1d.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/AdaINResBlock1.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/AdaLayerNorm.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/Conv1dInference.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/ConvWeighted.swift — findings: 1
- ios/Runner/KokoroVendored/BuildingBlocks/InstanceNorm1d.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/Interpolate.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/LayerNormInference.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/LSTM.swift — findings: 1
- ios/Runner/KokoroVendored/BuildingBlocks/ReflectionPad1d.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/UpSample1d.swift — clean
- ios/Runner/KokoroVendored/Decoder/Decoder.swift — clean
- ios/Runner/KokoroVendored/Decoder/Generator.swift — clean
- ios/Runner/KokoroVendored/Decoder/MLXSTFT.swift — clean
- ios/Runner/KokoroVendored/Decoder/SineGen.swift — clean
- ios/Runner/KokoroVendored/Decoder/SourceModuleHnNSF.swift — clean
- ios/Runner/KokoroVendored/TextProcessing/eSpeakNGG2PProcessor.swift — clean
- ios/Runner/KokoroVendored/TextProcessing/G2PFactory.swift — clean
- ios/Runner/KokoroVendored/TextProcessing/G2PProcessor.swift — clean
- ios/Runner/KokoroVendored/TextProcessing/Language.swift — clean
- ios/Runner/KokoroVendored/TextProcessing/MisakiG2PProcessor.swift — clean
- ios/Runner/KokoroVendored/TextProcessing/Tokenizer.swift — clean
- ios/Runner/KokoroVendored/TTSEngine/DurationEncoder.swift — clean
- ios/Runner/KokoroVendored/TTSEngine/KokoroConfig.swift — clean
- ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift — findings: 1
- ios/Runner/KokoroVendored/TTSEngine/ProsodyPredictor.swift — clean
- ios/Runner/KokoroVendored/TTSEngine/TextEncoder.swift — clean
- ios/Runner/KokoroVendored/TTSEngine/TimestampPredictor.swift — findings: 1
- ios/Runner/KokoroVendored/TTSEngine/WeightLoader.swift — clean
- ios/Runner/KokoroVendored/Utils/AudioUtils.swift — clean
- ios/Runner/MediaControlPlugin.swift — clean
- ios/Runner/MemoryMonitorPlugin.swift — clean
- ios/Runner/MisakiVendored/English/DataStructures/TokenContext.swift — clean
- ios/Runner/MisakiVendored/English/EnglishG2P.swift — clean
- ios/Runner/MisakiVendored/English/FallbackNetwork/BARTConfig.swift — clean
- ios/Runner/MisakiVendored/English/FallbackNetwork/BARTDecoderLayer.swift — clean
- ios/Runner/MisakiVendored/English/FallbackNetwork/BARTEncoderLayer.swift — clean
- ios/Runner/MisakiVendored/English/FallbackNetwork/BARTLayerNorm.swift — clean
- ios/Runner/MisakiVendored/English/FallbackNetwork/BARTModel.swift — findings: 1
- ios/Runner/MisakiVendored/English/FallbackNetwork/EnglishFallbackNetwork.swift — clean
- ios/Runner/MisakiVendored/English/FallbackNetwork/FeedForward.swift — clean
- ios/Runner/MisakiVendored/English/FallbackNetwork/MultiHeadAttention.swift — clean
- ios/Runner/MisakiVendored/English/Lexicon/DataResourcesUtil.swift — clean
- ios/Runner/MisakiVendored/English/Lexicon/Lexicon.swift — findings: 1
- ios/Runner/MisakiVendored/English/Lexicon/PennTagUtil.swift — clean
- ios/Runner/MisakiVendored/English/Num2Word/EnglishNum2Word.swift — findings: 1
- ios/Runner/MisakiVendored/Extensions/MLXArray+DebugPrint.swift — clean
- ios/Runner/MisakiVendored/Extensions/NLTag+ProperNoun.swift — clean
- ios/Runner/MisakiVendored/Extensions/Range+Contains.swift — clean
- ios/Runner/MisakiVendored/Extensions/String+ReplacingLast.swift — clean
- ios/Runner/MLXSttPlugin.swift — findings: 1
- ios/Runner/ObjCExceptionCatcher.h — clean
- ios/Runner/ObjCExceptionCatcher.m — clean
- ios/Runner/PaddleOcrPlugin.swift — clean
- ios/Runner/PdfTextPlugin.swift — findings: 1
- ios/Runner/Runner-Bridging-Header.h — clean
- ios/Runner/SceneDelegate.swift — clean
- ios/RunnerTests/RunnerTests.swift — clean
- lib/app.dart — clean
- lib/core/constants.dart — clean
- lib/core/responsive.dart — clean
- lib/core/theme/app_theme.dart — clean
- lib/core/toast.dart — clean
- lib/data/database/app_database.dart — clean
- lib/data/models/cast_member_model.dart — clean
- lib/data/models/production_models.dart — clean
- lib/data/models/rehearsal_models.dart — clean
- lib/data/models/script_models.dart — findings: 1
- lib/data/models/voice_preset.dart — clean
- lib/data/repositories/production_repository.dart — clean
- lib/data/services/analytics_service.dart — clean
- lib/data/services/audio_level_service.dart — findings: 1
- lib/data/services/contact_picker_service.dart — clean
- lib/data/services/debug_log_service.dart — findings: 1
# Perf review batch 3 — lib/data/services/

- [low] lib/data/services/ocr_confidence_service.dart:182 — `_wordValidCache` (`final _wordValidCache = <String, bool>{};`) is a singleton-level memo keyed by distinct word with no eviction/TTL/max size; `_isValidWord` (line 184) writes a permanent entry via `putIfAbsent` for every distinct word ever scored, including OCR-garbled strings that never recur. Over many script imports the map grows monotonically with distinct (including misspelled/noise) words — memory creep on a mobile device that the `dispose()` path clears but `scoreScript` re-accumulates. — Smallest safe fix: cap with an LRU (e.g. `LinkedHashMap` with a max size) or clear the cache between imports.
- [low] lib/data/services/ocr_confidence_service.dart:247 — `scoreScript` calls `_buildWhitelist(lines, characters)` (line 247) which tokenizes every line (loop at lines 135-140), then calls `scoreLine(line.text)` (line 253) which re-tokenizes the same line again (via `_tokenize` at line 152). Each line's text is split twice per `scoreScript` call; for a multi-thousand-line play this doubles the tokenization work on the import path (constant-factor, spell-check dominates, so low). — Smallest safe fix: have `_buildWhitelist` return/keep the per-line tokens (or a single word-frequency pass) and feed them to `scoreLine`.
- [medium] lib/data/services/recording_sync_service.dart:539 — `getCachedRecordings(String productionId)` scans the entire global `_cache` map (all productions, growing with every recording downloaded) and runs a filesystem stat `File(cached.localPath).existsSync()` (line 544) per entry to filter one production's subset. Each call is O(total cached recordings) with a per-item stat, called when the rehearsal screen populates its recordingsProvider; with several productions and hundreds of recordings cached the scan/stats dominate. — Smallest safe fix: keep a per-production index (map productionId → set of lineIds) and iterate only that production's entries, or maintain a second map keyed by productionId.
- [low] lib/data/services/recording_sync_service.dart:176 — `_saveManifest()` serializes the entire global `_cache` (`jsonEncode(_cache.values.map((c) => c.toJson()).toList())`) on every call, and `handleRealtimeRecording` invokes it per recording arrival (line 633). During a production where castmates upload many takes via realtime, each arrival re-encodes and rewrites the whole cross-production manifest — O(total cached entries) per event. The write chain (line 177) prevents parallel writes but not the per-event full serialization. — Smallest safe fix: only serialize the changed entry (append/incremental manifest) or batch writes with a debounce/interval.
- [low] lib/data/services/script_export.dart:194 — `toCharacterLines` builds a full filtered list `script.lines.where((l) => ...).toList()` (lines 194-197) solely to read `charLines.length` (line 199), then loops over `script.lines` again (line 203) for the same data. Two full passes over every line plus an allocation that is used only for a count; scales linearly with script length on the (cold) export path. — Smallest safe fix: use `script.lines.where(...).length` instead of materializing the list, and merge the act-header pass into the existing loop.
- [low] lib/data/services/script_import_service.dart:637 — in `_estimateLineConfidence` (called per OCR line on the ML Kit fallback, line 462) the vowel check constructs `RegExp(r'[aeiouAEIOU]')` inside the per-word loop (line 637), and other small regexes (`RegExp(r'^[IaO0-9]$')` line 650, `RegExp(r'(.)\1{3,}')`/`(.)\1{2}` lines 661/663) are constructed per line. Each tiny-pattern compile is cheap but happens per word/line over every line of a scanned play, adding constant-factor CPU on the fallback path. — Smallest safe fix: hoist these constant patterns to `static final` fields.

## Coverage
- lib/data/services/deep_link_service.dart — clean
- lib/data/services/kokoro_onnx_service.dart — clean
- lib/data/services/live_asr_service.dart — clean
- lib/data/services/media_control_service.dart — clean
- lib/data/services/mlx_stt_channel.dart — clean
- lib/data/services/model_download_service.dart — clean
- lib/data/services/model_manager.dart — clean
- lib/data/services/ocr_confidence_service.dart — findings: 2
- lib/data/services/paddle_ocr_channel.dart — clean
- lib/data/services/pdf_text_channel.dart — clean
- lib/data/services/perf_service.dart — clean
- lib/data/services/playback_session.dart — clean
- lib/data/services/recording_sync_service.dart — findings: 2
- lib/data/services/script_export.dart — findings: 1
- lib/data/services/script_import_service.dart — findings: 1
# Batch 4 — Performance findings

- [medium] lib/data/services/script_parser.dart:893 — `_detectCharacterCue` re-sorts `knownCharacters` and rebuilds up to four `RegExp`s per character on every dialogue line — `_parseLines` (line 1203) calls it for each non-noise line, so parsing a play costs `lines × characters` regex compilations plus one list sort per line. A ~5000-line play with ~40 characters pays ~200k regex compilations and 5000 sorts on the (one-shot but user-facing) import path; latency scales with lines × characters. — Hoist the length-sorted name list and the per-character cue patterns out of the line loop, building them once after `knownCharacters` is finalized (e.g. a `_cuePatterns` list built in `parse()` before `_parseLines`).
- [medium] lib/data/services/stt_adaptation_service.dart:197 — `addSample` rebuilds the whole `samples` list each add (`samples: [...actorProfile.samples, sample]`) and recomputes `totalAudioSeconds` (a fold over every sample, lines 65-66) on each add for both the actor and production profile — adding N samples is O(N) per add, i.e. O(N²) allocation/fold work as an actor's training corpus grows toward the 300s recommended target. — Append to a mutable list once per add and maintain a running total-duration field instead of copying + re-folding the list.
- [low] lib/data/services/sync_queue.dart:363 — `_processQueue` drains `_pending` with `_pending.remove(job)` (also lines 380, 388) which is an O(n) shift per job, and `enqueue` (lines 300-302) does `_pending.any` + `_pending.removeWhere` + `_failed.removeWhere` scans per enqueue — processing N queued offline recordings is O(N²) list-element work. At a few hundred offline lines this is tens of thousands of element moves on the upload path (not a hot loop, so low). — Use a linked/deque-style queue or a map keyed by production/line to remove jobs in O(1).

## Coverage
- lib/data/services/script_parser.dart — findings: 1
- lib/data/services/stt_adaptation_service.dart — findings: 1
- lib/data/services/stt_channel.dart — clean
- lib/data/services/stt_service.dart — clean
- lib/data/services/stt_vocabulary_service.dart — clean
- lib/data/services/supabase_service.dart — clean
- lib/data/services/sync_queue.dart — findings: 1
- lib/data/services/tts_service.dart — clean
- lib/data/services/vision_ocr_channel.dart — clean
- lib/data/services/voice_clone_service.dart — clean
# batch-5 performance findings

- [high] lib/features/cast_manager/cast_manager_screen.dart:334-349 — Per-character card render does linear scans over all cast members and all script lines — In the ListView.builder itemBuilder, `ref.read(castMembersProvider.notifier).primaryFor(char.name)` and `understudyFor(char.name)` each run a `firstWhere` over the full cast-member list (production_providers.dart:230-250), and `script.linesForCharacter(char.name)` (script_models.dart:321-326) scans every script line, once per character card; `charLines.where((l) => recordings.containsKey(l.id))` then re-scans the character's lines again. Each build is O(characters × (members + lines)) — a 200-character script with 200 cast members / 2000 lines is ~800k comparisons and allocations per rebuild, and the screen rebuilds on every cast/recording/script change. Fix: build `Map<String, CastMemberModel>` for primary and understudy plus a per-character line-count cache once per build, outside the itemBuilder.

- [high] lib/features/cast_manager/cast_manager_screen.dart:62-82 — Cloud cast sync saves each fetched member with an O(n) state update, giving O(M²) — `_syncCastFromCloud` loops over cloudMembers calling `await notifier.save(member)` per row, and `save` (production_providers.dart:210-221) runs `state.indexWhere(...)` plus rebuilds the entire state list on every call, so syncing M cast members is O(M²) scans/allocations each time the cast manager opens. At 500 members that is ~250k list operations plus full-list copies per sync. Fix: batch all fetched members into one state replacement (or collect updates and apply once) instead of save-per-row.

- [medium] lib/features/cast_manager/cast_manager_screen.dart:147-153 — Full-script voice adjacency walk recomputed on every build — `VoiceConfigService.assignVoicesFromScript(...)` walks every dialogue line (O(lines × window)) on each build, and this screen rebuilds on every recordings/cast/script change; the result is not memoized across builds. A multi-thousand-line script repeats a whole-script pass on each state change. Fix: memoize the assignment keyed by (script lines, gender overrides) or compute it lazily once per script/overrides change.

- [medium] lib/features/cast_manager/cast_manager_screen.dart:163-169 — unassignedCount scans every cast member per character — `script.characters.where((char) => castMembers.where((m) => ...).isEmpty)` is O(characters × members) and is recomputed on every build. Fix: build a `Set` of assigned primary (character, role) keys once and test membership per character.

- [medium] lib/features/cast_manager/bulk_cast_setup_screen.dart:75-79 — unassigned filter is O(characters × members) and recomputed on every keystroke — build computes `script.characters.where((char) => !castMembers.any(...)).toList()`, and each TextField's `onChanged: (_) => setState(() {})` (line 214) triggers a full rebuild on every keystroke, re-scanning all characters against all cast members and rebuilding every card. Fix: index cast members by character+role into a set/map once (outside build) and hoist the unassigned computation out of the per-keystroke rebuild.

- [medium] lib/features/cast_manager/voice_config_screen.dart:108-121 — All character voice tiles built eagerly and autoAssignment recomputed on every build — `...script.characters.map((char) => _buildCharacterTile(...))` feeds a non-lazy `ListView` so every character tile is constructed on each build regardless of viewport, and `assignVoicesFromScript` re-walks the whole script per build; any preset/override change rebuilds the entire list. For a large cast this constructs hundreds of ListTiles and repeats a full-script walk per rebuild. Fix: use `ListView.builder` for the character tiles and memoize the assignment.

## Coverage
lib/data/services/voice_config_service.dart — clean
lib/features/auth/auth_screen.dart — clean
lib/features/cast_manager/bulk_cast_setup_screen.dart — findings: 1
lib/features/cast_manager/cast_manager_screen.dart — findings: 4
lib/features/cast_manager/voice_config_screen.dart — findings: 1
lib/features/home/home_screen.dart — clean
lib/features/join/join_production_screen.dart — clean
lib/features/onboarding/model_setup_screen.dart — clean
# batch-6 performance findings

- [medium] lib/features/recording_studio/recording_studio_screen.dart:233 — `_myLines = script.linesForCharacter(character)` full-script scan recomputed on every build — `build()` assigns `_myLines` from `script.linesForCharacter(character)` (script_models.dart:321-326 walks ALL `script.lines` with `.where().toList()`), and build() runs on every `setState`, including the 100 ms `_durationTimer` tick (lines 597-603) that fires during each recording. So while recording, the UI thread re-scans the entire script (~2000-line script = 2000 comparisons + a fresh list allocation) and then re-scans `_myLines` for `recordedCount` (line 246) every 100 ms — tens of thousands of comparisons per minute plus allocation churn on the main isolate. `_myLines` depends only on script+character, which are fixed for the session. Fix: compute `_myLines` once in initState/on character change instead of inside build, or cache it keyed on (script, character).

- [medium] lib/features/recording_studio/recording_studio_screen.dart:344 — `_buildContextLines` re-scans the whole script per build — each build calls `script.lines.indexWhere((l) => l.id == currentLine.id)` (O(all lines)) to locate the current line, then walks backwards. Combined with the 100 ms recording-timer setState, this is a second O(script-lines) scan per tick. Fix: store the current line's full-script index (or the context lines) once when `_currentLineIdx` changes, not per build.

- [medium] lib/features/recording_studio/recording_character_screen.dart:59 — Per-character card scans the entire script, O(characters × lines) — in the `ListView.builder` itemBuilder, each row calls `script.linesForCharacter(char.name)` (script_models.dart:321-326) which filters all `script.lines` into a new list, then `charLines.where(...)` re-scans that list for `recordedCount`. For C characters and L script lines each rebuild is O(C × L) comparisons plus allocations; the screen rebuilds on every recording/script change (it watches `recordingsProvider` at line 23). A 20-character script over 5000 lines is ~100k comparisons + 20 list allocations per rebuild. This is exactly the O(n×m) the recordings_browser fixed by building a `linesById` map. Fix: build a per-character dialogue-line cache (or precomputed `Map<String,List<ScriptLine>>`) once per script, and iterate it instead of re-filtering `script.lines` per row.

- [medium] lib/features/recording_studio/recordings_browser_screen.dart:75-112 — Whole recorded list rebuilt, re-scanned and re-sorted on every build — `build()` rebuilds the `linesById` map over all script lines (O(lines)), iterates every `recordings.entries` (O(recordings)), sorts `recordedEntries` by orderIndex (O(n log n)), builds a `recordedCharacters` set (O(recordings)), scans all dialogue lines (O(lines)), and folds total duration (O(recordings)) — all recomputed from scratch on each build. Builds happen on every playback `setState` (lines 680/696), on scan completion, and on any recording/script provider change, so every play/stop re-sorts and re-scans the entire list. With thousands of recordings this is thousands of comparisons + a sort per state change. Fix: memoize `recordedEntries`/stats keyed on (script, recordings, filter) and rebuild only when one of those changes.

- [low] lib/features/recording_studio/recordings_browser_screen.dart:187-209 — `_scanFileExistence` builds a join string and runs sequential synchronous file stats per recording on the main isolate — `entries.map((e) => e.recording.id).join('|')` is an O(n) string concatenation per build to compare against `_scannedKey`, and the scan itself awaits `_resolveRecordingPath` per entry, whose `File(...).existsSync()` calls are blocking syscalls on the UI thread (plus a `firstWhere` over the whole cached file list when a path is stale, lines 601-606). For a production with hundreds of recordings this is hundreds of sequential blocking stat calls on the main isolate on entry to the screen. Fix: keep a cached id-list key instead of rebuilding a join string, and batch the existence checks off the main isolate (e.g. compute in `compute()`/isolate) or skip the per-entry sync stats where the stored path is known-good.

- [low] lib/features/recording_studio/recordings_browser_screen.dart:310 — `_buildRecordingTile` does `script.characters.indexWhere(...)` per visible tile — each list row scans all characters to find its color (O(characters)) on every row rebuild during scroll. For a large cast this is O(characters) per tile per frame and is not memoized. Fix: build a `Map<String,Color>` (or name→index) once per build outside the itemBuilder.

- [low] lib/features/production_hub/production_hub_screen.dart:409-415 — Per-scene card recomputes dialogue stats on every row rebuild — the `ListView.builder` itemBuilder calls `script.linesInScene(scene).where(...).toList()` (O(lines in that scene)) and then re-filters `sceneDialogue` for `myLineCount`, and lines 503-504 call `script.characters.indexWhere` for every character chip in the scene's `Wrap` — all recomputed on each row rebuild during scrolling, with no memoization. A script with hundreds of scenes re-walks every scene's lines and re-scans characters each scroll frame. Fix: precompute per-scene dialogue count / per-character index once per script, and have the itemBuilder read cached values.

- [medium] lib/features/rehearsal/rehearsal_history_screen.dart:20-22 — Unbounded history list with O(n) copy on every add, O(n²) over time — `add` prepends via `state = [session, ...state]`, copying the entire existing list each time and growing the list without any cap/eviction (only a user-initiated `clear`). Session history accumulates for the whole production, so the k-th session costs O(k) copy and total cost is O(n²); the list also grows monotonically in memory. Fix: cap the retained sessions (e.g. keep the latest N) and append/insert with a fixed-capacity structure (or a `RingBuffer`) instead of full-list spread prepend.

- [low] lib/features/rehearsal/rehearsal_history_screen.dart:85-97 — Summary stats re-fold the entire history on every build — `_buildSummary` runs two `fold`s over `sessions` and a `map(...).toSet()` for `uniqueScenes` (O(n) + set allocation) each build, and the screen rebuilds whenever `rehearsalHistoryProvider` changes. With an unbounded history this is O(n) per rebuild, growing with the list. Fix: compute the summary once per history change and cache it, or maintain running totals in the notifier.

## Coverage
lib/features/production_hub/production_hub_screen.dart — findings: 1
lib/features/recording_studio/recording_character_screen.dart — findings: 1
lib/features/recording_studio/recording_studio_screen.dart — findings: 2
lib/features/recording_studio/recordings_browser_screen.dart — findings: 3
lib/features/recording_studio/voice_profile_screen.dart — clean
lib/features/rehearsal/rehearsal_history_screen.dart — findings: 2
# Batch 7 — Performance findings

- [medium] lib/features/rehearsal/rehearsal_screen.dart:933 — `cacheExtent: 10000` force-builds a very large region of the rehearsal script `ListView.builder` (every line advance via `currentLineIndexProvider` rebuilds the whole `_buildScriptView`, so ~70–145+ offscreen items — more on long scenes — are rebuilt per line, and every font-size change re-triggers the same). The code's own comments (lines 86, 2093, 2880) admit this force-builds offscreen items; cost scales with `dialogueLines.length`. — Long scenes make each line transition rebuild dozens/hundreds of full text rows on the UI thread, causing frame jank during the very moment the actor advances. — Reduce the cache extent (e.g. 2000–3000 px) and rely on the existing estimated-offset fallback in `_scrollToCurrentLine` (lines 2891-2901), or drive scroll via `Scrollable.ensureVisible`/`scrollToIndex` on a lazily built current-line key instead of keeping everything force-built.

- [low] lib/features/rehearsal/rehearsal_screen.dart:950 — `script.characters.indexWhere((c) => c.name == colorLookupName)` runs a linear scan of the characters list inside every `itemBuilder` invocation, so each rebuild of the force-built list region (see above) costs O(builtItems × characters). — On a script with many characters and a long scene, each line-advance rebuild pays a redundant scan per visible+cached item; with cacheExtent: 10000 this repeats across dozens of items on the hot advance path. — Build a `Map<String,int>` of name→index once (e.g. alongside the cached `dialogueLines` in `_getRehearsalLines` or a field) and look it up per item instead of `indexWhere`.

- [medium] lib/features/script_editor/character_manager_screen.dart:755 — `_rebuildScript` nests a full `for (final line in updatedLines)` scan inside `script.scenes.map(...)` (lines 755-766) to collect each scene's characters, so a rename/delete rebuild costs O(scenes × lines). — A script with many scenes and thousands of lines turns one user-triggered rename/delete into a quadratic pass (e.g. 40 scenes × 3000 lines = 120k comparisons), stalling the edit and the subsequent `scheduleScriptSave`. — Do a single pass over `updatedLines`, bucketing each dialogue line's character into the scene it falls in (via `line.orderIndex` vs scene bounds), then build `scene.characters` from the buckets — O(lines + scenes) instead of O(scenes × lines).

- [low] lib/features/script_editor/scene_editor_screen.dart:116 — `script.characters.indexWhere((c) => c.name == name)` is a linear scan per character chip inside each scene's `itemBuilder` (and `ReorderableListView.builder` builds every scene eagerly), so the whole screen build is O(scenes × charsPerScene × characters). — For a production with many characters across many scenes, opening/rebuilding the scene list repeatedly pays redundant name scans; minor on this cold editor screen but trivially avoidable. — Hoist a `Map<String,int>` of character name→index once per build and look it up for each chip.

## Coverage

- lib/features/rehearsal/rehearsal_screen.dart — findings: 2
- lib/features/script_editor/character_manager_screen.dart — findings: 1
- lib/features/script_editor/cloud_sync_dialog.dart — clean
- lib/features/script_editor/scene_editor_screen.dart — findings: 1
# Batch 8 — Performance findings (Flutter UI screens)

- [high] lib/features/script_import/ocr_review_screen.dart:408 — `_buildListChildren` eagerly builds a Card (with a TextField) for EVERY review line via `...reviewLines.map((l) => _buildReviewCard(l, twoPane: twoPane))`, and the `ListView.builder` in `_buildSinglePaneBody`/`_buildTwoPaneBody` (lines 324-328 / 355-358) only indexes into that prebuilt `children` list (`itemBuilder: (context, i) => children[i]`). So every `setState` — save edit (149), remove (163), select (204), toggle context (129) — reconstructs all N review cards. The comment at 313-316 explicitly says this was meant to be lazy ("a bad scan flags 100-300 lines ... cost hundreds of ms per tap"), but the code defeats it. Consequence: O(N) heavy widget construction (each card contains a TextField) on every interaction, scaling with flagged-line count; hundreds of ms jank on large scans. — Smallest safe fix: build the card lazily per visible index inside `itemBuilder` (map review/notScript entries to a per-index builder rather than prebuilding the whole list).

- [medium] lib/features/script_import/ocr_review_screen.dart:99 — `_contextLinesFor` copies and sorts the ENTIRE line list on every call: `widget.lines.where((l) => !_removedIds.contains(l.id)).toList()..sort((a, b) => a.orderIndex.compareTo(b.orderIndex))` (lines 104-107), then `indexWhere` (108). It is invoked from `_buildContextEditor` during build whenever a line's context editor is expanded (line 570), so each expanded editor adds an O(L log L) full-list sort + scan per build. Consequence: opening "Edit nearby lines" on several flagged lines makes every rebuild cost O(E·L log L) over all script lines. — Smallest safe fix: keep one orderIndex-sorted working list in state and index into it, instead of re-sorting `widget.lines` per expanded editor.

- [medium] lib/features/script_import/ocr_review_screen.dart:135 — The `_reviewLines` (135), `_notScriptLines` (139), `_pendingReviewCount` (143) and `_pendingNotScriptCount` (146) getters each do a full O(L) scan of `widget.lines`, and build() (279-281) plus `_buildCountsBar` (480) recompute several of these on every rebuild; combined with the eager children list this means each setState pays multiple full-list passes plus all-card construction. Consequence: rebuild cost scales with total line count even though only flagged lines are shown. — Smallest safe fix: compute the review/notScript subsets once and reuse (store in state, update on removals) instead of re-filtering the full list per build.

- [medium] lib/features/script_editor/script_editor_screen.dart:88 — build() recomputes the `charColors` map (88-91), the full filtered list via `_filteredLines(script)` (93) — which does `script.lines.toList()` plus one or two `where(...).toList()` passes (519-548) — and the low-OCR chip's `script.lines.any(...)` (249) and `script.lines.where(...).length` (255) on EVERY rebuild. Any setState (selecting a line on tablet, toggling directions/reorder mode, editing) re-runs these O(L) scans/allocations over all script lines. Consequence: with a multi-thousand-line script each interaction pays ~5 full-line passes plus allocations, jank growing with L. — Smallest safe fix: memoize `charColors`, the filtered line list, and the low-OCR count keyed on (script identity, `_showDirections`, `_showLowConfidenceOnly`, `_selectedCharacter`) instead of recomputing per build.

- [low] lib/features/script_editor/script_editor_screen.dart:429 — `_buildDetailPanel` constructs `final textController = TextEditingController(text: line.text)` on every build and never disposes it. On the tablet two-pane layout this panel is rebuilt on every build/setState, so each rebuild allocates a new controller (and drops the previous one's state). Consequence: allocation churn on every rebuild of the detail pane. — Smallest safe fix: keep a single controller in state (recreate/dispose when the selected line changes) rather than creating one per build.

- [low] lib/features/settings/debug_log_screen.dart:30 — `_refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) { if (mounted) setState(() {}); })` unconditionally rebuilds the entire log screen — recomputing `entriesForCategory(_filter)` (line 49, O(entries)) and rebuilding the ListView — every 2 seconds even when no new entries arrive. Consequence: constant background rebuild/CPU while the screen is open, wasteful on low-power devices; bounded by the 500-entry cap so severity is low. — Smallest safe fix: only rebuild when the entry count or a revision counter changes (e.g. compare `_log.entries.length` and skip the setState when unchanged).

## Coverage
- lib/features/script_editor/script_editor_screen.dart — findings: 2
- lib/features/script_editor/validation_panel.dart — clean
- lib/features/script_import/ocr_review_screen.dart — findings: 3
- lib/features/script_import/pdf_page_view.dart — clean
- lib/features/script_import/script_import_screen.dart — clean
- lib/features/settings/ai_models_screen.dart — clean
- lib/features/settings/debug_log_screen.dart — findings: 1
- lib/features/settings/kokoro_debug_screen.dart — clean
- lib/features/settings/model_download_screen.dart — clean
- lib/features/settings/parakeet_debug_screen.dart — clean
- lib/features/settings/settings_screen.dart — clean
- lib/firebase_options.dart — clean
# Batch 9 — Performance findings

- [high] supabase/migrations/20260315_cast_join_code.sql:20 — dropping the `cast_members_production_id_user_id_key` constraint (line 19 comment, line 20 `ALTER TABLE public.cast_members DROP CONSTRAINT IF EXISTS cast_members_production_id_user_id_key;`) removed the only index on `cast_members.production_id`, and no replacement index was created. Every membership check (`is_production_member` at 20260314140000_fix_rls_recursion.sql:7 does `select exists(select 1 from cast_members where production_id = ... and user_id = ...)`), the `fetch_cast_for_join` RPC (20260319000001_join_flow_rpc_v2.sql:19 `WHERE cm.production_id = prod_id::uuid`), and the RLS policies that call `is_production_member` per row ("Members can read productions" 20260314140000_fix_rls_recursion.sql:40 runs it once per production row scanned) now do a sequential scan of `cast_members`. As cast rows grow across all productions, the join flow and home-screen membership queries degrade to a full-table scan per check — N productions × M cast rows. Fix: `create index on public.cast_members (production_id)` (or `(production_id, user_id)`).

- [medium] supabase/migrations/20260314061409_initial_schema.sql:44 — `organizer_id uuid not null references auth.users(id)` has no index. The "Organizer full access" RLS policy (`using (auth.uid() = organizer_id)`, line 53) and organizer-scoped production queries (e.g. `fetchMyProductions`, which runs on every home-screen load) scan `productions` per row when the planner cannot use an index. Grows with total productions. Fix: `create index on public.productions (organizer_id)`.

- [medium] macos/Runner/BackgroundDownloadPlugin.swift:137 — `urlSession(_:downloadTask:didWriteData:...)` calls `channel.invokeMethod("onDownloadProgress", ...)` once per URLSession data-chunk write, which fires very frequently for large model downloads (hundreds of MB). Each `invokeMethod` is a cross-isolate message to the Dart side, so a single multi-hundred-MB download floods the main isolate with tens of thousands of progress messages, adding per-chunk overhead and GC churn. Fix: throttle — only invoke when `progress` crosses a threshold (e.g. ≥1% delta from the last emitted value) or at most N times/sec.

- [low] lib/providers/production_providers.dart:76 — `addAll` loops `for (final production in productions) { await _repo.saveProduction(production); }` doing one Drift DB write per production. Called by `restoreCloudProductions` (line 504) which runs on every home-screen load; a user with many cloud productions gets N sequential awaited single-row inserts instead of a batch insert. Bounded by the number of missing productions, so it is a cold-path cost, but it is per-item I/O in a loop. Fix: batch the inserts in one transaction/`insertOrReplace` call.

## Coverage
lib/main.dart — clean
lib/providers/production_providers.dart — findings: 1
linux/flutter/generated_plugin_registrant.cc — clean
linux/flutter/generated_plugin_registrant.h — clean
linux/runner/main.cc — clean
linux/runner/my_application.cc — clean
linux/runner/my_application.h — clean
macos/Flutter/GeneratedPluginRegistrant.swift — clean
macos/Runner/AppDelegate.swift — clean
macos/Runner/BackgroundDownloadPlugin.swift — findings: 1
macos/Runner/MainFlutterWindow.swift — clean
macos/Runner/MemoryMonitorPlugin.swift — clean
macos/Runner/PdfTextPlugin.swift — clean
macos/Runner/VisionOcrPlugin.swift — clean
macos/RunnerTests/RunnerTests.swift — clean
pubspec.yaml — clean
scripts/compare_macbeth_versions.py — clean
scripts/deploy.sh — clean
scripts/generate_rehearsal_webp.sh — clean
scripts/generate_screenshots.sh — clean
scripts/generate_test_export.py — clean
scripts/parse_script.py — clean
scripts/pdf_to_script.py — clean
scripts/phone-harness.sh — clean
scripts/pull-crashlog.sh — clean
scripts/pull-debuglog.sh — clean
scripts/ship-play.sh — clean
scripts/ship-testflight.sh — clean
scripts/test_pdf_import.swift — clean
scripts/test_silence_trim.swift — clean
supabase/config.toml — clean
supabase/migrations/20260314061409_initial_schema.sql — findings: 1
supabase/migrations/20260314120000_add_script_lines.sql — clean
supabase/migrations/20260314130000_fix_cast_members_rls.sql — clean
supabase/migrations/20260314140000_fix_rls_recursion.sql — clean
supabase/migrations/20260315_cast_join_code.sql — findings: 1
supabase/migrations/20260316_join_code_default.sql — clean
supabase/migrations/20260318_add_join_code_policy.sql — clean
supabase/migrations/20260319000001_join_flow_rpc_v2.sql — clean
supabase/migrations/20260319100000_add_voice_preset.sql — clean
supabase/migrations/20260319100001_add_locale.sql — clean
supabase/migrations/20260320200000_add_debug_reports.sql — clean
supabase/migrations/20260701090000_add_multi_characters.sql — clean
supabase/migrations/20260703090000_leave_policy_and_audit_cleanup.sql — clean
supabase/migrations/20260703100000_purge_test_productions.sql — clean
supabase/migrations/20260703140000_security_lockdown.sql — clean
supabase/migrations/20260703150000_fix_helper_grants.sql — clean
supabase/migrations/20260703160000_drop_last_productions_readall.sql — clean
supabase/migrations/20260703170000_recordings_delete_policy.sql — clean
test_driver/integration_test.dart — clean
test/analytics_route_observer_test.dart — clean
test/cast_member_test.dart — clean
test/cast_role_test.dart — clean
test/cloud_sync_dialog_test.dart — clean
test/dialog_navigation_test.dart — clean
test/gender_inference_test.dart — clean
test/home_screen_logic_test.dart — clean
test/model_manager_test.dart — clean
test/models_test.dart — clean
test/ocr_cleanup_test.dart — clean
test/ocr_confidence_mapping_test.dart — clean
test/ocr_confidence_test.dart — clean
test/parser_accuracy_test.dart — clean
test/parser_edge_cases_test.dart — clean
test/pdf_export_test.dart — clean
test/pdf_import_test.dart — clean
# Batch 10 — performance review findings

- [low] tool/orphan_sweep.dart:77 — regex recompiled per row inside the orphan-report loop: `final m = RegExp('/$pid/([^/]+)/').firstMatch(Uri.decodeFull(r['audio_url'] as String? ?? ''));` builds a new `RegExp` for every orphan recording (and again per row in the `byWhen` aggregation loop at lines 73-82). Consequence: regex compilation + `RegExp` object allocation per recording row; a production with thousands of orphaned recordings makes the report loop spend measurable CPU on compilation that never changes per row. Smallest safe fix: hoist `final charRe = RegExp('/$pid/([^/]+)/');` once per production before the loop and reuse it (`.firstMatch` on the shared instance).

- [low] tool/analyze_orphaned_recordings.dart:84-85 — `String charOf(String url) { final m = RegExp('/$productionId/([^/]+)/').firstMatch(Uri.decodeFull(url)); ... }` constructs a new `RegExp` on every call, and `charOf` is invoked once per orphan row (loop at lines 91-95) and once per recording row (loop at lines 102-107). Consequence: regex compilation + allocation per recording row across the full recordings list; the pattern is constant for the production. Smallest safe fix: build `final charRe = RegExp('/$productionId/([^/]+)/');` once and call `charRe.firstMatch(...)` inside `charOf`.

## Coverage
- test/pp_ocr_attribution_test.dart — clean
- test/production_repository_test.dart — clean
- test/recording_path_safety_test.dart — clean
- test/recording_sync_service_test.dart — clean
- test/rehearsal_models_test.dart — clean
- test/sample_script_test.dart — clean
- test/script_parser_import_test.dart — clean
- test/shakespeare_import_test.dart — clean
- test/sharing_test.dart — clean
- test/stt_adaptation_test.dart — clean
- test/stt_service_test.dart — clean
- test/stt_vocabulary_service_test.dart — clean
- test/supabase_join_test.dart — clean
- test/supabase_service_test.dart — clean
- test/sync_queue_test.dart — clean
- test/toast_autodismiss_test.dart — clean
- test/tts_service_test.dart — clean
- test/tts_text_chunking_test.dart — clean
- test/voice_clone_test.dart — clean
- test/voice_config_test.dart — clean
- test/widget_test.dart — clean
- tool/analyze_orphaned_recordings.dart — findings: 1
- tool/orphan_sweep.dart — findings: 1
- tool/parse_stats.dart — clean
- tool/sim_multi_user.dart — clean
- tool/verify_cloud_recordings.dart — clean

# Coverage top-up — 92 vendored-ML files, specialized perf skills routed (mlx/metal/simd/ios)

# TOPUP_DSV4 — performance-only findings

- [medium] ios/Runner/MLXSttPlugin.swift:208 — `fullText += token` accumulates the whole transcript on every streamed token event — O(n²) string copy per transcription; a long line/recording (hundreds of tokens) spends quadratic time copying the growing string inside the streaming decode loop — use an `NSMutableString` (or collect parts then `joined()` once) instead of `+=` per token.

- [medium] ios/Runner/PdfTextPlugin.swift:80 — `fullText += pageText; fullText += "\n"` per page concatenates the whole document repeatedly — O(n²) across pages; a long PDF (hundreds of pages of extracted text) re-copies the entire growing string per page — collect page strings into a `[String]` and `joined(separator: "\n")` once, or use an `NSMutableString`.

- [medium] ios/Runner/PdfTextPlugin.swift:144 — `hasEmbeddedText` calls `PDFDocument(url:)` synchronously on the main thread (the `handle` switch invokes it directly, unlike `extractText`/`extractTextPerPage` which hop to a background queue) — opening a large PDF blocks the UI thread and causes visible jank on the import path — wrap the document open + first-3-pages scan in `DispatchQueue.global(qos: .userInitiated).async` and hop back to `DispatchQueue.main` for `result`.

- [medium] ios/Runner/BackgroundDownloadPlugin.swift:190 — `channel.invokeMethod("onDownloadProgress", ...)` fires from `didWriteData` on every URLSession write callback — a platform-channel storm for multi-GB model downloads (URLSession can deliver thousands of callbacks per transfer), each crossing the Flutter bridge and waking the Dart isolate — throttle: only invoke when `progress` changed by ≥ ~0.01 or when ≥ N bytes written since the last report.

- [medium] ios/Runner/KokoroVendored/BuildingBlocks/ConvWeighted.swift:100 — `let weight = weightNorm(weightV: weightV, weightG: weightG, dim: 0)` recomputes the normalized convolution weight on every `callAsFunction` (both overloads, lines 100 and 128), but `weightV`/`weightG` are static after load — a full-tensor `sqrt(sum(x*x))` + division per conv forward, multiplied across every conv layer and synthesis step in Decoder/Generator/TextEncoder/ProsodyPredictor — compute `weightNorm` once in `init` and cache the normalized `MLXArray` (invalidate only if weights mutate).

- [medium] ios/Runner/KokoroVendored/TTSEngine/DurationEncoder.swift:92 — `MLX.where(m..., MLXArray.zeros(like: x), x)` re-masks with a fresh `zeros(like:)` allocation after every alternating LSTM/AdaLayerNorm layer (also line 109), and lines 123-125 allocate `MLXArray.zeros([...])` then overwrite it per LSTM block — allocation churn scaled by `nlayers × 2` × steps — build the mask/zero buffer once before the layer loop and reuse it; mask once where semantics allow.

- [medium] ios/Runner/KokoroVendored/TTSEngine/TextEncoder.swift:131 — `x = MLX.where(mask, 0.0, x)` is re-applied after every CNN sublayer (also line 104), and lines 143-144 allocate `MLX.zeros([...])` then `_updateInternal(x)` per call — redundant full-tensor mask passes scaled by `depth × 3` sublayers over the whole sequence — apply the mask once after the CNN stack (or rely on the final mask) and reuse a single zero tensor instead of `zeros`+overwrite.

- [high] ios/Runner/MisakiVendored/English/FallbackNetwork/BARTModel.swift:120 — `generate` decodes the fallback BART G2P without a KV-cache: `decode(decoderInput, ...)` (line 127) re-projects and re-attends over the whole prefix plus cross-attention each step, `decoderInput = concatenated([decoderInput, newToken], axis: 1)` (line 145) reallocates the growing prefix per token, and `scaledLogits.argMax().item(Int32.self)` (line 134) forces a GPU→CPU pipeline stall per token — for every out-of-lexicon word this is O(t²) attention recompute plus N device syncs per word — thread per-layer K/V caches and feed only the new position, accumulate tokens in a pre-sized native `[Int32]`, and keep argmax on-device (sync once at loop exit).

- [medium] ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetAudio.swift:24 — `makeWindow(...)` and `melFilters(...)` (lines 24 and 36-42) recompute the STFT window and mel filterbank on every `logMelSpectrogram` call, but both depend only on `config` — `decodeChunk` calls this once per audio chunk inside the `while start < totalSamples` streaming loop (ParakeetModel.swift:437), so the filterbank is rebuilt per chunk as audio duration grows — cache window + mel-filters as static tables keyed by the config (nFft/winLength/sampleRate/nMels).

- [low] ios/Runner/KokoroVendored/Decoder/MLXSTFT.swift:61 — `hanning(length: winLen + 1)` (also line 120) rebuilds the window tensor on every `mlxStft`/`mlxIstft` call though it depends only on `winLength` — once-per-synthesis scalar window construction — hoist the window to a static/instance value computed once per `MLXSTFT`.

- [low] ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetTokenizer.swift:10 — `vocabulary[token].replacingOccurrences(of: "▁", with: " ")` allocates a new string per decoded token in a loop over the token sequence — per-token allocation on the decode path — precompute a cleaned vocabulary array (or build the result with `NSMutableString`) once.

- [low] ios/Runner/KokoroVendored/TextProcessing/Tokenizer.swift:20 — `text.map { vocab[String($0)] }` constructs a `String` per character and does a dict lookup per char over the phonemized text — per-char allocation on the TTS tokenization path — iterate with `unicodeScalars` and look up without per-char `String` allocation, and `reserveCapacity` the result.

- [low] ios/Runner/MisakiVendored/English/Lexicon/PennTagUtil.swift:30 — nine `Set<String>` literals (`whDeterminers`, `whPronouns`, `whAdverbs`, ...) are constructed on every `pennTag(for:token:)` call, which runs per token during G2P — per-token set allocations — hoist them to file/static-level constants.

- [low] lib/data/services/kokoro_onnx_service.dart:362 — the WAV writer converts every sample with a Dart scalar `round()` + clamp + `setInt16` loop (`for (var i = 0; i < n; i++)`) over the full synthesis audio — per-sample scalar work on the hot synthesis path (tens of thousands of samples) — bulk-convert into an `Int16List`/`ByteData` via typed-data views after one clamp pass, then write once.

- [low] lib/data/services/live_asr_service.dart:216 — the per-PCM-chunk `for (var i = 0; i < n; i++) { samples[i] = bd.getInt16(...) / 32768.0 }` scalar conversion runs on every 16 kHz chunk (≈1600 samples × ~10/s) during live rehearsal matching — per-sample scalar conversion on the hot path — bulk-convert with `Float32List`/`Int16List` typed views instead of the per-sample loop.

- [low] lib/data/services/debug_log_service.dart:184 — `File(path).writeAsStringSync('...', mode: FileMode.append, flush: true)` fsyncs on every `log` entry, and logging is frequent on the rehearsal/STT/TTS paths — fsync per log line adds disk sync latency under heavy logging — drop `flush: true` (let the OS buffer) or batch appends; keep an explicit flush only at checkpoints.

## Coverage
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/Generation.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetAttention.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetAudio.swift — findings: 1
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetConfig.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetConformer.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetCTCLayers.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetDecodingLogic.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetRNNTLayers.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetTokenizer.swift — findings: 1
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/STTOutput.swift — clean
- ios/Runner/BackgroundDownloadPlugin.swift — findings: 1
- ios/Runner/ContactPickerPlugin.swift — clean
- ios/Runner/KokoroMLXPlugin.swift — clean
- ios/Runner/KokoroVendored/Albert/AlbertEmbeddings.swift — clean
- ios/Runner/KokoroVendored/Albert/AlbertEncoder.swift — clean
- ios/Runner/KokoroVendored/Albert/AlbertIntermediate.swift — clean
- ios/Runner/KokoroVendored/Albert/AlbertLayer.swift — clean
- ios/Runner/KokoroVendored/Albert/AlbertLayerGroup.swift — clean
- ios/Runner/KokoroVendored/Albert/AlbertModelArgs.swift — clean
- ios/Runner/KokoroVendored/Albert/AlbertOutput.swift — clean
- ios/Runner/KokoroVendored/Albert/AlbertSelfAttention.swift — clean
- ios/Runner/KokoroVendored/Albert/AlbertSelfOutput.swift — clean
- ios/Runner/KokoroVendored/Albert/CustomAlbert.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/AdaIN1d.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/AdainResBlk1d.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/AdaINResBlock1.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/AdaLayerNorm.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/Conv1dInference.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/ConvWeighted.swift — findings: 1
- ios/Runner/KokoroVendored/BuildingBlocks/InstanceNorm1d.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/Interpolate.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/LayerNormInference.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/ReflectionPad1d.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/UpSample1d.swift — clean
- ios/Runner/KokoroVendored/Decoder/Decoder.swift — clean
- ios/Runner/KokoroVendored/Decoder/Generator.swift — clean
- ios/Runner/KokoroVendored/Decoder/MLXSTFT.swift — findings: 1
- ios/Runner/KokoroVendored/Decoder/SineGen.swift — clean
- ios/Runner/KokoroVendored/Decoder/SourceModuleHnNSF.swift — clean
- ios/Runner/KokoroVendored/TextProcessing/eSpeakNGG2PProcessor.swift — clean
- ios/Runner/KokoroVendored/TextProcessing/G2PFactory.swift — clean
- ios/Runner/KokoroVendored/TextProcessing/G2PProcessor.swift — clean
- ios/Runner/KokoroVendored/TextProcessing/Language.swift — clean
- ios/Runner/KokoroVendored/TextProcessing/MisakiG2PProcessor.swift — clean
- ios/Runner/KokoroVendored/TextProcessing/Tokenizer.swift — findings: 1
- ios/Runner/KokoroVendored/TTSEngine/DurationEncoder.swift — findings: 1
- ios/Runner/KokoroVendored/TTSEngine/KokoroConfig.swift — clean
- ios/Runner/KokoroVendored/TTSEngine/ProsodyPredictor.swift — clean
- ios/Runner/KokoroVendored/TTSEngine/TextEncoder.swift — findings: 1
- ios/Runner/KokoroVendored/TTSEngine/WeightLoader.swift — clean
- ios/Runner/MediaControlPlugin.swift — clean
- ios/Runner/MemoryMonitorPlugin.swift — clean
- ios/Runner/MisakiVendored/English/DataStructures/TokenContext.swift — clean
- ios/Runner/MisakiVendored/English/FallbackNetwork/BARTConfig.swift — clean
- ios/Runner/MisakiVendored/English/FallbackNetwork/BARTDecoderLayer.swift — clean
- ios/Runner/MisakiVendored/English/FallbackNetwork/BARTEncoderLayer.swift — clean
- ios/Runner/MisakiVendored/English/FallbackNetwork/BARTLayerNorm.swift — clean
- ios/Runner/MisakiVendored/English/FallbackNetwork/BARTModel.swift — findings: 1
- ios/Runner/MisakiVendored/English/FallbackNetwork/EnglishFallbackNetwork.swift — clean
- ios/Runner/MisakiVendored/English/FallbackNetwork/FeedForward.swift — clean
- ios/Runner/MisakiVendored/English/FallbackNetwork/MultiHeadAttention.swift — clean
- ios/Runner/MisakiVendored/English/Lexicon/DataResourcesUtil.swift — clean
- ios/Runner/MisakiVendored/English/Lexicon/PennTagUtil.swift — findings: 1
- ios/Runner/MisakiVendored/Extensions/MLXArray+DebugPrint.swift — clean
- ios/Runner/MisakiVendored/Extensions/NLTag+ProperNoun.swift — clean
- ios/Runner/MisakiVendored/Extensions/Range+Contains.swift — clean
- ios/Runner/MisakiVendored/Extensions/String+ReplacingLast.swift — clean
- ios/Runner/MLXSttPlugin.swift — findings: 1
- ios/Runner/ObjCExceptionCatcher.h — clean
- ios/Runner/ObjCExceptionCatcher.m — clean
- ios/Runner/PdfTextPlugin.swift — findings: 3
- lib/app.dart — clean
- lib/core/constants.dart — clean
- lib/core/responsive.dart — clean
- lib/core/theme/app_theme.dart — clean
- lib/core/toast.dart — clean
- lib/data/database/app_database.dart — clean
- lib/data/models/cast_member_model.dart — clean
- lib/data/models/production_models.dart — clean
- lib/data/models/rehearsal_models.dart — clean
- lib/data/models/voice_preset.dart — clean
- lib/data/repositories/production_repository.dart — clean
- lib/data/services/analytics_service.dart — clean
- lib/data/services/audio_level_service.dart — clean
- lib/data/services/contact_picker_service.dart — clean
- lib/data/services/debug_log_service.dart — findings: 1
- lib/data/services/deep_link_service.dart — clean
- lib/data/services/kokoro_onnx_service.dart — findings: 1
- lib/data/services/live_asr_service.dart — findings: 1
- lib/data/services/media_control_service.dart — clean
- lib/data/services/mlx_stt_channel.dart — clean
- lib/data/services/model_manager.dart — clean
