import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:firebase_performance/firebase_performance.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'debug_log_service.dart';
import 'kokoro_onnx_service.dart' show KokoroOnnxService;
import 'model_manager.dart';
import 'perf_service.dart';
import 'playback_session.dart';
import 'wav_silence.dart';

/// TTS engine type.
enum TtsEngine {
  /// Kokoro on-device neural TTS via MLX (iOS, highest quality).
  kokoroMlx,

  /// Kokoro on-device neural TTS via sherpa-onnx (Android — fp16 pack,
  /// synthesized in a background isolate; see KokoroOnnxService).
  kokoroOnnx,

  /// System TTS (fallback when Kokoro model not loaded).
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
  static final _localeSplitRe = RegExp(r'[-_]');
  static final _gbVoiceRe = RegExp(r'en-gb-x-gb([a-z])');
  static final _usVoiceRe = RegExp(r'en-us-x-\w\w([a-z])');

  final FlutterTts _systemTts = FlutterTts();
  final AudioPlayer _audioPlayer = AudioPlayer();

  /// When audio last played. Used to decide whether the output is cold — see
  /// the padding in the Kokoro play path.
  DateTime? _lastPlaybackAt;

  /// The output is treated as asleep when nothing has played for a few
  /// seconds. Mid-rehearsal, lines follow each other closely and stay warm.
  bool get _outputIsCold {
    final last = _lastPlaybackAt;
    return last == null ||
        DateTime.now().difference(last) > const Duration(seconds: 3);
  }

  String? _tempDirPath;
  Future<String> _tempDir() async =>
      _tempDirPath ??= (await getTemporaryDirectory()).path;
  StreamSubscription? _playerStateSub;
  bool _initialized = false;
  Future<void>? _initFuture;
  TtsEngine _activeEngine = TtsEngine.system;

  // Map character names to Kokoro voice IDs (set by voice config or fallback)
  final Map<String, String> _characterVoices = {};

  // Per-character speed overrides (from voice config)
  final Map<String, double> _characterSpeeds = {};

  // System TTS voices (fallback)
  final Map<String, Map<String, String>> _characterSystemVoices = {};
  final Map<String, double> _characterPitches = {}; // gender-based pitch
  List<dynamic> _availableSystemVoices = [];

  // Kokoro model readiness, exposed reactively for settings/status surfaces.
  bool _kokoroLoaded = false;
  final ValueNotifier<bool> _kokoroLoadedNotifier = ValueNotifier(false);

  /// Fired the moment a line's FIRST audio actually starts playing.
  ///
  /// This — not speak()'s return — is the pipelining anchor: speak() only
  /// returns after playback COMPLETES, so a prefetch kicked "after speak"
  /// starts exactly when the next line already needs its audio (measured on
  /// Android playthrough: 6-10 s of silence between consecutive TTS lines
  /// despite "prefetching"). The rehearsal screen prefetches upcoming lines
  /// from here so their synthesis genuinely overlaps this line's playback.
  void Function()? onPlaybackStarted;

  // Completion callback — guarded by generation counter to fire exactly once per speak()
  Function? _completionHandler;
  bool _isSpeaking = false;
  Trace? _currentTrace; // Firebase Performance trace for current speak()
  int _speakGen = 0; // incremented each speak(), prevents stale completions
  int _activeGen =
      0; // gen at time of current speak(), used by system TTS completion
  bool _usingSystemTts =
      false; // true only when system TTS is actively speaking
  Timer? _systemTtsWatchdog;
  void Function()? _cancelChunkWait;

  TtsEngine get activeEngine => _activeEngine;
  bool get isKokoroLoaded => _kokoroLoaded;
  ValueListenable<bool> get kokoroLoadedListenable => _kokoroLoadedNotifier;
  bool get isInitialized => _initialized;

  void _setKokoroLoaded(bool value) {
    _kokoroLoaded = value;
    _kokoroLoadedNotifier.value = value;
  }

  /// Set the system TTS language to match the production locale.
  /// Also refreshes and logs the filtered voice pool for diagnostics.
  Future<void> setLocale(String locale) async {
    await _systemTts.setLanguage(locale);
    _availableSystemVoices = await _systemTts.getVoices as List<dynamic>;
    // Log available voices for the locale so we can debug accent/gender issues
    final matching = _availableSystemVoices.where((v) {
      if (v is! Map) return false;
      final vLocale =
          v['locale']?.toString().replaceAll('_', '-').toLowerCase() ?? '';
      return vLocale == locale.replaceAll('_', '-').toLowerCase();
    }).toList();
    final names = matching.map((v) => (v as Map)['name'] ?? '?').toList();
    DebugLogService.instance.log(
      LogCategory.tts,
      'System TTS locale=$locale, ${matching.length} exact voices: $names',
    );
    // Log full metadata of first 3 voices to discover available fields
    for (var i = 0; i < matching.length && i < 3; i++) {
      DebugLogService.instance.log(
        LogCategory.tts,
        'Voice[$i] full data: ${matching[i]}',
      );
    }
  }

  /// Try to load Kokoro after model files are downloaded.
  /// Call this when the model download completes post-init.
  Future<bool> tryLoadKokoro() async {
    if (_kokoroLoaded) return true;
    final dlog = DebugLogService.instance;
    dlog.log(LogCategory.tts, 'tryLoadKokoro: attempting post-download load');

    // Try MLX first (iOS).
    if (await _initKokoroMlx()) {
      _activeEngine = TtsEngine.kokoroMlx;
      _setKokoroLoaded(true);
      dlog.log(
        LogCategory.tts,
        'Kokoro MLX loaded successfully (post-download)',
      );
      return true;
    }

    // Android: sherpa-onnx engine.
    if (Platform.isAndroid &&
        await KokoroOnnxService.instance.ensureStarted()) {
      _activeEngine = TtsEngine.kokoroOnnx;
      _setKokoroLoaded(true);
      dlog.log(
        LogCategory.tts,
        'Kokoro ONNX loaded successfully (post-download)',
      );
      return true;
    }

    _activeEngine = TtsEngine.system;
    _setKokoroLoaded(false);
    dlog.log(LogCategory.tts, 'Kokoro still not available after download');
    return false;
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

  Future<void> init() {
    if (_initialized) return Future<void>.value();
    return _initFuture ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      // Try to load Kokoro on device: MLX on Apple platforms, sherpa-onnx on
      // Android.
      final dlog = DebugLogService.instance;
      if (await _initKokoroMlx()) {
        _activeEngine = TtsEngine.kokoroMlx;
        _setKokoroLoaded(true);
        dlog.log(LogCategory.tts, 'Kokoro MLX loaded successfully');
      } else if (Platform.isAndroid &&
          await KokoroOnnxService.instance.ensureStarted()) {
        _activeEngine = TtsEngine.kokoroOnnx;
        _setKokoroLoaded(true);
        dlog.log(LogCategory.tts, 'Kokoro ONNX loaded successfully');
      } else {
        _activeEngine = TtsEngine.system;
        _setKokoroLoaded(false);
        dlog.log(LogCategory.tts, 'Kokoro not available — system TTS fallback');
      }

      // Initialize system TTS as fallback (language updated per-session in setLocale)
      await _systemTts.setLanguage('en-US');
      await _systemTts.setSpeechRate(0.5);
      await _systemTts.setVolume(1.0);
      await _systemTts.setPitch(1.0);
      _availableSystemVoices = await _systemTts.getVoices as List<dynamic>;

      _systemTts.setStartHandler(() {
        DebugLogService.instance.log(
          LogCategory.tts,
          'System TTS started speaking (gen=$_activeGen)',
        );
      });

      _systemTts.setErrorHandler((msg) {
        DebugLogService.instance.logError(
          LogCategory.tts,
          'System TTS error: $msg (gen=$_activeGen)',
        );
        // Fire completion on error so rehearsal doesn't stall.
        if (_usingSystemTts && _speakGen == _activeGen) {
          _systemTtsWatchdog?.cancel();
          _systemTtsWatchdog = null;
          _usingSystemTts = false;
          _fireCompletion('systemTtsError');
        }
      });

      _systemTts.setCompletionHandler(() {
        // Only fire if system TTS is actually the active engine for this speak() call.
        // _systemTts.stop() can trigger stale completions during Kokoro playback,
        // which would prematurely advance the rehearsal and cut off audio.
        if (_usingSystemTts && _speakGen == _activeGen) {
          _systemTtsWatchdog?.cancel();
          _systemTtsWatchdog = null;
          _usingSystemTts = false;
          _fireCompletion('systemTts');
        } else {
          DebugLogService.instance.log(
            LogCategory.tts,
            'System TTS completion ignored (usingSystem=$_usingSystemTts, gen=$_activeGen, current=$_speakGen)',
          );
        }
      });

      // DO NOT use playerStateStream for completion detection — it re-emits stale
      // 'completed' events during the next line's Kokoro synthesis, causing lines
      // to be skipped. Instead, completion is fired from _speakWithKokoroMlx after
      // play() returns, guarded by a generation counter.
      _playerStateSub = _audioPlayer.playerStateStream.listen((state) {
        if (state.processingState == ProcessingState.completed) {
          DebugLogService.instance.log(
            LogCategory.tts,
            'audioPlayer stream completed (gen=$_speakGen, speaking=$_isSpeaking) — ignored, using gen counter',
          );
        }
      });

      _initialized = true;
    } catch (_) {
      _initFuture = null;
      rethrow;
    }
  }

  /// Initialize on-device Kokoro MLX model.
  /// Returns true if the model is loaded and ready for inference.
  Future<bool> _initKokoroMlx() async {
    final dlog = DebugLogService.instance;
    try {
      // Check if model files exist first (via getModelStatus)
      try {
        final status = await _channel.invokeMapMethod<String, dynamic>(
          'getModelStatus',
        );
        dlog.log(
          LogCategory.tts,
          'Kokoro model status: downloaded=${status?['downloaded']}, loaded=${status?['loaded']}',
        );
      } catch (_) {
        // getModelStatus not critical — continue to loadModel
      }

      dlog.log(LogCategory.tts, 'Kokoro: calling loadModel...');
      final result = await _channel.invokeMethod<bool>('loadModel');
      dlog.log(LogCategory.tts, 'Kokoro: loadModel returned $result');
      return result ?? false;
    } on PlatformException catch (e) {
      dlog.logError(
        LogCategory.tts,
        'Kokoro MLX load failed: ${e.code} — ${e.message}',
        e,
      );
      return false;
    } on MissingPluginException {
      dlog.logError(
        LogCategory.tts,
        'Kokoro MLX: platform channel not registered',
      );
      return false;
    } catch (e) {
      dlog.logError(
        LogCategory.tts,
        'Kokoro MLX: unexpected error during load',
        e,
      );
      return false;
    }
  }

  /// Check if the Kokoro MLX model is downloaded but not yet loaded.
  Future<bool> isModelDownloaded() async {
    try {
      final status = await _channel.invokeMapMethod<String, dynamic>(
        'getModelStatus',
      );
      return status?['downloaded'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Assign a specific Kokoro voice and speed to a character.
  ///
  /// Called by rehearsal screen after resolving voice config (preset + overrides).
  /// [locale] filters system TTS voices to matching language (e.g. "en-GB").
  /// [isMale] selects male/female system TTS voices by name heuristic.
  void assignVoice(
    String character,
    int characterIndex, {
    String? voiceId,
    double? speed,
    String? locale,
    bool? isMale,
  }) {
    // Use provided voiceId or fall back to round-robin from kokoroVoices
    final assignedVoice =
        voiceId ?? kokoroVoices[characterIndex % kokoroVoices.length];
    _characterVoices[character] = assignedVoice;

    if (speed != null) {
      _characterSpeeds[character] = speed;
    }

    DebugLogService.instance.log(
      LogCategory.tts,
      'Voice assigned: $character → $assignedVoice (idx=$characterIndex, speed=${speed ?? _currentSpeed})',
    );

    // Also assign a system TTS voice as fallback, filtered by locale and gender
    if (_availableSystemVoices.isNotEmpty) {
      final targetLocale = locale ?? 'en-US';
      // Filter voices matching the requested locale (e.g. en-GB, en-US)
      final localeVoices = _availableSystemVoices.where((v) {
        if (v is! Map) return false;
        final vLocale = v['locale']?.toString() ?? '';
        return vLocale.replaceAll('_', '-').toLowerCase() ==
                targetLocale.replaceAll('_', '-').toLowerCase() ||
            vLocale.split(_localeSplitRe).first.toLowerCase() ==
                targetLocale.split(_localeSplitRe).first.toLowerCase();
      }).toList();

      // Prefer exact locale match, fall back to same-language voices
      final exactMatch = localeVoices.where((v) {
        final vLocale =
            (v as Map)['locale']
                ?.toString()
                .replaceAll('_', '-')
                .toLowerCase() ??
            '';
        return vLocale == targetLocale.replaceAll('_', '-').toLowerCase();
      }).toList();

      final pool = exactMatch.isNotEmpty
          ? exactMatch
          : localeVoices.isNotEmpty
          ? localeVoices
          : _availableSystemVoices;

      // Filter by gender using Google TTS voice name conventions.
      // On-device voices use pattern: en-{cc}-x-{prefix}{letter}-{local|network}
      // The letter maps to Cloud TTS gender (cloud.google.com/text-to-speech/docs/voices).
      List<dynamic> genderPool = pool;
      if (isMale != null && pool.length > 1) {
        final filtered = pool.where((v) {
          if (v is! Map) return false;
          final name = (v['name']?.toString() ?? '').toLowerCase();
          final voiceGender = _googleTtsVoiceGender(name);
          if (voiceGender == null) return true; // unknown → include in both
          return isMale ? voiceGender == 'male' : voiceGender == 'female';
        }).toList();
        if (filtered.isNotEmpty) genderPool = filtered;
      }

      final sysIdx = characterIndex % genderPool.length;
      final voice = genderPool[sysIdx];
      if (voice is Map) {
        _characterSystemVoices[character] = Map<String, String>.from(voice);
        // Subtle pitch reinforcement for gender
        _characterPitches[character] = (isMale == true) ? 0.9 : 1.05;
        DebugLogService.instance.log(
          LogCategory.tts,
          'System voice: $character → ${voice['name']} (locale=${voice['locale']}, isMale=$isMale, pitch=${_characterPitches[character]})',
        );
      }
    }
  }

  /// Determine gender of a Google TTS on-device voice from its name.
  /// Maps voice name suffixes to Cloud TTS documented genders.
  /// Returns 'male', 'female', or null if unknown.
  static String? _googleTtsVoiceGender(String voiceName) {
    // Known male voices by full prefix (e.g. "rjs" is always male)
    if (voiceName.contains('-rjs-')) return 'male';

    // en-GB voices: en-gb-x-gb{letter} → Cloud en-GB-Standard-{letter}
    // A=F, B=M, C=F, D=M, F=F, G=F, N=F, O=M
    final gbMatch = _gbVoiceRe.firstMatch(voiceName);
    if (gbMatch != null) {
      return _cloudTtsGender('gb', gbMatch.group(1)!);
    }

    // en-US voices: en-us-x-{prefix}{letter}
    // A=M, B=M, C=F, D=M, E=F, F=F, G=F, H=F, I=M, J=M
    final usMatch = _usVoiceRe.firstMatch(voiceName);
    if (usMatch != null) {
      return _cloudTtsGender('us', usMatch.group(1)!);
    }

    return null;
  }

  /// Cloud TTS gender by locale and voice letter.
  static String? _cloudTtsGender(String locale, String letter) {
    const genderMap = {
      'gb': {
        'a': 'female',
        'b': 'male',
        'c': 'female',
        'd': 'male',
        'f': 'female',
        'g': 'female',
        'n': 'female',
        'o': 'male',
      },
      'us': {
        'a': 'male',
        'b': 'male',
        'c': 'female',
        'd': 'male',
        'e': 'female',
        'f': 'female',
        'g': 'female',
        'h': 'female',
        'i': 'male',
        'j': 'male',
      },
    };
    return genderMap[locale]?[letter];
  }

  /// Override the playback speed for a specific character.
  /// Used by fast mode to temporarily speed up/slow down TTS.
  void setCharacterSpeed(String character, double speed) {
    _characterSpeeds[character] = speed;
  }

  /// Speak text for a character using Kokoro MLX on-device TTS.
  ///
  /// Falls back to system TTS only if Kokoro is not available on this device.
  ///
  /// [precomputedChunks] — optional per-chunk synthesis futures (one per
  /// chunk, from [prepareKokoro]). When provided and the chunk count matches,
  /// playback starts as soon as the FIRST chunk resolves, while the rest
  /// keep synthesizing in the background.
  Future<void> speak(
    String text, {
    String? character,
    List<Future<String?>>? precomputedChunks,
  }) async {
    if (!_initialized) await init();
    // Stage directions in parentheses/brackets are never spoken — strip them so
    // the TTS reads only the dialogue. Abbreviations expand ("Mr." → "Mister")
    // so their periods can't read as sentence ends — see expandAbbreviations.
    text = expandAbbreviations(stripStageDirections(text));
    _currentTrace?.stop();
    _currentTrace = PerfService.instance.startTrace('tts_speak');
    _currentTrace?.putAttribute('engine', _kokoroLoaded ? 'kokoro' : 'system');
    final dlog = DebugLogService.instance;
    var preview = text.length > 40 ? '${text.substring(0, 37)}...' : text;

    // Increment generation — any stale completion from previous speak() is ignored.
    _cancelChunkWait?.call();
    _systemTtsWatchdog?.cancel();
    _systemTtsWatchdog = null;
    _speakGen++;
    final gen = _speakGen;
    _activeGen = gen;
    _isSpeaking = true;
    _usingSystemTts = false;

    // Quiesce the previous platform utterance while callbacks are disabled.
    // flutter_tts callbacks carry no request ID, so allowing an old completion
    // past this boundary could complete the replacement line.
    if (!await _stopSystemTtsForReplacement(gen)) return;

    // The whole line was a stage direction — nothing to speak. Fire completion
    // so the rehearsal flow still advances — but NEVER synchronously: every
    // other completion arrives from an async platform callback, and firing
    // inside the caller's stack re-entered the rehearsal advance path while
    // processCurrentLine was still on it.
    if (text.isEmpty) {
      Future.microtask(() {
        if (gen == _speakGen) _fireCompletion('emptyAfterStripDirections');
      });
      return;
    }

    if (_kokoroLoaded) {
      dlog.log(
        LogCategory.tts,
        'Kokoro ${_activeEngine == TtsEngine.kokoroOnnx ? 'ONNX' : 'MLX'} '
        'speak: "$preview" (char=$character, gen=$gen)',
      );
      final fallbackText = await _speakWithKokoroMlx(
        text,
        character: character,
        precomputedChunks: precomputedChunks,
      );
      if (fallbackText == null || gen != _speakGen) return;

      // A later-chunk failure must not replay chunks the actor already heard.
      text = fallbackText;
      preview = text.length > 40 ? '${text.substring(0, 37)}...' : text;
      dlog.log(
        LogCategory.tts,
        'Kokoro failed, falling back to system TTS for remaining text',
      );
    }

    await _speakWithSystemTts(
      text,
      preview: preview,
      character: character,
      gen: gen,
    );
  }

  Future<void> _speakWithSystemTts(
    String text, {
    required String preview,
    required String? character,
    required int gen,
  }) async {
    final dlog = DebugLogService.instance;
    try {
      // Release just_audio's audio session first — on Android, it holds
      // exclusive audio focus and flutter_tts can silently fail to acquire it.
      await _audioPlayer.stop();
      if (gen != _speakGen) return;

      // STT can leave the shared iOS session in record mode. Android must not
      // activate this session because that itself grabs audio focus.
      if (Platform.isIOS) {
        await PlaybackSession.ensurePlayback();
        if (gen != _speakGen) return;
      }

      dlog.log(LogCategory.tts, 'System TTS: "$preview"');
      if (character != null && _characterSystemVoices.containsKey(character)) {
        await _systemTts.setVoice(_characterSystemVoices[character]!);
        if (gen != _speakGen) return;
      }

      final pitch =
          (character != null && _characterPitches.containsKey(character))
          ? _characterPitches[character]!
          : 1.0;
      await _systemTts.setPitch(pitch);
      if (gen != _speakGen) return;

      // Arm before invoking the platform. Some Android engines accept the
      // request but emit no start, error, or completion callback.
      _usingSystemTts = true;
      _systemTtsWatchdog = Timer(_systemTtsWatchdogDuration(text), () {
        if (_usingSystemTts && gen == _speakGen) {
          dlog.logError(
            LogCategory.tts,
            'System TTS timed out without completion (gen=$gen)',
          );
          _usingSystemTts = false;
          _systemTtsWatchdog = null;
          unawaited(_systemTts.stop());
          _fireCompletion('systemTtsWatchdog');
        }
      });

      final result = await _systemTts.speak(text);
      if (gen != _speakGen) return;
      if (result == 0 || result == false) {
        _systemTtsWatchdog?.cancel();
        _systemTtsWatchdog = null;
        _usingSystemTts = false;
        dlog.logError(
          LogCategory.tts,
          'System TTS refused to start (result=$result, gen=$gen)',
        );
        _fireCompletion('systemTtsStartFailed');
      }
    } catch (e, stack) {
      dlog.logError(
        LogCategory.tts,
        'System TTS invocation failed (gen=$gen)',
        e,
        stack,
      );
      if (gen == _speakGen) {
        _systemTtsWatchdog?.cancel();
        _systemTtsWatchdog = null;
        _usingSystemTts = false;
        _fireCompletion('systemTtsException');
      }
    }
  }

  static Duration _systemTtsWatchdogDuration(String text) {
    // System voices normally exceed 12 characters/second. Eight plus a
    // ten-second startup margin avoids cutting off slow accessibility voices.
    // Do not cap long lines: a fixed ceiling can stop valid speech early.
    final estimatedSeconds = 10 + (text.length / 8).ceil();
    return Duration(seconds: estimatedSeconds < 15 ? 15 : estimatedSeconds);
  }

  Future<bool> _stopSystemTtsForReplacement(int gen) async {
    _usingSystemTts = false;
    try {
      await _systemTts.stop();
    } catch (e, stack) {
      DebugLogService.instance.logError(
        LogCategory.tts,
        'Failed to stop previous system TTS utterance',
        e,
        stack,
      );
      if (gen == _speakGen) _fireCompletion('systemTtsReplacementStopFailed');
      return false;
    }
    return gen == _speakGen;
  }

  /// Remove parenthetical / bracketed stage directions so the TTS speaks only
  /// the dialogue. In play scripts, "(…)" and "[…]" are delivery/stage
  /// directions ("(softly)", "(crossing to the window)", "[aside]"), never the
  /// spoken words — so they should never be read aloud. Collapses the leftover
  /// whitespace. Exposed for reuse (e.g. line-matching) and testing.
  // Compiled once: stripStageDirections runs per speak() AND per rehearsal
  // quiet-sample plausibility check.
  static final _parenRe = RegExp(r'\([^)]*\)');
  static final _bracketRe = RegExp(r'\[[^\]]*\]');
  static final _unclosedRe = RegExp(r'[(\[][^)\]]*$');
  static final _wsRe = RegExp(r'\s+');
  static final _sentenceSplitRe = RegExp(r'(?<=[.!?;])\s+');
  static final _clauseSplitRe = RegExp(r'(?<=[,;:])\s+');

  static String stripStageDirections(String text) {
    var t = text.replaceAll(_parenRe, ' '); // (closed)
    t = t.replaceAll(_bracketRe, ' '); // [closed]
    // Unclosed direction running to end of the line — OCR'd scripts routinely
    // drop the closing ')' / ']' (the direction wraps to the next line), e.g.
    // "Nothing would delight me more. (MRS. GARDINER and ELIZABETH turn to…".
    t = t.replaceAll(_unclosedRe, ' ');
    return t.replaceAll(_wsRe, ' ').trim();
  }

  /// Split text into chunks at sentence boundaries for Kokoro's 510 token limit.
  /// Each chunk should be under ~300 characters to stay safely within the limit.
  /// Expand spoken abbreviations before any sentence handling.
  ///
  /// "Mr. Bennet" carries a period that BOTH sentence splitters — ours below
  /// and Kokoro's internal one — read as end-of-sentence, producing an
  /// audible pause after every "Mr."/"Mrs." (and our splitter even peeled
  /// "Mr." off as its own one-word chunk, multiplying per-chunk playback
  /// gaps: the "slow playthrough" complaint). Expanding to the full word
  /// removes the false boundary at every layer and pins the pronunciation.
  static final _abbrevRe = RegExp(
    r'\b(Mr|Mrs|Ms|Dr|Prof|Rev|Capt|Col|Lt|Sgt|Jr|Sr|St)\.',
  );

  static String expandAbbreviations(String text) {
    const expansions = {
      'Mr': 'Mister',
      'Mrs': 'Missus',
      'Ms': 'Miz',
      'Dr': 'Doctor',
      'Prof': 'Professor',
      'Rev': 'Reverend',
      'Capt': 'Captain',
      'Col': 'Colonel',
      'Lt': 'Lieutenant',
      'Sgt': 'Sergeant',
      'Jr': 'Junior',
      'Sr': 'Senior',
      'St':
          'Saint', // dialogue "St. James" — street addresses are rare in scripts
    };
    return text.replaceAllMapped(
      // Word-boundary + period, case as written (titles are capitalized in
      // scripts; leave lowercase "st." etc alone rather than guess).
      // Compiled once — this runs per speak().
      _abbrevRe,
      (m) => expansions[m[1]]!,
    );
  }

  /// Test hook: the chunking test used to verify a hand-copied replica of
  /// this algorithm, which caught nothing when the real one changed.
  @visibleForTesting
  static List<String> splitTextForKokoroTest(String text) =>
      _splitTextForKokoro(text);

  static List<String> _splitTextForKokoro(String text) {
    // Synthesis is ~real-time on Android phones, so time-to-first-audio is
    // set by the FIRST chunk's length: peel off the opening sentence of any
    // multi-sentence line so playback starts after ~one sentence of synthesis
    // while the rest generates during playback. (Cross-sentence prosody loss
    // is negligible — sherpa synthesizes per sentence internally anyway.)
    final sentences = text.split(_sentenceSplitRe);
    if (text.length <= 120 || sentences.length < 2) {
      if (text.length <= 300) return [text];
    }

    final chunks = <String>[];
    var current = '';

    for (final sentence in sentences) {
      if (current.isEmpty) {
        current = sentence;
      } else if (chunks.isEmpty && text.length > 120) {
        // First chunk = first sentence alone (fast start).
        chunks.add(current);
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
        final parts = chunk.split(_clauseSplitRe);
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

    // Final safety: force-split any chunk still over 300 chars at word boundaries.
    // This catches text with no punctuation at all (monologues, run-on sentences).
    final safe = <String>[];
    for (final chunk in result) {
      if (chunk.length <= 300) {
        safe.add(chunk);
      } else {
        final words = chunk.split(' ');
        var sub = '';
        for (final word in words) {
          if (sub.isEmpty) {
            sub = word;
          } else if (sub.length + word.length + 1 <= 300) {
            sub = '$sub $word';
          } else {
            if (sub.isNotEmpty) safe.add(sub);
            sub = word;
          }
        }
        if (sub.isNotEmpty) safe.add(sub);
      }
    }
    return safe.isEmpty ? [text] : safe;
  }

  /// Synthesize and play audio using on-device Kokoro MLX.
  /// Returns true if successful. Splits long text into chunks automatically.
  /// Synthesize one chunk with whichever Kokoro engine is loaded, returning
  /// the audio file path (null on failure). The single seam between the
  /// platform engines — playback, chunking, and prefetch above are shared.
  ///
  /// [urgent] marks audio the actor is waiting on right now (live speak, not
  /// prefetch): on the ONNX engine it cancels stale queued lines and aborts a
  /// superseded generation mid-synthesis.
  Future<String?> _synthesizeChunk(
    String text, {
    required String voice,
    required double speed,
    bool urgent = false,
  }) {
    if (_activeEngine == TtsEngine.kokoroOnnx) {
      return KokoroOnnxService.instance.synthesize(
        text,
        voice: voice,
        speed: speed,
        urgent: urgent,
      );
    }
    return _channel.invokeMethod<String>('synthesize', {
      'text': text,
      'voice': voice,
      'speed': speed,
    });
  }

  /// Returns null when the invocation was fully handled. On failure, returns
  /// only the text whose chunks have not completed playback so system TTS does
  /// not repeat earlier chunks.
  Future<String?> _speakWithKokoroMlx(
    String text, {
    String? character,
    List<Future<String?>>? precomputedChunks,
  }) async {
    final gen = _speakGen;
    final voice = (character != null && _characterVoices.containsKey(character))
        ? _characterVoices[character]!
        : 'af_heart';
    final speed = (character != null && _characterSpeeds.containsKey(character))
        ? _characterSpeeds[character]!
        : _currentSpeed;

    final chunks = _splitTextForKokoro(text);
    if (chunks.length > 1) {
      DebugLogService.instance.log(
        LogCategory.tts,
        'Kokoro: splitting into ${chunks.length} chunks (text=${text.length} chars)',
      );
    }

    final usePrecomputed =
        precomputedChunks != null && precomputedChunks.length == chunks.length;
    if (usePrecomputed) {
      DebugLogService.instance.log(
        LogCategory.tts,
        'Kokoro: using ${chunks.length} prefetched chunk future(s)',
      );
    }
    var currentChunk = 0;
    String? remainingText() {
      final remaining = chunks.skip(currentChunk).join(' ');
      return remaining.isEmpty ? null : remaining;
    }

    try {
      // Streaming: chunk i+1 synthesizes while chunk i plays.
      Future<String?>? nextOnDemand;
      for (var i = 0; i < chunks.length; i++) {
        currentChunk = i;
        if (gen != _speakGen) {
          DebugLogService.instance.log(
            LogCategory.tts,
            'Kokoro chunk $i: gen stale ($gen != $_speakGen), discarding',
          );
          return null;
        }

        var audioPath = usePrecomputed
            ? await precomputedChunks[i]
            : await (nextOnDemand ??
                  _synthesizeChunk(
                    chunks[i],
                    voice: voice,
                    speed: speed,
                    urgent: true,
                  ));
        nextOnDemand = null;
        if ((audioPath == null || audioPath.isEmpty) && usePrecomputed) {
          if (gen != _speakGen) return null;
          audioPath = await _synthesizeChunk(
            chunks[i],
            voice: voice,
            speed: speed,
            urgent: true,
          );
        }

        if (audioPath == null || audioPath.isEmpty) {
          DebugLogService.instance.logError(
            LogCategory.tts,
            'Kokoro returned null/empty audio path for chunk $i',
          );
          return remainingText();
        }

        if (gen != _speakGen) {
          DebugLogService.instance.log(
            LogCategory.tts,
            'Kokoro synthesis done but gen stale ($gen != $_speakGen), discarding chunk $i',
          );
          return null;
        }

        if (!usePrecomputed && i + 1 < chunks.length) {
          nextOnDemand = _synthesizeChunk(
            chunks[i + 1],
            voice: voice,
            speed: speed,
            urgent: true,
          );
        }

        if (i == 0 && Platform.isAndroid && _outputIsCold) {
          final padded = await WavSilence.prepend(
            audioPath,
            p.join(await _tempDir(), 'tts_warmup.wav'),
          );
          if (padded != audioPath) {
            DebugLogService.instance.log(
              LogCategory.tts,
              'Kokoro: padded the first line with silence (cold output)',
            );
            audioPath = padded;
          }
        }

        await _audioPlayer.stop();
        await _audioPlayer.setFilePath(audioPath);
        if (i == 0) {
          await PlaybackSession.ensurePlayback();
          DebugLogService.instance.log(
            LogCategory.tts,
            'Kokoro playing audio (voice=$voice, chunks=${chunks.length})',
          );
          onPlaybackStarted?.call();
        }

        // Listen before play() so a very short file cannot complete between the
        // call and subscription. The explicit subscription is cancelled on
        // every exit, unlike Future.firstWhere().timeout().
        final chunkDone = _waitForChunkCompletion(gen);
        try {
          await _audioPlayer.play();
        } catch (_) {
          _cancelChunkWait?.call();
          rethrow;
        }
        _lastPlaybackAt = DateTime.now();

        final completed = await chunkDone;
        if (gen != _speakGen) {
          DebugLogService.instance.log(
            LogCategory.tts,
            'Kokoro chunk $i finished but gen stale, bailing',
          );
          return null;
        }
        if (!completed) {
          DebugLogService.instance.logError(
            LogCategory.tts,
            'Kokoro playback timed out for chunk $i',
          );
          return remainingText();
        }
        currentChunk = i + 1;
      }

      if (gen == _speakGen) {
        _fireCompletion('kokoroPlay');
      } else {
        DebugLogService.instance.log(
          LogCategory.tts,
          'Kokoro play done but gen stale ($gen != $_speakGen), completion skipped',
        );
      }
      return null;
    } on PlatformException catch (e, stack) {
      if (e.message != null && e.message!.contains('cancelled')) {
        DebugLogService.instance.log(
          LogCategory.tts,
          'Kokoro synthesis cancelled (gen=$gen, current=$_speakGen)',
        );
        return null;
      }
      if (e.message != null && e.message!.contains('backgrounded')) {
        DebugLogService.instance.log(
          LogCategory.tts,
          'Kokoro unavailable in background — using system voice for remaining text',
        );
        return remainingText();
      }
      DebugLogService.instance.logError(
        LogCategory.tts,
        'Kokoro synthesis failed',
        e,
        stack,
      );
      return remainingText();
    } catch (e, stack) {
      DebugLogService.instance.logError(
        LogCategory.tts,
        'Kokoro playback failed',
        e,
        stack,
      );
      return remainingText();
    }
  }

  Future<bool> _waitForChunkCompletion(int gen) {
    final completer = Completer<bool>();
    Timer? timer;
    late StreamSubscription<ProcessingState> subscription;
    late void Function() cancelWait;

    void finish(bool completed) {
      if (!completer.isCompleted) completer.complete(completed);
    }

    subscription = _audioPlayer.processingStateStream.listen(
      (state) {
        if (gen != _speakGen) {
          finish(false);
        } else if (state == ProcessingState.completed) {
          finish(true);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      },
    );
    timer = Timer(const Duration(seconds: 60), () => finish(false));
    cancelWait = () => finish(false);
    _cancelChunkWait = cancelWait;

    return completer.future.whenComplete(() {
      timer?.cancel();
      if (identical(_cancelChunkWait, cancelWait)) _cancelChunkWait = null;
      return subscription.cancel();
    });
  }

  /// Pre-synthesize Kokoro audio for [text] WITHOUT playing it, so a later
  /// [speak] call (passed the returned futures via `precomputedChunks`)
  /// starts as soon as the FIRST chunk is ready — long lines used to wait for
  /// every chunk before any audio played (measured: 15 s of silence on a
  /// 416-char line). Mirrors [_speakWithKokoroMlx]'s voice/speed/chunking
  /// logic but does NOT touch _speakGen / _isSpeaking / completion.
  /// Best-effort: null if Kokoro isn't loaded; individual futures resolve
  /// null when a chunk fails or its synthesis was cancelled.
  List<Future<String?>>? prepareKokoro(String text, {String? character}) {
    if (!_kokoroLoaded) return null;
    // Strip + expand identically to [speak] so the chunk counts (and thus
    // the precomputedChunks) line up.
    text = expandAbbreviations(stripStageDirections(text));
    if (text.isEmpty) return null;

    final voice = (character != null && _characterVoices.containsKey(character))
        ? _characterVoices[character]!
        : 'af_heart';
    final speed = (character != null && _characterSpeeds.containsKey(character))
        ? _characterSpeeds[character]!
        : _currentSpeed;

    final chunks = _splitTextForKokoro(text);
    final futures = [
      for (final chunk in chunks)
        _synthesizeChunk(chunk, voice: voice, speed: speed).catchError((
          Object e,
        ) {
          DebugLogService.instance.logError(
            LogCategory.tts,
            'Kokoro prefetch chunk failed',
            e,
          );
          return null;
        }),
    ];
    unawaited(
      Future.wait(futures).then((paths) {
        if (paths.every((p) => p != null)) {
          DebugLogService.instance.log(
            LogCategory.tts,
            'Kokoro prefetch ready (${paths.length} chunk(s), voice=$voice)',
          );
        }
      }),
    );
    return futures;
  }

  double _currentSpeed = 1.0;

  /// Fire the completion handler exactly once per speak() call.
  /// Prevents stale/duplicate completion events from advancing the rehearsal.
  void _fireCompletion(String source) {
    if (_isSpeaking) {
      _isSpeaking = false;
      _currentTrace?.stop();
      _currentTrace = null;
      DebugLogService.instance.log(
        LogCategory.tts,
        'Completion fired (source=$source)',
      );
      _completionHandler?.call();
    } else {
      DebugLogService.instance.log(
        LogCategory.tts,
        'Completion IGNORED (source=$source, not speaking)',
      );
    }
  }

  /// Stop current speech. Does NOT fire the completion handler.
  /// [reason] logged for diagnostics (e.g. 'advanceLine', 'dispose').
  Future<void> stop({String reason = 'unknown'}) async {
    _speakGen++; // Invalidate any in-flight speak() call
    DebugLogService.instance.log(
      LogCategory.tts,
      'stop() called (gen=$_speakGen, wasSpeaking=$_isSpeaking, reason=$reason)',
    );
    _isSpeaking = false; // Prevent stop() from triggering completion
    _usingSystemTts = false; // Prevent stale system TTS completion
    _systemTtsWatchdog?.cancel();
    _systemTtsWatchdog = null;
    _cancelChunkWait?.call();
    _currentTrace?.stop();
    _currentTrace = null;
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

  /// Unload the active Kokoro engine from memory while keeping model files.
  /// Used to free RAM before a heavy operation like on-device LLM script
  /// cleanup, where Kokoro + a multi-GB LLM cannot both be resident. Falls
  /// back to system TTS until [tryLoadKokoro] reloads.
  Future<void> unloadKokoro() async {
    // Android can retain a loaded ONNX isolate even when Dart readiness became
    // stale, so always stop it before model-file deletion. Apple uses the MLX
    // platform channel and can skip the call when no model is loaded.
    if (!Platform.isAndroid && !_kokoroLoaded) return;
    try {
      if (Platform.isAndroid) {
        await KokoroOnnxService.instance.stop();
      } else {
        await _channel.invokeMethod('unloadModel');
      }
    } catch (e, stack) {
      DebugLogService.instance.logError(
        LogCategory.tts,
        'Kokoro unload failed',
        e,
        stack,
      );
      rethrow;
    }
    _activeEngine = TtsEngine.system;
    _setKokoroLoaded(false);
  }

  /// Delete the on-device Kokoro model to free storage.
  Future<void> deleteModel() async {
    try {
      await unloadKokoro();
      if (Platform.isAndroid) {
        await ModelManager.instance.deleteKokoro();
      } else {
        await _channel.invokeMethod('deleteModel');
      }
    } catch (e, stack) {
      DebugLogService.instance.logError(
        LogCategory.tts,
        'Kokoro delete failed',
        e,
        stack,
      );
      rethrow;
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
    _systemTtsWatchdog?.cancel();
    _cancelChunkWait?.call();
    _playerStateSub?.cancel();
    _audioPlayer.dispose();
    _kokoroLoadedNotifier.dispose();
  }
}
