"""OCR benchmark harness — shared rendering, gold-text extraction, and scoring.

Compares Baidu **Unlimited-OCR** (3B MoE vision-language model, run via a GGUF
quant on llama.cpp) against the shipped **PaddleOCR PP-OCRv6** engine (the
committed `assets/paddle_ocr/*.onnx` models, run via ONNX Runtime) on the
public-domain scanned play-scripts in `sample-scripts/ocr-test-set/`.

Pipeline: render each PDF page to an image → OCR with each engine → score the
text against a per-page reference. Four of the test scripts carry an embedded
(archive.org) OCR text layer we extract as the per-page reference; the rest are
image-only and used for qualitative side-by-side only.

Metrics (see README.md for rationale):
  * word_multiset_f1 — order-insensitive fraction of real words recognized.
    This is the primary metric: it is robust to the reference's scrambled
    reading order and directly captures the "serue vs serve" garble that
    inflates the parsed character roster with phantom names.
  * cer / char_acc — standard character error rate. Secondary, and order
    sensitive, so it penalizes an engine for *disagreeing with the reference's
    (imperfect) reading order* — read it with that caveat.

Usage:
    python3 harness.py manifest      # render pages + extract gold, write manifest.json
"""
import fitz, numpy as np, re, json, os, sys
from PIL import Image
import Levenshtein
from collections import Counter

REPO = os.environ.get("CASTCIRCLE_ROOT",
                      os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))
OCRSET = f"{REPO}/sample-scripts/ocr-test-set"
OUT = os.environ.get("OCR_BENCH_OUT",
                     os.path.join(os.path.dirname(__file__), "results"))
PAGES = f"{OUT}/pages"

# Interior dialogue pages sampled per script. The four GOLD_SCRIPTS ship an
# embedded text layer (verified via `pdftotext`) used as the per-page reference;
# QUAL_SCRIPTS are image-only (no text layer) and used for qualitative diffs.
# faustus is the deliberately-degraded 150-DPI copier mimic that stands in for
# the (copyrighted, un-committed) Pride & Prejudice scan.
GOLD_SCRIPTS = {
    "earnest":    ("earnest_wilde_1920.pdf",   [40, 55, 70, 85, 100]),
    "dollshouse": ("dollshouse_ibsen.pdf",     [35, 50, 60, 72, 85]),
    "pygmalion":  ("pygmalion_shaw_1920.pdf",  [40, 55, 70, 85, 100]),
    "chekhov":    ("chekhov_twoplays_1912.pdf",[45, 70, 95, 120, 140]),
}
QUAL_SCRIPTS = {
    "faustus": ("faustus_marlowe_1905_lowdpi.pdf", [60, 75, 90]),  # P&P 150-DPI proxy
    "macbeth": ("macbeth_shakespeare_1898.pdf",    [90, 110, 130]),  # bitonal verse
}

# ---------- Unlimited-OCR markup stripping ----------
# Unlimited-OCR emits structural tags: <|det|>LABEL [x0,y0,x1,y1]<|/det|>TEXT
# where LABEL is header/title/text/page_number/etc. Strip the tags, keep text.
_DET = re.compile(r"<\|det\|>[^\[]*\[[0-9,\s]*\]<\|/det\|>")
_ANYTAG = re.compile(r"<\|[^>]*\|>")

def strip_unlimited_markup(t: str) -> str:
    t = _DET.sub(" ", t)
    t = _ANYTAG.sub(" ", t)
    return t

# ---------- scoring ----------
_WORD = re.compile(r"[a-z0-9]+")

def _words(t: str):
    return _WORD.findall(t.lower())

def _norm_chars(t: str) -> str:
    t = t.lower()
    t = re.sub(r"[^a-z0-9 ]+", " ", t)
    return re.sub(r"\s+", " ", t).strip()

def word_multiset_f1(ref: str, hyp: str) -> dict:
    r = Counter(_words(ref)); h = Counter(_words(hyp))
    inter = sum((r & h).values())
    rp = sum(r.values()); hp = sum(h.values())
    prec = inter / hp if hp else 0.0
    rec = inter / rp if rp else 0.0
    f1 = 2 * prec * rec / (prec + rec) if (prec + rec) else 0.0
    return dict(precision=round(prec, 4), recall=round(rec, 4), f1=round(f1, 4),
                garble_rate=round(1 - prec, 4), ref_words=rp, hyp_words=hp, matched=inter)

def cer(ref: str, hyp: str):
    r = _norm_chars(ref); h = _norm_chars(hyp)
    if not r:
        return None
    d = Levenshtein.distance(r, h)
    return dict(cer=round(d / len(r), 4), char_acc=round(1 - d / len(r), 4), ref_chars=len(r))

# ---------- rendering ----------
def render(pdf_path: str, page_idx: int, dpi: int = 200):
    doc = fitz.open(pdf_path)
    page = doc[page_idx]
    pix = page.get_pixmap(dpi=dpi)
    img = np.frombuffer(pix.samples, dtype=np.uint8).reshape(pix.height, pix.width, pix.n)
    if pix.n == 4:
        img = img[:, :, :3]
    gold = page.get_text().strip()
    return img.copy(), gold, (pix.width, pix.height)

def build_manifest():
    os.makedirs(PAGES, exist_ok=True)
    man = []
    for tag, (fn, idxs) in {**GOLD_SCRIPTS, **QUAL_SCRIPTS}.items():
        has_gold = tag in GOLD_SCRIPTS
        pdf = f"{OCRSET}/{fn}"
        for pi in idxs:
            img, gold, wh = render(pdf, pi)
            png = f"{PAGES}/{tag}_p{pi}.png"
            Image.fromarray(img).save(png)
            man.append(dict(script=tag, page=pi, png=png, wh=wh,
                            has_gold=has_gold, gold_len=len(gold)))
            if has_gold:
                open(f"{PAGES}/{tag}_p{pi}.gold.txt", "w").write(gold)
    json.dump(man, open(f"{OUT}/manifest.json", "w"), indent=2)
    return man

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "manifest":
        man = build_manifest()
        print(f"built {len(man)} page images under {PAGES}")
        for m in man:
            print(f"  {m['script']:12} p{m['page']:<4} {m['wh'][0]}x{m['wh'][1]} gold={m['gold_len']}")
    else:
        print(__doc__)
