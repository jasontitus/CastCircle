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
  // Incremented by stop(); a start that began before the stop must not
  // resurrect state afterwards (a stop mid-load used to leave ensureStarted
  // returning a doomed future for 30 s).
  var _epoch = 0;

  /// Cumulative transcript of the current utterance, called on every change.
  void Function(String text)? onPartial;

  /// Current utterance id. Partials are tagged with the utterance they came
  /// from and stale ones are dropped: the isolate may still be decoding line
  /// N's flush when line N+1 starts, and without the tag line N's words were
  /// delivered — and scored — against line N+1 (seen in the field).
  var _uid = 0;

  bool get isRunning => _toIsolate != null;

  /// Spawn the recognizer isolate if the model files are present. Safe to call
  /// repeatedly; concurrent calls share one startup. Returns false (loudly,
  /// via debug log) when the model isn't downloaded or failed to load.
  Future<bool> ensureStarted() {
    if (_toIsolate != null) return Future.value(true);
    if (_starting != null) return _starting!;
    late final Future<bool> f;
    f = _start().whenComplete(() {
      // Only clear our own registration — stop() may have already replaced
      // it with a fresh start that must not be wiped by this doomed one.
      if (identical(_starting, f)) _starting = null;
    });
    return _starting = f;
  }

  Future<bool> _start() async {
    final epoch = _epoch;
    final dir = await ModelDownloadService.instance.getLiveAsrModelDir();
    if (dir == null) {
      _dlog.log(LogCategory.stt,
          'LiveASR: model not downloaded — live matching unavailable');
      return false;
    }

    final fromIsolate = ReceivePort();
    final ready = Completer<bool>();
    late final Isolate spawned;
    try {
      spawned = await Isolate.spawn(_isolateMain, _IsolateArgs(
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
    if (epoch != _epoch) {
      // stop() ran while we were loading — this instance is orphaned.
      spawned.kill(priority: Isolate.immediate);
      fromIsolate.close();
      return false;
    }
    _isolate = spawned;

    _fromIsolateSub = fromIsolate.listen((msg) {
      if (epoch != _epoch) return; // stopped since — ignore everything
      if (msg is SendPort) {
        _toIsolate = msg;
      } else if (msg is Map) {
        if (msg['ready'] == true && !ready.isCompleted) {
          ready.complete(true);
        } else if (msg.containsKey('error')) {
          _dlog.logError(LogCategory.stt, 'LiveASR: ${msg['error']}');
          if (!ready.isCompleted) ready.complete(false);
        } else if (msg.containsKey('partial')) {
          if (msg['uid'] == _uid) {
            onPartial?.call(msg['partial'] as String);
          }
        }
      }
    });

    final ok = await ready.future
        .timeout(const Duration(seconds: 30), onTimeout: () => false);
    if (epoch != _epoch) return false; // stopped while loading
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
  /// transcript so [onPartial] restarts from empty, and invalidates any
  /// partials still in flight from the previous utterance.
  void startUtterance() =>
      _toIsolate?.send({'cmd': 'start', 'uid': ++_uid});

  /// Feed a chunk of 16 kHz mono 16-bit LE PCM.
  void feedPcm(Uint8List pcm) => _toIsolate?.send(pcm);

  /// End the utterance: flushes the decoder with trailing silence so the
  /// final words are emitted through [onPartial].
  void endUtterance() => _toIsolate?.send(const {'cmd': 'end'});

  /// Tear down the isolate. [ensureStarted] restarts it fresh — including
  /// while a previous start is still in flight (the epoch guard orphans it).
  Future<void> stop() async {
    _epoch++;
    _starting = null;
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
  var uid = 0;

  void decodeAndReport() {
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }
    final text = recognizer.getResult(stream).text.trim();
    if (text != lastSent) {
      lastSent = text;
      args.sendPort.send({'partial': text, 'uid': uid});
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
          uid = msg['uid'] as int? ?? uid + 1;
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
