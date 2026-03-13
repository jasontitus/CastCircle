import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/script_models.dart';
import '../../providers/production_providers.dart';

/// Provider for the character the user is rehearsing as.
final rehearsalCharacterProvider = StateProvider<String?>((ref) => null);

/// Provider for the selected scene to rehearse.
final selectedSceneProvider = StateProvider<ScriptScene?>((ref) => null);

/// Cue-to-cue mode: skip to just before each of the actor's lines.
final cueToCueModeProvider = StateProvider<bool>((ref) => false);

class SceneSelectorScreen extends ConsumerStatefulWidget {
  const SceneSelectorScreen({super.key});

  @override
  ConsumerState<SceneSelectorScreen> createState() =>
      _SceneSelectorScreenState();
}

class _SceneSelectorScreenState extends ConsumerState<SceneSelectorScreen> {
  String? _filterAct;

  @override
  Widget build(BuildContext context) {
    final script = ref.watch(currentScriptProvider);
    final myCharacter = ref.watch(rehearsalCharacterProvider);

    if (script == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Select Scene')),
        body: const Center(child: Text('No script loaded')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose a Scene'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: Column(
        children: [
          // Character selector
          _buildCharacterSelector(context, script, myCharacter),
          const Divider(height: 1),
          // Rehearsal mode toggle
          if (myCharacter != null) _buildModeToggle(context),
          // Act filter
          if (script.acts.length > 1) _buildActFilter(context, script),
          // Scene list
          Expanded(
            child: _buildSceneList(context, script, myCharacter),
          ),
        ],
      ),
    );
  }

  Widget _buildCharacterSelector(
    BuildContext context,
    ParsedScript script,
    String? myCharacter,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'I am rehearsing as:',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: myCharacter,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              hintText: 'Select your character',
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
                    Text(char.name),
                    const Spacer(),
                    Text(
                      '${char.lineCount} lines',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              );
            }).toList(),
            onChanged: (value) {
              ref.read(rehearsalCharacterProvider.notifier).state = value;
            },
          ),
        ],
      ),
    );
  }

  Widget _buildModeToggle(BuildContext context) {
    final cueToCue = ref.watch(cueToCueModeProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('Full Scene'),
                  icon: Icon(Icons.playlist_play),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('Cue-to-Cue'),
                  icon: Icon(Icons.skip_next),
                ),
              ],
              selected: {cueToCue},
              onSelectionChanged: (selected) {
                ref.read(cueToCueModeProvider.notifier).state =
                    selected.first;
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActFilter(BuildContext context, ParsedScript script) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
    );
  }

  Widget _buildSceneList(
    BuildContext context,
    ParsedScript script,
    String? myCharacter,
  ) {
    var scenes = script.scenes;

    // Filter by act
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Scene header with color bar
                Container(
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
                                  ?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
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
                            Icon(
                              Icons.place,
                              size: 14,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.5),
                            ),
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
              ],
            ),
          ),
        );
      },
    );
  }
}
