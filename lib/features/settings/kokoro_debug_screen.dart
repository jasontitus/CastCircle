import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../data/services/tts_service.dart';
import '../../data/services/model_manager.dart';

class KokoroDebugScreen extends StatefulWidget {
  const KokoroDebugScreen({super.key});

  @override
  State<KokoroDebugScreen> createState() => _KokoroDebugScreenState();
}

class _KokoroDebugScreenState extends State<KokoroDebugScreen> {
  final _tts = TtsService.instance;
  final _textController = TextEditingController(
    text: 'Hello! This is a test of the Kokoro neural text to speech engine.',
  );
  String _selectedVoice = TtsService.kokoroVoices.first;

  Map<String, String> _debugInfo = {};
  List<String> _modelFiles = [];
  bool _loading = true;
  bool _speaking = false;
  bool _initializing = false;
  String _statusLog = '';
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    _loadDebugInfo();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _loadDebugInfo() async {
    if (!mounted) return;
    setState(() => _loading = true);

    // Get TTS debug info. Keep the diagnostics screen usable even if the
    // service itself cannot provide diagnostics on this platform.
    Map<String, String> info;
    try {
      info = await _tts.getDebugInfo();
    } catch (error) {
      info = {'Error': error.toString()};
      _log('getDebugInfo() ERROR: $error');
    }

    // List model files on disk
    final files = <String>[];
    try {
      final kokoroPath = Platform.isAndroid
          ? await ModelManager.instance.kokoroModelDir
          : p.join(await ModelManager.instance.modelsDir, 'kokoro_mlx');
      final kokoroDir = Directory(kokoroPath);
      if (await kokoroDir.exists()) {
        await for (final entity in kokoroDir.list(recursive: false)) {
          final name = p.basename(entity.path);
          if (entity is File) {
            final size = await entity.length();
            final sizeStr = size > 1024 * 1024
                ? '${(size / 1024 / 1024).toStringAsFixed(1)} MB'
                : '${(size / 1024).toStringAsFixed(1)} KB';
            files.add('$name ($sizeStr)');
          } else if (entity is Directory) {
            files.add('$name/ (dir)');
          }
        }
        files.sort();
      } else {
        files.add('Directory does not exist: ${kokoroDir.path}');
      }
    } catch (e) {
      files.add('Error listing files: $e');
    }

    if (mounted) {
      setState(() {
        _debugInfo = info;
        _modelFiles = files;
        _loading = false;
      });
    }
  }

  void _log(String msg) {
    // Called after awaits from _speak/_stop/_tryInit — a no-op once the
    // screen is gone beats setState-after-dispose.
    if (!mounted) return;
    setState(() {
      _statusLog =
          '${DateTime.now().toString().substring(11, 19)} $msg\n$_statusLog';
    });
  }

  Future<void> _tryInit() async {
    if (_initializing) return;
    setState(() => _initializing = true);
    _log('Calling TtsService.init()...');
    try {
      await _tts.init();
      _log(
        'init() complete. Engine: ${_tts.activeEngine.name}, '
        'Kokoro ready: ${_tts.isKokoroLoaded}',
      );
      await _loadDebugInfo();
    } catch (error) {
      _log('init() ERROR: $error');
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
  }

  Future<void> _tryReload() async {
    if (_initializing) return;
    setState(() => _initializing = true);
    _log('Calling tryLoadKokoro()...');
    try {
      final success = await _tts.tryLoadKokoro();
      _log('tryLoadKokoro() → $success. Engine: ${_tts.activeEngine.name}');
      await _loadDebugInfo();
    } catch (error) {
      _log('tryLoadKokoro() ERROR: $error');
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
  }

  Future<void> _speak() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    const debugCharacter = '__kokoro_debug__';
    final voice = _selectedVoice;
    final speaker = TtsService.kokoroVoices.indexOf(voice);
    _tts.assignVoice(debugCharacter, speaker, voiceId: voice);

    setState(() => _speaking = true);
    _log('Speaking with voice $voice, speed $_speed...');
    _log('Text: "${text.substring(0, text.length.clamp(0, 60))}..."');

    try {
      await _tts.setRate(_speed * 0.5);
      await _tts.speak(text, character: debugCharacter);
      _log('speak() complete (engine: ${_tts.activeEngine.name})');
    } catch (e) {
      _log('speak() ERROR: $e');
    } finally {
      if (mounted) setState(() => _speaking = false);
    }
  }

  Future<void> _stop() async {
    await _tts.stop();
    _log('Stopped');
    if (mounted) setState(() => _speaking = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Kokoro Debug'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadDebugInfo,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Status section
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Engine Status',
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        for (final entry in _debugInfo.entries)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 140,
                                  child: Text(
                                    entry.key,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: Colors.grey,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    entry.value,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color:
                                          entry.value == 'true' ||
                                              entry.value == 'kokoro'
                                          ? Colors.green
                                          : entry.value == 'false' ||
                                                entry.value.contains(
                                                  'not found',
                                                )
                                          ? Colors.red
                                          : null,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                // Actions
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _initializing ? null : _tryInit,
                        child: const Text('Init TTS'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _initializing ? null : _tryReload,
                        child: const Text('Reload Kokoro'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Speak controls
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Speak', style: theme.textTheme.titleSmall),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _textController,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            hintText: 'Text to speak...',
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            SizedBox(
                              width: 160,
                              child: DropdownButtonFormField<String>(
                                value: _selectedVoice,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  labelText: 'Voice',
                                  isDense: true,
                                ),
                                items: [
                                  for (final voice in TtsService.kokoroVoices)
                                    DropdownMenuItem(
                                      value: voice,
                                      child: Text(
                                        voice,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                                onChanged: _speaking
                                    ? null
                                    : (voice) {
                                        if (voice != null) {
                                          setState(
                                            () => _selectedVoice = voice,
                                          );
                                        }
                                      },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Speed: ${_speed.toStringAsFixed(1)}x',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                  Slider(
                                    value: _speed,
                                    min: 0.5,
                                    max: 2.0,
                                    divisions: 6,
                                    onChanged: (v) =>
                                        setState(() => _speed = v),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _speaking ? null : _speak,
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('Speak'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton(
                              onPressed: _stop,
                              child: const Text('Stop'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Model files
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Model Files on Disk',
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        if (_modelFiles.isEmpty)
                          const Text(
                            'No files found',
                            style: TextStyle(color: Colors.red),
                          )
                        else
                          for (final f in _modelFiles)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Text(f, style: theme.textTheme.bodySmall),
                            ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Log
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Log', style: theme.textTheme.titleSmall),
                        const SizedBox(height: 8),
                        Container(
                          height: 200,
                          width: double.infinity,
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: SingleChildScrollView(
                            child: Text(
                              _statusLog.isEmpty
                                  ? 'No actions yet'
                                  : _statusLog,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                color: Colors.greenAccent,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
