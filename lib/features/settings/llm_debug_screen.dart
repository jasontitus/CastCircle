import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/services/ai_script_structuring_service.dart';
import '../../data/services/model_download_service.dart';
import '../../data/services/on_device_llm_channel.dart';

/// Diagnostics + tester for the on-device script-AI runtime (Gemma via MLX,
/// or Apple Foundation Models). Mirrors the Kokoro/Parakeet debug screens.
class LlmDebugScreen extends StatefulWidget {
  const LlmDebugScreen({super.key});

  @override
  State<LlmDebugScreen> createState() => _LlmDebugScreenState();
}

class _LlmDebugScreenState extends State<LlmDebugScreen> {
  final _channel = OnDeviceLlmChannel.instance;
  final _download = ModelDownloadService.instance;
  final _promptController = TextEditingController(
    text: 'Reply with exactly: {"ok": true}',
  );

  bool _busy = false;
  String _status = 'Not initialized';
  final List<String> _modelFiles = [];
  String _output = '';
  String _elapsed = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    final dir = await _download.getGemmaModelDir();

    // List the model files on disk.
    _modelFiles.clear();
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final gemmaDir = Directory(p.join(appDir.path, 'models', 'gemma_llm'));
      if (gemmaDir.existsSync()) {
        for (final e in gemmaDir.listSync()) {
          if (e is File) {
            final b = e.lengthSync();
            final size = b == 0
                ? '⚠️ 0 bytes — EMPTY'
                : b < 1024
                    ? '$b B'
                    : b < 1024 * 1024
                        ? '${(b / 1024).toStringAsFixed(1)} KB'
                        : '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
            _modelFiles.add('${p.basename(e.path)} ($size)');
          }
        }
        _modelFiles.sort();
      } else {
        _modelFiles.add('no gemma_llm directory');
      }
    } catch (e) {
      _modelFiles.add('error: $e');
    }

    // Initialize the runtime (cheap — Gemma loads on first generate).
    final ready = await _channel.initialize(dir ?? '');
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = ready
          ? 'READY — runtime=${_channel.lastRuntime}'
          : 'NOT READY — runtime=${_channel.lastRuntime}';
    });
  }

  Future<void> _runPrompt() async {
    setState(() {
      _busy = true;
      _output = '';
      _elapsed = '';
    });
    final sw = Stopwatch()..start();
    try {
      final out = await _channel.generate(prompt: _promptController.text);
      sw.stop();
      if (!mounted) return;
      setState(() {
        _output = out ?? '(null — see error below / debug log)';
        _elapsed = '${sw.elapsedMilliseconds} ms';
      });
    } catch (e) {
      sw.stop();
      if (mounted) {
        setState(() {
          _output = 'ERROR: $e';
          _elapsed = '${sw.elapsedMilliseconds} ms';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testStructuring() async {
    setState(() {
      _busy = true;
      _output = '';
      _elapsed = '';
    });
    const sample = '''
ACT I
MRS. BENNET. My dear Mr. Bennet, have you heard that Netherfield Park is let at last?
MR. BENNET. You want to tell me, and I have no objection to hearing it.
''';
    final sw = Stopwatch()..start();
    final svc = AiScriptStructuringService();
    final result = await svc.structure(rawText: sample, title: 'Sample');
    sw.stop();
    if (!mounted) return;
    final summary = result == null
        ? 'structure() returned null'
        : 'parsed: ${result.characters.length} characters, '
            '${result.lines.where((l) => l.lineType.name == "dialogue").length} lines'
            '${result.characters.isEmpty ? "" : " — ${result.characters.map((c) => c.name).join(", ")}"}';
    setState(() {
      _busy = false;
      _elapsed = '${sw.elapsedMilliseconds} ms';
      _output = '$summary\n\n--- raw model output ---\n'
          '${svc.lastRawOutput.isEmpty ? "(none)" : svc.lastRawOutput}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = _channel.isAvailable;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Script AI Debug'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _busy ? null : _refresh,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: ready
                ? Colors.green.withValues(alpha: 0.15)
                : theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(ready ? Icons.check_circle : Icons.error_outline,
                          color: ready ? Colors.green : theme.colorScheme.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_status,
                            style: theme.textTheme.titleSmall),
                      ),
                    ],
                  ),
                  if (_channel.lastError.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SelectableText('error: ${_channel.lastError}',
                        style: theme.textTheme.bodySmall),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Model files', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          for (final f in _modelFiles)
            Text('• $f', style: theme.textTheme.bodySmall),
          const SizedBox(height: 20),
          Text('Test prompt', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _promptController,
            maxLines: 4,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _runPrompt,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Run prompt'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _testStructuring,
                  child: const Text('Test structuring'),
                ),
              ),
            ],
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            Center(
              child: Column(
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  ValueListenableBuilder<String>(
                    valueListenable: _channel.progress,
                    builder: (_, msg, __) => Text(
                      msg.isEmpty ? 'working…' : msg,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_elapsed.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Output  ($_elapsed)', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _output.isEmpty ? '(empty)' : _output,
                style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
