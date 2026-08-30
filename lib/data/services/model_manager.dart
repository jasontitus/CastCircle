import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:archive/archive_io.dart';
// ignore: depend_on_referenced_packages
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'debug_log_service.dart';
import 'model_download_service.dart';

/// One file whose exact bytes are required by the shipped Kokoro engine.
class KokoroPackArtifact {
  const KokoroPackArtifact(this.relativePath, this.sizeBytes, this.sha256);

  final String relativePath;
  final int sizeBytes;
  final String sha256;

  Map<String, Object> toJson() => {
    'path': relativePath,
    'size': sizeBytes,
    'sha256': sha256,
  };
}

/// Manages downloading and caching of on-device ML models.
///
/// Kokoro is downloaded as a .tar.bz2 archive (600+ files including
/// espeak-ng-data). Extraction runs in a separate isolate using streaming
/// I/O to avoid OOM and main-thread watchdog kills.
class ModelManager {
  ModelManager._() : _activePackStagingPaths = {};

  @visibleForTesting
  ModelManager.forTesting(
    String modelsDirectory, {
    Set<String> activePackStagingPaths = const {},
  }) : _modelsDir = modelsDirectory,
       _activePackStagingPaths = {...activePackStagingPaths};

  static final instance = ModelManager._();

  String? _modelsDir;
  final Set<String> _activePackStagingPaths;
  Future<void> _kokoroCriticalTail = Future<void>.value();

  /// Base directory for all cached models.
  Future<String> get modelsDir async {
    if (_modelsDir != null) return _modelsDir!;
    final appDir = await getApplicationDocumentsDirectory();
    _modelsDir = p.join(appDir.path, 'models');
    await Directory(_modelsDir!).create(recursive: true);
    return _modelsDir!;
  }

  // ── URLs ──────────────────────────────────────────────

  // Our own release asset (supply-chain: immutable tag + pinned hash), not
  // the k2-fsa fp32 original: weight-only fp16 conversion halves the download
  // (182 MB vs 349 MB) with verified-identical output (log-spectral corr
  // 0.998, same speed — see integration_test/tts_kokoro_compare_macos_test.dart)
  // and drops the zh-only jieba dict/lexicons the app never uses.
  static const _kokoroArchiveUrl =
      'https://github.com/jasontitus/CastCircle/releases/download/kokoro-en-fp16-v1/kokoro-en-fp16-v1_0.tar.bz2';
  static const _kokoroArchiveSha256 =
      '4cafe1c49bf4b0a7f9c2fab9f2b010b05544dde2b28b66e3211e832308a1a1f9';
  static const _kokoroModelName = 'kokoro-en-fp16-v1_0';
  static const _kokoroModelFile = 'model.fp16.onnx';

  /// Superseded model dirs reclaimed on the next download/readiness check —
  /// the old fp32 pack is 600 MB of dead disk once the fp16 pack is in use.
  static const _legacyKokoroDirs = ['kokoro-multi-lang-v1_0'];
  static const _kokoroManifestFile = '.castcircle-pack.json';
  static const _kokoroEspeakDataDir = 'espeak-ng-data';

  /// Exact runtime inputs from the archive pinned by [_kokoroArchiveSha256].
  ///
  /// Extraction verifies every hash once before publish. Normal readiness
  /// checks compare the completion manifest and exact sizes, avoiding a
  /// repeated 180 MB hash scan while still detecting interrupted extraction,
  /// truncation, or a pack from a different release.
  static const kokoroRequiredArtifacts = <KokoroPackArtifact>[
    KokoroPackArtifact(
      'model.fp16.onnx',
      163493590,
      '7983eb4baa16c3b9a81832afd570e5bec06da12538f89b58d32c5c9ed11a00d9',
    ),
    KokoroPackArtifact(
      'voices.bin',
      27678720,
      '8a77c0d397026208d22211f37670b5b3b11e03f190756b25a1d24041fced82a9',
    ),
    KokoroPackArtifact(
      'tokens.txt',
      687,
      '6ebb6bb288f20f3ae8d004d3c2ca27697da27c037d75e81a60e2a6a663f95425',
    ),
    KokoroPackArtifact(
      'lexicon-us-en.txt',
      5956885,
      '7daaab53a181be9885b853a8582bf1838186317e5dadacbcef9c426d6fa0da14',
    ),
    KokoroPackArtifact(
      'lexicon-gb-en.txt',
      6366635,
      'c4cbb37316f62210dff52718a7afcaae24f50c032cc75ab47ae67b831d1049e7',
    ),
    KokoroPackArtifact(
      'espeak-ng-data/phontab',
      55796,
      '886f3fa402cb0ba73d483aa8ad000af47a6b7cc06293c75a97913fba68a530f6',
    ),
    KokoroPackArtifact(
      'espeak-ng-data/phonindex',
      39074,
      '3ca7b8fa3b42624e4b0f152707e7a39245fce569aa99ea47c055d9e622fcf0c4',
    ),
    KokoroPackArtifact(
      'espeak-ng-data/phondata',
      550424,
      '4e0288957874029a8c3c9f41a8f517ad4bf18127046decbdd4b9d1d6807ce3a3',
    ),
    KokoroPackArtifact(
      'espeak-ng-data/intonations',
      2040,
      '3f8af65fd3eda9759a10f021d61361c120871f463515229c925995c7f90918cc',
    ),
    KokoroPackArtifact(
      'espeak-ng-data/en_dict',
      166944,
      '71bd330ba8a2e3e8076e631508208ef49449d6147c17b7bd2b4b1e1468292e35',
    ),
    KokoroPackArtifact(
      'espeak-ng-data/lang/gmw/en',
      140,
      '4605d5330801de3641c6e366d15f129ea1f5ffbce8722642aba01ace07ab9c83',
    ),
    KokoroPackArtifact(
      'espeak-ng-data/lang/gmw/en-US',
      257,
      '41534c2a22df5dd4f1052ff9e1a33a3ea7bff5a26b5c02bdad5ba8ddb7524704',
    ),
    KokoroPackArtifact(
      'espeak-ng-data/lang/gmw/en-GB-x-rp',
      249,
      'd0625af7f58561b1b8cf96fd7f93eee6553bcb3eadb9020ae0757bf96e5115e5',
    ),
  ];

  static String get kokoroManifestJson => jsonEncode({
    'model': _kokoroModelName,
    'archiveSha256': _kokoroArchiveSha256,
    'artifacts': kokoroRequiredArtifacts
        .map((artifact) => artifact.toJson())
        .toList(),
  });

  // ── Kokoro TTS ─────────────────────────────────────────

  Future<String?> kokoroProblem() =>
      _withKokoroCriticalSection(_kokoroProblemLocked);

  Future<String?> _kokoroProblemLocked() async {
    final dir = await modelsDir;
    final modelsRoot = Directory(dir);
    final modelDir = Directory(p.join(dir, _kokoroModelName));
    await _runKokoroReconciliation(modelsRoot, modelDir);

    final problem = await _kokoroPackProblem(
      modelDir,
      requireManifest: true,
      verifyHashes: false,
    );
    if (problem != 'verification manifest missing') return problem;

    // One-time upgrade for packs installed before completion manifests were
    // introduced. Full-hash the pinned runtime inputs once; only exact known
    // bytes earn the marker and avoid an unnecessary 180 MB redownload.
    final legacyProblem = await _kokoroPackProblem(
      modelDir,
      requireManifest: false,
      verifyHashes: true,
    );
    if (legacyProblem != null) return legacyProblem;
    await _writeKokoroManifest(modelDir);
    await _runKokoroReconciliation(modelsRoot, modelDir);
    return null;
  }

  Future<T> _withKokoroCriticalSection<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _kokoroCriticalTail = _kokoroCriticalTail.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  Future<void> _runKokoroReconciliation(
    Directory modelsRoot,
    Directory active,
  ) async {
    if (!await active.exists()) {
      await _restoreInterruptedPublish(modelsRoot, active);
    }
    final activeProblem = await _kokoroPackProblem(
      active,
      requireManifest: true,
      verifyHashes: false,
    );
    if (activeProblem != null || !await modelsRoot.exists()) return;

    final obsolete = <Directory>[];
    await for (final entry in modelsRoot.list(followLinks: false)) {
      if (entry is! Directory) continue;
      final name = p.basename(entry.path);
      if (name.startsWith('$_kokoroModelName.previous-') ||
          name.startsWith('.kokoro_staging_')) {
        obsolete.add(entry);
      }
    }
    for (final directory in obsolete) {
      if (_activePackStagingPaths.contains(directory.path)) continue;
      try {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      } catch (e) {
        // Leave it discoverable: the next readiness call retries cleanup.
        DebugLogService.instance.logError(
          LogCategory.error,
          'ModelManager: deferred Kokoro artifact cleanup failed',
          e,
        );
      }
    }
  }

  Future<void> _restoreInterruptedPublish(
    Directory modelsRoot,
    Directory active,
  ) async {
    if (!await modelsRoot.exists() || await active.exists()) return;
    final backups = <Directory>[];
    await for (final entry in modelsRoot.list(followLinks: false)) {
      if (entry is Directory &&
          p.basename(entry.path).startsWith('$_kokoroModelName.previous-')) {
        backups.add(entry);
      }
    }
    backups.sort((a, b) => b.path.compareTo(a.path));
    for (final backup in backups) {
      final problem = await _kokoroPackProblem(
        backup,
        requireManifest: true,
        verifyHashes: false,
      );
      if (problem != null) continue;
      try {
        await backup.rename(active.path);
        DebugLogService.instance.log(
          LogCategory.general,
          'ModelManager: restored verified pack after interrupted publish',
        );
        return;
      } catch (e) {
        DebugLogService.instance.logError(
          LogCategory.error,
          'ModelManager: could not restore interrupted Kokoro publish',
          e,
        );
        return;
      }
    }
  }

  /// Check if the exact verified Kokoro pack is installed.
  Future<bool> isKokoroReady() async => await kokoroProblem() == null;

  /// Get paths to Kokoro model files. Returns null if not downloaded.
  /// [lexicon] is the comma-separated list sherpa expects.
  Future<
    ({
      String model,
      String voices,
      String tokens,
      String dataDir,
      String lexicon,
    })?
  >
  getKokoroPaths() async {
    if (await kokoroProblem() != null) return null;
    final dir = await modelsDir;
    final modelDir = p.join(dir, _kokoroModelName);
    return (
      model: p.join(modelDir, _kokoroModelFile),
      voices: p.join(modelDir, 'voices.bin'),
      tokens: p.join(modelDir, 'tokens.txt'),
      dataDir: p.join(modelDir, _kokoroEspeakDataDir),
      lexicon:
          '${p.join(modelDir, 'lexicon-us-en.txt')},'
          '${p.join(modelDir, 'lexicon-gb-en.txt')}',
    );
  }

  /// Delete superseded model dirs (best-effort, silent when absent).
  Future<void> _reclaimLegacyKokoro() async {
    final dir = await modelsDir;
    for (final name in _legacyKokoroDirs) {
      final d = Directory(p.join(dir, name));
      if (await d.exists()) {
        try {
          await d.delete(recursive: true);
          debugPrint('ModelManager: reclaimed legacy model dir $name');
        } catch (e) {
          debugPrint('ModelManager: could not delete legacy $name: $e');
        }
      }
    }
  }

  /// Download and extract Kokoro TTS model archive.
  Future<void> downloadKokoro({
    void Function(String file, double progress)? onProgress,
  }) async {
    if (await isKokoroReady()) {
      await _reclaimLegacyKokoro();
      onProgress?.call('kokoro', 1.0);
      return;
    }
    final dir = await modelsDir;
    onProgress?.call('$_kokoroModelName.tar.bz2', 0);
    await _downloadAndExtractArchive(
      _kokoroArchiveUrl,
      dir,
      (progress) => onProgress?.call('$_kokoroModelName.tar.bz2', progress),
      expectedSha256: _kokoroArchiveSha256,
    );
    await _reclaimLegacyKokoro();
  }

  // ── Download all ───────────────────────────────────────

  /// Check if all required models are downloaded.
  /// iOS: checks MLX Kokoro (via ModelDownloadService).
  /// Android: checks ONNX Kokoro (via ModelManager).
  Future<bool> isAllReady() async {
    if (Platform.isAndroid) {
      // Voices AND the live line-matching ASR — the production hub's download
      // prompt/banner stays up until rehearsal has its full experience.
      return await isKokoroReady() &&
          await ModelDownloadService.instance.isLiveAsrReady();
    }
    return ModelDownloadService.instance.isKokoroReady();
  }

  /// Download all models. Use ModelDownloadService for individual model downloads.
  ///
  /// Pairs with [isAllReady]: on Android that also requires the live
  /// line-matching ASR group, so it must be downloaded here too — otherwise
  /// "download all" completes and the ready gate still reports false forever.
  Future<void> downloadAll({
    void Function(String model, String file, double progress)? onProgress,
  }) async {
    await downloadKokoro(
      onProgress: (file, progress) =>
          onProgress?.call('Kokoro TTS', file, progress),
    );
    if (Platform.isAndroid) {
      await ModelDownloadService.instance.downloadLiveAsr();
    }
  }

  /// Delete all cached models.
  Future<void> clearCache() async {
    final dir = await modelsDir;
    final d = Directory(dir);
    if (await d.exists()) {
      await d.delete(recursive: true);
      await d.create(recursive: true);
    }
  }

  // ── Helpers ────────────────────────────────────────────

  /// Download a .tar.bz2 archive and extract it to [destDir].
  ///
  /// Extraction runs in a separate isolate using streaming I/O:
  /// bzip2 → temp tar file → extract entries one at a time.
  /// This avoids both OOM (streaming) and iOS watchdog kills (off main thread).
  Future<void> _downloadAndExtractArchive(
    String url,
    String destDir,
    void Function(double progress)? onProgress, {
    required String expectedSha256,
  }) async {
    final downloadDir = await (await getTemporaryDirectory()).createTemp(
      'kokoro_download_',
    );
    final archiveName = p.basename(Uri.parse(url).path);
    final archivePath = p.join(downloadDir.path, archiveName);
    final archiveFile = File(archivePath);
    Directory? stagingRoot;

    try {
      await _downloadFile(url, archivePath, (progress) {
        onProgress?.call(progress * 0.8);
      });

      final archiveSize = await archiveFile.length();
      debugPrint(
        'Archive downloaded: ${(archiveSize / 1024 / 1024).toStringAsFixed(1)} MB',
      );
      final digest = await crypto.sha256.bind(archiveFile.openRead()).first;
      final actual = digest.toString().toLowerCase();
      if (actual != expectedSha256.toLowerCase()) {
        throw Exception(
          'Archive failed verification (sha256 $actual != '
          'expected ${expectedSha256.toLowerCase()}) — it was discarded, '
          'please try again',
        );
      }

      // Never extract over the active pack. A failed or interrupted extraction
      // remains isolated here and cannot turn a working installation partial.
      final modelsRoot = Directory(destDir);
      await modelsRoot.create(recursive: true);
      stagingRoot = await _createLeasedStagingRoot(modelsRoot);
      debugPrint('Extracting archive to ${stagingRoot.path} ...');
      onProgress?.call(0.85);
      await compute(_extractArchiveStreaming, (archivePath, stagingRoot.path));

      final stagedModel = Directory(p.join(stagingRoot.path, _kokoroModelName));
      final problem = await _kokoroPackProblem(
        stagedModel,
        requireManifest: false,
        verifyHashes: true,
      );
      if (problem != null) {
        throw Exception(
          'Extracted Kokoro pack failed verification ($problem) — '
          'the working model was kept',
        );
      }
      await _writeKokoroManifest(stagedModel);

      await _publishVerifiedKokoroPack(
        stagedModel,
        Directory(p.join(destDir, _kokoroModelName)),
      );
      onProgress?.call(1.0);
      debugPrint('Kokoro archive verified and published successfully');
    } finally {
      if (await downloadDir.exists()) {
        try {
          await downloadDir.delete(recursive: true);
        } catch (e) {
          DebugLogService.instance.logError(
            LogCategory.error,
            'ModelManager: could not remove archive staging directory',
            e,
          );
        }
      }
      final staging = stagingRoot;
      if (staging != null) {
        try {
          if (await staging.exists()) {
            await staging.delete(recursive: true);
          }
        } catch (e) {
          DebugLogService.instance.logError(
            LogCategory.error,
            'ModelManager: could not remove extraction staging directory',
            e,
          );
        } finally {
          _activePackStagingPaths.remove(staging.path);
        }
      }
    }
  }

  static Future<String?> _kokoroPackProblem(
    Directory modelDir, {
    required bool requireManifest,
    required bool verifyHashes,
  }) async {
    if (!await modelDir.exists()) return 'pack directory missing';

    final dataDir = Directory(p.join(modelDir.path, _kokoroEspeakDataDir));
    if (!await dataDir.exists()) return '$_kokoroEspeakDataDir missing';

    if (requireManifest) {
      final marker = File(p.join(modelDir.path, _kokoroManifestFile));
      if (!await marker.exists()) return 'verification manifest missing';
      try {
        final decoded = jsonDecode(await marker.readAsString());
        final expected = jsonDecode(kokoroManifestJson);
        if (jsonEncode(decoded) != jsonEncode(expected)) {
          return 'verification manifest does not match $_kokoroModelName';
        }
      } catch (e) {
        return 'verification manifest unreadable: $e';
      }
    }

    for (final artifact in kokoroRequiredArtifacts) {
      final file = File(p.join(modelDir.path, artifact.relativePath));
      if (!await file.exists()) return '${artifact.relativePath} missing';
      final actualSize = await file.length();
      if (actualSize != artifact.sizeBytes) {
        return '${artifact.relativePath} size $actualSize B != '
            '${artifact.sizeBytes} B';
      }
      if (verifyHashes) {
        final digest = await crypto.sha256.bind(file.openRead()).first;
        final actualHash = digest.toString().toLowerCase();
        if (actualHash != artifact.sha256) {
          return '${artifact.relativePath} sha256 $actualHash != '
              '${artifact.sha256}';
        }
      }
    }
    return null;
  }

  static Future<void> _writeKokoroManifest(Directory modelDir) async {
    final marker = File(p.join(modelDir.path, _kokoroManifestFile));
    final stagedMarker = File('${marker.path}.tmp');
    await stagedMarker.writeAsString(kokoroManifestJson, flush: true);
    await stagedMarker.rename(marker.path);
  }

  Future<Directory> _createLeasedStagingRoot(Directory modelsRoot) =>
      _withKokoroCriticalSection(() async {
        final staging = await modelsRoot.createTemp('.kokoro_staging_');
        _activePackStagingPaths.add(staging.path);
        return staging;
      });

  Future<void> _publishVerifiedKokoroPack(Directory staged, Directory active) =>
      _withKokoroCriticalSection(
        () => _publishVerifiedKokoroPackLocked(staged, active),
      );

  Future<void> _publishVerifiedKokoroPackLocked(
    Directory staged,
    Directory active,
  ) async {
    Directory? backup;
    if (await active.exists()) {
      backup = Directory(
        '${active.path}.previous-${DateTime.now().microsecondsSinceEpoch}',
      );
      await active.rename(backup.path);
    }
    try {
      await staged.rename(active.path);
    } catch (e) {
      if (backup != null && await backup.exists() && !await active.exists()) {
        await backup.rename(active.path);
      }
      rethrow;
    }
    if (backup != null && await backup.exists()) {
      try {
        await backup.delete(recursive: true);
      } catch (e) {
        DebugLogService.instance.logError(
          LogCategory.error,
          'ModelManager: verified pack active but old pack cleanup failed',
          e,
        );
      }
    }
  }

  /// Streaming archive extraction — runs in an isolate.
  ///
  /// Step 1: Stream-decompress bzip2 to a temp .tar file on disk.
  /// Step 2: Stream-extract tar entries to destination, one file at a time.
  /// Peak memory is ~one file, not the entire archive.
  static void _extractArchiveStreaming((String, String) args) {
    final (archivePath, destDir) = args;
    // Decompress bzip2 → temp tar file
    final tempDir = Directory.systemTemp.createTempSync('lineguide_extract');
    try {
      final tarPath = p.join(tempDir.path, 'temp.tar');

      final input = InputFileStream(archivePath);
      final output = OutputFileStream(tarPath);
      BZip2Decoder().decodeStream(input, output);
      input.closeSync();
      output.closeSync();

      // Extract tar entries to destination
      final tarInput = InputFileStream(tarPath);
      final archive = TarDecoder().decodeStream(tarInput);
      extractArchiveToDiskSync(archive, destDir);
      tarInput.closeSync();
      archive.clear();
    } finally {
      // Failure used to leak the fully-decompressed tar (hundreds of MB)
      // in system temp on every failed extraction.
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// Download a single file with progress reporting.
  ///
  /// [redirectsLeft] bounds the hand-rolled redirect following below — a
  /// redirect loop used to recurse until the stack blew.
  Future<void> _downloadFile(
    String url,
    String localPath,
    void Function(double progress)? onProgress, {
    int redirectsLeft = 5,
  }) async {
    final file = File(localPath);
    if (await file.exists()) {
      onProgress?.call(1.0);
      return;
    }

    await file.parent.create(recursive: true);

    debugPrint('Downloading: $url');
    final client = HttpClient();
    client.autoUncompress = false; // Don't decompress — we need raw bz2 bytes
    try {
      final request = await client.getUrl(Uri.parse(url));
      // With autoUncompress off, a server that gzips the response writes
      // gzipped bytes into a file we then treat as the archive. Archives are
      // sha256-checked so it would fail loudly rather than corrupt silently,
      // but asking for identity avoids the round trip. (This is exactly what
      // broke tokens.txt in the model downloader.)
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close();

      if (response.statusCode != 200) {
        if (response.isRedirect ||
            response.statusCode == 302 ||
            response.statusCode == 301 ||
            response.statusCode == 307) {
          final redirectUrl = response.headers.value('location');
          if (redirectUrl != null) {
            await response.drain<void>();
            client.close();
            // Location may be relative; resolve it against the current URL.
            final target = Uri.parse(url).resolve(redirectUrl);
            // Redirects are followed by hand here (autoUncompress is off), so
            // the scheme check HttpClient would do is ours to make: an
            // https→http hop would put the model bytes we then execute-as-data
            // on the wire in the clear, open to tampering.
            if (target.scheme != 'https') {
              final msg =
                  'Model download refused: redirect to a non-HTTPS URL '
                  '(${target.scheme}://${target.host})';
              DebugLogService.instance.logError(LogCategory.network, msg);
              throw Exception(msg);
            }
            if (redirectsLeft <= 0) {
              final msg =
                  'Model download refused: too many redirects from $url';
              DebugLogService.instance.logError(LogCategory.network, msg);
              throw Exception(msg);
            }
            await _downloadFile(
              target.toString(),
              localPath,
              onProgress,
              redirectsLeft: redirectsLeft - 1,
            );
            return;
          }
        }
        await response.drain<void>();
        throw Exception('Download failed: HTTP ${response.statusCode}');
      }

      final contentLength = response.contentLength;
      var bytesReceived = 0;
      final tmpPath = '$localPath.tmp';
      final tmpFile = File(tmpPath);
      final sink = tmpFile.openWrite();

      // Throttle progress to ~1 MB deltas: the callback typically ends in
      // setState, and per-socket-chunk emission meant thousands of full
      // screen rebuilds over a 180 MB archive.
      var lastNotified = 0;
      await for (final chunk in response) {
        sink.add(chunk);
        bytesReceived += chunk.length;
        if (contentLength > 0 &&
            (bytesReceived - lastNotified > 1024 * 1024 ||
                bytesReceived == contentLength)) {
          lastNotified = bytesReceived;
          onProgress?.call(bytesReceived / contentLength);
        }
      }

      await sink.close();
      await tmpFile.rename(localPath);
      onProgress?.call(1.0);
      debugPrint(
        'Downloaded: ${p.basename(localPath)} (${(bytesReceived / 1024 / 1024).toStringAsFixed(1)} MB)',
      );
    } finally {
      client.close();
    }
  }
}
