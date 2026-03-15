import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf_render/pdf_render.dart';

import '../models/script_models.dart';
import 'script_parser.dart';
import 'script_export.dart';

/// Service to import scripts from PDF or text files.
class ScriptImportService {
  final ScriptParser _parser = ScriptParser();

  /// Import a script from a text file (already OCR'd or plain text).
  Future<ParsedScript> importFromTextFile(String filePath) async {
    final file = File(filePath);
    final rawText = await file.readAsString();
    final title = _titleFromPath(filePath);
    return _parser.parse(rawText, title: title);
  }

  /// Import from raw text string.
  ParsedScript importFromText(String rawText, {String title = 'Untitled'}) {
    return _parser.parse(rawText, title: title);
  }

  /// Import a script from a markdown file.
  /// Strips markdown formatting (bold, italic, headers, etc.) and parses.
  Future<ParsedScript> importFromMarkdownFile(String filePath) async {
    final file = File(filePath);
    var rawText = await file.readAsString();
    rawText = _stripMarkdown(rawText);
    final title = _titleFromPath(filePath);
    return _parser.parse(rawText, title: title);
  }

  /// Strip common markdown formatting to get clean script text.
  String _stripMarkdown(String md) {
    var text = md;
    // Remove markdown headers (## ACT I -> ACT I)
    text = text.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
    // Remove bold/italic markers
    text = text.replaceAll(RegExp(r'\*{1,3}(.+?)\*{1,3}'), r'$1');
    text = text.replaceAll(RegExp(r'_{1,3}(.+?)_{1,3}'), r'$1');
    // Remove horizontal rules
    text = text.replaceAll(RegExp(r'^[-*_]{3,}\s*$', multiLine: true), '');
    // Remove link syntax [text](url) -> text
    text = text.replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'$1');
    // Remove inline code backticks
    text = text.replaceAll(RegExp(r'`([^`]+)`'), r'$1');
    return text;
  }

  /// Import from a PDF file using the on-device OCR pipeline:
  /// 1. Render each PDF page to an image
  /// 2. Run ML Kit text recognition on each page image
  /// 3. Concatenate text and parse as a script
  Future<ParsedScript> importFromPdf(String pdfPath) async {
    final doc = await PdfDocument.openFile(pdfPath);
    final pageCount = doc.pageCount;

    final textRecognizer = TextRecognizer();
    final buffer = StringBuffer();

    try {
      for (var i = 1; i <= pageCount; i++) {
        // Render page to image at 2x for good OCR quality
        final page = await doc.getPage(i);
        final pageImage = await page.render(
          width: (page.width * 2).toInt(),
          height: (page.height * 2).toInt(),
        );
        final image = await pageImage.createImageDetached();

        // Save to temp file for ML Kit (requires file path)
        final byteData =
            await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();

        if (byteData == null) continue;

        final tempDir = await getTemporaryDirectory();
        final tempFile = File(p.join(tempDir.path, 'ocr_page_$i.png'));
        await tempFile.writeAsBytes(byteData.buffer.asUint8List());

        // Run OCR
        final inputImage = InputImage.fromFilePath(tempFile.path);
        final recognized = await textRecognizer.processImage(inputImage);

        // Reconstruct text preserving line breaks
        for (final block in recognized.blocks) {
          for (final line in block.lines) {
            buffer.writeln(line.text);
          }
          buffer.writeln(); // paragraph break between blocks
        }

        // Clean up temp file
        await tempFile.delete();

        debugPrint('PDF OCR: Page $i/$pageCount done '
            '(${recognized.blocks.length} blocks)');
      }
    } finally {
      textRecognizer.close();
      doc.dispose();
    }

    final rawText = buffer.toString();
    if (rawText.trim().isEmpty) {
      throw Exception(
          'No text found in PDF. The file may be image-only or corrupted.');
    }

    final title = _titleFromPath(pdfPath);
    return _parser.parse(rawText, title: title);
  }

  /// Save a parsed script export to the app's documents directory.
  Future<String> exportToTextFile(
    ParsedScript script, {
    String format = 'plain', // 'plain', 'markdown', 'character', 'cue'
    String? characterName,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final exportDir = Directory(p.join(dir.path, 'exports'));
    if (!exportDir.existsSync()) {
      exportDir.createSync(recursive: true);
    }

    String content;
    String extension;

    switch (format) {
      case 'markdown':
        content = ScriptExporter.toMarkdown(script);
        extension = '.md';
        break;
      case 'character':
        if (characterName == null) {
          throw ArgumentError('characterName required for character export');
        }
        content = ScriptExporter.toCharacterLines(script, characterName);
        extension = '.txt';
        break;
      case 'cue':
        if (characterName == null) {
          throw ArgumentError('characterName required for cue export');
        }
        content = ScriptExporter.toCueScript(script, characterName);
        extension = '.txt';
        break;
      default:
        content = ScriptExporter.toPlainText(script);
        extension = '.txt';
    }

    final safeName = script.title
        .replaceAll(RegExp(r'[^\w\s-]'), '')
        .replaceAll(RegExp(r'\s+'), '_')
        .toLowerCase();
    final fileName = '${safeName}_$format$extension';
    final filePath = p.join(exportDir.path, fileName);

    await File(filePath).writeAsString(content);
    return filePath;
  }

  String _titleFromPath(String path) {
    final name = p.basenameWithoutExtension(path);
    // Clean up common suffixes
    return name
        .replaceAll(RegExp(r'_?(script|ocr|parsed|text)\b', caseSensitive: false), '')
        .replaceAll('_', ' ')
        .trim();
  }
}
