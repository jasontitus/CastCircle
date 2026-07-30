import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'debug_log_service.dart';
import 'model_download_service.dart';

/// On-device streaming speech recognizer for live line matching, used where
/// the platform recognizer can't share the mic with the rehearsal recording
/// (Android — see docs/ANDROID_LIVE_MATCHING.md).
///
/// Runs a sherpa-onnx Zipformer transducer in a background isolate so decoding
/// (~tens of ms per 100 ms chunk on a phone) never janks the UI. The rehearsal
/// screen feeds it the PCM chunks the native capture fan-out delivers via
/// [SttChannel.onPcm], and receives cumulative partial transcripts per line,
/// mirroring the iOS SFSpeechRecognizer callback shape.
class LiveAsrService {
  LiveAsrService._();
  static final instance = LiveAsrService._();

  final _dlog = DebugLogService.instance;

  Isolate? _isolate;
  SendPort? _toIsolate;
  StreamSubscription? _fromIsolateSub;
  Future<bool>? _starting;

  /// Cumulative transcript of the current utterance, called on every change.
  void Function(String text)? onPartial;

  bool get isRunning => _toIsolate != null;

  /// Spawn the recognizer isolate if the model files are present. Safe to call
  /// repeatedly; concurrent calls share one startup. Returns false (loudly,
  /// via debug log) when the model isn't downloaded or failed to load.
  Future<bool> ensureStarted() {
    if (_toIsolate != null) return Future.value(true);
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<bool> _start() async {
    final dir = await ModelDownloadService.instance.getLiveAsrModelDir();
    if (dir == null) {
      _dlog.log(LogCategory.stt,
          'LiveASR: model not downloaded — live matching unavailable');
      return false;
    }

    final fromIsolate = ReceivePort();
    final ready = Completer<bool>();
    try {
      _isolate = await Isolate.spawn(_isolateMain, _IsolateArgs(
        sendPort: fromIsolate.sendPort,
        encoder: '$dir/encoder.onnx',
        decoder: '$dir/decoder.onnx',
        joiner: '$dir/joiner.onnx',
        tokens: '$dir/tokens.txt',
      ));
    } catch (e) {
      _dlog.logError(LogCategory.stt, 'LiveASR: isolate spawn failed', e);
      fromIsolate.close();
      return false;
    }

    _fromIsolateSub = fromIsolate.listen((msg) {
      if (msg is SendPort) {
        _toIsolate = msg;
      } else if (msg is Map) {
        if (msg['ready'] == true && !ready.isCompleted) {
          ready.complete(true);
        } else if (msg.containsKey('error')) {
          _dlog.logError(LogCategory.stt, 'LiveASR: ${msg['error']}');
          if (!ready.isCompleted) ready.complete(false);
        } else if (msg.containsKey('partial')) {
          onPartial?.call(msg['partial'] as String);
        }
      }
    });

    final ok = await ready.future
        .timeout(const Duration(seconds: 30), onTimeout: () => false);
    if (!ok) {
      _dlog.logError(
          LogCategory.stt, 'LiveASR: recognizer failed to initialize');
      await stop();
    } else {
      _dlog.log(LogCategory.stt, 'LiveASR: recognizer ready');
    }
    return ok;
  }

  /// Begin a fresh utterance (typically one script line): clears the
  /// transcript so [onPartial] restarts from empty.
  void startUtterance() => _toIsolate?.send(const {'cmd': 'start'});

  /// Feed a chunk of 16 kHz mono 16-bit LE PCM.
  void feedPcm(Uint8List pcm) => _toIsolate?.send(pcm);

  /// End the utterance: flushes the decoder with trailing silence so the
  /// final words are emitted through [onPartial].
  void endUtterance() => _toIsolate?.send(const {'cmd': 'end'});

  /// Tear down the isolate (rehearsal over). [ensureStarted] restarts it.
  Future<void> stop() async {
    _toIsolate?.send(const {'cmd': 'dispose'});
    _toIsolate = null;
    await _fromIsolateSub?.cancel();
    _fromIsolateSub = null;
    // Give the isolate a moment to free native memory, then make sure.
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
  }
}

class _IsolateArgs {
  const _IsolateArgs({
    required this.sendPort,
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
  });
  final SendPort sendPort;
  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;
}

Future<void> _isolateMain(_IsolateArgs args) async {
  final commands = ReceivePort();
  args.sendPort.send(commands.sendPort);

  sherpa.OnlineRecognizer recognizer;
  try {
    sherpa.initBindings();
    recognizer = sherpa.OnlineRecognizer(sherpa.OnlineRecognizerConfig(
      model: sherpa.OnlineModelConfig(
        transducer: sherpa.OnlineTransducerModelConfig(
          encoder: args.encoder,
          decoder: args.decoder,
          joiner: args.joiner,
        ),
        tokens: args.tokens,
        numThreads: 2,
        debug: false,
      ),
      // The rehearsal screen owns endpointing (its silence timers), so the
      // recognizer just transcribes.
      enableEndpoint: false,
    ));
  } catch (e) {
    args.sendPort.send({'error': 'recognizer init failed: $e'});
    return;
  }
  args.sendPort.send(const {'ready': true});

  var stream = recognizer.createStream();
  var lastSent = '';

  void decodeAndReport() {
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }
    final text = recognizer.getResult(stream).text.trim();
    if (text != lastSent) {
      lastSent = text;
      args.sendPort.send({'partial': text});
    }
  }

  await for (final msg in commands) {
    if (msg is Uint8List) {
      // 16-bit LE PCM → normalized floats.
      final n = msg.length ~/ 2;
      final bd = ByteData.sublistView(msg);
      final samples = Float32List(n);
      for (var i = 0; i < n; i++) {
        samples[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
      }
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      decodeAndReport();
    } else if (msg is Map) {
      switch (msg['cmd']) {
        case 'start':
          stream.free();
          stream = recognizer.createStream();
          lastSent = '';
          break;
        case 'end':
          // ~0.8 s of silence gives the zipformer the right-context it needs
          // to emit the last words (measured in the macOS eval — shorter
          // padding truncates line tails).
          stream.acceptWaveform(
              samples: Float32List(12800), sampleRate: 16000);
          decodeAndReport();
          break;
        case 'dispose':
          stream.free();
          recognizer.free();
          commands.close();
          return;
      }
    }
  }
}
