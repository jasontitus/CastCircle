import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/responsive.dart';
import '../../data/services/analytics_service.dart';
import '../../data/services/debug_log_service.dart';
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
  bool _submittingProduction = false;

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
            savedCharacterName: savedChar.value,
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
          savedCharacterName: savedChar.value,
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

    // Recording sync (upload local + download others' + realtime) is started by
    // the production hub's init, so it covers opening AND joining a production.

    final savedScript = await loadPersistedScript(ref, production.id);

    if (savedScript != null) {
      final script = ParsedScript(
        title: production.title,
        lines: savedScript.lines,
        characters: savedScript.characters,
        scenes: savedScript.scenes,
        rawText: savedScript.rawText,
      );

      ref.read(currentScriptProvider.notifier).state = script;
      if (!context.mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      context.push('/production');
      // We used the cached local script for an instant open, but the organizer
      // may have edited the script since this castmate joined. Pull the latest
      // shared version in the background and adopt it if it changed (stable line
      // IDs keep recordings matched). Never blocks the open.
      unawaited(_refreshScriptFromCloud(ref, production, messenger));
      return;
    }

    // No local script. Navigate to import immediately so the tap is instant,
    // then check the cloud in the background — a slow Supabase round-trip must
    // not block opening the production. If a cloud script exists (e.g. imported
    // on another device), load it and let the user reopen to rehearse.
    final messenger = ScaffoldMessenger.of(context);
    if (context.mounted) context.push('/import');
    unawaited(_reconcileCloudScript(ref, production, messenger));
  }

  /// Background: pull a script from the cloud (if any) and persist it locally.
  /// Runs after navigation so it never blocks opening a production.
  Future<void> _reconcileCloudScript(
    WidgetRef ref,
    Production production,
    ScaffoldMessengerState messenger,
  ) async {
    try {
      final cloudLines = await fetchCloudScriptLines(production.id);
      if (cloudLines == null || cloudLines.isEmpty) return;
      final script = buildParsedScript(production.title, cloudLines);
      await _persistResolvedScript(ref, script);
      ref.read(currentScriptProvider.notifier).state = script;
      messenger.showSnackBar(SnackBar(
        content: Text(
            'Loaded ${cloudLines.length} lines from cloud — reopen to rehearse'),
        duration: const Duration(seconds: 4),
      ));
    } catch (e) {
      DebugLogService.instance.logError(
          LogCategory.network, 'Cloud script fetch failed', e);
    }
  }

  /// Background: pull the latest shared script from the cloud and adopt it
  /// locally if it differs from the cached copy — so a castmate who already
  /// joined picks up the organizer's later edits (typo fixes, OCR cleanup,
  /// added/removed lines). pushScriptToCloud preserves line IDs, so adopting the
  /// cloud copy keeps existing recordings matched. Saves locally only (does NOT
  /// push back — the cloud is the source). Skipped for the organizer, whose own
  /// local copy is authoritative.
  Future<void> _refreshScriptFromCloud(
    WidgetRef ref,
    Production production,
    ScaffoldMessengerState messenger,
  ) async {
    try {
      final myUserId = SupabaseService.instance.currentUser?.id;
      if (myUserId != null && production.organizerId == myUserId) return;

      final cloudLines = await fetchCloudScriptLines(production.id);
      if (cloudLines == null || cloudLines.isEmpty) return;

      final local = ref.read(currentScriptProvider);
      if (local != null && _sameLines(local.lines, cloudLines)) return; // already current

      // The cloud push is a non-atomic delete+insert; a push that died halfway
      // leaves a truncated cloud script. Adopting it here would propagate that
      // truncation to this castmate (and everyone else). Refuse suspiciously
      // large shrinkage — the organizer's next successful push heals the cloud.
      if (local != null &&
          local.lines.length >= 20 &&
          cloudLines.length < local.lines.length ~/ 2) {
        DebugLogService.instance.logError(
          LogCategory.network,
          'Cloud script for ${production.id} has ${cloudLines.length} lines '
          'but local has ${local.lines.length} — looks like a truncated push; '
          'keeping the local copy',
        );
        return;
      }

      final updated = buildParsedScript(production.title, cloudLines);
      await persistScriptLocally(ref, production.id, updated);

      // Only swap the in-memory script if we're still on this production.
      if (ref.read(currentProductionProvider)?.id == production.id) {
        ref.read(currentScriptProvider.notifier).state = updated;
      }
      DebugLogService.instance.log(
        LogCategory.general,
        'Script re-synced from cloud: ${cloudLines.length} lines '
        '(was ${local?.lines.length ?? 0})',
      );
      messenger.showSnackBar(SnackBar(
        content: Text('Script updated from the cast (${cloudLines.length} lines)'),
        duration: const Duration(seconds: 3),
      ));
    } catch (e) {
      DebugLogService.instance.logError(
          LogCategory.network, 'Script cloud refresh failed', e);
    }
  }

  /// Cheap structural equality: same count, and same id/text/character per line.
  bool _sameLines(List<ScriptLine> a, List<ScriptLine> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id ||
          a[i].text != b[i].text ||
          a[i].character != b[i].character) {
        return false;
      }
    }
    return true;
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
    // Local-only: this script just came FROM the cloud — pushing it back would
    // be a pointless (and for cast members RLS-rejected) delete+reinsert.
    final production = ref.read(currentProductionProvider);
    if (production != null) {
      await persistScriptLocally(ref, production.id, script);
    }
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
    final dlog = DebugLogService.instance;
    final title = controller.text.trim();
    if (title.isEmpty) return;
    if (_submittingProduction) {
      dlog.log(LogCategory.general,
          '_submitProduction: BLOCKED by _submittingProduction guard');
      return;
    }
    _submittingProduction = true;
    dlog.log(LogCategory.general,
        '_submitProduction: starting for "$title"');

    // Capture the router NOW, while the dialog's context is still valid. We
    // pop the dialog below (invalidating its context), so navigating later with
    // that context would crash in GoRouter.of. The router itself is stable.
    final router = GoRouter.of(context);

    // Close dialog immediately to prevent any double-trigger.
    controller.clear();
    if (context.mounted) Navigator.pop(context);

    final supa = SupabaseService.instance;
    final productionId = const Uuid().v4();
    final organizerId = supa.isSignedIn ? supa.currentUser!.id : 'local';
    final joinCode = SupabaseService.generateJoinCode();

    final production = Production(
      id: productionId,
      title: title,
      organizerId: organizerId,
      createdAt: DateTime.now(),
      status: ProductionStatus.draft,
      joinCode: joinCode,
    );

    // Optimistic: persist locally and navigate immediately so the new
    // production appears instantly. The cloud insert runs in the background
    // using the same id + join code, so local and cloud stay consistent.
    dlog.log(LogCategory.general,
        '_submitProduction: adding production id=$productionId (optimistic)');
    await ref.read(productionsProvider.notifier).add(production);
    ref.read(currentProductionProvider.notifier).state = production;
    AnalyticsService.instance.logProductionCreated();
    _submittingProduction = false;

    if (supa.isSignedIn) {
      // Fire-and-forget — failure is non-fatal (local copy exists; the sync
      // layer reconciles later), and it must not block the UI.
      unawaited(supa
          .createProduction(title: title, id: productionId, joinCode: joinCode)
          .catchError((Object e) {
        dlog.log(LogCategory.error,
            '_submitProduction: background cloud create failed: $e');
        return <String, dynamic>{};
      }));
    }

    dlog.log(LogCategory.general,
        '_submitProduction: done, navigating to /import');
    // Use the router captured before the dialog was popped — the dialog's
    // context is dead by now, so context.push here would throw.
    router.push('/import');
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
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
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
