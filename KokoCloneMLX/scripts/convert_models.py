#!/usr/bin/env python3
"""
Convert KokoClone models (WavLM-base+, Kanade-25hz, Vocos-mel-24khz) from
PyTorch to MLX-compatible safetensors format.

Usage:
    pip install -r requirements.txt
    python convert_models.py --output-dir ./models

This creates:
    models/wavlm_base_plus.safetensors   (~360 MB)
    models/kanade_25hz.safetensors       (~470 MB)
    models/vocos_mel_24khz.safetensors   (~54 MB)
"""

import argparse
import os
from pathlib import Path

import numpy as np
import torch
from safetensors.torch import save_file


def convert_wavlm(output_dir: Path):
    """Convert WavLM-base+ to safetensors with MLX-compatible key names."""
    import torchaudio

    print("Loading WavLM-base+ via torchaudio...")
    bundle = torchaudio.pipelines.WAVLM_BASE_PLUS
    model = bundle.get_model()
    model.eval()

    state_dict = model.state_dict()

    # Remap torchaudio key names to our Swift convention.
    # torchaudio uses a flat structure; we organize by component.
    remapped = {}

    for key, tensor in state_dict.items():
        # Convert to float32 numpy for safetensors
        t = tensor.detach().float()

        # Conv1d weights in PyTorch are (out_ch, in_ch/groups, kernel)
        # MLX Conv1d expects (out_ch, kernel, in_ch/groups)
        if "conv" in key and "weight" in key and t.dim() == 3:
            t = t.transpose(1, 2).contiguous()

        # Linear weights in PyTorch are (out, in)
        # MLX Linear expects (out, in) — same, no transpose needed

        remapped[key] = t

    out_path = output_dir / "wavlm_base_plus.safetensors"
    save_file(remapped, str(out_path))
    size_mb = out_path.stat().st_size / 1024 / 1024
    print(f"  Saved {out_path} ({size_mb:.1f} MB, {len(remapped)} tensors)")


def convert_kanade(output_dir: Path):
    """Convert Kanade-25hz to safetensors."""
    from huggingface_hub import hf_hub_download

    print("Downloading Kanade-25hz model...")
    model_path = hf_hub_download(
        repo_id="frothywater/kanade-25hz",
        filename="model.safetensors",
    )

    # Kanade is already in safetensors format, but we need to transpose
    # Conv1d weights for MLX compatibility.
    from safetensors.torch import load_file

    state_dict = load_file(model_path)

    remapped = {}
    for key, tensor in state_dict.items():
        t = tensor.detach().float()

        # Transpose Conv1d weights: PyTorch (out, in/g, k) -> MLX (out, k, in/g)
        if any(
            prefix in key
            for prefix in [
                "conv_downsample",
                "mel_conv_upsample",
                "mel_postnet.convolutions",
            ]
        ):
            if "weight" in key and t.dim() == 3:
                t = t.transpose(1, 2).contiguous()

        # Global encoder ConvNeXt Conv1d weights
        if "global_encoder.backbone" in key:
            if ("embed.weight" in key or "dwconv.weight" in key) and t.dim() == 3:
                t = t.transpose(1, 2).contiguous()

        # Global encoder pooling Conv1d weights
        if "global_encoder.pooling.attn" in key:
            if "weight" in key and t.dim() == 3:
                t = t.transpose(1, 2).contiguous()

        remapped[key] = t

    out_path = output_dir / "kanade_25hz.safetensors"
    save_file(remapped, str(out_path))
    size_mb = out_path.stat().st_size / 1024 / 1024
    print(f"  Saved {out_path} ({size_mb:.1f} MB, {len(remapped)} tensors)")


def convert_vocos(output_dir: Path):
    """Convert Vocos mel-24khz to safetensors."""
    from huggingface_hub import hf_hub_download

    print("Downloading Vocos mel-24khz model...")
    model_path = hf_hub_download(
        repo_id="charactr/vocos-mel-24khz",
        filename="pytorch_model.bin",
    )

    state_dict = torch.load(model_path, map_location="cpu", weights_only=True)

    remapped = {}
    for key, tensor in state_dict.items():
        t = tensor.detach().float()

        # Transpose Conv1d weights for MLX
        if "embed.weight" in key and t.dim() == 3:
            t = t.transpose(1, 2).contiguous()
        if "dwconv.weight" in key and t.dim() == 3:
            t = t.transpose(1, 2).contiguous()

        # Skip feature_extractor (mel spec computation is done in code)
        if key.startswith("feature_extractor."):
            continue

        remapped[key] = t

    out_path = output_dir / "vocos_mel_24khz.safetensors"
    save_file(remapped, str(out_path))
    size_mb = out_path.stat().st_size / 1024 / 1024
    print(f"  Saved {out_path} ({size_mb:.1f} MB, {len(remapped)} tensors)")


def generate_mel_filterbank(output_dir: Path):
    """Pre-compute and save the mel filterbank matrix for 24kHz/1024-FFT/100-mels."""
    import torchaudio.transforms as T

    # Create a MelScale transform to extract the filterbank
    n_fft = 1024
    n_mels = 100
    sample_rate = 24000
    n_freqs = n_fft // 2 + 1  # 513

    mel_scale = T.MelScale(
        n_mels=n_mels, sample_rate=sample_rate, n_stft=n_freqs
    )
    # The filterbank is stored as mel_scale.fb, shape (n_freqs, n_mels) = (513, 100)
    fb = mel_scale.fb.detach().float()

    save_file({"mel_filterbank": fb}, str(output_dir / "mel_filterbank.safetensors"))
    print(f"  Saved mel_filterbank.safetensors ({fb.shape})")


def main():
    parser = argparse.ArgumentParser(
        description="Convert KokoClone models to MLX safetensors"
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("./models"),
        help="Directory to save converted models",
    )
    parser.add_argument(
        "--models",
        nargs="+",
        default=["wavlm", "kanade", "vocos", "mel_fb"],
        choices=["wavlm", "kanade", "vocos", "mel_fb"],
        help="Which models to convert",
    )
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)

    if "wavlm" in args.models:
        convert_wavlm(args.output_dir)
    if "kanade" in args.models:
        convert_kanade(args.output_dir)
    if "vocos" in args.models:
        convert_vocos(args.output_dir)
    if "mel_fb" in args.models:
        generate_mel_filterbank(args.output_dir)

    print("\nDone! Model files ready for MLX Swift.")
    total = sum(
        f.stat().st_size for f in args.output_dir.iterdir() if f.suffix == ".safetensors"
    )
    print(f"Total: {total / 1024 / 1024:.1f} MB")


if __name__ == "__main__":
    main()
