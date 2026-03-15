import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Voice profile for a cast member, storing reference audio and embeddings.
class VoiceProfile {
  final String characterName;
  final List<String> referenceAudioPaths;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Estimated quality based on number/duration of reference clips.
  /// 0.0 = no data, 1.0 = excellent (60+ seconds of clean audio).
  double get quality {
    if (referenceAudioPaths.isEmpty) return 0.0;
    // Each clip assumed ~5-15s; 6+ clips = good quality
    return (referenceAudioPaths.length / 8.0).clamp(0.1, 1.0);
  }

  const VoiceProfile({
    required this.characterName,
    required this.referenceAudioPaths,
    required this.createdAt,
    required this.updatedAt,
  });

  VoiceProfile copyWith({
    String? characterName,
    List<String>? referenceAudioPaths,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return VoiceProfile(
      characterName: characterName ?? this.characterName,
      referenceAudioPaths: referenceAudioPaths ?? this.referenceAudioPaths,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// Status of a voice clone generation request.
enum VoiceCloneStatus {
  idle,
  extractingEmbedding,
  generating,
  complete,
  error,
}

/// Service for voice cloning.
///
/// Voice cloning requires a dedicated model (e.g. ZipVoice) which is not
/// currently bundled. This service manages voice profiles and will generate
/// cloned audio when a model backend is available.
class VoiceCloneService {
  VoiceCloneService._();
  static final instance = VoiceCloneService._();

  VoiceCloneStatus _status = VoiceCloneStatus.idle;
  VoiceCloneStatus get status => _status;

  bool _initialized = false;

  final Map<String, VoiceProfile> _profiles = {};

  /// Whether voice clone model is loaded and ready.
  bool get isReady => false; // No backend currently linked

  /// Get voice profile for a character, or null if none exists.
  VoiceProfile? getProfile(String character) => _profiles[character];

  /// Get all voice profiles.
  Map<String, VoiceProfile> get profiles => Map.unmodifiable(_profiles);

  /// Initialize voice clone model. Returns false — no backend available yet.
  Future<bool> init() async {
    debugPrint('VoiceClone: No backend available (sherpa-onnx removed)');
    return false;
  }

  /// Build a voice profile from existing recordings.
  Future<VoiceProfile> buildProfileFromRecordings({
    required String character,
    required List<String> recordingPaths,
  }) async {
    final validPaths = <String>[];
    for (final path in recordingPaths) {
      if (await File(path).exists()) {
        validPaths.add(path);
      }
    }

    final now = DateTime.now();
    final profile = VoiceProfile(
      characterName: character,
      referenceAudioPaths: validPaths,
      createdAt: _profiles[character]?.createdAt ?? now,
      updatedAt: now,
    );

    _profiles[character] = profile;
    return profile;
  }

  /// Generate speech for a line using a character's voice profile.
  /// Returns null — no voice clone backend available.
  Future<String?> generateLine({
    required String productionId,
    required String character,
    required String lineId,
    required String text,
    String? referenceText,
  }) async {
    // Check cache — previously generated files still work
    final cachePath = await _cachePath(productionId, character, lineId);
    if (await File(cachePath).exists()) return cachePath;

    // No backend available
    return null;
  }

  /// Check if we can generate voice-cloned audio for a character.
  bool canClone(String character) {
    return false; // No backend currently available
  }

  /// Clear cached generated audio for a production.
  Future<void> clearCache(String productionId) async {
    final dir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory(p.join(dir.path, 'voice_cache', productionId));
    if (cacheDir.existsSync()) {
      await cacheDir.delete(recursive: true);
    }
  }

  /// Get the local cache path for a generated line.
  Future<String> _cachePath(
      String productionId, String character, String lineId) async {
    final dir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory(
        p.join(dir.path, 'voice_cache', productionId, character));
    if (!cacheDir.existsSync()) {
      cacheDir.createSync(recursive: true);
    }
    return p.join(cacheDir.path, '$lineId.wav');
  }

  void dispose() {}
}
