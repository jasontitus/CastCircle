# On-Device OCR — Research, Benchmarks, and Plan

How CastCircle OCRs imported script PDFs, why we're moving off Google ML Kit, and
the data behind every decision. All numbers here were **measured**, not assumed —
where something is unverified it says so.

## TL;DR / decision

- **Current OCR is Google ML Kit** (on iOS/Android) and **Apple Vision** (macOS).
  ML Kit garbles clean print (`serue`→serve, `Bernnet`→Bennet, `themn`→them),
  which then becomes junk characters in the parsed script (`MRS`, `INE`, `EA`).
- **Decision: replace ML Kit with PaddleOCR PP-OCRv6** (the latest, released
  2026-06-11) run on-device via **ONNX Runtime**. It is the most accurate
  lightweight engine and fixes the garbling.
- **Format: fp16 (~66 MB) or a fixed int8 (~34 MB)** — *not* fp32 (132 MB).
  GPU/ANE acceleration does **not** work for this model (see §6), so we're
  CPU-bound; CPU is fast enough (~1.3 s/page).
- **Validated end-to-end:** PaddleOCR's text parses into a cleaner script than ML
  Kit through the real `ScriptParser` (§7).
- **Status:** Mac-side runtime fully validated. Dart scaffolding landed
  (`paddle_ocr_channel.dart` + import wiring, falls back to ML Kit). The iOS
  native plugin (onnxruntime-objc + the det→cls→rec pipeline) is the remaining
  build.
- **Later challengers evaluated & rejected:** Baidu **Unlimited-OCR** (3B MoE
  VLM, 2026-06) — benchmarked at ≈ parity with PaddleOCR but ~30× the size /
  latency and GPU-only; keep PaddleOCR on-device (see §10, harness `tool/ocr_bench/`).

## 1. OCR engine head-to-head

Same P&P page (page 4, clean digital PDF @ 220 DPI), char-level accuracy on the
dialogue passage vs the clean reference (`sample-scripts/pride_and_prejudice_perfect.md`):

| Engine | char accuracy | notes |
|---|---|---|
| Tesseract (baseline) | 97.2% | cleanest classic engine |
| **PaddleOCR PP-OCRv6** | **96.4%** | minor missing-space quirks only |
| **Apple Vision** | 96.3% | native iOS; occasional all-caps glitch (`MR. BENNET`→`MIR. BENNEL`) |
| ML Kit (current) | 91.4% | weakest; errors cluster in dense/small text |
| **Gemma 4 vision** | **FAIL** | hallucinated the page + looped (general-VLM full-page OCR fails) |

Key finding: at low DPI (96), Apple Vision and Tesseract still read "three serve"
correctly while the device's ML Kit produced "serue" — so the device garbling is
the **engine**, not just render resolution. ("Captain Talley" is **not** an OCR
error — all engines read it; it's genuinely printed in the Jory adaptation.)

**Gemma 4 vision (via llama.cpp `llama-mtmd-cli` + its 167 MB projector, 12B):**
hallucinated text ("adapted by Jon **Jury**", "(A book of the stage is very rich
drama…)") and looped. General VLMs downsample a dense full page below readable
resolution. The on-device E2B would be worse. **Scratch Gemma-vision for OCR.**

## 2. Apple Vision history (why it's macOS-only)

Apple Vision OCR **was** built — commit `f4a5150` (2026-03-19):
`macos/Runner/VisionOcrPlugin.swift` (194 lines, `VNRecognizeText`) +
`lib/data/services/vision_ocr_channel.dart`. But it is **macOS-only** —
`script_import_service.dart:_importFromPdfOcr` does `if (Platform.isMacOS)` →
Vision, `else` (iOS/Android) → ML Kit. There is **no `ios/Runner/VisionOcrPlugin.swift`**;
the iOS port was never written (the pickaxe shows `VNRecognizeText` only ever
appeared in that one macOS commit). Per the owner, it wasn't pursued on iOS
because it "didn't work in the end" (the exact reason isn't recorded in history).

## 3. Why PaddleOCR (and which version)

PaddleOCR-VL (0.9B VLM) is the OmniDocBench SOTA, but it's ~25× the params, slower,
and has the VLM resolution caveat. The **PP-OCRv6** CNN pipeline is the right
on-device pick: tiny, fast, and it **surpasses billion-param VLMs on OCR**.

**Version diligence (learned the hard way):** the latest is **PP-OCRv6**, released
**2026-06-11** (`paddleocr 3.7.0` ships it). Do **not** trust convenience packages —
`rapidocr_onnxruntime 1.4.4` bundles stale **PP-OCRv4**. Use the current `rapidocr`
(3.8.3) / convert from the PaddleX inference models with **paddle2onnx 2.1.0**.

## 4. Tier benchmark (tiny / small / medium)

PP-OCRv6 has exactly three tiers — **tiny (1.5M) / small (7.7M) / medium (34.5M)**.
There is no "large"; medium is the top tier. Measured through ONNX Runtime on
page-04 (clean dialogue):

| tier | accuracy | agreement vs medium (full page) |
|---|---|---|
| tiny | 99.4% | 74% |
| small | 99.4% | 81% |
| medium | 99.6% | 100% (ref) |

All tiers tie on clean script text; medium has the edge on dense/degraded text
(per the published OmniDocBench numbers). Real throughput (batched, one engine,
82 pages): **small ≈ 1.3 s/page** on the Mac CPU. (Per-*call* timings of
10–30 s/page were model-reload overhead, not real throughput.)

## 5. Quantization (det+rec ONNX, verified through ONNX Runtime)

| precision | accuracy | size | reliability |
|---|---|---|---|
| fp32 | 99.6% | 132 MB | reference |
| **fp16** | **99.6%** | **66.3 MB** | **lossless: 99.89–99.94% ≡ fp32 across 3 pages** ✅ |
| int8 (dynamic) | — | 34 MB | **won't run** (ConvInteger unsupported on CPU EP) |
| int8 (static QDQ, real calibration) | 99.6% p4 / 99.7% p12 | 34.6 MB | **UNRELIABLE — p8 collapsed to 72.9%** ⚠️ |

- **fp16 is the verified, reliable compressed model** (66.3 MB, zero loss).
- **int8 is *not* adopted** — static QDQ (5 det + 36 rec calibration samples) was
  lossless on 2 pages but garbled page-08. Needs more/diverse calibration and
  likely a **det-fp16 / rec-int8 hybrid** (DB-detection quant is the usual culprit)
  + on-device validation before it can be trusted. The earlier "int8 ≈ 34 MB" was a
  *size-only* number with no verified accuracy — don't repeat that.

## 6. GPU / ANE acceleration — does NOT work (important)

The Mac and the phone share the same Apple Silicon ANE/GPU, so the Mac is a valid
proxy: **if it won't accelerate here, it won't on the phone.** It doesn't.

onnxruntime's **CoreML execution provider** gives no speedup for PP-OCRv6:
- **fp16:** CoreML rejects every conv/relu — verbose log: `[Conv] Input type:
  [10]=float16 not supported` — so the whole graph falls back to CPU.
- **fp32** (fixed input shape, `ModelFormat=MLProgram`, `MLComputeUnits=ALL`): ops
  are now supported but there's still **no speedup** — det **1.06×**, rec **0.76×
  (slower)**. The transformer-style rec head (Erf/MatMul/ReduceMean) + the
  CPU↔ANE partition-boundary copies negate any gain.

Consequence: **on-device OCR is CPU-bound.** This is acceptable (CPU ≈ 1.3 s/page),
and it reshapes the format choice (§5/§8). A *native* Core ML conversion
(coremltools) might engage the ANE better, but ONNX→CoreML is deprecated and would
mean a different runtime than onnxruntime-objc — not pursued.

### 6.1 CPU parallelism (measured)

Since we're CPU-bound, can we use more cores? Measured on a 20-core Mac (small tier):

| config | s/page | vs sequential |
|---|---|---|
| sequential (default intra-op) | 1.30 | 1.0× |
| parallel ×2 pages | 0.80 | **1.62×** |
| parallel ×4 pages | 0.82 | 1.58× |
| parallel ×20 pages | 0.89 | 1.45× (oversubscribed) |

- A **single** OCR call is already multi-threaded (onnxruntime intra-op spreads it
  across cores — hence 1.3 s/page, not slower).
- **Page-level parallelism adds ~1.6×** but **plateaus at ~2 concurrent** and
  regresses past that — OCR is memory-bandwidth-bound, so extra threads just
  contend once intra-op has the cores.
- On the **phone** (≈6 cores, tighter thermals/bandwidth) expect *less* headroom:
  per-inference threading already uses the perf cores; 2–3 concurrent pages (GCD
  `concurrentPerform`) gives a modest ~1.3–1.5×, not linear scaling.
- Bigger lever than page-parallelism: **batch the rec model** (all of a page's
  text lines in one inference) instead of many tiny per-line calls (untested but
  expected to use the cores more efficiently).

## 7. End-to-end validation (PaddleOCR vs ML Kit through `ScriptParser`)

Full 82-page OCR → the app's real `ScriptParser` → parsed script:

| | characters | dialogue lines | junk names |
|---|---|---|---|
| ML Kit (current) | 25 | 1121 | `MRS`, `INE`, `EA` (+ `ANNE`) |
| **PaddleOCR (small)** | **22** | 1121 | **none** (1 residual fragment `ZABE`) |

Same dialogue volume, but PaddleOCR yields a cleaner character roster — it removes
the OCR-garble fragments ML Kit produces. **Confirmed: PaddleOCR is a real
improvement through the actual pipeline.**

## 8. Format decision, given CPU-bound

Because acceleration is off the table (§6), format is a CPU-speed/size tradeoff:
- **fp32:** fastest on CPU (no fp16 cast overhead: rec 34 ms vs fp16 52 ms) but
  **132 MB** — too big.
- **fp16:** **66 MB**, lossless, speed still fine → **the safe baseline.**
- **int8:** would be **fastest *and* smallest (~34 MB)** on CPU (native int8
  kernels) — but only if the §5 accuracy regression is fixed and verified.

→ **Ship fp16 (66 MB) unless/until a fixed int8 is verified.** fp32's only edge
(marginal CPU speed) doesn't justify doubling the bundle.

## 9. Integration plan (the remaining iOS work)

Mirror the existing `VisionOcrChannel`/`VisionOcrPlugin` pattern so the import
pipeline barely changes (same `recognizeText`/`ocrPdf` → `pages→lines→{text,
confidence}` shape). **Done:** `lib/data/services/paddle_ocr_channel.dart` +
`_importFromPdfOcr` wiring (tries PaddleOCR first, falls back to ML Kit on
null/throw — safe to ship before the native side exists).

**Remaining (task #12/#13):**
1. **onnxruntime-objc v1.26.0** into the iOS build.
2. Port the **det → cls → rec** pipeline — Approach B: vendor a **C++ RapidOCR
   xcframework** (mirrors `ios/LocalPackages/LlamaCpp`; pipeline logic already in
   C++); hybrid fallback = onnxruntime-objc + the DB-postproc/CTC-decode in Swift.
3. Bundle the fp16 models (det 29.7 MB + rec 36.6 MB) + `ppocrv6_keys.txt`
   (18,708-char dict, 0.07 MB) as app resources.
4. `PaddleOcrPlugin.swift` (PDFKit render loop copied from `VisionOcrPlugin`),
   register in `ios/Runner/AppDelegate.swift`, build, verify on-device against the
   known-garbled PDF.
5. Android: `onnxruntime-android` + a Kotlin plugin on the same channel (later).
6. Once verified, drop `google_mlkit_text_recognition` + the GoogleMLKit pods.

## Reproducing the benchmarks

- Models: `paddle2onnx --model_dir ~/.paddlex/official_models/PP-OCRv6_medium_det
  --model_filename inference.json --params_filename inference.pdiparams
  --save_file det.onnx --opset_version 14` (same for `_rec`). fp16 via
  `onnxconverter_common.float16.convert_float_to_float16(..., keep_io_types=True)`.
  Dict from the rec `inference.yml` `character_dict`.
- Run via ONNX Runtime: `RapidOCR(params={"Det.model_path":..., "Rec.model_path":...,
  "Rec.rec_keys_path":"ppocrv6_keys.txt", "Global.use_cls":False})`.
- Scratch artifacts lived in `/tmp/paddle-onnx` and `/tmp/ocr-bench` (not committed).

## 9. Post-processing: page furniture, margin notes, credits (2026-06-22)

Mac-verified on the real `Pride-Prejudice-SCRIPT.pdf` (82pp copier scan) with the
shipped ONNX models: **OCR text accuracy is ~99%** — the perceived "type errors"
were not recognition errors. Two layout problems were leaking non-dialogue text
into the script, both fixed in `script_import_service` / `script_parser`:

1. **Left-margin handwritten annotations** (a marked-up script's director notes)
   sit in a distinct left column (left edge ≈ 0.02) well left of the indented
   dialogue body (≈ 0.26) and got OCR'd + interleaved line-by-line. Fix:
   `PaddleOcrPlugin` now returns each line's normalized box `left`+`width`;
   the assembly drops boxes with `left < bodyLeft − 0.12 && width < 0.30`, where
   `bodyLeft` = median left of the wide (body) boxes — so it adapts per script.
2. **Running headers/footers + credits**: the running title ("Pride and
   Prejudice") is dropped by cross-page first/last-slot repetition (≥50% of
   pages); bare page numbers by the existing `^\d+$` patterns; and the title
   credit by new noise patterns (`adapted by …`, `from the novel by …`, any
   `jon jory`).

Validated in Python against the real models: pages 8/12/14 lose every margin
note and the credit, dialogue fully intact. Harness lived in `/tmp/ocr_verify`
(not committed) — rebuild from `assets/paddle_ocr/*.onnx` + the constants in
`PaddleOcrPlugin.swift` (det 960 / thresh 0.3 / unclip 0.4, rec h48, CTC blank=0).

### 9.1 Corpus safety verification (2026-06-22)

The auto-detect margin filter (§9) was run through the real PP-OCRv6 models on
**36 sample pages across all 12 test scripts** (sample-scripts + ocr-test-set:
Atreus, Chekhov, Congreve, Doll's House, Earnest, Faustus, Ideal Husband, two
Macbeths, Patience, Pygmalion, P&P). Result: **zero dialogue-like drops anywhere.**
11 scripts stripped nothing; Macbeth/Folger stripped only its 78 `FTLN` line
numbers (furniture). Confirms the column auto-detection only fires on a genuine
narrow far-left furniture column and never removes body text. (Positive case —
stripping P&P's handwritten margin notes — verified separately on pages 8/12.)

## 10. Unlimited-OCR (Baidu 3B MoE VLM) vs PaddleOCR (2026-07-23)

**Question:** Baidu open-sourced **Unlimited-OCR** on 2026-06-22 — a 3B-parameter
Mixture-of-Experts vision-language model (~500M active/token, MIT license) that
parses whole pages in one forward pass. Does it beat the shipped PaddleOCR
PP-OCRv6 enough to be worth adopting?

**TL;DR: No — not for on-device.** On raw accuracy it is **≈ parity** with
PaddleOCR (marginally better on noisy/foreign-name speaker cues, marginally worse
on average because it occasionally *silently drops page content*), while costing
**~30× the model size, ~35× the per-page latency, and a hard GPU requirement**.
It is a genuinely competent OCR model — unlike the general Gemma-4 VLM (§1) it
does **not** hallucinate or loop — but the accuracy delta doesn't come close to
justifying the cost, and it can't run on a phone. Keep PaddleOCR as the on-device
engine. Unlimited-OCR's only plausible niche is an *optional cloud re-OCR* of a
specific failing scan, and even there the silent-drop failure mode is a concern.

Harness (reproducible): `tool/ocr_bench/` — renders sample pages, runs both
engines, scores word-multiset F1 + char accuracy against the per-page reference.

### 10.1 How it was run
- **Unlimited-OCR:** the community GGUF (`DevQuasar/baidu.Unlimited-OCR-GGUF`,
  **Q4_K_M** 1.9 GB + the f16 vision projector 788 MB) on **llama.cpp**
  (`llama-mtmd-cli`, CPU). Official prompt `"document parsing."`, temp 0.
  `--jinja` is **required** (its chat template aborts `llama-mtmd-cli` otherwise).
  Emits structural markup `<|det|>LABEL [box]<|/det|>TEXT` (header/title/text/…),
  stripped before scoring. **Caveat:** this is a Q4 quant on CPU, not the
  full-precision GPU model — the true fp16 ceiling is likely a hair higher.
- **PaddleOCR:** the committed `assets/paddle_ocr/{det,rec}.onnx` (PP-OCRv6 small,
  fp16) via RapidOCR/ONNX Runtime — the exact weights the app ships.
- **Corpus:** 20 gold-scored pages (Earnest, Doll's House, Pygmalion, Chekhov —
  the four scripts with an embedded per-page text layer) + 6 qualitative pages
  (Faustus 150-DPI = the P&P copier-scan proxy; bitonal Macbeth). The copyrighted
  **P&P scan itself is not in the repo** (gitignored) — drop it in and re-run per
  `tool/ocr_bench/README.md` to score the real target.
- **Metric:** primary is **word-multiset F1** (order-insensitive — the embedded
  reference has scrambled reading order, which unfairly penalizes the
  better-ordered engine under plain CER; F1 also directly measures the
  `produetion`→production garble that spawns phantom character names). char-acc
  (1−CER) is secondary and *understates* Unlimited-OCR for that ordering reason.

### 10.2 Accuracy (20 gold pages, mean)

| script | pages | Paddle F1 | Unlimited F1 | Paddle char-acc | Unlimited char-acc | Paddle garble | Unlimited garble |
|---|---|---|---|---|---|---|---|
| chekhov (Russian names, ~400 DPI) | 5 | 0.972 | **0.980** | 0.993 | **0.995** | 0.031 | **0.019** |
| dollshouse (clean grayscale) | 5 | **0.971** | 0.965 | **0.980** | 0.973 | 0.028 | 0.031 |
| earnest (clean grayscale) | 5 | **0.984** | 0.971 | **0.991** | 0.986 | **0.009** | 0.022 |
| pygmalion (dense, dialect) | 5 | **0.959** | 0.885† | **0.981** | 0.881† | 0.039 | 0.040 |
| **ALL** | 20 | **0.971** | 0.950† | **0.986** | 0.958† | 0.027 | 0.028 |
| **ALL, excl. 1 outlier†** | 19 | 0.973 | **0.971** | 0.989 | 0.986 | — | — |

†**One catastrophic page** (Pygmalion p70): Unlimited-OCR **silently dropped ~60%
of the page** (recall 0.41, output ended cleanly at the page number — it just
skipped a middle block, no error, no loop). Remove that single page and the two
engines are a **statistical tie** on the typical page. That failure mode is the
finding: a VLM can quietly omit content, whereas PaddleOCR's deterministic DBNet
detector emits a box for every text region it finds. Unlimited-OCR **wins the
noisy Chekhov set** (foreign names, lower DPI — the hardest garble case) and is a
touch behind on the cleanest grayscale pages.

### 10.3 Speaker-cue fidelity on the low-DPI P&P proxy (Faustus, qualitative)
This is the app-relevant axis — garbled ALL-CAPS/Title-case cue names become
phantom characters in the parsed roster (the original reason for moving off ML
Kit). On the degraded 150-DPI Faustus scan (the closest proxy to the real P&P
copier scan), PaddleOCR still makes a **consistent cue garble** — `Meph.` →
**`Mepk.`** (h→k) on every occurrence — which the parser would read as a separate
character. **Unlimited-OCR reads `Meph.` correctly every time**, with correct
reading order and expanded stage directions. (It does normalize away archaic
diacritics — `vexèd`→vexed, `carvèd`→carved — cosmetic for a rehearsal script.)
So the VLM's edge, where it has one, is exactly on the hard cue-name garble — but
PaddleOCR's residual errors here are already rare, and §9's post-processing plus
the parser's roster de-duping mop up most of what remains. On clean bitonal Macbeth
both engines are effectively perfect.

### 10.4 Cost / deployment (the deciding factor)

| | PaddleOCR PP-OCRv6 (shipped) | Unlimited-OCR (Q4 GGUF) |
|---|---|---|
| params / size | ~8M / **30.5 MB** (det+rec fp16) | 3B MoE / **2.7 GB** (Q4+mmproj); ~6 GB bf16 |
| latency | **~1.5 s/page** (this CPU; ~1.3 s Mac) | **~46 s/page** (4-core CPU; min 36 / max 66) |
| hardware | **fully on-device** (iOS/Android, CPU) | officially **NVIDIA GPU**; CPU only via GGUF |
| reliability | deterministic; detects every box | occasional **silent content-drop** (§10.2) |
| output | line text + boxes (feeds margin filter §9) | markdown + region labels (needs tag-stripping) |

At ~90× the on-disk footprint and ~30× the latency — and not runnable on a phone
at all — Unlimited-OCR would have to be *clearly* more accurate to matter. It
isn't; it's a tie. **Decision: keep PaddleOCR PP-OCRv6 on-device.** Revisit
Unlimited-OCR only if we ever add an opt-in *cloud* "re-OCR this scan" path for a
document PaddleOCR visibly fails — and validate the silent-drop behavior on real
pages before trusting it there.
