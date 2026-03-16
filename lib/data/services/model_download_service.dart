import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'tts_service.dart';

/// Represents a downloadable on-device AI model file.
class AiModel {
  final String id;
  final String name;
  final String description;
  final String sizeLabel;
  final int sizeBytes;
  final String downloadUrl;

  /// The filename to save as (e.g. 'kokoro-v1_0.safetensors').
  final String filename;

  /// Subdirectory within the models dir (e.g. 'kokoro_mlx').
  final String subdir;

  const AiModel({
    required this.id,
    required this.name,
    required this.description,
    required this.sizeLabel,
    required this.sizeBytes,
    required this.downloadUrl,
    required this.filename,
    this.subdir = '',
  });
}

/// Download status for a single model.
enum ModelStatus {
  notDownloaded,
  downloading,
  downloaded,
  error,
}

/// Progress info for an in-flight download.
class ModelDownloadState {
  final ModelStatus status;
  final double progress; // 0.0 – 1.0
  final String? errorMessage;

  const ModelDownloadState({
    this.status = ModelStatus.notDownloaded,
    this.progress = 0.0,
    this.errorMessage,
  });

  ModelDownloadState copyWith({
    ModelStatus? status,
    double? progress,
    String? errorMessage,
  }) {
    return ModelDownloadState(
      status: status ?? this.status,
      progress: progress ?? this.progress,
      errorMessage: errorMessage,
    );
  }
}

/// Service for downloading and managing on-device AI model files.
///
/// Uses native iOS background URLSession for downloads so they survive
/// screen sleep, app suspension, and even app termination.
///
/// Kokoro MLX model files are downloaded to Documents/models/kokoro_mlx/
/// to match the path expected by KokoroMLXService.swift.
class ModelDownloadService {
  ModelDownloadService._() {
    _setupNativeCallbacks();
  }
  static final instance = ModelDownloadService._();

  static const _channel =
      MethodChannel('com.lineguide/background_download');

  /// Registry of available models.
  static const List<AiModel> availableModels = [
    AiModel(
      id: 'kokoro_model',
      name: 'Kokoro TTS Model',
      description: 'Neural TTS model weights for on-device speech synthesis',
      sizeLabel: '~327 MB',
      sizeBytes: 327 * 1024 * 1024,
      downloadUrl:
          'https://huggingface.co/mlx-community/Kokoro-82M-bf16/resolve/main/kokoro-v1_0.safetensors',
      filename: 'kokoro-v1_0.safetensors',
      subdir: 'kokoro_mlx',
    ),
    AiModel(
      id: 'kokoro_voices',
      name: 'Kokoro Voice Styles',
      description: 'Voice embeddings for 28+ distinct character voices',
      sizeLabel: '~14 MB',
      sizeBytes: 14 * 1024 * 1024,
      downloadUrl:
          'https://github.com/mlalma/KokoroTestApp/raw/main/Resources/voices.npz',
      filename: 'voices.npz',
      subdir: 'kokoro_mlx',
    ),
    AiModel(
      id: 'parakeet_model',
      name: 'Parakeet STT Model',
      description: 'MLX neural speech-to-text (0.6B params)',
      sizeLabel: '~2.5 GB',
      sizeBytes: 2508288736,
      downloadUrl:
          'https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3/resolve/main/model.safetensors',
      filename: 'model.safetensors',
      subdir: 'parakeet_stt',
    ),
    AiModel(
      id: 'parakeet_config',
      name: 'Parakeet STT Config',
      description: 'Model configuration and vocabulary',
      sizeLabel: '~244 KB',
      sizeBytes: 244093,
      downloadUrl:
          'https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3/resolve/main/config.json',
      filename: 'config.json',
      subdir: 'parakeet_stt',
    ),
  ];

  final Map<String, ModelDownloadState> _states = {};
  final List<VoidCallback> _listeners = [];

  /// Current state for a model.
  ModelDownloadState getState(String modelId) {
    return _states[modelId] ?? const ModelDownloadState();
  }

  /// Register a listener for state changes.
  void addListener(VoidCallback listener) => _listeners.add(listener);

  /// Remove a listener.
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void _notify() {
    for (final l in _listeners) {
      l();
    }
  }

  /// Set up callbacks from native iOS for download progress/completion/error.
  void _setupNativeCallbacks() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onDownloadProgress':
          final args = call.arguments as Map;
          final modelId = args['modelId'] as String;
          final progress = (args['progress'] as num).toDouble();
          _states[modelId] = ModelDownloadState(
            status: ModelStatus.downloading,
            progress: progress,
          );
          _notify();
          break;

        case 'onDownloadComplete':
          final args = call.arguments as Map;
          final modelId = args['modelId'] as String;
          final size = args['size'] as int;
          _states[modelId] = const ModelDownloadState(
            status: ModelStatus.downloaded,
            progress: 1.0,
          );
          _notify();
          debugPrint(
              'ModelDownload: $modelId complete (${(size / 1024 / 1024).toStringAsFixed(1)} MB)');

          // Auto-load Kokoro TTS engine once both model files are downloaded
          if (modelId == 'kokoro_model' || modelId == 'kokoro_voices') {
            _tryLoadKokoroIfReady();
          }
          break;

        case 'onDownloadError':
          final args = call.arguments as Map;
          final modelId = args['modelId'] as String;
          final error = args['error'] as String;
          _states[modelId] = ModelDownloadState(
            status: ModelStatus.error,
            errorMessage: error,
          );
          _notify();
          debugPrint('ModelDownload: $modelId failed: $error');
          break;
      }
    });
  }

  /// Check which models are already downloaded on disk.
  Future<void> refreshDownloadedStatus() async {
    for (final model in availableModels) {
      final path = await _filePath(model);
      if (File(path).existsSync()) {
        _states[model.id] = const ModelDownloadState(
          status: ModelStatus.downloaded,
          progress: 1.0,
        );
      } else {
        // Reset error/stuck states on refresh — allow retry
        final current = _states[model.id];
        if (current != null && current.status != ModelStatus.downloading) {
          _states[model.id] = const ModelDownloadState();
        }
      }
    }
    // Clean up any leftover .tmp files from failed downloads
    await _cleanupTmpFiles();
    _notify();
  }

  /// Auto-load Kokoro TTS after both model files finish downloading.
  Future<void> _tryLoadKokoroIfReady() async {
    if (await isKokoroReady()) {
      debugPrint('ModelDownload: Both Kokoro files ready, loading TTS engine');
      await TtsService.instance.tryLoadKokoro();
    }
  }

  /// Whether all Kokoro files are downloaded.
  Future<bool> isKokoroReady() async {
    for (final model in availableModels) {
      if (model.subdir == 'kokoro_mlx') {
        final path = await _filePath(model);
        if (!File(path).existsSync()) return false;
      }
    }
    return true;
  }

  /// Whether all Parakeet STT files are downloaded.
  Future<bool> isParakeetReady() async {
    for (final model in availableModels) {
      if (model.subdir == 'parakeet_stt') {
        final path = await _filePath(model);
        if (!File(path).existsSync()) return false;
      }
    }
    return true;
  }

  /// Get the path to the Parakeet model directory, or null if not downloaded.
  Future<String?> getParakeetModelDir() async {
    if (!await isParakeetReady()) return null;
    final appDir = await getApplicationDocumentsDirectory();
    return p.join(appDir.path, 'models', 'parakeet_stt');
  }

  /// Download a model file using native iOS background URLSession.
  Future<void> download(AiModel model) async {
    if (model.downloadUrl.isEmpty) {
      _states[model.id] = const ModelDownloadState(
        status: ModelStatus.error,
        errorMessage: 'Model not yet available for download',
      );
      _notify();
      return;
    }

    // Reset state and clean up any leftover .tmp file
    _states[model.id] = const ModelDownloadState(
      status: ModelStatus.downloading,
      progress: 0.0,
    );
    _notify();

    try {
      final outPath = await _filePath(model);

      // Clean up .tmp file from previous failed download
      final tmpFile = File('$outPath.tmp');
      if (tmpFile.existsSync()) {
        await tmpFile.delete();
      }

      // Create destination directory
      await Directory(p.dirname(outPath)).create(recursive: true);

      // Start native background download
      await _channel.invokeMethod('startDownload', {
        'modelId': model.id,
        'url': model.downloadUrl,
        'destinationPath': outPath,
      });

      debugPrint('ModelDownload: started background download for ${model.id}');
    } catch (e) {
      _states[model.id] = ModelDownloadState(
        status: ModelStatus.error,
        errorMessage: e.toString(),
      );
      _notify();
      debugPrint('ModelDownload: ${model.id} failed to start: $e');
    }
  }

  /// Download all available models.
  Future<void> downloadAll() async {
    for (final m in availableModels) {
      if (m.downloadUrl.isNotEmpty) {
        await download(m);
      }
    }
  }

  /// Delete a downloaded model file.
  Future<void> delete(String modelId) async {
    final model = availableModels.where((m) => m.id == modelId).firstOrNull;
    if (model != null) {
      final path = await _filePath(model);
      final file = File(path);
      if (file.existsSync()) await file.delete();
      // Also clean up any .tmp file
      final tmpFile = File('$path.tmp');
      if (tmpFile.existsSync()) await tmpFile.delete();
    }
    _states[modelId] = const ModelDownloadState();
    _notify();
  }

  /// Delete all Kokoro model files.
  Future<void> deleteKokoro() async {
    final dir = await _kokoroDir();
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
    for (final model in availableModels) {
      if (model.subdir == 'kokoro_mlx') {
        _states[model.id] = const ModelDownloadState();
      }
    }
    _notify();
  }

  /// Full path where a model file will be saved.
  Future<String> _filePath(AiModel model) async {
    final appDir = await getApplicationDocumentsDirectory();
    if (model.subdir.isNotEmpty) {
      return p.join(appDir.path, 'models', model.subdir, model.filename);
    }
    return p.join(appDir.path, 'models', model.filename);
  }

  Future<Directory> _kokoroDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    return Directory(p.join(appDir.path, 'models', 'kokoro_mlx'));
  }

  /// Remove leftover .tmp files from failed downloads.
  Future<void> _cleanupTmpFiles() async {
    for (final model in availableModels) {
      final path = await _filePath(model);
      final tmpFile = File('$path.tmp');
      if (tmpFile.existsSync()) {
        try {
          await tmpFile.delete();
          debugPrint('ModelDownload: cleaned up ${model.id}.tmp');
        } catch (e) {
          debugPrint('ModelDownload: failed to clean ${model.id}.tmp: $e');
        }
      }
    }
  }
}
