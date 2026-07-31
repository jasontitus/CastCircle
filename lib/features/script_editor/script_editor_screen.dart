import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../../core/responsive.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/production_models.dart';
import '../../data/models/script_models.dart';
import '../../data/services/analytics_service.dart';
import '../../data/services/script_export.dart';
import '../../data/services/supabase_service.dart';
import '../../providers/production_providers.dart';
import '../script_import/pdf_page_view.dart';
import 'validation_panel.dart';
import '../../core/toast.dart';

class ScriptEditorScreen extends ConsumerStatefulWidget {
  const ScriptEditorScreen({super.key});

  @override
  ConsumerState<ScriptEditorScreen> createState() => _ScriptEditorScreenState();
}

class _ScriptEditorScreenState extends ConsumerState<ScriptEditorScreen> {
  String? _selectedCharacter;
  bool _showDirections = true;
  bool _reorderMode = false;
  bool _showLowConfidenceOnly = false;
  ScriptLine? _selectedLine; // for tablet master-detail

  /// Detail-panel text controller, owned here and re-targeted only when the
  /// selected line changes. Creating one inside _buildDetailPanel leaked a
  /// controller per rebuild AND wiped the user's in-progress edit on every
  /// rebuild.
  TextEditingController? _detailController;
  String? _detailControllerLineId;

  TextEditingController _detailControllerFor(ScriptLine line) {
    if (_detailControllerLineId != line.id) {
      _detailController?.dispose();
      _detailController = TextEditingController(text: line.text);
      _detailControllerLineId = line.id;
    }
    return _detailController!;
  }

  @override
  void dispose() {
    _detailController?.dispose();
    super.dispose();
  }

  /// Deterministic fallback path to the imported PDF, resolved from the current
  /// app Documents directory. The `scriptPath` stored on the production is an
  /// absolute path that can go stale across reinstalls (iOS rewrites the
  /// Documents container UUID), but the file lives at a stable relative
  /// location: `Documents/scripts/{productionId}.pdf`. We recover it here so the
  /// page viewer reappears for already-imported scripts. Null until resolved or
  /// when no file exists there.
  String? _resolvedPdfPath;

  @override
  void initState() {
    super.initState();
    _resolvePdfPath();
  }

  Future<void> _resolvePdfPath() async {
    final production = ref.read(currentProductionProvider);
    if (production == null) return;
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final candidate =
          p.join(docsDir.path, 'scripts', '${production.id}.pdf');
      if (File(candidate).existsSync() && mounted) {
        setState(() => _resolvedPdfPath = candidate);
      }
    } catch (_) {
      // Non-fatal — the viewer just stays hidden if we can't resolve a path.
    }
  }

  /// Returns a usable PDF path for the current production, preferring the
  /// persisted `scriptPath` when its file still exists, then falling back to the
  /// deterministic Documents location resolved in [_resolvePdfPath].
  String? _effectivePdfPath(Production? production) {
    final stored = production?.scriptPath;
    if (stored != null && File(stored).existsSync()) return stored;
    return _resolvedPdfPath;
  }

  @override
  Widget build(BuildContext context) {
    final script = ref.watch(currentScriptProvider);

    if (script == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Script Editor')),
        body: const Center(child: Text('No script loaded')),
      );
    }

    // Build character → color map
    final charColors = <String, Color>{};
    for (final char in script.characters) {
      charColors[char.name] = AppTheme.colorForCharacter(char.colorIndex);
    }

    final filteredLines = _filteredLines(script);

    return Scaffold(
      appBar: AppBar(
        title: Text(script.title),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.language),
            tooltip: 'Edit on web',
            onPressed: () {
              final production = ref.read(currentProductionProvider);
              final email = SupabaseService.instance.currentUser?.email ?? '';
              final productionName = production?.title ?? script.title;

              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  icon: const Icon(Icons.desktop_windows, size: 40),
                  title: const Text('Edit on a Big Screen'),
                  content: Text(
                    'Editing scripts is easier with a real keyboard and mouse. '
                    'Share this link to open the web editor in any browser — '
                    'your script syncs automatically via the cloud.'
                    '${email.isNotEmpty ? '\n\nSign in as: $email' : ''}',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Not Now'),
                    ),
                    FilledButton.icon(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await Future.delayed(const Duration(milliseconds: 300));
                        final box = context.findRenderObject() as RenderBox?;
                        final origin = box != null
                            ? box.localToGlobal(Offset.zero) & box.size
                            : null;
                        final productionId = production?.id ?? '';
                        final url = productionId.isNotEmpty
                            ? 'https://castcircle-app.web.app?production=$productionId'
                            : 'https://castcircle-app.web.app';
                        final text = 'Edit "$productionName" on the web:\n'
                            '$url\n'
                            '${email.isNotEmpty ? '\nSign in with: $email' : ''}';
                        Share.share(
                          text,
                          subject: 'CastCircle: Edit $productionName',
                          sharePositionOrigin: origin,
                        );
                      },
                      icon: const Icon(Icons.share),
                      label: const Text('Share Link'),
                    ),
                  ],
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.cloud_upload_outlined),
            tooltip: 'Sync to cloud',
            onPressed: () async {
              await persistScript(ref);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showAutoToast(
                  const SnackBar(
                    content: Text('Script synced to cloud'),
                    duration: Duration(seconds: 1),
                  ),
                );
              }
            },
          ),
          IconButton(
            icon: Icon(
              _showDirections ? Icons.speaker_notes : Icons.speaker_notes_off,
              color: _showDirections ? null : Colors.grey,
            ),
            tooltip: _showDirections
                ? 'Hide stage directions'
                : 'Show stage directions',
            onPressed: () =>
                setState(() => _showDirections = !_showDirections),
          ),
          IconButton(
            icon: Icon(
              Icons.swap_vert,
              color: _reorderMode ? Theme.of(context).colorScheme.primary : null,
            ),
            tooltip: _reorderMode ? 'Done reordering' : 'Reorder lines',
            onPressed: () => setState(() => _reorderMode = !_reorderMode),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: 'More',
            onSelected: (action) {
              switch (action) {
                case 'validate':
                  showValidationPanel(context, script);
                case 'export_text':
                  _export(context, script, 'plain');
                case 'export_md':
                  _export(context, script, 'markdown');
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'validate',
                child: ListTile(
                  leading: Icon(Icons.checklist),
                  title: Text('Validate Script'),
                  dense: true,
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'export_text',
                child: ListTile(
                  leading: Icon(Icons.text_snippet),
                  title: Text('Export as Text'),
                  dense: true,
                ),
              ),
              const PopupMenuItem(
                value: 'export_md',
                child: ListTile(
                  leading: Icon(Icons.article),
                  title: Text('Export as Markdown'),
                  dense: true,
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Character filter chips
          SizedBox(
            height: 56,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                FilterChip(
                  label: const Text('All'),
                  selected: _selectedCharacter == null && !_showLowConfidenceOnly,
                  onSelected: (_) =>
                      setState(() { _selectedCharacter = null; _showLowConfidenceOnly = false; }),
                ),
                const SizedBox(width: 8),
                if (script.lines.any((l) => l.ocrConfidence != null && l.ocrConfidence! < 0.85))
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      avatar: Icon(Icons.warning_amber_rounded, size: 16, color: Colors.amber.shade700),
                      label: Text(
                        'Low OCR (${script.lines.where((l) => l.ocrConfidence != null && l.ocrConfidence! < 0.85).length})',
                      ),
                      selected: _showLowConfidenceOnly,
                      selectedColor: Colors.amber.shade100,
                      onSelected: (_) => setState(() {
                        _showLowConfidenceOnly = !_showLowConfidenceOnly;
                        if (_showLowConfidenceOnly) _selectedCharacter = null;
                      }),
                    ),
                  ),
                ...script.characters.map((char) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        avatar: CircleAvatar(
                          backgroundColor: charColors[char.name],
                          radius: 8,
                        ),
                        label: Text(char.name),
                        selected: _selectedCharacter == char.name,
                        onSelected: (_) => setState(() {
                          _selectedCharacter =
                              _selectedCharacter == char.name
                                  ? null
                                  : char.name;
                        }),
                      ),
                    )),
              ],
            ),
          ),
          const Divider(height: 1),
          // Line count
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Text(
                  '${filteredLines.length} lines',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                if (_showLowConfidenceOnly)
                  Text(
                    'Showing low-confidence OCR lines',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.amber.shade700,
                        ),
                  )
                else if (_selectedCharacter != null)
                  Text(
                    'Showing $_selectedCharacter only',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: charColors[_selectedCharacter],
                        ),
                  ),
              ],
            ),
          ),
          // Reorder mode banner
          if (_reorderMode)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: Theme.of(context).colorScheme.tertiaryContainer,
              child: Row(
                children: [
                  Icon(Icons.swap_vert, size: 16,
                      color: Theme.of(context).colorScheme.onTertiaryContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Long press and drag to reorder',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onTertiaryContainer)),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _reorderMode = false),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
          // Script lines (with optional detail panel on tablets)
          Expanded(
            child: Responsive.isWide(context)
                ? Row(
                    children: [
                      // Line list (left side)
                      Expanded(
                        flex: 3,
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: filteredLines.length,
                          itemBuilder: (context, index) {
                            final line = filteredLines[index];
                            final isSelected = _selectedLine?.id == line.id;
                            return Container(
                              decoration: isSelected
                                  ? BoxDecoration(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primaryContainer
                                          .withValues(alpha: 0.3),
                                      borderRadius: BorderRadius.circular(8),
                                    )
                                  : null,
                              child: GestureDetector(
                                onTap: () => setState(() => _selectedLine = line),
                                child: AbsorbPointer(
                                  child: _buildLineCard(
                                      context, line, charColors),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      // Detail panel (right side)
                      Expanded(
                        flex: 2,
                        child: _selectedLine != null
                            ? _buildDetailPanel(context, _selectedLine!, charColors)
                            : Center(
                                child: Text(
                                  'Select a line to edit',
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.4),
                                  ),
                                ),
                              ),
                      ),
                    ],
                  )
                : _reorderMode && _selectedCharacter == null
                    ? ReorderableListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: filteredLines.length,
                        onReorder: (oldIndex, newIndex) {
                          _reorderLines(
                              script, filteredLines, oldIndex, newIndex);
                        },
                        itemBuilder: (context, index) {
                          return _buildLineCard(
                            context, filteredLines[index], charColors,
                            key: ValueKey(filteredLines[index].id),
                            showDragHandle: true,
                          );
                        },
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: filteredLines.length,
                        itemBuilder: (context, index) {
                          return _buildLineCard(
                              context, filteredLines[index], charColors);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  /// Tablet detail panel: shows PDF page + edit fields inline.
  Widget _buildDetailPanel(
    BuildContext context,
    ScriptLine line,
    Map<String, Color> charColors,
  ) {
    final production = ref.read(currentProductionProvider);
    final pdfPath = _effectivePdfPath(production);
    final hasPdf = pdfPath != null && line.sourcePage != null && File(pdfPath).existsSync();
    final textController = _detailControllerFor(line);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Row(
            children: [
              if (line.character.isNotEmpty) ...[
                CircleAvatar(
                  backgroundColor: charColors[line.character] ?? Colors.grey,
                  radius: 6,
                ),
                const SizedBox(width: 8),
                Text(line.character,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: charColors[line.character],
                    )),
                const SizedBox(width: 8),
              ],
              Text('Line #${line.orderIndex}  ${line.pageLineRef}',
                  style: Theme.of(context).textTheme.bodySmall),
              if (line.ocrConfidence != null && line.ocrConfidence! < 0.85) ...[
                const SizedBox(width: 8),
                Icon(Icons.warning_amber_rounded,
                    size: 16, color: Colors.amber.shade700),
                Text(' ${(line.ocrConfidence! * 100).toInt()}%',
                    style: TextStyle(
                        fontSize: 12, color: Colors.amber.shade700)),
              ],
            ],
          ),
          const SizedBox(height: 12),

          // PDF page viewer (if available)
          if (hasPdf)
            Expanded(
              flex: 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: Theme.of(context).colorScheme.outline, width: 0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: PdfPageView(
                    pdfPath: pdfPath,
                    pageNumber: line.sourcePage!,
                    lineOnPage: line.sourceLineOnPage,
                  ),
                ),
              ),
            ),
          if (hasPdf) const SizedBox(height: 12),

          // Text editor
          Expanded(
            flex: hasPdf ? 1 : 3,
            child: TextField(
              controller: textController,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                labelText: 'Line text',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Save button
          FilledButton(
            onPressed: () {
              _updateLine(line, line.character, textController.text.trim());
              setState(() => _selectedLine = null);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  List<ScriptLine> _filteredLines(ParsedScript script) {
    // Single pass (runs per build over the whole script) — the staged
    // .where().toList() version materialized up to five intermediate lists.
    final char = _selectedCharacter;
    final out = <ScriptLine>[];
    var firstCharIndex = -1;
    for (final l in script.lines) {
      if (!_showDirections && l.lineType == LineType.stageDirection) continue;
      if (_showLowConfidenceOnly) {
        if (l.ocrConfidence != null && l.ocrConfidence! < 0.85) out.add(l);
        continue;
      }
      if (char != null) {
        final isChars = l.isForCharacter(char);
        if (!isChars &&
            l.lineType != LineType.header &&
            l.lineType != LineType.stageDirection) {
          continue;
        }
        if (isChars && firstCharIndex < 0) firstCharIndex = out.length;
      }
      out.add(l);
    }
    // Trim headers and stage directions that appear before the character's
    // first actual line so the view starts at relevant content.
    if (char != null && !_showLowConfidenceOnly && firstCharIndex > 0) {
      return out.sublist(firstCharIndex);
    }
    return out;
  }

  void _reorderLines(ParsedScript script, List<ScriptLine> filteredLines,
      int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    if (oldIndex == newIndex) return;

    // Work on the full line list
    final allLines = script.lines.toList();
    final movedLine = filteredLines[oldIndex];
    final targetLine = filteredLines[newIndex];

    // Find positions in the full list
    final fromIdx = allLines.indexWhere((l) => l.id == movedLine.id);
    final toIdx = allLines.indexWhere((l) => l.id == targetLine.id);
    if (fromIdx < 0 || toIdx < 0) return;

    // Move the line
    allLines.removeAt(fromIdx);
    final insertAt = toIdx > fromIdx ? toIdx : toIdx;
    allLines.insert(insertAt, movedLine);

    // Reassign orderIndex
    final reindexed = <ScriptLine>[];
    for (var i = 0; i < allLines.length; i++) {
      reindexed.add(allLines[i].copyWith(orderIndex: i));
    }

    // Update script
    ref.read(currentScriptProvider.notifier).state = ParsedScript(
      title: script.title,
      lines: reindexed,
      characters: script.characters,
      scenes: script.scenes,
      rawText: script.rawText,
    );

    // Persist
    persistScript(ref);
  }

  Widget _buildLineCard(
    BuildContext context,
    ScriptLine line,
    Map<String, Color> charColors, {
    Key? key,
    bool showDragHandle = false,
  }) {
    switch (line.lineType) {
      case LineType.header:
        return Padding(
          key: key,
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            line.text,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
        );

      case LineType.stageDirection:
        return Padding(
          key: key,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Card(
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: 0.5),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                line.text,
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.6),
                ),
              ),
            ),
          ),
        );

      case LineType.dialogue:
      case LineType.song:
        final color =
            charColors[line.character] ?? Theme.of(context).colorScheme.primary;
        final hasLowConfidence =
            line.ocrConfidence != null && line.ocrConfidence! < 0.85;
        return Padding(
          key: key,
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: InkWell(
            onTap: () => _editLine(context, line),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              decoration: hasLowConfidence
                  ? BoxDecoration(
                      border: Border(
                        left: BorderSide(
                          color: Colors.amber.shade700,
                          width: 3,
                        ),
                      ),
                    )
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Page:line reference
                    SizedBox(
                      width: 42,
                      child: Text(
                        line.pageLineRef,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.35),
                              fontSize: 10,
                              fontFeatures: [const FontFeature.tabularFigures()],
                            ),
                      ),
                    ),
                    // Character color bar
                    Container(
                      width: 3,
                      height: 20,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Content
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                line.character,
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: color,
                                  fontSize: 13,
                                ),
                              ),
                              if (hasLowConfidence) ...[
                                const SizedBox(width: 4),
                                Tooltip(
                                  message:
                                      'OCR confidence: ${(line.ocrConfidence! * 100).toInt()}%',
                                  child: Icon(
                                    Icons.warning_amber_rounded,
                                    size: 14,
                                    color: Colors.amber.shade700,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          if (line.stageDirection.isNotEmpty)
                            Text(
                              '(${line.stageDirection})',
                              style: TextStyle(
                                fontStyle: FontStyle.italic,
                                fontSize: 12,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.5),
                              ),
                            ),
                          Text(line.text),
                        ],
                      ),
                    ),
                    if (showDragHandle)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Icon(Icons.drag_handle,
                            size: 20,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.3)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
    }
  }

  void _editLine(BuildContext context, ScriptLine line) {
    final textController = TextEditingController(text: line.text);
    final script = ref.read(currentScriptProvider);
    final production = ref.read(currentProductionProvider);
    final charNames = script?.characters.map((c) => c.name).toList() ?? [];
    var selectedChar = line.character;
    final newCharController = TextEditingController();
    var isNewChar = !charNames.contains(selectedChar) && selectedChar.isNotEmpty;

    // Check if we have a PDF source page to show
    final pdfPath = _effectivePdfPath(production);
    final hasPdfPage = pdfPath != null &&
        line.sourcePage != null &&
        File(pdfPath).existsSync();

    // Sheet-scoped controllers: disposed when the sheet closes —
    // they used to leak one pair per opened edit sheet for the whole
    // editing session.
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: hasPdfPage
          ? BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.92)
          : null,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) => Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
              left: 16,
              right: 16,
              top: 16,
            ),
            child: Column(
              mainAxisSize: hasPdfPage ? MainAxisSize.max : MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Header row ──
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Edit Line #${line.orderIndex}${line.sourcePage != null ? '  (p${line.sourcePage})' : ''}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    PopupMenuButton<String>(
                      icon: Icon(_lineTypeIcon(line.lineType), size: 20),
                      tooltip: 'Change line type',
                      onSelected: (type) {
                        _changeLineType(line, type);
                        Navigator.pop(context);
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                            value: 'dialogue', child: Text('Dialogue')),
                        const PopupMenuItem(
                            value: 'stageDirection',
                            child: Text('Stage Direction')),
                        const PopupMenuItem(
                            value: 'header', child: Text('Header')),
                        const PopupMenuItem(
                            value: 'song', child: Text('Song')),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.splitscreen, size: 20),
                      tooltip: 'Split line',
                      onPressed: () {
                        Navigator.pop(context);
                        _splitLine(context, line);
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline,
                          size: 20, color: Colors.red),
                      tooltip: 'Delete line',
                      onPressed: () {
                        _deleteLine(line);
                        Navigator.pop(context);
                      },
                    ),
                  ],
                ),

                // ── PDF page viewer (pinch-to-zoom) ──
                if (hasPdfPage) ...[
                  const SizedBox(height: 8),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outline,
                            width: 0.5,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: PdfPageView(
                          pdfPath: pdfPath,
                          pageNumber: line.sourcePage!,
                          lineOnPage: line.sourceLineOnPage,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],

                // ── Character selector ──
                if (line.lineType == LineType.dialogue ||
                    line.lineType == LineType.song) ...[
                  DropdownButtonFormField<String>(
                    value: isNewChar ? '__new__' : selectedChar,
                    decoration: const InputDecoration(
                      labelText: 'Character',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      ...charNames.map((name) => DropdownMenuItem(
                            value: name,
                            child: Text(name),
                          )),
                      const DropdownMenuItem(
                        value: '__new__',
                        child: Text('+ New character...'),
                      ),
                    ],
                    onChanged: (value) {
                      setModalState(() {
                        if (value == '__new__') {
                          isNewChar = true;
                          selectedChar = '';
                        } else {
                          isNewChar = false;
                          selectedChar = value ?? '';
                        }
                      });
                    },
                  ),
                  if (isNewChar) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: newCharController,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'New character name',
                        border: OutlineInputBorder(),
                        hintText: 'e.g. DARCY',
                        isDense: true,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                ],

                // ── Text editor ──
                TextField(
                  controller: textController,
                  maxLines: hasPdfPage ? 3 : 4,
                  decoration: InputDecoration(
                    labelText: 'Line text',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: line.ocrConfidence != null && line.ocrConfidence! < 0.85
                        ? Tooltip(
                            message: 'OCR confidence: ${(line.ocrConfidence! * 100).toInt()}%',
                            child: Icon(Icons.warning_amber_rounded,
                                color: Colors.amber.shade700, size: 20),
                          )
                        : null,
                  ),
                ),
                const SizedBox(height: 12),

                // ── Action buttons ──
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () {
                        final finalChar = isNewChar
                            ? newCharController.text.trim().toUpperCase()
                            : selectedChar;
                        _updateLine(
                          line,
                          finalChar,
                          textController.text.trim(),
                        );
                        Navigator.pop(context);
                      },
                      child: const Text('Save'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    ).whenComplete(() {
      textController.dispose();
      newCharController.dispose();
    });
  }

  IconData _lineTypeIcon(LineType type) {
    switch (type) {
      case LineType.dialogue:
        return Icons.chat_bubble_outline;
      case LineType.stageDirection:
        return Icons.directions_walk;
      case LineType.header:
        return Icons.title;
      case LineType.song:
        return Icons.music_note;
    }
  }

  void _changeLineType(ScriptLine line, String typeStr) {
    final script = ref.read(currentScriptProvider);
    if (script == null) return;

    final newType = LineType.values.byName(typeStr);
    final updatedLines = script.lines.map((l) {
      if (l.id == line.id) {
        return l.copyWith(
          lineType: newType,
          character: newType == LineType.stageDirection ||
                  newType == LineType.header
              ? ''
              : l.character,
        );
      }
      return l;
    }).toList();

    _rebuildScript(script, updatedLines);
  }

  void _splitLine(BuildContext context, ScriptLine line) {
    final controller = TextEditingController(text: line.text);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Split Line'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Place your cursor where you want to split, '
                'then tap Split.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 4,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Tap to position cursor at split point',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final pos = controller.selection.baseOffset;
              if (pos > 0 && pos < line.text.length) {
                _applySplit(line, pos);
              }
              Navigator.pop(context);
            },
            child: const Text('Split'),
          ),
        ],
      ),
    );
  }

  void _applySplit(ScriptLine line, int splitPos) {
    final script = ref.read(currentScriptProvider);
    if (script == null) return;

    final firstText = line.text.substring(0, splitPos).trim();
    final secondText = line.text.substring(splitPos).trim();
    if (firstText.isEmpty || secondText.isEmpty) return;

    final newLine = ScriptLine(
      // Fresh uuid, NOT "<id>_split": splitting the same line twice minted the
      // same id twice — duplicate ValueKeys crash the reorder list, and the
      // cloud push (which preserves ids) collapses or rejects the pair.
      id: const Uuid().v4(),
      act: line.act,
      scene: line.scene,
      lineNumber: line.lineNumber + 1,
      orderIndex: line.orderIndex + 1,
      character: line.character,
      text: secondText,
      lineType: line.lineType,
      stageDirection: '',
    );

    final updatedLines = <ScriptLine>[];
    for (final l in script.lines) {
      if (l.id == line.id) {
        updatedLines.add(l.copyWith(text: firstText));
        updatedLines.add(newLine);
      } else {
        updatedLines.add(l);
      }
    }

    _rebuildScript(script, updatedLines);
  }

  void _deleteLine(ScriptLine line) {
    final script = ref.read(currentScriptProvider);
    if (script == null) return;
    AnalyticsService.instance.logScriptEdited(action: 'delete_line');

    final updatedLines =
        script.lines.where((l) => l.id != line.id).toList();
    _rebuildScript(script, updatedLines);
  }

  void _rebuildScript(ParsedScript script, List<ScriptLine> updatedLines) {
    final charCounts = <String, int>{};
    for (final line in updatedLines) {
      if (line.lineType == LineType.dialogue && line.character.isNotEmpty) {
        charCounts[line.character] = (charCounts[line.character] ?? 0) + 1;
      }
    }
    // Carry genders across the rebuild. ScriptCharacter defaults to female, so
    // omitting this reset the WHOLE cast's gender on any line edit — and the
    // autosave below then persisted it, giving every male character a female
    // voice for the rest of the session.
    final existingGenders = {
      for (final c in script.characters) c.name: c.gender,
    };
    var colorIdx = 0;
    final characters = charCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final charList = characters
        .map((e) => ScriptCharacter(
              name: e.key,
              colorIndex: colorIdx++,
              lineCount: e.value,
              gender: existingGenders[e.key] ?? CharacterGender.female,
            ))
        .toList();

    ref.read(currentScriptProvider.notifier).state = ParsedScript(
      title: script.title,
      lines: updatedLines,
      characters: charList,
      scenes: script.scenes,
      rawText: script.rawText,
    );
    // Editor mutations used to live in memory only — an app kill, or
    // simply opening another production, silently discarded them.
    scheduleScriptSave(ref);
  }

  void _updateLine(ScriptLine original, String newChar, String newText) {
    final script = ref.read(currentScriptProvider);
    if (script == null) return;
    AnalyticsService.instance.logScriptEdited(action: 'edit_line');

    final updatedLines = script.lines.map((l) {
      if (l.id == original.id) {
        return l.copyWith(character: newChar, text: newText);
      }
      return l;
    }).toList();

    // Recalculate characters
    final charCounts = <String, int>{};
    for (final line in updatedLines) {
      if (line.lineType == LineType.dialogue && line.character.isNotEmpty) {
        charCounts[line.character] = (charCounts[line.character] ?? 0) + 1;
      }
    }
    // Same gender preservation as _rebuildScript — without it, editing a
    // single line's text resets every character's gender.
    final existingGenders = {
      for (final c in script.characters) c.name: c.gender,
    };
    var colorIdx = 0;
    final characters = charCounts.entries
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final charList = characters
        .map((e) => ScriptCharacter(
              name: e.key,
              colorIndex: colorIdx++,
              lineCount: e.value,
              gender: existingGenders[e.key] ?? CharacterGender.female,
            ))
        .toList();

    ref.read(currentScriptProvider.notifier).state = ParsedScript(
      title: script.title,
      lines: updatedLines,
      characters: charList,
      scenes: script.scenes,
      rawText: script.rawText,
    );
    // Editor mutations used to live in memory only — an app kill, or
    // simply opening another production, silently discarded them.
    scheduleScriptSave(ref);
  }

  Future<void> _syncToCloud(BuildContext context) async {
    try {
      await pushScriptToCloud(ref);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showAutoToast(
          const SnackBar(content: Text('Script pushed to cloud')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showAutoToast(
          SnackBar(content: Text('Cloud sync failed: $e')),
        );
      }
    }
  }

  Future<void> _export(
    BuildContext context,
    ParsedScript script,
    String format,
  ) async {
    try {
      String content;
      String fileName;

      switch (format) {
        case 'markdown':
          content = ScriptExporter.toMarkdown(script);
          fileName = '${_safeName(script.title)}.md';
          break;
        case 'character':
          content =
              ScriptExporter.toCharacterLines(script, _selectedCharacter!);
          fileName =
              '${_safeName(script.title)}_${_safeName(_selectedCharacter!)}.txt';
          break;
        case 'cue':
          content = ScriptExporter.toCueScript(script, _selectedCharacter!);
          fileName =
              '${_safeName(script.title)}_${_safeName(_selectedCharacter!)}_cues.txt';
          break;
        default:
          content = ScriptExporter.toPlainText(script);
          fileName = '${_safeName(script.title)}.txt';
      }

      // Save to temp dir and share
      final dir = await getApplicationDocumentsDirectory();
      final exportDir = Directory(p.join(dir.path, 'exports'));
      if (!exportDir.existsSync()) {
        exportDir.createSync(recursive: true);
      }
      final filePath = p.join(exportDir.path, fileName);
      await File(filePath).writeAsString(content);

      if (!context.mounted) return;

      // Show share sheet — sharePositionOrigin required on iPad/iPhone
      final box = context.findRenderObject() as RenderBox?;
      await Share.shareXFiles(
        [XFile(filePath, mimeType: 'text/plain')],
        text: 'CastCircle export: ${script.title}',
        sharePositionOrigin: box != null
            ? box.localToGlobal(Offset.zero) & box.size
            : Rect.zero,
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showAutoToast(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  String _safeName(String name) {
    return name
        .replaceAll(RegExp(r'[^\w\s-]'), '')
        .replaceAll(RegExp(r'\s+'), '_')
        .toLowerCase();
  }
}
