import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/script_models.dart';
import '../../data/services/script_export.dart';
import '../../providers/production_providers.dart';

class ScriptEditorScreen extends ConsumerStatefulWidget {
  const ScriptEditorScreen({super.key});

  @override
  ConsumerState<ScriptEditorScreen> createState() => _ScriptEditorScreenState();
}

class _ScriptEditorScreenState extends ConsumerState<ScriptEditorScreen> {
  String? _selectedCharacter;
  bool _showDirections = true;

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
            icon: const Icon(Icons.auto_awesome_mosaic),
            tooltip: 'Edit Scenes (${script.scenes.length})',
            onPressed: () => context.push('/scenes'),
          ),
          IconButton(
            icon: const Icon(Icons.mic),
            tooltip: 'Record Lines',
            onPressed: () => context.push('/record'),
          ),
          IconButton(
            icon: const Icon(Icons.play_circle_outline),
            tooltip: 'Practice',
            onPressed: () => context.push('/practice'),
          ),
          IconButton(
            icon: const Icon(Icons.visibility),
            tooltip: _showDirections
                ? 'Hide stage directions'
                : 'Show stage directions',
            onPressed: () =>
                setState(() => _showDirections = !_showDirections),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.file_download),
            tooltip: 'Export',
            onSelected: (format) => _export(context, script, format),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'plain',
                child: ListTile(
                  leading: Icon(Icons.text_snippet),
                  title: Text('Export as Text'),
                ),
              ),
              const PopupMenuItem(
                value: 'markdown',
                child: ListTile(
                  leading: Icon(Icons.article),
                  title: Text('Export as Markdown'),
                ),
              ),
              if (_selectedCharacter != null) ...[
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'character',
                  child: ListTile(
                    leading: const Icon(Icons.person),
                    title: Text('$_selectedCharacter lines'),
                  ),
                ),
                PopupMenuItem(
                  value: 'cue',
                  child: ListTile(
                    leading: const Icon(Icons.queue_music),
                    title: Text('$_selectedCharacter cue script'),
                  ),
                ),
              ],
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
                  selected: _selectedCharacter == null,
                  onSelected: (_) =>
                      setState(() => _selectedCharacter = null),
                ),
                const SizedBox(width: 8),
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
                if (_selectedCharacter != null)
                  Text(
                    'Showing $_selectedCharacter only',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: charColors[_selectedCharacter],
                        ),
                  ),
              ],
            ),
          ),
          // Script lines
          Expanded(
            child: ListView.builder(
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

  List<ScriptLine> _filteredLines(ParsedScript script) {
    var lines = script.lines.toList();

    if (!_showDirections) {
      lines = lines
          .where((l) => l.lineType != LineType.stageDirection)
          .toList();
    }

    if (_selectedCharacter != null) {
      lines = lines
          .where((l) =>
              l.lineType == LineType.header ||
              l.character == _selectedCharacter ||
              l.lineType == LineType.stageDirection)
          .toList();
    }

    return lines;
  }

  Widget _buildLineCard(
    BuildContext context,
    ScriptLine line,
    Map<String, Color> charColors,
  ) {
    switch (line.lineType) {
      case LineType.header:
        return Padding(
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
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: InkWell(
            onTap: () => _editLine(context, line),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Line number
                  SizedBox(
                    width: 32,
                    child: Text(
                      '${line.orderIndex}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.3),
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
                        Text(
                          line.character,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: color,
                            fontSize: 13,
                          ),
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
                ],
              ),
            ),
          ),
        );
    }
  }

  void _editLine(BuildContext context, ScriptLine line) {
    final textController = TextEditingController(text: line.text);
    final charController = TextEditingController(text: line.character);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
          left: 16,
          right: 16,
          top: 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Edit Line #${line.orderIndex}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: charController,
              decoration: const InputDecoration(
                labelText: 'Character',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: textController,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Line text',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
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
                    _updateLine(
                      line,
                      charController.text.trim(),
                      textController.text.trim(),
                    );
                    Navigator.pop(context);
                  },
                  child: const Text('Save'),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _updateLine(ScriptLine original, String newChar, String newText) {
    final script = ref.read(currentScriptProvider);
    if (script == null) return;

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
    var colorIdx = 0;
    final characters = charCounts.entries
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final charList = characters
        .map((e) => ScriptCharacter(
              name: e.key,
              colorIndex: colorIdx++,
              lineCount: e.value,
            ))
        .toList();

    ref.read(currentScriptProvider.notifier).state = ParsedScript(
      title: script.title,
      lines: updatedLines,
      characters: charList,
      scenes: script.scenes,
      rawText: script.rawText,
    );
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

      // Show share sheet
      await Share.shareXFiles(
        [XFile(filePath)],
        text: 'LineGuide export: ${script.title}',
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
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
