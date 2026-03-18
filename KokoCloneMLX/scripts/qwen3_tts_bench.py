#!/usr/bin/env python3
"""
Qwen3-TTS voice cloning benchmark — instrumented for comparison with KokoClone.

Usage:
    pip install mlx-audio soundfile
    python qwen3_tts_bench.py --text "Hello world" --ref-audio ref.wav --ref-text "..." --output output.wav
    python qwen3_tts_bench.py --text "Hello world" --ref-audio ref.wav --stream  # chunked decoding

Metrics reported (matching KokoClone test app):
    • MLX GPU active/peak memory per phase
    • Process RSS per phase
    • Wall-clock time per phase
    • Real-time factor (RTF)
    • JSON export for automated comparison
"""

import argparse
import json
import os
import resource
import time

import mlx.core as mx
import numpy as np


def get_rss_mb():
    """Get current process RSS in MB."""
    # maxrss on macOS is in bytes, on Linux in KB
    import sys
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    if sys.platform == "darwin":
        return rss / 1_048_576.0
    return rss / 1024.0


def get_memory_snapshot():
    """Take a memory snapshot."""
    mx.eval(mx.array(0))  # Force pending ops
    return {
        "gpu_active_mb": mx.get_active_memory() / 1_048_576.0,
        "gpu_peak_mb": mx.get_peak_memory() / 1_048_576.0,
        "rss_mb": get_rss_mb(),
        "timestamp": time.time(),
    }


def instrument(name, func):
    """Run a function with memory/time instrumentation."""
    mx.reset_peak_memory()
    mem_before = get_memory_snapshot()
    start = time.time()

    result = func()

    mx.eval(mx.array(0))  # Force completion
    elapsed = time.time() - start
    mem_after = get_memory_snapshot()

    metrics = {
        "name": name,
        "duration_s": elapsed,
        "gpu_peak_mb": mem_after["gpu_peak_mb"],
        "gpu_delta_mb": mem_after["gpu_active_mb"] - mem_before["gpu_active_mb"],
        "rss_after_mb": mem_after["rss_mb"],
        "rss_delta_mb": mem_after["rss_mb"] - mem_before["rss_mb"],
    }
    return result, metrics


def format_report(model_name, metrics_list, audio_duration_s):
    """Format a benchmark report matching the Swift app output."""
    lines = []
    lines.append("╔══════════════════════════════════════════════════════════════╗")
    lines.append(f"║  BENCHMARK: {model_name:<47}║")
    lines.append("╠══════════════════════════════════════════════════════════════╣")
    lines.append("║  Phase                  Time(s)   GPU(MB)   RSS(MB)        ║")
    lines.append("║  ──────────────────── ────────── ────────── ─────────       ║")

    total_time = 0
    for m in metrics_list:
        total_time += m["duration_s"]
        phase = m["name"][:22].ljust(22)
        t = f"{m['duration_s']:8.2f}"
        gpu = f"{m['gpu_peak_mb']:8.1f}"
        rss = f"{m['rss_after_mb']:8.1f}"
        lines.append(f"║  {phase} {t}   {gpu}   {rss}       ║")

    lines.append("║  ──────────────────── ────────── ────────── ─────────       ║")

    rtf = total_time / audio_duration_s if audio_duration_s > 0 else 0
    peak_gpu = max(m["gpu_peak_mb"] for m in metrics_list)
    peak_rss = max(m["rss_after_mb"] for m in metrics_list)

    lines.append("║                                                             ║")
    lines.append(f"║  Total inference:  {total_time:8.2f}s                               ║")
    lines.append(f"║  Audio duration:   {audio_duration_s:8.2f}s                               ║")
    lines.append(f"║  Real-time factor: {rtf:8.2f}x                               ║")
    lines.append(f"║  Peak GPU memory:  {peak_gpu:8.1f} MB                             ║")
    lines.append(f"║  Peak RSS memory:  {peak_rss:8.1f} MB                             ║")

    # Show first-chunk latency if any phase used streaming
    for m in metrics_list:
        if m.get("streaming") and m.get("first_chunk_s") is not None:
            lines.append(f"║  First chunk:      {m['first_chunk_s']:8.2f}s  ({m['num_chunks']} chunks)              ║")
            break

    lines.append("║                                                             ║")
    lines.append("╚══════════════════════════════════════════════════════════════╝")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Qwen3-TTS Voice Cloning Benchmark")
    parser.add_argument("--text", required=True, help="Text to synthesize")
    parser.add_argument("--ref-audio", required=True, help="Reference speaker WAV file (3-10s)")
    parser.add_argument("--ref-text", default="", help="Transcript of reference audio")
    parser.add_argument("--output", default="qwen3_output.wav", help="Output WAV path")
    parser.add_argument("--model", default="mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit",
                        help="HuggingFace model ID")
    parser.add_argument("--stream", action="store_true",
                        help="Chunked decoding: process and report chunks as they arrive")
    parser.add_argument("--json", default=None, help="Export metrics as JSON")
    args = parser.parse_args()

    print(f"=== Qwen3-TTS Voice Cloning Benchmark (Instrumented) ===\n")
    all_metrics = []

    # Baseline
    baseline = get_memory_snapshot()
    print(f"Baseline — GPU: {baseline['gpu_active_mb']:.1f} MB, RSS: {baseline['rss_mb']:.1f} MB\n")

    # 1. Load model
    print(f"[1/3] Loading model: {args.model}...")
    def load_model_fn():
        from mlx_audio.tts.utils import load_model
        return load_model(args.model)

    model, load_metrics = instrument("Model loading", load_model_fn)
    all_metrics.append(load_metrics)
    print(f"  ✓ {load_metrics['duration_s']:.2f}s | GPU peak: {load_metrics['gpu_peak_mb']:.1f} MB | "
          f"RSS: {load_metrics['rss_after_mb']:.1f} MB\n")

    # 2. Generate speech with voice cloning
    print(f"[2/3] Generating speech (voice cloning)...")
    print(f"  Text: \"{args.text[:60]}{'...' if len(args.text) > 60 else ''}\"")
    print(f"  Reference: {args.ref_audio}")

    import soundfile as sf

    if args.stream:
        # Chunked decoding: process and save chunks as they arrive
        mx.reset_peak_memory()
        mem_before = get_memory_snapshot()
        gen_start = time.time()

        sample_rate = 24000
        audio_arrays = []
        chunk_metrics = []
        first_chunk_time = None

        for i, result in enumerate(model.generate(
            text=args.text,
            ref_audio=args.ref_audio,
            ref_text=args.ref_text if args.ref_text else None,
        )):
            chunk_time = time.time() - gen_start
            audio_data = result.audio
            if hasattr(audio_data, 'tolist'):
                chunk_np = np.array(audio_data.tolist(), dtype=np.float32).flatten()
            else:
                chunk_np = np.array(audio_data, dtype=np.float32).flatten()

            audio_arrays.append(chunk_np)
            chunk_dur = len(chunk_np) / sample_rate

            if first_chunk_time is None:
                first_chunk_time = chunk_time
                print(f"  ▸ First chunk: {first_chunk_time:.2f}s ({chunk_dur:.2f}s audio)")
            else:
                print(f"  ▸ Chunk {i+1}: +{chunk_time:.2f}s ({chunk_dur:.2f}s audio)")

            chunk_metrics.append({
                "chunk": i + 1,
                "wall_time_s": chunk_time,
                "audio_duration_s": chunk_dur,
                "samples": len(chunk_np),
            })

        mx.eval(mx.array(0))
        gen_elapsed = time.time() - gen_start
        mem_after = get_memory_snapshot()

        gen_metrics = {
            "name": "Voice clone generation",
            "duration_s": gen_elapsed,
            "gpu_peak_mb": mem_after["gpu_peak_mb"],
            "gpu_delta_mb": mem_after["gpu_active_mb"] - mem_before["gpu_active_mb"],
            "rss_after_mb": mem_after["rss_mb"],
            "rss_delta_mb": mem_after["rss_mb"] - mem_before["rss_mb"],
            "streaming": True,
            "first_chunk_s": first_chunk_time,
            "num_chunks": len(chunk_metrics),
            "chunks": chunk_metrics,
        }
        all_metrics.append(gen_metrics)
        print(f"  ✓ {gen_elapsed:.2f}s total | first chunk: {first_chunk_time:.2f}s | "
              f"{len(chunk_metrics)} chunks | GPU peak: {gen_metrics['gpu_peak_mb']:.1f} MB\n")

        # Save concatenated output
        print(f"[3/3] Saving output...")
        if audio_arrays:
            audio_np = np.concatenate(audio_arrays)
            sf.write(args.output, audio_np, sample_rate)
            audio_duration = len(audio_np) / sample_rate
            print(f"  Saved: {args.output}")
            print(f"  Duration: {audio_duration:.1f}s")
            print(f"  Size: {os.path.getsize(args.output) // 1024} KB")
        else:
            audio_duration = 0
            print("  WARNING: No audio generated!")
    else:
        # Batch mode: collect all chunks, then save
        audio_result = None
        def generate_fn():
            nonlocal audio_result
            results = list(model.generate(
                text=args.text,
                ref_audio=args.ref_audio,
                ref_text=args.ref_text if args.ref_text else None,
            ))
            audio_result = results
            return results

        _, gen_metrics = instrument("Voice clone generation", generate_fn)
        all_metrics.append(gen_metrics)
        print(f"  ✓ {gen_metrics['duration_s']:.2f}s | GPU peak: {gen_metrics['gpu_peak_mb']:.1f} MB\n")

        # 3. Save output
        print(f"[3/3] Saving output...")

        if audio_result and len(audio_result) > 0:
            audio_arrays = []
            for r in audio_result:
                audio_data = r.audio
                if hasattr(audio_data, 'tolist'):
                    audio_arrays.append(np.array(audio_data.tolist(), dtype=np.float32))
                else:
                    audio_arrays.append(np.array(audio_data, dtype=np.float32))

            audio_np = np.concatenate(audio_arrays) if len(audio_arrays) > 1 else audio_arrays[0]
            audio_np = audio_np.flatten()

            sample_rate = 24000
            sf.write(args.output, audio_np, sample_rate)

            audio_duration = len(audio_np) / sample_rate
            print(f"  Saved: {args.output}")
            print(f"  Duration: {audio_duration:.1f}s")
            print(f"  Size: {os.path.getsize(args.output) // 1024} KB")
        else:
            audio_duration = 0
            print("  WARNING: No audio generated!")

    # Model storage
    print(f"\nModel storage:")
    try:
        from huggingface_hub import scan_cache_dir
        cache_info = scan_cache_dir()
        for repo in cache_info.repos:
            if args.model.replace("/", "--") in str(repo.repo_path) or args.model.split("/")[-1] in str(repo.repo_path):
                print(f"  {args.model}: {repo.size_on_disk / 1_048_576:.0f} MB")
                break
        else:
            print(f"  (Could not determine cache size for {args.model})")
    except Exception:
        print(f"  (Install huggingface_hub to show cache size)")

    # Report
    print()
    # Use the generation time as the relevant metric for audio duration
    inference_duration = audio_duration if audio_duration > 0 else 1.0
    print(format_report(
        f"Qwen3-TTS ({args.model.split('/')[-1]})",
        all_metrics,
        inference_duration,
    ))

    # JSON export
    if args.json:
        total_time = sum(m["duration_s"] for m in all_metrics)
        peak_gpu = max(m["gpu_peak_mb"] for m in all_metrics)
        peak_rss = max(m["rss_after_mb"] for m in all_metrics)

        # Find streaming metrics if present
        stream_info = {}
        for m in all_metrics:
            if m.get("streaming"):
                stream_info = {
                    "streaming": True,
                    "first_chunk_s": m["first_chunk_s"],
                    "num_chunks": m["num_chunks"],
                    "chunks": m["chunks"],
                }
                break

        export = {
            "model": "qwen3_tts_" + args.model.split("/")[-1].replace("-", "_"),
            "audio_duration_s": audio_duration,
            "total_inference_s": total_time,
            "rtf": total_time / inference_duration,
            "peak_gpu_mb": peak_gpu,
            "peak_rss_mb": peak_rss,
            **stream_info,
            "phases": all_metrics,
        }
        with open(args.json, "w") as f:
            json.dump(export, f, indent=2)
        print(f"\nMetrics exported to: {args.json}")

    print(f"\nOutput: {args.output} ({audio_duration:.1f}s)")
    print("Listen and compare with the reference speaker.")


if __name__ == "__main__":
    main()
