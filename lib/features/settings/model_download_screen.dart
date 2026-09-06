import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/responsive.dart';
import '../../core/toast.dart';
import '../../data/services/debug_log_service.dart';
import '../../data/services/model_download_service.dart';
import '../../data/services/model_manager.dart';
import '../../data/services/tts_service.dart';

class ModelDownloadScreen extends ConsumerStatefulWidget {
  const ModelDownloadScreen({super.key});

  @override
  ConsumerState<ModelDownloadScreen> createState() =>
      _ModelDownloadScreenState();
}

class _ModelDownloadScreenState extends ConsumerState<ModelDownloadScreen> {
  final _manager = ModelManager.instance;
  final _downloadService = ModelDownloadService.instance;

  bool _downloading = false;
  String? _error;

  // Per-model progress for parallel downloads
  final Map<String, double> _modelProgress = {};

  bool _allReady = false;
  bool get _usesIosMlx => Platform.isIOS;
  bool get _supportsModelDownloads => Platform.isIOS || Platform.isAndroid;

  Iterable<AiModel> get _trackedServiceModels {
    final subdir = _usesIosMlx
        ? 'kokoro_mlx'
        : Platform.isAndroid
        ? 'live_asr'
        : null;
    if (subdir == null) return const Iterable<AiModel>.empty();
    return ModelDownloadService.availableModels.where(
      (model) => model.subdir == subdir,
    );
  }

  String? get _trackedServiceError {
    final errors = <String>[];
    for (final model in _trackedServiceModels) {
      final state = _downloadService.getState(model.id);
      if (state.status == ModelStatus.error) {
        errors.add('${model.name}: ${state.errorMessage ?? 'Unknown error'}');
      }
    }
    return errors.isEmpty ? null : errors.join('; ');
  }

  @override
  void initState() {
    super.initState();
    if (_supportsModelDownloads) {
      _downloadService.addListener(_onDownloadUpdate);
    }
    _checkStatus();
  }

  @override
  void dispose() {
    if (_supportsModelDownloads) {
      _downloadService.removeListener(_onDownloadUpdate);
    }
    super.dispose();
  }

  void _onDownloadUpdate() {
    if (!mounted) return;
    final states = {
      for (final model in _trackedServiceModels)
        model: _downloadService.getState(model.id),
    };
    final downloading = states.values.any(
      (state) => state.status == ModelStatus.downloading,
    );
    final error = _trackedServiceError;

    setState(() {
      for (final entry in states.entries) {
        final state = entry.value;
        if (state.status == ModelStatus.downloading ||
            state.status == ModelStatus.downloaded) {
          _modelProgress[entry.key.name] = state.progress;
        }
      }
      if (_usesIosMlx) _downloading = downloading;
      if (error != null) _error = error;
    });
    if (_usesIosMlx && !downloading) unawaited(_checkStatus());
  }

  Future<void> _checkStatus() async {
    if (!_supportsModelDownloads) {
      if (mounted) {
        setState(() {
          _allReady = true;
          _error = null;
        });
      }
      return;
    }

    try {
      final ready = await _manager.isAllReady();
      final serviceError = _trackedServiceError;
      if (mounted) {
        setState(() {
          _allReady = ready;
          _error = serviceError;
        });
      }
    } catch (error, stack) {
      DebugLogService.instance.logError(
        LogCategory.ai,
        'Could not check model status',
        error,
        stack,
      );
      if (mounted) {
        setState(() => _error = 'Could not check model status: $error');
      }
    }
  }

  Future<void> _downloadAll() async {
    if (!_supportsModelDownloads) return;
    setState(() {
      _downloading = true;
      _error = null;
      _modelProgress.clear();
    });

    try {
      if (_usesIosMlx) {
        await _downloadService.downloadKokoro();
        final error = _trackedServiceError;
        if (error != null) throw StateError(error);
      } else {
        await _manager.downloadAll(
          onProgress: (model, file, progress) {
            if (mounted) {
              setState(() {
                _modelProgress[model] = progress;
              });
            }
          },
        );
        final error = _trackedServiceError;
        if (error != null) throw StateError(error);
        await _checkStatus();
      }
    } catch (error, stack) {
      DebugLogService.instance.logError(
        LogCategory.ai,
        'Model download failed',
        error,
        stack,
      );
      if (mounted) {
        setState(() {
          _error = error.toString();
        });
      }
    } finally {
      if (mounted &&
          (!_usesIosMlx ||
              !_downloadServiceStatesContain(ModelStatus.downloading))) {
        setState(() {
          _downloading = false;
        });
      }
    }
  }

  bool _downloadServiceStatesContain(ModelStatus status) {
    return _trackedServiceModels
        .map((model) => _downloadService.getState(model.id).status)
        .contains(status);
  }

  String get _kokoroDownloadSize {
    final bytes = ModelDownloadService.availableModels
        .where((model) => model.subdir == 'kokoro_mlx')
        .fold<int>(0, (total, model) => total + model.sizeBytes);
    final roundedToTenMb = (bytes / 10000000).round() * 10;
    return '~$roundedToTenMb MB';
  }

  String get _totalDownloadSize {
    if (_usesIosMlx) return _kokoroDownloadSize;
    if (!Platform.isAndroid) return 'No download';
    final asrBytes = ModelDownloadService.availableModels
        .where((model) => model.subdir == 'live_asr')
        .fold<int>(0, (total, model) => total + model.sizeBytes);
    // The Android Kokoro pack is the same approximately 180 MB shown on its
    // dedicated model-management tile.
    final roundedToTenMb = ((180000000 + asrBytes) / 10000000).round() * 10;
    return '~$roundedToTenMb MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!_supportsModelDownloads) {
      return Scaffold(
        appBar: AppBar(title: const Text('AI Models')),
        body: ContentConstraint(
          maxWidth: 700,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('System text-to-speech', style: theme.textTheme.bodyLarge),
              const SizedBox(height: 8),
              Text(
                'This platform uses its built-in system voices. '
                'No on-device AI model download is available or required.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 24),
              _modelCard(
                context,
                title: 'System voices',
                subtitle: 'Provided by the operating system',
                size: 'No download',
                ready: true,
                icon: Icons.record_voice_over,
              ),
            ],
          ),
        ),
      );
    }
    final allReady = _allReady;
    return Scaffold(
      appBar: AppBar(title: const Text('AI Models')),
      body: ContentConstraint(
        maxWidth: 700,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'On-device AI models for natural speech',
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Models are downloaded once and run entirely on your device. '
              'No internet needed for rehearsal.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 24),
            _modelCard(
              context,
              title: Platform.isAndroid
                  ? 'Kokoro TTS + Live Matching'
                  : 'Kokoro TTS',
              subtitle: Platform.isAndroid
                  ? 'Neural speech and live line recognition'
                  : 'Neural text-to-speech (28 voices)',
              size: _totalDownloadSize,
              ready: _allReady,
              icon: Icons.record_voice_over,
            ),
            const SizedBox(height: 24),
            if (_downloading) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Downloading models...',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 12),
                      for (final entry in _modelProgress.entries) ...[
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: Text(
                                entry.key,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                            Expanded(
                              flex: 3,
                              child: LinearProgressIndicator(
                                value: entry.value,
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 36,
                              child: Text(
                                '${(entry.value * 100).toInt()}%',
                                style: theme.textTheme.labelSmall,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],
                    ],
                  ),
                ),
              ),
            ] else if (_error != null) ...[
              Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Text(
                        'Model operation failed',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(_error!, style: theme.textTheme.bodySmall),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _downloadAll,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            ] else if (!allReady) ...[
              FilledButton.icon(
                onPressed: _downloadAll,
                icon: const Icon(Icons.download),
                label: const Text('Download All Models'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Total download: $_totalDownloadSize. Wi-Fi recommended.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ] else ...[
              Card(
                color: theme.colorScheme.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(
                        Icons.check_circle,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'All models ready. Rehearsal uses on-device AI.',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('Clear Models'),
                      content: const Text(
                        'Delete all downloaded models? You will need to re-download them.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(c, false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(c, true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (confirm != true) return;
                  try {
                    await TtsService.instance.unloadKokoro();
                    if (_usesIosMlx) {
                      await _downloadService.deleteKokoro();
                    } else {
                      await _manager.clearCache();
                    }
                    await _checkStatus();
                  } catch (error, stack) {
                    DebugLogService.instance.logError(
                      LogCategory.ai,
                      'Could not clear downloaded models',
                      error,
                      stack,
                    );
                    if (mounted) {
                      setState(() {
                        _error = 'Could not clear downloaded models: $error';
                      });
                      ScaffoldMessenger.of(context).showAutoToast(
                        SnackBar(
                          content: Text(
                            'Could not clear downloaded models: $error',
                          ),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  }
                },
                child: const Text('Clear Downloaded Models'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _modelCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required String size,
    required bool ready,
    required IconData icon,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: ready ? Colors.green : Colors.grey),
        title: Text(title),
        subtitle: Text('$subtitle ($size)'),
        trailing: ready
            ? const Icon(Icons.check_circle, color: Colors.green)
            : const Icon(Icons.cloud_download_outlined, color: Colors.grey),
      ),
    );
  }
}
