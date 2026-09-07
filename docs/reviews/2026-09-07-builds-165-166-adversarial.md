# Adversarial review of builds 165–166

Scope: database upgrade repair, combined act/scene headings, publisher/footer
filtering, biography cutoff, and their source-page matching interactions.
Reviewed the diff from a3a8c7b through 8f9128e, plus the dependent account-claim
and matcher code. This was a local review with separate test-driven passes,
not an independent multi-agent audit. No live database was modified.

## Confirmed findings and applied fixes

### P1 — Legacy account rows became guest-visible during upgrade

Reproducer: an unscoped v10 database contains a local guest production and
productions owned by Alice and Bob. Adding account_namespace with the guest
default exposes all three through getAllProductions('__guest__') before
sign-in; after Alice signs in, Bob's unclaimed row remains guest-visible.

Fix: schema 12 places unclaimed rows with a nonlocal organizer in a reserved
legacy namespace. claimLegacyProductions checks organizer/cast membership
before moving those rows to an account. Actual local guest rows retain the
existing first-sign-in claim behavior. Existing assigned namespaces do not
change. Joined productions with cached matching cast membership remain
recoverable by that actor. A legacy joined row without cached membership
stays hidden until ownership/membership can be recovered, rather than being
shown to every signed-out user.

Verification: failures reproduced on the prior code. Tests cover guest and
cross-account visibility, preservation of assigned namespaces and script
lines on v9/v10/v11, joined-cast recovery, repeated opens, production creation
and outbox persistence, and malformed-index failure without user_version
advancement or loss of rows. The malformed index can be repaired and the
upgrade retried. This is local visibility isolation, not an audit of every
repository operation or the remote authorization system.

### P1 — Spoken ending marker could silently remove subsequent acts

Reproducer: a character's cue is followed by a standalone 'End of Play.',
then more dialogue and another act, then a true ending and an author section.
The former firstMatch/any-later-author-heading logic removed everything from
the first spoken marker, including the later act.

Fix: inspect only the final ending marker; reject a marker following an empty
speaker cue; require only identifiable page furniture between the ending and
its author heading. If ambiguous, retain text. Considering one final marker
also avoids repeatedly scanning a large tail for many candidate markers.

Verification: both a spoken early marker with a later true ending and a
spoken marker followed by later dialogue but no explicit true end survive.
The real Wrinkle biography is still removed, and existing footer/cue tests
still pass. This remains heuristic document cleanup; unrecognized publisher
formats are retained for review rather than universally removed.

### P2 — Colon cues and short exact dialogue failed source matching

The adjacent matcher only stripped dot-delimited speaker cues. Colon-prefixed
'No.' remained 'MEG: No.', and even an exact short body could score zero under
the long-text containment/token rules. This can leave source-page metadata
unmatched/inherited or omit a highlight. The issue predated these commits
but affects the newly supported Stage Partners import path.

Fix: strip colon cues too and accept exact normalized body equality before
fuzzy scoring. Weak short-text overlaps remain rejected. Tests cover MEG,
CHARLES, and MRS. WHO colon cues and run the existing highlight/mapping suites.
Identical repeated short replies remain intrinsically ambiguous; this does
not prove every source-page assignment is exact.

## Validation and limits

- Full Flutter test suite: 698 passed, one existing skipped test.
- Real local PDFKit extraction: 55 pages, 2 acts, 13 scenes, 1,130 dialogue
  lines, 22 characters; Calvin's exact line maps to page 14. All imported
  lines are checked for the reported publisher/footer/running-title text.
- Analyzer: 134 existing diagnostics (129 informational and five warnings)
  in the captured run; no errors. The warnings are in unchanged TTS, rehearsal,
  and app-initialization code.
- No licensed PDF or extracted text added to Git.
- No physical-device execution or simulated disk-full fault injection in this
  pass; migration faults were tested with malformed index structures.
- Already imported scripts are not rewritten. A new import is needed for
  parser changes, while the schema repair runs on the next upgraded open.
