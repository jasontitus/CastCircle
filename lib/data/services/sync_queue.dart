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
  int retryCount;

  SyncJob({
    required this.id,
    required this.productionId,
    required this.characterName,
    required this.lineId,
    required this.localPath,
    required this.durationMs,
    required this.createdAt,
    this.retryCount = 0,
  });
}

/// Offline-first sync queue for uploading recordings to Supabase.
///
/// Recordings are saved locally first (source of truth), then queued
/// for upload when connectivity is available. Failed uploads are
/// retried with exponential backoff.
class SyncQueue {
  SyncQueue._();
  static final instance = SyncQueue._();

  final List<SyncJob> _pending = [];
  final List<SyncJob> _failed = [];
  Timer? _retryTimer;
  StreamSubscription? _connectivitySub;
  bool _processing = false;

  List<SyncJob> get pending => List.unmodifiable(_pending);
  List<SyncJob> get failed => List.unmodifiable(_failed);
  int get pendingCount => _pending.length + _failed.length;

  /// Called after a successful upload with (lineId, remoteUrl).
  void Function(String lineId, String remoteUrl)? onUploaded;

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
  void enqueue({
    required String productionId,
    required String characterName,
    required String lineId,
    required String localPath,
    required int durationMs,
  }) {
    // Don't duplicate
    final exists = _pending.any((j) =>
        j.productionId == productionId && j.lineId == lineId);
    if (exists) return;

    _pending.add(SyncJob(
      id: '${productionId}_${lineId}_${DateTime.now().millisecondsSinceEpoch}',
      productionId: productionId,
      characterName: characterName,
      lineId: lineId,
      localPath: localPath,
      durationMs: durationMs,
      createdAt: DateTime.now(),
    ));

    if (!_processing) _processQueue();
  }

  /// Process all pending jobs.
  Future<void> _processQueue() async {
    if (_processing || _pending.isEmpty) return;
    _processing = true;

    final supa = SupabaseService.instance;
    if (!supa.isSignedIn) {
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

        final url = await supa.uploadRecording(
          productionId: job.productionId,
          characterName: job.characterName,
          lineId: job.lineId,
          audioFile: file,
        );

        await supa.saveRecordingMetadata(
          productionId: job.productionId,
          lineId: job.lineId,
          userId: supa.currentUser!.id,
          audioUrl: url,
          durationMs: job.durationMs,
        );

        _pending.removeAt(0);
        debugPrint('SyncQueue: Uploaded ${job.lineId}');
        onUploaded?.call(job.lineId, url);
      } catch (e) {
        debugPrint('SyncQueue: Failed ${job.lineId} (attempt ${job.retryCount + 1}): $e');
        job.retryCount++;
        _pending.removeAt(0);

        if (job.retryCount < 5) {
          _failed.add(job);
        } else {
          debugPrint('SyncQueue: Giving up on ${job.lineId} after 5 attempts');
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
}
