import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

  /// Import from a PDF file.
  /// For now, this is a placeholder — in production, this would:
  /// 1. Convert PDF pages to images
  /// 2. Run on-device OCR (ML Kit)
  /// 3. Parse the resulting text
  Future<ParsedScript> importFromPdf(String pdfPath) async {
    // TODO: Implement PDF → image → OCR pipeline
    // For now, throw a helpful error
    throw UnimplementedError(
      'PDF import requires OCR pipeline. '
      'Use importFromTextFile() with pre-OCR\'d text, '
      'or wait for the OCR integration in Phase 6.',
    );
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
