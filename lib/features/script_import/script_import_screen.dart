import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/models/script_models.dart';
import '../../data/services/voice_config_service.dart';
import '../../providers/production_providers.dart';

class ScriptImportScreen extends ConsumerStatefulWidget {
  const ScriptImportScreen({super.key});

  @override
  ConsumerState<ScriptImportScreen> createState() =>
      _ScriptImportScreenState();
}

class _ScriptImportScreenState extends ConsumerState<ScriptImportScreen> {
  bool _loading = false;
  String? _error;
  ParsedScript? _preview;
  String? _importedPdfPath; // persisted copy of imported PDF for page viewer

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
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Parsing script...'),
                ],
              ),
            )
          : _preview != null
              ? _buildPreview(context)
              : _buildImportOptions(context),
    );
  }

  Widget _buildImportOptions(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.description_outlined,
              size: 80,
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
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
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.6),
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
                      Icon(Icons.error_outline,
                          color:
                              Theme.of(context).colorScheme.onErrorContainer),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onErrorContainer,
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
    );
  }

  Widget _buildPreview(BuildContext context) {
    final script = _preview!;

    return Column(
      children: [
        // Stats bar
        Container(
          padding: const EdgeInsets.all(16),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _statBadge(
                context,
                '${script.lines.where((l) => l.lineType == LineType.dialogue).length}',
                'Lines',
              ),
              _statBadge(
                context,
                '${script.characters.length}',
                'Characters',
              ),
              _statBadge(
                context,
                '${script.acts.length}',
                'Acts',
              ),
            ],
          ),
        ),
        // Dialect selector
        _buildDialectSelector(context),
        // Character list
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Characters Found',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              ...script.characters.map((char) => ListTile(
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
                  )),
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
                    }),
                    child: const Text('Re-import'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () async {
                      ref.read(currentScriptProvider.notifier).state = script;
                      await persistScript(ref);
                      if (context.mounted) context.push('/production');
                    },
                    icon: const Icon(Icons.check),
                    label: const Text('Accept Script'),
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
              Icon(Icons.language, size: 20,
                  color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              const Text('Script dialect'),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              segments: _localeLabels.entries.map((e) =>
                ButtonSegment(value: e.key, label: Text(e.value)),
              ).toList(),
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
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _statBadge(BuildContext context, String value, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                )),
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
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
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
                  style: TextStyle(
                    color: Colors.grey[300],
                  ),
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

  Future<void> _pickPdfFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );

      if (result == null || result.files.isEmpty) return;

      final filePath = result.files.first.path;
      if (filePath == null) return;

      setState(() {
        _loading = true;
        _error = null;
      });

      final service = ref.read(scriptImportServiceProvider);

      try {
        final script = await service.importFromPdf(filePath);

        // Copy PDF to app documents so it persists for the page viewer
        final production = ref.read(currentProductionProvider);
        if (production != null) {
          final docsDir = await getApplicationDocumentsDirectory();
          final pdfDir = Directory(p.join(docsDir.path, 'scripts'));
          if (!pdfDir.existsSync()) pdfDir.createSync(recursive: true);
          final destPath = p.join(pdfDir.path, '${production.id}.pdf');
          await File(filePath).copy(destPath);
          _importedPdfPath = destPath;
          final updated = production.copyWith(scriptPath: destPath);
          ref.read(productionsProvider.notifier).update(updated);
          ref.read(currentProductionProvider.notifier).state = updated;
        }

        setState(() {
          _preview = script;
          _loading = false;
        });
      } on UnimplementedError {
        // ML Kit not available — show helpful message
        setState(() {
          _error = 'PDF import requires Google ML Kit Text Recognition.\n'
              'Add google_mlkit_text_recognition to pubspec.yaml, '
              'or convert your PDF to a text file first.';
          _loading = false;
        });
      }
    } catch (e) {
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

      setState(() {
        _loading = true;
        _error = null;
      });

      final service = ref.read(scriptImportServiceProvider);
      final script = await service.importFromMarkdownFile(filePath);

      setState(() {
        _preview = script;
        _loading = false;
      });
    } catch (e) {
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

      setState(() {
        _loading = true;
        _error = null;
      });

      final service = ref.read(scriptImportServiceProvider);
      final script = await service.importFromTextFile(filePath);

      setState(() {
        _preview = script;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to import script: $e';
        _loading = false;
      });
    }
  }
}
