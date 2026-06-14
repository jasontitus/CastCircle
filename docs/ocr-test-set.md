# OCR Test Set — Sources

Scanned PD play-script PDFs for developing and validating the on-device OCR +
parser pipeline and the per-document auto-tuner. Committed under
`sample-scripts/ocr-test-set/`.

- All are **public domain** (pre-1929 editions). The **copyrighted** Jon Jory
  *Pride & Prejudice* scan and the **CC-BY-NC** Folger *Macbeth* are gitignored at
  the `sample-scripts/` top level (local-only, not redistributed).
- Per-script scan profiles + cited cast/act ground truth:
  `sample-scripts/ocr-test-set/manifest.md`.

## How these are used (text layers don't matter)
We OCR by **rendering each PDF page to an image and running our pipeline on the
pixels** — exactly what the iOS plugin does. Some archive.org scans also carry an
**invisible** OCR text layer (render mode 3), but rendering a page **doesn't draw
it**, so the rasterized image is the scan alone and our OCR runs normally. The
text layer only matters for the *app's import path*, which skips OCR when a PDF
already has extractable text — irrelevant to OCR tuning on the Mac harness.

Bonus: for the scans that carry a text layer, we extract it as a free per-page
reference (`*.embedded.txt`); for those well-known plays, clean **gold** ground
truth is also on Project Gutenberg. So they're the best-instrumented accuracy
cases (true word-accuracy, not just phantom-name count).

## Validation metric
`dart run tool/parse_stats.dart <ocr.txt> --expect <CAST_CSV>` runs the real
`ScriptParser` and reports the character roster + line counts + PHANTOM
(OCR-garble) names vs the play's known cast. Clean OCR collapses to the right
number of characters; garble inflates it with phantom name variants.

## Committed corpus
| File | Play (edition) | Acts | Scan | Reference GT | Stresses |
|---|---|---|---|---|---|
| `ideal_husband_wilde_1899.pdf` | An Ideal Husband (1899) | 4 | bitonal 600 | cast | large cast; malformed xref |
| `macbeth_shakespeare_1898.pdf` | Macbeth (Deighton 1898) | 5 | bitonal 600 | cast | verse + scenes; school apparatus |
| `atreus_aeschylus_1904.pdf` | Aeschylus *Oresteia* (1904) | 3 plays | bitonal 600 | cast | Greek tragedy + CHORUS |
| `congreve_comedies_1895.pdf` | Congreve comedies (1895) | 2 plays | bitonal 600 | cast | Restoration; abbreviated cues |
| `patience_gilbert_1902.pdf` | G&S *Patience* (1902) | 2 | bitonal 600 | cast | musical / song cues |
| `faustus_marlowe_1905_lowdpi.pdf` | Marlowe *Doctor Faustus* | — | **grayscale 150** | cast | very low DPI + noise + skew (≈ the P&P scan) |
| `earnest_wilde_1920.pdf` | Importance of Being Earnest | 3 | grayscale ~500 | **embedded + Gutenberg** | clean grayscale; gold GT |
| `dollshouse_ibsen.pdf` | A Doll's House (Archer) | 3 | grayscale ~500 | **embedded + Gutenberg** | clean grayscale; gold GT |
| `pygmalion_shaw_1920.pdf` | Pygmalion (1920) | 5 | grayscale ~500 | **embedded + Gutenberg** | dense page, dialect; gold GT |
| `chekhov_twoplays_1912.pdf` | Seagull + Cherry Orchard | 4+4 | grayscale ~400 | **embedded** | low DPI; two plays/file; Russian names |

Full source URLs per script: `sample-scripts/ocr-test-set/manifest.md`.

## The primary real-world target (copyrighted — gitignored)
`Pride-Prejudice-SCRIPT.pdf` — Jon Jory's *Pride and Prejudice* adaptation, an
82-page **150 DPI grayscale Canon copier scan** (no text layer). Copyrighted
(Concord Theatricals / Playscripts), user-provided, not committed. Answer key:
~21 characters, 2 acts (`sample-scripts/pride_and_prejudice_perfect.md`).

## Available but not committed (re-downloadable; URLs in manifest)
- `glaspell_plays_1920.pdf` (47 MB) — lowest-DPI grayscale, 8 plays/file. Too large to commit.
- `iolanthe_gilbert_1882.pdf` (23 MB) — only **color** scan; second musical. Too large to commit.

## Verifying a scan is genuinely image-only (if you want pure scan fidelity)
```bash
pdftotext -f 20 -l 22 file.pdf - | tr -d '[:space:]' | wc -c   # 0 = image-only on interior pages
```
archive.org's `_bw.pdf` "LuraDocument" derivatives usually DO carry a text layer
(check interior pages, not front matter); Google-digitized `*goog` scans ship
image-only. Either works for OCR tuning since we force-render.
