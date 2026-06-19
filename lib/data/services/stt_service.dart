import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'stt_channel.dart';
import 'debug_log_service.dart';
import 'mlx_stt_channel.dart';

/// STT engine type.
enum SttEngine {
  /// Apple SFSpeechRecognizer with contextualStrings (primary — real-time).
  apple,

  /// MLX Parakeet batch transcription (for file transcription).
  mlx,
}

/// Speech-to-text service.
///
/// Primary engine: Apple SFSpeechRecognizer via custom platform channel
/// with contextualStrings for vocabulary hinting. Provides real-time
/// streaming results — words appear as you speak.
///
/// MLX Parakeet is available for batch file transcription but not used
/// for live mic input (it's a batch model, not streaming).
class SttService {
  SttService._();
  static final instance = SttService._();

  final SttChannel _sttChannel = SttChannel.instance;
  final MlxSttChannel _mlxChannel = MlxSttChannel.instance;

  bool _isListening = false;
  SttEngine _activeEngine = SttEngine.apple;

  String _locale = 'en-US';

  SttEngine get activeEngine => _activeEngine;
  bool get isListening => _isListening;
  bool get isMlxReady => _mlxChannel.isInitialized;
  bool get isAvailable => _sttChannel.isInitialized;
  String get locale => _locale;

  /// Initialize the STT engine.
  ///
  /// [locale] — BCP-47 locale (e.g. "en-US", "en-GB"). Use "en-GB" for
  /// British/classical/Shakespearean scripts to improve recognition of
  /// British vocabulary and speech patterns.
  Future<bool> init({String locale = 'en-US'}) async {
    _locale = locale;

    // Screenshot mode: skip native STT init so we don't trigger the iOS
    // speech recognition permission dialog, which blocks the screenshot run.
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('screenshot_mode') == true) {
        DebugLogService.instance.log(
            LogCategory.stt, 'Screenshot mode: skipping STT init');
        return false;
      }
    } catch (_) {}

    // Dispose any previously loaded MLX model to free memory —
    // we use the native OS recognizer now; Parakeet is only for batch transcription
    _mlxChannel.dispose();

    // Apple SFSpeechRecognizer — real-time streaming with vocabulary hints
    final appleOk = await _sttChannel.initialize(locale: locale);
    if (appleOk) {
      _activeEngine = SttEngine.apple;
      DebugLogService.instance.log(LogCategory.stt,
          'STT ready (locale=$locale, contextualStrings)');
      return true;
    }

    DebugLogService.instance.logError(LogCategory.stt, 'No STT engine available');
    return false;
  }

  /// Re-attempt MLX init (for batch file transcription).
  Future<bool> reloadMlx() async {
    try {
      final ok = await _mlxChannel.initialize('builtin');
      return ok;
    } catch (e) {
      debugPrint('STT: MLX init failed: $e');
      return false;
    }
  }

  // Stored callbacks for continuous mode restarts
  void Function(String)? _onResult;
  void Function()? _onDone;
  bool _continuous = false;
  List<String>? _vocabHints;

  // ── Carried transcript (mcpzim-style) ─────────────────
  //
  // Apple's recognizer auto-finalizes after ~0.6s of intra-utterance
  // silence. Without carrying, each restarted session begins from
  // scratch and a dramatic pause mid-line wipes the transcript (and
  // the match score with it). We fold finalized text into a carried
  // prefix and emit the merged transcript so the line accumulates
  // seamlessly across pauses.
  String _carriedTranscript = '';
  String _lastPartial = '';

  // ── Input level / endpointing ──────────────────────────
  //
  // The native tap reports mic energy ~12×/s. We smooth it with a
  // 1-pole low-pass for UI and track how long the input has been
  // below the speech threshold for end-of-utterance detection.
  double _smoothedLevel = 0;
  DateTime? _silenceStart;
  bool _hasSpeechInUtterance = false;

  /// Mic input below this (smoothed RMS, 0..1) counts as silence.
  static const double silenceThreshold = 0.02;

  /// Smoothed mic input level (0..1) for UI animation.
  double get inputLevel => _smoothedLevel;

  /// Called with the smoothed input level (0..1) on every level event.
  void Function(double level)? onLevel;

  /// Called with the current silence duration on every level event while
  /// listening. [Duration.zero] while the actor is speaking. Only fires
  /// after some speech has been heard in this utterance, so leading
  /// silence (thinking before the line) never triggers endpointing.
  void Function(Duration silence)? onSilence;

  void _handleLevel(double level) {
    // 1-pole low-pass: responsive but non-strobing for UI
    _smoothedLevel = 0.7 * _smoothedLevel + 0.3 * level;
    onLevel?.call(_smoothedLevel);

    if (!_isListening) return;

    if (_smoothedLevel >= silenceThreshold) {
      _hasSpeechInUtterance = true;
      _silenceStart = null;
      onSilence?.call(Duration.zero);
    } else if (_hasSpeechInUtterance) {
      _silenceStart ??= DateTime.now();
      onSilence?.call(DateTime.now().difference(_silenceStart!));
    }
  }

  /// Merge two transcript fragments with whitespace-aware joining.
  @visibleForTesting
  static String mergeTranscripts(String carried, String partial) {
    final a = carried.trim();
    final b = partial.trim();
    if (a.isEmpty) return b;
    if (b.isEmpty) return a;
    return '$a $b';
  }

  /// Start listening for speech. Calls [onResult] with recognized words
  /// in real-time as they are spoken.
  ///
  /// The text passed to [onResult] is cumulative across the recognizer's
  /// automatic finalizations — pauses mid-line don't reset it.
  ///
  /// [vocabularyHints] — words/phrases to boost in recognition. Pass
  /// character names, script-specific terms, or the expected line's words
  /// to improve accuracy.
  ///
  /// When [continuous] is true, listening automatically restarts after
  /// each recognition session until [stop] is called.
  Future<void> listen({
    required void Function(String recognizedWords) onResult,
    void Function()? onDone,
    bool continuous = false,
    Duration listenFor = const Duration(seconds: 30),
    List<String>? vocabularyHints,
  }) async {
    // Auto-init if needed
    if (!_sttChannel.isInitialized) {
      final ok = await init();
      if (!ok) {
        onDone?.call();
        return;
      }
    }

    _isListening = true;
    _continuous = continuous;
    _onResult = onResult;
    _onDone = onDone;
    _vocabHints = vocabularyHints;
    _carriedTranscript = '';
    _lastPartial = '';
    _silenceStart = null;
    _hasSpeechInUtterance = false;
    _sttChannel.onLevel = _handleLevel;

    await _startAppleSession();
  }

  Future<void> _startAppleSession() async {
    if (!_isListening) return;

    final ok = await _sttChannel.listen(
      contextualStrings: _vocabHints,
      onResult: (text, isFinal) {
        _lastPartial = text;
        _onResult?.call(mergeTranscripts(_carriedTranscript, text));
      },
      onDone: () {
        if (_continuous && _isListening) {
          // The recognizer auto-finalized (intra-utterance pause).
          // Carry the finalized text forward and restart so the
          // transcript keeps accumulating.
          _carriedTranscript =
              mergeTranscripts(_carriedTranscript, _lastPartial);
          _lastPartial = '';
          // Auto-restart after brief pause
          Future.delayed(const Duration(milliseconds: 200), () {
            if (_isListening) {
              _startAppleSession();
            }
          });
        } else {
          _isListening = false;
          _onDone?.call();
          _onResult = null;
          _onDone = null;
        }
      },
    );

    if (!ok) {
      _isListening = false;
      _onDone?.call();
      _onResult = null;
      _onDone = null;
    }
  }

  /// Stop listening.
  ///
  /// [discard] parameter kept for API compatibility but not needed
  /// for Apple engine (no pending transcription to discard).
  Future<void> stop({bool discard = false}) async {
    _isListening = false;
    _continuous = false;
    _onResult = null;
    _onDone = null;
    _vocabHints = null;
    _carriedTranscript = '';
    _lastPartial = '';
    _silenceStart = null;
    _hasSpeechInUtterance = false;
    onSilence = null;
    onLevel = null;
    await _sttChannel.stop();
  }

  /// Transcribe a pre-recorded audio file (MLX Parakeet only).
  Future<String?> transcribeFile(String audioPath,
      {List<String>? vocabularyHints}) async {
    if (_mlxChannel.isInitialized) {
      return _mlxChannel.transcribe(audioPath,
          vocabularyHints: vocabularyHints);
    }
    return null;
  }

  // ── Match Score ───────────────────────────────────────

  /// Match score using Longest Common Subsequence (LCS) of words.
  ///
  /// Unlike simple set overlap, this respects word order — the user
  /// must say the words in roughly the right sequence to score well.
  /// Handles insertions, deletions, and STT adding extra words gracefully.
  static double matchScore(String expected, String spoken) {
    // Stage directions in parentheses/brackets aren't spoken by the actor, so
    // don't count them as expected words (otherwise "(crossing)" would make
    // "crossing" a word the actor is penalized for not saying).
    final dialogueExpected = expected
        .replaceAll(RegExp(r'\([^)]*\)'), ' ')
        .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
        .replaceAll(RegExp(r'[(\[][^)\]]*$'), ' '); // unclosed (OCR-dropped close)
    final normalizedExpected = _normalize(dialogueExpected);
    if (normalizedExpected.isEmpty) return 1.0;

    final expectedWords = normalizedExpected.split(RegExp(r'\s+'));
    final spokenWords = _normalize(spoken).split(RegExp(r'\s+'));

    if (spokenWords.isEmpty || (spokenWords.length == 1 && spokenWords[0].isEmpty)) {
      return 0.0;
    }

    // LCS with fuzzy word matching (edit distance ≤ 1 counts as match)
    final m = expectedWords.length;
    final n = spokenWords.length;
    final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));

    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= n; j++) {
        if (_wordsMatch(expectedWords[i - 1], spokenWords[j - 1])) {
          dp[i][j] = dp[i - 1][j - 1] + 1;
        } else {
          dp[i][j] = dp[i - 1][j] > dp[i][j - 1]
              ? dp[i - 1][j]
              : dp[i][j - 1];
        }
      }
    }

    return dp[m][n] / m;
  }

  /// Check if two words match — exact or within edit distance 1.
  static bool _wordsMatch(String a, String b) {
    if (a == b) return true;
    if ((a.length - b.length).abs() > 1) return false;

    // Quick single-char edit distance check
    int diffs = 0;
    if (a.length == b.length) {
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) diffs++;
        if (diffs > 1) return false;
      }
      return true;
    }

    // Handle insertion/deletion (lengths differ by 1)
    final shorter = a.length < b.length ? a : b;
    final longer = a.length < b.length ? b : a;
    var si = 0;
    for (var li = 0; li < longer.length && si < shorter.length; li++) {
      if (shorter[si] == longer[li]) {
        si++;
      } else {
        diffs++;
        if (diffs > 1) return false;
      }
    }
    return true;
  }

  static String _normalize(String text) {
    return text.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '').trim();
  }

  // ── Concurrent Recording ─────────────────────────────

  /// Start recording audio alongside STT (same mic tap).
  /// The audio file will be saved to [path] as .m4a.
  Future<bool> startRecording(String path) async {
    DebugLogService.instance.log(LogCategory.rehearsal,
        'STT.startRecording: $path');
    final ok = await _sttChannel.startRecording(path);
    DebugLogService.instance.log(LogCategory.rehearsal,
        'STT.startRecording → $ok');
    return ok;
  }

  /// Stop recording and finalize the file.
  /// Returns {path, durationMs} or null.
  Future<Map<String, dynamic>?> stopRecording() async {
    DebugLogService.instance.log(LogCategory.rehearsal,
        'STT.stopRecording: calling...');
    final result = await _sttChannel.stopRecording();
    if (result != null) {
      DebugLogService.instance.log(LogCategory.rehearsal,
          'STT.stopRecording → path=${result['path']}, duration=${result['durationMs']}ms');
    } else {
      DebugLogService.instance.log(LogCategory.rehearsal,
          'STT.stopRecording → null (not recording?)');
    }
    return result;
  }

  // ── Helpers ───────────────────────────────────────────

  void dispose() {
    _sttChannel.dispose();
    _mlxChannel.dispose();
  }
}
