import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../data/models/production_models.dart';
import '../../providers/production_providers.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final productions = ref.watch(productionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('LineGuide'),
        actions: [
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
            onTap: () {
              ref.read(currentProductionProvider.notifier).state = production;
              context.push('/import');
            },
          ),
        );
      },
    );
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

  void _submitProduction(
    BuildContext context,
    WidgetRef ref,
    TextEditingController controller,
  ) {
    final title = controller.text.trim();
    if (title.isEmpty) return;

    final production = Production(
      id: const Uuid().v4(),
      title: title,
      organizerId: 'local',
      createdAt: DateTime.now(),
      status: ProductionStatus.draft,
    );

    ref.read(productionsProvider.notifier).add(production);
    ref.read(currentProductionProvider.notifier).state = production;
    Navigator.pop(context);
    context.push('/import');
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
