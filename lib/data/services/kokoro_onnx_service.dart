import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'debug_log_service.dart';
import 'model_manager.dart';

/// Kokoro neural TTS for platforms without MLX (Android): sherpa-onnx
/// OfflineTts running the fp16 Kokoro pack (see ModelManager), hosted in a
/// background isolate because synthesis is ~real-time on a phone (RTF ≈ 0.9
/// at 4 threads on a Galaxy A35) and would freeze the UI for seconds per line.
///
/// Exposes the same contract as the iOS KokoroMLX channel — synthesize(text,
/// voice, speed) → WAV file path — so TtsService's playback, chunking, and
/// prefetch logic is shared untouched.
class KokoroOnnxService {
  KokoroOnnxService._();
  static final instance = KokoroOnnxService._();

  final _dlog = DebugLogService.instance;

  Isolate? _isolate;
  SendPort? _toIsolate;
  StreamSubscription? _sub;
  Future<bool>? _starting;
  final _pending = <int, Completer<String?>>{};
  var _nextId = 0;

  bool get isRunning => _toIsolate != null;

  /// Speaker IDs for kokoro-multi-lang-v1_0 (identical in v1_1, which appends
  /// new voices). Source: sherpa-onnx model docs. The English voices the app
  /// offers all live in 0-27.
  static const voiceIds = <String, int>{
    'af_alloy': 0, 'af_aoede': 1, 'af_bella': 2, 'af_heart': 3,
    'af_jessica': 4, 'af_kore': 5, 'af_nicole': 6, 'af_nova': 7,
    'af_river': 8, 'af_sarah': 9, 'af_sky': 10,
    'am_adam': 11, 'am_echo': 12, 'am_eric': 13, 'am_fenrir': 14,
    'am_liam': 15, 'am_michael': 16, 'am_onyx': 17, 'am_puck': 18,
    'am_santa': 19,
    'bf_alice': 20, 'bf_emma': 21, 'bf_isabella': 22, 'bf_lily': 23,
    'bm_daniel': 24, 'bm_fable': 25, 'bm_george': 26, 'bm_lewis': 27,
  };

  /// Spawn the synthesis isolate if the model is downloaded. Safe to call
  /// repeatedly; concurrent calls share one startup.
  Future<bool> ensureStarted() {
    if (_toIsolate != null) return Future.value(true);
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<bool> _start() async {
    final paths = await ModelManager.instance.getKokoroPaths();
    if (paths == null) {
      _dlog.log(LogCategory.tts, 'KokoroOnnx: model not downloaded');
      return false;
    }
    final tmpDir = (await getTemporaryDirectory()).path;

    final fromIsolate = ReceivePort();
    final ready = Completer<bool>();
    try {
      _isolate = await Isolate.spawn(_isolateMain, _IsolateArgs(
        sendPort: fromIsolate.sendPort,
        model: paths.model,
        voices: paths.voices,
        tokens: paths.tokens,
        dataDir: paths.dataDir,
        lexicon: paths.lexicon,
        tmpDir: tmpDir,
      ));
    } catch (e) {
      _dlog.logError(LogCategory.tts, 'KokoroOnnx: isolate spawn failed', e);
      fromIsolate.close();
      return false;
    }

    _sub = fromIsolate.listen((msg) {
      if (msg is SendPort) {
        _toIsolate = msg;
      } else if (msg is Map) {
        if (msg['ready'] == true && !ready.isCompleted) {
          ready.complete(true);
        } else if (msg.containsKey('initError')) {
          _dlog.logError(LogCategory.tts, 'KokoroOnnx: ${msg['initError']}');
          if (!ready.isCompleted) ready.complete(false);
        } else if (msg.containsKey('id')) {
          final c = _pending.remove(msg['id']);
          if (msg.containsKey('error')) {
            _dlog.logError(
                LogCategory.tts, 'KokoroOnnx synth failed: ${msg['error']}');
            c?.complete(null);
          } else {
            c?.complete(msg['path'] as String?);
          }
        }
      }
    });

    // Model load reads ~180 MB from disk — allow a slow first open.
    final ok = await ready.future
        .timeout(const Duration(seconds: 60), onTimeout: () => false);
    if (!ok) {
      _dlog.logError(LogCategory.tts, 'KokoroOnnx: engine failed to start');
      await stop();
    } else {
      _dlog.log(LogCategory.tts, 'KokoroOnnx: engine ready');
    }
    return ok;
  }

  /// Synthesize [text] to a 24 kHz WAV; returns its path, or null on failure.
  /// Requests are processed sequentially in the isolate (one CPU-heavy
  /// pipeline), so prefetch naturally queues behind live synthesis.
  Future<String?> synthesize(String text,
      {required String voice, double speed = 1.0}) async {
    final port = _toIsolate;
    if (port == null) return null;
    final sid = voiceIds[voice] ?? voiceIds['af_heart']!;
    final id = _nextId++;
    final c = Completer<String?>();
    _pending[id] = c;
    port.send({'id': id, 'text': text, 'sid': sid, 'speed': speed});
    return c.future;
  }

  /// Tear down the isolate and fail any in-flight requests.
  Future<void> stop() async {
    _toIsolate?.send(const {'cmd': 'dispose'});
    _toIsolate = null;
    await _sub?.cancel();
    _sub = null;
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    for (final c in _pending.values) {
      c.complete(null);
    }
    _pending.clear();
  }
}

class _IsolateArgs {
  const _IsolateArgs({
    required this.sendPort,
    required this.model,
    required this.voices,
    required this.tokens,
    required this.dataDir,
    required this.lexicon,
    required this.tmpDir,
  });
  final SendPort sendPort;
  final String model;
  final String voices;
  final String tokens;
  final String dataDir;
  final String lexicon;
  final String tmpDir;
}

Future<void> _isolateMain(_IsolateArgs args) async {
  final commands = ReceivePort();
  args.sendPort.send(commands.sendPort);

  sherpa.OfflineTts tts;
  try {
    sherpa.initBindings();
    tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        kokoro: sherpa.OfflineTtsKokoroModelConfig(
          model: args.model,
          voices: args.voices,
          tokens: args.tokens,
          dataDir: args.dataDir,
          lexicon: args.lexicon,
          // No dictDir: jieba is zh-only and excluded from the shipped pack.
        ),
        // Synthesis is the pacing item during rehearsal (RTF ≈ 0.9 on a
        // mid-range phone at 4 threads vs 1.34 at 2) — use the cores.
        numThreads: 4,
        debug: false,
      ),
    ));
  } catch (e) {
    args.sendPort.send({'initError': 'OfflineTts init failed: $e'});
    return;
  }
  args.sendPort.send(const {'ready': true});

  var fileSeq = 0;
  await for (final msg in commands) {
    if (msg is! Map) continue;
    if (msg['cmd'] == 'dispose') {
      tts.free();
      commands.close();
      return;
    }
    final id = msg['id'] as int;
    try {
      final audio = tts.generate(
        text: msg['text'] as String,
        sid: msg['sid'] as int,
        speed: (msg['speed'] as num).toDouble(),
      );
      if (audio.samples.isEmpty) {
        args.sendPort.send({'id': id, 'error': 'empty audio'});
        continue;
      }
      // Unique per call — prefetched paths stay valid while later lines
      // synthesize.
      final path = '${args.tmpDir}/kokoro_onnx_${fileSeq++}.wav';
      _writeWav(path, audio.samples, audio.sampleRate);
      args.sendPort.send({'id': id, 'path': path});
    } catch (e) {
      args.sendPort.send({'id': id, 'error': '$e'});
    }
  }
}

void _writeWav(String path, Float32List samples, int rate) {
  final n = samples.length;
  final b = ByteData(44 + n * 2);
  void s(int off, String t) {
    for (var i = 0; i < t.length; i++) {
      b.setUint8(off + i, t.codeUnitAt(i));
    }
  }

  s(0, 'RIFF');
  b.setUint32(4, 36 + n * 2, Endian.little);
  s(8, 'WAVEfmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, rate, Endian.little);
  b.setUint32(28, rate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  s(36, 'data');
  b.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    final v = (samples[i] * 32767).round();
    b.setInt16(44 + i * 2, v < -32768 ? -32768 : (v > 32767 ? 32767 : v),
        Endian.little);
  }
  File(path).writeAsBytesSync(b.buffer.asUint8List());
}
