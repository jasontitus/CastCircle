import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/responsive.dart';
import '../../data/services/analytics_service.dart';
import '../../data/services/debug_log_service.dart';
import '../../data/services/model_download_service.dart';
import '../../data/services/model_manager.dart';
import '../../data/services/tts_service.dart';
import '../../core/toast.dart';

/// Screen for managing on-device AI model downloads.
class AiModelsScreen extends StatefulWidget {
  const AiModelsScreen({super.key});

  @override
  State<AiModelsScreen> createState() => _AiModelsScreenState();
}

class _AiModelsScreenState extends State<AiModelsScreen> {
  final _tts = TtsService.instance;
  final _service = ModelDownloadService.instance;

  // Android ONNX download state
  bool _onnxDownloading = false;
  bool _onnxReady = false;
  bool _onnxInstalled = false;
  double _onnxProgress = 0;
  String _onnxStatus = '';
  String? _onnxError;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid || Platform.isIOS) {
      _service.addListener(_onStateChanged);
      _service.refreshDownloadedStatus();
    }
    _tts.kokoroLoadedListenable.addListener(_onTtsStateChanged);
    if (Platform.isAndroid) _checkOnnxStatus();
  }

  @override
  void dispose() {
    _tts.kokoroLoadedListenable.removeListener(_onTtsStateChanged);
    if (Platform.isAndroid || Platform.isIOS) {
      _service.removeListener(_onStateChanged);
    }
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  void _onTtsStateChanged() {
    if (!mounted || !Platform.isAndroid) return;
    final loaded = _tts.kokoroLoadedListenable.value;
    setState(() {
      _onnxReady = loaded;
      if (loaded) _onnxInstalled = true;
    });
  }

  Future<void> _checkOnnxStatus() async {
    try {
      final installed = await ModelManager.instance.isKokoroReady();
      if (mounted) {
        setState(() {
          _onnxInstalled = installed;
          _onnxReady = installed && _tts.kokoroLoadedListenable.value;
        });
      }
    } catch (error, stack) {
      _reportActionError('Could not check Kokoro model status', error, stack);
    }
  }

  Future<void> _downloadOnnxKokoro() async {
    setState(() {
      _onnxDownloading = true;
      _onnxProgress = 0;
      _onnxStatus = 'Starting download...';
      _onnxError = null;
    });

    try {
      await ModelManager.instance.downloadKokoro(
        onProgress: (file, progress) {
          if (mounted) {
            setState(() {
              _onnxProgress = progress;
              if (progress < 0.8) {
                _onnxStatus = 'Downloading... ${(progress * 100).toInt()}%';
              } else if (progress < 1.0) {
                _onnxStatus = 'Extracting model files...';
              } else {
                _onnxStatus = 'Complete';
              }
            });
          }
        },
      );
    } catch (error, stack) {
      DebugLogService.instance.logError(
        LogCategory.ai,
        'Kokoro model download failed',
        error,
        stack,
      );
      if (mounted) {
        setState(() {
          _onnxDownloading = false;
          _onnxError = 'Download failed: $error';
        });
        ScaffoldMessenger.of(context).showAutoToast(
          SnackBar(
            content: Text('Download failed: $error'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    AnalyticsService.instance.logModelDownloaded(modelId: 'kokoro_onnx');
    if (mounted) setState(() => _onnxInstalled = true);

    try {
      final loaded = await _tts.tryLoadKokoro();
      if (!loaded) {
        throw StateError('No Kokoro engine could be loaded');
      }
      if (mounted) {
        setState(() {
          _onnxReady = true;
          _onnxError = null;
        });
        ScaffoldMessenger.of(context).showAutoToast(
          const SnackBar(content: Text('Kokoro AI voices ready!')),
        );
      }
    } catch (error, stack) {
      DebugLogService.instance.logError(
        LogCategory.ai,
        'Kokoro model load failed after download',
        error,
        stack,
      );
      if (mounted) {
        setState(() {
          _onnxReady = false;
          _onnxError =
              'Model downloaded, but the voice engine could not load: '
              '$error';
        });
        ScaffoldMessenger.of(context).showAutoToast(
          SnackBar(
            content: Text('Model downloaded, but loading failed: $error'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _onnxDownloading = false);
    }
  }

  Future<void> _deleteOnnxKokoro() async {
    try {
      await _tts.unloadKokoro();
      await ModelManager.instance.deleteKokoro();
      // TTS will fall back to system on next init.
      if (mounted) {
        setState(() {
          _onnxInstalled = false;
          _onnxReady = false;
          _onnxError = null;
        });
        ScaffoldMessenger.of(
          context,
        ).showAutoToast(const SnackBar(content: Text('Kokoro model deleted')));
      }
    } catch (error, stack) {
      _reportActionError('Could not delete the Kokoro model', error, stack);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI Models')),
      body: ContentConstraint(
        maxWidth: 700,
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                Platform.isAndroid || Platform.isIOS
                    ? 'Download on-device AI models for offline use. '
                          'Models are stored locally and can be deleted at any time.'
                    : 'This platform uses built-in system text-to-speech. '
                          'No AI voice model download is available or required.',
                style: TextStyle(color: Colors.grey[500], fontSize: 13),
              ),
            ),
            const Divider(),

            // Platform-specific model tiles
            if (Platform.isAndroid) ...[
              _buildOnnxKokoroTile(context),
              _buildLiveAsrTile(context),
            ] else if (Platform.isIOS)
              // live_asr powers Android live matching only (iOS uses the OS
              // recognizer), so iOS offers only its MLX Kokoro files.
              ...ModelDownloadService.availableModels
                  .where((m) => m.subdir == 'kokoro_mlx')
                  .map((model) => _buildModelTile(context, model))
            else
              const ListTile(
                leading: Icon(Icons.record_voice_over),
                title: Text('System voices'),
                subtitle: Text(
                  'Provided by the operating system — no download required',
                ),
                trailing: Icon(Icons.check_circle, color: Colors.green),
              ),

            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                'Diagnostics',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.bug_report),
              title: const Text('Kokoro TTS Debug'),
              subtitle: const Text('Test TTS engine and view diagnostics'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/kokoro-debug'),
            ),
          ],
        ),
      ),
    );
  }

  /// Android: Kokoro ONNX model tile (single archive download)
  Widget _buildOnnxKokoroTile(BuildContext context) {
    return ListTile(
      leading: Icon(
        Icons.record_voice_over,
        color: _onnxReady
            ? Colors.green
            : _onnxInstalled
            ? Colors.orange
            : Theme.of(context).colorScheme.primary,
      ),
      title: const Text('Kokoro AI Voices'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _onnxReady
                ? 'Loaded — 28 high-quality English voices'
                : _onnxInstalled
                ? 'Installed — voice engine not loaded'
                : 'On-device neural TTS (~180 MB download)',
          ),
          if (_onnxDownloading)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: _onnxProgress),
                  const SizedBox(height: 4),
                  Text(_onnxStatus, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          if (_onnxError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _onnxError!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ),
        ],
      ),
      trailing: _onnxDownloading
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : _onnxInstalled
          ? PopupMenuButton<String>(
              icon: Icon(
                Icons.check_circle,
                color: _onnxReady ? Colors.green : Colors.orange,
              ),
              onSelected: (value) async {
                if (value == 'delete') await _deleteOnnxKokoro();
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            )
          : IconButton(
              icon: const Icon(Icons.download),
              tooltip: 'Download',
              onPressed: _downloadOnnxKokoro,
            ),
    );
  }

  /// Android: one tile for the live line-matching ASR model group (encoder +
  /// decoder + joiner + tokens). Grouped because the pieces are useless
  /// individually — a single Download fetches all four, progress is weighted
  /// by size, and Delete removes them together.
  Widget _buildLiveAsrTile(BuildContext context) {
    final models = ModelDownloadService.availableModels
        .where((m) => m.subdir == 'live_asr')
        .toList();
    final states = {for (final m in models) m: _service.getState(m.id)};
    final allDone = states.values.every(
      (s) => s.status == ModelStatus.downloaded,
    );
    final downloading = states.values.any(
      (s) => s.status == ModelStatus.downloading,
    );
    final error = states.values
        .map((s) => s.errorMessage)
        .whereType<String>()
        .firstOrNull;
    // This tile fronts FOUR files, so "one failed while three carry on" is a
    // real state — and it used to render as a spinner next to a red error
    // with nothing saying the group could no longer succeed.
    final ready = states.values
        .where((s) => s.status == ModelStatus.downloaded)
        .length;
    final failed = states.values
        .where((s) => s.status == ModelStatus.error)
        .length;
    final totalBytes = models.fold<int>(0, (a, m) => a + m.sizeBytes);
    var progress = 0.0;
    states.forEach((m, s) {
      final part = s.status == ModelStatus.downloaded ? 1.0 : s.progress;
      progress += part * m.sizeBytes / totalBytes;
    });

    return ListTile(
      leading: Icon(
        Icons.graphic_eq,
        color: allDone ? Colors.green : Theme.of(context).colorScheme.primary,
      ),
      title: const Text('Live Line Matching'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            allDone
                ? 'Installed — rehearsal follows your lines as you speak. '
                      'Speech model: Kroko-ASR community (CC BY-SA).'
                : 'On-device speech recognition so rehearsal follows your '
                      'lines as you speak (~68 MB download). '
                      'Speech model: Kroko-ASR community (CC BY-SA).',
          ),
          if (downloading)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(value: progress),
            ),
          if (downloading || failed > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '$ready of ${models.length} files installed'
                '${failed > 0 ? ' · $failed failed' : ''}',
                style: TextStyle(
                  fontSize: 12,
                  color: failed > 0
                      ? Colors.orange
                      : Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                downloading
                    // Saying only "download again" while a spinner is still
                    // turning reads as "it's handling it". It isn't.
                    ? '$error (the other files are still downloading — '
                          'tap download again when they finish)'
                    : error,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ),
        ],
      ),
      trailing: downloading
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : allDone
          ? PopupMenuButton<String>(
              icon: const Icon(Icons.check_circle, color: Colors.green),
              onSelected: (value) async {
                if (value == 'delete') await _deleteLiveAsr(models);
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            )
          : IconButton(
              icon: const Icon(Icons.download),
              tooltip: 'Download',
              onPressed: _downloadLiveAsr,
            ),
    );
  }

  /// iOS: Individual MLX model tiles
  Widget _buildModelTile(BuildContext context, AiModel model) {
    final state = _service.getState(model.id);
    return ListTile(
      leading: Icon(
        _iconForModel(model.id),
        color: state.status == ModelStatus.downloaded
            ? Colors.green
            : Theme.of(context).colorScheme.primary,
      ),
      title: Text(model.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(model.description),
          if (state.status == ModelStatus.downloading)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(value: state.progress),
            ),
          if (state.status == ModelStatus.error && state.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                state.errorMessage!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ),
        ],
      ),
      trailing: _buildTrailing(context, model, state),
    );
  }

  Widget _buildTrailing(
    BuildContext context,
    AiModel model,
    ModelDownloadState state,
  ) {
    switch (state.status) {
      case ModelStatus.notDownloaded:
      case ModelStatus.error:
        return IconButton(
          icon: const Icon(Icons.download),
          tooltip: 'Download',
          onPressed: () => _download(model),
        );
      case ModelStatus.downloading:
        return const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case ModelStatus.downloaded:
        return PopupMenuButton<String>(
          icon: const Icon(Icons.check_circle, color: Colors.green),
          onSelected: (value) async {
            if (value == 'delete') await _delete(model);
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        );
    }
  }

  IconData _iconForModel(String modelId) {
    return switch (modelId) {
      'kokoro_model' => Icons.record_voice_over,
      'kokoro_voices' => Icons.people,
      _ => Icons.smart_toy,
    };
  }

  Future<void> _download(AiModel model) async {
    try {
      await _service.download(model);
      if (!mounted) return;
      final state = _service.getState(model.id);
      if (state.status == ModelStatus.error) {
        _showErrorToast('Download failed: ${state.errorMessage}');
      }
    } catch (error, stack) {
      _reportActionError('Could not download ${model.name}', error, stack);
    }
  }

  Future<void> _delete(AiModel model) async {
    try {
      if (model.subdir == 'kokoro_mlx') {
        await _tts.unloadKokoro();
      }
      await _service.delete(model.id);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showAutoToast(SnackBar(content: Text('${model.name} deleted')));
    } catch (error, stack) {
      _reportActionError('Could not delete ${model.name}', error, stack);
    }
  }

  Future<void> _downloadLiveAsr() async {
    try {
      await _service.downloadLiveAsr();
    } catch (error, stack) {
      _reportActionError(
        'Could not download live line-matching models',
        error,
        stack,
      );
    }
  }

  Future<void> _deleteLiveAsr(List<AiModel> models) async {
    var deleted = 0;
    try {
      for (final model in models) {
        await _service.delete(model.id);
        deleted++;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showAutoToast(
          const SnackBar(content: Text('Live line-matching models deleted')),
        );
      }
    } catch (error, stack) {
      _reportActionError(
        'Deleted $deleted of ${models.length} live line-matching files; '
        'the remaining files could not be deleted',
        error,
        stack,
      );
    }
  }

  void _reportActionError(String action, Object error, [StackTrace? stack]) {
    DebugLogService.instance.logError(LogCategory.ai, action, error, stack);
    _showErrorToast('$action: $error');
  }

  void _showErrorToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showAutoToast(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }
}
