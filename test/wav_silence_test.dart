import 'dart:io';
import 'dart:typed_data';

import 'package:castcircle/data/services/wav_silence.dart';
import 'package:flutter_test/flutter_test.dart';

/// Byte-level surgery on audio files: if this is wrong the app plays noise,
/// which is worse than the clipped syllable it works around. So the padded
/// output is parsed back and checked field by field, and every malformed
/// input must fall back to the original file rather than produce something.
Uint8List wav({
  int sampleRate = 24000,
  int channels = 1,
  int bits = 16,
  int frames = 1000,
  String dataId = 'data',
}) {
  final frameSize = channels * (bits ~/ 8);
  final dataLen = frames * frameSize;
  final bytes = BytesBuilder();
  final header = ByteData(44);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      header.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + dataLen, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, sampleRate * frameSize, Endian.little); // byte rate
  header.setUint16(32, frameSize, Endian.little);
  header.setUint16(34, bits, Endian.little);
  ascii(36, dataId);
  header.setUint32(40, dataLen, Endian.little);
  bytes.add(header.buffer.asUint8List());
  // Non-zero audio, so padding is distinguishable from content.
  bytes.add(Uint8List.fromList(List.generate(dataLen, (i) => (i % 251) + 1)));
  return bytes.toBytes();
}

({int riffSize, int dataSize, int dataStart}) parse(Uint8List b) {
  final d = ByteData.sublistView(b);
  return (
    riffSize: d.getUint32(4, Endian.little),
    dataSize: d.getUint32(40, Endian.little),
    dataStart: 44,
  );
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('wavpad'));
  tearDown(() async => dir.delete(recursive: true));

  Future<String> write(String name, Uint8List bytes) async {
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes);
    return f.path;
  }

  test('prepends exactly the requested silence', () async {
    const rate = 24000, frames = 1000;
    final src = await write('in.wav', wav(sampleRate: rate, frames: frames));
    final out = await WavSilence.prepend(src, '${dir.path}/out.wav',
        silence: const Duration(milliseconds: 350));

    expect(out, '${dir.path}/out.wav');
    final bytes = await File(out).readAsBytes();
    final info = parse(bytes);

    // 350ms of 24kHz 16-bit mono = 8400 frames = 16800 bytes.
    const padBytes = 350 * rate * 2 ~/ 1000;
    expect(info.dataSize, frames * 2 + padBytes);
    expect(info.riffSize, bytes.length - 8, reason: 'RIFF size must match');
    expect(bytes.length, 44 + frames * 2 + padBytes);
  });

  test('the padding is silent and the audio survives intact', () async {
    final original = wav(frames: 500);
    final src = await write('in.wav', original);
    final out = await WavSilence.prepend(src, '${dir.path}/out.wav',
        silence: const Duration(milliseconds: 100));

    final bytes = await File(out).readAsBytes();
    const padBytes = 100 * 24000 * 2 ~/ 1000;
    expect(bytes.sublist(44, 44 + padBytes).every((b) => b == 0), isTrue,
        reason: 'the pad must be pure silence');
    expect(bytes.sublist(44 + padBytes), original.sublist(44),
        reason: 'the original audio must be byte-identical after the pad');
  });

  test('keeps frames aligned for stereo', () async {
    // A pad that is not a whole number of frames would shift every sample
    // after it and turn the audio into noise.
    final src = await write(
        'in.wav', wav(channels: 2, sampleRate: 44100, frames: 100));
    final out = await WavSilence.prepend(src, '${dir.path}/out.wav',
        silence: const Duration(milliseconds: 7));
    final bytes = await File(out).readAsBytes();
    final pad = parse(bytes).dataSize - 100 * 4;
    expect(pad % 4, 0, reason: '4 bytes per frame at 16-bit stereo');
  });

  group('falls back to the original file', () {
    test('when the input is not a WAV', () async {
      final src = await write('x.bin', Uint8List.fromList(List.filled(200, 7)));
      expect(await WavSilence.prepend(src, '${dir.path}/out.wav'), src);
    });

    test('when the input is too short to be a WAV', () async {
      final src = await write('tiny.wav', Uint8List.fromList([1, 2, 3]));
      expect(await WavSilence.prepend(src, '${dir.path}/out.wav'), src);
    });

    test('when the input is missing', () async {
      expect(await WavSilence.prepend('${dir.path}/nope.wav',
          '${dir.path}/out.wav'), '${dir.path}/nope.wav');
    });

    test('when the format is not PCM', () async {
      final bytes = wav(frames: 100);
      ByteData.sublistView(bytes).setUint16(20, 3, Endian.little); // float
      final src = await write('float.wav', bytes);
      expect(await WavSilence.prepend(src, '${dir.path}/out.wav'), src);
    });

    test('when there is no data chunk', () async {
      final src = await write('nodata.wav', wav(frames: 10, dataId: 'LIST'));
      expect(await WavSilence.prepend(src, '${dir.path}/out.wav'), src);
    });
  });

  test('a header claiming more data than the file holds is clamped', () async {
    // A truncated download or an interrupted write: pad it, but never read
    // past the end of the file.
    final bytes = wav(frames: 100);
    ByteData.sublistView(bytes).setUint32(40, 999999, Endian.little);
    final src = await write('lying.wav', bytes);
    final out = await WavSilence.prepend(src, '${dir.path}/out.wav',
        silence: const Duration(milliseconds: 10));
    final result = await File(out).readAsBytes();
    expect(result.length, 44 + 200 + (10 * 24000 * 2 ~/ 1000));
  });
}
