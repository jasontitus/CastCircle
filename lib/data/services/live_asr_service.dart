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

  _LiveAsrSession? _session;
  Future<bool>? _starting;
  Future<void>? _stopping;
  var _epoch = 0;

  /// Cumulative transcript of the current utterance, called on every change.
  void Function(String text)? onPartial;

  /// Current utterance id. Partials are tagged with the utterance they came
  /// from and stale ones are dropped: the isolate may still be decoding line
  /// N's flush when line N+1 starts.
  var _uid = 0;

  bool get isRunning => _session?.ready ?? false;

  SendPort? get _readyPort {
    final session = _session;
    return session?.ready == true ? session?.sendPort : null;
  }

  /// Spawn the recognizer isolate if the model files are present. Safe to call
  /// repeatedly; concurrent calls share one startup. Returns false (loudly,
  /// via debug log) when the model isn't downloaded or failed to load.
  Future<bool> ensureStarted() {
    if (isRunning) return Future.value(true);
    final stopping = _stopping;
    if (stopping != null) {
      return stopping.then((_) => ensureStarted());
    }
    if (_starting != null) return _starting!;
    late final Future<bool> future;
    future = _start().whenComplete(() {
      if (identical(_starting, future)) _starting = null;
    });
    return _starting = future;
  }

  Future<bool> _start() async {
    final epoch = _epoch;
    final dir = await ModelDownloadService.instance.getLiveAsrModelDir();
    if (epoch != _epoch) return false;
    if (dir == null) {
      _dlog.log(
        LogCategory.stt,
        'LiveASR: model not downloaded — live matching unavailable',
      );
      return false;
    }

    final session = _LiveAsrSession();
    _session = session;

    session.fromSubscription = session.fromPort.listen((message) {
      if (message is SendPort) {
        if (!session.controlPort.isCompleted) {
          session.controlPort.complete(message);
        }
        if (identical(_session, session) && epoch == _epoch) {
          session.sendPort = message;
        }
        return;
      }
      if (message is! Map) return;
      if (message['disposed'] == true) {
        if (!session.disposed.isCompleted) session.disposed.complete();
        return;
      }
      if (!identical(_session, session) || epoch != _epoch) return;
      if (message['ready'] == true) {
        session.ready = true;
        if (!session.readySignal.isCompleted) {
          session.readySignal.complete(true);
        }
      } else if (message.containsKey('error')) {
        _dlog.logError(LogCategory.stt, 'LiveASR: ${message['error']}');
        if (!session.readySignal.isCompleted) {
          session.readySignal.complete(false);
        }
      } else if (message.containsKey('partial') && message['uid'] == _uid) {
        onPartial?.call(message['partial'] as String);
      }
    });
    session.errorSubscription = session.errorPort.listen((error) {
      if (!identical(_session, session) || epoch != _epoch) return;
      _dlog.logError(LogCategory.stt, 'LiveASR: isolate error', error);
      if (!session.readySignal.isCompleted) {
        session.readySignal.complete(false);
      }
    });
    session.exitSubscription = session.exitPort.listen((_) {
      if (!identical(_session, session) || epoch != _epoch) return;
      final wasReady = session.ready;
      session.ready = false;
      _session = null;
      _epoch++;
      if (!session.readySignal.isCompleted) {
        session.readySignal.complete(false);
      }
      _dlog.logError(
        LogCategory.stt,
        wasReady
            ? 'LiveASR: recognizer isolate exited unexpectedly'
            : 'LiveASR: recognizer isolate exited during startup',
      );
      unawaited(session.close());
    });

    late final Isolate spawned;
    try {
      spawned = await Isolate.spawn(
        _isolateMain,
        _IsolateArgs(
          sendPort: session.fromPort.sendPort,
          encoder: '$dir/encoder.onnx',
          decoder: '$dir/decoder.onnx',
          joiner: '$dir/joiner.onnx',
          tokens: '$dir/tokens.txt',
        ),
        onExit: session.exitPort.sendPort,
        onError: session.errorPort.sendPort,
        errorsAreFatal: true,
      );
      session.isolate = spawned;
    } catch (e) {
      _dlog.logError(LogCategory.stt, 'LiveASR: isolate spawn failed', e);
      if (identical(_session, session)) _session = null;
      if (!session.readySignal.isCompleted) {
        session.readySignal.complete(false);
      }
      await session.close();
      return false;
    }
    if (epoch != _epoch || !identical(_session, session)) {
      spawned.kill(priority: Isolate.immediate);
      await session.close();
      return false;
    }

    final ok = await session.readySignal.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => false,
    );
    if (epoch != _epoch || !identical(_session, session)) return false;
    if (!ok) {
      _dlog.logError(
        LogCategory.stt,
        'LiveASR: recognizer failed to initialize',
      );
      await stop();
      return false;
    }
    _dlog.log(LogCategory.stt, 'LiveASR: recognizer ready');
    return true;
  }

  /// Begin a fresh utterance (typically one script line): clears the
  /// transcript so [onPartial] restarts from empty, and invalidates any
  /// partials still in flight from the previous utterance.
  void startUtterance() => _readyPort?.send({'cmd': 'start', 'uid': ++_uid});

  /// Feed a chunk of 16 kHz mono 16-bit LE PCM.
  void feedPcm(Uint8List pcm) => _readyPort?.send(pcm);

  /// End the utterance: flushes the decoder with trailing silence so the
  /// final words are emitted through [onPartial].
  void endUtterance() => _readyPort?.send(const {'cmd': 'end'});

  /// Tear down the isolate after it explicitly frees its native handles.
  /// A force-kill is only the timeout fallback.
  Future<void> stop() {
    if (_stopping != null) return _stopping!;
    late final Future<void> future;
    future = _stop().whenComplete(() {
      if (identical(_stopping, future)) _stopping = null;
    });
    return _stopping = future;
  }

  Future<void> _stop() async {
    _epoch++;
    _starting = null;
    final session = _session;
    _session = null;
    if (session == null) return;
    session.ready = false;
    if (!session.readySignal.isCompleted) {
      session.readySignal.complete(false);
    }

    SendPort? control = session.sendPort;
    if (control == null) {
      try {
        control = await session.controlPort.future.timeout(
          const Duration(milliseconds: 500),
        );
      } on TimeoutException {
        // The isolate never exposed its command port; force-kill below.
      }
    }

    var disposed = false;
    if (control != null) {
      control.send(const {'cmd': 'dispose'});
      try {
        await session.disposed.future.timeout(const Duration(seconds: 2));
        disposed = true;
      } on TimeoutException {
        _dlog.logError(
          LogCategory.stt,
          'LiveASR: native disposal acknowledgement timed out',
        );
      }
    }
    session.isolate?.kill(
      priority: disposed ? Isolate.beforeNextEvent : Isolate.immediate,
    );
    await session.close();
  }
}

class _LiveAsrSession {
  final fromPort = ReceivePort();
  final exitPort = ReceivePort();
  final errorPort = ReceivePort();
  final readySignal = Completer<bool>();
  final controlPort = Completer<SendPort>();
  final disposed = Completer<void>();

  Isolate? isolate;
  SendPort? sendPort;
  StreamSubscription<dynamic>? fromSubscription;
  StreamSubscription<dynamic>? exitSubscription;
  StreamSubscription<dynamic>? errorSubscription;
  bool ready = false;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await fromSubscription?.cancel();
    await exitSubscription?.cancel();
    await errorSubscription?.cancel();
    fromPort.close();
    exitPort.close();
    errorPort.close();
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
    recognizer = sherpa.OnlineRecognizer(
      sherpa.OnlineRecognizerConfig(
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
      ),
    );
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
          stream.acceptWaveform(samples: Float32List(12800), sampleRate: 16000);
          decodeAndReport();
          break;
        case 'dispose':
          stream.free();
          recognizer.free();
          commands.close();
          args.sendPort.send(const {'disposed': true});
          return;
      }
    }
  }
}
