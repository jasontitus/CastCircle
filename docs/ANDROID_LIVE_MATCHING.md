# Android live line-matching

> **Status (2026-07-30): implemented** — option 2 below. One native
> `AudioRecord` (16 kHz mono) in `AndroidSttPlugin` fans out to an AAC/.m4a
> encoder (`MediaCodec`+`MediaMuxer`, same channel contract as before), to Dart
> as `onPcm` chunks, and to peak-level events. `LiveAsrService` runs a
> sherpa-onnx streaming Zipformer (Kroko-ASR community English model, CC-BY-SA,
> chosen by measured head-to-head — see
> `integration_test/asr_streaming_macos_test.dart`) in a background isolate and
> feeds the same matching pipeline iOS uses
> (`_handleRecognizedForLine`). Model files (~68 MB) download on demand via
> Settings → AI Models with pinned sizes + SHA-256. Without the model the old
> record-only silence-advance behavior remains, with a once-per-rehearsal tip.
> Verified on a Galaxy A35: word-perfect transcript of the bundled test
> utterance through the full isolate pipeline, simultaneous with .m4a capture
> (`integration_test/android_live_matching_test.dart`).

## Autonomous test harness

`scripts/phone-harness.sh` runs the full rehearsal loop on a connected device
or emulator with no human in the loop — it sideloads both model packs (from
`.asr-eval/`, git-ignored; re-stage from the release assets if absent), grants
the mic, sets volume, and prints PROBE metrics: TTS pipeline latency per line
and mic→recognizer match scores. On a real phone the round trip is acoustic
(speaker → air → mic); on an emulator, whose virtual mic can't hear its own
speaker, the harness detects the silent capture and injects PCM directly
(validates decoding/matching, not the mic). Emulator note: give the AVD
6 GB RAM (`hw.ramSize = 6144`) — at the default 1.5 GB the Kokoro session
swaps and every metric is garbage.

## The problem

On iOS, rehearsal does two things at once with the microphone: `SFSpeechRecognizer`
matches the actor's words against the script line by line, and an `AVAudioFile` tap
captures the audio so the take can be shared with the cast.

Android can't do both. `SpeechRecognizer` and the media recorder each want exclusive
use of the mic, so `rehearsal_screen.dart` takes a different path there
(`_startRecordOnlyCapture`): it records the line and advances on mic-silence, with no
word matching. The actor gets no "you said it right" feedback and no mid-line
recovery — just a pause detector.

## What was tried: `RecognizerIntent.EXTRA_AUDIO_SOURCE`

Since API 31, `SpeechRecognizer` accepts a `ParcelFileDescriptor` of app-supplied
audio instead of opening the mic itself. If honoured, that would solve this outright:
CastCircle owns the mic, writes the WAV, and forwards the same PCM to the recognizer.

The docs do not promise the feature works on any given device, and — importantly — an
unsupported implementation **silently opens the mic anyway** rather than failing. So
it had to be measured on real hardware, not read about.

### Result: not viable

Probed on a Samsung Galaxy A35 (SM-A356U, Android 16 / API 36) with
`AudioSourcePlugin.kt` (commit `4b48bc9`, since removed — recover from git to re-run
on another device). Platform TTS synthesized a known phrase, which was fed to the
recognizer through the descriptor while a concurrent `AudioRecord` tested whether the
mic was still free.

Four configurations were tried — on-device and default recognizers, each with a pipe
and with a file-backed descriptor:

| Configuration | Transcript | Error | Mic free? |
|---|---|---|---|
| on-device, pipe | none | none | yes (1024 samples read) |
| on-device, file | none | none | — |
| default, pipe | none | none | yes (1024 samples read) |
| default, file | none | none | — |

**No configuration produced a transcript, and none raised an error.** The recognizer
accepts the request, declines to open the mic, and returns nothing.

Two earlier runs were invalid and their conclusions should be ignored if you find them
in the history:

- `flutter test` installs and then *uninstalls* the app, which wipes any
  `adb shell pm grant`. The resulting error 9 (`INSUFFICIENT_PERMISSIONS`) and
  `micFree: false` were artifacts of a missing `RECORD_AUDIO` grant, not real
  findings. The probe grew a 60-second grant-wait loop so the permission can be
  granted mid-run.
- The probe initially hardcoded 16 kHz while Android TTS on this device emits
  **24 kHz**, so the recognizer was being handed time-stretched audio. Fixed by
  parsing the WAV `fmt ` chunk; the final runs declared the true format and also
  tried a correct 16 kHz resample. Neither helped.

The one encouraging signal — the mic stayed free — is weak evidence on its own. A
recognizer that ignores the request entirely also never touches the mic, so
`micFree: true` is equally consistent with "the whole request was a no-op".

## Options

### 1. Mode switch — about a day

Ask per session which the actor wants: live matching (recognizer owns the mic, no
recording produced) or capture (today's behaviour). Cheap, no new dependencies, but
it makes the two features mutually exclusive and pushes the choice onto the user,
who mostly wants both.

### 2. Own the mic, fan the audio out — roughly a week *(recommended)*

Stop using the platform recognizer during rehearsal. Open the mic once with
`AudioRecord`, then send the same PCM buffers two places: to the WAV writer, and to
an on-device streaming recognizer running in-process. The conflict disappears because
only one component ever opens the mic, and Android reaches feature parity with iOS
rather than approaching it.

[`sherpa_onnx`](https://pub.dev/packages/sherpa_onnx) (1.13.4, published 2026-07-07)
is the natural fit: ONNX Runtime based, actively maintained, and its streaming
Zipformer models emit partial hypotheses continuously, which is what line matching
needs. The alternatives are stale — `vosk_flutter` last shipped in 2023 and
`whisper_flutter_new` in 2024, and Whisper is chunk-oriented rather than streaming.
CastCircle already ships ONNX Runtime for PaddleOCR, so this is a smaller addition
than it appears; the main new costs are the model download (tens of MB, via the
existing `model_download_service` path) and matching the tuning quality of the
existing iOS matcher.

Worth noting this would also give iOS a path off `SFSpeechRecognizer`, which is
currently failing in the field with `kAFAssistantErrorDomain 216`.

### 3. Reconstruct audio from the recognizer — not possible

`SpeechRecognizer` exposes no audio to the caller. Listed only so it isn't
re-investigated.

## Recommendation

Option 2. Option 1 is a reasonable stopgap if Android parity is needed before the
work lands, but it is throwaway effort — nothing in it survives option 2.
