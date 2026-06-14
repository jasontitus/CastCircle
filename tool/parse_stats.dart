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
    stderr.writeln('usage: dart run tool/parse_stats.dart <textfile> [--json] '
        '[--expect NAME1,NAME2,...]');
    exit(2);
  }

  final text = File(positional.first).readAsStringSync();
  final parsed = ScriptParser().parse(text, title: 'Test');

  final dialogue =
      parsed.lines.where((l) => l.lineType == LineType.dialogue).length;
  final roster = [...parsed.characters]
    ..sort((a, b) => b.lineCount.compareTo(a.lineCount));

  final expected = expectArg
      .split(',')
      .map((s) => s.trim().toUpperCase())
      .where((s) => s.isNotEmpty)
      .toSet();

  // Roster scoring vs the answer key (if provided). A parsed name "matches" an
  // expected name if either contains the other (handles "MRS. BENNET" vs
  // "BENNET" and minor truncations), so we measure real coverage, not exact
  // string equality.
  bool matches(String got, String exp) =>
      got == exp || got.contains(exp) || exp.contains(got);
  final matchedExpected = <String>{};
  final phantoms = <String>[];
  for (final c in roster) {
    final n = c.name.toUpperCase();
    final hit = expected.where((e) => matches(n, e)).toList();
    if (hit.isEmpty && expected.isNotEmpty) {
      phantoms.add('${c.name} (${c.lineCount})');
    } else {
      matchedExpected.addAll(hit);
    }
  }
  final missing = expected.difference(matchedExpected);

  if (asJson) {
    print(const JsonEncoder.withIndent('  ').convert({
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
    }));
    return;
  }

  print('characters:    ${parsed.characters.length}'
      '${expected.isNotEmpty ? '   (expected ~${expected.length})' : ''}');
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
