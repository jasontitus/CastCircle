# OCR Test Set — Scanned Public-Domain Play Scripts

Purpose: ground-truth corpus for validating an on-device OCR + script-parser pipeline.
All PDFs below are **image-based scans** (verified: `pdffonts` shows only non-embedded
boilerplate fonts / none real; `pdftotext` on interior pages yields ~0 characters, i.e.
no usable text layer to cheat from). All works are **public domain** (pre-1929 publication).

Generated: 2026-06-14. Total set: 6 scripts, ~29 MB.

Note on the scan-image profile: the archive.org grayscale derivatives embed a small
low-res thumbnail PLUS the high-res text image per page. The DPI/bpc values below are the
**primary high-resolution text image** (measured with `pdfimages -list` on interior content
pages), which is what the OCR actually consumes.

Note on cast lists: for the English-original plays (Wilde, Shaw, Shakespeare, Ibsen via the
standard Archer translation) character names are stable. For Chekhov, transliterations vary by
translator (this scan is the **Calderon 1912** translation, e.g. "Trepleff", "Lopahin",
"Madame Ranevsky"); the *count* of named roles and the *act count* are the stable ground truth.

---

## 1. earnest_wilde_1920.pdf — *The Importance of Being Earnest* (Oscar Wilde)

- Source page: https://archive.org/details/importanceofbein1920wild
- Downloaded file: https://archive.org/download/importanceofbein1920wild/importanceofbein1920wild_bw.pdf
- Edition: 1920 (Wilde d. 1900; play first performed 1895). Public domain.
- Pages: 136
- Scan profile: **grayscale, 8 bpc, ~500 DPI** (JPX/JPEG2000 image + JBIG2 soft-mask).
  Clean library scan, large clear serif type. Image-only (interior pages: 0 real text chars).
- Why it's useful: clean, high-DPI grayscale baseline; prose drama with clearly-printed
  speaker-name + dialogue layout.

**Ground truth — 3 acts; 9 named characters:**
John (Jack) Worthing J.P.; Algernon Moncrieff; Rev. Canon Chasuble D.D.; Merriman (butler);
Lane (manservant); Lady Bracknell; Hon. Gwendolen Fairfax; Cecily Cardew; Miss Prism.
Source: https://en.wikipedia.org/wiki/The_Importance_of_Being_Earnest

---

## 2. dollshouse_ibsen.pdf — *A Doll's House* (Henrik Ibsen, trans. William Archer)

- Source page: https://archive.org/details/dollshouseplayin00ibseuoft
- Downloaded file: https://archive.org/download/dollshouseplayin00ibseuoft/dollshouseplayin00ibseuoft_bw.pdf
- Edition: early 1900s (Archer translation; Ibsen d. 1906; play 1879). Public domain.
- Pages: 104
- Scan profile: **grayscale, 8 bpc, ~500 DPI**. Clean University of Toronto library scan.
  Image-only (interior pages: ~0 real text chars).
- Why it's useful: smallest/cleanest file; tight 3-act prose play; a good "easy" control case
  and a different publisher/typeface from #1.

**Ground truth — 3 acts ("a play in three acts" per the title page); 9 roles:**
Torvald Helmer; Nora (his wife); Doctor Rank; Mrs. Linde; Nils Krogstad; the three Helmer
children; Anne (nurse); a Housemaid; a Porter.
Sources: https://americanliterature.com/author/henrik-ibsen/play/a-dolls-house/dramatis-personae
and https://en.wikipedia.org/wiki/A_Doll's_House

---

## 3. pygmalion_shaw_1920.pdf — *Pygmalion* (George Bernard Shaw)

- Source page: https://archive.org/details/pygmalionromance00shawuoft
- Downloaded file: https://archive.org/download/pygmalionromance00shawuoft/pygmalionromance00shawuoft_bw.pdf
- Edition: 1920, Constable, London (play first published 1913/16). Public domain.
- Pages: 126
- Scan profile: **grayscale, 8 bpc, ~500 DPI**, small page (265x440 pt) → denser type.
  Image-only (interior pages: 0 real text chars).
- Why it's useful: 5-act play (more acts to detect); Shaw uses long descriptive stage
  directions and dialect spelling for Eliza — stresses speaker-vs-direction discrimination.

**Ground truth — 5 acts; principal named roles:**
Henry Higgins; Eliza Doolittle; Colonel Pickering; Alfred Doolittle; Mrs. Higgins;
Mrs. Pearce; Freddy Eynsford Hill; Mrs. Eynsford Hill; Clara Eynsford Hill; (plus a
Bystander/Sarcastic Bystander, a Parlourmaid). Core cast ≈ 9-11.
Source: https://en.wikipedia.org/wiki/Pygmalion_(play) and https://www.sparknotes.com/lit/pygmalion/characters/

---

## 4. chekhov_twoplays_1912.pdf — *The Seagull* + *The Cherry Orchard* (Anton Chekhov, trans. George Calderon)

- Source page: https://archive.org/details/twoplaysbytchekh00chekiala
- Downloaded file: https://archive.org/download/twoplaysbytchekh00chekiala/twoplaysbytchekh00chekiala_bw.pdf
- Edition: 1912, Grant Richards, London (Calderon translation). Public domain.
- Pages: 168
- Scan profile: **grayscale, 8 bpc, ~400 DPI** (lower DPI than #1-3). Image-only.
- Why it's useful: (a) lowest-DPI grayscale → more OCR noise; (b) **two plays in one volume**
  → tests detection of multiple cast lists / act boundaries within one file; (c) Russian
  patronymic names (Konstantin Gavrilovich, etc.) stress name parsing.

**Ground truth (two plays):**
- *The Seagull* — **4 acts**; 13 roles: Irina Arkadina; Konstantin Treplev; Pyotr Sorin;
  Nina Zarechnaya; Ilya Shamrayev; Polina Andreyevna; Masha (Maria Shamrayeva);
  Boris Trigorin; Yevgeny Dorn; Semyon Medvedenko; Yakov; a Cook; a Maid.
  Source: https://en.wikipedia.org/wiki/The_Seagull
- *The Cherry Orchard* — **4 acts**; ~13 roles: Lyubov Ranevskaya; Anya; Varya; Leonid Gayev;
  Yermolai Lopakhin; Peter Trofimov; Boris Simeonov-Pishchik; Charlotta Ivanovna;
  Semyon Yepikhodov; Dunyasha; Firs; Yasha; a Passer-by/Stationmaster/Postmaster.
  Source: https://en.wikipedia.org/wiki/The_Cherry_Orchard
- NOTE: Calderon's 1912 spellings differ (e.g. "Trepleff", "Lopahin", "Madame Ranevsky").

---

## 5. ideal_husband_wilde_1899.pdf — *An Ideal Husband* (Oscar Wilde)

- Source page: https://archive.org/details/anidealhusband01wildgoog
- Downloaded file: https://archive.org/download/anidealhusband01wildgoog/anidealhusband01wildgoog.pdf
- Edition: 1899, Leonard Smithers & Co. (Google-digitized from Harvard). Public domain.
- Pages: 233
- Scan profile: **BITONAL (1 bpc, black & white), 600 DPI** (JBIG2). Google Books scan.
  Image-only; PDF has a malformed xref ("Internal Error … reconstruct" warning) — also a
  useful real-world robustness test for the loader.
- Why it's useful: the **only bitonal scan** in the set (hard thresholding, different OCR
  failure modes vs grayscale); different scan vendor (Google) and an 1899 first-edition
  typeface; 4-act play.

**Ground truth — 4 acts; cast:**
The Earl of Caversham; Viscount Goring (Lord Goring); Sir Robert Chiltern; Vicomte de Nanjac;
Mr. Montford; Phipps; Mason; James; Harold; Lady Chiltern; Lady Markby; Countess of Basildon;
Mrs. Marchmont; Miss Mabel Chiltern; Mrs. Cheveley. (~15 named roles)
Source: https://en.wikipedia.org/wiki/An_Ideal_Husband

---

## 6. macbeth_shakespeare_1898.pdf — *Macbeth* (William Shakespeare, Deighton school ed.)

- Source page: https://archive.org/details/macbeth00deiggoog
- Downloaded file: https://archive.org/download/macbeth00deiggoog/macbeth00deiggoog.pdf
- Edition: 1898 Macmillan school edition (notes by K. Deighton), Google-digitized. Public domain.
- Pages: 231 (includes long editorial intro + notes around the play text)
- Scan profile: **BITONAL (1 bpc), 600 DPI** (JBIG2). Google Books scan. Image-only.
- Why it's useful: **verse** drama (vs prose in #1-5) with Act + Scene subdivisions and
  short verse lines; older 1898 typeface; a school edition means surrounding apparatus
  (intro, footnotes, glossary) that the parser must distinguish from the play proper.

**Ground truth — 5 acts (each divided into scenes); principal named characters:**
Macbeth; Lady Macbeth; Duncan; Malcolm; Donalbain; Banquo; Fleance; Macduff; Lady Macduff;
Macduff's son; the Three Witches (Weird Sisters); Hecate; Ross; Lennox; Angus; Menteith;
Caithness; Siward; Young Siward; Seyton; Porter; Doctor (plus messengers, murderers, lords).
Source: https://en.wikipedia.org/wiki/Macbeth

---

## Diversity summary

| # | File | Play | Acts | Scan color | DPI | Vendor/era | Distinctive stressor |
|---|------|------|------|-----------|-----|-----------|----------------------|
| 1 | earnest_wilde_1920    | Earnest        | 3 | grayscale 8bpc | ~500 | archive.org / 1920 | clean baseline |
| 2 | dollshouse_ibsen      | Doll's House   | 3 | grayscale 8bpc | ~500 | archive.org / ~1900s | cleanest, smallest |
| 3 | pygmalion_shaw_1920   | Pygmalion      | 5 | grayscale 8bpc | ~500 | archive.org / 1920 | dense small page, dialect, 5 acts |
| 4 | chekhov_twoplays_1912 | Seagull+Cherry | 4+4 | grayscale 8bpc | ~400 | archive.org / 1912 | lowest DPI, TWO plays, Russian names |
| 5 | ideal_husband_wilde_1899 | Ideal Husband | 4 | **bitonal 1bpc** | 600 | Google / 1899 | bitonal, malformed xref, big cast |
| 6 | macbeth_shakespeare_1898 | Macbeth      | 5 | **bitonal 1bpc** | 600 | Google / 1898 | VERSE + scenes, school apparatus |

## Rejected candidates
- Sophocles *Oedipus*/*Sophocles I* modern editions (e.g. sophoclesioedipu00soph, 1991;
  oedipuskingantig00soph, 1987): **copyrighted modern translations**, borrow-only with
  ACS-encrypted (DRM) PDFs. Not public domain — rejected.
- Sophocles *Tragedies and Fragments* (Plumptre, 1914, PD): 32 MB and a complete-works
  collection ("and fragments") rather than a clean single play → ambiguous single-play
  ground truth and oversized → rejected to keep the set script-shaped.
- archive.org "Text PDF" derivatives (the default `<id>.pdf`): these carry an invisible OCR
  text layer, so `pdftotext` returns full text and the parser could bypass OCR. We
  deliberately downloaded the `_bw.pdf` grayscale (image-only) derivatives instead, except
  for the two Google scans which ship as image-only by default.
