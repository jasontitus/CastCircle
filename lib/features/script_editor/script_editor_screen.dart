import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/script_models.dart';
import '../../data/services/script_export.dart';
import '../../providers/production_providers.dart';
import 'validation_panel.dart';

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
            icon: const Icon(Icons.save_outlined),
            tooltip: 'Save',
            onPressed: () async {
              await persistScript(ref);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Script saved'),
                    duration: Duration(seconds: 1),
                  ),
                );
              }
            },
          ),
          IconButton(
            icon: Icon(_showDirections
                ? Icons.visibility
                : Icons.visibility_off),
            tooltip: _showDirections
                ? 'Hide stage directions'
                : 'Show stage directions',
            onPressed: () =>
                setState(() => _showDirections = !_showDirections),
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
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Edit Line #${line.orderIndex}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                // Line type toggle
                PopupMenuButton<String>(
                  icon: Icon(_lineTypeIcon(line.lineType), size: 20),
                  tooltip: 'Change line type',
                  onSelected: (type) {
                    _changeLineType(line, type);
                    Navigator.pop(context);
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'dialogue',
                      child: Text('Dialogue'),
                    ),
                    const PopupMenuItem(
                      value: 'stageDirection',
                      child: Text('Stage Direction'),
                    ),
                    const PopupMenuItem(
                      value: 'header',
                      child: Text('Header'),
                    ),
                    const PopupMenuItem(
                      value: 'song',
                      child: Text('Song'),
                    ),
                  ],
                ),
                // Split line
                IconButton(
                  icon: const Icon(Icons.splitscreen, size: 20),
                  tooltip: 'Split line',
                  onPressed: () {
                    Navigator.pop(context);
                    _splitLine(context, line);
                  },
                ),
                // Delete line
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
            const SizedBox(height: 16),
            if (line.lineType == LineType.dialogue ||
                line.lineType == LineType.song)
              TextField(
                controller: charController,
                decoration: const InputDecoration(
                  labelText: 'Character',
                  border: OutlineInputBorder(),
                ),
              ),
            if (line.lineType == LineType.dialogue ||
                line.lineType == LineType.song)
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
      id: '${line.id}_split',
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
    var colorIdx = 0;
    final characters = charCounts.entries.toList()
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

      // Show share sheet — sharePositionOrigin required on iPad/iPhone
      final box = context.findRenderObject() as RenderBox?;
      await Share.shareXFiles(
        [XFile(filePath)],
        text: 'LineGuide export: ${script.title}',
        sharePositionOrigin: box != null
            ? box.localToGlobal(Offset.zero) & box.size
            : Rect.zero,
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
