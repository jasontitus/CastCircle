import 'dart:async';
import 'dart:isolate';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart' show SnackBar, Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../data/services/debug_log_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../data/database/app_database.dart'
    show PendingCastInvitationRow, ProductionCloudCreateRow;
import '../data/models/cast_member_model.dart';
import '../data/models/production_models.dart';
import '../data/models/script_models.dart';
import '../data/repositories/production_repository.dart';
import '../data/services/deep_link_service.dart';
import '../data/services/demo_production_service.dart';
import '../data/services/script_import_service.dart';
import '../data/services/script_parser.dart';
import '../data/services/voice_config_service.dart';
import '../data/services/analytics_service.dart';
import '../data/services/perf_service.dart';
import '../data/services/supabase_service.dart';
import '../data/services/recording_sync_service.dart';
import '../data/services/sync_queue.dart';
import '../main.dart';
import '../core/toast.dart';

/// Maximum size (in bytes) for a SharedPreferences script backup.
const _maxBackupBytes = 5 * 1024 * 1024; // 5 MB

/// Pending join data from a deep link. Consumed by the join screen.
final pendingJoinProvider = StateProvider<PendingJoin?>((ref) => null);

/// Provider for the character the user is rehearsing as.
final rehearsalCharacterProvider = StateProvider<String?>((ref) => null);

/// Provider for the selected scene to rehearse.
final selectedSceneProvider = StateProvider<ScriptScene?>((ref) => null);

/// Rehearsal mode: full scene readthrough vs cue-response practice vs full readthrough.
enum RehearsalMode { sceneReadthrough, cuePractice, readthrough }

final rehearsalModeProvider = StateProvider<RehearsalMode>(
  (ref) => RehearsalMode.sceneReadthrough,
);

/// When true, the actor's upcoming lines are hidden (blind rehearsal).
final hideMyLinesProvider = StateProvider<bool>((ref) => false);

/// The account namespace every local query is scoped to: the signed-in user
/// id, or '__guest__' when signed out. Guest rows are claimed into the user's
/// namespace by [setAccountIdentity] on sign-in.
final activeAccountNamespaceProvider = StateProvider<String>(
  (ref) => guestAccountNamespace,
);

int _identityGeneration = 0;

/// Rebind every repository query to [userId]'s account namespace.
///
/// Publishes the namespace FIRST so any production the user creates from here
/// on is attributed to them, then claims guest-namespace rows a prior guest
/// session (or the sign-in transition) left behind — organizer rows, joined
/// rows, and rows created signed-out (organizer_id='local'). The claim is
/// unconditional: a once-per-user gate left those rows permanently invisible.
Future<void> setAccountIdentity(WidgetRef ref, String? userId) async {
  final generation = ++_identityGeneration;
  final namespace = userId == null || userId.isEmpty
      ? guestAccountNamespace
      : userId;
  final notifier = ref.read(activeAccountNamespaceProvider.notifier);
  if (namespace == guestAccountNamespace) {
    if (generation == _identityGeneration && notifier.state != namespace) {
      notifier.state = namespace;
    }
    return;
  }

  final database = ref.read(databaseProvider);
  if (generation == _identityGeneration && notifier.state != namespace) {
    notifier.state = namespace;
  }
  if (generation != _identityGeneration) return;
  await database.claimLegacyProductions(namespace);
}

/// Repository provider — bridges Drift DB with domain models.
final productionRepositoryProvider = Provider<ProductionRepository>((ref) {
  final db = ref.read(databaseProvider);
  final accountNamespace = ref.watch(activeAccountNamespaceProvider);
  return ProductionRepository(db, accountNamespace: accountNamespace);
});
final connectivityChangesProvider = Provider<Stream<List<ConnectivityResult>>>(
  (ref) => Connectivity().onConnectivityChanged,
);

final productionCloudCreationProvider =
    StateNotifierProvider<
      ProductionCloudCreationNotifier,
      Map<String, ProductionCloudCreateRow>
    >(
      (ref) => ProductionCloudCreationNotifier(
        ref.read(productionRepositoryProvider),
        ref.read(connectivityChangesProvider),
      ),
    );

/// The list of productions the user has.
final productionsProvider =
    StateNotifierProvider<ProductionsNotifier, List<Production>>((ref) {
      final repo = ref.read(productionRepositoryProvider);
      final cloudCreates = ref.read(productionCloudCreationProvider.notifier);
      return ProductionsNotifier(repo, cloudCreates);
    });

class ProductionsNotifier extends StateNotifier<List<Production>> {
  final ProductionRepository _repo;
  final ProductionCloudCreationNotifier _cloudCreates;

  ProductionsNotifier(this._repo, this._cloudCreates) : super([]) {
    _cloudCreates.onProductionDeleted = (id) {
      state = state.where((production) => production.id != id).toList();
    };
    _load();
  }

  Future<void> _load() async {
    state = await _repo.getAllProductions();
  }

  /// Save [productions] to Drift and reload once. Used by the cloud restore.
  Future<void> addAll(List<Production> productions) async {
    for (final production in productions) {
      await _repo.saveProduction(production);
    }
    state = await _repo.getAllProductions();
  }

  Future<void> add(Production production) async {
    final dlog = DebugLogService.instance;
    dlog.log(
      LogCategory.general,
      'ProductionsNotifier.add: saving local production; '
      'current_count=${state.length}',
    );
    await _repo.saveProduction(production);
    // Reload from DB to guarantee no duplicates (DB uses insertOrReplace).
    state = await _repo.getAllProductions();
    dlog.log(
      LogCategory.general,
      'ProductionsNotifier.add: after reload, state has ${state.length} items',
    );
  }

  /// Atomically save the optimistic local row and its durable cloud outbox
  /// entry before returning control to the UI.
  Future<void> addPendingCloudCreation(Production production) async {
    await _repo.saveProductionPendingCloudCreate(production);
    state = await _repo.getAllProductions();
    await _cloudCreates.reload();
    unawaited(_cloudCreates.retry(production.id));
  }

  Future<void> update(Production production) async {
    await _repo.saveProduction(production);
    state = [
      for (final p in state)
        if (p.id == production.id) production else p,
    ];
  }

  /// Must complete before the caller deletes the cloud row. It blocks new
  /// create retries and joins any create already in flight.
  Future<void> prepareForDeletion(String id) => _cloudCreates.beginDeletion(id);

  Future<void> cancelPreparedDeletion(String id) =>
      _cloudCreates.cancelDeletion(id);

  /// Call immediately after the cloud delete commits, before fallible local
  /// cleanup, so an app restart cannot replay the create outbox.
  Future<void> cloudDeletionCommitted(String id) =>
      _cloudCreates.cloudDeletionCommitted(id);

  Future<void> remove(String id) async {
    await _cloudCreates.beginDeletion(id);
    await _repo.deleteProduction(id);
    _cloudCreates.completeDeletion(id);
    state = state.where((p) => p.id != id).toList();
  }

  /// Wipe the in-memory list without touching persisted rows (sign-out).
  void clear() {
    state = const [];
  }
}

class ProductionCloudCreationNotifier
    extends StateNotifier<Map<String, ProductionCloudCreateRow>> {
  ProductionCloudCreationNotifier(this._repo, this._connectivityChanges)
    : super({}) {
    unawaited(_initialize());
  }

  final ProductionRepository _repo;
  final Stream<List<ConnectivityResult>> _connectivityChanges;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _retrying = false;
  final Map<String, Future<bool>> _inFlight = {};
  final Set<String> _deleting = {};
  void Function(String productionId)? onProductionDeleted;

  Future<void> _initialize() async {
    await reload();
    await retryAll();
    _connectivitySubscription = _connectivityChanges.listen((results) {
      if (results.any((result) => result != ConnectivityResult.none)) {
        unawaited(retryAll());
      }
    });
  }

  Future<void> reload() async {
    final rows = await _repo.getProductionCloudCreates();
    state = {for (final row in rows) row.productionId: row};
  }

  Future<void> retryAll() async {
    if (_retrying || !SupabaseService.instance.isSignedIn) return;
    _retrying = true;
    try {
      for (final productionId in state.keys.toList()) {
        final row = state[productionId];
        if (row?.status == 'deleting') {
          if (!_deleting.contains(productionId)) {
            await _resumeDeletion(productionId);
          }
        } else {
          await retry(productionId);
        }
      }
    } finally {
      _retrying = false;
    }
  }

  Future<void> _resumeDeletion(String productionId) async {
    try {
      await SupabaseService.instance.deleteProductionEverywhere(productionId);
      await _repo.deleteProduction(productionId);
      state = Map.from(state)..remove(productionId);
      onProductionDeleted?.call(productionId);
    } catch (error) {
      DebugLogService.instance.logError(
        LogCategory.network,
        'Pending production deletion will retry',
        error,
      );
    }
  }

  /// Returns true only after the server confirms the original id and join code.
  Future<bool> retry(String productionId) {
    if (_deleting.contains(productionId)) return Future.value(false);
    final active = _inFlight[productionId];
    if (active != null) return active;
    final retry = _retry(productionId);
    _inFlight[productionId] = retry;
    return retry.whenComplete(() {
      if (identical(_inFlight[productionId], retry)) {
        _inFlight.remove(productionId);
      }
    });
  }

  Future<void> beginDeletion(String productionId) async {
    _deleting.add(productionId);
    try {
      final active = _inFlight[productionId];
      if (active != null) await active;
      await _repo.markProductionCloudDeletionPending(productionId);
      await reload();
    } catch (_) {
      _deleting.remove(productionId);
      rethrow;
    }
  }

  Future<void> cloudDeletionCommitted(String productionId) async {
    await _repo.cancelProductionCloudCreate(productionId);
    if (state.containsKey(productionId)) {
      state = Map.from(state)..remove(productionId);
    }
  }

  void completeDeletion(String productionId) {
    _deleting.remove(productionId);
    if (state.containsKey(productionId)) {
      state = Map.from(state)..remove(productionId);
    }
  }

  Future<void> cancelDeletion(String productionId) async {
    if (!_deleting.remove(productionId)) return;
    await _repo.resumeProductionCloudCreate(productionId);
    await reload();
    if (state.containsKey(productionId)) {
      unawaited(retry(productionId));
    }
  }

  Future<bool> _retry(String productionId) async {
    if (_deleting.contains(productionId)) return false;
    if (!state.containsKey(productionId)) return true;
    if (state[productionId]?.status == 'deleting') return false;
    if (!SupabaseService.instance.isSignedIn) return false;
    final production = await _repo.getProduction(productionId);
    if (production == null) return false;
    try {
      final confirmed = await SupabaseService.instance.createProduction(
        title: production.title,
        id: production.id,
        joinCode: production.joinCode,
      );
      if (confirmed['id'] != production.id ||
          confirmed['join_code'] != production.joinCode) {
        throw StateError(
          'Cloud create confirmed different production identity/code',
        );
      }
      await _repo.markProductionCloudCreateSynced(productionId);
      state = Map.from(state)..remove(productionId);
      return true;
    } catch (error) {
      await _repo.markProductionCloudCreateFailed(productionId, error);
      await reload();
      DebugLogService.instance.logError(
        LogCategory.network,
        'Cloud production create remains pending',
        error,
      );
      return false;
    }
  }

  @override
  void dispose() {
    final subscription = _connectivitySubscription;
    if (subscription != null) unawaited(subscription.cancel());
    super.dispose();
  }
}

/// Currently selected production.
final currentProductionProvider = StateProvider<Production?>((ref) => null);

/// Parsed script for the current production.
final currentScriptProvider = StateProvider<ParsedScript?>((ref) => null);

/// Script import service.
final scriptImportServiceProvider = Provider<ScriptImportService>((ref) {
  return ScriptImportService();
});

/// All recordings for the current production, keyed by script line ID.
final recordingsProvider =
    StateNotifierProvider<RecordingsNotifier, Map<String, Recording>>((ref) {
      final repo = ref.read(productionRepositoryProvider);
      return RecordingsNotifier(repo);
    });

class RecordingsNotifier extends StateNotifier<Map<String, Recording>> {
  final ProductionRepository _repo;
  String? _productionId;

  RecordingsNotifier(this._repo) : super({});

  /// Load recordings for a given production from the database.
  Future<void> loadForProduction(String productionId) async {
    _productionId = productionId;
    state = await _repo.getRecordings(productionId);
  }

  Future<void> add(Recording recording) async {
    if (_productionId != null) {
      await _repo.saveRecording(_productionId!, recording);
    }
    state = {...state, recording.scriptLineId: recording};
  }

  Future<void> remove(String scriptLineId) async {
    final recording = state[scriptLineId];
    // State first, synchronously: the recordings browser calls this from
    // Dismissible.onDismissed, and the row must leave the tree this frame
    // or Flutter throws "A dismissed Dismissible widget is still part of
    // the tree". The DB row follows; if that fails the row simply
    // reappears on the next load instead of dangling file-less.
    state = Map.from(state)..remove(scriptLineId);
    if (recording != null) {
      await _repo.deleteRecording(recording.id);
    }
  }

  /// Load recordings from a pre-built map (e.g. from recording sync cache).
  void loadFromMap(Map<String, Recording> recordings) {
    state = {...state, ...recordings};
  }

  /// Persist the remote URL after a successful cloud upload. Queue uploads
  /// carry the immutable recording id; [expectedRecordedAt] supports queues
  /// persisted by older app versions before that id was serialized.
  Future<void> markUploaded(
    String productionId,
    String scriptLineId,
    String remoteUrl, {
    String? expectedRecordingId,
    DateTime? expectedRecordedAt,
  }) async {
    final changed = await _repo.markRecordingUploaded(
      productionId,
      scriptLineId,
      remoteUrl,
      expectedRecordingId: expectedRecordingId,
      expectedRecordedAt: expectedRecordedAt,
    );
    if (!changed) return;
    final existing = state[scriptLineId];
    final identityMatches = expectedRecordingId != null
        ? existing?.id == expectedRecordingId
        : expectedRecordedAt == null ||
              existing?.recordedAt == expectedRecordedAt;
    if (existing != null && _productionId == productionId && identityMatches) {
      state = {...state, scriptLineId: existing.copyWith(remoteUrl: remoteUrl)};
    }
  }

  void clear() {
    _productionId = null;
    state = {};
  }
}

/// Understudy recordings for the current production, keyed by script line ID.
/// These are recordings made by understudies and can be used as fallback
/// when the primary actor hasn't recorded a line.
final understudyRecordingsProvider =
    StateNotifierProvider<RecordingsNotifier, Map<String, Recording>>((ref) {
      final repo = ref.read(productionRepositoryProvider);
      return RecordingsNotifier(repo);
    });

/// Character being recorded in the recording studio.
final recordingCharacterProvider = StateProvider<String?>((ref) => null);

final pendingCastInvitationProvider =
    StateNotifierProvider<
      PendingCastInvitationNotifier,
      List<PendingCastInvitationRow>
    >(
      (ref) => PendingCastInvitationNotifier(
        ref.read(productionRepositoryProvider),
        ref.read(connectivityChangesProvider),
      ),
    );

/// Cast members for the current production, backed by Drift + Supabase sync.
final castMembersProvider =
    StateNotifierProvider<CastMembersNotifier, List<CastMemberModel>>((ref) {
      final repo = ref.read(productionRepositoryProvider);
      final pending = ref.read(pendingCastInvitationProvider.notifier);
      return CastMembersNotifier(repo, pending);
    });

class CastMembersNotifier extends StateNotifier<List<CastMemberModel>> {
  final ProductionRepository _repo;
  final PendingCastInvitationNotifier _pendingInvitations;
  String? _productionId;

  CastMembersNotifier(this._repo, this._pendingInvitations) : super([]);

  /// Load cast members from Drift for the given production.
  Future<void> loadForProduction(String productionId) async {
    _productionId = productionId;
    state = await _repo.getCastMembers(productionId);
  }

  /// Add or update a cast member in Drift and state.
  Future<void> save(CastMemberModel member) async {
    await _repo.saveCastMember(member);
    final idx = state.indexWhere((m) => m.id == member.id);
    if (idx >= 0) {
      state = [
        for (int i = 0; i < state.length; i++)
          if (i == idx) member else state[i],
      ];
    } else {
      state = [...state, member];
    }
  }

  /// Save a bulk setup as one transaction and emit one state change. Each
  /// member remains backed by an inspectable invitation outbox row until the
  /// cloud returns its canonical id.
  Future<void> savePendingInvitations(List<CastMemberModel> members) async {
    if (members.isEmpty) return;
    final productionIds = members.map((member) => member.productionId).toSet();
    if (productionIds.length != 1) {
      throw ArgumentError('Bulk invitations must belong to one production');
    }
    final productionId = productionIds.single;
    if (_productionId != null && _productionId != productionId) {
      throw StateError('Cast notifier is loaded for another production');
    }
    _productionId = productionId;
    await _repo.savePendingCastInvitations(members);
    final byId = {for (final member in state) member.id: member};
    for (final member in members) {
      byId[member.id] = member;
    }
    state = byId.values.toList();
    await _pendingInvitations.reload();
    unawaited(_pendingInvitations.retryAll());
  }

  Future<List<PendingCastInvitationRow>> pendingInvitations() =>
      _productionId == null
      ? Future.value(const [])
      : _repo.getPendingCastInvitations(productionId: _productionId);

  Future<void> markInvitationFailed(String localMemberId, Object error) =>
      _repo.markCastInvitationFailed(localMemberId, error);

  Future<void> reconcileInvitation(
    String localMemberId,
    CastMemberModel cloudMember,
  ) => reconcileInvitations([
    (localMemberId: localMemberId, cloudMember: cloudMember),
  ]);

  Future<void> reconcileInvitations(
    List<({String localMemberId, CastMemberModel cloudMember})> reconciliations,
  ) async {
    if (reconciliations.isEmpty) return;
    await _repo.reconcileCastInvitations(reconciliations);
    final replacedIds = {
      for (final item in reconciliations) item.localMemberId,
    };
    state = [
      for (final member in state)
        if (!replacedIds.contains(member.id)) member,
      for (final item in reconciliations) item.cloudMember,
    ];
  }

  /// Remove a cast member.
  Future<void> remove(String id) async {
    await _repo.deleteCastMember(id);
    state = state.where((m) => m.id != id).toList();
  }

  /// Get the primary actor for a character.
  CastMemberModel? primaryFor(String characterName) {
    try {
      return state.firstWhere(
        (m) => m.characterName == characterName && m.role == CastRole.primary,
      );
    } catch (_) {
      return null;
    }
  }

  /// Get the understudy for a character.
  CastMemberModel? understudyFor(String characterName) {
    try {
      return state.firstWhere(
        (m) =>
            m.characterName == characterName && m.role == CastRole.understudy,
      );
    } catch (_) {
      return null;
    }
  }

  void clear() {
    _productionId = null;
    state = [];
  }
}

typedef PendingInvitationSender =
    Future<({String localMemberId, CastMemberModel cloudMember})?> Function(
      PendingCastInvitationRow invitation,
    );

class PendingCastInvitationNotifier
    extends StateNotifier<List<PendingCastInvitationRow>> {
  PendingCastInvitationNotifier(
    this._repo,
    this._connectivityChanges, {
    PendingInvitationSender? sendInvitation,
    bool Function()? isSignedIn,
  }) : _sendInvitation = sendInvitation,
       _isSignedIn = isSignedIn,
       super([]) {
    unawaited(_initialize());
  }

  final ProductionRepository _repo;
  final Stream<List<ConnectivityResult>> _connectivityChanges;
  final PendingInvitationSender? _sendInvitation;
  final bool Function()? _isSignedIn;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Future<void>? _retryFuture;
  bool _retryRequested = false;
  Future<void> _initialize() async {
    await reload();
    await retryAll();
    _connectivitySubscription = _connectivityChanges.listen((results) {
      if (results.any((result) => result != ConnectivityResult.none)) {
        unawaited(retryAll());
      }
    });
  }

  Future<void> reload() async {
    state = await _repo.getPendingCastInvitations();
  }

  Future<void> retryAll() {
    final active = _retryFuture;
    if (active != null) {
      _retryRequested = true;
      return active;
    }
    if (state.isEmpty || !_signedIn) return Future.value();

    _retryRequested = true;
    final drain = _drainRetryRequests();
    late final Future<void> owner;
    owner = drain.whenComplete(() async {
      // A caller can arrive after [drain] completes but before this completion
      // listener runs. Drain that tail request before releasing ownership.
      while (_retryRequested) {
        await _drainRetryRequests();
      }
      if (identical(_retryFuture, owner)) _retryFuture = null;
    });
    _retryFuture = owner;
    return owner;
  }

  bool get _signedIn =>
      _isSignedIn?.call() ?? SupabaseService.instance.isSignedIn;

  Future<void> _drainRetryRequests() async {
    while (_retryRequested) {
      _retryRequested = false;
      if (state.isEmpty || !_signedIn) return;
      await _retryAllPending();
    }
  }

  Future<void> _retryAllPending() async {
    final successes = <({String localMemberId, CastMemberModel cloudMember})>[];
    for (var offset = 0; offset < state.length; offset += 4) {
      final candidateEnd = offset + 4;
      final end = candidateEnd < state.length ? candidateEnd : state.length;
      final batch = state.sublist(offset, end);
      final results = await Future.wait([
        for (final invitation in batch)
          _sendInvitation?.call(invitation) ?? _send(invitation),
      ]);
      for (final result in results) {
        if (result != null) successes.add(result);
      }
    }
    if (successes.isNotEmpty) {
      await _repo.reconcileCastInvitations(successes);
    }
    await reload();
  }

  Future<bool> retry(String localMemberId) async {
    final active = _retryFuture;
    if (active != null) {
      await active;
      return !state.any((row) => row.localMemberId == localMemberId);
    }
    final matches = state
        .where((row) => row.localMemberId == localMemberId)
        .toList();
    if (matches.isEmpty || !_signedIn) return false;
    final result =
        await (_sendInvitation?.call(matches.single) ?? _send(matches.single));
    if (result == null) {
      await reload();
      return false;
    }
    await _repo.reconcileCastInvitations([result]);
    await reload();
    return true;
  }

  Future<({String localMemberId, CastMemberModel cloudMember})?> _send(
    PendingCastInvitationRow invitation,
  ) async {
    try {
      final role = CastRole.values.byName(invitation.role);
      final row = await SupabaseService.instance.createCastInvitation(
        productionId: invitation.productionId,
        characterName: invitation.characterName,
        displayName: invitation.displayName,
        contactInfo: invitation.contactInfo,
        role: role.toSupabaseString(),
        id: invitation.localMemberId,
      );
      if (row['id'] != invitation.localMemberId ||
          row['production_id'] != invitation.productionId) {
        throw StateError('Cloud invitation confirmed a different identity');
      }
      return (
        localMemberId: invitation.localMemberId,
        cloudMember: CastMemberModel(
          id: row['id'] as String,
          productionId: row['production_id'] as String,
          userId: row['user_id'] as String?,
          characterName:
              row['character_name'] as String? ?? invitation.characterName,
          displayName: row['display_name'] as String? ?? invitation.displayName,
          contactInfo: row['contact_info'] as String?,
          role: CastRole.fromString(row['role'] as String? ?? invitation.role),
          invitedAt:
              DateTime.tryParse(row['invited_at'] as String? ?? '') ??
              invitation.createdAt,
          joinedAt: DateTime.tryParse(row['joined_at'] as String? ?? ''),
        ),
      );
    } catch (_, stack) {
      await _repo.markCastInvitationFailed(
        invitation.localMemberId,
        'retry_pending',
      );
      DebugLogService.instance.logError(
        LogCategory.network,
        'Cast invitation retry remains pending',
        null,
        stack,
      );
      return null;
    }
  }

  @override
  void dispose() {
    final subscription = _connectivitySubscription;
    if (subscription != null) unawaited(subscription.cancel());
    super.dispose();
  }
}

enum ScriptPersistStatus {
  nothingToSave,
  cloudSkipped,
  cloudSynced,
  cloudFailed,
}

class ScriptPersistResult {
  final ScriptPersistStatus status;
  final Object? cloudError;

  const ScriptPersistResult(this.status, {this.cloudError});

  bool get localSaved => status != ScriptPersistStatus.nothingToSave;
}

/// Persist the current script locally, then return a truthful cloud outcome.
/// Local persistence failures throw. Cloud failures are returned to the caller
/// so each UI operation can render exactly one result message.
Future<ScriptPersistResult> persistScript(WidgetRef ref) async {
  final trace = PerfService.instance.startTrace('persist_script');
  try {
    final script = ref.read(currentScriptProvider);
    final production = ref.read(currentProductionProvider);
    if (script == null || production == null) {
      return const ScriptPersistResult(ScriptPersistStatus.nothingToSave);
    }

    await persistScriptLocally(ref, production.id, script);

    final myUserId = SupabaseService.instance.currentUser?.id;
    if (myUserId == null || production.organizerId != myUserId) {
      DebugLogService.instance.log(
        LogCategory.network,
        'Script cloud push skipped — not the organizer',
      );
      return const ScriptPersistResult(ScriptPersistStatus.cloudSkipped);
    }

    try {
      await pushScriptToCloud(ref);
      AnalyticsService.instance.logCloudSynced(direction: 'push');
      return const ScriptPersistResult(ScriptPersistStatus.cloudSynced);
    } catch (error) {
      DebugLogService.instance.logError(
        LogCategory.network,
        'Script cloud push failed — local save remains durable',
        error,
      );
      return ScriptPersistResult(
        ScriptPersistStatus.cloudFailed,
        cloudError: error,
      );
    }
  } finally {
    trace?.stop();
  }
}

// ── Script edit autosave ───────────────────────────────
//
// Editor screens (script/character/scene editors, gender toggles) only wrote
// currentScriptProvider, which is in-memory: an app kill — or simply opening
// another production — silently threw away every edit, and castmates never saw
// them. Any screen that mutates the script now calls scheduleScriptSave(), and
// this debounces the real persist so rapid edits don't thrash Drift/cloud.
Timer? _scriptSaveTimer;
bool _scriptSaveInFlight = false;
bool _scriptSaveQueued = false;

/// Persist the current script soon (debounced). Safe to call on every edit.
void scheduleScriptSave(
  WidgetRef ref, {
  Duration delay = const Duration(milliseconds: 800),
}) {
  _scriptSaveTimer?.cancel();
  // The timer closure can outlive the scheduling widget; a disposed
  // WidgetRef throws from ref.read and the pending save would be lost with
  // an unhandled zone error. Editor screens flush on dispose, so the only
  // work lost here is a save something else already superseded.
  _scriptSaveTimer = Timer(delay, () async {
    try {
      await _runScriptSave(ref);
    } catch (e) {
      DebugLogService.instance.logError(
        LogCategory.general,
        'Debounced script save failed (screen disposed?)',
        e,
      );
    }
  });
}

/// Persist immediately (e.g. leaving an editor screen), skipping the debounce.
Future<void> flushScriptSave(WidgetRef ref) async {
  _scriptSaveTimer?.cancel();
  _scriptSaveTimer = null;
  await _runScriptSave(ref);
}

Future<void> _runScriptSave(WidgetRef ref) async {
  if (_scriptSaveInFlight) {
    _scriptSaveQueued = true;
    return;
  }
  _scriptSaveInFlight = true;
  try {
    final result = await persistScript(ref);
    if (result.status == ScriptPersistStatus.cloudFailed) {
      rootScaffoldMessengerKey.currentState?.showAutoToast(
        const SnackBar(
          content: Text(
            "Couldn't sync script changes to the cast — your edits "
            'are saved on this device and will retry on the next save.',
          ),
          duration: Duration(seconds: 6),
        ),
      );
    }
  } catch (e) {
    DebugLogService.instance.logError(
      LogCategory.error,
      'Script autosave failed',
      e,
    );
    rootScaffoldMessengerKey.currentState?.showAutoToast(
      const SnackBar(
        content: Text(
          "Couldn't save script changes — they're still on screen; "
          'try again or check your connection.',
        ),
        duration: Duration(seconds: 6),
      ),
    );
  } finally {
    _scriptSaveInFlight = false;
    if (_scriptSaveQueued) {
      _scriptSaveQueued = false;
      unawaited(_runScriptSave(ref));
    }
  }
}

/// Save [script] to Drift and the SharedPreferences backup WITHOUT pushing to
/// the cloud. Use for scripts that just came FROM the cloud (join, refresh) —
/// pushing those back is at best redundant and at worst a destructive
/// delete+reinsert racing the organizer.
Future<void> persistScriptLocally(
  WidgetRef ref,
  String productionId,
  ParsedScript script,
) async {
  final repo = ref.read(productionRepositoryProvider);
  await repo.saveScriptLines(productionId, script.lines);
  await repo.saveScenes(productionId, script.scenes);

  // Save a JSON backup to SharedPreferences as a second local copy
  try {
    final jsonList = script.lines.map((l) => l.toJson()).toList();
    // Isolate.run: encoding a full play is a multi-MB synchronous JSON pass
    // that ran on the UI isolate inside the debounced autosave.
    final jsonString = await Isolate.run(() => jsonEncode(jsonList));
    if (jsonString.length <= _maxBackupBytes) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('script_backup_$productionId', jsonString);
      DebugLogService.instance.log(
        LogCategory.general,
        'Script backup saved to SharedPreferences for $productionId '
        '(${script.lines.length} lines, ${jsonString.length} bytes)',
      );
    } else {
      DebugLogService.instance.log(
        LogCategory.general,
        'Script backup skipped — JSON too large '
        '(${jsonString.length} bytes > $_maxBackupBytes)',
      );
    }
  } catch (e) {
    DebugLogService.instance.logError(
      LogCategory.error,
      'SharedPreferences script backup failed',
      e,
    );
    // Non-fatal — Drift save already succeeded
  }
}

/// Wire up recording sync for a production: persist remote URLs on upload,
/// subscribe to realtime so castmates' new recordings download as they arrive,
/// and run a full background sync (upload local, download others').
///
/// Safe to call whenever a production becomes current. It is invoked from the
/// production hub's init so it covers BOTH entry paths — opening a production
/// from the home screen AND joining one (the join screen uses `context.go`,
/// which disposes it, so it can't own the long-lived sync work itself).
bool shouldSyncRecordingsForProduction(String productionId) =>
    productionId != DemoProductionService.productionId;

int activateRecordingProduction(String? productionId) => productionId == null
    ? RecordingSyncService.instance.deactivateProduction()
    : RecordingSyncService.instance.activateProduction(productionId);

void launchRecordingSync(WidgetRef ref, String productionId, int runToken) {
  bool isCurrent() =>
      RecordingSyncService.instance.isProductionRunCurrent(
        productionId,
        runToken,
      );
  // The built-in demo is local-only and deliberately uses a readable,
  // non-UUID id. Sending it to Supabase produces a PostgreSQL UUID error and
  // a false connection warning during first-run model setup.
  if (!shouldSyncRecordingsForProduction(productionId)) {
    RecordingSyncService.instance.unsubscribe();
    return;
  }
  final userId = SupabaseService.instance.currentUser?.id;

  // Persist remote URLs locally when queued uploads complete so recordings
  // aren't re-uploaded and sync status stays accurate.
  SyncQueue.instance.onUploaded = (job, url) => ref
      .read(recordingsProvider.notifier)
      .markUploaded(
        job.productionId,
        job.lineId,
        url,
        expectedRecordingId: job.recordingId,
        expectedRecordedAt: job.recordedAt,
      );

  // A recording the queue abandons after all retries never reaches castmates —
  // that must be loud, not just a debug-log line.
  SyncQueue.instance.onGaveUp = (job, error) {
    rootScaffoldMessengerKey.currentState?.showAutoToast(
      SnackBar(
        content: Text(
          'Upload failed for a "${job.characterName}" recording — castmates '
          "won't hear it. Check your connection and re-record the line.",
        ),
        duration: const Duration(seconds: 8),
      ),
    );
  };

  RecordingSyncService.instance
    ..onRecordingReady = (lineId, path) {
      // Add just the recording that arrived — rebuilding the full cache map
      // stats every cached file per download, which during a big first sync
      // is O(n²) file stats plus n map copies.
      final rec = RecordingSyncService.instance.getCachedRecording(
        lineId,
        productionId: productionId,
      );
      if (rec != null) {
        ref.read(understudyRecordingsProvider.notifier).loadFromMap({
          lineId: rec,
        });
      }
    }
    ..onLocalUploaded = (lineId, url) async {
      await ref
          .read(recordingsProvider.notifier)
          .markUploaded(productionId, lineId, url);
    }
    ..subscribe(productionId: productionId, myUserId: userId);

  // Full sync in the background — don't block. The caller (app.dart's
  // currentProductionProvider listener) awaits the Drift load before invoking
  // this, so recordingsProvider already holds this production's recordings —
  // no arbitrary sleep needed (a slow load used to make sync see an empty map
  // and re-download/skip-upload recordings it already had).
  Future(() async {
    // Surface recordings already downloaded to disk (previous runs) BEFORE
    // the network sync — so castmates' takes play even when offline.
    await RecordingSyncService.instance.hydrateCache();
    if (!isCurrent()) return;
    final hydrated = RecordingSyncService.instance.getCachedRecordings(
      productionId,
    );
    if (hydrated.isNotEmpty) {
      ref.read(understudyRecordingsProvider.notifier).loadFromMap(hydrated);
    }

    final localRecordings = ref.read(recordingsProvider);

    final downloaded = await RecordingSyncService.instance.syncForProduction(
      productionId: productionId,
      localRecordings: localRecordings,
      myUserId: userId,
    );
    if (!isCurrent()) return;

    if (downloaded > 0) {
      final cached = RecordingSyncService.instance.getCachedRecordings(
        productionId,
      );
      ref.read(understudyRecordingsProvider.notifier).loadFromMap(cached);
    }
  }).catchError((Object e) {
    // Fire-and-forget: an uncaught throw here would surface as an unhandled
    // zone error (crash in debug, bare Crashlytics noise in release) with no
    // sign that recording sync failed.
    DebugLogService.instance.logError(
      LogCategory.network,
      'Background recording sync failed',
      e,
    );
  });
}

/// Restore productions this user belongs to from the cloud into Drift.
///
/// A reinstall / new device used to show an EMPTY home screen forever — the
/// memberships and productions exist in Supabase but nothing ever fetched
/// them (actors had to re-enter join codes; organizers had no recovery path
/// at all). Merges cloud productions the local DB doesn't have; never
/// overwrites local rows. Safe to call on every home-screen load.
Future<void> restoreCloudProductions(WidgetRef ref) async {
  final supa = SupabaseService.instance;
  if (!supa.isInitialized || !supa.isSignedIn) return;
  try {
    final rows = await supa.fetchMyProductions();
    if (rows.isEmpty) return;

    final localIds = ref.read(productionsProvider).map((p) => p.id).toSet();
    final missing = rows
        .where((row) => !localIds.contains(row['id'] as String?))
        .map(
          (row) => Production(
            id: row['id'] as String,
            title: row['title'] as String? ?? 'Untitled',
            organizerId: row['organizer_id'] as String? ?? '',
            createdAt:
                DateTime.tryParse(row['created_at'] as String? ?? '') ??
                DateTime.now(),
            status: ProductionStatus.draft,
            joinCode: row['join_code'] as String?,
            locale: row['locale'] as String? ?? 'en-US',
          ),
        )
        .toList();
    if (missing.isEmpty) return;

    await ref.read(productionsProvider.notifier).addAll(missing);
    DebugLogService.instance.log(
      LogCategory.network,
      'Cloud production restore complete; restored_count=${missing.length}',
    );
  } catch (e) {
    DebugLogService.instance.logError(
      LogCategory.network,
      'Cloud production restore failed',
      e,
    );
  }
}

/// Fetch cloud script lines for a production. Returns null if Supabase
/// is not initialized or no lines exist in the cloud.
Future<List<ScriptLine>?> fetchCloudScriptLines(String productionId) async {
  final supa = SupabaseService.instance;
  if (!supa.isInitialized || !supa.isSignedIn) return null;

  try {
    final rows = await supa.fetchScriptLines(productionId);
    if (rows.isEmpty) return null;

    return rows
        .map(
          (row) => ScriptLine(
            id: row['id'] as String,
            act: row['act'] as String? ?? '',
            scene: row['scene'] as String? ?? '',
            lineNumber: row['line_number'] as int? ?? 0,
            orderIndex: row['order_index'] as int? ?? 0,
            character: row['character'] as String? ?? '',
            text: row['line_text'] as String? ?? '',
            // asNameMap fallback: one unknown line_type (newer app version, bad
            // row) degrades that line to dialogue instead of nulling the whole
            // script — byName would throw and abort the entire fetch.
            lineType:
                LineType.values.asNameMap()[row['line_type'] as String? ??
                    'dialogue'] ??
                LineType.dialogue,
            stageDirection: row['stage_direction'] as String? ?? '',
            multiCharacters:
                (row['multi_characters'] as List?)?.cast<String>() ?? const [],
          ),
        )
        .toList();
  } catch (e) {
    DebugLogService.instance.logError(
      LogCategory.network,
      'Cloud script fetch failed for $productionId',
      e,
    );
    return null;
  }
}

/// Push the current script to the cloud.
Future<void> pushScriptToCloud(WidgetRef ref) async {
  final script = ref.read(currentScriptProvider);
  final production = ref.read(currentProductionProvider);
  final supa = SupabaseService.instance;
  if (script == null || production == null) return;
  if (!supa.isInitialized || !supa.isSignedIn) return;

  try {
    final rows = script.lines
        .asMap()
        .entries
        .map(
          (e) => {
            // Preserve the line id so it's STABLE across the cast. Without this the
            // cloud regenerates ids on every push, and recordings (keyed by line id)
            // are orphaned for everyone who later pulls the script — they fall back
            // to TTS because no line matches. See pull side: ScriptLine(id: row['id']).
            'id': e.value.id,
            'production_id': production.id,
            'order_index': e.key,
            'act': e.value.act,
            'scene': e.value.scene,
            'line_number': e.value.lineNumber,
            'character': e.value.character,
            'line_text': e.value.text,
            'line_type': e.value.lineType.name,
            'stage_direction': e.value.stageDirection,
            // Shared/ensemble lines ("BOTH", "MACBETH AND LENNOX") lose their
            // character list without this — joiners then never see those lines
            // under "my lines" and are never prompted to record them.
            'multi_characters': e.value.multiCharacters.isEmpty
                ? null
                : e.value.multiCharacters,
          },
        )
        .toList();

    final sceneRows = script.scenes
        .asMap()
        .entries
        .map(
          (e) => {
            'id': e.value.id,
            'production_id': production.id,
            'sort_order': e.key,
            'scene_name': e.value.sceneName,
            'act': e.value.act,
            'location': e.value.location,
            'description': e.value.description,
            'start_line_index': e.value.startLineIndex,
            'end_line_index': e.value.endLineIndex,
            'characters': e.value.characters.join(','),
          },
        )
        .toList();

    await supa.saveScript(
      productionId: production.id,
      lines: rows,
      scenes: sceneRows,
    );
  } catch (e) {
    DebugLogService.instance.logError(
      LogCategory.network,
      'Cloud script push failed for ${production.id}',
      e,
    );
    rethrow;
  }
}

/// [buildParsedScript], then overlay cloud scene metadata when available.
///
/// Scene names/descriptions edited in the scene editor sync via the
/// script_scenes table; productions pushed before that table existed (or
/// with an unreachable cloud) keep the tag-derived scenes.
Future<ParsedScript> buildParsedScriptWithCloudScenes(
  String title,
  List<ScriptLine> lines,
  String productionId,
) async {
  // Explicit gender choices win over inference, on every path out of this
  // function — including the early returns below.
  final base = buildParsedScript(
    title,
    lines,
    savedGenders: await VoiceConfigService.instance.getGenders(productionId),
  );
  final supa = SupabaseService.instance;
  if (!supa.isInitialized || !supa.isSignedIn) return base;
  try {
    final rows = await supa.fetchScriptScenes(productionId);
    if (rows.isEmpty) return base;
    final scenes = <ScriptScene>[];
    for (final r in rows) {
      final start = r['start_line_index'] as int? ?? 0;
      final end = r['end_line_index'] as int? ?? -1;
      // Ranges are positional into THIS line list; anything inconsistent
      // (e.g. scenes pushed against a different revision of the lines)
      // falls back wholesale to tag-derived scenes rather than serving a
      // wrong slice to rehearsal.
      if (start < 0 || end < start || end >= lines.length) return base;
      scenes.add(
        ScriptScene(
          id: r['id'] as String,
          act: r['act'] as String? ?? '',
          sceneName: r['scene_name'] as String? ?? '',
          location: r['location'] as String? ?? '',
          description: r['description'] as String? ?? '',
          startLineIndex: start,
          endLineIndex: end,
          characters: (r['characters'] as String? ?? '')
              .split(',')
              .where((c) => c.isNotEmpty)
              .toList(),
        ),
      );
    }
    if (scenes.isEmpty) return base;
    return ParsedScript(
      title: base.title,
      lines: base.lines,
      characters: base.characters,
      scenes: scenes,
      rawText: base.rawText,
    );
  } catch (e) {
    DebugLogService.instance.logError(
      LogCategory.network,
      'Cloud scene fetch failed for $productionId — using tag-derived',
      e,
    );
    return base;
  }
}

/// Build a ParsedScript from a list of ScriptLine objects.
/// Reconstructs scenes from the scene tags already on each line.
/// Rebuild a [ParsedScript] from persisted lines.
///
/// [savedGenders] are the user's explicit choices from the character manager.
/// They MUST be passed by any caller that has a production id: gender is
/// re-derived on every load rather than stored on the line rows, so omitting
/// them silently reverts a hand-corrected character to the inferred value the
/// next time the production is opened.
ParsedScript buildParsedScript(
  String title,
  List<ScriptLine> lines, {
  Map<String, CharacterGender> savedGenders = const {},
}) {
  final charCounts = <String, int>{};
  for (final line in lines) {
    if (line.lineType == LineType.dialogue && line.character.isNotEmpty) {
      if (line.multiCharacters.isNotEmpty) {
        for (final char in line.multiCharacters) {
          charCounts[char] = (charCounts[char] ?? 0) + 1;
        }
      } else {
        charCounts[line.character] = (charCounts[line.character] ?? 0) + 1;
      }
    }
  }
  final characters = charCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final scriptCharacters = characters
      .asMap()
      .entries
      .map(
        (e) => ScriptCharacter(
          name: e.value.key,
          colorIndex: e.key,
          lineCount: e.value.value,
          gender:
              savedGenders[e.value.key] ??
              ScriptParser.inferGender(e.value.key),
        ),
      )
      .toList();

  // Rebuild scenes from line scene/act tags
  final scenes = _buildScenesFromLines(lines);

  return ParsedScript(
    title: title,
    lines: lines,
    characters: scriptCharacters,
    scenes: scenes,
    rawText: '',
  );
}

/// Reconstruct ScriptScene objects by grouping consecutive lines
/// that share the same act+scene tag.
List<ScriptScene> _buildScenesFromLines(List<ScriptLine> lines) {
  if (lines.isEmpty) return [];

  final scenes = <ScriptScene>[];
  var sceneStart = 0;
  var currentKey = '${lines.first.act}|${lines.first.scene}';
  var sceneCounter = 0;

  void closeScene(int endIndex) {
    final sceneLines = lines.sublist(sceneStart, endIndex + 1);
    final dialogueLines = sceneLines
        .where((l) => l.lineType == LineType.dialogue)
        .toList();
    if (dialogueLines.isEmpty) {
      sceneStart = endIndex + 1;
      return;
    }

    sceneCounter++;
    final chars = <String>{};
    for (final l in dialogueLines) {
      if (l.multiCharacters.isNotEmpty) {
        chars.addAll(l.multiCharacters);
      } else if (l.character.isNotEmpty) {
        chars.add(l.character);
      }
    }

    final act = sceneLines.first.act;
    final scene = sceneLines.first.scene;
    final sceneName = scene.isNotEmpty
        ? '$act, $scene'
        : '$act, Scene $sceneCounter';

    scenes.add(
      ScriptScene(
        id: const Uuid().v4(),
        act: act,
        sceneName: sceneName,
        location: scene,
        description: '',
        startLineIndex: sceneStart,
        endLineIndex: endIndex,
        characters: chars.toList()..sort(),
      ),
    );

    sceneStart = endIndex + 1;
  }

  for (var i = 1; i < lines.length; i++) {
    final key = '${lines[i].act}|${lines[i].scene}';
    if (key != currentKey) {
      closeScene(i - 1);
      currentKey = key;
    }
  }
  closeScene(lines.length - 1);

  return scenes;
}

/// Load a saved script from the database for the given production.
/// Falls back to SharedPreferences backup if the Drift DB returns empty.
/// (Cloud fallback is handled by the join flow, not here.)
Future<ParsedScript?> loadPersistedScript(
  WidgetRef ref,
  String productionId,
) async {
  final repo = ref.read(productionRepositoryProvider);
  var lines = await repo.getScriptLines(productionId);
  final scenes = await repo.getScenes(productionId);

  // If Drift DB returned no lines, try recovering from SharedPreferences backup
  if (lines.isEmpty) {
    try {
      final prefs = await SharedPreferences.getInstance();
      final backupJson = prefs.getString('script_backup_$productionId');
      if (backupJson != null && backupJson.isNotEmpty) {
        final jsonList = jsonDecode(backupJson) as List<dynamic>;
        lines = jsonList
            .map((e) => ScriptLine.fromJson(e as Map<String, dynamic>))
            .toList();

        DebugLogService.instance.log(
          LogCategory.error,
          'WARNING: Drift DB empty for $productionId — '
          'recovered ${lines.length} lines from SharedPreferences backup',
        );

        // Re-persist recovered lines back to Drift so future loads are normal
        if (lines.isNotEmpty) {
          await repo.saveScriptLines(productionId, lines);
          DebugLogService.instance.log(
            LogCategory.general,
            'Re-persisted ${lines.length} recovered lines back to Drift DB',
          );
        }
      }
    } catch (e) {
      DebugLogService.instance.logError(
        LogCategory.error,
        'SharedPreferences backup recovery failed for $productionId',
        e,
      );
    }
  }

  if (lines.isEmpty) return null;

  // Rebuild characters from dialogue lines.
  // Multi-character lines credit each individual character.
  final charCounts = <String, int>{};
  for (final line in lines) {
    if (line.lineType == LineType.dialogue && line.character.isNotEmpty) {
      if (line.multiCharacters.isNotEmpty) {
        for (final char in line.multiCharacters) {
          charCounts[char] = (charCounts[char] ?? 0) + 1;
        }
      } else {
        charCounts[line.character] = (charCounts[line.character] ?? 0) + 1;
      }
    }
  }
  final characters = charCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  // Load saved genders
  final savedGenders = await VoiceConfigService.instance.getGenders(
    productionId,
  );

  final scriptCharacters = characters
      .asMap()
      .entries
      .map(
        (e) => ScriptCharacter(
          name: e.value.key,
          colorIndex: e.key,
          lineCount: e.value.value,
          gender:
              savedGenders[e.value.key] ??
              ScriptParser.inferGender(e.value.key),
        ),
      )
      .toList();

  // If no scenes were persisted, rebuild from line tags
  final effectiveScenes = scenes.isNotEmpty
      ? scenes
      : _buildScenesFromLines(lines);

  return ParsedScript(
    title: '', // Title comes from production
    lines: lines,
    characters: scriptCharacters,
    scenes: effectiveScenes,
    rawText: '',
  );
}

/// Wipe every in-memory account-scoped provider and pause background sync
/// before sign-out. Persisted artifacts (Drift rows, queue jobs, upload
/// checkpoints) are account-namespaced and intentionally survive.
Future<void> teardownAccountState(WidgetRef ref) async {
  final productions = ref.read(productionsProvider.notifier);
  final currentProduction = ref.read(currentProductionProvider.notifier);
  final currentScript = ref.read(currentScriptProvider.notifier);
  final recordings = ref.read(recordingsProvider.notifier);
  final understudy = ref.read(understudyRecordingsProvider.notifier);
  final cast = ref.read(castMembersProvider.notifier);
  final recordingCharacter = ref.read(recordingCharacterProvider.notifier);
  final rehearsalCharacter = ref.read(rehearsalCharacterProvider.notifier);
  final selectedScene = ref.read(selectedSceneProvider.notifier);
  final rehearsalMode = ref.read(rehearsalModeProvider.notifier);
  final hideMyLines = ref.read(hideMyLinesProvider.notifier);
  final pendingJoin = ref.read(pendingJoinProvider.notifier);
  final accountNamespace = ref.read(activeAccountNamespaceProvider.notifier);
  final recordingSync = RecordingSyncService.instance;
  final syncQueue = SyncQueue.instance;

  _scriptSaveTimer?.cancel();
  _scriptSaveTimer = null;
  _scriptSaveQueued = false;
  _scriptSaveInFlight = false;

  productions.clear();
  currentProduction.state = null;
  currentScript.state = null;
  recordings.clear();
  understudy.clear();
  cast.clear();
  recordingCharacter.state = null;
  rehearsalCharacter.state = null;
  selectedScene.state = null;
  rehearsalMode.state = RehearsalMode.sceneReadthrough;
  hideMyLines.state = false;
  pendingJoin.state = null;

  final recordingTeardown = recordingSync.teardownAccount();
  final queueTeardown = syncQueue.teardownAccount();
  accountNamespace.state = guestAccountNamespace;
  await Future.wait([recordingTeardown, queueTeardown]);
}
