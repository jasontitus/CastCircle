import Flutter
import UIKit
import PDFKit
import onnxruntime_objc

/// On-device PaddleOCR (PP-OCRv6 small) via ONNX Runtime.
///
/// Replaces Google ML Kit for PDF/image OCR on iOS. Mirrors the macOS
/// `VisionOcrPlugin` channel contract (`recognizeText` / `ocrPdf` →
/// `pages → lines → {text, confidence}`) so the import pipeline swaps engines
/// with no shape change; the Dart side falls back to ML Kit if this plugin
/// isn't registered or throws.
///
/// Pipeline per page: render (PDFKit) → DB detection ONNX → threshold +
/// connected-component boxes → crop each box → recognition ONNX → CTC greedy
/// decode against the PP-OCRv6 dictionary. Reasonable defaults throughout; the
/// box extraction is connected-components (not full DBNet contour+unclip), which
/// is a known simplification we can refine after measuring on-device.
class PaddleOcrPlugin: NSObject {
  private let channel: FlutterMethodChannel
  private var env: ORTEnv?
  private var detSession: ORTSession?
  private var recSession: ORTSession?
  private var keys: [String] = []
  private var ready = false

  // Detection / recognition constants (PP-OCR defaults).
  private let detLimitSide = 960
  private let detThresh: Float = 0.3        // binarize the probability map
  private let detMinBoxArea = 16            // drop specks (in det-map pixels)
  // DBNet "unclip" box expansion. The optimal value is DOCUMENT-DEPENDENT: a
  // larger ratio recovers clipped glyphs on loose-spaced/high-DPI scans, but on
  // a tight-spaced low-DPI copier scan it over-expands and MERGES adjacent text
  // lines into one box, which the recognizer then mangles. 0.8 is the safe
  // default for real-world copier scans — verified on-Mac through the real
  // parser on a 150-DPI P&P scan: garbled lines −79%, name accuracy 95.6%→99.1%,
  // ELIZABETH fragments (ELZA/ELIZABT/LZABTH) collapse back into one character.
  // A per-document auto-tuner (pick this from measured line spacing) supersedes
  // this static value.
  private let detUnclipRatio: Float = 0.8
  private let recHeight = 48
  private let recMaxWidth = 1024
  private let detMean: [Float] = [0.485, 0.456, 0.406]
  private let detStd: [Float] = [0.229, 0.224, 0.225]

  init(registrar: FlutterPluginRegistrar, messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.lineguide/paddle_ocr", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler(handle)
    loadModels(registrar: registrar)
  }

  // MARK: - Model loading

  private func assetPath(_ registrar: FlutterPluginRegistrar, _ asset: String) -> String? {
    let key = registrar.lookupKey(forAsset: asset)
    return Bundle.main.path(forResource: key, ofType: nil)
  }

  private func loadModels(registrar: FlutterPluginRegistrar) {
    guard let detPath = assetPath(registrar, "assets/paddle_ocr/det.onnx"),
          let recPath = assetPath(registrar, "assets/paddle_ocr/rec.onnx"),
          let keysPath = assetPath(registrar, "assets/paddle_ocr/keys.txt") else {
      NSLog("PaddleOCR: model assets not found — falling back to ML Kit")
      return
    }
    do {
      let t0 = Date()
      env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
      let opts = try ORTSessionOptions()
      try opts.setIntraOpNumThreads(0)  // 0 = use all cores
      try opts.setGraphOptimizationLevel(.all)
      detSession = try ORTSession(env: env!, modelPath: detPath, sessionOptions: opts)
      recSession = try ORTSession(env: env!, modelPath: recPath, sessionOptions: opts)
      let raw = (try? String(contentsOfFile: keysPath, encoding: .utf8)) ?? ""
      keys = raw.components(separatedBy: "\n")
      while let last = keys.last, last.isEmpty { keys.removeLast() }
      ready = true
      NSLog("PaddleOCR: models loaded in \(Int(Date().timeIntervalSince(t0)*1000))ms — \(keys.count) keys")
    } catch {
      NSLog("PaddleOCR: model load failed: \(error) — falling back to ML Kit")
    }
  }

  // MARK: - Channel

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard ready else {
      // Returning NOT_IMPLEMENTED makes the Dart channel fall back to ML Kit.
      result(FlutterError(code: "NOT_READY", message: "PaddleOCR models not loaded", details: nil))
      return
    }
    switch call.method {
    case "recognizeText":
      guard let path = (call.arguments as? [String: Any])?["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing 'path'", details: nil)); return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        var blocks: [[String: Any]] = []
        if let img = UIImage(contentsOfFile: path)?.cgImage { blocks = self.ocrImage(img) }
        DispatchQueue.main.async { result(["blocks": blocks]) }
      }
    case "ocrPdf":
      guard let path = (call.arguments as? [String: Any])?["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing 'path'", details: nil)); return
      }
      let scale = (call.arguments as? [String: Any])?["scale"] as? Double ?? 2.0
      ocrPdf(path: path, scale: scale, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func ocrPdf(path: String, scale: Double, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
        DispatchQueue.main.async {
          result(FlutterError(code: "PDF_OPEN_FAILED", message: "Could not open PDF", details: nil))
        }
        return
      }
      let pageCount = doc.pageCount
      var pages: [[String: Any]] = []
      var failed = 0
      let jobStart = Date()
      for i in 0..<pageCount {
        // Push per-page progress to Dart so the import screen shows
        // "Reading page X of Y" instead of a frozen spinner.
        DispatchQueue.main.async {
          self.channel.invokeMethod("ocrProgress",
                                    arguments: ["page": i + 1, "pageCount": pageCount])
        }
        guard let page = doc.page(at: i) else { failed += 1; continue }
        let b = page.bounds(for: .mediaBox)
        guard let cg = self.renderPage(page, width: b.width * CGFloat(scale), height: b.height * CGFloat(scale)) else {
          failed += 1; continue
        }
        let t0 = Date()
        let lines = self.ocrImage(cg)
        pages.append(["page": i + 1, "lines": lines])
        NSLog("PaddleOCR: page \(i+1)/\(pageCount) — \(lines.count) lines in \(Int(Date().timeIntervalSince(t0)*1000))ms")
      }
      let total = Date().timeIntervalSince(jobStart)
      NSLog("PaddleOCR: \(pageCount) pages in \(String(format: "%.1f", total))s (\(String(format: "%.2f", total/Double(max(pageCount,1)))) s/page)")
      DispatchQueue.main.async {
        result(["pages": pages, "pageCount": pageCount, "failedPages": failed])
      }
    }
  }

  // MARK: - PP-OCR pipeline

  private func ocrImage(_ cg: CGImage) -> [[String: Any]] {
    guard let det = detSession, let rec = recSession else { return [] }
    let origW = cg.width, origH = cg.height
    // 1. Detection: resize to multiples of 32 (≤ limit), normalize, run.
    let ratio = min(Float(detLimitSide) / Float(max(origW, origH)), 1.0)
    let newW = max(32, Int((Float(origW) * ratio / 32).rounded()) * 32)
    let newH = max(32, Int((Float(origH) * ratio / 32).rounded()) * 32)
    guard let detIn = imageToTensor(cg, newW, newH, mean: detMean, std: detStd) else { return [] }
    guard let (prob, pShape) = try? run(det, detIn, [1, 3, newH, newW]), pShape.count >= 2 else { return [] }
    let mH = pShape[pShape.count - 2], mW = pShape[pShape.count - 1]
    // 2. Threshold + connected-component boxes, mapped back to original coords.
    let boxes = detectBoxes(prob, mW: mW, mH: mH, origW: origW, origH: origH)
    // 3. Recognize each box, sorted top-to-bottom (reading order).
    var lines: [[String: Any]] = []
    for box in boxes.sorted(by: { $0.minY < $1.minY }) {
      guard let crop = cg.cropping(to: box) else { continue }
      if let (text, conf) = recognize(crop, rec) , !text.isEmpty {
        lines.append(["text": text, "confidence": conf])
      }
    }
    return lines
  }

  /// Threshold the DB probability map and extract axis-aligned boxes via a
  /// scanline connected-components pass, scaled back to original-image coords.
  private func detectBoxes(_ prob: [Float], mW: Int, mH: Int, origW: Int, origH: Int) -> [CGRect] {
    var label = [Int](repeating: 0, count: mW * mH)
    var next = 1
    var minX = [Int](), minY = [Int](), maxX = [Int](), maxY = [Int](), area = [Int]()
    func newComp() { minX.append(Int.max); minY.append(Int.max); maxX.append(0); maxY.append(0); area.append(0) }
    newComp() // index 0 unused
    var stack = [Int]()
    for sy in 0..<mH {
      for sx in 0..<mW {
        let s = sy * mW + sx
        if prob[s] <= detThresh || label[s] != 0 { continue }
        newComp(); let id = next; next += 1
        stack.removeAll(keepingCapacity: true); stack.append(s); label[s] = id
        while let p = stack.popLast() {
          let x = p % mW, y = p / mW
          if x < minX[id] { minX[id] = x }; if x > maxX[id] { maxX[id] = x }
          if y < minY[id] { minY[id] = y }; if y > maxY[id] { maxY[id] = y }
          area[id] += 1
          for (dx, dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
            let nx = x + dx, ny = y + dy
            if nx < 0 || ny < 0 || nx >= mW || ny >= mH { continue }
            let np = ny * mW + nx
            if prob[np] > detThresh && label[np] == 0 { label[np] = id; stack.append(np) }
          }
        }
      }
    }
    let sx = CGFloat(origW) / CGFloat(mW), sy = CGFloat(origH) / CGFloat(mH)
    var boxes = [CGRect]()
    for id in 1..<next where area[id] >= detMinBoxArea {
      // DBNet shrinks text regions — the probability map fires only on glyph
      // cores — so a raw connected component clips ascenders/descenders and
      // corrupts recognition (BANQUO→BANOUO, y→v, commas→periods). Recover the
      // full glyph with PP-OCR's "unclip": expand the bbox outward by
      // dist = area · ratio / perimeter (in det-map pixels) before the ±1px pad.
      // Verified on-Mac against the real models (real Swift pipeline): lifts word
      // accuracy 92% → 99%, matching rapidocr's full DBNet contour+unclip.
      let bw = maxX[id] - minX[id] + 1, bh = maxY[id] - minY[id] + 1
      let dist = Int((Float(bw * bh) * detUnclipRatio / Float(2 * (bw + bh))).rounded())
      let mnx = minX[id] - dist, mny = minY[id] - dist
      let mxx = maxX[id] + dist, mxy = maxY[id] + dist
      let x0 = CGFloat(max(0, mnx - 1)) * sx
      let y0 = CGFloat(max(0, mny - 1)) * sy
      let x1 = CGFloat(min(mW, mxx + 2)) * sx
      let y1 = CGFloat(min(mH, mxy + 2)) * sy
      boxes.append(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
    }
    return boxes
  }

  /// Recognize one cropped text-line image → (text, confidence) via CTC greedy.
  private func recognize(_ crop: CGImage, _ rec: ORTSession) -> (String, Double)? {
    let h = crop.height, w = crop.width
    if h == 0 { return nil }
    var rw = Int((Float(recHeight) * Float(w) / Float(h)).rounded())
    rw = max(16, min(rw, recMaxWidth))
    let mean: [Float] = [0.5, 0.5, 0.5], std: [Float] = [0.5, 0.5, 0.5]
    guard let inp = imageToTensor(crop, rw, recHeight, mean: mean, std: std) else { return nil }
    guard let (out, shape) = try? run(rec, inp, [1, 3, recHeight, rw]), shape.count == 3 else { return nil }
    let T = shape[1], C = shape[2]
    var sb = ""; var probSum: Double = 0; var emitted = 0; var prev = -1
    for t in 0..<T {
      var best = 0; var bestP: Float = -1
      let base = t * C
      for c in 0..<C { let p = out[base + c]; if p > bestP { bestP = p; best = c } }
      if best != 0 && best != prev {
        let idx = best - 1
        if idx >= 0 && idx < keys.count { sb += keys[idx] }
        else { sb += " " }  // trailing space class
        probSum += Double(bestP); emitted += 1
      }
      prev = best
    }
    let conf = emitted > 0 ? probSum / Double(emitted) : 0
    return (sb.trimmingCharacters(in: .whitespaces), conf)
  }

  // MARK: - Helpers

  private func renderPage(_ page: PDFPage, width: CGFloat, height: CGFloat) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    let info = CGImageAlphaInfo.premultipliedLast.rawValue
    guard width > 0, height > 0,
          let ctx = CGContext(data: nil, width: Int(width), height: Int(height),
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info) else { return nil }
    ctx.setFillColor(UIColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let b = page.bounds(for: .mediaBox)
    ctx.scaleBy(x: width / b.width, y: height / b.height)
    ctx.translateBy(x: -b.origin.x, y: -b.origin.y)
    // Draw directly: the bitmap CGContext already shares PDFPage.draw's
    // bottom-left origin. An extra y-flip here double-flips the page (renders it
    // upside-down AND glyph-mirrored), which fed the recognizer garbage — the
    // real "totally broken output" bug, caught by running this exact code on the
    // Mac. (Verified: with the flip → ~0% word accuracy; without → 92%, then 99%
    // with the detectBoxes unclip above.)
    page.draw(with: .mediaBox, to: ctx)
    return ctx.makeImage()
  }

  /// CGImage → NCHW float tensor (RGB), normalized `(p/255 - mean)/std`.
  private func imageToTensor(_ cg: CGImage, _ w: Int, _ h: Int, mean: [Float], std: [Float]) -> [Float]? {
    let bpr = w * 4
    var buf = [UInt8](repeating: 0, count: h * bpr)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: bpr, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    let plane = w * h
    var out = [Float](repeating: 0, count: 3 * plane)
    for y in 0..<h {
      for x in 0..<w {
        let p = y * bpr + x * 4
        let idx = y * w + x
        out[idx]             = (Float(buf[p])   / 255 - mean[0]) / std[0]
        out[plane + idx]     = (Float(buf[p+1]) / 255 - mean[1]) / std[1]
        out[2 * plane + idx] = (Float(buf[p+2]) / 255 - mean[2]) / std[2]
      }
    }
    return out
  }

  /// Run a single-input/single-output float model.
  private func run(_ session: ORTSession, _ data: [Float], _ shape: [Int]) throws -> ([Float], [Int]) {
    let inName = try session.inputNames().first ?? "x"
    let outName = try session.outputNames().first ?? "out"
    let nsdata = NSMutableData(bytes: data, length: data.count * MemoryLayout<Float>.size)
    let tensor = try ORTValue(tensorData: nsdata, elementType: ORTTensorElementDataType.float,
                              shape: shape.map { NSNumber(value: $0) })
    let outputs = try session.run(withInputs: [inName: tensor], outputNames: [outName], runOptions: nil)
    guard let val = outputs[outName] else { return ([], []) }
    let info = try val.tensorTypeAndShapeInfo()
    let outShape = info.shape.map { $0.intValue }
    let raw = try val.tensorData() as Data
    var floats = [Float](repeating: 0, count: raw.count / MemoryLayout<Float>.size)
    _ = floats.withUnsafeMutableBytes { raw.copyBytes(to: $0) }
    return (floats, outShape)
  }
}
