import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/script_models.dart';
import 'debug_log_service.dart';
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

  /// Pages that could not be OCR'd during the most recent [importFromPdf]
  /// call. The import UI reads this to warn the user — a scan that silently
  /// lost 5 of 60 pages looks perfectly clean in the preview and the actor
  /// only finds out at rehearsal.
  int lastImportFailedPages = 0;

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
    lastImportFailedPages = 0; // set by the OCR path when pages fail

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
            // Map source page onto parsed lines. Forward cursor: parsed lines
            // are in document order, so restarting the raw-line scan from 0
            // for every line (the old behavior) was O(N·M).
            final rawLines = nativeText.split('\n');
            var rawSearchStart = 0;
            final taggedLines = nativeResult.lines.map((line) {
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
      // Vocab loads on the MAIN isolate (rootBundle), but the scoring itself
      // — a 251K-word dictionary probe per distinct word across the whole
      // script — runs in a background isolate, exactly like the parse: doing
      // it on the UI isolate froze the import spinner for seconds on big
      // scanned plays.
      await scorer.ensureVocabLoaded();
      final vocab = scorer.theatricalVocab;
      final lines = script.lines;
      final characters = script.characters;
      final scoredLines = await Isolate.run(() {
        final s = OcrConfidenceService.instance; // fresh in this isolate
        s.setTheatricalVocab(vocab);
        return s.scoreScript(lines, characters: characters);
      });
      var reviewCount = 0;
      var notScriptCount = 0;
      for (final l in scoredLines) {
        if (l.reviewStatus == OcrReviewStatus.review) {
          reviewCount++;
        } else if (l.reviewStatus == OcrReviewStatus.likelyNotScript) {
          notScriptCount++;
        }
      }
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

  /// If the page has a distinct, tightly-clustered narrow far-left column
  /// (handwritten margin notes, or line numbers), return the left cutoff below
  /// which a narrow box is margin furniture; otherwise null → strip nothing.
  ///
  /// Auto-detected rather than a fixed threshold, so it never fires on a script
  /// whose body is simply flush-left or indented. Requires ≥4 narrow boxes
  /// tightly clustered (left spread ≤ 0.12) and clearly left of the body's left
  /// boundary (the 15th-percentile left of the wide body boxes). Verified on
  /// the real PP-OCRv6 models across P&P (drops only the handwritten notes),
  /// Macbeth/Folger (drops only FTLN line numbers, no dialogue), and Chekhov
  /// 1912 (drops nothing).
  static double? _marginCutoff(List<PaddleTextBlock> lines) {
    var wide = lines.where((l) => l.width >= 0.30).map((l) => l.left).toList();
    if (wide.isEmpty) wide = lines.map((l) => l.left).toList();
    if (wide.isEmpty) return null;
    wide.sort();
    final cutoff = wide[(wide.length * 0.15).floor()] - 0.10;
    final cands =
        lines.where((l) => l.width < 0.30 && l.left < cutoff).map((l) => l.left).toList();
    if (cands.length < 4) return null; // no consistent margin column
    cands.sort();
    if (cands.last - cands.first > 0.12) return null; // not tightly clustered
    return cutoff;
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
      // Loud, in the FIELD log: which engine actually ran decides OCR
      // quality (Android has no Paddle plugin yet — every import there is
      // the ML Kit fallback), and debugPrint never reaches debug reports.
      DebugLogService.instance.log(
          LogCategory.general,
          'PDF OCR: PaddleOCR unavailable ($e) — falling back to '
          '${Platform.isMacOS ? 'Vision' : 'ML Kit'}');
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
        // Only strip a margin column when one is clearly detected on this page,
        // so scripts without one lose nothing.
        final marginCutoff = _marginCutoff(page.lines);
        for (final line in page.lines) {
          // Left-margin handwritten annotations (a marked-up script's director
          // notes) sit in a narrow column well left of the dialogue body — drop
          // them so they don't interleave line-by-line with the dialogue.
          if (marginCutoff != null &&
              line.width < 0.30 &&
              line.left < marginCutoff) {
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
      // Field log, not debugPrint: which engine ran DECIDES import quality
      // and must show up in debug reports.
      DebugLogService.instance.log(
        LogCategory.general,
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
      // One platform-channel round-trip, not one per page.
      final tempDir = await getTemporaryDirectory();
      final tempFile = File(p.join(tempDir.path, 'ocr_page.png'));

      try {
        for (var i = 1; i <= pageCount; i++) {
          try {
            final page = doc.pages[i - 1];
            // ML Kit accuracy depends heavily on input resolution: the old
            // fixed 2x (~150 DPI on a letter page) misread the P&P scan at
            // the character level ("chamtorlae" for "Charlotte"). Target the
            // same ~long-side sweet spot the PaddleOCR plugin uses, clamped
            // so huge pages don't blow the page bitmap up unboundedly.
            final longSidePt = max(page.width, page.height);
            final renderScale = (2600 / longSidePt).clamp(2.0, 4.0);
            final pdfImage = await page.render(
              fullWidth: page.width * renderScale,
              fullHeight: page.height * renderScale,
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

            // Respect the view's offset/length: toByteData may return a
            // view into a larger buffer, and asUint8List() on the bare
            // buffer would append trailing garbage that breaks OCR.
            await tempFile.writeAsBytes(byteData.buffer
                .asUint8List(byteData.offsetInBytes, byteData.lengthInBytes));

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
        // The single reused page image is deleted once, not per page.
        if (tempFile.existsSync()) {
          try {
            await tempFile.delete();
          } catch (_) {}
        }
      }
    }

    lastImportFailedPages = failedPages;
    if (failedPages > 0) {
      DebugLogService.instance.logError(LogCategory.error,
          'PDF OCR: $failedPages page(s) failed — imported script is missing '
          'their content');
    }

    final rawText = buffer.toString();
    if (rawText.trim().isEmpty) {
      throw Exception(
        'No text found in PDF. The file may be image-only or corrupted.',
      );
    }

    // Parse + confidence/page mapping run in a worker isolate: for a big
    // scanned play this is seconds of pure-Dart string work, and doing it on
    // the UI isolate froze the import spinner right after the native OCR
    // finished. Everything captured/returned is plain data.
    return Isolate.run(
        () => parseAndMapOcr(rawText, title, lineConfidences, linePageMap));
  }

  /// Parse OCR'd [rawText] and map per-raw-line OCR confidence + source page
  /// onto the parsed lines. Pure function (safe for [Isolate.run]).
  ///
  /// Mapping uses a single forward cursor over the raw lines: parsed lines
  /// come out in document order, and each parsed line's contributing raw
  /// lines are consecutive. The old implementation rescanned ALL raw lines
  /// per parsed line (O(N·M) `contains` calls — tens of millions for a long
  /// play) and let repeated short text anywhere in the document pollute a
  /// line's confidence average.
  @visibleForTesting
  static ParsedScript parseAndMapOcr(
    String rawText,
    String title,
    Map<int, double> lineConfidences,
    Map<int, int> linePageMap,
  ) {
    final script = ScriptParser().parse(rawText, title: title);

    // NORMALIZED matching, not exact-lowercase: the parser's _cleanLine
    // rewrites junk chars and spacing on garbled lines — which are exactly
    // the review-flagged ones — so exact contains() failed for them, they
    // lost their sourcePage, and the OCR review's "View page" button
    // vanished on the very lines that needed it (field, iPhone 2026-08-13).
    final rawLines = rawText.split('\n').map(_normForMatch).toList();

    bool matches(String raw, String search) {
      if (raw.isEmpty || search.isEmpty) return false;
      if (raw.contains(search) || search.contains(raw)) return true;
      // Weak fallback: same first 12 normalized chars — enough to place a
      // heavily-rewritten line on its page.
      if (raw.length >= 12 && search.length >= 12) {
        return raw.substring(0, 12) == search.substring(0, 12);
      }
      return false;
    }

    var cursor = 0;
    final updatedLines = script.lines.map((line) {
      final searchText = _normForMatch(line.text);
      if (searchText.isEmpty) return line;

      // Find the first contributing raw line at/after the cursor.
      int? matchStart;
      for (var i = cursor; i < rawLines.length; i++) {
        if (rawLines[i].isEmpty) continue;
        if (matches(rawLines[i], searchText)) {
          matchStart = i;
          break;
        }
      }
      if (matchStart == null) return line;

      // Average confidence across the consecutive raw lines this parsed line
      // was assembled from.
      final confidences = <double>[];
      for (var i = matchStart; i < rawLines.length; i++) {
        if (rawLines[i].isEmpty) break;
        if (i > matchStart && !matches(rawLines[i], searchText)) break;
        final conf = lineConfidences[i];
        if (conf != null) confidences.add(conf);
      }
      cursor = matchStart + 1;

      final page = linePageMap[matchStart];
      final avgConf = confidences.isEmpty
          ? null
          : confidences.reduce((a, b) => a + b) / confidences.length;
      return line.copyWith(
        ocrConfidence: avgConf != null ? () => avgConf : null,
        sourcePage: page != null ? () => page : null,
        // Real position within the page (1-based), not the old constant 0.
        sourceLineOnPage:
            page != null ? () => _lineOnPage(linePageMap, matchStart!) : null,
      );
    }).toList();

    // Any line still unmapped inherits the nearest mapped neighbor's page:
    // a page holds ~40 lines, so the neighbor's page is right (or off by
    // one, and the viewer pages). Confidence is NOT inherited — the page is
    // navigation, not provenance.
    _inheritMissingPages(updatedLines);

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
  static final _normJunkRe = RegExp(r'[^a-z0-9 ]');
  static final _normWsRe = RegExp(r'\s+');

  /// Lowercase, junk stripped, whitespace collapsed — both sides of every
  /// raw-vs-parsed comparison go through this so _cleanLine's rewrites
  /// can't break the match.
  static String _normForMatch(String s) => s
      .toLowerCase()
      .replaceAll(_normJunkRe, ' ')
      .replaceAll(_normWsRe, ' ')
      .trim();

  /// 1-based position of [rawIdx] within its page.
  static int _lineOnPage(Map<int, int> linePageMap, int rawIdx) {
    final page = linePageMap[rawIdx];
    if (page == null) return 0;
    var first = rawIdx;
    while (first > 0 && linePageMap[first - 1] == page) {
      first--;
    }
    return rawIdx - first + 1;
  }

  /// Forward- then backward-fill sourcePage for unmapped lines.
  static void _inheritMissingPages(List<ScriptLine> lines) {
    int? lastPage;
    for (var i = 0; i < lines.length; i++) {
      final page = lines[i].sourcePage;
      if (page != null) {
        lastPage = page;
      } else if (lastPage != null) {
        final captured = lastPage;
        lines[i] = lines[i].copyWith(sourcePage: () => captured);
      }
    }
    int? nextPage;
    for (var i = lines.length - 1; i >= 0; i--) {
      final page = lines[i].sourcePage;
      if (page != null) {
        nextPage = page;
      } else if (nextPage != null) {
        final captured = nextPage;
        lines[i] = lines[i].copyWith(sourcePage: () => captured);
      }
    }
  }

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

  /// Estimate OCR confidence for a line based on text heuristics.
  /// Returns 0.0 (garbage) to 1.0 (clean).
  // Compiled once — _estimateLineConfidence runs per OCR line on the ML Kit
  // fallback path (thousands of lines per scanned play).
  static final _validCharRe = RegExp(r'''[a-zA-Z0-9 .,;:!?'"()\-/]''');
  static final _confWsRe = RegExp(r'\s+');
  static final _vowelRe = RegExp(r'[aeiouAEIOU]');
  static final _loneCharRe = RegExp(r'^[IaO0-9]$');
  static final _quadRepeatRe = RegExp(r'(.)\1{3,}');
  static final _tripleRepeatRe = RegExp(r'(.)\1{2}');
  static final _nonAlnumRe = RegExp(r'[^a-zA-Z0-9\s]');

  static double _estimateLineConfidence(String text) {
    if (text.trim().isEmpty) return 1.0;

    final trimmed = text.trim();
    var score = 1.0;

    // 1. Ratio of alphanumeric + common punctuation vs junk characters
    final cleanChars = trimmed.replaceAll(
      _validCharRe,
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
    final words = trimmed.split(_confWsRe);
    if (words.isNotEmpty) {
      var noVowelCount = 0;
      for (final word in words) {
        if (word.length <= 2) continue;
        if (word == word.toUpperCase() && word.length <= 12) continue;
        if (!_vowelRe.hasMatch(word)) {
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
        .where((w) => w.length == 1 && !_loneCharRe.hasMatch(w))
        .length;
    if (words.length > 2) {
      final loneRatio = loneChars / words.length;
      if (loneRatio > 0.3)
        score -= 0.25;
      else if (loneRatio > 0.15)
        score -= 0.1;
    }

    // 4. Repeated characters (stutter from misread: "tttthe")
    if (_quadRepeatRe.hasMatch(trimmed)) {
      score -= 0.3;
    } else if (_tripleRepeatRe.hasMatch(trimmed.toLowerCase())) {
      final triples =
          _tripleRepeatRe.allMatches(trimmed.toLowerCase()).length;
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
    if (trimmed.length < 5 && _nonAlnumRe.hasMatch(trimmed)) {
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
