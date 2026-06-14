import 'package:flutter/material.dart';

import '../../data/models/script_models.dart';
import 'pdf_page_view.dart';

/// Result returned from [OcrReviewScreen]: the (possibly edited) full line list
/// with any removed lines dropped. The caller swaps this into the preview's
/// [ParsedScript] before the user saves.
class OcrReviewResult {
  const OcrReviewResult(this.lines);
  final List<ScriptLine> lines;
}

/// Editable review surface for low-OCR lines.
///
/// - "Review & edit" lines ([OcrReviewStatus.review]) are shown with an inline
///   [TextField] so the user can correct the OCR text. Saving an edit clears the
///   line's review flag.
/// - "Likely not script" lines ([OcrReviewStatus.likelyNotScript]) are grouped
///   into a separate collapsed section with a bulk "Remove these" action — these
///   are usually margin annotations / handwriting, not dialogue.
///
/// Operates on a copy of the full line list and returns it (with edits applied
/// and removals dropped) via [Navigator.pop].
class OcrReviewScreen extends StatefulWidget {
  const OcrReviewScreen({super.key, required this.lines, this.pdfPath});

  /// The full set of parsed lines (all statuses). The screen only surfaces the
  /// `review` / `likelyNotScript` ones but returns the whole list so the caller
  /// can swap it in wholesale.
  final List<ScriptLine> lines;

  /// Local path to the imported source PDF, if any. When present, review rows
  /// with a known `sourcePage` get a "View page" button that opens the original
  /// scanned page so the user can read it while correcting the OCR text.
  final String? pdfPath;

  @override
  State<OcrReviewScreen> createState() => _OcrReviewScreenState();
}

class _OcrReviewScreenState extends State<OcrReviewScreen> {
  /// Working copy keyed by line id, so edits/removals survive list rebuilds.
  late final Map<String, ScriptLine> _byId;

  /// Ids removed by the user (the "likely not script" bulk action or per-line).
  final Set<String> _removedIds = {};

  /// Per-line text controllers for the editable review rows.
  final Map<String, TextEditingController> _controllers = {};

  bool _notScriptExpanded = false;

  @override
  void initState() {
    super.initState();
    _byId = {for (final l in widget.lines) l.id: l};
    for (final line in _reviewLines) {
      _controllers[line.id] = TextEditingController(text: line.text);
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  List<ScriptLine> get _reviewLines => widget.lines
      .where((l) => l.reviewStatus == OcrReviewStatus.review)
      .toList();

  List<ScriptLine> get _notScriptLines => widget.lines
      .where((l) => l.reviewStatus == OcrReviewStatus.likelyNotScript)
      .toList();

  int get _pendingReviewCount =>
      _reviewLines.where((l) => !_removedIds.contains(l.id)).length;

  int get _pendingNotScriptCount =>
      _notScriptLines.where((l) => !_removedIds.contains(l.id)).length;

  void _saveEdit(ScriptLine line) {
    final text = _controllers[line.id]?.text.trim() ?? line.text;
    setState(() {
      // Editing resolves the review flag for this line.
      _byId[line.id] = _byId[line.id]!.copyWith(
        text: text,
        reviewStatus: OcrReviewStatus.ok,
      );
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Line updated')));
  }

  void _removeLine(ScriptLine line) {
    setState(() => _removedIds.add(line.id));
  }

  /// Opens the original scanned source page for [line] in a full-height modal
  /// bottom sheet so the user can read it while correcting the OCR text. Only
  /// reachable when both [OcrReviewScreen.pdfPath] and `line.sourcePage` exist.
  void _viewSourcePage(ScriptLine line) {
    final pdfPath = widget.pdfPath;
    final page = line.sourcePage;
    if (pdfPath == null || page == null) return;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return FractionallySizedBox(
          heightFactor: 0.92,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Source page${line.character.isNotEmpty ? ' — ${line.character}' : ''}',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(sheetContext).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: PdfPageView(
                  pdfPath: pdfPath,
                  pageNumber: page,
                  lineOnPage: line.sourceLineOnPage,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _removeAllNotScript() {
    setState(() {
      for (final line in _notScriptLines) {
        _removedIds.add(line.id);
      }
    });
  }

  void _done() {
    final result = <ScriptLine>[];
    for (final line in widget.lines) {
      if (_removedIds.contains(line.id)) continue;
      result.add(_byId[line.id] ?? line);
    }
    Navigator.of(context).pop(OcrReviewResult(result));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reviewLines =
        _reviewLines.where((l) => !_removedIds.contains(l.id)).toList();
    final notScriptLines = _notScriptLines;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Review OCR'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _done,
        ),
        actions: [
          TextButton(
            onPressed: _done,
            child: const Text('Done'),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildCountsBar(context),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (reviewLines.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'No lines need review.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.6),
                      ),
                    ),
                  )
                else ...[
                  Text('Review & edit', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Fix any misread text, then Done. '
                    'Editing a line clears its flag.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ...reviewLines.map(_buildReviewCard),
                ],
                if (notScriptLines.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  _buildNotScriptSection(context, notScriptLines),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCountsBar(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Text(
        '$_pendingReviewCount lines to review, '
        '$_pendingNotScriptCount likely-not-script',
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildReviewCard(ScriptLine line) {
    final theme = Theme.of(context);
    final controller = _controllers[line.id]!;
    final edited = _byId[line.id]?.reviewStatus == OcrReviewStatus.ok;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (line.character.isNotEmpty) ...[
                  Text(
                    line.character,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Text(
                  line.pageLineRef,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color:
                        theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
                const Spacer(),
                if (edited)
                  Icon(Icons.check_circle,
                      size: 18, color: theme.colorScheme.primary),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              maxLines: null,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (widget.pdfPath != null && line.sourcePage != null)
                  TextButton.icon(
                    onPressed: () => _viewSourcePage(line),
                    icon: const Icon(Icons.picture_as_pdf, size: 18),
                    label: const Text('View page'),
                  ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _removeLine(line),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Remove'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => _saveEdit(line),
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotScriptSection(
      BuildContext context, List<ScriptLine> notScriptLines) {
    final theme = Theme.of(context);
    final remaining =
        notScriptLines.where((l) => !_removedIds.contains(l.id)).toList();

    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: _notScriptExpanded,
          onExpansionChanged: (v) => setState(() => _notScriptExpanded = v),
          leading: const Icon(Icons.gesture),
          title: Text(
            'Likely not script (notes/handwriting)',
            style: theme.textTheme.titleSmall,
          ),
          subtitle: Text('${remaining.length} lines'),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'These are usually margin notes or handwriting, not dialogue. '
                'Remove them to keep your script clean.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
            const SizedBox(height: 8),
            ...remaining.map((line) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    line.text,
                    style: theme.textTheme.bodySmall,
                  ),
                  subtitle: Text(line.pageLineRef),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () => _removeLine(line),
                  ),
                )),
            if (remaining.isNotEmpty) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _removeAllNotScript,
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: Text('Remove these (${remaining.length})'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
