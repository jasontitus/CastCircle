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
import '../../data/services/debug_log_service.dart';
import '../../data/services/stt_adaptation_service.dart';
import '../../data/services/stt_vocabulary_service.dart';
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
  final SttVocabularyService _sttVocab = SttVocabularyService.instance;
  String? _activeAdapter; // per-actor or per-production LoRA adapter path
  final GlobalKey _currentLineKey = GlobalKey();

  final bool _autoPlay = true; // auto-advance through other characters' lines
  String _recognizedText = '';
  double _matchScore = 0.0;
  bool _showMatchFeedback = false;

  // Silence timeout — auto-advance when no new STT results for a while
  Timer? _silenceTimer;
  static const _silenceTimeout = Duration(seconds: 5);

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

    // Listen for playback completion to auto-advance (real recordings only)
    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed &&
          _autoPlay &&
          mounted) {
        final rs = ref.read(rehearsalStateProvider);
        if (rs == RehearsalState.playingOther) {
          _dlog.log(LogCategory.rehearsal, 'Recording player completed');
          _onOtherLineFinished();
        }
      }
    });
  }

  final _dlog = DebugLogService.instance;

  Future<void> _initAudio() async {
    _dlog.log(LogCategory.rehearsal, 'Rehearsal starting');
    _dlog.startMemoryMonitoring();
    await _tts.init();

    final production = ref.read(currentProductionProvider);
    final myCharacter = ref.read(rehearsalCharacterProvider);
    final script = ref.read(currentScriptProvider);

    // Use per-character locale if set, otherwise production default
    var locale = production?.locale ?? 'en-US';
    if (production != null && myCharacter != null) {
      final charLocale = await VoiceConfigService.instance
          .getLocale(production.id, myCharacter);
      if (charLocale != null) locale = charLocale;
    }

    // Assign voices (fast — batched SharedPreferences reads)
    await _assignVoices(production, script, locale);

    _tts.setCompletionHandler(() {
      if (_autoPlay && mounted) {
        _onOtherLineFinished();
      }
    });

    // In Cue Practice mode, jump to a few lines before the actor's first line.
    // In Scene Readthrough mode, start from the beginning of the scene.
    final mode = ref.read(rehearsalModeProvider);
    if (mode == RehearsalMode.cuePractice &&
        script != null &&
        myCharacter != null) {
      final scene = ref.read(selectedSceneProvider);
      if (scene != null) {
        final dialogueLines = _getRehearsalLines(script, scene, myCharacter);
        final firstMyIdx = dialogueLines
            .indexWhere((l) => l.character == myCharacter);
        if (firstMyIdx > 0) {
          // Start 3 lines before actor's first line (minimum 0)
          final startIdx = (firstMyIdx - 3).clamp(0, dialogueLines.length - 1);
          ref.read(currentLineIndexProvider.notifier).state = startIdx;
          _scrollToCurrentLine();
        }
      }
    }

    // Auto-start playback immediately — don't wait for STT
    if (_autoPlay) {
      _processCurrentLine();
    }

    // Defer STT init to background — it's only needed when it's the user's
    // turn to speak, not for TTS playback of other characters' lines.
    _initSttDeferred(production, myCharacter, script, locale);
  }

  Future<void> _initSttDeferred(
    dynamic production,
    String? myCharacter,
    ParsedScript? script,
    String locale,
  ) async {
    await _stt.init(locale: locale);

    // Build STT vocabulary from script for correction
    if (script != null && production != null) {
      _sttVocab.buildFromScript(production.id, script.lines);
    }

    // Check for per-actor or per-production STT adapter
    if (production != null && myCharacter != null) {
      _activeAdapter = _sttAdapt.getBestAdapter(production.id, myCharacter);
      if (_activeAdapter != null) {
        debugPrint('Rehearsal: Using adapted STT model: $_activeAdapter');
      }
    }
  }

  @override
  void dispose() {
    _dlog.stopMemoryMonitoring();
    _dlog.log(LogCategory.rehearsal, 'Rehearsal ended');
    _silenceTimer?.cancel();
    _scrollController.dispose();
    _player.dispose();
    _tts.stop(reason: 'dispose');
    _stt.stop();
    super.dispose();
  }

  /// Assign voices to all characters. Batches SharedPreferences reads
  /// to avoid sequential await per character.
  Future<void> _assignVoices(
    dynamic production,
    ParsedScript? script,
    String locale,
  ) async {
    if (script == null) return;
    final voiceConfig = VoiceConfigService.instance;

    if (production != null) {
      // Batch-load overrides and genders in one go
      final genderOverrides = await voiceConfig.getGenders(production.id);
      final overrides = await voiceConfig.getOverrides(production.id);
      final preset = await voiceConfig.getPreset(production.id, locale: locale);

      for (var i = 0; i < script.characters.length; i++) {
        final char = script.characters[i];
        final gender = genderOverrides[char.name] ?? char.gender;
        final isFemale = gender != CharacterGender.male;

        // Resolve voice without hitting SharedPreferences again
        String voiceId;
        double speed;
        final override = overrides[char.name];
        if (override != null) {
          voiceId = override.voiceId;
          speed = override.speed;
        } else {
          final pool = isFemale ? preset.femaleVoices : preset.maleVoices;
          final voices = pool.isNotEmpty
              ? pool
              : [...preset.femaleVoices, ...preset.maleVoices];
          voiceId = voices.isEmpty ? 'af_heart' : voices[i % voices.length];
          speed = preset.defaultSpeed;
        }

        _tts.assignVoice(char.name, i, voiceId: voiceId, speed: speed);
      }
    } else {
      for (var i = 0; i < script.characters.length; i++) {
        _tts.assignVoice(script.characters[i].name, i);
      }
    }
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

    final mode = ref.watch(rehearsalModeProvider);
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
            _buildTopBar(context, scene, progress, rehearsalState, mode),
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
      RehearsalState rehearsalState, RehearsalMode mode) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70),
            onPressed: () {
              _tts.stop(reason: 'closeButton');
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
          // Mode badge
          if (mode == RehearsalMode.cuePractice)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('CUE',
                  style: TextStyle(color: Colors.blue, fontSize: 9,
                      fontWeight: FontWeight.bold)),
            ),
          // Blind rehearsal badge
          if (ref.watch(hideMyLinesProvider))
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: Colors.purple.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('BLIND',
                  style: TextStyle(color: Colors.purple, fontSize: 9,
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
      // Large cacheExtent so items are built before they're visible.
      // This ensures _currentLineKey is always available for scrolling.
      cacheExtent: 10000,
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
                // Hide the actor's upcoming lines in blind mode
                if (ref.watch(hideMyLinesProvider) && isMe && !isPast)
                  Text(
                    'Say your line...',
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: isCurrent ? 18 : 15,
                      height: 1.4,
                      fontStyle: FontStyle.italic,
                    ),
                  )
                else
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
                _tts.stop(reason: 'chooseAnotherScene');
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
            label: ref.read(rehearsalModeProvider) == RehearsalMode.cuePractice
                ? 'Back 2'
                : 'Back $jumpBackLines',
            onTap: currentIdx > 0
                ? () => _jumpBack(
                    ref.read(rehearsalModeProvider) == RehearsalMode.cuePractice
                        ? 2
                        : jumpBackLines,
                    totalLines)
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
        _tts.stop(reason: 'skipOtherLine');
        try { _player.stop(); } catch (_) {}
        _advanceLine(totalLines);
      case RehearsalState.listeningForMe:
        // Accept whatever was said and advance (manual skip)
        // Discard pending transcription to avoid delayed callbacks
        _stt.stop(discard: true);
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

    final mode = ref.read(rehearsalModeProvider);
    if (mode != RehearsalMode.cuePractice || myCharacter == null) return allDialogue;

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

    if (script == null || scene == null) {
      _dlog.log(LogCategory.rehearsal,
          'processCurrentLine: script=${script != null} scene=${scene != null}');
      return;
    }

    final sceneLines = script.linesInScene(scene);
    _dlog.log(LogCategory.rehearsal,
        'processCurrentLine: scene="${scene.sceneName}" '
        'start=${scene.startLineIndex} end=${scene.endLineIndex} '
        'totalLines=${script.lines.length} sceneLines=${sceneLines.length}');

    final dialogueLines = _getRehearsalLines(script, scene, myCharacter);

    _dlog.log(LogCategory.rehearsal,
        'processCurrentLine: dialogueLines=${dialogueLines.length} '
        'currentIdx=$currentIdx char=$myCharacter');

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

    _dlog.log(LogCategory.rehearsal,
        'Playing: ${line.character} — "${line.text.length > 40 ? '${line.text.substring(0, 37)}...' : line.text}"');

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
    // Only advance if we were actually playing another character's line.
    // This prevents double-advance when _tts.stop() is called explicitly
    // (e.g., during skip/advance) from triggering this handler.
    if (rehearsalState != RehearsalState.playingOther) {
      _dlog.log(LogCategory.rehearsal,
          'onOtherLineFinished ignored (state=${rehearsalState.name})');
      return;
    }
    _dlog.log(LogCategory.rehearsal, 'Other line finished, advancing');

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

    // Check if next line is the actor's — if so, start listening immediately
    // so there's no awkward pause. Only add pacing delay between other lines.
    final nextLine = dialogueLines[currentIdx + 1];
    final isNextMine = nextLine.character == myCharacter;

    if (isNextMine) {
      // Actor's turn — start listening right away
      if (mounted) _processCurrentLine();
    } else {
      // Another character's line — brief pacing delay for natural feel
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) _processCurrentLine();
      });
    }
  }

  /// Start STT listening for the actor's line.
  Future<void> _startListeningForMyLine(ScriptLine line) async {
    ref.read(rehearsalStateProvider.notifier).state =
        RehearsalState.listeningForMe;
    setState(() {
      _recognizedText = '';
      _showMatchFeedback = false;
    });

    // Release TTS audio session so STT can acquire the microphone.
    // Without this, the audioPlayer holds the session in playback mode
    // and STT silently fails to start recording.
    await _tts.releaseAudioSession();

    // Haptic feedback: it's your turn
    HapticFeedback.mediumImpact();

    // If STT isn't ready yet (deferred init still running), wait for it
    if (!_stt.isAvailable) {
      _dlog.log(LogCategory.rehearsal, 'Waiting for STT init...');
      // Poll briefly — STT init typically takes 1-3 seconds
      for (var i = 0; i < 50 && !_stt.isAvailable && mounted; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    final available = _stt.isAvailable;
    if (!available) {
      // STT truly not available — just wait for manual advance
      _dlog.log(LogCategory.rehearsal, 'STT not available, manual advance');
      ref.read(rehearsalStateProvider.notifier).state = RehearsalState.ready;
      return;
    }

    final threshold = ref.read(matchThresholdProvider) / 100.0;

    _currentAttemptCount++;

    // Build vocabulary hints: the current line as a phrase, its individual
    // words, plus script-wide vocabulary (character names, archaic terms).
    final production = ref.read(currentProductionProvider);
    final myCharacter = ref.read(rehearsalCharacterProvider);
    final cleanLine = line.text.replaceAll(RegExp("[^\\w\\s']"), '');
    final wordHints = cleanLine.split(RegExp(r'\s+'))
        .where((w) => w.length > 1)
        .toSet()
        .toList();
    // Full phrase + individual words + script vocabulary
    final vocabHints = <String>[cleanLine, ...wordHints];
    // Add script-wide important words (character names, recurring terms)
    if (production != null) {
      vocabHints.addAll(_sttVocab.getScriptHints(production.id));
    }

    // Start silence timer — if no new results for a while, auto-advance
    _resetSilenceTimer(line);

    await _stt.listen(
      continuous: true,
      onResult: (recognized) {
        if (!mounted) return;
        // Ignore stale results if we've moved past this line
        if (ref.read(rehearsalStateProvider) != RehearsalState.listeningForMe) return;

        // Reset silence timer on each new result
        _resetSilenceTimer(line);

        // Apply vocabulary correction before scoring
        final corrected = production != null
            ? _sttVocab.correct(
                recognized: recognized,
                expectedText: line.text,
                productionId: production.id,
                actorId: myCharacter,
              )
            : recognized;

        final score = SttService.matchScore(line.text, corrected);
        setState(() {
          _recognizedText = corrected;
          _matchScore = score;
          _showMatchFeedback = corrected.isNotEmpty;
        });

        if (score > _currentBestScore) _currentBestScore = score;

        // Auto-advance if match exceeds threshold
        if (score >= threshold) {
          _silenceTimer?.cancel();
          _stt.stop();
          HapticFeedback.lightImpact();

          // Learn from this successful attempt
          if (production != null && myCharacter != null) {
            _sttVocab.learnFromAttempt(
              productionId: production.id,
              actorId: myCharacter,
              recognized: recognized,
              expected: line.text,
            );
          }

          // Record the attempt
          _recordAttempt(line, skipped: false);

          // Brief delay so user sees the "Match!" feedback
          Future.delayed(const Duration(milliseconds: 600), () {
            if (mounted) {
              final s = ref.read(currentScriptProvider);
              final scene = ref.read(selectedSceneProvider);
              final mc = ref.read(rehearsalCharacterProvider);
              if (s == null || scene == null) return;
              final dialogueLines = _getRehearsalLines(s, scene, mc);
              _advanceLine(dialogueLines.length);
            }
          });
        }
      },
      onDone: () {
        if (!mounted) return;
        // Listening ended but no match — stay on this line, let user retry or skip
        if (ref.read(rehearsalStateProvider) == RehearsalState.listeningForMe) {
          ref.read(rehearsalStateProvider.notifier).state =
              RehearsalState.ready;
        }
      },
      vocabularyHints: vocabHints,
    );
  }

  /// Reset the silence timer. When no new STT results arrive for
  /// [_silenceTimeout], auto-advance with whatever score we have.
  void _resetSilenceTimer(ScriptLine line) {
    _silenceTimer?.cancel();
    _silenceTimer = Timer(_silenceTimeout, () {
      if (!mounted) return;
      final state = ref.read(rehearsalStateProvider);
      if (state != RehearsalState.listeningForMe) return;

      debugPrint('Rehearsal: Silence timeout — auto-advancing');
      _stt.stop();

      // Record the attempt with whatever score was achieved
      final threshold = ref.read(matchThresholdProvider) / 100.0;
      _recordAttempt(line, skipped: _matchScore < threshold);

      // Advance to next line
      final script = ref.read(currentScriptProvider);
      final scene = ref.read(selectedSceneProvider);
      final mc = ref.read(rehearsalCharacterProvider);
      if (script == null || scene == null) return;
      final dialogueLines = _getRehearsalLines(script, scene, mc);
      _advanceLine(dialogueLines.length);
    });
  }

  void _advanceLine(int totalLines) {
    _silenceTimer?.cancel();
    _tts.stop(reason: 'advanceLine');
    _stt.stop(discard: true);
    try { _player.stop(); } catch (_) {}

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
    _silenceTimer?.cancel();
    _tts.stop(reason: 'jumpBack');
    _stt.stop(discard: true);
    try { _player.stop(); } catch (_) {}

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
    _silenceTimer?.cancel();
    _tts.stop(reason: 'restartScene');
    _stt.stop(discard: true);
    try { _player.stop(); } catch (_) {}

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
    _silenceTimer?.cancel();
    final current = ref.read(rehearsalStateProvider);
    if (current == RehearsalState.paused) {
      ref.read(rehearsalStateProvider.notifier).state = RehearsalState.ready;
      if (_autoPlay) _processCurrentLine();
    } else {
      _tts.stop(reason: 'pause');
      _stt.stop(discard: true);
      try { _player.pause(); } catch (_) {}
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
    final mode = ref.read(rehearsalModeProvider);
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
      rehearsalMode: mode.name,
    );

    ref.read(rehearsalHistoryProvider.notifier).add(session);
  }

  void _scrollToCurrentLine() {
    // Wait for the current frame to complete layout so the widget tree
    // has been rebuilt with the new currentLineIndexProvider value.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;

      // With cacheExtent: 10000 the target widget should be built.
      // Use ensureVisible on the GlobalKey for pixel-perfect scroll.
      final ctx = _currentLineKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.3, // position current line ~30% from top
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      } else {
        // Fallback: estimate scroll position if widget not yet built
        final currentIdx = ref.read(currentLineIndexProvider);
        const estimatedItemHeight = 140.0;
        final targetOffset = currentIdx * estimatedItemHeight;
        final maxScroll = _scrollController.position.maxScrollExtent;
        _scrollController.animateTo(
          targetOffset.clamp(0.0, maxScroll),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }
}
