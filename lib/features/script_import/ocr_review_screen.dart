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

  /// Review-line ids whose "edit nearby lines" context editor is open.
  final Set<String> _contextExpanded = {};

  /// Controllers for context (neighbour) lines, created lazily, keyed by line id.
  final Map<String, TextEditingController> _contextControllers = {};

  bool _notScriptExpanded = false;

  /// On wide layouts the screen is a two-pane master/detail: this is the id of
  /// the line whose source page is pinned in the right pane.
  String? _selectedLineId;

  /// At or above this width (logical px) the screen becomes a two-pane
  /// master/detail with the source page pinned beside the list; below it, a
  /// single column with a modal page viewer. ~720 covers tablets in portrait
  /// and large phones in landscape.
  static const double _twoPaneBreakpoint = 720;

  @override
  void initState() {
    super.initState();
    _byId = {for (final l in widget.lines) l.id: l};
    for (final line in _reviewLines) {
      _controllers[line.id] = TextEditingController(text: line.text);
    }
    // Default the pinned detail pane to the first reviewable line that has a
    // known source page.
    final withPage = _reviewLines.where((l) => l.sourcePage != null);
    _selectedLineId = withPage.isNotEmpty ? withPage.first.id : null;
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    for (final c in _contextControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Lines surrounding [flagged] (by script order) that aren't themselves
  /// flagged — the context the user wants to clean up, since OCR errors cluster
  /// and often span more than the one flagged line. Flagged neighbours are
  /// skipped because they already have their own editable card.
  List<ScriptLine> _contextLinesFor(ScriptLine flagged, {int span = 3}) {
    final ordered = widget.lines.toList()
      ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    final idx = ordered.indexWhere((l) => l.id == flagged.id);
    if (idx < 0) return const [];
    final out = <ScriptLine>[];
    for (var i = idx - span; i <= idx + span; i++) {
      if (i < 0 || i >= ordered.length || i == idx) continue;
      final l = ordered[i];
      if (l.reviewStatus != OcrReviewStatus.ok) continue; // has its own card
      if (_removedIds.contains(l.id)) continue;
      out.add(l);
    }
    return out;
  }

  TextEditingController _contextController(ScriptLine l) =>
      _contextControllers.putIfAbsent(
          l.id, () => TextEditingController(text: (_byId[l.id] ?? l).text));

  void _onContextChanged(ScriptLine l, String value) {
    // Capture live so the edit is included when the user taps Done.
    _byId[l.id] = (_byId[l.id] ?? l).copyWith(text: value);
  }

  void _toggleContext(ScriptLine line) {
    setState(() {
      if (!_contextExpanded.add(line.id)) _contextExpanded.remove(line.id);
    });
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

  /// Confirm + remove a nearby (context) line. Unlike the flagged line's own
  /// "Remove line" button, deleting a neighbour is easy to do by accident while
  /// cleaning up a region, so it's gated behind a confirmation.
  Future<void> _removeContextLine(ScriptLine l) async {
    final text = _contextControllers[l.id]?.text ?? _byId[l.id]?.text ?? l.text;
    final preview = text.trim().isEmpty
        ? '(empty)'
        : (text.length > 90 ? '${text.substring(0, 87)}…' : text);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this line?'),
        content: Text(
          'It will be deleted from your script:\n\n'
          '${l.character.isNotEmpty ? '${l.character}: ' : ''}"$preview"',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      setState(() => _removedIds.add(l.id));
    }
  }

  /// Pins [line]'s source page in the right (detail) pane on wide layouts.
  void _select(ScriptLine line) {
    if (line.sourcePage == null || _selectedLineId == line.id) return;
    setState(() => _selectedLineId = line.id);
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
    final width = MediaQuery.sizeOf(context).width;
    final reviewLines =
        _reviewLines.where((l) => !_removedIds.contains(l.id)).toList();
    final notScriptLines = _notScriptLines;
    // The two-pane detail view is only useful when we can actually show a page.
    final twoPane = width >= _twoPaneBreakpoint && widget.pdfPath != null;

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
      body: twoPane
          ? _buildTwoPaneBody(context, reviewLines, notScriptLines)
          : _buildSinglePaneBody(context, reviewLines, notScriptLines),
    );
  }

  /// Phone / narrow layout: a single scrolling column. Source pages open in a
  /// modal bottom sheet via each card's "View page" button.
  Widget _buildSinglePaneBody(BuildContext context,
      List<ScriptLine> reviewLines, List<ScriptLine> notScriptLines) {
    return Column(
      children: [
        _buildCountsBar(context),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: _buildListChildren(
              context,
              reviewLines,
              notScriptLines,
              twoPane: false,
            ),
          ),
        ),
      ],
    );
  }

  /// Tablet / wide layout: the editable list on the left, the selected line's
  /// source page pinned on the right so the user can read it while correcting.
  Widget _buildTwoPaneBody(BuildContext context, List<ScriptLine> reviewLines,
      List<ScriptLine> notScriptLines) {
    return Column(
      children: [
        _buildCountsBar(context),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 5,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: _buildListChildren(
                    context,
                    reviewLines,
                    notScriptLines,
                    twoPane: true,
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                flex: 4,
                child: _buildSourcePane(context),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// The list content shared by both layouts.
  List<Widget> _buildListChildren(
    BuildContext context,
    List<ScriptLine> reviewLines,
    List<ScriptLine> notScriptLines, {
    required bool twoPane,
  }) {
    final theme = Theme.of(context);
    return [
      if (reviewLines.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text(
            'No lines need review.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        )
      else ...[
        Text('Review & edit', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          twoPane
              ? 'Tap a line to see its page on the right. '
                  'Fix any misread text, then Done.'
              : 'Fix any misread text, then Done. '
                  'Editing a line clears its flag.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 12),
        ...reviewLines.map((l) => _buildReviewCard(l, twoPane: twoPane)),
      ],
      if (notScriptLines.isNotEmpty) ...[
        const SizedBox(height: 24),
        _buildNotScriptSection(context, notScriptLines),
      ],
    ];
  }

  /// The pinned right pane on wide layouts: the source page for the selected
  /// line, or a hint when nothing with a page is selected.
  Widget _buildSourcePane(BuildContext context) {
    final theme = Theme.of(context);
    final pdfPath = widget.pdfPath;
    final selected = _selectedLineId != null ? _byId[_selectedLineId] : null;
    final page = selected?.sourcePage;

    if (pdfPath == null || selected == null || page == null) {
      return Container(
        color: theme.colorScheme.surfaceContainerLow,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: Text(
          'Tap a line to see its source page here.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      );
    }

    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Icon(Icons.picture_as_pdf,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Source page'
                    '${selected.character.isNotEmpty ? ' — ${selected.character}' : ''}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: PdfPageView(
              pdfPath: pdfPath,
              pageNumber: page,
              lineOnPage: selected.sourceLineOnPage,
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

  Widget _buildReviewCard(ScriptLine line, {required bool twoPane}) {
    final theme = Theme.of(context);
    final controller = _controllers[line.id]!;
    final edited = _byId[line.id]?.reviewStatus == OcrReviewStatus.ok;
    final isSelected = twoPane && _selectedLineId == line.id;
    final canSelect = twoPane && line.sourcePage != null;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: isSelected
          ? RoundedRectangleBorder(
              side: BorderSide(color: theme.colorScheme.primary, width: 2),
              borderRadius: BorderRadius.circular(12),
            )
          : null,
      child: InkWell(
        onTap: canSelect ? () => _select(line) : null,
        borderRadius: BorderRadius.circular(12),
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
                onTap: canSelect ? () => _select(line) : null,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _toggleContext(line),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: Icon(
                    _contextExpanded.contains(line.id)
                        ? Icons.unfold_less
                        : Icons.unfold_more,
                    size: 18,
                  ),
                  label: Text(
                    _contextExpanded.contains(line.id)
                        ? 'Hide nearby lines'
                        : 'Edit nearby lines',
                  ),
                ),
              ),
              if (_contextExpanded.contains(line.id)) _buildContextEditor(line),
              const SizedBox(height: 8),
              Row(
                children: [
                  // On wide layouts the page is already pinned beside the list,
                  // so the per-card "View page" button only appears on phones.
                  if (!twoPane &&
                      widget.pdfPath != null &&
                      line.sourcePage != null)
                    TextButton.icon(
                      onPressed: () => _viewSourcePage(line),
                      icon: const Icon(Icons.picture_as_pdf, size: 18),
                      label: const Text('View page'),
                    ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => _removeLine(line),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Remove line'),
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
      ),
    );
  }

  /// Editable fields for the lines surrounding a flagged line, so the user can
  /// clean up a whole misread region — OCR errors cluster and often span more
  /// than the single flagged line.
  Widget _buildContextEditor(ScriptLine line) {
    final theme = Theme.of(context);
    final ctx = _contextLinesFor(line);
    if (ctx.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          'No nearby lines to edit.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 4),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Nearby lines',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 4),
          ...ctx.map((l) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (l.character.isNotEmpty)
                      SizedBox(
                        width: 60,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 9, right: 6),
                          child: Text(
                            l.character,
                            style: theme.textTheme.labelSmall
                                ?.copyWith(fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    Expanded(
                      child: TextField(
                        controller: _contextController(l),
                        maxLines: null,
                        onChanged: (v) => _onContextChanged(l, v),
                        style: theme.textTheme.bodySmall,
                        decoration: const InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(),
                          contentPadding:
                              EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: 'Remove this line',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      onPressed: () => _removeContextLine(l),
                    ),
                  ],
                ),
              )),
        ],
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
