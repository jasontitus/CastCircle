import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/script_models.dart';
import 'debug_log_service.dart';
import 'model_download_service.dart';
import 'on_device_llm_channel.dart';
import 'script_import_service.dart';
import 'tts_service.dart';

/// Owns a long-running AI script-cleanup job independent of any screen.
///
/// On-device structuring is slow (one model call per ~40-line chunk → minutes
/// for a full play), so the work must outlive the import screen: the user can
/// navigate away and come back to a finished result. This singleton holds the
/// running job, live progress, the final [result], and a [cancel] hook; the
/// import screen just subscribes and reflects [phase]/[chunkDone]/[chunkTotal].
///
/// iOS caveat: while the app is foregrounded the job runs to completion. If the
/// user leaves the app entirely, iOS suspends the inference and the job pauses
/// until they return — a [OnDeviceLlmChannel.beginBackgroundExecution] assertion
/// extends the grace window for brief switches but cannot run for minutes in the
/// background. A local notification fires when the job actually completes.
enum CleanupPhase { idle, running, done, cancelled, failed }

class ScriptAiCleanupController extends ChangeNotifier {
  ScriptAiCleanupController._();
  static final ScriptAiCleanupController instance =
      ScriptAiCleanupController._();

  /// How many chunks the LLM decodes in parallel per call. On-device decode is
  /// memory-bandwidth-bound, so higher N ≈ higher throughput — until the GPU
  /// becomes compute-bound or KV memory runs out. Tunable in the Script AI
  /// Debug screen; default 4.
  static const _batchSizeKey = 'ai_cleanup_batch_size';
  static const int defaultBatchSize = 4;
  static const int maxBatchSize = 8;

  Future<int> getBatchSize() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getInt(_batchSizeKey) ?? defaultBatchSize).clamp(1, maxBatchSize);
  }

  Future<void> setBatchSize(int n) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_batchSizeKey, n.clamp(1, maxBatchSize));
  }

  CleanupPhase _phase = CleanupPhase.idle;
  int _chunkDone = 0;
  int _chunkTotal = 0;
  bool _cancelRequested = false;
  ParsedScript? _result;
  Object? _error;

  /// The job's source identity, so a screen can tell whether a finished result
  /// belongs to the script it is currently showing.
  String? _jobTitle;

  /// The service backing the running job, kept so [cancel] can clear the
  /// on-disk checkpoint even if the native decode is wedged (see [cancel]).
  ScriptImportService? _service;

  // ETA tracking: timestamp + chunk index when this session's processing began
  // (after model load / a resume), so the estimate uses the live per-chunk rate.
  DateTime? _sessionStart;
  int _sessionFirstChunk = 0;

  CleanupPhase get phase => _phase;
  int get chunkDone => _chunkDone;
  int get chunkTotal => _chunkTotal;
  bool get isRunning => _phase == CleanupPhase.running;
  bool get cancelRequested => _cancelRequested;
  ParsedScript? get result => _result;
  Object? get error => _error;
  String? get jobTitle => _jobTitle;

  /// Estimated time remaining, from the average per-chunk time this session.
  /// Null until at least one chunk completes after the session start.
  Duration? get eta {
    final start = _sessionStart;
    if (start == null || _chunkTotal == 0) return null;
    final doneThisSession = _chunkDone - _sessionFirstChunk;
    if (doneThisSession < 1) return null;
    final elapsedMs = DateTime.now().difference(start).inMilliseconds;
    final perChunkMs = elapsedMs / doneThisSession;
    final remaining = _chunkTotal - _chunkDone;
    if (remaining <= 0) return Duration.zero;
    return Duration(milliseconds: (perChunkMs * remaining).round());
  }

  /// Live native step ("foundation: generating…", "gemma: 24 tokens", …).
  ValueListenable<String> get nativeProgress =>
      OnDeviceLlmChannel.instance.progress;

  /// Start a chunked cleanup. No-op (returns false) if one is already running.
  /// Results are kept on the controller; callers read [result] when [phase]
  /// becomes [CleanupPhase.done].
  Future<bool> start({
    required String rawText,
    required String title,
    required ScriptImportService service,
  }) async {
    if (_phase == CleanupPhase.running) return false;
    _phase = CleanupPhase.running;
    _chunkDone = 0;
    _chunkTotal = 0;
    _cancelRequested = false;
    _result = null;
    _error = null;
    _jobTitle = title;
    _service = service;
    _sessionStart = null;
    _sessionFirstChunk = 0;
    notifyListeners();

    final log = DebugLogService.instance;
    final llm = OnDeviceLlmChannel.instance;
    final tts = TtsService.instance;
    // Extend the background grace window so a quick app-switch mid-chunk does
    // not immediately suspend the process. Best-effort; iOS still caps it.
    await llm.beginBackgroundExecution('Script AI cleanup');

    // The 3.3 GB LLM and Kokoro's MLX model can't both be resident (the load
    // OOM-kills the app), so make the LLM the only big model: free Kokoro
    // first, then (re)initialize the LLM — it's disposed after each job, so a
    // fresh init is needed here. Kokoro reloads in `finally`.
    final kokoroWasLoaded = tts.isKokoroLoaded;
    if (kokoroWasLoaded) {
      log.log(LogCategory.ai, 'freeing Kokoro to make room for the LLM');
      await tts.unloadKokoro();
    }
    final dir = await ModelDownloadService.instance.getGemmaModelDir();
    await llm.initialize(dir ?? '');

    final batchSize = await getBatchSize();
    log.log(LogCategory.ai, 'cleanup batch size = $batchSize');

    try {
      final result = await service.structureWithAiChunked(
        rawText: rawText,
        title: title,
        batchSize: batchSize,
        onProgress: (done, total) {
          // Anchor ETA timing the first time progress arrives this session, so
          // the rate is measured over chunks completed *after* this point.
          if (_sessionStart == null) {
            _sessionStart = DateTime.now();
            _sessionFirstChunk = done;
          }
          _chunkDone = done;
          _chunkTotal = total;
          notifyListeners();
        },
        isCancelled: () => _cancelRequested,
      );

      if (_cancelRequested) {
        _phase = CleanupPhase.cancelled;
        log.log(LogCategory.ai, 'cleanup cancelled by user');
      } else if (result != null) {
        _result = result;
        _phase = CleanupPhase.done;
        final lines =
            result.lines.where((l) => l.lineType == LineType.dialogue).length;
        await llm.postLocalNotification(
          title: 'Script cleanup complete',
          body: '$title — ${result.characters.length} characters, $lines lines.',
        );
      } else {
        _phase = CleanupPhase.failed;
        _error = 'Script AI returned no usable result.';
        await llm.postLocalNotification(
          title: 'Script cleanup failed',
          body: 'Could not structure "$title". Tap to retry.',
        );
      }
    } catch (e) {
      _phase = CleanupPhase.failed;
      _error = e;
      log.logError(LogCategory.ai, 'cleanup job threw', e);
      await llm.postLocalNotification(
        title: 'Script cleanup failed',
        body: 'Error while cleaning "$title".',
      );
    } finally {
      // Free the multi-GB LLM so Kokoro (and the rest of the app) gets its
      // memory back, then restore Kokoro if we unloaded it.
      await llm.dispose();
      // Skip the Kokoro reload after a FAILED job: that failure is typically the
      // GPU/Metal stack wedging mid-run, and loading Kokoro's MLX model onto a
      // wedged Metal device can hard-crash the app. Leave TTS for the next launch
      // (fresh Metal state) — the cleanup auto-resumes from its checkpoint then.
      if (kokoroWasLoaded && _phase != CleanupPhase.failed) {
        log.log(LogCategory.ai, 'reloading Kokoro after cleanup');
        await tts.tryLoadKokoro();
      } else if (kokoroWasLoaded) {
        log.log(LogCategory.ai,
            'skipping Kokoro reload after failed cleanup (avoids MLX-on-wedged-Metal crash)');
      }
      await llm.endBackgroundExecution();
      notifyListeners();
    }
    return true;
  }

  /// If an earlier cleanup was interrupted (app killed mid-run), restart it
  /// from its checkpoint using the persisted source text. Returns true if a
  /// resume was kicked off. Call when re-entering the app/import screen.
  Future<bool> resumeIfPending(ScriptImportService service) async {
    if (_phase == CleanupPhase.running) return false;
    final pending = await service.pendingCleanup();
    if (pending == null) return false;
    // A checkpoint that has burned its auto-resume budget can never finish —
    // discard it here, before any heavyweight model load, rather than relaunch
    // the cleanup every time this screen opens (the loop that made a
    // cancelled/failed job impossible to stop).
    if (await service.pendingCleanupExhausted()) {
      DebugLogService.instance.log(LogCategory.ai,
          'pending cleanup exhausted its resume budget — discarding checkpoint');
      await service.clearPendingCleanup();
      return false;
    }
    DebugLogService.instance
        .log(LogCategory.ai, 'resuming interrupted cleanup from checkpoint');
    // Fire-and-forget: structureChunked picks up from the checkpoint; listeners
    // reflect progress. Don't await — let the caller's UI stay responsive.
    unawaited(start(
      rawText: pending.rawText,
      title: pending.title,
      service: service,
    ));
    return true;
  }

  /// Request cancellation; the job stops cleanly after the current chunk.
  ///
  /// Cancel means stop, not pause: also clear the on-disk checkpoint directly.
  /// Normally `structureChunked` deletes it when the loop unwinds, but if the
  /// native decode is wedged and never returns, that cleanup never runs — and
  /// without this the cancelled job would relaunch from its checkpoint on the
  /// next import-screen visit. Clearing here makes cancel always stick.
  void cancel() {
    if (_phase != CleanupPhase.running) return;
    _cancelRequested = true;
    final service = _service;
    if (service != null) unawaited(service.clearPendingCleanup());
    notifyListeners();
  }

  /// Clear a finished result once a screen has consumed it, returning to idle.
  void acknowledge() {
    if (_phase == CleanupPhase.running) return;
    _phase = CleanupPhase.idle;
    _result = null;
    _error = null;
    _jobTitle = null;
    _chunkDone = 0;
    _chunkTotal = 0;
    notifyListeners();
  }
}
