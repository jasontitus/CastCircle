import 'dart:io';
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
    await Supabase.initialize(url: url, anonKey: anonKey);
    _initialized = true;
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
    final row = await _client
        .from('productions')
        .insert({
          'title': title,
          'organizer_id': userId,
          'status': 'draft',
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
    return _client
        .from('cast_members')
        .select('*, profiles(*)')
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
