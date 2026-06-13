import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ai_script_structuring_service.dart';
import 'debug_log_service.dart';

/// Platform channel to an on-device multimodal LLM used for script
/// structuring (recommended model: **Gemma 4 E2B**, Apache 2.0, <2 GB).
///
/// Mirrors [MlxSttChannel]: it talks to a native plugin over a
/// [MethodChannel] and degrades gracefully (reports unavailable) wherever the
/// plugin isn't wired — Android without AI Edge, the iOS simulator, web, or a
/// build where the model hasn't been downloaded yet.
///
/// Native wiring (not yet implemented — this is the prototype seam):
///   * iOS/macOS — load a Gemma 4 MLX checkpoint with the existing mlx-swift
///     stack (the same one powering [MlxSttChannel]) and expose
///     `initialize` / `generate` on the `com.lineguide/on_device_llm` channel.
///   * Android — use the Google AI Edge MediaPipe `LlmInference` API with a
///     Gemma 4 `.litertlm` checkpoint; multimodal prompting accepts image +
///     text, so the `imagePaths` argument maps to MediaPipe image inputs.
///
/// Until a native side answers the channel, [isAvailable] stays false and the
/// import pipeline simply keeps using the heuristic parser.
class OnDeviceLlmChannel implements OnDeviceLlmProvider {
  OnDeviceLlmChannel._() {
    // The native plugin pushes progress messages (model load/generate steps)
    // here so a long-running call is visible live — both in the debug log and
    // (via [progress]) in the Script AI Debug screen.
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onLog') {
        final msg = (call.arguments as String?) ?? '';
        DebugLogService.instance.log(LogCategory.ai, msg);
        progress.value = msg;
      }
      return null;
    });
  }
  static final OnDeviceLlmChannel instance = OnDeviceLlmChannel._();

  /// Latest native progress message, for live display in the debug screen.
  final ValueNotifier<String> progress = ValueNotifier<String>('');

  static const _channel = MethodChannel('com.lineguide/on_device_llm');

  bool _initialized = false;

  /// Diagnostics from the last [initialize], surfaced by the LLM debug screen.
  String lastRuntime = 'unknown'; // gemma | foundation | none
  String lastError = '';

  @override
  bool get isAvailable => _initialized;

  /// Load the model from a local checkpoint path. Returns true on success.
  /// Safe to call on platforms without the plugin (returns false).
  Future<bool> initialize(String modelPath) async {
    final log = DebugLogService.instance;
    try {
      log.log(LogCategory.ai,
          'initialize (loading on-device model, may take a moment)…');
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'initialize',
        {'modelPath': modelPath},
      );
      final ready = res?['ready'] == true;
      final runtime = (res?['runtime'] as String?) ?? 'unknown';
      final error = (res?['error'] as String?) ?? '';
      _initialized = ready;
      lastRuntime = runtime;
      lastError = error;
      if (ready) {
        log.log(LogCategory.ai,
            'ready — runtime=$runtime${error.isNotEmpty ? " (gemma: $error)" : ""}');
      } else {
        log.logError(LogCategory.ai, 'not ready — runtime=$runtime: $error');
      }
      return _initialized;
    } on PlatformException catch (e) {
      log.logError(LogCategory.ai, 'initialize failed: ${e.message}', e);
      return false;
    } on MissingPluginException {
      log.log(LogCategory.ai, 'plugin not available on this platform');
      return false;
    }
  }

  @override
  Future<String?> generate({
    required String prompt,
    List<String> imagePaths = const [],
  }) async {
    if (!_initialized) return null;
    final log = DebugLogService.instance;
    try {
      log.log(LogCategory.ai,
          'generate (promptChars=${prompt.length}, images=${imagePaths.length})…');
      final out = await _channel.invokeMethod<String>('generate', {
        'prompt': prompt,
        'imagePaths': imagePaths,
      }).timeout(const Duration(seconds: 120));
      log.log(LogCategory.ai, 'generate returned ${out?.length ?? 0} chars');
      return out;
    } on TimeoutException {
      log.logError(LogCategory.ai,
          'generate timed out (>120s) — model load or inference stuck/too slow');
      return null;
    } on PlatformException catch (e) {
      log.logError(LogCategory.ai, 'generate failed (${e.code}): ${e.message}', e);
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Free the model's memory (the checkpoint is large). Best-effort.
  Future<void> dispose() async {
    if (!_initialized) return;
    try {
      await _channel.invokeMethod<void>('dispose');
    } on PlatformException catch (e) {
      debugPrint('OnDeviceLlm: dispose failed: ${e.message}');
    } on MissingPluginException {
      // No native plugin to dispose.
    } finally {
      _initialized = false;
    }
  }
}
