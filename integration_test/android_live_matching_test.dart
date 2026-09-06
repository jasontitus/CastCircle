// On-phone verification of the Android live line-matching stack
// (docs/ANDROID_LIVE_MATCHING.md):
//
//   1. the real model download path (ModelDownloadService.downloadLiveAsr)
//   2. the sherpa isolate recognizer (LiveAsrService) fed a known utterance
//   3. the native mic fan-out (AudioRecord → .m4a + onPcm + onLevel)
//
//   flutter test integration_test/android_live_matching_test.dart -d <device>
//
// The mic part needs RECORD_AUDIO: grant during the wait loop with
//   adb shell pm grant com.tiltastech.castcircle android.permission.RECORD_AUDIO
// (flutter test reinstalls the app, which clears a pre-run grant).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:castcircle/data/services/live_asr_service.dart';
import 'package:castcircle/data/services/model_download_service.dart';
import 'package:castcircle/data/services/stt_channel.dart';

const _testWavUrl =
    'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06/resolve/main/test_wavs/0.wav';
// Its transcript, decoded on macOS with the same model:
// "Ask not what your country can do for you. Ask what you can do for your country"

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test(
    'model download + recognizer + mic fan-out',
    () async {
      // Freshly-installed app + instant launch: DNS for the new UID can lag the
      // install by a few seconds. Wait for it (and report how long it took).
      final sw = Stopwatch()..start();
      var dnsOk = false;
      while (sw.elapsed < const Duration(seconds: 60)) {
        try {
          await InternetAddress.lookup('huggingface.co');
          dnsOk = true;
          break;
        } catch (_) {
          await Future.delayed(const Duration(seconds: 1));
        }
      }
      print('PROBE: DNS ready after ${sw.elapsedMilliseconds}ms (ok=$dnsOk)');
      expect(dnsOk, true, reason: 'app process never got DNS');

      // ── 1. Model download (the real user path) ──
      final dl = ModelDownloadService.instance;
      await dl.refreshDownloadedStatus();
      // The instrumented app gets flaky network on this device (DNS dead for
      // ~47 s after install, then dies again) — an artifact of the harness, not
      // the app. Try the real download path once, then fall back to waiting for
      // sideloaded files:
      //   adb push <model files> /data/local/tmp/
      //   adb shell run-as com.tiltastech.castcircle sh -c \
      //     'mkdir -p app_flutter/models/live_asr && cp /data/local/tmp/<f> ...'
      if (!await dl.isLiveAsrReady()) {
        print('PROBE: downloading live ASR model...');
        await dl.downloadLiveAsr();
      }
      if (!await dl.isLiveAsrReady()) {
        print('PROBE: download failed — waiting for sideloaded model files');
        final sw2 = Stopwatch()..start();
        while (sw2.elapsed < const Duration(minutes: 4)) {
          await dl.refreshDownloadedStatus();
          if (await dl.isLiveAsrReady()) break;
          await Future.delayed(const Duration(seconds: 3));
        }
      }
      expect(
        await dl.isLiveAsrReady(),
        true,
        reason: 'live ASR model group must verify after download',
      );
      print('PROBE: model ready');

      // ── 2. Recognizer on a known utterance ──
      final asr = LiveAsrService.instance;
      expect(await asr.ensureStarted(), true, reason: 'recognizer must start');

      // Sideloaded alongside the model files (same network caveat), else fetch.
      final dir0 = await dl.getLiveAsrModelDir();
      final side = File('$dir0/test0.wav');
      final wav = side.existsSync()
          ? await side.readAsBytes()
          : await _fetch(_testWavUrl);
      final pcm16k = _resampleTo16k(wav);
      print('PROBE: test wav ${wav.length} B → ${pcm16k.length} B @16k');

      var latest = '';
      asr.onPartial = (t) => latest = t;
      asr.startUtterance();
      // 100 ms chunks, like the live mic path.
      for (var off = 0; off < pcm16k.length; off += 3200) {
        final end = (off + 3200).clamp(0, pcm16k.length);
        asr.feedPcm(Uint8List.sublistView(pcm16k, off, end));
      }
      asr.endUtterance();
      // Partials arrive async from the isolate — phone decode of ~4 s of audio
      // takes a couple of seconds, and partials pause while the isolate chews
      // through the chunk queue. Settled = no change for a full 2 s.
      var settled = '';
      var lastChange = DateTime.now();
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (latest != settled) {
          settled = latest;
          lastChange = DateTime.now();
        } else if (latest.isNotEmpty &&
            DateTime.now().difference(lastChange) >
                const Duration(seconds: 2)) {
          break;
        }
      }
      print('PROBE: transcript="$latest"');
      final lower = latest.toLowerCase();
      expect(
        lower,
        contains('country'),
        reason: 'recognizer should decode the JFK test utterance',
      );
      expect(lower, contains('ask'));
      asr.onPartial = null;

      // ── 3. Native mic fan-out ──
      final ch = SttChannel.instance;
      // Installs the method-call handler that delivers onPcm/onLevel — the app
      // always does this at rehearsal start (SttService.init).
      await ch.initialize();
      var pcmChunks = 0;
      var pcmBytes = 0;
      var levelEvents = 0;
      ch.onPcm = (b) {
        pcmChunks++;
        pcmBytes += b.length;
      };
      ch.onLevel = (_) => levelEvents++;

      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/fanout_test.m4a';
      final recordingSessionId = DateTime.now().microsecondsSinceEpoch;
      var started = false;
      // Grant-wait: startRecording fails while RECORD_AUDIO is missing.
      for (var i = 0; i < 60; i++) {
        started = await ch.startRecording(path, sessionId: recordingSessionId);
        if (started) break;
        if (i == 0)
          print('PROBE: waiting for RECORD_AUDIO grant (adb pm grant)');
        await Future.delayed(const Duration(seconds: 1));
      }
      expect(started, true, reason: 'mic capture must start');
      await Future.delayed(const Duration(seconds: 2));
      final rec = await ch.stopRecording();
      ch.onPcm = null;
      ch.onLevel = null;

      print(
        'PROBE: fan-out chunks=$pcmChunks bytes=$pcmBytes '
        'levels=$levelEvents rec=$rec',
      );
      expect(rec, isNotNull, reason: '.m4a must be produced');
      final m4a = File(rec!['path'] as String);
      expect(m4a.existsSync(), true);
      final m4aBytes = m4a.lengthSync();
      print('PROBE: m4a size=$m4aBytes duration=${rec['durationMs']}ms');
      expect(
        m4aBytes,
        greaterThan(2000),
        reason: '2 s of AAC speech/ambience should be > 2 KB',
      );
      // ~20 chunks of 100 ms in 2 s (allow scheduling slop).
      expect(pcmChunks, greaterThan(12), reason: 'PCM fan-out must stream');
      expect(pcmBytes, greaterThan(12 * 3200));
      expect(levelEvents, greaterThan(12), reason: 'level events must stream');

      await asr.stop();
      print('PROBE: ALL OK');
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

const _fixtureFetchTimeout = Duration(seconds: 30);
const _fixtureBodyTimeout = Duration(seconds: 60);
const _maxFixtureBytes = 5 * 1024 * 1024;

Future<Uint8List> _fetch(String url) async {
  final client = HttpClient()
    ..connectionTimeout = _fixtureFetchTimeout
    ..idleTimeout = _fixtureFetchTimeout;
  try {
    final req = await client
        .getUrl(Uri.parse(url))
        .timeout(_fixtureFetchTimeout);
    final res = await req.close().timeout(_fixtureFetchTimeout);
    if (res.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Fixture request failed with HTTP ${res.statusCode}',
        uri: Uri.parse(url),
      );
    }
    if (res.contentLength > _maxFixtureBytes) {
      throw StateError(
        'Fixture is ${res.contentLength} bytes; limit is $_maxFixtureBytes',
      );
    }

    final bytes = BytesBuilder(copy: false);
    var total = 0;
    await res
        .forEach((chunk) {
          total += chunk.length;
          if (total > _maxFixtureBytes) {
            throw StateError(
              'Fixture exceeded $_maxFixtureBytes bytes while downloading',
            );
          }
          bytes.add(chunk);
        })
        .timeout(_fixtureBodyTimeout);
    return bytes.takeBytes();
  } finally {
    client.close(force: true);
  }
}

/// WAV (PCM16 mono, any rate) → 16 kHz PCM16 bytes via linear interpolation.
Uint8List _resampleTo16k(Uint8List wav) {
  if (wav.length < 12 ||
      String.fromCharCodes(wav, 0, 4) != 'RIFF' ||
      String.fromCharCodes(wav, 8, 12) != 'WAVE') {
    throw const FormatException('Fixture is not a RIFF/WAVE file');
  }

  final bd = ByteData.sublistView(wav);
  final riffEnd = bd.getUint32(4, Endian.little) + 8;
  if (riffEnd > wav.length) {
    throw FormatException(
      'WAV declares $riffEnd bytes but only ${wav.length} are present',
    );
  }

  var offset = 12;
  int? rate;
  var dataStart = -1;
  var dataLen = 0;
  while (offset + 8 <= riffEnd) {
    final id = String.fromCharCodes(wav, offset, offset + 4);
    final size = bd.getUint32(offset + 4, Endian.little);
    final payloadStart = offset + 8;
    final payloadEnd = payloadStart + size;
    final next = payloadEnd + (size & 1);
    if (payloadEnd > riffEnd || next > wav.length) {
      throw FormatException('Truncated WAV $id chunk ($size bytes)');
    }

    if (id == 'fmt ') {
      if (size < 16) {
        throw const FormatException('WAV fmt chunk is shorter than 16 bytes');
      }
      final format = bd.getUint16(payloadStart, Endian.little);
      final channels = bd.getUint16(payloadStart + 2, Endian.little);
      final sampleRate = bd.getUint32(payloadStart + 4, Endian.little);
      final blockAlign = bd.getUint16(payloadStart + 12, Endian.little);
      final bitsPerSample = bd.getUint16(payloadStart + 14, Endian.little);
      if (format != 1 ||
          channels != 1 ||
          sampleRate <= 0 ||
          blockAlign != 2 ||
          bitsPerSample != 16) {
        throw FormatException(
          'Expected mono PCM16 WAV; got format=$format channels=$channels '
          'rate=$sampleRate blockAlign=$blockAlign bits=$bitsPerSample',
        );
      }
      rate = sampleRate;
    } else if (id == 'data' && dataStart < 0) {
      dataStart = payloadStart;
      dataLen = size;
    }
    offset = next;
  }

  if (rate == null) {
    throw const FormatException('WAV has no valid fmt chunk');
  }
  if (dataStart < 0 || dataLen == 0 || dataLen.isOdd) {
    throw const FormatException('WAV has no non-empty PCM16 data chunk');
  }

  final n = dataLen ~/ 2;
  final outN = (n * 16000 / rate).floor();
  final out = Uint8List(outN * 2);
  final outBd = ByteData.sublistView(out);
  for (var s = 0; s < outN; s++) {
    final src = s * rate / 16000;
    final i0 = src.floor().clamp(0, n - 1);
    final i1 = (i0 + 1).clamp(0, n - 1);
    final frac = src - i0;
    final v0 = bd.getInt16(dataStart + i0 * 2, Endian.little);
    final v1 = bd.getInt16(dataStart + i1 * 2, Endian.little);
    outBd.setInt16(s * 2, (v0 + (v1 - v0) * frac).round(), Endian.little);
  }
  return out;
}
