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

  /// Begin a native background-task assertion so a long cleanup survives a
  /// brief app-switch (iOS still caps the grace window — minutes-long compute
  /// can't run fully backgrounded). Best-effort; no-op without the plugin.
  Future<void> beginBackgroundExecution(String reason) async {
    try {
      await _channel.invokeMethod<void>('beginBackground', {'reason': reason});
    } on PlatformException catch (e) {
      debugPrint('OnDeviceLlm: beginBackground failed: ${e.message}');
    } on MissingPluginException {
      // No native plugin on this platform.
    }
  }

  /// End the background-task assertion started by [beginBackgroundExecution].
  Future<void> endBackgroundExecution() async {
    try {
      await _channel.invokeMethod<void>('endBackground');
    } on PlatformException catch (e) {
      debugPrint('OnDeviceLlm: endBackground failed: ${e.message}');
    } on MissingPluginException {
      // No native plugin on this platform.
    }
  }

  /// Post a local notification (e.g. "cleanup complete"). Requests
  /// authorization on first use. Best-effort; silently no-ops if the user
  /// declined notifications or the plugin is unavailable.
  Future<void> postLocalNotification({
    required String title,
    required String body,
  }) async {
    try {
      await _channel.invokeMethod<void>('notify', {
        'title': title,
        'body': body,
      });
    } on PlatformException catch (e) {
      debugPrint('OnDeviceLlm: notify failed: ${e.message}');
    } on MissingPluginException {
      // No native plugin on this platform.
    }
  }

  @override
  Future<List<String?>> generateBatch(List<String> prompts) async {
    if (!_initialized) return List<String?>.filled(prompts.length, null);
    final log = DebugLogService.instance;
    try {
      log.log(LogCategory.ai, 'generateBatch (N=${prompts.length})…');
      final out = await _channel.invokeMethod<List<dynamic>>('generateBatch', {
        'prompts': prompts,
      }).timeout(const Duration(seconds: 600));
      final results = (out ?? const [])
          .map((e) => e as String?)
          .toList(growable: false);
      log.log(LogCategory.ai, 'generateBatch returned ${results.length} results');
      // Pad/truncate defensively so the caller always gets one slot per prompt.
      if (results.length != prompts.length) {
        return List<String?>.generate(
            prompts.length, (i) => i < results.length ? results[i] : null);
      }
      return results;
    } on TimeoutException {
      log.logError(LogCategory.ai, 'generateBatch timed out (>600s)');
      return List<String?>.filled(prompts.length, null);
    } on PlatformException catch (e) {
      if (e.code == 'NOT_IMPLEMENTED') {
        // No batched runtime (Foundation Models) → fall back to sequential.
        final out = <String?>[];
        for (final p in prompts) {
          out.add(await generate(prompt: p));
        }
        return out;
      }
      log.logError(LogCategory.ai, 'generateBatch failed (${e.code}): ${e.message}', e);
      return List<String?>.filled(prompts.length, null);
    } on MissingPluginException {
      return List<String?>.filled(prompts.length, null);
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
