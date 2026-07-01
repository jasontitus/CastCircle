import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import 'debug_log_service.dart';
import 'supabase_service.dart';

/// A pending upload job in the sync queue.
class SyncJob {
  final String id;
  final String productionId;
  final String characterName;
  final String lineId;
  final String localPath;
  final int durationMs;
  final DateTime createdAt;

  /// When the audio was actually recorded (used for freshness comparison
  /// on other devices). Falls back to [createdAt].
  final DateTime recordedAt;
  int retryCount;

  SyncJob({
    required this.id,
    required this.productionId,
    required this.characterName,
    required this.lineId,
    required this.localPath,
    required this.durationMs,
    required this.createdAt,
    DateTime? recordedAt,
    this.retryCount = 0,
  }) : recordedAt = recordedAt ?? createdAt;
}

/// Abstraction over the cloud upload calls so the queue can be tested
/// without a live Supabase client.
abstract class RecordingUploader {
  /// Whether uploads can proceed (e.g. signed in).
  bool get isReady;

  /// Upload the audio file and return its remote URL.
  Future<String> upload(SyncJob job);

  /// Persist recording metadata after a successful upload.
  Future<void> saveMetadata(SyncJob job, String remoteUrl);
}

class _SupabaseUploader implements RecordingUploader {
  @override
  bool get isReady {
    final supa = SupabaseService.instance;
    return supa.isInitialized && supa.isSignedIn;
  }

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
}

/// Offline-first sync queue for uploading recordings to Supabase.
///
/// Recordings are saved locally first (source of truth), then queued
/// for upload when connectivity is available. Failed uploads are
/// retried with exponential backoff.
class SyncQueue {
  SyncQueue._() : _uploader = _SupabaseUploader();

  @visibleForTesting
  SyncQueue.forTesting(this._uploader);

  static final instance = SyncQueue._();

  final RecordingUploader _uploader;
  final _dlog = DebugLogService.instance;

  final List<SyncJob> _pending = [];
  final List<SyncJob> _failed = [];
  Timer? _retryTimer;
  StreamSubscription? _connectivitySub;
  bool _processing = false;

  List<SyncJob> get pending => List.unmodifiable(_pending);
  List<SyncJob> get failed => List.unmodifiable(_failed);
  int get pendingCount => _pending.length + _failed.length;

  /// Called after a successful upload with (productionId, lineId, remoteUrl).
  /// Used to persist the remote URL on the local recording so the app
  /// knows the upload completed.
  void Function(String productionId, String lineId, String remoteUrl)?
      onUploaded;

  /// Called when a job is abandoned after exhausting all retries.
  void Function(SyncJob job, Object error)? onGaveUp;

  /// Start monitoring connectivity and processing the queue.
  void start() {
    _connectivitySub?.cancel();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasConnection = results.any((r) => r != ConnectivityResult.none);
      if (hasConnection && !_processing) {
        _processQueue();
      }
    });
  }

  /// Stop monitoring and cancel pending retries.
  void stop() {
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// Enqueue a recording for upload.
  ///
  /// If a job for the same production/line is already queued (pending or
  /// failed), it is replaced — the newest take wins and retry counts reset.
  void enqueue({
    required String productionId,
    required String characterName,
    required String lineId,
    required String localPath,
    required int durationMs,
    DateTime? recordedAt,
  }) {
    bool sameLine(SyncJob j) =>
        j.productionId == productionId && j.lineId == lineId;
    final replaced = _pending.any(sameLine) || _failed.any(sameLine);
    _pending.removeWhere(sameLine);
    _failed.removeWhere(sameLine);

    _pending.add(SyncJob(
      id: '${productionId}_${lineId}_${DateTime.now().millisecondsSinceEpoch}',
      productionId: productionId,
      characterName: characterName,
      lineId: lineId,
      localPath: localPath,
      durationMs: durationMs,
      createdAt: DateTime.now(),
      recordedAt: recordedAt,
    ));

    _dlog.log(
        LogCategory.network,
        'SyncQueue: queued upload line=$lineId char="$characterName" '
        '${durationMs}ms${replaced ? ' (replaced prior take)' : ''} '
        '— ${_pending.length} pending, ${_failed.length} failed');

    if (!_processing) _processQueue();
  }

  /// Process all pending jobs immediately. Exposed for tests; production
  /// code relies on [enqueue]/connectivity triggers.
  @visibleForTesting
  Future<void> processQueue() => _processQueue();

  Future<void> _processQueue() async {
    if (_processing || _pending.isEmpty) return;
    _processing = true;

    if (!_uploader.isReady) {
      _dlog.log(
          LogCategory.network,
          'SyncQueue: not uploading — cloud not ready (offline or signed out); '
          '${_pending.length} pending will retry in 30s');
      _processing = false;
      // Signing in on a stable connection fires no connectivity event, so
      // poll until the uploader becomes ready.
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(seconds: 30), _processQueue);
      return;
    }

    _dlog.log(LogCategory.network,
        'SyncQueue: processing ${_pending.length} pending upload(s)');

    while (_pending.isNotEmpty) {
      final job = _pending.first;

      try {
        final file = File(job.localPath);
        if (!file.existsSync()) {
          // File deleted locally — drop the job
          _dlog.log(LogCategory.network,
              'SyncQueue: dropped line=${job.lineId} — local file gone (${job.localPath})');
          _pending.remove(job);
          continue;
        }

        final sizeKb = (file.lengthSync() / 1024).toStringAsFixed(0);
        _dlog.log(
            LogCategory.network,
            'SyncQueue: uploading line=${job.lineId} char="${job.characterName}" '
            '${sizeKb}KB (attempt ${job.retryCount + 1})');
        final url = await _uploader.upload(job);
        await _uploader.saveMetadata(job, url);

        // enqueue() may have replaced this job with a newer take while the
        // upload was in flight — remove() then misses, and the newer take's
        // local recording must NOT be stamped with this stale URL (a non-null
        // remoteUrl would exclude it from every future sync).
        final superseded = !_pending.remove(job);
        _dlog.log(
            LogCategory.network,
            'SyncQueue: uploaded line=${job.lineId} → $url'
            '${superseded ? ' (superseded by a newer take, not marking local)' : ''}');
        if (!superseded) {
          onUploaded?.call(job.productionId, job.lineId, url);
        }
      } catch (e) {
        final superseded = !_pending.remove(job);
        if (superseded) {
          // A newer take for this line is already queued; let it drive the
          // retry instead of resurrecting this job.
          _dlog.log(
              LogCategory.network,
              'SyncQueue: upload failed line=${job.lineId} but a newer take '
              'is queued — dropping the old job');
          continue;
        }
        job.retryCount++;

        if (job.retryCount < 5) {
          _dlog.logError(
              LogCategory.network,
              'SyncQueue: upload failed line=${job.lineId} '
              '(attempt ${job.retryCount}/5, will retry)',
              e);
          _failed.add(job);
        } else {
          _dlog.logError(
              LogCategory.network,
              'SyncQueue: GAVE UP on line=${job.lineId} after 5 attempts — '
              'this recording will not reach castmates until re-recorded',
              e);
          onGaveUp?.call(job, e);
        }
      }
    }

    _processing = false;

    // An enqueue() that landed between the loop's last emptiness check and
    // the flag reset above saw _processing == true and skipped its kick —
    // pick those jobs up now.
    if (_pending.isNotEmpty) {
      scheduleMicrotask(_processQueue);
      return;
    }

    // Schedule retry for failed jobs with exponential backoff
    if (_failed.isNotEmpty) {
      final nextRetry = _failed.first;
      final delay = Duration(seconds: 2 << nextRetry.retryCount.clamp(0, 4));
      _dlog.log(
          LogCategory.network,
          'SyncQueue: ${_failed.length} failed upload(s); retrying in '
          '${delay.inSeconds}s');
      _retryTimer?.cancel();
      _retryTimer = Timer(delay, () {
        _pending.addAll(_failed);
        _failed.clear();
        _processQueue();
      });
    }
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
    _retryTimer?.cancel();
    _retryTimer = null;
    _processing = false;
  }
}
