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
import '../../data/services/stt_adaptation_service.dart';
import '../../data/services/voice_clone_service.dart';
import '../../providers/production_providers.dart';
import '../../features/settings/settings_screen.dart';

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
  RecordingStatus _status = RecordingStatus.idle;
  int _currentLineIdx = 0;
  String? _currentRecordingPath;
  Duration _recordingDuration = Duration.zero;
  Timer? _durationTimer;
  String? _initError;

  late List<ScriptLine> _myLines;
  String? _character;

  @override
  void initState() {
    super.initState();
    _initAudio();
  }

  void _initAudio() {
    try {
      _recorder = AudioRecorder();
      _player = AudioPlayer();
      _player!.playerStateStream.listen((state) {
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
    _recorder?.dispose();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final script = ref.watch(currentScriptProvider);
    final character = ref.watch(recordingCharacterProvider);

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

    _character = character;
    _myLines = script.linesForCharacter(character);

    if (_myLines.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Recording Studio')),
        body: Center(
          child: Text('$character has no dialogue lines'),
        ),
      );
    }

    final recordings = ref.watch(recordingsProvider);
    final recordedCount =
        _myLines.where((l) => recordings.containsKey(l.id)).length;
    final progress = _myLines.isEmpty ? 0.0 : recordedCount / _myLines.length;
    final currentLine = _myLines[_currentLineIdx];
    final hasRecording = recordings.containsKey(currentLine.id) ||
        _status == RecordingStatus.recorded ||
        _status == RecordingStatus.playing;

    final charIdx =
        script.characters.indexWhere((c) => c.name == character);
    final charColor =
        charIdx >= 0 ? AppTheme.colorForCharacter(charIdx) : Colors.blue;

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
                        context, currentLine, hasRecording, charColor),
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

  Widget _buildTopBar(BuildContext context, String character, double progress,
      int recordedCount) {
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
          IconButton(
            icon: const Icon(Icons.record_voice_over, color: Colors.white70),
            tooltip: 'Voice Profile',
            onPressed: () => context.push('/voice-profile'),
          ),
          Text(
            '${_currentLineIdx + 1} / ${_myLines.length}',
            style: TextStyle(color: Colors.grey[500], fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildContextLines(
      BuildContext context, ParsedScript script, Color charColor) {
    // Show the 2 lines before the current one in the full script
    final currentLine = _myLines[_currentLineIdx];
    final fullIdx =
        script.lines.indexWhere((l) => l.id == currentLine.id);
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
        final isMe = line.character == _character;
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
      BuildContext context, ScriptLine line, Color charColor) {
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
                const Icon(Icons.fiber_manual_record,
                    color: Colors.red, size: 12),
                const SizedBox(width: 6),
                Text(
                  _formatDuration(_recordingDuration),
                  style: const TextStyle(color: Colors.red, fontSize: 14),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRecordingControls(BuildContext context, ScriptLine line,
      bool hasRecording, Color charColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Play existing recording
        if (hasRecording &&
            _status != RecordingStatus.recording) ...[
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
          icon: _status == RecordingStatus.recording
              ? Icons.stop
              : Icons.mic,
          color: _status == RecordingStatus.recording
              ? Colors.red
              : charColor,
          size: 72,
          onTap: _status == RecordingStatus.recording
              ? _stopRecording
              : _startRecording,
          filled: true,
        ),
        if (hasRecording &&
            _status != RecordingStatus.recording) ...[
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
      BuildContext context, bool hasRecording, Color charColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Previous
        TextButton.icon(
          onPressed: _currentLineIdx > 0 ? _previousLine : null,
          icon: const Icon(Icons.chevron_left),
          label: const Text('Previous'),
          style: TextButton.styleFrom(foregroundColor: Colors.white70),
        ),
        // Skip
        TextButton(
          onPressed: _currentLineIdx < _myLines.length - 1
              ? () => _goToLine(_currentLineIdx + 1)
              : null,
          style: TextButton.styleFrom(foregroundColor: Colors.grey[600]),
          child: const Text('Skip'),
        ),
        // Next
        TextButton.icon(
          onPressed: _currentLineIdx < _myLines.length - 1
              ? _nextLine
              : null,
          icon: const Text('Next'),
          label: const Icon(Icons.chevron_right),
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
    if (_recorder == null) return;

    if (_status == RecordingStatus.playing) {
      await _player?.stop();
    }

    final hasPermission = await _recorder!.hasPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission required')),
        );
      }
      return;
    }

    final dir = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory(p.join(dir.path, 'recordings'));
    if (!recordingsDir.existsSync()) {
      recordingsDir.createSync(recursive: true);
    }

    final line = _myLines[_currentLineIdx];
    final filePath = p.join(recordingsDir.path,
        '${line.id}${AppConstants.audioExtension}');

    await _recorder!.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        sampleRate: AppConstants.sampleRate,
        bitRate: 128000,
      ),
      path: filePath,
    );

    _currentRecordingPath = filePath;
    _recordingDuration = Duration.zero;
    _durationTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) {
        setState(() {
          _recordingDuration += const Duration(milliseconds: 100);
        });
      }
    });

    setState(() => _status = RecordingStatus.recording);
  }

  Future<void> _stopRecording() async {
    _durationTimer?.cancel();
    final path = await _recorder?.stop();

    if (path != null && mounted) {
      final line = _myLines[_currentLineIdx];
      final recording = Recording(
        id: const Uuid().v4(),
        scriptLineId: line.id,
        character: _character!,
        localPath: path,
        durationMs: _recordingDuration.inMilliseconds,
        recordedAt: DateTime.now(),
      );
      ref.read(recordingsProvider.notifier).add(recording);

      // Feed into per-actor training pipelines
      final production = ref.read(currentProductionProvider);
      if (production != null) {
        // STT adaptation: recording + transcript as training data
        SttAdaptationService.instance.addSample(
          productionId: production.id,
          actorId: _character!,
          audioPath: path,
          transcript: line.text,
          durationMs: _recordingDuration.inMilliseconds,
        );

        // Voice cloning: auto-rebuild profile with new recording
        final charRecordings = ref.read(recordingsProvider).values
            .where((r) => r.character == _character)
            .map((r) => r.localPath)
            .toList()
          ..add(path);
        VoiceCloneService.instance.buildProfileFromRecordings(
          character: _character!,
          recordingPaths: charRecordings,
        );
      }

      setState(() => _status = RecordingStatus.recorded);
    }
  }

  Future<void> _playRecording() async {
    final line = _myLines[_currentLineIdx];
    final recordings = ref.read(recordingsProvider);
    final recording = recordings[line.id];

    final path = _currentRecordingPath ?? recording?.localPath;
    if (path == null) return;

    try {
      await _player!.setFilePath(path);
      final speed = ref.read(playbackSpeedProvider);
      await _player!.setSpeed(speed);
      setState(() => _status = RecordingStatus.playing);
      await _player!.play();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Playback error: $e')),
        );
      }
    }
  }

  Future<void> _stopPlayback() async {
    await _player?.stop();
    setState(() => _status = RecordingStatus.recorded);
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
