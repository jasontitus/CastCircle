import 'package:flutter/material.dart';

import '../../data/services/stt_service.dart';

class ParakeetDebugScreen extends StatefulWidget {
  const ParakeetDebugScreen({super.key});

  @override
  State<ParakeetDebugScreen> createState() => _ParakeetDebugScreenState();
}

class _ParakeetDebugScreenState extends State<ParakeetDebugScreen> {
  final _stt = SttService.instance;
  final _expectedController = TextEditingController(
    text: 'To be or not to be, that is the question.',
  );
  final _spokenController = TextEditingController();

  bool _loading = true;
  bool _recording = false;
  String _recognizedText = '';
  double? _testMatchScore;
  String _statusLog = '';

  @override
  void initState() {
    super.initState();
    _loadInfo();
  }

  @override
  void dispose() {
    _expectedController.dispose();
    _spokenController.dispose();
    _stt.stop();
    super.dispose();
  }

  Future<void> _loadInfo() async {
    setState(() => _loading = true);
    // Just trigger a state refresh
    setState(() => _loading = false);
  }

  void _log(String msg) {
    setState(() {
      _statusLog =
          '${DateTime.now().toString().substring(11, 19)} $msg\n$_statusLog';
    });
  }

  Future<void> _initStt() async {
    _log('Calling SttService.init()...');
    final result = await _stt.init();
    _log(
        'init() complete. Engine: ${_stt.activeEngine.name}, result: $result');
    setState(() {});
  }

  Future<void> _startRecording() async {
    setState(() {
      _recording = true;
      _recognizedText = '';
    });
    _log('Recording started (engine: ${_stt.activeEngine.name})...');

    await _stt.listen(
      onResult: (recognized) {
        if (!mounted) return;
        setState(() => _recognizedText = recognized);
        _log('Recognized: "$recognized"');
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _recording = false);
        _log('Recording stopped');
      },
      listenFor: const Duration(seconds: 15),
    );
  }

  Future<void> _stopRecording() async {
    await _stt.stop();
    setState(() => _recording = false);
    _log('Recording stopped manually');
  }

  void _computeMatchScore() {
    final expected = _expectedController.text.trim();
    final spoken = _spokenController.text.trim();
    if (expected.isEmpty || spoken.isEmpty) return;

    final score = SttService.matchScore(expected, spoken);
    setState(() => _testMatchScore = score);
    _log('Match score: ${(score * 100).toInt()}% '
        '(expected: "${expected.substring(0, expected.length.clamp(0, 30))}...")');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Parakeet STT Debug'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadInfo,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Engine status
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Engine Status',
                            style: theme.textTheme.titleSmall),
                        const SizedBox(height: 8),
                        _statusRow('Active Engine', _stt.activeEngine.name,
                            _stt.activeEngine == SttEngine.mlx
                                ? Colors.green
                                : Colors.orange),
                        _statusRow('MLX Parakeet', _stt.isMlxReady.toString(),
                            _stt.isMlxReady ? Colors.green : Colors.red),
                        _statusRow(
                            'Available',
                            _stt.isAvailable.toString(),
                            _stt.isAvailable ? Colors.green : Colors.red),
                        _statusRow('Is Listening', _stt.isListening.toString(),
                            _stt.isListening ? Colors.orange : null),
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
                        onPressed: _initStt,
                        child: const Text('Init STT'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          _log('Reloading MLX...');
                          final ok = await _stt.reloadMlx();
                          _log('Reload result: $ok, engine: ${_stt.activeEngine.name}');
                          setState(() {});
                        },
                        child: const Text('Reload MLX'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Test Microphone
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Test Microphone',
                            style: theme.textTheme.titleSmall),
                        const SizedBox(height: 8),
                        if (_recognizedText.isNotEmpty)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: Colors.grey[900],
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              _recognizedText,
                              style: const TextStyle(
                                  fontSize: 16, color: Colors.white),
                            ),
                          ),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed:
                                    _recording ? null : _startRecording,
                                icon: const Icon(Icons.mic),
                                label: const Text('Record'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton(
                              onPressed:
                                  _recording ? _stopRecording : null,
                              child: const Text('Stop'),
                            ),
                          ],
                        ),
                        if (_recording)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: LinearProgressIndicator(),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Match Score Tester
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Match Score Tester',
                            style: theme.textTheme.titleSmall),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _expectedController,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: 'Expected text',
                            isDense: true,
                          ),
                          maxLines: 2,
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _spokenController,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: 'Spoken text',
                            isDense: true,
                          ),
                          maxLines: 2,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            FilledButton(
                              onPressed: _computeMatchScore,
                              child: const Text('Compute'),
                            ),
                            const SizedBox(width: 12),
                            if (_testMatchScore != null)
                              Text(
                                '${(_testMatchScore! * 100).toInt()}%',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: _testMatchScore! >= 0.7
                                      ? Colors.green
                                      : Colors.orange,
                                ),
                              ),
                          ],
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

  Widget _statusRow(String label, String value, Color? valueColor) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.grey),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: valueColor),
            ),
          ),
        ],
      ),
    );
  }
}
