import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// Manages downloading and caching of ONNX models for on-device ML.
///
/// Models are downloaded from HuggingFace/GitHub on first use and cached
/// in the app's documents directory under `models/`.
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

  // ── Model definitions ──────────────────────────────────

  static const _kokoroBaseUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models';
  static const _kokoroModelName = 'kokoro-multi-lang-v1_0';

  static const _whisperBaseUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models';
  static const _whisperModelName = 'sherpa-onnx-whisper-small';

  static const _vadBaseUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models';

  // ── Kokoro TTS ─────────────────────────────────────────

  /// Files needed for Kokoro TTS.
  List<({String url, String localPath})> _kokoroFiles(String dir) {
    final base = '$_kokoroBaseUrl/$_kokoroModelName';
    final modelDir = p.join(dir, _kokoroModelName);
    return [
      (
        url: '$base/model.onnx',
        localPath: p.join(modelDir, 'model.onnx'),
      ),
      (
        url: '$base/voices.bin',
        localPath: p.join(modelDir, 'voices.bin'),
      ),
      (
        url: '$base/tokens.txt',
        localPath: p.join(modelDir, 'tokens.txt'),
      ),
    ];
  }

  /// Check if Kokoro model is downloaded.
  Future<bool> isKokoroReady() async {
    final dir = await modelsDir;
    final files = _kokoroFiles(dir);
    return _allFilesExist(files);
  }

  /// Get paths to Kokoro model files. Returns null if not downloaded.
  Future<({String model, String voices, String tokens, String dataDir})?> getKokoroPaths() async {
    final dir = await modelsDir;
    final modelDir = p.join(dir, _kokoroModelName);
    final files = _kokoroFiles(dir);

    if (!await _allFilesExist(files)) return null;

    return (
      model: files[0].localPath,
      voices: files[1].localPath,
      tokens: files[2].localPath,
      dataDir: modelDir,
    );
  }

  /// Download Kokoro TTS model files.
  Future<void> downloadKokoro({
    void Function(String file, double progress)? onProgress,
  }) async {
    final dir = await modelsDir;
    final files = _kokoroFiles(dir);
    for (final file in files) {
      final name = p.basename(file.localPath);
      onProgress?.call(name, 0);
      await _downloadFile(file.url, file.localPath, (progress) {
        onProgress?.call(name, progress);
      });
    }
  }

  // ── Whisper STT ────────────────────────────────────────

  List<({String url, String localPath})> _whisperFiles(String dir) {
    final base = '$_whisperBaseUrl/$_whisperModelName';
    final modelDir = p.join(dir, _whisperModelName);
    return [
      (
        url: '$base/encoder.onnx',
        localPath: p.join(modelDir, 'encoder.onnx'),
      ),
      (
        url: '$base/decoder.onnx',
        localPath: p.join(modelDir, 'decoder.onnx'),
      ),
      (
        url: '$base/tokens.txt',
        localPath: p.join(modelDir, 'tokens.txt'),
      ),
    ];
  }

  Future<bool> isWhisperReady() async {
    final dir = await modelsDir;
    return _allFilesExist(_whisperFiles(dir));
  }

  Future<({String encoder, String decoder, String tokens})?> getWhisperPaths() async {
    final dir = await modelsDir;
    final files = _whisperFiles(dir);
    if (!await _allFilesExist(files)) return null;
    return (
      encoder: files[0].localPath,
      decoder: files[1].localPath,
      tokens: files[2].localPath,
    );
  }

  Future<void> downloadWhisper({
    void Function(String file, double progress)? onProgress,
  }) async {
    final dir = await modelsDir;
    final files = _whisperFiles(dir);
    for (final file in files) {
      final name = p.basename(file.localPath);
      onProgress?.call(name, 0);
      await _downloadFile(file.url, file.localPath, (progress) {
        onProgress?.call(name, progress);
      });
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
    final url = '$_vadBaseUrl/silero_vad.onnx';
    final path = p.join(dir, 'silero_vad.onnx');
    onProgress?.call('silero_vad.onnx', 0);
    await _downloadFile(url, path, (progress) {
      onProgress?.call('silero_vad.onnx', progress);
    });
  }

  // ── Download all ───────────────────────────────────────

  /// Check if all required models are downloaded.
  Future<bool> isAllReady() async {
    final results = await Future.wait([
      isKokoroReady(),
      isWhisperReady(),
      isVadReady(),
    ]);
    return results.every((r) => r);
  }

  /// Download all models. Returns total bytes downloaded.
  Future<void> downloadAll({
    void Function(String model, String file, double progress)? onProgress,
  }) async {
    await downloadKokoro(
      onProgress: (file, progress) => onProgress?.call('Kokoro TTS', file, progress),
    );
    await downloadWhisper(
      onProgress: (file, progress) => onProgress?.call('Whisper STT', file, progress),
    );
    await downloadVad(
      onProgress: (file, progress) => onProgress?.call('VAD', file, progress),
    );
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

  Future<bool> _allFilesExist(
      List<({String url, String localPath})> files) async {
    for (final file in files) {
      if (!await File(file.localPath).exists()) return false;
    }
    return true;
  }

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
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();

      if (response.statusCode != 200) {
        // Follow redirects for GitHub releases
        if (response.statusCode == 302 || response.statusCode == 301) {
          final redirectUrl = response.headers.value('location');
          if (redirectUrl != null) {
            await response.drain<void>();
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
      debugPrint('Downloaded: ${p.basename(localPath)} (${(bytesReceived / 1024 / 1024).toStringAsFixed(1)} MB)');
    } finally {
      client.close();
    }
  }
}
