"""Run the shipped PaddleOCR PP-OCRv6 engine over the benchmark page images.

Uses the committed `assets/paddle_ocr/{det,rec}.onnx` + `keys.txt` via RapidOCR
(ONNX Runtime) — the same models the iOS/Android app ships. Writes one
`<script>_p<page>.paddle.txt` per page next to the rendered PNGs.

    pip install rapidocr onnxruntime pymupdf pillow numpy python-Levenshtein
    python3 harness.py manifest
    python3 run_paddle.py
"""
import json, os, time, numpy as np
from PIL import Image
from rapidocr import RapidOCR
from harness import REPO, OUT

ocr = RapidOCR(params={
    "Global.use_cls": False,                       # no orientation classifier (doc §repro)
    "Det.model_path": f"{REPO}/assets/paddle_ocr/det.onnx",
    "Det.limit_side_len": 960, "Det.limit_type": "max",   # matches PaddleOcrPlugin.swift
    "Rec.model_path": f"{REPO}/assets/paddle_ocr/rec.onnx",
    "Rec.rec_keys_path": f"{REPO}/assets/paddle_ocr/keys.txt",
})

man = json.load(open(f"{OUT}/manifest.json"))
for m in man:
    img = np.array(Image.open(m["png"]).convert("RGB"))[:, :, ::-1]  # RGB->BGR
    t0 = time.time()
    res = ocr(np.ascontiguousarray(img))
    dt = time.time() - t0
    txt = "\n".join(res.txts) if res and res.txts else ""
    open(f"{OUT}/pages/{m['script']}_p{m['page']}.paddle.txt", "w").write(txt)
    nlines = len(res.txts) if res and res.txts else 0
    print(f"{m['script']:12} p{m['page']:<4} {dt:5.1f}s  {len(txt):5d} chars  {nlines} lines")
print("PADDLE DONE")
