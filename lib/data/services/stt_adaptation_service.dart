import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/app_database.dart';

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
  SttAdaptationService(
    this._database, {
    Future<Directory> Function()? documentsDirectory,
  }) : _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory;

  final AppDatabase _database;
  final Future<Directory> Function() _documentsDirectory;

  /// Per-actor profiles, keyed by "productionId:actorId".
  final Map<String, SttProfile> _actorProfiles = {};

  /// Per-production pooled profile, keyed by productionId.
  final Map<String, SttProfile> _productionProfiles = {};
  final Map<String, int> _productionSampleCounts = {};
  final Map<String, int> _productionDurationMs = {};

  final Map<String, int> _actorSampleCounts = {};
  final Map<String, int> _actorDurationMs = {};
  final Map<String, Map<String, TrainingSample>> _samplesByProductionPath = {};
  // ── Persistence ────────────────────────────────────────

  final Map<String, Future<void>> _hydrations = {};

  /// Hydrate normalized rows, migrating the historical profiles.json exactly
  /// once. Failed migration/loading propagates so a recording is never
  /// reported as durably adapted when its row was not stored.
  Future<void> ensureLoaded(String productionId) async {
    final existing = _hydrations[productionId];
    if (existing != null) {
      await existing;
      return;
    }
    final loading = _loadProduction(productionId);
    _hydrations[productionId] = loading;
    try {
      await loading;
    } catch (_) {
      if (identical(_hydrations[productionId], loading)) {
        _hydrations.remove(productionId);
      }
      rethrow;
    }
  }

  Future<void> _loadProduction(String productionId) async {
    await _migrateLegacyProfiles(productionId);
    final sampleRows = await _database.loadSttSamples(productionId);
    final metadataRows = await _database.loadSttProfileMetadata(productionId);

    _actorProfiles.removeWhere((key, _) => key.startsWith('$productionId:'));
    final samplesByActor = <String, List<TrainingSample>>{};
    for (final row in sampleRows) {
      (samplesByActor[row.actorId] ??= <TrainingSample>[]).add(
        TrainingSample(
          audioPath: row.audioPath,
          transcript: row.transcript,
          character: row.actorId,
          durationMs: row.durationMs,
          recordedAt: row.recordedAt,
        ),
      );
    }
    final metadataByActor = {for (final row in metadataRows) row.actorId: row};
    for (final entry in samplesByActor.entries) {
      final metadata = metadataByActor[entry.key];
      final profile = SttProfile(
        actorId: entry.key,
        productionId: productionId,
        samples: entry.value,
        status: _statusFromName(metadata?.status),
        adapterPath: metadata?.adapterPath,
        lastTrainedAt: metadata?.lastTrainedAt,
        wordErrorRate: metadata?.wordErrorRate,
      );
      _actorProfiles['$productionId:${entry.key}'] = profile.copyWith(
        status: _computeStatus(
          profile.samples.length,
          profile.totalAudioSeconds,
          profile.adapterPath,
        ),
      );
    }
    for (final metadata in metadataRows) {
      if (metadata.actorId == '_production' ||
          samplesByActor.containsKey(metadata.actorId)) {
        continue;
      }
      _actorProfiles['$productionId:${metadata.actorId}'] = SttProfile(
        actorId: metadata.actorId,
        productionId: productionId,
        samples: <TrainingSample>[],
        status: _statusFromName(metadata.status),
        adapterPath: metadata.adapterPath,
        lastTrainedAt: metadata.lastTrainedAt,
        wordErrorRate: metadata.wordErrorRate,
      );
    }

    final productionMetadata = metadataByActor['_production'];
    _productionProfiles[productionId] = SttProfile(
      actorId: '_production',
      productionId: productionId,
      samples: const [],
      status: _statusFromName(productionMetadata?.status),
      adapterPath: productionMetadata?.adapterPath,
      lastTrainedAt: productionMetadata?.lastTrainedAt,
      wordErrorRate: productionMetadata?.wordErrorRate,
    );
    _actorSampleCounts.removeWhere(
      (key, _) => key.startsWith('$productionId:'),
    );
    _actorDurationMs.removeWhere((key, _) => key.startsWith('$productionId:'));
    for (final entry in samplesByActor.entries) {
      final key = '$productionId:${entry.key}';
      _actorSampleCounts[key] = entry.value.length;
      _actorDurationMs[key] = entry.value.fold(
        0,
        (total, sample) => total + sample.durationMs,
      );
    }
    _samplesByProductionPath[productionId] = {
      for (final sample in sampleRows)
        sample.audioPath: TrainingSample(
          audioPath: sample.audioPath,
          transcript: sample.transcript,
          character: sample.actorId,
          durationMs: sample.durationMs,
          recordedAt: sample.recordedAt,
        ),
    };
    _productionSampleCounts[productionId] = sampleRows.length;
    _productionDurationMs[productionId] = sampleRows.fold(
      0,
      (total, sample) => total + sample.durationMs,
    );
  }

  SttAdaptationStatus _statusFromName(String? value) =>
      SttAdaptationStatus.values.asNameMap()[value] ??
      SttAdaptationStatus.needsData;

  Future<void> _migrateLegacyProfiles(String productionId) async {
    if (await _database.hasSttLegacyMigration(productionId)) return;
    final file = File(p.join(await _adapterDir(productionId), 'profiles.json'));
    if (!await file.exists()) {
      await _database.migrateLegacySttProfiles(
        productionId,
        const [],
        const [],
      );
      return;
    }

    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      throw const FormatException('Legacy STT profile root is not an object');
    }
    final samplesByPath = <String, SttSampleRow>{};
    final metadata = <SttProfileMetadataRow>[];

    void collect(dynamic value, {required bool productionProfile}) {
      if (value is! Map) return;
      final json = Map<String, dynamic>.from(value);
      final actorId = productionProfile
          ? '_production'
          : (json['actor_id'] as String? ?? '');
      if (actorId.isEmpty) return;
      metadata.add(
        SttProfileMetadataRow(
          productionId: productionId,
          actorId: actorId,
          status: json['status'] as String? ?? 'needsData',
          adapterPath: json['adapter_path'] as String?,
          lastTrainedAt: DateTime.tryParse(
            json['last_trained_at'] as String? ?? '',
          ),
          wordErrorRate: (json['wer'] as num?)?.toDouble(),
        ),
      );
      if (productionProfile) return;
      for (final rawSample in (json['samples'] as List? ?? const [])) {
        if (rawSample is! Map) continue;
        final sample = TrainingSample.fromJson(
          Map<String, dynamic>.from(rawSample),
        );
        samplesByPath[sample.audioPath] = SttSampleRow(
          productionId: productionId,
          actorId: actorId,
          audioPath: sample.audioPath,
          transcript: sample.transcript,
          durationMs: sample.durationMs,
          recordedAt: sample.recordedAt,
        );
      }
    }

    for (final actor in (decoded['actors'] as List? ?? const [])) {
      collect(actor, productionProfile: false);
    }
    collect(decoded['production'], productionProfile: true);
    await _database.migrateLegacySttProfiles(
      productionId,
      samplesByPath.values.toList(),
      metadata,
    );
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
        );
  }

  /// Get per-production pooled profile. Samples are derived from actor
  /// profiles instead of being duplicated in memory and persistence.
  SttProfile getProductionProfile(String productionId) {
    final metadata =
        _productionProfiles[productionId] ??
        SttProfile(
          actorId: '_production',
          productionId: productionId,
          samples: const [],
        );
    final samples = _actorProfiles.entries
        .where((entry) => entry.key.startsWith('$productionId:'))
        .expand((entry) => entry.value.samples)
        .toList(growable: false);
    final pooled = metadata.copyWith(samples: samples);
    return pooled.copyWith(
      status: _computeStatus(
        _productionSampleCounts[productionId] ?? samples.length,
        (_productionDurationMs[productionId] ??
                samples.fold<int>(
                  0,
                  (sum, sample) => sum + sample.durationMs,
                )) /
            1000,
        pooled.adapterPath,
      ),
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
  Future<void> addSample({
    required String productionId,
    required String actorId,
    required String audioPath,
    required String transcript,
    required int durationMs,
  }) async {
    await ensureLoaded(productionId);
    final recordedAt = DateTime.now();
    final sample = TrainingSample(
      audioPath: audioPath,
      transcript: transcript,
      character: actorId,
      durationMs: durationMs,
      recordedAt: recordedAt,
    );
    final actorKey = '$productionId:$actorId';
    final existing = _samplesByProductionPath[productionId]?[audioPath];
    final existingActorKey = existing == null
        ? null
        : '$productionId:${existing.character}';
    final replacesSameActor = existingActorKey == actorKey;
    final actorCount =
        (_actorSampleCounts[actorKey] ?? 0) + (replacesSameActor ? 0 : 1);
    final actorDuration =
        (_actorDurationMs[actorKey] ?? 0) +
        durationMs -
        (replacesSameActor ? existing!.durationMs : 0);
    final productionCount =
        (_productionSampleCounts[productionId] ?? 0) +
        (existing == null ? 1 : 0);
    final productionDuration =
        (_productionDurationMs[productionId] ?? 0) +
        durationMs -
        (existing?.durationMs ?? 0);

    final actorProfile =
        _actorProfiles[actorKey] ??
        SttProfile(
          actorId: actorId,
          productionId: productionId,
          samples: <TrainingSample>[],
        );
    final actorStatus = _computeStatus(
      actorCount,
      actorDuration / 1000,
      actorProfile.adapterPath,
    );
    final productionProfile =
        _productionProfiles[productionId] ??
        SttProfile(
          actorId: '_production',
          productionId: productionId,
          samples: const [],
        );
    final productionStatus = _computeStatus(
      productionCount,
      productionDuration / 1000,
      productionProfile.adapterPath,
    );
    final metadata = <SttProfileMetadataRow>[
      _metadataRow(actorProfile.copyWith(status: actorStatus)),
      _metadataRow(productionProfile.copyWith(status: productionStatus)),
    ];
    if (existing != null &&
        existingActorKey != null &&
        existingActorKey != actorKey) {
      final oldProfile = _actorProfiles[existingActorKey];
      if (oldProfile != null) {
        final oldCount = (_actorSampleCounts[existingActorKey] ?? 1) - 1;
        final oldDuration =
            (_actorDurationMs[existingActorKey] ?? existing.durationMs) -
            existing.durationMs;
        metadata.add(
          _metadataRow(
            oldProfile.copyWith(
              status: _computeStatus(
                oldCount,
                oldDuration / 1000,
                oldProfile.adapterPath,
              ),
            ),
          ),
        );
      }
    }

    await _database.upsertSttSampleWithMetadata(
      SttSampleRow(
        productionId: productionId,
        actorId: actorId,
        audioPath: audioPath,
        transcript: transcript,
        durationMs: durationMs,
        recordedAt: recordedAt,
      ),
      metadata,
    );

    if (existing != null) {
      final oldKey = '$productionId:${existing.character}';
      final oldProfile = _actorProfiles[oldKey];
      oldProfile?.samples.removeWhere((item) => item.audioPath == audioPath);
      if (oldKey != actorKey) {
        final oldCount = (_actorSampleCounts[oldKey] ?? 1) - 1;
        final oldDuration =
            (_actorDurationMs[oldKey] ?? existing.durationMs) -
            existing.durationMs;
        _actorSampleCounts[oldKey] = oldCount;
        _actorDurationMs[oldKey] = oldDuration;
        if (oldProfile != null) {
          _actorProfiles[oldKey] = oldProfile.copyWith(
            status: _computeStatus(
              oldCount,
              oldDuration / 1000,
              oldProfile.adapterPath,
            ),
          );
        }
      }
    }
    actorProfile.samples.add(sample);
    _actorProfiles[actorKey] = actorProfile.copyWith(status: actorStatus);
    _actorSampleCounts[actorKey] = actorCount;
    _actorDurationMs[actorKey] = actorDuration;
    _productionProfiles[productionId] = productionProfile.copyWith(
      status: productionStatus,
    );
    _productionSampleCounts[productionId] = productionCount;
    _productionDurationMs[productionId] = productionDuration;
    (_samplesByProductionPath[productionId] ??= {})[audioPath] = sample;

    debugPrint(
      'SttAdaptation: Added sample '
      '($actorCount actor samples, ${actorDuration ~/ 1000}s total)',
    );
  }

  SttProfileMetadataRow _metadataRow(SttProfile profile) =>
      SttProfileMetadataRow(
        productionId: profile.productionId,
        actorId: profile.actorId,
        status: profile.status.name,
        adapterPath: profile.adapterPath,
        lastTrainedAt: profile.lastTrainedAt,
        wordErrorRate: profile.wordErrorRate,
      );

  SttAdaptationStatus _computeStatus(
    int sampleCount,
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

    // Cloud training is not yet dispatched here; persist the durable
    // ready-to-train state without transient in-memory-only transitions.
    final updated = profile.copyWith(status: SttAdaptationStatus.readyToTrain);
    await _database.upsertSttProfileMetadata(_metadataRow(updated));
    _actorProfiles[key] = updated;
    debugPrint(
      'SttAdaptation: actor profile ready '
      '(${profile.samples.length} samples, '
      '${profile.totalAudioSeconds.toStringAsFixed(0)}s audio)',
    );
  }

  /// Request training for a pooled production adapter.
  Future<void> requestProductionTraining({required String productionId}) async {
    final pooled = getProductionProfile(productionId);
    if (!pooled.hasEnoughData) return;
    final metadata =
        (_productionProfiles[productionId] ??
                SttProfile(
                  actorId: '_production',
                  productionId: productionId,
                  samples: const [],
                ))
            .copyWith(status: SttAdaptationStatus.readyToTrain);
    await _database.upsertSttProfileMetadata(_metadataRow(metadata));
    _productionProfiles[productionId] = metadata;
    debugPrint(
      'SttAdaptation: production profile ready '
      '(${pooled.samples.length} samples, '
      '${pooled.totalAudioSeconds.toStringAsFixed(0)}s audio)',
    );
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
    final dir = await _documentsDirectory();
    final adapterDir = Directory(
      p.join(dir.path, 'stt_adapters', productionId),
    );
    if (!adapterDir.existsSync()) {
      adapterDir.createSync(recursive: true);
    }
    return adapterDir.path;
  }

  /// Clear all adaptation data for a production.
  Future<void> clearProduction(String productionId) async {
    await _database.clearSttAdaptation(productionId);
    _hydrations.remove(productionId);
    _actorProfiles.removeWhere((key, _) => key.startsWith('$productionId:'));
    _actorSampleCounts.removeWhere(
      (key, _) => key.startsWith('$productionId:'),
    );
    _actorDurationMs.removeWhere((key, _) => key.startsWith('$productionId:'));
    _samplesByProductionPath.remove(productionId);
    _productionSampleCounts.remove(productionId);
    _productionDurationMs.remove(productionId);
    _productionProfiles.remove(productionId);

    // Delete adapter files
    final dir = await _documentsDirectory();
    final adapterDir = Directory(
      p.join(dir.path, 'stt_adapters', productionId),
    );
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
