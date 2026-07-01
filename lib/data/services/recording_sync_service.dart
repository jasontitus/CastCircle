import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel;

import '../models/script_models.dart';
import 'debug_log_service.dart';
import 'supabase_service.dart';

/// Abstraction over the cloud calls used by [RecordingSyncService] so the
/// sync logic can be tested without a live Supabase backend.
abstract class RecordingCloud {
  /// Whether cloud calls can proceed (initialized and signed in).
  bool get isReady;

  /// The signed-in user's id, if any.
  String? get currentUserId;

  Future<List<Map<String, dynamic>>> fetchRecordings(String productionId);

  Future<String> uploadRecording({
    required String productionId,
    required String characterName,
    required String lineId,
    required File audioFile,
  });

  Future<void> saveRecordingMetadata({
    required String productionId,
    required String lineId,
    required String userId,
    required String audioUrl,
    required int durationMs,
    DateTime? recordedAt,
  });

  Future<Uint8List> downloadRecordingByUrl(String audioUrl);
}

class _SupabaseRecordingCloud implements RecordingCloud {
  SupabaseService get _supa => SupabaseService.instance;

  @override
  bool get isReady => _supa.isInitialized && _supa.isSignedIn;

  @override
  String? get currentUserId => _supa.currentUser?.id;

  @override
  Future<List<Map<String, dynamic>>> fetchRecordings(String productionId) =>
      _supa.fetchRecordings(productionId);

  @override
  Future<String> uploadRecording({
    required String productionId,
    required String characterName,
    required String lineId,
    required File audioFile,
  }) =>
      _supa.uploadRecording(
        productionId: productionId,
        characterName: characterName,
        lineId: lineId,
        audioFile: audioFile,
      );

  @override
  Future<void> saveRecordingMetadata({
    required String productionId,
    required String lineId,
    required String userId,
    required String audioUrl,
    required int durationMs,
    DateTime? recordedAt,
  }) =>
      _supa.saveRecordingMetadata(
        productionId: productionId,
        lineId: lineId,
        userId: userId,
        audioUrl: audioUrl,
        durationMs: durationMs,
        recordedAt: recordedAt,
      );

  @override
  Future<Uint8List> downloadRecordingByUrl(String audioUrl) =>
      _supa.downloadRecordingByUrl(audioUrl);
}

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
  RecordingSyncService._() : _cloud = _SupabaseRecordingCloud();

  @visibleForTesting
  RecordingSyncService.forTesting(this._cloud, {String? cacheDirectory})
      : _cacheDir = cacheDirectory;

  static final instance = RecordingSyncService._();

  final RecordingCloud _cloud;
  final _dlog = DebugLogService.instance;

  /// Cache dir for downloaded recordings: Documents/recording_cache/
  String? _cacheDir;

  /// Metadata for cached recordings: lineId → {recordedAt, userId, path}
  final Map<String, _CachedRecording> _cache = {};

  /// Active realtime channel (null when not subscribed).
  RealtimeChannel? _realtimeChannel;

  /// Callback when a new recording is downloaded and ready
  void Function(String lineId, String localPath)? onRecordingReady;

  /// Callback when a local recording was uploaded during [syncForProduction]
  /// with (lineId, remoteUrl) — used to persist the remote URL locally.
  void Function(String lineId, String remoteUrl)? onLocalUploaded;

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
  /// 1. Upload any local recordings that are missing from the cloud or
  ///    newer than the cloud copy (e.g. re-records, or uploads lost when
  ///    the app was killed before the in-memory queue drained)
  /// 2. Download any cloud recordings missing locally
  /// Returns the number of recordings downloaded.
  Future<int> syncForProduction({
    required String productionId,
    required Map<String, Recording> localRecordings,
    String? myUserId,
  }) async {
    if (!_cloud.isReady) return 0;

    _dlog.log(LogCategory.general,
        'RecordingSync: starting for $productionId (${localRecordings.length} local)');

    // Fetch all cloud recording metadata for this production
    List<Map<String, dynamic>> cloudRecordings;
    try {
      cloudRecordings = await _cloud.fetchRecordings(productionId);
    } catch (e) {
      _dlog.logError(LogCategory.error, 'RecordingSync: fetch failed', e);
      return 0;
    }

    _dlog.log(LogCategory.general,
        'RecordingSync: ${cloudRecordings.length} recordings in cloud');

    final userId = myUserId ?? _cloud.currentUserId;

    // Build lookups: newest cloud row per line from ANY user (drives
    // downloads), and newest per line from ME (drives the upload decision —
    // cloud rows are keyed (production, line, user), so a castmate's newer
    // take for the same line must not suppress uploading mine).
    final cloudByLine = <String, Map<String, dynamic>>{};
    final myCloudByLine = <String, Map<String, dynamic>>{};
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
      if (userId != null && row['user_id'] == userId) {
        final mine = myCloudByLine[lineId];
        if (mine == null ||
            _parseTimestamp(row['recorded_at']) >
                _parseTimestamp(mine['recorded_at'])) {
          myCloudByLine[lineId] = row;
        }
      }
    }

    // ── Upload local recordings that are missing or newer in cloud ──
    final toUpload = <MapEntry<String, Recording>>[];
    for (final entry in localRecordings.entries) {
      final recording = entry.value;

      // Skip if already uploaded (has remoteUrl)
      if (recording.remoteUrl != null && recording.remoteUrl!.isNotEmpty) {
        continue;
      }

      // Skip if the cloud already has MY take for this line and it's at least
      // as new as the local one. (A strictly newer local take — a re-record —
      // must still be uploaded. Another user's newer take doesn't count: my
      // row coexists with theirs.)
      final cloud = myCloudByLine[entry.key];
      if (cloud != null &&
          _parseTimestamp(cloud['recorded_at']) >=
              recording.recordedAt.millisecondsSinceEpoch) {
        continue;
      }

      // Skip if file doesn't exist
      if (!File(recording.localPath).existsSync()) continue;

      toUpload.add(entry);
    }

    int uploaded = 0;
    await _runPooled(toUpload, (entry) async {
      final lineId = entry.key;
      final recording = entry.value;
      try {
        final url = await _cloud.uploadRecording(
          productionId: productionId,
          characterName: recording.character,
          lineId: lineId,
          audioFile: File(recording.localPath),
        );

        await _cloud.saveRecordingMetadata(
          productionId: productionId,
          lineId: lineId,
          userId: userId ?? 'local',
          audioUrl: url,
          durationMs: recording.durationMs,
          recordedAt: recording.recordedAt,
        );

        uploaded++;
        onLocalUploaded?.call(lineId, url);
        _dlog.log(LogCategory.general,
            'RecordingSync: uploaded $lineId (${recording.character})');
      } catch (e) {
        _dlog.logError(
            LogCategory.error, 'RecordingSync: upload failed for $lineId', e);
      }
    });

    if (uploaded > 0) {
      _dlog.log(LogCategory.general,
          'RecordingSync: uploaded $uploaded local recordings');
    }

    // ── Download cloud recordings not cached locally ──
    final toDownload = <MapEntry<String, Map<String, dynamic>>>[];
    for (final entry in cloudByLine.entries) {
      final lineId = entry.key;
      final cloud = entry.value;

      // Skip if we already have a local recording for this line
      // (regardless of who recorded it — handles multi-device for same user)
      if (localRecordings.containsKey(lineId)) {
        final local = localRecordings[lineId]!;
        // But if the local file doesn't exist (e.g. different device),
        // still download it
        if (File(local.localPath).existsSync()) continue;
      }

      final cloudTimestamp = _parseTimestamp(cloud['recorded_at']);
      final cached = _cache[lineId];

      // Skip if cached version is up to date (and the file still exists)
      if (cached != null &&
          cached.recordedAt >= cloudTimestamp &&
          File(cached.localPath).existsSync()) {
        continue;
      }

      toDownload.add(entry);
    }

    int downloaded = 0;
    await _runPooled(toDownload, (entry) async {
      final lineId = entry.key;
      final cloud = entry.value;
      final cloudUserId = cloud['user_id'] as String?;
      final cloudTimestamp = _parseTimestamp(cloud['recorded_at']);

      // Download the recording by its stored URL (resolves the exact object).
      try {
        final audioUrl = cloud['audio_url'] as String? ?? '';
        final characterName =
            _extractCharacterFromUrl(audioUrl, productionId); // for display only

        final bytes = await _cloud.downloadRecordingByUrl(audioUrl);

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
    });

    _dlog.log(LogCategory.general,
        'RecordingSync: done — $uploaded uploaded, $downloaded downloaded');

    return downloaded;
  }

  /// Run [task] over [items] with a few concurrent workers instead of one at
  /// a time. A full first sync of a production is hundreds of small transfers;
  /// serially that's minutes of round-trip latency, pooled it's ~4-6× faster.
  /// Errors are handled inside [task] (each transfer logs its own failure).
  static Future<void> _runPooled<T>(
    List<T> items,
    Future<void> Function(T item) task, {
    int concurrency = 4,
  }) async {
    if (items.isEmpty) return;
    var next = 0;
    final workers = List.generate(concurrency.clamp(1, items.length), (_) async {
      while (true) {
        final i = next++; // safe: single isolate, no await between read+bump
        if (i >= items.length) break;
        await task(items[i]);
      }
    });
    await Future.wait(workers);
  }

  // ── Build Recording Map from Cache ──────────────────────

  /// Get a single cached recording as a [Recording], or null if not cached.
  /// Much cheaper than [getCachedRecordings] when one file just arrived —
  /// during a big sync the full-map version stats every cache entry per
  /// downloaded file.
  Recording? getCachedRecording(String lineId) {
    final cached = _cache[lineId];
    if (cached == null) return null;
    return Recording(
      id: 'cache_$lineId',
      scriptLineId: lineId,
      character: cached.character,
      localPath: cached.localPath,
      remoteUrl: null,
      durationMs: cached.durationMs,
      recordedAt: DateTime.fromMillisecondsSinceEpoch(
          cached.recordedAt.clamp(0, 1 << 52)),
    );
  }

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
    unsubscribe();

    final supa = SupabaseService.instance;
    if (!supa.isInitialized || !supa.isSignedIn) return;

    try {
      _realtimeChannel = supa.subscribeToRecordings(
        productionId: productionId,
        onNewRecording: (payload) => handleRealtimeRecording(
          payload,
          productionId: productionId,
          myUserId: myUserId,
        ),
      );

      _dlog.log(
          LogCategory.general, 'RecordingSync: subscribed to $productionId');
    } catch (e) {
      _dlog.logError(
          LogCategory.error, 'RecordingSync: subscribe failed', e);
    }
  }

  /// Handle a realtime "new recording" payload: download the audio and add
  /// it to the cache. Exposed for tests.
  @visibleForTesting
  Future<void> handleRealtimeRecording(
    Map<String, dynamic> payload, {
    required String productionId,
    String? myUserId,
  }) async {
    final lineId = payload['line_id'] as String?;
    final recordUserId = payload['user_id'] as String?;
    if (lineId == null) return;

    // Skip our own recordings
    if (recordUserId == (myUserId ?? _cloud.currentUserId)) return;

    final audioUrl = payload['audio_url'] as String? ?? '';
    final characterName =
        _extractCharacterFromUrl(audioUrl, productionId); // for display only

    _dlog.log(LogCategory.general,
        'RecordingSync: realtime — new recording for $lineId ($characterName)');

    try {
      final bytes = await _cloud.downloadRecordingByUrl(audioUrl);

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
  }

  /// Unsubscribe from real-time updates.
  void unsubscribe() {
    final channel = _realtimeChannel;
    _realtimeChannel = null;
    if (channel != null) {
      try {
        SupabaseService.instance.unsubscribe(channel);
      } catch (e) {
        _dlog.logError(
            LogCategory.error, 'RecordingSync: unsubscribe failed', e);
      }
    }
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
  @visibleForTesting
  static String extractCharacterFromUrl(String url, String productionId) =>
      _extractCharacterFromUrl(url, productionId);

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
