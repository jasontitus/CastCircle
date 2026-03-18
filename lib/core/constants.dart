class AppConstants {
  AppConstants._();

  static const String appName = 'CastCircle';
  static const String appVersion = '0.1.0';

  // Default rehearsal settings
  static const int defaultJumpBackLines = 3;
  static const double defaultPlaybackSpeed = 1.0;
  static const int defaultMatchThreshold = 70; // % word overlap for line match

  // Fast mode settings
  static const double defaultFastModeSpeed = 1.5;
  static const int defaultLineDelay = 300; // ms between lines (normal)
  static const int defaultFastModeLineDelay = 0; // ms between lines (fast)

  // Audio settings
  static const int sampleRate = 44100;
  static const String audioExtension = '.m4a';

  // Script parser settings
  static const int minCharacterNameLength = 2;
  static const int maxCharacterNameLength = 50;
}
