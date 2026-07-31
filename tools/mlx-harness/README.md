# mlx-harness

macOS verification harness for the vendored Kokoro/Misaki MLX code. It
compiles the app's live iOS sources (per-file symlinks into
`ios/Runner/{Kokoro,Misaki}Vendored`) into a CLI so numeric changes can be
proven bit-exact on the Mac before any phone round-trip.

## Setup

```sh
./link-sources.sh          # re-create symlinks (run after adding files)
swift build

# SwiftPM does not build the MLX metallib; compile it once by hand:
M=.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal
AIR=$(mktemp -d)
(cd $M && for f in *.metal; do xcrun metal -c "$f" -I . -o "$AIR/${f%.metal}.air"; done)
xcrun metallib $AIR/*.air -o "$(pwd)/.build/arm64-apple-macosx/debug/mlx.metallib"

# Resources load via Bundle.main == the executable dir:
cp ../../ios/Runner/MisakiVendored/Resources/* .build/debug/
cp ../../ios/Runner/KokoroVendored/Resources/config.json .build/debug/
mkdir -p .build/debug/Resources && cp ../../ios/Runner/MisakiVendored/Resources/*.json .build/debug/Resources/

# Kokoro model files (pinned release, sha-verified — see model_download_service.dart):
#   .asr-eval/kokoro-mlx/kokoro-v1_0.safetensors + voices.npz
```

## Commands

```sh
# BART G2P: greedy-decode words, print word<TAB>phonemes<TAB>tokenIds + timings.
.build/debug/harness bart .build/debug/us_bart_config.json .build/debug/us_bart.safetensors words.txt

# Full synthesis: raw Float32 samples (cold + .warm second run) + timings.
# MLXRandom is seeded, so identical code produces byte-identical output —
# diff the .f32 files to prove a refactor is behavior-preserving.
.build/debug/harness synth <model.safetensors> <voices.npz> af_heart 1.0 text.txt out.f32
```

Known trap: the DurationEncoder zeros-pad scatter looks dead but shapes MLX
kernel fusion — removing it perturbs audio at the 1e-3 level. See the comment
at its site.
