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

  /// Per-page OCR progress, pushed from native during [ocrPdf] so the import
  /// screen can show "Reading page X of Y" instead of a frozen spinner. Null
  /// between runs.
  static final ValueNotifier<OcrProgress?> progress = ValueNotifier(null);

  static bool _handlerInstalled = false;

  /// Install the native→Dart handler that receives `ocrProgress` events. Lazy
  /// (first OCR call) so we don't claim the channel handler until it's needed.
  static void _ensureProgressHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'ocrProgress' && call.arguments is Map) {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        progress.value = (
          page: args['page'] as int? ?? 0,
          total: args['pageCount'] as int? ?? 0,
        );
      }
      return null;
    });
  }

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

  /// OCR an entire PDF natively — renders pages, runs PP-OCR (det+cls+rec) per
  /// page, returns per-page lines with real recognition confidence in one call.
  static Future<PaddlePdfResult?> ocrPdf(
    String pdfPath, {
    double scale = 2.0,
  }) async {
    _ensureProgressHandler();
    progress.value = (page: 0, total: 0); // "starting" until the first page lands
    try {
      final result = await _channel.invokeMethod<Map>('ocrPdf', {
        'path': pdfPath,
        'scale': scale,
      });
      if (result == null) return null;

      final pageCount = result['pageCount'] as int? ?? 0;
      final failedPages = result['failedPages'] as int? ?? 0;
      final pagesRaw = result['pages'] as List? ?? [];

      final pages = pagesRaw.map((p) {
        final map = Map<String, dynamic>.from(p as Map);
        final pageNum = map['page'] as int? ?? 0;
        final linesRaw = map['lines'] as List? ?? [];
        final lines = linesRaw.map((l) {
          final lm = Map<String, dynamic>.from(l as Map);
          return PaddleTextBlock(
            text: lm['text'] as String? ?? '',
            confidence: (lm['confidence'] as num?)?.toDouble() ?? 0.0,
            left: (lm['left'] as num?)?.toDouble() ?? 0.0,
            width: (lm['width'] as num?)?.toDouble() ?? 1.0,
          );
        }).toList();
        return PaddlePage(page: pageNum, lines: lines);
      }).toList();

      return PaddlePdfResult(
        pages: pages,
        pageCount: pageCount,
        failedPages: failedPages,
      );
    } on MissingPluginException {
      return null;
    } finally {
      progress.value = null;
    }
  }
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
