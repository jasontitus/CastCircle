import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/app_database.dart';
import 'debug_log_service.dart';
import 'supabase_service.dart';

/// A pending upload job in the sync queue.
class SyncJob {
  final String id;
  final String productionId;
  final String characterName;
  final String lineId;

  /// Immutable Drift recording-row identity. Null only for queues persisted by
  /// app versions that predate this field.
  final String? recordingId;
  final String localPath;
  final int durationMs;
  final DateTime createdAt;
  final DateTime recordedAt;
  int retryCount;

  /// Set as soon as the bytes upload succeeds. Persisting this before later
  /// metadata work prevents retries from uploading the same bytes again.
  String? remoteUrl;
  bool cloudMetadataSaved;

  /// Uploaded objects superseded before metadata commit. Kept with the
  /// replacement job until the server-side cleanup outbox accepts them.
  final List<String> orphanedRemoteUrls;

  SyncJob({
    required this.id,
    required this.productionId,
    required this.characterName,
    required this.lineId,
    this.recordingId,
    required this.localPath,
    required this.durationMs,
    required this.createdAt,
    DateTime? recordedAt,
    this.retryCount = 0,
    this.remoteUrl,
    this.cloudMetadataSaved = false,
    List<String>? orphanedRemoteUrls,
  }) : recordedAt = recordedAt ?? createdAt,
       orphanedRemoteUrls = orphanedRemoteUrls ?? [];

  String get queueKey => '$productionId/$lineId';

  Map<String, dynamic> toJson() => {
    'id': id,
    'productionId': productionId,
    'characterName': characterName,
    'lineId': lineId,
    'recordingId': recordingId,
    'localPath': localPath,
    'durationMs': durationMs,
    'createdAt': createdAt.toIso8601String(),
    'recordedAt': recordedAt.toIso8601String(),
    'retryCount': retryCount,
    'remoteUrl': remoteUrl,
    'cloudMetadataSaved': cloudMetadataSaved,
    'orphanedRemoteUrls': orphanedRemoteUrls,
  };

  static SyncJob? fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    final productionId = json['productionId'] as String?;
    final lineId = json['lineId'] as String?;
    final localPath = json['localPath'] as String?;
    if (id == null ||
        productionId == null ||
        lineId == null ||
        localPath == null) {
      return null;
    }
    return SyncJob(
      id: id,
      productionId: productionId,
      characterName: json['characterName'] as String? ?? '',
      lineId: lineId,
      recordingId: json['recordingId'] as String?,
      localPath: localPath,
      durationMs: json['durationMs'] as int? ?? 0,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      recordedAt: DateTime.tryParse(json['recordedAt'] as String? ?? ''),
      retryCount: json['retryCount'] as int? ?? 0,
      remoteUrl: json['remoteUrl'] as String?,
      cloudMetadataSaved: json['cloudMetadataSaved'] as bool? ?? false,
      orphanedRemoteUrls:
          (json['orphanedRemoteUrls'] as List?)?.whereType<String>().toList() ??
          [],
    );
  }

  SyncJob snapshot() => SyncJob.fromJson(toJson())!;
}

abstract class RecordingUploader {
  bool get isReady;
  Future<String> upload(SyncJob job);
  Future<void> saveMetadata(SyncJob job, String remoteUrl);
  Future<void> discardUpload(SyncJob job, String remoteUrl);
}

class _SupabaseUploader implements RecordingUploader {
  @override
  bool get isReady {
    final supa = SupabaseService.instance;
    return supa.isInitialized && supa.isSignedIn;
  }

  @override
  Future<String> upload(SyncJob job) =>
      SupabaseService.instance.uploadRecording(
        productionId: job.productionId,
        characterName: job.characterName,
        lineId: job.lineId,
        audioFile: File(job.localPath),
      );

  @override
  Future<void> saveMetadata(SyncJob job, String remoteUrl) {
    final supa = SupabaseService.instance;
    return supa.saveRecordingMetadata(
      productionId: job.productionId,
      lineId: job.lineId,
      userId: supa.currentUser!.id,
      audioUrl: remoteUrl,
      durationMs: job.durationMs,
      recordedAt: job.recordedAt,
    );
  }

  @override
  Future<void> discardUpload(SyncJob job, String remoteUrl) {
    final supa = SupabaseService.instance;
    return supa.discardRecordingUpload(
      productionId: job.productionId,
      lineId: job.lineId,
      userId: supa.currentUser!.id,
      audioUrl: remoteUrl,
    );
  }
}

enum PersistedSyncJobState { pending, failed }

class PersistedSyncJob {
  final SyncJob job;
  final PersistedSyncJobState state;

  const PersistedSyncJob(this.job, this.state);
}

/// O(1)-per-transition durability boundary used by [SyncQueue].
abstract class SyncQueuePersistence {
  Future<List<PersistedSyncJob>> load();
  Future<void> upsert(SyncJob job, PersistedSyncJobState state);
  Future<void> delete(String queueKey);
  Future<void> clear();
}

class _DatabaseSyncQueuePersistence implements SyncQueuePersistence {
  _DatabaseSyncQueuePersistence(this._db);

  final AppDatabase _db;
  bool _legacyChecked = false;

  @override
  Future<List<PersistedSyncJob>> load() async {
    await _migrateLegacyFile();
    final rows = await _db.loadSyncQueueRows();
    return [
      for (final row in rows)
        if (SyncJob.fromJson(
              Map<String, dynamic>.from(jsonDecode(row.payload) as Map),
            )
            case final job?)
          PersistedSyncJob(
            job,
            row.state == PersistedSyncJobState.failed.name
                ? PersistedSyncJobState.failed
                : PersistedSyncJobState.pending,
          ),
    ];
  }

  @override
  Future<void> upsert(SyncJob job, PersistedSyncJobState state) =>
      _db.upsertSyncQueueRow(
        SyncQueueRow(
          key: job.queueKey,
          payload: jsonEncode(job.toJson()),
          state: state.name,
          remoteUrl: job.remoteUrl,
        ),
      );

  @override
  Future<void> delete(String queueKey) => _db.deleteSyncQueueRow(queueKey);

  @override
  Future<void> clear() => _db.clearSyncQueueRows();

  Future<void> _migrateLegacyFile() async {
    if (_legacyChecked) return;
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'sync_queue.json'));
    if (!await file.exists()) {
      _legacyChecked = true;
      return;
    }

    late final Map decoded;
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map) throw const FormatException('queue root is not a map');
      decoded = value;
    } catch (error) {
      DebugLogService.instance.logError(
        LogCategory.error,
        'SyncQueue: legacy queue file corrupt',
        error,
      );
      try {
        await file.rename('${file.path}.corrupt');
      } catch (renameError) {
        DebugLogService.instance.logError(
          LogCategory.error,
          'SyncQueue: could not preserve corrupt legacy queue',
          renameError,
        );
      }
      _legacyChecked = true;
      return;
    }

    // Database errors deliberately escape without renaming the source. A later
    // retry can import it; classifying an I/O failure as corrupt would lose the
    // only durable copy of offline recordings.
    for (final entry in <(dynamic, PersistedSyncJobState)>[
      (decoded['pending'], PersistedSyncJobState.pending),
      (decoded['failed'], PersistedSyncJobState.failed),
    ]) {
      for (final raw in entry.$1 is List ? entry.$1 as List : const []) {
        if (raw is! Map) continue;
        final job = SyncJob.fromJson(Map<String, dynamic>.from(raw));
        if (job != null) {
          await _db.insertSyncQueueRowIfAbsent(
            SyncQueueRow(
              key: job.queueKey,
              payload: jsonEncode(job.toJson()),
              state: entry.$2.name,
              remoteUrl: job.remoteUrl,
            ),
          );
        }
      }
    }
    await file.rename('${file.path}.migrated');
    _legacyChecked = true;
  }
}

/// Test-only legacy store. Production uses keyed Drift rows above.
class _JsonSyncQueuePersistence implements SyncQueuePersistence {
  _JsonSyncQueuePersistence(this.path);

  final String path;
  final Map<String, PersistedSyncJob> _rows = {};
  bool _loaded = false;

  @override
  Future<List<PersistedSyncJob>> load() async {
    if (_loaded) return _rows.values.toList();
    _loaded = true;
    final file = File(path);
    if (!await file.exists()) return const [];
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) throw const FormatException('queue root is not a map');
    for (final entry in <(dynamic, PersistedSyncJobState)>[
      (decoded['pending'], PersistedSyncJobState.pending),
      (decoded['failed'], PersistedSyncJobState.failed),
    ]) {
      for (final raw in entry.$1 is List ? entry.$1 as List : const []) {
        if (raw is! Map) continue;
        final job = SyncJob.fromJson(Map<String, dynamic>.from(raw));
        if (job != null) _rows[job.queueKey] = PersistedSyncJob(job, entry.$2);
      }
    }
    return _rows.values.toList();
  }

  @override
  Future<void> upsert(SyncJob job, PersistedSyncJobState state) async {
    await load();
    _rows[job.queueKey] = PersistedSyncJob(job.snapshot(), state);
    await _write();
  }

  @override
  Future<void> delete(String queueKey) async {
    await load();
    _rows.remove(queueKey);
    await _write();
  }

  @override
  Future<void> clear() async {
    _loaded = true;
    _rows.clear();
    await _write();
  }

  Future<void> _write() async {
    final snapshot = jsonEncode({
      'pending': [
        for (final row in _rows.values)
          if (row.state == PersistedSyncJobState.pending) row.job.toJson(),
      ],
      'failed': [
        for (final row in _rows.values)
          if (row.state == PersistedSyncJobState.failed) row.job.toJson(),
      ],
    });
    final tmp = File('$path.tmp');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsString(snapshot, flush: true);
    await tmp.rename(path);
  }
}

class _NoopSyncQueuePersistence implements SyncQueuePersistence {
  @override
  Future<void> clear() async {}
  @override
  Future<void> delete(String queueKey) async {}
  @override
  Future<List<PersistedSyncJob>> load() async => const [];
  @override
  Future<void> upsert(SyncJob job, PersistedSyncJobState state) async {}
}

class _PersistenceMutation {
  final int generation;
  final SyncJob? job;
  final PersistedSyncJobState? state;
  final bool clear;

  const _PersistenceMutation.upsert(this.generation, this.job, this.state)
    : clear = false;
  const _PersistenceMutation.delete(this.generation)
    : job = null,
      state = null,
      clear = false;
  const _PersistenceMutation.clear(this.generation)
    : job = null,
      state = null,
      clear = true;
}

/// Offline-first sync queue for uploading recordings to Supabase.
class SyncQueue {
  SyncQueue._()
    : _uploader = _SupabaseUploader(),
      _persistence = _DatabaseSyncQueuePersistence(AppDatabase()),
      _persistenceRetryDelay = const Duration(seconds: 2);

  @visibleForTesting
  SyncQueue.forTesting(
    this._uploader, {
    String? persistPath,
    SyncQueuePersistence? persistence,
    Duration persistenceRetryDelay = const Duration(milliseconds: 10),
  }) : _persistence =
           persistence ??
           (persistPath == null
               ? _NoopSyncQueuePersistence()
               : _JsonSyncQueuePersistence(persistPath)),
       _persistenceRetryDelay = persistenceRetryDelay;

  static final instance = SyncQueue._();

  final RecordingUploader _uploader;
  final SyncQueuePersistence _persistence;
  final Duration _persistenceRetryDelay;
  final _dlog = DebugLogService.instance;

  final List<SyncJob> _pending = [];
  final List<SyncJob> _failed = [];
  final LinkedHashMap<String, _PersistenceMutation> _mutations =
      LinkedHashMap();
  Timer? _retryTimer;
  Timer? _persistenceRetryTimer;
  StreamSubscription? _connectivitySub;
  bool _processing = false;
  Future<void>? _processingFuture;
  bool _loaded = false;
  Future<void>? _loadFuture;
  Future<void>? _persistFuture;
  int _dirtyGeneration = 0;
  int _durableGeneration = 0;
  Object? _lastPersistenceError;
  int _persistenceFailureCount = 0;

  List<SyncJob> get pending => List.unmodifiable(_pending);
  List<SyncJob> get failed => List.unmodifiable(_failed);
  int get pendingCount => _pending.length + _failed.length;
  Object? get lastPersistenceError => _lastPersistenceError;
  bool get persistenceHealthy =>
      _lastPersistenceError == null && _mutations.isEmpty;
  int get dirtyGeneration => _dirtyGeneration;
  int get durableGeneration => _durableGeneration;

  Future<void> Function(SyncJob job, String remoteUrl)? onUploaded;
  void Function(SyncJob job, Object error)? onGaveUp;

  void start() {
    final previous = _connectivitySub;
    if (previous != null) unawaited(previous.cancel());
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((result) => result != ConnectivityResult.none)) {
        unawaited(_resumeAfterPersistence());
      }
    });
    unawaited(_resumeAfterPersistence());
  }

  Future<void> _resumeAfterPersistence() async {
    await _drainPersistence();
    if (_loaded && !_processing) await _processQueue();
  }

  void stop() {
    final subscription = _connectivitySub;
    if (subscription != null) unawaited(subscription.cancel());
    _connectivitySub = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _persistenceRetryTimer?.cancel();
    _persistenceRetryTimer = null;
  }

  void enqueue({
    required String productionId,
    required String characterName,
    required String lineId,
    String? recordingId,
    required String localPath,
    required int durationMs,
    DateTime? recordedAt,
  }) {
    bool sameLine(SyncJob job) =>
        job.productionId == productionId && job.lineId == lineId;
    final priorJobs = [..._pending.where(sameLine), ..._failed.where(sameLine)];
    final replaced = priorJobs.isNotEmpty;
    final orphanedRemoteUrls = <String>{
      for (final prior in priorJobs) ...prior.orphanedRemoteUrls,
      for (final prior in priorJobs)
        if (prior.remoteUrl != null && !prior.cloudMetadataSaved)
          prior.remoteUrl!,
    };
    _pending.removeWhere(sameLine);
    _failed.removeWhere(sameLine);

    final now = DateTime.now();
    final job = SyncJob(
      id: '${productionId}_${lineId}_${now.millisecondsSinceEpoch}',
      productionId: productionId,
      characterName: characterName,
      lineId: lineId,
      recordingId: recordingId,
      localPath: localPath,
      durationMs: durationMs,
      createdAt: now,
      recordedAt: recordedAt,
      orphanedRemoteUrls: orphanedRemoteUrls.toList(),
    );
    _pending.add(job);
    _queueUpsert(job, PersistedSyncJobState.pending);

    _dlog.log(
      LogCategory.network,
      'SyncQueue: queued upload line=$lineId durationMs=$durationMs'
      '${replaced ? ' (replaced prior take)' : ''}',
    );
    if (!_processing) unawaited(_processQueue());
  }

  @visibleForTesting
  Future<void> processQueue() => _processQueue();

  Future<void> _processQueue() {
    final existing = _processingFuture;
    if (existing != null) return existing;
    _processing = true;
    late final Future<void> processing;
    processing = _runProcessQueue().whenComplete(() {
      _processing = false;
      if (identical(_processingFuture, processing)) {
        _processingFuture = null;
      }
    });
    _processingFuture = processing;
    return processing;
  }

  Future<void> _runProcessQueue() async {
    try {
      await _restorePersisted();
      await _drainPersistence();
      if (_mutations.isNotEmpty) return;
      if (_pending.isEmpty) {
        _scheduleUploadRetry();
        return;
      }

      if (!_uploader.isReady) {
        _retryTimer?.cancel();
        _retryTimer = Timer(
          const Duration(seconds: 30),
          () => unawaited(_processQueue()),
        );
        return;
      }

      queueLoop:
      while (_pending.isNotEmpty) {
        final job = _pending.first;
        Object? failure;
        try {
          while (job.orphanedRemoteUrls.isNotEmpty) {
            final orphanedUrl = job.orphanedRemoteUrls.first;
            await _uploader.discardUpload(job, orphanedUrl);
            if (!_pending.contains(job)) continue queueLoop;
            job.orphanedRemoteUrls.removeAt(0);
            _queueUpsert(job, PersistedSyncJobState.pending);
            await _drainPersistence();
            if (_mutations.isNotEmpty) return;
          }

          if (job.remoteUrl == null && !File(job.localPath).existsSync()) {
            _pending.remove(job);
            _queueDelete(job.queueKey);
            await _drainPersistence();
            continue;
          }

          if (job.remoteUrl == null) {
            final url = await _uploader.upload(job);
            if (!_pending.contains(job)) {
              SyncJob? replacement;
              for (final candidate in _pending) {
                if (candidate.queueKey == job.queueKey) {
                  replacement = candidate;
                  break;
                }
              }
              if (replacement == null) {
                await _uploader.discardUpload(job, url);
              } else {
                if (!replacement.orphanedRemoteUrls.contains(url)) {
                  replacement.orphanedRemoteUrls.add(url);
                }
                _queueUpsert(replacement, PersistedSyncJobState.pending);
                await _drainPersistence();
                if (_mutations.isNotEmpty) return;
              }
              continue;
            }
            job.remoteUrl = url;
            job.cloudMetadataSaved = false;
            _queueUpsert(job, PersistedSyncJobState.pending);
            await _drainPersistence();
            if (_mutations.isNotEmpty) return;
          }

          if (!job.cloudMetadataSaved) {
            await _uploader.saveMetadata(job, job.remoteUrl!);
            if (!_pending.contains(job)) continue;
            job.cloudMetadataSaved = true;
            _queueUpsert(job, PersistedSyncJobState.pending);
            await _drainPersistence();
            if (_mutations.isNotEmpty) return;
          }

          await onUploaded?.call(job, job.remoteUrl!);
        } catch (error) {
          failure = error;
        }

        if (!_pending.remove(job)) continue;
        if (failure == null) {
          _queueDelete(job.queueKey);
          await _drainPersistence();
          _dlog.log(
            LogCategory.network,
            'SyncQueue: settled line=${job.lineId} → ${job.remoteUrl}',
          );
          continue;
        }

        job.retryCount++;
        _failed.add(job);
        _queueUpsert(job, PersistedSyncJobState.failed);
        await _drainPersistence();
        _dlog.logError(
          LogCategory.network,
          'SyncQueue: ${job.remoteUrl == null ? 'upload' : 'post-upload persistence'} '
          'failed line=${job.lineId} (attempt ${job.retryCount}/5)',
          failure,
        );
        if (job.retryCount >= 5) onGaveUp?.call(job, failure);
      }
    } catch (error) {
      _lastPersistenceError = error;
      _schedulePersistenceRetry();
    }

    // Persistence owns the retry cadence while any generation is dirty.
    // Never hot-loop upload processing around its bounded backoff.
    if (_mutations.isNotEmpty) return;

    if (_pending.isNotEmpty) {
      scheduleMicrotask(() => unawaited(_processQueue()));
    } else {
      _scheduleUploadRetry();
    }
  }

  void _scheduleUploadRetry() {
    final retryable = _failed.where((job) => job.retryCount < 5).toList();
    if (retryable.isEmpty) return;
    final delay = Duration(
      seconds: 2 << retryable.first.retryCount.clamp(0, 4),
    );
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      for (final job in retryable) {
        if (_failed.remove(job)) _pending.add(job);
      }
      unawaited(_processQueue());
    });
  }

  @visibleForTesting
  Future<void> retryNow() {
    _retryTimer?.cancel();
    _retryTimer = null;
    for (final job in _failed) {
      if (job.retryCount >= 5) job.retryCount = 0;
    }
    _pending.addAll(_failed);
    _failed.clear();
    return _processQueue();
  }

  Future<void> _restorePersisted() {
    if (_loaded) return Future.value();
    final existing = _loadFuture;
    if (existing != null) return existing;
    final loading = _loadPersisted();
    _loadFuture = loading;
    return loading.catchError((Object error) {
      if (identical(_loadFuture, loading)) _loadFuture = null;
      throw error;
    });
  }

  Future<void> _loadPersisted() async {
    final rows = await _persistence.load();
    final liveKeys = {
      for (final job in _pending) job.queueKey,
      for (final job in _failed) job.queueKey,
    };
    for (final row in rows) {
      final job = row.job;
      if (!liveKeys.add(job.queueKey)) continue;
      if (job.remoteUrl == null && !File(job.localPath).existsSync()) {
        _queueDelete(job.queueKey);
        continue;
      }
      (row.state == PersistedSyncJobState.failed ? _failed : _pending).add(job);
    }
    _loaded = true;
  }

  void _queueUpsert(SyncJob job, PersistedSyncJobState state) {
    final generation = ++_dirtyGeneration;
    _mutations[job.queueKey] = _PersistenceMutation.upsert(
      generation,
      job.snapshot(),
      state,
    );
    unawaited(_drainPersistence());
  }

  void _queueDelete(String key) {
    final generation = ++_dirtyGeneration;
    _mutations[key] = _PersistenceMutation.delete(generation);
    unawaited(_drainPersistence());
  }

  Future<void> _drainPersistence() {
    return _persistFuture ??= _runPersistence().whenComplete(() {
      _persistFuture = null;
    });
  }

  Future<void> _runPersistence() async {
    try {
      await _restorePersisted();
      while (_mutations.isNotEmpty) {
        final entry = _mutations.entries.first;
        final mutation = entry.value;
        try {
          if (mutation.clear) {
            await _persistence.clear();
          } else if (mutation.job == null) {
            await _persistence.delete(entry.key);
          } else {
            await _persistence.upsert(mutation.job!, mutation.state!);
          }
        } catch (error) {
          _lastPersistenceError = error;
          _schedulePersistenceRetry();
          return;
        }
        if (identical(_mutations[entry.key], mutation)) {
          _mutations.remove(entry.key);
        }
        _durableGeneration = mutation.generation > _durableGeneration
            ? mutation.generation
            : _durableGeneration;
      }
      _lastPersistenceError = null;
      _persistenceFailureCount = 0;
      _persistenceRetryTimer?.cancel();
      _persistenceRetryTimer = null;
    } catch (error) {
      _lastPersistenceError = error;
      _schedulePersistenceRetry();
    }
  }

  void _schedulePersistenceRetry() {
    _persistenceFailureCount++;
    _dlog.logError(
      LogCategory.error,
      'SyncQueue: persistence unavailable; queue remains dirty',
      _lastPersistenceError,
    );
    _persistenceRetryTimer?.cancel();
    final exponent = _persistenceFailureCount < 5
        ? _persistenceFailureCount
        : 5;
    final delay = _persistenceRetryDelay * (1 << exponent);
    _persistenceRetryTimer = Timer(delay, () async {
      await _drainPersistence();
      if (_mutations.isEmpty && !_processing) unawaited(_processQueue());
    });
  }

  /// Attempts to make the latest queue generation durable and reports failure
  /// instead of silently treating an in-memory queue as persisted.
  @visibleForTesting
  Future<void> flushPersistence() async {
    await _restorePersisted();
    _persistenceRetryTimer?.cancel();
    _persistenceRetryTimer = null;
    await _drainPersistence();
    if (_mutations.isNotEmpty) {
      throw StateError(
        'Sync queue is not durable through generation $_dirtyGeneration: '
        '$_lastPersistenceError',
      );
    }
  }

  @visibleForTesting
  void reset() {
    _pending.clear();
    _failed.clear();
    _retryTimer?.cancel();
    _retryTimer = null;
    _processing = false;
    _loaded = true;
    final generation = ++_dirtyGeneration;
    _mutations
      ..clear()
      ..['__clear__'] = _PersistenceMutation.clear(generation);
    unawaited(_drainPersistence());
  }
}
