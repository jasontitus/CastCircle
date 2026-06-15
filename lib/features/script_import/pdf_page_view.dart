import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

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
  final _txController = TransformationController();
  late int _currentPage;
  int _totalPages = 0;

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
    setState(() => _loading = true);
    _pageImage?.dispose();
    _pageImage = null;
    _txController.value = Matrix4.identity();

    try {
      Pdfrx.getCacheDirectory ??= () async {
        final dir = await getTemporaryDirectory();
        return dir.path;
      };

      final doc = await PdfDocument.openFile(widget.pdfPath);
      _totalPages = doc.pages.length;
      final pageIdx = _currentPage - 1;
      if (pageIdx < 0 || pageIdx >= doc.pages.length) {
        await doc.dispose();
        if (mounted) setState(() => _loading = false);
        return;
      }

      final page = doc.pages[pageIdx];
      final pdfImage = await page.render(
        fullWidth: page.width * 3,
        fullHeight: page.height * 3,
      );
      await doc.dispose();

      if (pdfImage == null || !mounted) return;

      final image = await pdfImage.createImage();
      pdfImage.dispose();

      if (mounted) {
        setState(() {
          _pageImage = image;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('PDF page render failed: $e');
      if (mounted) setState(() => _loading = false);
    }
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
}
