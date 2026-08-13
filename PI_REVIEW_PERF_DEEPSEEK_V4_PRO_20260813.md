# Pi sweep review (perf focus) — CastCircle-5cfa63ca

Exhaustive per-file pass: 274 code files across 23 batches.

## Findings

- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:460 — `releaseRecorder()` calls `captureThread?.join(1500)` and is reached from main-thread handlers `stopListening` (line 239), `startRecording` (line 278), and `onDetachedFromEngine` (line 77). The capture thread can be parked in `MediaCodec.dequeueInputBuffer(10_000)` (up to 10 s) or a stalled `drainEncoder`, so the join blocks the platform main thread for up to 1.5 s — jank/ANR risk when a recording is stopped mid-capture (e.g. screen close). Fix: set `capturing = false` and join off the main thread (the `stopRecording` method already does exactly this), or drop the join and let the capture thread's `finally` release resources.
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:289 — `detectBoxes` stores per-component state in boxed `ArrayList<Int>` (`area`/`minX`/`minY`/`maxX`/`maxY`) and a boxed `ArrayDeque<Int>` stack, and the connected-components fill does `area[id] = area[id] + 1` (line 314) plus `stack.addLast(np)` (lines 316–319) once per foreground pixel. Each is an `Integer` autobox/unbox allocation; a dense detection map (up to 960×960 ≈ 921k pixels) drives ~2 allocations per foreground pixel (hundreds of thousands of `Integer`s per page), adding GC churn to an already multi-second-per-page OCR hot path. Fix: use `IntArray` for the component bounds/area and an `IntArray`-backed stack (primitive), avoiding boxed collections entirely.
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/PdfTextPlugin.kt:70 — `checkPdfReadable` (called from the main-thread `hasEmbeddedText` handler, line 55) opens a `ParcelFileDescriptor` and constructs a `PdfRenderer`, parsing the PDF xref table and reading `pageCount` (line 71) on every call — then discards `hasPages` and unconditionally returns `false`. For large scanned scripts this is wasted file I/O + PDF parse on the main thread on a per-call basis, janking the UI for a result the caller never uses. Fix: return `false` immediately without opening the PDF (the method's contract is always-fall-through-to-OCR), or delete the renderer/pageCount work entirely.

## Coverage
analysis_options.yaml — clean
android/app/build.gradle.kts — clean
android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt — findings: 1
android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt — clean
android/app/src/main/kotlin/com/tiltastech/lineguide/MainActivity.kt — clean
android/app/src/main/kotlin/com/tiltastech/lineguide/MemoryMonitorPlugin.kt — clean
android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt — findings: 1
android/app/src/main/kotlin/com/tiltastech/lineguide/PdfTextPlugin.kt — findings: 1
android/app/src/main/kotlin/com/tiltastech/lineguide/StubPlugins.kt — clean
android/build.gradle.kts — clean
android/gradle.properties — clean
android/gradle/wrapper/gradle-wrapper.properties — clean
android/settings.gradle.kts — clean
ios/Runner/AppDelegate.swift — clean
ios/Runner/AppleSttPlugin.swift — clean
ios/Runner/AudioAnalysisPlugin.swift — clean
ios/Runner/BackgroundDownloadPlugin.swift — clean
ios/Runner/ContactPickerPlugin.swift — clean
ios/Runner/KokoroMLXPlugin.swift — clean
ios/Runner/KokoroMLXService.swift — clean
# Perf sweep — batch 2 (KokoroVendored MLX inference, Swift)

Stack: Swift + MLX/MLXNN vendored TTS inference. Checklists applied: performance-review (general), mlx-performance-review (MLX tensor code), ios-performance-review (platform) — MLX internals route to mlx skill. These files are lazy-graph tensor code; hot-path = `callAsFunction` on the encoder/decoder graph, executed per synthesis (and per decoder step).

## Findings

- [medium] ios/Runner/KokoroVendored/BuildingBlocks/ConvWeighted.swift:100 — weight normalization is recomputed on every forward pass: `weightNorm(weightV:weightG:dim: 0)` re-runs a full L2-norm reduction over the entire weight tensor (`sum(weightV * weightV)` + sqrt + divide + multiply) plus `bias = bias?.reshaped([1,1,-1])` every `callAsFunction`, even though `weightV`/`weightG`/`bias` are frozen after load. The same code is duplicated in the second overload at line 128 (convTransposed path). — Every ConvWeighted layer (conv1/conv2/conv1x1/pool in `AdainResBlk1d`, convs1/convs2 in `AdaINResBlock1`) re-reduces its full weight tensor on every inference call; with multiple conv layers per block and repeated syntheses this is redundant GPU work proportional to (weight size × layers × calls). — Normalize the weight once at init (or lazily cache the normalized weight and reshaped bias in stored fields) and reuse in `callAsFunction`.

- [low] ios/Runner/KokoroVendored/BuildingBlocks/LSTM.swift:89 — `whForward.transposed()` is recomputed inside the per-timestep loop (`for idx in 0 ..< seqLen`); `whForward` is loop-invariant. Same for `whBackward.transposed()` at line 137 in `backwardDirection`. — One extra transpose graph node recorded per sequence step (seqLen grows with input text length) on the hot sequence-processing path. — Hoist `let whForwardT = whForward.transposed()` (and `whBackwardT`) before the loop and matmul against the precomputed view.

- [low] ios/Runner/KokoroVendored/BuildingBlocks/InstanceNorm1d.swift:69 — `mean = MLX.mean(input, ...)` is followed by `variance = MLX.variance(input, ...)`; `MLX.variance` internally computes its own mean, so `input` is fully reduced twice. — Instance norm runs inside `AdaIN1d` on every decoder block per forward pass; the second reduction is a full extra pass over `[batch, channels, length]` for no benefit. — Compute `variance` from the already-computed `mean` (e.g. `mean((x-mean)^2)`) or use a single fused stat pass.

- [low] ios/Runner/KokoroVendored/BuildingBlocks/AdaLayerNorm.swift:25 — same redundant double reduction: `MLX.mean` at line 25 then `MLX.variance` at line 26 recomputes the mean over `x` (axes -1). — One extra full-tensor reduction pass on the hot per-block normalization path. — Derive variance from the existing `mean` (mean-of-squared-deviations) instead of a second `MLX.variance` pass.

- [low] ios/Runner/KokoroVendored/Albert/AlbertEmbeddings.swift:27 — LayerNorm weights copied element-by-element via `layerNorm.bias![i] = layerNormBiases[i]`; each scalar subscript on an MLXArray forces a GPU→CPU evaluation, so this loop performs ~2×`embeddingSize` device syncs at init. — Slower model load (sync per element); trivially replaced by whole-array assignment. — Assign the arrays directly (`layerNorm.bias = layerNormBiases; layerNorm.weight = layerNormWeights`), matching the `guard` shape check already present.

- [low] ios/Runner/KokoroVendored/Albert/AlbertLayer.swift:30 — same per-element scalar sync loop copying `fullLayerLayerNorm` weight/bias over `config.hiddenSize` elements (~2×`hiddenSize` device syncs at init). — Slower model load; whole-array assignment is equivalent. — Assign `fullLayerLayerNorm.weight`/`.bias` directly instead of the scalar loop.

- [low] ios/Runner/KokoroVendored/Albert/AlbertSelfAttention.swift:43 — same per-element scalar sync loop copying the attention `LayerNorm` weight/bias over `config.hiddenSize` elements. — Slower model load; whole-array assignment is equivalent. — Assign `layerNorm.weight`/`.bias` directly instead of the scalar loop.

## Coverage
ios/Runner/KokoroVendored/Albert/AlbertEmbeddings.swift — findings: 1
ios/Runner/KokoroVendored/Albert/AlbertEncoder.swift — clean
ios/Runner/KokoroVendored/Albert/AlbertIntermediate.swift — clean
ios/Runner/KokoroVendored/Albert/AlbertLayer.swift — findings: 1
ios/Runner/KokoroVendored/Albert/AlbertLayerGroup.swift — clean
ios/Runner/KokoroVendored/Albert/AlbertModelArgs.swift — clean
ios/Runner/KokoroVendored/Albert/AlbertOutput.swift — clean
ios/Runner/KokoroVendored/Albert/AlbertSelfAttention.swift — findings: 1
ios/Runner/KokoroVendored/Albert/AlbertSelfOutput.swift — clean
ios/Runner/KokoroVendored/Albert/CustomAlbert.swift — clean
ios/Runner/KokoroVendored/BuildingBlocks/AdaIN1d.swift — clean
ios/Runner/KokoroVendored/BuildingBlocks/AdainResBlk1d.swift — clean
ios/Runner/KokoroVendored/BuildingBlocks/AdaINResBlock1.swift — clean
ios/Runner/KokoroVendored/BuildingBlocks/AdaLayerNorm.swift — findings: 1
ios/Runner/KokoroVendored/BuildingBlocks/Conv1dInference.swift — clean
ios/Runner/KokoroVendored/BuildingBlocks/ConvWeighted.swift — findings: 1
ios/Runner/KokoroVendored/BuildingBlocks/InstanceNorm1d.swift — findings: 1
ios/Runner/KokoroVendored/BuildingBlocks/Interpolate.swift — clean
ios/Runner/KokoroVendored/BuildingBlocks/LayerNormInference.swift — clean
ios/Runner/KokoroVendored/BuildingBlocks/LSTM.swift — findings: 1
- [medium] ios/Runner/KokoroVendored/TTSEngine/TextEncoder.swift:102 — `MLX.where(maskT, 0.0, x)` uses a scalar `0.0` literal (also lines 111, 114, and 131) instead of `MLXArray.zeros(like: x)` — this promotes the bf16 activation tensor to float32 for the elementwise mask op (the sibling DurationEncoder.callAsFunction documents this exact failure at lines 99–101 and switched to `zeros(like:)`), so every mask application (after embedding, after each conv sub-layer, after each LayerNorm sub-layer, and the final output) upcasts the full [batch, seq, channels] tensor and allocates a float32 temporary — roughly 2× memory bandwidth plus a float32 round-trip on the activation tensor ~14 times per synthesis, on the hot path of every `generateAudio` call — smallest fix: replace the `0.0` scalar with `MLXArray.zeros(like: x)` in all four `MLX.where` calls, matching DurationEncoder.

## Coverage
ios/Runner/KokoroVendored/BuildingBlocks/ReflectionPad1d.swift — clean
ios/Runner/KokoroVendored/BuildingBlocks/UpSample1d.swift — clean
ios/Runner/KokoroVendored/Decoder/Decoder.swift — clean
ios/Runner/KokoroVendored/Decoder/Generator.swift — clean
ios/Runner/KokoroVendored/Decoder/MLXSTFT.swift — clean
ios/Runner/KokoroVendored/Decoder/SineGen.swift — clean
ios/Runner/KokoroVendored/Decoder/SourceModuleHnNSF.swift — clean
ios/Runner/KokoroVendored/TextProcessing/eSpeakNGG2PProcessor.swift — clean
ios/Runner/KokoroVendored/TextProcessing/G2PFactory.swift — clean
ios/Runner/KokoroVendored/TextProcessing/G2PProcessor.swift — clean
ios/Runner/KokoroVendored/TextProcessing/Language.swift — clean
ios/Runner/KokoroVendored/TextProcessing/MisakiG2PProcessor.swift — clean
ios/Runner/KokoroVendored/TextProcessing/Tokenizer.swift — clean
ios/Runner/KokoroVendored/TTSEngine/DurationEncoder.swift — clean
ios/Runner/KokoroVendored/TTSEngine/KokoroConfig.swift — clean
ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift — clean
ios/Runner/KokoroVendored/TTSEngine/ProsodyPredictor.swift — clean
ios/Runner/KokoroVendored/TTSEngine/TextEncoder.swift — findings: 1
ios/Runner/KokoroVendored/TTSEngine/TimestampPredictor.swift — clean
ios/Runner/KokoroVendored/TTSEngine/WeightLoader.swift — clean
- [medium] ios/Runner/MisakiVendored/English/FallbackNetwork/BARTModel.swift:166 — per-token `scaledLogits.argMax().item(Int32.self)` inside the autoregressive `generate` loop forces a synchronous GPU→CPU transfer plus full evaluation of the step's lazy graph every decode step, so the next token's graph construction cannot start until the transfer returns (no async-eval overlap) — decode latency scales as tokens × sync stall, and this fallback runs once per out-of-vocabulary word during phonemization (up to `maxLength`=50 steps each) — smallest safe fix: keep argmax on-device and only synchronize at the EOS branch, or overlap with `async_eval` (Swift `asyncEval`) so next-step construction proceeds while the current step runs.
- [medium] ios/Runner/MisakiVendored/English/FallbackNetwork/BARTDecoderLayer.swift:54 — self-attention KV cache grown by `concatenated([cache.k, k], axis: 2)` (and `v` at :55) each `step` re-allocates and copies the entire accumulated K/V sequence on every token — O(t) copy per token, O(t²) per sequence (t up to maxLength=50), paid per out-of-vocabulary word across every decoder layer and head — smallest safe fix: preallocate K/V cache blocks and assign the new slice in place (or use MLX `KVCache`), instead of concatenating a fresh tensor per step.
- [low] ios/Runner/MisakiVendored/English/Lexicon/PennTagUtil.swift:30 — `pennTag(for:)` constructs eight `Set<String>` literals (`whDeterminers`, `whPronouns`, `whAdverbs`, `possessivePronouns`, `auxBe`, `auxDo`, `auxHave`, `subordinatingConjunctions`) on every call, and `isPersonalPrononun` (:144) builds a 20-entry `personalPronouns` set per call; `pennTag` is invoked once or more per token in the G2P hot path (`Lexicon.getParentTag`/`getSpecialCase`/`lookup`) — ~10 set allocations plus retain/release churn per token, compounding on long phonemize inputs — smallest safe fix: hoist these sets to file-scope `static let` constants so they are built once.
- [low] ios/Runner/MisakiVendored/English/EnglishG2P.swift:159 — `result += String(input[lastEnd..<start])` (and `result += grapheme` at :166) inside the `linkRegex.enumerateMatches` closure re-copies the entire accumulated result string once per markdown-link match — O(n·m) character copies where n = number of `[text](url)` matches in the input and m = output length — smallest safe fix: append the slices to an array and `.joined()` once after the loop, or advance a `String.Index` cursor and build the result in a single pass.
## Coverage
ios/Runner/KokoroVendored/Utils/AudioUtils.swift — clean
ios/Runner/MediaControlPlugin.swift — clean
ios/Runner/MemoryMonitorPlugin.swift — clean
ios/Runner/MisakiVendored/English/DataStructures/TokenContext.swift — clean
ios/Runner/MisakiVendored/English/EnglishG2P.swift — findings: 1
ios/Runner/MisakiVendored/English/FallbackNetwork/BARTConfig.swift — clean
ios/Runner/MisakiVendored/English/FallbackNetwork/BARTDecoderLayer.swift — findings: 1
ios/Runner/MisakiVendored/English/FallbackNetwork/BARTEncoderLayer.swift — clean
ios/Runner/MisakiVendored/English/FallbackNetwork/BARTLayerNorm.swift — clean
ios/Runner/MisakiVendored/English/FallbackNetwork/BARTModel.swift — findings: 1
ios/Runner/MisakiVendored/English/FallbackNetwork/EnglishFallbackNetwork.swift — clean
ios/Runner/MisakiVendored/English/FallbackNetwork/FeedForward.swift — clean
ios/Runner/MisakiVendored/English/FallbackNetwork/MultiHeadAttention.swift — clean
ios/Runner/MisakiVendored/English/Lexicon/DataResourcesUtil.swift — clean
ios/Runner/MisakiVendored/English/Lexicon/Lexicon.swift — clean
ios/Runner/MisakiVendored/English/Lexicon/PennTagUtil.swift — findings: 1
ios/Runner/MisakiVendored/English/Num2Word/EnglishNum2Word.swift — clean
ios/Runner/MisakiVendored/Extensions/MLXArray+DebugPrint.swift — clean
ios/Runner/MisakiVendored/Extensions/NLTag+ProperNoun.swift — clean
ios/Runner/MisakiVendored/Extensions/Range+Contains.swift — clean
- [medium] ios/Runner/PaddleOcrPlugin.swift:253 — the 4-neighbor offset array `[(-1,0),(1,0),(0,-1),(0,1)]` is re-allocated on every iteration of the connected-components flood-fill loop (`while let p = stack.popLast()` at line 248), which visits every above-threshold text pixel in the detection map (~960×960 → tens-to-hundreds of thousands of pixels per page, repeated for every page of an imported script) — heap allocation + ARC churn per visited pixel measurably slows OCR detection on multi-page imports — hoist the offsets to a `static let neighbors: [(Int, Int)]` (or unroll the four neighbor checks explicitly) so no allocation happens inside the loop.
- [medium] ios/Runner/PdfTextPlugin.swift:142 — `hasEmbeddedText` opens the PDF (`PDFDocument(url:)` at line 145) and reads up to 3 pages' `page.string` synchronously on the platform main thread (invoked directly from the method-channel `handle` at line 52), unlike `extractText`/`extractTextPerPage` which wrap their work in `DispatchQueue.global(qos: .userInitiated).async` — PDF open + text-layer parse blocks the UI thread (jank/hang) on large or slow-storage PDFs every time the OCR-vs-PDFKit decision runs — wrap the body in `DispatchQueue.global(qos: .userInitiated).async { ... }` and deliver `result` back on the main queue, matching the sibling handlers.
- [medium] lib/data/models/script_models.dart:363 — `ParsedScript.linesForCharacter` is an O(lines) scan (`lines.where(...).toList()`) that allocates a fresh list per call, and it is invoked once per character inside `ListView.builder`'s `itemBuilder` (lib/features/recording_studio/recording_character_screen.dart:59) — each list build/scroll re-scans the whole script per visible character, O(characters × lines) (e.g. 20 characters × 3000 lines = 60k predicate evaluations per build, re-run for every newly-built row) — precompute a `Map<String, List<ScriptLine>>` once per script change (the pattern already used in cast_manager_screen.dart's `linesByChar`) and have the itemBuilder index into it instead of re-scanning.

## Coverage
ios/Runner/MisakiVendored/Extensions/String+ReplacingLast.swift — clean
ios/Runner/ObjCExceptionCatcher.h — clean
ios/Runner/ObjCExceptionCatcher.m — clean
ios/Runner/PaddleOcrPlugin.swift — findings: 1
ios/Runner/PdfTextPlugin.swift — findings: 1
ios/Runner/Runner-Bridging-Header.h — clean
ios/Runner/SceneDelegate.swift — clean
ios/RunnerTests/RunnerTests.swift — clean
lib/app.dart — clean
lib/core/constants.dart — clean
lib/core/responsive.dart — clean
lib/core/theme/app_theme.dart — clean
lib/core/toast.dart — clean
lib/data/database/app_database.dart — clean
lib/data/models/cast_member_model.dart — clean
lib/data/models/production_models.dart — clean
lib/data/models/rehearsal_models.dart — clean
lib/data/models/script_models.dart — findings: 1
lib/data/models/voice_preset.dart — clean
lib/data/repositories/production_repository.dart — clean
# Performance findings — batch 6

- [medium] lib/data/services/debug_log_service.dart:187 — `log()` persists every entry with `File(path).writeAsStringSync(..., mode: FileMode.append)` on the caller's thread, which is the UI isolate during rehearsal (STT partials, TTS chunk boundaries, 10s memory timer, 30s frame-stats all call `log`); each entry is an open+append+close sync syscall on the UI thread — cumulative jank that scales with rehearsal log cadence, defeating the "backstop" design intent — buffer entries into `_pendingFlush` and let the existing 30s `_flushTimer` (or an async `writeAsString`) do the append instead of a synchronous write per entry.

- [medium] lib/data/services/recording_sync_service.dart:558 — `getCachedRecordings` iterates the global `_cache` (recordings across every production, persisted and never evicted) and does `File(cached.localPath).existsSync()` per matching entry, on the UI isolate, each time a recordings provider builds its map — a sync stat syscall per cached recording that scales with total cache size and runs on every provider rebuild during/after sync — drop the per-entry `existsSync` (the manifest already dropped missing files at hydrate time) or cache file-existence, and record/emit entries lazily instead of stat-ing the whole map per call.

- [low] lib/data/services/kokoro_onnx_service.dart:261 — `_schedulePrune` runs `Directory(dir).listSync()` plus per-file `statSync()`/`deleteSync()` inside a `Future(() {})` closure, which still executes on the main isolate; the first time the ~150 MB WAV cache needs pruning this is a full synchronous directory walk (thousands of files, one stat per file) that blocks the UI — move the prune into `Isolate.run` (or the existing synthesis isolate) so the scan/delete happens off the UI thread.

- [low] lib/data/services/kokoro_onnx_service.dart:182 — every cache-hit `synthesize()` call does `File(cachePath).existsSync()` and `File(cachePath).setLastModifiedSync(DateTime.now())` (a metadata write) synchronously on the caller's UI isolate, once per replayed line during rehearsal — per-line-play sync syscalls on the hot playback path — touch the mtime only at cache-adoption time (or asynchronously) instead of on every read.

- [low] lib/data/services/script_import_service.dart:707 — `_estimateLineConfidence` constructs a new `RegExp(r'(.)\1{2}')` per OCR line even though the identical pattern is already compiled as the static `_tripleRepeatRe` (line 652), and line 728 constructs another `RegExp(r'[^a-zA-Z0-9\s]')` per line; this runs for thousands of lines per scanned play on the ML Kit fallback path — repeated regex compilation/allocation per line — reuse the two static `RegExp` constants (the comment on line 645 claims "compiled once" but these two were missed).

## Coverage
lib/data/services/analytics_service.dart — clean
lib/data/services/audio_level_service.dart — clean
lib/data/services/contact_picker_service.dart — clean
lib/data/services/debug_log_service.dart — findings: 1
lib/data/services/deep_link_service.dart — clean
lib/data/services/frame_stats_service.dart — clean
lib/data/services/kokoro_onnx_service.dart — findings: 2
lib/data/services/live_asr_service.dart — clean
lib/data/services/media_control_service.dart — clean
lib/data/services/model_download_service.dart — clean
lib/data/services/model_manager.dart — clean
lib/data/services/ocr_confidence_service.dart — clean
lib/data/services/paddle_ocr_channel.dart — clean
lib/data/services/pdf_text_channel.dart — clean
lib/data/services/perf_service.dart — clean
lib/data/services/playback_session.dart — clean
lib/data/services/recording_sync_service.dart — findings: 1
lib/data/services/script_export.dart — clean
lib/data/services/script_import_service.dart — findings: 1
- [medium] lib/data/services/script_parser.dart:1127 — `_cleanLine` constructs 4 `RegExp` literals on every call; it is invoked once per raw text line in `_parseLines` (line 1524) and again on every flushed dialogue/stage direction — a full-length play (~thousands of lines) triggers tens of thousands of regex compilations per import, scaling with script size — hoist the 4 patterns to `static final` fields.
- [medium] lib/data/services/script_parser.dart:1474 — the `isRunningHeader` (1474), `actMatch` (1477), and `sceneMatch` (1504) `RegExp`s are constructed inside the per-line loop of `_parseLines`, so every raw line pays regex compile cost during the import hot path — hoist these three patterns to `static final` fields (the file already does this for `_noisePatterns`/`_sceneTransitionPatterns`).
- [low] lib/data/services/script_parser.dart:64 — `_normalizeForHeader` constructs 2 `RegExp`s per call and is called once per line from `_isNoise` (line 1113) whenever running headers were detected, adding per-line compile churn on top of `_cleanLine`/header regexes — hoist the two patterns to `static final` fields.
- [low] lib/data/services/stt_adaptation_service.dart:197 — `addSample` copies the entire samples list on every recording (`[...actorProfile.samples, sample]` at 197, `[...prodProfile.samples, sample]` at 210) and recomputes `totalAudioSeconds` via `fold` (line 65) multiple times per call — total cost is O(n²) element copies + folds as a production accumulates recordings, and the pooled production list grows with the whole cast — keep a mutable list plus a running duration total, or append to the existing list and materialize only on read.
- [low] lib/data/services/stt_vocabulary_service.dart:157 — `correct()` applies every learned per-actor correction (one `replaceAll` regex pass each) on every partial STT result (several times/second while the actor speaks), and `_actorCorrections`/`_correctionPatterns` grow with no cap (unlike the vocabulary `correctionCache`, bounded at 4000) — per-partial regex work and memory grow monotonically with the number of distinct misrecognized words an actor accumulates over a long production — cap the per-actor correction map or apply all corrections in a single combined word-replacement pass.

## Coverage
lib/data/services/script_parser.dart — findings: 3
lib/data/services/stt_adaptation_service.dart — findings: 1
lib/data/services/stt_channel.dart — clean
lib/data/services/stt_service.dart — clean
lib/data/services/stt_vocabulary_service.dart — findings: 1
lib/data/services/supabase_service.dart — clean
lib/data/services/sync_queue.dart — clean
- [low] lib/features/cast_manager/bulk_cast_setup_screen.dart:214 — name TextField's `onChanged: (_) => setState(() {})` rebuilds the entire screen on every keystroke — each keystroke re-runs the O(chars × castMembers) `unassigned` filter (`.where(... !castMembers.any(...))`) and the `unassigned.every(...)` scan, and re-lays-out every visible character card (each with two TextFields); typing gets progressively jankier as the cast grows to a full play (~20–40 characters × members). — smallest safe fix: track filled count in a `ValueNotifier<int>` (or a scoped Riverpod provider) and only rebuild the summary bar / Save button; drop the `setState` on `onChanged` since `unassigned` doesn't depend on controller text.
- [low] lib/features/cast_manager/cast_manager_screen.dart:193 — `linesByChar` full-script index (loop over every `script.lines` entry) is rebuilt on every `build()`, but it depends only on `script`, which is unchanged during the castMembers/recordings-triggered rebuilds this screen watches — a background recording/cast sync while the screen is open re-walks a multi-thousand-line script for no reason. — smallest safe fix: memoize it on `identityHashCode(script)` exactly like `_memoAssignment` already does for the voice assignment.
- [low] lib/features/cast_manager/cast_manager_screen.dart:378 — `itemBuilder` computes `recordedCount` with `charLines.where((l) => recordings.containsKey(l.id)).length`, a linear scan over that character's full line list on every build of every visible card — a lead role with ~1000 lines is re-scanned each rebuild (recording/cast syncs, scroll) even though `recordings` is an O(1) map. — smallest safe fix: precompute a `recordedByChar` count map once per build in `build()` (next to `linesByChar`) and look it up in the card.
- [low] lib/features/cast_manager/voice_config_screen.dart:110 — `VoiceConfigService.assignVoicesFromScript` (full-script adjacency walk + sort + greedy coloring) is recomputed on every `build()`; every preset tap and dialect toggle calls `setState`, re-running the whole O(lines) walk on a script that has not changed (cast_manager_screen already memoizes this same call). — smallest safe fix: memoize the assignment keyed on `(identityHashCode(script), _currentPreset, _genderOverrides)` as `_CastManagerScreenState` does.
## Coverage
lib/data/services/tts_service.dart — clean
lib/data/services/vision_ocr_channel.dart — clean
lib/data/services/voice_clone_service.dart — clean
lib/data/services/voice_config_service.dart — clean
lib/features/auth/auth_screen.dart — clean
lib/features/cast_manager/bulk_cast_setup_screen.dart — findings: 1
lib/features/cast_manager/cast_manager_screen.dart — findings: 2
lib/features/cast_manager/voice_config_screen.dart — findings: 1
lib/features/home/home_screen.dart — clean
- [medium] lib/features/recording_studio/recording_character_screen.dart:59 — `script.linesForCharacter(char.name)` is called inside `ListView.builder`'s `itemBuilder`, and `linesForCharacter` scans the *entire* `script.lines` list (`lines.where(...).toList()`) per character — full list build is O(characters × lines) and every newly-visible row during scroll re-scans the whole script — scrolling/rebuilding the character picker janks on a long script with many characters (e.g. 3000 lines × 30 chars ≈ 90k filter+contains per build) — precompute a `Map<String, List<ScriptLine>>` (character → lines) once per build/data change and do an O(1) lookup in `itemBuilder`.

- [medium] lib/features/recording_studio/recording_studio_screen.dart:613 — the 100 ms `Timer.periodic` drives `setState` on the screen-root State, so the *entire* studio screen rebuilds 10×/second for the whole recording, when only the elapsed-duration label changes — each 10 Hz rebuild re-runs `_myLines.where((l) => recordings.containsKey(l.id)).length` (O(myLines)), `script.characters.indexWhere` (O(characters)), and the `_buildContextLines` backward walk, on top of full widget-tree allocation, during the exact window the device is also encoding audio — scope the duration counter to a tiny leaf widget (e.g. `ValueNotifier<Duration>` + `ValueListenableBuilder`) instead of `setState` on the root.

- [medium] lib/features/recording_studio/recordings_browser_screen.dart:92 — `build()` rebuilds `linesById` (O(script.lines)), re-runs `recordedEntries.sort(...)` (O(n log n)), the stats folds, and the `_scanFileExistence` id-join string (O(n)) on every build; because play/stop toggles `_playingLineId` via `setState`, each tap re-sorts the whole recording list and re-allocates all derived maps/lists — toggling playback stutters on a large recording library (hundreds/thousands of takes) — memoize the sorted `recordedEntries`/stats keyed on (recordings, script, filter) and track `_playingLineId` separately so play state changes don't rebuild the list.

- [low] lib/features/recording_studio/recordings_browser_screen.dart:593 — `_resolveRecordingPath` performs synchronous `File(...).existsSync()` (two calls per recording) inside the per-recording existence-scan loop, which runs on the main isolate — opening the browser with many recordings fires N synchronous filesystem stats on the UI thread, janking the initial paint — use the async `File(...).exists()` and `await` inside the already-async scan loop.

- [low] lib/features/production_hub/production_hub_screen.dart:417 — the scene-list `itemBuilder` recomputes `script.linesInScene(scene)` (a `sublist` copy) then `.where(...).toList()` then another `.where(...).length` per visible row on every rebuild; mode/hide-lines/fast-mode/character/filter changes all rebuild the list — repeated O(scene-size) list allocation and rescanning per toggle, worse on scenes with hundreds of lines — precompute scene→dialogue-lines (and per-character counts) once per data change and reuse them in `itemBuilder`.

- [low] lib/features/rehearsal/rehearsal_history_screen.dart:21 — `RehearsalHistoryNotifier.add` does `state = [session, ...state]`, copying the entire history list on every add, and the list is never capped — per-completed-scene O(n) copy plus unbounded in-memory growth over a long session — cap the history to the last N sessions (and/or store newest-last and reverse only for display).

## Coverage
lib/features/join/join_production_screen.dart — clean
lib/features/onboarding/model_setup_screen.dart — clean
lib/features/production_hub/production_hub_screen.dart — findings: 1
lib/features/recording_studio/recording_character_screen.dart — findings: 1
lib/features/recording_studio/recording_studio_screen.dart — findings: 1
lib/features/recording_studio/recordings_browser_screen.dart — findings: 2
lib/features/recording_studio/voice_profile_screen.dart — clean
lib/features/rehearsal/rehearsal_history_screen.dart — findings: 1
- [medium] lib/features/rehearsal/rehearsal_screen.dart:995 — `cacheExtent: 10000` on the rehearsal line list forces ~70–145 offscreen rows to be built, laid out, and kept alive instead of the ~2–3 the default 250px cache would keep. Because the screen root watches `currentLineIndexProvider`, `rehearsalStateProvider`, `rehearsalFontSizeProvider`, `hideMyLinesProvider`, and `fastModeEnabledProvider`, every line advance / state transition / font-size change re-runs `itemBuilder` and re-lays-out all of those cached rows. Consequence: on a full-length script, each line transition pays the layout cost of ~100+ extra rows (the code comments themselves note "~145 offscreen list items cacheExtent: 10000 keeps alive"); on low-end devices this is visible per-line jank, plus ~100 live widget subtrees of resident memory for the whole rehearsal. Smallest safe fix: use a sane `cacheExtent` (viewport-scaled, default-ish) with `itemExtent`/`prototypeItem` for the near-uniform rows, and scroll to the current line by estimated offset (the fallback branch in `_scrollToCurrentLine` already does this) instead of relying on the `_currentLineKey` GlobalKey being materialized.
- [medium] lib/features/script_editor/character_manager_screen.dart:755 — `_rebuildScript` recomputes every scene's character list with a nested `for (final line in updatedLines)` inside `script.scenes.map(...)`, i.e. O(scenes × lines), and this runs on every rename / merge / delete action (each of which already did an O(lines) pass in `_applyRename`/`_applyDelete`). Consequence: renaming or merging a character on a large script does scenes×lines iterations (e.g. 40 scenes × 5000 lines ≈ 200k range-check iterations plus a set insert per in-range line), a UI hitch that grows quadratically with script size on a common edit path. Smallest safe fix: precompute a map from each line's `orderIndex` to its scene once, then do a single O(lines) pass to bucket characters per scene (or iterate `updatedLines` once and add each dialogue line's character to the scene whose `startLineIndex`/`endLineIndex` contain it).

## Coverage
lib/features/rehearsal/rehearsal_screen.dart — findings: 1
lib/features/script_editor/character_manager_screen.dart — findings: 1
lib/features/script_editor/cloud_sync_dialog.dart — clean
lib/features/script_editor/scene_editor_screen.dart — clean
# Performance findings — batch 11

- [medium] lib/features/script_editor/script_editor_screen.dart:115 — `build()` runs two full O(n) scans over `script.lines` on every rebuild: `_filteredLines(script)` (line 115) and `lowOcrCount = script.lines.where(...).length` (lines 117–119), plus a `charColors` map rebuild. Every `setState` in this screen (toggle stage directions, toggle reorder mode, select a character filter chip, tap a line to select it on tablet, toggle low-OCR filter) re-executes both scans and re-materializes the filtered list. For a script with thousands of lines this is thousands of iterations + a fresh list allocation per tap, causing measurable jank on large imported scripts — concrete consequence: the richer/longer the script (the more it matters for editing), the slower every tap becomes. — Smallest safe fix: memoize `filteredLines` and `lowOcrCount` keyed on `(script.lines, _selectedCharacter, _showDirections, _showLowConfidenceOnly)` (recompute only when those inputs change, e.g. a `didUpdateWidget`/notifier hook or cached fields invalidated on script change), or derive `lowOcrCount` once from the parsed-script data instead of re-scanning.

- [medium] lib/features/script_import/ocr_review_screen.dart:155 — the `_reviewLines` (155–157) and `_notScriptLines` (159–161) getters each do a full `.where(...).toList()` over the entire `widget.lines` list, and they are re-invoked multiple times per `build`: in `build()` (lines 300–301), via `_pendingReviewCount`/`_pendingNotScriptCount` (163–167, which themselves re-run `_reviewLines`/`_notScriptLines` then `.where().length`), and again in `_buildNotScriptSection` (`remaining = notScriptLines.where(...).toList()`). Each `setState` (Save, Remove, select line, toggle "Edit nearby lines", bulk remove) therefore performs ~5–6 full scans of the whole script plus several intermediate list materializations. A scan flagging 100–300 lines in a multi-thousand-line script means each tap does tens of thousands of predicate evaluations — concrete consequence: sluggish taps and dropped frames during the OCR cleanup flow, exactly when the user is tapping rapidly through corrections. — Smallest safe fix: memoize the two filtered lists (and pending counts) the same way `_orderedCache`/`_orderedIndexCache` are already memoized — recompute on the mutation points (`_markRemoved`, `_saveEdit`) instead of on every read, and compute both pending counts in a single pass over one filtered list.

- [low] lib/features/script_import/ocr_review_screen.dart:428 — `_buildListChildren` eagerly constructs every review card via `...reviewLines.map((l) => _buildReviewCard(l, twoPane: twoPane))` and hands the prebuilt `List<Widget>` to `ListView.builder` (`itemBuilder: (context, i) => children[i]`, lines 347/378). The builder therefore provides laziness only for layout/inflation, not construction — every `setState` still allocates the full Card/TextField/InkWell subtree for every flagged line (100–300 cards × ~15 widgets each), contradicting the intent stated in the in-code comment. — Concrete consequence: hundreds of widget allocations per tap during review, GC churn on mid-range devices. — Smallest safe fix: construct each card inside the `itemBuilder` callback (index-based) so only visible rows are built, or keep the prebuilt list only when it is cached/invalidated on data change.

- [medium] lib/features/script_import/pdf_page_view.dart:104 — `_renderPage` renders every page at 3× intrinsic resolution (`fullWidth: pdfPage.width * 3, fullHeight: pdfPage.height * 3`, lines 103–105), producing a ~17 MB+ RGBA texture for a letter/A4 scan, then `createImage()` (line 114) decodes it; each call also re-opens the PDF from disk via `PdfDocument.openFile` (line 88). There is no cache, so every page change — stepping pages, or tapping through lines that live on different pages in the tablet two-pane editor/OCR panes — re-opens the document and re-renders+re-decodes a full-res image. — Concrete consequence: multi-hundred-ms jank and large transient memory spikes (OOM/jetsam risk on low-RAM iOS devices) whenever the user flips between source pages. — Smallest safe fix: render at a viewport-scaled resolution (derive `cacheWidth`/render size from the `LayoutBuilder` constraints × devicePixelRatio instead of a fixed 3×), and cache the rendered `ui.Image` per page number in a bounded LRU so back/forward navigation reuses the decode.

- [low] lib/features/script_import/script_import_screen.dart:190 — `_buildPreview` runs three separate full `script.lines` scans on every preview rebuild: the dialogue-count stat badge (line 190) and the two `.where(...).length` passes in `_buildReviewBanner` (lines 367 and 370). These re-run on each `setState` in preview mode (e.g. every dialect `SegmentedButton` change, and the `_saving` toggles during accept). — Concrete consequence: for very large scripts each dialect tap re-scans the whole line list multiple times and rebuilds the character tiles; minor but real constant-factor waste on the import path. — Smallest safe fix: compute the three counts in a single pass over `script.lines` (or cache them alongside the preview) rather than three independent `.where(...).length` calls.

## Coverage
lib/features/script_editor/script_editor_screen.dart — findings: 1
lib/features/script_editor/validation_panel.dart — clean
lib/features/script_import/ocr_review_screen.dart — findings: 2
lib/features/script_import/pdf_page_view.dart — findings: 1
lib/features/script_import/script_import_screen.dart — findings: 1
lib/features/settings/ai_models_screen.dart — clean
lib/features/settings/debug_log_screen.dart — clean
lib/features/settings/kokoro_debug_screen.dart — clean
lib/features/settings/model_download_screen.dart — clean
lib/features/settings/settings_screen.dart — clean
lib/firebase_options.dart — clean
lib/main.dart — clean
# Performance findings — batch 12

- [medium] macos/Runner/BackgroundDownloadPlugin.swift:137 — `urlSession(_:downloadTask:didWriteData:...)` calls `channel.invokeMethod("onDownloadProgress", ...)` on every URLSession progress callback, and the session's `delegateQueue` is `.main`, so the whole callback runs on the main thread. URLSession fires `didWriteData` many times per second during a large transfer (the app downloads multi-hundred-MB ONNX models: sherpa, ORT), so a single download generates hundreds/thousands of main-thread platform-channel round-trips. Consequence: bridge traffic storm + main-thread churn → janky UI for the duration of a model download, scaling with download size. Smallest safe fix: throttle emission — only invoke the channel when progress advances by a meaningful delta (e.g. `>= 1%` or `>= 500ms` since last emit), keeping the last-seen totals to still report completion accurately.
- [low] macos/Runner/PdfTextPlugin.swift:135 — `hasEmbeddedText` opens `PDFDocument(url:)` and reads page text synchronously on the method-channel handler thread (main thread), unlike `extractText`/`extractTextPerPage` which wrap the same work in `DispatchQueue.global(qos: .userInitiated).async`. Consequence: synchronous disk I/O + PDF parse on the main thread → a brief UI stall for large PDFs (tens of ms+), scaling with PDF size. Smallest safe fix: move the body onto a background queue like the sibling methods and call `result` back on `DispatchQueue.main`.
- [low] macos/Runner/VisionOcrPlugin.swift:116 — `NSLog("VisionOCR: Page \(i+1)/\(pageCount) — \(blocks.count) lines")` runs once per page inside the OCR loop. `NSLog` is synchronous and comparatively expensive. Consequence: for a many-hundred-page PDF, hundreds of synchronous logging calls on the OCR worker queue add measurable overhead and energy cost on top of the already-heavy per-page Vision work. Smallest safe fix: drop the per-page log (or switch to `Logger`/`OSSignposter`, or log only at completion with a per-page count).
- [low] lib/providers/production_providers.dart:369 — `persistScriptLocally` runs `jsonEncode(jsonList)` of the full script (all lines to JSON) on the main/UI isolate, and the `_maxBackupBytes` (5 MB) cap is checked only *after* the complete encode; `loadPersistedScript` (line 698) similarly `jsonDecode`s the backup on the UI isolate. Consequence: synchronous multi-MB JSON encode/decode on the UI isolate during the debounced autosave and on script load — a sub-frame-to-frame hitch that grows with script size (a full play is thousands of lines). Smallest safe fix: offload the encode/decode to `Isolate.run`/`compute`, or cheaply guard with `script.lines.length` before encoding so oversized scripts skip the encode entirely.

## Coverage
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
macos/Runner/PdfTextPlugin.swift — findings: 1
macos/Runner/VisionOcrPlugin.swift — findings: 1
macos/RunnerTests/RunnerTests.swift — clean
pubspec.yaml — clean
scripts/compare_macbeth_versions.py — clean
scripts/deploy.sh — clean
scripts/fetch-ort-java.sh — clean
scripts/generate_rehearsal_webp.sh — clean
scripts/generate_screenshots.sh — clean
- [medium] scripts/parse_script.py:140 — `detect_character_cue` re-sorts `KNOWN_CHARACTERS` (`sorted(KNOWN_CHARACTERS, key=len, reverse=True)`) and builds + attempts up to 27 `re.match` calls per call, and it is invoked once per input line from the `while i < len(lines)` loop at :287 — for a full-length play (thousands of lines) that is ~27 regex match attempts plus a 27-element sort for every line (~130k+ regex attempts on a 5k-line script); the file's own docstring declares it the reference implementation for the Flutter app's on-device parser, so the same per-line recomputation is mirrored into device CPU/battery during script import — hoist `SORTED = sorted(KNOWN_CHARACTERS, key=len, reverse=True)` and a module-level list of precompiled `re.compile(re.escape(c) + r"\.\s+")` patterns, then iterate those in the loop instead of re-sorting and re-escaping per line
- [low] supabase/migrations/20260314120000_add_script_lines.sql:45 — `create index idx_script_lines_production on public.script_lines (production_id, order_index)` duplicates the btree index already created by the `unique (production_id, order_index)` table constraint (line 17) on the identical column pair — every INSERT/UPDATE/DELETE into `script_lines` now maintains two identical indexes (2× index-write amplification) and pays double index storage; `script_lines` is the largest table (one row per script line, bulk-imported and re-synced on every script edit), so the redundant index doubles index maintenance on the bulk-import path — drop `idx_script_lines_production`; the unique constraint's index already serves all (production_id, order_index) lookups and the unique lookups

## Coverage
scripts/generate_test_export.py — clean
scripts/parse_script.py — findings: 1
scripts/pdf_to_script.py — clean
scripts/phone-harness.sh — clean
scripts/pull-crashlog.sh — clean
scripts/pull-debuglog.sh — clean
scripts/ship-play.sh — clean
scripts/ship-testflight.sh — clean
scripts/verify-apk-ort.sh — clean
supabase/config.toml — clean
supabase/migrations/20260314061409_initial_schema.sql — clean
supabase/migrations/20260314120000_add_script_lines.sql — findings: 1
supabase/migrations/20260314130000_fix_cast_members_rls.sql — clean
supabase/migrations/20260314140000_fix_rls_recursion.sql — clean
supabase/migrations/20260315_cast_join_code.sql — clean
supabase/migrations/20260316_join_code_default.sql — clean
supabase/migrations/20260318_add_join_code_policy.sql — clean
supabase/migrations/20260319000001_join_flow_rpc_v2.sql — clean
supabase/migrations/20260319100000_add_voice_preset.sql — clean
supabase/migrations/20260319100001_add_locale.sql — clean
# Performance sweep — batch 14

Scope: SQL migrations (one-time/DDL + RLS policy definitions) and Dart CLI/audit tools plus the MLX Swift harness. Reviewed against performance-review, dart-performance-review, and mlx-performance-review. No external perf linters (ruff/staticcheck/eslint) applicable to SQL/Dart/Swift here; checklist greps and read-throughs were the method.

## Findings

- [low] tool/analyze_orphaned_recordings.dart:85 — `charOf` constructs `RegExp('/$productionId/([^/]+)/')` on every call, and is invoked once per recording in both the orphan loop (line 91) and the per-recording counts loop (line 102). The pattern is constant for the whole run (productionId is fixed), so this recompiles the identical regex ~2×recs times. — Redundant regex compilation and per-call allocation churn; negligible for a handful of recordings but grows linearly with a production's recording count. — Hoist the `RegExp` to a single `final` (built once after productionId is known) and pass it into `charOf`.
- [low] tool/orphan_sweep.dart:77 — `RegExp('/$pid/([^/]+)/')` is constructed inside the per-orphan loop; `$pid` is constant for the whole inner loop, so the same regex is recompiled once per orphaned recording per production. — Per-recording regex compilation across all productions swept; allocation churn that scales with total orphan count. — Build the `RegExp` once per production (immediately after `pid` is read, before the orphans loop) and reuse it.
- [low] tool/orphan_sweep.dart:37 — the sweep issues four sequential remote round-trips per production (cast_members INSERT to satisfy RLS at line ~40, script_lines SELECT at 57, recordings SELECT at 63, cast_members DELETE at ~85), all serialized in a single `for` loop over every production, which is itself fetched unpaginated (line ~30). — Sweep wall-clock time scales as ~4×P round-trips (P = production count); a few hundred productions means hundreds to thousands of awaited round-trips and minutes-to-tens-of-minutes runs for a manual audit. — Batch the membership inserts (multi-row INSERT) and fetch lines/recordings for joined productions in fewer, broader queries, or run productions under a bounded-concurrency pool instead of strictly sequential awaits. (Note: the per-production read is inherently RLS-gated; this is an offline audit tool, so impact is operator latency, not a service outage.)

## Coverage

supabase/migrations/20260320200000_add_debug_reports.sql — clean
supabase/migrations/20260701090000_add_multi_characters.sql — clean
supabase/migrations/20260703090000_leave_policy_and_audit_cleanup.sql — clean
supabase/migrations/20260703100000_purge_test_productions.sql — clean
supabase/migrations/20260703140000_security_lockdown.sql — clean
supabase/migrations/20260703150000_fix_helper_grants.sql — clean
supabase/migrations/20260703160000_drop_last_productions_readall.sql — clean
supabase/migrations/20260703170000_recordings_delete_policy.sql — clean
supabase/migrations/20260801130000_cast_members_rls_index.sql — clean
tool/analyze_orphaned_recordings.dart — findings: 1
tool/orphan_sweep.dart — findings: 2
tool/parse_stats.dart — clean
tool/sim_multi_user.dart — clean
tool/verify_cloud_recordings.dart — clean
tools/mlx-harness/link-sources.sh — clean
tools/mlx-harness/Package.swift — clean
tools/mlx-harness/Sources/harness/main.swift — clean
# Pi sweep performance — batch 15

## Notes
All 20 listed files are Flutter integration tests, unit tests, a test driver stub, and two one-off Swift dev scripts. None contain production hot paths. The only loop patterns present (WAV linear resampling, per-window RMS, word-level LCS) operate on bounded inputs (single audio clips, ~10–20 word sentences, ~100-page PDFs) with linear or amortized-linear complexity. No N+1 queries, unbounded caches, per-item remote I/O, missing pagination, or O(n²)-or-worse hot paths were found. Swift `fullText += text + "\n"` uses amortized geometric buffer growth and is not a quadratic accumulation. No findings.

## Coverage
dart_test.yaml — clean
integration_test/android_kokoro_rtf_test.dart — clean
integration_test/android_kokoro_service_test.dart — clean
integration_test/android_live_matching_test.dart — clean
integration_test/android_paddle_ocr_test.dart — clean
integration_test/android_rehearsal_harness_test.dart — clean
integration_test/asr_streaming_macos_test.dart — clean
integration_test/asr_testwav_transcript_macos_test.dart — clean
integration_test/kokoro_pack_smoke_macos_test.dart — clean
integration_test/kokoro_service_queue_macos_test.dart — clean
integration_test/ocr_dump_macos_test.dart — clean
integration_test/ocr_import_macos_test.dart — clean
integration_test/rehearsal_demo_test.dart — clean
integration_test/screenshot_test.dart — clean
integration_test/tts_kokoro_compare_macos_test.dart — clean
scripts/test_pdf_import.swift — clean
scripts/test_silence_trim.swift — clean
test_driver/integration_test.dart — clean
test/analytics_route_observer_test.dart — clean
test/cast_member_test.dart — clean
# Batch 16 — Performance findings

All 20 files in this batch are Flutter/Dart test files (`test/**`). None sit on a production hot path: they construct small bounded fixtures (a handful of `ScriptLine`s, one-line dictionaries, 60–600 generated lines into a `StringBuffer`), exercise model `copyWith`/computed properties, and use in-memory Drift DBs closed in `tearDown`. No file exhibits a performance defect that meets the defensibility bar.

Dismissed candidates (false positives, per the skill's own rules):
- `parser_accuracy_test.dart` `readAsStringSync()` / per-file `parse()` in the extended-tag "Generate parser accuracy report" test — one-shot CLI-like report generator over a bounded `sample-scripts/` directory; skipped during normal `flutter test`; not a hot path ("sync I/O in CLI/startup", "queries/parse in one-off scripts or test setup").
- `pp_ocr_attribution_test.dart` `lineContaining()` linear scan over ~1100 parsed lines, called a few times per test — bounded test fixture, no growing input.
- `recording_sync_service_test.dart` `FakeCloud.fetchRecordings`/`saveRecordingMetadata` O(n) `where`/`removeWhere` — in-memory test double over a handful of rows.
- `pdf_import_test.dart` / `ocr_cleanup_test.dart` loops use `StringBuffer.writeln` (correct pattern, no `+=` string accumulation).
- `production_repository_test.dart` in-memory Drift DB per test, closed in `tearDown` — correct lifecycle.

## Coverage
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
test/pp_ocr_attribution_test.dart — clean
test/production_repository_test.dart — clean
test/recording_path_safety_test.dart — clean
test/recording_sync_service_test.dart — clean
test/rehearsal_models_test.dart — clean
test/running_header_test.dart — clean
# Pi sweep — performance — batch 17

## Summary
Reviewed all 18 `test/*.dart` files for performance only. These are unit/widget tests exercising the script parser, STT/TTS services, sync queue, and models. No performance findings: every loop iterates over bounded data (small literal scripts, fixed fixtures, capped synthetic inputs ≤ 500 lines, or in-memory fakes), none of these files sit on a production request/rendering hot path, and there is no N+1, quadratic-over-unbounded-data, allocation churn, or unbounded-growth pattern. The `sharing_test.dart` `diffScriptLines` 500-line case is a benchmark-style test that itself asserts sub-second completion, not a hot path.

## Findings

_None._

## Coverage
test/sample_script_test.dart — clean
test/scene_partition_test.dart — clean
test/scene_remap_test.dart — clean
test/script_parser_import_test.dart — clean
test/shakespeare_import_test.dart — clean
test/sharing_test.dart — clean
test/stt_adaptation_test.dart — clean
test/stt_service_test.dart — clean
test/stt_vocabulary_service_test.dart — clean
test/supabase_join_test.dart — clean
test/supabase_service_test.dart — clean
test/sync_queue_test.dart — clean
test/toast_autodismiss_test.dart — clean
test/tts_service_test.dart — clean
test/tts_text_chunking_test.dart — clean
test/voice_clone_test.dart — clean
test/voice_config_test.dart — clean
test/widget_test.dart — clean
- [low] lib/data/services/supabase_service.dart:721 — `saveScriptLines` fires one HTTP round trip per 100-line batch and awaits each sequentially (`for (var i = 0; i < lines.length; i += 100) … await …insert(batch)`), so pushing a large script is a serial chain of round trips — a 4000-line play (~40 batches) costs ~40 × network RTT (several seconds) on the save path, and the delete-then-reinsert already makes it non-incremental — issue batches with bounded concurrency (e.g. `Future.wait` over chunks of 3–5) or fold into a single RPC, keeping the 100-row batch size as the floor.
- [low] lib/data/services/supabase_service.dart:653 — `fetchRecordings` selects the entire `recordings` table for a production with no LIMIT and no `recorded_at > since` watermark, and `RecordingSyncService.syncForProduction` calls it on every production open — as takes accumulate (rows ≈ lines × cast members; a 2000-line play × 10 cast ≈ 20k rows), each sync re-transfers and JSON-decodes a growing multi-MB payload on the UI isolate — add an incremental `recorded_at` watermark filter (or a server-side newest-per-line aggregation) so only rows newer than the last sync are fetched.

## Coverage
lib/data/services/tts_service.dart — clean
lib/features/home/home_screen.dart — clean
lib/data/services/supabase_service.dart — findings: 2
lib/data/services/model_download_service.dart — clean
- [low] ios/Runner/AppleSttPlugin.swift:274 — `AVAudioFile.write(from: buffer)` runs inside the `AVAudioNodeTapBlock` for the mic input, which is invoked on the realtime audio render thread — when concurrent recording is active, every ~4096-frame buffer does synchronous file I/O on the render thread; a disk-latency spike stalls the render callback and drops buffers, glitching both the recorded audio and the STT feed (the tap also appends to `recognitionRequest` and computes mic level on the same thread) — offload writes to a background queue (enqueue buffers from the tap, drain/write off the render thread) so the render callback never touches disk.

- [low] ios/Runner/MisakiVendored/English/Lexicon/Lexicon.swift:246,409,496 — `String.range(of:options:.regularExpression)` compiles a fresh `NSRegularExpression` on every call, and these three sites sit on the per-token phonemization hot path (`getSpecialCase` runs for every preposition, `stem_ing` for every word ending in "ing", `getNumber` for numeric words), so each transcribed word pays pattern-compile cost during TTS — latency scales with the number of words synthesized — hoist the three patterns to `static let` compiled `NSRegularExpression` instances (EnglishG2P.swift already does this for `subtokenizeRegex`/`linkRegex`) and reuse them.

- [low] lib/features/join/join_production_screen.dart:232 — the name `TextField`'s `onChanged` fires a bare `setState(() {})` on the screen-root State, rebuilding the entire scaffold (Card, TextFields, and `_buildCharacterOptions()`, which re-walks `_castMembers` and constructs a `RadioListTile` per unclaimed character) on every keystroke — with a large cast, each keystroke re-constructs the whole character list for a rebuild that only needs to enable/disable the Join button — scope the rebuild to a `ValueListenableBuilder` on the name controller (or derive the button's enabled state from `_nameController.text` without a full-screen `setState`).
## Coverage
ios/Runner/AppleSttPlugin.swift — findings: 1
ios/Runner/MisakiVendored/English/Lexicon/Lexicon.swift — findings: 1
lib/features/join/join_production_screen.dart — findings: 1
lib/features/script_editor/scene_editor_screen.dart — clean
# Perf review — batch 20

Scope: 4 files (Flutter auth screen, iOS Kokoro MLX TTS service, Dart sync queue, Dart STT service). Lenses applied: performance-review, flutter-performance-review (auth_screen), dart-performance-review (sync_queue, stt_service), ios-performance-review + mlx-performance-review (KokoroMLXService). No linters available in this environment (offline, no installs allowed); relied on checklist reads.

## Findings

- [low] lib/data/services/sync_queue.dart:374 — `_processQueue` drains `_pending` in a `while` loop and `await`s `_uploader.upload(job)` then `_uploader.saveMetadata(job, url)` serially for each job — jobs are independent (distinct `lineId`), so a backlog of N offline recordings (e.g. "20 lines on the train") uploads one round-trip at a time; total sync latency is the SUM of per-upload network time instead of the max — upload with a small bounded pool (e.g. 3–4 in flight via a semaphore or chunked `Future.wait`), keeping the existing `_processing` guard as the pool's gate.

## Coverage
lib/features/auth/auth_screen.dart — clean
ios/Runner/KokoroMLXService.swift — clean
lib/data/services/sync_queue.dart — findings: 1
lib/data/services/stt_service.dart — clean
- [low] ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:270 — redundant device sync in prepareInputTensors: `let inputLengthMax: Int = inputLengths.max().item()` dispatches a reduction + forced host extraction to recover the sequence length, but that value is already known on the host as `paddedInputIds.dim(-1)` (equivalently `paddedInputIdsArray.count`); the tensor `inputLengths` is still needed downstream, but the scalar is not. Consequence: a pointless device round-trip on every `generateAudio` call (the TTS hot path) — the same class of sync this file already eliminated from `createAlignmentTarget`. Fix: `let inputLengthMax = paddedInputIdsArray.count` and keep the `inputLengths` tensor only for the downstream `durationEncoder` call.
- [low] ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:308-324 — createAlignmentTarget allocates a dense `[Float](repeating: 0.0, count: totalFrames * batchSize)` host array where `batchSize = paddedInputIds.shape[1]` (sequence length, not 1), so the alignment buffer is O(seqLen × totalFrames) ≈ O(seqLen² × avg_duration) and is then copied back onto the device via `MLXArray(alignmentArray).reshaped(...)`. Consequence: for long inputs (up to Constants.maxTokenCount = 510 tokens) the alignment matrix is multi-megabyte CPU allocation + device copy per synthesis, on the TTS hot path. This is bounded by maxTokenCount and largely inherent to the dense alignment matmul, so it is low, but the device-side copy can be avoided by constructing the one-hot indices and using MLX scatter/integer indexing (or `MLX.put_along_axis`) instead of materializing a full Float buffer on the host.
- [low] ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:281 — `extractStyleEmbeddings` indexes `voice[tokenCount - 1, 0 ... 1, 0...]` and `referenceStyle[0 ... 1, 128...]`/`[0 ... 1, 0 ... 127]` with per-call fancy slices on the embedding tensor; these are one-time per synthesis (not in a loop) and bounded by the fixed embedding width, so only a small constant overhead — no growth axis. Not escalated; noted only for completeness.

## Coverage
tool/sim_multi_user.dart — clean
supabase/config.toml — clean
ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift — findings: 3
lib/features/settings/settings_screen.dart — clean
- [low] scripts/pdf_to_script.py:146 — `_extract_folger` extracts every page's structured text via `page.get_text("dict")` up to three times over the same document: once in `_detect_characters_from_pdf` (line 129, full doc), once in the ACT-1 start-page search (line 157, full doc until found, plus a plain `page.get_text()` at line 168 on candidates), and once more in the extraction loop (line 181). — For a Folger play of a few hundred pages, `get_text("dict")` (layout + span extraction) is the dominant cost, so the conversion runs ~2-3x slower than necessary; the redundant passes are pure recomputation. — Do a single pass over pages (detect characters, record the ACT-1 start page, and emit lines in one loop), or memoize each page's `get_text("dict")` result in a dict keyed by page index.

## Coverage
scripts/pdf_to_script.py — findings: 1
lib/data/services/voice_config_service.dart — clean
lib/features/settings/ai_models_screen.dart — clean
lib/features/settings/debug_log_screen.dart — clean
- [low] lib/data/services/model_manager.dart:327 — download progress callback fires once per network chunk with no throttle — `await for (final chunk in response)` invokes `onProgress?.call(bytesReceived / contentLength)` for every ~8–64 KB socket read, and the caller (`ModelSetupScreen._downloadAll`'s `onProgress:`) turns each into a `setState` that rebuilds the whole setup screen; a ~180 MB archive yields ~3,000–20,000 redundant rebuilds spread across the download, wasting main-thread time and battery for a progress bar that only needs ~1% granularity — throttle like the sibling `model_download_service.dart` already does (`received - lastNotified > 1024 * 1024`), or only emit when the integer-percent changes.

## Coverage
lib/features/onboarding/model_setup_screen.dart — clean
lib/features/settings/kokoro_debug_screen.dart — clean
lib/data/services/model_manager.dart — findings: 1
lib/data/database/app_database.dart — clean

## Run stats

input 1056176 tok (+8900992 cached), output 275130 tok, cost $0.73 — 298 files in 20m (891.0 files/h, 0.9 min/batch)
