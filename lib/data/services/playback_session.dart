import 'dart:io';

import 'package:audio_session/audio_session.dart';

import 'debug_log_service.dart';

/// Forces the shared audio session into a playback-capable state before we
/// play a recording.
///
/// Why this exists: rehearsal capture and the recorder leave iOS's shared
/// `AVAudioSession` in the `.record` category (set natively by AppleSttPlugin /
/// the `record` plugin). just_audio then "plays" in that category but produces
/// **no audible output** — and throws no error — so recordings sound empty even
/// though the files are full and valid. Switching the category to `.playback`
/// here restores sound. Nothing else in the app resets the category, since the
/// native TTS path only sets `.playback` when Kokoro actually speaks.
///
/// No-op on desktop (macOS has no AVAudioSession) and on any failure.
class PlaybackSession {
  PlaybackSession._();

  /// Configure + activate a playback session. Call immediately before
  /// `AudioPlayer.play()` for a recording. Cheap to call repeatedly — we
  /// reconfigure every time so a `.record` category left by STT is always
  /// overridden.
  static Future<void> ensurePlayback() async {
    if (!Platform.isIOS && !Platform.isAndroid) return;
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      await session.setActive(true);
    } catch (e) {
      DebugLogService.instance.logError(
        LogCategory.error,
        'PlaybackSession.ensurePlayback failed',
        e,
      );
    }
  }
}
