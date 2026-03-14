import 'package:flutter/material.dart';

import '../../data/services/model_download_service.dart';

/// Screen for managing on-device AI model downloads.
///
/// Downloads run on the main isolate using async I/O to avoid the
/// "Illegal argument in isolate message: object is unsendable" crash
/// that occurs when passing dart:async objects across isolate boundaries.
class AiModelsScreen extends StatefulWidget {
  const AiModelsScreen({super.key});

  @override
  State<AiModelsScreen> createState() => _AiModelsScreenState();
}

class _AiModelsScreenState extends State<AiModelsScreen> {
  final _service = ModelDownloadService.instance;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onStateChanged);
    _service.refreshDownloadedStatus();
  }

  @override
  void dispose() {
    _service.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI Models')),
      body: ListView(
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
          ...ModelDownloadService.availableModels
              .map((model) => _buildModelTile(context, model)),
        ],
      ),
    );
  }

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
      BuildContext context, AiModel model, ModelDownloadState state) {
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
            const PopupMenuItem(
              value: 'delete',
              child: Text('Delete'),
            ),
          ],
        );
    }
  }

  IconData _iconForModel(String modelId) {
    return switch (modelId) {
      'vad' => Icons.hearing,
      'kokoro_tts' => Icons.record_voice_over,
      'whisper_stt' => Icons.mic,
      _ => Icons.smart_toy,
    };
  }

  Future<void> _download(AiModel model) async {
    await _service.download(model);
    if (!mounted) return;
    final state = _service.getState(model.id);
    if (state.status == ModelStatus.error) {
      ScaffoldMessenger.of(context).showSnackBar(
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${model.name} deleted')),
    );
  }
}
