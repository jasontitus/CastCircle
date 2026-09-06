import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/voice_config_service.dart';
import 'package:castcircle/data/models/voice_preset.dart';

void main() {
  group('VoicePreset', () {
    test('allVoices contains both female and male voices', () {
      final preset = VoicePresets.modernAmerican;
      expect(
        preset.allVoices.length,
        preset.femaleVoices.length + preset.maleVoices.length,
      );
    });

    test('every preset has non-empty voice pools', () {
      for (final preset in VoicePresets.all) {
        expect(
          preset.femaleVoices,
          isNotEmpty,
          reason: '${preset.id} has empty femaleVoices',
        );
        expect(
          preset.maleVoices,
          isNotEmpty,
          reason: '${preset.id} has empty maleVoices',
        );
      }
    });

    test('every preset has a valid speed', () {
      for (final preset in VoicePresets.all) {
        expect(
          preset.defaultSpeed,
          greaterThanOrEqualTo(0.5),
          reason: '${preset.id} speed too low',
        );
        expect(
          preset.defaultSpeed,
          lessThanOrEqualTo(2.0),
          reason: '${preset.id} speed too high',
        );
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
        expect(
          VoicePresets.voiceLabels.containsKey(voice),
          true,
          reason: '$voice used in preset but not in voiceLabels',
        );
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

  group('VoiceConfigService.assignVoicesFromScript', () {
    test('assigns characters from their gender-specific pools', () {
      const characters = [
        ScriptCharacter(
          name: 'ELIZABETH',
          colorIndex: 0,
          lineCount: 2,
          gender: CharacterGender.female,
        ),
        ScriptCharacter(
          name: 'DARCY',
          colorIndex: 1,
          lineCount: 2,
          gender: CharacterGender.male,
        ),
      ];

      final assignments = VoiceConfigService.assignVoicesFromScript(
        lines: const [],
        characters: characters,
        femaleVoices: const ['female-1'],
        maleVoices: const ['male-1'],
      );

      expect(assignments, {'ELIZABETH': 'female-1', 'DARCY': 'male-1'});
    });

    test('adjacent speakers receive different voices when possible', () {
      const characters = [
        ScriptCharacter(name: 'A', colorIndex: 0, lineCount: 2),
        ScriptCharacter(name: 'B', colorIndex: 1, lineCount: 2),
        ScriptCharacter(name: 'C', colorIndex: 2, lineCount: 2),
      ];
      const lines = [
        ScriptLine(
          id: '1',
          act: 'ACT I',
          scene: 'Scene 1',
          lineNumber: 1,
          orderIndex: 1,
          character: 'A',
          text: 'First',
          lineType: LineType.dialogue,
        ),
        ScriptLine(
          id: '2',
          act: 'ACT I',
          scene: 'Scene 1',
          lineNumber: 2,
          orderIndex: 2,
          character: 'B',
          text: 'Second',
          lineType: LineType.dialogue,
        ),
        ScriptLine(
          id: '3',
          act: 'ACT I',
          scene: 'Scene 1',
          lineNumber: 3,
          orderIndex: 3,
          character: 'C',
          text: 'Third',
          lineType: LineType.dialogue,
        ),
      ];

      final assignments = VoiceConfigService.assignVoicesFromScript(
        lines: lines,
        characters: characters,
        femaleVoices: const ['voice-1', 'voice-2'],
        maleVoices: const [],
        window: 1,
      );

      expect(assignments['A'], isNot(assignments['B']));
      expect(assignments['B'], isNot(assignments['C']));
      expect(assignments['A'], assignments['C']);
    });

    test('gender overrides change the selected voice pool', () {
      const character = ScriptCharacter(
        name: 'PAGE',
        colorIndex: 0,
        lineCount: 1,
      );

      final assignments = VoiceConfigService.assignVoicesFromScript(
        lines: const [],
        characters: const [character],
        femaleVoices: const ['female-1'],
        maleVoices: const ['male-1'],
        genderOverrides: const {'PAGE': CharacterGender.male},
      );

      expect(assignments['PAGE'], 'male-1');
    });
  });
}
