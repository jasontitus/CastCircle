# OCR Test Set — Sources

The scanned PDF scripts used to develop and validate the on-device OCR + parser
pipeline (and the per-document auto-tuner) are **not committed** to the repo —
they're large and some are copyrighted. This doc records where each came from so
the corpus can be recreated.

PDFs live locally (gitignored) under `sample-scripts/` and `sample-scripts/ocr-test-set/`.

## Why a scanned corpus
The auto-tuner has to pick OCR settings (notably the DBNet `unclip` ratio and
render scale) from a scan's image characteristics. That only generalizes if it's
validated across **varied scans** — different DPI, grayscale vs bitonal, tight vs
loose line spacing, prose vs verse, single vs multi-column. Each script below
stresses a different axis. Validation metric: run the OCR output through the real
`ScriptParser` (`tool/parse_stats.dart`) and compare the parsed roster + line
counts to the play's known cast (the "answer key").

## The primary real-world document (copyrighted — do NOT redistribute)
- **`Pride-Prejudice-SCRIPT.pdf`** — Jon Jory's stage adaptation of *Pride and
  Prejudice*, an 82-page **150 DPI grayscale Canon copier scan** (no text layer).
  This is **copyrighted** (publisher: Concord Theatricals / Playscripts; book page
  <https://www.concordtheatricals.com/p/100407>) and is **user-provided** — it is
  not a public download and must not be committed or shared. It is the canonical
  low-quality real-world target (the scan the auto-tuner most needs to handle).
  Answer key (parsed roster): ~21 characters, 2 acts — see
  `sample-scripts/pride_and_prejudice_perfect.md` / `_master.md`.

## Public-domain test set (re-downloadable)

All public domain (pre-1929). On archive.org we deliberately fetch the **grayscale
`_bw.pdf` image derivative**, not the default `<id>.pdf` "Text PDF" — the latter
embeds an invisible OCR text layer that would let the parser bypass OCR and
invalidate the test. The two Google-digitized scans ship image-only by default.

| File | Play (edition) | Acts | Scan | DPI | Stresses | Download |
|---|---|---|---|---|---|---|
| `earnest_wilde_1920.pdf` | Importance of Being Earnest (1920) | 3 | grayscale | ~500 | clean baseline | [link](https://archive.org/download/importanceofbein1920wild/importanceofbein1920wild_bw.pdf) |
| `dollshouse_ibsen.pdf` | A Doll's House (Archer trans.) | 3 | grayscale | ~500 | cleanest/smallest | [link](https://archive.org/download/dollshouseplayin00ibseuoft/dollshouseplayin00ibseuoft_bw.pdf) |
| `pygmalion_shaw_1920.pdf` | Pygmalion (1920) | 5 | grayscale | ~500 | dense page, dialect, 5 acts | [link](https://archive.org/download/pygmalionromance00shawuoft/pygmalionromance00shawuoft_bw.pdf) |
| `chekhov_twoplays_1912.pdf` | Seagull + Cherry Orchard (Calderon 1912) | 4+4 | grayscale | ~400 | low DPI, two plays/file, Russian names | [link](https://archive.org/download/twoplaysbytchekh00chekiala/twoplaysbytchekh00chekiala_bw.pdf) |
| `ideal_husband_wilde_1899.pdf` | An Ideal Husband (1899) | 4 | **bitonal** | 600 | only bitonal, big cast, malformed xref | [link](https://archive.org/download/anidealhusband01wildgoog/anidealhusband01wildgoog.pdf) |
| `macbeth_shakespeare_1898.pdf` | Macbeth (Deighton school ed. 1898) | 5 | **bitonal** | 600 | verse + scenes, school apparatus | [link](https://archive.org/download/macbeth00deiggoog/macbeth00deiggoog.pdf) |

> The set is being expanded with lower-DPI/noisy, multi-column, Greek-chorus, and
> Restoration-comedy scans. The authoritative, always-current list (with per-file
> scan profiles and cited cast/act ground truth) is the generated manifest at
> `sample-scripts/ocr-test-set/manifest.md`.

### Recreate the public-domain set
```bash
mkdir -p sample-scripts/ocr-test-set && cd sample-scripts/ocr-test-set
base=https://archive.org/download
curl -L -o earnest_wilde_1920.pdf     $base/importanceofbein1920wild/importanceofbein1920wild_bw.pdf
curl -L -o dollshouse_ibsen.pdf       $base/dollshouseplayin00ibseuoft/dollshouseplayin00ibseuoft_bw.pdf
curl -L -o pygmalion_shaw_1920.pdf    $base/pygmalionromance00shawuoft/pygmalionromance00shawuoft_bw.pdf
curl -L -o chekhov_twoplays_1912.pdf  $base/twoplaysbytchekh00chekiala/twoplaysbytchekh00chekiala_bw.pdf
curl -L -o ideal_husband_wilde_1899.pdf $base/anidealhusband01wildgoog/anidealhusband01wildgoog.pdf
curl -L -o macbeth_shakespeare_1898.pdf $base/macbeth00deiggoog/macbeth00deiggoog.pdf
# verify each is image-only (no text layer to cheat from):
for f in *.pdf; do echo "$f: $(pdftotext -f 3 -l 5 "$f" - 2>/dev/null | tr -d '[:space:]' | wc -c) text chars (want ~0)"; done
```

Cast/act ground truth for each play is on Wikipedia (linked per-script in the
generated manifest); names are stable for the English originals (Wilde, Shaw,
Shakespeare, Ibsen/Archer). For Chekhov the role *count* and *act count* are the
stable ground truth (transliterations vary by translator).
