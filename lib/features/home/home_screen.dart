import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/responsive.dart';
import '../../data/services/analytics_service.dart';
import '../../data/services/recording_sync_service.dart';
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

bool shouldReuseLoadedScript({
  required String? currentProductionId,
  required String targetProductionId,
  required ParsedScript? currentScript,
}) {
  return currentProductionId == targetProductionId &&
      currentScript != null &&
      currentScript.lines.isNotEmpty;
}

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
              color: Theme.of(context).colorScheme.primary.withOpacity( 0.5),
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
                        .withOpacity( 0.6),
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
    // On tablets, use a 2-column grid
    if (Responsive.isWide(context)) {
      return GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: Responsive.isExpanded(context) ? 3 : 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.6,
        ),
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
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Delete Production?'),
                  content: Text(
                      'Delete "${production.title}" and all its data?'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel')),
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Delete',
                            style: TextStyle(color: Colors.red))),
                  ],
                ),
              );
              if (confirmed == true) {
                if (!context.mounted) return;
                await _deleteProduction(context, ref, production);
              }
            },
          );
        },
      );
    }

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
              if (!context.mounted) return;
              await _deleteProduction(context, ref, production);
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
    final previousProduction = ref.read(currentProductionProvider);
    if (previousProduction?.id != production.id) {
      ref.read(currentScriptProvider.notifier).state = null;
      ref.read(understudyRecordingsProvider.notifier).clear();
    }

    ref.read(currentProductionProvider.notifier).state = production;
    ref.read(rehearsalCharacterProvider.notifier).state = null;
    ref.read(selectedSceneProvider.notifier).state = null;
    ref.read(recordingsProvider.notifier).loadForProduction(production.id);
    ref.read(castMembersProvider.notifier).loadForProduction(production.id);

    // Sync recordings in background — upload local, download others'
    _syncRecordingsInBackground(ref, production.id);

    final savedScript = await loadPersistedScript(ref, production.id);

    if (savedScript != null) {
      var script = ParsedScript(
        title: production.title,
        lines: savedScript.lines,
        characters: savedScript.characters,
        scenes: savedScript.scenes,
        rawText: savedScript.rawText,
      );

      final cloudScript = await _resolveCloudScript(
        production,
        localScript: script,
      );
      if (!mounted) return;
      if (cloudScript != null) {
        script = cloudScript;
        await _persistResolvedScript(ref, script);
      } else {
        ref.read(currentScriptProvider.notifier).state = script;
      }

      if (context.mounted) context.push('/production');
      return;
    }

    // Try cloud (Supabase)
    try {
      final cloudLines = await fetchCloudScriptLines(production.id);
      if (cloudLines != null && cloudLines.isNotEmpty) {
        final script = buildParsedScript(production.title, cloudLines);
        await _persistResolvedScript(ref, script);
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
    final previousProduction = ref.read(currentProductionProvider);
    if (previousProduction?.id != production.id) {
      ref.read(currentScriptProvider.notifier).state = null;
      ref.read(understudyRecordingsProvider.notifier).clear();
    }

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
    final previousProduction = ref.read(currentProductionProvider);
    if (previousProduction?.id != production.id) {
      ref.read(currentScriptProvider.notifier).state = null;
      ref.read(understudyRecordingsProvider.notifier).clear();
    }

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
      case 'web-editor':
        final email = SupabaseService.instance.currentUser?.email ?? '';
        final prodTitle = production.title;
        final url = 'https://castcircle-app.web.app?production=${production.id}';
        final text = 'Edit "$prodTitle" on the web:\n'
            '$url'
            '${email.isNotEmpty ? '\n\nSign in with: $email' : ''}';
        Share.share(text, subject: 'CastCircle: Edit $prodTitle');
    }
  }

  /// Sync recordings in the background when opening a production.
  /// Uploads local recordings and downloads other cast members' recordings
  /// so they're ready before rehearsal starts.
  void _syncRecordingsInBackground(WidgetRef ref, String productionId) {
    final userId = SupabaseService.instance.currentUser?.id;

    // Subscribe to realtime for new recordings
    RecordingSyncService.instance
      ..onRecordingReady = (lineId, path) {
        final cached = RecordingSyncService.instance.getCachedRecordings();
        ref.read(understudyRecordingsProvider.notifier).loadFromMap(cached);
      }
      ..subscribe(productionId: productionId, myUserId: userId);

    // Run full sync in background — don't await
    Future(() async {
      // Wait briefly for recordingsProvider to finish loading from Drift
      await Future.delayed(const Duration(milliseconds: 500));
      final localRecordings = ref.read(recordingsProvider);

      final downloaded = await RecordingSyncService.instance.syncForProduction(
        productionId: productionId,
        localRecordings: localRecordings,
        myUserId: userId,
      );

      if (downloaded > 0) {
        final cached = RecordingSyncService.instance.getCachedRecordings();
        ref.read(understudyRecordingsProvider.notifier).loadFromMap(cached);
      }
    });
  }

  Future<void> _ensureScriptLoaded(
      WidgetRef ref, Production production) async {
    final currentProduction = ref.read(currentProductionProvider);
    final current = ref.read(currentScriptProvider);
    if (shouldReuseLoadedScript(
      currentProductionId: currentProduction?.id,
      targetProductionId: production.id,
      currentScript: current,
    )) {
      return;
    }

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

  Future<void> _persistResolvedScript(
    WidgetRef ref,
    ParsedScript script,
  ) async {
    ref.read(currentScriptProvider.notifier).state = script;
    await persistScript(ref);
  }

  bool _scriptsDiffer(ParsedScript localScript, ParsedScript cloudScript) {
    return diffScriptLines(localScript.lines, cloudScript.lines)
        .any((diff) => diff.type != DiffType.unchanged);
  }

  Future<ParsedScript?> _resolveCloudScript(
    Production production, {
    required ParsedScript localScript,
  }) async {
    final cloudLines = await fetchCloudScriptLines(production.id);
    if (cloudLines == null || cloudLines.isEmpty) return null;

    final cloudScript = buildParsedScript(production.title, cloudLines);
    if (!_scriptsDiffer(localScript, cloudScript)) {
      return null;
    }

    if (!mounted) return null;
    final useCloud = await showCloudSyncDialog(
      context: context,
      localLines: localScript.lines,
      cloudLines: cloudScript.lines,
    );

    if (useCloud == true) {
      return cloudScript;
    }
    return null;
  }

  Future<void> _deleteProduction(
    BuildContext context,
    WidgetRef ref,
    Production production,
  ) async {
    await RecordingSyncService.instance.clearCache(production.id);

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('script_backup_${production.id}');
    await prefs.remove('rehearsal_character_${production.id}');

    await ref.read(productionsProvider.notifier).remove(production.id);

    final currentProduction = ref.read(currentProductionProvider);
    if (currentProduction?.id == production.id) {
      ref.read(currentProductionProvider.notifier).state = null;
      ref.read(currentScriptProvider.notifier).state = null;
      ref.read(recordingsProvider.notifier).clear();
      ref.read(understudyRecordingsProvider.notifier).clear();
      ref.read(castMembersProvider.notifier).clear();
      ref.read(rehearsalCharacterProvider.notifier).state = null;
      ref.read(selectedSceneProvider.notifier).state = null;
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted "${production.title}"')),
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
    AnalyticsService.instance.logProductionCreated();
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
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onRehearse,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(
                Icons.theater_comedy,
                color: theme.colorScheme.primary,
                size: 32,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      production.title,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    if (hasCharacter) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Playing: $savedCharacterName',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withOpacity(0.6),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert,
                    color: theme.colorScheme.onSurface.withOpacity(0.5)),
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
                  const PopupMenuItem(
                      value: 'web-editor',
                      child: ListTile(
                          leading: Icon(Icons.language),
                          title: Text('Edit on Web'),
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
        ),
      ),
    );
  }
}
