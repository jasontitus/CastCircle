import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/voice_config_service.dart';
import 'package:castcircle/providers/production_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Gender is NOT stored on the persisted line rows — it is re-derived every
/// time a production is opened. That makes it easy to lose a correction the
/// user made by hand, which is exactly what happened: the load path used by
/// the home screen rebuilt characters with inference alone, so a gender set
/// in the character manager reverted the next time the production opened.
List<ScriptLine> linesFor(List<String> speakers) => [
      for (var i = 0; i < speakers.length; i++)
        ScriptLine(
          id: 'l$i',
          act: 'ACT I',
          scene: 'Scene 1',
          lineNumber: i,
          orderIndex: i,
          character: speakers[i],
          text: 'Line $i',
          lineType: LineType.dialogue,
        ),
    ];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('an explicit choice beats inference', () {
    final script = buildParsedScript('Play', linesFor(['KING', 'OPHELIA']),
        savedGenders: {'KING': CharacterGender.female});

    final king = script.characters.firstWhere((c) => c.name == 'KING');
    final ophelia = script.characters.firstWhere((c) => c.name == 'OPHELIA');
    // Casting against type is a legitimate directorial choice — the point is
    // that the app must not argue with it.
    expect(king.gender, CharacterGender.female);
    // Untouched characters still get inference.
    expect(ophelia.gender, CharacterGender.female);
  });

  test('inference still applies where nothing was set', () {
    final script = buildParsedScript('Play', linesFor(['KING', 'QUEEN']));
    expect(script.characters.firstWhere((c) => c.name == 'KING').gender,
        CharacterGender.male);
    expect(script.characters.firstWhere((c) => c.name == 'QUEEN').gender,
        CharacterGender.female);
  });

  test('a gender saved for one production survives a rebuild', () async {
    const productionId = 'p1';
    await VoiceConfigService.instance
        .setGender(productionId, 'HAMLET', CharacterGender.female);

    final saved = await VoiceConfigService.instance.getGenders(productionId);
    expect(saved['HAMLET'], CharacterGender.female,
        reason: 'the choice must be readable back');

    final script = buildParsedScript('Hamlet', linesFor(['HAMLET']),
        savedGenders: saved);
    expect(script.characters.single.gender, CharacterGender.female);
  });

  test('choices are scoped to their production', () async {
    await VoiceConfigService.instance
        .setGender('p1', 'HAMLET', CharacterGender.female);

    final other = await VoiceConfigService.instance.getGenders('p2');
    expect(other['HAMLET'], isNull,
        reason: 'casting in one show must not follow the name into another');

    final script =
        buildParsedScript('Hamlet', linesFor(['HAMLET']), savedGenders: other);
    expect(script.characters.single.gender, CharacterGender.male);
  });
}
