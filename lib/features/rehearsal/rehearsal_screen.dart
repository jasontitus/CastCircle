import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/script_models.dart';
import '../../providers/production_providers.dart';
import '../../features/settings/settings_screen.dart';
import 'scene_selector_screen.dart';

/// Rehearsal state machine.
enum RehearsalState {
  ready,
  playingOther,
  listeningForMe,
  paused,
  sceneComplete,
}

/// Provider tracking the rehearsal engine state.
final rehearsalStateProvider =
    StateProvider<RehearsalState>((ref) => RehearsalState.ready);

/// Current line index within the scene.
final currentLineIndexProvider = StateProvider<int>((ref) => 0);

class RehearsalScreen extends ConsumerStatefulWidget {
  const RehearsalScreen({super.key});

  @override
  ConsumerState<RehearsalScreen> createState() => _RehearsalScreenState();
}

class _RehearsalScreenState extends ConsumerState<RehearsalScreen> {
  late ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    // Reset to beginning
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(currentLineIndexProvider.notifier).state = 0;
      ref.read(rehearsalStateProvider.notifier).state = RehearsalState.ready;
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final script = ref.watch(currentScriptProvider);
    final scene = ref.watch(selectedSceneProvider);
    final myCharacter = ref.watch(rehearsalCharacterProvider);
    final currentIdx = ref.watch(currentLineIndexProvider);
    final state = ref.watch(rehearsalStateProvider);
    final jumpBackLines = ref.watch(jumpBackLinesProvider);

    if (script == null || scene == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Rehearsal')),
        body: const Center(child: Text('No scene selected')),
      );
    }

    final sceneLines = script.linesInScene(scene);
    final dialogueLines =
        sceneLines.where((l) => l.lineType == LineType.dialogue).toList();

    final isComplete = currentIdx >= dialogueLines.length;
    final currentLine =
        isComplete ? null : dialogueLines[currentIdx];
    final isMyLine = currentLine?.character == myCharacter;
    final progress = dialogueLines.isEmpty
        ? 0.0
        : currentIdx / dialogueLines.length;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar: scene name + progress + close
            _buildTopBar(context, scene, progress),
            // Progress bar
            LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.grey[900],
              color: isMyLine
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey[600],
            ),
            // Main content: scrolling script
            Expanded(
              child: isComplete
                  ? _buildCompletionView(context, scene, dialogueLines.length)
                  : _buildScriptView(
                      context,
                      script,
                      dialogueLines,
                      currentIdx,
                      myCharacter,
                    ),
            ),
            // Bottom controls
            _buildControls(
              context,
              state,
              isMyLine,
              isComplete,
              currentIdx,
              dialogueLines.length,
              jumpBackLines,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(
      BuildContext context, ScriptScene scene, double progress) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70),
            onPressed: () => context.pop(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  scene.sceneName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                if (scene.location.isNotEmpty)
                  Text(
                    scene.location,
                    style: TextStyle(
                      color: Colors.grey[500],
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          Text(
            '${(progress * 100).toInt()}%',
            style: TextStyle(color: Colors.grey[500], fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildScriptView(
    BuildContext context,
    ParsedScript script,
    List<ScriptLine> dialogueLines,
    int currentIdx,
    String? myCharacter,
  ) {
    // Show a window of lines: past lines (faded), current (bright), upcoming (dim)
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      itemCount: dialogueLines.length,
      itemBuilder: (context, index) {
        final line = dialogueLines[index];
        final isCurrent = index == currentIdx;
        final isPast = index < currentIdx;
        final isMe = line.character == myCharacter;

        final charIdx = script.characters
            .indexWhere((c) => c.name == line.character);
        final color = charIdx >= 0
            ? AppTheme.colorForCharacter(charIdx)
            : Colors.grey;

        double opacity;
        if (isCurrent) {
          opacity = 1.0;
        } else if (isPast) {
          opacity = 0.25;
        } else {
          opacity = 0.5;
        }

        return Opacity(
          opacity: opacity,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 6),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isCurrent
                  ? (isMe
                      ? Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.15)
                      : Colors.grey[900])
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: isCurrent
                  ? Border.all(
                      color: isMe
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey[700]!,
                      width: isMe ? 2 : 1,
                    )
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isMe ? 'YOU (${line.character})' : line.character,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    if (isCurrent && isMe) ...[
                      const Spacer(),
                      Icon(
                        Icons.mic,
                        size: 16,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'YOUR LINE',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                if (line.stageDirection.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '(${line.stageDirection})',
                      style: TextStyle(
                        fontStyle: FontStyle.italic,
                        color: Colors.grey[600],
                        fontSize: 13,
                      ),
                    ),
                  ),
                Text(
                  line.text,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: isCurrent ? 18 : 15,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCompletionView(
      BuildContext context, ScriptScene scene, int totalLines) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 80,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 24),
            const Text(
              'Scene Complete!',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${scene.sceneName}\n$totalLines lines',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[500], fontSize: 16),
            ),
            const SizedBox(height: 32),
            // Big "Run Again" button
            FilledButton.icon(
              onPressed: _restartScene,
              icon: const Icon(Icons.replay),
              label: const Text('Run Again'),
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                textStyle: const TextStyle(fontSize: 18),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => context.pop(),
              child: const Text('Choose Another Scene'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls(
    BuildContext context,
    RehearsalState state,
    bool isMyLine,
    bool isComplete,
    int currentIdx,
    int totalLines,
    int jumpBackLines,
  ) {
    if (isComplete) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Jump back
          _controlButton(
            context,
            icon: Icons.replay,
            label: 'Back $jumpBackLines',
            onTap: currentIdx > 0
                ? () => _jumpBack(jumpBackLines, totalLines)
                : null,
          ),
          // Restart scene
          _controlButton(
            context,
            icon: Icons.restart_alt,
            label: 'Restart',
            onTap: _restartScene,
          ),
          // Next line (manual advance)
          _controlButton(
            context,
            icon: isMyLine ? Icons.mic : Icons.skip_next,
            label: isMyLine ? 'Done' : 'Next',
            onTap: () => _advanceLine(totalLines),
            primary: true,
          ),
          // Pause
          _controlButton(
            context,
            icon: state == RehearsalState.paused
                ? Icons.play_arrow
                : Icons.pause,
            label: state == RehearsalState.paused ? 'Resume' : 'Pause',
            onTap: _togglePause,
          ),
        ],
      ),
    );
  }

  Widget _controlButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    bool primary = false,
  }) {
    final color = onTap == null
        ? Colors.grey[700]
        : primary
            ? Theme.of(context).colorScheme.primary
            : Colors.white70;

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: primary ? 56 : 44,
            height: primary ? 56 : 44,
            decoration: BoxDecoration(
              color: primary
                  ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)
                  : Colors.grey[850],
              shape: BoxShape.circle,
              border: primary
                  ? Border.all(
                      color: Theme.of(context).colorScheme.primary, width: 2)
                  : null,
            ),
            child: Icon(icon, color: color, size: primary ? 28 : 22),
          ),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(color: color, fontSize: 10)),
        ],
      ),
    );
  }

  void _advanceLine(int totalLines) {
    final current = ref.read(currentLineIndexProvider);
    if (current < totalLines) {
      ref.read(currentLineIndexProvider.notifier).state = current + 1;
      _scrollToCurrentLine();
    }
  }

  void _jumpBack(int jumpCount, int totalLines) {
    final current = ref.read(currentLineIndexProvider);
    final newIdx = (current - jumpCount).clamp(0, totalLines - 1);
    ref.read(currentLineIndexProvider.notifier).state = newIdx;
    _scrollToCurrentLine();
  }

  void _restartScene() {
    ref.read(currentLineIndexProvider.notifier).state = 0;
    ref.read(rehearsalStateProvider.notifier).state = RehearsalState.ready;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _togglePause() {
    final current = ref.read(rehearsalStateProvider);
    ref.read(rehearsalStateProvider.notifier).state =
        current == RehearsalState.paused
            ? RehearsalState.ready
            : RehearsalState.paused;
  }

  void _scrollToCurrentLine() {
    final idx = ref.read(currentLineIndexProvider);
    // Approximate scroll position
    final offset = (idx * 100.0).clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.animateTo(
      offset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }
}
