import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:speech_to_text/speech_to_text.dart';

import 'mlx_stt_channel.dart';

/// STT engine type.
enum SttEngine {
  /// MLX Parakeet on-device via mlx-audio-swift (future, when linked).
  mlx,

  /// Apple SFSpeechRecognizer (primary engine).
  system,
}

/// Speech-to-text service with tiered engine priority:
///
///   1. MLX Parakeet (best quality, supports LoRA fine-tuning — future)
///   2. Apple SFSpeechRecognizer (primary, on-device, good quality)
class SttService {
  SttService._();
  static final instance = SttService._();

  // System STT — Apple SFSpeechRecognizer
  final SpeechToText _systemStt = SpeechToText();
  bool _systemInitialized = false;
  bool _continuousMode = false;

  // MLX Parakeet via platform channel (future)
  final MlxSttChannel _mlxChannel = MlxSttChannel.instance;

  // Recording (for MLX transcription path)
  final AudioRecorder _recorder = AudioRecorder();
  bool _isListening = false;
  Timer? _listenTimer;

  SttEngine _activeEngine = SttEngine.system;

  SttEngine get activeEngine => _activeEngine;
  bool get isListening => _isListening;
  bool get isMlxReady => _mlxChannel.isInitialized;

  /// Check if STT is available (MLX or system).
  bool get isAvailable => _mlxChannel.isInitialized || _systemInitialized;

  Future<bool> init() async {
    // 1. Try MLX Parakeet first (iOS only, best quality)
    final mlxLoaded = await _initMlx();
    if (mlxLoaded) {
      _activeEngine = SttEngine.mlx;
      debugPrint('STT: MLX Parakeet ready');
      return true;
    }

    // 2. Use Apple SFSpeechRecognizer (primary engine)
    _activeEngine = SttEngine.system;
    _systemInitialized = await _systemStt.initialize();
    if (_systemInitialized) {
      debugPrint('STT: Apple SFSpeechRecognizer ready');
      return true;
    }

    debugPrint('STT: No STT engine available');
    return false;
  }

  Future<bool> _initMlx() async {
    // Initialize the native STT plugin (Apple SFSpeechRecognizer via
    // the Parakeet platform channel). No model path needed — the native
    // side handles everything.
    try {
      return await _mlxChannel.initialize('builtin');
    } catch (e) {
      debugPrint('STT: MLX/Parakeet init failed: $e');
      return false;
    }
  }

  /// Re-attempt MLX init (e.g. after model download).
  Future<bool> reloadMlx() async {
    final mlxLoaded = await _initMlx();
    if (mlxLoaded) {
      _activeEngine = SttEngine.mlx;
      return true;
    }
    return false;
  }

  /// Start listening for speech. Calls [onResult] with recognized words.
  /// Calls [onDone] when listening stops.
  ///
  /// When [continuous] is true, listening automatically restarts after each
  /// pause/timeout until [stop] is called explicitly.
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

      // Use streaming transcription to show partial results in real-time.
      // Listen for partial results on the event channel.
      StreamSubscription? streamSub;
      streamSub = _mlxChannel.transcriptionStream.listen((event) {
        final text = event['text'] as String?;
        if (text != null && text.trim().isNotEmpty) {
          onResult(text.trim());
        }
      }, onError: (_) {});

      // transcribeStreaming sends partials via eventSink and returns final text
      final text = await _mlxChannel.transcribeStreaming(
        wavPath,
        vocabularyHints: vocabularyHints,
      );

      await streamSub.cancel();

      // Send final result
      if (text != null && text.trim().isNotEmpty) {
        onResult(text.trim());
      }

      await audioFile.delete().catchError((_) => audioFile);
    } catch (e) {
      debugPrint('MLX transcription failed: $e');
    }

    onDone?.call();
  }

  // ── System STT (Apple SFSpeechRecognizer) ─────────────

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

    if (_activeEngine == SttEngine.mlx) {
      _isListening = false;
      await _recorder.stop();
    } else {
      _isListening = false;
      await _systemStt.stop();
    }
  }

  /// Transcribe a pre-recorded audio file (MLX only).
  Future<String?> transcribeFile(String audioPath,
      {List<String>? vocabularyHints}) async {
    if (_mlxChannel.isInitialized) {
      return _mlxChannel.transcribe(audioPath,
          vocabularyHints: vocabularyHints);
    }
    return null;
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

  void dispose() {
    _mlxChannel.dispose();
    _listenTimer?.cancel();
    _recorder.dispose();
  }
}
