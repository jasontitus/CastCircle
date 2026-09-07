// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:castcircle/data/services/model_download_service.dart';

const _channel = MethodChannel('com.lineguide/kokoro_mlx');

Future<void> _ensureModel() async {
  final status = await _channel.invokeMapMethod<String, dynamic>(
    'getModelStatus',
  );
  if (status?['downloaded'] == true) return;

  final downloader = ModelDownloadService.instance;
  final timer = Stopwatch()..start();
  for (final model in ModelDownloadService.availableModels) {
    if (model.subdir == 'kokoro_mlx') await downloader.download(model);
  }
  while (timer.elapsed < const Duration(minutes: 10)) {
    if (await downloader.isKokoroReady()) {
      print('PROBE: iosKokoro modelDownloadMs=${timer.elapsedMilliseconds}');
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  fail('Kokoro MLX model download did not finish');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Kokoro MLX cold and queued synthesis latency',
    () async {
      expect(Platform.isIOS, true, reason: 'This benchmark requires iOS');

      await _ensureModel();

      final loadTimer = Stopwatch()..start();
      expect(await _channel.invokeMethod<bool>('loadModel'), true);
      loadTimer.stop();

      final cacheDirectory = await getApplicationCacheDirectory();
      final audioCache = Directory('${cacheDirectory.path}/kokoro_tts');
      if (await audioCache.exists()) {
        await audioCache.delete(recursive: true);
      }

      print('PROBE: iosKokoro loadMs=${loadTimer.elapsedMilliseconds}');

      final cold = await _synthesize(
        'You must allow me to tell you how ardently I admire and love you.',
        requestGroup: 'benchmark-cold',
      );
      expect(cold.path, isNotNull, reason: cold.error);
      print('PROBE: iosKokoro coldMs=${cold.elapsedMs} bytes=${cold.bytes}');

      final warm = await _synthesize(
        'There is no charm equal to tenderness of heart.',
        requestGroup: 'benchmark-warm',
      );
      expect(warm.path, isNotNull, reason: warm.error);
      print('PROBE: iosKokoro warmMs=${warm.elapsedMs} bytes=${warm.bytes}');

      final queuedTimer = Stopwatch()..start();
      final queued = await Future.wait([
        _synthesize(
          'The first prefetched line should remain ready for its actor.',
          requestGroup: 'benchmark-queued',
        ),
        _synthesize(
          'The second prefetched line should follow immediately behind it.',
          requestGroup: 'benchmark-queued',
        ),
        _synthesize(
          'The third prefetched line must not invalidate either sibling.',
          requestGroup: 'benchmark-queued',
        ),
      ]);
      queuedTimer.stop();
      final completed = queued.where((result) => result.path != null).length;
      final errors = queued
          .where((result) => result.error != null)
          .map((result) => result.error)
          .join('|');
      print(
        'PROBE: iosKokoro queuedTotalMs=${queuedTimer.elapsedMilliseconds} '
        'completed=$completed/3 individualMs='
        '${queued.map((result) => result.elapsedMs).join(',')} errors=$errors',
      );
      expect(
        completed,
        3,
        reason: 'Every sibling prefetch must complete; errors=$errors',
      );
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

Future<_SynthesisResult> _synthesize(
  String text, {
  required String requestGroup,
}) async {
  final timer = Stopwatch()..start();
  try {
    final path = await _channel.invokeMethod<String>('synthesize', {
      'text': text,
      'voice': 'af_heart',
      'speed': 1.0,
      'requestGroup': requestGroup,
      'urgent': false,
    });
    timer.stop();
    final bytes = path == null ? 0 : await File(path).length();
    return _SynthesisResult(timer.elapsedMilliseconds, path, bytes, null);
  } on PlatformException catch (error) {
    timer.stop();
    return _SynthesisResult(
      timer.elapsedMilliseconds,
      null,
      0,
      '${error.code}:${error.message}',
    );
  }
}

class _SynthesisResult {
  const _SynthesisResult(this.elapsedMs, this.path, this.bytes, this.error);

  final int elapsedMs;
  final String? path;
  final int bytes;
  final String? error;
}
