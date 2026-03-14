import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'model_manager.dart';

/// TTS engine type.
enum TtsEngine {
  /// Kokoro on-device neural TTS via sherpa-onnx (default).
  kokoro,

  /// System TTS (fallback if Kokoro model not downloaded).
  system,
}

/// Text-to-speech service using Kokoro via sherpa-onnx.
///
/// Priority chain for playing other characters' lines:
///   1. Real recording by primary actor
///   2. Real recording by understudy (if fallback enabled)
///   3. Voice-cloned audio (ZipVoice)
///   4. Kokoro on-device TTS (this service)
///   5. System TTS (last resort — only if Kokoro model not available)
class TtsService {
  TtsService._();
  static final instance = TtsService._();

  final FlutterTts _systemTts = FlutterTts();
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _initialized = false;
  TtsEngine _activeEngine = TtsEngine.system;
  VoidCallback? _completionHandler;

  // Kokoro
  sherpa.OfflineTts? _kokoroTts;
  int _kokoroSampleRate = 24000;

  // Character voice assignments (speaker IDs for Kokoro, voice maps for system)
  final Map<String, int> _characterSpeakerIds = {};
  final Map<String, Map<String, String>> _characterSystemVoices = {};
  List<dynamic> _availableSystemVoices = [];

  TtsEngine get activeEngine => _activeEngine;
  bool get isKokoroReady => _kokoroTts != null;

  Future<void> init() async {
    if (_initialized) return;

    // Try to load Kokoro
    final kokoroLoaded = await _initKokoro();
    if (kokoroLoaded) {
      _activeEngine = TtsEngine.kokoro;
      debugPrint('TTS: Kokoro neural TTS ready (sherpa-onnx)');
    } else {
      _activeEngine = TtsEngine.system;
      debugPrint('TTS: Kokoro not available, using system TTS');
    }

    // Initialize system TTS as fallback
    await _systemTts.setLanguage('en-US');
    await _systemTts.setSpeechRate(0.5);
    await _systemTts.setVolume(1.0);
    await _systemTts.setPitch(1.0);
    _availableSystemVoices = await _systemTts.getVoices as List<dynamic>;

    _systemTts.setCompletionHandler(() {
      _completionHandler?.call();
    });

    _audioPlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        _completionHandler?.call();
      }
    });

    _initialized = true;
  }

  /// Initialize Kokoro via sherpa-onnx.
  Future<bool> _initKokoro() async {
    final paths = await ModelManager.instance.getKokoroPaths();
    if (paths == null) return false;

    try {
      final config = sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          kokoro: sherpa.OfflineTtsKokoroModelConfig(
            model: paths.model,
            voices: paths.voices,
            tokens: paths.tokens,
            dataDir: paths.dataDir,
          ),
          numThreads: 2,
          debug: false,
          provider: 'cpu',
        ),
      );

      _kokoroTts = sherpa.OfflineTts(config);
      _kokoroSampleRate = _kokoroTts!.sampleRate;
      debugPrint('Kokoro loaded: ${_kokoroTts!.numSpeakers} speakers, ${_kokoroSampleRate}Hz');
      return true;
    } catch (e) {
      debugPrint('Kokoro init failed: $e');
      return false;
    }
  }

  /// Re-attempt Kokoro init (e.g. after model download).
  Future<bool> reloadKokoro() async {
    final loaded = await _initKokoro();
    if (loaded) _activeEngine = TtsEngine.kokoro;
    return loaded;
  }

  /// Assign a distinct voice to a character.
  void assignVoice(String character, int characterIndex) {
    if (_kokoroTts != null && _kokoroTts!.numSpeakers > 0) {
      _characterSpeakerIds[character] =
          characterIndex % _kokoroTts!.numSpeakers;
    }

    if (_availableSystemVoices.isNotEmpty) {
      final voiceIdx = characterIndex % _availableSystemVoices.length;
      final voice = _availableSystemVoices[voiceIdx];
      if (voice is Map) {
        _characterSystemVoices[character] = Map<String, String>.from(voice);
      }
    }
  }

  /// Speak text for a character.
  /// Returns true if audio was produced, false if no TTS engine is available.
  /// Uses Kokoro neural TTS if available, falls back to system TTS.
  Future<bool> speak(String text, {String? character}) async {
    if (!_initialized) await init();

    // Try lazy-loading Kokoro if models appeared since init
    if (_kokoroTts == null) {
      await _initKokoro();
      if (_kokoroTts != null) _activeEngine = TtsEngine.kokoro;
    }

    if (_kokoroTts != null) {
      return _speakWithKokoro(text, character: character);
    }

    // Fall back to system TTS so rehearsal doesn't skip lines
    debugPrint('TTS: Kokoro not available, using system TTS');
    return _speakWithSystem(text, character: character);
  }

  /// Speak using system TTS.
  Future<bool> _speakWithSystem(String text, {String? character}) async {
    if (character != null && _characterSystemVoices.containsKey(character)) {
      await _systemTts.setVoice(_characterSystemVoices[character]!);
    }
    await _systemTts.speak(text);
    return true;
  }

  /// Speak using Kokoro via sherpa-onnx.
  Future<bool> _speakWithKokoro(String text, {String? character}) async {
    if (_kokoroTts == null) return false;

    try {
      final sid = character != null
          ? (_characterSpeakerIds[character] ?? 0)
          : 0;

      final audio = _kokoroTts!.generate(
        text: text,
        sid: sid,
        speed: 1.0,
      );

      if (audio.samples.isEmpty) {
        debugPrint('Kokoro generated empty audio for: "${text.substring(0, text.length.clamp(0, 40))}..."');
        return false;
      }

      // Write to temporary WAV file and play
      final wavPath = await _writeWav(audio.samples, audio.sampleRate);
      await _audioPlayer.setFilePath(wavPath);
      await _audioPlayer.play();
      return true;
    } catch (e) {
      debugPrint('Kokoro speak failed: $e');
      return false;
    }
  }

  /// Write Float32 PCM samples to a WAV file.
  Future<String> _writeWav(Float32List samples, int sampleRate) async {
    final tmpDir = await getTemporaryDirectory();
    final wavPath = p.join(tmpDir.path, 'tts_output.wav');

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
    buffer.setUint8(8, 0x57);  // W
    buffer.setUint8(9, 0x41);  // A
    buffer.setUint8(10, 0x56); // V
    buffer.setUint8(11, 0x45); // E

    // fmt subchunk
    buffer.setUint8(12, 0x66); // f
    buffer.setUint8(13, 0x6D); // m
    buffer.setUint8(14, 0x74); // t
    buffer.setUint8(15, 0x20); // (space)
    buffer.setUint32(16, 16, Endian.little);    // subchunk size
    buffer.setUint16(20, 1, Endian.little);     // PCM
    buffer.setUint16(22, 1, Endian.little);     // mono
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, byteRate, Endian.little);
    buffer.setUint16(32, 2, Endian.little);     // block align
    buffer.setUint16(34, 16, Endian.little);    // bits per sample

    // data subchunk
    buffer.setUint8(36, 0x64); // d
    buffer.setUint8(37, 0x61); // a
    buffer.setUint8(38, 0x74); // t
    buffer.setUint8(39, 0x61); // a
    buffer.setUint32(40, dataSize, Endian.little);

    // Convert float32 [-1,1] to int16
    for (var i = 0; i < numSamples; i++) {
      final clamped = samples[i].clamp(-1.0, 1.0);
      final int16 = (clamped * 32767).round();
      buffer.setInt16(44 + i * 2, int16, Endian.little);
    }

    await File(wavPath).writeAsBytes(buffer.buffer.asUint8List());
    return wavPath;
  }

  /// Stop current speech.
  Future<void> stop() async {
    await _systemTts.stop();
    await _audioPlayer.stop();
  }

  /// Set playback speed.
  Future<void> setRate(double rate) async {
    await _systemTts.setSpeechRate(rate);
    // Kokoro speed is set per-generate call
  }

  /// Listen for TTS completion events.
  void setCompletionHandler(Function handler) {
    _completionHandler = () => handler();
  }

  /// Clean up resources.
  void dispose() {
    _kokoroTts?.free();
    _kokoroTts = null;
    _audioPlayer.dispose();
  }
}
