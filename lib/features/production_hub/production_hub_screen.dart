import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'dart:io';

import '../../core/responsive.dart';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/script_models.dart';
import '../../data/models/production_models.dart';
import '../../data/services/model_manager.dart';
import '../../data/services/script_export.dart';
import '../../data/services/supabase_service.dart';
import '../../data/services/debug_log_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers/production_providers.dart';
import '../script_editor/cloud_sync_dialog.dart';
import '../settings/settings_screen.dart';
import '../../core/toast.dart';

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
  ProviderSubscription<ParsedScript?>? _scriptSubscription;
  ProviderSubscription<Production?>? _productionSubscription;
  String? _productionId;
  bool _awaitingProductionScript = false;
  bool _loadingSavedCharacter = false;
  int _characterLoadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _productionId = ref.read(currentProductionProvider)?.id;
    _checkModels();
    _productionSubscription = ref.listenManual<Production?>(
      currentProductionProvider,
      (_, production) {
        final productionId = production?.id;
        if (productionId == _productionId) return;
        _productionId = productionId;
        _filterAct = null;
        _awaitingProductionScript = true;
        _characterLoadGeneration++;
      },
    );
    _scriptSubscription = ref.listenManual<ParsedScript?>(
      currentScriptProvider,
      (_, script) {
        if (_awaitingProductionScript) {
          if (script == null) return;
          _awaitingProductionScript = false;
          unawaited(_loadSavedCharacter());
          return;
        }
        if (!_loadingSavedCharacter) _clearInvalidCharacter(script);
      },
    );
    _awaitingProductionScript = ref.read(currentScriptProvider) == null;
    if (!_awaitingProductionScript) unawaited(_loadSavedCharacter());
  }

  void _clearInvalidCharacter(ParsedScript? script) {
    if (script == null) return;
    if (ref.read(currentProductionProvider)?.id != _productionId) return;
    final selected = ref.read(rehearsalCharacterProvider);
    if (selected == null ||
        script.characters.any((character) => character.name == selected)) {
      return;
    }

    ref.read(rehearsalCharacterProvider.notifier).state = null;
    unawaited(_saveCharacterChoice(null));
  }

  Future<void> _loadSavedCharacter() async {
    final production = ref.read(currentProductionProvider);
    if (production == null || production.id != _productionId) return;
    final generation = ++_characterLoadGeneration;
    _loadingSavedCharacter = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      if (!_isCurrentProduction(production.id) ||
          generation != _characterLoadGeneration) {
        return;
      }
      final preferenceKey = 'rehearsal_character_${production.id}';
      final saved = prefs.getString(preferenceKey);
      final script = ref.read(currentScriptProvider);
      if (script == null) {
        _awaitingProductionScript = true;
        return;
      }
      if (saved != null) {
        if (script.characters.any((c) => c.name == saved)) {
          ref.read(rehearsalCharacterProvider.notifier).state = saved;
          return;
        }
        await prefs.remove(preferenceKey);
        if (!_isCurrentProduction(production.id) ||
            generation != _characterLoadGeneration) {
          return;
        }
      }

      // Fallback: auto-select from cast membership.
      final castMembers = ref.read(castMembersProvider);
      final userId = SupabaseService.instance.currentUser?.id;
      if (userId == null) return;
      final myMembership = castMembers.where(
        (member) => member.userId == userId && member.characterName.isNotEmpty,
      );
      if (myMembership.isEmpty) return;

      final charName = myMembership.first.characterName;
      final currentScript = ref.read(currentScriptProvider);
      if (currentScript != null &&
          currentScript.characters.any((c) => c.name == charName)) {
        ref.read(rehearsalCharacterProvider.notifier).state = charName;
        unawaited(_saveCharacterChoice(charName));
      }
    } finally {
      if (generation == _characterLoadGeneration) {
        _loadingSavedCharacter = false;
        if (_isCurrentProduction(production.id)) {
          _clearInvalidCharacter(ref.read(currentScriptProvider));
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

  @override
  void dispose() {
    _scriptSubscription?.close();
    _productionSubscription?.close();
    super.dispose();
  }

  Future<void> _checkModels() async {
    // Screenshot mode: pretend models are ready so the banner/prompt is hidden.
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('screenshot_mode') == true) {
      if (mounted) {
        setState(() {
          _checkedModels = true;
          _modelsReady = true;
        });
      }
      return;
    }

    final ready = await ModelManager.instance.isAllReady();
    if (mounted) {
      setState(() {
        _checkedModels = true;
        _modelsReady = ready;
      });

      if (!ready) {
        if (!Platform.isMacOS) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted && !_modelsReady) _showModelPrompt();
          });
        }
      }
    }
  }

  void _showModelPrompt() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.smart_toy, size: 48),
        title: const Text('Download AI Models'),
        content: Text(
          Platform.isAndroid
              ? 'CastCircle uses on-device AI for natural-sounding voices and '
                    'to follow your lines as you speak during rehearsal. '
                    'Download the models now (one-time) for the best '
                    'experience.\n\n'
                    'Without them, rehearsal audio and live line matching '
                    'won\'t be available.'
              : 'CastCircle uses on-device AI for natural-sounding voices '
                    'during rehearsal. Download the voice models now (~180 MB, '
                    'one-time) for the best experience.\n\n'
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

    if (production == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Production')),
        body: const Center(child: Text('No production selected')),
      );
    }

    final hasScript = script != null && script.lines.isNotEmpty;

    return ResponsiveScaffold(
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.download,
                      color: theme.colorScheme.onTertiaryContainer,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'AI models not downloaded — tap to download',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onTertiaryContainer,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      color: theme.colorScheme.onTertiaryContainer,
                    ),
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
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    hintText: 'Select your character',
                    labelText: 'I am rehearsing as',
                    isDense: true,
                  ),
                  items: script.characters.map((char) {
                    final color = AppTheme.colorForCharacter(char.colorIndex);
                    return DropdownMenuItem(
                      value: char.name,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircleAvatar(backgroundColor: color, radius: 8),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              char.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
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
                      ref.read(fastModeEnabledProvider.notifier).state = !ref
                          .read(fastModeEnabledProvider);
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                FilterChip(
                  label: const Text('All Acts'),
                  selected: _filterAct == null,
                  onSelected: (_) => setState(() => _filterAct = null),
                ),
                const SizedBox(width: 8),
                ...script.acts.map(
                  (act) => Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(act),
                      selected: _filterAct == act,
                      onSelected: (_) => setState(
                        () => _filterAct = _filterAct == act ? null : act,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

        // ── Scene cards (scrollable) ──
        Expanded(child: _buildSceneList(context, script, myCharacter)),
      ],
    );
  }

  Map<String, (int, int)>? _sceneCountsCache;
  (List<ScriptLine>, List<ScriptScene>, String?)? _sceneCountsKey;

  /// scene.id → (dialogue count, my-line count), one pass per scene.
  Map<String, (int, int)> _memoSceneCounts(
    ParsedScript script,
    String? myCharacter,
  ) {
    final key = (script.lines, script.scenes, myCharacter);
    if (_sceneCountsCache != null &&
        identical(_sceneCountsKey?.$1, key.$1) &&
        identical(_sceneCountsKey?.$2, key.$2) &&
        _sceneCountsKey?.$3 == key.$3) {
      return _sceneCountsCache!;
    }
    final counts = <String, (int, int)>{};
    for (final scene in script.scenes) {
      var dialogue = 0, mine = 0;
      for (final l in script.linesInScene(scene)) {
        if (l.lineType != LineType.dialogue) continue;
        dialogue++;
        if (myCharacter != null && l.isForCharacter(myCharacter)) mine++;
      }
      counts[scene.id] = (dialogue, mine);
    }
    _sceneCountsKey = key;
    return _sceneCountsCache = counts;
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

    // Hoisted out of itemBuilder: an indexWhere over the cast per character
    // chip made each visible row O(sceneChars × castSize).
    final charIndexByName = {
      for (var i = 0; i < script.characters.length; i++)
        script.characters[i].name: i,
    };

    // Per-scene dialogue/my-line counts, memoized on (lines, character):
    // linesInScene sublists the script per visible row, re-running on every
    // list rebuild (mode toggles, filters) — O(sceneSize) allocation per row.
    final sceneCounts = _memoSceneCounts(script, myCharacter);

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: scenes.length,
      itemBuilder: (context, index) {
        final scene = scenes[index];
        final isMyScene =
            myCharacter != null && scene.characters.contains(myCharacter);
        final (totalDialogue, myLineCount) = sceneCounts[scene.id] ?? (0, 0);

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () {
              ref.read(selectedSceneProvider.notifier).state = scene;
              context.push('/rehearsal');
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: isMyScene
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(
                            context,
                          ).colorScheme.outline.withValues(alpha: 0.3),
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
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                      if (isMyScene)
                        Chip(
                          label: Text('$myLineCount lines'),
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.primaryContainer,
                          labelStyle: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onPrimaryContainer,
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
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.5),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          scene.location,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: 0.6),
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
                      final charIdx = charIndexByName[charName] ?? -1;
                      final color = charIdx >= 0
                          ? AppTheme.colorForCharacter(charIdx)
                          : Colors.grey;
                      final isMe = charName == myCharacter;
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
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
                            fontWeight: isMe
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$totalDialogue lines total',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.4),
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
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  production.status.name.toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
          // ── Script Setup ──
          _drawerSection('Script'),
          if (!hasScript)
            _drawerItem(Icons.upload_file, 'Import Script', () {
              _closeDrawerIfOpen(context);
              context.push('/import');
            })
          else ...[
            _drawerItem(Icons.edit_note, 'Edit Script', () {
              _closeDrawerIfOpen(context);
              context.push('/editor');
            }),
            _drawerItem(Icons.person_search, 'Characters', () {
              _closeDrawerIfOpen(context);
              context.push('/characters');
            }),
            _drawerItem(Icons.auto_awesome_mosaic, 'Scenes', () {
              _closeDrawerIfOpen(context);
              context.push('/scenes');
            }),
          ],
          const Divider(),
          // ── Cast & Recording ──
          _drawerSection('Cast & Recording'),
          _drawerItem(Icons.people_outline, 'Manage Cast', () {
            _closeDrawerIfOpen(context);
            context.push('/cast');
          }),
          if (hasScript)
            _drawerItem(Icons.mic, 'Record Lines', () {
              _closeDrawerIfOpen(context);
              context.push('/record');
            }),
          if (hasScript)
            _drawerItem(Icons.library_music, 'Browse Recordings', () {
              _closeDrawerIfOpen(context);
              context.push('/recordings');
            }),
          const Divider(),
          // ── Cloud Sync ──
          if (isSignedIn) ...[
            _drawerSection('Cloud'),
            _drawerItem(Icons.cloud_upload, 'Push Script to Cloud', () {
              _closeDrawerIfOpen(context);
              _pushToCloud(context);
            }),
            _drawerItem(Icons.cloud_download, 'Pull from Cloud', () {
              _closeDrawerIfOpen(context);
              _syncFromCloud(context);
            }),
            const Divider(),
          ],
          // ── Export ──
          if (hasScript) ...[
            _drawerSection('Export'),
            _drawerItem(Icons.text_snippet, 'Export as Text', () {
              _closeDrawerIfOpen(context);
              _export(context, 'plain');
            }),
            _drawerItem(Icons.article, 'Export as Markdown', () {
              _closeDrawerIfOpen(context);
              _export(context, 'markdown');
            }),
            const Divider(),
          ],
          // ── Voices & History ──
          _drawerItem(Icons.record_voice_over, 'Voice Preset & Config', () {
            _closeDrawerIfOpen(context);
            context.push('/voice-config');
          }),
          _drawerItem(Icons.history, 'Rehearsal History', () {
            _closeDrawerIfOpen(context);
            context.push('/history');
          }),
          _drawerItem(Icons.smart_toy, 'AI Models', () async {
            _closeDrawerIfOpen(context);
            await context.push('/ai-models');
            _checkModels();
          }),
          _drawerItem(Icons.settings, 'Settings', () {
            _closeDrawerIfOpen(context);
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

  void _closeDrawerIfOpen(BuildContext context) {
    // ResponsiveScaffold embeds this drawer on wide layouts. On compact
    // layouts an action can only be tapped while the modal drawer is open.
    if (!Responsive.isWide(context)) {
      Navigator.pop(context);
    }
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
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.5),
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
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.6),
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
        ScaffoldMessenger.of(context).showAutoToast(
          const SnackBar(
            content: Text('Script pushed to cloud'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e, stack) {
      DebugLogService.instance.logError(
        LogCategory.network,
        'Pushing the script to cloud failed',
        e,
        stack,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showAutoToast(
          const SnackBar(
            content: Text(
              'Couldn\'t push the script. Check your connection and try again.',
            ),
          ),
        );
      }
    }
  }

  bool _isCurrentProduction(String productionId) {
    return mounted &&
        _productionId == productionId &&
        ref.read(currentProductionProvider)?.id == productionId;
  }

  Future<void> _syncFromCloud(BuildContext context) async {
    final production = ref.read(currentProductionProvider);
    if (production == null) return;
    final scriptNotifier = ref.read(currentScriptProvider.notifier);

    try {
      final cloudLines = await fetchCloudScriptLines(production.id);
      if (!_isCurrentProduction(production.id)) return;
      if (cloudLines == null || cloudLines.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showAutoToast(const SnackBar(content: Text('No script in cloud')));
        }
        return;
      }

      final cloudScript = await buildParsedScriptWithCloudScenes(
        production.title,
        cloudLines,
        production.id,
      );
      if (!_isCurrentProduction(production.id)) return;
      final localScript = ref.read(currentScriptProvider);

      if (localScript != null &&
          diffScriptLines(
            localScript.lines,
            cloudScript.lines,
          ).every((diff) => diff.type == DiffType.unchanged)) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showAutoToast(
            const SnackBar(content: Text('Local script is already up to date')),
          );
        }
        return;
      }

      var shouldReplaceLocal = true;
      if (localScript != null && context.mounted) {
        final choice = await showCloudSyncDialog(
          context: context,
          localLines: localScript.lines,
          cloudLines: cloudScript.lines,
        );
        shouldReplaceLocal = choice == true;
        if (!_isCurrentProduction(production.id)) return;
      }

      if (!shouldReplaceLocal) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showAutoToast(const SnackBar(content: Text('Kept local script')));
        }
        return;
      }

      if (!_isCurrentProduction(production.id)) return;
      scriptNotifier.state = cloudScript;
      // Local-only: this script just came FROM the cloud — persistScript
      // would push it straight back (an unnecessary delete+reinsert window
      // for the whole cast).
      await persistScriptLocally(ref, production.id, cloudScript);
      if (!_isCurrentProduction(production.id)) return;

      if (context.mounted) {
        ScaffoldMessenger.of(context).showAutoToast(
          SnackBar(
            content: Text('Loaded ${cloudLines.length} lines from cloud'),
          ),
        );
      }
    } catch (e, stack) {
      DebugLogService.instance.logError(
        LogCategory.network,
        'Pulling the script from cloud failed',
        e,
        stack,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showAutoToast(
          const SnackBar(
            content: Text(
              'Couldn\'t pull the script. Check your connection and try again.',
            ),
          ),
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
      final sanitizedName = production.title
          .replaceAll(RegExp(r'[^\w\s-]'), '')
          .replaceAll(RegExp(r'\s+'), '_')
          .toLowerCase();
      final safeName = sanitizedName.isEmpty
          ? 'export_${production.id}'
          : sanitizedName;

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
    } catch (e, stack) {
      DebugLogService.instance.logError(
        LogCategory.error,
        'Exporting the script failed',
        e,
        stack,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showAutoToast(
        const SnackBar(
          content: Text('Couldn\'t export the script. Try again.'),
        ),
      );
    }
  }
}
