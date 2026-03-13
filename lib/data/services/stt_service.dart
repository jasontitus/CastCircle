import 'package:speech_to_text/speech_to_text.dart';

/// Speech-to-text service using system STT as fallback.
/// Will be replaced by Whisper on-device STT in Phase 6.
class SttService {
  SttService._();
  static final instance = SttService._();

  final SpeechToText _stt = SpeechToText();
  bool _initialized = false;
  bool _isListening = false;

  bool get isListening => _isListening;

  Future<bool> init() async {
    if (_initialized) return true;
    _initialized = await _stt.initialize();
    return _initialized;
  }

  /// Start listening for speech. Calls [onResult] with recognized words.
  /// Calls [onDone] when listening stops.
  Future<void> listen({
    required void Function(String recognizedWords) onResult,
    void Function()? onDone,
  }) async {
    if (!_initialized) {
      final ok = await init();
      if (!ok) return;
    }

    _isListening = true;
    await _stt.listen(
      onResult: (result) {
        onResult(result.recognizedWords);
        if (result.finalResult) {
          _isListening = false;
          onDone?.call();
        }
      },
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 3),
      listenOptions: SpeechListenOptions(listenMode: ListenMode.dictation),
    );
  }

  /// Stop listening.
  Future<void> stop() async {
    _isListening = false;
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
