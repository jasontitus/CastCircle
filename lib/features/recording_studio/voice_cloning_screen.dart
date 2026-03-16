import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/script_models.dart';
import '../../data/services/voice_clone_service.dart';
import '../../data/services/tts_service.dart';
import '../../providers/production_providers.dart';

/// Voice cloning UI: shows characters with recordings, lets users build
/// voice profiles and test cloned speech against original recordings.
class VoiceCloningScreen extends ConsumerStatefulWidget {
  const VoiceCloningScreen({super.key});

  @override
  ConsumerState<VoiceCloningScreen> createState() =>
      _VoiceCloningScreenState();
}

class _VoiceCloningScreenState extends ConsumerState<VoiceCloningScreen> {
  final AudioPlayer _player = AudioPlayer();
  final VoiceCloneService _voiceClone = VoiceCloneService.instance;
  final TtsService _tts = TtsService.instance;

  String? _selectedCharacter;
  String? _playingLineId;
  _PlaybackMode? _playbackMode;
  bool _building = false;
  String? _generatingLineId;

  @override
  void initState() {
    super.initState();
    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        if (mounted) setState(() {
          _playingLineId = null;
          _playbackMode = null;
        });
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final script = ref.watch(currentScriptProvider);
    final recordings = ref.watch(recordingsProvider);

    if (script == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Voice Cloning')),
        body: const Center(child: Text('No script loaded')),
      );
    }

    // Characters that have at least one recording
    final charsWithRecordings = <String, List<Recording>>{};
    for (final rec in recordings.values) {
      charsWithRecordings.putIfAbsent(rec.character, () => []).add(rec);
    }

    // Sort by character order in script
    final sortedChars = script.characters
        .where((c) => charsWithRecordings.containsKey(c.name))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice Cloning'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: sortedChars.isEmpty
          ? _buildEmptyState(context)
          : Column(
              children: [
                // Character cards
                SizedBox(
                  height: 140,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(12),
                    itemCount: sortedChars.length,
                    itemBuilder: (context, index) {
                      final char = sortedChars[index];
                      final charRecs = charsWithRecordings[char.name]!;
                      return _buildCharacterCard(
                          context, script, char, charRecs);
                    },
                  ),
                ),
                const Divider(height: 1),
                // Selected character's lines
                if (_selectedCharacter != null)
                  Expanded(
                    child: _buildLinesList(
                        context, script, recordings, _selectedCharacter!),
                  )
                else
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.record_voice_over,
                              size: 64,
                              color: Colors.grey[700]),
                          const SizedBox(height: 16),
                          Text('Select a character above',
                              style: TextStyle(color: Colors.grey[500])),
                          const SizedBox(height: 4),
                          Text('to build and test voice clones',
                              style: TextStyle(
                                  color: Colors.grey[600], fontSize: 12)),
                        ],
                      ),
                    ),
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
            Icon(Icons.mic_off, size: 64, color: Colors.grey[700]),
            const SizedBox(height: 16),
            Text('No recordings yet',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Record lines for characters in the Recording Studio\n'
              'to enable voice cloning.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[500], fontSize: 13),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => context.push('/record'),
              icon: const Icon(Icons.mic),
              label: const Text('Go to Recording Studio'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCharacterCard(BuildContext context, ParsedScript script,
      ScriptCharacter char, List<Recording> charRecs) {
    final color = AppTheme.colorForCharacter(char.colorIndex);
    final isSelected = _selectedCharacter == char.name;
    final profile = _voiceClone.getProfile(char.name);
    final totalLines = char.lineCount;
    final totalDurationMs =
        charRecs.fold<int>(0, (sum, r) => sum + r.durationMs);
    final durationSecs = (totalDurationMs / 1000).round();

    return GestureDetector(
      onTap: () => setState(() => _selectedCharacter = char.name),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 160,
        margin: const EdgeInsets.only(right: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected
              ? color.withValues(alpha: 0.15)
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? color : Colors.transparent,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: color,
                  radius: 14,
                  child: Text(
                    char.name[0],
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    char.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${charRecs.length}/$totalLines lines recorded',
              style: TextStyle(color: Colors.grey[500], fontSize: 11),
            ),
            Text(
              '${durationSecs}s of audio',
              style: TextStyle(color: Colors.grey[600], fontSize: 11),
            ),
            const Spacer(),
            // Profile status
            Row(
              children: [
                Icon(
                  profile != null
                      ? Icons.check_circle
                      : Icons.circle_outlined,
                  size: 14,
                  color: profile != null ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 4),
                Text(
                  profile != null
                      ? '${(profile.quality * 100).toInt()}% quality'
                      : 'No profile',
                  style: TextStyle(
                    fontSize: 11,
                    color: profile != null ? Colors.green : Colors.grey,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLinesList(BuildContext context, ParsedScript script,
      Map<String, Recording> recordings, String character) {
    final charLines = script.linesForCharacter(character);
    final charRecs = recordings.values
        .where((r) => r.character == character)
        .toList();
    final profile = _voiceClone.getProfile(character);
    final charIdx =
        script.characters.indexWhere((c) => c.name == character);
    final charColor =
        charIdx >= 0 ? AppTheme.colorForCharacter(charIdx) : Colors.blue;

    return Column(
      children: [
        // Action bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: charColor,
                radius: 16,
                child: Text(character[0],
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(character,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text(
                      '${charRecs.length} recordings, '
                      '${charLines.length} total lines',
                      style: TextStyle(color: Colors.grey[500], fontSize: 12),
                    ),
                  ],
                ),
              ),
              // Build / Rebuild profile button
              _building
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : FilledButton.icon(
                      onPressed: charRecs.length >= 3
                          ? () => _buildProfile(character, charRecs)
                          : null,
                      icon: Icon(profile != null
                          ? Icons.refresh
                          : Icons.auto_awesome,
                          size: 18),
                      label: Text(
                        profile != null ? 'Rebuild' : 'Build Clone',
                        style: const TextStyle(fontSize: 13),
                      ),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                      ),
                    ),
            ],
          ),
        ),
        if (charRecs.length < 3)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Colors.orange.withValues(alpha: 0.1),
            child: Row(
              children: [
                const Icon(Icons.info_outline,
                    size: 16, color: Colors.orange),
                const SizedBox(width: 8),
                Text(
                  'Record ${3 - charRecs.length} more '
                  'line${3 - charRecs.length == 1 ? '' : 's'} to enable cloning',
                  style:
                      const TextStyle(color: Colors.orange, fontSize: 12),
                ),
              ],
            ),
          ),
        // Lines list
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: charLines.length,
            itemBuilder: (context, index) {
              final line = charLines[index];
              final recording = recordings[line.id];
              return _buildLineTile(
                  context, script, line, recording, profile, charColor);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildLineTile(BuildContext context, ParsedScript script,
      ScriptLine line, Recording? recording, VoiceProfile? profile,
      Color charColor) {
    final hasRecording = recording != null;
    final isPlayingOriginal =
        _playingLineId == line.id && _playbackMode == _PlaybackMode.original;
    final isPlayingClone =
        _playingLineId == line.id && _playbackMode == _PlaybackMode.clone;
    final isGenerating = _generatingLineId == line.id;

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Scene tag + line number
            Row(
              children: [
                Text(
                  '${line.act} ${line.scene}'.trim(),
                  style: TextStyle(color: Colors.grey[600], fontSize: 10),
                ),
                const Spacer(),
                if (hasRecording)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('Recorded',
                        style: TextStyle(
                            color: Colors.green,
                            fontSize: 9,
                            fontWeight: FontWeight.bold)),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            // Stage direction
            if (line.stageDirection.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '(${line.stageDirection})',
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: Colors.grey[500],
                    fontSize: 12,
                  ),
                ),
              ),
            // Line text
            Text(
              line.text,
              style: const TextStyle(fontSize: 14, height: 1.3),
            ),
            const SizedBox(height: 8),
            // Playback controls row
            Row(
              children: [
                // Play original recording
                if (hasRecording)
                  _playbackChip(
                    icon: isPlayingOriginal ? Icons.stop : Icons.play_arrow,
                    label: 'Original',
                    color: charColor,
                    isActive: isPlayingOriginal,
                    onTap: () => isPlayingOriginal
                        ? _stopPlayback()
                        : _playOriginal(recording, line.id),
                  ),
                if (hasRecording) const SizedBox(width: 8),
                // Play voice clone
                if (profile != null)
                  isGenerating
                      ? const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : _playbackChip(
                          icon: isPlayingClone
                              ? Icons.stop
                              : Icons.record_voice_over,
                          label: 'Clone',
                          color: Colors.purple,
                          isActive: isPlayingClone,
                          onTap: () => isPlayingClone
                              ? _stopPlayback()
                              : _playClone(line),
                        ),
                const Spacer(),
                // Duration of original
                if (hasRecording)
                  Text(
                    _formatDuration(
                        Duration(milliseconds: recording.durationMs)),
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _playbackChip({
    required IconData icon,
    required String label,
    required Color color,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return Material(
      color: isActive
          ? color.withValues(alpha: 0.2)
          : Colors.grey[900],
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isActive ? color : Colors.grey[700]!,
              width: isActive ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: isActive ? color : Colors.white70),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: isActive ? color : Colors.white70,
                  fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Actions ─────────────────────────────────────────────

  Future<void> _buildProfile(
      String character, List<Recording> charRecs) async {
    setState(() => _building = true);

    final paths = charRecs.map((r) => r.localPath).toList();
    final profile = await _voiceClone.buildProfileFromRecordings(
      character: character,
      recordingPaths: paths,
    );

    if (mounted) {
      setState(() => _building = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Voice profile built: ${profile.referenceAudioPaths.length} clips, '
            '${(profile.quality * 100).toInt()}% quality',
          ),
        ),
      );
    }
  }

  Future<void> _playOriginal(Recording recording, String lineId) async {
    try {
      await _player.stop();
      if (!File(recording.localPath).existsSync()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Recording file not found')),
          );
        }
        return;
      }
      await _player.setFilePath(recording.localPath);
      setState(() {
        _playingLineId = lineId;
        _playbackMode = _PlaybackMode.original;
      });
      await _player.play();
    } catch (e) {
      if (mounted) {
        setState(() {
          _playingLineId = null;
          _playbackMode = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Playback error: $e')),
        );
      }
    }
  }

  Future<void> _playClone(ScriptLine line) async {
    final production = ref.read(currentProductionProvider);
    if (production == null) return;

    setState(() => _generatingLineId = line.id);

    try {
      // Try to get cached voice-cloned audio first
      final cachedPath = await _voiceClone.generateLine(
        productionId: production.id,
        character: line.character,
        lineId: line.id,
        text: line.text,
      );

      if (cachedPath != null && File(cachedPath).existsSync()) {
        // Play cached clone audio
        await _player.stop();
        await _player.setFilePath(cachedPath);
        setState(() {
          _generatingLineId = null;
          _playingLineId = line.id;
          _playbackMode = _PlaybackMode.clone;
        });
        await _player.play();
      } else {
        // Fall back to TTS preview — demonstrates what the clone would sound like
        if (!_tts.isInitialized) await _tts.init();

        // Assign voice for this character if not already done
        final script = ref.read(currentScriptProvider);
        if (script != null) {
          final charIdx =
              script.characters.indexWhere((c) => c.name == line.character);
          if (charIdx >= 0) {
            _tts.assignVoice(line.character, charIdx);
          }
        }

        setState(() {
          _generatingLineId = null;
          _playingLineId = line.id;
          _playbackMode = _PlaybackMode.clone;
        });

        _tts.setCompletionHandler(() {
          if (mounted) {
            setState(() {
              _playingLineId = null;
              _playbackMode = null;
            });
          }
        });

        await _tts.speak(line.text, character: line.character);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _generatingLineId = null;
          _playingLineId = null;
          _playbackMode = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Clone playback error: $e')),
        );
      }
    }
  }

  Future<void> _stopPlayback() async {
    await _player.stop();
    await _tts.stop();
    setState(() {
      _playingLineId = null;
      _playbackMode = null;
    });
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

enum _PlaybackMode { original, clone }
