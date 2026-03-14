import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Represents a downloadable on-device AI model.
class AiModel {
  final String id;
  final String name;
  final String description;
  final String sizeLabel;
  final int sizeBytes;
  final String downloadUrl;

  const AiModel({
    required this.id,
    required this.name,
    required this.description,
    required this.sizeLabel,
    required this.sizeBytes,
    required this.downloadUrl,
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
/// Downloads use plain async/await on the main isolate — HTTP downloads are
/// I/O-bound so there is no benefit to spawning a separate isolate, and
/// doing so causes crashes because [HttpClient], [Completer], and other
/// dart:async objects cannot be sent across isolate boundaries via
/// [SendPort.send].
class ModelDownloadService {
  ModelDownloadService._();
  static final instance = ModelDownloadService._();

  /// Registry of available models.
  static const List<AiModel> availableModels = [
    AiModel(
      id: 'vad',
      name: 'Voice Activity Detection',
      description: 'Detects when you start/stop speaking (~2 MB)',
      sizeLabel: '~2 MB',
      sizeBytes: 2 * 1024 * 1024,
      downloadUrl: '', // populated when backend is ready
    ),
    AiModel(
      id: 'kokoro_tts',
      name: 'Kokoro TTS',
      description: 'On-device neural text-to-speech (~80 MB)',
      sizeLabel: '~80 MB',
      sizeBytes: 80 * 1024 * 1024,
      downloadUrl: '',
    ),
    AiModel(
      id: 'whisper_stt',
      name: 'Whisper STT',
      description: 'On-device speech recognition (~40 MB)',
      sizeLabel: '~40 MB',
      sizeBytes: 40 * 1024 * 1024,
      downloadUrl: '',
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
    final dir = await _modelsDir();
    for (final model in availableModels) {
      final file = File(p.join(dir, '${model.id}.onnx'));
      if (file.existsSync()) {
        _states[model.id] = const ModelDownloadState(
          status: ModelStatus.downloaded,
          progress: 1.0,
        );
      }
    }
    _notify();
  }

  /// Download a model file to the local models directory.
  ///
  /// This runs on the main isolate using async I/O — no isolate spawning
  /// is needed and avoids the "unsendable object" crash.
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
      final dir = await _modelsDir();
      final outFile = File(p.join(dir, '${model.id}.onnx'));

      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(model.downloadUrl));
        final response = await request.close();

        if (response.statusCode != 200) {
          throw HttpException(
            'Server returned ${response.statusCode}',
            uri: Uri.parse(model.downloadUrl),
          );
        }

        final contentLength = response.contentLength;
        final sink = outFile.openWrite();
        int received = 0;

        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          if (contentLength > 0) {
            _states[model.id] = ModelDownloadState(
              status: ModelStatus.downloading,
              progress: (received / contentLength).clamp(0.0, 1.0),
            );
            _notify();
          }
        }

        await sink.flush();
        await sink.close();
      } finally {
        client.close();
      }

      _states[model.id] = const ModelDownloadState(
        status: ModelStatus.downloaded,
        progress: 1.0,
      );
      _notify();

      debugPrint('ModelDownload: ${model.id} downloaded to ${outFile.path}');
    } catch (e) {
      _states[model.id] = ModelDownloadState(
        status: ModelStatus.error,
        errorMessage: e.toString(),
      );
      _notify();
      debugPrint('ModelDownload: ${model.id} failed: $e');
    }
  }

  /// Delete a downloaded model file.
  Future<void> delete(String modelId) async {
    final dir = await _modelsDir();
    final file = File(p.join(dir, '$modelId.onnx'));
    if (file.existsSync()) {
      await file.delete();
    }
    _states[modelId] = const ModelDownloadState();
    _notify();
  }

  /// Get the local path for a downloaded model, or null if not downloaded.
  Future<String?> modelPath(String modelId) async {
    final dir = await _modelsDir();
    final file = File(p.join(dir, '$modelId.onnx'));
    return file.existsSync() ? file.path : null;
  }

  Future<String> _modelsDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDir.path, 'ai_models'));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir.path;
  }
}
