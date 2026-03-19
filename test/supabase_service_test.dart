import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const supabaseUrl = 'https://vngpbmqymdaxxnvqptsk.supabase.co';
  const anonKey = 'sb_publishable_f3YAIMI4GIEIPdDwnvfO3Q_stwSCxXI';
  
  setUpAll(() async {
    // Mock SharedPreferences so Supabase.initialize works in tests
    SharedPreferences.setMockInitialValues({});
    
    await Supabase.initialize(url: supabaseUrl, anonKey: anonKey);
    
    // Sign up a test user
    try {
      await Supabase.instance.client.auth.signUp(
        email: 'test_${DateTime.now().millisecondsSinceEpoch}@test.com',
        password: 'testtest123',
      );
      print('Signed in as: ${Supabase.instance.client.auth.currentUser?.email}');
    } catch (e) {
      print('Auth: $e');
    }
  });

  test('lookupByJoinCode via rpc() — exact app code path', () async {
    final client = Supabase.instance.client;
    
    print('isSignedIn: ${client.auth.currentUser != null}');
    
    // This is EXACTLY what SupabaseService.lookupByJoinCode does
    try {
      final rpcResult = await client.rpc(
        'lookup_production_by_join_code',
        params: {'lookup_code': 'DHT6XT'},
      );
      
      print('rpcResult type: ${rpcResult.runtimeType}');
      print('rpcResult: $rpcResult');
      print('is Map: ${rpcResult is Map}');
      print('is null: ${rpcResult == null}');
      
      if (rpcResult != null && rpcResult is Map) {
        final map = Map<String, dynamic>.from(rpcResult);
        print('SUCCESS — Title: ${map['title']}');
        expect(map['title'], 'Macbeth');
      } else {
        print('WOULD FALL THROUGH TO DIRECT QUERY');
        // Try direct query
        final rows = await client
            .from('productions')
            .select()
            .eq('join_code', 'DHT6XT')
            .limit(1);
        print('Direct query rows: $rows');
        print('Direct query type: ${rows.runtimeType}');
        if (rows.isNotEmpty) {
          print('Direct query found: ${rows.first}');
        } else {
          print('BOTH FAILED — user would see "No production found"');
        }
      }
    } catch (e) {
      print('RPC THREW: $e');
      print('Exception type: ${e.runtimeType}');
      
      // Try fallback
      try {
        final rows = await client
            .from('productions')
            .select()
            .eq('join_code', 'DHT6XT')
            .limit(1);
        print('Fallback direct query: $rows');
      } catch (e2) {
        print('Fallback also failed: $e2');
      }
    }
  });
}
