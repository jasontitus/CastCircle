import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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

/// Provider for the character the user is rehearsing as.
final rehearsalCharacterProvider = StateProvider<String?>((ref) => null);

/// Provider for the selected scene to rehearse.
final selectedSceneProvider = StateProvider<ScriptScene?>((ref) => null);

/// Rehearsal mode: full scene readthrough vs cue-response practice vs full readthrough.
enum RehearsalMode { sceneReadthrough, cuePractice, readthrough }

final rehearsalModeProvider =
    StateProvider<RehearsalMode>((ref) => RehearsalMode.sceneReadthrough);

/// When true, the actor's upcoming lines are hidden (blind rehearsal).
final hideMyLinesProvider = StateProvider<bool>((ref) => false);

/// Repository provider — bridges Drift DB with domain models.
final productionRepositoryProvider = Provider<ProductionRepository>((ref) {
  final db = ref.read(databaseProvider);
  return ProductionRepository(db);
});

/// The list of productions the user has.
final productionsProvider =
    StateNotifierProvider<ProductionsNotifier, List<Production>>((ref) {
  final repo = ref.read(productionRepositoryProvider);
  return ProductionsNotifier(repo);
});

class ProductionsNotifier extends StateNotifier<List<Production>> {
  final ProductionRepository _repo;

  ProductionsNotifier(this._repo) : super([]) {
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
    dlog.log(LogCategory.general,
        'ProductionsNotifier.add: "${production.title}" id=${production.id}, '
        'state has ${state.length} items, ids=${state.map((p) => p.id).toList()}');
    await _repo.saveProduction(production);
    // Reload from DB to guarantee no duplicates (DB uses insertOrReplace).
    state = await _repo.getAllProductions();
    dlog.log(LogCategory.general,
        'ProductionsNotifier.add: after reload, state has ${state.length} items');
  }

  Future<void> update(Production production) async {
    await _repo.saveProduction(production);
    state = [
      for (final p in state)
        if (p.id == production.id) production else p,
    ];
  }

  Future<void> remove(String id) async {
    await _repo.deleteProduction(id);
    state = state.where((p) => p.id != id).toList();
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

  /// Persist the remote URL after a successful cloud upload so the app
  /// knows the recording is synced (and won't re-upload it).
  Future<void> markUploaded(
      String productionId, String scriptLineId, String remoteUrl) async {
    await _repo.markRecordingUploaded(productionId, scriptLineId, remoteUrl);
    final existing = state[scriptLineId];
    if (existing != null && _productionId == productionId) {
      state = {
        ...state,
        scriptLineId: existing.copyWith(remoteUrl: remoteUrl),
      };
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

/// Cast members for the current production, backed by Drift + Supabase sync.
final castMembersProvider =
    StateNotifierProvider<CastMembersNotifier, List<CastMemberModel>>((ref) {
  final repo = ref.read(productionRepositoryProvider);
  return CastMembersNotifier(repo);
});

class CastMembersNotifier extends StateNotifier<List<CastMemberModel>> {
  final ProductionRepository _repo;
  String? _productionId;

  CastMembersNotifier(this._repo) : super([]);

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

/// Persist the current script to the local database, SharedPreferences backup,
/// and push to cloud. Three layers: Drift DB -> SharedPreferences -> Supabase.
/// Call after updating currentScriptProvider when you want changes saved.
Future<void> persistScript(WidgetRef ref) async {
  final trace = PerfService.instance.startTrace('persist_script');
  final script = ref.read(currentScriptProvider);
  final production = ref.read(currentProductionProvider);
  if (script == null || production == null) { trace?.stop(); return; }

  await persistScriptLocally(ref, production.id, script);

  // Also push to cloud so other cast members can download it. Only the
  // organizer may write script_lines (RLS) — a cast member's push would fail
  // every time, so don't attempt it (their edits stay local by design; the
  // cloud copy is the organizer's).
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
    await pushScriptToCloud(ref);
    AnalyticsService.instance.logCloudSynced(direction: 'push');
  } catch (e) {
    // Local save succeeded, but the cast will keep rehearsing a stale script
    // until a push succeeds — that must be loud, not a debugPrint.
    DebugLogService.instance.logError(
      LogCategory.network,
      'Script cloud push failed — castmates will not see these edits '
      'until the next successful save',
      e,
    );
    rootScaffoldMessengerKey.currentState?.showAutoToast(const SnackBar(
      content: Text("Couldn't sync script changes to the cast — check your "
          'connection. Your edits are saved on this device and will push on '
          'the next save.'),
      duration: Duration(seconds: 6),
    ));
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

/// Persist the current script soon (debounced). Safe to call on every edit.
void scheduleScriptSave(WidgetRef ref, {Duration delay = const Duration(milliseconds: 800)}) {
  _scriptSaveTimer?.cancel();
  // The timer closure can outlive the scheduling widget; a disposed
  // WidgetRef throws from ref.read and the pending save would be lost with
  // an unhandled zone error. Editor screens flush on dispose, so the only
  // work lost here is a save something else already superseded.
  _scriptSaveTimer = Timer(delay, () async {
    try {
      await _runScriptSave(ref);
    } catch (e) {
      DebugLogService.instance.logError(LogCategory.general,
          'Debounced script save failed (screen disposed?)', e);
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
  // Serialize: two overlapping persists mean two cloud delete+reinsert cycles
  // racing over the same rows.
  if (_scriptSaveInFlight) {
    _scriptSaveQueued = true;
    return;
  }
  _scriptSaveInFlight = true;
  try {
    await persistScript(ref);
  } catch (e) {
    DebugLogService.instance
        .logError(LogCategory.error, 'Script autosave failed', e);
    rootScaffoldMessengerKey.currentState?.showAutoToast(const SnackBar(
      content: Text("Couldn't save script changes — they're still on screen; "
          'try again or check your connection.'),
      duration: Duration(seconds: 6),
    ));
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
    WidgetRef ref, String productionId, ParsedScript script) async {
  final repo = ref.read(productionRepositoryProvider);
  await repo.saveScriptLines(productionId, script.lines);
  await repo.saveScenes(productionId, script.scenes);

  // Save a JSON backup to SharedPreferences as a second local copy
  try {
    final jsonList = script.lines.map((l) => l.toJson()).toList();
    final jsonString = jsonEncode(jsonList);
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
void launchRecordingSync(WidgetRef ref, String productionId) {
  final userId = SupabaseService.instance.currentUser?.id;

  // Persist remote URLs locally when queued uploads complete so recordings
  // aren't re-uploaded and sync status stays accurate.
  SyncQueue.instance.onUploaded = (prodId, lineId, url) {
    ref.read(recordingsProvider.notifier).markUploaded(prodId, lineId, url);
  };

  // A recording the queue abandons after all retries never reaches castmates —
  // that must be loud, not just a debug-log line.
  SyncQueue.instance.onGaveUp = (job, error) {
    rootScaffoldMessengerKey.currentState?.showAutoToast(SnackBar(
      content: Text(
          'Upload failed for a "${job.characterName}" recording — castmates '
          "won't hear it. Check your connection and re-record the line."),
      duration: const Duration(seconds: 8),
    ));
  };

  RecordingSyncService.instance
    ..onRecordingReady = (lineId, path) {
      // Add just the recording that arrived — rebuilding the full cache map
      // stats every cached file per download, which during a big first sync
      // is O(n²) file stats plus n map copies.
      final rec = RecordingSyncService.instance
          .getCachedRecording(lineId, productionId: productionId);
      if (rec != null) {
        ref
            .read(understudyRecordingsProvider.notifier)
            .loadFromMap({lineId: rec});
      }
    }
    ..onLocalUploaded = (lineId, url) {
      ref.read(recordingsProvider.notifier).markUploaded(productionId, lineId, url);
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
    final hydrated =
        RecordingSyncService.instance.getCachedRecordings(productionId);
    if (hydrated.isNotEmpty) {
      ref.read(understudyRecordingsProvider.notifier).loadFromMap(hydrated);
    }

    final localRecordings = ref.read(recordingsProvider);

    final downloaded = await RecordingSyncService.instance.syncForProduction(
      productionId: productionId,
      localRecordings: localRecordings,
      myUserId: userId,
    );

    if (downloaded > 0) {
      final cached =
          RecordingSyncService.instance.getCachedRecordings(productionId);
      ref.read(understudyRecordingsProvider.notifier).loadFromMap(cached);
    }
  }).catchError((Object e) {
    // Fire-and-forget: an uncaught throw here would surface as an unhandled
    // zone error (crash in debug, bare Crashlytics noise in release) with no
    // sign that recording sync failed.
    DebugLogService.instance.logError(
        LogCategory.network, 'Background recording sync failed', e);
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

    final localIds =
        ref.read(productionsProvider).map((p) => p.id).toSet();
    final missing = rows
        .where((row) => !localIds.contains(row['id'] as String?))
        .map((row) => Production(
              id: row['id'] as String,
              title: row['title'] as String? ?? 'Untitled',
              organizerId: row['organizer_id'] as String? ?? '',
              createdAt:
                  DateTime.tryParse(row['created_at'] as String? ?? '') ??
                      DateTime.now(),
              status: ProductionStatus.draft,
              joinCode: row['join_code'] as String?,
              locale: row['locale'] as String? ?? 'en-US',
            ))
        .toList();
    if (missing.isEmpty) return;

    await ref.read(productionsProvider.notifier).addAll(missing);
    DebugLogService.instance.log(
        LogCategory.network,
        'Restored ${missing.length} production(s) from the cloud '
        '(${missing.map((p) => p.title).join(', ')})');
  } catch (e) {
    DebugLogService.instance
        .logError(LogCategory.network, 'Cloud production restore failed', e);
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

    return rows.map((row) => ScriptLine(
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
      lineType: LineType.values
              .asNameMap()[row['line_type'] as String? ?? 'dialogue'] ??
          LineType.dialogue,
      stageDirection: row['stage_direction'] as String? ?? '',
      multiCharacters:
          (row['multi_characters'] as List?)?.cast<String>() ?? const [],
    )).toList();
  } catch (e) {
    DebugLogService.instance.logError(
        LogCategory.network, 'Cloud script fetch failed for $productionId', e);
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
    final rows = script.lines.asMap().entries.map((e) => {
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
      'multi_characters':
          e.value.multiCharacters.isEmpty ? null : e.value.multiCharacters,
    }).toList();

    await supa.saveScriptLines(
      productionId: production.id,
      lines: rows,
    );
  } catch (e) {
    DebugLogService.instance.logError(
        LogCategory.network, 'Cloud script push failed for ${production.id}', e);
    rethrow;
  }
}

/// Build a ParsedScript from a list of ScriptLine objects.
/// Reconstructs scenes from the scene tags already on each line.
ParsedScript buildParsedScript(String title, List<ScriptLine> lines) {
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
  final scriptCharacters = characters.asMap().entries.map((e) => ScriptCharacter(
    name: e.value.key,
    colorIndex: e.key,
    lineCount: e.value.value,
    gender: ScriptParser.inferGender(e.value.key),
  )).toList();

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
    final dialogueLines =
        sceneLines.where((l) => l.lineType == LineType.dialogue).toList();
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

    scenes.add(ScriptScene(
      id: const Uuid().v4(),
      act: act,
      sceneName: sceneName,
      location: scene,
      description: '',
      startLineIndex: sceneStart,
      endLineIndex: endIndex,
      characters: chars.toList()..sort(),
    ));

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
Future<ParsedScript?> loadPersistedScript(WidgetRef ref, String productionId) async {
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
  final savedGenders =
      await VoiceConfigService.instance.getGenders(productionId);

  final scriptCharacters = characters.asMap().entries.map((e) => ScriptCharacter(
        name: e.value.key,
        colorIndex: e.key,
        lineCount: e.value.value,
        gender: savedGenders[e.value.key] ?? ScriptParser.inferGender(e.value.key),
      )).toList();

  // If no scenes were persisted, rebuild from line tags
  final effectiveScenes = scenes.isNotEmpty ? scenes : _buildScenesFromLines(lines);

  return ParsedScript(
    title: '', // Title comes from production
    lines: lines,
    characters: scriptCharacters,
    scenes: effectiveScenes,
    rawText: '',
  );
}
