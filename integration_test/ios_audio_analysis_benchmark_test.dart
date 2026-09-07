// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:castcircle/data/services/audio_level_service.dart';
import 'package:castcircle/data/services/debug_log_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test(
    'audio analysis latency and peak footprint scale with duration',
    () async {
      final temp = await getTemporaryDirectory();
      for (final seconds in [30, 300]) {
        final file = File('${temp.path}/audio_analysis_${seconds}s.wav');
        await _writeStereoWav(file, seconds: seconds);
        AudioLevelService.instance.invalidate(file.path);

        final before = await DebugLogService.instance.getMemoryUsage();
        var peakMb = before['physicalFootprintMB'] ?? 0;
        var sampling = false;
        final sampler = Timer.periodic(const Duration(milliseconds: 100), (
          _,
        ) async {
          if (sampling) return;
          sampling = true;
          final memory = await DebugLogService.instance.getMemoryUsage();
          final current = memory['physicalFootprintMB'] ?? 0;
          if (current > peakMb) peakMb = current;
          sampling = false;
        });

        final stopwatch = Stopwatch()..start();
        final volume = await AudioLevelService.instance.volumeFor(file.path);
        stopwatch.stop();
        sampler.cancel();
        final after = await DebugLogService.instance.getMemoryUsage();
        final endMb = after['physicalFootprintMB'] ?? 0;
        if (endMb > peakMb) peakMb = endMb;

        print(
          'PROBE: iosAudioAnalysis seconds=$seconds '
          'elapsedMs=${stopwatch.elapsedMilliseconds} '
          'startMb=${before['physicalFootprintMB'] ?? 0} '
          'peakMb=$peakMb endMb=$endMb volume=$volume',
        );
        expect(volume, inInclusiveRange(0.3, 1.0));
        await file.delete();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<void> _writeStereoWav(File file, {required int seconds}) async {
  const sampleRate = 48000;
  const channels = 2;
  const bytesPerSample = 2;
  final dataBytes = seconds * sampleRate * channels * bytesPerSample;
  final header = Uint8List(44);
  final view = ByteData.sublistView(header);

  void ascii(int offset, String value) {
    header.setRange(offset, offset + value.length, value.codeUnits);
  }

  ascii(0, 'RIFF');
  view.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little);
  view.setUint16(22, channels, Endian.little);
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, sampleRate * channels * bytesPerSample, Endian.little);
  view.setUint16(32, channels * bytesPerSample, Endian.little);
  view.setUint16(34, bytesPerSample * 8, Endian.little);
  ascii(36, 'data');
  view.setUint32(40, dataBytes, Endian.little);

  final oneSecond = Uint8List(sampleRate * channels * bytesPerSample);
  final samples = ByteData.sublistView(oneSecond);
  for (var frame = 0; frame < sampleRate; frame++) {
    final value = frame.isEven ? 12000 : -12000;
    samples.setInt16(frame * 4, value, Endian.little);
    samples.setInt16(frame * 4 + 2, value, Endian.little);
  }

  final sink = file.openWrite();
  sink.add(header);
  for (var second = 0; second < seconds; second++) {
    sink.add(oneSecond);
  }
  await sink.close();
}
