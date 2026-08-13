# Pi sweep review — CastCircle-5cfa63ca

Exhaustive per-file pass: 274 code files across 23 batches.

## Findings

- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:100 — After ACTION_PICK returns the contact URI, the plugin queries ContactsContract.CommonDataKinds.Phone.CONTENT_URI (and Email.CONTENT_URI) to fetch phone/email, but that URI is not covered by the picker's temporary URI grant and requires the READ_CONTACTS runtime permission, which is never requested anywhere in the app (only declared in the manifest). On devices where READ_CONTACTS has not been runtime-granted, `contentResolver.query(Phone.CONTENT_URI, ...)` throws SecurityException, which the outer catch at line 129 converts to `CONTACT_ERROR`, so the caller receives an error and loses even the successfully-read display name. — Smallest safe fix: wrap the phone and email queries in their own try/catch so a permission failure still returns `{name, phone: null, email: null}`, or request READ_CONTACTS at runtime (and degrade gracefully on denial).
- [medium] ios/Runner/KokoroMLXService.swift:187 — `synthGeneration` is a plain `Int` that is incremented and read (`+= 1` / `let myGeneration = synthGeneration`) on the calling Swift-concurrency thread, outside `synthQueue`, while queued blocks read `self.synthGeneration` inside `synthQueue`. Concurrent `synthesize()` calls (the app prefetches the next line while one is still in flight) race on this non-atomic counter; a lost increment makes `myGeneration != self.synthGeneration` evaluate false, so a superseded (stale) synthesis is not cancelled and its audio can be synthesized/returned after a newer request. — Smallest safe fix: move the generation increment and capture inside the `synthQueue.async` block (or protect `synthGeneration` with a lock/actor) so read-modify-write is serialized.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:460 — `releaseRecorder()` performs a blocking `captureThread?.join(1500)` and is called from `stopListening` (line 239) and `onDetachedFromEngine` (line 77), both of which run on the main thread. When `stop` arrives mid-capture the capture loop may be inside `record.read` and then its EOS flush (`drainEncoder` waits up to a 1000 ms deadline), so the main thread can block for up to ~1.5 s, janking the UI (the comment at 236–238 shows this path is expected). — Smallest safe fix: perform the join off the main thread (as `stopRecording` already does) instead of joining synchronously on the platform thread.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/PdfTextPlugin.kt:70 — `ParcelFileDescriptor.open` returns an fd that is only closed at line 73 after `PdfRenderer(fd)` constructs successfully; if the PDF is corrupt and the `PdfRenderer(fd)` constructor throws, control jumps to the catch and the fd is never closed. Repeatedly importing corrupt PDFs leaks a file descriptor each time and can eventually exhaust the fd table. — Smallest safe fix: open the fd inside a `use`/try-finally (close it in `finally`) so it is released on the constructor-throw path too.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:169 — Same class of leak as PdfTextPlugin: the fd from `ParcelFileDescriptor.open` (line 163) is only handed to `PdfRenderer(fd).use { ... }`, and `.use` never runs if the `PdfRenderer(fd)` constructor throws on a corrupt PDF, so the opened fd leaks on that path (the outer catch just posts `PDF_OCR_FAILED`). — Smallest safe fix: wrap the `ParcelFileDescriptor` in a try/finally (or `use`) and close it in `finally` regardless of renderer construction.

## Coverage
analysis_options.yaml — clean
android/app/build.gradle.kts — clean
android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt — findings: 1
android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt — findings: 1
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
ios/Runner/KokoroMLXService.swift — findings: 1
# Findings — batch 2

- [low] ios/Runner/KokoroVendored/BuildingBlocks/Interpolate.swift:97 — `xLow = MLX.floor(x).asType(.int32)` is never clamped to `[0, inputWidth-1]` before being used as a gather index (`input[..., xLow]` at line 101). In linear upsampling (`scaleFactor > 1` ⇒ `scale = inputWidth/outputSize < 1`), `x = i*scale + 0.5*scale - 0.5` is negative for the first `floor(0.5*(1/scale - 1))` output positions, so `floor(x)` yields `-1` and MLX's negative indexing wraps to the last element of the input, blending the final (largest) sample into the start of the output. Reachable via `SineGen._f02sine`, which upsamples the accumulated phase with `scaleFactor: upsampleScale` (=300); the result is a ~150-sample decaying phase glitch at the very start of the harmonic source (audible onset artifact for voiced utterances). Smallest safe fix: clamp the low index, e.g. `let xLow = MLX.clip(MLX.floor(x).asType(.int32), min: 0, max: inputWidth - 1)`.

- [nit] ios/Runner/KokoroVendored/Albert/AlbertIntermediate.swift:8 — `AlbertIntermediate` is dead code: it is compiled into the target (project.pbxproj) but never instantiated anywhere in the Swift sources; its logic duplicates `AlbertLayer.ffChunk`. Consequence: misleading duplication that can drift from the live path and confuse future maintenance. Smallest safe fix: delete the class and its pbxproj entries, or wire it into `AlbertLayer` if it was intended to be the FFN sub-layer.

- [nit] ios/Runner/KokoroVendored/Albert/AlbertOutput.swift:13 — `AlbertOutput` is dead code (never instantiated outside project.pbxproj) and, unlike every other Albert component, its `dense` layer is constructed via `Linear(config.intermediateSize, config.hiddenSize)` with no weights loaded from the model, so it uses random initialization. Consequence: if anyone ever wires it in, it silently produces garbage rather than failing at init. Smallest safe fix: delete it, or load weights from `bert.encoder...output.dense.*` and add the same shape guard used elsewhere.

- [nit] ios/Runner/KokoroVendored/Albert/AlbertSelfOutput.swift:13 — `AlbertSelfOutput` is dead code (never instantiated outside project.pbxproj) and its `dense` layer is constructed via `Linear(config.hiddenSize, config.hiddenSize)` with no weights loaded from the model, so it uses random initialization. Consequence: if anyone ever wires it in, it silently produces garbage rather than failing at init. Smallest safe fix: delete it, or load weights from `bert.encoder...attention.output.dense.*` and add the same shape guard used elsewhere.

## Coverage
ios/Runner/KokoroVendored/Albert/AlbertEmbeddings.swift — clean
ios/Runner/KokoroVendored/Albert/AlbertEncoder.swift — clean
ios/Runner/KokoroVendored/Albert/AlbertIntermediate.swift — findings: 1
ios/Runner/KokoroVendored/Albert/AlbertLayer.swift — clean
ios/Runner/KokoroVendored/Albert/AlbertLayerGroup.swift — clean
ios/Runner/KokoroVendored/Albert/AlbertModelArgs.swift — clean
ios/Runner/KokoroVendored/Albert/AlbertOutput.swift — findings: 1
ios/Runner/KokoroVendored/Albert/AlbertSelfAttention.swift — clean
ios/Runner/KokoroVendored/Albert/AlbertSelfOutput.swift — findings: 1
ios/Runner/KokoroVendored/Albert/CustomAlbert.swift — clean
ios/Runner/KokoroVendored/BuildingBlocks/AdaIN1d.swift — clean
ios/Runner/KokoroVendored/BuildingBlocks/AdainResBlk1d.swift — clean
ios/Runner/KokoroVendored/BuildingBlocks/AdaINResBlock1.swift — clean
ios/Runner/KokoroVendored/BuildingBlocks/AdaLayerNorm.swift — clean
ios/Runner/KokoroVendored/BuildingBlocks/Conv1dInference.swift — clean
ios/Runner/KokoroVendored/BuildingBlocks/ConvWeighted.swift — clean
ios/Runner/KokoroVendored/BuildingBlocks/InstanceNorm1d.swift — clean
ios/Runner/KokoroVendored/BuildingBlocks/Interpolate.swift — findings: 1
ios/Runner/KokoroVendored/BuildingBlocks/LayerNormInference.swift — clean
ios/Runner/KokoroVendored/BuildingBlocks/LSTM.swift — clean
- [medium] ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:338 — `speed` is used directly as a divisor without validation — a `speed` of 0 (or NaN) yields `inf`/`NaN` durations; `clip(...).round().asType(.int32)` on `inf` is undefined and `createAlignmentTarget` then allocates `Array(repeating:count:)` from the resulting (possibly negative/huge) frame count, crashing or exhausting memory — reachable from the Flutter channel (`KokoroMLXPlugin.swift:49` passes an unvalidated Dart `Double` straight through) — smallest safe fix: `guard speed > 0, speed.isFinite else { throw ... }` at the top of `generateAudio` (or clamp to a sane range).
- [low] ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:290 — empty/whitespace-only input is not rejected: `inputIds` becomes `[]`, so `tokenCount == 0` and `voice[tokenCount - 1]` indexes `voice[-1]`, which MLX wraps to the last style entry — the engine synthesizes audio for empty text using the wrong style instead of returning an error — reachable via `KokoroMLXPlugin` with no empty-text guard — smallest safe fix: after tokenization, throw/return early when `inputIds.isEmpty`.
- [low] ios/Runner/KokoroVendored/Decoder/MLXSTFT.swift:136 — `let windowModLen = 20 / 5` hardcodes the overlap-add group count to 4, which is only correct because the shipped config has `genIstftNFFT == 800` and `genIstftHopSize == 200` (ratio 4); the `t / winLen` window-sum repeat count relies on the same ratio — if the iSTFT config values ever change (e.g. 1024/256), `mlxIstft` silently produces wrong/aliased audio or mis-sized window sums — smallest safe fix: compute `let windowModLen = winLen / hopLen` and validate `winLen % hopLen == 0`.
- [low] ios/Runner/KokoroVendored/TTSEngine/KokoroConfig.swift:18 — `nonisolated(unsafe) static var config` is written by `loadConfig()` and read on every `Tokenizer.tokenize` call with no synchronization — concurrent initialization (or a tokenize racing a first `loadConfig`) is a data race on shared mutable state (undefined behavior/crash) — smallest safe fix: initialize `config` once as a `let` at startup, or guard access with a lock/actor.
- [nit] ios/Runner/KokoroVendored/TextProcessing/Tokenizer.swift:21 — out-of-vocabulary characters are silently discarded via `.filter { $0 != nil }` — a G2P-emitted phoneme/symbol not in `vocab` is dropped, altering the phoneme sequence (mispronunciation) with no error, and an all-OOV input yields an empty token list that flows into the empty-input path — smallest safe fix: throw or log on OOV tokens (or at minimum detect an empty result).

## Coverage
ios/Runner/KokoroVendored/BuildingBlocks/ReflectionPad1d.swift — clean
ios/Runner/KokoroVendored/BuildingBlocks/UpSample1d.swift — clean
ios/Runner/KokoroVendored/Decoder/Decoder.swift — clean
ios/Runner/KokoroVendored/Decoder/Generator.swift — clean
ios/Runner/KokoroVendored/Decoder/MLXSTFT.swift — findings: 1
ios/Runner/KokoroVendored/Decoder/SineGen.swift — clean
ios/Runner/KokoroVendored/Decoder/SourceModuleHnNSF.swift — clean
ios/Runner/KokoroVendored/TextProcessing/eSpeakNGG2PProcessor.swift — clean
ios/Runner/KokoroVendored/TextProcessing/G2PFactory.swift — clean
ios/Runner/KokoroVendored/TextProcessing/G2PProcessor.swift — clean
ios/Runner/KokoroVendored/TextProcessing/Language.swift — clean
ios/Runner/KokoroVendored/TextProcessing/MisakiG2PProcessor.swift — clean
ios/Runner/KokoroVendored/TextProcessing/Tokenizer.swift — findings: 1
ios/Runner/KokoroVendored/TTSEngine/DurationEncoder.swift — clean
ios/Runner/KokoroVendored/TTSEngine/KokoroConfig.swift — findings: 1
ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift — findings: 2
ios/Runner/KokoroVendored/TTSEngine/ProsodyPredictor.swift — clean
ios/Runner/KokoroVendored/TTSEngine/TextEncoder.swift — clean
ios/Runner/KokoroVendored/TTSEngine/TimestampPredictor.swift — clean
ios/Runner/KokoroVendored/TTSEngine/WeightLoader.swift — clean
- [medium] ios/Runner/MisakiVendored/English/Lexicon/DataResourcesUtil.swift:21 — `loadSilver` looks up the lexicon JSON with `subdirectory: "Resources"`, but the Misaki resource group in `Runner.xcodeproj` is a plain `PBXGroup` whose individual files (`us_silver.json`, `gb_silver.json`) are added to the "Copy Bundle Resources" phase directly, so Xcode flattens them into the app bundle root (no `Resources/` subdirectory is created in the `.app`; `loadGold` correctly omits the subdirectory). `Bundle.main.url(forResource:withExtension:subdirectory:)` therefore returns nil and `loadSilver` silently returns `[:]` — the ~3 MB silver pronunciation dictionary is never loaded. Consequence: every word not in the gold lexicon falls through to `EnglishFallbackNetwork` (a full BART transformer forward pass per word, rated 1) instead of a dictionary lookup (rated 3), degrading pronunciation quality and adding a neural inference per word on the hot path. Smallest safe fix: drop the `subdirectory: "Resources"` argument so it matches `loadGold`.

- [low] ios/Runner/MisakiVendored/English/FallbackNetwork/EnglishFallbackNetwork.swift:17 — `configuration = EnglishFallbackNetwork.loadConfig(british: british)!` force-unwraps the optional (and the same on line 18 for `loadWeights(...)!`). Both loaders swallow failures with `try?` and return nil, so if the bundled `us_bart_config.json`/`us_bart.safetensors` are missing, stripped from the build, or corrupt, `EnglishFallbackNetwork.init` traps and crashes the app at startup instead of degrading gracefully. Smallest safe fix: make `init` failable (`init?`) or throw and have the caller fall back to lexicon-only G2P rather than force-unwrapping.

## Coverage
ios/Runner/KokoroVendored/Utils/AudioUtils.swift — clean
ios/Runner/MediaControlPlugin.swift — clean
ios/Runner/MemoryMonitorPlugin.swift — clean
ios/Runner/MisakiVendored/English/DataStructures/TokenContext.swift — clean
ios/Runner/MisakiVendored/English/EnglishG2P.swift — clean
ios/Runner/MisakiVendored/English/FallbackNetwork/BARTConfig.swift — clean
ios/Runner/MisakiVendored/English/FallbackNetwork/BARTDecoderLayer.swift — clean
ios/Runner/MisakiVendored/English/FallbackNetwork/BARTEncoderLayer.swift — clean
ios/Runner/MisakiVendored/English/FallbackNetwork/BARTLayerNorm.swift — clean
ios/Runner/MisakiVendored/English/FallbackNetwork/BARTModel.swift — clean
ios/Runner/MisakiVendored/English/FallbackNetwork/EnglishFallbackNetwork.swift — findings: 1
ios/Runner/MisakiVendored/English/FallbackNetwork/FeedForward.swift — clean
ios/Runner/MisakiVendored/English/FallbackNetwork/MultiHeadAttention.swift — clean
ios/Runner/MisakiVendored/English/Lexicon/DataResourcesUtil.swift — findings: 1
ios/Runner/MisakiVendored/English/Lexicon/Lexicon.swift — clean
ios/Runner/MisakiVendored/English/Lexicon/PennTagUtil.swift — clean
ios/Runner/MisakiVendored/English/Num2Word/EnglishNum2Word.swift — clean
ios/Runner/MisakiVendored/Extensions/MLXArray+DebugPrint.swift — clean
ios/Runner/MisakiVendored/Extensions/NLTag+ProperNoun.swift — clean
ios/Runner/MisakiVendored/Extensions/Range+Contains.swift — clean
# Batch 5 review

## Findings

- [medium] lib/data/repositories/production_repository.dart:175 — `saveScenes` deletes all scenes (`deleteScenesForProduction`, line 177) and re-inserts them (line 190) without a transaction — a crash or exception between the two statements permanently loses every scene for the production, the exact data-loss hazard `saveScriptLines` (same file) explicitly guards against with `_db.transaction` — wrap the delete+insert in `_db.transaction(() async { ... })`.

- [low] ios/Runner/PaddleOcrPlugin.swift:152 — the `scale` argument from the Dart contract is parsed (default 2.0) but never used; `ocrPdf(path:scale:result:)` ignores `scale` and computes `autoScale` from `targetRenderLongPx` instead — `PaddleOcrChannel.ocrPdf(scale:)` silently has no effect, breaking the `VisionOcrChannel` contract it claims to mirror (there `scale` controls render resolution), so callers cannot request a higher-fidelity render — honor `scale` (e.g. factor it into `autoScale`) or remove it from the channel contract and the Dart wrapper.

- [low] ios/Runner/PdfTextPlugin.swift:142 — `hasEmbeddedText` opens the PDF (`PDFDocument(url:)`) and extracts up to 3 pages of text synchronously on the platform main thread, unlike `extractText`/`extractTextPerPage` which dispatch to a background queue — probing a large PDF during import blocks the UI (jank/frozen frame) — wrap the body in `DispatchQueue.global(qos: .userInitiated).async` and deliver the result on the main queue, matching the other two handlers.

- [low] lib/data/models/cast_member_model.dart:8 — `CastRole.fromString` only special-cases `'actor'` and otherwise calls `CastRole.values.byName(s)`, which throws `ArgumentError` for any unrecognized string — a new or typo'd role string arriving from Supabase (reachable via `cast_manager_screen.dart:96/114` parsing `cm['role']`) crashes cast loading instead of degrading — default unknown roles to a safe fallback (e.g. `CastRole.primary`) rather than throwing.

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
lib/data/models/cast_member_model.dart — findings: 1
lib/data/models/production_models.dart — clean
lib/data/models/rehearsal_models.dart — clean
lib/data/models/script_models.dart — clean
lib/data/models/voice_preset.dart — clean
lib/data/repositories/production_repository.dart — findings: 1
# Pi sweep — batch 6 (lib/data/services)

## Findings

- [low] lib/data/services/media_control_service.dart:83 — the `onPlayPause` callback is dead code and the play/pause command is wired to jump back — `activate()` stores `onPlayPause` (line 31) and `deactivate()` clears it (line 50), but no code path ever invokes it: `_handleNativeCall` maps `case 'playPause'` to `onJumpBack?.call()`, contradicting the class doc ("Play/Pause → pause/resume"). The rehearsal screen wires `_handleRemotePlayPause`, so pause/resume via media controls silently never happens (and the native plugin, MediaControlPlugin.swift, only ever emits `"jumpBack"`, making `'playPause'`/`'skip'` unreachable in practice). — concrete consequence: a user tapping play/pause on AirPods/lock screen jumps back instead of pausing, and pause/resume via remote commands is impossible. — smallest safe fix: route `case 'playPause'` to `onPlayPause?.call()` (or delete the field and fix the doc comment to match the "everything → jump back" behavior).

- [low] lib/data/services/model_download_service.dart:579 — the Dart fallback download follows redirects without enforcing HTTPS, unlike the sibling `ModelManager._downloadFile` path that explicitly refuses https→http hops — `_dartDownload` creates a default `HttpClient` (followRedirects true, maxRedirects 5) and only checks `res.statusCode != 200`, so an https→http redirect on the live-ASR URLs is silently followed. — concrete consequence: a network attacker can force a downgrade so the (public, but integrity-critical) model bytes transit in cleartext; the post-download SHA-256 check still detects tampering, but the bytes are exposed and a MITM can DoS downloads by corrupting them. — smallest safe fix: set `client.followRedirects = false` and re-implement the bounded redirect loop with an `https`-scheme guard (reusing the logic from `model_manager.dart:_downloadFile`), or at minimum check each `res.isRedirect` location scheme before following.

## Coverage
lib/data/services/analytics_service.dart — clean
lib/data/services/audio_level_service.dart — clean
lib/data/services/contact_picker_service.dart — clean
lib/data/services/debug_log_service.dart — clean
lib/data/services/deep_link_service.dart — clean
lib/data/services/frame_stats_service.dart — clean
lib/data/services/kokoro_onnx_service.dart — clean
lib/data/services/live_asr_service.dart — clean
lib/data/services/media_control_service.dart — findings: 1
lib/data/services/model_download_service.dart — findings: 1
lib/data/services/model_manager.dart — clean
lib/data/services/ocr_confidence_service.dart — clean
lib/data/services/paddle_ocr_channel.dart — clean
lib/data/services/pdf_text_channel.dart — clean
lib/data/services/perf_service.dart — clean
lib/data/services/playback_session.dart — clean
lib/data/services/recording_sync_service.dart — clean
lib/data/services/script_export.dart — clean
lib/data/services/script_import_service.dart — clean
- [low] lib/data/services/supabase_service.dart:718 — `saveScriptLines` deletes all cloud `script_lines` for a production, then re-inserts in batches of 100 with no transaction or rollback — a network drop or a rejected batch leaves the cloud holding a truncated script (some scenes deleted, later batches never inserted); other devices that pull during that window receive an incomplete script — wrap delete+inserts in a single RPC/transaction, or upload into a staging set and swap, so a partial failure can't expose a half-written script.
- [low] lib/data/services/supabase_service.dart:44 — `init()` only catches `TimeoutException` around `await initFuture.timeout(...)`; if `Supabase.initialize` completes quickly with an error (e.g. malformed URL/key), that error is rethrown uncaught out of `init()` instead of the graceful offline fallback the timeout branch implements — startup surfaces a raw exception rather than degrading to offline mode — add an `on Object`/`catch` branch (mirroring the timeout path's `catchError`) that logs and leaves `_initialized` false.
- [low] lib/data/services/supabase_service.dart:485 — `lookupByJoinCode` logs the full RPC result (`value=$rpcResult`) to the persistent on-device debug log and console, including the production `join_code` and `organizer_id` — the join code is a standing access credential and its disclosure to a shared/exported log file lets anyone with the log join the production — log only the title/id (or a redacted summary), never the whole row.
- [nit] lib/data/services/stt_vocabulary_service.dart:127 — `clearProduction` removes the production's vocabulary and `_actorCorrections` but never clears `_correctionPatterns` (line 39), the singleton cache of learned-correction regexes — it grows for the lifetime of the process across every production/actor the app has ever seen — evict entries keyed by `$productionId:` or clear the map when a production is removed.
- [low] lib/data/services/sync_queue.dart:186 — the queue file is rewritten with a non-atomic `writeAsString` and `_loadPersisted` sets `_loaded = true` (line 203) before `jsonDecode`; a crash mid-write leaves a truncated JSON file that `jsonDecode` fails on next launch, after which the empty in-memory queue overwrites it — every previously queued recording upload is permanently lost — write to a temp file and rename atomically, and on parse failure do not let a subsequent persist clobber the file (or back it up before overwriting).
## Coverage
lib/data/services/script_parser.dart — clean
lib/data/services/stt_adaptation_service.dart — clean
lib/data/services/stt_channel.dart — clean
lib/data/services/stt_service.dart — clean
lib/data/services/stt_vocabulary_service.dart — findings: 1
lib/data/services/supabase_service.dart — findings: 3
lib/data/services/sync_queue.dart — findings: 1
# Batch 8 findings

- [low] lib/features/cast_manager/voice_config_screen.dart:145 — `_buildPresetTile.onChanged` calls `setState` after `await _voiceConfig.setPreset(...)` with no `mounted` guard (same pattern at :202 character-tile reset, :284 voice-dialog Save, :418 dialect selector) — if the screen is popped while the SharedPreferences write is in flight, `setState()` fires on a defunct State and throws "setState() called after dispose()" — add `if (!mounted) return;` before each post-await `setState`.
- [low] lib/features/cast_manager/voice_config_screen.dart:373 — `_previewVoice` calls `tts.assignVoice(characterName, 0, voiceId: voiceId, speed: speed)`, which permanently mutates the TTS singleton's per-character voice/speed maps (and system-voice/pitch maps at a hardcoded index 0) as a side effect of a "preview" — any `speak()` for that character that doesn't re-run the rehearsal `_assignVoices` path will speak in the previewed voice/speed instead of the configured one — restore the prior assignment after preview, or add a non-mutating `speak(voiceId:, speed:)` overload.
- [low] lib/features/cast_manager/cast_manager_screen.dart:886 — `_showInviteOptions` is never called anywhere; its helpers `_shareTextInvite` (:966), `_shareInviteCard` (:994) and `_InviteCardWidget` (:1323) are reachable only through it, so the entire "send text invite / invite card" feature is dead code — unreachable UI path and confusion about which invite flows exist — delete the block or wire `_showInviteOptions` to a caller.
- [low] lib/features/cast_manager/cast_manager_screen.dart:1073 — `_nudge` builds a `PendingJoin.buildUri` with `production?.joinCode ?? ''` without checking for an empty code — a production with a null/empty `joinCode` (e.g. restored from a cloud row with null `join_code`) yields `castcircle://join?code=`, which `PendingJoin.fromUri` rejects (code must match `^[A-Z0-9]{6}$`), so the reminder link is dead and the recipient gets the "invalid join code" toast — guard `code.isNotEmpty` and fall back to the join-code text, matching `_inviteActor` (:858).
- [low] lib/features/cast_manager/cast_manager_screen.dart:1246 — `_showVoiceSheet`'s Save (:1264) and Reset (:1246) handlers call `setState` after `await`ing `_voiceConfig.setOverride/removeOverride/getOverrides` without a `mounted` check on the State — navigating away mid-write triggers `setState() after dispose()` — add `if (!mounted) return;` before those `setState` calls.
- [low] lib/features/cast_manager/bulk_cast_setup_screen.dart:338 — `_showInviteLinksSheet` builds per-actor invite deep links from `production?.joinCode ?? ''` unguarded (:399) — a null/empty join code produces `castcircle://join?code=` links that `PendingJoin.fromUri` rejects, so every copied/shared invite silently fails — guard `joinCode.isNotEmpty` before building links (and hide the link-based invite when absent), as `_inviteActor` already does.
- [low] lib/features/home/home_screen.dart:461 — `_scriptsDiffer` (:461) and `_resolveCloudScript` (:466) are never called; the cloud-vs-local diff/merge flow they implement was superseded by `_refreshScriptFromCloud`/`_reconcileCloudScript`, leaving ~30 lines and the `cloud_sync_dialog.dart`/`diffScriptLines` import unused — dead path that suggests two competing sync flows to a future reader — remove both methods and the now-unused import.
- [low] lib/data/services/voice_clone_service.dart:1 — the entire `VoiceCloneService`/`VoiceProfile`/`VoiceCloneStatus` API is unreferenced outside this file (backend stubbed out with `isReady => false`); `buildProfileFromRecordings`, `generateLine`, `clearCache` and `_cachePath` have no call sites — dead code that can drift from the rest of the app — delete the file or leave a `// pi-review: unused` marker if a backend is planned.
- [nit] lib/features/auth/auth_screen.dart:422 — `_skipAuth` sets `authStateProvider` (documented as "tracks whether user is signed in") to `true` for a guest who has no Supabase session — the provider is currently write-only (only `settings_screen` resets it), so nothing breaks today, but the state misrepresents auth and will mislead any future reader that gates cloud calls on it — drop the line or rename/repurpose the provider to mean "auth gate passed".

## Coverage
lib/data/services/tts_service.dart — clean
lib/data/services/vision_ocr_channel.dart — clean
lib/data/services/voice_clone_service.dart — findings: 1
lib/data/services/voice_config_service.dart — clean
lib/features/auth/auth_screen.dart — findings: 1
lib/features/cast_manager/bulk_cast_setup_screen.dart — findings: 1
lib/features/cast_manager/cast_manager_screen.dart — findings: 3
lib/features/cast_manager/voice_config_screen.dart — findings: 2
lib/features/home/home_screen.dart — findings: 1
- [medium] lib/features/recording_studio/recordings_browser_screen.dart:360 — `Dismissible.onDismissed` calls async `_deleteRecording`, which awaits `file.delete()` (line 493) and `notifier.remove()` (line 504) before the row actually leaves `recordingsProvider` state, so the dismissed widget stays in the ListView across the resize-animation frames — Flutter throws "A dismissed Dismissible widget is still part of the tree." (debug) and the row can flash back before disappearing; additionally if the Drift/DB remove throws, the on-disk file is already gone but the DB row remains, leaving a dangling row whose playback fails — remove the item from the notifier's in-memory state synchronously inside `onDismissed` (before the first `await`), then do file/DB/cloud cleanup asynchronously.
- [low] lib/features/recording_studio/recording_studio_screen.dart:621 — `_startRecording` calls `setState(() => _status = RecordingStatus.recording)` with no `mounted` guard after the awaits at lines 571 (`hasPermission`), 581 (`getApplicationDocumentsDirectory`) and 592 (`_recorder.start`); tapping the studio's close button during the permission prompt or recorder start disposes the State and this `setState` throws "setState called after dispose" — add `if (!mounted) return;` before the timer/setState block (the rest of the file already guards every other post-await `setState`).
- [low] lib/features/join/join_production_screen.dart:437 — `final userId = supa.currentUser!.id;` force-unwraps the nullable `SupabaseService.currentUser` (returns null when uninitialized or the auth session has lapsed); the join button is only gated by `isSignedIn` at render time, so a session expiring between render and tap makes the join throw a raw "Null check operator used on a null value" surfaced to the user as "Failed to join: …" with no sign-in recovery — read `final user = supa.currentUser;` and bail out with a "please sign in again" message (or route to `/auth`) instead of force-unwrapping.
- [low] lib/features/onboarding/model_setup_screen.dart:156 — the settle-poll `while (mounted && !_voices.ready && _voices.error == null) { await Future.delayed(...500ms...); }` has no timeout; if the native iOS voice download stalls (no progress, no error, no completion) the loop spins forever, keeping `_downloading` true (button stays disabled) and the line-matching download after it never runs — bound the wait (e.g. a deadline of a few minutes or a max-iteration count) and set `_voices.error`/stop polling when exceeded.
## Coverage
lib/features/join/join_production_screen.dart — findings: 1
lib/features/onboarding/model_setup_screen.dart — findings: 1
lib/features/production_hub/production_hub_screen.dart — clean
lib/features/recording_studio/recording_character_screen.dart — clean
lib/features/recording_studio/recording_studio_screen.dart — findings: 1
lib/features/recording_studio/recordings_browser_screen.dart — findings: 1
lib/features/recording_studio/voice_profile_screen.dart — clean
lib/features/rehearsal/rehearsal_history_screen.dart — clean
# Pi review — batch 10

## Findings

- [high] lib/features/script_editor/character_manager_screen.dart:755 — `_rebuildScript` (reached from `_applyDelete` at :713) rebuilds scenes' `characters` but never remaps `ScriptScene.startLineIndex`/`endLineIndex` after `_applyDelete` removes lines — deleting a character removes its dialogue lines, which shifts every subsequent line's list position, so each scene after the deletion keeps stale positional bounds and `ParsedScript.linesInScene` (positional `sublist`) returns the wrong dialogue slice; rehearsal then plays lines from a different part of the play (the exact "lines out of order in rehearsal" failure `ParsedScript.remapScenes` was written to prevent). Note the same block also compares `line.orderIndex` against positional `scene.startLineIndex`/`endLineIndex`, which is only accidentally correct while no lines have been deleted. — Smallest safe fix: replace the manual `updatedScenes` map in `_rebuildScript` with `final updatedScenes = ParsedScript.remapScenes(script.scenes, script.lines, updatedLines);` (then recompute each scene's `characters` from `updatedLines.sublist(scene.startLineIndex, scene.endLineIndex + 1)` if needed) so bounds track the new line list.

- [low] lib/features/rehearsal/rehearsal_screen.dart:2658 — `_handleRemoteJumpBack` computes `final jumpCount = (current - target).clamp(1, current);` which throws `ArgumentError` when `current == 0` (lowerLimit 1 > upperLimit 0) — an AirPods/lock-screen jump-back tap while the rehearsal is on the first line raises an unhandled exception and the jump-back action does nothing (the `_jumpBackInProgress` flag also swallows the next tap for 500 ms). — Smallest safe fix: guard the actor-line branch with `if (current == 0) return;` (or compute `final jumpCount = current > 0 ? (current - target).clamp(1, current) : 0;`) so line 0 is treated as "nothing to jump back to".

- [low] lib/features/script_editor/cloud_sync_dialog.dart:36 — `diffScriptLines`'s `same` check compares only `character`, `text`, `lineType`, and `stageDirection`, omitting `multiCharacters` (and `act`/`scene`/`orderIndex`), so a cloud change that only alters an ensemble line's speaker list or a scene tag is displayed as "unchanged" and excluded from the changes list — the organizer sees "No changes detected"/a wrong summary and may keep a stale local script that other cast members (whose lines are matched by `isForCharacter`/scene grouping) would have corrected. — Smallest safe fix: include `multiCharacters` (and the positional/tag fields) in the equality check, e.g. `loc.multiCharacters` list equality plus `loc.scene == cld.scene && loc.act == cld.act`.

## Coverage

lib/features/rehearsal/rehearsal_screen.dart — findings: 1
lib/features/script_editor/character_manager_screen.dart — findings: 1
lib/features/script_editor/cloud_sync_dialog.dart — findings: 1
lib/features/script_editor/scene_editor_screen.dart — clean
- [low] lib/features/script_import/script_import_screen.dart:427 — After the OCR review pass, `_preview` reuses `script.characters` unchanged while `result.lines` may have had lines removed — a character whose only line(s) were removed stays in the cast list and every `lineCount`/`colorIndex` is stale — cast list and "N lines" figures shown after Accept are wrong until the script is reloaded from the DB (where `loadPersistedScript` recomputes them). Fix: rebuild the character list from `result.lines` (the same `charCounts` logic used in `buildParsedScript`/`loadPersistedScript`) instead of passing `script.characters`.
- [low] lib/main.dart:125-140 — On every iOS launch until models are present, the app auto-downloads ~178 MB (Kokoro model 163 MB + voices 14 MB) in a microtask with no user consent, no Wi-Fi/connectivity gate, and failures only `debugPrint`ed — a user on cellular data is hit with a large surprise download on first launch. Fix: gate the auto-download on connectivity/Wi-Fi and/or ask the user first, and surface download failure via the debug log or a toast.
- [low] lib/firebase_options.dart:52-65 — Firebase client API keys (iOS/Android) are committed to git (tracked, in history). These are project identifiers rather than secrets, but with no App Check or API-key restrictions enabled, anyone who extracts them can abuse the project's Firebase Auth/Storage/analytics quota. Fix: enable Firebase App Check and add API-key application restrictions in the GCP console (keys stay in the client bundle by design; this is about restricting abuse, not removing them).
- [nit] lib/features/script_editor/script_editor_screen.dart:590 — `final insertAt = toIdx > fromIdx ? toIdx : toIdx;` is a tautology (both branches are `toIdx`), so the intended `toIdx - 1` adjustment for the "moved down" case was never implemented — dead conditional that misleads readers about the reorder off-by-one handling (the current `toIdx` value happens to be correct in both directions after the `newIndex--` adjustment, so this is not a functional bug). Fix: replace with `final insertAt = toIdx;` (or restore the intended `toIdx > fromIdx ? toIdx - 1 : toIdx` if the adjustment is ever needed).
- [low] lib/features/script_import/ocr_review_screen.dart:293 — The in-app back arrow and "Done" button both call `_done()` (pop with `OcrReviewResult`), but the system back gesture/button pops the route with `null`, and the caller (`_openReview`) treats `null` as "no changes" — all edits and removals made in the review screen are silently discarded with no confirmation. Fix: wrap with `PopScope`/`onPopInvoked` to call `_done()`, or make the caller treat a null result as a commit of the current state.

## Coverage
lib/features/script_editor/script_editor_screen.dart — findings: 1
lib/features/script_editor/validation_panel.dart — clean
lib/features/script_import/ocr_review_screen.dart — findings: 1
lib/features/script_import/pdf_page_view.dart — clean
lib/features/script_import/script_import_screen.dart — findings: 1
lib/features/settings/ai_models_screen.dart — clean
lib/features/settings/debug_log_screen.dart — clean
lib/features/settings/kokoro_debug_screen.dart — clean
lib/features/settings/model_download_screen.dart — clean
lib/features/settings/settings_screen.dart — clean
lib/firebase_options.dart — findings: 1
lib/main.dart — findings: 1
# Batch 12 review findings

- [medium] macos/Runner/VisionOcrPlugin.swift:97 — `let scale = args["scale"] as? Double ?? 2.0` is multiplied directly into the bitmap dimensions (`width = bounds.width * CGFloat(scale)`, `height = bounds.height * CGFloat(scale)`) with no upper bound, and `renderPage` then calls `CGContext(data:width:height:...)` at those dimensions. A scale value from a buggy/malicious Dart caller (e.g. `1000.0`) makes the app allocate a multi-hundred-MB (or larger) bitmap per page, exhausting memory and crashing the process mid-OCR. — Smallest safe fix: clamp `scale` to a sane range before use, e.g. `let scale = min(max(args["scale"] as? Double ?? 2.0, 0.5), 4.0)`.

- [low] lib/providers/production_providers.dart:533 — `LineType.values.byName(row['line_type'] as String? ?? 'dialogue')` throws `ArgumentError` if the cloud returns any `line_type` string not in the current enum (e.g. written by a newer app version that introduced a new `LineType`, or a malformed/legacy row). Because the throw happens inside the single `try` block that wraps the whole `rows.map(...)`, one unrecognized value aborts the entire `fetchCloudScriptLines` call, which then returns `null` — the user gets no script at all instead of the other valid lines. — Smallest safe fix: map defensively, e.g. `LineType.values.asNameMap()[row['line_type']] ?? LineType.dialogue` (or a helper that falls back instead of throwing), so a single bad value degrades to one line rather than the whole fetch.

- [low] lib/providers/production_providers.dart:319 — `_scriptSaveTimer = Timer(delay, () => _runScriptSave(ref))` captures the caller's `WidgetRef` in a timer closure that survives past the scheduling widget's lifecycle. If the editor is disposed before the 800ms debounce fires and the dispose path does not call `flushScriptSave`, `_runScriptSave` calls `ref.read(...)` on a defunct `WidgetRef`, throwing a `StateError` and dropping the pending save. The same stale-ref risk applies to the `unawaited(_runScriptSave(ref))` re-queue at line ~350. — Smallest safe fix: have the timer callback re-read from a `Ref`/container (provider-side reference) or guard with `ref.mounted`/cancel the timer on widget dispose, instead of holding a raw `WidgetRef` past its lifetime.

- [low] lib/providers/production_providers.dart:446 — `Future(() async { ... })` (the background sync launched by `launchRecordingSync`) is fire-and-forget with no `try/catch` or `.catchError`. If `hydrateCache()`, `getCachedRecordings`, or `syncForProduction` throws (network failure, malformed cache file), the error becomes an unhandled async exception in the zone — surfaced as a crash in debug and an unannotated Crashlytics report in release, with no user feedback that sync failed. — Smallest safe fix: wrap the body in `try { ... } catch (e) { DebugLogService.instance.logError(...) }` so sync failures are logged and contained.

- [low] scripts/fetch-ort-java.sh:14 — `curl -sfL -o "$TMP/ort.aar" "$URL"` downloads a prebuilt binary AAR and the extracted `.so` files are copied straight into `android/app/src/main/jniLibs/`, but the checksum is only printed (`shasum` at line 15), never verified against a pinned expected value. A compromised or substituted Maven artifact would inject arbitrary native code into the app with no automated rejection. — Smallest safe fix: hardcode the expected SHA-256 for the pinned version and fail the script (`sha256sum -c`) when it mismatches.

- [nit] macos/RunnerTests/RunnerTests.swift:7 — `testExample()` has an empty body and asserts nothing; it always passes and exercises no application code, so it provides no regression protection. — Smallest safe fix: replace with a real test of the native plugin channel/AppDelegate behavior, or delete the placeholder if it is intentionally unused.

## Coverage
lib/providers/production_providers.dart — findings: 3
linux/flutter/generated_plugin_registrant.cc — clean
linux/flutter/generated_plugin_registrant.h — clean
linux/runner/main.cc — clean
linux/runner/my_application.cc — clean
linux/runner/my_application.h — clean
macos/Flutter/GeneratedPluginRegistrant.swift — clean
macos/Runner/AppDelegate.swift — clean
macos/Runner/BackgroundDownloadPlugin.swift — clean
macos/Runner/MainFlutterWindow.swift — clean
macos/Runner/MemoryMonitorPlugin.swift — clean
macos/Runner/PdfTextPlugin.swift — clean
macos/Runner/VisionOcrPlugin.swift — findings: 1
macos/RunnerTests/RunnerTests.swift — findings: 1
pubspec.yaml — clean
scripts/compare_macbeth_versions.py — clean
scripts/deploy.sh — clean
scripts/fetch-ort-java.sh — findings: 1
scripts/generate_rehearsal_webp.sh — clean
scripts/generate_screenshots.sh — clean
- [medium] supabase/migrations/20260319000001_join_flow_rpc_v2.sql:54 — `claim_cast_invitation(member_id)` is SECURITY DEFINER and sets `user_id = auth.uid()` on any row where `user_id IS NULL`, with no check that the caller is the person the invitation was created for — any authenticated user who learns an unclaimed member id can steal/claim any role; `fetch_cast_for_join` (line 19) returns every cast row's `id` + `user_id`, so a legitimate member of a production can enumerate and claim *all* unclaimed invitations, locking out the actors they were meant for — fix: verify the caller matches the invitation's intended identity (e.g. store an email on the invitation and require `auth.email() = it`) or require organizer confirmation before binding `user_id`.

- [low] supabase/migrations/20260319000001_join_flow_rpc_v2.sql:32 — `join_production(prod_id, ...)` is SECURITY DEFINER and inserts the caller into any production given only its uuid; it never verifies the join code, so the entire join-code gate collapses to "unguessable uuid" — anyone who obtains a production uuid (e.g. a member of that production, or via `lookup_production_by_join_code` for a code they've seen) can self-join without the code — fix: accept and verify the join code inside the RPC (the lockdown migration even notes this is "tracked separately" as a known gap).

- [low] supabase/migrations/20260319000001_join_flow_rpc_v2.sql:19 — `fetch_cast_for_join(prod_id)` is SECURITY DEFINER with no membership/ownership check and is `GRANT ... TO authenticated`; any authenticated caller who knows a production uuid can enumerate the full roster (ids, display names, user_ids) of a production they don't belong to — this is the data source that makes the `claim_cast_invitation` hole exploitable — fix: gate it with `public.is_production_member(prod_id::uuid, auth.uid())` or require the join code.

- [medium] scripts/parse_script.py:385 — `__main__` hardcodes absolute output paths `"/home/user/Lineguide-/examples/..."` for the parsed markdown/JSON; on any machine other than that one Linux checkout (including the macOS dev host) the write either raises `PermissionError` (can't create `/home/user`) or silently writes outside the repo, so the "reference implementation" run fails after doing all the parsing work — fix: derive the repo root via `os.path.dirname(os.path.dirname(os.path.abspath(__file__)))` (exactly as `scripts/generate_test_export.py` does) instead of a hardcoded `/home/user/Lineguide-`.

- [low] supabase/migrations/20260315_cast_join_code.sql:10 — the join-code backfill uses `upper(substr(md5(random()::text), 1, 6))`, yielding 6 hex chars (alphabet `0-9A-F`, ~16.7M codes) for every pre-existing production, versus the ~1B-code alphabet of `generate_join_code()`; those legacy productions keep brute-forceable codes, and `lookup_production_by_join_code` (SECURITY DEFINER, granted to `authenticated`/`anon`) is not rate-limited, so codes can be guessed online — fix: re-roll backfilled codes with `public.generate_join_code()` instead of the 6-char hex fragment.

- [low] supabase/migrations/20260314061409_initial_schema.sql:133 — `recordings` UPDATE policy "Users can update own recordings" is `using (auth.uid() = user_id)` with no `with check` and no membership check; the new row is unconstrained, so a user can reassign their own recording's `user_id` to another user, move it to a different `production_id`, or repoint `audio_url`, and can keep updating rows in productions they've left (the later lockdown fixed only the INSERT policy, not this UPDATE) — fix: add `with check (auth.uid() = user_id and public.is_production_member(production_id, auth.uid()))`.

- [low] supabase/config.toml:175 — `minimum_password_length = 6` with `password_requirements = ""` permits trivially weak passwords for accounts that can reach other members' voice recordings, scripts, and `cast_members.contact_info` — fix: raise the minimum to 8+ and set a `password_requirements` value (the Supabase docs comment in the file itself recommends 8 or more).

- [low] scripts/ship-play.sh:33 — the debug-signing sanity check hardcodes `unzip -p "$AAB" 'META-INF/UPLOAD.RSA'`, which only exists if the signing key's JAR-signature entry is literally named `UPLOAD.RSA`; with a differently-named alias (the repo's key is `castcircle-upload.jks`) or v2-only bundle signing, `OWNER` comes back empty and the guard silently prints "signed: unknown" and proceeds, so a debug-signed AAB would not be caught by the check whose sole job is to catch it — fix: verify the signer with `apksigner verify --print-certs` or match the cert against the alias in `android/key.properties` rather than a fixed filename.

- [nit] scripts/ship-testflight.sh:36 — hardcodes the App Store Connect API key ID and issuer ID as literals in a git-tracked script; the actual signing secret (the `.p8`) is correctly external under `~/.appstoreconnect/`, so this is not directly exploitable, but the credential identifiers don't belong in committed code — fix: read `KEY`/`ISSUER` from environment variables (or a git-ignored file) at runtime.

- [nit] scripts/phone-harness.sh:13 — `set -uo pipefail` deliberately omits `-e`; a failed `adb push` or a missing model file in the `for f in encoder.onnx ...` copy loop does not abort the script, so an incomplete model pack is pushed and the harness still proceeds to `wait` and print `PROBE` metrics from a broken run, masking the failure as test output — fix: use `set -euo pipefail` and add an explicit existence check for each model file before the copy loop.

- [nit] supabase/migrations/20260319100001_add_locale.sql:3 — re-adds the `locale` column that `20260319100000_add_voice_preset.sql` already added; `IF NOT EXISTS` makes it a harmless no-op, but the duplicate migration is dead/confusing change that should not ship — fix: delete this migration file (the column is already covered by the preceding migration).

## Coverage
scripts/generate_test_export.py — clean
scripts/parse_script.py — findings: 1
scripts/pdf_to_script.py — clean
scripts/phone-harness.sh — findings: 1
scripts/pull-crashlog.sh — clean
scripts/pull-debuglog.sh — clean
scripts/ship-play.sh — findings: 1
scripts/ship-testflight.sh — findings: 1
scripts/verify-apk-ort.sh — clean
supabase/config.toml — findings: 1
supabase/migrations/20260314061409_initial_schema.sql — findings: 1
supabase/migrations/20260314120000_add_script_lines.sql — clean
supabase/migrations/20260314130000_fix_cast_members_rls.sql — clean
supabase/migrations/20260314140000_fix_rls_recursion.sql — clean
supabase/migrations/20260315_cast_join_code.sql — findings: 1
supabase/migrations/20260316_join_code_default.sql — clean
supabase/migrations/20260318_add_join_code_policy.sql — clean
supabase/migrations/20260319000001_join_flow_rpc_v2.sql — findings: 3
supabase/migrations/20260319100000_add_voice_preset.sql — clean
supabase/migrations/20260319100001_add_locale.sql — findings: 1
# Pi sweep — batch 14

## Findings

- [medium] supabase/migrations/20260703140000_security_lockdown.sql:115 — "Users insert own membership" INSERT policy checks only `auth.uid() = user_id` and does not restrict `role`, so the point-9 fix (`member_role := 'actor'` in join_production RPC) is bypassable via a direct table INSERT: any authenticated user who learns a production UUID (e.g. via lookup_production_by_join_code) can insert a cast_members row for themselves with role='organizer' (or any value the CHECK constraint allows), defeating the migration's own "never let a self-joiner mint an elevated role" guarantee. — concrete consequence: role elevation via the direct-table path even though the RPC path was hardened (DB-side RLS ignores cast_members.role, but any client logic trusting role is defeated). — smallest safe fix: add a role restriction to the policy, e.g. `with check (auth.uid() = user_id and role = 'actor')`, or add a trigger that forces role='actor' for non-organizer inserts.

- [medium] tool/orphan_sweep.dart:31 — the sweep enumerates productions with `c.from('productions').select(...)` using an authenticated throwaway account, but after 20260703140000 (drop of the permissive SELECT policies) + 20260703160000 (drop "Anyone can lookup by join code") the only remaining productions SELECT policies are organizer/member-scoped, so this query returns 0 rows for a fresh throwaway account and the tool silently prints "0 productions" and reports nothing. — concrete consequence: orphaned recordings are no longer detectable; the sweep is a silent no-op. — smallest safe fix: run the listing with the service-role key (bypasses RLS) or add a dedicated SECURITY DEFINER admin RPC that enumerates productions.

- [low] supabase/migrations/20260703100000_purge_test_productions.sql:5 — the cleanup DELETE filters only by a hardcoded UUID list and never checks `organizer_id`, contradicting the comment's guarantee ("organizer accounts … only; other users' productions untouched"). If any of the 44 hardcoded UUIDs belongs to a non-owner (or the list drifts over time), real productions and their cascaded children are deleted with no ownership guard. — concrete consequence: destructive deletion of data without the ownership check the comment promises. — smallest safe fix: add `and organizer_id in ('9c166be7-…','0cfa0ca8-…')` to the WHERE clause.

- [low] supabase/migrations/20260320200000_add_debug_reports.sql:17 — the INSERT policy uses `WITH CHECK (true)`, so any authenticated user can insert a debug_reports row with an arbitrary `user_id` (including another user's id) and arbitrary `user_email`/`content`. After the lockdown the SELECT policy is `auth.uid() = user_id`, so a planted row is shown to the victim as one of "their own" reports. — concrete consequence: forged debug reports attributable to another user's account (user_id is visible to castmates via cast_members reads). — smallest safe fix: change to `with check (auth.uid() = user_id)`.

- [low] tool/orphan_sweep.dart:22 — the tool signs up a throwaway `…@example.com` account on every run and only deletes its cast_members rows, never the auth.users (and trigger-created profiles) row; the same pattern is in tool/analyze_orphaned_recordings.dart and tool/verify_cloud_recordings.dart. — concrete consequence: each run leaves an orphaned auth.users + profiles row in production (the team already had to write 20260703090000 to purge these). — smallest safe fix: delete the auth.users account (admin/service-role API) during cleanup, or reuse one dedicated audit account.

- [low] tool/verify_cloud_recordings.dart:20 — the `joinCode` argument is parsed and printed but never used: the tool self-inserts a cast_members row directly instead of exercising lookup_production_by_join_code, so it cannot detect a regression in the join-by-code path it claims to verify and silently accepts a wrong/expired code. — concrete consequence: a broken join-code flow goes undetected by this "verify" tool; users are misled into thinking the code path was validated. — smallest safe fix: resolve the production via `lookup_production_by_join_code` (and verify the id matches) before self-joining, or drop the unused argument.

- [nit] tool/sim_multi_user.dart:85 — the `if (aUserId == bUserId)` guard is duplicated verbatim (lines 81 and 85), so the second block is dead code. — concrete consequence: copy-paste dead code that can drift. — smallest safe fix: remove the duplicate block.

## Coverage
supabase/migrations/20260320200000_add_debug_reports.sql — findings: 1
supabase/migrations/20260701090000_add_multi_characters.sql — clean
supabase/migrations/20260703090000_leave_policy_and_audit_cleanup.sql — clean
supabase/migrations/20260703100000_purge_test_productions.sql — findings: 1
supabase/migrations/20260703140000_security_lockdown.sql — findings: 1
supabase/migrations/20260703150000_fix_helper_grants.sql — clean
supabase/migrations/20260703160000_drop_last_productions_readall.sql — clean
supabase/migrations/20260703170000_recordings_delete_policy.sql — clean
supabase/migrations/20260801130000_cast_members_rls_index.sql — clean
tool/analyze_orphaned_recordings.dart — clean
tool/orphan_sweep.dart — findings: 2
tool/parse_stats.dart — clean
tool/sim_multi_user.dart — findings: 1
tool/verify_cloud_recordings.dart — findings: 1
tools/mlx-harness/link-sources.sh — clean
tools/mlx-harness/Package.swift — clean
tools/mlx-harness/Sources/harness/main.swift — clean
# Pi sweep — batch 15

## Findings

- [low] scripts/test_silence_trim.swift:124 — `try! Data(contentsOf: URL(string: path)!)` force-unwraps the URL and force-tries the network fetch — any malformed URL or transient download failure crashes the script with a fatal error instead of a usable message — replace with `guard let url = URL(string: path), let data = try? Data(contentsOf: url) else { print("..."); exit(1) }`.

- [nit] scripts/test_pdf_import.swift:39 — `guard page < doc.pageCount` validates only the upper bound, so `--page -1` (or any negative) passes the guard, `doc.page(at:)` returns nil, and the script silently exits 0 with no output — add `guard page >= 0` to the guard.

- [low] integration_test/ocr_import_macos_test.dart:25 — the committed `sample-scripts/Pride-Prejudice-SCRIPT.pdf` is referenced by an absolute path rooted at `/Users/jasontitus/experiments/CastCircle`, so the test fails to find the file on any other checkout or CI machine — resolve relative to the repo root (e.g. via `Platform.environment`/a test asset) instead of a hardcoded home-dir path.

- [low] integration_test/ocr_dump_macos_test.dart:23 — same absolute-path defect as ocr_import_macos_test.dart: the committed sample PDF is hardcoded under `/Users/jasontitus/experiments/CastCircle`, breaking the test on any other machine — use a repo-relative path.

- [nit] integration_test/asr_streaming_macos_test.dart:17 — `_repo` hardcodes the author's home directory (`/Users/jasontitus/experiments/CastCircle`), making the model staging path non-portable and non-reproducible outside the author's machine — derive the repo path from the environment or document the requirement explicitly.

- [nit] integration_test/asr_testwav_transcript_macos_test.dart:10 — `_dir` hardcodes `/Users/jasontitus/experiments/CastCircle/.asr-eval/kroko`; the test only runs on the author's machine — use an environment variable or relative path for the staging dir.

- [nit] integration_test/kokoro_pack_smoke_macos_test.dart:13 — `_eval` hardcodes `/Users/jasontitus/experiments/CastCircle/.asr-eval`, tying the pack/ASR staging dir to one machine — resolve from a config/env instead.

- [nit] integration_test/tts_kokoro_compare_macos_test.dart:20 — `_eval` hardcodes `/Users/jasontitus/experiments/CastCircle/.asr-eval`; non-portable model staging path — use an env-var/config-derived location.

## Coverage
dart_test.yaml — clean
integration_test/android_kokoro_rtf_test.dart — clean
integration_test/android_kokoro_service_test.dart — clean
integration_test/android_live_matching_test.dart — clean
integration_test/android_paddle_ocr_test.dart — clean
integration_test/android_rehearsal_harness_test.dart — clean
integration_test/asr_streaming_macos_test.dart — findings: 1
integration_test/asr_testwav_transcript_macos_test.dart — findings: 1
integration_test/kokoro_pack_smoke_macos_test.dart — findings: 1
integration_test/kokoro_service_queue_macos_test.dart — clean
integration_test/ocr_dump_macos_test.dart — findings: 1
integration_test/ocr_import_macos_test.dart — findings: 1
integration_test/rehearsal_demo_test.dart — clean
integration_test/screenshot_test.dart — clean
integration_test/tts_kokoro_compare_macos_test.dart — findings: 1
scripts/test_pdf_import.swift — findings: 1
scripts/test_silence_trim.swift — findings: 1
test_driver/integration_test.dart — clean
test/analytics_route_observer_test.dart — clean
test/cast_member_test.dart — clean
- [medium] test/parser_accuracy_test.dart:28 — `parseFile` prints "SKIP" and returns null when a fixture is missing, and every test body does `if (s == null) return;` — the entire accuracy suite passes green while asserting nothing whenever `sample-scripts/*.txt` files are absent (wrong CWD, sparse checkout, moved fixtures) — replace the silent `return null`/`if (s == null) return` with a `fail('fixture missing: $filename')` so missing data fails loudly instead of producing a false-green run.
- [low] test/parser_accuracy_test.dart:293 — the "Generate parser accuracy report" test writes to `sample-scripts/PARSER_ACCURACY_REPORT.md` (git-tracked, confirmed via `git ls-files`), embedding `DateTime.now()` at line 290 — every `flutter test --tags extended` run rewrites a committed file, dirtying the working tree and producing a non-reproducible timestamped diff in CI — write the report to a temp/gitignored path (or omit the timestamp) so running tests never mutates tracked files.
- [low] test/ocr_confidence_mapping_test.dart:48 — the confidence assertions use `closeTo(0.80, 0.2)` (and `closeTo(0.90, 0.2)` at line 55), which accepts any value in ~[0.6, 1.0]; this means the 0.99 speaker-name-line confidence (or any wrong raw line) still passes, so the test does not actually enforce its stated contract that the parsed line's confidence comes from the 0.80 body line rather than the consumed "HAMLET." cue — tighten the delta (e.g. `closeTo(0.80, 0.05)`) so an incorrect raw-line mapping fails.

## Coverage
test/cast_role_test.dart — clean
test/cloud_sync_dialog_test.dart — clean
test/dialog_navigation_test.dart — clean
test/gender_inference_test.dart — clean
test/home_screen_logic_test.dart — clean
test/model_manager_test.dart — clean
test/models_test.dart — clean
test/ocr_cleanup_test.dart — clean
test/ocr_confidence_mapping_test.dart — findings: 1
test/ocr_confidence_test.dart — clean
test/parser_accuracy_test.dart — findings: 2
test/parser_edge_cases_test.dart — clean
test/pdf_export_test.dart — clean
test/pdf_import_test.dart — clean
test/pp_ocr_attribution_test.dart — clean
test/production_repository_test.dart — clean
test/recording_path_safety_test.dart — clean
test/recording_sync_service_test.dart — clean
test/rehearsal_models_test.dart — clean
test/running_header_test.dart — clean
# Batch 17 findings

- [medium] test/supabase_join_test.dart:17 — `setUpAll` POSTs a real `auth/v1/signup` against the production Supabase project (URL + publishable key hardcoded at lines 10-11) on every test run — pollutes the production `auth.users` table with a throwaway account per run and makes the suite non-hermetic (fails without network) — replace the live signup with a stubbed auth token, or move the whole file behind an opt-in integration tag that is never run against prod.
- [medium] test/supabase_service_test.dart:13 — `Supabase.initialize` targets the production project and `setUpAll` calls `auth.signUp` on each run (lines 13-26) — creates junk accounts in production and the test depends on live network and a specific pre-existing join code, so it is neither hermetic nor offline-safe — initialize against a local/mock Supabase or gate the test behind an explicit integration tag.
- [low] test/stt_vocabulary_service_test.dart:32 — `test('extracts important vocabulary words', ...)` has no `expect()` assertion (only a comment) — the test can never fail, so regressions in vocabulary/important-word extraction go undetected — add assertions on which words are marked important.
- [low] test/stt_vocabulary_service_test.dart:44 — `test('ignores stage directions', ...)` has no `expect()` assertion (only a comment) — it can never fail, so stage-direction text leaking into the vocabulary would pass silently — assert that the direction text is absent from the built vocabulary.
- [low] test/tts_text_chunking_test.dart:3 — the test re-implements the private `TtsService._splitTextForKokoro` algorithm rather than calling the production method (comment admits this) — it verifies a copy, so a regression in the real chunker won't be caught — expose the method via `@visibleForTesting` (or an internal test hook) and test the actual implementation.
- [low] test/sample_script_test.dart:28 — every sample-script test opens with `if (!file.existsSync()) return;` (11 occurrences, e.g. lines 28, 39, 49, 63, 84, 92, 111, 132, 151, 159) — a missing/corrupted sample file makes the test PASS while asserting nothing, instead of being reported skipped — use `markTestSkipped(...)`.
- [low] test/shakespeare_import_test.dart:697 — the full-file tests silently `return` when the fixture is missing (lines 697 and 743) — absent sample files report green while validating nothing — use `markTestSkipped(...)`.
- [nit] test/sharing_test.dart:774 — `test('large script diff performance', ...)` asserts `Stopwatch.elapsedMilliseconds < 1000` — a wall-clock assertion is inherently flaky on loaded CI and can fail spuriously without a real regression — drop the timing assertion (the surrounding correctness assertions already cover the diff behavior).

## Coverage
test/sample_script_test.dart — findings: 1
test/scene_partition_test.dart — clean
test/scene_remap_test.dart — clean
test/script_parser_import_test.dart — clean
test/shakespeare_import_test.dart — findings: 1
test/sharing_test.dart — findings: 1
test/stt_adaptation_test.dart — clean
test/stt_service_test.dart — clean
test/stt_vocabulary_service_test.dart — findings: 2
test/supabase_join_test.dart — findings: 1
test/supabase_service_test.dart — findings: 1
test/sync_queue_test.dart — clean
test/toast_autodismiss_test.dart — clean
test/tts_service_test.dart — clean
test/tts_text_chunking_test.dart — findings: 1
test/voice_clone_test.dart — clean
test/voice_config_test.dart — clean
test/widget_test.dart — clean
- [low] lib/data/services/script_import_service.dart:484 — `byteData.buffer.asUint8List()` ignores `byteData.offsetInBytes`/`lengthInBytes`, so if the `ui.Image.toByteData` result is a view into a larger backing buffer (the documented, non-guaranteed-contract case), trailing garbage bytes are written into the reused `ocr_page.png` temp file — ML Kit OCR fails to recognize that page, silently incrementing `failedPages` and dropping script content — write `byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes)` instead.
- [nit] lib/data/services/script_import_service.dart:603 — `sourceLineOnPage` is always set to `0` (both in `parseAndMapOcr` at :603 and `_findSourcePageFrom` at :637, which returns `lineOnPage: 0`), contradicting the `ScriptLine` field's documented "1-based line within that page" contract — every persisted page reference renders as `pN:0` and `ParsedScript.indexForRef(page, lineOnPage)` can never match a real line number, so it silently falls back to the 42-lines-per-page heuristic — populate the actual on-page line index (or store the raw-line index delta per page) instead of the constant 0.
## Coverage
lib/data/services/script_parser.dart — clean
lib/data/services/tts_service.dart — clean
lib/features/production_hub/production_hub_screen.dart — clean
lib/data/services/script_import_service.dart — findings: 2
# Pi sweep — batch 19

## Findings

- [medium] ios/Runner/AppleSttPlugin.swift:382 — `stopRecording` sets `audioFile = nil` (closing/deallocating the CAF file) on the main thread without first stopping the audio engine or removing the tap, while the `AVAudioNodeTapBlock` (line 272) concurrently reads `self?.audioFile` and calls `file.write(from:)` from the audio thread — data race on `audioFile` (also `recordingPath`/`recordingStartTime`, and the tap block itself mutates `self?.audioFile = nil` at line 277) can crash via non-atomic reference access and/or leave the CAF being converted while the tap is still writing, producing a truncated/corrupted take — smallest safe fix: stop the engine and remove the tap (`stopCurrentSession()`, or at least `audioEngine.stop()` + `inputNode.removeTap(onBus: 0)`) before mutating `audioFile`, or serialize `audioFile` access on a single thread/queue before closing and converting.
- [low] ios/Runner/AppleSttPlugin.swift:484 — `detectSpeechRange` hardcodes `sampleRate = 44100.0` to size its 50ms RMS windows and then computes trim `CMTime`s as `windowIndex * 0.05` s, but the actual mic tap format is frequently 48 kHz; when the true rate differs, each "50ms" window is ~45.9ms so the trim boundaries drift proportionally to the number of leading/trailing silence windows, and a long leading silence can shift the start past the intended 150ms padding and clip the first speech edge (or leave tail silence) — smallest safe fix: derive the sample rate from the asset's audio track (`track.naturalTimeScale`/format) instead of a constant, and compute window duration from that rate.

## Coverage
lib/data/services/recording_sync_service.dart — clean
ios/Runner/AppleSttPlugin.swift — findings: 2
ios/Runner/MisakiVendored/English/Lexicon/Lexicon.swift — clean
ios/Runner/MisakiVendored/English/EnglishG2P.swift — clean
# Batch 20 findings

## Findings
- [medium] lib/features/script_editor/scene_editor_screen.dart:399 — Scene edits (rename via `_updateScene`, and `_performSplit`/`_performMerge` at 481/515) persist scene metadata only locally — `scheduleScriptSave` → `persistScript` → `persistScriptLocally` (Drift `saveScenes`) while `pushScriptToCloud` in production_providers.dart sends only `script.lines`, never scenes. On any cloud pull (`fetchCloudScriptLines` → `buildParsedScript` → `_buildScenesFromLines`), scenes are regenerated from each line's `act|scene` tag, so the organizer's custom `sceneName` (the entire point of this screen), `description`, and scene `id`s are silently discarded/regenerated. Concrete consequence: cast members pulling the script (and a reinstall/restore of the organizer's own device) lose every scene rename/description, and anything keyed by scene id changes identity. Smallest safe fix: push scene rows (id/act/name/location/description/bounds) to the cloud alongside lines and rebuild from them on pull, or encode sceneName/description into a per-line tag so the rebuild path can recover them.
- [low] lib/features/script_editor/scene_editor_screen.dart:68 — `onReorder` is an empty no-op (comment: "Reorder not implemented for scenes"), but the widget is a `ReorderableListView`, so the UI actively presents a drag-to-reorder affordance that does nothing — the list snaps back after the user reorders. Concrete consequence: users are offered a reordering interaction that silently has no effect. Smallest safe fix: implement scene reorder (and remap line order) or replace `ReorderableListView` with a plain `ListView` so no reorder gesture is offered.
- [low] lib/data/services/kokoro_onnx_service.dart:121 — `_sub = fromIsolate.listen((msg) {...})` registers only an onData callback with no `onError`/`onDone` handler, and `synthesize` awaits `req.completer.future` (line 217) with no timeout. If the synthesis isolate terminates on its own (uncaught native/FFI crash in sherpa, OS kill), the ReceivePort stream just ends and `_inFlight`/queued `_Req.completer`s are never completed. Concrete consequence: `synthesize` (and therefore TtsService's `speak` on-demand path, which awaits it with no timeout) hangs indefinitely instead of surfacing a null/failure the caller already handles. Smallest safe fix: add `onDone`/`onError` to the subscription that completes `_inFlight` and all queued completers with null, and/or wrap `req.completer.future` in a `.timeout(...)`.
- [low] lib/data/models/script_models.dart:209 — `dialogueLineCount` returns `endLineIndex - startLineIndex + 1` (the raw line-range span) rather than counting `LineType.dialogue` lines, and the getter is currently unused. Concrete consequence: any future caller (the name invites "dialogue line" counts) gets stage directions and headers counted as dialogue, and a scene whose span includes no dialogue still reports a nonzero count. Smallest safe fix: delete the dead getter or implement it as `characters`-unrelated `lines`-aware count of `lineType == LineType.dialogue` within the range.

## Coverage
lib/features/script_editor/scene_editor_screen.dart — findings: 2
lib/data/services/stt_service.dart — clean
lib/data/services/kokoro_onnx_service.dart — findings: 1
lib/data/models/script_models.dart — findings: 1
- [low] lib/features/settings/settings_screen.dart:326 — `ref.read(sharedPreferencesProvider).remove('auth_skipped')` returns a `Future<bool>` that is never awaited — the `auth_skipped` flag removal is fire-and-forget and races with `context.go('/auth')`; if the app is terminated before the async remove flushes, `main.dart:152` still reads `prefs.getBool('auth_skipped') == true` on next launch and re-skips auth, so sign-out doesn't stick — `await ref.read(sharedPreferencesProvider).remove('auth_skipped');` before navigating.
- [low] scripts/pdf_to_script.py:331-340 — `doc = pymupdf.open(pdf_path)` is closed with `doc.close()` only on the happy path; if `_extract_folger`/`_extract_standard` (or page.get_text on a corrupt/encrypted PDF) raises, the document handle is leaked and the file stays locked (notably on Windows) until process exit — wrap extraction in try/finally (or `with`) so `doc.close()` always runs.
- [low] lib/data/services/voice_config_service.dart:78-93 — `setOverride` (and `setGender`:232, `setLocale`:273, `removeOverride`, `renameCharacter`) do a non-atomic read-modify-write over a whole SharedPreferences JSON map (`await getOverrides(...)` then `await _saveOverrides(...)`); two overlapping calls interleave at the await and the later write silently drops the earlier change (e.g. two characters' overrides set concurrently, or a rename racing an override edit) — serialize per-production via an in-flight future/keyed lock, or store per-character keys instead of one whole-map blob.
- [medium] lib/data/services/stt_adaptation_service.dart:118-121 — `_actorProfiles`/`_productionProfiles` are in-memory-only maps with no load/save, despite `TrainingSample.toJson/fromJson` and `_adapterDir` existing; every collected training sample, `status`, `adapterPath`, `lastTrainedAt` and WER is lost on app restart, so a cast member who accrues the required 60s+ across sessions never reaches `readyToTrain` and the adaptation feature cannot work — persist profiles/samples (e.g. JSON under `_adapterDir`) and hydrate on startup.
## Coverage
lib/features/settings/settings_screen.dart — findings: 1
scripts/pdf_to_script.py — findings: 1
lib/data/services/voice_config_service.dart — findings: 1
lib/data/services/stt_adaptation_service.dart — findings: 1
- [medium] lib/features/settings/ai_models_screen.dart:110 — `_deleteOnnxKokoro()` calls `ModelManager.instance.clearCache()`, which recursively deletes the entire `Documents/models` directory (model_manager.dart:150-156) — not just the Kokoro ONNX pack. On Android the `live_asr` line-matching files live in the same dir (`Documents/models/live_asr/…` per model_download_service.dart `_filePath`), so tapping "Delete" on the "Kokoro AI Voices" tile silently wipes the Live Line Matching models too. The live-ASR tile keeps showing green "Installed" because it reads the in-memory `ModelDownloadService` states, which are never refreshed after `clearCache()`; rehearsal then loses live matching with no visible cause. — Smallest safe fix: delete only the Kokoro model dir (e.g. `Directory(p.join(await modelsDir, _kokoroModelName)).delete(recursive: true)`) instead of `clearCache()`, and call `ModelDownloadService.instance.refreshDownloadedStatus()` afterwards so the ASR tile reflects reality.

- [low] lib/features/settings/kokoro_debug_screen.dart:116 — `_speak()` calls `_log('speak() complete …')` (which calls `setState` at line 85) after `await _tts.speak(text)` with no `mounted` guard; the same applies to `_log('speak() ERROR: …')` at line 118, `_stop()`'s `_log('Stopped')`/`setState` at lines 126-127, and `_tryInit`/`_tryReload` which call `_log`/`_loadDebugInfo` (whose first statement `setState(() => _loading = true)` at line 44 is also unguarded) after `await`. If the user navigates away while an init/speak/stop is in flight, the callback runs after `dispose()` and throws `setState() called after dispose()`. — Smallest safe fix: guard each post-`await` state mutation with `if (!mounted) return;`, or make `_log`/`_loadDebugInfo` no-ops when `!mounted`.

- [low] lib/data/services/model_manager.dart:140 — `downloadAll()` only invokes `downloadKokoro()`, but the companion `isAllReady()` (line 129) on Android also requires the live line-matching ASR group (`ModelDownloadService.instance.isLiveAsrReady()`). A caller that uses the natural `downloadAll()` → `isAllReady()` pairing (as the production-hub/onboarding "models ready" gates do) still reports not-ready on Android after a full "download all", leaving the download banner/prompt up. — Smallest safe fix: make `downloadAll()` also `await ModelDownloadService.instance.downloadLiveAsr()` on Android, or rename/document it as Kokoro-only so callers don't pair it with `isAllReady()`.

- [low] lib/data/services/model_manager.dart:214 — `_downloadAndExtractArchive` deletes the downloaded archive only on the success path (line 222, after `compute`); when `_extractArchiveStreaming` throws, the exception is rethrown and the ~180 MB archive file is left in the app temp dir. Inside the isolate, `_extractArchiveStreaming` (line 234) creates a system-temp `lineguide_extract*` dir and only calls `tempDir.deleteSync()` at line 254 on success, so a failed extraction also leaks the fully decompressed tar. Repeated failed extractions (e.g. disk full during the 600-file unpack) accumulate large temp files on the device. — Smallest safe fix: wrap the extraction and cleanup in `try { … } finally { tempDir.deleteSync(recursive: true); }` inside the isolate and delete the archive file in a `finally` in `_downloadAndExtractArchive`.

## Coverage
lib/features/settings/ai_models_screen.dart — findings: 1
lib/features/settings/debug_log_screen.dart — clean
lib/features/settings/kokoro_debug_screen.dart — findings: 1
lib/data/services/model_manager.dart — findings: 2
# Pi review — batch 23

## Findings

- [high] ios/Runner/BackgroundDownloadPlugin.swift:152 — background URLSession downloads that complete (or fail) while the app is terminated are silently lost because `activeDownloads` is an in-memory-only `[String: DownloadInfo]` and the destination path is never persisted — on relaunch iOS replays `didFinishDownloadingTo` with `taskDescription` restored, but `guard ... let info = activeDownloads[modelId] else { return }` fails (the freshly constructed plugin has an empty dict), so the temp file at `location` is never moved to `destinationPath`, gets deleted by the system, and `onDownloadComplete` is never delivered; the same empty-dict guard at line 209 drops `didCompleteWithError`, so resume-data persistence and the auto-retry are skipped too — concrete consequence: a multi-GB model download finishing during a background/terminated window is discarded and the UI never learns of completion — smallest safe fix: persist `modelId → (url, destinationPath)` to disk (JSON file in Application Support or UserDefaults) in `startDownload` and reconstruct `DownloadInfo` from that metadata in both delegate callbacks when `activeDownloads[modelId]` is nil.

- [medium] lib/data/database/app_database.dart:128 — every migration step swallows all exceptions with `catch (_) {}` — Drift runs `onUpgrade` inside a transaction and advances `user_version` to `schemaVersion` when the callback returns without throwing, so a genuine `addColumn`/`createIndex` failure (not just the intended "column already exists" case) is masked, the version is bumped anyway, and the column/index is permanently missing — concrete consequence: the app then throws "no such column: ..." on every query touching that column and the migration never re-runs to repair it — smallest safe fix: log and rethrow (or catch only the specific duplicate-column error), letting Drift roll back to the old version so the migration is retried.

## Coverage
lib/data/database/app_database.dart — findings: 1
lib/app.dart — clean
lib/data/services/ocr_confidence_service.dart — clean
ios/Runner/BackgroundDownloadPlugin.swift — findings: 1

## Run stats

input 934321 tok (+15424128 cached), output 514164 tok, cost $0.91 — 298 files in 39m (454.4 files/h, 1.7 min/batch)
