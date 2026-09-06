import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/cast_member_model.dart';
import 'debug_log_service.dart';

enum CastMemberRemovalResult { removed, alreadyAbsent }

class CastPrimaryAlreadyAssignedException implements Exception {
  const CastPrimaryAlreadyAssignedException();

  @override
  String toString() => 'The character already has a primary actor invitation.';
}

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
  final Completer<bool> _initializationResult = Completer<bool>();
  Future<void>? _initialization;

  /// Resolves when the current initialization attempt finishes.
  ///
  /// A late success after the startup timeout resolves to `true`, allowing the
  /// app to restore a persisted session without polling. Fast failures resolve
  /// to `false`.
  Future<bool> get initializationResult => _initializationResult.future;

  /// Initialize Supabase. Call once at app startup.
  /// Pass url and publishableKey from environment config or
  /// compile-time constants.
  Future<void> init({
    required String url,
    required String publishableKey,
  }) async {
    if (_initialized) return;

    // Keep one underlying initialization attempt even after the startup wait
    // times out. Supabase initialization is not safe to start twice.
    final initFuture = _initialization ??= () async {
      try {
        await Supabase.initialize(url: url, publishableKey: publishableKey);
        _initialized = true;
        if (!_initializationResult.isCompleted) {
          _initializationResult.complete(true);
        }
      } catch (_) {
        if (!_initializationResult.isCompleted) {
          _initializationResult.complete(false);
        }
        rethrow;
      }
    }();

    try {
      await initFuture.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      // Do NOT mark initialized here: until Supabase.initialize actually
      // completes, Supabase.instance.client throws. The app watches
      // [initializationResult] so a restored session is picked up even when
      // initialization completes after this soft startup timeout.
      _dlog.log(
        LogCategory.network,
        'Supabase init slow (>5s) — starting offline; cloud features '
        'enable when it completes',
      );
      unawaited(
        initFuture
            .then<void>((_) {
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
      // A fast failure (malformed URL/key, DNS refusal) degrades to offline.
      _dlog.logError(
        LogCategory.network,
        'Supabase init failed — starting offline',
        e,
      );
    }
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

  /// Durably delete a production and every recording object beneath its
  /// storage prefix.
  ///
  /// `begin_production_deletion` first moves the production into immutable
  /// deleting state so no new recording metadata can be published. Storage is
  /// then removed recursively before `finalize_production_deletion` cascades
  /// metadata. A retry resumes the durable server-side deletion job.
  ///
  /// Returns `true` when this call finalizes deletion and `false` when a prior
  /// call already finalized it. Authorization and transport failures throw.
  Future<bool> deleteProductionEverywhere(String productionId) async {
    final beginResult = await _client.rpc(
      'begin_production_deletion',
      params: {'prod_id': productionId},
    );
    if (beginResult is! Map) {
      throw StateError(
        'begin_production_deletion returned an invalid response',
      );
    }
    final begin = Map<String, dynamic>.from(beginResult);
    final beginStatus = begin['status'];
    if (beginStatus == 'already_finalized') return false;
    if (beginStatus != 'started' && beginStatus != 'resumed') {
      throw StateError('begin_production_deletion returned an invalid status');
    }

    final storagePrefix = begin['storage_prefix'];
    if (storagePrefix != '$productionId/') {
      throw StateError(
        'begin_production_deletion returned an invalid storage prefix',
      );
    }

    // Finalization checks storage independently. Repeat cleanup if it observes
    // an object that arrived just before publication was blocked.
    for (var attempt = 0; attempt < 3; attempt++) {
      await _deleteRecordingStorageTree(
        storagePrefix.substring(0, storagePrefix.length - 1),
      );
      final finalizeResult = await _client.rpc(
        'finalize_production_deletion',
        params: {'prod_id': productionId},
      );
      if (finalizeResult is! Map) {
        throw StateError(
          'finalize_production_deletion returned an invalid response',
        );
      }
      final status = finalizeResult['status'];
      if (status == 'finalized') {
        _dlog.log(
          LogCategory.network,
          'Deleted production $productionId and its recording storage',
        );
        return true;
      }
      if (status == 'already_finalized') return false;
      if (status != 'storage_not_empty') {
        throw StateError(
          'finalize_production_deletion returned an invalid status',
        );
      }
    }
    throw StateError(
      'Recording storage remained non-empty after deletion retries.',
    );
  }

  Future<void> _deleteRecordingStorageTree(String directory) async {
    final bucket = _client.storage.from('recordings');
    while (true) {
      final entries = await bucket.list(
        path: directory,
        searchOptions: const SearchOptions(limit: 100, offset: 0),
      );
      if (entries.isEmpty) return;

      final files = <String>[];
      for (final entry in entries) {
        final childPath = '$directory/${entry.name}';
        if (entry.id == null) {
          await _deleteRecordingStorageTree(childPath);
        } else {
          files.add(childPath);
        }
      }
      if (files.isNotEmpty) {
        final removed = await bucket.remove(files);
        if (removed.isEmpty) {
          throw StateError(
            'Recording storage deletion made no progress under $directory.',
          );
        }
      }
    }
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
    String productionId, {
    String? joinCode,
  }) async {
    // Pre-join callers are authorized by the code; members are authorized by
    // their authenticated membership. The RPC deliberately omits user_id and
    // exposes only a claimed flag to unauthenticated/non-member callers.
    final rpcResult = await _client.rpc(
      'fetch_cast_for_join',
      params: {'prod_id': productionId, 'code': joinCode ?? ''},
    );
    if (rpcResult is! List) {
      throw StateError('fetch_cast_for_join returned an invalid response');
    }
    return rpcResult
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  Future<void> addCastMember({
    required String productionId,
    required String userId,
    required String role,
    String? characterName,
  }) async {
    final result = await _createCastMember(
      productionId: productionId,
      characterName: characterName ?? '',
      displayName: '',
      role: role,
      userId: userId,
    );
    switch (result['status']) {
      case 'created':
      case 'already_member':
        return;
      case 'already_assigned':
        throw const CastPrimaryAlreadyAssignedException();
      default:
        throw StateError('create_cast_member returned an invalid status');
    }
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
    final result = await _createCastMember(
      productionId: productionId,
      characterName: characterName,
      displayName: displayName,
      role: role,
      contactInfo: contactInfo,
      memberId: id,
    );
    switch (result['status']) {
      case 'created':
        final member = result['member'];
        if (member is! Map) {
          throw StateError('create_cast_member returned no created member');
        }
        return Map<String, dynamic>.from(member);
      case 'already_exists':
        final existing = result['member'];
        if (id == null || existing is! Map) {
          throw StateError('create_cast_member returned an invalid retry');
        }
        return Map<String, dynamic>.from(existing);
      case 'already_assigned':
        throw const CastPrimaryAlreadyAssignedException();
      case 'already_member':
        throw StateError('The assigned user is already a production member.');
      default:
        throw StateError('create_cast_member returned an invalid status');
    }
  }

  Future<Map<String, dynamic>> _createCastMember({
    required String productionId,
    required String characterName,
    required String displayName,
    required String role,
    String? contactInfo,
    String? userId,
    String? memberId,
    DateTime? invitedAt,
    DateTime? joinedAt,
  }) async {
    final result = await _client.rpc(
      'create_cast_member',
      params: {
        'prod_id': productionId,
        'char_name': characterName,
        'new_display_name': displayName,
        'member_role': role,
        'contact_info': contactInfo,
        'assigned_user_id': userId,
        'member_id': memberId,
        'invited_at_value': invitedAt?.toUtc().toIso8601String(),
        'joined_at_value': joinedAt?.toUtc().toIso8601String(),
      },
    );
    if (result is! Map) {
      throw StateError('create_cast_member returned an invalid response');
    }
    return Map<String, dynamic>.from(result);
  }

  /// Recreate an exact cast row as compensation after a later operation fails.
  ///
  /// Creation remains organizer-authorized and RPC-only. An idempotent retry
  /// succeeds only when the row with the original id still matches the
  /// snapshot; a conflicting assignment is never mistaken for restoration.
  Future<void> restoreCastMember(CastMemberModel member) async {
    final result = await _createCastMember(
      productionId: member.productionId,
      characterName: member.characterName,
      displayName: member.displayName,
      role: member.role.toSupabaseString(),
      contactInfo: member.contactInfo,
      userId: member.userId,
      memberId: member.id,
      invitedAt: member.invitedAt,
      joinedAt: member.joinedAt,
    );
    switch (result['status']) {
      case 'created':
        return;
      case 'already_assigned':
      case 'already_member':
      case 'already_exists':
        final existing = result['member'];
        if (existing is Map &&
            _matchesCastSnapshot(Map<String, dynamic>.from(existing), member)) {
          return;
        }
        throw StateError(
          'Cast compensation conflicted with a different cloud assignment.',
        );
      default:
        throw StateError('create_cast_member returned an invalid status');
    }
  }

  static bool _matchesCastSnapshot(
    Map<String, dynamic> row,
    CastMemberModel member,
  ) {
    return row['id'] == member.id &&
        row['production_id'] == member.productionId &&
        row['user_id'] == member.userId &&
        row['character_name'] == member.characterName &&
        row['display_name'] == member.displayName &&
        row['contact_info'] == member.contactInfo &&
        row['role'] == member.role.toSupabaseString() &&
        _sameTimestamp(row['invited_at'], member.invitedAt) &&
        _sameTimestamp(row['joined_at'], member.joinedAt);
  }

  static bool _sameTimestamp(Object? value, DateTime? expected) {
    if (expected == null) return value == null;
    if (value is! String) return false;
    return DateTime.tryParse(value)?.toUtc() == expected.toUtc();
  }

  /// Remove a cast member for everyone (organizer-side unassign).
  ///
  /// An already-absent cloud row is a successful idempotent outcome, distinct
  /// from authorization and transport failures, which the RPC raises.
  Future<CastMemberRemovalResult> removeCastMember({
    required String castMemberId,
    required String productionId,
  }) async {
    final result = await _client.rpc(
      'remove_cast_member',
      params: {'member_id': castMemberId, 'prod_id': productionId},
    );
    final outcome = switch (result) {
      'removed' => CastMemberRemovalResult.removed,
      'already_absent' => CastMemberRemovalResult.alreadyAbsent,
      _ => throw StateError('remove_cast_member returned an invalid response'),
    };
    _dlog.log(
      LogCategory.network,
      outcome == CastMemberRemovalResult.removed
          ? 'Removed cast member $castMemberId from the cloud'
          : 'Cast member $castMemberId was already absent from the cloud',
    );
    return outcome;
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
        'Cloud rename updated no rows for cast member $castMemberId.',
      );
    }
    _dlog.log(
      LogCategory.network,
      'Renamed cast member $castMemberId → "$characterName"',
    );
  }

  /// Claim an existing invitation for the authenticated user.
  Future<void> claimInvitation({
    required String castMemberId,
    required String userId,
    required String joinCode,
    required String displayName,
  }) async {
    try {
      final result = await _client.rpc(
        'claim_cast_invitation',
        params: {
          'member_id': castMemberId,
          'code': joinCode,
          'new_display_name': displayName,
        },
      );
      if (result is! Map) {
        throw StateError('claim_cast_invitation returned an invalid response');
      }
      final claimed = Map<String, dynamic>.from(result);
      if (claimed['user_id'] != userId) {
        throw StateError('This role could not be claimed by the current user.');
      }
      _dlog.log(
        LogCategory.network,
        'Join: claimed invitation $castMemberId via RPC',
      );
    } catch (e) {
      _dlog.logError(
        LogCategory.network,
        'Join: claim failed for invitation $castMemberId',
        e,
      );
      rethrow;
    }
  }

  /// Self-join a production (create or return the authenticated user's row).
  Future<Map<String, dynamic>> selfJoinProduction({
    required String productionId,
    required String userId,
    required String characterName,
    required String displayName,
    required String joinCode,
  }) async {
    try {
      // The RPC verifies the join code, derives user_id from auth.uid(), forces
      // role='actor', and returns the existing row on an idempotent retry.
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
        throw StateError('join_production returned an invalid response');
      }
      final joined = Map<String, dynamic>.from(result);
      if (joined['user_id'] != userId) {
        throw StateError('join_production returned a row for another user');
      }
      _dlog.log(
        LogCategory.network,
        'Join: self-joined "$characterName" via RPC',
      );
      return joined;
    } catch (e) {
      _dlog.logError(
        LogCategory.network,
        'Join: self-join failed for "$characterName"',
        e,
      );
      rethrow;
    }
  }

  /// Look up a production by its join code.
  ///
  /// The security-definer RPC returns only the public pre-join fields. Fetch
  /// the full production with [fetchProduction] after membership is created.
  Future<Map<String, dynamic>?> lookupByJoinCode(String code) async {
    final dlog = DebugLogService.instance;
    dlog.log(
      LogCategory.network,
      'Join lookup started: initialized=$_initialized, signedIn=$isSignedIn',
    );

    try {
      final rpcResult = await _client.rpc(
        'lookup_production_by_join_code',
        params: {'lookup_code': code.toUpperCase()},
      );
      if (rpcResult == null) return null;
      if (rpcResult is! Map) {
        throw StateError(
          'lookup_production_by_join_code returned an invalid response',
        );
      }
      final production = Map<String, dynamic>.from(rpcResult);
      dlog.log(
        LogCategory.network,
        'Join lookup succeeded for production ${production['id']}',
      );
      return production;
    } catch (e) {
      dlog.logError(LogCategory.network, 'Join lookup failed', e);
      rethrow;
    }
  }

  /// Fetch a full production row after the current user has joined it.
  Future<Map<String, dynamic>> fetchProduction(String productionId) async {
    if (currentUser == null) throw StateError('Not signed in');
    return _client.from('productions').select().eq('id', productionId).single();
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
    _dlog.log(
      LogCategory.network,
      'Storage upload → recordings/$path (${sizeKb}KB)',
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
      _dlog.logError(
        LogCategory.network,
        'Storage upload FAILED → recordings/$path',
        e,
      );
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
        'Storage download ← recordings/$objectPath (${(bytes.length / 1024).toStringAsFixed(0)}KB)',
      );
      return bytes;
    } catch (e) {
      _dlog.logError(
        LogCategory.network,
        'Storage download FAILED ← recordings/$objectPath',
        e,
      );
      rethrow;
    }
  }

  /// Delete the storage object identified by a recording's persisted URL.
  ///
  /// Call only after metadata deletion/replacement commits and the URL is
  /// durably queued, so a storage or process failure remains retryable.
  Future<void> deleteRecordingByUrl(String audioUrl) async {
    final objectPath = _objectPathFromUrl(audioUrl);
    if (objectPath == null) {
      throw ArgumentError(
        'Could not parse a recordings object path from audioUrl',
      );
    }
    await _client.storage.from('recordings').remove([objectPath]);
    _dlog.log(LogCategory.network, 'Storage delete → recordings/$objectPath');
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
    String productionId,
  ) async {
    // Supabase projects commonly cap a response at 1,000 rows. Page with a
    // deterministic order so mature ensemble productions cannot silently lose
    // later rows at the server cap.
    const pageSize = 500;
    final all = <Map<String, dynamic>>[];
    for (var offset = 0; ; offset += pageSize) {
      final page = await _client
          .from('recordings')
          .select('line_id, user_id, audio_url, duration_ms, recorded_at')
          .eq('production_id', productionId)
          .order('line_id')
          .order('user_id')
          .range(offset, offset + pageSize - 1);
      all.addAll(page);
      if (page.length < pageSize) return all;
    }
  }

  /// Atomically save recording metadata and return the superseded audio URL.
  ///
  /// The RPC derives user identity from the authenticated session and locks
  /// this production/line/user tuple, so concurrent devices cannot race the
  /// previous-URL handoff. Callers durably enqueue deletion only after this
  /// commit succeeds.
  Future<String?> saveRecordingMetadata({
    required String productionId,
    required String lineId,
    required String audioUrl,
    required int durationMs,
    DateTime? recordedAt,
  }) async {
    try {
      final result = await _client.rpc(
        'save_recording_metadata',
        params: {
          'prod_id': productionId,
          'line_id': lineId,
          'audio_url': audioUrl,
          'duration_ms': durationMs,
          'recorded_at': (recordedAt ?? DateTime.now())
              .toUtc()
              .toIso8601String(),
        },
      );
      if (result is! Map || result['recording'] is! Map) {
        throw StateError(
          'save_recording_metadata returned an invalid response',
        );
      }
      final previousUrl = result['previous_audio_url'];
      if (previousUrl != null && previousUrl is! String) {
        throw StateError(
          'save_recording_metadata returned an invalid previous audio URL',
        );
      }
      _dlog.log(LogCategory.network, 'Recording metadata saved: line=$lineId');
      return previousUrl == audioUrl ? null : previousUrl as String?;
    } catch (e) {
      _dlog.logError(
        LogCategory.network,
        'Recording metadata save FAILED: line=$lineId '
        '(castmates will not see this recording)',
        e,
      );
      rethrow;
    }
  }

  /// Delete the authenticated user's recording metadata and return its object
  /// URL for durable, deferred storage cleanup.
  ///
  /// Returns null when the row is already absent. Authentication and transport
  /// failures throw; storage is intentionally untouched by this transaction.
  Future<String?> deleteRecordingMetadata({
    required String productionId,
    required String lineId,
  }) async {
    final result = await _client.rpc(
      'delete_recording_metadata',
      params: {'prod_id': productionId, 'line_id': lineId},
    );
    if (result is! Map) {
      throw StateError(
        'delete_recording_metadata returned an invalid response',
      );
    }
    switch (result['status']) {
      case 'deleted':
        final audioUrl = result['audio_url'];
        if (audioUrl is! String || audioUrl.isEmpty) {
          throw StateError(
            'delete_recording_metadata returned no deleted audio URL',
          );
        }
        return audioUrl;
      case 'already_absent':
        return null;
      default:
        throw StateError(
          'delete_recording_metadata returned an invalid status',
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

  /// Replace the cloud scene metadata for a production. Scene rows are tiny
  /// (tens per play), so a single delete + insert is fine.
  Future<void> saveScriptScenes({
    required String productionId,
    required List<Map<String, dynamic>> scenes,
  }) async {
    await _client
        .from('script_scenes')
        .delete()
        .eq('production_id', productionId);
    if (scenes.isNotEmpty) {
      await _client.from('script_scenes').insert(scenes);
    }
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

    // Insert in batches, a few in flight at a time. Serial 100-row batches
    // made a 4000-line play ~40 sequential round-trips (several seconds on
    // cellular); bounded concurrency keeps payloads modest without turning
    // a flaky connection into 40 parallel failures. Row order doesn't
    // matter — every row carries order_index.
    const batchSize = 200;
    const maxInFlight = 4;
    final batches = <List<Map<String, dynamic>>>[
      for (var i = 0; i < lines.length; i += batchSize)
        lines.sublist(
          i,
          i + batchSize > lines.length ? lines.length : i + batchSize,
        ),
    ];
    for (var i = 0; i < batches.length; i += maxInFlight) {
      final window = batches.sublist(
        i,
        i + maxInFlight > batches.length ? batches.length : i + maxInFlight,
      );
      await Future.wait(
        window.map((b) => _client.from('script_lines').insert(b)),
      );
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
