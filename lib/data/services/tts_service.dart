import 'package:flutter_tts/flutter_tts.dart';

/// Text-to-speech service using system TTS as fallback.
/// Will be replaced by Kokoro on-device TTS in Phase 6.
class TtsService {
  TtsService._();
  static final instance = TtsService._();

  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;

  // Map character names to voice indices for variety
  final Map<String, Map<String, String>> _characterVoices = {};
  List<dynamic> _availableVoices = [];

  Future<void> init() async {
    if (_initialized) return;

    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _availableVoices = await _tts.getVoices as List<dynamic>;
    _initialized = true;
  }

  /// Assign a distinct voice to a character for variety during rehearsal.
  void assignVoice(String character, int characterIndex) {
    if (_availableVoices.isEmpty) return;

    // Cycle through available voices by index
    final voiceIdx = characterIndex % _availableVoices.length;
    final voice = _availableVoices[voiceIdx];
    if (voice is Map) {
      _characterVoices[character] = Map<String, String>.from(voice);
    }
  }

  /// Speak text for a character, using their assigned voice if available.
  Future<void> speak(String text, {String? character}) async {
    if (!_initialized) await init();

    if (character != null && _characterVoices.containsKey(character)) {
      final voice = _characterVoices[character]!;
      await _tts.setVoice(voice);
    }

    await _tts.speak(text);
  }

  /// Stop current speech.
  Future<void> stop() async {
    await _tts.stop();
  }

  /// Set playback speed (0.0 to 1.0, where 0.5 is normal).
  Future<void> setRate(double rate) async {
    await _tts.setSpeechRate(rate);
  }

  /// Listen for TTS completion events.
  void setCompletionHandler(Function handler) {
    _tts.setCompletionHandler(() => handler());
  }
}
