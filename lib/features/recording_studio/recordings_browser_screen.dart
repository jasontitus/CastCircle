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
import '../../data/services/sync_queue.dart';
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
  String? _pendingLineId;
  int _playbackGeneration = 0;
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
    _playbackGeneration++;
    _playerSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  List<_RecordedLine>? _entriesCache;
  (List<ScriptLine>, Map<String, Recording>, String?)? _entriesKey;

  List<_RecordedLine> _memoEntries(
    ParsedScript script,
    Map<String, Recording> recordings,
  ) {
    if (_entriesCache != null &&
        identical(_entriesKey?.$1, script.lines) &&
        identical(_entriesKey?.$2, recordings) &&
        _entriesKey?.$3 == _filterCharacter) {
      return _entriesCache!;
    }
    final linesById = {for (final l in script.lines) l.id: l};
    final entries = <_RecordedLine>[];
    for (final entry in recordings.entries) {
      final line = linesById[entry.key];
      if (line != null &&
          (_filterCharacter == null ||
              entry.value.character == _filterCharacter)) {
        entries.add(_RecordedLine(line: line, recording: entry.value));
      }
    }
    entries.sort((a, b) => a.line.orderIndex.compareTo(b.line.orderIndex));
    _scanFileExistence(entries);
    _entriesKey = (script.lines, recordings, _filterCharacter);
    return _entriesCache = entries;
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

    // Derived lists memoized on (lines, recordings, filter): every play/stop
    // tap toggles _playingLineId via setState, and rebuilding + re-sorting
    // the whole recording library per tap stuttered with hundreds of takes.
    final recordedEntries = _memoEntries(script, recordings);

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
    final scanKey = key;
    unawaited(() async {
      final resolved = <String, bool>{};
      for (final entry in entries) {
        resolved[entry.recording.id] =
            await _resolveRecordingPath(entry.recording) != null;
      }
      if (!mounted || _scannedKey != scanKey) return;
      final missing = resolved.values.where((ok) => !ok).length;
      if (missing > 0) {
        DebugLogService.instance.log(
          LogCategory.general,
          'Recordings: $missing of ${resolved.length} recording file(s) '
          'missing on this device',
        );
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
      (c) => c.name == recording.character,
    );
    final charColor = charIdx >= 0
        ? AppTheme.colorForCharacter(script.characters[charIdx].colorIndex)
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
      confirmDismiss: (_) => _confirmDeleteRecording(line, recording),
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
                              recording.character,
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
                // Generic record button. The studio has no line-selection
                // route state, so this must not promise a line-specific retry.
                IconButton(
                  icon: const Icon(Icons.mic, size: 18),
                  tooltip: 'Record',
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

  Future<bool> _confirmDeleteRecording(
    ScriptLine line,
    Recording recording,
  ) async {
    // Snapshot all non-widget deletion dependencies before opening the dialog.
    // Once cloud deletion starts, cleanup must finish even if this screen pops.
    final productionId = ref.read(currentProductionProvider)?.id;
    final notifier = ref.read(recordingsProvider.notifier);
    final localFile = File(recording.localPath);
    final confirmed = await showDialog<bool>(
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
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return false;

    // Fail closed before local state loses the retry target.
    final cloud = await _deleteCloudCopy(recording, productionId);
    switch (cloud) {
      case _CloudDelete.notNeeded:
      case _CloudDelete.deleted:
        await _deleteRecording(recording, productionId, notifier, localFile);
        // Provider removal already removed the tile; never ask Dismissible to
        // run a second deletion callback.
        return false;
      case _CloudDelete.signInRequired:
        if (mounted) {
          ScaffoldMessenger.of(context).showAutoToast(
            const SnackBar(
              content: Text(
                'Sign in before deleting this recording so its shared cloud copy '
                'can be removed too.',
              ),
              duration: Duration(seconds: 8),
            ),
          );
        }
        return false;
      case _CloudDelete.failed:
        if (mounted) {
          ScaffoldMessenger.of(context).showAutoToast(
            const SnackBar(
              content: Text(
                "Couldn't remove the shared cloud copy. The recording was not "
                'deleted; try again.',
              ),
              duration: Duration(seconds: 8),
            ),
          );
        }
        return false;
    }
  }

  Future<void> _deleteRecording(
    Recording recording,
    String? productionId,
    RecordingsNotifier notifier,
    File localFile,
  ) async {
    final dlog = DebugLogService.instance;
    if (productionId == null) {
      dlog.logError(
        LogCategory.error,
        'Delete: no production snapshot for recording ${recording.id}',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showAutoToast(
          const SnackBar(
            content: Text(
              "Couldn't safely delete that recording because its production "
              'is no longer selected.',
            ),
            duration: Duration(seconds: 6),
          ),
        );
      }
      return;
    }
    final deletingPlayback =
        _playingLineId == recording.scriptLineId ||
        _pendingLineId == recording.scriptLineId;
    if (deletingPlayback) {
      _playbackGeneration++;
      _pendingLineId = null;
      _playingLineId = null;
      if (mounted) {
        try {
          await _player.stop();
        } catch (e) {
          dlog.logError(
            LogCategory.error,
            'Delete: could not stop playback for ${recording.id}',
            e,
          );
        }
      }
    }

    // Delete the exact captured Drift row; the notifier only removes live
    // provider state if this production and recording ID are still current.
    try {
      await notifier.removeRecording(
        productionId,
        recording.scriptLineId,
        recording.id,
      );
    } catch (e) {
      dlog.logError(
        LogCategory.error,
        'Delete: could not remove recording row ${recording.id}',
        e,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showAutoToast(
          SnackBar(
            content: Text("Couldn't safely delete that recording: $e"),
            duration: const Duration(seconds: 6),
          ),
        );
      }
      return;
    }

    var localFileGone = true;
    try {
      if (await localFile.exists()) await localFile.delete();
    } catch (e) {
      localFileGone = false;
      dlog.logError(
        LogCategory.error,
        'Delete: could not remove file ${localFile.path}',
        e,
      );
    }

    if (!mounted) return;
    final problems = <String>[
      if (!localFileGone) 'the audio file is still on this device',
    ];
    ScaffoldMessenger.of(context).showAutoToast(
      SnackBar(
        content: Text(
          problems.isEmpty
              ? 'Recording deleted'
              : 'Recording removed here, but ${problems.join(', and ')}.',
        ),
        duration: Duration(seconds: problems.isEmpty ? 4 : 8),
      ),
    );
  }

  /// Delete this take's cloud metadata, then durably queue its storage object.
  ///
  /// Metadata goes first so a metadata failure leaves playable storage intact.
  /// Once metadata is gone, the durable cleanup queue owns blob deletion and
  /// retries storage failures without blocking local cleanup.
  Future<_CloudDelete> _deleteCloudCopy(
    Recording recording,
    String? productionId,
  ) async {
    final supa = SupabaseService.instance;
    final localUrl = recording.remoteUrl;
    final wasUploaded = localUrl != null && localUrl.isNotEmpty;
    // A castmate's take cached on this device is not ours to delete from the
    // cloud; removing it here just stops it playing locally.
    if (recording.id.startsWith('cache_')) return _CloudDelete.notNeeded;
    if (!supa.isInitialized || !supa.isSignedIn) {
      return wasUploaded ? _CloudDelete.signInRequired : _CloudDelete.notNeeded;
    }
    if (productionId == null) {
      return wasUploaded ? _CloudDelete.failed : _CloudDelete.notNeeded;
    }

    try {
      final deletedUrl = await supa.deleteRecordingMetadata(
        productionId: productionId,
        lineId: recording.scriptLineId,
      );
      // A prior attempt may have deleted metadata and then failed before its
      // cleanup URL was persisted. The captured local URL closes that retry
      // gap when the RPC reports the row already absent.
      final cleanupUrl = deletedUrl ?? (wasUploaded ? localUrl : null);
      if (cleanupUrl != null) {
        await SyncQueue.instance.enqueueObjectCleanup(cleanupUrl);
      }
      DebugLogService.instance.log(
        LogCategory.network,
        'Delete: removed cloud recording metadata for '
        'line=${recording.scriptLineId}'
        '${cleanupUrl != null ? ' and queued object cleanup' : ''}',
      );
      return deletedUrl == null && !wasUploaded
          ? _CloudDelete.notNeeded
          : _CloudDelete.deleted;
    } catch (e) {
      DebugLogService.instance.logError(
        LogCategory.error,
        'Delete: cloud metadata/cleanup handoff failed for '
        'line=${recording.scriptLineId}',
        e,
      );
      return _CloudDelete.failed;
    }
  }

  /// Resolve a recording's local path — if the stored absolute path is stale
  /// (app container UUID changed after reinstall), try the current Documents dir.
  // Documents dir resolved once — _resolveRecordingPath runs per recording
  // during the existence scan (hundreds of platform-channel hops otherwise).
  Directory? _docsDirCache;

  Future<String?> _resolveRecordingPath(Recording recording) async {
    // Async exists(): this runs per recording in the existence scan — the
    // sync stat variant blocked the UI isolate N times on first paint.
    if (await File(recording.localPath).exists()) return recording.localPath;

    // Try current Documents/recordings/{filename}
    final docsDir = _docsDirCache ??= await getApplicationDocumentsDirectory();
    final filename = p.basename(recording.localPath);
    final resolved = p.join(docsDir.path, 'recordings', filename);
    if (await File(resolved).exists()) return resolved;

    // Try recording cache (downloaded from cloud). The directory tree is
    // walked ONCE per screen and searched in memory — this fallback runs per
    // unresolved recording, and a synchronous recursive listSync on every
    // call janked the browser when many rows needed it.
    final cachePath = (await _cachedRecordingPaths(docsDir.path)).firstWhere(
      (path) =>
          p.basename(path) == filename || path.contains(recording.scriptLineId),
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
    final generation = ++_playbackGeneration;
    _pendingLineId = lineId;
    bool isCurrent() => mounted && generation == _playbackGeneration;

    dlog.log(
      LogCategory.general,
      'Play: resolving ${recording.scriptLineId.substring(0, 8)}... stored=${recording.localPath.split("/").last}',
    );

    try {
      final resolvedPath = await _resolveRecordingPath(recording);
      if (!isCurrent()) return;

      if (resolvedPath == null) {
        _pendingLineId = null;
        dlog.log(
          LogCategory.error,
          'Play: file NOT FOUND for ${recording.scriptLineId.substring(0, 8)}',
        );
        ScaffoldMessenger.of(context).showAutoToast(
          SnackBar(
            content: Text(
              'Recording file not found (${p.basename(recording.localPath)})',
            ),
          ),
        );
        return;
      }

      final size = await File(resolvedPath).length();
      if (!isCurrent()) return;
      dlog.log(
        LogCategory.general,
        'Play: found at ${resolvedPath.split("/").last} (${size ~/ 1024}KB)',
      );

      if (size < 100) {
        _pendingLineId = null;
        dlog.log(LogCategory.error, 'Play: file empty (${size}B)');
        ScaffoldMessenger.of(context).showAutoToast(
          const SnackBar(content: Text('Recording file is empty')),
        );
        return;
      }

      await _player.stop();
      if (!isCurrent()) return;
      // Rehearsal capture leaves iOS in the .record category; without this the
      // player runs silently. Force a playback session first.
      await PlaybackSession.ensurePlayback();
      if (!isCurrent()) return;
      await _player.setFilePath(resolvedPath);
      if (!isCurrent()) return;
      final volume = await AudioLevelService.instance.volumeFor(resolvedPath);
      if (!isCurrent()) return;
      await _player.setVolume(volume);
      if (!isCurrent()) return;
      _pendingLineId = null;
      setState(() => _playingLineId = lineId);
      await _player.play();
      if (!isCurrent()) return;
    } catch (e) {
      debugPrint('PlayRecording ERROR: $e');
      dlog.logError(LogCategory.error, 'Play: playback failed', e);
      if (isCurrent()) {
        _pendingLineId = null;
        setState(() => _playingLineId = null);
        final message = e is FileSystemException
            ? 'Recording file is no longer available'
            : 'Playback error: $e';
        ScaffoldMessenger.of(
          context,
        ).showAutoToast(SnackBar(content: Text(message)));
      }
    }
  }

  Future<void> _stopPlayback() async {
    _playbackGeneration++;
    _pendingLineId = null;
    await _player.stop();
    if (mounted) setState(() => _playingLineId = null);
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

/// Outcome of removing a take's storage object and cloud metadata row.
enum _CloudDelete {
  /// The take was never uploaded, or is another castmate's cached copy.
  notNeeded,
  deleted,
  signInRequired,
  failed,
}
