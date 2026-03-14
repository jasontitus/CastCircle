import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:speech_to_text/speech_to_text.dart';

import 'model_manager.dart';

/// STT engine type.
enum SttEngine {
  /// Whisper on-device via sherpa-onnx (default).
  whisper,

  /// System STT (fallback if Whisper model not downloaded).
  system,
}

/// Speech-to-text service using Whisper via sherpa-onnx.
///
/// Falls back to system STT if Whisper model is not downloaded.
class SttService {
  SttService._();
  static final instance = SttService._();

  // System STT fallback
  final SpeechToText _systemStt = SpeechToText();
  bool _systemInitialized = false;

  // Whisper via sherpa-onnx
  sherpa.OfflineRecognizer? _whisperRecognizer;
  SttEngine _activeEngine = SttEngine.system;

  // Recording for Whisper
  final AudioRecorder _recorder = AudioRecorder();
  bool _isListening = false;
  Timer? _listenTimer;

  SttEngine get activeEngine => _activeEngine;
  bool get isListening => _isListening;
  bool get isWhisperReady => _whisperRecognizer != null;

  Future<bool> init() async {
    // Try Whisper first
    final whisperLoaded = await _initWhisper();
    if (whisperLoaded) {
      _activeEngine = SttEngine.whisper;
      debugPrint('STT: Whisper ready (sherpa-onnx)');
      return true;
    }

    // Fallback to system STT
    _activeEngine = SttEngine.system;
    _systemInitialized = await _systemStt.initialize();
    debugPrint('STT: Using system STT (Whisper not available)');
    return _systemInitialized;
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

  /// Re-attempt Whisper init (e.g. after model download).
  Future<bool> reloadWhisper() async {
    final loaded = await _initWhisper();
    if (loaded) _activeEngine = SttEngine.whisper;
    return loaded;
  }

  /// Start listening for speech.
  Future<void> listen({
    required void Function(String recognizedWords) onResult,
    void Function()? onDone,
    Duration listenFor = const Duration(seconds: 30),
  }) async {
    if (_activeEngine == SttEngine.whisper && _whisperRecognizer != null) {
      await _listenWithWhisper(
        onResult: onResult,
        onDone: onDone,
        listenFor: listenFor,
      );
    } else {
      await _listenWithSystem(
        onResult: onResult,
        onDone: onDone,
      );
    }
  }

  Future<void> _listenWithWhisper({
    required void Function(String recognizedWords) onResult,
    void Function()? onDone,
    required Duration listenFor,
  }) async {
    _isListening = true;

    // Record audio to a temporary WAV file
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

    // Stop after timeout
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

    // Recognize with Whisper
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

      // Clean up
      await audioFile.delete().catchError((_) => audioFile);
    } catch (e) {
      debugPrint('Whisper recognition failed: $e');
    }

    onDone?.call();
  }

  Future<void> _listenWithSystem({
    required void Function(String recognizedWords) onResult,
    void Function()? onDone,
  }) async {
    if (!_systemInitialized) {
      _systemInitialized = await _systemStt.initialize();
      if (!_systemInitialized) return;
    }

    _isListening = true;
    await _systemStt.listen(
      onResult: (result) {
        onResult(result.recognizedWords);
        if (result.finalResult) {
          _isListening = false;
          onDone?.call();
        }
      },
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 3),
      listenOptions: SpeechListenOptions(listenMode: ListenMode.dictation),
    );
  }

  /// Stop listening.
  Future<void> stop() async {
    _listenTimer?.cancel();
    _listenTimer = null;

    if (_activeEngine == SttEngine.whisper) {
      _isListening = false;
      // Force stop recording and transcribe what we have
      final tmpDir = await getTemporaryDirectory();
      final wavPath = p.join(tmpDir.path, 'stt_input.wav');
      await _recorder.stop();
      _isListening = false;
    } else {
      _isListening = false;
      await _systemStt.stop();
    }
  }

  /// Transcribe a pre-recorded audio file.
  Future<String?> transcribeFile(String audioPath) async {
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

  /// Check if speech recognition is available.
  Future<bool> get isAvailable async {
    if (_whisperRecognizer != null) return true;
    if (!_systemInitialized) await init();
    return _systemInitialized;
  }

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
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .trim();
  }

  /// Extract Float32 samples from WAV bytes.
  Float32List? _wavToFloat32(Uint8List bytes) {
    if (bytes.length < 44) return null;

    // Verify RIFF header
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
    _listenTimer?.cancel();
    _recorder.dispose();
  }
}
