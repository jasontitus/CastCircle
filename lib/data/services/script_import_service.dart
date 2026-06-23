import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/script_models.dart';
import 'ocr_confidence_service.dart';
import 'script_parser.dart';
import 'script_export.dart';
import 'pdf_text_channel.dart';
import 'perf_service.dart';
import 'paddle_ocr_channel.dart';
import 'vision_ocr_channel.dart';

/// Service to import scripts from PDF or text files.
class ScriptImportService {
  ScriptImportService();

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
    // Remove bold/italic markers (**text** -> text)
    text = text.replaceAll(RegExp(r'\*{2,3}'), '');
    // Remove horizontal rules
    text = text.replaceAll(RegExp(r'^[-*_]{3,}\s*$', multiLine: true), '');
    // Remove link syntax [text](url) -> text
    text = text.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\([^)]+\)'),
      (m) => m[1]!,
    );
    // Remove inline code backticks
    text = text.replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m[1]!);
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
    return PerfService.instance.measure(
      'pdf_import',
      () => _importFromPdfInner(pdfPath),
    );
  }

  Future<ParsedScript> _importFromPdfInner(String pdfPath) async {
    final title = _titleFromPath(pdfPath);

    // Strategy 1: Try native PDFKit text extraction (text-based PDFs)
    try {
      final perPage = await PdfTextChannel.extractTextPerPage(pdfPath);
      if (perPage != null && perPage.isNotEmpty) {
        // Build combined text and track which raw line came from which page
        final buffer = StringBuffer();
        final linePageMap =
            <int, int>{}; // raw line index → 1-based page number
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
          debugPrint(
            'PDF import: PDFKit extracted ${nativeText.length} chars from ${perPage.length} pages',
          );
          final cleanedText = _cleanPdfKitText(nativeText);
          final nativeParser = ScriptParser();
          final nativeResult = nativeParser.parse(cleanedText, title: title);

          if (_isGoodParse(nativeResult)) {
            // Map source page onto parsed lines
            final rawLines = nativeText.split('\n');
            final taggedLines = nativeResult.lines.map((line) {
              final pageInfo = _findSourcePage(
                line.text,
                rawLines,
                linePageMap,
              );
              return line.copyWith(
                sourcePage: () => pageInfo?.page,
                sourceLineOnPage: () => pageInfo?.lineOnPage,
              );
            }).toList();

            debugPrint(
              'PDF import: Using PDFKit result '
              '(${nativeResult.characters.length} characters, '
              '${nativeResult.lines.where((l) => l.lineType == LineType.dialogue).length} lines)',
            );
            return await _scoreConfidence(
              ParsedScript(
                title: nativeResult.title,
                lines: taggedLines,
                characters: nativeResult.characters,
                scenes: nativeResult.scenes,
                rawText: nativeResult.rawText,
              ),
            );
          }

          debugPrint(
            'PDF import: PDFKit parse quality low '
            '(${nativeResult.characters.length} chars, '
            '${nativeResult.acts.length} acts), trying OCR...',
          );
        }
      }
    } catch (e) {
      debugPrint('PDF import: PDFKit extraction failed ($e), trying OCR...');
    }

    // Strategy 2: OCR pipeline (image-based PDFs like scanned scripts)
    final ocrResult = await _importFromPdfOcr(pdfPath, title: title);
    return await _scoreConfidence(ocrResult);
  }

  /// Run dictionary-based spell checking on all lines to score OCR confidence.
  /// Disposes the dictionary after scoring to free memory.
  Future<ParsedScript> _scoreConfidence(ParsedScript script) async {
    final scorer = OcrConfidenceService.instance;
    try {
      await scorer.ensureVocabLoaded();
      final scoredLines = scorer.scoreScript(
        script.lines,
        characters: script.characters,
      );
      final reviewCount = scoredLines
          .where((l) => l.reviewStatus == OcrReviewStatus.review)
          .length;
      final notScriptCount = scoredLines
          .where((l) => l.reviewStatus == OcrReviewStatus.likelyNotScript)
          .length;
      debugPrint(
        'OCR confidence: $reviewCount lines to review, '
        '$notScriptCount likely-not-script (of ${scoredLines.length})',
      );
      return ParsedScript(
        title: script.title,
        lines: scoredLines,
        characters: script.characters,
        scenes: script.scenes,
        rawText: script.rawText,
      );
    } finally {
      scorer.dispose(); // free ~3MB dictionary
    }
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
      RegExp(r'^\d+\s+\w+\s+ACT \d+\.\s*SC\.\s*\d+\s*$', multiLine: true),
      '',
    );

    // Remove bare page numbers on their own line
    cleaned = cleaned.replaceAll(RegExp(r'^\d{1,3}\s*$', multiLine: true), '');

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
    final dialogueCount = result.lines
        .where((l) => l.lineType == LineType.dialogue)
        .length;
    final charCount = result.characters.length;
    final actCount = result.acts.length;

    // Must have at least 3 characters and 10 dialogue lines
    if (charCount < 3 || dialogueCount < 10) return false;

    // Too many acts suggests running headers were parsed as act markers
    // (a normal play has 1-5 acts, not 35)
    if (actCount > 10) return false;

    return true;
  }

  /// Normalize an OCR line for running-header/footer matching: lowercase, drop a
  /// leading or trailing bare page number, collapse whitespace. So "Jon Jory 14"
  /// and "Jon Jory 15" both key to "jon jory".
  static String _furnitureKey(String text) {
    var t = text.trim().toLowerCase();
    t = t.replaceAll(RegExp(r'^\s*\d+\s+'), ''); // leading page number
    t = t.replaceAll(RegExp(r'\s+\d+\s*$'), ''); // trailing page number
    return t.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Detect running headers/footers across an OCR'd document: text that
  /// consistently occupies the FIRST or LAST line slot on at least half the
  /// pages (e.g. a repeated "Jon Jory" credit or the play title). Character cues
  /// don't reliably land in the same boundary slot across pages, so they're not
  /// flagged. Returns the set of furniture keys to strip. No-op for <3 pages.
  static Set<String> _detectRunningFurniture(List<PaddlePage> pages) {
    if (pages.length < 3) return {};
    final firstCounts = <String, int>{};
    final lastCounts = <String, int>{};
    for (final page in pages) {
      final texts =
          page.lines.map((l) => l.text.trim()).where((t) => t.isNotEmpty).toList();
      if (texts.isEmpty) continue;
      final fk = _furnitureKey(texts.first);
      final lk = _furnitureKey(texts.last);
      if (fk.length >= 3) firstCounts[fk] = (firstCounts[fk] ?? 0) + 1;
      if (lk.length >= 3) lastCounts[lk] = (lastCounts[lk] ?? 0) + 1;
    }
    final threshold = (pages.length * 0.5).ceil().clamp(3, pages.length);
    final furniture = <String>{};
    firstCounts.forEach((k, v) {
      if (v >= threshold) furniture.add(k);
    });
    lastCounts.forEach((k, v) {
      if (v >= threshold) furniture.add(k);
    });
    return furniture;
  }

  /// The page's dialogue-body left edge (normalized 0–1): the median left of the
  /// "wide" boxes (full text lines). Margin annotations are then measured
  /// relative to this, so the rule adapts to each script's indentation (a script
  /// with no margin notes simply has nothing far enough to the left to drop).
  static double _bodyColumnLeft(List<PaddleTextBlock> lines) {
    var lefts = lines.where((l) => l.width >= 0.30).map((l) => l.left).toList();
    if (lefts.isEmpty) lefts = lines.map((l) => l.left).toList();
    if (lefts.isEmpty) return 0.0;
    lefts.sort();
    return lefts[lefts.length ~/ 2];
  }

  /// OCR-based PDF import pipeline.
  /// Renders each page to an image, runs text recognition,
  /// and maps per-line OCR confidence back onto parsed ScriptLines.
  Future<ParsedScript> _importFromPdfOcr(
    String pdfPath, {
    required String title,
  }) async {
    final buffer = StringBuffer();
    final lineConfidences = <int, double>{};
    final linePageMap = <int, int>{}; // raw line index → 1-based page
    var rawLineIndex = 0;
    var failedPages = 0;

    // PaddleOCR (PP-OCRv6 via ONNX Runtime) is the primary engine on EVERY
    // platform — one shared native code path (iOS + macOS use the same plugin)
    // so OCR behaviour can't diverge. Only if the native plugin is unavailable
    // or errors do we fall back: macOS → Apple Vision, iOS/Android → ML Kit.
    PaddlePdfResult? paddleResult;
    try {
      paddleResult = await PaddleOcrChannel.ocrPdf(pdfPath);
    } catch (e) {
      debugPrint('PDF OCR: PaddleOCR failed ($e) — falling back');
      paddleResult = null;
    }

    if (paddleResult != null) {
      failedPages = paddleResult.failedPages;
      // Running headers/footers (e.g. a "Jon Jory" credit or the title repeated
      // at the bottom/top of every page) otherwise leak in as bogus lines — the
      // parser's noise patterns only catch the ones that include a page number.
      final furniture = _detectRunningFurniture(paddleResult.pages);
      var strippedFurniture = 0;
      var strippedMargin = 0;
      for (final page in paddleResult.pages) {
        final bodyLeft = _bodyColumnLeft(page.lines);
        for (final line in page.lines) {
          // Left-margin handwritten annotations (a marked-up script's director
          // notes) sit well left of the indented dialogue body and are narrow —
          // drop them so they don't interleave line-by-line with the dialogue.
          if (line.left < bodyLeft - 0.12 && line.width < 0.30) {
            strippedMargin++;
            continue;
          }
          if (furniture.contains(_furnitureKey(line.text))) {
            strippedFurniture++;
            continue; // drop running header/footer
          }
          buffer.writeln(line.text);
          lineConfidences[rawLineIndex] = line.confidence; // real confidence
          linePageMap[rawLineIndex] = page.page;
          rawLineIndex++;
        }
        buffer.writeln();
        rawLineIndex++;
      }
      debugPrint(
        'PDF OCR (PaddleOCR): ${paddleResult.pageCount} pages, '
        '${paddleResult.failedPages} failed, '
        'stripped $strippedMargin margin notes + $strippedFurniture running '
        'header/footer lines ${furniture.isEmpty ? '' : furniture.toList()}',
      );
    } else if (Platform.isMacOS) {
      // macOS fallback: single native call — PDFKit render + Vision OCR.
      final pdfResult = await VisionOcrChannel.ocrPdf(pdfPath);
      if (pdfResult == null) {
        throw Exception('PaddleOCR and Vision OCR plugins both unavailable');
      }

      failedPages = pdfResult.failedPages;
      for (final page in pdfResult.pages) {
        for (final line in page.lines) {
          buffer.writeln(line.text);
          lineConfidences[rawLineIndex] = line.confidence;
          linePageMap[rawLineIndex] = page.page;
          rawLineIndex++;
        }
        buffer.writeln();
        rawLineIndex++;
      }

      debugPrint(
        'PDF OCR (Vision fallback): ${pdfResult.pageCount} pages, '
        '${pdfResult.failedPages} failed',
      );
    } else {
      // iOS/Android fallback: use pdfrx render + Google ML Kit per page
      Pdfrx.getCacheDirectory ??= () async {
        final dir = await getTemporaryDirectory();
        return dir.path;
      };
      final doc = await PdfDocument.openFile(pdfPath);
      final pageCount = doc.pages.length;

      final textRecognizer = TextRecognizer();

      try {
        for (var i = 1; i <= pageCount; i++) {
          try {
            final page = doc.pages[i - 1];
            final pdfImage = await page.render(
              fullWidth: page.width * 2,
              fullHeight: page.height * 2,
            );
            if (pdfImage == null) {
              debugPrint(
                'PDF OCR: Page $i/$pageCount — render returned null, skipping',
              );
              failedPages++;
              continue;
            }
            final image = await pdfImage.createImage();
            pdfImage.dispose();

            final byteData = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            image.dispose();

            if (byteData == null) {
              debugPrint(
                'PDF OCR: Page $i/$pageCount — render returned null, skipping',
              );
              failedPages++;
              continue;
            }

            final tempDir = await getTemporaryDirectory();
            final tempFile = File(p.join(tempDir.path, 'ocr_page_$i.png'));
            await tempFile.writeAsBytes(byteData.buffer.asUint8List());

            final inputImage = InputImage.fromFilePath(tempFile.path);
            final recognized = await textRecognizer.processImage(inputImage);

            for (final block in recognized.blocks) {
              for (final line in block.lines) {
                buffer.writeln(line.text);
                lineConfidences[rawLineIndex] = _estimateLineConfidence(
                  line.text,
                );
                linePageMap[rawLineIndex] = i;
                rawLineIndex++;
              }
              buffer.writeln();
              rawLineIndex++;
            }

            await tempFile.delete();

            debugPrint(
              'PDF OCR: Page $i/$pageCount done '
              '(${recognized.blocks.length} blocks)',
            );
          } catch (e) {
            debugPrint('PDF OCR: Page $i/$pageCount FAILED: $e — skipping');
            failedPages++;
          }
        }
      } finally {
        textRecognizer.close();
        await doc.dispose();
      }
    }

    if (failedPages > 0) {
      debugPrint('PDF OCR: $failedPages pages failed');
    }

    final rawText = buffer.toString();
    if (rawText.trim().isEmpty) {
      throw Exception(
        'No text found in PDF. The file may be image-only or corrupted.',
      );
    }

    final script = _parser.parse(rawText, title: title);

    // Map OCR confidence and source page onto parsed ScriptLines.
    // Use a single forward pass through raw lines so each raw line is
    // consumed at most once — prevents all parsed lines from matching
    // the same early occurrence of common text.
    final rawLines = rawText.split('\n');
    var rawSearchStart = 0;
    final updatedLines = script.lines.map((line) {
      final conf = _findConfidenceForParsedLine(
        line.text,
        rawLines,
        lineConfidences,
      );
      final pageInfo = _findSourcePageFrom(
        line.text,
        rawLines,
        linePageMap,
        rawSearchStart,
      );
      if (pageInfo != null) {
        rawSearchStart = pageInfo.rawLineIndex + 1;
      }
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

  /// Find the source page for a parsed line by matching against raw lines,
  /// starting from [startIndex] to avoid re-matching earlier lines.
  ({int page, int lineOnPage, int rawLineIndex})? _findSourcePageFrom(
    String parsedText,
    List<String> rawLines,
    Map<int, int> linePageMap,
    int startIndex,
  ) {
    final searchText = parsedText.trim().toLowerCase();
    if (searchText.isEmpty) return null;

    for (var i = startIndex; i < rawLines.length; i++) {
      final rawTrimmed = rawLines[i].trim().toLowerCase();
      if (rawTrimmed.isEmpty) continue;
      final page = linePageMap[i];
      if (page == null) continue;
      if (rawTrimmed.contains(searchText) || searchText.contains(rawTrimmed)) {
        return (page: page, lineOnPage: 0, rawLineIndex: i);
      }
    }
    return null;
  }

  /// Find the source page for a parsed line (legacy — searches from start).
  ({int page, int lineOnPage})? _findSourcePage(
    String parsedText,
    List<String> rawLines,
    Map<int, int> linePageMap,
  ) {
    final result = _findSourcePageFrom(parsedText, rawLines, linePageMap, 0);
    if (result == null) return null;
    return (page: result.page, lineOnPage: result.lineOnPage);
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
      if (rawTrimmed.contains(searchText) || searchText.contains(rawTrimmed)) {
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
    final cleanChars = trimmed.replaceAll(
      RegExp(r'''[a-zA-Z0-9 .,;:!?'"()\-/]'''),
      '',
    );
    final junkRatio = cleanChars.length / trimmed.length;
    if (junkRatio > 0.3)
      score -= 0.4;
    else if (junkRatio > 0.15)
      score -= 0.2;
    else if (junkRatio > 0.05)
      score -= 0.05;

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
      if (noVowelRatio > 0.3)
        score -= 0.3;
      else if (noVowelRatio > 0.1)
        score -= 0.15;
    }

    // 3. Lone single characters (fragmented words)
    final loneChars = words
        .where((w) => w.length == 1 && !RegExp(r'^[IaO0-9]$').hasMatch(w))
        .length;
    if (words.length > 2) {
      final loneRatio = loneChars / words.length;
      if (loneRatio > 0.3)
        score -= 0.25;
      else if (loneRatio > 0.15)
        score -= 0.1;
    }

    // 4. Repeated characters (stutter from misread: "tttthe")
    if (RegExp(r'(.)\1{3,}').hasMatch(trimmed)) {
      score -= 0.3;
    } else if (RegExp(r'(.)\1{2}').hasMatch(trimmed.toLowerCase())) {
      final triples = RegExp(
        r'(.)\1{2}',
      ).allMatches(trimmed.toLowerCase()).length;
      if (triples > 1) score -= 0.15;
    }

    // 5. Mixed case within a word (e.g. "hElLo")
    var mixedCaseWords = 0;
    for (final word in words) {
      if (word.length < 3) continue;
      if (word == word.toUpperCase() || word == word.toLowerCase()) continue;
      if (word[0] == word[0].toUpperCase() &&
          word.substring(1) == word.substring(1).toLowerCase())
        continue;
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
        .replaceAll(
          RegExp(r'_?(script|ocr|parsed|text)\b', caseSensitive: false),
          '',
        )
        .replaceAll('_', ' ')
        .trim();
  }
}
