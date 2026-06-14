import 'package:flutter/services.dart';

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

  /// OCR an entire PDF natively — renders pages, runs PP-OCR (det+cls+rec) per
  /// page, returns per-page lines with real recognition confidence in one call.
  static Future<PaddlePdfResult?> ocrPdf(
    String pdfPath, {
    double scale = 2.0,
  }) async {
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
    }
  }
}

class PaddleTextBlock {
  final String text;
  final double confidence;

  PaddleTextBlock({required this.text, required this.confidence});
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
