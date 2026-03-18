# On-Device ML Research for LineGuide

Date: 2026-03-14

## Use Cases

1. **TTS** — Speak other characters' lines during rehearsal so the actor can practice
2. **Voice Cloning** — Make TTS sound like the actual castmate using a few seconds of their recording
3. **STT** — Listen to the actor speaking their lines and score accuracy against the script
4. **STT Fine-tuning** — Adapt the speech model to recognize specific actors' voices/accents better

---

## Text-to-Speech Options

### Kokoro-82M (Current Best Open-Source TTS)

- **Parameters:** 82M (only model size available, no larger variant exists)
- **Architecture:** Based on StyleTTS 2
- **Output:** 24,000 Hz audio
- **Voices:** 54 pre-built (20 American English, 8 British English, others across 9 languages)
- **Performance:** ~3.3x faster than real-time on iPhone 13 Pro
- **Latest version:** v1.0 (multilingual), v1.1 (103 voices)
- **Model sizes:**
  - fp32: 326 MB
  - fp16: 163 MB
  - int8 quantized: 92 MB
- **License:** Apache 2.0
- **Source:** https://huggingface.co/hexgrad/Kokoro-82M

#### Kokoro Runtime Options

| Runtime | Package | Platform | Notes |
|---------|---------|----------|-------|
| sherpa-onnx | `sherpa_onnx` (pub.dev) | iOS, Android, all | ONNX Runtime, CPU. Supports v0.19, v1.0, v1.1 |
| kokoro-ios (MLX) | Swift Package Manager | iOS 18+, macOS | Apple Neural Engine via MLX Swift. 3.3x realtime on iPhone 13 |
| kokoro_tts_flutter | `kokoro_tts_flutter` (pub.dev) | All | **ARCHIVED Dec 2025** — dead project, do not use |
| kokoro-onnx | Python/JS | Server/browser | Reference implementation, not for mobile |

#### kokoro-ios Details (MLX Native)
- **Repo:** https://github.com/mlalma/kokoro-ios
- **Also:** https://github.com/adriancmurray/kokoro-ios (MLXFast variant)
- **Also:** https://github.com/mattmireles/kokoro-swift-mlx
- **Requires:** iOS 18.0+, MisakiSwift (G2P), MLXUtilsLibrary
- **Integration:** Swift Package Manager → Flutter platform channel
- **Advantage:** Runs on Apple Neural Engine, best performance on Apple Silicon
- **Disadvantage:** Requires Swift bridge code, iOS-only

---

## Voice Cloning Options

### ZipVoice (sherpa-onnx built-in)
- **Parameters:** 123M
- **Architecture:** Flow-matching-based zero-shot TTS
- **Built by:** k2-fsa team (same as sherpa-onnx)
- **Reference audio needed:** 3-10 seconds
- **Languages:** English + Chinese
- **Integration:** Already merged into sherpa-onnx (PR #2487)
- **API:** `OfflineTtsZipVoiceModelConfig` with `generateWithConfig()` accepting reference audio/text
- **Source:** https://github.com/k2-fsa/ZipVoice
- **Verdict:** Best option for sherpa-onnx path. Single dependency, proper API.

### KokoClone (Kokoro + Kanade Voice Conversion) ⭐ MLX Port In Progress
- **Approach:** Kokoro generates speech → Kanade Tokenizer converts timbre to match reference
- **Reference audio needed:** 3-10 seconds
- **Modes:** Text-to-speech (with voice conversion) and audio-to-audio (direct conversion)
- **Runs on:** CPU or GPU, on-device capable
- **Source:** https://github.com/Ashish-Patnaik/kokoclone
- **MLX Port:** `KokoCloneMLX/` — standalone Swift package with test app
- **Components (all ported to MLX Swift):**
  - WavLM-Base+ (94M params, ~360 MB) — SSL feature extractor
  - Kanade-25Hz (118M params, ~470 MB) — content encoder + mel decoder
  - Vocos mel-24kHz (13.5M params, ~54 MB) — neural vocoder
- **Total model size:** ~884 MB (FP32), est. ~450 MB (FP16)
- **Est. RAM:** ~1.5-2.0 GB during inference
- **Status:** Code complete, pending model conversion + on-device testing
- **Verdict:** Best option for MLX/native path. Smallest total footprint of all voice cloning options.

### KVoiceWalk (Experimental)
- **Approach:** Random walk algorithm to evolve Kokoro voice style tensors toward target
- **Reference audio needed:** 20-30 seconds
- **Quality:** 93% similarity after 10,000 iterations (from 71% baseline)
- **Source:** https://github.com/RobViren/kvoicewalk
- **Verdict:** Research proof-of-concept, too slow for production.

### Kokoro Voice Blending
- **Approach:** Blend two existing Kokoro voices using weighted averaging or spherical interpolation
- **Tool:** https://github.com/tsmdt/kokoro-MLX-blender
- **No reference audio needed** — just picks/mixes from 54 built-in voices
- **Verdict:** Quick approximation, no actual cloning.

### F5-TTS (Previous Plan)
- **Parameters:** ~300M+
- **ONNX export exists:** https://github.com/DakeQQ/F5-TTS-ONNX
- **No sherpa-onnx integration**
- **Verdict:** Too large for mobile, no easy integration path. Replaced by ZipVoice.

### Speaklone (Reference Implementation)
- **What:** iOS/macOS app running a 0.6B voice model on-device using MLX-Swift
- **Key techniques:**
  - Strict memory ceiling (~3.5 GB) enforced during inference
  - Aggressive MLX cache clearing between generations (`GPU.clearCache()`)
  - Chunked decoding to stream audio while model is still generating (hides latency)
- **Relevance:** Proves 0.6B-class models can run on iPhones with careful memory management. The chunked-decode streaming pattern is directly applicable to our KokoClone MLX pipeline.

### Other Voice Cloning Models (Not Recommended for Mobile)
- **CosyVoice2-0.5B** — 500M params, too large
- **OpenVoice** — No ONNX mobile pipeline
- **mlx-audio CSM-1B** — macOS only, variable quality

---

## Speech-to-Text Options

### Whisper via sherpa-onnx
- **Models:** Whisper tiny through large-v3
- **API:** `OfflineRecognizer` with `OfflineWhisperModelConfig`
- **Features:** Transcription, translation, token timestamps, segment timestamps
- **Sample rate:** 16,000 Hz
- **Integration:** Already in sherpa-onnx Flutter package
- **Model sizes:**
  - tiny: ~39 MB
  - base: ~74 MB
  - small: ~244 MB
  - medium: ~769 MB
  - large-v3: ~1.5 GB
- **Recommendation:** Use small (~244 MB) for good accuracy/size tradeoff

### WhisperKit (MLX Native, iOS)
- **Repo:** https://github.com/argmaxinc/WhisperKit
- **Platform:** iOS 18+, macOS 14+
- **Features:** Streaming, word timestamps, VAD, speaker diarization
- **Integration:** Swift Package Manager → Flutter platform channel
- **Advantage:** Apple Neural Engine acceleration
- **Verdict:** Best option for MLX/native path

### sherpa-onnx Streaming STT (Non-Whisper)
- **Models:** Transducer, Paraformer, Zipformer2CTC, NemoCTC
- **API:** `OnlineRecognizer` — processes audio chunks in real-time
- **Features:** Endpoint detection, hotwords
- **Advantage:** Streaming (results as you speak) vs Whisper which is offline (process after recording)
- **Note:** For rehearsal line matching, streaming may be better UX (show match % as actor speaks)

---

## STT Fine-Tuning

### On-Device Fine-Tuning
- **iPhone:** Not practical. Whisper fine-tuning requires too much memory/compute.
- **iPad (8GB+ RAM):** Theoretically possible with MLX Swift LoRA, demonstrated at WWDC 2025.
- **Mac:** Fully supported via whisperkittools or MLX.

### Recommended Architecture (Already in SttAdaptationService)
1. **Collect on device:** Pair actor recordings with script text during rehearsal
2. **Upload to server:** Send audio + transcript pairs
3. **Fine-tune on server:** LoRA fine-tuning via whisperkittools (https://github.com/argmaxinc/whisperkittools)
4. **Download adapter:** Small LoRA weights (~5-10 MB) back to device
5. **Load at inference:** sherpa-onnx or WhisperKit loads adapter alongside base model

---

## Chosen Architecture: sherpa-onnx

### Why sherpa-onnx over MLX Native

| Factor | sherpa-onnx | MLX Native |
|--------|------------|------------|
| Dependencies | 1 Flutter package | 3+ Swift packages + platform channels |
| TTS | Kokoro (built-in) | kokoro-ios (separate) |
| Voice cloning | ZipVoice (built-in) | KokoClone (separate, needs porting) |
| STT | Whisper (built-in) | WhisperKit (separate) |
| Cross-platform | iOS + Android + desktop | iOS only |
| Integration effort | Low (Dart API) | High (Swift bridges) |
| Performance | ONNX Runtime (CPU) | Apple Neural Engine |
| Maintenance | Active (9,400 downloads/week) | Multiple small repos |

**Decision:** sherpa-onnx for unified, cross-platform, single-dependency integration. MLX native path remains viable for future iOS-specific optimization.

### Model Download Budget

| Model | Size | Purpose |
|-------|------|---------|
| Kokoro int8 | ~92 MB | TTS |
| ZipVoice | ~100-150 MB (est.) | Voice cloning |
| Whisper small | ~244 MB | STT |
| Silero VAD | ~2 MB | Voice activity detection |
| **Total** | **~440-490 MB** | First-launch download |

### sherpa_onnx Flutter API Summary

```dart
// TTS with Kokoro
final tts = OfflineTts(OfflineTtsConfig(
  model: OfflineTtsModelConfig(
    kokoro: OfflineTtsKokoroModelConfig(
      model: 'kokoro.onnx', voices: 'voices.bin', tokens: 'tokens.txt',
    ),
  ),
));
final audio = tts.generate(text: 'Hello', sid: 0, speed: 1.0);
// Returns: GeneratedAudio { Float32List samples, int sampleRate }

// Voice cloning with ZipVoice
final cloneTts = OfflineTts(OfflineTtsConfig(
  model: OfflineTtsModelConfig(
    zipVoice: OfflineTtsZipVoiceModelConfig(
      tokens: '...', encoder: '...', decoder: '...', vocoder: '...',
    ),
  ),
));
final audio = cloneTts.generateWithConfig(
  text: 'Line to speak',
  config: OfflineTtsGenerationConfig(
    referenceAudio: refSamples,      // Float32List from castmate recording
    referenceSampleRate: 24000,
    referenceText: 'What they said',  // Transcript of reference
  ),
);

// STT with Whisper
final recognizer = OfflineRecognizer(OfflineRecognizerConfig(
  model: OfflineModelConfig(
    whisper: OfflineWhisperModelConfig(
      encoder: 'encoder.onnx', decoder: 'decoder.onnx',
      language: 'en', task: 'transcribe',
    ),
    tokens: 'tokens.txt',
  ),
));
final stream = recognizer.createStream();
stream.acceptWaveform(samples: audioData, sampleRate: 16000);
recognizer.decode(stream);
final result = recognizer.getResult(stream); // .text, .tokens, .timestamps

// Streaming STT (real-time)
final online = OnlineRecognizer(OnlineRecognizerConfig(...));
final stream = online.createStream();
stream.acceptWaveform(samples: chunk, sampleRate: 16000);
if (online.isReady(stream)) {
  final result = online.getResult(stream);
}
if (online.isEndpoint(stream)) {
  online.reset(stream); // Ready for next utterance
}

// VAD
final vad = VoiceActivityDetector(config: VadModelConfig(
  sileroVad: SileroVadModelConfig(model: 'silero_vad.onnx'),
));
vad.acceptWaveform(samples);
if (vad.isDetected()) { ... }
```

### Key Implementation Notes

- All objects require manual `.free()` calls to avoid memory leaks
- Audio samples must be `Float32List` normalized to [-1.0, 1.0]
- Call `initBindings()` once at app startup before using any sherpa-onnx API
- Models are loaded from filesystem paths (not assets) — must download/extract first
- `GeneratedAudio` returns raw PCM samples — write to WAV file or play via `just_audio`

---

## References

- [sherpa-onnx pub.dev](https://pub.dev/packages/sherpa_onnx)
- [sherpa-onnx GitHub](https://github.com/k2-fsa/sherpa-onnx)
- [ZipVoice](https://github.com/k2-fsa/ZipVoice)
- [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M)
- [Kokoro-82M ONNX](https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX)
- [kokoro-ios](https://github.com/mlalma/kokoro-ios)
- [KokoClone](https://github.com/Ashish-Patnaik/kokoclone)
- [WhisperKit](https://github.com/argmaxinc/WhisperKit)
- [whisperkittools](https://github.com/argmaxinc/whisperkittools)
- [Silero VAD](https://github.com/snakers4/silero-vad)
- [sherpa-onnx Kokoro docs](https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/kokoro.html)
- [sherpa-onnx ZipVoice PR #2487](https://github.com/k2-fsa/sherpa-onnx/pull/2487)
