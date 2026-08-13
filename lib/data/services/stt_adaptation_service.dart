import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
  final SttAdaptationStatus status;
  final String? adapterPath; // path to LoRA adapter weights
  final DateTime? lastTrainedAt;
  final double? wordErrorRate; // WER on validation set, if measured

  const SttProfile({
    required this.actorId,
    required this.productionId,
    required this.samples,
    this.status = SttAdaptationStatus.needsData,
    this.adapterPath,
    this.lastTrainedAt,
    this.wordErrorRate,
  });

  /// Total duration of training audio in seconds.
  double get totalAudioSeconds =>
      samples.fold<int>(0, (sum, s) => sum + s.durationMs) / 1000.0;

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
    SttAdaptationStatus? status,
    String? adapterPath,
    DateTime? lastTrainedAt,
    double? wordErrorRate,
  }) {
    return SttProfile(
      actorId: actorId ?? this.actorId,
      productionId: productionId ?? this.productionId,
      samples: samples ?? this.samples,
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
class SttAdaptationService {
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
  Timer? _persistDebounce;
  final Set<String> _dirtyProductions = {};

  /// Hydrate a production's profiles from disk (idempotent, lazy).
  Future<void> ensureLoaded(String productionId) =>
      _hydrations[productionId] ??= _loadProduction(productionId);

  Future<void> _loadProduction(String productionId) async {
    try {
      final file = File(p.join(await _adapterDir(productionId), 'profiles.json'));
      if (!file.existsSync()) return;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) return;
      SttProfile? decode(dynamic j) {
        if (j is! Map) return null;
        final m = Map<String, dynamic>.from(j);
        final samples = (m['samples'] as List? ?? [])
            .whereType<Map>()
            .map((x) => TrainingSample.fromJson(Map<String, dynamic>.from(x)))
            // A sample whose audio file is gone can't train anything.
            .where((x) => File(x.audioPath).existsSync())
            .toList();
        return SttProfile(
          actorId: m['actor_id'] as String? ?? '',
          productionId: productionId,
          samples: samples,
          status: SttAdaptationStatus.values
                  .asNameMap()[m['status'] as String? ?? ''] ??
              SttAdaptationStatus.needsData,
          adapterPath: m['adapter_path'] as String?,
          lastTrainedAt: DateTime.tryParse(m['last_trained_at'] as String? ?? ''),
          wordErrorRate: (m['wer'] as num?)?.toDouble(),
        );
      }

      SttProfile merge(SttProfile disk, SttProfile? live) {
        if (live == null) return disk;
        // Union by audioPath: live (this-session) samples win, disk fills
        // in everything accumulated in previous runs.
        final livePaths = {for (final x in live.samples) x.audioPath};
        final samples = [
          ...disk.samples.where((x) => !livePaths.contains(x.audioPath)),
          ...live.samples,
        ];
        final merged = live.copyWith(
          samples: samples,
          adapterPath: live.adapterPath ?? disk.adapterPath,
          lastTrainedAt: live.lastTrainedAt ?? disk.lastTrainedAt,
          wordErrorRate: live.wordErrorRate ?? disk.wordErrorRate,
        );
        return merged.copyWith(
            status: _computeStatus(merged.samples.length,
                merged.totalAudioSeconds, merged.adapterPath));
      }

      for (final j in (data['actors'] as List? ?? [])) {
        final profile = decode(j);
        if (profile == null || profile.actorId.isEmpty) continue;
        final key = '$productionId:${profile.actorId}';
        _actorProfiles[key] = merge(profile, _actorProfiles[key]);
      }
      final prod = decode(data['production']);
      if (prod != null) {
        _productionProfiles[productionId] =
            merge(prod, _productionProfiles[productionId]);
      }
    } catch (e) {
      debugPrint('SttAdaptation: hydrate failed for $productionId: $e');
    }
  }

  void _schedulePersist(String productionId) {
    _dirtyProductions.add(productionId);
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(seconds: 2), () {
      final dirty = _dirtyProductions.toList();
      _dirtyProductions.clear();
      for (final pid in dirty) {
        unawaited(_persistProduction(pid));
      }
    });
  }

  Future<void> _persistProduction(String productionId) async {
    try {
      Map<String, dynamic> encode(SttProfile profile) => {
            'actor_id': profile.actorId,
            'samples': profile.samples.map((s) => s.toJson()).toList(),
            'status': profile.status.name,
            'adapter_path': profile.adapterPath,
            'last_trained_at': profile.lastTrainedAt?.toIso8601String(),
            'wer': profile.wordErrorRate,
          };
      final snapshot = jsonEncode({
        'actors': [
          for (final e in _actorProfiles.entries)
            if (e.key.startsWith('$productionId:')) encode(e.value),
        ],
        'production': _productionProfiles[productionId] == null
            ? null
            : encode(_productionProfiles[productionId]!),
      });
      final path = p.join(await _adapterDir(productionId), 'profiles.json');
      final tmp = File('$path.tmp');
      await tmp.writeAsString(snapshot, flush: true);
      await tmp.rename(path);
    } catch (e) {
      debugPrint('SttAdaptation: persist failed for $productionId: $e');
    }
  }

  // ── Profile Management ─────────────────────────────────

  /// Get per-actor profile, creating if needed.
  SttProfile getActorProfile(String productionId, String actorId) {
    final key = '$productionId:$actorId';
    return _actorProfiles[key] ?? SttProfile(
      actorId: actorId,
      productionId: productionId,
      samples: const [],
    );
  }

  /// Get per-production pooled profile.
  SttProfile getProductionProfile(String productionId) {
    return _productionProfiles[productionId] ?? SttProfile(
      actorId: '_production',
      productionId: productionId,
      samples: const [],
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
    final actorProfile = _actorProfiles[actorKey] ?? SttProfile(
      actorId: actorId,
      productionId: productionId,
      samples: const [],
    );
    final actorSeconds = actorProfile.totalAudioSeconds + durationMs / 1000.0;
    _actorProfiles[actorKey] = actorProfile.copyWith(
      samples: [...actorProfile.samples, sample],
      status: _computeStatus(
          actorProfile.samples.length + 1, actorSeconds, actorProfile.adapterPath),
    );

    // Also add to pooled production profile
    final prodProfile = _productionProfiles[productionId] ?? SttProfile(
      actorId: '_production',
      productionId: productionId,
      samples: const [],
    );
    _productionProfiles[productionId] = prodProfile.copyWith(
      samples: [...prodProfile.samples, sample],
      status: _computeStatus(prodProfile.samples.length + 1,
          prodProfile.totalAudioSeconds + durationMs / 1000.0,
          prodProfile.adapterPath),
    );

    debugPrint(
      'SttAdaptation: Added sample for $actorId '
      '(${actorProfile.samples.length + 1} samples, '
      '${actorSeconds.toStringAsFixed(0)}s total)',
    );
    _schedulePersist(productionId);
  }

  SttAdaptationStatus _computeStatus(
      int sampleCount, double totalSeconds, String? existingAdapter) {
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
    final actorsReady = actorProfiles
        .where((p) => p.hasEnoughData)
        .length;

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
  Future<void> requestProductionTraining({
    required String productionId,
  }) async {
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
        p.join(dir.path, 'stt_adapters', productionId));
    if (!adapterDir.existsSync()) {
      adapterDir.createSync(recursive: true);
    }
    return adapterDir.path;
  }

  /// Clear all adaptation data for a production.
  Future<void> clearProduction(String productionId) async {
    _hydrations.remove(productionId);
    _dirtyProductions.remove(productionId);
    // Remove actor profiles
    _actorProfiles.removeWhere(
        (key, _) => key.startsWith('$productionId:'));

    // Remove production profile
    _productionProfiles.remove(productionId);

    // Delete adapter files
    final dir = await getApplicationDocumentsDirectory();
    final adapterDir = Directory(
        p.join(dir.path, 'stt_adapters', productionId));
    if (adapterDir.existsSync()) {
      await adapterDir.delete(recursive: true);
    }
  }
}

/// Strategy recommendation for STT training.
enum TrainingStrategy {
  /// Every actor has enough solo data — train individual LoRAs.
  perActor,
  /// Pool all cast recordings into one adapter.
  perProduction,
  /// Not enough data collected yet.
  notReady,
}
