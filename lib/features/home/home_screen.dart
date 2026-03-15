import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../data/models/production_models.dart';
import '../../data/models/script_models.dart';
import '../../data/services/supabase_service.dart';
import '../../features/script_editor/cloud_sync_dialog.dart';
import '../../providers/production_providers.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _hasSynced = false;

  @override
  Widget build(BuildContext context) {
    final productions = ref.watch(productionsProvider);

    // One-time cloud sync on first build
    if (!_hasSynced) {
      _hasSynced = true;
      Future.microtask(() => _syncCloudProductions(ref));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('LineGuide'),
        actions: [
          if (SupabaseService.instance.isSignedIn)
            IconButton(
              icon: const Icon(Icons.cloud_sync),
              tooltip: 'Sync from Cloud',
              onPressed: () => _syncCloudProductions(ref),
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createProduction(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('New Production'),
      ),
    );
  }

  /// Pull cloud productions into the local list.
  Future<void> _syncCloudProductions(WidgetRef ref) async {
    final supa = SupabaseService.instance;
    if (!supa.isInitialized || !supa.isSignedIn) return;

    try {
      final cloudProductions = await supa.fetchMyProductions();
      final localProductions = ref.read(productionsProvider);
      final localIds = localProductions.map((p) => p.id).toSet();

      for (final row in cloudProductions) {
        final id = row['id'] as String;
        if (!localIds.contains(id)) {
          // Cloud production not in local — add it
          final production = Production(
            id: id,
            title: row['title'] as String,
            organizerId: row['organizer_id'] as String,
            createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
                DateTime.now(),
            status: _parseStatus(row['status'] as String? ?? 'draft'),
          );
          await ref.read(productionsProvider.notifier).add(production);
        }
      }
    } catch (e) {
      debugPrint('Cloud production sync failed: $e');
    }
  }

  ProductionStatus _parseStatus(String s) {
    for (final status in ProductionStatus.values) {
      if (status.name == s) return status;
    }
    return ProductionStatus.draft;
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
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Icon(
                Icons.theater_comedy,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
            title: Text(production.title),
            subtitle: Text(production.status.name.toUpperCase()),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openProduction(context, ref, production),
          ),
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
    ref.read(recordingsProvider.notifier).loadForProduction(production.id);

    // Load local script first — this is fast (local disk)
    final savedScript = await loadPersistedScript(ref, production.id);

    if (savedScript != null) {
      // Have local script — navigate immediately, check cloud in background
      ref.read(currentScriptProvider.notifier).state = ParsedScript(
        title: production.title,
        lines: savedScript.lines,
        characters: savedScript.characters,
        scenes: savedScript.scenes,
        rawText: savedScript.rawText,
      );
      if (context.mounted) context.push('/production');

      // Check cloud for updates in background (non-blocking)
      _backgroundCloudSync(context, ref, production, savedScript);
      return;
    }

    // No local script — check cloud (may be slow but unavoidable)
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
    } else {
      // No script anywhere — go to import
      if (context.mounted) context.push('/import');
    }
  }

  /// Check cloud for script updates after navigating — non-blocking.
  Future<void> _backgroundCloudSync(
    BuildContext context,
    WidgetRef ref,
    Production production,
    ParsedScript savedScript,
  ) async {
    try {
      final cloudLines = await fetchCloudScriptLines(production.id);
      if (cloudLines == null || cloudLines.isEmpty) return;

      final localLines = savedScript.lines;
      if (!_scriptsDiffer(localLines, cloudLines)) return;

      // Cloud has different version — prompt user
      if (!context.mounted) return;
      final accept = await showCloudSyncDialog(
        context: context,
        localLines: localLines,
        cloudLines: cloudLines,
      );

      if (accept == true) {
        final script = buildParsedScript(production.title, cloudLines);
        ref.read(currentScriptProvider.notifier).state = script;
        await persistScript(ref);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Cloud script accepted'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Background cloud sync failed: $e');
    }
  }

  bool _scriptsDiffer(List<ScriptLine> local, List<ScriptLine> cloud) {
    if (local.length != cloud.length) return true;
    for (var i = 0; i < local.length; i++) {
      if (local[i].character != cloud[i].character ||
          local[i].text != cloud[i].text ||
          local[i].lineType != cloud[i].lineType ||
          local[i].stageDirection != cloud[i].stageDirection) {
        return true;
      }
    }
    return false;
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

    // If signed in, create in Supabase first so IDs match
    if (supa.isSignedIn) {
      try {
        final row = await supa.createProduction(title: title);
        productionId = row['id'] as String;
        organizerId = supa.currentUser!.id;
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
    );

    ref.read(productionsProvider.notifier).add(production);
    ref.read(currentProductionProvider.notifier).state = production;
    if (context.mounted) {
      Navigator.pop(context);
      context.push('/import');
    }
  }

  void _showAbout(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: 'LineGuide',
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
