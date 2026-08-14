import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../data/services/debug_log_service.dart';
import '../../data/services/ocr_highlight_matcher.dart';
import '../../data/services/paddle_ocr_channel.dart';

/// Renders a single PDF page as an image with pinch-to-zoom,
/// initially zoomed to the quadrant where the script line is.
///
/// Shared by the script editor and the OCR review flow so a user fixing a
/// badly-transcribed line can see the original scanned page for reference.
class PdfPageView extends StatefulWidget {
  final String pdfPath;
  final int pageNumber;
  final int? lineOnPage;

  /// When set, the page is re-OCR'd once (native single-page call, ~1 s)
  /// and the region best matching this text is highlighted and scrolled
  /// into view — so the user can SEE where a flagged line came from.
  final String? highlightText;

  const PdfPageView({
    super.key,
    required this.pdfPath,
    required this.pageNumber,
    this.lineOnPage,
    this.highlightText,
  });

  @override
  State<PdfPageView> createState() => _PdfPageViewState();
}

class _PdfPageViewState extends State<PdfPageView> {
  /// Always points at a cache-owned image (or null). The LRU cache is the
  /// SOLE owner of every decoded page: nothing else disposes them, and
  /// eviction skips whichever image is currently on screen.
  ui.Image? _pageImage;
  bool _loading = true;
  String? _renderError;
  final _txController = TransformationController();
  late int _currentPage;
  int _totalPages = 0;

  /// The document handle is opened once per file and reused across page
  /// flips — every flip used to re-open the PDF (re-parsing the xref) from
  /// disk before rendering.
  PdfDocument? _doc;
  String? _docPath;

  /// Decoded pages, keyed by page number, small LRU. A page flip back to a
  /// recently-viewed page (the OCR review flow bounces between pages
  /// constantly in the two-pane layout) reuses the decode instead of paying
  /// a multi-hundred-ms render + a fresh multi-MB RGBA allocation.
  final _pageCache = <int, ui.Image>{};
  static const _maxCachedPages = 4;

  /// Highlight state: rects (normalized page coords) for the current page,
  /// null while the page-OCR lookup runs, empty when nothing matched.
  List<Rect>? _highlightRects;
  bool _locating = false;

  /// Per-page OCR cache so flipping back doesn't re-OCR (small: the sheet
  /// lives per line).
  final _pageOcrCache = <int, List<OcrPageLine>>{};

  /// Last layout size, for the auto-scroll transform.
  Size _lastViewSize = Size.zero;

  /// Bumped on every [_renderPage] call. Rendering a page takes long enough
  /// that quickly stepping through lines leaves several renders in flight; a
  /// slow earlier one would otherwise land last, show the wrong page and leak
  /// the newer (tens of MB) image.
  int _renderGeneration = 0;

  @override
  void initState() {
    super.initState();
    _currentPage = widget.pageNumber;
    _renderPage();
  }

  @override
  void didUpdateWidget(covariant PdfPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // In the tablet two-pane layout this widget is kept alive and re-targeted as
    // the user selects different lines. Re-render only when the page (or file)
    // actually changes.
    if (oldWidget.pdfPath != widget.pdfPath ||
        oldWidget.pageNumber != widget.pageNumber) {
      _currentPage = widget.pageNumber;
      _renderPage();
    }
  }

  @override
  void dispose() {
    _evictAllCached();
    _doc?.dispose();
    _txController.dispose();
    super.dispose();
  }

  void _evictAllCached() {
    for (final img in _pageCache.values) {
      img.dispose();
    }
    _pageCache.clear();
    _pageImage = null; // was cache-owned; now disposed
  }

  void _cachePut(int page, ui.Image image) {
    final replaced = _pageCache.remove(page);
    if (replaced != null && !identical(replaced, image)) {
      if (identical(replaced, _pageImage)) _pageImage = null;
      replaced.dispose();
    }
    _pageCache[page] = image;
    // Maps iterate in insertion order — earliest key = least recently
    // inserted/hit. Never evict the image currently on screen.
    final evictable = _pageCache.keys
        .where((k) => !identical(_pageCache[k], _pageImage))
        .toList();
    for (final k in evictable) {
      if (_pageCache.length <= _maxCachedPages) break;
      _pageCache.remove(k)?.dispose();
    }
  }

  Future<void> _renderPage() async {
    final generation = ++_renderGeneration;
    final page = _currentPage;

    // Cache hit: instant flip, no I/O, no decode.
    final cached = _pageCache.remove(page);
    if (cached != null) {
      _pageCache[page] = cached; // refresh LRU position
      setState(() {
        _pageImage = cached;
        _loading = false;
        _renderError = null;
      });
      _txController.value = Matrix4.identity();
      _locateHighlight(page);
      return;
    }

    setState(() {
      _loading = true;
      _renderError = null;
    });
    _pageImage = null; // cache still owns the old image
    _txController.value = Matrix4.identity();

    try {
      Pdfrx.getCacheDirectory ??= () async {
        final dir = await getTemporaryDirectory();
        return dir.path;
      };

      // Reuse the open document; a new file (or a closed handle) reopens.
      if (_doc == null || _docPath != widget.pdfPath) {
        await _doc?.dispose();
        _evictAllCached();
        _doc = await PdfDocument.openFile(widget.pdfPath);
        _docPath = widget.pdfPath;
      }
      final doc = _doc!;
      if (_isStale(generation)) return;
      _totalPages = doc.pages.length;
      final pageIdx = page - 1;
      if (pageIdx < 0 || pageIdx >= doc.pages.length) {
        _fail(generation, 'Page $page is not in this PDF '
            '(it has $_totalPages page(s)).');
        return;
      }

      final pdfPage = doc.pages[pageIdx];
      // Render sized to the display, not a fixed 3×: viewport width ×
      // devicePixelRatio × 2 (zoom headroom for reading small print), capped
      // at 3× intrinsic. A letter-size scan at fixed 3× was a ~17 MB RGBA
      // buffer + decode per flip regardless of the screen showing it.
      final media = MediaQuery.maybeOf(context);
      final viewW = media == null ? 800.0 : media.size.width;
      final dpr = media?.devicePixelRatio ?? 2.0;
      final targetW =
          (viewW * dpr * 2).clamp(pdfPage.width, pdfPage.width * 3);
      final scale = targetW / pdfPage.width;
      final pdfImage = await pdfPage.render(
        fullWidth: pdfPage.width * scale,
        fullHeight: pdfPage.height * scale,
      );

      if (pdfImage == null) {
        _fail(generation, 'Page $page could not be rendered.');
        return;
      }

      final image = await pdfImage.createImage();
      pdfImage.dispose();

      // A newer request (or a dispose) beat us here — this image would show the
      // wrong page. It's still a perfectly good decode: cache it for the flip
      // back instead of discarding it.
      if (_isStale(generation)) {
        if (mounted) {
          _cachePut(page, image);
        } else {
          image.dispose();
        }
        return;
      }

      setState(() {
        _pageImage = image;
        _loading = false;
      });
      _cachePut(page, image);
      _locateHighlight(page);
    } catch (e, stack) {
      _fail(generation, 'Page $page of this PDF could not be shown.', e, stack);
    }
  }

  /// Re-OCR [page] (cached) and highlight where [widget.highlightText]
  /// sits. Only meaningful on the flagged line's own page — paging away
  /// clears the highlight rather than matching the text against the wrong
  /// page.
  Future<void> _locateHighlight(int page) async {
    final target = widget.highlightText;
    if (target == null || target.trim().isEmpty) return;
    if (page != widget.pageNumber) {
      if (mounted) setState(() => _highlightRects = const []);
      return;
    }
    setState(() {
      _locating = true;
      _highlightRects = null;
    });
    try {
      final lines = _pageOcrCache[page] ??
          await PaddleOcrChannel.ocrPage(widget.pdfPath, page);
      if (!mounted || _currentPage != page) return;
      if (lines == null) {
        // Native single-page OCR unavailable (e.g. macOS) — no highlight,
        // no error: the page itself still shows.
        setState(() {
          _locating = false;
          _highlightRects = const [];
        });
        return;
      }
      _pageOcrCache[page] = lines;
      final rects = OcrHighlightMatcher.locate(target, lines);
      setState(() {
        _locating = false;
        _highlightRects = rects;
      });
      if (rects.isNotEmpty) _scrollToHighlight(rects.first);
    } catch (e) {
      DebugLogService.instance
          .logError(LogCategory.general, 'Page highlight lookup failed', e);
      if (mounted) {
        setState(() {
          _locating = false;
          _highlightRects = const [];
        });
      }
    }
  }

  /// Pan so the highlight's center is vertically centered in the viewport
  /// (page is fit-to-width, so only the Y axis needs help).
  void _scrollToHighlight(Rect normRect) {
    final img = _pageImage;
    if (img == null || _lastViewSize == Size.zero) return;
    final scale = _lastViewSize.width / img.width;
    final pageH = img.height * scale;
    final targetY = normRect.center.dy * pageH - _lastViewSize.height / 2;
    final maxY = (pageH - _lastViewSize.height).clamp(0.0, double.infinity);
    final y = targetY.clamp(0.0, maxY);
    _txController.value = Matrix4.identity()..translateByDouble(0, -y, 0, 1);
  }

  bool _isStale(int generation) => !mounted || generation != _renderGeneration;

  /// Always logged; shown in place of the blank pane when this request is still
  /// the current one.
  void _fail(int generation, String message,
      [Object? error, StackTrace? stack]) {
    DebugLogService.instance
        .logError(LogCategory.general, 'PDF page view: $message', error, stack);
    if (_isStale(generation)) return;
    setState(() {
      _loading = false;
      _renderError = message;
    });
  }

  void _goToPage(int page) {
    if (page < 1 || page > _totalPages) return;
    _currentPage = page;
    _renderPage();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left, size: 20),
              onPressed: _currentPage > 1 ? () => _goToPage(_currentPage - 1) : null,
              visualDensity: VisualDensity.compact,
            ),
            Text(
              'Page $_currentPage${_totalPages > 0 ? '/$_totalPages' : ''}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right, size: 20),
              onPressed: _currentPage < _totalPages ? () => _goToPage(_currentPage + 1) : null,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        Text(
          'Drag to pan · pinch to zoom',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.45),
              ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _renderError != null
                  ? _buildError(context)
                  : _pageImage != null
                  ? LayoutBuilder(
                      builder: (context, constraints) {
                        final viewW = constraints.maxWidth;
                        final viewH = constraints.maxHeight;
                        final imgW = _pageImage!.width.toDouble();
                        final imgH = _pageImage!.height.toDouble();

                        // Fit the page to the viewer WIDTH so the text is
                        // readable; a taller-than-view page is panned vertically.
                        // No line-targeted auto-zoom — sourceLineOnPage isn't
                        // reliable, and a guessed crop hid the line off-screen.
                        final scale = viewW / imgW;
                        final pageW = imgW * scale; // == viewW
                        final pageH = imgH * scale;

                        _lastViewSize = Size(viewW, viewH);
                        return Stack(
                          children: [
                            InteractiveViewer(
                              transformationController: _txController,
                              constrained: false,
                              minScale: 0.5,
                              maxScale: 8.0,
                              // Generous margin so any region can be slid into
                              // view, even when zoomed right in.
                              boundaryMargin: EdgeInsets.symmetric(
                                horizontal: viewW,
                                vertical: viewH,
                              ),
                              child: SizedBox(
                                width: pageW,
                                height: pageH,
                                child: Stack(
                                  children: [
                                    RawImage(
                                      image: _pageImage,
                                      fit: BoxFit.fill,
                                    ),
                                    // Where the flagged line's text sits,
                                    // from a fresh single-page OCR.
                                    for (final r
                                        in _highlightRects ?? const <Rect>[])
                                      Positioned(
                                        left: r.left * pageW - 4,
                                        top: r.top * pageH - 3,
                                        width: r.width * pageW + 8,
                                        height: r.height * pageH + 6,
                                        child: IgnorePointer(
                                          child: DecoratedBox(
                                            decoration: BoxDecoration(
                                              color: Colors.yellow
                                                  .withValues(alpha: 0.30),
                                              border: Border.all(
                                                  color: Colors.orange,
                                                  width: 1.5),
                                              borderRadius:
                                                  BorderRadius.circular(3),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            if (_locating)
                              Positioned(
                                top: 8,
                                left: 0,
                                right: 0,
                                child: Center(child: _statusChip(context,
                                    'Locating line…', busy: true)),
                              )
                            else if (widget.highlightText != null &&
                                _currentPage == widget.pageNumber &&
                                (_highlightRects?.isEmpty ?? false))
                              Positioned(
                                top: 8,
                                left: 0,
                                right: 0,
                                child: Center(child: _statusChip(context,
                                    "Couldn't locate this line on the page")),
                              ),
                          ],
                        );
                      },
                    )
                  : const Center(child: Text('Could not load page')),
        ),
      ],
    );
  }

  Widget _statusChip(BuildContext context, String label,
      {bool busy = false}) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.inverseSurface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy) ...[
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: theme.colorScheme.onInverseSurface),
              ),
              const SizedBox(width: 8),
            ],
            Text(label,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onInverseSurface)),
          ],
        ),
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined,
                size: 32, color: theme.colorScheme.error),
            const SizedBox(height: 8),
            Text(
              _renderError!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _renderPage,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
