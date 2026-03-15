import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Platform channel wrapper for MLX-based speech-to-text on iOS.
///
/// Communicates with MLXSttPlugin.swift via FlutterMethodChannel.
/// Falls back gracefully when MLX is not available (Android, simulator).
class MlxSttChannel {
  MlxSttChannel._();
  static final instance = MlxSttChannel._();

  static const _channel = MethodChannel('com.lineguide/mlx_stt');
  static const _streamEvents = EventChannel('com.lineguide/mlx_stt_stream');

  bool _initialized = false;

  bool get isInitialized => _initialized;

  /// Initialize the MLX STT model from a local path.
  /// Returns true if the model loaded successfully.
  Future<bool> initialize(String modelPath) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'initialize',
        {'modelPath': modelPath},
      );
      _initialized = result ?? false;
      debugPrint('MlxStt: initialize($modelPath) = $_initialized');
      return _initialized;
    } on PlatformException catch (e) {
      debugPrint('MlxStt: initialize failed: ${e.message}');
      return false;
    } on MissingPluginException {
      // Platform channel not available (Android, web, simulator)
      debugPrint('MlxStt: Platform channel not available');
      return false;
    }
  }

  /// Transcribe audio from a WAV file path.
  /// Returns the transcribed text, or null on failure.
  Future<String?> transcribe(
    String audioPath, {
    List<String>? vocabularyHints,
  }) async {
    if (!_initialized) return null;

    try {
      final result = await _channel.invokeMethod<String>(
        'transcribe',
        {
          'audioPath': audioPath,
          if (vocabularyHints != null) 'vocabularyHints': vocabularyHints,
        },
      );
      return result;
    } on PlatformException catch (e) {
      debugPrint('MlxStt: transcribe failed: ${e.message}');
      return null;
    }
  }

  /// Check if the MLX model is loaded and ready.
  Future<bool> isReady() async {
    try {
      return await _channel.invokeMethod<bool>('isReady') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Load a LoRA adapter for personalized STT.
  Future<bool> loadAdapter(String adapterPath) async {
    try {
      return await _channel.invokeMethod<bool>(
            'loadAdapter',
            {'adapterPath': adapterPath},
          ) ??
          false;
    } on PlatformException catch (e) {
      debugPrint('MlxStt: loadAdapter failed: ${e.message}');
      return false;
    }
  }

  /// Unload the current LoRA adapter.
  Future<bool> unloadAdapter() async {
    try {
      return await _channel.invokeMethod<bool>('unloadAdapter') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Stream of partial transcription results from streaming mode.
  /// Each event is a map with 'type' ('partial' or 'final') and 'text'.
  Stream<Map<String, dynamic>> get transcriptionStream {
    return _streamEvents.receiveBroadcastStream().map(
          (event) => Map<String, dynamic>.from(event as Map),
        );
  }

  /// Transcribe audio with streaming — sends partial results via
  /// [transcriptionStream] as text is recognized progressively.
  /// Returns the final transcribed text.
  Future<String?> transcribeStreaming(
    String audioPath, {
    List<String>? vocabularyHints,
  }) async {
    if (!_initialized) return null;

    try {
      final result = await _channel.invokeMethod<String>(
        'transcribeStreaming',
        {
          'audioPath': audioPath,
          if (vocabularyHints != null) 'vocabularyHints': vocabularyHints,
        },
      );
      return result;
    } on PlatformException catch (e) {
      debugPrint('MlxStt: transcribeStreaming failed: ${e.message}');
      return null;
    }
  }

  /// Check if the Parakeet model files exist on disk.
  Future<bool> isModelDownloaded() async {
    try {
      return await _channel.invokeMethod<bool>('isModelDownloaded') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Clean up native resources.
  Future<void> dispose() async {
    try {
      await _channel.invokeMethod<void>('dispose');
      _initialized = false;
    } on PlatformException {
      // Ignore
    }
  }
}
