# OCR benchmark harness — Unlimited-OCR vs PaddleOCR PP-OCRv6

Reproducible CPU harness for comparing OCR quality on CastCircle's scanned
play-script corpus. It scores **Baidu Unlimited-OCR** (a 3B-parameter MoE
vision-language model, run via a GGUF quant on llama.cpp) against the shipped
**PaddleOCR PP-OCRv6** engine (the committed `assets/paddle_ocr/*.onnx` models,
run via ONNX Runtime — the same weights the iOS/Android app uses).

See `docs/on-device-ocr.md` §"Unlimited-OCR" for the results and the verdict.

## What it does

1. `harness.py manifest` — renders a fixed sample of interior dialogue pages
   from `sample-scripts/ocr-test-set/` to PNGs (200 DPI). For the four scripts
   that carry an embedded archive.org text layer (Earnest, A Doll's House,
   Pygmalion, Chekhov) it extracts each page's text as the **per-page
   reference**. Faustus (the degraded 150-DPI copier mimic that stands in for
   the copyrighted P&P scan) and Macbeth (bitonal verse) are image-only and
   used for qualitative side-by-side only.
2. `run_paddle.py` — runs PaddleOCR over every page (~1.5 s/page CPU).
3. `run_unlimited.sh` — runs Unlimited-OCR over every page (~50 s/page CPU).
4. `score.py` — scores both against the gold text and writes `results/report.md`.

## Metrics

- **word-multiset F1** (primary) — order-insensitive fraction of real words
  recognized. Robust to the reference layer's scrambled reading order, and it
  directly captures the `serue`→serve / `produetion`→production garble that
  inflates the parsed character roster with phantom names.
- **char-acc** (1 − CER) — standard character accuracy. Order-sensitive, so it
  penalizes an engine for disagreeing with the reference's (imperfect) reading
  order; read as secondary.
- **garble-rate** (1 − precision) — fraction of emitted word-tokens not present
  in the reference (a false-token / hallucination proxy).

The embedded reference is itself archive.org's OCR, so it is an imperfect
yardstick — but **both engines are scored against the identical reference**, so
the relative ranking is sound even where the absolute numbers are not ground
truth. Spot-check pages by eye for the qualitative story.

## Setup

```bash
pip install rapidocr onnxruntime pymupdf pillow numpy python-Levenshtein \
            opencv-python-headless shapely pyclipper

# Unlimited-OCR needs llama.cpp's multimodal CLI:
git clone --depth 1 https://github.com/ggml-org/llama.cpp tool/ocr_bench/llama.cpp
cmake -S tool/ocr_bench/llama.cpp -B tool/ocr_bench/llama.cpp/build \
      -DCMAKE_BUILD_TYPE=Release
cmake --build tool/ocr_bench/llama.cpp/build -j --target llama-mtmd-cli

# ...and the GGUF weights + vision projector (DevQuasar/baidu.Unlimited-OCR-GGUF):
mkdir -p tool/ocr_bench/models
BASE=https://huggingface.co/DevQuasar/baidu.Unlimited-OCR-GGUF/resolve/main
curl -L -o tool/ocr_bench/models/unlimited-ocr-Q4_K_M.gguf   "$BASE/baidu.Unlimited-OCR.Q4_K_M.gguf"
curl -L -o tool/ocr_bench/models/mmproj-unlimited-ocr-f16.gguf "$BASE/mmproj-baidu.Unlimited-OCR.f16.gguf"
```

## Run

```bash
cd tool/ocr_bench
python3 harness.py manifest
python3 run_paddle.py
./run_unlimited.sh          # slow; ~50 s/page on CPU
python3 score.py            # -> results/report.md, results/scores.json
```

## Adding the real Pride & Prejudice scan

The copyrighted `Pride-Prejudice-SCRIPT.pdf` is gitignored and not committed.
To include it: drop it under `sample-scripts/`, add an entry to `GOLD_SCRIPTS`
(if you have a per-page reference) or `QUAL_SCRIPTS` (roster/qualitative only)
in `harness.py`, and re-run. Its clean roster answer key is
`sample-scripts/pride_and_prejudice_perfect.md`.

## Notes / gotchas

- `--jinja` is **required** for Unlimited-OCR: its chat template needs the full
  Jinja engine, else `llama-mtmd-cli` aborts at startup in
  `common_chat_templates_apply`.
- Official Unlimited-OCR prompt is `"document parsing."` at temperature 0; it
  emits structural tags `<|det|>LABEL [box]<|/det|>TEXT` (LABEL ∈
  header/title/text/page_number/…), which `score.py` strips before scoring.
- PaddleOCR params mirror `ios/Runner/PaddleOcrPlugin.swift` (det limit-side 960,
  no orientation classifier). RapidOCR drives its own calibrated PP-OCRv6
  pre/post-processing over the committed models.
- `results/` (rendered pages, model outputs) and `models/` / `llama.cpp/` are
  gitignored — large and regenerable.
