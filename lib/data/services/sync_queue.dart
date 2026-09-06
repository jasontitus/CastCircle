import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'debug_log_service.dart';
import 'supabase_service.dart';

/// A pending upload job in the sync queue.
class SyncJob {
  final String id;
  final String productionId;
  final String accountNamespace;
  final String characterName;
  final String lineId;
  final String localPath;
  final int durationMs;
  final DateTime createdAt;

  /// When the audio was actually recorded (used for freshness comparison
  /// on other devices). Falls back to [createdAt].
  final DateTime recordedAt;
  int retryCount;

  /// Set after storage upload. Persisting it lets metadata and local-completion
  /// retries reuse the object instead of uploading audio again.
  String? uploadedUrl;
  bool metadataSaved;
  int publicationRetryCount;
  final List<String> deferredCleanupUrls;

  SyncJob({
    required this.id,
    this.accountNamespace = '__guest__',
    required this.productionId,
    required this.characterName,
    required this.lineId,
    required this.localPath,
    required this.durationMs,
    required this.createdAt,
    DateTime? recordedAt,
    this.uploadedUrl,
    this.metadataSaved = false,
    this.publicationRetryCount = 0,
    List<String> deferredCleanupUrls = const [],
    this.retryCount = 0,
  }) : deferredCleanupUrls = List.of(deferredCleanupUrls),
       recordedAt = recordedAt ?? createdAt;

  Map<String, dynamic> toJson() => {
    'accountNamespace': accountNamespace,
    'id': id,
    'productionId': productionId,
    'characterName': characterName,
    'lineId': lineId,
    'localPath': localPath,
    'durationMs': durationMs,
    'createdAt': createdAt.toIso8601String(),
    'recordedAt': recordedAt.toIso8601String(),
    'retryCount': retryCount,
    if (uploadedUrl != null) 'uploadedUrl': uploadedUrl,
    if (uploadedUrl != null) 'metadataSaved': metadataSaved,
    'publicationRetryCount': publicationRetryCount,
    if (deferredCleanupUrls.isNotEmpty)
      'deferredCleanupUrls': deferredCleanupUrls,
  };

  static SyncJob? fromJson(
    Map<String, dynamic> json, {
    String accountNamespace = '__guest__',
  }) {
    final id = json['id'];
    final productionId = json['productionId'];
    final lineId = json['lineId'];
    final localPath = json['localPath'];
    if (id is! String ||
        productionId is! String ||
        lineId is! String ||
        localPath is! String) {
      return null;
    }
    final duration = json['durationMs'];
    final createdAtValue = json['createdAt'];
    final recordedAtValue = json['recordedAt'];
    final deferredCleanupValue = json['deferredCleanupUrls'];
    final uploadedUrlValue = json['uploadedUrl'];
    final metadataSavedValue = json['metadataSaved'];
    final publicationRetryValue = json['publicationRetryCount'];
    return SyncJob(
      id: id,
      accountNamespace: json['accountNamespace'] is String
          ? json['accountNamespace'] as String
          : accountNamespace,
      productionId: productionId,
      characterName: json['characterName'] is String
          ? json['characterName'] as String
          : '',
      lineId: lineId,
      localPath: localPath,
      durationMs: duration is num ? duration.toInt() : 0,
      createdAt: createdAtValue is String
          ? DateTime.tryParse(createdAtValue) ?? DateTime.now()
          : DateTime.now(),
      recordedAt: recordedAtValue is String
          ? DateTime.tryParse(recordedAtValue)
          : null,
      uploadedUrl: uploadedUrlValue is String && uploadedUrlValue.isNotEmpty
          ? uploadedUrlValue
          : null,
      metadataSaved: metadataSavedValue == true,
      publicationRetryCount: publicationRetryValue is num
          ? publicationRetryValue.toInt()
          : 0,
      deferredCleanupUrls: deferredCleanupValue is List
          ? deferredCleanupValue.whereType<String>().toList()
          : const [],
      // Persisted upload retries start fresh after an app restart. Completion
      // retries retain uploadedUrl and therefore never upload again.
      retryCount: 0,
    );
  }
}

/// Abstraction over the cloud upload calls so the queue can be tested
/// without a live Supabase client.
abstract class RecordingUploader {
  /// Whether uploads can proceed (e.g. signed in).
  bool get isReady;

  String get accountNamespace => '__guest__';

  /// Upload the audio file and return its remote URL.
  Future<String> upload(SyncJob job);

  /// Persist recording metadata and return the superseded object URL.
  Future<String?> saveMetadata(SyncJob job, String remoteUrl);

  Future<void> deleteObject(String remoteUrl);
}

class _SupabaseUploader implements RecordingUploader {
  @override
  bool get isReady {
    final supa = SupabaseService.instance;
    return supa.isInitialized && supa.isSignedIn;
  }

  @override
  String get accountNamespace =>
      SupabaseService.instance.currentUser?.id ?? '__guest__';

  @override
  Future<String> upload(SyncJob job) {
    return SupabaseService.instance.uploadRecording(
      productionId: job.productionId,
      characterName: job.characterName,
      lineId: job.lineId,
      audioFile: File(job.localPath),
    );
  }

  @override
  Future<String?> saveMetadata(SyncJob job, String remoteUrl) {
    final supa = SupabaseService.instance;
    if (supa.currentUser == null) {
      throw const _UploadPausedException();
    }
    return supa.saveRecordingMetadata(
      productionId: job.productionId,
      lineId: job.lineId,
      audioUrl: remoteUrl,
      durationMs: job.durationMs,
      recordedAt: job.recordedAt,
    );
  }

  @override
  Future<void> deleteObject(String remoteUrl) =>
      SupabaseService.instance.deleteRecordingByUrl(remoteUrl);
}

class _UploadPausedException implements Exception {
  const _UploadPausedException();
}

/// Offline-first sync queue for uploading recordings to Supabase.
///
/// Recordings are saved locally first (source of truth), then queued
/// for upload when connectivity is available. Failed uploads are
/// retried with exponential backoff.
class SyncQueue {
  SyncQueue._() : _uploader = _SupabaseUploader(), _persistToDisk = true;

  @visibleForTesting
  SyncQueue.forTesting(this._uploader, {String? persistPath})
    : _persistToDisk = persistPath != null,
      _persistPathOverride = persistPath;

  static final instance = SyncQueue._();

  final RecordingUploader _uploader;
  final _dlog = DebugLogService.instance;
  int _generation = 0;

  final List<SyncJob> _pending = [];
  final List<SyncJob> _failed = [];
  final Set<String> _cleanupUrls = {};
  int _cleanupRetryCount = 0;
  Timer? _retryTimer;
  StreamSubscription? _connectivitySub;
  bool _processing = false;

  // ── Persistence ────────────────────────────────────────
  //
  // Jobs are tiny JSON (the audio files already live on disk). Mutations are
  // coalesced into atomic snapshots, while post-upload URL checkpoints await
  // durable persistence before metadata publication continues.
  final bool _persistToDisk;
  String? _persistPathOverride;
  bool _loaded = false;
  Future<void>? _persistChain;
  bool _persistDirty = false;
  bool _persistScheduled = false;
  Future<void>? _scheduledPersist;

  int _journalEntries = 0;

  Future<String> _journalPath() async => '${await _persistPath()}.journal';

  Future<void> _appendJournal(Map<String, dynamic> event) async {
    if (!_persistToDisk) return;
    await _serializedFileAccess(() async {
      final journal = File(await _journalPath());
      await journal.writeAsString(
        '${jsonEncode(event)}\n',
        mode: FileMode.append,
        flush: true,
      );
      _journalEntries++;
    });
    if (_journalEntries >= 128) await _compactJournal();
  }

  Future<void> _compactJournal() async {
    if (!_persistToDisk) return;
    await _persist();
    await _serializedFileAccess(() async {
      await File(await _journalPath()).writeAsString('', flush: true);
      _journalEntries = 0;
    });
  }

  Future<void> _appendJob(SyncJob job, {List<String> cleanupUrls = const []}) =>
      _appendJournal({
        'op': 'upsert',
        'job': job.toJson(),
        if (cleanupUrls.isNotEmpty) 'cleanupUrls': cleanupUrls,
      });

  Future<void> _appendRemove(SyncJob job) => _appendJournal({
    'op': 'remove',
    'accountNamespace': job.accountNamespace,
    'id': job.id,
  });

  Future<String> _persistPath() async {
    if (_persistPathOverride != null) return _persistPathOverride!;
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'sync_queue.json');
  }

  /// Run [action] serialized against all other queue-file access. Every load
  /// AND write goes through this one chain — a restore racing a write used to
  /// read a freshly-overwritten file and lose the previous run's jobs.
  Future<void> _serializedFileAccess(Future<void> Function() action) {
    final next = (_persistChain ?? Future.value())
        .catchError((Object _) {})
        .then((_) => action());
    _persistChain = next;
    return next;
  }

  /// Coalesce mutations that arrive while a snapshot is queued or being
  /// written. Every caller shares the same completion future; a mutation during
  /// I/O sets dirty and forces one final latest-state snapshot.
  Future<void> _persist() {
    if (!_persistToDisk) return Future.value();
    _persistDirty = true;
    if (_persistScheduled) {
      final current = _scheduledPersist!;
      return current.then((_) async {
        while (_persistScheduled) {
          await _scheduledPersist!;
        }
      });
    }
    _persistScheduled = true;

    final scheduled = _serializedFileAccess(() async {
      do {
        _persistDirty = false;
        try {
          await _loadPersisted();
          if (!_loaded) return;
          final snapshot = jsonEncode({
            'cleanupUrls': _cleanupUrls.toList(),
            'pending': _pending.map((j) => j.toJson()).toList(),
            'failed': _failed.map((j) => j.toJson()).toList(),
          });
          final path = await _persistPath();
          final tmp = File('$path.tmp');
          await tmp.writeAsString(snapshot, flush: true);
          await tmp.rename(path);
        } catch (e) {
          _dlog.logError(LogCategory.error, 'SyncQueue: persist failed', e);
          rethrow;
        }
      } while (_persistDirty);
    });
    _scheduledPersist = scheduled.whenComplete(() {
      _persistScheduled = false;
      _scheduledPersist = null;
      if (_persistDirty) {
        unawaited(
          _persist().catchError((Object e) {
            _dlog.logError(
              LogCategory.error,
              'SyncQueue: follow-up persist failed',
              e,
            );
          }),
        );
      }
    });

    return _scheduledPersist!;
  }

  Future<void> _replayJournal(List<SyncJob> restored) async {
    final journal = File(await _journalPath());
    if (!await journal.exists()) return;
    final lines = const LineSplitter().convert(await journal.readAsString());
    _journalEntries = lines.length;
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final event = jsonDecode(line);
        if (event is! Map) continue;
        final op = event['op'];
        if (op == 'upsert') {
          final raw = event['job'];
          if (raw is! Map) continue;
          final job = SyncJob.fromJson(
            Map<String, dynamic>.from(raw),
            accountNamespace: _uploader.accountNamespace,
          );
          if (job == null) continue;
          restored.removeWhere(
            (existing) =>
                existing.accountNamespace == job.accountNamespace &&
                existing.productionId == job.productionId &&
                existing.lineId == job.lineId,
          );
          restored.add(job);
          final cleanup = event['cleanupUrls'];
          if (cleanup is List) {
            _cleanupUrls.addAll(cleanup.whereType<String>());
          }
        } else if (op == 'remove') {
          restored.removeWhere(
            (job) =>
                job.accountNamespace == event['accountNamespace'] &&
                job.id == event['id'],
          );
        } else if (op == 'cleanupAdd' && event['url'] is String) {
          _cleanupUrls.add(event['url'] as String);
        } else if (op == 'cleanupRemove' && event['url'] is String) {
          _cleanupUrls.remove(event['url'] as String);
        }
      } catch (e) {
        _dlog.logError(
          LogCategory.error,
          'SyncQueue: ignored malformed journal event',
          e,
        );
      }
    }
  }

  /// Restore persisted jobs via the serialized chain (safe against writes).
  Future<void> _restorePersisted() =>
      _persistToDisk ? _serializedFileAccess(_loadPersisted) : Future.value();

  /// Load persisted jobs (app restart). Jobs whose local audio file no longer
  /// exists are dropped; a job for a line that was re-enqueued live before the
  /// load finished is superseded by the live (newer) one. Only call from
  /// within [_serializedFileAccess].
  Future<void> _loadPersisted() async {
    if (!_persistToDisk || _loaded) return;
    try {
      final file = File(await _persistPath());
      dynamic data = <String, dynamic>{};
      if (await file.exists()) {
        try {
          data = jsonDecode(await file.readAsString());
        } catch (e) {
          _dlog.logError(
            LogCategory.error,
            'SyncQueue: queue file corrupt — set aside',
            e,
          );
          try {
            await file.rename('${file.path}.corrupt');
          } catch (_) {}
          data = <String, dynamic>{};
        }
      }
      if (data is! Map) {
        _dlog.logError(
          LogCategory.error,
          'SyncQueue: queue file has an invalid top-level value — ignored',
        );
        data = <String, dynamic>{};
      }

      final restored = <SyncJob>[];
      void restoreList(dynamic value, String listName) {
        if (value is! List) return;
        for (var i = 0; i < value.length; i++) {
          try {
            final raw = value[i];
            if (raw is! Map) {
              throw const FormatException('job is not an object');
            }
            final json = <String, dynamic>{};
            for (final entry in raw.entries) {
              if (entry.key is! String) {
                throw const FormatException('job key is not a string');
              }
              json[entry.key as String] = entry.value;
            }
            final job = SyncJob.fromJson(
              json,
              accountNamespace: _uploader.accountNamespace,
            );
            if (job == null) {
              throw const FormatException('job is missing required fields');
            }
            restored.add(job);
          } catch (e) {
            _dlog.logError(
              LogCategory.error,
              'SyncQueue: ignored malformed $listName job at index $i',
              e,
            );
          }
        }
      }

      restoreList(data['pending'], 'pending');
      final cleanupUrls = data['cleanupUrls'];
      if (cleanupUrls is List) {
        _cleanupUrls.addAll(cleanupUrls.whereType<String>());
      }
      restoreList(data['failed'], 'failed');
      await _replayJournal(restored);
      var kept = 0;
      final queuedKeys = {
        for (final j in _pending)
          '${j.accountNamespace}/${j.productionId}/${j.lineId}',
        for (final j in _failed)
          '${j.accountNamespace}/${j.productionId}/${j.lineId}',
      };
      for (final job in restored) {
        if (job.uploadedUrl == null && !await File(job.localPath).exists()) {
          continue;
        }
        final key = '${job.accountNamespace}/${job.productionId}/${job.lineId}';
        if (!queuedKeys.add(key)) continue;
        _pending.add(job);
        kept++;
      }
      _loaded = true;
      if (kept > 0) {
        _dlog.log(
          LogCategory.network,
          'SyncQueue: restored $kept queued upload(s) from a previous run',
        );
      }
    } catch (e) {
      // Path and I/O failures are retryable. Do not latch _loaded: a later
      // enqueue/start must get another chance before overwriting the snapshot.
      _dlog.logError(LogCategory.error, 'SyncQueue: restore failed', e);
    }
  }

  /// Test hook: wait for restore + any in-flight persist writes.
  @visibleForTesting
  Future<void> flushPersistence() async {
    await _restorePersisted();
    await (_persistChain ?? Future.value());
  }

  List<SyncJob> get pending => List.unmodifiable(
    _pending.where((job) => job.accountNamespace == _uploader.accountNamespace),
  );
  List<SyncJob> get failed => List.unmodifiable(
    _failed.where((job) => job.accountNamespace == _uploader.accountNamespace),
  );
  int get pendingCount => pending.length + failed.length;

  /// Called after durable cloud publication with immutable take identity.
  Future<void> Function(
    String productionId,
    String lineId,
    String recordingId,
    String remoteUrl,
  )?
  onUploaded;

  /// Called when a job is abandoned after exhausting all retries.
  void Function(SyncJob job, Object error)? onGaveUp;

  /// Start monitoring connectivity and processing the queue. Also restores
  /// jobs persisted by a previous run (uploads killed with the app).
  void start() {
    _connectivitySub?.cancel();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasConnection = results.any((r) => r != ConnectivityResult.none);
      if (hasConnection && !_processing) {
        _processQueue();
      }
    });
    unawaited(
      _restorePersisted().then((_) {
        if ((_pending.isNotEmpty || _cleanupUrls.isNotEmpty) && !_processing) {
          _processQueue();
        }
      }),
    );
  }

  /// Stop monitoring and cancel pending retries.
  void stop() {
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// Durably enqueue a recording upload. The immutable [recordingId] is the
  /// take/version token carried through metadata publication and local marking.
  Future<void> enqueue({
    required String productionId,
    required String recordingId,
    required String characterName,
    required String lineId,
    required String localPath,
    required int durationMs,
    DateTime? recordedAt,
  }) async {
    await _restorePersisted();
    final accountNamespace = _uploader.accountNamespace;
    bool sameLine(SyncJob job) =>
        job.accountNamespace == accountNamespace &&
        job.productionId == productionId &&
        job.lineId == lineId;
    final superseded = [
      ..._pending.where(sameLine),
      ..._failed.where(sameLine),
    ];
    final deferredCleanupUrls = <String>[];
    for (final old in superseded) {
      deferredCleanupUrls.addAll(old.deferredCleanupUrls);
      final uploadedUrl = old.uploadedUrl;
      if (uploadedUrl != null) deferredCleanupUrls.add(uploadedUrl);
    }
    _pending.removeWhere(sameLine);
    _failed.removeWhere(sameLine);
    final job = SyncJob(
      id: recordingId,
      accountNamespace: accountNamespace,
      productionId: productionId,
      characterName: characterName,
      lineId: lineId,
      localPath: localPath,
      durationMs: durationMs,
      createdAt: DateTime.now(),
      recordedAt: recordedAt,
      deferredCleanupUrls: deferredCleanupUrls.toSet().toList(),
    );
    _pending.add(job);
    await _appendJob(job);
    if (!_processing) _processQueue();
  }

  Future<void> enqueueObjectCleanup(String remoteUrl) async {
    if (remoteUrl.isEmpty) return;
    await _restorePersisted();
    _cleanupUrls.add(remoteUrl);
    await _appendJournal({'op': 'cleanupAdd', 'url': remoteUrl});
    if (!_processing) _processQueue();
  }

  /// Process queued uploads and deferred object cleanup now.
  Future<void> processQueue() => _processQueue();

  Future<void> _processQueue() async {
    if (_processing || (_pending.isEmpty && _cleanupUrls.isEmpty)) return;
    _processing = true;
    if (!_uploader.isReady) {
      _processing = false;
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(seconds: 30), _processQueue);
      return;
    }

    final generation = _generation;
    while (true) {
      final jobIndex = _pending.indexWhere(
        (job) => job.accountNamespace == _uploader.accountNamespace,
      );
      if (jobIndex < 0) break;
      final job = _pending[jobIndex];
      bool isCurrent() => generation == _generation && _pending.contains(job);

      try {
        var url = job.uploadedUrl;
        if (url == null) {
          final file = File(job.localPath);
          final exists = await file.exists();
          if (generation != _generation) return;
          if (!exists) {
            await _appendRemove(job);
            if (!isCurrent()) continue;
            _pending.remove(job);
            continue;
          }
          final size = await file.length();
          if (generation != _generation) return;
          _dlog.log(
            LogCategory.network,
            'SyncQueue: uploading line=${job.lineId} '
            '${(size / 1024).toStringAsFixed(0)}KB '
            '(attempt ${job.retryCount + 1})',
          );
          url = await _uploader.upload(job);
          if (!isCurrent()) {
            _cleanupUrls.add(url);
            await _appendJournal({'op': 'cleanupAdd', 'url': url});
            continue;
          }
          job.uploadedUrl = url;
          await _appendJob(job);
          if (!isCurrent()) {
            // A replacement event serialized after this checkpoint transfers
            // the uploaded URL into durable cleanup before dropping the job.
            continue;
          }
        }

        if (!job.metadataSaved) {
          if (!_uploader.isReady) throw const _UploadPausedException();
          final previousUrl = await _uploader.saveMetadata(job, url);
          job.metadataSaved = true;
          final cleanupUrls = <String>{
            ...job.deferredCleanupUrls,
            if (previousUrl != null && previousUrl != url) previousUrl,
          }.toList();
          _cleanupUrls.addAll(cleanupUrls);
          job.deferredCleanupUrls.clear();
          await _appendJob(job, cleanupUrls: cleanupUrls);
        }
        if (!isCurrent()) continue;
        await _drainObjectCleanup();
        if (!isCurrent()) continue;

        final callback = onUploaded;
        if (callback != null) {
          await callback(job.productionId, job.lineId, job.id, url);
        }
        if (!isCurrent()) continue;

        await _appendRemove(job);
        if (!isCurrent()) continue;
        _pending.remove(job);
      } on _UploadPausedException {
        if (isCurrent()) {
          _pending.remove(job);
          _failed.add(job);
          await _appendJob(job);
        }
        break;
      } catch (e) {
        if (!isCurrent()) continue;
        _pending.remove(job);
        if (job.uploadedUrl != null) {
          if (job.publicationRetryCount < 6) {
            job.publicationRetryCount++;
          }
          _failed.add(job);
          await _appendJob(job);
          _dlog.logError(
            LogCategory.error,
            'SyncQueue: uploaded line=${job.lineId} has unfinished '
            'publication; retaining its durable URL checkpoint',
            e,
          );
          continue;
        }
        job.retryCount++;
        if (job.retryCount < 5) {
          _failed.add(job);
          await _appendJob(job);
          _dlog.logError(
            LogCategory.network,
            'SyncQueue: upload failed line=${job.lineId} '
            '(attempt ${job.retryCount}/5, will retry)',
            e,
          );
        } else {
          _dlog.logError(
            LogCategory.network,
            'SyncQueue: GAVE UP on line=${job.lineId} after 5 attempts',
            e,
          );
          onGaveUp?.call(job, e);
          await _appendRemove(job);
        }
      }
    }

    await _drainObjectCleanup();
    _processing = false;

    final hasActivePending = _pending.any(
      (job) => job.accountNamespace == _uploader.accountNamespace,
    );
    if (hasActivePending) {
      scheduleMicrotask(_processQueue);
      return;
    }
    if (_failed.isNotEmpty || _cleanupUrls.isNotEmpty) {
      final publicationBackoff = _failed.isEmpty
          ? 0
          : _failed
                .map((job) => job.publicationRetryCount)
                .reduce((a, b) => a > b ? a : b);
      final uploadBackoff = _failed.isEmpty
          ? 0
          : _failed
                .map((job) => job.retryCount)
                .reduce((a, b) => a > b ? a : b);
      final exponent = [
        publicationBackoff,
        uploadBackoff,
        _cleanupRetryCount,
      ].reduce((a, b) => a > b ? a : b).clamp(0, 6);
      _retryTimer?.cancel();
      _retryTimer = Timer(Duration(seconds: 2 << exponent), () {
        final account = _uploader.accountNamespace;
        final activeFailed = _failed
            .where((job) => job.accountNamespace == account)
            .toList();
        _failed.removeWhere((job) => job.accountNamespace == account);
        _pending.addAll(activeFailed);
        _processQueue();
      });
    }
  }

  Future<void> _drainObjectCleanup() async {
    if (_cleanupUrls.isEmpty) {
      _cleanupRetryCount = 0;
      return;
    }
    for (final url in _cleanupUrls.toList()) {
      try {
        await _uploader.deleteObject(url);
        await _appendJournal({'op': 'cleanupRemove', 'url': url});
        _cleanupUrls.remove(url);
      } catch (e) {
        _dlog.logError(
          LogCategory.network,
          'SyncQueue: superseded recording cleanup failed; retaining retry',
          e,
        );
      }
    }
    // Each successful removal is journaled independently above.
    _cleanupRetryCount = _cleanupUrls.isEmpty
        ? 0
        : (_cleanupRetryCount < 6 ? _cleanupRetryCount + 1 : 6);
  }

  Future<void> teardownAccount() async {
    _generation++;
    stop();
    _processing = false;
    onUploaded = null;
    onGaveUp = null;
    // Jobs and cleanup URLs are account-namespaced and remain durable. Signing
    // out must pause unsynced local work, never silently purge it.
    await _compactJournal();
  }

  /// Immediately retry failed jobs without waiting for the backoff timer.
  /// For tests.
  @visibleForTesting
  Future<void> retryNow() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _pending.addAll(_failed);
    _failed.clear();
    return _processQueue();
  }

  /// Clear all queue state. For tests.
  @visibleForTesting
  void reset() {
    _pending.clear();
    _failed.clear();
    _cleanupUrls.clear();
    _cleanupRetryCount = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
    _processing = false;
    _loaded = true;
    unawaited(
      _compactJournal().catchError((Object e) {
        _dlog.logError(LogCategory.error, 'SyncQueue: reset persist failed', e);
      }),
    );
  }
}
