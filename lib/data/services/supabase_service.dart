import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'debug_log_service.dart';

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
  /// Public access for debug log upload and other direct operations.
  SupabaseClient get client => _client;
  DebugLogService get _dlog => DebugLogService.instance;
  bool _initialized = false;
  bool get isInitialized => _initialized;

  /// Initialize Supabase. Call once at app startup.
  /// Pass url and publishableKey from environment config or
  /// compile-time constants.
  Future<void> init({
    required String url,
    required String publishableKey,
  }) async {
    if (_initialized) return;
    // Timeout prevents startup hanging on expired tokens or an unreachable
    // server. The timeout does NOT cancel initialization — it keeps running.
    final initFuture =
        Supabase.initialize(url: url, publishableKey: publishableKey);
    try {
      await initFuture.timeout(const Duration(seconds: 5));
      _initialized = true;
    } on TimeoutException {
      // Do NOT mark initialized here: until Supabase.initialize actually
      // completes, Supabase.instance.client throws — the old code set the
      // flag anyway, so innocuous isSignedIn checks blew up on slow-network
      // cold starts. Flip the flag when init really finishes.
      _dlog.log(
          LogCategory.network,
          'Supabase init slow (>5s) — starting offline; cloud features '
          'enable when it completes');
      unawaited(initFuture.then((_) {
        _initialized = true;
        _dlog.log(LogCategory.network,
            'Supabase init completed late — cloud features enabled');
      }).catchError((Object e) {
        _dlog.logError(
            LogCategory.network, 'Supabase init failed after timeout', e);
      }));
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
    String? id,
    String? joinCode,
  }) async {
    final userId = currentUser!.id;
    final insertData = <String, dynamic>{
      'title': title,
      'organizer_id': userId,
      'status': 'draft',
      'join_code': joinCode ?? generateJoinCode(),
    };
    // Use the caller's id when provided so the cloud row matches the local
    // (optimistically-created) production instead of a server-generated id.
    if (id != null) insertData['id'] = id;
    final row = await _client
        .from('productions')
        .insert(insertData)
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

  /// Delete a production from the cloud FOR EVERYONE. Only the organizer's
  /// RLS policy permits this; script lines, cast members, and recording
  /// metadata cascade via foreign keys. Throws if nothing was deleted
  /// (not the organizer, or already gone).
  /// Returns true when a cloud row was actually deleted, false when there
  /// was no row visible to us at all (never pushed, or already gone) — the
  /// caller may safely delete locally in both cases. Throws ONLY when the
  /// cloud still holds a row it refused to delete, because deleting locally
  /// then would boomerang on the next restore.
  ///
  /// The zero-rows case used to throw unconditionally, which made a
  /// production that never reached the cloud impossible to delete at all
  /// (field: "Cloud delete failed for 'test'" on every attempt).
  Future<bool> deleteProductionEverywhere(String productionId) async {
    final deleted = await _client
        .from('productions')
        .delete()
        .eq('id', productionId)
        .select('id');
    if (deleted.isNotEmpty) {
      _dlog.log(LogCategory.network,
          'Deleted production $productionId from the cloud (cascade)');
      return true;
    }
    // Nothing deleted — is the row genuinely there (a refusal we must
    // respect) or simply absent/invisible to us (safe to delete locally)?
    final existing = await _client
        .from('productions')
        .select('id')
        .eq('id', productionId)
        .maybeSingle();
    if (existing == null) {
      _dlog.log(
          LogCategory.network,
          'No cloud row for production $productionId (never pushed or '
          'already gone) — local delete is safe');
      return false;
    }
    throw StateError(
        'Cloud delete removed nothing — only the organizer can delete a '
        'production.');
  }

  /// Leave a production: remove the signed-in user's own cast_members rows.
  /// The production itself is untouched. Throws if no membership row was
  /// removed (e.g. the "Members can leave" policy isn't deployed yet) so the
  /// caller doesn't do a local delete that boomerangs back on the next sync.
  /// Returns true when a membership row was removed, false when there was
  /// none to remove (already left, or never joined in the cloud) — safe to
  /// drop locally either way. Throws only on a real error, so a
  /// never-synced production can still be removed from the device.
  Future<bool> leaveProduction(String productionId) async {
    final uid = currentUser?.id;
    if (uid == null) throw StateError('Not signed in');
    final deleted = await _client
        .from('cast_members')
        .delete()
        .eq('production_id', productionId)
        .eq('user_id', uid)
        .select('id');
    if (deleted.isEmpty) {
      _dlog.log(
          LogCategory.network,
          'No cloud membership row for production $productionId — local '
          'removal is safe');
      return false;
    }
    _dlog.log(LogCategory.network,
        'Left production $productionId (${deleted.length} membership row(s))');
    return true;
  }

  // ── Voice Preset (cloud sync) ────────────────────────

  /// Save the organizer's voice preset choice to Supabase.
  Future<void> saveVoicePreset({
    required String productionId,
    required String presetId,
  }) async {
    await _client
        .from('productions')
        .update({'voice_preset': presetId})
        .eq('id', productionId);
  }

  /// Save the production locale (dialect) to Supabase.
  Future<void> saveLocale({
    required String productionId,
    required String locale,
  }) async {
    await _client
        .from('productions')
        .update({'locale': locale})
        .eq('id', productionId);
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
  ///
  /// Pass [id] to reuse the caller's locally-generated id so the cloud
  /// invitation and the director's local cast_member row share one id — without
  /// it the cloud row gets a server-generated id and the two diverge (which can
  /// surface as a duplicate member if cast is ever synced cloud→local).
  Future<Map<String, dynamic>> createCastInvitation({
    required String productionId,
    required String characterName,
    required String displayName,
    String? contactInfo,
    required String role,
    String? id,
  }) async {
    final data = <String, dynamic>{
      'production_id': productionId,
      'character_name': characterName,
      'display_name': displayName,
      'contact_info': contactInfo,
      'role': role,
      'invited_at': DateTime.now().toIso8601String(),
    };
    if (id != null) data['id'] = id;
    return _client.from('cast_members').insert(data).select().single();
  }

  /// Remove a cast member FOR EVERYONE (organizer-side unassign).
  ///
  /// Dropping only the local Drift row leaves the cloud invitation alive: the
  /// next cast sync re-saves it locally and the actor's join link keeps
  /// working. Throws if nothing was deleted (RLS lets only the organizer
  /// remove somebody else's row) so the caller can keep the local row rather
  /// than have it boomerang back on the next sync.
  Future<void> removeCastMember(String castMemberId) async {
    final deleted = await _client
        .from('cast_members')
        .delete()
        .eq('id', castMemberId)
        .select('id');
    if (deleted.isEmpty) {
      throw StateError(
          'Cloud delete removed nothing — only the organizer can remove a '
          'cast member (or the row was already gone).');
    }
    _dlog.log(LogCategory.network,
        'Removed cast member $castMemberId from the cloud');
  }

  /// Point a cast member at a renamed character.
  ///
  /// character_name is the only link between an actor and their role, so a
  /// character rename that stops at the local row leaves the cloud copy — and
  /// therefore every other device — assigned to a name the script dropped.
  Future<void> renameCastCharacter({
    required String castMemberId,
    required String characterName,
  }) async {
    final updated = await _client
        .from('cast_members')
        .update({'character_name': characterName})
        .eq('id', castMemberId)
        .select('id');
    if (updated.isEmpty) {
      throw StateError(
          'Cloud rename updated no rows for cast member $castMemberId.');
    }
    _dlog.log(LogCategory.network,
        'Renamed cast member $castMemberId → "$characterName"');
  }

  /// Claim an existing invitation by setting user_id and joined_at.
  Future<void> claimInvitation({
    required String castMemberId,
    required String userId,
  }) async {
    try {
      await _client.rpc('claim_cast_invitation',
          params: {'member_id': castMemberId});
      // The RPC returns void even when it matched 0 rows (role already
      // claimed) — verify the row is actually ours before reporting success.
      final row = await _client
          .from('cast_members')
          .select('user_id')
          .eq('id', castMemberId)
          .maybeSingle();
      final claimedBy = row?['user_id'] as String?;
      if (claimedBy != userId) {
        _dlog.logError(
            LogCategory.network,
            'Join: invitation $castMemberId already claimed by another user '
            '— RPC was a no-op');
        throw StateError(
            'This role has already been claimed by another cast member.');
      }
      _dlog.log(LogCategory.network,
          'Join: claimed invitation $castMemberId via RPC');
    } on StateError {
      rethrow;
    } catch (e) {
      _dlog.logError(LogCategory.network,
          'Join: claim RPC failed for $castMemberId, trying direct update', e);
      try {
        // Guard on user_id IS NULL: this fallback fires on ANY RPC failure
        // (including transient network errors) and the cast_members UPDATE
        // policy is wide open — without the guard, a joiner with a stale
        // lookup could silently overwrite (steal) an already-claimed role.
        final updated = await _client
            .from('cast_members')
            .update({
              'user_id': userId,
              'joined_at': DateTime.now().toIso8601String(),
            })
            .eq('id', castMemberId)
            .isFilter('user_id', null)
            .select('id');
        if (updated.isEmpty) {
          // 0 rows: either someone else holds the role, or an earlier attempt
          // (e.g. the RPC before its verify flaked) already claimed it for us.
          final row = await _client
              .from('cast_members')
              .select('user_id')
              .eq('id', castMemberId)
              .maybeSingle();
          if ((row?['user_id'] as String?) == userId) {
            _dlog.log(LogCategory.network,
                'Join: invitation $castMemberId was already claimed by us');
            return;
          }
          _dlog.logError(
              LogCategory.network,
              'Join: invitation $castMemberId is already claimed by someone '
              'else — refusing to overwrite');
          throw StateError(
              'This role has already been claimed by another cast member.');
        }
        _dlog.log(LogCategory.network,
            'Join: claimed invitation $castMemberId via direct update');
      } catch (e2) {
        _dlog.logError(LogCategory.network,
            'Join: claim FAILED for $castMemberId (both RPC and direct)', e2);
        rethrow;
      }
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
        _dlog.log(LogCategory.network,
            'Join: self-joined "$characterName" via RPC');
        return Map<String, dynamic>.from(result);
      }
    } catch (e) {
      _dlog.logError(LogCategory.network,
          'Join: join_production RPC failed, trying direct insert', e);
    }

    try {
      final row = await _client
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
      _dlog.log(LogCategory.network,
          'Join: self-joined "$characterName" via direct insert');
      return row;
    } catch (e) {
      _dlog.logError(LogCategory.network,
          'Join: self-join FAILED for "$characterName" (both RPC and direct)', e);
      rethrow;
    }
  }

  /// Look up a production by its join code.
  /// Uses RPC function (SECURITY DEFINER) to bypass RLS.
  Future<Map<String, dynamic>?> lookupByJoinCode(String code) async {
    final dlog = DebugLogService.instance;
    dlog.log(LogCategory.network,
        'Join lookup: code=$code, initialized=$_initialized, signedIn=$isSignedIn');

    try {
      // Try RPC first (bypasses RLS, always works)
      final rpcResult = await _client.rpc(
        'lookup_production_by_join_code',
        params: {'lookup_code': code.toUpperCase()},
      );
      dlog.log(LogCategory.network,
          'RPC result: type=${rpcResult.runtimeType}, isMap=${rpcResult is Map}, value=$rpcResult');

      if (rpcResult is Map) {
        dlog.log(LogCategory.network, 'RPC success: ${rpcResult['title']}');
        return Map<String, dynamic>.from(rpcResult);
      }
      if (rpcResult != null) {
        try {
          final map = Map<String, dynamic>.from(rpcResult as dynamic);
          dlog.log(LogCategory.network, 'RPC cast success: ${map['title']}');
          return map;
        } catch (e) {
          dlog.logError(LogCategory.network, 'Could not cast RPC result: $e');
        }
      }
      dlog.log(LogCategory.network, 'RPC returned null/non-Map, trying direct query');
    } catch (e) {
      dlog.logError(LogCategory.network, 'RPC lookup failed: $e');
    }

    // Fallback: direct query
    try {
      dlog.log(LogCategory.network, 'Trying direct query for join_code=$code');
      final rows = await _client
          .from('productions')
          .select()
          .eq('join_code', code.toUpperCase())
          .limit(1);
      dlog.log(LogCategory.network, 'Direct query: ${rows.length} rows');
      if (rows.isEmpty) return null;
      return rows.first;
    } catch (e) {
      dlog.logError(LogCategory.network, 'Direct lookup also failed: $e');
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

  /// Both ids come from our own row data, but a forged or corrupt sync row
  /// could carry `../` and walk the storage key outside the production's
  /// prefix — refuse anything that isn't a plain UUID.
  static final _uuidRe = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  static String _requireUuid(String value, String what) {
    if (!_uuidRe.hasMatch(value)) {
      throw ArgumentError('$what is not a UUID: "$value"');
    }
    return value;
  }

  /// Upload a recorded line to Supabase Storage.
  /// Path: recordings/{productionId}/{characterName}/{lineId}.m4a
  Future<String> uploadRecording({
    required String productionId,
    required String characterName,
    required String lineId,
    required File audioFile,
  }) async {
    // A UNIQUE key per upload. The recordings bucket has no UPDATE/DELETE storage
    // policy, so re-uploading to the same key is RLS-blocked (overwrite fails) —
    // which silently breaks re-records. A fresh key each time is always an
    // INSERT (allowed); download resolves the exact object from the stored URL,
    // so the key shape doesn't matter to playback. (Old per-take objects orphan
    // harmlessly — the recordings row keeps only the latest URL.)
    _requireUuid(productionId, 'productionId');
    _requireUuid(lineId, 'lineId');
    final safeChar = characterName.replaceAll('/', '-');
    final unique =
        '${DateTime.now().millisecondsSinceEpoch}${Random().nextInt(1000)}';
    final path = '$productionId/$safeChar/$lineId/$unique.m4a';
    final sizeKb = (audioFile.lengthSync() / 1024).toStringAsFixed(0);
    _dlog.log(LogCategory.network, 'Storage upload → recordings/$path (${sizeKb}KB)');
    try {
      await _client.storage.from('recordings').upload(
            path,
            audioFile,
            fileOptions: const FileOptions(contentType: 'audio/mp4'),
          );
    } catch (e) {
      _dlog.logError(LogCategory.network,
          'Storage upload FAILED → recordings/$path', e);
      rethrow;
    }
    return _client.storage.from('recordings').getPublicUrl(path);
  }

  /// Upload recording from bytes (useful for in-memory buffers). Uses a unique
  /// key per upload for the same reason as [uploadRecording].
  Future<String> uploadRecordingBytes({
    required String productionId,
    required String characterName,
    required String lineId,
    required Uint8List bytes,
  }) async {
    _requireUuid(productionId, 'productionId');
    _requireUuid(lineId, 'lineId');
    final safeChar = characterName.replaceAll('/', '-');
    final unique =
        '${DateTime.now().millisecondsSinceEpoch}${Random().nextInt(1000)}';
    final path = '$productionId/$safeChar/$lineId/$unique.m4a';
    await _client.storage.from('recordings').uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(contentType: 'audio/mp4'),
        );
    return _client.storage.from('recordings').getPublicUrl(path);
  }

  /// Download a recording by its stored public URL. Resolves the exact storage
  /// object key from the URL, so it works regardless of the key layout — current
  /// unique-per-take keys and older fixed `{prod}/{char}/{line}.m4a` keys alike —
  /// and is immune to character names with awkward characters.
  Future<Uint8List> downloadRecordingByUrl(String audioUrl) async {
    final objectPath = _objectPathFromUrl(audioUrl);
    if (objectPath == null) {
      throw Exception('Could not parse a recordings object path from: $audioUrl');
    }
    try {
      final bytes = await _client.storage.from('recordings').download(objectPath);
      _dlog.log(LogCategory.network,
          'Storage download ← recordings/$objectPath (${(bytes.length / 1024).toStringAsFixed(0)}KB)');
      return bytes;
    } catch (e) {
      _dlog.logError(LogCategory.network,
          'Storage download FAILED ← recordings/$objectPath', e);
      rethrow;
    }
  }

  /// Extract the storage object key (everything after the `recordings/` bucket
  /// segment, minus any query string) from a Supabase storage URL.
  static String? _objectPathFromUrl(String url) {
    const marker = '/recordings/';
    final i = url.indexOf(marker);
    if (i < 0) return null;
    var path = url.substring(i + marker.length);
    final q = path.indexOf('?');
    if (q >= 0) path = path.substring(0, q);
    return Uri.decodeFull(path);
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
  ///
  /// [recordedAt] should be the time the audio was actually recorded so
  /// that other devices can compare freshness; defaults to now.
  Future<void> saveRecordingMetadata({
    required String productionId,
    required String lineId,
    required String userId,
    required String audioUrl,
    required int durationMs,
    DateTime? recordedAt,
  }) async {
    // The recordings table has UNIQUE (production_id, line_id, user_id);
    // without onConflict the upsert resolves against the primary key only,
    // so re-recording a line would fail with a unique violation.
    try {
      await _client.from('recordings').upsert(
        {
          'production_id': productionId,
          'line_id': lineId,
          'user_id': userId,
          'audio_url': audioUrl,
          'duration_ms': durationMs,
          'recorded_at':
              (recordedAt ?? DateTime.now()).toUtc().toIso8601String(),
        },
        onConflict: 'production_id,line_id,user_id',
      );
      _dlog.log(LogCategory.network,
          'Recording metadata saved: line=$lineId user=$userId');
    } catch (e) {
      _dlog.logError(
          LogCategory.network,
          'Recording metadata save FAILED: line=$lineId user=$userId '
          '(castmates won\'t see this recording — check recordings RLS/insert policy)',
          e);
      rethrow;
    }
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

  /// Subscribe to new (and updated) recordings for a production.
  ///
  /// Listens to INSERT *and* UPDATE: a first take INSERTs a row, but a
  /// re-record UPSERTs onto the existing (production_id, line_id, user_id) row
  /// — i.e. an UPDATE. Without the UPDATE listener, castmates never receive
  /// re-recorded takes live (only on the next full sync when they reopen).
  ///
  /// Returns a channel that can be unsubscribed from.
  RealtimeChannel subscribeToRecordings({
    required String productionId,
    required void Function(Map<String, dynamic> payload) onNewRecording,
  }) {
    final filter = PostgresChangeFilter(
      type: PostgresChangeFilterType.eq,
      column: 'production_id',
      value: productionId,
    );
    return _client
        .channel('recordings:$productionId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'recordings',
          filter: filter,
          callback: (payload) {
            _dlog.log(LogCategory.network,
                'Realtime INSERT: line=${payload.newRecord['line_id']}');
            onNewRecording(payload.newRecord);
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'recordings',
          filter: filter,
          callback: (payload) {
            _dlog.log(LogCategory.network,
                'Realtime UPDATE (re-record): line=${payload.newRecord['line_id']}');
            onNewRecording(payload.newRecord);
          },
        )
        // Log the channel lifecycle: if this never reaches "subscribed", live
        // sharing is down (realtime not enabled on the table, auth/RLS, or
        // network) — the single most useful signal when takes aren't arriving.
        .subscribe((status, error) {
      if (error != null) {
        _dlog.logError(LogCategory.network,
            'Realtime channel error for recordings:$productionId ($status)', error);
      } else {
        _dlog.log(LogCategory.network,
            'Realtime channel status for recordings:$productionId → $status');
      }
    });
  }

  /// Unsubscribe from a channel.
  Future<void> unsubscribe(RealtimeChannel channel) {
    return _client.removeChannel(channel);
  }
}
