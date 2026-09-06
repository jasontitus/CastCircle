import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'paddle_ocr_channel.dart' show OcrCancelledException, OcrProgress;

/// Dart wrapper for the native macOS Vision OCR plugin.
/// Used as a replacement for Google ML Kit on macOS.
class VisionOcrChannel {
  static const _channel = MethodChannel('com.lineguide/vision_ocr');
  static bool _handlerInstalled = false;
  static int _requestSerial = 0;
  static final Map<String, _VisionOcrRequest> _requestsById = {};

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
      } else if (call.method == 'ocrPage') {
        final pageIndex = args['pageIndex'] as int?;
        final linesRaw = args['lines'] as List?;
        if (pageIndex == null || linesRaw == null) return null;
        request.pages.add(
          VisionPage(
            page: pageIndex,
            lines: [
              for (final line in linesRaw)
                (() {
                  final map = Map<String, dynamic>.from(line as Map);
                  return VisionTextBlock(
                    text: map['text'] as String? ?? '',
                    confidence: (map['confidence'] as num?)?.toDouble() ?? 0.0,
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
      'vision-${DateTime.now().microsecondsSinceEpoch}-${_requestSerial++}';

  /// Recognize text in an image file using Apple Vision framework.
  static Future<List<VisionTextBlock>?> recognizeText(String imagePath) async {
    try {
      final result = await _channel.invokeMethod<Map>('recognizeText', {
        'path': imagePath,
      });
      if (result == null) return null;

      final blocks = result['blocks'] as List?;
      if (blocks == null) return [];

      return blocks.map((b) {
        final map = Map<String, dynamic>.from(b as Map);
        return VisionTextBlock(
          text: map['text'] as String? ?? '',
          confidence: (map['confidence'] as num?)?.toDouble() ?? 0.0,
        );
      }).toList();
    } on MissingPluginException {
      return null;
    }
  }

  /// Start whole-PDF Vision OCR as a request-scoped, cancellable operation.
  static VisionOcrPdfJob startPdf(String pdfPath, {double scale = 2.0}) {
    _ensureProgressHandler();
    final requestId = _nextRequestId();
    final request = _VisionOcrRequest();
    _requestsById[requestId] = request;
    final job = VisionOcrPdfJob._(
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

  static Future<VisionPdfResult?> _runPdf(
    String pdfPath,
    double scale,
    String requestId,
    List<VisionPage> pages,
  ) async {
    try {
      final result = await _channel.invokeMethod<Map>('ocrPdf', {
        'path': pdfPath,
        'scale': scale,
        'requestId': requestId,
      });
      if (result == null) return null;
      pages.sort((a, b) => a.page.compareTo(b.page));
      return VisionPdfResult(
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

class _VisionOcrRequest {
  final ValueNotifier<OcrProgress?> progress = ValueNotifier((
    page: 0,
    total: 0,
  ));
  final List<VisionPage> pages = [];
}

class VisionOcrPdfJob {
  VisionOcrPdfJob._({
    required this.requestId,
    required this.progress,
    required Future<bool> Function(String) cancelRequest,
  }) : _cancelRequest = cancelRequest;

  final String requestId;
  final ValueNotifier<OcrProgress?> progress;
  final Future<bool> Function(String) _cancelRequest;
  late final Future<VisionPdfResult?> result;

  Future<void> cancel() async {
    await _cancelRequest(requestId);
  }
}

class VisionTextBlock {
  final String text;
  final double confidence;

  VisionTextBlock({required this.text, required this.confidence});
}

class VisionPage {
  final int page; // 1-based
  final List<VisionTextBlock> lines;

  VisionPage({required this.page, required this.lines});
}

class VisionPdfResult {
  final List<VisionPage> pages;
  final int pageCount;
  final int failedPages;

  VisionPdfResult({
    required this.pages,
    required this.pageCount,
    required this.failedPages,
  });
}
