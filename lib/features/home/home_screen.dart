import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/production_models.dart';
import '../../data/models/script_models.dart';
import '../../data/services/supabase_service.dart';
import '../../features/script_editor/cloud_sync_dialog.dart';
import '../../providers/production_providers.dart';

/// FutureProvider that loads the saved character name for a production.
final savedCharacterProvider =
    FutureProvider.family<String?, String>((ref, productionId) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString('rehearsal_character_$productionId');
});

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    final productions = ref.watch(productionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('CastCircle'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.push('/settings'),
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showAbout(context),
          ),
        ],
      ),
      body: productions.isEmpty
          ? _buildEmptyState(context)
          : _buildProductionList(context, ref, productions),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'join',
            onPressed: () => context.push('/join'),
            icon: const Icon(Icons.vpn_key),
            label: const Text('Join Production'),
            backgroundColor:
                Theme.of(context).colorScheme.secondaryContainer,
            foregroundColor:
                Theme.of(context).colorScheme.onSecondaryContainer,
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'create',
            onPressed: () => _createProduction(context, ref),
            icon: const Icon(Icons.add),
            label: const Text('New Production'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.theater_comedy,
              size: 80,
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 24),
            Text(
              'No productions yet',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Create a production and import a script\nto start learning your lines.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.6),
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProductionList(
    BuildContext context,
    WidgetRef ref,
    List<Production> productions,
  ) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: productions.length,
      itemBuilder: (context, index) {
        final production = productions[index];
        final savedChar = ref.watch(savedCharacterProvider(production.id));

        return _ProductionCard(
          production: production,
          savedCharacterName: savedChar.valueOrNull,
          onRehearse: () => _openProduction(context, ref, production),
          onSetUp: () => _openProductionForSetup(context, ref, production),
          onMenuAction: (action) =>
              _handleMenuAction(context, ref, production, action),
          onDelete: () async {
            final confirmed =
                await _confirmDeleteProduction(context, production);
            if (confirmed == true) {
              ref.read(productionsProvider.notifier).remove(production.id);
            }
          },
        );
      },
    );
  }

  Future<void> _openProduction(
    BuildContext context,
    WidgetRef ref,
    Production production,
  ) async {
    ref.read(currentProductionProvider.notifier).state = production;
    ref.read(rehearsalCharacterProvider.notifier).state = null;
    ref.read(selectedSceneProvider.notifier).state = null;
    ref.read(recordingsProvider.notifier).loadForProduction(production.id);
    ref.read(castMembersProvider.notifier).loadForProduction(production.id);

    final savedScript = await loadPersistedScript(ref, production.id);

    if (savedScript != null) {
      ref.read(currentScriptProvider.notifier).state = ParsedScript(
        title: production.title,
        lines: savedScript.lines,
        characters: savedScript.characters,
        scenes: savedScript.scenes,
        rawText: savedScript.rawText,
      );
      if (context.mounted) context.push('/production');
      return;
    }

    // Try cloud (Supabase)
    try {
      final cloudLines = await fetchCloudScriptLines(production.id);
      if (cloudLines != null && cloudLines.isNotEmpty) {
        final script = buildParsedScript(production.title, cloudLines);
        ref.read(currentScriptProvider.notifier).state = script;
        await persistScript(ref);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Loaded ${cloudLines.length} lines from cloud'),
              duration: const Duration(seconds: 2),
            ),
          );
          context.push('/production');
        }
        return;
      }
    } catch (e) {
      debugPrint('Cloud script fetch failed: $e');
    }

    // Nothing found anywhere — go to import
    if (context.mounted) context.push('/import');
  }

  Future<void> _openProductionForSetup(
    BuildContext context,
    WidgetRef ref,
    Production production,
  ) async {
    ref.read(currentProductionProvider.notifier).state = production;
    ref.read(rehearsalCharacterProvider.notifier).state = null;
    ref.read(selectedSceneProvider.notifier).state = null;
    ref.read(recordingsProvider.notifier).loadForProduction(production.id);
    ref.read(castMembersProvider.notifier).loadForProduction(production.id);

    if (context.mounted) context.push('/import');
  }

  void _handleMenuAction(
    BuildContext context,
    WidgetRef ref,
    Production production,
    String action,
  ) {
    // Set as current production first
    ref.read(currentProductionProvider.notifier).state = production;
    ref.read(recordingsProvider.notifier).loadForProduction(production.id);
    ref.read(castMembersProvider.notifier).loadForProduction(production.id);

    // Load script in background for routes that need it
    _ensureScriptLoaded(ref, production);

    switch (action) {
      case 'editor':
        context.push('/editor');
      case 'characters':
        context.push('/characters');
      case 'cast':
        context.push('/cast');
      case 'voice-config':
        context.push('/voice-config');
      case 'record':
        context.push('/record');
      case 'history':
        context.push('/history');
      case 'ai-models':
        context.push('/ai-models');
      case 'settings':
        context.push('/settings');
    }
  }

  Future<void> _ensureScriptLoaded(
      WidgetRef ref, Production production) async {
    final current = ref.read(currentScriptProvider);
    if (current != null && current.lines.isNotEmpty) return;

    final saved = await loadPersistedScript(ref, production.id);
    if (saved != null) {
      ref.read(currentScriptProvider.notifier).state = ParsedScript(
        title: production.title,
        lines: saved.lines,
        characters: saved.characters,
        scenes: saved.scenes,
        rawText: saved.rawText,
      );
    }
  }

  void _createProduction(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Production'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Production title',
            hintText: 'e.g., Pride and Prejudice',
          ),
          onSubmitted: (_) => _submitProduction(context, ref, controller),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => _submitProduction(context, ref, controller),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  Future<void> _submitProduction(
    BuildContext context,
    WidgetRef ref,
    TextEditingController controller,
  ) async {
    final title = controller.text.trim();
    if (title.isEmpty) return;

    final supa = SupabaseService.instance;
    String productionId = const Uuid().v4();
    String organizerId = 'local';
    String joinCode = SupabaseService.generateJoinCode();

    if (supa.isSignedIn) {
      try {
        final row = await supa.createProduction(title: title);
        productionId = row['id'] as String;
        organizerId = supa.currentUser!.id;
        joinCode = row['join_code'] as String? ?? joinCode;
      } catch (e) {
        debugPrint('Cloud production create failed: $e');
      }
    }

    final production = Production(
      id: productionId,
      title: title,
      organizerId: organizerId,
      createdAt: DateTime.now(),
      status: ProductionStatus.draft,
      joinCode: joinCode,
    );

    ref.read(productionsProvider.notifier).add(production);
    ref.read(currentProductionProvider.notifier).state = production;
    if (context.mounted) {
      Navigator.pop(context);
      context.push('/import');
    }
  }

  Future<bool?> _confirmDeleteProduction(
    BuildContext context,
    Production production,
  ) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Production'),
        content: Text(
          'Delete "${production.title}"? This will remove the script, '
          'recordings, and all rehearsal data. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _showAbout(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: 'CastCircle',
      applicationVersion: '0.1.0',
      children: [
        const Text(
          'Help actors learn their lines by rehearsing with '
          'real cast recordings or text-to-speech.',
        ),
      ],
    );
  }
}

/// Rich production card with Rehearse button and overflow menu.
class _ProductionCard extends StatelessWidget {
  final Production production;
  final String? savedCharacterName;
  final VoidCallback onRehearse;
  final VoidCallback onSetUp;
  final void Function(String action) onMenuAction;
  final VoidCallback onDelete;

  const _ProductionCard({
    required this.production,
    this.savedCharacterName,
    required this.onRehearse,
    required this.onSetUp,
    required this.onMenuAction,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasCharacter =
        savedCharacterName != null && savedCharacterName!.isNotEmpty;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title row with overflow menu
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Icon(
                    Icons.theater_comedy,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        production.title,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        hasCharacter
                            ? savedCharacterName!
                            : 'No character selected',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: hasCharacter
                              ? theme.colorScheme.onSurface
                                  .withValues(alpha: 0.7)
                              : theme.colorScheme.onSurface
                                  .withValues(alpha: 0.4),
                          fontStyle: hasCharacter
                              ? FontStyle.normal
                              : FontStyle.italic,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  onSelected: (action) {
                    if (action == 'delete') {
                      onDelete();
                    } else {
                      onMenuAction(action);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                        value: 'editor',
                        child: ListTile(
                            leading: Icon(Icons.edit_note),
                            title: Text('Edit Script'),
                            dense: true,
                            contentPadding: EdgeInsets.zero)),
                    const PopupMenuItem(
                        value: 'characters',
                        child: ListTile(
                            leading: Icon(Icons.person_search),
                            title: Text('Characters'),
                            dense: true,
                            contentPadding: EdgeInsets.zero)),
                    const PopupMenuItem(
                        value: 'cast',
                        child: ListTile(
                            leading: Icon(Icons.people_outline),
                            title: Text('Cast'),
                            dense: true,
                            contentPadding: EdgeInsets.zero)),
                    const PopupMenuItem(
                        value: 'voice-config',
                        child: ListTile(
                            leading: Icon(Icons.record_voice_over),
                            title: Text('Voice Config'),
                            dense: true,
                            contentPadding: EdgeInsets.zero)),
                    const PopupMenuItem(
                        value: 'record',
                        child: ListTile(
                            leading: Icon(Icons.mic),
                            title: Text('Record Lines'),
                            dense: true,
                            contentPadding: EdgeInsets.zero)),
                    const PopupMenuItem(
                        value: 'history',
                        child: ListTile(
                            leading: Icon(Icons.history),
                            title: Text('History'),
                            dense: true,
                            contentPadding: EdgeInsets.zero)),
                    const PopupMenuItem(
                        value: 'ai-models',
                        child: ListTile(
                            leading: Icon(Icons.smart_toy),
                            title: Text('AI Models'),
                            dense: true,
                            contentPadding: EdgeInsets.zero)),
                    const PopupMenuItem(
                        value: 'settings',
                        child: ListTile(
                            leading: Icon(Icons.settings),
                            title: Text('Settings'),
                            dense: true,
                            contentPadding: EdgeInsets.zero)),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        leading: Icon(Icons.delete,
                            color: theme.colorScheme.error),
                        title: Text('Delete',
                            style:
                                TextStyle(color: theme.colorScheme.error)),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Rehearse / Set Up button
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onRehearse,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Rehearse'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  textStyle: theme.textTheme.titleMedium,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
