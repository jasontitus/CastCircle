import FlutterMacOS
import Vision
import AppKit
import PDFKit

/// macOS native OCR plugin using Apple's Vision framework + PDFKit rendering.
/// Renders and recognizes PDF pages natively, then streams each page result
/// independently to keep platform-channel payloads bounded.
class VisionOcrPlugin: NSObject {
    private let channel: FlutterMethodChannel
    private var pdfOcrJobs: [String: PdfOcrJob] = [:]

    private final class PdfOcrJob {
        let requestId: String
        private let lock = NSLock()
        private var cancelled = false

        init(requestId: String) {
            self.requestId = requestId
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "com.lineguide/vision_ocr",
            binaryMessenger: messenger
        )
        super.init()
        channel.setMethodCallHandler(handle)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "recognizeText":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "Missing 'path' argument",
                                    details: nil))
                return
            }
            recognizeText(path: path, result: result)

        case "ocrPdf":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String,
                  let requestId = args["requestId"] as? String,
                  !requestId.isEmpty else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "Missing 'path' or 'requestId' argument",
                                    details: nil))
                return
            }
            guard pdfOcrJobs[requestId] == nil else {
                result(FlutterError(code: "DUPLICATE_REQUEST",
                                    message: "OCR request is already active",
                                    details: requestId))
                return
            }
            let requestedScale = args["scale"] as? Double ?? 2.0
            guard requestedScale.isFinite else {
                result(FlutterError(code: "INVALID_SCALE",
                                    message: "OCR scale must be finite",
                                    details: nil))
                return
            }
            let job = PdfOcrJob(requestId: requestId)
            pdfOcrJobs[requestId] = job
            let scale = min(max(requestedScale, 0.5), 4.0)
            ocrPdf(path: path, scale: scale, job: job, result: result)

        case "cancelOcrPdf":
            guard let args = call.arguments as? [String: Any],
                  let requestId = args["requestId"] as? String else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "Missing 'requestId' argument",
                                    details: nil))
                return
            }
            guard let job = pdfOcrJobs[requestId] else {
                result(false)
                return
            }
            job.cancel()
            result(true)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// OCR a single image file.
    private func recognizeText(path: String, result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            let url = URL(fileURLWithPath: path)

            guard let image = NSImage(contentsOf: url),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "IMAGE_LOAD_FAILED",
                                        message: "Could not load image at \(path)",
                                        details: nil))
                }
                return
            }

            do {
                let blocks = try Self.ocrImage(cgImage)
                DispatchQueue.main.async {
                    result(["blocks": blocks])
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "OCR_FAILED",
                                        message: "Text recognition failed",
                                        details: error.localizedDescription))
                }
            }
        }
    }

    /// Full PDF OCR pipeline: render each page with PDFKit, OCR with Vision,
    /// stream page results, and return document-level completion metadata.
    private func ocrPdf(
        path: String,
        scale: Double,
        job: PdfOcrJob,
        result: @escaping FlutterResult
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let url = URL(fileURLWithPath: path)

            guard let document = PDFDocument(url: url) else {
                self.finishPdfOcr(
                    job: job,
                    result: result,
                    response: FlutterError(code: "PDF_OPEN_FAILED",
                                           message: "Could not open PDF at \(path)",
                                           details: nil)
                )
                return
            }

            let pageCount = document.pageCount
            var failedPages = 0

            for i in 0..<pageCount {
                if job.isCancelled { break }

                autoreleasepool {
                    guard let page = document.page(at: i) else {
                        failedPages += 1
                        return
                    }

                    let bounds = page.bounds(for: .mediaBox)
                    guard let dimensions = Self.renderDimensions(bounds: bounds, scale: scale),
                          let cgImage = Self.renderPage(
                              page,
                              width: dimensions.width,
                              height: dimensions.height
                          ) else {
                        NSLog("VisionOCR: Page \(i+1)/\(pageCount) render failed")
                        failedPages += 1
                        return
                    }

                    do {
                        let blocks = try Self.ocrImage(cgImage)
                        self.emitPage(job: job, pageIndex: i + 1, lines: blocks)
                    } catch {
                        NSLog("VisionOCR: Page \(i+1)/\(pageCount) recognition failed: \(error)")
                        failedPages += 1
                    }
                }
                self.emitProgress(job: job, page: i + 1, pageCount: pageCount)
            }

            self.finishPdfOcr(job: job, result: result, response: [
                "pageCount": pageCount,
                "failedPages": failedPages,
            ])
        }
    }

    private func emitPage(
        job: PdfOcrJob,
        pageIndex: Int,
        lines: [[String: Any]]
    ) {
        DispatchQueue.main.sync {
            guard self.pdfOcrJobs[job.requestId] === job,
                  !job.isCancelled else { return }
            self.channel.invokeMethod("ocrPage", arguments: [
                "requestId": job.requestId,
                "pageIndex": pageIndex,
                "lines": lines,
            ])
        }
    }

    private func emitProgress(job: PdfOcrJob, page: Int, pageCount: Int) {
        DispatchQueue.main.async {
            guard self.pdfOcrJobs[job.requestId] === job,
                  !job.isCancelled else { return }
            self.channel.invokeMethod("ocrProgress", arguments: [
                "requestId": job.requestId,
                "page": page,
                "pageCount": pageCount,
            ])
        }
    }

    private func finishPdfOcr(
        job: PdfOcrJob,
        result: @escaping FlutterResult,
        response: Any
    ) {
        DispatchQueue.main.async {
            guard self.pdfOcrJobs[job.requestId] === job else { return }
            self.pdfOcrJobs.removeValue(forKey: job.requestId)
            if job.isCancelled {
                result(FlutterError(code: "ocr_cancelled",
                                    message: "OCR request cancelled",
                                    details: job.requestId))
            } else {
                result(response)
            }
        }
    }

    private static let maxRenderDimension: CGFloat = 8_192
    private static let maxRenderPixels: CGFloat = 32_000_000

    private static func renderDimensions(
        bounds: CGRect,
        scale: Double
    ) -> (width: Int, height: Int)? {
        guard bounds.origin.x.isFinite,
              bounds.origin.y.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0,
              scale.isFinite,
              scale > 0 else {
            return nil
        }

        var width = bounds.width * CGFloat(scale)
        var height = bounds.height * CGFloat(scale)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            return nil
        }

        let sideReduction = min(
            1,
            min(maxRenderDimension / width, maxRenderDimension / height)
        )
        let pixelReduction = min(1, sqrt(maxRenderPixels / width / height))
        let reduction = min(sideReduction, pixelReduction)
        width *= reduction
        height *= reduction

        guard width.isFinite, height.isFinite, width >= 1, height >= 1 else {
            return nil
        }
        return (
            width: Int(width.rounded(.down)),
            height: Int(height.rounded(.down))
        )
    }

    /// Render a PDF page to a CGImage at dimensions already bounded for memory safety.
    private static func renderPage(_ page: PDFPage, width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        let renderWidth = CGFloat(width)
        let renderHeight = CGFloat(height)
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: renderWidth, height: renderHeight))

        let bounds = page.bounds(for: .mediaBox)
        context.scaleBy(x: renderWidth / bounds.width, y: renderHeight / bounds.height)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: context)

        return context.makeImage()
    }

    /// Run Vision text recognition on a CGImage and return structured results.
    private static func ocrImage(_ cgImage: CGImage) throws -> [[String: Any]] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        let sorted = observationsInReadingOrder(observations)

        var lines: [[String: Any]] = []
        for observation in sorted {
            guard let topCandidate = observation.topCandidates(1).first else { continue }
            lines.append([
                "text": topCandidate.string,
                "confidence": topCandidate.confidence,
            ])
        }
        return lines
    }

    private static func observationsInReadingOrder(
        _ observations: [VNRecognizedTextObservation]
    ) -> [VNRecognizedTextObservation] {
        guard let columnSplit = columnSplit(for: observations) else {
            return observationsSortedByRows(observations)
        }

        let spanning = observations
            .filter {
                $0.boundingBox.minX < columnSplit
                    && $0.boundingBox.maxX > columnSplit
            }
            .sorted {
                if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.000_1 {
                    return $0.boundingBox.midY > $1.boundingBox.midY
                }
                return $0.boundingBox.minX < $1.boundingBox.minX
            }
        var remaining = observations.filter {
            !($0.boundingBox.minX < columnSplit
                && $0.boundingBox.maxX > columnSplit)
        }
        var ordered: [VNRecognizedTextObservation] = []

        for separator in spanning {
            let above = remaining.filter {
                $0.boundingBox.midY > separator.boundingBox.midY
            }
            ordered.append(contentsOf: observationsSortedByColumns(above, split: columnSplit))
            remaining.removeAll {
                $0.boundingBox.midY > separator.boundingBox.midY
            }
            ordered.append(separator)
        }

        ordered.append(contentsOf: observationsSortedByColumns(remaining, split: columnSplit))
        return ordered
    }

    private static func columnSplit(
        for observations: [VNRecognizedTextObservation]
    ) -> CGFloat? {
        let candidates = observations.filter { $0.boundingBox.width < 0.6 }
        var bestSplit: CGFloat?
        var bestGap: CGFloat = 0

        for step in 20...80 {
            let split = CGFloat(step) / 100
            let left = candidates.filter { $0.boundingBox.maxX <= split }
            let right = candidates.filter { $0.boundingBox.minX >= split }
            let crossing = candidates.count - left.count - right.count
            guard crossing == 0, left.count >= 2, right.count >= 2,
                  let leftEdge = left.map({ $0.boundingBox.maxX }).max(),
                  let rightEdge = right.map({ $0.boundingBox.minX }).min() else {
                continue
            }

            let gap = rightEdge - leftEdge
            if gap >= 0.04, gap > bestGap {
                bestGap = gap
                bestSplit = split
            }
        }
        return bestSplit
    }

    private static func observationsSortedByColumns(
        _ observations: [VNRecognizedTextObservation],
        split: CGFloat
    ) -> [VNRecognizedTextObservation] {
        let left = observations.filter { $0.boundingBox.midX < split }
        let right = observations.filter { $0.boundingBox.midX >= split }
        return observationsSortedByRows(left) + observationsSortedByRows(right)
    }

    private static func observationsSortedByRows(
        _ observations: [VNRecognizedTextObservation]
    ) -> [VNRecognizedTextObservation] {
        var rows: [[VNRecognizedTextObservation]] = []
        let topDown = observations.sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.000_1 {
                return $0.boundingBox.midY > $1.boundingBox.midY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }

        for observation in topDown {
            if let rowIndex = rows.firstIndex(where: { row in
                guard let first = row.first else { return false }
                let tolerance = max(
                    first.boundingBox.height,
                    observation.boundingBox.height
                ) * 0.5
                return abs(first.boundingBox.midY - observation.boundingBox.midY)
                    <= tolerance
            }) {
                rows[rowIndex].append(observation)
            } else {
                rows.append([observation])
            }
        }

        return rows.flatMap { row in
            row.sorted {
                if abs($0.boundingBox.minX - $1.boundingBox.minX) > 0.000_1 {
                    return $0.boundingBox.minX < $1.boundingBox.minX
                }
                return $0.boundingBox.midY > $1.boundingBox.midY
            }
        }
    }
}
