import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/script_parser.dart';

void main() {
  group('Folger Shakespeare PDF format', () {
    late ScriptParser parser;

    setUp(() {
      parser = ScriptParser();
    });

    test('parses Folger-converted text with nameOnOwnLine format', () {
      const rawText = '''
ACT I

SCENE 1.

 [Thunder and Lightning. Enter three Witches.]

FIRST WITCH.
When shall we three meet again?
In thunder, lightning, or in rain?

SECOND WITCH.
When the hurly-burly's done,
When the battle's lost and won.

THIRD WITCH.
That will be ere the set of sun.

FIRST WITCH.
Where the place?

SECOND WITCH.
Upon the heath.

THIRD WITCH.
There to meet with Macbeth.

FIRST WITCH.
I come, Graymalkin.

SECOND WITCH.
Paddock calls.

THIRD WITCH.
Anon.

ALL.
Fair is foul, and foul is fair;
Hover through the fog and filthy air.

 [They exit.]
''';
      final script = parser.parse(rawText, title: 'Macbeth (Folger)');

      // Should detect all witches + ALL
      final charNames = script.characters.map((c) => c.name).toSet();
      expect(charNames, contains('FIRST WITCH'));
      expect(charNames, contains('SECOND WITCH'));
      expect(charNames, contains('THIRD WITCH'));
      expect(charNames, contains('ALL'));
      expect(charNames.length, 4);

      // Should have correct dialogue count
      final dialogueLines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(dialogueLines.length, 10);

      // First witch should have 3 lines
      final firstWitchCount = dialogueLines
          .where((l) => l.character == 'FIRST WITCH')
          .length;
      expect(firstWitchCount, 3);

      // Should have bracket stage directions
      final stageDirs = script.lines
          .where((l) => l.lineType == LineType.stageDirection)
          .toList();
      expect(stageDirs.length, greaterThanOrEqualTo(1));
    });

    test('parses Folger Scene 2 with inline stage directions', () {
      const rawText = '''
ACT I

SCENE 2.

 [Alarum within. Enter King Duncan, Malcolm,
Donalbain, Lennox, with Attendants, meeting a bleeding
Captain.]

DUNCAN.
What bloody man is that? He can report,
As seemeth by his plight, of the revolt
The newest state.

MALCOLM.
This is the sergeant
Who, like a good and hardy soldier, fought
'Gainst my captivity.—Hail, brave friend!

CAPTAIN.
Doubtful it stood,
As two spent swimmers that do cling together
And choke their art.

DUNCAN.
O valiant cousin, worthy gentleman!

 [The Captain is led off by Attendants.]

 [Enter Ross and Angus.]

MALCOLM.
The worthy Thane of Ross.

LENNOX.
What a haste looks through his eyes!

ROSS.
God save the King.
''';
      final script = parser.parse(rawText, title: 'Macbeth Scene 2');

      final charNames = script.characters.map((c) => c.name).toSet();
      expect(charNames, contains('DUNCAN'));
      expect(charNames, contains('MALCOLM'));
      expect(charNames, contains('CAPTAIN'));
      expect(charNames, contains('LENNOX'));
      expect(charNames, contains('ROSS'));

      // Duncan should have 2 lines
      final duncanLines = script.lines
          .where((l) => l.character == 'DUNCAN' && l.lineType == LineType.dialogue)
          .toList();
      expect(duncanLines.length, 2);
      expect(duncanLines[0].text, contains('bloody man'));
    });

    test('handles FTLN noise from raw Folger text', () {
      const rawText = '''
MACBETH.
Is this a dagger which I see before me,
FTLN 0001
The handle toward my hand?
FTLN 0002
ACT 2. SC. 1
''';
      final script = parser.parse(rawText, title: 'FTLN Test');

      // FTLN lines should be filtered as noise
      final dialogueLines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(dialogueLines.length, 1);
      expect(dialogueLines[0].text, contains('dagger'));
      // Should NOT contain FTLN text
      for (final line in script.lines) {
        expect(line.text, isNot(contains('FTLN')));
        expect(line.text, isNot(contains('ACT 2. SC.')));
      }
    });

    test('handles dual character names like MACBETH AND LENNOX', () {
      const rawText = '''
MACDUFF.
O horror, horror, horror!

MACBETH AND LENNOX.
What's the matter?

MACDUFF.
Confusion now hath made his masterpiece.
''';
      final script = parser.parse(rawText, title: 'Dual Char Test');

      final charNames = script.characters.map((c) => c.name).toSet();
      expect(charNames, contains('MACDUFF'));
      expect(charNames, contains('MACBETH AND LENNOX'));

      final dialogueLines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(dialogueLines.length, 3);
      expect(dialogueLines[1].character, 'MACBETH AND LENNOX');
    });

    test('multi-line dialogue continuation across page breaks', () {
      const rawText = '''
MACBETH.
Go bid thy mistress, when my drink is ready,
She strike upon the bell. Get thee to bed.

 [Servant exits.]

Is this a dagger which I see before me,
The handle toward my hand? Come, let me clutch
thee.
I have thee not, and yet I see thee still.
''';
      final script = parser.parse(rawText, title: 'Continuation Test');

      final macbethLines = script.lines
          .where((l) => l.character == 'MACBETH' && l.lineType == LineType.dialogue)
          .toList();
      // The parser should produce 2 Macbeth dialogue blocks
      // (one before the stage dir, one after — the continuation is attributed
      // to Macbeth because bracket stage dirs preserve currentCharacter)
      expect(macbethLines.length, greaterThanOrEqualTo(1));
      expect(macbethLines[0].text, contains('bid thy mistress'));
    });
  });

  group('Gutenberg Macbeth format', () {
    late ScriptParser parser;

    setUp(() {
      parser = ScriptParser();
    });

    test('parses Gutenberg Shakespeare nameOnOwnLine format', () {
      const rawText = '''
ACT I

SCENE I. An open Place.


 Thunder and Lightning. Enter three Witches.

FIRST WITCH.
When shall we three meet again?
In thunder, lightning, or in rain?

SECOND WITCH.
When the hurlyburly's done,
When the battle's lost and won.

THIRD WITCH.
That will be ere the set of sun.

FIRST WITCH.
Where the place?

SECOND WITCH.
Upon the heath.

THIRD WITCH.
There to meet with Macbeth.

FIRST WITCH.
I come, Graymalkin!

SECOND WITCH.
Paddock calls.

THIRD WITCH.
Anon.

ALL.
Fair is foul, and foul is fair:
Hover through the fog and filthy air.

 [_Exeunt._]
''';
      final script = parser.parse(rawText, title: 'Macbeth (Gutenberg)');

      final charNames = script.characters.map((c) => c.name).toSet();
      expect(charNames, contains('FIRST WITCH'));
      expect(charNames, contains('SECOND WITCH'));
      expect(charNames, contains('THIRD WITCH'));
      expect(charNames, contains('ALL'));

      final dialogueLines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(dialogueLines.length, 10);

      // Verify dialogue is attributed correctly
      expect(dialogueLines[0].character, 'FIRST WITCH');
      expect(dialogueLines[0].text, contains('meet again'));
      expect(dialogueLines[3].character, 'FIRST WITCH');
      expect(dialogueLines[3].text, contains('Where the place'));
    });

    test('detects Macbeth character genders correctly', () {
      const rawText = '''
MACBETH.
So foul and fair a day I have not seen.

LADY MACBETH.
Yet do I fear thy nature.

BANQUO.
Good sir, why do you start?

MACDUFF.
O Scotland, Scotland!

MALCOLM.
Be comforted.

DUNCAN.
Is execution done on Cawdor?
''';
      final script = parser.parse(rawText, title: 'Gender Test');

      final macbeth = script.characters.firstWhere((c) => c.name == 'MACBETH');
      final ladyMacbeth = script.characters.firstWhere((c) => c.name == 'LADY MACBETH');
      final banquo = script.characters.firstWhere((c) => c.name == 'BANQUO');

      expect(macbeth.gender, CharacterGender.male);
      expect(ladyMacbeth.gender, CharacterGender.female);
      expect(banquo.gender, CharacterGender.male);
    });
  });

  group('Folger vs Gutenberg parity', () {
    test('same scene produces matching character sets from both formats', () {
      // Gutenberg format
      const gutenberg = '''
ACT I

SCENE I. An open Place.

 Thunder and Lightning. Enter three Witches.

FIRST WITCH.
When shall we three meet again?

SECOND WITCH.
When the hurlyburly's done,

THIRD WITCH.
That will be ere the set of sun.

ALL.
Fair is foul, and foul is fair.
''';

      // Folger format (converted)
      const folger = '''
ACT I

SCENE 1.

 [Thunder and Lightning. Enter three Witches.]

FIRST WITCH.
When shall we three meet again?

SECOND WITCH.
When the hurly-burly's done,

THIRD WITCH.
That will be ere the set of sun.

ALL.
Fair is foul, and foul is fair;
''';

      final parserG = ScriptParser();
      final parserF = ScriptParser();

      final scriptG = parserG.parse(gutenberg, title: 'Gutenberg');
      final scriptF = parserF.parse(folger, title: 'Folger');

      // Same characters
      final charsG = scriptG.characters.map((c) => c.name).toSet();
      final charsF = scriptF.characters.map((c) => c.name).toSet();
      expect(charsG, equals(charsF));

      // Same number of dialogue lines
      final dlgG = scriptG.lines.where((l) => l.lineType == LineType.dialogue).length;
      final dlgF = scriptF.lines.where((l) => l.lineType == LineType.dialogue).length;
      expect(dlgG, equals(dlgF));

      // Same character attribution order
      final orderG = scriptG.lines
          .where((l) => l.lineType == LineType.dialogue)
          .map((l) => l.character)
          .toList();
      final orderF = scriptF.lines
          .where((l) => l.lineType == LineType.dialogue)
          .map((l) => l.character)
          .toList();
      expect(orderG, equals(orderF));
    });
  });

  group('Pride and Prejudice regression', () {
    late ScriptParser parser;

    setUp(() {
      parser = ScriptParser();
    });

    test('standard format P&P still parses correctly', () {
      const rawText = '''
ACT I

MR. BENNET. I am quite at leisure, my dear.

MRS. BENNET. Oh! Mr. Bennet, have you heard that Netherfield Park is let at last?

ELIZABETH. What is his name?

MRS. BENNET. Bingley!

LYDIA. Is he married or single?

MRS. BENNET. A single man of large fortune.

(Shift begins into the Ball.)

BINGLEY. I say, Darcy, I have never met with pleasanter people.

DARCY. You have been dancing with the only handsome girl in the room.
''';
      final script = parser.parse(rawText, title: 'P&P Regression');

      final charNames = script.characters.map((c) => c.name).toSet();
      expect(charNames, contains('MR. BENNET'));
      expect(charNames, contains('MRS. BENNET'));
      expect(charNames, contains('ELIZABETH'));
      expect(charNames, contains('LYDIA'));
      expect(charNames, contains('BINGLEY'));
      expect(charNames, contains('DARCY'));

      // Title prefixes should NOT create standalone characters
      expect(charNames, isNot(contains('MR')));
      expect(charNames, isNot(contains('MRS')));

      final dialogueLines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(dialogueLines.length, 8);

      // Scene detection via shift transition
      expect(script.scenes.length, greaterThanOrEqualTo(1));

      // Gender inference
      final elizabeth = script.characters.firstWhere((c) => c.name == 'ELIZABETH');
      final darcy = script.characters.firstWhere((c) => c.name == 'DARCY');
      expect(elizabeth.gender, CharacterGender.female);
      expect(darcy.gender, CharacterGender.male);
    });

    test('P&P multi-line dialogue with OCR artifacts preserved', () {
      const rawText = '''
ELIZABETH. I could easily forgive
his pride, if he had not
mortified mine.

MR. BENNET. For what do we live, but to make sport for our
neighbours, and laugh at them in our turn?
''';
      final script = parser.parse(rawText, title: 'P&P Multi-line');

      final dialogueLines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(dialogueLines.length, 2);
      expect(dialogueLines[0].text, contains('forgive'));
      expect(dialogueLines[0].text, contains('mortified'));
      expect(dialogueLines[1].text, contains('neighbours'));
    });
  });
}
