import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/script_models.dart';
import '../../providers/production_providers.dart';

/// Browse all recordings for the current production, grouped by character.
class RecordingsBrowserScreen extends ConsumerStatefulWidget {
  const RecordingsBrowserScreen({super.key});

  @override
  ConsumerState<RecordingsBrowserScreen> createState() =>
      _RecordingsBrowserScreenState();
}

class _RecordingsBrowserScreenState
    extends ConsumerState<RecordingsBrowserScreen> {
  final AudioPlayer _player = AudioPlayer();
  String? _playingLineId;
  String? _filterCharacter; // null = show all

  @override
  void initState() {
    super.initState();
    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        if (mounted) setState(() => _playingLineId = null);
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
        appBar: AppBar(title: const Text('Recordings')),
        body: const Center(child: Text('No script loaded')),
      );
    }

    // Build list of recorded lines with their recordings
    final recordedEntries = <_RecordedLine>[];
    for (final entry in recordings.entries) {
      final line = script.lines
          .where((l) => l.id == entry.key)
          .firstOrNull;
      if (line != null) {
        if (_filterCharacter == null ||
            line.character == _filterCharacter) {
          recordedEntries.add(_RecordedLine(line: line, recording: entry.value));
        }
      }
    }

    // Sort by script order
    recordedEntries.sort((a, b) =>
        a.line.orderIndex.compareTo(b.line.orderIndex));

    // Characters that have at least one recording
    final recordedCharacters = <String>{};
    for (final entry in recordings.values) {
      recordedCharacters.add(entry.character);
    }

    // Stats
    final totalRecordings = recordings.length;
    final totalDialogueLines = script.lines
        .where((l) => l.lineType == LineType.dialogue)
        .length;
    final totalDurationMs = recordings.values
        .fold<int>(0, (sum, r) => sum + r.durationMs);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Recordings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        actions: [
          if (_playingLineId != null)
            IconButton(
              icon: const Icon(Icons.stop),
              tooltip: 'Stop playback',
              onPressed: _stopPlayback,
            ),
        ],
      ),
      body: recordings.isEmpty
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.mic_off, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('No recordings yet',
                      style: TextStyle(color: Colors.grey)),
                  SizedBox(height: 8),
                  Text('Head to the Recording Studio to get started',
                      style: TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            )
          : Column(
              children: [
                // Summary bar
                _buildSummary(
                    context, totalRecordings, totalDialogueLines, totalDurationMs),
                const Divider(height: 1),
                // Character filter chips
                if (recordedCharacters.length > 1)
                  _buildCharacterFilter(context, script, recordedCharacters),
                // Recordings list
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    itemCount: recordedEntries.length,
                    itemBuilder: (context, index) =>
                        _buildRecordingTile(context, script, recordedEntries[index]),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildSummary(BuildContext context, int totalRecordings,
      int totalLines, int totalDurationMs) {
    final duration = Duration(milliseconds: totalDurationMs);
    return Container(
      padding: const EdgeInsets.all(16),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _statColumn(context, '$totalRecordings', 'Recorded'),
          _statColumn(context, '$totalLines', 'Total Lines'),
          _statColumn(context,
              '${(totalRecordings / totalLines * 100).toInt()}%', 'Coverage'),
          _statColumn(context, _formatDuration(duration), 'Duration'),
        ],
      ),
    );
  }

  Widget _statColumn(BuildContext context, String value, String label) {
    return Column(
      children: [
        Text(
          value,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
        const SizedBox(height: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _buildCharacterFilter(BuildContext context, ParsedScript script,
      Set<String> recordedCharacters) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          FilterChip(
            label: const Text('All'),
            selected: _filterCharacter == null,
            onSelected: (_) => setState(() => _filterCharacter = null),
          ),
          const SizedBox(width: 8),
          ...script.characters
              .where((c) => recordedCharacters.contains(c.name))
              .map((char) {
            final color = AppTheme.colorForCharacter(char.colorIndex);
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                avatar: CircleAvatar(
                  backgroundColor: color,
                  radius: 8,
                  child: null,
                ),
                label: Text(char.name),
                selected: _filterCharacter == char.name,
                onSelected: (_) => setState(() {
                  _filterCharacter =
                      _filterCharacter == char.name ? null : char.name;
                }),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildRecordingTile(
      BuildContext context, ParsedScript script, _RecordedLine entry) {
    final line = entry.line;
    final recording = entry.recording;
    final isPlaying = _playingLineId == line.id;

    final charIdx =
        script.characters.indexWhere((c) => c.name == line.character);
    final charColor =
        charIdx >= 0 ? AppTheme.colorForCharacter(charIdx) : Colors.blue;
    final fileExists = File(recording.localPath).existsSync();

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: fileExists
            ? () => isPlaying ? _stopPlayback() : _playRecording(recording, line.id)
            : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Play/stop indicator
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isPlaying
                      ? charColor.withValues(alpha: 0.2)
                      : Colors.grey[900],
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isPlaying ? charColor : Colors.grey[700]!,
                    width: isPlaying ? 2 : 1,
                  ),
                ),
                child: Icon(
                  isPlaying ? Icons.stop : Icons.play_arrow,
                  color: isPlaying ? charColor : Colors.white70,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              // Line info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: charColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            line.character,
                            style: TextStyle(
                              color: charColor,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${line.act} ${line.scene}'.trim(),
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      line.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Duration and status
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _formatDurationShort(
                        Duration(milliseconds: recording.durationMs)),
                    style: TextStyle(
                      color: Colors.grey[500],
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (!fileExists)
                    Icon(Icons.cloud_off, size: 14, color: Colors.grey[600])
                  else if (recording.remoteUrl != null)
                    Icon(Icons.cloud_done, size: 14, color: Colors.green[400])
                  else
                    Icon(Icons.phone_android, size: 14, color: Colors.grey[500]),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _playRecording(Recording recording, String lineId) async {
    try {
      await _player.stop();
      await _player.setFilePath(recording.localPath);
      setState(() => _playingLineId = lineId);
      await _player.play();
    } catch (e) {
      if (mounted) {
        setState(() => _playingLineId = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Playback error: $e')),
        );
      }
    }
  }

  Future<void> _stopPlayback() async {
    await _player.stop();
    setState(() => _playingLineId = null);
  }

  String _formatDuration(Duration d) {
    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    }
    if (d.inMinutes > 0) {
      return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    }
    return '${d.inSeconds}s';
  }

  String _formatDurationShort(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _RecordedLine {
  final ScriptLine line;
  final Recording recording;

  const _RecordedLine({required this.line, required this.recording});
}
