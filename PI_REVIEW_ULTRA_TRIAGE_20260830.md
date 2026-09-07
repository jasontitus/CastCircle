# PI Review Ultra unified triage

Branch: `pi-review-ultra`  
Snapshot reviewed: `7974003`  
Triage date: 2026-08-30

## Executive result

The branch contains **32 primary review files** plus 32 coverage companions (the request estimated about 27). Eight independent domain triages checked every primary review claim against the snapshot code; seven adversarial audits then attempted to falsify accepted findings, restore missed findings, correct severities/fix plans, and collapse cross-review duplicates.

- Canonical confirmed issues: **103** (7 P1, 67 P2, 29 P3)
- Runtime/benchmark proof required before changing behavior: **39** (4 P1, 11 P2, 24 P3)
- Duplicates collapsed: **21**
- Already fixed/stale: **14**
- Rejected false positives or non-defects: **99**

Severity means remediation order, not raw model severity. P1 blocks release; P2 is a reachable correctness/security/performance defect; P3 is bounded, developer-tool, observability, or hardening work. `needs_runtime_proof` is not counted as a confirmed defect.

## Method

1. Enumerate all 32 non-coverage `REVIEW_*_20260829.md` files.
2. Extract every distinct claim, follow each cited entry point through current call sites, and classify it as confirmed, runtime-proof-needed, duplicate, already fixed, or false positive.
3. Adversarially re-open the review and code for every accepted item. Challenge lifecycle assumptions, trust boundaries, severity, fix safety, and duplicate ownership.
4. Preserve a single canonical owner for cross-review root causes. A duplicate is closed only when its canonical item retains the complete remediation.

## Review-file inventory

| Review file | Distinct raw claims | Accepted before adversarial pass |
|---|---:|---:|
| `REVIEW_android-review_ds4-glm-5.3-flash-q2_20260829.md` | 37 | 9 |
| `REVIEW_android-performance-review_ds4-glm-5.3-flash-q2_20260829.md` | 20 | 9 |
| `REVIEW_kotlin-review_ds4-glm-5.3-flash-q2_20260829.md` | 27 | 7 |
| `REVIEW_kotlin-performance-review_ds4-glm-5.3-flash-q2_20260829.md` | 16 | 6 |
| `REVIEW_c-review_ds4-glm-5.3-flash-q2_20260829.md` | 1 | 0 |
| `REVIEW_c-performance-review_ds4-glm-5.3-flash-q2_20260829.md` | 1 | 0 |
| `REVIEW_cpp-review_ds4-glm-5.3-flash-q2_20260829.md` | 4 | 0 |
| `REVIEW_cpp-performance-review_ds4-glm-5.3-flash-q2_20260829.md` | 0 | 0 |
| `REVIEW_simd-accelerate-review_ds4-glm-5.3-flash-q2_20260829.md` | 23 | 11 |
| `REVIEW_security-review_ds4-glm-5.3-flash-q2_20260829.md` | 912 | 9 |
| `REVIEW_crypto-security-review_ds4-glm-5.3-flash-q2_20260829.md` | 223 | 5 |
| `REVIEW_gcp-review_ds4-glm-5.3-flash-q2_20260829.md` | 721 | 4 |
| `REVIEW_aws-review_ds4-glm-5.3-flash-q2_20260829.md` | 4 | 1 |
| `REVIEW_db-review_ds4-glm-5.3-flash-q2_20260829.md` | 80 | 15 |
| `REVIEW_sql-migration-review_ds4-glm-5.3-flash-q2_20260829.md` | 55 | 15 |
| `REVIEW_dependency-audit_ds4-glm-5.3-flash-q2_20260829.md` | 9 | 1 |
| `REVIEW_flutter-review_ds4-glm-5.3-flash-q2_20260829.md` | 629 | 19 |
| `REVIEW_maintainability-review_ds4-glm-5.3-flash-q2_20260829.md` | 1088 | 16 |
| `REVIEW_testing-review_ds4-glm-5.3-flash-q2_20260829.md` | 278 | 4 |
| `REVIEW_observability-review_ds4-glm-5.3-flash-q2_20260829.md` | 327 | 12 |
| `REVIEW_performance-review_ds4-glm-5.3-flash-q2_20260829.md` | 694 | 11 |
| `REVIEW_dart-performance-review_ds4-glm-5.3-flash-q2_20260829.md` | 341 | 11 |
| `REVIEW_flutter-performance-review_ds4-glm-5.3-flash-q2_20260829.md` | 496 | 12 |
| `REVIEW_ios-review_ds4-glm-5.3-flash-q2_20260829.md` | 247 | 18 |
| `REVIEW_ios-performance-review_ds4-glm-5.3-flash-q2_20260829.md` | 33 | 4 |
| `REVIEW_swift-review_ds4-glm-5.3-flash-q2_20260829.md` | 69 | 14 |
| `REVIEW_ml-inference-pipeline-review_ds4-glm-5.3-flash-q2_20260829.md` | 892 | 10 |
| `REVIEW_mlx-performance-review_ds4-glm-5.3-flash-q2_20260829.md` | 313 | 4 |
| `REVIEW_media-provenance-review_ds4-glm-5.3-flash-q2_20260829.md` | 11 | 4 |
| `REVIEW_python-review_ds4-glm-5.3-flash-q2_20260829.md` | 18 | 9 |
| `REVIEW_python-performance-review_ds4-glm-5.3-flash-q2_20260829.md` | 13 | 2 |
| `REVIEW_shell-review_ds4-glm-5.3-flash-q2_20260829.md` | 70 | 16 |

## Canonical confirmed issues

### AndroidTriage

#### AND-07 — AudioRecord failures busy-spin the capture thread

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_android-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_android-performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_kotlin-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:367`
- Evidence: The capture loop executes `if (n <= 0) continue` with no state transition, wait, or retry bound. Persistent `ERROR_INVALID_OPERATION`, `ERROR_DEAD_OBJECT`, or zero reads therefore run the loop as fast as `AudioRecord.read` returns.
- Triage rationale: This can consume a core and battery indefinitely while `capturing` remains true.
- Remediation: Handle negative AudioRecord error codes as terminal capture errors; for zero reads use a short bounded backoff and fail after a small consecutive-zero limit. Route the terminal error through the existing single `onError` path and cleanup.
- Verification: Inject sequences of zero and negative reads into a scoped capture-loop test; assert bounded read count/time, no hot loop, one error, and resource cleanup. Exercise mic revocation/device loss on an Android device.

#### AND-15 — Overlapping contact picks overwrite the first pending result

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_android-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_kotlin-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:58`, `android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:70`, `lib/data/services/contact_picker_service.dart:27`
- Evidence: Every `pickContact` call assigns `pendingResult = result` without checking an existing call. A second call replaces the only reference to the first MethodChannel.Result; the next activity result completes only the replacement, leaving the first Dart Future unresolved.
- Triage rationale: Double taps or re-entrant callers can deterministically hang one request and misassociate activity results.
- Remediation: Before launching, reject a new call with a stable `PICK_IN_PROGRESS` PlatformException while `pendingResult != null`. Assign pending only after the launch succeeds, and clear it on launch failure.
- Verification: In a scoped plugin test, invoke `pickContact` twice before delivering an activity result; assert the second completes with `PICK_IN_PROGRESS` and the first receives the selected/cancelled result exactly once.

#### AND-23 — Paddle creates unbounded raw threads and concurrent inference jobs

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_android-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_android-performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_kotlin-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_kotlin-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:70`, `android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:122`, `android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:139`, `android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:155`
- Evidence: Each call during loading starts its own polling Thread, and each ready `recognizeText`, `ocrPdf`, or `ocrPdfPage` starts another dedicated Thread. There is no queue, concurrency bound, cancellation token, or rejection/backpressure policy. At the 15-second loading deadline, a still-loading call re-enters and starts another poller rather than resolving.
- Triage rationale: Concurrent requests multiply full bitmaps/tensors and invoke shared ORT sessions concurrently, causing unbounded thread/memory/CPU growth.
- Remediation: Use one lifecycle-owned single-thread ExecutorService for all OCR jobs and one shared load-completion future/latch. Queue pending calls once, define a bounded queue or explicit BUSY response, and shut the executor down on detach after cancelling queued work.
- Verification: Issue many image/PDF/page calls before, during, and after model load; assert a fixed worker count, bounded queue behavior, FIFO/exactly-once results, one model load, and no work accepted after detach.

#### AND-24 — Model load can complete after detach and leak live sessions

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_android-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_kotlin-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:69`, `android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:73`, `android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:101`, `android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:106`
- Evidence: Attach starts `loadModels` asynchronously. Detach closes only the sessions currently stored and does not stop/join the loader or set a generation/detached guard. If detach occurs before assignments at lines 101–102, the loader subsequently assigns fresh sessions and sets `ready=true` on a detached plugin; no later lifecycle path closes those sessions.
- Triage rationale: This deterministic ordering leaks large native model sessions and leaves invalid ready state after hot restart/engine teardown.
- Remediation: Give each attachment a generation/cancellation token. Build sessions into locals; before publishing them atomically, verify the binding/generation is still current, otherwise close the locals. On detach cancel pending load and close only after the lifecycle-owned executor drains.
- Verification: Block model creation between det and rec/session publication, detach, release the block, and assert both local sessions/options close, `ready` remains false, and no callback is posted.

#### AND-29 — Tensor conversion allocates large arrays for every page and line crop

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_android-performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_kotlin-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:437`, `android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:470`
- Evidence: `imageToTensor` always allocates `IntArray(w*h)` and `FloatArray(3*w*h)` and usually a scaled Bitmap. Detection can allocate about 3.7 MB of pixels plus 11 MB of floats at 960²; recognition repeats smaller allocations once per detected line. The file records recognition as ~3.8 s and dozens of runs per page.
- Triage rationale: This is deterministic high-volume allocation on the hot OCR path even without accepting the reviews' unmeasured GC-duration estimates.
- Remediation: After serializing jobs, maintain separate reusable det and rec pixel/float buffers sized to the current maximum; fill only the active range and create tensors over that range/shape. Avoid allocating a scaled Bitmap by drawing into one reusable appropriately sized bitmap or converting with a reusable raster buffer.
- Verification: Compare allocation profiles and GC pauses for a fixed multi-page corpus; assert tensors and recognized text/confidence/boxes are byte-for-byte or tolerance-equivalent to the existing path.

#### AND-37 — Android physicalFootprintMB reports only Java heap usage

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_android-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `android/app/src/main/kotlin/com/tiltastech/lineguide/MemoryMonitorPlugin.kt:47`, `android/app/src/main/kotlin/com/tiltastech/lineguide/MemoryMonitorPlugin.kt:53`, `lib/data/services/debug_log_service.dart:208`, `lib/data/services/debug_log_service.dart:257`
- Evidence: Native computes `Runtime.totalMemory() - Runtime.freeMemory()` and labels it `physicalFootprintMB`. Dart stores that key and logs it as total MB used. It excludes native ONNX allocations, bitmaps/graphics, code, and other process RSS/PSS—the most relevant memory in this app.
- Triage rationale: Diagnostics can materially underreport memory during OCR and mislead field/OOM investigation.
- Remediation: Use `Debug.MemoryInfo`/`Debug.getMemoryInfo` and report total PSS (or an explicitly selected process-memory metric) under a correctly named cross-platform key. If retaining Java heap, rename it `javaHeapUsedMB` and update every Dart display/log consumer atomically.
- Verification: Allocate known Java-heap and native/direct memory separately in an instrumentation test; assert the renamed heap metric changes only for heap, and the process metric reflects both within documented tolerance. Verify debug screen/log labels.

#### AND-18 — Contact provider queries run synchronously on the UI thread

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_android-performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_kotlin-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:67`, `android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:90`, `android/app/src/main/kotlin/com/tiltastech/lineguide/ContactPickerPlugin.kt:104`
- Evidence: `onActivityResult` runs on the activity/UI thread and performs up to three ContentResolver queries, each an IPC/provider operation, before returning and completing Dart.
- Triage rationale: A cold or slow contacts provider can block frames during a user-visible transition. Frequency is low, so this is P3 rather than an ANR claim.
- Remediation: Snapshot the URI and application ContentResolver, perform all cursor work on one bounded background executor, then post exactly one Result completion to the main handler. Tie cancellation/completion to the pending-request lifecycle.
- Verification: Use a fake resolver that blocks each query and assert `onActivityResult` returns promptly while the result completes later on the main looper; test cancel, SecurityException degradation, detach, and success.

#### AND-33 — OrtSession SessionOptions native resource is never closed

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_android-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:92`
- Evidence: `OrtSession.SessionOptions()` is created as a local AutoCloseable, passed to both `createSession` calls, and then dropped without `close()`/`use`. This is bounded per attachment but repeats across engine lifecycles and relies on cleaner/GC for a native handle.
- Triage rationale: It is a real native-resource ownership omission, though low impact compared with session/tensor issues.
- Remediation: Wrap SessionOptions in `use` around both session creations; publish sessions only after both creations succeed, closing the first if the second fails.
- Verification: A scoped load test should assert options close on successful load, first/second session creation failure, and detached/cancelled load, while both sessions remain usable after options close.

### DataAdversary

#### ADV-05 — Prevent cast members from overwriting one another's recording blobs

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_db-review_ds4-glm-5.3-flash-q2_20260829.md (storage UPDATE authorization claim, recomputed against the later lockdown migration)`
- Code: `supabase/migrations/20260703140000_security_lockdown.sql:57-79`, `lib/data/services/supabase_service.dart:581-597`, `lib/data/services/supabase_service.dart:660-669`
- Evidence: The final storage UPDATE policy authorizes solely by membership in the production encoded in the object path; it does not check the object's owner. Every production member can read recording metadata including audio_url, which reveals the exact storage path, and the SELECT policy also authorizes that member. A malicious or buggy cast member can therefore call the storage update/overwrite operation on another cast member's known object and replace that person's audio. This is distinct from DAT-006: DAT-006 is missing DELETE/GC and retention, while this is an active cross-user integrity grant.
- Adversarial disposition: The final storage UPDATE policy authorizes solely by membership in the production encoded in the object path; it does not check the object's owner. Every production member can read recording metadata including audio_url, which reveals the exact storage path, and the SELECT policy also authorizes that member. A malicious or buggy cast member can therefore call the storage update/overwrite operation on another cast member's known object and replace that person's audio. This is distinct from DAT-006: DAT-006 is missing DELETE/GC and retention, while this is an active cross-user integrity grant.
- Remediation: Add a forward migration that drops "Members update recording objects". Current upload code intentionally creates a new unique key for every take and never needs object UPDATE, so removing the policy preserves the shipped path and existing data. If overwrite is later required, introduce a separate owner-only UPDATE policy that checks both production membership and storage ownership in USING and WITH CHECK; do not grant UPDATE to organizers or generic members merely because they may need a separately scoped DELETE operation.
- Verification: On an isolated local/staging Supabase database, upload an object as actor A, expose its audio_url through the recordings row, and attempt an update of that exact key as actor B in the same production; it must fail. Confirm actor B can still download as an authorized production member, both actors can still upload fresh unique keys, and the app's re-record path succeeds without storage UPDATE. No remote operation was performed in this audit.

### DataTriage

#### DAT-001 — Cloud script replacement is non-atomic and can publish/adopt a truncated script

- Severity/status: **P1 / confirmed**
- Sources: `REVIEW_db-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_sql-migration-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/supabase_service.dart:742`, `lib/data/services/supabase_service.dart:755`, `lib/features/home/home_screen.dart:323`, `lib/features/home/home_screen.dart:362`, `lib/providers/production_providers.dart:606`
- Evidence: saveScriptLines deletes every cloud script_lines row, then inserts independent 200-row batches in windows of four. A failure after the delete or after any batch commits leaves an empty or prefix-only cloud script. _reconcileCloudScript accepts any nonempty cloud result when no local script exists; _refreshScriptFromCloud rejects only a shrink below 50% when the local script has at least 20 lines, so many partial results are persisted locally. saveScriptScenes separately performs delete then insert; its caller catches failures, so custom scene metadata can disappear while the line push is reported as successful.
- Triage rationale: An ordinary network/process failure can turn a replace operation into a durable partial write and propagate the truncated canonical copy to cast devices. The local organizer copy may permit recovery, but the repository provides no atomicity or revision marker and new devices can adopt the damaged copy.
- Remediation: Add one database RPC that replaces lines and scene metadata in a single PostgreSQL transaction, validates the complete payload before deleting the prior revision, and returns the committed revision/count. Migrate the client to that RPC and remove the direct delete/batched-insert paths. For payloads too large for one request, upload to staging under a revision id and atomically switch the production's active revision only after all rows and counts are present.
- Verification: Use a local Supabase instance and inject failures before delete, after delete, and after an intermediate batch. Assert readers continue seeing the prior complete revision until the new complete revision commits, and assert lines plus scenes switch together. Exercise both no-local-copy and existing-castmate reconciliation paths.

#### DAT-002 — A legacy permissive INSERT policy defeats the v3 join-code and role restrictions

- Severity/status: **P1 / confirmed**
- Sources: `REVIEW_db-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_sql-migration-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `supabase/migrations/20260315_cast_join_code.sql:40`, `supabase/migrations/20260703140000_security_lockdown.sql:109`, `supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:167`, `lib/data/services/supabase_service.dart:458`
- Evidence: 20260315 creates "Users can self-join" with only WITH CHECK (auth.uid() = user_id). Neither the lockdown nor v3 migration drops that policy; v3 drops/recreates only "Users insert own membership". PostgreSQL permissive policies are OR-combined, so the surviving legacy policy still allows an authenticated caller to insert themself into any known production UUID with any role, including organizer. The client retains a direct INSERT fallback after an RPC error.
- Triage rationale: Knowing a production UUID is sufficient to create membership without proving the join code. Membership then satisfies is_production_member and grants access to cast, script, recordings, and storage. The legacy policy also makes v3's role restriction ineffective, although server organizer authorization still keys off productions.organizer_id rather than cast_members.role.
- Remediation: In a new forward migration, drop every historical direct self-join policy by exact name, including "Users can self-join" and "Users insert own membership". Remove the client's direct INSERT fallback and make the code-validating SECURITY DEFINER RPC the only self-join path. If direct inserts are still required for organizers, create a separate organizer-only policy using is_production_organizer.
- Verification: On a fresh migrated local database, enumerate pg_policies for cast_members and assert no authenticated direct INSERT policy permits self-join. As a signed-in nonmember, attempt direct inserts with a known production UUID and roles actor/understudy/organizer; all must fail. Verify the v3 RPC succeeds only with the correct code and always writes actor.

#### DAT-003 — Direct UPDATE policies and the client fallback bypass the v3 invitation code check

- Severity/status: **P1 / confirmed**
- Sources: `REVIEW_db-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_sql-migration-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `supabase/migrations/20260315_cast_join_code.sql:34`, `supabase/migrations/20260703140000_security_lockdown.sql:119`, `supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:145`, `lib/data/services/supabase_service.dart:383`
- Evidence: The final schema retains policies that allow any authenticated caller to target a cast_members row with user_id IS NULL and require only that the post-update user_id equal auth.uid(). The v3 RPC validates the production join code, but claimInvitation falls back on any RPC failure to a direct UPDATE by member id and user_id IS NULL, without sending or checking the code. The policy also does not constrain production_id, role, character_name, display_name, or contact_info from changing in the same UPDATE.
- Triage rationale: Anyone who learns an unclaimed member id can claim or rewrite it without the credential v3 says is required for every pre-membership operation, then gain member-scoped data access.
- Remediation: Drop the direct null-row claim policies in a new migration, retain only own-row updates that cannot change identity/production/role fields, and make the code-validating claim RPC the sole NULL-to-user transition. Remove the direct claim fallback; report RPC/network failure rather than weakening authorization. Have the RPC return an explicit claimed/already-claimed/invalid-code result.
- Verification: As a nonmember, verify direct UPDATE of an unclaimed row fails with and without modifying ancillary columns. Verify the RPC rejects a wrong code, succeeds with the right code, cannot change immutable invitation fields, and returns a distinct zero-row/already-claimed result.

#### DAT-004 — SECURITY DEFINER join RPCs retain default EXECUTE privilege for PUBLIC

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_db-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_sql-migration-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `supabase/migrations/20260319000001_join_flow_rpc_v2.sql:69`, `supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:81`, `supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:84`, `supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:116`, `supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:146`
- Evidence: PostgreSQL grants EXECUTE on new functions to PUBLIC by default. The migrations grant v3 functions to authenticated but never revoke them from PUBLIC; lookup revokes only the direct anon grant, which does not remove privilege inherited through PUBLIC. fetch_cast_for_join accepts a valid code without requiring auth.uid, and join_production inserts auth.uid() into a nullable user_id column, so anonymous execution with a known code can enumerate a roster or create unclaimed rows despite the stated signed-in requirement.
- Adversarial disposition: The ACL computation is correct but P1 is too high. New v3 fetch/join/claim functions receive PostgreSQL's default EXECUTE grant to PUBLIC; granting authenticated without first revoking PUBLIC does not narrow that grant, and revoking anon directly from lookup does not negate PUBLIC. Anonymous callers with a valid join code can therefore fetch the roster or make join_production insert a nullable-user junk membership. lookup itself rejects null auth through check_join_rate_limit, and the anonymous caller does not gain an authenticated member session, so the concrete impact is anonymous roster disclosure and roster pollution to an attacker who already possesses a valid code—not systemic unauthenticated tenant compromise. SEC-02's P2 assessment is the correct canonical severity.
- Remediation: Add a forward migration that revokes EXECUTE on all exposed SECURITY DEFINER RPC signatures from PUBLIC and anon, then grants only the explicitly intended roles. Add explicit auth.uid() IS NOT NULL checks inside state-changing functions as defense in depth. Set restrictive default function privileges for the migration owner if compatible with the project.
- Verification: Inspect information_schema.routine_privileges/has_function_privilege for anon, authenticated, and service roles. Invoke every join RPC with an anon JWT and assert permission denial; invoke as authenticated and verify normal behavior. Confirm no older overload remains executable.

#### DAT-005 — Membership uniqueness was dropped and never restored

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_db-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_sql-migration-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `supabase/migrations/20260315_cast_join_code.sql:20`, `supabase/migrations/20260801130000_cast_members_rls_index.sql:10`, `supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:133`
- Evidence: 20260315 drops the unique (production_id, user_id) constraint to allow NULL invitations. The later migration creates only a non-unique index on the same columns. join_production performs a plain INSERT with no ON CONFLICT/anti-join, so retries and concurrent calls can create multiple non-NULL membership rows for the same user and production.
- Adversarial disposition: The missing non-NULL membership uniqueness is confirmed, but a bare partial unique index is unsafe on an existing deployment because it fails if duplicates already exist, while deleting an arbitrary duplicate can discard a distinct role, character assignment, invitation timestamp, or contact field. Inventory and archive every duplicate row first; define and verify a field-by-field merge/canonical-row rule; repoint any dependent references if introduced; then create the partial unique index using a deployment mode that does not block the hot table (CONCURRENTLY in a dedicated nontransactional step where supported, otherwise a measured maintenance window). Make join_production idempotent against that exact partial-index predicate.
- Remediation: Audit and deterministically consolidate existing duplicate non-NULL memberships, then add a partial unique index on (production_id, user_id) WHERE user_id IS NOT NULL. Make join_production idempotent with ON CONFLICT against a compatible unique constraint/index or an explicit locked lookup.
- Verification: Before applying, use a read-only GROUP BY query to enumerate duplicates. Locally exercise repeated and concurrent join RPC calls and assert exactly one membership row and a stable id/result. Verify multiple NULL invitation rows in one production remain allowed.

#### DAT-006 — Re-recording permanently orphans prior storage objects

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_db-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_sql-migration-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `supabase/migrations/20260703140000_security_lockdown.sql:57`, `supabase/migrations/20260703170000_recordings_delete_policy.sql:5`, `lib/data/services/supabase_service.dart:571`, `lib/data/services/supabase_service.dart:608`
- Evidence: Final storage.objects policies provide SELECT, INSERT, and UPDATE but no DELETE. The client explicitly generates a fresh key for every take because overwrite/delete is unavailable and comments that old per-take objects are orphaned. The recordings metadata UPSERT retains only the latest URL, so old audio loses its application reference but remains stored.
- Adversarial disposition: Blob retention is confirmed. The DELETE policy must not be merely production-member scoped: every member can learn other members' object paths from recordings.audio_url, so member-wide DELETE would let castmates erase one another's audio. Permit deletion only to the storage object owner or the authoritative production organizer. Capture the old URL, commit the replacement metadata, and only then delete the superseded object; never delete the sole referenced object before the metadata switch. Historical GC must inventory references, use a safety age, archive/dry-run its delete set, and protect all currently referenced keys.
- Remediation: Add a production-member/owner-scoped storage DELETE policy using recording_object_production(name). After a replacement metadata UPSERT commits, delete the prior object key; on metadata deletion, delete its object as well. Add a conservative service-role cleanup job for objects not referenced by recordings after a safety age, with dry-run inventory before any remote deletion.
- Verification: Locally upload take A, replace it with B, and delete B. Assert table metadata and storage objects converge after each operation and other members/productions cannot delete them. For any hosted cleanup, first compare the keep set to every recordings.audio_url and perform a read-only dry run; no remote deletion is part of this triage.

#### DAT-007 — The app's user-only membership lookup lacks a matching index

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_db-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `supabase/migrations/20260801130000_cast_members_rls_index.sql:10`, `lib/data/services/supabase_service.dart:97`
- Evidence: The restored index is (production_id, user_id), but fetchProductions first queries cast_members WHERE user_id = current user to obtain production ids. A btree with production_id leading cannot support that user_id-only lookup efficiently. The final policy "Users read own memberships" uses the same predicate.
- Adversarial disposition: The user_id-leading index is warranted by fetchMyProductions and the own-membership policy. On an existing populated deployment, the recommendation must not be implemented as an ordinary blocking CREATE INDEX without first measuring the table and traffic. Use CREATE INDEX CONCURRENTLY in a dedicated migration/operator step that is not wrapped in a transaction, or schedule a verified maintenance window if the migration runner cannot support it. Retain the production_id-leading index because it serves is_production_member; the two indexes cover different access paths.
- Remediation: Add an index on cast_members(user_id, production_id), preferably replacing the non-unique production-leading index only if EXPLAIN confirms both helper and user-list predicates remain covered by the chosen pair of indexes.
- Verification: On representative local data, compare EXPLAIN (ANALYZE, BUFFERS) for the user-only production-list query and the is_production_member predicate before/after. Verify both use indexes and measure write overhead before deciding whether both indexes are retained.

#### DAT-008 — recordings.line_id has no referential integrity despite UUID/client assumptions

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_db-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `supabase/migrations/20260314061409_initial_schema.sql:109`, `supabase/migrations/20260314120000_add_script_lines.sql:6`, `lib/data/services/supabase_service.dart:574`, `lib/data/services/supabase_service.dart:686`
- Evidence: recordings.line_id is text with no FK, while script_lines.id is uuid. Upload code rejects a non-UUID line id and metadata stores that id, establishing a client assumption that a recording belongs to an existing script line. The database nevertheless accepts malformed/nonexistent line ids and script replacement can leave dangling recording rows.
- Adversarial disposition: A simple line_id UUID FK is insufficient and can be destructive. It would allow a recording to reference a line from another production unless the relationship is composite on (production_id,line_id) -> script_lines(production_id,id). More importantly, the current writer deletes every script line before reinserting it: RESTRICT would make every replacement containing recorded lines fail, while CASCADE would delete recording metadata even when the same stable line IDs are immediately reinserted. NOT VALID skips validation of old rows but still enforces new DML, so it does not solve this sequencing problem. First replace delete/reinsert with an atomic staged diff/upsert that preserves existing IDs and gives removed recorded lines an explicit archival/RESTRICT/CASCADE product behavior; then audit/quarantine invalid text and cross-production references, convert line_id, add the required referenced composite uniqueness, add the composite FK NOT VALID, and validate only after all exceptions are resolved.
- Remediation: Read-only audit existing values for UUID validity and missing script_lines matches. Decide whether line deletion should RESTRICT, CASCADE metadata, or preserve recordings in a separate archival relation. Then normalize line_id to uuid and add a NOT VALID FK, repair/quarantine exceptions, and validate it in a later safe step.
- Verification: On a local copy, prove invalid and cross-production line references are rejected, valid metadata UPSERT still works, and the selected line-deletion behavior matches product expectations. Do not mutate hosted rows during the audit.

#### DAT-009 — Production organizers depend on a separate cast row to read recordings

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_db-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `supabase/migrations/20260314140000_fix_rls_recursion.sql:67`, `lib/data/services/supabase_service.dart:131`
- Evidence: The final recordings SELECT policy checks only is_production_member. The client creates a production and then auto-adds the organizer to cast_members in a separate, non-transactional request. If that second request fails or a production is created through another client, the authoritative organizer_id owner cannot read their production's recordings.
- Triage rationale: Ownership authorization should not depend on a redundant membership row maintained by best-effort client sequencing.
- Remediation: Extend recordings SELECT to allow is_production_organizer(production_id, auth.uid()) as well as membership. Consider making production creation plus organizer membership one transactional RPC, but retain the direct owner branch as the schema invariant.
- Verification: Create an organizer-owned production without a cast row locally. Verify the organizer can read its recordings but an unrelated authenticated user cannot; verify normal member reads remain unchanged.

#### DAT-010 — Join-code RPCs return more identity and production data than the client requires

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_db-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_sql-migration-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:61`, `supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:101`, `lib/data/services/supabase_service.dart:491`
- Evidence: lookup_production_by_join_code returns row_to_json(p), automatically exposing every present and future productions column to any caller with a code. fetch_cast_for_join returns each member's user_id to a pre-member who knows the production-wide code. The lookup client consumes the title and join flow fields and explicitly treats organizer_id/join_code as sensitive log data; no need for an open-ended full-row contract is established.
- Adversarial disposition: The roster user UUID minimization point is valid: the pre-membership UI only tests whether user_id is null, so the RPC can return an is_claimed boolean instead. The lookup_production_by_join_code half is overstated as written. The current join client explicitly consumes organizer_id, join_code, created_at, locale, id, and title to construct the local Production; removing those fields without migrating that caller breaks joining, and the present productions schema contains no additional secret column. Replace row_to_json with an explicit contract to prevent future-column exposure, but retain the fields actually consumed or update the client in the same cutover.
- Remediation: Replace row_to_json with json_build_object containing the exact join-screen contract. Remove user_id from the pre-membership roster projection or return only a caller-owned boolean; provide a richer member-only RPC if needed.
- Verification: Trace and contract-test every join screen consumer against the reduced JSON shape. Assert a code holder cannot retrieve organizer_id, unrelated future/internal columns, contact_info, or other users' UUIDs, while existing members receive any fields their UI demonstrably needs.

#### DAT-012 — script_scenes maintains a redundant duplicate index

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_db-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_sql-migration-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `supabase/migrations/20260813100000_add_script_scenes.sql:25`, `supabase/migrations/20260813100000_add_script_scenes.sql:45`
- Evidence: UNIQUE (production_id, sort_order) creates a btree with exactly the same columns and order as idx_script_scenes_production. Unlike the analogous script_lines duplicate, v3 never drops this index.
- Adversarial disposition: The duplicate index is real, but on an already populated deployment the forward cleanup should verify the unique constraint's backing index and use DROP INDEX CONCURRENTLY in a dedicated nontransactional step where supported, or a measured maintenance window. Editing the historical create-table migration or issuing an ordinary drop during traffic is not the safe cutover.
- Remediation: Drop idx_script_scenes_production in a forward migration after confirming the unique constraint's backing index exists. Do not edit or remove an already-applied migration file.
- Verification: Inspect pg_indexes/pg_constraint locally, compare EXPLAIN for production_id plus sort_order reads before/after, and verify the unique constraint still rejects duplicate sort_order values.

### FlutterPerfAdversary

#### ADV-09 — Abort bulk-cast completion updates after disposal

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_maintainability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/features/cast_manager/bulk_cast_setup_screen.dart:272-323`
- Evidence: After the long remote/Drift sequence, _saveAndShowInvites calls setState before checking mounted; disposal while the final notifier.save is pending reaches setState on a dead State. Earlier loop iterations can also reach ref.read after disposal.
- Adversarial disposition: After the long remote/Drift sequence, _saveAndShowInvites calls setState before checking mounted; disposal while the final notifier.save is pending reaches setState on a dead State. Earlier loop iterations can also reach ref.read after disposal.
- Remediation: After each async boundary, return when !mounted before ref/context/setState access. Reset the saving flag in a mounted-only try/finally.
- Verification: Delay the final save, pop the route, complete it, and assert no Flutter exception or disposed ref access; keep mounted and verify the saving flag settles on success/failure.

#### ADV-10 — Persist failed cast invitations as retryable cloud operations

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_flutter-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/features/cast_manager/bulk_cast_setup_screen.dart:265-348`, `lib/features/join/join_production_screen.dart:404-477`
- Evidence: A failed cloud invitation still persists a local member under a fresh UUID and shows invite links. The cloud roster lacks the unclaimed assignment, deep-link character preselection cannot resolve it, and re-save creates a different cloud identity with no durable retry owner.
- Adversarial disposition: A failed cloud invitation still persists a local member under a fresh UUID and shows invite links. The cloud roster lacks the unclaimed assignment, deep-link character preselection cannot resolve it, and re-save creates a different cloud identity with no durable retry owner.
- Remediation: Keep offline local save but store a durable pending invitation/outbox with stable identity; retry on connectivity/startup and atomically reconcile the returned cloud ID while showing pending/failed status.
- Verification: Save offline, restart providers, recover connectivity, and assert exactly one cloud invitation, no duplicate local member, and successful deep-link character preselection.

#### ADV-11 — Discard stale recording-file scan completions

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_observability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/features/recording_studio/recordings_browser_screen.dart:195-218`
- Evidence: When the recording list changes, old and new unawaited scans both replace _fileResolved. If the old scan finishes last, it overwrites current file statuses because _scannedKey is never validated at completion.
- Adversarial disposition: When the recording list changes, old and new unawaited scans both replace _fileResolved. If the old scan finishes last, it overwrites current file statuses because _scannedKey is never validated at completion.
- Remediation: Capture a monotonically increasing generation or structural key at launch and discard completion unless it remains current after all awaits; combine with PERF-03 indexing/concurrency work.
- Verification: Launch scan A, change the list and launch B, finish B then A, and assert only B's ids/statuses remain.

#### ADV-12 — Stop prior playback when the selected recording is empty

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_observability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/features/recording_studio/recordings_browser_screen.dart:669-707`
- Evidence: The player stops only after the new file passes the size check. Tapping an empty B while A plays shows an error for B but leaves A playing and _playingLineId unchanged.
- Adversarial disposition: The player stops only after the new file passes the size check. Tapping an empty B while A plays shows an error for B but leaves A playing and _playingLineId unchanged.
- Remediation: On null/empty/error replacement paths, stop the existing player and clear _playingLineId while mounted before returning.
- Verification: Play A, tap an under-100-byte B, and assert stopped playback, null playing id, no B source, and one empty-file message.

#### ADV-13 — Guard debug-log clear completion with mounted

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_maintainability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/features/settings/debug_log_screen.dart:124-131`, `lib/data/services/debug_log_service.dart:234-244`
- Evidence: Clear awaits filesystem work and then unconditionally calls setState; navigating away while deletion is pending triggers setState after dispose.
- Adversarial disposition: Clear awaits filesystem work and then unconditionally calls setState; navigating away while deletion is pending triggers setState after dispose.
- Remediation: Let the app-scoped clear finish, but repaint only when mounted.
- Verification: Delay clear, pop, resolve, and assert no Flutter exception; while mounted assert the list refreshes.

#### ADV-14 — Recognize joint context lines as the actor's lines

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_flutter-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/features/recording_studio/recording_studio_screen.dart:365-390`, `lib/data/models/script_models.dart:42-74`
- Evidence: Context labels use line.character == selected character, while joint cues retain a combined character string and list individuals in multiCharacters. A joint line spoken by the actor is therefore not labeled YOU despite isForCharacter returning true.
- Adversarial disposition: Context labels use line.character == selected character, while joint cues retain a combined character string and list individuals in multiCharacters. A joint line spoken by the actor is therefore not labeled YOU despite isForCharacter returning true.
- Remediation: Use line.isForCharacter(selectedCharacter) for the label without rewriting the combined cue representation.
- Verification: Render a joint prior line containing the selected actor and assert YOU/actor color; an unrelated joint line retains its combined label.

### FlutterTriage

#### FLUTTER-08 — App-scoped ScriptImportService reuses a stateful parser without resetting per-document state

- Severity/status: **P1 / confirmed**
- Sources: `REVIEW_flutter-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_maintainability-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_observability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/script_parser.dart:25`, `lib/data/services/script_parser.dart:30`, `lib/data/services/script_parser.dart:51`, `lib/data/services/script_parser.dart:117`, `lib/data/services/script_import_service.dart:28`, `lib/providers/production_providers.dart:116`, `lib/features/script_import/script_import_screen.dart:657`
- Evidence: `ScriptParser` owns mutable `knownCharacters`, `characterAliases`, `multiCharacterMap`, `_titleHeaders`, and `_headerScrubPatterns`. `parse` detects into those collections but does not clear them at entry. `ScriptImportService` holds one parser field, and `scriptImportServiceProvider` is an app-scoped Provider reused by PDF, Markdown, and text import entry points.
- Triage rationale: Importing a second unrelated play in the same app process carries character aliases and running-header scrub patterns from the first into detection and cleaning of the second. Wrong attribution/line deletion can then be persisted as the second production's canonical script. Existing parser tests generally construct a fresh parser in `setUp` or per fixture, so they miss the service lifecycle.
- Remediation: Make parse state local to one invocation, or add a private reset at the very start of `parse` for every document-derived collection while preserving only explicitly configured seed data in immutable inputs.
- Verification: Use the same provider/service instance to import two deliberately disjoint scripts. Seed the first with a character alias and repeating header that appears as legitimate content in the second; assert the second result is identical to parsing it with a fresh parser.

#### FLUTTER-01 — Migration recovery classifies SQLite errors by broad message substrings

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_flutter-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_maintainability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/database/app_database.dart:126`, `lib/data/database/app_database.dart:133`, `lib/data/database/app_database.dart:145`
- Evidence: Every v2-v7 upgrade step runs through `_step`. Its catch treats any exception string containing `duplicate column name` or `already exists` as successfully applied and returns normally. Drift can then advance `user_version`; there is no structural check that the specific column/index named by `what` exists.
- Adversarial disposition: The structural-verification defect is real, but P1 is disproportionate. Each closure emits one add-column or create-index statement, so a harmful suppression requires a partially applied or externally altered schema, such as an expected index name with the wrong definition; this is an edge recovery path rather than a generally reachable high-severity failure.
- Remediation: Make each migration step structurally idempotent: inspect the exact target column/index before creating it and verify it after any duplicate-object exception. Only suppress the exact SQLite duplicate-object result for that target; rethrow everything else.
- Verification: Use an in-memory/file Drift database at each prior schema version. Exercise a normal jump to v7, a partially-applied step with the intended column/index already present, and an injected different SQLite failure whose text contains `already exists`; assert only the intended partial-application case advances to v7 and that every required column/index exists.

#### FLUTTER-02 — Production deletion is not atomic across related database rows

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_flutter-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_maintainability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/repositories/production_repository.dart:42`, `lib/data/repositories/production_repository.dart:56`, `test/production_repository_test.dart:24`
- Evidence: `ProductionRepository.deleteProduction` first unlinks recording files, then independently awaits deletion of recordings, script lines, scenes, cast, and finally the production. There is no Drift transaction around the five row mutations. The cited tests cover only the all-success path and cross-production isolation; they inject no failure between deletes.
- Triage rationale: A process death or database error after any intermediate await commits a partial state. Depending on the failure point, surviving child rows reference a production being removed, or recording rows point to files already deleted.
- Remediation: Capture file paths, delete all database rows in one `_db.transaction`, then unlink the captured files after commit with explicit logged failures. Keep the production row if the database transaction fails.
- Verification: Add a repository test with a fault-injecting executor that fails each cascade step in turn and assert the database remains unchanged. Add success coverage asserting all rows disappear atomically and file-unlink failures do not roll back committed database deletion but are observable.

#### FLUTTER-03 — Successful upload completion drops the asynchronous database update

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_flutter-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_observability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/sync_queue.dart:277`, `lib/data/services/sync_queue.dart:445`, `lib/providers/production_providers.dart:427`, `lib/providers/production_providers.dart:167`, `lib/data/repositories/production_repository.dart:243`, `lib/data/database/app_database.dart:276`
- Evidence: `SyncQueue.onUploaded` is typed as a synchronous `void Function`. `launchRecordingSync` installs a closure that calls the async `RecordingsNotifier.markUploaded` but does not return/await its Future. The queue removes and persists the upload job before invoking the callback. The repository also discards the integer affected-row count returned by Drift.
- Adversarial disposition: Both upload dispatchers expose synchronous void callbacks and discard RecordingsNotifier.markUploaded's Future: SyncQueue.onUploaded after removing its durable job and RecordingSyncService.onLocalUploaded after counting success. Repair both callback contracts and check Drift's affected-row count; fixing only SyncQueue leaves full-sync uploads broken.
- Remediation: Change `onUploaded` to `Future<void> Function(...)`, await it, and define a post-upload metadata-retry state distinct from re-uploading bytes. Make `markRecordingUploaded` throw when the affected-row count is not exactly one.
- Verification: Extend `sync_queue_test.dart` with an async callback that completes later, throws, and reports zero-row persistence. Assert the job is not considered fully settled until metadata persistence succeeds and that a successful cloud upload is not repeated merely to retry the local stamp.

#### FLUTTER-04 — Transient loudness-analysis failures are cached as permanent success values

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_flutter-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_maintainability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/audio_level_service.dart:36`, `lib/data/services/audio_level_service.dart:52`, `lib/data/services/audio_level_service.dart:63`
- Evidence: `volumeFor` initializes `volume = 1.0`, catches every channel/decode failure by retaining 1.0, and then unconditionally stores that fallback in `_gainCache[path]`. Every later call for the same recording returns it without invoking the analyzer. There are no tests referencing `AudioLevelService` or `volumeFor`.
- Triage rationale: A one-time MissingPluginException during initialization or transient decoder error disables normalization for that stable file path until an external caller happens to invalidate it. The API cannot distinguish measured unity gain from failure fallback.
- Remediation: Cache only a successfully parsed, finite RMS result. Do not cache exception/invalid-result fallbacks, or store a failure entry with a bounded retry time separate from measured gains.
- Verification: Inject a channel that fails once then returns a hot RMS value; assert the second call retries and attenuates. Also test that a legitimately measured 1.0 result is cached and that concurrent misses share one analysis Future.

#### FLUTTER-05 — Bulk/automatic model download can overwrite a verified working component before verifying its replacement

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_flutter-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_maintainability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/main.dart:136`, `lib/main.dart:140`, `lib/data/services/model_download_service.dart:483`, `lib/data/services/model_download_service.dart:659`, `lib/data/services/model_download_service.dart:694`
- Evidence: When group readiness is false, launch-time auto-download loops over every Kokoro component and calls `download`, even components already valid. The Dart path renames `$outPath.tmp` onto the live path and only then calls `_verifyDownload`; verification failure deletes the now-bad live file. The public `downloadAll` has the same unconditional behavior.
- Triage rationale: One missing component causes already-good model files to be replaced. A truncated or wrong replacement destroys a working installation instead of preserving it while repair proceeds.
- Remediation: Skip components that already pass `fileProblem`/hash verification. For replacements, verify the staged temporary file before atomically swapping it into place; retain the prior live file until the staged file is proven good.
- Verification: Stage one valid installed model and one missing component, serve a corrupt replacement for the valid one, invoke the actual bulk/auto path, and assert the valid original bytes remain while the failed staged file is discarded.

#### FLUTTER-06 — Status refresh deletes temporary files belonging to active background downloads

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_flutter-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_maintainability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/model_download_service.dart:338`, `lib/data/services/model_download_service.dart:340`, `lib/data/services/model_download_service.dart:370`, `lib/data/services/model_download_service.dart:755`, `lib/features/settings/ai_models_screen.dart:35`
- Evidence: `refreshDownloadedStatus` avoids changing a model whose in-memory state is `downloading`, but after the loop it calls `_cleanupTmpFiles`, which iterates every model and deletes every `$path.tmp` without checking state. The settings screen starts refresh during initialization, and native background transfers can outlive the in-memory state/process.
- Adversarial disposition: The iOS downloader uses a system temporary location and $destinationPath.resume, not $outPath.tmp, so refresh cannot delete an active native transfer. The Android path remains concretely broken: setup explicitly lets Dart downloads continue after pop, opening AI Models refreshes status, and cleanup deletes every active Dart $outPath.tmp without checking state.
- Remediation: Associate temp artifacts with an explicit download lease/job and skip cleanup for every active native or Dart job. On startup, reconcile native session tasks before deciding a temp file is stale; use age/job metadata rather than filename alone.
- Verification: Run a controllable slow downloader, call `refreshDownloadedStatus` mid-stream, and assert the temp file and transfer survive. Separately create an old orphan temp with no active task and assert refresh removes it.

#### FLUTTER-07 — Kokoro readiness omits files returned as mandatory engine inputs

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_flutter-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_maintainability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/model_manager.dart:55`, `lib/data/services/model_manager.dart:66`, `lib/data/services/model_manager.dart:82`, `test/model_manager_test.dart:10`, `integration_test/kokoro_pack_smoke_macos_test.dart:73`
- Evidence: `isKokoroReady` checks the model, voices, tokens, and US lexicon only. `getKokoroPaths` subsequently returns both `lexicon-us-en.txt` and unchecked `lexicon-gb-en.txt`, plus the unchecked `espeak-ng-data` directory, as engine inputs. Integration tests stage a complete pack, so they do not exercise a missing GB lexicon/data directory; the unit test explicitly has no readiness behavior coverage.
- Triage rationale: The application can advertise the model as ready and enter the load path with nonexistent required paths. Engine load then fails and the user silently falls back to system speech despite a green readiness gate.
- Remediation: Define one manifest of required runtime artifacts and use it for extraction verification, readiness, and path construction. Include both lexicons and required espeak data contents.
- Verification: Parameterize an integration/readiness test by removing each manifest artifact in turn. Assert readiness is false and `getKokoroPaths` is null for every missing item, then assert a complete staged pack loads.

#### FLUTTER-09 — Voice preset and locale cloud writes are fire-and-forget after local commit

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_flutter-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_maintainability-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_observability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/features/cast_manager/voice_config_screen.dart:154`, `lib/features/cast_manager/voice_config_screen.dart:168`, `lib/features/cast_manager/voice_config_screen.dart:427`, `lib/features/cast_manager/voice_config_screen.dart:440`
- Evidence: Preset selection awaits local SharedPreferences and updates `_currentPreset`, then calls `supa.saveVoicePreset(...)` without awaiting or attaching an error handler. Dialect selection first updates both local production providers and the local preset, then drops both `saveLocale` and `saveVoicePreset` Futures.
- Adversarial disposition: The same dialect control on ScriptImportScreen also discards ProductionsNotifier.update, VoiceConfigService.setPreset, saveLocale, and saveVoicePreset Futures. Preserve the optimistic Riverpod update but add awaitable/durable pending state across both screens.
- Remediation: Represent the change as a single async operation with pending/error state. Await both cloud writes (or enqueue a durable sync record), surface failure with retry, and only report synced state once both related fields are consistent.
- Verification: Widget-test preset and dialect changes with a fake Supabase client that delays and fails each write. Assert pending UI, durable retry/error visibility, no unhandled Future, and convergence of local/cloud values after retry.

#### FLUTTER-11 — Manual script sync shows success after persistScript swallows cloud failure

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_flutter-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_maintainability-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_observability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/features/script_editor/script_editor_screen.dart:183`, `lib/features/script_editor/script_editor_screen.dart:186`, `lib/providers/production_providers.dart:267`, `lib/providers/production_providers.dart:291`, `lib/features/script_editor/script_editor_screen.dart:1386`
- Evidence: The toolbar's `Sync to cloud` handler awaits `persistScript(ref)` and unconditionally shows `Script synced to cloud`. `persistScript` catches `pushScriptToCloud` errors internally, logs/toasts, and returns normally after only the local save. A separate `_syncToCloud` helper handles push errors but has no call site.
- Triage rationale: The same failed operation emits both a failure toast from the provider and an explicit success toast from the toolbar. Users can believe castmates received edits when only the local layers succeeded.
- Remediation: Return a structured result distinguishing localSaved, cloudSkipped, cloudSynced, and cloudFailed. Make the toolbar render that result and remove the unused divergent `_syncToCloud` path.
- Verification: Widget-test the toolbar as organizer, cast member, and offline organizer. Assert exactly one truthful outcome message and verify a thrown cloud push can never produce `Script synced to cloud`.

#### FLUTTER-13 — Rehearsal jump/restart paths leave an old strong-match timer armed

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_flutter-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_maintainability-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_observability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/features/rehearsal/rehearsal_screen.dart:2394`, `lib/features/rehearsal/rehearsal_screen.dart:2445`, `lib/features/rehearsal/rehearsal_screen.dart:2642`, `lib/features/rehearsal/rehearsal_screen.dart:2682`, `lib/features/rehearsal/rehearsal_screen.dart:2709`
- Evidence: Strong recognition schedules `_strongMatchDeadline`, which can recursively re-arm every 800 ms and eventually calls `_confirmLineMatch` for the captured line. `_advanceLine` cancels it, but `_jumpBack` and `_restartScene` cancel only silence and match-confirm timers. Both then schedule `_processCurrentLine`, allowing the stale callback to run while the new line is again in `listeningForMe`.
- Adversarial disposition: The old timer cannot survive until new recognition raises the score because listening startup cancels it before recognition. It can still fire after listeningForMe is set but while releaseAudioSession awaits just_audio.stop, observing the prior score/ending/timestamp. Cancel on jump/restart and use a line generation token.
- Remediation: Centralize teardown in one `_cancelLineTimersAndAudio` routine used by advance, jump, restart, pause, interruption, and dispose. Add a line/session generation token to every delayed callback and reject callbacks whose token no longer matches.
- Verification: With fake timers, arm a strong deadline, jump/restart before it fires, begin listening on another line, advance time beyond repeated deadlines, and assert index/state do not change. Also assert normal confirmation still advances once.

#### FLUTTER-14 — Sync-queue persistence failure has no retryable or inspectable state

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_maintainability-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_observability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/sync_queue.dart:177`, `lib/data/services/sync_queue.dart:194`, `lib/data/services/sync_queue.dart:340`
- Evidence: Every queue mutation calls `_persist`, but `_persist` returns void, starts serialized async I/O, catches any failure into a debug log, and neither re-marks the queue dirty nor exposes an error. If the app is killed after an offline enqueue whose write failed, the in-memory job disappears and the old on-disk snapshot is restored next launch.
- Triage rationale: Disk persistence is the queue's stated durability boundary for offline recordings. A failed boundary silently degrades the durable queue to memory-only with no retry trigger unless another unrelated mutation occurs.
- Remediation: Track a dirty generation and last persistence error; retry failed writes with bounded backoff until the latest generation is durable. Expose persistence health to diagnostics/UI and provide an awaitable flush for lifecycle shutdown.
- Verification: Inject a filesystem that fails the first N writes while offline, enqueue a job, then recover I/O. Assert automatic retry writes the latest snapshot and a reconstructed queue restores the job. Assert diagnostics reports the failure while outstanding.

#### FLUTTER-17 — Model setup records a download-completed analytics event before downloads begin

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_observability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/features/onboarding/model_setup_screen.dart:127`, `lib/features/onboarding/model_setup_screen.dart:138`, `lib/features/onboarding/model_setup_screen.dart:229`
- Evidence: `_downloadAll` calls `AnalyticsService.logModelDownloaded(modelId: 'setup_all')` immediately after setting `_downloading = true`, before either voice or matching downloads run. Completion is only checked near line 229, where no corresponding completion event is sent.
- Triage rationale: Failures and 15-minute timeouts are counted as successful downloads, making the metric unsuitable for setup completion/funnel diagnosis.
- Remediation: Log a distinct setup-download-started event at entry and emit completed only after every required item is ready; emit failed/cancelled with stable reason codes on terminal alternatives.
- Verification: Use fake services for success, one-file failure, timeout, and user navigation. Assert event sequences and ensure `model_downloaded/setup_all` appears only in the all-ready case.

#### FLUTTER-18 — Optimistic production creation has no durable cloud-create retry state

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_flutter-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_observability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/features/home/home_screen.dart:689`, `lib/features/home/home_screen.dart:696`, `lib/features/home/home_screen.dart:704`
- Evidence: `_submitProduction` persists and selects a local production with a generated join code, then fire-and-forgets `createProduction`. On failure it logs and shows an 8-second toast, returns an empty map from `catchError`, and stores no pending/failed cloud-creation marker or retry job.
- Triage rationale: The production remains fully usable locally and continues displaying a join code that resolves to nothing for invitees. Restart loses the transient toast and there is no healing mechanism tied to that production.
- Remediation: Persist a cloudCreationStatus/outbox operation with the production. Disable or label invitations while pending/failed, retry durably on connectivity/startup, and clear the marker only after the server confirms the same id/join code.
- Verification: Create while the fake cloud is offline, restart providers, then restore connectivity. Assert the production retains a visible pending state, invites are blocked/labeled, retry creates the exact original id/code, and state becomes synced.

#### TEST-01 — Opt-in Supabase suites mutate production and can pass diagnostic branches without assertions

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_testing-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `test/supabase_service_test.dart:10`, `test/supabase_service_test.dart:30`, `test/supabase_service_test.dart:40`, `test/supabase_service_test.dart:64`, `test/supabase_join_test.dart:14`, `test/supabase_join_test.dart:30`, `test/supabase_join_test.dart:96`, `test/supabase_join_test.dart:111`
- Evidence: Both files hard-code the production Supabase project and explicitly sign up throwaway users in `setUpAll`. They are skipped unless `RUN_SUPABASE_TESTS` is set. `supabase_service_test` reimplements the RPC/fallback instead of calling `SupabaseService`, swallows signup/RPC/fallback exceptions into prints, and several branches have no unconditional assertion. Two `supabase_join_test` cases only print raw HTTP results.
- Triage rationale: Running the suites pollutes production `auth.users` and depends on the live `DHT6XT`/`Macbeth` fixture, while green results do not reliably prove the application service contract. This is a concrete test-environment and oracle defect, not a preference for more coverage.
- Remediation: Move live checks to a dedicated disposable test project with seeded fixtures and cleanup. Make default-running unit tests call the real `SupabaseService` through an injected fake client. Require assertions and fail setup when auth/fixture creation fails.
- Verification: Run the unit suite with network disabled and prove lookup success, invalid code, RPC failure/fallback, and auth failure deterministically. Run the isolated integration job twice and assert setup/cleanup leaves no users or rows behind.

#### TEST-02 — Gzip regression test validates a copied downloader instead of ModelDownloadService

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_testing-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `test/model_download_gzip_test.dart:49`, `test/model_download_gzip_test.dart:53`, `lib/data/services/model_download_service.dart:576`, `lib/data/services/model_download_service.dart:620`
- Evidence: The test defines its own `download(Uri)` with HttpClient, headers, gzip detection, stream decode, and byte collection, described as mirroring `_dartDownload`. Its assertions never invoke `ModelDownloadService.download` or `_dartDownload`; only the separate static size check touches production code.
- Triage rationale: A production regression that removes identity encoding or gzip decoding leaves the test's copied implementation green. This is especially material because the file is documented as the regression guard for a field failure that disabled live matching.
- Remediation: Extract the streamed HTTP download behind an injectable internal collaborator used by `ModelDownloadService`, or expose a testing constructor/model registry so the local server can drive the actual `download` path. Delete the copied algorithm from the test.
- Verification: Point the real service at the local server for identity and forced-gzip responses, wait for service state, and assert the persisted verified bytes. Demonstrate the test fails if production gzip decoding is removed.

#### FLUTTER-10 — Corrupt voice-override JSON is converted to an empty map and overwritten on the next edit

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_flutter-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_maintainability-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_observability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/voice_config_service.dart:62`, `lib/data/services/voice_config_service.dart:76`, `lib/data/services/voice_config_service.dart:90`
- Evidence: `getOverrides` catches every decode/type error, only `debugPrint`s it, and returns `{}`. `setOverride` calls `getOverrides`, adds one entry to that empty map, and `_saveOverrides` replaces the stored blob. No test covers an invalid `voice_overrides_*` payload.
- Adversarial disposition: Malformed JSON is replaced on the next edit, but all overrides are already unreadable at the trigger and no incompatible recoverable legacy format is established. Quarantining the blob and surfacing decode failure is worthwhile, but the proven impact is P3.
- Remediation: Return a typed decode failure rather than `{}`; preserve/move aside the original blob, log through `DebugLogService`, and block destructive mutation until migration/recovery succeeds. Version the serialized shape.
- Verification: Seed SharedPreferences with malformed JSON and a valid legacy-but-incompatible shape. Assert reads surface corruption, `setOverride` does not replace the original bytes, and a supported migration preserves every prior override.

#### FLUTTER-12 — Welcome is marked seen before verifying the initiating context can navigate

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_flutter-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_maintainability-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_observability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/features/onboarding/welcome_screen.dart:24`, `lib/features/onboarding/welcome_screen.dart:30`, `lib/features/onboarding/welcome_screen.dart:31`
- Evidence: `maybeOffer` awaits SharedPreferences, writes `welcome_seen = true`, and only afterward checks `context.mounted` before pushing `/welcome`. The caller intentionally runs this asynchronously after launch.
- Triage rationale: If the home context is disposed while SharedPreferences resolves, no walkthrough is shown but the durable flag suppresses it on every future launch. This is an observable one-way state transition, not merely a preference about mounted-check placement.
- Remediation: Check mounted immediately after each await and record `welcome_seen` only after navigation has successfully started (or when the user dismisses/completes the walkthrough).
- Verification: Use a delayed preferences fake, dispose the initiating widget before completion, and assert no flag is written. Exercise successful show/close and assert the flag is then durable.

#### FLUTTER-15 — Deep-link logging emits user-supplied names in the raw URI

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_flutter-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_maintainability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/deep_link_service.dart:132`, `lib/data/services/deep_link_service.dart:36`, `lib/features/auth/auth_screen.dart:95`, `lib/features/join/join_production_screen.dart:49`
- Evidence: `_handleUri` calls `debugPrint('Deep link received: $uri')` before parsing/sanitization. Invite URIs carry `char` and `name`; those values are subsequently shown in auth chrome and prefilled into the join form, so they can contain real actor/cast names.
- Triage rationale: The rejected-link structured log deliberately avoids raw query text, but the unconditional preceding console line defeats that privacy design. Debug console/device logs can retain the full user-controlled invite URI.
- Remediation: Log only scheme, normalized route, presence of fields, and a nonreversible correlation token. Never log query values; route failures through the structured logger after redaction.
- Verification: Feed a URI containing distinctive actor/character PII into `_handleUri` with captured debug/structured log sinks and assert no emitted line contains the values or encoded query string.

#### FLUTTER-20 — Cast-cloud sync failure is durable in logs but invisible in the active screen

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_flutter-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_maintainability-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_observability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/features/cast_manager/cast_manager_screen.dart:98`, `lib/features/cast_manager/cast_manager_screen.dart:139`, `lib/features/cast_manager/cast_manager_screen.dart:148`
- Evidence: Opening the cast screen launches `_syncCastFromCloud`. Its successful path adds cloud rows and removes stale local rows; the catch only calls `DebugLogService.logError` and leaves the existing list displayed without a banner, retry action, or stale-state marker.
- Triage rationale: The screen looks authoritative even though the exact reconciliation that removes ghost members and imports invitations did not run. The central log helps support but not the organizer making casting decisions in the current session.
- Remediation: Track sync status in screen/provider state, display a nonblocking stale/offline banner with retry, and include stack trace/stable production id in the structured log without actor names.
- Verification: Widget-test a failing and then recovering cloud source. Assert the old list remains but is visibly marked stale, retry is available, and the marker clears only after reconciliation completes.

#### FLUTTER-21 — Cold-start deep-link platform failures bypass the structured diagnostic log

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_flutter-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_maintainability-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/deep_link_service.dart:103`, `lib/data/services/deep_link_service.dart:109`, `lib/data/services/deep_link_service.dart:113`
- Evidence: `getInitialLink` timeout is recorded through `DebugLogService.logError`, but every other exception falls into `catch (e) { debugPrint(...) }` and is treated exactly like no initial invite. The live stream path does use the structured logger.
- Triage rationale: A plugin registration/platform failure that breaks all cold-start invitations is absent from exported app diagnostics, while the semantically equivalent timeout and stream errors are retained.
- Remediation: Catch expected platform/format errors with stack traces and log them through `DebugLogService`; reserve normal no-link behavior for a successful null result.
- Verification: Mock `getInitialLink` to return null, throw PlatformException, throw FormatException, and time out. Assert null produces no error while each failure produces one redacted structured entry with stack/correlation data.

#### TEST-03 — Parser accuracy report is a green test with no behavioral assertion and writes into the worktree

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_testing-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `test/parser_accuracy_test.dart:245`, `test/parser_accuracy_test.dart:295`
- Evidence: The extended test named `Generate parser accuracy report` catches per-file parse errors into report rows, writes `sample-scripts/PARSER_ACCURACY_REPORT.md`, prints it, and has no `expect`/`fail` in the test body. Parser errors therefore become text while the test passes, and every changed report dirties a tracked project path.
- Triage rationale: This is a report generator mislabeled as a verification test. It cannot block parser regressions and has an observable repository side effect.
- Remediation: Move report generation to a tool command writing an explicit output path. If retained as a test, write to a test temp directory, assert no ERROR rows and pin the domain invariants the report is meant to protect.
- Verification: Force one fixture parse to throw and assert the verification test fails. Run the report tool separately and assert the repository working tree is untouched.

#### TEST-04 — OCR classifier tests do not pin either side of the documented thresholds

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_testing-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `test/ocr_confidence_test.dart:92`, `test/ocr_confidence_test.dart:137`, `test/ocr_confidence_test.dart:148`
- Evidence: The suite covers representative values and a few mixed cases, but not values immediately below/equal/above both the 0.65 recognition-confidence gate and 0.50/0.80 dictionary gates. The null-confidence case covers `ok` and `review` only. An inequality change at a gate can preserve every existing assertion.
- Triage rationale: These thresholds directly decide whether imported content is hidden as likely-not-script, shown for review, or accepted. Boundary precedence is an observable contract, unlike the report's many style-only requests for more samples.
- Remediation: Use table-driven tests for each threshold at `t-epsilon`, `t`, and `t+epsilon`, including every relevant combination and null recognition confidence. Name expected precedence explicitly.
- Verification: Mutation-check by changing each `<` to `<=` (and vice versa) in `classify`; at least one table case must fail for every mutation.

### IOSAdversary

#### ADV-04 — Ignore stale STT callbacks from superseded sessions

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_ios-review_ds4-glm-5.3-flash-q2_20260829.md and REVIEW_swift-review_ds4-glm-5.3-flash-q2_20260829.md (recognition-task lifecycle claims)`
- Code: `ios/Runner/AppleSttPlugin.swift:180-200`, `ios/Runner/AppleSttPlugin.swift:249-279`, `ios/Runner/AppleSttPlugin.swift:631-641`
- Evidence: A new `listen` cancels the prior `recognitionTask` and immediately installs new request/task/tap state. The prior task's asynchronous cancellation/error/final callback retains the plugin for that callback and unconditionally calls `stopCurrentSession`; if it arrives after replacement setup, it ends the new request, cancels the new task, stops its engine, and emits old `onError`/`onDone` events into the new Dart listening state. Weak capture prevents a leak but does not identify session ownership.
- Adversarial disposition: A new `listen` cancels the prior `recognitionTask` and immediately installs new request/task/tap state. The prior task's asynchronous cancellation/error/final callback retains the plugin for that callback and unconditionally calls `stopCurrentSession`; if it arrives after replacement setup, it ends the new request, cancels the new task, stops its engine, and emits old `onError`/`onDone` events into the new Dart listening state. Weak capture prevents a leak but does not identify session ownership.
- Remediation: Assign each listen an immutable generation/session ID captured by its recognition closure and tap. Before stopping state or emitting any event, require that ID to equal the active session. Make teardown conditional (`stopCurrentSession(ifActive:)`), remove the active tap before ending its request, and discard stale callbacks without sending Flutter events. Keep audio-file finalization separately serialized so an STT session change cannot discard an in-flight take.
- Verification: Start session A, immediately start B, and inject/delay A final, cancellation, and error callbacks until after B's tap is running. Assert B remains listening and records audio, A emits no events after supersession, B emits one terminal event, and Thread Sanitizer reports no request/file-state race. Repeat jump-back/stop/start while recording on a physical device.

### IOSTriage

#### IOS-01 — The STT render tap races session teardown and recording state

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_ios-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/AppleSttPlugin.swift:297`, `ios/Runner/AppleSttPlugin.swift:303`, `ios/Runner/AppleSttPlugin.swift:311`, `ios/Runner/AppleSttPlugin.swift:631`
- Evidence: The AVAudioEngine tap runs on the realtime render thread and reads/appends through `recognitionRequest` and reads `audioFile`. `stopCurrentSession()` writes `recognitionRequest = nil` on the Flutter/main thread, while the file queue writes `audioFile = nil`; the render-thread `audioFile != nil` precheck is outside `audioFileQueue`. Rapid stop/restart and write failure therefore perform unsynchronized reads/writes of Swift reference properties, and `endAudio()` can overlap `append(buffer)`.
- Triage rationale: This is production-reachable whenever a line completes, the user jumps back/stops, or an audio write fails while a tap callback is in flight. Swift data races are undefined behavior and the Speech request also has a semantic append/end race.
- Remediation: Give the tap immutable session-local state: capture the recognition request installed for that tap and serialize append/end teardown, and remove the unsynchronized `audioFile` precheck so every file lookup/mutation occurs on `audioFileQueue` (or one lock-protected state object). Remove the tap before ending/releasing its request.
- Verification: On a physical iPhone, repeatedly start/stop and jump back during active speech while recording, including an injected AVAudioFile write failure. Run the scenario under Thread Sanitizer in a simulator-compatible audio harness and verify no race reports, tap-already-installed failures, truncated takes, or append-after-end errors.

#### IOS-02 — STT export fallback is non-atomic, can lose the prior take, and mislabels CAF as M4A

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_ios-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_swift-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/AppleSttPlugin.swift:438`, `ios/Runner/AppleSttPlugin.swift:441`, `ios/Runner/AppleSttPlugin.swift:444`, `ios/Runner/AppleSttPlugin.swift:481`, `ios/Runner/AppleSttPlugin.swift:490`
- Evidence: Before creating/exporting the new M4A, the code removes `destUrl`, which may contain the previous take. Both fallback branches move CAF bytes to `destPath` and return that path as success even though the extension and documented Dart contract are M4A. The no-export-session branch ignores whether `moveItem` succeeded; the export-failure double-failure branch deletes the remaining CAF and returns nil.
- Adversarial disposition: The file-loss and container-mismatch diagnosis is correct, but the proposed successful raw-CAF result still violates the existing Dart/cloud contract. `SttChannel` documents that the returned path is M4A, and `SupabaseService.uploadRecording` always stores the object under `.m4a` with `contentType: audio/mp4`. Returning an actual `.caf` path plus a format field that current Dart ignores would preserve local bytes but upload mislabeled CAF data. Export must occur at a temporary M4A, be validated, and atomically replace the prior take. If conversion fails, retain the CAF only as recovery data and return a typed failure/recovery payload; do not return it as a normal successful recording until Dart explicitly handles/transcodes that format.
- Remediation: Export to a unique temporary M4A beside the destination, validate it, then atomically replace the old destination only on success. On export failure, retain and return the actual `.caf` path with an explicit format field, and never delete the last valid capture merely because the final move failed.
- Verification: Seed an existing destination take, then exercise successful export, unavailable-export-session, export failure, destination collision, and injected move failure. Verify the old take survives every unsuccessful replacement and every success payload points to an existing file whose container matches its reported format/extension and is playable by the Dart player.

#### IOS-04 — Release logging exposes full user script text through STT contextual hints

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_ios-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/AppleSttPlugin.swift:238`, `ios/Runner/AppleSttPlugin.swift:240`, `lib/features/rehearsal/rehearsal_screen.dart:2264`
- Evidence: The rehearsal builds hints as `[cleanLine, ...wordHints]`, so the first element is the full expected script line. Native code logs `contextualStrings.prefix(5)` with `NSLog`, which is present in release device/system logs.
- Triage rationale: Private or licensed script dialogue is persisted outside the app's data model and can appear in sysdiagnostics/support logs. Logging counts is sufficient for diagnostics; content is unnecessary.
- Remediation: Remove hint contents from release logs. Use an `os.Logger` message containing only count/locale with private fields redacted, optionally retaining content logging only behind an explicit DEBUG-only diagnostic switch.
- Verification: Run a release build with a unique canary script line, start STT, collect Console/sysdiagnose logs, and verify the canary text and its words do not appear while a non-content diagnostic count remains.

#### IOS-07 — Resume blobs are not bound to the URL/model generation they resume

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_ios-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_swift-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/BackgroundDownloadPlugin.swift:47`, `ios/Runner/BackgroundDownloadPlugin.swift:150`, `ios/Runner/BackgroundDownloadPlugin.swift:154`
- Evidence: Resume data is stored solely at `destinationPath + ".resume"`. `startTask` uses any nonempty blob with `downloadTask(withResumeData:)` without verifying the blob's original request URL. Model IDs/destinations persist across app releases while registry URLs can change, so a failed old download can be resumed after the URL changes.
- Triage rationale: The Dart registry uses fixed HTTPS release URLs and sandbox destinations, so this is not the review's claimed arbitrary-network security issue. It is a real version/update correctness issue: URLSession resume data embeds its old request and may download the obsolete source until later hash validation fails.
- Remediation: Persist resume metadata including model ID, immutable expected URL, and expected digest/generation; discard the blob unless all match the new request. Prefer a model-ID plus URL/digest-derived resume filename.
- Verification: Create partial resume data for URL A, update the same model/destination to URL B, and verify the plugin discards A's blob and starts B. Verify a matching URL/digest resumes successfully across process relaunch.

#### IOS-08 — A stale retry timer can start a second task over a replacement download

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_ios-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_swift-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/BackgroundDownloadPlugin.swift:165`, `ios/Runner/BackgroundDownloadPlugin.swift:183`, `ios/Runner/BackgroundDownloadPlugin.swift:185`
- Evidence: `scheduleRetry` queues an untracked `asyncAfter`. When it fires, it only checks that `activeDownloads[modelId]` exists. If the user starts a fresh download for that model during backoff, the stale closure reads the new `DownloadInfo`, starts another task, and overwrites its stored task while the already-running fresh task continues untracked.
- Adversarial disposition: The stale retry closure is valid, but generation checking only that closure is incomplete. Every URLSession callback routes solely by `taskDescription == modelId`; after a replacement is installed, a late progress, finish, or non-cancel error callback from the old task can read or remove the replacement's `DownloadInfo`, overwrite its resume blob, emit the wrong completion, or leave the replacement transfer untracked. The generation/task identifier must be captured in DownloadInfo and checked by the retry closure and all delegate dispatch points, with terminal cleanup conditional on the same generation.
- Remediation: Add an immutable generation/UUID to DownloadInfo and capture it in the retry closure; fire only if the active entry still has that generation and no current task. Store/cancel retry work items when replacing or cancelling an entry.
- Verification: Force a retry delay, start a new download for the same model before it expires, and inspect `session.allTasks`. Assert exactly one active task, one progress stream, and no state overwrite when the old timer deadline passes.

#### IOS-13 — Kokoro cache pruning races cache-hit lookup and has an unsynchronized launch flag

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_ios-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_swift-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/KokoroMLXService.swift:170`, `ios/Runner/KokoroMLXService.swift:172`, `ios/Runner/KokoroMLXService.swift:336`, `ios/Runner/KokoroMLXService.swift:340`, `ios/Runner/KokoroMLXService.swift:361`
- Evidence: Production prefetch launches multiple `synthesize` Futures. Each calls `pruneCacheIfNeeded` before the serial synthesis queue, while the static `pruneScheduled` Bool is read/written without synchronization. The utility prune deletes old WAVs concurrently with `fileExists`/touch/return on cache hits, so it can remove the exact path just before it is returned for playback.
- Triage rationale: With a cache over 200 MB on first synthesis after launch, a valid cache hit can become a nonexistent audio path, and concurrent first calls also constitute a Swift static-state race.
- Remediation: Protect scheduling with a lock/actor and serialize cache lookup/touch/write/prune through one cache coordinator. Pin/exclude a cache-hit entry until the caller has opened it, or return an opened handle/copy that pruning cannot invalidate.
- Verification: Populate more than 200 MB including a deliberately old target entry, launch several prefetch calls for it simultaneously, and verify under TSan that one prune is scheduled and every returned path still exists and plays through completion.

#### IOS-15 — PaddleOCR initializes two 31 MB ONNX models synchronously during Flutter engine startup

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_ios-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/AppDelegate.swift:77`, `ios/Runner/PaddleOcrPlugin.swift:57`, `ios/Runner/PaddleOcrPlugin.swift:92`, `ios/Runner/PaddleOcrPlugin.swift:118`
- Evidence: AppDelegate constructs PaddleOcrPlugin during `didInitializeImplicitFlutterEngine`; its initializer immediately calls `loadModels`. That call searches bundles, configures ORT, constructs det and rec sessions, and parses keys before returning. The committed det/rec assets are about 9.9 MB and 21.2 MB respectively.
- Triage rationale: This work is on the platform/main engine-initialization path even when the user never imports a PDF, delaying first usable UI and risking watchdog/jank on slower supported devices.
- Remediation: Make loading lazy and asynchronous on a dedicated serial OCR queue. Expose a loading state so the first OCR request awaits the single load operation; do not block plugin registration.
- Verification: Measure cold launch signposts on the oldest supported device before/after and confirm engine initialization no longer includes ORT session creation. Concurrent first OCR calls must share one load and receive deterministic success/failure.

#### IOS-17 — PaddleOCR collapses image and ONNX runtime failures into successful empty OCR

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_ios-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_swift-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/PaddleOcrPlugin.swift:145`, `ios/Runner/PaddleOcrPlugin.swift:251`, `ios/Runner/PaddleOcrPlugin.swift:338`, `ios/Runner/PaddleOcrPlugin.swift:412`
- Evidence: Unreadable images leave `blocks = []` and return success. Detection and recognition use `try? run`, converting ORT errors into no boxes/no line, while empty input/output names are replaced with guessed `x`/`out`. Dart therefore cannot distinguish a truly text-free page from decoder/model failure and does not fall back.
- Triage rationale: A corrupt input, incompatible model, or runtime failure silently drops script content, which is worse than a surfaced import failure.
- Remediation: Make OCR helpers throw typed load/decode/inference errors. Reject missing I/O names rather than guessing, propagate the first page/crop runtime failure to the channel (with page context), and reserve empty arrays for successful no-text inference.
- Verification: Exercise an unreadable image, invalid PDF page, injected ORT run error, empty model I/O metadata, and a valid blank page. Assert only the valid blank page returns an empty success and all failures reach Dart distinctly/fallback as designed.

#### IOS-10 — Resume persistence failures silently turn retries into full redownloads

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_ios-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_swift-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/BackgroundDownloadPlugin.swift:282`, `ios/Runner/BackgroundDownloadPlugin.swift:286`
- Evidence: Both resume-data writes and stale-blob removals use `try?`; `scheduleRetry` runs regardless. On disk-full or permission failure, the next attempt silently restarts a potentially multi-GB model from zero.
- Triage rationale: The transfer can waste substantial time/data while the UI claims resumable retry behavior. The failure should be visible and state should say whether retry is fresh.
- Remediation: Handle write/remove errors explicitly, log the underlying filesystem cause, and include `resuming: false` or a stable error in the Dart event before deciding whether to retry from scratch.
- Verification: Inject disk-full and permission errors when saving resume data. Verify one deterministic error/fresh-retry state is emitted and no log claims that bytes were saved when no blob exists.

### MLScriptsAdversary

#### ADV-06 — Serialize MLX cache pruning with cache hits and writes

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_ml-inference-pipeline-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/KokoroMLXService.swift:170-178`, `ios/Runner/KokoroMLXService.swift:246-250`, `ios/Runner/KokoroMLXService.swift:336-364`
- Evidence: pruneCacheIfNeeded launches an unsynchronized utility task before the cache-hit exists/touch/return sequence. The pruner can sample an old modification date, the synthesis call can then touch and return that path, and the pruner can delete it afterward; playback receives a path that no longer exists. The same detached deletion loop races a synthesis writing the stable cache URL. ML-07 captured only the launch flag, not this user-visible file-lifetime race.
- Adversarial disposition: pruneCacheIfNeeded launches an unsynchronized utility task before the cache-hit exists/touch/return sequence. The pruner can sample an old modification date, the synthesis call can then touch and return that path, and the pruner can delete it afterward; playback receives a path that no longer exists. The same detached deletion loop races a synthesis writing the stable cache URL. ML-07 captured only the launch flag, not this user-visible file-lifetime race.
- Remediation: Own lookup, touch, atomic write/adoption, and prune deletion on one cache actor/serial queue, or add an in-use lease set checked by the pruner. Do not rely on mtime as synchronization. Preserve synthesize's String path output and ensure the file exists when ownership transfers to playback.
- Verification: Inject a filesystem seam that pauses pruning after date enumeration, issue a cache hit and a cache miss/write, resume deletion, and assert returned WAVs remain readable and newly written files are never removed. Repeat under Thread Sanitizer for service state.

#### ADV-07 — Restore device power state when phone harness exits

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_shell-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/phone-harness.sh:55-59`, `scripts/phone-harness.sh:82-89`
- Evidence: The harness executes `adb shell svc power stayon true` and has no trap or corresponding restore on success, test failure, provisioning timeout, or interruption. It therefore permanently changes the connected device's stay-awake setting after every run; the comment claiming cleanup-friendly handling is contradicted by the absence of any cleanup trap.
- Adversarial disposition: The harness executes `adb shell svc power stayon true` and has no trap or corresponding restore on success, test failure, provisioning timeout, or interruption. It therefore permanently changes the connected device's stay-awake setting after every run; the comment claiming cleanup-friendly handling is contradicted by the absence of any cleanup trap.
- Remediation: Before mutation, capture the device's original stay_on_while_plugged_in value, install an EXIT/INT/TERM cleanup trap that terminates/waits for TESTPID when set and restores the exact original value, then enable stay-awake. Implement with set -euo pipefail and Bash 3.2 constructs, explicitly guarding expected-nonzero probes.
- Verification: Run successful, failing, no-install-timeout, and SIGINT harness stubs against a fake adb state store; after every exit assert the exact original power value is restored and the child process is gone.

### MLScriptsTriage

#### ML-01 — Android Kokoro readiness accepts corrupted extracted model files

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_ml-inference-pipeline-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/model_manager.dart:55`, `lib/data/services/model_manager.dart:68`, `lib/data/services/kokoro_onnx_service.dart:88`
- Evidence: ModelManager.isKokoroReady checks only that four paths exist. getKokoroPaths then supplies those paths to the sherpa initializer. The downloaded archive is SHA-256 checked before extraction, but later readiness checks do not validate file size, hash, the British lexicon, or the espeak data directory, so post-extraction truncation/corruption is reported ready.
- Adversarial disposition: The shallow readiness predicate is real and, more concretely than hypothetical post-extraction bit rot, direct extraction into the final models directory can leave a partial pack that contains the four checked files but lacks lexicon-gb-en.txt or espeak-ng-data. The proposed full manifest hash scan on every readiness call would repeatedly hash a large model pack. Extract into a staging directory, validate required nonempty files/directories after the already pinned archive hash, atomically publish it with a completion marker tied to the archive version/hash, and reserve full rehashing for repair diagnostics.
- Remediation: Persist and verify an extracted-pack manifest containing required relative paths, exact sizes, and hashes; make readiness and getKokoroPaths use the same verifier and expose the first failed entry.
- Verification: Create a valid extracted fixture, truncate each required file and remove each required directory in turn, and verify readiness becomes false with a specific repairable error; verify the intact manifest passes.

#### SHELL-01 — deploy reports success when device launch fails

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_shell-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/deploy.sh:23`, `scripts/deploy.sh:24`, `scripts/deploy.sh:25`
- Evidence: After a successful install pipeline, process launch redirects all output and uses || true, then prints 'deployed + launched' and exits 0 regardless of launch status.
- Triage rationale: The operator receives a false success for the final requested action, including startup crashes or policy failures.
- Remediation: Capture launch output/status, report install and launch as separate stages, and exit nonzero on launch failure while retaining the diagnostic.
- Verification: Stub install success plus launch failure and assert nonzero status/no success message; verify successful install+launch remains zero.

#### SHELL-04 — phone harness ignores critical provisioning failures

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_shell-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/phone-harness.sh:13`, `scripts/phone-harness.sh:64`, `scripts/phone-harness.sh:65`, `scripts/phone-harness.sh:66`
- Evidence: The script deliberately omits errexit. Model pushes have explicit guards, but mic grant, app-op, and volume commands redirect errors and have no status checks. It can later print provisioned based solely on a file-count check.
- Adversarial disposition: The permission/app-op/volume failures are genuinely ignored, but the proposed plan explicitly preserves the script's missing errexit despite the required shell invariant. Restore set -euo pipefail, put cleanup/state restoration in an EXIT/INT/TERM trap, and wrap only expected-nonzero polling/uninstall/wait probes in if/|| true. Verify each required adb state before printing provisioned.
- Remediation: Keep cleanup-friendly explicit status handling, but guard each required adb command and verify the resulting permission/app-op/volume state before declaring provisioned.
- Verification: Force each adb operation to fail independently and assert the harness aborts with the exact failed prerequisite and terminates/cleans the child test.

#### SHELL-05 — phone harness can wait forever after provisioning timeout

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_shell-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/phone-harness.sh:59`, `scripts/phone-harness.sh:82`
- Evidence: flutter test is backgrounded. If the 120-iteration package loop expires, execution falls through to wait $TESTPID without recording provisioning failure or imposing a test deadline.
- Adversarial disposition: The unbounded wait is real. The fix must not assume GNU timeout, wait -n, or Bash 4: under /bin/bash 3.2, poll kill -0 against a deadline, hard-fail the no-install timeout, terminate and wait for the child in cleanup, and guard expected nonzero statuses under set -euo pipefail. Preserve and restore device state in the same trap.
- Remediation: Track whether provisioning completed; on timeout terminate the child process tree, restore device state via trap, print the test log tail, and exit nonzero. Also impose an overall test timeout.
- Verification: Use a test that never installs and one that installs then hangs; assert bounded termination, child cleanup, state restoration, and distinct diagnostics.

#### SHELL-06 — play changelog accepts malformed version code in output path

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_shell-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/play-changelog.sh:14`, `scripts/play-changelog.sh:16`, `scripts/play-changelog.sh:18`
- Evidence: VERSION_CODE is everything after the last '+'; when '+' is absent it remains the full 'version: ...' line and is interpolated into the metadata filename. Missing version lines abort through grep with no controlled diagnostic.
- Triage rationale: Release notes can be written to the wrong filename while the command appears to target the current release.
- Remediation: Parse pubspec version once, require exactly name+numericCode with a Bash-3-compatible case/grep validation, and abort before mkdir/write on any mismatch.
- Verification: Cover valid, missing, duplicate, no-plus, and nonnumeric version lines; only the valid case may create a numeric changelog filename.

#### SHELL-07 — line-boundary changelog truncation can produce no notes

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_shell-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/play-changelog.sh:70`, `scripts/play-changelog.sh:75`, `scripts/play-changelog.sh:79`
- Evidence: For input over 500 bytes whose first line exceeds the 497-byte line budget, awk exits before printing anything. The later -s check prevents shipping empty notes, but the advertised automatic truncation fails completely. wc -c also enforces bytes rather than Play's character limit, causing unnecessary truncation of UTF-8 text.
- Adversarial disposition: The triage understates impact: awk writes an empty $OUT.tmp and mv replaces the existing canonical release-notes file before the later -s check fails, so one long first line destroys prior notes. Build and Unicode-count in a temporary file, hard-cut only when no line fits, validate nonempty and ≤500 code points, then atomically replace OUT. Reuse Python 3 rather than locale-sensitive wc -m; retain set -euo pipefail.
- Remediation: Count Unicode characters with a deterministic UTF-8-capable helper, preserve lines when possible, and hard-cut with an ellipsis when no complete line fits.
- Verification: Test one long line, multiline text, no trailing newline, emoji, and combining characters; assert nonempty output of at most 500 Play-counted characters.

#### SHELL-08 — Play icon alpha verification fails open

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_shell-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/play-preflight.sh:74`, `scripts/play-preflight.sh:75`
- Evidence: If python3, Pillow, or image decoding fails, `|| echo 0` sets HAS_ALPHA to the same value as a verified opaque image. Preflight can then pass an icon it never inspected.
- Triage rationale: This is a release gate whose direction of failure is permissive; Play can reject the upload later.
- Remediation: Check interpreter/Pillow availability up front and make verifier errors call bad/cause failure. Distinguish verified opaque, verified alpha, and unknown/error.
- Verification: Run with Pillow missing, corrupt PNG, unreadable file, opaque RGB, palette transparency, and RGBA; only verified opaque should pass.

#### SHELL-11 — Play signing gate rejects only a textual debug certificate

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_shell-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/ship-play.sh:60`, `scripts/ship-play.sh:63`, `scripts/ship-play.sh:69`
- Evidence: The gate extracts one signature entry, parses a locale-dependent Owner line, and rejects it only if it contains 'Android Debug'. It never positively compares the certificate fingerprint to the configured upload certificate, so any other signing key passes the local gate.
- Adversarial disposition: No external Play behavior is needed to prove the local gate is wrong: any non-debug third-party release certificate yields a nonempty Owner not containing Android Debug and passes, despite the comment claiming verification of our upload key. Compare locale-independent SHA-256 certificate fingerprints of the AAB signer and configured keystore, failing closed on zero/multiple/parse failures.
- Remediation: Derive the expected SHA-256 certificate fingerprint from the configured keystore once, compare it to the AAB signing certificate using locale-independent keytool output, and fail closed on parse ambiguity.
- Verification: Build/sign fixtures with the intended upload key, Android debug key, and a third release key under varied locales/JDKs; only the intended fingerprint may reach upload.

#### SHELL-12 — ORT APK verifier can compare against the wrong cached dependency

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_shell-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_ml-inference-pipeline-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/verify-apk-ort.sh:12`, `scripts/verify-apk-ort.sh:14`, `scripts/verify-apk-ort.sh:15`
- Evidence: find selects the first sherpa_onnx_android_arm64 match anywhere in pub-cache instead of the version locked by this project. find | head can also yield a SIGPIPE failure under pipefail when multiple matches exist. Both source and APK then compare only the first VERS_ string, despite a library potentially containing multiple version tags.
- Triage rationale: A release verification script can fail spuriously or, worse, pass against an unrelated cached version/incomplete tag set.
- Remediation: Read the exact package version from pubspec.lock/package_config, construct that cache path, and compare the complete sorted unique version-tag sets. Avoid head pipelines under pipefail.
- Verification: Create caches with multiple package versions and libraries with multiple VERS_ tags; assert selection follows the lockfile and any set mismatch fails deterministically under Bash 3.2.

#### SHELL-13 — MLX harness relink deletes working links before validating sources

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_shell-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_mlx-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `tools/mlx-harness/link-sources.sh:10`, `tools/mlx-harness/link-sources.sh:15`
- Evidence: Each vendor destination is rm -rf'd before find runs in process substitution. Failure inside process substitution is not propagated by set -e to the while loop, so a missing/unreadable source tree can produce zero links and a successful final echo.
- Adversarial disposition: The destructive process-substitution failure is confirmed, but 'atomically swap the completed tree' is incomplete on macOS: mv cannot atomically replace an existing nonempty directory, and there are two vendor trees. Validate both source dirs first, capture each checked find result to a temporary manifest, build both staged trees, move current trees to backups, install staged trees, and rollback from the trap on any failure. Use while IFS= read -r under Bash 3.2; do not use mapfile/readarray.
- Remediation: Validate both source directories first, build links in a temporary sibling tree, require nonzero expected files and successful find status, then atomically swap the completed tree.
- Verification: Run with valid sources, missing vendor, unreadable vendor, and paths containing spaces; failures must preserve the prior link tree and return nonzero under /bin/bash 3.2.

#### MEDIA-01 — Silence-trim test assumes 44.1 kHz for all decoded PCM

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_media-provenance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/test_silence_trim.swift:33`, `scripts/test_silence_trim.swift:35`, `scripts/test_silence_trim.swift:95`
- Evidence: AVAssetReader output settings request PCM format/bit depth but do not request a sample rate. The script then hardcodes 44100 to choose 50 ms sample windows and converts window indexes to seconds. A 48 kHz source therefore uses too-small windows while still labeling each as 50 ms.
- Adversarial disposition: The 44.1 kHz assumption mathematically mis-scales timestamps for 48 kHz input, but this file is an operator test that writes a temporary demonstration export, not the app's trimming implementation or provenance pipeline. P3 is the proportional severity; derive the rate from the output sample-buffer ASBD and retain the existing CMTimeRange contract.
- Remediation: Read the output track format/sample rate from the CMSampleBuffer format description (or explicitly request a supported rate) and derive both windowSamples and timestamps from it.
- Verification: Use equivalent 44.1 kHz and 48 kHz fixtures with known leading/trailing silence; assert detected boundaries agree within one window and exports preserve speech.

#### MEDIA-02 — Silence-trim test reuses fixed shared temporary files

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_media-provenance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/test_silence_trim.swift:123`, `scripts/test_silence_trim.swift:141`
- Evidence: Remote input always writes /tmp/test_audio_trim.m4a and exports always write /tmp/trimmed_output.m4a after deleting it. Concurrent invocations share and overwrite both names.
- Triage rationale: Operator-only tooling can analyze or report another invocation's bytes and clobber outputs.
- Remediation: Create a unique temporary directory per invocation with FileManager, place both files inside it, and clean it via defer unless an explicit --keep-output path is requested.
- Verification: Run two invocations concurrently with distinguishable fixtures and assert each output hash corresponds to its own input and cleanup is isolated.

#### MEDIA-03 — Remote test input uses force-try URL download and write

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_media-provenance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/test_silence_trim.swift:124`, `scripts/test_silence_trim.swift:125`
- Evidence: URL construction is force-unwrapped and Data(contentsOf:) plus data.write use try!. Network, malformed-URL, and filesystem failures terminate with a Swift trap rather than a controlled CLI error.
- Triage rationale: The path is test-only and operator-invoked, so P3, but it is an avoidable opaque failure.
- Remediation: Validate URL scheme, use do/catch around fetch/write, print the failing operation and underlying error to stderr, and exit nonzero.
- Verification: Exercise malformed URL, HTTP failure, interrupted fetch, and unwritable temp directory; assert concise diagnostics and nonzero status without a crash backtrace.

#### ML-04 — Unknown Android voice IDs silently select af_heart

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_ml-inference-pipeline-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/kokoro_onnx_service.dart:219`, `lib/data/services/tts_service.dart:628`
- Evidence: The ONNX request uses voiceIds[voice] ?? voiceIds['af_heart']!, whereas the iOS service throws voiceNotFound. Current production callers resolve voices from internal maps, so this is a configuration/version-skew failure rather than an attacker-controlled path.
- Adversarial disposition: Saved voice overrides can cross this boundary without validation, so the silent af_heart substitution is real. The fix need not replace Future<String?> with a typed result: reject an unknown voice, log it, and return null through the existing failure contract, or validate at assignVoice while retaining a defensive null at the engine seam.
- Remediation: Return a typed unknownVoice failure from KokoroOnnxService and let TtsService choose/log an explicit product fallback at the call site if desired.
- Verification: Submit every registered voice and one unknown value to both platform seams; assert known IDs map correctly and unknown values produce the same explicit result on Android and iOS.

#### PY-03 — Multi-speaker cue recognition validates only one substring

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_python-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/parse_script.py:155`, `scripts/parse_script.py:163`
- Evidence: The fallback accepts an all-caps comma list when any KNOWN_CHARACTERS string is a substring of names_str, then returns the entire raw list as one character. It neither tokenizes and validates every name nor normalizes aliases.
- Adversarial disposition: The any-substring validation is genuinely too weak, but this is an offline reference/example parser and the checked-in output intentionally represents valid ensemble cues such as MARY, KITTY, LYDIA as one String because ScriptLine has only one character field. Validate every split component and aliases, but do not invent a multi-speaker output schema without migrating all JSON/example consumers. P2 overstates a developer conversion heuristic.
- Remediation: Split the cue on commas, normalize punctuation and aliases, require every component to resolve to a known speaker, and represent multi-speaker attribution explicitly rather than concatenating a name.
- Verification: Cover all-known, one-known-plus-unknown, aliases, substring collisions, and shouted all-caps prose; assert only the intended cues parse.

#### PY-04 — ACT and SCENE prefix matches consume dialogue text

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_python-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/parse_script.py:256`, `scripts/parse_script.py:278`
- Evidence: ACT uses ^ACT followed by a numeral without an end anchor. SCENE is likewise prefix-only and case-insensitive. Both store the entire line as header state and continue, dropping any remainder from dialogue output.
- Adversarial disposition: Prefix-only ACT/SCENE matching can consume a wrapped dialogue line, but it is an offline OCR/reference parser with no production app path shown. Full-line format-specific regexes are appropriate; P3 matches the actual operator-tool blast radius.
- Remediation: Use full-line, format-specific header regexes after trimming, with bounded optional punctuation/title syntax derived from supported source formats.
- Verification: Test canonical Roman/digit headers, titled scene headers, and dialogue sentences beginning with act/scene plus a numeral; only canonical headers may transition state.

#### PY-05 — Folger orphan-dialogue guard is a no-op

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_python-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/pdf_to_script.py:288`, `scripts/pdf_to_script.py:291`
- Evidence: In the elif dialogue_parts branch, not current_char and not stage_dir executes pass, after which output.append still runs unconditionally. Thus the comment's intended orphan suppression is not implemented.
- Adversarial disposition: The pass is a no-op and orphan dialogue is unconditionally appended, but this affects an offline Folger conversion heuristic rather than production runtime. Change the condition to skip/log only proven orphans while preserving current_char page continuations; P2 is disproportionate.
- Remediation: Use continue/conditional append for true orphans and record them in a diagnostic count/sample so page-continuation heuristics can be evaluated instead of silently discarded.
- Verification: Feed visual-line fixtures for normal continuation, new-page continuation, front matter, and isolated text; assert only attributable/explicitly supported continuations are emitted.

#### PY-06 — PDF output encoding is locale-dependent

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_python-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/pdf_to_script.py:363`
- Evidence: Path.write_text(result) omits encoding while the extracted Shakespeare text can contain curly quotes, em dashes, and IPA/Unicode characters.
- Triage rationale: On a non-UTF-8 Python locale the operator tool can fail or produce incompatible bytes. macOS normally defaults UTF-8, so severity is P3.
- Remediation: Specify encoding='utf-8' for writes and reads of generated text throughout these scripts.
- Verification: Run under a forced non-UTF-8 locale with non-ASCII fixture text and assert UTF-8 output round-trips exactly.

#### PY-08 — Positional comparison misaligns after one inserted cue

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_python-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/compare_macbeth_versions.py:124`
- Evidence: The report zips the first 12 dialogue blocks solely by index. One edition-specific insertion shifts all following printed pairs, yet each is labeled as an attribution/text mismatch.
- Adversarial disposition: The utility explicitly prints a small first-12-block side-by-side sample and documents known editorial differences; it does not claim sequence alignment or label rows as authoritative mismatches. SequenceMatcher would be a feature enhancement, not a demonstrated defect.
- Remediation: Align cue/text sequences using a small sequence matcher keyed by normalized character and text prefix, showing insertions/deletions explicitly.
- Verification: Compare fixtures with one inserted, deleted, and renamed cue; assert subsequent matching blocks realign.

#### SHELL-10 — Crash-report pull failures are reported as no crashes

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_shell-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/pull-crashlog.sh:48`, `scripts/pull-crashlog.sh:53`
- Evidence: idevicecrashreport redirects stderr and uses || true. If it is missing, the device disconnects, or the UDID is wrong, the script proceeds to search old/shared directories and can print 'No Runner crash logs found on device.'
- Triage rationale: Operator diagnostics conflate acquisition failure with a valid empty result.
- Remediation: Capture status/stderr; search only the current unique pull directory; fail with the pull diagnostic on acquisition error and reserve the empty message for a successful pull.
- Verification: Stub successful-empty, successful-with-log, command-missing, bad-UDID, and disconnect cases and assert distinct outcomes.

#### SHELL-14 — phone-harness log filename is predictable

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_shell-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/phone-harness.sh:19`
- Evidence: OUT uses TMPDIR or /tmp plus epoch seconds. Another local process can predict/precreate the file or two invocations in one second can collide; the harness later greps it for PROBE and pass/fail output.
- Triage rationale: Shared-host/local tampering can falsify benchmark results, but the tool is operator-only.
- Remediation: Create the log with mktemp and restrictive permissions, install a cleanup trap, and optionally retain it only on failure or explicit flag.
- Verification: Launch concurrent harness stubs and precreate predicted names; assert unique logs and no symlink/preexisting-file following.

#### SHELL-15 — pull-debuglog uses a shared predictable output directory

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_shell-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/pull-debuglog.sh:13`, `scripts/pull-debuglog.sh:17`, `scripts/pull-debuglog.sh:31`
- Evidence: The script recursively deletes and recreates /tmp/castcircle-debug, then trusts debug_log.txt there. Concurrent runs share it and a local user can interfere with the directory/file. LINES is quoted but unvalidated, so malformed input causes an opaque tail error rather than command injection.
- Triage rationale: Operator-only diagnostics can display stale/planted content; severity is P3.
- Remediation: Use mktemp -d, trap cleanup, validate LINES as a positive decimal with Bash-3-compatible case matching, and require a nonempty copied file.
- Verification: Run concurrent pulls, a planted symlink/path, empty successful copy, and invalid line counts; assert isolation and controlled errors.

### NativeAdversary

#### ADV-02 — Do not cancel sibling chunks in one Kokoro prefetch

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_simd-accelerate-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/tts_service.dart:628-641`, `lib/data/services/tts_service.dart:823-837`, `ios/Runner/KokoroMLXService.swift:175-202`
- Evidence: prepareKokoro eagerly invokes synthesize once for every chunk, but every native synthesize call increments one global synthGeneration. When two uncached sibling chunks reach the serial queue, any earlier job whose block starts after the later increment returns KokoroError.cancelled. The Dart caller explicitly expects every sibling Future to produce a path, so long-line prefetch can cancel its own chunks, synthesize a later chunk first, and force on-demand retries before playback.
- Adversarial disposition: prepareKokoro eagerly invokes synthesize once for every chunk, but every native synthesize call increments one global synthGeneration. When two uncached sibling chunks reach the serial queue, any earlier job whose block starts after the later increment returns KokoroError.cancelled. The Dart caller explicitly expects every sibling Future to produce a path, so long-line prefetch can cancel its own chunks, synthesize a later chunk first, and force on-demand retries before playback.
- Remediation: Stop treating every synthesize invocation as superseding every earlier invocation. Pass an explicit request/group ID and urgency through the platform channel; sibling chunks in one group must share a cancellation epoch and all run serially, while only an explicit newer urgent request may invalidate older groups. Preserve the serial synthQueue for MLX/NLTagger safety.
- Verification: Prefetch a three-chunk uncached line and assert all three Futures return distinct existing WAV paths without cancellation and in queue order. Then enqueue an older prefetch group followed by an urgent group and assert only the explicitly superseded group is cancelled; also cover cache-hit siblings.

#### ADV-03 — Count audio frames, not interleaved samples, when trimming speech

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_simd-accelerate-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/AppleSttPlugin.swift:514-529`, `ios/Runner/AppleSttPlugin.swift:536-579`, `ios/Runner/AppleSttPlugin.swift:608-614`
- Evidence: detectSpeechRange requests interleaved PCM, then treats length/2 as a mono frame count and forms each 50 ms window from sampleRate*0.05 Int16 values. For a valid two-channel recording, each window contains only 25 ms of frames while the returned CMTimeRange still advances by 50 ms per window, producing incorrect trim boundaries and potentially an end beyond the asset duration. The recording path preserves every tap channel and imposes no mono-only invariant.
- Adversarial disposition: detectSpeechRange requests interleaved PCM, then treats length/2 as a mono frame count and forms each 50 ms window from sampleRate*0.05 Int16 values. For a valid two-channel recording, each window contains only 25 ms of frames while the returned CMTimeRange still advances by 50 ms per window, producing incorrect trim boundaries and potentially an end beyond the asset duration. The recording path preserves every tap channel and imposes no mono-only invariant.
- Remediation: Read the channel count from the sample buffer's audio format, convert interleaved frames to one mono analysis stream (or compute RMS across all channels per frame), and advance windows and carry in frame units. Clamp the final range to the asset duration.
- Verification: Analyze mono and stereo fixtures containing identical leading silence, speech, and trailing silence, including speech crossing CMSampleBuffer boundaries. Assert both formats return the same start/end times within one 50 ms window and that the range never exceeds asset.duration.

### NativeTriage

#### SIMD-002 — Recording path allocates and deep-copies a PCM buffer on the real-time tap thread

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_simd-accelerate-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/AppleSttPlugin.swift:38`, `ios/Runner/AppleSttPlugin.swift:39`, `ios/Runner/AppleSttPlugin.swift:44`, `ios/Runner/AppleSttPlugin.swift:301`
- Evidence: When audioFile is non-nil, every tap callback constructs a new AVAudioPCMBuffer, sets its length, and bulk-copies each channel before enqueueing the copy for file I/O. `UnsafeMutablePointer.update(from:count:)` is a bulk copy rather than the review's claimed Swift per-sample loop, but allocation and copy do occur synchronously on the render callback. Nil copies are silently skipped.
- Adversarial disposition: The callback deterministically calls AVAudioPCMBuffer's allocating initializer and copies every channel before returning, then places each owned copy on an unbounded serial DispatchQueue. This is not merely a possible scalar-loop optimization: heap allocation has unbounded latency and is unsafe in an AVAudioEngine render callback, while a stalled writer can retain an unbounded number of copies. Replace this with a bounded pool or lock-free SPSC ring of format-sized buffers; the writer must recycle slots, and the render callback must drop/count a buffer rather than allocate or wait when the pool is exhausted.
- Remediation: Use a bounded pool/ring of preallocated per-format PCM buffers, recycle a buffer only after audioFileQueue finishes writing it, and record a lightweight dropped-buffer counter when the pool is exhausted rather than logging from the render thread.
- Verification: Stress record on physical low-memory devices while inducing I/O pressure; measure tap callback p95/p99, audio underruns, dropped-buffer count, and output continuity. Confirm multichannel float and Int16 copies remain bit-for-bit correct.

#### SIMD-007 — Whole-file audio loudness analysis has unbounded PCM residency

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_simd-accelerate-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/AudioAnalysisPlugin.swift:48`, `ios/Runner/AudioAnalysisPlugin.swift:51`, `ios/Runner/AudioAnalysisPlugin.swift:52`, `lib/data/services/audio_level_service.dart:31`
- Evidence: The native method converts file.length to AVAudioFrameCount, allocates one AVAudioPCMBuffer with that full frameCapacity, then reads the entire decoded file into it before analysis. AudioLevelService passes recording paths over the production com.lineguide/audio_analysis channel and imposes no duration or file-size bound. For float PCM, resident bytes scale as frames × channels × 4 (for example, 10 minutes at 48 kHz stereo is roughly 230 MB, not the review's understated 46 MB).
- Triage rationale: This is source-proven input-proportional peak memory on a reachable production path and can create memory pressure for long or remotely supplied recordings.
- Remediation: Read AVAudioFile in a fixed-size reusable PCM buffer (for example 32K–64K frames), accumulate sum of squares, peak, and sample count across chunks, and return the same dBFS contract.
- Verification: Analyze mono/stereo fixtures, empty/corrupt files, and a long generated recording. Assert chunked results match a trusted whole-file calculation within a numeric tolerance and use Instruments to confirm peak allocation remains bounded as duration grows.

#### SIMD-014 — Concurrent contact picker calls can strand the first Flutter result

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_simd-accelerate-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/ContactPickerPlugin.swift:8`, `ios/Runner/ContactPickerPlugin.swift:27`, `ios/Runner/ContactPickerPlugin.swift:30`, `ios/Runner/ContactPickerPlugin.swift:72`, `ios/Runner/ContactPickerPlugin.swift:77`
- Evidence: Every pickContact assigns pendingResult without checking an existing request. A second invocation replaces the first callback; delegate completion resolves only the most recently stored callback, so the first platform-channel Future never completes. Also, the NO_VIEW_CONTROLLER path resolves result after storing it but does not clear pendingResult.
- Triage rationale: This is deterministic state-machine behavior on a production-registered platform channel, not merely a performance observation.
- Remediation: Guard pendingResult == nil and immediately resolve a second call with an ALREADY_ACTIVE FlutterError; only assign pendingResult after a presenter is found, or clear it on presentation failure. Ensure every delegate/failure path takes and nils the callback exactly once.
- Verification: Add focused plugin tests or a harness that invokes pickContact twice before delegate completion and exercises no-view-controller, select, and cancel paths; assert every Flutter result resolves exactly once and only one picker is presented.

### PerformanceTriage

#### PERF-03 — Recordings browser resolves files serially and performs an O(R×C) cache-name search on fallback

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_dart-performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_flutter-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/features/recording_studio/recordings_browser_screen.dart:196`, `lib/features/recording_studio/recordings_browser_screen.dart:601`, `lib/features/recording_studio/recordings_browser_screen.dart:631`
- Evidence: _scanFileExistence awaits _resolveRecordingPath inside a for loop, serializing up to two File.exists calls per recording. _cachedRecordingPaths correctly walks recording_cache only once, but every unresolved recording then firstWhere-scans the entire cached path list by basename/scriptLineId. With R listed recordings and C cached files, fallback matching is O(R×C), in addition to serial stat latency. This scan is launched whenever the recording-id list changes and controls which rows are marked playable.
- Adversarial disposition: Serial probes and O(R×C) fallback are proven, but there is no existing scan generation guard to retain. Each unawaited scan unconditionally replaces _fileResolved after only a mounted check. The fix must add generation/key validation alongside indexes and bounded concurrency.
- Remediation: Build basename and script-line lookup indexes once alongside _recordingCachePaths, and resolve recordings with a small bounded-concurrency stat pool. Retain the existing scan-key cancellation/generation guard so stale async scans cannot overwrite a newer list.
- Verification: Create R local/stale recording rows and C cache files, including basename and line-id fallback cases. Instrument stat and cache comparisons to demonstrate O(R+C) indexing rather than O(RC), verify all resolution semantics, and measure time-to-resolved-state for 100/500/1,000 rows.

#### PERF-05 — SyncQueue rewrites the complete queue snapshot on every enqueue and upload transition

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_dart-performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_flutter-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/sync_queue.dart:177`, `lib/data/services/sync_queue.dart:340`, `lib/data/services/sync_queue.dart:384`, `lib/data/services/sync_queue.dart:401`, `lib/data/services/sync_queue.dart:409`, `lib/data/services/sync_queue.dart:428`
- Evidence: _persist jsonEncodes every pending and failed job, writes the entire JSON to a temp file with flush:true, and renames it. It is called after enqueue and after each success, retry removal, and terminal failure. Recording N offline lines generates growing snapshots of sizes 1..N; later draining rewrites sizes N..0, yielding O(N²) cumulative serialized bytes and queue-file work. Calls are chained, so a burst can also leave a long persistence backlog.
- Triage rationale: The queue's crash durability is load-bearing, but full-snapshot persistence per mutation has a concrete growing-work defect during long offline rehearsals.
- Remediation: Persist queue jobs as keyed rows in the existing Drift database (upsert on enqueue, update retry/error, delete on success) within transactions, with a one-time migration from sync_queue.json. This makes each mutation O(1) and preserves crash safety without a custom journal/compaction protocol.
- Verification: Run enqueue/retry/success sequences for 1,000 jobs, kill/recreate the service between every transition class, and assert exact restoration/supersession semantics. Instrument bytes written or SQL row mutations to show O(N) total mutation work instead of O(N²), and test migration from valid/corrupt legacy JSON.

#### PERF-06 — STT adaptation copies and reserializes the complete growing sample history after each recorded line

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_dart-performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_flutter-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/stt_adaptation_service.dart:221`, `lib/data/services/stt_adaptation_service.dart:235`, `lib/data/services/stt_adaptation_service.dart:309`
- Evidence: addSample appends by allocating [...actorProfile.samples, sample] and a second [...prodProfile.samples, sample], so each line copies growing histories. _schedulePersist waits two seconds, but normal spoken lines are farther apart, so it commonly fires once per line. _persistProduction synchronously jsonEncodes every actor profile and pooled sample before its first filesystem await, then rewrites profiles.json. Across N lines this is O(N²) cumulative list-copy/JSON work and duplicates each sample in actor and pooled arrays.
- Triage rationale: The workload is a normal long rehearsal, not an artificial call flood; the growing synchronous encode runs on the UI isolate after each sample interval.
- Remediation: Store samples incrementally as normalized Drift rows keyed by production/actor/audioPath and store small profile metadata separately; derive pooled views by query rather than duplicating sample JSON. Batch status updates with the sample insert and migrate existing profiles.json once.
- Verification: Add 100/500/1,000 samples across multiple actors and compare per-add p95 and total allocated/written bytes; the new path should remain approximately constant per add/O(N) total. Verify hydration merge, duplicate-audioPath precedence, pooled totals, status thresholds, and crash recovery.

#### PERF-08 — Bulk cast setup serializes one remote invitation and one local save per actor

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_dart-performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_flutter-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/features/cast_manager/bulk_cast_setup_screen.dart:265`, `lib/features/cast_manager/bulk_cast_setup_screen.dart:310`, `lib/providers/production_providers.dart:216`
- Evidence: _saveCastAssignments loops filled controllers and awaits SupabaseService.createCastInvitation for each actor, then awaits CastMembersNotifier.save for that actor before continuing. Saving A actors therefore takes A serial network round trips plus A serial Drift writes/state emissions. The save screen remains in _saving for the whole sum.
- Triage rationale: Bulk setup exists specifically for multi-actor workloads; serial remote latency grows linearly with the number filled. The per-keystroke controller scans alleged elsewhere are small and scoped, but this save path is a concrete latency defect.
- Remediation: Add a Supabase bulk invitation insert returning all ids, preserve per-row failure reporting, then batch the successful/fallback local members through the repository/notifier transaction from PERF-07 with one state update. If the backend cannot return per-row results, use a small bounded concurrency pool rather than unbounded Future.wait.
- Verification: Exercise all-success, partial-cloud-failure, signed-out, and retry cases for 1/20/100 actors; verify generated member ids/invite links and _failedCloudInvites are correct. Count remote requests, DB transactions, and provider emissions, and measure save latency under injected network delay.

#### PERF-09 — Text/PDFKit import performs multi-pass and worst-case quadratic matching synchronously on the UI isolate

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_dart-performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_flutter-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/script_import_service.dart:37`, `lib/data/services/script_import_service.dart:45`, `lib/data/services/script_import_service.dart:123`, `lib/data/services/script_import_service.dart:132`, `lib/data/services/script_import_service.dart:746`, `lib/data/services/script_parser.dart:117`, `lib/data/services/script_parser.dart:854`, `lib/data/services/script_parser.dart:929`, `lib/data/services/script_parser.dart:1137`
- Evidence: importFromTextFile/importFromMarkdown return ScriptParser.parse directly after async file reads, importFromText is synchronous, and the PDFKit success path calls parse and source-page mapping on the caller isolate. parse is a multi-pass whole-script pipeline. _mergeOcrCharacterNames compares rare candidates against all candidates and runs O(L²) edit distance, giving O(K²L²) worst-case work; title-case abbreviation resolution is another O(K²) nested scan. PDFKit mapping calls _findSourcePageFrom per parsed line; successful ordered matches are amortized forward, but a miss does not advance rawSearchStart, so U unmatched parsed lines can each scan the remaining R raw lines: O(U×R). By contrast, the scanned-OCR path explicitly uses Isolate.run because this class of work froze its spinner.
- Triage rationale: The review's numeric 'seconds' estimates were not established for every text input, but the UI-isolate reachability and growing asymptotic work are directly proven by current control flow. Constant RegExp constructions in per-line parser helpers add allocation cost but are folded into this same import-pipeline finding rather than reported as micro-findings.
- Remediation: Make production import APIs asynchronous and run parsing plus page mapping in Isolate.run for all text/PDFKit paths, migrating every caller. Replace unbounded _findSourcePageFrom misses with the bounded/indexed normalized matcher already used by the OCR path. Then benchmark candidate counts; if K² dominates, bucket fuzzy candidates by first character/length and use thresholded edit distance with early exit/reused typed rows; bucket title prefixes similarly. Hoist only regexes shown by the benchmark or clearly invoked per input line.
- Verification: Benchmark representative and adversarial scripts at 500/1,500/5,000 lines, varying candidate-name count and unmatched-page ratio; report total latency, isolate/UI CPU, allocations, and worst Flutter frame. Add equivalence tests asserting parsed lines/characters/scenes/source pages are byte-for-byte unchanged across the worker cutover, and a scaling test that unmatched mapping no longer grows as U×R.

### SecurityAdversary

### SecurityCloudTriage

#### AUTH-01 — Committed auth policy accepts six-character passwords with no strength requirement

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_security-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_gcp-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_aws-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `supabase/config.toml:169`, `supabase/config.toml:175`, `supabase/config.toml:178`, `docs/RELEASING.md:218`
- Evidence: Public email signup is enabled, `minimum_password_length = 6`, and `password_requirements = ""`. Release documentation directs operators to apply this file with `supabase config push`, so this is not merely an unused local fixture.
- Triage rationale: Attack preconditions are knowledge of an account email and a victim choosing a weak/reused six-character password; server sign-in rate limits slow but do not eliminate credential stuffing across IPs. Successful compromise exposes that user's joined productions, cast details, scripts, and voice recordings and permits writes allowed to that member.
- Remediation: Raise the minimum substantially (at least the product's agreed modern baseline; prefer long passphrases) and enable breached-password screening if the hosted plan supports it. Do not rely on composition alone; keep rate limiting and add CAPTCHA/abuse protection to public signup/sign-in.
- Verification: Apply in staging, attempt signup and password change with six/seven-character and known-compromised passwords and assert rejection; verify a compliant passphrase succeeds and existing-user login/reset flows still work.

#### AUTH-02 — Password changes do not require recent reauthentication

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_security-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_gcp-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `supabase/config.toml:207`, `supabase/config.toml:214`, `docs/RELEASING.md:218`
- Evidence: Email address changes require double confirmation, but `secure_password_change = false`. The configuration is the file operators push to the hosted project.
- Triage rationale: Attack precondition is theft of an already valid user session/token. The attacker can change the password without proving the current password or recent authentication, converting a temporary session compromise into persistent account takeover and locking out the legitimate user. Existing session theft already exposes data, but this setting increases persistence and recovery impact.
- Remediation: Set `secure_password_change = true` and ensure the client handles the reauthentication/nonce flow with a generic error and a clear user prompt. Review session revocation behavior after password change.
- Verification: In staging, age a session beyond the secure-change window and assert a password change is rejected until reauthentication; assert a freshly reauthenticated user can change it and prior sessions are handled per policy.

#### SEC-04 — Persistent logs contain join credentials and copyrighted/private script content

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_security-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_crypto-security-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/deep_link_service.dart:132`, `lib/data/services/supabase_service.dart:477`, `lib/features/rehearsal/rehearsal_screen.dart:1786`, `lib/features/production_hub/production_hub_screen.dart:166`, `lib/data/services/debug_log_service.dart:78`, `lib/data/services/debug_log_service.dart:145`
- Evidence: Deep-link handling prints the full URI, including `code`, `char`, and `name`. `lookupByJoinCode` logs `code=$code` into DebugLogService. Rehearsal logs `MY LINE` plus up to 40 characters of actual dialogue. ProductionHub logs the production title and selected character. DebugLogService synchronously appends every entry to `Documents/debug_log.txt`, retains it across crashes, and exposes logs through the in-app share screen.
- Adversarial disposition: The core exposure is confirmed, but the evidence must distinguish sinks. lookupByJoinCode writes the complete join code to DebugLogService; rehearsal writes dialogue excerpts; lookup success writes the production title. Those entries are synchronously persisted and can be uploaded to debug_reports, shared, or copied from the debug screen, so a support-log recipient can obtain an active join credential and private/licensed content. By contrast, DeepLinkService's full raw URI and ProductionHub's character/title diagnostic use debugPrint, not the persistent DebugLogService file. The corrected P2 finding should rely on the verified persistent/export path rather than claim that every cited console message is stored in debug_log.txt.
- Remediation: Never log join codes, raw deep-link query strings, actor/contact names, titles, dialogue, local paths, or storage object paths. Introduce structured redaction at the logger boundary for credential-bearing keys and change call sites to stable opaque event IDs/counts. Keep verbose content logging behind a non-release, explicit developer mode that never writes to the persistent/exportable log.
- Verification: Exercise a deep-link join, lookup, production open, and rehearsal line, then inspect the persisted/exported log and captured platform console. Assert none of the join code, actor/character names, production title, dialogue substring, or raw URI appears; assert useful redacted event markers remain.

#### SUPPLY-01 — Non-default ONNX Runtime versions are vendored without an integrity pin

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_security-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/fetch-ort-java.sh:7`, `scripts/fetch-ort-java.sh:20`, `scripts/fetch-ort-java.sh:28`, `scripts/fetch-ort-java.sh:34`
- Evidence: The default 1.22.0 AAR is SHA-256 pinned and fails closed. Passing any other version prints `no pinned hash ... verify` but continues to unzip and copy `classes.jar` plus native `.so` libraries into shipped Android source directories.
- Triage rationale: Attack preconditions are an operator intentionally selecting another version plus a compromised/substituted Maven artifact, repository/DNS/TLS failure, or simple failure to manually compare the printed digest. Concrete impact is attacker-controlled Java/native code being committed and shipped in the app. A warning is not an integrity boundary.
- Remediation: Maintain an explicit version-to-SHA-256 allowlist and abort before extraction for every unpinned version. If a bootstrap mode is unavoidable, require a separate explicit flag and write only to quarantine, never the vendored tree, until a reviewed pin is added. Stage all outputs and atomically replace destinations only after complete verification.
- Verification: Serve/prepare a modified AAR for a non-default version and assert the script exits before unzip/copy. Verify the pinned artifact succeeds, a one-byte modification fails, and no repo-side jar/so changes occur on any failure.

#### TOOL-01 — Predictable /tmp crash filenames reach a Python-code interpolation sink

- Severity/status: **P2 / confirmed**
- Sources: `REVIEW_security-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_gcp-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/pull-crashlog.sh:13`, `scripts/pull-crashlog.sh:48`, `scripts/pull-crashlog.sh:51`, `scripts/pull-crashlog.sh:64`, `scripts/pull-crashlog.sh:67`
- Evidence: The script uses fixed `/tmp/castcircle-crashes` and legacy `/tmp/crashlogs`, accepts matching `Runner-*.ips` paths from `find`, and interpolates the selected path into `python3 -c` as `open('$LATEST')`. A filename containing a single quote can close the Python literal and inject Python statements. The predictable directory can be pre-created or populated by another local user before the developer runs the tool; path parsing is also whitespace-unsafe.
- Adversarial disposition: The code-execution path is genuine: an unprivileged same-host user can pre-create/populate the fixed /tmp directory with a quote-bearing Runner-*.ips filename; find selects it and the filename is interpolated into Python source as open('$LATEST'), allowing Python statement injection when a developer later runs the tool. The impact is execution as the developer, including access to that account's source and developer credentials. P1 overstates a path that requires a separate local account on the same workstation plus a later manual invocation of an obscure diagnostic script; P2 preserves the serious code-execution consequence while accounting for those strong preconditions.
- Remediation: Use a per-run `mktemp -d` directory with mode 0700, reject unexpected ownership/symlinks, and stop reading the legacy shared directory. Pass the chosen filename as a separate `sys.argv` element to a quoted heredoc/script; use NUL-delimited file discovery/sorting. Never interpolate path or log contents into executable Python.
- Verification: In a controlled temp directory, create matching filenames containing quotes, newlines, spaces, `$`, and semicolons plus a sentinel injection payload. Run the parser with a mocked pull command and assert no sentinel executes, only files inside the private directory are considered, and valid `.ips` parsing still works.

#### CLOUD-02 — Audit tools default to production and create persistent real auth users

- Severity/status: **P3 / confirmed**
- Sources: `REVIEW_security-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_crypto-security-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `tool/analyze_orphaned_recordings.dart:19`, `tool/analyze_orphaned_recordings.dart:23`, `tool/analyze_orphaned_recordings.dart:130`, `tool/orphan_sweep.dart:17`, `tool/orphan_sweep.dart:20`, `tool/verify_cloud_recordings.dart:15`, `tool/verify_cloud_recordings.dart:18`, `supabase/migrations/20260703090000_leave_policy_and_audit_cleanup.sql:9`
- Evidence: Three runnable tools hardcode the production project and call `/auth/v1/signup` with a fresh `@example.com` address and fixed password. They never delete the auth user. Two accept no explicit production-safety acknowledgement, and the verification tool silently supplies a live production/code when arguments are omitted. A committed migration records the observed consequence: prior audit runs left junk understudy memberships on approximately 97 productions and required deleting the rows and `@example.com` auth users.
- Adversarial disposition: The tools do default to the production project and each invocation attempts to create a persistent real auth user, so the operator-safety defect is concrete. Current repository configuration and release verification require confirmed email signup and explicitly expect signup to return no access token. Because every tool generates a fresh address and immediately attempts password grant, the current documented path exits before membership insertion or customer-data reads. The present confirmed impact is production auth-user pollution plus SMTP/email-rate-limit consumption; the historical migration proves larger pollution occurred under older auth/policy state, but does not make those stronger effects currently reachable. P3 reflects the required operator invocation and narrowed present impact; membership/data access would need runtime proof of deployed auth drift.
- Remediation: Make tools staging-only by default and require explicit URL/key/production arguments plus a conspicuous production acknowledgement. Never sign up accounts from audit tools; use pre-provisioned least-privilege staging identities. Wrap every temporary data mutation in verified `try/finally` cleanup and make non-empty cleanup results mandatory. Remove the live defaults and fixed credentials.
- Verification: Run each CLI against a local mock/staging endpoint: with missing explicit target it must exit before any HTTP request; with staging credentials, force failures at every step and assert no membership/storage/production rows remain. Verify no `/signup` request is issued.


## Runtime/benchmark proof queue

### AndroidTriage

#### AND-25 — Detach closes ORT sessions concurrently with active runs and leaves stale posts

- Severity/status: **P1 / needs_runtime_proof**
- Sources: `REVIEW_android-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_kotlin-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:73`, `android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:139`, `android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:222`, `android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:499`
- Evidence: Workers capture session references in `ocrImage` and can be inside native `session.run` while `onDetachedFromEngine` immediately calls `close()` from the platform thread. Workers also continue posting progress/final Result callbacks through the old channel. Kotlin catches some thrown failures, but it cannot guarantee safety if native close/run concurrency is unsupported. The reviews did not reproduce a crash.
- Triage rationale: A native use-after-close/process crash would be P1, but ORT's exact concurrent close/run behavior and Flutter messenger behavior after teardown require runtime proof.
- Remediation: Serialize all model access on the lifecycle executor; on detach reject new work, cancel queued jobs, wait off-main-thread for the active job/load to finish, then close sessions. Gate every progress/final post by attachment generation and complete surviving cached-engine requests with a cancellation error.
- Verification: Instrumentation stress: repeatedly detach/destroy the engine during detection and recognition runs under native crash reporting; assert no SIGSEGV/IllegalStateException, no callbacks from an old generation, and all native handles eventually close.

#### AND-28 — Detection scratch allocation may add OCR GC pressure

- Severity/status: **P2 / needs_runtime_proof**
- Sources: `REVIEW_android-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_android-performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_kotlin-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_kotlin-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:342`, `android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:373`
- Evidence: Every detection allocates a BooleanArray of at most 960×960 (about 0.9 MB) and a 4096-int stack that doubles only when one connected component exceeds capacity. The reviews overstate the map as 1.2–3 million pixels and do not profile GC; the code's measured 420 ms includes inference and flood fill but no allocation attribution.
- Triage rationale: Repeated scratch allocation is plausible pressure, especially across PDF pages, but the claimed high severity/seconds of cost is not established. Reuse is also unsafe until concurrent OCR calls are serialized.
- Remediation: First serialize OCR per AND-23. If allocation profiling confirms impact, retain max-sized `visited` and stack scratch in that executor, clear only the used/map range per page, and grow the stack once to the observed maximum.
- Verification: Profile allocation counts, GC pause time, and detection latency on dense and normal pages before/after scratch reuse; assert identical boxes and no cross-request state contamination.

#### AND-10 — Two STT channel events per 100 ms may cause avoidable main-isolate churn

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_android-performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_kotlin-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `android/app/src/main/kotlin/com/tiltastech/lineguide/AndroidSttPlugin.kt:386`, `lib/data/services/stt_channel.dart:147`
- Evidence: Each 100 ms capture chunk posts one main-thread lambda that invokes `onLevel` and `onPcm` separately, producing 20 channel messages/second. Dart defines these as two separate callback contracts. The reviews provide no frame, queue-depth, or serialization profile showing backlog.
- Triage rationale: The traffic is real and coalescing could reduce dispatches, but 20 bounded messages/second is not by itself a demonstrated performance defect.
- Remediation: If profiling confirms impact, cut over both native and Dart contracts atomically to one `onPcm` map carrying `bytes` and `level`, updating `SttChannel._handleCallback` and every consumer.
- Verification: Profile Flutter frame times, Android main-looper queue delay, and platform-channel CPU during a long rehearsal before/after; also assert identical PCM bytes and level callback cadence.

#### AND-21 — Eager Paddle model loading may contend with cold startup

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_android-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `android/app/src/main/kotlin/com/tiltastech/lineguide/MainActivity.kt:14`, `android/app/src/main/kotlin/com/tiltastech/lineguide/PaddleOcrPlugin.kt:63`
- Evidence: Most plugin constructors/attachments are cheap, contrary to the broad review claim, but PaddleOcrPlugin immediately starts a worker that reads two large ONNX assets and constructs two sessions when registered. It is off-main-thread yet can contend for I/O, CPU, and memory before first frame. No startup trace was provided.
- Triage rationale: Only Paddle has a plausible startup cost, and impact needs a cold-start measurement.
- Remediation: If proven, install the channel immediately but start one shared model-load future lazily on the first OCR call; queued first calls await that future without spawning poller threads.
- Verification: Compare cold process start-to-first-frame, CPU, I/O, and peak RSS over repeated runs with eager versus lazy model load, then verify the first OCR call still waits once and falls back correctly on load failure.

### DataTriage

#### DAT-013 — The audit cleanup migration can delete legitimate @example.com accounts

- Severity/status: **P1 / needs_runtime_proof**
- Sources: `REVIEW_db-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_sql-migration-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `supabase/migrations/20260703090000_leave_policy_and_audit_cleanup.sql:16`
- Evidence: The schema migration deletes cast memberships and auth.users rows for every address matching '%@example.com'. The comment asserts no real user has such an address, but the repository cannot establish that fact, the pattern is not an exact test-account allowlist, and deleting auth.users is destructive.
- Triage rationale: Whether damage is possible or already occurred depends on hosted rows and migration history. The repository defect is embedding a broad data purge in automatic migration history without a row-count/identity guard.
- Remediation: Do not replay or remotely apply this cleanup based only on the repository. Read migration history first. If still pending, perform read-only exact-row inventory with ids, creation times, ownership, and dependent data; require an explicit allowlist, backup/export, expected row-count assertion, and operator approval. Future audit cleanup should be a separately reviewed one-off operation, not a schema migration.
- Verification: Read-only: confirm whether version 20260703090000 is recorded as applied and enumerate any matching accounts/dependencies. Compare each candidate to the known audit account allowlist. No deletion or remote migration application is part of this verification.

#### DAT-014 — The hard-coded production purge is safe only if hosted identity assertions are true

- Severity/status: **P1 / needs_runtime_proof**
- Sources: `REVIEW_db-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_sql-migration-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `supabase/migrations/20260703100000_purge_test_productions.sql:5`
- Evidence: A schema migration deletes 44 production UUIDs, cascading children through existing FKs. Comments label them owner-approved tests, but names/comments are not database guards and the repository cannot prove current ownership, contents, backups, or whether the migration already ran.
- Triage rationale: The SQL is intentionally destructive; classification depends on environment state rather than current code semantics.
- Remediation: Before any pending application, check migration history and perform read-only joins that show each production's organizer, title, timestamps, cast/line/recording counts, and active references. Require every id to match a signed-off allowlist and create a recoverable export. If already applied, inspect audit/backups rather than replaying it. Keep future purges out of the migration stream.
- Verification: Read-only catalog/data checks and backup manifest comparison only. Assert the keep set includes every non-approved production and every active consumer. Do not execute the DELETE or apply remote migrations during triage.

#### DAT-015 — Repository migration order is coherent, but hosted migration/policy state is unknown

- Severity/status: **P1 / needs_runtime_proof**
- Sources: `REVIEW_db-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_sql-migration-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `supabase/migrations/20260314061409_initial_schema.sql:1`, `supabase/migrations/20260703140000_security_lockdown.sql:1`, `supabase/migrations/20260703160000_drop_last_productions_readall.sql:10`, `supabase/migrations/20260813110000_join_flow_v3_and_policy_fixes.sql:1`
- Evidence: Filename order is logically consistent: base schema, recursion fixes, join-code/RPC additions, lockdown/hotfix/final global-policy drop, membership index, then v3. Later migrations repair many severe earlier policies. The repository alone does not show supabase_migrations.schema_migrations or the deployed pg_policies/routine ACLs. An environment stopped before 20260703160000 would retain global production reads; one stopped before the lockdown retains still broader exposure.
- Triage rationale: This is environment-state uncertainty, not evidence that the current ordered repository still has every historical vulnerability. The impact of missing later migrations is high enough to require a read-only deployment-state check.
- Remediation: Compare the hosted migration ledger to every repository version and export read-only pg_policies, bucket public flags, function definitions, and routine privileges. Produce a drift report and separately plan any required forward migration; do not apply remote migrations as part of this review.
- Verification: Read-only assertions should confirm all expected versions through 20260813110000, recordings bucket public=false, absence of global productions/cast/debug policies, expected final policies by name/predicate, and RPC/helper ACLs. Any mismatch remains an environment finding until explicitly remediated.

### IOSTriage

#### IOS-12 — Kokoro model lifecycle state is not isolated from async load/status/synthesis

- Severity/status: **P2 / needs_runtime_proof**
- Sources: `REVIEW_ios-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_swift-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/KokoroMLXPlugin.swift:26`, `ios/Runner/KokoroMLXPlugin.swift:91`, `ios/Runner/KokoroMLXPlugin.swift:96`, `ios/Runner/KokoroMLXService.swift:28`, `ios/Runner/KokoroMLXService.swift:100`, `ios/Runner/KokoroMLXService.swift:157`
- Evidence: `loadModel` runs in an unstructured Task and mutates `ttsEngine`/`voices`; synchronous channel cases read status or clear the same properties. `synthesize` reads them before entering `synthQueue`. There is no actor/lock around lifecycle state. The queued synthesis does retain local engine/embedding values, so the review's claim that unload necessarily deallocates them mid-inference is overstated, but concurrent Swift property/dictionary access remains unisolated.
- Triage rationale: Normal Dart flow mostly serializes model loading and the unload/delete APIs currently have no production caller, so a user-visible failure is not proven. Engine reinitialization, diagnostics status during load, or future unload use can expose a real data race.
- Remediation: Make KokoroMLXService an actor or isolate all engine/voice lifecycle reads and writes on one dedicated queue; take an immutable strong model snapshot there before queued synthesis and serialize load/unload/delete transitions.
- Verification: Add a stress harness issuing load/status/synthesize/unload/delete concurrently under Thread Sanitizer. Verify no race reports, every channel call resolves once, and a synthesis either uses one complete snapshot or returns a deterministic lifecycle error.

#### IOS-22 — PDFKit background/concurrent use needs runtime validation, not a main-thread rewrite

- Severity/status: **P2 / needs_runtime_proof**
- Sources: `REVIEW_swift-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/PdfTextPlugin.swift:62`, `ios/Runner/PdfTextPlugin.swift:105`, `ios/Runner/PdfTextPlugin.swift:146`
- Evidence: All three methods create separate PDFDocument instances on a global concurrent queue. The review asserts PDFKit background access can crash, but provides no repository/runtime evidence, and moving disk parsing/text extraction to the main actor would reintroduce documented UI jank. Concurrent calls can nevertheless execute PDFKit work simultaneously on different global threads.
- Triage rationale: The alleged thread restriction is not established from source alone. A dedicated serial PDF queue may be warranted if target-SDK/device stress shows instability, but main-thread confinement is not justified without proof.
- Remediation: First stress the exact supported PDFKit/OS matrix. If crashes/races reproduce, confine all plugin PDFKit access to a dedicated serial background queue, not the main actor.
- Verification: Concurrently run extractText, extractTextPerPage, and hasEmbeddedText over valid, encrypted, corrupt, and large PDFs on supported iOS versions under TSan and crash logging. Record whether failures disappear under a serial background queue.

#### IOS-23 — Implicit Flutter engine reinitialization may strand old plugin/session lifecycles

- Severity/status: **P2 / needs_runtime_proof**
- Sources: `REVIEW_ios-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/AppDelegate.swift:38`, `ios/Runner/AppDelegate.swift:48`, `ios/Runner/AppDelegate.swift:53`, `ios/Runner/AppDelegate.swift:58`
- Evidence: Every `didInitializeImplicitFlutterEngine` call replaces plugin ivars without explicit teardown. Most channel handlers will be replaced by name, but BackgroundDownloadPlugin owns a URLSession that retains its delegate and is never invalidated; AppleStt owns audio/observers. Whether Flutter invokes this delegate more than once in production scene/engine restoration is not established.
- Triage rationale: Hot restart alone is not a production defect, but a real implicit-engine reinitialization could leave duplicate background-session delegates or stale native callbacks. Runtime lifecycle proof is needed before changing registration ownership.
- Remediation: Instrument engine initialization count and add explicit plugin teardown/invalidation if multiple production initializations occur. Teardown must preserve an active background download by transferring ownership rather than blindly invalidating it.
- Verification: Exercise cold launch, scene destruction/restoration, memory-pressure engine recreation, and developer hot restart. Count live plugin/session instances and callback deliveries; verify one owner per channel/background session and no stale messenger invocations.

#### IOS-06 — STT level metering assumes channel 0 and needs route-specific proof

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_ios-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_swift-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/AppleSttPlugin.swift:619`, `ios/Runner/AppleSttPlugin.swift:622`
- Evidence: `rmsLevel` reads only `floatChannelData[0]` and returns zero for non-Float PCM. Dart uses `onLevel` for silence endpointing. Built-in iPhone microphones normally expose a mono Float tap, but the code does not establish that invariant for wired, Bluetooth, USB, or multichannel routes.
- Triage rationale: The source-level limitation is real, but a user-visible endpointing failure depends on formats actually delivered by supported iOS routes; that requires device evidence.
- Remediation: Either assert/document a mono Float tap after enumerating supported routes, or compute RMS over every available channel and handle Int16 PCM as well.
- Verification: Log tap common format/channel count and compare emitted RMS against AVAudioPCMBuffer reference RMS on built-in mic, wired headset, AirPods/Bluetooth, and a multichannel USB interface. Confirm silence and speech endpoint thresholds remain correct on each route.

#### IOS-19 — OCR tensor conversion repeatedly allocates and scalar-normalizes full images

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_ios-performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_swift-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/PaddleOcrPlugin.swift:388`, `ios/Runner/PaddleOcrPlugin.swift:397`, `ios/Runner/PaddleOcrPlugin.swift:414`
- Evidence: Every detection page and every recognized crop allocates an RGBA UInt8 buffer, a 3×W×H Float array, then `NSMutableData(bytes:)` copies the tensor again. RGB planar normalization is a nested scalar Swift pixel loop. A dense multi-page PDF invokes this for every detected line, potentially hundreds/thousands of times.
- Adversarial disposition: RGBA allocation, planar Float allocation, the NSMutableData copy, and scalar normalization are source-proven, but pages/crops are processed sequentially and no assigned review provides device allocation or wall-time evidence showing this conversion dominates import. Reusing storage or vectorizing is reasonable only after Instruments confirms material impact and numerical/OCR equivalence; classify it as runtime proof rather than a confirmed medium bug.
- Remediation: Reuse bounded RGBA and Float scratch buffers on the serialized OCR worker, vectorize conversion/normalization with Accelerate or vImage, and construct ORT tensor storage without an extra full copy where the wrapper supports owned mutable data.
- Verification: Benchmark representative 1-, 20-, and dense 100-page PDFs with Instruments Allocations/Time Profiler. Require identical tensor values/OCR output, lower allocation count/peak memory, and improved per-page wall time.

#### IOS-20 — OCR detector and CTC decoder use allocation-heavy scalar hot loops at page/crop scale

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_ios-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/PaddleOcrPlugin.swift:280`, `ios/Runner/PaddleOcrPlugin.swift:288`, `ios/Runner/PaddleOcrPlugin.swift:341`
- Evidence: Each page allocates a full `mW*mH` Int label array plus component arrays/stack and scalar flood-fills the probability map. Each crop performs a scalar `T*C` argmax over the entire recognition output. With detection capped near 960² and dozens of crops per page, these loops and fresh buffers dominate dense-document work.
- Adversarial disposition: The detector and CTC decoder necessarily scan their full outputs, and MLX/Swift optimizer behavior for the small neighbor literal and ORT-side argmax is not established. Scratch reuse may help, but a P2 claim that these loops dominate dense-document work requires profiling of the actual det/rec sessions and corpus. Any rewrite must preserve connected-component geometry, CTC blank/repeat semantics, line order, text, confidence, and normalized rectangles.
- Remediation: Reuse label/stack/component scratch storage across pages, flatten neighbor traversal without per-pixel tuple-array construction, and use an optimized/vectorized argmax or ORT-side argmax for CTC timesteps while preserving blank/repeat semantics.
- Verification: Profile dense scanned PDFs and compare page/crop CPU, allocations, boxes, decoded strings, confidence, and ordering byte-for-byte against a reference corpus.

#### IOS-21 — PDFKit page loops lack per-page autorelease pools

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_ios-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/PdfTextPlugin.swift:80`, `ios/Runner/PdfTextPlugin.swift:120`
- Evidence: Both background dispatch blocks iterate every PDF page and access ObjC PDFKit `page.string` without an inner autorelease pool. The dispatch worker's pool drains after the whole block, so autoreleased PDFKit/bridging temporaries can accumulate across hundreds of pages even though Swift locals leave scope.
- Adversarial disposition: GCD supplies an autorelease scope for the work item, so an inner per-page pool can reduce lifetime of PDFKit temporaries, but source alone does not prove that `PDFDocument.page(at:)`/`page.string` accumulate substantial autoreleased objects rather than releasing Swift/Objective-C references each iteration. Large-PDF VM/Allocations evidence is needed before calling this a confirmed jetsam path. If reproduced, retain only the copied Swift String outside each per-page autoreleasepool.
- Remediation: Wrap each page extraction in `autoreleasepool`, retaining only the final Swift String needed by the result. Preserve page indexing for the per-page API.
- Verification: Extract 10-, 100-, and 500-page text PDFs under Allocations/VM Tracker. Verify peak memory plateaus per page rather than growing with page count and returned full/per-page text remains identical.

### MLScriptsTriage

#### ML-02 — Restarted ONNX isolates can reuse temporary WAV names

- Severity/status: **P2 / needs_runtime_proof**
- Sources: `REVIEW_ml-inference-pipeline-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/kokoro_onnx_service.dart:337`, `lib/data/services/kokoro_onnx_service.dart:422`, `lib/data/services/kokoro_onnx_service.dart:471`
- Evidence: fileSeq is local to _isolateMain and begins at zero on every spawn. stop sends dispose but immediately kills with Isolate.beforeNextEvent; a native generation may still be returning while a replacement isolate starts. Both epochs can therefore target kokoro_onnx_0.wav.
- Triage rationale: The name collision is code-confirmed, but whether Dart's kill timing permits the old native call to reach the write concurrently needs a targeted lifecycle run.
- Remediation: Use a per-spawn cryptographically unique/UUID filename or createTemp, and atomically adopt it into the content-addressed cache. Do not derive uniqueness from an isolate-local counter.
- Verification: Hold generation in a controllable fake/native hook, stop and restart during generation, then release both epochs and assert paths and bytes never collide and cancelled output is not cached.

#### ML-08 — Tokenizer silently drops unknown phoneme characters

- Severity/status: **P2 / needs_runtime_proof**
- Sources: `REVIEW_ml-inference-pipeline-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/KokoroVendored/TextProcessing/Tokenizer.swift:17`, `ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:259`
- Evidence: Tokenizer maps vocab lookups to optionals, filters nils, and force-unwraps the remainder. prepareInputTensors receives no indication that characters disappeared. KokoroConfig.config itself is never nil in production (it returns the eagerly loaded shared config), so the separate missing-config claim is false.
- Triage rationale: Silent shortening would corrupt spoken output, but it must be demonstrated that a production G2P can emit a character outside the bundled vocabulary; ordinary input punctuation is processed before this seam.
- Remediation: Make tokenization throwing and report the first unsupported scalar and its position, or map a deliberately documented unknown token. Do not silently filter.
- Verification: Enumerate output characters produced by both shipped G2P languages over the rehearsal corpus and fuzz Unicode input; assert all are tokenized or fail with the exact unsupported scalar, never shorten silently.

#### ML-13 — Live ASR kills the isolate before confirming native disposal

- Severity/status: **P2 / needs_runtime_proof**
- Sources: `REVIEW_ml-inference-pipeline-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/live_asr_service.dart:139`, `lib/data/services/live_asr_service.dart:146`, `lib/data/services/live_asr_service.dart:231`
- Evidence: stop sends dispose, cancels the receive subscription, and immediately calls kill(priority: beforeNextEvent). There is no dispose acknowledgement, despite the comment saying it gives the isolate a moment. The isolate frees stream and recognizer only when it processes the dispose map.
- Triage rationale: Native cleanup may still occur during isolate teardown, so leak/crash impact requires measurement, but the intended graceful path is not guaranteed.
- Remediation: Have the isolate acknowledge after freeing stream/recognizer, await that acknowledgement with a short timeout, then hard-kill only on timeout. Keep the epoch guard for stale starts.
- Verification: Loop start/stop during load and active decode while tracking native memory and open handles; assert every normal stop acknowledges and memory returns to baseline, and the timeout hard-kill path remains bounded.

#### SHELL-03 — AAR extraction has no explicit path-containment validation

- Severity/status: **P2 / needs_runtime_proof**
- Sources: `REVIEW_shell-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/fetch-ort-java.sh:33`
- Evidence: The script runs unzip directly in the temp directory and performs no entry-name validation. Modern unzip implementations often reject or sanitize ../ entries, so exploitability depends on the exact macOS/Linux extractor version; the review assumes traversal behavior without proving it.
- Adversarial disposition: Extractor traversal remains unproved and is largely subsumed once SHELL-02 rejects unknown hashes. The proposed normalize-then-unzip shell loop is itself fragile for symlinks/newlines and host differences. Because only classes.jar and four exact JNI members are needed, stream those exact members with unzip -p into explicit staged files, check status/nonempty content, then publish; never extract arbitrary archive paths. This is Bash 3.2-safe and needs no unquoted glob.
- Remediation: List archive entries first, reject absolute paths and any normalized path escaping a dedicated extraction directory, then extract there and copy only expected exact entries.
- Verification: Use AAR fixtures with ../, absolute, symlink, duplicate, and expected entries under both supported hosts; assert rejection before any outside write.

#### MEDIA-04 — Raw PCM pointer assumptions need an alignment/length proof

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_media-provenance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/test_silence_trim.swift:40`, `scripts/test_silence_trim.swift:46`
- Evidence: The script ignores CMBlockBufferGetDataPointer's status, truncates odd lengths with length / 2, and rebinds Int8 storage to Int16 without documenting alignment. CoreMedia commonly supplies suitable PCM buffers, but that guarantee was not established by the review.
- Triage rationale: Potential garbage reads are plausible but need a fixture/API-contract proof; do not add speculative copying to a sample loop without evidence.
- Remediation: Check the CoreMedia status and even byte count; use copyBytes into aligned Int16 storage if alignment is not guaranteed by the returned buffer contract.
- Verification: Inspect/test contiguous and non-contiguous sample buffers with Address/Undefined Behavior sanitizers and odd-length synthetic block buffers; assert safe rejection or correct samples.

#### ML-03 — ONNX WAV conversion does not handle non-finite samples

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_ml-inference-pipeline-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/kokoro_onnx_service.dart:482`, `lib/data/services/kokoro_onnx_service.dart:502`, `lib/data/services/kokoro_onnx_service.dart:474`
- Evidence: _writeWav calls (samples[i] * 32767).round() before integer clamping. NaN and infinity cannot be rounded to an int. The surrounding isolate try/catch reports a synthesis error, so the review's claim that the isolate necessarily crashes or leaves a truncated file is overstated, but the request still fails for one non-finite sample.
- Adversarial disposition: round() does throw for NaN/infinity, but the only producer is the shipped sherpa native model and no reviewed input or run demonstrates non-finite samples. If established, reject/sanitize in _writeWav and let the existing isolate error-map/Future<String?> null path carry failure; introducing a new public typed result would unnecessarily change the ML output contract.
- Remediation: Reject non-finite sample arrays with a typed engine error, or deliberately replace non-finite samples with zero while counting/logging them; keep finite amplitude clamping.
- Verification: Call the WAV encoder with NaN, positive/negative infinity, and finite out-of-range samples; assert the documented behavior, a valid header, and no partial destination on rejection.

#### ML-05 — ONNX cache adoption performs synchronous UI-isolate I/O

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_mlx-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/kokoro_onnx_service.dart:247`
- Evidence: After awaiting synthesis, the Dart/UI isolate calls File(path).renameSync(cachePath). The review's adjacent claim that exists and setLastModified are synchronous is false: those operations use awaited/asynchronous APIs. The rename itself is genuinely synchronous on every uncached success.
- Adversarial disposition: renameSync is indeed executed on the Dart/UI isolate after an uncached synthesis, but a same-filesystem rename is one metadata operation and no measured jank or correctness failure is shown. Keep only as a benchmark-backed optimization; await File(path).rename(cachePath) preserves Future<String?> and the cache-path contract.
- Remediation: Use await File(path).rename(cachePath), or perform cache adoption in the synthesis isolate before returning the stable path.
- Verification: Profile uncached line synthesis with Timeline file-I/O events on representative low-end Android storage; verify no synchronous file operation remains on the UI isolate and returned files are immediately readable.

#### ML-09 — Timestamp predictor contains unverified index/offset arithmetic

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_ml-inference-pipeline-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/KokoroVendored/TTSEngine/TimestampPredictor.swift:33`, `ios/Runner/KokoroVendored/TTSEngine/TimestampPredictor.swift:44`, `ios/Runner/KokoroVendored/TTSEngine/TimestampPredictor.swift:61`, `ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:230`
- Evidence: left is initialized to zero and immediately overwritten with right; a nil-phoneme whitespace token increments i, reads dur[i], then increments again; phoneme slices depend on the resulting i. The predictor runs for every synthesis with tokens even though KokoroMLXService discards returned tokens. Wrong timestamps alone therefore have no current user-visible effect, but an out-of-range path could fail synthesis.
- Adversarial disposition: The cited out-of-range concern is not exhibited: each loop iteration guards i < dur.count - 1, the nil-phoneme branch's one read after i += 1 is therefore at most dur[count-1], and the phoneme branch guards j < dur.count. Returned token timestamps are discarded by KokoroMLXService. Reference parity may justify deleting this dead work, but it is not a current output-correctness finding.
- Remediation: Port the timestamp routine directly from the pinned upstream/reference implementation with explicit cursor invariants and bounds; if timestamps are unused, remove prediction from the production audio path instead of retaining risky dead work.
- Verification: Use reference durations/tokens covering leading/trailing whitespace and nil phonemes; compare every timestamp and assert cursor bounds. Also synthesize those cases through KokoroMLXService.

#### ML-10 — SourceModule generates an output-sized random tensor that callers discard

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_mlx-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/KokoroVendored/Decoder/SourceModuleHnNSF.swift:47`, `ios/Runner/KokoroVendored/Decoder/SourceModuleHnNSF.swift:50`, `ios/Runner/KokoroVendored/Decoder/Generator.swift:151`
- Evidence: SourceModuleHnNSF allocates MLXRandom.normal(uv.shape) and returns it with uv. Generator destructures only harSource and discards the other two values. The source comment itself states noise and uv are not needed.
- Adversarial disposition: The unused noise expression is removable weight, but MLX is lazy: MLXRandom.normal(uv.shape) creates a graph value that is discarded and is not shown to materialize an output-sized GPU tensor or execute an RNG kernel. Delete the unused tuple members and migrate the sole Generator caller only after fixed-seed waveform parity, but do not claim GPU allocation savings without an MLX trace.
- Remediation: Change SourceModuleHnNSF to return only sineMerge and remove the second random generation. Migrate its sole caller and retain any randomness inside SineGen that actually shapes sineMerge.
- Verification: Run fixed-seed cold/warm MLX harness samples before and after; assert sample parity and compare GPU allocations/kernel time for representative 5 s and 20 s utterances.

#### ML-11 — Dense CPU-built duration alignment is a likely MLX hotspot

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_mlx-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:359`, `ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:369`, `ios/Runner/KokoroVendored/TTSEngine/KokoroTTS.swift:378`
- Evidence: createAlignmentTarget synchronizes durations to a Swift [Int32], allocates tokenCount × totalFrames Float values, fills a dense one-hot matrix in nested loops, and uploads it to MLX. The parameter named batchSize is actually passed paddedInputIds.shape[1], i.e. token count, so the review's dimensions are substantively right despite misleading naming.
- Triage rationale: Clear avoidable allocation/copy, but severity and best replacement require profiling; classify as benchmark opportunity, not correctness.
- Remediation: Prototype an on-device cumulative-duration comparison/scatter implementation and rename dimensions to tokenCount/totalFrames. Keep the reference CPU implementation for parity tests only.
- Verification: Compare matrices and final samples across varied duration vectors; benchmark host allocation, GPU upload, and end-to-end RTF at 50, 300, and 510 tokens and minimum supported speed.

#### ML-12 — iSTFT overlap-add materializes many full-length intermediates

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_mlx-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/KokoroVendored/Decoder/MLXSTFT.swift:142`, `ios/Runner/KokoroVendored/Decoder/MLXSTFT.swift:149`, `ios/Runner/KokoroVendored/Decoder/MLXSTFT.swift:167`
- Evidence: mlxIstft repeats wSquared to full output length, constructs output and window-sum arrays for every overlap phase with zero-padding, then reduces them in second loops. With shipped winLen/hopLen this holds multiple output-length MLXArrays per synthesis.
- Triage rationale: The allocation pattern is confirmed, but no profile proves it dominates current RTF. It is a benchmark opportunity, not an output-correctness issue.
- Remediation: Implement parity-tested strided overlap-add/broadcast accumulation with one reconstructed buffer and one normalization buffer; avoid retaining per-phase full-length arrays.
- Verification: Compare waveform samples/tolerance against the current implementation and benchmark peak unified memory, allocations, GPU time, and end-to-end RTF for several clip lengths.

#### ML-14 — Lexicon resource failures silently degrade G2P

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_ml-inference-pipeline-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/MisakiVendored/English/Lexicon/DataResourcesUtil.swift:9`, `ios/Runner/MisakiVendored/English/Lexicon/DataResourcesUtil.swift:28`, `ios/Runner/MisakiVendored/English/EnglishG2P.swift:39`
- Evidence: loadGold returns an empty dictionary without logging on missing/read/decode failure. loadSilver logs only via NSLog and also returns empty. EnglishG2P then constructs the optional BART fallback, so bundle corruption becomes slower/lower-confidence inference rather than an observable model-load failure.
- Adversarial disposition: Only loadGold fails silently; loadSilver emits NSLog, and EnglishG2P deliberately owns an optional BART fallback and unknown-token behavior. Missing gold therefore does not by itself prove degraded spoken output. Keep a production corpus parity/quality check and expose fallback-only mode if quality changes, rather than treating the supported fallback as a confirmed correctness failure.
- Remediation: Make resource loaders throwing with distinct missing/read/decode errors. Decide at EnglishG2P initialization whether fallback-only mode is supported; if so, expose and persist a degraded-mode diagnostic.
- Verification: Build fixtures with each resource absent, unreadable, malformed, and valid; assert initialization either fails explicitly or enters a visible documented degraded mode, never silently returns an empty dictionary.

#### PY-09 — Folger extraction repeats full-page parsing passes

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_python-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `scripts/pdf_to_script.py:109`, `scripts/pdf_to_script.py:127`, `scripts/pdf_to_script.py:155`, `scripts/pdf_to_script.py:178`
- Evidence: _is_folger_pdf extracts plain text for up to 15 pages; _detect_characters_from_pdf then extracts dict blocks for every page; _extract_folger again extracts dict blocks for every page and additionally plain text on candidate start pages.
- Triage rationale: Redundant extraction is confirmed, but wall-time/peak-memory impact on the supported PDFs was not measured. Treat as benchmark opportunity rather than correctness.
- Remediation: Build one cached per-page structural pass that supplies signature detection, character discovery, start-page detection, and extraction; avoid retaining more page data than needed.
- Verification: Benchmark current and single-pass implementations on representative short and full-play PDFs; assert byte-for-byte equivalent conversion and report time/peak RSS.

### NativeTriage

#### SIMD-001 — Scalar microphone RMS runs inside the AVAudioEngine tap callback

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_simd-accelerate-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/AppleSttPlugin.swift:294`, `ios/Runner/AppleSttPlugin.swift:310`, `ios/Runner/AppleSttPlugin.swift:619`
- Evidence: The production tap invokes rmsLevel for every buffer. rmsLevel iterates all frames in channel zero in Swift, accumulating sample*sample before sqrt. The tap uses 4096-frame buffers and the file already imports Accelerate. The code proves render-callback work, but not the review's assertion that the compiler cannot vectorize it or that its approximately 49,000 samples/second cost causes a measurable glitch.
- Triage rationale: This is a plausible real-time-thread optimization, but the claimed user-visible severity is unsupported without callback-duration and deadline data. It should not be called P2 on source inspection alone.
- Remediation: If profiling shows meaningful callback cost, replace the loop with vDSP_rmsqv directly over channelData[0], preserving the current channel-zero and empty-buffer semantics.
- Verification: Use Instruments/System Trace on a physical supported iPhone while recording: compare tap callback duration, missed render deadlines, and reported RMS values before/after for silence, sine-wave, and clipped buffers.

#### SIMD-003 — Speech-range analysis allocates a scratch Float array for every CMSampleBuffer

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_simd-accelerate-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/AppleSttPlugin.swift:438`, `ios/Runner/AppleSttPlugin.swift:536`, `ios/Runner/AppleSttPlugin.swift:548`, `ios/Runner/AppleSttPlugin.swift:549`, `ios/Runner/AppleSttPlugin.swift:564`
- Evidence: stopRecording dispatches analysis to a global userInitiated queue. detectSpeechRange streams AVAssetReader sample buffers, allocates `[Float](repeating:count:)` once per buffer, converts Int16 with vDSP_vflt16, and computes each 50 ms RMS window with vDSP_rmsqv. It retains only one Float per 50 ms in windowRMS plus a bounded carry, so the review overstates it as sample-by-sample scalar analysis and does not establish severe memory growth; the per-buffer scratch allocation is real.
- Triage rationale: Hoisting/reusing scratch storage may reduce allocator traffic, but analysis is already off-main, streaming, and vectorized. Impact depends on AVAssetReader buffer sizes/counts and recording durations in practice.
- Remediation: Reserve windowRMS from total duration, reuse a grow-only Float scratch buffer across sample buffers, and retain the existing fixed-size carry/vDSP window processing. Do not replace this with a whole-file buffer.
- Verification: Profile allocations and elapsed analysis time for representative 30-second, 5-minute, and maximum-supported takes; validate returned CMTimeRange against fixtures with speech crossing sample-buffer boundaries.

#### SIMD-008 — Loudness analysis uses nested scalar sample loops instead of vector reductions

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_simd-accelerate-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/AudioAnalysisPlugin.swift:63`, `ios/Runner/AudioAnalysisPlugin.swift:69`, `ios/Runner/AudioAnalysisPlugin.swift:77`
- Evidence: For every channel and frame, Swift loads a Float, converts it to Double for sumSquares, computes abs, and branches for peak. The work is on a global userInitiated queue rather than the main thread, so the review's claimed UI blocking is indirect and no latency measurement is supplied.
- Triage rationale: Vector reductions are plausible and naturally pair with the required chunking fix, but whether scalar compute causes seconds of latency for supported recording lengths needs measurement.
- Remediation: Within the chunked implementation from SIMD-007, use vDSP reductions per channel for sum-of-squares/RMS and maximum magnitude, accumulate totals across chunks in Double, and preserve the current all-channel aggregation semantics.
- Verification: Benchmark scalar and vDSP implementations on physical target devices over short and long mono/stereo files; verify dBFS output within tolerance and measure wall time/CPU utilization.

#### SIMD-023 — AdainResBlk1d contains redundant adjacent axis swaps, but materialization cost is unproven

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_simd-accelerate-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/KokoroVendored/BuildingBlocks/AdainResBlk1d.swift:96`, `ios/Runner/KokoroVendored/BuildingBlocks/AdainResBlk1d.swift:100`, `ios/Runner/KokoroVendored/BuildingBlocks/AdainResBlk1d.swift:122`, `ios/Runner/KokoroVendored/BuildingBlocks/AdainResBlk1d.swift:124`
- Evidence: In shortcut, data is swapped to convolution layout, upsampled, swapped back, then immediately swapped again when conv1x1 exists. In residual, the post-upsample swap at line 122 is immediately undone at line 124 before conv1. Those adjacent inverse graph operations can be removed by retaining convolution layout. However, the review's broader assertion that 8+ swaps each materialize full copies is unsupported because MLX is lazy and some swaps are necessary between channel-major normalization and MLX convolution layout.
- Triage rationale: There is a narrow source-proven redundancy, but whether MLX graph simplification already eliminates it or it affects runtime needs profiling.
- Remediation: Keep tensors in convolution layout across upsample/pool and the following convolution, remove only adjacent inverse swaps, and preserve channel-major layout at normalization/output boundaries. Do not blindly delete required layout conversions.
- Verification: Compare block outputs before/after on fixed tensors within tolerance, inspect the MLX graph/kernel trace for eliminated transpose nodes, and benchmark production block shapes.

#### SIMD-024 — ConvWeighted recreates a transposed-weight graph node in both forward overloads

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_simd-accelerate-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `ios/Runner/KokoroVendored/BuildingBlocks/ConvWeighted.swift:18`, `ios/Runner/KokoroVendored/BuildingBlocks/ConvWeighted.swift:122`, `ios/Runner/KokoroVendored/BuildingBlocks/ConvWeighted.swift:146`, `ios/Runner/KokoroVendored/BuildingBlocks/ConvWeighted.swift:175`, `ios/Runner/KokoroVendored/TTSEngine/WeightLoader.swift:61`
- Evidence: normalizedWeight is cached, but whenever the runtime x/weight shape branch selects the alternate layout, each call invokes weight.transposed() anew. Both conv1d and convTransposed1d overloads have the same behavior. WeightLoader conditionally changes checkpoint weight_v layouts, so source inspection alone cannot prove how often the branch is taken for the downloaded production checkpoint; nor does lazy transposed() alone prove an eager full-kernel copy.
- Triage rationale: Caching the alternate graph/value is plausible for frozen inference weights, but the review overstates branch reach and copy cost. Runtime shape logging/graph profiling is required.
- Remediation: If the branch is observed and costly, add one shared cached transposedNormalizedWeight helper used by both overloads. Make frozen-weight immutability/invalidation explicit so both normalized caches cannot become stale.
- Verification: With the production Kokoro checkpoint, record each ConvWeighted input/weight shape and branch, inspect MLX kernel traces/evaluations, benchmark repeated synthesis, and confirm output samples are unchanged after caching.

### PerformanceTriage

#### PERF-11 — Two O(M×N) transcript alignment passes run on every STT partial

- Severity/status: **P2 / needs_runtime_proof**
- Sources: `REVIEW_performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_dart-performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_flutter-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/features/rehearsal/rehearsal_screen.dart:2343`, `lib/data/services/stt_service.dart:319`, `lib/data/services/stt_vocabulary_service.dart:366`
- Evidence: Every cumulative recognition result in _handleRecognizedForLine first calls SttVocabularyService.correct; _correctAgainstExpected allocates/fills an Int32List of (recognizedWords+1)×(expectedWords+1) and performs bounded edit-distance checks per cell. It then calls SttService.matchScore, another O(M×N) LCS using two rows. Partials arrive several times per second. Current code already normalizes words once, uses flat/two-row storage, caches vocabulary corrections, and scopes UI updates to ValueNotifiers, so the reviews' jank assertions are not proven for normal theatrical line lengths.
- Triage rationale: The frequency and asymptotic cost are reachable, but typical M/N are small and the implementation contains deliberate optimizations. This should not be changed without p95 profiling on long real lines and low-end hardware.
- Remediation: Profile first. If over frame budget, cache normalized expected tokens per current line, avoid doing two independent alignments by returning alignment/score from one bounded routine, reuse typed scratch buffers, and cap/fallback for pathological paragraph-length lines. Avoid isolate-per-partial overhead unless measured superior.
- Verification: Replay 5/20/50/100-word lines at 5–15 cumulative partials/sec on target devices; record correction+score p50/p95, allocations, and dropped frames. Preserve exact correction and match-score outputs across a corpus before accepting an optimization.

#### PERF-04 — Recording-cache hydration and reads synchronously stat every cached file on the UI isolate

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_dart-performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_flutter-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/recording_sync_service.dart:148`, `lib/data/services/recording_sync_service.dart:553`, `lib/providers/production_providers.dart:464`
- Evidence: _doHydrate parses the manifest and calls File.existsSync for every restored entry. getCachedRecordings scans the global cache, filters by production, and existsSync-stats each matching path before constructing its map. launchRecordingSync invokes getCachedRecordings after hydration and again after a sync that downloaded anything. For N cached entries, startup/sync performs O(N) synchronous filesystem syscalls on the calling isolate; the existence validation is required by the documented deleted-file contract, but its placement is not.
- Adversarial disposition: O(N) existsSync loops on the caller isolate are proven, but hydration/sync frequency is bounded and no profile establishes a realistic frame stall. Measure representative low-end devices before replacing the simple validated-map contract.
- Remediation: Make cache validation asynchronous and bounded-concurrent during hydrate/refresh, index cached entries by production, prune invalid entries once, and let map materialization use the validated index without re-statting it immediately. Preserve an explicit async refresh path for mid-session OS/file deletions.
- Verification: Hydrate manifests with 0/100/1,000 valid and missing files, verify missing entries are excluded and re-download behavior remains intact, and capture Flutter frame timings while switching productions. Assert getCachedRecordings map construction no longer performs synchronous file I/O.

#### PERF-07 — Cast-manager cloud refresh performs N database writes and O(N²) state copying/rebuilds

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_dart-performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_flutter-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/features/cast_manager/cast_manager_screen.dart:103`, `lib/features/cast_manager/cast_manager_screen.dart:139`, `lib/providers/production_providers.dart:216`, `lib/providers/production_providers.dart:230`
- Evidence: Opening CastManager calls _syncCastFromCloud. It awaits notifier.save for each cloud row, then awaits notifier.remove for each stale duplicate. Each save performs a Drift write, indexWhere over current state, allocates a new whole state list, and emits provider state; remove writes and filters/copies the state. Thus an N-member refresh is N serial DB operations and O(N²) aggregate state scans/copies/rebuild notifications.
- Adversarial disposition: N serial Drift writes and aggregate O(N²) state scans/copies are real, but casts are naturally small and no timing or rebuild-count evidence establishes material impact. Measure 10/50/100-member refreshes before adding batch complexity.
- Remediation: Add repository/notifier batch merge APIs: one Drift transaction/batch upserts all cloud members and removes stale ids, then one deterministic state assignment. Preserve organizers and existing cloud-id/character-role dedupe rules.
- Verification: With fake repositories and 10/100/500 cloud members, assert one transaction and one state emission, identical final membership/order, organizer retention, and stale duplicate removal. Compare operation counts and refresh latency scaling.

#### PERF-10 — Demo reopen reloads and reparses the fixed 595-line asset every time

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_dart-performance-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_flutter-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/demo_production_service.dart:74`, `lib/data/services/demo_production_service.dart:118`, `assets/demo/hamlet_demo.txt:1`
- Evidence: DemoProductionService.load unconditionally awaits _parseBundledScript even when the demo Production already exists. _parseBundledScript calls rootBundle.loadString and the synchronous ScriptImportService.importFromText on every reopen; the bundled asset is fixed and 595 lines. It also republishes/persists the parsed script each open. The work is O(fixed asset bytes/lines) per reopen, not unbounded, and no current latency measurement proves it is user-visible.
- Triage rationale: The repeated work is real, but the asset is bounded and user-triggered; claims of a visible hitch require runtime evidence under the non-goal against speculative micro-optimization.
- Remediation: First measure cold/warm demo-open latency. If material, cache a Future/immutable ParsedScript for the bundled parse for the process lifetime (or ship a pre-parsed asset), while retaining per-open provider assignment and any intentionally required persistence.
- Verification: Instrument parse count and navigation-to-first-frame time for ten opens on low-end Android/iOS. Require a material p95 improvement before changing behavior; verify repeated opens still reset/select/persist exactly as intended.

#### PERF-12 — Kokoro cache adoption uses synchronous rename on the UI isolate

- Severity/status: **P3 / needs_runtime_proof**
- Sources: `REVIEW_flutter-performance-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `lib/data/services/kokoro_onnx_service.dart:247`
- Evidence: After awaiting worker-isolate synthesis, synthesize calls File(path).renameSync(cachePath) before completing the user-facing Future. This occurs once per uncached synthesized chunk/line on Android and is a synchronous filesystem syscall on the UI isolate. The source and cache are both under temporary storage on the same filesystem, so the operation is normally O(1) metadata work; the review's millisecond/jank estimate is unsupported.
- Triage rationale: The synchronous I/O placement is undesirable on a playback-critical path, but its actual same-volume cost may be below measurement noise, so it does not justify a load-bearing change without proof.
- Remediation: Measure first; if material, replace renameSync with awaited File.rename and retain the current fallback of returning the original path when adoption fails. Do not add an in-memory cache index unless separate measurements justify it.
- Verification: Measure p95 adoption latency and Flutter frame timing across hundreds of cache misses on slow target storage; test rename success/failure and confirm returned paths remain playable and cache hits still work.

### SecurityCloudTriage

#### AUTH-03 — Two auth emails per hour may make public authentication trivially exhaustible

- Severity/status: **P2 / needs_runtime_proof**
- Sources: `REVIEW_gcp-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `supabase/config.toml:182`, `supabase/config.toml:207`, `supabase/config.toml:211`, `supabase/config.toml:233`
- Evidence: The committed config combines required signup confirmation, double-confirmed email changes, password-reset/resend flows, custom SMTP, and `auth.rate_limit.email_sent = 2` per hour. If this limit is project-global/effective on the hosted service, two attacker-triggered messages can consume the allowance and block confirmations and recovery for everyone.
- Triage rationale: Attack preconditions are access to the public signup/resend endpoints and a hosted limit with project-wide semantics. Concrete impact would be low-cost account-onboarding/password-recovery denial of service. Runtime proof is required because Supabase's hosted interpretation and the currently deployed value cannot be established from the repository without querying cloud state; no cloud call was made.
- Remediation: Confirm the hosted limit scope, raise it to a capacity-supported value for custom SMTP, and control abuse with per-address/IP cooldown, CAPTCHA, and provider-side limits rather than a two-message global ceiling.
- Verification: Read the deployed auth rate-limit settings and provider metrics without changing them. In staging, consume the configured threshold with distinct addresses and verify whether an unrelated user's confirmation/reset is blocked; tune only after measuring legitimate peak traffic.

#### SEC-03 — Live production join codes are committed in runnable tools/tests

- Severity/status: **P2 / needs_runtime_proof**
- Sources: `REVIEW_security-review_ds4-glm-5.3-flash-q2_20260829.md`, `REVIEW_crypto-security-review_ds4-glm-5.3-flash-q2_20260829.md`
- Code: `tool/verify_cloud_recordings.dart:19`, `test/supabase_join_test.dart:52`
- Evidence: `verify_cloud_recordings.dart` defaults to production UUID `ca0cde7d-5eef-4231-a584-03f935e3879b` and join code `D5E6SK`. The explicitly live Supabase join test hardcodes `DHT6XT`, expects it to resolve to Macbeth, and prints the returned row. Join codes are standing bearer-like credentials: v3 lookup/join RPCs accept possession of the code as authorization.
- Adversarial disposition: The runtime condition is correctly retained: repository inspection cannot prove that D5E6SK or DHT6XT is still active. If active, a repository reader must still create and confirm their own account, then can use the exposed code as the intended bearer credential to join one of the specifically identified productions and read its shared script, roster, and recordings. That is a concrete single/few-production confidentiality breach, but not the systemic cross-tenant reach of SEC-01; P2 is more proportionate than P1. The test's explicit LIVE/production comments support checking, but committed identifiers alone do not prove present exploitability.
- Remediation: Remove all live production UUIDs/join codes from source and fixtures; require explicit environment arguments targeting a staging project. Rotate both exposed production codes through the normal administrative path and audit membership/history for unexpected joins. Use synthetic local fixtures for ordinary tests.
- Verification: Without querying from this review session, have the project owner inspect the production records/audit logs in the dashboard, confirm whether each code is active, rotate any active code, and verify old-code lookup/join fails while newly shared invitations work.


## Closed claims

These items remain traceable but require no independent fix.

| ID | Final disposition | Claim | Reason / canonical owner |
|---|---|---|---|
| `AF-01` | already_fixed | Server join/claim RPCs already revalidate code and unclaimed state | The RPCs themselves fix arbitrary client-state role/member selection. The distinct remaining vulnerability is that direct table policies and client fallbacks bypass those RPC checks (SEC-01). |
| `AF-02` | already_fixed | Invite URI construction already percent-encodes values | The cited bulk-invite caller delegates to this safe builder; there is no manual string concatenation at that boundary. |
| `AF-03` | already_fixed | Recordings database-row deletion policy exists; only blob GC remains | Claims that every cloud metadata delete is RLS-blocked are already fixed. Storage objects still remain and are reported separately as CLOUD-03. |
| `DAT-018` | already_fixed | Historical public storage/table and broad RLS exposures are repaired by later repository migrations | The reviews repeatedly reported the vulnerable initial definitions as if they were final state. They remain important migration-history evidence, but at commit 7974003 their repository-level final state is superseded. DAT-015 separately covers whether those repairs reached a hosted environment. |
| `DAT-019` | already_fixed | Early circular RLS policies and helper hardening gaps are superseded | The review's recursion/search_path claims are stale against ordered final state. Its claim that STABLE caches one auth.uid across pooled requests is also false here: the helpers receive p_user_id as an explicit argument and do not read auth.uid internally; STABLE is statement-scoped, not cross-request result caching. |
| `DAT-020` | already_fixed | The main index/delete omissions identified in early migrations were later repaired | Those review claims are valid against earlier snapshots but not final repository state. The user_id-only index, duplicate script_scenes index, and storage-object deletion are distinct residual findings DAT-007/DAT-012/DAT-006. |
| `IOS-R01` | already_fixed | STT tap and recognition closures do not exhibit the alleged strong-capture leak | The reviews misread weak capture/rebinding. Session-state races are real and reported separately as IOS-01, but there is no retain-cycle/stale-channel finding from these closures. |
| `IOS-R04` | already_fixed | Background URLSession completion is already wired to AppDelegate | The required iOS background-session handshake exists end to end. Engine-reinitialization ownership uncertainty is separately captured as IOS-23. |
| `ML-15` | already_fixed | Repeated model documents-directory resolution claims are stale | The review repeatedly counts one platform round trip per model and bases four performance findings on that false premise. Synchronous fileProblem stats remain, but six bounded model entries do not establish a defect. |
| `PERF-R2` | already_fixed | Major ModelDownloadService repeated-path/hash/serialization claims are stale or misread current code | These were among the most repeated medium claims, but the cited expensive behavior is absent or already bounded in current code. |
| `PERF-R3` | already_fixed | OCR review's alleged per-card O(N log N) sort is already memoized | The code comments explicitly describe and implement the prior O(N² log N) fix. Treating invalidation assignments as repeated recomputation misreads lazy getters. |
| `PERF-R4` | already_fixed | Rehearsal list rebuild-storm findings describe code that has already been narrowed to row-level selects | The high-severity reviews infer rebuild behavior from widget count/cacheExtent without following Riverpod select and ValueNotifier dependencies. The asserted per-advance O(all cached rows) cost is not current behavior. |
| `STALE-01` | already_fixed | Signup-without-session navigation claim is stale | The reviewed claim that any signup result unconditionally enters the app does not match commit 7974003. The sign-in branch relies on Supabase throwing on invalid credentials, which is the client API contract. |
| `STALE-02` | already_fixed | Demo production is parsed before its row is added | A parse failure cannot leave the claimed half-created production row. Later persistence failures are retryable because reopening reparses and re-persists the same fixed demo id. |
| `ADV-01` | duplicate | Serialize every audioFile state access without blocking the tap | IOS-01 |
| `CLOUD-01` | duplicate | Cloud script replacement is non-atomic and clients can persist a partial result | DAT-001 |
| `CLOUD-03` | duplicate | Deleted and superseded recording blobs remain readable to production members | DAT-006 |
| `FLUTTER-16` | duplicate | Production hub logs production title, script size, and selected character on every build | FLUTTER-15 |
| `IOS-03` | duplicate | A CAF metadata read failure is treated as an empty capture and deletes it | IOS-02 |
| `IOS-05` | duplicate | Silence trimming performs a full-file allocation-heavy scan before every export | SIMD-003 |
| `IOS-11` | duplicate | Contact picker permits overlapping calls to overwrite the sole pending result | SIMD-014 |
| `IOS-14` | duplicate | Kokoro's 200 MB cache cap is checked only once and failed deletes are counted as success | IOS-13 |
| `IOS-R06` | duplicate | AudioAnalysis whole-file and silent-sentinel claims are bounded and intentionally handled | SIMD-007 |
| `ML-06` | duplicate | MLX lifecycle mutations are not serialized with synthesis | IOS-12 |
| `ML-07` | duplicate | MLX cache-prune scheduling flag has a Swift data race | IOS-13 |
| `NATIVE-007` | duplicate | Hardcoded window-title claim duplicates the application-ID mismatch hypothesis | NATIVE-006 |
| `PERF-01` | duplicate | Production deletion serializes every recording-file probe/delete and every database delete | FLUTTER-02 |
| `PERF-02` | duplicate | Audio loudness cache permits duplicate native decodes and evicts by FIFO rather than recency | FLUTTER-04 |
| `SEC-01` | duplicate | Direct cast-membership policies bypass the join-code authorization boundary | DAT-002/DAT-003 |
| `SEC-02` | duplicate | SECURITY DEFINER join RPC execute grants remain available through PUBLIC | DAT-004 |
| `SHELL-02` | duplicate | fetch-ort-java vendors unpinned native code for arbitrary versions | SUPPLY-01 |
| `SHELL-09` | duplicate | Crash-log path is interpolated into executable Python source | TOOL-01 |
| `SIMD-004` | duplicate | Fresh `floats` allocation claim is part of the speech-range scratch-allocation finding | SIMD-003 |
| `SIMD-025` | duplicate | Second ConvWeighted overload is the same transpose-cache issue | SIMD-024 |
| `AND-01` | false_positive | STT context assertions are not reachable after engine detach | The two `context!!` expressions are unattractive defensive-code gaps, but the alleged detach race is excluded by MethodChannel/plugin lifecycle serialization. There is no current crashing path to remediate. |
| `AND-02` | false_positive | stopRecording snapshots duration before another platform call can mutate it | Clearing the other fields before computing the local duration does not introduce concurrency. The claimed wrong-duration interleaving does not exist. |
| `AND-03` | false_positive | Detached-engine stop result does not strand a live Dart future | An attached flag would merely suppress a reply to a destroyed isolate and cannot make that Future complete. The review's proposed fix does not solve the stated consequence. |
| `AND-04` | false_positive | SpeechRecognizer RMS scaling is aligned with the Dart threshold | The review speculates about device calibration but does not establish threshold failure on the active Android rehearsal path. |
| `AND-05` | false_positive | MediaCodec BufferInfo is correctly reused per dequeue | There is no stale metadata window inside an iteration and no asynchronous callback sharing this object. |
| `AND-06` | false_positive | Nullable MediaCodec input buffer can terminate capture after start succeeds | The nullable type does not make this runtime-dependent. Android's `getInputBuffer` contract returns null only when the index is not a dequeued input buffer or the codec uses surface input. Here `inIndex` is returned immediately by `dequeueInputBuffer`, the AAC audio encoder is configured for ByteBuffer input, and no other thread flushes, stops, or releases it. Thus `getInputBuffer(inIndex)!!` is non-null on this p... |
| `AND-08` | false_positive | Synchronous recorder join is intentional and confined to mic handoff | The review itself says no current change is needed; no other main-thread caller exists. |
| `AND-09` | false_positive | PCM ByteArray cannot be safely reused across the asynchronous Dart post | The proposed preallocated shared array is unsafe under the current asynchronous ownership contract and does not eliminate the required immutable payload allocation. |
| `AND-11` | false_positive | Short-lived STT cleanup threads are bounded and user-paced | No leak, queue growth, or measured thread-creation cost is shown. A shared executor is optional cleanup, not a current defect. |
| `AND-12` | false_positive | STT nonvolatile fields and capture-error state are benign under current ownership | The review explicitly describes the fields as benign and the join as harmless. Volatile-for-symmetry would not fix an exhibited race. |
| `AND-13` | false_positive | Vendored ONNX Runtime artifacts have pinned provenance | The provenance concern is already satisfied. Universal APK size is a packaging choice, not evidence that every delivered split duplicates all ABIs. |
| `AND-14` | false_positive | Android signing and local property files are ignored and absent | No credential is committed or exposed; both review requests to verify ignore status are satisfied. |
| `AND-16` | false_positive | Permanent activity detach can leave a contact pick pending | The claimed surviving Future requires a cached/live FlutterEngine after permanent activity detach, but this repository uses a plain FlutterActivity and contains no cached-engine provider, `provideFlutterEngine`, or `destroyEngineWithActivity` override. The default activity-owned engine is destroyed on permanent host teardown, so its Dart isolate/Future does not remain live; configuration detach is already preserve... |
| `AND-17` | false_positive | Contact URI, permission, null-name, and exception claims match the intended contract | These are documented fallback/API choices, not silent cancellation or privilege bypass. The claim that activity-null result delivery drops data also lacks a reachable callback: the ActivityResultListener is tied to the attached binding. |
| `AND-19` | false_positive | Phone and email cannot be folded into the picked Contacts row as proposed | The review's optimization would fail or change semantics. Off-main-thread querying addresses the real UI issue without inventing an invalid projection. |
| `AND-20` | false_positive | Plugin registration and request code are not duplicated | The reviews supplied hypothetical duplicate configuration/collision scenarios but no second registration or request-code user. |
| `AND-22` | false_positive | OCR file paths do not cross an app security boundary | Restricting to an app directory would reject legitimate imported temporary/files-provider paths without removing a privilege escalation, because no lower-privilege principal is crossing the channel. |
| `AND-26` | false_positive | Current OCR dictionary is LF-only, so CRLF corruption is not present | There is no current malformed key. Trimming `\r` is harmless hardening but not a current defect. |
| `AND-27` | false_positive | Detection resize cannot round the long side above 960 | The numerical overflow example in the review is arithmetically incorrect, and the wide-image behavior is an acknowledged parity choice rather than a demonstrated defect. |
| `AND-30` | false_positive | Per-box sequential recognition is intentional and prior batching regressed accuracy | Linear work per real text line is expected OCR behavior; the proposed fixes either repeat a rejected experiment or violate extraction completeness. |
| `AND-31` | false_positive | Sequential PDF work and per-page progress are bounded-memory contract behavior | Large documents take proportionally longer by definition, but the reviews do not show retained bitmaps, queue buildup, or an ANR. Lowering render size or capping pages would reduce OCR quality/completeness. |
| `AND-32` | false_positive | recognizeText decodes unbounded full-resolution images before downscaling | Although the native `recognizeText` method decodes without sampling, the Dart wrapper is the only repository declaration and has no production caller. Current PDF import uses `ocrPdf`, and the page viewer uses `ocrPdfPage`, both of which render bounded page bitmaps. Therefore no current user-selected camera/image path reaches the full-resolution decode, so the asserted OOM path is not an exhibited app defect. |
| `AND-34` | false_positive | The 0.4 unclip value expands boxes and is corpus-validated | Substituting a generic DBNet reference constant would discard project-specific measured tuning; the review's stated shrink behavior is mathematically wrong. |
| `AND-35` | false_positive | Out-of-range CTC classes silently become confident spaces | The bundled recognition model output is `[dynamic, dynamic, 18710]`, while keys.txt has 18,708 entries. Paddle CTC adds blank at class 0 and, with `use_space_char`, one terminal space class, yielding exactly 18,710 classes. The only `idx >= keys.size` value possible is therefore the valid terminal space class (`best=18709`, `idx=18708`), which the code correctly maps to a space; no out-of-range model class exists ... |
| `AND-36` | false_positive | OCR assets are bundled and protected by APK signing | The missing-assets premise is false in this tree, and an additional runtime checksum does not protect against a repackager who can also replace the checksum/code. |
| `AND-38` | false_positive | Android PDF text methods deliberately signal OCR fallback | False does not skip OCR or produce empty imports. The performance review correctly notes current code does no I/O; a hypothetical future reimplementation is not a present defect. |
| `AND-39` | false_positive | MethodChannel lateinit fields follow FlutterPlugin lifecycle correctly | The alleged detach-before-attach and stale-handler paths violate the lifecycle contract; nullable channels would add state without fixing a reachable bug. |
| `AND-40` | false_positive | Android stub return values match Dart fallback contracts | The mixed shapes represent different method contracts, not ambiguous state. Replacing loadModel false with an error would produce the same fallback with noisier logs; changing cancel has no observable caller. |
| `AND-41` | false_positive | Flutter Gradle build-directory and clean configuration is stock and non-colliding | No stale/colliding output or deletion of source artifacts is shown. Restoring Gradle's default would diverge from Flutter tooling expectations. |
| `AND-42` | false_positive | Pinned FlutterFire plugin versions have no demonstrated incompatibility | Age alone is not an actionable code finding, and no upgrade behavior was verified. |
| `AND-43` | false_positive | Memory diagnostics calls and constant stub allocations are not hot paths | Both source reviews acknowledge negligible impact and no unbounded growth. Caching memory data would make diagnostics stale. |
| `DAT-011` | false_positive | Helper functions are deliberately exposed to anon as cross-user boolean oracles | The boolean oracle exists, but the immediately following hotfix explicitly documents and accepts it as the tradeoff required by the current policy signatures. That makes it deliberate rather than an unintentional bug under the audit criteria. Merely adding TO authenticated and revoking anon would remove anonymous probing, but authenticated callers could still pass arbitrary user UUIDs. If the product reverses the ... |
| `DAT-016` | false_positive | The record_linux dependency override is unexplained and may now be redundant | The committed lock proves the override is active and resolves record_linux 1.3.1 as direct overridden; it is not dependency drift hidden by a missing lock. An unexplained override is a maintainability concern, but neither the review nor repository establishes a broken Linux recording path, and publish_to:none removes the claimed consumer-override impact. Do not remove it based on this audit. A future intentional d... |
| `DAT-017` | false_positive | Debug-report/user-FK retention and account-deletion behavior require an explicit lifecycle decision | The FK semantics correction is right: NO ACTION blocks auth-user deletion rather than creating orphans. The repository exposes sign-out but no account-deletion operation, so no current client path is broken, and no stated retention contract establishes that debug reports must expire on a particular schedule. This is a product/lifecycle decision, not something runtime inspection can resolve. If account deletion is ... |
| `DAT-021` | false_positive | Claimed dependency versions and SDK constraint are demonstrably resolvable | Manifest/lock state directly refutes all seven version-nonexistence claims and the missing-lockfile claim. |
| `DAT-022` | false_positive | Several generic schema/migration claims do not match PostgreSQL semantics or client behavior | These claims infer failures contrary to actual database semantics or concrete client call sites. Similar generic claims about understudy read access, locale/voice free-form CHECK constraints, and nullable profile display_name lack an exhibited broken contract. |
| `FALSE-01` | false_positive | Missing recording context index does not access a negative list offset | There is no RangeError path. The function returns the empty-context placeholder as intended. |
| `FALSE-02` | false_positive | Kokoro synthesis queues requests while startup is in progress | Only calls made before startup has been initiated return null, which matches the documented failure contract. The claimed dropping of requests during active startup is not present. |
| `FALSE-03` | false_positive | Async test tearDown callbacks are awaited by flutter_test | The claimed cross-test sequencing and infinite loop on other exception types do not follow from the test framework or Dart catch semantics. |
| `FALSE-04` | false_positive | Cloud reconciliation intentionally persists under the fetched production, not the current one | Switching screens during fetch does not write A's script under B. Persisting A's fetched data even when B is now current is correct cache reconciliation. |
| `FALSE-05` | false_positive | Frame percentile index is in range for the only nonempty p99 call | No RangeError is reachable from the actual entry point. Generalizing `_pct` might justify a clamp later, but that is defensive style, not an existing defect. |
| `FLUTTER-19` | false_positive | Native model callback schema is unchecked at the Dart boundary | Current producers satisfy the casts exactly: Swift emits String modelId, Double progress, Int size, and String error; Android emits no callbacks. Relaunch delivery uses the same Swift callback. Future-version malformed payloads are boundary hardening, not a current defect. |
| `FP-01` | false_positive | Supabase/Firebase publishable client keys were misclassified as secrets | Moving public client configuration to an environment variable does not prevent extraction from the shipped app and does not fix an RLS flaw. The real issue exposed by the tools is their unsafe production behavior and the membership policies, reported separately. |
| `FP-02` | false_positive | Unvalidated local remoteUrl is not an SSRF/open-redirect boundary | Malformed data can cause a failed download or select another object the current user is already authorized to read, but the claimed javascript/file scheme execution, open redirect, SSRF, and cross-tenant disclosure are not reachable in current call paths. |
| `FP-03` | false_positive | Local Drift repository methods are not tenant authorization boundaries | A caller controlling the local process can alter its own cache, but cannot thereby overwrite another tenant's cloud row. Adding ownership checks to this local repository would not close the real direct-membership server-policy bypass. |
| `FP-04` | false_positive | Claimed recording/export/native path traversal is not reachable from untrusted IDs | The reviews assume a remote attacker can inject arbitrary file paths or method-channel calls, but no such trust transition exists in current code. A compromised Dart process already has equivalent access to its own sandbox, so native containment would not provide the claimed boundary. |
| `FP-05` | false_positive | Allow-listing an unused exact custom auth callback does not itself enable token interception | Custom schemes can be hijacked if a live OAuth/PKCE flow sends credentials to them, but that precondition is absent. The review relied on hypothetical future provider behavior rather than a reachable current flow. |
| `FP-06` | false_positive | Ten-second refresh-token reuse window is an explicit retry tradeoff, not demonstrated theft | An attacker who already stole a refresh token may exploit any accepted window, but reducing the standard retry grace to zero without evidence can break mobile retry races and does not remediate the token-theft root cause. This is a documented risk decision, not a confirmed defect from code alone. |
| `FP-07` | false_positive | SMTP/S3 env placeholders do not expose credentials | The reviews ask to verify a hypothetical future accidental commit but exhibit no current secret. The comment that the Resend account/domain is shared is not a credential. |
| `FP-08` | false_positive | Auth request spam is server-limited; a client cooldown is not a security boundary | The actionable cloud question is whether the server email ceiling is correctly scoped/tuned, reported separately as AUTH-03. The claimed missing client-side rate limit is not a security vulnerability. |
| `FP-09` | false_positive | Raw SDK errors shown to the initiating user do not expose demonstrated secrets | Generic messages may be preferable UX and reduce operational detail, but the claimed confidentiality impact is not established. Persistent credential/content logging is separately confirmed in SEC-04. |
| `FP-10` | false_positive | The offline auth-skipped preference does not create a cloud session | A user with filesystem/device control can reach offline screens, but cannot use the preference to read/write protected cloud data. Treating a local navigation flag as server authorization would be a flaw, but current cloud calls do not do that. |
| `FP-11` | false_positive | Unknown CastRole fallback does not grant organizer authorization | This is a correctness/forward-compatibility concern, not the claimed privilege escalation. Mapping unknown roles to understudy or rejecting them may still be safer UX. |
| `FP-12` | false_positive | Other claimed shell/eval injections lack attacker-controlled input | Unsafe-looking quoting alone is not an exploitable injection without an untrusted source. These can be hardened for maintainability but do not meet the current reachability requirement. |
| `IOS-09` | false_positive | Cancel does not cancel a restored background URLSession task | The native method would not find a restored task when `activeDownloads` is empty, but there is no Dart invocation of `cancelDownload` anywhere in current production code; repository-wide lookup finds only the native/stub implementations and review text. The stated user-cancel-after-relaunch trigger is therefore unreachable at this commit. Querying `getAllTasks` becomes required if a cancel UI/caller is added, but ... |
| `IOS-16` | false_positive | PaddleOCR's NOT_READY result does not trigger the promised Dart fallback | The wrapper itself catches only MissingPluginException for whole-PDF OCR, but the production import dispatch point wraps `PaddleOcrChannel.ocrPdf` in `catch (e)`, sets the result to null, and then runs Vision or ML Kit. The single-page wrapper also catches PlatformException, and `recognizeText` has no production callsite. Thus native `NOT_READY` already triggers the promised production fallback rather than a hard ... |
| `IOS-18` | false_positive | PaddleOCR marks itself ready even when its character dictionary failed to load | A genuinely missing dictionary is caught by `assetPath` in the three-asset guard and leaves `ready == false`, which takes the fallback path. The narrower read-failed/empty-dictionary case would set ready, but the dictionary is a signed read-only bundle resource and the committed file is present/nonempty; the reviews identify no production mutation or mismatched shipped model. This is useful load-time validation fo... |
| `IOS-R02` | false_positive | Several STT format, duration, permission, and on-device claims are not production defects | These claims either contradict the actual configured decode format/lifecycle or lack production reachability at this commit. The channel's misleading `onDevice` documentation can be cleaned separately but does not alter current behavior. |
| `IOS-R03` | false_positive | The alleged unguarded failable AVAssetReaderTrackOutput construction is not exhibited | The review inferred an obsolete/different API signature and described behavior the current Swift type checker cannot express. |
| `IOS-R05` | false_positive | Background download arbitrary-URL/path and unbounded-state claims are not production-reachable | Canonicalization/validation can be defense in depth, but the reviews' SSRF/path-escape, unbounded growth, and cross-queue severity assumptions do not match the actual bridge caller or URLSession configuration. |
| `IOS-R07` | false_positive | Contact delegate threading and cancellation-envelope claims are incorrect | No off-main mutation or malformed cancellation result is exhibited. Presentation must remain on main, as it already is. |
| `IOS-R08` | false_positive | Kokoro plugin Tasks are serviced serially and background-task cleanup is main-actor serialized | The reviews' unbounded concurrent GPU inference, double-end race, and lost-result claims do not follow from the actual service serialization and main-actor ordering. Lifecycle property isolation remains a separate needs-proof issue (IOS-12). |
| `IOS-R09` | false_positive | Media-control payload, mapping, logging, and target-removal claims are not current defects | These are hypothetical malformed-internal-call/future-owner concerns or intentional product semantics, not observed lifecycle/bridge defects at this commit. |
| `IOS-R10` | false_positive | Memory-monitor zero sentinels affect diagnostics only and polling cost is negligible | The claimed operational consequence is absent from callers. An explicit unknown sentinel would improve diagnostics but is not an actionable production bug under this assignment. |
| `IOS-R11` | false_positive | Paddle env/session concurrency and output-buffer claims do not match initialization or model ownership | The review described future-refactor or malformed-internal-model possibilities as current Swift races/crashes. Actual error suppression and performance issues are captured in IOS-17 through IOS-20. |
| `IOS-R12` | false_positive | PDF FlutterResult dispatch, Bool transfer, and empty-page semantics are valid | These claims mistake correct asynchronous bridge use/value capture and deliberate API semantics for lifecycle races. |
| `IOS-R13` | false_positive | Empty SceneDelegate is standard Flutter scene plumbing, not a lifecycle defect | An empty subclass is framework integration boilerplate, not actionable dead code by itself. |
| `ML-16` | false_positive | Background-task capture finding misstates Swift closure semantics | A separate cancellation design could improve long-running inference, but the asserted stale .invalid capture and mandatory delayed end are not shown by this code. |
| `ML-17` | false_positive | BART mask/token-map correctness claims conflict with current code and config | Several review claims were based on unseen/assumed configuration or stale code. |
| `NATIVE-001` | false_positive | Objective-C exception catcher implementation is present and linked into Runner | The review only hypothesized that the implementation might be absent because its batch contained the header. The implementation and production target membership are both present, so there is no link defect. |
| `NATIVE-002` | false_positive | my_application_new has a proper no-argument prototype in this C++ target | The review applied C semantics to code compiled as C++. There is no unspecified argument marshalling or performance consequence. |
| `NATIVE-003` | false_positive | Empty-argv startup crash is not reachable from the production Linux entrypoint | The review's crash requires an invalid synthetic invocation with no argv[0], not the production OS entrypoint. No user-controlled app argument can remove argv[0]. |
| `NATIVE-004` | false_positive | Registration-error dereference claim was self-withdrawn and is not a defect | There is no supported defect claim to accept. |
| `NATIVE-005` | false_positive | Returning TRUE after a handled registration failure is intentional GApplication flow | A GUI dialog is not required for a Linux runner registration failure, and the existing warning plus nonzero process exit is an observable failure signal. The review also says no change is needed. |
| `NATIVE-006` | false_positive | Linux title and application identifier are intentionally different kinds of values | Desktop application IDs are not expected to equal display titles. Both values consistently identify CastCircle and the review cites no desktop-file mismatch. |
| `PERF-R1` | false_positive | FrameStatsService window is bounded; the claimed 54k-entry/periodic-jank defect is unsupported | No measurement shows sorting ~1,800 doubles causes a missed frame, and replacing exact diagnostic percentiles with an approximation would reduce telemetry quality. The lists do not grow for the process lifetime under normal callbacks. |
| `PERF-R5` | false_positive | Scene-editor item work is lazy and proportional to visible scene contents, not scenes times the whole script | The reviews multiply independent bounds incorrectly and provide no frame profile. Memoizing counts would add invalidation complexity for a user-triggered editor screen without demonstrated cost. |
| `PERF-R6` | false_positive | Broadcast deep-link streams do not buffer unobserved events | The central memory-growth premise is contrary to broadcast stream semantics, and normal deep-link frequency is user-driven and tiny. |
| `PY-01` | false_positive | parse_script always overwrites fixed repository examples | The module docstring says this is both the working Pride & Prejudice parser and the reference implementation; its character database is also fixed to that play. Regenerating the two canonical example artifacts is therefore consistent with the script's explicit purpose, not shown accidental mutation. The unused md_path is dead code, not proof of a generic CLI contract. |
| `PY-02` | false_positive | parse_script silently trusts a shared /tmp default input | The no-argument /tmp/pride_full_ocr.txt input aligns with the same fixed Pride & Prejudice example-regeneration workflow. It is nonportable developer tooling, but the review does not establish that this CLI was meant to accept arbitrary inputs by default or that the fixed default is unintended. |
| `PY-07` | false_positive | Comparison subprocess can block indefinitely | The claimed trigger is merely that an arbitrary local PDF/native extractor could hang; no cited fixture, known PyMuPDF failure, or bounded-runtime contract establishes a bug in this one-shot comparison utility. A configurable timeout is optional developer hardening, not a merge-blocking correctness finding. |
| `PY-10` | false_positive | Per-call regex compilation claims ignore Python's regex cache | Hoisting could improve readability, but the review's stated dominant compile cost needs a profile before becoming an actionable performance finding. |
| `PY-11` | false_positive | make-demo scene/speaker claims do not match fixed-source behavior | The review hypothesizes arbitrary quoted headings and speaker inflation without an exhibited input in this fixed generator. |
| `SHELL-16` | false_positive | Pipeline-masking claims ignore enabled pipefail | Do not add PIPESTATUS complexity or duplicate checks to already-correct failure propagation. Limited tail output may reduce diagnostics but does not create the claimed false success. |
| `SIMD-005` | false_positive | Two linear speech-window scans are bounded and appropriate | This is O(n), required to locate both endpoints, and the review itself says no fix is needed. |
| `SIMD-006` | false_positive | One-time plugin registration is not a hot-path issue | No actionable performance defect exists. |
| `SIMD-009` | false_positive | Download progress throttle retains completed model IDs forever | The production caller cannot supply arbitrary model IDs: ModelDownloadService.download accepts an AiModel from the static availableModels catalogue, which contains exactly six fixed IDs, and repeated downloads overwrite the same dictionary key. lastProgressEmit therefore retains at most six small tuples in the shipped app. Terminal cleanup would be tidy, but the claimed app-lifetime unbounded growth is not reachab... |
| `SIMD-010` | false_positive | Persisted download dictionary is pruned and bounded by active transfers | Read-modify-write cost is bounded by concurrent active downloads and no production evidence suggests hundreds of simultaneous model downloads. |
| `SIMD-011` | false_positive | Kokoro synthesis already executes inference on a dedicated serial queue | The review did not follow the awaited service method and incorrectly inferred main-thread inference from Task inheritance. The production call chain explicitly leaves the main thread. |
| `SIMD-012` | false_positive | Model unload performs MLX cache destruction synchronously in the Flutter handler | The platform handler is registered, and TtsService defines unloadKokoro, but the repository has no production call site for unloadKokoro; its only occurrence is the method definition. Thus no app action reaches unloadModel, and profiling Memory.clearCache on that dead route cannot establish a pre-merge production defect. If this operation is wired into the app later, serialize it with synthQueue before exposing it. |
| `SIMD-013` | false_positive | Multi-file model directory deletion is synchronous in the Flutter handler | TtsService.deleteModel is likewise definition-only: no production Dart code invokes it, so the synchronous Swift deleteModel handler is not reachable from a user flow. ModelDownloadService has a different delete(String modelId) implementation and does not call this channel method. Move deletion off the handler and serialize teardown if a caller is added, but do not carry this as a current production performance fi... |
| `SIMD-015` | false_positive | Cache pruning is detached from first-synthesis latency | The review's claim that the first synthesis pays the directory walk before inference is contradicted by the asynchronous dispatch. Background O(n) maintenance may exist but no critical-path or scale defect is demonstrated. |
| `SIMD-016` | false_positive | SHA-256 cache-key hashing is negligible and the review withdrew it | No actionable performance issue remains. |
| `SIMD-017` | false_positive | ALBERT attention is GPU-backed MLX and the proposed fast API is not fused for this sequence shape | Quadratic full-sequence attention is standard model work under a fixed cap. The review's CPU, transpose-copy, and fused-kernel premises are unsupported for this production path. |
| `SIMD-018` | false_positive | ALBERT reshape metadata is tiny and MLX transposes are lazy graph operations | The claimed full-tensor copy and meaningful main-thread overhead are unsupported, and synthesis itself runs on synthQueue. |
| `SIMD-019` | false_positive | Attention-mask memoization is unsupported because each utterance constructs a new mask | No measured or source-proven consequential redundancy exists. |
| `SIMD-020` | false_positive | Snake activation already executes as MLX tensor work on the default device | These operations implement the trained Snake activation and cannot be replaced without numerical/model validation. A hypothetical unavailable-Metal path is not an accepted defect. |
| `SIMD-021` | false_positive | Four three-element initializer loops are bounded one-time model setup | The review itself describes the work as negligible and one-time. Combining loops would reduce clarity without measurable work. |
| `SIMD-022` | false_positive | Proposed MLX.variance replacement is not shown to be fused or cheaper | Replacing a deliberate implementation with an unverified primitive is not an evidence-backed optimization. A true fused layer-norm reformulation would also need numeric and performance proof and was not established by the review. |

| `ADV-08` | duplicate | Any production member can overwrite another member's recording object | ADV-05 |

## Post-remediation adversarial findings

The final diff audit found four additional defects in the first remediation pass. They are included in the canonical count above and were fixed before release packaging.

### ADV-FIX-01 — Joined OCR search anchors could restore quadratic mapping

- Severity/status: **P1 / confirmed and fixed**
- Code: `lib/data/services/script_import_service.dart`
- Evidence: One search interval spanning a drifted cursor and proportional estimate can grow with document length on every parsed line, restoring O(N²) work.
- Remediation: Search two independent bounded neighborhoods and select the stronger candidate, preferring the drift-independent estimate on ties.
- Verification: Real-corpus page mapping remains monotonic over 70 pages; highlight location succeeds for 1,161/1,187 lines (97.8%).

### ADV-FIX-02 — Superseded recording upload could stamp a replacement take

- Severity/status: **P1 / confirmed and fixed**
- Code: `lib/data/services/sync_queue.dart`, `lib/data/database/app_database.dart`, `lib/data/repositories/production_repository.dart`, `lib/providers/production_providers.dart`
- Evidence: Upload completion was keyed only by production/line. The production recording flow reuses the same filename, so path comparison also allowed an old in-flight take to write its URL onto the replacement Drift row and provider state.
- Remediation: Serialize the immutable `Recording.id` in each queue job, pass it from both production enqueue sites, and condition the Drift/state update on that id. Legacy persisted jobs use their immutable `recordedAt` timestamp as the compatibility guard.
- Verification: Regression tests replace a take with the same local filename and a different recording id; the old stamp changes zero rows and only the replacement id is reported uploaded.

### ADV-FIX-03 — Superseded unique recording objects leaked before metadata commit

- Severity/status: **P2 / confirmed and fixed**
- Code: `lib/data/services/sync_queue.dart`, `lib/data/services/supabase_service.dart`, `supabase/migrations/20260830120000_atomic_script_and_data_integrity.sql`
- Evidence: If re-recording replaced a queue job while its unique Storage upload was in flight, the returned object had no metadata row and no cleanup owner.
- Remediation: Transfer orphan object URLs into the replacement job's durable local state, retry failed handoff, and use an owner-checked security-definer RPC to commit cleanup intent to the database outbox before local ownership is released.
- Verification: Queue tests cover mid-upload replacement and failed cleanup retry; service tests prove a Storage deletion failure returns only after the database outbox has accepted the object.

### ADV-FIX-04 — Invitation retry coalescing could strand newly queued rows

- Severity/status: **P1 / confirmed and fixed**
- Code: `lib/providers/production_providers.dart`
- Evidence: `retryAll` returned an active pass without requesting a follow-up, and the first fix still had a completion-tail lost wakeup between drain completion and owner cleanup.
- Remediation: Record every coalesced request, drain requests in one owner loop, and retain a chained owner future whose completion drains any tail request before synchronously releasing ownership.
- Verification: A concurrency regression adds a second durable invitation while the first send is blocked; awaiting the shared owner sends and reconciles both rows.

## Release gates

- P1 confirmed findings must be fixed before release.
- P2 and P3 confirmed findings are part of this remediation branch; each fix needs targeted behavioral proof and an adversarial diff review.
- Runtime-proof items are changed only when a safe source-level invariant is independently confirmed or a benchmark/reproduction demonstrates the claimed cost. Otherwise they stay documented, not silently promoted to defects.
- Database migration `20260830120000_atomic_script_and_data_integrity.sql` was applied to linked project `vngpbmqymdaxxnvqptsk`; local and remote migration history both record `20260830120000`. No destructive audit cleanup was run.
- TestFlight work produces a release archive/IPA only; uploading is a separate consequential action.

## Physical-device benchmark evidence

- Comparison: baseline commit `7974003` versus this remediation branch, on the same devices with clean installs. These are one-run cold A/B probes, useful as direct regression evidence but not a statistically complete performance study.
- Android: Samsung SM-A356U, Android 16/API 36. The remediation branch passed the complete rehearsal harness, including long-line chunking and two 100%-score acoustic recognitions. The baseline hit the harness's prefetched-line latency gate and stopped before those later probes.

| Android probe | Baseline | Remediation | Change |
| --- | ---: | ---: | ---: |
| TTS engine start | 3,488 ms | 2,900 ms | -16.9% |
| Line 0 start | 6,779 ms | 6,460 ms | -4.7% |
| Prefetched line 1 start | 2,681 ms | 1,319 ms | -50.8% |
| Prefetched line 2 start | 456 ms | 258 ms | -43.4% |

- Remediation-only Android probes after the baseline gate: long line first chunk 3,461 ms, all three chunks 22,105 ms; inter-line gaps 741/629 ms; both acoustic matches 100%.
- iOS: iPhone `Jazzman 17`, iOS 26.6, wireless deployment, profile build. `integration_test/ios_audio_analysis_benchmark_test.dart` generated identical 48 kHz stereo PCM16 WAVs and measured analysis wall time plus physical-footprint growth.

| iOS audio probe | Baseline | Remediation | Result |
| --- | ---: | ---: | --- |
| 30 s wall time | 18 ms | 6 ms | -66.7% |
| 30 s footprint growth | +1 MB | +0 MB | bounded |
| 300 s wall time | 45 ms | 11 ms | -75.6% |
| 300 s footprint growth | +110 MB | +0 MB | bounded |
| 300 s normalized volume | 0.3437706 | 0.3437716 | equivalent within 0.0000011 |

- Absolute iOS starting footprints differed between launches, so the memory comparison uses each run's own peak-minus-start growth. The 10x duration increase raised baseline footprint by 110 MB while the chunked implementation remained flat, directly proving the intended whole-file-allocation removal.

- iOS Kokoro MLX: `integration_test/ios_kokoro_benchmark_test.dart` cleared the audio cache, synthesized identical text/voice/speed fixtures, and exercised three concurrent sibling prefetches on the same physical iPhone.

| iOS Kokoro probe | Baseline | Remediation | Result |
| --- | ---: | ---: | --- |
| Cache-cold line | 6,461 ms | 6,400 ms | -0.9%; no material change |
| Warm line | 264 ms | 272 ms | +3.0%; no material change |
| Sibling prefetch completion | 2/3 | 3/3 | cancelled line eliminated |
| Cold output size | 195,644 bytes | 195,644 bytes | exact parity |
| Warm output size | 150,044 bytes | 150,044 bytes | exact parity |

- The baseline cancelled the first sibling with `SYNTH_FAILED: Synthesis cancelled (newer request superseded)`. The remediation completed all three in 1,074 ms; an asserted repeat completed all three again in 1,084 ms. Its raw per-line inference rate is not materially faster—the repeat measured 6,782 ms cold and 282 ms warm—so the user-visible improvement is reliable prefetch availability, avoiding a later on-demand resynthesis stall. The baseline's 670 ms queue total is not a throughput win because it produced only two of three requested lines.

## Performance benchmark protocol

- Scope: benchmark only changes with a performance claim. Correctness, concurrency, RLS, and durability fixes remain gated by behavioral tests and adversarial reproductions rather than synthetic timing.
- Method: release/profile artifacts; identical fixture and device; three warmups followed by 20 measured runs where practical; alternate baseline/remediation order; cool the device between native inference runs; report median, p95, MAD, peak RSS/physical footprint, allocations, and output parity. Reject a change for a new p95 regression above 5% unless its correctness tradeoff is explicitly accepted.
- Dart/import/storage: exercise 100/500/1,000-item recording lists, sync queues, invitation batches, adaptation histories, and OCR mappings; measure wall time, UI-frame stalls, allocation count, persistence bytes, and asymptotic slope.
- Android native: run Paddle cold start plus 1/20/100-page OCR under Perfetto, a 10-minute STT session for callback/frame misses and RSS, and the rehearsal TTS/ASR harness for cold/prefetched latency, inter-line gaps, and acoustic correctness.
- iOS native: run AudioAnalysis over 30/300/1,800-second mono and stereo files under Instruments, Paddle OCR under Allocations/Time Profiler, 10-minute STT capture for callback underruns, and standardized Kokoro utterances for real-time factor, peak unified memory, and energy.
- Supabase: use local or staging data, not production load generation. Capture `EXPLAIN (ANALYZE, BUFFERS)` for membership lookup and script/recording RPCs, then test concurrent replacements/invitation claims for lock duration, throughput, and RLS correctness.

## Final verification

- Flutter suite: **696 passed, 1 skipped**; all non-skipped tests passed.
- Python unit suite: **10 passed**.
- Shell validation: every changed shell script passes Bash syntax checking.
- Analyzer: **0 errors**; 129 pre-existing warning/info diagnostics remain, so `flutter analyze --no-pub` exits nonzero.
- OCR real-corpus proof: 70 distinct monotonic pages; **1,161/1,187 (97.8%)** highlight hits.
- Replacement iOS archive: `build/ios/archive/Runner.xcarchive`; embedded build `160` was gated before export.
- Replacement TestFlight IPA: `build/ios/ipa/castcircle.ipa`; version `0.1.1`, embedded build `160`, 124,877,517 bytes.
- Replacement IPA SHA-256: `24d1891b0e1ebfed1389903d432e63fe1fae2f81bdb1d963796481b43df36c3f`.
- Apple processed build `160` as `VALID` and `APP_STORE_ELIGIBLE`; delivery UUID `b07715f1-dbf6-4047-b920-ce19b27d55a3`.
- Post-release onboarding regressions: **6 targeted tests passed**, covering direct model-download dispatch and exclusion of the local demo from cloud recording sync.
