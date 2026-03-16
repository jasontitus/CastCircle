import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';

import 'debug_log_service.dart';
import 'model_manager.dart';

/// TTS engine type.
enum TtsEngine {
  /// Kokoro on-device neural TTS via MLX (default, higher quality).
  kokoroMlx,

  /// System TTS (last resort if Kokoro model not loaded).
  system,
}

/// Text-to-speech service using Kokoro via MLX.
///
/// Priority chain for playing other characters' lines:
///   1. Real recording by primary actor
///   2. Real recording by understudy (if fallback enabled)
///   3. Voice-cloned audio (if voice cloning enabled)
///   4. Kokoro MLX on-device TTS (default fallback)
///   5. System TTS (last resort — only if Kokoro unavailable)
class TtsService {
  TtsService._();
  static final instance = TtsService._();

  static const _channel = MethodChannel('com.lineguide/kokoro_mlx');

  final FlutterTts _systemTts = FlutterTts();
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _initialized = false;
  TtsEngine _activeEngine = TtsEngine.kokoroMlx;

  // Map character names to Kokoro voice IDs (set by voice config or fallback)
  final Map<String, String> _characterVoices = {};

  // Per-character speed overrides (from voice config)
  final Map<String, double> _characterSpeeds = {};

  // System TTS voices (fallback)
  final Map<String, Map<String, String>> _characterSystemVoices = {};
  List<dynamic> _availableSystemVoices = [];

  // Kokoro MLX state
  bool _kokoroLoaded = false;

  // Completion callback — guarded by generation counter to fire exactly once per speak()
  Function? _completionHandler;
  bool _isSpeaking = false;
  int _speakGen = 0; // incremented each speak(), prevents stale completions
  int _activeGen = 0; // gen at time of current speak(), used by system TTS completion
  bool _usingSystemTts = false; // true only when system TTS is actively speaking

  TtsEngine get activeEngine => _activeEngine;
  bool get isKokoroLoaded => _kokoroLoaded;
  bool get isInitialized => _initialized;

  /// Try to load Kokoro after model files are downloaded.
  /// Call this when the model download completes post-init.
  Future<bool> tryLoadKokoro() async {
    if (_kokoroLoaded) return true;
    final dlog = DebugLogService.instance;
    dlog.log(LogCategory.tts, 'tryLoadKokoro: attempting post-download load');
    _kokoroLoaded = await _initKokoroMlx();
    if (_kokoroLoaded) {
      _activeEngine = TtsEngine.kokoroMlx;
      dlog.log(LogCategory.tts, 'Kokoro MLX loaded successfully (post-download)');
    } else {
      dlog.log(LogCategory.tts, 'Kokoro MLX still not available after download');
    }
    return _kokoroLoaded;
  }

  /// Available Kokoro voices for character assignment.
  static const List<String> kokoroVoices = [
    'af_heart',
    'af_bella',
    'af_jessica',
    'af_nova',
    'af_sarah',
    'am_adam',
    'am_eric',
    'am_michael',
    'am_onyx',
    'bf_alice',
    'bf_emma',
    'bf_lily',
    'bm_daniel',
    'bm_george',
    'bm_lewis',
  ];

  Future<void> init() async {
    if (_initialized) return;

    // Try to load Kokoro MLX model on device
    final dlog = DebugLogService.instance;
    _kokoroLoaded = await _initKokoroMlx();
    if (_kokoroLoaded) {
      _activeEngine = TtsEngine.kokoroMlx;
      dlog.log(LogCategory.tts, 'Kokoro MLX loaded successfully');
    } else {
      _activeEngine = TtsEngine.system;
      dlog.log(LogCategory.tts, 'Kokoro MLX NOT available — falling back to system TTS');
    }

    // Initialize system TTS as fallback
    await _systemTts.setLanguage('en-US');
    await _systemTts.setSpeechRate(0.5);
    await _systemTts.setVolume(1.0);
    await _systemTts.setPitch(1.0);
    _availableSystemVoices = await _systemTts.getVoices as List<dynamic>;

    _systemTts.setCompletionHandler(() {
      // Only fire if system TTS is actually the active engine for this speak() call.
      // _systemTts.stop() can trigger stale completions during Kokoro playback,
      // which would prematurely advance the rehearsal and cut off audio.
      if (_usingSystemTts && _speakGen == _activeGen) {
        _usingSystemTts = false;
        _fireCompletion('systemTts');
      } else {
        DebugLogService.instance.log(LogCategory.tts,
            'System TTS completion ignored (usingSystem=$_usingSystemTts, gen=$_activeGen, current=$_speakGen)');
      }
    });

    // DO NOT use playerStateStream for completion detection — it re-emits stale
    // 'completed' events during the next line's Kokoro synthesis, causing lines
    // to be skipped. Instead, completion is fired from _speakWithKokoroMlx after
    // play() returns, guarded by a generation counter.
    _audioPlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        DebugLogService.instance.log(LogCategory.tts,
            'audioPlayer stream completed (gen=$_speakGen, speaking=$_isSpeaking) — ignored, using gen counter');
      }
    });

    _initialized = true;
  }

  /// Initialize on-device Kokoro MLX model.
  /// Returns true if the model is loaded and ready for inference.
  Future<bool> _initKokoroMlx() async {
    final dlog = DebugLogService.instance;
    try {
      // Check if model files exist first (via getModelStatus)
      try {
        final status = await _channel.invokeMapMethod<String, dynamic>('getModelStatus');
        dlog.log(LogCategory.tts,
            'Kokoro model status: downloaded=${status?['downloaded']}, loaded=${status?['loaded']}');
      } catch (_) {
        // getModelStatus not critical — continue to loadModel
      }

      dlog.log(LogCategory.tts, 'Kokoro: calling loadModel...');
      final result = await _channel.invokeMethod<bool>('loadModel');
      dlog.log(LogCategory.tts, 'Kokoro: loadModel returned $result');
      return result ?? false;
    } on PlatformException catch (e) {
      dlog.logError(LogCategory.tts, 'Kokoro MLX load failed: ${e.code} — ${e.message}', e);
      return false;
    } on MissingPluginException {
      dlog.logError(LogCategory.tts, 'Kokoro MLX: platform channel not registered');
      return false;
    } catch (e) {
      dlog.logError(LogCategory.tts, 'Kokoro MLX: unexpected error during load', e);
      return false;
    }
  }

  /// Check if the Kokoro MLX model is downloaded but not yet loaded.
  Future<bool> isModelDownloaded() async {
    try {
      final status = await _channel.invokeMapMethod<String, dynamic>('getModelStatus');
      return status?['downloaded'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Assign a specific Kokoro voice and speed to a character.
  ///
  /// Called by rehearsal screen after resolving voice config (preset + overrides).
  void assignVoice(String character, int characterIndex,
      {String? voiceId, double? speed}) {
    // Use provided voiceId or fall back to round-robin from kokoroVoices
    final assignedVoice =
        voiceId ?? kokoroVoices[characterIndex % kokoroVoices.length];
    _characterVoices[character] = assignedVoice;

    if (speed != null) {
      _characterSpeeds[character] = speed;
    }

    DebugLogService.instance.log(LogCategory.tts,
        'Voice assigned: $character → $assignedVoice (idx=$characterIndex, speed=${speed ?? _currentSpeed})');

    // Also assign a system TTS voice as fallback
    if (_availableSystemVoices.isNotEmpty) {
      final sysIdx = characterIndex % _availableSystemVoices.length;
      final voice = _availableSystemVoices[sysIdx];
      if (voice is Map) {
        _characterSystemVoices[character] = Map<String, String>.from(voice);
      }
    }
  }

  /// Speak text for a character using Kokoro MLX on-device TTS.
  ///
  /// Falls back to system TTS only if Kokoro is not available on this device.
  Future<void> speak(String text, {String? character}) async {
    if (!_initialized) await init();
    final dlog = DebugLogService.instance;
    final preview = text.length > 40 ? '${text.substring(0, 37)}...' : text;

    // Increment generation — any stale completion from previous speak() is ignored
    _speakGen++;
    _activeGen = _speakGen;
    _isSpeaking = true;
    _usingSystemTts = false; // Reset — only set true if we actually use system TTS

    // Try Kokoro MLX first
    if (_kokoroLoaded) {
      dlog.log(LogCategory.tts, 'Kokoro speak: "$preview" (char=$character, gen=$_speakGen)');
      final spoke = await _speakWithKokoroMlx(text, character: character);
      if (spoke) return; // completion will fire from _audioPlayer stream
      dlog.log(LogCategory.tts, 'Kokoro failed, falling back to system TTS');
    }

    // Fall back to system TTS
    _usingSystemTts = true;
    dlog.log(LogCategory.tts, 'System TTS: "$preview"');
    if (character != null &&
        _characterSystemVoices.containsKey(character)) {
      final voice = _characterSystemVoices[character]!;
      await _systemTts.setVoice(voice);
    }
    await _systemTts.speak(text);
  }

  /// Split text into chunks at sentence boundaries for Kokoro's 510 token limit.
  /// Each chunk should be under ~300 characters to stay safely within the limit.
  static List<String> _splitTextForKokoro(String text) {
    if (text.length <= 300) return [text];

    final chunks = <String>[];
    // Split at sentence-ending punctuation followed by a space
    final sentences = text.split(RegExp(r'(?<=[.!?;])\s+'));
    var current = '';

    for (final sentence in sentences) {
      if (current.isEmpty) {
        current = sentence;
      } else if (current.length + sentence.length + 1 <= 300) {
        current = '$current $sentence';
      } else {
        chunks.add(current);
        current = sentence;
      }
    }
    if (current.isNotEmpty) chunks.add(current);

    // If any chunk is still too long, split at comma/clause boundaries
    final result = <String>[];
    for (final chunk in chunks) {
      if (chunk.length <= 300) {
        result.add(chunk);
      } else {
        final parts = chunk.split(RegExp(r'(?<=[,;:])\s+'));
        var sub = '';
        for (final part in parts) {
          if (sub.isEmpty) {
            sub = part;
          } else if (sub.length + part.length + 1 <= 300) {
            sub = '$sub $part';
          } else {
            result.add(sub);
            sub = part;
          }
        }
        if (sub.isNotEmpty) result.add(sub);
      }
    }
    return result;
  }

  /// Synthesize and play audio using on-device Kokoro MLX.
  /// Returns true if successful. Splits long text into chunks automatically.
  Future<bool> _speakWithKokoroMlx(String text, {String? character}) async {
    final gen = _speakGen; // capture for stale-check after async gaps
    final voice = (character != null && _characterVoices.containsKey(character))
        ? _characterVoices[character]!
        : 'af_heart';

    // Use per-character speed if set, otherwise global speed
    final speed = (character != null && _characterSpeeds.containsKey(character))
        ? _characterSpeeds[character]!
        : _currentSpeed;

    final chunks = _splitTextForKokoro(text);
    if (chunks.length > 1) {
      DebugLogService.instance.log(LogCategory.tts,
          'Kokoro: splitting into ${chunks.length} chunks (text=${text.length} chars)');
    }

    try {
      for (var i = 0; i < chunks.length; i++) {
        // Bail out if a newer speak() was called
        if (gen != _speakGen) {
          DebugLogService.instance.log(LogCategory.tts,
              'Kokoro chunk $i: gen stale ($gen != $_speakGen), discarding');
          return true;
        }

        final audioPath = await _channel.invokeMethod<String>('synthesize', {
          'text': chunks[i],
          'voice': voice,
          'speed': speed,
        });

        if (audioPath == null) {
          DebugLogService.instance.logError(LogCategory.tts,
              'Kokoro returned null audio path for chunk $i');
          return false;
        }

        // Bail out if a newer speak() was called during synthesis
        if (gen != _speakGen) {
          DebugLogService.instance.log(LogCategory.tts,
              'Kokoro synthesis done but gen stale ($gen != $_speakGen), discarding chunk $i');
          return true;
        }

        await _audioPlayer.stop();
        await _audioPlayer.setFilePath(audioPath);
        if (i == 0) {
          DebugLogService.instance.log(LogCategory.tts,
              'Kokoro playing audio (voice=$voice, chunks=${chunks.length})');
        }
        await _audioPlayer.play();
      }

      // All chunks played — fire completion only if still active
      if (gen == _speakGen) {
        _fireCompletion('kokoroPlay');
      } else {
        DebugLogService.instance.log(LogCategory.tts,
            'Kokoro play done but gen stale ($gen != $_speakGen), completion skipped');
      }
      return true;
    } on PlatformException catch (e) {
      DebugLogService.instance.logError(LogCategory.tts, 'Kokoro synthesis failed', e);
      return false;
    } catch (e) {
      DebugLogService.instance.logError(LogCategory.tts, 'Kokoro playback failed', e);
      return false;
    }
  }

  double _currentSpeed = 1.0;

  /// Fire the completion handler exactly once per speak() call.
  /// Prevents stale/duplicate completion events from advancing the rehearsal.
  void _fireCompletion(String source) {
    if (_isSpeaking) {
      _isSpeaking = false;
      DebugLogService.instance.log(LogCategory.tts, 'Completion fired (source=$source)');
      _completionHandler?.call();
    } else {
      DebugLogService.instance.log(LogCategory.tts, 'Completion IGNORED (source=$source, not speaking)');
    }
  }

  /// Stop current speech. Does NOT fire the completion handler.
  /// [reason] logged for diagnostics (e.g. 'advanceLine', 'dispose').
  Future<void> stop({String reason = 'unknown'}) async {
    _speakGen++; // Invalidate any in-flight speak() call
    DebugLogService.instance.log(LogCategory.tts,
        'stop() called (gen=$_speakGen, wasSpeaking=$_isSpeaking, reason=$reason)');
    _isSpeaking = false; // Prevent stop() from triggering completion
    _usingSystemTts = false; // Prevent stale system TTS completion
    await _audioPlayer.stop();
    await _systemTts.stop();
  }

  /// Release audio resources so STT can acquire the microphone.
  /// Does NOT affect the gen counter or fire completions.
  /// Call this before starting STT after TTS playback.
  Future<void> releaseAudioSession() async {
    await _audioPlayer.stop();
  }

  /// Set playback speed (0.0 to 1.0, where 0.5 is normal for system TTS).
  Future<void> setRate(double rate) async {
    // For Kokoro MLX, speed is 0.5–2.0 where 1.0 is normal.
    // The caller passes rate as system-TTS scale (0.0–1.0, 0.5 = normal).
    // Convert: system 0.5 → Kokoro 1.0
    _currentSpeed = (rate / 0.5).clamp(0.5, 2.0);
    await _systemTts.setSpeechRate(rate);
  }

  /// Listen for TTS completion events.
  void setCompletionHandler(Function handler) {
    _completionHandler = handler;
    // Don't override system TTS handler — init() already routes it through
    // _fireCompletion which provides the _isSpeaking guard.
  }

  /// Delete the on-device Kokoro model to free storage.
  Future<void> deleteModel() async {
    try {
      await _channel.invokeMethod('deleteModel');
      _kokoroLoaded = false;
      _activeEngine = TtsEngine.system;
    } catch (e) {
      debugPrint('Kokoro MLX: delete failed: $e');
    }
  }

  /// Debug info for diagnostics screen.
  Future<Map<String, String>> getDebugInfo() async {
    return {
      'initialized': _initialized.toString(),
      'activeEngine': _activeEngine.name,
      'kokoroLoaded': _kokoroLoaded.toString(),
    };
  }

  /// Clean up resources.
  void dispose() {
    _audioPlayer.dispose();
  }
}
