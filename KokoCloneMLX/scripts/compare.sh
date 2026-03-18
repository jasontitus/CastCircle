#!/bin/bash
set -e

# ═══════════════════════════════════════════════════════════════
# Voice Cloning Comparison: KokoClone MLX vs Qwen3-TTS
# ═══════════════════════════════════════════════════════════════
#
# Usage:
#   ./compare.sh <source.wav> <reference.wav> <ref-text> "<text-to-speak>"
#
# Prerequisites:
#   1. KokoClone models converted:
#      python convert_models.py --output-dir ../models
#   2. KokoClone Swift built:
#      cd .. && swift build -c release
#   3. Qwen3-TTS installed:
#      pip install mlx-audio soundfile
#
# Output:
#   results/kokoclone_output.wav    — KokoClone voice-converted audio
#   results/qwen3_output.wav        — Qwen3-TTS voice-cloned audio
#   results/kokoclone_metrics.json  — KokoClone benchmark data
#   results/qwen3_metrics.json      — Qwen3-TTS benchmark data
#   results/comparison.txt          — Side-by-side summary

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$SCRIPT_DIR/results"

if [ $# -lt 4 ]; then
    echo "Voice Cloning Comparison: KokoClone MLX vs Qwen3-TTS"
    echo ""
    echo "Usage:"
    echo "  $0 <source.wav> <reference.wav> <ref-text> \"<text-to-speak>\""
    echo ""
    echo "Arguments:"
    echo "  source.wav      Source speech (for KokoClone voice conversion)"
    echo "  reference.wav   Reference speaker audio (3-10 seconds)"
    echo "  ref-text        Transcript of reference audio (for Qwen3-TTS)"
    echo "  text-to-speak   Text to synthesize (for Qwen3-TTS)"
    echo ""
    echo "Both tools will produce output using the reference speaker's voice."
    echo "KokoClone converts the source audio; Qwen3-TTS synthesizes from text."
    echo ""
    echo "Prerequisites:"
    echo "  1. python convert_models.py --output-dir ../models"
    echo "  2. cd $PROJECT_DIR && swift build -c release"
    echo "  3. pip install mlx-audio soundfile"
    exit 1
fi

SOURCE_WAV="$1"
REFERENCE_WAV="$2"
REF_TEXT="$3"
TEXT="$4"

# Qwen3 model variants to test (add/remove as desired)
QWEN3_MODELS=(
    "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit"
    # "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"
    # "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit"
)

mkdir -p "$RESULTS_DIR"

echo "═══════════════════════════════════════════════════════════"
echo "  Voice Cloning Comparison"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Source audio:    $SOURCE_WAV"
echo "Reference audio: $REFERENCE_WAV"
echo "Text:            $TEXT"
echo ""

# ─── KokoClone MLX ───────────────────────────────────────────

KOKOCLONE_BIN="$PROJECT_DIR/.build/release/kokoclone-test"
MODELS_DIR="$PROJECT_DIR/models"

if [ -f "$KOKOCLONE_BIN" ] && [ -d "$MODELS_DIR" ]; then
    echo "━━━ Running KokoClone MLX ━━━"
    echo ""
    "$KOKOCLONE_BIN" \
        "$MODELS_DIR" \
        "$SOURCE_WAV" \
        "$REFERENCE_WAV" \
        "$RESULTS_DIR/kokoclone_output.wav" \
        --json "$RESULTS_DIR/kokoclone_metrics.json"
    echo ""
else
    echo "⚠ Skipping KokoClone: build or models not found."
    echo "  Build: cd $PROJECT_DIR && swift build -c release"
    echo "  Models: cd scripts && python convert_models.py --output-dir ../models"
    echo ""
fi

# ─── Qwen3-TTS ──────────────────────────────────────────────

for MODEL in "${QWEN3_MODELS[@]}"; do
    MODEL_SHORT=$(echo "$MODEL" | sed 's|.*/||' | tr '-' '_')
    echo "━━━ Running Qwen3-TTS ($MODEL_SHORT) ━━━"
    echo ""
    python3 "$SCRIPT_DIR/qwen3_tts_bench.py" \
        --text "$TEXT" \
        --ref-audio "$REFERENCE_WAV" \
        --ref-text "$REF_TEXT" \
        --output "$RESULTS_DIR/qwen3_${MODEL_SHORT}_output.wav" \
        --model "$MODEL" \
        --json "$RESULTS_DIR/qwen3_${MODEL_SHORT}_metrics.json"
    echo ""
done

# ─── Comparison Summary ─────────────────────────────────────

echo "━━━ Comparison Summary ━━━"
echo ""

SUMMARY="$RESULTS_DIR/comparison.txt"
{
    echo "Voice Cloning Comparison — $(date)"
    echo "Source: $SOURCE_WAV"
    echo "Reference: $REFERENCE_WAV"
    echo "Text: $TEXT"
    echo ""
    printf "%-30s %10s %10s %10s %10s\n" "Model" "Time(s)" "RTF" "GPU(MB)" "RSS(MB)"
    printf "%-30s %10s %10s %10s %10s\n" "─────" "───────" "───" "───────" "───────"

    for JSON_FILE in "$RESULTS_DIR"/*_metrics.json; do
        [ -f "$JSON_FILE" ] || continue
        MODEL=$(python3 -c "import json; print(json.load(open('$JSON_FILE'))['model'])")
        TOTAL=$(python3 -c "import json; print(f\"{json.load(open('$JSON_FILE'))['total_inference_s']:.2f}\")")
        RTF=$(python3 -c "import json; print(f\"{json.load(open('$JSON_FILE'))['rtf']:.2f}\")")
        GPU=$(python3 -c "import json; print(f\"{json.load(open('$JSON_FILE'))['peak_gpu_mb']:.1f}\")")
        RSS=$(python3 -c "import json; print(f\"{json.load(open('$JSON_FILE'))['peak_rss_mb']:.1f}\")")
        printf "%-30s %10s %10s %10s %10s\n" "$MODEL" "$TOTAL" "$RTF" "$GPU" "$RSS"
    done

    echo ""
    echo "Output files:"
    for WAV in "$RESULTS_DIR"/*_output.wav; do
        [ -f "$WAV" ] || continue
        SIZE=$(du -h "$WAV" | cut -f1)
        echo "  $(basename "$WAV"): $SIZE"
    done
} | tee "$SUMMARY"

echo ""
echo "Results saved to: $RESULTS_DIR/"
echo "Listen to the WAV files and compare voice quality."
