import 'package:flutter/services.dart';

/// Dart wrapper for the native PDFKit text extraction plugin.
///
/// Provides direct text extraction from PDFs that have embedded text layers.
/// Used as a fallback when ML Kit OCR produces poor results on complex layouts
/// (e.g., Folger Shakespeare PDFs with margin annotations and FTLN numbers).
class PdfTextChannel {
  static const _channel = MethodChannel('com.lineguide/pdf_text');

  /// Extract all text from a PDF file using Apple's PDFKit.
  ///
  /// Returns the extracted text, or null if the PDF has no embedded text
  /// (image-only PDF that requires OCR).
  static Future<String?> extractText(String path) async {
    try {
      final result = await _channel.invokeMethod<Map>('extractText', {
        'path': path,
      });
      return result?['text'] as String?;
    } on PlatformException catch (e) {
      if (e.code == 'NO_TEXT') return null;
      rethrow;
    }
  }

  /// Check if a PDF has embedded text (vs being image-only).
  ///
  /// Returns true if at least one of the first 3 pages has extractable text.
  /// Use this to decide whether PDFKit extraction or OCR is appropriate.
  static Future<bool> hasEmbeddedText(String path) async {
    try {
      final result = await _channel.invokeMethod<bool>('hasEmbeddedText', {
        'path': path,
      });
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }
}
