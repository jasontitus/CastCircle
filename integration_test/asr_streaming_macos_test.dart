// Head-to-head evaluation of streaming ASR candidates for live line matching,
// run on macOS before any phone round-trip (see docs/ANDROID_LIVE_MATCHING.md).
//
//   flutter test integration_test/asr_streaming_macos_test.dart -d macos
//
// Requires the model dirs + synthesized test lines staged under .asr-eval/
// (git-ignored). Each WAV is fed in 200 ms chunks, exactly as the live mic
// path will feed the recognizer, and we print the partial-transcript cadence,
// the final transcript, and the real-time factor.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Repo root for fixture/model staging paths. Relative default works when
/// tests run from the checkout root; override with
/// --dart-define=CASTCIRCLE_REPO=/path for other harnesses.
const _ccRepo =
    String.fromEnvironment('CASTCIRCLE_REPO', defaultValue: '.');


const _repo = _ccRepo;

class _Candidate {
  const _Candidate(this.name, this.dir, this.encoder, this.decoder, this.joiner);
  final String name;
  final String dir;
  final String encoder;
  final String decoder;
  final String joiner;
}

const _candidates = [
  _Candidate('kroko-2025-08-06', '$_repo/.asr-eval/kroko', 'encoder.onnx',
      'decoder.onnx', 'joiner.onnx'),
  _Candidate(
      'en-20M-int8',
      '$_repo/.asr-eval/en20m',
      'encoder-epoch-99-avg-1.int8.onnx',
      'decoder-epoch-99-avg-1.int8.onnx',
      'joiner-epoch-99-avg-1.int8.onnx'),
];

const _lines = {
  'line1.wav': 'any savage can dance sir',
  'line2.wav': 'it is a truth universally acknowledged that a single man in '
      'possession of a good fortune must be in want of a wife',
  'line3.wav': 'you must allow me to tell you how ardently i admire and love you',
  'line4.wav': 'i could easily forgive his pride if he had not mortified mine',
};

/// 16-bit little-endian mono PCM samples from [path], asserting 16 kHz.
Float32List _samplesFromWav(String path) {
  final bytes = File(path).readAsBytesSync();
  final bd = ByteData.sublistView(bytes);
  // Walk RIFF chunks to the data chunk; verify fmt says 16 kHz mono PCM16.
  var i = 12;
  var dataStart = -1, dataLen = 0;
  while (i + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(i, i + 4));
    final sz = bd.getUint32(i + 4, Endian.little);
    if (id == 'fmt ') {
      expect(bd.getUint16(i + 10, Endian.little), 1, reason: 'mono');
      expect(bd.getUint32(i + 12, Endian.little), 16000, reason: '16 kHz');
      expect(bd.getUint16(i + 22, Endian.little), 16, reason: '16-bit');
    } else if (id == 'data') {
      dataStart = i + 8;
      dataLen = sz;
    }
    i += 8 + sz + (sz & 1);
  }
  expect(dataStart, isNot(-1), reason: 'no data chunk in $path');
  final n = dataLen ~/ 2;
  final out = Float32List(n);
  for (var s = 0; s < n; s++) {
    out[s] = bd.getInt16(dataStart + s * 2, Endian.little) / 32768.0;
  }
  return out;
}

/// Word-level LCS of [expected] vs [got], as a fraction of expected length.
/// (Greedy in-order matching mis-scores badly when a common word like "a"
/// matches ahead of the real alignment.)
double _matchRate(String expected, String got) {
  List<String> words(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z\s]'), '')
      .trim()
      .split(RegExp(r'\s+'));
  final a = words(expected), b = words(got);
  if (a.isEmpty || b.first.isEmpty) return 0;
  var prev = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0);
    for (var j = 1; j <= b.length; j++) {
      cur[j] = a[i - 1] == b[j - 1]
          ? prev[j - 1] + 1
          : (prev[j] > cur[j - 1] ? prev[j] : cur[j - 1]);
    }
    prev = cur;
  }
  return prev[b.length] / a.length;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('streaming candidates on synthesized rehearsal lines', () {
    sherpa.initBindings();

    for (final c in _candidates) {
      final recognizer = sherpa.OnlineRecognizer(sherpa.OnlineRecognizerConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: '${c.dir}/${c.encoder}',
            decoder: '${c.dir}/${c.decoder}',
            joiner: '${c.dir}/${c.joiner}',
          ),
          tokens: '${c.dir}/tokens.txt',
          numThreads: 2,
          debug: false,
        ),
        // Endpointing is handled by the rehearsal screen's own silence logic;
        // here we just want the transcript.
        enableEndpoint: false,
      ));

      print('=== ${c.name} ===');
      var total = 0.0;
      for (final entry in _lines.entries) {
        final raw = _samplesFromWav('$_repo/.asr-eval/${entry.key}');
        // Lead-in so the encoder has left context for the first words —
        // the live mic path opens before the actor starts speaking, so this
        // mirrors reality too.
        final samples = Float32List(4800 + raw.length)..setAll(4800, raw);
        final audioSec = samples.length / 16000.0;
        final stream = recognizer.createStream();
        final sw = Stopwatch()..start();
        var firstPartialMs = -1;
        // 200 ms chunks — the cadence the live mic path will deliver.
        for (var off = 0; off < samples.length; off += 3200) {
          final end = (off + 3200 < samples.length) ? off + 3200 : samples.length;
          stream.acceptWaveform(
              samples: samples.sublist(off, end), sampleRate: 16000);
          while (recognizer.isReady(stream)) {
            recognizer.decode(stream);
          }
          if (firstPartialMs < 0 &&
              recognizer.getResult(stream).text.trim().isNotEmpty) {
            firstPartialMs = sw.elapsedMilliseconds;
          }
        }
        // Flush with trailing silence so the last words decode — the zipformer
        // needs ~0.8 s of right context before it will emit the final tokens.
        stream.acceptWaveform(
            samples: Float32List(12800), sampleRate: 16000);
        while (recognizer.isReady(stream)) {
          recognizer.decode(stream);
        }
        sw.stop();
        final text = recognizer.getResult(stream).text.trim();
        stream.free();
        final rate = _matchRate(entry.value, text);
        total += rate;
        print('${entry.key}: match ${(rate * 100).round()}% '
            'rtf ${(sw.elapsedMilliseconds / 1000 / audioSec).toStringAsFixed(3)} '
            'firstPartial ${firstPartialMs}ms\n  "$text"');
      }
      print('${c.name} mean match: '
          '${(total / _lines.length * 100).round()}%');
      recognizer.free();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
