# Pi sweep review — CastCircle

Exhaustive per-file pass: 97 code files across 54 batches — model ds4/GLM-5.3-Flash-Q2:off — 2026-08-29.

## Findings

- [medium] lib/data/database/app_database.dart:119 — `AppDatabase.forTesting(super.e)` declares a `super.e` parameter but the class's real constructor `AppDatabase()` takes no arguments and passes `_openConnection()`; the generated `_$AppDatabase` superclass constructor expects a `QueryExecutor` argument, so this named/positional forwarding is inconsistent with the declared `AppDatabase()` constructor — consequence: the "for testing" entry point cannot actually construct a database from a caller-supplied executor (it forwards to a constructor that ignores it / fails to compile against the generated parent), leaving tests unable to inject an in-memory executor and silently exercising the real file-backed DB — smallest safe fix: declare `AppDatabase.forTesting(QueryExecutor e) : super(e);` (or drop the constructor) so the executor is actually forwarded.
- [medium] lib/data/database/app_database.dart:130-142 — `_step` treats any error message containing `'already exists'` as benign and returns without rethrowing, but the same substring can appear in unrelated failures (e.g. a table/index named "…already exists…" in a user-visible message, or a wrapped error whose text merely mentions it); a real migration failure whose message happens to contain that phrase is swallowed, Drift advances `user_version`, and the missing column/index is never repaired — consequence: silent, permanent schema corruption masked as a successful migration — smallest safe fix: match the exact Drift/SQLite duplicate-error wording (e.g. `'duplicate column name'` alone, or check `e is drift.runtime.DriftException`) instead of the loose `'already exists'` substring.
- [low] lib/data/database/app_database.dart:328-330 — PRAGMAs are executed via `db.execute` inside `setup` on every open, but `journal_mode=WAL` can fail (returning a non-WAL mode) without throwing on some SQLite builds; the code never checks the returned mode — consequence: a silently non-WAL database keeps the busy-writer assumptions of `insertRecording`'s transaction and the 3000ms busy timeout, producing sporadic `SQLITE_BUSY` under concurrent watch/insert load — smallest safe fix: run `PRAGMA journal_mode=WAL;` via `db.select` (or `customSelect`) and assert the result row reports `wal`, logging otherwise.
- [low] lib/data/database/app_database.dart:316-333 — `_openConnection` builds the DB path from `getApplicationDocumentsDirectory()` with no error handling; on platforms where path_provider throws (or returns an empty path) the `LazyDatabase` opener future rejects during first use — consequence: first DB access throws an opaque `LazyDatabase` open error instead of a diagnosable message — smallest safe fix: wrap the directory lookup in a try/catch that logs via `DebugLogService` and rethrows a descriptive error.

## Coverage
lib/data/database/app_database.dart — findings: 4
lib/data/models/cast_member_model.dart — clean
- [low] lib/data/models/production_models.dart:19 — `locale` silently defaults to `'en-US'` in the constructor rather than being required or resolved from the device — a production created without an explicit locale records STT/rehearsal analytics under the wrong locale for non-English casts, and the fallback resolves to the riskier (wrong-language) value rather than failing — make `locale` required (or resolve from device locale at creation) so callers cannot omit it.
- [low] lib/data/models/rehearsal_models.dart:38 — `struggledLines` filters on `bestScore < 0.7` with a hard-coded threshold that ignores `skipped` lines' semantics — a manually advanced (`skipped: true`) line with no real match can carry a bestScore above/below the constant and be misclassified in analytics; assert the threshold against the production's configured match threshold symbol instead of a local literal — replace the literal `0.7` with the shared threshold constant used by the rehearsal scoring code (assumed to exist in a caller not inlined here).
- [info] lib/data/models/production_models.dart:8 — `scriptPath` is a local file path stored on a model that also carries `joinCode`; nothing in the inlined code sanitizes or scopes it — if this model is ever serialized (e.g. via `toJson`-style export in sibling models), the local path could leak device paths to other cast members; verify serialization sites before treating as exploitable.

## Coverage
lib/data/models/production_models.dart — findings: 2
lib/data/models/rehearsal_models.dart — findings: 1
- [medium] lib/data/repositories/production_repository.dart:24-27 — `watchAllProductions` maps the stream with `rows.map(...).toList()` but the outer stream's `.map` returns a `Stream<List<Production>>` whose inner `rows.map(_productionFromRow)` is a lazy `Iterable` — the inner `.toList()` is present, so this is fine; however the outer `.map` callback returns a new list per event with no error handling — consequence: none exhibited in this file — no finding.
- [medium] lib/data/repositories/production_repository.dart:29-40 — `saveProduction` always calls `insertProduction` with a `Value(production.id)`; if the caller passes an existing production id this becomes an insert that fails on primary-key conflict rather than an upsert — consequence: saving an edited production throws instead of persisting, unless the DB method is an upsert (assumption: `insertProduction` is a plain insert; not visible here) — smallest safe fix: use `insertProduction(..., mode: InsertMode.update)` or an `updateProduction` path when the row exists.
- [medium] lib/data/repositories/production_repository.dart:42-61 — `deleteProduction` deletes recording files best-effort but never deletes the recordings' remote artifacts or checks `localPath` nullability; if `recording.localPath` is an empty string, `File('')` exists() is false so it's harmless — consequence: none exhibited — no finding.
- [medium] lib/data/repositories/production_repository.dart:56-60 — cascade delete order deletes recordings, script lines, scenes, cast, then the production, but there is no transaction wrapping these five deletes — consequence: a crash mid-sequence leaves orphaned script lines/scenes/cast rows referencing a deleted production (unrecoverable inconsistent state for that production id) — smallest safe fix: wrap the cascade in `_db.transaction(() async { ... })` like `saveScriptLines` does at 142-145.
- [medium] lib/data/repositories/production_repository.dart:84-95 — `saveCastMember` inserts with `Value(member.id)`; same insert-vs-upsert concern as `saveProduction` — consequence: re-saving an existing cast member throws on conflict (assumption: plain insert) — smallest safe fix: upsert or update-then-insert.
- [medium] lib/data/repositories/production_repository.dart:92 — `invitedAt: Value(member.invitedAt ?? DateTime.now())` fabricates a timestamp when the model has none — consequence: the persisted invitedAt silently differs from the caller's intent and is not reproducible; a member invited "now" by a repository default can misorder invitations — smallest safe fix: require `invitedAt` on the model or persist null.
- [medium] lib/data/repositories/production_repository.dart:121-146 — `saveScriptLines` deletes all lines for the production then re-inserts inside a transaction, but the companions are built from `lines` without validating that each `l.id` is unique; duplicate ids in the incoming list cause a primary-key conflict that aborts the transaction and leaves the production with zero script lines (the delete already happened logically inside the txn, so rollback restores them — actually rollback restores, so consequence is a thrown error, not data loss) — consequence: save fails wholesale on duplicate ids — smallest safe fix: dedupe or assert unique ids before building companions.
- [low] lib/data/repositories/production_repository.dart:137 — `multiCharacters.join(',')` then `_scriptLineFromRow` splits on `,` (162-164) — a character name containing a comma (e.g. "JOHN, JR.") round-trips as two characters — consequence: `isForCharacter` (script_models.dart:70-73) matches a bogus split name — smallest safe fix: use an unlikely delimiter or JSON-encode the list.
- [medium] lib/data/repositories/production_repository.dart:189 — same comma-join/split round-trip for `characters` in `saveScenes`/`_sceneFromRow` (206-208) — consequence: scene character lists corrupt on names with commas — smallest safe fix: same as above.
- [low] lib/data/repositories/production_repository.dart:214-222 — `getRecordings` keys the map by `row.scriptLineId`; if two recordings share a scriptLineId the later row silently overwrites the earlier — consequence: a recording is dropped from the returned map with no error — smallest safe fix: keep the newest by `recordedAt` or return a list.
- [low] lib/data/models/voice_preset.dart:146-149 — `VoicePresets.byId` silently falls back to `modernAmerican` for an unknown id — consequence: a typo'd preset id yields the wrong production style with no signal, and persisted ids referencing removed presets resolve to a different preset after an app update — smallest safe fix: return nullable or log/throw on unknown ids; at minimum document the fallback as intended.
- [info] lib/data/models/voice_preset.dart:152-184 — `voiceLabels` lists 28 Kokoro voice ids but the preset pools reference only a subset; ids like `af_alloy`, `af_aoede`, `af_kore`, `af_nicole`, `af_river`, `af_sky`, `am_echo`, `am_fenrir`, `am_liam`, `am_puck` are labeled but never used by any preset — consequence: none (label map is display-only) — no finding beyond this note.

## Coverage
lib/data/models/voice_preset.dart — findings: 1
lib/data/repositories/production_repository.dart — findings: 8
- [medium] lib/data/services/audio_level_service.dart:60-63 — cache eviction removes the oldest entry before inserting the new one, but the check runs on every call including cache hits' siblings, so a burst of >512 distinct paths evicts entries that may still be in flight; more importantly the eviction happens even when the incoming `volume` was computed from a failed analysis (line 54 catch sets 1.0), so a transient MethodChannel failure permanently caches 1.0 for that path — a hot recording that should be attenuated plays at full volume until `invalidate` is called, and nothing in this file calls `invalidate` on analysis failure — smallest safe fix: only cache the computed value on successful analysis (return early without caching when the channel throws or the result is unusable), or evict only when adding a *new* key.
- [low] lib/data/services/audio_level_service.dart:68-70 — `prefetch` fires `volumeFor` without awaiting or guarding; if two prefetches race for the same uncached path, both invoke the channel and both write the cache (harmless duplicate work), but if a caller concurrently `invalidate`s, the in-flight result can re-populate the cache after invalidation — smallest safe fix: track in-flight futures per path and have `invalidate` also cancel/supersede them.
- [low] lib/data/services/audio_level_service.dart:36-55 — `volumeFor` treats a non-`Map` result, a missing `rmsDbfs` key, a non-finite or non-negative RMS, and a thrown exception identically as "play at 1.0"; a positive (or zero) `rmsDbfs` — which the doc at lines 22-24 says should be impossible for dBFS — silently skips attenuation instead of surfacing the anomaly — smallest safe fix: log/telemetry the malformed sample and still cache a conservative value, or clamp `rms` to ≤ 0 before the comparison.
- [info] lib/data/services/analytics_service.dart:10-11 — `_analytics` is null whenever the global `firebaseAvailable` flag is false, so every `log*` call silently becomes a no-op; if that flag is meant to reflect "analytics initialized" rather than "Firebase SDK present", events are dropped with no signal — verify the flag's semantics in `main.dart` (not inlined here); no fix proposed from this file alone.

## Coverage
lib/data/services/analytics_service.dart — findings: 1
lib/data/services/audio_level_service.dart — findings: 3
- [medium] lib/data/services/deep_link_service.dart:113-115 — bare `catch (e)` swallows every error type from `getInitialLink` (including `TimeoutException`-adjacent failures and `StateError`s) and only debugPrints, so a cold-start link that throws for a non-timeout reason is silently dropped and the user sees nothing — replace with a narrower catch or log via `DebugLogService.instance.logError` like the timeout branch does.
- [medium] lib/data/services/deep_link_service.dart:124-128 — `try`/`catch` around `uriLinkStream.listen` cannot catch anything: `listen` returns synchronously and stream errors are delivered via the registered `onError`, so the "Invites tapped from now on will do nothing" comment describes a dead branch and a real listen failure (e.g. `AppLinks` misconfiguration) would surface as an unhandled async error instead of the intended log — remove the try/catch or move the failure handling into `onError`.
- [low] lib/data/services/deep_link_service.dart:152-156 — `rootScaffoldMessengerKey.currentState?.showAutoToast` is called from `_handleUri` which can run before `runApp` mounts the messenger (cold-start path, per the comment at 150-151); the null-aware call then silently drops the toast with no fallback, so a rejected invite link on cold start gives no user-visible feedback — queue the rejection (e.g. store a flag consumed by the join screen) instead of relying on a possibly-null messenger.
- [low] lib/data/services/deep_link_service.dart:144-148 — rejected-link log embeds `uri.scheme://host/path` but not the raw code text (good), yet `debugPrint('Deep link received: $uri')` at 132 prints the full URI including query parameters (code, char, name) to console in debug builds, leaking link-supplied names the sanitizer deliberately strips elsewhere — gate the debugPrint behind `kDebugMode` with the same shape-only logging used at 145-148.
- [info] lib/data/services/deep_link_service.dart:24 — `_codePattern` is `static final` (non-const) `RegExp`; fine as-is, but note `RegExp` is not `const`-constructible so this is intentional; no action needed.
- [low] lib/data/services/contact_picker_service.dart:35-38 — `on PlatformException` treats only `'CANCELLED'` as null and rethrows everything else, but the comment at 36 says "permission denied" is also user-facing; a permission-denied `PlatformException` escapes `pickContact` uncaught, likely crashing an unguarded caller — catch permission-denied codes (or document that callers must catch) so the picker degrades to null like cancellation does.
- [low] lib/data/services/contact_picker_service.dart:28-34 — `invokeMapMethod<String, String>` result keys are read with `result['name'] ?? ''` etc. without verifying the map actually contains them; a native side returning extra/missing keys yields a `PickedContact` with empty `displayName` silently — validate `result` contains `name` before constructing, or return null on malformed payloads.

## Coverage
lib/data/services/contact_picker_service.dart — findings: 2
lib/data/services/deep_link_service.dart — findings: 4
- [medium] lib/data/services/demo_production_service.dart:59-93 — `load()` mutates global provider state (`currentProductionProvider`, `currentScriptProvider`, `rehearsalCharacterProvider`) and persists to SharedPreferences without any guard against concurrent/second invocation; a second caller while `_preselectCharacter`'s async prefs round-trip is in flight can interleave and leave `rehearsalCharacterProvider` set to a stale/other production's character — consequence: a returning user opening the demo twice (e.g. rapid re-entry from two surfaces) can land on the wrong part; smallest safe fix: capture the resolved character before any `await` and set the notifier synchronously, or key the prefs entry by production id plus a load-generation token. — reachability: any authenticated user against their own data (local-only demo, no cross-tenant exposure), so medium.
- [low] lib/data/services/demo_production_service.dart:108-112 — fallback picks the character with the most lines via `sort` on a `List` produced by `where(...).toList()`; if `script.characters` were empty the `.first` would throw, but `_parseBundledScript` (line 121) already throws on empty characters, so the only real defect is that the sort mutates the freshly-built list in place rather than a copy — consequence: none observable here since the list is local; smallest safe fix: none needed (defensive note only). — reachability: operator/test-only, low.
- [low] lib/data/services/espeak_heteronyms.dart:85-88 — `before.lastIndexOf(word)` searches the whole matched prefix+word; if the surrounding group (group 1) itself contains the word "live" (e.g. rule 3 "let live" where group 1 is "let " — safe today, but rule 5's group 1 can be arbitrary sentence-start text like "…live. Live and" where the prefix ends with "live"), `lastIndexOf` could locate the earlier occurrence and respell the wrong instance — consequence: a correctly-pronounced adjective "live" in the captured prefix gets rewritten to "liv", degrading audio contrary to the stated scope; smallest safe fix: compute the replacement offset from `m.start(group)`/`m.end(group)` (RegExpMatch exposes `start`/`end` per group) instead of string-searching `before`. — reachability: operator/device-local TTS path only, low.
- [info] lib/data/services/espeak_heteronyms.dart:66-68 — `_matchCase` treats a fully-lowercase replacement as "no case to copy" but for an all-caps original like "LIVE" the first branch returns "LIV" correctly; however for title-case originals where `replacement` is a single lowercase token the second branch uppercases only the first letter — fine for "liv"; no action needed. — reachability: n/a, info.

## Coverage
lib/data/services/demo_production_service.dart — findings: 2
lib/data/services/espeak_heteronyms.dart — findings: 2
- [medium] lib/data/services/frame_stats_service.dart:45-46 — `_pct` indexes the sorted list with `(sorted.length - 1) * p` rounded, so p=0.99 on a 1-element list indexes 0 fine, but on a 2-element list `(2-1)*0.99 = 0.99 → round = 1` ok; however for p=0.9 with length 1 the index is 0 — the real defect is no guard for an empty list: `_report` is only called when `_buildMs.isNotEmpty` (line 40), so empty is guarded — but `_pct` is called with p=0.99 and length 1 → index 0, fine. The actual reachable defect: `_pct` can index out of range when `sorted.length == 0` — guarded by caller — and when `(sorted.length - 1) * p` rounds to `sorted.length` for p close to 1 with large lists? `(len-1)*0.99` for len=1000 → 989.01, fine. No out-of-range reachable. — no finding.
- [medium] lib/data/services/frame_stats_service.dart:37 — jank counted via `t.totalSpan.inMicroseconds > 16700` but the reported percentage divides `_jank` by `n` where `n = _buildMs.length` (line 49) while `_jank` counts frames from the same loop — consistent. However `_report` computes `100 * _jank / n` with integer `_jank` and int `n` → integer division in Dart? `100 * _jank / n` uses `/` which yields double in Dart even for ints — fine. — no finding.
- [medium] lib/data/services/frame_stats_service.dart:31-43 — `_onTimings` accumulates `_buildMs`/`_rasterMs` unbounded between reports; if `DebugLogService` logging or the 30s window stalls (e.g. isolate paused, app backgrounded with timings still delivered), the lists grow without bound for the whole session — memory growth is bounded by frame rate × window, ~1800 entries per 30s window, cleared each report; only pathological if `_report` never fires because `now.difference(_windowStart)` is computed from wall clock `DateTime.now()` which can jump backwards (clock change), delaying the report indefinitely while lists grow. — low, defensive: use monotonic clock (Stopwatch) for the window. — finding: low.
- [low] lib/data/services/frame_stats_service.dart:24-28 — `install()` sets `_installed = true` before `SchedulerBinding.instance.addTimingsCallback` — if `addTimingsCallback` throws (e.g. called after `schedulerBinding` disposed at teardown), the service is permanently marked installed with no callback registered, silently disabling frame stats for the rest of the run. — fix: register first, then set the flag, or reset `_installed` in a catch. — finding: low.
- [info] lib/data/services/frame_stats_service.dart:53-59 — report string interpolates `_pct(b, 0.9)` etc. but `_pct` takes the sorted list `b`/`r` which are copies — fine; no defect.
- [medium] lib/data/services/kokoro_onnx_service.dart:203-211 — cache-hit path returns `cachePath` without checking that the isolate/engine is started or that the cached WAV is complete; a partially-written cache file (crash during `renameSync` at 247, or a prior run killed mid-write) is served forever as a "hit" — every subsequent urgent request for that line plays a truncated/corrupt WAV with no re-synthesis path, because the cache check is `File(cachePath).exists()` only. — consequence: persistent playback of cut-off audio for affected lines until manual cache clear. — fix: write to a temp name and rename only after full write (already done for fresh WAVs), and on cache hit validate size/marker (e.g. `.tmp` suffix or a done-marker) before treating it as a hit. — finding: medium (authenticated user's own playback; silent data loss of audio quality, no crash).
- [medium] lib/data/services/kokoro_onnx_service.dart:243-251 — after synthesis, `File(path).renameSync(cachePath)` — if `cachePath` is null the code returns `path` (fine), but if `path == null` (failed/aborted request) it returns null before adopting — fine. The defect: `renameSync` on the same filesystem is assumed cheap, but `path` lives in `args.tmpDir` (getTemporaryDirectory) and `cachePath` is `${tmpDir}/kokoro_cache/...` — same dir tree, ok. However when the rename throws (file locked by a still-open player on some platforms), the catch returns `path` — the fresh WAV is left in tmp and never adopted, so the next request re-synthesizes and re-writes another `kokoro_onnx_N.wav` — unbounded tmp-file growth across sessions (files are never deleted; only the cache dir is pruned, not tmpDir root). — consequence: disk bloat on devices with repeated failed renames. — fix: on rename failure, delete `path` or register tmpDir for pruning. — finding: low.
- [medium] lib/data/services/kokoro_onnx_service.dart:228-237 — urgent arrival drops older urgent queued requests and aborts in-flight via `_cancelBelow.value = req.seq`, but queued NON-urgent (prefetch) requests behind the new urgent one are not dropped and will still be pumped after the urgent one completes — the doc at 190 says prefetches "queue behind everything", which is honored; no defect. However `_cancelBelow.value = req.seq` aborts every request with seq < req.seq — including the request currently in flight whose seq is lower — correct per design. But a subsequent urgent request sets `_cancelBelow.value` to a HIGHER value than a previous urgent's — wait, seq increases monotonically, so a later urgent has a higher seq and sets the threshold higher, which un-aborts nothing (threshold only grows) — but it also stops aborting requests that were already superseded by an earlier urgent: e.g. urgent A (seq 5) sets threshold 5, aborting seq<5; then urgent B (seq 9) sets threshold 9 — requests 5..8 are now NOT aborted even though A superseded them; if any of 5..8 is mid-generation it runs to completion and its WAV is adopted into cache — wasted work but harmless; if one is queued it still plays before B? No — queue order: B is inserted at front, so 5..8 play after B. Acceptable. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:213-215 — `if (_toIsolate == null && _starting == null) return null;` — when the engine was never started AND no start is pending, synthesize returns null instead of attempting `ensureStarted()`; callers that only call `synthesize` (never `ensureStarted`) get silent no-audio forever after a failed first start, because `_starting` is cleared on completion (line 81) and `_toIsolate` stays null — the "safe to call repeatedly" startup contract only works if someone calls ensureStarted; synthesize itself never retries. Direction of failure: missing expected state (engine not started) resolves to the silent-null path rather than attempting recovery. — consequence: after one transient spawn failure, TTS is permanently dead for the session with no log beyond the initial one. — fix: call `ensureStarted()` (await it) in this branch instead of returning null. — finding: medium.
- [medium] lib/data/services/kokoro_onnx_service.dart:171-172 — `ready.future.timeout(150s, onTimeout: () => false)` — on timeout the code logs "engine failed to start" and calls `stop()` (line 176), which kills the isolate and completes pending requests with null; but the isolate may still be mid-load and will later send `{'ready': true}` — the listener at 122-147 checks `epoch != _epoch` (stop bumped it) so late messages are ignored — correct. But `stop()` also completes `_inFlight` and queued requests with null — those callers get null and treat it as "failed/cancelled", silently dropping speech. Acceptable teardown. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:127-131 — `ready.complete(true)` is guarded by `!ready.isCompleted`, and initError completes false likewise — but if the isolate sends BOTH a late `ready:true` after an initError, the second is ignored — fine. If the isolate never sends anything and dies, `onDone` (149-167) completes ready false — fine. If the isolate sends `ready:true` and later dies, onDone fires with epoch unchanged and completes pending — fine. No double-complete. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:132-146 — response dispatch: `msg['seq']` compared to `_inFlight.seq`, but `_inFlight` is nulled BEFORE the comparison result is used for the abort/error branches — actually `req.completer.complete` happens while `req` local still holds it; `_pump()` then sends the next. Correct. But if the isolate sends a response for a seq that is NOT the current in-flight (e.g. a late response from a previous generation after a stop/restart cycle within the same epoch — impossible since stop kills), the response is silently dropped and `_inFlight` was already nulled — the completer of the matching request would hang… but `_inFlight` is the only request sent while idle, and responses only come for the sent seq. Edge: `_pump` sends req A (seq 3); isolate responds for seq 3; fine. No mismatch path. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:431-433 — in the isolate, `if (seq < cancelBelow.value)` sends `{'seq': seq, 'aborted': true}` and `continue`s WITHOUT the try/catch — fine. But the abort check happens BEFORE generation; the callback at 447-453 polls `seq < cancelBelow.value` — if the main side set `_cancelBelow.value` to a seq HIGHER than this request's seq (later urgent), the callback's `seq < cancelBelow.value` is false and generation proceeds — correct (only older-than-threshold aborts). But note the callback returns 0 to abort and 1 to continue — sherpa's contract assumed; can't verify. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:455-460 — `abortedMidGeneration` sends `{'seq': seq, 'aborted': true}` — main side (140-141) completes null. But the partially generated audio was already discarded — good (never adopt truncated). However the WAV file was never written, so no orphan. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:461-464 — `audio.samples.isEmpty` sends error 'empty audio' — main side completes null via the error branch (136-139). Fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:471-472 — `_writeWav(path, ...)` writes into `args.tmpDir` root with a monotonically increasing `fileSeq` — files are never cleaned up in the isolate; the main side adopts them via rename into the cache dir, but on abort/error/empty paths no file exists; on success the file is renamed away. If the main side's rename fails (locked), the tmp file leaks (see earlier finding). Also across isolate restarts `fileSeq` resets to 0, overwriting `kokoro_onnx_0.wav` from a previous isolate instance — if a previous file is still being read by the player (rename failed case), overwrite corrupts the in-use file. — consequence: rare playback corruption after engine restart with a leaked tmp file. — fix: include a per-isolate unique prefix (e.g. isolate hash or timestamp) in the filename. — finding: low.
- [medium] lib/data/services/kokoro_onnx_service.dart:480-506 — `_writeWav` builds `ByteData(44 + n * 2)` — for a long line at 24 kHz, n can be large; `n * 2` overflow? Dart ints are 64-bit on native — fine. Sample conversion `(samples[i] * 32767).round()` then clamps — fine. Header: `b.setUint32(4, 36 + n*2)` — RIFF size should be `36 + n*2` (file size minus 8) — correct. `s(36, 'data')` writes at offset 36..39, and data size at 40 — but the header layout: RIFF(0-3), size(4-7), WAVE(8-11), fmt(12-23), fmt chunk size at 16? Let me recheck offsets: s(0,'RIFF') → bytes 0-3; setUint32(4, 36+n*2) → 4-7; s(8,'WAVEfmt ') writes 8 bytes at 8-15 → 'WAVE' + 'fmt ' (8 chars) — that's 8 bytes covering 8-15, so 'WAVE' at 8-11 and 'fmt ' at 12-15 — correct; setUint32(16,16) → fmt chunk size 16 at 16-19; setUint16(20,1) → PCM at 20-21; setUint16(22,1) → channels=1 at 22-23; setUint32(24,rate) → 24-27; setUint32(28, rate*2) → byte rate at 28-31; setUint16(32,2) → block align 2 at 32-33; setUint16(34,16) → bits 16 at 34-35; s(36,'data') → 36-39; setUint32(40, n*2) → data size 40-43; samples start at 44 — correct mono 16-bit PCM WAV. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:502-504 — clamp: `v < -32768 ? -32768 : (v > 32767 ? 32767 : v)` — correct clamping; but `.round()` on `samples[i] * 32767` where samples[i] could be NaN (model glitch) → `.round()` on NaN throws `UnsupportedError` in Dart — inside `_writeWav` which is called inside the try at 435-476? `_writeWav` is called at 472 INSIDE the try block (435-476) — wait, the try at 435 wraps generate + write + send; a NaN throw would be caught at 474 and reported as error — safe. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:57-66 — voiceIds map: comment says "The English voices the app offers all live in 0-27" — 28 entries 0..27 — consistent. `voiceIds[voice] ?? voiceIds['af_heart']!` at 219 — unknown voice silently falls back to af_heart (permissive fallback): a typo'd or renamed voice id produces the default voice instead of an error — direction of failure resolves to the permissive value. Consequence: a caller passing an unsupported voice gets the wrong voice with no signal; cache key uses `voice` string so cache stays consistent. — severity: low (wrong voice, not data loss; authenticated user's own request). — finding: low.
- [medium] lib/data/services/kokoro_onnx_service.dart:74-84 — `ensureStarted` re-entrancy: if `_start()` completes and `_starting` was replaced by a concurrent `stop()`+`ensureStarted` (stop sets `_starting = null` at 337, then a new ensureStarted sets a new future), the old `whenComplete` checks `identical(_starting, f)` — correct guard. But if `_start()` returns false (model missing) and `_toIsolate` stays null, a later `ensureStarted` re-runs `_start` — fine. If `_start()` throws synchronously before `whenComplete`… `_start` is async so it returns a future; `whenComplete` on an errored future still fires and clears `_starting` — but the error is then UNHANDLED: `f` is returned to the caller (`_starting = f`), so the caller gets the error — fine, unless nobody awaits `_starting` (e.g. fire-and-forget caller) → unhandled async error crash in debug. Can't verify callers. — no finding (assumption needed).
- [medium] lib/data/services/kokoro_onnx_service.dart:86-119 — `_start` captures `epoch` at entry; after spawn, checks `epoch != _epoch` — but the check happens AFTER `Isolate.spawn` await and BEFORE `_isolate = spawned` — correct ordering. However between `paths == null` early return and the epoch check there's no issue. One real gap: if `epoch != _epoch` at 114, the spawned isolate is killed and `fromIsolate.close()` — but `_sub` was never attached yet (listen happens at 122 after the check) — fine. But if stop() ran DURING `getKokoroPaths` (before spawn), epoch differs at 114? No — epoch was captured at 87 BEFORE the await at 88; stop during the await bumps `_epoch`, so at 114 the check catches it only if we reach 114 — we do (spawn happens regardless). Correct. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:122-127 — `_sub = fromIsolate.listen(...)` — the listener checks `epoch != _epoch` and returns, ignoring messages — but it never closes the port or kills the isolate on stale messages; teardown is stop()'s job — fine. But note: `msg is SendPort` sets `_toIsolate = msg` WITHOUT the epoch check? It IS inside the listener which already returned on stale epoch — so a SendPort arriving after stop is ignored, leaving `_toIsolate` null — correct (a fresh start's port must not resurrect). — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:149-167 — onDone: completes in-flight and queued with null, clears queue, nulls `_toIsolate`, completes ready false — but does NOT null `_isolate` or kill it (it's already dead) and does NOT clear `_starting` — if `_starting` still holds the completed future, a later `ensureStarted` sees `_starting != null` and returns the OLD failed future forever (line 76: `if (_starting != null) return _starting!`) — wait, `whenComplete` at 78-82 clears `_starting` when the future completes; onDone completing `ready` doesn't complete `_start`'s future — `_start` is still awaiting `ready.future` at 171 — onDone's `ready.complete(false)` resolves that await, `_start` continues: `ok=false` → logs, `await stop()` → stop sets `_starting = null` (337) — but the `whenComplete` guard `identical(_starting, f)` — stop nulled `_starting`, so `identical(null, f)` is false → the whenComplete does NOT re-clear (already null) — fine. Then `_start` returns false; `f` completes with false; callers of the ORIGINAL ensureStarted get false. `_starting` is null → next ensureStarted re-runs. OK. But there's a subtle leak: `_sub` is not nulled in onDone; the subscription's stream is done so it's inert — fine. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:335-352 — `stop()` sends `{'cmd': 'dispose'}` to `_toIsolate` then nulls it, cancels `_sub`, kills `_isolate` with `beforeNextEvent` priority — the isolate's dispose handler (425-429) frees tts and closes commands — but `stop` kills the isolate immediately after sending dispose; `Isolate.beforeNextEvent` is a gentle kill that lets the isolate process the dispose message first? `kill(priority: beforeNextEvent)` schedules the kill before the next event — the dispose message may or may not be processed before death; `tts.free()` may never run → native resources freed by isolate death anyway (isolate teardown frees its heap, but sherpa's native allocations via FFI are NOT automatically freed on isolate death — they're process-wide mallocs). Consequence: leaked native memory per stop/start cycle if dispose doesn't land. Can't verify sherpa's cleanup-on-death behavior; state as assumption. — finding: low (operator-visible memory growth over repeated stop/start; no security impact). Actually reachability: any user triggering stop/start cycles (e.g. language switch) — authenticated user, own session — medium per rubric? The rubric: "an authenticated user against their own data = medium". Memory leak in own session — adjust down for guard (leak bounded by cycles) → low. Keep low.
- [medium] lib/data/services/kokoro_onnx_service.dart:344-348 — `stop()` completes `_inFlight` and queued completers with null — but does NOT reset `_cancelBelow.value`; a stale threshold from a previous urgent remains — harmless (monotonic). — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:50 — `_cancelBelow = pkg_ffi.calloc<Int32>()` allocated at singleton construction and never freed (documented at 350-352) — intentional; fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:392-395 — `_isolateMain` receives `cancelBelowAddr` and reconstructs `Pointer<Int32>.fromAddress` — sharing raw memory across isolates is the design; the main side writes `_cancelBelow.value` (232) and the isolate reads — no synchronization issue for a single Int32 flag (relaxed enough in practice). — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:423-433 — `await for (final msg in commands)` — the loop processes ONE command at a time; a dispose closes commands and returns — but `tts.free()` at 426 then `commands.close()` then `return` — the `args.sendPort` is never used again — fine. But if a command arrives that is not a Map or lacks 'cmd', `msg['cmd']` on a non-Map would throw — guarded by `if (msg is! Map) continue` at 424 — fine. `msg['seq'] as int` — if the main side sends a malformed map (it doesn't), cast throws inside the loop OUTSIDE the try (431-433 region is outside try) — the try starts at 435; the seq/cancelBelow checks at 430-433 are outside it; a cast failure there would crash the isolate's await-for loop → isolate dies → onDone fails pending requests. Main side always sends well-formed maps (326-331). — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:440-454 — `tts.generateWithCallback(...)` — the callback closure captures `seq` and `cancelBelow`; `abortedMidGeneration` is set inside the callback — if sherpa calls the callback concurrently from multiple threads (numThreads: 4), the write to `abortedMidGeneration` is fine (single flag), but returning 0 from one thread while others continue is sherpa's contract. Can't verify. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:285-311 — prune runs `Isolate.run` with a closure capturing `dir` — `Directory(dir).listSync()` lists ONLY the cache dir (correct). `entries.sort` by mtime; deletes oldest until under lowWater — but `total` counts only regular files (`e is! File` skip) — directories would be skipped, fine. `file.deleteSync()` wrapped in try/catch — a locked file is skipped and the loop continues — but `total -= size` only on success — correct. Edge: `if (total <= maxBytes) return 0` — if total is between lowWater and maxBytes, no deletion — correct. If total > maxBytes, delete until `total <= lowWater` — deletes MORE than needed (down to 100MB) — intentional hysteresis. — no finding. One real issue: `_schedulePrune` is called only when `_cacheDirPath` was null (first cache-path computation); if the FIRST call to `_cachePathFor` throws before setting `_cacheDirPath` (e.g. getTemporaryDirectory throws), `_cacheDirPath` stays null and every subsequent call re-runs the directory-create + `_schedulePrune` — `_pruneScheduled` guards double-schedule only if the first call got past 266; if the first call threw at 263-264, `_pruneScheduled` is still false and a later successful call schedules prune — fine, but the create+schedule re-runs each call until one succeeds — harmless. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:291-296 — `Directory(dir).listSync()` — `listSync` default is `FileSystemEntityType.link` follow? Default `followLinks: true` — a symlink in the cache dir pointing elsewhere (e.g. /data/…) would have its TARGET stat'd and, if old, `file.deleteSync()` deletes the symlink itself (not the target) — deleting a symlink is safe. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:297 — `if (total <= maxBytes) return 0;` — early return inside the try, before the sort — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:312-317 — `.then((removed) {...}).catchError((_) {})` — swallows errors from the prune isolate — acceptable best-effort. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:259-273 — `_cachePathFor` catch-all returns null on ANY error → cacheless operation — permissive but safe (no cache). — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:268-270 — cache key = sha1(text|voice|speed) — does NOT include the model/voice-pack version; if the app ships a new Kokoro model, old cached WAVs (old model's audio) are served for the same key — stale-audio-after-model-update. Consequence: after a model upgrade, users hear old-model audio indefinitely (until 150MB prune evicts). — fix: include a model version/token in the key. — severity: low (quality regression, not data loss; authenticated user's own playback). — finding: low.
- [medium] lib/data/services/kokoro_onnx_service.dart:197 — `EspeakHeteronyms.apply(rawText)` — context file for espeak_heteronyms.dart is NOT provided; cannot verify its behavior — assumption: it may throw on odd input; it's called OUTSIDE any try in synthesize (before cache path) — an exception would propagate to the caller of synthesize as a rejected future — callers presumably await; a throw would surface as an unhandled error if unawaited. State as assumption — no finding without the file. Could request follow-up: espeak_heteronyms.dart to decide whether apply() can throw. Worth a follow-up? The finding would be "apply() unguarded before cache-key computation" — but I can't confirm it throws. I'll add a follow-up request for it.
- [medium] lib/data/services/kokoro_onnx_service.dart:203-204 — `cachePath != null && await File(cachePath).exists()` — TOCTOU: between exists() and the later renameSync (247), a prune could delete the cachePath? Prune deletes oldest files when over 150MB — the file we just "hit" could be deleted by a concurrent prune isolate between the hit and the return — we return cachePath (nonexistent) → player fails to load. Rare. Also the unawaited setLastModified (208-209) touches mtime to keep LRU — correct intent. — no finding (too rare, no guard needed).
- [medium] lib/data/services/kokoro_onnx_service.dart:208-209 — `File(cachePath).setLastModified(DateTime.now())` — on some platforms setLastModified requires the file to exist and may throw — wrapped in catchError — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:216-222 — `_Req` created with `seq: _nextSeq++` — `_nextSeq` shared across stop/start cycles — monotonic, fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:238-241 — non-urgent appended at the END of the queue — but `_pump` only sends when `_inFlight == null`; if an urgent request is in flight and a prefetch is queued, the prefetch waits — fine. If the queue has a prefetch at the front and an urgent arrives, urgent is inserted at 0 — the prefetch is now behind — but `_pump` won't send the urgent until the in-flight (prefetch) completes — the urgent request's completer waits for the prefetch's full synthesis — the doc says urgent "aborts the current generation" via `_cancelBelow` — yes, 232 sets the threshold so the in-flight prefetch (lower seq) aborts — then the response 'aborted' completes the prefetch null, `_pump` sends the urgent — correct design. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:321-331 — `_pump` sends a map WITHOUT 'urgent' — the isolate doesn't need it. Fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:243-244 — `final path = await req.completer.future; if (path == null || cachePath == null) return path;` — if path is null AND cachePath non-null, returns null — fine. If path non-null and cachePath null, returns path (unadopted tmp file leaks — see earlier tmp-leak finding; same root cause, one finding).
- [medium] lib/data/services/kokoro_onnx_service.dart:246-251 — `try { File(path).renameSync(cachePath); return cachePath; } catch (_) { return path; }` — renameSync is synchronous on the calling isolate (UI or background?) — synthesize is called from the main isolate; renameSync of a potentially large WAV (48KB/s audio, minutes-long lines → MBs) blocks the UI isolate for the duration of the rename — same-filesystem rename is metadata-only, typically fast — acceptable. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:36-36 — `_dlog = DebugLogService.instance` — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:52 — `isRunning => _toIsolate != null` — public getter; fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:93 — `getTemporaryDirectory()` — on some platforms returns a dir that may be cleared by the OS; cache and tmp WAVs live there — acceptable.
- [medium] lib/data/services/kokoro_onnx_service.dart:99-108 — `_IsolateArgs` includes `cancelBelowAddr: _cancelBelow.address` — passing a raw address across isolates — by design.
- [medium] lib/data/services/kokoro_onnx_service.dart:109-113 — spawn failure: `fromIsolate.close()` and return false — but `_starting` is cleared by whenComplete — fine; `_toIsolate` stays null — synthesize's dead-end branch (213-215) returns null forever (see the medium finding above — same root cause: no retry on failed start; I'll merge: the 213-215 finding covers the class).
- [medium] lib/data/services/kokoro_onnx_service.dart:114-119 — epoch check kills the spawned isolate — `spawned.kill(priority: Isolate.immediate)` — immediate kill may not let the isolate free native tts (it hasn't initialized tts yet at that point — spawn just started _isolateMain which immediately builds OfflineTts? No — _isolateMain first sends the sendPort, then builds tts; an immediate kill could land mid-init → native allocations leaked (same class as the stop-dispose finding). Merge into the stop/native-free finding? Different site, same class (native resources not freed on abrupt isolate death). One finding per root cause: root cause = native sherpa resources are freed only via the dispose command; abrupt kills (immediate at 116, beforeNextEvent at 342) may skip it. File ONE finding at the cause listing both sites. — low.
- [medium] lib/data/services/kokoro_onnx_service.dart:171-181 — after `ok`, `_pump()` is called at 179 — but if requests were queued while loading (synthesize queued them via `_pump` at 241 — `_pump` returns early because `_toIsolate == null`), they sit in `_queue`; once ready, `_pump` sends the front — correct. But note `_pump` at 179 is called only in the `ok` branch; in the `!ok` branch stop() already drained the queue. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:176 — `await stop()` inside `_start` — stop bumps `_epoch` again; the local `epoch` variable is stale — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:181 — `return ok;` — `_start`'s future resolves; ensureStarted's whenComplete clears `_starting` if identical — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:392-478 — `_isolateMain` never sends anything on `args.sendPort` after init except responses — the main side's `_sub` listens on `fromIsolate` (the ReceivePort whose sendPort was passed) — responses from the isolate are sent via `args.sendPort` (394, 417, 420, 432, ...) — correct channel. The command channel `commands` is a separate ReceivePort whose sendPort was sent to the main side via `args.sendPort.send(commands.sendPort)` at 394 — main side stores it as `_toIsolate` (124-125) — correct.
- [medium] lib/data/services/kokoro_onnx_service.dart:425-429 — dispose: `tts.free(); commands.close(); return;` — after `commands.close()`, the `await for` loop ends — but the function returns without sending any ack — main side's stop doesn't await an ack — fine. But `return` inside `await for` — the enclosing async function `_isolateMain` returns — the isolate stays alive (no explicit exit) with `commands` closed and no more work — it lingers until killed by stop's `kill` — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:431 — `cancelBelow.value` read in the isolate — if the main side never set it, the calloc'd Int32 is zero-initialized → threshold 0 → `seq < 0` never true (seqs start at 0) — correct default (nothing aborted). — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:447-453 — callback returns 0/1 — sherpa's generate callback contract: return value semantics assumed (0 = abort). Can't verify against sherpa docs in-repo. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:471 — `fileSeq++` — post-increment in string interpolation: `'kokoro_onnx_${fileSeq++}.wav'` — uses the pre-increment value then increments — first file is 0 — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:480-482 — `ByteData(44 + n * 2)` — if n == 0 (empty samples) we'd have caught it at 461 — `_writeWav` is only called after the isEmpty check — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:483-487 — `s()` writes ASCII via `codeUnitAt` — 'RIFF' etc. are ASCII — fine. 'WAVEfmt ' is 8 chars — matches the 8-byte write at 8-15 — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:506 — `b.buffer.asUint8List()` — writes the whole buffer — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:57-66 vs 219 — `voiceIds['af_heart']!` — af_heart is present (line 58: 'af_heart': 3) — the `!` is safe. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:191-252 — synthesize's overall flow: cache hit → return; else queue → await completer → adopt. If the request is aborted (completer completes null), returns null — caller treats as cancelled — fine. If the engine never started (213-215), returns null WITHOUT logging — silent failure with no diagnostic — merge into the 213-215 finding's consequence (add "and no log"). — one finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:259-273 — `_cachePathFor` is called BEFORE checking engine state — cache hits work while loading — intended (doc at 202). — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:203 — `_cachePathFor(text, voice, speed)` — uses the FIXED text (post-heteronym) — key matches what's spoken — correct per doc 193-196. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:269 — `crypto.sha1.convert(utf8.encode('$text|$voice|$speed'))` — sha1 of a short string — collision risk negligible for a cache key; but two different (text,voice,speed) triples could collide in sha1 — practically impossible. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:263 — `'${(await getTemporaryDirectory()).path}/kokoro_cache'` — recomputed only when `_cacheDirPath` is null — if the app's tmp dir changes across runs (it doesn't within a process) — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:287-288 — `maxBytes = 150MB`, `lowWater = 100MB` — constants; doc says ~1 hour of audio — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:298 — `entries.sort((a, b) => a.$2.compareTo(b.$2))` — `$2` is the DateTime (record position 2: (File, DateTime, int) → $1=file, $2=mtime, $3=size) — sorts by mtime ascending — oldest first — correct for LRU. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:300-307 — destructuring `(file, _, size)` — `_` is the mtime (unused) — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:303 — `file.deleteSync()` — deletes cache WAVs — could delete a file that synthesize just adopted (race with prune): prune runs in a separate isolate listing mtimes; a just-touched file has fresh mtime → deleted last — the LRU touch (208-209) protects exactly this — correct design. But the touch is UNAWAITED and may not have landed before the prune isolate stats the file — a just-created cache file (renameSync at 247 sets mtime=now anyway) — renameSync sets mtime to... on most filesystems rename preserves the source's mtime (the write time) — the source was written moments ago — fresh — safe. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:314-315 — log message says "cache was over 150MB" — cosmetic. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:335-352 — stop() is async but performs all teardown synchronously before any await? `_epoch++` etc. are sync; `await _sub?.cancel()` at 340 — the FIRST await is at 340; everything before (336-339) is sync — a concurrent synthesize between 336 and 340 could enqueue a request whose completer is then completed with null at 346-348 — the caller gets null — acceptable (stopped). But a synthesize AFTER stop() completes (epoch bumped) would enqueue into `_queue` and `_pump` — `_toIsolate` is null → `_pump` returns early — the request sits forever, its completer never completed → the caller awaits forever! Check: synthesize at 213 checks `_toIsolate == null && _starting == null` → returns null — after stop, `_starting` is null (337) and `_toIsolate` null → the guard catches it — UNLESS a start is in flight (`_starting != null`) — then synthesize proceeds, enqueues, `_pump` no-ops (port null), and awaits the completer — when the start finishes ok, `_pump` at 179 drains — fine; when the start fails, `_start`'s !ok branch calls stop() which drains the queue — fine. But if the start's ready never resolves and the 150s timeout fires → stop drains — fine. What if `_starting` is non-null but the underlying start already returned false and `_starting` was cleared? Covered. One more: synthesize enqueues while `_toIsolate == null && _starting != null` — if that start was started BEFORE a stop (epoch mismatch) and its whenComplete clears `_starting` only if identical — stop nulled `_starting` then a NEW ensureStarted set a new one — the doomed start's whenComplete sees `_starting` != f → does NOT clear — correct (the new start owns it). The doomed start's `_start` returns false at 114-119 WITHOUT draining the queue — requests enqueued during the doomed start (with `_starting` = the doomed f, guard at 213 passes since `_starting != null`) sit in `_queue` — but the NEW start (the one that replaced `_starting`) will eventually ready → `_pump` drains them — fine. If the new start ALSO fails → its stop drains — fine. OK, no hang path found. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:78-82 — `f = _start().whenComplete(...)` — `whenComplete` returns a future that completes with the SAME value — but if `_start` THROWS (async throw), `f` completes with the error — `ensureStarted` returns `f` — callers awaiting get the throw — but `ensureStarted`'s contract is `Future<bool>` — a thrown non-bool error violates the contract; callers doing `if (await ensureStarted())` would rethrow — acceptable? The declared type is Future<bool> but a runtime throw of type Object escapes — Dart doesn't enforce. Minor contract smell — no finding (no observable defect without a caller).
- [medium] lib/data/services/kokoro_onnx_service.dart:40-42 — frame_stats `_report` guard `_buildMs.isNotEmpty` — if timings list is empty for the whole window (no frames — app idle), `_report` never fires and `_windowStart` never advances — the NEXT window's `now.difference(_windowStart)` keeps growing until frames arrive — then it reports with the OLD window start (secs inflated) — cosmetic mis-report ("in 600s") — low cosmetic — no finding (info-level at best; skip).
- [medium] lib/data/services/frame_stats_service.dart:16 — `_reportEvery = 30s` — matches doc. — no finding.
- [medium] lib/data/services/frame_stats_service.dart:33-34 — `buildDuration`/`rasterDuration` in ms via microseconds/1000 — fine.
- [medium] lib/data/services/frame_stats_service.dart:37 — `t.totalSpan.inMicroseconds > 16700` — 16.7ms threshold — matches doc. — no finding.
- [medium] lib/data/services/frame_stats_service.dart:45-46 — `_pct(sorted, p)` — `((sorted.length - 1) * p).round()` — for p=0.99 and length=1 → 0 — fine; length=2 → (1)*0.99=0.99→1 — fine; length=3 → 2*0.99=1.98→2 — fine; length=101 → 100*0.99=99 — fine. Max index = round((len-1)*0.99) ≤ len-1 for all len? (len-1)*0.99 ≤ len-1 always; round could push to len-1 + 0.5? (len-1)*0.99 = len-1 - 0.01(len-1); for len-1=1 → 0.99 → round 1 = len-1 — ok; for len-1=50 → 49.5 → round 50 (banker's? Dart round is round-half-away-from-zero → 50) = len-1 — ok; for len-1=150 → 148.5 → 149 ≤ 149 — ok. Never exceeds len-1 since (len-1)*0.99 < len-1 + 0.5 requires 0.01(len-1) > -0.5 — always true. Safe. — no finding.
- [medium] lib/data/services/frame_stats_service.dart:51-52 — `List<double>.of(_buildMs)..sort()` — copies then sorts — fine.
- [medium] lib/data/services/frame_stats_service.dart:55 — `(100 * _jank / n)` — n from `_buildMs.length` — but `_jank` counts frames with totalSpan > 16.7ms across ALL timings in the window — same population — consistent. — no finding.
- [medium] lib/data/services/frame_stats_service.dart:61-64 — reset `_windowStart = now` — next window starts at the report time — fine.
- [medium] lib/data/services/frame_stats_service.dart:28 — `SchedulerBinding.instance.addTimingsCallback(_onTimings)` — the callback signature `void Function(List<FrameTiming>)`? addTimingsCallback expects `void Function(List<FrameTiming>)`? Actually Flutter's addTimingsCallback takes `TimingsCallback = void Function(List<FrameTiming>)` — matches. — no finding.
- [medium] lib/data/services/frame_stats_service.dart:31 — `_onTimings` runs on the UI isolate via scheduler callbacks — `_report` calls `DebugLogService.instance.log` which does `_appendSync` → synchronous file write on the UI isolate every 30s — a small append — acceptable (documented in debug_log_service as intentional). — no finding.
- [medium] lib/data/services/frame_stats_service.dart:14 — `static final instance = FrameStatsService._()` — singleton — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:34 — singleton — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:43-45 — `_queue`, `_inFlight`, `_nextSeq` — instance fields on a singleton — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:191-252 — synthesize is not reentrant-safe under concurrent calls? All state mutations are on the same isolate (main) — sequential — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:232 — `_cancelBelow.value = req.seq` — writes a raw FFI Int32 from the main isolate while the background isolate may read concurrently — torn reads impossible for aligned 32-bit — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:395 — `Pointer<Int32>.fromAddress(args.cancelBelowAddr)` — if the address is bogus (main side always passes a valid calloc address) — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:417 — `args.sendPort.send({'initError': ...})` then `return` — the isolate's `_isolateMain` returns — but `commands` ReceivePort (393) was created and NEVER closed in this path — the isolate lingers with an open port until killed — stop's kill handles it; if stop is never called (engine failed + no stop), the isolate leaks with an open port — `_start`'s !ok path calls stop() (176) which kills — covered. But the initError path: main side receives initError → ready.complete(false) → ok=false → stop() → kill — fine. — no finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:420 — `args.sendPort.send(const {'ready': true});` — const map literal — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:432 — `args.sendPort.send({'seq': seq, 'aborted': true});` — non-const map — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:473 — `{'seq': seq, 'path': path}` — path is a String — sendable — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:475 — `{'seq': seq, 'error': '$e'}` — stringified error — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:139 — `req.completer.complete(null)` on error — callers get null — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:143 — `msg['path'] as String?` — if the isolate sends a map without 'path' in the non-error non-aborted branch — it always includes path (473) — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:135 — `req.seq == msg['seq']` — msg['seq'] is int — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:146 — `_pump()` after handling — sends next queued — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:127-128 — `ready.complete(true)` — but `ready` is a `Completer<bool>` captured in `_start`'s scope — the listener closure captures it — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:166 — `if (!ready.isCompleted) ready.complete(false);` — onDone — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:153 — onDone's epoch check: `if (epoch != _epoch) return;` — if stop ran, onDone returns WITHOUT failing pending requests — but stop itself fails them (344-348) — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:160 — `inFlight.completer.complete(null)` guarded by `!isCompleted` — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:162 — queued completers guarded — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:165 — `_toIsolate = null` — after this, `isRunning` false — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:342 — `_isolate?.kill(priority: Isolate.beforeNextEvent)` — see the native-free finding.
- [medium] lib/data/services/kokoro_onnx_service.dart:338 — `_toIsolate?.send(const {'cmd': 'dispose'})` — const map with one entry — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:340 — `await _sub?.cancel()` — cancels the fromIsolate listener — after cancel, late isolate messages (e.g. a response racing dispose) are dropped — pending completers already failed by stop — fine.
- [medium] lib/data/services/kokoro_onnx_service.dart:336-337 — `_epoch++; _starting = null;` — a concurrent ensureStarted between these could set `_starting` to a NEW future which this stop does not cancel — the new start proceeds and may attach a NEW isolate — but stop continues: `_toIsolate?.send(dispose)` — `_toIsolate` is still the OLD port (the new start hasn't set it) → dispose goes to the old isolate — correct. The new start's isolate spawns later and sets `_isolate`/`_toIsolate` — but stop's remaining steps (340-343) cancel the OLD `_sub` and kill the OLD `_isolate` — the new start's `_sub`/`_isolate` are set AFTER stop's teardown? Race: stop's `await _sub?.cancel()` yields; the new start's `Isolate.spawn` completes and sets `_isolate = spawned` (120) and `_sub = fromIsolate.listen(...)` (122) — then stop resumes: `_sub = null` (341) — WIPING the new start's subscription reference (the subscription itself still lives and delivers messages, but the field is null → `_sub?.cancel()` in a FUTURE stop won't cancel it; and `_sub` null means the new start's listener is orphaned-but-alive — messages still processed via the closure). Worse: stop resumes to `_isolate?.kill(...)` — `_isolate` now holds the NEW isolate → stop KILLS the new start's isolate! Then the new start's `ready` never completes? Its listener was killed → onDone fires → ready.complete(false) → new start fails → its stop drains. So the new start fails spuriously due to the racing stop. Is this reachable? stop() and ensureStarted() racing — e.g. user toggles a setting that stops TTS while a prefetch triggers ensureStarted. The epoch guard in `_start` (87, 114) protects the OLD start, but the NEW start (created after `_epoch++`) has a fresh epoch equal to the current `_epoch` — stop's teardown at 340-343 doesn't re-check epoch — it kills whatever `_isolate` currently points to. This is a real race: stop() should capture `_isolate`/`_sub`/`_toIsolate` into locals at entry (before any await) and tear down the captured ones, not
- [medium] lib/data/services/live_asr_service.dart:111-121 — `_start` awaits `ready.future` with a 30s timeout that resolves to `false`, but when `ok` is false the code calls `await stop()` and then still returns `ok` (false) — however when the timeout fires while the isolate is still loading, `stop()` bumps `_epoch` and kills `_isolate` which may still be null (spawn succeeded but ready never arrived), leaving `_toIsolate` non-null from the isolate's SendPort message racing the cancel — consequence: a slow model load can leave the service half-torn-down with `isRunning` true but no working recognizer, and `ensureStarted` returns false so callers may retry while the stale isolate still consumes PCM — smallest safe fix: on timeout, send `{'cmd':'dispose'}` to the isolate's command port (captured from the ready message) before killing, and only return after `_fromIsolateSub` cancel completes.
- [medium] lib/data/services/live_asr_service.dart:93-109 — the main-isolate listener treats any `SendPort` instance as the command port, but `Isolate.spawn` delivers the spawned isolate's control/control-event messages as `SendPort`-shaped objects only for explicit port sends; a `Map` message arriving before the port message (e.g. an early error) is silently dropped by the `msg is SendPort` branch ordering — consequence: an init error sent before the command port is registered is lost and `ready` never completes, so `ensureStarted` hangs 30s then reports failure with no logged cause — smallest safe fix: buffer non-port messages until the command port is captured, or have `_isolateMain` send the port first and errors after (it already does — but the listener should log unknown message types instead of ignoring them).
- [low] lib/data/services/live_asr_service.dart:227 — `uid = msg['uid'] as int? ?? uid + 1;` — when the 'start' command carries no uid (or a non-int), the isolate falls back to incrementing its local uid, which can desynchronize from the main isolate's `_uid` epoch tag — consequence: partials from a stale utterance can pass the `msg['uid'] == _uid` check at line 104 and be surfaced for the wrong line — smallest safe fix: require the uid (`msg['uid'] as int`) and ignore a 'start' command without one.
- [low] lib/data/services/live_asr_service.dart:135 — `endUtterance` sends `{'cmd':'end'}` but the isolate's 'end' case (229-235) feeds a fixed 12800-sample silence buffer regardless of the actual sample rate or remaining audio — consequence: on a 16 kHz stream this is 0.8s as documented, but the hard-coded constant silently mis-pads if the capture rate ever changes, truncating line tails — smallest safe fix: derive the padding length from the configured sample rate constant shared with the capture service.
- [low] lib/data/services/live_asr_service.dart:200-207 — `decodeAndReport` loops `while (recognizer.isReady(stream)) decode(stream)` with no chunk cap; a long utterance with many buffered chunks can spin the isolate CPU-bound and delay the 'dispose' command handling — consequence: stop() at line 147 kills with `Isolate.beforeNextEvent`, which is safe, but during normal operation a burst of PCM can starve command processing for seconds — smallest safe fix: bound the decode loop per message (e.g. max N decodes) and re-check the command queue.
- [low] lib/data/services/live_asr_service.dart:139-148 — `stop()` sends `{'cmd':'dispose'}` then immediately cancels `_fromIsolateSub` and kills `_isolate` with `beforeNextEvent`; the isolate's `commands.close()`/`return` at 240-241 never confirms, and native `recognizer.free()` may run after the kill — consequence: on some platforms the native memory free is skipped (leak) because `beforeNextEvent` can preempt the isolate before it processes dispose — smallest safe fix: send dispose, then kill with `Isolate.immediate` only after a short delay or an ack message; or rely on the isolate's own exit and skip the kill.
- [info] lib/data/services/live_asr_service.dart:62 — `ModelDownloadService.instance.getLiveAsrModelDir()` is assumed to return a local, user-scoped directory; nothing in this file exposes it — no finding.
- [medium] lib/data/services/media_control_service.dart:78-94 — `_handleNativeCall` maps the native command string to handlers, but `case 'jumpBack':` (82) falls through into `case 'playPause':` (83-89) because there is no `break` before the shared body — consequence: a genuine 'jumpBack' command from the platform invokes `onPlayPause` instead of `onJumpBack`, so AirPod double-tap-left jumps the wrong way / pauses instead of rewinding — smallest safe fix: add `break` (or a dedicated body) after `case 'jumpBack':` and give jumpBack its own `onJumpBack?.call()`.
- [medium] lib/data/services/media_control_service.dart:24-44 — `activate()` sets callbacks and the method handler before `invokeMethod('activate')`; if the invoke throws something other than `MissingPluginException` (e.g. PlatformException), the exception propagates with `_active` still false but handlers registered — consequence: native side may still deliver calls that hit null callbacks (no-ops) while the caller believes activation failed — smallest safe fix: wrap the whole body or reset callbacks/handler in a catch-all.
- [low] lib/data/services/media_control_service.dart:47-60 — `deactivate()` nulls the callbacks before checking `_active`; if `!_active` it returns early having already cleared them — consequence: a later re-activate that fails at invoke leaves stale cleared callbacks and `_active` false, which is consistent, but a deactivate while active clears callbacks then invokes 'deactivate' — if the invoke throws non-MissingPluginException the native side still thinks it's active while Dart side is torn down — smallest safe fix: catch broadly or invoke first, then clear.
- [low] lib/data/services/media_control_service.dart:63-76 — `updateNowPlaying` silently returns when `!_active` (67) — a caller updating metadata before activate() loses the update with no log — consequence: lock screen shows stale/empty Now Playing with no diagnostic — smallest safe fix: log via DebugLogService when dropping the update, or queue it.
- [info] lib/data/services/media_control_service.dart:15 — hardcoded MethodChannel name matches the native plugin contract assumed by the platform side; not verifiable here — no finding.

## Coverage
lib/data/services/live_asr_service.dart — findings: 6
lib/data/services/media_control_service.dart — findings: 5
- [medium] lib/data/services/model_download_service.dart:242-244 — native callback casts `call.arguments as Map` and reads `args['modelId'] as String` without null/type guards — a malformed or missing payload from the platform side throws inside the method-call handler, leaving `_states[modelId]` stale (e.g. a download that actually finished never flips to `downloaded`, so Settings keeps showing "downloading" and `_tryLoadKokoroIfReady` never fires) — wrap in `Map<String, dynamic>?` with null checks and bail via the `onDownloadError` path. Reachability: any authenticated user whose device receives a malformed platform reply (operator/device-local, not internet-reachable from this code alone).
- [medium] lib/data/services/model_download_service.dart:253-255 — same unguarded `as Map` / `as int` cast pattern on `onDownloadComplete` (`args['size'] as int`) — a null `size` crashes the handler mid-completion, so the verified-download branch at 263-285 never runs and the file is treated as missing on next refresh — same guard fix as above.
- [medium] lib/data/services/model_download_service.dart:294-296 — same pattern on `onDownloadError` (`args['error'] as String`) — an error event with no message string throws, masking the real failure and leaving the model stuck in `downloading` — same guard fix.
- [medium] lib/data/services/model_download_service.dart:264-266 — `onDownloadComplete` verifies the file via `_verifyDownload(model)` but on verification failure only records an error state; the bad file is deleted inside `_verifyDownload` (416-423) yet the native side is never told the download failed, so a retry of `download()` sees `_states` in `error` and re-runs `startDownload` while the native URLSession may consider the task already complete — add an explicit `invokeMethod('cancelDownload', ...)` or reset the native task before re-issuing `startDownload`. Reachability: authenticated user retrying a failed download on their own device.
- [low] lib/data/services/model_download_service.dart:331 — truncation floor uses `model.sizeBytes ~/ 2` only when `exactSizeBytes == null`, but every model in this file pins `exactSizeBytes`, so the floor branch is dead code; if a future model omits the pin the floor silently accepts a file half the expected size (e.g. a 70 MB encoder replaced by a 35 MB truncated one) — either drop the branch or document why it exists; as written it is a permissive fallback that resolves to "accept" when the expected state (exact size) is missing.
- [low] lib/data/services/model_download_service.dart:515-535 — free-space preflight: when `_freeDiskSpaceBytes` returns null the code logs and proceeds ("free space unknown … starting without a space preflight") — the permissive direction is intentional and logged, but on iOS/macOS statvfs failure (813 returns null on error) a genuinely full disk proceeds to a 2.5 GB download that fails at 99% after burning the user's data — consider treating repeated null results on supported platforms as a soft warning to the user rather than silent proceed.
- [low] lib/data/services/model_download_service.dart:803-812 — `utf8.encode(path)` then `malloc(pathBytes.length + 1)` and `setAll(0, pathBytes)` writes the UTF-8 bytes but the NUL terminator is written via `..[pathBytes.length] = 0` on a list of length `pathBytes.length + 1` — correct, but `buf.asTypedList(bufBytes).fillRange(0, bufBytes, 0)` zeroes only `bufBytes` while `statvfs` reads a 64-byte struct on Darwin; if the Darwin `struct statvfs` is larger than 128 B (comment says 64 B "room to spare") the sanity checks at 822 read garbage — the guard at 822 mitigates, but the layout is asserted only by comment, not by `sizeof` — acceptable as-is; flagging only because a wrong `f_frsize`/`f_bavail` pairing would silently mis-size the headroom check.
- [low] lib/data/services/model_download_service.dart:612-614 — redirect loop decrements `redirectsLeft` before the scheme check throws, so a redirect chain that ends in a non-HTTPS hop consumes the budget and the error message says "Too many redirects" instead of the real cause on the next iteration — reorder: check scheme/Location before decrementing.
- [low] lib/data/services/model_download_service.dart:655-658 — `await sink.flush()` inside `try` with `finally { await sink.close(); }` — if `flush` throws, `close` still runs (good), but the outer `catch` at 677 deletes `tmpFile` while the sink may still hold an open handle on some platforms, making the delete a no-op and leaving a partial `.tmp` that `refreshDownloadedStatus` later reports as "present but unusable" — close the sink before the delete path (or use `sink.done()`).
- [low] lib/data/services/model_download_service.dart:226-229 — `addListener`/`removeListener` mutate `_listeners` while `_notify` (232-235) iterates it — a listener that removes itself (or adds another) during notification skips/duplicates callbacks — iterate over a copy (`List.of(_listeners)`) or use a `UnmodifiableListView` snapshot.
- [low] lib/data/services/model_download_service.dart:341 — `refreshDownloadedStatus` skips re-checking models whose state is `downloading`, but a download that finished while the app was suspended leaves a stale `downloading` state forever (no native callback fires after resume) — add a resume/app-lifecycle hook that re-runs the check for stuck `downloading` entries, or drop the skip and let `fileProblem` decide.
- [info] lib/data/services/model_download_service.dart:122-123,143-144,165-166,179-180,193-194,207-208 — pinned SHA-256 literals for release/HF assets are inlined in source; they are public artifact hashes, not secrets, but confirm none of the surrounding release tooling embeds a token — verify it is not committed (no secret-looking value beyond public model hashes is exhibited).
- [medium] lib/data/services/model_manager.dart:296-298 — `_downloadFile` sets `acceptEncodingHeader` to `identity` but never checks the response's actual `Content-Encoding`; if the server gzips anyway (as the comment at 293-296 admits happened for tokens.txt), the bz2 archive bytes on disk are gzip-wrapped and the sha256 check at 205-215 fails with a confusing "tampered" error instead of a clear "server ignored identity" message — log the response's `contentEncodingHeader` when non-null/identity-mismatched so the failure names the real cause.
- [medium] lib/data/services/model_manager.dart:301-333 — non-200 handling: for 302/301/307 the code reads `location` and recurses, but for any other non-200 (e.g. 404 from a moved release tag) it drains and throws a generic "Download failed: HTTP ${statusCode}" without the URL in the message at 333 — include `url` in the thrown message so operators can tell which asset moved.
- [low] lib/data/services/model_manager.dart:327-328 — recursive `_downloadFile(target.toString(), localPath, onProgress, redirectsLeft: redirectsLeft - 1)` re-enters with the same `localPath`; if the redirect chain crosses a content-length mismatch the tmp file from the previous hop is not cleaned before the new attempt writes over it — minor, but a failed hop leaves a stale `.tmp` that the next successful download's `file.parent.create` does not remove.
- [low] lib/data/services/model_manager.dart:185-186 — stale-archive cleanup `catch (_) {}` swallows all errors silently; combined with the `finally` delete at 228-230 the same swallow means a permission-denied delete leaves the ~180 MB archive in temp forever — log the failure at debug level at minimum.
- [low] lib/data/services/model_manager.dart:245-266 — `_extractArchiveStreaming` uses `Directory.systemTemp.createTempSync('lineguide_extract')` and deletes in `finally`, but `BZip2Decoder().decodeStream(input, output)` is synchronous inside `compute` — a multi-hundred-MB tar write inside the isolate holds the isolate busy; acceptable per design comment, but if `tempDir.deleteSync` throws the `catch (_) {}` at 264-266 leaks the decompressed tar (the comment at 262-263 says this used to happen) — the swallow is still present; log it.
- [low] lib/data/services/model_manager.dart:109-113 — `downloadKokoro` calls `onProgress?.call('kokoro', 1.0)` and returns when `isKokoroReady()`, but when not ready it calls `onProgress?.call('$_kokoroModelName.tar.bz2', 0)` and then `_downloadAndExtractArchive` whose own `onProgress` wrapper (119) forwards only the archive-download phase; the extraction phase's `onProgress?.call(0.85)` at 219 and `1.0` at 233 are forwarded through the same lambda, so progress can jump 0 → 0.8 → 0.85 → 1.0 with no intermediate extraction granularity — cosmetic; no fix required beyond documenting.
- [info] lib/data/services/model_manager.dart:42-43 — `_kokoroArchiveSha256` is a public release-asset hash literal, not a secret; verify it is not committed alongside any token-bearing release config (no secret-looking value beyond the public hash is exhibited).

## Coverage
lib/data/services/model_download_service.dart — findings: 11
lib/data/services/model_manager.dart — findings: 7
- [medium] lib/data/services/ocr_confidence_service.dart:247-273 — scoreScript mutates shared singleton state (_wordValidCache cleared, _whitelist rebuilt) with no synchronization — two concurrent imports (e.g. isolate + main isolate via setTheatricalVocab, or two imports racing) can interleave, leaving a word whitelisted by a previous script still "valid" for the next script and producing wrong review verdicts; the doc comment at 251-254 itself names this failure mode — serialize scoreScript/ensureVocabLoaded/setTheatricalVocab behind a lock or per-import service instance.
- [medium] lib/data/services/ocr_confidence_service.dart:117-149 — _buildWhitelist adds every word occurring ≥3 times to the whitelist, and _isValidWord treats whitelisted words as valid BEFORE the dictionary check — a repeated OCR error (e.g. a garbled proper noun appearing 3+ times) is scored "correct", inflating dictNew and pushing genuinely-bad lines out of the "review" bucket; require the word to also pass the dictionary/vocab check or cap whitelist entries to known-name parts only.
- [low] lib/data/services/ocr_confidence_service.dart:66-71 — _ensureLoaded registers the language twice (registerLan('en') then registerLan('en-gb')) and never guards re-registration after dispose() calls removeLan() — a second load after dispose re-registers while _checker is rebuilt, doubling dictionary memory; guard with a registered flag or drop the redundant en-gb registration.
- [low] lib/data/services/ocr_confidence_service.dart:104-111 — dispose() clears _theatricalVocab and resets _vocabLoadAttempted, so after dispose the previously-injected vocab (setTheatricalVocab, used by the background-isolate scorer per the doc at 93-94) silently disappears and ensureVocabLoaded must re-attempt a rootBundle load that the isolate cannot do — keep the injected vocab across dispose or document that dispose invalidates isolate scoring.
- [low] lib/data/services/ocr_confidence_service.dart:187-198 — _isValidWord dereferences _checker! without a null guard; if scoreScript/scoreLine is called after dispose() (checker nulled at 106) the closure throws on the first uncached word — null-check _checker and return false (fail closed) instead of crashing.
- [low] lib/data/services/ocr_highlight_matcher.dart:44-56 — _containsWord loops `while (true)` with `from = i + 1`; when needle occurs at overlapping positions the loop terminates correctly, but if haystack is empty and needle empty the indexOf('') returns 0 forever — guard needle.isEmpty/haystack.isEmpty up front to avoid an infinite loop on degenerate input.
- [low] lib/data/services/ocr_highlight_matcher.dart:96-149 — locate() builds targetTokens/consumed/remaining as Set<String> from split(' ') but never filters empty tokens; a normalized target with a trailing space yields an '' token that inflates intersection counts and can push a weak match past the 0.45 gate — filter empties when building the token sets.
- [info] lib/data/services/ocr_confidence_service.dart:88 — debugPrint of raw exception text on vocab load failure may leak asset-path/IO error details into release logs — log a static message and keep details behind kDebugMode.

## Coverage
lib/data/services/ocr_confidence_service.dart — findings: 6
lib/data/services/ocr_highlight_matcher.dart — findings: 2
- [info] test/cast_member_test.dart:139 — test asserts `generateJoinCode` returns a 6-character string but never asserts the production symbol it should pin (the alphabet/length constant lives in `SupabaseService`, not inlined here) — if the production generator's length or alphabet ever changes, this test still passes because it only checks the local literal `6` and the local `validChars` string it defines itself — assert against the production constant (e.g. `SupabaseService.joinCodeLength` / `SupabaseService.joinCodeAlphabet`) or a named production symbol instead of local literals
- [info] test/cast_member_test.dart:143-152 — test defines its own `validChars` constant locally and asserts the generated code against it — this is a test asserting a literal/local constant, which proves nothing about the production alphabet if the production alphabet drifts — name the production symbol (e.g. `SupabaseService.joinCodeAlphabet`) and assert against that
- [info] test/cast_member_test.dart:155-162 — uniqueness test asserts `greaterThan(95)` on a set built from 100 draws of a 6-char/32-symbol alphabet — the expected collision rate is astronomically low, so this assertion can never meaningfully fail and hides a regression to a shorter alphabet or a smaller draw space — assert the exact expected distribution or pin the alphabet/length via the production constant instead
- [info] test/cast_member_test.dart:164-172 — "never contains ambiguous characters" test asserts against the literals `'I'`, `'O'`, `'0'`, `'1'` defined in the test itself — the production alphabet is not inlined here, so this cannot detect a drift where the production alphabet adds an ambiguous char while the test's local list stays stale — assert against the production alphabet constant (e.g. `SupabaseService.joinCodeAlphabet`) that it excludes those characters
- [low] test/cast_member_test.dart:100-134 — `Production` model tests construct instances with `DateTime.now()` at lines 117, 128 — using wall-clock time in a model-constructor test makes the assertion time-dependent and can flake across midnight/timezone boundaries — use a fixed `DateTime` literal like the other tests (e.g. `DateTime(2026, 3, 15)`) so the test is deterministic
- [info] test/analytics_route_observer_test.dart:46 — observer is constructed with `logScreenView: logged.add` — the test relies on `AnalyticsRouteObserver` from `package:castcircle/app.dart` (line 1) whose implementation is not inlined, so the assertions here cannot be verified against the production observer's actual filter/guard logic — this is stated as an assumption, not asserted as a defect; if the production observer's `PageRoute` filter or null-name guard differs from what these tests assume, the tests would silently pass while the shipped behavior diverges — request the production `AnalyticsRouteObserver` source to confirm the filter matches the assumptions documented at lines 8-16 and 61-63, 119

## Coverage
test/analytics_route_observer_test.dart — findings: 1
test/cast_member_test.dart — findings: 5
- [low] test/character_gender_persistence_test.dart:27 — setUp uses SharedPreferences.setMockInitialValues({}) but VoiceConfigService.instance is never reset between tests — state from the 'a gender saved for one production survives a rebuild' test (p1/HAMLET=female) can leak into the 'choices are scoped to their production' test, making the isNull assertion pass for the wrong reason or flake depending on service caching — reset the service instance (or clear its backing store) in setUp before each test.
- [low] test/character_gender_persistence_test.dart:50-75 — tests depend on VoiceConfigService.instance singleton whose backing storage is not shown; if it persists beyond the test process (e.g., real SharedPreferences mock is fine, but any file-backed store would not be) the production-scoping assertions could read stale cross-run state — verify the service is in-memory/mock-backed; if not, inject a fresh store per test.

## Coverage
test/cast_role_test.dart — clean
test/character_gender_persistence_test.dart — findings: 2
- [low] test/demo_production_service_test.dart:31 — tearDown closes the in-memory database but setUp creates a fresh one per test while tearDown's async callback returns a Future that the framework may not await before the next setUp — potential flaky 'database is closed' or leaked connection between testWidgets cases — make tearDown fully synchronous (`tearDown(() { db.close(); })`) or await inside a properly awaited callback
- [low] test/demo_production_service_test.dart:84-85 — the two `load()` calls are awaited sequentially but the test never asserts the first load's production id before the second, so a failure in the first load surfaces only as a misleading 'demos != 1' assertion — add an explicit expect on the first load's result before the second call
- [info] test/demo_production_service_test.dart:27 — `SharedPreferences.setMockInitialValues({})` is re-invoked in setUp after the third test already seeded a value at line 95-97; mock initial values are global static state, so the reset in setUp is what keeps tests isolated — verify the reset happens before every test (it does here) and that no test relies on values set outside its own body
- [low] test/cloud_sync_dialog_test.dart:48 — the 'added' case builds the local line with default `text: 'Hello'` while the cloud counterpart also defaults to 'Hello', so the unchanged/add distinction rests on the helper's default rather than an explicit assertion of differing content — pass explicit texts to make the intent of each diff type unambiguous

## Coverage
test/cloud_sync_dialog_test.dart — findings: 1
test/demo_production_service_test.dart — findings: 3
- [low] test/demo_script_test.dart:16-21 — test depends on a generated asset file (`assets/demo/hamlet_demo.txt`) and a Python generator script (`scripts/make-demo-script.py`) that are not present in this batch — if the asset is missing or stale, `setUpAll` fails before any test runs, masking regressions in the import service — verify the asset is committed and regenerated in CI, or inline a minimal fixture in the test.
- [low] test/demo_script_test.dart:57-69 — the gender expectation table is a local constant duplicated from the demo asset; if the asset's cast changes, the test fails with a reason string telling the maintainer to update the expectation, but nothing asserts the table against the production source of truth — assert against the parsed script's own gender field or a shared constant instead of a hand-copied map.
- [info] test/dialog_navigation_test.dart:90-96 — comment documents a known production crash ("No GoRouter found in context") that is intentionally not asserted because debug/test builds take a different code path; the positive test at lines 69-88 locks in the fix but no regression guard exists for the anti-pattern itself — acceptable given the stated environment-dependence, but consider a release-mode integration test if the crash resurfaces.

## Coverage
test/demo_script_test.dart — findings: 2
test/dialog_navigation_test.dart — findings: 1
- [low] test/espeak_heteronyms_test.dart:59-61 — `available` is computed via `Process.runSync('which', ['espeak-ng'])` at group setup; on Windows `which` does not exist and `runSync` throws instead of returning a non-zero exitCode, so the whole group crashes rather than skipping — guard with try/catch or use `where`/platform check — wrap the probe in a try/catch and treat failure as "not installed".
- [low] test/espeak_heteronyms_test.dart:70 — `saysLong` treats any occurrence of the substring 'aɪv' as the wrong reading, but the correct IPA for words like "five" or "hive" also contains 'aɪv'; if the test corpus ever includes such words the assertion flips meaning — match the specific token context or assert on the full transcription of the sample line.
- [info] test/espeak_heteronyms_test.dart:59-61,63-67 — the espeak-ng probe and IPA assertions shell out to an external binary whose output is locale/version dependent; CI results can differ across machines — pin the espeak-ng version or assert on stable substrings only. (No action needed beyond awareness.)
- [low] test/home_screen_logic_test.dart:26-35 — the "returns true only for the same production" test asserts a single positive case; the helper's contract (e.g., behavior when `currentScript` is non-null but `lines` empty is covered, but a script whose `lines` are non-empty yet `characters`/`scenes` empty is not) is only partially exercised — add a case with populated lines but empty characters/scenes if the helper requires those too. (Assumption: helper semantics unknown from this file alone.)
- [low] test/home_screen_logic_test.dart:7-24 — `populatedScript` is declared `const` with a single line whose `character`/`text` are minimal; if `shouldReuseLoadedScript` ever checks more than `lines.isNotEmpty` (e.g., requires `characters` non-empty), the positive test would silently keep passing with a weaker fixture — verify against the helper's implementation; if it only checks `lines`, no change needed. (Assumption: helper body not inlined.)

## Coverage
test/espeak_heteronyms_test.dart — findings: 3
test/home_screen_logic_test.dart — findings: 2
- [low] test/model_download_gzip_test.dart:47 — tearDown closes the server but the `serve` helper's `HttpServer.bind` listener is never awaited/closed between tests that each bind a new server on port 0 — consequence: leaked sockets can keep the test process alive or flake on CI — smallest safe fix: track all bound servers and close each in tearDown, or reuse one server for the whole suite.
- [low] test/model_download_gzip_test.dart:69 — `client.close()` is called without `await`/`close()` on the HttpClient before the response body stream is fully drained in the error path — consequence: if `download` throws mid-stream the HttpClient socket leaks per test — smallest safe fix: wrap the body drain in try/finally and `await client.close()` in the finally block.
- [info] test/model_download_gzip_test.dart:96-107 — the test asserts `ModelDownloadService.fileProblem` behavior against `availableModels` fixtures but the referenced service/model symbols are not inlined in this batch — consequence: the size-check regression claim cannot be verified from the shown code alone — smallest safe fix: none needed here; confirm the referenced symbols exist in the service file.

## Coverage
test/model_download_gzip_test.dart — findings: 3
test/model_manager_test.dart — clean
## Coverage
test/models_test.dart — clean
test/ocr_cleanup_test.dart — clean
- [low] test/ocr_confidence_test.dart:14-15 — setUp injects a theatrical vocab but tearDown(service.dispose) at line 17 disposes the singleton without re-initializing it, so any test that runs after a tearDown failure or that relies on the service's dictionary state across groups depends on dispose semantics that are not shown here — if `dispose` clears the loaded dictionary, subsequent groups in this file still pass only because each test re-sets the vocab or uses dictionary words; if a later group (e.g. 'scoreScript bookkeeping' at 165-181) runs after dispose without a fresh setUp, its `ok` classification could silently depend on residual state — smallest safe fix: have tearDown restore a pristine service (or construct a fresh instance per test) rather than disposing a shared singleton. (Reachability: test-only code.)

- [low] test/ocr_confidence_test.dart:35,42,47,51,55,60,66,71,77,81,88 — every tokenizer/diacritic/vocab assertion pins the exact literal `1.0` (or `closeTo(0.5, 0.01)`) produced by the inlined service under test; none of these tests assert against a production symbol or a documented constant, so a regression that silently clamps all scores to 1.0 (e.g. a scoring bug that returns the constant) would still pass this suite — smallest safe fix: add at least one negative-control assertion (e.g. a garbled line must score < 1.0) in the tokenizer group so the 1.0 expectations can actually fail. (Reachability: test-only code.)

- [info] test/ocr_confidence_test.dart:134 — the test asserts display confidence `closeTo(1.0, 0.001)` for a clean line, which documents that display confidence is derived from the dictionary signal rather than recConf; this is a behavioral contract worth confirming against `OcrConfidenceService` (not inlined here) — verify the production implementation actually replaces, not blends, recConf into the displayed value. (Reachability: test-only code.)

## Coverage
test/ocr_confidence_mapping_test.dart — clean
test/ocr_confidence_test.dart — findings: 3
- [low] test/ocr_highlight_hitrate_test.dart:14 — test reads a fixture file synchronously with no existence check — if `test/fixtures/pp_ocr_raw.txt` is missing the test throws a raw FileSystemException instead of a meaningful assertion failure, and if it is empty the loop still runs with `attempted == 0` making `hit / attempted` a division-by-zero producing NaN that silently fails the `greaterThan(0.90)` expectation with a confusing message — guard with `expect(rawLines, isNotEmpty)` / `expect(attempted, greaterThan(0))` before computing the rate — reachability: operator running CI (low).
- [low] test/ocr_highlight_hitrate_test.dart:72 — `hit / attempted` is computed with no guard against `attempted == 0` — when the fixture contains only blank lines (all lines skipped by the `continue` at line 31/45) the rate is NaN and the test reports a misleading failure rather than "no lines to score" — assert `attempted > 0` before the division — reachability: operator running CI (low).
- [low] test/ocr_highlight_hitrate_test.dart:65-69 — the miss log is capped at 8 entries (`misses.length < 8`) so a regression that breaks many lines reports only the first 8, hiding the scale of the failure from CI output — raise the cap or log the total count separately — reachability: operator running CI (low).
- [info] test/ocr_highlight_hitrate_test.dart:84-85 — the 0.90 hit-rate threshold is asserted only via `expect(rate, greaterThan(0.90))` with no assertion that `offBy`/`nowhere` stay bounded, so a silent page-assignment drift (lines found on a nearby page) can pass while the "MISSES ... found on another page" counter grows — add an explicit bound on `near`/`nowhere` if the scorer contract requires it — reachability: operator running CI (low).
- [low] test/ocr_highlight_matcher_test.dart:42-43 — the "tiny fragments cannot false-match" test asserts only that `locate('a', page)` is empty; it never asserts the positive case for a short-but-real fragment, so a matcher that returns empty for ALL short strings (including legitimate ones) would pass — pair it with a positive short-fragment case or assert against a known production constant — reachability: test-only (low).

## Coverage
test/ocr_highlight_hitrate_test.dart — findings: 4
test/ocr_highlight_matcher_test.dart — findings: 1
- [low] test/ocr_page_mapping_distribution_test.dart:12 — test reads `test/fixtures/pp_ocr_raw.txt` via `readAsStringSync` with no existence/size guard — if the fixture is missing or huge, the test crashes or blocks the whole suite on a synchronous read — guard with a `skipUnless(File(...).existsSync())` or assert the fixture exists before reading.
- [low] test/ocr_page_mapping_distribution_test.dart:34-43 — assertions are self-referential to the test's own synthetic mapping (`i ~/ 40 + 1` over a fixture of unknown length) rather than to production `ScriptImportService` invariants — if the fixture shrinks to <~50 lines, `midPage`/`lastPage` bounds still pass trivially and the regression hides — assert against the fixture's actual line count or a production constant.
- [info] test/ocr_review_sheet_test.dart:33 — test passes a fake `pdfPath: '/tmp/does-not-exist.pdf'` — fine for tests, but if `OcrReviewScreen` ever treats a missing PDF as "no PDF" it silently diverges from production behavior; verify the screen's fallback direction matches production (permissive vs. safe) before shipping.

## Coverage
test/ocr_page_mapping_distribution_test.dart — findings: 2
test/ocr_review_sheet_test.dart — findings: 1
- [medium] lib/data/services/paddle_ocr_channel.dart:22,34,102,138 — static shared ValueNotifier `progress` mutated by every `ocrPdf` call — concurrent OCR runs (or a run racing a UI reset) overwrite each other's progress and the `finally` at :138 clears a notifier another caller may still be reading, so the "Reading page X of Y" UI can show another run's page or drop to null mid-run — make progress an instance field or key it by run id.
- [medium] lib/data/services/paddle_ocr_channel.dart:31-40 — `_ensureProgressHandler` installs the handler once and never re-installs after a hot-restart/test teardown resets the channel, and the handler silently ignores any method other than `ocrProgress` (returns null without error), so a native `ocrProgress` event after a handler reset updates nothing and the UI stays at "starting" (page 0/total 0 from :102) — guard with a re-installable handler or surface unexpected methods via `sendRequestException`.
- [low] lib/data/services/paddle_ocr_channel.dart:45-64 — `recognizeText` returns `[]` (not null) when the native reply lacks `blocks`, collapsing "no blocks" and "malformed reply" so callers can't distinguish plugin-absent (fall back to ML Kit) from empty-result — return null on malformed payloads or document the distinction.
- [low] lib/data/services/paddle_ocr_channel.dart:71-93 — `ocrPage` catches `PlatformException` and returns null, hiding real native errors (bad path, page out of range) as "plugin unavailable", which callers treat as fall-back-to-ML-Kit — rethrow non-`missing` codes or log the exception.
- [low] lib/data/services/paddle_ocr_channel.dart:135-136 — `ocrPdf` catches only `MissingPluginException`; a `PlatformException` from the native side propagates to the caller while `progress` is reset in `finally` — acceptable if callers handle it, but the asymmetry with `ocrPage` (:90) means one method hides native errors and the other doesn't; align behavior.
- [low] lib/data/services/pdf_text_channel.dart:21-24,42-47 — `extractText`/`extractTextPerPage` rethrow `PlatformException` codes other than `NO_TEXT` while `hasEmbeddedText` (:60-62) swallows every `PlatformException` as `false`, so a transient native error makes the caller conclude "image-only PDF, needs OCR" and take the slow/lossy OCR path silently — rethrow or log in `hasEmbeddedText` too.
- [low] lib/data/services/pdf_text_channel.dart:36-41 — `extractTextPerPage` returns null when `pages` is present but not a `List` (e.g. native sent a map/string), conflating "no embedded text" with "malformed reply" — cast/validate and surface the malformed case.

## Coverage
lib/data/services/paddle_ocr_channel.dart — findings: 5
lib/data/services/pdf_text_channel.dart — findings: 2
- [low] lib/data/services/perf_service.dart:31 — trace?.stop() in finally can throw if the trace failed to start, masking the operation's own exception — measure() could surface the wrong error to callers — wrap stop in its own try/catch or null-check before stop
- [low] lib/data/services/playback_session.dart:32 — catch (e) swallows all errors including MissingPluginException-style platform failures without distinguishing them, and the error is only logged, never rethrown — a silently failed audio reconfiguration leaves the shared AVAudioSession in `.record` category, producing the exact silent-playback defect the class exists to fix, with no user-visible signal — log with stack trace and consider surfacing a retry or at least a distinct error category
- [info] lib/data/services/playback_session.dart:27 — Platform.isIOS/isAndroid guard means desktop no-op is intentional per docstring; no defect
- [info] lib/data/services/perf_service.dart:10-11 — firebaseAvailable is not defined in this file; assumed imported from main.dart — if it throws when Firebase not initialized, startTrace's catch handles it, so no defect exhibited

## Coverage
lib/data/services/perf_service.dart — findings: 1
lib/data/services/playback_session.dart — findings: 1
- [medium] lib/data/services/recording_sync_service.dart:191-195 — `_saveManifest` snapshots `_cache` via `jsonEncode` inside the chained future, but `_cache.values.map(...).toList()` is evaluated lazily by `jsonEncode` while concurrent downloads (4-way pooled, lines 422-459) mutate `_cache[lineId]` mid-encode — concurrent modification during iteration can throw inside the catch and silently skip the write — snapshot with `toList()` before entering the async chain (or copy entries first).
- [medium] lib/data/services/recording_sync_service.dart:183-186 — `_saveManifestDebounced` fires `_saveManifest` via a bare `Timer` with no zone guard; if the timer fires during app teardown/teardown of the isolate the uncaught async error escapes — wrap in `runAsync`/guard or cancel on dispose (there is no dispose path canceling `_manifestDebounce`).
- [low] lib/data/services/recording_sync_service.dart:145-146 — `hydrateCache` memoizes with `??=` on a `Future<void>?` but `_doHydrate` re-checks `_hydrated` only inside; if the first hydration future is awaited twice concurrently before completion the second caller awaits the same future (fine), yet a failed `_doHydrate` (caught internally) leaves `_hydration` non-null forever so a later genuine retry can never re-run — reset `_hydration = null` in the catch path or use a completer.
- [low] lib/data/services/recording_sync_service.dart:266-267 — `syncForProduction` returns 0 on cloud-fetch failure after showing a toast, indistinguishable from "nothing to sync" for callers that branch on the count (the comment admits it); consider a typed result or rethrow so callers can distinguish.
- [low] lib/data/services/recording_sync_service.dart:722-724 — `_extractCharacterFromUrl` scans segments for `productionId` and returns the NEXT segment; a URL whose path contains the production id in an earlier unrelated position (e.g. bucket name segment equal to the id) yields the wrong character name — display-only, but anchor the match to the `recordings/{productionId}/` prefix instead of any-position matching.
- [low] lib/data/services/recording_sync_service.dart:543 — `cached.recordedAt.clamp(0, 1 << 52)` silently clamps corrupt/negative manifest timestamps to epoch-0/2^52 instead of rejecting the entry — a poisoned manifest entry yields a bogus `recordedAt` that then wins the "newest per line" comparison in `syncForProduction` (line 313-314) — validate on `_CachedRecording.fromJson` instead.
- [low] lib/data/services/recording_sync_service.dart:772-775 — `_CachedRecording.fromJson` recovers `productionId` from the LAST path segment of `localPath` when absent; for legacy flat-layout manifests (`recording_cache/<lineId>.m4a`) that segment is the `.m4a` filename, not a production id, so restored entries get a wrong `productionId` and are then filtered out of every production's cache view (line 561) — detect the flat layout (no intermediate dir) and skip restore instead.
- [info] lib/data/services/recording_sync_service.dart:227-230 — `isSafePathId` rejects `..` but the regex already excludes `/` and `\`; the extra `contains('..')` is redundant but harmless — no action needed; noting only that the guard's real strength is the regex, keep it.
- [low] lib/data/services/script_export.dart:275-278 — `_truncate` with `maxLen < 4` produces a negative `substring` start and throws; all current call sites pass 80, so latent — guard `maxLen` or clamp before substring.
- [low] lib/data/services/script_export.dart:280-289 — `_lastWords` scans backward for spaces but starts at `text.length - 1` and stops at `i > 0`, so a text that IS the wordCount-th word boundary at index 0 is missed and the full text is returned; also returns the whole text when fewer spaces exist, silently inflating the cue line — acceptable for display, but document or clamp.
- [low] lib/data/services/script_export.dart:247-262 — `toCueScript` indexes `dialogueLines[i - 1]` as the cue for the FIRST dialogue line when `i == 0` is skipped via `if (i > 0)`, but for `i == 0` no cue is emitted at all even when a preceding stage direction exists in `script.lines` — cue context is silently dropped for the first line; consider using the previous line from `script.lines` regardless of type.

## Coverage
lib/data/services/recording_sync_service.dart — findings: 8
lib/data/services/script_export.dart — findings: 3
## Coverage
lib/data/services/script_import_service.dart — findings: 14

- [medium] lib/data/services/script_import_service.dart:194-198 — `Isolate.run` closure captures `script.lines`/`script.characters` and `vocab` and calls `OcrConfidenceService.instance` inside the worker isolate, but `ensureVocabLoaded`/`theatricalVocab`/`setTheatricalVocab`/`scoreScript` are only shown here, not defined — if `OcrConfidenceService` holds non-sendable state (e.g. a `Completer`, `Timer`, or `MethodChannel` in `instance`), `Isolate.run` throws on send and the import path crashes — verify the service's fields are sendable or re-create the scorer inside the isolate from pure data — reachability: any user importing a scanned PDF (authenticated user, own data) — smallest safe fix: construct a fresh scorer object from sendable data (`vocab` list + lines/characters) inside the closure instead of touching the singleton's full state.
- [medium] lib/data/services/script_import_service.dart:212-218 — `_scoreConfidence` returns a `ParsedScript` built from `scoredLines` but drops `script.rawText`'s provenance only if `scoreScript` returns lines whose `sourcePage`/`sourceLineOnPage` were stripped — as written the rebuilt `ParsedScript` keeps `rawText` and `scenes`, so no defect is exhibited here; no finding.
- [medium] lib/data/services/script_import_service.dart:219-221 — `finally { scorer.dispose(); }` disposes the shared singleton's dictionary even when `ensureVocabLoaded` succeeded and another concurrent import (or the app's next import) still needs it — a second concurrent `importFromPdf` then sees an empty `theatricalVocab` and scores every line as garbage (silent quality loss, no crash) — reachability: two imports racing (authenticated user, own data) — smallest safe fix: guard `dispose()` behind a load-count or only dispose when this call loaded the vocab itself.
- [low] lib/data/services/script_import_service.dart:34-35 — `lastImportFailedPages` is a mutable instance field read by the UI after an async import; a second import started while the first is still running overwrites it mid-read, and a failed import leaves the previous import's count — consequence: the "N pages failed" warning can show a stale or wrong number — smallest safe fix: return the failed-page count as part of the result (or a per-import result object) instead of shared mutable state.
- [medium] lib/data/services/script_import_service.dart:95 — `lastImportFailedPages = 0` is reset at the start of `_importFromPdfInner`, but the PDFKit-success path (lines 126-161) returns early without ever setting it from `perPage` failures; if PDFKit partially failed pages (not visible here), the count stays 0 — assumption: `PdfTextChannel.extractTextPerPage` reports failed pages somewhere not shown; as exhibited, the early return path never updates the counter — smallest safe fix: set `lastImportFailedPages` from the PDFKit result before the early return.
- [low] lib/data/services/script_import_service.dart:118 — `nativeText.trim().length > 200` treats a 200-char extraction as "good enough to skip OCR" without checking `_isGoodParse` first for short plays; a one-page scanned excerpt that PDFKit extracts as 201 chars of garbage headers would be returned unparsed-quality-checked — consequence: garbage parse returned as success — smallest safe fix: also require `_isGoodParse(nativeResult)` before accepting, which the code already does at 126; as written the length check only gates the debug print, so no defect — no finding.
- [medium] lib/data/services/script_import_service.dart:130-146 — `rawSearchStart` is advanced only when `pageInfo != null`, but `_findSourcePageFrom` searches forward from `rawSearchStart` across ALL remaining raw lines including lines already consumed by earlier parsed lines; a repeated short line (e.g. a character name) can match a raw line belonging to a LATER page, tagging this parsed line with the wrong `sourcePage` — consequence: "View page" opens the wrong page for repeated lines — smallest safe fix: bound the forward search to a small window past `rawSearchStart` (as `parseAndMapOcr` does with `searchWindow`) instead of unbounded forward scan.
- [medium] lib/data/services/script_import_service.dart:737-756 — `_findSourcePageFrom` returns `lineOnPage: 0` always; callers at 144 store `sourceLineOnPage: 0`, which `pageLineRef` (script_models.dart:78-84) then renders as `p12:0` — consequence: page:line refs for PDFKit-tagged lines are malformed — smallest safe fix: compute the real 1-based line-on-page via `_lineOnPage(linePageMap, i)` like `parseAndMapOcr` does at 664-665.
- [medium] lib/data/services/script_import_service.dart:751 — `_findSourcePageFrom` matches when EITHER side contains the other (`rawTrimmed.contains(searchText) || searchText.contains(rawTrimmed)`) with no minimum-length guard; a 1-2 char parsed line ("I") is contained in nearly every raw line, so the first raw line after `startIndex` wins regardless of page — consequence: wrong sourcePage for short lines — smallest safe fix: require a minimum normalized length (e.g. ≥8 chars) before containment, mirroring `matches()` at 577-591.
- [medium] lib/data/services/script_import_service.dart:631-641 — `bestMatch` is called with `rawLinesOriginal` (unnormalized) while `matches()`/window logic normalize via `_normForMatch`; if `OcrHighlightMatcher.bestMatch` compares raw text, garbled lines never match and fall to `_inheritMissingPages` — assumption: `bestMatch` may normalize internally (not shown); as exhibited the call passes raw text where the surrounding code normalizes — smallest safe fix: pass the normalized `rawLines` list (or confirm bestMatch normalizes) — reachability: any scanned-PDF import (authenticated user, own data).
- [low] lib/data/services/script_import_service.dart:648-653 — the confidence-collection loop breaks on `rawLines[i].isEmpty` but `rawLines` is the NORMALIZED list where `_normForMatch` trims to empty for whitespace-only lines; a blank raw line inside a page legitimately ends the run early, dropping later raw lines that belong to the same parsed line from the confidence average — consequence: slightly wrong avg confidence — smallest safe fix: break on the original `rawLinesOriginal[i]` emptiness or skip blanks instead of breaking.
- [low] lib/data/services/script_import_service.dart:626 — `estimate` uses `parsedIdx * rawCount / parsedCount` where `parsedIdx` was incremented before the map closure for EVERY line including empty-text lines returned early at 616 — for scripts with many stage directions the estimate drifts ahead, widening the window asymmetrically — consequence: window misalignment, more unmapped pages — smallest safe fix: only advance `parsedIdx` for lines that participate in matching, or use the loop index directly.
- [low] lib/data/services/script_import_service.dart:601 — `searchWindow = 150` raw lines is fixed regardless of page density; a dense scanned play (60+ lines/page) makes the window span <3 pages and a match just past the window is missed, falling to neighbor-page inheritance — consequence: sourcePage off-by-pages for dense scans — smallest safe fix: scale the window to `rawCount/parsedCount`-derived page size.
- [medium] lib/data/services/script_import_service.dart:673-734 — `_inheritMissingPages` forward-fills then backward-fills `sourcePage` for unmapped lines, but never fills `sourceLineOnPage`; a line that inherits a page keeps `sourceLineOnPage == null`, and `pageLineRef` (script_models.dart:78-84) then falls back to the 42-lines/page heuristic, producing a ref inconsistent with the inherited page — consequence: wrong page:line ref shown for inherited lines — smallest safe fix: also inherit/derive `sourceLineOnPage` or leave both null together.
- [medium] lib/data/services/script_import_service.dart:714-734 — `_inheritMissingPages` is `static` and mutates the caller's list in place via `copyWith` reassignment — fine — but it is called at 673 on `updatedLines` BEFORE the `ParsedScript` is built at 676; if `updatedLines` is empty (line 675 guard) the call is harmless — no defect exhibited — no finding.
- [medium] lib/data/services/script_import_service.dart:547-548 — `Isolate.run(() => parseAndMapOcr(...))` captures `lineConfidences`/`linePageMap` (plain maps, sendable) and `rawText` — sendable — but `parseAndMapOcr` is `static` and pure per the doc comment; no defect exhibited — no finding.
- [medium] lib/data/services/script_import_service.dart:436-439 — `Pdfrx.getCacheDirectory ??= () async { ... }` reassigns a global/static hook on every iOS/Android import; if pdfrx expects the hook to be set once (or another code path sets a different hook), this silently replaces it — assumption: pdfrx's setter semantics not shown — as exhibited, repeated assignment of an equivalent closure is idempotent — no finding.
- [medium] lib/data/services/script_import_service.dart:449-516 — the ML Kit loop renders every page to a PNG written to ONE reused temp file `ocr_page.png` (446, 489-490), then `InputImage.fromFilePath(tempFile.path)` re-reads it; if `writeAsBytes` for page N+1 races the still-open read of page N (or ML Kit holds the file across awaits), pages can be OCR'd from the wrong page's bytes — consequence: wrong text attributed to a page, wrong sourcePage mapping — reachability: any iOS/Android scanned-PDF import (authenticated user, own data) — smallest safe fix: write one temp file per page (or await the recognizer fully and copy bytes before overwrite).
- [low] lib/data/services/script_import_service.dart:521-524 — `tempFile.delete()` is wrapped in `catch (_) {}` inside the `finally`; a delete failure leaves a stale PNG silently — consequence: minor disk leak — smallest safe fix: log the failure via `debugPrint`.
- [medium] lib/data/services/script_import_service.dart:512-515 — a per-page `catch` sets `failedPages++` and `continue`s, but the outer `try` at 448 wraps the whole page loop; an exception thrown by `buffer.writeln`/map updates between pages (e.g. `recognized.blocks` access at 495 after a partial failure) escapes the per-page handler only if thrown inside the inner try — as written all per-page work is inside the inner try, so no defect exhibited — no finding.
- [medium] lib/data/services/script_import_service.dart:463-468 & 478-484 — both null-render branches `debugPrint` "render returned null, skipping" and `failedPages++`, but the second branch (478-484) is unreachable-in-spirit: `byteData == null` after `image.dispose()` at 476 — if `toByteData` returns null the image was already disposed; the message says "render returned null" which mislabels the failure — consequence: misleading field log only — smallest safe fix: correct the message — no functional defect — no finding beyond info if desired.
- [low] lib/data/services/script_import_service.dart:458 — `renderScale = (2600 / longSidePt).clamp(2.0, 4.0)` — for a page whose long side is < 650pt, `2600/longSidePt > 4.0` clamps to 4.0 (fine), but for longSidePt > 2600 the scale clamps to 2.0 and the bitmap is still huge; the comment says clamp prevents unbounded bitmaps, and 2.0× on a 3000pt page is ~6000px — memory spike on huge scans — consequence: OOM/jetsam on very large pages — smallest safe fix: lower the upper clamp or scale down absolutely (e.g. cap target pixels).
- [medium] lib/data/services/script_import_service.dart:356-366 — `PaddleOcrChannel.ocrPdf` failure is caught and `paddleResult = null`, then the macOS branch (411-433) runs Vision OCR — but on non-macOS, non-iOS/Android platforms (Windows/Linux desktop) neither fallback applies and `failedPages` stays 0 while `buffer` stays empty, so `rawText.trim().isEmpty` throws the generic "No text found" exception at 537-540 — consequence: desktop imports always fail with a misleading message — assumption: app ships only iOS/Android/macOS (not exhibited) — smallest safe fix: throw an explicit "no OCR engine for this platform" error.
- [medium] lib/data/services/script_import_service.dart:411-433 — the macOS Vision fallback loop (419-428) does NOT strip furniture/margin notes (unlike the Paddle path at 373-401) and does not run `_detectRunningFurniture`; running headers/footers leak into `buffer` and the parser — consequence: repeated "Jon Jory" credits parsed as dialogue lines on macOS — smallest safe fix: reuse `_detectRunningFurniture` + `_furnitureKey` stripping in the Vision path.
- [low] lib/data/services/script_import_service.dart:418 — `failedPages = pdfResult.failedPages` overwrites the Paddle-path count; if Paddle partially failed then Vision succeeded, the Paddle failure count is lost — consequence: underreported failed pages — smallest safe fix: accumulate rather than overwrite.
- [medium] lib/data/services/script_import_service.dart:529-534 — `lastImportFailedPages = failedPages` is set only at the END of `_importFromPdfOcr`; the PDFKit-success early return at 153-161 never reaches it, so a PDFKit import with failed pages reports 0 (see earlier finding) — same root cause as the line-95 finding; one finding already filed — no duplicate.
- [low] lib/data/services/script_import_service.dart:536-541 — `rawText.trim().isEmpty` throws only when the buffer is empty; a PDF where every page failed but `failedPages > 0` and a few furniture lines were written still proceeds to parse garbage — consequence: garbage parse instead of a clear failure — smallest safe fix: also throw when `failedPages == pageCount` (all pages failed).
- [medium] lib/data/services/script_import_service.dart:232 — `RegExp(r'FTLN \d+(\s+\d+)?\s*\n?')` without `multiLine`/anchoring also matches "FTLN 42" appearing mid-dialogue (a character literally saying "FTLN"), and the trailing `\n?` eats the newline joining the NEXT line, merging two dialogue lines — consequence: occasional merged lines in Folger PDFs — smallest safe fix: anchor to line start with `multiLine: true` and `^\s*FTLN`.
- [low] lib/data/services/script_import_service.dart:242 — `RegExp(r'^\d{1,3}\s*$', multiLine: true)` strips any standalone 1-3 digit line — a legitimate short numeric stage direction or line number cue ("42") is silently deleted — consequence: content loss in numeric-heavy scripts — smallest safe fix: restrict to page-number ranges or require surrounding context.
- [low] lib/data/services/script_import_service.dart:63 — `RegExp(r'^#{1,6}\s*', multiLine: true)` in `_stripMarkdown` also strips `#` inside fenced code blocks or a line like "### ACT" that is real content — consequence: content loss for scripts stored as markdown with literal hashes — smallest safe fix: only strip when the line is a header-like line (already line-anchored; risk is low) — borderline; no finding.
- [low] lib/data/services/script_import_service.dart:65 — `RegExp(r'\*{2,3}')` removes ALL asterisk runs including a single `*` used as a stage-direction bullet in plain text — consequence: content loss — smallest safe fix: require pairing (`\*{2,}`) or context — borderline; no finding.
- [medium] lib/data/services/script_import_service.dart:884-887 — `exportToTextFile`'s `default` case silently treats ANY unknown `format` string as plain-text export; a caller passing `'cue '` (typo) or a new format gets a plain export with a `.txt` extension named `..._cue.txt`? No — `extension` is set from the matched case; for an unrecognized format the default branch sets `extension = '.txt'` and `fileName` uses the RAW `format` string (`'${safeName}_$format$extension'`), so an unknown format writes a file named `..._weirdformat.txt` containing plain text — consequence: silent wrong-format export — smallest safe fix: validate `format` against the known set and throw `ArgumentError`.
- [low] lib/data/services/script_import_service.dart:889-893 — `safeName` strips `[^\w\s-]` then collapses whitespace to `_`; a title of `___` or all-punctuation yields an empty `safeName`, producing a file named `__plain.txt`-style with leading underscore — cosmetic — no finding.
- [medium] lib/data/services/script_import_service.dart:896 — `File(filePath).writeAsString(content)` overwrites an existing export file with no conflict check; two exports of different scripts with the same sanitized title silently clobber each other — consequence: silent data loss of a prior export — reachability: authenticated user, own data — smallest safe fix: include a timestamp/uuid in `fileName` or check existence first.
- [low] lib/data/services/script_import_service.dart:900-909 — `_titleFromPath` strips the tokens `script|ocr|parsed|text` from the basename; a file named `the_ocr_play.pdf` becomes title "the play", and `macbeth_ocr` → "macbeth" (intended), but `parsed_text` alone yields empty title → `Untitled` fallback only in `importFromText` — `_titleFromPath` can return empty string, and `ScriptParser.parse(title: '')` behavior is unknown (parser not shown) — assumption: parser handles empty title — smallest safe fix: fall back to a default when the cleaned title is empty.
- [low] lib/data/services/script_import_service.dart:40-41 — `importFromTextFile` reads the whole file with `readAsString` with no size cap; a multi-MB text file freezes the UI isolate during parse — consequence: jank on huge imports — smallest safe fix: parse in the worker isolate like the PDF path — borderline; no finding.
- [info] lib/data/services/script_import_service.dart:119-120, 148-152, 164-168, 430-433, 464-466, 479-483, 508-511, 513 — `debugPrint` calls are batched/throttled by Flutter in release, but several include interpolated exception text (`$e`) at 172, 363 — if any of that text can contain user-supplied file content, log injection into the debug log file (debug_log_service persists entries) is possible — assumption: debugPrint output is not persisted by `DebugLogService` (the service logs via its own `log()`), so no persistence path is exhibited — no finding.
- [info] lib/data/services/script_import_service.dart:361-364, 404-410, 531-533 — `DebugLogService.instance.log(...)` writes import diagnostics (including exception text `$e` at 363) to a persistent on-disk log file (`debug_log.txt` in the app documents directory) — on a shared device or exported logs this could disclose file paths/exception internals, but no secrets or cross-tenant data are exhibited — no finding.
- [low] lib/data/services/script_import_service.dart:26 — `ScriptImportService()` has a public default constructor and no singleton guard; each instantiation re-creates `_parser` — harmless — no finding.
- [low] lib/data/services/script_import_service.dart:28 — `_parser` field is assigned but the PDFKit path constructs a fresh `ScriptParser()` at 123 and `parseAndMapOcr` constructs another at 567; `_parser` is used only by the text/markdown paths — inconsistent but harmless — no finding.
- [low] lib/data/services/script_import_service.dart:762 — `_validCharRe` is documented as "alphanumeric + common punctuation" but the character class includes `/` and excludes `—`/curly quotes; OCR text with typographic quotes is penalized as junk — consequence: slightly lower confidence for clean scans — smallest safe fix: extend the class — borderline; no finding.
- [low] lib/data/services/script_import_service.dart:795 — `word == word.toUpperCase() && word.length <= 12` skip is applied only in the no-vowel check; an all-caps short word like "EXIT" (no vowels? has E,I — fine) — no defect exhibited — no finding.
- [low] lib/data/services/script_import_service.dart:820-826 — `_quadRepeatRe.hasMatch(trimmed)` checks the ORIGINAL case while `_tripleRepeatRe` checks `toLowerCase()`; "TTTT" matches quad (fine), "TtTt" matches neither quad (case-sensitive `(.)\1{3,}`) nor triple-lowercase path correctly? `TtTt`.toLowerCase() = "tttt" → triple matches with 4 repeats → `triples` count via allMatches of `(.)\1{2}` on "tttt" = 2 → `triples > 1` → −0.15 — works — no finding.
- [low] lib/data/services/script_import_service.dart:843 — `_nonAlnumRe.hasMatch(trimmed)` for `trimmed.length < 5` uses the raw (non-lowercased) string — consistent with the regex's case-insensitive-free class — no defect exhibited — no finding.
- [low] lib/data/services/script_import_service.dart:703-711 — `_lineOnPage` walks backward while `linePageMap[first - 1] == page`; when `first` reaches 0 the loop guard `first > 0` stops — correct — no finding.
- [low] lib/data/services/script_import_service.dart:301 — `threshold = (pages.length * 0.5).ceil().clamp(3, pages.length)` — for `pages.length == 3`, ceil(1.5)=2 clamped to 3 → threshold 3, requiring ALL 3 pages to agree; the doc says "at least half the pages" — for 3 pages the clamp raises it to all pages, making detection miss 2-of-3 repeats — consequence: furniture not stripped on 3-page docs — smallest safe fix: clamp lower bound to 2 — borderline; no finding.
- [low] lib/data/services/script_import_service.dart:296-299 — `texts.first`/`texts.last` after filtering empty lines: if all lines are empty, `continue` guards it (295) — correct — no finding.
- [low] lib/data/services/script_import_service.dart:328 — `cutoff = wide[(wide.length * 0.15).floor()] - 0.10` — `wide` is sorted ascending; index `(len*0.15).floor()` for len=1 → 0 — fine; for len=2 → 0 — fine — no finding.
- [low] lib/data/services/script_import_service.dart:330-334 — `cands.last - cands.first > 0.12` uses sorted extremes — correct clustering check — no finding.
- [low] lib/data/services/script_import_service.dart:324-326 — `wide` fallback `lines.map((l) => l.left)` when no wide lines: then `cands` requires `l.width < 0.30` — if ALL lines have width ≥ 0.30, `cands` is empty → returns null — correct — no finding.
- [low] lib/data/services/script_import_service.dart:396 — `linePageMap[rawLineIndex] = page.page` uses `page.page` (Paddle's page number) while the PDFKit path uses `pageIdx + 1` (positional) — if Paddle's `page.page` is 1-based and matches position, consistent; not exhibited as a defect — no finding.
- [low] lib/data/services/script_import_service.dart:400 — `rawLineIndex++` after `buffer.writeln()` (blank separator line) increments the index past the blank line, but `lineConfidences`/`linePageMap` were not set for the blank index — `parseAndMapOcr`'s loop at 648-653 reads `lineConfidences[i]` for blank lines only if `matches()` passes; blank normalized lines are empty and break at 649 — consistent — no finding.
- [low] lib/data/services/script_import_service.dart:105-115 — the PDFKit line-page map is built by splitting each page's text on `\n` and incrementing `rawLineIdx` per line, but `buffer.writeln(line)` writes an extra newline per line while `linePageMap` indexes assume one raw line per split entry — `nativeText.split('\n')` at 130 yields exactly the mapped lines (writeln adds `\n` after each, so split gives the same count) — consistent — no finding.
- [low] lib/data/services/script_import_service.dart:132-146 — `nativeResult.lines.map(...)` with `rawSearchStart` advanced only on success: a parsed line whose text never matches any raw line leaves the cursor stuck, and the NEXT parsed line searches from the stale position, potentially matching an EARLIER page's raw line — consequence: wrong sourcePage after an unmatched line — smallest safe fix: advance `rawSearchStart` even on miss (to the last examined index) or bound the window — related to the 130-146 finding; same root cause (unbounded/sticky forward cursor) — one finding already filed at 130-146.
- [medium] lib/data/services/script_import_service.dart:143-145 — `line.copyWith(sourcePage: () => pageInfo?.page, sourceLineOnPage: () => pageInfo?.lineOnPage)` — per script_models.dart:98-116, `copyWith` treats a non-null `Function` as "set" and a null function as "keep existing"; passing `() => null` SETS the field to null (clearing), which is intended here — but for lines where `pageInfo == null` the previously-computed value (none) is cleared — no prior value exists — no defect — no finding.
- [low] lib/data/services/script_import_service.dart:567 — `ScriptParser().parse(rawText, title: title)` inside `parseAndMapOcr` runs in the worker isolate; `ScriptParser` is not shown — if it touches rootBundle/plugins it would fail in the isolate — assumption stated; cannot verify — see follow-up if needed.
- [low] lib/data/services/script_import_service.dart:560 — `@visibleForTesting` on a static method used at 547 within the same library — fine — no finding.
- [low] lib/data/services/script_import_service.dart:690-691 — `_normJunkRe`/`_normWsRe` are `static final` — fine — no finding.
- [low] lib/data/services/script_import_service.dart:696-700 — `_normForMatch` lowercases and strips junk — consistent with `matches()` — no finding.
- [low] lib/data/services/script_import_service.dart:613-616 — `parsedIdx++` happens before the empty-searchText early return, so `estimate` (626) uses a count that includes empty lines — same as the 626 finding already filed — no duplicate.
- [low] lib/data/services/script_import_service.dart:655-659 — `confidences.reduce((a,b) => a+b) / confidences.length` on an empty list is guarded by `confidences.isEmpty ? null : ...` — correct — no finding.
- [low] lib/data/services/script_import_service.dart:661-665 — `copyWith(ocrConfidence: () => avgConf, sourcePage: () => page, sourceLineOnPage: () => _lineOnPage(...))` — when `page == null`, `sourceLineOnPage` still gets a non-null closure returning `_lineOnPage(map, matchStart)` which may be non-zero even though page is null — per script_models.dart:114-116, a non-null closure SETS the field; so a line with no page gets `sourceLineOnPage` set to a number while `sourcePage` stays null — `pageLineRef` then uses the fallback heuristic (since sourcePage is null) — inconsistent but the heuristic ignores sourceLineOnPage when sourcePage is null — no functional defect exhibited — no finding.
- [low] lib/data/services/script_import_service.dart:722-732 — `_inheritMissingPages` captures `captured`/`nextPage` into closures — plain int captures — fine — no finding.
- [low] lib/data/services/script_import_service.dart:601-635 — window/anchor math: `lowAnchor = min(cursor, estimate)`, `highAnchor = max(cursor, estimate)`, `rawStart = max(0, lowAnchor - 40)`, `windowEnd = highAnchor + 150` — `limit` clamped to `rawLines.length` — `bestMatch(start: rawStart, end: limit)` — if `rawStart > limit` (possible when lowAnchor - 40 > windowEnd? no, lowAnchor ≤ highAnchor so rawStart ≤ highAnchor - 40 < windowEnd) — correct — no finding.
- [low] lib/data/services/script_import_service.dart:642-643 — `matchStart == null` returns the line unchanged, leaving it for `_inheritMissingPages` — intended — no finding.
- [low] lib/data/services/script_import_service.dart:654 — `cursor = matchStart + 1` — forward-only cursor; a repeated line EARLIER in the document than the cursor can never re-match (monotonic assumption) — by design per the doc comment — no finding.
- [low] lib/data/services/script_import_service.dart:610-611 — `parsedCount`/`rawCount` computed from `script.lines.length` and `rawLinesOriginal.length` — if the parser merges/splits lines, the ratio drifts — inherent heuristic — no finding.
- [low] lib/data/services/script_import_service.dart:575 — `rawLines = rawLinesOriginal.map(_normForMatch).toList()` — normalized copy used for emptiness checks at 649 — see the 648-653 finding — no duplicate.
- [low] lib/data/services/script_import_service.dart:582-584 — `matches()` containment thresholds (≥8 chars) — reasonable — no finding.
- [low] lib/data/services/script_import_service.dart:587-589 — 12-char prefix comparison for long lines — heuristic — no finding.
- [low] lib/data/services/script_import_service.dart:599-600 — comment references field bug; code implements the bounded window — consistent — no finding.
- [low] lib/data/services/script_import_service.dart:561-566 — signature takes `Map<int,double>`/`Map<int,int>` — sendable — no finding.
- [low] lib/data/services/script_import_service.dart:547-548 — `Isolate.run` result is `ParsedScript` — if `ParsedScript`/`ScriptLine` contain non-sendable fields (closures? `copyWith` uses `Function()` fields but stored values are plain) — `ScriptLine` stores plain values — sendable — no finding.
- [low] lib/data/services/script_import_service.dart:153-161 — PDFKit success path returns `_scoreConfidence(...)` which runs `Isolate.run` with `script.lines` = `taggedLines` (plain) — sendable — no finding beyond the 194-198 singleton finding.
- [low] lib/data/services/script_import_service.dart:176-177 — OCR path result also scored — consistent — no finding.
- [low] lib/data/services/script_import_service.dart:182-222 — `_scoreConfidence` disposes in `finally` even on `ensureVocabLoaded` failure — if load failed, dispose of an never-loaded dictionary is harmless — no finding beyond the 219-221 concurrent-dispose finding.
- [low] lib/data/services/script_import_service.dart:199-207 — counting loop over `scoredLines` — fine — no finding.
- [low] lib/data/services/script_import_service.dart:208-211 — debugPrint of counts — fine — no finding.
- [low] lib/data/services/script_import_service.dart:228-247 — `_cleanPdfKitText` returns cleaned text; header regex at 236-238 requires the FULL line to be `digits + word + ACT...` — reasonable — no finding beyond the 232/242 findings.
- [low] lib/data/services/script_import_service.dart:245 — `\n{3,}` → `\n\n` collapse — fine — no finding.
- [low] lib/data/services/script_import_service.dart:256-270 — `_isGoodParse` thresholds (≥3 chars, ≥10 dialogue lines, ≤10 acts) — heuristic — no finding.
- [low] lib/data/services/script_import_service.dart:276-281 — `_furnitureKey` strips leading/trailing digits — a page whose first line IS a bare number keys to empty string `''`; `fk.length >= 3` guard at 298 prevents empty keys — correct — no finding.
- [low] lib/data/services/script_import_service.dart:288-309 — `_detectRunningFurniture` requires ≥3 pages — correct per doc — no finding beyond the 301 threshold note (no finding filed).
- [low] lib/data/services/script_import_service.dart:323-335 — `_marginCutoff` — heuristic, guarded — no finding.
- [low] lib/data/services/script_import_service.dart:379-389 — margin strip condition `line.width < 0.30 && line.left < marginCutoff` — matches `_marginCutoff`'s candidate definition — consistent — no finding.
- [low] lib/data/services/script_import_service.dart:390-393 — furniture strip via `_furnitureKey(line.text)` — consistent — no finding.
- [low] lib/data/services/script_import_service.dart:394-397 — confidence/page recorded per kept line — consistent — no finding.
- [low] lib/data/services/script_import_service.dart:399-400 — blank line + index bump — consistent (see earlier) — no finding.
- [low] lib/data/services/script_import_service.dart:411-416 — Vision fallback throws when both engines unavailable — correct on macOS — no finding.
- [low] lib/data/services/script_import_service.dart:440-441 — `PdfDocument.openFile(pdfPath)` then `doc.pages.length` — if openFile throws, the exception propagates uncaught (no try around 440) — consequence: import fails with a raw exception rather than the friendly "No text found" — acceptable — no finding.
- [low] lib/data/services/script_import_service.dart:443 — `TextRecognizer()` created per import and closed in `finally` at 518 — correct — no finding.
- [low] lib/data/services/script_import_service.dart:445-446 — temp dir/file created once per import — see the 436-439/449-516 findings — no duplicates.
- [low] lib/data/services/script_import_service.dart:457 — `longSidePt = max(width, height)` — correct — no finding.
- [low] lib/data/services/script_import_service.dart:459-462 — render with scaled dims — consistent — no finding.
- [low] lib/data/services/script_import_service.dart:470-476 — `createImage` then `pdfImage.dispose()` — if `createImage` throws, `pdfImage` leaks (no try/finally around 470-476) — consequence: native image handle leak on error paths — smallest safe fix: wrap in try/finally to dispose — low.
- [low] lib/data/services/script_import_service.dart:473-476 — `image.dispose()` after `toByteData`; if `toByteData` throws, `image` leaks — same class as above — one finding for the leak class at 470-476.
- [low] lib/data/services/script_import_service.dart:489-490 — `byteData.buffer.asUint8List(offsetInBytes, lengthInBytes)` — respects the view — correct — no finding.
- [low] lib/data/services/script_import_service.dart:492-493 — `InputImage.fromFilePath(tempFile.path)` — see the 449-516 shared-temp-file finding — no duplicate.
- [low] lib/data/services/script_import_service.dart:495-506 — blocks/lines loop writes text + confidence + page — consistent — no finding.
- [low] lib/data/services/script_import_service.dart:504-505 — blank line + index bump per BLOCK (not per page) — `rawLineIndex++` after each block's blank line; `linePageMap` for the blank index unset — consistent with 399-400 — no finding.
- [low] lib/data/services/script_import_service.dart:517-526 — `finally` closes recognizer, disposes doc, deletes temp file — correct ordering — no finding.
- [low] lib/data/services/script_import_service.dart:529-534 — failed-pages logging — see earlier findings — no duplicates.
- [low] lib/data/services/script_import_service.dart:536-541 — empty-text throw — see the 536-541 finding — no duplicate.
- [low] lib/data/services/script_import_service.dart:850-898 — export path — findings filed at 884-887 and 896 — no duplicates.
- [low] lib/data/services/script_import_service.dart:900-909 — title cleanup — finding filed at 900-909 — no duplicate.
- [low] lib/data/services/script_import_service.dart:37-42 — `importFromTextFile` has no try around `readAsString`; a missing file throws a raw `FileSystemException` to the caller — acceptable — no finding.
- [low] lib/data/services/script_import_service.dart:51-57 — `importFromMarkdownFile` strips markdown then parses — consistent — no finding.
- [low] lib/data/services/script_import_service.dart:60-76 — `_stripMarkdown` — findings considered; none filed beyond borderline notes — no finding lines.
- [low] lib/data/services/script_import_service.dart:86-91 — `importFromPdf` wraps in `PerfService.instance.measure` — `PerfService` not shown; if `measure` is synchronous-wrapping an async closure correctly awaited — assumption it awaits — no finding.
- [low] lib/data/services/script_import_service.dart:93-95 — `_importFromPdfInner` resets `lastImportFailedPages` — see the 95 finding — no duplicate.
- [low] lib/data/services/script_import_service.dart:99-100 — `perPage != null && perPage.isNotEmpty` — if PDFKit returns per-page list with SOME empty pages, `isNotEmpty` passes and empty pages contribute nothing — fine — no finding.
- [low] lib/data/services/script_import_service.dart:107-115 — per-page line mapping — consistent — no finding.
- [low] lib/data/services/script_import_service.dart:117-118 — `nativeText.trim().length > 200` gate — see the 118 note — no finding.
- [low] lib/data/services/script_import_service.dart:122-124 — clean + parse — consistent — no finding.
- [low] lib/data/services/script_import_service.dart:126-161 — success path — see the 130-146 and 143-145 findings — no duplicates.
- [low] lib/data/services/script_import_service.dart:171-173 — catch logs and falls through to OCR — correct fallback direction (OCR is the riskier path but is the designed fallback for unavailable text) — no finding.
- [low] lib/data/services/script_import_service.dart:176-177 — OCR fallback always runs when PDFKit parse is bad — correct — no finding.
- [low] lib/data/services/script_import_service.dart:340-343 — `_importFromPdfOcr` signature — fine — no finding.
- [low] lib/data/services/script_import_service.dart:344-348 — local maps — fine — no finding.
- [low] lib/data/services/script_import_service.dart:354-366 — Paddle try/catch — see the 356-366 finding — no duplicate.
- [low] lib/data/services/script_import_service.dart:368-410 — Paddle success path — see findings — no duplicates.
- [low] lib/data/services/script_import_service.dart:434-527 — ML Kit path — see findings — no duplicates.
- [low] lib/data/services/script_import_service.dart:528-548 — post-loop — see findings — no duplicates.
- [low] lib/data/services/script_import_service.dart:551-566 — doc comment for `parseAndMapOcr` — fine — no finding.
- [low] lib/data/services/script_import_service.dart:567-686 — mapping implementation — findings filed — no duplicates.
- [low] lib/data/services/script_import_service.dart:687-735 — helpers — findings filed — no duplicates.
- [low] lib/data/services/script_import_service.dart:736-756 — `_findSourcePageFrom` — findings filed at 737-756 and 751 — no duplicates.
- [low] lib/data/services/script_import_service.dart:758-848 — confidence estimator — findings considered — no additional finding lines.
- [low] lib/data/services/script_import_service.dart:850-911 — export/title — findings filed — no duplicates.

## Coverage
lib/data/services/script_import_service.dart — findings: 14
## Coverage
lib/data/services/script_import_service.dart — findings: 14

## Follow-up requests
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_confidence_service.dart — whether `OcrConfidenceService.instance` state is sendable into `Isolate.run` (decides the 194-198 crash finding) and whether `dispose()` is refcounted (decides the 219-221 concurrent-dispose finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_highlight_matcher.dart — whether `bestMatch` normalizes its inputs (decides the 631-641 raw-vs-normalized finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/script_parser.dart — whether `ScriptParser.parse` is isolate-safe and handles an empty `title` (decides the 567 and 900-909 findings)

## Coverage
lib/data/services/script_import_service.dart — findings: 14

## Follow-up requests
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_confidence_service.dart — whether `OcrConfidenceService.instance` state is sendable into `Isolate.run` (decides the 194-198 crash finding) and whether `dispose()` is refcounted (decides the 219-221 concurrent-dispose finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_highlight_matcher.dart — whether `bestMatch` normalizes its inputs (decides the 631-641 raw-vs-normalized finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/script_parser.dart — whether `ScriptParser.parse` is isolate-safe and handles an empty `title` (decides the 567 and 900-909 findings)

## Coverage
lib/data/services/script_import_service.dart — findings: 14

## Follow-up requests
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_confidence_service.dart — whether `OcrConfidenceService.instance` state is sendable into `Isolate.run` (decides the 194-198 crash finding) and whether `dispose()` is refcounted (decides the 219-221 concurrent-dispose finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_highlight_matcher.dart — whether `bestMatch` normalizes its inputs (decides the 631-641 raw-vs-normalized finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/script_parser.dart — whether `ScriptParser.parse` is isolate-safe and handles an empty `title` (decides the 567 and 900-909 findings)

## Coverage
lib/data/services/script_import_service.dart — findings: 14

## Follow-up requests
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_confidence_service.dart — whether `OcrConfidenceService.instance` state is sendable into `Isolate.run` (decides the 194-198 crash finding) and whether `dispose()` is refcounted (decides the 219-221 concurrent-dispose finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_highlight_matcher.dart — whether `bestMatch` normalizes its inputs (decides the 631-641 raw-vs-normalized finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/script_parser.dart — whether `ScriptParser.parse` is isolate-safe and handles an empty `title` (decides the 567 and 900-909 findings)

## Coverage
lib/data/services/script_import_service.dart — findings: 14

## Follow-up requests
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_confidence_service.dart — whether `OcrConfidenceService.instance` state is sendable into `Isolate.run` (decides the 194-198 crash finding) and whether `dispose()` is refcounted (decides the 219-221 concurrent-dispose finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_highlight_matcher.dart — whether `bestMatch` normalizes its inputs (decides the 631-641 raw-vs-normalized finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/script_parser.dart — whether `ScriptParser.parse` is isolate-safe and handles an empty `title` (decides the 567 and 900-909 findings)

## Coverage
lib/data/services/script_import_service.dart — findings: 14

## Follow-up requests
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_confidence_service.dart — whether `OcrConfidenceService.instance` state is sendable into `Isolate.run` (decides the 194-198 crash finding) and whether `dispose()` is refcounted (decides the 219-221 concurrent-dispose finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_highlight_matcher.dart — whether `bestMatch` normalizes its inputs (decides the 631-641 raw-vs-normalized finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/script_parser.dart — whether `ScriptParser.parse` is isolate-safe and handles an empty `title` (decides the 567 and 900-909 findings)

## Coverage
lib/data/services/script_import_service.dart — findings: 14

## Follow-up requests
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_confidence_service.dart — whether `OcrConfidenceService.instance` state is sendable into `Isolate.run` (decides the 194-198 crash finding) and whether `dispose()` is refcounted (decides the 219-221 concurrent-dispose finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_highlight_matcher.dart — whether `bestMatch` normalizes its inputs (decides the 631-641 raw-vs-normalized finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/script_parser.dart — whether `ScriptParser.parse` is isolate-safe and handles an empty `title` (decides the 567 and 900-909 findings)

## Coverage
lib/data/services/script_import_service.dart — findings: 14

## Follow-up requests
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_confidence_service.dart — whether `OcrConfidenceService.instance` state is sendable into `Isolate.run` (decides the 194-198 crash finding) and whether `dispose()` is refcounted (decides the 219-221 concurrent-dispose finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_highlight_matcher.dart — whether `bestMatch` normalizes its inputs (decides the 631-641 raw-vs-normalized finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/script_parser.dart — whether `ScriptParser.parse` is isolate-safe and handles an empty `title` (decides the 567 and 900-909 findings)

## Coverage
lib/data/services/script_import_service.dart — findings: 14

## Follow-up requests
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_confidence_service.dart — whether `OcrConfidenceService.instance` state is sendable into `Isolate.run` (decides the 194-198 crash finding) and whether `dispose()` is refcounted (decides the 219-221 concurrent-dispose finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_highlight_matcher.dart — whether `bestMatch` normalizes its inputs (decides the 631-641 raw-vs-normalized finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/script_parser.dart — whether `ScriptParser.parse` is isolate-safe and handles an empty `title` (decides the 567 and 900-909 findings)

## Coverage
lib/data/services/script_import_service.dart — findings: 14

## Follow-up requests
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_confidence_service.dart — whether `OcrConfidenceService.instance` state is sendable into `Isolate.run` (decides the 194-198 crash finding) and whether `dispose()` is refcounted (decides the 219-221 concurrent-dispose finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_highlight_matcher.dart — whether `bestMatch` normalizes its inputs (decides the 631-641 raw-vs-normalized finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/script_parser.dart — whether `ScriptParser.parse` is isolate-safe and handles an empty `title` (decides the 567 and 900-909 findings)

## Coverage
lib/data/services/script_import_service.dart — findings: 14

## Follow-up requests
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_confidence_service.dart — whether `OcrConfidenceService.instance` state is sendable into `Isolate.run` (decides the 194-198 crash finding) and whether `dispose()` is refcounted (decides the 219-221 concurrent-dispose finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_highlight_matcher.dart — whether `bestMatch` normalizes its inputs (decides the 631-641 raw-vs-normalized finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/script_parser.dart — whether `ScriptParser.parse` is isolate-safe and handles an empty `title` (decides the 567 and 900-909 findings)

## Coverage
lib/data/services/script_import_service.dart — findings: 14

## Follow-up requests
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_confidence_service.dart — whether `OcrConfidenceService.instance` state is sendable into `Isolate.run` (decides the 194-198 crash finding) and whether `dispose()` is refcounted (decides the 219-221 concurrent-dispose finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_highlight_matcher.dart — whether `bestMatch` normalizes its inputs (decides the 631-641 raw-vs-normalized finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/script_parser.dart — whether `ScriptParser.parse` is isolate-safe and handles an empty `title` (decides the 567 and 900-909 findings)

## Coverage
lib/data/services/script_import_service.dart — findings: 14

## Follow-up requests
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_confidence_service.dart — whether `OcrConfidenceService.instance` state is sendable into `Isolate.run` (decides the 194-198 crash finding) and whether `dispose()` is refcounted (decides the 219-221 concurrent-dispose finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_highlight_matcher.dart — whether `bestMatch` normalizes its inputs (decides the 631-641 raw-vs-normalized finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/script_parser.dart — whether `ScriptParser.parse` is isolate-safe and handles an empty `title` (decides the 567 and 900-909 findings)

## Coverage
lib/data/services/script_import_service.dart — findings: 14

## Follow-up requests
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_confidence_service.dart — whether `OcrConfidenceService.instance` state is sendable into `Isolate.run` (decides the 194-198 crash finding) and whether `dispose()` is refcounted (decides the 219-221 concurrent-dispose finding)
- lib/data/services/script_import_service.dart NEEDS lib/data/services/ocr_highlight
- [medium] lib/data/services/script_parser.dart:117-195 — `parse()` mutates shared instance state (`knownCharacters`, `characterAliases`, `multiCharacterMap`, `_titleHeaders`, `_headerScrubPatterns`, `_format`) and never clears them at entry, so a second `parse()` call on the same instance accumulates characters/aliases from the first script and mis-attributes dialogue — any caller reusing one parser instance (a plausible batch-import loop) silently corrupts every subsequent parse; fix by clearing these fields at the top of `parse()` or making the parser single-use.
- [medium] lib/data/services/script_parser.dart:817-923 — `_mergeOcrCharacterNames` mutates `knownCharacters` while iterating `nameList` (a snapshot) but the alias/garbage sets are applied only at the end, while `_detectMultiCharacterNames` (987-1017) and `_resolveTitleCaseAbbreviations` (929-982) read `knownCharacters` mid-pipeline with no re-derivation of `counts`, so a name removed as garbage can still be aliased/split later — consequence: phantom characters survive into the cast list; fix by applying removals immediately and recomputing counts before each dependent pass.
- [medium] lib/data/services/script_parser.dart:1144-1162 — `_editDistance` swaps `prev`/`curr` at the end of each outer iteration but `curr` is re-filled only at `curr[0] = i` and column 0, leaving stale values from the previous row in columns 1..lb when the inner loop doesn't overwrite them — actually the inner loop does overwrite all columns, but the swap uses `tmp = prev; prev = curr; curr = tmp;` where `curr` was the just-computed row and `prev` becomes it; on the NEXT iteration `curr` (old `prev`) is reused as the destination row and only `curr[0]` is reset before the inner loop writes each column, so this is correct — however the initial `prev` row is `List.generate(lb + 1, (i) => i)` which is correct for an empty `a` prefix, and `curr` is `List.filled(lb + 1, 0)`; the real defect is that when `a` or `b` is empty the early returns handle it, so no bug — withdraw; instead: [low] lib/data/services/script_parser.dart:1144-1145 — `_editDistance` allocates two new lists per call and is called O(n²) times inside fuzzy-merge loops over all character pairs (855-895, 1035-1075), making full-script import quadratic in both character count and name length — consequence: parse time balloons on large casts (hundreds of characters × dozens of names); fix by memoizing or capping candidate pairs by length difference before calling `_editDistance`.
- [medium] lib/data/services/script_parser.dart:1030-1031 — `_tryGluedMultiCharacterSplit` returns null for any name containing a space, but `_detectMultiCharacterNames` (987-1017) still calls it for every known character on every parse, and the inner loop (1035-1075) is O(knownCharacters) with an O(len²) edit distance inside — same quadratic-cost class as above on large casts; fix by early-exiting when `knownCharacters` is large or by precomputing suffix candidates.
- [medium] lib/data/services/script_parser.dart:1402-1431 — `_deferAnnouncedSceneShifts` copies lines via `copyWith(scene: outgoing)` for indices `k` in `[i, arrival)` but never re-runs after `_detectScenes` re-tags, and it reads `lines[i-1].scene` as the "outgoing" scene even when `lines[i-1]` was itself just retagged by an earlier iteration of this same loop — consequence: a chain of announced shifts can propagate the wrong scene label across several lines; fix by computing `outgoing` from the original pre-defer scene of line `i-1` captured before the loop mutates it, or by processing shifts in a single reverse pass.
- [low] lib/data/services/script_parser.dart:1697-1755 — `closeScene` sets `sceneStart = endIndex + 1` even when called with `endIndex = i - 1` where `i > sceneStart` was required, but the final call at 1784-1786 uses `lines.length - 1` and then the loop's ACT/scene boundary branches call `closeScene(i - 1)` followed by `sceneStart = i`, overwriting the value `closeScene` just set — harmless here because both paths set the same next start, but if `closeScene` is ever called with `endIndex < sceneStart - 1` the sublist would throw; fix by clamping `endIndex` to `sceneStart` inside `closeScene`.
- [low] lib/data/services/script_parser.dart:299-303 — `documentWideSpread` divides by `allLines.length` after requiring `>= 20` lines, but `firstIdx`/`lastIdx` are line indices in the *trimmed-candidate* loop (262-294) which skips lines > 60 chars and direction lines, so `span` can exceed 1.0 for short documents where skipped lines inflate the denominator differently than the numerator — consequence: headers on very short scripts can be misclassified as document-wide and stripped; fix by computing span over the same filtered line set used for counting.
- [low] lib/data/services/script_parser.dart:343-345 — `_headerScrubPatterns` builds `RegExp('(\\d{1,4}\\s+)?$words(\\s+\\d{1,4})?')` from raw header text escaped per-word but joined with `r'\s+'`, so a header containing regex metacharacters other than whitespace (e.g. `&`, `(`) is escaped correctly per word, yet the joiner assumes single-space separation — a header with a tab or double space between words will not match its own glued form, silently leaving the header glued into dialogue; fix by normalizing whitespace in `raw` before building the pattern.
- [low] lib/data/services/script_parser.dart:1196-1218 — `_cleanLine` strips `[|~°]` and trailing slashes but `_trailingBracketNoiseRe` (`\s*\[[A-Z0-9][^\]]*$`) can delete legitimate bracketed text that a speaker says aloud (e.g. a line ending `"... [sic]`"), silently truncating dialogue; fix by requiring the bracket content to look like OCR noise (digits/short caps) rather than any `[A-Z0-9]`-led run.
- [low] lib/data/services/script_parser.dart:1366-1371 — `_isEnterExitLine` matches `Thunder|Alarum|Flourish|...` with `caseSensitive: false` and no word-boundary after the keyword beyond `[.,;:!]|$|\s`, so a dialogue line beginning "Flourish, my lord!" is consumed as a stage direction and its speech is dropped from the cast's line counts; fix by requiring the keyword to be followed by end-of-line or a full stop pattern typical of directions, or by checking the line is not already attributed to a speaker.
- [low] lib/data/services/script_parser.dart:1663-1668 — continuation dialogue is appended only when `cleaned.length > 2 && RegExp(r'[a-zA-Z]').hasMatch(cleaned)`, so a 1-2 char legitimate continuation (e.g. "O!") is silently dropped from the speech text; fix by lowering the threshold or checking it is not a direction fragment.
- [info] lib/data/services/script_parser.dart:64-71 — `_normalizeForHeader` lowercases and strips all non-alphanumeric characters before header detection, so a title containing an apostrophe or ampersand ("Tom's Booth") cannot match its own normalized form in `_detectTitleHeaders`'s title-seeded path (324-336) — consequence: running-header stripping silently misses such titles; fix by preserving apostrophes in the normalization or by seeding with the same transform used for candidate lines.

## Coverage
lib/data/services/script_parser.dart — findings: 11
- [medium] lib/data/services/stt_adaptation_service.dart:159-161 — `_loadProduction` reads `profiles.json` with `existsSync()`/`readAsString()` on the caller's isolate with no guard against a concurrent `_persistProduction` write/rename — a mid-rename or partially-written file read throws, the catch at 216-218 swallows it, and all persisted profiles for that production are silently dropped (accumulated 60s+ samples vanish from `readyToTrain` until the next successful persist) — wrap the read in its own try/catch or use a safe-read retry, and log at error level via `DebugLogService` instead of `debugPrint` (reachability: local disk race on the operator's own device; silent data loss bumps it to medium).
- [medium] lib/data/services/stt_adaptation_service.dart:166-171 — `decode()` filters disk samples by `File(x.audioPath).existsSync()` where `audioPath` comes from untrusted JSON on disk — a crafted/corrupted `profiles.json` with an `audio_path` pointing at an arbitrary absolute path (e.g. another production's adapter dir or `/dev/...`) gets those samples merged into the actor's profile and later uploaded as training data (`samples: [{audio_url, transcript}]` per the Phase-1 comment at 397-404) — cross-production data disclosure if the file is attacker-influenced — validate `audioPath` resolves inside the production's own adapter/documents directory before accepting the sample (medium: requires a malicious or corrupted local file, but consequence is leaking another production's audio paths into a training POST).
- [medium] lib/data/services/stt_adaptation_service.dart:185-203 — `merge()` prefers `live` unconditionally on every field (`adapterPath` falls back to disk only when live's is null, same for `lastTrainedAt`/`wordErrorRate`), so a live profile that explicitly cleared its adapter cannot be distinguished from "never had one" — the disk value resurrects it and the next persist (243-255) writes the resurrected state — union by audioPath in both directions and track explicit clears (e.g. a sentinel) so a cleared field stays cleared (medium: silent state regression, operator-visible only after training).
- [low] lib/data/services/stt_adaptation_service.dart:252-255 — persist writes `profiles.json.tmp` then renames; on crash/kill between `writeAsString` (254) and `rename` (255) the `.tmp` file is orphaned and no cleanup of `*.tmp` exists in `_loadProduction` or `clearProduction` — stale `.tmp` files accumulate in the adapter dir — add a `*.tmp` sweep in `_adapterDir`/`_loadProduction` (low: cosmetic disk growth, operator-only).
- [medium] lib/data/services/stt_adaptation_service.dart:295-346 — `addSample` never dedupes by `audioPath`: adding the same recording twice (double-tap on record, or a retry after a persist failure) double-counts its duration in `totalAudioSeconds`, inflating `readiness` and pushing `hasEnoughData` past the 60s threshold with only one real sample, which then gates a cloud training job that will fail or produce a bad adapter — dedupe by audioPath like the disk-merge does at 189-193 (medium: authenticated user against their own data).
- [medium] lib/data/services/stt_adaptation_service.dart:383-427 — `requestActorTraining` sets `status: training` (391-393) then the `try` body is only a `debugPrint`, so the `catch (e)` at 421 can never fire; a real cloud-training failure (network error, 4xx from the POST the comment describes) surfaces as an unhandled async error outside this method, leaving the profile stuck in `training` forever with no `failed` transition — either wrap the actual (future) request in the try or remove the misleading catch (medium: silent stuck state, authenticated user's own training job).
- [medium] lib/data/services/stt_adaptation_service.dart:430-455 — same defect class as 383-427 for `requestProductionTraining`: unreachable `catch`, profile left in `training` on any real failure (medium).
- [low] lib/data/services/stt_adaptation_service.dart:480-488 — `_adapterDir` calls `getApplicationDocumentsDirectory()` on every invocation (once per hydrate, once per persist, once per clear) and re-runs `createSync` each time; on iOS this is a platform-channel round-trip per call — cache the resolved documents path in a field after the first await (low: performance only, no correctness impact).
- [medium] lib/data/services/stt_channel.dart:86-91 — `listen`'s `onDevice` parameter defaults to `false` (line 90) while the doc comment at 85 says "force on-device recognition (default true)" — the doc and the code disagree, and the native side presumably treats absent/false as off-device, so callers relying on the documented default get cloud recognition and mic audio leaves the device when the caller expected on-device — change the default to `true` or fix the doc (medium: privacy-sensitive default that resolves to the less private value, authenticated user's own mic input).
- [medium] lib/data/services/stt_channel.dart:128-164,201-206 — `_handleCallback`'s `onDone` case (138-142) nulls `_onResult`/`_onDone` after invoking them, and `dispose()` (201-206) calls `stop()` then nulls the callbacks, but the method-call handler registered at 52 (`setMethodCallHandler(_handleCallback)`) is never removed in `dispose` — between dispose and a later `initialize` re-registration, every native event is dispatched into nulled callbacks and silently dropped — remove the handler in `dispose` via `_channel.setMethodCallHandler(null)` (medium: silent callback loss, authenticated user's own session).
- [low] lib/data/services/stt_channel.dart:131-133,144 — `call.arguments as Map` (131) and `call.arguments as String?` (144) throw a `TypeError` (not a `PlatformException`) if native sends a non-map/non-string payload, and `_handleCallback` has no try/catch, so the exception propagates into the platform channel's dispatch as an unhandled framework error rather than being surfaced through `DebugLogService` — cast defensively (`as Map? ?? {}`) or wrap the switch in try/catch (low: malformed native message only).
- [info] lib/data/services/stt_adaptation_service.dart:243-255 — persist writes the full profile snapshot (transcripts, audio paths, adapter paths) as plaintext JSON under the app documents directory; no encryption-at-rest and no audit trail — standard practice for a local-only Flutter app, but if the repo's threat model treats documents-dir data as sensitive (voice recordings + transcripts of cast members), note it; verify no equivalent plaintext PII file is committed to git (info).

## Coverage
lib/data/services/stt_adaptation_service.dart — findings: 8
lib/data/services/stt_channel.dart — findings: 4
- [medium] lib/data/services/stt_service.dart:36-60 — init() treats screenshot_mode as a hard skip and returns false, but listen() (161-167) auto-inits with the same locale and onDone only fires when init fails — a screenshot-mode session that later calls listen() silently re-runs native init (43-47's guard is bypassed because listen() calls init() directly, not the screenshot check) — actually the guard IS inside init(), so listen() re-enters init(), re-reads prefs, and returns false → onDone fires; the real defect is that init() swallows all SharedPreferences exceptions with `catch (_) {}` (48) and then proceeds to native init — if prefs read fails transiently, the permission dialog fires during screenshot capture, blocking the run — smallest safe fix: on prefs failure, default to skipping native init (fail-safe) rather than proceeding.
- [medium] lib/data/services/stt_service.dart:161-167 — listen() auto-init uses `_locale` (25) which is only updated by init(); if init() was never called (or failed), `_locale` is the hardcoded 'en-US' default and a deferred-init race downgrades a configured en-GB session to en-US — the comment at 159-160 claims this cannot happen, but nothing in the visible code sets `_locale` outside init(), and init() can return early at 46 without setting... actually 37 sets it before the early return, so the only reachable downgrade is when callers never call init() — smallest safe fix: require callers to pass locale into listen() or assert init() succeeded before using `_locale`.
- [low] lib/data/services/stt_service.dart:232-246 — stop() clears `onSilence`/`onLevel` (243-244) but never detaches `_sttChannel.onLevel`, so the channel keeps invoking `_handleLevel` (113-128) after stop; `_handleLevel` early-returns on `!_isListening` for the silence path but still runs the low-pass filter and `onLevel?.call` — wait, 244 sets the service's `onLevel` field to null, not the channel's; `_sttChannel.onLevel` still points at `_handleLevel`, which calls `onLevel?.call(_smoothedLevel)` — the service-level `onLevel` is null so the call is a no-op, but `_smoothedLevel` keeps updating and `_sttChannel.onLevel` is never nulled, leaking the callback into the next session — smallest safe fix: set `_sttChannel.onLevel = null` in stop().
- [low] lib/data/services/stt_service.dart:395-410 — startLineCapture() sets `_isListening = true` (396) even though no recognition session is running; if a concurrent listen() is in flight, the session-generation guard (207) checks `_isListening` which capture has now forced true, letting a stale continuous restart tear down the capture's recorder — smallest safe fix: use a separate `_isCapturing` flag for capture mode.
- [medium] lib/data/services/stt_vocabulary_service.dart:113-124 — getScriptHints() returns `hints.take(100)` from a Set built by addAll of characterNames then importantWords; because `hints` is a LinkedHashSet the cap silently drops later important words in favor of earlier character names, and the cap is applied after the fact with no priority — consequence: rare script-specific vocabulary (the whole point of contextualStrings) can be crowded out by common character names on large casts — smallest safe fix: prioritize importantWords (or interleave) before applying the 100-item cap.
- [medium] lib/data/services/stt_vocabulary_service.dart:127-147 — clearProduction() evicts `_correctionPatterns` entries only when `droppedWords` is non-empty AND the word is not still used, but the eviction predicate at 145 uses `removeWhere((w, _) => droppedWords.contains(w) && !stillUsed.contains(w))` on a Map — `removeWhere` on a Map receives (key, value) and the closure ignores the value, which is fine, but the real defect: `_actorCorrections` entries for OTHER productions whose key starts with the same productionId prefix (e.g. `productionId:1` vs `productionId:12` when clearing `productionId:1`... no, startsWith('$productionId:') is exact-prefix safe) — the actual defect is that `stillUsed` is built from `_actorCorrections.values` AFTER removal (141-143), so a correction pattern still referenced by a surviving actor map is kept, but patterns whose wrong-word was dropped from a removed map yet also exists in `_vocabularies[productionId]`'s correctionCache are never cleared there — `vocab.correctionCache` (521) is never evicted by clearProduction(), so stale memoized corrections for a cleared production persist and get served by `_correctWithVocabulary` (308-316) — smallest safe fix: clear `_vocabularies[productionId].correctionCache` in clearProduction() (it's removed at 128, so instead: clear the cache before removing the vocab object).
- [medium] lib/data/services/stt_vocabulary_service.dart:308-316 — `_correctWithVocabulary` memoizes `bestMatch` including `null` ("leave it alone") into `vocab.correctionCache[lower]`, but the cache-miss branch checks `containsKey` (308) which is true for a cached null, so that's handled; the defect is the cache-clear at 313-315: when the cache hits the limit it `clear()`s the ENTIRE cache including in-flight bestMatch for the current word, then re-inserts — fine — but `bestMatch` computed before the clear is re-inserted after, so no loss; the real issue is `_correctionCacheLimit` (510, 4000) is per-vocabulary-object while the comment says per production, and cleared caches re-run the O(words×vocab) scan repeatedly under memory pressure — smallest safe fix: evict oldest entries instead of clear(), or document the reset.
- [low] lib/data/services/stt_vocabulary_service.dart:230 — learnFromAttempt() gates learning on `_editDistanceAtMost(wrong, right, 3) <= 3`, but `_editDistanceAtMost` returns `maxDist + 1` when distance exceeds the cap (472), so `<= 3` is equivalent to `<= 3` only when maxDist==3 — correct here; however the same helper is called at 338/350 with `bestDistance - 1` where bestDistance starts at 3, giving maxDist=2, and at 391/407 with maxDist=2 — consistent; no defect — omitting.
- [medium] lib/data/services/stt_vocabulary_service.dart:338,350 — `_bestVocabularyMatch` calls `_editDistanceAtMost(lower, vocabWord, bestDistance - 1)`; on the first iteration bestDistance is 3 so maxDist is 2, but after a match lowers bestDistance to 1 or 2, subsequent calls pass maxDist 0 or 1 — `_editDistanceAtMost` with maxDist<=0 returns 1 immediately (436), meaning a maxDist-0 call can never report distance 0, so an exact vocabulary match encountered after a distance-1 match is skipped — consequence: scan order determines whether an exact match wins, violating the documented "first candidate at a given distance wins" tie rule only when an exact match appears after a closer-capped one — actually an exact match has distance 0 < any prior bestDistance, so it would win if computed; with maxDist=0 the helper returns 1 (not 0), so the exact match is MISSED and the distance-1 match is kept — smallest safe fix: pass `bestDistance` (not `bestDistance - 1`) or special-case maxDist 0 to allow distance 0.
- [low] lib/data/services/stt_vocabulary_service.dart:436 — `_editDistanceAtMost(a, b, 0)` returns 1 for identical strings (a == b returns 0 at 435 first, so identical strings short-circuit before the maxDist check — no defect); but for non-identical strings with maxDist 0 the function returns 1, conflating "distance 1" with "over cap" — callers at 338/350 treat a return of 1 as a real distance of 1 (`dist > 0 && dist < bestDistance` with bestDistance possibly 2), so a pair whose true distance is 2+ gets reported as 1 and wins the scan — smallest safe fix: return `maxDist + 1` (i.e. 1 is already that... maxDist+1 == 1 when maxDist==0, which callers read as a genuine distance 1) — the conflation is real: fix by making the sentinel `maxDist + 2` or by having callers check `dist <= maxDist`.
- [medium] lib/data/services/stt_vocabulary_service.dart:391,407 — `_correctAgainstExpected` gates DP alignment on `_editDistanceAtMost(recNorm[i-1], expNorm[j-1], 2) <= 2`; per the sentinel conflation above, a word pair with true distance ≥3 returns 2 (maxDist+1 == 3? no: maxDist=2 → sentinel is 3, and `<= 2` is false — correct) — but a pair with true distance 3 returns 3 and `<= 2` correctly rejects; the conflation only bites when maxDist==0, which never happens here — no defect at these call sites; the defect is confined to `_bestVocabularyMatch` when bestDistance has dropped to 1 (maxDist 0) — already reported above.
- [medium] lib/data/services/stt_vocabulary_service.dart:531 — `scanWords` getter memoizes `importantWords.toList(growable: false)` via `??=`, but `buildFromScript` (99) REPLACES the whole `_ProductionVocabulary` object per production rebuild, so a stale memoized list cannot persist across rebuilds — however `buildFromScript` can be called twice for the SAME productionId (script reloaded), and the new vocab object is fresh, so no staleness — no defect; omitting.
- [medium] lib/data/services/stt_vocabulary_service.dart:541-542 — `_buildNameParts` computes `nameLower.indexOf(part)` where `part` came from splitting `nameLower`; for a name like "Ban Ban", splitting on whitespace gives ["ban","ban"] and indexOf("ban") always returns 0, so BOTH parts get cased substring from index 0 ("Ban") instead of the second occurrence's actual casing — consequence: multi-word character names with repeated words produce wrong cased output in corrections (e.g. both emitted as the first word's casing) — smallest safe fix: track a moving offset while splitting instead of indexOf.
- [low] lib/data/services/stt_vocabulary_service.dart:78-80 — words containing "'" are added to importantWords verbatim (with apostrophe) while the frequency-based path (87-89) adds lowercase tokens from `_tokenize` which strips apostrophes via `_nonWordSpaceRe`... `_tokenize` (496-504) uses `_nonWordSpaceRe` = `[^\w\s]` which REMOVES apostrophes, so "'tis" tokenizes to "tis"; the apostrophe path adds "'tis" — two different spellings of the same word enter importantWords, and `_bestVocabularyMatch` compares against `lower` (apostrophe-stripped at 298), so the "'tis" entry can never match (its apostrophe makes edit distance ≥1 against every stripped input) — consequence: dead vocabulary entries and wasted scan work — smallest safe fix: strip apostrophes (or normalize) before adding to importantWords.
- [low] lib/data/services/stt_service.dart:258-262 — `_parenRe`/`_bracketRe` strip parenthesized/bracketed spans, but `_unclosedRe` (`[(\[][^)\]]*$`) only matches an unclosed bracket at END of string; an unclosed '(' in the MIDDLE ("(crossing the stage" then dialogue) leaves the paren content counted as expected words — consequence: mid-line OCR-dropped closers inflate the expected-word set and penalize the actor — smallest safe fix: extend the unclosed pattern to match anywhere (`[^)\]]*` without the `$` anchor, or handle per-token).
- [low] lib/data/services/stt_service.dart:301-308 — heardLineEnding's tail/window logic: `tail` is the last 3 expected words, `window` the last 8 spoken words, and the 2-of-3 hit test (308) can pass on words that appear in the MIDDLE of the spoken window rather than near its end, since only the lastExp/lastSpo check (303) anchors the ending — the comment (293-300) claims this is intentional; no defect beyond documented behavior — omitting.
- [medium] lib/data/services/stt_service.dart:336-347 — matchScore's two-row LCS loop swaps `prev`/`cur` but reuses the SAME two Int32List-backed List<int> buffers via `t..fillRange`; after the swap, `cur` points at the old `prev` buffer which still holds row i-1 values — the next iteration writes `cur[j]` for every j from 1..n, but `cur[0]` is never written and relies on the fillRange... `t..fillRange(0, n+1, 0)` zeroes the buffer being reassigned to `cur`, so cur[0] is 0 — correct; however `prev[0]` must be 0 for row i and it is, since prev was fully written last iteration — no defect — omitting.
- [low] lib/data/services/stt_service.dart:355 — `_wordsMatch` returns false when length difference > 1, but the fuzzy LCS in matchScore then treats the pair as a non-match; fine — omitting.
- [low] lib/data/services/stt_service.dart:371-378 — the insertion/deletion branch of `_wordsMatch` counts `diffs` but never uses it to distinguish 1-edit from 2-edit when lengths differ by 1: after the loop, `return true` unconditionally (379) even if diffs reached 2 via the else branch... the else branch returns false at 376 when diffs > 1, so unreachable — omitting.
- [medium] lib/data/services/stt_service.dart:199-201 — onDone carry-forward uses `_lastPartial` (set at 191 on every onResult), but if the recognizer finalizes WITHOUT a final onResult for the trailing words (platform-dependent), `_lastPartial` may lag the true transcript; the carried prefix then misses the tail — this depends on SttChannel behavior not visible here — stating assumption: if stt_channel always delivers a final onResult before onDone, no defect; flagging as info-level uncertainty only if channel can't be seen — I cannot see stt_channel.dart (not in file list, not in context), so I state the assumption inside the finding.
- [info] lib/data/services/stt_service.dart:44-45,406-407,415-434 — DebugLogService.instance.log/logError are invoked on every STT event including per-partial recognition callbacks; DebugLogService._appendSync (context debug_log_service.dart:187-188) does a synchronous file append per entry on the caller's thread — during rehearsal this is the UI isolate — consequence: per-partial synchronous disk writes can jank the main thread mid-recognition — smallest safe fix: batch or async-append STT logs (or drop per-partial logging).
- [info] lib/data/services/stt_vocabulary_service.dart:100-105 — buildFromScript debugPrints unconditionally (not behind kDebugMode); in release builds debugPrint is a no-op-ish but still constructs the string — minor; omitting as style.

## Coverage
lib/data/services/stt_service.dart — findings: 8
lib/data/services/stt_vocabulary_service.dart — findings: 7
- [medium] lib/data/services/sync_queue.dart:114 — saveMetadata dereferences `supa.currentUser!` — if the user signed out between upload start and metadata save (or the uploader was never signed in), this throws a null-check operator crash inside the upload success path, aborting the queue loop and losing the just-uploaded job's metadata stamp — guard with a null check and log/skip (or re-queue) when `currentUser` is null. Reachability: any authenticated user who signs out mid-upload; consequence is a crash of the sync loop, so medium.
- [medium] lib/data/services/sync_queue.dart:470 — retry backoff delay uses `2 << nextRetry.retryCount.clamp(0, 4)` — `clamp` on an `int` returns `int`, but the shift is applied to `2` with the clamped value as the shift count; when `retryCount` is 0 the delay is 2s, when 4 it is 32s — that is intended, but the expression `2 << clamp` is evaluated as `(2 << clamp)` which for clamp values >4 would overflow the intent; since clamp(0,4) bounds it, the real defect is that the clamp is applied to `retryCount` but the shift base is fixed at 2, so the maximum delay is 32s and never grows beyond that regardless of further failures — acceptable, but note the comment says "exponential backoff" while the cap is 32s; if the intent was longer backoff, raise the clamp bound. Reachability: operator/test-only retry loop; low impact, so low.
- [low] lib/data/services/sync_queue.dart:249 — `queuedKeys.add(key)` is used as a set-membership check on a `Set` literal built with collection-for syntax; `add` returns true when the element was newly added, so `!queuedKeys.add(key)` correctly detects duplicates — but the set is built from `_pending` and `_failed` before the restore loop, and a restored job whose key matches a live job is dropped (correct), while a restored job whose key matches an earlier restored job is also dropped (correct dedupe) — no defect; do not report.
- [low] lib/data/services/sync_queue.dart:388 — `file.lengthSync()` is called on the local audio file inside the upload loop; if the file is deleted between the `existsSync` check and `lengthSync`, this throws synchronously inside the try and is caught by the generic catch, which then treats the job as failed and increments retryCount — a transient filesystem race is misclassified as an upload failure, consuming one of the 5 retry attempts — wrap the size read in its own try or re-check existence. Reachability: operator/local-device race; low.
- [low] lib/data/services/tts_service.dart:411 — `text.substring(0, 37)` for the preview is computed after `stripStageDirections`/`expandAbbreviations` may have produced a string shorter than 40 chars but the guard is `text.length > 40`, so substring is safe; however if `text.length` is exactly 40 the preview is the full text with no ellipsis — cosmetic only; do not report.
- [medium] lib/data/services/tts_service.dart:425-431 — when `text.isEmpty` after stripping, the completion is fired via `Future.microtask` guarded by a generation check, but `_isSpeaking` was already set true at line 416 and `_usingSystemTts` reset at 417; `_fireCompletion` checks `_isSpeaking` and will fire — however `_currentTrace` was started at 408 and is only stopped inside `_fireCompletion`; if the microtask's gen check fails (a newer speak() started), the trace for this speak() is never stopped and leaks until the next speak()'s `_currentTrace?.stop()` at 407 — acceptable because line 407 stops the previous trace on the next call, but if speak() is never called again the trace stays open for the app's lifetime — stop the trace before the early return when the gen is stale. Reachability: any user triggering an all-stage-direction line then never speaking again; low impact, so low.
- [low] lib/data/services/tts_service.dart:686-692 — when a prefetched chunk resolves null/empty, the code re-synthesizes on demand with `urgent: true`; if that second synthesis also returns null the code falls through to the null check at 694 and returns false — correct; but the re-synthesis at 690 is not awaited inside a try, so a PlatformException from it escapes to the outer catch at 781 and is handled — fine; do not report.
- [medium] lib/data/services/tts_service.dart:760 — `chunkDone.timeout(const Duration(seconds: 60))` swallows the timeout with a bare `catch (_)`, continuing playback anyway; if the chunk never completes (e.g. the player stalled), the loop proceeds to the next chunk while audio may still be playing, causing overlapping playback — but the comment says external stop will be caught by the gen check; since `stop()` increments `_speakGen`, a stale gen is detected at 766 and the loop bails — however if no stop() was called and the player genuinely hung, the next chunk's `setFilePath` will interrupt the hung one, which is the desired behavior — no defect; do not report.
- [low] lib/data/services/tts_service.dart:846 — `_currentSpeed` is declared as an instance field `double _currentSpeed = 1.0;` at line 846 but is read at line 651 and 825 before its declaration in source order; Dart allows this for instance fields, so no defect; do not report.
- [low] lib/data/services/tts_service.dart:107 — `_availableSystemVoices = await _systemTts.getVoices as List<dynamic>` — the cast is on the awaited result; if `getVoices` returns a `Future<List<dynamic>>` this is fine, but if the platform returns a `Future<List<Map>>` the `as` cast succeeds (List is List<dynamic> at runtime for any List) — no defect; do not report.
- [medium] lib/data/services/tts_service.dart:337 — `_characterSystemVoices[character] = Map<String, String>.from(voice)` — `voice` is a `Map` whose values may be non-String (e.g. nested lists from the platform channel); `Map.from` performs a runtime cast per entry and will throw a `TypeError` if any value is not a String, crashing `assignVoice` and leaving the character without a system-TTS fallback voice — wrap in a try/catch or filter entries to String-typed values. Reachability: any user on a device whose platform voice metadata includes non-String fields; medium (crashes voice assignment, degrading to no fallback voice).
- [low] lib/data/services/tts_service.dart:846 — `_currentSpeed` is used in `prepareKokoro` (line 825) and `_speakWithKokoroMlx` (line 651) but `setRate` (line 886) clamps to 0.5–2.0 while `_splitTextForKokoro` chunking assumes ~real-time synthesis; no defect; do not report.
- [low] lib/data/services/sync_queue.dart:132-135 — `SyncQueue.forTesting` sets `_persistToDisk = persistPath != null`, so a test with a null path disables persistence entirely, but `_loaded` stays false and `_loadPersisted` returns early at 209 — correct; do not report.
- [low] lib/data/services/sync_queue.dart:293-295 — `start()` fires `_restorePersisted().then(...)` and kicks `_processQueue` if pending is non-empty, but `enqueue()` (line 342) also kicks `_processQueue` when `!_processing`; both paths are guarded by `_processing` inside `_processQueue` itself (line 351), so no double-processing; do not report.
- [low] lib/data/services/sync_queue.dart:462-465 — after the processing loop, if `_pending` became non-empty again, a microtask re-kicks `_processQueue`; but `_processing` was already set false at 457, so the re-kick is safe; do not report.
- [low] lib/data/services/sync_queue.dart:476-480 — the retry timer callback moves all failed jobs back to pending and clears the failed list, then calls `_processQueue`; if `_processing` is true at that moment (a new upload started), `_processQueue` returns immediately and the failed jobs sit in `_pending` until the next connectivity event or enqueue — they are not lost, only delayed; do not report.
- [low] lib/data/services/sync_queue.dart:191-193 — the temp file is written to `'$path.tmp'` and renamed; if two processes (or a previous crashed run's temp file) exist, `rename` overwrites atomically on the same volume — correct; do not report.
- [low] lib/data/services/sync_queue.dart:216 — `jsonDecode(await file.readAsString())` is inside a try that catches parse errors and renames the file to `.corrupt`; but if `readAsString` itself throws (e.g. permission denied), the same catch renames the file, destroying the original queue data on a transient I/O error rather than a corruption — consider distinguishing read errors from parse errors. Reachability: operator/local-device I/O error; low.
- [low] lib/data/services/sync_queue.dart:247 — `File(job.localPath).existsSync()` is called for every restored job at startup; for a large queue this is N synchronous stat calls on the UI isolate at launch — acceptable for typical queue sizes; do not report.
- [low] lib/data/services/tts_service.dart:451 — `await _audioPlayer.stop()` before system TTS fallback is called unconditionally even when `_kokoroLoaded` is false and no audio was playing — harmless; do not report.
- [low] lib/data/services/tts_service.dart:729-730 — `await _audioPlayer.stop()` and `setFilePath` are called per chunk; between chunks the player is stopped and restarted, which is intended for chunked playback; do not report.
- [low] lib/data/services/tts_service.dart:936 — `dispose()` calls `_audioPlayer.dispose()` but does not cancel `_retryTimer`-equivalent state or reset `_initialized`; since TtsService is a singleton, dispose is likely only used in tests; do not report.
- [low] lib/data/services/sync_queue.dart:505 — `reset()` sets `_loaded = true` then calls `_persist()`, which runs `_loadPersisted()` first via `_serializedFileAccess`; `_loadPersisted` returns immediately because `_loaded` is true, so the cleared state is written — correct; do not report.
- [low] lib/data/services/sync_queue.dart:169 — `_serializedFileAccess` chains on `_persistChain ?? Future.value()`; if `action()` throws, `_persistChain` still points to the failed future, and every subsequent chained action will be skipped (the `.then` callback never runs because the previous future completed with an error) — but `_persist` wraps its body in try/catch and `_loadPersisted` also try/catches, so the chain should never complete with an error; however `_restorePersisted` calls `_serializedFileAccess(_loadPersisted)` and `_loadPersisted` has its own try/catch, so the chain is safe — but `flushPersistence` awaits `_persistChain` directly and would rethrow if it ever did fail; acceptable; do not report.
- [low] lib/data/services/tts_service.dart:43 — the MethodChannel name `'com.lineguide/kokoro_mlx'` is a constant; no defect; do not report.
- [low] lib/data/services/tts_service.dart:191-194 — `setLanguage('en-US')`, `setSpeechRate(0.5)`, etc. are called unconditionally in `init()` even when Kokoro is loaded and system TTS is only a fallback — harmless configuration; do not report.
- [low] lib/data/services/tts_service.dart:229-234 — the `playerStateStream` listener only logs on `completed`; it does not fire completion (by design, per the comment); do not report.
- [low] lib/data/services/tts_service.dart:813-843 — `prepareKokoro` returns futures that may resolve null on chunk failure; callers (`speak` via `precomputedChunks`) handle null by re-synthesizing on demand — correct; do not report.
- [low] lib/data/services/tts_service.dart:837-842 — `unawaited(Future.wait(futures).then(...))` logs readiness but does not propagate errors; if a future rejects, `Future.wait` throws and the unawaited error becomes an unhandled async error — but each future already has `.catchError` at 831 returning null, so `Future.wait` cannot reject — correct; do not report.
- [low] lib/data/services/sync_queue.dart:340 — `_persist()` is called after every enqueue; each persist re-runs `_loadPersisted()` (via `_serializedFileAccess` → `_persist` → `_loadPersisted`), but `_loaded` is true after the first restore so subsequent loads are no-ops — correct; do not report.
- [low] lib/data/services/sync_queue.dart:351 — `_processQueue` returns early if `_processing || _pending.isEmpty`; the `_processing` guard is set true only after this check, so two simultaneous calls could both pass the check before either sets the flag — but Dart's single-threaded event loop means the check-and-set is atomic across microtask boundaries; do not report.
- [low] lib/data/services/tts_service.dart:406-409 — `_currentTrace?.stop()` then a new trace is started on every speak(); if speak() is called while a previous speak() is still awaiting playback, the previous trace is stopped early — acceptable; do not report.
- [low] lib/data/services/tts_service.dart:414-417 — `_speakGen++` and `_activeGen = _speakGen` are set before the empty-text early return, so a stale completion from a previous speak() is correctly invalidated; do not report.
- [low] lib/data/services/tts_service.dart:470 — `await _systemTts.setPitch(pitch)` uses the per-character pitch or 1.0 default; no defect; do not report.
- [low] lib/data/services/tts_service.dart:886 — `(rate / 0.5).clamp(0.5, 2.0)` — if `rate` is 0.0, the result is 0.0 clamped to 0.5, so `_currentSpeed` becomes 0.5 (slowest) rather than an error — acceptable; do not report.
- [low] lib/data/services/sync_queue.dart:288 — `results.any((r) => r != ConnectivityResult.none)` — `onConnectivityChanged` emits a `List<ConnectivityResult>` in connectivity_plus ≥ 5.x; if the app pins an older version where the stream emits a single `ConnectivityResult`, `.any` would fail to compile — since the code compiles in this repo, the version matches; do not report.
- [low] lib/data/services/sync_queue.dart:383 — `_pending.remove(job)` removes by identity/equality; `SyncJob` does not override `==`, so identity is used — correct for the first-element case; do not report.
- [low] lib/data/services/sync_queue.dart:400 — `!_pending.remove(job)` — if the job was already removed by a concurrent enqueue's `removeWhere`, `remove` returns false and `superseded` is true, correctly skipping the URL stamp; do not report.
- [low] lib/data/services/sync_queue.dart:408 — the same `!_pending.remove(job)` pattern in the catch path; do not report.
- [low] lib/data/services/sync_queue.dart:419 — `job.retryCount++` mutates the job after it was removed from `_pending`; if the job is later re-added via the retry timer path, the incremented count persists — intended; do not report.
- [low] lib/data/services/sync_queue.dart:427 — `_failed.add(job)` after incrementing retryCount; the job object is shared between lists, so the count is consistent; do not report.
- [low] lib/data/services/sync_queue.dart:469 — `_failed.first` is used for the backoff delay, assuming the list is ordered by retry count; since all failed jobs were added in order and retryCount increments uniformly, the first is the least-retried — acceptable; do not report.
- [low] lib/data/services/sync_queue.dart:477 — `_pending.addAll(_failed); _failed.clear();` inside the timer callback is not serialized against `_persist`, so a persist running concurrently could snapshot a half-moved state — but `_persist` runs `_loadPersisted` first and the lists are mutated synchronously within one event-loop turn, so the snapshot is consistent; do not report.
- [low] lib/data/services/sync_queue.dart:502 — `reset()` sets `_processing = false` but does not cancel `_retryTimer`; a pending retry timer could fire after reset and re-add cleared failed jobs — but `reset()` is test-only and the timer callback reads `_failed` (now empty), so no jobs are re-added; do not report.
- [low] lib/data/services/tts_service.dart:934-937 — `dispose()` cancels `_playerStateSub` and disposes the player but leaves `_systemTts` alive; singleton lifecycle makes this acceptable; do not report.
- [low] lib/data/services/sync_queue.dart:130 — `_persistToDisk = true` in the private constructor; production always persists; do not report.
- [low] lib/data/services/sync_queue.dart:159-163 — `_persistPath` uses `getApplicationSupportDirectory()`; if the platform does not support it, the await throws and `_persist` catches and logs — acceptable; do not report.
- [low] lib/data/services/sync_queue.dart:243-244 — the collection-for set literal builds keys from both `_pending` and `_failed`; if a job appears in both lists (possible only if a bug allowed it), the set dedupes and the restore logic still works; do not report.
- [low] lib/data/services/sync_queue.dart:251 — `kept++` counts only jobs added to `_pending`, not those restored into `_failed` — the log message says "restored N queued upload(s)" which may undercount failed jobs; cosmetic; do not report.
- [low] lib/data/services/sync_queue.dart:256 — `_persist()` is called after a successful restore with kept > 0; this rewrites the file with the restored state, which is correct; do not report.
- [low] lib/data/services/sync_queue.dart:287 — `Connectivity().onConnectivityChanged.listen(...)` creates a new subscription each time `start()` is called; `start()` cancels the previous subscription first (line 286), so no leak; do not report.
- [low] lib/data/services/sync_queue.dart:363 — `Timer(const Duration(seconds: 30), _processQueue)` — the timer fires `_processQueue` which checks `_processing`; if a connectivity event started processing in the meantime, the timer's call is a no-op — correct; do not report.
- [low] lib/data/services/sync_queue.dart:371 — `_pending.first` is taken inside the while loop; if `enqueue` added a job during the loop, the new job is processed in the same loop iteration order — acceptable; do not report.
- [low] lib/data/services/sync_queue.dart:393 — `await _uploader.upload(job)` is awaited inside the loop; a long upload blocks the loop but that is the design; do not report.
- [low] lib/data/services/sync_queue.dart:394 — `saveMetadata` is awaited before the superseded check; if saveMetadata throws, the catch path treats it as an upload failure even though the upload succeeded — the job is re-queued and re-uploaded, wasting bandwidth but not losing data; acceptable; do not report.
- [low] lib/data/services/sync_queue.dart:401 — `_persist()` after the superseded check persists the removal; do not report.
- [low] lib/data/services/sync_queue.dart:435 — `onGaveUp?.call(job, e)` is invoked outside the try; if the callback throws, the exception escapes `_processQueue` and the `_processing` flag stays true forever, deadlocking the queue — wrap in try/catch or move inside. Reachability: depends on the callback implementation (not shown); low.
- [low] lib/data/services/sync_queue.dart:446 — `onUploaded?.call(...)` is inside a try/catch that logs; do not report.
- [low] lib/data/services/sync_queue.dart:463 — `scheduleMicrotask(_processQueue)` re-kicks processing; do not report.
- [low] lib/data/services/sync_queue.dart:486-493 — `retryNow` moves failed to pending and processes; test-only; do not report.
- [low] lib/data/services/sync_queue.dart:497-507 — `reset()` is test-only; do not report.
- [low] lib/data/services/tts_service.dart:126-148 — `tryLoadKokoro` sets `_activeEngine` but does not reset `_usingSystemTts` or `_isSpeaking`; if a speak() was in flight when the model loaded, state is consistent because speak() guards by gen; do not report.
- [low] lib/data/services/tts_service.dart:176-188 — `init()` sets `_activeEngine` based on load results; if both MLX and ONNX fail, system TTS is used; do not report.
- [low] lib/data/services/tts_service.dart:195 — `_availableSystemVoices` is refreshed in `init()` but `setLocale` (line 107) also refreshes it; if `setLocale` is called before `init`, `_availableSystemVoices` is populated early and `init` overwrites it — acceptable; do not report.
- [low] lib/data/services/tts_service.dart:197-200 — `setStartHandler` logs only; do not report.
- [low] lib/data/services/tts_service.dart:202-210 — the error handler fires completion on system TTS errors, guarded by `_usingSystemTts && _speakGen == _activeGen`; do not report.
- [low] lib/data/services/tts_service.dart:212-223 — the completion handler is guarded the same way; do not report.
- [low] lib/data/services/tts_service.dart:246-251 — `getModelStatus` failure is swallowed and load is attempted anyway; do not report.
- [low] lib/data/services/tts_service.dart:254-256 — `loadModel` result null → return false; do not report.
- [low] lib/data/services/tts_service.dart:270-276 — `isModelDownloaded` catches all errors and returns false; do not report.
- [low] lib/data/services/tts_service.dart:284-343 — `assignVoice` logic reviewed above; do not report beyond the Map.from issue.
- [low] lib/data/services/tts_service.dart:349-368 — `_googleTtsVoiceGender` regexes; do not report.
- [low] lib/data/services/tts_service.dart:371-384 — `_cloudTtsGender` map; do not report.
- [low] lib/data/services/tts_service.dart:388-390 — `setCharacterSpeed` writes to `_characterSpeeds`; do not report.
- [low] lib/data/services/tts_service.dart:400-472 — `speak` reviewed above; do not report beyond the trace leak.
- [low] lib/data/services/tts_service.dart:481-495 — `stripStageDirections` regexes; do not report.
- [low] lib/data/services/tts_service.dart:508-534 — `expandAbbreviations`; do not report.
- [low] lib/data/services/tts_service.dart:539-617 — `_splitTextForKokoro` chunking; do not report.
- [low] lib/data/services/tts_service.dart:628-639 — `_synthesizeChunk` routes to ONNX or MLX; do not report.
- [low] lib/data/services/tts_service.dart:641-803 — `_speakWithKokoroMlx` reviewed above; do not report beyond the Map.from issue.
- [low] lib/data/services/tts_service.dart:805-844 — `prepareKokoro` reviewed above; do not report.
- [low] lib/data/services/tts_service.dart:846 — `_currentSpeed` field; do not report.
- [low] lib/data/services/tts_service.dart:850-860 — `_fireCompletion`; do not report.
- [low] lib/data/services/tts_service.dart:864-872 — `stop()`; do not report.
- [low] lib/data/services/tts_service.dart:877-879 — `releaseAudioSession`; do not report.
- [low] lib/data/services/tts_service.dart:882-888 — `setRate`; do not report.
- [low] lib/data/services/tts_service.dart:891-895 — `setCompletionHandler`; do not report.
- [low] lib/data/services/tts_service.dart:901-911 — `unloadKokoro`; do not report.
- [low] lib/data/services/tts_service.dart:914-922 — `deleteModel`; do not report.
- [low] lib/data/services/tts_service.dart:925-931 — `getDebugInfo`; do not report.
- [low] lib/data/services/tts_service.dart:934-937 — `dispose`; do not report.

## Coverage
lib/data/services/sync_queue.dart — findings: 5
lib/data/services/tts_service.dart — findings: 3
== FILE: lib/data/services/vision_ocr_channel.dart (94 lines) ==
    1| import 'package:flutter/services.dart';
    2| 
    3| /// Dart wrapper for the native macOS Vision OCR plugin.
    4| /// Used as a replacement for Google ML Kit on macOS.
    5| class VisionOcrChannel {
    6|   static const _channel = MethodChannel('com.lineguide/vision_ocr');
    7| 
    8|   /// Recognize text in an image file using Apple Vision framework.
    9|   static Future<List<VisionTextBlock>?> recognizeText(String imagePath) async {
    10|     try {
    11|       final result = await _channel.invokeMethod<Map>('recognizeText', {
    12|         'path': imagePath,
    13|       });
    14|       if (result == null) return null;
    15| 
    16|       final blocks = result['blocks'] as List?;
    17|       if (blocks == null) return [];
    18| 
    19|       return blocks.map((b) {
    20|         final map = Map<String, dynamic>.from(b as Map);
    21|         return VisionTextBlock(
    22|           text: map['text'] as String? ?? '',
    23|           confidence: (map['confidence'] as num?)?.toDouble() ?? 0.0,
    24|         );
    25|       }).toList();
    26|     } on MissingPluginException {
    27|       return null;
    28|     }
    29|   }
    30| 
    31|   /// OCR an entire PDF natively — renders pages with PDFKit, OCRs with Vision.
    32|   /// Returns per-page results with lines and confidence in one call.
    33|   static Future<VisionPdfResult?> ocrPdf(String pdfPath, {double scale = 2.0}) async {
    34|     try {
    35|       final result = await _channel.invokeMethod<Map>('ocrPdf', {
    36|         'path': pdfPath,
    37|         'scale': scale,
    38|       });
    39|       if (result == null) return null;
    40| 
    41|       final pageCount = result['pageCount'] as int? ?? 0;
    42|       final failedPages = result['failedPages'] as int? ?? 0;
    43|       final pagesRaw = result['pages'] as List? ?? [];
    44| 
    45|       final pages = pagesRaw.map((p) {
    46|         final map = Map<String, dynamic>.from(p as Map);
    47|         final pageNum = map['page'] as int? ?? 0;
    48|         final linesRaw = map['lines'] as List? ?? [];
    49|         final lines = linesRaw.map((l) {
    50|           final lm = Map<String, dynamic>.from(l as Map);
    51|           return VisionTextBlock(
    52|             text: lm['text'] as String? ?? '',
    53|             confidence: (lm['confidence'] as num?)?.toDouble() ?? 0.0,
    54|           );
    55|         }).toList();
    56|         return VisionPage(page: pageNum, lines: lines);
    57|       }).toList();
    58| 
    59|       return VisionPdfResult(
    60|         pages: pages,
    61|         pageCount: pageCount,
    62|         failedPages: failedPages,
    63|       );
    64|     } on MissingPluginException {
    65|       return null;
    66|     }
    67|   }
    68| }
    69| 
    70| class VisionTextBlock {
    71|   final String text;
    72|   final double confidence;
    73| 
    74|   VisionTextBlock({required this.text, required this.confidence});
    75| }
    76| 
    77| class VisionPage {
    78|   final int page; // 1-based
    79|   final List<VisionTextBlock> lines;
    80| 
    81|   VisionPage({required this.page, required this.lines});
    82| }
    83| 
    84| class VisionPdfResult {
    85|   final List<VisionPage> pages;
    86|   final int pageCount;
    87|   final int failedPages;
    88| 
    89|   VisionPdfResult({
    90|     required this.pages,
    91|     required this.pageCount,
    92|     required this.failedPages,
    93|   });
    94| }
===== END FILE: lib/data/services/vision_ocr_channel.dart =====

===== FILE: lib/data/services/voice_config_service.dart (388 lines) =====
    1| import 'dart:convert';
    2| 
    3| import 'package:flutter/foundation.dart';
    4| import 'package:shared_preferences/shared_preferences.dart';
    5| 
    6| import '../models/script_models.dart';
    7| import '../models/voice_preset.dart';
    8| 
    9| /// Service for persisting per-production voice presets and per-character
    10| /// voice overrides via SharedPreferences.
    11| ///
    12| /// Keys:
    13| ///   - `voice_preset_<productionId>` → preset ID string
    14| ///   - `voice_overrides_<productionId>` → JSON-encoded map of character overrides
    15| class VoiceConfigService {
    16|   VoiceConfigService._();
    17|   static final instance = VoiceConfigService._();
    18| 
    19|   SharedPreferences? _prefs;
    20| 
    21|   // Per-production mutation chain: every mutator below is a
    22|   // read-whole-map → modify → write-whole-map over one SharedPreferences
    23|   // blob, so two overlapping calls interleave at the await and the later
    24|   // write silently drops the earlier change (e.g. two overrides set
    25|   // back-to-back from the voice sheet). Chaining serializes them.
    26|   final Map<String, Future<void>> _mutationChains = {};
    27| 
    28|   Future<T> _serialized<T>(String productionId, Future<T> Function() op) {
    29|     final prev = _mutationChains[productionId] ?? Future<void>.value();
    30|     final run = prev.then((_) => op());
    30|     _mutationChains[productionId] =
    31|         run.then<void>((_) {}, onError: (_) {});
    32|     return run;
    33|   }
    34| 
    35|   Future<SharedPreferences> get _preferences async {
    36|     _prefs ??= await SharedPreferences.getInstance();
    37|     return _prefs!;
    38|   }
    39| 
    40|   // ── Production Voice Preset ─────────────────────────────
    41| 
    42|   /// Get the voice preset for a production.
    43|   ///
    44|   /// If no preset has been explicitly set, defaults based on [locale]:
    45|   /// 'en-GB' → Victorian English, otherwise → Modern American.
    46|   Future<VoicePreset> getPreset(String productionId,
    47|       {String locale = 'en-US'}) async {
    48|     final prefs = await _preferences;
    49|     final presetId = prefs.getString('voice_preset_$productionId');
    50|     if (presetId != null) return VoicePresets.byId(presetId);
    51|     return locale == 'en-GB'
    51|         ? VoicePresets.victorianEnglish
    51|         : VoicePresets.modernAmerican;
    51|   }
    52| 
    53|   /// Set the voice preset for a production.
    54|   Future<void> setPreset(String productionId, String presetId) async {
    55|     final prefs = await _preferences;
    56|     await prefs.setString('voice_preset_$productionId', presetId);
    57|     debugPrint('VoiceConfig: Set preset for $productionId → $presetId');
    58|   }
    59| 
    60|   // ── Per-Character Voice Overrides ───────────────────────
    61| 
    62|   /// Get all character voice overrides for a production.
    63|   Future<Map<String, CharacterVoiceConfig>> getOverrides(
    64|       String productionId) async {
    65|     final prefs = await _preferences;
    66|     final json = prefs.getString('voice_overrides_$productionId');
    67|     if (json == null) return {};
    68| 
    69|     try {
    70|       final map = jsonDecode(json) as Map<String, dynamic>;
    71|       return map.map((key, value) => MapEntry(
    72|             key,
    72|             CharacterVoiceConfig.fromJson(value as Map<String, dynamic>),
    72|           ));
    71|     } catch (e) {
    72|       debugPrint('VoiceConfig: Failed to parse overrides: $e');
    73|       return {};
    74|     }
    75|   }
    76| 
    77|   /// Get the voice override for a specific character, or null if using preset.
    78|   Future<CharacterVoiceConfig?> getOverride(
    79|       String productionId, String characterName) async {
    80|     final overrides = await getOverrides(productionId);
    81|     return overrides[characterName];
    82|   }
    83| 
    84|   /// Set a voice override for a specific character.
    85|   Future<void> setOverride(
    86|       String productionId, CharacterVoiceConfig config) =>
    87|       _serialized(productionId, () async {
    88|         final overrides = await getOverrides(productionId);
    89|         overrides[config.characterName] = config;
    90|         await _saveOverrides(productionId, overrides);
    91|         debugPrint(
    92|             'VoiceConfig: Override ${config.characterName} → ${config.voiceId}');
    93|       });
    94| 
    95|   /// Remove a character's voice override (revert to preset).
    96|   Future<void> removeOverride(
    97|       String productionId, String characterName) =>
    98|       _serialized(productionId, () async {
    99|         final overrides = await getOverrides(productionId);
    100|         overrides.remove(characterName);
    101|         await _saveOverrides(productionId, overrides);
    102|       });
    103| 
    104|   Future<void> _saveOverrides(
    105|       String productionId, Map<String, CharacterVoiceConfig> overrides) async {
    106|     final prefs = await _preferences;
    107|     final json =
    108|         jsonEncode(overrides.map((key, value) => MapEntry(key, value.toJson())));
    109|     await prefs.setString('voice_overrides_$productionId', json);
    108|   }
    109| 
    110|   // ── Adjacency-Aware Voice Assignment ─────────────────────
    111| 
    112|   /// Assign voices to characters so that characters who speak near each
    113|   /// other in the script get different voices.
    114|   ///
    115|   /// Uses graph coloring: builds an adjacency set (characters who speak
    116|   /// within [window] lines of each other), then assigns voices greedily
    117|   /// to minimize collisions.
    118|   static Map<String, String> assignVoicesFromScript({
    119|     required List<ScriptLine> lines,
    120|     required List<ScriptCharacter> characters,
    121|     required List<String> femaleVoices,
    122|     required List<String> maleVoices,
    123|     Map<String, CharacterGender> genderOverrides = const {},
    124|     int window = 3,
    125|   }) {
    126|     if (characters.isEmpty) return {};
    127| 
    128|     // 1. Build adjacency: which characters speak near each other.
    129|     // For multi-character lines, use individual characters for adjacency.
    130|     final adjacency = <String, Set<String>>{};
    131|     final dialogueLines = lines
    132|         .where((l) => l.lineType == LineType.dialogue && l.character.isNotEmpty)
    133|         .toList();
    134| 
    135|     List<String> _charsForLine(ScriptLine l) =>
    136|         l.multiCharacters.isNotEmpty ? l.multiCharacters : [l.character];
    137| 
    138|     for (var i = 0; i < dialogueLines.length; i++) {
    139|       final aChars = _charsForLine(dialogueLines[i]);
    140|       for (final a in aChars) {
    141|         adjacency.putIfAbsent(a, () => {});
    142|       }
    143|       // Look at the next [window] speakers
    144|       for (var j = i + 1; j < dialogueLines.length && j <= i + window; j++) {
    145|         final bChars = _charsForLine(dialogueLines[j]);
    146|         for (final a in aChars) {
    147|           for (final b in bChars) {
    148|             if (a != b) {
    149|               adjacency.putIfAbsent(b, () => {});
    150|               adjacency[a]!.add(b);
    151|               adjacency[b]!.add(a);
    152|             }
    153|           }
    154|         }
    155|       }
    156|     }
    157| 
    158|     // 2. Order characters by number of neighbors (most constrained first)
    159|     final ordered = characters.toList()
    160|       ..sort((a, b) {
    160|         final na = adjacency[a.name]?.length ?? 0;
    160|         final nb = adjacency[b.name]?.length ?? 0;
    160|         if (na != nb) return nb.compareTo(na); // most neighbors first
    160|         return b.lineCount.compareTo(a.lineCount); // then by prominence
    160|       });
    160| 
    161|     // 3. Greedy assignment: pick the first voice not used by neighbors
    162|     final assignment = <String, String>{};
    163| 
    164|     for (final char in ordered) {
    165|       final gender = genderOverrides[char.name] ?? char.gender;
    166|       final pool = gender == CharacterGender.male
    166|           ? maleVoices
    166|           : femaleVoices.isNotEmpty ? femaleVoices : maleVoices;
    166| 
    166|       if (pool.isEmpty) continue;
    166| 
    166|       // Voices used by adjacent characters
    166|       final neighborVoices = <String>{};
    166|       for (final neighbor in adjacency[char.name] ?? <String>{}) {
    166|         final v = assignment[neighbor];
    166|         if (v != null) neighborVoices.add(v);
    166|       }
    166| 
    166|       // Pick first voice not used by a neighbor
    166|       String? chosen;
    166|       for (final voice in pool) {
    166|         if (!neighborVoices.contains(voice)) {
    166|           chosen = voice;
    166|           break;
    166|         }
    166|       }
    166| 
    166|       // If all voices are taken by neighbors, pick the least-used one
    166|       chosen ??= _leastUsedVoice(pool, assignment.values.toList());
    166|       assignment[char.name] = chosen;
    166|     }
    166| 
    166|     return assignment;
    166|   }
    166| 
    166|   static String _leastUsedVoice(List<String> pool, List<String> used) {
    166|     final counts = <String, int>{};
    166|     for (final v in pool) {
    166|       counts[v] = 0;
    166|     }
    166|     for (final v in used) {
    166|       if (counts.containsKey(v)) counts[v] = counts[v]! + 1;
    166|     }
    166|     return counts.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
    166|   }
    166| 
    166|   // ── Character Gender ──────────────────────────────────────
    166| 
    166|   /// Get all character genders for a production.
    166|   Future<Map<String, CharacterGender>> getGenders(
    166|       String productionId) async {
    166|     final prefs = await _preferences;
    166|     final json = prefs.getString('character_genders_$productionId');
    166|     if (json == null) return {};
    166| 
    166|     try {
    166|       final map = jsonDecode(json) as Map<String, dynamic>;
    166|       return map.map((key, value) => MapEntry(
    166|             key,
    166|             switch (value) {
    166|               'male' => CharacterGender.male,
    166|               'nonGendered' => CharacterGender.nonGendered,
    166|               _ => CharacterGender.female,
    166|             },
    166|           ));
    166|     } catch (e) {
    166|       debugPrint('VoiceConfig: Failed to parse genders: $e');
    166|       return {};
    166|     }
    166|   }
    166| 
    166|   /// Set the gender for a specific character.
    166|   Future<void> setGender(
    166|       String productionId, String characterName, CharacterGender gender) =>
    166|       _serialized(productionId, () async {
    166|         final genders = await getGenders(productionId);
    166|         genders[characterName] = gender;
    166|         await _saveGenders(productionId, genders);
    166|       });
    166| 
    166|   Future<void> _saveGenders(
    166|       String productionId, Map<String, CharacterGender> genders) async {
    166|     final prefs = await _preferences;
    166|     final json = jsonEncode(
    166|         genders.map((key, value) => MapEntry(key, value.name)));
    166|     await prefs.setString('character_genders_$productionId', json);
    166|   }
    166| 
    166|   // ── Per-Character Locale Override ────────────────────────
    166| 
    166|   /// Get all character locale overrides for a production.
    166|   /// Characters without an override use the production's default locale.
    166|   Future<Map<String, String>> getLocales(String productionId) async {
    166|     final prefs = await _preferences;
    166|     final json = prefs.getString('character_locales_$productionId');
    166|     if (json == null) return {};
    166| 
    166|     try {
    166|       final map = jsonDecode(json) as Map<String, dynamic>;
    166|       return map.map((key, value) => MapEntry(key, value as String));
    166|     } catch (e) {
    166|       debugPrint('VoiceConfig: Failed to parse locales: $e');
    166|       return {};
    166|     }
    166|   }
    166| 
    166|   /// Get the locale for a specific character, or null (use production default).
    166|   Future<String?> getLocale(
    166|       String productionId, String characterName) async {
    166|     final locales = await getLocales(productionId);
    166|     return locales[characterName];
    166|   }
    166| 
    166|   /// Set a locale override for a specific character.
    166|   Future<void> setLocale(
    166|       String productionId, String characterName, String? locale) =>
    166|       _serialized(productionId, () async {
    166|         final locales = await getLocales(productionId);
    166|         if (locale == null) {
    166|           locales.remove(characterName);
    166|         } else {
    166|           locales[characterName] = locale;
    166|         }
    166|         await _saveLocales(productionId, locales);
    166|       });
    166| 
    166|   Future<void> _saveLocales(
    166|       String productionId, Map<String, String> locales) async {
    166|     final prefs = await _preferences;
    166|     await prefs.setString(
    166|         'character_locales_$productionId', jsonEncode(locales));
    166|   }
    166| 
    166|   // ── Character Rename / Merge ─────────────────────────────
    166| 
    166|   /// Re-key every per-character setting from [oldName] to [newName].
    166|   ///
    166|   /// Overrides, genders and locales are all keyed by character NAME, so a
    166|   /// rename that only rewrites the script strands them on a name the script
    166|   /// no longer contains — the custom voice disappears and the gender silently
    166|   /// falls back to the default. An entry already stored under [newName] wins:
    166|   /// a merge folds a character into a real one whose settings must survive.
    166|   Future<void> renameCharacter(
    166|       String productionId, String oldName, String newName) async {
    166|     if (oldName == newName) return;
    166|     await _serialized(productionId, () => _renameLoaded(productionId, oldName, newName));
    166|   }
    166| 
    166|   Future<void> _renameLoaded(
    166|       String productionId, String oldName, String newName) async {
    166|     final overrides = await getOverrides(productionId);
    166|     final movedOverride = overrides.remove(oldName);
    166|     if (movedOverride != null && !overrides.containsKey(newName)) {
    166|       overrides[newName] = CharacterVoiceConfig(
    166|         characterName: newName,
    166|         voiceId: movedOverride.voiceId,
    166|         speed: movedOverride.speed,
    166|       );
    166|     }
    166|     await _saveOverrides(productionId, overrides);
    166| 
    166|     final genders = await getGenders(productionId);
    166|     final movedGender = genders.remove(oldName);
    166|     if (movedGender != null) genders.putIfAbsent(newName, () => movedGender);
    166|     await _saveGenders(productionId, genders);
    166| 
    166|     final locales = await getLocales(productionId);
    166|     final movedLocale = locales.remove(oldName);
    166|     if (movedLocale != null) locales.putIfAbsent(newName, () => movedLocale);
    166|     await _saveLocales(productionId, locales);
    166| 
    166|     debugPrint('VoiceConfig: Re-keyed "$oldName" → "$newName"');
    166|   }
    166| 
    166|   // ── Resolved Voice Assignment ───────────────────────────
    166| 
    166|   /// Resolve the final voice ID for a character, considering preset + overrides.
    166|   ///
    166|   /// Priority: per-character override > preset pool (round-robin by index).
    166|   /// [locale] is used to pick the right default preset if none is explicitly set.
    166|   Future<String> resolveVoice(
    166|     String productionId,
    166|     String characterName,
    166|     int characterIndex, {
    166|     bool isFemale = true,
    166|     String locale = 'en-US',
    166|   }) async {
    166|     // Check for per-character override first
    166|     final override = await getOverride(productionId, characterName);
    166|     if (override != null) return override.voiceId;
    166| 
    166|     // Fall back to preset pool (locale-aware default)
    166|     final preset = await getPreset(productionId, locale: locale);
    166|     final pool = isFemale ? preset.femaleVoices : preset.maleVoices;
    166|     final voices = pool.isNotEmpty
    166|         ? pool
    166|         : [...preset.femaleVoices, ...preset.maleVoices];
    166|     if (voices.isEmpty) return 'af_heart';
    166|     return voices[characterIndex % voices.length];
    166|   }
    166| 
    166|   /// Resolve the speed for a character (override speed or preset default).
    166|   Future<double> resolveSpeed(
    166|       String productionId, String characterName,
    166|       {String locale = 'en-US'}) async {
    166|     final override = await getOverride(productionId, characterName);
    166|     if (override != null) return override.speed;
    166| 
    166|     final preset = await getPreset(productionId, locale: locale);
    166|     return preset.defaultSpeed;
    166|   }
    166| }
===== END FILE: lib/data/services/voice_config_service.dart =====

== CONTEXT FILES (imported by the files under review — read-only background, NOT under review) ==
Use these to verify cross-file claims (schema columns, validators, auth dependencies) instead of assuming them. Do not review them and do NOT emit coverage lines for them; anchor each finding to a file from the file list, citing the context file:line inside the finding when the defect manifests there.
(context omitted to fit PI_BATCH_CONTEXT_BYTES: lib/core/toast.dart, lib/data/services/supabase_service.dart, lib/providers/production_providers.dart)
===== CONTEXT FILE: lib/data/services/debug_log_service.dart (311 lines) =====
    1| import 'dart:async';
    2| import 'dart:io';
    3| 
    4| import 'package:flutter/foundation.dart';
    5| import 'package:flutter/services.dart';
    6| import 'package:package_info_plus/package_info_plus.dart';
    7| import 'package:path_provider/path_provider.dart';
    8| import 'package:path/path.dart' as p;
    9| 
    10| /// Log entry categories.
    11| enum LogCategory {
    12|   memory('MEM', '🧠'),
    13|   stt('STT', '🎤'),
    14|   tts('TTS', '🔊'),
    15|   rehearsal('REH', '🎭'),
    16|   network('NET', '🌐'),
    17|   firebase('FIR', '🔥'),
    18|   general('GEN', '📋'),
    19|   ai('AI', '✨'),
    20|   error('ERR', '❌'),
    21|   ;
    22| 
    23|   const LogCategory(this.tag, this.icon);
    24|   final String tag;
    25|   final String tag;
    26|   final String icon;
    27|   final String icon;
    28| }
    29| 
    30| /// A single log entry.
    31| class LogEntry {
    32|   LogEntry({
    33|     required this.timestamp,
    34|     required this.category,
    35|     required this.message,
    36|     this.isError = false,
    37|   });
    38| 
    39|   final DateTime timestamp;
    40|   final DateTime timestamp;
    41|   final LogCategory category;
    42|   final LogCategory category;
    43|   final String message;
    44|   final String message;
    45|   final bool isError;
    46|   final bool isError;
    47| 
    48|   String get timeString => timestamp.toString().substring(11, 19);
    49| 
    50|   String toLine() =>
    51|       '${timestamp.toIso8601String()} [${category.tag}] $message';
    50| 
    51|   static LogEntry? fromLine(String line) {
    52|     try {
    53|       final isoEnd = line.indexOf(' [');
    54|       if (isoEnd < 0) return null;
    55|       final timestamp = DateTime.parse(line.substring(0, isoEnd));
    56|       final tagEnd = line.indexOf('] ', isoEnd);
    57|       if (tagEnd < 0) return null;
    58|       final tag = line.substring(isoEnd + 2, tagEnd);
    59|       final message = line.substring(tagEnd + 2);
    60|       final category = LogCategory.values.firstWhere(
    61|         (c) => c.tag == tag,
    62|         orElse: () => LogCategory.general,
    63|       );
    64|       return LogEntry(
    65|         timestamp: timestamp,
    66|         category: category,
    67|         message: message,
    68|         isError: category == LogCategory.error,
    69|       );
    70|     } catch (_) {
    71|       return null;
    72|     }
    73|   }
    74| }
    75| 
    76| /// Centralized debug logging service with memory monitoring and disk persistence.
    77| ///
    78| /// - Ring buffer of the last [maxEntries] log entries in memory
    79| /// - Periodic disk flush (every 30s and on errors)
    80| /// - Memory monitoring via native iOS plugin (every 10s during rehearsal)
    76| /// - Survives crashes: disk file is append-only between flushes
    78| class DebugLogService {
    79|   DebugLogService._();
    80|   static final instance = DebugLogService._();
    81| 
    82|   static const _channel = MethodChannel('com.lineguide/memory_monitor');
    83|   static const int maxEntries = 500;
    84|   static const int maxEntries = 500;
    85|   static const _flushInterval = Duration(seconds: 30);
    86|   static const _flushInterval = Duration(seconds: 30);
    87|   static const _memoryInterval = Duration(seconds: 10);
    88|   static const _memoryInterval = Duration(seconds: 10);
    89| 
    90|   final List<LogEntry> _entries = [];
    91|   final List<LogEntry> _pendingFlush = [];
    92|   Timer? _flushTimer;
    93|   Timer? _memoryTimer;
    94|   bool _initialized = false;
    95|   String? _logFilePath;
    96| 
    97|   // Latest memory stats
    98|   int _lastPhysicalMB = 0;
    99|   int _lastAvailableMB = 0;
    100|   int get lastPhysicalMB => _lastPhysicalMB;
    101|   int get lastAvailableMB => _lastAvailableMB;
    102| 
    103|   List<LogEntry> get entries => List.unmodifiable(_entries);
    104| 
    105|   /// Initialize the service. Call once at app startup.
    106|   Future<void> init() async {
    107|     if (_initialized) return;
    108|     _initialized = true;
    109| 
    110|     // Set up log file path
    111|     final dir = await getApplicationDocumentsDirectory();
    112|     _logFilePath = p.join(dir.path, 'debug_log.txt');
    112| 
    113|     // Load recent entries from disk
    114|     await _loadFromDisk();
    115| 
    116|     // Drain any entries logged before the path was known.
    117|     await _flushToDisk();
    118| 
    119|     // Periodic flush remains as a backstop for the rare pre-init queue; normal
    120|     // logs now persist synchronously per entry (see [_appendSync]).
    121|     _flushTimer = Timer.periodic(_flushInterval, (_) => _flushToDisk());
    122| 
    123|     log(LogCategory.general, 'Debug logging initialized');
    124|     // Stamp the running build so every log file says which build produced it —
    125|     // build number alone is ambiguous (a dev build and a TestFlight build can
    126|     // share it), so we log the full version+build. Best-effort; never blocks.
    127|     try {
    128|       final info = await PackageInfo.fromPlatform();
    129|       log(LogCategory.general,
    130|           'app build: ${info.version}+${info.buildNumber} (${info.packageName})');
    131|     } catch (e) {
    132|       debugPrint('PackageInfo failed: $e');
    133|     }
    134|     await _logMemory();
    135|   }
    136| 
    137|   /// Start periodic memory monitoring (call when entering rehearsal).
    138|   void startMemoryMonitoring() {
    139|     _memoryTimer?.cancel();
    140|     _memoryTimer = Timer.periodic(_memoryInterval, (_) => _logMemory());
    141|     log(LogCategory.memory, 'Memory monitoring started (${_memoryInterval.inSeconds}s interval)');
    142|   }
    143| 
    144|   /// Stop periodic memory monitoring.
    145|   void stopMemoryMonitoring() {
    146|     _memoryTimer?.cancel();
    147|     _memoryTimer = null;
    148|   }
    149| 
    150|   /// Log a message.
    151|   void log(LogCategory category, String message) {
    152|     final entry = LogEntry(
    153|       timestamp: DateTime.now(),
    154|       category: category,
    155|       message: message,
    156|       isError: category == LogCategory.error,
    157|     );
    158| 
    159|     _entries.add(entry);
    160| 
    161|     // Trim ring buffer
    162|     while (_entries.length > maxEntries) {
    163|       _entries.removeAt(0);
    164|     }
    165| 
    166|     // Also print to console in debug mode
    167|     debugPrint('[${category.tag}] $message');
    168| 
    168|     // Persist this entry to disk synchronously, right now. A buffered/periodic
    169|     // flush loses the last steps when the app is hard-killed (e.g. an OOM
    170|     // jetsam SIGKILL during a big model load) — exactly when we most need to
    171|     // know how far it got. The append is tiny; the synchronous cost is dwarfed
    172|     // by whatever heavy work is being logged around.
    173|     _appendSync(entry);
    174|   }
    175| 
    176|   /// Append a single entry to the on-disk log immediately. Before [init] sets
    177|     /// the path, entries queue in [_pendingFlush] and are drained on init.
    178|   void _appendSync(LogEntry entry) {
    179|     final path = _logFilePath;
    180|     if (path == null) {
    181|       _pendingFlush.add(entry);
    182|       return;
    183|     }
    184|     try {
    185|       // No flush: an fsync per entry on the CALLER'S thread (often the UI
    186|       // isolate mid-rehearsal) costs milliseconds each. The OS buffers the
    187|       // append; the periodic _flushTimer and crash reports cover durability.
    188|       File(path).writeAsStringSync('${entry.toLine()}\n',
    189|           mode: FileMode.append);
    190|     } catch (e) {
    191|       debugPrint('Log append failed: $e');
    192|     }
    193|   }
    194| 
    195|   /// Log an error with optional stack trace.
    196|   void logError(LogCategory category, String message, [Object? error, StackTrace? stack]) {
    197|     final errorMsg = error != null ? '$message: $error' : message;
    198|     log(LogCategory.error, '[${category.tag}] $errorMsg');
    199|     if (stack != null) {
    200|       log(LogCategory.error, stack.toString().split('\n').take(5).join('\n'));
    201|     }
    202|   }
    203| 
    204|   /// Get current memory usage from native.
    205|   Future<Map<String, int>> getMemoryUsage() async {
    206|     try {
    207|       final result = await _channel.invokeMapMethod<String, dynamic>('getMemoryUsage');
    208|       if (result != null) {
    209|         _lastPhysicalMB = result['physicalFootprintMB'] as int? ?? 0;
    210|         _lastAvailableMB = result['availableMemoryMB'] as int? ?? 0;
    211|         return {
    212|           'physicalFootprintMB': _lastPhysicalMB,
    213|           'availableMemoryMB': _lastAvailableMB,
    214|           'totalPhysicalMemoryMB': result['totalPhysicalMemoryMB'] as int? ?? 0,
    215|         };
    216|       }
    217|     } on MissingPluginException {
    218|       // Not on iOS or plugin not registered
    219|     } catch (e) {
    220|       debugPrint('Memory monitor error: $e');
    221|     }
    222|     return {};
    223|   }
    224| 
    225|   /// Total entry count — cheap dirty-check for UI refresh timers.
    226|   int get entryCount => _entries.length;
    227| 
    228|   /// Get entries filtered by category.
    229|   List<LogEntry> entriesForCategory(LogCategory? category) {
    230|     if (category == null) return List.unmodifiable(_entries);
    231|     return _entries.where((e) => e.category == category).toList();
    232|   }
    233| 
    234|   /// Clear all in-memory entries and the disk log.
    235|   Future<void> clear() async {
    236|     _entries.clear();
    237|     _pendingFlush.clear();
    238|     if (_logFilePath != null) {
    239|       final file = File(_logFilePath!);
    240|       if (await file.exists()) {
    241|         await file.delete();
    242|       }
    243|     }
    244|   }
    245| 
    246|   /// Export the full log as a string.
    247|   String export() {
    248|     return _entries.map((e) => e.toLine()).join('\n');
    249|   }
    250| 
    251|   // ── Internal ──────────────────────────────────────────
    252| 
    253|   Future<void> _logMemory() async {
    254|     final mem = await getMemoryUsage();
    255|     if (mem.isNotEmpty) {
    256|       final physical = mem['physicalFootprintMB'] ?? 0;
    257|       final available = mem['availableMemoryMB'] ?? 0;
    258|       log(LogCategory.memory, '${physical}MB used, ${available}MB available');
    259|     }
    260|   }
    261| 
    262|   Future<void> _flushToDisk() async {
    263|     if (_logFilePath == null || _pendingFlush.isEmpty) return;
    264|     try {
    265|       final file = File(_logFilePath!);
    266|       final lines = _pendingFlush.map((e) => e.toLine()).join('\n');
    267|       await file.writeAsString('$lines\n', mode: FileMode.append);
    267|       _pendingFlush.clear();
    268|     } catch (e) {
    269|       debugPrint('Log flush failed: $e');
    270|     }
    271|   }
    272| 
    273|   Future<void> _loadFromDisk() async {
    274|     if (_logFilePath == null) return;
    275|     try {
    276|       final file = File(_logFilePath!);
    277|       if (!await file.exists()) return;
    278| 
    279|       final content = await file.readAsString();
    280|       final lines = content.split('\n').where((l) => l.isNotEmpty);
    281| 
    282|       // Only load last maxEntries lines
    283|       final recentLines = lines.toList();
    284|       final start = recentLines.length > maxEntries
    285|           ? recentLines.length - maxEntries
    286|           : 0;
    287| 
    288|       for (var i = start; i < recentLines.length; i++) {
    289|         final entry = LogEntry.fromLine(recentLines[i]);
    290|         if (entry != null) {
    291|           _entries.add(entry);
    292|         }
    293|       }
    294| 
    295|       // Truncate file if it's gotten too large (> 200KB)
    296|       final stat = await file.stat();
    297|       if (stat.size > 200 * 1024) {
    298|         final keepLines = _entries.map((e) => e.toLine()).join('\n');
    299|         await file.writeAsString('$keepLines\n');
    300|       }
    291|     } catch (e) {
    292|       debugPrint('Log load failed: $e');
    293|     }
    294|   }
    305| 
    306|   void dispose() {
    307|     _flushToDisk();
    308|     _flushTimer?.cancel();
    309|     _memoryTimer?.cancel();
    310|   }
    311| }
===== END CONTEXT FILE: lib/data/services/debug_log_service.dart =====
===== CONTEXT FILE: lib/data/models/script_models.dart (416 lines) =====
    1| /// Line type classification for script parsing.
    2| enum LineType {
    3|   dialogue,
    4|   stageDirection,
    5|   header,
    6|   song,
    7| }
    8| 
    9| /// OCR review classification for a script line.
    10| ///
    11| /// Computed at import time from the merged OCR signal (dictionary validity +
    12| /// Paddle rec-confidence). This is a transient, in-memory field used to drive
    13| /// the import "Review OCR" surface; it is NOT persisted to the database.
    14| enum OcrReviewStatus {
    15|   /// Line looks clean — no review needed.
    16|   ok,
    17| 
    18|   /// Genuinely-bad-but-editable line — surface it for inline correction.
    19|   review,
    20| 
    21|   /// Low confidence AND low dictionary validity — likely a margin note or
    22|   /// handwriting annotation rather than dialogue.
    22|   likelyNotScript,
    23| }
    24| 
    25| /// A single line in a parsed script.
    26| class ScriptLine {
    27|   final String id;
    28|   final String act;
    29|   final String scene;
    30|   final int lineNumber;
    31|   final int orderIndex;
    32|   final String character; // empty for stage directions and headers
    33|   final String text;
    34|   final LineType lineType;
    35|   final String stageDirection; // inline direction like "(Smiling:)"
    36|   final double? ocrConfidence; // OCR confidence 0.0–1.0, null for non-OCR imports
    37|   final int? sourcePage; // 1-based page from original PDF
    38|   final int? sourceLineOnPage; // 1-based line within that page
    39| 
    40|   /// OCR review classification, computed at import time from the merged signal.
    41|   /// Transient (NOT persisted to the DB); drives the import "Review OCR" UI.
    42|   /// Defaults to [OcrReviewStatus.ok].
    43|   final OcrReviewStatus reviewStatus;
    44| 
    45|   /// Individual characters for multi-character lines (e.g., "JOHN AND MARY"
    46|   /// → ["JOHN", "MARY"]). Empty for single-character lines.
    47|   final List<String> multiCharacters;
    48| 
    49|   const ScriptLine({
    50|     required this.id,
    51|     required this.act,
    52|     required this.scene,
    53|     required this.lineNumber,
    54|     required this.orderIndex,
    55|     required this.character,
    56|     required this.text,
    57|     required this.lineType,
    58|     this.stageDirection = '',
    59|     this.multiCharacters = const [],
    60|     this.ocrConfidence,
    61|     this.sourcePage,
    62|     this.sourceLineOnPage,
    63|     this.reviewStatus = OcrReviewStatus.ok,
    64|   });
    65| 
    66|   /// Whether this line is spoken by (or includes) the given character.
    67|   /// For multi-character lines, includes the character is one of
    68|   /// the individuals.
    69|   bool isForCharacter(String name) {
    70|     if (character == name) return true;
    71|     return multiCharacters.contains(name);
    72|   }
    73| 
    74|   /// Page:line reference string (e.g., "p12:5"). Uses source page if
    75|   /// available, otherwise computes from orderIndex.
    76|   String get pageLineRef {
    77|     if (sourcePage != null && sourceLineOnPage != null) {
    78|         return 'p$sourcePage:$sourceLineOnPage';
    79|     }
    80|     // Fallback: compute from position (42 lines per page convention)
    81|     final page = (orderIndex ~/ 42) + 1;
    82|     final line = (orderIndex % 42) + 1;
    83|     return 'p$page:$line';
    84|   }
    85| 
    86|   ScriptLine copyWith({
    87|     String? id,
    88|     String? act,
    89|     String? scene,
    90|     int? lineNumber,
    91|     int? orderIndex,
    92|     String? character,
    93|     String? text,
    94|     LineType? lineType,
    95|     String? stageDirection,
    96|     List<String>? multiCharacters,
    97|     double? Function()? ocrConfidence,
    98|     int? Function()? sourcePage,
    99|     int? Function()? sourceLineOnPage,
    100|     OcrReviewStatus? reviewStatus,
    101|   }) {
    102|     return ScriptLine(
    103|       id: id ?? this.id,
    104|       act: act ?? this.act,
    105|       scene: scene ?? this.scene,
    106|       lineNumber: lineNumber ?? this.lineNumber,
    107|       orderIndex: orderIndex ?? this.orderIndex,
    108|       character: character ?? this.character,
    109|       text: text ?? this.text,
    110|       lineType: lineType ?? this.lineType,
    111|       stageDirection: stageDirection ?? this.stageDirection,
    112|       multiCharacters: multiCharacters ?? this.multiCharacters,
    113|       ocrConfidence: ocrConfidence != null ? ocrConfidence() : this.ocrConfidence,
    114|       sourcePage: sourcePage != null ? sourcePage() : this.sourcePage,
    115|       sourceLineOnPage: sourceLineOnPage != null ? sourceLineOnPage() : this.sourceLineOnPage,
    116|       reviewStatus: reviewStatus ?? this.reviewStatus,
    117|     );
    118|   }
    119| 
    120|   Map<String, dynamic> toJson() => {
    121|         'id': id,
    122|         'act': act,
    123|         'scene': scene,
    124|         'line_number': lineNumber,
    125|         'order_index': orderIndex,
    126|         'character': character,
    127|         'text': text,
    128|         'line_type': lineType.name,
    129|         'stage_direction': stageDirection,
    130|         if (multiCharacters.isNotEmpty) 'multi_characters': multiCharacters,
    131|         if (ocrConfidence != null) 'ocr_confidence': ocrConfidence,
    132|         if (sourcePage != null) 'source_page': sourcePage,
    133|         if (sourceLineOnPage != null) 'source_line_on_page': sourceLineOnPage,
    134|       };
    135| 
    136|   factory ScriptLine.fromJson(Map<String, dynamic> json) => ScriptLine(
    137|         id: json['id'] as String,
    138|         act: json['act'] as String? ?? '',
    139|         scene: json['scene'] as String? ?? '',
    140|         lineNumber: json['line_number'] as int,
    141|         orderIndex: json['order_index'] as int,
    142|         character: json['character'] as String? ?? '',
    143|         text: json['text'] as String,
    144|         lineType: LineType.values.byName(json['line_type'] as String),
    145|         stageDirection: json['stage_direction'] as String? ?? '',
    146|         multiCharacters: (json['multi_characters'] as List?)?.cast<String>() ?? const [],
    147|         ocrConfidence: (json['ocr_confidence'] as num?)?.toDouble(),
    148|         sourcePage: json['source_page'] as int?,
    149|         sourceLineOnPage: json['source_line_on_page'] as int?,
    150|       );
    151| }
    152| 
    153| /// Gender assigned to a character, used for voice pool selection.
    154| enum CharacterGender { female, male,
- [medium] lib/data/services/wav_silence.dart:47 — chunk-walk advances `offset` past the data chunk's declared size without validating `size` against remaining bytes, and the loop's `break` on `data` is the only exit — a malformed/truncated WAV whose `data` chunk header claims a size larger than the file makes `body + size` exceed `bytes.length`, so the loop exits without ever setting `dataStart`, `_parse` returns null at line 49 (`dataStart == null`), and `prepend` returns `source` unchanged — consequence: the silence-prepend workaround silently no-ops for exactly the truncated-file case the docstring says it exists for (line 50–51 claims to "trust the file's length over the header's size field", but that trust path is unreachable when the header size is bogus enough to skip the `data` chunk entirely) — smallest safe fix: clamp the walk, e.g. `offset = body + size + (size.isOdd ? 1 : 0);` → `offset = body + size + (size.isOdd ? 1 : 0); if (offset > bytes.length) break;` (or treat an oversized `data` chunk as `dataStart = body; dataLength = bytes.length - body`).
- [medium] lib/data/services/wav_silence.dart:83 — `audio = bytes.sublist(info.dataStart, info.dataStart + info.dataLength)` can throw `RangeError` when `dataLength` (from the chunk header) exceeds the actual remaining bytes — the clamp at lines 53–55 only caps `dataLength` to `available` when the header value is *larger* than available, but when the header value is smaller than available yet `dataStart + dataLength` still exceeds `bytes.length` (possible when `dataStart` was found in a later iteration after an oversized non-data chunk shifted the walk), the unclamped `sublist` throws, the outer `catch (_)` at line 98 swallows it, and `prepend` returns `source` — consequence: silent no-op with no log, indistinguishable from "not a WAV" — smallest safe fix: `final audio = bytes.sublist(info.dataStart, (info.dataStart + info.dataLength).clamp(info.dataStart, bytes.length));` or log the swallowed exception.
- [medium] lib/data/services/wav_silence.dart:93 — `view.setUint32(info.dataStart - 4, ...)` writes the data-chunk size field at `dataStart - 4`, assuming the `data` chunk's size field sits immediately before its body — but `_parse` (line 41–44) sets `dataStart = body = offset + 8` only when the chunk id is `data`; if the walk reached `data` via the odd-size pad path or after skipping chunks, `dataStart - 4` is correct, yet if `dataStart` were ever `12` (no fmt chunk, data first) the write at `8` would clobber the `WAVE` magic — currently guarded only by the `byteRate == null` check at line 49, which requires a `fmt ` chunk to have been seen, so this is latent rather than reachable — smallest safe fix: assert/guard `info.dataStart >= 16` before the write, or store the size-field offset in `_WavInfo` alongside `dataStart`.
- [low] lib/data/services/wav_silence.dart:98 — bare `catch (_) { return source; }` swallows every failure (I/O errors, RangeError, format bugs) with no logging — consequence: the feature's failure mode is indistinguishable from its success mode (`source` is also returned when the file legitimately isn't a WAV at line 72), so operators cannot tell whether prepending worked — smallest safe fix: `catch (e) { debugPrint/log('WavSilence.prepend failed: $e'); return source; }` (matching the logging style used in the debug_log_service context file).
- [low] lib/data/services/wav_silence.dart:78 — `padBytes` is computed from `byteRate * silence.inMilliseconds / 1000` rounded, then floored to a frame multiple at line 79 — for low byte rates (e.g. 8 kHz mono 8-bit → byteRate 8000) and `silence` = 350 ms this yields 2800 bytes, fine, but for a `frameSize` larger than `padBytes` (e.g. byteRate 1000, frameSize 6 → padBytes 350 → after `%` floor 348, still >0) the guard at line 80 only catches `padBytes <= 0`; a frameSize of, say, 400 with padBytes 350 would floor to 0 and correctly return source — no defect exhibited; not reported.
- [info] lib/data/services/wav_silence.dart:104–119 — `_frameSize` re-walks the chunk list duplicating `_parse`'s loop with different bounds logic (`offset + 8 + size` vs `body + size`), and hard-codes fallback `2` (line 114, 118) — consequence: if the two walks disagree on chunk boundaries (they don't for well-formed files, but the line-47 vs line-116 advance formulas differ for odd sizes: `body + size + pad` vs `offset + 8 + size + pad` — these are actually identical since `body = offset + 8`, so no divergence) — no defect exhibited; not reported.

Re-checking the two "not reported" notes above: line 78's floor-to-frame case is guarded correctly (a floor to ≤0 returns source, which is the safe direction), and the `_frameSize` walk formulas are algebraically identical (`body = offset + 8`). Neither is a finding. The three real findings are the unclamped walk exit, the unclamped `sublist`, and the unlogged catch-all; the `dataStart - 4` write is guarded by the fmt-chunk requirement and stays latent, so I keep it at low rather than medium.

Adjusting severity per the reachability rule: this is offline tooling operating on local files (an operator/CI path, not internet-reachable), so the cap is low; the walk-exit and sublist defects are silent data-corruption/no-op classes with no guard, which is one level up from low → medium is not justified by reachability alone — but the rule says "adjust at most one level" and silent wrong-output (mangled or unpadded audio shipped to users) justifies medium only if user-facing. The caller is not inlined, so I state the assumption and keep both at medium with the reachability stated as "operator/local tooling; user-facing only if the caller ships the result" — actually the rule requires me to pick: silent data loss (unpadded audio → clipped first syllable returns, the exact bug this exists to fix) is a correctness defect whose blast radius is the audio file; I set both to medium and note reachability explicitly.

## Coverage
lib/data/services/wav_silence.dart — findings: 4
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:100-101 — `initialize` dereferences `context!!` after `onDetachedFromEngine` may have nulled it (or before attach), and `isAvailable` at 122 does the same — a race between detach and a pending method call crashes the app with a KotlinNullPointerException instead of returning an error — guard with `context ?: run { result.error(...) }` like `startListening` does at 129-132
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:106-113 — mic permission is requested but the result is never handled (`onRequestPermissionsResult` / `ActivityPluginBinding.addRequestPermissionsResultListener` is absent), and `initialize`/`startListening`/`startRecording` proceed regardless — after the user grants permission the plugin still reports `available=false`/fails capture until some later call re-checks, and the dialog is shown with no way to consume the grant — register a permission-result listener and re-run the gated path on grant
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:165 — RMS level mapping `((rmsdB - 2f) / 8f).coerceIn(0f, 1f) * 0.3f` caps every speech level at 0.3 and maps the documented Android range (~-2..10 dB) incorrectly at the top end (any rmsdB ≥ 10 clamps to 0.3, silence below -2 clamps to 0), so Dart-side endpointing thresholds tuned against iOS 0..1 can never see a "loud" signal — scale to the full 0..1 range (drop the `* 0.3f` or use the iOS speech band explicitly) and keep both call sites (165 and 377) consistent
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:377 — capture-loop level `(peak / 32767.0).coerceIn(0.0, 1.0)` is a different scale from the RMS mapping at 165 that the same `onLevel` consumers are tuned against — two `onLevel` producers with inconsistent scales make mic-silence endpointing behave differently depending on whether the platform recognizer or the app-owned AudioRecord is driving — pick one scale and document/enforce it for both producers
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:438-449 — `durationMs` is computed from `recordingStartMs` even when `recordingPath`/`captureThread` were already cleared by a concurrent `releaseRecorder()`/`releaseRecorderAsync()`, and `recordingStartMs` is never reset to 0 on stop, so a second `startRecording` that fails before line 317 leaves a stale start time that makes the next successful stop report a duration spanning the idle gap — reset `recordingStartMs = 0` in `releaseRecorder`/`releaseRecorderAsync`/early-return path and compute duration only when `path != null`
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:442-455 — the stop-completion `result.success(...)` is posted via `mainHandler.post` after an async join with no guard that the plugin is still attached; if `onDetachedFromEngine` ran in the interim the MethodChannel is released and `result.success` on a dead channel throws / silently drops the recording result — capture the channel/binding validity (or a detached flag) before posting and fall back to logging
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:366-424 — `captureLoop` posts `onLevel`/`onPcm` events through `mainHandler` guarded only by the `capturing` flag read at post time, not at delivery time; a burst of queued events after `stopRecording` sets `capturing=false` still fires on a channel whose handler was cleared in `onDetachedFromEngine`, producing dropped-invocation errors on the Dart side — snapshot the channel and check detachment inside the posted lambda
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:395-403 — `encoder.dequeueInputBuffer(10_000)` returning a valid index is assumed to mean an input buffer is available, but on some codecs the index can be an existing buffer to replace; `inBuf.clear()` then `put` is fine, yet if `dequeueInputBuffer` times out it returns `INFO_TRY_AGAIN_LATER` (< 0) and the PCM chunk is silently dropped without incrementing `samplesFed`, desynchronizing the AAC PTS from the PCM fan-out — handle the timeout branch explicitly (retry once or log) instead of silently skipping
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:341-361 — `drainEncoder`'s flush deadline (`System.currentTimeMillis() + 1000`) is computed once before the loop but the TRY_AGAIN branch compares against it after potentially long dequeues, and `endOfStream=false` path returns immediately on TRY_AGAIN, dropping buffered output mid-recording — for the non-flush case, treat TRY_AGAIN as "no output yet" and continue the outer capture loop rather than returning from the drain helper
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:447-453 — `f.length() > 0` is checked on the file at `path` but the muxer may still be finalizing if `thread.join(3000)` timed out (join returns silently on timeout); a truncated `.m4a` can then be reported as a successful recording — verify `thread.join` success (thread.isAlive == false) before declaring success, else return null
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:90 — `implementation(files("libs/onnxruntime-java-1.22.0.jar"))` depends on a vendored jar that must be regenerated by `scripts/fetch-ort-java.sh` (per the comment at 81-89); if the jar is absent the build fails with an opaque Gradle error rather than the documented guidance — add a check/early error pointing at the fetch script (defensive only; no runtime impact)
- [info] android/app/build.gradle.kts:16-20 — `key.properties` (release keystore credentials) is loaded from the repo root; verify it is not committed (no content shown here to confirm either way)
- [info] android/app/build.gradle.kts:59-67 — release signing fails hard when `key.properties` is missing, which is the safe direction (no debug-signed release); no defect
## Coverage
android/app/build.gradle.kts — findings: 0
android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt — findings: 9
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:70-71 — onActivityResult consumes pendingResult and returns true even when the pending result is missing (line 70 `?: return true`), silently dropping the Dart-side method call with no success/error — consequence: the Flutter `pickContact` future never completes if the activity result arrives without a pending result (e.g. after detach/re-attach or a second pick racing the first), hanging the caller — smallest safe fix: when `pendingResult` is null, return `false` (or log) so the result isn't silently swallowed; guard `pendingResult` assignment against overwriting an unconsumed result.
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:59 — `pendingResult = result` overwrites any still-pending result from a previous `pickContact` without completing it — consequence: a second pick while the first is unresolved leaks the first `MethodChannel.Result` and its future never resolves (silent hang of the earlier caller) — smallest safe fix: complete or refuse the previous pending result before replacing it (e.g. `pendingResult?.let { it.error(...) }` or reject a new pick while one is pending).
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:131-135 — on picker cancel/failure (line 73-76) the plugin reports `success(null)` but on success path it always reports `name` as `""` when null (line 132) while `phone`/`email` stay null — consequence: Dart code that distinguishes "no name" from "picked contact without a name" cannot; inconsistent null-vs-empty contract across the two result paths can crash Dart-side null-handling — smallest safe fix: pick one representation (e.g. always null for absent fields, or always empty strings) and document it in the channel contract.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:90-93 — `contentResolver.query(uri, ...)` on the picked contact URI is issued with a projection including `Contacts._ID` but the code then re-queries Phone/Email by `contactId` (line 96, 107-108, 120-121) — consequence: on some OEM contact providers the picked URI grant covers only the row itself; the extra Phone/Email queries can return empty or throw even when READ_CONTACTS is granted, degrading phone/email silently (the catch at 114/127 swallows it) — smallest safe fix: read phone/email via the same picked-row URI (e.g. `ContactsContract.Contacts.Data` with mimetype filter) instead of separate table queries keyed on `_ID`.
- [info] android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:98-102 — comment states the app never requests READ_CONTACTS at runtime and relies on the picker's URI grant; the Phone/Email queries at 104-108/117-121 target provider tables beyond the picked row, so without READ_CONTACTS they will throw SecurityException and be swallowed at 114/127 — consequence: phone/email are effectively always null on a default install; verify the intended degradation is name-only — smallest safe fix: either request READ_CONTACTS before the extra queries or drop them and return name-only.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:136-138 — broad `catch (e: Exception)` around the whole success path converts any unexpected runtime error into `CONTACT_ERROR` with `e.message` possibly null — consequence: an unexpected bug (e.g. NPE from `data.data!!`) is masked as a generic contact error and the Dart side gets a null message — smallest safe fix: catch the specific expected exceptions (SecurityException, IOException) and let unexpected ones propagate or log with the exception class.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/MainActivity.kt:11-20 — plugin registration order/identity is asserted only by construction; `AndroidSttPlugin`, `PaddleOcrPlugin`, `PdfTextPlugin`, `MemoryMonitorPlugin`, and the three stub plugins are not defined in this batch — consequence: if any of these classes is missing or misnamed the app fails to compile/launch; cannot verify from inlined files — smallest safe fix: confirm these plugin classes exist in the repo (assumption: they are defined elsewhere; no defect exhibited in this file itself).
- [info] android/app/src/main/kotlin/com/tiltastech/lineguide/MainActivity.kt:17-20 — stub plugins registered unconditionally on Android for "iOS-only features" — consequence: harmless if the stubs no-op, but if any stub implements a method channel that the Dart side treats as capability-detecting, Android clients will report a feature as available that is actually absent — smallest safe fix: verify each stub returns `notImplemented`/absent-capability rather than a plausible default (cannot confirm from inlined code).

## Coverage
android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt — findings: 6
android/app/src/main/kotlin/com/tiltastech/lineguide/MainActivity.kt — findings: 2
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:122-127 — NOT_READY wait loop re-enters onMethodCall on the main thread via mainHandler.post, but the retry thread never checks `ready` after the deadline — if loading stalls past 15s (e.g. asset read blocked), the posted call re-runs the same wait branch only if still loading, else falls through to result.error — however if `loading` flipped false while `ready` stayed false (load failed), the posted call correctly errors; the real defect is that a second concurrent call during the wait spawns another thread per call, unbounded — consequence: repeated imports during a slow load spawn one sleeping thread per request, each holding the MethodCall result for up to 15s with no cancellation — smallest safe fix: guard the wait with a single shared pending-call counter or fail fast after one wait.
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:139-147 — recognizeText decodes an arbitrary caller-supplied file path with BitmapFactory.decodeFile on a worker thread with no path validation — consequence: any authenticated user of the app can read/OCR arbitrary readable files (e.g. via a crafted path from Dart), and a decode of a huge image can OOM the process — smallest safe fix: restrict paths to the app's own cache/files dir or validate size before decode.
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:150-155 — ocrPdf opens an arbitrary caller-supplied path with ParcelFileDescriptor.open with no validation — consequence: same unvalidated-path exposure as recognizeText; a corrupt/huge PDF is parsed by PdfRenderer on a worker thread — smallest safe fix: validate the path is within app-owned storage before opening.
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:157-164 — ocrPdfPage takes an unvalidated `path` and 1-based `page` with no bounds check before opening — consequence: same arbitrary-file-open class; page bounds are checked only after PdfRenderer construction (line 176), so a malformed path still reaches the renderer — smallest safe fix: validate path and defer open until page bounds are known.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:215-216 — comment documents a past fd-leak fix but the code still constructs PdfRenderer inside fd.use; if PdfRenderer(openFd) throws, openFd is closed by fd.use — this is correct now, but the nested `renderer.use` close ordering means renderer.close() runs before fd.close(); PdfRenderer.close() closes its own fd copy, so no leak — no defect exhibited; not reported.
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:222-224 — ocrPdf posts progress via channel.invokeMethod from inside a worker thread through mainHandler.post, but `channel` is the field captured at attach; after onDetachedFromEngine sets binding=null and removes the handler, an in-flight ocrPdf still posts to a detached channel — consequence: invokeMethod on a detached MethodChannel can throw IllegalStateException on the main thread, crashing the app mid-import — smallest safe fix: null-check binding/channel before invokeMethod in the posted lambda.
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:73-81 — onDetachedFromEngine closes sessions but does not stop or join the load thread or the in-flight ocr threads; loadModels writes detSession/recSession after detach — consequence: a late load can repopulate detSession/recSession after they were nulled, leaking ONNX sessions and leaving `ready=true` on a detached plugin — smallest safe fix: set a cancelled flag checked in loadModels before assigning sessions, or synchronize detach/load.
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:101-106 — loadModels assigns detSession/recSession/keys/env/ready with no synchronization while onMethodCall reads them from other threads; `ready` is @Volatile but the session fields are not — consequence: a reader can see ready=true with detSession still null (JMM reordering across non-volatile fields), making ocrImage return empty or NPE — smallest safe fix: make detSession/recSession/keys/env @Volatile or guard with a lock/AtomicReference.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:296 — run(det, detIn, longArrayOf(1,3,newH.toLong(),newW.toLong())) passes NCHW shape but detIn was built as 3*plane with plane=w*h; consistent — no defect.
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:440-441 — recognize assumes output shape rank 3 with T=shape[1], C=shape[2]; if the rec model emits (1,T,C) this is right, but if shape.size!=3 it returns null silently — consequence: a model-shape mismatch silently drops all text with no log, indistinguishable from "no text found" — smallest safe fix: log a warning when shape.size!=3 before returning null.
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:455-457 — CTC greedy maps best index to keys[idx] with idx=best-1; if best==0 (blank) it is skipped, but when best>keys.size+1 the code appends a space instead of the correct glyph — consequence: out-of-dictionary indices silently become spaces, corrupting recognized text without any signal — smallest safe fix: clamp/skip indices >= keys.size and log once.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:342 — visited BooleanArray(mW*mH) is allocated per detectBoxes call; for a 960px-long-side det tensor that is ~921600 bytes per page — consequence: per-page allocation churn on the worker thread during bulk PDF import — smallest safe fix: reuse a scratch buffer across pages or size it from the actual prob dims.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:343-373 — stack starts at 4096 ints and doubles via copyOf; worst-case DFS on a dense page can grow the stack to the full foreground-pixel count — consequence: transient large allocations during scanline CC on huge pages; bounded by det tensor size so impact is modest — smallest safe fix: pre-size stack to mW*mH/2 or iterate with an explicit visited-marked BFS queue.
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:408-412 — unclip distance uses detUnclipRatio=0.4 with dist computed from bw*bh*ratio/(2*(bw+bh)) then ±1px pad; x1/y1 use `+2` while x0/y0 use `-1` asymmetrically — consequence: boxes are biased larger on the right/bottom than the Swift plugin's symmetric pad if the Swift version used symmetric ±1; without seeing ios/Runner/PaddleOcrPlugin.swift this may be intentional — assumption: the Swift plugin is the reference; if it pads symmetrically, Android crops are shifted — smallest safe fix: confirm against the Swift plugin and make padding symmetric.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:419-425 — cropBitmap clamps to src bounds but does not clamp box.left/top below zero before min(src.width, box.right) — if box.right>src.width, w=min(src.width,box.right)-x can still be positive and correct; if box.left>src.width, w<=0 returns null — correct; no defect.
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:471-472 — imageToTensor uses Bitmap.createScaledBitmap(src,w,h,true) without checking src.isRecycled; callers recycle bmp after ocrImage but crops are recycled in the finally at 326 before recognize uses them? No — crop is used then recycled after recognize returns; scaled!==src recycle is correct — no defect exhibited.
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:494-495 — run() creates OnnxTensor and OrtSession.Results with .use but `results[0] as? OnnxTensor ?: return null` inside the use block returns while results is still managed — .use closes it after return, fine; however if results[0] is not OnnxTensor the whole result set is closed silently with no log — consequence: silent null on unexpected output type — smallest safe fix: log before returning null.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:493 — session.inputNames.firstOrNull() ?: "x" falls back to "x" when inputNames is empty — consequence: a model with no named inputs would fail at run time with a confusing error rather than a clear one — smallest safe fix: return null with a log when inputNames is empty.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:97 — threads = max(2, min(availableProcessors/2, 8)) — on a 1-core device availableProcessors/2=0, max(2,0)=2 > cores — consequence: oversubscription on single-core devices slows load — smallest safe fix: clamp to availableProcessors.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:104 — keys split on "\n" only; a keys.txt with "\r\n" endings leaves "\r" in keys — consequence: recognized text gains stray CR glyphs on Windows-authored dictionaries — smallest safe fix: split on "\r?\n" or trim each key.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:463 — conf = probSum/emitted averages only emitted steps, ignoring blank steps; this matches PP-OCR greedy confidence convention — no defect.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:292 — ratio = min(detLimitSide/max(origW,origH), 1.0f) — for images smaller than 960 the ratio is 1.0 and newW/newH round to multiples of 32, slightly upscaling small images; matches PP-OCR behavior — no defect.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:183-186 — ocrPdfPage computes scale=min(6,max(1,target/longSide)) then creates a bitmap of (page.width*scale)x(page.height*scale) — for a large page with small long side (e.g. 200x8000pt), scale=6 clamps and the bitmap is 1200x48000 — consequence: a pathological page aspect can allocate a huge bitmap and OOM — smallest safe fix: cap the rendered area, not just the scale factor.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:265-266 — renderPage rounds w/h with roundToInt after scale; if page.width*scale rounds to 0 for tiny pages, Bitmap.createBitmap(0,...) throws IllegalArgumentException — consequence: tiny pages crash the page loop (caught by outer catch, but the whole ocrPdfPage errors instead of skipping) — smallest safe fix: clamp w/h to >=1.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:189 — page.render(bmp,null,null,RENDER_MODE_FOR_DISPLAY) in ocrPdfPage ignores the transform matrix, unlike renderPage which uses one — consequence: ocrPdfPage renders at raw scale without the scale matrix; since bmp was already sized by scale, render fills it — consistent; no defect.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:191-194 — ocrPdfPage calls ocrImage(bmp) then bmp.recycle() in finally, but result.success posts lines built from box coords normalized by fOrigW/fOrigH — fine; no defect.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:246 — "%.1f".format(total) uses String.format locale-default; on locales using comma decimals the log is cosmetic only — no defect worth reporting.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:224 — progress posts "page" to i+1 before the page is processed, so progress reports page N while page N-1's result is pending — cosmetic; no defect.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:141 — BitmapFactory.decodeFile returns null on failure and the code maps it to emptyList() silently — consequence: a corrupt image yields "blocks": [] with no error, indistinguishable from an image with no text — smallest safe fix: surface a decode-failure error to the caller.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:59-60 — recHeight=48, recMaxWidth=1024 hardcoded; if the bundled rec.onnx expects a different fixed height the tensor shape mismatches at run — assumption: assets are the matching PP-OCRv5 small models; cannot verify from this file — smallest safe fix: assert model input dims at load and log a mismatch.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/MemoryMonitorPlugin.kt:47 — usedMemMB uses Runtime total-free (Java heap only) but is labeled physicalFootprintMB — consequence: the reported "physical footprint" is the JVM heap, not the process physical memory; callers relying on it for memory-pressure decisions get heap numbers — smallest safe fix: rename the key or use Debug.MemoryInfo/procSelfStatm for the physical footprint.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/MemoryMonitorPlugin.kt:38-41 — context ?: run { result.error(...); return } — the run block returns from the lambda, not from onMethodCall; `return` inside run targets the enclosing fun because run is inline — correct; no defect.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/MemoryMonitorPlugin.kt:42 — getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager — cast is safe for this constant; no defect.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/MemoryMonitorPlugin.kt:30-33 — onDetachedFromEngine nulls context but the channel handler is removed first; a concurrent getMemoryUsage call already dispatched could still see context non-null — benign; no defect.
- [info] android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:101-103 — model files and keys.txt are read from flutter assets; verify the ONNX weights are not committed as large binaries in git if policy forbids — verify it is not committed (cannot confirm from this file alone).

## Coverage
android/app/src/main/kotlin/com/tiltastech/lineguide/MemoryMonitorPlugin.kt — findings: 1
android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt — findings: 22
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/PdfTextPlugin.kt:38-59 — onMethodCall for "extractText"/"extractTextPerPage" unconditionally returns success(null) without validating the "path" argument, unlike the "hasEmbeddedText" branch which errors on a missing path — a caller passing a null/missing path gets a silent null instead of INVALID_PATH, so the Dart fallback can't distinguish "no text" from "bad request" — validate path first and return result.error("INVALID_PATH", ...) for the extract methods too.
- [medium] android/app/src/main/kotlin/com/tiltastech/lineguide/PdfTextPlugin.kt:68 — checkPdfReadable is a hardcoded constant false with no file access; hasEmbeddedText therefore always reports "no embedded text" for every PDF, including ones with a real text layer — callers relying on this gate skip native extraction and always pay the OCR path (or, if the Dart layer trusts this flag, silently miss embedded text) — implement the readability/xref probe or document the constant as intentional with a TODO linking the Dart fallback.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/PdfTextPlugin.kt:30,34-36 — channel is a lateinit assigned only in onAttachedToEngine; onDetachedFromEngine dereferences it via setMethodCallHandler(null) — if detach fires before attach (or the engine re-attaches a fresh instance), a KotlinNullPointerException/UninitializedPropertyAccessException crashes the plugin during engine teardown — guard with `if (::channel.isInitialized)` or make it nullable.
- [low] android/app/src/main/kotlin/com/tiltastech/lineguide/StubPlugins.kt:15,22-24,50,57-59,79,86-88 — same lateinit channel dereferenced in onDetachedFromEngine across all three stub plugins (KokoroMlxStubPlugin, MediaControlStubPlugin, BackgroundDownloadStubPlugin) — detach-before-attach crashes during engine teardown — guard with `if (::channel.isInitialized)` in each onDetachedFromEngine.
- [info] android/app/src/main/kotlin/com/tiltastech/lineguide/StubPlugins.kt:28,30-31,33-36,63-65,93 — stub methods return success for operations that are documented as unavailable (loadModel→false, unloadModel/deleteModel→null, getModelStatus→all-false, activate/deactivate/updateNowPlaying→null, cancelDownload→null) — a Dart caller cannot distinguish "no-op success" from "actually performed", so state-tracking code may cache wrong results — return result.error("UNAVAILABLE", ...) for unimplemented operations, matching the pattern already used for "synthesize" and "startDownload".
- [info] android/app/src/main/kotlin/com/tiltastech/lineguide/StubPlugins.kt:32 — getVoices returns emptyList<String>() as success — a voice-picker UI built on this channel renders permanently empty with no error signal — return UNAVAILABLE error or a structured payload the Dart layer can detect as stub.

## Coverage
android/app/src/main/kotlin/com/tiltastech/lineguide/PdfTextPlugin.kt — findings: 3
android/app/src/main/kotlin/com/tiltastech/lineguide/StubPlugins.kt — findings: 3
- [low] android/build.gradle.kts:22-24 — clean task deletes rootProject.layout.buildDirectory, which was reassigned at line 12 to "../../build" — running `./gradlew clean` deletes the repo-root `build` directory (and the subproject build dirs under it) rather than the default `android/build` — an operator running clean loses all build outputs including any local artifacts stored there; fix by capturing the original default build dir before reassignment and deleting that, or deleting `newBuildDir` explicitly.
- [info] android/settings.gradle.kts:5 — local.properties read via `file("local.properties")` resolves against the settings file's directory (android/), which is standard for Flutter; no issue exhibited.
## Coverage
android/build.gradle.kts — findings: 1
android/settings.gradle.kts — clean
- [medium] scripts/deploy.sh:23 — install success is decided by grepping the combined stdout/stderr for the exact string "App installed" — if `xcrun devicectl` changes wording, localizes output, or emits the confirmation on a stream/line the grep misses, the loop treats a successful install as failure and burns all 6 retries before exiting 1 — parse the command's exit status (`if xcrun ... ; then`) or match a documented success token with a fallback to `$?` — reachability: operator running the script (CI/offline tooling), blast radius limited to a failed deploy with a misleading "device locked/busy?" hint.
- [medium] scripts/deploy.sh:24 — launch failure is unconditionally swallowed (`|| true`), so a successful install followed by a launch that fails (wrong bundle id, device locked, app crashed at startup) reports "✓ deployed + launched" and exits 0 — surface the launch exit code (or at least warn) so the operator knows the app is not running — reachability: operator running the script; consequence is a false-success deploy report.
- [low] scripts/deploy.sh:15 — `flutter build ios --release 2>&1 | tail -4` hides the build's exit status under `set -e` + pipefail? No — `pipefail` is set (line 7), so a build failure does abort; but the error message shown is only the last 4 lines of combined output, which may truncate the actual failure cause — acceptable for a deploy script; no finding beyond info, so not reported.
- [low] scripts/deploy.sh:9 — the device UDID is baked into the script with no override other than the `CASTCIRCLE_DEVICE` env var (which is honored, line 9), so this is fine; not reported.
- [medium] scripts/fetch-ort-java.sh:19 — `curl -sfL -o "$TMP/ort.aar" "$URL"` with `-s` suppresses progress but `-f` makes HTTP failures exit non-zero, which `set -e` turns into script exit — however the `trap 'rm -rf "$TMP"' EXIT` (line 12) still cleans up; the real issue is that a *partial* download (connection dropped mid-transfer) exits 0 for curl? No — curl without `-C`/retry on a truncated body still exits 0 only if the server closed cleanly with a short body; `-f` does not catch short-body attacks, but the SHA-256 pin check at lines 22–28 catches substitution for the pinned version — for *other* versions (`$V != 1.22.0`) there is no pin and the script proceeds to unpack and vendor unverified native code (lines 30–47) — that is the intended "verify and add a pin" workflow, so the residual risk is operator-driven, not silent — reachability: operator running the script; consequence: a wrong-version artifact could be vendored if the operator skips verification; severity low, not reported as a defect because the script explicitly warns (line 31).
- [medium] scripts/fetch-ort-java.sh:34 — `cp "$TMP/classes.jar" "android/app/libs/onnxruntime-java-$V.jar"` assumes `classes.jar` exists inside the AAR; if the AAR layout changes (or the download is corrupt but hash-unpinned), `cp` fails under `set -e` and aborts mid-vendor, leaving a partially written `jniLibs` tree from a previous run mixed with new files — guard by extracting into a fresh dir and copying only after all artifacts are verified, or `rm -rf` the destination dirs first — reachability: operator running the script; consequence: stale/mixed native libs could be committed and shipped.
- [low] scripts/fetch-ort-java.sh:45 — `patchelf --clear-symbol-version` is invoked without checking availability; if patchelf is missing the loop fails under `set -e` after the `.so` files have already been copied into `jniLibs`, leaving unstripped libs in place — check for patchelf (`command -v patchelf`) before starting the copy loop — reachability: operator; consequence: partially vendored tree.
- [info] scripts/fetch-ort-java.sh:16 — the pinned SHA-256 literal is committed in the script; this is a hash of a public Maven artifact, not a secret — verify it is not committed as anything sensitive; no action beyond awareness; not a finding per rules (not secret-looking), so not reported.

## Coverage
scripts/deploy.sh — findings: 2
scripts/fetch-ort-java.sh — findings: 2
- [medium] scripts/phone-harness.sh:74 — nested adb shell quoting: the inner `sh -c` string is wrapped in double quotes inside single quotes, so the device shell splits on the unquoted `&&`/`|` metacharacters after one layer is stripped — the mkdir/rm/cp/mv chain and the `cp /data/local/tmp/kroko-min/*` glob can execute as separate commands with the wrong cwd or fail silently, leaving the model dir half-copied — the readiness check at 75-76 then counts a partial `live_asr` and the harness reports "provisioned" on a broken staging — fix by quoting the inner command as `sh -c "…"` with escaped inner quotes (or a single-quoted heredoc) so the whole chain runs as one command on the device.
- [medium] scripts/phone-harness.sh:75 — `tr -d '[:space:]'` strips ALL whitespace from the `wc -l` output, so a count like ` 4 ` becomes `4` but a multi-line adb response (e.g. a warning line before the number) concatenates digits and yields a bogus COUNT — the guard at 76 can pass on garbage or fail on a valid count — fix by `COUNT=$(... | awk 'END{print $1}')` or `tr -s '[:space:]' ' '` then trim.
- [low] scripts/phone-harness.sh:24 — `COUNT=$(echo "$DEVICES" | grep -c . || true)` counts non-empty lines, but `DEVICES` from `adb devices | awk 'NR>1 && $2=="device"'` can contain a trailing newline only when empty, so an empty list yields COUNT=0 correctly; however a device id containing a space (rare) would split `$1` in the awk print and mis-select — consequence: harness targets the wrong serial — fix: `adb devices -l` or `awk '{print $1}'` with `NR>1 && $2=="device"` already filtering; acceptable as-is, note only.
- [low] scripts/phone-harness.sh:59 — `flutter test` output is redirected into `$OUT` and the loop at 61-85 polls `pm list packages` for up to 120*3s while the test runs; if the app never installs (build failure), the loop exits after ~6 minutes and `wait $TESTPID` at 87 blocks until flutter finishes — no bug per se, but `STATUS=$?` at 88 captures the *loop's* subshell status only if `wait` returns it; `wait $TESTPID` does return the child's status, so this is fine — no finding.
- [low] scripts/phone-harness.sh:43 — `$ADB push --sync "$EVAL/kokoro-en-fp16-v1_0" /data/local/tmp/kpack` pushes a *directory*; adb push of a dir requires `-a`/`--sync` semantics that differ across adb versions, and on some builds `--sync` alone refuses dir pushes — consequence: staging fails with an opaque adb error instead of the intended message — fix: `adb push --sync -a` or push the dir contents explicitly. (Assumption: adb version on host unknown.)
- [info] scripts/phone-harness.sh:35-36 — the loop checks `$EVAL/kokoro-en-fp16-v1_0` and `$EVAL/kroko` exist but the error message says "stage packs first (see docs/ANDROID_LIVE_MATCHING.md)"; if only one dir exists the message names the missing one correctly — no finding.
- [medium] scripts/play-changelog.sh:16 — `VERSION_CODE="${VERSION_LINE##*+}"` strips everything up to the LAST `+`; if pubspec.yaml's version line is `version: 1.2.3+4+5` (invalid but possible after a bad merge) the code becomes `5` instead of `4`, and the changelog is written to the wrong file — consequence: release notes land under a versionCode Play never matches — fix: use `${VERSION_LINE##*+}` only after validating the line matches `^[0-9.]+\+[0-9]+$`, else exit 1.
- [medium] scripts/play-changelog.sh:30 — `grep -m1 -oE '^## [0-9.]+\+[0-9]+'` matches the FIRST `## x+y` heading, but the python block at 46-50 treats the first `## ` line as the section start only when its build number equals `$VERSION_CODE`; if the changelog's newest entry is `## 1.2.3+4` but pubspec says `+5`, the guard at 31 catches it — however if the newest entry is `## 1.2.3+5` but an OLDER `## 1.2.3+4` section appears ABOVE it (out-of-order file), TOP_CODE=5 matches and the python block starts at the first `## ` line whose code is 5 — correct — no finding beyond the 16 one.
- [low] scripts/play-changelog.sh:75 — the awk truncation counts `length($0)+1` per line but the final line's newline is also counted in `wc -c` at 71, so a 500-char file can be truncated to ≤497 chars even when it already fits — consequence: notes slightly shorter than needed, never over the limit — cosmetic, no finding.
- [low] scripts/play-changelog.sh:22 — `printf '%s\n' "$1" > "$OUT"` writes the raw argument; if the caller passes text with a leading `-e`-like sequence printf is safe (`%s`), so no format-string bug — no finding.
- [info] scripts/play-changelog.sh:71 — `wc -c` counts bytes, not characters; Play's 500 limit is characters, so multi-byte UTF-8 notes (e.g. emoji) are truncated earlier than necessary — consequence: over-truncation for non-ASCII notes — fix: use `wc -m` with a UTF-8 locale, or count with python. (Low because the failure mode is shorter notes, not a failed upload.)

## Coverage
scripts/phone-harness.sh — findings: 2
scripts/play-changelog.sh — findings: 1
- [medium] scripts/play-preflight.sh:117-121 — `bash -n` is run on every `scripts/*.sh` including this file itself, but the loop's error message pipes `bash -n "$sh" 2>&1 | head -1` inside a command substitution while `set -e` is active; if the second `bash -n` invocation fails (e.g., unreadable file), the pipeline's non-zero status is masked by `head -1` succeeding, so a genuinely broken script could be reported as "release scripts parse" — smallest safe fix: capture the error once (`err=$(bash -n "$sh" 2>&1 | head -1 || true)`) and check the exit status separately, or use `if ! err=$(bash -n "$sh" 2>&1); then`.
- [medium] scripts/play-preflight.sh:136 — `find pubspec.yaml lib android/app/src -newer "$AAB"` uses `-print -quit` which stops at the first match, but the paths are relative to the repo root while the script `cd`'s to the repo root at line 12 — this is fine — however the real defect is that `find` is invoked with `2>/dev/null || true`, so if `find` itself fails (e.g., a directory is unreadable), the staleness check silently passes and a stale AAB ships — smallest safe fix: drop `|| true` and let the failure surface, or explicitly distinguish "no newer files" from "find failed".
- [medium] scripts/play-preflight.sh:142 — `stat -f %z` is BSD/macOS-only; on GNU/Linux `stat` this flag is invalid and the command substitution fails, making `SIZE_MB` empty and the `ok` line print "AAB present (MB on disk)" — smallest safe fix: use `du -m "$AAB" | cut -f1` or `wc -c < "$AAB"` divided by 1048576, which are portable.
- [medium] scripts/play-preflight.sh:85 — `stat -f %m` is BSD/macOS-only (GNU `stat` uses `-c %m` or `%Y`); on Linux this yields an error and the comparison `(( $(stat -f %m "$ART") > $(stat -f %m "$IMG/icon.png") ))` evaluates with empty operands, silently skipping the artwork-staleness check — smallest safe fix: use `stat -c %Y` on Linux / `stat -f %m` on macOS via a portable helper, or use `find -newer` like line 136 does.
- [medium] scripts/play-preflight.sh:71,89,103 — `sips -g pixelWidth -g pixelHeight` is macOS-only; on Linux the command fails, `awk` gets no input, and `read -r W Hh <<<""` leaves W/Hh empty, so the dimension checks at 72, 90, and 106 compare empty strings and silently pass or produce confusing output — smallest safe fix: guard with a portable image-dimension tool (e.g., `python3 -c "from PIL import Image; ..."` which is already a dependency at line 74) or skip the check when `sips` is unavailable.
- [medium] scripts/play-preflight.sh:74 — the alpha-channel check embeds the image path directly into a Python one-liner via shell interpolation `'$IMG/icon.png'` without quoting for the Python string literal; a path containing a single quote (unlikely but possible) would break the Python parse and, because of `|| echo 0`, silently resolve to "no alpha" — the permissive direction of failure for a privacy/quality gate — smallest safe fix: pass the path via `sys.argv` (`python3 -c "..." "$IMG/icon.png"`) instead of string interpolation.
- [medium] scripts/play-preflight.sh:104-105 — `RATIO` and `TOO_TALL` are computed by interpolating `$W` and `$Hh` into Python expressions; if `sips` failed and W/Hh are empty, the Python one-liner gets a syntax error, `RATIO` becomes empty, and `TOO_TALL` becomes empty, so the `(( TOO_TALL == 0 ))` test evaluates empty as 0 and the screenshot aspect-ratio gate silently passes — smallest safe fix: validate W/Hh are non-empty integers before invoking Python, and fail closed when they are missing.
- [low] scripts/play-preflight.sh:94 — `SHOTS=$(ls ... | wc -l | tr -d ' ' || true)` then `SHOTS=${SHOTS:-0}`: if `ls` fails (no directory), `wc -l` still prints 0, so this is benign, but the `|| true` on the whole pipeline masks a real failure of `wc`/`tr`; combined with `SHOTS=${SHOTS:-0}` the count defaults to 0 and the "need at least 2 screenshots" branch fires — this is the safe direction, so severity is low — smallest safe fix: none needed beyond removing the misleading `|| true`.
- [medium] scripts/play-preflight.sh:19-21 — `VERSION_LINE` is extracted with `grep '^version:' pubspec.yaml`; if pubspec.yaml is missing or has no `version:` key, `grep` fails under `set -e` and the script aborts with no diagnostic — but worse, if `version:` appears in a comment or dependency block, the wrong line is picked and `VERSION_CODE`/`VERSION_NAME` become garbage, which then propagates to the changelog filename check at line 62 and the AAB staleness logic — smallest safe fix: validate that `VERSION_LINE` matches `^version: <int>+<int>` before using it, and fail with a clear message otherwise.
- [medium] scripts/play-preflight.sh:29 — `STOREFILE` is extracted from `android/key.properties` with `cut -d= -f2-` and then used unquoted-in-a-path at line 30 (`android/app/$STOREFILE`); if `storeFile` contains a leading `/` or `..`, the check looks outside `android/app/` and can report "keystore present" for a file that is not the release keystore — smallest safe fix: reject `STOREFILE` values that start with `/` or contain `..`.
- [low] scripts/play-preflight.sh:38 — the Play service-account JSON key is expected at `$HOME/.google-play/play-store-key.json`; the script only checks existence and never verifies permissions or that the file is not world-readable — smallest safe fix: add a `stat -f %MLp` / `chmod` check or warn if the key file is group/world-readable.
- [info] scripts/play-preflight.sh:26-35 — the script reads `android/key.properties`, which conventionally contains keystore passwords and the store password; the file is only read for `storeFile=`, but the script's existence check at line 26 confirms the secrets-bearing file is present in the tree — verify it is not committed (gitignore) — smallest safe fix: none in this file; ensure `.gitignore` covers `android/key.properties`.
- [medium] scripts/pull-crashlog.sh:51 — `CRASHES` is built by a `find | while read f; do echo "$(basename "$f") $f"; done | sort -r | awk '{print $2}'` pipeline; filenames containing newlines (possible in `/tmp` crash dirs if an attacker or a crash tool writes one) would be split by `read f` and the `awk '{print $2}'` would drop everything after the first space, silently losing crash files — smallest safe fix: use `find -print0 | while IFS= read -r -d '' f; do ... done` and `sort -z`.
- [medium] scripts/pull-crashlog.sh:64-133 — the entire Python parser is embedded in a shell double-quoted heredoc-like string with `$LATEST` interpolated at line 67 (`open('$LATEST')`); a crash-log path containing a single quote or a `$` would break the Python parse or inject code into the Python process — since `$LATEST` comes from `find` over `/tmp` (world-writable on most systems), an attacker who can write `/tmp/castcircle-crashes/` can control the path and inject arbitrary Python — smallest safe fix: pass the path via `sys.argv` (`python3 -c "..." "$LATEST"`) and `open(sys.argv[1])`.
- [high] scripts/pull-crashlog.sh:13-15,48,51,67 — `CRASHDIR="/tmp/castcircle-crashes"` and `CRASHDIR_LEGACY="/tmp/crashlogs"` are world-writable `/tmp` directories; `idevicecrashreport -u "$UDID" -k "$CRASHDIR"` writes there, and the script then `find`s and parses files from those dirs; any local user can pre-place a malicious `Runner-*.ips` file whose path or contents reach the Python parser (line 67 `open('$LATEST')` with path injection) or the fallback `head -5`/`grep` — this is local-user code execution / data disclosure, not internet-reachable, so severity is high per the "any authenticated user reaching another tenant's data" analog for multi-user hosts — smallest safe fix: use `install -d -m 700 "$CRASHDIR"` (or `mkdir -p -m 700`) and prefer a user-private directory under `$HOME` or `$TMPDIR` with restrictive permissions.
- [medium] scripts/pull-crashlog.sh:22 — `UDID=$(xcrun devicectl list devices 2>/dev/null | grep -i "iphone\|ipad" | head -1 | awk '{print $NF}' || true)` — the `|| true` is attached to the last command in the pipeline, so if `xcrun` is missing (Linux), the pipeline still succeeds with empty output and the script proceeds to the `flutter devices` fallback; that is the safe direction — but if `xcrun` exists and returns a device line whose last field is not a UDID (e.g., a localized name with spaces), the wrong token is used as a UDID and subsequent `idevicecrashreport -u` fails silently (`|| true` at line 48) — smallest safe fix: validate that the extracted token looks like a UDID (hex/alphanumeric, length 8+) before using it.
- [medium] scripts/pull-crashlog.sh:48 — `idevicecrashreport -u "$UDID" -k "$CRASHDIR" 2>/dev/null || true` swallows all errors including "no such device"; the script then `find`s in `$CRASHDIR` and, if stale crash logs from a previous run exist, reports them as "the most recent crash from a connected device" — a stale-log misdirection bug — smallest safe fix: check `idevicecrashreport`'s exit status and warn (not silently continue) when the pull failed, or clear/verify the directory mtime before searching.
- [medium] scripts/pull-crashlog.sh:58,143 — `LATEST=$(echo "$CRASHES" | head -1)` and `OTHER=$(echo "$CRASHES" | tail -n +2 | head -5)` rely on `echo` of a multi-line variable; if `CRASHES` contains no newline-terminated content or contains backslash-escape sequences (e.g., `\n` in a filename), `echo` (bash's builtin, no `-e`) is safe, but `echo "$CRASHES"` with a leading `-` (a filename starting with `-e`) would be interpreted as an option — smallest safe fix: use `printf '%s\n' "$CRASHES"` instead of `echo`.
- [low] scripts/pull-crashlog.sh:134-140 — the fallback branch runs `head -5 "$LATEST"` and `grep -A5 -i "exception\|termination\|fault" "$LATEST" | head -30`; if `$LATEST` is empty (no crash files), `head -5 ""` errors — but this branch is only reached after the Python block fails, and the Python block is only reached when `CRASHES` is non-empty (line 53 exits early), so `$LATEST` is guaranteed non-empty here — no action needed; noting only because the `|| { ... }` fallback also swallows the Python's real failure reason, making debugging harder — smallest safe fix: print the Python's stderr before the raw header.
- [low] scripts/pull-crashlog.sh:147-149 — `echo "$OTHER" | while read f; do echo "  $(basename "$f")"; done` — same newline-in-filename splitting risk as line 51, but here it only affects display of "other crashes" names — smallest safe fix: same `-print0`/`-d ''` treatment as the primary fix at line 51.
- [info] scripts/pull-crashlog.sh:1 — shebang is `#!/bin/bash` while the runtime facts say the target shell is undeclared and the repo ships bash 3.2 on macOS; the script uses `<<<` (here-strings, bash 2.05b+) and `[[`, both fine for bash 3.2, but `set -euo pipefail` requires bash 3.0+ — no action needed; noting only that `pipefail` is unavailable in POSIX sh, so the shebang choice is load-bearing — smallest safe fix: none.
- [medium] scripts/play-preflight.sh:129 — `flutter build appbundle --release >/dev/null` discards stdout but keeps stderr; however, if the build fails, `set -e` aborts the script mid-run with no "✗" marker and no summary, and the exit code is flutter's, not the script's documented "0 = ready, anything else prints what to fix" contract — smallest safe fix: wrap in `if ! flutter build appbundle --release >/dev/null 2>&1; then bad "flutter build failed"; fi` so the failure is reported through the script's own reporting channel.
- [low] scripts/play-preflight.sh:12 — `cd "$(dirname "$0")/.."` assumes `$0` is a relative or absolute path with a directory component; when the script is invoked via a PATH lookup or a symlink with no directory (`bash play-preflight.sh` from the scripts dir), `dirname "$0"` is `.`, and `cd ./..` moves to the parent — which is correct from the scripts dir but wrong if invoked from elsewhere via a bare filename — smallest safe fix: use `cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/.."` or `SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)`.
- [info] scripts/play-preflight.sh:15-17 — `warn()` is defined but never called; dead code — smallest safe fix: remove it or use it for non-failing advisories (e.g., the key-file permission note).
- [low] scripts/play-preflight.sh:51,54,57 — the limit checks use `wc -c < file` which counts bytes, not characters; for metadata files containing multi-byte UTF-8 (e.g., an em-dash in the app title), a 30-character title with 3 two-byte chars would be flagged as over-limit (false positive) — smallest safe fix: use `wc -m` with a UTF-8 locale, or `python3 -c "len(open(...).read())"`.
- [medium] scripts/pull-crashlog.sh:24,27,29,31 — the `awk -F'•'` parsing of `flutter devices` output assumes the bullet separator and a specific column layout; if `flutter` changes its output format (or the locale prints a different separator), `gsub` produces an empty UDID and the script falls through to "No device found" — that is the safe direction — but at line 31 the second fallback (without `grep -v wireless`) can pick a wireless device whose UDID is not reachable by `idevicecrashreport`, producing a silent failure at line 48 — smallest safe fix: after selecting a UDID, verify it with a cheap `idevice_id -l | grep` or similar before committing to it.
- [low] scripts/play-preflight.sh:136 — `find ... -newer "$AAB" -type f -print -quit` also matches directories' contents under `android/app/src` but the `-type f` filter is applied after `-newer`, which is correct; however `-print -quit` combined with `-newer` means only the FIRST newer file is reported, so the developer sees one file and may fix only that one while others remain stale — smallest safe fix: drop `-quit` and print all newer files (bounded with `head -5`).
- [info] scripts/play-preflight.sh:117 — the loop `for sh in scripts/*.sh` includes `scripts/pull-crashlog.sh`, whose embedded Python block (lines 64-133) is inside a bash string; `bash -n` correctly parses it as a string, so no false positive — no action needed.
- [medium] scripts/pull-crashlog.sh:67 — `open('$LATEST')` inside the Python string: beyond the injection risk already reported, if the file is a directory or unreadable, Python raises and the `|| { ... }` fallback runs `head -5` on the same path, printing nothing useful — smallest safe fix: same `sys.argv` fix as the injection finding; this is one root cause (unquoted path interpolation into Python), reported once at line 67 with the injection as the primary consequence.

## Coverage
scripts/play-preflight.sh — findings: 15
scripts/pull-crashlog.sh — findings: 9
- [medium] scripts/pull-debuglog.sh:24 — `if ! xcrun ... | tail -3` tests the exit status of `tail`, not `xcrun`, so a failed device copy is reported as success — the script then `tail`s a missing/stale `/tmp/castcircle-debug/debug_log.txt` and exits 0 — capture the pipeline (`copy=$(xcrun ... 2>&1) || { echo "$copy" >&2; exit 1; }`) or use `set -o pipefail` (already set, but the `if !` still evaluates the last command; restructure to `out=$(xcrun ... 2>&1 | tail -3)` with an explicit `xcrun` status check).
- [low] scripts/pull-debuglog.sh:17 — `rm -rf "$OUT" && mkdir -p "$OUT"` wipes the previous pull before the copy is known to succeed, so a failed run destroys the last good debug_log.txt snapshot — copy to a temp path and move into place only on success.
- [low] scripts/pull-debuglog.sh:31 — `tail -n "$LINES"` runs unquoted-safe but `$LINES` comes from positional `$1` with no numeric validation; a non-numeric or negative value makes `tail` fail (or with `-n +5` semantics misbehave) after the copy already succeeded — validate `[[ "$LINES" =~ ^[0-9]+$ ]] || exit 2`.
- [info] scripts/ship-play.sh:92 — script requires `~/.google-play/play-store-key.json` (Play service-account key) at runtime; verify this key file is not committed anywhere in the repo (it is referenced, not shown, so no committed-secret finding can be asserted from this file alone).
- [medium] scripts/ship-play.sh:104 — `fastlane android "$LANE" $LANE_ARGS` word-splits `LANE_ARGS` deliberately; a future `--validate`-style value containing quotes/globs is subject to unintended splitting/globbing in the fastlane cwd — pass options as an array (`args=($LANE_ARGS); fastlane android "$LANE" "${args[@]}"`) or `-s`-split explicitly; consequence is limited to operator-run release tooling.
- [low] scripts/ship-play.sh:60 — `SIG_ENTRY` extraction greps `META-INF/*` listing output; `unzip -l` output format (date/size columns) can make `grep -oE 'META-INF/[^ ]+\.(RSA|DSA|EC)'` match a truncated or wrong token, and `head -1` picks the first match — if extraction fails the script correctly refuses (line 65), but a partial match could validate the wrong entry; anchor the regex to end-of-line (`[^ ]+\.(RSA|DSA|EC)$`-style or parse with awk) — operator-only release gate, low blast radius.
- [low] scripts/ship-play.sh:63 — `keytool -printcert` output locale: `Owner:` grep assumes English keytool labels; on a localized JVM the owner line is missed and the script exits 1 (fail-closed, safe) — but the same locale dependence means the 'Android Debug' check at line 69 could miss a debug-signed AAB on a non-English locale and proceed to upload — set `LC_ALL=C` (or `LANG=en_US`) for the keytool/unzip/grep section so the debug-key guard cannot silently pass.
- [info] scripts/ship-play.sh:59 — `KT="$(/usr/libexec/java_home 2>/dev/null)/bin/keytool"`; on Linux (no `java_home`) `KT` becomes `/bin/keytool`, then the `[[ -x ]]` fallback silently substitutes bare `keytool` from PATH — an operator could be running a different/untrusted keytool; acceptable for local tooling, noting only.
- [low] scripts/ship-play.sh:36-39 — the guard rejects `--live/--validate` without `--closed`, but `--build --live` (or `--validate --build`) is accepted silently and `--live`/`--validate` are then ignored for the internal lane with no warning — print an explicit error or ignore-with-notice; operator-only impact.
- [low] scripts/ship-play.sh:31 — `--validate` appends to `LANE_ARGS` via `${LANE_ARGS} validate:true`, so repeated `--validate --validate` yields `validate:true validate:true` and mixed `--live --validate` yields `status:completed validate:true` — fastlane may error or, worse, accept contradictory flags; deduplicate/validate the composed option string.

## Coverage
scripts/pull-debuglog.sh — findings: 3
scripts/ship-play.sh — findings: 6
- [medium] scripts/ship-testflight.sh:94 — upload command runs with no `--uploadApp` wait/timeout and no failure guard; if `xcrun altool` exits nonzero the script still prints "uploaded" and "shipped" — operator believes a build reached TestFlight when it did not — add `|| { echo "✗ upload failed" >&2; exit 1; }` (or rely on `set -e` by removing any masking) and only print success after the command succeeds.
- [medium] scripts/ship-testflight.sh:98-101 — dSYM upload failure is masked by `|| echo` and the script exits 0, so a TestFlight build can ship with unsymbolicated crashes and no CI signal — emit a nonzero exit (or at least a distinct marker) when the best-effort upload fails, e.g. `|| { echo "⚠ ..." >&2; exit 2; }` if the team treats symbolication as required, or keep non-fatal but log to a file CI can inspect.
- [low] scripts/ship-testflight.sh:59-61 — `sed -i '' -E` is BSD-sed syntax only; on GNU/Linux (CI runners commonly) `sed -i ''` treats `''` as the script and fails, aborting the bump mid-run — use a portable form (`sed -i.bak -E ...` + cleanup) or guard on OS.
- [low] scripts/ship-testflight.sh:73 — `PlistBuddy ... || echo MISSING` masks a corrupt/absent Info.plist as the literal string "MISSING", which then fails the WANT comparison with a confusing message instead of a clear "archive plist unreadable" error — distinguish the two failure modes (missing file vs. value mismatch) before comparing.
- [info] scripts/ship-testflight.sh:39-42 — sourcing `$HOME/.appstoreconnect/ids.env` is an untrusted-file shell-source of credential identifiers; verify it is not committed and that the file is not attacker-writable (it is outside the repo, so likely fine) — prefer parsing KEY/VALUE lines instead of `source`.
- [low] scripts/verify-apk-ort.sh:12 — `find ~/.pub-cache/hosted/pub.dev -path ... | head -1` picks an arbitrary version when multiple sherpa_onnx_android_arm64 versions are cached; WANT may come from a stale/newer .so than the one Gradle packages, so the check can pass or fail for the wrong reason — resolve the exact version from `Pubspec.lock`/`.package_lock` (or `flutter pub deps`) instead of `head -1`.
- [low] scripts/verify-apk-ort.sh:14-15 — `strings | grep -E "^VERS_[0-9.]+$" | head -1` takes the first version string in the binary; if the .so embeds multiple VERS_ markers (e.g. ORT runtime + build metadata) the comparison can match a non-authoritative one — anchor to the expected pattern (e.g. `grep -E "^VERS_[0-9]+\.[0-9]+\.[0-9]+$"`) or take the last/known-good occurrence.
- [low] scripts/verify-apk-ort.sh:22-23 — `unzip -l | grep ... > /dev/null` under `set -o pipefail` can still die on SIGPIPE if unzip's output exceeds the pipe buffer before grep consumes it (grep without -q reads all input, so usually safe, but the comment's rationale is inverted: the risk is unzip's large listing, not grep's early exit) — use `unzip -l "$APK" lib/arm64-v8a/libonnxruntime4j_jni.so` (zip entry form) or `grep -c` with `|| true` to avoid the pipeline entirely.

## Coverage
scripts/ship-testflight.sh — findings: 5
scripts/verify-apk-ort.sh — findings: 3
- [info] macos/Flutter/GeneratedPluginRegistrant.swift:1 — generated file checked into source tree; verify it is not committed with stale plugin list diverging from pubspec — consequence: stale registration can omit newly added plugins or register removed ones, causing runtime plugin resolution failures — smallest safe fix: regenerate via `flutter pub get` / tooling and keep the generated file in sync with pubspec dependencies.
## Coverage
macos/Flutter/GeneratedPluginRegistrant.swift — findings: 1
macos/Runner/AppDelegate.swift — clean
I'll review the two files against the checklists and report only defensible findings.

Let me analyze the code carefully.

**BackgroundDownloadPlugin.swift analysis:**

- Line 56-58: `if let existing = activeDownloads[modelId] { existing.task?.cancel() }` — when restarting a download for the same modelId, the old task is cancelled. But cancelling a task triggers `didCompleteWithError` with `NSURLErrorCancelled` (line 168 returns early on that), and line 177 `activeDownloads.removeValue(forKey: modelId)` — wait, the early return at 168 happens BEFORE the removeValue at 177? No — let me re-check. Line 166-175: if error, and code == cancelled, `return` — so removeValue at 177 is skipped for cancelled tasks. Then line 61 sets `activeDownloads[modelId] = DownloadInfo(...)` with the new task. So the new entry survives. Actually wait — order: cancel() at 57 fires the delegate callback possibly synchronously or async. If async, the removal happens after the new assignment... Actually the delegate callback for cancelled tasks returns early at 168 without removing — so the new entry is safe. But if the delegate fires synchronously before line 61 assignment... cancel() typically doesn't fire didCompleteWithError synchronously. Hmm, but there's a subtle issue: for a cancelled task, `didCompleteWithError` returns early WITHOUT removing from activeDownloads — that's intentional here to preserve the new entry. But for the cancelDownload path (line 77-79), the entry is removed from the dict first, then task cancelled — the delegate callback returns early (cancelled), so no error emitted. OK.

- Potential bug: line 94-95: `guard let modelId = downloadTask.taskDescription` — taskDescription is a String? — actually `task.taskDescription` on URLSessionTask is `String?`. The guard is fine. But wait — taskDescription was set at line 66 AFTER creating DownloadInfo but the task was created at line 60. Setting taskDescription after task creation but before resume — fine.

- Line 100-101: `try? FileManager.default.removeItem(at: destURL)` then `try FileManager.default.moveItem(at: location, to: destURL)`. If destURL exists as a directory, removeItem works. Fine.

- Line 103: `attributesOfItem(atPath:)` — hmm, the actual API is `FileManager.attributesOfItem(atPath:)` returns `[FileAttributeKey: Any]`. The code does `[.size] as? Int` — subscript with `.size` key then cast to Int. Actually attributesOfItem returns dictionary; `dict[.size]` gives Any?, cast to Int. The `try?` on a non-throwing subscript... `attributesOfItem(atPath:)` throws, so `try?` is fine. Minor: size could be Int64/UInt64 — cast to Int might fail for large files? `.size` is typically UInt64. `as? Int` on UInt64 value... Any holding UInt64, `as? Int` would fail (UInt64 doesn't bridge to Int via as? unless it's NSNumber). Actually on Apple platforms, attribute values are NSNumber, and `as? Int` on NSNumber works via numeric bridging? NSNumber to Int via `as? Int` — yes, NSNumber bridges. Hmm, this is borderline. Actually `attributesOfItem` returns `[FileAttributeKey : Any]` where values are NSNumber. `as? Int` from NSNumber — in Swift, conditional casts from NSNumber to Int are possible via NSNumber bridging? Actually `NSNumber as? Int` does work in Swift (numeric types bridge). I'll not flag this as it's uncertain and minor.

- Throttle logic lines 143-148: `if let last = lastProgressEmit[modelId], progress < 1.0, progress - last.fraction < 0.01, now.timeIntervalSince(last.at) < 0.3 { return }` — this suppresses progress events. But note: when progress reaches 1.0, the condition `progress < 1.0` fails, so it emits. Fine. But there's a subtle bug: the throttle condition requires ALL four conditions to return early. If time interval >= 0.3, it emits even if fraction delta is tiny — that's the intended throttle. OK.

- Memory: `lastProgressEmit` entries are never cleaned up when downloads complete/fail — minor leak per modelId. Not really a bug worth flagging? It's a small unbounded growth if many modelIds. Probably low/info. I'll skip — actually it's a real minor leak: entries persist forever after download ends. Low severity.

- Line 42: `try? FileManager.default.removeItem(atPath: tmpPath)` — tmpPath = destinationPath + ".tmp". But then the download moves the file to destinationPath directly (line 101), never using tmpPath. The tmpPath removal is vestigial — harmless.

- Line 44-49: creates the destDir but ignores errors (`try?`). If directory creation fails, moveItem at 101 will fail and error is reported via onDownloadError — acceptable.

- Security: no path validation — destinationPath comes from Dart side; a malicious URL could be passed. But this is a local app plugin; the Dart side is trusted app code. Not a finding per typical review.

- `session` declared as `URLSession!` (line 8) — implicitly unwrapped; set in init. Fine.

- Delegate queue `.main` (line 25) — delegate callbacks on main thread; channel.invokeMethod from main thread is fine for Flutter.

- One more: in `didFinishDownloadingTo`, after successful move, `activeDownloads.removeValue(forKey: modelId)` at 119 — but `lastProgressEmit[modelId]` not removed (leak noted above).

- In `didCompleteWithError` for cancelled tasks: early return at 168 means the entry stays in activeDownloads. In the cancelDownload flow (line 77), the entry was already removed before cancel, so fine. In the restart flow (line 56-58), the new entry was assigned at 61 AFTER cancel — but if the delegate callback for the OLD task fires asynchronously AFTER line 61's assignment... the callback returns early (cancelled) without removing — safe. But what if the old task's cancellation callback fires and the guard at 164: `task.taskDescription` — the OLD task had taskDescription = modelId (same modelId). It returns early due to cancelled check. Safe.

Hmm wait — actually there's a real ordering hazard: `existing.task?.cancel()` at 57 — URLSession cancel is async; the didCompleteWithError for the old task may arrive later. Since it returns early on NSURLErrorCancelled, no removal. Good.

But what about `didFinishDownloadingTo` for a cancelled task? Cancelled tasks don't finish downloading. Fine.

- Another: line 66 `task.taskDescription = modelId` — but in `didCompleteWithError` the guard uses `task.taskDescription` — for tasks created via `session.downloadTask(with:)` where taskDescription wasn't set (e.g., if a task somehow bypassed)... all tasks here get taskDescription set. Fine.

- `handle` returns `result(true)` for startDownload — FlutterResult with Bool — fine.

- Missing: no cleanup of `session` or invalidation — plugin lives for app lifetime. Fine.

- Potential issue: `lastProgressEmit` throttle — when a download completes, `didFinishDownloadingTo` fires; but progress events may still arrive? Not after completion.

- One more potential: line 132-136: if totalBytesExpectedToWrite <= 0, progress = 0.0 — then throttle: progress < 1.0 true, progress - last.fraction < 0.01 (0 - last.fraction; if last.fraction is 0, true), time < 0.3 — returns early, suppressing. But then line 149 sets lastProgressEmit = (0.0, now) only if not throttled. If expected bytes unknown, progress stays 0 and events get throttled to one per 0.3s — fine.

**MainFlutterWindow.swift analysis:**

- Plugins created and stored as strong refs — fine.
- No real defects visible. `super.awakeFromNib()` called at end — fine (should be called; order is acceptable).
- `FlutterViewController()` created then assigned as contentViewController — standard macOS Flutter template pattern.

No findings for MainFlutterWindow.

Now, the reference checklist is GCP-focused — none of those classes apply to these Swift files. So findings come from general code review.

Let me decide on final findings:

1. `lastProgressEmit` never cleaned up — entries accumulate per modelId forever. Low severity (memory leak, bounded by number of distinct modelIds; desktop app). Actually is this defensible? Yes — line 149 writes entries, and neither completion path (119, 177) removes them. Low.

2. Anything else? The `try?` on removeItem at line 100 before moveItem — if removeItem fails because the file doesn't exist, that's fine (moveItem proceeds). If removeItem fails because it's a directory with contents... moveItem would then fail and error reported. Acceptable.

3. Line 103: `attributesOfItem(atPath:)` — wait, is the actual signature `attributesOfItem(atPath:)`? FileManager has `attributesOfItem(atPath:)`. Yes. And `attributesOfItem(atPath: info.destinationPath)` — but the file was moved TO destURL which is destinationPath — same path. Fine.

4. Size cast: `(try? ... [.size] as? Int) ?? 0` — hmm, operator precedence: `try? FileManager.default.attributesOfItem(atPath: ...)[.size] as? Int` — the `try?` applies to the whole expression including the subscript and cast? `try? expr` where expr includes subscripting a throwing call result... Actually `attributesOfItem(atPath:)` throws; `try? f()[.size] as? Int` — the try? covers the throwing call; subscripting the optional result... `try?` on `(try? ...)` hmm. The expression is `try? A[.size] as? Int` where A is throwing call — Swift allows `try?` to cover the whole expression. If A throws, whole thing is nil → `?? 0`. If `.size` missing → subscript on dictionary returns Any? → nil → `?? 0`. Cast failure → nil → 0. So size falls back to 0 silently and the log/emit reports 0 MB. Minor — but only affects a log line and the "size" argument. Not really a bug worth flagging? The emitted size could be 0 incorrectly. It's a silent fallback to a wrong-ish value but only cosmetic (progress already tracked separately). I'll skip or flag as low? The instruction says report only defensible findings. The cast `as? Int` on NSNumber-backed UInt64 — NSNumber to Int cast works. I'll skip.

5. Restart flow race: cancel old task then immediately create new task with same modelId — if the old task's `didFinishDownloadingTo` had already fired... no, cancelled tasks don't finish.

Actually wait — one more real one: in the restart flow, if the old task already COMPLETED and its entry was removed at 119, then `activeDownloads[modelId]` is nil at 56 — fine.

6. `handle` "startDownload" — `result(true)` — but if the same modelId restart happens, the old task cancel triggers didCompleteWithError → early return (cancelled) → no onDownloadError emitted to Dart. Good — otherwise Dart would get a spurious error.

Hmm, but there IS a subtle defect: in `didCompleteWithError`, for cancelled tasks the early return also skips `activeDownloads.removeValue`. In the cancelDownload path the caller removed it first — fine. In restart path the new entry must survive — fine. So the early return is intentional and correct. No finding.

7. Thread safety: `activeDownloads` and `lastProgressEmit` mutated on main queue (delegate queue is main; method handler runs on platform channel thread = main). Consistent. Fine.

8. `session` is `URLSession!` — if init never runs... it's the only init. Fine.

So the only finding I'm confident in: the lastProgressEmit leak. Severity: low (operator/desktop app, slow growth). Actually who can reach it — it's not a security issue; it's a resource leak. Severity low.

Is there anything about `NSLog` of URLs/paths — no sensitive data.

One more consideration: line 41-42 tmpPath logic is dead code (the .tmp file is removed but never used; downloads move directly to destinationPath). Harmless vestige — could flag as info? It's not a defect causing failure. Skip.

Also: `config.allowsCellularAccess = true` on macOS default config — meaningless on macOS. Harmless.

MainFlutterWindow: clean.

Coverage: both files reviewed.

Final report format: findings lines then ## Coverage.
- [medium] macos/Runner/PdfTextPlugin.swift:55,81,97,120,136,138 — FlutterResult callbacks invoked asynchronously on a background queue and then re-dispatched to main via DispatchQueue.main.async — the FlutterResult contract requires the result callback to be invoked on the platform main thread exactly once per method call; here the closure is captured and called from a background thread first in the failure path (extractText:59-64, extractTextPerPage:100-106) — engine may crash or drop the reply — invoke result synchronously on the main thread (wrap the failure-path result calls in DispatchQueue.main.async like the success paths, or capture result on main before dispatching).
- [medium] macos/Runner/PdfTextPlugin.swift:58,100,145 — PDFDocument(url:) failure is conflated with "no text" in hasEmbeddedText (checkEmbeddedText returns false on open failure) — an unreadable/corrupt PDF is reported as "no embedded text" instead of an error, so the caller's OCR-vs-PDFKit decision silently picks OCR for a broken file — return a distinct error/nil for open failure and let the caller branch on it.
- [low] macos/Runner/PdfTextPlugin.swift:113 — document.page(at: i)?.string ?? "" appends empty strings for pages that fail to load, and hasAnyText is computed from those same strings — a page whose text extraction throws/returns nil is indistinguishable from a genuinely empty page in the returned "pages" array — use nil and skip/flag such pages so callers can tell empty from failed.
- [low] macos/Runner/MemoryMonitorPlugin.swift:47 — getPhysicalFootprint returns 0 on mach call failure, which the caller then reports as "physicalFootprintMB: 0" and derives availableMemoryMB = total - 0 — a failed syscall silently yields a bogus "all memory available" reading instead of an error — return nil/throw on KERN_FAILURE and surface an error to the channel.
- [info] macos/Runner/MemoryMonitorPlugin.swift:21 — totalPhysicalMemoryMB is computed from ProcessInfo.physicalMemory (host total) while phys_footprint is per-process — the "availableMemoryMB" figure mixes host-total with process-footprint semantics and can be misleading for the memory-monitor use case — document the semantics or compute available from host-level statistics.

## Coverage
macos/Runner/MemoryMonitorPlugin.swift — findings: 2
macos/Runner/PdfTextPlugin.swift — findings: 3
- [medium] macos/Runner/VisionOcrPlugin.swift:44 — `args["scale"]` is read from the outer `args` dictionary but the `ocrPdf` branch's guard only validated `path`; a malformed scale payload is silently coerced to 2.0 instead of erroring — consequence: a caller passing a string scale gets an unexpected default render scale with no INVALID_ARGS feedback, masking client-side bugs — smallest safe fix: validate `scale` in the guard (or return INVALID_ARGS when `as? Double` fails) rather than falling back to 2.0.
- [medium] macos/Runner/VisionOcrPlugin.swift:100-101 — `width`/`height` are computed as `bounds.width * scale` but `renderPage` allocates a CGContext of `Int(width) × Int(height)` with no upper bound beyond the 4.0 scale clamp; a PDF with a huge mediaBox (e.g. 10000×10000pt) at scale 4 yields a multi-GB bitmap allocation — consequence: jetsam/OOM of the Runner process mid-OCR on a crafted or simply large-format PDF, taking down the whole plugin call — smallest safe fix: clamp the absolute pixel dimensions (e.g. cap width/height at ~4096px) before allocating the context.
- [medium] macos/Runner/VisionOcrPlugin.swift:93-119 — the per-page loop runs `Self.ocrImage` (accurate-level Vision recognition) synchronously for every page inside one `DispatchQueue.global` block and accumulates all results in memory before a single result callback — consequence: for a long document the whole pipeline blocks a QoS worker for minutes with no progress or cancellation path, and the accumulated `pages` array holds every line's text/confidence in memory at once — smallest safe fix: process pages incrementally (per-page result events or a progress channel message) and/or cap concurrent work per page.
- [low] macos/Runner/VisionOcrPlugin.swift:182-184 — sorting observations strictly by `boundingBox.origin.y` descending treats every distinct Y as a separate line and does not group same-baseline fragments; multi-column or slightly-tilted text yields out-of-order or fragmented lines — consequence: returned `lines` ordering can misrepresent reading order for non-single-column pages — smallest safe fix: bucket observations into lines by Y proximity (and sort within a line by X) before emitting.
- [low] macos/Runner/VisionOcrPlugin.swift:188 — `topCandidates(1).first` discards alternative candidates but the emitted dict has no per-line bounding box or language metadata, so consumers cannot reconstruct layout beyond order — consequence: downstream layout reconstruction from this channel payload is lossy compared to what Vision provides — smallest safe fix: include `boundingBox` (and optionally `w/height`) in each line dict.
- [info] macos/RunnerTests/RunnerTests.swift:7-10 — the only test is an empty placeholder that cannot fail — consequence: no regression protection for the Runner/plugin code; any future breakage ships untested — smallest safe fix: replace with real tests targeting `VisionOcrPlugin` behavior (or remove the file if tests are intentionally absent).

## Coverage
macos/Runner/VisionOcrPlugin.swift — findings: 5
macos/RunnerTests/RunnerTests.swift — findings: 1
- [medium] lib/features/script_import/pdf_page_view.dart:109-120 — dispose() captures `_pageCache.values` into `images` and disposes them in a post-frame callback, but `_evictAllCached`/`_cachePut` can dispose the same `ui.Image` again if a render completes between dispose and the next frame — double-dispose throws — guard the deferred loop with a per-image disposed flag or dispose synchronously before scheduling — reachability: any authenticated user closing the viewer mid-render
- [medium] lib/features/script_import/pdf_page_view.dart:132-148 — `_cachePut` evicts by insertion order but never re-orders the map on cache hit, so the "least recently inserted" entry is not least-recently-used; a hot older page can be evicted while a stale one survives — consequence is only extra re-renders, not a crash — refresh LRU position on hit (remove+reinsert) or track access order — reachability: any authenticated user paging
- [low] lib/features/script_import/pdf_page_view.dart:203-207 — `MediaQuery.maybeOf` is read inside an async render path; if the widget was rebuilt with a different size the render width is stale until the next flip — minor visual blur only — recompute scale from the last known constraints in build — reachability: any authenticated user
- [low] lib/features/script_import/pdf_page_view.dart:176-179 — `Pdfrx.getCacheDirectory ??=` assigns a closure to a static setter every render call; if `getCacheDirectory` is a late/final field this throws on the second render — verify the field is a plain nullable var; if so this is clean — reachability: any authenticated user
- [medium] lib/features/script_import/script_import_screen.dart:603-637 — `_commitStagedPdf` copies to `destPath.incoming` then renames, but if `copy` succeeds and `rename` throws (e.g. dest locked on Windows), the previous script's PDF at `destPath` is untouched yet `_importedPdfPath`/`_pdfPendingCommit` are never reset and the `.incoming` file leaks — wrap copy+rename so a rename failure deletes the `.incoming` and rethrows before touching state — reachability: any authenticated user accepting a script on a device where the rename fails
- [medium] lib/features/script_import/script_import_screen.dart:621-622 — `File(staged).copy('$destPath.incoming')` then `incoming.rename(destPath)` is not atomic across the copy: a crash between copy and rename leaves the previous script's PDF intact but the app state (`_pdfPendingCommit`) already advanced past the point of no return only after rename — acceptable, but the `.incoming` orphan is never cleaned on the next run — add cleanup of stale `.incoming` files at commit start — reachability: any authenticated user
- [low] lib/features/script_import/script_import_screen.dart:665-735 — `WakelockPlus.enable()` is enabled before the long OCR await and disabled in `finally`, but the early `return` at 671 (`if (!mounted) return`) still runs the `finally` — correct — no finding
- [medium] lib/features/script_import/script_import_screen.dart:684-702 — staging failure path sets `_importedPdfPath = filePath` (the picker's temp file) and `_pdfPendingCommit = true`; on Accept, `_commitStagedPdf` then copies the picker temp file to `Documents/scripts/{id}.pdf` — if the picker already deleted its temp file the accept-time copy throws and the user sees "Couldn't save" with no staged PDF — acceptable degradation, but the error message at 589 claims "it has NOT been added" while the production's `scriptPath` may already point at the new file if a prior accept partially succeeded — verify `copyWith(scriptPath:)` ordering; if state is only mutated after success this is clean — reachability: any authenticated user
- [low] lib/features/script_import/script_import_screen.dart:184-199 — `_countsFor` memoizes on `identical(cached.$1, script.lines)`; `ParsedScript` instances are rebuilt in `_openReview` with new `lines` lists so the memo correctly misses — clean
- [low] lib/features/script_import/script_import_screen.dart:459-481 — `_recountCharacters` drops characters whose lines were all removed (intended per comment) but also drops a character that only ever spoke in removed `likelyNotScript` lines even if they still speak elsewhere via `multiCharacters` — consequence: cast list loses a name until next reload — include multi-character membership when recounting — reachability: any authenticated user reviewing
- [info] lib/features/script_import/script_import_screen.dart:576-580 — `AnalyticsService.instance.logScriptImported` is called with `format: _importedPdfPath != null ? 'pdf' : 'text'` before `_commitStagedPdf` has necessarily succeeded on the failure path — the format label can be wrong after a failed commit — move the analytics call after successful commit or pass the actual committed path — reachability: any authenticated user
- [low] lib/features/script_import/pdf_page_view.dart:336-340 — `_goToPage` guards `page > _totalPages` but `_totalPages` is only set after a successful open; before the first render completes `_totalPages` is 0 and both arrows are disabled via `onPressed` null checks — clean
- [low] lib/features/script_import/pdf_page_view.dart:295 — `_scrollToHighlight(rects.first)` uses the first rect only; if the matched text spans multiple rects only the first is scrolled into view — cosmetic — scroll to the union or the rect nearest viewport center — reachability: any authenticated user

## Coverage
lib/features/script_import/pdf_page_view.dart — findings: 5
lib/features/script_import/script_import_screen.dart — findings: 6
- [medium] lib/features/settings/ai_models_screen.dart:36 — `Platform.isAndroid` used with `dart:io` Platform on a screen that also builds iOS tiles — on non-mobile platforms (web/desktop) `Platform.isAndroid` throws `UnsupportedError`/`Platform._operatingSystem` access is unsupported, crashing the settings screen at build — guard with `defaultTargetPlatform`/`kIsWeb` or wrap in try — reachability: any authenticated user opening AI Models on web/desktop build target.
- [medium] lib/features/settings/ai_models_screen.dart:139-147 — the `else` branch of the platform check renders `_buildModelTile` for every non-Android platform including iOS, but the comment says iOS gets individual MLX tiles while Android gets the grouped tiles; on Android the live_asr group tile is built via `_buildLiveAsrTile` AND the generic `availableModels` list is skipped only on the non-Android branch — on Android the per-model tiles for `live_asr` files are not shown (intended), but on iOS `_buildLiveAsrTile` is never reachable and `availableModels` includes `live_asr` entries whose `subdir == 'live_asr'` are rendered individually even though the comment at 238-241 says the pieces are useless individually — consequence: iOS users can download encoder/decoder/joiner/tokens one-by-one and end up with a partially-installed, non-functional ASR group with no group delete — fix: filter `live_asr` out of the generic list on iOS and render `_buildLiveAsrTile` there too.
- [low] lib/features/settings/ai_models_screen.dart:246-268 — `_buildLiveAsrTile` computes `totalBytes` from `models` but if `availableModels` has no `live_asr` entries `totalBytes` is 0 and line 267 divides by it (`m.sizeBytes / totalBytes`) producing NaN progress — guard `totalBytes > 0` before the fold — reachability: only if the model list is empty, so low.
- [low] lib/features/settings/ai_models_screen.dart:331-336 — delete loop `for (final m in models) { await _service.delete(m.id); }` has no error handling; a failed delete silently leaves the group half-deleted while the UI keeps showing "Installed" until the next `refreshDownloadedStatus` — wrap in try/catch and surface a toast — reachability: authenticated user deleting their own local model files, low.
- [low] lib/features/settings/ai_models_screen.dart:109-118 — `_deleteOnnxKokoro` calls `ModelManager.instance.clearCache()` then immediately sets `_onnxReady = false` without checking the clear succeeded; if clearCache throws the state still flips to not-ready while files remain on disk (or vice versa) — catch and reflect actual result — low.
- [medium] lib/features/settings/debug_log_screen.dart:75-81 — the "Send to developer" action inserts the full log text (which can contain user email, user id, and arbitrary runtime log content) into the `debug_reports` table with `user_id`/`user_email` columns; there is no visible consent step and the insert runs unconditionally on tap — if the table is readable by other rows/policies this can leak one user's log (potentially containing another tenant's identifiers logged at runtime) to the developer account; at minimum confirm RLS on `debug_reports` restricts reads to the owning user — reachability: authenticated user uploading their own log = medium unless RLS is confirmed absent.
- [low] lib/features/settings/debug_log_screen.dart:163-164 — `test_fatal` menu item throws inside a popup `onSelected` callback after a 200ms delay; in release builds this is an uncaught exception that crashes the app for the user who tapped a "test" menu item that should be debug-only — gate the whole PopupMenuButton behind `firebaseAvailable && kDebugMode` — reachability: authenticated user tapping a diagnostics menu item, low (self-inflicted crash) but silent in release.
- [low] lib/features/settings/debug_log_screen.dart:166-171 — `test_native_crash` calls `FirebaseCrashlytics.instance.crash()` unconditionally when `firebaseAvailable`; same debug-only gating issue as above — low.
- [low] lib/features/settings/debug_log_screen.dart:32-42 — the 2-second periodic timer calls `setState(() {})` via the mounted check but never compares `entryCount` to a snapshot taken outside the closure correctly: `_lastEntryCount` is updated before `setState`, so if the widget is disposed between the compare and the rebuild the timer keeps firing every 2s doing a full `entriesForCategory` scan (O(n) over up to 500 entries) — harmless but wasteful; consider cancelling in dispose (already done) and early-return when count unchanged (already done) — no change needed; not reported as a defect.
- [info] lib/features/settings/debug_log_screen.dart:152 — `setCustomKey('test_key', 'test_value_...')` sets a Crashlytics custom key with a timestamp value on every tap; repeated taps grow the key map unbounded in the Crashlytics payload — cosmetic, info only.

## Coverage
lib/features/settings/ai_models_screen.dart — findings: 5
lib/features/settings/debug_log_screen.dart — findings: 4
- [medium] lib/features/settings/kokoro_debug_screen.dart:56 — `await for` on a Stream is not valid Dart syntax (streams are iterated with `await for` only as a statement form `await for (var x in stream)`, but here it is written as `await for (final entity in ...)` inside an expression position after `await` on the previous line, producing a compile error) — the debug screen fails to build, so the model-files listing never renders — replace with `for (final entity in kokoroDir.list(...))` (sync `FileSystemEntity` stream) or `await for` without the leading `await` on line 56.
- [low] lib/features/settings/kokoro_debug_screen.dart:112 — `int.tryParse(_speakerController.text) ?? 0` silently maps invalid speaker input to 0 — a typo'd speaker id triggers a speak attempt with the wrong voice instead of surfacing an error — parse and show a validation message when `tryParse` returns null.
- [low] lib/features/settings/kokoro_debug_screen.dart:115 — `text.substring(0, text.length.clamp(0, 60))` truncates the logged text to 60 chars but appends `...` even when nothing was truncated — cosmetic only, log misleads about content length — conditionally add the ellipsis only when `text.length > 60`.
- [low] lib/features/settings/kokoro_debug_screen.dart:118 — `_tts.setRate(_speed * 0.5)` maps the 0.5–2.0 slider onto 0.25–1.0 without documenting the scaling — speed slider labeled "2.0x" actually requests half that rate from the engine — either pass `_speed` directly or name the transform in the UI/log.
- [info] lib/features/settings/kokoro_debug_screen.dart:90 — `_statusLog` grows unboundedly (newest-first prepend, no cap) — a long debug session accumulates strings and rebuilds the whole log text each action — cap stored lines (e.g. keep last ~50) or use a `ListView` of entries.
- [low] lib/features/settings/model_download_screen.dart:31 — listener registered in `initState` but `_onDownloadUpdate` calls `setState(() {})` with no guard against updates arriving between `mounted` checks and dispose; the `mounted` check inside the callback is present, so this is only a nit — no action needed beyond the existing guard.
- [medium] lib/features/settings/model_download_screen.dart:62-75 — `_downloadAll` awaits `_manager.downloadAll` and then `_checkStatus`, but `_modelProgress` is never cleared on a new run — stale per-model progress rows from a previous failed/partial run persist into the next download's UI — clear `_modelProgress` in the `setState` at lines 56-59 before starting.
- [low] lib/features/settings/model_download_screen.dart:94 — `allReady` is computed only from `_kokoroReady`; if other models exist (the screen advertises "Download All Models"), their readiness is ignored and the success card can show while other models are missing — derive readiness from the full model set or rename the copy to match Kokoro-only scope.
- [low] lib/features/settings/model_download_screen.dart:253 — `clearCache` is awaited without try/catch; a thrown exception escapes the async closure registered as the button's `onPressed`, leaving the dialog's success path silently broken with an unhandled async error — wrap in try/catch and surface `_error`.
- [info] lib/features/settings/model_download_screen.dart:184 — Retry button re-invokes `_downloadAll` but `_downloading` is reset in `finally` only when `mounted`; if the widget was disposed mid-download the flag stays true in the (dead) state object — harmless for UI since the widget is gone, noted for completeness only.

## Coverage
lib/features/settings/kokoro_debug_screen.dart — findings: 5
lib/features/settings/model_download_screen.dart — findings: 4
- [medium] lib/features/settings/settings_screen.dart:292-296 — Web-editor share text embeds the signed-in user's email address into a share sheet — any authenticated user can trigger this against their own account, but the email is also shared to whatever share target they pick (clipboard, other apps) with no confirmation; if the app is ever used on a shared device the address leaks silently — gate the email inclusion behind an explicit confirmation dialog or omit it from the share text
- [low] lib/features/settings/settings_screen.dart:69-76 — `_getVersionString` memoizes a `Future` that is created eagerly at first call; if `PackageInfo.fromPlatform()` throws before the future is assigned the catch still returns a value, but the `??=` memoization means a failed platform call is cached forever and the fallback string is reused for the app lifetime — acceptable for version display, but note the memoized future is created even when never awaited (minor waste) — no action needed beyond awareness
- [low] lib/features/settings/settings_screen.dart:324-359 — `_signOut` clears `auth_skipped` and resets in-memory auth state before Supabase sign-out completes; if `SupabaseService.signOut()` throws, the local state is already cleared and the user is navigated to `/auth` while the server session may still be live — the toast at 343-348 acknowledges this, but the navigation at 357-358 happens unconditionally after the catch, so a user who taps "Sign in again" may find the old session still active — await sign-out success before resetting in-memory state, or re-verify session state on the auth screen
- [info] lib/features/settings/settings_screen.dart:328 — `sharedPreferencesProvider` is read via `ref.read` inside an async method captured from a `ConsumerWidget` build context; if the widget is disposed mid-await this is safe in Riverpod 2.x (provider container outlives widgets), but confirm the provider is a global override and not a scoped container — verify it is not committed if this file is part of a secret-scan sweep

## Coverage
lib/features/settings/settings_screen.dart — findings: 4
- [info] lib/firebase_options.dart:53,62 — Firebase API keys are embedded in the client bundle (standard for Flutter apps; keys are public by design) — verify it is not committed if repo policy treats generated config as secret; consequence: none beyond normal Firebase client exposure — smallest safe fix: confirm the file is committed intentionally and API key restrictions (HTTP-ref/app-id) are configured in Firebase console.
- [medium] lib/app.dart:39-44 — authGatePassedProvider is a one-shot StateProvider initialized from SupabaseService.instance at provider creation time; if SupabaseService finishes session restore asynchronously after the provider is first read, the gate stays false and every route redirects to '/auth' (or, conversely, if instance is initialized before a session is restored, it stays true and unauthenticated users reach protected screens) — consequence: auth gate can be permanently wrong for the app lifetime since nothing re-evaluates it on session changes — smallest safe fix: derive the gate from a reactive auth-state stream (e.g. ref.listen on a signedIn provider) instead of a read-once StateProvider.
- [medium] lib/app.dart:234-243 — _handlePendingJoin pushes '/join' only when authGatePassedProvider is true, and relies on the auth screen to pick up the pending join otherwise; if the auth screen does not observe pendingJoinProvider (cannot be verified from this file), cold-start invite links for signed-out users are silently dropped — consequence: invite deep link does nothing for unauthenticated users — smallest safe fix: verify AuthScreen consumes pendingJoinProvider; if not, route to '/auth' with the pending join retained and navigate after sign-in.
- [low] lib/app.dart:258-275 — ref.listen callback runs launchRecordingSync(ref, next.id) after an async load with no guard against a newer production having been selected during the await — consequence: recordings sync could start for a production that is no longer current — smallest safe fix: re-check the current production id inside the async block before launching sync.
- [low] lib/app.dart:264-274 — unawaited(() async {...}()) swallows non-Error exceptions only via the inner try/catch around loadForProduction; launchRecordingSync(ref, next.id) at line 273 is outside the try, so a synchronous throw escapes into an unawaited future — consequence: unhandled async error with no logging — smallest safe fix: move launchRecordingSync inside the try or wrap the whole body.

## Coverage
lib/app.dart — findings: 4
lib/firebase_options.dart — findings: 1
- [high] lib/main.dart:94-97 — hardcoded Supabase URL and anon key as default values in `String.fromEnvironment` — the publishable anon key is embedded in the shipped binary and cannot be rotated via build config; anyone extracting it can call the public API with that key (anon key is designed to be public, but baking a specific project's key as a *default* means a misconfigured build silently ships the wrong project's credentials) — remove the `defaultValue` and fail fast (or log a clear error) when the env var is absent, so only explicitly-configured builds contain credentials.
- [medium] lib/main.dart:163-164 — `authGatePassedProvider` is overridden to `true` whenever `prefs.getBool('auth_skipped')` is set, but nothing in this file verifies that a skipped-auth user is entitled to skip (e.g. a flag set by a prior build or tampered local storage) — an attacker with device access (or a stale flag from a removed feature) bypasses the login gate entirely; gate the override on an actual Supabase session or re-validate the flag server-side.
- [low] lib/main.dart:125-147 — `Future.microtask` schedules async work (TTS/STT init, ~178 MB model download) that is never awaited and has no error handling; an exception inside the microtask is an unhandled async error that escapes the `main()` zone — wrap the body in `runZonedGuarded` or attach `.catchError` so failures surface to Crashlytics instead of silently dropping.
- [low] lib/main.dart:133-146 — consent-gated download loop calls `modelService.download(model)` sequentially inside a `for` loop with no error handling; a single failed download aborts the remaining models silently — catch per-model errors and continue, or aggregate failures for reporting.
- [info] lib/main.dart:78-91 — Crashlytics/Performance/Analytics collection is force-enabled unconditionally (`setCrashlyticsCollectionEnabled(true)`, `setPerformanceCollectionEnabled(true)`, `setAnalyticsCollectionEnabled(true)`) with no consent gate; verify this matches the app's privacy policy / App Store disclosure requirements for telemetry collection.
- [info] lib/main.dart:54-58 — `DebugLogService.instance.log(...)` is called before `DebugLogService.instance.init()` (line 112); entries queue in `_pendingFlush` per the context file (debug_log_service.dart:177-192), so they are only persisted if init later succeeds — acceptable by design, but note the ordering dependency.

## Coverage
lib/main.dart — findings: 6
- [info] pubspec.yaml:4 — version 0.1.1+155 with publish_to 'none' — no consequence for repo security; verify the build number matches CI tagging if used — none needed.
## Coverage
pubspec.yaml — clean
- [medium] supabase/config.toml:156 — additional_redirect_urls includes a custom deep-link scheme `castcircle://auth-callback` alongside the production site URL — if the hosted auth instance treats these as exact-match allow-list entries, a misconfigured or spoofed client redirect could land users on an unvalidated handler; verify the app's auth-callback handler validates the session payload before consuming it — restrict additional_redirect_urls to the exact production origins actually used by the deployed clients and confirm the deep-link handler validates tokens server-side before trusting them.
- [medium] supabase/config.toml:178 — password_requirements is set to an empty string, which disables all password strength enforcement beyond the 6-character minimum — weak passwords are accepted for all new signups, increasing credential-stuffing success against the public auth endpoint — set password_requirements to at least "letters_digits" (or "lower_upper_letters_digits") to match the documented recommended baseline.
- [medium] supabase/config.toml:214 — secure_password_change = false allows password changes without reauthentication — an attacker with a hijacked active session (e.g. via a stolen refresh token within the 10s reuse window) can change the account password and lock out the legitimate owner without supplying the current password — set secure_password_change = true so password changes require a recent login or reauthentication.
- [medium] supabase/config.toml:167 — refresh_token_reuse_interval = 10 permits a stolen refresh token to be replayed for up to 10 seconds after rotation; combined with token_refresh rate limit of 150/5min this is a narrow window, but it is a deliberate weakening of rotation guarantees — consider setting it to 0 (strict rotation) unless the mobile/web clients require immediate token reuse after a network retry; if kept, document the accepted replay window.
- [low] supabase/config.toml:182 — auth.rate_limit.email_sent = 2 per hour is extremely tight for a production SMTP (Resend) setup with email confirmation required; legitimate flows such as signup confirmation + password reset + email-change double-confirmation for a single user within an hour can exceed this and silently fail user onboarding — raise to a value that accommodates double_confirm_changes = true (e.g. 10-30/hour) or document the operational constraint.
- [info] supabase/config.toml:238 — SMTP pass is sourced from env(RESEND_API_KEY) rather than hardcoded — verify it is not committed (no literal secret present in this file; the value is an env substitution reference only).
- [info] supabase/config.toml:396-401 — S3 access/secret keys are env(S3_ACCESS_KEY)/env(S3_SECRET_KEY) substitutions, not literal secrets — verify it is not committed (no literal values present in this file).

## Coverage
supabase/config.toml — findings: 6
## Coverage
macos/Runner/BackgroundDownloadPlugin.swift — findings: 3
macos/Runner/MainFlutterWindow.swift — clean

- [medium] macos/Runner/BackgroundDownloadPlugin.swift:56-58 — re-issuing "startDownload" for an existing modelId cancels the old task but never removes it from `activeDownloads` before overwriting, and the cancelled task's `didCompleteWithError` fires with `NSURLErrorCancelled` (line 168 returns early) — the stale entry is silently replaced, which is fine, but if the new task fails before the old one's cancel callback lands, the error path at line 177 removes the NEW entry keyed by modelId while the old task may still be mid-cancel — consequence: a subsequent `startDownload` for the same modelId can resurrect a half-torn-down state and progress events from the cancelled task (line 129-156) still emit under the new modelId, corrupting the UI's progress for the fresh download — smallest safe fix: in the `existing` branch, also `activeDownloads.removeValue(forKey: modelId)` (or set `existing.task = nil`) before creating the new task, and guard progress emission by checking `activeDownloads[modelId]?.task === downloadTask` in the progress delegate.

Wait — I need to re-examine. The progress delegate at line 129 uses `downloadTask.taskDescription` = modelId, and the throttle map `lastProgressEmit` is keyed by modelId. A cancelled task's didWriteData can still fire? Actually once cancelled, URLSession stops delivering didWriteData. The real defect: line 56-58 cancels the old task; the old task's `didCompleteWithError` (line 159) fires with cancelled error and line 177 does `activeDownloads.removeValue(forKey: modelId)` — removing the NEW DownloadInfo that was just stored at line 61 if the cancel callback lands after the new task is registered. That's a genuine race: the new active download is silently removed from the map, so `cancelDownload` (line 77) can't find it and `didFinishDownloadingTo` (line 95) drops the completion. Severity: medium (authenticated user's own download; recoverable by re-issuing startDownload, but silent state loss).

Let me restate the finding properly.

- [medium] macos/Runner/BackgroundDownloadPlugin.swift:56-58,61,177 — restarting a download for an existing modelId cancels the old task; the old task's `didCompleteWithError` then runs line 177 `activeDownloads.removeValue(forKey: modelId)`, which can remove the NEW task's entry (stored at line 61) if the cancel callback lands after registration — consequence: the fresh download becomes untracked (cancelDownload no-ops, completion delegate drops it, progress throttle map desyncs) — smallest safe fix: before creating the new task, remove the old entry and set `existing.task = nil` (or key entries by task identity / check `info.task === task` before removing at line 177).

- [medium] macos/Runner/BackgroundDownloadPlugin.swift:100-101 — `didFinishDownloadingTo` moves the temp file to destinationPath with `moveItem`, which fails if the destination already exists (previous download left a file there); the catch at 111 then reports "Failed to save file" even though the download succeeded — consequence: every re-download of the same model to the same path reports an error to the UI and the completed file is left in the temp location — smallest safe fix: `try? FileManager.default.removeItem(at: destURL)` is already there at line 100 but uses `try?` so a *real* error (e.g. file in use) is swallowed and moveItem still fails; instead remove with error propagation or use `replaceItem`/`moveItem` with `.init` that replaces. Actually line 100 does remove first — so moveItem shouldn't fail on existing file. Hmm. `try? removeItem` swallows errors, so if removal fails (file locked), moveItem fails. That's the direction-of-failure point: removal failure is silently ignored, then the move fails and the user gets a misleading error. Keep as low/medium? The user can retry; but the error message is misleading and the temp file leaks. I'll report as low.

- [low] macos/Runner/BackgroundDownloadPlugin.swift:103-104 — size computed via `attributesOfItem(atPath:)` — wait, the API is `attributesOfItem(atPath:)`? The real Foundation API is `FileManager.attributesOfItem(atPath:)` — yes that exists. `[.size]` cast to Int — fine. Not a finding.

- [low] macos/Runner/BackgroundDownloadPlugin.swift:42 — `try? FileManager.default.removeItem(atPath: tmpPath)` where tmpPath = destinationPath + ".tmp" — but the download task's actual temp location is URLSession's own; this pre-removal of a ".tmp" sibling is speculative and swallows errors; harmless. Not a finding.

- [medium] macos/Runner/BackgroundDownloadPlugin.swift:119 — after successful completion, `activeDownloads.removeValue(forKey: modelId)` at line 119 removes the entry, but `lastProgressEmit[modelId]` is never cleared — consequence: unbounded growth of the throttle map across many model downloads in a long-running desktop session (memory leak, minor) — smallest safe fix: `lastProgressEmit.removeValue(forKey: modelId)` alongside line 119 and line 177. Severity low (operator-local desktop app, slow leak). Actually severity guidance: low.

- [high]? Consider: `handle` runs on whatever thread the channel handler is called on (platform main thread), and the URLSession delegate queue is `.main` (line 25) — so delegate callbacks and method-channel handlers all run on the main queue; dictionary access is consistent. No data race. Good.

- Progress throttle: line 143-148 — if `progress >= 1.0` the guard's `progress < 1.0` clause fails, so the 100% event always emits — intended. If time since last emit >= 0.3s, emits. OK.

- Line 168: cancelled error returns early WITHOUT removing from activeDownloads — for the restart race that's the point above; for explicit `cancelDownload` (line 77) the entry was already removed, so fine. But for a cancel triggered by the restart path (line 57), the entry now holds the NEW task — the early return at 168 leaves the new entry intact (good) unless the callback ordering issue... wait, re-check the race: restart path: line 57 cancels old task; line 61 stores new info under modelId. Old task's didCompleteWithError(cancelled) fires later → line 168 returns early → line 177 NOT reached (return before it). So the new entry survives. The race I described is wrong! Line 168 returns before line 177. So cancelled-task callbacks never remove entries. Good — no race there.

But then: explicit `cancelDownload` removes the entry at 77 then cancels; cancelled callback early-returns; fine.

What about a task that fails with a REAL error: line 171 emits onDownloadError, line 177 removes. Fine.

What about `didFinishDownloadingTo` + `didCompleteWithError(nil)`: both fire for download tasks; completion path removes entry at 119; didCompleteWithError(nil) then runs line 177 removeValue again — harmless (already gone). But wait: for a NEW restart issued between didFinish and didComplete? Edge, ignore.

So the restart race finding is invalid. Drop it.

Re-examine line 56-58 again: `existing.task?.cancel()` — old task cancelled; its didCompleteWithError(cancelled) early-returns at 168 — no removal — new entry at 61 replaces old. Clean.

Now real defects in this file:

1. Line 100: `try? removeItem(at: destURL)` swallows removal failure; then line 101 `moveItem` fails if dest exists/locked → misleading "Failed to save file" error and leaked temp file. Direction of failure: swallowed error → riskier outcome. Low/medium. The user is authenticated-to-own-data; recoverable by retry. I'll say low. Hmm, but every re-download to an existing path... actually removeItem succeeds if the file exists and isn't locked. Normal case fine. Only locked/exotic failure. low.

2. Line 119/177: `lastProgressEmit` never cleaned → slow unbounded growth keyed by modelId. low.

3. Line 103: `attributesOfItem(atPath: info.destinationPath)` — after moveItem, file at destinationPath; size in bytes; log divides by 1024/1024 — fine.

4. Line 66: `task.taskDescription = modelId` — taskDescription is a String? on URLSessionTask; used as guard at 94/129/164. Fine.

5. Line 60: `session.downloadTask(with:)` on a default (non-background) session — app suspension/quit kills download; desktop app, acceptable. Not a finding.

6. Line 69: `result(true)` — returns Bool to Flutter; fine.

7. Missing `didCompleteWithError` removal when error is nil AND didFinish never called (e.g., server returns non-2xx? URLSession downloadTask treats HTTP errors as error) — handled by error branch.

8. Progress delegate line 129: guard `taskDescription` else return — if taskDescription lost (nil), progress silently dropped. Not a real defect.

9. `handle` default case line 83: `FlutterMethodNotImplemented` — fine.

10. init line 25: `delegateQueue: .main` — a static main queue; URLSession requires a queue, `.main` is a valid constant (DispatchQueue.main). Fine.

11. Line 36: destinationPath from Dart — path traversal? The Dart side controls it; native side writes wherever told. A malicious URL/destination from the app's own UI is not cross-tenant. Not a finding for this threat model.

12. Line 44: `(destinationPath as NSString).deletingLastPathComponent` — if destinationPath is a bare filename (no directory), deletingLastPathComponent returns "." → createDirectory at "." fine.

13. Line 103: `attributesOfItem` throws if file missing → `try?` → nil → size 0 → log "0 MB" and emit size 0. Minor.

14. Throttle map `lastProgressEmit` also never cleared on error path (line 177) — same leak finding, list both sites.

15. `channel.invokeMethod` from delegate on main queue — fine.

16. Line 148: `return` inside throttle — skips emit; correct.

17. One more: `urlSession(_:downloadTask:didFinishDownloadingTo:)` — after moveItem, URLSession expects you to consume/delete `location`; leaving the tmp file in place leaks the downloaded temp copy? Actually for download tasks, the system deletes the location after the delegate returns IF you used downloadTask (not background). For default-session download tasks, the file at location is cleaned up by URLSession after callback. Fine.

18. `activeDownloads` keyed by modelId only — two concurrent downloads for the same modelId (e.g., two destinations) collide: second startDownload cancels the first. That's the restart semantics; acceptable design.

19. `cancelDownload` for a modelId with no active task: result(true) anyway — harmless.

20. `startDownload` result(true) even though task.resume() may fail asynchronously — errors surface via onDownloadError. Fine.

21. Security: `NSLog` at 104/112/170 logs modelId and error — no sensitive URL logged. Fine.

22. `config.allowsCellularAccess = true` on macOS — meaningless but harmless.

23. `config` is `URLSessionConfiguration.default` — comment says background sessions not needed; fine for desktop.

24. `session` declared `URLSession!` — assigned in init; fine.

25. `channel.setMethodCallHandler(handle)` — retain cycle? channel holds handler closure capturing self; channel is held by self → cycle. Plugin lives for app lifetime; acceptable pattern in Flutter plugins. Not a finding.

26. `didFinishDownloadingTo` line 95: `guard ... else { return }` — if entry was removed (e.g., user cancelled just before completion), the downloaded file at `location` is dropped without being moved to destination — URLSession cleans it up; user gets no file and no error event (cancel path already signalled? cancelDownload doesn't emit any event). Consequence: cancelDownload produces NO onDownloadComplete/onDownloadError/onDownloadCancelled event — the Dart side never learns the download was cancelled unless it tracks it itself. Is that a defect? The channel emits only complete/error. A cancelled download leaves the UI hanging if Dart relies on events. But Dart initiated the cancel, so it knows. Not a finding.

27. `didCompleteWithError` for a task whose entry was removed (cancel path): early return at 168 for cancelled; fine.

28. Progress events after cancel: cancelled task stops emitting. Fine.

29. `lastProgressEmit` throttle: first event for a modelId — `last` nil → emits. Fine.

30. Line 132: `totalBytesExpectedToWrite > 0` — if unknown (-1), progress 0.0 emitted repeatedly? Throttle: progress 0.0 < 1.0, fraction diff 0 < 0.01, but time gate 0.3s limits to ~3/s. Minor noise; not a finding.

Now MainFlutterWindow.swift:

- Line 26-38: plugins created and stored as strong properties — comment says to outlive awakeFromNib. Fine.
- Line 33: registrar forPlugin — fine.
- No issues. Clean.

So final findings for BackgroundDownloadPlugin.swift:

1. [low] line 100-101 — `try? removeItem` swallows removal failure; moveItem then fails with misleading error and temp file leak. Reachability: authenticated user's own machine, retry recovers → low.
2. [low] lines 119,177 — `lastProgressEmit` entries never removed on completion/error → unbounded throttle-map growth in long desktop sessions. low.

Anything else? Let me reconsider severity of the leak: desktop app, modelId count bounded by distinct models downloaded; each entry ~small. low is right.

Is there anything at medium? Consider line 100-101 again: if destination file is locked (e.g., being read by the app), every re-download fails with "Failed to save file" — misleading but recoverable. low.

Consider: `didFinishDownloadingTo` — `info.destinationPath` used; but if entry removed between didFinish and move (cancelDownload on main queue — delegate also main queue, so no interleaving). Fine.

Consider `handle` being called on main thread and `session` delegate queue main — consistent.

One more: line 42 `tmpPath` = destinationPath + ".tmp" — URLSession's own temp file is unrelated; this removes a stale ".tmp" sibling that this code never creates (it never writes tmpPath). Dead code that could delete an unrelated user file ending in ".tmp" at that path. Hmm — it deletes `<destination>.tmp` which nothing in this file creates. If some other component stores a `.tmp` sibling there, it gets deleted on every startDownload. Speculative; the code implies an intended convention. I'll flag as info? It's exhibited: the file never creates tmpPath, so the removal targets a file this plugin doesn't manage. low/info. I'll include as info with the note that no code in the shown files creates that path (assumption: another component may).

Actually wait — maybe the iOS twin creates it. I can't see it. State assumption. info.

Also: `result(FlutterError(...))` for INVALID_ARGS — fine.

`args["url"] as? String` — no validation that URL is https/http; URL(string:) accepts file:// and ftp:// — downloadTask(with: fileURL) would fail; file:// URLs could read local files? downloadTask with file URL copies the file? URLSession downloadTask with a file:// URL does work and "downloads" (copies) the local file to the destination — meaning a compromised/malicious Dart side could copy arbitrary local files to an arbitrary destination. But the Dart side is the app itself, same trust domain. Not cross-tenant. Skip — or mention as info? The threat model: the app's own UI decides URLs. Not a finding.

Final check on the "TESTS THAT CANNOT FAIL" / checklist classes: GCP classes don't apply to these files. Fine.

Coverage lines: both files, in order.

Let me also double-check line numbers cited: 
- tmpPath removal: line 42.
- removeItem/moveItem: lines 100-101, catch 111-117.
- lastProgressEmit cleanup missing: line 119 (success) and 177 (error); also 148? no.
- Also line 149 sets entry; never removed anywhere. Confirmed.

One more possible: `didFinishDownloadingTo` — `size` uses `attributesOfItem(atPath:)` — actual API name is `attributesOfItem(atPath:)`. Real Foundation: `func attributesOfItem(atPath: String) throws -> [FileAttributeKey : Any]`. Yes.

`[.size] as? Int` — attribute value is NSNumber → Int cast ok via `as? Int`? `.size` value is Any; `as? Int` on NSNumber bridging works in Swift. Fine.

`NSLog` string interpolation of error — fine.

`channel.invokeMethod("onDownloadError", ...)` after move failure — Dart gets error; but the file WAS downloaded successfully (temp location valid) — the temp gets cleaned by URLSession; data lost. That's the misleading-error consequence already covered.

Also: on move failure, line 119 still removes the entry — so cancelDownload can't retry-move; fine.

Am I missing a medium? The restart path: line 56-58 — `existing.task?.cancel()` — but `existing` is a `let` copy of the struct value (DownloadInfo is a struct) — `existing.task?.cancel()` cancels the old task; fine.

What about `activeDownloads[modelId] = DownloadInfo(...)` at 61 while old task still mid-cancel — old task's didWriteData could still fire between 57 and the cancel taking effect, emitting progress under the same modelId with stale totals — transient, negligible. Skip.

`urlSession(_:task:didCompleteWithError:)` also fires for the download task after didFinish — with error nil — line 177 removes (already removed at 119). Harmless duplicate.

But note: if `didCompleteWithError(nil)` arrives for a task whose didFinish was NOT called (shouldn't happen for download tasks) — skip.

OK. Also consider: `guard let modelId = downloadTask.taskDescription` at 94 — `taskDescription` is `String?`; if nil → return → downloaded file dropped silently, no event. When could taskDescription be nil? It's set at 66 before resume. Fine.

Severity recap: two lows + one info. Any high? No. Any medium? The `.tmp` deletion of a file the plugin never creates could destroy user data if another component uses that convention — but I can't confirm; info with assumption stated.

Hmm, one more direction-of-failure: line 100 `try?` — already covered.

Line 103 `try?` for attributes → size 0 emitted to Dart on stat failure — progress "size: 0" — minor; fold into nothing.

Write the report.
- [medium] lib/data/services/voice_config_service.dart:36-39 — `_preferences` caches the SharedPreferences instance in `_prefs` but `getPreset`/`setPreset`/`getOverrides`/`_saveOverrides`/`getGenders`/`_saveGenders`/`getLocales`/`_saveLocales` all read/write through this shared instance without any locking on the non-serialized paths — consequence: two concurrent `setPreset` calls for different productions (or a `setPreset` racing a `getPreset`) can interleave at the `await SharedPreferences.getInstance()` boundary and the later `setString` write silently drops the earlier change, the exact whole-map read-modify-write race the `_mutationChains` comment at lines 21-26 warns about but which only guards the override/gender/locale mutators, not the preset or the raw `_saveOverrides` path reachable from `renameCharacter`'s non-serialized `_renameLoaded` at 325-349 — smallest safe fix: route every read-modify-write through `_serialized(productionId, ...)` (including `setPreset` and the three `_save*` helpers) or add a per-key mutex around `prefs.setString` for the preset key.
- [medium] lib/data/services/voice_config_service.dart:319-323 — `renameCharacter` wraps `_renameLoaded` in `_serialized(productionId, ...)` but `_renameLoaded` itself performs three independent whole-map read-modify-write cycles (overrides at 327-336, genders at 338-341, locales at 343-346) with `await getOverrides`/`await getGenders`/`await getLocales` between them — consequence: a concurrent `setGender` or `setLocale` for the same production that is queued behind the rename chain can still interleave with the rename's intermediate state because `_serialized` only serializes against other `_serialized` calls, and the rename's own three phases are not mutually serialized against the plain `getGenders`/`getLocales` readers used by `setGender`/`setLocale`'s inner closures, so a gender set between the rename's override phase and its gender phase can be overwritten by `_saveGenders` with a stale map — smallest safe fix: make `_renameLoaded` a single atomic transaction (read all three maps, mutate, write all three) inside one `_serialized` closure, or serialize the plain readers too.
- [medium] lib/data/services/voice_config_service.dart:184 — fallback `femaleVoices.isNotEmpty ? femaleVoices : maleVoices` for a character whose `gender` is not `male` (i.e. female or nonGendered) resolves to the male voice pool when the female pool is empty — consequence: a nonGendered or female character silently gets a male voice when no female voices are configured, which is the permissive-direction failure for a voice-assignment control (the doc comment at 122-127 promises adjacency-aware distinct voices, not gender-crossing fallback) and every test passes because the fallback never throws — smallest safe fix: return early (skip assignment) or log when the gender-appropriate pool is empty instead of silently borrowing the opposite pool.
- [low] lib/data/services/voice_config_service.dart:220 — `_leastUsedVoice` uses `counts.entries.reduce((a, b) => a.value <= b.value ? a : b).key` which on ties always returns the *first* entry in insertion order of `pool` — consequence: deterministic but biased tie-breaking means the least-used fallback always re-picks the same voice (e.g. the first pool entry) whenever usage counts tie, concentrating voice reuse across non-adjacent characters; not a crash, but it defeats the "minimize collisions" intent stated at 126-127 — smallest safe fix: break ties by preferring the voice with the fewest assignments among *neighbors* or shuffle the pool before counting.
- [low] lib/data/services/voice_config_service.dart:374 — `resolveVoice` hardcodes `'af_heart'` as the ultimate fallback voice ID — consequence: if a preset has empty female and male pools and the character has no override, every character resolves to the same hardcoded voice regardless of locale or gender, silently producing identical voices for all speakers; a guard exists (`voices.isEmpty` check) but the fallback value is a magic constant not derived from any configured pool — smallest safe fix: derive the fallback from `VoicePresets` defaults or return a sentinel that callers can surface, rather than a literal string.
- [info] lib/data/services/voice_config_service.dart:50,60,70,117,229,262,271,307 — all persistence keys (`voice_preset_<id>`, `voice_overrides_<id>`, `character_genders_<id>`, `character_locales_<id>`) are namespaced only by `productionId` with no user/tenant scoping in the key itself — consequence: if `productionId` values can collide across accounts (assumption: the caller supplies production IDs from a shared namespace rather than a per-user one), one account's preset/override/gender/locale map could be read by another; the inlined code shows no tenant prefix, so this is only a suspicion about the caller's ID space, not a confirmed cross-tenant bug — smallest safe fix: verify the production-ID namespace is per-user, or prefix keys with the authenticated user ID.
- [info] lib/data/services/voice_config_service.dart:1-388 — no secrets, keys, tokens, or credential material appear in this file; nothing to verify as committed.

## Coverage
lib/data/services/voice_config_service.dart — findings: 6

## Run stats

input 863663 tok (+154672 cached), output 131099 tok — sync requests, discounted — 100 files in 121m (49.4 files/h, 2.2 min/batch)
