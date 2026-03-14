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
  static const _trainingEvents = EventChannel('com.lineguide/mlx_stt_training');

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

  /// Listen for LoRA training progress events.
  Stream<Map<String, dynamic>> get trainingProgress {
    return _trainingEvents.receiveBroadcastStream().map(
          (event) => Map<String, dynamic>.from(event as Map),
        );
  }

  /// Download the Parakeet model from HuggingFace via mlx-audio-swift.
  /// Returns true if download succeeded (or model already exists).
  /// [onProgress] reports 0.0–1.0 progress.
  Future<bool> downloadModel({
    void Function(double progress)? onProgress,
  }) async {
    try {
      final result = await _channel.invokeMethod<bool>('downloadModel');
      onProgress?.call(1.0);
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('MlxStt: downloadModel failed: ${e.message}');
      return false;
    } on MissingPluginException {
      debugPrint('MlxStt: Platform channel not available for download');
      return false;
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
