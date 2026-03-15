# On-Device ML Integration Plan: sherpa-onnx

## Decision

Use **sherpa-onnx** as the unified on-device ML runtime for TTS, voice cloning, and STT. This replaces the current system TTS fallback and stubbed Kokoro/F5-TTS services.

**Tagged baseline:** `pre-onnx` (commit before integration begins)

## Architecture Overview

```
sherpa-onnx (single Flutter dependency)
├── Kokoro v1.0 TTS (54 voices, 82M params)
├── ZipVoice (zero-shot voice cloning, 123M params)
└── Whisper STT (streaming, on-device)
```

All models run on-device. No cloud dependency for inference.

## Component Details

### 1. Kokoro TTS (Text-to-Speech)

- **Model:** Kokoro-82M v1.0 (multilingual, English + Chinese)
- **Voices:** 54 built-in (20 American English, 8 British English, others)
- **Performance:** ~3.3x faster than real-time on iPhone 13 Pro; iPhone 17 Pro Max will be faster
- **Model sizes:**
  - fp32: 326 MB
  - fp16: 163 MB (recommended)
  - int8 quantized: 92 MB (smallest, minor quality trade-off)
- **sherpa-onnx versions supported:**
  - `kokoro-en-v0_19` — English only, 11 voices
  - `kokoro-multi-lang-v1_0` — 53 voices, English + Chinese
  - `kokoro-multi-lang-v1_1` — 103 voices, English + Chinese
- **Output:** 24,000 Hz audio
- **Use case:** Default TTS for other characters' lines during rehearsal. Assign distinct voices to different characters for variety.

### 2. ZipVoice (Voice Cloning)

- **Model:** ZipVoice, 123M params, flow-matching-based zero-shot TTS
- **Built by:** k2-fsa team (same as sherpa-onnx)
- **Merged into sherpa-onnx:** PR #2487
- **API:** `OfflineTtsZipvoiceModelConfig` with `generate()` overload accepting prompt audio/text
- **Reference audio needed:** 3-10 seconds
- **Languages:** Chinese + English
- **Use case:** Actor records a castmate's lines → ZipVoice uses those recordings as reference to synthesize unrecorded lines in that castmate's voice
- **Replaces:** Current F5-TTS stub in `voice_clone_service.dart`

### 3. Whisper STT (Speech-to-Text)

- **Model:** OpenAI Whisper (multiple sizes: tiny through large-v3)
- **sherpa-onnx support:** Built-in, streaming capable
- **Use case:** Listen to actor speaking their lines during rehearsal, compare against script text for accuracy scoring
- **Replaces:** Current `speech_to_text` package (platform STT)

## Model Delivery Strategy

Models are too large to bundle in the app binary (App Store 200 MB OTA limit). Strategy:

1. **First launch:** Download models from HuggingFace/GitHub releases
2. **Cache locally:** Store in app documents directory via `path_provider`
3. **Show progress:** Download progress indicator on first use
4. **Recommended model set:**
   - Kokoro int8: ~92 MB
   - ZipVoice: ~TBD (estimate 100-150 MB)
   - Whisper small: ~150 MB
   - **Total first download: ~350-400 MB**

## Integration Path

### Flutter Package
- **Package:** `sherpa_onnx` on pub.dev (v1.12.29+, 93 likes, ~9,420 weekly downloads)
- **Platforms:** iOS, Android, macOS, Windows, Linux
- **License:** Apache 2.0

### Files to Modify

| File | Change |
|------|--------|
| `pubspec.yaml` | Add `sherpa_onnx`, remove `flutter_tts` and `speech_to_text` |
| `lib/data/services/tts_service.dart` | Replace system TTS with sherpa-onnx Kokoro |
| `lib/data/services/voice_clone_service.dart` | Replace F5-TTS stub with ZipVoice |
| `lib/data/services/stt_service.dart` | Replace platform STT with sherpa-onnx Whisper |
| `lib/features/rehearsal/rehearsal_screen.dart` | Update audio priority chain |

### New Files

| File | Purpose |
|------|---------|
| `lib/data/services/model_manager.dart` | Download, cache, and version-check ONNX models |
| `lib/features/settings/model_download_screen.dart` | UI for model download progress |

## Audio Priority Chain (Rehearsal)

When playing another character's line:

1. **Real recording** by the primary actor for that character
2. **Real recording** by understudy (if fallback enabled)
3. **ZipVoice clone** — uses actor's recordings as reference voice (3+ seconds needed)
4. **Kokoro TTS** — high-quality neural TTS with assigned character voice
5. ~~System TTS~~ — removed, no longer needed

## STT Fine-Tuning

On-device Whisper fine-tuning is **not practical on iPhone**. The architecture:

1. Collect audio + transcript pairs on device during rehearsal
2. Upload training data to server
3. Server runs LoRA fine-tuning via whisperkittools or similar
4. Download small adapter weights (~5-10 MB) back to device
5. sherpa-onnx loads adapter at inference time

This matches the existing `SttAdaptationService` design.

## Alternatives Considered

### MLX Native (Swift platform channels)
- **kokoro-ios** for TTS (MLX Swift, Apple Neural Engine)
- **KokoClone/Kanade** for voice cloning (separate layer)
- **WhisperKit** for STT (MLX Swift)
- **Pros:** Best Apple Silicon performance, Neural Engine acceleration
- **Cons:** Three separate Swift dependencies, platform channels needed, more complex integration
- **Verdict:** Higher performance ceiling but significantly more integration work. sherpa-onnx provides a single unified API.

### kokoro_tts_flutter (dedicated package)
- Wraps flutter_onnxruntime + G2P phonemizer
- **Pros:** Simple API
- **Cons:** Archived repo (Dec 2025), no maintenance, only 7 likes, no voice cloning
- **Verdict:** Dead project, not suitable

## References

- [sherpa-onnx on pub.dev](https://pub.dev/packages/sherpa_onnx)
- [sherpa-onnx GitHub](https://github.com/k2-fsa/sherpa-onnx)
- [ZipVoice GitHub](https://github.com/k2-fsa/ZipVoice)
- [ZipVoice PR #2487](https://github.com/k2-fsa/sherpa-onnx/pull/2487)
- [Kokoro-82M on HuggingFace](https://huggingface.co/hexgrad/Kokoro-82M)
- [Kokoro-82M ONNX](https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX)
- [KokoClone (voice cloning)](https://github.com/Ashish-Patnaik/kokoclone)
- [WhisperKit (iOS STT)](https://github.com/argmaxinc/WhisperKit)
- [whisperkittools (fine-tuning)](https://github.com/argmaxinc/whisperkittools)
