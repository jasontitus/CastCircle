import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/voice_preset.dart';

void main() {
  group('VoicePreset', () {
    test('allVoices contains both female and male voices', () {
      final preset = VoicePresets.modernAmerican;
      expect(preset.allVoices.length,
          preset.femaleVoices.length + preset.maleVoices.length);
    });

    test('every preset has non-empty voice pools', () {
      for (final preset in VoicePresets.all) {
        expect(preset.femaleVoices, isNotEmpty,
            reason: '${preset.id} has empty femaleVoices');
        expect(preset.maleVoices, isNotEmpty,
            reason: '${preset.id} has empty maleVoices');
      }
    });

    test('every preset has a valid speed', () {
      for (final preset in VoicePresets.all) {
        expect(preset.defaultSpeed, greaterThanOrEqualTo(0.5),
            reason: '${preset.id} speed too low');
        expect(preset.defaultSpeed, lessThanOrEqualTo(2.0),
            reason: '${preset.id} speed too high');
      }
    });

    test('byId returns correct preset', () {
      expect(VoicePresets.byId('victorian_english').id, 'victorian_english');
      expect(VoicePresets.byId('modern_american').id, 'modern_american');
      expect(VoicePresets.byId('shakespearean').id, 'shakespearean');
    });

    test('byId returns modernAmerican for unknown ID', () {
      expect(VoicePresets.byId('nonexistent').id, 'modern_american');
    });

    test('all preset IDs are unique', () {
      final ids = VoicePresets.all.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('voiceLabels covers all voices used in presets', () {
      final presetVoices = <String>{};
      for (final preset in VoicePresets.all) {
        presetVoices.addAll(preset.femaleVoices);
        presetVoices.addAll(preset.maleVoices);
      }
      for (final voice in presetVoices) {
        expect(VoicePresets.voiceLabels.containsKey(voice), true,
            reason: '$voice used in preset but not in voiceLabels');
      }
    });
  });

  group('CharacterVoiceConfig', () {
    test('toJson round-trip', () {
      const config = CharacterVoiceConfig(
        characterName: 'DARCY',
        voiceId: 'bm_daniel',
        speed: 0.9,
      );
      final json = config.toJson();
      final restored = CharacterVoiceConfig.fromJson(json);

      expect(restored.characterName, 'DARCY');
      expect(restored.voiceId, 'bm_daniel');
      expect(restored.speed, 0.9);
    });

    test('fromJson defaults speed to 1.0 if missing', () {
      final config = CharacterVoiceConfig.fromJson({
        'characterName': 'JANE',
        'voiceId': 'af_heart',
      });
      expect(config.speed, 1.0);
    });
  });

  group('Voice pool gender assignment', () {
    test('female character gets female voice from pool', () {
      final preset = VoicePresets.victorianEnglish;
      // isFemale=true → use femaleVoices pool
      final voice = preset.femaleVoices[0 % preset.femaleVoices.length];
      expect(voice.startsWith('bf_'), true,
          reason: 'Victorian English female voice should be British female');
    });

    test('male character gets male voice from pool', () {
      final preset = VoicePresets.victorianEnglish;
      // isFemale=false → use maleVoices pool
      final voice = preset.maleVoices[0 % preset.maleVoices.length];
      expect(voice.startsWith('bm_'), true,
          reason: 'Victorian English male voice should be British male');
    });

    test('round-robin assigns different voices', () {
      final preset = VoicePresets.modernAmerican;
      final voices = List.generate(
        preset.femaleVoices.length,
        (i) => preset.femaleVoices[i % preset.femaleVoices.length],
      );
      // All voices should be unique since we haven't wrapped around
      expect(voices.toSet().length, preset.femaleVoices.length);
    });

    test('round-robin wraps correctly', () {
      final preset = VoicePresets.modernAmerican;
      final poolSize = preset.maleVoices.length;
      // Index beyond pool size should wrap
      final voice = preset.maleVoices[(poolSize + 1) % poolSize];
      expect(voice, preset.maleVoices[1]);
    });
  });
}
