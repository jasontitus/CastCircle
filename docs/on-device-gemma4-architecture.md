# On-Device AI Architecture — Gemma 4 Script Cleanup

How CastCircle turns raw imported script text into a structured `ParsedScript`
entirely on the phone, using Gemma 4 via llama.cpp. This is the design we
**arrived at after a lot of iteration** — the rejected approaches and the
hard-won robustness fixes are documented at the end so they aren't re-tried.

## TL;DR

```
PDF / images → OCR (ML Kit) → raw text
   → heuristic ScriptParser  (instant, free — the default)
   → [only if that looks poor / on opt-in] AI cleanup:
        chunk the text → Gemma 4 (llama.cpp, Metal) → JSON per chunk
        → stitch → ParsedScript
```

The AI cleanup is the slow "smart fallback." The fast heuristic parser runs
first; the model pass exists for input the heuristic can't handle.

## Runtime

- **Model:** `google/gemma-4-E2B-it-qat-q4_0-gguf` (file `gemma-4-E2B_q4_0-it.gguf`,
  ~3.35 GB). Gemma 4 E2B = ~2B *effective* params (per-layer embeddings), QAT
  (quantization-aware-trained) q4_0 so the 4-bit weights stay faithful.
- **Engine:** llama.cpp, vendored as a **prebuilt xcframework** (release b8777,
  module `llama`) as a local SPM package (`ios/LocalPackages/LlamaCpp`), mirroring
  the `parakeet-stt` pattern. Metal-accelerated (`n_gpu_layers = 99` on device).
- **Fallback:** Apple Foundation Models when no GGUF is downloaded (too weak for
  verbatim extraction — hallucinates — but fine as a presence check).
- **Chat template (Gemma 4, NOT Gemma 2/3):**
  `"<|turn>user\n\(prompt)<turn|>\n<|turn>model\n"`. BOS added by the tokenizer
  (`add_special=true`); `<|turn>`/`<turn|>` parsed as special tokens
  (`parse_special=true`). Stop on `llama_vocab_is_eog`.

## Inference design

The model is loaded **once** (lazily, on first generate) and reused; it is multi-GB
so reloading per chunk would be ruinous. Two code paths in
`ios/Runner/OnDeviceLlmPlugin.swift`:

- **`runLlama`** (single completion) — used by the debug screen. Fresh context per
  call (defer-free); `n_ctx = n_batch = 8192`, `n_ubatch = 512`,
  `maxNewTokens = 4096`.
- **`runLlamaBatch`** (the cleanup path) — **continuous batching**. This is the
  throughput design and where most of the subtlety lives.

### Continuous batching (the cleanup decoder)

On-device decode is **memory-bandwidth-bound** (each step reads the whole 3.3 GB of
weights), so decoding N sequences together yields ~N tokens per weight-read. We
keep `slots` sequences in flight and **refill a slot the instant its chunk hits
end-of-turn** — instead of a fixed batch that idles on its slowest chunk.

- The Dart side (`structureChunked`) hands the decoder **groups of `2 × slots`
  chunks** per native call, so refilling actually happens; `slots` = the
  batch-size setting (default 4, the compute-bound knee on Apple Silicon).
- One reusable multi-sequence context per job (`batchCtx`), sized
  `n_ctx = perSeqCtx(4096) × slots`, `n_seq_max = slots`, `n_ubatch = 512`
  (small so the compute buffer doesn't grow with the slot count). Recreating a
  large context per call fragments/leaks Metal memory.
- Per-slot prefill via `llama_memory_seq_rm(seq)` + decode at positions `0..len-1`;
  refills are **deferred to after** the generation decode+sample (they reuse the
  shared `batch` buffer, so doing them mid-construction would clobber it).
- A reverse `onBatchProgress` channel reports per-chunk completion so the import
  progress bar advances smoothly even though one native call covers a whole group.

Measured: single-seq ~22 tok/s; fixed batch N=4 ~78 tok/s (~3.5×); continuous
batching ~1.25× on top of fixed (slots stay saturated, no per-batch tail).

### Key parameters

| Param | Value | Why |
|---|---|---|
| `slots` (batchSize) | 4 (1–8, user-tunable) | compute-bound knee on Apple Silicon |
| `groupSize` | `2 × slots` | enough to exercise refill; small enough to checkpoint/cancel often |
| `perSeqCtx` | 4096 | prompt (~950) + `maxNewTokens` fits with headroom |
| `n_ctx` | `4096 × slots` (16384 @ 4) | total KV cells across sequences |
| `n_batch` | = `n_ctx` | logical cap; below prompt size → GGML_ASSERT/SIGABRT |
| `n_ubatch` | 512 | physical batch; sizes the compute buffer |
| `maxNewTokens` | **1024** | was 2048 — capped to stop runaway generation (see crash fix) |
| `linesPerChunk` | 60 | ~600–1000 JSON tokens out per chunk |

## Robustness (hard-won)

These exist because each one was a real on-device failure:

- **Memory coexistence.** The 3.3 GB LLM and Kokoro's MLX model can't both be
  resident (the load OOM-kills the app). The controller frees Kokoro *before* the
  LLM load and reloads it after. Entitlements: `increased-memory-limit` +
  `extended-virtual-addressing`. Footprint with N=4 is only ~700 MB (the mmap'd
  model doesn't count toward `phys_footprint`).
- **Checkpoint + resume.** `structureChunked` checkpoints after every group
  (atomic `.tmp`+rename) with the raw text + title, keyed by a stable FNV-1a hash.
  A killed/backgrounded job resumes from the last group — even after the app was
  hard-killed and the in-memory preview is gone.
- **Decode-failure recovery.** On any `llama_decode` failure, free the context
  (`freeBatchCtx`) so the next call rebuilds clean. (Necessary but **not
  sufficient** — see the GPU-wedge fix.)
- **Runaway-generation cap.** Heavily OCR-garbled chunks make the model fail to
  emit end-of-turn; it rambles to the token cap on every slot. That sustained load
  wedges Metal. `maxNewTokens` capped 2048 → 1024; truncated JSON is salvaged.
- **Abort + resume on a GPU wedge.** Once Metal wedges, `llama_decode` fails for
  every subsequent group and **recreating the context doesn't help** (the failure
  is at the GPU layer). So when a whole group returns all-null, `structureChunked`
  **stops**, keeps the checkpoint, and returns null (job marked failed) — a resume
  in a **fresh process** continues with clean Metal, rather than churning dead
  decodes through every remaining group.
- **No Kokoro reload after a failed job.** Loading Kokoro's MLX model onto a
  wedged Metal device hard-crashes the app — that was the actual crash. On failure
  the controller skips the reload; TTS returns next launch (fresh Metal), when the
  cleanup also auto-resumes.
- **Background survival.** A `beginBackground` UIBackgroundTask assertion lets a
  brief app-switch not suspend mid-chunk; a local notification fires on completion.
  (iOS still can't run minutes of compute fully backgrounded.)

## Output parsing (`ai_script_structuring_service.dart`)

- Prompt uses **placeholder field descriptions**, not realistic examples — small
  models copy few-shot examples verbatim, so an example like "MACBETH" leaked into
  P&P output. Plus an explicit "never copy" rule + empty-result escape hatch.
- **Lenient JSON:** strips ```json fences, walks brace depth, and **salvages
  truncated output** (keeps complete `lines[]` elements, drops the half-written
  last one) — small models cap output mid-array. Also escapes raw control
  characters models emit inside strings.
- **Act/scene normalization + carry-forward:** the model labels acts
  inconsistently across independent chunks ("ACTI"/"1"/"A" for ACT I).
  Canonicalize to `ACT <Roman>` / `Scene N`; unrecognizable labels carry the prior
  act forward (across chunks and across a resume) instead of resetting to ACT I.

## What we tried and rejected (so we don't re-try it)

- **mlx-swift-lm** — Gemma4 load fails (layer 15 `v_proj`/`k_proj`/`k_norm` not
  found): `Gemma4Attention.init` unconditionally builds k/v proj for KV-shared
  layers, then `loadWeights` does strict `verify:[.all]`. Both QAT and non-QAT
  checkpoints fail identically — not a quant issue, not fixable without forking.
  → abandoned MLX for the LLM; switched to llama.cpp.
- **Apple Foundation Models** — hallucinates on verbatim extraction (invented
  "MR. BENTLEY", "Captain Talley"). Kept only as a no-download fallback.
- **Non-QAT 4-bit** — garbage output; the **QAT** q4_0 GGUF is faithful. (PLE-safe.)
- **MTP / EAGLE3 speculative decoding** — not viable: llama.cpp MTP is hard-locked
  to `n_parallel=1` (can't combine with batching), MTP regresses on Metal even at
  batch-1, E2B MTP ~48% acceptance, and the speculative driver lives in
  `common/speculative.cpp` which isn't in the xcframework.
- **Fixed batching** — worked but idles on the slowest chunk per batch and (the
  real killer) cascades into a job-wide failure when one decode fails. Replaced
  with continuous batching + the wedge/abort handling above.

## Key files

- `ios/Runner/OnDeviceLlmPlugin.swift` — the llama.cpp plugin (load, single +
  continuous-batch decode, recovery, background, notifications).
- `ios/LocalPackages/LlamaCpp/Package.swift` — the b8777 xcframework binary target.
- `lib/data/services/ai_script_structuring_service.dart` — prompt, chunking,
  JSON salvage, act/scene normalization, `structureChunked`.
- `lib/data/services/on_device_llm_channel.dart` — Dart↔native channel
  (`generate`, `generateBatch` with `slots`/`baseDone`/`onBatchProgress`).
- `lib/data/services/script_ai_cleanup_controller.dart` — the long-running job
  owner (Kokoro coexistence, ETA, batch-size setting, resume).
- `scripts/ship-testflight.sh` — one-command TestFlight ship (see its header).

## Build & ship

Release build + device install: `./scripts/deploy.sh`. TestFlight:
`./scripts/ship-testflight.sh` (ASC API key `7C7256MDM6` + `-allowProvisioningUpdates`;
**do not** route through fastlane — it breaks `pod install` and clobbers the
Flutter build number). Pull on-device logs: `scripts/pull-debuglog.sh`.

## Known limitation & future direction: OCR

The biggest remaining quality problem is **OCR**, not structuring. The current
ML Kit OCR produces garbling ("themn", "serue", "Captain Talley") that the model
faithfully transcribes (it's told to preserve text verbatim), and on already-clean
scripts the AI cleanup is ~a wash vs the free heuristic parser. Two upgrades:

1. **Apple Vision (`VNRecognizeTextRequest`)** instead of ML Kit — native, free,
   higher accuracy on clean print; helps both heuristic and AI paths.
2. **Gemma 4's own vision path** — Gemma 4 E2B is multimodal and documented to do
   OCR + document parsing; llama.cpp supports it via `libmtmd` + an `mmproj`
   projector. Feed rendered page images → OCR + layout + structure in one pass,
   replacing ML Kit *and* the text-structuring step. The `pageImagePaths` /
   `imagePaths` seam is already reserved for this; the work is a multimodal-enabled
   xcframework (the prebuilt one must include `libmtmd`/`clip.cpp`) + the `mmproj`.
