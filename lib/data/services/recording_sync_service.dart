import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/script_models.dart';
import 'debug_log_service.dart';
import 'supabase_service.dart';

/// Syncs recordings between local device and Supabase cloud.
///
/// Handles:
/// - Uploading local recordings that haven't been pushed to cloud
/// - Downloading other cast members' recordings for rehearsal playback
/// - Caching downloaded recordings with timestamp-based invalidation
/// - Real-time subscription for new recordings as they arrive
///
/// Recordings are keyed by script line UUID, which is stable across
/// reordering. Deleted lines orphan recordings but don't lose them —
/// they can be re-associated if the line is restored.
class RecordingSyncService {
  RecordingSyncService._();
  static final instance = RecordingSyncService._();

  final _dlog = DebugLogService.instance;

  /// Cache dir for downloaded recordings: Documents/recording_cache/
  String? _cacheDir;

  /// Metadata for cached recordings: lineId → {recordedAt, userId, path}
  final Map<String, _CachedRecording> _cache = {};

  /// Realtime subscription
  StreamSubscription? _realtimeSub;

  /// Callback when a new recording is downloaded and ready
  void Function(String lineId, String localPath)? onRecordingReady;

  /// Get or create the cache directory.
  Future<String> get cacheDir async {
    if (_cacheDir != null) return _cacheDir!;
    final dir = await getApplicationDocumentsDirectory();
    _cacheDir = p.join(dir.path, 'recording_cache');
    await Directory(_cacheDir!).create(recursive: true);
    return _cacheDir!;
  }

  /// Path for a cached recording file.
  Future<String> cachePath(String productionId, String lineId) async {
    final dir = await cacheDir;
    final prodDir = p.join(dir, productionId);
    await Directory(prodDir).create(recursive: true);
    return p.join(prodDir, '$lineId.m4a');
  }

  /// Get the local path for a cached recording, or null if not cached.
  String? getCachedPath(String lineId) {
    return _cache[lineId]?.localPath;
  }

  // ── Full Sync ──────────────────────────────────────────

  /// Sync all recordings for a production.
  /// 1. Upload any local recordings missing from cloud
  /// 2. Download any cloud recordings missing locally
  /// Returns the number of recordings downloaded.
  Future<int> syncForProduction({
    required String productionId,
    required Map<String, Recording> localRecordings,
    String? myUserId,
  }) async {
    final supa = SupabaseService.instance;
    if (!supa.isInitialized || !supa.isSignedIn) return 0;

    _dlog.log(LogCategory.general,
        'RecordingSync: starting for $productionId (${localRecordings.length} local)');

    // Fetch all cloud recording metadata for this production
    List<Map<String, dynamic>> cloudRecordings;
    try {
      cloudRecordings = await supa.fetchRecordings(productionId);
    } catch (e) {
      _dlog.logError(LogCategory.error, 'RecordingSync: fetch failed', e);
      return 0;
    }

    _dlog.log(LogCategory.general,
        'RecordingSync: ${cloudRecordings.length} recordings in cloud');

    // Build lookup: lineId → cloud metadata
    final cloudByLine = <String, Map<String, dynamic>>{};
    for (final row in cloudRecordings) {
      final lineId = row['line_id'] as String?;
      if (lineId == null) continue;
      // Keep the most recent recording per line
      final existing = cloudByLine[lineId];
      if (existing == null ||
          _parseTimestamp(row['recorded_at']) >
              _parseTimestamp(existing['recorded_at'])) {
        cloudByLine[lineId] = row;
      }
    }

    // ── Upload local recordings not in cloud ──
    final userId = myUserId ?? supa.currentUser?.id;
    int uploaded = 0;
    for (final entry in localRecordings.entries) {
      final lineId = entry.key;
      final recording = entry.value;

      // Skip if already uploaded (has remoteUrl)
      if (recording.remoteUrl != null && recording.remoteUrl!.isNotEmpty) {
        continue;
      }

      // Skip if file doesn't exist
      if (!File(recording.localPath).existsSync()) continue;

      try {
        final url = await supa.uploadRecording(
          productionId: productionId,
          characterName: recording.character,
          lineId: lineId,
          audioFile: File(recording.localPath),
        );

        await supa.saveRecordingMetadata(
          productionId: productionId,
          lineId: lineId,
          userId: userId ?? 'local',
          audioUrl: url,
          durationMs: recording.durationMs,
        );

        uploaded++;
        _dlog.log(LogCategory.general,
            'RecordingSync: uploaded $lineId (${recording.character})');
      } catch (e) {
        _dlog.logError(
            LogCategory.error, 'RecordingSync: upload failed for $lineId', e);
      }
    }

    if (uploaded > 0) {
      _dlog.log(LogCategory.general,
          'RecordingSync: uploaded $uploaded local recordings');
    }

    // ── Download cloud recordings not cached locally ──
    int downloaded = 0;
    for (final entry in cloudByLine.entries) {
      final lineId = entry.key;
      final cloud = entry.value;
      final cloudUserId = cloud['user_id'] as String?;

      // Skip our own recordings — we already have them locally
      if (cloudUserId == userId) continue;

      // Skip if we already have a local recording for this line
      if (localRecordings.containsKey(lineId)) continue;

      final cloudTimestamp = _parseTimestamp(cloud['recorded_at']);
      final cached = _cache[lineId];

      // Skip if cached version is up to date
      if (cached != null && cached.recordedAt >= cloudTimestamp) continue;

      // Download the recording
      try {
        // We need character name for the storage path
        // Extract from audio_url or query — the URL contains the path
        final audioUrl = cloud['audio_url'] as String? ?? '';
        final characterName =
            _extractCharacterFromUrl(audioUrl, productionId);

        final bytes = await supa.downloadRecording(
          productionId: productionId,
          characterName: characterName,
          lineId: lineId,
        );

        final path = await cachePath(productionId, lineId);
        await File(path).writeAsBytes(bytes);

        _cache[lineId] = _CachedRecording(
          lineId: lineId,
          userId: cloudUserId ?? '',
          localPath: path,
          recordedAt: cloudTimestamp,
          durationMs: cloud['duration_ms'] as int? ?? 0,
          character: characterName,
        );

        downloaded++;
        onRecordingReady?.call(lineId, path);

        _dlog.log(LogCategory.general,
            'RecordingSync: downloaded $lineId ($characterName)');
      } catch (e) {
        _dlog.logError(
            LogCategory.error, 'RecordingSync: download failed for $lineId', e);
      }
    }

    _dlog.log(LogCategory.general,
        'RecordingSync: done — $uploaded uploaded, $downloaded downloaded');

    return downloaded;
  }

  // ── Build Recording Map from Cache ──────────────────────

  /// Get all cached recordings as a Map<lineId, Recording> for use
  /// with the recordingsProvider or understudyRecordingsProvider.
  Map<String, Recording> getCachedRecordings() {
    final result = <String, Recording>{};
    for (final entry in _cache.entries) {
      final cached = entry.value;
      if (File(cached.localPath).existsSync()) {
        result[entry.key] = Recording(
          id: 'cache_${entry.key}',
          scriptLineId: entry.key,
          character: cached.character,
          localPath: cached.localPath,
          remoteUrl: null,
          durationMs: cached.durationMs,
          recordedAt: DateTime.fromMillisecondsSinceEpoch(
              cached.recordedAt.clamp(0, 1 << 52)),
        );
      }
    }
    return result;
  }

  // ── Real-time Subscription ──────────────────────────────

  /// Subscribe to new recordings for a production.
  /// Downloads them as they arrive.
  void subscribe({
    required String productionId,
    String? myUserId,
  }) {
    _realtimeSub?.cancel();

    final supa = SupabaseService.instance;
    if (!supa.isInitialized || !supa.isSignedIn) return;

    try {
      supa.subscribeToRecordings(
        productionId: productionId,
        onNewRecording: (payload) async {
          final lineId = payload['line_id'] as String?;
          final recordUserId = payload['user_id'] as String?;
          if (lineId == null) return;

          // Skip our own recordings
          if (recordUserId == (myUserId ?? supa.currentUser?.id)) return;

          final audioUrl = payload['audio_url'] as String? ?? '';
          final characterName =
              _extractCharacterFromUrl(audioUrl, productionId);

          _dlog.log(LogCategory.general,
              'RecordingSync: realtime — new recording for $lineId ($characterName)');

          try {
            final bytes = await supa.downloadRecording(
              productionId: productionId,
              characterName: characterName,
              lineId: lineId,
            );

            final path = await cachePath(productionId, lineId);
            await File(path).writeAsBytes(bytes);

            _cache[lineId] = _CachedRecording(
              lineId: lineId,
              userId: recordUserId ?? '',
              localPath: path,
              recordedAt: _parseTimestamp(payload['recorded_at']),
              durationMs: payload['duration_ms'] as int? ?? 0,
              character: characterName,
            );

            onRecordingReady?.call(lineId, path);
          } catch (e) {
            _dlog.logError(LogCategory.error,
                'RecordingSync: realtime download failed for $lineId', e);
          }
        },
      );

      _dlog.log(
          LogCategory.general, 'RecordingSync: subscribed to $productionId');
    } catch (e) {
      _dlog.logError(
          LogCategory.error, 'RecordingSync: subscribe failed', e);
    }
  }

  /// Unsubscribe from real-time updates.
  void unsubscribe() {
    _realtimeSub?.cancel();
    _realtimeSub = null;
  }

  // ── Cleanup ──────────────────────────────────────────────

  /// Clear the cache for a production.
  Future<void> clearCache(String productionId) async {
    final dir = p.join(await cacheDir, productionId);
    final prodDir = Directory(dir);
    if (await prodDir.exists()) {
      await prodDir.delete(recursive: true);
    }
    _cache.removeWhere((_, v) => v.localPath.contains(productionId));
  }

  /// Clear all cached recordings.
  Future<void> clearAllCaches() async {
    final dir = await cacheDir;
    final cacheDirectory = Directory(dir);
    if (await cacheDirectory.exists()) {
      await cacheDirectory.delete(recursive: true);
      await cacheDirectory.create(recursive: true);
    }
    _cache.clear();
  }

  // ── Helpers ──────────────────────────────────────────────

  /// Parse a timestamp string or int to milliseconds since epoch.
  static int _parseTimestamp(dynamic ts) {
    if (ts == null) return 0;
    if (ts is int) return ts;
    if (ts is String) {
      final dt = DateTime.tryParse(ts);
      return dt?.millisecondsSinceEpoch ?? 0;
    }
    return 0;
  }

  /// Extract character name from a Supabase Storage URL.
  /// URL format: .../recordings/{productionId}/{characterName}/{lineId}.m4a
  static String _extractCharacterFromUrl(String url, String productionId) {
    try {
      final uri = Uri.parse(url);
      final segments = uri.pathSegments;
      // Find the segment after the production ID
      for (var i = 0; i < segments.length - 1; i++) {
        if (segments[i] == productionId && i + 1 < segments.length) {
          return segments[i + 1];
        }
      }
    } catch (_) {}
    return 'unknown';
  }
}

class _CachedRecording {
  final String lineId;
  final String userId;
  final String localPath;
  final int recordedAt; // millis since epoch
  final int durationMs;
  final String character;

  _CachedRecording({
    required this.lineId,
    required this.userId,
    required this.localPath,
    required this.recordedAt,
    required this.durationMs,
    required this.character,
  });
}
