// Validates the exact Kokoro pack CastCircle ships for Android (fp16 weights,
// no zh dict/lexicons/fsts): synthesize with US/UK male/female voices and
// ASR-verify intelligibility. voices.bin must stay COMPLETE (53 speakers) —
// sherpa checks it against the model metadata and aborts on a truncated file.
//
//   flutter test integration_test/kokoro_pack_smoke_macos_test.dart -d macos
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Repo root for fixture/model staging paths. Relative default works when
/// tests run from the checkout root; override with
/// --dart-define=CASTCIRCLE_REPO=/path for other harnesses.
const _ccRepo = String.fromEnvironment('CASTCIRCLE_REPO', defaultValue: '.');

const _eval = '$_ccRepo/.asr-eval';
const _pack = '$_eval/kokoro-en-fp16-pack';

const _line =
    'It is a truth universally acknowledged that a single man in '
    'possession of a good fortune must be in want of a wife.';

// App voices across the accent/gender grid.
const _voices = {'af_heart': 3, 'am_adam': 11, 'bf_emma': 21, 'bm_george': 26};

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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test(
    'shipped kokoro pack synthesizes intelligibly',
    () {
      sherpa.initBindings();
      final tts = sherpa.OfflineTts(
        sherpa.OfflineTtsConfig(
          model: sherpa.OfflineTtsModelConfig(
            kokoro: sherpa.OfflineTtsKokoroModelConfig(
              model: '$_pack/model.fp16.onnx',
              voices: '$_pack/voices.bin',
              tokens: '$_pack/tokens.txt',
              dataDir: '$_pack/espeak-ng-data',
              lexicon: '$_pack/lexicon-us-en.txt,$_pack/lexicon-gb-en.txt',
              // No dictDir: jieba is zh-only and excluded from the pack.
            ),
            numThreads: 2,
            debug: false,
          ),
        ),
      );
      final asr = sherpa.OnlineRecognizer(
        sherpa.OnlineRecognizerConfig(
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
        ),
      );

      for (final v in _voices.entries) {
        final audio = tts.generate(text: _line, sid: v.value, speed: 1.0);
        expect(
          audio.samples.length,
          greaterThan(16000),
          reason: '${v.key} produced almost no audio',
        );
        final stream = asr.createStream();
        stream.acceptWaveform(
          samples: _to16k(audio.samples, audio.sampleRate),
          sampleRate: 16000,
        );
        stream.acceptWaveform(samples: Float32List(12800), sampleRate: 16000);
        while (asr.isReady(stream)) {
          asr.decode(stream);
        }
        final heard = asr.getResult(stream).text.trim();
        stream.free();
        final match = _matchRate(_line, heard);
        print(
          '${v.key}: match=${(match * 100).round()}% '
          'dur=${(audio.samples.length / audio.sampleRate).toStringAsFixed(1)}s',
        );
        expect(match, greaterThan(0.8), reason: '${v.key} heard: "$heard"');
      }
      tts.free();
      asr.free();
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
