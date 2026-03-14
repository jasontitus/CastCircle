import 'package:speech_to_text/speech_to_text.dart';

/// Speech-to-text service using system STT as fallback.
/// Will be replaced by Whisper on-device STT in Phase 6.
class SttService {
  SttService._();
  static final instance = SttService._();

  final SpeechToText _stt = SpeechToText();
  bool _initialized = false;
  bool _isListening = false;
  bool _continuousMode = false;

  bool get isListening => _isListening;

  Future<bool> init() async {
    if (_initialized) return true;
    _initialized = await _stt.initialize();
    return _initialized;
  }

  /// Start listening for speech. Calls [onResult] with recognized words.
  /// Calls [onDone] when listening stops (only fires when [continuous] is
  /// false or after [stop] is called).
  ///
  /// When [continuous] is true, listening automatically restarts after each
  /// pause/timeout until [stop] is called explicitly. This keeps the mic
  /// open so the actor can take their time before speaking.
  Future<void> listen({
    required void Function(String recognizedWords) onResult,
    void Function()? onDone,
    bool continuous = false,
  }) async {
    if (!_initialized) {
      final ok = await init();
      if (!ok) return;
    }

    _isListening = true;
    _continuousMode = continuous;

    await _startListenSession(onResult: onResult, onDone: onDone);
  }

  Future<void> _startListenSession({
    required void Function(String recognizedWords) onResult,
    void Function()? onDone,
  }) async {
    await _stt.listen(
      onResult: (result) {
        onResult(result.recognizedWords);
        if (result.finalResult) {
          if (_continuousMode && _isListening) {
            // Auto-restart after a brief pause so the mic stays open
            Future.delayed(const Duration(milliseconds: 200), () {
              if (_isListening) {
                _startListenSession(onResult: onResult, onDone: onDone);
              }
            });
          } else {
            _isListening = false;
            onDone?.call();
          }
        }
      },
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 5),
      listenOptions: SpeechListenOptions(listenMode: ListenMode.dictation),
    );
  }

  /// Stop listening. Also exits continuous mode.
  Future<void> stop() async {
    _isListening = false;
    _continuousMode = false;
    await _stt.stop();
  }

  /// Check if speech recognition is available.
  Future<bool> get isAvailable async {
    if (!_initialized) await init();
    return _initialized;
  }

  /// Simple fuzzy match: what percentage of expected words were spoken.
  static double matchScore(String expected, String spoken) {
    final normalizedExpected = _normalize(expected);
    if (normalizedExpected.isEmpty) return 1.0;

    final expectedWords = normalizedExpected.split(RegExp(r'\s+'));
    final spokenWords = _normalize(spoken).split(RegExp(r'\s+'));

    int matched = 0;
    for (final word in expectedWords) {
      if (spokenWords.contains(word)) matched++;
    }

    return matched / expectedWords.length;
  }

  static String _normalize(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .trim();
  }
}
