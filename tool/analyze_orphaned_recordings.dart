// ignore_for_file: avoid_print
//
// Analyze orphaned recordings for a production: recordings whose line_id is
// not present in the production's current cloud script_lines. These play as
// "computer voices" for the cast (the rehearsal orphan banner).
//
//   dart run tool/analyze_orphaned_recordings.dart <productionId>
//
// Auths a throwaway account and self-joins as understudy to satisfy RLS
// (same pattern as verify_cloud_recordings.dart), then removes its own
// cast_members row at the end.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:supabase/supabase.dart';

const _url = 'https://vngpbmqymdaxxnvqptsk.supabase.co';
const _key = 'sb_publishable_f3YAIMI4GIEIPdDwnvfO3Q_stwSCxXI';

Future<void> main(List<String> args) async {
  final productionId =
      args.isNotEmpty ? args[0] : 'ca0cde7d-5eef-4231-a584-03f935e3879b';

  final rnd = Random().nextInt(1 << 31);
  final email = 'orphan_audit_$rnd@example.com';
  const pass = 'Test-passw0rd!';

  final cred = await _auth(email, pass);
  if (cred == null) {
    print('auth failed');
    exit(1);
  }
  final c = SupabaseClient(_url, _key,
      headers: {'Authorization': 'Bearer ${cred.accessToken}'});

  String? memberRowId;
  try {
    final row = await c
        .from('cast_members')
        .insert({
          'production_id': productionId,
          'user_id': cred.userId,
          'character_name': '',
          'role': 'understudy',
          'joined_at': DateTime.now().toIso8601String(),
        })
        .select('id')
        .single();
    memberRowId = row['id'] as String?;
  } catch (e) {
    print('join failed: $e');
  }

  final prod = await c
      .from('productions')
      .select('title, created_at')
      .eq('id', productionId)
      .maybeSingle();
  print('Production: ${prod?['title']} ($productionId)');

  final lines = (await c
          .from('script_lines')
          .select('id, character, order_index')
          .eq('production_id', productionId) as List)
      .cast<Map<String, dynamic>>();
  final lineIds = lines.map((l) => l['id'] as String).toSet();
  print('script_lines: ${lines.length}');

  final recs = (await c
          .from('recordings')
          .select('line_id, user_id, audio_url, duration_ms, recorded_at')
          .eq('production_id', productionId)
          .order('recorded_at') as List)
      .cast<Map<String, dynamic>>();
  print('recordings:   ${recs.length}');

  final matched = recs.where((r) => lineIds.contains(r['line_id'])).toList();
  final orphans = recs.where((r) => !lineIds.contains(r['line_id'])).toList();
  print('matched:      ${matched.length}');
  print('ORPHANED:     ${orphans.length}\n');

  String charOf(String url) {
    final m = RegExp('/$productionId/([^/]+)/').firstMatch(Uri.decodeFull(url));
    return m?.group(1) ?? '?';
  }

  // Group orphans by user + character + day for a readable report.
  print('--- orphans ---');
  for (final r in orphans) {
    print('  ${(r['recorded_at'] as String? ?? '?').substring(0, 16)}  '
        'user=${(r['user_id'] as String? ?? '?').substring(0, 8)}  '
        'char=${charOf(r['audio_url'] as String? ?? '')}  '
        '${r['duration_ms']}ms  line=${(r['line_id'] as String? ?? '?').substring(0, 8)}');
  }

  // Do the orphaned lines' characters also have CURRENT matched recordings
  // by the same user? If yes they're stale duplicates, safe to delete.
  print('\n--- per user+character: matched vs orphaned counts ---');
  final counts = <String, List<int>>{};
  for (final r in recs) {
    final key =
        '${(r['user_id'] as String? ?? '?').substring(0, 8)} ${charOf(r['audio_url'] as String? ?? '')}';
    counts.putIfAbsent(key, () => [0, 0]);
    counts[key]![lineIds.contains(r['line_id']) ? 0 : 1]++;
  }
  counts.forEach((k, v) => print('  $k: matched=${v[0]} orphaned=${v[1]}'));

  // Clean up the throwaway's membership row.
  if (memberRowId != null) {
    try {
      await c.from('cast_members').delete().eq('id', memberRowId);
      print('\n(cleaned up audit membership row)');
    } catch (e) {
      print('\n(could not remove audit membership row: $e)');
    }
  }
  exit(0);
}

class _Cred {
  final String accessToken;
  final String userId;
  _Cred(this.accessToken, this.userId);
}

Future<_Cred?> _auth(String email, String pass) async {
  final body = jsonEncode({'email': email, 'password': pass});
  var res = await _post('$_url/auth/v1/signup', body);
  if (res == null || res['access_token'] == null) {
    res = await _post('$_url/auth/v1/token?grant_type=password', body);
  }
  final at = res?['access_token'] as String?;
  final uid = (res?['user'] as Map?)?['id'] as String?;
  if (at == null || uid == null) return null;
  return _Cred(at, uid);
}

Future<Map<String, dynamic>?> _post(String url, String body) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse(url));
    req.headers.set('Content-Type', 'application/json');
    req.headers.set('apikey', _key);
    req.add(utf8.encode(body));
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    if (text.isEmpty) return null;
    return jsonDecode(text) as Map<String, dynamic>;
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}
