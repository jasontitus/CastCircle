import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/script_models.dart';
import '../../data/services/supabase_service.dart';
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
  @override
  Widget build(BuildContext context) {
    final production = ref.watch(currentProductionProvider);
    final script = ref.watch(currentScriptProvider);
    final myCharacter = ref.watch(rehearsalCharacterProvider);
    final sessions = ref.watch(rehearsalHistoryProvider);
    final theme = Theme.of(context);

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
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/'),
        ),
      ),
      drawer: _buildDrawer(context, hasScript),
      body: hasScript
          ? _buildRehearsalView(context, script!, myCharacter, sessions)
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
          // ── History & Settings ──
          _drawerItem(Icons.history, 'Rehearsal History', () {
            Navigator.pop(context);
            context.push('/history');
          }),
          _drawerItem(Icons.smart_toy, 'AI Models', () {
            Navigator.pop(context);
            context.push('/models');
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
          // ── Script summary card ──
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  _statChip(context, '$dialogueCount', 'lines'),
                  _statChip(
                      context, '${script.characters.length}', 'characters'),
                  _statChip(context, '${script.scenes.length}', 'scenes'),
                  _statChip(context, '${script.acts.length}', 'acts'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Character selector ──
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('I am rehearsing as:',
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: myCharacter,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      hintText: 'Select your character',
                    ),
                    items: script.characters.map((char) {
                      final color =
                          AppTheme.colorForCharacter(char.colorIndex);
                      return DropdownMenuItem(
                        value: char.name,
                        child: Row(
                          children: [
                            CircleAvatar(
                                backgroundColor: color, radius: 8),
                            const SizedBox(width: 8),
                            Expanded(child: Text(char.name)),
                            Text('${char.lineCount} lines',
                                style: theme.textTheme.bodySmall),
                          ],
                        ),
                      );
                    }).toList(),
                    onChanged: (value) {
                      ref.read(rehearsalCharacterProvider.notifier).state =
                          value;
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Start rehearsal button ──
          if (myCharacter != null) ...[
            FilledButton.icon(
              onPressed: () => context.push('/practice'),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start Rehearsal'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                textStyle: theme.textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 24),

            // ── My scenes summary ──
            _buildMyScenes(context, script, myCharacter),
          ] else ...[
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

          // ── Recent sessions ──
          if (sessions.isNotEmpty) ...[
            const SizedBox(height: 24),
            _buildRecentSessions(context, sessions),
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
    // Delegate to script editor export logic
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Open Edit Script to export'),
            duration: Duration(seconds: 2)),
      );
    }
  }
}
