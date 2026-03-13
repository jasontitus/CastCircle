# LineGuide — Implementation Plan

This document breaks the project into phases. Each phase is self-contained and produces a working (if incomplete) app. The goal is to get to a usable rehearsal experience as fast as possible, then layer on polish, collaboration, and watch support.

---

## Phase 0: Project Scaffold & Core Infrastructure
**Goal:** Runnable Flutter app with navigation, state management, and local persistence.

### Tasks
- [ ] `flutter create lineguide` with org identifier
- [ ] Set up folder structure (see below)
- [ ] Add core dependencies: `riverpod`, `drift`, `go_router`, `just_audio`, `record`
- [ ] Configure Drift database with tables: `productions`, `scripts`, `script_lines`, `characters`, `recordings`
- [ ] Build app shell with GoRouter: bottom nav (Home, Record, Rehearse, Settings)
- [ ] Create Production model and local CRUD
- [ ] Home screen: list productions, create new production (title only for now)
- [ ] Basic theming (dark mode default — actors rehearse in low light)

### Folder Structure
```
lib/
├── main.dart
├── app.dart                     # MaterialApp + router
├── core/
│   ├── theme/                   # Colors, text styles, dark theme
│   ├── constants.dart
│   └── utils/                   # Extensions, helpers
├── data/
│   ├── database/
│   │   ├── app_database.dart    # Drift database definition
│   │   ├── tables/              # Drift table definitions
│   │   └── daos/                # Data access objects
│   ├── models/                  # Domain models (freezed)
│   ├── repositories/            # Repository pattern (local + remote)
│   └── services/                # OCR, TTS, STT service wrappers
├── features/
│   ├── home/                    # Production list
│   ├── script_import/           # PDF upload + OCR + parsing
│   ├── script_editor/           # Line-by-line editor
│   ├── cast_manager/            # Role assignment + invites
│   ├── recording_studio/        # Record lines
│   ├── rehearsal/               # The core rehearsal player
│   └── settings/                # App + production settings
├── providers/                   # Riverpod providers
└── widgets/                     # Shared widgets
```

---

## Phase 1: Script Import & Parsing
**Goal:** Upload a PDF, OCR it, and parse it into structured lines.

### Tasks
- [ ] Add `file_picker` and `google_mlkit_text_recognition` dependencies
- [ ] Build PDF import screen: pick file, show progress
- [ ] Implement OCR pipeline:
  - Convert PDF pages to images (via `pdf_render` or `printing` package)
  - Run ML Kit text recognition on each page image
  - Concatenate raw text with page boundaries
- [ ] Build script parser:
  - Detect character names (ALL CAPS at start of line, or `NAME:` pattern)
  - Detect stage directions (text in parentheses or italics markers)
  - Detect act/scene headers (`ACT I`, `SCENE 2`, etc.)
  - Assign line numbers and order indices
  - Extract cast list from detected character names
- [ ] Store parsed `ScriptLine` records in Drift database
- [ ] Handle common script formats:
  - Standard play format (CHARACTER NAME followed by dialogue)
  - Screenplay format (character centered above dialogue)
  - Musical format (lyrics marked differently from dialogue)
- [ ] Unit tests for parser with sample script text

### Script Line Model
```dart
class ScriptLine {
  final int id;
  final int scriptId;
  final String? act;
  final String? scene;
  final int lineNumber;       // sequential within scene
  final int orderIndex;       // global ordering
  final String characterName; // empty for stage directions
  final String lineText;
  final LineType lineType;    // dialogue, stageDirection, song, header
}
```

### Parser Strategy
The parser is the trickiest part of this phase. Strategy:

1. **First pass — line classification**: Scan each line and classify as:
   - `header` — matches act/scene patterns
   - `characterCue` — ALL CAPS line, usually alone, or `NAME:` at start
   - `stageDirection` — wrapped in `()` or `[]`
   - `dialogue` — anything following a character cue

2. **Second pass — attribution**: Walk through classified lines and attribute dialogue to the most recent character cue.

3. **Third pass — scene grouping**: Group lines under act/scene headers.

4. **Validation**: Flag lines that couldn't be attributed or characters that appear only once (possible OCR error).

The parser should be configurable (regex patterns for character detection) so the organizer can adjust for unusual script formats.

### Lessons from Real Script (Pride & Prejudice by Jon Jory)

We parsed the actual 82-page script PDF through OCR + the reference parser (`scripts/parse_script.py`). Key findings:

**Format observed:** `CHARACTER NAME. Dialogue text` — standard American play format. Inline stage directions appear as `(Direction:)` within dialogue. Standalone directions in parens on their own lines.

**OCR challenges:**
- Image-based PDF (no embedded text) — required page-to-image conversion + tesseract
- Handwritten margin notes (blocking/staging annotations) get picked up as noise — need aggressive filtering
- Page headers ("Pride and Prejudice 17", "12 Jon Jory") appear as dialogue if not stripped
- Line-wrapping from OCR introduces mid-word breaks ("con-\nstruct", "de-\nlighted")
- Some pages have worse OCR quality (bleed-through, margin notes) — the script editor phase is essential

**Parse results:**
- 1,067 dialogue lines, 159 stage directions across 2 acts
- 17 unique speaking roles (some with aliases like "MR. DARCY" / "DARCY")
- Multi-character lines exist: "MARY, KITTY, LYDIA. (To the audience:) ..."
- Character aliases must be normalized (MR. DARCY → DARCY, MR. COLLINS → COLLINS)
- Elizabeth has 321 lines (30%), Darcy 103 (10%), Mrs. Bennet 111 (10%)

**Parser architecture that worked:**
- Single-pass with state machine (not multi-pass) — simpler and handles OCR messiness better
- Known character list + longest-match-first for detection
- Noise filtering via regex patterns for page headers/footers
- Margin noise detection for handwritten annotations
- Inline direction extraction via `(Text:)` pattern at start of dialogue

See `examples/pride_and_prejudice_parsed.md` and `.json` for the full output.

---

## Phase 2: Script Editor & Validation
**Goal:** Let the organizer view and fix the parsed script before assigning roles.

### Tasks
- [ ] Build script editor screen:
  - Scrollable list of `ScriptLine` cards
  - Each card shows: character name (colored chip), line text, line type icon
  - Each character gets a unique color (auto-assigned, editable)
- [ ] Edit capabilities:
  - Tap a line to edit text or character attribution
  - Long-press to split a line into two or merge with adjacent line
  - Swipe to change line type (dialogue ↔ stage direction)
  - Reorder via drag handles
  - Add/delete lines
- [ ] Character management panel:
  - List of all detected characters with line counts
  - Merge characters (fix OCR variants: "HAMLET" vs "HAMIET")
  - Rename characters
  - Delete spurious characters
- [ ] Validation panel:
  - ✓/✗ Every line attributed to a character
  - ✓/✗ Cast list looks complete
  - ✓/✗ No single-line characters (likely errors)
  - ✓/✗ Scenes have at least 2 characters
- [ ] "Preview" mode: full script rendered like a script document with character colors and proper formatting
- [ ] "Approve script" action that locks the script and moves to cast assignment

---

## Phase 3: Recording Studio
**Goal:** Cast members can record their lines one by one.

### Tasks
- [ ] Build recording studio screen:
  - Shows one line at a time with large text
  - Context: previous 2 lines shown (dimmed) for reference
  - Big record button, waveform visualization during recording
  - Playback button after recording
  - Re-record button (replaces previous take)
  - "Next line" / "Previous line" navigation
  - Skip button for lines they don't want to record yet
- [ ] Audio recording implementation:
  - Use `record` package for microphone capture
  - Record as AAC/m4a for good quality + small size
  - Save to local app directory, named by script_line_id
  - Store `Recording` in database with local file path
- [ ] Progress tracking:
  - Show N/total lines recorded for this character
  - Progress bar on character card in cast manager
  - Mark lines as recorded/unrecorded in script view
- [ ] Audio normalization:
  - Normalize volume levels across recordings
  - Trim silence from start/end
- [ ] Batch recording mode (optional enhancement):
  - Record continuously, app detects pauses between lines
  - Auto-segments into individual line recordings

---

## Phase 4: Rehearsal Engine (Core Experience)
**Goal:** The main rehearsal player — hear others' lines, speak your own, advance through scenes.

### Tasks
- [ ] Build rehearsal setup screen:
  - Select which character you're rehearsing as
  - Select scene(s) to rehearse (multi-select)
  - Show recording coverage: which characters have recordings
  - Settings: playback speed, jump-back lines, jump-back trigger
- [ ] Implement rehearsal engine (the brain):
  - Maintain a queue of `ScriptLine` items for the selected scene(s)
  - Track current position in the queue
  - For each line, determine: is this MY line or SOMEONE ELSE's?
  - **Someone else's line**: play recording or TTS, then advance
  - **My line**: activate STT, listen, match against expected text, advance when matched
  - Handle stage directions: display on screen briefly, optionally read via TTS
- [ ] Audio playback for other characters:
  - Priority: cast recording > understudy recording > TTS
  - Use `just_audio` for playback
  - Pre-buffer next 2-3 lines for seamless playback
- [ ] On-device TTS for unrecorded lines:
  - Integrate Kokoro TTS via ONNX Runtime (or `flutter_tts` as initial fallback)
  - Assign distinct TTS voices to different characters
  - Cache generated TTS audio for reuse
- [ ] On-device STT for actor's lines:
  - Integrate `whisper_flutter_plus`
  - Stream microphone input during actor's turn
  - Compare recognized text against expected line
  - Fuzzy matching (don't require word-perfect — use edit distance threshold)
  - Visual indicator: "listening...", "got it!", "try again?"
  - Auto-advance when match confidence exceeds threshold
  - Manual advance button as fallback
- [ ] Jump-back mechanism:
  - Configurable trigger: shake device, double-tap screen, say keyword (e.g., "again")
  - Configurable distance: jump back N lines (default 3)
  - Smooth transition: stop current audio, rewind queue, restart from jump point
  - Haptic feedback on jump
- [ ] Rehearsal UI:
  - Full-screen, minimal distractions
  - Current line highlighted with character color
  - Upcoming 2-3 lines shown (dimmed)
  - Previous lines scroll up (faded)
  - Floating controls: pause, jump-back, exit
  - Progress bar for scene completion
  - "Your turn" indicator (visual + optional haptic)
- [ ] Line accuracy tracking:
  - Store accuracy score per line per rehearsal session
  - Highlight lines the actor struggles with
  - Suggest focused practice on weak lines

### Rehearsal State Machine
```
┌──────────┐     line is other's      ┌───────────┐
│  IDLE /  │ ─────────────────────►   │  PLAYING  │
│  READY   │                          │  OTHER'S  │
│          │ ◄─────────────────────   │  LINE     │
│          │     playback complete    └───────────┘
│          │
│          │     line is mine         ┌───────────┐
│          │ ─────────────────────►   │ LISTENING │
│          │                          │  FOR MY   │
│          │ ◄─────────────────────   │  LINE     │
│          │     match confirmed      └───────────┘
│          │
│          │     jump-back trigger    ┌───────────┐
│          │ ─────────────────────►   │ JUMPING   │
│          │                          │  BACK     │
│          │ ◄─────────────────────   │           │
│          │     repositioned         └───────────┘
│          │
│          │     scene complete       ┌───────────┐
│          │ ─────────────────────►   │ COMPLETE  │
└──────────┘                          └───────────┘
```

---

## Phase 5: Supabase Backend & Collaboration
**Goal:** Multi-user: invitations, cloud sync of recordings, real-time updates.

### Tasks
- [ ] Set up Supabase project:
  - Auth (email + magic link for easy onboarding)
  - Postgres tables mirroring local Drift schema
  - Row Level Security policies per production
  - Storage buckets for audio recordings
- [ ] User authentication:
  - Sign up / sign in screen
  - Profile (name, photo)
  - Auth state managed via Riverpod
- [ ] Production sharing:
  - Organizer creates production (synced to Supabase)
  - Generate invite links (deep links) with production ID + role suggestion
  - Send invites via share sheet (email, SMS, messaging apps)
  - Invitee opens link → app opens → joins production with suggested role
- [ ] Cast assignment:
  - Organizer assigns primary + understudy per character
  - Cast members see their assigned roles
  - Role acceptance flow
- [ ] Recording sync:
  - Upload recordings to Supabase Storage on completion
  - Download other cast members' recordings on demand / wifi
  - Background sync with progress indicator
  - Conflict resolution: latest recording wins (per line per user)
- [ ] Real-time updates:
  - Supabase Realtime for recording availability
  - When a cast member finishes recording a line, others see it immediately
  - Production status updates (script approved, new cast member joined)
- [ ] Offline support:
  - Local-first with Drift database
  - Queue changes when offline, sync when back online
  - Pre-download all recordings for a scene before rehearsal

---

## Phase 6: On-Device ML Model Integration
**Goal:** Replace placeholder/cloud services with high-quality on-device models.

### Tasks
- [ ] **Kokoro TTS integration**:
  - Bundle Kokoro ONNX model (or download on first use)
  - Implement Flutter platform channel or FFI bridge to ONNX Runtime
  - Voice selection: map characters to distinct Kokoro voices
  - Pre-generate TTS for scenes to avoid latency during rehearsal
  - Cache generated audio files
- [ ] **Whisper STT integration**:
  - Bundle Whisper small/medium model (balance accuracy vs size)
  - Use `whisper_flutter_plus` for on-device inference
  - Streaming mode: process audio chunks in real-time
  - Tune for theatrical speech (louder, more enunciated)
  - Language configuration
- [ ] **OCR upgrade path** (optional):
  - Abstract OCR behind a service interface
  - Option to use Gemini API for complex scripts (handwritten notes, unusual formatting)
  - A/B test on-device vs cloud OCR accuracy
- [ ] Model management:
  - Download models on first use (not bundled in app binary to keep install small)
  - Show model download progress
  - Model version updates

---

## Phase 7: Watch Companion App
**Goal:** watchOS / wearOS app for hands-free rehearsal control.

### Tasks
- [ ] watchOS app (Swift/SwiftUI):
  - Simple UI: current line text (scrollable), character name
  - Tap to jump back
  - Haptic pulse when it's your turn
  - Crown to adjust volume
  - Complication showing rehearsal progress
- [ ] Flutter ↔ Watch communication:
  - Use `watch_connectivity` package
  - Sync rehearsal state (current line, playing/listening state)
  - Send commands (jump-back, pause, resume)
- [ ] wearOS app (Compose):
  - Mirror watchOS functionality
  - Rotary input for scrolling through lines

---

## Phase 8: Polish & Advanced Features
**Goal:** Quality-of-life improvements and nice-to-haves.

### Tasks
- [ ] **Rehearsal analytics**:
  - Track rehearsal sessions (date, duration, scenes covered)
  - Line accuracy trends over time
  - "Lines mastered" vs "lines struggling" dashboard
  - Practice streak / gamification
- [ ] **Scene notes**:
  - Actors can add personal notes to any line
  - Notes visible during rehearsal as subtle overlay
  - Organizer can add blocking notes visible to all
- [ ] **Cue-to-cue mode**:
  - Skip to just before each of your lines
  - Hear only the cue line (line before yours) then your turn
  - Faster practice for actors who know the general flow
- [ ] **Speed run mode**:
  - Gradually increase playback speed over rehearsals
  - Helps with rapid-fire dialogue scenes
- [ ] **Group rehearsal** (stretch):
  - Multiple actors connect to same session
  - Each hears others live (VoIP) + recorded lines for absent characters
  - Sync'd script position across devices
- [ ] **Accessibility**:
  - VoiceOver / TalkBack support
  - High-contrast mode
  - Adjustable text sizes
  - Haptic-only mode for rehearsal cues
- [ ] **Export**:
  - Export rehearsal recording (full scene audio)
  - Export script as formatted PDF
  - Share line recordings

---

## Implementation Priority

The phases above are roughly ordered by priority, but here's the critical path to a **minimum usable product**:

```
Phase 0 (Scaffold)
    │
    ▼
Phase 1 (Script Import) ──► Phase 2 (Script Editor)
    │                              │
    ▼                              ▼
Phase 3 (Recording)          Phase 4 (Rehearsal) ◄── THIS IS THE CORE VALUE
    │                              │
    ▼                              ▼
Phase 5 (Backend/Collab)     Phase 6 (ML Models)
    │                              │
    ▼                              ▼
Phase 7 (Watch)              Phase 8 (Polish)
```

**MVP = Phases 0-4** — A single user can import a script, record other characters' lines themselves (or use TTS), and rehearse scenes. This is already useful.

**v1.0 = Phases 0-6** — Full collaboration with real cast recordings and high-quality on-device models.

---

## Open Questions & Decisions

| Question | Options | Recommendation |
|----------|---------|----------------|
| State management | Riverpod vs Bloc | **Riverpod** — less boilerplate, great for dependency injection |
| Backend | Supabase vs Firebase | **Supabase** — open source, Postgres, better RLS, generous free tier |
| TTS fallback before Kokoro | `flutter_tts` (system TTS) | Yes, ship with system TTS first, upgrade to Kokoro in Phase 6 |
| STT fallback before Whisper | `speech_to_text` (system STT) | Yes, ship with system STT first, upgrade to Whisper in Phase 6 |
| Script format support | Play, screenplay, musical | Start with standard play format, expand based on user scripts |
| Audio format | AAC vs Opus vs WAV | **AAC (m4a)** — good quality, small size, native iOS/Android support |
| Fuzzy line matching | Edit distance vs word overlap vs embedding | Start with **word overlap ratio**, upgrade to embedding similarity later |

---

## Non-Functional Requirements

- **Offline-first**: Core rehearsal works entirely offline once recordings are downloaded
- **Low latency**: < 500ms between lines during rehearsal (no perceptible gap)
- **Battery efficient**: On-device ML models should be power-conscious (batch TTS pre-generation)
- **Storage mindful**: Audio recordings ~50KB per line (AAC), typical show ~500 lines = ~25MB per production
- **Privacy**: Audio never leaves device unless explicitly synced; on-device processing by default
