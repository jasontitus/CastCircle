# KokoClone MLX — Voice Cloning for Apple Silicon

Port of [KokoClone](https://github.com/Ashish-Patnaik/kokoclone) (Kokoro TTS + Kanade voice conversion) to Apple's MLX framework for on-device inference.

## Architecture

```
Source Audio (from Kokoro TTS)     Reference Audio (cast recording, 3-10s)
        │                                      │
        ▼                                      ▼
   ┌─────────┐                           ┌─────────┐
   │ WavLM   │  (layers 6+9 averaged)    │ WavLM   │  (layers 1+2 averaged)
   │ Base+   │                           │ Base+   │
   └────┬────┘                           └────┬────┘
        │                                      │
        ▼                                      ▼
  ┌───────────┐                         ┌──────────────┐
  │  Kanade   │  content tokens         │   Kanade     │  speaker embedding
  │  Encoder  │  (what is said)         │   Global Enc │  (who is speaking)
  └─────┬─────┘                         └──────┬───────┘
        │                                      │
        ▼                                      ▼
  ┌─────────────────────────────────────────────────┐
  │         Kanade Mel Decoder (AdaLN)              │
  │   content tokens + speaker embedding → mel      │
  └──────────────────────┬──────────────────────────┘
                         │
                         ▼
                   ┌───────────┐
                   │   Vocos   │  mel → waveform
                   │  Vocoder  │
                   └─────┬─────┘
                         │
                         ▼
                 Cloned Voice Audio (24kHz WAV)
```

## Requirements

- **macOS 14+** (Sonoma) or **iOS 17+**
- Apple Silicon (M1/M2/M3/M4)
- **Python 3.10+** (for model conversion only)
- ~900 MB disk space for models (FP32)
- ~1.5-2 GB RAM during inference

## Quick Start

### Step 1: Convert Models

```bash
cd scripts
pip install -r requirements.txt
python convert_models.py --output-dir ../models
```

This downloads and converts:
- WavLM-Base+ (~360 MB) — SSL feature extractor
- Kanade-25Hz (~470 MB) — voice tokenizer/decoder
- Vocos mel-24kHz (~54 MB) — neural vocoder
- Mel filterbank (~200 KB) — DSP lookup table

### Step 2: Build Test App

```bash
cd ..  # back to KokoCloneMLX/
swift build -c release
```

### Step 3: Test Voice Conversion

```bash
# You need two WAV files:
# 1. source.wav — speech to convert (e.g., from Kokoro TTS)
# 2. reference.wav — 3-10 seconds of the target speaker

swift run -c release kokoclone-test ./models source.wav reference.wav output.wav
```

### Step 4: Validate Output

Listen to `output.wav`. Check:
- ✅ **Words** match the source audio (content preserved)
- ✅ **Voice** sounds like the reference speaker (timbre transferred)
- ✅ **Quality** is clear without major artifacts
- ✅ **Speed** is near real-time (RTF < 1.0 on M1+)

## Model Sizes

| Component | Parameters | FP32 Size | Purpose |
|-----------|-----------|-----------|---------|
| WavLM-Base+ | 94M | ~360 MB | SSL feature extraction |
| Kanade-25Hz | 118M | ~470 MB | Content encoding + mel decoding |
| Vocos mel-24kHz | 13.5M | ~54 MB | Mel → waveform vocoding |
| **Total** | **~225M** | **~884 MB** | |

## How It Works (KokoClone Pipeline)

1. **WavLM** extracts deep speech features from raw audio at 50Hz
   - Layers 6+9 → linguistic/content features
   - Layers 1+2 → acoustic/speaker features

2. **Kanade Encoder** separates content from identity:
   - Local encoder (6-layer Transformer with RoPE) → content tokens
   - Global encoder (ConvNeXt + AttentiveStatsPool) → 128-dim speaker vector

3. **Kanade Decoder** reconstructs speech:
   - Mel prenet processes content tokens
   - Mel decoder (6-layer Transformer with AdaLN Zero) conditions on speaker vector
   - PostNet (4 Conv1d layers) refines mel spectrogram

4. **Vocos** converts mel spectrogram to waveform:
   - ConvNeXt backbone (8 layers)
   - ISTFT head (magnitude + phase → overlap-add)

## Integration with CastCircle

After validating the test app works:

1. Add `KokoCloneMLX` as a local Swift package dependency
2. Create `VoiceClonePlugin.swift` (Flutter platform channel)
3. Update `voice_clone_service.dart` to use the platform channel
4. Add model download entries to `model_download_service.dart`
5. Register plugin in `AppDelegate.swift`

The existing rehearsal audio fallback chain already checks `VoiceCloneService.canClone()` and calls `generateLine()` — just needs a working backend.

## Troubleshooting

**Build fails with MLX errors:**
Ensure Xcode 15+ and macOS 14+. MLX requires Apple Silicon.

**Model conversion fails:**
Check Python has torch and torchaudio installed. The WavLM model downloads from torchaudio's model hub.

**Output sounds robotic/garbled:**
This may indicate weight loading issues. Verify the safetensors files are the correct size (~360 + ~470 + ~54 MB).

**Out of memory:**
The full pipeline uses ~1.5-2 GB. Close other memory-intensive apps. For iPhones with 4 GB RAM, consider fp16 quantization.
