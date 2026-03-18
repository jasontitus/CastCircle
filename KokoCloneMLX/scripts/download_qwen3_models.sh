#!/bin/bash
set -e

# Pre-download Qwen3-TTS models from HuggingFace for offline use.
#
# mlx-audio auto-downloads on first run, but this script lets you
# pre-cache the models so the benchmark runs without network access.
#
# Usage:
#   ./download_qwen3_models.sh [--model MODEL_ID]

DEFAULT_MODEL="mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit"

# Parse args
MODEL="$DEFAULT_MODEL"
while [[ $# -gt 0 ]]; do
    case $1 in
        --model) MODEL="$2"; shift 2 ;;
        --all) DOWNLOAD_ALL=1; shift ;;
        *) shift ;;
    esac
done

echo "═══════════════════════════════════════════════════"
echo "  Qwen3-TTS — Model Download"
echo "═══════════════════════════════════════════════════"
echo ""

# Check dependencies
python3 -c "import mlx_audio" 2>/dev/null || {
    echo "Installing mlx-audio..."
    pip install -q mlx-audio soundfile
}

if [ "$DOWNLOAD_ALL" = "1" ]; then
    MODELS=(
        "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit"
        "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"
        "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit"
        "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit"
    )
else
    MODELS=("$MODEL")
fi

for M in "${MODELS[@]}"; do
    SHORT=$(echo "$M" | sed 's|.*/||')
    echo "Downloading: $SHORT..."
    echo ""

    python3 -c "
import time
from mlx_audio.tts.utils import load_model

t0 = time.time()
print(f'  Fetching {\"$M\"}...')
model = load_model('$M')
elapsed = time.time() - t0
print(f'  Downloaded and loaded in {elapsed:.1f}s')

# Report cache size
try:
    from huggingface_hub import scan_cache_dir
    cache = scan_cache_dir()
    for repo in cache.repos:
        if '$SHORT'.replace('-', '--') in str(repo.repo_path) or '$SHORT' in str(repo.repo_path):
            print(f'  Cache size: {repo.size_on_disk / 1_048_576:.0f} MB')
            break
except Exception:
    pass
print()
"
done

echo "Available Qwen3-TTS model variants:"
echo ""
echo "  Voice cloning (Base models — use ref_audio + ref_text):"
echo "    mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit    (~1.7 GB, fastest)"
echo "    mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit    (~2.0 GB)"
echo "    mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16    (~2.5 GB)"
echo "    mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit    (~2.3 GB, best quality)"
echo "    mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit    (~3.1 GB)"
echo ""
echo "  Preset voices with emotion (CustomVoice — use speaker + instruct):"
echo "    mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"
echo "    mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"
echo ""
echo "  Voice design from description (VoiceDesign — use instruct):"
echo "    mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16"
echo ""
echo "To download a different model:"
echo "  ./download_qwen3_models.sh --model mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit"
echo ""
echo "To download all voice cloning variants:"
echo "  ./download_qwen3_models.sh --all"
