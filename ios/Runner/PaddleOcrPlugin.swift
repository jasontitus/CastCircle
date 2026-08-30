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
/// Model creation and every inference run are owned by [ocrQueue]. Plugin
/// registration only records Flutter asset keys, so engine startup never pays
/// the cost of constructing the two ORT sessions.
class PaddleOcrPlugin: NSObject {
  private let channel: FlutterMethodChannel
  private let ocrQueue = DispatchQueue(label: "com.lineguide.paddle-ocr", qos: .userInitiated)
  private let assetKeys: (det: String, rec: String, keys: String)

  // Accessed only on ocrQueue.
  private var env: ORTEnv?
  private var detSession: ORTSession?
  private var recSession: ORTSession?
  private var keys: [String] = []
  private var modelLoadFailure: PaddleOCRError?

  private let detLimitSide = 960
  private let detThresh: Float = 0.3
  private let detMinBoxArea = 16
  private let detUnclipRatio: Float = 0.4
  private let targetRenderLongPx: CGFloat = 1800
  private let recHeight = 48
  private let recMaxWidth = 1024
  private let detMean: [Float] = [0.485, 0.456, 0.406]
  private let detStd: [Float] = [0.229, 0.224, 0.225]

  init(registrar: FlutterPluginRegistrar, messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.lineguide/paddle_ocr", binaryMessenger: messenger)
    assetKeys = (
      registrar.lookupKey(forAsset: "assets/paddle_ocr/det.onnx"),
      registrar.lookupKey(forAsset: "assets/paddle_ocr/rec.onnx"),
      registrar.lookupKey(forAsset: "assets/paddle_ocr/keys.txt")
    )
    super.init()
    channel.setMethodCallHandler(handle)
  }

  // MARK: - Model loading

  private func assetPath(for key: String) -> String? {
    let fm = FileManager.default
    if let path = Bundle.main.path(forResource: key, ofType: nil),
       fm.fileExists(atPath: path) {
      return path
    }
    let joined = (Bundle.main.bundlePath as NSString).appendingPathComponent(key)
    if fm.fileExists(atPath: joined) { return joined }

    var candidates = [Bundle]()
    if let app = Bundle(identifier: "io.flutter.flutter.app") { candidates.append(app) }
    candidates += Bundle.allFrameworks + Bundle.allBundles
    for bundle in candidates {
      for base in [bundle.bundlePath, bundle.resourcePath].compactMap({ $0 }) {
        let full = (base as NSString).appendingPathComponent(key)
        if fm.fileExists(atPath: full) { return full }
      }
      if let path = bundle.path(forResource: key, ofType: nil),
         fm.fileExists(atPath: path) {
        return path
      }
    }
    return nil
  }

  /// Called only by the serial OCR queue. The first request performs one load;
  /// concurrent first callers queue behind it and observe the same success or
  /// stored typed failure.
  private func ensureModelsLoaded() throws {
    if detSession != nil, recSession != nil { return }
    if let modelLoadFailure = modelLoadFailure { throw modelLoadFailure }

    do {
      guard let detPath = assetPath(for: assetKeys.det),
            let recPath = assetPath(for: assetKeys.rec),
            let keysPath = assetPath(for: assetKeys.keys) else {
        throw PaddleOCRError.modelAssetsMissing
      }

      let started = Date()
      let loadedEnv = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
      let options = try ORTSessionOptions()
      var performanceCores = 0
      var size = MemoryLayout<Int>.size
      if sysctlbyname("hw.perflevel0.physicalcpu", &performanceCores, &size, nil, 0) != 0
          || performanceCores < 1 {
        performanceCores = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
      }
      let threads = Int32(max(2, min(performanceCores, 8)))
      try options.setIntraOpNumThreads(threads)
      try options.addConfigEntry(withKey: "session.intra_op.allow_spinning", value: "0")
      try options.setGraphOptimizationLevel(.all)

      let loadedDet = try ORTSession(env: loadedEnv, modelPath: detPath, sessionOptions: options)
      let loadedRec = try ORTSession(env: loadedEnv, modelPath: recPath, sessionOptions: options)
      try validateMetadata(loadedDet, stage: "detection")
      try validateMetadata(loadedRec, stage: "recognition")

      let rawKeys = try String(contentsOfFile: keysPath, encoding: .utf8)
      var loadedKeys = rawKeys.components(separatedBy: "\n")
      while loadedKeys.last?.isEmpty == true { loadedKeys.removeLast() }
      guard !loadedKeys.isEmpty else {
        throw PaddleOCRError.invalidModelMetadata(stage: "recognition", reason: "dictionary is empty")
      }

      env = loadedEnv
      detSession = loadedDet
      recSession = loadedRec
      keys = loadedKeys
      NSLog("PaddleOCR: models loaded lazily in \(Int(Date().timeIntervalSince(started) * 1000))ms — \(keys.count) keys")
    } catch let error as PaddleOCRError {
      modelLoadFailure = error
      throw error
    } catch {
      let wrapped = PaddleOCRError.modelLoadFailed(error.localizedDescription)
      modelLoadFailure = wrapped
      throw wrapped
    }
  }

  private func validateMetadata(_ session: ORTSession, stage: String) throws {
    let inputNames = try session.inputNames()
    guard inputNames.count == 1, let input = inputNames.first, !input.isEmpty else {
      throw PaddleOCRError.invalidModelMetadata(
        stage: stage,
        reason: "expected one named input, found \(inputNames.count)"
      )
    }
    let outputNames = try session.outputNames()
    guard outputNames.count == 1, let output = outputNames.first, !output.isEmpty else {
      throw PaddleOCRError.invalidModelMetadata(
        stage: stage,
        reason: "expected one named output, found \(outputNames.count)"
      )
    }
  }

  // MARK: - Channel

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "recognizeText":
      guard let path = (call.arguments as? [String: Any])?["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing 'path'", details: nil))
        return
      }
      perform(result: result) {
        guard let image = self.loadCGImage(path) else {
          throw PaddleOCRError.imageDecodeFailed(path)
        }
        return ["blocks": try self.ocrImage(image)]
      }

    case "ocrPdfPage":
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String,
            let pageNumber = arguments["page"] as? Int else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing 'path'/'page'", details: nil))
        return
      }
      perform(result: result) {
        ["lines": try self.ocrPdfPage(path: path, pageNumber: pageNumber)]
      }

    case "ocrPdf":
      guard let path = (call.arguments as? [String: Any])?["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing 'path'", details: nil))
        return
      }
      let scale = (call.arguments as? [String: Any])?["scale"] as? Double ?? 2.0
      perform(result: result) {
        try self.ocrPdf(path: path, scale: scale)
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func perform(result: @escaping FlutterResult, operation: @escaping () throws -> Any) {
    ocrQueue.async {
      do {
        try self.ensureModelsLoaded()
        let value = try operation()
        DispatchQueue.main.async { result(value) }
      } catch {
        self.complete(error: error, result: result)
      }
    }
  }

  private func complete(error: Error, result: @escaping FlutterResult) {
    let typed = error as? PaddleOCRError
      ?? PaddleOCRError.inferenceFailed(stage: "OCR", reason: error.localizedDescription)
    NSLog("PaddleOCR: \(typed.localizedDescription)")
    DispatchQueue.main.async {
      result(FlutterError(code: typed.code, message: typed.localizedDescription, details: typed.details))
    }
  }

  // MARK: - PDF

  private func ocrPdf(path: String, scale: Double) throws -> [String: Any] {
    guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
      throw PaddleOCRError.pdfOpenFailed(path)
    }
    let pageCount = document.pageCount
    var pages: [[String: Any]] = []
    pages.reserveCapacity(pageCount)
    let jobStart = Date()

    for index in 0..<pageCount {
      let pageNumber = index + 1
      DispatchQueue.main.async {
        self.channel.invokeMethod(
          "ocrProgress",
          arguments: ["page": pageNumber, "pageCount": pageCount]
        )
      }
      do {
        guard let page = document.page(at: index) else {
          throw PaddleOCRError.pdfPageUnavailable(pageNumber)
        }
        let bounds = page.bounds(for: .mediaBox)
        let longPoints = max(bounds.width, bounds.height)
        guard longPoints > 0 else { throw PaddleOCRError.pdfRenderFailed(pageNumber) }
        let autoScale = min(6.0, max(1.0, max(scale, targetRenderLongPx / longPoints)))
        guard let image = renderPage(
          page,
          width: bounds.width * autoScale,
          height: bounds.height * autoScale
        ) else {
          throw PaddleOCRError.pdfRenderFailed(pageNumber)
        }
        let started = Date()
        let lines = try ocrImage(image)
        pages.append(["page": pageNumber, "lines": lines])
        NSLog("PaddleOCR: page \(pageNumber)/\(pageCount) — \(lines.count) lines in \(Int(Date().timeIntervalSince(started) * 1000))ms")
      } catch let error as PaddleOCRError {
        throw PaddleOCRError.pageFailed(page: pageNumber, reason: error.localizedDescription)
      } catch {
        throw PaddleOCRError.pageFailed(page: pageNumber, reason: error.localizedDescription)
      }
    }

    let total = Date().timeIntervalSince(jobStart)
    NSLog("PaddleOCR: \(pageCount) pages in \(String(format: "%.1f", total))s")
    return ["pages": pages, "pageCount": pageCount, "failedPages": 0]
  }

  private func ocrPdfPage(path: String, pageNumber: Int) throws -> [[String: Any]] {
    guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
      throw PaddleOCRError.pdfOpenFailed(path)
    }
    guard pageNumber >= 1,
          pageNumber <= document.pageCount,
          let page = document.page(at: pageNumber - 1) else {
      throw PaddleOCRError.pdfPageUnavailable(pageNumber)
    }
    let bounds = page.bounds(for: .mediaBox)
    let longPoints = max(bounds.width, bounds.height)
    guard longPoints > 0 else { throw PaddleOCRError.pdfRenderFailed(pageNumber) }
    let autoScale = min(6.0, max(1.0, targetRenderLongPx / longPoints))
    guard let image = renderPage(
      page,
      width: bounds.width * autoScale,
      height: bounds.height * autoScale
    ) else {
      throw PaddleOCRError.pdfRenderFailed(pageNumber)
    }
    do {
      return try ocrImage(image)
    } catch {
      throw PaddleOCRError.pageFailed(page: pageNumber, reason: error.localizedDescription)
    }
  }

  // MARK: - PP-OCR pipeline

  private func ocrImage(_ image: CGImage) throws -> [[String: Any]] {
    guard let detectionSession = detSession, let recognitionSession = recSession else {
      throw PaddleOCRError.modelLoadFailed("sessions are unavailable after loading")
    }
    let originalWidth = image.width
    let originalHeight = image.height
    guard originalWidth > 0, originalHeight > 0 else {
      throw PaddleOCRError.imageConversionFailed("image has zero dimensions")
    }

    let ratio = min(Float(detLimitSide) / Float(max(originalWidth, originalHeight)), 1.0)
    let newWidth = max(32, Int((Float(originalWidth) * ratio / 32).rounded()) * 32)
    let newHeight = max(32, Int((Float(originalHeight) * ratio / 32).rounded()) * 32)
    let detectionInput = try imageToTensor(
      image,
      newWidth,
      newHeight,
      mean: detMean,
      std: detStd
    )
    let (probabilities, probabilityShape) = try run(
      detectionSession,
      detectionInput,
      [1, 3, newHeight, newWidth],
      stage: "detection"
    )
    guard probabilityShape.count >= 2 else {
      throw PaddleOCRError.invalidInferenceOutput(stage: "detection", reason: "rank is \(probabilityShape.count)")
    }
    let mapHeight = probabilityShape[probabilityShape.count - 2]
    let mapWidth = probabilityShape[probabilityShape.count - 1]
    guard mapHeight > 0, mapWidth > 0,
          probabilities.count >= mapHeight * mapWidth else {
      throw PaddleOCRError.invalidInferenceOutput(stage: "detection", reason: "probability map shape/data mismatch")
    }

    let boxes = detectBoxes(
      probabilities,
      mW: mapWidth,
      mH: mapHeight,
      origW: originalWidth,
      origH: originalHeight
    )
    var lines: [[String: Any]] = []
    let width = Double(originalWidth)
    let height = Double(originalHeight)
    for box in boxes.sorted(by: { $0.minY < $1.minY }) {
      guard let crop = image.cropping(to: box) else {
        throw PaddleOCRError.imageConversionFailed("could not crop detected text region")
      }
      let (text, confidence) = try recognize(crop, recognitionSession)
      if !text.isEmpty {
        lines.append([
          "text": text,
          "confidence": confidence,
          "left": Double(box.minX) / width,
          "width": Double(box.width) / width,
          "top": Double(box.minY) / height,
          "height": Double(box.height) / height,
        ])
      }
    }
    return lines
  }

  private func detectBoxes(
    _ probabilities: [Float],
    mW: Int,
    mH: Int,
    origW: Int,
    origH: Int
  ) -> [CGRect] {
    var label = [Int](repeating: 0, count: mW * mH)
    var next = 1
    var minX = [Int](), minY = [Int](), maxX = [Int](), maxY = [Int](), area = [Int]()
    func newComponent() {
      minX.append(Int.max)
      minY.append(Int.max)
      maxX.append(0)
      maxY.append(0)
      area.append(0)
    }
    newComponent()
    var stack = [Int]()
    for sourceY in 0..<mH {
      for sourceX in 0..<mW {
        let source = sourceY * mW + sourceX
        if probabilities[source] <= detThresh || label[source] != 0 { continue }
        newComponent()
        let identifier = next
        next += 1
        stack.removeAll(keepingCapacity: true)
        stack.append(source)
        label[source] = identifier
        while let point = stack.popLast() {
          let x = point % mW
          let y = point / mW
          if x < minX[identifier] { minX[identifier] = x }
          if x > maxX[identifier] { maxX[identifier] = x }
          if y < minY[identifier] { minY[identifier] = y }
          if y > maxY[identifier] { maxY[identifier] = y }
          area[identifier] += 1
          for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
            let neighborX = x + dx
            let neighborY = y + dy
            if neighborX < 0 || neighborY < 0 || neighborX >= mW || neighborY >= mH { continue }
            let neighbor = neighborY * mW + neighborX
            if probabilities[neighbor] > detThresh && label[neighbor] == 0 {
              label[neighbor] = identifier
              stack.append(neighbor)
            }
          }
        }
      }
    }

    let scaleX = CGFloat(origW) / CGFloat(mW)
    let scaleY = CGFloat(origH) / CGFloat(mH)
    var boxes = [CGRect]()
    for identifier in 1..<next where area[identifier] >= detMinBoxArea {
      let boxWidth = maxX[identifier] - minX[identifier] + 1
      let boxHeight = maxY[identifier] - minY[identifier] + 1
      let distance = Int(
        (Float(boxWidth * boxHeight) * detUnclipRatio / Float(2 * (boxWidth + boxHeight))).rounded()
      )
      let minimumX = minX[identifier] - distance
      let minimumY = minY[identifier] - distance
      let maximumX = maxX[identifier] + distance
      let maximumY = maxY[identifier] + distance
      let x0 = CGFloat(max(0, minimumX - 1)) * scaleX
      let y0 = CGFloat(max(0, minimumY - 1)) * scaleY
      let x1 = CGFloat(min(mW, maximumX + 2)) * scaleX
      let y1 = CGFloat(min(mH, maximumY + 2)) * scaleY
      boxes.append(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
    }
    return boxes
  }

  private func recognize(_ crop: CGImage, _ session: ORTSession) throws -> (String, Double) {
    let height = crop.height
    let width = crop.width
    guard height > 0, width > 0 else {
      throw PaddleOCRError.imageConversionFailed("recognition crop has zero dimensions")
    }
    var resizedWidth = Int((Float(recHeight) * Float(width) / Float(height)).rounded())
    resizedWidth = max(16, min(resizedWidth, recMaxWidth))
    let input = try imageToTensor(
      crop,
      resizedWidth,
      recHeight,
      mean: [0.5, 0.5, 0.5],
      std: [0.5, 0.5, 0.5]
    )
    let (output, shape) = try run(
      session,
      input,
      [1, 3, recHeight, resizedWidth],
      stage: "recognition"
    )
    guard shape.count == 3, shape[1] > 0, shape[2] > 0,
          output.count >= shape[1] * shape[2] else {
      throw PaddleOCRError.invalidInferenceOutput(stage: "recognition", reason: "expected nonempty rank-3 output")
    }

    let timeSteps = shape[1]
    let classes = shape[2]
    var string = ""
    var probabilitySum: Double = 0
    var emitted = 0
    var previous = -1
    for time in 0..<timeSteps {
      var best = 0
      var bestProbability: Float = -.infinity
      let base = time * classes
      for character in 0..<classes where output[base + character] > bestProbability {
        bestProbability = output[base + character]
        best = character
      }
      if best != 0 && best != previous {
        let keyIndex = best - 1
        if keys.indices.contains(keyIndex) {
          string += keys[keyIndex]
        } else if keyIndex == keys.count {
          string += " "
        } else {
          throw PaddleOCRError.invalidInferenceOutput(
            stage: "recognition",
            reason: "class \(best) exceeds dictionary"
          )
        }
        probabilitySum += Double(bestProbability)
        emitted += 1
      }
      previous = best
    }
    let confidence = emitted > 0 ? probabilitySum / Double(emitted) : 0
    return (string.trimmingCharacters(in: .whitespaces), confidence)
  }

  // MARK: - Image and ORT helpers

  private func loadCGImage(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
      return nil
    }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  private func renderPage(_ page: PDFPage, width: CGFloat, height: CGFloat) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard width > 0, height > 0,
          let context = CGContext(
            data: nil,
            width: Int(width),
            height: Int(height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
          ) else {
      return nil
    }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let bounds = page.bounds(for: .mediaBox)
    guard bounds.width > 0, bounds.height > 0 else { return nil }
    context.scaleBy(x: width / bounds.width, y: height / bounds.height)
    context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
    page.draw(with: .mediaBox, to: context)
    return context.makeImage()
  }

  private func imageToTensor(
    _ image: CGImage,
    _ width: Int,
    _ height: Int,
    mean: [Float],
    std: [Float]
  ) throws -> [Float] {
    let bytesPerRow = width * 4
    var buffer = [UInt8](repeating: 0, count: height * bytesPerRow)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: &buffer,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw PaddleOCRError.imageConversionFailed("could not allocate bitmap context")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let plane = width * height
    var output = [Float](repeating: 0, count: 3 * plane)
    for y in 0..<height {
      for x in 0..<width {
        let pixel = y * bytesPerRow + x * 4
        let index = y * width + x
        output[index] = (Float(buffer[pixel]) / 255 - mean[0]) / std[0]
        output[plane + index] = (Float(buffer[pixel + 1]) / 255 - mean[1]) / std[1]
        output[2 * plane + index] = (Float(buffer[pixel + 2]) / 255 - mean[2]) / std[2]
      }
    }
    return output
  }

  private func run(
    _ session: ORTSession,
    _ data: [Float],
    _ shape: [Int],
    stage: String
  ) throws -> ([Float], [Int]) {
    do {
      let inputNames = try session.inputNames()
      guard inputNames.count == 1, let inputName = inputNames.first, !inputName.isEmpty else {
        throw PaddleOCRError.invalidModelMetadata(stage: stage, reason: "missing input name")
      }
      let outputNames = try session.outputNames()
      guard outputNames.count == 1, let outputName = outputNames.first, !outputName.isEmpty else {
        throw PaddleOCRError.invalidModelMetadata(stage: stage, reason: "missing output name")
      }

      let bytes = NSMutableData(bytes: data, length: data.count * MemoryLayout<Float>.size)
      let tensor = try ORTValue(
        tensorData: bytes,
        elementType: ORTTensorElementDataType.float,
        shape: shape.map { NSNumber(value: $0) }
      )
      let outputs = try session.run(
        withInputs: [inputName: tensor],
        outputNames: [outputName],
        runOptions: nil
      )
      guard let value = outputs[outputName] else {
        throw PaddleOCRError.invalidInferenceOutput(stage: stage, reason: "named output is absent")
      }
      let info = try value.tensorTypeAndShapeInfo()
      let outputShape = info.shape.map { $0.intValue }
      guard !outputShape.isEmpty, outputShape.allSatisfy({ $0 >= 0 }) else {
        throw PaddleOCRError.invalidInferenceOutput(stage: stage, reason: "invalid runtime shape")
      }
      let raw = try value.tensorData() as Data
      guard raw.count % MemoryLayout<Float>.size == 0 else {
        throw PaddleOCRError.invalidInferenceOutput(stage: stage, reason: "unaligned float output")
      }
      let elementCount = raw.count / MemoryLayout<Float>.size
      let expectedCount = try outputShape.reduce(1) { partial, dimension in
        let (product, overflow) = partial.multipliedReportingOverflow(by: dimension)
        if overflow { throw PaddleOCRError.invalidInferenceOutput(stage: stage, reason: "shape overflow") }
        return product
      }
      guard elementCount == expectedCount else {
        throw PaddleOCRError.invalidInferenceOutput(
          stage: stage,
          reason: "shape expects \(expectedCount) floats, received \(elementCount)"
        )
      }
      var floats = [Float](repeating: 0, count: elementCount)
      _ = floats.withUnsafeMutableBytes { raw.copyBytes(to: $0) }
      return (floats, outputShape)
    } catch let error as PaddleOCRError {
      throw error
    } catch {
      throw PaddleOCRError.inferenceFailed(stage: stage, reason: error.localizedDescription)
    }
  }
}

private enum PaddleOCRError: LocalizedError {
  case modelAssetsMissing
  case modelLoadFailed(String)
  case invalidModelMetadata(stage: String, reason: String)
  case imageDecodeFailed(String)
  case imageConversionFailed(String)
  case pdfOpenFailed(String)
  case pdfPageUnavailable(Int)
  case pdfRenderFailed(Int)
  case pageFailed(page: Int, reason: String)
  case inferenceFailed(stage: String, reason: String)
  case invalidInferenceOutput(stage: String, reason: String)

  var code: String {
    switch self {
    case .modelAssetsMissing, .modelLoadFailed, .invalidModelMetadata:
      return "OCR_MODEL_FAILED"
    case .imageDecodeFailed, .imageConversionFailed:
      return "IMAGE_DECODE_FAILED"
    case .pdfOpenFailed:
      return "PDF_OPEN_FAILED"
    case .pdfPageUnavailable, .pdfRenderFailed, .pageFailed:
      return "PDF_PAGE_FAILED"
    case .inferenceFailed, .invalidInferenceOutput:
      return "OCR_INFERENCE_FAILED"
    }
  }

  var details: [String: Any]? {
    switch self {
    case .pageFailed(let page, _), .pdfPageUnavailable(let page), .pdfRenderFailed(let page):
      return ["page": page]
    default:
      return nil
    }
  }

  var errorDescription: String? {
    switch self {
    case .modelAssetsMissing:
      return "PaddleOCR model assets are missing"
    case .modelLoadFailed(let reason):
      return "PaddleOCR model load failed: \(reason)"
    case .invalidModelMetadata(let stage, let reason):
      return "PaddleOCR \(stage) model metadata is invalid: \(reason)"
    case .imageDecodeFailed(let path):
      return "Could not decode image at \(path)"
    case .imageConversionFailed(let reason):
      return "Could not prepare image for OCR: \(reason)"
    case .pdfOpenFailed(let path):
      return "Could not open PDF at \(path)"
    case .pdfPageUnavailable(let page):
      return "PDF page \(page) is unavailable"
    case .pdfRenderFailed(let page):
      return "Could not render PDF page \(page)"
    case .pageFailed(let page, let reason):
      return "OCR failed on PDF page \(page): \(reason)"
    case .inferenceFailed(let stage, let reason):
      return "PaddleOCR \(stage) inference failed: \(reason)"
    case .invalidInferenceOutput(let stage, let reason):
      return "PaddleOCR \(stage) output is invalid: \(reason)"
    }
  }
}
