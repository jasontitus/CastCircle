import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'model_manager.dart';

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

/// Service for voice cloning using ZipVoice via sherpa-onnx.
///
/// ZipVoice is a 123M parameter flow-matching-based zero-shot TTS model.
/// Given 3-10 seconds of reference audio + its transcript, it generates
/// new speech in that voice.
///
/// The service manages:
/// - Voice profiles (reference audio per character)
/// - Generating speech for unrecorded lines using ZipVoice
/// - Caching generated audio alongside real recordings
class VoiceCloneService {
  VoiceCloneService._();
  static final instance = VoiceCloneService._();

  VoiceCloneStatus _status = VoiceCloneStatus.idle;
  VoiceCloneStatus get status => _status;

  sherpa.OfflineTts? _zipVoiceTts;
  bool _initialized = false;

  final Map<String, VoiceProfile> _profiles = {};

  /// Whether ZipVoice model is loaded and ready.
  bool get isReady => _zipVoiceTts != null;

  /// Get voice profile for a character, or null if none exists.
  VoiceProfile? getProfile(String character) => _profiles[character];

  /// Get all voice profiles.
  Map<String, VoiceProfile> get profiles => Map.unmodifiable(_profiles);

  /// Initialize ZipVoice model. Call after models are downloaded.
  Future<bool> init() async {
    if (_initialized && _zipVoiceTts != null) return true;

    // ZipVoice model paths — these will be provided by ModelManager
    // once ZipVoice models are added to the download list.
    // For now, check if the model files exist.
    final models = ModelManager.instance;
    final dir = await models.modelsDir;
    final zipVoiceDir = p.join(dir, 'zipvoice');

    final encoderPath = p.join(zipVoiceDir, 'encoder.onnx');
    final decoderPath = p.join(zipVoiceDir, 'decoder.onnx');
    final vocoderPath = p.join(zipVoiceDir, 'vocoder.onnx');
    final tokensPath = p.join(zipVoiceDir, 'tokens.txt');

    if (!await File(encoderPath).exists()) {
      debugPrint('ZipVoice: Model not downloaded yet');
      return false;
    }

    try {
      final config = sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          zipvoice: sherpa.OfflineTtsZipVoiceModelConfig(
            tokens: tokensPath,
            encoder: encoderPath,
            decoder: decoderPath,
            vocoder: vocoderPath,
            dataDir: zipVoiceDir,
          ),
          numThreads: 2,
          debug: false,
          provider: 'cpu',
        ),
      );

      _zipVoiceTts = sherpa.OfflineTts(config);
      _initialized = true;
      debugPrint('ZipVoice loaded: ${_zipVoiceTts!.sampleRate}Hz');
      return true;
    } catch (e) {
      debugPrint('ZipVoice init failed: $e');
      return false;
    }
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
  /// Returns the path to the generated audio file, or null if generation
  /// is not possible.
  Future<String?> generateLine({
    required String productionId,
    required String character,
    required String lineId,
    required String text,
    String? referenceText,
  }) async {
    final profile = _profiles[character];
    if (profile == null || profile.referenceAudioPaths.isEmpty) return null;

    // Check cache first
    final cachePath = await _cachePath(productionId, character, lineId);
    if (await File(cachePath).exists()) return cachePath;

    if (_zipVoiceTts == null) {
      // ZipVoice not loaded — try to init
      final loaded = await init();
      if (!loaded) {
        debugPrint('ZipVoice: Cannot generate — model not available');
        return null;
      }
    }

    _status = VoiceCloneStatus.generating;

    try {
      // Load reference audio from the first available recording
      final refPath = profile.referenceAudioPaths.first;
      final refAudio = await _loadAudioSamples(refPath);
      if (refAudio == null) {
        _status = VoiceCloneStatus.error;
        return null;
      }

      // Generate with ZipVoice using reference audio
      final audio = _zipVoiceTts!.generateWithConfig(
        text: text,
        config: sherpa.OfflineTtsGenerationConfig(
          speed: 1.0,
          referenceAudio: refAudio.samples,
          referenceSampleRate: refAudio.sampleRate,
          referenceText: referenceText ?? '',
        ),
      );

      if (audio.samples.isEmpty) {
        _status = VoiceCloneStatus.error;
        return null;
      }

      // Write to cache
      await _writeWav(audio.samples, audio.sampleRate, cachePath);
      _status = VoiceCloneStatus.complete;
      return cachePath;
    } catch (e) {
      _status = VoiceCloneStatus.error;
      debugPrint('ZipVoice generation error: $e');
      return null;
    } finally {
      if (_status != VoiceCloneStatus.complete) {
        _status = VoiceCloneStatus.idle;
      }
    }
  }

  /// Check if we can generate voice-cloned audio for a character.
  bool canClone(String character) {
    final profile = _profiles[character];
    return profile != null && profile.referenceAudioPaths.length >= 3;
  }

  /// Load audio samples from a WAV/M4A file as Float32List.
  Future<({Float32List samples, int sampleRate})?> _loadAudioSamples(
      String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;

      final bytes = await file.readAsBytes();

      // Simple WAV parser — check for RIFF header
      if (bytes.length > 44 &&
          bytes[0] == 0x52 && // R
          bytes[1] == 0x49 && // I
          bytes[2] == 0x46 && // F
          bytes[3] == 0x46) { // F
        final byteData = ByteData.sublistView(bytes);
        final sampleRate = byteData.getUint32(24, Endian.little);
        final bitsPerSample = byteData.getUint16(34, Endian.little);
        final dataStart = 44; // Standard WAV header size

        if (bitsPerSample == 16) {
          final numSamples = (bytes.length - dataStart) ~/ 2;
          final samples = Float32List(numSamples);
          for (var i = 0; i < numSamples; i++) {
            final int16 = byteData.getInt16(dataStart + i * 2, Endian.little);
            samples[i] = int16 / 32768.0;
          }
          return (samples: samples, sampleRate: sampleRate);
        }
      }

      // For non-WAV formats (m4a, etc.), use AudioPlayer to decode
      // This is a simplified approach — a proper implementation would
      // use a dedicated audio decoder
      debugPrint('VoiceClone: Non-WAV reference audio at $path');
      return null;
    } catch (e) {
      debugPrint('VoiceClone: Failed to load reference audio: $e');
      return null;
    }
  }

  /// Write Float32 PCM samples to a WAV file.
  Future<void> _writeWav(
      Float32List samples, int sampleRate, String path) async {
    final numSamples = samples.length;
    final dataSize = numSamples * 2;
    final fileSize = 36 + dataSize;

    final buffer = ByteData(44 + dataSize);

    // RIFF header
    buffer.setUint8(0, 0x52);
    buffer.setUint8(1, 0x49);
    buffer.setUint8(2, 0x46);
    buffer.setUint8(3, 0x46);
    buffer.setUint32(4, fileSize, Endian.little);
    buffer.setUint8(8, 0x57);
    buffer.setUint8(9, 0x41);
    buffer.setUint8(10, 0x56);
    buffer.setUint8(11, 0x45);

    // fmt
    buffer.setUint8(12, 0x66);
    buffer.setUint8(13, 0x6D);
    buffer.setUint8(14, 0x74);
    buffer.setUint8(15, 0x20);
    buffer.setUint32(16, 16, Endian.little);
    buffer.setUint16(20, 1, Endian.little);
    buffer.setUint16(22, 1, Endian.little);
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, sampleRate * 2, Endian.little);
    buffer.setUint16(32, 2, Endian.little);
    buffer.setUint16(34, 16, Endian.little);

    // data
    buffer.setUint8(36, 0x64);
    buffer.setUint8(37, 0x61);
    buffer.setUint8(38, 0x74);
    buffer.setUint8(39, 0x61);
    buffer.setUint32(40, dataSize, Endian.little);

    for (var i = 0; i < numSamples; i++) {
      final clamped = samples[i].clamp(-1.0, 1.0);
      buffer.setInt16(44 + i * 2, (clamped * 32767).round(), Endian.little);
    }

    await File(path).parent.create(recursive: true);
    await File(path).writeAsBytes(buffer.buffer.asUint8List());
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

  /// Clear cached generated audio for a production.
  Future<void> clearCache(String productionId) async {
    final dir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory(p.join(dir.path, 'voice_cache', productionId));
    if (cacheDir.existsSync()) {
      await cacheDir.delete(recursive: true);
    }
  }

  void dispose() {
    _zipVoiceTts?.free();
    _zipVoiceTts = null;
  }
}
