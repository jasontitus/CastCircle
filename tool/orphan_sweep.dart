// ignore_for_file: avoid_print
//
// Report matched vs orphaned recording counts for explicitly named productions.
// Supply each production together with its join code; the tool never bypasses
// the code-validating join flow.
//
//   CASTCIRCLE_AUDIT_EMAIL=... CASTCIRCLE_AUDIT_PASSWORD=... \
//     dart run tool/orphan_sweep.dart <productionId> <joinCode> [...]

import 'dart:io';

import 'package:supabase/supabase.dart';

import 'supabase_tool_auth.dart';

const _url = 'https://vngpbmqymdaxxnvqptsk.supabase.co';
const _key = 'sb_publishable_f3YAIMI4GIEIPdDwnvfO3Q_stwSCxXI';
const _pageSize = 500;

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length.isOdd) {
    stderr.writeln(
      'usage: dart run tool/orphan_sweep.dart '
      '<productionId> <joinCode> [...]',
    );
    exitCode = 2;
    return;
  }

  try {
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
    try {
      for (var index = 0; index < args.length; index += 2) {
        await _analyze(client, args[index], args[index + 1]);
      }
    } finally {
      await client.dispose();
    }
  } catch (error) {
    stderr.writeln('orphan sweep failed: $error');
    exitCode = 1;
  }
}

Future<void> _analyze(
  SupabaseClient client,
  String productionId,
  String joinCode,
) async {
  AuditMembershipLease? lease;
  try {
    lease = await beginAuditMembership(
      client,
      productionId,
      joinCode,
      displayName: 'Orphan sweep',
    );
    await renewAuditMembership(client, lease);

    final production = await client
        .from('productions')
        .select('title')
        .eq('id', productionId)
        .single();
    final lineIds = (await _fetchIds(
      client,
      lease,
      'script_lines',
      productionId,
    )).map((row) => row['id'] as String).toSet();
    final recordings = await _fetchRecordings(client, lease, productionId);
    final orphans = recordings
        .where((recording) => !lineIds.contains(recording['line_id']))
        .toList();

    print('${production['title']}  ($productionId)');
    print(
      '  lines=${lineIds.length} recordings=${recordings.length} '
      'matched=${recordings.length - orphans.length} '
      'ORPHANED=${orphans.length}',
    );
    if (orphans.isNotEmpty) {
      final grouped = <String, int>{};
      final characterPattern = RegExp('/$productionId/([^/]+)/');
      for (final recording in orphans) {
        if (lease.renewalDue) {
          await renewAuditMembership(client, lease);
        }
        final recordedAt = recording['recorded_at'] as String? ?? '?';
        final day = recordedAt.length >= 10
            ? recordedAt.substring(0, 10)
            : recordedAt;
        final match = characterPattern.firstMatch(
          Uri.decodeFull(recording['audio_url'] as String? ?? ''),
        );
        final userId = recording['user_id'] as String? ?? '?';
        final shortUserId = userId.length <= 8
            ? userId
            : userId.substring(0, 8);
        final key = '$day ${match?.group(1) ?? '?'} user=$shortUserId';
        grouped[key] = (grouped[key] ?? 0) + 1;
      }
      grouped.forEach((key, count) => print('    $key: $count'));
    }
  } finally {
    if (lease != null) {
      await endAuditMembership(client, lease);
    }
  }
}

Future<List<Map<String, dynamic>>> _fetchIds(
  SupabaseClient client,
  AuditMembershipLease lease,
  String table,
  String productionId,
) async {
  final rows = <Map<String, dynamic>>[];
  for (var offset = 0; ; offset += _pageSize) {
    await renewAuditMembership(client, lease);
    final page =
        (await client
                    .from(table)
                    .select('id')
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
                    .select('id, line_id, user_id, audio_url, recorded_at')
                    .eq('production_id', productionId)
                    .order('id')
                    .range(offset, offset + _pageSize - 1)
                as List)
            .cast<Map<String, dynamic>>();
    rows.addAll(page);
    if (page.length < _pageSize) return rows;
  }
}
