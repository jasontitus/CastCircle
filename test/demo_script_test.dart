import 'dart:io';

import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/script_import_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The demo is the first thing a new user sees, and it ships inside the app —
/// a broken demo asset can't be fixed without a release. These assertions are
/// about the SHAPE a demo needs: short enough to finish, cast-able by one
/// person, and structured so scene selection and cue practice both have
/// something to show.
void main() {
  late ParsedScript script;

  setUpAll(() {
    final file = File('assets/demo/hamlet_demo.txt');
    expect(file.existsSync(), isTrue,
        reason: 'assets/demo/hamlet_demo.txt is missing — regenerate it with '
            'python3 scripts/make-demo-script.py');
    script = ScriptImportService()
        .importFromText(file.readAsStringSync(), title: 'Hamlet (Demo)');
  });

  test('parses into dialogue, characters and scenes', () {
    expect(script.lines, isNotEmpty);
    expect(script.characters, isNotEmpty);
    expect(script.scenes.length, greaterThanOrEqualTo(2),
        reason: 'two scenes is the point — one scene has no scene picker to '
            'demonstrate');
  });

  test('stays small enough to be a demo', () {
    final dialogue =
        script.lines.where((l) => l.lineType == LineType.dialogue).length;
    expect(dialogue, greaterThan(60),
        reason: 'too short to show a rehearsal loop');
    expect(dialogue, lessThan(400),
        reason: 'a demo longer than this is a play, not a demo');
    expect(script.characters.length, lessThanOrEqualTo(14),
        reason: 'the cast screen greets the user with "N characters need '
            'actors" — keep N approachable');
  });

  test('has the parts the walkthrough promises', () {
    final names = script.characters.map((c) => c.name.toUpperCase()).toSet();
    expect(names, contains('HAMLET'));
    // A scene where the user's character trades short lines with someone else
    // is what makes Cue mode legible on first use.
    expect(names, contains('HORATIO'));
  });

  test('every dialogue line has a speaker', () {
    final orphans = script.lines
        .where((l) => l.lineType == LineType.dialogue && l.character.isEmpty)
        .toList();
    expect(orphans, isEmpty,
        reason: '${orphans.length} dialogue lines parsed without a character; '
            'they would be unassignable and unspeakable');
  });
}
