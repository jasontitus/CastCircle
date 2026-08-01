import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/responsive.dart';
import '../../data/services/analytics_service.dart';
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
  final _service = ModelDownloadService.instance;

  // Android ONNX download state
  bool _onnxDownloading = false;
  bool _onnxReady = false;
  double _onnxProgress = 0;
  String _onnxStatus = '';
  String? _onnxError;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onStateChanged);
    _service.refreshDownloadedStatus();
    if (Platform.isAndroid) _checkOnnxStatus();
  }

  @override
  void dispose() {
    _service.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _checkOnnxStatus() async {
    final ready = await ModelManager.instance.isKokoroReady();
    if (mounted) setState(() => _onnxReady = ready);
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

      // Try to initialize TTS after download
      await TtsService.instance.tryLoadKokoro();
      AnalyticsService.instance.logModelDownloaded(modelId: 'kokoro_onnx');

      if (mounted) {
        setState(() {
          _onnxDownloading = false;
          _onnxReady = true;
        });
        ScaffoldMessenger.of(context).showAutoToast(
          const SnackBar(content: Text('Kokoro AI voices ready!')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _onnxDownloading = false;
          _onnxError = e.toString();
        });
        ScaffoldMessenger.of(context).showAutoToast(
          SnackBar(
            content: Text('Download failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteOnnxKokoro() async {
    await ModelManager.instance.clearCache();
    // TTS will fall back to system on next init
    if (mounted) {
      setState(() => _onnxReady = false);
      ScaffoldMessenger.of(
        context,
      ).showAutoToast(const SnackBar(content: Text('Kokoro model deleted')));
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
                'Download on-device AI models for offline use. '
                'Models are stored locally and can be deleted at any time.',
                style: TextStyle(color: Colors.grey[500], fontSize: 13),
              ),
            ),
            const Divider(),

            // Platform-specific model tiles
            if (Platform.isAndroid) ...[
              _buildOnnxKokoroTile(context),
              _buildLiveAsrTile(context),
            ] else
              // live_asr powers Android live matching only (Apple platforms
              // use the OS recognizer) — don't offer a dead download.
              ...ModelDownloadService.availableModels
                  .where((m) => m.subdir != 'live_asr')
                  .map((model) => _buildModelTile(context, model)),

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
            : Theme.of(context).colorScheme.primary,
      ),
      title: const Text('Kokoro AI Voices'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _onnxReady
                ? 'Installed — 28 high-quality English voices'
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
          : _onnxReady
          ? PopupMenuButton<String>(
              icon: const Icon(Icons.check_circle, color: Colors.green),
              onSelected: (value) {
                if (value == 'delete') _deleteOnnxKokoro();
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
    final allDone =
        states.values.every((s) => s.status == ModelStatus.downloaded);
    final downloading =
        states.values.any((s) => s.status == ModelStatus.downloading);
    final error = states.values
        .map((s) => s.errorMessage)
        .whereType<String>()
        .firstOrNull;
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
          Text(allDone
              ? 'Installed — rehearsal follows your lines as you speak. '
                  'Speech model: Kroko-ASR community (CC BY-SA).'
              : 'On-device speech recognition so rehearsal follows your '
                  'lines as you speak (~68 MB download). '
                  'Speech model: Kroko-ASR community (CC BY-SA).'),
          if (downloading)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(value: progress),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                error,
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
                    if (value == 'delete') {
                      for (final m in models) {
                        await _service.delete(m.id);
                      }
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                )
              : IconButton(
                  icon: const Icon(Icons.download),
                  tooltip: 'Download',
                  onPressed: () => _service.downloadLiveAsr(),
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
          onSelected: (value) {
            if (value == 'delete') _delete(model);
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
    await _service.download(model);
    if (!mounted) return;
    final state = _service.getState(model.id);
    if (state.status == ModelStatus.error) {
      ScaffoldMessenger.of(context).showAutoToast(
        SnackBar(
          content: Text('Download failed: ${state.errorMessage}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _delete(AiModel model) async {
    await _service.delete(model.id);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showAutoToast(SnackBar(content: Text('${model.name} deleted')));
  }
}
