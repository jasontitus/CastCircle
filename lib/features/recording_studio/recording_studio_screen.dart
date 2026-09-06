import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/script_models.dart';
import '../../data/services/debug_log_service.dart';
import '../../data/services/stt_adaptation_service.dart';
import '../../data/services/sync_queue.dart';
import '../../data/services/audio_level_service.dart';
import '../../data/services/playback_session.dart';
import '../../providers/production_providers.dart';
import '../../features/settings/settings_screen.dart';
import '../../main.dart' show rootScaffoldMessengerKey;
import '../../core/toast.dart';

/// Recording state for the studio.
enum RecordingStatus {
  idle,
  recording,
  recorded, // has a recording, ready to review
  playing, // playing back the recording
}

class RecordingStudioScreen extends ConsumerStatefulWidget {
  const RecordingStudioScreen({super.key});

  @override
  ConsumerState<RecordingStudioScreen> createState() =>
      _RecordingStudioScreenState();
}

class _RecordingStudioScreenState extends ConsumerState<RecordingStudioScreen> {
  AudioRecorder? _recorder;
  AudioPlayer? _player;
  StreamSubscription? _playerSub;
  RecordingStatus _status = RecordingStatus.idle;
  int _currentLineIdx = 0;
  String? _currentRecordingPath;
  // ValueNotifier, not a field + setState: the 10 Hz tick used to rebuild
  // the ENTIRE studio screen for the whole recording (re-running the
  // recorded-count scan and context-line walk while the device encoded
  // audio). Only the timer label listens now.
  final ValueNotifier<Duration> _recordingDuration = ValueNotifier(
    Duration.zero,
  );
  Timer? _durationTimer;
  String? _initError;

  late List<ScriptLine> _myLines;
  ParsedScript? _myLinesScript; // identity key for the _myLines memo
  String? _character;

  /// Everything a finished take needs, cached from build(). Riverpod throws if
  /// `ref` is touched once the widget is gone, and a take that is still saving
  /// when the user leaves the studio must survive exactly that moment.
  RecordingsNotifier? _recordingsNotifier;
  Map<String, Recording> _recordingsSnapshot = const {};
  String? _productionId;

  /// Recorder transitions own the recorder across async platform calls.
  /// dispose() leaves it alone until that transition either transfers a live
  /// take to the screen or cleans up its candidate file.
  bool _startInFlight = false;
  bool _stopInFlight = false;
  ScriptLine? _recordingLine;
  String? _recordingCharacter;

  @override
  void initState() {
    super.initState();
    _initAudio();
  }

  void _initAudio() {
    try {
      _recorder = AudioRecorder();
      _player = AudioPlayer();
      _playerSub = _player!.playerStateStream.listen((state) {
        if (state.processingState == ProcessingState.completed) {
          if (mounted) setState(() => _status = RecordingStatus.recorded);
        }
      });
    } catch (e) {
      _initError = 'Audio initialization failed: $e';
    }
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    _recordingDuration.dispose();
    final recorder = _recorder;
    if (_startInFlight || _stopInFlight) {
      // The in-flight transition owns the recorder and will release it if the
      // screen has gone away.
    } else if (recorder != null && _status == RecordingStatus.recording) {
      // Closing the studio mid-take used to hand the recorder straight to
      // dispose(): the capture was abandoned, the take never registered, and
      // nothing said so. Finish and register it instead — off the widget,
      // using the values cached in build().
      unawaited(
        _finishTakeAfterDispose(
          recorder: recorder,
          line: _recordingLine ?? _myLines[_currentLineIdx],
          character: _recordingCharacter ?? _character,
          notifier: _recordingsNotifier,
          productionId: _productionId,
          durationMs: _recordingDuration.value.inMilliseconds,
        ),
      );
    } else {
      recorder?.dispose();
    }
    _playerSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  /// Stop + save a take whose screen is already gone. Runs detached from the
  /// widget, so failures go to the log and the app-wide messenger.
  Future<void> _finishTakeAfterDispose({
    required AudioRecorder recorder,
    required ScriptLine line,
    required String? character,
    required RecordingsNotifier? notifier,
    required String? productionId,
    required int durationMs,
  }) async {
    String? stoppedPath;
    try {
      stoppedPath = await recorder.stop();
      final path = stoppedPath;
      if (path == null || character == null || notifier == null) {
        DebugLogService.instance.logError(
          LogCategory.error,
          'Studio: take lost on close — recorder returned '
          '${path == null ? 'no file' : 'no character/notifier'} '
          'for line=${line.id}',
        );
        if (path != null) {
          try {
            final failedTake = File(path);
            if (await failedTake.exists()) await failedTake.delete();
          } catch (cleanupError) {
            DebugLogService.instance.logError(
              LogCategory.error,
              'Studio: could not remove unsaved take at $path',
              cleanupError,
            );
          }
        }
        rootScaffoldMessengerKey.currentState?.showAutoToast(
          const SnackBar(
            content: Text(
              'The recording in progress was lost when the studio '
              'closed — please record that line again.',
            ),
            duration: Duration(seconds: 6),
          ),
        );
        return;
      }
      await _registerTake(
        path: path,
        line: line,
        character: character,
        notifier: notifier,
        productionId: productionId,
        durationMs: durationMs,
      );
      rootScaffoldMessengerKey.currentState?.showAutoToast(
        SnackBar(
          content: Text(
            'Saved the take for ${character.toUpperCase()} that was '
            'still recording when you left the studio.',
          ),
        ),
      );
    } catch (e) {
      DebugLogService.instance.logError(
        LogCategory.error,
        'Studio: saving the in-progress take on close failed',
        e,
      );
      final path = stoppedPath;
      if (path != null) {
        try {
          final failedTake = File(path);
          if (await failedTake.exists()) await failedTake.delete();
        } catch (cleanupError) {
          DebugLogService.instance.logError(
            LogCategory.error,
            'Studio: could not remove unpublished take at $path',
            cleanupError,
          );
        }
      }
      rootScaffoldMessengerKey.currentState?.showAutoToast(
        SnackBar(
          content: Text("Couldn't save the recording that was in progress: $e"),
          duration: const Duration(seconds: 6),
        ),
      );
    } finally {
      await recorder.dispose();
    }
  }

  /// Register a finished take locally and queue it for the cast.
  ///
  /// Deliberately takes the notifier/production instead of reading `ref`: it
  /// also runs from [dispose], after this widget's ref is gone.
  Future<void> _registerTake({
    required String path,
    required ScriptLine line,
    required String character,
    required RecordingsNotifier notifier,
    required String? productionId,
    required int durationMs,
  }) async {
    final previousPath = _recordingsSnapshot[line.id]?.localPath;
    AudioLevelService.instance.invalidate(path);
    final recording = Recording(
      id: const Uuid().v4(),
      scriptLineId: line.id,
      character: character,
      localPath: path,
      durationMs: durationMs,
      recordedAt: DateTime.now(),
    );
    if (productionId != null) {
      // Durably install the immutable take token before local persistence can
      // await. If checkpointing fails, publication stops and the prior take
      // remains committed.
      await SyncQueue.instance.enqueue(
        productionId: productionId,
        recordingId: recording.id,
        characterName: character,
        lineId: line.id,
        localPath: path,
        durationMs: durationMs,
        recordedAt: recording.recordedAt,
      );
    }

    await notifier.add(recording);

    if (productionId != null) {
      // STT adaptation: recording + transcript as training data
      SttAdaptationService.instance.addSample(
        productionId: productionId,
        actorId: character,
        audioPath: path,
        transcript: line.text,
        durationMs: durationMs,
      );
    }

    // The new row and queue entry now point at the unique new file. Only now
    // is it safe to remove the committed take that this one replaced.
    if (previousPath != null && previousPath != path) {
      AudioLevelService.instance.invalidate(previousPath);
      try {
        var previousFile = File(previousPath);
        if (!await previousFile.exists()) {
          // Absolute app-container paths change across reinstalls. Resolve the
          // committed take by basename in the current recordings directory.
          previousFile = File(
            p.join(p.dirname(path), p.basename(previousPath)),
          );
        }
        if (await previousFile.exists()) {
          AudioLevelService.instance.invalidate(previousFile.path);
          await previousFile.delete();
        }
      } catch (e) {
        DebugLogService.instance.logError(
          LogCategory.error,
          'Studio: could not remove replaced take at $previousPath',
          e,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final script = ref.watch(currentScriptProvider);
    final character = ref.watch(recordingCharacterProvider);
    final recordings = ref.watch(recordingsProvider);

    // Kept fresh here so a take can still be saved after this widget is gone
    // (see [_recordingsNotifier]).
    _recordingsNotifier = ref.read(recordingsProvider.notifier);
    _recordingsSnapshot = recordings;
    _productionId = ref.read(currentProductionProvider)?.id;

    if (script == null || character == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Recording Studio')),
        body: const Center(child: Text('No script or character selected')),
      );
    }

    if (_initError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Recording Studio')),
        body: Center(child: Text(_initError!)),
      );
    }

    // Memoized: linesForCharacter walks the whole script per call. A refreshed
    // list may be shorter, so its index and line-specific playback state must
    // be updated together before either is read.
    if (_character != character || _myLinesScript != script) {
      _myLinesScript = script;
      _myLines = script.linesForCharacter(character);
      final activeLine = _recordingLine;
      final captureActive =
          _status == RecordingStatus.recording || _startInFlight;
      if (activeLine != null &&
          captureActive &&
          !_myLines.any((line) => line.id == activeLine.id)) {
        // Keep the stop control tied to the line actually being captured if a
        // live script/character edit removes it. The completed-take rebuild
        // refreshes the list again.
        _myLines = [activeLine, ..._myLines];
      }
      if (_myLines.isEmpty) {
        _currentLineIdx = 0;
      } else if (activeLine != null && captureActive) {
        _currentLineIdx = _myLines.indexWhere(
          (line) => line.id == activeLine.id,
        );
      } else {
        _currentLineIdx = _currentLineIdx.clamp(0, _myLines.length - 1);
      }
      if (_status != RecordingStatus.recording &&
          !_startInFlight &&
          !_stopInFlight) {
        _player?.stop();
        _currentRecordingPath = null;
        final line = _myLines.isEmpty ? null : _myLines[_currentLineIdx];
        _status = line != null && recordings.containsKey(line.id)
            ? RecordingStatus.recorded
            : RecordingStatus.idle;
      }
    }
    _character = character;

    if (_myLines.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Recording Studio')),
        body: Center(child: Text('$character has no dialogue lines')),
      );
    }

    final recordedCount = _myLines
        .where((l) => recordings.containsKey(l.id))
        .length;
    final progress = _myLines.isEmpty ? 0.0 : recordedCount / _myLines.length;
    final currentLine = _myLines[_currentLineIdx];
    final hasRecording =
        recordings.containsKey(currentLine.id) ||
        _status == RecordingStatus.recorded ||
        _status == RecordingStatus.playing;

    final charIdx = script.characters.indexWhere((c) => c.name == character);
    final charColor = charIdx >= 0
        ? AppTheme.colorForCharacter(charIdx)
        : Colors.blue;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            _buildTopBar(context, character, progress, recordedCount),
            // Progress bar
            LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.grey[900],
              color: charColor,
            ),
            const SizedBox(height: 8),
            // Context: previous lines
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    // Previous 2 lines for context
                    _buildContextLines(context, script, charColor),
                    const Spacer(),
                    // Current line (big)
                    _buildCurrentLine(context, currentLine, charColor),
                    const Spacer(),
                    // Recording controls
                    _buildRecordingControls(
                      context,
                      currentLine,
                      hasRecording,
                      charColor,
                    ),
                    const SizedBox(height: 16),
                    // Navigation
                    _buildNavigation(context, hasRecording, charColor),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(
    BuildContext context,
    String character,
    double progress,
    int recordedCount,
  ) {
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
                  'Recording: $character',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                Text(
                  '$recordedCount / ${_myLines.length} lines recorded',
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                ),
              ],
            ),
          ),
          Text(
            '${_currentLineIdx + 1} / ${_myLines.length}',
            style: TextStyle(color: Colors.grey[500], fontSize: 12),
          ),
        ],
      ),
    );
  }

  // line.id → full-script index, built once per script — _buildContextLines
  // runs on every build, which ticks at 10 Hz while recording.
  Map<String, int>? _fullIdxById;
  ParsedScript? _fullIdxScript;

  Widget _buildContextLines(
    BuildContext context,
    ParsedScript script,
    Color charColor,
  ) {
    if (_fullIdxScript != script) {
      _fullIdxScript = script;
      _fullIdxById = {
        for (var i = 0; i < script.lines.length; i++) script.lines[i].id: i,
      };
    }
    // Show the 2 lines before the current one in the full script
    final currentLine = _myLines[_currentLineIdx];
    final fullIdx = _fullIdxById![currentLine.id] ?? -1;
    final contextLines = <ScriptLine>[];
    for (var i = fullIdx - 1; i >= 0 && contextLines.length < 2; i--) {
      final line = script.lines[i];
      if (line.lineType == LineType.dialogue) {
        contextLines.insert(0, line);
      }
    }

    if (contextLines.isEmpty) {
      return const SizedBox(height: 60);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: contextLines.map((line) {
        final isMe = _character != null && line.isForCharacter(_character!);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Opacity(
            opacity: 0.4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isMe ? 'YOU' : line.character,
                  style: TextStyle(
                    color: isMe ? charColor : Colors.grey,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  line.text,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildCurrentLine(
    BuildContext context,
    ScriptLine line,
    Color charColor,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: charColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: charColor.withValues(alpha: 0.3), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (line.stageDirection.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '(${line.stageDirection})',
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  color: Colors.grey[500],
                  fontSize: 14,
                ),
              ),
            ),
          Text(
            line.text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              height: 1.5,
            ),
          ),
          if (_status == RecordingStatus.recording) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(
                  Icons.fiber_manual_record,
                  color: Colors.red,
                  size: 12,
                ),
                const SizedBox(width: 6),
                ValueListenableBuilder<Duration>(
                  valueListenable: _recordingDuration,
                  builder: (context, d, _) => Text(
                    _formatDuration(d),
                    style: const TextStyle(color: Colors.red, fontSize: 14),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRecordingControls(
    BuildContext context,
    ScriptLine line,
    bool hasRecording,
    Color charColor,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Play existing recording
        if (hasRecording && _status != RecordingStatus.recording) ...[
          _circleButton(
            icon: _status == RecordingStatus.playing
                ? Icons.stop
                : Icons.play_arrow,
            color: Colors.white70,
            size: 48,
            onTap: _status == RecordingStatus.playing
                ? _stopPlayback
                : _playRecording,
          ),
          const SizedBox(width: 24),
        ],
        // Record button
        _circleButton(
          icon: _status == RecordingStatus.recording ? Icons.stop : Icons.mic,
          color: _status == RecordingStatus.recording ? Colors.red : charColor,
          size: 72,
          onTap: _status == RecordingStatus.recording
              ? _stopRecording
              : _startRecording,
          filled: true,
        ),
        if (hasRecording && _status != RecordingStatus.recording) ...[
          const SizedBox(width: 24),
          // Re-record
          _circleButton(
            icon: Icons.refresh,
            color: Colors.white70,
            size: 48,
            onTap: _startRecording,
          ),
        ],
      ],
    );
  }

  Widget _buildNavigation(
    BuildContext context,
    bool hasRecording,
    Color charColor,
  ) {
    final canNavigate =
        _status != RecordingStatus.recording &&
        !_startInFlight &&
        !_stopInFlight;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Previous
        TextButton.icon(
          onPressed: canNavigate && _currentLineIdx > 0 ? _previousLine : null,
          icon: const Icon(Icons.chevron_left),
          label: const Text('Previous'),
          style: TextButton.styleFrom(foregroundColor: Colors.white70),
        ),
        // Skip
        TextButton(
          onPressed: canNavigate && _currentLineIdx < _myLines.length - 1
              ? () => _goToLine(_currentLineIdx + 1)
              : null,
          style: TextButton.styleFrom(foregroundColor: Colors.grey[600]),
          child: const Text('Skip'),
        ),
        // Next
        TextButton.icon(
          onPressed: canNavigate && _currentLineIdx < _myLines.length - 1
              ? _nextLine
              : null,
          icon: const Icon(Icons.chevron_right),
          label: const Text('Next'),
          style: TextButton.styleFrom(foregroundColor: charColor),
        ),
      ],
    );
  }

  Widget _circleButton({
    required IconData icon,
    required Color color,
    required double size,
    required VoidCallback onTap,
    bool filled = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: filled ? color.withValues(alpha: 0.2) : Colors.grey[900],
          shape: BoxShape.circle,
          border: Border.all(color: color, width: filled ? 3 : 1),
        ),
        child: Icon(icon, color: color, size: size * 0.45),
      ),
    );
  }

  // ── Recording Actions ─────────────────────────────────

  Future<void> _startRecording() async {
    final recorder = _recorder;
    if (recorder == null ||
        _startInFlight ||
        _stopInFlight ||
        _status == RecordingStatus.recording) {
      return;
    }

    final line = _myLines[_currentLineIdx];
    final character = _character;
    if (character == null) return;

    _startInFlight = true;
    _recordingLine = line;
    _recordingCharacter = character;
    setState(() {});

    String? candidatePath;
    var captureTransferred = false;
    try {
      if (_status == RecordingStatus.playing) {
        await _player?.stop();
        if (!mounted) return;
        setState(() => _status = RecordingStatus.recorded);
      }

      final hasPermission = await recorder.hasPermission();
      if (!mounted) return;
      if (!hasPermission) {
        ScaffoldMessenger.of(context).showAutoToast(
          const SnackBar(content: Text('Microphone permission required')),
        );
        return;
      }

      final dir = await getApplicationDocumentsDirectory();
      if (!mounted) return;
      final recordingsDir = Directory(p.join(dir.path, 'recordings'));
      await recordingsDir.create(recursive: true);
      if (!mounted) return;

      // Every take gets its own file. A failed or interrupted re-record can no
      // longer truncate the last committed take or mutate a queued upload.
      final takeId = const Uuid().v4();
      candidatePath = p.join(
        recordingsDir.path,
        '${line.id}_$takeId${AppConstants.audioExtension}',
      );
      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: AppConstants.sampleRate,
          bitRate: 128000,
        ),
        path: candidatePath,
      );
      if (!mounted) return;

      _currentRecordingPath = candidatePath;
      _recordingDuration.value = Duration.zero;
      _durationTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (mounted) {
          _recordingDuration.value += const Duration(milliseconds: 100);
        }
      });

      // Transfer ownership to the normal recording/stop lifecycle before
      // rebuilding. dispose() can now finish and register this take.
      _startInFlight = false;
      captureTransferred = true;
      setState(() => _status = RecordingStatus.recording);
    } catch (e) {
      DebugLogService.instance.logError(
        LogCategory.error,
        'Studio: recorder.start failed',
        e,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showAutoToast(
          SnackBar(content: Text("Couldn't start recording: $e")),
        );
      }
    } finally {
      if (!captureTransferred) {
        String? stoppedPath;
        if (candidatePath != null) {
          try {
            stoppedPath = await recorder.stop();
          } catch (e) {
            DebugLogService.instance.logError(
              LogCategory.error,
              'Studio: cleanup after interrupted recorder start failed',
              e,
            );
          }
          final orphanPath = stoppedPath ?? candidatePath;
          try {
            final orphan = File(orphanPath);
            if (await orphan.exists()) await orphan.delete();
          } catch (e) {
            DebugLogService.instance.logError(
              LogCategory.error,
              'Studio: could not remove interrupted take at $orphanPath',
              e,
            );
          }
        }
        _startInFlight = false;
        _recordingLine = null;
        _recordingCharacter = null;
        if (mounted) {
          setState(() {});
        } else {
          await recorder.dispose();
        }
      }
    }
  }

  Future<void> _stopRecording() async {
    if (_stopInFlight || _status != RecordingStatus.recording) return;
    _durationTimer?.cancel();
    // Snapshot what the save needs before the first await: the user can leave
    // the studio while stop() is running, and everything below must still work
    // with this widget gone.
    final line = _recordingLine ?? _myLines[_currentLineIdx];
    final character = _recordingCharacter ?? _character;
    final notifier = _recordingsNotifier;
    final productionId = _productionId;
    final durationMs = _recordingDuration.value.inMilliseconds;

    _stopInFlight = true;
    try {
      String? path;
      try {
        path = await _recorder?.stop();
      } catch (e) {
        DebugLogService.instance.logError(
          LogCategory.error,
          'Studio: recorder.stop failed',
          e,
        );
      }

      if (path == null) {
        DebugLogService.instance.logError(
          LogCategory.error,
          'Studio: recorder.stop returned no file',
        );
        rootScaffoldMessengerKey.currentState?.showAutoToast(
          const SnackBar(
            content: Text('Recording failed — nothing was saved. Try again.'),
          ),
        );
        if (mounted) {
          setState(() {
            _currentRecordingPath = null;
            _status = _recordingsSnapshot.containsKey(line.id)
                ? RecordingStatus.recorded
                : RecordingStatus.idle;
          });
        }
        return;
      }

      // Registering the take is NOT conditional on the screen still being
      // mounted. Only widget state and context access require a mounted guard.
      if (character == null || notifier == null) {
        DebugLogService.instance.logError(
          LogCategory.error,
          'Studio: no character selected — take at $path not registered',
        );
        try {
          final failedTake = File(path);
          if (await failedTake.exists()) await failedTake.delete();
        } catch (cleanupError) {
          DebugLogService.instance.logError(
            LogCategory.error,
            'Studio: could not remove unregistered take at $path',
            cleanupError,
          );
        }
        rootScaffoldMessengerKey.currentState?.showAutoToast(
          const SnackBar(
            content: Text(
              "Couldn't save the recording — no character selected.",
            ),
          ),
        );
        if (mounted) {
          setState(() {
            _currentRecordingPath = null;
            _status = _recordingsSnapshot.containsKey(line.id)
                ? RecordingStatus.recorded
                : RecordingStatus.idle;
          });
        }
        return;
      }

      try {
        await _registerTake(
          path: path,
          line: line,
          character: character,
          notifier: notifier,
          productionId: productionId,
          durationMs: durationMs,
        );
      } catch (e) {
        DebugLogService.instance.logError(
          LogCategory.error,
          'Studio: saving the take failed for ${line.id}',
          e,
        );
        try {
          final failedTake = File(path);
          if (await failedTake.exists()) await failedTake.delete();
        } catch (cleanupError) {
          DebugLogService.instance.logError(
            LogCategory.error,
            'Studio: could not remove unregistered take at $path',
            cleanupError,
          );
        }
        rootScaffoldMessengerKey.currentState?.showAutoToast(
          SnackBar(
            content: Text("Couldn't save that take: $e"),
            duration: const Duration(seconds: 6),
          ),
        );
        if (mounted) {
          setState(() {
            _currentRecordingPath = null;
            _status = _recordingsSnapshot.containsKey(line.id)
                ? RecordingStatus.recorded
                : RecordingStatus.idle;
          });
        }
        return;
      }

      _myLinesScript = null;
      if (mounted) setState(() => _status = RecordingStatus.recorded);
    } finally {
      _stopInFlight = false;
      _recordingLine = null;
      _recordingCharacter = null;
      // dispose() defers the recorder to this operation if the screen closes
      // during stop, persistence, or replacement cleanup.
      if (!mounted) await _recorder?.dispose();
    }
  }

  Future<void> _playRecording() async {
    final line = _myLines[_currentLineIdx];
    final recordings = ref.read(recordingsProvider);
    final speed = ref.read(playbackSpeedProvider);
    final recording = recordings[line.id];
    final player = _player;

    final path = _currentRecordingPath ?? recording?.localPath;
    if (path == null || player == null) return;

    try {
      // The recorder leaves iOS in the .record category; without this the
      // player runs silently. Force a playback session first.
      await PlaybackSession.ensurePlayback();
      if (!mounted) return;
      await player.setFilePath(path);
      if (!mounted) return;
      await player.setSpeed(speed);
      if (!mounted) return;
      final volume = await AudioLevelService.instance.volumeFor(path);
      if (!mounted) return;
      await player.setVolume(volume);
      if (!mounted) return;
      setState(() => _status = RecordingStatus.playing);
      await player.play();
    } catch (e) {
      if (mounted) {
        setState(() => _status = RecordingStatus.recorded);
        ScaffoldMessenger.of(
          context,
        ).showAutoToast(SnackBar(content: Text('Playback error: $e')));
      }
    }
  }

  Future<void> _stopPlayback() async {
    await _player?.stop();
    if (mounted) setState(() => _status = RecordingStatus.recorded);
  }

  void _nextLine() {
    if (_currentLineIdx < _myLines.length - 1) {
      _goToLine(_currentLineIdx + 1);
    }
  }

  void _previousLine() {
    if (_currentLineIdx > 0) {
      _goToLine(_currentLineIdx - 1);
    }
  }

  void _goToLine(int index) {
    if (_status == RecordingStatus.recording ||
        _startInFlight ||
        _stopInFlight) {
      return;
    }
    _player?.stop();
    _durationTimer?.cancel();
    setState(() {
      _currentLineIdx = index;
      _currentRecordingPath = null;
      // Check if this line already has a recording
      final line = _myLines[index];
      final recordings = ref.read(recordingsProvider);
      _status = recordings.containsKey(line.id)
          ? RecordingStatus.recorded
          : RecordingStatus.idle;
    });
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final tenths = (d.inMilliseconds.remainder(1000) ~/ 100).toString();
    return '$minutes:$seconds.$tenths';
  }
}
