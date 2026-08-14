# Changelog

All notable changes to **CastCircle** — the actor line-learning and rehearsal app
(on-device OCR, TTS, and STT; cloud sync for sharing recordings across a cast).

The marketing version has been `0.1.1` throughout the TestFlight beta, so releases
are identified by their **TestFlight build number**. Dates are UTC. Recent releases
are described in detail; older history is condensed from commit notes.

---

## 0.1.1+150 — 2026-08-14

### Rehearsal
- **Fixed a mangled rehearsal header.** On a phone the controls (A−/A+,
  Fast, Read/Cue, Playing, progress) take nearly the whole row, leaving the
  scene title ~60dp — and with no line limit it wrapped one word-fragment
  per line ("ACT / I, Sc / ene / 1"), inflating the header to a third of the
  screen. The title now ellipsises on one line, and the location subtitle
  only shows where there's room for it (≥600dp). Found in a Play screenshot
  capture on the Galaxy, not by looking at the code.
- **"Tap your AirPods" no longer appears on Android**, where there are none;
  the hint names the headset button instead.

### Release tooling
- Play screenshots: the pipeline no longer throws away a whole capture run
  when the test reports a debug-only framework assertion after every frame
  has already landed — it converts what it captured and says loudly that the
  run failed. `--convert-only` re-runs just the conversion.
- The Play set is now an explicit, ordered 8 (Play's maximum), rehearsal
  first; anything captured but unused is named in the output. Preflight
  rejects more than 8 screenshots.
- The screenshot test no longer writes to the device it runs on: it used the
  real on-disk database (seeding a Hamlet production into whatever phone was
  attached) and left `auth_skipped` / `screenshot_mode` flipped. It now uses
  an in-memory database and restores both preferences.

---

## 0.1.1+149 — 2026-08-14

### App icon
- **New CastCircle artwork everywhere.** Every platform was still shipping
  the placeholder Flutter logo — including the Google Play listing icon and
  feature graphic. All of them now render from `assets/castcircleicon.jpeg`
  via `scripts/generate-icons.py`: iOS (15 sizes, opaque), macOS (Apple's
  rounded-rect grid), Android (legacy, round, and adaptive foreground /
  background layers), and the Play store graphics.
- **Dark launch screen.** The app is dark-only, but the launch window was
  white on iOS and on light-mode Android, so every cold start flashed white
  before the first frame. Both now launch on #121212 with the icon.

---

## 0.1.1+148 — 2026-08-14

First Android-ready build. Two months of iOS-only iteration folded in, plus
the OCR cleanup workflow rebuilt around seeing the original scanned page.

### Fixing a scanned script
- **See where a line came from.** Opening a flagged line's source page
  re-reads that page and highlights the exact region the text was taken
  from, scrolling it into view — so a garbled line is obvious at a glance
  instead of a hunt down the page.
- **Walk the whole queue in one place.** The page view steps through
  flagged lines (Prev / Next) with the text editable in place, plus
  "Looks right" to confirm a line and "Remove" to drop one you can see was
  crossed out. Same walk-through in the script editor for cleanup after an
  import is accepted.
- **Pages are right.** A mapping bug pinned most lines to the wrong page;
  98% now resolve to the page their text is actually on (measured against
  the full scan), up from 46%.

### Rehearsal
- **Background noise no longer stalls a line.** A completed line confirms
  on the evidence that it finished, instead of waiting for a silence that a
  noisy room never delivers.
- A line that can't be matched at all now advances with an explanation
  rather than sitting there.

### Import
- The screen stays awake through OCR: an 82-page script no longer takes
  three times longer because the phone froze the app mid-import.
- Android reads scanned PDFs with the same engine as iOS.

### Under the hood
- A 174-finding review pass across the app: background downloads survive
  the app being killed, database migrations can't silently mask a failure,
  the recording file can't be truncated by a race, and the join flow now
  requires the production's join code.

## 0.1.1+86 — 2026-06-15

Responsive polish for phones and tablets, plus two fixes targeting the top
complaints in competitor reviews (uneven recording loudness, lost rehearsal
progress).

### Tablets & phones
- **OCR review is now a two-pane master/detail on tablets** (≥720dp with a source
  PDF): the editable line list on the left, the selected line's scanned source
  page pinned on the right and following selection. Phones keep the single-column
  list with a modal page viewer.
- **`PdfPageView` reacts to selection changes** (`didUpdateWidget`): a full
  re-render when the page changes, a cheap zoom re-target when only the line moves
  within a page.
- **14 list/form screens now cap their content width on tablets** via the existing
  `ContentConstraint` helper (settings, cast manager, recordings browser, rehearsal
  history, join, auth, script import, character/scene editors, AI-models &
  model-download, voice config, etc.) so content no longer stretches edge-to-edge
  on an iPad. Phone layouts are unchanged. The recording studio stays full-bleed by
  design.
- **The rehearsal reading column is capped at 760dp on tablets** so script lines
  stay comfortably readable instead of spanning the full width.

### Rehearsal
- **Progress autosave + resume.** The current line position is checkpointed per
  production + scene + character + mode and restored on re-entry ("Resumed where you
  left off (line N) · Start over"). Saved debounced on advance, immediately on app
  background (`WidgetsBindingObserver`), and on dispose. A force-quit no longer drops
  you back to line 0. Checkpoints expire after 14 days and clear on scene-complete or
  restart.
- **Recording playback loudness normalization.** A new native `AudioAnalysisPlugin`
  measures each recording's RMS/peak from the file itself, so it works for recordings
  made locally *and* ones received from castmates over the cloud. A per-file volume is
  applied at every playback site (rehearsal primary + understudy, studio preview,
  recordings browser). just_audio on iOS can only attenuate, so this normalizes
  downward toward −18 dBFS with a 0.3 floor — collapsing a ~25 dB cross-recording
  spread to ~3.6 dB for the common case (verified on macOS against AAC tones). Gains
  are cached per path and prefetched so normalization adds no playback latency.

### Fixes
- **Data loss:** `saveScriptLines` now wraps its delete-then-insert in a single
  transaction, so a crash mid-save can no longer wipe a production's script lines
  with nothing restored.

---

## 0.1.1+85 — 2026-06-14

- **Low-OCR review list.** Imported lines are scored against a 2,936-word theatrical
  lexicon (plus rec-confidence from PaddleOCR) and bucketed into "review & edit" vs
  "likely not script" (margin notes / handwriting). An editable review screen lets
  the user correct misreads inline or bulk-remove non-dialogue; a sharper merged
  signal (tokenizer + diacritic handling) cut false positives.
- **PDF page viewer in the review flow** — a "View page" button opens the original
  scanned page (extracted into a reusable `PdfPageView`), and the script editor now
  rebuilds a stable `Documents/scripts/{id}.pdf` path so the source page survives an
  app reinstall.

## 0.1.1+84 — 2026-06-14
- PaddleOCR DBNet unclip 0.6 → **0.4**, recovering merged tight-leaded lines on
  dense scans (e.g. one page dropped from 13 low-OCR lines to 2).

## 0.1.1+83 — 2026-06-14
- **Stop speaking — and stop expecting — stage directions.** Parenthetical/bracketed
  directions (including OCR-dropped unclosed ones running to end of line) are stripped
  from both TTS playback and STT matching, so the app no longer reads "(MRS. GARDINER
  turns to the audience…)" aloud or penalizes the actor for not saying it.

## 0.1.1+82 — 2026-06-14
- **Faster cue-to-line response:** the rehearsal loop fast-advances after a brief
  silence once the actor has covered ≥90% of the line's words, instead of waiting out
  the full confirm window.

## 0.1.1+81 — 2026-06-14
- **Reduced rehearsal latency** between the actor's line and the next spoken line:
  the next other-character line's Kokoro TTS is prefetched in the background while the
  actor speaks, with a tunable "pause before next line" setting.
- Added a competitive-analysis doc (loved / pain-point review themes per competitor,
  and App-Store review-region notes).

## 0.1.1+80 — 2026-06-14
- **Removed the on-device Gemma LLM** ("script AI cleanup") entirely — ~3,500 lines —
  in favor of the PaddleOCR + heuristic-parser pipeline.
- PaddleOCR settled on a **static unclip (0.6) + per-page automatic render scale**
  (`min(6.0, max(1.0, 1800/longSidePt))`); no per-document auto-tuner needed.
- Committed a public-domain OCR test corpus (six pre-1929 scanned scripts, image-only),
  plus license-analysis and OCR-test-set-sources docs; added a `parse_stats` tool that
  runs the real `ScriptParser` on OCR text and scores the character roster against an
  answer key.

## 0.1.1+77–78 — 2026-06-14
- **Fixed the real "totally broken OCR output" bug:** `renderPage` was double-flipping
  the page (rendering it upside-down/mirrored). Found by building the actual Swift
  pipeline on the Mac rather than round-tripping to the phone.
- Tuned DBNet unclip for copier scans (1.3 → 0.8) to fix garbled character names; fixed
  on-device PaddleOCR box clipping; added a per-page OCR progress indicator for PDF
  import.

## 0.1.1+74–75 — 2026-06-14
- **Added on-device PaddleOCR (PP-OCRv6 small, fp32) via ONNX Runtime** as the import
  OCR engine (`PaddleOcrPlugin.swift`: PDFKit render → DBNet detection → CTC recognition),
  with ML Kit as fallback.
- Fixed an AI-cleanup relaunch loop (cancel/failure now clears the checkpoint; silent
  auto-resume replaced with a Resume/Discard prompt).

---

## On-device Gemma era — 2026-06-12 → 2026-06-13 (builds 69–72)

A since-removed experiment running Gemma 4 QAT on-device for script structuring.
Retained here as history:

- Ran Gemma 4 QAT on-device via llama.cpp / mlx-swift-lm with batched parallel and
  continuous-batching decode; act/scene-label normalization carried across chunks.
- Hardened generation: `<end_of_turn>` stop token, 800-token cap, live token streaming,
  load/generate phase surfacing, 120s timeout, runaway-gen cap, GPU-wedge abort+resume.
- Added a Script AI Debug screen; moved Supabase off the create/open-production UI path
  to fix latency; `ship-testflight.sh` one-command TestFlight ship via the ASC API key.
- Fixed multi-user recording sync (upsert conflict, stale takes, realtime channel leak);
  upgraded to Riverpod 3 / go_router 16; ported STT controller behavior.

---

## 0.1.1 release line — 2026-03-25 → 2026-04-05 (builds 57–58, Android parity)

- Add screenshot pipeline and README image grid.
- Android feature parity, system TTS fixes, and Fastlane setup.
- Fix cloud sync and deletion regressions; `stable-pre-codex` checkpoint.
- Release 0.1.1 (build 58); build 57 with dSYMs uploaded.

---

## Web editor, recording sync & hardening — 2026-03-18 → 2026-03-20 (builds 35–58)

- **Web editor:** full rewrite (top nav, full-page recordings, modern UI), "Edit on
  Web" deep-linking to a production, share-link fixes, recordings tab with playback.
- **Recordings:** multi-user sync for cast rehearsal (moved to production load,
  multi-device), delete/re-record in the browser, re-upload fix, preserve line UUIDs
  on cloud save, resolve stale paths after reinstall.
- **Audio capture:** fixed format/duration issues (PCM → M4A, native AAC, silence
  trimming), added "Send to Developer" with debug logging.
- **Crashes & stability:** fixed Kokoro TTS TestFlight crashes, MLX GPU / G2P NLTagger
  crashes, STT `installTapOnBus` NSException, rapid AirPods-tap stack overflow and null
  crashes, background TTS crash.
- **Rehearsal:** AirPods / Action-Button jump-back (to cue lines, not just the actor's
  line), wakelock during rehearsal, fast-mode toggle live during playback, readthrough
  mode.
- **Import/parser:** native PDFKit text extraction fallback, Folger Shakespeare export
  support, multi-character lines ("MARY, KITTY, LYDIA"), dictionary-based OCR confidence,
  PDF page viewer in the editor, markdown parser.
- **Data safety:** three-layer script backup, safe DB migrations (catch errors to avoid
  data loss).
- **Cloud/join:** Supabase RLS + SECURITY DEFINER RPCs for the join flow, auto-push
  scripts to cloud on save, fixed auth redirect loop, share-sheet fix.
- **Android:** platform support, Firebase, sherpa-onnx Kokoro TTS + model download UI,
  release signing; tablet/iPad responsive layouts.
- Firebase Analytics / Crashlytics / Performance; App Store submission assets (privacy
  policy, support & landing pages, Info.plist privacy keys); Fastlane for TestFlight.

---

## On-device ML foundation & first rehearsal app — 2026-03-13 → 2026-03-18 (builds 1–35)

The initial build-out, from project design to a working rehearsal app.

- **TTS:** Kokoro on-device via MLX (`kokoro-swift`), vendored MisakiSwift to fix a
  launch crash; per-production voice presets + per-character overrides; per-character
  gender assignment; voice graph coloring.
- **STT:** MLX Parakeet (replacing Whisper), vocabulary-aware correction, streaming
  transcription, per-actor STT adaptation, continuous listening for seamless delivery.
- **Voice cloning research:** KokoClone MLX port, Qwen3-TTS benchmarks, ZipVoice;
  later removed from the app UI (service kept as documentation), understudy fallback.
- **Rehearsal flow:** always-scroll-to-current-line, don't cut off long lines, faster
  transitions, character selection starting at the first line.
- **Cast & roles:** join codes, invitations, rehearsal-first UX; production-level
  script dialect with per-character override.
- **Import/parser:** Shakespeare/Gutenberg formats, stage-direction detection, OCR
  parser fixes, comprehensive parser test suite, sample scripts.
- **Backend & infra:** Supabase schema + credentials wired into startup, web editor,
  cloud sync, production hub; persistent device login; raised iOS deployment target to
  16.0; model download scripts + one-command setup.
- Initial project design (README + implementation plan), renamed LineGuide → CastCircle.
