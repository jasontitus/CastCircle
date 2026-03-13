class AppConstants {
  AppConstants._();

  static const String appName = 'LineGuide';
  static const String appVersion = '0.1.0';

  // Default rehearsal settings
  static const int defaultJumpBackLines = 3;
  static const double defaultPlaybackSpeed = 1.0;
  static const int defaultMatchThreshold = 70; // % word overlap for line match

  // Audio settings
  static const int sampleRate = 44100;
  static const String audioExtension = '.m4a';

  // Script parser settings
  static const int minCharacterNameLength = 2;
  static const int maxCharacterNameLength = 50;
}
