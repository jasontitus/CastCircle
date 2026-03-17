# CastCircle

**The actor's scene partner in your pocket.**

CastCircle is a Flutter app (iOS, Android, and watchOS companion) that helps actors learn their lines by running through scenes with real cast recordings or high-quality on-device text-to-speech. A production organizer uploads a script PDF, assigns roles to cast members, and everyone records their lines. Then any actor can rehearse their scenes — hearing other characters speak and delivering their own lines, with the app listening via on-device speech recognition to advance automatically.

---

## How It Works

### 1. Create a Production
An organizer creates a new production, uploads the script as a PDF, and the app uses on-device OCR to extract the text. The raw text is parsed into a structured script — a sequence of labeled lines (character name + dialogue) and stage directions.

### 2. Edit & Validate the Script
The organizer reviews the parsed script in a highlighted editor showing each character's lines in distinct colors. They fix any OCR errors, adjust character names, and split/merge lines as needed. Built-in validation checks for:
- A complete cast list extracted from the script
- Every line attributed to a known character
- Scene/act boundaries properly marked

### 3. Assign Roles & Invite Cast
Once the script looks right, the organizer sees the full cast list and assigns a **primary** and **understudy** for each role. Invitations go out via email or SMS with a deep link. Cast members open the app and land directly on their assigned production with their suggested role(s).

### 4. Record Lines
Each cast member records their character's lines one at a time. The app shows the line text, records audio, and lets them re-record until satisfied. Recordings are synced to all cast members via cloud storage.

### 5. Rehearse Scenes
This is the core experience. An actor selects a scene to rehearse:
- Other characters' lines play back using **real cast recordings** (preferred) or **on-device TTS** (fallback for unrecorded lines)
- When it's the actor's turn, the app listens via **on-device speech recognition** (Whisper-based)
- The app matches what the actor says against the expected line and advances when they've delivered it
- **Jump back**: A configurable gesture (shake, double-tap, swipe) or a chosen keyword lets the actor jump back N lines (configurable) to retry a section
- Lines are highlighted as they progress through the scene
- Accuracy feedback shows how close they were to the written line

### 6. Watch Companion (Future)
A watchOS/wearOS companion app provides:
- Tap to jump back N lines
- Haptic cue when it's your turn to speak
- Basic transport controls (pause, restart scene)

---

## Architecture Overview

```
┌──────────────────────────────────────────────────┐
│                   Flutter App                     │
│                                                   │
│  ┌─────────┐  ┌──────────┐  ┌─────────────────┐ │
│  │  Script  │  │Recording │  │   Rehearsal      │ │
│  │  Import  │  │  Studio  │  │   Engine         │ │
│  │  & Edit  │  │          │  │                  │ │
│  └────┬─────┘  └────┬─────┘  └───┬──────┬──────┘ │
│       │              │            │      │        │
│  ┌────▼──────────────▼────────────▼──────▼──────┐ │
│  │              Core Services                    │ │
│  │  ┌────────┐ ┌────────┐ ┌──────┐ ┌─────────┐ │ │
│  │  │  OCR   │ │  TTS   │ │ STT  │ │  Audio  │ │ │
│  │  │On-Dev. │ │Kokoro  │ │Whispr│ │ Player  │ │ │
│  │  └────────┘ └────────┘ └──────┘ └─────────┘ │ │
│  └──────────────────┬───────────────────────────┘ │
│                     │                             │
│  ┌──────────────────▼───────────────────────────┐ │
│  │            Data Layer                         │ │
│  │  ┌─────────┐ ┌──────────┐ ┌───────────────┐ │ │
│  │  │ SQLite  │ │  Audio   │ │  Supabase      │ │ │
│  │  │ Local   │ │  Files   │ │  Cloud         │ │ │
│  │  └─────────┘ └──────────┘ └───────────────┘ │ │
│  └──────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────┘
```

### On-Device Models
| Purpose | Model | Why |
|---------|-------|-----|
| **Text-to-Speech** | Kokoro (via flutter_kokoro_tts or ONNX runtime) | High-quality, expressive, runs fully offline, multiple voices |
| **Speech-to-Text** | Whisper.cpp (via whisper_flutter_plus) | Accurate, runs on-device, supports streaming |
| **OCR** | ML Kit / Google Vision (placeholder) | Good baseline; swappable for Gemini later |

### Backend (Lightweight)
- **Supabase** for auth, invitations, production metadata, and audio file storage
- Postgres with Row Level Security so cast members only see their productions
- Supabase Storage for audio recordings with per-production buckets
- Realtime subscriptions for recording availability updates

---

## Data Model

```
Production
  ├── id, title, organizer_id, created_at
  ├── Script
  │     ├── id, production_id, raw_text, version
  │     └── ScriptLine[]
  │           ├── id, script_id, act, scene, line_number
  │           ├── character_name, line_text, line_type (dialogue|stage_direction|song)
  │           └── order_index
  ├── Character[]
  │     ├── id, production_id, name, color
  │     ├── primary_user_id, understudy_user_id
  │     └── recording_progress (0-100%)
  ├── CastMember[]
  │     ├── id, production_id, user_id
  │     ├── role (organizer|primary|understudy)
  │     └── invited_at, joined_at
  └── Recording[]
        ├── id, script_line_id, user_id
        ├── audio_url, duration_ms
        ├── is_primary (bool)
        └── recorded_at
```

---

## Key Screens

1. **Home** — List of productions (joined + organized)
2. **Create Production** — Title, upload PDF
3. **Script Editor** — Colored line-by-line editor with character labels, validation panel
4. **Cast Manager** — Character list with primary/understudy assignment, invite buttons
5. **Recording Studio** — Line-by-line recording interface with waveform, playback, re-record
6. **Scene Selector** — Pick act/scene to rehearse
7. **Rehearsal Player** — The main rehearsal experience (full-screen, minimal UI, audio-driven)
8. **Settings** — Jump-back gesture, jump-back line count, TTS voice selection, playback speed

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Framework | Flutter 3.x (iOS + Android + watchOS companion) |
| State Management | Riverpod 2.x |
| Local DB | Drift (SQLite) |
| Backend | Supabase (Auth, Postgres, Storage, Realtime) |
| OCR | google_mlkit_text_recognition (swappable) |
| TTS | Kokoro via on-device ONNX inference |
| STT | whisper_flutter_plus (Whisper.cpp) |
| Audio Recording | record package |
| Audio Playback | just_audio |
| Deep Links | app_links / uni_links |
| Watch | watch_connectivity (Flutter ↔ watchOS/wearOS) |

---

## Getting Started

```bash
# Prerequisites: Flutter SDK 3.x, Xcode (for iOS), Android Studio

# Clone and setup
git clone https://github.com/jasontitus/CastCircle-.git
cd CastCircle-
flutter pub get

# Run on device/simulator
flutter run
```

See [PLAN.md](PLAN.md) for the full implementation roadmap.

---

## License

TBD
