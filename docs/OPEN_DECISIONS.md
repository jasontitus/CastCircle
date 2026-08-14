# Open decisions

Product/UX questions that are **waiting on Jason**, not on implementation.
Each entry states the choice, why it's open, and what shipping it would
cost — so picking one is a sentence, not a research project.

Add here instead of re-asking mid-task; revisit when a related area is
already being worked on.

---

## 1. Script editor: compact review view, or full editor?

**Opened:** 2026-08-14 (during the OCR walk-through work)

The import's **Review OCR** sheet and the **script editor's** line-edit
sheet now offer the same four actions (Prev · Remove · Looks right ·
Next) over their flagged lines, but they still *look* different:

| | Review sheet (import) | Editor sheet (post-import) |
|---|---|---|
| Page + highlight | yes | yes |
| Text | one compact editable field | full editor |
| Also present | — | character dropdown, line-type menu, Split, Save |

Jason's note: "I still get a very different UI on edit script."

**Options**

- **A — Make the editor sheet compact**, matching the review sheet, with
  the advanced controls (character, line type, split) behind a
  "More…" disclosure. One mental model for cleaning up OCR; costs a
  round-trip whenever the advanced controls *are* what's needed.
- **B — Keep the full editor**, consistent action buttons only (today's
  state). Nothing to build; the visual difference stays.
- **C — Compact by default, remembered per user** — a toggle in the
  sheet ("simple / full"). Most flexible, most surface area.

**Note:** the post-import editor is the far more common cleanup path (the
review screen only exists during an import), so whichever wins should be
optimised for repeat visits, not first use.

---

## 2. ACT II scene segmentation

**Opened:** 2026-08-01 · **Still open**

Act II of the P&P scan parses as ONE 589-line scene (~40% of the play)
because its transitions are phrased differently from Act I's — e.g.
"(They are now outside.)" instead of a named-location shift. Rehearsal
therefore offers a marathon scene with no way to pick a chunk.

**Options**

- **A — Teach the transition detector Act II's phrasings** (bounded work;
  the parser corpus + scene-partition tests guard against regressions).
- **B — Manual scene splitting in the scene editor** (exists already;
  the organiser does it by hand once, and it now syncs to the cloud).
- **C — Leave it** — one long scene is survivable if rehearsal always
  resumes where you left off.

---

## 3. ~~Firebase App Check enforcement~~ — DECIDED 2026-08-14: no

Jason: "Let's not do Firebase app check." Not revisiting unless real
backend traffic moves onto Firebase.

Why it was the right call: Play Integrity requires Google Play Services,
which would break the Fire-tablet path (`docs/FIRE_TABLET.md`) and
direct-installed builds — and App Check protects Firestore / Storage /
Functions / Auth, none of which this app uses (auth, data, and audio all
live in Supabase). Firebase here is analytics + Crashlytics +
Performance only, which App Check enforcement doesn't gate anyway.

**Still worth finishing (not App Check):** the API-key restrictions that
actually close the review finding. The iOS key is already restricted to
bundle id `com.tiltastech.castcircle`. The Android key needs its
fingerprints before restricting, or Play-installed builds lose telemetry:

- upload key SHA-1 `22:F4:9D:A5:55:E5:BF:AB:44:A7:35:96:18:A4:F6:DE:0B:69:93:E9`
- debug key SHA-1 `06:EC:C4:36:1D:0E:27:9C:13:D0:FC:D5:02:4D:2B:B7:F6:9D:1C:88`
- **missing:** the Play App Signing SHA-1 (Play Console → Test and
  release → Setup → App integrity). Google re-signs the AAB, so
  Play-delivered builds present that cert, not the upload one.

Once that SHA-1 is in hand this is a two-minute `gcloud services
api-keys update` — no App Check involved.
