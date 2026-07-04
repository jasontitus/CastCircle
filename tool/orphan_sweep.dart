// ignore_for_file: avoid_print
//
// Sweep ALL productions and report matched vs orphaned recording counts
// (orphaned = recording.line_id not in the production's cloud script_lines).
//
//   dart run tool/orphan_sweep.dart
//
// Uses one throwaway account; joins each production only long enough to read
// (RLS) and deletes its membership rows afterwards.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:supabase/supabase.dart';

const _url = 'https://vngpbmqymdaxxnvqptsk.supabase.co';
const _key = 'sb_publishable_f3YAIMI4GIEIPdDwnvfO3Q_stwSCxXI';

Future<void> main() async {
  final rnd = Random().nextInt(1 << 31);
  final cred = await _auth('orphan_sweep_$rnd@example.com', 'Test-passw0rd!');
  if (cred == null) {
    print('auth failed');
    exit(1);
  }
  final c = SupabaseClient(_url, _key,
      headers: {'Authorization': 'Bearer ${cred.accessToken}'});

  final prods = (await c
          .from('productions')
          .select('id, title, created_at')
          .order('created_at') as List)
      .cast<Map<String, dynamic>>();
  print('${prods.length} productions\n');

  for (final prod in prods) {
    final pid = prod['id'] as String;
    String? memberRowId;
    try {
      final row = await c
          .from('cast_members')
          .insert({
            'production_id': pid,
            'user_id': cred.userId,
            'character_name': '',
            'role': 'understudy',
            'joined_at': DateTime.now().toIso8601String(),
          })
          .select('id')
          .single();
      memberRowId = row['id'] as String?;
    } catch (_) {}

    try {
      final lines = (await c
              .from('script_lines')
              .select('id')
              .eq('production_id', pid) as List)
          .cast<Map<String, dynamic>>();
      final lineIds = lines.map((l) => l['id'] as String).toSet();
      final recs = (await c
              .from('recordings')
              .select('line_id, user_id, audio_url, recorded_at')
              .eq('production_id', pid) as List)
          .cast<Map<String, dynamic>>();
      final orphans =
          recs.where((r) => !lineIds.contains(r['line_id'])).toList();
      print('${prod['title']}  ($pid)');
      print('  lines=${lineIds.length} recordings=${recs.length} '
          'matched=${recs.length - orphans.length} ORPHANED=${orphans.length}');
      if (orphans.isNotEmpty) {
        final byWhen = <String, int>{};
        for (final r in orphans) {
          final when = (r['recorded_at'] as String? ?? '?');
          final day = when.length >= 10 ? when.substring(0, 10) : when;
          final m = RegExp('/$pid/([^/]+)/')
              .firstMatch(Uri.decodeFull(r['audio_url'] as String? ?? ''));
          final key = '$day ${m?.group(1) ?? '?'} '
              'user=${(r['user_id'] as String? ?? '?').substring(0, 8)}';
          byWhen[key] = (byWhen[key] ?? 0) + 1;
        }
        byWhen.forEach((k, v) => print('    $k: $v'));
      }
    } catch (e) {
      print('${prod['title']}  ($pid)  — read failed: $e');
    }

    if (memberRowId != null) {
      try {
        final deleted = await c
            .from('cast_members')
            .delete()
            .eq('id', memberRowId)
            .select('id') as List;
        if (deleted.isEmpty) {
          print('WARNING: audit membership row NOT removed (RLS) — '
              'junk row left on production $pid');
        }
      } catch (e) {
        print('WARNING: audit membership cleanup failed for $pid: $e');
      }
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
