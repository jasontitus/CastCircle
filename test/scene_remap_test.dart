import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/models/script_models.dart';

/// Regression tests for the field bug: after an OCR review pass removed
/// not-script lines, the SCRIPT read correctly everywhere but REHEARSAL
/// played dialogue from the wrong part of the play — scene ranges are
/// positional indices into `lines` and were carried over unchanged.
void main() {
  ScriptLine line(String id, String text,
          {LineType type = LineType.dialogue, String character = 'A'}) =>
      ScriptLine(
        id: id,
        act: 'ACT I',
        scene: '',
        lineNumber: 0,
        orderIndex: 0,
        character: type == LineType.dialogue ? character : '',
        text: text,
        lineType: type,
      );

  ScriptScene scene(String id, String name, int start, int end) => ScriptScene(
        id: id,
        act: 'ACT I',
        sceneName: name,
        location: '',
        description: '',
        startLineIndex: start,
        endLineIndex: end,
        characters: const ['A'],
      );

  group('ParsedScript.remapScenes', () {
    final oldLines = [
      line('l0', 'scene one first'),
      line('l1', 'JUNK OCR ARTIFACT', type: LineType.stageDirection),
      line('l2', 'scene one last'),
      line('l3', 'scene two first'),
      line('l4', 'scene two last'),
    ];
    final scenes = [scene('s1', 'Scene 1', 0, 2), scene('s2', 'Scene 2', 3, 4)];

    test('removing a line shifts later scenes to their real lines', () {
      final newLines = [oldLines[0], oldLines[2], oldLines[3], oldLines[4]];
      final remapped = ParsedScript.remapScenes(scenes, oldLines, newLines);
      final script = ParsedScript(
          title: 't',
          lines: newLines,
          characters: const [],
          scenes: remapped,
          rawText: '');

      expect(script.linesInScene(remapped[0]).map((l) => l.id),
          ['l0', 'l2'],
          reason: 'scene 1 keeps its surviving lines');
      // The whole point: without remapping this returned ['l2','l3'] — the
      // rehearsal would open "Scene 2" and play scene one's last line.
      expect(script.linesInScene(remapped[1]).map((l) => l.id), ['l3', 'l4']);
    });

    test('scene metadata and identity survive the remap', () {
      final newLines = [oldLines[0], oldLines[2], oldLines[3], oldLines[4]];
      final remapped = ParsedScript.remapScenes(scenes, oldLines, newLines);
      expect(remapped.map((s) => s.id), ['s1', 's2']);
      expect(remapped[1].sceneName, 'Scene 2');
    });

    test('a fully-removed scene is dropped, later scenes still correct', () {
      // Everything in scene 1 goes away.
      final newLines = [oldLines[3], oldLines[4]];
      final remapped = ParsedScript.remapScenes(scenes, oldLines, newLines);
      expect(remapped.length, 1);
      expect(remapped.single.id, 's2');
      final script = ParsedScript(
          title: 't',
          lines: newLines,
          characters: const [],
          scenes: remapped,
          rawText: '');
      expect(script.linesInScene(remapped.single).map((l) => l.id),
          ['l3', 'l4']);
    });

    test('insertion pushes later scenes forward', () {
      final inserted = line('lx', 'added line');
      final newLines = [
        oldLines[0],
        oldLines[1],
        inserted,
        oldLines[2],
        oldLines[3],
        oldLines[4],
      ];
      final remapped = ParsedScript.remapScenes(scenes, oldLines, newLines);
      final script = ParsedScript(
          title: 't',
          lines: newLines,
          characters: const [],
          scenes: remapped,
          rawText: '');
      expect(script.linesInScene(remapped[1]).map((l) => l.id), ['l3', 'l4']);
    });

    test('no-op when the lines list is unchanged', () {
      final remapped = ParsedScript.remapScenes(scenes, oldLines, oldLines);
      expect(remapped[0].startLineIndex, 0);
      expect(remapped[0].endLineIndex, 2);
      expect(remapped[1].startLineIndex, 3);
      expect(remapped[1].endLineIndex, 4);
    });

    test('deleting a character keeps later scenes on their own lines', () {
      // Mirrors character_manager_screen._applyDelete: drop every line of one
      // character, then remap. Field-class bug — the script still reads
      // correctly, but rehearsal opens a scene on someone else's dialogue.
      final all = [
        line('a0', 'scene one, keeper', character: 'KEEP'),
        line('a1', 'scene one, doomed', character: 'CUT'),
        line('a2', 'scene one, keeper 2', character: 'KEEP'),
        line('a3', 'scene two first', character: 'KEEP'),
        line('a4', 'scene two, doomed', character: 'CUT'),
        line('a5', 'scene two last', character: 'KEEP'),
      ];
      final scenes = [scene('s1', 'Scene 1', 0, 2), scene('s2', 'Scene 2', 3, 5)];
      final kept = all.where((l) => l.character != 'CUT').toList();

      final remapped = ParsedScript.remapScenes(scenes, all, kept);
      final script = ParsedScript(
          title: 't',
          lines: kept,
          characters: const [],
          scenes: remapped,
          rawText: '');

      expect(script.linesInScene(remapped[0]).map((l) => l.id), ['a0', 'a2']);
      // Without the remap this returned ['a2'] + nothing / the wrong window.
      expect(script.linesInScene(remapped[1]).map((l) => l.id), ['a3', 'a5']);
      expect(remapped[1].startLineIndex, 2);
      expect(remapped[1].endLineIndex, 3);
    });
  });
}
