// ignore_for_file: avoid_print
//
// Verify a deterministic sample of cloud recordings for an existing production.
//
//   CASTCIRCLE_AUDIT_EMAIL=... CASTCIRCLE_AUDIT_PASSWORD=... \
//     dart run tool/verify_cloud_recordings.dart <productionId> <joinCode>
//
// Uses a dedicated audit account and a unique, code-validating membership
// lease that is always released.

import 'dart:io';

import 'package:supabase/supabase.dart';

import 'supabase_tool_auth.dart';

const _url = 'https://vngpbmqymdaxxnvqptsk.supabase.co';
const _key = 'sb_publishable_f3YAIMI4GIEIPdDwnvfO3Q_stwSCxXI';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
      'usage: dart run tool/verify_cloud_recordings.dart '
      '<productionId> <joinCode>',
    );
    exitCode = 2;
    return;
  }

  try {
    await _run(args[0], args[1]);
  } catch (error) {
    stderr.writeln('verification failed: $error');
    exitCode = 1;
  }
}

Future<void> _run(String productionId, String joinCode) async {
  final credentials = await authenticateToolUser(
    _url,
    _key,
    requireToolEnvironment('CASTCIRCLE_AUDIT_EMAIL'),
    requireToolEnvironment('CASTCIRCLE_AUDIT_PASSWORD'),
  );
  print('[1] authenticated dedicated audit user ${credentials.userId}');

  final client = SupabaseClient(
    _url,
    _key,
    headers: {'Authorization': 'Bearer ${credentials.accessToken}'},
  );
  AuditMembershipLease? lease;
  final outputDirectory = await Directory.systemTemp.createTemp(
    'castcircle_verify_',
  );

  try {
    print('[2] acquire code-validating audit membership lease');
    lease = await beginAuditMembership(
      client,
      productionId,
      joinCode,
      displayName: 'Recording audit',
    );

    await renewAuditMembership(client, lease);
    print('[3] read the three newest recording rows');
    final rows = await client
        .from('recordings')
        .select('id, line_id, user_id, audio_url, duration_ms, recorded_at')
        .eq('production_id', productionId)
        .order('recorded_at', ascending: false)
        .order('id')
        .limit(3);
    final recordings = (rows as List).cast<Map<String, dynamic>>();
    print('   deterministic sample size: ${recordings.length}');
    if (recordings.isEmpty) {
      throw StateError('no recording rows are visible for this production');
    }

    print('[4] download sampled objects and check size');
    var failures = 0;
    for (var index = 0; index < recordings.length; index++) {
      await renewAuditMembership(client, lease);
      final recording = recordings[index];
      final audioUrl = recording['audio_url'] as String? ?? '';
      final objectPath = _objectPathFromUrl(audioUrl);
      if (objectPath == null) {
        stderr.writeln('   could not parse object path from: $audioUrl');
        failures++;
        continue;
      }
      try {
        final bytes = await client.storage
            .from('recordings')
            .download(objectPath);
        final output = File('${outputDirectory.path}/recording_$index.m4a');
        await output.writeAsBytes(bytes);
        print(
          '   ${objectPath.split('/').last}: '
          '${(bytes.length / 1024).toStringAsFixed(0)}KB '
          'dur=${recording['duration_ms']}ms',
        );
      } catch (error) {
        stderr.writeln('   download failed for $objectPath: $error');
        failures++;
      }
    }
    if (failures != 0) {
      throw StateError('$failures sampled recording(s) failed verification');
    }
    print('done.');
  } finally {
    if (lease != null) {
      try {
        await endAuditMembership(client, lease);
        print('(released audit membership lease ${lease.id})');
      } catch (error) {
        stderr.writeln('could not release audit membership lease: $error');
        exitCode = 1;
      }
    }
    await client.dispose();
    await outputDirectory.delete(recursive: true);
  }
}

String? _objectPathFromUrl(String url) {
  const marker = '/recordings/';
  final index = url.indexOf(marker);
  if (index < 0) return null;
  var path = url.substring(index + marker.length);
  final queryIndex = path.indexOf('?');
  if (queryIndex >= 0) path = path.substring(0, queryIndex);
  return Uri.decodeFull(path);
}
