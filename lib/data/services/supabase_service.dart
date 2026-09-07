import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'debug_log_service.dart';
import '../models/cast_member_model.dart';

/// Lightweight Supabase service for production management, auth, and recording sync.
///
/// Architecture notes:
/// - The local Drift DB is the source of truth for script data
/// - Supabase stores: users, productions, cast memberships, and recorded audio
/// - Clients download all production data locally and rarely query the server
/// - Audio recordings are compressed (AAC/m4a, ~50KB per line)
class SupabaseService {
  SupabaseService._() : _injectedClient = null;

  /// Creates a service backed by an isolated client for deterministic contract
  /// tests. Production code uses [instance].
  @visibleForTesting
  SupabaseService.forTesting(SupabaseClient client)
    : _injectedClient = client,
      _initialized = true;

  static final instance = SupabaseService._();

  final SupabaseClient? _injectedClient;
  SupabaseClient get _client => _injectedClient ?? Supabase.instance.client;

  /// Public access for debug log upload and other direct operations.
  SupabaseClient get client => _client;
  DebugLogService get _dlog => DebugLogService.instance;
  bool _initialized = false;
  bool get isInitialized => _initialized;

  /// Completes when Supabase.initialize REALLY finishes (including the late
  /// completion after the 5s startup timeout), and completes false on a real
  /// init failure. app.dart awaits this before wiring the auth listener, so a
  /// restored session is never sampled before the client exists.
  final Completer<bool> _initializationResult = Completer<bool>();
  Future<bool> get initializationResult => _initializationResult.future;

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
    final initFuture = Supabase.initialize(
      url: url,
      publishableKey: publishableKey,
    );
    try {
      await initFuture.timeout(const Duration(seconds: 5));
      _initialized = true;
      _completeInitialization(true);
    } on TimeoutException {
      // Do NOT mark initialized here: until Supabase.initialize actually
      // completes, Supabase.instance.client throws — the old code set the
      // flag anyway, so innocuous isSignedIn checks blew up on slow-network
      // cold starts. Flip the flag when init really finishes.
      _dlog.log(
        LogCategory.network,
        'Supabase init slow (>5s) — starting offline; cloud features '
        'enable when it completes',
      );
      unawaited(
        initFuture
            .then((_) {
              _initialized = true;
              _completeInitialization(true);
              _dlog.log(
                LogCategory.network,
                'Supabase init completed late — cloud features enabled',
              );
            })
            .catchError((Object e) {
              _dlog.logError(
                LogCategory.network,
                'Supabase init failed after timeout',
                e,
              );
            }),
      );
    } catch (e) {
      _dlog.logError(
        LogCategory.network,
        'Supabase init failed — starting offline',
        e,
      );
      _completeInitialization(false);
    }
  }

  void _completeInitialization(bool ok) {
    if (!_initializationResult.isCompleted) _initializationResult.complete(ok);
  }

  // ── Auth ──────────────────────────────────────────────


  User? get currentUser => _initialized ? _client.auth.currentUser : null;
  bool get isSignedIn => _initialized && _client.auth.currentUser != null;

  Stream<AuthState> get authStateChanges =>
      _initialized ? _client.auth.onAuthStateChange : const Stream.empty();

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

    final productionIds = castRows
        .map((r) => r['production_id'] as String)
        .toList();

    if (productionIds.isEmpty) return [];

    final rows = await _client
        .from('productions')
        .select()
        .inFilter('id', productionIds)
        .order('created_at', ascending: false);

    return rows;
  }

  /// Atomically create the production and organizer membership. Retrying with
  /// the same explicit id/join code returns the confirmed existing row.
  Future<Map<String, dynamic>> createProduction({
    required String title,
    String? id,
    String? joinCode,
  }) async {
    final result = await _client.rpc(
      'create_production',
      params: {
        'p_id': id,
        'p_title': title,
        'p_join_code': joinCode ?? generateJoinCode(),
      },
    );
    if (result is! Map) {
      throw StateError(
        'The production creation service returned an invalid response.',
      );
    }
    return Map<String, dynamic>.from(result);
  }

  /// Atomically queue every referenced recording object before deleting the
  /// production and its relational children. Interrupted Storage cleanup stays
  /// durable and is retried when this method is called again.
  Future<bool> deleteProductionEverywhere(String productionId) async {
    final userId = currentUser?.id;
    if (userId == null) throw StateError('Not signed in');
    final result = await _client.rpc(
      'delete_production',
      params: {'p_production_id': productionId},
    );
    if (result is! Map || result['deleted'] is! bool) {
      throw StateError(
        'The production deletion service returned an invalid response.',
      );
    }
    final deleted = result['deleted'] as bool;
    await flushRecordingCleanup(productionId: productionId, userId: userId);
    _dlog.log(
      LogCategory.network,
      deleted
          ? 'Production and recording objects deleted from cloud'
          : 'No cloud production or pending recording cleanup found',
    );
    return deleted;
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
        'removal is safe',
      );
      return false;
    }
    _dlog.log(
      LogCategory.network,
      'Left production $productionId (${deleted.length} membership row(s))',
    );
    return true;
  }

  // ── Voice Preset (cloud sync) ────────────────────────

  /// Save the organizer's voice preset choice to Supabase.
  Future<void> saveVoicePreset({
    required String productionId,
    required String presetId,
  }) async {
    final updated = await _client
        .from('productions')
        .update({'voice_preset': presetId})
        .eq('id', productionId)
        .select('id');
    if (updated.length != 1) {
      throw StateError('Cloud voice preset update was not acknowledged.');
    }
  }

  /// Save the production locale (dialect) to Supabase.
  Future<void> saveLocale({
    required String productionId,
    required String locale,
  }) async {
    final updated = await _client
        .from('productions')
        .update({'locale': locale})
        .eq('id', productionId)
        .select('id');
    if (updated.length != 1) {
      throw StateError('Cloud locale update was not acknowledged.');
    }
  }

  // ── Cast ──────────────────────────────────────────────

  /// Fetch the reduced pre-membership roster contract. Authorization and join
  /// code validation live exclusively in the RPC; a direct-table fallback
  /// would both weaken that boundary and return other users' UUIDs.
  Future<List<Map<String, dynamic>>> fetchCastMembers(
    String productionId, {
    String? joinCode,
  }) async {
    final rpcResult = await _client.rpc(
      'fetch_cast_for_join',
      params: {'prod_id': productionId, 'code': joinCode ?? ''},
    );
    if (rpcResult is! List) {
      throw StateError('The cast roster service returned an invalid response.');
    }
    return rpcResult
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
  }

  /// Create an unclaimed cast invitation through the organizer-only RPC.
  /// Supplying [id] makes durable outbox retries idempotent; the server returns
  /// the existing row only when every invitation field matches.
  Future<Map<String, dynamic>> createCastInvitation({
    required String productionId,
    required String characterName,
    required String displayName,
    String? contactInfo,
    required String role,
    String? id,
  }) async {
    final result = await _client.rpc(
      'create_cast_invitation',
      params: {
        'p_id': id,
        'p_production_id': productionId,
        'p_character_name': characterName,
        'p_display_name': displayName,
        'p_contact_info': contactInfo,
        'p_role': role,
      },
    );
    if (result is! Map) {
      throw StateError(
        'The invitation creation service returned an invalid response.',
      );
    }
    return Map<String, dynamic>.from(result);
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
        'cast member (or the row was already gone).',
      );
    }
    _dlog.log(LogCategory.network, 'Cast member removed from the cloud');
  }

  /// Recreate a cast row as compensation after a later operation fails.
  ///
  /// The live backend has no organizer-side INSERT policy and no
  /// create_cast_member RPC — the only organizer-scoped write path is the
  /// SECURITY DEFINER create_cast_invitation RPC, which inserts an
  /// invitation (user_id null) and preserves the given id. So a restored
  /// row comes back as an invitation: unassigned members are fully
  /// restored; previously-assigned ones must re-claim their link, which the
  /// caller surfaces as best-effort compensation rather than an error.
  Future<void> restoreCastMember(CastMemberModel member) async {
    await createCastInvitation(
      productionId: member.productionId,
      characterName: member.characterName,
      displayName: member.displayName,
      contactInfo: member.contactInfo,
      role: member.role.toSupabaseString(),
      id: member.id,
    );
    if (member.userId != null) {
      _dlog.log(
        LogCategory.network,
        'Restored cast row ${member.id} as an unclaimed invitation — '
        'the actor must re-claim it from their link',
      );
    }
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
      throw StateError('Cloud cast member rename updated no rows.');
    }
    _dlog.log(LogCategory.network, 'Cast member character rename synchronized');
  }

  /// Claim an existing invitation through the code-validating RPC.
  Future<void> claimInvitation({
    required String castMemberId,
    required String joinCode,
  }) async {
    final result = await _client.rpc(
      'claim_cast_invitation',
      params: {'member_id': castMemberId, 'code': joinCode},
    );
    switch (result) {
      case 'claimed':
        _dlog.log(
          LogCategory.network,
          'Join: invitation claimed through the authorized RPC',
        );
        return;
      case 'invalid_code':
        throw StateError('The join code is invalid.');
      case 'already_claimed':
        throw StateError(
          'This role has already been claimed by another cast member.',
        );
      default:
        throw StateError(
          'The invitation service returned an invalid response.',
        );
    }
  }

  /// Self-join through the code-validating RPC. Direct cast_members inserts are
  /// intentionally denied by RLS.
  Future<Map<String, dynamic>> selfJoinProduction({
    required String productionId,
    required String characterName,
    required String displayName,
    required String joinCode,
  }) async {
    final result = await _client.rpc(
      'join_production',
      params: {
        'prod_id': productionId,
        'code': joinCode,
        'char_name': characterName,
        'display_name': displayName,
      },
    );
    if (result is! Map) {
      throw StateError('The join service returned an invalid response.');
    }
    _dlog.log(
      LogCategory.network,
      'Join: membership created through authorized RPC',
    );
    return Map<String, dynamic>.from(result);
  }

  /// Look up the explicit join-screen production contract through the
  /// code-validating RPC. Join codes and production titles are never written to
  /// persistent logs.
  Future<Map<String, dynamic>?> lookupByJoinCode(String code) async {
    _dlog.log(
      LogCategory.network,
      'Join lookup started: initialized=$_initialized, signedIn=$isSignedIn',
    );
    final rpcResult = await _client.rpc(
      'lookup_production_by_join_code',
      params: {'lookup_code': code.toUpperCase()},
    );
    if (rpcResult == null) {
      _dlog.log(LogCategory.network, 'Join lookup returned no match');
      return null;
    }
    if (rpcResult is! Map) {
      throw StateError('The join lookup service returned an invalid response.');
    }
    _dlog.log(LogCategory.network, 'Join lookup succeeded');
    return Map<String, dynamic>.from(rpcResult);
  }

  /// Fetch recording progress per character for a production.
  Future<List<Map<String, dynamic>>> fetchRecordingProgress(
    String productionId,
  ) async {
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
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

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
    // Every take gets a fresh INSERT-only object key. Once the metadata switch
    // commits, [saveRecordingMetadata] deletes the superseded object through
    // the owner-only/organizer DELETE policy. No storage UPDATE is needed.
    _requireUuid(productionId, 'productionId');
    _requireUuid(lineId, 'lineId');
    final safeChar = characterName.replaceAll('/', '-');
    final unique =
        '${DateTime.now().millisecondsSinceEpoch}${Random().nextInt(1000)}';
    final path = '$productionId/$safeChar/$lineId/$unique.m4a';
    final sizeKb = (audioFile.lengthSync() / 1024).toStringAsFixed(0);
    _dlog.log(
      LogCategory.network,
      'Recording storage upload started (${sizeKb}KB)',
    );
    try {
      await _client.storage
          .from('recordings')
          .upload(
            path,
            audioFile,
            fileOptions: const FileOptions(contentType: 'audio/mp4'),
          );
    } catch (e) {
      _dlog.logError(LogCategory.network, 'Recording storage upload failed', e);
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
    await _client.storage
        .from('recordings')
        .uploadBinary(
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
      throw Exception(
        'Could not parse a recordings object path from: $audioUrl',
      );
    }
    try {
      final bytes = await _client.storage
          .from('recordings')
          .download(objectPath);
      _dlog.log(
        LogCategory.network,
        'Recording storage download succeeded '
        '(${(bytes.length / 1024).toStringAsFixed(0)}KB)',
      );
      return bytes;
    } catch (e) {
      _dlog.logError(
        LogCategory.network,
        'Recording storage download failed',
        e,
      );
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

  /// List available recordings after retrying any durable object cleanup left
  /// by an interrupted replacement or explicit delete.
  Future<List<Map<String, dynamic>>> fetchRecordings(
    String productionId,
  ) async {
    final userId = currentUser?.id;
    if (userId != null) {
      await _flushRecordingCleanupDeferred(
        productionId: productionId,
        userId: userId,
      );
    }
    return _client
        .from('recordings')
        .select('line_id, user_id, audio_url, duration_ms, recorded_at')
        .eq('production_id', productionId);
  }

  /// Atomically switch recording metadata and enqueue the superseded object,
  /// then drain the durable cleanup queue. A failed Storage request leaves its
  /// queue row intact, so retrying this method cannot lose the old object path.
  Future<void> saveRecordingMetadata({
    required String productionId,
    required String lineId,
    required String userId,
    required String audioUrl,
    required int durationMs,
    DateTime? recordedAt,
  }) async {
    final objectName = _objectPathFromUrl(audioUrl);
    if (objectName == null) {
      throw ArgumentError('audioUrl does not identify a recordings object');
    }
    final previous = await _client
        .from('recordings')
        .select('audio_url')
        .eq('production_id', productionId)
        .eq('line_id', lineId)
        .eq('user_id', userId)
        .maybeSingle();
    final previousAudioUrl = previous?['audio_url'] as String?;
    final previousObjectName = previousAudioUrl == null
        ? null
        : _objectPathFromUrl(previousAudioUrl);
    final result = await _client.rpc(
      'save_recording_metadata',
      params: {
        'p_production_id': productionId,
        'p_line_id': lineId,
        'p_user_id': userId,
        'p_audio_url': audioUrl,
        'p_object_name': objectName,
        'p_previous_audio_url': previousAudioUrl,
        'p_previous_object_name': previousObjectName,
        'p_duration_ms': durationMs,
        'p_recorded_at': (recordedAt ?? DateTime.now())
            .toUtc()
            .toIso8601String(),
      },
    );
    if (result is! Map || result['saved'] != true) {
      throw StateError('The recording service returned an invalid response.');
    }
    await _flushRecordingCleanupDeferred(
      productionId: productionId,
      userId: userId,
    );
    _dlog.log(LogCategory.network, 'Recording metadata saved');
  }

  /// Durably queue an uploaded object that was superseded before its metadata
  /// could be committed. Returning means the database outbox owns cleanup;
  /// Storage deletion itself may finish during a later sync.
  Future<void> discardRecordingUpload({
    required String productionId,
    required String lineId,
    required String userId,
    required String audioUrl,
  }) async {
    final objectName = _objectPathFromUrl(audioUrl);
    if (objectName == null) {
      throw ArgumentError('audioUrl does not identify a recordings object');
    }
    final queued = await _client.rpc(
      'queue_recording_cleanup',
      params: {
        'p_production_id': productionId,
        'p_line_id': lineId,
        'p_user_id': userId,
        'p_object_name': objectName,
      },
    );
    if (queued != true) {
      throw StateError('The recording cleanup request was rejected.');
    }
    await _flushRecordingCleanupDeferred(
      productionId: productionId,
      userId: userId,
    );
  }

  /// Atomically delete recording metadata and enqueue its object for durable
  /// cleanup. Returns false only when neither a row nor retryable cleanup work
  /// exists for this recording.
  Future<bool> deleteRecording({
    required String productionId,
    required String lineId,
    required String userId,
    String? audioUrl,
  }) async {
    final objectName = audioUrl == null ? null : _objectPathFromUrl(audioUrl);
    if (audioUrl != null && objectName == null) {
      throw ArgumentError('audioUrl does not identify a recordings object');
    }
    final result = await _client.rpc(
      'delete_recording_metadata',
      params: {
        'p_production_id': productionId,
        'p_line_id': lineId,
        'p_user_id': userId,
        'p_audio_url': audioUrl,
        'p_object_name': objectName,
      },
    );
    if (result is! Map || result['deleted'] is! bool) {
      throw StateError(
        'The recording deletion service returned an invalid response.',
      );
    }
    final deleted = result['deleted'] as bool;
    await flushRecordingCleanup(productionId: productionId, userId: userId);
    if (deleted) {
      _dlog.log(
        LogCategory.network,
        'Recording metadata and storage object deleted',
      );
    }
    return deleted;
  }

  /// Claim and drain cleanup work. Claiming first lets the database serialize
  /// object adoption against deletion and guarantees the canonical storage name
  /// was server-verified before the Storage API sees it.
  Future<void> flushRecordingCleanup({
    required String productionId,
    required String userId,
  }) async {
    final cleanup = await _client.rpc(
      'claim_recording_cleanup',
      params: {'p_production_id': productionId, 'p_requested_by': userId},
    );
    if (cleanup is! List) {
      throw StateError(
        'The recording service returned an invalid cleanup response.',
      );
    }
    for (final rawEntry in cleanup) {
      if (rawEntry is! Map ||
          rawEntry['id'] is! String ||
          rawEntry['object_name'] is! String) {
        throw StateError('The recording cleanup queue contains invalid data.');
      }
      await _client.storage.from('recordings').remove([
        rawEntry['object_name'] as String,
      ]);
      final acknowledged = await _client.rpc(
        'complete_recording_cleanup',
        params: {'p_cleanup_id': rawEntry['id']},
      );
      if (acknowledged != true) {
        throw StateError('Recording cleanup could not be acknowledged.');
      }
    }
  }

  Future<void> _flushRecordingCleanupDeferred({
    required String productionId,
    required String userId,
  }) async {
    try {
      await flushRecordingCleanup(productionId: productionId, userId: userId);
    } catch (_) {
      // The database outbox remains authoritative and will be claimed again on
      // the next sync. Do not block current metadata reads or a committed take.
      _dlog.log(
        LogCategory.network,
        'Recording object cleanup deferred for a later sync',
      );
    }
  }

  // ── Script Lines (cloud sync) ────────────────────────

  /// Fetch script lines for a production from the cloud.
  Future<List<Map<String, dynamic>>> fetchScriptLines(
    String productionId,
  ) async {
    return _client
        .from('script_lines')
        .select()
        .eq('production_id', productionId)
        .order('order_index', ascending: true);
  }

  /// Fetch cloud scene metadata (empty list for productions pushed before
  /// scenes synced — the caller falls back to tag-derived scenes).
  Future<List<Map<String, dynamic>>> fetchScriptScenes(
    String productionId,
  ) async {
    return _client
        .from('script_scenes')
        .select()
        .eq('production_id', productionId)
        .order('sort_order', ascending: true);
  }

  /// Atomically replace lines and scene metadata through one transactional RPC.
  /// The server validates the complete payload before touching the known-good
  /// revision and returns the committed counts for contract verification.
  Future<String> saveScript({
    required String productionId,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> scenes,
  }) async {
    final result = await _client.rpc(
      'replace_script',
      params: {
        'p_production_id': productionId,
        'p_lines': lines,
        'p_scenes': scenes,
      },
    );
    if (result is! Map ||
        result['revision'] is! String ||
        result['line_count'] != lines.length ||
        result['scene_count'] != scenes.length) {
      throw StateError('The script service returned an invalid commit result.');
    }
    return result['revision'] as String;
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
            _dlog.log(
              LogCategory.network,
              'Realtime INSERT: line=${payload.newRecord['line_id']}',
            );
            onNewRecording(payload.newRecord);
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'recordings',
          filter: filter,
          callback: (payload) {
            _dlog.log(
              LogCategory.network,
              'Realtime UPDATE (re-record): line=${payload.newRecord['line_id']}',
            );
            onNewRecording(payload.newRecord);
          },
        )
        // Log the channel lifecycle: if this never reaches "subscribed", live
        // sharing is down (realtime not enabled on the table, auth/RLS, or
        // network) — the single most useful signal when takes aren't arriving.
        .subscribe((status, error) {
          if (error != null) {
            _dlog.logError(
              LogCategory.network,
              'Realtime channel error for recordings:$productionId ($status)',
              error,
            );
          } else {
            _dlog.log(
              LogCategory.network,
              'Realtime channel status for recordings:$productionId → $status',
            );
          }
        });
  }

  /// Unsubscribe from a channel.
  Future<void> unsubscribe(RealtimeChannel channel) {
    return _client.removeChannel(channel);
  }
}
