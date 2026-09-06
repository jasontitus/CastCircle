import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show SnackBar, Text;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel;

import '../../main.dart' show rootScaffoldMessengerKey;
import '../models/script_models.dart';
import 'debug_log_service.dart';
import 'supabase_service.dart';
import '../../core/toast.dart';

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

  Future<String?> saveRecordingMetadata({
    required String productionId,
    required String lineId,
    required String audioUrl,
    required int durationMs,
    DateTime? recordedAt,
  });

  Future<void> deleteRecordingByUrl(String audioUrl);

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
  }) => _supa.uploadRecording(
    productionId: productionId,
    characterName: characterName,
    lineId: lineId,
    audioFile: audioFile,
  );

  @override
  Future<String?> saveRecordingMetadata({
    required String productionId,
    required String lineId,
    required String audioUrl,
    required int durationMs,
    DateTime? recordedAt,
  }) => _supa.saveRecordingMetadata(
    productionId: productionId,
    lineId: lineId,
    audioUrl: audioUrl,
    durationMs: durationMs,
    recordedAt: recordedAt,
  );

  @override
  Future<void> deleteRecordingByUrl(String audioUrl) =>
      _supa.deleteRecordingByUrl(audioUrl);

  @override
  Future<Uint8List> downloadRecordingByUrl(String audioUrl) =>
      _supa.downloadRecordingByUrl(audioUrl);
}

typedef RecordingReadyCallback =
    void Function(String productionId, String lineId, String localPath);
typedef RecordingEvictedCallback =
    void Function(String productionId, String lineId);
typedef LocalRecordingUploadedCallback =
    Future<void> Function(
      String productionId,
      String lineId,
      String recordingId,
      String remoteUrl,
    );

/// Syncs recordings between local device and Supabase cloud.
///
/// Handles:
/// - Uploading local recordings that haven't been pushed to cloud
/// - Downloading other cast members' recordings for rehearsal playback
/// - Caching downloaded recordings with timestamp-based invalidation
/// - Real-time subscription for new recordings as they arrive
///
/// Cached recordings use `(productionId, lineId)` identity so stable line UUIDs
/// can be reused safely when a script is copied into another production.
class RecordingSyncService {
  RecordingSyncService._()
    : _cloud = _SupabaseRecordingCloud(),
      _cacheDirectoryOverridden = false;

  @visibleForTesting
  RecordingSyncService.forTesting(this._cloud, {String? cacheDirectory})
    : _cacheDir = cacheDirectory,
      _cacheDirectoryOverridden = cacheDirectory != null;

  static final instance = RecordingSyncService._();

  final RecordingCloud _cloud;
  final bool _cacheDirectoryOverridden;
  final _dlog = DebugLogService.instance;
  int _generation = 0;
  int _productionGeneration = 0;
  String? _activeProductionId;

  int activateProduction(String productionId) {
    _activeProductionId = productionId;
    return ++_productionGeneration;
  }

  int deactivateProduction() {
    _activeProductionId = null;
    return ++_productionGeneration;
  }

  bool _isRunCurrent(
    String productionId,
    int runToken,
    int accountGeneration,
  ) =>
      accountGeneration == _generation &&
      runToken == _productionGeneration &&
      productionId == _activeProductionId;

  bool isProductionRunCurrent(String productionId, int runToken) =>
      _isRunCurrent(productionId, runToken, _generation);

  /// Cache dir for downloaded recordings: Documents/recording_cache/
  String? _cacheDir;

  /// Metadata for cached recordings, keyed by (productionId, lineId).
  final Map<String, _CachedRecording> _cache = {};

  static String _cacheKey(String productionId, String lineId) =>
      '$productionId\u0000$lineId';

  final Map<String, Future<void>> _downloadChains = {};

  Future<void> _serializeDownload(String key, Future<void> Function() action) {
    final previous = _downloadChains[key] ?? Future.value();
    late final Future<void> next;
    next = previous
        .catchError((Object _) {})
        .then((_) => action())
        .whenComplete(() {
          if (identical(_downloadChains[key], next)) {
            _downloadChains.remove(key);
          }
        });
    _downloadChains[key] = next;
    return next;
  }

  final Map<String, _UploadCheckpoint> _uploadCheckpoints = {};
  bool _checkpointsLoaded = false;
  Future<void>? _checkpointChain;

  Future<String> _checkpointPath() async {
    if (_cacheDirectoryOverridden) {
      return p.join(_cacheDir!, 'upload_checkpoints.json');
    }
    final support = await getApplicationSupportDirectory();
    return p.join(support.path, 'recording_upload_checkpoints.json');
  }

  static String _checkpointKey(
    String accountNamespace,
    String productionId,
    String lineId,
  ) => '$accountNamespace\u0000$productionId\u0000$lineId';

  Future<void> _loadUploadCheckpoints() async {
    if (_checkpointsLoaded) return;
    _checkpointsLoaded = true;
    final accountGeneration = _generation;
    try {
      final file = File(await _checkpointPath());
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString());
      if (accountGeneration != _generation) return;
      if (data is! List) return;
      for (final entry in data.whereType<Map>()) {
        final checkpoint = _UploadCheckpoint.fromJson(
          Map<String, dynamic>.from(entry),
        );
        if (checkpoint == null) continue;
        if (accountGeneration != _generation) return;
        _uploadCheckpoints[_checkpointKey(
              checkpoint.accountNamespace,
              checkpoint.productionId,
              checkpoint.lineId,
            )] =
            checkpoint;
      }
    } catch (e) {
      _dlog.logError(
        LogCategory.error,
        'RecordingSync: upload checkpoint restore failed',
        e,
      );
    }
  }

  Future<void> _saveUploadCheckpoints() {
    final next = (_checkpointChain ?? Future.value())
        .catchError((Object _) {})
        .then((_) async {
          final snapshot = jsonEncode(
            _uploadCheckpoints.values.map((c) => c.toJson()).toList(),
          );
          final path = await _checkpointPath();
          final temp = File('$path.incoming');
          try {
            await temp.writeAsString(snapshot, flush: true);
            await temp.rename(path);
          } catch (e) {
            try {
              if (await temp.exists()) await temp.delete();
            } catch (_) {}
            _dlog.logError(
              LogCategory.error,
              'RecordingSync: upload checkpoint save failed',
              e,
            );
            rethrow;
          }
        });
    _checkpointChain = next;
    return next;
  }

  // The cache index used to be memory-only: after an app restart the
  // downloaded files were still on disk but invisible — offline rehearsal
  // fell back to TTS, and online every file was re-downloaded. A manifest
  // JSON beside the cache persists the index across launches.
  bool _hydrated = false;
  Future<void>? _manifestChain;

  Future<String> _manifestPath() async =>
      p.join(await cacheDir, 'manifest.json');

  /// Test hook: wait for in-flight manifest writes.
  @visibleForTesting
  Future<void> flushManifest() async =>
      await (_manifestChain ?? Future.value());

  /// Restore the cache index from the manifest (once per launch). Entries
  /// whose file no longer exists are dropped; entries already in memory
  /// (downloaded this session) win over the manifest.
  Future<void> hydrateCache() => _hydration ??= _doHydrate();
  Future<void>? _hydration;

  Future<void> _doHydrate() async {
    if (_hydrated) return;
    _hydrated = true;
    final accountGeneration = _generation;
    try {
      final file = File(await _manifestPath());
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString());
      if (accountGeneration != _generation) return;
      if (data is! List) return;
      var restored = 0;
      for (final entry in data.whereType<Map>()) {
        final cached = _CachedRecording.fromJson(
          Map<String, dynamic>.from(entry),
        );
        if (cached == null || cached.productionId.isEmpty) continue;
        final key = _cacheKey(cached.productionId, cached.lineId);
        if (_cache.containsKey(key)) continue;
        if (!await File(cached.localPath).exists()) continue;
        if (accountGeneration != _generation) return;
        _cache[key] = cached;
        restored++;
      }
      if (accountGeneration != _generation) return;
      final pruned = await _pruneCache();
      if (pruned) _saveManifest();
      if (restored > 0) {
        _dlog.log(
          LogCategory.general,
          'RecordingSync: restored $restored cached recording(s) from disk',
        );
      }
    } catch (e) {
      _dlog.logError(
        LogCategory.error,
        'RecordingSync: cache manifest restore failed',
        e,
      );
    }
  }

  /// Debounced variant for the REALTIME path: the manifest re-encodes the
  /// ENTIRE global cache, and each castmate-recording arrival used to
  /// trigger a full O(all cached recordings) encode + rewrite. Coalescing a
  /// burst into one write loses at most 2 s of index on a crash (the audio
  /// files themselves are already on disk). End-of-sync callers keep the
  /// immediate [_saveManifest] — one write per sync, and deterministic for
  /// tests that read the manifest right after.
  Timer? _manifestDebounce;
  void _saveManifestDebounced() {
    _manifestDebounce?.cancel();
    _manifestDebounce = Timer(const Duration(seconds: 2), _saveManifest);
  }

  /// Persist the cache index. Writes are chained (downloads run 4-way
  /// concurrent) and the content is snapshotted at write time.
  void _saveManifest() {
    _manifestChain = (_manifestChain ?? Future.value()).then((_) async {
      try {
        final snapshot = jsonEncode(
          _cache.values.map((c) => c.toJson()).toList(),
        );
        await File(await _manifestPath()).writeAsString(snapshot);
      } catch (e) {
        _dlog.logError(
          LogCategory.error,
          'RecordingSync: cache manifest save failed',
          e,
        );
      }
    });
  }

  /// Active realtime channel (null when not subscribed).
  RealtimeChannel? _realtimeChannel;

  /// Active callbacks are captured by each production run, never stored on
  /// this process-global service.

  /// Get or create the cache directory.
  Future<String> get cacheDir async {
    if (_cacheDir != null) return _cacheDir!;
    final dir = await getApplicationDocumentsDirectory();
    _cacheDir = p.join(dir.path, 'recording_cache');
    await Directory(_cacheDir!).create(recursive: true);
    return _cacheDir!;
  }

  /// Identifiers that are safe to interpolate into a filesystem path.
  /// production_id is a DB-enforced uuid, but recordings.line_id is free TEXT,
  /// so a hostile row could carry "../../…" (or an absolute path, which
  /// p.join happily adopts) and steer a download on every castmate's device
  /// into overwriting arbitrary .m4a files — including their own saved takes.
  static final _safeIdPattern = RegExp(r'^[A-Za-z0-9._-]{1,128}$');

  static bool isSafePathId(String value) =>
      _safeIdPattern.hasMatch(value) && !value.contains('..');

  /// Path for a cached recording file. Throws on an unsafe id rather than
  /// writing outside the cache directory.
  Future<String> cachePath(String productionId, String lineId) async {
    if (!isSafePathId(productionId) || !isSafePathId(lineId)) {
      throw ArgumentError(
        'Unsafe recording identifiers (production=$productionId, line=$lineId)',
      );
    }
    final dir = await cacheDir;
    final prodDir = p.join(dir, productionId);
    await Directory(prodDir).create(recursive: true);
    final path = p.join(prodDir, '$lineId.m4a');
    // Belt and braces: never escape the cache root.
    if (!p.isWithin(dir, path)) {
      throw ArgumentError('Recording path escapes the cache directory: $path');
    }
    return path;
  }

  /// Get the local path for a cached recording, or null if not cached.
  String? getCachedPath(String productionId, String lineId) {
    final cached = _cache[_cacheKey(productionId, lineId)];
    if (cached == null) return null;
    cached.lastAccessedAt = DateTime.now().millisecondsSinceEpoch;
    _saveManifestDebounced();
    return cached.localPath;
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
    required int runToken,
    required Map<String, Recording> localRecordings,
    String? myUserId,
    RecordingReadyCallback? onRecordingReady,
    RecordingEvictedCallback? onRecordingEvicted,
    LocalRecordingUploadedCallback? onLocalUploaded,
  }) async {
    final generation = _generation;
    bool isCurrent() => _isRunCurrent(productionId, runToken, generation);
    await hydrateCache();
    await _loadUploadCheckpoints();
    if (!isCurrent() || !_cloud.isReady) return 0;
    final userId = myUserId ?? _cloud.currentUserId;
    if (userId == null) {
      _dlog.log(
        LogCategory.network,
        'RecordingSync: skipped $productionId — signed-in user disappeared',
      );
      return 0;
    }

    _dlog.log(
      LogCategory.general,
      'RecordingSync: starting for $productionId (${localRecordings.length} local)',
    );
    List<Map<String, dynamic>> cloudRecordings;
    try {
      cloudRecordings = await _cloud.fetchRecordings(productionId);
      if (!isCurrent()) return 0;
    } catch (e) {
      _dlog.logError(LogCategory.error, 'RecordingSync: fetch failed', e);
      _tellUser(
        "Couldn't check for castmates' recordings — rehearsal will "
        'use computer voices for their lines. Check your connection.',
      );
      return 0;
    }

    final partnerCloudByLine = <String, Map<String, dynamic>>{};
    final myCloudByLine = <String, Map<String, dynamic>>{};
    for (final row in cloudRecordings) {
      final lineId = row['line_id'];
      if (lineId is! String) continue;
      if (!isSafePathId(lineId)) {
        _dlog.logError(
          LogCategory.error,
          'RecordingSync: ignoring cloud recording with unsafe line_id "$lineId"',
        );
        continue;
      }
      final target = row['user_id'] == userId
          ? myCloudByLine
          : partnerCloudByLine;
      final existing = target[lineId];
      if (existing == null ||
          _parseTimestamp(row['recorded_at']) >
              _parseTimestamp(existing['recorded_at'])) {
        target[lineId] = row;
      }
    }

    var uploaded = 0;
    var uploadFailures = 0;
    final toUpload = <MapEntry<String, Recording>>[];
    for (final entry in localRecordings.entries) {
      final recording = entry.value;
      final cloud = myCloudByLine[entry.key];
      final cloudUrl = cloud?['audio_url'];
      final cloudIsCurrent =
          cloudUrl is String &&
          cloudUrl.isNotEmpty &&
          _parseTimestamp(cloud?['recorded_at']) >=
              recording.recordedAt.millisecondsSinceEpoch;
      if (cloudIsCurrent) {
        final checkpointKey = _checkpointKey(userId, productionId, entry.key);
        final checkpoint = _uploadCheckpoints[checkpointKey];
        if (checkpoint != null) {
          final cleanupUrls = <String>{
            ...checkpoint.deferredCleanupUrls,
            if (checkpoint.cleanupUrl != null) checkpoint.cleanupUrl!,
          }.toList();
          for (final cleanupUrl in cleanupUrls) {
            try {
              await _cloud.deleteRecordingByUrl(cleanupUrl);
              checkpoint.deferredCleanupUrls.remove(cleanupUrl);
              if (checkpoint.cleanupUrl == cleanupUrl) {
                checkpoint.cleanupUrl = null;
              }
              await _saveUploadCheckpoints();
            } catch (e) {
              _dlog.logError(
                LogCategory.error,
                'RecordingSync: superseded object cleanup retry failed for ${entry.key}',
                e,
              );
              break;
            }
          }
        }
        if (recording.remoteUrl != cloudUrl && onLocalUploaded != null) {
          try {
            await onLocalUploaded(
              productionId,
              entry.key,
              recording.id,
              cloudUrl,
            );
            if (!isCurrent()) return 0;
          } catch (e) {
            _dlog.logError(
              LogCategory.error,
              'RecordingSync: local upload marker repair failed for ${entry.key}',
              e,
            );
          }
        }
        if (checkpoint != null &&
            checkpoint.cleanupUrl == null &&
            checkpoint.deferredCleanupUrls.isEmpty) {
          _uploadCheckpoints.remove(checkpointKey);
          await _saveUploadCheckpoints();
          if (!isCurrent()) return 0;
        }
        continue;
      }

      // remoteUrl is only a hint. A missing/older cloud row must be reconciled.
      final localFileExists = await File(recording.localPath).exists();
      if (!isCurrent()) return 0;
      if (!localFileExists) continue;
      toUpload.add(entry);
    }

    await _runPooled(toUpload, (entry) async {
      final lineId = entry.key;
      final recording = entry.value;
      final checkpointKey = _checkpointKey(userId, productionId, lineId);
      try {
        var checkpoint = _uploadCheckpoints[checkpointKey];
        final deferredCleanupUrls = <String>[];
        if (checkpoint != null &&
            checkpoint.recordedAt !=
                recording.recordedAt.millisecondsSinceEpoch) {
          deferredCleanupUrls
            ..addAll(checkpoint.deferredCleanupUrls)
            ..add(checkpoint.remoteUrl);
          if (checkpoint.cleanupUrl != null) {
            deferredCleanupUrls.add(checkpoint.cleanupUrl!);
          }
          _uploadCheckpoints.remove(checkpointKey);
          checkpoint = null;
        }

        if (checkpoint == null) {
          final url = await _cloud.uploadRecording(
            productionId: productionId,
            characterName: recording.character,
            lineId: lineId,
            audioFile: File(recording.localPath),
          );
          if (!isCurrent()) {
            try {
              await _cloud.deleteRecordingByUrl(url);
            } catch (e) {
              _dlog.logError(
                LogCategory.error,
                'RecordingSync: stale unreferenced upload cleanup failed',
                e,
              );
            }
            return;
          }
          checkpoint = _UploadCheckpoint(
            accountNamespace: userId,
            productionId: productionId,
            lineId: lineId,
            remoteUrl: url,
            recordedAt: recording.recordedAt.millisecondsSinceEpoch,
            deferredCleanupUrls: deferredCleanupUrls.toSet().toList(),
          );
          _uploadCheckpoints[checkpointKey] = checkpoint;
          // The object URL must reach disk before metadata publication begins.
          await _saveUploadCheckpoints();
        }

        if (!isCurrent()) return;
        if (!checkpoint.metadataSaved) {
          checkpoint.cleanupUrl = await _cloud.saveRecordingMetadata(
            productionId: productionId,
            lineId: lineId,
            audioUrl: checkpoint.remoteUrl,
            durationMs: recording.durationMs,
            recordedAt: recording.recordedAt,
          );
          checkpoint.metadataSaved = true;
          await _saveUploadCheckpoints();
        }
        if (!isCurrent()) return;
        final cleanupUrls = <String>{
          ...checkpoint.deferredCleanupUrls,
          if (checkpoint.cleanupUrl != null) checkpoint.cleanupUrl!,
        }.toList();
        for (final cleanupUrl in cleanupUrls) {
          await _cloud.deleteRecordingByUrl(cleanupUrl);
          checkpoint.deferredCleanupUrls.remove(cleanupUrl);
          if (checkpoint.cleanupUrl == cleanupUrl) {
            checkpoint.cleanupUrl = null;
          }
          await _saveUploadCheckpoints();
        }
        if (!isCurrent()) return;
        if (onLocalUploaded != null) {
          await onLocalUploaded(
            productionId,
            lineId,
            recording.id,
            checkpoint.remoteUrl,
          );
          if (!isCurrent()) return;
        }
        _uploadCheckpoints.remove(checkpointKey);
        await _saveUploadCheckpoints();
        if (!isCurrent()) return;
        uploaded++;
        _dlog.log(
          LogCategory.general,
          'RecordingSync: uploaded $lineId (${recording.character})',
        );
      } catch (e) {
        if (!isCurrent()) return;
        uploadFailures++;
        _dlog.logError(
          LogCategory.error,
          'RecordingSync: upload failed for $lineId',
          e,
        );
      }
    });

    final toDownload = <MapEntry<String, Map<String, dynamic>>>[];
    for (final entry in partnerCloudByLine.entries) {
      final local = localRecordings[entry.key];
      if (local != null && await File(local.localPath).exists()) {
        if (!isCurrent()) return 0;
        continue;
      }
      final cloudTimestamp = _parseTimestamp(entry.value['recorded_at']);
      final cached = _cache[_cacheKey(productionId, entry.key)];
      final cacheIsCurrent =
          cached != null &&
          cached.recordedAt >= cloudTimestamp &&
          await File(cached.localPath).exists();
      if (!isCurrent()) return 0;
      if (cacheIsCurrent) {
        cached.lastAccessedAt = DateTime.now().millisecondsSinceEpoch;
        _saveManifestDebounced();
        continue;
      }
      toDownload.add(entry);
    }

    var downloaded = 0;
    var downloadFailures = 0;
    await _runPooled(toDownload, (entry) async {
      final lineId = entry.key;
      final cloud = entry.value;
      final cloudTimestamp = _parseTimestamp(cloud['recorded_at']);
      final key = _cacheKey(productionId, lineId);
      await _serializeDownload(key, () async {
        try {
          final current = _cache[key];
          final currentFileExists =
              current != null && await File(current.localPath).exists();
          if (!isCurrent()) return;
          if (current != null &&
              current.recordedAt >= cloudTimestamp &&
              currentFileExists) {
            current.lastAccessedAt = DateTime.now().millisecondsSinceEpoch;
            _saveManifestDebounced();
            return;
          }
          final audioUrl = cloud['audio_url'];
          if (audioUrl is! String || audioUrl.isEmpty) {
            throw const FormatException('recording has no audio_url');
          }
          final characterName = _extractCharacterFromUrl(
            audioUrl,
            productionId,
          );
          final bytes = await _cloud.downloadRecordingByUrl(audioUrl);
          if (!isCurrent()) return;
          final path = await cachePath(productionId, lineId);
          await _writeCacheFile(path, bytes);
          if (!isCurrent()) return;

          _cache[key] = _CachedRecording(
            lineId: lineId,
            userId: cloud['user_id'] is String
                ? cloud['user_id'] as String
                : '',
            localPath: path,
            recordedAt: cloudTimestamp,
            durationMs: cloud['duration_ms'] is num
                ? (cloud['duration_ms'] as num).toInt()
                : 0,
            character: characterName,
            productionId: productionId,
          );
          downloaded++;
          onRecordingReady?.call(productionId, lineId, path);
          _dlog.log(
            LogCategory.general,
            'RecordingSync: downloaded $lineId ($characterName)',
          );
        } catch (e) {
          if (!isCurrent()) return;
          downloadFailures++;
          _dlog.logError(
            LogCategory.error,
            'RecordingSync: download failed for $lineId',
            e,
          );
        }
      });
    });

    if (!isCurrent()) return 0;
    final pruned = await _pruneCache(onEvicted: onRecordingEvicted);
    if (!isCurrent()) return 0;
    if (downloaded > 0 || pruned) _saveManifest();
    _dlog.log(
      LogCategory.general,
      'RecordingSync: done — $uploaded uploaded, $downloaded downloaded, '
      '$uploadFailures upload failure(s), $downloadFailures '
      'download failure(s)',
    );
    final trouble = <String>[
      if (downloadFailures > 0)
        "$downloadFailures castmate recording(s) couldn't be downloaded — "
            'those lines will use computer voices',
      if (uploadFailures > 0)
        "$uploadFailures of your recordings couldn't be uploaded — castmates "
            "won't hear them yet",
    ];
    if (trouble.isNotEmpty) _tellUser('${trouble.join('. ')}.');
    return downloaded;
  }

  /// Surface a sync problem to the user. Sync runs in the background with no
  /// widget context, hence the app-wide messenger. Guarded because there is no
  /// messenger before the app tree exists (or in tests) — and a missing
  /// SnackBar must never take down a sync; the failure is always logged first.
  void _tellUser(String message) {
    try {
      rootScaffoldMessengerKey.currentState?.showAutoToast(
        SnackBar(content: Text(message), duration: const Duration(seconds: 8)),
      );
    } catch (e) {
      debugPrint('RecordingSync: could not show "$message" ($e)');
    }
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
    final workers = List.generate(concurrency.clamp(1, items.length), (
      _,
    ) async {
      while (true) {
        final i = next++; // safe: single isolate, no await between read+bump
        if (i >= items.length) break;
        await task(items[i]);
      }
    });
    await Future.wait(workers);
  }

  // ── Build Recording Map from Cache ──────────────────────

  /// Get a single cached recording as a [Recording], or null if not cached
  /// (or cached under a different production). Much cheaper than
  /// [getCachedRecordings] when one file just arrived — during a big sync the
  /// full-map version stats every cache entry per downloaded file.
  Recording? getCachedRecording(String productionId, String lineId) {
    final cached = _cache[_cacheKey(productionId, lineId)];
    if (cached == null) return null;
    cached.lastAccessedAt = DateTime.now().millisecondsSinceEpoch;
    _saveManifestDebounced();
    return Recording(
      id: 'cache_$lineId',
      scriptLineId: lineId,
      character: cached.character,
      localPath: cached.localPath,
      remoteUrl: null,
      durationMs: cached.durationMs,
      recordedAt: DateTime.fromMillisecondsSinceEpoch(
        cached.recordedAt.clamp(0, 1 << 52),
      ),
    );
  }

  /// Get [productionId]'s cached recordings as a Map<lineId, Recording> for
  /// use with the recordingsProvider or understudyRecordingsProvider.
  ///
  /// The cache itself is global; the filter is REQUIRED — loading the whole
  /// map used to leak one production's recordings into every other
  /// production's provider (a fresh production showed them all as orphans).
  Future<Map<String, Recording>> getCachedRecordings(
    String productionId,
  ) async {
    final result = <String, Recording>{};
    for (final cached in _cache.values) {
      if (cached.productionId != productionId) continue;
      if (!await File(cached.localPath).exists()) continue;
      cached.lastAccessedAt = DateTime.now().millisecondsSinceEpoch;
      result[cached.lineId] = Recording(
        id: 'cache_${cached.lineId}',
        scriptLineId: cached.lineId,
        character: cached.character,
        localPath: cached.localPath,
        remoteUrl: null,
        durationMs: cached.durationMs,
        recordedAt: DateTime.fromMillisecondsSinceEpoch(
          cached.recordedAt.clamp(0, 1 << 52),
        ),
      );
    }
    if (result.isNotEmpty) _saveManifestDebounced();
    return result;
  }

  // ── Real-time Subscription ──────────────────────────────

  /// Subscribe to new recordings for a production.
  /// Downloads them as they arrive.
  void subscribe({
    required String productionId,
    required int runToken,
    String? myUserId,
    RecordingReadyCallback? onRecordingReady,
    RecordingEvictedCallback? onRecordingEvicted,
  }) {
    unawaited(unsubscribe());

    final supa = SupabaseService.instance;
    if (!supa.isInitialized || !supa.isSignedIn) return;

    try {
      _realtimeChannel = supa.subscribeToRecordings(
        productionId: productionId,
        onNewRecording: (payload) => handleRealtimeRecording(
          payload,
          productionId: productionId,
          myUserId: myUserId,
          runToken: runToken,
          onRecordingReady: onRecordingReady,
          onRecordingEvicted: onRecordingEvicted,
        ),
      );

      _dlog.log(
        LogCategory.general,
        'RecordingSync: subscribed to $productionId',
      );
    } catch (e) {
      _dlog.logError(LogCategory.error, 'RecordingSync: subscribe failed', e);
    }
  }

  /// Handle a realtime "new recording" payload: download the audio and add
  /// it to the cache. Exposed for tests.
  @visibleForTesting
  Future<void> handleRealtimeRecording(
    Map<String, dynamic> payload, {
    required String productionId,
    required int runToken,
    String? myUserId,
    RecordingReadyCallback? onRecordingReady,
    RecordingEvictedCallback? onRecordingEvicted,
  }) async {
    final generation = _generation;
    bool isCurrent() => _isRunCurrent(productionId, runToken, generation);
    final lineId = payload['line_id'];
    final recordUserId = payload['user_id'];
    if (lineId is! String || !isCurrent()) return;
    if (!isSafePathId(lineId)) {
      _dlog.logError(
        LogCategory.error,
        'RecordingSync: ignoring realtime recording with unsafe line_id "$lineId"',
      );
      return;
    }
    if (recordUserId == (myUserId ?? _cloud.currentUserId)) return;
    final audioUrl = payload['audio_url'];
    if (audioUrl is! String || audioUrl.isEmpty) return;
    final timestamp = _parseTimestamp(payload['recorded_at']);
    final key = _cacheKey(productionId, lineId);
    await _serializeDownload(key, () async {
      try {
        final current = _cache[key];
        final currentFileExists =
            current != null && await File(current.localPath).exists();
        if (!isCurrent()) return;
        if (current != null &&
            current.recordedAt >= timestamp &&
            currentFileExists) {
          current.lastAccessedAt = DateTime.now().millisecondsSinceEpoch;
          _saveManifestDebounced();
          return;
        }

        final characterName = _extractCharacterFromUrl(audioUrl, productionId);
        final bytes = await _cloud.downloadRecordingByUrl(audioUrl);
        if (!isCurrent()) return;
        final path = await cachePath(productionId, lineId);
        await _writeCacheFile(path, bytes);
        if (!isCurrent()) return;

        _cache[key] = _CachedRecording(
          lineId: lineId,
          userId: recordUserId is String ? recordUserId : '',
          localPath: path,
          recordedAt: timestamp,
          durationMs: payload['duration_ms'] is num
              ? (payload['duration_ms'] as num).toInt()
              : 0,
          character: characterName,
          productionId: productionId,
        );
        await _pruneCache(onEvicted: onRecordingEvicted);
        if (!isCurrent()) return;
        _saveManifestDebounced();
        onRecordingReady?.call(productionId, lineId, path);
      } catch (e) {
        if (!isCurrent()) return;
        _dlog.logError(
          LogCategory.error,
          'RecordingSync: realtime download failed for $lineId',
          e,
        );
      }
    });
  }

  /// Unsubscribe from real-time updates.
  Future<void> unsubscribe() async {
    final channel = _realtimeChannel;
    _realtimeChannel = null;
    if (channel != null) await _unsubscribe(channel);
  }

  Future<void> _unsubscribe(RealtimeChannel channel) async {
    try {
      await SupabaseService.instance.unsubscribe(channel);
    } catch (e) {
      _dlog.logError(LogCategory.error, 'RecordingSync: unsubscribe failed', e);
    }
  }

  Future<void> teardownAccount() async {
    _generation++;
    final unsubscribeFuture = unsubscribe();
    _manifestDebounce?.cancel();
    _manifestDebounce = null;
    _activeProductionId = null;
    _productionGeneration++;
    _downloadChains.clear();
    _cache.clear();
    await unsubscribeFuture;

    // Account-namespaced upload checkpoints live in Application Support and
    // remain durable across sign-out. Only downloaded playback cache is cleared.
    try {
      final dir = await cacheDir;
      final cacheDirectory = Directory(dir);
      if (await cacheDirectory.exists()) {
        await cacheDirectory.delete(recursive: true);
      }
      await cacheDirectory.create(recursive: true);
      _saveManifest();
    } catch (e) {
      _dlog.logError(
        LogCategory.error,
        'RecordingSync: account cache cleanup failed',
        e,
      );
    }
  }
  // ── Cleanup ──────────────────────────────────────────────

  static const _maxCacheEntries = 500;

  /// Bound the process-global cache using playback/access recency, while
  /// protecting the active production from eviction.
  Future<bool> _pruneCache({RecordingEvictedCallback? onEvicted}) async {
    final excess = _cache.length - _maxCacheEntries;
    if (excess <= 0) return false;
    final candidates =
        _cache.values
            .where((cached) => cached.productionId != _activeProductionId)
            .toList()
          ..sort((a, b) => a.lastAccessedAt.compareTo(b.lastAccessedAt));
    final victims = candidates.take(excess).toList();
    for (final cached in victims) {
      // Remove consumer state first, then index/file, so a published provider
      // can never point at a file this eviction is about to delete.
      onEvicted?.call(cached.productionId, cached.lineId);
      _cache.remove(_cacheKey(cached.productionId, cached.lineId));
      try {
        final file = File(cached.localPath);
        if (await file.exists()) await file.delete();
      } catch (e) {
        _dlog.logError(
          LogCategory.error,
          'RecordingSync: failed to evict ${cached.localPath}',
          e,
        );
      }
    }
    if (victims.isNotEmpty) {
      _dlog.log(
        LogCategory.general,
        'RecordingSync: evicted ${victims.length} least-recent cache entries',
      );
    }
    return victims.isNotEmpty;
  }

  /// Clear the cache for a production.
  Future<void> clearCache(String productionId) async {
    final dir = p.join(await cacheDir, productionId);
    final prodDir = Directory(dir);
    if (await prodDir.exists()) {
      await prodDir.delete(recursive: true);
    }
    _cache.removeWhere((_, v) => v.productionId == productionId);
    _saveManifest();
  }

  /// Clear all cached recordings.
  Future<void> clearAllCaches() async {
    final dir = await cacheDir;
    final cacheDirectory = Directory(dir);
    if (await cacheDirectory.exists()) {
      await cacheDirectory.delete(recursive: true);
    }
    await cacheDirectory.create(recursive: true);
    _cache.clear();
    _saveManifest();
  }

  // ── Helpers ──────────────────────────────────────────────

  static Future<void> _writeCacheFile(String path, Uint8List bytes) async {
    final temp = File('$path.incoming');
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(path);
    } catch (_) {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
      rethrow;
    }
  }

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
  final int recordedAt;
  final int durationMs;
  final String character;
  final String productionId;
  int lastAccessedAt;

  _CachedRecording({
    required this.lineId,
    required this.userId,
    required this.localPath,
    required this.recordedAt,
    required this.durationMs,
    required this.character,
    required this.productionId,
    int? lastAccessedAt,
  }) : lastAccessedAt = lastAccessedAt ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toJson() => {
    'lineId': lineId,
    'userId': userId,
    'localPath': localPath,
    'recordedAt': recordedAt,
    'durationMs': durationMs,
    'character': character,
    'productionId': productionId,
    'lastAccessedAt': lastAccessedAt,
  };

  static _CachedRecording? fromJson(Map<String, dynamic> json) {
    final lineId = json['lineId'] as String?;
    final localPath = json['localPath'] as String?;
    if (lineId == null || localPath == null) return null;
    var productionId = json['productionId'] as String? ?? '';
    if (productionId.isEmpty) {
      final segments = p.split(p.dirname(localPath));
      if (segments.isNotEmpty) productionId = segments.last;
    }
    return _CachedRecording(
      lineId: lineId,
      userId: json['userId'] as String? ?? '',
      localPath: localPath,
      recordedAt: json['recordedAt'] is num
          ? (json['recordedAt'] as num).toInt()
          : 0,
      durationMs: json['durationMs'] is num
          ? (json['durationMs'] as num).toInt()
          : 0,
      character: json['character'] as String? ?? '',
      productionId: productionId,
      lastAccessedAt: json['lastAccessedAt'] is num
          ? (json['lastAccessedAt'] as num).toInt()
          : DateTime.now().millisecondsSinceEpoch,
    );
  }
}

class _UploadCheckpoint {
  final String accountNamespace;
  final String productionId;
  final String lineId;
  final String remoteUrl;
  final int recordedAt;
  bool metadataSaved;
  String? cleanupUrl;
  final List<String> deferredCleanupUrls;

  _UploadCheckpoint({
    this.accountNamespace = '__guest__',
    required this.productionId,
    required this.lineId,
    required this.remoteUrl,
    required this.recordedAt,
    this.metadataSaved = false,
    this.cleanupUrl,
    List<String> deferredCleanupUrls = const [],
  }) : deferredCleanupUrls = List.of(deferredCleanupUrls);

  Map<String, dynamic> toJson() => {
    'accountNamespace': accountNamespace,
    'productionId': productionId,
    'lineId': lineId,
    'remoteUrl': remoteUrl,
    'recordedAt': recordedAt,
    'metadataSaved': metadataSaved,
    if (cleanupUrl != null) 'cleanupUrl': cleanupUrl,
    if (deferredCleanupUrls.isNotEmpty)
      'deferredCleanupUrls': deferredCleanupUrls,
  };

  static _UploadCheckpoint? fromJson(Map<String, dynamic> json) {
    final accountNamespace = json['accountNamespace'];
    final productionId = json['productionId'];
    final lineId = json['lineId'];
    final remoteUrl = json['remoteUrl'];
    final recordedAt = json['recordedAt'];
    final cleanupUrl = json['cleanupUrl'];
    final deferredCleanup = json['deferredCleanupUrls'];
    if (productionId is! String ||
        lineId is! String ||
        remoteUrl is! String ||
        recordedAt is! num) {
      return null;
    }
    return _UploadCheckpoint(
      accountNamespace: accountNamespace is String
          ? accountNamespace
          : '__guest__',
      productionId: productionId,
      lineId: lineId,
      remoteUrl: remoteUrl,
      recordedAt: recordedAt.toInt(),
      metadataSaved: json['metadataSaved'] == true,
      cleanupUrl: cleanupUrl is String && cleanupUrl.isNotEmpty
          ? cleanupUrl
          : null,
      deferredCleanupUrls: deferredCleanup is List
          ? deferredCleanup.whereType<String>().toList()
          : const [],
    );
  }
}
