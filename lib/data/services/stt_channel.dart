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
  int? _activeSessionId;
  int? _activeLevelSessionId;

  /// Called with raw mic input level (RMS, 0..1) while listening.
  /// Survives across listen sessions — set once by the consumer.
  void Function(double level)? onLevel;

  /// Called with raw 16 kHz mono 16-bit LE PCM chunks (~100 ms each) while a
  /// recording is in progress. Android only: the native side owns the mic and
  /// fans the audio out so an on-device recognizer can run off the same tap
  /// (see docs/ANDROID_LIVE_MATCHING.md). Null when nobody is listening —
  /// chunks are simply dropped.
  void Function(Uint8List pcm)? onPcm;

  /// Called when the OS audio session is interrupted (phone call, Siri,
  /// alarm) or the input route is lost (headphones unplugged). `began` is
  /// true at interruption start, false when it ends.
  void Function(bool began, bool shouldResume)? onAudioInterruption;
  void Function()? onAudioRouteLost;

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
        DebugLogService.instance.logError(
          LogCategory.stt,
          'STT initialize($locale) returned false — permission denied or '
          'recognizer unavailable',
        );
      }
      return _initialized;
    } on PlatformException catch (e) {
      DebugLogService.instance.logError(
        LogCategory.stt,
        'STT initialize failed',
        e,
      );
      return false;
    } on MissingPluginException {
      DebugLogService.instance.logError(
        LogCategory.stt,
        'STT platform channel not available on this platform',
      );
      return false;
    }
  }

  /// Start listening with optional vocabulary hints.
  ///
  /// [contextualStrings] — words/phrases to boost in recognition.
  /// [onResult] — called with (text, isFinal) as words are recognized.
  /// [onDone] — called when recognition ends.
  /// [onDevice] — require on-device recognition (default true).
  Future<bool> listen({
    List<String>? contextualStrings,
    required int sessionId,
    required void Function(String text, bool isFinal) onResult,
    void Function()? onDone,
    bool onDevice = true,
  }) async {
    _activeSessionId = sessionId;
    _activeLevelSessionId = sessionId;
    _onResult = onResult;
    _onDone = onDone;

    try {
      final result = await _channel.invokeMethod<bool>('listen', {
        if (contextualStrings != null && contextualStrings.isNotEmpty)
          'contextualStrings': contextualStrings,
        'onDevice': onDevice,
        'sessionId': sessionId,
      });
      if (_activeSessionId != sessionId) return false;
      _listening = result ?? false;
      if (!_listening) {
        _activeSessionId = null;
        if (_activeLevelSessionId == sessionId) {
          _activeLevelSessionId = null;
        }
        _onResult = null;
        _onDone = null;
      }
      return _listening;
    } on PlatformException catch (e) {
      DebugLogService.instance.logError(
        LogCategory.stt,
        'STT listen failed',
        e,
      );
      if (_activeSessionId == sessionId) {
        _listening = false;
        _activeSessionId = null;
        if (_activeLevelSessionId == sessionId) {
          _activeLevelSessionId = null;
        }
        _onResult = null;
        _onDone = null;
      }
      return false;
    } on MissingPluginException {
      DebugLogService.instance.logError(
        LogCategory.stt,
        'STT listen: platform channel not available',
      );
      if (_activeSessionId == sessionId) {
        _listening = false;
        _activeSessionId = null;
        _onResult = null;
        _onDone = null;
      }
      if (_activeLevelSessionId == sessionId) {
        _activeLevelSessionId = null;
      }
      return false;
    }
  }

  /// Stop listening.
  Future<void> stop() async {
    _activeLevelSessionId = null;
    _activeSessionId = null;
    _onResult = null;
    _onDone = null;
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
        if (args['sessionId'] != _activeSessionId) return;
        final text = args['text'] as String? ?? '';
        final isFinal = args['isFinal'] as bool? ?? false;
        _onResult?.call(text, isFinal);
        if (isFinal) {
          _listening = false;
        }
      case 'onDone':
        final args = call.arguments as Map;
        if (args['sessionId'] != _activeSessionId) return;
        _listening = false;
        _activeLevelSessionId = null;
        _activeSessionId = null;
        final onDone = _onDone;
        _onResult = null;
        _onDone = null;
        onDone?.call();
      case 'onError':
        final args = call.arguments;
        if (args is Map) {
          if (args['sessionId'] != _activeSessionId) return;
          DebugLogService.instance.logError(
            LogCategory.stt,
            'STT native error: ${args['error']}',
          );
        } else {
          // Recorder capture errors are not tied to a recognition session.
          DebugLogService.instance.logError(
            LogCategory.stt,
            'STT native error: $args',
          );
        }
      case 'onLevel':
        final args = call.arguments as Map;
        if (args['sessionId'] != _activeLevelSessionId) return;
        final level = (args['level'] as num?)?.toDouble() ?? 0.0;
        onLevel?.call(level);
      case 'onPcm':
        final pcm = call.arguments;
        if (pcm is Uint8List) onPcm?.call(pcm);
      case 'onAudioInterruption':
        final args = call.arguments as Map? ?? {};
        final began = args['began'] as bool? ?? true;
        final shouldResume = args['shouldResume'] as bool? ?? false;
        DebugLogService.instance.log(
          LogCategory.stt,
          'Audio interruption ${began ? 'began' : 'ended'} (shouldResume=$shouldResume)',
        );
        onAudioInterruption?.call(began, shouldResume);
      case 'onAudioRouteLost':
        DebugLogService.instance.log(
          LogCategory.stt,
          'Audio route lost (headphones unplugged?)',
        );
        onAudioRouteLost?.call();
    }
  }

  /// Start recording audio alongside STT (same mic tap).
  /// Audio is saved to [path] as .m4a.
  Future<bool> startRecording(String path, {required int sessionId}) async {
    _activeLevelSessionId = sessionId;

    void clearRecordOnlyLevelSession() {
      if (_activeSessionId != sessionId && _activeLevelSessionId == sessionId) {
        _activeLevelSessionId = null;
      }
    }

    try {
      final started =
          await _channel.invokeMethod<bool>('startRecording', {
            'path': path,
            'sessionId': sessionId,
          }) ??
          false;
      if (!started) clearRecordOnlyLevelSession();
      return started;
    } on PlatformException catch (e) {
      DebugLogService.instance.logError(
        LogCategory.stt,
        'STT startRecording failed',
        e,
      );
      clearRecordOnlyLevelSession();
      return false;
    } on MissingPluginException {
      DebugLogService.instance.logError(
        LogCategory.stt,
        'STT startRecording: channel not available',
      );
      clearRecordOnlyLevelSession();
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
      DebugLogService.instance.logError(
        LogCategory.stt,
        'STT stopRecording failed',
        e,
      );
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> dispose() async {
    await stop();
    _onResult = null;
    _activeSessionId = null;
    _onDone = null;
    _activeLevelSessionId = null;
    onLevel = null;
  }
}
