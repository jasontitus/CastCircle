// One-off: print the kroko bundled test wav's transcript so the on-phone
// verification test can assert against known words.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

const _dir = '/Users/jasontitus/experiments/CastCircle/.asr-eval/kroko';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('transcribe kroko test wav', () {
    sherpa.initBindings();
    final recognizer = sherpa.OnlineRecognizer(sherpa.OnlineRecognizerConfig(
      model: sherpa.OnlineModelConfig(
        transducer: sherpa.OnlineTransducerModelConfig(
          encoder: '$_dir/encoder.onnx',
          decoder: '$_dir/decoder.onnx',
          joiner: '$_dir/joiner.onnx',
        ),
        tokens: '$_dir/tokens.txt',
        numThreads: 2,
        debug: false,
      ),
      enableEndpoint: false,
    ));
    final bytes = File('$_dir/test_wavs/0.wav').readAsBytesSync();
    final bd = ByteData.sublistView(bytes);
    // Assume canonical 44-byte header (sherpa test wavs are plain PCM16 mono).
    final rate = bd.getUint32(24, Endian.little);
    final n = (bytes.length - 44) ~/ 2;
    final samples = Float32List(n);
    for (var i = 0; i < n; i++) {
      samples[i] = bd.getInt16(44 + i * 2, Endian.little) / 32768.0;
    }
    final stream = recognizer.createStream();
    stream.acceptWaveform(samples: samples, sampleRate: rate);
    stream.acceptWaveform(samples: Float32List(12800), sampleRate: rate);
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }
    print('rate=$rate transcript="${recognizer.getResult(stream).text}"');
    stream.free();
    recognizer.free();
  });
}
