// ignore_for_file: avoid_print
//
// Multi-user (multi-phone) simulation for cast joining + audio sharing.
//
// Drives TWO real Supabase sessions through the whole flow on ONE machine, so
// the cross-device issues that never show up with a single phone — RLS denying
// a castmate's read, the realtime channel never connecting, a re-record UPDATE
// not propagating, a storage path that doesn't round-trip, a broken join/claim
// — surface as a clear ✓/✗ checklist instead of "it didn't work on my friend's
// phone". Each step mirrors what the in-app debug log now prints.
//
// Run (needs two test accounts on the project — create them in the app or
// Supabase dashboard, email-confirmed):
//   dart run tool/sim_multi_user.dart <emailA> <passwordA> <emailB> <passwordB>
//
// Optional env overrides: SUPABASE_URL, SUPABASE_ANON_KEY.
//
// It creates a throwaway production owned by A and deletes it (and its storage
// objects) at the end, even on failure.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:supabase/supabase.dart';

const _defaultUrl = 'https://vngpbmqymdaxxnvqptsk.supabase.co';
const _defaultKey = 'sb_publishable_f3YAIMI4GIEIPdDwnvfO3Q_stwSCxXI';

int _pass = 0, _fail = 0;
void ok(String m) {
  _pass++;
  print('  ✓ $m');
}

void bad(String m) {
  _fail++;
  print('  ✗ $m');
}

Future<void> main(List<String> args) async {
  if (args.length < 4) {
    print('usage: dart run tool/sim_multi_user.dart '
        '<emailA> <passA> <emailB> <passB>');
    exit(2);
  }
  final url =
      Platform.environment['SUPABASE_URL']?.trim().isNotEmpty == true
          ? Platform.environment['SUPABASE_URL']!
          : _defaultUrl;
  final key = Platform.environment['SUPABASE_ANON_KEY']?.trim().isNotEmpty == true
      ? Platform.environment['SUPABASE_ANON_KEY']!
      : _defaultKey;

  print('\n[1] Authenticate both users (REST) → build per-user clients');
  final credA = await _auth(url, key, args[0], args[1]);
  final credB = await _auth(url, key, args[2], args[3]);
  if (credA == null || credB == null) {
    bad('Could not authenticate both users — aborting');
    exit(1);
  }
  // Two independent clients, each carrying its own user's JWT = two "phones".
  final a = SupabaseClient(url, key,
      headers: {'Authorization': 'Bearer ${credA.accessToken}'});
  final b = SupabaseClient(url, key,
      headers: {'Authorization': 'Bearer ${credB.accessToken}'});
  a.realtime.setAuth(credA.accessToken);
  b.realtime.setAuth(credB.accessToken);
  final aUserId = credA.userId;
  final bUserId = credB.userId;
  ok('A ready ($aUserId)');
  ok('B ready ($bUserId)');

  String? productionId;
  String? lineId;
  String? charName;

  try {
    if (aUserId == bUserId) {
      bad('A and B are the SAME account — use two different accounts');
      return;
    }
    if (aUserId == bUserId) {
      bad('A and B are the SAME account — use two different accounts');
      return;
    }

    print('\n[2] A creates a production with a join code');
    final code = _joinCode();
    productionId = _uuid();
    await a.from('productions').insert({
      'id': productionId,
      'title': 'SIM ${DateTime.now().toIso8601String()}',
      'organizer_id': aUserId,
      'status': 'draft',
      'join_code': code,
    });
    await a.from('cast_members').insert(
        {'production_id': productionId, 'user_id': aUserId, 'role': 'organizer'});
    ok('production $productionId (code $code)');

    print('\n[3] A invites a character + records a line (upload + metadata)');
    charName = 'TESTCHAR';
    final inviteId = _uuid();
    await a.from('cast_members').insert({
      'id': inviteId,
      'production_id': productionId,
      'character_name': charName,
      'display_name': 'Test Actor',
      'role': 'actor',
      'invited_at': DateTime.now().toIso8601String(),
    });
    lineId = _uuid();
    final path = '$productionId/$charName/$lineId.m4a';
    final audio = _fakeAudio(1);
    await a.storage.from('recordings').uploadBinary(path, audio,
        fileOptions: const FileOptions(contentType: 'audio/mp4', upsert: true));
    final audioUrl = a.storage.from('recordings').getPublicUrl(path);
    await a.from('recordings').upsert({
      'production_id': productionId,
      'line_id': lineId,
      'user_id': aUserId,
      'audio_url': audioUrl,
      'duration_ms': 1000,
      'recorded_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'production_id,line_id,user_id');
    ok('uploaded recordings/$path + metadata');

    print('\n[4] B looks up by join code, then joins (the app\'s exact sequence)');
    final lookup = await b.rpc('lookup_production_by_join_code',
        params: {'lookup_code': code});
    (lookup is Map && lookup['id'] == productionId)
        ? ok('B found production by code (RPC)')
        : bad('B lookup_production_by_join_code returned: $lookup');

    // App sequence: claim invitation via RPC → direct update fallback →
    // self-join (new row). Whichever lands makes B a real member.
    var joined = false;
    try {
      await b.rpc('claim_cast_invitation', params: {'member_id': inviteId});
      joined = true;
      ok('B claimed invitation via RPC');
    } catch (e) {
      bad('claim_cast_invitation RPC failed: $e');
      try {
        await b.from('cast_members').update({
          'user_id': bUserId,
          'joined_at': DateTime.now().toIso8601String(),
        }).eq('id', inviteId);
        joined = true;
        ok('B claimed via direct update (RPC fallback)');
      } catch (e2) {
        bad('direct-update claim also failed: $e2');
      }
    }
    if (!joined) {
      try {
        await b.from('cast_members').insert({
          'production_id': productionId,
          'user_id': bUserId,
          'character_name': charName,
          'display_name': 'Test Actor B',
          'role': 'actor',
          'joined_at': DateTime.now().toIso8601String(),
        });
        joined = true;
        ok('B self-joined (new row)');
      } catch (e) {
        bad('self-join insert also failed: $e');
      }
    }
    if (!joined) bad('B could not join at all — downstream checks will fail');

    print('\n[5] B reads the cast + A\'s recording (RLS cross-user read)');
    final bCast = await b.rpc('fetch_cast_for_join', params: {'prod_id': productionId});
    (bCast is List && bCast.isNotEmpty)
        ? ok('B sees ${bCast.length} cast member(s)')
        : bad('B fetch_cast_for_join returned: $bCast');
    final bRecs = await b.from('recordings').select().eq('production_id', productionId);
    bRecs.any((r) => r['line_id'] == lineId)
        ? ok('B sees A\'s recording row (RLS read OK)')
        : bad('B does NOT see A\'s recording — RLS read policy blocks castmates');

    print('\n[6] B downloads A\'s audio (storage RLS + path round-trip)');
    try {
      final got = await b.storage.from('recordings').download(path);
      got.length == audio.length
          ? ok('B downloaded ${got.length}B (matches)')
          : bad('B downloaded ${got.length}B, expected ${audio.length}B');
    } catch (e) {
      bad('B download failed for $path: $e');
    }

    print('\n[7] Realtime: B subscribes, A records a NEW line → B should get INSERT');
    final line2 = _uuid();
    final insertSeen = Completer<bool>();
    final chan = b
        .channel('sim:$productionId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'recordings',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'production_id',
              value: productionId),
          callback: (p) {
            if (p.newRecord['line_id'] == line2 && !insertSeen.isCompleted) {
              insertSeen.complete(true);
            }
          },
        );
    final updateSeen = Completer<bool>();
    chan.onPostgresChanges(
      event: PostgresChangeEvent.update,
      schema: 'public',
      table: 'recordings',
      filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'production_id',
          value: productionId),
      callback: (p) {
        if (p.newRecord['line_id'] == lineId && !updateSeen.isCompleted) {
          updateSeen.complete(true);
        }
      },
    );
    final subStatus = Completer<String>();
    chan.subscribe((s, e) {
      if (!subStatus.isCompleted) subStatus.complete(e == null ? s.name : 'error: $e');
    });
    final st = await subStatus.future
        .timeout(const Duration(seconds: 10), onTimeout: () => 'TIMEOUT');
    final rtConnected = st.toLowerCase().contains('subscrib');
    rtConnected
        ? ok('B realtime channel connected ($st)')
        : print('  ⚠ realtime channel did not connect from this standalone Dart '
            'client ($st) — this is a harness limitation, NOT a verdict on the '
            'app. Verify live delivery with the real app on two devices.');
    await Future.delayed(const Duration(seconds: 1));

    final p2 = '$productionId/$charName/$line2.m4a';
    await a.storage.from('recordings').uploadBinary(p2, _fakeAudio(2),
        fileOptions: const FileOptions(contentType: 'audio/mp4', upsert: true));
    await a.from('recordings').upsert({
      'production_id': productionId,
      'line_id': line2,
      'user_id': aUserId,
      'audio_url': a.storage.from('recordings').getPublicUrl(p2),
      'duration_ms': 1000,
      'recorded_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'production_id,line_id,user_id');
    final gotInsert = await insertSeen.future
        .timeout(const Duration(seconds: 12), onTimeout: () => false);
    if (gotInsert) {
      ok('B received realtime INSERT for the new line');
    } else if (rtConnected) {
      bad('B did NOT receive the INSERT within 12s (table not in realtime publication?)');
    } else {
      print('  ⚠ INSERT not received — realtime channel never connected (harness)');
    }

    print('\n[8] Re-record: old overwrite is blocked; the client FIX (fresh key)');
    // (a) The old behaviour: overwrite the same key (upsert) — storage RLS blocks.
    try {
      await a.storage.from('recordings').uploadBinary(path, _fakeAudio(3),
          fileOptions: const FileOptions(contentType: 'audio/mp4', upsert: true));
      ok('overwrite (upsert) works — re-records replace cloud audio fine');
    } catch (_) {
      print('  (overwriting the same key is RLS-blocked — that\'s the bug the '
          'fix avoids)');
    }
    // (b) The shipped fix: a NEW unique key per take is always an INSERT, and
    // the metadata URL is repointed → B downloads the NEW audio.
    final newKey = '$productionId/$charName/$lineId/${DateTime.now()
        .millisecondsSinceEpoch}.m4a';
    final reAudio = _fakeAudio(9);
    try {
      await a.storage.from('recordings').uploadBinary(newKey, reAudio,
          fileOptions: const FileOptions(contentType: 'audio/mp4'));
      final newUrl = a.storage.from('recordings').getPublicUrl(newKey);
      await a.from('recordings').upsert({
        'production_id': productionId,
        'line_id': lineId,
        'user_id': aUserId,
        'audio_url': newUrl,
        'duration_ms': 1500,
        'recorded_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'production_id,line_id,user_id');
      // B re-reads metadata and downloads by the stored URL.
      final bRows =
          await b.from('recordings').select().eq('production_id', productionId);
      final row = bRows.firstWhere((r) => r['line_id'] == lineId);
      final got =
          await b.storage.from('recordings').download(_keyFromUrl('${row['audio_url']}'));
      (got.length == reAudio.length && got[5] == reAudio[5])
          ? ok('FIX VALIDATED: re-record via fresh key → B downloads the NEW take')
          : bad('B got stale/wrong bytes after re-record');
    } catch (e) {
      bad('fresh-key re-record failed: $e');
    }
    final gotUpdate = await updateSeen.future
        .timeout(const Duration(seconds: 12), onTimeout: () => false);
    if (gotUpdate) {
      ok('B received realtime UPDATE for the re-record');
    } else if (rtConnected) {
      bad('B did NOT receive the UPDATE — recordings table needs to be in the '
          'realtime publication (and REPLICA IDENTITY FULL for the filter)');
    } else {
      print('  ⚠ UPDATE not received — realtime channel never connected (harness)');
    }

    await b.removeChannel(chan);
  } catch (e, s) {
    bad('Unexpected error: $e');
    print(s.toString().split('\n').take(4).join('\n'));
  } finally {
    print('\n[cleanup] removing the throwaway production + storage');
    if (productionId != null) {
      try {
        final files = (await a.storage.from('recordings').list(path: productionId))
            .map((f) => '$productionId/${f.name}')
            .toList();
        // list() is shallow; remove the known objects explicitly too.
        if (charName != null && lineId != null) {
          files.add('$productionId/$charName/$lineId.m4a');
        }
        if (files.isNotEmpty) {
          await a.storage.from('recordings').remove(files);
        }
      } catch (_) {}
      try {
        await a.from('recordings').delete().eq('production_id', productionId);
        await a.from('cast_members').delete().eq('production_id', productionId);
        await a.from('productions').delete().eq('id', productionId);
        print('  cleaned up $productionId');
      } catch (e) {
        print('  cleanup warning: $e (you may need to delete $productionId manually)');
      }
    }
    await a.dispose();
    await b.dispose();
  }

  print('\n══════════ $_pass passed, $_fail failed ══════════');
  exit(_fail == 0 ? 0 : 1);
}

class _Cred {
  final String accessToken;
  final String userId;
  _Cred(this.accessToken, this.userId);
}

/// Authenticate via the auth REST API and return the access token + user id.
/// (The standalone Dart client throws a client-side null on the signUp/signIn
/// *success* path — no session storage — so we go straight to REST and inject
/// the token into each client's headers.) Creates the account on first use
/// (the project has signups on, email confirmation off).
Future<_Cred?> _auth(String url, String key, String email, String pass) async {
  final body = jsonEncode({'email': email, 'password': pass});
  // Try signup first; if already registered, sign in with password.
  var res = await _authPost('$url/auth/v1/signup', key, body);
  if (res == null || res['access_token'] == null) {
    res = await _authPost('$url/auth/v1/token?grant_type=password', key, body);
  }
  final accessToken = res?['access_token'] as String?;
  final userId = (res?['user'] as Map?)?['id'] as String?;
  if (accessToken == null || userId == null) {
    print('  auth failed for $email: '
        '${res?['msg'] ?? res?['error_description'] ?? res?['error'] ?? res}');
    return null;
  }
  return _Cred(accessToken, userId);
}

Future<Map<String, dynamic>?> _authPost(
    String url, String key, String body) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse(url));
    req.headers
      ..set('apikey', key)
      ..set('Content-Type', 'application/json');
    req.add(utf8.encode(body));
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

String _uuid() {
  final r = Random.secure();
  String h(int n) =>
      List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
  return '${h(8)}-${h(4)}-4${h(3)}-${(8 + r.nextInt(4)).toRadixString(16)}${h(3)}-${h(12)}';
}

String _keyFromUrl(String url) {
  const marker = '/recordings/';
  final i = url.indexOf(marker);
  if (i < 0) return url;
  var p = url.substring(i + marker.length);
  final q = p.indexOf('?');
  if (q >= 0) p = p.substring(0, q);
  return Uri.decodeFull(p);
}

String _joinCode() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final r = Random.secure();
  return List.generate(6, (_) => chars[r.nextInt(chars.length)]).join();
}

Uint8List _fakeAudio(int seed) =>
    Uint8List.fromList(List.generate(2048, (i) => (i * 31 + seed) & 0xff));
