import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/responsive.dart';
import '../../data/models/script_models.dart';
import '../../data/models/production_models.dart';
import '../../data/services/analytics_service.dart';
import '../../data/services/debug_log_service.dart';
import '../../data/services/paddle_ocr_channel.dart';
import '../../data/services/script_parser.dart';
import '../../data/services/script_import_service.dart';
import '../../data/services/supabase_service.dart';
import '../../data/services/voice_config_service.dart';
import '../../providers/production_providers.dart';
import 'ocr_review_screen.dart';
import '../../core/toast.dart';

class _PreparedPdfCommit {
  const _PreparedPdfCommit({
    required this.staged,
    required this.incoming,
    required this.destination,
    required this.backup,
    required this.ownsStaged,
  });

  final File staged;
  final File incoming;
  final File destination;
  final File? backup;
  final bool ownsStaged;
}

class _PdfPromotionRollbackException implements Exception {
  const _PdfPromotionRollbackException(this.promotionError, this.rollbackError);

  final Object promotionError;
  final Object rollbackError;

  @override
  String toString() =>
      'PDF promotion failed ($promotionError), then rollback failed '
      '($rollbackError)';
}

class ScriptImportScreen extends ConsumerStatefulWidget {
  const ScriptImportScreen({super.key});

  @override
  ConsumerState<ScriptImportScreen> createState() => _ScriptImportScreenState();
}

class _ScriptImportScreenState extends ConsumerState<ScriptImportScreen> {
  bool _loading = false;
  bool _saving = false;
  bool _mutationInFlight = false;
  String? _error;
  ParsedScript? _preview;
  late final ScriptImportService _importService;
  String? _importedPdfPath; // copy of the imported PDF for the page viewer

  /// True while [_importedPdfPath] is waiting to be committed.
  bool _pdfPendingCommit = false;

  /// Whether the pending PDF is our temporary staging copy rather than the
  /// picker-owned source used as a review fallback.
  bool _pdfStagingOwned = false;

  @override
  void initState() {
    super.initState();
    _importService = ref.read(scriptImportServiceProvider);
  }

  @override
  void dispose() {
    unawaited(_cancelOcrOnDispose());
    super.dispose();
  }

  Future<void> _cancelOcrOnDispose() async {
    try {
      await _importService.cancelActiveOcr();
    } catch (e, stack) {
      DebugLogService.instance.logError(
        LogCategory.general,
        'Cancelling abandoned PDF import failed',
        e,
        stack,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final production = ref.watch(currentProductionProvider);
    final mutationInFlight = _mutationInFlight;

    return PopScope(
      canPop: !mutationInFlight,
      child: Scaffold(
        appBar: AppBar(
          title: Text(production?.title ?? 'Import Script'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: mutationInFlight ? null : () => context.pop(),
          ),
        ),
        body: _loading
            ? _buildLoading(context)
            : _preview != null
            ? _buildPreview(context)
            : _buildImportOptions(context),
      ),
    );
  }

  /// Loading view. For scanned PDFs the native OCR pass can take a while, so
  /// surface request-scoped progress instead of an indeterminate spinner that
  /// looks frozen.
  Widget _buildLoading(BuildContext context) {
    return Center(
      child: ValueListenableBuilder<OcrProgress?>(
        valueListenable: _importService.ocrProgress,
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
    final characterColorIndices = {
      for (final character in script.characters)
        character.name: character.colorIndex,
    };

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
                ...script.lines.take(30).map((line) {
                  final colorName = line.multiCharacters.isNotEmpty
                      ? line.multiCharacters.first
                      : line.character;
                  return _buildLinePreview(
                    line,
                    characterColorIndices[colorName] ?? 0,
                  );
                }),
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
                      _importedPdfPath = null;
                      _pdfPendingCommit = false;
                      _pdfStagingOwned = false;
                    }),
                    child: const Text('Re-import'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _mutationInFlight
                        ? null
                        : () => _acceptScript(script),
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
    final selectedLocale = _localeLabels.containsKey(production.locale)
        ? production.locale
        : 'en-US';

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
              selected: {selectedLocale},
              onSelectionChanged: _mutationInFlight
                  ? null
                  : (selected) => _setDialect(production, selected.first),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _setDialect(Production production, String locale) async {
    if (_mutationInFlight || locale == production.locale) return;
    setState(() {
      _mutationInFlight = true;
    });

    final supa = SupabaseService.instance;
    final voiceService = VoiceConfigService.instance;
    final productionsNotifier = ref.read(productionsProvider.notifier);
    final currentProductionNotifier = ref.read(
      currentProductionProvider.notifier,
    );
    final presetId = locale == 'en-GB'
        ? 'victorian_english'
        : 'modern_american';
    var previousPresetId = production.locale == 'en-GB'
        ? 'victorian_english'
        : 'modern_american';

    try {
      previousPresetId = (await voiceService.getPreset(
        production.id,
        locale: production.locale,
      )).id;
      if (supa.isSignedIn) {
        await Future.wait([
          supa.saveLocale(productionId: production.id, locale: locale),
          supa.saveVoicePreset(productionId: production.id, presetId: presetId),
        ]);
      }
      await voiceService.setPreset(production.id, presetId);
      final latest = currentProductionNotifier.state;
      if (latest == null || latest.id != production.id) {
        throw StateError('Production changed while updating its dialect');
      }
      final updated = latest.copyWith(locale: locale);
      await productionsNotifier.update(updated);
      currentProductionNotifier.state = updated;
    } catch (e, stack) {
      var rollbackFailed = false;
      final latest = currentProductionNotifier.state;
      final rollbackBase = latest != null && latest.id == production.id
          ? latest
          : production;
      final restoredProduction = rollbackBase.copyWith(
        locale: production.locale,
      );
      try {
        await productionsNotifier.update(restoredProduction);
      } catch (rollbackError, rollbackStack) {
        rollbackFailed = true;
        DebugLogService.instance.logError(
          LogCategory.general,
          'Dialect production rollback failed',
          rollbackError,
          rollbackStack,
        );
      }
      currentProductionNotifier.state = restoredProduction;
      try {
        await voiceService.setPreset(production.id, previousPresetId);
      } catch (rollbackError, rollbackStack) {
        rollbackFailed = true;
        DebugLogService.instance.logError(
          LogCategory.general,
          'Dialect preset rollback failed',
          rollbackError,
          rollbackStack,
        );
      }
      if (supa.isSignedIn) {
        try {
          await Future.wait([
            supa.saveLocale(
              productionId: production.id,
              locale: production.locale,
            ),
            supa.saveVoicePreset(
              productionId: production.id,
              presetId: previousPresetId,
            ),
          ]);
        } catch (rollbackError, rollbackStack) {
          rollbackFailed = true;
          DebugLogService.instance.logError(
            LogCategory.network,
            'Dialect cloud rollback failed',
            rollbackError,
            rollbackStack,
          );
        }
      }
      DebugLogService.instance.logError(
        LogCategory.network,
        'Updating script dialect failed',
        e,
        stack,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showAutoToast(
          SnackBar(
            content: Text(
              rollbackFailed
                  ? "Couldn't update the script dialect, and the previous "
                        'setting could not be fully restored.'
                  : "Couldn't update the script dialect. The previous setting "
                        'was restored.',
            ),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _mutationInFlight = false;
        });
      }
    }
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
          script.scenes,
          script.lines,
          result.lines,
        ),
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
    List<ScriptCharacter> existing,
    List<ScriptLine> lines,
  ) {
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

  static Production _withScriptPath(
    Production production,
    String? scriptPath,
  ) => Production(
    id: production.id,
    title: production.title,
    organizerId: production.organizerId,
    createdAt: production.createdAt,
    status: production.status,
    scriptPath: scriptPath,
    locale: production.locale,
    joinCode: production.joinCode,
  );

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

  Widget _buildLinePreview(ScriptLine line, int characterColorIndex) {
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
        final charIndex = characterColorIndex;
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

  /// Persist the preview while the PDF is still staged, then atomically
  /// promote the PDF and publish the production/provider changes.
  Future<void> _acceptScript(ParsedScript script) async {
    if (_mutationInFlight) return;
    final production = ref.read(currentProductionProvider);
    if (production == null) return;
    final previousScript = ref.read(currentScriptProvider);
    var cloudMayHaveChanged = false;
    _PreparedPdfCommit? preparedPdf;
    var scriptWasApplied = false;
    var pdfPromotionAttempted = false;

    setState(() {
      _mutationInFlight = true;
      _saving = true;
    });
    try {
      preparedPdf = await _prepareStagedPdf(production);
      ref.read(currentScriptProvider.notifier).state = script;
      scriptWasApplied = true;
      await persistScriptLocally(ref, production.id, script);
      if (SupabaseService.instance.currentUser?.id == production.organizerId) {
        // The cloud call can save script lines before failing on scenes or an
        // account-epoch check. From this point rollback must strictly restore
        // the prior cloud script rather than trusting local-first persistence.
        cloudMayHaveChanged = true;
        try {
          await pushScriptToCloud(ref);
        } catch (cloudError, cloudStack) {
          DebugLogService.instance.logError(
            LogCategory.network,
            'Imported script cloud push failed',
            cloudError,
            cloudStack,
          );
          if (mounted) {
            ScaffoldMessenger.of(context).showAutoToast(
              const SnackBar(
                content: Text(
                  "Couldn't sync the imported script to the cast. It is saved "
                  'on this device.',
                ),
                duration: Duration(seconds: 6),
              ),
            );
          }
        }
      }
      if (preparedPdf != null) {
        pdfPromotionAttempted = true;
        await _promotePreparedPdf(preparedPdf, production);
      }
    } catch (e, stack) {
      var restored = e is! _PdfPromotionRollbackException;
      if (scriptWasApplied) {
        try {
          await _restorePreviousScript(
            previousScript,
            production,
            restoreCloud: cloudMayHaveChanged,
          );
        } catch (rollbackError, rollbackStack) {
          restored = false;
          DebugLogService.instance.logError(
            LogCategory.general,
            'Imported script rollback failed',
            rollbackError,
            rollbackStack,
          );
        }
      }
      await _discardPreparedPdf(
        preparedPdf,
        preserveBackup: pdfPromotionAttempted,
      );
      DebugLogService.instance.logError(
        LogCategory.general,
        'Accepting imported script failed',
        e,
        stack,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showAutoToast(
          SnackBar(
            content: Text(
              restored
                  ? "Couldn't save the imported script. The previous script and "
                        'PDF are unchanged. $e'
                  : "Couldn't finish saving the imported script, and the "
                        'previous state could not be fully restored. $e',
            ),
            duration: const Duration(seconds: 8),
          ),
        );
      }
      return;
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _mutationInFlight = false;
        });
      }
    }

    AnalyticsService.instance.logScriptImported(
      format: _importedPdfPath != null ? 'pdf' : 'text',
      lineCount: script.lines.length,
      characterCount: script.characters.length,
    );
    if (mounted) context.push('/production');
  }

  Future<_PreparedPdfCommit?> _prepareStagedPdf(Production production) async {
    final stagedPath = _importedPdfPath;
    if (!_pdfPendingCommit || stagedPath == null) return null;

    final docsDir = await getApplicationDocumentsDirectory();
    final pdfDir = Directory(p.join(docsDir.path, 'scripts'));
    await pdfDir.create(recursive: true);
    final destination = File(p.join(pdfDir.path, '${production.id}.pdf'));
    final incoming = File('${destination.path}.incoming');
    try {
      await File(stagedPath).copy(incoming.path);

      File? backup;
      if (await destination.exists()) {
        backup = File('${destination.path}.previous');
        if (await backup.exists()) await backup.delete();
        await destination.copy(backup.path);
      }
      return _PreparedPdfCommit(
        staged: File(stagedPath),
        incoming: incoming,
        destination: destination,
        backup: backup,
        ownsStaged: _pdfStagingOwned,
      );
    } catch (_) {
      if (await incoming.exists()) await incoming.delete();
      rethrow;
    }
  }

  Future<void> _promotePreparedPdf(
    _PreparedPdfCommit prepared,
    Production production,
  ) async {
    final productionsNotifier = ref.read(productionsProvider.notifier);
    final currentProductionNotifier = ref.read(
      currentProductionProvider.notifier,
    );
    try {
      // POSIX rename replaces the destination atomically on every platform
      // this app ships on, so the previous PDF is never absent between file
      // operations.
      await prepared.incoming.rename(prepared.destination.path);
      final latest = currentProductionNotifier.state;
      if (latest == null || latest.id != production.id) {
        throw StateError('Production changed while promoting its PDF');
      }
      final updated = _withScriptPath(latest, prepared.destination.path);
      await productionsNotifier.update(updated);
      currentProductionNotifier.state = updated;
    } catch (promotionError) {
      try {
        final backup = prepared.backup;
        if (backup != null && await backup.exists()) {
          await backup.rename(prepared.destination.path);
        } else if (await prepared.destination.exists()) {
          await prepared.destination.delete();
        }
        final latest = currentProductionNotifier.state;
        final rollbackBase = latest != null && latest.id == production.id
            ? latest
            : production;
        final restoredProduction = _withScriptPath(
          rollbackBase,
          production.scriptPath,
        );
        await productionsNotifier.update(restoredProduction);
        currentProductionNotifier.state = restoredProduction;
      } catch (rollbackError, rollbackStack) {
        DebugLogService.instance.logError(
          LogCategory.general,
          'PDF promotion rollback failed',
          rollbackError,
          rollbackStack,
        );
        throw _PdfPromotionRollbackException(promotionError, rollbackError);
      }
      rethrow;
    }

    _pdfPendingCommit = false;
    _pdfStagingOwned = false;
    _importedPdfPath = prepared.destination.path;
    if (prepared.ownsStaged) {
      try {
        if (await prepared.staged.exists()) await prepared.staged.delete();
      } catch (e) {
        DebugLogService.instance.logError(
          LogCategory.general,
          'Staged PDF cleanup failed',
          e,
        );
      }
    }
    final backup = prepared.backup;
    if (backup != null) {
      try {
        if (await backup.exists()) await backup.delete();
      } catch (e) {
        DebugLogService.instance.logError(
          LogCategory.general,
          'PDF backup cleanup failed',
          e,
        );
      }
    }
  }

  Future<void> _restorePreviousScript(
    ParsedScript? previous,
    Production production, {
    required bool restoreCloud,
  }) async {
    final rollback =
        previous ??
        ParsedScript(
          title: production.title,
          lines: const [],
          characters: const [],
          scenes: const [],
          rawText: '',
        );
    ref.read(currentScriptProvider.notifier).state = rollback;
    try {
      await persistScriptLocally(ref, production.id, rollback);
      if (restoreCloud) {
        final outcome = await pushScriptToCloud(ref);
        if (outcome != ScriptCloudPushOutcome.complete) {
          throw StateError(
            'Prior script cloud restore was ${outcome.name}, not complete',
          );
        }
      }
    } finally {
      ref.read(currentScriptProvider.notifier).state = previous;
    }
  }

  Future<void> _discardPreparedPdf(
    _PreparedPdfCommit? prepared, {
    required bool preserveBackup,
  }) async {
    if (prepared == null) return;
    final files = [prepared.incoming, if (!preserveBackup) prepared.backup];
    for (final file in files) {
      if (file == null) continue;
      try {
        if (await file.exists()) await file.delete();
      } catch (e) {
        DebugLogService.instance.logError(
          LogCategory.general,
          'Prepared PDF cleanup failed',
          e,
        );
      }
    }
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

      final service = _importService;

      // Keep the screen (and therefore the process) awake for the whole OCR
      // run. Field log 2026-08-13: with the screen allowed to time out,
      // Samsung's power management repeatedly FROZE the app mid-import —
      // the 30 s sync heartbeat stretched to 78-147 s and 82 pages took
      // ~15 min instead of ~6. Rehearsal already holds a wakelock for the
      // same reason.
      WakelockPlus.enable();
      try {
        // OCR of a scanned script runs for minutes, and back works throughout —
        // every step after this await has to re-check that we're still here.
        final script = await service.importFromPdf(filePath);
        if (!mounted) return;

        // Stage the PDF in the temp dir so the page viewer works during review.
        // It only replaces the production's stored PDF after the script itself
        // persists successfully.
        try {
          final tmpDir = await getTemporaryDirectory();
          if (!mounted) return;
          final stagedPath = p.join(tmpDir.path, 'import.staged.pdf');
          await File(filePath).copy(stagedPath);
          if (!mounted) return;
          _importedPdfPath = stagedPath;
          _pdfPendingCommit = true;
          _pdfStagingOwned = true;
          DebugLogService.instance.log(
            LogCategory.general,
            'Import: PDF staged for page viewer ($stagedPath)',
          );
        } catch (e) {
          if (!mounted) return;
          // The picked file itself usually survives in tmp — use it so the
          // review's page viewer still works this session. It is not ours to
          // delete after acceptance.
          _importedPdfPath = filePath;
          _pdfPendingCommit = true;
          _pdfStagingOwned = false;
          DebugLogService.instance.logError(
            LogCategory.general,
            'Import: PDF staging copy failed — page viewer will use the '
            'picked file directly',
            e,
          );
        }

        if (!mounted) return;

        setState(() {
          _preview = script;
          _loading = false;
        });

        // A scan with unreadable pages produces a clean-LOOKING preview that
        // is silently missing scenes — warn now, not at rehearsal.
        final failed = service.lastImportFailedPages;
        if (failed > 0) {
          ScaffoldMessenger.of(context).showAutoToast(
            SnackBar(
              content: Text(
                '$failed page(s) couldn\'t be read — parts of the '
                'script may be missing. Check the preview against the PDF.',
              ),
              duration: const Duration(seconds: 8),
            ),
          );
        }
      } on UnimplementedError catch (e) {
        // ML Kit not available — show helpful message
        DebugLogService.instance.logError(
          LogCategory.general,
          'PDF import unavailable',
          e,
        );
        if (!mounted) return;
        setState(() {
          _error =
              'PDF import requires Google ML Kit Text Recognition.\n'
              'Add google_mlkit_text_recognition to pubspec.yaml, '
              'or convert your PDF to a text file first.';
          _loading = false;
        });
      } finally {
        // Import over (success, failure, or user backed out) — let the
        // screen sleep again. Rehearsal manages its own wakelock.
        WakelockPlus.disable();
      }
    } catch (e, stack) {
      DebugLogService.instance.logError(
        LogCategory.general,
        'PDF import failed',
        e,
        stack,
      );
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

      final service = _importService;
      final script = await service.importFromMarkdownFile(filePath);
      if (!mounted) return;

      setState(() {
        _preview = script;
        _loading = false;
      });
    } catch (e, stack) {
      DebugLogService.instance.logError(
        LogCategory.general,
        'Markdown import failed',
        e,
        stack,
      );
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

      final service = _importService;
      final script = await service.importFromTextFile(filePath);
      if (!mounted) return;

      setState(() {
        _preview = script;
        _loading = false;
      });
    } catch (e, stack) {
      DebugLogService.instance.logError(
        LogCategory.general,
        'Text import failed',
        e,
        stack,
      );
      if (!mounted) return;
      setState(() {
        _error = 'Failed to import script: $e';
        _loading = false;
      });
    }
  }
}
