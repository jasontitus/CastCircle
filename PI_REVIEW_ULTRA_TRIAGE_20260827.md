# CastCircle Ultra Review Triage — 2026-08-27

> Exhaustive source triage of all 2,839 candidate findings in `PI_REVIEW_ULTRA_20260827.md`.

## Executive summary

| Decision | Candidate findings | Root-cause groups |
|---|---:|---:|
| Verified | 1,581 | 478 |
| Refuted | 1,146 | 517 |
| Unverified | 112 | 44 |
| **Total** | **2,839** | **1,039** |

### Verified severity

| Severity | Candidate findings | Root-cause groups |
|---|---:|---:|
| Critical | 0 | 0 |
| High | 69 | 18 |
| Medium | 611 | 144 |
| Low | 828 | 287 |
| Info | 73 | 29 |

**No critical finding survived triage.** The verified set contains 69 high-severity candidate reports, consolidated into source-level root-cause groups below.

## Method and accounting

- The raw DeepSeek/GLM findings were treated as hypotheses, assigned stable `CC-NNNN` IDs in raw-report order, and partitioned by source file so duplicate claims stayed together.
- Each group was checked against the current implementation, callers, guards, configuration, and later migrations. A claim was refuted when the cited code was absent, language/API semantics were wrong, a later migration fixed it, or the stated trigger was unreachable.
- `verified` means current source supports a concrete failure scenario. `unverified` means deciding requires runtime, device, service, or external dependency evidence unavailable from source.
- Every candidate ID appears exactly once in a **Candidates** field: 2,839 accounted, 0 missing, 0 duplicated.
- The original raw report remains unchanged. Candidate IDs follow its finding order, and provenance below preserves the original lens/model tags.
- Anthropic triage was not routed through DeepInfra. No first-party Anthropic provider was configured, so triage used the harness's internal review agents instead.

## Verified findings

### V-001 · HIGH · Cast members can move their own membership into another production

- **Candidates:** CC-2477, CC-2480
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260703140000_security_lockdown.sql:122 — self/invitation UPDATE policy remains active
  - supabase/migrations/20260703140000_security_lockdown.sql:125 — USING accepts the caller's current row
  - supabase/migrations/20260703140000_security_lockdown.sql:126 — WITH CHECK constrains only user_id, not production_id
  - supabase/migrations/20260703140000_security_lockdown.sql:199 — is_production_member trusts any cast_members row in the target production
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:167 — the later role fix changes INSERT only, not this UPDATE
- **Decision:** A signed-in member who learns another production UUID can update their own row's production_id and immediately satisfy all member-read RLS without its join code.
- **Recommendation:** Remove direct self-update or enforce immutable production_id/role in a trigger and use narrow claim/update RPCs.

### V-002 · HIGH · Cast UPDATE policy still permits self-promotion

- **Candidates:** CC-2536
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260703140000_security_lockdown.sql:122 — current update policy applies to a user’s own row or any unclaimed row
  - supabase/migrations/20260703140000_security_lockdown.sql:126 — WITH CHECK constrains only user_id, not role
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:167 — later migration fixes role only for INSERT and leaves UPDATE policy unchanged
- **Decision:** An actor can directly update their own cast row to role=organizer; client logic trusts that role even if some server policies use production.organizer_id.
- **Recommendation:** Replace UPDATE policy with role-preserving/organizer-authorized checks and restrict claiming to safe roles.

### V-003 · HIGH · Deleting an ensemble member deletes co-speakers’ line

- **Candidates:** CC-1690, CC-1691, CC-1692
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/character_manager_screen.dart:704 — delete filters entire ScriptLine objects
  - lib/features/script_editor/character_manager_screen.dart:708 — any multiCharacters membership causes the whole line to be removed
  - lib/features/script_editor/character_manager_screen.dart:713 — the destructive result is immediately rebuilt and scheduled for save
- **Decision:** Deleting a one-line ensemble role silently removes the shared dialogue for every other speaker and the confirmation undercounts collateral loss.
- **Recommendation:** Remove only the target from multiCharacters; keep/rewrite the line while other speakers remain.

### V-004 · HIGH · Direct cast insert bypasses join-code verification

- **Candidates:** CC-2534, CC-2537, CC-2538
- **Provenance:** `db-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:173 — current direct INSERT policy remains enabled
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:176 — it checks only caller=user_id and low role
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:131 — the RPC’s join-code check is therefore bypassable through PostgREST
- **Decision:** Any authenticated caller who obtains a production UUID can self-insert as actor/understudy and become a member without the required code, unlocking membership-based reads/actions.
- **Recommendation:** Remove direct self-insert or require an unforgeable server-side authorization; force all joins through the verified RPC.

### V-005 · HIGH · Direct cast membership insert still permits self-joining a known production UUID

- **Candidates:** CC-2726, CC-2727
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tool/orphan_sweep.dart:41 — tool inserts membership directly without join code
  - tool/orphan_sweep.dart:44 — arbitrary listed production id is supplied
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:173 — latest insert policy is recreated
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:176 — check validates only own user id and actor/understudy role
- **Decision:** Any authenticated user who learns a production UUID can insert themselves as actor/understudy without presenting the join code, then satisfy member read policies.
- **Recommendation:** Revoke direct client INSERT and require the code-validating SECURITY DEFINER join RPC, retaining organizer invitation flows separately.

### V-006 · HIGH · Direct membership policy still permits self-joining any known production UUID

- **Candidates:** CC-2691, CC-2692, CC-2693
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - tool/analyze_orphaned_recordings.dart:40-50 — a new account inserts itself as understudy using only production_id
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:167-176 — latest policy checks only own user_id and actor/understudy role, not a join code
  - tool/analyze_orphaned_recordings.dart:22-24 — at least one real production UUID is committed publicly
- **Decision:** Later v3 RPCs validate join codes, but the latest direct-table INSERT policy bypasses them. Any authenticated user who obtains a production UUID can mint membership, after which membership-based RLS grants script/recording access.
- **Recommendation:** Remove direct self-membership INSERT for clients, or require an unforgeable server-side invitation/code proof and route all joins through the validated RPC.

### V-007 · HIGH · Downloaded Kokoro weight schema errors trap instead of throwing

- **Candidates:** CC-0398, CC-0399, CC-0400, CC-0432
- **Provenance:** `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroVendored/TTSEngine/WeightLoader.swift:36 — downloaded arrays are loaded and sanitized without validating required keys
  - ios/Runner/KokoroVendored/Albert/AlbertEmbeddings.swift:15 — required keys are force-unwrapped
  - ios/Runner/KokoroVendored/Decoder/Decoder.swift:37 — decoder keys are also force-unwrapped
  - ios/Runner/KokoroMLXService.swift:113 — recovery is a do/catch that cannot catch Swift traps
- **Decision:** A parseable but key-incomplete or shape-incompatible downloaded safetensors file can terminate the app and bypass deletion/redownload recovery.
- **Recommendation:** Validate the complete required-key/shape manifest before construction and throw KokoroError.modelCorrupt.

### V-008 · HIGH · iOS line listening reuses the previous match score

- **Candidates:** CC-1628, CC-1629
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:2231 — new iOS attempt starts
  - lib/features/rehearsal/rehearsal_screen.dart:2232 — confirmation is reset
  - lib/features/rehearsal/rehearsal_screen.dart:2239 — mic level is reset, but match score is not
  - lib/features/rehearsal/rehearsal_screen.dart:2284 — silence confirmation reads the stale score
  - lib/features/rehearsal/rehearsal_screen.dart:2897 — Android explicitly resets the score
- **Decision:** A prior above-threshold score can satisfy the next line’s silence endpoint before the actor speaks, silently advancing and misrecording the line.
- **Recommendation:** Reset _matchScore and feedback at the start of every platform’s per-line listening session.

### V-009 · HIGH · Manual exits discard captured actor audio without registering it

- **Candidates:** CC-1634
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:2630 — advance detects active capture
  - lib/features/rehearsal/rehearsal_screen.dart:2631 — it calls raw stopRecording fire-and-forget
  - lib/features/rehearsal/rehearsal_screen.dart:3071 — _stopCaptureForLine is the path that registers valid files
  - lib/features/rehearsal/rehearsal_screen.dart:3097 — registration into _capturedAudio occurs only there
- **Decision:** Manual skip/advance finalizes the recorder without reading its result, so the take is absent from the save offer and can remain orphaned.
- **Recommendation:** Use one awaited capture-finalization helper on every actor-line exit and explicitly decide save versus discard.

### V-010 · HIGH · Opt-in tests mutate production and publish a live join code

- **Candidates:** CC-2609, CC-2610, CC-2611, CC-2612, CC-2615, CC-2625, CC-2626, CC-2627, CC-2628
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `testing-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - test/supabase_join_test.dart:11 — source declares the target LIVE production Supabase
  - test/supabase_join_test.dart:30 — every opted-in run signs up an account
  - test/supabase_join_test.dart:38 — throwaway users are not torn down
  - test/supabase_join_test.dart:54 — committed test names live join code DHT6XT
  - test/supabase_join_test.dart:71 — it depends on a mutable Macbeth row
- **Decision:** Repository readers obtain a valid production join code, while opted-in runs pollute production auth and depend on mutable live tenant data.
- **Recommendation:** Move the suite to an isolated test project with seeded/teardown fixtures and rotate the exposed production join code.

### V-011 · HIGH · Pause, jump-back, and restart leave line capture active

- **Candidates:** CC-1636, CC-1637, CC-1638, CC-1639
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:2667 — jump-back teardown begins
  - lib/features/rehearsal/rehearsal_screen.dart:2672 — it stops recognition but not recording
  - lib/features/rehearsal/rehearsal_screen.dart:2698 — restart has the same gap
  - lib/features/rehearsal/rehearsal_screen.dart:2764 — manual pause also only stops recognition
  - lib/features/rehearsal/rehearsal_screen.dart:2741 — interruption pause demonstrates the missing recorder teardown
- **Decision:** The recorder and _isCapturingAudio survive common user exits, so resume/new-line startup can overlap capture or attribute a cross-line take incorrectly.
- **Recommendation:** Centralize cancellation/finalization of timers, recognizer, recorder, TTS, and player and use it from every transition.

### V-012 · HIGH · Pre-roll continuation can play an obsolete line

- **Candidates:** CC-1625
- **Provenance:** `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:1986 — _playOtherLine captures a line argument
  - lib/features/rehearsal/rehearsal_screen.dart:1993 — first call waits up to pre-roll completion
  - lib/features/rehearsal/rehearsal_screen.dart:1995 — continuation checks only global state
  - lib/features/rehearsal/rehearsal_screen.dart:2002 — it proceeds with the originally captured line
- **Decision:** Skipping during pre-roll can start a second playingOther operation; the first resumes while the state is again playingOther and plays stale audio, causing overlap and wrong advancement.
- **Recommendation:** Capture current line index/id and generation token and revalidate both after pre-roll and later awaits.

### V-013 · HIGH · ScriptParser leaks cast and cue state across imports

- **Candidates:** CC-1048, CC-1049, CC-1050, CC-1051, CC-1053, CC-1055, CC-1056, CC-1057, CC-1058, CC-1059, CC-1060
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/script_parser.dart:32 — knownCharacters is mutable instance state
  - lib/data/services/script_parser.dart:35 — characterAliases is mutable instance state
  - lib/data/services/script_parser.dart:39 — multiCharacterMap is mutable instance state
  - lib/data/services/script_parser.dart:117 — parse starts without clearing those collections
  - lib/data/services/script_parser.dart:1178 — cue cache invalidates only by count and format
  - lib/data/services/script_import_service.dart:28 — ScriptImportService retains one parser instance
- **Decision:** A second import in the same service inherits names, aliases, and possibly equal-sized stale cue regexes from the first script, causing silent speaker misattribution.
- **Recommendation:** Clear all per-parse state and invalidate cue patterns at parse entry, or instantiate a parser per import.

### V-014 · HIGH · SECURITY DEFINER join RPCs retain PUBLIC execute

- **Candidates:** CC-2515, CC-2516, CC-2517, CC-2518, CC-2522
- **Provenance:** `db-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:81 — only anon is revoked for lookup, not PUBLIC
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:113 — fetch is granted authenticated without revoking PUBLIC
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:143 — join likewise retains default PUBLIC execute
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:165 — claim likewise retains PUBLIC execute
- **Decision:** Postgres functions default to PUBLIC execute. Anonymous callers can invoke fetch with a code and join with auth.uid() null through definer privileges, defeating the intended account gate.
- **Recommendation:** Revoke execute from PUBLIC and anon for every helper/RPC, then grant only the intended roles; also reject null auth.uid() inside each function.

### V-015 · HIGH · Sign-out leaves the previous account’s production data in memory

- **Candidates:** CC-1991, CC-1995
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/settings/settings_screen.dart:353 — sign-out resets only auth state
  - lib/features/settings/settings_screen.dart:355 — auth gate is the only other reset
  - lib/providers/production_providers.dart:58 — production list provider is app-lifetime state
  - lib/providers/production_providers.dart:110 — current production is separate app-lifetime state
  - lib/providers/production_providers.dart:113 — current script is separate app-lifetime state
  - lib/providers/production_providers.dart:146 — recordings state also persists until explicitly cleared
- **Decision:** A second user in the same process can inherit the prior account’s production/script/recording/cast state, exposing cross-account content and enabling actions against stale context.
- **Recommendation:** Before clearing auth/navigating, reset every user- and production-scoped provider and subscriptions in one sign-out coordinator.

### V-016 · HIGH · Stale persisted-script loads can overwrite another production state

- **Candidates:** CC-1453, CC-1455, CC-1466, CC-1467, CC-1468, CC-1469
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/home/home_screen.dart:229 — openProduction awaits a production-scoped load
  - lib/features/home/home_screen.dart:240 — it writes shared currentScript without rechecking current production
  - lib/features/home/home_screen.dart:450 — ensureScriptLoaded repeats the unguarded await/write
- **Decision:** Rapid taps can run loads for productions A and B concurrently; the slower A completion can replace B’s shared script, and later edits can persist/push content under the wrong current production.
- **Recommendation:** After every await, verify currentProductionProvider still matches; centralize activation behind a generation token.

### V-017 · HIGH · Three join-code verification RPCs bypass rate limiting

- **Candidates:** CC-2504, CC-2505, CC-2506, CC-2507, CC-2523, CC-2524
- **Provenance:** `db-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `sql-migration-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:70 — only lookup calls check_join_rate_limit
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:95 — fetch_cast_for_join checks code without rate limiting
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:131 — join_production checks code without rate limiting
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:154 — claim path also checks code without rate limiting
- **Decision:** A caller with a production/member id can use success/error behavior as an unthrottled online code oracle, bypassing the migration’s brute-force control.
- **Recommendation:** Centralize code verification in one rate-limited function and call it from every pre-membership RPC.

### V-018 · HIGH · Tool demonstrates join-code bypass through direct membership insert

- **Candidates:** CC-2768, CC-2769, CC-2770, CC-2774
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tool/verify_cloud_recordings.dart:18-20 — joinCode is parsed and printed.
  - tool/verify_cloud_recordings.dart:38-46 — membership is created by direct cast_members insert without using the code.
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:172-176 — the latest direct insert policy still allows any authenticated user to insert their own actor/understudy membership without verifying a join code.
- **Decision:** Any authenticated user who learns a production UUID can bypass the hardened RPC and self-join, then gain script/recording access through membership-based RLS.
- **Recommendation:** Remove direct self-insert or require a server-validated join grant; permit membership creation only through the code-checking RPC.

### V-019 · MEDIUM · Android capture reuses a deterministic file without deleting stale audio

- **Candidates:** CC-1646, CC-1647, CC-1648
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:3003 — Android builds the deterministic per-line path
  - lib/features/rehearsal/rehearsal_screen.dart:3007 — it starts capture without removing an old file
  - lib/features/rehearsal/rehearsal_screen.dart:3035 — iOS builds the same deterministic shape
  - lib/features/rehearsal/rehearsal_screen.dart:3039 — iOS explicitly removes stale content first
- **Decision:** A failed/empty Android capture can leave a prior session’s plausible audio at the current take path.
- **Recommendation:** Delete the stale Android path before starting capture, preferably via a shared file-preparation helper.

### V-020 · MEDIUM · Android Kokoro teardown kills before native free

- **Candidates:** CC-0708
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/kokoro_onnx_service.dart:327-336 — stop sends dispose and immediately kills the isolate before its next event.
  - lib/data/services/kokoro_onnx_service.dart:416-421 — tts.free runs only when the dispose message is processed.
- **Decision:** The normal stop path prevents deterministic native model cleanup, retaining large native allocations across stop/restart cycles.
- **Recommendation:** Add a teardown acknowledgement after tts.free and kill only after acknowledgement or timeout.

### V-021 · MEDIUM · Android record-only silence marks an unspoken line completed

- **Candidates:** CC-1633
- **Provenance:** `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:2966 — no-live-matching branch bypasses score threshold
  - lib/features/rehearsal/rehearsal_screen.dart:2976 — silence calls _confirmLineMatch
  - lib/features/rehearsal/rehearsal_screen.dart:2562 — _confirmLineMatch always records skipped false
- **Decision:** In a quiet record-only session, silence alone can record bestScore zero as completed, inflating history completion counts.
- **Recommendation:** Pass the actual completion reason/skipped state into confirmation or record low-score silence as skipped.

### V-022 · MEDIUM · Android record-only start retains the previous line-ending flag

- **Candidates:** CC-1643
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:2894 — Android per-line reset starts
  - lib/features/rehearsal/rehearsal_screen.dart:2897 — score is reset
  - lib/features/rehearsal/rehearsal_screen.dart:2901 — lineEndingHeard is not reset
  - lib/features/rehearsal/rehearsal_screen.dart:2969 — silence duration depends on the retained flag
- **Decision:** A prior line’s heard ending can select the shorter endpointing tier for the next line and cut a paraphrased/partial line off early.
- **Recommendation:** Reset _lineEndingHeard alongside all other per-line matching state.

### V-023 · MEDIUM · Any production member can overwrite another member’s recording object

- **Candidates:** CC-2468, CC-2469, CC-2470, CC-2471, CC-2473, CC-2474
- **Provenance:** `db-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260703140000_security_lockdown.sql:73 — Members update recording objects is the final UPDATE policy
  - supabase/migrations/20260703140000_security_lockdown.sql:75 — USING checks bucket and production membership only
  - supabase/migrations/20260703140000_security_lockdown.sql:78 — no owner_id or uploader/path ownership condition is present
  - lib/data/services/supabase_service.dart:595 — clients upload directly to the recordings bucket
- **Decision:** A cast member who targets a known object key within their production satisfies the policy regardless of who uploaded it and can replace a castmate's take.
- **Recommendation:** Require storage owner_id = auth.uid() for member updates, with a separate organizer policy if organizer replacement is intended.

### V-024 · MEDIUM · Asynchronous recorder release loses the mic-handoff handle

- **Candidates:** CC-0055, CC-0056, CC-0063, CC-0064, CC-0065
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `kotlin-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:430 — stop clears captureThread before background finalization
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:475 — async release also clears the shared thread handle before join completes
- **Decision:** A quick subsequent start cannot wait for or detect the old thread and can open a second AudioRecord while the first still owns/finalizes the mic.
- **Recommendation:** Keep an old-release future/thread handle and await or fail-fast on mic handoff before opening the new recorder.

### V-025 · MEDIUM · audioFile is read outside the queue that owns it

- **Candidates:** CC-0281, CC-0282, CC-0283, CC-0284, CC-0285, CC-0286, CC-0289, CC-0290, CC-0291, CC-0292, CC-0293, CC-0294, CC-0295
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/AppleSttPlugin.swift:27 — the documented invariant says all audioFile access is serialized
  - ios/Runner/AppleSttPlugin.swift:303 — the render thread reads audioFile directly
  - ios/Runner/AppleSttPlugin.swift:395 — start writes it on audioFileQueue
  - ios/Runner/AppleSttPlugin.swift:409 — stop also reads it off-queue before the queued nil at line 420
- **Decision:** The strong Optional is accessed concurrently by the render, main, and file queues; Swift does not make such property races safe. The inner queued recheck prevents many stale writes but not the raced reads themselves.
- **Recommendation:** Keep the predicate and file reference queue-confined or guard them with a lock/atomic state.

### V-026 · MEDIUM · Bare all-caps lines become characters without the documented lookahead

- **Candidates:** CC-1074, CC-1075
- **Provenance:** `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/script_parser.dart:501 — comment requires a following dialogue-looking line
  - lib/data/services/script_parser.dart:505 — regex accepts any 2–30 character all-caps line
  - lib/data/services/script_parser.dart:509 — loop does not inspect the following line
  - lib/data/services/script_parser.dart:513 — every non-fixed-header match is added as a character
- **Decision:** Directives or shouted all-caps text in name-on-own-line scripts can become phantom speakers and then cue patterns.
- **Recommendation:** Implement the documented next-line dialogue lookahead before adding the candidate.

### V-027 · MEDIUM · Bulk invitations serialize one network round trip per character

- **Candidates:** CC-1354, CC-1356, CC-1357, CC-1358, CC-1359, CC-1364
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:272 — a serial loop handles all filled characters
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:283 — each iteration awaits createCastInvitation
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:310 — each iteration then awaits a local save
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:318 — the UI remains in the saving state for the whole loop
- **Decision:** A realistic full cast of dozens of characters incurs N serial HTTPS latencies and provider writes, producing multi-second to tens-of-seconds saves on mobile networks.
- **Recommendation:** Use a bounded-concurrency cloud batch and batch/local transaction while preserving per-character errors.

### V-028 · MEDIUM · Bulk save does not revalidate a character against current cast state

- **Candidates:** CC-1351
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:73 — the UI watches castMembersProvider and filters assigned characters
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:272 — save instead iterates the historical controller map
  - lib/features/cast_manager/cast_manager_screen.dart:103 — cloud synchronization can update cast members asynchronously
- **Decision:** A cloud sync that completes after the form was populated but before its entry is saved can add a primary actor; the stale controller is still inserted as another primary row because no uniqueness constraint or save-time check exists.
- **Recommendation:** Snapshot/recheck current unassigned character-role keys immediately before each insert.

### V-029 · MEDIUM · Bulk save exceptions leave the saving state latched

- **Candidates:** CC-1368, CC-1369, CC-1373, CC-1376
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:310 — local provider save is awaited without a catch
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:318 — _saving is set true
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:319 — _saveCastAssignments is awaited without try/finally
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:320 — reset runs only on normal completion
- **Decision:** A database/provider exception escapes the callback, skips the reset and leaves both Save controls disabled for the lifetime of the screen.
- **Recommendation:** Wrap the operation in try/catch/finally, reset if mounted, and show a user-visible failure.

### V-030 · MEDIUM · Cast contact information is dropped by local persistence

- **Candidates:** CC-0789, CC-0790, CC-0791, CC-0792
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/models/cast_member_model.dart:29 — contactInfo is part of the domain model
  - lib/data/database/app_database.dart:91 — CastMembers has no contactInfo column
  - lib/data/repositories/production_repository.dart:84 — saveCastMember omits contactInfo
  - lib/data/repositories/production_repository.dart:101 — the load conversion cannot restore it
- **Decision:** Organizer-entered phone/email values disappear after the local save/load round trip even though current cast flows populate the field.
- **Recommendation:** Add a nullable Drift column and migration, and persist/restore contactInfo.

### V-031 · MEDIUM · Cast gender controls ignore persisted overrides

- **Candidates:** CC-1400
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/cast_manager/cast_manager_screen.dart:159 — saved gender overrides are loaded
  - lib/features/cast_manager/cast_manager_screen.dart:479 — icon renders char.gender rather than effective override
  - lib/features/cast_manager/cast_manager_screen.dart:485 — toggle starts from the stale base value
- **Decision:** A saved override can drive rehearsal voice assignment while the cast screen shows and cycles a different gender, then overwrites it.
- **Recommendation:** Compute one effective gender from override ?? base for rendering and toggling.

### V-032 · MEDIUM · Cast sync deletes local rows by non-unique character/role key

- **Candidates:** CC-1395
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/cast_manager/cast_manager_screen.dart:134 — cloud rows are reduced to character/role keys
  - lib/features/cast_manager/cast_manager_screen.dart:139 — every non-cloud local row is scanned
  - lib/features/cast_manager/cast_manager_screen.dart:144 — any matching key causes deletion regardless of identity
- **Decision:** A legitimate local-only invite or duplicate understudy sharing a character/role with any cloud row can be silently removed.
- **Recommendation:** Deduplicate only rows with explicit cloud identity/linkage or exact proven duplicate ids.

### V-033 · MEDIUM · CGContext retains an unpinned Swift Array buffer

- **Candidates:** CC-0688, CC-0689, CC-0690, CC-0691
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/PaddleOcrPlugin.swift:390 — allocates pixels as a Swift Array
  - ios/Runner/PaddleOcrPlugin.swift:392 — passes &buf to a CGContext that outlives the initializer call
  - ios/Runner/PaddleOcrPlugin.swift:395 — uses the context after that pointer conversion ends
- **Decision:** Swift only guarantees the inout-to-pointer conversion for the call; CGContext retains the pointer for the later draw, so every OCR tensor conversion relies on unsupported lifetime behavior.
- **Recommendation:** Wrap context creation, draw, and reads in withUnsafeMutableBytes or allocate explicitly managed raw storage.

### V-034 · MEDIUM · Character and cue exports omit songs

- **Candidates:** CC-1001, CC-1002, CC-1003
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/script_export.dart:194 — character line count includes dialogue only
  - lib/data/services/script_export.dart:213 — character output handles dialogue only
  - lib/data/services/script_export.dart:243 — cue input filters to dialogue only
  - lib/data/services/script_export.dart:175 — markdown demonstrates songs are first-class lines elsewhere
- **Decision:** Actors in musicals receive incomplete personal/cue exports and incorrect totals.
- **Recommendation:** Include song lines anywhere character dialogue is selected and preserve their marker.

### V-035 · MEDIUM · Cloud-sync toolbar can report success after failure

- **Candidates:** CC-1737, CC-1738, CC-1739, CC-1740, CC-1741, CC-1778
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:185-195 — the button awaits persistScript and then always shows Script synced to cloud.
  - lib/providers/production_providers.dart:273-307 — local save may throw, while cloud push errors are caught and converted to a toast/normal return.
  - lib/features/script_editor/script_editor_screen.dart:1375-1390 — the explicit throwing push wrapper is unused.
- **Decision:** A cloud failure returns normally and is followed by a contradictory success toast; a local failure escapes the button without its own handling.
- **Recommendation:** Have the persistence API return a structured outcome and show success only when the requested cloud push succeeds.

### V-036 · MEDIUM · Common script imports parse on the UI isolate

- **Candidates:** CC-1016, CC-1017, CC-1018, CC-1019, CC-1021, CC-1022, CC-1023, CC-1024
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `metal-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `metal-performance-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/script_import_service.dart:37-56 — text and Markdown paths call ScriptParser.parse on the caller isolate.
  - lib/data/services/script_import_service.dart:118-149 — the PDFKit fast path parses and maps the full document on the caller isolate.
  - lib/data/services/script_import_service.dart:549-551 — only the OCR parse path is explicitly offloaded with Isolate.run.
- **Decision:** Large plays can block the import screen and frame pumping for seconds on the most common import paths.
- **Recommendation:** Offload parse and PDFKit mapping to an isolate using plain transferable data.

### V-037 · MEDIUM · Comparison tool unconditionally reports parser compatibility

- **Candidates:** CC-2172, CC-2173, CC-2174, CC-2175, CC-2176, CC-2177
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `python-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/compare_macbeth_versions.py:133 — format success is hardcoded
  - scripts/compare_macbeth_versions.py:144 — final compatibility success is unconditional
  - scripts/compare_macbeth_versions.py:145 — function always returns zero
- **Decision:** Even major converter regressions produce a green success statement and zero exit status, defeating the validation tool.
- **Recommendation:** Define explicit cue/overlap/dialogue thresholds, print failure details, and return nonzero when violated.

### V-038 · MEDIUM · Concurrent Live ASR start can report ready before model initialization

- **Candidates:** CC-0846
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/live_asr_service.dart:48-50 — any non-null _toIsolate makes ensureStarted return true
  - lib/data/services/live_asr_service.dart:93-100 — _toIsolate is assigned when the control port arrives, before the ready message
  - lib/data/services/live_asr_service.dart:167-193 — the isolate sends its port before constructing the recognizer
- **Decision:** A second caller during native model loading receives true prematurely and may attach audio before startup ultimately succeeds.
- **Recommendation:** Track an explicit ready state and make all concurrent callers share _starting until ready completes.

### V-039 · MEDIUM · Concurrent loadModel calls can load the MLX model twice

- **Candidates:** CC-0366
- **Provenance:** `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroMLXPlugin.swift:27 — every loadModel call creates an independent Task
  - ios/Runner/KokoroMLXService.swift:98 — readiness is checked before the asynchronous load without serialization
- **Decision:** Two overlapping method calls can both observe ttsEngine as nil and allocate/load the large model concurrently.
- **Recommendation:** Serialize model lifecycle operations or cache an in-flight load task.

### V-040 · MEDIUM · Confirmation-email quota is only two per hour

- **Candidates:** CC-2393, CC-2394, CC-2395
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/config.toml:182 — email_sent is 2 per hour
  - supabase/config.toml:212 — signup confirmation is mandatory
  - supabase/config.toml:234 — production SMTP is enabled
- **Decision:** More than two confirmation/reset/change emails in an hour can exhaust the configured quota and block legitimate account flows.
- **Recommendation:** Set a production-appropriate quota with abuse monitoring and retain per-address/IP resend controls.

### V-041 · MEDIUM · Contact picker never obtains phone or email permission

- **Candidates:** CC-0084
- **Provenance:** `android-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:98 — code acknowledges phone/email need READ_CONTACTS
  - android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:114 — SecurityException is swallowed for phone
  - android/app/src/main/AndroidManifest.xml:6 — READ_CONTACTS is declared but no runtime request exists in current sources
- **Decision:** The picked-row grant does not authorize the separate Phone/Email tables, so normal users receive name-only results despite contactInfo UI support.
- **Recommendation:** Request READ_CONTACTS at runtime before the extra queries, or deliberately remove the unsupported fields and manifest permission.

### V-042 · MEDIUM · Correction learning zips words without alignment

- **Candidates:** CC-1180
- **Provenance:** `gcp-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/stt_vocabulary_service.dart:220 — learning proceeds whenever word counts match
  - lib/data/services/stt_vocabulary_service.dart:225 — recognized and expected words are paired solely by index
  - lib/data/services/stt_vocabulary_service.dart:230 — short shifted pairs pass the edit-distance gate
- **Decision:** An insertion/deletion offset that preserves total word count can teach a cascade of wrong mappings, which are then globally applied to later partials.
- **Recommendation:** Align words first and learn only high-confidence one-to-one substitutions.

### V-043 · MEDIUM · Corrupt voice preferences are rewritten as empty maps

- **Candidates:** CC-1309, CC-1310, CC-1311, CC-1312, CC-1313, CC-1314, CC-1315, CC-1316
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/voice_config_service.dart:67-82 — any override decode/entry error returns an empty map.
  - lib/data/services/voice_config_service.dart:93-109 — the next override mutation persists that fallback map.
  - lib/data/services/voice_config_service.dart:225-245,269-280 — gender and locale stores use the same empty-map fallback.
- **Decision:** One malformed entry or truncated preference blob causes the next edit to erase all other settings in that family.
- **Recommendation:** Distinguish missing from corrupt storage; reject mutation or recover entries individually without overwriting the raw blob.

### V-044 · MEDIUM · Crashlog pull failures are hidden and stale logs can be reported

- **Candidates:** CC-2277, CC-2278, CC-2279, CC-2280, CC-2281, CC-2282, CC-2283, CC-2284
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `shell-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/pull-crashlog.sh:13-15 — a persistent shared /tmp directory is reused
  - scripts/pull-crashlog.sh:44-55 — idevicecrashreport stderr/status is discarded and the script then reports either existing files or no logs
- **Decision:** Tool absence, pairing/lock failure, or wrong UDID is presented as no crash—or can cause an old file to be labeled the most recent current crash.
- **Recommendation:** Use a per-run directory, preserve and check pull status/stderr, and only summarize files created by a successful current pull.

### V-045 · MEDIUM · Dart model downloads have no network timeout

- **Candidates:** CC-0885, CC-0886, CC-0887
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/model_download_service.dart:576-617 — fallback HttpClient connect, response, and stream awaits have no timeout
  - lib/data/services/model_manager.dart:288-293 — archive download likewise has no connection/request timeout
- **Decision:** A stalled socket can keep model state and setup flows awaiting indefinitely until process termination.
- **Recommendation:** Set connection timeout and bounded inactivity/request timeouts, close the client, remove staging files, and surface the existing error state on expiry.

### V-046 · MEDIUM · Deleting a character leaves cast and voice records orphaned

- **Candidates:** CC-1677, CC-1687, CC-1688, CC-1689
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/character_manager_screen.dart:703 — _applyDelete only filters script lines
  - lib/features/script_editor/character_manager_screen.dart:713 — it rebuilds/saves the script with no linked-data cleanup
  - lib/features/script_editor/character_manager_screen.dart:587 — rename, by contrast, migrates voice config
  - lib/features/script_editor/character_manager_screen.dart:588 — rename also migrates local/cloud cast rows
- **Decision:** Assigned actors and per-name voice/locale/gender data remain keyed to a role no longer in the script and can reappear through cloud sync.
- **Recommendation:** Prompt for/unassign affected cast rows and remove or migrate all per-character voice settings during delete.

### V-047 · MEDIUM · Deleting a recording row leaves its storage object readable

- **Candidates:** CC-2489, CC-2490, CC-2491, CC-2492, CC-2493
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260703170000_recordings_delete_policy.sql:1-12 — migration grants table-row deletion only
  - lib/features/recording_studio/recordings_browser_screen.dart:543-568 — client deliberately deletes only the recordings row and documents that it leaves the storage object
  - supabase/migrations/20260703140000_security_lockdown.sql:57-79 — recording object policies include member read/insert/update but no delete
- **Decision:** A deleted take’s blob remains stored and member-readable by path after its row is gone, creating privacy and storage-retention mismatch.
- **Recommendation:** Add uploader/organizer DELETE policy for recordings objects and delete the object before/with the row; backfill cleanup for rowless objects.

### V-048 · MEDIUM · Deleting Android Kokoro clears every downloaded model

- **Candidates:** CC-1901, CC-1903, CC-1904
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/settings/ai_models_screen.dart:109 — Kokoro Delete calls ModelManager.clearCache
  - lib/data/services/model_manager.dart:156 — documents clearCache as deleting all cached models
  - lib/data/services/model_manager.dart:161 — recursively deletes the shared models directory
  - lib/data/services/model_download_service.dart:716 — live ASR files live under that same models directory
- **Decision:** A user action labeled Kokoro model deleted also removes the live line-matching ASR group without warning, forcing an unrelated redownload.
- **Recommendation:** Add a Kokoro-ONNX-specific deletion method and leave sibling subdirectories intact.

### V-049 · MEDIUM · Disabled SQLite foreign keys permit orphaned recordings on script replacement

- **Candidates:** CC-0742, CC-0748, CC-0749
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/database/app_database.dart:32-93 — child tables declare references to productions and script lines
  - lib/data/database/app_database.dart:316-331 — connection setup enables WAL/synchronous/busy_timeout but not foreign_keys
  - lib/data/repositories/production_repository.dart:139-145 — saveScriptLines deletes and reinserts all lines without deleting recordings
- **Decision:** SQLite defaults foreign-key enforcement off, and the current script replacement path can leave recording rows pointing at removed line IDs.
- **Recommendation:** Enable PRAGMA foreign_keys=ON and define intentional cascade/restrict actions; migrate or clean existing orphans before enforcement.

### V-050 · MEDIUM · Done and back discard unsaved OCR TextField edits

- **Candidates:** CC-1800, CC-1801, CC-1802, CC-1803, CC-1804
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_import/ocr_review_screen.dart:448 — every exit funnels through _done
  - lib/features/script_import/ocr_review_screen.dart:454 — _done reads only _byId
  - lib/features/script_import/ocr_review_screen.dart:806 — card edits live only in a TextEditingController
  - lib/features/script_import/ocr_review_screen.dart:815 — the TextField has no onChanged synchronization
  - lib/features/script_import/ocr_review_screen.dart:866 — only explicit Save invokes _saveEdit
- **Decision:** Typing a correction and following the screen instruction to tap Done returns the original _byId text unless the separate Save/Looks right action was pressed, causing silent loss of user edits.
- **Recommendation:** Fold every live controller value into the result in _done or synchronize onChanged.

### V-051 · MEDIUM · downloadAll fetches Android ONNX Kokoro on iOS

- **Candidates:** CC-0898, CC-0899, CC-0900
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/model_manager.dart:136 — iOS readiness checks MLX Kokoro through ModelDownloadService
  - lib/data/services/model_manager.dart:147 — downloadAll unconditionally downloads the ONNX Kokoro archive
- **Decision:** On iOS the command downloads a large pack that does not satisfy the readiness gate or the MLX TTS path.
- **Recommendation:** Branch downloadAll by platform and use ModelDownloadService for iOS MLX assets.

### V-052 · MEDIUM · Empty speaker crashes the character dropdown

- **Candidates:** CC-1758, CC-1759, CC-1760, CC-1761
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:821-824 — an empty selectedChar sets isNewChar false.
  - lib/features/script_editor/script_editor_screen.dart:1026-1041 — DropdownButtonFormField receives the empty value although no item has that value.
- **Decision:** Opening an unattributed dialogue/song line violates the dropdown’s exactly-one-item invariant.
- **Recommendation:** Map empty/unknown speakers to the New character item or allow a dedicated unattributed item.

### V-053 · MEDIUM · English G2P mixes UTF-16 regex offsets with grapheme indexing

- **Candidates:** CC-0537, CC-0538, CC-0539, CC-0540, CC-0541, CC-0542, CC-0543, CC-0544, CC-0545, CC-0546
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/EnglishG2P.swift:147-157 — NSRegularExpression ranges from NSString are fed to Character-based String.index offsets
  - ios/Runner/MisakiVendored/English/EnglishG2P.swift:159-187 — those indices drive slicing and lastEnd
- **Decision:** Emoji or composed characters before markdown-style pronunciation markup make UTF-16 offsets diverge from grapheme offsets, producing wrong slices or an out-of-range trap on user text.
- **Recommendation:** Convert each match using Range(match.range, in: input) and use its String.Index bounds.

### V-054 · MEDIUM · English number conversion breaks 21 through 29

- **Candidates:** CC-0622, CC-0628, CC-0629, CC-0630
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/Num2Word/EnglishNum2Word.swift:16 — midNumWords omits 20
  - ios/Runner/MisakiVendored/English/Num2Word/EnglishNum2Word.swift:126 — the 21–29 tens lookup falls back to an empty string
- **Decision:** Values 21–29 render as -one through -nine, corrupting cardinal, ordinal, and TTS output. Exact 20 is handled by lowNumWords, but each candidate also identifies the real 21–29 failure.
- **Recommendation:** Add (20, "twenty") to the tens table and cover cardinal/ordinal examples.

### V-055 · MEDIUM · Failed Kokoro load is still marked ready

- **Candidates:** CC-1502, CC-1503
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/onboarding/model_setup_screen.dart:150 — tryLoadKokoro result is discarded
  - lib/features/onboarding/model_setup_screen.dart:151 — voices.ready is set true unconditionally
  - lib/data/services/tts_service.dart:128 — tryLoadKokoro explicitly returns false when neither engine loads
- **Decision:** Onboarding can report “All set” and exit while Kokoro is unavailable and rehearsal falls back.
- **Recommendation:** Gate ready on the returned boolean and surface/log a load error on false.

### V-056 · MEDIUM · Failed Kokoro startup strands requests queued during loading

- **Candidates:** CC-0810, CC-0811, CC-0812, CC-0813
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/kokoro_onnx_service.dart:75 — concurrent callers share _starting
  - lib/data/services/kokoro_onnx_service.dart:88 — missing model returns false without draining pending work
  - lib/data/services/kokoro_onnx_service.dart:108 — isolate-spawn failure also returns without draining
  - lib/data/services/kokoro_onnx_service.dart:206 — synthesize accepts requests while _starting is non-null
  - lib/data/services/kokoro_onnx_service.dart:236 — caller then awaits the request completer indefinitely
- **Decision:** A synth request can enter _queue while getKokoroPaths or isolate spawn is pending; either early return leaves no isolate, pump, or completer cleanup.
- **Recommendation:** Route every startup failure through one pending-request failure helper.

### V-057 · MEDIUM · Failed or guest cloud invitations are still saved and offered as dead links

- **Candidates:** CC-1361, CC-1362, CC-1367, CC-1380, CC-1381, CC-1382, CC-1383, CC-1384
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:281 — cloud creation is skipped entirely for signed-out guests
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:291 — signed-in cloud failures are caught
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:300 — both cases still create a local primary member
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:334 — failures only produce a transient toast
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:348 — the invite sheet is always opened
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:368 — it includes every filled controller, including failed entries
- **Decision:** Recipients can be sent links for rows that do not exist in Supabase; the local primary row then filters the character out of this form, so the toast's instruction to re-save is not actionable.
- **Recommendation:** Do not present/share failed links; retain a retryable pending-invite state or roll back the local assignment until cloud creation succeeds.

### V-058 · MEDIUM · Final schema permits duplicate production memberships

- **Candidates:** CC-2428, CC-2429, CC-2430, CC-2431, CC-2432, CC-2433, CC-2434
- **Provenance:** `db-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `db-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260315_cast_join_code.sql:16-20 — the production/user unique constraint is dropped
  - supabase/migrations/20260801130000_cast_members_rls_index.sql:10-11 — the later replacement is non-unique
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:115-143 — current join RPC inserts without dedupe/conflict handling
- **Decision:** Repeated join requests can create multiple rows for the same authenticated user and production, corrupting cast lists/counts and leave semantics.
- **Recommendation:** Add a partial unique index on (production_id,user_id) where user_id is not null, clean existing duplicates, and make join return the existing membership on conflict.

### V-059 · MEDIUM · Folger play-start detection is Macbeth-specific

- **Candidates:** CC-2233
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/pdf_to_script.py:166 — start requires literal ACT 1
  - scripts/pdf_to_script.py:170 — confirmation includes WITCH, DUNCAN, or MACBETH despite declared Hamlet support
- **Decision:** A supported non-Macbeth Folger PDF can miss the play boundary because it lacks those names or uses a different act numeral style.
- **Recommendation:** Detect generic act/scene layout and content rather than play-specific names.

### V-060 · MEDIUM · Guest-mode invite links point to no cloud production

- **Candidates:** CC-1403, CC-1412
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/cast_manager/cast_manager_screen.dart:774 — cloudInviteOk defaults true
  - lib/features/cast_manager/cast_manager_screen.dart:776 — cloud creation is skipped when signed out without flipping it false
  - lib/features/cast_manager/cast_manager_screen.dart:818 — the live invite share still runs
  - lib/features/cast_manager/cast_manager_screen.dart:872 — invite links depend only on a local joinCode
- **Decision:** Local productions still have locally generated codes, but no Supabase row can resolve them; guest-mode assignment/reminder paths therefore share dead deep links.
- **Recommendation:** Require signed-in cloud backing before constructing/sharing a join link; otherwise share linkless text or block invite.

### V-061 · MEDIUM · Highlight audit never asserts that highlighting works

- **Candidates:** CC-0228, CC-0234
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `testing-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/ocr_highlight_audit_macos_test.dart:67 — matcher outcomes are accumulated
  - integration_test/ocr_highlight_audit_macos_test.dart:113 — outcome totals are only printed
  - integration_test/ocr_highlight_audit_macos_test.dart:120 — the final assertion checks only that flagged lines exist
- **Decision:** If locate returns no matches for every line, byPage and flagged remain non-empty and the test still passes, directly defeating its stated contract.
- **Recommendation:** Assert an acceptable located fraction and an explicit bound on nowhere results.

### V-062 · MEDIUM · Image import decodes unbounded full-resolution bitmaps

- **Candidates:** CC-0120, CC-0121, CC-0122
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `kotlin-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:139-145 — BitmapFactory.decodeFile uses no bounds pass or inSampleSize
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:289-295 — detection immediately scales the decoded bitmap to at most 960 pixels on its long side
- **Decision:** A high-resolution user image incurs the full ARGB allocation before the pipeline’s useful downscale and can fail as a silent empty result.
- **Recommendation:** Decode bounds first and choose inSampleSize against a safe pixel budget near detLimitSide.

### V-063 · MEDIUM · Image OCR failures are returned as successful empty text

- **Candidates:** CC-0116, CC-0117, CC-0118, CC-0119
- **Provenance:** `android-review@deepinfra-zai-org-glm-5.3-flash`, `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:139-146 — decode failure and every Throwable become result.success with an empty block list
  - lib/data/services/script_import_service.dart:353-369 — fallback occurs only when Paddle is unavailable or throws
- **Decision:** A corrupt image, inference failure, or memory error is indistinguishable from a genuinely textless image, preventing the documented ML Kit fallback.
- **Recommendation:** Return a platform error for decode/inference failures; reserve an empty successful list for a completed OCR pass that found no text.

### V-064 · MEDIUM · Import acceptance mutates PDF and providers before persistence

- **Candidates:** CC-1873, CC-1874, CC-1875, CC-1876, CC-1877, CC-1878, CC-1879, CC-1881
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_import/script_import_screen.dart:568-592 — commit and currentScriptProvider mutation precede persistScript
  - lib/features/script_import/script_import_screen.dart:615-636 — commit atomically overwrites the prior production PDF and updates production providers
  - lib/features/script_import/script_import_screen.dart:584-592 — failure message claims the script was not added without rollback
- **Decision:** A persistence failure leaves new in-memory script/path state and irreversibly replaces the previous source PDF while telling the user nothing changed.
- **Recommendation:** Persist a staged transaction first and promote/update providers only after success, or retain and restore the old PDF/provider state on any failure.

### V-065 · MEDIUM · Invitation claim leaves cloud display name as director placeholder

- **Candidates:** CC-1484
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/join/join_production_screen.dart:484 — typed name is written to the local member
  - lib/data/services/supabase_service.dart:394 — fallback claim updates only user_id and joined_at
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:154 — RPC claim likewise updates only user_id/joined_at
- **Decision:** Other devices retain the invitation placeholder and can overwrite the joiner’s local display on cloud sync.
- **Recommendation:** Pass/update display_name as part of the claim RPC transaction.

### V-066 · MEDIUM · Invitation claim silently succeeds when no row changed

- **Candidates:** CC-2532
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:148 — claim_cast_invitation returns void
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:154 — update can match zero rows
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:163 — no row-count check or exception follows
- **Decision:** A raced/already-claimed id or wrong code returns successful RPC completion even though membership was not claimed, so the client can proceed on false state.
- **Recommendation:** Return the updated row/boolean or GET DIAGNOSTICS and raise when row_count is zero.

### V-067 · MEDIUM · Join reports failure after membership commit and is not idempotent

- **Candidates:** CC-1486, CC-1487, CC-1488
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/join/join_production_screen.dart:474 — invitation/self-join cloud mutation occurs first
  - lib/features/join/join_production_screen.dart:538 — local and post-join work can still throw
  - lib/features/join/join_production_screen.dart:580 — one catch reports every later failure as join failure
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:137 — self-join inserts without an existing-user uniqueness/idempotency check
- **Decision:** A local or script-sync failure after self-join leaves a real cloud row, but retry can insert another membership or trap on server policy while UI says the original join failed.
- **Recommendation:** Make the server RPC idempotent for production/user, and separate committed membership success from best-effort local/script synchronization.

### V-068 · MEDIUM · Join-code rate limiter has a concurrent check/insert race

- **Candidates:** CC-2498, CC-2501, CC-2502, CC-2503
- **Provenance:** `db-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `db-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:52 — recent attempts are counted first
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:54 — decision uses that non-locking snapshot
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:57 — attempt is inserted in a later statement
- **Decision:** Parallel requests can all observe fewer than 20 committed attempts and pass before inserting, exceeding the advertised cap.
- **Recommendation:** Serialize per user with an advisory lock or implement one atomic insert/check design.

### V-069 · MEDIUM · join_production is non-idempotent and permits duplicate memberships

- **Candidates:** CC-2526, CC-2527, CC-2529
- **Provenance:** `db-review@deepinfra-zai-org-glm-5.3-flash`, `sql-migration-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260315_cast_join_code.sql:20 — the original production/user unique constraint was dropped
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:137 — join_production performs an unconditional insert
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:139 — it always returns the new row
- **Decision:** Retries or repeated valid-code calls create multiple membership rows for the same user/production, corrupting roster/member assumptions.
- **Recommendation:** Restore an appropriate partial uniqueness invariant and return/upsert the existing membership idempotently.

### V-070 · MEDIUM · Kokoro load failure bool is ignored

- **Candidates:** CC-1894
- **Provenance:** `gcp-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/settings/ai_models_screen.dart:81 — awaits but ignores tryLoadKokoro result
  - lib/data/services/tts_service.dart:128 — returns false when no Kokoro engine loads
  - lib/features/settings/ai_models_screen.dart:87 — unconditionally sets _onnxReady true
- **Decision:** A successful file download followed by a false load result is shown and logged as ready even while TTS falls back to the system engine.
- **Recommendation:** Require a true load result before marking ready; show a load-specific error while retaining downloaded status.

### V-071 · MEDIUM · Kokoro model state is accessed across executors without isolation

- **Candidates:** CC-0370, CC-0376, CC-0377, CC-0378, CC-0379, CC-0380, CC-0381, CC-0382, CC-0383
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroMLXService.swift:33-48 — ttsEngine and voices are unguarded mutable properties
  - ios/Runner/KokoroMLXService.swift:97-125 — async load mutates both properties
  - ios/Runner/KokoroMLXService.swift:133-151 — unload/delete mutate and clear MLX state outside synthQueue
  - ios/Runner/KokoroMLXService.swift:157-166 — synthesize reads both before dispatching to synthQueue
- **Decision:** Concurrent load/unload/delete/synthesize calls can publish torn lifecycle state, double-load the model, or clear MLX resources while synthesis is active.
- **Recommendation:** Confine load, state snapshots, synthesis, unload, and delete to one actor/serial queue; cancellation generation should be part of that isolation.

### V-072 · MEDIUM · Kokoro readiness omits required lexicon and data directory

- **Candidates:** CC-0891, CC-0893, CC-0894, CC-0895, CC-0896, CC-0897
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/model_manager.dart:58 — readiness checks four files only
  - lib/data/services/model_manager.dart:81 — engine paths additionally require espeak-ng-data and lexicon-gb-en.txt
- **Decision:** A partial extraction can pass readiness and then fail native TTS startup because two returned resources were never checked.
- **Recommendation:** Validate every returned required file/directory, with minimum-size/content checks where appropriate.

### V-073 · MEDIUM · Kokoro stop kills the isolate before disposal can be acknowledged

- **Candidates:** CC-0829, CC-0831, CC-0832, CC-0833, CC-0834, CC-0835
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/kokoro_onnx_service.dart:331 — dispose is sent as a queued message
  - lib/data/services/kokoro_onnx_service.dart:333 — receive subscription is cancelled immediately
  - lib/data/services/kokoro_onnx_service.dart:335 — isolate is killed at beforeNextEvent
  - lib/data/services/kokoro_onnx_service.dart:419 — tts.free runs only if the dispose message is handled
- **Decision:** There is no acknowledgement or wait between sending dispose and killing the isolate, so explicit native cleanup is racy and commonly skipped across stop/start cycles.
- **Recommendation:** Have the isolate free resources and acknowledge completion before a bounded fallback kill.

### V-074 · MEDIUM · Late Supabase initialization strands persisted sessions behind the auth gate

- **Candidates:** CC-0710, CC-0711, CC-0712, CC-0713, CC-0714, CC-0715, CC-0716, CC-0717, CC-0721, CC-2054, CC-2055, CC-2056, CC-2057, CC-2058, CC-2059, CC-2060
- **Provenance:** `db-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `db-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `sql-migration-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/supabase_service.dart:37-60 — init returns after five seconds while initialization continues and flips _initialized only later
  - lib/main.dart:151-164 — persisted-session state is sampled once immediately after init returns
  - lib/app.dart:38-43,69-80 — authGatePassedProvider is a sticky snapshot and the router has no late-init refresh path
- **Decision:** A valid persisted session that restores after the five-second soft timeout is sampled as signed out; no late completion or auth-state listener promotes the gate, so the returning user remains on /auth until manual action.
- **Recommendation:** Drive the gate from a reactive initialization/auth-state signal and refresh router redirects when that state changes.

### V-075 · MEDIUM · Learned corrections replace substrings inside unrelated words

- **Candidates:** CC-1170, CC-1171, CC-1172, CC-1173, CC-1174, CC-1175, CC-1176, CC-1177, CC-1178, CC-1179
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/stt_vocabulary_service.dart:177 — cached patterns use only RegExp.escape(key)
  - lib/data/services/stt_vocabulary_service.dart:178 — patterns are case-insensitive but have no word boundaries
  - lib/data/services/stt_vocabulary_service.dart:225 — short word pairs can be learned positionally
  - lib/data/services/stt_vocabulary_service.dart:230 — any pair within edit distance three is accepted
- **Decision:** A realistic short learned pair such as an→and deterministically rewrites the same letters inside longer words on every later partial, corrupting match scores.
- **Recommendation:** Match complete tokens or add start/end word boundaries and reject implausibly short corrections.

### V-076 · MEDIUM · Legacy direct-table invitation-claim policy survives the lockdown

- **Candidates:** CC-2476
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260315_cast_join_code.sql:34 — policy Users can claim invitation permits updates of unclaimed rows
  - supabase/migrations/20260315_cast_join_code.sql:37 — its only new-row check is auth.uid() = user_id
  - supabase/migrations/20260703140000_security_lockdown.sql:121 — lockdown drops only the differently named Users can claim their invitation
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:145 — v3 secures the RPC but does not drop the old table policy
- **Decision:** An authenticated caller who knows an unclaimed cast-member UUID can still claim it directly without presenting the join code, bypassing the v3 RPC requirement.
- **Recommendation:** Drop the exact legacy policy and leave claiming exclusively to the code-validating SECURITY DEFINER RPC.

### V-077 · MEDIUM · Line navigation leaves an active recorder running

- **Candidates:** CC-1545, CC-1546, CC-1561, CC-1562, CC-1563
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/recording_studio/recording_studio_screen.dart:516-544 — Previous, Skip, and Next remain enabled while recording.
  - lib/features/recording_studio/recording_studio_screen.dart:759-770 — navigation changes line/status without stopping or registering the recorder.
  - lib/features/recording_studio/recording_studio_screen.dart:643-650 — stop snapshots the then-current line, not the line on which recording started.
- **Decision:** Tapping navigation mid-take can misattribute audio, lose the take, and leave the microphone locked.
- **Recommendation:** Disable navigation while recording or atomically stop/register the original line before changing index.

### V-078 · MEDIUM · Live ASR isolate death leaves stale running state with no exit signal

- **Candidates:** CC-0838, CC-0839, CC-0840, CC-0841, CC-0842, CC-0843, CC-0844, CC-0845
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/live_asr_service.dart:69-93 — the isolate is spawned without onExit/onError ports
  - lib/data/services/live_asr_service.dart:93-109 — receive listener has no lifecycle recovery
  - lib/data/services/live_asr_service.dart:43-50 — non-null _toIsolate permanently reports running and short-circuits restart
- **Decision:** After a post-ready isolate exit, no message clears the control port, so live matching cannot restart and continues reporting ready. A ReceivePort onDone alone would not detect child exit; an explicit exit listener is needed.
- **Recommendation:** Register onExit/onError ports, epoch-guard cleanup, clear state, log the failure, and allow ensureStarted to respawn.

### V-079 · MEDIUM · Live ASR isolate is killed before dispose cleanup can run

- **Candidates:** CC-2071
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/live_asr_service.dart:142 — dispose is sent asynchronously
  - lib/data/services/live_asr_service.dart:147 — isolate is immediately killed before its next event
  - lib/data/services/live_asr_service.dart:237 — native stream/recognizer free calls run only when dispose is processed
- **Decision:** Isolate.beforeNextEvent prevents the queued dispose command from executing, so repeated stop/restart can skip explicit native-handle cleanup.
- **Recommendation:** Have the isolate acknowledge disposal after freeing resources, then kill only on timeout.

### V-080 · MEDIUM · Live join tests silently substitute the anon key for failed signup

- **Candidates:** CC-2616, CC-2617, CC-2618, CC-2619, CC-2620, CC-2621, CC-2622, CC-2623
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `testing-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - test/supabase_join_test.dart:43 — signup response is decoded without status validation
  - test/supabase_join_test.dart:44 — missing access_token falls back to anonKey
  - test/supabase_join_test.dart:48 — later helpers call the token authenticated
- **Decision:** Signup/rate-limit failures cause tests labeled authenticated to exercise anon behavior, yielding misleading green or unrelated failures.
- **Recommendation:** Fail setUpAll with status/body when no access token is returned.

### V-081 · MEDIUM · Local cast persistence drops contact information

- **Candidates:** CC-0744
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/database/app_database.dart:90-103 — CastMembers has no contactInfo column
  - lib/data/repositories/production_repository.dart:84-111 — save/load mappings omit contactInfo
  - lib/data/models/cast_member_model.dart:28-40 — contactInfo is part of the application model
- **Decision:** Saving and reloading a local cast member silently loses invite email/phone data.
- **Recommendation:** Add a nullable column and schema migration, then map it in both repository directions; otherwise remove it from the local-persistence contract explicitly.

### V-082 · MEDIUM · Long out-of-vocabulary words can exceed BART position embeddings

- **Candidates:** CC-0572, CC-0573
- **Provenance:** `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MisakiVendored/Resources/us_bart_config.json:36 — max_position_embeddings is 64
  - ios/Runner/MisakiVendored/English/FallbackNetwork/EnglishFallbackNetwork.swift:45 — emits one token per unbounded word character plus BOS/EOS
  - ios/Runner/MisakiVendored/English/FallbackNetwork/BARTModel.swift:78 — slices positionIds through seqLen without a bound
- **Decision:** A pasted URL, identifier, or malformed OCR token longer than 62 characters can reach fallback G2P and request an out-of-range positional slice.
- **Recommendation:** Reject, split, or truncate fallback words before model.encode, with an explicit maxPositionEmbeddings check.

### V-083 · MEDIUM · macOS download callbacks are keyed only by reusable model ID

- **Candidates:** CC-2085, CC-2086, CC-2087, CC-2088, CC-2089, CC-2092, CC-2093, CC-2094, CC-2101
- **Provenance:** `db-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `sql-migration-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - macos/Runner/BackgroundDownloadPlugin.swift:56 — cancels an existing same-ID task
  - macos/Runner/BackgroundDownloadPlugin.swift:61 — immediately overwrites the ID entry
  - macos/Runner/BackgroundDownloadPlugin.swift:94 — finish callback resolves only by taskDescription/modelId
  - macos/Runner/BackgroundDownloadPlugin.swift:177 — any stale noncancel error removes the current ID entry
- **Decision:** A retry/double-start can leave old task callbacks addressing the replacement entry. A stale finish can move/report the old file and remove the new task, or a stale error can untrack the new task so its completion is dropped.
- **Recommendation:** Store active downloads by taskIdentifier and verify callback task identity before moving files, emitting events, or removing state.

### V-084 · MEDIUM · macOS OCR does not cap final rendered pixel dimensions

- **Candidates:** CC-2118, CC-2125, CC-2126, CC-2127, CC-2128
- **Provenance:** `ios-performance-review@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - macos/Runner/VisionOcrPlugin.swift:41-45 — only the caller-supplied scale is clamped
  - macos/Runner/VisionOcrPlugin.swift:93-104 — mediaBox dimensions multiply directly into render dimensions
  - macos/Runner/VisionOcrPlugin.swift:131-144 — unchecked CGFloat-to-Int dimensions allocate an RGBA CGContext
- **Decision:** A malformed or legitimately oversized PDF page can request enormous dimensions, trap conversion, or exhaust memory despite the scale clamp. User-selected PDFs are a realistic trigger.
- **Recommendation:** Bound total pixels and each side, reject non-finite/out-of-range values, and downscale oversized pages before Int conversion.

### V-085 · MEDIUM · Million-scale numbers are recursively expressed as thousands

- **Candidates:** CC-0631, CC-0632, CC-0633, CC-0634, CC-0635
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/Num2Word/EnglishNum2Word.swift:145 — the thousand entry is checked before high cards
  - ios/Runner/MisakiVendored/English/Num2Word/EnglishNum2Word.swift:158 — million/billion cards are therefore unreachable for every value already matched by thousand
- **Decision:** One million becomes one thousand thousand and larger numbers are silently mispronounced.
- **Recommendation:** Process cardsDescending before the thousand branch.

### V-086 · MEDIUM · Missing cloud cast rows can make local members undeletable

- **Candidates:** CC-1404, CC-1407, CC-1408
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/cast_manager/cast_manager_screen.dart:846 — unassign always attempts cloud deletion while signed in
  - lib/features/cast_manager/cast_manager_screen.dart:847 — every error, including no matching row, aborts
  - lib/features/cast_manager/cast_manager_screen.dart:859 — local removal is skipped
  - lib/data/services/supabase_service.dart:318 — removeCastMember treats a zero-row delete as failure
- **Decision:** Local-only/failed-invite rows or invitations removed elsewhere repeatedly fail cloud delete and can never reach local removal.
- **Recommendation:** Distinguish not-found from transport/RLS failure and treat an already-absent cloud row as safe local cleanup.

### V-087 · MEDIUM · Missing play start silently extracts front matter

- **Candidates:** CC-2234, CC-2235, CC-2236, CC-2237
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `python-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `python-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/pdf_to_script.py:176 — failed start detection falls back to page zero without warning
  - scripts/pdf_to_script.py:179 — extraction then processes every page
- **Decision:** On unsupported/differently formatted Folger PDFs, covers, essays, TOC, and cast matter flow into parser-ready output as if valid.
- **Recommendation:** Fail with a diagnostic or require an explicit operator override instead of permissive page-zero fallback.

### V-088 · MEDIUM · Model archive download has no operation timeout

- **Candidates:** CC-0916
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/model_manager.dart:292 — getUrl is awaited without timeout
  - lib/data/services/model_manager.dart:340 — body consumption is an unbounded await-for loop
- **Decision:** A stalled server/socket can leave the download UI and model setup pending indefinitely.
- **Recommendation:** Add connect, response, idle-body, and overall timeouts with cleanup of the temporary file.

### V-089 · MEDIUM · Model screen uses Android ONNX readiness/download semantics on iOS

- **Candidates:** CC-1965, CC-1970
- **Provenance:** `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/settings/model_download_screen.dart:47 — status always calls ModelManager.isKokoroReady
  - lib/features/settings/model_download_screen.dart:62 — download always calls ModelManager.downloadAll
  - lib/data/services/model_manager.dart:136 — the manager’s own iOS all-ready contract uses MLX instead
- **Decision:** On iOS this screen can mark the wrong pack ready or download ONNX assets while actual TTS requires MLX, matching the platform mismatch in downloadAll.
- **Recommendation:** Use ModelManager.isAllReady and platform-correct ModelDownloadService state/downloads.

### V-090 · MEDIUM · Native jump-back commands are dispatched as play/pause in Dart

- **Candidates:** CC-0856, CC-0857, CC-0858, CC-0859, CC-0860, CC-0861, CC-0862
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MediaControlPlugin.swift:49-83 — every native remote command emits jumpBack
  - lib/data/services/media_control_service.dart:17-19 — distinct jump-back, skip, and play/pause callbacks are exposed
  - lib/data/services/media_control_service.dart:81-92 — jumpBack shares the onPlayPause body and onJumpBack is never called
- **Decision:** Every iOS remote command currently arrives as jumpBack, yet Dart invokes the pause handler, making the wired jump-back callback unreachable. Dart switch cases terminate implicitly, so the candidates’ additional skip/fall-through assertion is not part of the verified defect.
- **Recommendation:** Dispatch jumpBack to onJumpBack and retain separate cases for future playPause/skip commands.

### V-091 · MEDIUM · Network and disk startup work is serialized before first UI

- **Candidates:** CC-2010, CC-2011, CC-2014, CC-2038, CC-2039, CC-2040
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/main.dart:44-112 — Firebase, Crashlytics diagnostics, Supabase, and debug-log initialization are awaited sequentially
  - lib/data/services/supabase_service.dart:37-60 — Supabase alone can consume the full five-second soft timeout
  - lib/main.dart:149-159 — SharedPreferences is also awaited before runApp
- **Decision:** Slow Supabase/network and disk operations can leave cold start blank for up to the timeout plus remaining work because no widget tree exists yet.
- **Recommendation:** Run the app shell first, retain only provider-critical local state on the pre-run path, and complete cloud/diagnostic initialization asynchronously with explicit readiness state.

### V-092 · MEDIUM · No-export fallback reports success even when CAF move fails

- **Candidates:** CC-0305
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/AppleSttPlugin.swift:443 — this branch runs when AVAssetExportSession cannot be created
  - ios/Runner/AppleSttPlugin.swift:448 — moveItem failure is discarded with try?
  - ios/Runner/AppleSttPlugin.swift:450 — success is returned unconditionally
- **Decision:** A file-system move failure leaves no file at destPath while Dart receives a success-shaped result, silently losing the take.
- **Recommendation:** Use the guarded move-and-nil-on-failure logic already present at lines 483-491.

### V-093 · MEDIUM · Numeric dialogue continuations are discarded as page noise

- **Candidates:** CC-1052
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/script_parser.dart:75 — any digit plus up to five words matches the first noise regex
  - lib/data/services/script_parser.dart:1513 — noise filtering occurs before dialogue continuation
  - lib/data/services/script_parser.dart:1576 — continuation handling is reached only afterward
- **Decision:** A continuation such as “5 minutes later” matches the broad page-header pattern and is silently omitted from the active character’s speech.
- **Recommendation:** Require stronger page-header evidence or defer this noise rule until speaker/continuation context is known.

### V-094 · MEDIUM · One malformed adaptation sample aborts whole profile hydration

- **Candidates:** CC-1087
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/stt_adaptation_service.dart:166 — maps the full sample list
  - lib/data/services/stt_adaptation_service.dart:168 — TrainingSample.fromJson can throw on any bad field
  - lib/data/services/stt_adaptation_service.dart:216 — catches only around the entire file
  - lib/data/services/stt_adaptation_service.dart:243 — later persistence writes the in-memory snapshot
- **Decision:** A version-skewed or partially corrupt entry prevents all otherwise-valid profiles from loading, and a later sample write can replace the file with only current-session data.
- **Recommendation:** Decode entries independently, skip and log malformed records, and avoid replacing a file after failed hydration.

### V-095 · MEDIUM · One malformed persisted job aborts all queue restoration

- **Candidates:** CC-1213
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/sync_queue.dart:232 — jobs are mapped through fromJson in one collection expression
  - lib/data/services/sync_queue.dart:66 — type-mismatched durationMs uses a throwing cast
  - lib/data/services/sync_queue.dart:258 — the resulting exception aborts restore
- **Decision:** A single schema-corrupt entry prevents every valid job from being restored, after loaded has already latched true.
- **Recommendation:** Parse each job independently, quarantine/log malformed entries, and keep valid jobs.

### V-096 · MEDIUM · ORT vendoring permits unpinned native artifacts

- **Candidates:** CC-2194, CC-2195, CC-2196, CC-2197, CC-2198, CC-2199, CC-2200, CC-2201, CC-2202, CC-2203
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `shell-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `shell-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/fetch-ort-java.sh:16 — only version 1.22.0 has a pinned digest
  - scripts/fetch-ort-java.sh:30 — every other version takes the permissive branch
  - scripts/fetch-ort-java.sh:31 — the branch only prints a warning
  - scripts/fetch-ort-java.sh:34 — the unverified jar/native libraries are then copied into the app
- **Decision:** A developer version bump or typo vendors executable native code without an integrity gate, defeating the script’s stated supply-chain protection.
- **Recommendation:** Fail closed for unknown versions until an expected digest is added, or require an explicit supplied digest/unsafe override.

### V-097 · MEDIUM · Paddle inference errors become successful blank pages

- **Candidates:** CC-0679, CC-0681, CC-0682
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/PaddleOcrPlugin.swift:251 — try? converts detector errors to an empty OCR result
  - ios/Runner/PaddleOcrPlugin.swift:338 — recognition errors are also converted to nil
  - ios/Runner/PaddleOcrPlugin.swift:201 — appends the resulting page without incrementing failedPages
- **Decision:** A model/tensor/runtime error is indistinguishable from a genuinely blank page, so the importer can silently omit script content and never select its fallback.
- **Recommendation:** Propagate inference failures as per-page failures or a FlutterError so the importer can report or retry with another engine.

### V-098 · MEDIUM · Page-view OCR omits the scale transform

- **Candidates:** CC-0126
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:183-189 — ocrPdfPage creates a scaled bitmap but passes a null Matrix
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:264-272 — renderPage applies an explicit scale Matrix for the same sizing
- **Decision:** With an identity/default transform, upscaled page content does not use the intended output scale, reducing OCR resolution and making page-view results diverge from full import.
- **Recommendation:** Reuse renderPage for ocrPdfPage or pass the same explicit scale Matrix.

### V-099 · MEDIUM · Parseable incomplete MLX weights reach forced unwraps

- **Candidates:** CC-0479, CC-0480, CC-0481, CC-0482, CC-0483, CC-0484, CC-0485, CC-0486
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroVendored/TTSEngine/WeightLoader.swift:42 — loader sanitizes whatever keys MLX.loadArrays returns
  - ios/Runner/KokoroVendored/TTSEngine/WeightLoader.swift:104 — it returns without checking the required key set
  - ios/Runner/KokoroVendored/TTSEngine/ProsodyPredictor.swift:51 — model construction force-unwraps required dictionary keys
  - ios/Runner/KokoroMLXService.swift:114 — KokoroTTS construction is the native model-load path
- **Decision:** A structurally valid safetensors file with a missing or renamed tensor passes loading and then traps at a forced unwrap, bypassing the service's throwable corrupt-model recovery.
- **Recommendation:** Validate the complete expected key/shape contract and throw before constructing model modules.

### V-100 · MEDIUM · Parseable model packs can crash on missing weights

- **Candidates:** CC-0455, CC-0456
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:71-89 — runtime safetensors load is followed by force-unwrapped weight keys.
  - ios/Runner/KokoroMLXService.swift:110-117 — only thrown initialization errors enter the delete-and-redownload recovery path.
- **Decision:** A syntactically valid wrong-revision pack with a missing key traps at a force unwrap, bypassing the recovery catch and persisting across launch.
- **Recommendation:** Validate the complete required key set and shapes before model construction, then throw a recoverable corruption error.

### V-101 · MEDIUM · Parser always overwrites Pride and Prejudice examples

- **Candidates:** CC-2221, CC-2222, CC-2223, CC-2224
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `python-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/parse_script.py:375-381 — arbitrary argv input is accepted
  - scripts/parse_script.py:390-408 — output names are always pride_and_prejudice_parsed.md/json and opened for overwrite
- **Decision:** Running the tool on another script silently clobbers the canonical checked-in examples with unrelated content.
- **Recommendation:** Derive output names from input or require explicit output paths; reserve canonical example writes for an explicit fixture-update mode.

### V-102 · MEDIUM · Password changes do not require recent reauthentication

- **Candidates:** CC-2399, CC-2400, CC-2401, CC-2402, CC-2403, CC-2404, CC-2405, CC-2406, CC-2407, CC-2408, CC-2409, CC-2410, CC-2411, CC-2412, CC-2413
- **Provenance:** `aws-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `aws-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `docker-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `docker-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/config.toml:158 — access tokens live for one hour
  - supabase/config.toml:214 — secure_password_change is false
- **Decision:** A stolen active session can rotate the account password without proving recent possession of credentials, converting transient session theft into lockout/persistent takeover.
- **Recommendation:** Enable secure_password_change and provide the required reauthentication UX.

### V-103 · MEDIUM · PDF render dimensions are not capped in pixels

- **Candidates:** CC-0678
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/PaddleOcrPlugin.swift:195 — clamps the scale but not page width or height
  - ios/Runner/PaddleOcrPlugin.swift:196 — multiplies arbitrary PDF media-box dimensions by that scale
  - ios/Runner/PaddleOcrPlugin.swift:370 — allocates an RGBA CGContext at the resulting dimensions
- **Decision:** A PDF with an unusually large media box can allocate a very large raster before the detector later downsizes it, causing a realistic import memory spike.
- **Recommendation:** Cap render long-side pixels and derive scale from that cap regardless of caller scale.

### V-104 · MEDIUM · PDF rendering has no output pixel cap

- **Candidates:** CC-0123, CC-0124
- **Provenance:** `android-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:183-189 — page OCR allocates width×scale by height×scale with scale never below 1
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:260-272 — full-document renderPage repeats the uncapped allocation
- **Decision:** An oversized or malformed PDF media box can request an arbitrarily large ARGB bitmap and OOM the process.
- **Recommendation:** Cap both maximum dimension and total pixels before Bitmap.createBitmap; reject pages that cannot fit safely.

### V-105 · MEDIUM · Pending retry timer can start a duplicate replacement download

- **Candidates:** CC-0336, CC-0337, CC-0338, CC-0339, CC-0340, CC-0341, CC-0342
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/BackgroundDownloadPlugin.swift:183 — delayed retry is not represented by a cancellable token
  - ios/Runner/BackgroundDownloadPlugin.swift:184 — it re-reads the current entry and starts it unconditionally
  - ios/Runner/BackgroundDownloadPlugin.swift:122 — manual restart replaces that same entry
- **Decision:** A user retry during backoff starts a fresh task, then the old timer starts another task for the replacement info, causing duplicate transfers and state confusion.
- **Recommendation:** Use a generation token/cancellable work item and verify the entry has no active task before retrying.

### V-106 · MEDIUM · Per-line keys destroy PDF viewer caches

- **Candidates:** CC-1745, CC-1746, CC-1747, CC-1753, CC-1754
- **Provenance:** `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:502-508 — tablet viewer key includes line.id.
  - lib/features/script_editor/script_editor_screen.dart:924-930 — walkthrough viewer key also includes current.id.
  - lib/features/script_editor/pdf_page_view.dart:49-69 — document, rendered-page, and OCR caches live in the widget State.
- **Decision:** Every line step remounts the viewer, reopens/rerenders the PDF, and discards per-page OCR caches even on the same page.
- **Recommendation:** Keep State keyed by document and update page/highlight through didUpdateWidget.

### V-107 · MEDIUM · Per-line keys discard PdfPageView document and OCR caches

- **Candidates:** CC-1798, CC-1805
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_import/ocr_review_screen.dart:363 — phone sheet keys PdfPageView by current line id
  - lib/features/script_import/ocr_review_screen.dart:693 — wide source pane also keys it by selected line id
  - lib/features/script_import/pdf_page_view.dart:49 — the open PDF document is State-owned
  - lib/features/script_import/pdf_page_view.dart:59 — decoded-page LRU is State-owned
  - lib/features/script_import/pdf_page_view.dart:69 — per-page OCR cache is State-owned
  - lib/features/script_import/pdf_page_view.dart:101 — disposal destroys those resources
- **Decision:** Stepping between adjacent flagged lines replaces State even on the same page, forcing PDF reopen/render/OCR instead of didUpdateWidget and cache hits.
- **Recommendation:** Use a stable key per PDF/view instance and make didUpdateWidget rerun highlight location when line metadata changes.

### V-108 · MEDIUM · Permissive invitation update policy remains in final state

- **Candidates:** CC-2435
- **Provenance:** `db-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260315_cast_join_code.sql:33-37 — Users can claim invitation allows updating any null-user row as long as resulting user_id is self
  - supabase/migrations/20260703140000_security_lockdown.sql:119-126 — lockdown drops a differently named policy and recreates similarly broad column checks
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:145-165 — current RPC is code-gated, but no later migration drops the original direct policy
- **Decision:** A caller able to target an unclaimed row can claim it while changing unconstrained role/display/contact/character columns; the old policy is never removed.
- **Recommendation:** Drop both legacy claim policies and restrict direct UPDATE to immutable-column-safe semantics, preferably exposing only the code-gated SECURITY DEFINER RPC.

### V-109 · MEDIUM · Persistent AudioRecord errors busy-spin the capture thread

- **Candidates:** CC-0047, CC-0048, CC-0049
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:368 — AudioRecord.read errors enter an immediate continue at line 369
- **Decision:** A revoked or invalidated input can return a persistent negative code while capturing remains true, causing an unbounded tight loop and no user-visible termination.
- **Recommendation:** Break on negative read errors, post a capture error, and only retry zero reads with bounded backoff.

### V-110 · MEDIUM · Playback continuations touch disposed studio state

- **Candidates:** CC-1556, CC-1557, CC-1558, CC-1560
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/recording_studio/recording_studio_screen.dart:723-731 — ref.read and setState occur after several awaits without a mounted check.
  - lib/features/recording_studio/recording_studio_screen.dart:742-744 — stop playback sets state after await without a mounted check.
- **Decision:** Leaving during playback setup/stop can throw ref-after-dispose or setState-after-dispose.
- **Recommendation:** Snapshot settings before awaits and guard mounted before every State/ref touch afterward.

### V-111 · MEDIUM · Pre-join cast fetch leaks member account UUIDs

- **Candidates:** CC-2520, CC-2521
- **Provenance:** `db-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:101 — fetch returns the full production roster
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:102 — stable cast row ids are included
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:107 — each linked auth user_id is included
- **Decision:** A shared code holder can correlate account UUIDs with cast names/characters even though the join UI needs only claimable role information.
- **Recommendation:** Project only required display/claim fields and omit user_id for pre-membership callers.

### V-112 · MEDIUM · Production cascade deletion is not transactional

- **Candidates:** CC-0758, CC-0759, CC-0760, CC-0762, CC-0763, CC-0764, CC-0765, CC-0766, CC-0767, CC-0768, CC-0777, CC-0778
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/repositories/production_repository.dart:42 — deleteProduction begins outside a transaction
  - lib/data/repositories/production_repository.dart:56 — five destructive database awaits execute independently
  - lib/data/repositories/production_repository.dart:142 — the same repository uses a transaction for delete-and-reinsert saves
- **Decision:** An exception or process stop between deletes leaves a partially destroyed production; audio files have already been removed.
- **Recommendation:** Wrap all database deletes in one Drift transaction and perform best-effort file cleanup after commit.

### V-113 · MEDIUM · Production voice cloud synchronization is fire-and-forget and ungated in UI

- **Candidates:** CC-1427, CC-1428, CC-1429, CC-1430, CC-1431, CC-1432, CC-1433, CC-1434, CC-1435, CC-1436, CC-1437, CC-1438, CC-1439, CC-1440, CC-1441
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/cast_manager/voice_config_screen.dart:154 — preset callback is async
  - lib/features/cast_manager/voice_config_screen.dart:162 — saveVoicePreset is neither awaited nor caught
  - lib/features/cast_manager/voice_config_screen.dart:426 — dialect callback mutates local state first
  - lib/features/cast_manager/voice_config_screen.dart:442 — saveLocale is unawaited
  - lib/features/cast_manager/voice_config_screen.dart:443 — paired saveVoicePreset is unawaited
  - supabase/migrations/20260314140000_fix_rls_recursion.sql:34 — production writes are authorized only to the organizer
- **Decision:** Offline/RLS failures leave local UI updated while the production row remains stale, with an unhandled future and no feedback; non-organizers can reach the controls but their writes are necessarily rejected.
- **Recommendation:** Organizer-gate production-wide controls and await cloud writes in try/catch with explicit local-only/failure feedback.

### V-114 · MEDIUM · Production-pushed auth policy permits weak six-character passwords

- **Candidates:** CC-2376, CC-2377, CC-2378, CC-2379, CC-2380, CC-2381, CC-2382, CC-2383, CC-2384, CC-2385, CC-2386, CC-2387, CC-2388, CC-2389, CC-2390, CC-2391, CC-2392
- **Provenance:** `aws-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `aws-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `docker-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `docker-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/config.toml:169 — public signup is enabled
  - supabase/config.toml:175 — minimum password length is 6
  - supabase/config.toml:178 — no composition requirement is set
- **Decision:** Internet users can choose common six-character passwords, below the file recommendation and materially easier to guess under credential attacks.
- **Recommendation:** Raise the minimum to at least 8–12 characters and consider a breached-password/strength policy rather than brittle composition alone.

### V-115 · MEDIUM · Rapid production switches race shared recording state and sync

- **Candidates:** CC-0725, CC-0726, CC-0727, CC-0728
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `sql-migration-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/app.dart:252-268 — each production change launches an unawaited load then sync with no generation guard
  - lib/providers/production_providers.dart:127-137 — loadForProduction sets a shared production id before an awaited DB read, then writes shared state
  - lib/providers/production_providers.dart:442-480 — sync installs singleton callbacks and later reads the shared recordings provider
- **Decision:** A slower stale load can finish after a newer production load and overwrite the current recordings map, then launch sync for the stale production against shared callbacks/state.
- **Recommendation:** Serialize production transitions or use an epoch/current-production check before every post-await state write and sync launch.

### V-116 · MEDIUM · Raw production join codes are exported in debug logs

- **Candidates:** CC-1914, CC-1916, CC-1918, CC-1919, CC-1920, CC-1923, CC-1924
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/supabase_service.dart:482-498 — lookupByJoinCode logs the raw code despite an adjacent warning that it is a standing credential
  - lib/features/settings/debug_log_screen.dart:68-81 — send-to-developer uploads raw toLine output
  - lib/features/settings/debug_log_screen.dart:100-121 — share and clipboard export the same raw text
- **Decision:** Looking up a code places a reusable production credential into every later upload/share/copy of the log. This is a concrete credential disclosure path.
- **Recommendation:** Stop logging raw join codes at the source and add export-time redaction as defense in depth.

### V-117 · MEDIUM · Re-recording truncates the committed take in place

- **Candidates:** CC-1548, CC-1549, CC-1550, CC-1552
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/recording_studio/recording_studio_screen.dart:590-608 — every take for a line starts at the same line-ID filename.
  - lib/features/recording_studio/recording_studio_screen.dart:690-712 — the replacement is registered only after recording has already overwritten that path.
- **Decision:** An interrupted re-record destroys the previous local take and can race a queued upload reading the same file.
- **Recommendation:** Record to a unique temporary path and atomically replace/delete the prior take only after successful registration.

### V-118 · MEDIUM · Realtime events can replace newer cached takes

- **Candidates:** CC-0985
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/recording_sync_service.dart:407-415 — full sync compares recorded_at before replacing cache.
  - lib/data/services/recording_sync_service.dart:618-641 — realtime handling downloads and overwrites without a timestamp comparison.
- **Decision:** An out-of-order realtime event can overwrite a newer take with older audio.
- **Recommendation:** Apply the same recorded_at monotonicity guard and serialize per-line downloads.

### V-119 · MEDIUM · Recognition request is raced between the audio tap and teardown

- **Candidates:** CC-0279, CC-0280
- **Provenance:** `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/AppleSttPlugin.swift:298 — the render callback reads and appends to recognitionRequest
  - ios/Runner/AppleSttPlugin.swift:632 — teardown ends the request
  - ios/Runner/AppleSttPlugin.swift:633 — teardown nils it before stopping/removing the tap at lines 638-640
- **Decision:** A stop/restart can overlap an in-flight render callback with endAudio and deallocation of the same request.
- **Recommendation:** Stop and remove the tap before ending/nilling the request, with all access synchronized.

### V-120 · MEDIUM · Recording cache key omits production identity

- **Candidates:** CC-0966, CC-0976
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/recording_sync_service.dart:124-125 — cache entries are keyed only by lineId.
  - lib/data/services/recording_sync_service.dart:251-252 — getCachedPath accepts no production identifier.
  - lib/data/services/recording_sync_service.dart:439-447 — a download overwrites the global lineId entry with its production.
- **Decision:** Two productions preserving the same script-line IDs can overwrite or retrieve each other’s local cached audio.
- **Recommendation:** Key cache and manifest entries by (productionId, lineId) and require both at every lookup.

### V-121 · MEDIUM · Recording line index is not clamped after script changes

- **Candidates:** CC-1538, CC-1539, CC-1540, CC-1541, CC-1542, CC-1543
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/recording_studio/recording_studio_screen.dart:241-245 — recomputing _myLines leaves _currentLineIdx unchanged.
  - lib/features/recording_studio/recording_studio_screen.dart:256-260 — build immediately indexes the refreshed list with the stale index.
- **Decision:** A live script/character change to fewer lines causes a RangeError and blanks the studio.
- **Recommendation:** Clamp/reset the index and recording state whenever the memo key changes.

### V-122 · MEDIUM · Recording playback updates state after awaits without mounted guards

- **Candidates:** CC-1594, CC-1595, CC-1596
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/recording_studio/recordings_browser_screen.dart:651 — playback awaits path resolution
  - lib/features/recording_studio/recordings_browser_screen.dart:687 — it awaits several player/session operations
  - lib/features/recording_studio/recordings_browser_screen.dart:695 — setState is unguarded after those awaits
  - lib/features/recording_studio/recordings_browser_screen.dart:710 — stop awaits player
  - lib/features/recording_studio/recordings_browser_screen.dart:711 — stop also calls unguarded setState
- **Decision:** Popping the screen during path/player operations can call setState on a disposed State.
- **Recommendation:** Check mounted after async gaps before updating UI, while still stopping shared resources safely.

### V-123 · MEDIUM · Recording startup leaks local native resources on exceptions

- **Candidates:** CC-0040, CC-0041, CC-0042, CC-0043, CC-0044
- **Provenance:** `android-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:284 — AudioRecord is held only in a local during setup
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:322 — catch calls releaseRecorder, which cannot release the local record/encoder/muxer
- **Decision:** A codec, muxer, or startRecording exception before field assignment bypasses cleanup of already-created local resources; device codec failures and invalid/full output paths are realistic triggers.
- **Recommendation:** Track locals across the setup try and stop/release each constructed resource in catch/finally.

### V-124 · MEDIUM · Recording sync fetches the complete cloud history

- **Candidates:** CC-0967, CC-0968
- **Provenance:** `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `metal-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/recording_sync_service.dart:276-290 — each sync fetches all recording metadata for the production before building maps.
  - lib/data/services/recording_sync_service.dart:263-270 — this runs on each production sync/open path.
- **Decision:** Transfer, decoding, and memory scale with every historical recording row and are also vulnerable to server row caps.
- **Recommendation:** Page the query or fetch only current/newer rows with a server-side latest-per-line query.

### V-125 · MEDIUM · Recording sync performs growing synchronous stat sweeps

- **Candidates:** CC-0970, CC-0973, CC-0978, CC-0979, CC-0980, CC-0981, CC-0982, CC-0983, CC-0984
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `metal-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `metal-performance-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/recording_sync_service.dart:348-349 — upload discovery uses existsSync per local recording.
  - lib/data/services/recording_sync_service.dart:398-413 — download discovery performs synchronous existence checks per line/cache entry.
  - lib/data/services/recording_sync_service.dart:553-562 — cache hydration for one production iterates entries and stats files synchronously on the caller isolate.
- **Decision:** Production open and sync completion can block the UI isolate for hundreds or thousands of filesystem calls as the library grows.
- **Recommendation:** Move bulk validation off the UI isolate and scan only entries for the requested production.

### V-126 · MEDIUM · Rehearsal async capture continues after disposal

- **Candidates:** CC-1630
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:2290 — iOS awaits STT listen
  - lib/features/rehearsal/rehearsal_screen.dart:2305 — capture starts afterward without mounted check
  - lib/features/rehearsal/rehearsal_screen.dart:3007 — Android awaits capture startup
  - lib/features/rehearsal/rehearsal_screen.dart:3028 — provider state is written afterward without mounted check
- **Decision:** Closing the screen during either await can start/retain capture or use Riverpod ref after the widget is disposed.
- **Recommendation:** Check mounted and current line/state immediately after each await before capture or provider access.

### V-127 · MEDIUM · Rehearsal history survives account switches in memory

- **Candidates:** CC-1599
- **Provenance:** `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_history_screen.dart:9-35 — the global provider has clear but no auth scoping.
  - lib/features/settings/settings_screen.dart:324-359 — sign-out does not clear or invalidate rehearsalHistoryProvider.
- **Decision:** A second account in the same process can see the previous account’s rehearsal sessions.
- **Recommendation:** Clear user-scoped providers on sign-out and key persisted history by user.

### V-128 · MEDIUM · Rehearsal launches async audio paths without an error boundary

- **Candidates:** CC-1659
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:1770-1779 — listening and playback Futures are started without await/catchError
  - lib/features/rehearsal/rehearsal_screen.dart:2177-2197 — listener setup awaits audio-session and record-only work without a surrounding catch
  - lib/features/rehearsal/rehearsal_screen.dart:2894-2920 — live-ASR startup awaits can throw before capture fallback is established
- **Decision:** Unexpected session/ASR/TTS errors become uncaught async failures and can leave rehearsal state stuck rather than showing a recoverable error.
- **Recommendation:** Route both branches through one guarded async dispatcher that logs with stack and restores a usable rehearsal state.

### V-129 · MEDIUM · Rehearsal persistence uses mutable scene names as identifiers

- **Candidates:** CC-1608, CC-1609, CC-1610, CC-1611, CC-1612, CC-1613, CC-1657, CC-1658
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:466 — checkpoint key embeds scene.sceneName
  - lib/features/rehearsal/rehearsal_screen.dart:3263 — history sceneId is also scene.sceneName
  - lib/features/rehearsal/rehearsal_screen.dart:3264 — display label is separately available as sceneName
  - lib/data/models/script_models.dart:188 — ScriptScene has a stable id
- **Decision:** Renaming a scene loses its checkpoint/history join, and duplicate names collide across distinct scenes and index spaces.
- **Recommendation:** Use scene.id for keys and sceneId while retaining labels only for display.

### V-130 · MEDIUM · Rehearsal settings reset on every process restart

- **Candidates:** CC-1976, CC-1977, CC-1978, CC-2360
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/settings_screen.dart:19 — jump-back provider initializes only from a constant
  - lib/features/settings/settings_screen.dart:22 — playback speed does likewise
  - lib/features/settings/settings_screen.dart:31 — advance silence uses an in-memory literal
  - lib/features/settings/settings_screen.dart:55 — fast-mode enabled is an in-memory provider
  - lib/features/settings/settings_screen.dart:62 — font size is also in-memory
  - lib/features/settings/settings_screen.dart:160 — controls only update provider state, with no persistence write
- **Decision:** The controls present durable user preferences, but there is no hydration or SharedPreferences write path for them, so relaunch restores defaults.
- **Recommendation:** Persist a versioned settings record and hydrate providers before rehearsal UI is used.

### V-131 · MEDIUM · Remote controls can save duplicate completed sessions

- **Candidates:** CC-1642
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:2639 — advance at/past the end calls completion
  - lib/features/rehearsal/rehearsal_screen.dart:2646 — _completeScene is invoked again
  - lib/features/rehearsal/rehearsal_screen.dart:2834 — remote skip has no sceneComplete guard
  - lib/features/rehearsal/rehearsal_screen.dart:2844 — remote play/pause also has no completion guard
  - lib/features/rehearsal/rehearsal_screen.dart:1793 — each completion saves a session
- **Decision:** Remote events on the completion view can execute completion side effects repeatedly and append duplicate timestamped history rows.
- **Recommendation:** Make _completeScene idempotent and ignore remote advance/resume in sceneComplete.

### V-132 · MEDIUM · Repeated OOV words rerun full fallback inference

- **Candidates:** CC-0587
- **Provenance:** `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/FallbackNetwork/EnglishFallbackNetwork.swift:74 — every call constructs tensors and invokes model.generate
  - ios/Runner/MisakiVendored/English/FallbackNetwork/EnglishFallbackNetwork.swift:77 — no word/result cache exists around generation
- **Decision:** Repeated names or unknown words in scripts repeatedly pay the same encoder/autoregressive decode cost, causing avoidable TTS latency.
- **Recommendation:** Memoize fallback results by normalized word and locale with a bounded cache.

### V-133 · MEDIUM · Reported recording duration ignores silence trimming

- **Candidates:** CC-0300, CC-0301, CC-0302
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/AppleSttPlugin.swift:414 — durationMs is captured from wall clock
  - ios/Runner/AppleSttPlugin.swift:459 — the export may apply a shorter speech timeRange
  - ios/Runner/AppleSttPlugin.swift:473 — the original duration is returned after successful trimmed export
  - lib/features/rehearsal/rehearsal_screen.dart:3199 — returned duration is persisted with the recording
- **Decision:** Every materially trimmed take stores and displays a duration longer than the actual returned audio and inflates adaptation-duration accounting.
- **Recommendation:** Return the applied timeRange duration, or read the finalized asset duration.

### V-134 · MEDIUM · Restored background download cannot be cancelled by model id

- **Candidates:** CC-0321, CC-0322
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/BackgroundDownloadPlugin.swift:134 — cancel only cancels a task found in activeDownloads
  - ios/Runner/BackgroundDownloadPlugin.swift:84 — persisted state is reconstructed only from delegate callbacks, not at plugin startup
- **Decision:** After relaunch the live URLSession task can continue even though cancelDownload removes only the record, consuming network and storage against the user request.
- **Recommendation:** Enumerate session tasks at startup/cancel and match taskDescription to cancel the system task.

### V-135 · MEDIUM · Resume data is reused without binding it to the requested URL

- **Candidates:** CC-0320, CC-0323, CC-0324, CC-0325, CC-0326, CC-0327, CC-0328, CC-0331, CC-0332, CC-0333, CC-0334, CC-0335
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/BackgroundDownloadPlugin.swift:51 — resume data is keyed only by destination path
  - ios/Runner/BackgroundDownloadPlugin.swift:153 — any nonempty resume blob is preferred over info.url
  - ios/Runner/BackgroundDownloadPlugin.swift:122 — a fresh request can replace the URL without deleting the old resume file
- **Decision:** Changing a model URL or reusing a destination can silently resume the old request. Corrupt data generally fails and is later cleared, but the URL-mismatch failure is current and realistic during CDN/revision changes.
- **Recommendation:** Persist URL/revision metadata alongside resume data and discard the blob unless it matches the new request; write it atomically.

### V-136 · MEDIUM · Running-header scrub deletes legitimate title mentions

- **Candidates:** CC-1064, CC-1065, CC-1066, CC-1067, CC-1068, CC-1069
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/script_parser.dart:300 — title-seeded header path begins
  - lib/data/services/script_parser.dart:310 — only three standalone title occurrences are required
  - lib/data/services/script_parser.dart:323 — page numbers are optional on both sides of the scrub regex
  - lib/data/services/script_parser.dart:331 — the unanchored regex is replaced in every candidate line
- **Decision:** Once a production title is classified as a header, an exact-case title phrase inside genuine dialogue is removed even without adjacent page-number evidence.
- **Recommendation:** Require page-seam/page-number context or boundary anchoring for inline removal, including the title-seeded path.

### V-137 · MEDIUM · Saving a blank new speaker erases attribution

- **Candidates:** CC-1762, CC-1763, CC-1764
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:1100-1109 — Save accepts an empty new-character field and passes an empty finalChar.
  - lib/features/script_editor/script_editor_screen.dart:1327-1341 — update replaces character and clears/recomputes multi-character attribution.
- **Decision:** The new-character path, including combined-cue lines treated as unknown, can silently save an unattributed line.
- **Recommendation:** Disable Save until a nonempty valid speaker is supplied and preserve ensemble attribution unless explicitly changed.

### V-138 · MEDIUM · Scene rename writes location into every line scene tag

- **Candidates:** CC-1707, CC-1708, CC-1709, CC-1710, CC-1711, CC-1712, CC-1713, CC-1714
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/scene_editor_screen.dart:377 — code intends to update line scene tags
  - lib/features/script_editor/scene_editor_screen.dart:386 — it writes updated.location rather than updated.sceneName
  - lib/features/script_editor/cloud_sync_dialog.dart:44 — line.scene participates in cloud diffing
- **Decision:** A name/location edit corrupts line-level scene identity (or blanks it), causing wrong grouping/exports and spurious cloud diffs.
- **Recommendation:** Write updated.sceneName, or preserve canonical tag semantics explicitly.

### V-139 · MEDIUM · Self-join stores a different role locally than the server

- **Candidates:** CC-1485
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:137 — server inserts role actor
  - lib/features/join/join_production_screen.dart:508 — client hardcodes CastRole.primary
- **Decision:** The same membership immediately has divergent role semantics across the joiner and other devices.
- **Recommendation:** Build CastMemberModel from the returned row role, or use CastRole.actor consistently.

### V-140 · MEDIUM · Sign-out during upload can null-dereference metadata user

- **Candidates:** CC-1198, CC-1199, CC-1200, CC-1201, CC-1202, CC-1203, CC-1204, CC-1205
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/sync_queue.dart:95 — readiness is checked before queue processing
  - lib/data/services/sync_queue.dart:393 — upload introduces an await gap
  - lib/data/services/sync_queue.dart:114 — currentUser is force-unwrapped afterward
- **Decision:** A user can sign out or lose the session while an upload is in flight, causing metadata save to throw after storage upload and leaving an orphan/retry loop.
- **Recommendation:** Capture the authenticated user id per job/run or revalidate currentUser immediately before metadata save and pause cleanly when absent.

### V-141 · MEDIUM · Signed-out delete misreports a surviving cloud copy as success

- **Candidates:** CC-1582
- **Provenance:** `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/recording_studio/recordings_browser_screen.dart:552 — signed-out cloud deletion returns skipped
  - lib/features/recording_studio/recordings_browser_screen.dart:532 — only failed contributes a warning
  - lib/features/recording_studio/recordings_browser_screen.dart:536 — skipped therefore produces Recording deleted
- **Decision:** For an uploaded take after session expiry, local deletion succeeds while the shared database row remains and the UI claims full deletion.
- **Recommendation:** Treat skipped as a cloud-removal problem when remoteUrl exists, and tell the user to sign in to finish deletion.

### V-142 · MEDIUM · Signed-out invite flow consumes pending deep link before authentication

- **Candidates:** CC-1471, CC-1472
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/join/join_production_screen.dart:46 — post-frame pending join processing is unconditional
  - lib/features/join/join_production_screen.dart:55 — provider state is cleared before sign-in
  - lib/features/join/join_production_screen.dart:130 — signed-out user then navigates away to auth
- **Decision:** A signed-out invite recipient loses the code/character when JoinProductionScreen is disposed, so auth cannot return them to the pending invite.
- **Recommendation:** Do not consume/clear pending join until signed in and the join succeeds; preserve it across auth navigation.

### V-143 · MEDIUM · Speech callback tears down AVAudioEngine off the serialized UI path

- **Candidates:** CC-0275, CC-0276, CC-0277
- **Provenance:** `ios-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/AppleSttPlugin.swift:249 — recognitionTask supplies an asynchronous result handler
  - ios/Runner/AppleSttPlugin.swift:265 — final results call stopCurrentSession directly
  - ios/Runner/AppleSttPlugin.swift:274 — errors also call teardown directly
  - ios/Runner/AppleSttPlugin.swift:631 — teardown mutates request, task, engine and tap state
- **Decision:** The Speech callback queue is not serialized with method-channel listen/stop calls, so rapid stop/relisten can race non-thread-safe engine teardown.
- **Recommendation:** Serialize all recognition and AVAudioEngine state mutations on the main queue or one dedicated session queue.

### V-144 · MEDIUM · Speech recognizer omitted from Android package-visibility queries

- **Candidates:** CC-0023
- **Provenance:** `android-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/AndroidManifest.xml:55 — the sole queries block contains only PROCESS_TEXT through line 60
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:114 — availability is gated by SpeechRecognizer.isRecognitionAvailable
- **Decision:** On Android 11+ recognition-service visibility can be filtered, yielding a false unavailable result on a device with a recognizer installed.
- **Recommendation:** Add an android.speech.RecognitionService intent to the manifest queries block.

### V-145 · MEDIUM · Split line creates duplicate ordering metadata

- **Candidates:** CC-1766, CC-1768, CC-1769, CC-1770, CC-1771, CC-1772, CC-1773, CC-1774, CC-1775, CC-1776
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:1215-1243 — the new half gets original+1 order/line numbers while following lines are unchanged.
  - lib/data/services/supabase_service.dart:726 — cloud reload orders script lines by order_index.
- **Decision:** Splitting a nonfinal line collides with its successor, so persistence/reload can reorder lines nondeterministically.
- **Recommendation:** Reindex the complete list after insert/delete, as the reorder path already does.

### V-146 · MEDIUM · Stage-direction heuristic drops ordinary dialogue

- **Candidates:** CC-2226, CC-2239, CC-2240
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `python-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `python-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/pdf_to_script.py:87 — pronoun/The keyword regex classifies broad sentence forms
  - scripts/pdf_to_script.py:251 — heuristic runs before the dialogue branch
- **Decision:** Dialogue beginning with forms such as “They …” or “The queen enters …” at the Folger dialogue x-position is emitted as a stage direction, changing speaker content.
- **Recommendation:** Require layout/styling evidence and narrow lexical patterns; add representative dialogue fixtures.

### V-147 · MEDIUM · Status refresh deletes active download staging files

- **Candidates:** CC-0872, CC-0873, CC-0874, CC-0875, CC-0889
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/model_download_service.dart:337-370 — refresh skips status mutation for downloading models but always runs temporary cleanup
  - lib/data/services/model_download_service.dart:576-634 — Dart fallback writes and then renames the same .tmp path
  - lib/data/services/model_download_service.dart:729-742 — cleanup deletes every model .tmp without checking state
- **Decision:** A refresh during an Android fallback transfer unlinks its staging path and makes final rename fail, forcing a full retry.
- **Recommendation:** Skip cleanup for downloading model IDs and avoid deleting any staging file owned by an active native or Dart task.

### V-148 · MEDIUM · Stop can report success before muxer finalization completes

- **Candidates:** CC-0057, CC-0058, CC-0059, CC-0060
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:444 — join is capped at three seconds without checking thread liveness
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:448 — any nonempty file is then reported as successful
- **Decision:** If codec finalization exceeds the timeout, the returned MP4 can still lack its final metadata and be unreadable despite success.
- **Recommendation:** After timeout, report a finalization error and never expose the path until the capture thread has exited.

### V-149 · MEDIUM · Stopping Kokoro does not signal the native cancellation flag

- **Candidates:** CC-0828
- **Provenance:** `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/kokoro_onnx_service.dart:46 — _cancelBelow exists specifically for native callback cancellation
  - lib/data/services/kokoro_onnx_service.dart:225 — urgent requests raise the flag
  - lib/data/services/kokoro_onnx_service.dart:328 — stop begins without raising the flag
  - lib/data/services/kokoro_onnx_service.dart:335 — isolate kill is requested only before the next event
- **Decision:** An isolate blocked in native generation cannot process the kill request until it returns, allowing a stopped engine to overlap a restarted engine and retain its large model meanwhile.
- **Recommendation:** Raise _cancelBelow past all issued sequences before requesting isolate teardown.

### V-150 · MEDIUM · STT adaptation profiles grow and rewrite without bound

- **Candidates:** CC-1095, CC-1097, CC-1098, CC-1100, CC-1101, CC-1102, CC-1103, CC-1104
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `metal-performance-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/stt_adaptation_service.dart:322 — copies the full actor sample list on every add
  - lib/data/services/stt_adaptation_service.dart:334 — copies the full pooled list again
  - lib/data/services/stt_adaptation_service.dart:243 — JSON-encodes every retained sample for each persist
  - lib/data/services/stt_adaptation_service.dart:67 — recomputes duration by folding all samples
- **Decision:** Every recording is retained twice, additions become cumulatively quadratic, and every debounce rewrites an ever-growing transcript/path snapshot on the main isolate. Training never consumes or prunes it.
- **Recommendation:** Cap or compact retained samples, maintain duration incrementally, and serialize persistence in an isolate or append-oriented store.

### V-151 · MEDIUM · System TTS exceptions leave speak half-open

- **Candidates:** CC-1247
- **Provenance:** `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/tts_service.dart:383-398 — speak marks the invocation active before platform work
  - lib/data/services/tts_service.dart:428-452 — stop/session/voice/pitch/speak awaits are not inside a catch/finally
- **Decision:** A platform exception escapes while active flags and trace remain set, so completion does not recover the rehearsal line.
- **Recommendation:** Wrap the fallback in generation-aware try/catch/finally, reset active state, log with stack, and invoke the explicit error completion policy.

### V-152 · MEDIUM · System TTS fallback can speak after stop or replacement

- **Candidates:** CC-1240, CC-1241, CC-1242, CC-1243
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/tts_service.dart:394-424 — generation is captured/rechecked only around the Kokoro attempt
  - lib/data/services/tts_service.dart:428-452 — fallback has several awaits, sets usingSystemTts, and speaks without a final generation check
  - lib/data/services/tts_service.dart:825-835 — stop invalidates the generation during those awaits
- **Decision:** A stopped or superseded invocation can resume and start its old text over the new line.
- **Recommendation:** Capture the invocation generation for every speak path and check it after each async gap, especially immediately before setting active state and calling system speak.

### V-153 · MEDIUM · System TTS silent-start failure has no recovery

- **Candidates:** CC-1244, CC-1246, CC-1248
- **Provenance:** `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/tts_service.dart:428-452 — comments document silent Android focus failure, but the speak result is ignored and no watchdog is armed
  - lib/data/services/tts_service.dart:183-203 — completion advances only when an error/completion callback arrives
- **Decision:** When the engine refuses to start without a callback, isSpeaking remains true and rehearsal never advances.
- **Recommendation:** Check flutter_tts’s start result and arm a generation-aware duration watchdog that completes or surfaces an error exactly once.

### V-154 · MEDIUM · Transient restore I/O failure permanently latches queue as loaded

- **Candidates:** CC-1211
- **Provenance:** `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/sync_queue.dart:210 — loaded is set before any path/read operation
  - lib/data/services/sync_queue.dart:258 — outer restore errors are only logged
- **Decision:** After a transient read/path error, subsequent persistence skips restore and can overwrite the only queued-job snapshot with current memory.
- **Recommendation:** Set loaded only after a successful/decided load, or clear it on retryable outer errors.

### V-155 · MEDIUM · Type-change and split discard unsaved sheet text

- **Candidates:** CC-1751
- **Provenance:** `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:874-896 — type-change and split actions operate on current and close the sheet without committing textController.
  - lib/features/script_editor/script_editor_screen.dart:1141-1159 — type change copies the stored line text; split opens from that stored line.
- **Decision:** Typed corrections vanish when either action is chosen before Save.
- **Recommendation:** Commit the controller text first or pass it explicitly into type/split operations.

### V-156 · MEDIUM · Unguarded startup microtask turns recoverable ML failures into unhandled fatals

- **Candidates:** CC-2041, CC-2042, CC-2043, CC-2044, CC-2045, CC-2046, CC-2047, CC-2048, CC-2049, CC-2050, CC-2051
- **Provenance:** `db-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `sql-migration-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/main.dart:124-147 — an unawaited Future.microtask sequentially awaits TTS, STT, and model downloads with no catch
  - lib/data/services/tts_service.dart:151-176 — init awaits multiple platform operations that can throw
  - lib/main.dart:69-75 — escaped async errors are recorded as fatal
- **Decision:** One failed initialization aborts all subsequent steps and escapes as an unhandled fatal report even though the app can use fallbacks; per-model failure also aborts the remaining downloads.
- **Recommendation:** Schedule after app start and isolate each independent init/download in explicit try/catch logging, continuing where safe.

### V-157 · MEDIUM · Unknown character cues are appended to the previous speaker

- **Candidates:** CC-2206
- **Provenance:** `python-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/parse_script.py:136-167 — cue detection recognizes only the hardcoded cast/multi-cues
  - scripts/parse_script.py:292-313 — an unrecognized uppercase cue falls into current-dialogue continuation
- **Decision:** A missing/misspelled cast entry silently attributes the following cue and dialogue to the prior character.
- **Recommendation:** Detect cue-shaped unknown names and emit an explicit unattributed/warning record instead of continuation.

### V-158 · MEDIUM · Unnamed parser scene transitions always reuse Scene 1

- **Candidates:** CC-1083, CC-1084, CC-1085, CC-1086
- **Provenance:** `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/script_parser.dart:1403 — scene number counts header lines having nonempty scene
  - lib/data/services/script_parser.dart:1483 — emitted act header begins here
  - lib/data/services/script_parser.dart:1486 — emitted header has an empty scene
  - lib/data/services/script_parser.dart:1498 — explicit scene headers update state without emitting a header line
  - lib/data/services/script_parser.dart:1688 — scene boundaries require the scene tag to change
- **Decision:** The count cannot increase from emitted headers, so consecutive location-less transitions receive the same tag and are merged by scene detection.
- **Recommendation:** Maintain an explicit per-act scene counter incremented at each transition.

### V-159 · MEDIUM · Verification tool leaves a persistent known-credential member

- **Candidates:** CC-2771, CC-2772, CC-2773, CC-2775, CC-2776, CC-2777, CC-2778
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tool/verify_cloud_recordings.dart:22-27 — each run creates a throwaway account with a fixed password pattern.
  - tool/verify_cloud_recordings.dart:38-50 — it inserts an understudy membership.
  - tool/verify_cloud_recordings.dart:52-85 — all completion and early-exit paths lack membership cleanup.
- **Decision:** Each successful run can leave a ghost cast member with continuing read access and pollute the real roster.
- **Recommendation:** Capture the inserted row ID and remove it in a finally block; use disposable credentials and delete the test account where supported.

### V-160 · MEDIUM · Very long OOV words exceed fallback positional embeddings

- **Candidates:** CC-0586
- **Provenance:** `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MisakiVendored/Resources/us_bart_config.json:36 — max_position_embeddings is 64
  - ios/Runner/MisakiVendored/English/FallbackNetwork/EnglishFallbackNetwork.swift:45 — every grapheme is converted without a length cap
  - ios/Runner/MisakiVendored/English/FallbackNetwork/EnglishFallbackNetwork.swift:75 — the unbounded token list is passed to BART
- **Decision:** A user-supplied letter run longer than the model position table reaches an out-of-range positional slice.
- **Recommendation:** Return an unknown/fallback pronunciation when token count plus special tokens exceeds the configured maximum.

### V-161 · MEDIUM · Walkthrough navigation discards unsaved corrections

- **Candidates:** CC-1757
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:937-947 — Prev/Next goTo replaces textController.text with the next line.
  - lib/features/script_editor/script_editor_screen.dart:993-999 — only Looks right explicitly commits typed text first.
- **Decision:** Using Prev or Next after typing silently loses the current correction.
- **Recommendation:** Commit or prompt before navigation, or retain per-line controller state.

### V-162 · MEDIUM · Wide-layout drawer taps pop the hub route

- **Candidates:** CC-1515, CC-1516, CC-1517
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/core/responsive.dart:54 — wide layouts embed drawer directly in the scaffold body
  - lib/core/responsive.dart:64 — the Drawer widget is a permanent row child, not a navigator route
  - lib/features/production_hub/production_hub_screen.dart:626 — drawer actions unconditionally Navigator.pop before navigating
- **Decision:** On tablet/desktop there is no modal drawer route, so the pop removes ProductionHub and loses its state/back-stack position.
- **Recommendation:** Pass modal/wide context into drawer actions and only close an actually open modal drawer.

### V-163 · LOW · A rapid same-path retake can overlap asynchronous CAF export

- **Candidates:** CC-0299
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/AppleSttPlugin.swift:386 — every take for a path reuses path + .caf
  - ios/Runner/AppleSttPlugin.swift:438 — export continues asynchronously after stopRecording
  - lib/features/rehearsal/rehearsal_screen.dart:2631 — at least one capture stop path is fire-and-forget
- **Decision:** A new recording can reopen the deterministic CAF while an earlier fire-and-forget stop is still exporting, allowing the first result to observe rewritten input.
- **Recommendation:** Rename the closed CAF to a generation-unique temporary path before asynchronous export.

### V-164 · LOW · AAC flush can proceed without queuing end-of-stream

- **Candidates:** CC-0053
- **Provenance:** `android-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:408 — a timed-out dequeue skips the EOS queue
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:414 — drainEncoder(true) still runs afterward
- **Decision:** A busy codec can miss the one EOS attempt, so the bounded drain times out and can omit the recording tail.
- **Recommendation:** Retry EOS input acquisition until a short deadline or explicitly fail finalization.

### V-165 · LOW · Accent switches rebuild the full G2P lexicon

- **Candidates:** CC-0466
- **Provenance:** `ios-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:238-246 — every language change calls setLanguage.
  - ios/Runner/KokoroVendored/TextProcessing/MisakiG2PProcessor.swift:14-20 — setLanguage constructs a new EnglishG2P for each US/GB switch.
- **Decision:** Alternating US and GB voices repeatedly reloads and parses the bundled dictionaries on the serial synthesis path, adding avoidable line latency and allocation churn.
- **Recommendation:** Cache one initialized G2P instance per supported language and switch references.

### V-166 · LOW · Accuracy report generator is a green test that mutates source

- **Candidates:** CC-2564, CC-2565, CC-2566, CC-2567, CC-2568, CC-2569, CC-2570, CC-2571, CC-2572
- **Provenance:** `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `testing-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - test/parser_accuracy_test.dart:245-287 — every per-file parse error is caught and written as an ERROR row with no assertion.
  - test/parser_accuracy_test.dart:294-300 — the test writes a tracked source-tree report and only prints it.
- **Decision:** The test remains green even if every report parse fails and an extended run dirties or requires write access to the checkout.
- **Recommendation:** Move report generation to a tool, or assert zero errors and write only to an explicit output path.

### V-167 · LOW · Acoustic harness scores before decoding settles

- **Candidates:** CC-0204
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/android_rehearsal_harness_test.dart:254-259 — acoustic scoring waits only 500 ms after endUtterance.
  - integration_test/android_rehearsal_harness_test.dart:261-289 — a low acoustic score switches to injected PCM, whose transcript is allowed to settle for two seconds.
- **Decision:** Slow real-device decoding can force the fallback before the acoustic transcript settles, masking speaker-to-mic regressions.
- **Recommendation:** Apply the same transcript-settle loop before acoustic scoring and report acoustic failure separately.

### V-168 · LOW · Adaptation debounce loses the last sample on a hard kill

- **Candidates:** CC-1094
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/stt_adaptation_service.dart:224 — defers writes for two seconds
  - lib/data/services/stt_adaptation_service.dart:345 — sample collection only schedules the debounce
- **Decision:** There is no lifecycle or synchronous flush, so an app termination during the final two-second window drops the latest collected sample.
- **Recommendation:** Flush dirty profiles on lifecycle pause/termination or persist each small append transactionally.

### V-169 · LOW · Adaptation hydration performs synchronous stats on the UI isolate

- **Candidates:** CC-1088, CC-1089, CC-1090
- **Provenance:** `metal-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `metal-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/stt_adaptation_service.dart:157 — hydration resumes on the calling isolate
  - lib/data/services/stt_adaptation_service.dart:170 — calls existsSync once per persisted sample
  - lib/features/recording_studio/recording_studio_screen.dart:206 — recording flow invokes addSample
- **Decision:** A production with hundreds of retained samples performs hundreds of blocking file metadata calls when first hydrated.
- **Recommendation:** Move sample validation to an isolate or use asynchronous/batched filesystem checks.

### V-170 · LOW · Adaptation persistence failures lack durable diagnostics

- **Candidates:** CC-1096
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/stt_adaptation_service.dart:256 — catches profile write failures
  - lib/data/services/stt_adaptation_service.dart:257 — reports only through debugPrint
- **Decision:** Disk-full or rename failures are hidden from the app field log and user, so samples can disappear after restart without actionable diagnostics.
- **Recommendation:** Log through DebugLogService and expose a nonblocking warning/retry state.

### V-171 · LOW · Add scene break action does not add a break

- **Candidates:** CC-1703
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/scene_editor_screen.dart:56 — AppBar presents an Add scene break action
  - lib/features/script_editor/scene_editor_screen.dart:351 — handler only opens an explanatory dialog
  - lib/features/script_editor/scene_editor_screen.dart:357 — dialog redirects the user elsewhere instead of performing the action
- **Decision:** The affordance promises a mutation but never performs one, creating a user-visible dead-end.
- **Recommendation:** Rename it to Help or navigate directly to an actual split/add flow.

### V-172 · LOW · Alias-normalization test passes even if aliasing breaks

- **Candidates:** CC-2596
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - test/script_parser_import_test.dart:150 — input already contains an ELIZABETH cue
  - test/script_parser_import_test.dart:152 — also contains the LIZZY alias
  - test/script_parser_import_test.dart:156 — only asserts ELIZABETH exists
- **Decision:** The assertion is satisfied by the first cue even if LIZZY remains a separate character.
- **Recommendation:** Assert LIZZY is absent and ELIZABETH owns both lines.

### V-173 · LOW · All unhandled async errors are marked fatal in Crashlytics

- **Candidates:** CC-2016, CC-2017
- **Provenance:** `db-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/main.dart:69-75 — PlatformDispatcher records every unhandled error with fatal: true and returns handled
- **Decision:** Recoverable asynchronous failures inflate fatal metrics and obscure actual process-ending incidents.
- **Recommendation:** Record unknown async errors non-fatally or classify known fatal boundaries explicitly.

### V-174 · LOW · Android capture reuses a stale deterministic take path

- **Candidates:** CC-1660
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:3002-3007 — Android starts capture at rehearsal_<line>.m4a without deleting it
  - lib/features/rehearsal/rehearsal_screen.dart:3033-3042 — the Apple capture path explicitly removes the same deterministic stale file first
- **Decision:** A failed Android capture can leave an earlier session’s file at the path later inspected/saved.
- **Recommendation:** Delete the deterministic file before startLineCapture, exactly as the sibling capture path does.

### V-175 · LOW · Android debug screen lists the wrong model directory

- **Candidates:** CC-1942
- **Provenance:** `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/kokoro_debug_screen.dart:53 — the screen resolves ModelManager.modelsDir
  - lib/features/settings/kokoro_debug_screen.dart:54 — it always appends kokoro_mlx
  - lib/data/services/model_manager.dart:44 — Android pack name is kokoro-en-fp16-v1_0
  - lib/data/services/model_manager.dart:57 — readiness checks that Android directory
- **Decision:** On Android the diagnostics card reports a nonexistent MLX directory even while the ONNX model being exercised is installed and ready.
- **Recommendation:** Select the active platform engine's ModelManager directory.

### V-176 · LOW · Android Kokoro RTF probe has no regression assertion

- **Candidates:** CC-0140
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/android_kokoro_rtf_test.dart:64 — duration is used only to print RTF
  - integration_test/android_kokoro_rtf_test.dart:72 — test completes with a print and no expect
- **Decision:** Empty or unusably slow output can still leave this probe green (including non-finite printed RTF).
- **Recommendation:** Assert nonempty samples, positive duration, and an explicit acceptable RTF bound.

### V-177 · LOW · Android physical footprint reports only ART heap

- **Candidates:** CC-0088, CC-0089, CC-0090, CC-0091, CC-0092, CC-0093
- **Provenance:** `android-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `kotlin-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/MemoryMonitorPlugin.kt:46-54 — physicalFootprintMB is Runtime totalMemory minus freeMemory
  - lib/data/services/debug_log_service.dart:203-213 — Dart stores that value under the physicalFootprintMB contract
  - lib/data/services/debug_log_service.dart:252-257 — current use is diagnostic logging, not an OCR allocation gate
- **Decision:** The value excludes native bitmap and ONNX allocations and is semantically inconsistent with a process footprint. Current reach is debug diagnostics, so the review’s OOM-control impact is overstated.
- **Recommendation:** Report process PSS/RSS for physicalFootprintMB, or rename the field and log label to ART heap used.

### V-178 · LOW · Android release configuration blocks debug-only builds without a keystore

- **Candidates:** CC-0014
- **Provenance:** `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/build.gradle.kts:55-67 — the release DSL throws while the android extension is configured whenever key.properties is absent
- **Decision:** Gradle configures build types before task execution, so the throw is not scoped to a release task and contradicts the debug-build guidance.
- **Recommendation:** Move the keystore requirement to release task execution or condition release signing without throwing during global configuration.

### V-179 · LOW · Any local take suppresses partner takes for shared lines

- **Candidates:** CC-0972
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/recording_sync_service.dart:392-405 — cloud download is skipped whenever localRecordings contains the line ID and its file exists.
- **Decision:** For ensemble lines, one user’s local take blocks the newest castmate take despite cloud rows being per user.
- **Recommendation:** Make playback/download selection user- and role-aware rather than line-only.

### V-180 · LOW · Any model constructor error deletes downloaded weights

- **Candidates:** CC-0372, CC-0373
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroMLXService.swift:110-118 — every KokoroTTS constructor error removes the safetensors file
- **Decision:** The catch does not distinguish verified corruption from transient I/O/resource failures, so recoverable failures can force a large re-download.
- **Recommendation:** Delete only after an integrity/parse diagnosis proves corruption; otherwise retain or quarantine the file and report the original error.

### V-181 · LOW · Apple STT logs script vocabulary hints verbatim

- **Candidates:** CC-0269, CC-0270, CC-0271, CC-0272, CC-0273, CC-0274
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/stt_service.dart:188 — application vocabulary hints are passed to the native channel
  - ios/Runner/AppleSttPlugin.swift:239 — hints become contextualStrings
  - ios/Runner/AppleSttPlugin.swift:240 — the first five strings are interpolated into NSLog
- **Decision:** Rehearsal vocabulary can contain private script content, and each listen persists a sample in unified device logs.
- **Recommendation:** Log only the hint count, never hint contents.

### V-182 · LOW · Async realtime unsubscribe errors escape the catch

- **Candidates:** CC-0986
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/recording_sync_service.dart:659-668 — unsubscribe is invoked without await inside a synchronous try/catch.
- **Decision:** A failed removeChannel future becomes an unhandled asynchronous error rather than the intended logged failure.
- **Recommendation:** Make unsubscribe async and await the service call inside the catch boundary.

### V-183 · LOW · Audit repeatedly rescans every OCR page for each far miss

- **Candidates:** CC-0229, CC-0230, CC-0231, CC-0232, CC-0233
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/ocr_highlight_audit_macos_test.dart:69 — work repeats for every parsed line
  - integration_test/ocr_highlight_audit_macos_test.dart:93 — every far miss loops across all pages
  - integration_test/ocr_highlight_audit_macos_test.dart:94 — each probe reruns OcrHighlightMatcher.locate
- **Decision:** The bundled multi-page scan and hundreds of flagged lines are a realistic trigger for repeated tokenization and matching in this already timeout-bound offline audit.
- **Recommendation:** Pre-index or pre-normalize page lines once for diagnostic far-page lookup.

### V-184 · LOW · Audit tools create persistent known-password production accounts

- **Candidates:** CC-2680, CC-2683, CC-2684, CC-2686, CC-2687, CC-2688, CC-2689
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tool/analyze_orphaned_recordings.dart:26-35 — each run signs up a random @example.com account with a fixed committed password
  - tool/analyze_orphaned_recordings.dart:112-120 — cleanup removes only membership, not auth.users
  - supabase/migrations/20260703090000_leave_policy_and_audit_cleanup.sql:10-17 — a prior one-time migration documents and purges this exact accumulation, but current tools can recreate it
- **Decision:** Operator runs continue creating durable junk auth users secured by a repository-known password; failed cleanup can also leave memberships.
- **Recommendation:** Use dedicated accounts or random per-run credentials and an administrator cleanup path that deletes created auth users.

### V-185 · LOW · Authentication trims password credentials

- **Candidates:** CC-1327, CC-1328, CC-1329, CC-1330, CC-1331, CC-1332, CC-1333, CC-1334
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/auth/auth_screen.dart:313 — email is trimmed separately
  - lib/features/auth/auth_screen.dart:314 — password text is also trimmed
  - lib/features/auth/auth_screen.dart:328 — the altered password is used for signup
  - lib/features/auth/auth_screen.dart:343 — the altered password is used for signin
- **Decision:** An account created by another Supabase client with leading or trailing password whitespace cannot authenticate through this app; signup also silently changes what the user entered.
- **Recommendation:** Trim email only and validate/pass the raw password text.

### V-186 · LOW · Back-to-back cues are misread as dialogue

- **Candidates:** CC-2164, CC-2165
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/compare_macbeth_versions.py:39 — parser takes the next nonempty line unconditionally
  - scripts/compare_macbeth_versions.py:44 — that line is appended as dialogue without checking if it is another cue
- **Decision:** A cue with no intervening text causes the next speaker cue to be attributed as dialogue and then skipped.
- **Recommendation:** Before appending dialogue, test the candidate line against the cue/header pattern without consuming it.

### V-187 · LOW · Background relaunch resets automatic retry budget

- **Candidates:** CC-0319
- **Provenance:** `ios-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/BackgroundDownloadPlugin.swift:86 — restoredDownloadInfo reconstructs state
  - ios/Runner/BackgroundDownloadPlugin.swift:94 — reconstruction omits retryCount, defaulting it to zero
- **Decision:** Repeated process relaunches allow a permanently failing transfer to receive a fresh retry budget instead of honoring the documented maximum.
- **Recommendation:** Persist retryCount with the download record and restore it.

### V-188 · LOW · Bare orphan audit targets and mutates a committed production UUID

- **Candidates:** CC-2685
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tool/analyze_orphaned_recordings.dart:22-28 — no-argument execution uses a committed production UUID and creates a throwaway account
  - tool/analyze_orphaned_recordings.dart:40-51 — it inserts a membership into that production
- **Decision:** Running the operator command without an argument changes a real default production instead of failing closed.
- **Recommendation:** Require productionId explicitly and print the target before confirmation/mutation.

### V-189 · LOW · Broad margin-noise regex deletes valid dialogue substrings

- **Candidates:** CC-2208, CC-2209
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `python-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/parse_script.py:102-109 — MARGIN_NOISE contains an unanchored broad uppercase/lowercase/uppercase alternative
  - scripts/parse_script.py:123-133 — clean_line applies substitution to every line
  - scripts/parse_script.py:205-210 — assembled dialogue is cleaned before output
- **Decision:** Legitimate dialogue matching that shape can be silently removed, not merely classified as a margin annotation.
- **Recommendation:** Apply annotation patterns only to whole short suspect lines or anchor/remove the broad fallback alternative.

### V-190 · LOW · Bulk contact-picker failures are invisible to the user

- **Candidates:** CC-1347, CC-1348, CC-1349, CC-1350
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:248 — the contact suffix button enters _pickContact
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:256 — all picker errors are caught
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:257 — the catch only debugPrints
- **Decision:** Denied contact permission or a platform-channel failure makes the button appear to do nothing, with no recovery instruction.
- **Recommendation:** Show the same permission/error toast used by the single-assignment screen and log the exception.

### V-191 · LOW · Bulk likely-not-script removal has no confirmation or undo

- **Candidates:** CC-1812
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_import/ocr_review_screen.dart:1013 — one button controls removal of the full remaining set
  - lib/features/script_import/ocr_review_screen.dart:1014 — it calls _removeAllNotScript immediately
  - lib/features/script_import/ocr_review_screen.dart:438 — the handler marks every line removed without confirmation
  - lib/features/script_import/ocr_review_screen.dart:454 — removed lines are omitted from the committed result
- **Decision:** A single accidental tap can drop hundreds of imported lines and the screen offers neither confirmation nor undo.
- **Recommendation:** Confirm the bulk count and provide an undo opportunity before commit.

### V-192 · LOW · Bulk setup calls setState after long awaits without mounted checks

- **Candidates:** CC-1345, CC-1346, CC-1370, CC-1371, CC-1372, CC-1374, CC-1375, CC-1377, CC-1378, CC-1379
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:250 — contact picker awaits a system UI
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:255 — its result calls setState without mounted
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:319 — save awaits serial network/database work
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:320 — save completion calls setState before the mounted check at line 322
- **Decision:** The AppBar remains poppable while either operation is in flight; returning after disposal produces setState-called-after-dispose framework errors.
- **Recommendation:** Check mounted immediately after each await and before touching controllers, state, or context.

### V-193 · LOW · Cache pruning can remove a just-returned cache hit

- **Candidates:** CC-0396
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroMLXService.swift:171-177 — pruning is scheduled before a cache-hit path is touched and returned
  - ios/Runner/KokoroMLXService.swift:340-365 — the utility pass concurrently enumerates and deletes cache entries
- **Decision:** When over the cap, the asynchronous prune can select the same file before its modification date is refreshed, returning a path that playback can no longer open.
- **Recommendation:** Touch/pin the cache hit before scheduling prune, or recheck existence after pruning and synthesize on a miss.

### V-194 · LOW · Capture-loop exceptions leave ambiguous partial recording state

- **Candidates:** CC-0054
- **Provenance:** `kotlin-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:415 — capture errors only emit onError
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:448 — stop later treats any nonempty file as success
- **Decision:** A partially muxed file can be returned as a successful take after a capture error because the stop result does not retain the failure state.
- **Recommendation:** Record the terminal capture error and make stopRecording return an error/discard the partial file.

### V-195 · LOW · Capture-save action silently no-ops after production state is lost

- **Candidates:** CC-1652
- **Provenance:** `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:3127 — save prompt is latched once
  - lib/features/rehearsal/rehearsal_screen.dart:3152 — action invokes save
  - lib/features/rehearsal/rehearsal_screen.dart:3165 — production is read at save time
  - lib/features/rehearsal/rehearsal_screen.dart:3166 — null production returns with no feedback or cleanup
- **Decision:** If production state clears before save, repeated button actions do nothing while captured files remain and no discard/recovery path is surfaced.
- **Recommendation:** Show an actionable error and preserve/rebind or explicitly offer discard; do not silently return.

### V-196 · LOW · Cast gender UI reads a different source than voice assignment

- **Candidates:** CC-1446
- **Provenance:** `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/cast_manager/cast_manager_screen.dart:75 — automatic voice assignment receives _genderOverrides
  - lib/features/cast_manager/cast_manager_screen.dart:479 — icon renders char.gender
  - lib/features/cast_manager/cast_manager_screen.dart:1176 — toggle also cycles from char.gender
- **Decision:** A persisted override can drive one voice gender while a refreshed script character renders another; the next tap cycles from the stale displayed base.
- **Recommendation:** Compute displayed/toggled gender as _genderOverrides[char.name] ?? char.gender and keep persistence synchronized.

### V-197 · LOW · Cast migration reads WidgetRef after load await

- **Candidates:** CC-1683
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/character_manager_screen.dart:641 — cast loading is awaited
  - lib/features/script_editor/character_manager_screen.dart:642 — ref is read immediately afterward without mounted check
- **Decision:** Leaving during rename migration can throw from the disposed ConsumerState ref after the script rename already committed.
- **Recommendation:** Snapshot notifier/state safely or check mounted before the post-await ref read.

### V-198 · LOW · Cast sync can use WidgetRef after disposal

- **Candidates:** CC-1389
- **Provenance:** `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/cast_manager/cast_manager_screen.dart:87 — post-frame callback reads ref without mounted check
  - lib/features/cast_manager/cast_manager_screen.dart:103 — cloud sync awaits network
  - lib/features/cast_manager/cast_manager_screen.dart:104 — ref is read immediately after the await
  - lib/features/cast_manager/cast_manager_screen.dart:132 — ref is read again later
- **Decision:** Leaving the screen before the callback or cloud request finishes can access a disposed ConsumerState ref.
- **Recommendation:** Check mounted before callback/post-await ref use, or snapshot long-lived notifiers before awaiting.

### V-199 · LOW · Character export drops scene headers within an act

- **Candidates:** CC-1004, CC-1005, CC-1006
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/script_export.dart:202 — currentAct starts as an empty string
  - lib/data/services/script_export.dart:205 — headers emit only when line.act changes
  - lib/data/services/script_export.dart:209 — every header then continues whether emitted or not
- **Decision:** Multiple scene/header lines sharing one act, and initial headers with empty act, are silently omitted.
- **Recommendation:** Emit each header or track a stable header identity rather than act alone.

### V-200 · LOW · Claimed prefilled invite silently degrades to characterless join

- **Candidates:** CC-1479
- **Provenance:** `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/join/join_production_screen.dart:406 — prefill selects only rows whose user_id is null
  - lib/features/join/join_production_screen.dart:457 — null selection becomes an empty character
  - lib/features/join/join_production_screen.dart:493 — empty selection enters self-join without warning
- **Decision:** If the invited role was claimed before lookup, the recipient can press Join and silently join without the intended role instead of being asked to choose.
- **Recommendation:** Surface an explicit role-unavailable state and require a deliberate alternative selection.

### V-201 · LOW · Cloud cast sync performs serial per-member writes

- **Candidates:** CC-1390, CC-1391, CC-1392, CC-1393, CC-1394
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/cast_manager/cast_manager_screen.dart:103 — every open fetches the full cloud cast
  - lib/features/cast_manager/cast_manager_screen.dart:107 — every cloud member is visited
  - lib/features/cast_manager/cast_manager_screen.dart:127 — each notifier save is awaited serially
  - lib/features/cast_manager/cast_manager_screen.dart:145 — removals are also serial notifier operations
- **Decision:** Open latency and provider emissions scale with cast size even when cloud rows are unchanged.
- **Recommendation:** Diff cloud/local state and apply one batched Drift write and provider update.

### V-202 · LOW · Cloud diff hides pure line reordering

- **Candidates:** CC-1695
- **Provenance:** `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/cloud_sync_dialog.dart:22-51 — lines are matched by id and sameness omits orderIndex/lineNumber
  - lib/features/script_editor/cloud_sync_dialog.dart:27-29,73-88 — cloud order drives output, but unchanged lines are excluded from the visible change list
- **Decision:** A cloud-only reorder of otherwise identical lines yields an all-unchanged summary, so the conflict dialog reports no changes despite changed sequence.
- **Recommendation:** Compare ordering metadata or emit a moved DiffType when matched IDs change position.

### V-203 · LOW · Cloud pull uses WidgetRef after asynchronous gaps

- **Candidates:** CC-1521, CC-1522, CC-1523
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/production_hub/production_hub_screen.dart:802 — cloud fetch is awaited
  - lib/features/production_hub/production_hub_screen.dart:812 — parsed script/scenes are awaited
  - lib/features/production_hub/production_hub_screen.dart:829 — optional dialog adds another await
  - lib/features/production_hub/production_hub_screen.dart:846 — ref is accessed without a final mounted check
- **Decision:** Navigating away mid-pull produces disposed-ref failure and discards the fetched script.
- **Recommendation:** Snapshot safe notifiers before await where supported and check mounted immediately before every state/ref operation.

### V-204 · LOW · Cloud refresh compares against another production before scope guard

- **Candidates:** CC-1458
- **Provenance:** `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/home/home_screen.dart:311 — cloud lines are fetched asynchronously
  - lib/features/home/home_screen.dart:314 — currentScript is read before checking production identity
  - lib/features/home/home_screen.dart:337 — production scope is checked only at the final in-memory assignment
- **Decision:** Switching productions during fetch can make equality or truncation checks use the other production’s script and incorrectly skip the fetched production’s local refresh.
- **Recommendation:** Check current production before comparisons, or load the persisted script for production.id rather than shared state.

### V-205 · LOW · Comparison script relies on locale-default text encoding

- **Candidates:** CC-2166
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/compare_macbeth_versions.py:55 — read_text omits encoding
  - scripts/compare_macbeth_versions.py:73 — Folger output read also omits encoding
  - scripts/pdf_to_script.py:363 — output write omits encoding
- **Decision:** On systems whose locale encoding is not UTF-8, Shakespeare text with typographic punctuation can decode/write incorrectly or throw.
- **Recommendation:** Specify encoding="utf-8" for all known UTF-8 inputs and outputs.

### V-206 · LOW · Completed background transfer can be silently dropped without state

- **Candidates:** CC-0343
- **Provenance:** `ios-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/BackgroundDownloadPlugin.swift:198 — completion requires in-memory or persisted info
  - ios/Runner/BackgroundDownloadPlugin.swift:199 — missing state only logs and returns
- **Decision:** If records are cleared or corrupted while the system task survives, iOS deletes the callback temp location after the delegate returns and the completed payload is lost without a Flutter error.
- **Recommendation:** Cancel tasks when clearing records, or emit an error and recover destination metadata from task.originalRequest/state.

### V-207 · LOW · Concurrent contact picks overwrite the pending channel result

- **Candidates:** CC-0067, CC-0068, CC-0069, CC-0070, CC-0071, CC-0072, CC-0074, CC-0075, CC-0076, CC-0077, CC-0078
- **Provenance:** `android-review@deepinfra-zai-org-glm-5.3-flash`, `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `kotlin-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `kotlin-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:59 — every pick assigns pendingResult unconditionally
  - android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:70 — only the currently stored result is completed
- **Decision:** Two invocations before the picker returns strand the first MethodChannel.Result and can deliver the first activity result to the wrong caller.
- **Recommendation:** Reject a second pick while pendingResult is non-null and clear/complete pending work on lifecycle teardown.

### V-208 · LOW · Contact picker can orphan a pending Flutter result on reentry

- **Candidates:** CC-0351, CC-0353, CC-0354, CC-0355, CC-0356, CC-0357, CC-0358, CC-0359, CC-0360, CC-0361, CC-0362, CC-0363
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/ContactPickerPlugin.swift:33 — unconditionally overwrites pendingResult
  - ios/Runner/ContactPickerPlugin.swift:39 — stores the result before the no-view-controller guard
  - lib/features/cast_manager/cast_manager_screen.dart:699 — contact picker button has no in-flight guard
- **Decision:** A rapid second tap while the first picker is presented replaces the first callback, so the first Dart Future can hang and the first picker can resolve the wrong call. The error guard also retains an already-completed closure.
- **Recommendation:** Reject reentry while pending, assign only after presentation preconditions pass, and clear pendingResult on every terminal path.

### V-209 · LOW · Contact picker retains activity-result listeners

- **Candidates:** CC-0066
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:40 — attachment registers this as an activity-result listener
  - android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:45 — config-change detach only nulls activity
  - android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:50 — final detach also only nulls activity
- **Decision:** The plugin never removes the listener from the old ActivityPluginBinding, so reattachment can retain stale bindings/listeners.
- **Recommendation:** Store the binding and remove this listener in both detach callbacks.

### V-210 · LOW · Contact provider queries run on the Android main thread

- **Candidates:** CC-0081, CC-0082, CC-0083
- **Provenance:** `android-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `android-performance-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:67 — onActivityResult handles the result synchronously
  - android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:90 — the contact query starts directly in that callback
  - android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:103 — phone and email provider queries are also synchronous
- **Decision:** Every successful pick performs up to three binder/provider queries on the UI thread, so a slow provider can stall the resume frame.
- **Recommendation:** Run provider reads on a worker executor and post the MethodChannel result back to main.

### V-211 · LOW · Context-line confirmation can return after screen disposal

- **Candidates:** CC-1797
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_import/ocr_review_screen.dart:205 — _removeContextLine awaits showDialog
  - lib/features/script_import/ocr_review_screen.dart:228 — confirmed result is handled after the await
  - lib/features/script_import/ocr_review_screen.dart:229 — setState has no mounted guard
- **Decision:** If the review route is removed programmatically while the dialog resolves, its continuation calls setState on a disposed State.
- **Recommendation:** Check mounted after showDialog returns.

### V-212 · LOW · Converter subprocess has no timeout and buffers all output

- **Candidates:** CC-2167, CC-2168, CC-2169
- **Provenance:** `observability-review@deepinfra-zai-org-glm-5.3-flash`, `python-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `python-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/compare_macbeth_versions.py:62 — subprocess.run has no timeout
  - scripts/compare_macbeth_versions.py:67 — capture_output buffers both streams
- **Decision:** A malformed/large PDF or stuck converter can block the operator indefinitely; verbose output is also fully retained.
- **Recommendation:** Set a bounded timeout, handle TimeoutExpired, and stream or cap diagnostics.

### V-213 · LOW · Corrupt empty voices file remains installed forever

- **Candidates:** CC-0371, CC-0375
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroMLXService.swift:50-55 — downloaded status is file-existence based
  - ios/Runner/KokoroMLXService.swift:120-125 — an unreadable/empty voices file clears the engine and throws but is not deleted
- **Decision:** The same bad voices.npz is retried on every load while the UI continues to see both files present.
- **Recommendation:** Delete or quarantine the failed voices file and surface it as needing re-download.

### V-214 · LOW · Crashlytics handlers replace default reporting without a fallback

- **Candidates:** CC-2015
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/main.dart:61-75 — both global handlers are replaced and route solely to Crashlytics/debug log
  - lib/main.dart:63-67 — FlutterError.presentError is not chained
- **Decision:** Framework errors lose the normal presentation path, and any asynchronous Crashlytics recording failure has no local fallback beyond the preceding short message.
- **Recommendation:** Chain FlutterError.presentError in debug/local diagnostics and treat Crashlytics recording as best-effort.

### V-215 · LOW · CRLF word lists retain carriage returns

- **Candidates:** CC-2800
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tools/mlx-harness/Sources/harness/main.swift:53 — words are split only on newline
  - tools/mlx-harness/Sources/harness/main.swift:59 — retained carriage return maps to unknown token 3
- **Decision:** A Windows-style words file adds an unknown token to every word and can change model output silently.
- **Recommendation:** Use split(whereSeparator: \.isNewline) or trim newline/control whitespace per word.

### V-216 · LOW · Cue export chooses invalid previous-line cues

- **Candidates:** CC-1009, CC-1010, CC-1011
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/script_export.dart:243 — headers/scenes are removed before cue selection
  - lib/data/services/script_export.dart:252 — every actor line uses the immediately previous filtered dialogue
  - lib/data/services/script_export.dart:253 — no same-character or same-scene check is made
- **Decision:** Consecutive actor lines use the actor’s own prior line as a cue, and first lines of scenes can use the preceding scene’s final line.
- **Recommendation:** Skip self-cues and prevent cue search from crossing act/scene boundaries.

### V-217 · LOW · Cue regex counts act/scene headings as characters

- **Candidates:** CC-2163
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/compare_macbeth_versions.py:22 — any all-caps dotted line is accepted as a cue
  - scripts/compare_macbeth_versions.py:36 — dialogue block parsing repeats the same broad regex
- **Decision:** Lines such as ACT I. and SCENE I. satisfy the pattern and inflate reported character/cue comparisons.
- **Recommendation:** Share parser-aware cue detection and explicitly exclude structural headings.

### V-218 · LOW · Curly quotes are incorrectly included in non-quote punctuation

- **Candidates:** CC-0524, CC-0525
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/EnglishG2P.swift:14-23 — punctuation includes curly quotes but the filter excludes only ASCII quote
  - ios/Runner/MisakiVendored/English/EnglishG2P.swift:53-61 — non-quote punctuation resets future vowel context
- **Decision:** Curly quotes take punctuation-reset semantics despite the set name and quote-specific phoneme mapping, changing context-sensitive pronunciations.
- **Recommendation:** Exclude ASCII and curly quote characters from nonQuotePunctuations.

### V-219 · LOW · Debug init/reload actions let exceptions escape without status feedback

- **Candidates:** CC-1939, CC-1948
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/kokoro_debug_screen.dart:94 — _tryInit begins without a try/catch
  - lib/features/settings/kokoro_debug_screen.dart:96 — TtsService.init is awaited directly
  - lib/features/settings/kokoro_debug_screen.dart:101 — _tryReload also has no try/catch
  - lib/features/settings/kokoro_debug_screen.dart:103 — tryLoadKokoro is awaited before any completion log
- **Decision:** A platform/System TTS initialization exception terminates the button callback and never writes the diagnostic error the screen exists to expose.
- **Recommendation:** Catch each action, log an ERROR line, and restore any action state in finally.

### V-220 · LOW · Debug log UI freezes once the ring buffer reaches capacity

- **Candidates:** CC-1910, CC-1911
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/settings/debug_log_screen.dart:25-40 — refresh dirty-check compares only entryCount
  - lib/data/services/debug_log_service.dart:224-230 — entryCount is bounded entries length
- **Decision:** Once each new entry evicts an old one, length remains constant and the screen never rebuilds for replacement entries.
- **Recommendation:** Expose and compare a monotonic log sequence or newest-entry identity.

### V-221 · LOW · Deleting a production leaves its imported PDF

- **Candidates:** CC-0761
- **Provenance:** `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/repositories/production_repository.dart:43 — deletion only enumerates recording files
  - lib/data/repositories/production_repository.dart:60 — the production row is deleted without touching scriptPath
  - lib/data/models/production_models.dart:8 — scriptPath is the local original PDF path
- **Decision:** The app-owned Documents/scripts PDF survives production deletion and accumulates storage.
- **Recommendation:** Best-effort delete the owned scriptPath/deterministic script file after the DB commit.

### V-222 · LOW · Deleting the active recording leaves playback state running

- **Candidates:** CC-1581
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/recording_studio/recordings_browser_screen.dart:316 — active state is keyed by line ID
  - lib/features/recording_studio/recordings_browser_screen.dart:490 — delete begins without stopping the player
  - lib/features/recording_studio/recordings_browser_screen.dart:517 — local file can be deleted
  - lib/features/recording_studio/recordings_browser_screen.dart:529 — UI completion does not clear _playingLineId
- **Decision:** Deleting the playing take neither stops playback nor clears the active indicator, leaving stale controls and playback on an unlinked file handle.
- **Recommendation:** Stop/clear playback before deleting the active line.

### V-223 · LOW · Deleting the last line can invert clamp bounds

- **Candidates:** CC-1693, CC-1694
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/character_manager_screen.dart:703 — delete can produce an empty updatedLines list
  - lib/features/script_editor/character_manager_screen.dart:760 — clamp upper bound becomes -1 with lower bound 0
- **Decision:** A minimal one-character/one-line script with a scene throws ArgumentError during rebuild instead of saving empty state.
- **Recommendation:** Special-case empty updatedLines and return an empty/remapped scene list before clamping.

### V-224 · LOW · Deploy claims launch success after suppressing failure

- **Candidates:** CC-2193
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/deploy.sh:23-26 — launch output/status is discarded with || true before an unconditional deployed + launched message.
- **Decision:** A launch refusal or immediate command failure is reported as successful launch.
- **Recommendation:** Report install and launch statuses separately and preserve launch diagnostics.

### V-225 · LOW · Deploy hides most build failure diagnostics

- **Candidates:** CC-2180
- **Provenance:** `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/deploy.sh:13-16 — release build output is piped through tail -4 under pipefail.
- **Decision:** The command fails correctly, but the useful signing/compiler error can be hundreds of lines before the only output retained.
- **Recommendation:** Capture full output to a log and print a concise tail only on success; show relevant failure output on error.

### V-226 · LOW · Deploy install probe is vulnerable to pipefail SIGPIPE

- **Candidates:** CC-2181, CC-2182, CC-2183, CC-2184, CC-2185, CC-2186, CC-2187, CC-2188, CC-2189, CC-2190, CC-2191, CC-2192
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `shell-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `shell-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/deploy.sh:7 — pipefail is enabled.
  - scripts/deploy.sh:21-30 — devicectl output is piped to grep -q and a nonzero pipeline retries/fails the install.
- **Decision:** If devicectl emits more output after the success marker, grep exits early, the producer can receive SIGPIPE, and pipefail classifies a successful install as failed.
- **Recommendation:** Capture command output/status first, then search the completed output.

### V-227 · LOW · Destination is destroyed before replacement move succeeds

- **Candidates:** CC-0344, CC-0345
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/BackgroundDownloadPlugin.swift:205 — existing completed model is removed first
  - ios/Runner/BackgroundDownloadPlugin.swift:206 — replacement move can then throw
- **Decision:** A filesystem failure during move leaves neither the prior valid model nor the newly downloaded temp file.
- **Recommendation:** Use an atomic replace/backup sequence and remove the old file only after the new file is safely installed.

### V-228 · LOW · Dialect cloud writes are unawaited and unobserved

- **Candidates:** CC-1855, CC-1856, CC-1857, CC-1859, CC-1860, CC-1861, CC-1862
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_import/script_import_screen.dart:361-378 — saveLocale and saveVoicePreset Futures are neither awaited nor given error handlers after local state changes
- **Decision:** Network/RLS failures surface as uncaught asynchronous errors and leave cloud locale/preset stale with no log or retry.
- **Recommendation:** Await both writes inside a guarded async handler, or use unawaited with catchError that logs and queues retry.

### V-229 · LOW · Dialog navigation test does not exercise production code

- **Candidates:** CC-2546
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - test/dialog_navigation_test.dart:22 — builds a standalone synthetic app
  - test/dialog_navigation_test.dart:73 — supplies a hand-written callback containing the fix
  - test/dialog_navigation_test.dart:78 — asserts navigation through that copied callback
- **Decision:** Reverting HomeScreen._submitProduction would not affect this test, so the documented production regression could recur while it stays green.
- **Recommendation:** Extract the navigation workflow into a testable production helper or drive the real HomeScreen dialog handler.

### V-230 · LOW · Direction-only inline dialogue is duplicated into text

- **Candidates:** CC-2210
- **Provenance:** `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/parse_script.py:176-184 — inline extraction can return an empty dialogue
  - scripts/parse_script.py:213-226 — empty dialogue falls back to full_text while also storing stage_direction
- **Decision:** A cue containing only an inline direction emits the same direction both as metadata and spoken dialogue text.
- **Recommendation:** Emit an empty dialogue or a standalone stage-direction record when extraction consumes the whole text.

### V-231 · LOW · Download consent persistence is fire-and-forget

- **Candidates:** CC-1499, CC-1500
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/onboarding/model_setup_screen.dart:130 — SharedPreferences acquisition is chained without await
  - lib/features/onboarding/model_setup_screen.dart:131 — setBool has no catch handler
- **Decision:** A preferences failure is unhandled and silently loses the user’s auto-download choice.
- **Recommendation:** Await the write in try/catch and log failure before starting downloads.

### V-232 · LOW · Editor saves rewrite every script row

- **Candidates:** CC-0798, CC-0799
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/repositories/production_repository.dart:121 — saveScriptLines maps every line to a companion
  - lib/data/repositories/production_repository.dart:142 — each save deletes all rows then reinserts the full list
  - lib/providers/production_providers.dart:323 — editor persistence is debounced but still invokes full-script save
- **Decision:** Each editor save performs O(total script lines) deletes/inserts and invalidates watchers even for a small edit.
- **Recommendation:** Diff by stable line id and batch only inserts, updates, and removals in one transaction.

### V-233 · LOW · Editor walkthrough test never exercises the documented walkthrough

- **Candidates:** CC-2595
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - test/script_editor_walkthrough_test.dart:23-25 — file claims to test Prev/Looks right/Next walkthrough behavior
  - test/script_editor_walkthrough_test.dart:41-79 — tests only filter-chip presence/absence and no exception
- **Decision:** The regression path named by the file can break while both tests remain green.
- **Recommendation:** Open the line-edit sheet and exercise previous, accept, and next transitions across boundaries.

### V-234 · LOW · English G2P recompiles a fixed link regex per utterance

- **Candidates:** CC-0528, CC-0529, CC-0530, CC-0531, CC-0532, CC-0533, CC-0534, CC-0535, CC-0536
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-performance-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/EnglishG2P.swift:30-32 — another fixed regex is hoisted statically
  - ios/Runner/MisakiVendored/English/EnglishG2P.swift:137-152 — preprocess constructs the same NSRegularExpression on every call
- **Decision:** Every preprocessed utterance pays avoidable ICU regex construction and allocation. The literal pattern itself is valid, so try! is not a realistic malformed-input crash.
- **Recommendation:** Hoist linkRegex to a static let beside subtokenizeRegex.

### V-235 · LOW · Every STT partial scans all learned corrections with regex replaceAll

- **Candidates:** CC-1164, CC-1165, CC-1166, CC-1167, CC-1168, CC-1169
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `metal-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `metal-performance-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/stt_vocabulary_service.dart:173 — correct iterates every actor correction
  - lib/data/services/stt_vocabulary_service.dart:174 — each entry performs a full-string replaceAll
  - lib/data/services/stt_vocabulary_service.dart:234 — the map may grow to 500 entries
  - lib/data/services/stt_service.dart:190 — correction is fed by streaming recognition callbacks
- **Decision:** An actor can accumulate hundreds of corrections over a long play, making each partial perform hundreds of regex scans and allocations on the main isolate.
- **Recommendation:** Apply whole-token corrections in one token pass or compile one combined matcher per actor.

### V-236 · LOW · Expected-line correction rebuilds quadratic alignment for every partial

- **Candidates:** CC-1186, CC-1187, CC-1188, CC-1189
- **Provenance:** `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `metal-performance-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/stt_vocabulary_service.dart:382 — comments confirm this runs per partial on the main isolate
  - lib/data/services/stt_vocabulary_service.dart:387 — allocation scales with recognized words times expected words
  - lib/data/services/stt_vocabulary_service.dart:389 — every cell computes a capped edit distance
  - lib/data/services/stt_vocabulary_service.dart:407 — backtracking recomputes comparisons
- **Decision:** Long monologue lines make each streaming partial rebuild thousands of DP cells and edit-distance work on the UI isolate, a realistic source of rehearsal jank.
- **Recommendation:** Cache incremental/prefix alignment or move bounded alignment work off the UI isolate.

### V-237 · LOW · Extended parser suite is not excluded by configuration

- **Candidates:** CC-2556, CC-2557
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `testing-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - test/parser_accuracy_test.dart:1-9 — the suite is tagged extended and claims normal flutter test skips it.
  - dart_test.yaml:1-5 — the tag is declared but no skip/exclusion configuration is attached; the file itself says full suite is flutter test.
- **Decision:** The claimed default exclusion depends on a manually supplied CLI flag and is not enforced by repository configuration.
- **Recommendation:** Encode the intended default command in CI/task tooling or correct the comments to match actual behavior.

### V-238 · LOW · Extracted Kokoro files are trusted by existence only

- **Candidates:** CC-0892
- **Provenance:** `gcp-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/model_manager.dart:55 — readiness checks existence only
  - lib/data/services/model_manager.dart:110 — an existing ready set skips redownload
- **Decision:** A truncated individual extracted file can persist after interruption and indefinitely bypass repair even though the archive was originally hash-checked.
- **Recommendation:** Use an extraction manifest/atomic directory swap and validate required file sizes or hashes.

### V-239 · LOW · Failed audit self-join does not abort analysis

- **Candidates:** CC-2694
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tool/analyze_orphaned_recordings.dart:38-54 — insert failure is printed but execution continues
  - tool/analyze_orphaned_recordings.dart:56-82 — subsequent RLS-limited reads still print matched/orphan counts
- **Decision:** A denied membership can produce empty/truncated reads and a misleading clean-looking orphan report.
- **Recommendation:** Exit nonzero immediately when required membership cannot be established.

### V-240 · LOW · Failed ML Kit image conversion leaks native images

- **Candidates:** CC-1032, CC-1033
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/script_import_service.dart:466-479 — pdfImage is disposed only after createImage succeeds and image only after toByteData succeeds.
  - lib/data/services/script_import_service.dart:515-517 — the per-page catch skips cleanup after either throw.
- **Decision:** Intermittent conversion failures can retain page-sized native images across a long scan.
- **Recommendation:** Use nested try/finally blocks that dispose both handles on every exit.

### V-241 · LOW · Failing repository assertion can leak its temp file

- **Candidates:** CC-2578
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - test/production_repository_test.dart:145 — keepFile is persisted as fixture data
  - test/production_repository_test.dart:156 — assertions run before cleanup
  - test/production_repository_test.dart:158 — deletion is inline and skipped if an expectation throws
- **Decision:** A failing test leaves the file in shared system temp storage and can contaminate repeated runs.
- **Recommendation:** Register deletion with addTearDown before assertions.

### V-242 · LOW · Fallback commit deletes the picker-owned PDF

- **Candidates:** CC-1882
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_import/script_import_screen.dart:621-624 — commit deletes whatever path is in _importedPdfPath
  - lib/features/script_import/script_import_screen.dart:694-701 — staging failure stores the original picked file path and still marks it pending commit
- **Decision:** When staging copy fails, successful acceptance deletes the picker’s own source after copying it, contrary to the fallback’s preservation assumption.
- **Recommendation:** Track whether the path is an owned staging file and delete only owned temporary copies.

### V-243 · LOW · Filtered reorder mutates hidden full-list positions

- **Candidates:** CC-1742
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:414-420 — reorder mode remains active when only the low-OCR filtered list is shown.
  - lib/features/script_editor/script_editor_screen.dart:608-628 — filtered source/target IDs are spliced into the full script list.
- **Decision:** Dragging among flagged lines produces order changes relative to hidden lines that the user cannot predict.
- **Recommendation:** Disable reorder while filtered or define and display filtered-reorder semantics.

### V-244 · LOW · Fixed model-download deadline times out healthy slow transfers

- **Candidates:** CC-1504
- **Provenance:** `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/onboarding/model_setup_screen.dart:163 — one absolute 15-minute deadline is created
  - lib/features/onboarding/model_setup_screen.dart:164 — progress does not reset it
  - lib/features/onboarding/model_setup_screen.dart:166 — crossing it reports timeout while native transfer can continue
- **Decision:** A slow but progressing 180 MB download can be labeled failed at 15 minutes.
- **Recommendation:** Use a stall timeout reset by progress, or expose background continuation without declaring failure.

### V-245 · LOW · Folger conversion repeatedly extracts full page dictionaries

- **Candidates:** CC-2227, CC-2228, CC-2229, CC-2230, CC-2231, CC-2232
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`, `python-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `python-performance-review@deepinfra-zai-org-glm-5.3-flash`, `x86-simd-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `x86-simd-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/pdf_to_script.py:127 — character detection scans every page dict
  - scripts/pdf_to_script.py:155 — play-start search scans dicts again
  - scripts/pdf_to_script.py:179 — main extraction scans them a third time
- **Decision:** Each conversion performs up to three expensive layout extractions over the document, with work scaling linearly per pass.
- **Recommendation:** Cache per-page extracted dictionaries/text and reuse them across detection and extraction.

### V-246 · LOW · Full PDF OCR buffers the entire result in one platform reply

- **Candidates:** CC-0127, CC-0128, CC-0129, CC-0130
- **Provenance:** `android-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:217-249 — every page map accumulates in pages and the whole list is posted in one result.success
  - lib/data/services/paddle_ocr_channel.dart:110-133 — Dart materializes the full nested page/line result
- **Decision:** Memory and platform-channel serialization grow with arbitrary PDF page and line counts; current scripts make impact usually moderate, but there is no bound.
- **Recommendation:** Stream page results or process bounded page batches rather than returning one cumulative document map.

### V-247 · LOW · Full PDF OCR is unbounded and non-cancellable

- **Candidates:** CC-0131
- **Provenance:** `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:217-244 — the loop processes renderer.pageCount without a page limit or cancellation check
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:276-281 — comments document seconds of compute per page
- **Decision:** A user-selected very long PDF can run for minutes while consuming CPU/battery even after the UI no longer needs the import.
- **Recommendation:** Add cooperative cancellation and either a page cap or page-batched API.

### V-248 · LOW · G2P feature alignment scales as features times tokens

- **Candidates:** CC-0548, CC-0549, CC-0550
- **Provenance:** `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/EnglishG2P.swift:223-244 — every pronunciation feature scans every mutable token
- **Decision:** Dense markdown pronunciation annotations create O(features × tokens) range checks on the synthesis path. Normal unannotated input is unaffected, limiting severity.
- **Recommendation:** Walk sorted feature and token ranges together or index tokens by range.

### V-249 · LOW · Gender persistence failure is unhandled

- **Candidates:** CC-1665
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/character_manager_screen.dart:235 — toggle handler is synchronous
  - lib/features/script_editor/character_manager_screen.dart:245 — setGender Future is neither awaited nor caught
  - lib/features/script_editor/character_manager_screen.dart:258 — in-memory state is updated immediately
- **Decision:** A preferences write failure becomes an unhandled async error while UI/script appears updated and later reload reverts it.
- **Recommendation:** Make the action async, await persistence, and report/log failure before committing UI state.

### V-250 · LOW · Generic contained OCR fragments receive perfect score

- **Candidates:** CC-0942
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/ocr_highlight_matcher.dart:202 — any eight-character candidate contained in target scores 1.0
  - lib/data/services/ocr_highlight_matcher.dart:217 — token-overlap safeguards are bypassed by the containment return
- **Decision:** A generic fragment can tie/beat the true later source and anchor a highlight to the wrong OCR line.
- **Recommendation:** Require meaningful target-token coverage before awarding perfect containment.

### V-251 · LOW · grep -q can false-negative under pipefail in package polling

- **Candidates:** CC-2264, CC-2265, CC-2266
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/phone-harness.sh:13 — pipefail is enabled
  - scripts/phone-harness.sh:62 — adb output is piped to an early-exiting grep -q
  - scripts/phone-harness.sh:63 — a false pipeline status skips all provisioning
- **Decision:** On a device with enough package output after the match, grep exits early, adb receives SIGPIPE, and pipefail makes the successful lookup evaluate false.
- **Recommendation:** Capture output first or use a consumer that drains the pipe before testing the match.

### V-252 · LOW · Guest preference persistence is fire-and-forget

- **Candidates:** CC-1343
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/auth/auth_screen.dart:412 — _skipAuth is synchronous void
  - lib/features/auth/auth_screen.dart:421 — setBool returns a Future that is neither awaited nor handled
  - lib/features/auth/auth_screen.dart:424 — navigation occurs immediately
- **Decision:** A preferences write error is unobserved and the next launch can re-prompt a user who chose guest mode.
- **Recommendation:** Make _skipAuth async, await persistence, and surface/log failure before navigation.

### V-253 · LOW · Harness fetch accepts HTTP error bodies as WAV

- **Candidates:** CC-0180, CC-0183
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/android_live_matching_test.dart:171-180 — response status is never checked before bytes are returned
  - integration_test/android_live_matching_test.dart:84-88 — fetched bytes are immediately parsed as WAV
- **Decision:** A 4xx/5xx HTML body fails later in the audio parser/recognizer with a misleading transcript error.
- **Recommendation:** Require HTTP 200 and report the status before parsing the response body.

### V-254 · LOW · Harness force-crashes on ordinary file/model errors

- **Candidates:** CC-2789, CC-2790, CC-2791, CC-2792, CC-2793, CC-2794, CC-2795, CC-2796, CC-2797, CC-2798
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tools/mlx-harness/Sources/harness/main.swift:32 — config file read uses try!
  - tools/mlx-harness/Sources/harness/main.swift:36 — weight load uses try!
  - tools/mlx-harness/Sources/harness/main.swift:100 — synthesis uses try!
  - tools/mlx-harness/Sources/harness/main.swift:111 — output write uses try! despite an existing die helper
- **Decision:** A mistyped path, malformed config/weights, failed inference, or unwritable output is a normal CLI error but terminates with a Swift trap/backtrace instead of an actionable diagnostic.
- **Recommendation:** Use throwing subcommand functions with top-level do/catch routed through die().

### V-255 · LOW · Harness network fetch has no timeout or size bound

- **Candidates:** CC-0179, CC-0181, CC-0182
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/android_live_matching_test.dart:171-183 — HttpClient GET, response drain, and BytesBuilder have no timeout or byte cap
  - integration_test/android_live_matching_test.dart:33-74 — the outer test permits up to 20 minutes and documents flaky device networking
- **Decision:** A stalled or unexpectedly large test-fixture response can wedge or inflate the test until the broad test timeout.
- **Recommendation:** Set connection/request/body timeouts and reject fixture bodies beyond a small expected-size cap.

### V-256 · LOW · Harness proceeds after package or model provisioning never succeeds

- **Candidates:** CC-2260, CC-2261, CC-2262, CC-2263, CC-2268, CC-2269, CC-2273
- **Provenance:** `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `shell-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/phone-harness.sh:61 — package polling has no success flag
  - scripts/phone-harness.sh:70 — pack copy gets three attempts
  - scripts/phone-harness.sh:76 — success is only printed conditionally
  - scripts/phone-harness.sh:82 — the outer loop breaks even after all copy attempts fail
  - scripts/phone-harness.sh:85 — package-poll exhaustion also falls through
  - scripts/phone-harness.sh:87 — the test is awaited regardless of provisioning outcome
- **Decision:** A slow install, denied run-as, or failed copy deterministically launches/continues the test without required mic/models and reports only a confusing downstream test result.
- **Recommendation:** Track package and pack success separately; terminate the test and exit nonzero with a specific provisioning error.

### V-257 · LOW · Harness relinker masks missing vendor directories

- **Candidates:** CC-2831, CC-2832, CC-2833, CC-2835, CC-2836, CC-2837
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `shell-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `shell-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tools/mlx-harness/link-sources.sh:10 — existing links are deleted before validating source
  - tools/mlx-harness/link-sources.sh:15 — find runs in process substitution whose status is not checked by the parent loop
  - tools/mlx-harness/link-sources.sh:18 — script still reports a linked count and success
- **Decision:** A renamed/missing/unreadable vendor directory can erase valid links, link nothing, and exit zero, deferring failure to SwiftPM.
- **Recommendation:** Validate every source directory before deletion and materialize/check find results before replacing links.

### V-258 · LOW · Harness WAV parser accepts missing or invalid chunks

- **Candidates:** CC-0199
- **Provenance:** `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/android_rehearsal_harness_test.dart:62-76 — the parser leaves dataStart at -1 and does not validate PCM format fields.
  - integration_test/android_rehearsal_harness_test.dart:86-87 — sample reads use dataStart directly.
- **Decision:** A changed or malformed generated WAV reaches a negative-offset sample read instead of a clear harness failure.
- **Recommendation:** Validate RIFF/fmt/data chunks before resampling.

### V-259 · LOW · Harness WAV parser trusts malformed headers

- **Candidates:** CC-0141, CC-0184, CC-0185, CC-0186, CC-0189, CC-0190, CC-0193, CC-0194, CC-0195, CC-0196
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/android_live_matching_test.dart:186-203 — the parser does not validate RIFF/fmt format, rate, channels, bit depth, data presence, or data bounds
  - integration_test/android_live_matching_test.dart:206-213 — missing data or zero rate reaches negative indexing/division-derived bounds
- **Decision:** A malformed, truncated, stereo, or non-WAV response produces opaque RangeError/UnsupportedError failures rather than an actionable fixture error.
- **Recommendation:** Validate RIFF/WAVE, PCM16 mono fmt fields, positive rate, data presence, and chunk bounds before resampling.

### V-260 · LOW · History relative dates use elapsed 24-hour buckets

- **Candidates:** CC-1601, CC-1602, CC-1603
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_history_screen.dart:274-280 — Today and Yesterday are selected from DateTime.difference.inDays.
- **Decision:** Sessions around midnight are assigned the wrong calendar label, and future timestamps can produce negative-day text.
- **Recommendation:** Compare normalized local calendar dates and handle future values explicitly.

### V-261 · LOW · Hub cloud/export failures are not persisted in diagnostics

- **Candidates:** CC-1518
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/production_hub/production_hub_screen.dart:788 — push catch only shows a snackbar
  - lib/features/production_hub/production_hub_screen.dart:858 — pull catch only shows a snackbar
  - lib/features/production_hub/production_hub_screen.dart:907 — export catch only shows a snackbar
- **Decision:** Once the transient message disappears, debug reports contain no details for these failures.
- **Recommendation:** Log full exceptions with DebugLogService before showing a generic message.

### V-262 · LOW · Import failure message hides an already-committed PDF change

- **Candidates:** CC-1975
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_import/script_import_screen.dart:573 — _acceptScript commits the staged PDF first
  - lib/features/script_import/script_import_screen.dart:581 — script persistence happens afterward and may throw
  - lib/features/script_import/script_import_screen.dart:589 — catch says nothing was added
  - lib/features/script_import/script_import_screen.dart:634 — PDF commit already changes production.scriptPath
- **Decision:** If persistScript fails, production metadata and its source PDF have already changed, so the recovery message falsely promises no state was added/changed.
- **Recommendation:** Persist atomically before promotion or report the partial commit accurately and offer retry/rollback.

### V-263 · LOW · Import matcher recomputes candidate tokens across target lines

- **Candidates:** CC-0941
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/ocr_highlight_matcher.dart:166 — each bestMatch call normalizes the target anew
  - lib/data/services/ocr_highlight_matcher.dart:173 — every candidate is normalized inside every call
  - lib/data/services/ocr_highlight_matcher.dart:215 — each score allocates a fresh token set/intersection
- **Decision:** Large imports repeatedly normalize/tokenize page candidates for adjacent target lines, creating avoidable CPU and allocation work.
- **Recommendation:** Precompute normalized candidate bodies and token sets for the page window.

### V-264 · LOW · Initial memory snapshot does not trigger a rebuild

- **Candidates:** CC-1913
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/settings/debug_log_screen.dart:28-45 — init fires getMemoryUsage without awaiting or setState
  - lib/data/services/debug_log_service.dart:203-225 — getMemoryUsage updates fields but does not add a log entry
- **Decision:** If no unrelated log arrives, the two-second poll sees the same count and the memory bar retains its prior values.
- **Recommendation:** Await the snapshot and setState when mounted, or include memory generation in the dirty-check.

### V-265 · LOW · Instance normalization repeats a full centering pass

- **Candidates:** CC-0409
- **Provenance:** `ios-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroVendored/BuildingBlocks/InstanceNorm1d.swift:68-74 — centered is computed for variance
  - ios/Runner/KokoroVendored/BuildingBlocks/InstanceNorm1d.swift:94-96 — normalization recomputes input minus mean
- **Decision:** Every active instance-normalization forward performs an avoidable elementwise subtraction over the activation tensor.
- **Recommendation:** Use centered / sqrt(variance + eps) for normalization.

### V-266 · LOW · Int.min overflows negative cardinal conversion

- **Candidates:** CC-0625, CC-0626, CC-0627
- **Provenance:** `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/Num2Word/EnglishNum2Word.swift:110 — toCardinal accepts Int
  - ios/Runner/MisakiVendored/English/Num2Word/EnglishNum2Word.swift:112 — negative values call abs(number) without guarding Int.min
  - ios/Runner/MisakiVendored/English/Num2Word/EnglishNum2Word.swift:213 — Decimal input is narrowed through NSDecimalNumber.intValue
- **Decision:** A sufficiently negative Decimal can narrow to Int.min, for which abs traps.
- **Recommendation:** Handle Int.min using unsigned magnitude or Decimal arithmetic before negation.

### V-267 · LOW · iOS loudness analysis buffers an unbounded whole audio file

- **Candidates:** CC-0309, CC-0310, CC-0311, CC-0312, CC-0313, CC-0314, CC-0315
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `metal-performance-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/AudioAnalysisPlugin.swift:50 — converts the full file length to frame capacity
  - ios/Runner/AudioAnalysisPlugin.swift:52 — allocates one AVAudioPCMBuffer for all frames
  - lib/data/services/audio_level_service.dart:43 — passes an arbitrary recording path to the native channel
- **Decision:** A long user or cloud recording is decoded fully into resident float PCM even though RMS and peak are streamable, creating a realistic memory spike.
- **Recommendation:** Read fixed-size PCM chunks and accumulate peak and sum of squares with constant memory; optionally reject implausibly long inputs.

### V-268 · LOW · iOS model setup checks the Android Kokoro pack

- **Candidates:** CC-1494
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/onboarding/model_setup_screen.dart:88 — refresh always calls ModelManager.isKokoroReady
  - lib/data/services/model_manager.dart:127 — ModelManager documents iOS should use ModelDownloadService MLX readiness
  - lib/data/services/model_manager.dart:136 — isAllReady correctly routes iOS to ModelDownloadService
- **Decision:** An already-installed iOS MLX pack can be displayed as missing because refresh checks the unrelated ONNX directory.
- **Recommendation:** Use platform-routed isAllReady/isKokoroReady consistently.

### V-269 · LOW · Join attempt rows for churned users never expire

- **Candidates:** CC-2499, CC-2500
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:50 — cleanup deletes only auth.uid() rows
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:57 — every lookup inserts a row
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:32 — retained rows also stay in the index
- **Decision:** Users who never call again leave permanent attempt rows, so table/index size grows monotonically with account churn.
- **Recommendation:** Run global retention cleanup via scheduled job or safe bounded cleanup in the definer function.

### V-270 · LOW · Join lookup exposes the complete production row

- **Candidates:** CC-2508, CC-2509, CC-2510, CC-2511, CC-2512
- **Provenance:** `db-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:71 — lookup returns row_to_json(p)
  - supabase/migrations/20260314061409_initial_schema.sql:44 — production row contains organizer_id
  - supabase/migrations/20260319100000_add_voice_preset.sql:10 — later columns are automatically exposed by row_to_json
- **Decision:** Any code holder receives organizer/account and all current/future production columns rather than the small identity/title contract needed by the join screen.
- **Recommendation:** Return an explicit json_build_object whitelist.

### V-271 · LOW · Join UI exposes raw backend errors and auth debug state

- **Candidates:** CC-1474, CC-1475, CC-1476, CC-1480, CC-1481, CC-1482
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/join/join_production_screen.dart:387 — not-found text includes signed-in state
  - lib/features/join/join_production_screen.dart:428 — raw lookup exception is shown
  - lib/features/join/join_production_screen.dart:584 — raw join exception is shown
- **Decision:** Supabase status/details can reach actors and the copy exposes internal auth state despite already logging the full exception.
- **Recommendation:** Map errors to stable user-facing messages and keep raw details only in DebugLogService.

### V-272 · LOW · Kokoro cache key omits model-pack identity

- **Candidates:** CC-0824
- **Provenance:** `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/kokoro_onnx_service.dart:194 — comment says the key covers everything shaping audio
  - lib/data/services/kokoro_onnx_service.dart:261 — actual key contains only text, voice, and speed
  - lib/data/services/kokoro_onnx_service.dart:263 — cached WAV path is derived solely from that hash
- **Decision:** Replacing the downloaded model can continue serving audio synthesized by the previous pack for identical text/voice/speed.
- **Recommendation:** Include a stable model-pack/version identity in the key or clear this cache on model replacement.

### V-273 · LOW · Kokoro cache pruning is permanently one-shot per process

- **Candidates:** CC-0388, CC-0389, CC-0390, CC-0391, CC-0392, CC-0393, CC-0394, CC-0397
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `simd-accelerate-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `simd-accelerate-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroMLXService.swift:334-346 — pruneScheduled is set once before directory enumeration and never reset, including early return
  - ios/Runner/KokoroMLXService.swift:352-367 — the 200 MB cap is only checked inside that one asynchronous pass
- **Decision:** After the first pass—commonly before the cache directory exists—new WAVs can grow beyond the intended cap until relaunch.
- **Recommendation:** Re-arm the guard in defer after each pass and reschedule based on bytes added or a bounded cadence.

### V-274 · LOW · Kokoro catch logs omit stack traces

- **Candidates:** CC-1260
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/tts_service.dart:744-764 — catch clauses capture only e and pass no StackTrace to logError
  - lib/data/services/debug_log_service.dart:194-200 — stack output is persisted only when a stack argument is supplied
- **Decision:** Actual synthesis/playback errors lose their call-site stack, reducing field diagnosability.
- **Recommendation:** Use catch (e, stack) and pass stack to logError.

### V-275 · LOW · Kokoro comparison test records quality metrics without pass/fail thresholds

- **Candidates:** CC-0253, CC-0256
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `testing-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/tts_kokoro_compare_macos_test.dart:156-215 — RTF, ASR match, and correlation are accumulated and printed
  - integration_test/tts_kokoro_compare_macos_test.dart:110-218 — the test body contains no expect call
- **Decision:** A synthesis or intelligibility regression can complete the evaluator green because all decision metrics are observational only.
- **Recommendation:** Add documented acceptance thresholds for intelligibility and performance, while retaining artifacts for human listening.

### V-276 · LOW · Kokoro device staging nests or preserves stale directories on reruns

- **Candidates:** CC-2251, CC-2252, CC-2253, CC-2271, CC-2272
- **Provenance:** `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/phone-harness.sh:43 — the source directory is pushed to a fixed kpack destination rather than its parent
  - scripts/phone-harness.sh:50 — the Kroko path explicitly documents the contrasting parent-push rerun fix
  - scripts/phone-harness.sh:74 — app staging moves .kpack-tmp onto a deterministic destination without removing it
  - scripts/phone-harness.sh:75 — verification checks only live_asr files, not the Kokoro layout
- **Decision:** Once either destination directory exists, standard directory copy/move semantics can add another nested directory or retain the previous pack; the harness still declares provisioning from the unrelated ASR count.
- **Recommendation:** Remove destinations before atomic replacement, push to the parent, and verify named Kokoro files.

### V-277 · LOW · Kokoro disk-cache cap is enforced only once per process

- **Candidates:** CC-0823, CC-0825, CC-0826, CC-0827
- **Provenance:** `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/kokoro_onnx_service.dart:250 — _pruneScheduled is a static one-way flag
  - lib/data/services/kokoro_onnx_service.dart:259 — pruning is scheduled only while first creating the cached directory path
  - lib/data/services/kokoro_onnx_service.dart:269 — comment explicitly says once per app run
  - lib/data/services/kokoro_onnx_service.dart:273 — flag is set and never reset
- **Decision:** After the initial sweep, every distinct synthesis can add a WAV for the remainder of a long process, so the stated 150 MB high-water mark is not maintained.
- **Recommendation:** Re-arm pruning periodically or after a bounded number/size of cache insertions.

### V-278 · LOW · Kokoro RTF harness accepts empty generated audio

- **Candidates:** CC-0165, CC-0166
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/android_kokoro_rtf_test.dart:62 — generate result is accepted without validation
  - integration_test/android_kokoro_rtf_test.dart:64 — duration is computed from sample count and sample rate
  - integration_test/android_kokoro_rtf_test.dart:66 — elapsed time is divided by duration
  - integration_test/android_kokoro_rtf_test.dart:72 — harness prints DONE without an assertion
- **Decision:** An empty generated sample list produces a zero duration and a non-useful ratio while the test has no assertion that synthesis yielded audio.
- **Recommendation:** Assert a positive sample rate, non-empty samples, and finite positive duration before computing RTF.

### V-279 · LOW · Kokoro RTF harness documents the wrong fp16 pack

- **Candidates:** CC-0148, CC-0149
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/android_kokoro_rtf_test.dart:1 — header says fp32 versus int8
  - integration_test/android_kokoro_rtf_test.dart:7 — sideload recipe names fp32,int8
  - integration_test/android_kokoro_rtf_test.dart:38 — benchmark cases begin here
  - integration_test/android_kokoro_rtf_test.dart:42 — actual second case is fp16-v1_0
- **Decision:** Following the current header prepares the wrong directory and misstates the benchmark being run.
- **Recommendation:** Change both header references from int8 to fp16.

### V-280 · LOW · Kokoro RTF sideload timeout falls through without a readiness assertion

- **Candidates:** CC-0150, CC-0151, CC-0152, CC-0153, CC-0154, CC-0155, CC-0156, CC-0157, CC-0158, CC-0159, CC-0160, CC-0161
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `testing-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/android_kokoro_rtf_test.dart:28 — six-minute polling loop begins
  - integration_test/android_kokoro_rtf_test.dart:31 — only fp16 has a READY sentinel
  - integration_test/android_kokoro_rtf_test.dart:36 — readiness is printed unconditionally after the loop
  - integration_test/android_kokoro_rtf_test.dart:45 — native OfflineTts construction follows immediately
- **Decision:** A failed or partial sideload reaches native initialization after six minutes with a misleading success probe instead of a clear harness failure.
- **Recommendation:** Assert every required pack file/sentinel after polling and use READY markers for both packs.

### V-281 · LOW · Kokoro status tile is not reactive to engine loading

- **Candidates:** CC-1985, CC-1986
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/settings/settings_screen.dart:248 — subtitle reads singleton state imperatively
  - lib/features/settings/settings_screen.dart:253 — icon reads the same imperative snapshot
  - lib/features/settings/settings_screen.dart:82 — build watches settings providers, not TTS state
- **Decision:** A model finishing or unloading while this route remains mounted does not trigger rebuild, so the displayed engine state can remain stale.
- **Recommendation:** Expose engine readiness through a provider/Listenable and watch it in the tile.

### V-282 · LOW · Large model SHA-256 runs on the UI isolate

- **Candidates:** CC-0876, CC-0877, CC-0878, CC-0879, CC-0880
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/model_download_service.dart:395-414 — crypto.sha256 consumes the full file stream in the caller isolate
  - lib/data/services/model_download_service.dart:252-266 — native completion awaits verification in the method-channel handler
- **Decision:** Post-download hashing is memory-safe but CPU work scales with model size and can cause a one-time frame stall.
- **Recommendation:** Perform digest computation in Isolate.run/compute and return only the digest string.

### V-283 · LOW · Late native callbacks can mutate a newer STT session

- **Candidates:** CC-1143, CC-1146
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/stt_service.dart:184-218 — only the delayed restart checks generation; result/onDone closures mutate shared state without it
  - lib/data/services/stt_channel.dart:127-142 — native callbacks invoke the single current callback slots and clear them
  - ios/Runner/AppleSttPlugin.swift:180-200 — starting a session cancels the previous native task, whose completion can arrive asynchronously
- **Decision:** A cancellation callback from the prior native task can run through the newly installed Dart slots, merge stale text, clear callbacks, or stop the active line.
- **Recommendation:** Capture the session generation in both channel and service callbacks and ignore any callback that does not match the active generation.

### V-284 · LOW · Leaving during recorder start drops an orphan file

- **Candidates:** CC-1553, CC-1554
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/recording_studio/recording_studio_screen.dart:600-626 — status remains idle during start; after unmount the branch stops and returns without registration or deletion.
  - lib/features/recording_studio/recording_studio_screen.dart:92-114 — dispose saves only when status is already recording.
- **Decision:** Navigating away during permission/start can leave unregistered audio on disk and no upload/log record.
- **Recommendation:** Track start-in-flight ownership and delete or register the stopped file in the unmounted branch.

### V-285 · LOW · Legacy-code reroll can generate another all-hex code

- **Candidates:** CC-2540
- **Provenance:** `db-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260315_cast_join_code.sql:59 — generator alphabet contains digits and A–Z excluding ambiguous characters
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:203 — each legacy row is rerolled exactly once
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:205 — generated result is not rechecked against the legacy regex
- **Decision:** A nonzero fraction of generated codes remain entirely in the smaller hex alphabet the migration intended to eliminate.
- **Recommendation:** Loop/retry until the new unique code does not match the legacy pattern.

### V-286 · LOW · Likely-not-script section eagerly builds every row

- **Candidates:** CC-1806, CC-1807, CC-1808, CC-1809, CC-1810, CC-1811
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_import/ocr_review_screen.dart:967 — all remaining flagged-note lines are materialized each build
  - lib/features/script_import/ocr_review_screen.dart:984 — ExpansionTile receives an eager children list
  - lib/features/script_import/ocr_review_screen.dart:996 — spread-map constructs every ListTile
  - lib/features/script_import/ocr_review_screen.dart:505 — the neighboring review list documents 100-300-line scans and uses lazy construction
- **Decision:** Hundreds of not-script tiles are constructed even while collapsed and reconstructed on every relevant setState, recreating the jank the main list was designed to avoid.
- **Recommendation:** Build expanded rows lazily and avoid constructing them while collapsed.

### V-287 · LOW · Linear interpolation extrapolates at the left edge

- **Candidates:** CC-0415, CC-0416, CC-0417, CC-0418, CC-0419
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroVendored/BuildingBlocks/Interpolate.swift:87 — align-corners-false positions can start below zero
  - ios/Runner/KokoroVendored/BuildingBlocks/Interpolate.swift:104 — only the integer low index is clamped
  - ios/Runner/KokoroVendored/BuildingBlocks/Interpolate.swift:108 — the fraction still uses the negative coordinate
- **Decision:** For initial positions with x < 0, xFrac is negative and the blend extrapolates instead of replicating sample zero, deviating from the intended/PyTorch edge behavior.
- **Recommendation:** Clamp x or xFrac before computing the blend.

### V-288 · LOW · Linux startup performs a synchronous X11 WM round trip

- **Candidates:** CC-2063
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - linux/runner/my_application.cc:23 — the call occurs synchronously in application activate
  - linux/runner/my_application.cc:39 — gdk_x11_screen_get_window_manager_name queries the X server
  - linux/runner/my_application.cc:61 — Flutter view creation happens only afterward
- **Decision:** On a remote or stalled X connection this cold-path round trip delays the first Flutter frame and can make launch appear hung.
- **Recommendation:** Avoid the WM query or defer the cosmetic title-bar heuristic until after startup.

### V-289 · LOW · Linux window remains invisible if no first frame arrives

- **Candidates:** CC-2065
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - linux/runner/my_application.cc:18 — only first_frame_cb shows the top-level window
  - linux/runner/my_application.cc:72 — visibility is connected solely to the first-frame signal
  - linux/runner/my_application.cc:74 — the view is realized but the window is not otherwise presented
- **Decision:** A missing-asset or engine rendering failure prevents the signal and gives a graphical user no window or error surface.
- **Recommendation:** Present a minimal window/error fallback if the first frame does not arrive.

### V-290 · LOW · listen retains the previous smoothed microphone level

- **Candidates:** CC-1141
- **Provenance:** `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/stt_service.dart:169-179 — listen resets silence/speech state but not _smoothedLevel
  - lib/data/services/stt_service.dart:113-126 — the next level event blends 70% of the stale value before speech detection
- **Decision:** A high previous level can make initial silence in a new utterance count as speech, violating the documented leading-silence guard.
- **Recommendation:** Reset _smoothedLevel to zero when starting every listening session.

### V-291 · LOW · Live ASR teardown kills before confirming native disposal

- **Candidates:** CC-0849, CC-0851, CC-0852, CC-0853, CC-0855
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/live_asr_service.dart:139-148 — stop sends dispose, cancels listening, then immediately kills before the next event
  - lib/data/services/live_asr_service.dart:237-241 — native stream/recognizer free occurs only when the child handles dispose
- **Decision:** There is no acknowledgement or delay behind the comment promising a moment to free memory. Normal stop and timeout cleanup race the only explicit native frees, risking retained native allocations until process exit.
- **Recommendation:** Have the child acknowledge disposal after free, await it with a short timeout, then force-kill only if needed.

### V-292 · LOW · Live Supabase join-flow test swallows every failure branch

- **Candidates:** CC-2632, CC-2633, CC-2634, CC-2635, CC-2636, CC-2637, CC-2638
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `testing-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - test/supabase_service_test.dart:57 — sole expect is inside the success branch
  - test/supabase_service_test.dart:61 — null/non-map falls through to prints
  - test/supabase_service_test.dart:77 — exceptions are caught
  - test/supabase_service_test.dart:90 — fallback failure is only printed
- **Decision:** A broken RPC and broken fallback can complete the opt-in test successfully, providing false regression confidence.
- **Recommendation:** Fail explicitly unless either path returns the expected production, and let unexpected exceptions fail with diagnostics.

### V-293 · LOW · Load-bearing microphone permission failure is discarded

- **Candidates:** CC-2267
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/phone-harness.sh:64 — RECORD_AUDIO grant stderr is discarded and exit status ignored
  - scripts/phone-harness.sh:77 — success text claims mic provisioning based only on model file count
- **Decision:** A denied/failed permission grant produces a misleading provisioned message and a later opaque microphone test failure.
- **Recommendation:** Check the grant status explicitly; leave only nonessential appops/volume commands best-effort.

### V-294 · LOW · Locale dialog calls setState after await without mounted check

- **Candidates:** CC-1670, CC-1671, CC-1672, CC-1673, CC-1674
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/character_manager_screen.dart:303 — onChanged is asynchronous
  - lib/features/script_editor/character_manager_screen.dart:304 — locale persistence is awaited
  - lib/features/script_editor/character_manager_screen.dart:309 — screen setState runs with no mounted guard
- **Decision:** Popping the character screen while persistence is pending can call setState on a disposed State.
- **Recommendation:** Check mounted immediately after await before mutating state.

### V-295 · LOW · Long OCR imports continue after the user abandons them

- **Candidates:** CC-0676
- **Provenance:** `ios-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/PaddleOcrPlugin.swift:178 — processes every page with no cancel flag
  - ios/Runner/PaddleOcrPlugin.swift:181 — continues emitting progress for the entire loop
- **Decision:** The native operation has no cancellation method or disposed-caller check, so dismissing a long import cannot stop its CPU, memory, or battery use.
- **Recommendation:** Add a job token and cancel method checked between pages.

### V-296 · LOW · Low-OCR walkthrough controls disappear on lines without pages

- **Candidates:** CC-1752, CC-1756
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:910-1021 — walkthrough controls are inside the sourcePage/PDF conditional.
  - lib/features/script_editor/script_editor_screen.dart:1250-1256 — the walkthrough list includes all low-confidence lines, including those without sourcePage.
- **Decision:** Stepping to a flagged line without a page removes navigation and review controls mid-workflow.
- **Recommendation:** Render controls outside the page preview or filter navigation to page-backed lines.

### V-297 · LOW · macOS available memory is total minus this process only

- **Candidates:** CC-2105, CC-2107, CC-2108, CC-2109, CC-2110, CC-2111, CC-2112, CC-2113, CC-2114
- **Provenance:** `db-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `sql-migration-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - macos/Runner/MemoryMonitorPlugin.swift:17-29 — availableMemoryMB is total physical memory minus only this process footprint
  - lib/data/services/debug_log_service.dart:252-257 — current Dart use is diagnostic logging
- **Decision:** The metric ignores every other process and system pressure, substantially overstating actual availability. Current consumers log it rather than gate model/OCR work, so impact is diagnostic.
- **Recommendation:** Use a host/process availability API or rename the field so it does not claim system-available memory.

### V-298 · LOW · macOS memory probe failure reports maximum availability

- **Candidates:** CC-2106, CC-2115, CC-2116
- **Provenance:** `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - macos/Runner/MemoryMonitorPlugin.swift:36-47 — task_info failure returns footprint 0
  - macos/Runner/MemoryMonitorPlugin.swift:20-28 — zero becomes availableMemoryMB equal to total physical memory
- **Decision:** Probe failure resolves in the most permissive and misleading direction.
- **Recommendation:** Return an optional/error and preserve availability as unknown rather than total memory.

### V-299 · LOW · macOS model replacement deletes the good file before promotion

- **Candidates:** CC-2081, CC-2095, CC-2096, CC-2097
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - macos/Runner/BackgroundDownloadPlugin.swift:100 — removes an existing destination first
  - macos/Runner/BackgroundDownloadPlugin.swift:101 — only then attempts to move the new file
  - macos/Runner/BackgroundDownloadPlugin.swift:111 — move failure is caught after deletion
- **Decision:** A filesystem failure between deletion and move loses the last working model even though a replacement was not installed.
- **Recommendation:** Move to a same-directory temporary name and atomically replace the destination only after the new file is safely present.

### V-300 · LOW · macOS PDF OCR has no progress or cancellation lifecycle

- **Candidates:** CC-2119, CC-2120, CC-2122, CC-2124
- **Provenance:** `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - macos/Runner/VisionOcrPlugin.swift:74-129 — one background block processes every page serially and returns only after the full document
  - macos/Runner/VisionOcrPlugin.swift:21-49 — the method channel exposes no cancellation command
- **Decision:** A long scanned PDF continues consuming CPU after its UI consumer leaves and offers no progress signal; all per-page results are buffered into one final reply.
- **Recommendation:** Add request IDs with between-page cancellation and emit progress/chunked results for long documents.

### V-301 · LOW · Malformed or failed remote URLs crash the silence diagnostic

- **Candidates:** CC-2332, CC-2333, CC-2336, CC-2337, CC-2338, CC-2339, CC-2340, CC-2341, CC-2342, CC-2343
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `media-provenance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `media-provenance-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/test_silence_trim.swift:117 — path is raw command-line input
  - scripts/test_silence_trim.swift:124 — URL construction and synchronous download are force-unwrapped/force-tried
  - scripts/test_silence_trim.swift:125 — the temporary write is also force-tried
- **Decision:** A malformed URL, DNS/HTTP failure, timeout, or full disk produces a fatal trap instead of the diagnostic's established ERROR-and-exit behavior.
- **Recommendation:** Validate the URL and handle download/write/status errors with a specific message and nonzero exit.

### V-302 · LOW · Markdown stripping test does not assert stripped content

- **Candidates:** CC-2574, CC-2575, CC-2576
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - test/pdf_import_test.dart:341 — test is named for markdown stripping
  - test/pdf_import_test.dart:346 — input contains markdown markers
  - test/pdf_import_test.dart:354 — result is parsed
  - test/pdf_import_test.dart:356 — only line count is asserted
  - lib/data/services/script_parser.dart:121 — production parser currently performs markdown stripping
- **Decision:** Removing or breaking _stripMarkdown can leave the test green as long as cue parsing still yields two lines.
- **Recommendation:** Assert exact normalized dialogue text and absence of each supported marker/link syntax.

### V-303 · LOW · matchScore glues hyphenated expected words

- **Candidates:** CC-1151, CC-1156
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/stt_service.dart:279-289 — heardLineEnding replaces hyphens with spaces before normalization
  - lib/data/services/stt_service.dart:311-320 — matchScore omits that replacement, while normalization deletes punctuation
- **Decision:** A script token such as good-humoured becomes goodhumoured and cannot align with recognizer output good humoured, lowering match scores systematically.
- **Recommendation:** Apply the same hyphen-to-space preprocessing to both sides of matchScore.

### V-304 · LOW · Memory monitor reports task_info failure as a real zero reading

- **Candidates:** CC-0523
- **Provenance:** `ios-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MemoryMonitorPlugin.swift:45 — task_info returns a kernel status
  - ios/Runner/MemoryMonitorPlugin.swift:53 — every failure is collapsed to integer zero
  - lib/data/services/debug_log_service.dart:255 — callers log that zero as physical memory usage
- **Decision:** A task_info failure produces a plausible but false 0 MB diagnostic rather than an error or missing sample, masking the monitoring failure.
- **Recommendation:** Return a FlutterError or nullable field when task_info fails.

### V-305 · LOW · Metadata failure leaves repeatedly uploaded objects

- **Candidates:** CC-0971
- **Provenance:** `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/recording_sync_service.dart:356-377 — upload completes before metadata save and local remoteUrl notification.
  - lib/data/services/recording_sync_service.dart:380-384 — either failure is caught without retaining the uploaded object URL.
- **Decision:** A metadata-write failure loses knowledge of a successful object upload, so later syncs upload another object.
- **Recommendation:** Persist an upload checkpoint or delete the object when metadata save fails.

### V-306 · LOW · Mic tap allocates and copies a PCM buffer on the realtime thread

- **Candidates:** CC-0260, CC-0278, CC-0287, CC-0288
- **Provenance:** `ios-performance-review@deepinfra-zai-org-glm-5.3-flash`, `metal-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `metal-performance-review@deepinfra-zai-org-glm-5.3-flash`, `simd-accelerate-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/AppleSttPlugin.swift:38 — copyBuffer allocates AVAudioPCMBuffer
  - ios/Runner/AppleSttPlugin.swift:297 — the tap block runs on the audio callback
  - ios/Runner/AppleSttPlugin.swift:304 — copying occurs before dispatch to audioFileQueue
- **Decision:** Every tap while recording performs heap allocation and a full channel copy on the render callback, a realistic source of capture jitter under allocator pressure.
- **Recommendation:** Use a bounded preallocated buffer pool and keep ownership safe until the file queue consumes each buffer.

### V-307 · LOW · Mid-line Kokoro failure replays completed chunks

- **Candidates:** CC-1238, CC-1259
- **Provenance:** `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/tts_service.dart:653-679 — any later chunk can return false after earlier chunks played
  - lib/data/services/tts_service.dart:420-452 — false falls back by speaking the original entire text
- **Decision:** The system fallback repeats already-heard content from the start after a later synthesis/playback failure.
- **Recommendation:** Track the first unplayed chunk and fallback only to the remaining text, or suppress full-line fallback once playback began.

### V-308 · LOW · Migration has unbounded lock waits on hot objects

- **Candidates:** CC-2535, CC-2541, CC-2542
- **Provenance:** `sql-migration-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:172 — policy DDL runs without lock_timeout
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:211 — plain DROP INDEX is used on script_lines
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:209 — migration itself identifies script_lines as the largest bulk-write path
- **Decision:** During a live deploy, a long transaction can make lock-taking DDL wait while subsequent traffic queues; there is no bounded abort/retry.
- **Recommendation:** Set a short lock_timeout and split DROP INDEX CONCURRENTLY into a compatible non-transactional migration/maintenance step.

### V-309 · LOW · Missing contact-picker activity can crash the platform call

- **Candidates:** CC-0079, CC-0080
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:59 — pendingResult is stored before launch
  - android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:61 — startActivityForResult is not guarded
- **Decision:** A device without an activity resolving ACTION_PICK throws ActivityNotFoundException and leaves pendingResult outstanding.
- **Recommendation:** Catch ActivityNotFoundException, clear pendingResult, and return a channel error.

### V-310 · LOW · Model actions let service exceptions escape

- **Candidates:** CC-0003
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/ai_models_screen.dart:394 — _download awaits the service without a catch
  - lib/features/settings/ai_models_screen.dart:408 — _delete likewise awaits delete without handling an exception
  - lib/features/settings/ai_models_screen.dart:303 — group deletion awaits each delete directly from an async button callback
- **Decision:** A download or delete exception escapes the UI callback and becomes an unhandled asynchronous error.
- **Recommendation:** Catch service exceptions, log them, and show a durable error toast.

### V-311 · LOW · Model delete handlers drop filesystem exceptions

- **Candidates:** CC-1895, CC-1896, CC-1897, CC-1898, CC-1899, CC-1900, CC-1902, CC-1907
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/ai_models_screen.dart:109 — clearCache is awaited without catch
  - lib/features/settings/ai_models_screen.dart:301 — grouped live-ASR deletes have no error handling
  - lib/features/settings/ai_models_screen.dart:408 — individual delete has no error handling
  - lib/features/settings/ai_models_screen.dart:224 — popup callback does not await or handle the returned Future
- **Decision:** Ordinary I/O failures propagate as unhandled asynchronous errors with no toast, and grouped deletion can stop partway through.
- **Recommendation:** Catch deletion failures at each user action, log them, and show accurate partial/success state.

### V-312 · LOW · Model progress callbacks rebuild the whole setup screen

- **Candidates:** CC-1495
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/onboarding/model_setup_screen.dart:102 — every native service notification enters _onServiceState
  - lib/features/onboarding/model_setup_screen.dart:117 — each notification calls screen-level setState
  - lib/features/onboarding/model_setup_screen.dart:146 — Android progress also calls setState per callback
- **Decision:** High-frequency download progress can rebuild all cards/buttons many times per second for a long transfer.
- **Recommendation:** Throttle/coalesce progress updates or isolate each progress row in a listenable builder.

### V-313 · LOW · Model setup readiness errors leave the screen unchecked

- **Candidates:** CC-1493
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/onboarding/model_setup_screen.dart:87 — _refreshStatus has no try/catch
  - lib/features/onboarding/model_setup_screen.dart:88 — file/service readiness calls are awaited directly
  - lib/features/onboarding/model_setup_screen.dart:96 — _statusChecked is set only after both succeed
- **Decision:** An I/O/platform error leaves _statusChecked false and no actionable download/error state; maybeOffer is likewise called unawaited by home.
- **Recommendation:** Catch and log readiness errors and render a retry/error state.

### V-314 · LOW · Model-download analytics records start as success

- **Candidates:** CC-1501
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/onboarding/model_setup_screen.dart:138 — logModelDownloaded fires before any download begins
  - lib/features/onboarding/model_setup_screen.dart:173 — later download failures are possible and caught
- **Decision:** Failures and abandoned downloads inflate a success-named metric.
- **Recommendation:** Emit a start event here and completion only after all required rows are verified ready.

### V-315 · LOW · Monologue scenes are presented as validation errors

- **Candidates:** CC-1786
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/validation_panel.dart:75 — every scene with fewer than two characters is selected
  - lib/features/script_editor/validation_panel.dart:79 — such a scene fails the check
  - lib/features/script_editor/validation_panel.dart:18 — failed checks default to error rather than warning
- **Decision:** A legitimate single-speaker scene makes an otherwise valid script fail the panel’s overall success state.
- **Recommendation:** Make this heuristic a warning or fail only scenes with no spoken character.

### V-316 · LOW · Multi-page OCR lacks a per-page autorelease scope

- **Candidates:** CC-0675
- **Provenance:** `ios-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/PaddleOcrPlugin.swift:178 — loops over every PDF page inside one dispatched closure
  - ios/Runner/PaddleOcrPlugin.swift:196 — renders a full bitmap on each iteration
  - ios/Runner/PaddleOcrPlugin.swift:200 — creates detector and recognizer temporaries per page
- **Decision:** Objective-C/PDFKit autoreleased temporaries can remain until the whole queue block drains, raising peak memory on long scanned scripts.
- **Recommendation:** Wrap each page iteration in autoreleasepool and keep only serialized result maps.

### V-317 · LOW · Negative decimal fractions gain a spurious zero

- **Candidates:** CC-0637, CC-0638, CC-0639, CC-0640, CC-0641, CC-0642, CC-0643
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/Num2Word/EnglishNum2Word.swift:213 — integer conversion truncates a negative decimal toward zero
  - ios/Runner/MisakiVendored/English/Num2Word/EnglishNum2Word.swift:223 — dropFirst(2) assumes a 0. prefix and leaves the decimal point for -0.x
- **Decision:** Negative non-integers such as -3.5 are rendered as minus three point zero five.
- **Recommendation:** Format digits from the absolute fractional magnitude rather than slicing a signed description.

### V-318 · LOW · Next button icon and label are reversed

- **Candidates:** CC-1547
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/recording_studio/recording_studio_screen.dart:537-543 — TextButton.icon supplies Text("Next") as icon and the chevron Icon as label.
- **Decision:** The control renders and styles its text/icon in the wrong slots.
- **Recommendation:** Swap the icon and label arguments.

### V-319 · LOW · OCR highlight audit performs the full OCR twice

- **Candidates:** CC-0227
- **Provenance:** `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/ocr_highlight_audit_macos_test.dart:39 — the test invokes Paddle OCR directly
  - integration_test/ocr_highlight_audit_macos_test.dart:64 — it then invokes ScriptImportService.importFromPdf
  - lib/data/services/script_import_service.dart:359 — the import path invokes PaddleOcrChannel.ocrPdf again
- **Decision:** The scanned fixture follows the OCR fallback, so one audit run repeats full-document OCR and can consume most of its 30-minute budget.
- **Recommendation:** Reuse the import OCR pages or add a test-scoped cache.

### V-320 · LOW · OCR matching repeats normalization work

- **Candidates:** CC-0939
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/ocr_highlight_matcher.dart:101 — locate normalizes each candidate for scoring
  - lib/data/services/ocr_highlight_matcher.dart:122 — backward extension normalizes candidates again
  - lib/data/services/ocr_highlight_matcher.dart:137 — consumed and forward walks normalize them again
- **Decision:** A page with many flagged lines repeats multiple regex passes over the same bounded page lines on the UI path.
- **Recommendation:** Precompute normalized full/body forms once per page locate operation or page cache.

### V-321 · LOW · OCR recognition allocates large per-line buffers

- **Candidates:** CC-0133, CC-0134, CC-0135, CC-0136
- **Provenance:** `android-performance-review@deepinfra-zai-org-glm-5.3-flash`, `kotlin-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:309-327 — each detected line creates and recycles a crop bitmap
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:470-487 — each tensor conversion allocates a scaled bitmap, IntArray, and FloatArray
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:490-501 — every model run copies the output FloatBuffer into a new FloatArray
- **Decision:** Multi-page imports create substantial short-lived heap churn proportional to recognized lines, causing avoidable GC overhead on memory-constrained phones.
- **Recommendation:** Reuse job-scoped pixel/tensor buffers where shapes permit and decode CTC directly from the output FloatBuffer.

### V-322 · LOW · OCR review eagerly creates a controller for every flagged line

- **Candidates:** CC-1789
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_import/ocr_review_screen.dart:81 — initState iterates the full review list
  - lib/features/script_import/ocr_review_screen.dart:82 — each line gets a TextEditingController and text copy
  - lib/features/script_import/ocr_review_screen.dart:559 — cards themselves are otherwise lazily built
- **Decision:** Bad scans are explicitly expected to flag hundreds of lines, so screen entry allocates hundreds of heavy controllers before most are visible or edited.
- **Recommendation:** Create controllers lazily with putIfAbsent and commit live values on exit.

### V-323 · LOW · OCR scorer loads an unused British dictionary

- **Candidates:** CC-0919
- **Provenance:** `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/ocr_confidence_service.dart:68 — registers the en dictionary
  - lib/data/services/ocr_confidence_service.dart:69 — also registers en-gb
  - lib/data/services/ocr_confidence_service.dart:70 — constructs the checker only for en
- **Decision:** The second full dictionary remains registered but is never queried in production scoring, adding avoidable startup work and retained memory.
- **Recommendation:** Register only the selected language.

### V-324 · LOW · OCR typo-cleanup test cannot detect typo characters

- **Candidates:** CC-2585
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - test/sample_script_test.dart:293 — the test inserts ELIIZABETH and DRCY
  - test/sample_script_test.dart:300 — it only asserts clean ELIZABETH is present
  - test/sample_script_test.dart:302 — comment states typo names should not exist but no negative assertion follows
- **Decision:** The 40 clean setup lines guarantee the positive assertions, so a regression preserving both typo characters still passes.
- **Recommendation:** Assert the typo spellings are absent or map to the canonical names.

### V-325 · LOW · Offline unassign silently boomerangs after sync

- **Candidates:** CC-1405, CC-1406
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/cast_manager/cast_manager_screen.dart:844 — cloud delete is skipped while signed out
  - lib/features/cast_manager/cast_manager_screen.dart:863 — local row is still removed
  - lib/features/cast_manager/cast_manager_screen.dart:107 — the next signed-in open re-saves every cloud member
- **Decision:** A cloud-backed member removed offline reappears from the untouched cloud row, silently undoing the organizer action.
- **Recommendation:** Block offline removal of cloud-backed rows or queue a durable cloud deletion.

### V-326 · LOW · One-off WAV transcript tool assumes a fixed 44-byte header

- **Candidates:** CC-0211, CC-0212, CC-0213, CC-0214, CC-0215
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `testing-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/asr_testwav_transcript_macos_test.dart:39 — parser explicitly assumes a canonical 44-byte header
  - integration_test/asr_testwav_transcript_macos_test.dart:40 — sample rate is read from fixed offset 24
  - integration_test/asr_testwav_transcript_macos_test.dart:44 — PCM samples always start at fixed offset 44
- **Decision:** A RIFF file with an extra chunk is a realistic input and deterministically shifts the data chunk, so this diagnostic can print a false transcript without failing.
- **Recommendation:** Walk RIFF chunks, validate RIFF/WAVE and fmt/data chunks, and assert a non-empty result.

### V-327 · LOW · One-time model offer is consumed before navigation

- **Candidates:** CC-1489, CC-1490, CC-1491, CC-1492
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/onboarding/model_setup_screen.dart:33 — readiness is awaited
  - lib/features/onboarding/model_setup_screen.dart:34 — model_setup_offered is persisted before mounted/ready checks
  - lib/features/onboarding/model_setup_screen.dart:35 — an unmounted context returns after the offer was consumed
- **Decision:** A navigation race can permanently suppress the setup screen without showing it.
- **Recommendation:** Set the preference only on the mounted path immediately before/after successfully presenting the setup route.

### V-328 · LOW · Orphan analyzer cleanup is not exception-safe

- **Candidates:** CC-2695, CC-2713, CC-2714, CC-2715
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tool/analyze_orphaned_recordings.dart:56-110 — all analysis queries/reporting occur after membership without a surrounding finally
  - tool/analyze_orphaned_recordings.dart:112-120 — membership deletion runs only on the happy path
- **Decision:** Any query, decoding, or reporting exception skips membership cleanup and leaves an audit row in the production.
- **Recommendation:** Wrap all post-insert work in try/finally and perform verified membership deletion in finally.

### V-329 · LOW · Orphan audit silently truncates large productions

- **Candidates:** CC-2697, CC-2698, CC-2699, CC-2700
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tool/analyze_orphaned_recordings.dart:63-76 — script_lines and recordings each use one unpaginated select
  - tool/analyze_orphaned_recordings.dart:79-110 — all counts and detail derive solely from those responses
- **Decision:** Once row count exceeds the PostgREST max-rows response cap, the tool reports incomplete counts without detecting truncation.
- **Recommendation:** Page deterministically until a short page, or use server-side counted/anti-join RPCs.

### V-330 · LOW · Orphan-dialogue guard is a no-op

- **Candidates:** CC-2242, CC-2243, CC-2244, CC-2245
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/pdf_to_script.py:287 — orphan path is detected
  - scripts/pdf_to_script.py:290 — body is only pass
  - scripts/pdf_to_script.py:291 — text is appended unconditionally
- **Decision:** Dialogue without a current speaker silently enters output, violating the converter’s name-on-own-line contract.
- **Recommendation:** Attach only to a validated cross-page speaker or warn/fail and exclude the orphan.

### V-331 · LOW · ORT vendoring can leave a partial source-tree update

- **Candidates:** CC-2204, CC-2205
- **Provenance:** `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/fetch-ort-java.sh:34 — jar is copied before validating all inputs/tools
  - scripts/fetch-ort-java.sh:37 — each ABI library is copied directly into the source tree
  - scripts/fetch-ort-java.sh:45 — patchelf can fail after earlier artifacts were installed
- **Decision:** Missing patchelf, changed AAR layout, or a later ABI failure leaves partially replaced artifacts that subsequent Gradle builds consume.
- **Recommendation:** Validate tools/layout first, patch entirely under TMP, and atomically copy outputs only after all ABIs succeed.

### V-332 · LOW · Overlapping file scans can publish stale results

- **Candidates:** CC-1568, CC-1574
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/recording_studio/recordings_browser_screen.dart:196 — each scan computes a key
  - lib/features/recording_studio/recordings_browser_screen.dart:198 — _scannedKey changes before async work
  - lib/features/recording_studio/recordings_browser_screen.dart:199 — scans run unawaited and may overlap
  - lib/features/recording_studio/recordings_browser_screen.dart:212 — completion publishes without checking its captured key
- **Decision:** An older slower scan can finish after a newer scan and overwrite file-resolution state for the wrong entry set.
- **Recommendation:** Capture the scan key/version and discard completion when it no longer equals _scannedKey.

### V-333 · LOW · Overlapping PDF opens can leak losing document handles

- **Candidates:** CC-1826, CC-1828, CC-1831
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_import/pdf_page_view.dart:166 — concurrent renders can both see no matching document
  - lib/features/script_import/pdf_page_view.dart:169 — assigns an awaited open directly to shared _doc
  - lib/features/script_import/pdf_page_view.dart:173 — stale return does not dispose a newly opened losing handle
  - lib/features/script_import/pdf_page_view.dart:103 — dispose cannot close a handle that finishes opening afterward
- **Decision:** Rapid remount/page changes while openFile is in flight can overwrite a handle or assign one after dispose, leaving the losing native document undisposed.
- **Recommendation:** Serialize document opening and dispose any newly opened document whose generation or mounted state is stale before assignment.

### V-334 · LOW · Paddle detach is unsynchronized with loaders and OCR workers

- **Candidates:** CC-0095, CC-0096, CC-0097, CC-0098, CC-0099, CC-0100, CC-0101, CC-0102, CC-0103
- **Provenance:** `android-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `kotlin-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:64-81 — attach starts a loader thread while detach closes and nulls sessions without coordination
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:83-107 — the loader can assign sessions and ready after detach
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:139-164 — OCR jobs run on independent background threads
- **Decision:** One lifecycle root cause creates both late-load leaks and close-versus-run races during Flutter engine teardown/hot restart. It is device-local and teardown-dependent.
- **Recommendation:** Serialize load/run/close through one executor or lifecycle lock, reject work after detach, and close locally-created sessions when publication loses the lifecycle race.

### V-335 · LOW · Paddle loading wait can requeue forever

- **Candidates:** CC-0105, CC-0106, CC-0107, CC-0108, CC-0109, CC-0110, CC-0111
- **Provenance:** `android-performance-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:118-127 — every call while loading starts a raw 15-second polling thread and reposts the same call regardless of timeout
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:73-80 — detach does not cancel pending waiter threads
- **Decision:** A stuck loader re-enters the same branch with a fresh deadline, retaining the Result and creating another thread indefinitely; normal warm-up also creates one waiter per early request.
- **Recommendation:** Use a single load-completion future/latch and resolve each pending Result once with NOT_READY on a fixed per-call deadline or detach.

### V-336 · LOW · Paddle OCR model construction blocks plugin registration

- **Candidates:** CC-0659, CC-0660, CC-0661, CC-0662
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/PaddleOcrPlugin.swift:60 — init calls loadModels synchronously
  - ios/Runner/PaddleOcrPlugin.swift:118 — constructs both ORT sessions before returning
  - ios/Runner/PaddleOcrPlugin.swift:124 — records model-load duration during registration
- **Decision:** Plugin registration runs on the UI thread, so synchronous asset discovery and two ORT session constructions delay startup.
- **Recommendation:** Lazy-load or initialize on a worker queue and gate requests on a loading/ready state.

### V-337 · LOW · Paddle recognition runs one session per detected line

- **Candidates:** CC-0683
- **Provenance:** `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/PaddleOcrPlugin.swift:258 — iterates every detected box
  - ios/Runner/PaddleOcrPlugin.swift:260 — invokes recognize separately per crop
  - ios/Runner/PaddleOcrPlugin.swift:338 — each recognize performs a separate ORT run
- **Decision:** Pages with many lines pay repeated tensor allocation and fixed session-dispatch overhead, a source-proven scaling cost in the import hot path.
- **Recommendation:** Batch compatible recognition crops or reuse buffers if profiling confirms the expected page-time reduction.

### V-338 · LOW · Parse-stats substring matching inflates roster accuracy

- **Candidates:** CC-2738, CC-2739, CC-2740, CC-2741
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tool/parse_stats.dart:61 — match accepts got.contains(expected)
  - tool/parse_stats.dart:62 — reverse expected.contains(got) is also accepted
  - tool/parse_stats.dart:65 — every parsed/expected pair is scanned
  - tool/parse_stats.dart:71 — all substring hits are marked matched
- **Decision:** A short OCR phantom such as LI or BE can count as a real longer name and suppress both missing and phantom counts, biasing tuning decisions.
- **Recommendation:** Require exact/token-boundary normalized matches or a minimum-length edit-distance rule.

### V-339 · LOW · Partial Android signing properties fail with opaque casts

- **Candidates:** CC-0011, CC-0012
- **Provenance:** `kotlin-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - android/app/build.gradle.kts:46-50 — four required values are cast directly with `as String` when the file merely exists
- **Decision:** An existing but incomplete key.properties reaches unchecked casts and fails configuration without a field-specific diagnostic. This is operator-only build reliability.
- **Recommendation:** Validate each required property with a named GradleException before assigning signingConfig fields.

### V-340 · LOW · PDF harness accepts negative page indexes as success

- **Candidates:** CC-2307
- **Provenance:** `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/test_pdf_import.swift:17-24 — any parsed integer is accepted
  - scripts/test_pdf_import.swift:38-48 — range check omits page >= 0 and exits 0 when PDFKit returns no page
- **Decision:** An operator typo such as --page -1 produces no page output and a successful exit instead of an actionable error.
- **Recommendation:** Require 0 <= page < pageCount and fail nonzero otherwise.

### V-341 · LOW · PDF highlight diagnostics persist script text

- **Candidates:** CC-1837, CC-1838
- **Provenance:** `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_import/pdf_page_view.dart:270 — logs every locate diagnostic
  - lib/features/script_import/pdf_page_view.dart:274 — includes up to 40 characters of target dialogue
  - lib/data/services/debug_log_service.dart:109 — persists logs to Documents/debug_log.txt
- **Decision:** User script dialogue is copied into a user-exportable support log, expanding accidental disclosure when logs are shared.
- **Recommendation:** Log page, counts, and match status only; omit target text.

### V-342 · LOW · PDF viewer retains up to four large decoded pages

- **Candidates:** CC-1813, CC-1815
- **Provenance:** `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_import/pdf_page_view.dart:60 — cache holds four pages
  - lib/features/script_import/pdf_page_view.dart:184 — renders with two-times zoom headroom
  - lib/features/script_import/pdf_page_view.dart:191 — permits up to three-times intrinsic width
- **Decision:** Manual page flips can retain several multi-megabyte RGBA images per mounted viewer, and an overlaid sheet can coexist with its underlying viewer.
- **Recommendation:** Use a byte budget or smaller cache/zoom headroom on memory-constrained devices.

### V-343 · LOW · PDFKit extraction retains per-page autoreleased objects

- **Candidates:** CC-2117
- **Provenance:** `ios-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - macos/Runner/PdfTextPlugin.swift:73-78 — extractText loops over every page string without a per-page autoreleasepool.
  - macos/Runner/PdfTextPlugin.swift:112-118 — extractTextPerPage repeats the same whole-document loop.
- **Decision:** Large PDFs can retain Objective-C/PDFKit bridge intermediates until the dispatch block ends, spiking peak memory.
- **Recommendation:** Wrap each page extraction body in autoreleasepool.

### V-344 · LOW · PDFKit imports store line-on-page as zero

- **Candidates:** CC-1036, CC-1037, CC-1038, CC-1039, CC-1040, CC-1041, CC-1042, CC-1043, CC-1044, CC-1045, CC-1046
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/script_import_service.dart:755-772 — every successful PDFKit source match returns lineOnPage: 0.
  - lib/data/models/script_models.dart:77-85 — pageLineRef exposes sourceLineOnPage in page references.
- **Decision:** All text-based PDF lines receive an invalid zero position, degrading references and page targeting.
- **Recommendation:** Compute the one-based offset within the matched page, sharing the OCR helper.

### V-345 · LOW · PDFKit page mapping can stall after unmatched lines

- **Candidates:** CC-1035
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/script_import_service.dart:135-149 — rawSearchStart advances only after a mapping match.
  - lib/data/services/script_import_service.dart:755-775 — each failed lookup searches only the same bounded forward window.
- **Decision:** After a sufficiently long unmatched run, later valid lines outside the frozen window lose source-page attribution.
- **Recommendation:** Advance using a document-position estimate or reuse the OCR mapper’s dual-anchor recovery.

### V-346 · LOW · Per-line keys defeat PDF document and page caching

- **Candidates:** CC-1814, CC-1823
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:503 — keys the viewer by line ID
  - lib/features/script_import/ocr_review_screen.dart:693 — also keys by selected line ID
  - lib/features/script_import/pdf_page_view.dart:102 — remount evicts every cached image
  - lib/features/script_import/pdf_page_view.dart:103 — remount closes the reused document
- **Decision:** Selecting another line on the same page creates a new State, reopening/rerendering/re-OCRing instead of using the class caches, which is a realistic navigation hot path.
- **Recommendation:** Keep a stable key for a PDF/viewer pane and make didUpdateWidget correctly relocalize highlight text.

### V-347 · LOW · Persisted remote URL suppresses cloud reconciliation

- **Candidates:** CC-0969
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/recording_sync_service.dart:327-345 — any local recording with a nonempty remoteUrl is skipped before comparing current cloud rows.
- **Decision:** If its metadata/object is removed remotely, the local take is never retried and castmates remain without it.
- **Recommendation:** Reconcile remoteUrl entries against the current user’s cloud rows and requeue missing takes.

### V-348 · LOW · Phone harness comment promises cleanup traps that do not exist

- **Candidates:** CC-2249, CC-2250
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/phone-harness.sh:13 — the script deliberately omits set -e
  - scripts/phone-harness.sh:40 — comment says cleanup traps always fire
  - scripts/phone-harness.sh:55 — later ADB setup commands are unchecked
  - scripts/phone-harness.sh:1 — repository search finds no trap statement in the file
- **Decision:** Failures after staging can be ignored and leave device state changed, contrary to the maintenance comment's asserted cleanup guarantee.
- **Recommendation:** Add real cleanup traps and explicit load-bearing error checks, or correct the comment and failure model.

### V-349 · LOW · Phone harness uses a predictable shared temporary directory

- **Candidates:** CC-2254
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/phone-harness.sh:45 — staging always uses /tmp/kroko-min
  - scripts/phone-harness.sh:48 — model files are copied through that path
  - scripts/phone-harness.sh:51 — the resulting directory is trusted and pushed to the device
- **Decision:** On a multi-user developer host, a precreated symlink can redirect writes or substitute staged model content.
- **Recommendation:** Use mktemp -d under TMPDIR with a cleanup trap.

### V-350 · LOW · Playback failure can leave studio stuck in playing state

- **Candidates:** CC-1559
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/recording_studio/recording_studio_screen.dart:723-739 — status becomes playing before player.play, but catch only shows a toast.
- **Decision:** If play throws after the status update, controls remain in the playing state until another action resets them.
- **Recommendation:** Reset status in the catch when mounted.

### V-351 · LOW · Post-download Kokoro exceptions are mislabeled as download failures

- **Candidates:** CC-1893
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/ai_models_screen.dart:63 — download and extraction start the shared try block
  - lib/features/settings/ai_models_screen.dart:81 — engine loading runs in the same try
  - lib/features/settings/ai_models_screen.dart:101 — every thrown error is labeled Download failed
- **Decision:** If initialization throws after files were successfully downloaded, the user receives the wrong failure stage and cannot distinguish load troubleshooting from network/download failure.
- **Recommendation:** Separate download and load error handling and preserve downloaded-file readiness independently.

### V-352 · LOW · Preview uses a different character color mapping

- **Candidates:** CC-1867, CC-1868, CC-1869, CC-1870, CC-1871
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_import/script_import_screen.dart:238-253 — cast avatars use ScriptCharacter.colorIndex
  - lib/features/script_import/script_import_screen.dart:520-533 — dialogue headers instead use character.hashCode
- **Decision:** The same role can display different colors between the cast list and preview, undermining the screen’s visual association.
- **Recommendation:** Resolve the matching ScriptCharacter and use its colorIndex for dialogue preview text.

### V-353 · LOW · Primary auth failures are absent from diagnostic logs

- **Candidates:** CC-1335, CC-1336
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/auth/auth_screen.dart:358 — _submit catches all authentication errors
  - lib/features/auth/auth_screen.dart:360 — the catch updates only UI state
  - lib/features/auth/auth_screen.dart:401 — the resend path demonstrates the available DebugLogService error pattern
- **Decision:** A real Supabase outage or unexpected signin failure leaves no app diagnostic record, preventing support logs from distinguishing service failures from credential errors.
- **Recommendation:** Log the raw exception with non-sensitive context before presenting the friendly message.

### V-354 · LOW · Production audio cleanup serializes every file operation

- **Candidates:** CC-0769, CC-0770, CC-0771, CC-0772, CC-0773, CC-0774, CC-0775, CC-0776
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/repositories/production_repository.dart:43 — recordings are processed in a sequential for loop
  - lib/data/repositories/production_repository.dart:47 — exists is awaited per row
  - lib/data/repositories/production_repository.dart:48 — delete is then awaited per row
- **Decision:** Deletion wall time grows with two serialized file-system round trips per recording, which is noticeable for fully recorded long scripts.
- **Recommendation:** Use bounded parallel deletion or delete a production-owned recording directory.

### V-355 · LOW · Production deletion is not transactional

- **Candidates:** CC-2155
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/repositories/production_repository.dart:42-60 — related recordings, lines, scenes, cast, and production rows are deleted by separate awaited statements.
  - lib/data/repositories/production_repository.dart:139-145 — the repository already uses a transaction for destructive replace operations.
- **Decision:** A crash or later delete error leaves a partially deleted production with orphaned local rows.
- **Recommendation:** Run all database deletes in one Drift transaction; keep file deletion best-effort outside it.

### V-356 · LOW · Production settings expose deliberate Crashlytics crash actions

- **Candidates:** CC-1926, CC-1927, CC-1928, CC-1929, CC-1930, CC-1931, CC-1932, CC-1933
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/settings/debug_log_screen.dart:131-190 — fatal exception and native SIGABRT actions are not gated by kDebugMode
  - lib/features/settings/settings_screen.dart:276-283 — Debug Log is reachable from normal Settings
- **Decision:** A production user can intentionally or accidentally terminate the app and generate synthetic fatal reports from ordinary settings UI. Labels are explicit, limiting severity.
- **Recommendation:** Hide destructive diagnostics outside debug/diagnostic builds or require a protected developer mode and confirmation.

### V-357 · LOW · Production title is logged on every hub rebuild

- **Candidates:** CC-1507
- **Provenance:** `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/production_hub/production_hub_screen.dart:166 — debugPrint includes production title, line count, and selected character without a debug-mode guard
- **Decision:** User production data is emitted repeatedly to release console/device logs.
- **Recommendation:** Remove the log or guard non-sensitive diagnostics with kDebugMode.

### V-358 · LOW · Production-submit guard remains latched after local persistence failure

- **Candidates:** CC-1470
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/home/home_screen.dart:598 — submitting flag is set before persistence
  - lib/features/home/home_screen.dart:630 — add is awaited without finally
  - lib/features/home/home_screen.dart:633 — flag resets only on success
- **Decision:** A storage/database exception leaves the screen instance permanently rejecting later Create attempts.
- **Recommendation:** Wrap the submission body in try/finally and show the persistence error.

### V-359 · LOW · Proper-noun spelling silently drops nonletters

- **Candidates:** CC-0600, CC-0601
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/Lexicon/Lexicon.swift:312-324 — getNNP uses compactMap and then checks the resulting list for nil, which can never succeed.
- **Decision:** Mixed proper nouns can lose digits or symbols and return a partial or empty phoneme instead of falling through to the normal fallback.
- **Recommendation:** Use map to preserve failed characters and return nil when any component cannot be spelled.

### V-360 · LOW · PyMuPDF dependency is unpinned

- **Candidates:** CC-2225
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/pdf_to_script.py:26 — pymupdf is imported at runtime
  - pubspec.yaml:1 — Dart manifest does not manage Python dependencies
- **Decision:** No requirements or pyproject file exists, so operator results can change with arbitrary installed PyMuPDF versions.
- **Recommendation:** Add a Python dependency manifest with a tested pinned/compatible version.

### V-361 · LOW · Queue cancellation tests use fixed-delay synchronization

- **Candidates:** CC-0224, CC-0225
- **Provenance:** `security-review@deepinfra-zai-org-glm-5.3-flash`, `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/kokoro_service_queue_macos_test.dart:82 — urgent supersede waits a fixed 200 ms
  - integration_test/kokoro_service_queue_macos_test.dart:99 — prefetch supersede repeats the same fixed wait
- **Decision:** On faster or loaded hardware the first synthesis may finish before the delay or may not yet enter generation, making the result timing-dependent.
- **Recommendation:** Expose a test hook/state signal and trigger the urgent request only after generation is confirmed in flight.

### V-362 · LOW · Queue integration test accepts a stale partial staged pack

- **Candidates:** CC-0222
- **Provenance:** `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/kokoro_service_queue_macos_test.dart:33 — any existing destination directory skips staging
  - integration_test/kokoro_service_queue_macos_test.dart:51 — readiness checks only the limited ModelManager file set
- **Decision:** A crashed copy can leave a directory that bypasses restaging and supplies stale or partial fixture files.
- **Recommendation:** Validate a fixture manifest/hash or restage atomically via a temporary directory.

### V-363 · LOW · Queue persistence rewrites and fsyncs the full queue per mutation

- **Candidates:** CC-1206, CC-1207, CC-1208, CC-1209, CC-1210, CC-1221, CC-1224, CC-1225
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `metal-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `metal-performance-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/sync_queue.dart:182 — every persist JSON-encodes pending plus failed
  - lib/data/services/sync_queue.dart:192 — every snapshot is written with flush true
  - lib/data/services/sync_queue.dart:401 — draining invokes persist per completed job
- **Decision:** Draining N queued recordings performs repeated whole-snapshot writes, producing quadratic bytes and many fsyncs. Typical impact is low because jobs are small, but the scaling claim is real.
- **Recommendation:** Coalesce mutations or use an append/log/database representation with periodic compaction.

### V-364 · LOW · Rapid voice-sheet actions can pop the underlying route

- **Candidates:** CC-1421
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/cast_manager/cast_manager_screen.dart:1262 — Reset is async with no in-flight guard
  - lib/features/cast_manager/cast_manager_screen.dart:1278 — Save is also async with no guard
  - lib/features/cast_manager/cast_manager_screen.dart:1273 — each completion pops the navigator
- **Decision:** Two accepted taps can complete twice: the first dismisses the sheet and the second pop removes the cast screen.
- **Recommendation:** Disable both actions while either persistence operation is pending and pop at most once.

### V-365 · LOW · Raw exception details are shown in user snackbars

- **Candidates:** CC-1519
- **Provenance:** `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/production_hub/production_hub_screen.dart:791 — push displays $e
  - lib/features/production_hub/production_hub_screen.dart:861 — sync displays $e
  - lib/features/production_hub/production_hub_screen.dart:910 — export displays $e
- **Decision:** Filesystem paths, Supabase details, and implementation messages can appear in screenshots/device UI; exposure is limited to the user’s own device.
- **Recommendation:** Log full exceptions privately and show stable generic user messages.

### V-366 · LOW · Re-record action loses the selected line and character

- **Candidates:** CC-1578, CC-1579, CC-1580
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/recording_studio/recordings_browser_screen.dart:470 — tile exposes Re-record
  - lib/features/recording_studio/recordings_browser_screen.dart:473 — callback has the line and recording in scope
  - lib/features/recording_studio/recordings_browser_screen.dart:474 — it pushes only the generic /record route
- **Decision:** The action promises a line-specific re-record but passes no provider state or route parameter, so the user must rediscover the target.
- **Recommendation:** Set the character/line selection and route directly to the recording studio, or relabel this as generic Record.

### V-367 · LOW · Readthrough completions are omitted from rehearsal history

- **Candidates:** CC-1653, CC-1654, CC-1655, CC-1656
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:369 — readthrough intentionally runs without a character
  - lib/features/rehearsal/rehearsal_screen.dart:1793 — all modes call _saveSession at completion
  - lib/features/rehearsal/rehearsal_screen.dart:3249 — _saveSession returns when character is null
  - lib/features/rehearsal/rehearsal_history_screen.dart:174 — history UI explicitly renders a Readthrough mode label
- **Decision:** Every completed readthrough takes the early return, despite history having UI support for readthrough sessions.
- **Recommendation:** Persist readthrough with an explicit all-cast/sentinel character representation and appropriate totals.

### V-368 · LOW · Record-only stop does not end SttService listening state

- **Candidates:** CC-1157, CC-1158, CC-1160
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/stt_service.dart:395-409 — startLineCapture sets _isListening and installs the level hook
  - lib/data/services/stt_service.dart:423-436 — stopRecording only delegates to native and leaves listening/session state unchanged
  - lib/features/rehearsal/rehearsal_screen.dart:3007-3015 — Android uses startLineCapture as the documented record-only path
- **Decision:** The paired record-only API leaves isListening true and retains internal endpointing hooks until a separate stop happens, making its standalone contract inconsistent.
- **Recommendation:** Provide stopLineCapture or make stopRecording reset _isListening, silence state, and the channel level hook for record-only sessions.

### V-369 · LOW · Recording bursts rebuild and rescan visible cast cards

- **Candidates:** CC-1396
- **Provenance:** `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/cast_manager/cast_manager_screen.dart:174 — the screen root watches the whole recordings map
  - lib/features/cast_manager/cast_manager_screen.dart:382 — every notification rebuilds the character list
  - lib/features/cast_manager/cast_manager_screen.dart:392 — each realized card filters all lines for that character against recordings
- **Decision:** Per-recording sync notifications cause repeated whole-screen rebuilds and per-visible-character line scans.
- **Recommendation:** Watch/select precomputed recorded counts per character instead of the whole map at screen root.

### V-370 · LOW · Recording cache and manifest grow without eviction

- **Candidates:** CC-0962, CC-0963, CC-0964, CC-0965
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `metal-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/recording_sync_service.dart:124-125 — the process-global cache indexes every downloaded line.
  - lib/data/services/recording_sync_service.dart:190-194 — manifest persistence snapshots and JSON-encodes the whole cache.
  - lib/data/services/recording_sync_service.dart:675-695 — entries shrink only through explicit cache-clear APIs.
- **Decision:** Opening productions accumulates recordings indefinitely and makes later manifest work scale with lifetime cache history.
- **Recommendation:** Introduce an age/size cap and prune cache entries and files together.

### V-371 · LOW · Recording character filter drops multi-character takes

- **Candidates:** CC-1564, CC-1565, CC-1566, CC-1567
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/recording_studio/recordings_browser_screen.dart:74 — recordings are joined to script lines
  - lib/features/recording_studio/recordings_browser_screen.dart:79 — filter compares only line.character
  - lib/features/recording_studio/recordings_browser_screen.dart:108 — filter chips are derived from recording.character
  - lib/data/models/script_models.dart:70 — isForCharacter includes multiCharacters
- **Decision:** A take credited to an individual on a combined cue can have a recording.character matching the chip while line.character is the combined cue, so selecting the actor hides the take.
- **Recommendation:** Filter by recording.character or line.isForCharacter and label consistently.

### V-372 · LOW · Recording deletion leaves storage objects orphaned

- **Candidates:** CC-2465, CC-2466
- **Provenance:** `db-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `db-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260703140000_security_lockdown.sql:57 — storage has a SELECT policy
  - supabase/migrations/20260703140000_security_lockdown.sql:65 — storage has an INSERT policy
  - supabase/migrations/20260703140000_security_lockdown.sql:73 — storage has an UPDATE policy but no DELETE policy
  - supabase/migrations/20260703170000_recordings_delete_policy.sql:6 — only the recordings table gains DELETE
  - lib/features/recording_studio/recordings_browser_screen.dart:563 — UI deletion removes the table row, not the storage object
- **Decision:** Deleting takes or productions cannot delete their blobs through the authenticated client, so private unreachable objects accumulate indefinitely.
- **Recommendation:** Add an owner/organizer-scoped storage DELETE policy and delete the object before/with metadata cleanup.

### V-373 · LOW · Recording downloads overwrite final files non-atomically

- **Candidates:** CC-0975
- **Provenance:** `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/recording_sync_service.dart:428-439 — full sync writes downloaded bytes directly to the final cache path.
  - lib/data/services/recording_sync_service.dart:635-641 — realtime sync uses the same direct overwrite.
- **Decision:** Interruption or disk-full can truncate a previously usable cache file that later existence checks still accept.
- **Recommendation:** Write and fsync a sibling temporary file, then atomically rename it into place.

### V-374 · LOW · Recording playback stats a file synchronously outside error handling

- **Candidates:** CC-1588, CC-1589, CC-1590, CC-1591, CC-1592, CC-1593
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/recording_studio/recordings_browser_screen.dart:651 — path resolution is awaited
  - lib/features/recording_studio/recordings_browser_screen.dart:670 — lengthSync runs before the try block
  - lib/features/recording_studio/recordings_browser_screen.dart:686 — playback try/catch begins later
- **Decision:** Deletion or eviction between resolution and stat throws out of the tap handler, and the synchronous stat runs on the UI isolate.
- **Recommendation:** Use await File(resolvedPath).length inside the existing try/catch and show the missing-file feedback on failure.

### V-375 · LOW · Recording sync launches even after the prerequisite local load fails

- **Candidates:** CC-0729
- **Provenance:** `db-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/app.dart:258-268 — load errors are caught, but launchRecordingSync runs unconditionally afterward
  - lib/providers/production_providers.dart:460-479 — sync assumes local recordings were loaded before it reads the provider
- **Decision:** A database read failure leaves empty or stale state but still starts reconciliation, creating a missed-upload/re-download window.
- **Recommendation:** Return from the listener after load failure and surface a retry before launching sync.

### V-376 · LOW · ReflectionPad1d performs zero padding

- **Candidates:** CC-0423, CC-0424, CC-0425, CC-0426, CC-0427, CC-0428, CC-0429
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroVendored/BuildingBlocks/ReflectionPad1d.swift:8-16 — ReflectionPad1d delegates to MLX.padded without reflected slices.
  - ios/Runner/KokoroVendored/Decoder/Generator.swift:171 — the layer feeds the generator final convolution.
- **Decision:** Every MLX synthesis uses constant boundary samples where the named/reference operation requires reflected samples, creating a small deterministic boundary mismatch.
- **Recommendation:** Implement reflection with reversed edge slices and add a numerical reference check.

### V-377 · LOW · Rehearsal demo writes fixture data to the persistent app database

- **Candidates:** CC-0241, CC-0242
- **Provenance:** `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/rehearsal_demo_test.dart:39 — the test constructs the production AppDatabase
  - lib/data/database/app_database.dart:116 — AppDatabase opens the normal connection
  - integration_test/rehearsal_demo_test.dart:66 — the Hamlet production is persisted without cleanup
- **Decision:** Running the demo on a simulator/device leaves its generated production in normal app storage, making runs non-hermetic.
- **Recommendation:** Use AppDatabase.forTesting with an in-memory executor or delete the fixture in teardown.

### V-378 · LOW · Rehearsal history is process-only despite persistent UI

- **Candidates:** CC-1597, CC-1598
- **Provenance:** `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_history_screen.dart:9-30 — history is an in-memory StateNotifier capped at 100.
  - lib/features/rehearsal/rehearsal_history_screen.dart:44-84 — the production screen presents prior sessions and lifetime summary stats.
- **Decision:** All displayed sessions and stats disappear on process death with no session-only label.
- **Recommendation:** Persist sessions locally or explicitly label the screen as current-session history.

### V-379 · LOW · Rehearsal recording harness can succeed with broken visual content

- **Candidates:** CC-0238, CC-0240
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `testing-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/rehearsal_demo_test.dart:34 — the demo is registered as a testWidgets test
  - integration_test/rehearsal_demo_test.dart:91 — it navigates to rehearsal without checking rendered content
  - integration_test/rehearsal_demo_test.dart:94 — it only holds for the external recorder and has no expectations
- **Decision:** A route that renders the wrong or empty rehearsal surface can still produce a green test and a broken recorded asset.
- **Recommendation:** Assert the expected rehearsal widgets before the recording hold.

### V-380 · LOW · Remote jump-back can land on the actor’s own first line

- **Candidates:** CC-1640, CC-1641
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:2810 — target clamps to zero
  - lib/features/rehearsal/rehearsal_screen.dart:2814 — loop runs while target is the actor
  - lib/features/rehearsal/rehearsal_screen.dart:2815 — decrementing zero clamps back to zero
  - lib/features/rehearsal/rehearsal_screen.dart:2816 — loop then breaks without restoring the cue invariant
- **Decision:** When no earlier cue exists, the target remains an actor line despite the documented guarantee, so remote jump-back begins listening rather than playing a setup cue.
- **Recommendation:** Detect the no-earlier-cue case and return or choose an explicitly documented fallback.

### V-381 · LOW · Removed rehearsal character remains selected

- **Candidates:** CC-1510
- **Provenance:** `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/production_hub/production_hub_screen.dart:164 — hub watches persisted rehearsalCharacterProvider
  - lib/features/production_hub/production_hub_screen.dart:250 — dropdown derives valid choices from current script characters
- **Decision:** After edits/cloud sync remove the selected character, provider/preferences retain a name no longer represented by the UI while rehearsal logic still consumes it.
- **Recommendation:** Detect invalid selection when script changes and clear provider plus persisted preference.

### V-382 · LOW · Reorder drop bypasses debounced script persistence

- **Candidates:** CC-1749
- **Provenance:** `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:608-648 — each completed reorder calls persistScript immediately.
  - lib/providers/production_providers.dart:267-307 — persistScript performs local persistence and an organizer cloud push.
- **Decision:** A drop on a very large script triggers an immediate full persistence/push rather than the editor’s normal debounce, causing avoidable bulk work.
- **Recommendation:** Use scheduleScriptSave after updating state.

### V-383 · LOW · Repeated ending words can be double-counted

- **Candidates:** CC-1149
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/stt_service.dart:301-308 — hits counts each expected tail occurrence whenever window.contains is true
- **Decision:** For endings with duplicate words, one recognized occurrence can satisfy multiple expected occurrences and prematurely meet the 2-of-3 condition.
- **Recommendation:** Match occurrences with consumption/order rather than independent contains checks.

### V-384 · LOW · Resolved OCR lines remain in cards and pending counts

- **Candidates:** CC-1791, CC-1792, CC-1793, CC-1794, CC-1795, CC-1796
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_import/ocr_review_screen.dart:165 — _reviewLines is an immutable original-status snapshot
  - lib/features/script_import/ocr_review_screen.dart:173 — pending count excludes only removed ids
  - lib/features/script_import/ocr_review_screen.dart:183 — Save changes only the live _byId status to ok
  - lib/features/script_import/ocr_review_screen.dart:462 — rendered reviewLines also excludes only removals
- **Decision:** Saving or accepting every line clears its live status but leaves every card and the header count present, while the walk-through correctly drops those same lines.
- **Recommendation:** Filter cards and counts by the current _byId reviewStatus.

### V-385 · LOW · Retry retains stale per-model progress rows

- **Candidates:** CC-1958, CC-1959, CC-1966, CC-1967, CC-1968
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/settings/model_download_screen.dart:24 — progress map persists for the State lifetime
  - lib/features/settings/model_download_screen.dart:55 — download start does not clear it
  - lib/features/settings/model_download_screen.dart:184 — Retry reuses the same state
- **Decision:** After a failed attempt, old percentages remain visible during the next attempt until each key reports new progress.
- **Recommendation:** Clear _modelProgress when starting a new download attempt.

### V-386 · LOW · RLS membership helper performs a row-correlated function probe

- **Candidates:** CC-2426
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/migrations/20260703140000_security_lockdown.sql:199 — is_production_member remains a SECURITY DEFINER stable SQL function
  - supabase/migrations/20260703140000_security_lockdown.sql:203 — it probes cast_members by the candidate row production id
  - supabase/migrations/20260314140000_fix_rls_recursion.sql:80 — script_lines SELECT invokes it per candidate row
  - supabase/migrations/20260801130000_cast_members_rls_index.sql:10 — a later index makes each probe cheaper but does not remove per-row calls
- **Decision:** Large script/recording result sets evaluate a non-inlineable definer function correlated on each row, adding repeated membership index probes to ordinary sync reads.
- **Recommendation:** Use a query/policy shape that evaluates membership once per production where possible, and confirm with EXPLAIN ANALYZE.

### V-387 · LOW · Running-header filter is hardcoded to Macbeth

- **Candidates:** CC-2238
- **Provenance:** `python-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/pdf_to_script.py:228 — only literal Macbeth is skipped
  - scripts/pdf_to_script.py:257 — other centered title text can fall into dialogue output
- **Decision:** Other declared plays can emit their repeated running title on every page.
- **Recommendation:** Detect the document title dynamically or filter repeated-position headers generically.

### V-388 · LOW · Same-account simulation misconfiguration exits successfully

- **Candidates:** CC-2749
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tool/sim_multi_user.dart:80-84 — same user records a failure then returns from inside try
  - tool/sim_multi_user.dart:315-344 — finally runs, but return skips the nonzero exit after the summary
- **Decision:** CI or an operator wrapper sees status 0 despite the harness detecting invalid two-user setup.
- **Recommendation:** Exit nonzero after cleanup, for example by throwing a controlled failure or avoiding the early return.

### V-389 · LOW · Scene 1 label compares the first blocks of the entire files

- **Candidates:** CC-2171
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/compare_macbeth_versions.py:116 — section is labeled Scene 1
  - scripts/compare_macbeth_versions.py:118 — dialogue blocks are collected from full text
  - scripts/compare_macbeth_versions.py:124 — comparison simply starts at index zero
- **Decision:** Front matter and earlier false cues can be reported as Scene 1 without locating scene boundaries.
- **Recommendation:** Locate ACT/SCENE boundaries before selecting comparison blocks.

### V-390 · LOW · Scene export loses the song marker

- **Candidates:** CC-1000
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/script_export.dart:84 — full text prefixes song lines with a music marker
  - lib/data/services/script_export.dart:120 — scene export merges dialogue and song cases
  - lib/data/services/script_export.dart:125 — merged output has no song marker
- **Decision:** The same song is distinguishable in full export but rendered as ordinary dialogue in scene export.
- **Recommendation:** Give LineType.song its own scene-export branch and marker.

### V-391 · LOW · Scene headers are not emitted as records

- **Candidates:** CC-2211, CC-2212
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/parse_script.py:255-273 — ACT headers append HEADER records
  - scripts/parse_script.py:276-285 — SCENE headers update state and continue without appending a record
  - scripts/parse_script.py:218-225 — subsequent records do retain current_scene
- **Decision:** Explicit scene titles disappear as standalone output/header boundaries, although the scene field on following JSON lines is preserved; the candidates overstate that latter loss.
- **Recommendation:** Append a HEADER record for each scene while continuing to populate current_scene.

### V-392 · LOW · Scene partition failure messages escape interpolation

- **Candidates:** CC-2588, CC-2589, CC-2590, CC-2591, CC-2592, CC-2593, CC-2594
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `testing-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - test/scene_partition_test.dart:114 — StateError string contains escaped dollar interpolation
  - test/scene_partition_test.dart:121 — expect reason also contains escaped interpolation
- **Decision:** When either guard fails, it prints literal template text rather than the actual scene list or dialogue, removing the diagnostic data.
- **Recommendation:** Remove the backslashes before the dollar signs.

### V-393 · LOW · Scene split omits individual ensemble speakers

- **Candidates:** CC-1715, CC-1716, CC-1717, CC-1718, CC-1719, CC-1720, CC-1721
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/scene_editor_screen.dart:427 — first-half characters are derived only from line.character
  - lib/features/script_editor/scene_editor_screen.dart:434 — second half repeats that logic
  - lib/data/models/script_models.dart:437 — canonical character derivation credits multiCharacters individually
- **Decision:** After a split, combined cue text is recorded as one pseudo-character and individual ensemble actors disappear from scene membership/navigation.
- **Recommendation:** Use multiCharacters when non-empty in both halves, matching rebuildCharacters.

### V-394 · LOW · Screenshot generation has no content assertions

- **Candidates:** CC-0246
- **Provenance:** `testing-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/screenshot_test.dart:52 — screenshot flow is a testWidgets body
  - integration_test/screenshot_test.dart:89 — empty-home image is captured without an expectation
  - integration_test/screenshot_test.dart:101 — seeded-home image is captured without an expectation
  - integration_test/screenshot_test.dart:132 — rehearsal image is captured without checking rendered lines
- **Decision:** A blank or semantically wrong screen can still be captured and the harness completes, so generated store imagery is not guarded against content regressions.
- **Recommendation:** Add a small content expectation before each materially different screenshot.

### V-395 · LOW · Screenshot harness persists auth-bypass preferences

- **Candidates:** CC-0247
- **Provenance:** `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/screenshot_test.dart:57 — real SharedPreferences instance is opened
  - integration_test/screenshot_test.dart:58 — auth_skipped is set true
  - integration_test/screenshot_test.dart:59 — screenshot_mode is set true
  - integration_test/screenshot_test.dart:167 — test ends without teardown that removes either key
- **Decision:** The flags remain in the simulator/device preference store and affect later launches.
- **Recommendation:** Register teardown that removes both keys even when the flow fails.

### V-396 · LOW · Screenshot harness uses the persistent application database

- **Candidates:** CC-0249, CC-0250, CC-0251, CC-0252
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `testing-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/screenshot_test.dart:61 — comment claims a clean in-memory database
  - integration_test/screenshot_test.dart:62 — code constructs default AppDatabase
  - lib/data/database/app_database.dart:116 — default constructor uses the normal connection
  - lib/data/database/app_database.dart:316 — normal connection opens application storage
- **Decision:** The default constructor is not in-memory, so seeded data and prior rows can pollute the empty-state image and persist after the run.
- **Recommendation:** Use AppDatabase.forTesting with a memory executor and close it in teardown.

### V-397 · LOW · Script locale cloud writes are dropped without error handling

- **Candidates:** CC-2162
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_import/script_import_screen.dart:361-378 — locale and preset futures are invoked without await, unawaited annotation, or catch
- **Decision:** A network/RLS failure becomes an unhandled future and leaves cloud metadata stale while local state appears saved.
- **Recommendation:** Await both writes with user-visible failure handling, or use explicitly caught background synchronization.

### V-398 · LOW · Script validation excludes sung dialogue

- **Candidates:** CC-1782, CC-1783, CC-1787
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/models/script_models.dart:3 — dialogue is a spoken line type
  - lib/data/models/script_models.dart:6 — song is a distinct sung line type
  - lib/features/script_editor/validation_panel.dart:38 — attribution filters only dialogue
  - lib/features/script_editor/validation_panel.dart:87 — dialogue-ratio count also filters only dialogue
- **Decision:** Song lines with missing speakers evade attribution, and song-heavy scripts receive a misleading low dialogue ratio.
- **Recommendation:** Treat dialogue and song as attributed/spoken content for these checks.

### V-399 · LOW · Script-scenes migration retains a duplicate composite index

- **Candidates:** CC-2424
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/migrations/20260813100000_add_script_scenes.sql:13-25,45-46 — unique(production_id, sort_order) and an identical explicit index are both created
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:207-211 — later cleanup drops only the script_lines duplicate
- **Decision:** Current effective schema still maintains two equivalent indexes for script_scenes writes. The older script_lines duplicate has been fixed by the later migration.
- **Recommendation:** Add a later migration dropping idx_script_scenes_production.

### V-400 · LOW · Security-definer membership helpers are callable by anon

- **Candidates:** CC-2486, CC-2487, CC-2488
- **Provenance:** `db-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `sql-migration-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/migrations/20260703140000_security_lockdown.sql:215-216 — the lockdown revoked helper execution from anon.
  - supabase/migrations/20260703150000_fix_helper_grants.sql:15-16 — the later migration grants both membership helpers back to anon.
- **Decision:** Unauthenticated callers who know user and production UUIDs can use the helpers as a cross-tenant membership/organizer boolean oracle.
- **Recommendation:** Grant execution only to authenticated, or constrain helpers to auth.uid() for external calls.

### V-401 · LOW · Self-update policy permits cast-role spoofing

- **Candidates:** CC-2478, CC-2479, CC-2481
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260703140000_security_lockdown.sql:125 — a caller can update their own cast row
  - supabase/migrations/20260703140000_security_lockdown.sql:126 — new-row check validates only user_id
  - lib/data/database/app_database.dart:97 — application cast rows include organizer/primary/understudy roles
  - lib/features/cast_manager/cast_manager_screen.dart:141 — client behavior does treat organizer-role rows specially
- **Decision:** A member can change their row role and distort roster/UI behavior. Server organizer authorization still uses productions.organizer_id, so the candidate's claimed database privilege escalation is refuted and severity is reduced.
- **Recommendation:** Make role immutable to self-service updates; authorize any role transition in organizer-only RPCs.

### V-402 · LOW · Share flow uses context after an unguarded delay

- **Candidates:** CC-1733, CC-1734, CC-1735
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:155-160 — after popping and waiting 300 ms, the code calls findRenderObject without a mounted check.
- **Decision:** Rapid navigation during the delay can make the context defunct before share-origin lookup.
- **Recommendation:** Check context.mounted immediately after the delay.

### V-403 · LOW · Shared lines are not highlighted as the recording actor

- **Candidates:** CC-1544
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/recording_studio/recording_studio_screen.dart:239-244 — the studio list comes from linesForCharacter, which includes shared lines.
  - lib/features/recording_studio/recording_studio_screen.dart:382 — context highlighting compares only line.character to the actor.
- **Decision:** A multi-character line included for recording is displayed as another speaker instead of YOU.
- **Recommendation:** Use ScriptLine.isForCharacter for context highlighting.

### V-404 · LOW · Short OCR target can be discarded after a full-line match

- **Candidates:** CC-0937
- **Provenance:** `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/ocr_highlight_matcher.dart:81 — either body or full text may establish containment
  - lib/data/services/ocr_highlight_matcher.dart:85 — excess is always computed from body length
  - lib/data/services/ocr_highlight_matcher.dart:86 — a negative body excess rejects the candidate
- **Decision:** When only the cue-included full line matches and the stripped body is shorter, the code rejects a valid short-target candidate.
- **Recommendation:** Track which representation matched and compute excess from that representation.

### V-405 · LOW · Sign-out uses WidgetRef after awaits without a mounted guard

- **Candidates:** CC-1994
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/settings/settings_screen.dart:328 — first await precedes later ref use
  - lib/features/settings/settings_screen.dart:334 — remote sign-out adds another async gap
  - lib/features/settings/settings_screen.dart:354 — ref is used unconditionally afterward
  - lib/features/settings/settings_screen.dart:357 — context.mounted is checked only after those ref reads
- **Decision:** Popping the route while sign-out is in flight can use a disposed Consumer element and abort local reset/navigation.
- **Recommendation:** Capture required notifiers before awaiting or return when context is unmounted before using ref.

### V-406 · LOW · Signed-out debug-report upload yields a generic failure

- **Candidates:** CC-1917
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/debug_log_screen.dart:71-81 — upload checks initialization but permits null user_id and “unknown” email
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:178-183 — current RLS requires user_id = auth.uid()
- **Decision:** An expired/signed-out session reaches an insert that current RLS rejects, surfaced only as a generic Send failed message. It does not permit anonymous upload.
- **Recommendation:** Require currentUser before insert and show a sign-in-specific message.

### V-407 · LOW · Silence detector uses a rebound pointer after its closure

- **Candidates:** CC-0306
- **Provenance:** `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/AppleSttPlugin.swift:544 — withMemoryRebound returns the pointer out of its closure
  - ios/Runner/AppleSttPlugin.swift:549 — vDSP dereferences it after the rebinding lifetime ended
- **Decision:** Swift guarantees the rebound binding only inside the closure; every silence-analysis pass executes this formally invalid access.
- **Recommendation:** Perform vDSP_vflt16 inside withMemoryRebound.

### V-408 · LOW · Silence script dereferences a rebound pointer after its closure

- **Candidates:** CC-2323, CC-2324, CC-2325
- **Provenance:** `ios-review@deepinfra-zai-org-glm-5.3-flash`, `media-provenance-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/test_silence_trim.swift:46 — withMemoryRebound returns its pointer from the closure
  - scripts/test_silence_trim.swift:49 — the pointer is used only after the closure returned
  - scripts/test_silence_trim.swift:50 — every decoded Int16 is dereferenced through the expired binding
- **Decision:** Swift's temporary memory binding is valid only for the closure duration, so the current analysis loop relies on undefined behavior.
- **Recommendation:** Move all pointer reads inside withMemoryRebound or copy through a correctly scoped unsafe buffer.

### V-409 · LOW · Silence script reuses predictable shared temporary files

- **Candidates:** CC-2329, CC-2330
- **Provenance:** `ios-review@deepinfra-zai-org-glm-5.3-flash`, `media-provenance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/test_silence_trim.swift:123 — every remote input writes /tmp/test_audio_trim.m4a
  - scripts/test_silence_trim.swift:141 — every output writes /tmp/trimmed_output.m4a
  - scripts/test_silence_trim.swift:142 — the output path is deleted without guarding against symlinks/concurrent runs
- **Decision:** Concurrent runs clobber one another, and another local user can precreate paths/symlinks to substitute input or redirect writes.
- **Recommendation:** Create a unique temporary directory and remove it on exit.

### V-410 · LOW · Silence-trim diagnostic hardcodes 44.1 kHz mono timing

- **Candidates:** CC-2314, CC-2315, CC-2316, CC-2317, CC-2318, CC-2319, CC-2320, CC-2321, CC-2322
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `media-provenance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `media-provenance-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/test_silence_trim.swift:27 — reader output is interleaved and does not force one channel
  - scripts/test_silence_trim.swift:33 — analysis hardcodes 44100 Hz
  - scripts/test_silence_trim.swift:34 — 50 ms windows derive from that constant
  - scripts/test_silence_trim.swift:83 — every window is nevertheless mapped to a fixed 0.05 seconds
- **Decision:** A normal 48 kHz phone recording, or multichannel input, creates windows with a different timeline duration, shifting the exported speech range and invalidating the production-algorithm comparison.
- **Recommendation:** Read sample rate and channel count from the audio format and normalize window timing to frames, not interleaved sample count.

### V-411 · LOW · Silence-trim diagnostic masks AVAssetReader failures as no silence to trim

- **Candidates:** CC-2313
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/test_silence_trim.swift:31 — startReading return value is ignored
  - scripts/test_silence_trim.swift:38 — sample copying ends when output returns nil
  - scripts/test_silence_trim.swift:58 — reader is cancelled without inspecting failed status
  - scripts/test_silence_trim.swift:165 — nil is finally reported as no significant silence
- **Decision:** A corrupt or unsupported input that fails reading follows the same nil result as valid audio with no useful trim, misleading the operator.
- **Recommendation:** Check startReading and reader.status/error before classifying the audio.

### V-412 · LOW · Simulation account passwords are exposed through argv

- **Candidates:** CC-2744, CC-2745, CC-2746, CC-2747, CC-2748
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tool/sim_multi_user.dart:12-14,43-59 — both account passwords are documented and read from command-line arguments
- **Decision:** Shell history and local process listings can expose real test-account credentials during operator runs.
- **Recommendation:** Read passwords from protected environment variables or an interactive no-echo prompt.

### V-413 · LOW · Simulation cleanup leaks second-line and fresh-key audio objects

- **Candidates:** CC-2750, CC-2751, CC-2752, CC-2753, CC-2754, CC-2755, CC-2756, CC-2757, CC-2758, CC-2759, CC-2760, CC-2761
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tool/sim_multi_user.dart:240-250,273-278 — the run uploads p2 and a nested newKey
  - tool/sim_multi_user.dart:315-329 — cleanup performs a shallow root list and explicitly adds only the first flat lineId path
- **Decision:** The known second and nested object keys are never removed, so every successful run can leave orphaned storage blobs after deleting database rows/production.
- **Recommendation:** Track every uploaded object key and remove that exact list in finally, with cleanup failures surfaced nonzero.

### V-414 · LOW · Some cast/voice failures remain outside persisted diagnostics

- **Candidates:** CC-1399
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:256 — contact-pick failure is caught
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:257 — it is sent only to debugPrint
  - lib/features/cast_manager/voice_config_screen.dart:393 — preview PlatformException is caught without DebugLogService logging
- **Decision:** These reachable failures disappear from persisted debug reports, making support diagnosis impossible after the transient UI/console event.
- **Recommendation:** Log full errors through DebugLogService while keeping user messages generic.

### V-415 · LOW · Speaker control is parsed and logged but never affects synthesis

- **Candidates:** CC-1950, CC-1951
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/kokoro_debug_screen.dart:112 — the Speaker field is parsed as sid
  - lib/features/settings/kokoro_debug_screen.dart:114 — sid is only interpolated into a log message
  - lib/features/settings/kokoro_debug_screen.dart:119 — TtsService.speak receives only text
- **Decision:** Changing the visible Speaker field produces identical voice selection, so a core diagnostic control is nonfunctional.
- **Recommendation:** Wire the control to the service's voice selection API or remove it.

### V-416 · LOW · Split line drops source and OCR metadata

- **Candidates:** CC-1765, CC-1767
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:1215-1231 — the new half copies speaker/type fields but omits sourcePage, sourceLineOnPage, ocrConfidence, and reviewStatus.
- **Decision:** The second half loses PDF navigation and falls out of OCR review despite originating from the same source line.
- **Recommendation:** Copy source/review metadata to both halves, adjusting only fields that truly differ.

### V-417 · LOW · Staging failure can setState after disposal

- **Candidates:** CC-1885
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_import/script_import_screen.dart:684-704 — success rechecks mounted after copy, but the catch falls through to setState without another mounted check
- **Decision:** Backing out while the staging copy fails can trigger setState on a disposed screen.
- **Recommendation:** Check mounted in the catch/finally path before line 704, or compute local state then update once behind a single mounted guard.

### V-418 · LOW · Status check and clear-model callbacks leak filesystem errors

- **Candidates:** CC-1964, CC-1971, CC-1972, CC-1973, CC-1974
- **Provenance:** `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/model_download_screen.dart:46 — checkStatus has no error handling
  - lib/features/settings/model_download_screen.dart:253 — clearCache is awaited without try/catch
- **Decision:** Filesystem/provider exceptions become unhandled async errors and the UI gives no failure state after a user action.
- **Recommendation:** Catch errors, preserve/refresh state safely, and display a friendly retry message.

### V-419 · LOW · Stopped Kokoro generations can orphan raw temporary WAVs

- **Candidates:** CC-0830, CC-0836
- **Provenance:** `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/kokoro_onnx_service.dart:333 — parent stops listening before isolate teardown completes
  - lib/data/services/kokoro_onnx_service.dart:464 — generation writes a raw temporary WAV before sending completion
  - lib/data/services/kokoro_onnx_service.dart:278 — cache pruning only walks kokoro_cache, not raw kokoro_onnx files
- **Decision:** A native generation already in progress can finish and write after the parent has cancelled the subscription; its path is never adopted or deleted.
- **Recommendation:** Cancel native generation before teardown and delete unclaimed raw outputs on stale/failed completion.

### V-420 · LOW · STT listen default contradicts its on-device privacy documentation

- **Candidates:** CC-1120, CC-1121, CC-1122
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/stt_channel.dart:85 — documents onDevice default true
  - lib/data/services/stt_channel.dart:90 — actual default is false
  - lib/data/services/stt_service.dart:188 — production caller omits onDevice
- **Decision:** The ordinary rehearsal path relies on the false default, allowing the OS recognizer to use server recognition despite the documented on-device default.
- **Recommendation:** Choose the intended privacy/availability policy explicitly; either pass true from SttService or correct the documentation and user disclosure.

### V-421 · LOW · STT singleton retains callbacks from disposed rehearsal state

- **Candidates:** CC-1614
- **Provenance:** `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:612 — dispose clears interruption callbacks
  - lib/features/rehearsal/rehearsal_screen.dart:614 — teardown continues without clearing level/silence callbacks
  - lib/features/rehearsal/rehearsal_screen.dart:2264 — onLevel captures this State
  - lib/features/rehearsal/rehearsal_screen.dart:2279 — onSilence also captures this State
- **Decision:** Until another rehearsal overwrites them, the singleton retains the disposed State graph; mounted guards avoid calls but not retention.
- **Recommendation:** Null onLevel and onSilence during dispose.

### V-422 · LOW · Subtoken resolution repeatedly rescans and copies shrinking slices

- **Candidates:** CC-0554
- **Provenance:** `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/EnglishG2P.swift:439-475 — each while iteration scans arr[left..<right] and may materialize Array(arr[left..<right])
- **Decision:** Long compound/numeric tokens can incur quadratic work and repeated allocations. Ordinary word lengths bound practical impact.
- **Recommendation:** Replace repeated slice scans with a single-pass or indexed resolution strategy.

### V-423 · LOW · Successful converter warnings are hidden

- **Candidates:** CC-2170
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/compare_macbeth_versions.py:68 — stdout is always printed
  - scripts/compare_macbeth_versions.py:69 — stderr is printed only on nonzero exit
- **Decision:** Warnings about partial extraction on a zero exit are silently discarded, giving the operator incomplete diagnostics.
- **Recommendation:** Forward stderr on success when nonempty.

### V-424 · LOW · Superseded old take is briefly published before replacement

- **Candidates:** CC-1223
- **Provenance:** `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/sync_queue.dart:394 — old metadata is saved before supersede detection
  - lib/data/services/sync_queue.dart:400 — replacement is detected only after publication
- **Decision:** A re-record made during upload leaves a realistic window where castmates receive the older take until the newer queued upload completes.
- **Recommendation:** Check whether the job is still current before metadata publication, or explicitly accept/document eventual replacement.

### V-425 · LOW · Symbol-only production titles collapse to hidden export names

- **Candidates:** CC-1524
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/production_hub/production_hub_screen.dart:875 — sanitizer strips non-word characters
  - lib/features/production_hub/production_hub_screen.dart:883 — empty safeName becomes .md
  - lib/features/production_hub/production_hub_screen.dart:886 — plain export similarly becomes .txt
- **Decision:** Emoji/symbol-only titles collide per format and create hidden dotfiles, overwriting earlier exports.
- **Recommendation:** Fallback to export or the production id when sanitized name is empty.

### V-426 · LOW · Synthesis allocates and samples a discarded noise tensor

- **Candidates:** CC-0440, CC-0441
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroVendored/Decoder/SourceModuleHnNSF.swift:46-53 — every call samples MLXRandom.normal and returns noise
  - ios/Runner/KokoroVendored/Decoder/Generator.swift:151 — the sole synthesis caller discards the second and third tuple values
- **Decision:** Every utterance performs a random fill and multiplication proportional to the F0 length with no consumer.
- **Recommendation:** Return only sineMerge, or remove the noise computation and unused tuple elements.

### V-427 · LOW · Text imports retain stale PDF failure counts

- **Candidates:** CC-1015
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/script_import_service.dart:34-56 — text and Markdown imports do not reset lastImportFailedPages.
  - lib/features/script_import/script_import_screen.dart:710-714 — the shared field is read after import to show the failed-page warning.
- **Decision:** A successful text import after a failed PDF import can display the old missing-page warning.
- **Recommendation:** Reset the field at the start of every import entry point.

### V-428 · LOW · Timed-out Kokoro completion futures retain stream listeners

- **Candidates:** CC-1254, CC-1255
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/tts_service.dart:716-726 — firstWhere listens only for completed and Future.timeout does not cancel the source future
  - lib/data/services/tts_service.dart:825-835 — stop produces a non-completed state and invalidates generation but does not cancel that subscription
- **Decision:** Each timeout/stop can leave a predicate subscribed until some later completed event, accumulating stale listeners across repeated stalls.
- **Recommendation:** Use an explicit StreamSubscription/Completer and cancel it on completion, stop, stale generation, error, and timeout.

### V-429 · LOW · TTS default-engine test asserts only its static enum type

- **Candidates:** CC-2640, CC-2641, CC-2642, CC-2643, CC-2644, CC-2645, CC-2646, CC-2647, CC-2648, CC-2649, CC-2650
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `testing-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - test/tts_service_test.dart:12 — test title promises the system default
  - test/tts_service_test.dart:14 — assertion accepts any TtsEngine value
- **Decision:** The matcher passes for system, MLX, or ONNX and therefore cannot detect the named default-selection regression.
- **Recommendation:** Assert TtsEngine.system under an isolated no-model precondition.

### V-430 · LOW · TTS initialization is not single-flight

- **Candidates:** CC-1231, CC-1237
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/tts_service.dart:151-177 — initialized remains false across multiple awaited platform/model calls
  - lib/data/services/tts_service.dart:206-217 — each overlapping init installs and overwrites a player stream subscription before setting initialized
  - lib/main.dart:125-127 — startup initializes asynchronously while screens can also call init
- **Decision:** Overlapping startup/screen calls can duplicate native initialization and leak the overwritten stream subscription.
- **Recommendation:** Store an _initFuture and have all callers await the same initialization attempt.

### V-431 · LOW · Two live join tests contain no assertions

- **Candidates:** CC-2624, CC-2629, CC-2630, CC-2631
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - test/supabase_join_test.dart:96 — direct query test begins
  - test/supabase_join_test.dart:103 — response is only printed
  - test/supabase_join_test.dart:111 — RPC simulation test begins
  - test/supabase_join_test.dart:123 — decoded values are only printed through the end
- **Decision:** Any status/payload can pass these test cases, so they provide no regression protection for the behavior in their names.
- **Recommendation:** Assert HTTP status, response shape, and the intended authorization/content contract or remove diagnostic-only tests.

### V-432 · LOW · Unknown authentication exceptions are rendered raw

- **Candidates:** CC-1338, CC-1339
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/auth/auth_screen.dart:372 — the formatter receives the raw exception
  - lib/features/auth/auth_screen.dart:386 — unmatched exceptions are returned with e.toString
  - lib/features/auth/auth_screen.dart:360 — that string is displayed as the screen error
- **Decision:** Unexpected Supabase/network exception internals can be shown directly instead of a stable user-safe message.
- **Recommendation:** Show a generic error and retain raw details only in local diagnostics.

### V-433 · LOW · Unknown cast roles fail open to primary

- **Candidates:** CC-0143
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/models/cast_member_model.dart:10-12 — unknown role strings fall back to CastRole.primary.
  - lib/features/cast_manager/cast_manager_screen.dart:208-212 — primary and understudy roles receive distinct assignment precedence.
- **Decision:** A malformed or newer cloud role is therefore treated as the primary actor rather than a lower-privilege understudy.
- **Recommendation:** Use an explicit safe fallback or reject unknown rows.

### V-434 · LOW · Unknown persisted enum values abort repository loads

- **Candidates:** CC-2156
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/repositories/production_repository.dart:63-73 — production status uses values.byName on stored text.
  - lib/data/repositories/production_repository.dart:101-109 — cast role uses the same throwing conversion.
  - lib/data/repositories/production_repository.dart:148-158 — line type also uses values.byName.
- **Decision:** One corrupt or newer-version enum string throws while mapping the collection and prevents local data from loading.
- **Recommendation:** Use explicit backward-compatible mappings or per-row validation with a safe documented fallback.

### V-435 · LOW · Unknown production locale violates SegmentedButton selection

- **Candidates:** CC-1852, CC-1853
- **Provenance:** `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_import/script_import_screen.dart:320-328 — stored locales outside en-US/en-GB are anticipated for display
  - lib/features/script_import/script_import_screen.dart:354-360 — selected always contains the raw locale while segments contain only the two map keys
- **Decision:** A synced/legacy locale outside the two buttons yields an invalid selection set and can assert or render with no selection.
- **Recommendation:** Map unsupported locales to a valid displayed selection or add a segment representing the stored locale.

### V-436 · LOW · Unknown stored genders silently become female

- **Candidates:** CC-1324
- **Provenance:** `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/voice_config_service.dart:232-240 — the gender decoder maps every unknown string to CharacterGender.female.
  - lib/data/services/voice_config_service.dart:180-186 — gender controls the voice pool used for assignment.
- **Decision:** Schema drift or corruption silently changes voice selection rather than falling back to inferred/neutral behavior.
- **Recommendation:** Return no override for unknown values and log the malformed entry.

### V-437 · LOW · Unscorable OCR garbage receives a perfect dictionary score

- **Candidates:** CC-0922, CC-0923, CC-0924
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/ocr_confidence_service.dart:159 — drops single-character tokens
  - lib/data/services/ocr_confidence_service.dart:161 — drops all-caps tokens
  - lib/data/services/ocr_confidence_service.dart:205 — returns 1.0 when no tokens remain
  - lib/data/services/ocr_confidence_service.dart:235 — classifies that score as ok
- **Decision:** Punctuation-only, digit-only, or all-caps OCR output can bypass both review buckets despite providing no dictionary evidence.
- **Recommendation:** Represent no scorable tokens separately or classify non-header nonempty lines conservatively for review.

### V-438 · LOW · Unsupported memory monitor logs literal null values

- **Candidates:** CC-1934, CC-1935
- **Provenance:** `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/settings/debug_log_screen.dart:223-228 — the manual action interpolates missing map keys directly
  - lib/data/services/debug_log_service.dart:203-221 — unsupported platforms return an empty map
- **Decision:** On Android or another platform without the channel, the action writes “nullMB” diagnostics instead of a meaningful unavailable state.
- **Recommendation:** Handle an empty result and log n/a, or use last known values.

### V-439 · LOW · Upload callback failure leaves local status stale without promised reupload

- **Candidates:** CC-1226
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/sync_queue.dart:444 — callback runs after the job is removed
  - lib/data/services/sync_queue.dart:450 — log claims next sync will re-upload
  - lib/data/services/recording_sync_service.dart:341 — reconciliation skips upload when equal-or-newer cloud metadata already exists
- **Decision:** If markUploaded throws, the cloud row exists but local remoteUrl remains null; the next sync sees matching cloud freshness and skips rather than healing the local marker.
- **Recommendation:** On callback failure, reconcile/stamp the known URL locally or retain a durable post-upload completion job.

### V-440 · LOW · Urgent Kokoro integration test assumes cancellation must win

- **Candidates:** CC-0167, CC-0168, CC-0169, CC-0170
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `testing-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/android_kokoro_service_test.dart:65 — starts a long urgent synthesis and waits a fixed 400 ms
  - lib/data/services/kokoro_onnx_service.dart:196 — a warm cache returns before urgency handling
  - lib/data/services/kokoro_onnx_service.dart:429 — cancellation is polled only between native generation chunks
  - lib/data/services/kokoro_onnx_service.dart:458 — stale but complete audio intentionally returns a path
- **Decision:** The fixed-delay test has realistic warm-cache and completed-generation outcomes in which the stale Future is non-null, so its null-only assertion is timing dependent.
- **Recommendation:** Make the test synchronize on an observable in-flight state and assert the service contract without requiring a completed stale generation to be discarded.

### V-441 · LOW · Verification tool fetches all rows to inspect three

- **Candidates:** CC-2779, CC-2780, CC-2781
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - tool/verify_cloud_recordings.dart:52-58 — the query selects the production’s complete recordings result without range/limit.
  - tool/verify_cloud_recordings.dart:64-67 — only the first three returned rows are downloaded and checked.
- **Decision:** Large productions transfer/materialize unnecessary metadata, while server row caps can hide objects beyond the first page and produce incomplete verification.
- **Recommendation:** Request an explicit deterministic sample or paginate and verify every page.

### V-442 · LOW · Vision OCR errors are returned as successful empty pages

- **Candidates:** CC-2129
- **Provenance:** `db-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - macos/Runner/VisionOcrPlugin.swift:103-117 — only render failure increments failedPages
  - macos/Runner/VisionOcrPlugin.swift:163-176 — Vision perform errors are logged then converted to an empty list
- **Decision:** A recognition failure is indistinguishable from a genuinely blank page in the returned success payload, allowing silent missing script text.
- **Recommendation:** Return a result/error sentinel from ocrImage and increment/report failedPages for Vision failures.

### V-443 · LOW · Vision OCR reading order sorts only by vertical position

- **Candidates:** CC-2130, CC-2131, CC-2132, CC-2133, CC-2134, CC-2135, CC-2136, CC-2137, CC-2138
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - macos/Runner/VisionOcrPlugin.swift:178-194 — observations are sorted only by descending boundingBox.origin.y and emitted in that order
- **Decision:** Equal or near-equal row fragments and multi-column content have no horizontal/column ordering, producing unstable or interleaved script text.
- **Recommendation:** Cluster observations into row/column bands and sort with a deterministic x-aware reading-order policy.

### V-444 · LOW · Vocabulary singleton retains every production and dead line-text copies

- **Candidates:** CC-1161, CC-1162, CC-1163, CC-1193
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/stt_vocabulary_service.dart:32 — vocabularies are retained by production id in a process singleton
  - lib/data/services/stt_vocabulary_service.dart:92 — every dialogue line text is copied into lineTexts
  - lib/data/services/stt_vocabulary_service.dart:127 — removal requires explicit clearProduction
  - lib/features/rehearsal/rehearsal_screen.dart:442 — rehearsals build entries, while repository search finds no clearProduction caller
- **Decision:** Opening rehearsals for distinct productions grows retained script/token state for the process lifetime; lineTexts is never read and needlessly duplicates the largest component.
- **Recommendation:** Remove lineTexts and evict or clear vocabularies when a production/rehearsal is left.

### V-445 · LOW · Voice embedding shape is not validated

- **Candidates:** CC-0470, CC-0471, CC-0472
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:192-193 — extraction receives the downloaded voice tensor with only token count.
  - ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:303-309 — indexing assumes enough rows, rank, and at least 256 style features.
  - ios/Runner/KokoroMLXService.swift:120-125 — voice loading checks only that the NPZ dictionary is nonempty.
- **Decision:** A parseable but mismatched voices pack can index out of range or select a wrong style row during ordinary synthesis.
- **Recommendation:** Validate every voice tensor shape when loading the NPZ and reject/delete an incompatible pack.

### V-446 · LOW · Voice preview handles only PlatformException

- **Candidates:** CC-1442, CC-1443, CC-1444, CC-1445
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/cast_manager/voice_config_screen.dart:385 — preview begins a try block
  - lib/features/cast_manager/voice_config_screen.dart:392 — TtsService.speak is awaited
  - lib/features/cast_manager/voice_config_screen.dart:393 — only PlatformException is caught
  - lib/data/services/tts_service.dart:383 — speak can await initialization and multiple non-platform Futures
- **Decision:** Non-PlatformException failures from initialization, playback session, file/audio, or state code escape the button callback without the existing Preview failed message.
- **Recommendation:** Catch Object/Exception at this UI boundary, log it, and show the same preview failure feedback.

### V-447 · LOW · Voice round-robin tests reimplement arithmetic instead of production assignment

- **Candidates:** CC-2655, CC-2656, CC-2657, CC-2658, CC-2659, CC-2660, CC-2661, CC-2662, CC-2663, CC-2664, CC-2665, CC-2666, CC-2667, CC-2668
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `testing-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - test/voice_config_test.dart:86 — test indexes the female pool directly
  - test/voice_config_test.dart:94 — test indexes the male pool directly
  - test/voice_config_test.dart:101 — test locally generates modulo indices
  - test/voice_config_test.dart:113 — wrap test asserts a modulo identity
  - lib/data/services/voice_config_service.dart:1 — production assignment lives outside these calculations
- **Decision:** A broken production allocator can pass because the tests verify fixture lists and Dart modulo behavior rather than call the assignment implementation.
- **Recommendation:** Drive VoiceConfigService.assignVoicesFromScript with casts/adjacency/gender inputs and assert its outputs.

### V-448 · LOW · Whole-PDF OCR reply is decoded on the UI isolate

- **Candidates:** CC-1271
- **Provenance:** `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/vision_ocr_channel.dart:35 — ocrPdf uses one MethodChannel result for the document
  - lib/data/services/vision_ocr_channel.dart:45 — all pages are materialized in one Dart list
  - lib/data/services/vision_ocr_channel.dart:49 — every line map is copied in that handoff
- **Decision:** Large PDFs produce one large standard-codec decode and map-copy burst at completion, which can stall the main isolate.
- **Recommendation:** Stream/page results or decode/process them incrementally.

### V-449 · LOW · Wrapped stage direction keeps only the final fragment

- **Candidates:** CC-2241
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/pdf_to_script.py:252 — first stage fragment is assigned
  - scripts/pdf_to_script.py:255 — continuation overwrites rather than appends
- **Decision:** A split direction can lose its first fragment and later text can be misclassified as dialogue.
- **Recommendation:** Accumulate all fragments in order before emitting the direction.

### V-450 · INFO · Android release explicitly references ProGuard rules but does not enable shrinking

- **Candidates:** CC-0013, CC-0015
- **Provenance:** `android-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `android-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/build.gradle.kts:55-72 — release supplies proguardFiles but never sets isMinifyEnabled or isShrinkResources
- **Decision:** The Android build type retains the plugin default of no minification. This increases package size and leaves Java bytecode unobfuscated, but is not a security boundary.
- **Recommendation:** Either enable and validate R8/resource shrinking with required JNI keep rules, or remove the unused ProGuard configuration.

### V-451 · INFO · BART logit-bias comment contradicts its use

- **Candidates:** CC-0571
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/FallbackNetwork/BARTModel.swift:67 — says logitBias is not used
  - ios/Runner/MisakiVendored/English/FallbackNetwork/BARTModel.swift:159 — adds logitBias to generated logits
- **Decision:** The current comment is factually stale and can mislead maintenance.
- **Recommendation:** Remove or correct the comment.

### V-452 · INFO · Cast role/member tests substantially duplicate another suite

- **Candidates:** CC-2545
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - test/cast_role_test.dart:5-109 — tests role conversions, hasJoined, and copyWith
  - test/cast_member_test.dart:8-97 — repeats the same observable cases with near-identical setup
- **Decision:** The duplication increases maintenance and runtime slightly without materially extending coverage.
- **Recommendation:** Consolidate unique cases into one suite and remove duplicate assertions.

### V-453 · INFO · CastRole tests are duplicated across two files

- **Candidates:** CC-2543
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - test/cast_member_test.dart:66 — begins CastRole mapping tests
  - test/cast_role_test.dart:5 — dedicated file repeats the same contract
- **Decision:** Duplicate assertions add maintenance work and can drift without adding independent coverage.
- **Recommendation:** Keep one authoritative role-mapping test group.

### V-454 · INFO · Clause splitter recompiles its regex per long line

- **Candidates:** CC-1250, CC-1251
- **Provenance:** `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/tts_service.dart:553-571 — RegExp for comma/clause boundaries is constructed inside every split call
  - lib/data/services/tts_service.dart:460-490 — sibling stable patterns are already cached statically
- **Decision:** Long-line speak/prefetch calls pay avoidable regex compilation, but impact is minor.
- **Recommendation:** Hoist the clause-boundary expression to a static final field.

### V-455 · INFO · Debug-log export formatting is duplicated across three actions

- **Candidates:** CC-1915
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/debug_log_screen.dart:68-70,103-107,113-117 — identical filtering and toLine joining are repeated
- **Decision:** The duplication already creates three places where redaction and formatting must stay aligned, but it is not itself a runtime failure.
- **Recommendation:** Extract one currentLogText/currentLogLabel helper.

### V-456 · INFO · Dormant voice-clone surface is dead-by-design

- **Candidates:** CC-1272, CC-1273, CC-1274, CC-1275, CC-1278
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/voice_clone_service.dart:1-3 — header states there are no call sites and backend is stubbed
  - lib/data/services/voice_clone_service.dart:66-85,129-155 — state is inert, readiness/canClone are false, and dispose is empty
- **Decision:** The repository carries a sizeable API that cannot perform its advertised feature and can drift before a planned backend arrives. This is maintenance debt only.
- **Recommendation:** Delete it if the plan is inactive; otherwise keep it isolated behind the feature work that supplies a backend and callers.

### V-457 · INFO · Fallback app version is already stale

- **Candidates:** CC-0733
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/core/constants.dart:5 — hardcodes appVersion 0.1.0
  - pubspec.yaml:4 — current package version is 0.1.1+147
  - lib/features/settings/settings_screen.dart:73 — uses the constant when PackageInfo fails
- **Decision:** The duplicate has drifted and can display the wrong version during loading or PackageInfo failure.
- **Recommendation:** Use PackageInfo as the only runtime source and replace the fallback with an unknown/unavailable label.

### V-458 · INFO · Firebase failure comments still claim Android is unconfigured

- **Candidates:** CC-2009, CC-2013
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/main.dart:37,47-59 — comments/debugPrint describe Android as unconfigured
  - lib/firebase_options.dart:25-27,61-67 — currentPlatform returns configured Android options
- **Decision:** A real Android Firebase failure is mislabeled as an expected configuration skip, impairing diagnostics only.
- **Recommendation:** Update comments and failure text to describe unsupported platforms or actual initialization failure.

### V-459 · INFO · Firebase telemetry is unavailable on current macOS configuration

- **Candidates:** CC-2012
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/firebase_options.dart:19-31 — currentPlatform supports iOS and Android and throws for macOS/web
  - lib/main.dart:49-59 — the exception is caught and firebaseAvailable remains false
- **Decision:** The repository ships macOS surfaces/tests, so those builds run without Firebase crash, performance, or analytics collection. Web is not a current target because main imports dart:io.
- **Recommendation:** Add macOS Firebase options if telemetry coverage is intended, or document macOS as intentionally offline.

### V-460 · INFO · iOS media-control header contradicts intentional all-to-jump-back mapping

- **Candidates:** CC-0510
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MediaControlPlugin.swift:7-10 — header documents three distinct commands
  - ios/Runner/MediaControlPlugin.swift:49-83 — all five remote commands intentionally emit jumpBack
- **Decision:** The stale header can misdirect maintenance but runtime mapping is explicit.
- **Recommendation:** Update the header mapping to state that every remote command emits jumpBack.

### V-461 · INFO · iOS Runner test target contains only an empty placeholder

- **Candidates:** CC-0700, CC-0701, CC-0702, CC-0703, CC-0704, CC-0705, CC-0706
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/RunnerTests/RunnerTests.swift:7-10 — testExample has an empty body and no assertion
- **Decision:** The stock placeholder cannot fail or establish any Runner behavior. This is a coverage signal, not a production failure.
- **Recommendation:** Delete the placeholder or replace it with a test of an observable Runner contract.

### V-462 · INFO · Kokoro comparison labels stale int8 candidates

- **Candidates:** CC-0254, CC-0255
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/tts_kokoro_compare_macos_test.dart:29-36 — active candidates are fp32 and fp16
  - integration_test/tts_kokoro_compare_macos_test.dart:1-2,113 — header and test name still say int8
- **Decision:** The current label misdescribes the actual candidate set but does not affect execution.
- **Recommendation:** Rename the test and header to fp32 versus fp16.

### V-463 · INFO · Kokoro debug route lacks a friendly analytics name

- **Candidates:** CC-0718, CC-0719
- **Provenance:** `db-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/app.dart:45-67 — _screenNames omits /kokoro-debug
  - lib/app.dart:177-181,328-331 — the route exists and falls back to logging its raw path
- **Decision:** Only analytics naming is affected.
- **Recommendation:** Add /kokoro-debug to _screenNames.

### V-464 · INFO · Kokoro download-size labels disagree

- **Candidates:** CC-1906
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/ai_models_screen.dart:190 — labels Kokoro about 180 MB
  - lib/features/settings/model_download_screen.dart:120 — labels Kokoro about 341 MB
  - lib/features/settings/model_download_screen.dart:202 — repeats 341 MB as the total
- **Decision:** Current user-facing screens provide contradictory storage/network expectations.
- **Recommendation:** Derive sizes from the actual platform artifact metadata or one shared constant.

### V-465 · INFO · Live ASR readiness does not rehash installed model files

- **Candidates:** CC-0837
- **Provenance:** `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/live_asr_service.dart:60-67 — startup trusts ModelDownloadService readiness
  - lib/data/services/model_download_service.dart:315-335 — readiness validates file presence/size rather than SHA-256
- **Decision:** A same-size post-download corruption is not detected at readiness time, although download-time checks and native model load failures substantially reduce impact.
- **Recommendation:** If field corruption warrants the cost, verify pinned digests on readiness or after a load failure.

### V-466 · INFO · Live ASR stop does not close its ReceivePort

- **Candidates:** CC-0854
- **Provenance:** `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/live_asr_service.dart:69 — each start allocates a ReceivePort
  - lib/data/services/live_asr_service.dart:139-149 — stop cancels the subscription but stores no port to close it
- **Decision:** Repeated starts leave port cleanup to garbage collection rather than deterministic lifecycle management.
- **Recommendation:** Store the ReceivePort and close it during stop and failed startup.

### V-467 · INFO · Loudness cache is FIFO despite LRU contract

- **Candidates:** CC-0803, CC-0804, CC-0805, CC-0806, CC-0807, CC-0808, CC-0809
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/audio_level_service.dart:36-38 — cache hits do not refresh insertion order
  - lib/data/services/audio_level_service.dart:57-63 — eviction removes the first inserted key while the comment calls it LRU
- **Decision:** Hot entries can be evicted before colder later inserts, causing bounded redundant loudness analysis; correctness and memory remain bounded.
- **Recommendation:** Reinsert on cache hit to refresh recency, or rename the policy/comment to FIFO.

### V-468 · INFO · macOS downloader cleans a temp path it never writes

- **Candidates:** CC-2079, CC-2080, CC-2082, CC-2083
- **Provenance:** `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - macos/Runner/BackgroundDownloadPlugin.swift:41 — computes destinationPath.tmp
  - macos/Runner/BackgroundDownloadPlugin.swift:42 — deletes it
  - macos/Runner/BackgroundDownloadPlugin.swift:92 — receives URLSession own temporary location
  - macos/Runner/BackgroundDownloadPlugin.swift:101 — moves directly from that location to destination
- **Decision:** The local tmpPath lifecycle is dead and misleading, though it has no runtime consequence.
- **Recommendation:** Remove it or use it as part of an intentional atomic replacement flow.

### V-469 · INFO · Markdown wildcard assertion is redundant

- **Candidates:** CC-2669, CC-2670, CC-2671, CC-2672
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - test/widget_test.dart:222 — already asserts a concrete bold fragment containing asterisks
  - test/widget_test.dart:223 — then asserts only that some asterisk exists
- **Decision:** The second assertion adds no independent stage-direction or emphasis coverage.
- **Recommendation:** Assert the exact italicized stage-direction fragment or remove the redundant check.

### V-470 · INFO · OCR confidence documentation contradicts current display scoring

- **Candidates:** CC-0925, CC-0926, CC-0927, CC-0928
- **Provenance:** `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/ocr_confidence_service.dart:241 — says display confidence is the minimum of two signals
  - lib/data/services/ocr_confidence_service.dart:264 — explains dictionary-only display behavior
  - lib/data/services/ocr_confidence_service.dart:267 — assigns dictNew only
- **Decision:** The doc comment is stale and invites reversal of an intentional field-validated behavior.
- **Recommendation:** Rewrite the scoreScript documentation to state that recognition confidence is used only for the junk gate.

### V-471 · INFO · ORT input and output names are repeatedly queried

- **Candidates:** CC-0695, CC-0696, CC-0697
- **Provenance:** `ios-performance-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/PaddleOcrPlugin.swift:411 — run is called for detection and every recognition crop
  - ios/Runner/PaddleOcrPlugin.swift:412 — queries inputNames on each run
  - ios/Runner/PaddleOcrPlugin.swift:413 — queries outputNames on each run
- **Decision:** The graph names are immutable yet repeatedly cross the wrapper. This is real but small constant overhead, not a correctness issue.
- **Recommendation:** Cache names alongside each session during model initialization.

### V-472 · INFO · Parser missing input produces a raw traceback

- **Candidates:** CC-2214, CC-2216
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `python-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/parse_script.py:375-379 — argv/default input is opened without an existence guard
- **Decision:** An operator typo or absent default file raises FileNotFoundError without a usage-oriented diagnostic.
- **Recommendation:** Check existence and exit with a concise missing-file/usage message.

### V-473 · INFO · Per-page OCR cache is count-unbounded

- **Candidates:** CC-1816
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_import/pdf_page_view.dart:69 — stores OCR results in an unbounded page-number map
  - lib/features/script_import/pdf_page_view.dart:266 — inserts every OCR-visited page
- **Decision:** A long-lived viewer manually traversing many pages retains all OCR line lists. Current per-line remounting limits typical growth, so impact is informational.
- **Recommendation:** Bound the OCR cache with an LRU or clear distant pages.

### V-474 · INFO · Rehearsal cache comments retain the old 10000 value

- **Candidates:** CC-1605
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:1061 — comment says the extent was 10000
  - lib/features/rehearsal/rehearsal_screen.dart:1064 — actual cacheExtent is 3000
  - lib/features/rehearsal/rehearsal_screen.dart:3284 — scrolling comment still says cacheExtent 10000
- **Decision:** The scrolling comment describes an obsolete current value and can misdirect performance work.
- **Recommendation:** Update stale comments to the current 3000 extent and realistic row count.

### V-475 · INFO · Supabase local project label is stale copy residue

- **Candidates:** CC-2362, CC-2363, CC-2364, CC-2365, CC-2366, CC-2367, CC-2368, CC-2369, CC-2370, CC-2371, CC-2372
- **Provenance:** `aws-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `docker-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `docker-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/config.toml:5 — project_id is Lineguide-
  - supabase/config.toml:154 — deployed site identity is CastCircle
- **Decision:** The value is a local CLI/container namespace, not the hosted project ref, but the unrelated name and trailing dash create avoidable operator confusion.
- **Recommendation:** Rename the local project_id to a stable CastCircle-specific label; do not substitute a hosted project ref.

### V-476 · INFO · Supabase tool bootstrap code is duplicated and already divergent

- **Candidates:** CC-2717, CC-2718
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tool/analyze_orphaned_recordings.dart:124-157 — local credential/auth HTTP helpers
  - tool/sim_multi_user.dart:347-370 — a separate copy includes richer error diagnostics
- **Decision:** Multiple operator tools maintain independent authentication/bootstrap implementations, increasing drift risk; this is maintenance debt rather than a current security failure.
- **Recommendation:** Extract a shared tool-only helper when these scripts are next updated.

### V-477 · INFO · Unused stress constants remain in EnglishG2P

- **Candidates:** CC-0527
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/EnglishG2P.swift:27-29 — stresses, primaryStress, and secondaryStress are declared
  - ios/Runner/MisakiVendored/English/EnglishG2P.swift:114-120 — current code references Lexicon.primaryStress instead
- **Decision:** The three local declarations have no current use and duplicate Lexicon ownership.
- **Recommendation:** Remove the dead declarations.

### V-478 · INFO · Voice assignment recompiles simple regexes

- **Candidates:** CC-1235
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/tts_service.dart:265-352 — system-voice filtering/gender inference runs during per-character assignment while several regexes are constructed inside helpers
- **Decision:** This is avoidable setup churn proportional to characters×device voices, but it is not a correctness failure or hot per-partial path.
- **Recommendation:** Hoist stable voice-name and locale split patterns to static final fields.


## Unverified findings

### U-001 · MEDIUM · Tar decoder peak-memory behavior depends on archive package internals

- **Candidates:** CC-0909
- **Provenance:** `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/model_manager.dart:256 — TarDecoder.decodeStream returns an Archive before disk extraction at line 258
- **Decision:** Whether entry contents are lazily backed or materialized depends on archive 4.0.9 implementation/runtime; source here alone does not prove the claimed 180 MB residency.
- **Recommendation:** Inspect/profile archive package behavior and switch to per-entry extraction if it materializes content.

### U-002 · MEDIUM · Telemetry collection is force-enabled without an in-app consent gate

- **Candidates:** CC-2018, CC-2019, CC-2020, CC-2021, CC-2022, CC-2023, CC-2024, CC-2025, CC-2026, CC-2027, CC-2028, CC-2029, CC-2030
- **Provenance:** `db-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `db-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `sql-migration-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/main.dart:84-92 — Crashlytics, Performance, and Analytics are unconditionally enabled after Firebase initialization
  - ios/Runner/Info.plist:83-86 — platform defaults also enable Crashlytics and Performance
- **Decision:** The source has no opt-out, but whether this violates the product’s disclosures, legal basis, store declarations, or jurisdictional consent requirements is external policy data not present in the repository. It does not override a current false plist value.
- **Recommendation:** Confirm the documented privacy basis and store declarations; if consent/opt-out is required, default off and gate all three SDKs on persisted preference.

### U-003 · MEDIUM · Uploader await timeout depends on Supabase transport behavior

- **Candidates:** CC-1222
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/sync_queue.dart:393 — upload and metadata futures have no queue-level timeout
- **Decision:** The source lacks its own timeout, but whether these futures can remain pending indefinitely depends on the Supabase/HTTP client runtime and network behavior.
- **Recommendation:** Confirm SDK timeout semantics; add queue-level operation deadlines if it permits indefinite waits.

### U-004 · LOW · APK verifier head pipelines can fail via SIGPIPE

- **Candidates:** CC-2345, CC-2346, CC-2348, CC-2349, CC-2350, CC-2351, CC-2352, CC-2354, CC-2355, CC-2358
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `shell-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/verify-apk-ort.sh:9-15 — find/strings/grep pipelines end in head -1 under set -euo pipefail
  - scripts/verify-apk-ort.sh:20-23 — the script itself documents the early-consumer pipefail class elsewhere
- **Decision:** Failure requires multiple matches and producer timing/artifact contents; source establishes the hazard but not the current cached-library/APK trigger.
- **Recommendation:** Avoid early-closing consumers under pipefail: use find -print -quit and extract matches from fully captured/file-backed output.

### U-005 · LOW · APK verifier may choose an arbitrary cached sherpa version

- **Candidates:** CC-2347
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/verify-apk-ort.sh:12-14 — find selects the first matching package directory without consulting pubspec.lock
- **Decision:** Wrong comparison requires multiple cached package versions on the verification host, which is external runtime state.
- **Recommendation:** Resolve the exact locked package/version and fail if that source library is absent.

### U-006 · LOW · Device UDID parsing depends on external CLI layouts

- **Candidates:** CC-2274
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/pull-crashlog.sh:21-35 — UDIDs are selected by final column or bullet-delimited field without shape validation
- **Decision:** Correctness depends on current xcrun/flutter output formats and attached-device data, which repository state cannot establish.
- **Recommendation:** Validate selected tokens against accepted UDID shapes and fail distinctly when parsing is ambiguous.

### U-007 · LOW · Firebase Android Gradle plugins may be outdated

- **Candidates:** CC-0139
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/settings.gradle.kts:24 — google-services is pinned to 4.3.15
  - android/settings.gradle.kts:25 — firebase-perf is pinned to 1.4.1
  - android/settings.gradle.kts:26 — crashlytics is pinned to 2.8.1
- **Decision:** The pins are current-source facts, but deciding whether supported/current versions contain relevant fixes requires registry and release-note data outside the repository.
- **Recommendation:** Compare the pins with Google Maven and FlutterFire compatibility guidance before updating.

### U-008 · LOW · Flood-fill literal allocation impact needs profiling

- **Candidates:** CC-0684, CC-0685
- **Provenance:** `ios-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/PaddleOcrPlugin.swift:293 — flood fill visits probability-map pixels
  - ios/Runner/PaddleOcrPlugin.swift:298 — constructs the four-neighbor literal inside the loop
- **Decision:** The source shows repeated literal evaluation, but Swift may stack-promote or optimize it; the claimed heap-allocation count and wall-time impact require a release-device profile.
- **Recommendation:** Hoist a static neighbor tuple only if profiling shows allocation or loop overhead.

### U-009 · LOW · Fused-attention performance benefit requires measurement

- **Candidates:** CC-0407
- **Provenance:** `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroVendored/Albert/AlbertSelfAttention.swift:74 — current attention is explicitly composed from matmul, scale, softmax, and matmul
- **Decision:** Source establishes an optimization opportunity, not that MLX fails to fuse it or that current synthesis breaches a performance threshold.
- **Recommendation:** Benchmark against MLXFast.scaledDotProductAttention before changing numerical code.

### U-010 · LOW · Hydration versus debounce loss requires an extreme timing race

- **Candidates:** CC-1092, CC-1093, CC-1099
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/stt_adaptation_service.dart:304 — starts hydration without awaiting it
  - lib/data/services/stt_adaptation_service.dart:224 — persistence waits two seconds
  - lib/data/services/stt_adaptation_service.dart:185 — merges disk and live profiles when hydration reads the old snapshot
- **Decision:** The merge protects normal overlap; loss requires path lookup/read to stall beyond two seconds and then read only the newly replaced file. Whether that occurs requires runtime filesystem timing.
- **Recommendation:** Await first hydration before the first persist to eliminate the race if device evidence confirms it.

### U-011 · LOW · Join-code default has probabilistic uniqueness collisions

- **Candidates:** CC-2437
- **Provenance:** `sql-migration-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/migrations/20260315_cast_join_code.sql:6 — join_code is unique
  - supabase/migrations/20260316_join_code_default.sql:3 — default calls generate_join_code without a visible retry
- **Decision:** A duplicate draw would abort insertion, but whether this is realistic depends on deployed production cardinality and generator distribution/runtime data.
- **Recommendation:** Implement bounded collision retry in the creation function/RPC.

### U-012 · LOW · Join-code generation has no collision retry

- **Candidates:** CC-2436
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260315_cast_join_code.sql:55-66 — generator returns one random six-character code
  - supabase/migrations/20260316_join_code_default.sql:3-4 — it is used directly as the unique column default
- **Decision:** An insert failure requires a random collision in the current code space, which cannot be proven from repository state.
- **Recommendation:** Generate with bounded unique_violation retry or allocate the code in an idempotent RPC.

### U-013 · LOW · Live ASR 30-second model-load budget may be too short on slow devices

- **Candidates:** CC-0848
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/live_asr_service.dart:111-117 — recognizer initialization has a fixed 30-second timeout and stops on expiry
- **Decision:** Whether the shipped model exceeds 30 seconds on supported low-end storage is hardware/runtime data not available from source.
- **Recommendation:** Measure cold loads on the slowest supported Android device and raise or stage the timeout if necessary.

### U-014 · LOW · Live ASR producer has no measured backpressure bound

- **Candidates:** CC-0850
- **Provenance:** `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/live_asr_service.dart:130-131 — every PCM chunk is sent directly to the isolate
  - lib/data/services/live_asr_service.dart:210-220 — isolate processes queued chunks serially and has no queue-depth policy
- **Decision:** The queue is structurally unbounded, but a failure requires decoding to remain slower than capture; current source asserts tens of milliseconds per 100ms chunk and no device trace is available.
- **Recommendation:** Measure worst-device sustained decode; add timestamps/coalescing or bounded backpressure if lag grows.

### U-015 · LOW · Live-ASR artifacts depend on mutable upstream URLs

- **Candidates:** CC-0867
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/model_download_service.dart:309-334 — local verification protects bytes but availability still depends on the configured URL
- **Decision:** A mutable upstream change cannot be established from repository state; the local pins make changed bytes fail safely rather than execute.
- **Recommendation:** Use immutable revision URLs so valid pinned downloads remain available after upstream branch changes.

### U-016 · LOW · Main-isolate archive hashing may cause device jank

- **Candidates:** CC-0904, CC-0905, CC-0906, CC-0907
- **Provenance:** `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/model_manager.dart:206 — SHA-256 streams the roughly 180 MB archive on the caller isolate
- **Decision:** The work scales with archive size, but whether async chunk hashing misses frames on supported devices requires runtime profiling.
- **Recommendation:** Profile; if visible, hash in the extraction isolate or a dedicated worker.

### U-017 · LOW · Native Kokoro generation has no watchdog

- **Candidates:** CC-0820
- **Provenance:** `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/kokoro_onnx_service.dart:236 — synthesize waits directly on a completer
  - lib/data/services/kokoro_onnx_service.dart:434 — native generation owns completion while in flight
- **Decision:** A native deadlock would strand the future, but the repository does not establish that sherpa generation can hang without terminating the isolate; deciding that requires runtime/native behavior.
- **Recommendation:** Add a watchdog only if a targeted fault-injection or field trace reproduces a native hang.

### U-018 · LOW · Native progress callback cadence may over-notify UI

- **Candidates:** CC-0868, CC-0869
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/model_download_service.dart:237-250 — every native progress callback updates state and notifies all listeners
  - lib/data/services/model_download_service.dart:620-628 — the Dart fallback throttles notifications to roughly 1 MB
- **Decision:** Whether this causes excessive rebuilds depends on native URLSession callback cadence and listener surfaces at runtime.
- **Recommendation:** Apply the same byte/progress delta throttle to native callbacks if device traces show high event frequency.

### U-019 · LOW · Network fixture URL is mutable

- **Candidates:** CC-0171
- **Provenance:** `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/android_live_matching_test.dart:25-28 — the test fetches resolve/main while asserting a fixed transcript
- **Decision:** The source is mutable, but deciding whether it has changed requires the external HuggingFace repository state.
- **Recommendation:** Pin the fixture URL to an immutable commit or store the fixture with the harness.

### U-020 · LOW · Parser relies on process-default text encoding

- **Candidates:** CC-2215
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/parse_script.py:378-379 — input open omits encoding
  - scripts/parse_script.py:401-408 — both output opens omit encoding
- **Decision:** Failure requires a non-UTF-8 process locale; current macOS/Linux environments commonly default to UTF-8.
- **Recommendation:** Specify encoding="utf-8" consistently for OCR input and generated output.

### U-021 · LOW · Parser repeatedly constructs and scans regular expressions

- **Candidates:** CC-1061, CC-1062, CC-1063, CC-1070, CC-1071, CC-1072, CC-1073, CC-1076, CC-1077, CC-1078, CC-1079, CC-1080, CC-1081, CC-1082
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `metal-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `metal-performance-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/script_parser.dart:223 — a RegExp is created inside header scanning
  - lib/data/services/script_parser.dart:384 — gender context scans raw text per character
  - lib/data/services/script_parser.dart:1238 — inline-direction regex is built per dialogue flush
  - lib/data/services/script_parser.dart:1281 — enter/exit regex is built per call
  - lib/data/services/script_parser.dart:1350 — location regexes are built per location check
- **Decision:** The repeated work is real, but whether it produces an observable import delay requires corpus/device profiling; candidate timing and scale estimates are not repository facts.
- **Recommendation:** Profile representative large scripts and hoist only expressions shown to matter.

### U-022 · LOW · Per-page OCR lacks an explicit autorelease pool

- **Candidates:** CC-2121, CC-2123
- **Provenance:** `ios-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - macos/Runner/VisionOcrPlugin.swift:77-128 — all pages run inside one GCD block with no per-iteration autoreleasepool
  - macos/Runner/VisionOcrPlugin.swift:103-117 — each page creates PDF/Vision/CoreGraphics intermediates
- **Decision:** ARC releases Swift-owned values each iteration, while autoreleased Objective-C intermediates may persist to the GCD block pool. Actual peak growth depends on framework ownership/runtime behavior and needs measurement.
- **Recommendation:** Profile a large scanned PDF; wrap each page in autoreleasepool if peak memory grows by page count.

### U-023 · LOW · Per-synthesis MLX cache clearing may add latency

- **Candidates:** CC-0385
- **Provenance:** `metal-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroMLXService.swift:247-265 — MLX cache is cleared after both successful and failed synthesis
- **Decision:** Whether this defeats useful allocator reuse or materially affects latency requires MLX runtime profiling on target hardware.
- **Recommendation:** Profile repeated cache misses; retain the clear only if memory pressure data justifies its latency cost.

### U-024 · LOW · Recording existence scan serializes file resolution

- **Candidates:** CC-1569, CC-1570, CC-1571, CC-1572, CC-1573
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/recording_studio/recordings_browser_screen.dart:199 — scan runs asynchronously off build
  - lib/features/recording_studio/recordings_browser_screen.dart:201 — entries are processed in a serial loop
  - lib/features/recording_studio/recordings_browser_screen.dart:203 — each path resolution is awaited before the next
- **Decision:** Wall time grows with recording count, but the claimed seconds-long delay requires actual filesystem latency and production-size data.
- **Recommendation:** Measure large libraries; if needed, resolve with bounded concurrency and incremental state updates.

### U-025 · LOW · Rehearsal UI and synchronous logging may add frame work

- **Candidates:** CC-1617, CC-1618, CC-1623
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:1064 — list cacheExtent is 3000
  - lib/features/rehearsal/rehearsal_screen.dart:1253 — mic uses a 90 ms AnimatedContainer
  - lib/features/rehearsal/rehearsal_screen.dart:1733 — line processing emits synchronous diagnostic calls
- **Decision:** The extra work is source-visible, but the asserted frame-rate or millisecond impact requires profiling on supported devices and realistic scenes.
- **Recommendation:** Profile scrolling, mic animation, and line transitions before changing deliberate caching/animation/diagnostics.

### U-026 · LOW · Remote-command enabled state remains set after deactivation

- **Candidates:** CC-0513, CC-0516, CC-0518, CC-0519
- **Provenance:** `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/MediaControlPlugin.swift:55-83 — activate enables five MPRemoteCommand objects
  - ios/Runner/MediaControlPlugin.swift:91-102 — deactivate removes targets and clears nowPlayingInfo but never disables commands
- **Decision:** The source leaves isEnabled true, but whether clearing nowPlayingInfo still exposes dead controls is MediaPlayer runtime/UI behavior that cannot be established from source alone.
- **Recommendation:** Verify on a device after leaving rehearsal; if controls remain, disable all five commands in deactivate.

### U-027 · LOW · Rename failure may leave raw temporary WAVs

- **Candidates:** CC-0822
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/kokoro_onnx_service.dart:240 — cache adoption attempts renameSync
  - lib/data/services/kokoro_onnx_service.dart:242 — failure returns the source path without cleanup
  - lib/data/services/kokoro_onnx_service.dart:278 — prune scans only the cache directory
- **Decision:** Leak impact requires a realistic repeated rename-failure condition, which depends on filesystem/runtime behavior outside source semantics.
- **Recommendation:** If rename failures are observed, copy/delete or schedule source cleanup after playback.

### U-028 · LOW · Scalar CTC argmax impact needs device measurement

- **Candidates:** CC-0686
- **Provenance:** `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/PaddleOcrPlugin.swift:341 — loops over each timestep
  - ios/Runner/PaddleOcrPlugin.swift:344 — scans every class in scalar Swift
- **Decision:** The comparison count is real, but whether it is material beside ONNX inference is runtime- and model-dependent.
- **Recommendation:** Profile the recognition stage before adding Accelerate or batching complexity.

### U-029 · LOW · Screenshot preference failure is silently permissive

- **Candidates:** CC-1139, CC-1140
- **Provenance:** `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/stt_service.dart:39-51 — SharedPreferences errors are swallowed and native STT initialization proceeds
- **Decision:** The unsafe fallback is present, but triggering it requires a real SharedPreferences platform failure not established by source.
- **Recommendation:** Log the exception and fail closed for screenshot-mode automation when preference state is unavailable.

### U-030 · LOW · Settings sliders rebuild the whole settings screen

- **Candidates:** CC-1980, CC-1981, CC-1982, CC-1983, CC-1984
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/settings/settings_screen.dart:82 — root ConsumerWidget build watches all settings
  - lib/features/settings/settings_screen.dart:83 — provider watches are at root scope
  - lib/features/settings/settings_screen.dart:109 — the full list is rebuilt
  - lib/features/settings/settings_screen.dart:160 — slider ticks update a watched provider
- **Decision:** The rebuild pattern is real, but visible drag jank on supported devices requires profiling; the screen has a fixed modest number of tiles.
- **Recommendation:** Profile slider dragging on a low-end target before splitting rows into narrower Consumers.

### U-031 · LOW · SineGen phase distribution may differ from the reference

- **Candidates:** CC-0439
- **Provenance:** `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroVendored/Decoder/SineGen.swift:45 — initial phase uses MLXRandom.normal
  - ios/Runner/KokoroVendored/Decoder/SineGen.swift:46 — the fundamental phase is forced to zero
- **Decision:** Whether the reference requires a uniform distribution and whether the difference is audible requires external reference-source/model behavior not established in this repository.
- **Recommendation:** Compare against the exact trained model reference and audio regression corpus before changing distribution.

### U-032 · LOW · Small device-selection pipelines may trip pipefail

- **Candidates:** CC-2276
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/pull-crashlog.sh:27-31 — several command substitutions end in head -1 under set -o pipefail
- **Decision:** SIGPIPE depends on external producer volume/timing; typical flutter device output fits in a pipe buffer, so source alone does not prove the asserted multi-device abort.
- **Recommendation:** Select and exit inside one awk process or otherwise consume input fully to make status deterministic.

### U-033 · LOW · Synchronous model-directory deletion may stall UI

- **Candidates:** CC-0368, CC-0369
- **Provenance:** `metal-performance-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroMLXPlugin.swift:100 — deleteModel runs synchronously in the channel handler
  - ios/Runner/KokoroMLXService.swift:149 — it recursively removes the model directory
- **Decision:** The current model directory contains large files, but unlink latency and whether this produces visible jank depend on device/filesystem runtime behavior; the claim of hundreds of thousands of files is false.
- **Recommendation:** Measure on supported devices; move deletion off-main if latency is user-visible.

### U-034 · LOW · System TTS callbacks cannot identify stopped utterance generations

- **Candidates:** CC-1233
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/tts_service.dart:193-203 — the global completion callback checks only current mutable generation/state
  - lib/data/services/tts_service.dart:825-835 — stop invalidates generation, but the next speak makes the global state active again
- **Decision:** A stale completion would be misattributed if flutter_tts delivers it after stop and after a new speak starts; that callback ordering requires device/plugin behavior.
- **Recommendation:** Use utterance IDs if supported, or serialize stop/start until the prior utterance lifecycle is conclusively drained.

### U-035 · LOW · System voice enumeration assumes a List

- **Candidates:** CC-1229
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/tts_service.dart:84-89 — setLocale force-casts getVoices
  - lib/data/services/tts_service.dart:171-177 — init repeats the force-cast before marking initialized
- **Decision:** Failure depends on flutter_tts returning null/non-List on a supported platform, which requires runtime/plugin behavior not established here.
- **Recommendation:** Validate the dynamic result and fall back to an empty voice list while preserving system TTS availability.

### U-036 · LOW · Tensor normalization speed needs profiling

- **Candidates:** CC-0692, CC-0693, CC-0694
- **Provenance:** `ios-performance-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/PaddleOcrPlugin.swift:398 — normalizes every image pixel in nested Swift loops
  - ios/Runner/PaddleOcrPlugin.swift:402 — performs three normalized float writes per pixel
- **Decision:** The work count is source-proven, but the claimed user-visible delay relative to rasterization and ONNX inference is not.
- **Recommendation:** Use vImage/vDSP only after a release-device profile shows this loop is significant.

### U-037 · LOW · Text and Markdown parsing may stall the UI isolate

- **Candidates:** CC-1054
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/script_parser.dart:117 — parse is synchronous
  - lib/data/services/script_import_service.dart:28 — the import service calls its retained parser for text paths
- **Decision:** The amount of UI stall for realistic scripts depends on device and corpus timing; the claimed half-to-one-second impact is not established by source alone.
- **Recommendation:** Benchmark representative large text/Markdown imports, then offload only if frame responsiveness fails.

### U-038 · LOW · Transposed frozen convolution weights are not cached

- **Candidates:** CC-0408
- **Provenance:** `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroVendored/BuildingBlocks/ConvWeighted.swift:143-147 — the orientation-mismatch branch transposes normalized weights per call
  - ios/Runner/KokoroVendored/BuildingBlocks/ConvWeighted.swift:172-176 — the transposed-convolution overload repeats it
- **Decision:** The redundant operation is real if those shape branches run, but current model-shape reach and measurable cost require runtime graph profiling.
- **Recommendation:** If profiling shows the branch hot, cache the transposed normalized weight alongside the existing normalized cache.

### U-039 · LOW · User-only cast membership query lacks a user-leading index

- **Candidates:** CC-2495, CC-2496
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260801130000_cast_members_rls_index.sql:10 — only restored index begins with production_id
  - lib/data/services/supabase_service.dart:97 — app queries cast_members by user_id alone
  - lib/data/services/supabase_service.dart:100 — query predicate is user_id
- **Decision:** The query shape cannot use the composite index’s leading column, but impact depends on live row count and PostgreSQL plan/statistics unavailable in the repository.
- **Recommendation:** Inspect EXPLAIN/row counts in the deployed database; add cast_members(user_id) if the planner shows sequential-scan cost.

### U-040 · LOW · Verification tool defaults may target a live production

- **Candidates:** CC-2762, CC-2763, CC-2764, CC-2765, CC-2766, CC-2767
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tool/verify_cloud_recordings.dart:18-20 — missing CLI arguments fall back to embedded production and join identifiers.
  - tool/verify_cloud_recordings.dart:64-79 — successful reads download user audio to a fixed shared /tmp directory.
- **Decision:** The unsafe default and file mode are source-visible, but whether the embedded identifiers still reference a live production with recordings requires current external service state.
- **Recommendation:** Require explicit arguments/confirmation and use a private mode-0700 temporary directory; rotate any live join code.

### U-041 · LOW · Voice assignment memo key is recomputed per character

- **Candidates:** CC-1424, CC-1425
- **Provenance:** `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/cast_manager/voice_config_screen.dart:108 — _memoAssignment is invoked inside character mapping
  - lib/features/cast_manager/voice_config_screen.dart:126 — key computation includes genderOverrides.toString
  - lib/features/cast_manager/voice_config_screen.dart:128 — expensive assignment itself is cached
- **Decision:** The extra key/string work is source-visible, but user-visible impact at realistic cast sizes is not established.
- **Recommendation:** Hoist the memoized assignment to one local per build if profiling or cleanup warrants it.

### U-042 · LOW · Voice settings eagerly builds every character tile

- **Candidates:** CC-1422, CC-1423, CC-1426
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/cast_manager/voice_config_screen.dart:72 — screen uses ListView with a fixed children list
  - lib/features/cast_manager/voice_config_screen.dart:108 — every script character is expanded into that list
- **Decision:** Construction scales with parsed character count, but the claimed visible first-layout stall requires device/corpus measurement.
- **Recommendation:** Profile pathological OCR rosters before replacing the mixed section with slivers or a lazy builder.

### U-043 · INFO · External dependency freshness and CVE state requires current registry data

- **Candidates:** CC-2783
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - tools/mlx-harness/Package.swift:10-13 — harness depends on mlx-swift and MLXUtilsLibrary
  - tools/mlx-harness/Package.resolved:1 — current resolved revisions are recorded locally
- **Decision:** Whether newer releases are available or those revisions have current advisories is external, time-sensitive information not established by repository source.
- **Recommendation:** Run a networked dependency/advisory audit against the resolved revisions before release-sensitive use.

### U-044 · INFO · Web editor link authorization depends on deployed backend

- **Candidates:** CC-1736
- **Provenance:** `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:163-167 — the shared URL contains only a production identifier and account hint.
- **Decision:** Whether the deployed web editor verifies membership before returning script data is not decidable from this mobile call site and requires the deployed web/backend behavior.
- **Recommendation:** Exercise the hosted URL as an authenticated nonmember and verify RLS/server authorization.


## Refuted findings

### R-001 · LOW · BART weight lookups cannot be corrupted by user input

- **Candidates:** CC-0556, CC-0557, CC-0558, CC-0562, CC-0563, CC-0564, CC-0565, CC-0566, CC-0567, CC-0568, CC-0569
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/FallbackNetwork/BARTModel.swift:26 — weight keys come from the bundled safetensors dictionary
  - ios/Runner/MisakiVendored/English/FallbackNetwork/EnglishFallbackNetwork.swift:95 — loads a fixed Bundle.main resource
- **Decision:** Missing keys would indicate a broken signed application bundle or incompatible developer asset, not a reachable user-controlled state in the current repository.
- **Recommendation:** Add a packaging/model-schema check if desired; do not treat it as an input security bug.

### R-002 · INFO · 10^21 input cannot reach the Int converter

- **Candidates:** CC-0636
- **Provenance:** `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/Num2Word/EnglishNum2Word.swift:213 — conversion first narrows Decimal to platform Int
  - ios/Runner/MisakiVendored/English/Num2Word/EnglishNum2Word.swift:50 — the table is bounded by Int.max
- **Decision:** A value at or above 10^21 cannot exist as the Int passed to toCardinal on this 64-bit target; NSDecimalNumber narrowing saturates earlier.
- **Recommendation:** No change for the claimed threshold; separately handle saturation if desired.

### R-003 · INFO · A second Save cannot duplicate the just-saved controller entries

- **Candidates:** CC-1352, CC-1353, CC-1355, CC-1360
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:81 — saved primary characters leave the unassigned list when provider state updates
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:99 — AppBar Save visibility is based on current unassigned characters
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:149 — the bottom Save bar disappears when unassigned is empty
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:318 — _saving disables reentrant taps during the first save
- **Decision:** Although controllers retain text, the local save synchronously updates provider state and removes those characters' actionable Save controls; the described second-tap path is not reachable.
- **Recommendation:** No change for this claim; the separate concurrent-sync race should be fixed at save time.

### R-004 · INFO · AAB signing is JAR-based, not APK v2/v3-only

- **Candidates:** CC-2293, CC-2294, CC-2295
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/ship-play.sh:37-44 — check inspects the JAR signature entry in an Android App Bundle.
- **Decision:** APK Signature Scheme v2/v3 applies to APKs; the proposed valid v2/v3-only AAB trigger is invalid.
- **Recommendation:** Keep current AAB signature check.

### R-005 · INFO · Account hint is intentionally user-shared

- **Candidates:** CC-1731, CC-1732
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:140-167 — email is shown before explicit Share and included in selected content.
- **Decision:** This is visible user-initiated behavior, not covert outbound disclosure.
- **Recommendation:** No current defect fix required.

### R-006 · INFO · Adaptation clear races are unreachable in the current app

- **Candidates:** CC-1115, CC-1116, CC-1117, CC-1118, CC-1119
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/stt_adaptation_service.dart:491 — defines clearProduction
  - lib/data/services/stt_adaptation_service.dart:492 — removes hydration tracking and in-memory state
  - lib/data/services/stt_adaptation_service.dart:491 — no repository caller invokes this method
- **Decision:** The race is latent API behavior but there is no user action or current caller that clears adaptation data.
- **Recommendation:** Add generation-based cancellation before exposing clearProduction in UI.

### R-007 · INFO · Adaptation directory traversal lacks a hostile ID source

- **Candidates:** CC-1114
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/stt_adaptation_service.dart:483 — joins a production identifier under the adapter root
  - lib/features/recording_studio/recording_studio_screen.dart:206 — passes the current production ID
  - supabase/migrations/20260314061409_initial_schema.sql:60 — production IDs are UUIDs
- **Decision:** Current callers use database UUID production IDs, and clearProduction itself has no caller; path separators cannot reach this join.
- **Recommendation:** Validate IDs if this service is exposed to arbitrary channel or command input.

### R-008 · INFO · Adaptation singleton tests use nonoverlapping keys

- **Candidates:** CC-2600, CC-2601, CC-2602
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `testing-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - test/stt_adaptation_test.dart:133-177 — mutating test uses test-prod/ELIZABETH while other tests use distinct keys.
- **Decision:** Comment is inaccurate, but state cannot mask current assertions and files are isolate-separated.
- **Recommendation:** Correct comment; reset only if keys are reused.

### R-009 · INFO · ALBERT group division is safe for the shipped fixed configuration

- **Candidates:** CC-0401
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroVendored/Albert/AlbertEncoder.swift:32 — group selection assumes evenly divisible configured layers
  - ios/Runner/KokoroVendored/Albert/AlbertModelArgs.swift:25 — the shipped default has one hidden group
- **Decision:** The app loads a fixed, integrity-checked Kokoro configuration; no supported configuration with a non-divisible group count is reachable.
- **Recommendation:** No change required; validate divisibility only if arbitrary configs become supported.

### R-010 · INFO · Alignment host transfer is bounded and intentional

- **Candidates:** CC-0475
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:367-384 — durations are transferred once and the alignment is built in one host allocation.
- **Decision:** The code already avoids per-frame device synchronization; no measured current latency failure is provided.
- **Recommendation:** No change.

### R-011 · INFO · Alignment parameter naming does not change layout

- **Candidates:** CC-0474
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:356-384 — the passed sequence width and reshape dimensions agree.
- **Decision:** The parameter is misnamed, but current indexing and resulting matrix shape are consistent.
- **Recommendation:** No change.

### R-012 · INFO · All-false text mask is correct for an unpadded single sequence

- **Candidates:** CC-0469
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:274-293 — the implementation creates one sequence whose start/end tokens are real and whose length equals its full width.
- **Decision:** No padded batch positions exist in the current one-item input, so an all-valid mask is expected.
- **Recommendation:** No change.

### R-013 · INFO · Alleged locale selector is absent from SettingsScreen

- **Candidates:** CC-1996
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/settings_screen.dart:109 — current SettingsScreen list begins
  - lib/features/settings/settings_screen.dart:320 — list ends without a production-locale SegmentedButton
- **Decision:** The cited line range and locale selector belong to another screen/version; there is no such assertion path in the current settings implementation.
- **Recommendation:** No change.

### R-014 · INFO · altool deprecation is not a current failure

- **Candidates:** CC-2305
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/ship-testflight.sh:94 — current upload uses xcrun altool.
- **Decision:** The finding predicts a future failure and reports no current failed upload.
- **Recommendation:** Migrate when support is removed.

### R-015 · INFO · Android live harness mechanics are valid

- **Candidates:** CC-0172, CC-0173, CC-0174, CC-0175, CC-0177, CC-0178, CC-0192, CC-0197
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/android_live_matching_test.dart:30-33 — the integration binding and real service test are initialized
  - integration_test/android_live_matching_test.dart:94-114 — the final partial chunk is bounded and asynchronous recognition is given a settle loop
  - integration_test/android_live_matching_test.dart:117-119 — the expected transcript assertions match the documented fixture
- **Decision:** These candidates explicitly dismiss the code or rely on invalid claims; no current defect is present.
- **Recommendation:** No change.

### R-016 · INFO · Android OCR integration test intentionally accepts unavailable optional TTS

- **Candidates:** CC-0198
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/android_paddle_ocr_test.dart:88-90 — startup is timeout-bounded and the optional service result is diagnostic
- **Decision:** The candidate itself describes the false result as expected when the model is absent; the timeout already makes a hang fail. No missing asserted contract is shown.
- **Recommendation:** No change required.

### R-017 · INFO · Android PDF text fallback is explicit and intentional

- **Candidates:** CC-0137, CC-0138
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PdfTextPlugin.kt:41-55 — extraction returns null and embedded-text checks route to OCR
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PdfTextPlugin.kt:61-68 — the constant false behavior and PdfRenderer limitation are documented
- **Decision:** The function no longer implies a real text-layer probe: current comments explicitly define Android as OCR-only because PdfRenderer cannot extract text. OCR is the supported fallback, not an accidental slow path.
- **Recommendation:** No change required unless an Android text-extraction backend is added.

### R-018 · INFO · Android screenshot surface conversion is present

- **Candidates:** CC-0244
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/screenshot_test.dart:38 — convertFlutterSurfaceToImage is awaited
  - integration_test/screenshot_test.dart:40 — takeScreenshot follows conversion
- **Decision:** The candidate explicitly confirms the required Android sequence.
- **Recommendation:** No change.

### R-019 · INFO · Android signing secrets are ignored and absent from history

- **Candidates:** CC-0004, CC-0005, CC-0006, CC-0007, CC-0008, CC-0009, CC-0010
- **Provenance:** `android-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/.gitignore:10-14 — key.properties and all .keystore/.jks files are ignored
  - android/app/build.gradle.kts:16-20 — credentials are only loaded from the external key.properties file
- **Decision:** The repository contains no android/key.properties commit in git history, and current ignore rules cover both the properties file and keystores. The hypothesized credential exposure is absent.
- **Recommendation:** No change required; keep signing material outside version control.

### R-020 · INFO · Android stub emits the handled fallback code

- **Candidates:** CC-0884
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/StubPlugins.kt:91-94 — startDownload returns PlatformException code UNAVAILABLE
  - lib/data/services/model_download_service.dart:548-553 — UNAVAILABLE invokes the Dart fallback for eligible ASR models
- **Decision:** The hypothesized alternate error code is absent from the current native stub.
- **Recommendation:** No change.

### R-021 · INFO · App Store Connect identifiers are deliberate nonsecrets

- **Candidates:** CC-2297, CC-2298, CC-2299, CC-2300, CC-2301, CC-2302, CC-2303, CC-2304
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `shell-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `shell-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/ship-testflight.sh:10-14 — comments intentionally record working key/team identifiers.
  - scripts/ship-testflight.sh:36-55 — private credentials remain local.
- **Decision:** Key/team IDs are identifiers, not authentication secrets, and serve as operational reference.
- **Recommendation:** No security fix required.

### R-022 · INFO · Apple crash filenames do not contain hostile whitespace

- **Candidates:** CC-2287
- **Provenance:** `shell-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/pull-crashlog.sh:50-51 — only system-named Runner-*.ips/ExcUserFault_Runner-*.ips files are consumed
- **Decision:** The read loop style is imperfect, but current Apple-generated crash filenames do not supply the backslash/whitespace trigger.
- **Recommendation:** No change.

### R-023 · INFO · Apple emits one final result followed by onDone

- **Candidates:** CC-1145
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/AppleSttPlugin.swift:252-268 — isFinal immediately stops the session and posts onDone
  - lib/data/services/stt_service.dart:190-201 — _lastPartial is merged by that onDone
- **Decision:** The native implementation cannot emit multiple final segments within one session, so earlier finalized text is not overwritten as hypothesized.
- **Recommendation:** No change.

### R-024 · INFO · ASR WAV probe matches its canonical fixture

- **Candidates:** CC-0142
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/asr_testwav_transcript_macos_test.dart:39 — the test explicitly documents its canonical 44-byte PCM16 fixture assumption
  - integration_test/asr_testwav_transcript_macos_test.dart:40 — it reads the fixture sample rate from the canonical header
- **Decision:** The candidate contains no concrete failure claim, and the fixed fixture is explicitly constrained to the format the probe decodes.
- **Recommendation:** No change.

### R-025 · INFO · Assigned sign-out checks describe current correct behavior

- **Candidates:** CC-1992, CC-1993
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/settings_screen.dart:328 — auth_skipped removal is awaited
  - lib/features/settings/settings_screen.dart:334 — remote sign-out is awaited
  - lib/features/settings/settings_screen.dart:335 — failure is caught and surfaced
- **Decision:** The candidates explicitly mark these paths good and identify no defect.
- **Recommendation:** No change.

### R-026 · INFO · Async model download does not synchronously block the UI isolate for its duration

- **Candidates:** CC-2053
- **Provenance:** `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/main.dart:124-147 — model operations are awaited in an unawaited asynchronous microtask and are consent-gated
  - lib/main.dart:159-168 — runApp does not await that microtask
- **Decision:** Network/file futures yield the isolate; the claimed 178MB synchronous UI block is not supported by source. Some startup contention is covered by the broader startup finding.
- **Recommendation:** No isolate migration required solely for asynchronous download I/O.

### R-027 · INFO · Audit-transparency note is not a defect

- **Candidates:** CC-0001
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - pubspec.yaml:9 — the current repository does contain a dependency manifest
- **Decision:** The candidate is a batch-scope disclaimer, not a current failure, and its premise does not apply to the repository as a whole.
- **Recommendation:** No code change.

### R-028 · INFO · Automatic redirects retain Dart HTTPS downgrade protection

- **Candidates:** CC-0913, CC-0914, CC-0915
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/model_manager.dart:292 — request.followRedirects is left at the Dart default
  - lib/data/services/model_manager.dart:310 — manual scheme guard is reached only for redirects not auto-followed
- **Decision:** The manual branch is largely dead for ordinary redirects, but Dart HttpClient does not auto-follow an HTTPS-to-HTTP downgrade. The claimed cleartext bypass is therefore invalid.
- **Recommendation:** Set followRedirects=false for clarity/consistent explicit handling, but no current security failure is verified.

### R-029 · INFO · Awaiting platform initialization does not block the UI isolate

- **Candidates:** CC-1232
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/tts_service.dart:151-177 — initialization consists of awaited asynchronous platform/model operations
- **Decision:** Awaiting MethodChannel futures yields the isolate; moving channel work to a Dart isolate is invalid and the claimed synchronous UI blocking is not shown.
- **Recommendation:** No change.

### R-030 · INFO · Background home refresh errors are caught and home remains mounted on push

- **Candidates:** CC-1457
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/home/home_screen.dart:289 — reconcile catches all errors
  - lib/features/home/home_screen.dart:350 — refresh also catches all errors
- **Decision:** Normal route pushes retain HomeScreen beneath the stack, and disposal-related ref errors fall into the existing catch rather than causing the claimed uncaught failure.
- **Recommendation:** No change required.

### R-031 · INFO · Background is checked before generation cancellation

- **Candidates:** CC-0384
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroMLXService.swift:179-197 — the immediate background check occurs before synthGeneration increments
  - ios/Runner/KokoroMLXService.swift:210-226 — queued work rechecks generation and background before GPU submission
- **Decision:** The newer request does not cancel an older generation when it is already backgrounded at entry; the queued recheck is an intentional safety gate for a later lifecycle transition.
- **Recommendation:** No change.

### R-032 · INFO · Background URL-session completion follows the documented normal path

- **Candidates:** CC-0258
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/AppDelegate.swift:35 — the OS completion handler is retained
  - ios/Runner/BackgroundDownloadPlugin.swift:294 — URLSession completion events invoke the handler
  - ios/Runner/BackgroundDownloadPlugin.swift:297 — the handler is cleared immediately after invocation
- **Decision:** The candidate itself identifies no realistic missed callback; absence of a handler when no relaunch callback was provided is valid.
- **Recommendation:** No change.

### R-033 · INFO · Background-task identifier accesses are main-actor serialized

- **Candidates:** CC-0367
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroMLXPlugin.swift:58 — identifier assignment occurs inside MainActor.run
  - ios/Runner/KokoroMLXPlugin.swift:80 — completion reads and ends it inside MainActor.run
- **Decision:** The mutable identifier is accessed on the main actor, including the UIKit expiration path; the alleged cross-thread unsynchronized access is not demonstrated.
- **Recommendation:** No change required.

### R-034 · INFO · BART cache concatenation is tightly bounded

- **Candidates:** CC-0559, CC-0560
- **Provenance:** `ios-performance-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/FallbackNetwork/BARTModel.swift:125 — generation defaults to at most 50 tokens
  - ios/Runner/MisakiVendored/English/FallbackNetwork/BARTModel.swift:137 — loop is bounded by maxLength
- **Decision:** The quadratic copy shape is bounded to a tiny fallback word decode and no measured bottleneck or failure is shown.
- **Recommendation:** Profile before redesigning the cache representation.

### R-035 · INFO · BART phoneme filter correctly skips four special slots

- **Candidates:** CC-0570
- **Provenance:** `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/MisakiVendored/Resources/us_bart_config.json:40 — phoneme_chars starts with four underscores before A
  - ios/Runner/MisakiVendored/English/FallbackNetwork/EnglishFallbackNetwork.swift:64 — accepts token IDs greater than the special unknown ID 3
- **Decision:** The first real phoneme A is ID 4, not ID 0; valid A/I/O/W phonemes are therefore retained.
- **Recommendation:** No change.

### R-036 · INFO · batchFirst false is unreachable in current callers

- **Candidates:** CC-0421
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroVendored/BuildingBlocks/LSTM.swift:12,26-57 — batchFirst is stored by the internal vendored class.
- **Decision:** All repository construction uses the batch-first behavior; no current caller supplies an incompatible layout.
- **Recommendation:** No change; an assertion would be optional API hardening.

### R-037 · INFO · Bidirectional LSTM duplication has not diverged

- **Candidates:** CC-0422
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroVendored/BuildingBlocks/LSTM.swift:61-166 — forward and backward implementations remain numerically parallel.
- **Decision:** The candidate predicts a future maintenance error rather than identifying a current output failure.
- **Recommendation:** No defect fix required.

### R-038 · INFO · Bounded ADB provisioning retries are not a performance defect

- **Candidates:** CC-2270
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/phone-harness.sh:61 — package polling is bounded to 120 iterations
  - scripts/phone-harness.sh:70 — copy retry is bounded to three attempts
  - scripts/phone-harness.sh:43 — adb push uses --sync for unchanged files
- **Decision:** This is infrequent operator tooling and the candidate identifies no current consequence.
- **Recommendation:** No change.

### R-039 · INFO · Bounded PDFKit matching work is not a verified freeze

- **Candidates:** CC-1025
- **Provenance:** `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/script_import_service.dart:755-775 — matching is capped at 150 raw lines per parsed line.
- **Decision:** No measured user-visible failure is established; mapping correctness is separately accounted.
- **Recommendation:** No defect fix required.

### R-040 · INFO · Bounded prefetch index scans are below meaningful scale

- **Candidates:** CC-1626, CC-1627
- **Provenance:** `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:2109 — prefetch depth is fixed at two or four
  - lib/features/rehearsal/rehearsal_screen.dart:2115 — indexOf scan occurs only within that bounded loop
- **Decision:** The candidates themselves characterize the cost as sub-millisecond/negligible under realistic line counts.
- **Recommendation:** No change unless profiling contradicts that bound.

### R-041 · INFO · Bounded test-isolate decode is not a product performance failure

- **Candidates:** CC-0206
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/android_rehearsal_harness_test.dart:264-272 — synchronous decode occurs only in the two-line injected test fallback.
- **Decision:** The bounded fixture work is test-only and the candidate measures no failure.
- **Recommendation:** No change.

### R-042 · INFO · Bounded vocabulary scan is already memoized and pruned

- **Candidates:** CC-1184
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/stt_vocabulary_service.dart:307 — correctionCache avoids repeat scans
  - lib/data/services/stt_vocabulary_service.dart:337 — candidates outside the useful length difference are skipped
  - lib/data/services/stt_vocabulary_service.dart:343 — distance-one hits exit early
- **Decision:** This candidate explicitly identifies no defect in current behavior.
- **Recommendation:** No change.

### R-043 · INFO · Bridging header is a valid first-party bridge

- **Candidates:** CC-0699
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/Runner-Bridging-Header.h:2 — the header contains the intended first-party Objective-C import
- **Decision:** The candidate explicitly reports no issue.
- **Recommendation:** No change.

### R-044 · INFO · BSD grep accepts the ios whitespace expression here

- **Candidates:** CC-2275
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/pull-crashlog.sh:21-25 — fallback uses grep -E "ios\s"
- **Decision:** A targeted run with the workstation BSD grep matched "ios " for this expression, so the claimed literal-s behavior is false on the supported host.
- **Recommendation:** No change.

### R-045 · INFO · Bulk save adopts the server row id locally

- **Candidates:** CC-1363, CC-1365, CC-1366
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:283 — createCastInvitation returns the inserted row
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:290 — memberId is replaced with row[id]
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:301 — the local CastMemberModel uses that returned id
- **Decision:** Passing a client id is unnecessary here because the current implementation explicitly mirrors the server-generated id into the local record.
- **Recommendation:** No change.

### R-046 · INFO · Bundled fallback weights are not runtime-mutated

- **Candidates:** CC-0582, CC-0583, CC-0584
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/FallbackNetwork/EnglishFallbackNetwork.swift:87 — config is loaded from the signed app bundle
  - ios/Runner/MisakiVendored/English/FallbackNetwork/EnglishFallbackNetwork.swift:95 — weights are also loaded from the app bundle
  - ios/Runner/MisakiVendored/English/FallbackNetwork/BARTModel.swift:26 — downstream keys are force-unwrapped
- **Decision:** A partial bundle would be a broken signed application build/installation, not a realistic user-controlled or downloaded current trigger. Missing/unreadable bundles already return nil.
- **Recommendation:** Optionally validate keys as build-time packaging defense.

### R-047 · INFO · Bundled G2P force unwraps are not a realistic input-triggered crash

- **Candidates:** CC-0492
- **Provenance:** `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:239 — setup occurs for bundled language resources
  - ios/Runner/MisakiVendored/Resources/us_bart_config.json:1 — the configuration is committed app data
- **Decision:** Malformed regex literals or signed bundle resources require a broken build/package, not user text. No current resource mismatch is shown.
- **Recommendation:** Validate bundle resources in packaging tests rather than adding runtime branches for impossible signed-resource mutation.

### R-048 · INFO · Bundled gold lexicon resources are present

- **Candidates:** CC-0588, CC-0589, CC-0590, CC-0591, CC-0592
- **Provenance:** `ios-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/Lexicon/DataResourcesUtil.swift:6-16 — gold loader falls back only when a bundled file/read/decode fails.
  - ios/Runner/MisakiVendored/Resources/us_gold.json:6066 — current US gold resource is present.
  - ios/Runner/MisakiVendored/Resources/gb_gold.json:6235 — current GB gold resource is present.
- **Decision:** The proposed packaging regression is absent; logging differences alone are not a runtime failure.
- **Recommendation:** No defect fix required.

### R-049 · INFO · Bundled test script has negligible release impact

- **Candidates:** CC-2161
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - pubspec.yaml:105 — assets/test_scripts is bundled
  - assets/test_scripts/hamlet.txt:1 — the directory contains one text fixture
- **Decision:** The only fixture is roughly 207 KB and contains non-secret literary text; no meaningful install-size or confidentiality failure is shown.
- **Recommendation:** Optional: move it to test-only resources if release-size policy requires it.

### R-050 · INFO · Candidate contains no actionable claim

- **Candidates:** CC-0709
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/kokoro_service_queue_macos_test.dart:1 — the repository test is concrete, while the assigned finding body is only an ellipsis
- **Decision:** The assigned text supplies no alleged behavior, trigger, or failure to verify.
- **Recommendation:** No change without a substantive claim.

### R-051 · INFO · Canonical character rebuild excludes empty names

- **Candidates:** CC-1664
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/models/script_models.dart:434 — dialogue with an empty character is skipped
  - lib/data/models/script_models.dart:445 — ScriptCharacter entries are built only from collected non-empty cue keys
  - lib/features/script_editor/character_manager_screen.dart:114 — screen consumes the canonical script.characters list
- **Decision:** Current parser/persistence edit paths rebuild characters through the canonical helper, so the assumed empty ScriptCharacter is not emitted.
- **Recommendation:** Keep the invariant; optional defensive avatar fallback is harmless.

### R-052 · INFO · Cast manager caches are bounded per route

- **Candidates:** CC-1388
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/cast_manager/cast_manager_screen.dart:37 — assignment cache stores one map
  - lib/features/cast_manager/cast_manager_screen.dart:43 — line cache stores one map per screen state
- **Decision:** The candidate explicitly found no unbounded growth.
- **Recommendation:** No change.

### R-053 · INFO · Cast manager size is a maintainability observation

- **Candidates:** CC-1387
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/cast_manager/cast_manager_screen.dart:26 — the current screen owns cast-management UI and actions
- **Decision:** File size/mixed concerns do not prove a current observable failure.
- **Recommendation:** Split only as a deliberate refactor with behavior coverage.

### R-054 · INFO · Cast-list share scan is too small and infrequent to fail

- **Candidates:** CC-1417
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/cast_manager/cast_manager_screen.dart:1111 — work occurs only when the user explicitly shares the cast list
- **Decision:** The stated 100×200 scan is about 20,000 in-memory comparisons on a cold manual action, not a realistic performance failure.
- **Recommendation:** Optional indexing if profiling warrants it.

### R-055 · INFO · Cast-roster RPC was secured by a later migration

- **Candidates:** CC-2464
- **Provenance:** `db-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:84 — old one-argument function is dropped
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:85 — replacement requires production id and code
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:83 — migration documents code-or-membership authorization
- **Decision:** The assigned finding targets the older 202607 definition; the current migration chain replaces it with an authorization-aware signature.
- **Recommendation:** No change.

### R-056 · INFO · Ceil/floor difference is latent under current scale factors

- **Candidates:** CC-0414
- **Provenance:** `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroVendored/BuildingBlocks/Interpolate.swift:36 — output uses ceil
  - ios/Runner/KokoroVendored/BuildingBlocks/Interpolate.swift:44 — only the current 1D path is supported
- **Decision:** The finding itself concedes all current callers use exact integer ratios where ceil equals floor, so there is no current failure trigger.
- **Recommendation:** Align the implementation/comment when non-integral scale factors are added.

### R-057 · INFO · Character action switch does not fall through in Dart 3

- **Candidates:** CC-1667, CC-1668, CC-1669
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/character_manager_screen.dart:277 — _handleAction uses modern Dart switch cases
  - lib/features/script_editor/character_manager_screen.dart:278 — locale is one case
  - lib/features/script_editor/character_manager_screen.dart:280 — rename is a distinct non-fallthrough case
- **Decision:** Modern Dart case clauses implicitly terminate; selecting one action invokes only that handler. The claimed compile error/dialog cascade is false.
- **Recommendation:** No breaks are required.

### R-058 · INFO · Character color indices are nonnegative at current call sites

- **Candidates:** CC-0735, CC-0736
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/models/script_models.dart:448 — character color indices are generated from a zero-based loop
  - lib/features/recording_studio/recording_character_screen.dart:89 — rendering passes that stored colorIndex
- **Decision:** Current callers guard sentinel indices or use generated nonnegative indices; negative modulo indexing is not reachable.
- **Recommendation:** No change required.

### R-059 · INFO · Character detail and mutation passes are bounded one-shot work

- **Candidates:** CC-1678, CC-1679, CC-1680, CC-1681, CC-1682
- **Provenance:** `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/character_manager_screen.dart:456 — detail scans run only on a user tap
  - lib/features/script_editor/character_manager_screen.dart:560 — rename maps lines once per explicit rename
  - lib/features/script_editor/character_manager_screen.dart:641 — cast load runs only during rename migration
- **Decision:** The candidates either explicitly dismiss the work or describe bounded O(script) work on rare manual actions without a demonstrated user-visible failure.
- **Recommendation:** No optimization absent profiling.

### R-060 · INFO · Character gender toggle performs a bounded one-off rebuild

- **Candidates:** CC-1447
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/character_manager_screen.dart:253 — the toggle maps the character list once
  - lib/features/script_editor/character_manager_screen.dart:258 — existing lines, scenes and rawText objects are reused in the new ParsedScript
- **Decision:** No full rawText copy or hot-loop trigger is shown; this user-tap O(character-count) update is appropriate.
- **Recommendation:** No change.

### R-061 · INFO · Character maps are small session caches, not a current leak

- **Candidates:** CC-1227, CC-1228
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `metal-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/tts_service.dart:48-57 — maps store one small value per distinct character name and overwrite repeated names
- **Decision:** The candidate establishes neither a realistic memory threshold nor a persistent cross-process leak; current production casts keep these maps small.
- **Recommendation:** No change.

### R-062 · INFO · Character rename cloud loop is bounded to one role name

- **Candidates:** CC-1448
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/character_manager_screen.dart:642 — affected rows are filtered to oldName
  - lib/features/script_editor/character_manager_screen.dart:647 — only those rows are renamed
  - lib/features/script_editor/character_manager_screen.dart:650 — each affected row performs one cloud update
- **Decision:** A normal cast has only a primary actor and perhaps understudies for one character, not the candidate's entire 20-person cast; no realistic latency failure is established.
- **Recommendation:** No change absent profiling.

### R-063 · INFO · Character-name part lookup cannot produce the claimed malformed token

- **Candidates:** CC-1194
- **Provenance:** `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/stt_vocabulary_service.dart:538 — lookup and source substring use the same lowercased name
  - lib/data/services/stt_vocabulary_service.dart:541 — indexOf finds an occurrence of the exact part
  - lib/data/services/stt_vocabulary_service.dart:542 — substring length equals the part length
- **Decision:** An earlier occurrence may preserve different casing, but because it is the exact same case-folded substring it cannot include the claimed trailing space or different letters; character names are also normally consistently cased.
- **Recommendation:** No change; offset-preserving splitting would only improve casing fidelity.

### R-064 · INFO · Chunk splitting work is bounded and intentional

- **Candidates:** CC-1249, CC-1252
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/tts_service.dart:523-598 — splitting is limited to one line and enforces a 300-character chunk ceiling
- **Decision:** The candidates identify either bounded work or stylistic duplication, not a current observable failure.
- **Recommendation:** No change.

### R-065 · INFO · clearCache intentionally deletes all downloaded models

- **Candidates:** CC-0901, CC-0902, CC-0903
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/model_manager.dart:156 — API contract says Delete all cached models
  - lib/features/settings/model_download_screen.dart:237 — UI confirmation says Delete all downloaded models
- **Decision:** Deleting the shared models root, including live ASR, is the declared operation rather than collateral deletion.
- **Recommendation:** No change required.

### R-066 · INFO · Clipboard log formatting is ordinary and candidate asserts no defect

- **Candidates:** CC-1925
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/debug_log_screen.dart:110-121 — copy serializes timestamp/category/message as designed
- **Decision:** The candidate explicitly marks this behavior fine.
- **Recommendation:** No change required.

### R-067 · INFO · Cloud deletion is attempted even when remoteUrl is null

- **Candidates:** CC-1583
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/recording_studio/recordings_browser_screen.dart:559 — remoteUrl only computes wasUploaded
  - lib/features/recording_studio/recordings_browser_screen.dart:562 — delete query runs regardless of wasUploaded
  - lib/features/recording_studio/recordings_browser_screen.dart:569 — any removed prior row returns deleted
- **Decision:** A newly re-recorded local take with null remoteUrl still causes deletion of the old row by production, line, and user; the proposed skip does not occur.
- **Recommendation:** No change.

### R-068 · INFO · Cloud diff is linear and its Dart switches do not fall through

- **Candidates:** CC-1696, CC-1697, CC-1698, CC-1699, CC-1700, CC-1701, CC-1702
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/cloud_sync_dialog.dart:22-60 — diff builds one id map and performs linear passes
  - lib/features/script_editor/cloud_sync_dialog.dart:76-86,200-215 — Dart switch cases implicitly terminate after each case body
- **Decision:** The diff is O(local + cloud), not an unbounded quadratic UI computation, and Dart’s language semantics invalidate all missing-break/blank-tile claims.
- **Recommendation:** No break changes are required; address only the separate reorder omission.

### R-069 · INFO · Cloud diff materialization is linear and list rendering is lazy

- **Candidates:** CC-1449
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/cloud_sync_dialog.dart:73 — diff is computed once
  - lib/features/script_editor/cloud_sync_dialog.dart:143 — changed rows render with ListView.builder
- **Decision:** Thousands of small LineDiff objects are bounded by script size and tiles are lazy; no memory or latency failure is demonstrated.
- **Recommendation:** No change required.

### R-070 · INFO · Cloud reconciliation functions have distinct authority semantics

- **Candidates:** CC-1456
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/home/home_screen.dart:263 — reconcile handles absence of a local script
  - lib/features/home/home_screen.dart:295 — refresh compares an existing castmate cache and guards truncation
- **Decision:** The two methods intentionally implement different source-of-truth rules; similarity is not a defect.
- **Recommendation:** No change required.

### R-071 · INFO · Cloud script line IDs are UUID constrained

- **Candidates:** CC-1551
- **Provenance:** `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/recording_studio/recording_studio_screen.dart:590-598 — line ID forms filename; supabase/migrations/20260314120000_add_script_lines.sql:8 declares UUID IDs.
- **Decision:** Traversal strings cannot arrive from cloud rows.
- **Recommendation:** No change.

### R-072 · INFO · Color value comparisons are trivial

- **Candidates:** CC-1450
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/cloud_sync_dialog.dart:231 — two short-lived Color values are used while building one visible tile
- **Decision:** This is a constant amount of work per visible tile and cannot create the claimed scaling issue.
- **Recommendation:** No change required.

### R-073 · INFO · Committed OCR dictionary uses compatible line endings

- **Candidates:** CC-0663, CC-0664
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/PaddleOcrPlugin.swift:121 — splits keys on newline
  - assets/paddle_ocr/keys.txt:1 — the committed dictionary is UTF-8 text with LF lines
- **Decision:** The conditional CRLF corruption does not apply to the shipped asset.
- **Recommendation:** Trimming CR would be harmless hardening but is not a current defect.

### R-074 · INFO · Committed Supabase key is explicitly publishable

- **Candidates:** CC-2605, CC-2606, CC-2607, CC-2608, CC-2613, CC-2614
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - test/supabase_join_test.dart:24 — key uses sb_publishable prefix
  - test/supabase_join_test.dart:33 — it is supplied as the public apikey
  - supabase/migrations/20260703140000_security_lockdown.sql:5 — repository security relies on RLS rather than secrecy of the client key
- **Decision:** The candidates correctly note that this is a client-public key and do not identify a service-role secret.
- **Recommendation:** No key-removal action for this candidate; keep RLS authoritative.

### R-075 · INFO · Completion wait is a valid synchronization guard

- **Candidates:** CC-0203
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/android_rehearsal_harness_test.dart:193-202 — the handler completion is awaited with a timeout after speak.
- **Decision:** A possibly redundant wait neither fails nor weakens the exercised behavior.
- **Recommendation:** No change.

### R-076 · INFO · Console-only voice logs are an observability preference

- **Candidates:** CC-1307
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/voice_config_service.dart:57-62,93-100 — writes are persisted before debugPrint.
- **Decision:** No mutation is lost because of the logging sink.
- **Recommendation:** No defect fix required.

### R-077 · INFO · Constant assertions intentionally pin API values

- **Candidates:** CC-2598, CC-2599
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - test/stt_adaptation_test.dart:127-130 — tests pin public readiness thresholds.
- **Decision:** They force review when product thresholds are retuned; this is not a runtime tautology defect.
- **Recommendation:** No change.

### R-078 · INFO · Constants-only audit contains no finding

- **Candidates:** CC-0732
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/core/constants.dart:1 — contains static application constants only
- **Decision:** The candidate explicitly reports no secret or behavior defect.
- **Recommendation:** No change.

### R-079 · INFO · Contact picker presentation hang is speculative

- **Candidates:** CC-0364
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/ContactPickerPlugin.swift:48 — finds the topmost presented controller before presenting
  - ios/Runner/ContactPickerPlugin.swift:44 — presents from that top controller
- **Decision:** The candidate assumes UIKit silently no-ops without a current call path or state proving that behavior.
- **Recommendation:** If field evidence appears, explicitly serialize presentation; no source-proven fix is required now.

### R-080 · INFO · Contact-property delegate is not required by the configured picker

- **Candidates:** CC-0365
- **Provenance:** `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/ContactPickerPlugin.swift:35 — creates a default CNContactPickerViewController
  - ios/Runner/ContactPickerPlugin.swift:66 — implements full-contact selection
  - ios/Runner/ContactPickerPlugin.swift:35 — sets no predicateForSelectionOfProperty or property-selection configuration
- **Decision:** A default contact picker selects contacts through didSelect contact; the property callback is for property-selection configurations this plugin does not enable.
- **Recommendation:** No change.

### R-081 · INFO · Controller replacement follows supported listener teardown

- **Candidates:** CC-1723, CC-1724, CC-1725, CC-1726
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:44-51 — old controller is disposed when a new line controller is created.
  - lib/features/script_editor/script_editor_screen.dart:514-527 — the TextField receives the new controller during rebuild.
- **Decision:** Flutter permits removeListener after disposal for teardown ordering; no realistic used-after-dispose action is shown.
- **Recommendation:** No change.

### R-082 · INFO · Correction-cache clear burst requires an unsupported extreme trigger

- **Candidates:** CC-1183
- **Provenance:** `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/stt_vocabulary_service.dart:304 — repeated partial words are memoized
  - lib/data/services/stt_vocabulary_service.dart:313 — the cache is bounded at 4,000 distinct recognized words
  - lib/data/services/stt_vocabulary_service.dart:316 — the triggering word is immediately repopulated
- **Decision:** Crossing 4,000 distinct misrecognized tokens in one production session is not a realistic rehearsal path, and no measured frame loss supports the claim.
- **Recommendation:** No change absent profiling.

### R-083 · INFO · Corrupt queue is quarantined rather than silently overwritten

- **Candidates:** CC-1212
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/sync_queue.dart:218 — corrupt JSON is explicitly logged
  - lib/data/services/sync_queue.dart:224 — the original file is renamed with a .corrupt suffix
- **Decision:** Unparseable JSON cannot safely be restored; current code preserves the evidence instead of silently destroying it.
- **Recommendation:** No change required; a user-facing recovery notice is optional.

### R-084 · INFO · Crash filename Python injection is not realistically reachable

- **Candidates:** CC-2288, CC-2289, CC-2290
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `shell-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/pull-crashlog.sh:50-67 — LATEST comes from fixed Apple crash-report naming under a user-owned subdirectory, then is interpolated into Python source
- **Decision:** The interpolation should be avoided, but paired devices do not control Apple crash filenames and /tmp/castcircle-crashes is a user-owned subdirectory, so the claimed hostile filename execution path is not realistic.
- **Recommendation:** No change.

### R-085 · INFO · Crashlog history scan is operator-bounded

- **Candidates:** CC-2285, CC-2286
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/pull-crashlog.sh:48-58 — the operator tool scans retained crash files to select the newest
- **Decision:** The candidate itself characterizes files as small and the tool as manually invoked; no meaningful resource threshold is established.
- **Recommendation:** No change.

### R-086 · INFO · Cross-document cache reuse is masked by current widget keys

- **Candidates:** CC-1817, CC-1818, CC-1819, CC-1824, CC-1827, CC-1829, CC-1830, CC-1833, CC-1834, CC-1836
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:503 — keys each source viewer by line ID
  - lib/features/script_editor/script_editor_screen.dart:925 — editor sheet also keys by line ID
  - lib/features/script_import/ocr_review_screen.dart:363 — review sheet remounts per line
  - lib/features/script_import/ocr_review_screen.dart:693 — review pane remounts per selection
- **Decision:** Every current retarget across selected lines remounts the State and disposes its page/OCR caches, so a previous PDF cache is not reused by reachable callers. The class remains fragile for future stable-key reuse.
- **Recommendation:** If keys are stabilized to recover caching, key caches by path and clear all document-scoped state on path changes.

### R-087 · INFO · Cross-production audio URL is blocked by storage RLS

- **Candidates:** CC-0974
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/recording_sync_service.dart:428-437 — client downloads row URL but catches authorization failures.
  - supabase/migrations/20260703140000_security_lockdown.sql:57-63 — reads require membership in the production encoded in the object path.
- **Decision:** A member of production A cannot make every A device read a production B object; storage authorization evaluates B.
- **Recommendation:** No change; prefix validation is optional defense in depth.

### R-088 · INFO · Cue-regex duplication is maintainability-only

- **Candidates:** CC-2248
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/pdf_to_script.py:368 — quick stats use a local cue regex
  - scripts/compare_macbeth_versions.py:22 — comparison uses a similar regex
- **Decision:** The candidate shows no current divergence that causes a distinct failure beyond the separately verified over-broad regex.
- **Recommendation:** Consolidation is optional after fixing cue semantics.

### R-089 · INFO · Current chunk and speed bounds do not exceed 60 seconds

- **Candidates:** CC-1257, CC-1258
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/tts_service.dart:575-597 — every chunk is capped at 300 characters
  - lib/data/services/tts_service.dart:844-850 — Kokoro speed is clamped to at least 0.5
- **Decision:** The candidate does not establish a realistic supported 300-character utterance lasting longer than the generous timeout; silent truncation is speculative.
- **Recommendation:** No change.

### R-090 · INFO · Current Dart flows do not overlap Paddle jobs

- **Candidates:** CC-0112, CC-0113, CC-0114, CC-0115
- **Provenance:** `kotlin-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `kotlin-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/script_import_service.dart:357-371 — full-document Paddle OCR is awaited as one import operation
  - lib/data/services/paddle_ocr_channel.dart:71-92 — page OCR is a separate viewer call that converts platform failures to null
- **Decision:** The native entry points use independent threads, but current UI/import callers serialize the full import and invoke page OCR later. The asserted overlapping multi-pipeline/OOM trigger is not established; ONNX Runtime sessions also support concurrent Run calls.
- **Recommendation:** No change.

### R-091 · INFO · Current Drift writers persist only valid enum names

- **Candidates:** CC-0779, CC-0780, CC-0781, CC-0782, CC-0783, CC-0784, CC-0785, CC-0786, CC-0787, CC-0788, CC-0793, CC-0794, CC-0795, CC-0796, CC-0797
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/repositories/production_repository.dart:34 — production status is persisted with enum.name
  - lib/data/repositories/production_repository.dart:91 — cast role is persisted with enum.name
  - lib/data/repositories/production_repository.dart:132 — line type is persisted with enum.name
  - lib/data/repositories/production_repository.dart:68 — strict byName reads those locally controlled values
- **Decision:** Every current local writer and migration uses valid current enum names; the alleged bad row requires hypothetical corruption, an unseen writer, or a future/downgraded schema rather than a realistic current trigger.
- **Recommendation:** Add tolerant decoding only as optional corruption/downgrade hardening.

### R-092 · INFO · Current harness duration matches its writer

- **Candidates:** CC-0201
- **Provenance:** `testing-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/android_rehearsal_harness_test.dart:132-140 — duration deliberately documents and uses the current 24 kHz PCM/44-byte writer contract.
- **Decision:** The finding depends on a future writer change; current generated files satisfy the assumption.
- **Recommendation:** No change.

### R-093 · INFO · Current recording schema prevents the alleged null substring inputs

- **Candidates:** CC-2701, CC-2702, CC-2703, CC-2704, CC-2705, CC-2706, CC-2707, CC-2708, CC-2709, CC-2710, CC-2711, CC-2712
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260314061409_initial_schema.sql:106-114 — recorded_at, user_id, line_id, and audio_url are all NOT NULL
  - tool/analyze_orphaned_recordings.dart:91-107 — substring fields come from those constrained recording columns
- **Decision:** The null fallback is indeed shorter than the substring, but current database constraints make null rows impossible, and current app/tool IDs are UUID-length. No realistic current row reaches the alleged fallback.
- **Recommendation:** No change required; a safe truncation helper would only harden against manually corrupted legacy data.

### R-094 · INFO · Current sign-in and sign-out flows explicitly navigate after gate changes

- **Candidates:** CC-0720
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/auth/auth_screen.dart:347-350,422-424 — sign-in/skip set the gate and navigate
  - lib/features/settings/settings_screen.dart:354-358 — sign-out clears the gate and navigates to /auth
- **Decision:** Although GoRouter has no refreshListenable, all current gate mutations perform navigation, which reruns redirect. The claimed stranded sign-out path is absent.
- **Recommendation:** No change required for current call sites; reactive refresh would simplify the contract.

### R-095 · INFO · Current UI prevents duplicate same-model starts

- **Candidates:** CC-0881, CC-0882, CC-0883
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/settings/ai_models_screen.dart:364-368 — the download action is replaced by a progress indicator while status is downloading
  - lib/data/services/model_download_service.dart:448-460 — grouped downloads first select only files that are not already valid and await one Future per model
- **Decision:** The service lacks a defensive in-flight guard, but current user-facing call sites do not expose the asserted double-tap trigger; corruption is not proven.
- **Recommendation:** No change.

### R-096 · INFO · Dart accepts the clamp expression as an int endpoint

- **Candidates:** CC-1952, CC-1953, CC-1954
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/kokoro_debug_screen.dart:115 — substring receives text.length.clamp(0, 60)
  - lib/features/settings/kokoro_debug_screen.dart:115 — the receiver and both clamp bounds are ints
- **Decision:** Targeted `dart analyze lib/features/settings/kokoro_debug_screen.dart` reports no issues under the repository SDK; the claimed compile error is an invalid language/API assertion.
- **Recommendation:** No change.

### R-097 · INFO · Dart accepts the current int clamp as substring index

- **Candidates:** CC-2586, CC-2587
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - test/scene_partition_test.dart:55 — substring receives l.text.length.clamp(0, 30)
  - test/scene_partition_test.dart:55 — receiver is an int length
  - test/scene_partition_test.dart:15 — file is valid current Dart test code
- **Decision:** Targeted `dart analyze test/scene_partition_test.dart` reported “No issues found”; the claimed static type error is invalid for the current toolchain.
- **Recommendation:** No change.

### R-098 · INFO · Dart int.clamp is an int in the current SDK

- **Candidates:** CC-0707
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/kokoro_debug_screen.dart:115 — substring receives text.length.clamp(0, 60)
- **Decision:** On Dart 3.11 an int receiver returns an int from clamp, and the current expression compiles; the claimed static type error is invalid.
- **Recommendation:** No change.

### R-099 · INFO · Dart OCR mapping is bounded linear work

- **Candidates:** CC-1270
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/vision_ocr_channel.dart:45 — ocrPdf maps each returned page once
  - lib/data/services/vision_ocr_channel.dart:49 — it maps each returned line once
- **Decision:** The candidate explicitly concludes no issue.
- **Recommendation:** No change.

### R-100 · INFO · Dart service prevents inactive now-playing updates

- **Candidates:** CC-0512
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/media_control_service.dart:62-75 — updateNowPlaying returns immediately unless the service is active
  - lib/features/rehearsal/rehearsal_screen.dart:625 — rehearsal disposal deactivates the service
- **Decision:** The current caller-side guard prevents the alleged stale post-deactivate method call, and no other caller bypasses this singleton.
- **Recommendation:** No change required; native gating would be defense in depth.

### R-101 · INFO · Dart String multiplication is valid

- **Candidates:** CC-1418
- **Provenance:** `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/cast_manager/cast_manager_screen.dart:1118 — current Dart source uses the repetition operator in live code
- **Decision:** The current Dart SDK supports String * int; the compile-error claim is false.
- **Recommendation:** No change.

### R-102 · INFO · Dart supports String repetition in the current SDK

- **Candidates:** CC-0999
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/script_export.dart:22 — current source uses String * int in live export code
  - lib/data/services/script_export.dart:91 — the method returns normally from that compiled expression
- **Decision:** Dart 3.11 defines String multiplication; a targeted runtime probe produced the expected repeated string, so the claimed compile error is an invalid language assertion.
- **Recommendation:** No change.

### R-103 · INFO · Dart switch cases do not fall through

- **Candidates:** CC-1460, CC-1461, CC-1462, CC-1463, CC-1464, CC-1465
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/home/home_screen.dart:409 — current code uses Dart switch cases without break
  - lib/features/script_editor/cloud_sync_dialog.dart:77 — the same valid Dart 3 switch style is used throughout current code
- **Decision:** Modern Dart switch statements have implicit non-fallthrough termination; missing break is neither a compile error nor route cascade.
- **Recommendation:** No change required.

### R-104 · INFO · Dart switch cases do not fall through here

- **Candidates:** CC-1616, CC-1619, CC-1620, CC-1621, CC-1622
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:996 — state-chip switch uses modern Dart case semantics
  - lib/features/rehearsal/rehearsal_screen.dart:1575 — action switch uses the same semantics
  - pubspec.yaml:1 — this is a current Dart/Flutter project that successfully analyzes these constructs
- **Decision:** Modern Dart switch statements do not implicitly execute the following nonempty case; break is unnecessary. The alleged skipped lines and always-Ready chip are based on another language’s semantics.
- **Recommendation:** No change.

### R-105 · INFO · Dart switch cases do not fall through here

- **Candidates:** CC-1123, CC-1124, CC-1125, CC-1126, CC-1128, CC-1129
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/stt_channel.dart:129 — uses modern Dart switch statement cases
  - pubspec.yaml:7 — project requires Dart 3.11
- **Decision:** Modern Dart switch cases terminate implicitly; the file compiles and a callback executes only its matching case. The claimed compile error and cascade are invalid language semantics.
- **Recommendation:** No breaks are required.

### R-106 · INFO · Dart switch cases do not require break and do not fall through

- **Candidates:** CC-0863, CC-0864, CC-0865, CC-0866
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/media_control_service.dart:81-92 — each non-empty Dart case implicitly terminates; only the empty jumpBack label shares the next body
- **Decision:** The compile-error and double-dispatch claims apply Java/C-style fall-through semantics that Dart does not use. The file compiles, and onSkip is not called after onPlayPause.
- **Recommendation:** No break statements are required; fix the separate jumpBack mapping defect instead.

### R-107 · INFO · Dart switch cases have implicit non-fallthrough

- **Candidates:** CC-1841, CC-1842, CC-1843, CC-1844
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_import/script_import_screen.dart:187-197 — the switch uses modern Dart case bodies without break
- **Decision:** Modern Dart switch statements do not implicitly fall through; these case bodies are valid and count exactly one status each.
- **Recommendation:** No change.

### R-108 · INFO · Dart switch cases implicitly terminate

- **Candidates:** CC-1525, CC-1526, CC-1527, CC-1528, CC-1529, CC-1530, CC-1531, CC-1532
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/production_hub/production_hub_screen.dart:880 — current switch uses modern Dart case semantics
  - lib/features/production_hub/production_hub_screen.dart:881 — markdown assignments form one case
  - lib/features/production_hub/production_hub_screen.dart:884 — default is not executed after a matching non-empty case in Dart 3
- **Decision:** Modern Dart has implicit non-fallthrough switch cases; a targeted Dart 3.11 probe printed the markdown branch result and compiled. The build/fallthrough claim is invalid.
- **Recommendation:** No break is required.

### R-109 · INFO · Darwin statvfs offsets are correct

- **Candidates:** CC-0890
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/model_download_service.dart:790-798 — code reads 32-bit fsblkcnt_t fields at offsets 16/24 with sanity checks
- **Decision:** A targeted compile against the current Darwin headers reported sizeof(fsblkcnt_t)=4 and f_bavail offset 24, exactly matching the implementation; the candidate’s 64-bit ABI premise is false.
- **Recommendation:** No change.

### R-110 · INFO · Database allow-all CIDRs are in a disabled block

- **Candidates:** CC-2373
- **Provenance:** `docker-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/config.toml:67 — network restrictions section
  - supabase/config.toml:69 — enabled is false
- **Decision:** The CIDR values do not configure access while the feature is disabled, and enabling it would require an explicit operator change.
- **Recommendation:** Choose restrictive CIDRs at the same time if network restrictions are enabled later.

### R-111 · INFO · Dead TimestampPredictor assignment is nonfunctional

- **Candidates:** CC-0477
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroVendored/TTSEngine/TimestampPredictor.swift:34 — left is assigned
  - ios/Runner/KokoroVendored/TTSEngine/TimestampPredictor.swift:48 — later control flow overwrites it before the alleged use
- **Decision:** An overwritten assignment is cleanup, not a current failure.
- **Recommendation:** Optional cleanup only.

### R-112 · INFO · Debug speed conversion matches TtsService semantics

- **Candidates:** CC-1955
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/settings/kokoro_debug_screen.dart:118 — the displayed multiplier is converted by multiplying 0.5
  - lib/data/services/tts_service.dart:844 — setRate documents 0.5 as normal system rate
  - lib/data/services/tts_service.dart:849 — TtsService divides by 0.5 to recover Kokoro's 1.0 normal multiplier
- **Decision:** A displayed 1.0x becomes 0.5 at the public service boundary and is converted back to Kokoro 1.0 exactly as intended.
- **Recommendation:** No change.

### R-113 · INFO · Debug-info load cannot throw and guards its post-await setState

- **Candidates:** CC-1937, CC-1938, CC-1940, CC-1941
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/tts_service.dart:888 — getDebugInfo is an async method returning an in-memory map
  - lib/data/services/tts_service.dart:889 — it performs no platform or file operation
  - lib/features/settings/kokoro_debug_screen.dart:76 — the eventual setState is guarded by mounted
- **Decision:** The alleged plugin/TTS exception cannot arise from the current getDebugInfo implementation, so the spinner is not stranded on that path.
- **Recommendation:** No change.

### R-114 · INFO · Debug-log pull is bounded by service startup rotation

- **Candidates:** CC-2292
- **Provenance:** `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/pull-debuglog.sh:19 — copies the current log before tailing
  - lib/data/services/debug_log_service.dart:295 — truncates logs larger than 200 KB during load
  - lib/data/services/debug_log_service.dart:299 — rewrites only retained entries
- **Decision:** The log does not grow without bound across launches as claimed. A single unusually long run can exceed the threshold until restart, but copying that local diagnostic is the script purpose.
- **Recommendation:** Optional streaming tail retrieval is not required for correctness.

### R-115 · INFO · Debug-only WAV copy is not a release performance failure

- **Candidates:** CC-0509
- **Provenance:** `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroVendored/Utils/AudioUtils.swift:7 — the export helper is guarded by DEBUG
- **Decision:** The scalar copy is absent from production and no debug workflow failure is demonstrated.
- **Recommendation:** Use a bulk copy only as optional debug-tool cleanup.

### R-116 · INFO · debug_reports user index has no current application read path

- **Candidates:** CC-2475
- **Provenance:** `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260703140000_security_lockdown.sql:84 — the SELECT policy permits a user to read their own rows
  - supabase/migrations/20260320200000_add_debug_reports.sql:2 — the table is a support-report sink
  - supabase/migrations/20260703140000_security_lockdown.sql:88 — developer access uses the service role
  - lib/data/services/debug_log_service.dart:1 — repository search finds no client SELECT from debug_reports
- **Decision:** The app inserts reports and support pulls them with service credentials; no current per-user listing performs the alleged growing sequential scan.
- **Recommendation:** Add an index if a user-facing history query is introduced.

### R-117 · INFO · Decoder dimensions are fixed model architecture, not live configuration

- **Candidates:** CC-0430, CC-0431
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroVendored/Decoder/Decoder.swift:20 — dimOut is not used
  - ios/Runner/KokoroVendored/Decoder/Decoder.swift:29 — decoder widths are fixed to the vendored architecture
  - ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:71 — weights and bundled config are loaded together for this fixed pack
- **Decision:** No runtime path edits the bundled config independently of its matching signed/downloaded model architecture; the finding is a future-maintenance concern rather than a current failure.
- **Recommendation:** Optionally assert the supported architecture during model validation.

### R-118 · INFO · Deep-link setup does not expose the alleged current race

- **Candidates:** CC-0722, CC-0723, CC-0724
- **Provenance:** `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/deep_link_service.dart:101-129 — init catches initial-link and stream-listener failures and internally subscribes to live links
  - lib/data/services/deep_link_service.dart:131-137 — links arriving during init are stored in latestPendingJoin
  - lib/app.dart:208-225 — after init, app consumes latestPendingJoin before subscribing to later broadcasts
- **Decision:** The service captures links during its own initialization, so the app-level post-await subscription gap does not drop them; the cold-start emission occurs before the app listener and is handled once via latestPendingJoin. The app root normally shares the process lifetime.
- **Recommendation:** No change required; adding mounted guards would be defensive.

### R-119 · INFO · Dequeued codec output buffer is not realistically null

- **Candidates:** CC-0045, CC-0046
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:343 — the index comes directly from dequeueOutputBuffer
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:351 — getOutputBuffer is queried only for a nonnegative dequeued index
- **Decision:** For a valid non-secure audio encoder output index, Android supplies the buffer; the hypothesis does not provide a reachable state where it is null.
- **Recommendation:** No change required.

### R-120 · INFO · Detached engine cannot dispatch channel methods

- **Candidates:** CC-0017, CC-0018, CC-0019, CC-0020, CC-0024
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `kotlin-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:75 — detachment removes the method-call handler before clearing context at line 78
- **Decision:** Flutter method calls and engine detach are serialized on the platform thread; after the handler is removed no new initialize/isAvailable call reaches the force unwrap.
- **Recommendation:** No change required; a defensive null check would be optional hardening.

### R-121 · INFO · Deterministic MLX seed is correct for comparison harness

- **Candidates:** CC-2819, CC-2820
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tools/mlx-harness/Sources/harness/main.swift:15 — harness promises seeded comparable runs
  - tools/mlx-harness/Sources/harness/main.swift:98 — cold run seeds 42
  - tools/mlx-harness/Sources/harness/main.swift:104 — warm run resets the same seed to compare identical noise
- **Decision:** This is not security randomness, and “fresh seed” means resetting generator state for comparability, not selecting a different value.
- **Recommendation:** No change required; clarify the comment wording if desired.

### R-122 · INFO · Dialog-local controllers are collectible after pop

- **Candidates:** CC-1401, CC-1402
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/cast_manager/cast_manager_screen.dart:666 — controllers are local to _assignRole
  - lib/features/cast_manager/cast_manager_screen.dart:674 — the dialog route is their only live owner
  - lib/features/cast_manager/cast_manager_screen.dart:795 — the dialog is popped after submission
- **Decision:** The controllers are not retained by the screen or a long-lived collection; after the dialog route is removed they are garbage-collectable. Missing explicit dispose is hygiene, not the claimed app-lifetime accumulation.
- **Recommendation:** Optionally own/dispose them in a small stateful dialog widget.

### R-123 · INFO · Different duration formats serve different screens

- **Candidates:** CC-1600
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_history_screen.dart:267-272 — history renders descriptive durations.
- **Decision:** A compact browser display need not be identical.
- **Recommendation:** No change.

### R-124 · INFO · Digest formatting cost is negligible

- **Candidates:** CC-0387
- **Provenance:** `ios-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroMLXService.swift:322-331 — formatting occurs once per synthesis/cache lookup after SHA-256
- **Decision:** The candidate itself describes a bounded micro-cost dwarfed by synthesis and does not establish an observable failure.
- **Recommendation:** No change.

### R-125 · INFO · Disabled captcha is a hardening choice, not a source-proven bypass

- **Candidates:** CC-2396, CC-2397
- **Provenance:** `docker-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/config.toml:189 — signups/sign-ins are rate limited
  - supabase/config.toml:192 — token verification is rate limited
  - supabase/config.toml:197 — captcha is optional and commented out
- **Decision:** The candidates establish reduced bot resistance but no current functional or authorization failure. Captcha is not mandatory for a secure auth service.
- **Recommendation:** Enable Turnstile/hCaptcha if abuse telemetry warrants it.

### R-126 · INFO · Disabled MFA is an explicit plan-tier/product choice

- **Candidates:** CC-2415
- **Provenance:** `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/config.toml:293 — notes MFA availability on the Pro plan
  - supabase/config.toml:300 — TOTP enrollment is disabled
  - supabase/config.toml:305 — phone MFA is disabled
- **Decision:** Absence of an optional MFA feature is not itself a defect, and no requirement or bypass of an advertised MFA flow exists.
- **Recommendation:** Reassess MFA as an account-security product feature.

### R-127 · INFO · Dismissed color candidate asserts no defect

- **Candidates:** CC-1866
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_import/script_import_screen.dart:520-533 — dialogue currently uses a hash-derived color
- **Decision:** This candidate itself dismisses the cosmetic inconsistency; duplicate non-dismissed candidates cover the actual UI mismatch.
- **Recommendation:** No change.

### R-128 · INFO · Display versus print render mode does not offset returned rectangles

- **Candidates:** CC-0125
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:185-195 — viewer OCR derives text and normalized rectangles from the same rendered bitmap
- **Decision:** The highlight is matched and normalized against the on-demand page OCR result itself; using a different render mode than import does not introduce the claimed coordinate offset.
- **Recommendation:** No change.

### R-129 · INFO · Disposed context is checked before MediaQuery lookup

- **Candidates:** CC-1832
- **Provenance:** `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_import/pdf_page_view.dart:173 — returns when generation is stale or State unmounted
  - lib/features/script_import/pdf_page_view.dart:187 — MediaQuery lookup occurs only after that guard
- **Decision:** The candidate overlooks the mounted/staleness check already executed before context access.
- **Recommendation:** No change.

### R-130 · INFO · Distinct user-ID assertion is not tautological to the model

- **Candidates:** CC-2544
- **Provenance:** `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - test/cast_member_test.dart:239 — constructs the understudy independently
  - test/cast_member_test.dart:251 — checks the two stored userId fields differ
- **Decision:** The values are simple literals, but the assertion would fail if the model constructor/storage incorrectly coerced them. It is weak but not incapable of detecting the stated model bug.
- **Recommendation:** Optionally replace with a more behavior-focused assignment test.

### R-131 · INFO · Dormant cache creates no directories in current execution

- **Candidates:** CC-1292
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/voice_clone_service.dart:1-3,112-126 — generateLine has no callers and no backend
  - lib/data/services/voice_clone_service.dart:144-152 — directory creation is therefore unreachable
- **Decision:** No current run leaks the alleged empty directories.
- **Recommendation:** Move creation to the eventual write site when implementing generation.

### R-132 · INFO · Dormant in-memory profile behavior has no current runtime trigger

- **Candidates:** CC-1279, CC-1280, CC-1281, CC-1282, CC-1283
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/voice_clone_service.dart:1-3 — current repository has no call sites
  - lib/data/services/voice_clone_service.dart:71-80,88-109 — profile storage is in-memory but reachable only through the dormant service
- **Decision:** Persistence and eviction would matter only after a voice-clone feature defines its lifecycle; no current user can create these profiles.
- **Recommendation:** Design persistence and production scoping when the feature is implemented, not in dead code.

### R-133 · INFO · Dormant profiles cannot currently retain purgeable paths

- **Candidates:** CC-1288
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/voice_clone_service.dart:1-3,71-109 — no caller populates profiles in the current application
- **Decision:** The hypothetical dangling-cache behavior requires a future caller and unspecified temporary input paths.
- **Recommendation:** Define owned storage when implementing the feature.

### R-134 · INFO · Dormant sequential file probes are unreachable

- **Candidates:** CC-1284, CC-1285, CC-1286, CC-1287
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/voice_clone_service.dart:1-3 — service has no current callers
  - lib/data/services/voice_clone_service.dart:88-98 — the sequential exists checks are confined to the dormant profile builder
- **Decision:** No current user-facing path invokes these stats, and tens of local file probes are not a demonstrated failure.
- **Recommendation:** Batch or bound probes when real callers and performance requirements exist.

### R-135 · INFO · Dormant voice cache cannot currently serve stale generated speech

- **Candidates:** CC-1289
- **Provenance:** `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/voice_clone_service.dart:1-3,73-85 — no backend or callers are active
  - lib/data/services/voice_clone_service.dart:112-126 — cache lookup exists but no current path generates entries
- **Decision:** The stale key design is latent and has no producer or consumer in the shipped app.
- **Recommendation:** Include text/profile version hashes when a generation backend is implemented.

### R-136 · INFO · Dormant voice-cache synchronous I/O has no current cadence

- **Candidates:** CC-1291, CC-1293, CC-1297, CC-1298, CC-1302
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/voice_clone_service.dart:1-3 — current call frequency is zero
  - lib/data/services/voice_clone_service.dart:134-152 — synchronous directory checks sit only in unreferenced methods
- **Decision:** Per-line UI jank is hypothetical until a backend and playback caller exist.
- **Recommendation:** Cache the documents directory and use async filesystem calls as part of implementation.

### R-137 · INFO · Dormant voice-cache traversal has no current attacker-controlled caller

- **Candidates:** CC-1290, CC-1294, CC-1295, CC-1296, CC-1299, CC-1300, CC-1301
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/voice_clone_service.dart:1-3 — the service is unreferenced
  - lib/data/services/voice_clone_service.dart:134-152 — unsafe path joins exist only behind the dormant API
- **Decision:** The path construction is unsafe for untrusted future inputs, but there is no current call path—trusted or untrusted—to read/delete through it.
- **Recommendation:** Validate path components before exposing this API in a feature.

### R-138 · INFO · double.clamp assignment is type-correct

- **Candidates:** CC-1263
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/tts_service.dart:844-850 — receiver rate/0.5 is double and double.clamp returns double in the Dart SDK override
- **Decision:** The claimed static type error does not exist in current Dart.
- **Recommendation:** No change.

### R-139 · INFO · Download listener is correctly removed

- **Candidates:** CC-1957, CC-1969
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/model_download_screen.dart:31 — listener is registered
  - lib/features/settings/model_download_screen.dart:37 — listener is removed in dispose
  - lib/features/settings/model_download_screen.dart:61 — download has try/catch/finally
- **Decision:** These candidates explicitly describe correct behavior.
- **Recommendation:** No change required.

### R-140 · INFO · Download progress notifications are already coalesced

- **Candidates:** CC-1960, CC-1961, CC-1962, CC-1963
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/model_download_service.dart:620 — HTTP progress notifies only after roughly 1 MB
  - ios/Runner/BackgroundDownloadPlugin.swift:246 — native iOS bridge also throttles by 1 percent/0.3 seconds
- **Decision:** The two screen update paths do not both fire for the same Manager archive event, and service updates are bounded to coarse progress increments rather than every socket chunk.
- **Recommendation:** No change required unless profiling shows remaining jank.

### R-141 · INFO · Download-all serialization is not a demonstrated defect

- **Candidates:** CC-0888
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/model_download_service.dart:668-674 — downloadAll intentionally awaits registry entries sequentially
  - lib/data/services/model_download_service.dart:448-460 — latency-sensitive live-ASR group already downloads concurrently
- **Decision:** The candidate establishes only a possible speedup in a rarely used aggregate action, not incorrect behavior or a realistic threshold failure.
- **Recommendation:** No change.

### R-142 · INFO · Downloaded MLX model already has pinned digest verification

- **Candidates:** CC-0478
- **Provenance:** `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/model_download_service.dart:121 — the Kokoro model has a pinned SHA-256
  - lib/data/services/model_download_service.dart:402 — download completion computes the file digest
  - lib/data/services/model_download_service.dart:408 — a mismatch is rejected
- **Decision:** The loader itself does not hash, but the current download/install pipeline verifies the immutable artifact before use.
- **Recommendation:** No change.

### R-143 · INFO · Downloaded recordings carry their concrete cache path

- **Candidates:** CC-1585
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/recording_studio/recordings_browser_screen.dart:604 — resolver first checks recording.localPath directly
  - lib/features/recording_studio/recordings_browser_screen.dart:612 — directory memo is only a fallback for stale paths
  - lib/features/recording_studio/recordings_browser_screen.dart:631 — cached listing serves that fallback
- **Decision:** A newly synced Recording is loaded with its newly downloaded local path, which succeeds before the memoized fallback listing; the claimed invisibility path is not current.
- **Recommendation:** No change.

### R-144 · INFO · Downloader duplication is maintainability commentary

- **Candidates:** CC-0911, CC-0917
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/model_manager.dart:274 — ModelManager has a specialized bz2 downloader
  - lib/data/services/model_download_service.dart:579 — individual model downloads use a separate implementation
- **Decision:** Duplication alone is not a current failure and the paths have distinct progress/model contracts.
- **Recommendation:** No change required.

### R-145 · INFO · Downloader session lifetime matches app-lifetime plugin ownership

- **Candidates:** CC-2077, CC-2078
- **Provenance:** `ios-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - macos/Runner/MainFlutterWindow.swift:8 — window strongly owns the plugin
  - macos/Runner/MainFlutterWindow.swift:13 — constructs it once during window setup
  - macos/Runner/BackgroundDownloadPlugin.swift:25 — session retains its app-lifetime delegate
- **Decision:** The plugin is intentionally process/window-lived; no teardown/recreation caller is present, so the retain relationship does not accumulate instances.
- **Recommendation:** Add explicit invalidation only if engine/window recreation becomes supported.

### R-146 · INFO · Drawer production unwrap is dominated by build guard

- **Candidates:** CC-1514
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/production_hub/production_hub_screen.dart:168 — build returns immediately when production is null
  - lib/features/production_hub/production_hub_screen.dart:178 — _buildDrawer is reached only after that guard
  - lib/features/production_hub/production_hub_screen.dart:586 — force unwrap therefore receives the guarded non-null state
- **Decision:** Sign-out/leave triggers a rebuild that exits before rebuilding the drawer; there is no current call to _buildDrawer with a null production.
- **Recommendation:** Optional nullable hardening only.

### R-147 · INFO · Duplicate cache-to-model construction has not diverged

- **Candidates:** CC-0977
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/recording_sync_service.dart:529-575 — both conversion paths populate the same Recording fields.
- **Decision:** This is refactoring advice and no current inconsistent result is shown.
- **Recommendation:** No defect fix required.

### R-148 · INFO · Duplicate live-test bootstrap is maintenance-only

- **Candidates:** CC-2604
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - test/supabase_join_test.dart:14 — opt-in gate is local to this live suite
  - test/supabase_join_test.dart:23 — this suite intentionally declares its endpoint
- **Decision:** Copying a small opt-in bootstrap does not establish a current functional or security failure.
- **Recommendation:** Share it only if the live suites continue to be maintained together.

### R-149 · INFO · Duplicate locale migration is harmless

- **Candidates:** CC-2451
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/migrations/20260319100001_add_locale.sql:2 — migration uses ADD COLUMN IF NOT EXISTS
  - supabase/migrations/20260319100000_add_voice_preset.sql:8 — the same locale/default was already established
- **Decision:** The later statement is an intentional no-op under current schema and causes no runtime or migration failure.
- **Recommendation:** Leave historical migration immutable; avoid adding another source of truth.

### R-150 · INFO · Duplicate PDF-channel claim is unreachable

- **Candidates:** CC-2154
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/pdf_text_channel.dart:15 — extractText is present but unused
  - lib/data/services/script_import_service.dart:99 — current import uses extractTextPerPage
  - lib/data/services/pdf_text_channel.dart:45 — the called method catches MissingPluginException
- **Decision:** The alleged OCR-fallback crash names methods not used by the current import flow.
- **Recommendation:** No change.

### R-151 · INFO · Duplicate prune scheduling is benign

- **Candidates:** CC-0395
- **Provenance:** `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroMLXService.swift:336-367 — the unsynchronized flag can schedule duplicate utility work, but each pass only removes cache files toward the same low-water mark
- **Decision:** A data race on the Bool is undesirable, but the candidate identifies only duplicate best-effort cleanup, not a realistic application failure.
- **Recommendation:** No change.

### R-152 · INFO · Duplicated capture-start code is not itself a current failure

- **Candidates:** CC-1644
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:2894 — Android has platform-specific combined capture/PCM setup
  - lib/features/rehearsal/rehearsal_screen.dart:3032 — non-Android has a different recorder startup path
- **Decision:** The platform paths have materially different microphone/ASR responsibilities; duplication alone does not prove a current bug.
- **Recommendation:** Share only truly common file preparation after fixing concrete divergence.

### R-153 · INFO · Duplicated contact queries are maintenance-only

- **Candidates:** CC-0085
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:103 — phone query has its own permission-degradation block
  - android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:116 — email query intentionally repeats the independently caught operation
- **Decision:** The duplication does not itself produce a current observable failure; the actual permission failure is classified separately.
- **Recommendation:** Optional refactor only after fixing the permission contract.

### R-154 · INFO · Duplicated crash formatting has no current divergence

- **Candidates:** CC-2291
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/pull-crashlog.sh:89-125 — two frame collections intentionally use the same local formatting
- **Decision:** This is maintainability duplication without a current behavioral failure.
- **Recommendation:** No change.

### R-155 · INFO · Duplicated demo setup is not a demonstrated failure

- **Candidates:** CC-0245
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/screenshot_test.dart:49 — screenshot driver has its own main entry point
  - integration_test/screenshot_test.dart:76 — provider overrides are local to this harness
- **Decision:** Duplication alone does not prove the two independently run integration drivers have diverged or failed.
- **Recommendation:** Refactor only if the harnesses actually need a shared contract.

### R-156 · INFO · Duplicated invite wording is not a current behavioral failure

- **Candidates:** CC-1385, CC-1386
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:424 — deep links use the shared PendingJoin builder
  - lib/features/cast_manager/bulk_cast_setup_screen.dart:429 — this screen builds its own presentation text
- **Decision:** Copy-pasted wording is maintenance debt, but the current link and code are valid and no present divergence demonstrates broken invitations.
- **Recommendation:** Consolidate only during invite-flow cleanup.

### R-157 · INFO · Duplicated Linux title literal is not a current defect

- **Candidates:** CC-2064
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - linux/runner/my_application.cc:48 — header-bar title is castcircle
  - linux/runner/my_application.cc:52 — fallback window title is the same castcircle literal
- **Decision:** Both branches currently display the same correct title; the candidate predicts only a future rename oversight.
- **Recommendation:** No change.

### R-158 · INFO · Duplicated OCR stepper UI is maintenance debt only

- **Candidates:** CC-1799
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_import/ocr_review_screen.dart:379 — the modal sheet has its navigation rail
  - lib/features/script_import/ocr_review_screen.dart:700 — wide layout has a separate responsive rail
- **Decision:** Different responsive interactions are not themselves a current failure; the candidate predicts future divergence rather than demonstrating incorrect behavior.
- **Recommendation:** No current change.

### R-159 · INFO · Duplicated phoneme constants do not currently diverge

- **Candidates:** CC-0526
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/EnglishG2P.swift:24-29 — local vowel/stress constants are visible
  - ios/Runner/MisakiVendored/English/EnglishG2P.swift:114-120 — active stress logic uses Lexicon.primaryStress
- **Decision:** Duplication is a maintainability preference; the candidate provides no differing current values or reachable incorrect pronunciation.
- **Recommendation:** Consolidate constants opportunistically, not as a bug fix.

### R-160 · INFO · Duplicated production activation is maintainability-only

- **Candidates:** CC-1454
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/home/home_screen.dart:209 — rehearsal open performs activation plus script load
  - lib/features/home/home_screen.dart:369 — setup open intentionally activates then navigates directly to import
- **Decision:** The flows have different behavior and no current divergence-induced failure is shown.
- **Recommendation:** No change required.

### R-161 · INFO · Duplicated sample-write blocks are maintainability-only

- **Candidates:** CC-2821, CC-2822
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tools/mlx-harness/Sources/harness/main.swift:109 — cold samples are encoded
  - tools/mlx-harness/Sources/harness/main.swift:113 — warm samples repeat the same two-line operation
- **Decision:** The copies are currently identical and produce the intended two outputs; no behavior failure is present.
- **Recommendation:** Optional: extract a helper when changing the format.

### R-162 · INFO · Duplicated test helpers have not diverged into a failure

- **Candidates:** CC-0176, CC-0187, CC-0188, CC-0191, CC-0208, CC-0209
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `testing-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/android_live_matching_test.dart:99-114 — this harness has a concrete settle implementation
  - integration_test/asr_streaming_macos_test.dart:83-104 — this test owns a concrete match-rate implementation
- **Decision:** Code duplication is maintainability debt, not a currently triggered behavioral failure under the verification contract.
- **Recommendation:** No change.

### R-163 · INFO · Duplicated timing expressions are maintenance-only

- **Candidates:** CC-1631, CC-1632
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:2412 — one plausibility calculation exists
  - lib/features/rehearsal/rehearsal_screen.dart:2492 — a second path has a similar calculation
- **Decision:** The candidates identify possible future divergence, not a current behavioral disagreement.
- **Recommendation:** Optional extraction when timing rules next change.

### R-164 · INFO · Duration encoder is intentionally batch-one

- **Candidates:** CC-0442, CC-0443, CC-0444, CC-0445, CC-0446, CC-0447
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroVendored/TTSEngine/DurationEncoder.swift:120-139 — the LSTM path explicitly extracts and reconstructs one batch
  - ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:303-311 — voice/style extraction is a single-example slice used by the current synthesis pipeline
- **Decision:** Current synthesis always supplies one example and comments require preserving the verified graph shape; batch>1 is unreachable, while one candidate explicitly asserts no action.
- **Recommendation:** No change.

### R-165 · INFO · Duration updates are already isolated

- **Candidates:** CC-1555
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/recording_studio/recording_studio_screen.dart:49-54,629-634 — timer updates only a ValueNotifier.
- **Decision:** The candidate confirms no full-screen rebuild.
- **Recommendation:** No change.

### R-166 · INFO · Eager preview children are bounded in current scripts

- **Candidates:** CC-1846, CC-1847, CC-1849
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_import/script_import_screen.dart:227-273 — line previews are capped at 30 and character tiles reflect the finite parsed cast
- **Decision:** The review’s own companion candidates characterize normal casts as dozens; no realistic frame/memory threshold is demonstrated.
- **Recommendation:** No change.

### R-167 · INFO · Editor file stats are bounded per interaction

- **Candidates:** CC-1728, CC-1729, CC-1730, CC-1743, CC-1744
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:93-95,451-453,826-831 — local existsSync checks are constant-count.
- **Decision:** No growing loop or measured frame failure exists.
- **Recommendation:** No current defect fix required.

### R-168 · INFO · Empty expected speech intentionally means nothing must be spoken

- **Candidates:** CC-2673, CC-2674, CC-2675, CC-2676, CC-2677
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `testing-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/stt_service.dart:315 — removes nonspoken stage directions from expected text
  - lib/data/services/stt_service.dart:317 — returns perfect when no dialogue words remain
  - lib/features/rehearsal/rehearsal_screen.dart:2337 — passes a parsed current line, not a missing nullable reference
- **Decision:** The behavior supports stage-direction-only/no-dialogue cues; current callers do not use an absent expected line as an authorization or security decision.
- **Recommendation:** Rename the test to document no-dialogue semantics if clarity is needed.

### R-169 · INFO · Empty expected text is intentionally non-spoken

- **Candidates:** CC-2603
- **Provenance:** `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/stt_service.dart:312 — stage directions are removed from expected text
  - lib/data/services/stt_service.dart:317 — no remaining dialogue returns a perfect score deliberately
- **Decision:** Rehearsal dialogue lines are nonempty; the branch treats direction-only/non-spoken content as requiring no actor words rather than accepting arbitrary normal dialogue.
- **Recommendation:** No change required unless product semantics for blank lines change.

### R-170 · INFO · Empty FlutterPlugin register method is bypassed intentionally

- **Candidates:** CC-0352
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/ContactPickerPlugin.swift:19 — explicitly documents AppDelegate registration
  - ios/Runner/ContactPickerPlugin.swift:10 — initializer installs the channel handler
- **Decision:** The current app constructs the plugin through its messenger initializer; no caller uses the conventional static registrar entry point.
- **Recommendation:** Delete the unused conformance method if desired, but it does not break current registration.

### R-171 · INFO · Empty join codes have no current writer

- **Candidates:** CC-1409, CC-1410, CC-1411
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260315_cast_join_code.sql:14 — cloud join_code is NOT NULL
  - supabase/migrations/20260316_join_code_default.sql:3 — cloud creation defaults to generate_join_code
  - lib/features/cast_manager/cast_manager_screen.dart:870 — the share path reads the production model value
- **Decision:** The current cloud/local creation paths generate a non-empty code; the candidate requires a hypothetical restored malformed empty string not produced by current code.
- **Recommendation:** Retain isNotEmpty hardening if legacy data is later demonstrated.

### R-172 · INFO · Empty male pool is absent from current presets

- **Candidates:** CC-1321, CC-1322
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/models/voice_preset.dart:55-144 — every shipped preset defines male and female pools.
- **Decision:** The trigger requires a custom preset current code cannot construct.
- **Recommendation:** No defect fix required.

### R-173 · INFO · Empty scorer transcript is represented by one empty token

- **Candidates:** CC-0210
- **Provenance:** `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/asr_streaming_macos_test.dart:86-94 — words("") yields a one-element empty-string list and b.first is safely checked
- **Decision:** Dart String.split returns [""] for the normalized empty string here, so b.first does not throw and the function returns zero.
- **Recommendation:** No change.

### R-174 · INFO · Empty token arrays are an explicit valid return shape

- **Candidates:** CC-0553
- **Provenance:** `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/EnglishG2P.swift:405-413 — the public tuple consistently returns a token array
  - ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:186-190 — the caller detects empty tokenized input and throws invalidInput
- **Decision:** An empty array already distinguishes no tokens; making the array optional would add a redundant state and no current failure.
- **Recommendation:** No change required.

### R-175 · INFO · Empty transcripts do not make the word list empty

- **Candidates:** CC-0218, CC-0219
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/kokoro_pack_smoke_macos_test.dart:30 — words trims before splitting
  - integration_test/kokoro_pack_smoke_macos_test.dart:36 — b.first is checked for an empty string
- **Decision:** In Dart, splitting the trimmed empty string yields a one-element list containing the empty string, so b.first is valid and the guard returns zero.
- **Recommendation:** No change.

### R-176 · INFO · Empty-tensor debug-print crash has no current callsite

- **Candidates:** CC-0651, CC-0652, CC-0653, CC-0654, CC-0655
- **Provenance:** `ios-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MisakiVendored/Extensions/MLXArray+DebugPrint.swift:44 — an empty [0,N] tensor would be treated as one row
  - ios/Runner/MisakiVendored/Extensions/MLXArray+DebugPrint.swift:63 — that hypothetical call would slice an empty array
  - ios/Runner/MisakiVendored/Extensions/MLXArray+DebugPrint.swift:13 — the helper is never invoked by current repository code
- **Decision:** The helper contains the described edge case, but no current application or test path calls it; triggering it requires adding new code.
- **Recommendation:** Guard flat.isEmpty if the helper gains a caller.

### R-177 · INFO · End-flush partials are intentionally stale after line advancement

- **Candidates:** CC-0847
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:2956-2971 — a line advances only after its match threshold and silence requirement are already satisfied
  - lib/features/rehearsal/rehearsal_screen.dart:3078-3083 — comments explicitly state post-transition flush words are harmlessly dropped
- **Decision:** The scorer has already accepted the line before capture stops; delivering late line-N text after state moves to line N+1 would be the bug the UID guard prevents.
- **Recommendation:** No change required.

### R-178 · INFO · English STT fallback matches the app’s supported script locales

- **Candidates:** CC-1606, CC-1607
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:377 — an English device preserves its locale
  - lib/features/rehearsal/rehearsal_screen.dart:380 — other devices use en-US
  - lib/features/cast_manager/voice_config_screen.dart:402 — supported production locale labels are en-US and en-GB only
- **Decision:** The current product exposes only English dialects; using a French/German recognizer for an English script would be worse. The candidate assumes unsupported non-English scripts.
- **Recommendation:** Expand locale selection together with actual non-English script/STT support, not independently.

### R-179 · INFO · eSpeak unsupported-language residue is not reachable through the TTS caller

- **Candidates:** CC-0504, CC-0505, CC-0506, CC-0507, CC-0508
- **Provenance:** `ios-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroVendored/TextProcessing/eSpeakNGG2PProcessor.swift:21-38 — unsupported languages throw and process is internal to the processor
  - ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:171-182 — generation propagates setLanguage failure before process is called
  - ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:237-255 — the only production path never catches a failed setLanguage and continues processing
- **Decision:** Language.none is a sentinel, not a documented request for an engine default, and the sole current caller cannot continue into process after setLanguage throws. The half-configured internal state therefore has no realistic current trigger.
- **Recommendation:** No change required for current callers; constructing into a local would still strengthen the type invariant.

### R-180 · INFO · Example.com purge targets documented audit accounts

- **Candidates:** CC-2460, CC-2461, CC-2462
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260703090000_leave_policy_and_audit_cleanup.sql:10 — migration documents one-time audit-tool cleanup
  - supabase/migrations/20260703090000_leave_policy_and_audit_cleanup.sql:15 — repository asserts no real user has that reserved-domain address
  - supabase/migrations/20260703090000_leave_policy_and_audit_cleanup.sql:16 — cast references are removed before auth users
- **Decision:** The claimed production-owning/test-environment victims are hypothetical and contradict the documented population created by the audit tooling; no current row evidence proves an FK abort.
- **Recommendation:** Keep one-time data cleanup reviewed separately from reusable schema migrations.

### R-181 · INFO · Explicit crash-test menu is intentional debug tooling

- **Candidates:** CC-0147
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/debug_log_screen.dart:159 — action is explicitly named test_fatal
  - lib/features/settings/debug_log_screen.dart:166 — native crash requires selecting test_native_crash
  - lib/features/settings/debug_log_screen.dart:183 — menu labels the action Test Fatal Exception
  - lib/features/settings/debug_log_screen.dart:186 — menu labels the native action Test Native Crash (SIGABRT)
- **Decision:** The actions are explicit, deliberate diagnostics; the finding does not establish a crash loop or state corruption, and an async Dart test exception is not itself proof of process termination.
- **Recommendation:** No change for this candidate; product may separately decide whether shipped diagnostic routes should be hidden.

### R-182 · INFO · Export helper edge cases are unreachable with normalized inputs

- **Candidates:** CC-1012, CC-1013, CC-1014
- **Provenance:** `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/script_export.dart:223 — _truncate is called with the constant 80
  - lib/data/services/script_export.dart:255 — _lastWords is called with the constant 8
  - lib/data/services/script_export.dart:280 — helper inputs come from persisted parsed dialogue text
- **Decision:** The truncate crash requires a max below three that no caller supplies; parsed/editor dialogue is trimmed, so the trailing/leading-space-only cases have no current realistic trigger.
- **Recommendation:** Harden helpers if they become public or accept variable limits.

### R-183 · INFO · Extended test tag configuration matches documented commands

- **Candidates:** CC-0144, CC-0145, CC-0146
- **Provenance:** `docker-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `testing-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - dart_test.yaml:2 — the documented default command explicitly excludes extended
  - dart_test.yaml:3 — bare flutter test is explicitly documented as the full suite
- **Decision:** An empty tag options map is valid and the file does not claim bare flutter test excludes the tag.
- **Recommendation:** No change required.

### R-184 · INFO · Extraction stream handles do not produce the claimed mobile failure

- **Candidates:** CC-0908
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/model_manager.dart:249 — streams are closed only after successful bzip decode
  - lib/data/services/model_manager.dart:261 — isolate cleanup always removes the temporary directory
- **Decision:** The cited Windows locked-file consequence is outside the mobile paths using this model manager, and isolate termination releases handles after an exception.
- **Recommendation:** Optional: close streams in nested finally blocks for hygiene.

### R-185 · INFO · Extreme duration allocation is blocked by application speed ranges

- **Candidates:** CC-0473
- **Provenance:** `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:171-176 — native input rejects nonfinite and extreme speed; app playback controls supply ordinary bounded values.
- **Decision:** The candidate relies on an artificial near-floor speed not reachable from current settings.
- **Recommendation:** No change.

### R-186 · INFO · Fallback literal duplication has not drifted

- **Candidates:** CC-1326
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/voice_config_service.dart:368-375 — current fallback remains af_heart.
- **Decision:** No present behavioral mismatch exists.
- **Recommendation:** No defect fix required.

### R-187 · INFO · Fallback vocab already includes reserved token slots

- **Candidates:** CC-0585
- **Provenance:** `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/MisakiVendored/Resources/us_bart_config.json:23 — grapheme_chars begins with four reserved underscores
  - ios/Runner/MisakiVendored/Resources/us_bart_config.json:40 — phoneme_chars likewise begins with four reserved underscores
  - ios/Runner/MisakiVendored/English/FallbackNetwork/EnglishFallbackNetwork.swift:33 — enumerated indices therefore already include the 0–3 offset
- **Decision:** Adding four again would misindex the trained vocabulary; the language/API claim is false for the shipped config.
- **Recommendation:** No change.

### R-188 · INFO · Firebase client config and navigation analytics are expected bounded behavior

- **Candidates:** CC-0730, CC-0731
- **Provenance:** `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/app.dart:284-331 — analytics performs one map lookup and one screen-view event per PageRoute transition
  - lib/firebase_options.dart:25-67 — Firebase options are public client configuration
- **Decision:** Public Firebase client identifiers are not secrets, and route logging is bounded by user navigation rather than an unbounded hot path.
- **Recommendation:** No change required.

### R-189 · INFO · Firebase mobile API keys are public client identifiers

- **Candidates:** CC-1997, CC-1998, CC-1999, CC-2000, CC-2001, CC-2002, CC-2003, CC-2004, CC-2005, CC-2006, CC-2007, CC-2008
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `db-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `db-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/firebase_options.dart:53 — generated iOS client API key is embedded
  - lib/firebase_options.dart:62 — generated Android client API key is embedded
- **Decision:** Firebase client configuration must ship in the app and is not a server credential. Console restrictions/App Check are external hardening, not evidence of a repository failure.
- **Recommendation:** No source change; maintain Firebase rules and app restrictions in the console.

### R-190 · INFO · Fixed white spinner is correct in the locked dark theme

- **Candidates:** CC-1850
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/app.dart:275-278 — the application is locked to ThemeMode.dark
- **Decision:** The candidate is expressly cosmetic and its light-theme premise is not active.
- **Recommendation:** No change.

### R-191 · INFO · Fixture guard duplication does not break current tests

- **Candidates:** CC-2581
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - test/sample_script_test.dart:19 — the current fixture exists check is explicit
  - sample-scripts/pg37431.txt:1 — the referenced fixture is present in the repository
- **Decision:** The observation is maintenance duplication; all current referenced fixtures exist and no test currently fails or silently disappears because of it.
- **Recommendation:** Optional test helper refactor.

### R-192 · INFO · Fixture path follows the supported Flutter test working directory

- **Candidates:** CC-2552
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - test/ocr_highlight_hitrate_test.dart:14 — the test reads a repository fixture by relative path
  - test/ocr_highlight_hitrate_test.dart:1 — it is a package Flutter test expected to run from the package root
- **Decision:** Running this package test from an unrelated CWD is not a supported invocation and would also break package/pubspec resolution; lack of a custom exists message is not a contract failure.
- **Recommendation:** No change.

### R-193 · INFO · Foreign-key-enabled save failure premise is false

- **Candidates:** CC-0743
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/database/app_database.dart:316-331 — foreign_keys is never enabled for the NativeDatabase connection
- **Decision:** The candidate assumes Drift enables SQLite foreign keys by default; this connection does not, so the claimed delete constraint failure does not occur.
- **Recommendation:** No change.

### R-194 · INFO · Formatter side effect is contained by the current setState caller

- **Candidates:** CC-1337
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/auth/auth_screen.dart:360 — the sole caller invokes _friendlyAuthError inside setState
  - lib/features/auth/auth_screen.dart:375 — confirmation state is mutated during that same state update
- **Decision:** The design is impure but current UI state is rebuilt correctly; the candidate relies on a hypothetical future caller.
- **Recommendation:** No current correctness change.

### R-195 · INFO · Foundation bridges file size to Int successfully

- **Candidates:** CC-2344
- **Provenance:** `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/test_silence_trim.swift:155 — attributes[.size] is conditionally cast to Int
  - scripts/test_silence_trim.swift:156 — output size uses the same bridge
- **Decision:** On the repository macOS runtime a targeted Swift evaluation of this exact attributes expression returned the real nonzero file size; NSNumber-to-Int bridging works here.
- **Recommendation:** No change.

### R-196 · INFO · Fresh orphan-sweep account cannot enumerate productions under current RLS

- **Candidates:** CC-2719, CC-2720, CC-2721, CC-2722, CC-2723, CC-2724, CC-2725, CC-2728, CC-2729, CC-2730, CC-2731, CC-2732, CC-2733, CC-2734, CC-2735, CC-2736, CC-2737
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tool/orphan_sweep.dart:22 — tool creates a fresh throwaway account
  - tool/orphan_sweep.dart:30 — it queries productions before joining any production
  - supabase/migrations/20260314140000_fix_rls_recursion.sql:38 — production SELECT is membership-scoped
  - supabase/migrations/20260703160000_drop_last_productions_readall.sql:10 — last permissive read-all policy is dropped
  - tool/orphan_sweep.dart:37 — every pagination/loop/reporting issue is downstream of a nonempty production list
- **Decision:** The current tool sees no productions for its new nonmember account, so the alleged large sweep, serial per-production work, swallowed join errors, and nullable orphan formatting paths are unreachable. The tool is obsolete rather than failing in the claimed ways.
- **Recommendation:** Retire it or redesign an admin audit with explicitly privileged credentials and pagination; do not weaken RLS.

### R-197 · INFO · Full-context character export is distinct from cue export

- **Candidates:** CC-1007, CC-1008
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/script_export.dart:185 — toCharacterLines is documented as a personal-study export
  - lib/data/services/script_export.dart:220 — it intentionally labels all other dialogue as context
  - lib/data/services/script_export.dart:233 — a separate toCueScript method provides just cue lines plus the actor lines
- **Decision:** The inline “line before yours” comment is inaccurate, but the public method’s full-context behavior is coherent and a separate cue-only format exists; no current functional failure is proven.
- **Recommendation:** Correct the misleading inline comment.

### R-198 · INFO · Full-corpus parsing is intentional coverage with no demonstrated timeout

- **Candidates:** CC-2597
- **Provenance:** `x86-simd-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - test/shakespeare_import_test.dart:694 — this section deliberately validates full-corpus imports
  - test/shakespeare_import_test.dart:701 — corpus text is loaded as a test fixture
  - test/shakespeare_import_test.dart:747 — another distinct work is parsed for behavior coverage
- **Decision:** Linear fixture parsing is the observable contract under test; growth from hypothetical future fixtures is not a current failure.
- **Recommendation:** No change absent measured suite regression.

### R-199 · INFO · Full-PDF OCR caller catches PlatformException and other failures

- **Candidates:** CC-0948
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/paddle_ocr_channel.dart:97 — ocrPdf is the full-document entry point
  - lib/data/services/script_import_service.dart:358 — caller enters a try before invoking it
  - lib/data/services/script_import_service.dart:360 — caller catches any error
- **Decision:** Even though ocrPdf itself only catches plugin absence, the only production caller catches native failures and follows its logged fallback path.
- **Recommendation:** No change.

### R-200 · INFO · G2P reconstruction is guarded by the selected language

- **Candidates:** CC-0489, CC-0490, CC-0491
- **Provenance:** `ios-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:239 — returns when chosenLanguage already matches
  - ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:245 — calls setLanguage only after that guard
- **Decision:** Current synthesis does not rebuild dictionaries and model weights per utterance; it rebuilds only on an actual language change.
- **Recommendation:** No change; cache both variants only if language-switch profiling justifies it.

### R-201 · INFO · GApplication argv and lifecycle code follow valid template invariants

- **Candidates:** CC-2066, CC-2067
- **Provenance:** `cpp-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - linux/runner/my_application.cc:82 — local_command_line receives GApplication's argv contract
  - linux/runner/my_application.cc:87 — it strips the mandatory executable entry
  - linux/runner/my_application.cc:103 — startup explicitly chains to the parent
  - linux/runner/my_application.cc:112 — shutdown explicitly chains to the parent
- **Decision:** GApplication supplies a null-terminated argv with argv[0]; the pass-through overrides are harmless template scaffolding and do not produce a failure.
- **Recommendation:** No change.

### R-202 · INFO · Generator batch-shape issue is unreachable in single-utterance synthesis

- **Candidates:** CC-0434
- **Provenance:** `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:275 — token IDs are explicitly expanded to a batch of one
  - ios/Runner/KokoroVendored/Decoder/Generator.swift:148 — the transpose yields the expected trailing singleton for batch one
- **Decision:** The only current synthesis entry constructs batch size one; the claimed corruption requires batch size greater than one.
- **Recommendation:** Fix the shape before adding batched synthesis.

### R-203 · INFO · Greedy cue stripping preserves the dialogue in the cited all-caps example

- **Candidates:** CC-0936
- **Provenance:** `gcp-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/ocr_highlight_matcher.dart:32 — the cue regex requires a period followed by whitespace
  - lib/data/services/ocr_highlight_matcher.dart:37 — stripping returns everything after the matched cue
  - lib/data/services/ocr_highlight_matcher.dart:40 — only an actually empty remainder restores the original
- **Decision:** For “MRS. BENNET. OH DEAR.” the final period is not followed by whitespace, so the match ends after BENNET and the remainder is OH DEAR, not DEAR. The concrete failure claim is false.
- **Recommendation:** No change for the cited case; add corpus cases before changing the measured greedy behavior.

### R-204 · INFO · Guest gate does not authorize cloud operations

- **Candidates:** CC-1340, CC-1344
- **Provenance:** `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/auth/auth_screen.dart:413 — guest mode is explicitly supported
  - lib/features/auth/auth_screen.dart:422 — authStateProvider is set only as UX state
  - lib/features/auth/auth_screen.dart:17 — repository search finds no reader of authStateProvider beyond auth writes/reset
  - lib/data/services/supabase_service.dart:72 — cloud authentication remains derived from the actual Supabase session
- **Decision:** No cloud callsite trusts authStateProvider for authorization, and server RLS still requires auth.uid(); guest mode cannot gain cloud access through this flag.
- **Recommendation:** No change.

### R-205 · INFO · Hardcoded developer fixture values are not a runtime defect

- **Candidates:** CC-2178, CC-2179
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/deploy.sh:9-10 — device and bundle defaults are operator-script values and device can be overridden.
- **Decision:** A stale default fails loudly at devicectl; no current stale target is shown.
- **Recommendation:** No defect fix required.

### R-206 · INFO · Hardcoded model size is cosmetic

- **Candidates:** CC-1956
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/model_download_screen.dart:120 — the size appears only as descriptive UI text
- **Decision:** No behavioral failure is claimed.
- **Recommendation:** Update copy when model packaging changes, otherwise no action.

### R-207 · INFO · Hardcoded production defaults are explicit operator-tool configuration

- **Candidates:** CC-2682
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tool/analyze_orphaned_recordings.dart:7-24 — usage accepts a production id and supplies a visible default
  - tool/sim_multi_user.dart:16,49-55 — the simulator separately documents staging-capable environment overrides
- **Decision:** The audit tool is expressly production-specific; no promise that every tool honors staging variables is shown. The security impact of the exposed default UUID is covered by the membership-policy finding.
- **Recommendation:** Require an argument if accidental production execution is a recurring operator problem.

### R-208 · INFO · Hardcoded vendor set is the current harness contract

- **Candidates:** CC-2830
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - tools/mlx-harness/link-sources.sh:4 — comment names exactly Kokoro and Misaki vendored trees
  - tools/mlx-harness/link-sources.sh:9 — loop matches those two existing trees
- **Decision:** A hypothetical third/renamed vendor is future scope; current sources are not omitted.
- **Recommendation:** Auto-discover only if adding another vendored tree.

### R-209 · INFO · Harness helper duplication has no demonstrated divergence

- **Candidates:** CC-0200
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/android_rehearsal_harness_test.dart:61-91 — the local WAV helper is test-only and the candidate identifies no current differing result.
- **Decision:** Copying test helpers is maintainability debt, not a verified current failure.
- **Recommendation:** No change.

### R-210 · INFO · Harness recount/reporting is cosmetic and current-scope accurate

- **Candidates:** CC-2838, CC-2839
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tools/mlx-harness/link-sources.sh:18 — one final find counts current harness symlinks
  - tools/mlx-harness/link-sources.sh:9 — current harness manages exactly the two present vendor groups
- **Decision:** The extra traversal is negligible, and the alleged future third symlink group does not exist; neither candidate proves a current failure.
- **Recommendation:** Optional local counter for cleaner reporting.

### R-211 · INFO · Harness tokenizer deliberately mirrors app fallback constants

- **Candidates:** CC-2799
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - tools/mlx-harness/Sources/harness/main.swift:46 — comment states tokenizer is replicated solely to avoid Bundle loading
  - ios/Runner/MisakiVendored/English/FallbackNetwork/EnglishFallbackNetwork.swift:6 — canonical implementation defines unknownTokenId as 3
- **Decision:** The duplicate is necessary for the standalone harness and currently matches the exact app semantics it verifies; no drift is present.
- **Recommendation:** Keep parity checks when changing the canonical tokenizer.

### R-212 · INFO · Highlight hit-rate diagnostic scan is bounded and test-only

- **Candidates:** CC-2553, CC-2554, CC-2555
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`, `x86-simd-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - test/ocr_highlight_hitrate_test.dart:14 — input is one fixed bundled fixture
  - test/ocr_highlight_hitrate_test.dart:50 — full-page fallback runs only for misses
  - test/ocr_highlight_hitrate_test.dart:84 — the bounded run ends in the hit-rate assertion
- **Decision:** The candidates explicitly report current runtime as sub-second/a few seconds and no production reachability or timeout.
- **Recommendation:** No change.

### R-213 · INFO · Highlight race does not overwrite another line in current callers

- **Candidates:** CC-1835
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_import/pdf_page_view.dart:236 — only the widget source page is eligible for highlight
  - lib/features/script_import/ocr_review_screen.dart:693 — a different selected line remounts the State
- **Decision:** Page-away lookups clear a highlight intentionally, while line changes get a new State. The described old-line result cannot land over a newer selected-line State.
- **Recommendation:** Add a locate generation if stable-key reuse is introduced.

### R-214 · INFO · Historical nonconcurrent index build is not a current runtime defect

- **Candidates:** CC-2494, CC-2497
- **Provenance:** `sql-migration-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260801130000_cast_members_rls_index.sql:10 — migration creates the index once
  - supabase/migrations/20260801130000_cast_members_rls_index.sql:11 — target is cast_members
- **Decision:** This dated migration is a one-time deployment operation already represented in the migration chain; the findings do not establish a current blocked deployment or table size that made the lock harmful.
- **Recommendation:** Use concurrent index procedures for future large live tables when migration tooling permits them.

### R-215 · INFO · Historical open RLS policies were closed by later migrations

- **Candidates:** CC-2438
- **Provenance:** `sql-migration-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/migrations/20260703140000_security_lockdown.sql:4-16 — lockdown documents and closes the historically reproduced exposures
  - supabase/migrations/20260703140000_security_lockdown.sql:90-126 — global production/cast policies are dropped and membership policies installed
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:1-18 — later join RPCs require codes and close remaining join-era gaps
- **Decision:** The candidate describes a historical live exposure, but the current final migration state contains explicit later fixes; current-source triage therefore refutes it.
- **Recommendation:** No change.

### R-216 · INFO · Historical purge contains fixed known IDs

- **Candidates:** CC-2463
- **Provenance:** `sql-migration-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/migrations/20260703100000_purge_test_productions.sql:1-55 — one-time migration deletes an enumerated set of test UUIDs.
- **Decision:** No wrong current UUID or repeatable broad delete is identified.
- **Recommendation:** No change to migration history.

### R-217 · INFO · Hub dropdown mapping is bounded ordinary build work

- **Candidates:** CC-1508
- **Provenance:** `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/production_hub/production_hub_screen.dart:198 — the dropdown is built from the current script character list
- **Decision:** The candidate explicitly declines to report a defect; ordinary mapping over a cast-sized list is bounded.
- **Recommendation:** No change.

### R-218 · INFO · Identity-hash collision is not a realistic cache failure

- **Candidates:** CC-1615
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:656 — cached line filtering uses an identity-derived key
- **Decision:** The candidate concedes negligible collision odds and supplies no reachable collision.
- **Recommendation:** No change; use object identity directly if the cache is later redesigned.

### R-219 · INFO · Image conversion awaits raster/native work

- **Candidates:** CC-1029, CC-1030, CC-1034
- **Provenance:** `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/script_import_service.dart:452-519 — render, createImage, toByteData, file write, and OCR are awaited.
- **Decision:** The pipeline is sequential, but the premise that PNG encoding synchronously blocks the Dart UI isolate is not established.
- **Recommendation:** No defect fix required.

### R-220 · INFO · Import fallback failures have aggregate field logging

- **Candidates:** CC-1026, CC-1031
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/script_import_service.dart:532-536 — failed OCR page count is written to DebugLogService.
- **Decision:** Per-page detail uses debugPrint, but the claimed complete absence of field evidence is false.
- **Recommendation:** No defect fix required.

### R-221 · INFO · Injected fallback is explicitly diagnostic behavior

- **Candidates:** CC-0205
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/android_rehearsal_harness_test.dart:259-290 — the harness labels acoustic versus injected mode before the final score.
- **Decision:** The candidate explicitly concludes the documented fallback is fine.
- **Recommendation:** No change.

### R-222 · INFO · Injected test decode has no realistic scaling trigger

- **Candidates:** CC-0207
- **Provenance:** `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/android_rehearsal_harness_test.dart:54-59,264-272 — only two fixed lines reach the synchronous decode branch.
- **Decision:** The proposed multi-sentence unbounded scenario is absent from the current harness input.
- **Recommendation:** No change.

### R-223 · INFO · Interpolate vector lengths are unreachable in the current 1D API

- **Candidates:** CC-0413
- **Provenance:** `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroVendored/BuildingBlocks/Interpolate.swift:32 — one factor is expanded to spatialDims
  - ios/Runner/KokoroVendored/BuildingBlocks/Interpolate.swift:43 — only the 1D case is implemented
  - ios/Runner/KokoroVendored/BuildingBlocks/Interpolate.swift:47 — every multi-dimensional call traps before interpolation
- **Decision:** Current callers use one-element factors for the only supported 1D path; no realistic current call supplies a mismatched multi-element vector.
- **Recommendation:** Add validation if multidimensional interpolation is introduced.

### R-224 · INFO · Invite-template duplication is maintenance-only

- **Candidates:** CC-1413
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/cast_manager/cast_manager_screen.dart:876 — the live invite template is explicit
- **Decision:** No current malformed template or inconsistent join URL is proven by duplication itself.
- **Recommendation:** Optional shared builder refactor.

### R-225 · INFO · Join code already has a unique index

- **Candidates:** CC-2513, CC-2514
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260315_cast_join_code.sql:6 — join_code is added with a UNIQUE constraint
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:73 — lookup equality can use that unique index
- **Decision:** The candidate overlooked the earlier unique constraint, which creates the required btree index.
- **Recommendation:** No additional index.

### R-226 · INFO · Join codes are already unique and collisions fail the migration

- **Candidates:** CC-2539
- **Provenance:** `sql-migration-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/migrations/20260315_cast_join_code.sql:6 — productions.join_code has a UNIQUE constraint
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:203 — reroll updates that constrained column
- **Decision:** A generator collision cannot silently create duplicate routing; the unique constraint aborts that row/transaction instead. The claimed cross-tenant wrong resolution is false.
- **Recommendation:** Optional collision retry improves migration robustness but uniqueness is enforced.

### R-227 · INFO · Join flow v3 requires a join code for every pre-membership RPC

- **Candidates:** CC-2482, CC-2483, CC-2484, CC-2485
- **Provenance:** `db-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `db-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:84 — the UUID-only fetch_cast_for_join signature is dropped
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:97 — roster fetch checks production id plus code
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:116 — the UUID-only join_production signature is dropped
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:133 — join validates the code
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:146 — UUID-only invitation claim is dropped
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:161 — claim validates the production code
- **Decision:** These findings describe superseded v2 functions; the final migration cleanly removes those signatures and requires the code.
- **Recommendation:** No change.

### R-228 · INFO · Join-code lookup is server-rate-limited in the latest migration

- **Candidates:** CC-1473
- **Provenance:** `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:54 — lookup is capped at 20 attempts per five minutes
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:70 — lookup RPC invokes the limiter
- **Decision:** The candidate omitted the later v3 migration that supplies the required server-side throttling.
- **Recommendation:** No change required.

### R-229 · INFO · Jump-back trigger control exposes all enum values

- **Candidates:** CC-1979
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/settings_screen.dart:33 — enum has four values
  - lib/features/settings/settings_screen.dart:147 — dropdown maps JumpBackTrigger.values
  - lib/features/settings/settings_screen.dart:148 — each value becomes an item
- **Decision:** The claim that the dropdown has one option is false in current source. Literal defaults alone do not cause a failure.
- **Recommendation:** No change.

### R-230 · INFO · Known Tempest case is explicitly disabled

- **Candidates:** CC-2563
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - test/parser_accuracy_test.dart:92-98 — skip has a concrete abbreviated-name fixture reason.
- **Decision:** An explicit skip is not silent coverage and no current fix is identified.
- **Recommendation:** Re-enable when support lands.

### R-231 · INFO · Kokoro benchmark model paths are internally consistent

- **Candidates:** CC-0162, CC-0163, CC-0164
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/android_kokoro_rtf_test.dart:29 — wait checks fp32/model.onnx
  - integration_test/android_kokoro_rtf_test.dart:30 — wait checks fp16/model.fp16.onnx
  - integration_test/android_kokoro_rtf_test.dart:39 — fp32 case uses model.onnx
  - integration_test/android_kokoro_rtf_test.dart:42 — fp16 case uses model.fp16.onnx
- **Decision:** The candidates themselves describe matching wait and configuration paths; there is no mismatch.
- **Recommendation:** No change.

### R-232 · INFO · Kokoro config is correctly copied into the app bundle

- **Candidates:** CC-0448, CC-0449, CC-0450, CC-0451, CC-0452, CC-0453, CC-0454
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-performance-review@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroVendored/TTSEngine/KokoroConfig.swift:165 — loader intentionally reads Bundle.main
  - ios/Runner.xcodeproj/project.pbxproj:75 — config.json has a Resources build-file entry
  - ios/Runner.xcodeproj/project.pbxproj:665 — config.json is in the Runner Resources phase
  - ios/Runner/KokoroVendored/Resources/config.json:1 — the resource exists in the repository
- **Decision:** This code is vendored directly into Runner rather than consumed as an SPM/framework module, and Xcode copies config.json into Bundle.main. The proposed module-bundle failure path is absent.
- **Recommendation:** No bundle change; forced decoding can remain fail-fast for an invariant build resource.

### R-233 · INFO · Kokoro language mutation is serialized by its service

- **Candidates:** CC-0465, CC-0467, CC-0468
- **Provenance:** `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroMLXService.swift:155-157 — synthesis is documented as serialized.
  - ios/Runner/KokoroMLXService.swift:202-205 — every generateAudio call is dispatched onto one serial synthQueue.
- **Decision:** Concurrent generateAudio mutation is unreachable through the current app call path.
- **Recommendation:** No change while KokoroTTS remains service-private.

### R-234 · INFO · Kokoro wait has an explicit release timeout

- **Candidates:** CC-1253
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/tts_service.dart:716-726 — each completion wait is bounded to 60 seconds
- **Decision:** The candidate explicitly recommends no change and identifies no separate defect.
- **Recommendation:** No change.

### R-235 · INFO · Large editor functions are not a behavior failure

- **Candidates:** CC-1750
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:814-1125 — edit sheet branches are complete and controllers cleaned.
- **Decision:** Size is maintainability feedback.
- **Recommendation:** No current defect fix required.

### R-236 · INFO · Large main function is a style concern, not a demonstrated simulation failure

- **Candidates:** CC-2743
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - tool/sim_multi_user.dart:43-345 — one sequential scenario intentionally preserves ordered setup, assertions, and finally cleanup
- **Decision:** The candidate identifies function length and potential future editing risk, not a current incorrect result.
- **Recommendation:** Refactor only when changing the harness, preserving its explicit ordered scenario.

### R-237 · INFO · Large native plugin file is a maintainability observation, not a failure

- **Candidates:** CC-0259
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/AppleSttPlugin.swift:180 — listen owns the recognition lifecycle
  - ios/Runner/AppleSttPlugin.swift:365 — recording code is separated by a MARK section
- **Decision:** File size and responsibility count do not themselves produce an incorrect current behavior.
- **Recommendation:** No change unless a behavior-driven refactor is undertaken.

### R-238 · INFO · Latency assertion is intentional

- **Candidates:** CC-0202
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/android_rehearsal_harness_test.dart:145-163 — the first-chunk-before-half assertion directly tests streaming latency.
- **Decision:** The candidate itself describes a meaningful assertion and no defect.
- **Recommendation:** No change.

### R-239 · INFO · Later migration hardens recording UPDATE membership checks

- **Candidates:** CC-2420, CC-2421, CC-2422, CC-2423
- **Provenance:** `db-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:189 — the old Users can update own recordings policy is dropped
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:190 — a replacement UPDATE policy is created
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:193 — replacement WITH CHECK requires unchanged ownership
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:195 — replacement also requires membership in the new production
- **Decision:** The current final schema rejects repointing a recording into a production where the caller is not a member.
- **Recommendation:** No change.

### R-240 · INFO · Later migration prevents forged debug-report attribution

- **Candidates:** CC-2452, CC-2453, CC-2454, CC-2455, CC-2456, CC-2457, CC-2458, CC-2459
- **Provenance:** `db-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `db-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:179 — old insert policy is dropped
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:183 — replacement requires user_id = auth.uid
- **Decision:** The findings stop at the older migration and are refuted by the later policy migration applied afterward.
- **Recommendation:** No change required for attribution; separate rate/size controls may be considered independently.

### R-241 · INFO · Latest join migration closes all v2 RPC findings

- **Candidates:** CC-2439, CC-2440, CC-2441, CC-2442, CC-2443, CC-2444, CC-2445, CC-2446, CC-2447, CC-2448, CC-2449, CC-2450
- **Provenance:** `db-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `sql-migration-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:61-81 — lookup rate-limits signed-in callers and revokes anon.
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:83-165 — fetch, join, and claim require code or membership and old signatures are dropped.
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:198-205 — weak legacy codes are rerolled.
- **Decision:** Candidates stop at older migrations; v3 removes their triggers.
- **Recommendation:** No further fix for historical definitions.

### R-242 · INFO · Level callbacks are reinstalled per line and native levels stop

- **Candidates:** CC-1147, CC-1148
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:2258-2280 — rehearsal assigns onLevel and onSilence for every actor line
  - lib/data/services/stt_service.dart:232-245 — stop intentionally clears consumer hooks while stopping native listening
- **Decision:** Current owners re-register callbacks per session, and a completed native recognizer stops its audio tap; the claimed persistent level loss/events are absent.
- **Recommendation:** No change.

### R-243 · INFO · Levenshtein row-minimum early exit is sound

- **Candidates:** CC-1190
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/stt_vocabulary_service.dart:451 — rows extend the first-string prefix one character at a time
  - lib/data/services/stt_vocabulary_service.dart:453 — rowMin is the minimum distance to every prefix of the second string
  - lib/data/services/stt_vocabulary_service.dart:465 — exit occurs only when that minimum exceeds the cap
- **Decision:** The minimum edit distance from successive prefixes to any prefix of the target cannot fall below a previously exceeded cap; exhaustive bounded-string checking likewise finds no claimed counterexample.
- **Recommendation:** No change.

### R-244 · INFO · Lexicon restress is not a no-op

- **Candidates:** CC-0595
- **Provenance:** `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/Lexicon/Lexicon.swift:86-110 — stress markers are reassigned to vowelIndex-0.5 and indexed characters are sorted.
- **Decision:** When a marker starts before consonants, the algorithm moves it before the following vowel, contradicting the premise.
- **Recommendation:** No defect fix required.

### R-245 · INFO · Light-theme character contrast is unreachable

- **Candidates:** CC-0734
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/app.dart:277 — the app is fixed to ThemeMode.dark
  - lib/core/theme/app_theme.dart:7 — character colors are used under the active dark theme
- **Decision:** The light theme is not selectable in current code, so the claimed light-background contrast failure is unreachable.
- **Recommendation:** No change required unless light mode is enabled.

### R-246 · INFO · Light-theme contrast path is inactive

- **Candidates:** CC-1872
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/app.dart:275-278 — ThemeMode.dark is forced
  - lib/features/script_import/script_import_screen.dart:543-546 — the fixed grey text is rendered on that dark surface
- **Decision:** The claimed near-invisibility depends on a light theme the application does not select.
- **Recommendation:** No change.

### R-247 · INFO · Likely-not-script lines are intentionally optional removals

- **Candidates:** CC-1790
- **Provenance:** `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_import/ocr_review_screen.dart:140 — context editing intentionally skips every flagged neighbor
  - lib/features/script_import/ocr_review_screen.dart:979 — likely-not-script lines have a dedicated notes/handwriting section
  - lib/features/script_import/ocr_review_screen.dart:988 — the UI describes removal as optional cleanup
- **Decision:** A user can leave a misclassified line in the script and edit it later; this screen intentionally separates review corrections from optional note removal, so lack of a context field is not a proven failure.
- **Recommendation:** No change unless product requirements make all classifications editable here.

### R-248 · INFO · Linux runner declaration is compiled as C++

- **Candidates:** CC-2068, CC-2069, CC-2070
- **Provenance:** `c-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `c-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - linux/runner/my_application.h:19 — declaration uses empty parentheses
  - linux/runner/my_application.cc:1 — implementation translation unit is C++
- **Decision:** In C++, an empty parameter list means no parameters; the candidates incorrectly apply C’s unspecified-argument rule.
- **Recommendation:** No change.

### R-249 · INFO · Live ASR startup converts known failures to false

- **Candidates:** CC-1645
- **Provenance:** `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/live_asr_service.dart:60 — startup has a boolean contract
  - lib/data/services/live_asr_service.dart:80 — isolate spawn exceptions are caught and return false
  - lib/features/rehearsal/rehearsal_screen.dart:2911 — rehearsal consumes that boolean Future
- **Decision:** The cited engine-start failures are handled inside ensureStarted; the candidate does not show a remaining realistic thrown path.
- **Recommendation:** No change unless a concrete uncaught startup exception is reproduced.

### R-250 · INFO · Live-ASR model list cannot be empty in this build

- **Candidates:** CC-1908
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/model_download_service.dart:150 — catalog begins the live_asr group
  - lib/data/services/model_download_service.dart:170 — encoder entry uses live_asr
  - lib/data/services/model_download_service.dart:212 — tokens entry uses live_asr
- **Decision:** The model catalog is compile-time static and contains four nonzero-size entries, so totalBytes cannot be zero on Android without changing source.
- **Recommendation:** A defensive zero guard is harmless but does not fix a reachable current state.

### R-251 · INFO · Live-stream and playback-rate metadata are deliberate activation signals

- **Candidates:** CC-0520, CC-0521, CC-0522
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/MediaControlPlugin.swift:85-86 — activation intentionally installs initial now-playing metadata
  - ios/Runner/MediaControlPlugin.swift:107-116 — live-stream and nonzero rate are explicitly used to keep command targets responsive
  - ios/Runner/MediaControlPlugin.swift:91-102 — deactivation clears all now-playing metadata
- **Decision:** The metadata represents an active rehearsal command session rather than literal audio playback and is cleared on deactivate. The candidate identifies a product-label choice, not a proven malfunction.
- **Recommendation:** No change required unless device UX testing shows an unacceptable Live indicator.

### R-252 · INFO · Local recount handles current multi-character lines

- **Candidates:** CC-1863, CC-1864
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_import/script_import_screen.dart:455-481 — recount credits every multiCharacters member and ignores empty single-character cues
  - lib/data/models/script_models.dart:428-455 — canonical rebuilding has the same behavior for valid parser output
- **Decision:** The high-severity claim that only the primary character is credited is false. The only textual divergence requires an invalid empty-primary/multi-character model not produced by current parser paths.
- **Recommendation:** No change.

### R-253 · INFO · Locale loading is one-time and bounded

- **Candidates:** CC-1663
- **Provenance:** `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/character_manager_screen.dart:35 — locales load once from initState
  - lib/features/script_editor/character_manager_screen.dart:41 — one service read obtains the map
- **Decision:** The candidate explicitly says the one-time cost is fine.
- **Recommendation:** No change.

### R-254 · INFO · Locale provider updates are valid

- **Candidates:** CC-1854
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_import/script_import_screen.dart:361-369 — the updated production is written to list and current providers before preset selection
- **Decision:** The candidate explicitly reports no issue.
- **Recommendation:** No change.

### R-255 · INFO · LSTM constructor duplication is maintainability-only

- **Candidates:** CC-0420
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroVendored/BuildingBlocks/LSTM.swift:26-57 — current initializer receives explicit forward/backward tensors and callers compile against it.
- **Decision:** No current checkpoint key mismatch or numerical failure is shown.
- **Recommendation:** No defect fix required; refactor only with reference-output coverage.

### R-256 · INFO · macOS downloads are constrained and verified by Dart

- **Candidates:** CC-2072
- **Provenance:** `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - macos/Runner/BackgroundDownloadPlugin.swift:30-67 — downloader receives URL/model/path from the internal method call
  - lib/data/services/model_download_service.dart:259-278 — native completion verifies the registry model before marking success
  - lib/data/services/model_download_service.dart:395-424 — pinned downloads are size/hash checked and discarded on mismatch
- **Decision:** The candidate’s assumption that the caller does not verify is false, and current registry URLs are internal HTTPS constants rather than user input.
- **Recommendation:** No change.

### R-257 · INFO · macOS shared plugin sources are included in the target

- **Candidates:** CC-2104
- **Provenance:** `db-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - macos/Runner.xcodeproj/project.pbxproj:94 — PaddleOcrPlugin.swift references the shared iOS source
  - macos/Runner.xcodeproj/project.pbxproj:95 — AppleSttPlugin.swift likewise references the shared source
  - macos/Runner.xcodeproj/project.pbxproj:464 — Paddle source is in the macOS Sources build phase
  - macos/Runner.xcodeproj/project.pbxproj:466 — Apple STT source is in the build phase
- **Decision:** Both allegedly missing classes are explicitly compiled into the macOS Runner target.
- **Recommendation:** No change.

### R-258 · INFO · Main delegate queue is throttled and no failure is shown

- **Candidates:** CC-0318
- **Provenance:** `metal-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/BackgroundDownloadPlugin.swift:44 — URLSession delegates run on main
  - ios/Runner/BackgroundDownloadPlugin.swift:246 — progress bridge emissions are throttled by fraction and time
- **Decision:** Delegate callbacks still arrive on main, but their work is a few comparisons and bridge emissions are throttled; no realistic main-thread failure is established.
- **Recommendation:** No change unless profiling demonstrates callback pressure.

### R-259 · INFO · Main-isolate OCR scorer disposal does not dispose isolate scorer

- **Candidates:** CC-1027, CC-1028
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/script_import_service.dart:185-223 — scoring creates a fresh isolate-local singleton and disposes only the main-isolate holder.
- **Decision:** Dart isolate statics are independent and the UI exposes no concurrent import flow.
- **Recommendation:** No defect fix required.

### R-260 · INFO · Main-queue download delegate work is throttled and metadata-only

- **Candidates:** CC-2076
- **Provenance:** `ios-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - macos/Runner/BackgroundDownloadPlugin.swift:25 — delegate queue is main
  - macos/Runner/BackgroundDownloadPlugin.swift:143 — bridge emissions are throttled
  - macos/Runner/BackgroundDownloadPlugin.swift:101 — completion moves a URLSession temp file rather than copying its contents
- **Decision:** Callbacks still arrive on main, but the hot callback is throttled before the channel and completion performs same-volume metadata operations. No demonstrated UI freeze remains.
- **Recommendation:** Move completion I/O off-main only if profiling shows a hitch.

### R-261 · INFO · Manual debug log growth has no realistic failure

- **Candidates:** CC-1943, CC-1944, CC-1945, CC-1946, CC-1947
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/settings/kokoro_debug_screen.dart:85 — _log is called by manual diagnostic actions
  - lib/features/settings/kokoro_debug_screen.dart:90 — each action prepends one short line
  - lib/features/settings/kokoro_debug_screen.dart:339 — the log is confined to a 200-pixel debug pane
- **Decision:** Growth requires an unrealistic number of user button taps in one debug-screen lifetime; candidates themselves acknowledge ordinary cost is negligible.
- **Recommendation:** No change; cap only if automated logging is added.

### R-262 · INFO · Markdown stripping duplication has no current contradictory output

- **Candidates:** CC-1020
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/script_import_service.dart:53-76 — Markdown imports deliberately pre-strip a broader syntax set before parser normalization.
- **Decision:** No present parsing failure is identified.
- **Recommendation:** No defect fix required.

### R-263 · INFO · Match-score work is bounded per script line

- **Candidates:** CC-1150, CC-1152, CC-1153, CC-1154, CC-1155
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `metal-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/stt_service.dart:326-349 — LCS uses two rows and current expected/spoken line tokens
  - lib/features/rehearsal/rehearsal_screen.dart:2624-2663 — line advance stops STT before starting the next line
- **Decision:** The carried transcript exists only for the current line/session and current flows cap/stop it on advance; the asserted scene-long unbounded growth and observable jank are not established.
- **Recommendation:** No change.

### R-264 · INFO · Media plugin lifetime is app-owned, not a growing leak

- **Candidates:** CC-0511
- **Provenance:** `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/AppDelegate.swift:9-10,61-64 — AppDelegate owns one plugin instance for the engine lifetime
  - ios/Runner/MediaControlPlugin.swift:15-22 — one channel handler is installed at initialization
- **Decision:** The plugin and its channel intentionally live for the application engine lifetime; no repeated construction or accumulating leaked instances exists.
- **Recommendation:** No change required; a weak capture may be used for conventional ownership hygiene.

### R-265 · INFO · Memory bar ratio is a pressure heuristic, not a claimed system-used percentage

- **Candidates:** CC-1936
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/debug_log_screen.dart:236-280 — the UI labels app footprint in MB and available memory in MB; it does not label the bar as total system utilization
- **Decision:** physical/(physical+available) is a reasonable app-versus-headroom pressure heuristic. The candidate provides no observable wrong decision based on the bar.
- **Recommendation:** No change required; label the heuristic if operators misinterpret it.

### R-266 · INFO · Memory probe is not rapidly polled

- **Candidates:** CC-0087
- **Provenance:** `kotlin-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/debug_log_service.dart:135-139 — periodic memory snapshots run every configured interval
  - lib/data/services/debug_log_service.dart:84-85 — the interval is 10 seconds
- **Decision:** The realistic caller cadence is 0.1 Hz, so the cheap ActivityManager query and small result allocation do not create the hypothesized contention.
- **Recommendation:** No change.

### R-267 · INFO · Menu routes do not consume stale rehearsal selections

- **Candidates:** CC-1459
- **Provenance:** `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/home/home_screen.dart:409 — menu routes target editor/cast/record/history/settings, not rehearsal
  - lib/features/home/home_screen.dart:220 — actual production-hub entry resets rehearsal character and scene
- **Decision:** The stale providers are reset on the path that can reach rehearsal; the menu routes listed do not use them.
- **Recommendation:** No change required.

### R-268 · INFO · Misnamed PDF test does not assert a false contract

- **Candidates:** CC-2573
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - test/pdf_export_test.dart:1 — current file is parser-oriented despite its historical name
- **Decision:** A confusing filename is a discoverability issue, not a production or test-behavior failure.
- **Recommendation:** Rename opportunistically; no defect fix required.

### R-269 · INFO · Missing PDF is an intentional optional fallback

- **Candidates:** CC-1727
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:74-95 — absent files resolve to no PDF while editing remains available.
- **Decision:** Suppressing an optional cache miss is not a functional failure.
- **Recommendation:** No current defect fix required.

### R-270 · INFO · Missing staging pack fails loudly

- **Candidates:** CC-0221
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/kokoro_service_queue_macos_test.dart:35 — listSync on the fixture path throws if absent
- **Decision:** The candidate itself notes the test fails loudly; there is no silent success.
- **Recommendation:** No change required.

### R-271 · INFO · Missing sync files are intentionally permanent drops

- **Candidates:** CC-2639
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/sync_queue.dart:377-385 — processing logs and removes a job only when its concrete local path no longer exists
  - test/sync_queue_test.dart:161-176 — the contract explicitly pins that behavior
- **Decision:** Current queue paths point to finalized local recording files; no migration/lock path temporarily changes existence. Retrying a permanently deleted file would only create an endless failed queue item.
- **Recommendation:** No change.

### R-272 · INFO · Missing VERS markers fail under set -e

- **Candidates:** CC-2353, CC-2356, CC-2357, CC-2359
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/verify-apk-ort.sh:9-16 — set -euo pipefail applies to command substitutions whose grep returns nonzero on no match
- **Decision:** If either marker is absent, the assignment pipeline exits nonzero and set -e aborts; both empty strings do not reach the equality comparison, so the claimed vacuous OK is false.
- **Recommendation:** No change.

### R-273 · INFO · MLX debug-print costs are unreachable in the current app

- **Candidates:** CC-0644, CC-0645, CC-0646, CC-0647, CC-0648, CC-0649, CC-0650
- **Provenance:** `ios-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-performance-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MisakiVendored/Extensions/MLXArray+DebugPrint.swift:13 — this is an optional debug extension method
  - ios/Runner/MisakiVendored/Extensions/MLXArray+DebugPrint.swift:27 — it would materialize the full array
  - ios/Runner/MisakiVendored/Extensions/MLXArray+DebugPrint.swift:73 — output is console-only
- **Decision:** Repository search finds no .debugPrint() caller in ios/Runner, so current inference cannot incur the alleged transfer or allocation.
- **Recommendation:** No product change; optimize the helper if it is introduced into a live diagnostic path.

### R-274 · INFO · Model download progress is throttled before screen rebuilds

- **Candidates:** CC-1886, CC-1887, CC-1888, CC-1889, CC-1890, CC-1892
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/BackgroundDownloadPlugin.swift:246 — throttles native progress by fraction/time
  - macos/Runner/BackgroundDownloadPlugin.swift:143 — applies the same throttle
  - lib/data/services/model_download_service.dart:620 — Dart fallback notifies at roughly 1 MB deltas
  - lib/data/services/model_manager.dart:336 — ONNX archive progress is also throttled at roughly 1 MB
- **Decision:** The current source contains the throttles the candidates assumed were absent, bounding whole-screen rebuild cadence.
- **Recommendation:** Further widget scoping is optional profiling-driven polish.

### R-275 · INFO · Model download service contains its own start failures

- **Candidates:** CC-1909
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/ai_models_screen.dart:395 — awaits ModelDownloadService.download
  - lib/data/services/model_download_service.dart:500 — wraps the download start in try/catch
  - lib/data/services/model_download_service.dart:555 — converts thrown start/download errors to ModelStatus.error
- **Decision:** The specific _download path does not propagate ordinary network or native-start exceptions; it returns an error state that the screen displays.
- **Recommendation:** No extra catch is needed for that service contract.

### R-276 · INFO · Model load failure reaches a stable NOT_READY response

- **Candidates:** CC-0104
- **Provenance:** `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:108-112 — failure logs and clears loading
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:118-130 — loading=false and ready=false immediately returns NOT_READY
- **Decision:** The candidate itself identifies no behavior beyond the separate waiter issue; later calls are resolved with an error rather than left in a spinner state.
- **Recommendation:** No change.

### R-277 · INFO · Model polling loop is bounded

- **Candidates:** CC-1505
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/onboarding/model_setup_screen.dart:163 — loop has a 15-minute deadline
  - lib/features/onboarding/model_setup_screen.dart:170 — each iteration sleeps 500 ms
- **Decision:** The candidate explicitly dismisses unbounded busy-wait.
- **Recommendation:** No change.

### R-278 · INFO · Model readiness file stats are too infrequent to establish jank

- **Candidates:** CC-1509
- **Provenance:** `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/production_hub/production_hub_screen.dart:105 — readiness is checked once on hub initialization
  - lib/data/services/model_download_service.dart:315 — fileProblem performs a metadata existence/length check, not reading model contents
- **Decision:** A handful of local metadata stats per screen entry/tap has no demonstrated user-visible stall; the claimed 1–10 ms per file is speculative.
- **Recommendation:** Move off-isolate only if profiling shows a frame miss.

### R-279 · INFO · Model URLs are fixed HTTPS constants

- **Candidates:** CC-2084
- **Provenance:** `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/model_download_service.dart:123 — model download URLs are compile-time catalog values
  - lib/data/services/model_manager.dart:40 — Android Kokoro archive uses a fixed HTTPS GitHub URL
- **Decision:** No caller supplies user-controlled or HTTP URLs to this channel in the current app.
- **Recommendation:** Scheme validation at the native boundary is optional defense in depth.

### R-280 · INFO · Mutation-chain map is practically bounded

- **Candidates:** CC-1304, CC-1305
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/voice_config_service.dart:21-33 — one completed Future is retained per production touched.
- **Decision:** The object is tiny and user production count is realistically bounded.
- **Recommendation:** No defect fix required.

### R-281 · INFO · Native page OCR does not return null on handled requests

- **Candidates:** CC-0945, CC-0946
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/paddle_ocr_channel.dart:73 — ocrPage invokes the registered ocrPdfPage method
  - ios/Runner/PaddleOcrPlugin.swift:148 — iOS registers ocrPdfPage
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:157 — Android registers ocrPdfPage
  - lib/data/services/paddle_ocr_channel.dart:88 — unavailable plugins return null via MissingPluginException
- **Decision:** Registered native handlers return a result or FlutterError; plugin absence throws MissingPluginException. The hypothesized null response is not a current native contract path.
- **Recommendation:** No change.

### R-282 · INFO · Native STT errors are followed by onDone

- **Candidates:** CC-1130, CC-1131, CC-1132
- **Provenance:** `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/AppleSttPlugin.swift:276 — emits onError
  - ios/Runner/AppleSttPlugin.swift:277 — immediately emits onDone
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:205 — emits onError
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:208 — emits onDone
- **Decision:** The current producers guarantee the terminal callback that resets Dart state, so the hypothesized permanently listening session does not occur.
- **Recommendation:** Keep the producer contract synchronized or defensively end onError if adding another native backend.

### R-283 · INFO · Native STT payload casts match every current producer

- **Candidates:** CC-1127
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/stt_channel.dart:131 — expects a map for onResult
  - ios/Runner/AppleSttPlugin.swift:276 — native plugin controls the emitted error callback
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:205 — Android plugin controls the same channel
- **Decision:** The platform channel is internal, not attacker-controlled, and current native implementations emit the expected shapes. No malformed producer is identified.
- **Recommendation:** Use defensive decoding only as general robustness hardening.

### R-284 · INFO · Native Vision plugins return the exact payload types decoded by Dart

- **Candidates:** CC-1265, CC-1266, CC-1267
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/vision_ocr_channel.dart:19 — Dart decodes the controlled native block map
  - macos/Runner/VisionOcrPlugin.swift:122 — macOS constructs pages/page counts using concrete dictionaries and integers
  - ios/Runner/PaddleOcrPlugin.swift:201 — iOS constructs page and line maps with the same contract
- **Decision:** The alleged malformed method-channel types require a bug in the current first-party native producer; current implementations construct the exact expected map/string/number shapes.
- **Recommendation:** No broad catch/fallback; keep native and Dart contracts tested together.

### R-285 · INFO · Navigation is mounted-guarded

- **Candidates:** CC-1880
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_import/script_import_screen.dart:581-583 — context.push occurs only after an explicit mounted check
- **Decision:** The candidate explicitly dismisses the path.
- **Recommendation:** No change.

### R-286 · INFO · No competing remote-command targets exist in the current app

- **Candidates:** CC-0514, CC-0515, CC-0517
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/MediaControlPlugin.swift:47-100 — this plugin is the only current MPRemoteCommandCenter user and removes its targets
  - ios/Runner/AppDelegate.swift:61-64 — only one media-control plugin instance is registered
- **Decision:** removeTarget(nil) would remove other targets, but repository search shows no second component registering them. The hypothesized current component breakage is unreachable.
- **Recommendation:** Store target tokens if another media component is introduced.

### R-287 · INFO · No current client subscribes to script-line realtime fan-out

- **Candidates:** CC-2425
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/migrations/20260314120000_add_script_lines.sql:47-48 — script_lines is in the realtime publication
  - lib/data/services/supabase_service.dart:789-843 — current realtime subscriptions are only for recordings
  - lib/data/services/supabase_service.dart:755-786 — line replacement is batched and no client callback consumes per-line events
- **Decision:** Publication causes WAL processing, but the alleged O(N×connected-cast) client broadcast requires script_lines subscribers that the current app does not create. Recordings realtime is separately needed for live take sharing.
- **Recommendation:** Remove script_lines from the publication if no external subscriber needs it, as optional overhead cleanup.

### R-288 · INFO · No string-built SQL exists in join_production

- **Candidates:** CC-2525
- **Provenance:** `db-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:131 — join_production uses a static EXISTS query
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:137 — insert values use typed PL/pgSQL parameters directly
- **Decision:** The candidate invents string concatenation/dynamic SQL that is absent. A quote in prod_id reaches a UUID cast error, not definer SQL injection.
- **Recommendation:** No injection fix; optionally normalize UUID inputs.

### R-289 · INFO · No-op filter does not alter currency output

- **Candidates:** CC-0620
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/Lexicon/Lexicon.swift:555-563 — filter { _ in true } preserves all constructed pairs.
- **Decision:** The expression is redundant but produces no failing behavior.
- **Recommendation:** No defect fix required.

### R-290 · INFO · Non-Android live-ASR filter is necessary

- **Candidates:** CC-1905
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/ai_models_screen.dart:142 — non-Android branch iterates the global catalog
  - lib/features/settings/ai_models_screen.dart:146 — removes live_asr entries there
  - lib/data/services/model_download_service.dart:170 — global catalog includes live_asr entries
- **Decision:** The predicate is not dead: it prevents Android-only ASR artifacts from appearing on Apple platforms.
- **Recommendation:** No change.

### R-291 · INFO · Normal cancellation already removes or replaces active state

- **Candidates:** CC-2102, CC-2103
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - macos/Runner/BackgroundDownloadPlugin.swift:77 — explicit cancel removes the dictionary entry before canceling
  - macos/Runner/BackgroundDownloadPlugin.swift:61 — restart replaces the old entry
  - macos/Runner/BackgroundDownloadPlugin.swift:168 — cancelled delegate callback deliberately leaves the current/replacement entry untouched
- **Decision:** The cancelled-error early return does not leak through the two current cancellation routes. lastProgressEmit remains only a tiny catalog-bounded hygiene issue.
- **Recommendation:** Clean progress metadata on terminal events if desired; do not remove a replacement task from a stale cancel callback.

### R-292 · INFO · Nullable copyWith fields have no clearing caller

- **Candidates:** CC-0757
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/models/cast_member_model.dart:62 — null preserves userId
  - lib/data/models/cast_member_model.dart:65 — null preserves contactInfo
- **Decision:** The pattern cannot express clearing, but no current caller attempts to clear these fields via copyWith; repository flows update them through persistence models/services.
- **Recommendation:** Add sentinel parameters when an observable clear operation is introduced.

### R-293 · INFO · Nullable parser guards cannot silently pass today

- **Candidates:** CC-2558, CC-2559, CC-2560, CC-2561, CC-2562
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - test/parser_accuracy_test.dart:23-34 — parseFile calls fail or returns ScriptParser.parse.
  - test/parser_accuracy_test.dart:63-241 — null guards precede real assertions but are unreachable.
- **Decision:** The feared null return path does not exist.
- **Recommendation:** Optionally make helper nonnullable.

### R-294 · INFO · Objective-C exception catcher implementation is present and used safely

- **Candidates:** CC-0656, CC-0657, CC-0658
- **Provenance:** `c-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/ObjCExceptionCatcher.m:1-11 — the declared class wraps tryBlock in @try/@catch and invokes catchBlock
  - ios/Runner/AppleSttPlugin.swift:327-331 — the sole call supplies a non-null catch closure
- **Decision:** The implementation exists in the current target and the only caller supplies both blocks. The header itself contains no defect.
- **Recommendation:** No change required.

### R-295 · INFO · Obsolete Kokoro EnglishG2P path is absent

- **Candidates:** CC-0488
- **Provenance:** `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/EnglishG2P.swift:1-6 — the current vendored EnglishG2P implementation lives under MisakiVendored
- **Decision:** The cited ios/Runner/KokoroVendored/TextProcessing/EnglishG2P.swift no longer exists, so its line-141 finding cannot trigger.
- **Recommendation:** No change required; assess the active Misaki implementation separately.

### R-296 · INFO · OCR confidence test resets singleton state between every case

- **Candidates:** CC-2551
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - test/ocr_confidence_test.dart:13 — setUp injects the expected vocabulary before each test
  - test/ocr_confidence_test.dart:17 — tearDown disposes/reset state after each test
  - lib/data/services/ocr_confidence_service.dart:104 — dispose clears checker and vocabulary state
  - lib/data/services/ocr_confidence_service.dart:66 — the checker is lazily re-registered on the next use
- **Decision:** The shared instance is intentionally reset and then reinitialized by each test; no later case observes disposed or mutated state.
- **Recommendation:** No change.

### R-297 · INFO · OCR import count assertion is not a defect

- **Candidates:** CC-0235
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/ocr_import_macos_test.dart:49 — the candidate itself identifies the review-count assertion as fine
- **Decision:** No failure hypothesis is stated, and the current assertion is ordinary test coverage.
- **Recommendation:** No change.

### R-298 · INFO · OCR inputs are bounded before ORT and no hang trigger is shown

- **Candidates:** CC-0698
- **Provenance:** `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/PaddleOcrPlugin.swift:247 — detection long side is capped at 960
  - ios/Runner/PaddleOcrPlugin.swift:335 — recognition width is capped at 1024
- **Decision:** The candidate posits an indefinitely hung runtime from oversized or malformed tensors, but current tensors are fixed-shape bounded and no realistic ORT hang is established.
- **Recommendation:** Cancellation can be added as a feature; a watchdog cannot safely abort arbitrary synchronous native inference by itself.

### R-299 · INFO · OCR scoring duplication is not an observable defect

- **Candidates:** CC-0938, CC-0940
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/ocr_highlight_matcher.dart:100 — locate owns its global-best selection loop
  - lib/data/services/ocr_highlight_matcher.dart:172 — bestMatch deliberately has locality-first semantics
  - lib/data/services/ocr_highlight_matcher.dart:180 — comments explain why the policies intentionally differ
- **Decision:** The loops share scoring but intentionally use different selection policies; code duplication alone is maintenance risk, not a current failure.
- **Recommendation:** Optionally extract only the score calculation without merging selection semantics.

### R-300 · INFO · Old join-code DDL is no longer a reachable migration path

- **Candidates:** CC-2427
- **Provenance:** `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260315_cast_join_code.sql:5-14 — the lock-heavy add/backfill/not-null sequence is in a dated migration already superseded by months of later migrations
- **Decision:** The migration has already been applied in the current final schema; rerunning it would fail on existing columns rather than block current application traffic.
- **Recommendation:** No change.

### R-301 · INFO · Omitted storage WITH CHECK does not mean new rows are unchecked

- **Candidates:** CC-2472
- **Provenance:** `db-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/migrations/20260703140000_security_lockdown.sql:73 — this is an UPDATE policy with USING
  - supabase/migrations/20260703140000_security_lockdown.sql:75 — the predicate validates production membership derived from name
- **Decision:** Under PostgreSQL RLS semantics, an UPDATE policy with no explicit WITH CHECK reuses its USING expression for the new row; renaming into a production where the caller is not a member is rejected.
- **Recommendation:** No change for this claim; add explicit WITH CHECK only for clarity.

### R-302 · INFO · On-device preference branch has no current reachable caller

- **Candidates:** CC-0261, CC-0262, CC-0263, CC-0264, CC-0265, CC-0266, CC-0267, CC-0268
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/stt_channel.dart:90 — onDevice defaults to false
  - lib/data/services/stt_service.dart:188 — the sole application listen path omits onDevice
  - ios/Runner/AppleSttPlugin.swift:229 — the questionable branch runs only when onDevice is true
- **Decision:** The native branch would not require on-device recognition, but no current app caller can set it true and there is no user privacy control promising this behavior.
- **Recommendation:** No current product fix; if the option is exposed, set requiresOnDeviceRecognition true or remove the parameter.

### R-303 · INFO · One-shot scene mutation copying is inherent and bounded

- **Candidates:** CC-1662
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/scene_editor_screen.dart:381 — one list copy is made on explicit Save
  - lib/features/script_editor/scene_editor_screen.dart:385 — only the edited scene range receives copyWith
  - lib/features/script_editor/scene_editor_screen.dart:399 — one debounced persistence follows
- **Decision:** This is a user-triggered edit with one O(lines + scene size) immutable-state update; the candidate itself concedes the dominant full save is inherent.
- **Recommendation:** No performance change without measurement.

### R-304 · INFO · One-time codec setup is not a demonstrated UI failure

- **Candidates:** CC-0039
- **Provenance:** `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:295 — AAC encoder and muxer setup occurs once per user-initiated recording
- **Decision:** The candidate itself characterizes this as below threshold and supplies no measured jank.
- **Recommendation:** No change unless device profiling demonstrates a problem.

### R-305 · INFO · ONNX readiness check gracefully remains false on failure

- **Candidates:** CC-1891
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/ai_models_screen.dart:49 — readiness is an asynchronous convenience check
  - lib/features/settings/ai_models_screen.dart:179 — false renders the download state
- **Decision:** The candidate itself dismisses the behavior; no misleading success or data loss occurs.
- **Recommendation:** Optional error logging may improve diagnostics.

### R-306 · INFO · onReorder fires on completed reorder

- **Candidates:** CC-1748
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:414-420 — one callback invokes one persistence path.
- **Decision:** The estimate assumes repeated callbacks while crossing indices, which ReorderableListView does not make.
- **Recommendation:** No current defect fix required.

### R-307 · INFO · Opaque model generation assumption is not a finding

- **Candidates:** CC-2812
- **Provenance:** `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tools/mlx-harness/Sources/harness/main.swift:63 — harness calls the model API
  - tools/mlx-harness/Sources/harness/main.swift:64 — one host materialization is required to print token ids
- **Decision:** The candidate explicitly states the boundary is natural and identifies no defect.
- **Recommendation:** No change required.

### R-308 · INFO · Operational comments do not change Supabase behavior

- **Candidates:** CC-2398
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/config.toml:209 — records why confirmations were enabled
  - supabase/config.toml:225 — records SMTP operational context
- **Decision:** Forward-dated or historical comments may need editorial cleanup but cannot cause a runtime or deployment failure.
- **Recommendation:** Update comments only when their facts become stale.

### R-309 · INFO · Operator-provided HTTP input is not an authenticated transport contract

- **Candidates:** CC-2328
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/test_silence_trim.swift:117 — the URL is supplied directly by the operator
  - scripts/test_silence_trim.swift:120 — both HTTP and HTTPS are treated as remote inputs
  - scripts/test_silence_trim.swift:132 — the tool only analyzes the resulting local diagnostic file
- **Decision:** This offline developer tool does not handle user credentials or claim authenticity of arbitrary operator URLs; accepting HTTP is not a current product security failure.
- **Recommendation:** Prefer HTTPS operationally; no repository correctness change required.

### R-310 · INFO · Optional ALBERT value bias is not a current checkpoint failure

- **Candidates:** CC-0402, CC-0403, CC-0404, CC-0405, CC-0406
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroVendored/Albert/AlbertSelfAttention.swift:29 — only value bias is accepted as optional
  - ios/Runner/KokoroVendored/Albert/AlbertSelfAttention.swift:24 — adjacent required checkpoint tensors force-fail when absent
- **Decision:** The pinned shipped checkpoint contains this tensor; a selectively missing value-bias key is neither produced by current downloads nor a realistic supported input.
- **Recommendation:** No change required; consistent validation would be optional hardening.

### R-311 · INFO · Optional token promotion matches the shared G2P contract

- **Candidates:** CC-0493
- **Provenance:** `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroVendored/TextProcessing/G2PProcessor.swift:29 — the protocol returns optional token arrays
  - ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:250 — consumes the shared optional contract
- **Decision:** Swift may promote a non-optional Misaki token array to the protocol optional; nil remains meaningful for other engines.
- **Recommendation:** No change.

### R-312 · INFO · Orphan analyzer try/catch is syntactically complete

- **Candidates:** CC-2690
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - tool/analyze_orphaned_recordings.dart:38-54 — the membership insert try is closed by a catch before subsequent queries
  - tool/analyze_orphaned_recordings.dart:112-122 — main is structurally closed normally
- **Decision:** The claimed unterminated outer try does not exist in current source. Cleanup placement is a separate verified issue.
- **Recommendation:** No syntax fix required.

### R-313 · INFO · Orphan-warning retry does not rebuild large nonempty sets repeatedly

- **Candidates:** CC-1624
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:1886 — recording IDs are gathered
  - lib/features/rehearsal/rehearsal_screen.dart:1890 — retry occurs only while the set is empty
  - lib/features/rehearsal/rehearsal_screen.dart:1891 — first nonempty set latches the check
- **Decision:** While syncing has produced no rows, set creation is over empty maps; once the maps are large/nonempty the work runs once. The proposed repeated O(recordings) cost is absent.
- **Recommendation:** No change.

### R-314 · INFO · ORT vendoring is checksum-pinned

- **Candidates:** CC-0016
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/fetch-ort-java.sh:13-29 — the default 1.22.0 AAR has a pinned SHA-256 and mismatches abort
  - android/app/build.gradle.kts:80-90 — the vendored jar provenance and regeneration script are documented
- **Decision:** The claimed missing integrity pin is fixed in the current fetch script.
- **Recommendation:** No change required; update the pin deliberately with any ORT version bump.

### R-315 · INFO · Out-of-range OCR classes require a mismatched bundle

- **Candidates:** CC-0687
- **Provenance:** `ios-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/PaddleOcrPlugin.swift:347 — indexes the bundled key table defensively
  - ios/Runner/PaddleOcrPlugin.swift:92 — model and keys are loaded together from committed assets
- **Decision:** A class/key mismatch requires packaging incompatible model resources, not a user input trigger in the current build.
- **Recommendation:** Validate model/key cardinality during model loading if packaging drift becomes a concern.

### R-316 · INFO · Own-membership delete is permitted and SDK errors are not silently successful

- **Candidates:** CC-2716
- **Provenance:** `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260703090000_leave_policy_and_audit_cleanup.sql:5-8 — users may delete their own cast_members row
  - tool/analyze_orphaned_recordings.dart:113-119 — delete exceptions are caught and reported
- **Decision:** Current RLS permits this exact cleanup. The lack of returned deleted rows does not make a successful PostgREST response evidence of an RLS-blocked delete.
- **Recommendation:** No change required; selecting deleted ids is optional auditing.

### R-317 · INFO · Paddle not-ready errors do reach the import fallback

- **Candidates:** CC-0665, CC-0666, CC-0667
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/PaddleOcrPlugin.swift:135 — emits NOT_READY as a PlatformException
  - lib/data/services/script_import_service.dart:358 — wraps PaddleOcrChannel.ocrPdf in a broad try/catch
  - lib/data/services/script_import_service.dart:368 — converts any exception to a null result that selects the fallback
- **Decision:** Although the native comment names FlutterMethodNotImplemented, the production PDF importer catches NOT_READY and falls back as intended.
- **Recommendation:** Correct the misleading native comment; behavior need not change.

### R-318 · INFO · Paddle package matches the app namespace

- **Candidates:** CC-0094
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:1 — package is com.tiltastech.castcircle
  - android/app/src/main/kotlin/com/tiltastech/lineguide/MemoryMonitorPlugin.kt:1 — sibling plugin uses the same package
- **Decision:** The directory name does not define Kotlin’s package, and the claimed sibling-package mismatch is absent.
- **Recommendation:** No change.

### R-319 · INFO · Page OCR fallback is explicit and caller-visible

- **Candidates:** CC-0947
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/paddle_ocr_channel.dart:90 — PlatformException is mapped to null
  - lib/features/script_import/pdf_page_view.dart:245 — caller consults its page cache or OCR
  - lib/features/script_import/pdf_page_view.dart:246 — null is handled at the page-view boundary
- **Decision:** The channel intentionally exposes best-effort page localization; a native error degrades to no overlay rather than aborting the viewer. No harmful silent alternate-engine switch is shown.
- **Recommendation:** Optional logging, not a verified failure.

### R-320 · INFO · Parse-stats pairwise scan is tiny at realistic roster sizes

- **Candidates:** CC-2742
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tool/parse_stats.dart:65 — scoring performs a pairwise expected-name scan
  - tool/parse_stats.dart:72 — work ends after the roster loop
- **Decision:** The candidate itself bounds both lists to tens of names and the operation to microseconds, with no observable consequence.
- **Recommendation:** No change.

### R-321 · INFO · Parsed ensemble lines retain a nonempty combined character name

- **Candidates:** CC-1784, CC-1785
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/script_parser.dart:1375 — parser normalizes the combined cue name
  - lib/data/services/script_parser.dart:1386 — it stores that cue in character
  - lib/data/services/script_parser.dart:1390 — individual names are additionally stored in multiCharacters
  - lib/features/script_editor/validation_panel.dart:40 — attribution therefore sees the combined nonempty character
- **Decision:** The current parser does not represent a valid multi-character cue with empty character; multiCharacters supplements rather than replaces it.
- **Recommendation:** No validation change for this candidate.

### R-322 · INFO · Parser filters empty ensemble character names

- **Candidates:** CC-1534, CC-1535
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/script_parser.dart:1001 — ensemble segments are trimmed
  - lib/data/services/script_parser.dart:1004 — empty segments are filtered
  - lib/data/services/script_parser.dart:1006 — only two or more valid nonempty names are accepted
- **Decision:** The proposed parser route cannot produce an empty ScriptCharacter, so char.name[0] is safe for current generated data.
- **Recommendation:** No change required; a UI guard would be optional defense in depth.

### R-323 · INFO · Parser regex scan is below threshold

- **Candidates:** CC-2213
- **Provenance:** `x86-simd-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/parse_script.py:145-152 — precompiled cue patterns are checked once per non-noise line
- **Decision:** The candidate explicitly describes sub-second operator-tool work and recommends no change.
- **Recommendation:** No change.

### R-324 · INFO · Parser size is a maintainability observation, not a failure

- **Candidates:** CC-1047
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/script_parser.dart:29 — ScriptParser owns the parsing pipeline
  - lib/data/services/script_parser.dart:117 — parse exposes one cohesive script-to-model operation
  - lib/data/services/script_parser.dart:1357 — line assembly remains private implementation detail
- **Decision:** File length and responsibility count do not establish incorrect current behavior.
- **Recommendation:** Refactor only behind characterization tests when a concrete change needs it.

### R-325 · INFO · Parser-derived character names are non-empty

- **Candidates:** CC-1848
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/models/script_models.dart:432-443 — canonical character rebuilding excludes dialogue with an empty primary character before creating ScriptCharacter entries
- **Decision:** The preview list is built from parser/rebuild output whose character names are non-empty, so char.name[0] is reachable only with an invalid externally-constructed model not used here.
- **Recommendation:** No change.

### R-326 · INFO · PCM chunk allocation and event cadence are bounded

- **Candidates:** CC-0051, CC-0052
- **Provenance:** `android-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:64 — chunks are fixed at 100 ms
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:380 — one roughly 3.2 KB byte array is allocated per chunk
- **Decision:** Roughly ten chunks and twenty small events per second are bounded and no queue-growth trigger is shown.
- **Recommendation:** No change unless profiling identifies actual pressure.

### R-327 · INFO · PDF document handle is closed for all post-open failures

- **Candidates:** CC-2246, CC-2247
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `python-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/pdf_to_script.py:331 — document is opened before try
  - scripts/pdf_to_script.py:339 — every failure after a successful open closes it in finally
- **Decision:** If open itself throws there is no acquired document handle to leak. A raw CLI traceback is usability, not the claimed resource leak.
- **Recommendation:** Optional: catch PyMuPDF errors for friendlier CLI output.

### R-328 · INFO · PDF sample harness intentionally mirrors one Macbeth fixture

- **Candidates:** CC-2306, CC-2312
- **Provenance:** `ios-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/test_pdf_import.swift:2-5 — the script is documented as a quick test for the Macbeth sample
  - scripts/test_pdf_import.swift:66-100 — cleanup is explicitly a simulation, including the fixture-specific Macbeth header
- **Decision:** This is a one-fixture diagnostic harness, not a shared production parser or general PDF CLI. Its hardcoded sample behavior is intentional.
- **Recommendation:** No change required unless the script is promoted into a general-purpose verifier.

### R-329 · INFO · PDFKit page arrays are strings, including blank pages

- **Candidates:** CC-0960, CC-0961
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/pdf_text_channel.dart:37 — pages comes from the native result
  - lib/data/services/pdf_text_channel.dart:39 — Dart casts each page to String
  - lib/data/services/script_import_service.dart:99 — import consumes this native per-page contract
- **Decision:** Native PDF extraction represents an empty page as an empty string, not a null list element; the candidate supplies no current native path producing a non-string element.
- **Recommendation:** No change; validate at the boundary if the native contract changes.

### R-330 · INFO · pdfrx serializes document dispose behind active rendering

- **Candidates:** CC-1825
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_import/pdf_page_view.dart:103 — requests PdfDocument.dispose on State disposal
  - /Users/jasontitus/.pub-cache/hosted/pub.dev/pdfrx_engine-0.3.9/lib/src/native/pdfrx_pdfium.dart:1181 — rendering runs through the single BackgroundWorker
  - /Users/jasontitus/.pub-cache/hosted/pub.dev/pdfrx_engine-0.3.9/lib/src/native/pdfrx_pdfium.dart:910 — document close uses that same worker
- **Decision:** The package queues both native render and close on one worker isolate, so the close cannot race inside the PDFium render as claimed.
- **Recommendation:** No app-side render lock is required for this crash hypothesis.

### R-331 · INFO · Pending adaptation persist cannot restore cleared profile data by itself

- **Candidates:** CC-1091
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/stt_adaptation_service.dart:493 — clearProduction removes the dirty marker
  - lib/data/services/stt_adaptation_service.dart:495 — removes actor profiles before deletion
  - lib/data/services/stt_adaptation_service.dart:499 — removes the production profile
- **Decision:** A later timer snapshot sees empty maps, so it may recreate an empty directory/file but not the deleted samples claimed by this candidate.
- **Recommendation:** A generation guard would avoid empty recreation, but the stated data resurrection is false.

### R-332 · INFO · Per-buffer scratch allocation is bounded background diagnostic work

- **Candidates:** CC-0307
- **Provenance:** `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/AppleSttPlugin.swift:536 — allocation occurs in an offline AVAssetReader loop
  - ios/Runner/AppleSttPlugin.swift:548 — scratch size is one sample buffer
  - ios/Runner/AppleSttPlugin.swift:581 — the reader is cancelled after one pass per take
- **Decision:** This is background, once-per-take work and no realistic intended take demonstrates a failure from the bounded scratch churn.
- **Recommendation:** No change absent profiling.

### R-333 · INFO · Per-card provider watches are cached and bounded

- **Candidates:** CC-1451, CC-1452
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/home/home_screen.dart:161 — each card watches a family provider keyed by production id
  - lib/features/home/home_screen.dart:187 — the same pattern is used for list layout
- **Decision:** Riverpod caches each family instance; a one-time rebuild as saved values resolve is not a demonstrated failure at realistic production counts.
- **Recommendation:** No change required.

### R-334 · INFO · Per-character rename fanout is small and action-scoped

- **Candidates:** CC-1684, CC-1685, CC-1686
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/character_manager_screen.dart:647 — loop covers only cast rows assigned to the one renamed character
  - lib/features/script_editor/character_manager_screen.dart:650 — each cloud rename is awaited for coherent per-member error handling
- **Decision:** The normal cardinality is one primary plus a few understudies and occurs only on explicit rename; no realistic seconds-scale failure is established.
- **Recommendation:** Batch only if real casts demonstrate high duplicate assignment counts.

### R-335 · INFO · Per-character tokenizer allocations are bounded and dominated by inference

- **Candidates:** CC-0501, CC-0502
- **Provenance:** `ios-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroVendored/TextProcessing/Tokenizer.swift:20 — one String key conversion occurs per phoneme character
  - ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:270 — input is capped by maxTokenCount
- **Decision:** The work is linear and tightly bounded; no measured latency or allocation failure is shown relative to model inference.
- **Recommendation:** No change unless profiling identifies it as material.

### R-336 · INFO · Per-download HttpClient construction is negligible

- **Candidates:** CC-0912
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/model_manager.dart:289 — one client is created for a user-initiated archive download
- **Decision:** This is a bounded cold path and the candidate identifies no threshold breach.
- **Recommendation:** No change required.

### R-337 · INFO · Per-file mkdir overhead is cold tooling work

- **Candidates:** CC-2834
- **Provenance:** `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tools/mlx-harness/link-sources.sh:13 — mkdir -p runs per vendored Swift file
  - tools/mlx-harness/link-sources.sh:4 — script is manually rerun only when vendored files change
- **Decision:** The operation is developer-only and infrequent; no seconds-scale failure is demonstrated at the current tree size.
- **Recommendation:** Optimize only if measured.

### R-338 · INFO · Per-line keys already force same-page highlight refresh

- **Candidates:** CC-1820, CC-1821, CC-1822
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_import/ocr_review_screen.dart:363 — key changes with the current line ID
  - lib/features/script_import/ocr_review_screen.dart:693 — selected-line key remounts the viewer
  - lib/features/script_editor/script_editor_screen.dart:503 — editor source pane follows the same pattern
- **Decision:** Although didUpdateWidget ignores highlightText, current callers destroy and recreate the State whenever the highlighted line changes, including same-page changes.
- **Recommendation:** Fix didUpdateWidget before replacing per-line keys with stable keys.

### R-339 · INFO · Per-line voice and pitch calls are bounded

- **Candidates:** CC-1245
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/tts_service.dart:441-452 — voice/pitch setup occurs once on the system fallback for a spoken line
- **Decision:** The candidate asserts only an optional cache optimization without an observable defect.
- **Recommendation:** No change.

### R-340 · INFO · Per-page NSLog cost is negligible and off the UI thread

- **Candidates:** CC-0680
- **Provenance:** `ios-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/PaddleOcrPlugin.swift:167 — the page loop runs on a global queue
  - ios/Runner/PaddleOcrPlugin.swift:202 — emits one diagnostic per processed page
- **Decision:** One off-main diagnostic per multi-second OCR page is not a realistic performance failure.
- **Recommendation:** Keep or gate it based on desired diagnostics.

### R-341 · INFO · Per-partial alignment allocation is not independently a failure

- **Candidates:** CC-1185
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/stt_vocabulary_service.dart:384 — dimensions are the words in one recognized and expected line
  - lib/data/services/stt_vocabulary_service.dart:387 — one flat Int32List holds the matrix
- **Decision:** For ordinary script lines the one flat allocation is small; the candidate gives no realistic observed failure distinct from the algorithmic long-line cost.
- **Recommendation:** No change; profile before introducing scratch-buffer state.

### R-342 · INFO · Per-script scoring clears cached word verdicts

- **Candidates:** CC-0921
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/ocr_confidence_service.dart:250 — rebuilds the script whitelist
  - lib/data/services/ocr_confidence_service.dart:255 — clears word-validity cache before scoring
- **Decision:** The production scoring path cannot reuse a prior script whitelist through the cache.
- **Recommendation:** Optionally clear the cache in dispose for API hygiene, but no production misclassification remains.

### R-343 · INFO · Per-token host synchronization is inherent and bounded here

- **Candidates:** CC-0580, CC-0581
- **Provenance:** `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/FallbackNetwork/BARTModel.swift:137 — decode is capped at 50 steps
  - ios/Runner/MisakiVendored/English/FallbackNetwork/BARTModel.swift:166 — each next token is needed before the next autoregressive step
- **Decision:** A host-visible next token is a dependency of this loop, and the candidates do not establish a realistic performance failure for the bounded OOV fallback.
- **Recommendation:** Optimize only with measured evidence or a different batched decoding design.

### R-344 · INFO · Per-word decode is the explicit offline harness contract

- **Candidates:** CC-2801, CC-2802
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tools/mlx-harness/Sources/harness/main.swift:9 — bart subcommand is defined to decode each word
  - tools/mlx-harness/Sources/harness/main.swift:57 — loop performs one result/materialization per requested word
- **Decision:** Runtime is necessarily linear in the operator-supplied word count and no unbounded hidden input or breached threshold is shown.
- **Recommendation:** No change required.

### R-345 · INFO · Periodic timer lifecycle is already guarded

- **Candidates:** CC-1912
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/debug_log_screen.dart:32-51 — callback checks mounted and dispose cancels the timer
- **Decision:** The candidate explicitly dismisses this timer and current lifecycle is correct.
- **Recommendation:** No change required.

### R-346 · INFO · Permission-check duplication is not a demonstrated failure

- **Candidates:** CC-0021
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:106 — initialize intentionally preflights permission while startRecording reports a distinct command error at lines 264-273
- **Decision:** The different outcomes correspond to different method contracts; duplication alone does not prove a current failure.
- **Recommendation:** No change required.

### R-347 · INFO · Persisted guest preference has a startup reader

- **Candidates:** CC-1341, CC-1342
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/auth/auth_screen.dart:421 — skip writes auth_skipped
  - lib/main.dart:156 — startup reads the persisted Supabase session
  - lib/main.dart:157 — startup also reads auth_skipped
  - lib/main.dart:163 — the result restores the auth gate
- **Decision:** The claimed dead state is used on the next launch exactly as the comment says.
- **Recommendation:** No change.

### R-348 · INFO · Pinned archive makes crafted traversal entry unreachable

- **Candidates:** CC-0910
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/model_manager.dart:42 — archive SHA-256 is pinned
  - lib/data/services/model_manager.dart:208 — bytes are rejected before extraction on hash mismatch
- **Decision:** An attacker cannot substitute a crafted tar without also changing trusted app code/hash; no user-controlled archive reaches extraction.
- **Recommendation:** No change required; path validation remains defense in depth.

### R-349 · INFO · Placeholder candidate contains no finding

- **Candidates:** CC-0750
- **Provenance:** `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - local://castcircle-triage-input-3.txt:118 — the original candidate explicitly says none and to ignore the line
- **Decision:** The assigned candidate asserts no defect.
- **Recommendation:** No change required.

### R-350 · INFO · Platform STT listen errors are converted to false

- **Candidates:** CC-1142, CC-1144
- **Provenance:** `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/stt_channel.dart:95-112 — PlatformException and MissingPluginException are caught and listen returns false
  - lib/data/services/stt_service.dart:220-225 — false resets listening state and invokes completion
- **Decision:** The claimed platform exceptions do not propagate through the current SttChannel implementation, and the false path performs teardown.
- **Recommendation:** No change.

### R-351 · INFO · Play validates an incorrect upload certificate

- **Candidates:** CC-2296
- **Provenance:** `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - scripts/ship-play.sh:39-49 — script rejects debug signing and derives built certificate owner.
  - scripts/ship-play.sh:65-93 — Google Play upload enforces the registered certificate.
- **Decision:** A wrong nondebug keystore yields an explicit upload rejection, not a silently accepted release.
- **Recommendation:** No correctness change required.

### R-352 · INFO · Post-download retry is bounded by explicit events

- **Candidates:** CC-1230
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/tts_service.dart:105-130 — tryLoadKokoro runs only when explicitly called and returns after one load attempt
- **Decision:** The candidate explicitly identifies no current loop or failure.
- **Recommendation:** No change.

### R-353 · INFO · Pre-init singleton test is deterministic in its isolated test file

- **Candidates:** CC-2651, CC-2652
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - test/tts_service_test.dart:8 — preceding test only reads singleton identity
  - test/tts_service_test.dart:12 — preceding default test only reads activeEngine
  - test/tts_service_test.dart:17 — pre-init check occurs before any init call in the file
- **Decision:** Flutter test files run in isolated processes and this file has no earlier initializer, so current order does not make the assertion flaky.
- **Recommendation:** Introduce a resettable instance only if future tests initialize the singleton in the same file.

### R-354 · INFO · Pre-join roster RPC strips contact information

- **Candidates:** CC-1478
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:101 — v3 builds an explicit roster projection
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:107 — projection ends with user_id and omits contact_info
- **Decision:** The later migration specifically prevents contact_info from being returned.
- **Recommendation:** No change required.

### R-355 · INFO · Prefetch duplication has not produced divergent behavior

- **Candidates:** CC-1261
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/tts_service.dart:622-634 — live playback resolves voice, speed, and chunks
  - lib/data/services/tts_service.dart:776-794 — prefetch currently mirrors the same preparation and resolution
- **Decision:** The review identifies maintainability duplication but no current divergence or failure.
- **Recommendation:** No change.

### R-356 · INFO · Preset lookup already has a safe fallback

- **Candidates:** CC-1306
- **Provenance:** `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/models/voice_preset.dart:146-149 — byId uses orElse and returns modernAmerican.
- **Decision:** The claimed exception is absent.
- **Recommendation:** No defect fix required.

### R-357 · INFO · Preview count memoization is already sound

- **Candidates:** CC-1839, CC-1840, CC-1845
- **Provenance:** `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_import/script_import_screen.dart:178-200 — counts are computed in one pass and cached by line-list identity
  - lib/features/script_import/script_import_screen.dart:554-565 — color modulo is bounded safely
- **Decision:** These candidates explicitly dismiss the implementation or describe negligible work.
- **Recommendation:** No change.

### R-358 · INFO · Preview hash computation is negligible

- **Candidates:** CC-1865
- **Provenance:** `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_import/script_import_screen.dart:499-545 — color hashing occurs only for the at-most-30 preview lines
- **Decision:** The candidate expressly places this below the report threshold.
- **Recommendation:** No change.

### R-359 · INFO · Private MLX API compatibility is a future maintenance risk only

- **Candidates:** CC-0561
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/FallbackNetwork/BARTLayerNorm.swift:11 — current code calls _updateInternal
- **Decision:** The repository currently builds against its resolved MLX version; a hypothetical future API removal is not a present defect.
- **Recommendation:** Revisit when upgrading MLX.

### R-360 · INFO · Process death cannot leave a live Dart contact future

- **Candidates:** CC-0073
- **Provenance:** `gcp-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:24 — pendingResult is process-local plugin state
  - android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:67 — results are delivered through the current engine plugin instance
- **Decision:** A process death destroys both the plugin and Dart isolate, so there is no surviving Future to complete. Clearing on ordinary detach is a separate lifecycle hardening issue, not the claimed post-process-death hang.
- **Recommendation:** No change for the process-death scenario; handle ordinary detach and concurrent calls separately.

### R-361 · INFO · Production deletion uses the repository cascade

- **Candidates:** CC-0745, CC-0746, CC-0747
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/repositories/production_repository.dart:42-60 — the only production delete path removes local files and all child tables before the parent
  - lib/providers/production_providers.dart:103-105 — UI deletion calls the repository method
- **Decision:** The low-level database method is not called directly by current application code; the current organizer flow performs the manual cascade and file cleanup.
- **Recommendation:** No change.

### R-362 · INFO · Production hub cast-provider read is not a defect

- **Candidates:** CC-1506
- **Provenance:** `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/production_hub/production_hub_screen.dart:61 — init performs a one-time provider read for current hub state
- **Decision:** The candidate explicitly states this is not a finding and identifies at most one extra local read.
- **Recommendation:** No change.

### R-363 · INFO · Production ID traversal is excluded by current identity sources

- **Candidates:** CC-0987, CC-0988, CC-0989, CC-0990, CC-0991, CC-0992, CC-0993, CC-0994, CC-0995, CC-0996, CC-0997, CC-0998
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/recording_sync_service.dart:675-683 — clearCache joins the supplied production ID.
  - supabase/migrations/20260314061409_initial_schema.sql:15 — production IDs are UUID typed.
  - lib/features/home/home_screen.dart:611-617 — locally created production IDs come from Uuid.v4.
- **Decision:** Current callers cannot supply traversal IDs; the finding incorrectly transfers the free-text line-ID threat model to UUID production IDs.
- **Recommendation:** No current defect; an isWithin assertion is optional defense in depth.

### R-364 · INFO · Production OCR scoring runs only once on fresh imported lines

- **Candidates:** CC-0929, CC-0930, CC-0931, CC-0932, CC-0933, CC-0934, CC-0935
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/script_import_service.dart:179 — scores the newly imported OCR result
  - lib/data/services/script_import_service.dart:197 — runs one isolated scoreScript pass
  - lib/data/services/script_import_service.dart:200 — returns that single pass
- **Decision:** No current rescore path feeds dictionary display confidence back as native recognition confidence, so the hypothesized second-pass corruption is unreachable.
- **Recommendation:** Store signals separately if a rescore feature is later added.

### R-365 · INFO · Production-wide code intentionally selects any open role

- **Candidates:** CC-2530, CC-2531, CC-2533
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `sql-migration-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/join/join_production_screen.dart:234 — join UI intentionally shows available characters to any valid-code user
  - lib/features/join/join_production_screen.dart:323 — unclaimed invitations are explicitly presented as selectable roles
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:159 — claim requires the production-wide code
- **Decision:** Current product semantics deliberately let a code holder pick an unclaimed cast role; there is no per-invitee token/identity invariant to violate. Elevated organizer invitations are not created by current UI flows.
- **Recommendation:** Change product/invitation identity model first if person-specific seats are required.

### R-366 · INFO · Progress aggregation duplication has no current failure

- **Candidates:** CC-1496, CC-1497
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/onboarding/model_setup_screen.dart:108 — voice aggregation is explicit
  - lib/features/onboarding/model_setup_screen.dart:185 — matching aggregation has intentionally different error handling later
- **Decision:** Duplication alone is maintenance risk; the candidate identifies no incorrect current aggregate.
- **Recommendation:** Optional helper extraction.

### R-367 · INFO · Progress timestamp dictionary is bounded by the fixed model catalog

- **Candidates:** CC-0346, CC-0347, CC-0348, CC-0349, CC-0350
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/BackgroundDownloadPlugin.swift:232 — one small tuple is retained per modelId
  - lib/data/services/model_download_service.dart:107 — downloads originate from a fixed availableModels catalog
- **Decision:** The map cannot grow with chunks or time for normal callers, and suppressing an early same-model event for under 0.3 seconds is not a functional failure.
- **Recommendation:** No change required; cleanup would be cosmetic.

### R-368 · INFO · Progress-throttle map is bounded by the static model catalog

- **Candidates:** CC-2073, CC-2074, CC-2075, CC-2099, CC-2100
- **Provenance:** `db-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - macos/Runner/BackgroundDownloadPlugin.swift:10 — map is keyed by modelId
  - lib/data/services/model_download_service.dart:214 — model IDs come from a fixed catalog
- **Decision:** Entries are tiny and bounded by the small static catalog, not by download attempts. Stale state can at most suppress a progress callback for 0.3 seconds.
- **Recommendation:** Clear entries on terminal callbacks as hygiene, not as a leak fix.

### R-369 · INFO · Proposed stop/enqueue race has no async interleaving point

- **Candidates:** CC-0814, CC-0815
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/kokoro_onnx_service.dart:206 — availability is checked after cache awaits
  - lib/data/services/kokoro_onnx_service.dart:209 — request construction follows synchronously
  - lib/data/services/kokoro_onnx_service.dart:230 — enqueue follows synchronously
  - lib/data/services/kokoro_onnx_service.dart:236 — the next await is only after enqueue and pump
- **Decision:** Dart cannot run stop or onDone between the guard and enqueue because that section contains no await/event-loop yield; once enqueued, stop and onDone both drain visible pending requests.
- **Recommendation:** No change for this race.

### R-370 · INFO · Prosody branch similarity is not a current numerical bug

- **Candidates:** CC-0476
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroVendored/TTSEngine/ProsodyPredictor.swift:121-151 — F0 and N branches intentionally use separate blocks and projections.
- **Decision:** No current divergence from the model architecture is shown.
- **Recommendation:** No change.

### R-371 · INFO · Punctuation-only TTS silence is not a demonstrated contract violation

- **Candidates:** CC-0547
- **Provenance:** `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/EnglishG2P.swift:193-200 — empty and non-alphanumeric strings are deliberately rejected before NLTagger
  - ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:186-190 — empty tokenization is rejected as invalid input
- **Decision:** The current engine deliberately does not synthesize punctuation or emoji alone; no caller contract requires those symbols to produce speech.
- **Recommendation:** No change required unless product requirements define spoken punctuation.

### R-372 · INFO · Raw unknown locale label is intentional

- **Candidates:** CC-1851
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_import/script_import_screen.dart:320-329 — known locales get labels and others deliberately display the stored locale string
- **Decision:** No defect is asserted.
- **Recommendation:** No change.

### R-373 · INFO · Re-recording reuses the same audio path

- **Candidates:** CC-0800
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/recording_studio/recording_studio_screen.dart:181 — current code documents that re-recording reuses the filename
  - lib/features/recording_studio/recording_studio_screen.dart:187 — the replacement row stores that reused path
- **Decision:** Replacing the database row does not orphan a prior distinct WAV on the current recording-studio path because the file path is reused/overwritten.
- **Recommendation:** No change for this claim.

### R-374 · INFO · Reading ValueNotifier.value after dispose is permitted

- **Candidates:** CC-1536
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/recording_studio/recording_studio_screen.dart:92-111 — dispose reads stored value but does not add listeners or notify.
- **Decision:** ValueNotifier value getter remains a field read; the claimed assertion does not occur.
- **Recommendation:** No change.

### R-375 · INFO · Recognizer RMS callback traffic is bounded and ordinary

- **Candidates:** CC-0028, CC-0029, CC-0030
- **Provenance:** `android-performance-review@deepinfra-zai-org-glm-5.3-flash`, `kotlin-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:161 — one small level event is emitted per platform RMS callback
- **Decision:** The producer cadence is platform-bounded and the candidate shows no backlog, frame loss, or other current failure.
- **Recommendation:** No change required unless profiling shows pressure.

### R-376 · INFO · record_linux override is a future dependency hygiene note

- **Candidates:** CC-2157, CC-2158, CC-2159, CC-2160
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - pubspec.yaml:37 — record is the direct package
  - pubspec.yaml:97 — record_linux is overridden to a hosted compatible range
- **Decision:** The lock resolves a current hosted version and no Linux build/runtime incompatibility is demonstrated. Missing rationale is maintainability, not a present failure.
- **Recommendation:** Add a rationale/removal condition when next touching the dependency; no bug fix required.

### R-377 · INFO · Recorded-count scan is bounded to visible rows

- **Candidates:** CC-1533
- **Provenance:** `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/recording_studio/recording_character_screen.dart:84 — rows use ListView.builder
  - lib/features/recording_studio/recording_character_screen.dart:91 — each visible row scans only that character’s indexed lines
- **Decision:** The current implementation no longer rescans the whole script and typical visible work is small; no frame failure is demonstrated.
- **Recommendation:** No change required.

### R-378 · INFO · Recording cache deletion test exercises its contract

- **Candidates:** CC-2579
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - test/recording_sync_service_test.dart:401-430 — test deletes cache, resyncs, and verifies redownload.
- **Decision:** Candidate confirms behavior is exercised.
- **Recommendation:** No change.

### R-379 · INFO · Recording DELETE policy was added by a later migration

- **Candidates:** CC-1584
- **Provenance:** `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260703170000_recordings_delete_policy.sql:6 — users-delete-own policy is created
  - supabase/migrations/20260703170000_recordings_delete_policy.sql:7 — policy applies to DELETE
  - supabase/migrations/20260703170000_recordings_delete_policy.sql:10 — user ownership is enforced
- **Decision:** The browser comment is stale, but the current migration chain does include the required DELETE authorization.
- **Recommendation:** Update the stale comment separately; no missing-policy bug remains.

### R-380 · INFO · Recording line IDs are UUID-backed and cannot be short

- **Candidates:** CC-1586, CC-1587
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260314120000_add_script_lines.sql:6 — cloud script line id is UUID
  - lib/data/services/script_parser.dart:1381 — locally parsed line IDs are UUID v4
  - lib/features/recording_studio/recordings_browser_screen.dart:648 — eight-character log abbreviation consumes those IDs
- **Decision:** Both local and cloud line ID sources enforce UUID-length identifiers, so a shorter value is not a reachable recording row.
- **Recommendation:** No change; retain schema validation at sync boundaries.

### R-381 · INFO · Recording state is removed synchronously before Dismissible completes

- **Candidates:** CC-1577
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/providers/production_providers.dart:146 — remove captures the row
  - lib/providers/production_providers.dart:148 — comment documents Dismissible ordering
  - lib/providers/production_providers.dart:153 — provider state removes the row before the repository await
  - lib/features/recording_studio/recordings_browser_screen.dart:501 — browser awaits that implementation
- **Decision:** The current notifier was migrated specifically to prevent the dismissed widget from remaining in the tree; a later database failure does not reinsert it in the current frame.
- **Recommendation:** No change.

### R-382 · INFO · Redundant scan is a micro-optimization only

- **Candidates:** CC-1216
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/sync_queue.dart:320 — enqueue performs two any scans before two removeWhere scans
- **Decision:** Queue sizes are small and this does not alter behavior or create a failure.
- **Recommendation:** No change required.

### R-383 · INFO · Reference correlation order is deterministic in the current evaluator

- **Candidates:** CC-0257
- **Provenance:** `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/tts_kokoro_compare_macos_test.dart:33-36 — fp32 is the first entry in the insertion-ordered map
  - integration_test/tts_kokoro_compare_macos_test.dart:139-206 — iteration stores fp32 references before evaluating fp16
- **Decision:** Dart map literals preserve insertion order, and current source fixes fp32 before fp16. A hypothetical future reorder is not a current failure.
- **Recommendation:** No change required; an explicit reference-first phase would only be defensive.

### R-384 · INFO · Rehearsal invalidates restart generation before the next capture

- **Candidates:** CC-1159
- **Provenance:** `gcp-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:2629-2636 — line advance invokes SttService.stop, which increments generation, before the next line starts
  - lib/data/services/stt_service.dart:232-245 — stop invalidates delayed restart callbacks
- **Decision:** The current transition does not enter startLineCapture with an old continuous restart still generation-valid.
- **Recommendation:** No change.

### R-385 · INFO · Rehearsal model test correctly specifies its production threshold

- **Candidates:** CC-2580
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/models/rehearsal_models.dart:36 — struggledLines contract is below threshold
  - lib/data/models/rehearsal_models.dart:38 — production threshold is 0.7
  - test/rehearsal_models_test.dart:63 — test names that exact boundary
  - test/rehearsal_models_test.dart:160 — skipped fixture is simply asserted below the same contract
- **Decision:** A test should change when the production contract changes; using the same explicit boundary is not a silent defect.
- **Recommendation:** No change; extract a shared constant only if threshold is meant to be configurable.

### R-386 · INFO · Rehearsal screen size is not itself a functional defect

- **Candidates:** CC-1604
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:64 — one State owns the rehearsal UI and lifecycle
  - lib/features/rehearsal/rehearsal_screen.dart:2884 — capture logic is a private section of that state
- **Decision:** A large stateful screen raises maintenance cost but does not prove a current failure.
- **Recommendation:** Refactor only around concrete, tested state-machine boundaries.

### R-387 · INFO · Rename controller is not retained after dialog closes

- **Candidates:** CC-1675
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/character_manager_screen.dart:330 — controller is local to the rename invocation
  - lib/features/script_editor/character_manager_screen.dart:332 — its only owner is the dialog route
- **Decision:** After the dialog is popped no screen field retains the controller, so it is collectible; the claimed screen-lifetime accumulation is not established.
- **Recommendation:** Optional stateful dialog with explicit dispose for hygiene.

### R-388 · INFO · Rename decoding cost is one user action

- **Candidates:** CC-1325
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/voice_config_service.dart:319-349 — rename performs three small serialized preference migrations once.
- **Decision:** No performance failure is demonstrated.
- **Recommendation:** No defect fix required.

### R-389 · INFO · Rename-to-existing preserves target voice settings

- **Candidates:** CC-1676
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/character_manager_screen.dart:357 — rename and merge intentionally share _applyRename
  - lib/data/services/voice_config_service.dart:317 — target settings explicitly win during a merge
  - lib/data/services/voice_config_service.dart:329 — moved override is applied only when target has none
- **Decision:** Renaming onto an existing name behaves as a merge and does not overwrite the target settings as claimed. The UI already offers the same merge operation explicitly.
- **Recommendation:** Optionally warn that an existing name will merge, but no stated data-overwrite bug remains.

### R-390 · INFO · Repeated join does not hit the removed unique constraint

- **Candidates:** CC-2528
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/migrations/20260315_cast_join_code.sql:20 — cast_members_production_id_user_id_key was explicitly dropped
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:137 — the insert therefore creates another row instead of the claimed conflict
- **Decision:** The candidate’s raw-500 failure mode depends on a unique constraint that current migrations removed. Duplicate creation is real and classified separately.
- **Recommendation:** Address duplicates with a restored constraint/idempotent RPC.

### R-391 · INFO · Repeated OCR null assertion still fails the test correctly

- **Candidates:** CC-0237
- **Provenance:** `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/ocr_page_repeat_macos_test.dart:51 — a null repeat result triggers a test failure at the null check
- **Decision:** A null-check exception is less tailored than an expect message but cannot make the regression pass or affect production.
- **Recommendation:** Optionally add an explicit expect before dereferencing for clearer diagnostics.

### R-392 · INFO · Repeated ParsedScript reconstruction is maintenance-only

- **Candidates:** CC-1666
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/character_manager_screen.dart:258 — current mutation explicitly preserves all ParsedScript fields
  - lib/features/script_editor/scene_editor_screen.dart:390 — scene mutation likewise preserves the full current model
- **Decision:** No current field is dropped; the candidate predicts a future model-extension mistake rather than a current failure.
- **Recommendation:** Optional shared copy/helper when the model changes.

### R-393 · INFO · Repeated stem probes are bounded CPU duplication

- **Candidates:** CC-0598, CC-0599
- **Provenance:** `ios-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/Lexicon/Lexicon.swift:177-208 — capitalized unknown words may probe stems twice, but token count is bounded.
- **Decision:** No correctness failure or measured latency regression is established.
- **Recommendation:** No defect fix required.

### R-394 · INFO · Repeated test staging constants are not a current failure

- **Candidates:** CC-0217, CC-0220
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - integration_test/kokoro_pack_smoke_macos_test.dart:13 — the repo-root override is documented locally
  - integration_test/kokoro_pack_smoke_macos_test.dart:50 — the resampler is private to this integration test
- **Decision:** Duplication creates possible future maintenance work, but the current constants and helper are internally consistent and no trigger demonstrates incorrect behavior.
- **Recommendation:** No correctness change; consolidate only during a deliberate test-utility cleanup.

### R-395 · INFO · Repository recording deletion has no file-leaking caller

- **Candidates:** CC-0801, CC-0802
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/providers/production_providers.dart:146 — notifier.remove is the only repository deletion path
  - lib/features/recording_studio/recordings_browser_screen.dart:501 — the only caller removes the row through the notifier
  - lib/features/recording_studio/recordings_browser_screen.dart:517 — that caller then deletes recording.localPath
- **Decision:** The low-level method deletes only the row, but every current caller also deletes the file; no realistic current orphan trigger exists. Re-recording uses the same path separately.
- **Recommendation:** Keep ownership explicit or fold file deletion into one API if new callers are added.

### R-396 · INFO · Required O pronunciation exists in both shipped lexicons

- **Candidates:** CC-0602, CC-0603, CC-0604, CC-0605, CC-0606, CC-0607, CC-0608, CC-0609, CC-0610, CC-0611, CC-0612, CC-0613, CC-0614, CC-0615, CC-0616, CC-0617, CC-0618, CC-0619
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/Lexicon/Lexicon.swift:531-535 — force cast is reached for a zero tens digit; current resources contain O at us_gold.json:6066 and gb_gold.json:6235.
- **Decision:** The claimed nil requires O to be absent, which is false for the exact shipped resources.
- **Recommendation:** No defect fix required.

### R-397 · INFO · Required OCR fixture exists in the repository

- **Candidates:** CC-2577
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - test/pp_ocr_attribution_test.dart:15-19 — setUpAll intentionally loads the real regression fixture
  - test/fixtures/pp_ocr_raw.txt:1 — the assigned fixture is present
- **Decision:** This is a required checked-in regression corpus, not an optional environment fixture; silently skipping when it disappears would weaken the test.
- **Recommendation:** No change.

### R-398 · INFO · Resume metadata read is not a multi-gigabyte main-thread read

- **Candidates:** CC-0329, CC-0330
- **Provenance:** `ios-performance-review@deepinfra-zai-org-glm-5.3-flash`, `metal-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/BackgroundDownloadPlugin.swift:153 — Data(contentsOf:) reads URLSession resume metadata, not the partial downloaded payload
- **Decision:** URLSession resume data is a small request/state blob; the transferred bytes are managed separately by the system. The claimed multi-GB synchronous read is invalid.
- **Recommendation:** No change required.

### R-399 · INFO · Retry reset does not resurrect an exhausted job

- **Candidates:** CC-1195, CC-1196
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/sync_queue.dart:73 — restored in-flight jobs reset retryCount
  - lib/data/services/sync_queue.dart:429 — a fifth failure is not re-added to failed or persisted
- **Decision:** A job that actually reaches five attempts is removed before persistence and cannot return next launch. Reset only applies to jobs interrupted before exhaustion.
- **Recommendation:** No change required.

### R-400 · INFO · Roster fallback remains protected by current RLS

- **Candidates:** CC-1477
- **Provenance:** `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/supabase_service.dart:263 — RPC failure falls back to a direct cast_members select
  - supabase/migrations/20260703140000_security_lockdown.sql:101 — direct cast reads require production membership
- **Decision:** A pre-join caller is not a member, so the fallback fails closed/returns no rows rather than broadening access.
- **Recommendation:** Prefer failing explicitly for clearer UX, but no unauthorized read is verified.

### R-401 · INFO · Rounded cache speeds cannot collide through current controls

- **Candidates:** CC-0386
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroMLXService.swift:322-331 — cache keys round speed to two decimals
  - lib/features/settings/settings_screen.dart:152-188 — shipped speed controls produce quarter-step values
- **Decision:** The key is lossy in the abstract, but current settings only produce values separated by much more than 0.01, so no realistic current collision exists.
- **Recommendation:** No change.

### R-402 · INFO · RunnerTests file is an explicit placeholder, not false coverage

- **Candidates:** CC-2139, CC-2140, CC-2141, CC-2142, CC-2143, CC-2144, CC-2145, CC-2146, CC-2147, CC-2148, CC-2149, CC-2150, CC-2151, CC-2152, CC-2153
- **Provenance:** `db-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `db-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `sql-migration-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - macos/RunnerTests/RunnerTests.swift:7 — the sole method is named generic testExample
  - macos/RunnerTests/RunnerTests.swift:8 — its comment explicitly asks future contributors to add tests
  - macos/RunnerTests/RunnerTests.swift:10 — the body performs no assertion or production call
- **Decision:** The test is weightless template code, but it does not claim to exercise any plugin; a hypothetical plugin regression is not a current failure caused or masked by a named contract.
- **Recommendation:** Delete the placeholder during test-target cleanup; add behavior tests only for uncovered contracts.

### R-403 · INFO · Running-stat defects are unreachable in shipped inference

- **Candidates:** CC-0410, CC-0411, CC-0412
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroVendored/BuildingBlocks/InstanceNorm1d.swift:21-27 — trackRunningStats defaults false
  - ios/Runner/KokoroVendored/BuildingBlocks/InstanceNorm1d.swift:68-82 — disputed updates execute only with trackRunningStats and training
- **Decision:** No current construction enables the running-stat path, so the proposed shape/statistics failures are latent unsupported configurations rather than current defects.
- **Recommendation:** No change.

### R-404 · INFO · Same-volume cache rename is not a demonstrated UI failure

- **Candidates:** CC-0821
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/kokoro_onnx_service.dart:238 — fresh WAV is adopted on the same filesystem
  - lib/data/services/kokoro_onnx_service.dart:240 — renameSync performs a metadata rename
- **Decision:** The operation is a same-filesystem metadata rename of one file; no realistic latency or frame failure is demonstrated.
- **Recommendation:** Optional asynchronous cleanup, not a verified bug.

### R-405 · INFO · Sample corpus directory is present in the current repository

- **Candidates:** CC-2582, CC-2583, CC-2584
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `testing-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - test/sample_script_test.dart:203 — corpus group checks sample-scripts
  - sample-scripts/pg37431.txt:1 — the repository contains the corpus directory/files
- **Decision:** The bare-return weakness requires the directory to be absent; it is checked in and available to current test runs, so no current coverage vanishes.
- **Recommendation:** Fail loudly if the corpus becomes optional/external in CI.

### R-406 · INFO · Sample serialization copies are bounded by model input limits

- **Candidates:** CC-2825
- **Provenance:** `ios-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - tools/mlx-harness/Sources/harness/main.swift:109 — Data is preallocated for the sample byte count before append
  - ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:270 — synthesis input is capped by maxTokenCount
- **Decision:** There is an avoidable intermediate Data copy, but the candidate’s ten-minute/unbounded synthesis scenario is not reachable under the model token limit and no failure is demonstrated.
- **Recommendation:** Optimize only if harness profiling makes this material.

### R-407 · INFO · Scalar loudness pass has no demonstrated user-visible failure

- **Candidates:** CC-0316, CC-0317
- **Provenance:** `simd-accelerate-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `simd-accelerate-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/AudioAnalysisPlugin.swift:41 — analysis runs on a global background queue
  - lib/data/services/audio_level_service.dart:37 — results are cached by path
- **Decision:** The loop is linear, off the main thread, and runs once per uncached recording. The candidates provide estimates, not a current failure or measured bottleneck.
- **Recommendation:** Consider Accelerate only if profiling shows this background pass matters.

### R-408 · INFO · Scalar RMS and 12 Hz level delivery have no demonstrated bottleneck

- **Candidates:** CC-0296, CC-0297, CC-0298, CC-0308
- **Provenance:** `ios-performance-review@deepinfra-zai-org-glm-5.3-flash`, `metal-performance-review@deepinfra-zai-org-glm-5.3-flash`, `simd-accelerate-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `simd-accelerate-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/AppleSttPlugin.swift:316 — the source bounds delivery at about 12 events per second
  - ios/Runner/AppleSttPlugin.swift:619 — RMS processes one channel and one tap buffer
  - ios/Runner/AppleSttPlugin.swift:625 — the loop performs roughly one multiply-add per input sample
- **Decision:** About 48,000 scalar operations per second and 12 main-queue notifications are bounded and no current realistic trigger establishes a user-visible overrun. The risk claim is speculative.
- **Recommendation:** No change; optimize only with profiling evidence.

### R-409 · INFO · Scalar silence analysis is acceptable for intended short take files

- **Candidates:** CC-2326, CC-2327
- **Provenance:** `ios-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/test_silence_trim.swift:6 — the script is a one-off audio trim diagnostic
  - scripts/test_silence_trim.swift:49 — work is linear in decoded samples
  - scripts/test_silence_trim.swift:54 — the sample buffer is retained and reused per fixed window
- **Decision:** The minutes/hour-long recordings used to claim a failure are outside the take-sized diagnostic workflow; no current timeout or measured issue is shown.
- **Recommendation:** No change absent profiling on intended fixtures.

### R-410 · INFO · Scene rename controllers are dialog-scoped

- **Candidates:** CC-1705, CC-1706
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/scene_editor_screen.dart:191 — controllers are local variables
  - lib/features/script_editor/scene_editor_screen.dart:194 — the dialog route is their only owner
- **Decision:** No long-lived state retains the controllers after pop; app-lifetime accumulation is not established.
- **Recommendation:** Optional stateful dialog disposal for hygiene.

### R-411 · INFO · Scene row counting slices only that scene

- **Candidates:** CC-1661, CC-1704
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/scene_editor_screen.dart:73 — each realized row calls linesInScene once
  - lib/data/models/script_models.dart:368 — linesInScene clamps and sublists the scene range rather than scanning the full script
- **Decision:** Scene ranges partition the script; visible rows do not each scan every line as claimed. The cost is proportional to lines in realized scenes, not scenes × full script.
- **Recommendation:** Profile before adding another cache.

### R-412 · INFO · Scene-count memo is correctly keyed and reused

- **Candidates:** CC-1511, CC-1512, CC-1513
- **Provenance:** `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/production_hub/production_hub_screen.dart:392 — cache key contains actual lines/scenes lists and selected character
  - lib/features/production_hub/production_hub_screen.dart:393 — identity/equality checks return the cached counts
  - lib/features/production_hub/production_hub_screen.dart:409 — key is retained after recomputation
- **Decision:** Unrelated provider rebuilds do not replace script.lines/script.scenes identity, so the cache survives them. A character change legitimately changes “my lines” counts and causes one linear recount.
- **Recommendation:** No change absent profiling evidence.

### R-413 · INFO · Script line IDs cannot contain path traversal

- **Candidates:** CC-1649, CC-1650, CC-1651
- **Provenance:** `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/script_parser.dart:1381 — local parser generates UUID v4 IDs
  - supabase/migrations/20260314120000_add_script_lines.sql:6 — cloud script line IDs are UUID columns
  - lib/features/rehearsal/rehearsal_screen.dart:3003 — filenames interpolate only those UUID-backed IDs
- **Decision:** Both trust-boundary sources constrain IDs to UUIDs, excluding slashes and dot segments.
- **Recommendation:** No change.

### R-414 · INFO · Script-specific cast lists are intentionally different

- **Candidates:** CC-2207
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/parse_script.py:43-45 — this reference parser labels its cast as extracted for this script
- **Decision:** Different play utilities use different casts; duplication alone does not prove a current parsing failure.
- **Recommendation:** No change.

### R-415 · INFO · Second preferences lookup cannot reuse a later-scoped variable

- **Candidates:** CC-2052
- **Provenance:** `flutter-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/main.dart:125-147 — the microtask is declared before the prefs local exists
  - lib/main.dart:149-164 — ProviderScope-critical preferences are obtained later
- **Decision:** The later local is out of scope at closure creation; sharing it requires reordering startup, not simply passing an already-read value. SharedPreferences also caches its singleton.
- **Recommendation:** No change required for this negligible lookup.

### R-416 · INFO · Security review reported no applicable defect

- **Candidates:** CC-0002
- **Provenance:** `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroMLXService.swift:157 — synthesis is an on-device service entry point with no network/auth sink
- **Decision:** The candidate is expressly a clean review result, not a defect.
- **Recommendation:** No change.

### R-417 · INFO · Sequential join setup is a one-shot bounded flow

- **Candidates:** CC-1483
- **Provenance:** `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/join/join_production_screen.dart:474 — membership mutation precedes dependent local setup
  - lib/features/join/join_production_screen.dart:545 — script sync follows membership/local saves
- **Decision:** Most awaits are ordered by data/consistency dependencies, and the candidate itself reports no threshold breach.
- **Recommendation:** No change required.

### R-418 · INFO · Sequential OCR repeat coverage is intentional

- **Candidates:** CC-0236
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/ocr_page_repeat_macos_test.dart:29 — deliberately mixes repeated and distinct pages in a sequential loop
- **Decision:** The sequence exercises repeat behavior and is not itself a failure.
- **Recommendation:** No change.

### R-419 · INFO · Serial completion assertion is intentional

- **Candidates:** CC-0223, CC-0226
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/kokoro_service_queue_macos_test.dart:72 — exact completion order is the serial-queue contract
  - integration_test/kokoro_service_queue_macos_test.dart:88 — stale urgent cancellation is an explicit observable contract
- **Decision:** These assertions deliberately test product semantics; they are not defects.
- **Recommendation:** No change required.

### R-420 · INFO · Serial upload drain is an intentional bounded strategy

- **Candidates:** CC-1218, CC-1219
- **Provenance:** `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/sync_queue.dart:370 — jobs are processed serially
  - lib/data/services/recording_sync_service.dart:356 — bulk reconciliation already uses a pool where parallelism is appropriate
- **Decision:** The offline queue prioritizes ordering and low mobile resource use; slower drain alone is not a correctness failure.
- **Recommendation:** No change unless measured product requirements demand bounded concurrency.

### R-421 · INFO · Shared edit-distance rows are safe in Dart isolate execution

- **Candidates:** CC-1191
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/stt_vocabulary_service.dart:434 — edit distance is synchronous
  - lib/data/services/stt_vocabulary_service.dart:475 — the buffers are documented as synchronous and non-reentrant
  - lib/data/services/stt_vocabulary_service.dart:478 — state is isolate-local static Dart state
- **Decision:** Current callers cannot interleave synchronous executions within one isolate, and other isolates do not share these statics.
- **Recommendation:** No change.

### R-422 · INFO · Shared ONNX Runtime sessions are not proven unsafe

- **Candidates:** CC-0668, CC-0669, CC-0671
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/PaddleOcrPlugin.swift:143 — requests are dispatched concurrently
  - ios/Runner/PaddleOcrPlugin.swift:243 — inference only reads the shared session references
- **Decision:** The candidates assert that ORTSession.run is unsafe without evidence; ONNX Runtime sessions support concurrent Run calls. Memory contention is possible but no current failure is demonstrated.
- **Recommendation:** Add serialization only if device profiling or an ORT-specific limitation requires it.

### R-423 · INFO · Shared timing fields are not raced by current callers

- **Candidates:** CC-0132
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/script_import_service.dart:357-371 — the current full-document import awaits a single OCR request at a time
- **Decision:** The fields are shared, but the hypothesized concurrent OCR jobs are not reachable through current flows; log misattribution is therefore not proven.
- **Recommendation:** No change.

### R-424 · INFO · SharedPreferences and demo hold are intentional integration behavior

- **Candidates:** CC-0239, CC-0243
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/rehearsal_demo_test.dart:35 — preferences are intentionally set to enter screenshot mode
  - integration_test/rehearsal_demo_test.dart:94 — the comment explicitly identifies the 36-second external recording hold
- **Decision:** These are deliberate device-integration operations, not defects in the harness contract.
- **Recommendation:** No change.

### R-425 · INFO · Signup trigger fully qualifies its only application relation

- **Candidates:** CC-2416, CC-2417, CC-2418, CC-2419
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/migrations/20260314061409_initial_schema.sql:24 — handle_new_user is the trigger function
  - supabase/migrations/20260314061409_initial_schema.sql:27 — its insert target is explicitly public.profiles
  - supabase/migrations/20260314061409_initial_schema.sql:31 — the function is SECURITY DEFINER
- **Decision:** Pinning search_path is defense-in-depth, but the alleged relation-shadow redirect is impossible because public.profiles is schema-qualified and the body invokes no attacker-shadowable application object.
- **Recommendation:** Optionally pin search_path for consistency; no verified exploit fix is required.

### R-426 · INFO · Silver lexicon fallback is logged and resources exist

- **Candidates:** CC-0593
- **Provenance:** `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/Lexicon/DataResourcesUtil.swift:18-34 — silver load failure emits NSLog before returning empty.
  - ios/Runner/MisakiVendored/Resources/us_silver.json:1 — the current resource is bundled.
- **Decision:** The alleged silent missing-resource state is absent and the fallback is not silent at source level.
- **Recommendation:** No change.

### R-427 · INFO · SineGen batch-shape concern is unreachable in the app

- **Candidates:** CC-0438
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroVendored/Decoder/SineGen.swift:45 — phase seed shape derives from current batch and harmonics
  - ios/Runner/KokoroVendored/Decoder/SineGen.swift:47 — it is added to the first time slice
  - ios/Runner/KokoroVendored/Decoder/SineGen.swift:65 — SineGen is used by the utterance synthesis path
- **Decision:** The candidate concedes the pipeline always synthesizes one utterance, so the asserted batch-greater-than-one failure has no current trigger.
- **Recommendation:** Revisit only if batched utterance synthesis is introduced.

### R-428 · INFO · Single total-line scan is bounded and allocation-light

- **Candidates:** CC-1397, CC-1398
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/cast_manager/cast_manager_screen.dart:195 — build performs one linear dialogue count over script lines
  - lib/features/cast_manager/cast_manager_screen.dart:215 — heavier per-character line grouping is already memoized
- **Decision:** One linear scan of a few thousand local objects per rebuild is not a realistic user-visible failure by itself; the recording/card rebuild issue is classified separately.
- **Recommendation:** Optional cache only if profiling shows significance.

### R-429 · INFO · Single-page OCR intentionally has no caller scale

- **Candidates:** CC-0677
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/paddle_ocr_channel.dart:71 — ocrPage accepts only path and page
  - ios/Runner/PaddleOcrPlugin.swift:226 — single-page rendering computes its own display/highlight scale
- **Decision:** There is no ignored scale argument on ocrPdfPage; only whole-document OCR exposes scale.
- **Recommendation:** Optionally extract a shared sizing helper without treating this as a broken contract.

### R-430 · INFO · Singleton identity test can detect a fresh-instance regression

- **Candidates:** CC-2547, CC-2548, CC-2549, CC-2550
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - test/model_manager_test.dart:7 — evaluates ModelManager.instance twice under identical
  - lib/data/services/model_manager.dart:20 — current implementation is a static final singleton
- **Decision:** If instance were changed to return a fresh object per access, identical would be false. The test is narrow, but the candidates claiming it can never fail are wrong.
- **Recommendation:** Add functional model-path coverage separately; keep or drop the singleton contract test based on value.

### R-431 · INFO · Small debug-map and token-list allocations are bounded

- **Candidates:** CC-1181, CC-1182
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/stt_vocabulary_service.dart:252 — getActorCorrections is a debug/display accessor
  - lib/data/services/stt_vocabulary_service.dart:294 — correction splits one recognized line
  - lib/data/services/stt_vocabulary_service.dart:322 — the temporary list is immediately joined
- **Decision:** These operations are bounded by a single line or an explicit diagnostic read and do not demonstrate a current failure.
- **Recommendation:** No change.

### R-432 · INFO · Small Lexicon constant-factor work has no demonstrated impact

- **Candidates:** CC-0594, CC-0596, CC-0597
- **Provenance:** `ios-performance-review@deepinfra-zai-org-glm-5.3-flash`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/Lexicon/Lexicon.swift:141-161,333-343,451-465 — scans are bounded by a 510-token synthesis and small constant collections.
- **Decision:** The candidates identify micro-optimizations without a measured user-visible failure.
- **Recommendation:** No defect fix required.

### R-433 · INFO · Small List queue operations are negligible

- **Candidates:** CC-0819
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/kokoro_onnx_service.dart:42 — queue is a List
  - lib/data/services/kokoro_onnx_service.dart:230 — urgent insertion is at index zero
  - lib/data/services/kokoro_onnx_service.dart:317 — dequeue removes index zero
- **Decision:** The candidate itself bounds realistic depth at a handful of requests and identifies no observable failure.
- **Recommendation:** Use ListQueue only if profiling shows meaningful queue depth.

### R-434 · INFO · Speak path already catches TTS failures

- **Candidates:** CC-1949
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/kokoro_debug_screen.dart:117 — speak operations are inside try
  - lib/features/settings/kokoro_debug_screen.dart:121 — failures are caught
  - lib/features/settings/kokoro_debug_screen.dart:122 — the error is written to the status log
- **Decision:** The candidate identifies the current behavior as correct.
- **Recommendation:** No change.

### R-435 · INFO · Spell checker dependencies are pinned in the current lockfile

- **Candidates:** CC-0918
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - pubspec.lock:1281 — pins simple_spell_checker 1.3.1
  - pubspec.lock:1282 — records simple_spell_checker_en_lan as a direct dependency
- **Decision:** The candidate premise that versions were unavailable is false for the current repository.
- **Recommendation:** Review dependency health separately during dependency maintenance.

### R-436 · INFO · Stale force-cast finding is absent from current EnglishG2P

- **Candidates:** CC-0555
- **Provenance:** `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/EnglishG2P.swift:496-510 — the current file ends without the cited line-534 lookup force-cast
- **Decision:** The alleged lookup("O") force-cast no longer exists in the current file.
- **Recommendation:** No change required.

### R-437 · INFO · Stale getNNP findings target code no longer present

- **Candidates:** CC-0551, CC-0552
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/EnglishG2P.swift:302-324 — current lines contain foldLeft/subtokenize, not getNNP or optional pieces
- **Decision:** The cited compactMap and nil check are absent from the current implementation.
- **Recommendation:** No change required.

### R-438 · INFO · Stale Kokoro calls do not swallow the newer speak

- **Candidates:** CC-1239
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/tts_service.dart:653-685 — only the older generation returns early when stale; the newer speak owns the increment and executes independently
- **Decision:** The candidate reverses which invocation is discarded.
- **Recommendation:** No change.

### R-439 · INFO · Stale Kroko temp files cannot mask a missing required model

- **Candidates:** CC-2255, CC-2256, CC-2257, CC-2258, CC-2259
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `shell-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/phone-harness.sh:46 — the script enumerates exactly four required model names
  - scripts/phone-harness.sh:47 — each current source file must exist or the run exits
  - scripts/phone-harness.sh:48 — every required file is overwritten into staging before push
- **Decision:** Old extras may remain, but they cannot substitute for a missing current required file because the explicit pre-copy existence guard fails first; the claimed false readiness trigger is absent.
- **Recommendation:** Optional cleanup would improve hygiene but is not required for this failure claim.

### R-440 · INFO · Startup permission preflight prevents the claimed first-command loss

- **Candidates:** CC-0022, CC-0025, CC-0026
- **Provenance:** `android-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `kotlin-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/stt_service.dart:51 — app STT initialization invokes the native initialize preflight
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:108 — initialize requests RECORD_AUDIO before rehearsal use
- **Decision:** The permission dialog is requested during initialization, before the user can reach a capture. Later denied-permission commands fail visibly and can be retried; no pending capture is silently represented as successful.
- **Recommendation:** No native continuation is required for the current preflight flow.

### R-441 · INFO · StateProvider override remains writable

- **Candidates:** CC-2061, CC-2062
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/main.dart:159-165 — overrideWith supplies the StateProvider initializer value
  - lib/features/settings/settings_screen.dart:354-358 — current code mutates the provider notifier then navigates on sign-out
- **Decision:** Riverpod StateProvider.overrideWith changes the initial creation function; it does not replace the StateController with an immutable constant. Sign-out writes remain effective.
- **Recommendation:** No change required.

### R-442 · INFO · Stop operations are designed not to emit completion advancement

- **Candidates:** CC-1635
- **Provenance:** `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/tts_service.dart:825 — stop contract explicitly says it does not fire completion
  - lib/data/services/tts_service.dart:828 — generation is invalidated
  - lib/data/services/tts_service.dart:831 — speaking flag is cleared before stopping players
  - lib/features/rehearsal/rehearsal_screen.dart:2128 — completion also checks playingOther state
- **Decision:** The claimed stop-triggered double advances do not occur through TtsService, and just_audio stop/pause is not a completed-playback event.
- **Recommendation:** No change.

### R-443 · INFO · stop/start retry gaps are unreachable in production

- **Candidates:** CC-1214, CC-1215
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/main.dart:119 — production starts the singleton queue once
  - lib/data/services/sync_queue.dart:299 — stop exists but has no production caller
- **Decision:** Only tests call the stop lifecycle; no app path cycles it while failed/running jobs exist.
- **Recommendation:** No production change required; make test lifecycle semantics explicit if needed.

### R-444 · INFO · Stopping playback does not block rehearsal advance

- **Candidates:** CC-1256
- **Provenance:** `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:1770-1779 — processCurrentLine starts playback without awaiting it
  - lib/data/services/tts_service.dart:825-835 — stop itself awaits player stop directly and returns without awaiting chunkDone
- **Decision:** The stale speak Future may remain pending until its timeout, but the user’s stop/advance path is not waiting on it and generation checks prevent stale completion.
- **Recommendation:** No change.

### R-445 · INFO · Storage object names do not provide filesystem traversal

- **Candidates:** CC-1197
- **Provenance:** `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/supabase_service.dart:588 — slash is replaced before constructing the storage key
  - lib/data/services/supabase_service.dart:591 — the value becomes an object-store key under a validated production UUID
- **Decision:** Backslash and dot segments are literal object-key characters in Supabase Storage, not local path traversal.
- **Recommendation:** Optional: normalize names for readability; no traversal fix required.

### R-446 · INFO · Storage UPDATE new paths are rechecked and recordings rows are later fixed

- **Candidates:** CC-2467
- **Provenance:** `sql-migration-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/migrations/20260703140000_security_lockdown.sql:73 — storage UPDATE defines a USING membership predicate
  - supabase/migrations/20260703140000_security_lockdown.sql:78 — that predicate derives membership from name
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:193 — recordings rows now have an explicit new-row WITH CHECK
- **Decision:** PostgreSQL applies the USING expression as WITH CHECK when an UPDATE policy omits an explicit WITH CHECK, so a nonmember cannot rename into production B; the later migration separately closes the recordings-row repointing path.
- **Recommendation:** No change for cross-tenant repointing; object ownership remains a separate verified issue.

### R-447 · INFO · StrictMode absence is not a current failure

- **Candidates:** CC-0086
- **Provenance:** `android-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/MainActivity.kt:6-15 — MainActivity registers plugins and contains no debug StrictMode setup.
- **Decision:** The finding requests optional development instrumentation; it does not identify a failing production behavior or realistic trigger.
- **Recommendation:** No defect fix required; add debug instrumentation only as a team preference.

### R-448 · INFO · String upsampling modes have no current typo trigger

- **Candidates:** CC-0433
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroVendored/Decoder/Decoder.swift:34 — current literal is a known fixed value
- **Decision:** The candidate identifies type-safety/maintainability risk but no incorrect current literal or reachable failure.
- **Recommendation:** Use an enum during a future vendored-model cleanup.

### R-449 · INFO · STT adaptation training is an unused declared placeholder

- **Candidates:** CC-1105, CC-1106, CC-1107, CC-1108, CC-1109, CC-1110, CC-1111, CC-1112, CC-1113
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/stt_adaptation_service.dart:396 — labels the cloud operation as a future phase
  - lib/data/services/stt_adaptation_service.dart:417 — explicitly resets placeholder status
  - lib/data/services/stt_adaptation_service.dart:383 — no repository caller invokes requestActorTraining
- **Decision:** The methods do not implement training, but no UI or production caller exposes them as working. This is inactive placeholder code rather than a current user-visible failure.
- **Recommendation:** Delete the dead API until implementing training, or keep it clearly internal.

### R-450 · INFO · STT disposal does not retain screen callbacks in current flows

- **Candidates:** CC-1133, CC-1134, CC-1135, CC-1136, CC-1137, CC-1138
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/rehearsal/rehearsal_screen.dart:612 — explicitly clears interruption callback
  - lib/features/rehearsal/rehearsal_screen.dart:613 — clears route-loss callback
  - lib/features/rehearsal/rehearsal_screen.dart:622 — clears PCM callback
  - lib/data/services/stt_service.dart:441 — its dispose method has no repository caller
- **Decision:** The screen that installs these callbacks clears all of them directly, and the singleton disposal path is not invoked.
- **Recommendation:** For API completeness, dispose may clear every field, but no current stale callback is reachable.

### R-451 · INFO · Studio API URL is a local CLI setting, not a proven broken endpoint

- **Candidates:** CC-2374
- **Provenance:** `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/config.toml:88 — value belongs to local Studio configuration
  - supabase/config.toml:93 — uses the generated local host form
- **Decision:** The candidate assumes Studio directly uses port 80, but Supabase CLI injects local service routing/ports when starting the stack; no failed local Studio path is demonstrated.
- **Recommendation:** Change only if a targeted supabase start/status run shows an incorrect API endpoint.

### R-452 · INFO · Successful downloads clear stale error state

- **Candidates:** CC-1498
- **Provenance:** `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/model_download_service.dart:281 — successful completion replaces state with a new downloaded ModelDownloadState
  - lib/data/services/model_download_service.dart:71 — new state defaults errorMessage to null
- **Decision:** The candidate assumption is false: success does clear errorMessage, so _onServiceState does not retain that failed-attempt error after completion.
- **Recommendation:** No change.

### R-453 · INFO · Supabase default key is explicitly publishable client configuration

- **Candidates:** CC-2031, CC-2032, CC-2033, CC-2034, CC-2035, CC-2036, CC-2037
- **Provenance:** `db-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `sql-migration-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/main.dart:94-103 — the key has sb_publishable prefix and is passed as publishableKey
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:167-196 — current RLS constrains membership roles, debug-report ownership, and recording updates
- **Decision:** The key is designed to ship in clients and is not a service-role secret. A single production default is intentional-looking application configuration; no staging contract requiring failure on absent defines is shown.
- **Recommendation:** No secret rotation required; use build-time environment enforcement only if multiple deployment environments are supported.

### R-454 · INFO · Supabase secrets use environment substitution

- **Candidates:** CC-2375, CC-2414
- **Provenance:** `aws-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - supabase/config.toml:95 — OpenAI key uses env substitution
  - supabase/config.toml:238 — Resend key uses env substitution
  - supabase/config.toml:291 — Twilio token uses env substitution
  - supabase/config.toml:323 — Apple secret uses env substitution
- **Decision:** These candidates report the correct secret-management pattern and no exposed value.
- **Recommendation:** No change.

### R-455 · INFO · Superseded failed jobs correctly defer to the newer take

- **Candidates:** CC-1220
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/sync_queue.dart:408 — failed in-flight job detects it was replaced
  - lib/data/services/sync_queue.dart:411 — the newer take is explicitly left to drive retry
- **Decision:** A superseded old take should not emit the gave-up warning; the replacement remains queued. The candidate also incorrectly says the fifth failure is moved to failed.
- **Recommendation:** No change required.

### R-456 · INFO · Superseded takes reuse the same local file path

- **Candidates:** CC-1217
- **Provenance:** `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/recording_studio/recording_studio_screen.dart:181 — re-recording explicitly reuses the same filename
  - lib/features/rehearsal/rehearsal_screen.dart:3189 — permanent capture path is deterministic by line id
- **Decision:** Replacing the queue job does not strand a distinct previous audio file; the new take overwrites the line path.
- **Recommendation:** No change required.

### R-457 · INFO · Swift buffer rebound proportionally recounts bytes and handles empty arrays

- **Candidates:** CC-2823, CC-2824, CC-2826, CC-2827, CC-2828, CC-2829
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tools/mlx-harness/Sources/harness/main.swift:110 — Float buffer is rebound to UInt8 for Data construction
  - tools/mlx-harness/Sources/harness/main.swift:114 — identical warm encoding is used
- **Decision:** Targeted Swift runtime checks on the current toolchain produced 12 UInt8 elements from 3 Floats and 0 from an empty Float array. The claimed one-byte-per-float truncation and empty-buffer trap are invalid; withUnsafeBufferPointer also exposes the exact array storage range.
- **Recommendation:** No change required.

### R-458 · INFO · Swift String append loop is not proven quadratic

- **Candidates:** CC-2308, CC-2309, CC-2310, CC-2311
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-performance-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/test_pdf_import.swift:36,51-56 — one uniquely-owned mutable String is appended page by page
- **Decision:** Swift mutable String append uses growable storage and can append in place; the candidates assume immutable concatenation/copying without evidence. No measured stall is provided for this operator script.
- **Recommendation:** No change required; joined page arrays may improve clarity but are not a demonstrated performance fix.

### R-459 · INFO · SwiftPM lockfile pins harness resolutions

- **Candidates:** CC-2782, CC-2784, CC-2785, CC-2786
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - tools/mlx-harness/Package.swift:10-13 — manifests declare compatible ranges
  - tools/mlx-harness/Package.resolved:1 — a committed SwiftPM resolution file is present
- **Decision:** With the committed Package.resolved, normal resolved builds use exact revisions; from: ranges alone do not make each run silently float.
- **Recommendation:** Keep Package.resolved committed and update it deliberately.

### R-460 · INFO · Sync queue owns upload retries and diagnostics

- **Candidates:** CC-1537
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/recording_studio/recording_studio_screen.dart:193-203 — takes are enqueued; lib/data/services/sync_queue.dart:310-333 persists/replaces jobs.
- **Decision:** The candidate explicitly lacked queue context.
- **Recommendation:** No change.

### R-461 · INFO · Synchronous file-queue drain has no realistic backlog shown

- **Candidates:** CC-0303, CC-0304
- **Provenance:** `ios-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `mlx-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/AppleSttPlugin.swift:305 — file writes are dispatched to a dedicated serial queue
  - ios/Runner/AppleSttPlugin.swift:420 — stop synchronously drains that queue before conversion
- **Decision:** The drain is needed for file integrity; with 4096-frame buffers and ordinary local storage, the candidates provide no realistic evidence of a backlog large enough to freeze the UI.
- **Recommendation:** No change absent profiling; preserve the drain invariant if made asynchronous.

### R-462 · INFO · Synchronous recorder join is outside the normal restart path

- **Candidates:** CC-0032, CC-0033, CC-0034, CC-0035, CC-0036, CC-0037, CC-0038, CC-0061, CC-0062
- **Provenance:** `android-performance-review@deepinfra-zai-org-glm-5.3-flash`, `android-review@deepinfra-zai-org-glm-5.3-flash`, `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `kotlin-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `kotlin-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:430 — normal stop clears captureThread before returning
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:458 — the blocking join only sees a retained thread for an unsupported start-without-stop sequence
- **Decision:** Normal stop/start calls do not execute the alleged 1.5-second join because stopRecording has already nulled the field.
- **Recommendation:** No change required for current callers.

### R-463 · INFO · System TTS is stopped on actual line transitions

- **Candidates:** CC-1262
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/tts_service.dart:825-835 — stop releases both just_audio and flutter_tts
  - lib/features/rehearsal/rehearsal_screen.dart:2629-2636 — advance invokes the full TTS stop before STT starts
- **Decision:** releaseAudioSession is used after normal completion; explicit transitions that interrupt speech call stop, so the assumed active system-TTS focus leak is not reachable.
- **Recommendation:** No change.

### R-464 · INFO · Theatrical vocabulary one-shot load is appropriate for production

- **Candidates:** CC-0920
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/script_import_service.dart:193 — loads the asset after Flutter initialization during import
  - lib/data/services/ocr_confidence_service.dart:87 — explicitly treats missing assets as an optional fallback
- **Decision:** The production call is not an early-startup race, and repeatedly retrying a genuinely missing bundled asset would not recover.
- **Recommendation:** If assets become remote, distinguish transient failures then; no current change.

### R-465 · INFO · Theme duplication and asymmetric inactive theme are not failures

- **Candidates:** CC-0740, CC-0741
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/core/theme/app_theme.dart:39 — dark app-bar/card configuration is explicit
  - lib/core/theme/app_theme.dart:65 — light configuration intentionally omits dark-only surface/FAB settings
  - lib/app.dart:277 — only dark mode is active
- **Decision:** These are style/maintainability preferences and do not cause current behavior to fail.
- **Recommendation:** No change required.

### R-466 · INFO · Theme getters are evaluated only for MaterialApp construction

- **Candidates:** CC-0737, CC-0738, CC-0739
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/app.dart:275 — lightTheme is read once while constructing MaterialApp
  - lib/app.dart:276 — darkTheme is read alongside it
- **Decision:** No frequently rebuilt call site was found, so fresh ThemeData construction is not a hot-path failure.
- **Recommendation:** No change required.

### R-467 · INFO · Tokenizer behavior matches controlled bundled vocab/G2P contract

- **Candidates:** CC-0494, CC-0495, CC-0496, CC-0497, CC-0498, CC-0499, CC-0500, CC-0503
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroVendored/TextProcessing/Tokenizer.swift:18 — config accessor is optional in type
  - ios/Runner/KokoroVendored/TTSEngine/KokoroConfig.swift:21 — current config is a once-initialized static bundle value
  - ios/Runner/KokoroVendored/TTSEngine/KokoroConfig.swift:165 — missing/malformed config fails at bundle load rather than producing nil
- **Decision:** Current callers feed controlled phonemes from bundled G2P and the config cannot become nil. No actual emitted phoneme outside the pinned vocab is shown, so silent user-content loss is not proven.
- **Recommendation:** No change required; a debug assertion for unknown symbols is optional.

### R-468 · INFO · Tokenizer chain is bounded by one partial line

- **Candidates:** CC-1192
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/stt_vocabulary_service.dart:496 — tokenization processes one supplied text
  - lib/data/services/stt_vocabulary_service.dart:503 — temporaries are returned as a line-sized list
- **Decision:** The candidate itself identifies no realistic performance consequence.
- **Recommendation:** No change.

### R-469 · INFO · Tool Supabase keys are publishable, not secrets

- **Candidates:** CC-2678, CC-2679, CC-2681
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - tool/analyze_orphaned_recordings.dart:19-20 — committed key has sb_publishable prefix
  - lib/main.dart:94-103 — the same publishable key is intentionally shipped in the client
- **Decision:** The credentials are public client configuration, and no service-role key is present in the cited code. Hardcoding may reduce staging flexibility but is not credential exposure.
- **Recommendation:** No secret remediation required; environment overrides are optional ergonomics.

### R-470 · INFO · Trailing silence is intentional recognizer flushing

- **Candidates:** CC-0216
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/asr_testwav_transcript_macos_test.dart:47 — real samples are accepted first
  - integration_test/asr_testwav_transcript_macos_test.dart:48 — a zero buffer is then accepted before decode
- **Decision:** The second buffer is a conventional end-of-utterance flush and does not replace or corrupt the real samples.
- **Recommendation:** No change.

### R-471 · INFO · Two audio-level producers are intentionally calibrated

- **Candidates:** CC-0027, CC-0031, CC-0050
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:162 — recognizer RMS is deliberately mapped to the expected speech range
  - android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:371 — owned-mic peak is independently normalized for capture endpointing
- **Decision:** Raw maxima differ, but comments and consumers use speech/silence thresholds rather than assuming identical physical units; no realistic misfire is established.
- **Recommendation:** No change required; documenting the pseudo-level contract is optional.

### R-472 · INFO · UI-selected split point remains strictly inside the scene

- **Candidates:** CC-1722
- **Provenance:** `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/scene_editor_screen.dart:242 — dialogue choices come from the already-clamped scene slice
  - lib/features/script_editor/scene_editor_screen.dart:263 — slider minimum is 1
  - lib/features/script_editor/scene_editor_screen.dart:264 — maximum is dialogueLines.length - 1
  - lib/features/script_editor/scene_editor_screen.dart:311 — chosen line is therefore an interior dialogue line of that slice
- **Decision:** Stale bounds affect which slice is shown, but the chosen split line is drawn from within that same slice and cannot clamp to its endpoints under current unique order indices.
- **Recommendation:** Validate bounds defensively if orderIndex uniqueness changes.

### R-473 · INFO · Unavailable G2P engine path is not used by the app

- **Candidates:** CC-0457, CC-0458, CC-0459, CC-0460, CC-0461, CC-0462, CC-0463, CC-0464
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:68 — the default engine is Misaki.
  - ios/Runner/KokoroMLXService.swift:110-115 — the only app construction uses the default and exposes no engine selector.
- **Decision:** The swallowed eSpeakNG factory error requires a caller that current application code cannot make.
- **Recommendation:** No app defect; propagate the error if this vendored API is later exposed.

### R-474 · INFO · Uncaught MissingPluginException methods have no production caller

- **Candidates:** CC-0949, CC-0950, CC-0951, CC-0952, CC-0953, CC-0954, CC-0955, CC-0956, CC-0957, CC-0958, CC-0959
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/pdf_text_channel.dart:15 — extractText lacks MissingPluginException handling
  - lib/data/services/pdf_text_channel.dart:54 — hasEmbeddedText lacks it too
  - lib/data/services/script_import_service.dart:99 — the only PdfTextChannel call uses extractTextPerPage
  - lib/data/services/pdf_text_channel.dart:45 — extractTextPerPage already catches MissingPluginException
- **Decision:** The methods named by the findings are unreachable in current production code; the active PDF import method already implements the null fallback.
- **Recommendation:** No change unless extractText or hasEmbeddedText gains a caller.

### R-475 · INFO · Unknown cast roles are rejected by the database schema

- **Candidates:** CC-0751, CC-0752, CC-0753, CC-0754, CC-0755, CC-0756
- **Provenance:** `crypto-security-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `gcp-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/models/cast_member_model.dart:12 — fallback applies only to unknown strings
  - supabase/migrations/20260314061409_initial_schema.sql:63 — database check permits only organizer, actor, or understudy
- **Decision:** Current cloud rows cannot contain the hypothesized malformed/new role without a schema migration, and primary is not the server-side organizer authorization role.
- **Recommendation:** If roles evolve, migrate the schema and decoder together; no current fail-closed change is required.

### R-476 · INFO · Unknown native model IDs are unreachable

- **Candidates:** CC-0870, CC-0871
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/model_download_service.dart:482-545 — native downloads are started only with AiModel IDs from the registry
  - macos/Runner/BackgroundDownloadPlugin.swift:56-66 — callbacks retain the modelId supplied by that start call
- **Decision:** The native plugin does not originate or rename IDs, so a completion for a nonexistent registry entry cannot arise through current code.
- **Recommendation:** No change.

### R-477 · INFO · Unknown-token and special-token constants match canonical model code

- **Candidates:** CC-2803, CC-2804, CC-2805, CC-2806, CC-2807, CC-2808, CC-2809, CC-2810, CC-2811, CC-2813
- **Provenance:** `crypto-security-review@deepinfra-zai-org-glm-5.3-flash`, `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tools/mlx-harness/Sources/harness/main.swift:59 — harness maps unknown graphemes to 3
  - tools/mlx-harness/Sources/harness/main.swift:67 — it filters generated ids at the same cutoff
  - ios/Runner/MisakiVendored/English/FallbackNetwork/EnglishFallbackNetwork.swift:6 — canonical unknownTokenId is exactly 3
  - ios/Runner/MisakiVendored/English/FallbackNetwork/EnglishFallbackNetwork.swift:64 — canonical phoneme decode uses token > unknownTokenId
- **Decision:** These are not arbitrary harness assumptions; they intentionally reproduce the shipped fallback network and fixed configs. Unsupported characters becoming the model unknown token is expected tokenizer behavior.
- **Recommendation:** No change required; derive from a shared constant only if the harness can import the app module.

### R-478 · INFO · Unmounted cloud-sync path does not silently overwrite local state

- **Candidates:** CC-1520
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/production_hub/production_hub_screen.dart:827 — shouldReplaceLocal defaults true
  - lib/features/production_hub/production_hub_screen.dart:846 — replacement first accesses the ConsumerState ref
  - lib/features/production_hub/production_hub_screen.dart:858 — disposed-ref failure is caught
- **Decision:** If the same widget context is unmounted, the subsequent WidgetRef access throws before applying/persisting cloud state; the real bug is post-await disposed ref use, classified separately, not silent replacement.
- **Recommendation:** Fix disposed-ref handling; conservative default is still reasonable hardening.

### R-479 · INFO · Unpaginated audit reads are server-capped rather than unbounded-memory loads

- **Candidates:** CC-2696
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - tool/analyze_orphaned_recordings.dart:63-76 — requests omit pagination but materialize only the server response page
- **Decision:** PostgREST response limits bound a single response; the real defect is silent truncation, not unbounded client memory.
- **Recommendation:** Paginate for correctness as described in the separate finding.

### R-480 · INFO · Unreachable invite-card code has no live failure

- **Candidates:** CC-1414, CC-1415, CC-1416
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/cast_manager/cast_manager_screen.dart:901 — current source marks the invite options block unreachable
  - lib/features/cast_manager/cast_manager_screen.dart:1062 — the double-remove path is inside that dead method
- **Decision:** Dead code is maintenance weight, and the double-remove trigger cannot be reached through the current UI.
- **Recommendation:** Delete the unreachable block separately; do not report its latent exception as a user bug.

### R-481 · INFO · Unused BART temperature parameter does not affect current callers

- **Candidates:** CC-0574, CC-0575, CC-0576, CC-0577, CC-0578, CC-0579
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `linux-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/FallbackNetwork/BARTModel.swift:125 — temperature defaults to 1.0
  - ios/Runner/MisakiVendored/English/FallbackNetwork/EnglishFallbackNetwork.swift:77 — the only repository caller uses the default
- **Decision:** Argmax is scale-invariant, but no caller requests sampling or passes a nondefault temperature, so no current behavior fails.
- **Recommendation:** Remove the dead parameter/comment to make the greedy contract explicit.

### R-482 · INFO · Unused image OCR entry point has no current silent-loss trigger

- **Candidates:** CC-0670, CC-0672, CC-0673, CC-0674
- **Provenance:** `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`, `swift-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/PaddleOcrPlugin.swift:139 — recognizeText is a separate channel method
  - lib/data/services/paddle_ocr_channel.dart:45 — defines its wrapper
  - lib/data/services/script_import_service.dart:358 — production PDF imports use ocrPdf instead
- **Decision:** No repository caller invokes PaddleOcrChannel.recognizeText, so its empty-on-decode-failure behavior cannot currently lose imported content.
- **Recommendation:** Return a typed error if this image entry point gains a caller.

### R-483 · INFO · Unused number-converter members have no runtime effect

- **Candidates:** CC-0621, CC-0623, CC-0624
- **Provenance:** `ios-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/MisakiVendored/English/Num2Word/EnglishNum2Word.swift:14 — excludeTitle is unused
  - ios/Runner/MisakiVendored/English/Num2Word/EnglishNum2Word.swift:61 — merge is unused
- **Decision:** These are dead-code/immutability observations, not current observable failures.
- **Recommendation:** Remove them opportunistically.

### R-484 · INFO · Unused output-path variable causes no runtime failure

- **Candidates:** CC-2217, CC-2218, CC-2219, CC-2220
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`, `python-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/parse_script.py:384-388 — md_path is computed but unused
  - scripts/parse_script.py:390-408 — actual outputs use explicit repo paths
- **Decision:** This is dead code/maintainability clutter rather than a triggered failure under the triage contract.
- **Recommendation:** No change.

### R-485 · INFO · Unused SineGen field has no behavioral impact

- **Candidates:** CC-0437
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroVendored/Decoder/SineGen.swift:13 — dim is stored
  - ios/Runner/KokoroVendored/Decoder/SineGen.swift:29 — dim is initialized
  - ios/Runner/KokoroVendored/Decoder/SineGen.swift:65 — synthesis uses harmonicNum directly
- **Decision:** The field is dead weight, but no current failure follows from it.
- **Recommendation:** Optional cleanup only.

### R-486 · INFO · Unused single-image OCR entry point cannot abort import

- **Candidates:** CC-0943, CC-0944
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/paddle_ocr_channel.dart:45 — recognizeText is the single-image entry point
  - lib/data/services/script_import_service.dart:359 — production import calls ocrPdf instead
  - lib/features/script_import/pdf_page_view.dart:246 — page viewer calls ocrPage instead
- **Decision:** There is no current caller of recognizeText, and the full-PDF caller catches all thrown errors at the import boundary.
- **Recommendation:** No change unless recognizeText gains a caller with a null-fallback contract.

### R-487 · INFO · Unused STFT wrapper state has no reachable retention path

- **Candidates:** CC-0435, CC-0436
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroVendored/Decoder/MLXSTFT.swift:186 — magnitude and phase are optional stored properties
  - ios/Runner/KokoroVendored/Decoder/MLXSTFT.swift:255 — only callAsFunction assigns them
  - ios/Runner/KokoroVendored/Decoder/Generator.swift:140 — production constructs MLXSTFT and uses transform/inverse rather than the wrapper
- **Decision:** Repository search finds no call to MLXSTFT.callAsFunction or reads of the stored properties, so the proposed retained spectrogram is unreachable in current inference.
- **Recommendation:** No correctness change; remove dead wrapper state only as cleanup.

### R-488 · INFO · Unused sync helper is unreachable

- **Candidates:** CC-1777
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:1375-1390 — private helper has no call site.
- **Decision:** Dead code cannot trigger the claimed user failure.
- **Recommendation:** No current defect fix required.

### R-489 · INFO · Unwired export branches cannot crash current UI

- **Candidates:** CC-1779, CC-1780, CC-1781
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:219-227 — menu calls only plain and markdown; lines 1401-1419 contain unreachable character/cue branches.
- **Decision:** Current call sites cannot reach the null assertions.
- **Recommendation:** No current defect fix required.

### R-490 · INFO · Urgent requests already bypass queued prefetches

- **Candidates:** CC-0818
- **Provenance:** `mlx-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/kokoro_onnx_service.dart:217 — urgent handling begins
  - lib/data/services/kokoro_onnx_service.dart:225 — current generation is cancelled below the urgent sequence
  - lib/data/services/kokoro_onnx_service.dart:230 — urgent work is inserted at the queue front
- **Decision:** Existing nonurgent prefetches do not delay the urgent request and can remain useful for upcoming lines. The finding does not prove unbounded accumulation under current prefetch deduplication.
- **Recommendation:** No change.

### R-491 · INFO · URLSession owns cleanup of unconsumed download locations

- **Candidates:** CC-2090, CC-2091, CC-2098
- **Provenance:** `ios-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `ml-inference-pipeline-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - macos/Runner/BackgroundDownloadPlugin.swift:92 — location is URLSession didFinishDownloadingTo temporary storage
  - macos/Runner/BackgroundDownloadPlugin.swift:95 — returning without moving relinquishes it to URLSession
- **Decision:** The temporary location is system-managed and valid only during the delegate callback; URLSession removes it after return. The claimed persistent multi-hundred-MB leak is invalid.
- **Recommendation:** No manual cleanup is needed for the callback location.

### R-492 · INFO · User-initiated debug upload is tenant-restricted by current RLS

- **Candidates:** CC-1921, CC-1922
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/migrations/20260703140000_security_lockdown.sql:81-88 — debug reports are readable only by their owner (service role excepted)
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:178-183 — inserts must use the authenticated user id
  - lib/features/settings/debug_log_screen.dart:64-81 — upload occurs only on explicit Send to developer action
- **Decision:** The candidate’s anonymous/cross-tenant RLS premise was fixed by later migrations. Email/log content is knowingly included in a user-initiated support action; the separate raw join-code leak remains verified.
- **Recommendation:** No additional RLS change required.

### R-493 · INFO · Using real SharedPreferences is not itself a defect

- **Candidates:** CC-0248
- **Provenance:** `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - integration_test/screenshot_test.dart:55 — source explicitly explains why mock initial values are unsuitable on simulator
  - integration_test/screenshot_test.dart:57 — the real plugin is intentionally used
- **Decision:** The candidate asserts this is fine and identifies no failure.
- **Recommendation:** No change.

### R-494 · INFO · UUID casts are validation errors, not SQL injection/existence proof

- **Candidates:** CC-2519
- **Provenance:** `db-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:97 — prod_id is cast as a typed uuid in a static SQL statement
  - supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:157 — member_id is likewise statically cast
- **Decision:** Malformed text can raise a UUID syntax error, but there is no dynamic SQL and no additional existence oracle beyond the caller-supplied id/code checks. The high-severity claim is overstated.
- **Recommendation:** Optionally parse/catch invalid UUIDs to return a stable application error.

### R-495 · INFO · Validation threshold is intentionally a separate conservative warning

- **Candidates:** CC-1788
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_editor/validation_panel.dart:112 — panel labels this an OCR confidence review check
  - lib/features/script_editor/validation_panel.dart:114 — it uses 0.85
  - lib/features/script_editor/validation_panel.dart:125 — failed result is explicitly warning-only
- **Decision:** A review panel may conservatively flag more lines than the importer’s hard classification buckets; differing thresholds do not prove a contradiction.
- **Recommendation:** Share a constant only if product semantics require identical buckets.

### R-496 · INFO · Version Future memoization is deliberate immutable caching

- **Candidates:** CC-2361
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/settings_screen.dart:64 — comment documents process-constant version
  - lib/features/settings/settings_screen.dart:67 — module future is nullable cache
  - lib/features/settings/settings_screen.dart:69 — initializer memoizes once
- **Decision:** The cached version cannot legitimately change during a process and prevents FutureBuilder flicker.
- **Recommendation:** No change.

### R-497 · INFO · Visible-tile character lookup is bounded and negligible

- **Candidates:** CC-1575, CC-1576
- **Provenance:** `flutter-performance-review@deepinfra-zai-org-glm-5.3-flash`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/recording_studio/recordings_browser_screen.dart:174 — ListView.builder creates visible rows lazily
  - lib/features/recording_studio/recordings_browser_screen.dart:318 — each visible row scans the cast list once
- **Decision:** The candidate itself limits the work to visible rows and typical casts of tens; no observable failure is established.
- **Recommendation:** No change unless profiling on pathological casts shows jank.

### R-498 · INFO · Vision payload parsing duplication is maintenance-only

- **Candidates:** CC-1264
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/vision_ocr_channel.dart:19 — recognizeText decodes blocks
  - lib/data/services/vision_ocr_channel.dart:49 — ocrPdf separately decodes line blocks
- **Decision:** No current field divergence or observable failure is identified.
- **Recommendation:** Optional helper extraction only.

### R-499 · INFO · Vision platform failures are intentionally surfaced by import

- **Candidates:** CC-1268, CC-1269
- **Provenance:** `flutter-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/vision_ocr_channel.dart:26 — only plugin absence degrades to null
  - lib/data/services/script_import_service.dart:416 — the macOS fallback awaits Vision OCR
  - lib/data/services/script_import_service.dart:418 — unavailable engines become an explicit import exception
- **Decision:** A native PlatformException represents an OCR failure and is expected to abort/surface through the import flow rather than masquerade as empty OCR. Missing-plugin null is an intentional fallback signal.
- **Recommendation:** Add structured logging at the import boundary if desired, without swallowing real OCR failures.

### R-500 · INFO · Voice assignment and text preprocessing are bounded

- **Candidates:** CC-1234, CC-1236
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/tts_service.dart:373-387 — preprocessing runs once per spoken line
  - lib/data/services/tts_service.dart:478-523 — chunk preparation is line-bounded
- **Decision:** The candidates explicitly describe bounded, non-observable constant work.
- **Recommendation:** No change.

### R-501 · INFO · Voice assignment complexity is cold and cast-bounded

- **Candidates:** CC-1320, CC-1323
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/voice_config_service.dart:120-220 — adjacency assignment runs once over cast-sized input.
- **Decision:** The candidates describe the cost as unobservable for realistic casts.
- **Recommendation:** No defect fix required.

### R-502 · INFO · Voice CRUD similarity has no current divergence failure

- **Candidates:** CC-1308
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/voice_config_service.dart:64-118,223-308 — each typed store has complete current CRUD.
- **Decision:** The finding predicts future maintenance drift.
- **Recommendation:** No defect fix required.

### R-503 · INFO · Voice embeddings are not vendored model weights

- **Candidates:** CC-0374
- **Provenance:** `swift-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - ios/Runner/KokoroMLXService.swift:120-125 — voices.npz is loaded into voice embeddings after KokoroTTS already loaded its model weights
- **Decision:** The candidate conflates the voice-embedding dictionary with the vendored neural-network weight dictionary; missing voice IDs take the voiceNotFound path rather than force-unwrapping model layer keys.
- **Recommendation:** No change.

### R-504 · INFO · Voice fallback is constrained by the offered voice set

- **Candidates:** CC-0816, CC-0817
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/kokoro_onnx_service.dart:53 — map documents the English voices the app offers
  - lib/data/services/kokoro_onnx_service.dart:56 — every offered voice ID is enumerated
  - lib/data/services/kokoro_onnx_service.dart:212 — fallback applies only to values outside that controlled set
- **Decision:** Current presets and the supported v1.0/v1.1 English voice set do not supply an unknown ID; the candidate relies on corrupt or unsupported persisted data rather than a realistic caller.
- **Recommendation:** Validate imported configuration if the voice set later becomes externally extensible.

### R-505 · INFO · Voice preference decoding is cast-bounded

- **Candidates:** CC-1317, CC-1318, CC-1319
- **Provenance:** `dart-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `metal-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/voice_config_service.dart:85-90,353-386 — resolution decodes small maps during setup.
- **Decision:** No measured frame or latency failure is shown.
- **Recommendation:** No defect fix required.

### R-506 · INFO · Voice preset assignment is synchronous

- **Candidates:** CC-1858
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_import/script_import_screen.dart:366-370 — setPreset is invoked as a void local state operation
- **Decision:** There is no Future to await, exactly as the candidate’s final assessment states.
- **Recommendation:** No change.

### R-507 · INFO · Voice preset import resolves to an existing file

- **Candidates:** CC-1303
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/data/services/voice_config_service.dart:6-7 — relative import points to lib/data/models/voice_preset.dart, which exists.
- **Decision:** The claimed missing import target is false.
- **Recommendation:** No defect fix required.

### R-508 · INFO · Voice quality and copyWith claims misread current semantics

- **Candidates:** CC-1276, CC-1277
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/data/services/voice_clone_service.dart:18-23 — six clips yield 0.75, consistent with “good,” while eight reach the documented excellent 1.0
  - lib/data/services/voice_clone_service.dart:33-44 — callers can clear recordings by passing an empty list; only null means unchanged
- **Decision:** Neither alleged behavior is present: the comment does not equate good with 1.0, and empty-list reset works normally.
- **Recommendation:** No change required.

### R-509 · INFO · Voice quality threshold test is redundant but not misleading

- **Candidates:** CC-2653, CC-2654
- **Provenance:** `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `testing-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - test/voice_clone_test.dart:16 — exact one-clip scaling is already asserted
  - test/voice_clone_test.dart:45 — the later threshold test restates a weaker invariant
  - test/voice_clone_test.dart:52 — it correctly checks the named at-least-0.1 property
- **Decision:** The assertion is redundant, but it does fail if one-clip quality falls below the explicitly named product threshold; redundancy does not create a current behavior failure.
- **Recommendation:** Optionally remove during test cleanup; no production change.

### R-510 · INFO · Voice-prefix language mapping is valid for available Kokoro voices

- **Candidates:** CC-2814, CC-2815, CC-2816, CC-2817, CC-2818
- **Provenance:** `dependency-audit@deepinfra-zai-org-glm-5.3-flash`, `ios-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`, `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tools/mlx-harness/Sources/harness/main.swift:89 — voice must exist in the bundled NPZ map
  - tools/mlx-harness/Sources/harness/main.swift:95 — a-prefixed voices use enUS and others enGB
- **Decision:** Supported Kokoro voice keys follow the a/b naming convention; mistyped voices fail the existence guard rather than silently choosing a language. No reachable differently named shipped voice is shown.
- **Recommendation:** Validate naming if future voice catalogs add other conventions.

### R-511 · INFO · Voice-sheet duplication is maintenance-only

- **Candidates:** CC-1419, CC-1420
- **Provenance:** `maintainability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/cast_manager/cast_manager_screen.dart:1216 — cast manager owns one voice picker
  - lib/features/cast_manager/voice_config_screen.dart:231 — voice config owns a distinct richer flow
- **Decision:** Behavioral differences such as preview/reset are product differences, not proof of a current failure.
- **Recommendation:** Extract shared widgets only if the UX contracts should be identical.

### R-512 · INFO · Wakelock and staging success paths are balanced

- **Candidates:** CC-1883, CC-1884
- **Provenance:** `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/script_import/script_import_screen.dart:659-665 — import enables wakelock
  - lib/features/script_import/script_import_screen.dart:731-734 — finally disables it on every exit
  - lib/features/script_import/script_import_screen.dart:684-701 — both staging branches set pending state coherently
- **Decision:** The candidates explicitly dismiss these paths.
- **Recommendation:** No change.

### R-513 · INFO · Walk-list scan has no verified frame failure

- **Candidates:** CC-1755
- **Provenance:** `dart-performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - lib/features/script_editor/script_editor_screen.dart:937-939,1250-1256 — list rebuild is a linear in-memory scan.
- **Decision:** No evidence shows a user-visible failure.
- **Recommendation:** No current defect fix required.

### R-514 · INFO · Wall-clock benchmark jump is not a realistic harness failure

- **Candidates:** CC-2787, CC-2788
- **Provenance:** `ios-review@deepinfra-zai-org-glm-5.3-flash`, `macos-server-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - tools/mlx-harness/Sources/harness/main.swift:22 — timing uses CFAbsoluteTimeGetCurrent
  - tools/mlx-harness/Sources/harness/main.swift:35 — intervals cover short local load/inference operations
- **Decision:** A system clock step during these short operator-run intervals is possible in theory but no realistic trigger or observed invalid measurement is established.
- **Recommendation:** Using a monotonic clock is optional benchmark hygiene.

### R-515 · INFO · Web-editor email sharing is explicit and user-controlled

- **Candidates:** CC-1987, CC-1988, CC-1989, CC-1990
- **Provenance:** `dependency-audit@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `flutter-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `maintainability-review@deepinfra-zai-org-glm-5.3-flash`, `observability-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`
- **Evidence:**
  - lib/features/settings/settings_screen.dart:286 — user taps an Edit on the Web share action
  - lib/features/settings/settings_screen.dart:292 — signed-in email is read for the message
  - lib/features/settings/settings_screen.dart:297 — text is presented through the OS share sheet for user-selected delivery
- **Decision:** This is not automatic outbound traffic: the user explicitly invokes sharing and can inspect/cancel the OS share sheet. The candidates themselves acknowledge that context.
- **Recommendation:** Product may simplify copy, but no covert leak is verified.

### R-516 · INFO · Weight-layout ambiguity does not affect the pinned shipped checkpoint

- **Candidates:** CC-0487
- **Provenance:** `security-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - ios/Runner/KokoroVendored/TTSEngine/WeightLoader.swift:117 — the heuristic applies only to three-dimensional weight_v tensors
  - lib/data/services/model_download_service.dart:121 — the app pins one verified checkpoint digest
- **Decision:** The candidate is a hypothetical compatibility risk for a differently shaped future checkpoint; the current immutable model is already validated by its shipped synthesis behavior.
- **Recommendation:** Revisit only when changing checkpoint format.

### R-517 · INFO · Whole-file remote buffering is acceptable for this take diagnostic

- **Candidates:** CC-2331, CC-2334, CC-2335
- **Provenance:** `ios-performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-deepseek-ai-deepseek-v4-flash-0731`, `performance-review@deepinfra-zai-org-glm-5.3-flash`
- **Evidence:**
  - scripts/test_silence_trim.swift:124 — a remote file is loaded once into Data
  - scripts/test_silence_trim.swift:127 — the script reports the downloaded take size
  - scripts/test_silence_trim.swift:135 — AVAsset then analyzes the temporary file
- **Decision:** The intended inputs are short compressed recordings; multi-hundred-megabyte examples are not a realistic current trigger and no memory failure is demonstrated.
- **Recommendation:** Stream only if the tool is expanded to long-form recordings.
