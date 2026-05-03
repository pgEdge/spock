# Eliminating the Spock checkpoint hook and per-commit WAL flush for `spock.progress`

**Date:** 2026-04-21 (revised 2026-05-01 to reflect as-built behavior)
**Status:** Implemented

> **Two design changes from the original proposal**, both expanding scope:
>
> 1. **`remote_commit_ts` is recovered post-crash via a `pg_commit_ts` scan**, not left NULL. The original design accepted NULL as a freshness regression; the implementation runs a backward scan of `pg_commit_ts` for the relevant origin and repopulates the field. Promoted from a "follow-up" to a goal so `spock.progress` shows an accurate timestamp after a crash. The recovered `prev_remote_ts` is also intended to be useful for the planned parallel-apply rework.
> 2. **The RMGR (id 144) is kept**, retargeted from apply-progress recovery to per-event progress records. The original design deleted it entirely. The shipped version retains the registration and emits one WAL record per affected `SpockGroupHash` entry at each `resource.dat` dump call site (clean shutdown, `add_node`, table-sync). Each record carries the full `SpockApplyProgress` snapshot for that entry. The records are not required for state recovery; they exist so a `pg_waldump` trace shows the exact progress snapshot persisted at each event LSN — useful for incident reconstruction over time. A single `XLogFlush` at the end of each emit batch gives WAL durability symmetric with `resource.dat`'s `durable_rename()`.
>
> Sections below are updated to reflect what shipped.

## Problem

Spock currently maintains the `spock.progress` view via three coupled mechanisms:

1. A custom WAL RMGR (`src/spock_rmgr.c`) that emits a `SPOCK_RMGR_APPLY_PROGRESS` record on every applied remote-origin commit and calls `XLogFlush` synchronously (in addition to the `XLogFlush` that core's `CommitTransactionCommand` already performs).
2. A `Checkpoint_hook` (registered in `src/spock.c:1248`) that dumps the in-memory `SpockGroupHash` to `PGDATA/spock/resource.dat` at every Postgres checkpoint. This requires a patch to Postgres core (`src/backend/access/transam/xlog.c` and `src/include/access/xlog.h`) to add the hook callout.
3. A load/redo path that seeds shmem from `resource.dat` during `shmem_startup_hook` and overwrites with WAL redo of `APPLY_PROGRESS` records during recovery.

This design has two costs:

- **A Postgres core patch** (4 lines across 2 files) must be maintained for each supported Postgres version.
- **An extra synchronous `XLogFlush` on every applied remote-origin commit**, purely to persist monitoring data — doubling the fsync pressure of the apply hot path.

Investigation showed that Spock's apply worker already uses Postgres's native replication origins (`replorigin_session_get_progress`) to determine the resume LSN on reconnect. The correctness-critical "where do I resume from" question is handled entirely by stock logical-replication protocol. The checkpoint hook and WAL RMGR exist only to preserve additional monitoring-level fields (`remote_commit_ts`, `remote_insert_lsn`, `received_lsn`, `last_updated_ts`) across crashes. The checkpoint hook in particular was added (commit `a4b93e8`) to handle the case where apply workers are idle across a checkpoint — keepalive-driven advances of `remote_insert_lsn` are never WAL-logged, so the hook is the only path that preserves them.

## Goal

Remove the Postgres core patch (`Checkpoint_hook`) and the extra per-commit `XLogFlush`, while preserving user-visible `spock.progress` behavior across clean and crash restarts. Recover `remote_commit_ts` after crash via a backward scan of `pg_commit_ts` for the relevant origin so the view shows an accurate timestamp; the recovered `prev_remote_ts` is also intended to be useful for the planned parallel-apply rework.

## Non-goals

- Changing the `spock.progress` column schema or the SQL-level API.
- Altering apply-worker resume semantics (which are already handled by Postgres replication origins and need no change).
- Removing or reshaping the `SpockGroupHash` shmem layout or the `SpockApplyProgress` struct.
- Recovering `last_updated_ts` precisely (apply-time timestamp). Post-crash, set to the recovered `remote_commit_ts` (the publisher's commit timestamp) — a lower bound on local apply time that under-reports lag rather than zeroing it. Refreshes on the next applied commit.

## Design overview

The shipped design keeps `resource.dat` as a snapshot written at three call sites — clean shutdown (supervisor `before_shmem_exit`), `add_node`, and table-sync — and replaces WAL-based durability with three components:

1. **Replication origins as the source of truth for `remote_commit_lsn`.** At apply-worker startup, read the origin's LSN and reconcile shmem against it. If `resource.dat` holds a stale LSN for an entry (file_lsn < origin_lsn), the file's timestamp fields for that entry are cleared to NULL pending recovery by step 3.
2. **A forced keepalive on apply-worker (re)connect.** The subscriber sends a status-update message with `replyRequested=true` immediately after `spock_start_replication` returns. Postgres's walsender responds with a 'k' keepalive carrying its current `sentPtr`. The apply worker's existing keepalive handler populates `remote_insert_lsn` and `received_lsn` in shmem within milliseconds of reconnect, rather than waiting for `wal_sender_timeout / 2` (default 30s) to elapse.
3. **A backward `pg_commit_ts` scan to recover `remote_commit_ts` per origin.** When reconcile detects stale or absent state, a follow-on routine `recover_progress_timestamps_from_commit_ts()` walks `pg_commit_ts` backward from the latest xid, filtering on the publisher's origin id, and writes the max-by-ts back into shmem. Termination at 1000 commits seen for the origin or 1M xids total scanned, whichever first. `last_updated_ts` is set to the same recovered `remote_commit_ts` so the XOR invariant in `progress_update_struct` holds; using the publisher's commit_ts (rather than the subscriber's wall clock) gives a lower bound on local apply time that under-reports lag instead of hiding it as zero.

Together these handle every shmem field without WAL or checkpoint-time persistence:

| Field | Source | When authoritative |
|---|---|---|
| `remote_commit_lsn` | Replication origin (`replorigin_session_get_progress`) | At apply-worker startup, always correct |
| `remote_commit_ts` | `resource.dat` if validated against origin LSN; else `pg_commit_ts` scan | Preserved across clean restart; recovered post-crash; NULL only on fresh first start (no commits yet) |
| `remote_insert_lsn` | Forced 'k' keepalive | Within ~ms of apply worker connect |
| `received_lsn` | Same | Same |
| `last_updated_ts` | `GetCurrentTimestamp()` at each update; post-crash set to the recovered `remote_commit_ts` | Always advances during apply; post-crash pinned to the recovered publisher commit_ts as a lower bound on local apply time (under-reports lag rather than zeroing it); refreshes on next applied commit |
| `prev_remote_ts` | Set together with `remote_commit_ts` (same value) | Same as `remote_commit_ts` — recovered alongside |

## Architecture

### Startup flow

**Phase 1 — `shmem_startup_hook` (pre-recovery).**

Runs via `spock_group_shmem_startup()`, unchanged from today except that the spock RMGR no longer carries apply-progress records so WAL recovery has no state-bearing Spock records to redo:

1. Create the empty `SpockGroupHash` HTAB.
2. Call `spock_group_resource_load()` to load `PGDATA/spock/resource.dat` if present and valid (version and `system_identifier` match). Each record is upserted into the hash via `spock_group_progress_update()`.
3. **No state-bearing WAL redo for Spock records.** The RMGR (id 144) is retained but its only record type is a dump-event marker whose redo handler emits a `LOG` line and does not touch shmem.

At the end of phase 1, shmem contains either an empty hash or the contents of the last clean shutdown's `resource.dat`. Values may be stale if a crash occurred since that shutdown.

**Phase 2 — per-apply-worker reconciliation.**

In `spock_apply_main()`, after `replorigin_session_setup()` returns the session's origin but before `spock_start_replication()` is called, each worker reconciles its own shmem entry. `reconcile_progress_with_origin()` returns a `ReconcileResult` enum so the caller can gate Phase 3 (the recovery scan) on whether reconcile detected staleness.

1. Compute the shmem key: `(MyDatabaseId, MySubscription->target->id, MySubscription->origin->id)`.
2. Fetch `origin_lsn = replorigin_session_get_progress(false)`.
3. Acquire `SpockCtx->apply_group_master_lock` in exclusive mode; HASH_ENTER for the entry:
   - **Entry absent.** Initialize with `remote_commit_lsn = origin_lsn`, other fields zero/NULL. Result: `RECONCILE_FILE_ABSENT`.
   - **Entry present, `file_lsn == origin_lsn`.** File is in sync with the origin. Keep `remote_commit_ts` and `last_updated_ts` as loaded. Result: `RECONCILE_FILE_IN_SYNC`.
   - **Entry present, `file_lsn < origin_lsn`.** File is stale for this entry. Overwrite `remote_commit_lsn` with `origin_lsn`; clear `remote_commit_ts` and `last_updated_ts` to 0; bump `remote_insert_lsn` and `received_lsn` up to at least `origin_lsn` to preserve the `insert_lsn >= commit_lsn` invariant (the forced keepalive will refresh them shortly). Result: `RECONCILE_FILE_STALE`.
   - **Entry present, `file_lsn > origin_lsn`.** Anomalous; shouldn't occur in normal flow. Log a warning and prefer `origin_lsn` (same body as STALE). Result: `RECONCILE_FILE_ANOMALY`.
4. Release the lock and return the result.

Phase 2 lives in the apply worker (not the shmem_startup_hook) because the startup hook runs before catalogs and subscriptions are readable.

**Phase 3 — `pg_commit_ts` scan to recover `remote_commit_ts`.**

If reconcile returned anything other than `RECONCILE_FILE_IN_SYNC`, run `recover_progress_timestamps_from_commit_ts(entry, target_origin)` where `target_origin = MySubscription->origin->id` (the publisher's spock node id, which is what `pg_commit_ts` records for applied xacts on the subscriber — `handle_origin()` overwrites `replorigin_session_origin` per-message with that value).

The scan walks backward from `ReadNextTransactionId() - 1` in batches of `SPOCK_TS_RECOVERY_BATCH_SIZE` (1000), calling `TransactionIdGetCommitTsData(xid, &ts, &origin)` for each xid. Filter: `origin == target_origin`. Track per-origin `running_max_ts` and `seen_count`. Terminate when:

- `seen_count >= SPOCK_TS_RECOVERY_MIN_SEEN_PER_ORIGIN` (1000), or
- `total_scanned >= SPOCK_TS_RECOVERY_SCAN_LIMIT` (1M), or
- backward scan reaches `FirstNormalTransactionId`.

The 1000-commits-per-origin termination is justified by concurrency width: the publisher's max in-flight xacts is bounded well below 1000 by `max_connections` and pooler limits, so any commit older than the 1000th observed has a strictly smaller commit_ts than the max already seen — even under parallel apply where xid order ≠ commit_ts order on the subscriber.

If `running_max_ts > 0`, write it under the master lock to `remote_commit_ts`, `prev_remote_ts`, and `last_updated_ts` (XOR invariant in `progress_update_struct` requires `remote_commit_ts` and `last_updated_ts` to be both zero or both non-zero). Using the recovered publisher commit_ts for `last_updated_ts` rather than the subscriber's wall clock gives a lower bound on local apply time, which under-reports lag instead of hiding it. The next applied commit refreshes `last_updated_ts` to the actual subscriber-side `GetCurrentTimestamp()`. If `running_max_ts == 0`, log a `WARNING` and proceed with NULL.

The constants are `#define`s in `src/spock_progress_recovery.c` (`SPOCK_TS_RECOVERY_MIN_SEEN_PER_ORIGIN`, `SPOCK_TS_RECOVERY_SCAN_LIMIT`, `SPOCK_TS_RECOVERY_BATCH_SIZE`). Convert to GUCs only if profiling motivates tuning.

A `LOG` line is emitted on completion in either path: "ts recovery: file in sync with origin, skipping scan" (skip) or "ts recovery: scanned N xids, found K commits, recovered remote_commit_ts" (run). `LOG` rather than `INFO` because INFO is client-only and does not reach the server log for a bgworker.

`track_commit_timestamp = on` is required. Spock already enforces this via the `spock.conflict_resolution` GUC's `check_hook` (the only allowed value `last_update_wins` requires it), which fires at postmaster start. The recovery scan therefore does not need its own guard — by the time it runs, the GUC is guaranteed on.

**Phase 4 — forced keepalive.**

Immediately after `spock_start_replication()` returns, before entering the receive loop, the apply worker calls a new helper:

```c
static void
request_initial_status_update(PGconn *conn, XLogRecPtr startpos);
```

This sends an 'r' status-update message with `replyRequested=true` but leaves `send_feedback()`'s static bookkeeping untouched. The walsender's `ProcessStandbyReplyMessage` sees the flag and calls `WalSndKeepalive(false, InvalidXLogRecPtr)`, which emits a 'k' with the publisher's current `sentPtr`. The subscriber's existing keepalive handler routes it through `UpdateWorkerStats`, populating `remote_insert_lsn` and `received_lsn` in shmem.

### Runtime flow

**Commit path (`handle_commit` in `src/spock_apply.c:992-1023`).**

Delete the `spock_apply_progress_add_to_wal(&sap)` call. The surrounding `SpockApplyProgress` construction remains; `spock_group_progress_update_ptr()` continues to update shmem. Net: one fewer `XLogFlush` per applied remote-origin commit.

**Keepalive path.**

Unchanged. `UpdateWorkerStats()` updates `remote_insert_lsn` / `received_lsn` in shmem for every incoming message.

**`spock_group_progress_force_set_list()` (add_node path).**

Used during `add_node` to populate the new node's view of mesh-peer progress from `read_peer_progress()` output. These entries are *deduplication state* for forwarded transactions in a mesh (not just monitoring), so they must be crash-durable before the first clean shutdown.

Transformation:
1. Remove the per-entry `spock_apply_progress_add_to_wal(sap)` call.
2. Per entry: acquire master lock → mutate shmem → release lock (no I/O under the lock).
3. After the loop: call `spock_group_resource_dump()` once to persist all entries atomically via `durable_rename`.

Rationale: `resource.dat` is a full-snapshot dump, not an incremental format, so N per-entry dumps would rewrite the entire file N times. A single post-loop dump gives equivalent durability (`add_node` is all-or-nothing at the admin level) with O(1) file writes.

**`spock_group_progress_update_list()` (table-sync path).**

Same transformation as `force_set_list`: drop the per-entry WAL call, add a single `spock_group_resource_dump()` after the loop.

### Shutdown flow

The clean-shutdown dump runs from the supervisor's `before_shmem_exit` callback (`spock_supervisor_on_exit` in `src/spock.c`), not from postmaster context. The supervisor first poll-waits for sibling apply/sync workers to clear their `PGPROC` slots (~5 s ceiling), then calls `spock_group_resource_dump()` followed by `spock_rmgr_log_resource_dump(SPOCK_DUMP_SHUTDOWN, NULL)`. Running in the supervisor process is required for the WAL emit (postmaster has no backend slot for `XLogInsert`); the drain wait ensures the file dump and the SHUTDOWN forensic records both reflect each worker's last update to `SpockGroupHash`. This is the sole remaining runtime producer of `resource.dat` on clean exit.

## Code changes

### Delete

- `spock_checkpoint_hook()` function in `src/spock_group.c` (no longer registered or referenced).
- `extern void spock_checkpoint_hook(...)` declaration in `include/spock_group.h`.
- The apply-progress recovery contents of `src/spock_rmgr.c` (the redo handler that replayed `SPOCK_RMGR_APPLY_PROGRESS` records into shmem). The file itself is retained — see "Trim, do not delete" below.
- The `spock_apply_progress_add_to_wal()` emit helper.

### Remove one-liners

- `src/spock.c` — `Checkpoint_hook = spock_checkpoint_hook;`.
- `src/spock_apply.c:handle_commit` — `spock_apply_progress_add_to_wal(&sap);`.
- `src/spock_group.c:spock_group_progress_update_list` — `spock_apply_progress_add_to_wal(sap);`.
- `src/spock_group.c:spock_group_progress_force_set_list` — `spock_apply_progress_add_to_wal(sap);`.
- `#include "spock_rmgr.h"` in `include/spock_group.h` (was a circular include with no consumer).

### Trim, do not delete

- **`src/spock_rmgr.c`** — replace the apply-progress recovery contents with a single record type `SPOCK_RMGR_RESOURCE_DUMP`. New emit helper `spock_rmgr_log_resource_dump(event, changed_entries)` is called at each of the three `resource.dat` dump call sites. Each call emits one WAL record per progress entry, carrying the full `SpockApplyProgress` snapshot for that entry so a `pg_waldump` trace shows exactly what state was on disk at each event LSN — useful for incident reconstruction over time. A single `XLogFlush` at the end of each emit batch covers all records.
  - For `SHUTDOWN` and `ADD_NODE`: caller passes `NULL` for `changed_entries`; the helper walks `SpockGroupHash` and emits a record per entry. Both events reflect changes across all subscriptions.
  - For `TABLE_SYNC`: caller passes the same list of `SpockApplyProgress *` it just used to update shmem. Only the affected subscription's entries are emitted, since table-sync is per-subscription.
  - Redo handler emits a `LOG` line per record showing event type, sequence in batch, key, LSNs, and `commit_ts`. Records are not used for state recovery.
- **`include/spock_rmgr.h`** — replace declarations to match the trimmed contents (`SPOCK_RMGR_ID = 144`, `SPOCK_RMGR_RESOURCE_DUMP = 0x10`, `SpockResourceDumpRec` carrying `event_type` + `entry_seq`/`entry_total` + the embedded `SpockApplyProgress`, `SpockResourceDumpEvent`, the emit helper).
- **`src/spock.c`** — `spock_rmgr_init()` call retained in `_PG_init`. Header include retained.

### Modify

- **`src/spock_progress_recovery.c` and `include/spock_progress_recovery.h`** (new module) — single public entry point `spock_init_progress_state(XLogRecPtr origin_lsn)`. File-static internals: the `ReconcileResult` enum, `reconcile_progress_with_origin()`, `recover_progress_timestamps_from_commit_ts()`, and the `SPOCK_TS_RECOVERY_*` `#define`s.
- **`src/spock_apply.c`** — add a new helper `request_initial_status_update(PGconn *conn, XLogRecPtr startpos)` that emits an 'r' message with `replyRequested=true` without touching `send_feedback`'s static state.
- **`src/spock_apply.c:spock_apply_main`** — between `replorigin_session_setup` and `spock_start_replication`, call `spock_init_progress_state(origin_lsn)` once; this internally runs reconcile and (if reconcile detected staleness) the `pg_commit_ts` scan. After `spock_start_replication` returns, call `request_initial_status_update`.
- **`src/spock_group.c:spock_group_progress_force_set_list`** — drop the WAL call; add a single `spock_group_resource_dump()` followed by `spock_rmgr_log_resource_dump(SPOCK_DUMP_ADD_NODE, ...)` after the loop.
- **`src/spock_group.c:spock_group_progress_update_list`** — same with `SPOCK_DUMP_TABLE_SYNC`.
- **`src/spock.c:spock_supervisor_main`** — register `spock_supervisor_on_exit` via `before_shmem_exit`. The callback poll-waits for apply/sync workers to detach via a new helper `spock_any_apply_worker_running()` (in `src/spock_worker.c`), then calls `spock_group_resource_dump()` followed by `spock_rmgr_log_resource_dump(SPOCK_DUMP_SHUTDOWN, NULL)`. The previous postmaster-context `spock_on_shmem_exit` in `src/spock_shmem.c` is removed entirely; both file and WAL dumps now have a single owner that runs in the supervisor process where `XLogInsert` is permitted.

### Keep unchanged

- Clean-shutdown gating semantics (only dumps if `code == 0`) — preserved in `spock_supervisor_on_exit`.
- `spock_group_resource_load()`, `spock_group_resource_dump()` — load/dump file-format code.
- `SpockApplyProgress` and `SpockGroupEntry` struct layouts.
- `spock.progress` SQL view and `get_apply_group_progress()` function.

### Postgres core patch removal

The patch can be reverted entirely after the Spock-side removal. Four lines across two files:

- `postgresql/src/backend/access/transam/xlog.c:173` — `Checkpoint_hook_type Checkpoint_hook = NULL;`.
- `postgresql/src/backend/access/transam/xlog.c:7648-7649` — 2-line `if (Checkpoint_hook) Checkpoint_hook(...)` invocation inside `CreateCheckPoint`.
- `postgresql/src/include/access/xlog.h:218-219` — typedef + `extern PGDLLIMPORT` declaration.

No other Spock or Postgres-patch code depends on `Checkpoint_hook`.

## Edge cases

**Forced keepalive: publisher never responds.** Not blocking. The apply worker proceeds into its normal receive loop; `remote_insert_lsn` / `received_lsn` stay at seeded values (or NULL) until a 'k' or 'w' arrives via Postgres's own `wal_sender_timeout / 2` cadence. Worst case matches current behavior.

**Startup: origin exists but `resource.dat` is missing.** Phase 2 initializes a fresh shmem entry with `remote_commit_lsn = origin_lsn` and NULL timestamps. Equivalent to first-time start.

**Startup: `resource.dat` entry for a subscription that was dropped.** Old entry sits in shmem; no apply worker reconciles it. Matches current behavior. Optional follow-up: purge unknown entries after catalog is readable.

**Startup: origin LSN is `InvalidXLogRecPtr`.** Subscription exists but nothing has been applied. Reconcile still runs first: if the loaded `resource.dat` entry has `file_lsn > 0` it is treated as ANOMALY (file ahead of origin) — `commit_lsn` is overwritten to 0, timestamps cleared, insert/received bumped to 0. If `file_lsn == 0` the IN_SYNC branch keeps the file as-is. The `pg_commit_ts` scan is then skipped via the `XLogRecPtrIsInvalid(origin_lsn)` short-circuit in `spock_init_progress_state`, since a fresh origin has no progress to recover and `pg_commit_ts` rows from a prior subscription would only backfill stale historical timestamps.

**`add_node` retry.** Failed mid-loop leaves shmem partially updated and the file untouched (dump runs only after the loop completes). Second run's unconditional overwrite (`init_progress_fields` then `progress_update_struct`) replaces partial state; dump runs after the loop. Fine.

**`add_node` interrupted after dump.** All entries persisted; re-run is idempotent.

**Multiple apply workers.** Each worker reconciles its own key under the master lock. No cross-worker interference. Forced keepalive is per-connection.

**Post-crash with publisher offline.** `remote_commit_ts` is recovered from the subscriber's `pg_commit_ts` (which survives the crash) by the Phase 3 scan. Recovery does not depend on the publisher being reachable. The only situation that yields NULL is one where `pg_commit_ts` itself has no entries for this origin within the last 1M xids — typically a fresh subscription that has not yet applied any commits.

**Recovery scan finds nothing.** If the subscriber has no `pg_commit_ts` entries with `roident == target_origin` in the last 1M xids, `running_max_ts` stays 0. We log a `WARNING` and proceed with NULL `remote_commit_ts`. This is rare and matches the fresh-subscription case anyway.

**Recovery scan picks up unrelated commits.** The filter `roident == MySubscription->origin->id` is the publisher's spock node id, not subscription-unique. Sibling subscriptions to the same publisher, or a dropped/recreated subscription with old commits still in the 1M-xid window, can contribute to `running_max_ts`. Under monotonic publisher clocks the max-by-ts naturally prefers the most recent commit (current sub), so the failure mode is narrow: clock skew between drop and recreate, or scenarios where stale commits are newer than current ones. Impact is forensic-only — `prev_remote_ts` is not consumed today (apply-group ordering is disabled). The planned parallel-apply rework is the natural place to revisit.

**Concurrency width vs. termination bound.** The scan stops after observing 1000 commits per origin, which is correct only if max in-flight concurrent xacts on the publisher is bounded below 1000. PostgreSQL's `max_connections` defaults to 100, and pooled deployments cap effective concurrency well below that. If a deployment ever exceeds it, the constant is a single `#define` to bump.

**Publisher clock skew (NTP step-back).** `running_max_ts` is the max-by-ts. If the publisher's clock steps backward such that commit_ts order disagrees with commit *order*, the recovered `prev_remote_ts` may not match the next transaction's `required_commit_ts` from the publisher. Theoretical only — the apply-group ordering machinery that consumes `prev_remote_ts` is currently disabled. The planned parallel-apply rework will revisit. Out of scope for this design.

**Shmem hash full during `force_set_list`.** Warn and continue (existing behavior unchanged). Post-loop dump persists whichever entries made it in.

**Concurrent shutdown during reconciliation.** Worker completes its update under the lock, releases, exits on next `CHECK_FOR_INTERRUPTS`. Shutdown hook dumps resource.dat with the reconciled values. Reconciliation-then-dump cannot leave shmem more stale than the file.

## Testing

### Modified existing tests

- `tests/tap/t/008_rmgr.pl` — rewrote Phase 4 assertions for the new reconcile semantics. Covers the multi-origin case (Scenario A: file has stale entry, Scenario B: file has no entry for an origin). The test issues a `CHECKPOINT` before SIGKILL so the apply worker's WAL is durable past batch-2; without this, walwriter-cadence races could leave recovery's origin LSN at batch-1 and reconcile would take the IN_SYNC path instead of STALE.
- `tests/tap/t/022_rmgr_progress_post_checkpoint_crash.pl` — rewrote to assert that reconcile detects `file_lsn < origin_lsn` after a crash, advances `remote_commit_lsn` from the replication origin, and (with the recovery scan) that `remote_commit_ts` is recovered non-NULL post-crash. Also asserts CHECKPOINT does NOT update `resource.dat` (regression guard against re-introducing the checkpoint hook).

### New tests

1. **`023_forced_keepalive_timing.pl`** — set `wal_sender_timeout=10min` so the timer-driven path is disabled; assert `remote_insert_lsn` populates within 1 second (proves the forced keepalive, not the timer, drove the refresh).
2. **`026_no_double_wal_flush.pl`** — count `pg_stat_wal.wal_sync` delta over 30 applied commits; assert delta < N (no per-commit forced fsync on the apply hot path).
3. **`027_remote_commit_ts_recovery.pl`** — apply commits, clean restart, more commits, CHECKPOINT, SIGKILL, restart; assert `remote_commit_ts` is non-NULL post-crash (recovered via the `pg_commit_ts` scan).
4. **`029_remote_commit_ts_recovery_clean_shutdown.pl`** — clean restart only; assert the skip-path `LOG` line ("file in sync with origin, skipping scan") fires and the run-path log does not, and `remote_commit_ts` is preserved.

### Deferred / not implemented

- **`track_commit_timestamp = off` test.** Cannot occur in practice because spock's existing `spock.conflict_resolution` GUC validation aborts the postmaster at startup if the GUC is off. The recovery scan is unreachable in that scenario.
- **Idle-cluster test (no commits in last 1M xids).** Would require either >1M unrelated xids of activity or a temporary constant override. Both too heavy for v1.
- **`add_node` interrupted mid-loop test.** Out of scope for this design; covered by existing `add_node` integration tests.

### Regression safety checks

- `spock.progress` column set unchanged.
- `read_peer_progress()` SQL function output unchanged.
- Downstream tools reading `spock.progress` (spockctrl, monitoring scripts) see no schema or column-type changes.

## Follow-ups (out of scope)

- Convert `SPOCK_TS_RECOVERY_*` `#define`s to GUCs if any deployment ever needs to tune them.
- Generalize the forensic RMGR record into a small audit-event family covering more rare events (`add_node` / `drop_node` lifecycle, subscription state transitions, sync start/end). Sketched separately in `2026-05-01-spock-audit-rmgr-design.md`.
- Revisit the parallel-apply ordering coordinate. The current `commit_ts`-based approach is exposed to publisher clock skew; alternatives will be considered alongside the parallel-apply rework.
- Multi-origin shared scan: a single backward pass that populates all origins' shmem entries at once, gated by a per-origin "recovery done" flag in `SpockGroupEntry`. Worth doing only if profiling shows per-worker scan cost matters.
- Purging `resource.dat` entries that reference subscriptions that no longer exist.
- Removing the obsolete `updated_by_decode` field from the `SpockApplyProgress` struct layout. (`prev_remote_ts` is still actively used as the wait/signal coordinate for the parallel-apply machinery — keep until that rework lands.)
