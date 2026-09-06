// Runs the real app ScriptParser on a raw-text file and prints the structural
// stats the import preview shows (character roster + line counts, acts, scenes).
//
// This is the Mac-side scoring harness for OCR/auto-tuner tuning: feed it the
// OCR output of a scanned script and compare the parsed roster/line-counts to
// the play's known structure (the "answer key"). A scanned script that OCRs
// cleanly collapses to the right number of characters; OCR garble inflates it
// with phantom names (e.g. ELIZABETH + EUZABETH + ELlZABETH).
//
// Usage:
//   dart run tool/parse_stats.dart <textfile> [--json]
//   dart run tool/parse_stats.dart <textfile> --expect ELIZABETH,DARCY,JANE,...
//
// With --expect, also reports roster precision/recall vs the expected names and
// flags likely OCR-phantom characters (names not in the expected set).

import 'dart:convert';
import 'dart:io';

import 'package:castcircle/data/models/script_models.dart';
import 'package:castcircle/data/services/script_parser.dart';

void main(List<String> args) {
  final positional = <String>[];
  var asJson = false;
  var expectArg = '';
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--json') {
      asJson = true;
    } else if (a == '--expect' && i + 1 < args.length) {
      expectArg = args[++i];
    } else {
      positional.add(a);
    }
  }
  if (positional.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/parse_stats.dart <textfile> [--json] '
      '[--expect NAME1,NAME2,...]',
    );
    exit(2);
  }

  final text = File(positional.first).readAsStringSync();
  final parsed = ScriptParser().parse(text, title: 'Test');

  final dialogue = parsed.lines
      .where((l) => l.lineType == LineType.dialogue)
      .length;
  final roster = [...parsed.characters]
    ..sort((a, b) => b.lineCount.compareTo(a.lineCount));

  final expected = expectArg
      .split(',')
      .map((s) => s.trim().toUpperCase())
      .where((s) => s.isNotEmpty)
      .toSet();

  // Score exact normalized names first, then find a maximum one-to-one
  // matching across complete-token aliases such as "BENNET" vs "MRS. BENNET".
  // This prevents both one-to-many inflation and greedy undercounting.
  String normalizeName(String name) => name
      .toUpperCase()
      .replaceAll(RegExp(r'[^A-Z0-9]+'), ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');
  bool exactMatch(String got, String exp) {
    final normalizedGot = normalizeName(got);
    return normalizedGot.isNotEmpty && normalizedGot == normalizeName(exp);
  }

  bool tokenBoundaryMatch(String got, String exp) {
    final normalizedGot = normalizeName(got);
    final normalizedExpected = normalizeName(exp);
    if (normalizedGot.isEmpty ||
        normalizedExpected.isEmpty ||
        normalizedGot == normalizedExpected) {
      return false;
    }
    return ' $normalizedGot '.contains(' $normalizedExpected ') ||
        ' $normalizedExpected '.contains(' $normalizedGot ');
  }

  final matchedExpected = <String>{};
  final matchedRosterIndexes = <int>{};
  for (var index = 0; index < roster.length; index++) {
    for (final candidate in expected) {
      if (matchedExpected.contains(candidate)) continue;
      if (!exactMatch(roster[index].name, candidate)) continue;
      matchedRosterIndexes.add(index);
      matchedExpected.add(candidate);
      break;
    }
  }

  // Kuhn's augmenting-path algorithm finds a maximum bipartite matching over
  // the remaining alias edges, rather than depending on greedy iteration order.
  final aliasRosterByExpected = <String, int>{};
  bool augmentAlias(int rosterIndex, Set<String> visitedExpected) {
    for (final candidate in expected) {
      if (matchedExpected.contains(candidate) ||
          !visitedExpected.add(candidate) ||
          !tokenBoundaryMatch(roster[rosterIndex].name, candidate)) {
        continue;
      }
      final displacedRoster = aliasRosterByExpected[candidate];
      if (displacedRoster == null ||
          augmentAlias(displacedRoster, visitedExpected)) {
        aliasRosterByExpected[candidate] = rosterIndex;
        return true;
      }
    }
    return false;
  }

  for (var index = 0; index < roster.length; index++) {
    if (!matchedRosterIndexes.contains(index)) {
      augmentAlias(index, <String>{});
    }
  }
  matchedExpected.addAll(aliasRosterByExpected.keys);
  matchedRosterIndexes.addAll(aliasRosterByExpected.values);
  final phantoms = <String>[
    if (expected.isNotEmpty)
      for (var index = 0; index < roster.length; index++)
        if (!matchedRosterIndexes.contains(index))
          '${roster[index].name} (${roster[index].lineCount})',
  ];
  final missing = expected.difference(matchedExpected);

  if (asJson) {
    print(
      const JsonEncoder.withIndent('  ').convert({
        'characters': parsed.characters.length,
        'acts': parsed.acts.length,
        'scenes': parsed.scenes.length,
        'dialogueLines': dialogue,
        'totalLines': parsed.lines.length,
        'roster': {for (final c in roster) c.name: c.lineCount},
        if (expected.isNotEmpty) ...{
          'expectedCount': expected.length,
          'matchedExpected': matchedExpected.length,
          'missing': missing.toList(),
          'phantoms': phantoms,
        },
      }),
    );
    return;
  }

  print(
    'characters:    ${parsed.characters.length}'
    '${expected.isNotEmpty ? '   (expected ~${expected.length})' : ''}',
  );
  print('acts:          ${parsed.acts.length}   ${parsed.acts}');
  print('scenes:        ${parsed.scenes.length}');
  print('dialogue lines:${dialogue}   total lines: ${parsed.lines.length}');
  print('--- roster (name: lineCount) ---');
  for (final c in roster) {
    print('  ${c.name}: ${c.lineCount}');
  }
  if (expected.isNotEmpty) {
    print('--- vs answer key (${expected.length} expected) ---');
    print('matched expected: ${matchedExpected.length}/${expected.length}');
    if (missing.isNotEmpty) print('MISSING: ${missing.join(', ')}');
    if (phantoms.isNotEmpty) {
      print('PHANTOM (likely OCR garble): ${phantoms.length}');
      for (final p in phantoms) {
        print('  $p');
      }
    }
  }
}
