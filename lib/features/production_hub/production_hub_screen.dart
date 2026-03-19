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
import '../settings/settings_screen.dart';

class ProductionHubScreen extends ConsumerStatefulWidget {
  const ProductionHubScreen({super.key});

  @override
  ConsumerState<ProductionHubScreen> createState() =>
      _ProductionHubScreenState();
}

class _ProductionHubScreenState extends ConsumerState<ProductionHubScreen> {
  bool _checkedModels = false;
  bool _modelsReady = false;
  String? _filterAct;

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
    // Skip model check on Android — Kokoro MLX is iOS only
    if (Platform.isAndroid) {
      if (mounted) setState(() { _checkedModels = true; _modelsReady = false; });
      return;
    }
    final ready = await ModelManager.instance.isAllReady();
    if (mounted) {
      setState(() {
        _checkedModels = true;
        _modelsReady = ready;
      });

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

    debugPrint('ProductionHub.build: production=${production?.title}, script=${script?.lines.length} lines, char=$myCharacter');

    if (production == null) {
      debugPrint('ProductionHub.build: production is NULL — showing placeholder');
      return Scaffold(
        appBar: AppBar(title: const Text('Production')),
        body: const Center(child: Text('No production selected')),
      );
    }

    final hasScript = script != null && script.lines.isNotEmpty;
    debugPrint('ProductionHub.build: hasScript=$hasScript, lines=${script?.lines.length}, chars=${script?.characters.length}');

    // DEBUG: Test if Scaffold renders at all on Android
    if (Platform.isAndroid) {
      return Scaffold(
        appBar: AppBar(title: Text(production.title)),
        body: ListView(
          children: [
            ListTile(
              title: const Text('Script loaded'),
              subtitle: Text('${script?.lines.length ?? 0} lines, ${script?.characters.length ?? 0} characters'),
            ),
            if (hasScript) ...[
              const Divider(),
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('Edit Script'),
                onTap: () => context.push('/editor'),
              ),
              ListTile(
                leading: const Icon(Icons.play_arrow),
                title: const Text('Rehearsal'),
                onTap: () => context.push('/rehearsal'),
              ),
              ListTile(
                leading: const Icon(Icons.people),
                title: const Text('Characters'),
                onTap: () => context.push('/characters'),
              ),
              ListTile(
                leading: const Icon(Icons.home),
                title: const Text('Back to Home'),
                onTap: () => context.go('/'),
              ),
              const Divider(),
              ...script!.characters.map((c) => ListTile(
                title: Text(c.name),
                trailing: Text('${c.lineCount} lines'),
              )),
            ],
          ],
        ),
      );
    }

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
          ? _buildMergedHub(context, script, myCharacter)
          : _buildNoScriptView(context),
    );
  }

  // ── Merged hub: character + mode + scenes ─────────────

  Widget _buildMergedHub(
    BuildContext context,
    ParsedScript script,
    String? myCharacter,
  ) {
    final theme = Theme.of(context);
    final mode = ref.watch(rehearsalModeProvider);
    final hideLines = ref.watch(hideMyLinesProvider);

    return Column(
      children: [
        // ── Model download banner ──
        if (_checkedModels && !_modelsReady)
          Material(
            color: theme.colorScheme.tertiaryContainer,
            child: InkWell(
              onTap: () async {
                await context.push('/ai-models');
                _checkModels();
              },
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Icon(Icons.download,
                        color: theme.colorScheme.onTertiaryContainer),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('AI voices not downloaded — tap to download',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color:
                                  theme.colorScheme.onTertiaryContainer)),
                    ),
                    Icon(Icons.chevron_right,
                        color: theme.colorScheme.onTertiaryContainer),
                  ],
                ),
              ),
            ),
          ),

        // ── Pinned controls ──
        Container(
          color: theme.colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Character dropdown (hidden in listen mode)
              if (mode != RehearsalMode.readthrough)
              DropdownButtonFormField<String>(
                value: script.characters.any((c) => c.name == myCharacter)
                    ? myCharacter
                    : null,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  hintText: 'Select your character',
                  labelText: 'I am rehearsing as',
                  isDense: true,
                ),
                items: script.characters.map((char) {
                  final color = AppTheme.colorForCharacter(char.colorIndex);
                  return DropdownMenuItem(
                    value: char.name,
                    child: Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: color,
                          radius: 8,
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(char.name)),
                        Text(
                          '${char.lineCount} lines',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (value) {
                  ref.read(rehearsalCharacterProvider.notifier).state = value;
                  _saveCharacterChoice(value);
                },
              ),
              const SizedBox(height: 12),
              // Mode toggle + fast mode
              Row(
                children: [
                  Expanded(
                    child: SegmentedButton<RehearsalMode>(
                      segments: const [
                        ButtonSegment(
                          value: RehearsalMode.readthrough,
                          label: Text('Listen', style: TextStyle(fontSize: 12)),
                          icon: Icon(Icons.play_circle_outline, size: 18),
                        ),
                        ButtonSegment(
                          value: RehearsalMode.sceneReadthrough,
                          label: Text('Read', style: TextStyle(fontSize: 12)),
                          icon: Icon(Icons.playlist_play, size: 18),
                        ),
                        ButtonSegment(
                          value: RehearsalMode.cuePractice,
                          label: Text('Cue', style: TextStyle(fontSize: 12)),
                          icon: Icon(Icons.skip_next, size: 18),
                        ),
                      ],
                      selected: {mode},
                      onSelectionChanged: (selected) {
                        ref.read(rehearsalModeProvider.notifier).state =
                            selected.first;
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Fast mode toggle (lightning bolt)
                  IconButton(
                    icon: Icon(
                      Icons.bolt,
                      color: ref.watch(fastModeEnabledProvider)
                          ? Colors.amber
                          : theme.colorScheme.onSurface.withValues(alpha: 0.3),
                    ),
                    tooltip: ref.watch(fastModeEnabledProvider)
                        ? 'Fast mode ON'
                        : 'Fast mode OFF',
                    onPressed: () {
                      ref.read(fastModeEnabledProvider.notifier).state =
                          !ref.read(fastModeEnabledProvider);
                    },
                  ),
                ],
              ),
              // Hide my lines switch
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Hide my lines (blind rehearsal)'),
                value: hideLines,
                onChanged: (v) =>
                    ref.read(hideMyLinesProvider.notifier).state = v,
              ),
            ],
          ),
        ),

        // ── Act filter chips ──
        if (script.acts.length > 1)
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                FilterChip(
                  label: const Text('All Acts'),
                  selected: _filterAct == null,
                  onSelected: (_) => setState(() => _filterAct = null),
                ),
                const SizedBox(width: 8),
                ...script.acts.map((act) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(act),
                        selected: _filterAct == act,
                        onSelected: (_) => setState(
                            () => _filterAct = _filterAct == act ? null : act),
                      ),
                    )),
              ],
            ),
          ),

        // ── Scene cards (scrollable) ──
        Expanded(
          child: _buildSceneList(context, script, myCharacter),
        ),
      ],
    );
  }

  Widget _buildSceneList(
    BuildContext context,
    ParsedScript script,
    String? myCharacter,
  ) {
    var scenes = script.scenes;

    if (_filterAct != null) {
      scenes = scenes.where((s) => s.act == _filterAct).toList();
    }

    if (scenes.isEmpty) {
      return const Center(child: Text('No scenes detected'));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: scenes.length,
      itemBuilder: (context, index) {
        final scene = scenes[index];
        final isMyScene =
            myCharacter != null && scene.characters.contains(myCharacter);
        final myLineCount = myCharacter != null
            ? script
                .linesInScene(scene)
                .where((l) =>
                    l.lineType == LineType.dialogue &&
                    l.character == myCharacter)
                .length
            : 0;
        final totalDialogue = script
            .linesInScene(scene)
            .where((l) => l.lineType == LineType.dialogue)
            .length;

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () {
              ref.read(selectedSceneProvider.notifier).state = scene;
              context.push('/rehearsal');
            },
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: isMyScene
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context)
                            .colorScheme
                            .outline
                            .withValues(alpha: 0.3),
                    width: 4,
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          scene.sceneName,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                      if (isMyScene)
                        Chip(
                          label: Text('$myLineCount lines'),
                          backgroundColor:
                              Theme.of(context).colorScheme.primaryContainer,
                          labelStyle: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onPrimaryContainer,
                            fontSize: 12,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                  if (scene.location.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.place,
                            size: 14,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.5)),
                        const SizedBox(width: 4),
                        Text(
                          scene.location,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.6),
                              ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  // Character chips
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: scene.characters.map((charName) {
                      final charIdx = script.characters
                          .indexWhere((c) => c.name == charName);
                      final color = charIdx >= 0
                          ? AppTheme.colorForCharacter(charIdx)
                          : Colors.grey;
                      final isMe = charName == myCharacter;
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: isMe
                              ? color.withValues(alpha: 0.3)
                              : color.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: isMe
                              ? Border.all(color: color, width: 1.5)
                              : null,
                        ),
                        child: Text(
                          charName,
                          style: TextStyle(
                            fontSize: 11,
                            color: color,
                            fontWeight:
                                isMe ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$totalDialogue lines total',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.4),
                        ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
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
            context.push('/settings');
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
