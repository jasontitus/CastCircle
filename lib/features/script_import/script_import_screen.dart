import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/responsive.dart';
import '../../data/models/script_models.dart';
import '../../data/services/analytics_service.dart';
import '../../data/services/debug_log_service.dart';
import '../../data/services/paddle_ocr_channel.dart';
import '../../data/services/script_parser.dart';
import '../../data/services/supabase_service.dart';
import '../../data/services/voice_config_service.dart';
import '../../providers/production_providers.dart';
import 'ocr_review_screen.dart';
import '../../core/toast.dart';

class ScriptImportScreen extends ConsumerStatefulWidget {
  const ScriptImportScreen({super.key});

  @override
  ConsumerState<ScriptImportScreen> createState() => _ScriptImportScreenState();
}

class _ScriptImportScreenState extends ConsumerState<ScriptImportScreen> {
  bool _loading = false;
  bool _saving = false;
  String? _error;
  ParsedScript? _preview;
  String? _importedPdfPath; // copy of the imported PDF for the page viewer

  /// True while [_importedPdfPath] points at the staging copy in the temp dir,
  /// i.e. before the user accepted the import. See [_commitStagedPdf].
  bool _pdfPendingCommit = false;

  @override
  Widget build(BuildContext context) {
    final production = ref.watch(currentProductionProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(production?.title ?? 'Import Script'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: _loading
          ? _buildLoading(context)
          : _preview != null
          ? _buildPreview(context)
          : _buildImportOptions(context),
    );
  }

  /// Loading view. For scanned PDFs the native PaddleOCR pass can take a while,
  /// so surface its per-page progress (pushed via [PaddleOcrChannel.progress])
  /// instead of an indeterminate spinner that looks frozen.
  Widget _buildLoading(BuildContext context) {
    return Center(
      child: ValueListenableBuilder<OcrProgress?>(
        valueListenable: PaddleOcrChannel.progress,
        builder: (context, ocr, _) {
          final reading = ocr != null && ocr.total > 0;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (reading)
                SizedBox(
                  width: 220,
                  child: LinearProgressIndicator(value: ocr.page / ocr.total),
                )
              else
                const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                reading
                    ? 'Reading page ${ocr.page} of ${ocr.total}…'
                    : (ocr != null ? 'Reading PDF…' : 'Parsing script…'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildImportOptions(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.description_outlined,
                size: 80,
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 24),
              Text(
                'Import Your Script',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Upload a script file to get started.\n'
                'Supported: .txt, .pdf (with OCR)',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: _pickTextFile,
                icon: const Icon(Icons.upload_file),
                label: const Text('Import Text File'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _pickMarkdownFile,
                icon: const Icon(Icons.article),
                label: const Text('Import Markdown'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _pickPdfFile,
                icon: const Icon(Icons.picture_as_pdf),
                label: const Text('Import PDF'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 24),
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // (dialogue, review, notScript) counts in one pass, memoized on the line
  // list identity — three separate full scans re-ran on every preview
  // setState (dialect taps, the _saving toggles).
  (List<ScriptLine>, int, int, int)? _previewCounts;
  (int, int, int) _countsFor(ParsedScript script) {
    final cached = _previewCounts;
    if (cached != null && identical(cached.$1, script.lines)) {
      return (cached.$2, cached.$3, cached.$4);
    }
    var dialogue = 0, review = 0, notScript = 0;
    for (final l in script.lines) {
      if (l.lineType == LineType.dialogue) dialogue++;
      switch (l.reviewStatus) {
        case OcrReviewStatus.review:
          review++;
        case OcrReviewStatus.likelyNotScript:
          notScript++;
        case OcrReviewStatus.ok:
          break;
      }
    }
    _previewCounts = (script.lines, dialogue, review, notScript);
    return (dialogue, review, notScript);
  }

  Widget _buildPreview(BuildContext context) {
    final script = _preview!;
    final (dialogueCount, _, _) = _countsFor(script);

    return Column(
      children: [
        // Stats bar
        Container(
          padding: const EdgeInsets.all(16),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _statBadge(context, '$dialogueCount', 'Lines'),
              _statBadge(context, '${script.characters.length}', 'Characters'),
              _statBadge(context, '${script.acts.length}', 'Acts'),
            ],
          ),
        ),
        // Dialect selector
        _buildDialectSelector(context),
        // OCR review banner (only when low-OCR lines were detected)
        _buildReviewBanner(context, script),
        // Character list
        Expanded(
          child: ContentConstraint(
            maxWidth: 720,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Characters Found',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                ...script.characters.map(
                  (char) => ListTile(
                    leading: CircleAvatar(
                      backgroundColor: _colorForIndex(char.colorIndex),
                      radius: 16,
                      child: Text(
                        char.name[0],
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    title: Text(char.name),
                    trailing: Text('${char.lineCount} lines'),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Script Preview',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                ...script.lines.take(30).map((line) => _buildLinePreview(line)),
                if (script.lines.length > 30)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      '... and ${script.lines.length - 30} more lines',
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
          ),
        ),
        // Action buttons
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => setState(() {
                      _preview = null;
                      _error = null;
                      // Drop the staged PDF too, or a following text import
                      // would commit the abandoned PDF as this script's source.
                      _importedPdfPath = null;
                      _pdfPendingCommit = false;
                    }),
                    child: const Text('Re-import'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _saving ? null : () => _acceptScript(script),
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.check),
                    label: Text(_saving ? 'Saving...' : 'Accept Script'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static const _localeLabels = {
    'en-US': 'American English',
    'en-GB': 'British English',
  };

  Widget _buildDialectSelector(BuildContext context) {
    final production = ref.watch(currentProductionProvider);
    if (production == null) return const SizedBox.shrink();
    final label = _localeLabels[production.locale] ?? production.locale;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.language,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              const Text('Script dialect'),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              segments: _localeLabels.entries
                  .map((e) => ButtonSegment(value: e.key, label: Text(e.value)))
                  .toList(),
              selected: {production.locale},
              onSelectionChanged: (selected) {
                final locale = selected.first;
                final updated = production.copyWith(locale: locale);
                ref.read(productionsProvider.notifier).update(updated);
                ref.read(currentProductionProvider.notifier).state = updated;
                final presetId = locale == 'en-GB'
                    ? 'victorian_english'
                    : 'modern_american';
                VoiceConfigService.instance.setPreset(production.id, presetId);
                // Sync locale and voice preset to cloud
                final supa = SupabaseService.instance;
                if (supa.isSignedIn) {
                  supa.saveLocale(productionId: production.id, locale: locale);
                  supa.saveVoicePreset(
                    productionId: production.id,
                    presetId: presetId,
                  );
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Banner surfacing low-OCR lines flagged for review. Hidden when the import
  /// was clean (no `review` / `likelyNotScript` lines).
  Widget _buildReviewBanner(BuildContext context, ParsedScript script) {
    final (_, reviewCount, notScriptCount) = _countsFor(script);
    if (reviewCount == 0 && notScriptCount == 0) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: theme.colorScheme.tertiaryContainer,
      child: Row(
        children: [
          Icon(
            Icons.spellcheck,
            size: 20,
            color: theme.colorScheme.onTertiaryContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$reviewCount lines to review, '
              '$notScriptCount likely-not-script',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: () => _openReview(context),
            child: const Text('Review'),
          ),
        ],
      ),
    );
  }

  Future<void> _openReview(BuildContext context) async {
    final script = _preview;
    if (script == null) return;
    final result = await Navigator.of(context).push<OcrReviewResult>(
      MaterialPageRoute(
        builder: (_) =>
            OcrReviewScreen(lines: script.lines, pdfPath: _importedPdfPath),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _preview = ParsedScript(
        title: script.title,
        lines: result.lines,
        // Scene ranges are positional — removing review lines shifts every
        // later scene, which rehearsal (linesInScene) would then play from
        // the wrong part of the script.
        scenes: ParsedScript.remapScenes(
            script.scenes, script.lines, result.lines),
        // Recount characters from the surviving lines: a character whose
        // only lines were removed in review used to linger in the preview's
        // cast list with a stale line count until the next DB reload.
        characters: _recountCharacters(script.characters, result.lines),
        rawText: script.rawText,
      );
    });
  }

  /// Rebuild the character list from [lines], preserving gender (and keeping
  /// colorIndex stable by list position, like the parser does).
  static List<ScriptCharacter> _recountCharacters(
      List<ScriptCharacter> existing, List<ScriptLine> lines) {
    final genders = {for (final c in existing) c.name: c.gender};
    final counts = <String, int>{};
    for (final line in lines) {
      if (line.lineType != LineType.dialogue) continue;
      if (line.multiCharacters.isNotEmpty) {
        for (final char in line.multiCharacters) {
          counts[char] = (counts[char] ?? 0) + 1;
        }
      } else if (line.character.isNotEmpty) {
        counts[line.character] = (counts[line.character] ?? 0) + 1;
      }
    }
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      for (final (i, e) in sorted.indexed)
        ScriptCharacter(
          name: e.key,
          colorIndex: i,
          lineCount: e.value,
          gender: genders[e.key] ?? ScriptParser.inferGender(e.key),
        ),
    ];
  }

  Widget _statBadge(BuildContext context, String value, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: Theme.of(
            context,
          ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _buildLinePreview(ScriptLine line) {
    switch (line.lineType) {
      case LineType.header:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            line.text,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
          ),
        );
      case LineType.stageDirection:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            line.text,
            style: TextStyle(
              fontStyle: FontStyle.italic,
              color: Colors.grey[500],
            ),
          ),
        );
      case LineType.dialogue:
      case LineType.song:
        final charIndex = line.character.hashCode.abs();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: '${line.character}. ',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: _colorForIndex(charIndex),
                  ),
                ),
                if (line.stageDirection.isNotEmpty)
                  TextSpan(
                    text: '(${line.stageDirection}) ',
                    style: TextStyle(
                      fontStyle: FontStyle.italic,
                      color: Colors.grey[500],
                    ),
                  ),
                TextSpan(
                  text: line.text,
                  style: TextStyle(color: Colors.grey[300]),
                ),
              ],
            ),
          ),
        );
    }
  }

  Color _colorForIndex(int index) {
    const colors = [
      Color(0xFF64B5F6),
      Color(0xFFE57373),
      Color(0xFF81C784),
      Color(0xFFFFB74D),
      Color(0xFFBA68C8),
      Color(0xFF4DD0E1),
      Color(0xFFFF8A65),
      Color(0xFFA1887F),
    ];
    return colors[index.abs() % colors.length];
  }

  /// Take the previewed import: promote the staged PDF, save the script, and
  /// open the production hub.
  Future<void> _acceptScript(ParsedScript script) async {
    setState(() => _saving = true);
    try {
      await _commitStagedPdf();
      if (!mounted) return;
      ref.read(currentScriptProvider.notifier).state = script;
      AnalyticsService.instance.logScriptImported(
        format: _importedPdfPath != null ? 'pdf' : 'text',
        lineCount: script.lines.length,
        characterCount: script.characters.length,
      );
      await persistScript(ref);
      if (!mounted) return;
      context.push('/production');
    } catch (e, stack) {
      DebugLogService.instance.logError(
          LogCategory.general, 'Accepting imported script failed', e, stack);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showAutoToast(SnackBar(
        content: Text("Couldn't save the imported script — it has NOT been "
            'added to this production. $e'),
        duration: const Duration(seconds: 8),
      ));
    } finally {
      // Or the button sticks on "Saving..." forever after a failure.
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Move the staged PDF to `Documents/scripts/{productionId}.pdf` and record
  /// it on the production. Deferred until the user accepts: that destination
  /// holds the PREVIOUS script's source PDF, and overwriting it at import time
  /// leaves every "view page" showing the wrong document if they back out.
  Future<void> _commitStagedPdf() async {
    final staged = _importedPdfPath;
    if (!_pdfPendingCommit || staged == null) return;
    final production = ref.read(currentProductionProvider);
    if (production == null) {
      // Shouldn't happen — staging only starts with a production open — but
      // dropping the PDF without a word would break the page viewer later.
      DebugLogService.instance.logError(LogCategory.general,
          'Staged PDF not committed — no production is open');
      return;
    }

    final docsDir = await getApplicationDocumentsDirectory();
    final pdfDir = Directory(p.join(docsDir.path, 'scripts'));
    if (!pdfDir.existsSync()) pdfDir.createSync(recursive: true);
    final destPath = p.join(pdfDir.path, '${production.id}.pdf');
    // Copy beside the destination and rename into place: copying straight onto
    // destPath truncates the previous script's PDF if it fails part-way.
    final incoming = await File(staged).copy('$destPath.incoming');
    await incoming.rename(destPath);
    try {
      await File(staged).delete();
    } catch (e) {
      // Only a leftover temp file — the import itself succeeded.
      DebugLogService.instance
          .logError(LogCategory.general, 'Staged PDF cleanup failed', e);
    }

    if (!mounted) return;
    _pdfPendingCommit = false;
    _importedPdfPath = destPath;
    final updated = production.copyWith(scriptPath: destPath);
    ref.read(productionsProvider.notifier).update(updated);
    ref.read(currentProductionProvider.notifier).state = updated;
  }

  Future<void> _pickPdfFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );

      if (result == null || result.files.isEmpty) return;

      final filePath = result.files.first.path;
      if (filePath == null) return;
      if (!mounted) return;

      setState(() {
        _loading = true;
        _error = null;
      });

      final service = ref.read(scriptImportServiceProvider);

      try {
        // OCR of a scanned script runs for minutes, and back works throughout —
        // every step after this await has to re-check that we're still here.
        final script = await service.importFromPdf(filePath);
        if (!mounted) return;

        // Stage the PDF in the temp dir so the page viewer works during review.
        // It only replaces the production's stored PDF on Accept
        // (see [_commitStagedPdf]).
        final production = ref.read(currentProductionProvider);
        if (production != null) {
          final tmpDir = await getTemporaryDirectory();
          if (!mounted) return;
          final stagedPath = p.join(tmpDir.path, '${production.id}.staged.pdf');
          await File(filePath).copy(stagedPath);
          if (!mounted) return;
          _importedPdfPath = stagedPath;
          _pdfPendingCommit = true;
        }

        setState(() {
          _preview = script;
          _loading = false;
        });

        // A scan with unreadable pages produces a clean-LOOKING preview that
        // is silently missing scenes — warn now, not at rehearsal.
        final failed = service.lastImportFailedPages;
        if (failed > 0) {
          ScaffoldMessenger.of(context).showAutoToast(SnackBar(
            content: Text('$failed page(s) couldn\'t be read — parts of the '
                'script may be missing. Check the preview against the PDF.'),
            duration: const Duration(seconds: 8),
          ));
        }
      } on UnimplementedError catch (e) {
        // ML Kit not available — show helpful message
        DebugLogService.instance
            .logError(LogCategory.general, 'PDF import unavailable', e);
        if (!mounted) return;
        setState(() {
          _error =
              'PDF import requires Google ML Kit Text Recognition.\n'
              'Add google_mlkit_text_recognition to pubspec.yaml, '
              'or convert your PDF to a text file first.';
          _loading = false;
        });
      }
    } catch (e, stack) {
      DebugLogService.instance
          .logError(LogCategory.general, 'PDF import failed', e, stack);
      if (!mounted) return;
      setState(() {
        _error = 'Failed to import PDF: $e';
        _loading = false;
      });
    }
  }

  Future<void> _pickMarkdownFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['md', 'markdown', 'txt'],
      );

      if (result == null || result.files.isEmpty) return;

      final filePath = result.files.first.path;
      if (filePath == null) return;
      if (!mounted) return;

      setState(() {
        _loading = true;
        _error = null;
      });

      final service = ref.read(scriptImportServiceProvider);
      final script = await service.importFromMarkdownFile(filePath);
      if (!mounted) return;

      setState(() {
        _preview = script;
        _loading = false;
      });
    } catch (e, stack) {
      DebugLogService.instance
          .logError(LogCategory.general, 'Markdown import failed', e, stack);
      if (!mounted) return;
      setState(() {
        _error = 'Failed to import markdown: $e';
        _loading = false;
      });
    }
  }

  Future<void> _pickTextFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'text'],
      );

      if (result == null || result.files.isEmpty) return;

      final filePath = result.files.first.path;
      if (filePath == null) return;
      if (!mounted) return;

      setState(() {
        _loading = true;
        _error = null;
      });

      final service = ref.read(scriptImportServiceProvider);
      final script = await service.importFromTextFile(filePath);
      if (!mounted) return;

      setState(() {
        _preview = script;
        _loading = false;
      });
    } catch (e, stack) {
      DebugLogService.instance
          .logError(LogCategory.general, 'Text import failed', e, stack);
      if (!mounted) return;
      setState(() {
        _error = 'Failed to import script: $e';
        _loading = false;
      });
    }
  }
}
