import FlutterMacOS
import Vision
import AppKit
import PDFKit

/// macOS native OCR plugin using Apple's Vision framework + PDFKit rendering.
/// Handles the entire PDF→render→OCR pipeline natively for speed,
/// eliminating per-page Dart↔native round-trips.
class VisionOcrPlugin: NSObject {
    private let channel: FlutterMethodChannel

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
                  let path = args["path"] as? String else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "Missing 'path' argument",
                                    details: nil))
                return
            }
            // Defensive clamp: scale multiplies straight into bitmap
            // dimensions — an absurd value would allocate a multi-hundred-MB
            // context per page and jetsam the process mid-OCR.
            let scale = min(max(args["scale"] as? Double ?? 2.0, 0.5), 4.0)
            ocrPdf(path: path, scale: scale, result: result)

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

            let blocks = Self.ocrImage(cgImage)
            DispatchQueue.main.async {
                result(["blocks": blocks])
            }
        }
    }

    /// Full PDF OCR pipeline: render each page with PDFKit, OCR with Vision.
    /// Returns per-page results with lines, confidence, and page numbers.
    private func ocrPdf(path: String, scale: Double, result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            let url = URL(fileURLWithPath: path)

            guard let document = PDFDocument(url: url) else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "PDF_OPEN_FAILED",
                                        message: "Could not open PDF at \(path)",
                                        details: nil))
                }
                return
            }

            let pageCount = document.pageCount
            var pages: [[String: Any]] = []
            var failedPages = 0

            for i in 0..<pageCount {
                guard let page = document.page(at: i) else {
                    failedPages += 1
                    continue
                }

                let bounds = page.bounds(for: .mediaBox)
                let width = bounds.width * CGFloat(scale)
                let height = bounds.height * CGFloat(scale)

                // Render page to CGImage
                guard let cgImage = Self.renderPage(page, width: width, height: height) else {
                    NSLog("VisionOCR: Page \(i+1)/\(pageCount) render failed")
                    failedPages += 1
                    continue
                }

                // Run Vision OCR on the rendered image
                let blocks = Self.ocrImage(cgImage)

                let pageResult: [String: Any] = [
                    "page": i + 1,  // 1-based
                    "lines": blocks,
                ]
                pages.append(pageResult)

            }

            DispatchQueue.main.async {
                result([
                    "pages": pages,
                    "pageCount": pageCount,
                    "failedPages": failedPages,
                ])
            }
        }
    }

    /// Render a PDF page to a CGImage at the given dimensions.
    private static func renderPage(_ page: PDFPage, width: CGFloat, height: CGFloat) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(
            data: nil,
            width: Int(width),
            height: Int(height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        // White background
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Scale to fit
        let bounds = page.bounds(for: .mediaBox)
        let scaleX = width / bounds.width
        let scaleY = height / bounds.height
        context.scaleBy(x: scaleX, y: scaleY)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)

        // Draw the PDF page
        page.draw(with: .mediaBox, to: context)

        return context.makeImage()
    }

    /// Run Vision text recognition on a CGImage and return structured results.
    private static func ocrImage(_ cgImage: CGImage) -> [[String: Any]] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            NSLog("VisionOCR: Recognition failed: \(error)")
            return []
        }

        guard let observations = request.results else { return [] }

        // Sort by Y position descending (Vision origin is bottom-left,
        // so higher Y = higher on the page = should come first in reading order)
        let sorted = observations.sorted { a, b in
            a.boundingBox.origin.y > b.boundingBox.origin.y
        }

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
}
