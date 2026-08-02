# Kindle Fire (Fire OS) support — tested 2026-08-01

**Verdict: the app runs on a Google-Play-Services-free Android device.**
Tested against Fire OS 8's base platform (Android 11 / API 30) with an AOSP
system image — the closest reproducible stand-in, since Amazon discontinued
its own Fire OS emulator images.

## How to reproduce the test environment

```sh
sdkmanager "system-images;android-30;default;arm64-v8a"   # "default" = AOSP, no GMS
avdmanager create avd -n FireOS8_like \
  -k "system-images;android-30;default;arm64-v8a" -d "10.1in WXGA (Tablet)"
# Fire HD 10 geometry; keep RAM modest, CPU rendering (see config.ini):
#   hw.ramSize=2048  hw.lcd.width=1920  hw.lcd.height=1200  hw.lcd.density=240
emulator -avd FireOS8_like -no-window -no-audio -gpu swiftshader_indirect -memory 2048
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Confirm the environment really is Fire-like:
`adb shell pm list packages | grep -c com.google.android.gms` → **0**.

## Measured results (release APK, build 132)

| Check | Result |
|---|---|
| Install + cold start | OK, no crash |
| Google Play Services present | **0 packages** |
| `PaddleOcrPlugin` model load | **OK — 356 ms, 18708 keys, 2 threads** |
| Firebase init | **"Firebase initialized OK"** (warns "Play Store missing", non-fatal) |
| Tablet UI (1920x1200) | Renders correctly; auth, onboarding, home, import screens all fine |
| Kokoro TTS | Correctly reports "model not downloaded" → system-TTS fallback |

`GooglePlayServicesUtil: ... requires the Google Play Store, but it is
missing` appears in logcat — a warning from the Firebase SDK, not a crash.

## Why it works

Everything on the critical path is self-contained:

- **OCR** — PaddleOCR via ONNX Runtime, models bundled in the APK.
- **Live line matching** — sherpa-onnx, own-the-mic.
- **TTS** — Kokoro via sherpa-onnx; system TTS as fallback.
- **ML Kit** (import fallback only) — the plugin pulls
  `com.google.mlkit:text-recognition`, the BUNDLED variant that ships the
  model in the APK. It is NOT `play-services-mlkit-text-recognition`, so it
  needs no Play Services either.
- **`android.speech.SpeechRecognizer`** (absent on Fire OS) is already off
  the critical path: Android can't share the mic between SpeechRecognizer
  and the recorder, so rehearsal uses record-only capture plus sherpa
  matching, and startup explicitly tolerates STT init failure on Android
  (`if (!sttOk && !Platform.isAndroid)`).

## Not yet verified on this environment

- A full PDF import end-to-end. The plugin's models load, but taps did not
  register in the emulator's file picker under swiftshader, so the import
  itself was exercised only on real Android hardware (Galaxy A35).
- Rehearsal audio (emulator launched with `-no-audio`).
- Model downloads over the network from the device.
- Real Fire OS extras: Amazon's own TTS engine, Amazon Appstore packaging
  and review, and Fire's older armv7 hardware (we ship arm64 + armeabi-v7a).
