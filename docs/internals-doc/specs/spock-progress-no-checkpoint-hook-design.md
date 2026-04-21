# Eliminating the Spock checkpoint hook and per-commit WAL flush for `spock.progress`

**Date:** 2026-04-21
**Status:** Design approved; pending implementation plan

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

Remove the Postgres core patch (`Checkpoint_hook`) and the extra per-commit `XLogFlush`, while preserving user-visible `spock.progress` behavior across clean restarts. Accept a small regression in post-crash monitoring freshness (`remote_commit_ts` becomes NULL after a crash-with-new-commits, instead of showing stale-from-last-shutdown), in exchange for a substantially simpler implementation.

## Non-goals

- Changing the `spock.progress` column schema or the SQL-level API.
- Altering apply-worker resume semantics (which are already handled by Postgres replication origins and need no change).
- Removing or reshaping the `SpockGroupHash` shmem layout or the `SpockApplyProgress` struct.
- Attempting to recover `remote_commit_ts` per-origin from Postgres internals at startup. (Investigated: replication origins persist only `remote_lsn`, and Postgres exposes no efficient per-origin lookup in the commit-ts SLRU. Deferred as a follow-up.)

## Design overview

The new design keeps `resource.dat` as a shutdown-only snapshot and replaces WAL-based durability with two components:

1. **Replication origins as the source of truth for `remote_commit_lsn`.** At apply-worker startup, read the origin's LSN and reconcile shmem against it. If `resource.dat` holds a stale LSN for an entry (file_lsn < origin_lsn), the file's timestamp fields for that entry are cleared to NULL — they can't be trusted.
2. **A forced keepalive on apply-worker (re)connect.** The subscriber sends a status-update message with `replyRequested=true` immediately after `spock_start_replication` returns. Postgres's walsender responds with a 'k' keepalive carrying its current `sentPtr`. The apply worker's existing keepalive handler populates `remote_insert_lsn` and `received_lsn` in shmem within milliseconds of reconnect, rather than waiting for `wal_sender_timeout / 2` (default 30s) to elapse.

Together these handle every shmem field without WAL or checkpoint-time persistence:

| Field | Source | When authoritative |
|---|---|---|
| `remote_commit_lsn` | Replication origin (`replorigin_session_get_progress`) | At apply-worker startup, always correct |
| `remote_commit_ts` | `resource.dat` if validated against origin LSN; else NULL until next commit | Preserved across clean restart; NULL after stale-detected crash; NULL on fresh first start |
| `remote_insert_lsn` | Forced 'k' keepalive | Within ~ms of apply worker connect |
| `received_lsn` | Same | Same |
| `last_updated_ts` | `GetCurrentTimestamp()` at each update, or from file | Always advances with events |
| `prev_remote_ts` | No longer written (field kept in struct; obsolete) | — |

## Architecture

### Startup flow

**Phase 1 — `shmem_startup_hook` (pre-recovery).**

Runs via `spock_group_shmem_startup()`, unchanged from today except that the spock RMGR no longer exists so WAL recovery has no Spock records to redo:

1. Create the empty `SpockGroupHash` HTAB.
2. Call `spock_group_resource_load()` to load `PGDATA/spock/resource.dat` if present and valid (version and `system_identifier` match). Each record is upserted into the hash via `spock_group_progress_update()`.
3. **No WAL redo for Spock records** (the RMGR is deleted).

At the end of phase 1, shmem contains either an empty hash or the contents of the last clean shutdown's `resource.dat`. Values may be stale if a crash occurred since that shutdown.

**Phase 2 — per-apply-worker reconciliation.**

In `spock_apply_main()`, after `replorigin_session_setup()` returns the session's origin but before `spock_start_replication()` is called, each worker reconciles its own shmem entry:

1. Compute the shmem key: `(MyDatabaseId, MySubscription->target->id, MySubscription->origin->id)`.
2. Fetch `origin_lsn = replorigin_session_get_progress(false)`.
3. Acquire `SpockCtx->apply_group_master_lock` in exclusive mode; HASH_ENTER for the entry:
   - **Entry absent.** Initialize with `remote_commit_lsn = origin_lsn`, other fields zero/NULL.
   - **Entry present, `file_lsn == origin_lsn`.** File is in sync with the origin. Keep `remote_commit_ts` and `last_updated_ts` as loaded.
   - **Entry present, `file_lsn < origin_lsn`.** File is stale for this entry. Overwrite `remote_commit_lsn` with `origin_lsn`; clear `remote_commit_ts` and `last_updated_ts` to NULL; leave `remote_insert_lsn` and `received_lsn` untouched (they'll be overwritten by the forced keepalive momentarily).
   - **Entry present, `file_lsn > origin_lsn`.** Anomalous; shouldn't occur in normal flow. Log a warning and prefer `origin_lsn`.
4. Release the lock.

Phase 2 lives in the apply worker (not the shmem_startup_hook) because the startup hook runs before catalogs and subscriptions are readable.

**Phase 3 — forced keepalive.**

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

Unchanged. `src/spock_shmem.c:190-199` already contains a `spock_on_shmem_exit` callback that calls `spock_group_resource_dump()` only on clean exit (`if (code != 0) return;`). This is the sole remaining runtime producer of `resource.dat`.

## Code changes

### Delete

- `src/spock_rmgr.c` — entire file.
- `include/spock_rmgr.h` — entire file (contains no live struct definitions; `SpockApplyProgress` and `SpockGroupEntry` live in `include/spock_group.h:116-147`).
- `spock_checkpoint_hook()` function in `src/spock_group.c:653-671`.
- `extern void spock_checkpoint_hook(...)` declaration in `include/spock_group.h:162`.

### Remove one-liners

- `src/spock.c:1248` — `Checkpoint_hook = spock_checkpoint_hook;`.
- `src/spock.c:1251` — `spock_rmgr_init();`.
- `src/spock_apply.c:1018` — `spock_apply_progress_add_to_wal(&sap);` inside `handle_commit`.
- `src/spock_group.c:682` — `spock_apply_progress_add_to_wal(sap);` inside `spock_group_progress_update_list`.
- `src/spock_group.c:769` — `spock_apply_progress_add_to_wal(sap);` inside `spock_group_progress_force_set_list`.
- `#include "spock_rmgr.h"` in `include/spock_group.h:23`.
- `#include "spock_rmgr.h"` in `src/spock.c:62`.

### Modify

- **`src/spock_apply.c`** — add a new helper `request_initial_status_update(PGconn *conn, XLogRecPtr startpos)` that emits an 'r' message with `replyRequested=true` without touching `send_feedback`'s static state.
- **`src/spock_apply.c:spock_apply_main`** — after `replorigin_session_setup` and before `spock_start_replication`, add phase-2 reconciliation. After `spock_start_replication` returns, call `request_initial_status_update`.
- **`src/spock_group.c:spock_group_progress_force_set_list`** — drop the WAL call; add a single `spock_group_resource_dump()` after the loop.
- **`src/spock_group.c:spock_group_progress_update_list`** — same.

### Keep unchanged

- `src/spock_shmem.c:190-199` — `spock_on_shmem_exit` (clean-shutdown-only dump).
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

**Startup: origin LSN is `InvalidXLogRecPtr`.** Subscription exists but nothing has been applied. Reconciliation treats this as "no origin progress"; keep `resource.dat` value if any, otherwise zero.

**`add_node` retry.** Failed mid-loop leaves shmem partially updated and the file untouched (dump runs only after the loop completes). Second run's unconditional overwrite (`init_progress_fields` then `progress_update_struct`) replaces partial state; dump runs after the loop. Fine.

**`add_node` interrupted after dump.** All entries persisted; re-run is idempotent.

**Multiple apply workers.** Each worker reconciles its own key under the master lock. No cross-worker interference. Forced keepalive is per-connection.

**Post-crash with publisher offline.** `remote_commit_ts` is NULL in `spock.progress` until publisher reconnects and sends a commit. This is the only visible regression versus today (which would show stale-from-last-shutdown values). NULL is intentionally chosen as an honest "unknown" signal.

**Shmem hash full during `force_set_list`.** Warn and continue (existing behavior unchanged). Post-loop dump persists whichever entries made it in.

**Concurrent shutdown during reconciliation.** Worker completes its update under the lock, releases, exits on next `CHECK_FOR_INTERRUPTS`. Shutdown hook dumps resource.dat with the reconciled values. Reconciliation-then-dump cannot leave shmem more stale than the file.

## Testing

### Modified existing tests

- `tests/tap/t/008_rmgr.pl` — rewrites assertions for the new mechanism. "Clean stop → restart → spock.progress preserved" and "crash → correct remote_commit_lsn from origin" assertions remain conceptually, with different internals.

### New tests

1. **Clean shutdown/restart preserves `remote_commit_ts`.** Apply N transactions → clean stop → start → assert `remote_commit_ts` matches pre-shutdown value.
2. **Crash after post-shutdown commits → `remote_commit_ts` NULL.** Clean shutdown → apply transactions → `SIGKILL` → restart → assert `remote_commit_ts` is NULL (stale-detection cleared it), `remote_commit_lsn` matches origin.
3. **Crash during idle → fields NULL until reconnect.** Let subscriber idle with publisher → `SIGKILL` → restart before publisher reconnects → assert only `remote_commit_lsn` populated, others NULL.
4. **Forced keepalive populates within ms.** Set `wal_sender_timeout` high (e.g., 600s) so the timer-driven path is disabled. Start apply worker → assert `remote_insert_lsn` populated within 1 second (proves the forced keepalive, not the timer, produced it).
5. **`add_node` crash-durability.** Run `add_node` → `SIGKILL` before clean shutdown → restart → assert mesh progress entries from `force_set_list` survived (via the post-loop `spock_group_resource_dump`).
6. **No extra WAL flush on commit.** Instrument or count flushes; confirm applied remote-origin commits perform 1 `XLogFlush`, not 2.
7. **`add_node` interrupted mid-loop.** Inject failure between entries → assert `resource.dat` reflects pre-add_node state (no partial dump).
8. **Publisher never responds to forced keepalive.** Block reply path → assert apply worker does not block; values populate on `wal_sender_timeout / 2` cadence.

### Regression safety checks

- `spock.progress` column set unchanged.
- `read_peer_progress()` SQL function output unchanged.
- Downstream tools reading `spock.progress` (spockctrl, monitoring scripts) see no schema or column-type changes.

## Follow-ups (out of scope)

- Best-effort `GetLatestCommitTsData` at startup to recover `remote_commit_ts` for the single globally-latest commit's origin. Low cost, low coverage (helps only one origin per crash). Deferred per user's call.
- Purging `resource.dat` entries that reference subscriptions that no longer exist.
- Removing the obsolete `prev_remote_ts` and `updated_by_decode` fields from the `SpockApplyProgress` struct layout.
