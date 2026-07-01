import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'debug_log_service.dart';

/// Platform channel for native real-time speech recognition.
///
/// Backed by the OS recognizer on each platform — Apple SFSpeechRecognizer on
/// iOS/macOS (AppleSttPlugin) and Android SpeechRecognizer (AndroidSttPlugin) —
/// with vocabulary hinting: words from [contextualStrings] are boosted so the
/// recognizer prefers them over phonetically similar alternatives.
class SttChannel {
  SttChannel._();
  static final instance = SttChannel._();

  // Wire name kept as the historical 'apple_stt' so the existing native plugins
  // (AppleSttPlugin / AndroidSttPlugin) keep matching — it's an internal
  // identifier, not user-visible.
  static const _channel = MethodChannel('com.lineguide/apple_stt');

  bool _initialized = false;
  bool _listening = false;

  bool get isInitialized => _initialized;
  bool get isListening => _listening;

  void Function(String text, bool isFinal)? _onResult;
  void Function()? _onDone;

  /// Called with raw mic input level (RMS, 0..1) while listening.
  /// Survives across listen sessions — set once by the consumer.
  void Function(double level)? onLevel;

  /// Initialize and request speech recognition permission.
  ///
  /// [locale] — BCP-47 locale for the speech recognizer (e.g. "en-US", "en-GB").
  Future<bool> initialize({String locale = 'en-US'}) async {
    // Set up method call handler for callbacks from native
    _channel.setMethodCallHandler(_handleCallback);

    try {
      final result = await _channel.invokeMethod<bool>('initialize', {
        'locale': locale,
      });
      _initialized = result ?? false;
      if (_initialized) {
        debugPrint('STT: initialize($locale) = true');
      } else {
        // Permission denied / recognizer unavailable — must be visible in
        // release debug logs, not just debugPrint.
        DebugLogService.instance.logError(LogCategory.stt,
            'STT initialize($locale) returned false — permission denied or '
            'recognizer unavailable');
      }
      return _initialized;
    } on PlatformException catch (e) {
      DebugLogService.instance
          .logError(LogCategory.stt, 'STT initialize failed', e);
      return false;
    } on MissingPluginException {
      DebugLogService.instance.logError(
          LogCategory.stt, 'STT platform channel not available on this platform');
      return false;
    }
  }

  /// Start listening with optional vocabulary hints.
  ///
  /// [contextualStrings] — words/phrases to boost in recognition.
  /// [onResult] — called with (text, isFinal) as words are recognized.
  /// [onDone] — called when recognition ends.
  /// [onDevice] — force on-device recognition (default true).
  Future<bool> listen({
    List<String>? contextualStrings,
    required void Function(String text, bool isFinal) onResult,
    void Function()? onDone,
    bool onDevice = false,
  }) async {
    _onResult = onResult;
    _onDone = onDone;

    try {
      final result = await _channel.invokeMethod<bool>('listen', {
        if (contextualStrings != null && contextualStrings.isNotEmpty)
          'contextualStrings': contextualStrings,
        'onDevice': onDevice,
      });
      _listening = result ?? false;
      return _listening;
    } on PlatformException catch (e) {
      DebugLogService.instance.logError(LogCategory.stt, 'STT listen failed', e);
      _listening = false;
      return false;
    } on MissingPluginException {
      DebugLogService.instance.logError(
          LogCategory.stt, 'STT listen: platform channel not available');
      _listening = false;
      return false;
    }
  }

  /// Stop listening.
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException catch (e) {
      debugPrint('STT: stop failed: ${e.message}');
    } on MissingPluginException {
      // Not available on this platform
    }
    _listening = false;
  }

  /// Handle callbacks from native side.
  Future<void> _handleCallback(MethodCall call) async {
    switch (call.method) {
      case 'onResult':
        final args = call.arguments as Map;
        final text = args['text'] as String? ?? '';
        final isFinal = args['isFinal'] as bool? ?? false;
        _onResult?.call(text, isFinal);
        if (isFinal) {
          _listening = false;
        }
      case 'onDone':
        _listening = false;
        _onDone?.call();
        _onResult = null;
        _onDone = null;
      case 'onError':
        final error = call.arguments as String?;
        DebugLogService.instance
            .logError(LogCategory.stt, 'STT native error: $error');
      case 'onLevel':
        final level = (call.arguments as num?)?.toDouble() ?? 0.0;
        onLevel?.call(level);
    }
  }

  /// Start recording audio alongside STT (same mic tap).
  /// Audio is saved to [path] as .m4a.
  Future<bool> startRecording(String path) async {
    try {
      return await _channel.invokeMethod<bool>('startRecording', {
        'path': path,
      }) ?? false;
    } on PlatformException catch (e) {
      DebugLogService.instance
          .logError(LogCategory.stt, 'STT startRecording failed', e);
      return false;
    } on MissingPluginException {
      DebugLogService.instance.logError(
          LogCategory.stt, 'STT startRecording: channel not available');
      return false;
    }
  }

  /// Stop recording and finalize the audio file.
  /// Returns {path, durationMs} or null if not recording.
  Future<Map<String, dynamic>?> stopRecording() async {
    try {
      final result = await _channel.invokeMethod<Map>('stopRecording');
      if (result == null) return null;
      return Map<String, dynamic>.from(result);
    } on PlatformException catch (e) {
      DebugLogService.instance
          .logError(LogCategory.stt, 'STT stopRecording failed', e);
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> dispose() async {
    await stop();
    _onResult = null;
    _onDone = null;
    onLevel = null;
  }
}
