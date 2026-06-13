import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

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
      _processing = false;
      return;
    }

    while (_pending.isNotEmpty) {
      final job = _pending.first;

      try {
        final file = File(job.localPath);
        if (!file.existsSync()) {
          // File deleted locally — drop the job
          _pending.removeAt(0);
          continue;
        }

        final url = await _uploader.upload(job);
        await _uploader.saveMetadata(job, url);

        _pending.removeAt(0);
        debugPrint('SyncQueue: Uploaded ${job.lineId}');
        onUploaded?.call(job.productionId, job.lineId, url);
      } catch (e) {
        debugPrint(
            'SyncQueue: Failed ${job.lineId} (attempt ${job.retryCount + 1}): $e');
        job.retryCount++;
        _pending.removeAt(0);

        if (job.retryCount < 5) {
          _failed.add(job);
        } else {
          debugPrint('SyncQueue: Giving up on ${job.lineId} after 5 attempts');
          onGaveUp?.call(job, e);
        }
      }
    }

    _processing = false;

    // Schedule retry for failed jobs with exponential backoff
    if (_failed.isNotEmpty) {
      final nextRetry = _failed.first;
      final delay = Duration(seconds: 2 << nextRetry.retryCount.clamp(0, 4));
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
