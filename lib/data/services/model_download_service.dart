import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

// crypto ships with the Flutter/Firebase dependency set already; it is used
// here only for the optional post-download SHA-256 check.
// ignore: depend_on_referenced_packages
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'debug_log_service.dart';
import 'tts_service.dart';

/// Represents a downloadable on-device AI model file.
class AiModel {
  final String id;
  final String name;
  final String description;
  final String sizeLabel;
  final int sizeBytes;
  final String downloadUrl;

  /// The filename to save as (e.g. 'kokoro-v1_0.safetensors').
  final String filename;

  /// Subdirectory within the models dir (e.g. 'kokoro_mlx').
  final String subdir;

  /// Exact expected size on disk. Set ONLY for artifacts pinned to an
  /// immutable URL (our own release assets), where any other size means a
  /// stale build or a partial download. Null when upstream can legitimately
  /// change the bytes — then only the truncation floor applies.
  final int? exactSizeBytes;

  /// Lowercase hex SHA-256 of the downloaded file, verified after download
  /// when present. Null means "unknown" — never a placeholder: a wrong hash
  /// would reject every good download.
  final String? sha256;

  const AiModel({
    required this.id,
    required this.name,
    required this.description,
    required this.sizeLabel,
    required this.sizeBytes,
    required this.downloadUrl,
    required this.filename,
    this.subdir = '',
    this.exactSizeBytes,
    this.sha256,
  });
}

/// Download status for a single model.
enum ModelStatus {
  notDownloaded,
  downloading,
  downloaded,
  error,
}

/// Progress info for an in-flight download.
class ModelDownloadState {
  final ModelStatus status;
  final double progress; // 0.0 – 1.0
  final String? errorMessage;

  const ModelDownloadState({
    this.status = ModelStatus.notDownloaded,
    this.progress = 0.0,
    this.errorMessage,
  });

  ModelDownloadState copyWith({
    ModelStatus? status,
    double? progress,
    String? errorMessage,
  }) {
    return ModelDownloadState(
      status: status ?? this.status,
      progress: progress ?? this.progress,
      errorMessage: errorMessage,
    );
  }
}

/// Service for downloading and managing on-device AI model files.
///
/// Uses native iOS background URLSession for downloads so they survive
/// screen sleep, app suspension, and even app termination.
///
/// Kokoro MLX model files are downloaded to Documents/models/kokoro_mlx/
/// to match the path expected by KokoroMLXService.swift.
class ModelDownloadService {
  ModelDownloadService._() {
    _setupNativeCallbacks();
  }
  static final instance = ModelDownloadService._();

  static const _channel =
      MethodChannel('com.lineguide/background_download');

  /// Registry of available models.
  static const List<AiModel> availableModels = [
    AiModel(
      id: 'kokoro_model',
      name: 'Kokoro TTS Model',
      description: 'Neural TTS model weights for on-device speech synthesis',
      // True bf16 (164 MB) — half the old 327 MB fp32. The mlx-community
      // "Kokoro-82M-bf16" repo is mislabeled (actually ships fp32); this is a
      // real bf16 cast, verified equivalent (acoustic-model output 0.99999
      // correlated with fp32). Saved under the same kokoro-v1_0.safetensors
      // filename the Swift loader expects.
      sizeLabel: '~164 MB',
      sizeBytes: 163588519,
      // Pinned release tag — the bytes never change, so the size is exact.
      exactSizeBytes: 163588519,
      // Verified against the published release asset 2026-07-03.
      sha256:
          '733bc3015578aad992f87863f8e6f90dbe00040bd3207d925b9ed693fa09e7bb',
      downloadUrl:
          'https://github.com/jasontitus/CastCircle/releases/download/kokoro-82m-bf16-v1/kokoro-v1_0-bf16.safetensors',
      filename: 'kokoro-v1_0.safetensors',
      subdir: 'kokoro_mlx',
    ),
    AiModel(
      id: 'kokoro_voices',
      name: 'Kokoro Voice Styles',
      description: 'Voice embeddings for 28+ distinct character voices',
      sizeLabel: '~14 MB',
      // Mirrored 2026-07-03 to our own immutable release tag. It used to be
      // fetched from a third party's MUTABLE main branch
      // (mlalma/KokoroTestApp), so whoever controlled that account could
      // silently change what every install downloaded — and the bytes are fed
      // straight into a hand-rolled binary parser (NpyzReader). Verified
      // byte-identical to the original at mirror time; all 27 voices the app
      // uses are present.
      sizeBytes: 14629684,
      exactSizeBytes: 14629684,
      sha256:
          '56dbfa2f2970af2e395397020393d368c5f441d09b3de4e9b77f6222e790f10f',
      downloadUrl:
          'https://github.com/jasontitus/CastCircle/releases/download/kokoro-82m-bf16-v1/voices.npz',
      filename: 'voices.npz',
      subdir: 'kokoro_mlx',
    ),
    // ── Live line-matching ASR (streaming Zipformer transducer) ──
    // Kroko-ASR community English model (CC-BY-SA, attribution in Settings →
    // About) converted for sherpa-onnx. Chosen over icefall en-20M by a
    // measured head-to-head on synthesized rehearsal lines (86% vs 66% word
    // match; en-20M also truncates utterance starts) — see
    // integration_test/asr_streaming_macos_test.dart. HF `main` is mutable, so
    // sizes/hashes are pinned: a silent upstream change fails verification
    // instead of feeding the recognizer unknown bytes.
    AiModel(
      id: 'live_asr_encoder',
      name: 'Live Matching — Encoder',
      description: 'Streaming speech encoder for live line matching',
      sizeLabel: '~70 MB',
      sizeBytes: 70092599,
      exactSizeBytes: 70092599,
      sha256:
          'd4881c57449d581e0770fd53fa66c2fdc6cd167d92ece7c715e603defc96d9d4',
      downloadUrl:
          'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06/resolve/main/encoder.onnx',
      filename: 'encoder.onnx',
      subdir: 'live_asr',
    ),
    AiModel(
      id: 'live_asr_decoder',
      name: 'Live Matching — Decoder',
      description: 'Streaming speech decoder for live line matching',
      sizeLabel: '~618 KB',
      sizeBytes: 617488,
      exactSizeBytes: 617488,
      sha256:
          '455ba38466fce8d5a57e7db68a323b684079ca4d9e1dd93a740d9b2429aae3b1',
      downloadUrl:
          'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06/resolve/main/decoder.onnx',
      filename: 'decoder.onnx',
      subdir: 'live_asr',
    ),
    AiModel(
      id: 'live_asr_joiner',
      name: 'Live Matching — Joiner',
      description: 'Streaming speech joiner for live line matching',
      sizeLabel: '~337 KB',
      sizeBytes: 336817,
      exactSizeBytes: 336817,
      sha256:
          'd406f616736350e2a7df3e39398b78eb2fc1a2ca6973a19d3853fa3227e25b52',
      downloadUrl:
          'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06/resolve/main/joiner.onnx',
      filename: 'joiner.onnx',
      subdir: 'live_asr',
    ),
    AiModel(
      id: 'live_asr_tokens',
      name: 'Live Matching — Tokens',
      description: 'Token vocabulary for live line matching',
      sizeLabel: '~6 KB',
      sizeBytes: 6310,
      exactSizeBytes: 6310,
      sha256:
          '396dbeb5f4858875690716084f54e90d339679d0ba3e6b5b584f3d7589254d2d',
      downloadUrl:
          'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06/resolve/main/tokens.txt',
      filename: 'tokens.txt',
      subdir: 'live_asr',
    ),
  ];

  final Map<String, ModelDownloadState> _states = {};
  final List<VoidCallback> _listeners = [];
  final _dlog = DebugLogService.instance;

  /// Current state for a model.
  ModelDownloadState getState(String modelId) {
    return _states[modelId] ?? const ModelDownloadState();
  }

  /// Register a listener for state changes.
  void addListener(VoidCallback listener) => _listeners.add(listener);

  /// Remove a listener.
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void _notify() {
    for (final l in _listeners) {
      l();
    }
  }

  /// Set up callbacks from native iOS for download progress/completion/error.
  void _setupNativeCallbacks() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onDownloadProgress':
          final args = call.arguments as Map;
          final modelId = args['modelId'] as String;
          final progress = (args['progress'] as num).toDouble();
          _states[modelId] = ModelDownloadState(
            status: ModelStatus.downloading,
            progress: progress,
          );
          _notify();
          break;

        case 'onDownloadComplete':
          final args = call.arguments as Map;
          final modelId = args['modelId'] as String;
          final size = args['size'] as int;
          debugPrint(
              'ModelDownload: $modelId complete (${(size / 1024 / 1024).toStringAsFixed(1)} MB)');

          // "The transfer finished" is not "the file is good": verify what
          // landed on disk before calling it downloaded, or a truncated /
          // wrong-revision file reads as installed while the feature it powers
          // silently falls back (TTS → system voices).
          final model =
              availableModels.where((m) => m.id == modelId).firstOrNull;
          final problem =
              model == null ? null : await _verifyDownload(model);
          if (problem != null) {
            _states[modelId] = ModelDownloadState(
              status: ModelStatus.error,
              errorMessage: 'Downloaded file failed verification ($problem) '
                  '— it was discarded, please download again',
            );
            _notify();
            _dlog.log(
                LogCategory.error,
                'ModelDownload: $modelId FAILED verification — $problem '
                '(file discarded)');
            break;
          }

          _states[modelId] = const ModelDownloadState(
            status: ModelStatus.downloaded,
            progress: 1.0,
          );
          _notify();

          // Auto-load Kokoro TTS engine once both model files are downloaded
          if (modelId == 'kokoro_model' || modelId == 'kokoro_voices') {
            _tryLoadKokoroIfReady();
          }
          break;

        case 'onDownloadError':
          final args = call.arguments as Map;
          final modelId = args['modelId'] as String;
          final error = args['error'] as String;
          _states[modelId] = ModelDownloadState(
            status: ModelStatus.error,
            errorMessage: error,
          );
          _notify();
          debugPrint('ModelDownload: $modelId failed: $error');
          _dlog.log(LogCategory.error, 'ModelDownload: $modelId failed: $error');
          break;
      }
    });
  }

  /// Why the file on disk for [model] can't be used, or null when it's good.
  ///
  /// The single source of truth for "is this model installed". Existence-only
  /// checks and the size check in [isKokoroReady] used to disagree: Settings
  /// showed a green "Downloaded" tile (whose only action was Delete) for a
  /// truncated or stale file while TTS quietly fell back to system voices.
  static String? fileProblem(AiModel model, File file) {
    if (!file.existsSync()) return 'file missing';
    final actual = file.lengthSync();

    // Exact match where the URL is immutable — catches BOTH a partial download
    // and a stale build (the old 327 MB fp32 Kokoro weights, which survive app
    // updates in Documents and would otherwise be kept forever).
    final exact = model.exactSizeBytes;
    if (exact != null && actual != exact) {
      return 'size $actual B != expected $exact B';
    }

    // Mutable upstreams only get a truncation floor: their real size drifts,
    // and a floor that trips on a legitimate 5% shrink would re-download the
    // same file forever. Half the expected size still catches the failures
    // that actually happen — empty files, aborted transfers, HTML error pages.
    if (exact == null && model.sizeBytes > 0 && actual < model.sizeBytes ~/ 2) {
      return 'size $actual B is far below the expected ${model.sizeLabel}';
    }
    return null;
  }

  /// Check which models are already downloaded on disk.
  Future<void> refreshDownloadedStatus() async {
    for (final model in availableModels) {
      // Never stomp an in-flight download's progress state.
      if (_states[model.id]?.status == ModelStatus.downloading) continue;

      final file = File(await _filePath(model));
      final problem = fileProblem(model, file);
      if (problem == null) {
        _states[model.id] = const ModelDownloadState(
          status: ModelStatus.downloaded,
          progress: 1.0,
        );
      } else if (file.existsSync()) {
        // Present but unusable — say so loudly and offer the download again
        // (the error tile shows the message and a Download button).
        _dlog.log(LogCategory.error,
            'ModelDownload: ${model.id} present but unusable — $problem');
        _states[model.id] = ModelDownloadState(
          status: ModelStatus.error,
          errorMessage:
              'Installed file is incomplete or outdated ($problem) — '
              'download again',
        );
      } else {
        // Reset error/stuck states on refresh — allow retry
        final current = _states[model.id];
        if (current != null) {
          _states[model.id] = const ModelDownloadState();
        }
      }
    }
    // Clean up any leftover .tmp files from failed downloads
    await _cleanupTmpFiles();
    await _cleanupRetiredModels();
    _notify();
  }

  /// Delete model directories for features that no longer exist. Users who
  /// downloaded the retired Parakeet STT model are carrying ~2.5 GB of dead
  /// weight in Documents that survives app updates.
  Future<void> _cleanupRetiredModels() async {
    for (final subdir in const ['parakeet_stt']) {
      try {
        final appDir = await getApplicationDocumentsDirectory();
        final dir = Directory(p.join(appDir.path, 'models', subdir));
        if (dir.existsSync()) {
          await dir.delete(recursive: true);
          _dlog.log(LogCategory.general,
              'ModelDownload: deleted retired model dir $subdir');
        }
      } catch (e) {
        _dlog.log(LogCategory.error,
            'ModelDownload: failed to delete retired model dir $subdir: $e');
      }
    }
  }

  /// Post-download integrity check. Size first (cheap), then SHA-256 when the
  /// descriptor pins one. A file that fails is DELETED — leaving it behind is
  /// what produced the "installed but broken, only Delete offered" dead end.
  Future<String?> _verifyDownload(AiModel model) async {
    final file = File(await _filePath(model));
    var problem = fileProblem(model, file);

    final expected = model.sha256;
    if (problem == null && expected != null) {
      try {
        // Streamed — these files run to gigabytes.
        final digest = await crypto.sha256.bind(file.openRead()).first;
        final actual = digest.toString().toLowerCase();
        if (actual != expected.toLowerCase()) {
          problem = 'sha256 $actual != expected ${expected.toLowerCase()}';
        }
      } catch (e) {
        problem = 'sha256 could not be computed: $e';
      }
    }

    if (problem != null && file.existsSync()) {
      try {
        await file.delete();
      } catch (e) {
        _dlog.log(LogCategory.error,
            'ModelDownload: could not delete the bad ${model.id} file: $e');
      }
    }
    return problem;
  }

  /// Auto-load Kokoro TTS after both model files finish downloading.
  Future<void> _tryLoadKokoroIfReady() async {
    if (await isKokoroReady()) {
      debugPrint('ModelDownload: Both Kokoro files ready, loading TTS engine');
      await TtsService.instance.tryLoadKokoro();
    }
  }

  /// Whether all Kokoro files are downloaded AND usable.
  Future<bool> isKokoroReady() => _groupReady('kokoro_mlx', 'Kokoro');

  /// Whether all live-matching ASR files are downloaded AND usable.
  Future<bool> isLiveAsrReady() => _groupReady('live_asr', 'Live ASR');

  /// Path to the live-matching ASR model directory, or null if not ready.
  Future<String?> getLiveAsrModelDir() async {
    if (!await isLiveAsrReady()) return null;
    final appDir = await getApplicationDocumentsDirectory();
    return p.join(appDir.path, 'models', 'live_asr');
  }

  /// Download every live-matching ASR file that isn't already good.
  Future<void> downloadLiveAsr() async {
    // Concurrent within the group: the Dart-fallback path (Android) blocks
    // per file, so sequentially the small decoder/joiner/tokens files queued
    // behind the big encoder. Progress is bytes-weighted across per-file
    // states, so the setup bar stays honest either way.
    final needed = <AiModel>[];
    for (final m in availableModels) {
      if (m.subdir != 'live_asr') continue;
      if (fileProblem(m, File(await _filePath(m))) == null) continue;
      needed.add(m);
    }
    await Future.wait(needed.map(download));
  }

  /// Shared readiness check over every model in [subdir] — same [fileProblem]
  /// the Settings tiles use, so the two can never disagree.
  Future<bool> _groupReady(String subdir, String label) async {
    for (final model in availableModels) {
      if (model.subdir != subdir) continue;
      final file = File(await _filePath(model));
      final problem = fileProblem(model, file);
      if (problem == null) continue;
      // A missing file is unremarkable (not downloaded yet); a file that is
      // THERE but wrong is a surprise the user must be able to see in the log.
      if (file.existsSync()) {
        _dlog.log(LogCategory.error,
            'ModelDownload: $label not ready — ${model.id}: $problem');
      }
      return false;
    }
    return true;
  }

  /// Download a model file using native iOS background URLSession.
  Future<void> download(AiModel model) async {
    if (model.downloadUrl.isEmpty) {
      _states[model.id] = const ModelDownloadState(
        status: ModelStatus.error,
        errorMessage: 'Model not yet available for download',
      );
      _notify();
      return;
    }

    // Reset state and clean up any leftover .tmp file
    _states[model.id] = const ModelDownloadState(
      status: ModelStatus.downloading,
      progress: 0.0,
    );
    _notify();

    try {
      final outPath = await _filePath(model);

      // Clean up .tmp file from previous failed download
      final tmpFile = File('$outPath.tmp');
      if (tmpFile.existsSync()) {
        await tmpFile.delete();
      }

      // Create destination directory
      await Directory(p.dirname(outPath)).create(recursive: true);

      // Preflight free space. A 2.5 GB model that runs the volume dry fails at
      // 99% — after burning the user's data — and can take their photos/other
      // apps' storage down with it on the way.
      final free = _freeDiskSpaceBytes(p.dirname(outPath));
      final needed = model.sizeBytes + _diskHeadroomBytes;
      if (free != null && free < needed) {
        final message =
            'Not enough free space for ${model.name}: needs ${_mb(needed)}, '
            '${_mb(free)} available. Free up some space and try again.';
        _states[model.id] = ModelDownloadState(
          status: ModelStatus.error,
          errorMessage: message,
        );
        _notify();
        _dlog.log(LogCategory.error, 'ModelDownload: $message');
        return;
      }
      if (free == null) {
        // Not a failure — this platform gives us no way to ask (see
        // [_freeDiskSpaceBytes]). Recorded so a later out-of-space download
        // failure isn't a mystery.
        debugPrint('ModelDownload: free space unknown on this platform — '
            'starting ${model.id} without a space preflight');
      }

      // Start native background download. Android has no native downloader
      // (the channel is a stub that errors) — fall back to a Dart-side
      // streamed download there; verification is identical either way.
      try {
        await _channel.invokeMethod('startDownload', {
          'modelId': model.id,
          'url': model.downloadUrl,
          'destinationPath': outPath,
        });
        debugPrint(
            'ModelDownload: started background download for ${model.id}');
      } on PlatformException catch (e) {
        if (e.code != 'UNAVAILABLE' || !_dartDownloadable(model)) rethrow;
        await _dartDownload(model, outPath);
      } on MissingPluginException {
        if (!_dartDownloadable(model)) rethrow;
        await _dartDownload(model, outPath);
      }
    } catch (e) {
      _states[model.id] = ModelDownloadState(
        status: ModelStatus.error,
        errorMessage: e.toString(),
      );
      _notify();
      debugPrint('ModelDownload: ${model.id} failed to start: $e');
    }
  }

  /// Whether [model] may use the Dart fallback when the native downloader is
  /// unavailable (i.e. on Android). Only the ASR files: letting the fallback
  /// serve everything would turn the Kokoro Settings tiles on Android into
  /// multi-GB downloads of MLX models Android can't run.
  static bool _dartDownloadable(AiModel model) => model.subdir == 'live_asr';

  /// Dart-side streamed download for platforms without a native downloader
  /// (Android). Runs in-process, so it doesn't survive app termination — fine
  /// for the ~70 MB ASR files; the multi-GB MLX models are Apple-only anyway.
  /// Feeds the same states and the same post-download verification as the
  /// native path.
  Future<void> _dartDownload(AiModel model, String outPath) async {
    debugPrint('ModelDownload: Dart fallback download for ${model.id}');
    final tmpFile = File('$outPath.tmp');
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(model.downloadUrl));
      final res = await req.close();
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode} for ${model.downloadUrl}');
      }
      final total = res.contentLength > 0 ? res.contentLength : model.sizeBytes;
      final sink = tmpFile.openWrite();
      var received = 0;
      var lastNotified = 0;
      try {
        await for (final chunk in res) {
          sink.add(chunk);
          received += chunk.length;
          // Throttle UI updates to every ~1 MB.
          if (total > 0 && received - lastNotified > 1024 * 1024) {
            lastNotified = received;
            _states[model.id] = ModelDownloadState(
              status: ModelStatus.downloading,
              progress: (received / total).clamp(0.0, 0.99),
            );
            _notify();
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      await tmpFile.rename(outPath);

      final problem = await _verifyDownload(model);
      if (problem != null) {
        _states[model.id] = ModelDownloadState(
          status: ModelStatus.error,
          errorMessage: 'Downloaded file failed verification ($problem) '
              '— it was discarded, please download again',
        );
        _dlog.log(LogCategory.error,
            'ModelDownload: ${model.id} FAILED verification — $problem');
      } else {
        _states[model.id] = const ModelDownloadState(
          status: ModelStatus.downloaded,
          progress: 1.0,
        );
      }
      _notify();
    } catch (e) {
      try {
        if (tmpFile.existsSync()) await tmpFile.delete();
      } catch (_) {}
      _states[model.id] = ModelDownloadState(
        status: ModelStatus.error,
        errorMessage: e.toString(),
      );
      _notify();
      _dlog.log(
          LogCategory.error, 'ModelDownload: ${model.id} Dart download failed: $e');
    } finally {
      client.close();
    }
  }

  /// Download all available models.
  Future<void> downloadAll() async {
    for (final m in availableModels) {
      if (m.downloadUrl.isNotEmpty) {
        await download(m);
      }
    }
  }

  /// Delete a downloaded model file.
  Future<void> delete(String modelId) async {
    final model = availableModels.where((m) => m.id == modelId).firstOrNull;
    if (model != null) {
      final path = await _filePath(model);
      final file = File(path);
      if (file.existsSync()) await file.delete();
      // Also clean up any .tmp file
      final tmpFile = File('$path.tmp');
      if (tmpFile.existsSync()) await tmpFile.delete();
    }
    _states[modelId] = const ModelDownloadState();
    _notify();
  }

  /// Delete all Kokoro model files.
  Future<void> deleteKokoro() async {
    final dir = await _kokoroDir();
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
    for (final model in availableModels) {
      if (model.subdir == 'kokoro_mlx') {
        _states[model.id] = const ModelDownloadState();
      }
    }
    _notify();
  }

  /// Full path where a model file will be saved.
  // Cached once — the documents dir never changes during a run, and
  // resolving it is a platform-channel round trip that used to repeat per
  // model on every status refresh.
  String? _docsPath;

  Future<String> _filePath(AiModel model) async {
    final docs =
        _docsPath ??= (await getApplicationDocumentsDirectory()).path;
    if (model.subdir.isNotEmpty) {
      return p.join(docs, 'models', model.subdir, model.filename);
    }
    return p.join(docs, 'models', model.filename);
  }

  Future<Directory> _kokoroDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    return Directory(p.join(appDir.path, 'models', 'kokoro_mlx'));
  }

  static String _mb(int bytes) =>
      '${(bytes / 1024 / 1024).toStringAsFixed(0)} MB';

  /// Remove leftover .tmp files from failed downloads.
  Future<void> _cleanupTmpFiles() async {
    for (final model in availableModels) {
      final path = await _filePath(model);
      final tmpFile = File('$path.tmp');
      if (tmpFile.existsSync()) {
        try {
          await tmpFile.delete();
          debugPrint('ModelDownload: cleaned up ${model.id}.tmp');
        } catch (e) {
          debugPrint('ModelDownload: failed to clean ${model.id}.tmp: $e');
        }
      }
    }
  }
}

// ── Free disk space ──────────────────────────────────────
//
// Slack left on top of the model size: the volume must not be driven to
// literally zero, and the native downloader stages the transfer before moving
// it into place.
const _diskHeadroomBytes = 100 * 1024 * 1024;

typedef _StatvfsNative = Int32 Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _StatvfsDart = int Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _MallocNative = Pointer<Uint8> Function(IntPtr);
typedef _MallocDart = Pointer<Uint8> Function(int);
typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Uint8>);

/// Bytes available on the volume holding [path], or null when this platform
/// can't be asked.
///
/// Dart has no free-space API and the download plugin exposes no channel for
/// it, so this calls POSIX `statvfs(3)` out of libSystem. Darwin only: the
/// field offsets below are the Darwin layout (`fsblkcnt_t` is 32-bit there,
/// 64-bit on Linux/bionic), and iOS + macOS are the only platforms these MLX
/// models download to. Verified against `df -k` on macOS. Anywhere else — or
/// on any error — this returns null and the caller skips the preflight rather
/// than acting on a number it can't trust.
int? _freeDiskSpaceBytes(String path) {
  if (!Platform.isIOS && !Platform.isMacOS) return null;
  try {
    final lib = DynamicLibrary.process();
    final statvfs = lib.lookupFunction<_StatvfsNative, _StatvfsDart>('statvfs');
    final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
    final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');

    final pathBytes = utf8.encode(path);
    final cPath = malloc(pathBytes.length + 1);
    const bufBytes = 128; // struct statvfs is 64 B on Darwin — room to spare
    final buf = malloc(bufBytes);
    if (cPath.address == 0 || buf.address == 0) return null;
    try {
      cPath.asTypedList(pathBytes.length + 1)
        ..setAll(0, pathBytes)
        ..[pathBytes.length] = 0;
      buf.asTypedList(bufBytes).fillRange(0, bufBytes, 0);
      if (statvfs(cPath, buf) != 0) return null;

      final asU64 = buf.cast<Uint64>();
      final asU32 = buf.cast<Uint32>();
      final frsize = asU64[1]; // offset 8:  unsigned long f_frsize
      final blocks = asU32[4]; // offset 16: fsblkcnt_t    f_blocks
      final bavail = asU32[6]; // offset 24: fsblkcnt_t    f_bavail
      // Sanity-check the layout rather than trust it: garbage here would block
      // a legitimate download with a bogus "not enough space".
      if (frsize <= 0 || blocks <= 0 || bavail > blocks) return null;
      return bavail * frsize;
    } finally {
      free(cPath);
      free(buf);
    }
  } catch (e) {
    debugPrint('ModelDownload: free-space query failed: $e');
    return null;
  }
}
