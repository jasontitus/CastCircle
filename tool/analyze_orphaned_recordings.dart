// ignore_for_file: avoid_print
//
// Analyze orphaned recordings for a production: recordings whose line_id is
// not present in the production's current cloud script_lines.
//
//   CASTCIRCLE_AUDIT_EMAIL=... CASTCIRCLE_AUDIT_PASSWORD=... \
//     dart run tool/analyze_orphaned_recordings.dart <productionId> <joinCode>
//
// Uses a dedicated audit account and a unique, code-validating membership
// lease that is released even if analysis fails.

import 'dart:io';

import 'package:supabase/supabase.dart';

import 'supabase_tool_auth.dart';

const _url = 'https://vngpbmqymdaxxnvqptsk.supabase.co';
const _key = 'sb_publishable_f3YAIMI4GIEIPdDwnvfO3Q_stwSCxXI';
const _pageSize = 500;

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
      'usage: dart run tool/analyze_orphaned_recordings.dart '
      '<productionId> <joinCode>',
    );
    exitCode = 2;
    return;
  }

  try {
    await _run(args[0], args[1]);
  } catch (error) {
    stderr.writeln('orphan analysis failed: $error');
    exitCode = 1;
  }
}

Future<void> _run(String productionId, String joinCode) async {
  print('Target production: $productionId');
  final credentials = await authenticateToolUser(
    _url,
    _key,
    requireToolEnvironment('CASTCIRCLE_AUDIT_EMAIL'),
    requireToolEnvironment('CASTCIRCLE_AUDIT_PASSWORD'),
  );
  final client = SupabaseClient(
    _url,
    _key,
    headers: {'Authorization': 'Bearer ${credentials.accessToken}'},
  );

  AuditMembershipLease? lease;
  try {
    lease = await beginAuditMembership(
      client,
      productionId,
      joinCode,
      displayName: 'Orphan audit',
    );

    final production = await client
        .from('productions')
        .select('title, created_at')
        .eq('id', productionId)
        .maybeSingle();
    print('Production: ${production?['title']} ($productionId)');

    final lines = await _fetchScriptLines(client, lease, productionId);
    final lineIds = lines.map((line) => line['id'] as String).toSet();
    print('script_lines: ${lines.length}');

    final recordings = await _fetchRecordings(client, lease, productionId);
    print('recordings:   ${recordings.length}');

    final matched = recordings.where(
      (recording) => lineIds.contains(recording['line_id']),
    );
    final orphans = recordings
        .where((recording) => !lineIds.contains(recording['line_id']))
        .toList();
    print('matched:      ${matched.length}');
    print('ORPHANED:     ${orphans.length}\n');

    final characterPattern = RegExp('/$productionId/([^/]+)/');
    String characterOf(String url) {
      final match = characterPattern.firstMatch(Uri.decodeFull(url));
      return match?.group(1) ?? '?';
    }

    print('--- orphans ---');
    for (final recording in orphans) {
      if (lease.renewalDue) {
        await renewAuditMembership(client, lease);
      }
      print(
        '  ${(recording['recorded_at'] as String? ?? '?').substring(0, 16)}  '
        'user=${(recording['user_id'] as String? ?? '?').substring(0, 8)}  '
        'char=${characterOf(recording['audio_url'] as String? ?? '')}  '
        '${recording['duration_ms']}ms  '
        'line=${(recording['line_id'] as String? ?? '?').substring(0, 8)}',
      );
    }

    print('\n--- per user+character: matched vs orphaned counts ---');
    final counts = <String, List<int>>{};
    for (final recording in recordings) {
      if (lease.renewalDue) {
        await renewAuditMembership(client, lease);
      }
      final key =
          '${(recording['user_id'] as String? ?? '?').substring(0, 8)} '
          '${characterOf(recording['audio_url'] as String? ?? '')}';
      counts.putIfAbsent(key, () => [0, 0]);
      counts[key]![lineIds.contains(recording['line_id']) ? 0 : 1]++;
    }
    counts.forEach(
      (key, values) =>
          print('  $key: matched=${values[0]} orphaned=${values[1]}'),
    );
  } finally {
    if (lease != null) {
      try {
        await endAuditMembership(client, lease);
        print('\n(released audit membership lease ${lease.id})');
      } catch (error) {
        stderr.writeln('could not release audit membership lease: $error');
        exitCode = 1;
      }
    }
    await client.dispose();
  }
}

Future<List<Map<String, dynamic>>> _fetchScriptLines(
  SupabaseClient client,
  AuditMembershipLease lease,
  String productionId,
) async {
  final rows = <Map<String, dynamic>>[];
  for (var offset = 0; ; offset += _pageSize) {
    await renewAuditMembership(client, lease);
    final page =
        (await client
                    .from('script_lines')
                    .select('id, character, order_index')
                    .eq('production_id', productionId)
                    .order('id')
                    .range(offset, offset + _pageSize - 1)
                as List)
            .cast<Map<String, dynamic>>();
    rows.addAll(page);
    if (page.length < _pageSize) return rows;
  }
}

Future<List<Map<String, dynamic>>> _fetchRecordings(
  SupabaseClient client,
  AuditMembershipLease lease,
  String productionId,
) async {
  final rows = <Map<String, dynamic>>[];
  for (var offset = 0; ; offset += _pageSize) {
    await renewAuditMembership(client, lease);
    final page =
        (await client
                    .from('recordings')
                    .select(
                      'id, line_id, user_id, audio_url, duration_ms, recorded_at',
                    )
                    .eq('production_id', productionId)
                    .order('id')
                    .range(offset, offset + _pageSize - 1)
                as List)
            .cast<Map<String, dynamic>>();
    rows.addAll(page);
    if (page.length < _pageSize) return rows;
  }
}
