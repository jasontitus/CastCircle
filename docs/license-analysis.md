# CastCircle — Dependency & Model License Analysis

**Question:** Can CastCircle ship as a **closed-source commercial product**? Is there any **GPL / AGPL / LGPL** (or otherwise commercially-incompatible) code or model that ships in the app?

**Verdict: Yes — CastCircle can ship as a closed-source commercial product**, provided it adds a third-party **acknowledgements/attributions screen**. Nothing copyleft is compiled into or shipped with the app, and no model weight is non-commercial. Verified 2026-06-14 (code-dependency scan + per-model license confirmation against each model card).

---

## Bottom line

- **No GPL / AGPL / LGPL is compiled into the app.** Of 202 resolved Dart
  packages, the only copyleft is **MPL-2.0** in `dbus`/`gtk`/`nm` — **Linux-desktop
  only, never built into the iOS/Android app.** iOS Pods + vendored native are all
  MIT / BSD / Apache-2.0.
- The two historical commercial risks both came back **clean**:
  - **NVIDIA Parakeet STT → CC-BY-4.0** — commercial explicitly allowed; only cost
    is an attribution to NVIDIA.
  - **Gemma 4 → Apache-2.0** — Google relicensed Gemma 4 away from the restrictive
    Gemma Terms of Use (no prohibited-use pass-through). (It's also disabled in the
    import flow.)
- **One latent trap, currently NOT triggered:** a Kokoro **download path** pulls a
  sherpa-onnx archive that bundles **GPLv3 `espeak-ng-data`**. No sherpa-onnx /
  espeak-ng is linked or compiled into the app (absent from all lockfiles), so GPL
  code does **not** ship — but the dead download path should be removed.

---

## Methodology
- **Dart:** parsed `.dart_tool/package_config.json` (202 packages); scanned every
  `LICENSE` for copyleft signatures.
- **iOS:** scanned all `ios/Pods/**/LICENSE`; read `ios/LocalPackages/*/LICENSE`.
- **Models:** identified each bundled/downloaded model and confirmed its weight
  license against its model card (links below).

---

## Code dependencies — commercial-safe
| Layer | Finding |
|---|---|
| **Dart (202 pkgs)** | No GPL/AGPL/LGPL. MPL-2.0 only in `dbus`/`gtk`/`nm` (Linux-desktop, not shipped). Rest BSD/MIT/Apache-2.0. |
| **iOS CocoaPods** | No copyleft. DKImagePickerController/DKPhotoGallery/SDWebImage/SwiftyGif (MIT); Firebase/Google (Apache-2.0); onnxruntime-objc/-c (MIT). |
| **Vendored (`ios/LocalPackages/`)** | `LlamaCpp` = MIT (llama.cpp); `kokoro-ios` = MIT (© 2025 Lassi Maksimainen); `parakeet-stt` = original MLX-Swift code, **no LICENSE file** (add one). |

## Components & models that ship in / are downloaded by the app
| Component | What it is | License (+ source) | Commercial? | Obligations |
|---|---|---|---|---|
| llama.cpp (xcframework b8777) | LLM inference engine | MIT — [llama.cpp](https://github.com/ggml-org/llama.cpp/blob/master/LICENSE) | ✅ | Attribution |
| KokoroSwift (kokoro-ios) | MLX Swift TTS engine | MIT | ✅ | Attribution |
| ParakeetSTT (parakeet-stt) | MLX Swift STT reimpl | Original code (no header); deps MIT | ✅ | Add LICENSE; credit MLX/NVIDIA |
| mlx-swift 0.31.4 | Apple MLX framework | MIT | ✅ | Attribution |
| MisakiSwift (MisakiVendored) | G2P for Kokoro (+ BART G2P weights) | Apache-2.0 — [MisakiSwift](https://github.com/mlalma/MisakiSwift) | ✅ | Attribution/NOTICE |
| ONNX Runtime 1.26.0 | Inference engine for PaddleOCR | MIT (Microsoft) | ✅ | Attribution |
| PDFium (pdfium_flutter / pdfrx) | PDF rendering | Apache-2.0 OR BSD-3-Clause | ✅ | Attribution |
| Firebase 12.14.0 | analytics/crashlytics/perf | Apache-2.0 | ✅ | Attribution; Google data terms |
| **Google ML Kit Text Recognition** | OCR fallback (phasing out for PaddleOCR) | **Proprietary** — [ML Kit Terms](https://developers.google.com/ml-kit/terms) | ✅ with obligations | Ship-in-app OK; **no extract/redistribute**; Google terms |
| **PP-OCRv6** weights (`assets/paddle_ocr/`) | On-device OCR | **Apache-2.0** — [PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR/blob/main/LICENSE) | ✅ | Attribution |
| **Kokoro-82M** weights (downloaded) | TTS model | **Apache-2.0** — [mlx-community/Kokoro-82M-bf16](https://huggingface.co/mlx-community/Kokoro-82M-bf16) | ✅ | Attribution |
| **NVIDIA Parakeet-TDT-0.6B-v3** weights (~2.5 GB, downloaded) | STT model | **CC-BY-4.0** — [model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) | ✅ | **Must credit NVIDIA, link license, note changes** |
| **Gemma 4 E2B** GGUF (~3.35 GB, downloaded; **disabled** in import) | Script-cleanup LLM | **Apache-2.0** — [Gemma 4 / Apache-2.0](https://ai.google.dev/gemma/apache_2) | ✅ | Attribution only |
| sherpa-onnx Kokoro archive (bundles **espeak-ng**) | Alt ONNX TTS path | sherpa-onnx Apache-2.0; **espeak-ng = GPLv3+** | **Not shipped** | Remove dead download path (see below) |

---

## Blockers
**None block shipping.** Two items need action but are not blockers:

1. **GPLv3 espeak-ng — latent, not triggered.** `ModelManager.downloadKokoro()` /
   `_downloadOnnxKokoro` (in `ai_models_screen.dart`) can download a sherpa-onnx
   archive bundling `espeak-ng-data` (GPLv3+). Nothing links/compiles sherpa-onnx
   or espeak-ng (absent from `Podfile.lock`, `pubspec.lock`, every `Package.swift`;
   the runtime TTS is Kokoro MLX + Misaki, Apache-2.0; the `.eSpeakNG` branch is
   gated behind an unresolved `eSpeakNGLib`). So **GPL code does not ship** — but
   remove the download path to kill the latent risk.
2. **Google ML Kit (proprietary).** Allowed in-app; cannot extract/redistribute the
   SDK. Goes under a "Powered by Google" note, not the OSS list.

## Required attributions (acknowledgements screen)
- **MIT/BSD:** llama.cpp, KokoroSwift, mlx-swift, ONNX Runtime, PDFium (or BSD), plus
  transitive Apple/HuggingFace SwiftPM deps (swift-transformers, swift-huggingface,
  swift-jinja, swift-nio, swift-crypto, swift-collections, ZIPFoundation, yyjson,
  EventSource).
- **Apache-2.0:** MisakiSwift/Misaki, Firebase, **PP-OCRv6 weights**, **Kokoro-82M
  weights**, **Gemma 4 weights** (ship NOTICE/license; mark modified files).
- **CC-BY-4.0 (mandatory, specific wording):** **NVIDIA Parakeet-TDT-0.6B-v3** —
  credit NVIDIA, link the CC-BY-4.0 license, indicate the mlx-community conversion
  is a change. This is the one custom attribution that cannot be omitted.
- **Proprietary (separate "Powered by" note):** Google ML Kit, Firebase/Google services.

## Recommendations
1. **Add the acknowledgements/licenses screen** (highest priority: the NVIDIA
   Parakeet CC-BY-4.0 credit + the Apache-2.0 NOTICEs).
2. **Remove the sherpa-onnx/espeak Kokoro download path** (`ModelManager.downloadKokoro`,
   `_kokoroArchiveUrl`, `_downloadOnnxKokoro`, `espeak-ng-data` refs) — pure latent
   GPL risk with no active consumer.
3. **Remove the Gemma model download** (`gemma_model` in `model_download_service.dart`,
   `_gemmaSection` in the download screen) — inference is already disabled
   (`_scriptAiEnabled => false`); it only fetches a dormant 3.35 GB. (Apache-2.0, so
   product cleanup, not a legal requirement — keep if re-enabling script AI.)
4. **Add a LICENSE to the vendored `parakeet-stt`** package to credit the MLX/NVIDIA
   lineage cleanly.

_Confirmed against each model card; Parakeet = CC-BY-4.0, Gemma 4 = Apache-2.0._
