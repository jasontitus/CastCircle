import 'dart:io';

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


  // ── Kokoro TTS ─────────────────────────────────────────

  /// Check if Kokoro model is downloaded and extracted.
  Future<bool> isKokoroReady() async {
    final dir = await modelsDir;
    final modelDir = p.join(dir, _kokoroModelName);
    return await File(p.join(modelDir, _kokoroModelFile)).exists() &&
        await File(p.join(modelDir, 'voices.bin')).exists() &&
        await File(p.join(modelDir, 'tokens.txt')).exists() &&
        await File(p.join(modelDir, 'lexicon-us-en.txt')).exists();
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
      })?> getKokoroPaths() async {
    if (!await isKokoroReady()) return null;
    final dir = await modelsDir;
    final modelDir = p.join(dir, _kokoroModelName);
    return (
      model: p.join(modelDir, _kokoroModelFile),
      voices: p.join(modelDir, 'voices.bin'),
      tokens: p.join(modelDir, 'tokens.txt'),
      dataDir: p.join(modelDir, 'espeak-ng-data'),
      lexicon: '${p.join(modelDir, 'lexicon-us-en.txt')},'
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
    String? expectedSha256,
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

    // Verify archive downloaded correctly
    final archiveFile = File(archivePath);
    final archiveSize = await archiveFile.length();
    debugPrint('Archive downloaded: ${(archiveSize / 1024 / 1024).toStringAsFixed(1)} MB');
    if (archiveSize < 1000) {
      throw Exception('Archive too small ($archiveSize bytes) — download likely failed');
    }

    // Integrity: these bytes get extracted and fed straight into native
    // inference code — a truncated or tampered archive must fail HERE, not
    // manifest as a mysterious crash later.
    if (expectedSha256 != null) {
      final digest = await crypto.sha256.bind(archiveFile.openRead()).first;
      final actual = digest.toString().toLowerCase();
      if (actual != expectedSha256.toLowerCase()) {
        try {
          await archiveFile.delete();
        } catch (_) {}
        throw Exception('Archive failed verification (sha256 $actual != '
            'expected $expectedSha256) — it was discarded, please try again');
      }
    }

    // Extract in a separate isolate using streaming I/O
    debugPrint('Extracting archive to $destDir ...');
    onProgress?.call(0.85);
    try {
      await compute(_extractArchiveStreaming, (archivePath, destDir));
    } catch (e) {
      debugPrint('Archive extraction failed: $e');
      rethrow;
    } finally {
      // Delete the ~180 MB archive on failure too — repeated failed
      // extractions (e.g. disk full) used to accumulate these.
      try {
        await File(archivePath).delete();
      } catch (_) {}
    }

    onProgress?.call(1.0);
    debugPrint('Archive extracted successfully');
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
              final msg = 'Model download refused: redirect to a non-HTTPS URL '
                  '(${target.scheme}://${target.host})';
              DebugLogService.instance.logError(LogCategory.network, msg);
              throw Exception(msg);
            }
            if (redirectsLeft <= 0) {
              final msg = 'Model download refused: too many redirects from $url';
              DebugLogService.instance.logError(LogCategory.network, msg);
              throw Exception(msg);
            }
            await _downloadFile(target.toString(), localPath, onProgress,
                redirectsLeft: redirectsLeft - 1);
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
          'Downloaded: ${p.basename(localPath)} (${(bytesReceived / 1024 / 1024).toStringAsFixed(1)} MB)');
    } finally {
      client.close();
    }
  }
}
