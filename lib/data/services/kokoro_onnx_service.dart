import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ffi/ffi.dart' as pkg_ffi;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'debug_log_service.dart';
import 'espeak_heteronyms.dart';
import 'model_manager.dart';

/// Kokoro neural TTS for platforms without MLX (Android): sherpa-onnx
/// OfflineTts running the fp16 Kokoro pack (see ModelManager), hosted in a
/// background isolate because synthesis is ~real-time on a phone (RTF ≈ 0.9
/// at 4 threads on a Galaxy A35) and would freeze the UI for seconds per line.
///
/// Exposes the same contract as the iOS KokoroMLX channel — synthesize(text,
/// voice, speed) → WAV file path — so TtsService's playback, chunking, and
/// prefetch logic is shared untouched.
///
/// Requests are queued HERE (one in the isolate at a time), not in the
/// isolate's port, so stale work can be dropped: an [urgent] request (a line
/// being spoken now) cancels older queued urgent requests outright and aborts
/// whatever is currently generating via a native flag the generate callback
/// polls — without this, restart/skip taps piled up full-length syntheses of
/// lines nobody would hear (measured: 11 s of silence from two stale synths).
class KokoroOnnxService {
  KokoroOnnxService._();
  static final instance = KokoroOnnxService._();

  final _dlog = DebugLogService.instance;

  Isolate? _isolate;
  SendPort? _toIsolate;
  StreamSubscription? _sub;
  Future<bool>? _starting;

  final _queue = <_Req>[];
  _Req? _inFlight;
  var _nextSeq = 0;

  /// Signals the queue that a generation actually started on the native
  /// side. macOS service tests await this to know a queued request is no
  /// longer merely pending.
  final _generationStarted = StreamController<void>.broadcast(sync: true);
  Future<void> get nextGenerationStarted =>
      _generationStarted.stream.first;

  /// Native flag shared with the isolate's generate callback: any request
  /// whose seq is below this value aborts. Process-wide memory — the only
  /// way to signal an isolate that is blocked inside a native call.
  final Pointer<Int32> _cancelBelow = pkg_ffi.calloc<Int32>();

  bool get isRunning => _toIsolate != null;

  /// Speaker IDs for kokoro-multi-lang-v1_0 (identical in v1_1, which appends
  /// new voices). Source: sherpa-onnx model docs. The English voices the app
  /// offers all live in 0-27.
  static const voiceIds = <String, int>{
    'af_alloy': 0,
    'af_aoede': 1,
    'af_bella': 2,
    'af_heart': 3,
    'af_jessica': 4,
    'af_kore': 5,
    'af_nicole': 6,
    'af_nova': 7,
    'af_river': 8,
    'af_sarah': 9,
    'af_sky': 10,
    'am_adam': 11,
    'am_echo': 12,
    'am_eric': 13,
    'am_fenrir': 14,
    'am_liam': 15,
    'am_michael': 16,
    'am_onyx': 17,
    'am_puck': 18,
    'am_santa': 19,
    'bf_alice': 20,
    'bf_emma': 21,
    'bf_isabella': 22,
    'bf_lily': 23,
    'bm_daniel': 24,
    'bm_fable': 25,
    'bm_george': 26,
    'bm_lewis': 27,
  };

  /// Resolve a persisted/product voice ID without silently changing speakers.
  static int? speakerIdForVoice(String voice) => voiceIds[voice];

  // Incremented by stop(); a start that began before the stop must not
  // resurrect state afterwards.
  var _epoch = 0;

  /// Spawn the synthesis isolate if the model is downloaded. Safe to call
  /// repeatedly; concurrent calls share one startup.
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
    final paths = await ModelManager.instance.getKokoroPaths();
    if (paths == null) {
      _dlog.log(LogCategory.tts, 'KokoroOnnx: model not downloaded');
      return false;
    }
    final tmpDir = (await getTemporaryDirectory()).path;

    final fromIsolate = ReceivePort();
    final ready = Completer<bool>();
    late final Isolate spawned;
    try {
      spawned = await Isolate.spawn(
        _isolateMain,
        _IsolateArgs(
          sendPort: fromIsolate.sendPort,
          model: paths.model,
          voices: paths.voices,
          tokens: paths.tokens,
          dataDir: paths.dataDir,
          lexicon: paths.lexicon,
          tmpDir: tmpDir,
          cancelBelowAddr: _cancelBelow.address,
        ),
      );
    } catch (e) {
      _dlog.logError(LogCategory.tts, 'KokoroOnnx: isolate spawn failed', e);
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

    _sub = fromIsolate.listen(
      (msg) {
        if (epoch != _epoch) return; // stopped since — ignore everything
        if (msg is SendPort) {
          _toIsolate = msg;
        } else if (msg is Map) {
          if (msg['ready'] == true && !ready.isCompleted) {
            ready.complete(true);
          } else if (msg.containsKey('initError')) {
            _dlog.logError(LogCategory.tts, 'KokoroOnnx: ${msg['initError']}');
            if (!ready.isCompleted) ready.complete(false);
          } else if (msg.containsKey('seq')) {
            final req = _inFlight;
            _inFlight = null;
            if (req != null && req.seq == msg['seq']) {
              if (msg.containsKey('error')) {
                _dlog.logError(
                  LogCategory.tts,
                  'KokoroOnnx synth failed: ${msg['error']}',
                );
                req.completer.complete(null);
              } else if (msg['aborted'] == true) {
                req.completer.complete(null);
              } else {
                req.completer.complete(msg['path'] as String?);
              }
            }
            _pump();
          }
        }
      },
      onDone: () {
        // The isolate died on its own (native crash in sherpa, OS kill): the
        // port stream just ends. Without this, every in-flight and queued
        // synthesize() awaits its completer forever and TTS silently hangs.
        if (epoch != _epoch) return;
        _dlog.logError(
          LogCategory.tts,
          'KokoroOnnx: synthesis isolate died — failing pending requests',
        );
        final inFlight = _inFlight;
        _inFlight = null;
        if (inFlight != null && !inFlight.completer.isCompleted) {
          inFlight.completer.complete(null);
        }
        for (final req in _queue) {
          if (!req.completer.isCompleted) req.completer.complete(null);
        }
        _queue.clear();
        _toIsolate = null;
        if (!ready.isCompleted) ready.complete(false);
      },
    );

    // Model load reads ~180 MB from disk — allow a slow first open (cold
    // flash on a low-end phone, or an emulator's qcow, can exceed a minute).
    final ok = await ready.future.timeout(
      const Duration(seconds: 150),
      onTimeout: () => false,
    );
    if (epoch != _epoch) return false; // stopped while loading
    if (!ok) {
      _dlog.logError(LogCategory.tts, 'KokoroOnnx: engine failed to start');
      await stop();
    } else {
      _dlog.log(LogCategory.tts, 'KokoroOnnx: engine ready');
      _pump();
    }
    return ok;
  }

  /// Synthesize [text] to a 24 kHz WAV; returns its path, or null on failure
  /// or cancellation.
  ///
  /// [urgent] marks audio the actor is waiting on RIGHT NOW (a line being
  /// spoken): it cancels older queued urgent requests and aborts the current
  /// generation so it runs next. Prefetches are non-urgent: they queue behind
  /// everything and are the natural casualty of an urgent arrival.
  Future<String?> synthesize(
    String rawText, {
    required String voice,
    double speed = 1.0,
    bool urgent = false,
  }) async {
    final sid = speakerIdForVoice(voice);
    if (sid == null) {
      _dlog.logError(LogCategory.tts, 'KokoroOnnx: unknown voice ID "$voice"');
      return null;
    }
    // Fix the heteronyms espeak-ng reads wrong ("Long live the King" as
    // /laɪv/) BEFORE the cache key is computed, so the key follows what will
    // actually be spoken: applying it later would keep serving the
    // mispronounced WAV already on disk under the original text.
    final text = EspeakHeteronyms.apply(rawText);

    // Disk cache first: actors drill the same scene repeatedly, and
    // synthesis runs near realtime (RTF ~0.9) — a replayed line from cache
    // is instant instead of seconds. Keyed by everything that shapes the
    // audio. Works even while the engine is still loading.
    final cachePath = await _cachePathFor(text, voice, speed);
    if (cachePath != null && await File(cachePath).exists()) {
      // Touch so pruning stays LRU (the mtime IS the eviction order —
      // removing this would silently turn pruning into FIFO). Async and
      // unawaited: a metadata write has no business on the play path.
      unawaited(
        File(cachePath).setLastModified(DateTime.now()).catchError((_) {}),
      );
      return cachePath;
    }

    if (_toIsolate == null && _starting == null) {
      return null;
    }
    final req = _Req(
      seq: _nextSeq++,
      text: text,
      sid: sid,
      speed: speed,
      urgent: urgent,
    );

    if (urgent) {
      // Older urgent requests are for lines nobody will hear — drop queued
      // ones and abort the one mid-generate (urgent or prefetch alike; a
      // dropped prefetch just re-synthesizes on demand later).
      _queue.removeWhere((q) {
        if (q.urgent) q.completer.complete(null);
        return q.urgent;
      });
      _cancelBelow.value = req.seq;
      // FRONT of the queue: the actor is waiting on this line RIGHT NOW.
      // Appending put it behind stale prefetches (each a queue round-trip,
      // and a session restart piles several up — field: 11.5 s before the
      // first line of a new read-through started playing).
      _queue.insert(0, req);
    } else {
      _queue.add(req);
    }
    _pump();

    final path = await req.completer.future;
    if (path == null || cachePath == null) return path;
    // Adopt the fresh WAV into the cache (same filesystem — cheap rename).
    try {
      File(path).renameSync(cachePath);
      return cachePath;
    } catch (_) {
      return path;
    }
  }

  // ── Synthesis cache ────────────────────────────────────

  static String? _cacheDirPath;
  static bool _pruneScheduled = false;

  Future<String?> _cachePathFor(String text, String voice, double speed) async {
    try {
      var dir = _cacheDirPath;
      if (dir == null) {
        dir = '${(await getTemporaryDirectory()).path}/kokoro_cache';
        Directory(dir).createSync(recursive: true);
        _cacheDirPath = dir;
        _schedulePrune(dir);
      }
      final key = crypto.sha1
          .convert(utf8.encode('$text|$voice|$speed'))
          .toString();
      return '$dir/$key.wav';
    } catch (_) {
      return null; // cacheless operation is always safe
    }
  }

  /// LRU-prune the cache to ~150 MB, once per app run. WAVs are ~48 KB/s of
  /// audio, so this keeps roughly an hour of recently used lines.
  void _schedulePrune(String dir) {
    if (_pruneScheduled) return;
    _pruneScheduled = true;
    // Isolate.run: the walk stats every cached WAV (thousands of files at
    // steady state) — a Future(...) closure still runs it on the UI isolate.
    // NB: the closure runs in a fresh isolate — no singletons (DebugLog) in
    // there; the summary comes back as the return value and is logged here.
    Isolate.run<int>(() {
          try {
            const maxBytes = 150 * 1024 * 1024;
            const lowWater = 100 * 1024 * 1024;
            final entries = <(File, DateTime, int)>[];
            var total = 0;
            for (final e in Directory(dir).listSync()) {
              if (e is! File) continue;
              final stat = e.statSync();
              entries.add((e, stat.modified, stat.size));
              total += stat.size;
            }
            if (total <= maxBytes) return 0;
            entries.sort((a, b) => a.$2.compareTo(b.$2)); // oldest first
            var removed = 0;
            for (final (file, _, size) in entries) {
              if (total <= lowWater) break;
              try {
                file.deleteSync();
                total -= size;
                removed++;
              } catch (_) {}
            }
            return removed;
          } catch (_) {
            return 0;
          }
        })
        .then((removed) {
          if (removed > 0) {
            DebugLogService.instance.log(
              LogCategory.tts,
              'KokoroOnnx: pruned $removed cached WAVs (cache was over 150MB)',
            );
          }
        })
        .catchError((_) {});
  }

  /// Send the next queued request if the isolate is idle.
  void _pump() {
    final port = _toIsolate;
    if (port == null || _inFlight != null || _queue.isEmpty) return;
    final req = _queue.removeAt(0);
    _inFlight = req;
    _generationStarted.add(null);
    port.send({
      'seq': req.seq,
      'text': req.text,
      'sid': req.sid,
      'speed': req.speed,
    });
  }

  /// Tear down the isolate and fail any in-flight requests.
  Future<void> stop() async {
    _epoch++;
    _starting = null;
    _toIsolate?.send(const {'cmd': 'dispose'});
    _toIsolate = null;
    await _sub?.cancel();
    _sub = null;
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _inFlight?.completer.complete(null);
    _inFlight = null;
    for (final q in _queue) {
      q.completer.complete(null);
    }
    _queue.clear();
    // _cancelBelow is intentionally never freed: the singleton lives for the
    // process, and a freed pointer with a live isolate would be a use-after-free.
  }
}

class _Req {
  _Req({
    required this.seq,
    required this.text,
    required this.sid,
    required this.speed,
    required this.urgent,
  });
  final int seq;
  final String text;
  final int sid;
  final double speed;
  final bool urgent;
  final completer = Completer<String?>();
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
    required this.cancelBelowAddr,
  });
  final SendPort sendPort;
  final String model;
  final String voices;
  final String tokens;
  final String dataDir;
  final String lexicon;
  final String tmpDir;
  final int cancelBelowAddr;
}

Future<void> _isolateMain(_IsolateArgs args) async {
  final commands = ReceivePort();
  args.sendPort.send(commands.sendPort);
  final cancelBelow = Pointer<Int32>.fromAddress(args.cancelBelowAddr);

  sherpa.OfflineTts tts;
  try {
    sherpa.initBindings();
    tts = sherpa.OfflineTts(
      sherpa.OfflineTtsConfig(
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
      ),
    );
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
    final seq = msg['seq'] as int;
    if (seq < cancelBelow.value) {
      args.sendPort.send({'seq': seq, 'aborted': true});
      continue;
    }
    try {
      // Track whether the abort actually TRUNCATED generation: the callback
      // polls only between sherpa's internal chunks (~a sentence), so a
      // cancel can land after the last poll — the audio is then complete
      // and worth keeping even though the request is stale.
      var abortedMidGeneration = false;
      final audio = tts.generateWithCallback(
        text: msg['text'] as String,
        sid: msg['sid'] as int,
        speed: (msg['speed'] as num).toDouble(),
        // Polled between generation chunks: 0 aborts. This is how a
        // superseded line stops burning CPU mid-synthesis.
        callback: (_) {
          if (seq < cancelBelow.value) {
            abortedMidGeneration = true;
            return 0;
          }
          return 1;
        },
      );
      if (abortedMidGeneration) {
        // Truncated — never let a half-synthesized line escape (it would be
        // adopted into the disk cache and play cut off forever).
        args.sendPort.send({'seq': seq, 'aborted': true});
        continue;
      }
      if (audio.samples.isEmpty) {
        args.sendPort.send({'seq': seq, 'error': 'empty audio'});
        continue;
      }
      // NOTE: a stale-but-COMPLETE generation falls through on purpose: the
      // service adopts finished WAVs into the disk cache, so a "wasted"
      // prefetch from a closed session becomes the next session's instant
      // cache hit instead of discarded work.
      // Unique per call — prefetched paths stay valid while later lines
      // synthesize.
      final path = '${args.tmpDir}/kokoro_onnx_${fileSeq++}.wav';
      _writeWav(path, audio.samples, audio.sampleRate);
      args.sendPort.send({'seq': seq, 'path': path});
    } catch (e) {
      args.sendPort.send({'seq': seq, 'error': '$e'});
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
    b.setInt16(
      44 + i * 2,
      v < -32768 ? -32768 : (v > 32767 ? 32767 : v),
      Endian.little,
    );
  }
  File(path).writeAsBytesSync(b.buffer.asUint8List());
}
