import 'dart:async';
import 'dart:isolate';
import 'dart:convert';

import 'package:flutter/material.dart' show SnackBar, Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../data/services/debug_log_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../data/models/cast_member_model.dart';
import '../data/models/production_models.dart';
import '../data/models/script_models.dart';
import '../data/repositories/production_repository.dart';
import '../data/services/deep_link_service.dart';
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

final activeAccountNamespaceProvider = StateProvider<String>(
  (ref) => guestAccountNamespace,
);

int _identityGeneration = 0;

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
  final preferences = await SharedPreferences.getInstance();
  if (generation != _identityGeneration) return;
  final completionKey = 'account_namespace_claim_v1_$namespace';
  if (preferences.getBool(completionKey) != true) {
    await database.claimLegacyProductions(namespace);
    if (generation != _identityGeneration) return;
    final persisted = await preferences.setBool(completionKey, true);
    if (!persisted) {
      throw StateError('Could not persist account namespace reconciliation');
    }
  }
  if (generation == _identityGeneration && notifier.state != namespace) {
    notifier.state = namespace;
  }
}

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

/// Repository provider — bridges Drift DB with domain models.
final productionRepositoryProvider = Provider<ProductionRepository>((ref) {
  final db = ref.watch(databaseProvider);
  final accountNamespace = ref.watch(activeAccountNamespaceProvider);
  return ProductionRepository(db, accountNamespace: accountNamespace);
});

/// The list of productions the user has.
final productionsProvider =
    StateNotifierProvider<ProductionsNotifier, List<Production>>((ref) {
      final repo = ref.watch(productionRepositoryProvider);
      return ProductionsNotifier(repo);
    });

class ProductionsNotifier extends StateNotifier<List<Production>> {
  final ProductionRepository _repo;
  int _generation = 0;

  ProductionsNotifier(this._repo) : super([]) {
    _load();
  }

  Future<void> _load() async {
    final generation = _generation;
    final loaded = await _repo.getAllProductions();
    if (generation == _generation) state = loaded;
  }

  /// Save [productions] to Drift and reload once. Used by the cloud restore.
  Future<void> addAll(List<Production> productions) async {
    final generation = _generation;
    for (final production in productions) {
      await _repo.saveProduction(production);
    }
    final loaded = await _repo.getAllProductions();
    if (generation == _generation) state = loaded;
  }

  Future<void> add(Production production) async {
    final generation = _generation;
    final dlog = DebugLogService.instance;
    dlog.log(
      LogCategory.general,
      'ProductionsNotifier.add: "${production.title}" id=${production.id}, '
      'state has ${state.length} items, ids=${state.map((p) => p.id).toList()}',
    );
    await _repo.saveProduction(production);
    final loaded = await _repo.getAllProductions();
    if (generation != _generation) return;
    state = loaded;
    dlog.log(
      LogCategory.general,
      'ProductionsNotifier.add: after reload, state has ${state.length} items',
    );
  }

  Future<void> update(Production production) async {
    final generation = _generation;
    await _repo.saveProduction(production);
    if (generation != _generation) return;
    state = [
      for (final p in state)
        if (p.id == production.id) production else p,
    ];
  }

  Future<void> remove(String id) async {
    final generation = _generation;
    await _repo.deleteProduction(id);
    if (generation == _generation) {
      state = state.where((p) => p.id != id).toList();
    }
  }

  void clear() {
    _generation++;
    state = [];
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
      final repo = ref.watch(productionRepositoryProvider);
      return RecordingsNotifier(repo);
    });

class RecordingsNotifier extends StateNotifier<Map<String, Recording>> {
  final ProductionRepository _repo;
  String? _productionId;
  int _generation = 0;

  RecordingsNotifier(this._repo) : super({});

  /// Load recordings for a given production from the database.
  Future<void> loadForProduction(String productionId) async {
    final generation = ++_generation;
    _productionId = productionId;
    final loaded = await _repo.getRecordings(productionId);
    if (generation == _generation && _productionId == productionId) {
      state = loaded;
    }
  }

  Future<void> add(Recording recording) async {
    final generation = _generation;
    final productionId = _productionId;
    if (productionId != null) {
      await _repo.saveRecording(productionId, recording);
    }
    if (generation == _generation) {
      state = {...state, recording.scriptLineId: recording};
    }
  }

  Future<void> remove(String scriptLineId) async {
    final productionId = _productionId;
    final recording = state[scriptLineId];
    // State first, synchronously: Dismissible requires the row to leave in the
    // current frame. The exact production/id delete follows.
    state = Map.from(state)..remove(scriptLineId);
    if (productionId != null && recording != null) {
      await _repo.deleteRecording(productionId, recording.id);
    }
  }

  Future<void> removeRecording(
    String productionId,
    String scriptLineId,
    String recordingId,
  ) async {
    await _repo.deleteRecording(productionId, recordingId);
    final loaded = state[scriptLineId];
    if (_productionId == productionId && loaded?.id == recordingId) {
      state = Map.from(state)..remove(scriptLineId);
    }
  }

  void removeFromMap(String scriptLineId) {
    if (state.containsKey(scriptLineId)) {
      state = Map.from(state)..remove(scriptLineId);
    }
  }

  /// Load recordings from a pre-built map (e.g. from recording sync cache).
  void loadFromMap(Map<String, Recording> recordings) {
    state = {...state, ...recordings};
  }

  /// Persist the remote URL after a successful cloud upload so the app
  /// knows the recording is synced (and won't re-upload it).
  Future<void> markUploaded(
    String productionId,
    String scriptLineId,
    String recordingId,
    String remoteUrl,
  ) async {
    await _repo.markRecordingUploaded(
      productionId,
      scriptLineId,
      recordingId,
      remoteUrl,
    );
    final existing = state[scriptLineId];
    if (existing != null &&
        existing.id == recordingId &&
        _productionId == productionId) {
      state = {...state, scriptLineId: existing.copyWith(remoteUrl: remoteUrl)};
    }
  }

  void clear() {
    _generation++;
    _productionId = null;
    state = {};
  }
}

/// Understudy recordings for the current production, keyed by script line ID.
/// These are recordings made by understudies and can be used as fallback
/// when the primary actor hasn't recorded a line.
final understudyRecordingsProvider =
    StateNotifierProvider<RecordingsNotifier, Map<String, Recording>>((ref) {
      final repo = ref.watch(productionRepositoryProvider);
      return RecordingsNotifier(repo);
    });

/// Character being recorded in the recording studio.
final recordingCharacterProvider = StateProvider<String?>((ref) => null);

/// Cast members for the current production, backed by Drift + Supabase sync.
final castMembersProvider =
    StateNotifierProvider<CastMembersNotifier, List<CastMemberModel>>((ref) {
      final repo = ref.watch(productionRepositoryProvider);
      return CastMembersNotifier(repo);
    });

class CastMembersNotifier extends StateNotifier<List<CastMemberModel>> {
  final ProductionRepository _repo;
  String? _productionId;
  int _generation = 0;

  CastMembersNotifier(this._repo) : super([]);

  /// Load cast members from Drift for the given production.
  Future<void> loadForProduction(String productionId) async {
    final generation = ++_generation;
    _productionId = productionId;
    final loaded = await _repo.getCastMembers(productionId);
    if (generation == _generation && _productionId == productionId) {
      state = loaded;
    }
  }

  /// Add or update a cast member in Drift and state.
  Future<void> save(CastMemberModel member) async {
    final generation = _generation;
    await _repo.saveCastMember(member);
    if (generation != _generation) return;
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

  Future<void> applyChanges({
    required List<CastMemberModel> upserts,
    required Set<String> deleteIds,
  }) async {
    final generation = _generation;
    await _repo.applyCastMemberChanges(upserts: upserts, deleteIds: deleteIds);
    if (generation != _generation) return;
    final next = {
      for (final member in state)
        if (!deleteIds.contains(member.id)) member.id: member,
      for (final member in upserts) member.id: member,
    };
    state = next.values.toList();
  }

  /// Remove a cast member.
  Future<void> remove(String id) async {
    final generation = _generation;
    await _repo.deleteCastMember(id);
    if (generation == _generation) {
      state = state.where((m) => m.id != id).toList();
    }
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
    _generation++;
    _productionId = null;
    state = [];
  }
}

/// Persist the current script to the local database, SharedPreferences backup,
/// and push to cloud. Three layers: Drift DB -> SharedPreferences -> Supabase.
/// Call after updating currentScriptProvider when you want changes saved.
Future<void> persistScript(WidgetRef ref) async {
  final accountEpoch = _accountEpoch;
  final trace = PerfService.instance.startTrace('persist_script');
  final script = ref.read(currentScriptProvider);
  final production = ref.read(currentProductionProvider);
  if (script == null || production == null) {
    trace?.stop();
    return;
  }

  await persistScriptLocally(ref, production.id, script);
  if (accountEpoch != _accountEpoch) {
    trace?.stop();
    return;
  }

  final myUserId = SupabaseService.instance.currentUser?.id;
  if (myUserId == null || production.organizerId != myUserId) {
    DebugLogService.instance.log(
      LogCategory.network,
      'Script cloud push skipped — not the organizer '
      '(edits stay on this device)',
    );
    trace?.stop();
    return;
  }
  try {
    final outcome = await pushScriptToCloud(ref);
    if (outcome == ScriptCloudPushOutcome.complete) {
      AnalyticsService.instance.logCloudSynced(direction: 'push');
    }
  } catch (e) {
    DebugLogService.instance.logError(
      LogCategory.network,
      'Script cloud push failed — castmates will not see these edits '
      'until the next successful save',
      e,
    );
    rootScaffoldMessengerKey.currentState?.showAutoToast(
      const SnackBar(
        content: Text(
          "Couldn't sync script changes to the cast — check your "
          'connection. Your edits are saved on this device and will push on '
          'the next save.',
        ),
        duration: Duration(seconds: 6),
      ),
    );
  }
  trace?.stop();
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
int _accountEpoch = 0;
int _scriptSaveGeneration = 0;

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
  final generation = _scriptSaveGeneration;
  if (_scriptSaveInFlight) {
    _scriptSaveQueued = true;
    return;
  }
  _scriptSaveInFlight = true;
  try {
    await persistScript(ref);
  } catch (e) {
    if (generation == _scriptSaveGeneration) {
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
    }
  } finally {
    if (generation == _scriptSaveGeneration) {
      _scriptSaveInFlight = false;
      if (_scriptSaveQueued) {
        _scriptSaveQueued = false;
        unawaited(_runScriptSave(ref));
      }
    }
  }
}

/// Invalidate all account-scoped work and state before authentication changes.
/// Every provider dependency is captured before the first await so this remains
/// safe if the settings route is disposed while teardown is running.
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

  _accountEpoch++;
  _scriptSaveTimer?.cancel();
  _scriptSaveTimer = null;
  _scriptSaveQueued = false;
  _scriptSaveGeneration++;
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
int activateRecordingProduction(String? productionId) => productionId == null
    ? RecordingSyncService.instance.deactivateProduction()
    : RecordingSyncService.instance.activateProduction(productionId);

void launchRecordingSync(WidgetRef ref, String productionId, int runToken) {
  final accountEpoch = _accountEpoch;
  final userId = SupabaseService.instance.currentUser?.id;
  final recordingsNotifier = ref.read(recordingsProvider.notifier);
  final understudyNotifier = ref.read(understudyRecordingsProvider.notifier);
  final localRecordings = ref.read(recordingsProvider);
  final sync = RecordingSyncService.instance;

  bool isCurrent() =>
      accountEpoch == _accountEpoch &&
      sync.isProductionRunCurrent(productionId, runToken);
  if (!isCurrent()) return;

  SyncQueue.instance.onUploaded = (prodId, lineId, recordingId, url) async {
    if (!isCurrent()) return;
    await recordingsNotifier.markUploaded(prodId, lineId, recordingId, url);
  };
  SyncQueue.instance.onGaveUp = (job, error) {
    if (!isCurrent()) return;
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
  unawaited(SyncQueue.instance.processQueue());

  void onReady(String callbackProductionId, String lineId, String path) {
    if (!isCurrent() || callbackProductionId != productionId) return;
    final rec = sync.getCachedRecording(productionId, lineId);
    if (rec != null) {
      understudyNotifier.loadFromMap({lineId: rec});
    }
  }

  void onEvicted(String callbackProductionId, String lineId) {
    if (isCurrent() && callbackProductionId == productionId) {
      understudyNotifier.removeFromMap(lineId);
    }
  }

  Future<void> onLocalUploaded(
    String callbackProductionId,
    String lineId,
    String recordingId,
    String url,
  ) async {
    if (!isCurrent() || callbackProductionId != productionId) return;
    await recordingsNotifier.markUploaded(
      productionId,
      lineId,
      recordingId,
      url,
    );
  }

  sync.subscribe(
    productionId: productionId,
    runToken: runToken,
    myUserId: userId,
    onRecordingReady: onReady,
    onRecordingEvicted: onEvicted,
  );

  Future(() async {
    await sync.hydrateCache();
    if (!isCurrent()) return;
    final hydrated = await sync.getCachedRecordings(productionId);
    if (!isCurrent()) return;
    if (hydrated.isNotEmpty) {
      understudyNotifier.loadFromMap(hydrated);
    }

    final downloaded = await sync.syncForProduction(
      productionId: productionId,
      runToken: runToken,
      localRecordings: localRecordings,
      myUserId: userId,
      onRecordingReady: onReady,
      onRecordingEvicted: onEvicted,
      onLocalUploaded: onLocalUploaded,
    );
    if (!isCurrent()) return;
    if (downloaded > 0) {
      final cached = await sync.getCachedRecordings(productionId);
      if (isCurrent()) understudyNotifier.loadFromMap(cached);
    }
  }).catchError((Object e) {
    if (isCurrent()) {
      DebugLogService.instance.logError(
        LogCategory.network,
        'Background recording sync failed',
        e,
      );
    }
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
  final namespace = ref.read(activeAccountNamespaceProvider);
  final namespaceController = ref.read(activeAccountNamespaceProvider.notifier);
  final productions = ref.read(productionsProvider.notifier);
  final localIds = ref.read(productionsProvider).map((p) => p.id).toSet();
  try {
    final rows = await supa.fetchMyProductions();
    if (namespaceController.state != namespace || rows.isEmpty) return;
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
    if (missing.isEmpty || namespaceController.state != namespace) {
      return;
    }
    await productions.addAll(missing);
    DebugLogService.instance.log(
      LogCategory.network,
      'Restored ${missing.length} production(s) from the cloud '
      '(${missing.map((p) => p.title).join(', ')})',
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

enum ScriptCloudPushOutcome { skipped, complete, scenesFailed }

/// Push the current script to the cloud.
Future<ScriptCloudPushOutcome> pushScriptToCloud(WidgetRef ref) async {
  final accountEpoch = _accountEpoch;
  final script = ref.read(currentScriptProvider);
  final production = ref.read(currentProductionProvider);
  final supa = SupabaseService.instance;
  if (script == null || production == null) {
    return ScriptCloudPushOutcome.skipped;
  }
  if (!supa.isInitialized || !supa.isSignedIn) {
    return ScriptCloudPushOutcome.skipped;
  }

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

    await supa.saveScriptLines(productionId: production.id, lines: rows);
    if (accountEpoch != _accountEpoch) {
      return ScriptCloudPushOutcome.skipped;
    }

    // Scene metadata too: without this, custom scene names/descriptions
    // from the scene editor lived only in local Drift — every cloud pull
    // regenerated scenes from line tags and silently discarded them.
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
    try {
      await supa.saveScriptScenes(
        productionId: production.id,
        scenes: sceneRows,
      );
      return ScriptCloudPushOutcome.complete;
    } catch (e) {
      // Tolerated separately: the script_scenes table may not exist yet on
      // an un-migrated backend, and lines (the critical payload) are saved.
      DebugLogService.instance.logError(
        LogCategory.network,
        'Cloud scene push failed for ${production.id} (lines saved)',
        e,
      );
      return ScriptCloudPushOutcome.scenesFailed;
    }
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
