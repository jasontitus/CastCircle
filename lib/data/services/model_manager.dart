import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
// ignore: depend_on_referenced_packages
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'debug_log_service.dart';
import 'model_download_service.dart';

/// Manages downloading and caching of on-device ML models.
///
/// Kokoro is downloaded as a .tar.bz2 archive (600+ files including
/// espeak-ng-data). Extraction runs in a separate isolate using streaming
/// I/O to avoid OOM and main-thread watchdog kills.
class ModelManager {
  ModelManager._();
  static final instance = ModelManager._();

  String? _modelsDir;
  Future<bool>? _markerMigration;

  static const _connectTimeout = Duration(seconds: 30);
  static const _responseTimeout = Duration(seconds: 60);
  static const _idleTimeout = Duration(seconds: 60);
  static const _archiveDownloadTimeout = Duration(minutes: 30);

  /// Base directory for all cached models.
  Future<String> get modelsDir async {
    if (_modelsDir != null) return _modelsDir!;
    final appDir = await getApplicationDocumentsDirectory();
    _modelsDir = p.join(appDir.path, 'models');
    await Directory(_modelsDir!).create(recursive: true);
    return _modelsDir!;
  }

  /// Directory where the Android ONNX Kokoro pack is expected.
  Future<String> get kokoroModelDir async =>
      p.join(await modelsDir, _kokoroModelName);

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
  static const kokoroCacheIdentity = _kokoroArchiveSha256;
  static const _kokoroReadyMarker = '.castcircle-ready';
  static const _kokoroRequiredFileSizes = <String, int>{
    _kokoroModelFile: 163493590,
    'voices.bin': 27678720,
    'tokens.txt': 687,
    'lexicon-us-en.txt': 5956885,
    'lexicon-gb-en.txt': 6366635,
    'espeak-ng-data/phonindex': 39074,
  };

  /// Superseded model dirs reclaimed on the next download/readiness check —
  /// the old fp32 pack is 600 MB of dead disk once the fp16 pack is in use.
  static const _legacyKokoroDirs = ['kokoro-multi-lang-v1_0'];

  // ── Kokoro TTS ─────────────────────────────────────────

  /// Check that the immutable Kokoro pack was completely extracted.
  Future<bool> isKokoroReady() async {
    final modelDir = await kokoroModelDir;
    final ready = await _isKokoroPackReady(modelDir, migrateLegacyMarker: true);
    if (ready) await _reclaimInterruptedKokoroBackup(modelDir);
    return ready;
  }

  Future<bool> _isKokoroPackReady(
    String modelDir, {
    bool migrateLegacyMarker = false,
  }) async {
    final marker = File(p.join(modelDir, _kokoroReadyMarker));
    try {
      if (!await Directory(p.join(modelDir, 'espeak-ng-data')).exists()) {
        return false;
      }
      for (final entry in _kokoroRequiredFileSizes.entries) {
        final file = File(p.join(modelDir, entry.key));
        if (!await file.exists() || await file.length() != entry.value) {
          return false;
        }
      }
      if (await marker.exists()) {
        return await marker.readAsString() == _kokoroArchiveSha256;
      }
      if (!migrateLegacyMarker) return false;

      // Packs installed before the marker was introduced are still accepted
      // only after the exact immutable-file manifest passes. Publish their
      // marker atomically so interruption cannot manufacture readiness.
      return _migrateLegacyMarker(marker);
    } on FileSystemException {
      return false;
    }
  }

  Future<bool> _migrateLegacyMarker(File marker) async {
    final active = _markerMigration;
    if (active != null) {
      await active;
      return await marker.exists() &&
          await marker.readAsString() == _kokoroArchiveSha256;
    }

    late final Future<bool> operation;
    operation = _writeLegacyMarker(marker);
    _markerMigration = operation;
    try {
      return await operation;
    } finally {
      if (identical(_markerMigration, operation)) _markerMigration = null;
    }
  }

  Future<bool> _writeLegacyMarker(File marker) async {
    final temporaryMarker = File('${marker.path}.tmp');
    try {
      // Re-check after winning the migration slot: another completed caller
      // may already have published the marker while this one was waiting.
      if (await marker.exists()) {
        return await marker.readAsString() == _kokoroArchiveSha256;
      }
      await temporaryMarker.writeAsString(_kokoroArchiveSha256, flush: true);
      await temporaryMarker.rename(marker.path);
      return true;
    } on FileSystemException {
      // If publication lost a filesystem race, accept only the exact marker.
      try {
        return await marker.exists() &&
            await marker.readAsString() == _kokoroArchiveSha256;
      } on FileSystemException {
        return false;
      }
    } finally {
      try {
        if (await temporaryMarker.exists()) await temporaryMarker.delete();
      } catch (_) {}
    }
  }

  Future<void> _reclaimInterruptedKokoroBackup(String modelDir) async {
    final backup = Directory(
      p.join(p.dirname(modelDir), '.$_kokoroModelName.backup'),
    );
    try {
      if (await backup.exists()) await backup.delete(recursive: true);
    } catch (e) {
      debugPrint('ModelManager: could not remove Kokoro backup: $e');
    }
  }

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
    if (!await isKokoroReady()) return null;
    final modelDir = await kokoroModelDir;
    return (
      model: p.join(modelDir, _kokoroModelFile),
      voices: p.join(modelDir, 'voices.bin'),
      tokens: p.join(modelDir, 'tokens.txt'),
      dataDir: p.join(modelDir, 'espeak-ng-data'),
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
    // Free the superseded fp32 pack first — 600 MB, and preflight headroom
    // for the new download.
    await _reclaimLegacyKokoro();
    if (await isKokoroReady()) {
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
  }

  // ── Download all ───────────────────────────────────────

  /// Check whether this platform's downloadable runtime models are ready.
  ///
  /// Android uses ONNX Kokoro plus live ASR, iOS uses MLX Kokoro, and macOS
  /// uses system TTS and therefore has no Kokoro readiness requirement.
  Future<bool> isAllReady() async {
    if (Platform.isAndroid) {
      return await isKokoroReady() &&
          await ModelDownloadService.instance.isLiveAsrReady();
    }
    if (Platform.isIOS) {
      return ModelDownloadService.instance.isKokoroReady();
    }
    return true;
  }

  /// Download every model required by [isAllReady] on this platform.
  Future<void> downloadAll({
    void Function(String model, String file, double progress)? onProgress,
  }) async {
    if (Platform.isAndroid) {
      await downloadKokoro(
        onProgress: (file, progress) =>
            onProgress?.call('Kokoro TTS', file, progress),
      );
      await ModelDownloadService.instance.downloadLiveAsr();
    } else if (Platform.isIOS) {
      await ModelDownloadService.instance.downloadKokoro();
    }
  }

  /// Delete only the Android ONNX Kokoro pack.
  Future<void> deleteKokoro() async {
    final modelDir = Directory(await kokoroModelDir);
    if (await modelDir.exists()) {
      await modelDir.delete(recursive: true);
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
    final tmpDir = await getTemporaryDirectory();
    final archiveName = p.basename(Uri.parse(url).path);
    final archivePath = p.join(tmpDir.path, archiveName);

    // Remove stale archive from interrupted download
    try {
      if (await File(archivePath).exists()) await File(archivePath).delete();
    } catch (_) {}

    // Download the archive
    await _downloadFile(url, archivePath, (progress) {
      // Download is 80% of the work, extraction is 20%
      onProgress?.call(progress * 0.8);
    });

    final archiveFile = File(archivePath);
    final stagingRoot = Directory(
      p.join(destDir, '.$_kokoroModelName.extracting'),
    );
    try {
      final archiveSize = await archiveFile.length();
      debugPrint(
        'Archive downloaded: '
        '${(archiveSize / 1024 / 1024).toStringAsFixed(1)} MB',
      );
      if (archiveSize < 1000) {
        throw Exception(
          'Archive too small ($archiveSize bytes) — download likely failed',
        );
      }

      // Hash away from the UI isolate; this archive is roughly 180 MB.
      final path = archiveFile.path;
      final actual = await Isolate.run(() async {
        final digest = await crypto.sha256.bind(File(path).openRead()).first;
        return digest.toString().toLowerCase();
      });
      if (actual != expectedSha256.toLowerCase()) {
        throw Exception(
          'Archive failed verification (sha256 $actual != '
          'expected $expectedSha256) — it was discarded, please try again',
        );
      }

      // Never expose a partially extracted pack. Extract beside the final
      // directory, validate it, write the completion marker, then rename.
      if (await stagingRoot.exists()) {
        await stagingRoot.delete(recursive: true);
      }
      await stagingRoot.create(recursive: true);
      debugPrint('Extracting archive to ${stagingRoot.path} ...');
      onProgress?.call(0.85);
      await compute(_extractArchiveStreaming, (archivePath, stagingRoot.path));

      final stagedModelDir = Directory(
        p.join(stagingRoot.path, _kokoroModelName),
      );
      await File(
        p.join(stagedModelDir.path, _kokoroReadyMarker),
      ).writeAsString(_kokoroArchiveSha256, flush: true);
      if (!await _isKokoroPackReady(stagedModelDir.path)) {
        throw Exception('Extracted Kokoro model pack is incomplete');
      }
      await _replaceKokoroModel(stagedModelDir, destDir);
      onProgress?.call(1.0);
      debugPrint('Archive extracted successfully');
    } catch (e) {
      debugPrint('Archive extraction failed: $e');
      rethrow;
    } finally {
      // Both files are large; neither should accumulate after any failure.
      try {
        if (await archiveFile.exists()) await archiveFile.delete();
      } catch (_) {}
      try {
        if (await stagingRoot.exists()) {
          await stagingRoot.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  Future<void> _replaceKokoroModel(
    Directory stagedModelDir,
    String destDir,
  ) async {
    final finalDir = Directory(p.join(destDir, _kokoroModelName));
    final backupDir = Directory(p.join(destDir, '.$_kokoroModelName.backup'));

    if (await finalDir.exists()) {
      if (await backupDir.exists()) {
        // A previous install was interrupted after moving the old pack aside.
        // The current final pack is known not-ready (otherwise downloadKokoro
        // returned early), so preserve the backup until the staged pack lands.
        await finalDir.delete(recursive: true);
      } else {
        await finalDir.rename(backupDir.path);
      }
    }
    try {
      await stagedModelDir.rename(finalDir.path);
    } catch (_) {
      if (!await finalDir.exists() && await backupDir.exists()) {
        await backupDir.rename(finalDir.path);
      }
      rethrow;
    }
    try {
      if (await backupDir.exists()) await backupDir.delete(recursive: true);
    } catch (e) {
      debugPrint('ModelManager: could not remove old Kokoro pack: $e');
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
    final tmpFile = File('$localPath.tmp');
    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = _connectTimeout;
    try {
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(_connectTimeout);
      // With autoUncompress off, a server that gzips the response writes
      // gzipped bytes into a file we then treat as the archive. Archives are
      // sha256-checked so it would fail loudly rather than corrupt silently,
      // but asking for identity avoids the round trip. (This is exactly what
      // broke tokens.txt in the model downloader.)
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close().timeout(_responseTimeout);

      if (response.statusCode != 200) {
        if (response.isRedirect ||
            response.statusCode == 302 ||
            response.statusCode == 301 ||
            response.statusCode == 307) {
          final redirectUrl = response.headers.value('location');
          if (redirectUrl != null) {
            await response.drain<void>().timeout(_idleTimeout);
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
        await response.drain<void>().timeout(_idleTimeout);
        throw Exception('Download failed: HTTP ${response.statusCode}');
      }

      final contentLength = response.contentLength;
      var bytesReceived = 0;
      final sink = tmpFile.openWrite();

      // Throttle progress to ~1 MB deltas: the callback typically ends in
      // setState, and per-socket-chunk emission meant thousands of full
      // screen rebuilds over a 180 MB archive.
      var lastNotified = 0;
      final transfer = response.timeout(_idleTimeout).listen((chunk) {
        sink.add(chunk);
        bytesReceived += chunk.length;
        if (contentLength > 0 &&
            (bytesReceived - lastNotified > 1024 * 1024 ||
                bytesReceived == contentLength)) {
          lastNotified = bytesReceived;
          onProgress?.call(bytesReceived / contentLength);
        }
      });
      try {
        await transfer.asFuture<void>().timeout(_archiveDownloadTimeout);
        await sink.flush();
      } finally {
        await transfer.cancel();
        await sink.close();
      }
      await tmpFile.rename(localPath);
      onProgress?.call(1.0);
      debugPrint(
        'Downloaded: ${p.basename(localPath)} (${(bytesReceived / 1024 / 1024).toStringAsFixed(1)} MB)',
      );
    } catch (_) {
      try {
        if (await tmpFile.exists()) await tmpFile.delete();
      } catch (_) {}
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}
