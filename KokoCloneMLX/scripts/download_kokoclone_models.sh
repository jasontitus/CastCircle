#!/bin/bash
set -e

# Download and convert KokoClone models (WavLM + Kanade + Vocos) to MLX safetensors.
#
# Downloads from HuggingFace, converts Conv1d weight layouts for MLX, and saves
# to ../models/ (~884 MB total).
#
# Usage:
#   ./download_kokoclone_models.sh [--output-dir DIR]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR/../models}"

# Parse --output-dir flag
while [[ $# -gt 0 ]]; do
    case $1 in
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

echo "═══════════════════════════════════════════════════"
echo "  KokoClone MLX — Model Download & Conversion"
echo "═══════════════════════════════════════════════════"
echo ""
echo "Output directory: $OUTPUT_DIR"
echo ""

# Check Python dependencies
echo "Checking dependencies..."
python3 -c "import torch, torchaudio, safetensors" 2>/dev/null || {
    echo "Installing Python dependencies..."
    pip install -q torch torchaudio safetensors huggingface_hub numpy
}

echo ""
echo "Models to download:"
echo "  • WavLM-Base+      (~360 MB)  — SSL feature extractor"
echo "  • Kanade-25Hz      (~470 MB)  — voice tokenizer/decoder"
echo "  • Vocos mel-24kHz  (~54 MB)   — neural vocoder"
echo "  • Mel filterbank   (~200 KB)  — DSP lookup table"
echo "  ─────────────────────────────"
echo "  Total:             ~884 MB"
echo ""

python3 "$SCRIPT_DIR/convert_models.py" --output-dir "$OUTPUT_DIR"

echo ""
echo "Models ready at: $OUTPUT_DIR/"
ls -lh "$OUTPUT_DIR"/*.safetensors 2>/dev/null || echo "(no safetensors files found)"
echo ""
echo "Next: cd $(dirname "$SCRIPT_DIR") && swift build -c release"
