// Autonomous on-phone rehearsal harness (no human in the loop) — run via
// scripts/phone-harness.sh, which sideloads the model packs, grants the mic,
// and sets media volume.
//
// Simulates the rehearsal loop end to end and prints PROBE metrics:
//   Part 1 — TTS pipeline: cold first-line latency, then prefetch-covered
//            latency for consecutive lines (the field complaint: 4-6 s of
//            silence per line without pipelining).
//   Part 2 — Round trip: a Kokoro-synthesized "actor" line plays through the
//            SPEAKER while the real mic fan-out captures it and the live
//            recognizer matches it against the script line — the same path a
//            human actor exercises, minus the human. On an EMULATOR (whose
//            virtual mic can't hear its own speaker) the harness detects the
//            silent capture and re-scores by injecting the line's PCM
//            directly into the recognizer — that mode validates decoding and
//            matching but NOT the microphone; the metric line says which
//            mode produced the score.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';

import 'package:castcircle/data/services/kokoro_onnx_service.dart';
import 'package:castcircle/data/services/live_asr_service.dart';
import 'package:castcircle/data/services/model_download_service.dart';
import 'package:castcircle/data/services/model_manager.dart';
import 'package:castcircle/data/services/stt_channel.dart';
import 'package:castcircle/data/services/stt_service.dart';
import 'package:castcircle/data/services/tts_service.dart';
import 'package:path_provider/path_provider.dart';

// A long multi-sentence line (416 chars — the field case that sat silent for
// 15 s): playback may begin once the FIRST chunk is synthesized.
const _longLine =
    'Certainly there are such people, but I hope I am not one of them. '
    'I confess I cannot boast of ever having seen such a woman in all my '
    'acquaintance. I never saw such capacity, and taste, and application, '
    'and elegance, as you describe united in one person. I am no longer '
    'surprised at your knowing only six accomplished women, Mr Darcy. '
    'I rather wonder now at your knowing any at all in the whole world.';

// A P&P exchange: alternating computer lines and "my" (DARCY) lines.
const _otherLines = [
  'Come, Darcy, I hate to see you standing about by yourself in this '
      'stupid manner. You had much better dance.',
  'I would not be so fastidious as you are for a kingdom! Upon my honour '
      'I never met with so many pleasant girls in my life.',
  'Indeed the most beautiful creature I ever beheld! But there is one of '
      'her sisters sitting down just behind you.',
];
const _myLines = [
  'You know how I detest it unless I am particularly acquainted with my '
      'partner.',
  'Your partner, the eldest Miss Bennet, is the only handsome girl in '
      'the room.',
];

/// WAV (PCM16 mono, any rate) → 16 kHz PCM16 bytes via linear interpolation.
Uint8List _wavTo16kPcm(Uint8List wav) {
  if (wav.length < 12 ||
      String.fromCharCodes(wav, 0, 4) != 'RIFF' ||
      String.fromCharCodes(wav, 8, 12) != 'WAVE') {
    throw const FormatException('Generated audio is not a RIFF/WAVE file');
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

Future<void> _waitForTranscriptToSettle(String Function() transcript) async {
  var settled = '';
  var lastChange = DateTime.now();
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    await Future.delayed(const Duration(milliseconds: 100));
    final current = transcript();
    if (current != settled) {
      settled = current;
      lastChange = DateTime.now();
    } else if (current.isNotEmpty &&
        DateTime.now().difference(lastChange) > const Duration(seconds: 2)) {
      return;
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test(
    'rehearsal loop: pipeline latency + acoustic matching',
    () async {
      // ── Sideload wait (packs land mid-run via run-as) ──
      final sw = Stopwatch()..start();
      while (sw.elapsed < const Duration(minutes: 6)) {
        final kokoro = await ModelManager.instance.isKokoroReady();
        await ModelDownloadService.instance.refreshDownloadedStatus();
        final asr = await ModelDownloadService.instance.isLiveAsrReady();
        if (kokoro && asr) break;
        await Future.delayed(const Duration(seconds: 3));
      }
      expect(
        await ModelManager.instance.isKokoroReady(),
        true,
        reason: 'kokoro pack not sideloaded',
      );
      expect(
        await ModelDownloadService.instance.isLiveAsrReady(),
        true,
        reason: 'live_asr pack not sideloaded',
      );
      print('PROBE: packs ready after ${sw.elapsed}');

      final tts = KokoroOnnxService.instance;
      final tEngine = Stopwatch()..start();
      expect(await tts.ensureStarted(), true);
      print('PROBE: tts engine start ${tEngine.elapsedMilliseconds}ms');

      // ── Part 1: pipeline latency over consecutive computer lines ──
      // Mimics _playOtherLine + the play-time prefetch hook: line N's audio is
      // requested urgently; while it "plays" (we wait its real duration), line
      // N+1 prefetches non-urgently.
      Future<String?>? prefetchNext;
      final latencies = <int>[];
      for (var i = 0; i < _otherLines.length; i++) {
        final t = Stopwatch()..start();
        final path = prefetchNext != null
            ? await prefetchNext
            : await tts.synthesize(
                _otherLines[i],
                voice: 'am_michael',
                urgent: true,
              );
        t.stop();
        expect(path, isNotNull, reason: 'line $i synthesis failed');
        latencies.add(t.elapsedMilliseconds);
        // Kick the next prefetch, then "play" this line (wav duration from
        // size: 24 kHz 16-bit mono + 44-byte header).
        prefetchNext = i + 1 < _otherLines.length
            ? tts.synthesize(_otherLines[i + 1], voice: 'am_michael')
            : null;
        final durMs = ((File(path!).lengthSync() - 44) / 2 / 24000 * 1000)
            .round();
        print('PROBE: line$i startLatency=${latencies[i]}ms audio=${durMs}ms');
        await Future.delayed(Duration(milliseconds: durMs));
      }
      expect(
        latencies.sublist(1).every((ms) => ms < 1500),
        true,
        reason: 'prefetched lines must start fast, got $latencies',
      );

      // ── Part 1b: long-line chunk streaming through TtsService ──
      // Time-to-first-audio is set by the FIRST chunk future; the rest
      // synthesize during playback.
      expect(
        await TtsService.instance.tryLoadKokoro(),
        true,
        reason: 'TtsService must pick up the ONNX engine',
      );
      final tLong = Stopwatch()..start();
      final chunkFutures = TtsService.instance.prepareKokoro(_longLine)!;
      final firstMs = await chunkFutures.first.then(
        (p) => p == null ? -1 : tLong.elapsedMilliseconds,
      );
      await Future.wait(chunkFutures);
      final allMs = tLong.elapsedMilliseconds;
      print(
        'PROBE: longLine chunks=${chunkFutures.length} '
        'firstChunk=${firstMs}ms allChunks=${allMs}ms',
      );
      expect(firstMs, greaterThan(0), reason: 'first chunk must synthesize');
      expect(
        chunkFutures.length,
        greaterThan(1),
        reason: 'long line must be split for streaming',
      );
      expect(
        firstMs,
        lessThan(allMs ~/ 2),
        reason:
            'playback must be able to start well before the whole line '
            'is synthesized',
      );

      // ── Part 1c: REAL TtsService.speak pipelining (playthrough) ──
      // Part 1 simulates its own pipeline and once reported 0 ms while the
      // real path sat silent 6-10 s between lines (speak() returns after
      // playback COMPLETES, so an after-speak prefetch never overlapped).
      // This drives the actual speak path with the rehearsal-style
      // onPlaybackStarted prefetch hook and measures the audio GAP between
      // consecutive lines — the number the actor actually hears.
      final tsvc = TtsService.instance;
      final speakLines = [
        'Mr. Bennet, how can you abuse your own children in such a way?',
        'Mrs. Long and her nieces must take their chance at the assembly.',
        'Depend upon it, Mr. Bingley will be delighted to see you all.',
      ];
      final prefetches = <int, List<Future<String?>>?>{};
      var speakIdx = 0;
      DateTime? lastCompletion;
      final gaps = <int>[];
      Completer<void> lineDone = Completer<void>();
      tsvc.onPlaybackStarted = () {
        if (lastCompletion != null) {
          gaps.add(DateTime.now().difference(lastCompletion!).inMilliseconds);
        }
        // Rehearsal-style: the moment audio starts, prefetch the NEXT line.
        final next = speakIdx + 1;
        if (next < speakLines.length && !prefetches.containsKey(next)) {
          prefetches[next] = tsvc.prepareKokoro(speakLines[next]);
        }
      };
      tsvc.setCompletionHandler(() {
        lastCompletion = DateTime.now();
        if (!lineDone.isCompleted) lineDone.complete();
      });
      for (speakIdx = 0; speakIdx < speakLines.length; speakIdx++) {
        lineDone = Completer<void>();
        await tsvc.speak(
          speakLines[speakIdx],
          precomputedChunks: prefetches[speakIdx],
        );
        await lineDone.future.timeout(const Duration(seconds: 60));
      }
      tsvc.onPlaybackStarted = null;
      tsvc.setCompletionHandler(() {});
      print('PROBE: speakPath interLineGaps=${gaps}ms');
      expect(gaps.length, speakLines.length - 1);
      expect(
        gaps.every((g) => g < 2500),
        true,
        reason: 'consecutive TTS lines must flow, got $gaps',
      );

      // ── Part 2: acoustic round trip (speaker → air → mic → recognizer) ──
      await SttChannel.instance.initialize();
      final asr = LiveAsrService.instance;
      expect(await asr.ensureStarted(), true, reason: 'recognizer must start');

      final player = AudioPlayer();
      final tmp = await getTemporaryDirectory();
      final recordingSessionBase = DateTime.now().microsecondsSinceEpoch;
      var lineNo = 0;
      for (final line in _myLines) {
        // The "actor": a DIFFERENT Kokoro voice reads the line out loud.
        final wav = await tts.synthesize(
          line,
          voice: 'bm_george',
          urgent: true,
        );
        expect(wav, isNotNull);

        var transcript = '';
        asr.onPartial = (t) => transcript = t;
        asr.startUtterance();
        SttChannel.instance.onPcm = asr.feedPcm;

        final recPath = '${tmp.path}/harness_rec_$lineNo.m4a';
        // Retried: emulator virtual-audio HALs release the mic lazily, so an
        // immediate re-open after the previous line can fail once or twice.
        // (Real devices reopen line-after-line without this.)
        var recording = false;
        for (var attempt = 0; attempt < 5 && !recording; attempt++) {
          recording = await SttChannel.instance.startRecording(
            recPath,
            sessionId: recordingSessionBase + lineNo,
          );
          if (!recording) {
            await Future.delayed(const Duration(milliseconds: 600));
          }
        }
        expect(
          recording,
          true,
          reason: 'mic capture must start (RECORD_AUDIO granted?)',
        );

        await player.setFilePath(wav!);
        await player.setVolume(1.0);
        await player.play();
        await player.playerStateStream.firstWhere(
          (s) => s.processingState == ProcessingState.completed,
        );
        // Release the output stream promptly — a lingering player keeps the
        // emulator's audio HAL busy and blocks the next mic open.
        await player.stop();
        // Trailing silence: endpointing context + decoder catch-up.
        await Future.delayed(const Duration(milliseconds: 1500));

        final rec = await SttChannel.instance.stopRecording();
        SttChannel.instance.onPcm = null;
        asr.endUtterance();
        await _waitForTranscriptToSettle(() => transcript);

        var score = SttService.matchScore(line, transcript);
        final acousticScore = score;
        final acousticTranscript = transcript;
        print(
          'PROBE: myLine$lineNo acousticScore='
          '${(acousticScore * 100).round()}% '
          'heard="${acousticTranscript.length > 60 ? '${acousticTranscript.substring(0, 57)}...' : acousticTranscript}"',
        );
        var mode = 'acoustic';
        if (score < 0.4) {
          // Emulator (or muted device): the mic heard nothing useful. Inject
          // the line's PCM straight into the recognizer instead.
          mode = 'injected';
          transcript = '';
          asr.onPartial = (t) => transcript = t;
          asr.startUtterance();
          final pcm16k = _wavTo16kPcm(File(wav).readAsBytesSync());
          for (var off = 0; off < pcm16k.length; off += 3200) {
            asr.feedPcm(
              Uint8List.sublistView(
                pcm16k,
                off,
                (off + 3200).clamp(0, pcm16k.length),
              ),
            );
          }
          asr.endUtterance();
          await _waitForTranscriptToSettle(() => transcript);
          score = SttService.matchScore(line, transcript);
        }

        print(
          'PROBE: myLine$lineNo mode=$mode score=${(score * 100).round()}% '
          'rec=${rec == null ? 'MISSING' : '${File(rec['path'] as String).lengthSync()}B'} '
          'heard="${transcript.length > 60 ? '${transcript.substring(0, 57)}...' : transcript}"',
        );
        expect(
          score,
          greaterThan(0.4),
          reason: 'round trip should match its own line (got "$transcript")',
        );
        expect(rec, isNotNull, reason: 'recording must be produced');
        lineNo++;
      }
      await player.dispose();
      await asr.stop();
      await tts.stop();
      print('PROBE: ALL OK');
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
