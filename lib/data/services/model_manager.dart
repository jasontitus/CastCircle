import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'mlx_stt_channel.dart';

/// Manages downloading and caching of ONNX models for on-device ML.
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

  static const _kokoroArchiveUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_0.tar.bz2';
  static const _kokoroModelName = 'kokoro-multi-lang-v1_0';

  static const _whisperArchiveUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-small.tar.bz2';
  static const _whisperModelName = 'sherpa-onnx-whisper-small';

  static const _vadUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx';

  // ── Kokoro TTS ─────────────────────────────────────────

  /// Check if Kokoro model is downloaded and extracted.
  Future<bool> isKokoroReady() async {
    final dir = await modelsDir;
    final modelDir = p.join(dir, _kokoroModelName);
    return await File(p.join(modelDir, 'model.onnx')).exists() &&
        await File(p.join(modelDir, 'voices.bin')).exists() &&
        await File(p.join(modelDir, 'tokens.txt')).exists();
  }

  /// Get paths to Kokoro model files. Returns null if not downloaded.
  Future<({String model, String voices, String tokens, String dataDir})?>
      getKokoroPaths() async {
    if (!await isKokoroReady()) return null;
    final dir = await modelsDir;
    final modelDir = p.join(dir, _kokoroModelName);
    return (
      model: p.join(modelDir, 'model.onnx'),
      voices: p.join(modelDir, 'voices.bin'),
      tokens: p.join(modelDir, 'tokens.txt'),
      dataDir: modelDir,
    );
  }

  /// Download and extract Kokoro TTS model archive.
  Future<void> downloadKokoro({
    void Function(String file, double progress)? onProgress,
  }) async {
    if (await isKokoroReady()) {
      onProgress?.call('kokoro', 1.0);
      return;
    }
    final dir = await modelsDir;
    onProgress?.call('kokoro-multi-lang-v1_0.tar.bz2', 0);
    await _downloadAndExtractArchive(
      _kokoroArchiveUrl,
      dir,
      (progress) =>
          onProgress?.call('kokoro-multi-lang-v1_0.tar.bz2', progress),
    );
  }

  // ── Whisper STT ────────────────────────────────────────

  /// Check if Whisper model is downloaded and extracted.
  Future<bool> isWhisperReady() async {
    final dir = await modelsDir;
    final modelDir = p.join(dir, _whisperModelName);
    return await File(p.join(modelDir, 'small-encoder.onnx')).exists() &&
        await File(p.join(modelDir, 'small-decoder.onnx')).exists() &&
        await File(p.join(modelDir, 'small-tokens.txt')).exists();
  }

  /// Get paths to Whisper model files. Returns null if not downloaded.
  Future<({String encoder, String decoder, String tokens})?>
      getWhisperPaths() async {
    if (!await isWhisperReady()) return null;
    final dir = await modelsDir;
    final modelDir = p.join(dir, _whisperModelName);
    return (
      encoder: p.join(modelDir, 'small-encoder.onnx'),
      decoder: p.join(modelDir, 'small-decoder.onnx'),
      tokens: p.join(modelDir, 'small-tokens.txt'),
    );
  }

  /// Download and extract Whisper STT model archive.
  Future<void> downloadWhisper({
    void Function(String file, double progress)? onProgress,
  }) async {
    if (await isWhisperReady()) {
      onProgress?.call('whisper', 1.0);
      return;
    }
    final dir = await modelsDir;
    onProgress?.call('sherpa-onnx-whisper-small.tar.bz2', 0);
    await _downloadAndExtractArchive(
      _whisperArchiveUrl,
      dir,
      (progress) =>
          onProgress?.call('sherpa-onnx-whisper-small.tar.bz2', progress),
    );
  }

  // ── MLX Parakeet STT ─────────────────────────────────────

  static const _mlxSttModelName = 'parakeet-tdt-0.6b-v3';

  /// Get path to the MLX STT model directory, or null if not downloaded.
  /// The model is downloaded automatically by mlx-audio-swift on first use,
  /// but we also support pre-downloading for offline use.
  Future<String?> getMlxSttModelPath() async {
    final dir = await modelsDir;
    final modelDir = p.join(dir, _mlxSttModelName);
    if (await Directory(modelDir).exists()) {
      return modelDir;
    }
    // Also check HuggingFace cache (mlx-audio-swift downloads here)
    return null;
  }

  /// Check if STT model is downloaded (Parakeet or Whisper fallback).
  Future<bool> isParakeetReady() async {
    // Check local models dir for Parakeet
    final dir = await modelsDir;
    final modelDir = p.join(dir, _mlxSttModelName);
    if (await Directory(modelDir).exists()) return true;

    // Check via platform channel (HuggingFace cache)
    if (await MlxSttChannel.instance.isModelDownloaded()) return true;

    // Fall back to Whisper readiness check
    return isWhisperReady();
  }

  /// Download Parakeet STT model via MLX platform channel.
  Future<void> downloadParakeet({
    void Function(String file, double progress)? onProgress,
  }) async {
    if (await isParakeetReady()) {
      onProgress?.call('parakeet-tdt-0.6b-v3', 1.0);
      return;
    }
    onProgress?.call('parakeet-tdt-0.6b-v3', 0);
    final success = await MlxSttChannel.instance.downloadModel(
      onProgress: (progress) {
        onProgress?.call('parakeet-tdt-0.6b-v3', progress);
      },
    );
    if (!success) {
      // MLX not available yet — fall back to Whisper download
      debugPrint('Parakeet download unavailable, falling back to Whisper');
      await downloadWhisper(onProgress: onProgress);
      return;
    }
  }

  // ── Silero VAD ─────────────────────────────────────────

  Future<bool> isVadReady() async {
    final dir = await modelsDir;
    return File(p.join(dir, 'silero_vad.onnx')).exists();
  }

  Future<String?> getVadPath() async {
    final dir = await modelsDir;
    final path = p.join(dir, 'silero_vad.onnx');
    return await File(path).exists() ? path : null;
  }

  Future<void> downloadVad({
    void Function(String file, double progress)? onProgress,
  }) async {
    final dir = await modelsDir;
    final path = p.join(dir, 'silero_vad.onnx');
    if (await File(path).exists()) {
      onProgress?.call('silero_vad.onnx', 1.0);
      return;
    }
    onProgress?.call('silero_vad.onnx', 0);
    await _downloadFile(_vadUrl, path, (progress) {
      onProgress?.call('silero_vad.onnx', progress);
    });
  }

  // ── Download all ───────────────────────────────────────

  /// Check if all required models are downloaded.
  Future<bool> isAllReady() async {
    final results = await Future.wait([
      isKokoroReady(),
      isParakeetReady(),
      isVadReady(),
    ]);
    return results.every((r) => r);
  }

  /// Download all models in parallel.
  Future<void> downloadAll({
    void Function(String model, String file, double progress)? onProgress,
  }) async {
    await Future.wait([
      downloadKokoro(
        onProgress: (file, progress) =>
            onProgress?.call('Kokoro TTS', file, progress),
      ),
      downloadParakeet(
        onProgress: (file, progress) =>
            onProgress?.call('Parakeet STT', file, progress),
      ),
      downloadVad(
        onProgress: (file, progress) =>
            onProgress?.call('VAD', file, progress),
      ),
    ]);
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
    void Function(double progress)? onProgress,
  ) async {
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

    // Extract in a separate isolate using streaming I/O
    debugPrint('Extracting archive to $destDir ...');
    onProgress?.call(0.85);
    try {
      await compute(_extractArchiveStreaming, (archivePath, destDir));
    } catch (e) {
      debugPrint('Archive extraction failed: $e');
      rethrow;
    }

    // Clean up archive
    try {
      await File(archivePath).delete();
    } catch (_) {}

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

    // Cleanup temp tar
    tempDir.deleteSync(recursive: true);
  }

  /// Download a single file with progress reporting.
  Future<void> _downloadFile(
    String url,
    String localPath,
    void Function(double progress)? onProgress,
  ) async {
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
            await _downloadFile(redirectUrl, localPath, onProgress);
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

      await for (final chunk in response) {
        sink.add(chunk);
        bytesReceived += chunk.length;
        if (contentLength > 0) {
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
