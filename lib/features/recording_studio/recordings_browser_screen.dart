import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/responsive.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/script_models.dart';
import '../../data/services/debug_log_service.dart';
import '../../data/services/audio_level_service.dart';
import '../../data/services/playback_session.dart';
import '../../data/services/supabase_service.dart';
import '../../providers/production_providers.dart';
import '../../core/toast.dart';

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
  StreamSubscription? _playerSub;
  String? _playingLineId;
  String? _filterCharacter; // null = show all

  /// recording.id → whether its audio actually resolves on disk. Resolving a
  /// path hits the filesystem (and the download cache), so it can't happen in
  /// build(): tiles start optimistic and flip when the scan comes back. This
  /// used to be a hardcoded `true`, which made the missing-file indicator and
  /// the "don't try to play it" guard dead code.
  final Map<String, bool> _fileResolved = {};
  String? _scannedKey;

  @override
  void initState() {
    super.initState();
    _playerSub = _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        if (mounted) setState(() => _playingLineId = null);
      }
    });
  }

  @override
  void dispose() {
    _playerSub?.cancel();
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

    // Build a fast lookup map: O(n+m) instead of the prior O(n*m).
    final linesById = {for (final l in script.lines) l.id: l};

    // Build list of recorded lines with their recordings
    final recordedEntries = <_RecordedLine>[];
    for (final entry in recordings.entries) {
      final line = linesById[entry.key];
      if (line != null) {
        if (_filterCharacter == null || line.character == _filterCharacter) {
          recordedEntries.add(
            _RecordedLine(line: line, recording: entry.value),
          );
        }
      }
    }

    // Sort by script order
    recordedEntries.sort(
      (a, b) => a.line.orderIndex.compareTo(b.line.orderIndex),
    );

    _scanFileExistence(recordedEntries);

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
    final totalDurationMs = recordings.values.fold<int>(
      0,
      (sum, r) => sum + r.durationMs,
    );

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
                  Text(
                    'No recordings yet',
                    style: TextStyle(color: Colors.grey),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Head to the Recording Studio to get started',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                // Summary bar
                _buildSummary(
                  context,
                  totalRecordings,
                  totalDialogueLines,
                  totalDurationMs,
                ),
                const Divider(height: 1),
                // Character filter chips
                if (recordedCharacters.length > 1)
                  _buildCharacterFilter(context, script, recordedCharacters),
                // Recordings list
                Expanded(
                  child: ContentConstraint(
                    maxWidth: 720,
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      itemCount: recordedEntries.length,
                      itemBuilder: (context, index) => _buildRecordingTile(
                        context,
                        script,
                        recordedEntries[index],
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  /// Resolve every listed recording's file once per list contents, off the
  /// build path. See [_fileResolved].
  void _scanFileExistence(List<_RecordedLine> entries) {
    final key = entries.map((e) => e.recording.id).join('|');
    if (key == _scannedKey) return;
    _scannedKey = key;
    unawaited(() async {
      final resolved = <String, bool>{};
      for (final entry in entries) {
        resolved[entry.recording.id] =
            await _resolveRecordingPath(entry.recording) != null;
      }
      if (!mounted) return;
      final missing = resolved.values.where((ok) => !ok).length;
      if (missing > 0) {
        DebugLogService.instance.log(LogCategory.general,
            'Recordings: $missing of ${resolved.length} recording file(s) '
            'missing on this device');
      }
      setState(() {
        _fileResolved
          ..clear()
          ..addAll(resolved);
      });
    }());
  }

  Widget _buildSummary(
    BuildContext context,
    int totalRecordings,
    int totalLines,
    int totalDurationMs,
  ) {
    final duration = Duration(milliseconds: totalDurationMs);
    return Container(
      padding: const EdgeInsets.all(16),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _statColumn(context, '$totalRecordings', 'Recorded'),
          _statColumn(context, '$totalLines', 'Total Lines'),
          _statColumn(
            context,
            // A script with no dialogue lines makes this Infinity/NaN, and
            // double.toInt() THROWS on those — the whole screen went blank.
            totalLines > 0
                ? '${(totalRecordings / totalLines * 100).toInt()}%'
                : '—',
            'Coverage',
          ),
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

  Widget _buildCharacterFilter(
    BuildContext context,
    ParsedScript script,
    Set<String> recordedCharacters,
  ) {
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
                      _filterCharacter = _filterCharacter == char.name
                          ? null
                          : char.name;
                    }),
                  ),
                );
              }),
        ],
      ),
    );
  }

  Widget _buildRecordingTile(
    BuildContext context,
    ParsedScript script,
    _RecordedLine entry,
  ) {
    final line = entry.line;
    final recording = entry.recording;
    final isPlaying = _playingLineId == line.id;

    final charIdx = script.characters.indexWhere(
      (c) => c.name == line.character,
    );
    final charColor = charIdx >= 0
        ? AppTheme.colorForCharacter(charIdx)
        : Colors.blue;
    // Optimistic until the async scan says otherwise (see [_fileResolved]);
    // the resolver, not a raw path check, decides — stale container paths and
    // cloud-cached copies still count as present.
    final fileExists = _fileResolved[recording.id] ?? true;

    return Dismissible(
      key: ValueKey(recording.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: Colors.red,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Delete Recording?'),
            content: Text(
              'Delete recording for "${line.text.length > 50 ? '${line.text.substring(0, 47)}...' : line.text}"?\n\n'
              'It is removed from this device and from the cast\'s cloud copy. '
              'Castmates who already downloaded it keep theirs.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text(
                  'Delete',
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ],
          ),
        );
      },
      onDismissed: (_) => _deleteRecording(recording),
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: fileExists
              ? () => isPlaying
                    ? _stopPlayback()
                    : _playRecording(recording, line.id)
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
                              horizontal: 6,
                              vertical: 2,
                            ),
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
                        Duration(milliseconds: recording.durationMs),
                      ),
                      style: TextStyle(
                        color: Colors.grey[500],
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (!fileExists)
                      Icon(Icons.cloud_off, size: 14, color: Colors.grey[600]),
                  ],
                ),
                const SizedBox(width: 4),
                // Re-record button
                IconButton(
                  icon: const Icon(Icons.mic, size: 18),
                  tooltip: 'Re-record',
                  onPressed: () {
                    context.push('/record');
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _deleteRecording(Recording recording) async {
    final dlog = DebugLogService.instance;
    // Read providers before the first await: riverpod throws if `ref` is used
    // after the user navigates away mid-delete.
    final notifier = ref.read(recordingsProvider.notifier);
    final productionId = ref.read(currentProductionProvider)?.id;

    // Delete local file
    var localFileGone = true;
    try {
      final file = File(recording.localPath);
      if (file.existsSync()) await file.delete();
    } catch (e) {
      // Was a bare `catch (_) {}`: the take stayed on disk and kept playing
      // through the path resolver, with the UI insisting it was deleted.
      localFileGone = false;
      dlog.logError(LogCategory.error,
          'Delete: could not remove file ${recording.localPath}', e);
    }

    // Remove from provider (and Drift DB)
    try {
      await notifier.remove(recording.scriptLineId);
    } catch (e) {
      dlog.logError(LogCategory.error,
          'Delete: could not remove recording row ${recording.id}', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showAutoToast(SnackBar(
          content: Text("Couldn't delete that recording: $e"),
          duration: const Duration(seconds: 6),
        ));
      }
      return;
    }

    final cloud = await _deleteCloudCopy(recording, productionId);

    if (!mounted) return;
    final problems = <String>[
      if (!localFileGone) 'the audio file is still on this device',
      if (cloud == _CloudDelete.failed)
        'the cloud copy could not be removed, so castmates may still hear it',
    ];
    ScaffoldMessenger.of(context).showAutoToast(SnackBar(
      content: Text(problems.isEmpty
          ? 'Recording deleted'
          : 'Recording removed here, but ${problems.join(', and ')}.'),
      duration: Duration(seconds: problems.isEmpty ? 4 : 8),
    ));
  }

  /// Delete this take's cloud row so castmates stop syncing it.
  ///
  /// The row — not the storage object — is what every castmate's sync reads;
  /// uploads already orphan their previous objects by design (a unique key per
  /// take), so leaving the blob behind changes nothing that plays.
  /// Castmates who already downloaded the take keep their cached copy.
  Future<_CloudDelete> _deleteCloudCopy(
      Recording recording, String? productionId) async {
    final supa = SupabaseService.instance;
    if (!supa.isInitialized || !supa.isSignedIn) return _CloudDelete.skipped;
    final userId = supa.currentUser?.id;
    if (productionId == null || userId == null) return _CloudDelete.skipped;
    // A castmate's take cached on this device is not ours to delete from the
    // cloud; removing it here just stops it playing locally.
    if (recording.id.startsWith('cache_')) return _CloudDelete.skipped;

    final wasUploaded =
        recording.remoteUrl != null && recording.remoteUrl!.isNotEmpty;
    try {
      final removed = await supa.client
          .from('recordings')
          .delete()
          .eq('production_id', productionId)
          .eq('line_id', recording.scriptLineId)
          .eq('user_id', userId)
          .select();
      if (removed.isNotEmpty) {
        DebugLogService.instance.log(
            LogCategory.network,
            'Delete: removed cloud recording row for '
            'line=${recording.scriptLineId}');
        return _CloudDelete.deleted;
      }
      // No rows came back. If this take was never uploaded there was nothing
      // to delete; if it WAS, the delete was refused (the recordings table has
      // no DELETE policy today) and the cast still has it.
      if (!wasUploaded) return _CloudDelete.skipped;
      DebugLogService.instance.log(
          LogCategory.error,
          'Delete: cloud row for line=${recording.scriptLineId} was NOT '
          'removed (no rows deleted — RLS has no delete policy?); castmates '
          'will keep syncing this take');
      return _CloudDelete.failed;
    } catch (e) {
      DebugLogService.instance.logError(
          LogCategory.error,
          'Delete: cloud delete failed for line=${recording.scriptLineId}',
          e);
      return _CloudDelete.failed;
    }
  }

  /// Resolve a recording's local path — if the stored absolute path is stale
  /// (app container UUID changed after reinstall), try the current Documents dir.
  Future<String?> _resolveRecordingPath(Recording recording) async {
    // Try stored path first
    if (File(recording.localPath).existsSync()) return recording.localPath;

    // Try current Documents/recordings/{filename}
    final docsDir = await getApplicationDocumentsDirectory();
    final filename = p.basename(recording.localPath);
    final resolved = p.join(docsDir.path, 'recordings', filename);
    if (File(resolved).existsSync()) return resolved;

    // Try recording cache (downloaded from cloud). The directory tree is
    // walked ONCE per screen and searched in memory — this fallback runs per
    // unresolved recording, and a synchronous recursive listSync on every
    // call janked the browser when many rows needed it.
    final cachePath = (await _cachedRecordingPaths(docsDir.path)).firstWhere(
      (path) =>
          p.basename(path) == filename ||
          path.contains(recording.scriptLineId),
      orElse: () => '',
    );
    if (cachePath.isNotEmpty) return cachePath;

    return null;
  }

  List<String>? _recordingCachePaths;

  /// All file paths under recording_cache, listed once and reused for every
  /// fallback resolution this screen performs.
  Future<List<String>> _cachedRecordingPaths(String docsPath) async {
    final cached = _recordingCachePaths;
    if (cached != null) return cached;
    final dir = Directory(p.join(docsPath, 'recording_cache'));
    if (!dir.existsSync()) return _recordingCachePaths = const [];
    final paths = await dir
        .list(recursive: true)
        .where((e) => e is File)
        .map((e) => e.path)
        .toList();
    return _recordingCachePaths = paths;
  }

  Future<void> _playRecording(Recording recording, String lineId) async {
    final dlog = DebugLogService.instance;
    dlog.log(
      LogCategory.general,
      'Play: resolving ${recording.scriptLineId.substring(0, 8)}... stored=${recording.localPath.split("/").last}',
    );

    final resolvedPath = await _resolveRecordingPath(recording);

    if (resolvedPath == null) {
      dlog.log(
        LogCategory.error,
        'Play: file NOT FOUND for ${recording.scriptLineId.substring(0, 8)}',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showAutoToast(
          SnackBar(
            content: Text(
              'Recording file not found (${p.basename(recording.localPath)})',
            ),
          ),
        );
      }
      return;
    }

    final size = File(resolvedPath).lengthSync();
    dlog.log(
      LogCategory.general,
      'Play: found at ${resolvedPath.split("/").last} (${size ~/ 1024}KB)',
    );

    if (size < 100) {
      dlog.log(LogCategory.error, 'Play: file empty (${size}B)');
      if (mounted) {
        ScaffoldMessenger.of(context).showAutoToast(
          const SnackBar(content: Text('Recording file is empty')),
        );
      }
      return;
    }

    try {
      await _player.stop();
      // Rehearsal capture leaves iOS in the .record category; without this the
      // player runs silently. Force a playback session first.
      await PlaybackSession.ensurePlayback();
      await _player.setFilePath(resolvedPath);
      await _player.setVolume(
        await AudioLevelService.instance.volumeFor(resolvedPath),
      );
      setState(() => _playingLineId = lineId);
      await _player.play();
    } catch (e) {
      debugPrint('PlayRecording ERROR: $e');
      dlog.logError(LogCategory.error, 'Play: playback failed', e);
      if (mounted) {
        setState(() => _playingLineId = null);
        ScaffoldMessenger.of(
          context,
        ).showAutoToast(SnackBar(content: Text('Playback error: $e')));
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

/// Outcome of removing a take's cloud row.
enum _CloudDelete {
  /// Nothing to delete (signed out, never uploaded, or not our recording).
  skipped,
  deleted,
  failed,
}
