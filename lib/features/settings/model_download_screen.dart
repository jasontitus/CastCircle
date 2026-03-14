import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/model_manager.dart';
import '../../data/services/tts_service.dart';
import '../../data/services/stt_service.dart';

class ModelDownloadScreen extends ConsumerStatefulWidget {
  const ModelDownloadScreen({super.key});

  @override
  ConsumerState<ModelDownloadScreen> createState() =>
      _ModelDownloadScreenState();
}

class _ModelDownloadScreenState extends ConsumerState<ModelDownloadScreen> {
  final _manager = ModelManager.instance;

  bool _downloading = false;
  String _currentModel = '';
  String _currentFile = '';
  double _progress = 0;
  String? _error;

  bool _kokoroReady = false;
  bool _whisperReady = false;
  bool _vadReady = false;

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  Future<void> _checkStatus() async {
    final results = await Future.wait([
      _manager.isKokoroReady(),
      _manager.isWhisperReady(),
      _manager.isVadReady(),
    ]);
    if (mounted) {
      setState(() {
        _kokoroReady = results[0];
        _whisperReady = results[1];
        _vadReady = results[2];
      });
    }
  }

  Future<void> _downloadAll() async {
    setState(() {
      _downloading = true;
      _error = null;
    });

    try {
      await _manager.downloadAll(
        onProgress: (model, file, progress) {
          if (mounted) {
            setState(() {
              _currentModel = model;
              _currentFile = file;
              _progress = progress;
            });
          }
        },
      );

      // Reload services with new models
      await TtsService.instance.reloadKokoro();
      await SttService.instance.reloadWhisper();

      await _checkStatus();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _downloading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allReady = _kokoroReady && _whisperReady && _vadReady;

    return Scaffold(
      appBar: AppBar(title: const Text('AI Models')),
      body: ListView(
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
            title: 'Kokoro TTS',
            subtitle: 'Neural text-to-speech (54 voices)',
            size: '~92 MB',
            ready: _kokoroReady,
            icon: Icons.record_voice_over,
          ),
          _modelCard(
            context,
            title: 'Whisper STT',
            subtitle: 'Speech recognition for line matching',
            size: '~244 MB',
            ready: _whisperReady,
            icon: Icons.hearing,
          ),
          _modelCard(
            context,
            title: 'Voice Activity Detection',
            subtitle: 'Detects when you start/stop speaking',
            size: '~2 MB',
            ready: _vadReady,
            icon: Icons.mic,
          ),
          const SizedBox(height: 24),
          if (_downloading) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Downloading $_currentModel',
                        style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(_currentFile, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: _progress),
                    const SizedBox(height: 4),
                    Text('${(_progress * 100).toInt()}%',
                        style: theme.textTheme.labelSmall),
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
                    Text('Download failed', style: theme.textTheme.titleSmall),
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
              'Total download: ~340 MB. Requires Wi-Fi recommended.',
              textAlign: TextAlign.center,
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
                    Icon(Icons.check_circle,
                        color: theme.colorScheme.primary),
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
                        'Delete all downloaded models? You will need to re-download them.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(c, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(c, true),
                          child: const Text('Delete')),
                    ],
                  ),
                );
                if (confirm == true) {
                  await _manager.clearCache();
                  await _checkStatus();
                }
              },
              child: const Text('Clear Downloaded Models'),
            ),
          ],
        ],
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
    final theme = Theme.of(context);
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
