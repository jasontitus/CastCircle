# Adversarial review: build 167 database startup

Reviewed commit 05e54b8, its UI and sync queue call sites, and the installed
Drift 2.34.0 opening implementation. This was a local review, not an independent
multi-agent audit. No physical-device test or new release was performed.

## P1: Startup timeout leaves the shared database unusable after lock release

Location: lib/data/database/app_database.dart:1213–1218.

The three-second busy timeout addresses short contention but not recovery.
NativeDatabase.createInBackground uses Drift's remote executor, whose
ensureOpen caches its future in _serverIsOpen, including a failed future.
After WAL setup times out, later reads and production saves keep returning
that original failure even when the competing connection has released its
lock. Both UI and sync queue now retain that executor through the singleton.

Reproduction against the shipped implementation:

1. Create a real SQLite file containing an existing production.
2. Open a second connection and hold BEGIN EXCLUSIVE.
3. Open AppDatabase.forTestingFile on the same file and query productions.
4. Await the expected database-is-locked error after the busy timeout.
5. COMMIT the competing transaction, releasing the lock.
6. Query the same AppDatabase instance again, expecting the existing row.

Step 6 fails with the cached WAL setup exception. The remote exception wrapper
was accounted for before evaluating this result. The failing reproduction is
saved locally at /tmp/castcircle-build167-long-lock-reproducer.dart; output is
/tmp/castcircle-167-adversarial.log. This extends the already documented timeout
limit: the material defect is failure persisting after contention has ended.

Recommended repair: serialize replacement of the failed startup executor on a
subsequent attempt for confirmed transient busy/locked opening errors, and
close the abandoned executor. Preserve a stable shared database abstraction
for existing repositories and the queue. Do not retry arbitrary writes or
schema errors blindly, and do not delete database or journal files. Regression
coverage must include timeout, release, retry, concurrent retry callers, and
preservation of existing rows and schema migration failures.

Status: confirmed and unresolved in build 167. No runtime fix applied by this
review.

## Checks that passed

- Default callers share one database instance; production call sites do not
  explicitly close it. Provider disposal no longer closes it.
- Short external lock waits and then permits reading and creating productions.
- Concurrent production transactions and sync writes preserve their rows.
- New fault injection: a failed production transaction rolls back its own row
  while a concurrently queued sync write persists and the original row survives.
- Targeted startup, migration, and sync suites: 33 passed.

No second confirmed issue in this bounded pass. This does not establish safe
behavior under disk exhaustion, database corruption, or arbitrary account
switching races. Existing recording-export errors remain outside this review.
