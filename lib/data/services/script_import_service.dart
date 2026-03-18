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
import 'pdf_text_channel.dart';

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

  /// Import from a PDF file.
  ///
  /// Strategy:
  /// 1. Try native PDFKit text extraction first (fast, high quality for
  ///    text-based PDFs like Gutenberg or Folger Shakespeare).
  /// 2. If PDFKit returns text, parse it and check quality.
  /// 3. If the result looks bad (few characters, too many acts) or the PDF
  ///    has no embedded text (image-only), fall back to OCR pipeline.
  Future<ParsedScript> importFromPdf(String pdfPath) async {
    final title = _titleFromPath(pdfPath);

    // Strategy 1: Try native PDFKit text extraction (text-based PDFs)
    try {
      final perPage = await PdfTextChannel.extractTextPerPage(pdfPath);
      if (perPage != null && perPage.isNotEmpty) {
        // Build combined text and track which raw line came from which page
        final buffer = StringBuffer();
        final linePageMap = <int, int>{}; // raw line index → 1-based page number
        var rawLineIdx = 0;

        for (var pageIdx = 0; pageIdx < perPage.length; pageIdx++) {
          final pageText = perPage[pageIdx];
          final pageLines = pageText.split('\n');
          for (final line in pageLines) {
            buffer.writeln(line);
            linePageMap[rawLineIdx] = pageIdx + 1; // 1-based
            rawLineIdx++;
          }
        }

        final nativeText = buffer.toString();
        if (nativeText.trim().length > 200) {
          debugPrint('PDF import: PDFKit extracted ${nativeText.length} chars from ${perPage.length} pages');
          final cleanedText = _cleanPdfKitText(nativeText);
          final nativeParser = ScriptParser();
          final nativeResult = nativeParser.parse(cleanedText, title: title);

          if (_isGoodParse(nativeResult)) {
            // Map source page onto parsed lines
            final rawLines = nativeText.split('\n');
            final taggedLines = nativeResult.lines.map((line) {
              final pageInfo = _findSourcePage(line.text, rawLines, linePageMap);
              return line.copyWith(
                sourcePage: () => pageInfo?.page,
                sourceLineOnPage: () => pageInfo?.lineOnPage,
              );
            }).toList();

            debugPrint('PDF import: Using PDFKit result '
                '(${nativeResult.characters.length} characters, '
                '${nativeResult.lines.where((l) => l.lineType == LineType.dialogue).length} lines)');
            return ParsedScript(
              title: nativeResult.title,
              lines: taggedLines,
              characters: nativeResult.characters,
              scenes: nativeResult.scenes,
              rawText: nativeResult.rawText,
            );
          }

          debugPrint('PDF import: PDFKit parse quality low '
              '(${nativeResult.characters.length} chars, '
              '${nativeResult.acts.length} acts), trying OCR...');
        }
      }
    } catch (e) {
      debugPrint('PDF import: PDFKit extraction failed ($e), trying OCR...');
    }

    // Strategy 2: OCR pipeline (image-based PDFs like scanned scripts)
    return _importFromPdfOcr(pdfPath, title: title);
  }

  /// Clean PDFKit-extracted text for parsing.
  ///
  /// PDFKit preserves all text layers including Folger FTLN line numbers,
  /// running headers, and page numbers that confuse the script parser.
  String _cleanPdfKitText(String text) {
    var cleaned = text;

    // Remove Folger FTLN line numbers (e.g., "FTLN 0042", "FTLN 0043 30")
    cleaned = cleaned.replaceAll(RegExp(r'FTLN \d+(\s+\d+)?\s*\n?'), '');

    // Remove running headers like "11 Macbeth ACT 1. SC. 2" or
    // "23    Macbeth    ACT 2. SC. 3"
    cleaned = cleaned.replaceAll(
        RegExp(r'^\d+\s+\w+\s+ACT \d+\.\s*SC\.\s*\d+\s*$',
            multiLine: true),
        '');

    // Remove bare page numbers on their own line
    cleaned = cleaned.replaceAll(
        RegExp(r'^\d{1,3}\s*$', multiLine: true), '');

    // Collapse 3+ blank lines to 2
    cleaned = cleaned.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    return cleaned;
  }

  /// Check if a parse result looks reasonable (not garbage).
  ///
  /// A bad parse typically has:
  /// - Very few characters (< 3) for a full play
  /// - Too many "acts" (Folger running headers parsed as act headers)
  /// - Very few dialogue lines relative to total content
  bool _isGoodParse(ParsedScript result) {
    final dialogueCount =
        result.lines.where((l) => l.lineType == LineType.dialogue).length;
    final charCount = result.characters.length;
    final actCount = result.acts.length;

    // Must have at least 3 characters and 10 dialogue lines
    if (charCount < 3 || dialogueCount < 10) return false;

    // Too many acts suggests running headers were parsed as act markers
    // (a normal play has 1-5 acts, not 35)
    if (actCount > 10) return false;

    return true;
  }

  /// OCR-based PDF import pipeline.
  /// Renders each page to an image, runs ML Kit text recognition,
  /// and maps per-line OCR confidence back onto parsed ScriptLines.
  Future<ParsedScript> _importFromPdfOcr(String pdfPath,
      {required String title}) async {
    final doc = await PdfDocument.openFile(pdfPath);
    final pageCount = doc.pageCount;

    final textRecognizer = TextRecognizer();
    final buffer = StringBuffer();
    // Track confidence and page per raw text line index (0-based)
    final lineConfidences = <int, double>{};
    final linePageMap = <int, int>{}; // raw line index → 1-based page
    var rawLineIndex = 0;

    var failedPages = 0;
    try {
      for (var i = 1; i <= pageCount; i++) {
        try {
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

          if (byteData == null) {
            debugPrint('PDF OCR: Page $i/$pageCount — render returned null, skipping');
            failedPages++;
            continue;
          }

          final tempDir = await getTemporaryDirectory();
          final tempFile = File(p.join(tempDir.path, 'ocr_page_$i.png'));
          await tempFile.writeAsBytes(byteData.buffer.asUint8List());

          // Run OCR
          final inputImage = InputImage.fromFilePath(tempFile.path);
          final recognized = await textRecognizer.processImage(inputImage);

          // Reconstruct text preserving line breaks, estimate confidence
          for (final block in recognized.blocks) {
            for (final line in block.lines) {
              buffer.writeln(line.text);
              // ML Kit on iOS doesn't return confidence scores, so we
              // estimate quality heuristically from the recognized text.
              lineConfidences[rawLineIndex] = _estimateLineConfidence(line.text);
              linePageMap[rawLineIndex] = i; // i is 1-based page number
              rawLineIndex++;
            }
            buffer.writeln(); // paragraph break between blocks
            rawLineIndex++; // account for the blank line
          }

          // Clean up temp file
          await tempFile.delete();

          debugPrint('PDF OCR: Page $i/$pageCount done '
              '(${recognized.blocks.length} blocks)');
        } catch (e) {
          // Don't let a single page failure kill the entire import
          debugPrint('PDF OCR: Page $i/$pageCount FAILED: $e — skipping');
          failedPages++;
        }
      }
    } finally {
      textRecognizer.close();
      doc.dispose();
    }

    if (failedPages > 0) {
      debugPrint('PDF OCR: $failedPages of $pageCount pages failed');
    }

    final rawText = buffer.toString();
    if (rawText.trim().isEmpty) {
      throw Exception(
          'No text found in PDF. The file may be image-only or corrupted.');
    }

    final script = _parser.parse(rawText, title: title);

    // Map OCR confidence and source page onto parsed ScriptLines.
    final rawLines = rawText.split('\n');
    final updatedLines = script.lines.map((line) {
      final conf = _findConfidenceForParsedLine(
          line.text, rawLines, lineConfidences);
      final pageInfo = _findSourcePage(line.text, rawLines, linePageMap);
      return line.copyWith(
        ocrConfidence: conf != null ? () => conf : null,
        sourcePage: pageInfo != null ? () => pageInfo.page : null,
        sourceLineOnPage: pageInfo != null ? () => pageInfo.lineOnPage : null,
      );
    }).toList();

    if (updatedLines.isNotEmpty) {
      return ParsedScript(
        title: script.title,
        lines: updatedLines,
        characters: script.characters,
        scenes: script.scenes,
        rawText: script.rawText,
      );
    }

    return script;
  }

  /// Find the source page for a parsed line by matching against raw lines.
  ({int page, int lineOnPage})? _findSourcePage(
    String parsedText,
    List<String> rawLines,
    Map<int, int> linePageMap,
  ) {
    final searchText = parsedText.trim().toLowerCase();
    if (searchText.isEmpty) return null;

    // Track line-within-page counters per page
    final pageLineCounts = <int, int>{};

    for (var i = 0; i < rawLines.length; i++) {
      final rawTrimmed = rawLines[i].trim().toLowerCase();
      if (rawTrimmed.isEmpty) continue;
      final page = linePageMap[i];
      if (page != null) {
        pageLineCounts[page] = (pageLineCounts[page] ?? 0) + 1;
      }
      if (rawTrimmed.contains(searchText) ||
          searchText.contains(rawTrimmed)) {
        if (page != null) {
          return (page: page, lineOnPage: pageLineCounts[page]!);
        }
      }
    }
    return null;
  }

  /// Find the OCR confidence for a parsed line by locating which raw text
  /// lines contributed to it.
  double? _findConfidenceForParsedLine(
    String parsedText,
    List<String> rawLines,
    Map<int, double> lineConfidences,
  ) {
    final confidences = <double>[];
    final searchText = parsedText.trim().toLowerCase();
    if (searchText.isEmpty) return null;

    for (var i = 0; i < rawLines.length; i++) {
      final rawTrimmed = rawLines[i].trim().toLowerCase();
      if (rawTrimmed.isEmpty) continue;
      if (rawTrimmed.contains(searchText) ||
          searchText.contains(rawTrimmed)) {
        final conf = lineConfidences[i];
        if (conf != null) confidences.add(conf);
      }
    }

    if (confidences.isEmpty) return null;
    return confidences.reduce((a, b) => a + b) / confidences.length;
  }

  /// Estimate OCR confidence for a line based on text heuristics.
  /// Returns 0.0 (garbage) to 1.0 (clean).
  static double _estimateLineConfidence(String text) {
    if (text.trim().isEmpty) return 1.0;

    final trimmed = text.trim();
    var score = 1.0;

    // 1. Ratio of alphanumeric + common punctuation vs junk characters
    final cleanChars = trimmed.replaceAll(RegExp(r'''[a-zA-Z0-9 .,;:!?'"()\-/]'''), '');
    final junkRatio = cleanChars.length / trimmed.length;
    if (junkRatio > 0.3) score -= 0.4;
    else if (junkRatio > 0.15) score -= 0.2;
    else if (junkRatio > 0.05) score -= 0.05;

    // 2. Words without vowels (likely garbled)
    final words = trimmed.split(RegExp(r'\s+'));
    if (words.isNotEmpty) {
      var noVowelCount = 0;
      for (final word in words) {
        if (word.length <= 2) continue;
        if (word == word.toUpperCase() && word.length <= 12) continue;
        if (!RegExp(r'[aeiouAEIOU]').hasMatch(word)) {
          noVowelCount++;
        }
      }
      final noVowelRatio = noVowelCount / words.length;
      if (noVowelRatio > 0.3) score -= 0.3;
      else if (noVowelRatio > 0.1) score -= 0.15;
    }

    // 3. Lone single characters (fragmented words)
    final loneChars = words.where((w) =>
        w.length == 1 && !RegExp(r'^[IaO0-9]$').hasMatch(w)).length;
    if (words.length > 2) {
      final loneRatio = loneChars / words.length;
      if (loneRatio > 0.3) score -= 0.25;
      else if (loneRatio > 0.15) score -= 0.1;
    }

    // 4. Repeated characters (stutter from misread: "tttthe")
    if (RegExp(r'(.)\1{3,}').hasMatch(trimmed)) {
      score -= 0.3;
    } else if (RegExp(r'(.)\1{2}').hasMatch(trimmed.toLowerCase())) {
      final triples = RegExp(r'(.)\1{2}').allMatches(trimmed.toLowerCase()).length;
      if (triples > 1) score -= 0.15;
    }

    // 5. Mixed case within a word (e.g. "hElLo")
    var mixedCaseWords = 0;
    for (final word in words) {
      if (word.length < 3) continue;
      if (word == word.toUpperCase() || word == word.toLowerCase()) continue;
      if (word[0] == word[0].toUpperCase() &&
          word.substring(1) == word.substring(1).toLowerCase()) continue;
      mixedCaseWords++;
    }
    if (words.length > 1 && mixedCaseWords / words.length > 0.3) {
      score -= 0.2;
    }

    // 6. Very short line with lots of punctuation (likely noise)
    if (trimmed.length < 5 && RegExp(r'[^a-zA-Z0-9\s]').hasMatch(trimmed)) {
      score -= 0.15;
    }

    return score.clamp(0.0, 1.0);
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
