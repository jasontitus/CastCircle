"""Score PaddleOCR and Unlimited-OCR outputs against the per-page gold text.

Reads manifest.json + the *.gold.txt / *.paddle.txt / *.unlimited.txt written by
the runners, computes word-multiset F1 (primary) and character accuracy
(secondary), prints a per-page table + aggregate, and writes report.md.

    python3 score.py
"""
import json, os, statistics as st
from harness import strip_unlimited_markup, word_multiset_f1, cer, OUT

def load(p):
    return open(p).read() if os.path.exists(p) and os.path.getsize(p) > 0 else None

man = json.load(open(f"{OUT}/manifest.json"))
rows = []
for m in man:
    if not m["has_gold"]:
        continue
    base = f"{OUT}/pages/{m['script']}_p{m['page']}"
    gold = load(base + ".gold.txt")
    texts = {"paddle": load(base + ".paddle.txt"), "unlimited": load(base + ".unlimited.txt")}
    if texts["unlimited"] is not None:
        texts["unlimited"] = strip_unlimited_markup(texts["unlimited"])
    row = dict(script=m["script"], page=m["page"])
    for eng, txt in texts.items():
        if txt is None or gold is None:
            row[eng] = None
            continue
        f = word_multiset_f1(gold, txt); c = cer(gold, txt)
        row[eng] = dict(f1=f["f1"], recall=f["recall"], precision=f["precision"],
                        garble=f["garble_rate"], char_acc=c["char_acc"])
    rows.append(row)

def agg(eng, metric):
    vals = [r[eng][metric] for r in rows if r.get(eng)]
    return round(st.mean(vals), 4) if vals else None

# console
print(f"{'script':11} {'pg':>4} | {'PADDLE f1/rec/gar':>22} | {'UNLIMITED f1/rec/gar':>22}")
for r in rows:
    def fmt(e):
        d = r.get(e)
        return f"{d['f1']:.3f}/{d['recall']:.3f}/{d['garble']:.3f}" if d else "   --- pending ---   "
    print(f"{r['script']:11} {r['page']:>4} | {fmt('paddle'):>22} | {fmt('unlimited'):>22}")
print("\n=== AGGREGATE (mean over scored pages) ===")
for e in ["paddle", "unlimited"]:
    print(f"{e:10}  f1={agg(e,'f1')}  recall={agg(e,'recall')}  "
          f"precision={agg(e,'precision')}  garble={agg(e,'garble')}  char_acc={agg(e,'char_acc')}")

# per-script aggregate
def sagg(script, eng, metric):
    vals = [r[eng][metric] for r in rows if r["script"] == script and r.get(eng)]
    return round(st.mean(vals), 4) if vals else None

scripts = sorted({r["script"] for r in rows})
lines = ["# OCR benchmark — Unlimited-OCR vs PaddleOCR PP-OCRv6", "",
         "Primary metric: **word-multiset F1** (order-insensitive fraction of real "
         "words recognized). char-acc is order-sensitive CER, secondary.", "",
         "| script | pages | Paddle F1 | Unlimited F1 | Paddle char-acc | Unlimited char-acc | Paddle garble | Unlimited garble |",
         "|---|---|---|---|---|---|---|---|"]
for s in scripts:
    n = len([r for r in rows if r["script"] == s])
    lines.append(f"| {s} | {n} | {sagg(s,'paddle','f1')} | {sagg(s,'unlimited','f1')} | "
                 f"{sagg(s,'paddle','char_acc')} | {sagg(s,'unlimited','char_acc')} | "
                 f"{sagg(s,'paddle','garble')} | {sagg(s,'unlimited','garble')} |")
lines.append(f"| **ALL** | {len(rows)} | **{agg('paddle','f1')}** | **{agg('unlimited','f1')}** | "
             f"**{agg('paddle','char_acc')}** | **{agg('unlimited','char_acc')}** | "
             f"**{agg('paddle','garble')}** | **{agg('unlimited','garble')}** |")
open(f"{OUT}/report.md", "w").write("\n".join(lines) + "\n")
json.dump(rows, open(f"{OUT}/scores.json", "w"), indent=2)
print(f"\nwrote {OUT}/report.md and scores.json")
