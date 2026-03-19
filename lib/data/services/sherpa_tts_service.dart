import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'debug_log_service.dart';
import 'model_manager.dart';

/// Cross-platform Kokoro TTS via sherpa-onnx ONNX Runtime.
///
/// Works on both iOS and Android (unlike Kokoro MLX which is iOS-only).
/// Uses the Kokoro-82M model from the sherpa-onnx release archive (~600MB).
/// Downloads via ModelManager which handles streaming bzip2 extraction.
class SherpaTtsService {
  SherpaTtsService._();
  static final instance = SherpaTtsService._();

  sherpa.OfflineTts? _tts;
  bool _initialized = false;

  bool get isInitialized => _initialized;

  /// Check if the Kokoro ONNX model files are downloaded.
  Future<bool> isModelDownloaded() async {
    return ModelManager.instance.isKokoroReady();
  }

  /// Initialize the sherpa-onnx TTS engine with Kokoro model.
  Future<bool> init() async {
    if (_initialized) return true;

    final dlog = DebugLogService.instance;
    final paths = await ModelManager.instance.getKokoroPaths();

    if (paths == null) {
      dlog.log(LogCategory.tts, 'Sherpa Kokoro ONNX: model files not found');
      return false;
    }

    try {
      sherpa.initBindings();

      final config = sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          kokoro: sherpa.OfflineTtsKokoroModelConfig(
            model: paths.model,
            voices: paths.voices,
            tokens: paths.tokens,
            dataDir: paths.dataDir,
            lengthScale: 1.0,
          ),
          numThreads: 2,
          debug: false,
        ),
        maxNumSenetences: 1,
      );

      _tts = sherpa.OfflineTts(config);
      _initialized = true;
      dlog.log(LogCategory.tts,
          'Sherpa Kokoro ONNX initialized (sample rate: ${_tts!.sampleRate})');
      return true;
    } catch (e) {
      dlog.logError(LogCategory.tts, 'Sherpa Kokoro ONNX init failed: $e', e);
      return false;
    }
  }

  /// Synthesize text to a WAV file.
  ///
  /// [voice] — Kokoro voice name (e.g. 'af_heart', 'am_adam').
  /// [speed] — Speech speed multiplier (1.0 = normal).
  /// Returns the path to the generated WAV file, or null on failure.
  Future<String?> synthesize(String text, {String voice = 'af_heart', double speed = 1.0}) async {
    if (!_initialized || _tts == null) return null;

    try {
      // Map voice name to speaker ID
      final sid = _voiceNameToSid(voice);

      final audio = _tts!.generate(text: text, sid: sid, speed: speed);
      if (audio.samples.isEmpty) {
        debugPrint('Sherpa TTS: empty audio for "$text"');
        return null;
      }

      // Write to WAV file
      final tempDir = await getTemporaryDirectory();
      final wavPath = p.join(tempDir.path,
          'sherpa_tts_${DateTime.now().millisecondsSinceEpoch}.wav');
      _writeWav(wavPath, audio.samples, audio.sampleRate);

      return wavPath;
    } catch (e) {
      debugPrint('Sherpa TTS synthesis failed: $e');
      return null;
    }
  }

  /// Map Kokoro voice names to speaker IDs.
  /// Kokoro v1.0 has voices indexed 0-53.
  int _voiceNameToSid(String voiceName) {
    const voiceMap = {
      'af_heart': 0, 'af_alloy': 1, 'af_aoede': 2, 'af_bella': 3,
      'af_jessica': 4, 'af_kore': 5, 'af_nicole': 6, 'af_nova': 7,
      'af_river': 8, 'af_sarah': 9, 'af_sky': 10,
      'am_adam': 11, 'am_echo': 12, 'am_eric': 13, 'am_fenrir': 14,
      'am_liam': 15, 'am_michael': 16, 'am_onyx': 17, 'am_puck': 18,
      'bf_alice': 19, 'bf_emma': 20, 'bf_isabella': 21, 'bf_lily': 22,
      'bm_daniel': 23, 'bm_fable': 24, 'bm_george': 25, 'bm_lewis': 26,
    };
    return voiceMap[voiceName] ?? 0;
  }

  /// Write PCM float samples to a WAV file.
  void _writeWav(String path, Float32List samples, int sampleRate) {
    final numSamples = samples.length;
    final byteRate = sampleRate * 2; // 16-bit mono
    final dataSize = numSamples * 2;
    final fileSize = 36 + dataSize;

    final buffer = ByteData(44 + dataSize);
    // RIFF header
    buffer.setUint8(0, 0x52); // R
    buffer.setUint8(1, 0x49); // I
    buffer.setUint8(2, 0x46); // F
    buffer.setUint8(3, 0x46); // F
    buffer.setUint32(4, fileSize, Endian.little);
    buffer.setUint8(8, 0x57); // W
    buffer.setUint8(9, 0x41); // A
    buffer.setUint8(10, 0x56); // V
    buffer.setUint8(11, 0x45); // E
    // fmt chunk
    buffer.setUint8(12, 0x66); // f
    buffer.setUint8(13, 0x6D); // m
    buffer.setUint8(14, 0x74); // t
    buffer.setUint8(15, 0x20); // (space)
    buffer.setUint32(16, 16, Endian.little); // chunk size
    buffer.setUint16(20, 1, Endian.little); // PCM
    buffer.setUint16(22, 1, Endian.little); // mono
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, byteRate, Endian.little);
    buffer.setUint16(32, 2, Endian.little); // block align
    buffer.setUint16(34, 16, Endian.little); // bits per sample
    // data chunk
    buffer.setUint8(36, 0x64); // d
    buffer.setUint8(37, 0x61); // a
    buffer.setUint8(38, 0x74); // t
    buffer.setUint8(39, 0x61); // a
    buffer.setUint32(40, dataSize, Endian.little);

    // Convert float32 to int16
    for (var i = 0; i < numSamples; i++) {
      final sample = (samples[i] * 32767).clamp(-32768, 32767).toInt();
      buffer.setInt16(44 + i * 2, sample, Endian.little);
    }

    File(path).writeAsBytesSync(buffer.buffer.asUint8List());
  }

  void dispose() {
    _tts?.free();
    _tts = null;
    _initialized = false;
  }
}
