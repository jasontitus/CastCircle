import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/script_parser.dart';

void main() {
  group('ScriptParser.inferGender', () {
    group('title prefix inference', () {
      test('MR. prefix → male', () {
        expect(ScriptParser.inferGender('MR. BENNET'), CharacterGender.male);
      });

      test('MR prefix without period → male', () {
        expect(ScriptParser.inferGender('MR DARCY'), CharacterGender.male);
      });

      test('MRS. prefix → female', () {
        expect(ScriptParser.inferGender('MRS. BENNET'), CharacterGender.female);
      });

      test('MISS prefix → female', () {
        expect(ScriptParser.inferGender('MISS BINGLEY'), CharacterGender.female);
      });

      test('SIR prefix → male', () {
        expect(ScriptParser.inferGender('SIR WILLIAM'), CharacterGender.male);
      });

      test('LADY prefix → female', () {
        expect(ScriptParser.inferGender('LADY CATHERINE'), CharacterGender.female);
      });

      test('LORD prefix → male', () {
        expect(ScriptParser.inferGender('LORD CAPULET'), CharacterGender.male);
      });

      test('COLONEL prefix → male', () {
        expect(ScriptParser.inferGender('COLONEL FITZWILLIAM'), CharacterGender.male);
      });

      test('MS. prefix → female', () {
        expect(ScriptParser.inferGender('MS. JONES'), CharacterGender.female);
      });

      test('KING prefix → male', () {
        expect(ScriptParser.inferGender('KING LEAR'), CharacterGender.male);
      });

      test('QUEEN prefix → female', () {
        expect(ScriptParser.inferGender('QUEEN GERTRUDE'), CharacterGender.female);
      });

      test('PRINCE prefix → male', () {
        expect(ScriptParser.inferGender('PRINCE HAMLET'), CharacterGender.male);
      });

      test('PRINCESS prefix → female', () {
        expect(ScriptParser.inferGender('PRINCESS AURORA'), CharacterGender.female);
      });

      test('DR. prefix → male', () {
        expect(ScriptParser.inferGender('DR. WATSON'), CharacterGender.male);
      });

      test('FATHER prefix → male', () {
        expect(ScriptParser.inferGender('FATHER LAWRENCE'), CharacterGender.male);
      });

      test('MOTHER prefix → female', () {
        expect(ScriptParser.inferGender('MOTHER SUPERIOR'), CharacterGender.female);
      });

      test('SISTER prefix → female', () {
        expect(ScriptParser.inferGender('SISTER MARY'), CharacterGender.female);
      });

      test('BROTHER prefix → male', () {
        expect(ScriptParser.inferGender('BROTHER JOHN'), CharacterGender.male);
      });
    });

    group('common name inference', () {
      test('JANE → female', () {
        expect(ScriptParser.inferGender('JANE'), CharacterGender.female);
      });

      test('ELIZABETH → female', () {
        expect(ScriptParser.inferGender('ELIZABETH'), CharacterGender.female);
      });

      test('DARCY → male', () {
        expect(ScriptParser.inferGender('DARCY'), CharacterGender.male);
      });

      test('WICKHAM → male', () {
        expect(ScriptParser.inferGender('WICKHAM'), CharacterGender.male);
      });

      test('BINGLEY → male', () {
        expect(ScriptParser.inferGender('BINGLEY'), CharacterGender.male);
      });

      test('COLLINS → male', () {
        expect(ScriptParser.inferGender('COLLINS'), CharacterGender.male);
      });

      test('HAMLET → male', () {
        expect(ScriptParser.inferGender('HAMLET'), CharacterGender.male);
      });

      test('OPHELIA → female', () {
        expect(ScriptParser.inferGender('OPHELIA'), CharacterGender.female);
      });

      test('JULIET → female', () {
        expect(ScriptParser.inferGender('JULIET'), CharacterGender.female);
      });

      test('ROMEO → male', () {
        expect(ScriptParser.inferGender('ROMEO'), CharacterGender.male);
      });

      test('DESDEMONA → female', () {
        expect(ScriptParser.inferGender('DESDEMONA'), CharacterGender.female);
      });

      test('OTHELLO → male', () {
        expect(ScriptParser.inferGender('OTHELLO'), CharacterGender.male);
      });

      test('case insensitive — lowercase name works', () {
        // inferGender uppercases, so 'jane' should match
        expect(ScriptParser.inferGender('jane'), CharacterGender.female);
      });

      test('name with whitespace gets trimmed', () {
        expect(ScriptParser.inferGender('  DARCY  '), CharacterGender.male);
      });
    });

    group('stage direction pronoun inference', () {
      test('he in stage direction → male', () {
        const rawText = 'HASTINGS. (He crosses to the window.) Some dialogue here.';
        expect(ScriptParser.inferGender('HASTINGS', rawText: rawText),
            CharacterGender.male);
      });

      test('she in stage direction → female', () {
        const rawText = 'AGNES. (She turns away.) Some dialogue here.';
        expect(ScriptParser.inferGender('AGNES', rawText: rawText),
            CharacterGender.female);
      });

      test('dialogue pronouns are NOT matched (prevents wrong inference)', () {
        // JANE says "He is wonderful" — this should NOT make JANE male
        const rawText = 'JANE. He is such a wonderful man.';
        // JANE is in common female names, so it resolves before context
        expect(ScriptParser.inferGender('JANE', rawText: rawText),
            CharacterGender.female);
      });

      test('stage direction only matches parenthesized text', () {
        // "He" appears in dialogue, not in (parentheses)
        const rawText = 'NARRATOR. He walks across the stage and delivers the line.';
        // NARRATOR not in common names, no title, no parenthesized pronoun
        // → defaults to female
        expect(ScriptParser.inferGender('NARRATOR', rawText: rawText),
            CharacterGender.female);
      });

      test('majority pronoun wins when both appear', () {
        const rawText = '''
ALEX. (He enters.) Some text.
ALEX. (He picks up the book.) More text.
ALEX. (She — no, he puts it down.) Even more.
''';
        // "He" appears more in stage directions
        expect(ScriptParser.inferGender('ALEX', rawText: rawText),
            CharacterGender.male);
      });
    });

    group('priority chain', () {
      test('title prefix wins over common name', () {
        // MRS is female title, DARCY is male common name → title wins
        expect(ScriptParser.inferGender('MRS. DARCY'), CharacterGender.female);
      });

      test('common name wins over context', () {
        // JANE is a female common name; even with "He" in stage directions
        const rawText = 'JANE. (He crosses...) Hmm.';
        expect(ScriptParser.inferGender('JANE', rawText: rawText),
            CharacterGender.female);
      });

      test('unknown name with no context defaults to female', () {
        expect(ScriptParser.inferGender('XYZPLUGH'), CharacterGender.female);
      });

      test('unknown name with male context → male', () {
        const rawText = 'XYZPLUGH. (He sneezes.) Achoo!';
        expect(ScriptParser.inferGender('XYZPLUGH', rawText: rawText),
            CharacterGender.male);
      });
    });
  });
}
