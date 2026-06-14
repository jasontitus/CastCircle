# OCR Test Set — Scanned Public-Domain Play Scripts

Purpose: ground-truth corpus for validating an on-device OCR + script-parser pipeline.
All PDFs below are **image-based scans** (verified: `pdffonts` shows only non-embedded
boilerplate fonts / none real; `pdftotext` on interior pages yields ~0 characters, i.e.
no usable text layer to cheat from). All works are **public domain** (pre-1929 publication).

Generated: 2026-06-14. Total set: **12 scripts, ~117 MB** (6 original + 6 batch-2 diversity additions).

> **VERIFICATION CAVEAT (added 2026-06-14):** the "all image-based / ~0 chars" claim below is
> accurate only for the **truly image-only** files (#5, #6, #7–#12). Re-verification found that
> the four original archive.org `_bw.pdf` files (#1–#4) **do contain an invisible OCR text
> layer** — see the correction note before entry #7. Use #5–#12 if you need files where the
> parser genuinely cannot bypass OCR.

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

---

# === ADDITIONS (2026-06-14, batch 2): diversity stressors ===

> **IMPORTANT CORRECTION discovered while adding batch 2.** The claim at the top of this
> file that *all* six original PDFs are image-only is **wrong for four of them**. Re-verified
> with `pdftotext -f N -l N` on interior pages:
> - The four archive.org `_bw.pdf` LuraDocument derivatives — **earnest_wilde_1920,
>   dollshouse_ibsen, pygmalion_shaw_1920, chekhov_twoplays_1912** — each carry a **full
>   invisible OCR text layer** (≈700–2400 non-space chars/page). A parser could read that text
>   and **bypass OCR entirely** on those four. They are still scanned images, but they are NOT
>   "no text layer to cheat from."
> - Only the two **Google Books** scans — **ideal_husband_wilde_1899** and
>   **macbeth_shakespeare_1898** — are genuinely image-only (0 chars/page).
>
> Consequence for batch 2: the reliable way to get *genuinely* image-only PDFs is (a) **Google
> Books-digitized scans** (`*goog` identifiers; the `.pdf` derivative is image-only), or
> (b) **build a PDF from the archive.org `_jp2.zip` raw page images** (which never have a text
> layer). All six additions below are verified **0 text chars on every sampled interior page**
> (sampled at ~30%/50%/70% depth). The two synthesized PDFs (Faustus-lowdpi, Iolanthe) are
> assembled from the public-domain page images themselves — same PD scan, just no OCR layer.

---

## 7. atreus_aeschylus_1904.pdf — *The House of Atreus* (Aeschylus' *Oresteia*, trans. E. D. A. Morshead)

- Source page: https://archive.org/details/houseatreusbein00aescgoog
- Downloaded file: https://archive.org/download/houseatreusbein00aescgoog/houseatreusbein00aescgoog.pdf
- Edition: 1904, Macmillan (Morshead English verse translation; Aeschylus 5th c. BCE). Public domain.
- Pages: 233
- Scan profile: **BITONAL (gray colorspace, 1 bpc), 600 DPI** (JBIG2). Google Books scan. Image-only
  (0 text chars on interior pages). Carries Greek-script footnotes (non-Latin glyphs on the page).
- Why it adds diversity: **GREEK TRAGEDY with a CHORUS** — the entire genre/structure is absent
  from the original set. The CHORUS speaks as a named role (choral odes / strophe-antistrophe),
  cue names are ALL-CAPS on their own line (AGAMEMNON / CASSANDRA / CHORUS), and embedded **Greek
  script** in footnotes stresses OCR + the speaker/non-speaker discriminator. Also a **three-play
  trilogy in one file** (another multi-cast-list document, like Chekhov).

**Ground truth — a trilogy = 3 plays (one continuous play each, no act divisions); each has its own CHORUS:**
- *Agamemnon* — Chorus (Elders of Argos); Watchman; Clytemnestra; Herald; Agamemnon; Cassandra; Aegisthus.
- *The Libation-Bearers (Choephoroe)* — Chorus (slave women); Orestes; Electra; Clytemnestra; Pylades; Cilissa; Aegisthus.
- *The Furies (Eumenides)* — Chorus (the Furies); Priestess; Apollo; Orestes; Ghost of Clytemnestra; Athena.
Source: https://en.wikipedia.org/wiki/Oresteia

---

## 8. congreve_comedies_1895.pdf — *The Comedies of William Congreve, vol. II* (*Love for Love* + *The Way of the World*)

- Source page: https://archive.org/details/comedieswilliam02conggoog
- Downloaded file: https://archive.org/download/comedieswilliam02conggoog/comedieswilliam02conggoog.pdf
- Edition: 1895, Methuen (vol. 2 of a 2-vol set; Congreve d. 1729). Public domain.
- Pages: 227
- Scan profile: **BITONAL (1 bpc), 600 DPI** (JBIG2). Google Books scan. Image-only (0 text chars).
- Why it adds diversity: **RESTORATION COMEDY** — a different period typeface (1695 plays in an
  1895 setting) and, crucially, a **different cue-name format**: heavily **abbreviated** ALL-CAPS
  speaker names with a trailing period, on the same line as dialogue (`SIR SAMP.` for Sir Sampson,
  `JERE.` for Jeremy, `VAL.`, `LADY.`). None of the original plays use truncated cue names.
  Scene divisions use `SC. XV.` Roman numerals. **Two plays in one file** (another multi-cast-list
  document). Note: confirmed this is the *actual Congreve play* "The Way of the World" — a 1884
  Victorian *novel* of the same title (wayworld00murrgoog) was found and rejected.

**Ground truth — two 5-act Restoration comedies (5 acts each is standard for Congreve):**
- *Love for Love* — Sir Sampson Legend; Valentine; Scandal; Tattle; Ben; Foresight; Jeremy;
  Trapland; Buckram; Angelica; Mrs. Foresight; Mrs. Frail; Miss Prue; Nurse; Jenny. (~15 roles)
- *The Way of the World* — Fainall; Mirabell; Witwoud; Petulant; Sir Wilfull Witwoud; Waitwell;
  Lady Wishfort; Mrs. Millamant; Mrs. Marwood; Mrs. Fainall; Foible; Mincing; Peg. (~13 roles)
Sources: https://en.wikipedia.org/wiki/Love_for_Love and https://en.wikipedia.org/wiki/The_Way_of_the_World

---

## 9. patience_gilbert_1902.pdf — *Patience; or, Bunthorne's Bride* (Gilbert & Sullivan comic opera libretto)

- Source page: https://archive.org/details/patienceorbunth00gilbgoog
- Downloaded file: https://archive.org/download/patienceorbunth00gilbgoog/patienceorbunth00gilbgoog.pdf
- Edition: 1902, Chappell vocal/libretto (opera first produced 1881; Gilbert d. 1911, Sullivan d. 1900). Public domain.
- Pages: 107
- Scan profile: **BITONAL (1 bpc), 600 DPI** (JBIG2) text pages; a few pages also embed small
  **RGB 8 bpc, 150 DPI** decorative borders/illustrations (mixed-content wrinkle). Google Books
  scan. Image-only (0 text chars).
- Why it adds diversity: **MUSICAL / comic opera with SONG CUES** — a genre absent from the set.
  Musical-number headers (`RECITATIVE—BUNTHORNE`, `BALLAD—…`, `DUET`), choral parts labelled by
  group (`MAIDENS`, `DRAGOONS`), sung verse interleaved with spoken dialogue (speaker names on
  their own line). Stresses distinguishing song-cue headers and chorus-group labels from ordinary
  speaker cues, plus mixed bitonal-text / color-illustration pages.

**Ground truth — 2 acts; 11 named roles (+ choruses of Maidens and Dragoon Officers):**
Colonel Calverley; Major Murgatroyd; Lieut. the Duke of Dunstable; Reginald Bunthorne;
Archibald Grosvenor; Mr. Bunthorne's Solicitor; the Lady Angela; the Lady Saphir; the Lady Ella;
the Lady Jane; Patience (a dairy maid).
Source: https://en.wikipedia.org/wiki/Patience_(opera)

---

## 10. glaspell_plays_1920.pdf — *Plays by Susan Glaspell* (8 one-act/short plays, incl. *Trifles*)

- Source page: https://archive.org/details/playsbysusanglaspell
- Downloaded file: https://archive.org/download/playsbysusanglaspell/Plays%20by%20Susan%20Glaspell.pdf
- Edition: 1920, Small, Maynard & Co. (Google-digitized from Harvard). Public domain.
- Pages: 318 (49 MB — largest file in the set)
- Scan profile: **GRAYSCALE, 8 bpc, ~72–150 DPI** (JPEG; the PDF declares the page image at 72 px/pt,
  ≈150 DPI at true page size — the **lowest-resolution scan in the whole set**). Image-only (0 chars).
- Why it adds diversity: **LOW-DPI GRAYSCALE copier-quality scan** (the axis the user's real
  150-DPI doc needs — the original set is mostly clean 400–600 DPI). Plus **modern (1920s) American
  typeface** and a **distinct cue-name format**: speaker names rendered in **letterspaced small-caps
  on their own line** (`THE WOMAN`, `OSCAR`, `LIGHT TOUCH`, `ED`) with **heavy bracketed italic
  stage directions** (`[Thinking aloud.]`, `[Enter THE LIGHT TOUCH.`). An **8-play volume** → many
  cast lists / act boundaries in one file, mostly one-acts.

**Ground truth — 8 plays (per the printed Contents page):**
Trifles (1 act); The People (1 act); Close the Book (comedy, 1 act); The Outside (1 act);
Woman's Honor (comedy, 1 act); Bernice (a play in **3 acts**); Suppressed Desires (comedy, 2 scenes,
w/ George Cram Cook); Tickless Time (comedy, 1 act, w/ George Cram Cook).
*Trifles* cast: George Henderson (county attorney); Henry Peters (sheriff); Lewis Hale; Mrs. Peters;
Mrs. Hale (+ the absent John & Minnie Wright).
Sources: printed Contents page (OCR'd); https://en.wikipedia.org/wiki/Trifles_(play)

---

## 11. faustus_marlowe_1905_lowdpi.pdf — *The Tragical History of Doctor Faustus* (Christopher Marlowe) — **synthesized low-DPI/noisy variant**

- Source page: https://archive.org/details/tragicalhistory00marlgoog (1905, J. M. Dent; Marlowe d. 1593). Public domain.
- Original derivative: https://archive.org/download/tragicalhistory00marlgoog/tragicalhistory00marlgoog.pdf
  (Google scan, image-only, bitonal 600 DPI).
- **This file is a deliberately DEGRADED copy** built locally from that PD scan to mimic a real
  copier/photocopy: rendered at 150 DPI, converted to **grayscale 8 bpc**, **Gaussian noise added**,
  slight blur, a small **random ±1° per-page skew/rotation**, and **JPEG quality 45** (heavy
  artifacts). Still legible (OCR'd correctly in spot checks) so it remains valid ground truth.
- Pages: 139
- Scan profile: **GRAYSCALE, 8 bpc, 150 DPI, JPEG (noisy, lightly skewed)**. Image-only (0 chars).
- Why it adds diversity: directly targets the **VERY LOW-DPI / NOISY / SKEWED** axis (mirrors the
  user's real 150-DPI Pride & Prejudice scan) — the single most-requested missing characteristic.
  Also adds **Elizabethan tragedy** content: a narrator **CHORUS**, blank-verse + prose, `SCENE`
  divisions, and Title-Case cue names (`Faustus.`, `Robin.`, `Mephistophilis.`).

**Ground truth — 5 acts / 13 scenes (1604 "A" text); principal roles:**
Chorus (narrator); Doctor Faustus; Mephistophilis; Wagner; Good Angel; Evil/Bad Angel; Lucifer;
Belzebub; Robin; Rafe; the Seven Deadly Sins; Old Man; Helen of Troy; Pope; Emperor (Charles V).
Source: https://en.wikipedia.org/wiki/Doctor_Faustus_(play)

---

## 12. iolanthe_gilbert_1882.pdf — *Iolanthe; or, The Peer and the Peri* (Gilbert & Sullivan) — **built from page images, COLOR**

- Source page: https://archive.org/details/iolantheorpeerpe00sulluoft
- Built from: https://archive.org/download/iolantheorpeerpe00sulluoft/iolantheorpeerpe00sulluoft_jp2.zip
  (the archive.org `.pdf` and `_bw.pdf` LuraDocument derivatives both carry an OCR text layer, so they
  were rejected; this PDF is **assembled locally from the raw jp2 page images** → no text layer).
- Edition: 1882, Chappell libretto (opera produced 1882; Gilbert/Sullivan as above). Public domain.
- Pages: 54
- Scan profile: **COLOR (RGB), 8 bpc, 400 DPI** (JPEG-in-PDF, q60). Image-only (0 chars). Mildly
  skewed/wavy source → noisier OCR than the clean Google bitonals.
- Why it adds diversity: the **only COLOR scan in the set** (every other file is grayscale or
  bitonal). A second **MUSICAL** with song cues (`BALLAD—LORD TOLLOLLER`, `RECITATIVE`, `CHORUS`)
  and a different cue-name style from #9. Color + 400 DPI + skew gives the tuner a distinct
  preprocessing regime (color→gray, deskew) it can't exercise on the rest of the set.

**Ground truth — 2 acts; 11 named roles (+ chorus of Peers and Fairies):**
The Lord Chancellor; George, Earl of Mountararat; Thomas, Earl Tolloller; Private Willis;
Strephon (an Arcadian shepherd); Queen of the Fairies; Iolanthe; Celia; Leila; Fleta;
Phyllis (an Arcadian shepherdess / Ward in Chancery).
Source: https://en.wikipedia.org/wiki/Iolanthe

---

## Diversity summary

| # | File | Play | Acts | Scan color | DPI | Vendor/era | Distinctive stressor |
|---|------|------|------|-----------|-----|-----------|----------------------|
| 1 | earnest_wilde_1920    | Earnest        | 3 | grayscale 8bpc | ~500 | archive.org / 1920 | clean baseline *(has OCR text layer)* |
| 2 | dollshouse_ibsen      | Doll's House   | 3 | grayscale 8bpc | ~500 | archive.org / ~1900s | cleanest, smallest *(has OCR text layer)* |
| 3 | pygmalion_shaw_1920   | Pygmalion      | 5 | grayscale 8bpc | ~500 | archive.org / 1920 | dense small page, dialect, 5 acts *(has OCR text layer)* |
| 4 | chekhov_twoplays_1912 | Seagull+Cherry | 4+4 | grayscale 8bpc | ~400 | archive.org / 1912 | TWO plays, Russian names *(has OCR text layer)* |
| 5 | ideal_husband_wilde_1899 | Ideal Husband | 4 | **bitonal 1bpc** | 600 | Google / 1899 | bitonal, malformed xref, big cast (truly image-only) |
| 6 | macbeth_shakespeare_1898 | Macbeth      | 5 | **bitonal 1bpc** | 600 | Google / 1898 | VERSE + scenes, school apparatus (truly image-only) |
| 7 | atreus_aeschylus_1904 | Oresteia (×3)  | 0 (continuous) | **bitonal 1bpc** | 600 | Google / 1904 | **GREEK TRAGEDY + CHORUS**, Greek-script footnotes, trilogy |
| 8 | congreve_comedies_1895 | Love for Love + Way of the World | 5+5 | **bitonal 1bpc** | 600 | Google / 1895 | **RESTORATION**, abbreviated caps cues (`SIR SAMP.`), 2 plays |
| 9 | patience_gilbert_1902 | Patience       | 2 | **bitonal 1bpc** (+RGB 150 insets) | 600 | Google / 1902 | **MUSICAL / song cues**, chorus-group labels, mixed content |
| 10 | glaspell_plays_1920  | 8 one-acts (Trifles…) | mostly 1 (Bernice 3) | **grayscale 8bpc** | **~72–150 (lowest)** | Google / 1920 | **LOW-DPI grayscale**, modern type, small-caps cues, 8 plays |
| 11 | faustus_marlowe_1905_lowdpi | Doctor Faustus | 5 (13 scenes) | **grayscale 8bpc** | **150 (degraded)** | synth from Google / 1905 | **LOW-DPI + NOISE + SKEW** (copier mimic), Elizabethan CHORUS |
| 12 | iolanthe_gilbert_1882 | Iolanthe       | 2 | **COLOR RGB 8bpc** | 400 | synth from jp2 / 1882 | **only COLOR scan**, musical song cues, skew/deskew |

## Rejected candidates

### Batch 1
- Sophocles *Oedipus*/*Sophocles I* modern editions (e.g. sophoclesioedipu00soph, 1991;
  oedipuskingantig00soph, 1987): **copyrighted modern translations**, borrow-only with
  ACS-encrypted (DRM) PDFs. Not public domain — rejected.
- Sophocles *Tragedies and Fragments* (Plumptre, 1914, PD): 32 MB and a complete-works
  collection ("and fragments") rather than a clean single play → ambiguous single-play
  ground truth and oversized → rejected to keep the set script-shaped.
- archive.org "Text PDF" derivatives (the default `<id>.pdf`): these carry an invisible OCR
  text layer, so `pdftotext` returns full text and the parser could bypass OCR.

### Batch 2 (2026-06-14)
- **archive.org `_bw.pdf` LuraDocument derivatives** (e.g. schoolforscanda00sher_bw,
  piratesofpenzanc00sull_bw, therivals00sheriala_bw, iolantheorpeerpe00sulluoft) and the
  **HP-recoded `OedipusKingOfThebes.pdf`**: all looked like image scans but **carry a full
  invisible OCR text layer** (≈500–1800 chars/interior page) — a parser could bypass OCR.
  Rejected as-is. (This is the same defect now flagged in original entries #1–#4 above.) For
  Iolanthe we instead **rebuilt an image-only PDF from its `_jp2.zip`** (→ entry #12).
- **wayworld00murrgoog** (1884, "The way of the world"): title-matched a **Victorian prose
  NOVEL**, not Congreve's Restoration play (OCR showed narrative prose: *"said Mr. Amelia… replied
  the visitor"*). Wrong content — rejected; used `comedieswilliam02conggoog` instead, which
  contains the genuine Congreve play (verified).
- **hippolytuseurip00murrgoog** (Euripides, Murray, 1904): valid PD Google image-only scan, but
  redundant with atreus_aeschylus_1904 on the "Greek tragedy + chorus" axis → dropped to avoid
  two near-identical Greek entries.

### Note on building image-only PDFs (batch 2 method)
Two additions are **synthesized** because no clean image-only derivative existed: Faustus-lowdpi
(degraded from the PD Google scan to hit the low-DPI/noise/skew axis) and Iolanthe (assembled from
the PD `_jp2.zip` page images via `opj_decompress` → png → `magick … -compress JPEG`). Both are the
same public-domain scans, just without any OCR text layer, and both verify at 0 text chars/page.
