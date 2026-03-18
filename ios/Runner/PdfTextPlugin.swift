import Flutter
import PDFKit

/// Native plugin that extracts text directly from PDF files using Apple's PDFKit.
///
/// This is used as a fallback when ML Kit OCR produces poor results
/// (e.g., complex layouts like Folger Shakespeare PDFs with margin annotations).
/// PDFKit reads the embedded text layer directly, preserving the document's
/// logical text flow without needing image rendering or OCR.
class PdfTextPlugin: NSObject {
    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "com.lineguide/pdf_text",
            binaryMessenger: messenger
        )
        super.init()
        channel.setMethodCallHandler(handle)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "extractText":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "Missing 'path' argument",
                                    details: nil))
                return
            }
            extractText(path: path, result: result)

        case "extractTextPerPage":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "Missing 'path' argument",
                                    details: nil))
                return
            }
            extractTextPerPage(path: path, result: result)

        case "hasEmbeddedText":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "Missing 'path' argument",
                                    details: nil))
                return
            }
            hasEmbeddedText(path: path, result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Extract all text from a PDF using PDFKit's text layer.
    /// Returns the full text as a string, or an error if the PDF has no text.
    private func extractText(path: String, result: @escaping FlutterResult) {
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
            var fullText = ""

            for i in 0..<pageCount {
                guard let page = document.page(at: i) else { continue }
                if let pageText = page.string {
                    fullText += pageText
                    fullText += "\n"
                }
            }

            DispatchQueue.main.async {
                if fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result(FlutterError(code: "NO_TEXT",
                                        message: "PDF has no embedded text (image-only)",
                                        details: nil))
                } else {
                    result([
                        "text": fullText,
                        "pageCount": pageCount,
                    ])
                }
            }
        }
    }

    /// Extract text from each page separately, returning an array of strings.
    private func extractTextPerPage(path: String, result: @escaping FlutterResult) {
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

            var pages: [String] = []
            var hasAnyText = false

            for i in 0..<document.pageCount {
                let pageText = document.page(at: i)?.string ?? ""
                pages.append(pageText)
                if !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    hasAnyText = true
                }
            }

            DispatchQueue.main.async {
                if !hasAnyText {
                    result(FlutterError(code: "NO_TEXT",
                                        message: "PDF has no embedded text",
                                        details: nil))
                } else {
                    result(["pages": pages, "pageCount": document.pageCount])
                }
            }
        }
    }

    /// Quick check: does this PDF have embedded text on at least the first page?
    /// Useful for deciding whether to use PDFKit extraction or OCR.
    private func hasEmbeddedText(path: String, result: @escaping FlutterResult) {
        let url = URL(fileURLWithPath: path)

        guard let document = PDFDocument(url: url) else {
            result(false)
            return
        }

        // Check first 3 pages for text
        for i in 0..<min(3, document.pageCount) {
            if let page = document.page(at: i),
               let text = page.string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result(true)
                return
            }
        }

        result(false)
    }
}
