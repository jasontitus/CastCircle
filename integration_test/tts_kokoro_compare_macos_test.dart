// Kokoro ONNX quality/speed comparison for the Android TTS decision:
// fp32 v1.0 (current 600 MB download) vs int8 v1.0 vs int8 v1.1.
//
//   flutter test integration_test/tts_kokoro_compare_macos_test.dart -d macos
//
// For each model × app voice × rehearsal line: synthesize, measure RTF, then
// round-trip the audio through the kroko streaming ASR (the same model the
// app uses for live matching) and score word-match against the input text —
// an objective intelligibility proxy. WAVs are written to the temp dir
// (printed) for human listening, which is the final judge.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

const _eval = '/Users/jasontitus/experiments/CastCircle/.asr-eval';

// int8 v1.0/v1.1 were eliminated (audibly worse per human listening, and
// SLOWER than fp32 — ORT quantized kernels fall back on both Mac and A35).
// fp16 is our own conversion (max_finite_val=65504 so the 24 kHz constant
// survives; the library default truncated it to 10000).
const _models = {
  'fp32-v1_0': ('$_eval/kokoro-multi-lang-v1_0', 'model.onnx'),
  'fp16-v1_0': ('$_eval/kokoro-fp16-v1_0', 'model.fp16.onnx'),
};

// Same speaker IDs in v1.0 and v1.1 (verified against the sherpa docs).
const _voices = {'af_heart': 3, 'am_adam': 11, 'bf_emma': 21};

const _lines = [
  'It is a truth universally acknowledged that a single man in possession '
      'of a good fortune must be in want of a wife.',
  'You must allow me to tell you how ardently I admire and love you.',
  'I could easily forgive his pride if he had not mortified mine.',
];

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

/// Linear resample to 16 kHz for the ASR.
Float32List _to16k(Float32List x, int fromRate) {
  final n = (x.length * 16000 / fromRate).floor();
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    final src = i * fromRate / 16000;
    final i0 = src.floor().clamp(0, x.length - 1);
    final i1 = (i0 + 1).clamp(0, x.length - 1);
    out[i] = x[i0] + (x[i1] - x[i0]) * (src - i0);
  }
  return out;
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
    b.setInt16(44 + i * 2, (samples[i] * 32767).round().clamp(-32768, 32767),
        Endian.little);
  }
  File(path).writeAsBytesSync(b.buffer.asUint8List());
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('kokoro fp32 vs int8 comparison', () async {
    sherpa.initBindings();

    final outDir =
        Directory('${(await getTemporaryDirectory()).path}/kokoro_compare')
          ..createSync(recursive: true);
    print('OUT: ${outDir.path}');

    // ASR judge — the app's own live-matching model.
    final asr = sherpa.OnlineRecognizer(sherpa.OnlineRecognizerConfig(
      model: sherpa.OnlineModelConfig(
        transducer: sherpa.OnlineTransducerModelConfig(
          encoder: '$_eval/kroko/encoder.onnx',
          decoder: '$_eval/kroko/decoder.onnx',
          joiner: '$_eval/kroko/joiner.onnx',
        ),
        tokens: '$_eval/kroko/tokens.txt',
        numThreads: 2,
        debug: false,
      ),
      enableEndpoint: false,
    ));

    // fp32 reference audio per voice/line, for output-correlation checks.
    final reference = <String, Float32List>{};

    for (final entry in _models.entries) {
      final (dir, modelFile) = entry.value;
      final tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          kokoro: sherpa.OfflineTtsKokoroModelConfig(
            model: '$dir/$modelFile',
            voices: '$dir/voices.bin',
            tokens: '$dir/tokens.txt',
            dataDir: '$dir/espeak-ng-data',
            dictDir: '$dir/dict',
            lexicon: '$dir/lexicon-us-en.txt,$dir/lexicon-gb-en.txt',
          ),
          numThreads: 2,
          debug: false,
        ),
      ));

      var rtfSum = 0.0, matchSum = 0.0, count = 0;
      for (final v in _voices.entries) {
        for (var li = 0; li < _lines.length; li++) {
          final sw = Stopwatch()..start();
          final audio = tts.generate(
              text: _lines[li], sid: v.value, speed: 1.0);
          sw.stop();
          final dur = audio.samples.length / audio.sampleRate;
          final rtf = sw.elapsedMilliseconds / 1000 / dur;

          _writeWav('${outDir.path}/${entry.key}_${v.key}_line$li.wav',
              audio.samples, audio.sampleRate);

          // ASR round-trip.
          final stream = asr.createStream();
          stream.acceptWaveform(
              samples: _to16k(audio.samples, audio.sampleRate),
              sampleRate: 16000);
          stream.acceptWaveform(samples: Float32List(12800), sampleRate: 16000);
          while (asr.isReady(stream)) {
            asr.decode(stream);
          }
          final heard = asr.getResult(stream).text.trim();
          stream.free();
          final match = _matchRate(_lines[li], heard);

          rtfSum += rtf;
          matchSum += match;
          count++;

          // Output correlation vs the fp32 reference: near-1.0 means the
          // conversion is acoustically transparent (the standard the iOS
          // bf16 weights were held to).
          var corrNote = '';
          final refKey = '${v.key}_$li';
          if (entry.key == 'fp32-v1_0') {
            reference[refKey] = audio.samples;
          } else if (reference.containsKey(refKey)) {
            final a = reference[refKey]!, b = audio.samples;
            final n = a.length < b.length ? a.length : b.length;
            final lenRatio = a.length / b.length;
            var sab = 0.0, saa = 0.0, sbb = 0.0;
            for (var i = 0; i < n; i++) {
              sab += a[i] * b[i];
              saa += a[i] * a[i];
              sbb += b[i] * b[i];
            }
            final corr = sab / math.sqrt(saa * sbb);
            corrNote = ' corr=${corr.toStringAsFixed(4)}'
                ' lenRatio=${lenRatio.toStringAsFixed(3)}';
          }

          print('${entry.key} ${v.key} line$li: '
              'rtf=${rtf.toStringAsFixed(2)} dur=${dur.toStringAsFixed(1)}s '
              'asrMatch=${(match * 100).round()}%$corrNote');
        }
      }
      print('=== ${entry.key}: mean rtf=${(rtfSum / count).toStringAsFixed(2)} '
          'mean asrMatch=${(matchSum / count * 100).round()}% ===');
      tts.free();
    }
    asr.free();
  }, timeout: const Timeout(Duration(minutes: 30)));
}
