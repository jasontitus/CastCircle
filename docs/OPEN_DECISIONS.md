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

## 3. Firebase App Check enforcement

**Opened:** 2026-08-13 · **Recommendation: don't, for now**

API-key restrictions (the part that actually closes the review finding)
are done for iOS; the Android key still needs its SHA-1 fingerprints
(blocked on the Play App Signing cert — see below). Full App Check
enforcement is a separate, larger step.

Reason to hold: Play Integrity requires Google Play Services, which
would break the Fire-tablet story (`docs/FIRE_TABLET.md`) and
direct-installed builds — and there is no Firebase backend behind the
door worth protecting (auth/data/audio all live in Supabase).

**Blocked on Jason:** the Play App Signing SHA-1 from Play Console →
Setup → App integrity, to finish the Android key restriction.
