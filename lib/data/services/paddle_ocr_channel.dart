import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Live progress of a native PDF OCR run: the page being processed and the
/// total. Null when no OCR is in flight.
typedef OcrProgress = ({int page, int total});

/// Dart wrapper for the native on-device PaddleOCR (PP-OCRv5) plugin, run via
/// ONNX Runtime. Replaces Google ML Kit for PDF/image OCR on iOS (and Android).
///
/// Mirrors [VisionOcrChannel] (the macOS Apple Vision plugin) so the import
/// pipeline can swap engines with no shape changes. Until the native plugin is
/// registered on a platform, every method returns null (via
/// [MissingPluginException]) and the caller falls back to ML Kit — so this is
/// safe to ship before the native side lands.
class PaddleOcrChannel {
  static const _channel = MethodChannel('com.lineguide/paddle_ocr');

  static bool _handlerInstalled = false;
  static int _requestSerial = 0;
  static final Map<String, _PaddleOcrRequest> _requestsById = {};

  /// Aggregate per-page progress of the most recent OCR run, for UI that
  /// outlives any single request object (the import screen's loading state).
  static final ValueNotifier<OcrProgress?> progress = ValueNotifier(null);

  /// Receive bounded, request-scoped page payloads and progress. Native never
  /// returns the document's pages in the final MethodChannel reply, avoiding a
  /// single whole-document StandardMessageCodec decode on the UI isolate.
  static void _ensureProgressHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.arguments is! Map) return null;
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final requestId = args['requestId'] as String?;
      final request = requestId == null ? null : _requestsById[requestId];
      if (request == null) return null;

      if (call.method == 'ocrProgress') {
        request.progress.value = (
          page: args['page'] as int? ?? 0,
          total: args['pageCount'] as int? ?? 0,
        );
        progress.value = request.progress.value;
      } else if (call.method == 'ocrPage') {
        final pageIndex = args['pageIndex'] as int?;
        final linesRaw = args['lines'] as List?;
        if (pageIndex == null || linesRaw == null) return null;
        request.pages.add(
          PaddlePage(
            page: pageIndex,
            lines: [
              for (final line in linesRaw)
                (() {
                  final map = Map<String, dynamic>.from(line as Map);
                  return PaddleTextBlock(
                    text: map['text'] as String? ?? '',
                    confidence: (map['confidence'] as num?)?.toDouble() ?? 0.0,
                    left: (map['left'] as num?)?.toDouble() ?? 0.0,
                    width: (map['width'] as num?)?.toDouble() ?? 1.0,
                  );
                })(),
            ],
          ),
        );
      }
      return null;
    });
  }

  static String _nextRequestId() =>
      'paddle-${DateTime.now().microsecondsSinceEpoch}-${_requestSerial++}';

  /// Recognize text in a single image file. Returns null when the native plugin
  /// isn't available on this platform/build (caller should fall back).
  static Future<List<PaddleTextBlock>?> recognizeText(String imagePath) async {
    try {
      final result = await _channel.invokeMethod<Map>('recognizeText', {
        'path': imagePath,
      });
      if (result == null) return null;

      final blocks = result['blocks'] as List?;
      if (blocks == null) return [];

      return blocks.map((b) {
        final map = Map<String, dynamic>.from(b as Map);
        return PaddleTextBlock(
          text: map['text'] as String? ?? '',
          confidence: (map['confidence'] as num?)?.toDouble() ?? 0.0,
        );
      }).toList();
    } on MissingPluginException {
      return null;
    }
  }

  /// OCR one 1-based page and return each recognized line with its FULL
  /// normalized bounding rect — used by the page viewer to highlight where
  /// a flagged line's text sits on the scanned page. Returns null when the
  /// native plugin is unavailable (e.g. macOS).
  static Future<List<OcrPageLine>?> ocrPage(String pdfPath, int page) async {
    try {
      final result = await _channel.invokeMethod<Map>('ocrPdfPage', {
        'path': pdfPath,
        'page': page,
      });
      final linesRaw = result?['lines'] as List? ?? [];
      return linesRaw.map((l) {
        final lm = Map<String, dynamic>.from(l as Map);
        return OcrPageLine(
          text: lm['text'] as String? ?? '',
          left: (lm['left'] as num?)?.toDouble() ?? 0.0,
          top: (lm['top'] as num?)?.toDouble() ?? 0.0,
          width: (lm['width'] as num?)?.toDouble() ?? 0.0,
          height: (lm['height'] as num?)?.toDouble() ?? 0.0,
        );
      }).toList();
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Start whole-PDF OCR and return a request-scoped operation. Native receives
  /// the generated request ID on start, progress, and cancellation, so an old
  /// import cannot cancel or update a newer one.
  static PaddleOcrPdfJob startPdf(String pdfPath, {double scale = 2.0}) {
    _ensureProgressHandler();
    final requestId = _nextRequestId();
    final request = _PaddleOcrRequest();
    _requestsById[requestId] = request;
    final job = PaddleOcrPdfJob._(
      requestId: requestId,
      progress: request.progress,
      cancelRequest: _cancelPdf,
    );
    job.result = _runPdf(pdfPath, scale, requestId, request.pages).whenComplete(
      () {
        _requestsById.remove(requestId);
        request.progress.value = null;
      },
    );
    return job;
  }

  static Future<PaddlePdfResult?> _runPdf(
    String pdfPath,
    double scale,
    String requestId,
    List<PaddlePage> pages,
  ) async {
    try {
      final result = await _channel.invokeMethod<Map>('ocrPdf', {
        'path': pdfPath,
        'scale': scale,
        'requestId': requestId,
      });
      if (result == null) return null;
      pages.sort((a, b) => a.page.compareTo(b.page));
      return PaddlePdfResult(
        pages: pages,
        pageCount: result['pageCount'] as int? ?? 0,
        failedPages: result['failedPages'] as int? ?? 0,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      if (error.code.toLowerCase() == 'ocr_cancelled') {
        throw OcrCancelledException(requestId);
      }
      rethrow;
    }
  }

  static Future<bool> _cancelPdf(String requestId) async {
    try {
      return await _channel.invokeMethod<bool>('cancelOcrPdf', {
            'requestId': requestId,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }
}

class _PaddleOcrRequest {
  final ValueNotifier<OcrProgress?> progress = ValueNotifier((
    page: 0,
    total: 0,
  ));
  final List<PaddlePage> pages = [];
}

/// A request-scoped whole-PDF Paddle OCR operation.
class PaddleOcrPdfJob {
  PaddleOcrPdfJob._({
    required this.requestId,
    required this.progress,
    required Future<bool> Function(String) cancelRequest,
  }) : _cancelRequest = cancelRequest;

  final String requestId;
  final ValueNotifier<OcrProgress?> progress;
  final Future<bool> Function(String) _cancelRequest;
  late final Future<PaddlePdfResult?> result;

  Future<void> cancel() async {
    await _cancelRequest(requestId);
  }
}

/// Signals deliberate abandonment of a native OCR request. It is distinct
/// from plugin unavailability so callers never fall through to another OCR
/// engine after the user has cancelled an import.
class OcrCancelledException implements Exception {
  const OcrCancelledException(this.requestId);

  final String requestId;

  @override
  String toString() => 'OCR request $requestId was cancelled';
}

class PaddleTextBlock {
  final String text;
  final double confidence;

  /// Normalized (0–1) left edge and width of the line's bounding box on the
  /// page. Used to drop left-margin handwritten annotations. Default to a
  /// full-width body line when the native side doesn't supply them.
  final double left;
  final double width;

  PaddleTextBlock({
    required this.text,
    required this.confidence,
    this.left = 0.0,
    this.width = 1.0,
  });
}

class PaddlePage {
  final int page; // 1-based
  final List<PaddleTextBlock> lines;

  PaddlePage({required this.page, required this.lines});
}

class PaddlePdfResult {
  final List<PaddlePage> pages;
  final int pageCount;
  final int failedPages;

  PaddlePdfResult({
    required this.pages,
    required this.pageCount,
    required this.failedPages,
  });
}

/// One recognized line on a single OCR'd page, rect normalized to page size.
class OcrPageLine {
  const OcrPageLine({
    required this.text,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });
  final String text;
  final double left;
  final double top;
  final double width;
  final double height;
}
