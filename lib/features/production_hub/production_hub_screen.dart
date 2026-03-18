import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/production_models.dart';
import '../../data/models/script_models.dart';
import '../../data/services/model_manager.dart';
import '../../data/services/script_export.dart';
import '../../data/services/supabase_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/services/voice_config_service.dart';
import '../../providers/production_providers.dart';
import '../rehearsal/rehearsal_history_screen.dart';
import '../rehearsal/scene_selector_screen.dart';

class ProductionHubScreen extends ConsumerStatefulWidget {
  const ProductionHubScreen({super.key});

  @override
  ConsumerState<ProductionHubScreen> createState() =>
      _ProductionHubScreenState();
}

class _ProductionHubScreenState extends ConsumerState<ProductionHubScreen> {
  bool _checkedModels = false;
  bool _modelsReady = false;

  @override
  void initState() {
    super.initState();
    _checkModels();
    _loadSavedCharacter();
  }

  Future<void> _loadSavedCharacter() async {
    final production = ref.read(currentProductionProvider);
    if (production == null) return;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('rehearsal_character_${production.id}');
    if (saved != null && mounted) {
      // Verify character still exists in script
      final script = ref.read(currentScriptProvider);
      if (script != null &&
          script.characters.any((c) => c.name == saved)) {
        ref.read(rehearsalCharacterProvider.notifier).state = saved;
        return;
      }
    }

    // Fallback: auto-select from cast membership
    if (mounted) {
      final castMembers = ref.read(castMembersProvider);
      final supa = SupabaseService.instance;
      final userId = supa.currentUser?.id;
      if (userId != null) {
        final myMembership = castMembers.where(
          (m) => m.userId == userId && m.characterName.isNotEmpty,
        );
        if (myMembership.isNotEmpty) {
          final charName = myMembership.first.characterName;
          final script = ref.read(currentScriptProvider);
          if (script != null &&
              script.characters.any((c) => c.name == charName)) {
            ref.read(rehearsalCharacterProvider.notifier).state = charName;
            _saveCharacterChoice(charName);
          }
        }
      }
    }
  }

  Future<void> _saveCharacterChoice(String? character) async {
    final production = ref.read(currentProductionProvider);
    if (production == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (character != null) {
      await prefs.setString('rehearsal_character_${production.id}', character);
    } else {
      await prefs.remove('rehearsal_character_${production.id}');
    }
  }

  Future<void> _checkModels() async {
    final ready = await ModelManager.instance.isAllReady();
    if (mounted) {
      setState(() {
        _checkedModels = true;
        _modelsReady = ready;
      });

      // Prompt to download if models are missing and script is loaded
      if (!ready) {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted && !_modelsReady) _showModelPrompt();
        });
      }
    }
  }

  void _showModelPrompt() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.smart_toy, size: 48),
        title: const Text('Download AI Voices'),
        content: const Text(
          'CastCircle uses on-device AI for natural-sounding voices during '
          'rehearsal. Download the voice models now (~340 MB, one-time) '
          'for the best experience.\n\n'
          'Without them, rehearsal audio won\'t be available.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Later'),
          ),
          FilledButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);
              await context.push('/ai-models');
              _checkModels();
            },
            icon: const Icon(Icons.download),
            label: const Text('Download Now'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final production = ref.watch(currentProductionProvider);
    final script = ref.watch(currentScriptProvider);
    final myCharacter = ref.watch(rehearsalCharacterProvider);
    final sessions = ref.watch(rehearsalHistoryProvider);

    if (production == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Production')),
        body: const Center(child: Text('No production selected')),
      );
    }

    final hasScript = script != null && script.lines.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(production.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Back to productions',
            onPressed: () => context.go('/'),
          ),
        ],
      ),
      drawer: _buildDrawer(context, hasScript),
      body: hasScript
          ? _buildRehearsalView(context, script, myCharacter, sessions)
          : _buildNoScriptView(context),
    );
  }

  // ── Drawer (hamburger menu) ────────────────────────────

  Widget _buildDrawer(BuildContext context, bool hasScript) {
    final production = ref.read(currentProductionProvider)!;
    final isSignedIn = SupabaseService.instance.isSignedIn;

    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  production.title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .onPrimaryContainer,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  production.status.name.toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .onPrimaryContainer
                            .withValues(alpha: 0.7),
                      ),
                ),
              ],
            ),
          ),
          // ── Script Setup ──
          _drawerSection('Script'),
          if (!hasScript)
            _drawerItem(Icons.upload_file, 'Import Script', () {
              Navigator.pop(context);
              context.push('/import');
            })
          else ...[
            _drawerItem(Icons.edit_note, 'Edit Script', () {
              Navigator.pop(context);
              context.push('/editor');
            }),
            _drawerItem(Icons.person_search, 'Characters', () {
              Navigator.pop(context);
              context.push('/characters');
            }),
            _drawerItem(Icons.auto_awesome_mosaic, 'Scenes', () {
              Navigator.pop(context);
              context.push('/scenes');
            }),
          ],
          const Divider(),
          // ── Cast & Recording ──
          _drawerSection('Cast & Recording'),
          _drawerItem(Icons.people_outline, 'Manage Cast', () {
            Navigator.pop(context);
            context.push('/cast');
          }),
          if (hasScript)
            _drawerItem(Icons.mic, 'Record Lines', () {
              Navigator.pop(context);
              context.push('/record');
            }),
          const Divider(),
          // ── Cloud Sync ──
          if (isSignedIn) ...[
            _drawerSection('Cloud'),
            _drawerItem(Icons.cloud_upload, 'Push Script to Cloud', () {
              Navigator.pop(context);
              _pushToCloud(context);
            }),
            _drawerItem(Icons.cloud_download, 'Pull from Cloud', () {
              Navigator.pop(context);
              _syncFromCloud(context);
            }),
            const Divider(),
          ],
          // ── Export ──
          if (hasScript) ...[
            _drawerSection('Export'),
            _drawerItem(Icons.text_snippet, 'Export as Text', () {
              Navigator.pop(context);
              _export(context, 'plain');
            }),
            _drawerItem(Icons.article, 'Export as Markdown', () {
              Navigator.pop(context);
              _export(context, 'markdown');
            }),
            const Divider(),
          ],
          // ── Voices & History ──
          _drawerItem(Icons.record_voice_over, 'Voice Preset & Config', () {
            Navigator.pop(context);
            context.push('/voice-config');
          }),
          _drawerItem(Icons.history, 'Rehearsal History', () {
            Navigator.pop(context);
            context.push('/history');
          }),
          _drawerItem(Icons.smart_toy, 'AI Models', () async {
            Navigator.pop(context);
            await context.push('/ai-models');
            _checkModels();
          }),
          _drawerItem(Icons.settings, 'Settings', () {
            Navigator.pop(context);
            context.go('/settings');
          }),
        ],
      ),
    );
  }

  Widget _drawerSection(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }

  Widget _drawerItem(IconData icon, String label, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      dense: true,
      onTap: onTap,
    );
  }

  static const _localeLabels = {
    'en-US': 'American English',
    'en-GB': 'British English',
  };

  Widget _buildDialectRow(BuildContext context, Production? production) {
    if (production == null) return const SizedBox.shrink();
    final label = _localeLabels[production.locale] ?? production.locale;
    return InkWell(
      onTap: () => _showLocaleDialog(context, production),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(Icons.language, size: 20,
                color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Text('Dialect:', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(width: 8),
            Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.bold)),
            const Spacer(),
            Icon(Icons.chevron_right, size: 20, color: Colors.grey[500]),
          ],
        ),
      ),
    );
  }

  void _showLocaleDialog(BuildContext context, Production production) {
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Script Dialect'),
        children: [
          ..._localeLabels.entries.map((e) {
            return RadioListTile<String>(
              value: e.key,
              groupValue: production.locale,
              title: Text(e.value),
              subtitle: Text(e.key == 'en-GB'
                  ? 'Shakespeare, period drama, British plays'
                  : 'Modern American theatre'),
              onChanged: (value) {
                if (value != null) _updateLocale(value);
                Navigator.pop(ctx);
              },
            );
          }),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text(
              'Sets STT recognition language and TTS voice accents. '
              'Individual characters can override this in Characters settings.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }

  void _showCharacterPicker(BuildContext context, ParsedScript script) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Select your character',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: script.characters.length,
                itemBuilder: (_, i) {
                  final char = script.characters[i];
                  final color = AppTheme.colorForCharacter(char.colorIndex);
                  final selected = ref.read(rehearsalCharacterProvider) == char.name;
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: color,
                      radius: 14,
                      child: Text(char.name[0],
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12)),
                    ),
                    title: Text(char.name),
                    trailing: Text('${char.lineCount} lines',
                        style: Theme.of(context).textTheme.bodySmall),
                    selected: selected,
                    onTap: () {
                      ref.read(rehearsalCharacterProvider.notifier).state =
                          char.name;
                      _saveCharacterChoice(char.name);
                      Navigator.pop(ctx);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _updateLocale(String locale) {
    final production = ref.read(currentProductionProvider);
    if (production == null) return;
    final updated = production.copyWith(locale: locale);
    ref.read(productionsProvider.notifier).update(updated);
    ref.read(currentProductionProvider.notifier).state = updated;

    // Auto-update voice preset to match dialect
    final presetId = locale == 'en-GB' ? 'victorian_english' : 'modern_american';
    VoiceConfigService.instance.setPreset(production.id, presetId);
  }

  // ── No script state ────────────────────────────────────

  Widget _buildNoScriptView(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.description_outlined,
              size: 80,
              color: Theme.of(context)
                  .colorScheme
                  .primary
                  .withValues(alpha: 0.5),
            ),
            const SizedBox(height: 24),
            Text(
              'No script imported yet',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Import a script to start rehearsing.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.6),
                  ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => context.push('/import'),
              icon: const Icon(Icons.upload_file),
              label: const Text('Import Script'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Main rehearsal view ────────────────────────────────

  Widget _buildRehearsalView(
    BuildContext context,
    ParsedScript script,
    String? myCharacter,
    List sessions,
  ) {
    final theme = Theme.of(context);
    final dialogueCount =
        script.lines.where((l) => l.lineType == LineType.dialogue).length;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Model download banner ──
          if (_checkedModels && !_modelsReady)
            Card(
              color: theme.colorScheme.tertiaryContainer,
              margin: const EdgeInsets.only(bottom: 16),
              child: InkWell(
                onTap: () async {
                  await context.push('/ai-models');
                  _checkModels();
                },
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.download,
                          color: theme.colorScheme.onTertiaryContainer),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('AI voices not downloaded',
                                style: theme.textTheme.titleSmall?.copyWith(
                                    color: theme.colorScheme
                                        .onTertiaryContainer)),
                            Text(
                                'Tap to download for natural-sounding rehearsal',
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme
                                        .onTertiaryContainer
                                        .withValues(alpha: 0.7))),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right,
                          color: theme.colorScheme.onTertiaryContainer),
                    ],
                  ),
                ),
              ),
            ),

          // ── Character selector + Start Rehearsal (always at top) ──
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('I am rehearsing as:',
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: () => _showCharacterPicker(context, script),
                    borderRadius: BorderRadius.circular(8),
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      child: myCharacter != null
                          ? Row(
                              children: [
                                CircleAvatar(
                                  backgroundColor: AppTheme.colorForCharacter(
                                    script.characters
                                        .indexWhere((c) => c.name == myCharacter)
                                        .clamp(0, 99),
                                  ),
                                  radius: 8,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(myCharacter,
                                      overflow: TextOverflow.ellipsis),
                                ),
                                Icon(Icons.arrow_drop_down,
                                    color: Colors.grey[500]),
                              ],
                            )
                          : Row(
                              children: [
                                Expanded(
                                  child: Text('Select your character',
                                      style: TextStyle(
                                          color: Colors.grey[500])),
                                ),
                                Icon(Icons.arrow_drop_down,
                                    color: Colors.grey[500]),
                              ],
                            ),
                    ),
                  ),
                  if (myCharacter != null) ...[
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => context.push('/practice'),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Start Rehearsal'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                        textStyle: theme.textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () {
                        ref.read(recordingCharacterProvider.notifier).state =
                            myCharacter;
                        context.push('/recording-studio');
                      },
                      icon: const Icon(Icons.mic),
                      label: const Text('Record Lines'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── My scenes (if character selected) ──
          if (myCharacter != null) ...[
            _buildMyScenes(context, script, myCharacter),
            const SizedBox(height: 16),
          ],

          // ── Script summary card ──
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      _statChip(context, '$dialogueCount', 'lines'),
                      _statChip(
                          context, '${script.characters.length}', 'characters'),
                      _statChip(context, '${script.scenes.length}', 'scenes'),
                      _statChip(context, '${script.acts.length}', 'acts'),
                    ],
                  ),
                  const Divider(height: 24),
                  _buildDialectRow(context, ref.watch(currentProductionProvider)),
                ],
              ),
            ),
          ),

          // ── Recent sessions ──
          if (sessions.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildRecentSessions(context, sessions),
          ],

          // ── Prompt to select character ──
          if (myCharacter == null) ...[
            const SizedBox(height: 16),
            Card(
              color: theme.colorScheme.surfaceContainerHighest,
              child: const Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  children: [
                    Icon(Icons.person_add, size: 48, color: Colors.grey),
                    SizedBox(height: 12),
                    Text('Select your character above to start rehearsing',
                        textAlign: TextAlign.center),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statChip(BuildContext context, String value, String label) {
    return Expanded(
      child: Column(
        children: [
          Text(value,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  )),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }

  Widget _buildMyScenes(
      BuildContext context, ParsedScript script, String character) {
    final myScenes = script.scenesForCharacter(character);
    if (myScenes.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Your scenes', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        ...myScenes.map((scene) {
          final myLineCount = script.lines
              .sublist(scene.startLineIndex,
                  (scene.endLineIndex + 1).clamp(0, script.lines.length))
              .where((l) =>
                  l.lineType == LineType.dialogue &&
                  l.character == character)
              .length;

          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              title: Text(scene.sceneName),
              subtitle: Text(scene.location.isNotEmpty
                  ? '${scene.location} - $myLineCount lines'
                  : '$myLineCount lines'),
              trailing: const Icon(Icons.play_circle_outline),
              onTap: () {
                ref.read(selectedSceneProvider.notifier).state = scene;
                context.push('/rehearsal');
              },
            ),
          );
        }),
      ],
    );
  }

  Widget _buildRecentSessions(BuildContext context, List sessions) {
    final theme = Theme.of(context);
    final recent = sessions.take(3).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Recent rehearsals', style: theme.textTheme.titleSmall),
            TextButton(
              onPressed: () => context.push('/history'),
              child: const Text('See all'),
            ),
          ],
        ),
        ...recent.map((session) {
          final score = (session.averageMatchScore * 100).round();
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: score >= 80
                    ? Colors.green
                    : score >= 60
                        ? Colors.orange
                        : Colors.red,
                child: Text('$score%',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
              ),
              title: Text(session.sceneName),
              subtitle: Text(session.character),
              trailing: Text(
                _formatDuration(session.duration),
                style: theme.textTheme.bodySmall,
              ),
            ),
          );
        }),
      ],
    );
  }

  String _formatDuration(Duration d) {
    final mins = d.inMinutes;
    final secs = d.inSeconds % 60;
    return '${mins}m ${secs}s';
  }

  // ── Cloud sync actions ─────────────────────────────────

  Future<void> _pushToCloud(BuildContext context) async {
    try {
      await pushScriptToCloud(ref);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Script pushed to cloud'),
              duration: Duration(seconds: 2)),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Push failed: $e')),
        );
      }
    }
  }

  Future<void> _syncFromCloud(BuildContext context) async {
    final production = ref.read(currentProductionProvider);
    if (production == null) return;

    try {
      final cloudLines = await fetchCloudScriptLines(production.id);
      if (cloudLines == null || cloudLines.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No script in cloud')),
          );
        }
        return;
      }

      final script = buildParsedScript(production.title, cloudLines);
      ref.read(currentScriptProvider.notifier).state = script;
      await persistScript(ref);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Loaded ${cloudLines.length} lines from cloud')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sync failed: $e')),
        );
      }
    }
  }

  Future<void> _export(BuildContext context, String format) async {
    final script = ref.read(currentScriptProvider);
    final production = ref.read(currentProductionProvider);
    if (script == null || production == null) return;

    try {
      String content;
      String fileName;
      final safeName = production.title
          .replaceAll(RegExp(r'[^\w\s-]'), '')
          .replaceAll(RegExp(r'\s+'), '_')
          .toLowerCase();

      switch (format) {
        case 'markdown':
          content = ScriptExporter.toMarkdown(script);
          fileName = '$safeName.md';
        default:
          content = ScriptExporter.toPlainText(script);
          fileName = '$safeName.txt';
      }

      final dir = await getApplicationDocumentsDirectory();
      final exportDir = Directory(p.join(dir.path, 'exports'));
      if (!exportDir.existsSync()) {
        exportDir.createSync(recursive: true);
      }
      final filePath = p.join(exportDir.path, fileName);
      await File(filePath).writeAsString(content);

      if (!context.mounted) return;

      final box = context.findRenderObject() as RenderBox?;
      await Share.shareXFiles(
        [XFile(filePath, mimeType: 'text/plain')],
        text: 'CastCircle export: ${production.title}',
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
}
