// On-phone Kokoro synthesis speed: fp32 v1.0 vs fp16 v1.0.
// The fp16 conversion preserves fp32 quality while cutting pack size; this
// probe guards both packs against unusably slow Android ARM regressions.
//
// Model dirs are sideloaded (see android_live_matching_test.dart recipe) to
//   <documents>/models/kokoro_eval/{fp32,fp16}/
import 'dart:convert';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

const _line =
    'You must allow me to tell you how ardently I admire and love you.';

const _maxAcceptableRtf = 1.5;

const _espeakTreeFiles = 355;
const _espeakTreeSha256 =
    'eb8b19ec00b564ee1725efe626775ae20deef533a43be16d8f9310077daf5cb3';
const _dictTreeFiles = 11;
const _dictTreeSha256 =
    'fa96c0f0392185c86be071f34862462a2babd308ef36e5e2f5f60e8cfc2b3e74';
const _fp32Ready =
    'castcircle-kokoro-eval-fp32-v1_0:'
    'c436dc6a842b62aba06af67e40bafcfb9c60ac3af895358f1974ad9a7f7c026b:'
    'eb8b19ec00b564ee1725efe626775ae20deef533a43be16d8f9310077daf5cb3:'
    'fa96c0f0392185c86be071f34862462a2babd308ef36e5e2f5f60e8cfc2b3e74';
const _fp16Ready =
    'castcircle-kokoro-eval-fp16-v1_0:'
    '7983eb4baa16c3b9a81832afd570e5bec06da12538f89b58d32c5c9ed11a00d9:'
    'eb8b19ec00b564ee1725efe626775ae20deef533a43be16d8f9310077daf5cb3:'
    'fa96c0f0392185c86be071f34862462a2babd308ef36e5e2f5f60e8cfc2b3e74';

const Map<String, ({int size, String sha256})> _sharedFiles = {
  'voices.bin': (
    size: 27678720,
    sha256: '8a77c0d397026208d22211f37670b5b3b11e03f190756b25a1d24041fced82a9',
  ),
  'tokens.txt': (
    size: 687,
    sha256: '6ebb6bb288f20f3ae8d004d3c2ca27697da27c037d75e81a60e2a6a663f95425',
  ),
  'lexicon-us-en.txt': (
    size: 5956885,
    sha256: '7daaab53a181be9885b853a8582bf1838186317e5dadacbcef9c426d6fa0da14',
  ),
  'lexicon-gb-en.txt': (
    size: 6366635,
    sha256: 'c4cbb37316f62210dff52718a7afcaae24f50c032cc75ab47ae67b831d1049e7',
  ),
  'espeak-ng-data/phonindex': (
    size: 39074,
    sha256: '3ca7b8fa3b42624e4b0f152707e7a39245fce569aa99ea47c055d9e622fcf0c4',
  ),
  'dict/jieba.dict.utf8': (
    size: 5071204,
    sha256: '3043b77068e09c9904f27cad82f12b6ebe9dbdb5aeff3b25e45ab7f9c1122b55',
  ),
};

const Map<String, ({int size, String sha256})> _fp32Files = {
  'model.onnx': (
    size: 325630829,
    sha256: 'c436dc6a842b62aba06af67e40bafcfb9c60ac3af895358f1974ad9a7f7c026b',
  ),
  ..._sharedFiles,
};

const Map<String, ({int size, String sha256})> _fp16Files = {
  'model.fp16.onnx': (
    size: 163493590,
    sha256: '7983eb4baa16c3b9a81832afd570e5bec06da12538f89b58d32c5c9ed11a00d9',
  ),
  ..._sharedFiles,
};

bool _packPresent(
  String dir,
  String readyMarker,
  Map<String, ({int size, String sha256})> files,
) {
  final ready = File('$dir/READY');
  if (!ready.existsSync() || ready.readAsStringSync().trim() != readyMarker) {
    return false;
  }
  final espeak = Directory('$dir/espeak-ng-data');
  final dict = Directory('$dir/dict');
  if (!espeak.existsSync() ||
      espeak
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .length !=
          _espeakTreeFiles ||
      !dict.existsSync() ||
      dict
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .length !=
          _dictTreeFiles) {
    return false;
  }
  return files.entries.every((entry) {
    final file = File('$dir/${entry.key}');
    return file.existsSync() && file.lengthSync() == entry.value.size;
  });
}

Future<void> _verifyPackHashes(
  String dir,
  Map<String, ({int size, String sha256})> files,
) async {
  for (final entry in files.entries) {
    final file = File('$dir/${entry.key}');
    final digest = await crypto.sha256.bind(file.openRead()).first;
    if (digest.toString() != entry.value.sha256) {
      throw StateError(
        '${entry.key} sha256 $digest does not match the '
        'pinned evaluation pack hash ${entry.value.sha256}',
      );
    }
  }
  await _verifyDirectoryTree(
    '$dir/espeak-ng-data',
    expectedFiles: _espeakTreeFiles,
    expectedSha256: _espeakTreeSha256,
  );
  await _verifyDirectoryTree(
    '$dir/dict',
    expectedFiles: _dictTreeFiles,
    expectedSha256: _dictTreeSha256,
  );
}

Future<void> _verifyDirectoryTree(
  String path, {
  required int expectedFiles,
  required String expectedSha256,
}) async {
  final directory = Directory(path);
  final files =
      directory
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  if (files.length != expectedFiles) {
    throw StateError(
      '$path contains ${files.length} files; '
      'expected the pinned $expectedFiles-file runtime tree',
    );
  }

  final manifest = StringBuffer();
  for (final file in files) {
    final relative = file.path
        .substring(directory.path.length + 1)
        .replaceAll('\\', '/');
    final digest = await crypto.sha256.bind(file.openRead()).first;
    manifest.writeln('$relative\t${file.lengthSync()}\t$digest');
  }
  final treeDigest = crypto.sha256
      .convert(utf8.encode(manifest.toString()))
      .toString();
  if (treeDigest != expectedSha256) {
    throw StateError(
      '$path tree sha256 $treeDigest does not match the '
      'pinned runtime tree hash $expectedSha256',
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('kokoro rtf on device', () async {
    sherpa.initBindings();
    final docs = (await getApplicationDocumentsDirectory()).path;
    final base = '$docs/models/kokoro_eval';

    // Sideload wait (flutter test reinstalls the app, so files land mid-run).
    // The driver writes the pinned READY text last; a bare/stale sentinel is
    // not readiness, and exact hashes are verified once copying has settled.
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(minutes: 6)) {
      if (_packPresent('$base/fp32', _fp32Ready, _fp32Files) &&
          _packPresent('$base/fp16', _fp16Ready, _fp16Files)) {
        break;
      }
      await Future.delayed(const Duration(seconds: 3));
    }
    expect(
      _packPresent('$base/fp32', _fp32Ready, _fp32Files),
      true,
      reason: 'fp32 pack does not match its pinned sizes/READY manifest',
    );
    expect(
      _packPresent('$base/fp16', _fp16Ready, _fp16Files),
      true,
      reason: 'fp16 pack does not match its pinned sizes/READY manifest',
    );
    await _verifyPackHashes('$base/fp32', _fp32Files);
    await _verifyPackHashes('$base/fp16', _fp16Files);
    print('PROBE: models verified after ${sw.elapsed}');

    for (final (name, dir, file) in [
      ('fp32-v1_0', '$base/fp32', 'model.onnx'),
      // Our weight-only fp16 conversion (int8 was eliminated: audibly worse
      // and slower than fp32 on both Mac and this phone).
      ('fp16-v1_0', '$base/fp16', 'model.fp16.onnx'),
    ]) {
      for (final threads in [2, 4]) {
        final tts = sherpa.OfflineTts(
          sherpa.OfflineTtsConfig(
            model: sherpa.OfflineTtsModelConfig(
              kokoro: sherpa.OfflineTtsKokoroModelConfig(
                model: '$dir/$file',
                voices: '$dir/voices.bin',
                tokens: '$dir/tokens.txt',
                dataDir: '$dir/espeak-ng-data',
                dictDir: '$dir/dict',
                lexicon: '$dir/lexicon-us-en.txt,$dir/lexicon-gb-en.txt',
              ),
              numThreads: threads,
              debug: false,
            ),
          ),
        );
        try {
          // Warm-up then timed run.
          tts.generate(text: 'Hello there.', sid: 3, speed: 1.0);
          final t = Stopwatch()..start();
          final audio = tts.generate(text: _line, sid: 3, speed: 1.0);
          t.stop();
          expect(
            audio.sampleRate,
            greaterThan(0),
            reason: '$name returned an invalid sample rate',
          );
          expect(
            audio.samples,
            isNotEmpty,
            reason: '$name returned no synthesized audio',
          );
          final dur = audio.samples.length / audio.sampleRate;
          expect(
            dur.isFinite && dur > 0,
            true,
            reason: '$name returned an invalid audio duration',
          );
          final rtf =
              t.elapsedMicroseconds / Duration.microsecondsPerSecond / dur;
          expect(
            rtf.isFinite && rtf > 0 && rtf < _maxAcceptableRtf,
            true,
            reason:
                '$name threads=$threads RTF $rtf must be positive and '
                'below $_maxAcceptableRtf',
          );
          print(
            'PROBE: $name threads=$threads '
            'rtf=${rtf.toStringAsFixed(2)} '
            'dur=${dur.toStringAsFixed(1)}s '
            'synth=${(t.elapsedMilliseconds / 1000).toStringAsFixed(1)}s',
          );
        } finally {
          tts.free();
        }
      }
    }
    print('PROBE: DONE');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
