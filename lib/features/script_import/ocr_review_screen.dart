import 'package:flutter/material.dart';

import '../../data/models/script_models.dart';
import 'pdf_page_view.dart';
import '../../core/toast.dart';

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

  /// Original (pre-edit) lines, for page-highlight matching.
  late final Map<String, ScriptLine> _origById;

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
    // Immutable originals: highlight matching must use the OCR'd text, not
    // the user's in-progress correction (which no longer matches the page).
    _origById = {for (final l in widget.lines) l.id: l};
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
  // Memoized current-order view: _contextLinesFor runs once per flagged
  // card inside build, and rebuilding + sorting the whole list per card was
  // O(n²·log n) per frame with hundreds of flagged OCR lines. Invalidated
  // whenever _removedIds changes (all mutations go through _markRemoved).
  List<ScriptLine>? _orderedCache;
  Map<String, int>? _orderedIndexCache;

  void _markRemoved(String id) {
    _removedIds.add(id);
    _orderedCache = null;
    _orderedIndexCache = null;
  }

  List<ScriptLine> get _orderedCurrentLines => _orderedCache ??= (widget.lines
      .where((l) => !_removedIds.contains(l.id))
      .toList()
    ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex)));

  Map<String, int> get _orderedIndexById => _orderedIndexCache ??= {
        for (var i = 0; i < _orderedCurrentLines.length; i++)
          _orderedCurrentLines[i].id: i,
      };

  List<ScriptLine> _contextLinesFor(ScriptLine flagged, {int span = 3}) {
    // Work over the CURRENT (non-removed) lines so the window follows deletions.
    // If we used the original list, lines deleted near one flagged item would
    // still occupy slots in a nearby flagged item's window and hide its real
    // neighbours — exactly the "didn't show the line" bug.
    final ordered = _orderedCurrentLines;
    final idx = _orderedIndexById[flagged.id] ?? -1;
    if (idx < 0) return const [];
    final out = <ScriptLine>[];
    for (var i = idx - span; i <= idx + span; i++) {
      if (i < 0 || i >= ordered.length || i == idx) continue;
      final l = ordered[i];
      if (l.reviewStatus != OcrReviewStatus.ok) continue; // has its own card
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

  // widget.lines never changes for this State's lifetime (edits live in
  // _byId, removals in _removedIds), so these filters are computed once.
  // As getters they re-scanned the whole script 5-6× per setState — tens of
  // thousands of predicate calls per tap on a large scan.
  late final List<ScriptLine> _reviewLines = widget.lines
      .where((l) => l.reviewStatus == OcrReviewStatus.review)
      .toList();

  late final List<ScriptLine> _notScriptLines = widget.lines
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
      ..showAutoToast(const SnackBar(content: Text('Line updated')));
  }

  void _removeLine(ScriptLine line) {
    setState(() => _markRemoved(line.id));
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
      setState(() => _markRemoved(l.id));
    }
  }

  /// Pins [line]'s source page in the right (detail) pane on wide layouts.
  void _select(ScriptLine line) {
    if (line.sourcePage == null || _selectedLineId == line.id) return;
    setState(() => _selectedLineId = line.id);
  }

  /// Flagged lines still pending, in script order — the walk-through list
  /// for the page viewer's Prev/Next.
  List<ScriptLine> _pendingWithPages() => [
        for (final l in _reviewLines)
          if (!_removedIds.contains(l.id) && l.sourcePage != null) l,
      ];

  /// Opens the original scanned source page for [line] in a full-height modal
  /// bottom sheet so the user can read it while correcting the OCR text. Only
  /// reachable when both [OcrReviewScreen.pdfPath] and `line.sourcePage` exist.
  ///
  /// The sheet is a WALK-THROUGH: Prev/Next step to the neighbouring flagged
  /// lines (new page, new highlight) without closing, so a whole review pass
  /// is one sheet instead of open-close-scroll-open per line.
  void _viewSourcePage(ScriptLine line) {
    final pdfPath = widget.pdfPath;
    if (pdfPath == null || line.sourcePage == null) return;

    final pending = _pendingWithPages();
    var idx = pending.indexWhere((l) => l.id == line.id);
    if (idx < 0) idx = 0;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      // The page viewer owns EVERY pan: with drag-to-dismiss enabled the
      // sheet fought InteractiveViewer for vertical swipes, making the
      // page feel stuck. Close button + tap-outside still dismiss.
      enableDrag: false,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            // Re-read each build: a removal inside the sheet shrinks it.
            final list = _pendingWithPages();
            if (list.isEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (sheetContext.mounted) Navigator.of(sheetContext).pop();
              });
              return const SizedBox.shrink();
            }
            if (idx >= list.length) idx = list.length - 1;
            final current = list[idx];
            final page = current.sourcePage!;
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
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Source page $page'
                                '${current.character.isNotEmpty ? ' — ${current.character}' : ''}',
                                style: theme.textTheme.titleMedium,
                              ),
                              Text(
                                'Flagged line ${idx + 1} of ${list.length}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.6),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Right where the user can SEE the line is crossed
                        // out / marginalia — no round-trip back to the card.
                        TextButton.icon(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text('Remove'),
                          style: TextButton.styleFrom(
                            foregroundColor: theme.colorScheme.error,
                          ),
                          onPressed: () {
                            _removeLine(current); // setState on the screen
                            setSheetState(() {}); // and refresh the sheet
                            ScaffoldMessenger.of(context)
                              ..hideCurrentSnackBar()
                              ..showAutoToast(const SnackBar(
                                  content: Text('Line removed')));
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Close',
                          onPressed: () => Navigator.of(sheetContext).pop(),
                        ),
                      ],
                    ),
                  ),
                  // The OCR text being hunted for, so the user can compare
                  // it against the highlighted region without leaving.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '"${(_origById[current.id] ?? current).text}"',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.75),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: PdfPageView(
                      // Key on the line so a step re-runs the locate.
                      key: ValueKey('sheet-${current.id}'),
                      pdfPath: pdfPath,
                      pageNumber: page,
                      lineOnPage: current.sourceLineOnPage,
                      highlightText: (_origById[current.id] ?? current).text,
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                      child: Row(
                        children: [
                          TextButton.icon(
                            onPressed: idx > 0
                                ? () => setSheetState(() => idx--)
                                : null,
                            icon: const Icon(Icons.chevron_left),
                            label: const Text('Previous'),
                          ),
                          const Spacer(),
                          FilledButton.icon(
                            onPressed: idx < list.length - 1
                                ? () => setSheetState(() => idx++)
                                : null,
                            icon: const Icon(Icons.chevron_right),
                            label: const Text('Next flagged line'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _removeAllNotScript() {
    setState(() {
      for (final line in _notScriptLines) {
        _markRemoved(line.id);
      }
    });
  }

  bool _popped = false;

  void _done() {
    if (_popped) return;
    _popped = true;
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

    // PopScope: the system back gesture/button used to pop this route with
    // null, and the caller treats null as "no changes" — every edit and
    // removal made here was silently discarded. Commit on ANY exit.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _done();
      },
      child: Scaffold(
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
      ),
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
          // ListView.builder, not ListView(children:): each review card holds
          // a TextField (one of the heaviest widgets), and a bad scan flags
          // 100-300 lines. Building them all on every setState (save, remove,
          // select) cost hundreds of ms per tap.
          child: _buildLazyList(reviewLines, notScriptLines, twoPane: false),
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
                child:
                    _buildLazyList(reviewLines, notScriptLines, twoPane: true),
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

  /// The list content shared by both layouts, built LAZILY: the itemBuilder
  /// constructs each review card (TextField — one of the heaviest widgets)
  /// only when its row scrolls near the viewport. The previous version
  /// prebuilt every card into a List<Widget> and indexed into it, which
  /// made ListView.builder lazy for layout but not construction — hundreds
  /// of card subtrees allocated per tap on a heavily-flagged scan.
  Widget _buildLazyList(
    List<ScriptLine> reviewLines,
    List<ScriptLine> notScriptLines, {
    required bool twoPane,
  }) {
    // Row map: 0 = header (or empty note), 1..n = review cards,
    // then optionally [spacer, not-script section].
    final cardCount = reviewLines.length;
    final hasNotScript = notScriptLines.isNotEmpty;
    final itemCount = 1 + cardCount + (hasNotScript ? 2 : 0);
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: itemCount,
      itemBuilder: (context, i) {
        final theme = Theme.of(context);
        if (i == 0) {
          if (reviewLines.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'No lines need review.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
            ],
          );
        }
        final cardIdx = i - 1;
        if (cardIdx < cardCount) {
          return _buildReviewCard(reviewLines[cardIdx], twoPane: twoPane);
        }
        if (cardIdx == cardCount) return const SizedBox(height: 24);
        return _buildNotScriptSection(context, notScriptLines);
      },
    );
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

    // Same walk-through affordances as the phone sheet: a wide screen (or
    // ANY phone in landscape — an iPhone 17 Pro Max is 956pt wide there)
    // renders this pane instead of the sheet, and it used to offer neither
    // Remove nor Next, so the actions vanished on rotation.
    final walk = _pendingWithPages();
    final walkIdx = walk.indexWhere((l) => l.id == selected.id);

    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                Icon(Icons.picture_as_pdf,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Source page $page'
                        '${selected.character.isNotEmpty ? ' — ${selected.character}' : ''}',
                        style: theme.textTheme.titleSmall,
                      ),
                      if (walkIdx >= 0)
                        Text(
                          'Flagged line ${walkIdx + 1} of ${walk.length}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.6),
                          ),
                        ),
                    ],
                  ),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Remove'),
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  onPressed: () {
                    // Advance the pinned selection first so the pane lands
                    // on the next flagged line instead of going blank.
                    final next = walkIdx >= 0 && walkIdx + 1 < walk.length
                        ? walk[walkIdx + 1]
                        : null;
                    _removeLine(selected);
                    setState(() => _selectedLineId = next?.id);
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showAutoToast(
                          const SnackBar(content: Text('Line removed')));
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: PdfPageView(
              // Key: re-locate when the selection moves to another line.
              key: ValueKey('src-${selected.id}'),
              pdfPath: pdfPath,
              pageNumber: page,
              lineOnPage: selected.sourceLineOnPage,
              highlightText: (_origById[selected.id] ?? selected).text,
            ),
          ),
          if (walkIdx >= 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: walkIdx > 0
                        ? () => setState(
                            () => _selectedLineId = walk[walkIdx - 1].id)
                        : null,
                    icon: const Icon(Icons.chevron_left),
                    label: const Text('Previous'),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: walkIdx < walk.length - 1
                        ? () => setState(
                            () => _selectedLineId = walk[walkIdx + 1].id)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                    label: const Text('Next flagged line'),
                  ),
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
