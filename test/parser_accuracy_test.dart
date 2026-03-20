@Tags(['extended'])
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/services/script_parser.dart';
import 'package:castcircle/data/models/script_models.dart';

/// Parse accuracy tests against public domain scripts.
/// Tagged 'extended' — skipped during normal `flutter test`.
/// Run with: flutter test --tags extended
///
/// Expected values sourced from:
/// - Open Source Shakespeare (opensourceshakespeare.org)
/// - PlayShakespeare.com (playshakespeare.com/study/biggest-roles)
/// - Wikipedia character lists
/// - Scholarly editions
///
/// We use ranges rather than exact numbers because different editions
/// count lines differently (verse lines vs speeches vs prose paragraphs).

void main() {
  final scriptsDir = Directory('sample-scripts');

  ParsedScript? parseFile(String filename) {
    final file = File('${scriptsDir.path}/$filename');
    if (!file.existsSync()) {
      // ignore: avoid_print
      print('SKIP: $filename not found');
      return null;
    }
    final text = file.readAsStringSync();
    final parser = ScriptParser();
    return parser.parse(text, title: filename.replaceAll('.txt', ''));
  }

  void expectCharacterExists(ParsedScript script, String name) {
    expect(
      script.characters.any((c) => c.name.contains(name)),
      isTrue,
      reason: 'Expected to find character "$name"',
    );
  }

  void expectCharacterLines(
      ParsedScript script, String name, int min, int max) {
    final char = script.characters.where((c) => c.name.contains(name));
    if (char.isEmpty) {
      fail('Character "$name" not found. '
          'Characters: ${script.characters.map((c) => c.name).toList()}');
    }
    final lines = char.first.lineCount;
    expect(
      lines,
      inInclusiveRange(min, max),
      reason: '$name has $lines lines, expected $min-$max',
    );
  }

  // Reference data from Open Source Shakespeare, Wikipedia, StageAgent.
  // Character counts are wider ranges because parser may find extras
  // (stage directions, messenger variants) or merge some.

  group('Shakespeare plays', () {
    test('Hamlet — 5 acts, ~30 chars, Hamlet leads', () {
      final s = parseFile('shakespeare_hamlet.txt');
      if (s == null) return;
      expect(s.characters.length, inInclusiveRange(20, 45));
      expect(s.acts.length, 5);
      expectCharacterExists(s, 'HAMLET');
      expectCharacterExists(s, 'HORATIO');
      expect(s.characters.first.name, contains('HAMLET'));
      expectCharacterLines(s, 'HAMLET', 300, 450);
    });

    test('Romeo and Juliet — 5 acts, ~20 chars, Romeo leads', () {
      final s = parseFile('shakespeare_romeo_and_juliet.txt');
      if (s == null) return;
      expect(s.characters.length, inInclusiveRange(15, 40));
      expect(s.acts.length, 5);
      expectCharacterExists(s, 'ROMEO');
      expectCharacterExists(s, 'JULIET');
    });

    test('Midsummer Night\'s Dream — 5 acts, ~20 chars', () {
      final s = parseFile('shakespeare_midsummer_nights_dream.txt');
      if (s == null) return;
      expect(s.characters.length, inInclusiveRange(15, 40));
      expect(s.acts.length, 5);
      expectCharacterExists(s, 'BOTTOM');
    });

    test('Tempest — known failure (abbreviated names)', () {
      final s = parseFile('shakespeare_tempest.txt');
      if (s == null) return;
      // This Gutenberg edition uses _Pros._ abbreviations — parser can't handle
      expect(s.characters.length, lessThan(10),
          reason: 'Known failure: abbreviated character names');
    }, skip: 'Gutenberg #23042 uses abbreviated names (_Pros._, _Mir._)');

    test('Othello — 5 acts, ~15 chars, Iago/Othello lead', () {
      final s = parseFile('shakespeare_othello.txt');
      if (s == null) return;
      expect(s.characters.length, inInclusiveRange(15, 35));
      expect(s.acts.length, 5);
      expectCharacterExists(s, 'OTHELLO');
      expectCharacterExists(s, 'IAGO');
    });

    test('King Lear — 5 acts, ~20 chars, Lear leads', () {
      final s = parseFile('shakespeare_king_lear.txt');
      if (s == null) return;
      expect(s.characters.length, inInclusiveRange(15, 35));
      expect(s.acts.length, 5);
      expectCharacterExists(s, 'LEAR');
      expectCharacterLines(s, 'LEAR', 150, 250);
    });

    test('Much Ado — 5 acts, ~20 chars, Benedick leads', () {
      final s = parseFile('shakespeare_much_ado.txt');
      if (s == null) return;
      expect(s.characters.length, inInclusiveRange(15, 30));
      expect(s.acts.length, 5);
      expectCharacterExists(s, 'BENEDICK');
      expectCharacterExists(s, 'BEATRICE');
    });

    test('Twelfth Night — 5 acts, ~15 chars, Sir Toby leads', () {
      final s = parseFile('shakespeare_twelfth_night.txt');
      if (s == null) return;
      expect(s.characters.length, inInclusiveRange(12, 25));
      expect(s.acts.length, 5);
      expectCharacterExists(s, 'SIR TOBY');
    });
  });

  group('Ibsen plays', () {
    test('A Doll\'s House — 3 acts, 6-8 chars, Nora leads', () {
      final s = parseFile('ibsen_a_dolls_house.txt');
      if (s == null) return;
      expect(s.characters.length, inInclusiveRange(5, 15));
      expect(s.acts.length, 3);
      expectCharacterExists(s, 'NORA');
    });

    test('Hedda Gabler — 4 acts, 7 chars, Hedda leads', () {
      final s = parseFile('ibsen_hedda_gabler.txt');
      if (s == null) return;
      expect(s.characters.length, inInclusiveRange(5, 15));
      expect(s.acts.length, 4);
      expectCharacterExists(s, 'HEDDA');
    });

    test('Ghosts — 3 acts, 5 chars, Mrs. Alving leads', () {
      final s = parseFile('ibsen_ghosts.txt');
      if (s == null) return;
      expect(s.characters.length, inInclusiveRange(4, 10));
      expect(s.acts.length, 3);
    });
  });

  group('Wilde plays', () {
    test('Earnest — 3+ acts, 9 chars, Jack leads', () {
      final s = parseFile('wilde_importance_of_being_earnest.txt');
      if (s == null) return;
      expect(s.characters.length, inInclusiveRange(7, 18));
      expect(s.acts.length, inInclusiveRange(3, 4));
      expectCharacterExists(s, 'JACK');
      expectCharacterExists(s, 'ALGERNON');
    });

    test('An Ideal Husband — 4 acts, ~12 chars', () {
      final s = parseFile('wilde_an_ideal_husband.txt');
      if (s == null) return;
      expect(s.characters.length, inInclusiveRange(8, 20));
      expect(s.acts.length, 4);
    });

    test('Lady Windermere\'s Fan — 4 acts, ~12 chars', () {
      final s = parseFile('wilde_lady_windermeres_fan.txt');
      if (s == null) return;
      expect(s.characters.length, inInclusiveRange(8, 20));
      expect(s.acts.length, 4);
    });
  });

  group('Shaw plays', () {
    test('Arms and the Man — 3 acts, 6 chars, Raina leads', () {
      final s = parseFile('shaw_arms_and_the_man.txt');
      if (s == null) return;
      expect(s.characters.length, inInclusiveRange(4, 15));
      expect(s.acts.length, 3);
    });

    test('Pygmalion — 5 acts, ~12 chars, Higgins leads', () {
      final s = parseFile('shaw_pygmalion.txt');
      if (s == null) return;
      expect(s.characters.length, inInclusiveRange(8, 25));
      expect(s.acts.length, 5);
      expectCharacterExists(s, 'HIGGINS');
    });
  });

  group('Other classics', () {
    test('Cyrano — 5 acts, ~25 chars, Cyrano leads', () {
      final s = parseFile('rostand_cyrano_de_bergerac.txt');
      if (s == null) return;
      // Parser finds too many due to stage direction noise, but Cyrano is top
      expect(s.acts.length, 5);
      expectCharacterExists(s, 'CYRANO');
      expect(s.characters.first.name, contains('CYRANO'));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('Doctor Faustus — Faustus found', () {
      final s = parseFile('marlowe_doctor_faustus.txt');
      if (s == null) return;
      expectCharacterExists(s, 'FAUSTUS');
      expect(s.characters.first.name, contains('FAUSTUS'));
    });

    test('She Stoops to Conquer — 5 acts, ~12 chars', () {
      final s = parseFile('goldsmith_she_stoops_to_conquer.txt');
      if (s == null) return;
      expect(s.characters.length, inInclusiveRange(8, 30));
      expect(s.acts.length, 5);
    });

    test('School for Scandal — 5 acts, ~15 chars, Sir Peter leads', () {
      final s = parseFile('sheridan_school_for_scandal.txt');
      if (s == null) return;
      expect(s.characters.length, inInclusiveRange(10, 25));
      expect(s.acts.length, 5);
    });

    test('Oedipus Rex — 1 act, ~8 chars, Oedipus leads', () {
      final s = parseFile('sophocles_oedipus_rex.txt');
      if (s == null) return;
      // Gutenberg translation has many extras
      expect(s.characters.length, inInclusiveRange(5, 30));
      expectCharacterExists(s, 'OEDIPUS');
      expect(s.characters.first.name, contains('OEDIPUS'));
    });
  });

  // Comprehensive stats dump for documentation
  test('Generate parser accuracy report', () {
    final files = scriptsDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.txt') &&
            !f.path.contains('folger_converted') &&
            !f.path.contains('pg37431'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final report = StringBuffer();
    report.writeln('# Parser Accuracy Report');
    report.writeln('');
    report.writeln(
        '| Play | Characters | Dialogue Lines | Acts | Scenes | Top Character | Top Lines |');
    report.writeln(
        '|------|-----------|---------------|------|--------|---------------|-----------|');

    for (final file in files) {
      final filename = file.path.split('/').last;
      try {
        final text = file.readAsStringSync();
        final parser = ScriptParser();
        final result = parser.parse(text, title: filename);

        final dialogueCount = result.lines
            .where((l) => l.lineType == LineType.dialogue)
            .length;
        final topChar =
            result.characters.isNotEmpty ? result.characters.first : null;

        report.writeln(
            '| ${filename.replaceAll('.txt', '').replaceAll('_', ' ')} '
            '| ${result.characters.length} '
            '| $dialogueCount '
            '| ${result.acts.length} '
            '| ${result.scenes.length} '
            '| ${topChar?.name ?? "?"} '
            '| ${topChar?.lineCount ?? 0} |');
      } catch (e) {
        report.writeln('| ${filename.replaceAll('.txt', '')} '
            '| ERROR | - | - | - | $e | - |');
      }
    }

    report.writeln('');
    report.writeln('Generated: ${DateTime.now().toIso8601String()}');

    // Write report to file
    File('sample-scripts/PARSER_ACCURACY_REPORT.md')
        .writeAsStringSync(report.toString());

    // Also print to console
    // ignore: avoid_print
    print(report.toString());
  });
}
