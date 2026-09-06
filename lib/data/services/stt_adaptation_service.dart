import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/widgets.dart';

import 'debug_log_service.dart';

/// Training sample: an audio clip paired with its transcript.
class TrainingSample {
  final String audioPath;
  final String transcript;
  final String character;
  final int durationMs;
  final DateTime recordedAt;

  const TrainingSample({
    required this.audioPath,
    required this.transcript,
    required this.character,
    required this.durationMs,
    required this.recordedAt,
  });

  Map<String, dynamic> toJson() => {
    'audio_path': audioPath,
    'transcript': transcript,
    'character': character,
    'duration_ms': durationMs,
    'recorded_at': recordedAt.toIso8601String(),
  };

  factory TrainingSample.fromJson(Map<String, dynamic> json) => TrainingSample(
    audioPath: json['audio_path'] as String,
    transcript: json['transcript'] as String,
    character: json['character'] as String,
    durationMs: json['duration_ms'] as int,
    recordedAt: DateTime.parse(json['recorded_at'] as String),
  );
}

/// Per-actor STT adaptation profile.
///
/// Stores training samples and tracks LoRA adapter state for a specific
/// actor's voice. Each profile can produce a personalized Whisper model
/// that better recognizes that person's speech patterns.
class SttProfile {
  final String actorId; // character name or user ID
  final String productionId;
  final List<TrainingSample> samples;
  final int? _cachedDurationMs;
  final SttAdaptationStatus status;
  final String? adapterPath; // path to LoRA adapter weights
  final DateTime? lastTrainedAt;
  final double? wordErrorRate; // WER on validation set, if measured

  const SttProfile({
    required this.actorId,
    required this.productionId,
    required this.samples,
    int? totalDurationMs,
    this.status = SttAdaptationStatus.needsData,
    this.adapterPath,
    this.lastTrainedAt,
    this.wordErrorRate,
  }) : _cachedDurationMs = totalDurationMs;

  /// Total duration of retained training audio.
  int get totalDurationMs =>
      _cachedDurationMs ??
      samples.fold<int>(0, (sum, sample) => sum + sample.durationMs);

  double get totalAudioSeconds => totalDurationMs / 1000.0;

  /// Minimum audio needed for useful adaptation (60 seconds).
  static const double minAudioSeconds = 60.0;

  /// Recommended audio for good adaptation (5 minutes).
  static const double recommendedAudioSeconds = 300.0;

  /// Readiness score: 0.0 = no data, 1.0 = recommended amount reached.
  double get readiness =>
      (totalAudioSeconds / recommendedAudioSeconds).clamp(0.0, 1.0);

  /// Whether we have enough data to attempt training.
  bool get hasEnoughData => totalAudioSeconds >= minAudioSeconds;

  SttProfile copyWith({
    String? actorId,
    String? productionId,
    List<TrainingSample>? samples,
    int? totalDurationMs,
    SttAdaptationStatus? status,
    String? adapterPath,
    DateTime? lastTrainedAt,
    double? wordErrorRate,
  }) {
    final nextSamples = samples ?? this.samples;
    return SttProfile(
      actorId: actorId ?? this.actorId,
      productionId: productionId ?? this.productionId,
      samples: nextSamples,
      totalDurationMs:
          totalDurationMs ??
          (samples == null
              ? _cachedDurationMs
              : nextSamples.fold<int>(
                  0,
                  (sum, sample) => sum + sample.durationMs,
                )),
      status: status ?? this.status,
      adapterPath: adapterPath ?? this.adapterPath,
      lastTrainedAt: lastTrainedAt ?? this.lastTrainedAt,
      wordErrorRate: wordErrorRate ?? this.wordErrorRate,
    );
  }
}

/// Status of STT adaptation for a given actor.
enum SttAdaptationStatus {
  needsData, // not enough training samples
  readyToTrain, // enough data, awaiting training
  training, // LoRA fine-tune in progress (cloud)
  trained, // adapter available for inference
  failed, // training failed
}

/// Manages per-actor and per-production STT adaptation.
///
/// Architecture (two-tier):
///
/// **Per-Actor LoRA** (ideal, requires more data):
///   - Collects 1-5 minutes of transcribed audio per actor
///   - Sends to cloud for Whisper LoRA fine-tuning (~15 min on GPU)
///   - Downloads tiny adapter weights (~5-10MB) back to device
///   - WhisperKit loads base model + per-actor LoRA at inference time
///   - Result: STT tuned to each person's voice, accent, cadence
///
/// **Per-Production Fine-Tune** (fallback, less data per person):
///   - Pools all cast recordings into one training set
///   - Fine-tunes on the production's vocabulary + all voices together
///   - Single adapter shared across all actors in the production
///   - Result: STT tuned to the play's language and the cast generally
///
/// The service automatically decides which strategy to use based on
/// how much per-actor data is available.
class SttAdaptationService with WidgetsBindingObserver {
  SttAdaptationService._();
  static final instance = SttAdaptationService._();

  /// Per-actor profiles, keyed by "productionId:actorId".
  final Map<String, SttProfile> _actorProfiles = {};

  /// Per-production pooled profile, keyed by productionId.
  final Map<String, SttProfile> _productionProfiles = {};

  // ── Persistence ────────────────────────────────────────
  //
  // Profiles used to be memory-only: every collected sample, status and
  // adapter path vanished on restart, so an actor could never accumulate
  // the 60s+ needed for readyToTrain across sessions. Profiles now persist
  // as JSON under the production's adapter dir and hydrate lazily.

  final Map<String, Future<void>> _hydrations = {};
  final Set<String> _failedHydrations = {};
  Timer? _persistDebounce;
  Future<void>? _flushInFlight;
  bool _flushAgain = false;
  final Map<String, int> _dirtyProductions = {};
  final _dlog = DebugLogService.instance;
  String? _persistenceWarning;
  bool _observesLifecycle = false;

  /// Register lifecycle flushing after Flutter has installed its binding.
  /// Construction stays binding-free so the singleton is safe in tests and
  /// during pre-runApp service initialization.
  void initializeLifecycle() {
    if (_observesLifecycle) return;
    WidgetsBinding.instance.addObserver(this);
    _observesLifecycle = true;
  }

  /// Last durable-write failure, if any. Calling [flush] retries dirty data.
  String? get persistenceWarning => _persistenceWarning;

  /// Hydrate a production's profiles from disk (idempotent, lazy).
  Future<void> ensureLoaded(String productionId) =>
      _hydrations[productionId] ??= _loadProduction(productionId);

  Future<void> _loadProduction(String productionId) async {
    try {
      final file = File(
        p.join(await _adapterDir(productionId), 'profiles.json'),
      );
      if (!await file.exists()) {
        _failedHydrations.remove(productionId);
        return;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        throw const FormatException('profile root is not an object');
      }
      final data = Map<String, dynamic>.from(decoded);
      final actors = data['actors'];
      if (actors != null && actors is! List) {
        throw const FormatException('actors is not a list');
      }

      for (final entry in actors as List? ?? const []) {
        final profile = await _decodeProfile(entry, productionId);
        if (profile == null || profile.actorId.isEmpty) continue;
        final key = '$productionId:${profile.actorId}';
        _actorProfiles[key] = _mergeProfiles(profile, _actorProfiles[key]);
      }
      final production = await _decodeProfile(data['production'], productionId);
      if (production != null) {
        _productionProfiles[productionId] = _mergeProfiles(
          production,
          _productionProfiles[productionId],
        );
      }
      _failedHydrations.remove(productionId);
    } catch (e, stack) {
      _failedHydrations.add(productionId);
      _dlog.logError(
        LogCategory.stt,
        'SttAdaptation: hydrate failed for $productionId; '
        'refusing to replace its snapshot',
        e,
        stack,
      );
    }
  }

  Future<SttProfile?> _decodeProfile(dynamic value, String productionId) async {
    if (value == null) return null;
    if (value is! Map) {
      _dlog.logError(
        LogCategory.stt,
        'SttAdaptation: skipped malformed profile entry',
      );
      return null;
    }

    try {
      final data = Map<String, dynamic>.from(value);
      final rawSamples = data['samples'];
      if (rawSamples != null && rawSamples is! List) {
        throw const FormatException('samples is not a list');
      }
      final decodedNewestFirst = <TrainingSample>[];
      var malformedSamples = 0;
      // Legacy snapshots may be unbounded. Walk newest-first and stop as soon
      // as the retained cap is full, rather than creating one Future and file
      // metadata request for every historical entry.
      for (final sampleJson in (rawSamples as List? ?? const []).reversed) {
        if (decodedNewestFirst.length >= _maxSamplesPerProfile) break;
        try {
          if (sampleJson is! Map) {
            throw const FormatException('sample is not an object');
          }
          final sample = TrainingSample.fromJson(
            Map<String, dynamic>.from(sampleJson),
          );
          if (await File(sample.audioPath).exists()) {
            decodedNewestFirst.add(sample);
          }
        } catch (_) {
          malformedSamples++;
        }
      }
      if (malformedSamples > 0) {
        _dlog.logError(
          LogCategory.stt,
          'SttAdaptation: skipped $malformedSamples malformed training samples',
        );
      }
      final samples = List<TrainingSample>.unmodifiable(
        decodedNewestFirst.reversed,
      );
      return SttProfile(
        actorId: data['actor_id'] as String? ?? '',
        productionId: productionId,
        samples: samples,
        totalDurationMs: _sampleDurationMs(samples),
        status:
            SttAdaptationStatus.values.asNameMap()[data['status'] as String? ??
                ''] ??
            SttAdaptationStatus.needsData,
        adapterPath: data['adapter_path'] as String?,
        lastTrainedAt: DateTime.tryParse(
          data['last_trained_at'] as String? ?? '',
        ),
        wordErrorRate: (data['wer'] as num?)?.toDouble(),
      );
    } catch (e) {
      _dlog.logError(
        LogCategory.stt,
        'SttAdaptation: skipped malformed profile',
        e,
      );
      return null;
    }
  }

  SttProfile _mergeProfiles(SttProfile disk, SttProfile? live) {
    if (live == null) return disk;
    final livePaths = {for (final sample in live.samples) sample.audioPath};
    final samples = _trimSamples([
      ...disk.samples.where((sample) => !livePaths.contains(sample.audioPath)),
      ...live.samples,
    ]);
    final merged = live.copyWith(
      samples: samples,
      totalDurationMs: _sampleDurationMs(samples),
      adapterPath: live.adapterPath ?? disk.adapterPath,
      lastTrainedAt: live.lastTrainedAt ?? disk.lastTrainedAt,
      wordErrorRate: live.wordErrorRate ?? disk.wordErrorRate,
    );
    return merged.copyWith(
      status: _computeStatus(merged.totalAudioSeconds, merged.adapterPath),
    );
  }

  void _schedulePersist(String productionId) {
    _dirtyProductions[productionId] =
        (_dirtyProductions[productionId] ?? 0) + 1;
    if (_flushInFlight != null) _flushAgain = true;
    _persistDebounce?.cancel();
    _persistDebounce = Timer(
      const Duration(seconds: 2),
      () => unawaited(flush()),
    );
  }

  /// Persist every dirty production now. Failed writes remain dirty so callers
  /// or a later lifecycle transition can retry without losing samples.
  Future<void> flush() {
    if (_flushInFlight != null) {
      _flushAgain = true;
      return _flushInFlight!;
    }
    late final Future<void> future;
    future = _flushUntilSettled().whenComplete(() {
      if (identical(_flushInFlight, future)) _flushInFlight = null;
    });
    return _flushInFlight = future;
  }

  Future<void> _flushUntilSettled() async {
    do {
      _flushAgain = false;
      await _flushDirty();
    } while (_flushAgain);
  }

  /// Retry hydration failures first, then retry every pending write.
  Future<void> retryPersistence() async {
    final failed = _failedHydrations
        .where(_dirtyProductions.containsKey)
        .toList(growable: false);
    for (final productionId in failed) {
      _hydrations.remove(productionId);
      await ensureLoaded(productionId);
    }
    await flush();
  }

  Future<void> _flushDirty() async {
    _persistDebounce?.cancel();
    _persistDebounce = null;
    final dirty = _dirtyProductions.entries.toList(growable: false);
    await Future.wait([
      for (final entry in dirty) _persistProduction(entry.key, entry.value),
    ]);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(flush());
    }
  }

  Future<void> _persistProduction(String productionId, int version) async {
    try {
      await ensureLoaded(productionId);
      if (_failedHydrations.contains(productionId)) {
        throw StateError('existing profile snapshot could not be hydrated');
      }

      Map<String, dynamic> encode(SttProfile profile) => {
        'actor_id': profile.actorId,
        'samples': profile.samples.map((sample) => sample.toJson()).toList(),
        'status': profile.status.name,
        'adapter_path': profile.adapterPath,
        'last_trained_at': profile.lastTrainedAt?.toIso8601String(),
        'wer': profile.wordErrorRate,
      };
      final payload = <String, dynamic>{
        'actors': [
          for (final entry in _actorProfiles.entries)
            if (entry.key.startsWith('$productionId:')) encode(entry.value),
        ],
        'production': _productionProfiles[productionId] == null
            ? null
            : encode(_productionProfiles[productionId]!),
      };
      final snapshot = await compute(_encodeProfileSnapshot, payload);
      final path = p.join(await _adapterDir(productionId), 'profiles.json');
      final tmp = File('$path.tmp');
      await tmp.writeAsString(snapshot, flush: true);
      await tmp.rename(path);
      if (_dirtyProductions[productionId] == version) {
        _dirtyProductions.remove(productionId);
      }
      if (_dirtyProductions.isEmpty) _persistenceWarning = null;
    } catch (e, stack) {
      _persistenceWarning =
          'Could not save speech adaptation data for $productionId';
      _dlog.logError(LogCategory.stt, _persistenceWarning!, e, stack);
    }
  }

  // ── Profile Management ─────────────────────────────────

  /// Get per-actor profile, creating if needed.
  SttProfile getActorProfile(String productionId, String actorId) {
    final key = '$productionId:$actorId';
    return _actorProfiles[key] ??
        SttProfile(
          actorId: actorId,
          productionId: productionId,
          samples: const [],
          totalDurationMs: 0,
        );
  }

  /// Get per-production pooled profile.
  SttProfile getProductionProfile(String productionId) {
    return _productionProfiles[productionId] ??
        SttProfile(
          actorId: '_production',
          productionId: productionId,
          samples: const [],
          totalDurationMs: 0,
        );
  }

  /// Get all actor profiles for a production.
  List<SttProfile> getProductionActorProfiles(String productionId) {
    return _actorProfiles.entries
        .where((e) => e.key.startsWith('$productionId:'))
        .map((e) => e.value)
        .toList();
  }

  // ── Training Data Collection ───────────────────────────

  /// Add a training sample from a recording. Called automatically when
  /// a cast member records a line — the recording + its transcript
  /// become training data for STT adaptation.
  void addSample({
    required String productionId,
    required String actorId,
    required String audioPath,
    required String transcript,
    required int durationMs,
  }) {
    // Kick hydration so samples from previous runs merge in (they combine
    // by audioPath, so adding before the disk snapshot lands is safe).
    unawaited(ensureLoaded(productionId));
    final sample = TrainingSample(
      audioPath: audioPath,
      transcript: transcript,
      character: actorId,
      durationMs: durationMs,
      recordedAt: DateTime.now(),
    );

    // Add to per-actor profile
    final actorKey = '$productionId:$actorId';
    final actorProfile =
        _actorProfiles[actorKey] ??
        SttProfile(
          actorId: actorId,
          productionId: productionId,
          samples: const [],
          totalDurationMs: 0,
        );
    final actorAppend = _appendSample(actorProfile, sample);
    final actorSeconds = actorAppend.durationMs / 1000.0;
    _actorProfiles[actorKey] = actorProfile.copyWith(
      samples: actorAppend.samples,
      totalDurationMs: actorAppend.durationMs,
      status: _computeStatus(actorSeconds, actorProfile.adapterPath),
    );

    // Also add to pooled production profile
    final prodProfile =
        _productionProfiles[productionId] ??
        SttProfile(
          actorId: '_production',
          productionId: productionId,
          samples: const [],
          totalDurationMs: 0,
        );
    final productionAppend = _appendSample(prodProfile, sample);
    _productionProfiles[productionId] = prodProfile.copyWith(
      samples: productionAppend.samples,
      totalDurationMs: productionAppend.durationMs,
      status: _computeStatus(
        productionAppend.durationMs / 1000.0,
        prodProfile.adapterPath,
      ),
    );

    debugPrint(
      'SttAdaptation: Added sample for $actorId '
      '(${actorAppend.samples.length} samples, '
      '${actorSeconds.toStringAsFixed(0)}s total)',
    );
    _schedulePersist(productionId);
  }

  static const _maxSamplesPerProfile = 500;

  static List<TrainingSample> _trimSamples(List<TrainingSample> samples) {
    final first = samples.length > _maxSamplesPerProfile
        ? samples.length - _maxSamplesPerProfile
        : 0;
    return List<TrainingSample>.unmodifiable(samples.skip(first));
  }

  static int _sampleDurationMs(Iterable<TrainingSample> samples) =>
      samples.fold<int>(0, (sum, sample) => sum + sample.durationMs);

  static ({List<TrainingSample> samples, int durationMs}) _appendSample(
    SttProfile profile,
    TrainingSample sample,
  ) {
    final evictedDuration = profile.samples.length >= _maxSamplesPerProfile
        ? profile.samples.first.durationMs
        : 0;
    final samples = profile.samples.length >= _maxSamplesPerProfile
        ? [...profile.samples.skip(1), sample]
        : [...profile.samples, sample];
    return (
      samples: List<TrainingSample>.unmodifiable(samples),
      durationMs: profile.totalDurationMs + sample.durationMs - evictedDuration,
    );
  }

  SttAdaptationStatus _computeStatus(
    double totalSeconds,
    String? existingAdapter,
  ) {
    if (existingAdapter != null) return SttAdaptationStatus.trained;
    if (totalSeconds >= SttProfile.minAudioSeconds) {
      return SttAdaptationStatus.readyToTrain;
    }
    return SttAdaptationStatus.needsData;
  }

  // ── Training ───────────────────────────────────────────

  /// Decide the best training strategy for a production.
  TrainingStrategy recommendStrategy(String productionId) {
    final actorProfiles = getProductionActorProfiles(productionId);
    final prodProfile = getProductionProfile(productionId);

    // Count actors with enough solo data
    final actorsReady = actorProfiles.where((p) => p.hasEnoughData).length;

    if (actorsReady >= actorProfiles.length && actorProfiles.isNotEmpty) {
      // Every actor has enough solo data — train per-actor LoRAs
      return TrainingStrategy.perActor;
    } else if (prodProfile.hasEnoughData) {
      // Pooled production data is enough — train one shared adapter
      return TrainingStrategy.perProduction;
    } else {
      // Not enough data yet
      return TrainingStrategy.notReady;
    }
  }

  /// Request training for a specific actor's LoRA adapter.
  /// Returns immediately — training happens asynchronously in the cloud.
  Future<void> requestActorTraining({
    required String productionId,
    required String actorId,
  }) async {
    final key = '$productionId:$actorId';
    final profile = _actorProfiles[key];
    if (profile == null || !profile.hasEnoughData) return;

    _actorProfiles[key] = profile.copyWith(
      status: SttAdaptationStatus.training,
    );

    try {
      // Phase 1: Cloud training
      // POST /api/stt/train
      // Body: {
      //   production_id, actor_id,
      //   samples: [{audio_url, transcript}...],
      //   base_model: "whisper-small",
      //   strategy: "lora",
      //   lora_rank: 8,
      // }
      // Response: { job_id, estimated_time_minutes }
      //
      // Phase 2: Poll for completion, download adapter
      // GET /api/stt/train/{job_id}
      // Response: { status: "complete", adapter_url: "..." }

      debugPrint(
        'SttAdaptation: Would train LoRA for $actorId '
        '(${profile.samples.length} samples, '
        '${profile.totalAudioSeconds.toStringAsFixed(0)}s audio)',
      );

      // Placeholder: mark as not yet trained
      _actorProfiles[key] = profile.copyWith(
        status: SttAdaptationStatus.readyToTrain,
      );
    } catch (e) {
      _actorProfiles[key] = profile.copyWith(
        status: SttAdaptationStatus.failed,
      );
      debugPrint('SttAdaptation: Training failed for $actorId: $e');
    }
  }

  /// Request training for a pooled production adapter.
  Future<void> requestProductionTraining({required String productionId}) async {
    final profile = _productionProfiles[productionId];
    if (profile == null || !profile.hasEnoughData) return;

    _productionProfiles[productionId] = profile.copyWith(
      status: SttAdaptationStatus.training,
    );

    try {
      debugPrint(
        'SttAdaptation: Would train production LoRA '
        '(${profile.samples.length} samples from all actors, '
        '${profile.totalAudioSeconds.toStringAsFixed(0)}s audio)',
      );

      _productionProfiles[productionId] = profile.copyWith(
        status: SttAdaptationStatus.readyToTrain,
      );
    } catch (e) {
      _productionProfiles[productionId] = profile.copyWith(
        status: SttAdaptationStatus.failed,
      );
    }
  }

  // ── Inference ──────────────────────────────────────────

  /// Get the best available adapter path for recognizing a specific actor.
  /// Prefers per-actor adapter, falls back to production adapter.
  String? getBestAdapter(String productionId, String actorId) {
    // Try per-actor first
    final actorKey = '$productionId:$actorId';
    final actorProfile = _actorProfiles[actorKey];
    if (actorProfile?.adapterPath != null) return actorProfile!.adapterPath;

    // Fall back to production adapter
    final prodProfile = _productionProfiles[productionId];
    return prodProfile?.adapterPath;
  }

  /// Get the adapter path for a production (shared across all actors).
  String? getProductionAdapter(String productionId) {
    return _productionProfiles[productionId]?.adapterPath;
  }

  // ── Storage ────────────────────────────────────────────

  /// Local directory for storing adapter weights.
  Future<String> _adapterDir(String productionId) async {
    final dir = await getApplicationDocumentsDirectory();
    final adapterDir = Directory(
      p.join(dir.path, 'stt_adapters', productionId),
    );
    if (!await adapterDir.exists()) {
      await adapterDir.create(recursive: true);
    }
    return adapterDir.path;
  }

  /// Clear all adaptation data for a production.
  Future<void> clearProduction(String productionId) async {
    _hydrations.remove(productionId);
    _failedHydrations.remove(productionId);
    _dirtyProductions.remove(productionId);
    // Remove actor profiles
    _actorProfiles.removeWhere((key, _) => key.startsWith('$productionId:'));

    // Remove production profile
    _productionProfiles.remove(productionId);

    // Delete adapter files
    final dir = await getApplicationDocumentsDirectory();
    final adapterDir = Directory(
      p.join(dir.path, 'stt_adapters', productionId),
    );
    if (await adapterDir.exists()) {
      await adapterDir.delete(recursive: true);
    }
  }
}

String _encodeProfileSnapshot(Map<String, dynamic> payload) =>
    jsonEncode(payload);

/// Strategy recommendation for STT training.
enum TrainingStrategy {
  /// Every actor has enough solo data — train individual LoRAs.
  perActor,

  /// Pool all cast recordings into one adapter.
  perProduction,

  /// Not enough data collected yet.
  notReady,
}
