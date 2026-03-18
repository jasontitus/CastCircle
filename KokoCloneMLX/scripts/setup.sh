#!/bin/bash
set -e

# One-command setup: install deps, download all models, build KokoClone.
#
# Usage:
#   cd KokoCloneMLX/scripts
#   ./setup.sh
#
# After this completes, run the comparison:
#   ./compare.sh source.wav reference.wav "ref transcript" "Text to speak"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "═══════════════════════════════════════════════════"
echo "  KokoClone MLX — Full Setup"
echo "═══════════════════════════════════════════════════"
echo ""

# ── 1. Python dependencies ──────────────────────────────────

echo "[1/4] Installing Python dependencies..."
pip install -q torch torchaudio safetensors huggingface_hub numpy mlx-audio soundfile 2>&1 | tail -1
echo "  ✓ Python packages installed"
echo ""

# ── 2. Download & convert KokoClone models ──────────────────

echo "[2/4] Downloading KokoClone models (~884 MB)..."
"$SCRIPT_DIR/download_kokoclone_models.sh" --output-dir "$PROJECT_DIR/models"
echo ""

# ── 3. Download Qwen3-TTS model ────────────────────────────

echo "[3/4] Downloading Qwen3-TTS 0.6B 4-bit (~1.7 GB)..."
"$SCRIPT_DIR/download_qwen3_models.sh"
echo ""

# ── 4. Build KokoClone Swift package ────────────────────────

echo "[4/4] Building KokoClone MLX Swift package..."
cd "$PROJECT_DIR"
swift build -c release 2>&1 | tail -5
echo "  ✓ Built: .build/release/kokoclone-test"
echo ""

# ── Summary ─────────────────────────────────────────────────

echo "═══════════════════════════════════════════════════"
echo "  Setup Complete!"
echo "═══════════════════════════════════════════════════"
echo ""
echo "KokoClone models: $PROJECT_DIR/models/"
ls -lh "$PROJECT_DIR/models/"*.safetensors 2>/dev/null | awk '{print "  " $NF ": " $5}'
echo ""
echo "Next steps:"
echo "  1. Get two WAV files:"
echo "     - source.wav: speech to convert (e.g., from Kokoro TTS)"
echo "     - reference.wav: 3-10 seconds of the target speaker"
echo ""
echo "  2. Run the comparison:"
echo "     cd $SCRIPT_DIR"
echo "     ./compare.sh source.wav reference.wav \"ref transcript\" \"Text to speak\""
echo ""
echo "  3. Listen to results/ and compare quality + resource usage"
