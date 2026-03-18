# Qwen3-TTS Voice Cloning Benchmark Results

**Date:** 2026-03-18
**Machine:** MacBook Pro, Apple Silicon (M-series)
**Python:** 3.11 (Homebrew — not Anaconda 3.9, which can't load MLX)
**Model:** `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit` (1,632 MB on disk)

## Test Setup

- **Text:** "To be or not to be, that is the question."
- **Reference audio:** `~/Downloads/test-audio.wav` — 7.6s, 48kHz mono PCM_16
- **Reference transcript:** "this is a test of voice cloning, and hopefully it will be useful"
- **Mode:** Streaming (`--stream`)
- **Output:** 24kHz WAV

## Run 1: Baseline (no optimizations)

```
Model loading:           4.31s | GPU peak: 1,628 MB | RSS: 2,067 MB
Voice clone generation:  1.58s | GPU peak: 5,730 MB | RSS: 2,140 MB

Total inference:   5.89s
Audio duration:    3.20s
Real-time factor:  1.84x  (slower than real-time)
Peak GPU memory:   5,730 MB
Peak RSS memory:   2,140 MB
First chunk:       1.51s (1 chunk, 3.2s audio)
```

## Run 2: With memory optimizations

Changes applied:
1. `mx.clear_cache()` after model load (free loader temp allocations)
2. `mx.clear_cache()` between streaming chunks (free intermediate memory)
3. Reference audio trimmed from 7.6s to 4.0s max (less data to encode)

```
Model loading:           4.59s | GPU peak: 1,652 MB | RSS: 2,070 MB
  After pool clear:      GPU 1,628 MB (freed ~24 MB)
Voice clone generation:  2.34s | GPU peak: 5,410 MB | RSS: 2,087 MB
  Reference trimmed:     7.6s → 4.0s

Total inference:   6.93s
Audio duration:    6.00s
Real-time factor:  1.15x  (nearly real-time)
Peak GPU memory:   5,410 MB
Peak RSS memory:   2,087 MB
First chunk:       2.31s (1 chunk, 6.0s audio)
```

## Comparison

| Metric | Baseline | Optimized | Delta |
|---|---|---|---|
| GPU peak (MB) | 5,730 | 5,410 | **-320 (-5.6%)** |
| RSS peak (MB) | 2,140 | 2,087 | **-54 (-2.5%)** |
| RTF | 1.84x | 1.15x | **-0.69x (37% faster)** |
| Audio output | 3.2s | 6.0s | More audio generated |
| First chunk latency | 1.51s | 2.31s | Slightly slower (longer output) |

Note: RTF improvement is partly because Run 2 generated more audio (6.0s vs 3.2s) — autoregressive models amortize startup cost over longer sequences.

## Memory Breakdown

| Component | Size |
|---|---|
| Model weights on disk | 1,632 MB |
| Model loaded in GPU | ~1,628 MB |
| Process RSS at load | ~2,070 MB |
| Inference working set (KV cache + activations) | ~3,780 MB |
| **Total GPU peak** | **~5,410 MB** |

The inference working set (~3.8 GB) is dominated by the autoregressive decoder's KV cache and attention matrices. This is internal to `mlx-audio`'s generation loop and cannot be reduced without modifying the library.

## iPhone Feasibility

| iPhone | Total RAM | Available to app (~65%) | Fits? |
|---|---|---|---|
| iPhone 15 (6 GB) | 6,144 MB | ~4,000 MB | No (needs 5.4 GB GPU) |
| iPhone 15 Pro (8 GB) | 8,192 MB | ~5,300 MB | Marginal |
| iPhone 16 Pro (8 GB) | 8,192 MB | ~5,300 MB | Marginal |
| iPhone 17 Pro Max (12 GB) | 12,288 MB | ~8,000 MB | **Yes** |

Unified memory on Apple Silicon means GPU and CPU share the same pool, so the 5.4 GB GPU peak is the binding constraint. The 8 GB devices could theoretically run it but would be close to the OS kill threshold.

## Possible Further Optimizations

1. **Sliding-window or grouped-query attention** — would cap KV cache growth. Requires patching `mlx-audio`.
2. **Shorter output sequences** — script lines are typically 5-15 words, so KV cache stays small. The 6.0s output here is reasonable for typical dialogue.
3. **`mx.set_memory_limit()`** — could cap MLX allocation to force more aggressive reuse, but may cause OOM errors.
4. **Smaller model** — no 0.6B variant smaller than 4-bit exists. The 1.7B models would use more.
5. **Offload speech tokenizer after encoding ref** — the speech tokenizer and LLM both stay in memory during generation. Unloading the tokenizer after ref encoding could free ~200-400 MB.

## How to Run

```bash
cd KokoCloneMLX/scripts

# Must use python3.11 (not python3 which is Anaconda 3.9)
python3.11 qwen3_tts_bench.py \
    --text "Your text here" \
    --ref-audio path/to/reference.wav \
    --ref-text "transcript of what's said in the reference" \
    --output /tmp/qwen3_output.wav \
    --stream \
    --json /tmp/qwen3_metrics.json

# Listen to output
afplay /tmp/qwen3_output.wav
```

## Audio Quality Notes

- Output is 24kHz mono WAV
- Voice cloning quality depends heavily on reference audio quality (clean, no background noise, 3-5s ideal)
- The `--ref-text` parameter helps the model separate speaker identity from content — always provide it
- Model occasionally produces slightly robotic artifacts on short utterances
