#!/bin/bash
# Run Baidu Unlimited-OCR (3B MoE VLM) over the benchmark page images via a GGUF
# quant on llama.cpp (CPU). Writes one <script>_p<page>.unlimited.txt per page.
#
# Prereqs:
#   1. Build llama.cpp with the multimodal CLI:
#        git clone --depth 1 https://github.com/ggml-org/llama.cpp
#        cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j --target llama-mtmd-cli
#   2. Fetch the GGUF weights + vision projector (DevQuasar/baidu.Unlimited-OCR-GGUF):
#        curl -L -o models/unlimited-ocr-Q4_K_M.gguf   .../baidu.Unlimited-OCR.Q4_K_M.gguf
#        curl -L -o models/mmproj-unlimited-ocr-f16.gguf .../mmproj-baidu.Unlimited-OCR.f16.gguf
#   3. python3 harness.py manifest   # render the page PNGs
#
# Notes:
#   * --jinja is REQUIRED: the model's chat template needs the full Jinja engine;
#     without it llama-mtmd-cli aborts in common_chat_templates_apply at startup.
#   * Official prompt is "document parsing." at temperature 0.
#   * ~50 s/page on a 4-core CPU (no GPU). Encoding the image tiles dominates.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="${LLAMA_MTMD_CLI:-$DIR/llama.cpp/build/bin/llama-mtmd-cli}"
M="${UNLIMITED_MODEL:-$DIR/models/unlimited-ocr-Q4_K_M.gguf}"
MMP="${UNLIMITED_MMPROJ:-$DIR/models/mmproj-unlimited-ocr-f16.gguf}"
OUT="${OCR_BENCH_OUT:-$DIR/results}"

for png in "$OUT"/pages/*.png; do
  base=$(basename "$png" .png)
  outf="$OUT/pages/${base}.unlimited.txt"
  [ -s "$outf" ] && { echo "skip $base (exists)"; continue; }
  S=$(date +%s)
  timeout 300 "$BIN" -m "$M" --mmproj "$MMP" --image "$png" \
    -p "document parsing." --temp 0 -n 4096 --repeat-penalty 1.05 --repeat-last-n 128 \
    -t 4 --jinja 2>/dev/null > "$outf"
  E=$(date +%s)
  echo "$base  $((E-S))s  $(wc -c < "$outf") chars"
done
echo "UNLIMITED BATCH DONE"
