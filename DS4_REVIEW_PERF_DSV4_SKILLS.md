# DS4 sweep review (perf focus) — CastCircle

Exhaustive per-file pass: 280 code files across 10 batches.

## Findings

# Performance findings — batch 1

- [high] ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetModel.swift:266 — per-frame host `.item()` syncs inside the TDT decode loop (`let token = tokenLogits.argMax(axis: -1).item(Int.self)` then `let decision = durationLogits.argMax(axis: -1).item(Int.self)`, both inside `while t < maxLength`) — each frame forces a full GPU→CPU pipeline stall (argmax must be evaluated and copied to host) just to make the host-side `tdtStep` decision; at ~100 frames/sec and up to 8192 frames that is 2 blocking syncs per frame, so decode is latency-bound on host round-trips instead of GPU throughput — keep argmax on-device and read the (token, decision) pair once per step via a bulk `asArray`/`asInt32` at the loop boundary, or evaluate both logits in one eval and extract together.
- [high] ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetModel.swift:348 — per-frame host `.item()` sync in the RNNT decode loop (`let token = jointOut.argMax(axis: -1).item(Int.self)` inside `while t < maxLength`) — same one-blocking-sync-per-frame pattern as decodeTDT, stalling the streaming STT decode path frame-by-frame — keep argmax on-device and extract the token once per step.
- [medium] ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetModel.swift:409 — per-element `.item()` inside a loop over all frames (`let ids: [Int] = (0..<featLen).map { bestTokens[$0].item(Int.self) }`) — one host sync per frame of the utterance (featLen can be thousands of frames), each a full pipeline stall plus an element-by-element MLXArray subscript graph op; `eval(bestTokens)` once then bulk-extract `bestTokens.asArray(Int32.self)` into a native array and map over that.
- [medium] ios/Runner/PdfTextPlugin.swift:80 — O(n²) string accumulation across PDF pages (`fullText += pageText` and `fullText += "\n"` inside the `for i in 0..<pageCount` loop) — every page copies the entire accumulated string; a hundreds-of-pages Folger-style PDF makes extraction quadratic in total text size, adding measurable latency on the OCR-fallback path — accumulate `[String]` and call `joined(separator: "\n")` once.
- [medium] ios/Runner/BackgroundDownloadPlugin.swift:190 — a Flutter platform-channel bridge call (`channel.invokeMethod("onDownloadProgress", arguments: [...])`) inside `didWriteData`, which URLSession invokes on every network write chunk (the delegate queue is `.main`) — a multi-GB model download at high throughput fires this many times per second, each a main-thread bridge crossing plus dict allocation, flooding the Dart bridge during the download — throttle progress to ~4-10 Hz (only emit when `totalBytesWritten - lastReported >= threshold` or on a time gate).
- [medium] ios/Runner/AppleSttPlugin.swift:553 — scalar per-sample RMS loop in the audio-tap callback (`for i in 0..<frames { sum += samples[i] * samples[i] }`) — the tap block runs ~12×/sec on the audio render thread over 4096-frame buffers, a scalar accumulation that defeats SIMD where one fused `vDSP_rmsqv` call does the whole buffer — replace the loop with `vDSP_rmsqv` (single Accelerate pass per buffer).
- [low] ios/Runner/AppleSttPlugin.swift:282 — per-tap main-thread platform-channel call (`DispatchQueue.main.async { self?.channel.invokeMethod("onLevel", arguments: level) }`) fired at the ~12 Hz tap cadence — ~12 main-thread bridge crossings/sec plus a main-queue hop per buffer, each carrying a single scalar that Dart's endpointing only needs a few times/sec — batch/downsample `onLevel` to a lower cadence or fold it into an existing batched event.
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:386 — two Flutter platform-channel calls (`channel.invokeMethod("onLevel", level)` and `channel.invokeMethod("onPcm", bytes)`) posted to the main handler inside `captureLoop`, once per 100 ms chunk (~10 Hz) — ~20 main-thread bridge crossings/sec during rehearsal capture; `onLevel` at that cadence exceeds what the Dart endpointing needs — combine `onLevel` into the `onPcm` payload (one crossing) or throttle `onLevel` to a lower rate.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:380 — fresh `ByteArray(n * 2)` allocated per 100 ms capture chunk in `captureLoop` (1600 samples ≈ 3200 bytes at ~10 Hz) — bounded-size allocation on a fixed low cadence but trivially hoistable to a field, causing steady GC churn during a long rehearsal take — reuse one preallocated buffer sized to `CHUNK_SAMPLES * 2`.
- [low] android/app/build.gradle.kts:4 — no `baselineprofile` plugin configured for the shipping Android app (release builds use default R8 only) — first runs pay JIT/interpreted startup on a ML/OCR-heavy app; Android Performance checklist expects a Baseline Profile over startup + key journeys — add the `com.android.experimental.baseline.profile` plugin and regenerate per release.

## Coverage
- analysis_options.yaml — clean
- android/app/build.gradle.kts — findings: 1
- android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt — findings: 2
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
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetModel.swift — findings: 3
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetRNNTLayers.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/ParakeetTokenizer.swift — clean
- ios/LocalPackages/parakeet-stt/Sources/ParakeetSTT/STTOutput.swift — clean
- ios/Runner/AppDelegate.swift — clean
- ios/Runner/AppleSttPlugin.swift — findings: 2
- ios/Runner/AudioAnalysisPlugin.swift — clean
- ios/Runner/BackgroundDownloadPlugin.swift — findings: 1
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
# Performance findings — batch 2

- [high] ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:356 — per-phoneme and per-frame host `.item()` syncs in `createAlignmentTarget` (`let frameCount: Int = duration.item()` inside `durations.enumerated().map`, and `let phonemeIndex: Int = indices[frame].item()` inside `for frame in 0 ..< totalFrames`) — each phoneme and each expanded frame forces a full GPU→CPU pipeline stall to build the one-hot alignment matrix; with up to 510 tokens each expanded to `maxDur` frames this is hundreds of blocking syncs per synthesis, so the duration-alignment step is host round-trip bound — evaluate `durations` and `indices` once before the loop (`eval` + `asArray(Int32.self)`) and build the matrix over native arrays.
- [medium] ios/Runner/KokoroVendored/TTSEngine/TimestampPredictor.swift:57 — per-token host `.item()` syncs inside the timestamp loop (`let tokenDuration: Float = predictionDuration[i..<j].sum().item()`, plus `predictionDuration[i].item()` at lines 44/45/58) — one blocking GPU→CPU eval per token (up to ~510 tokens per synthesis) just to accumulate timestamps; the loop is host-side arithmetic on an already-on-device tensor — bulk-extract `predictionDuration.asArray(Float.self)` once and operate on the native array.
- [high] ios/Runner/MisakiVendored/English/FallbackNetwork/BARTModel.swift:134 — three compounding decode defects in `generate` over `maxLength` (50 tokens per unknown word, called per OOV word during phonemization): no KV-cache (`decode` re-encodes the full decoder over all prior positions every step → O(t²) attention recompute), per-step `decoderInput = concatenated([decoderInput, newToken], axis: 1)` (line 145 → O(t) copy per step, O(t²) per sequence), and per-step `scaledLogits.argMax().item(Int32.self)` (line 134 → one blocking GPU→CPU sync per token) — the fallback G2P decode is latency-bound on host round-trips and quadratic in sequence length — thread per-layer key/value caches, append into a preallocated buffer with in-place slice assignment, and keep argmax on-device.
- [medium] ios/Runner/MisakiVendored/English/EnglishG2P.swift:439 — O(n²) scan/copy in the per-word transcribe loop (`let hasFixed = arr[left..<right].contains { $0._.alias != nil || $0.phonemes != nil }` and `mergeTokens(Array(arr[left..<right]))` inside `while left < right`) — each while iteration rescans and re-slices the shrinking sub-token array, so a word with many subtokens (long digit/camelCase strings) does O(subtokens²) work plus a fresh array copy per iteration, and this runs per word per synthesis — track whether a fixed token exists with a running flag and pass the slice once (or accumulate the merged result incrementally).
- [medium] ios/Runner/MisakiVendored/English/EnglishG2P.swift:141 — regex compiled per phonemize call (`let linkRegex = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^\)]*)\)"#, options: [])` inside `preprocess`, which `phonemize` invokes for every synthesis) — pattern compilation cost paid per text-to-speech request even though the pattern never changes; `subtokenizeRegex` is correctly a static let, but this one is rebuilt each call — hoist `linkRegex` to a static.
- [medium] ios/Runner/KokoroVendored/BuildingBlocks/ConvWeighted.swift:100 — weight-normalization recomputed on every forward pass (`let weight = weightNorm(weightV: weightV, weightG: weightG, dim: 0)` in each `callAsFunction` overload) — `weightNorm` does `sqrt(sum(x*x))` over the whole kernel plus a division on every conv layer invocation, once per decode frame; the weight is loop-invariant so this is redundant per-frame compute across ~20 conv layers in the decoder — precompute `weightNorm` once at init and reuse the cached array.
- [medium] ios/Runner/KokoroVendored/BuildingBlocks/AdaINResBlock1.swift:89 — per-layer transpose-pair churn (`xt = MLX.swappedAxes(xt, 2, 1)` … `MLX.swappedAxes(xt, 2, 1)` before and after each of the 3 convs, repeated for both conv1/conv2 in the 3-layer loop) — each swap is a separate layout op in the lazy graph, ~12 transposes per residual block invoked every decode frame and again inside the generator's noise resblocks — pick one layout (conv weights stored in the conv's native orientation) and drop the per-layer swap pairs.
- [medium] ios/Runner/KokoroVendored/TTSEngine/TextEncoder.swift:131 — mask re-applied after every CNN layer (`x = MLX.where(mask, 0.0, x)` inside the `for convBlock in cnn` loop, one `where` per layer over `depth` layers) — the mask is constant, so each layer re-materializes a zeros branch and a masked copy on the text-encode hot path per synthesis — apply the mask once before the CNN stack and once after the LSTM.
- [medium] ios/Runner/KokoroVendored/TTSEngine/DurationEncoder.swift:109 — mask re-applied and a fresh zeros pad allocated per alternating layer (`x = MLX.where(m.expandedDimensions(...), MLXArray.zeros(like: x), x)` after every AdaLN, and `let xPad = MLXArray.zeros([...])` + copy for every LSTM) — allocation and masking churn scaled by layer count × seq_len on the duration-prediction hot path per synthesis — allocate/zero once and re-mask once at the boundary rather than per layer.
- [medium] ios/Runner/KokoroVendored/BuildingBlocks/LSTM.swift:151 — O(seqLen²) insert-at-front accumulation in `backwardDirection` (`allCell.insert(currentCell, at: 0)` and `allHidden.insert(currentHidden, at: 0)` per step) — each insert shifts every previously-collected element, quadratic in sequence length (up to ~510 phoneme frames) for the bidirectional LSTMs used in duration/prosody/text encoding per synthesis — collect in a reversed-index loop (append then reverse, or stride the index down and build with `stacked` in order).
- [low] ios/Runner/KokoroVendored/Decoder/MLXSTFT.swift:61 — Hanning window recomputed per STFT/iSTFT call (`w = hanning(length: winLen + 1)` in both `mlxStft` and `mlxIstft`, invoked on every decoder transform/inverse per synthesis) — a `cos`-based array construction repeated per transform instead of built once; constant-factor waste on the hottest decoder stage — cache the window array on `MLXSTFT` at init.
- [low] ios/Runner/KokoroVendored/TextProcessing/Tokenizer.swift:20 — per-character String allocation + dictionary lookup (`text.map { vocab[String($0)] }`) — one `String` per character plus a `[String:Int]` probe, on text length per synthesis; measurable for long phoneme strings — map grapheme `Character`s directly (single `Character` keyed lookup) or iterate once with an index cursor instead of `.map`.
- [low] ios/Runner/MLXSttPlugin.swift:208 — O(n²) string accumulation in streaming transcription (`fullText += token` for every emitted token) and a per-token main-queue bridge event (`DispatchQueue.main.async { self?.eventSink?(["type": "partial", "text": fullText]) }`) — a long utterance's transcript grows by copying the whole accumulated string per token, and each token also hops the bridge; STT transcripts are short but this is a quadratic tail on long takes — append to `[String]` and join at final/result, or throttle partial events.
- [medium] ios/Runner/PdfTextPlugin.swift:80 — O(n²) string accumulation across PDF pages (`fullText += pageText` and `fullText += "\n"` inside `for i in 0..<pageCount`) — every page copies the entire accumulated text; a hundreds-of-pages Folger-style PDF makes extraction quadratic in total text size on the OCR-fallback path — accumulate `[String]` and `joined(separator: "\n")` once.
- [low] lib/data/models/script_models.dart:366 — `ParsedScript.acts` getter rescans all lines on every access (`lines.where((l) => l.act.isNotEmpty && seen.add(l.act))`) — each UI access of `.acts` walks the whole line list (thousands of lines) and rebuilds the array; if a screen queries it repeatedly the cost scales with lines × accesses — compute once and cache, or precompute at parse time.
- [low] lib/data/repositories/production_repository.dart:44 — per-recording `file.exists()` + `file.delete()` syscalls inside `deleteProduction` (`for (final recording in recordings)` … `await file.exists()` then `await file.delete()`) — a production with hundreds/thousands of recorded lines issues a stat syscall per file then a delete per file, serialized; one-off cleanup but O(recordings) syscalls — open-then-delete directly (handle error) or batch the deletes.
- [low] lib/data/services/audio_level_service.dart:30 — unbounded gain cache with no eviction (`final Map<String, double> _gainCache = {}`; only `invalidate`/`clear` on explicit calls) — each distinct recording file path accumulates an entry and there is no cap/TTL, so long recording sessions with re-recordings grow memory monotonically — cap with an LRU (or `clear()` on production change, which is already wired for the recording notifier).
- [medium] lib/data/services/debug_log_service.dart:184 — synchronous fsync'd disk write per log entry (`File(path).writeAsStringSync('${entry.toLine()}\n', mode: FileMode.append, flush: true)` called from `log()`), which runs on whatever thread calls `log` — during rehearsal STT/TTS/line events call `log` on the UI thread, and `flush: true` forces an fsync per entry (ms each), adding latency/energy to every logged event — drop `flush: true` (let the OS buffer) and rely on the existing 30 s periodic flush, or move appends to a background queue.
- [low] lib/data/database/app_database.dart:298 — connection setup sets no WAL/synchronous pragmas (`NativeDatabase.createInBackground(file)` with no `journal_mode`/`synchronous`/`busy_timeout` block) — default journaling makes every recording/script insert fsync the DB, and readers block writers on the mobile hot path; with per-line recording writes during rehearsal this adds commit cost per write — set `journal_mode=WAL; synchronous=NORMAL; busy_timeout=3000` in the open callback (or Drift `NativeDatabase.setup`).
- [low] ios/Runner/KokoroVendored/BuildingBlocks/ConvWeighted.swift:101 — stored `bias` reshaped on every call (`bias = bias?.reshaped([1, 1, -1])` mutates the property each forward pass) — a fresh reshape allocation per conv layer per frame — reshape once at init and keep the constant bias.
- [low] ios/Runner/MisakiVendored/English/Lexicon.swift:172 — stem functions evaluated twice per unknown word (`[stem_s, stem_ed, stem_ing].contains(where: { fn in fn(wl, tag, stress, ctx).0 != nil })` runs each stemmer (each does dictionary lookups + `applyStress`) purely to test, then they are re-run at lines 184-191) — ~2× redundant lookup work per OOV word on the per-word transcribe hot path — capture the results once and reuse them.

## Coverage
- ios/Runner/KokoroVendored/BuildingBlocks/AdaIN1d.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/AdainResBlk1d.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/AdaINResBlock1.swift — findings: 1
- ios/Runner/KokoroVendored/BuildingBlocks/AdaLayerNorm.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/Conv1dInference.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/ConvWeighted.swift — findings: 2
- ios/Runner/KokoroVendored/BuildingBlocks/InstanceNorm1d.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/Interpolate.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/LayerNormInference.swift — clean
- ios/Runner/KokoroVendored/BuildingBlocks/LSTM.swift — findings: 1
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
- ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift — findings: 1
- ios/Runner/KokoroVendored/TTSEngine/ProsodyPredictor.swift — clean
- ios/Runner/KokoroVendored/TTSEngine/TextEncoder.swift — findings: 1
- ios/Runner/KokoroVendored/TTSEngine/TimestampPredictor.swift — findings: 1
- ios/Runner/KokoroVendored/TTSEngine/WeightLoader.swift — clean
- ios/Runner/KokoroVendored/Utils/AudioUtils.swift — clean
- ios/Runner/MediaControlPlugin.swift — clean
- ios/Runner/MemoryMonitorPlugin.swift — clean
- ios/Runner/MisakiVendored/English/DataStructures/TokenContext.swift — clean
- ios/Runner/MisakiVendored/English/EnglishG2P.swift — findings: 2
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
- ios/Runner/MisakiVendored/English/Num2Word/EnglishNum2Word.swift — clean
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
- lib/data/database/app_database.dart — findings: 1
- lib/data/models/cast_member_model.dart — clean
- lib/data/models/production_models.dart — clean
- lib/data/models/rehearsal_models.dart — clean
- lib/data/models/script_models.dart — findings: 1
- lib/data/models/voice_preset.dart — clean
- lib/data/repositories/production_repository.dart — findings: 1
- lib/data/services/analytics_service.dart — clean
- lib/data/services/audio_level_service.dart — findings: 1
- lib/data/services/contact_picker_service.dart — clean
- lib/data/services/debug_log_service.dart — findings: 1
# Batch 3 — Performance findings (lib/data/services)

- [medium] lib/data/services/ocr_confidence_service.dart:182 — `_wordValidCache` is an unbounded per-word memo (`final _wordValidCache = <String, bool>{}`) keyed only on the word string, populated via `putIfAbsent` in `_isValidWord` (lines 184-195), and never cleared: `dispose()` (lines 100-108) resets `_checker`, `_whitelist`, `_theatricalVocab` and `_vocabLoadAttempted` but not `_wordValidCache`. The underlying validity inputs (`_whitelist`) are rebuilt per script by `_buildWhitelist` (called from `scoreScript` line 247), so the cache goes stale across imports AND grows monotonically with every distinct word ever scored. — Consequence: memory grows across every script import with no eviction (a 251K-word dictionary plus all prior scripts' words), and a word that was valid only because it appeared 3+ times in a previous script's whitelist is still returned `true` in the next script, inflating `dictNew` and mis-classifying OCR'd lines (wrong `review`/`ok` verdicts). — Smallest safe fix: clear `_wordValidCache` in `dispose()` (or key it on the whitelist generation / rebuild it inside `scoreScript`) so it is invalidated when the whitelist changes.

- [medium] lib/data/services/script_import_service.dart:183 — `_scoreConfidence` runs the dictionary spell-check scoring (`scorer.scoreScript(...)`, line 183) synchronously on the caller's isolate, which is the UI isolate (`script_import_screen.dart:607` awaits `service.importFromPdf`), while the parse + OCR-confidence mapping is deliberately offloaded via `Isolate.run` (lines 507-508) because "for a big scanned play this is seconds of pure-Dart string work, and doing it on the UI isolate froze the import spinner". `scoreScript` does the same class of CPU work — `_buildWhitelist` tokenizes every line (lines 135-145) and `_isValidWord` runs a ~251K-word dictionary lookup per distinct word (lines 184-195) — but was not moved off the UI isolate. — Consequence: for a long scanned play with tens of thousands of distinct words, the UI isolate freezes for the duration of the scoring right after the OCR finishes, the exact freeze the codebase already worked around for the parse path. — Smallest safe fix: run `scoreScript` inside the existing `Isolate.run`/`compute` (pass the whitelist/vocab as plain data, return scored lines), matching the parse+map offload.

- [medium] lib/data/services/recording_sync_service.dart:176-187 — `_saveManifest()` re-encodes the entire cache (`jsonEncode(_cache.values.map((c) => c.toJson()).toList())`) and rewrites the whole manifest file, and `handleRealtimeRecording` calls `_saveManifest()` (line 633) after every realtime recording download; `_cache` is global across all productions and grows unboundedly (only cleared by user `clearCache`/`clearAllCaches`). — Consequence: each new castmate recording arrival serializes and rewrites the whole index — O(N) work per event where N = all cached recordings across every production — a growing write cost on the realtime hot path (hundreds of cached entries → full JSON encode + file write per event). — Smallest safe fix: debounce/coalesce manifest writes (e.g. throttle to once per several events) or store entries incrementally/appends.

- [low] lib/data/services/recording_sync_service.dart:541-544 — `getCachedRecordings` performs a `File(cached.localPath).existsSync()` stat per cache entry inside the loop (`if (File(cached.localPath).existsSync())`), and is called on production open (production_providers.dart:451) and after each sync (line 466). — Consequence: O(N) filesystem stats per call (N = cached recordings for that production, hundreds for a full production) on the UI path, and during a sync the map is rebuilt once per sync so the stat cost scales with the cache size. The code itself acknowledges the cost at line 513 ("during a big sync the full-map version stats every cache entry per downloaded file"). — Smallest safe fix: stat the production cache dir once (or skip the per-entry stat — files are only ever removed via `clearCache`, so existence can be tracked), or batch existence checks.

- [low] lib/data/services/script_import_service.dart:618-665 — `_estimateLineConfidence` compiles ~8 `RegExp(...)` objects on every call (lines 619, 631, 637, 650, 661-665, 685), and it is invoked per OCR line on the ML Kit fallback path (`_importFromPdfOcr` line 462). — Consequence: constant-factor CPU/allocation waste for every line of a scanned play on the iOS/Android OCR fallback (thousands of lines → thousands of regex compilations); the patterns are constants and could be hoisted. — Smallest safe fix: hoist these patterns to `static final` fields (compiled once).

## Coverage
- lib/data/services/deep_link_service.dart — clean
- lib/data/services/kokoro_onnx_service.dart — clean
- lib/data/services/live_asr_service.dart — clean
- lib/data/services/media_control_service.dart — clean
- lib/data/services/mlx_stt_channel.dart — clean
- lib/data/services/model_download_service.dart — clean
- lib/data/services/model_manager.dart — clean
- lib/data/services/ocr_confidence_service.dart — findings: 1
- lib/data/services/paddle_ocr_channel.dart — clean
- lib/data/services/pdf_text_channel.dart — clean
- lib/data/services/perf_service.dart — clean
- lib/data/services/playback_session.dart — clean
- lib/data/services/recording_sync_service.dart — findings: 2
- lib/data/services/script_export.dart — clean
- lib/data/services/script_import_service.dart — findings: 2
# Batch 4 — Performance review (lib/data/services)

## Findings

- [medium] lib/data/services/stt_service.dart:304 — RegExp constructed per call on the live-recognition hot path — `matchScore` builds 5 regexes per invocation (`RegExp(r'\([^)]*\)')` at 304, `RegExp(r'\[[^\]]*\]')` at 305, `RegExp(r'[(\[][^)\]]*$')` at 306, `RegExp(r'\s+')` at 310/311, and `RegExp(r'[^\w\s]')` inside `_normalize` at 368), and `matchScore` is invoked on every partial STT result — several times per second per line — from `_handleRecognizedForLine` (rehearsal_screen.dart:2079). Each `RegExp(...)` compiles the pattern on construction; this exact cost was already hoisted to module constants in stt_vocabulary_service.dart (lines 8-11) because it "ran once per word ... on every partial STT result". Consequence: 5 regex compilations plus 2 full-text normalize passes per partial result, paid on the same hot path the rest of the code was explicitly de-hoisted for; measurable CPU on the recognition loop. — Fix: hoist the four patterns to `static final` constants (reuse the `_wsRe`/`_nonWordSpaceRe` style already used in stt_vocabulary_service.dart) and pass them into `_normalize`.

- [medium] lib/data/services/stt_service.dart:320 — LCS DP matrix fully allocated per call on the hot path — `final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0))` allocates (m+1)*(n+1) lists on every `matchScore` call, and `matchScore` runs several times per second per line (partial STT results). A 40-word spoken transcript vs a 40-word expected line is ~1600 list allocations per result. stt_vocabulary_service.dart already replaced exactly this with two reusable rows (`_dpPrev`/`_dpCurr`, lines 449-457) for its own `_editDistanceAtMost`. Consequence: allocation churn proportional to line word count squared on a real-time path. — Fix: use the two reusable-row LCS pattern (or a single reused growable matrix) instead of `List.generate` per call.

- [low] lib/data/services/script_parser.dart:893 — `_detectCharacterCue` re-sorts and re-compiles regexes per line over all known characters — the function sorts `knownCharacters.toList()` (line 893-894) and builds/`RegExp.escape`s a pattern per character per call (lines 901, 911-912, 919-920, 929, 949-950), and it is called once per raw line in `_parseLines` (lines 1125, 1203). For a ~1500-line script with ~30 characters that is ~45k regex compilations plus O(lines × chars log chars) sorting during a single parse. One-time parse (cold path), but the cost grows linearly with script length × character count and can add a noticeable second on large OCR'd plays. — Fix: build the sorted character list and pre-compiled cue patterns once (memoize across the line loop) instead of inside `_detectCharacterCue`.

- [low] lib/data/services/sync_queue.dart:350 — O(n) list removal per upload drains the queue in O(n²) — `_processQueue` loops `while (_pending.isNotEmpty)` taking `_pending.first` and then `_pending.remove(job)` (lines 380/388), and `List.remove` shifts the remaining elements each time. The queue size grows with the number of offline-recorded lines, so draining a queue of hundreds of pending uploads becomes quadratic list-shifting. Background upload path, bounded by offline recording count. — Fix: iterate by index (e.g. `while (i < _pending.length)` and remove via swap-remove/index), or pop from the end.

- [low] lib/data/services/tts_service.dart:443 — regexes recompiled per speak() call — `stripStageDirections` builds 4 `RegExp` objects per call (lines 443-448) and `_splitTextForKokoro` builds lookbehind regexes per call (lines 460, 490); `speak` runs `stripStageDirections` (line 376) and `_splitTextForKokoro` (line 565) once per line spoken. Per-line frequency, and synthesis itself dominates, but the patterns are constant and could be hoisted. — Fix: hoist the regexes to `static final` constants.

## Coverage
lib/data/services/script_parser.dart — findings: 1
lib/data/services/stt_adaptation_service.dart — clean
lib/data/services/stt_channel.dart — clean
lib/data/services/stt_service.dart — findings: 2
lib/data/services/stt_vocabulary_service.dart — clean
lib/data/services/supabase_service.dart — clean
lib/data/services/sync_queue.dart — findings: 1
lib/data/services/tts_service.dart — findings: 1
lib/data/services/vision_ocr_channel.dart — clean
lib/data/services/voice_clone_service.dart — clean
# Batch 5 — Performance review findings

- [high] lib/features/cast_manager/cast_manager_screen.dart:337-342 — itemBuilder performs a linear scan over the full castMembers list per card (`primaryFor`/`understudyFor` each do `state.firstWhere(...)` over M cast members) — for N character cards that is O(N×M) list rebuilds. castMembers is unbounded (one row per invited/joined actor), and the screen rebuilds on every castMembersProvider change (`save`/`remove`/`loadForProduction`) and on recordingsProvider change — so a sync or save of a few members triggers an O(N×M) scan. Fix: build a `Map<String, CastMemberModel>` keyed by characterName once per build (and per role) and look up per card.

- [high] lib/features/cast_manager/cast_manager_screen.dart:345 — itemBuilder calls `script.linesForCharacter(char.name)` which scans ALL script lines (`lines.where(...).toList()`, script_models.dart:321-326) and allocates a list per card — for N cards that is O(N×L) scans plus N list allocations per list rebuild, where L = total script lines (unbounded, a full play). Rebuild happens on every castMembers/recordings change. Fix: precompute a character→lines map once per build/data change and index it in the itemBuilder.

- [medium] lib/features/cast_manager/cast_manager_screen.dart:147-153 — `assignVoicesFromScript(...)` walks every script line and does graph coloring on EVERY build, but its inputs (script, `_currentPreset`, `_genderOverrides`) change rarely; the rebuild is driven by castMembers/recordings updates that don't affect the assignment. For a large script this is a full O(lines×window) walk plus O(chars²) coloring paid per unrelated rebuild. Fix: memoize the assignment keyed on (script identity, preset, genderOverrides) and recompute only when those change.

- [medium] lib/features/cast_manager/cast_manager_screen.dart:163-169 — `unassignedCount` filters `script.characters` with an inner `castMembers.where(...)` per character — O(N characters × M castMembers) per build, recomputed on every rebuild of this screen. Fix: build a set of assigned character names once per build, then count characters not in it (O(N+M)).

- [medium] lib/features/cast_manager/cast_manager_screen.dart:62-83 — `_syncCastFromCloud` awaits `notifier.save(member)` once per cloud row sequentially: each save is a Drift write plus a full state-list copy `state = [...state, member]` (production_providers.dart:214-220), so syncing N cloud members is N sequential DB writes plus O(N²) list copying. Fix: batch the state update (e.g. build the merged list once after the DB writes) and consider a transaction for the writes.

- [medium] lib/data/services/voice_config_service.dart:188 — inside the per-character greedy loop, `chosen ??= _leastUsedVoice(pool, assignment.values.toList());` allocates `assignment.values.toList()` (O(assigned characters)) and `_leastUsedVoice` scans it, once per character — O(chars²) total for the assignment phase of `assignVoicesFromScript`, which runs on every cast_manager/voice_config build. Fix: maintain a running voice-use counter map and update it incrementally instead of rebuilding `values.toList()` per character.

- [high] lib/features/cast_manager/bulk_cast_setup_screen.dart:75-79 — `unassigned` filters `script.characters` with an inner `castMembers.any(...)` per character — O(N characters × M castMembers) per build. It is recomputed on EVERY keystroke because each TextField's `onChanged: (_) => setState(() {})` (line 214) triggers a full-screen rebuild, and the AppBar `unassigned.every(...)` (line 89) and `_filledCount` (line 60-61) also scan all controllers per build. Fix: index castMembers into a per-character map once, and scope the keystroke rebuild to the counter/save-button (e.g. a small ValueNotifier) instead of rebuilding the whole screen.

- [medium] lib/features/cast_manager/bulk_cast_setup_screen.dart:257-296 — `_saveCastAssignments` awaits `supa.createCastInvitation(...)` sequentially inside the loop over filled actors, so saving N actors is N sequential network round-trips with no batching/parallelism, plus N sequential local `save` calls. Fix: fire the cloud invitations concurrently (Future.wait) and batch the local saves.

- [low] lib/features/cast_manager/voice_config_screen.dart:72,108-121 — the screen uses a non-lazy `ListView(children: [...])` that eagerly builds a tile for every script character and recomputes `assignVoicesFromScript` (O(lines×chars)) on every setState (preset/override changes); for a long play with many characters this builds and lays out all tiles at once. One-shot config screen, so impact is bounded to a single build. Fix: `ListView.builder` with the character tiles and memoize the assignment.

## Coverage
lib/data/services/voice_config_service.dart — findings: 1
lib/features/auth/auth_screen.dart — clean
lib/features/cast_manager/bulk_cast_setup_screen.dart — findings: 2
lib/features/cast_manager/cast_manager_screen.dart — findings: 4
lib/features/cast_manager/voice_config_screen.dart — findings: 1
lib/features/home/home_screen.dart — clean
lib/features/join/join_production_screen.dart — clean
lib/features/onboarding/model_setup_screen.dart — clean
# batch-6 performance findings (Flutter)

- [high] lib/features/recording_studio/recording_studio_screen.dart:233 — `_myLines = script.linesForCharacter(character)` recomputed on EVERY `build()`, and `_buildContextLines` at line 344 runs `script.lines.indexWhere((l) => l.id == currentLine.id)` — both are full O(script-lines) scans with new-list allocation. `build()` runs at 10 Hz during recording because `_durationTimer` (line 597, `Timer.periodic(100ms)`) calls `setState` every 100 ms while `_status == recording`. For a long script (thousands of lines) each tick scans the whole script twice on the UI isolate — jank on every audio-recording take, worst on the longest plays. Fix: compute `_myLines` once in `initState`/when `recordingCharacterProvider` changes, and store the current line's full-script index once instead of `indexWhere` per build.

- [medium] lib/features/recording_studio/recording_character_screen.dart:59 — `final charLines = script.linesForCharacter(char.name)` inside the `ListView.builder` `itemBuilder`: `linesForCharacter` walks ALL `script.lines` (`.where(...).toList()`, script_models.dart:321) per visible character row, so building the list is O(visibleCharacters × script-lines). A play with dozens of characters and thousands of lines pays a full script scan per visible tile, and every `recordingsProvider` change rebuilds and re-runs it. Fix: build a `characterName -> dialogue lines` map once per build/data change and index it in the builder.

- [medium] lib/features/recording_studio/recordings_browser_screen.dart:76 — `build()` rebuilds a full `linesById` map of every `script.lines` (`{for (final l in script.lines) l.id: l}`), then `recordedEntries.sort` (line 92) and the `_scanFileExistence` join key `entries.map((e) => e.recording.id).join('|')` (line 188) — all O(script-lines + recordings log recordings) work re-done on every rebuild. Rebuilds fire on every play/stop `setState` (`_playingLineId`, lines 680/686/696), every filter toggle, and every recording change, so toggling playback on a large production re-scans the whole script and re-sorts all recordings each time. Fix: cache the `linesById` map and the sorted entries keyed on the script/recordings identity; only recompute when the underlying data changes.

- [medium] lib/features/recording_studio/recordings_browser_screen.dart:193 — `_scanFileExistence` awaits `_resolveRecordingPath(entry)` sequentially per entry, and `_resolveRecordingPath` (line 587) calls the async `getApplicationDocumentsDirectory()` per recording plus `File().existsSync()` per path attempt. On the first screen of a production with hundreds of recordings this is O(recordings) serial coroutine hops + fs checks on the initial scan (one-time per list, off build, but adds a long stall after load). Fix: resolve `getApplicationDocumentsDirectory()` once before the loop and pass it in; the `_cachedRecordingPaths` cache already makes the cache listing one-time.

- [medium] lib/features/production_hub/production_hub_screen.dart:504 — inside the scene-list `ListView.builder` `itemBuilder`, `scene.characters.map((charName) { final charIdx = script.characters.indexWhere((c) => c.name == charName); ... })` is an O(sceneCharacters × scriptCharacters) linear scan per visible scene row, plus per-row `script.linesInScene(scene)` sublist + `.where(dialogue).toList()` allocation (lines 409-416). On a scrolling list over a long script with many scenes/characters, each visible row re-walks the whole character list and re-materializes the scene's dialogue — scroll jank and allocation churn proportional to cast × scene size. Fix: precompute a name→colorIndex map once per build/data change and hoist per-row dialogue counting out of `itemBuilder`.

- [low] lib/features/rehearsal/rehearsal_history_screen.dart:21 — `state = [session, ...state]` copies the entire (uncapped) history list on every `add`, so the list is O(n) per insertion and O(n²) cumulative, and each add triggers a rebuild that re-runs `_buildSummary`'s folds and `uniqueScenes = sessions.map((s) => s.sceneId).toSet()` (O(sessions)). Sessions accumulate for the whole rehearsal history with no cap. Fix: append to a growable list (insert at tail and render reversed, or cap the retained history) so adds are O(1); keep the summary memoized.

## Coverage
lib/features/production_hub/production_hub_screen.dart — findings: 1
lib/features/recording_studio/recording_character_screen.dart — findings: 1
lib/features/recording_studio/recording_studio_screen.dart — findings: 1
lib/features/recording_studio/recordings_browser_screen.dart — findings: 2
lib/features/recording_studio/voice_profile_screen.dart — clean
lib/features/rehearsal/rehearsal_history_screen.dart — findings: 1
# batch-7 findings — performance review

## lib/features/rehearsal/rehearsal_screen.dart

- [high] lib/features/rehearsal/rehearsal_screen.dart:933 — `cacheExtent: 10000` on the dialogue `ListView.builder` materializes the entire scene list (every item built + laid out offscreen; the in-code comments admit ~70–145 offscreen items stay alive). Rebuilds of `_buildScriptView` fire on every line advance (`currentLineIndexProvider`), state change, font-size and blind-mode toggle, so a full play scene (hundreds–thousands of dialogue lines) is fully rebuilt and re-laid-out per advance — the list's laziness is defeated and per-frame layout cost scales with the whole scene, not the viewport. Fix: drop `cacheExtent` to the default viewport-scaled value (or a small value like 250 px) and scroll by computed offset / `scroll_to_index` instead of relying on the item always being built.

- [high] lib/features/rehearsal/rehearsal_screen.dart:950 — inside `itemBuilder`, `script.characters.indexWhere((c) => c.name == colorLookupName)` is an O(characters) linear scan per list item; combined with `cacheExtent: 10000` every item is built, so each build/rebuild is O(dialogueLines × characters) — quadratic on a full play with many characters and lines. Fix: build a `Map<String,int>` name→index once per build/data change and index it (`charIdx = nameToIndex[colorLookupName]`), the standard pattern for `indexWhere` in an itemBuilder.

- [medium] lib/features/rehearsal/rehearsal_screen.dart:942 — `final baseFontSize = ref.watch(rehearsalFontSizeProvider);` and line 1049 `if (ref.watch(hideMyLinesProvider) && isMe && !isPast)` are `watch` calls inside `itemBuilder`: every built item subscribes to those providers, so tapping text-size +/- or toggling blind mode rebuilds every item currently in the cache extent (the whole script, given `cacheExtent: 10000`) instead of just the visible rows. Fix: pass font size and blind-flag down as plain arguments to a leaf item widget, or have only the current-line item watch them.

- [high] lib/features/rehearsal/rehearsal_screen.dart:964 — every list item is wrapped in `Opacity(..., opacity: ...)` with 0.25 (past) or 0.5 (future) opacity; a non-1.0 `Opacity` forces a `saveLayer` offscreen buffer per item. With `cacheExtent: 10000` the whole scene is a forest of saveLayers, so each rebuild hands the raster thread hundreds of offscreen buffers. Fix: replace the `Opacity` wrapper with alpha-blended colors (`Colors.white.withValues(alpha: ...)` on the text/container decoration) so no saveLayer is created.

## lib/features/script_editor/character_manager_screen.dart

- [medium] lib/features/script_editor/character_manager_screen.dart:755 — `_rebuildScript` computes `updatedScenes` with a nested loop: `script.scenes.map((scene) { ... for (final line in updatedLines) {...} })` scans ALL `updatedLines` once per scene to collect that scene's characters — O(scenes × lines). On rename/merge/delete of a full play (dozens of scenes × thousands of lines) each edit is a quadratic pass, and it also allocates a `toList()` per scene. Fix: since scenes are contiguous `startLineIndex..endLineIndex` ranges, do a single pass over `updatedLines`, mapping each dialogue line to its containing scene by range, accumulating `sceneChars` once instead of re-scanning per scene.

## lib/features/script_editor/cloud_sync_dialog.dart

- [low] lib/features/script_editor/cloud_sync_dialog.dart:67 — `showCloudSyncDialog` runs `diffs.where(...)` five separate times over the full diff list (added/removed/changed/unchanged, plus `changedDiffs`) to build the summary and the list; each is a fresh O(local+cloud) pass. For a full-script diff (thousands of lines) this is a 5× constant-factor re-scan of an already-computed list. Fix: fold the counts into the single `diffScriptLines` construction pass (or a single loop over `diffs`) instead of five `where` scans.

## lib/features/script_editor/scene_editor_screen.dart

- [low] lib/features/script_editor/scene_editor_screen.dart:66 — `itemBuilder` calls `script.linesInScene(scene)` per scene item, which does `lines.sublist(start, end)` — allocating a fresh list of that scene's lines — then scans it again with `.where(...).length` for the dialogue count; on each build/rebuild of the scene list this re-allocates the sublist per visible scene. And the character chips (`scene.characters.map((name) { script.characters.indexWhere(...) })`, lines 115-118) do an O(scene.chars × all chars) scan per expanded scene. Scenes/characters are small bounded collections, so cost is modest, but it repeats on every rebuild and on each expansion. Fix: precompute scene dialogue counts and a name→index character map once per script change, and avoid re-sublisting per item.

## Coverage
lib/features/rehearsal/rehearsal_screen.dart — findings: 4
lib/features/script_editor/character_manager_screen.dart — findings: 1
lib/features/script_editor/cloud_sync_dialog.dart — findings: 1
lib/features/script_editor/scene_editor_screen.dart — findings: 1
# Batch 8 — Performance Review Findings

- [medium] lib/features/script_editor/script_editor_screen.dart:429 — `_buildDetailPanel` creates `final textController = TextEditingController(text: line.text);` inside the build path and never disposes it — on tablet master/detail, every tap on a line calls `setState(() => _selectedLine = line)` (line 360), rebuilding the whole screen and minting a fresh TextEditingController that is leaked (its old instance is dropped without dispose) — repeated taps leak controllers + allocations on the UI thread and grow the heap over a session — hoist the controller into state keyed by line id, or use a TextField with an initialValue-style controller managed in a child stateful widget that disposes in `dispose()`.

- [low] lib/features/script_editor/script_editor_screen.dart:757,762 — `_editLine` creates `textController` and `newCharController` (and `_splitLine` at :1001 creates `controller`) inside modal/dialog builders with no dispose — each edit sheet leaks 2 TextEditingControllers and each split dialog leaks 1, accumulated per user edit across a session — dispose the controllers when the sheet/dialog is popped.

- [medium] lib/features/script_import/ocr_review_screen.dart:317-329 — `_buildListChildren` eagerly builds every review card and not-script ListTile into a `children` list (`...reviewLines.map((l) => _buildReviewCard(...))` at :408, `...remaining.map(...)` at :722), then ListView.builder only indexes `children[i]` — the comment at :313-316 claims laziness to avoid building 100-300 heavy TextField cards per setState, but the eager build defeats it — every save/remove/select `setState` rebuilds and re-lays-out all cards (hundreds of TextFields), the exact hundreds-of-ms-per-tap cost the comment says was fixed — convert to a real `ListView.builder` that constructs only visible cards (`itemBuilder` building the card directly instead of indexing a prebuilt list).

- [medium] lib/features/script_import/ocr_review_screen.dart:99-118 — `_contextLinesFor` re-scans the whole line list per call (`widget.lines.where(...).toList()..sort(...)` over all lines), and `_buildContextEditor` (:609) calls it per expanded card on every rebuild — with several "edit nearby lines" cards expanded, each build does O(cards × n log n) work over the script — precompute the ordered non-removed list once per build/data change and index into it.

- [medium] lib/features/settings/settings_screen.dart:312-313 — `FutureBuilder<String>(future: _getVersionString(), ...)` creates a fresh future inside `build()`; the screen `watch`es 8 providers (lines 78-86), so dragging any slider (e.g. playback speed :155) rebuilds the whole screen and re-invokes `PackageInfo.fromPlatform()` (a platform-channel call) on every rebuild, discarding prior results — cache the version string once (initState/lazy field or a provider) and reuse the same future.

- [low] lib/features/settings/debug_log_screen.dart:33 — `Timer.periodic(const Duration(seconds: 2), (_) => setState((){}))` rebuilds the whole screen every 2 s, and each build calls `_log.entriesForCategory(_filter)` (line 49) which for a category filter copies the up-to-500-entry ring buffer via `where().toList()` — continuous O(500) copy + full-screen rebuild while the screen is open, wasted work when nothing changed — only setState when a new entry arrives (or have the service push a revision counter).

## Coverage
lib/features/script_editor/script_editor_screen.dart — findings: 2
lib/features/script_editor/validation_panel.dart — clean
lib/features/script_import/ocr_review_screen.dart — findings: 2
lib/features/script_import/pdf_page_view.dart — clean
lib/features/script_import/script_import_screen.dart — clean
lib/features/settings/ai_models_screen.dart — clean
lib/features/settings/debug_log_screen.dart — findings: 1
lib/features/settings/kokoro_debug_screen.dart — clean
lib/features/settings/model_download_screen.dart — clean
lib/features/settings/parakeet_debug_screen.dart — clean
lib/features/settings/settings_screen.dart — findings: 1
lib/firebase_options.dart — clean
# Batch 9 — performance findings

- [high] supabase/migrations/20260315_cast_join_code.sql:20 — Drops `ALTER TABLE public.cast_members DROP CONSTRAINT IF EXISTS cast_members_production_id_user_id_key;` which was the ONLY index covering the `(production_id, user_id)` predicate that the SECURITY-DEFINER RLS helper `is_production_member` uses (`select exists (select 1 from public.cast_members where production_id = p_production_id and user_id = p_user_id)` — defined 20260314140000:7 and re-created 20260703140000:199). No later migration re-creates an index on cast_members.production_id. Because this helper is the `USING` clause of RLS policies on productions, cast_members, recordings, script_lines AND storage.objects, every row the planner considers on those tables (e.g. `fetchMyProductions` on every home-screen load, recording sync downloads, script fetches, and `fetch_cast_for_join` at 20260319000001:26 / 20260703140000:180 which also selects cast_members by production_id) forces a sequential scan of the whole cast_members table per evaluation. Consequence: as cast_members grows (dozens of rows per production × many productions), cloud read/write paths degrade to O(rows × cast_members) — latency scales with the whole table instead of an index lookup. Smallest safe fix: add a new migration `create index idx_cast_members_production on public.cast_members (production_id);` (or `(production_id, user_id)`).

- [medium] lib/providers/production_providers.dart:232 — `CastMembersNotifier.primaryFor` (line 230-238) and `understudyFor` (line 241-250) each do a linear `state.firstWhere(...)` scan over the whole cast-member list, and the caller `lib/features/cast_manager/cast_manager_screen.dart:337-342` invokes both inside the character `ListView.builder`'s `itemBuilder`, once per character row — alongside `script.linesForCharacter(char.name)` (script_models.dart:321, an O(all-lines) filter). Consequence: building the cast-manager list is O(characters × castMembers) + O(characters × scriptLines) on every rebuild, and the screen rebuilds as cast/recording/progress state changes; jank scales with cast size × script length (~40 chars × ~2000 lines ≈ 80k comparisons per full list render). Smallest safe fix: maintain a `Map<String, CastMemberModel>` (primary) and a per-character understudy map updated once per state write, and have the screen iterate a single prebuilt character→lines index instead of re-filtering `script.lines` per row.

- [low] lib/providers/production_providers.dart:76 — `ProductionsNotifier.addAll` awaits `_repo.saveProduction(production)` once per production inside a loop, then reloads the whole table; it is reached from `restoreCloudProductions` (line 479-513) which runs on every home-screen load for cloud productions missing locally. Consequence: restoring many productions issues one Drift write per row sequentially instead of a single batched insert. Smallest safe fix: batch the inserts (one transaction / multi-row insert) and reload once.

- [low] scripts/pdf_to_script.py:146 — `_extract_folger` calls `_detect_characters_from_pdf(doc)` (line 124-140) which scans every page with the expensive `page.get_text("dict")` block/line walk, then the main extraction loop (line 179+) walks the pages again with the same `get_text("dict")` mode — the full PDF is decoded in dict mode twice. Consequence: roughly doubles conversion time for large play PDFs (a one-shot CLI import pipeline). Smallest safe fix: detect characters within the single main extraction pass, or reuse one dict-mode text extraction for both.

- [low] scripts/parse_script.py:140 — `for char in sorted(KNOWN_CHARACTERS, key=len, reverse=True)` recomputes the sort of the 27-name list on every call of `detect_character_cue`, which runs per input line in the main `while` loop (line 241), plus the second `for char in KNOWN_CHARACTERS` membership scan in the multi-cue branch. Consequence: O(lines × characters) sort+regex work per line in a one-shot CLI parser. Smallest safe fix: hoist `KNOWN_CHARACTERS_BY_LEN = sorted(...)` (and a set of names) to module level once.

- [low] macos/Runner/BackgroundDownloadPlugin.swift:24 — `session = URLSession(configuration: config, delegate: self, delegateQueue: .main)` runs all delegate callbacks on the main thread, and `urlSession(... didWriteData ...)` (line 121-143) invokes the Flutter method channel on every write chunk. Consequence: a multi-hundred-MB Kokoro model download pumps thousands of progress callbacks onto the main/UI thread, risking jank during the download. Smallest safe fix: use a dedicated `delegateQueue:` (e.g. `.operationQueue` on a background queue) and throttle progress sends (e.g. at most a few per second).

## Coverage
- lib/main.dart — clean
- lib/providers/production_providers.dart — findings: 2
- linux/flutter/generated_plugin_registrant.cc — clean
- linux/flutter/generated_plugin_registrant.h — clean
- linux/runner/main.cc — clean
- linux/runner/my_application.cc — clean
- linux/runner/my_application.h — clean
- macos/Flutter/GeneratedPluginRegistrant.swift — clean
- macos/Runner/AppDelegate.swift — clean
- macos/Runner/BackgroundDownloadPlugin.swift — findings: 1
- macos/Runner/MainFlutterWindow.swift — clean
- macos/Runner/MemoryMonitorPlugin.swift — clean
- macos/Runner/PdfTextPlugin.swift — clean
- macos/Runner/VisionOcrPlugin.swift — clean
- macos/RunnerTests/RunnerTests.swift — clean
- pubspec.yaml — clean
- scripts/compare_macbeth_versions.py — clean
- scripts/deploy.sh — clean
- scripts/generate_rehearsal_webp.sh — clean
- scripts/generate_screenshots.sh — clean
- scripts/generate_test_export.py — clean
- scripts/parse_script.py — findings: 1
- scripts/pdf_to_script.py — findings: 1
- scripts/phone-harness.sh — clean
- scripts/pull-crashlog.sh — clean
- scripts/pull-debuglog.sh — clean
- scripts/ship-play.sh — clean
- scripts/ship-testflight.sh — clean
- scripts/test_pdf_import.swift — clean
- scripts/test_silence_trim.swift — clean
- supabase/config.toml — clean
- supabase/migrations/20260314061409_initial_schema.sql — clean
- supabase/migrations/20260314120000_add_script_lines.sql — clean
- supabase/migrations/20260314130000_fix_cast_members_rls.sql — clean
- supabase/migrations/20260314140000_fix_rls_recursion.sql — clean
- supabase/migrations/20260315_cast_join_code.sql — findings: 1
- supabase/migrations/20260316_join_code_default.sql — clean
- supabase/migrations/20260318_add_join_code_policy.sql — clean
- supabase/migrations/20260319000001_join_flow_rpc_v2.sql — clean
- supabase/migrations/20260319100000_add_voice_preset.sql — clean
- supabase/migrations/20260319100001_add_locale.sql — clean
- supabase/migrations/20260320200000_add_debug_reports.sql — clean
- supabase/migrations/20260701090000_add_multi_characters.sql — clean
- supabase/migrations/20260703090000_leave_policy_and_audit_cleanup.sql — clean
- supabase/migrations/20260703100000_purge_test_productions.sql — clean
- supabase/migrations/20260703140000_security_lockdown.sql — clean
- supabase/migrations/20260703150000_fix_helper_grants.sql — clean
- supabase/migrations/20260703160000_drop_last_productions_readall.sql — clean
- supabase/migrations/20260703170000_recordings_delete_policy.sql — clean
- test_driver/integration_test.dart — clean
- test/analytics_route_observer_test.dart — clean
- test/cast_member_test.dart — clean
- test/cast_role_test.dart — clean
- test/cloud_sync_dialog_test.dart — clean
- test/dialog_navigation_test.dart — clean
- test/gender_inference_test.dart — clean
- test/home_screen_logic_test.dart — clean
- test/model_manager_test.dart — clean
- test/models_test.dart — clean
- test/ocr_cleanup_test.dart — clean
- test/ocr_confidence_mapping_test.dart — clean
- test/ocr_confidence_test.dart — clean
- test/parser_accuracy_test.dart — clean
- test/parser_edge_cases_test.dart — clean
- test/pdf_export_test.dart — clean
- test/pdf_import_test.dart — clean
# Batch 10 — Performance review findings

Files reviewed: 26 (test/ + tool/ Dart files). The test files exercise app code but operate on small fixed fixtures (no unbounded inputs on a hot path), so the real findings are in the tool scripts that iterate over live cloud data.

- [medium] tool/orphan_sweep.dart:37-104 — Per-production sequential network round-trips over ALL productions. The loop `for (final prod in prods)` fetches `productions` unbounded up front, then for every production sequentially awaits 4 network calls: a `cast_members` insert (lines 41-51), a `script_lines` select (56-60), a `recordings` select (62-66), and a `cast_members` delete (89-95). Since every `await` is inside the loop body, total latency is ~4N × RTT where N is the production count; with hundreds of productions this is minutes of wall time and saturates the REST API with tiny queries. — Smallest safe fix: fetch `script_lines` and `recordings` for all productions in one query each (filter by the production_id set) after the upfront `productions` fetch, and drop the per-production script_lines/recordings round trips; keep the cast_members insert/delete per production only (RLS requires it) but run those concurrently (`Future.wait`) instead of sequentially.

- [low] tool/orphan_sweep.dart:77-80 — `RegExp('/$pid/([^/]+)/')` is constructed inside `for (final r in orphans)` on every orphan row. The pattern is loop-invariant (depends only on `pid`, fixed per production), so this reparses the regex once per recording row. — Concrete consequence: for a production with thousands of orphaned recordings, thousands of RegExp object constructions/parses add CPU per row in an already network-bound sweep. — Smallest safe fix: hoist `final re = RegExp('/$pid/([^/]+)/');` out of the orphan loop (and the per-production body) and reuse it.

- [low] tool/analyze_orphaned_recordings.dart:84-87 — `charOf` builds a fresh `RegExp('/$productionId/([^/]+)/')` on every call, and it is invoked once per orphaned recording in the print loop (line 92) and twice per recording in the counts loop (lines 103-104), i.e. ~3 RegExp parses per recording row. The pattern depends only on `productionId`, so it is loop-invariant. — Concrete consequence: for a production with many recordings this reparses the regex ~3N times in a single run. — Smallest safe fix: hoist `final re = RegExp('/$productionId/([^/]+)/');` once and pass it into a `charOf(String url)` that uses the shared instance.

## Coverage
test/pp_ocr_attribution_test.dart — clean
test/production_repository_test.dart — clean
test/recording_path_safety_test.dart — clean
test/recording_sync_service_test.dart — clean
test/rehearsal_models_test.dart — clean
test/sample_script_test.dart — clean
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
tool/analyze_orphaned_recordings.dart — findings: 1
tool/orphan_sweep.dart — findings: 2
tool/parse_stats.dart — clean
tool/sim_multi_user.dart — clean
tool/verify_cloud_recordings.dart — clean
