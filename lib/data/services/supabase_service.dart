import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Lightweight Supabase service for production management, auth, and recording sync.
///
/// Architecture notes:
/// - The local Drift DB is the source of truth for script data
/// - Supabase stores: users, productions, cast memberships, and recorded audio
/// - Clients download all production data locally and rarely query the server
/// - Audio recordings are compressed (AAC/m4a, ~50KB per line)
class SupabaseService {
  SupabaseService._();
  static final instance = SupabaseService._();

  SupabaseClient get _client => Supabase.instance.client;
  bool _initialized = false;
  bool get isInitialized => _initialized;

  /// Initialize Supabase. Call once at app startup.
  /// Pass url and anonKey from environment config or compile-time constants.
  Future<void> init({
    required String url,
    required String anonKey,
  }) async {
    if (_initialized) return;
    try {
      // Timeout prevents hanging on expired tokens or unreachable server
      await Supabase.initialize(url: url, anonKey: anonKey)
          .timeout(const Duration(seconds: 5));
      _initialized = true;
    } on TimeoutException {
      debugPrint('Supabase: init timed out after 5s, proceeding offline');
      // Mark as initialized anyway — the SDK may still work for cached auth
      _initialized = true;
    }
  }

  // ── Auth ──────────────────────────────────────────────

  User? get currentUser => _initialized ? _client.auth.currentUser : null;
  bool get isSignedIn => _initialized && _client.auth.currentUser != null;

  Stream<AuthState> get authStateChanges => _initialized
      ? _client.auth.onAuthStateChange
      : const Stream.empty();

  Future<AuthResponse> signInWithEmail(String email, String password) {
    if (!_initialized) throw Exception('Supabase is not initialized');
    return _client.auth.signInWithPassword(email: email, password: password);
  }

  Future<AuthResponse> signUpWithEmail(String email, String password) {
    if (!_initialized) throw Exception('Supabase is not initialized');
    return _client.auth.signUp(email: email, password: password);
  }

  Future<void> signOut() => _client.auth.signOut();

  // ── Productions ───────────────────────────────────────

  Future<List<Map<String, dynamic>>> fetchMyProductions() async {
    final userId = currentUser?.id;
    if (userId == null) return [];

    // Get productions where user is a cast member
    final castRows = await _client
        .from('cast_members')
        .select('production_id')
        .eq('user_id', userId);

    final productionIds =
        castRows.map((r) => r['production_id'] as String).toList();

    if (productionIds.isEmpty) return [];

    final rows = await _client
        .from('productions')
        .select()
        .inFilter('id', productionIds)
        .order('created_at', ascending: false);

    return rows;
  }

  Future<Map<String, dynamic>> createProduction({
    required String title,
  }) async {
    final userId = currentUser!.id;
    final joinCode = generateJoinCode();
    final row = await _client
        .from('productions')
        .insert({
          'title': title,
          'organizer_id': userId,
          'status': 'draft',
          'join_code': joinCode,
        })
        .select()
        .single();

    // Auto-add organizer as cast member
    await _client.from('cast_members').insert({
      'production_id': row['id'],
      'user_id': userId,
      'role': 'organizer',
    });

    return row;
  }

  // ── Cast ──────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> fetchCastMembers(
      String productionId) async {
    try {
      // Try RPC first (bypasses RLS)
      final rpcResult = await _client.rpc(
        'fetch_cast_for_join',
        params: {'prod_id': productionId},
      );
      if (rpcResult != null && rpcResult is List) {
        return List<Map<String, dynamic>>.from(
            rpcResult.map((e) => Map<String, dynamic>.from(e)));
      }
    } catch (e) {
      debugPrint('RPC fetch_cast_for_join failed: $e');
    }

    // Fallback: direct query (simpler select without profiles join)
    return _client
        .from('cast_members')
        .select()
        .eq('production_id', productionId);
  }

  Future<void> addCastMember({
    required String productionId,
    required String userId,
    required String role,
    String? characterName,
  }) async {
    final data = <String, dynamic>{
      'production_id': productionId,
      'user_id': userId,
      'role': role,
    };
    if (characterName != null) data['character_name'] = characterName;
    await _client.from('cast_members').insert(data);
  }

  /// Create a cast invitation (no user_id yet — they claim it when they join).
  Future<Map<String, dynamic>> createCastInvitation({
    required String productionId,
    required String characterName,
    required String displayName,
    String? contactInfo,
    required String role,
  }) async {
    return _client
        .from('cast_members')
        .insert({
          'production_id': productionId,
          'character_name': characterName,
          'display_name': displayName,
          'contact_info': contactInfo,
          'role': role,
          'invited_at': DateTime.now().toIso8601String(),
        })
        .select()
        .single();
  }

  /// Claim an existing invitation by setting user_id and joined_at.
  Future<void> claimInvitation({
    required String castMemberId,
    required String userId,
  }) async {
    try {
      await _client.rpc('claim_cast_invitation',
          params: {'member_id': castMemberId});
    } catch (e) {
      debugPrint('RPC claim failed, trying direct: $e');
      await _client.from('cast_members').update({
        'user_id': userId,
        'joined_at': DateTime.now().toIso8601String(),
      }).eq('id', castMemberId);
    }
  }

  /// Self-join a production (create a new cast_members row with user_id set).
  Future<Map<String, dynamic>> selfJoinProduction({
    required String productionId,
    required String userId,
    required String characterName,
    required String displayName,
    required String role,
  }) async {
    try {
      final result = await _client.rpc('join_production', params: {
        'prod_id': productionId,
        'char_name': characterName,
        'display_name': displayName,
        'member_role': role,
      });
      if (result != null && result is Map) {
        return Map<String, dynamic>.from(result);
      }
    } catch (e) {
      debugPrint('RPC join_production failed, trying direct: $e');
    }

    return _client
        .from('cast_members')
        .insert({
          'production_id': productionId,
          'user_id': userId,
          'character_name': characterName,
          'display_name': displayName,
          'role': role,
          'joined_at': DateTime.now().toIso8601String(),
        })
        .select()
        .single();
  }

  /// Look up a production by its join code.
  /// Uses RPC function (SECURITY DEFINER) to bypass RLS.
  Future<Map<String, dynamic>?> lookupByJoinCode(String code) async {
    try {
      // Try RPC first (bypasses RLS, always works)
      final rpcResult = await _client.rpc(
        'lookup_production_by_join_code',
        params: {'lookup_code': code.toUpperCase()},
      );
      if (rpcResult != null && rpcResult is Map) {
        return Map<String, dynamic>.from(rpcResult);
      }

      // Fallback: direct query (requires RLS policy)
      final rows = await _client
          .from('productions')
          .select()
          .eq('join_code', code.toUpperCase())
          .limit(1);
      if (rows.isEmpty) return null;
      return rows.first;
    } catch (e) {
      debugPrint('Join code lookup failed: $e');
      return null;
    }
  }

  /// Fetch recording progress per character for a production.
  Future<List<Map<String, dynamic>>> fetchRecordingProgress(
      String productionId) async {
    return _client
        .from('recordings')
        .select('line_id, user_id')
        .eq('production_id', productionId);
  }

  // ── Join Code Generation ───────────────────────────────

  static const _joinCodeChars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  /// Generate a 6-character alphanumeric code (no I/O/0/1 for readability).
  static String generateJoinCode() {
    final rng = Random.secure();
    return List.generate(
      6,
      (_) => _joinCodeChars[rng.nextInt(_joinCodeChars.length)],
    ).join();
  }

  // ── Recordings ────────────────────────────────────────

  /// Upload a recorded line to Supabase Storage.
  /// Path: recordings/{productionId}/{characterName}/{lineId}.m4a
  Future<String> uploadRecording({
    required String productionId,
    required String characterName,
    required String lineId,
    required File audioFile,
  }) async {
    final path = '$productionId/$characterName/$lineId.m4a';
    await _client.storage.from('recordings').upload(
          path,
          audioFile,
          fileOptions: const FileOptions(
            contentType: 'audio/mp4',
            upsert: true,
          ),
        );
    return _client.storage.from('recordings').getPublicUrl(path);
  }

  /// Upload recording from bytes (useful for in-memory buffers).
  Future<String> uploadRecordingBytes({
    required String productionId,
    required String characterName,
    required String lineId,
    required Uint8List bytes,
  }) async {
    final path = '$productionId/$characterName/$lineId.m4a';
    await _client.storage.from('recordings').uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(
            contentType: 'audio/mp4',
            upsert: true,
          ),
        );
    return _client.storage.from('recordings').getPublicUrl(path);
  }

  /// Download a recording to a local file.
  Future<Uint8List> downloadRecording({
    required String productionId,
    required String characterName,
    required String lineId,
  }) async {
    final path = '$productionId/$characterName/$lineId.m4a';
    return _client.storage.from('recordings').download(path);
  }

  /// List available recordings for a production.
  Future<List<Map<String, dynamic>>> fetchRecordings(
      String productionId) async {
    return _client
        .from('recordings')
        .select()
        .eq('production_id', productionId);
  }

  /// Save recording metadata after upload.
  Future<void> saveRecordingMetadata({
    required String productionId,
    required String lineId,
    required String userId,
    required String audioUrl,
    required int durationMs,
  }) async {
    await _client.from('recordings').upsert({
      'production_id': productionId,
      'line_id': lineId,
      'user_id': userId,
      'audio_url': audioUrl,
      'duration_ms': durationMs,
      'recorded_at': DateTime.now().toIso8601String(),
    });
  }

  // ── Script Lines (cloud sync) ────────────────────────

  /// Fetch script lines for a production from the cloud.
  Future<List<Map<String, dynamic>>> fetchScriptLines(
      String productionId) async {
    return _client
        .from('script_lines')
        .select()
        .eq('production_id', productionId)
        .order('order_index', ascending: true);
  }

  /// Save script lines to the cloud (replaces all existing lines).
  Future<void> saveScriptLines({
    required String productionId,
    required List<Map<String, dynamic>> lines,
  }) async {
    // Delete existing
    await _client
        .from('script_lines')
        .delete()
        .eq('production_id', productionId);

    // Insert in batches of 100
    for (var i = 0; i < lines.length; i += 100) {
      final batch = lines.sublist(i, i + 100 > lines.length ? lines.length : i + 100);
      await _client.from('script_lines').insert(batch);
    }
  }

  // ── Realtime ──────────────────────────────────────────

  /// Subscribe to new recordings for a production.
  /// Returns a channel that can be unsubscribed from.
  RealtimeChannel subscribeToRecordings({
    required String productionId,
    required void Function(Map<String, dynamic> payload) onNewRecording,
  }) {
    return _client
        .channel('recordings:$productionId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'recordings',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'production_id',
            value: productionId,
          ),
          callback: (payload) => onNewRecording(payload.newRecord),
        )
        .subscribe();
  }

  /// Unsubscribe from a channel.
  Future<void> unsubscribe(RealtimeChannel channel) {
    return _client.removeChannel(channel);
  }
}
