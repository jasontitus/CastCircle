import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
/// Kokoro MLX model files are downloaded to Documents/models/kokoro_mlx/
/// to match the path expected by KokoroMLXService.swift.
class ModelDownloadService {
  ModelDownloadService._();
  static final instance = ModelDownloadService._();

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
          'https://media.githubusercontent.com/media/mlalma/KokoroTestApp/main/Resources/voices.npz',
      filename: 'voices.npz',
      subdir: 'kokoro_mlx',
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

  /// Check which models are already downloaded on disk.
  Future<void> refreshDownloadedStatus() async {
    for (final model in availableModels) {
      final path = await _filePath(model);
      if (File(path).existsSync()) {
        _states[model.id] = const ModelDownloadState(
          status: ModelStatus.downloaded,
          progress: 1.0,
        );
      }
    }
    _notify();
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

  /// Download a model file with progress reporting.
  ///
  /// Follows redirects (HuggingFace and GitHub LFS both redirect).
  Future<void> download(AiModel model) async {
    if (model.downloadUrl.isEmpty) {
      _states[model.id] = const ModelDownloadState(
        status: ModelStatus.error,
        errorMessage: 'Model not yet available for download',
      );
      _notify();
      return;
    }

    _states[model.id] = const ModelDownloadState(
      status: ModelStatus.downloading,
      progress: 0.0,
    );
    _notify();

    try {
      final outPath = await _filePath(model);
      final outFile = File(outPath);
      await outFile.parent.create(recursive: true);

      await _downloadFile(model.downloadUrl, outPath, (progress) {
        _states[model.id] = ModelDownloadState(
          status: ModelStatus.downloading,
          progress: progress,
        );
        _notify();
      });

      // Verify file size is reasonable
      final size = await outFile.length();
      if (size < 1000) {
        await outFile.delete();
        throw Exception('Downloaded file too small ($size bytes)');
      }

      _states[model.id] = const ModelDownloadState(
        status: ModelStatus.downloaded,
        progress: 1.0,
      );
      _notify();

      debugPrint(
          'ModelDownload: ${model.id} downloaded (${(size / 1024 / 1024).toStringAsFixed(1)} MB)');
    } catch (e) {
      _states[model.id] = ModelDownloadState(
        status: ModelStatus.error,
        errorMessage: e.toString(),
      );
      _notify();
      debugPrint('ModelDownload: ${model.id} failed: $e');
    }
  }

  /// Download all available models in parallel.
  Future<void> downloadAll() async {
    await Future.wait(
      availableModels
          .where((m) => m.downloadUrl.isNotEmpty)
          .map((m) => download(m)),
    );
  }

  /// Delete a downloaded model file.
  Future<void> delete(String modelId) async {
    final model = availableModels.where((m) => m.id == modelId).firstOrNull;
    if (model != null) {
      final path = await _filePath(model);
      final file = File(path);
      if (file.existsSync()) await file.delete();
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

  /// Download a file with redirect handling and progress reporting.
  Future<void> _downloadFile(
    String url,
    String localPath,
    void Function(double progress) onProgress,
  ) async {
    final client = HttpClient();
    client.autoUncompress = false;
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();

      // Handle redirects (HuggingFace and GitHub LFS both redirect)
      if (response.statusCode == 301 ||
          response.statusCode == 302 ||
          response.statusCode == 307 ||
          response.isRedirect) {
        final redirectUrl = response.headers.value('location');
        if (redirectUrl != null) {
          await response.drain<void>();
          client.close();
          await _downloadFile(redirectUrl, localPath, onProgress);
          return;
        }
      }

      if (response.statusCode != 200) {
        await response.drain<void>();
        throw HttpException(
          'Server returned ${response.statusCode}',
          uri: Uri.parse(url),
        );
      }

      final contentLength = response.contentLength;
      final tmpPath = '$localPath.tmp';
      final sink = File(tmpPath).openWrite();
      int received = 0;

      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (contentLength > 0) {
          onProgress((received / contentLength).clamp(0.0, 1.0));
        }
      }

      await sink.flush();
      await sink.close();
      await File(tmpPath).rename(localPath);
      onProgress(1.0);

      debugPrint(
          'Downloaded: ${p.basename(localPath)} (${(received / 1024 / 1024).toStringAsFixed(1)} MB)');
    } finally {
      client.close();
    }
  }
}
