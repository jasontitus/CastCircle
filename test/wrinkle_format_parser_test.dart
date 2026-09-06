import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/script_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'parses indented Stage Partners colon cues after a scene-list preamble',
    () {
      const text = '''
    Cast of Characters
    MRS. WHICH
    MRS. WHO
    MEG
    CHARLES WALLACE
    CALVIN

    Scenes
    Act I Scene 1—Earth and Thereabouts
    Act I Scene 2—Into the Woods
    COPYRIGHT NOTICE: This front matter is not dialogue.

    Act I Scene 1—Earth and Thereabouts
      (Blackness. Lightning flashes.)
    MRS. WHICH: (Voice over:) It is time.
    MRS. WHO: Time flies by!
    yourstagepartners.com
    MEG: I hate this weather.
    CHARLES WALLACE: Whole house?

    Act I Scene 2—Into the Woods
    CALVIN: I was not hiding.
    https://www.yourstagepartners.com/
    MEG: Then why are you following us?
''';

      final script = ScriptParser().parse(text, title: 'A Wrinkle in Time');
      final names = script.characters
          .map((character) => character.name)
          .toSet();
      final dialogue = script.lines
          .where((line) => line.lineType == LineType.dialogue)
          .toList();

      expect(
        names,
        containsAll(<String>{
          'MRS. WHICH',
          'MRS. WHO',
          'MEG',
          'CHARLES WALLACE',
          'CALVIN',
        }),
      );
      expect(names, isNot(contains('COPYRIGHT NOTICE')));
      expect(dialogue, hasLength(6));
      expect(dialogue.first.character, 'MRS. WHICH');
      expect(script.rawText, isNot(contains('COPYRIGHT NOTICE')));
      expect(
        dialogue.every(
          (line) => !line.text.toLowerCase().contains('yourstagepartners.com'),
        ),
        isTrue,
      );
      expect(
        script.rawText.toLowerCase(),
        isNot(contains('yourstagepartners.com')),
      );
      expect(script.rawText, contains('Act I Scene 1—Earth and Thereabouts'));
    },
  );
}
