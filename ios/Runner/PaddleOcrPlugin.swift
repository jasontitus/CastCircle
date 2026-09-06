#if canImport(FlutterMacOS)
import FlutterMacOS
import AppKit
#else
import Flutter
import UIKit
#endif
import PDFKit
import ImageIO
import CoreGraphics
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
  private struct ModelSession {
    let session: ORTSession
    let inputName: String
    let outputName: String
  }

  private struct RecognitionCrop {
    let index: Int
    let box: CGRect
    let image: CGImage
    let width: Int
  }

  private enum PipelineError: LocalizedError {
    case imagePreprocessing
    case invalidDetectorOutput
    case invalidRecognizerOutput
    case missingModelOutput

    var errorDescription: String? {
      switch self {
      case .imagePreprocessing:
        return "Could not prepare the image for OCR"
      case .invalidDetectorOutput:
        return "The OCR detector returned an invalid tensor"
      case .invalidRecognizerOutput:
        return "The OCR recognizer returned an invalid tensor"
      case .missingModelOutput:
        return "The OCR model did not return its configured output"
      }
    }
  }

  private let channel: FlutterMethodChannel
  private let inferenceQueue = DispatchQueue(label: "com.lineguide.paddle_ocr.inference",
                                             qos: .userInitiated)
  private var env: ORTEnv?
  private var detModel: ModelSession?
  private var recModel: ModelSession?
  private var keys: [String] = []
  private var ready = false
  private var modelLoadFailure = "PaddleOCR models not loaded"
  private let requestLock = NSLock()
  private var liveRequestIds = Set<String>()
  private var cancelledRequestIds = Set<String>()

  // Detection / recognition constants (PP-OCR defaults).
  private let detLimitSide = 960
  private let detThresh: Float = 0.3        // binarize the probability map
  private let detMinBoxArea = 16            // drop specks (in det-map pixels)
  // DBNet "unclip" box expansion. A larger ratio over-expands boxes and MERGES
  // adjacent text lines (garble); a too-small ratio clips trailing punctuation.
  // A 9-scan corpus sweep AND a full-document low-OCR debug of the real P&P
  // copier scan (both Mac-verified) land on the 0.4–0.6 safe band. 0.4 is the
  // corpus-wide optimum and, on tightly-leaded pages, recovers ~13 more lines
  // than 0.6 (page 14: 13→2 low-OCR lines) while staying clear of the ~0.2
  // punctuation-clipping threshold.
  private let detUnclipRatio: Float = 0.4
  // Auto render scale: rasterize so the page long side ≈ this many px — the
  // recognition sweet spot (detection caps at 960 anyway, so scale only feeds
  // the rec crops). Adapts per page so small-page / low-DPI PDFs still get
  // enough resolution. Mac-validated across the corpus.
  private let targetRenderLongPx: CGFloat = 1800
  private let maxRenderLongPx: CGFloat = 4096
  private let recHeight = 48
  private let recMaxWidth = 1024
  private let recWidthBucket = 32
  private let recBatchSize = 2
  private let detMean: [Float] = [0.485, 0.456, 0.406]
  private let detStd: [Float] = [0.229, 0.224, 0.225]

  init(registrar: FlutterPluginRegistrar, messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.lineguide/paddle_ocr", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler(handle)
    inferenceQueue.async { [weak self] in
      self?.loadModels(registrar: registrar)
    }
  }

  // MARK: - Model loading

  private func assetPath(_ registrar: FlutterPluginRegistrar, _ asset: String) -> String? {
    let key = registrar.lookupKey(forAsset: asset)
    let fm = FileManager.default
    // iOS: the key is relative to the main bundle's resources.
    if let p = Bundle.main.path(forResource: key, ofType: nil),
       fm.fileExists(atPath: p) { return p }
    // macOS: lookupKey returns a path RELATIVE TO Bundle.main.bundlePath, e.g.
    // "Contents/Frameworks/App.framework/Resources/flutter_assets/...". The
    // slashes defeat `pathForResource:`, so just join it onto the bundle path.
    let joined = (Bundle.main.bundlePath as NSString).appendingPathComponent(key)
    if fm.fileExists(atPath: joined) { return joined }
    // Last resort: scan loaded bundles/frameworks for the (possibly relative)
    // key under each bundle path or resourcePath.
    var candidates = [Bundle]()
    if let app = Bundle(identifier: "io.flutter.flutter.app") { candidates.append(app) }
    candidates += Bundle.allFrameworks + Bundle.allBundles
    for b in candidates {
      for base in [b.bundlePath, b.resourcePath].compactMap({ $0 }) {
        let full = (base as NSString).appendingPathComponent(key)
        if fm.fileExists(atPath: full) { return full }
      }
      if let p = b.path(forResource: key, ofType: nil), fm.fileExists(atPath: p) { return p }
    }
    return nil
  }

  private func loadModels(registrar: FlutterPluginRegistrar) {
    guard let detPath = assetPath(registrar, "assets/paddle_ocr/det.onnx"),
          let recPath = assetPath(registrar, "assets/paddle_ocr/rec.onnx"),
          let keysPath = assetPath(registrar, "assets/paddle_ocr/keys.txt") else {
      modelLoadFailure = "PaddleOCR model assets not found"
      NSLog("PaddleOCR: model assets not found — falling back to ML Kit")
      return
    }
    do {
      let t0 = Date()
      let environment = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
      env = environment
      let opts = try ORTSessionOptions()
      // Thread config. Passing 0 through the onnxruntime-objc wrapper silently
      // yields a SINGLE intra-op thread (~30x slowdown — hit iOS imports too).
      // Set it explicitly to the PHYSICAL performance cores, capped: this is a
      // small model, so more threads add sync overhead, and we run two sessions
      // (det+rec), so all-logical-cores oversubscribes and thrashes. Also
      // disable intra-op spinning so the idle session's threads don't burn CPU
      // (which thermally throttled the whole chip and slowed it mid-run).
      var perfCores = 0
      var sz = MemoryLayout<Int>.size
      if sysctlbyname("hw.perflevel0.physicalcpu", &perfCores, &sz, nil, 0) != 0 || perfCores < 1 {
        perfCores = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
      }
      let threads = Int32(max(2, min(perfCores, 8)))
      try opts.setIntraOpNumThreads(threads)
      try opts.addConfigEntry(withKey: "session.intra_op.allow_spinning", value: "0")
      try opts.setGraphOptimizationLevel(.all)

      let detSession = try ORTSession(env: environment, modelPath: detPath, sessionOptions: opts)
      let recSession = try ORTSession(env: environment, modelPath: recPath, sessionOptions: opts)
      guard let detInputName = try detSession.inputNames().first,
            let detOutputName = try detSession.outputNames().first,
            let recInputName = try recSession.inputNames().first,
            let recOutputName = try recSession.outputNames().first else {
        throw PipelineError.missingModelOutput
      }
      detModel = ModelSession(session: detSession,
                              inputName: detInputName,
                              outputName: detOutputName)
      recModel = ModelSession(session: recSession,
                              inputName: recInputName,
                              outputName: recOutputName)

      let raw = try String(contentsOfFile: keysPath, encoding: .utf8)
      keys = raw.components(separatedBy: "\n")
      while let last = keys.last, last.isEmpty { keys.removeLast() }
      ready = true
      NSLog("PaddleOCR: models loaded in \(Int(Date().timeIntervalSince(t0)*1000))ms — \(keys.count) keys")
    } catch {
      modelLoadFailure = "PaddleOCR model load failed: \(error.localizedDescription)"
      NSLog("PaddleOCR: model load failed: \(error) — falling back to ML Kit")
    }
  }

  // MARK: - Channel

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "recognizeText":
      guard let path = (call.arguments as? [String: Any])?["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing 'path'", details: nil)); return
      }
      inferenceQueue.async {
        guard self.ensureReady(result) else { return }
        guard let image = self.loadCGImage(path) else {
          self.finishError(result, code: "IMAGE_OPEN_FAILED", message: "Could not open image")
          return
        }
        do {
          let blocks = try self.ocrImage(image)
          DispatchQueue.main.async { result(["blocks": blocks]) }
        } catch {
          self.finishError(result, code: "OCR_FAILED",
                           message: "PaddleOCR inference failed", error: error)
        }
      }
    case "ocrPdfPage":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            let pageNumber = args["page"] as? Int else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing 'path'/'page'", details: nil)); return
      }
      ocrPdfPage(path: path, pageNumber: pageNumber, result: result)
    case "ocrPdf":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            let requestId = args["requestId"] as? String,
            !requestId.isEmpty else {
        result(FlutterError(code: "INVALID_ARGS",
                            message: "Missing 'path'/'requestId'", details: nil))
        return
      }
      let scale = args["scale"] as? Double ?? 2.0
      guard registerOcrRequest(requestId) else {
        result(FlutterError(code: "DUPLICATE_REQUEST",
                            message: "OCR request is already active", details: requestId))
        return
      }
      ocrPdf(path: path, scale: scale, requestId: requestId, result: result)
    case "cancelOcrPdf":
      guard let args = call.arguments as? [String: Any],
            let requestId = args["requestId"] as? String,
            !requestId.isEmpty else {
        result(FlutterError(code: "INVALID_ARGS",
                            message: "Missing 'requestId'", details: nil))
        return
      }
      result(cancelOcrRequest(requestId))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func ensureReady(_ result: @escaping FlutterResult) -> Bool {
    guard ready else {
      finishError(result, code: "NOT_READY", message: modelLoadFailure)
      return false
    }
    return true
  }

  private func registerOcrRequest(_ requestId: String) -> Bool {
    requestLock.lock()
    defer { requestLock.unlock() }
    return liveRequestIds.insert(requestId).inserted
  }

  private func cancelOcrRequest(_ requestId: String) -> Bool {
    requestLock.lock()
    defer { requestLock.unlock() }
    guard liveRequestIds.contains(requestId) else { return false }
    cancelledRequestIds.insert(requestId)
    return true
  }

  private func isOcrRequestCancelled(_ requestId: String) -> Bool {
    requestLock.lock()
    defer { requestLock.unlock() }
    return cancelledRequestIds.contains(requestId)
  }

  private func finishOcrRequest(_ requestId: String, result: @escaping FlutterResult,
                                value: [String: Any]? = nil,
                                error: FlutterError? = nil) {
    DispatchQueue.main.async {
      self.requestLock.lock()
      let isLive = self.liveRequestIds.contains(requestId)
      let wasCancelled = self.cancelledRequestIds.contains(requestId)
      self.requestLock.unlock()
      guard isLive else { return }

      if wasCancelled {
        result(FlutterError(code: "ocr_cancelled",
                            message: "OCR request cancelled", details: requestId))
      } else if let error {
        result(error)
      } else {
        result(value)
      }

      // Keep the request visible through all earlier page callbacks and the
      // FlutterResult invocation. A cancellation acknowledged before this
      // main-queue block therefore suppresses queued payloads and wins over
      // success; a later cancellation correctly reports that no live job exists.
      self.requestLock.lock()
      self.liveRequestIds.remove(requestId)
      self.cancelledRequestIds.remove(requestId)
      self.requestLock.unlock()
    }
  }

  private func finishOcrCancellation(_ requestId: String,
                                     result: @escaping FlutterResult) {
    finishOcrRequest(
      requestId,
      result: result,
      error: FlutterError(code: "ocr_cancelled",
                          message: "OCR request cancelled", details: requestId))
  }

  private func emitOcrPage(_ requestId: String, pageIndex: Int,
                           lines: [[String: Any]]) {
    DispatchQueue.main.async {
      self.requestLock.lock()
      let shouldEmit = self.liveRequestIds.contains(requestId)
        && !self.cancelledRequestIds.contains(requestId)
      self.requestLock.unlock()
      guard shouldEmit else { return }
      self.channel.invokeMethod(
        "ocrPage",
        arguments: ["requestId": requestId, "pageIndex": pageIndex, "lines": lines])
    }
  }

  private func emitOcrProgress(_ requestId: String, page: Int, pageCount: Int) {
    DispatchQueue.main.async {
      self.requestLock.lock()
      let shouldEmit = self.liveRequestIds.contains(requestId)
        && !self.cancelledRequestIds.contains(requestId)
      self.requestLock.unlock()
      guard shouldEmit else { return }
      self.channel.invokeMethod(
        "ocrProgress",
        arguments: ["requestId": requestId, "page": page, "pageCount": pageCount])
    }
  }

  private func finishError(_ result: @escaping FlutterResult, code: String,
                           message: String, error: Error? = nil) {
    let details = error.map { String(describing: $0) }
    DispatchQueue.main.async {
      result(FlutterError(code: code, message: message, details: details))
    }
  }

  private func renderScale(for bounds: CGRect, requestedScale: CGFloat) -> CGFloat? {
    let longPt = max(bounds.width, bounds.height)
    guard bounds.width.isFinite, bounds.height.isFinite,
          bounds.width > 0, bounds.height > 0, longPt > 0 else {
      return nil
    }
    let request = requestedScale.isFinite ? requestedScale : 1
    let preferred = min(6, max(1, max(request, targetRenderLongPx / longPt)))
    return min(preferred, maxRenderLongPx / longPt)
  }

  private func ocrPdf(path: String, scale: Double, requestId: String,
                      result: @escaping FlutterResult) {
    inferenceQueue.async {
      guard self.ready else {
        self.finishOcrRequest(
          requestId,
          result: result,
          error: FlutterError(code: "NOT_READY", message: self.modelLoadFailure, details: nil))
        return
      }
      if self.isOcrRequestCancelled(requestId) {
        self.finishOcrCancellation(requestId, result: result)
        return
      }
      guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
        self.finishOcrRequest(
          requestId,
          result: result,
          error: FlutterError(code: "PDF_OPEN_FAILED", message: "Could not open PDF", details: nil))
        return
      }
      let pageCount = doc.pageCount
      var failed = 0
      let jobStart = Date()
      for i in 0..<pageCount {
        if self.isOcrRequestCancelled(requestId) {
          self.finishOcrCancellation(requestId, result: result)
          return
        }
        var pageLines: [[String: Any]]?
        var inferenceFailure: Error?
        autoreleasepool {
          guard let page = doc.page(at: i) else {
            failed += 1
            return
          }
          let bounds = page.bounds(for: .mediaBox)
          guard let renderScale = self.renderScale(for: bounds,
                                                   requestedScale: CGFloat(scale)),
                let image = self.renderPage(page,
                                            width: bounds.width * renderScale,
                                            height: bounds.height * renderScale) else {
            failed += 1
            return
          }
          let t0 = Date()
          do {
            let lines = try self.ocrImage(image)
            pageLines = lines
            NSLog("PaddleOCR: page \(i+1)/\(pageCount) — \(lines.count) lines in \(Int(Date().timeIntervalSince(t0)*1000))ms")
          } catch {
            inferenceFailure = error
            NSLog("PaddleOCR: page \(i+1)/\(pageCount) inference failed: \(error)")
          }
        }
        if self.isOcrRequestCancelled(requestId) {
          self.finishOcrCancellation(requestId, result: result)
          return
        }
        if let pageLines {
          self.emitOcrPage(requestId, pageIndex: i + 1, lines: pageLines)
        }
        self.emitOcrProgress(requestId, page: i + 1, pageCount: pageCount)
        if let inferenceFailure {
          self.finishOcrRequest(
            requestId,
            result: result,
            error: FlutterError(code: "OCR_FAILED",
                                message: "PaddleOCR inference failed on page \(i + 1)",
                                details: String(describing: inferenceFailure)))
          return
        }
      }
      let total = Date().timeIntervalSince(jobStart)
      NSLog("PaddleOCR: \(pageCount) pages in \(String(format: "%.1f", total))s (\(String(format: "%.2f", total/Double(max(pageCount,1)))) s/page)")
      self.finishOcrRequest(
        requestId,
        result: result,
        value: ["pageCount": pageCount, "failedPages": failed])
    }
  }

  /// OCR a single 1-based page and return its lines WITH full normalized
  /// rects — used by the page viewer to highlight where a flagged line's
  /// text sits on the scanned page.
  private func ocrPdfPage(path: String, pageNumber: Int, result: @escaping FlutterResult) {
    inferenceQueue.async {
      guard self.ensureReady(result) else { return }
      guard let doc = PDFDocument(url: URL(fileURLWithPath: path)),
            pageNumber >= 1, pageNumber <= doc.pageCount,
            let page = doc.page(at: pageNumber - 1) else {
        self.finishError(result, code: "PDF_PAGE_FAILED",
                         message: "Could not open page \(pageNumber)")
        return
      }
      let bounds = page.bounds(for: .mediaBox)
      guard let renderScale = self.renderScale(for: bounds, requestedScale: 1),
            let image = self.renderPage(page,
                                        width: bounds.width * renderScale,
                                        height: bounds.height * renderScale) else {
        self.finishError(result, code: "PDF_PAGE_FAILED",
                         message: "Could not render page \(pageNumber)")
        return
      }
      do {
        let lines = try self.ocrImage(image)
        DispatchQueue.main.async { result(["lines": lines]) }
      } catch {
        self.finishError(result, code: "OCR_FAILED",
                         message: "PaddleOCR inference failed for page \(pageNumber)",
                         error: error)
      }
    }
  }

  // MARK: - PP-OCR pipeline

  private func ocrImage(_ cg: CGImage) throws -> [[String: Any]] {
    guard let det = detModel, let rec = recModel else {
      throw PipelineError.missingModelOutput
    }
    let origW = cg.width, origH = cg.height
    // 1. Detection: resize to multiples of 32 (≤ limit), normalize, run.
    let ratio = min(Float(detLimitSide) / Float(max(origW, origH)), 1.0)
    let newW = max(32, Int((Float(origW) * ratio / 32).rounded()) * 32)
    let newH = max(32, Int((Float(origH) * ratio / 32).rounded()) * 32)
    guard let detIn = imageToTensor(cg, newW, newH, mean: detMean, std: detStd) else {
      throw PipelineError.imagePreprocessing
    }
    let (prob, pShape) = try run(det, detIn, [1, 3, newH, newW])
    guard pShape.count >= 2 else { throw PipelineError.invalidDetectorOutput }
    let mH = pShape[pShape.count - 2], mW = pShape[pShape.count - 1]
    guard mW > 0, mH > 0, prob.count >= mW * mH else {
      throw PipelineError.invalidDetectorOutput
    }
    // 2. Threshold + connected-component boxes, mapped back to original coords.
    let boxes = detectBoxes(prob, mW: mW, mH: mH, origW: origW, origH: origH)
      .sorted(by: { $0.minY < $1.minY })

    // 3. Recognition accepts dynamic batch and width dimensions. Bucket line
    // widths, right-pad with normalized white, and cap each run at two crops:
    // the recognizer's large class output otherwise makes a page-sized batch
    // hundreds of megabytes even when its input looks modest.
    var cropsByPaddedWidth: [Int: [RecognitionCrop]] = [:]
    var cropIndex = 0
    for box in boxes {
      guard let crop = cg.cropping(to: box), crop.height > 0 else { continue }
      var width = Int((Float(recHeight) * Float(crop.width) / Float(crop.height)).rounded())
      width = max(16, min(width, recMaxWidth))
      let paddedWidth = min(
        recMaxWidth,
        ((width + recWidthBucket - 1) / recWidthBucket) * recWidthBucket)
      cropsByPaddedWidth[paddedWidth, default: []].append(
        RecognitionCrop(index: cropIndex, box: box, image: crop, width: width))
      cropIndex += 1
    }

    var recognized = [(box: CGRect, text: String, confidence: Double)?](
      repeating: nil, count: cropIndex)
    for (paddedWidth, crops) in cropsByPaddedWidth {
      for start in stride(from: 0, to: crops.count, by: recBatchSize) {
        let batch = crops[start..<min(start + recBatchSize, crops.count)]
        let values = try recognize(batch, paddedWidth: paddedWidth, using: rec)
        for (crop, value) in zip(batch, values) {
          recognized[crop.index] = (crop.box, value.0, value.1)
        }
      }
    }

    let fOrigW = Double(max(origW, 1))
    let fOrigH = Double(max(origH, 1))
    return recognized.compactMap { line in
      guard let line, !line.text.isEmpty else { return nil }
      return [
        "text": line.text, "confidence": line.confidence,
        "left": Double(line.box.minX) / fOrigW,
        "width": Double(line.box.width) / fOrigW,
        "top": Double(line.box.minY) / fOrigH,
        "height": Double(line.box.height) / fOrigH,
      ]
    }
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

  /// Recognize a bounded batch of bucketed text-line crops.
  private func recognize(_ crops: ArraySlice<RecognitionCrop>, paddedWidth: Int,
                         using rec: ModelSession) throws -> [(String, Double)] {
    guard !crops.isEmpty else { return [] }
    let mean: [Float] = [0.5, 0.5, 0.5]
    let std: [Float] = [0.5, 0.5, 0.5]
    let paddedPlane = recHeight * paddedWidth
    // Normalized white is 1 for mean/std 0.5. Each resized crop occupies the
    // left side of its bucket and the rest remains white padding.
    var input = [Float](repeating: 1, count: crops.count * 3 * paddedPlane)
    for (batchIndex, crop) in crops.enumerated() {
      guard let tensor = imageToTensor(crop.image, crop.width, recHeight,
                                       mean: mean, std: std) else {
        throw PipelineError.imagePreprocessing
      }
      let sourcePlane = recHeight * crop.width
      input.withUnsafeMutableBufferPointer { destination in
        tensor.withUnsafeBufferPointer { source in
          guard let destinationBase = destination.baseAddress,
                let sourceBase = source.baseAddress else { return }
          for channel in 0..<3 {
            for row in 0..<recHeight {
              let destinationOffset = batchIndex * 3 * paddedPlane
                + channel * paddedPlane + row * paddedWidth
              let sourceOffset = channel * sourcePlane + row * crop.width
              destinationBase.advanced(by: destinationOffset).update(
                from: sourceBase.advanced(by: sourceOffset),
                count: crop.width)
            }
          }
        }
      }
    }

    let (output, shape) = try run(
      rec, input, [crops.count, 3, recHeight, paddedWidth])
    guard shape.count == 3, shape[0] == crops.count,
          shape[1] > 0, shape[2] > 0,
          output.count >= shape[0] * shape[1] * shape[2] else {
      throw PipelineError.invalidRecognizerOutput
    }
    let timeSteps = shape[1], classes = shape[2]
    return (0..<crops.count).map { batch in
      var text = ""
      var probabilitySum: Double = 0
      var emitted = 0
      var previous = -1
      for time in 0..<timeSteps {
        var best = 0
        var bestProbability: Float = -1
        let base = (batch * timeSteps + time) * classes
        for candidate in 0..<classes {
          let probability = output[base + candidate]
          if probability > bestProbability {
            bestProbability = probability
            best = candidate
          }
        }
        if best != 0 && best != previous {
          let keyIndex = best - 1
          text += keyIndex >= 0 && keyIndex < keys.count ? keys[keyIndex] : " "
          probabilitySum += Double(bestProbability)
          emitted += 1
        }
        previous = best
      }
      let confidence = emitted > 0 ? probabilitySum / Double(emitted) : 0
      return (text.trimmingCharacters(in: .whitespaces), confidence)
    }
  }

  // MARK: - Helpers

  /// Load a CGImage from a file path via ImageIO — works on both iOS and macOS
  /// (UIImage/NSImage are platform-specific; ImageIO is shared).
  private func loadCGImage(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
  }

  private func renderPage(_ page: PDFPage, width: CGFloat, height: CGFloat) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    let info = CGImageAlphaInfo.premultipliedLast.rawValue
    guard width > 0, height > 0,
          let ctx = CGContext(data: nil, width: Int(width), height: Int(height),
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
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
  private func imageToTensor(_ cg: CGImage, _ w: Int, _ h: Int,
                             mean: [Float], std: [Float]) -> [Float]? {
    let bytesPerRow = w * 4
    var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let plane = w * h
    var output = [Float](repeating: 0, count: 3 * plane)
    let converted = pixels.withUnsafeMutableBytes { bytes -> Bool in
      guard let baseAddress = bytes.baseAddress,
            let context = CGContext(data: baseAddress, width: w, height: h,
                                    bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                    space: colorSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return false
      }
      context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
      for y in 0..<h {
        for x in 0..<w {
          let pixel = y * bytesPerRow + x * 4
          let index = y * w + x
          output[index] = (Float(bytes[pixel]) / 255 - mean[0]) / std[0]
          output[plane + index] = (Float(bytes[pixel + 1]) / 255 - mean[1]) / std[1]
          output[2 * plane + index] = (Float(bytes[pixel + 2]) / 255 - mean[2]) / std[2]
        }
      }
      return true
    }
    return converted ? output : nil
  }

  /// Run a cached single-input/single-output float model.
  private func run(_ model: ModelSession, _ data: [Float],
                   _ shape: [Int]) throws -> ([Float], [Int]) {
    let nsdata = NSMutableData(bytes: data, length: data.count * MemoryLayout<Float>.size)
    let tensor = try ORTValue(tensorData: nsdata, elementType: ORTTensorElementDataType.float,
                              shape: shape.map { NSNumber(value: $0) })
    let outputs = try model.session.run(withInputs: [model.inputName: tensor],
                                        outputNames: [model.outputName],
                                        runOptions: nil)
    guard let value = outputs[model.outputName] else {
      throw PipelineError.missingModelOutput
    }
    let info = try value.tensorTypeAndShapeInfo()
    let outputShape = info.shape.map { $0.intValue }
    let raw = try value.tensorData() as Data
    var floats = [Float](repeating: 0, count: raw.count / MemoryLayout<Float>.size)
    _ = floats.withUnsafeMutableBytes { raw.copyBytes(to: $0) }
    return (floats, outputShape)
  }
}
