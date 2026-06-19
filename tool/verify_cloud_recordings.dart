// ignore_for_file: avoid_print
//
// Verify the cloud recordings for an EXISTING production are real audio and
// downloadable on macOS. Auths a throwaway account, joins the production by
// code, reads the recordings table, downloads each object, and reports size.
//
//   dart run tool/verify_cloud_recordings.dart <productionId> <joinCode>

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:supabase/supabase.dart';

const _url = 'https://vngpbmqymdaxxnvqptsk.supabase.co';
const _key = 'sb_publishable_f3YAIMI4GIEIPdDwnvfO3Q_stwSCxXI';

Future<void> main(List<String> args) async {
  final productionId = args.isNotEmpty ? args[0] : 'ca0cde7d-5eef-4231-a584-03f935e3879b';
  final joinCode = args.length > 1 ? args[1] : 'D5E6SK';

  final rnd = Random().nextInt(1 << 31);
  final email = 'verify_$rnd@example.com';
  const pass = 'Test-passw0rd!';

  print('[1] signup throwaway $email');
  final cred = await _auth(email, pass);
  if (cred == null) {
    print('   signup/login did not return a session (email confirmation on?). '
        'Cannot read RLS-protected recordings without a confirmed account.');
    exit(1);
  }
  print('   userId=${cred.userId}');

  final c = SupabaseClient(_url, _key,
      headers: {'Authorization': 'Bearer ${cred.accessToken}'});

  print('[2] join production $productionId (code $joinCode) via self cast_members insert');
  try {
    await c.from('cast_members').insert({
      'production_id': productionId,
      'user_id': cred.userId,
      'character_name': '',
      'role': 'understudy',
      'joined_at': DateTime.now().toIso8601String(),
    });
    print('   joined');
  } catch (e) {
    print('   join insert failed (may already be member / RLS): $e');
  }

  print('[3] read recordings for production');
  final rows = await c
      .from('recordings')
      .select('line_id, user_id, audio_url, duration_ms')
      .eq('production_id', productionId);
  final list = (rows as List).cast<Map<String, dynamic>>();
  print('   recordings rows visible: ${list.length}');
  if (list.isEmpty) {
    print('   RLS returned 0 rows — either not a member or no read policy.');
    exit(1);
  }

  print('[4] download up to 3 objects and check size');
  Directory('/tmp/cc_verify').createSync(recursive: true);
  var i = 0;
  for (final r in list.take(3)) {
    final audioUrl = r['audio_url'] as String? ?? '';
    final objectPath = _objectPathFromUrl(audioUrl);
    if (objectPath == null) {
      print('   ! could not parse object path from: $audioUrl');
      continue;
    }
    try {
      final bytes = await c.storage.from('recordings').download(objectPath);
      final out = '/tmp/cc_verify/rec_${i++}.m4a';
      File(out).writeAsBytesSync(bytes);
      print('   ✓ ${objectPath.split('/').last}: ${(bytes.length / 1024).toStringAsFixed(0)}KB '
          'dur=${r['duration_ms']}ms → $out');
    } catch (e) {
      print('   ✗ download FAILED for $objectPath: $e');
    }
  }
  print('done.');
  exit(0);
}

String? _objectPathFromUrl(String url) {
  const marker = '/recordings/';
  final idx = url.indexOf(marker);
  if (idx < 0) return null;
  var path = url.substring(idx + marker.length);
  final q = path.indexOf('?');
  if (q >= 0) path = path.substring(0, q);
  return Uri.decodeFull(path);
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
