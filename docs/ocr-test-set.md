# OCR Test Set — Sources

Scanned PDF scripts for developing and validating the on-device OCR + parser
pipeline and the per-document auto-tuner.

- The committed corpus under `sample-scripts/ocr-test-set/` is **public-domain
  (pre-1929) AND verified image-only** — `pdftotext` returns ~0 chars on interior
  pages, so nothing can bypass OCR.
- **Copyrighted / restricted** scans (the Jon Jory *Pride & Prejudice* adaptation;
  the Folger *Macbeth*, CC-BY-NC) are **gitignored** at the `sample-scripts/` top
  level — local-only, not redistributed.
- Per-script scan profiles + cited cast/act ground truth: `sample-scripts/ocr-test-set/manifest.md`.

## Validation metric
Run a script's OCR output through the real `ScriptParser`
(`dart run tool/parse_stats.dart <ocr.txt> --expect <CAST_CSV>`) and compare the
parsed roster + line counts to the play's known cast. Clean OCR collapses to the
right number of characters; OCR garble inflates it with phantom name variants.

## ⚠️ The archive.org text-layer trap (important)
archive.org's grayscale `_bw.pdf` "LuraDocument" derivatives **embed an invisible
OCR text layer** (≈700–6400 chars/page) — `pdffonts` shows no fonts, but
`pdftotext` on **interior content pages** returns full text. Such a PDF lets the
parser skip OCR entirely, so it is **not** a valid OCR fixture. **Always verify on
interior pages**, not front matter:
```bash
pdftotext -f 20 -l 22 file.pdf - | tr -d '[:space:]' | wc -c   # want ~0
```
Reliable image-only sources: **Google-digitized** archive.org scans (`*goog`),
which ship without a text layer; or rebuild from the `_jp2.zip` page images.

## The primary real-world document (copyrighted — do NOT redistribute)
- **`Pride-Prejudice-SCRIPT.pdf`** — Jon Jory's adaptation of *Pride and
  Prejudice*, an 82-page **150 DPI grayscale Canon copier scan** (no text layer).
  **Copyrighted** (Concord Theatricals / Playscripts — <https://www.concordtheatricals.com/p/100407>),
  **user-provided**, not committed. The canonical low-quality real-world target.
  Answer key: ~21 characters, 2 acts (`sample-scripts/pride_and_prejudice_perfect.md`).

## Committed corpus (public-domain, image-only)
| File | Play (edition) | Acts | Scan | Stresses |
|---|---|---|---|---|
| `ideal_husband_wilde_1899.pdf` | An Ideal Husband (1899) | 4 | bitonal 600 DPI | large cast; malformed xref robustness |
| `macbeth_shakespeare_1898.pdf` | Macbeth (Deighton ed. 1898) | 5 | bitonal 600 DPI | verse + scenes; school apparatus |
| `atreus_aeschylus_1904.pdf` | Aeschylus *Oresteia* (1904) | 3 plays | bitonal 600 DPI | Greek tragedy + CHORUS; 3 plays/file |
| `congreve_comedies_1895.pdf` | Congreve comedies (1895) | 2 plays | bitonal 600 DPI | Restoration; abbreviated caps cues (`SIR SAMP.`) |
| `patience_gilbert_1902.pdf` | G&S *Patience* (1902) | 2 | bitonal 600 DPI | musical / song cues; chorus labels |
| `faustus_marlowe_1905_lowdpi.pdf` | Marlowe *Doctor Faustus* | — | **grayscale 150 DPI** | very low DPI + noise + skew (mimics the P&P scan) |

Full source URLs are in `sample-scripts/ocr-test-set/manifest.md`. All are
Google-digitized archive.org scans (image-only) or rebuilt from page images;
`faustus_…_lowdpi` is degraded from the PD Google scan to a 150 DPI JPEG to mirror
the user's real-world copier-scan quality.

## Available but not committed (re-downloadable; see manifest for URLs)
- `glaspell_plays_1920.pdf` (47 MB) — lowest-DPI grayscale, 8 plays/file. Large → not committed.
- `iolanthe_gilbert_1882.pdf` (23 MB) — only **color** scan; second musical. Large → not committed.
- `earnest_wilde_1920`, `dollshouse_ibsen`, `pygmalion_shaw_1920`, `chekhov_twoplays_1912`
  — PD, but their `_bw.pdf` carry **OCR text layers** (see trap above), so they're not
  image-only OCR fixtures.
