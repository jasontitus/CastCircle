import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/script_models.dart';
import '../../data/models/rehearsal_models.dart';
import '../../data/services/tts_service.dart';
import '../../data/services/stt_service.dart';
import '../../data/services/stt_adaptation_service.dart';
import '../../data/services/voice_clone_service.dart';
import '../../data/services/voice_config_service.dart';
import '../../providers/production_providers.dart';
import '../../features/settings/settings_screen.dart';
import 'scene_selector_screen.dart';
import 'rehearsal_history_screen.dart';

/// Rehearsal state machine.
enum RehearsalState {
  ready, // waiting to start or between lines
  playingOther, // playing another character's recording/TTS
  listeningForMe, // STT active, waiting for actor to speak
  paused, // user paused
  sceneComplete, // all lines done
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
  final AudioPlayer _player = AudioPlayer();
  final TtsService _tts = TtsService.instance;
  final SttService _stt = SttService.instance;
  final VoiceCloneService _voiceClone = VoiceCloneService.instance;
  final SttAdaptationService _sttAdapt = SttAdaptationService.instance;
  String? _activeAdapter; // per-actor or per-production LoRA adapter path
  final GlobalKey _currentLineKey = GlobalKey();

  final bool _autoPlay = true; // auto-advance through other characters' lines
  String _recognizedText = '';
  double _matchScore = 0.0;
  bool _showMatchFeedback = false;

  // Session tracking
  late DateTime _sessionStartedAt;
  final List<LineAttempt> _lineAttempts = [];
  int _currentAttemptCount = 0;
  double _currentBestScore = 0.0;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();

    _sessionStartedAt = DateTime.now();

    // Reset to beginning
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(currentLineIndexProvider.notifier).state = 0;
      ref.read(rehearsalStateProvider.notifier).state = RehearsalState.ready;
      _initAudio();
    });

    // Listen for playback completion to auto-advance
    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed &&
          _autoPlay &&
          mounted) {
        _onOtherLineFinished();
      }
    });
  }

  Future<void> _initAudio() async {
    await _tts.init();

    // Assign voices to characters using production voice config
    final script = ref.read(currentScriptProvider);
    final production = ref.read(currentProductionProvider);
    if (script != null) {
      final voiceConfig = VoiceConfigService.instance;
      for (var i = 0; i < script.characters.length; i++) {
        final char = script.characters[i];
        if (production != null) {
          final voiceId = await voiceConfig.resolveVoice(
            production.id, char.name, i,
            isFemale: char.gender != CharacterGender.male,
          );
          final speed =
              await voiceConfig.resolveSpeed(production.id, char.name);
          _tts.assignVoice(char.name, i, voiceId: voiceId, speed: speed);
        } else {
          _tts.assignVoice(charName, i);
        }
      }
    }

    _tts.setCompletionHandler(() {
      if (_autoPlay && mounted) {
        _onOtherLineFinished();
      }
    });

    // Check for per-actor or per-production STT adapter
    final myCharacter = ref.read(rehearsalCharacterProvider);
    if (production != null && myCharacter != null) {
      _activeAdapter = _sttAdapt.getBestAdapter(production.id, myCharacter);
      if (_activeAdapter != null) {
        debugPrint('Rehearsal: Using adapted STT model: $_activeAdapter');
      }
    }

    // Auto-start if enabled
    if (_autoPlay) {
      _processCurrentLine();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _player.dispose();
    _tts.stop();
    _stt.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final script = ref.watch(currentScriptProvider);
    final scene = ref.watch(selectedSceneProvider);
    final myCharacter = ref.watch(rehearsalCharacterProvider);
    final currentIdx = ref.watch(currentLineIndexProvider);
    final rehearsalState = ref.watch(rehearsalStateProvider);
    final jumpBackLines = ref.watch(jumpBackLinesProvider);

    if (script == null || scene == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Rehearsal')),
        body: const Center(child: Text('No scene selected')),
      );
    }

    final cueToCue = ref.watch(cueToCueModeProvider);
    final dialogueLines = _getRehearsalLines(script, scene, myCharacter);

    final isComplete = currentIdx >= dialogueLines.length;
    final currentLine = isComplete ? null : dialogueLines[currentIdx];
    final isMyLine = currentLine?.character == myCharacter;
    final progress = dialogueLines.isEmpty
        ? 0.0
        : currentIdx / dialogueLines.length;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(context, scene, progress, rehearsalState, cueToCue),
            LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.grey[900],
              color: isMyLine
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey[600],
            ),
            Expanded(
              child: isComplete
                  ? _buildCompletionView(context, scene, dialogueLines.length)
                  : _buildScriptView(
                      context, script, dialogueLines, currentIdx, myCharacter,
                      rehearsalState),
            ),
            // Match feedback for STT
            if (_showMatchFeedback && isMyLine)
              _buildMatchFeedback(context),
            _buildControls(
              context, rehearsalState, isMyLine, isComplete,
              currentIdx, dialogueLines.length, jumpBackLines,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, ScriptScene scene, double progress,
      RehearsalState rehearsalState, bool cueToCue) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70),
            onPressed: () {
              _tts.stop();
              _stt.stop();
              _player.stop();
              context.pop();
            },
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
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  ),
              ],
            ),
          ),
          // Cue-to-cue badge
          if (cueToCue)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('C2C',
                  style: TextStyle(color: Colors.blue, fontSize: 9,
                      fontWeight: FontWeight.bold)),
            ),
          // Voice clone opt-out badge
          if (!ref.watch(voiceCloningEnabledProvider))
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('No Clone',
                  style: TextStyle(color: Colors.orange, fontSize: 9,
                      fontWeight: FontWeight.bold)),
            ),
          // Adapted STT badge
          if (_activeAdapter != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('AI',
                  style: TextStyle(color: Colors.green, fontSize: 9,
                      fontWeight: FontWeight.bold)),
            ),
          // State indicator
          _buildStateChip(rehearsalState),
          const SizedBox(width: 8),
          Text(
            '${(progress * 100).toInt()}%',
            style: TextStyle(color: Colors.grey[500], fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildStateChip(RehearsalState state) {
    String label;
    Color color;
    IconData icon;

    switch (state) {
      case RehearsalState.playingOther:
        label = 'Playing';
        color = Colors.green;
        icon = Icons.volume_up;
      case RehearsalState.listeningForMe:
        label = 'Listening';
        color = Colors.orange;
        icon = Icons.mic;
      case RehearsalState.paused:
        label = 'Paused';
        color = Colors.grey;
        icon = Icons.pause;
      case RehearsalState.sceneComplete:
        label = 'Done';
        color = Colors.blue;
        icon = Icons.check;
      case RehearsalState.ready:
        label = 'Ready';
        color = Colors.grey;
        icon = Icons.hourglass_empty;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontSize: 10)),
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
    RehearsalState rehearsalState,
  ) {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      itemCount: dialogueLines.length,
      itemBuilder: (context, index) {
        final line = dialogueLines[index];
        final isCurrent = index == currentIdx;
        final isPast = index < currentIdx;
        final isMe = line.character == myCharacter;

        final charIdx =
            script.characters.indexWhere((c) => c.name == line.character);
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
          key: isCurrent ? _currentLineKey : null,
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
                      if (rehearsalState == RehearsalState.listeningForMe) ...[
                        _pulsingMic(context),
                      ] else ...[
                        Icon(Icons.mic, size: 16,
                            color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 4),
                        Text('YOUR LINE',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ],
                    if (isCurrent && !isMe &&
                        rehearsalState == RehearsalState.playingOther) ...[
                      const Spacer(),
                      Icon(Icons.volume_up, size: 14, color: Colors.green[400]),
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
                // Show recognized text under current line if listening
                if (isCurrent && isMe && _recognizedText.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _recognizedText,
                      style: TextStyle(
                        color: Colors.grey[400],
                        fontSize: 14,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _pulsingMic(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.5, end: 1.0),
      duration: const Duration(milliseconds: 800),
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.mic, size: 16,
                  color: Colors.orange[400]),
              const SizedBox(width: 4),
              Text('LISTENING...',
                style: TextStyle(
                  color: Colors.orange[400],
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMatchFeedback(BuildContext context) {
    final threshold = ref.read(matchThresholdProvider) / 100.0;
    final matched = _matchScore >= threshold;
    final percentage = (_matchScore * 100).toInt();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: matched
          ? Colors.green.withValues(alpha: 0.2)
          : Colors.orange.withValues(alpha: 0.2),
      child: Row(
        children: [
          Icon(
            matched ? Icons.check_circle : Icons.info_outline,
            color: matched ? Colors.green : Colors.orange,
            size: 18,
          ),
          const SizedBox(width: 8),
          Text(
            matched ? 'Match! $percentage%' : '$percentage% — keep going',
            style: TextStyle(
              color: matched ? Colors.green : Colors.orange,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompletionView(
      BuildContext context, ScriptScene scene, int totalLines) {
    final completedLines = _lineAttempts.where((a) => !a.skipped).length;
    final avgScore = _lineAttempts.isEmpty
        ? 0.0
        : _lineAttempts.fold<double>(0, (s, a) => s + a.bestScore) /
            _lineAttempts.length;
    final struggled = _lineAttempts.where((a) => a.bestScore < 0.7).toList();
    final duration = DateTime.now().difference(_sessionStartedAt);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              avgScore >= 0.8
                  ? Icons.emoji_events
                  : Icons.check_circle_outline,
              size: 80,
              color: avgScore >= 0.8 ? Colors.amber : Theme.of(context).colorScheme.primary,
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
              scene.sceneName,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[500], fontSize: 16),
            ),
            const SizedBox(height: 16),
            // Stats row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _completionStat('${(avgScore * 100).toInt()}%', 'Score',
                    avgScore >= 0.8 ? Colors.green : Colors.orange),
                _completionStat('$completedLines/$totalLines', 'Lines',
                    Colors.white70),
                _completionStat(
                    '${duration.inMinutes}m ${duration.inSeconds.remainder(60)}s',
                    'Time',
                    Colors.white70),
              ],
            ),
            // Struggled lines
            if (struggled.isNotEmpty) ...[
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Lines to practice:',
                        style: TextStyle(color: Colors.orange,
                            fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 8),
                    ...struggled.take(5).map((a) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            '- ${a.lineText}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: Colors.grey[400], fontSize: 12),
                          ),
                        )),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 32),
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
            OutlinedButton.icon(
              onPressed: () => context.push('/history'),
              icon: const Icon(Icons.history),
              label: const Text('View History'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () {
                _tts.stop();
                _stt.stop();
                _player.stop();
                context.pop();
              },
              child: const Text('Choose Another Scene'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _completionStat(String value, String label, Color color) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(
                color: color, fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(label,
            style: TextStyle(color: Colors.grey[600], fontSize: 12)),
      ],
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
          _controlButton(
            context,
            icon: Icons.replay,
            label: 'Back $jumpBackLines',
            onTap: currentIdx > 0
                ? () => _jumpBack(jumpBackLines, totalLines)
                : null,
          ),
          _controlButton(
            context,
            icon: Icons.restart_alt,
            label: 'Restart',
            onTap: _restartScene,
          ),
          // Main action button changes based on state
          _controlButton(
            context,
            icon: _mainActionIcon(state, isMyLine),
            label: _mainActionLabel(state, isMyLine),
            onTap: () => _mainAction(state, isMyLine, totalLines),
            primary: true,
          ),
          _controlButton(
            context,
            icon: state == RehearsalState.paused
                ? Icons.play_arrow
                : Icons.pause,
            label: state == RehearsalState.paused ? 'Resume' : 'Pause',
            onTap: () => _togglePause(totalLines),
          ),
        ],
      ),
    );
  }

  IconData _mainActionIcon(RehearsalState state, bool isMyLine) {
    if (state == RehearsalState.ready && isMyLine) return Icons.mic;
    if (state == RehearsalState.listeningForMe) return Icons.skip_next;
    if (state == RehearsalState.ready) return Icons.play_arrow;
    return Icons.skip_next;
  }

  String _mainActionLabel(RehearsalState state, bool isMyLine) {
    if (state == RehearsalState.ready && isMyLine) return 'Speak';
    if (state == RehearsalState.listeningForMe) return 'Skip';
    if (state == RehearsalState.ready) return 'Play';
    return 'Next';
  }

  void _mainAction(RehearsalState state, bool isMyLine, int totalLines) {
    switch (state) {
      case RehearsalState.ready:
        _processCurrentLine();
      case RehearsalState.playingOther:
        // Skip to next
        _tts.stop();
        _player.stop();
        _advanceLine(totalLines);
      case RehearsalState.listeningForMe:
        // Accept whatever was said and advance (manual skip)
        _stt.stop();
        _recordCurrentLineAttempt(skipped: _matchScore < (ref.read(matchThresholdProvider) / 100.0));
        _advanceLine(totalLines);
      case RehearsalState.paused:
      case RehearsalState.sceneComplete:
        break;
    }
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
                  ? Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.2)
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

  // ── Cue-to-Cue Filtering ─────────────────────────────

  /// Returns the dialogue lines to rehearse, filtered for cue-to-cue mode
  /// if enabled. In cue-to-cue mode, only the actor's lines plus one cue
  /// line before each are included.
  List<ScriptLine> _getRehearsalLines(
      ParsedScript script, ScriptScene scene, String? myCharacter) {
    final sceneLines = script.linesInScene(scene);
    final allDialogue =
        sceneLines.where((l) => l.lineType == LineType.dialogue).toList();

    final cueToCue = ref.read(cueToCueModeProvider);
    if (!cueToCue || myCharacter == null) return allDialogue;

    // Build a filtered list: for each of the actor's lines, include
    // the immediately preceding line (the cue) plus the actor's line.
    final filtered = <ScriptLine>[];
    for (var i = 0; i < allDialogue.length; i++) {
      if (allDialogue[i].character == myCharacter) {
        // Add cue line (the one before) if not already added
        if (i > 0 && !filtered.contains(allDialogue[i - 1])) {
          filtered.add(allDialogue[i - 1]);
        }
        filtered.add(allDialogue[i]);
      }
    }
    return filtered;
  }

  // ── Engine Logic ──────────────────────────────────────

  /// Process the current line: play audio/TTS for others, or start listening for me.
  void _processCurrentLine() {
    final script = ref.read(currentScriptProvider);
    final scene = ref.read(selectedSceneProvider);
    final myCharacter = ref.read(rehearsalCharacterProvider);
    final currentIdx = ref.read(currentLineIndexProvider);

    if (script == null || scene == null) return;

    final dialogueLines = _getRehearsalLines(script, scene, myCharacter);

    if (currentIdx >= dialogueLines.length) {
      ref.read(rehearsalStateProvider.notifier).state =
          RehearsalState.sceneComplete;
      _saveSession(dialogueLines);
      return;
    }

    final line = dialogueLines[currentIdx];
    final isMyLine = line.character == myCharacter;

    // Always scroll to the current line so the actor can see it
    _scrollToCurrentLine();

    // Reset attempt tracking for new line
    _currentAttemptCount = 0;
    _currentBestScore = 0.0;

    if (isMyLine) {
      _startListeningForMyLine(line);
    } else {
      _playOtherLine(line);
    }
  }

  /// Play another character's line.
  ///
  /// Audio priority chain:
  ///   1. Real recording by primary actor
  ///   2. Real recording by understudy (if understudy fallback enabled)
  ///   3. Voice-cloned audio (if voice cloning enabled)
  ///   4. Kokoro TTS (default fallback — never uses system TTS)
  Future<void> _playOtherLine(ScriptLine line) async {
    ref.read(rehearsalStateProvider.notifier).state =
        RehearsalState.playingOther;
    setState(() {
      _showMatchFeedback = false;
      _recognizedText = '';
    });

    final speed = ref.read(playbackSpeedProvider);

    // 1. Check for a primary actor recording first
    final recordings = ref.read(recordingsProvider);
    final recording = recordings[line.id];

    if (recording != null) {
      try {
        await _player.setFilePath(recording.localPath);
        await _player.setSpeed(speed);
        await _player.play();
        return;
      } catch (_) {
        // Fall through to understudy
      }
    }

    // 2. Understudy fallback — use understudy recording if primary is missing
    final understudyFallback = ref.read(understudyFallbackProvider);
    if (understudyFallback) {
      final understudyRecordings = ref.read(understudyRecordingsProvider);
      final understudyRecording = understudyRecordings[line.id];

      if (understudyRecording != null) {
        try {
          await _player.setFilePath(understudyRecording.localPath);
          await _player.setSpeed(speed);
          await _player.play();
          return;
        } catch (_) {
          // Fall through to voice clone
        }
      }
    }

    // 3. Try voice clone if enabled and a profile exists for this character
    final voiceCloningEnabled = ref.read(voiceCloningEnabledProvider);
    final production = ref.read(currentProductionProvider);
    if (voiceCloningEnabled &&
        production != null &&
        _voiceClone.canClone(line.character)) {
      final clonedPath = await _voiceClone.generateLine(
        productionId: production.id,
        character: line.character,
        lineId: line.id,
        text: line.text,
      );
      if (clonedPath != null) {
        try {
          await _player.setFilePath(clonedPath);
          await _player.setSpeed(speed);
          await _player.play();
          return;
        } catch (_) {
          // Fall through to Kokoro TTS
        }
      }
    }

    // 4. Kokoro TTS fallback (never uses system TTS)
    await _tts.setRate(speed * 0.5);
    await _tts.speak(line.text, character: line.character);
    // Completion handled by TTS completion handler
  }

  /// Called when another character's line finishes playing.
  void _onOtherLineFinished() {
    if (!mounted) return;
    final rehearsalState = ref.read(rehearsalStateProvider);
    if (rehearsalState == RehearsalState.paused) return;

    final script = ref.read(currentScriptProvider);
    final scene = ref.read(selectedSceneProvider);
    final myCharacter = ref.read(rehearsalCharacterProvider);
    if (script == null || scene == null) return;

    final dialogueLines = _getRehearsalLines(script, scene, myCharacter);
    final currentIdx = ref.read(currentLineIndexProvider);

    if (currentIdx + 1 >= dialogueLines.length) {
      ref.read(currentLineIndexProvider.notifier).state = currentIdx + 1;
      ref.read(rehearsalStateProvider.notifier).state =
          RehearsalState.sceneComplete;
      _saveSession(dialogueLines);
      _scrollToCurrentLine();
      return;
    }

    // Advance and process next
    ref.read(currentLineIndexProvider.notifier).state = currentIdx + 1;
    _scrollToCurrentLine();

    // Small delay between lines for natural pacing
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) _processCurrentLine();
    });
  }

  /// Start STT listening for the actor's line.
  Future<void> _startListeningForMyLine(ScriptLine line) async {
    ref.read(rehearsalStateProvider.notifier).state =
        RehearsalState.listeningForMe;
    setState(() {
      _recognizedText = '';
      _showMatchFeedback = false;
    });

    // Haptic feedback: it's your turn
    HapticFeedback.mediumImpact();

    final available = await _stt.isAvailable;
    if (!available) {
      // STT not available — just wait for manual advance
      ref.read(rehearsalStateProvider.notifier).state = RehearsalState.ready;
      return;
    }

    final threshold = ref.read(matchThresholdProvider) / 100.0;

    _currentAttemptCount++;

    await _stt.listen(
      continuous: true,
      onResult: (recognized) {
        if (!mounted) return;
        final score = SttService.matchScore(line.text, recognized);
        setState(() {
          _recognizedText = recognized;
          _matchScore = score;
          _showMatchFeedback = recognized.isNotEmpty;
        });

        if (score > _currentBestScore) _currentBestScore = score;

        // Auto-advance if match exceeds threshold
        if (score >= threshold) {
          _stt.stop();
          HapticFeedback.lightImpact();

          // Record the attempt
          _recordAttempt(line, skipped: false);

          // Brief delay so user sees the "Match!" feedback
          Future.delayed(const Duration(milliseconds: 600), () {
            if (mounted) {
              final script = ref.read(currentScriptProvider);
              final scene = ref.read(selectedSceneProvider);
              final myCharacter = ref.read(rehearsalCharacterProvider);
              if (script == null || scene == null) return;
              final dialogueLines =
                  _getRehearsalLines(script, scene, myCharacter);
              _advanceLine(dialogueLines.length);
            }
          });
        }
      },
    );
  }

  void _advanceLine(int totalLines) {
    _tts.stop();
    _stt.stop();
    _player.stop();

    final current = ref.read(currentLineIndexProvider);
    if (current + 1 >= totalLines) {
      ref.read(currentLineIndexProvider.notifier).state = current + 1;
      ref.read(rehearsalStateProvider.notifier).state =
          RehearsalState.sceneComplete;
      _scrollToCurrentLine();
      return;
    }

    ref.read(currentLineIndexProvider.notifier).state = current + 1;
    ref.read(rehearsalStateProvider.notifier).state = RehearsalState.ready;
    _scrollToCurrentLine();

    setState(() {
      _showMatchFeedback = false;
      _recognizedText = '';
    });

    // Auto-play next line after short delay
    if (_autoPlay) {
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted) _processCurrentLine();
      });
    }
  }

  void _jumpBack(int jumpCount, int totalLines) {
    _tts.stop();
    _stt.stop();
    _player.stop();

    final current = ref.read(currentLineIndexProvider);
    final newIdx = (current - jumpCount).clamp(0, totalLines - 1);
    ref.read(currentLineIndexProvider.notifier).state = newIdx;
    ref.read(rehearsalStateProvider.notifier).state = RehearsalState.ready;
    _scrollToCurrentLine();

    setState(() {
      _showMatchFeedback = false;
      _recognizedText = '';
    });

    // Haptic on jump back
    HapticFeedback.heavyImpact();

    // Auto-play from new position
    if (_autoPlay) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) _processCurrentLine();
      });
    }
  }

  void _restartScene() {
    _tts.stop();
    _stt.stop();
    _player.stop();

    ref.read(currentLineIndexProvider.notifier).state = 0;
    ref.read(rehearsalStateProvider.notifier).state = RehearsalState.ready;

    // Reset session tracking
    _sessionStartedAt = DateTime.now();
    _lineAttempts.clear();
    _currentAttemptCount = 0;
    _currentBestScore = 0.0;

    setState(() {
      _showMatchFeedback = false;
      _recognizedText = '';
    });

    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );

    if (_autoPlay) {
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted) _processCurrentLine();
      });
    }
  }

  void _togglePause(int totalLines) {
    final current = ref.read(rehearsalStateProvider);
    if (current == RehearsalState.paused) {
      ref.read(rehearsalStateProvider.notifier).state = RehearsalState.ready;
      if (_autoPlay) _processCurrentLine();
    } else {
      _tts.stop();
      _stt.stop();
      _player.pause();
      ref.read(rehearsalStateProvider.notifier).state = RehearsalState.paused;
    }
  }

  /// Record an attempt for the given line.
  void _recordAttempt(ScriptLine line, {required bool skipped}) {
    _lineAttempts.add(LineAttempt(
      lineId: line.id,
      lineText: line.text.length > 80
          ? '${line.text.substring(0, 77)}...'
          : line.text,
      attemptCount: _currentAttemptCount,
      bestScore: _currentBestScore,
      skipped: skipped,
    ));
  }

  /// Record attempt for the current line (used when manually advancing).
  void _recordCurrentLineAttempt({required bool skipped}) {
    final script = ref.read(currentScriptProvider);
    final scene = ref.read(selectedSceneProvider);
    final myCharacter = ref.read(rehearsalCharacterProvider);
    final currentIdx = ref.read(currentLineIndexProvider);
    if (script == null || scene == null) return;

    final dialogueLines = _getRehearsalLines(script, scene, myCharacter);
    if (currentIdx < dialogueLines.length) {
      final line = dialogueLines[currentIdx];
      if (line.character == myCharacter) {
        _recordAttempt(line, skipped: skipped);
      }
    }
  }

  /// Save the completed rehearsal session to history.
  void _saveSession(List<ScriptLine> dialogueLines) {
    final scene = ref.read(selectedSceneProvider);
    final myCharacter = ref.read(rehearsalCharacterProvider);
    final production = ref.read(currentProductionProvider);
    final cueToCue = ref.read(cueToCueModeProvider);
    if (scene == null || myCharacter == null) return;

    final myLines = dialogueLines
        .where((l) => l.character == myCharacter)
        .length;
    final completedLines = _lineAttempts.where((a) => !a.skipped).length;
    final avgScore = _lineAttempts.isEmpty
        ? 0.0
        : _lineAttempts.fold<double>(0, (s, a) => s + a.bestScore) /
            _lineAttempts.length;

    final session = RehearsalSession(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      productionId: production?.id ?? '',
      sceneId: scene.sceneName,
      sceneName: scene.displayLabel,
      character: myCharacter,
      startedAt: _sessionStartedAt,
      endedAt: DateTime.now(),
      totalLines: myLines,
      completedLines: completedLines,
      averageMatchScore: avgScore,
      lineAttempts: List.from(_lineAttempts),
      cueToCueMode: cueToCue,
    );

    ref.read(rehearsalHistoryProvider.notifier).add(session);
  }

  void _scrollToCurrentLine() {
    // Wait for the next frame so the key is attached to the rebuilt widget
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _currentLineKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.3, // position current line ~30% from top
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }
}
