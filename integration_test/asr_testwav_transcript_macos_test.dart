// One-off: print the kroko bundled test wav's transcript so the on-phone
// verification test can assert against known words.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Repo root for fixture/model staging paths. Relative default works when
/// tests run from the checkout root; override with
/// --dart-define=CASTCIRCLE_REPO=/path for other harnesses.
const _ccRepo = String.fromEnvironment('CASTCIRCLE_REPO', defaultValue: '.');

const _dir = '$_ccRepo/.asr-eval/kroko';

({Float32List samples, int sampleRate}) _readPcm16MonoWav(Uint8List bytes) {
  if (bytes.length < 12 ||
      String.fromCharCodes(bytes, 0, 4) != 'RIFF' ||
      String.fromCharCodes(bytes, 8, 12) != 'WAVE') {
    throw const FormatException('Fixture is not a RIFF/WAVE file');
  }

  final bd = ByteData.sublistView(bytes);
  final riffEnd = bd.getUint32(4, Endian.little) + 8;
  if (riffEnd > bytes.length) {
    throw FormatException(
      'WAV declares $riffEnd bytes but only ${bytes.length} are present',
    );
  }

  var offset = 12;
  int? sampleRate;
  var dataStart = -1;
  var dataLength = 0;
  while (offset + 8 <= riffEnd) {
    final id = String.fromCharCodes(bytes, offset, offset + 4);
    final size = bd.getUint32(offset + 4, Endian.little);
    final payloadStart = offset + 8;
    final payloadEnd = payloadStart + size;
    final next = payloadEnd + (size & 1);
    if (payloadEnd > riffEnd || next > bytes.length) {
      throw FormatException('Truncated WAV $id chunk ($size bytes)');
    }

    if (id == 'fmt ') {
      if (size < 16) {
        throw const FormatException('WAV fmt chunk is shorter than 16 bytes');
      }
      final format = bd.getUint16(payloadStart, Endian.little);
      final channels = bd.getUint16(payloadStart + 2, Endian.little);
      final rate = bd.getUint32(payloadStart + 4, Endian.little);
      final blockAlign = bd.getUint16(payloadStart + 12, Endian.little);
      final bitsPerSample = bd.getUint16(payloadStart + 14, Endian.little);
      if (format != 1 ||
          channels != 1 ||
          rate <= 0 ||
          blockAlign != 2 ||
          bitsPerSample != 16) {
        throw FormatException(
          'Expected mono PCM16 WAV; got format=$format channels=$channels '
          'rate=$rate blockAlign=$blockAlign bits=$bitsPerSample',
        );
      }
      sampleRate = rate;
    } else if (id == 'data' && dataStart < 0) {
      dataStart = payloadStart;
      dataLength = size;
    }
    offset = next;
  }

  if (sampleRate == null) {
    throw const FormatException('WAV has no valid fmt chunk');
  }
  if (dataStart < 0 || dataLength == 0 || dataLength.isOdd) {
    throw const FormatException('WAV has no non-empty PCM16 data chunk');
  }

  final samples = Float32List(dataLength ~/ 2);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = bd.getInt16(dataStart + i * 2, Endian.little) / 32768.0;
  }
  return (samples: samples, sampleRate: sampleRate);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('transcribe kroko test wav', () {
    sherpa.initBindings();
    final recognizer = sherpa.OnlineRecognizer(
      sherpa.OnlineRecognizerConfig(
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
      ),
    );
    final wav = _readPcm16MonoWav(
      File('$_dir/test_wavs/0.wav').readAsBytesSync(),
    );
    final stream = recognizer.createStream();
    stream.acceptWaveform(samples: wav.samples, sampleRate: wav.sampleRate);
    stream.acceptWaveform(
      samples: Float32List(12800),
      sampleRate: wav.sampleRate,
    );
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }
    final transcript = recognizer.getResult(stream).text.trim();
    print('rate=${wav.sampleRate} transcript="$transcript"');
    expect(
      transcript,
      isNotEmpty,
      reason: 'known Kroko fixture must produce a transcript',
    );
    stream.free();
    recognizer.free();
  });
}
