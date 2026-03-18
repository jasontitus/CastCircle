# Plan: Fix KokoClone MLX Weight Loading

## Problem

The Swift model loaders (`WavLM.swift`, `Kanade.swift`, `Vocos.swift`) expect weight keys that don't match what `convert_models.py` produces. The CLI crashes immediately with "Unexpectedly found nil while unwrapping an Optional value" during model loading.

## Root Cause

The Swift code was written assuming a different weight key naming convention than what PyTorch's `state_dict()` produces. There are three categories of mismatch across all three models.

## Build Note

`swift build` cannot compile MLX's Metal shaders. Must use:
```bash
xcodebuild -scheme kokoclone-test -configuration Release -destination 'platform=macOS' -derivedDataPath .xcodebuild build
```
Binary ends up at `.xcodebuild/Build/Products/Release/kokoclone-test`.

---

## WavLM (wavlm_base_plus.safetensors — 199 keys)

### Issue 1: Key path prefixes

| Swift expects | Safetensors has |
|---|---|
| `feature_projection.layer_norm.weight` | `encoder.feature_projection.layer_norm.weight` |
| `encoder.layer_norm.weight` | `encoder.transformer.layer_norm.weight` |
| `encoder.layers.0.attention...` | `encoder.transformer.layers.0.attention...` |
| `encoder.pos_conv_embed.conv.weight_v` | `encoder.transformer.pos_conv_embed.conv.parametrizations.weight.original0` |

**Fix:** Update `WavLMBaseP.init(weights:)` key strings. The prefix pattern is:
- Feature extractor: no prefix (correct as-is)
- Feature projection: `encoder.` prefix needed
- Transformer layers: `encoder.transformer.` prefix needed
- Encoder norm: `encoder.transformer.` prefix needed

### Issue 2: Combined QKV attention weights

Swift expects separate Q/K/V projections:
```
encoder.layers.0.attention.q_proj.weight  [768, 768]
encoder.layers.0.attention.k_proj.weight  [768, 768]
encoder.layers.0.attention.v_proj.weight  [768, 768]
```

Safetensors has combined `in_proj`:
```
encoder.transformer.layers.0.attention.attention.in_proj_weight  [2304, 768]
encoder.transformer.layers.0.attention.attention.in_proj_bias    [2304]
```

**Fix:** Either:
- **(A) Split in Swift** — load `in_proj_weight` and slice into Q/K/V (first 768 rows = Q, next 768 = K, last 768 = V). Same for bias.
- **(B) Split in convert_models.py** — pre-split during conversion and save as separate keys.

Option A is simpler (no re-conversion needed):
```swift
let inProjW = w("encoder.transformer.layers.\(i).attention.attention.in_proj_weight")
let inProjB = w("encoder.transformer.layers.\(i).attention.attention.in_proj_bias")
qWeight = inProjW[0..<768]  // rows 0-767
kWeight = inProjW[768..<1536]
vWeight = inProjW[1536..<2304]
// Same slicing for bias
```

### Issue 3: Positional conv weight parameterization

Swift expects `weight_v` and `weight_g` (weight normalization decomposition):
```
encoder.pos_conv_embed.conv.weight_v
encoder.pos_conv_embed.conv.weight_g
```

Safetensors has PyTorch's parametrization format:
```
encoder.transformer.pos_conv_embed.conv.parametrizations.weight.original0  [1, 128, 1]   (g)
encoder.transformer.pos_conv_embed.conv.parametrizations.weight.original1  [768, 128, 48] (v)
```

**Fix:** Map `original0` → `weight_g`, `original1` → `weight_v`. The shapes confirm this: `original0` is the magnitude (g) and `original1` is the direction (v).

### Issue 4: Attention out_proj path

Swift expects:
```
encoder.layers.0.attention.out_proj.weight
```

Safetensors has (note double `attention`):
```
encoder.transformer.layers.0.attention.attention.out_proj.weight
```

**Fix:** Update the key string in `WavLMTransformerLayer.init`.

### Issue 5: rel_attn_embed key

Swift expects:
```
encoder.layers.0.attention.rel_attn_embed  (no .weight suffix)
```

Safetensors has:
```
encoder.transformer.layers.0.attention.rel_attn_embed.weight
```

**Fix:** Add `.weight` suffix and `transformer.` prefix.

---

## Kanade (kanade_25hz.safetensors — 282 keys)

### Issue 1: Swift only loads 28 of 282 keys

The Swift `Kanade.swift` loader uses hardcoded key patterns that match only a subset. Many weights for the global encoder, local encoder transformer layers, mel decoder, and FSQ are loaded via string interpolation in loops, but the loop-generated keys don't match the safetensors keys.

**Approach:** Print all 282 actual keys (see `/tmp/model_keys_dump.txt`), then update each section of `Kanade.init(weights:)` to use matching key names. The major subsections:

| Component | Safetensors key prefix | ~Keys |
|---|---|---|
| Local encoder (transformer) | `local_encoder.transformer.*` | ~100 |
| Global encoder (ConvNeXt + pool) | `global_encoder.backbone.*`, `global_encoder.pool.*`, `global_encoder.proj.*` | ~40 |
| Mel prenet | `mel_prenet.*` | ~4 |
| Mel decoder (transformer) | `mel_decoder.transformer.*` | ~80 |
| PostNet | `mel_postnet.*` | ~20 |
| FSQ projections | `fsq_proj_in.*`, `fsq_proj_out.*` | ~4 |
| Conv downsample | `conv_downsample.*` | ~2 |
| Speaker proj | `speaker_proj.*` | ~2 |

### Issue 2: mel_postnet key interpolation

Swift has `mel_postnet.convolutions.\(i).0.weight` but the actual key format needs verification against the safetensors dump.

---

## Vocos (vocos_mel_24khz.safetensors — 81 keys)

### Issue 1: Swift only loads 8 of 81 keys

Similar to Kanade — the Swift loader has hardcoded keys for a small subset. The full model has:

| Component | Safetensors key prefix | ~Keys |
|---|---|---|
| Backbone (ConvNeXt, 8 layers) | `backbone.convnext.{0-7}.*` | ~65 |
| Embedding layer | `backbone.embed.*` | ~2 |
| Norm | `backbone.norm.*` | ~2 |
| ISTFT head | `head.istft.*`, `head.out.*` | ~12 |

---

## Recommended Fix Order

### Step 1: Fix WavLM loader (highest priority — blocks everything)
1. Update all key strings in `WavLMBaseP.init(weights:)`
2. Add `in_proj_weight` → Q/K/V splitting logic in `WavLMTransformerLayer.init`
3. Map `parametrizations.weight.original{0,1}` → `weight_g/weight_v`
4. Fix all path prefixes (`encoder.transformer.layers.X` not `encoder.layers.X`)
5. Test: model should load without crashing

### Step 2: Fix Kanade loader
1. Dump all 282 keys with shapes from safetensors
2. Map each to the corresponding Swift property
3. Update `Kanade.init(weights:)` with correct key strings
4. Test: model should load

### Step 3: Fix Vocos loader
1. Dump all 81 keys with shapes
2. Map to Swift properties
3. Update `Vocos.init(weights:)`
4. Test: model should load

### Step 4: End-to-end test
```bash
.xcodebuild/Build/Products/Release/kokoclone-test ./models /tmp/source_tts.wav ~/Downloads/test-audio.wav /tmp/output.wav --json /tmp/metrics.json
```

### Step 5: Verify audio quality
Listen to output.wav — should have source content with reference speaker's voice.

---

## Reference Files

- Full key dump: `/tmp/model_keys_dump.txt` (regenerate with `python3 -c "from safetensors import safe_open; ..."`)
- Test audio: `/tmp/source_tts.wav` (Qwen3-TTS generated), `~/Downloads/test-audio.wav` (reference)
- Qwen3-TTS is working via: `python3.11 -c "from mlx_audio.tts.utils import load_model; ..."`
- The Qwen3 bench script (`scripts/qwen3_tts_bench.py`) should work with `python3.11` (not `python3` which is 3.9 on this machine)

## Alternative: Fix in convert_models.py instead

Rather than fixing 3 Swift files, you could update `convert_models.py` to rename keys during conversion to match what Swift expects. This is cleaner if the Swift key names are the "correct" convention you want to standardize on. But it requires re-running conversion after any change.
