/// A curated voice preset that maps a production style to Kokoro voice pools.
///
/// Each preset defines which Kokoro voices to use for female/male characters
/// and a default speed modifier to match the style's pacing.
class VoicePreset {
  final String id;
  final String name;
  final String description;
  final List<String> femaleVoices;
  final List<String> maleVoices;
  final double defaultSpeed; // 0.5–2.0, where 1.0 = normal

  const VoicePreset({
    required this.id,
    required this.name,
    required this.description,
    required this.femaleVoices,
    required this.maleVoices,
    this.defaultSpeed = 1.0,
  });

  /// All voices in this preset (female + male).
  List<String> get allVoices => [...femaleVoices, ...maleVoices];
}

/// Per-character voice configuration override.
class CharacterVoiceConfig {
  final String characterName;
  final String voiceId;
  final double speed; // 0.5–2.0

  const CharacterVoiceConfig({
    required this.characterName,
    required this.voiceId,
    this.speed = 1.0,
  });

  Map<String, dynamic> toJson() => {
    'characterName': characterName,
    'voiceId': voiceId,
    'speed': speed,
  };

  factory CharacterVoiceConfig.fromJson(Map<String, dynamic> json) =>
      CharacterVoiceConfig(
        characterName: json['characterName'] as String,
        voiceId: json['voiceId'] as String,
        speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
      );
}

/// Built-in voice presets for different production styles.
class VoicePresets {
  VoicePresets._();

  static const modernAmerican = VoicePreset(
    id: 'modern_american',
    name: 'Modern American',
    description: 'Natural contemporary American voices',
    femaleVoices: ['af_heart', 'af_bella', 'af_jessica', 'af_nova', 'af_sarah'],
    maleVoices: ['am_adam', 'am_eric', 'am_michael', 'am_onyx'],
    defaultSpeed: 1.0,
  );

  static const modernNewYork = VoicePreset(
    id: 'modern_new_york',
    name: 'Modern New York',
    description: 'Brisk, energetic American delivery',
    femaleVoices: ['af_jessica', 'af_nova', 'af_heart', 'af_sarah'],
    maleVoices: ['am_adam', 'am_onyx', 'am_eric'],
    defaultSpeed: 1.15,
  );

  static const victorianEnglish = VoicePreset(
    id: 'victorian_english',
    name: 'Victorian English',
    description: 'Measured British RP voices for period drama',
    femaleVoices: ['bf_alice', 'bf_emma', 'bf_isabella', 'bf_lily'],
    maleVoices: ['bm_daniel', 'bm_george', 'bm_lewis', 'bm_fable'],
    defaultSpeed: 0.9,
  );

  static const shakespearean = VoicePreset(
    id: 'shakespearean',
    name: 'Shakespearean',
    description: 'Slower, dramatic British voices for classical theatre',
    femaleVoices: ['bf_emma', 'bf_isabella', 'bf_alice', 'bf_lily'],
    maleVoices: ['bm_george', 'bm_daniel', 'bm_fable', 'bm_lewis'],
    defaultSpeed: 0.8,
  );

  static const classicBritish = VoicePreset(
    id: 'classic_british',
    name: 'Classic British',
    description: 'Warm British voices for Coward, Wilde, Stoppard',
    femaleVoices: ['bf_lily', 'bf_alice', 'bf_emma', 'bf_isabella'],
    maleVoices: ['bm_fable', 'bm_lewis', 'bm_daniel', 'bm_george'],
    defaultSpeed: 0.95,
  );

  static const southernAmerican = VoicePreset(
    id: 'southern_american',
    name: 'Southern American',
    description: 'Relaxed pacing for Williams, Henley, Foote',
    femaleVoices: ['af_bella', 'af_sarah', 'af_heart', 'af_nova'],
    maleVoices: ['am_michael', 'am_adam', 'am_eric'],
    defaultSpeed: 0.85,
  );

  static const musicalTheatre = VoicePreset(
    id: 'musical_theatre',
    name: 'Musical Theatre',
    description: 'Clear, projected voices for spoken dialogue in musicals',
    femaleVoices: ['af_nova', 'af_heart', 'bf_emma', 'af_jessica'],
    maleVoices: ['am_adam', 'bm_daniel', 'am_eric', 'am_onyx'],
    defaultSpeed: 1.0,
  );

  static const mixed = VoicePreset(
    id: 'mixed',
    name: 'Mixed (All Voices)',
    description: 'Full variety — all accents and styles',
    femaleVoices: [
      'af_heart',
      'af_bella',
      'af_jessica',
      'af_nova',
      'af_sarah',
      'bf_alice',
      'bf_emma',
      'bf_isabella',
      'bf_lily',
    ],
    maleVoices: [
      'am_adam',
      'am_eric',
      'am_michael',
      'am_onyx',
      'bm_daniel',
      'bm_fable',
      'bm_george',
      'bm_lewis',
    ],
    defaultSpeed: 1.0,
  );

  /// All available presets.
  static const List<VoicePreset> all = [
    modernAmerican,
    modernNewYork,
    victorianEnglish,
    shakespearean,
    classicBritish,
    southernAmerican,
    musicalTheatre,
    mixed,
  ];

  /// Look up a preset by ID. Returns [modernAmerican] if not found.
  static VoicePreset byId(String id) {
    return all.firstWhere((p) => p.id == id, orElse: () => modernAmerican);
  }

  /// All individual Kokoro voice IDs with human-readable labels.
  static const Map<String, String> voiceLabels = {
    // American Female
    'af_heart': 'Heart (American F)',
    'af_alloy': 'Alloy (American F)',
    'af_aoede': 'Aoede (American F)',
    'af_bella': 'Bella (American F)',
    'af_jessica': 'Jessica (American F)',
    'af_kore': 'Kore (American F)',
    'af_nicole': 'Nicole (American F)',
    'af_nova': 'Nova (American F)',
    'af_river': 'River (American F)',
    'af_sarah': 'Sarah (American F)',
    'af_sky': 'Sky (American F)',
    // American Male
    'am_adam': 'Adam (American M)',
    'am_echo': 'Echo (American M)',
    'am_eric': 'Eric (American M)',
    'am_fenrir': 'Fenrir (American M)',
    'am_liam': 'Liam (American M)',
    'am_michael': 'Michael (American M)',
    'am_onyx': 'Onyx (American M)',
    'am_puck': 'Puck (American M)',
    // British Female
    'bf_alice': 'Alice (British F)',
    'bf_emma': 'Emma (British F)',
    'bf_isabella': 'Isabella (British F)',
    'bf_lily': 'Lily (British F)',
    // British Male
    'bm_daniel': 'Daniel (British M)',
    'bm_fable': 'Fable (British M)',
    'bm_george': 'George (British M)',
    'bm_lewis': 'Lewis (British M)',
  };
}
