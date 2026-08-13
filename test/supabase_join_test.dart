import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Live test against the real Supabase REST API using raw HTTP.
/// No Flutter plugins needed — runs on macOS.
///
/// Run with: flutter test test/supabase_join_test.dart
void main() {

  // These tests hit the LIVE production Supabase: every run signs up a real
  // throwaway account (polluting auth.users) and requires network. They are
  // opt-in: RUN_SUPABASE_TESTS=1 flutter test --dart-define=RUN_SUPABASE_TESTS=1 ...
  const optIn = bool.fromEnvironment('RUN_SUPABASE_TESTS') ||
      String.fromEnvironment('RUN_SUPABASE_TESTS') == '1';
  if (!optIn) {
    test('skipped — live-Supabase tests are opt-in', () {
      markTestSkipped('Set --dart-define=RUN_SUPABASE_TESTS=1 to run the '
          'live join-flow tests against production Supabase.');
    });
    return;
  }
  const supabaseUrl = 'https://vngpbmqymdaxxnvqptsk.supabase.co';
  const anonKey = 'sb_publishable_f3YAIMI4GIEIPdDwnvfO3Q_stwSCxXI';

  late String authToken;

  setUpAll(() async {
    // Sign up a test user to get an auth token
    final signUpResp = await http.post(
      Uri.parse('$supabaseUrl/auth/v1/signup'),
      headers: {
        'apikey': anonKey,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'email':
            'join_test_${DateTime.now().millisecondsSinceEpoch}@test.com',
        'password': 'testtest123',
      }),
    );

    final signUpData = jsonDecode(signUpResp.body);
    authToken = signUpData['access_token'] as String? ?? anonKey;
    print('Auth token length: ${authToken.length}');
  });

  Map<String, String> headers({bool authenticated = true}) => {
        'apikey': anonKey,
        'Authorization': 'Bearer ${authenticated ? authToken : anonKey}',
        'Content-Type': 'application/json',
      };

  test('RPC lookup_production_by_join_code with DHT6XT', () async {
    final resp = await http.post(
      Uri.parse('$supabaseUrl/rest/v1/rpc/lookup_production_by_join_code'),
      headers: headers(),
      body: jsonEncode({'lookup_code': 'DHT6XT'}),
    );

    print('Status: ${resp.statusCode}');
    print('Body: ${resp.body}');

    expect(resp.statusCode, 200);

    final result = jsonDecode(resp.body);
    print('Decoded type: ${result.runtimeType}');
    print('Is Map: ${result is Map}');

    expect(result, isA<Map>());
    expect(result['title'], 'Macbeth');
    expect(result['join_code'], 'DHT6XT');
  });

  test('RPC fetch_cast_for_join', () async {
    // Get production ID first
    final lookupResp = await http.post(
      Uri.parse('$supabaseUrl/rest/v1/rpc/lookup_production_by_join_code'),
      headers: headers(),
      body: jsonEncode({'lookup_code': 'DHT6XT'}),
    );
    final prod = jsonDecode(lookupResp.body);
    final prodId = prod['id'] as String;

    final castResp = await http.post(
      Uri.parse('$supabaseUrl/rest/v1/rpc/fetch_cast_for_join'),
      headers: headers(),
      body: jsonEncode({'prod_id': prodId}),
    );

    print('Cast status: ${castResp.statusCode}');
    print('Cast body: ${castResp.body}');
    expect(castResp.statusCode, 200);
  });

  test('Direct query with authenticated user', () async {
    final resp = await http.get(
      Uri.parse(
          '$supabaseUrl/rest/v1/productions?join_code=eq.DHT6XT&select=id,title,join_code'),
      headers: headers(),
    );

    print('Direct status: ${resp.statusCode}');
    print('Direct body: ${resp.body}');

    final result = jsonDecode(resp.body);
    print('Direct type: ${result.runtimeType}');
    print('Direct length: ${result is List ? result.length : "not a list"}');
  });

  test('Simulate what supabase_flutter rpc() does', () async {
    // supabase_flutter's rpc() calls PostgREST /rest/v1/rpc/<name>
    // and parses the response. Let's see what type it would be.
    final resp = await http.post(
      Uri.parse('$supabaseUrl/rest/v1/rpc/lookup_production_by_join_code'),
      headers: headers(),
      body: jsonEncode({'lookup_code': 'DHT6XT'}),
    );

    final decoded = jsonDecode(resp.body);

    // This is what supabase_flutter returns from rpc()
    print('');
    print('=== What the app sees ===');
    print('Type: ${decoded.runtimeType}');
    print('is Map: ${decoded is Map}');
    print('is Map<String, dynamic>: ${decoded is Map<String, dynamic>}');
    print('is List: ${decoded is List}');

    if (decoded is Map) {
      final cast = Map<String, dynamic>.from(decoded);
      print('Successfully cast to Map<String, dynamic>');
      print('Title: ${cast["title"]}');
    }
  });
}
