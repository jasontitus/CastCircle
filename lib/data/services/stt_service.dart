import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:speech_to_text/speech_to_text.dart';

import 'mlx_stt_channel.dart';
import 'model_manager.dart';

/// STT engine type.
enum SttEngine {
  /// MLX Parakeet on-device via mlx-audio-swift (preferred on iOS).
  mlx,

  /// Whisper on-device via sherpa-onnx (fallback).
  whisper,

  /// System STT (last resort).
  system,
}

/// Speech-to-text service with tiered engine priority:
///
///   1. MLX Parakeet (best quality, supports LoRA fine-tuning)
///   2. sherpa-onnx Whisper (cross-platform fallback)
///   3. System STT (last resort, lazy-initialized)
class SttService {
  SttService._();
  static final instance = SttService._();

  // System STT fallback
  final SpeechToText _systemStt = SpeechToText();
  bool _systemInitialized = false;
  bool _continuousMode = false;

  // MLX Parakeet via platform channel
  final MlxSttChannel _mlxChannel = MlxSttChannel.instance;

  // Whisper via sherpa-onnx
  sherpa.OfflineRecognizer? _whisperRecognizer;
  SttEngine _activeEngine = SttEngine.system;

  // Recording
  final AudioRecorder _recorder = AudioRecorder();
  bool _isListening = false;
  Timer? _listenTimer;

  SttEngine get activeEngine => _activeEngine;
  bool get isListening => _isListening;
  bool get isWhisperReady => _whisperRecognizer != null;
  bool get isMlxReady => _mlxChannel.isInitialized;

  /// Check if any on-device STT is available (MLX or Whisper).
  /// Does NOT eagerly init system STT.
  bool get isAvailable => _mlxChannel.isInitialized || _whisperRecognizer != null;

  Future<bool> init() async {
    // 1. Try MLX Parakeet first (iOS only, best quality)
    final mlxLoaded = await _initMlx();
    if (mlxLoaded) {
      _activeEngine = SttEngine.mlx;
      debugPrint('STT: MLX Parakeet ready');
      return true;
    }

    // 2. Try sherpa-onnx Whisper
    final whisperLoaded = await _initWhisper();
    if (whisperLoaded) {
      _activeEngine = SttEngine.whisper;
      debugPrint('STT: Whisper ready (sherpa-onnx)');
      return true;
    }

    // 3. Mark system as fallback but do NOT initialize it yet.
    _activeEngine = SttEngine.system;
    debugPrint('STT: No on-device models, system STT will init on first use');
    return false;
  }

  Future<bool> _initMlx() async {
    final modelPath = await ModelManager.instance.getMlxSttModelPath();
    if (modelPath == null) return false;

    return _mlxChannel.initialize(modelPath);
  }

  Future<bool> _initWhisper() async {
    final paths = await ModelManager.instance.getWhisperPaths();
    if (paths == null) return false;

    try {
      final config = sherpa.OfflineRecognizerConfig(
        feat: sherpa.FeatureConfig(
          sampleRate: 16000,
          featureDim: 80,
        ),
        model: sherpa.OfflineModelConfig(
          whisper: sherpa.OfflineWhisperModelConfig(
            encoder: paths.encoder,
            decoder: paths.decoder,
            language: 'en',
            task: 'transcribe',
          ),
          tokens: paths.tokens,
          numThreads: 2,
          debug: false,
          provider: 'cpu',
        ),
        decodingMethod: 'greedy_search',
      );

      _whisperRecognizer = sherpa.OfflineRecognizer(config);
      debugPrint('Whisper STT loaded');
      return true;
    } catch (e) {
      debugPrint('Whisper init failed: $e');
      return false;
    }
  }

  /// Re-attempt model init (e.g. after model download).
  Future<bool> reloadWhisper() async {
    // Try MLX first
    final mlxLoaded = await _initMlx();
    if (mlxLoaded) {
      _activeEngine = SttEngine.mlx;
      return true;
    }
    // Fall back to Whisper
    final loaded = await _initWhisper();
    if (loaded) _activeEngine = SttEngine.whisper;
    return loaded || mlxLoaded;
  }

  /// Start listening for speech. Calls [onResult] with recognized words.
  /// Calls [onDone] when listening stops (only fires when [continuous] is
  /// false or after [stop] is called).
  ///
  /// When [continuous] is true, listening automatically restarts after each
  /// pause/timeout until [stop] is called explicitly. This keeps the mic
  /// open so the actor can take their time before speaking.
  Future<void> listen({
    required void Function(String recognizedWords) onResult,
    void Function()? onDone,
    bool continuous = false,
    Duration listenFor = const Duration(seconds: 30),
    List<String>? vocabularyHints,
  }) async {
    if (_activeEngine == SttEngine.mlx && _mlxChannel.isInitialized) {
      await _listenWithMlx(
        onResult: onResult,
        onDone: onDone,
        listenFor: listenFor,
        vocabularyHints: vocabularyHints,
      );
    } else if (_activeEngine == SttEngine.whisper &&
        _whisperRecognizer != null) {
      await _listenWithWhisper(
        onResult: onResult,
        onDone: onDone,
        listenFor: listenFor,
      );
    } else {
      await _listenWithSystem(
        onResult: onResult,
        onDone: onDone,
        continuous: continuous,
      );
    }
  }

  // ── MLX Parakeet ──────────────────────────────────────

  Future<void> _listenWithMlx({
    required void Function(String recognizedWords) onResult,
    void Function()? onDone,
    required Duration listenFor,
    List<String>? vocabularyHints,
  }) async {
    _isListening = true;

    final tmpDir = await getTemporaryDirectory();
    final wavPath = p.join(tmpDir.path, 'stt_mlx_input.wav');

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      _isListening = false;
      onDone?.call();
      return;
    }

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 256000,
      ),
      path: wavPath,
    );

    _listenTimer = Timer(listenFor, () async {
      await _stopMlxRecording(wavPath, onResult, onDone, vocabularyHints);
    });
  }

  Future<void> _stopMlxRecording(
    String wavPath,
    void Function(String recognizedWords) onResult,
    void Function()? onDone,
    List<String>? vocabularyHints,
  ) async {
    _listenTimer?.cancel();
    _listenTimer = null;

    if (!_isListening) return;
    _isListening = false;

    await _recorder.stop();

    try {
      final audioFile = File(wavPath);
      if (!await audioFile.exists()) {
        onDone?.call();
        return;
      }

      final text = await _mlxChannel.transcribe(
        wavPath,
        vocabularyHints: vocabularyHints,
      );

      if (text != null && text.trim().isNotEmpty) {
        onResult(text.trim());
      }

      await audioFile.delete().catchError((_) => audioFile);
    } catch (e) {
      debugPrint('MLX transcription failed: $e');
    }

    onDone?.call();
  }

  // ── Whisper (sherpa-onnx) ─────────────────────────────

  Future<void> _listenWithWhisper({
    required void Function(String recognizedWords) onResult,
    void Function()? onDone,
    required Duration listenFor,
  }) async {
    _isListening = true;

    final tmpDir = await getTemporaryDirectory();
    final wavPath = p.join(tmpDir.path, 'stt_input.wav');

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      _isListening = false;
      onDone?.call();
      return;
    }

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 256000,
      ),
      path: wavPath,
    );

    _listenTimer = Timer(listenFor, () async {
      await _stopWhisperRecording(wavPath, onResult, onDone);
    });
  }

  Future<void> _stopWhisperRecording(
    String wavPath,
    void Function(String recognizedWords) onResult,
    void Function()? onDone,
  ) async {
    _listenTimer?.cancel();
    _listenTimer = null;

    if (!_isListening) return;
    _isListening = false;

    final resultPath = await _recorder.stop();
    if (resultPath == null) {
      onDone?.call();
      return;
    }

    try {
      final audioFile = File(wavPath);
      if (!await audioFile.exists()) {
        onDone?.call();
        return;
      }

      final bytes = await audioFile.readAsBytes();
      final samples = _wavToFloat32(bytes);
      if (samples == null) {
        onDone?.call();
        return;
      }

      final stream = _whisperRecognizer!.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      _whisperRecognizer!.decode(stream);
      final result = _whisperRecognizer!.getResult(stream);
      stream.free();

      final text = result.text.trim();
      if (text.isNotEmpty) {
        onResult(text);
      }

      await audioFile.delete().catchError((_) => audioFile);
    } catch (e) {
      debugPrint('Whisper recognition failed: $e');
    }

    onDone?.call();
  }

  // ── System STT ────────────────────────────────────────

  Future<void> _listenWithSystem({
    required void Function(String recognizedWords) onResult,
    void Function()? onDone,
    bool continuous = false,
  }) async {
    // Lazy-init system STT only when actually needed
    if (!_systemInitialized) {
      _systemInitialized = await _systemStt.initialize();
      if (!_systemInitialized) {
        debugPrint('STT: System STT unavailable');
        onDone?.call();
        return;
      }
    }

    _isListening = true;
    _continuousMode = continuous;

    await _startListenSession(onResult: onResult, onDone: onDone);
  }

  Future<void> _startListenSession({
    required void Function(String recognizedWords) onResult,
    void Function()? onDone,
  }) async {
    await _systemStt.listen(
      onResult: (result) {
        onResult(result.recognizedWords);
        if (result.finalResult) {
          if (_continuousMode && _isListening) {
            // Auto-restart after a brief pause so the mic stays open
            Future.delayed(const Duration(milliseconds: 200), () {
              if (_isListening) {
                _startListenSession(onResult: onResult, onDone: onDone);
              }
            });
          } else {
            _isListening = false;
            onDone?.call();
          }
        }
      },
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 5),
      listenOptions: SpeechListenOptions(listenMode: ListenMode.dictation),
    );
  }

  // ── Stop / Transcribe ─────────────────────────────────

  /// Stop listening. Also exits continuous mode.
  Future<void> stop() async {
    _listenTimer?.cancel();
    _listenTimer = null;
    _continuousMode = false;

    if (_activeEngine == SttEngine.mlx || _activeEngine == SttEngine.whisper) {
      _isListening = false;
      await _recorder.stop();
    } else {
      _isListening = false;
      await _systemStt.stop();
    }
  }

  /// Transcribe a pre-recorded audio file.
  Future<String?> transcribeFile(String audioPath,
      {List<String>? vocabularyHints}) async {
    // Try MLX first
    if (_mlxChannel.isInitialized) {
      return _mlxChannel.transcribe(audioPath,
          vocabularyHints: vocabularyHints);
    }

    // Fall back to Whisper
    if (_whisperRecognizer == null) return null;

    try {
      final bytes = await File(audioPath).readAsBytes();
      final samples = _wavToFloat32(bytes);
      if (samples == null) return null;

      final stream = _whisperRecognizer!.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      _whisperRecognizer!.decode(stream);
      final result = _whisperRecognizer!.getResult(stream);
      stream.free();

      return result.text.trim();
    } catch (e) {
      debugPrint('Whisper transcribe failed: $e');
      return null;
    }
  }

  // ── Match Score ───────────────────────────────────────

  /// Simple fuzzy match: what percentage of expected words were spoken.
  static double matchScore(String expected, String spoken) {
    final normalizedExpected = _normalize(expected);
    if (normalizedExpected.isEmpty) return 1.0;

    final expectedWords = normalizedExpected.split(RegExp(r'\s+'));
    final spokenWords = _normalize(spoken).split(RegExp(r'\s+'));

    int matched = 0;
    for (final word in expectedWords) {
      if (spokenWords.contains(word)) matched++;
    }

    return matched / expectedWords.length;
  }

  static String _normalize(String text) {
    return text.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '').trim();
  }

  // ── Helpers ───────────────────────────────────────────

  /// Extract Float32 samples from WAV bytes.
  Float32List? _wavToFloat32(Uint8List bytes) {
    if (bytes.length < 44) return null;

    if (bytes[0] != 0x52 || bytes[1] != 0x49 ||
        bytes[2] != 0x46 || bytes[3] != 0x46) {
      return null;
    }

    final byteData = ByteData.sublistView(bytes);
    final bitsPerSample = byteData.getUint16(34, Endian.little);
    const dataStart = 44;

    if (bitsPerSample == 16) {
      final numSamples = (bytes.length - dataStart) ~/ 2;
      final samples = Float32List(numSamples);
      for (var i = 0; i < numSamples; i++) {
        samples[i] =
            byteData.getInt16(dataStart + i * 2, Endian.little) / 32768.0;
      }
      return samples;
    }

    return null;
  }

  void dispose() {
    _whisperRecognizer?.free();
    _whisperRecognizer = null;
    _mlxChannel.dispose();
    _listenTimer?.cancel();
    _recorder.dispose();
  }
}
