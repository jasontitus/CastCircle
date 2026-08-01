# Laguna S 2.1 vs DeepSeek V4 Flash — perf-review comparison on CastCircle

Controlled comparison: both models reviewed the identical source state
(`c717d17`, pre-fix) through the same ds4-box sweep machinery, same
performance brief, same 280-file feed, on the same M5 Max. Laguna review
docs were purged from the DeepSeek clone before its run — no cribbing was
possible. 2026-07-31.

## Configurations that actually work

| | Laguna S 2.1 Q4_K_M (`e2ccc05`) | DeepSeek V4 Flash 0731 IQ2XXS mixed |
|---|---|---|
| Size resident | 63.6 GiB (+6.1 GiB KV @131k) | 80.8 GiB (+5.0 GiB KV @600k — MLA) |
| Required mode | `--nothink` | `--think` |
| Required sampling | repetition penalty 1.15 / window 64 | stock |
| Failure mode without it | token loops → batches never finish | premature end-of-turn at a 2048-token generation segment → findings file never written |
| ctx used | 131,072 (model caps at 262k) | 600,000 |

Each model needs the *opposite* crutch: Laguna can't stop repeating
(sampling-level fix), DeepSeek stops too soon in nothink (mode-level fix).
Neither failure is visible in perplexity; both only appear in real agentic
runs.

## Reliability (batches passed first try)

- **Laguna**: 8/8, zero refeeds, ~5 h wall clock. One tool-call read-loop
  observed in a separate large-batch run (greedy tool calls are exempt from
  the repetition penalty by design — host-side watchdog catches this class).
- **DeepSeek nothink**: 0/3 on untried batches (one context exhaustion at
  131k, two 2048-token stops) — all self-healed by the sweep's refeed/resume
  machinery, none by the model.
- **DeepSeek think @600k**: 7/7 first-try, zero compactions, plus a clean
  92-file top-up. Verbosity note: DeepSeek narrates far more per file — the
  same 300 KB batch that fit Laguna at 131k needed 600k (or smaller batches)
  for DeepSeek.
- **Coverage honesty**: Laguna's run predated the coverage contract and
  needed a manual audit — batch 2 had reviewed "12 additional files" of 75
  fed, and group claims hid skips; 110 files required top-ups. DeepSeek ran
  under the hardened sweep: per-file verdicts enforced, 280/280 evidenced,
  and its one scope gap (vendored dirs, correctly following the old skill
  wording) was visible immediately rather than discovered by audit.

## Findings

- **Laguna**: 105 total (64 sweep + 41 top-ups) — 12 high.
- **DeepSeek**: 68 total (52 sweep + 16 skill-routed vendored top-up) —
  6 high.
- **Cross-model confirmations** (found independently by both — the
  highest-confidence items): the O(n²) `insert(at: 0)` LSTM backward pass;
  per-frame `.item()` syncs in KokoroTTS; the BART fallback decoder's
  growing-concat (and, with the skill, its missing KV-cache); synchronous
  `existsSync` per cache entry in recording sync; `cacheExtent: 10000`;
  the OCR-review sort-per-call; `_detectCharacterCue` re-sort+regex per
  line; `addSample` spread-copies; window/mel-filterbank rebuilds.
- **Laguna-leaning strengths**: vendored ML internals depth — it violated
  the (mis-scoped) vendored-deps exclusion and found the BART KV-cache
  cluster unprompted; Parakeet decode-loop syncs; TimestampPredictor.
- **DeepSeek-leaning strengths**: Flutter/platform semantics — the
  cast-manager O(M²) cloud sync and per-card scans; eager Card+TextField
  construction for every OCR line; per-token transcript `+=` in
  MLXSttPlugin (O(n²) per session); main-thread `PDFDocument` init;
  per-progress-event channel calls; unbounded rehearsal history; plus the
  disciplined per-file verdicts and false-positive dismissals.
- **Verdict on quality**: complementary, not ranked. Laguna reads like a
  systems engineer (deep, occasionally disobedient in useful ways);
  DeepSeek like a framework reviewer (broad, contract-faithful,
  calibrated severities). The union, deduplicated with confirmation
  flags, beats either alone.

## The skill-library effect (measured)

DeepSeek's base sweep missed the missing-KV-cache — the single most
valuable finding of the whole exercise (Laguna-only until today). The
92-file top-up re-ran with the new specialized skills routed
(mlx/metal/simd/ios): DeepSeek then reported `BARTModel.swift:120 — [high]
generate decodes without a KV-cache` on its own. Same model, same files;
the checklist closed the expertise gap. That is the argument for the
skills library in one datapoint.

## Throughput (matched-work samples; microbenchmark pending)

- DeepSeek think generation: 20.6–23.8 t/s sustained (turn-stats lines).
- End-to-end on identical file sets: DeepSeek nothink was ~3× faster than
  Laguna where it worked, but with a coverage asterisk; DeepSeek think
  runs at roughly Laguna-nothink speed per batch on non-vendored slices
  (e.g. the 66-file tests/migrations slice: 14 min vs Laguna's 41 for its
  53-file analog). The vendored 92-file set: DeepSeek+skills 28 min /
  16 findings vs Laguna 29 min / 27 findings — near-identical wall clock,
  Laguna deeper, DeepSeek's set includes issues Laguna missed.
- Isolated prefill/generation tps for both models on identical prompts:
  queued behind this doc (needs exclusive model residency).

## Normalization against current main

Five production files changed between the reviewed state and current
`main` (fixes already applied by the team): `stt_service.dart`,
`rehearsal_screen.dart`, `script_parser.dart`, `tts_service.dart`,
`kokoro_onnx_service.dart`. Findings anchored there should be checked
against `main` before acting — several P0/P1 items (the DP-matrix scorer,
rehearsal-screen listen/cacheExtent cluster, parser regex work) appear to
be already addressed; both models' reports still credit the detection.
Everything else — including the entire vendored-ML set (BART KV-cache,
`.item()` loops, per-sample copies) — is unfixed at time of writing.

## Operational recipes (what to run next time)

- Laguna: `DS4_MODEL=e2ccc05 DS4_CTX=131072 DS4_SWEEP_SAMPLING="--repeat-penalty 1.15 --repeat-last-n 64"` + nothink default.
- DeepSeek: `DS4_MODEL=0731 DS4_CTX=600000 DS4_SWEEP_THINK=1`, stock sampling.
- Either way the hardened sweep (per-file verdict contract, refeed,
  watchdog, coverage report) and the routed perf skills now come free.
