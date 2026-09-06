import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/script_parser.dart';

void main() {
  group('Gutenberg wrapper stripping', () {
    test('strips preamble and postamble', () {
      const text = '''
The Project Gutenberg eBook of Hamlet

Title: Hamlet
Author: William Shakespeare

*** START OF THE PROJECT GUTENBERG EBOOK HAMLET ***

ELIZABETH. Actual script content.

*** END OF THE PROJECT GUTENBERG EBOOK HAMLET ***

Some licensing text here.
''';
      final parser = ScriptParser();
      final script = parser.parse(text, title: 'Gutenberg Test');
      final lines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(lines.length, 1);
      expect(lines.first.character, 'ELIZABETH');
    });

    test('works fine when no Gutenberg markers present', () {
      const text = '''
ELIZABETH. First line.
DARCY. Second line.
''';
      final parser = ScriptParser();
      final script = parser.parse(text, title: 'No Gutenberg');
      expect(
        script.lines.where((l) => l.lineType == LineType.dialogue).length,
        2,
      );
    });
  });

  group('Format detection', () {
    test('detects standard format (name + dialogue on same line)', () {
      const text = '''
ELIZABETH. First line of dialogue.
DARCY. Second line of dialogue.
ELIZABETH. Third line of dialogue.
DARCY. Fourth line of dialogue.
ELIZABETH. Fifth line of dialogue.
DARCY. Sixth line of dialogue.
''';
      final parser = ScriptParser();
      final script = parser.parse(text, title: 'Standard');
      // Standard format should still work as before
      expect(
        script.lines.where((l) => l.lineType == LineType.dialogue).length,
        6,
      );
    });

    test('detects name-on-own-line format (Macbeth style)', () {
      const text = '''
MACBETH.
So foul and fair a day I have not seen.

BANQUO.
How far is it call'd to Forres?

MACBETH.
Speak, if you can; what are you?

FIRST WITCH.
All hail, Macbeth!

SECOND WITCH.
Hail to thee, Thane of Cawdor!

THIRD WITCH.
All hail, Macbeth, that shalt be king hereafter!
''';
      final parser = ScriptParser();
      final script = parser.parse(text, title: 'Macbeth Style');
      final lines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(lines.length, 6);
      expect(lines[0].character, 'MACBETH');
      expect(lines[0].text, contains('foul and fair'));
      expect(lines[1].character, 'BANQUO');
      expect(lines[3].character, 'FIRST WITCH');
    });

    test('detects title-case format (First Folio style)', () {
      const text = '''
Enter Barnardo and Francisco.

  Barnardo. Who's there?
  Fran. Nay answer me: Stand and unfold yourself.

  Bar. Long live the King.

  Fran. Barnardo?
  Bar. He.

  Fran. You come most carefully upon your hour.

  Bar. 'Tis now struck twelve, get thee to bed Francisco.
''';
      final parser = ScriptParser();
      final script = parser.parse(text, title: 'First Folio');
      final lines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      // Should detect characters and lines
      expect(lines.length, greaterThanOrEqualTo(5));
      // Bar/Barn should be merged via prefix matching
      final chars = script.characters.map((c) => c.name).toSet();
      // Should have BARNARDO (or BARN) as a character (resolved from Bar/Barn)
      expect(
        chars.any((c) => c.startsWith('BAR')),
        isTrue,
        reason: 'Should detect Barnardo variants as a character',
      );
      expect(
        chars.any((c) => c.startsWith('FRAN')),
        isTrue,
        reason: 'Should detect Francisco variants as a character',
      );
    });
  });

  group('Macbeth parsing (name-on-own-line format)', () {
    late ScriptParser parser;

    setUp(() {
      parser = ScriptParser();
    });

    test('parses character names on their own line', () {
      const text = '''
ACT I

SCENE I. An open Place.

FIRST WITCH.
When shall we three meet again?
In thunder, lightning, or in rain?

SECOND WITCH.
When the hurlyburly's done,
When the battle's lost and won.

THIRD WITCH.
That will be ere the set of sun.
''';
      final script = parser.parse(text, title: 'Macbeth Scene 1');
      final lines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(lines.length, 3);
      expect(lines[0].character, 'FIRST WITCH');
      expect(lines[0].text, contains('meet again'));
      expect(lines[0].text, contains('rain'));
      expect(lines[1].character, 'SECOND WITCH');
      expect(lines[2].character, 'THIRD WITCH');
    });

    test('handles multi-line dialogue in name-on-own-line format', () {
      const text = '''
MACBETH.
Tomorrow, and tomorrow, and tomorrow,
Creeps in this petty pace from day to day,
To the last syllable of recorded time.

LADY MACBETH.
Out, damned spot! Out, I say!
''';
      final script = parser.parse(text, title: 'Macbeth Multiline');
      final lines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(lines.length, 2);
      expect(lines[0].character, 'MACBETH');
      expect(lines[0].text, contains('Tomorrow'));
      expect(lines[0].text, contains('recorded time'));
      expect(lines[1].character, 'LADY MACBETH');
    });

    test('detects Enter/Exit as stage directions', () {
      const text = '''
DUNCAN.
What bloody man is that?

 Enter Ross and Angus.

MALCOLM.
The worthy Thane of Ross.
''';
      final script = parser.parse(text, title: 'Macbeth Directions');
      final directions = script.lines
          .where((l) => l.lineType == LineType.stageDirection)
          .toList();
      expect(directions.length, greaterThanOrEqualTo(1));
      expect(
        directions.any(
          (d) => d.text.contains('Ross') || d.text.contains('Enter'),
        ),
        isTrue,
      );
      // Dialogue should not include the stage direction text
      final dialogue = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      for (final line in dialogue) {
        expect(line.text, isNot(contains('Enter Ross')));
      }
    });

    test('detects bracketed stage directions [_Exeunt._]', () {
      const text = '''
MACBETH.
Lead me to the chamber.

[_Exeunt._]

ROSS.
Is it known who did this?
''';
      final script = parser.parse(text, title: 'Macbeth Brackets');
      final directions = script.lines
          .where((l) => l.lineType == LineType.stageDirection)
          .toList();
      expect(directions, isNotEmpty);
    });

    test('Alarum\'d in dialogue is NOT treated as stage direction', () {
      const text = '''
MACBETH.
And wither'd murder,
Alarum'd by his sentinel, the wolf,
Whose howl's his watch, thus with his stealthy pace,
Moves like a ghost.

LADY MACBETH.
That which hath made them drunk hath made me bold.
''';
      final script = parser.parse(text, title: 'Macbeth Alarmd');
      final dialogue = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      final macbethLines = dialogue
          .where((l) => l.character == 'MACBETH')
          .toList();
      expect(macbethLines.length, 1);
      // "Alarum'd" should be part of dialogue, not split out
      expect(macbethLines[0].text, contains("Alarum'd"));
      expect(macbethLines[0].text, contains('ghost'));
    });

    test('dialogue continues after stage direction (Is this a dagger)', () {
      const text = '''
MACBETH.
Go bid thy mistress, when my drink is ready,
She strike upon the bell. Get thee to bed.

[_Exit Servant._]

Is this a dagger which I see before me,
The handle toward my hand? Come, let me clutch thee.

[_A bell rings._]

I go, and it is done. The bell invites me.

LADY MACBETH.
That which hath made them drunk hath made me bold.
''';
      final script = parser.parse(text, title: 'Macbeth Dagger');
      final dialogue = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();

      // MACBETH should have 3 speeches (split by stage directions)
      // 1. "Go bid thy mistress..."
      // 2. "Is this a dagger..."
      // 3. "I go, and it is done..."
      final macbethLines = dialogue
          .where((l) => l.character == 'MACBETH')
          .toList();
      expect(
        macbethLines.length,
        3,
        reason: 'Macbeth speaks 3 times, split by stage directions',
      );

      expect(macbethLines[0].text, contains('Go bid thy mistress'));
      expect(macbethLines[1].text, contains('dagger'));
      expect(macbethLines[2].text, contains('bell invites me'));

      // LADY MACBETH gets her own line
      final ladyLines = dialogue
          .where((l) => l.character == 'LADY MACBETH')
          .toList();
      expect(ladyLines.length, 1);
    });

    test('dialogue continues after Enter in Hamlet (Horatio sees Ghost)', () {
      const text = '''
  Hor. In what particular thought to work, I know not:
But in the grosse and scope of my Opinion,
This boades some strange erruption to our State.

Enter Ghost againe.

But soft, behold: Loe, where it comes againe.

  Mar. Shall I strike at it with my Partizan?
''';
      final script = parser.parse(text, title: 'Hamlet Ghost');
      final dialogue = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();

      // HOR(ATIO) should have 2 speeches (split by stage direction)
      final horLines = dialogue
          .where((l) => l.character.startsWith('HOR'))
          .toList();
      expect(
        horLines.length,
        2,
        reason: 'Horatio speaks before and after the Ghost enters',
      );
      expect(horLines[0].text, contains('particular thought'));
      expect(horLines[1].text, contains('behold'));
    });

    test('detects ACT and SCENE headers', () {
      const text = '''
ACT I

SCENE I. An open Place.

FIRST WITCH.
When shall we three meet again?

SCENE II. A Camp near Forres.

DUNCAN.
What bloody man is that?

ACT II

SCENE I. Court within the Castle.

MACBETH.
Is this a dagger which I see before me?
''';
      final script = parser.parse(text, title: 'Macbeth Acts');
      final headers = script.lines
          .where((l) => l.lineType == LineType.header)
          .toList();
      expect(headers.length, 2);
      expect(headers[0].text, contains('ACT I'));
      expect(headers[1].text, contains('ACT II'));
    });

    test('Tomorrow and tomorrow speech attributed to MACBETH', () {
      const text = '''
SEYTON.
The Queen, my lord, is dead.

MACBETH.
She should have died hereafter.
There would have been a time for such a word.
Tomorrow, and tomorrow, and tomorrow,
Creeps in this petty pace from day to day,
To the last syllable of recorded time;
And all our yesterdays have lighted fools
The way to dusty death. Out, out, brief candle!
Life's but a walking shadow; a poor player,
That struts and frets his hour upon the stage,
And then is heard no more: it is a tale
Told by an idiot, full of sound and fury,
Signifying nothing.

 Enter a Messenger.

Thou com'st to use thy tongue; thy story quickly.

MESSENGER.
Gracious my lord,
I should report that which I say I saw.
''';
      final script = parser.parse(text, title: 'Macbeth Tomorrow');
      final dialogue = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      final macbethLines = dialogue
          .where((l) => l.character == 'MACBETH')
          .toList();

      // MACBETH has 2 speeches: the soliloquy, then addressing the Messenger
      expect(macbethLines.length, 2);
      expect(macbethLines[0].text, contains('Tomorrow'));
      expect(macbethLines[0].text, contains('Signifying nothing'));
      expect(macbethLines[1].text, contains('thy tongue'));

      // SEYTON and MESSENGER each have 1 line
      expect(dialogue.where((l) => l.character == 'SEYTON').length, 1);
      expect(dialogue.where((l) => l.character == 'MESSENGER').length, 1);
    });

    test('Out damned spot scene with correct character attributions', () {
      const text = '''
LADY MACBETH.
Yet here's a spot.

DOCTOR.
Hark, she speaks. I will set down what comes from her.

LADY MACBETH.
Out, damned spot! out, I say! One; two. Why, then 'tis time to do't.
Hell is murky! Fie, my lord, fie! a soldier, and afeard?

DOCTOR.
Do you mark that?

GENTLEWOMAN.
She has spoke what she should not.
''';
      final script = parser.parse(text, title: 'Macbeth Spot');
      final dialogue = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(dialogue.length, 5);

      final ladyLines = dialogue
          .where((l) => l.character == 'LADY MACBETH')
          .toList();
      expect(ladyLines.length, 2);
      expect(ladyLines[1].text, contains('Out, damned spot'));

      expect(dialogue.where((l) => l.character == 'DOCTOR').length, 2);
      expect(dialogue.where((l) => l.character == 'GENTLEWOMAN').length, 1);
    });

    test('finds all major Macbeth characters', () {
      const text = '''
ACT I

SCENE I. An open Place.

FIRST WITCH.
When shall we three meet again?

SECOND WITCH.
When the hurlyburly's done.

THIRD WITCH.
That will be ere the set of sun.

ALL.
Fair is foul, and foul is fair.

SCENE II. A Camp near Forres.

DUNCAN.
What bloody man is that?

MALCOLM.
This is the sergeant.

SCENE III. A heath.

MACBETH.
So foul and fair a day I have not seen.

BANQUO.
How far is it to Forres?

ROSS.
God save the King!

LENNOX.
What a haste looks through his eyes!

SCENE V. A Room in the Castle.

LADY MACBETH.
They met me in the day of success.

SCENE IV. A Room in the Palace.

MACDUFF.
Is the King stirring?
''';
      final script = parser.parse(text, title: 'Macbeth Full Cast');
      final charNames = script.characters.map((c) => c.name).toSet();
      expect(charNames, contains('MACBETH'));
      expect(charNames, contains('LADY MACBETH'));
      expect(charNames, contains('BANQUO'));
      expect(charNames, contains('DUNCAN'));
      expect(charNames, contains('MALCOLM'));
      expect(charNames, contains('MACDUFF'));
      expect(charNames, contains('ROSS'));
      expect(charNames, contains('FIRST WITCH'));
    });
  });

  group('Hamlet parsing (title-case format)', () {
    late ScriptParser parser;

    setUp(() {
      parser = ScriptParser();
    });

    test('To be or not to be soliloquy (First Folio format)', () {
      const text = '''
  Pol. I heare him comming, let's withdraw my Lord.

Exeunt.

Enter Hamlet.

  Ham. To be, or not to be, that is the Question:
Whether 'tis Nobler in the minde to suffer
The Slings and Arrowes of outragious Fortune,
Or to take Armes against a Sea of troubles,
And by opposing end them: to dye, to sleepe
No more; and by a sleepe, to say we end
The Heart-ake, and the thousand Naturall shockes
That Flesh is heyre too? 'Tis a consummation
Deuoutly to be wish'd. To dye to sleepe,
To sleepe, perchance to Dreame; I, there's the rub,
For in that sleepe of death, what dreames may come,
When we haue shuffel'd off this mortall coile,
Must giue vs pawse.
Thus Conscience does make Cowards of vs all,
And thus the Natiue hew of Resolution
Is sicklied o're, with the pale cast of Thought,
And enterprizes of great pith and moment,
With this regard their Currants turne away,
And loose the name of Action. Soft you now,
The faire Ophelia? Nimph, in thy Orizons
Be all my sinnes remembred

  Ophe. Good my Lord,
How does your Honor for this many a day?
''';
      final script = parser.parse(text, title: 'Hamlet Soliloquy');
      final dialogue = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();

      // POL(ONIUS), HAM(LET), OPHE(LIA) should all have dialogue
      expect(dialogue.length, greaterThanOrEqualTo(3));

      // The "To be" speech should be a single long dialogue line for HAM(LET)
      final hamLines = dialogue
          .where((l) => l.character.startsWith('HAM'))
          .toList();
      expect(hamLines, isNotEmpty);
      expect(hamLines.first.text, contains('To be, or not to be'));
      expect(
        hamLines.first.text,
        contains('loose the name of Action'),
        reason: 'Full soliloquy should be captured as one speech',
      );

      // Ophelia's response should be captured
      final opheLines = dialogue
          .where((l) => l.character.startsWith('OPHE'))
          .toList();
      expect(opheLines, isNotEmpty);
      expect(opheLines.first.text, contains('Good my Lord'));

      // Stage directions (Exeunt, Enter Hamlet) should be detected
      final directions = script.lines
          .where((l) => l.lineType == LineType.stageDirection)
          .toList();
      expect(directions.length, greaterThanOrEqualTo(1));
    });

    test('parses title-case character names with dialogue on same line', () {
      const text = '''
  Ham. To be, or not to be, that is the question.

  Hor. My lord, I came to see your father's funeral.

  Ham. I pray thee, do not mock me.

  Hor. Indeed, my lord, it followed hard upon.

  Ham. Thrift, thrift, Horatio!
''';
      final script = parser.parse(text, title: 'Hamlet Dialogue');
      final lines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(lines.length, 5);
      // HAM should be detected (and possibly resolved to HAMLET via aliases)
      final hamletChar = lines[0].character;
      expect(hamletChar, startsWith('HAM'));
    });

    test('resolves abbreviated names via Enter stage directions', () {
      const text = '''
Enter Hamlet and Horatio.

  Ham. The air bites shrewdly.

  Hor. It is a nipping and an eager air.

  Ham. What hour now?

  Hor. I think it lacks of twelve.

  Mar. No, it is struck.

Enter Marcellus.

  Mar. Holla Barnardo!

  Ham. The time is out of joint.
''';
      final script = parser.parse(text, title: 'Hamlet Names');
      final charNames = script.characters.map((c) => c.name).toSet();
      // HAM should resolve to HAMLET via "Enter Hamlet and Horatio"
      expect(charNames, contains('HAMLET'));
      // HOR should resolve to HORATIO
      expect(charNames, contains('HORATIO'));
      // MAR should resolve to MARCELLUS
      expect(charNames, contains('MARCELLUS'));
    });

    test('handles Latin act/scene headers', () {
      const text = '''
Actus Primus. Scoena Prima.

Enter Barnardo and Francisco.

  Barnardo. Who's there?
  Fran. Nay answer me.

Scena Secunda.

Enter King and Queen.

  King. Though yet of Hamlet our dear brother's death.

  Queen. Good Hamlet, cast thy nightly colour off.
''';
      final script = parser.parse(text, title: 'Hamlet Acts');
      final headers = script.lines
          .where((l) => l.lineType == LineType.header)
          .toList();
      expect(headers.length, greaterThanOrEqualTo(1));
      // Should detect characters across scenes
      final charNames = script.characters.map((c) => c.name).toSet();
      expect(charNames, isNotEmpty);
      expect(charNames.any((c) => c.startsWith('KING')), isTrue);
    });

    test('merges prefix abbreviations (Bar → Barn → Barnardo)', () {
      const text = '''
Enter Barnardo and Francisco.

  Barnardo. Who's there?

  Bar. Long live the King.

  Barn. Have you had quiet guard?

  Bar. 'Tis now struck twelve.

  Barn. In the same figure, like the king that's dead.
''';
      final script = parser.parse(text, title: 'Hamlet Abbreviations');
      final charNames = script.characters.map((c) => c.name).toSet();
      // All variants (BAR, BARN, BARNARDO) should merge to BARNARDO
      expect(charNames, contains('BARNARDO'));
      expect(charNames, isNot(contains('BAR')));
      expect(charNames, isNot(contains('BARN')));
    });

    test('handles Enter/Exit as stage directions in First Folio', () {
      const text = '''
  Hor. Friends to this ground.

Enter the Ghost.

  Hor. Stay! Speak! I charge thee speak.

Exit the Ghost.

  Mar. 'Tis gone, and will not answer.
''';
      final script = parser.parse(text, title: 'Hamlet Directions');
      final directions = script.lines
          .where((l) => l.lineType == LineType.stageDirection)
          .toList();
      expect(directions.length, greaterThanOrEqualTo(2));
      // Dialogue should not contain Enter/Exit text
      final dialogue = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(dialogue.length, greaterThanOrEqualTo(2));
      for (final line in dialogue) {
        expect(line.text, isNot(startsWith('Enter')));
        expect(line.text, isNot(startsWith('Exit')));
      }
    });
  });

  group('Full Shakespeare file parsing', () {
    test('Macbeth text file produces characters and dialogue', () {
      final file = File('sample-scripts/macbeth-pg1533-images-3.txt');
      if (!file.existsSync()) {
        markTestSkipped('fixture missing: ${file.path}');
        return;
      }
      final rawText = file.readAsStringSync();
      final parser = ScriptParser();
      final script = parser.parse(rawText, title: 'Macbeth');

      final charNames = script.characters.map((c) => c.name).toSet();
      final dialogue = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();

      // Must have characters
      expect(
        script.characters.length,
        greaterThan(10),
        reason: 'Macbeth has 20+ speaking characters',
      );

      // Must have substantial dialogue
      expect(
        dialogue.length,
        greaterThan(200),
        reason: 'Macbeth has 600+ speeches',
      );

      // Key characters must be present
      expect(charNames, contains('MACBETH'));
      expect(charNames, contains('LADY MACBETH'));
      expect(charNames, contains('BANQUO'));
      expect(charNames, contains('DUNCAN'));
      expect(charNames, contains('MACDUFF'));
      expect(charNames, contains('MALCOLM'));
      expect(charNames, contains('ROSS'));
      expect(charNames, contains('LENNOX'));

      // MACBETH should have the most lines
      final macbeth = script.characters.firstWhere((c) => c.name == 'MACBETH');
      expect(macbeth.lineCount, greaterThan(50));
      expect(
        script.characters.first.name,
        'MACBETH',
        reason: 'MACBETH should be the character with the most lines',
      );

      // Should have multiple acts
      final headers = script.lines
          .where((l) => l.lineType == LineType.header)
          .toList();
      expect(
        headers.length,
        greaterThanOrEqualTo(4),
        reason: 'Macbeth has 5 acts',
      );
    });

    test('Hamlet text file produces characters and dialogue', () {
      final file = File('sample-scripts/hamlet-pg1524-images-3.txt');
      if (!file.existsSync()) {
        markTestSkipped('fixture missing: ${file.path}');
        return;
      }
      final rawText = file.readAsStringSync();
      final parser = ScriptParser();
      final script = parser.parse(rawText, title: 'Hamlet');

      final charNames = script.characters.map((c) => c.name).toSet();
      final dialogue = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();

      // Must have characters
      expect(
        script.characters.length,
        greaterThan(5),
        reason: 'Hamlet has many speaking characters',
      );

      // Must have substantial dialogue
      expect(
        dialogue.length,
        greaterThan(200),
        reason: 'Hamlet has 1000+ speeches',
      );

      // Key characters should be present (resolved from abbreviations)
      // Ham → HAMLET (via Enter stage directions)
      expect(
        charNames,
        contains('HAMLET'),
        reason: 'Ham. should resolve to HAMLET via Enter directions',
      );

      // Hor → HORATIO
      expect(
        charNames,
        contains('HORATIO'),
        reason: 'Hor. should resolve to HORATIO',
      );

      // HAMLET should have the most lines
      final hamlet = script.characters.firstWhere((c) => c.name == 'HAMLET');
      expect(hamlet.lineCount, greaterThan(50));
    });
  });

  group('Standard format not broken', () {
    test('Pride & Prejudice style still works perfectly', () {
      const text = '''
ACT I

ELIZABETH. I could easily forgive his pride, if he had not mortified mine.

DARCY. I have been meditating on the very great pleasure which a pair of fine eyes can bestow.

(She exits.)

ELIZABETH. A man who has once been refused! How could I be so blind?

MR. BENNET. I have the pleasure of understanding your character.

MRS. BENNET. Oh my nerves!

BINGLEY. Your sister is the most beautiful creature.

ELIZABETH. I do not want people to be agreeable.

DARCY. My good opinion once lost is lost forever.
''';
      final parser = ScriptParser();
      final script = parser.parse(text, title: 'P&P Test');

      final charNames = script.characters.map((c) => c.name).toSet();
      expect(charNames, contains('ELIZABETH'));
      expect(charNames, contains('DARCY'));
      expect(charNames, contains('MR. BENNET'));
      expect(charNames, contains('MRS. BENNET'));
      expect(charNames, contains('BINGLEY'));

      final dialogue = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(dialogue.length, 8);

      // Stage direction should be detected
      final directions = script.lines
          .where((l) => l.lineType == LineType.stageDirection)
          .toList();
      expect(directions.length, 1);

      // Characters sorted by line count
      expect(script.characters[0].name, 'ELIZABETH');
      expect(script.characters[0].lineCount, 3);
    });

    test('multi-line dialogue continuation still works', () {
      const text = '''
ELIZABETH. I could easily forgive
his pride, if he had not
mortified mine.

DARCY. Indeed.
''';
      final parser = ScriptParser();
      final script = parser.parse(text, title: 'Continuation Test');
      final lines = script.lines
          .where((l) => l.lineType == LineType.dialogue)
          .toList();
      expect(lines.length, 2);
      expect(lines[0].text, contains('forgive'));
      expect(lines[0].text, contains('mortified'));
      expect(lines[0].character, 'ELIZABETH');
    });

    test('inline stage directions still work', () {
      const text = '''
ELIZABETH. (sarcastically:) How delightful.
''';
      final parser = ScriptParser();
      final script = parser.parse(text, title: 'Inline Direction');
      final line = script.lines.firstWhere(
        (l) => l.lineType == LineType.dialogue,
      );
      expect(line.stageDirection, 'sarcastically');
      expect(line.text, 'How delightful.');
    });

    test('shift scene transitions still work', () {
      const text = '''
ACT I

ELIZABETH. We are at Longbourn.

(Shift begins into Netherfield.)

DARCY. Welcome to Netherfield.
''';
      final parser = ScriptParser();
      final script = parser.parse(text, title: 'Shift Test');
      expect(script.scenes.length, greaterThanOrEqualTo(1));
    });
  });
}
