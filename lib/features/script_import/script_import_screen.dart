import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/script_models.dart';
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
                  child: FilledButton(
                    onPressed: () {
                      ref.read(currentScriptProvider.notifier).state = script;
                      persistScript(ref);
                      context.push('/production');
                    },
                    child: const Text('Edit Script'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
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
