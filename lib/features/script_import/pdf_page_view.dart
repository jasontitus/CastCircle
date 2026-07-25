import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../data/services/debug_log_service.dart';

/// Renders a single PDF page as an image with pinch-to-zoom,
/// initially zoomed to the quadrant where the script line is.
///
/// Shared by the script editor and the OCR review flow so a user fixing a
/// badly-transcribed line can see the original scanned page for reference.
class PdfPageView extends StatefulWidget {
  final String pdfPath;
  final int pageNumber;
  final int? lineOnPage;

  const PdfPageView({
    super.key,
    required this.pdfPath,
    required this.pageNumber,
    this.lineOnPage,
  });

  @override
  State<PdfPageView> createState() => _PdfPageViewState();
}

class _PdfPageViewState extends State<PdfPageView> {
  ui.Image? _pageImage;
  bool _loading = true;
  String? _renderError;
  final _txController = TransformationController();
  late int _currentPage;
  int _totalPages = 0;

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
    _pageImage?.dispose();
    _txController.dispose();
    super.dispose();
  }

  Future<void> _renderPage() async {
    final generation = ++_renderGeneration;
    final page = _currentPage;
    setState(() {
      _loading = true;
      _renderError = null;
    });
    _pageImage?.dispose();
    _pageImage = null;
    _txController.value = Matrix4.identity();

    try {
      Pdfrx.getCacheDirectory ??= () async {
        final dir = await getTemporaryDirectory();
        return dir.path;
      };

      final doc = await PdfDocument.openFile(widget.pdfPath);
      if (_isStale(generation)) {
        await doc.dispose();
        return;
      }
      _totalPages = doc.pages.length;
      final pageIdx = page - 1;
      if (pageIdx < 0 || pageIdx >= doc.pages.length) {
        await doc.dispose();
        _fail(generation, 'Page $page is not in this PDF '
            '(it has $_totalPages page(s)).');
        return;
      }

      final pdfPage = doc.pages[pageIdx];
      final pdfImage = await pdfPage.render(
        fullWidth: pdfPage.width * 3,
        fullHeight: pdfPage.height * 3,
      );
      await doc.dispose();

      if (pdfImage == null) {
        _fail(generation, 'Page $page could not be rendered.');
        return;
      }

      final image = await pdfImage.createImage();
      pdfImage.dispose();

      // A newer request (or a dispose) beat us here — this image would show the
      // wrong page, and dropping it without disposing leaks its pixel buffer.
      if (_isStale(generation)) {
        image.dispose();
        return;
      }

      setState(() {
        _pageImage = image;
        _loading = false;
      });
    } catch (e, stack) {
      _fail(generation, 'Page $page of this PDF could not be shown.', e, stack);
    }
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

                        return InteractiveViewer(
                          transformationController: _txController,
                          constrained: false,
                          minScale: 0.5,
                          maxScale: 8.0,
                          // Generous margin so any region can be slid into view,
                          // even when zoomed right in.
                          boundaryMargin: EdgeInsets.symmetric(
                            horizontal: viewW,
                            vertical: viewH,
                          ),
                          child: SizedBox(
                            width: pageW,
                            height: pageH,
                            child: RawImage(
                              image: _pageImage,
                              fit: BoxFit.fill,
                            ),
                          ),
                        );
                      },
                    )
                  : const Center(child: Text('Could not load page')),
        ),
      ],
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
