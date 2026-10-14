# 03 — Concurrency Model (Spock @ 69d9228f, branch main)

Focus: processes, shared memory, LWLocks/spinlocks/CVs/atomics, worker
launch/stop races, multi-upstream apply against local writers, sync/apply
handoff, signal handling. All claims below come from code in this tree;
"CLAIM" marks something the code/docs say, which has not been checked.

## 0. Process & shared-state map (what runs concurrently)

Per PostgreSQL instance (one Spock node):

| Process | Entry point | Count | Registered by |
|---|---|---|---|
| supervisor | `spock_supervisor_main` (src/spock.c:903) | 1 static bgworker | postmaster (`_PG_init`) |
| manager | `spock_manager_main` (src/spock_manager.c) | 1 per connectable DB | supervisor, `start_manager_workers` (src/spock.c:787) |
| apply | `spock_apply_main` (src/spock_apply.c:~4680) | 1 per enabled subscription | manager, `manage_apply_workers` (src/spock_manager.c:41) |
| sync | `spock_sync_main` (src/spock_sync.c:1960) | ≤1 running per subscription (`process_syncing_tables`, src/spock_apply.c:4610-4630) | the apply worker (`start_sync_worker`) |
| failover-slots | `spock_failover_slots_main` (src/spock_failover_slots.c:1321) | 1, standbys only | static |
| walsender + output plugin | `spock_output_plugin.c` callbacks | 1 per downstream slot (+ temporary ones for COPY/sync) | peers connecting |
| user backends | SQL functions in src/spock_functions.c (`sub_create`, `sub_drop`, `pause_apply_workers`, `resync_table`, …) | any | — |

All workers are dynamic bgworkers with `BGW_NEVER_RESTART`; restarts are done
by Spock itself (supervisor restarts managers, manager restarts apply,
apply restarts sync). No thread pool, no parallel apply within one worker.
Parallelism comes only from (a) several apply workers (one per upstream)
writing the same local tables at once and (b) local user transactions.

Shared memory (`spock_shmem_startup`, src/spock_shmem.c):

| Structure | Protection | Notes |
|---|---|---|
| `SpockCtx` + `workers[max_worker_processes]` (`SpockWorker` slots) | `SpockCtx->lock` (one LWLock, "spock context lock") | many fields read **without** the lock (see §1) |
| `SpockHash` channel stats (fixed-size HTAB) | `SpockCtx->lock` (SHARED to find, EXCLUSIVE to insert) + per-entry `slock_t mutex` | taken on **every applied row** (`handle_stats_counter`, src/spock_worker.c:930) |
| `exception_log_ptr[max_worker_processes]` (`SpockExceptionLog`) | `SpockCtx->lock` only when claiming a free entry; otherwise unlocked | keyed by **subscription name** |
| `SpockGroupHash` (key dbid,node_id,remote_node_id → `SpockGroupEntry` = progress + `nattached` atomic + `prev_processed_cv`) | `SpockCtx->apply_group_master_lock` (hash created HASH_PARTITION with 16 partitions but all accesses use the one master lock) | persisted to `$PGDATA/spock/resource.dat` |
| `slot_groups[]` (`SpockOutputSlotGroup`) | `slot_group_master_lock` + per-group LWLock | walsender side, "parallel slots" |
| `pause_apply` (pg_atomic_uint32) + `pause_cv` | atomics/CV | instance-wide, not per-DB |

Signals: all Spock workers install `handle_sigterm` (sets `got_SIGTERM`,
`SetLatch`), src/spock_worker.c:84, and `SignalHandlerForConfigReload` for
SIGHUP. So SIGTERM is **cooperative**: it is only noticed where the code
polls `got_SIGTERM`, never inside a heavyweight-lock wait, an LWLock wait,
or a long executor call. `CHECK_FOR_INTERRUPTS()` only acts on
`ProcDiePending`/`QueryCancelPending`, which a Spock SIGTERM does not set.

Latches/wait sets: apply main loop `WaitLatchOrSocket(...,1000ms)`
(src/spock_apply.c:3492); manager `WaitLatch(sleep_timer)`; supervisor
`WaitLatch(180 s)`; sync wait loops `WaitLatch(60 s)`
(`wait_for_sync_status_change`, src/spock_sync.c:2639).

---

## 1. Findings — ranked leads

Each lead: mechanism → why Antithesis can reach it → what to assert.

### F1. Possible undetectable deadlock: apply worker waits on a heavyweight lock while holding `SpockCtx->lock` EXCLUSIVE (HIGH)

`process_syncing_tables` (src/spock_apply.c:4456), SYNCWAIT branch
(~4517-4560):

```
LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE);
worker = spock_sync_find(...);
...
StartTransactionCommand();
set_table_sync_status(...);      /* CatalogTupleUpdate on spock.local_sync_status */
CommitTransactionCommand();
...
LWLockRelease(SpockCtx->lock);
```

A whole catalog transaction (row update, WAL insert, commit fsync) runs
while holding the instance-wide LWLock. `set_table_sync_status`
(src/spock_sync.c:2572) does `CatalogTupleUpdate` → `simple_heap_update`,
which **waits on the xid** of any uncommitted transaction that changed or
deleted the row. LWLock waits cannot be interrupted, and PG's deadlock
detector does not see them.

Concrete cycle:
1. Backend B runs `spock.sub_drop(S)`: `spock_drop_subscription`
   (src/spock_functions.c:762) calls `drop_subscription_sync_status(sub->id)`
   (line 779), which deletes S's `local_sync_status` rows (uncommitted).
2. Apply worker for S reaches the SYNCWAIT branch (a sync worker just
   finished COPY), takes `SpockCtx->lock` EXCLUSIVE, tries to update the
   same row → blocks on B's xid.
3. B continues to "Kill the apply" (line 808): `LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE)` → blocks forever.

Neither side can be cancelled. Every other Spock process then piles up on
`SpockCtx->lock`: every applied row (`handle_stats_counter`; the counter
GUC defaults to on), manager, supervisor, worker attach/detach
(`spock_worker_detach` runs in `before_shmem_exit`, so even clean shutdown
hangs). A similar cycle exists with any backend that holds a transaction
lock on a sync-status row and then reaches `signal_worker_xact_callback`
(src/spock_worker.c:679). That callback takes `SpockCtx->lock` at
`XACT_EVENT_COMMIT`, which runs before the transaction's heavyweight locks
are released.
- Antithesis: run `sub_drop` / `sub_remove_table` / `DROP TABLE` (which
  calls `drop_table_sync_status` via `spock_checkDependency`,
  src/spock_dependency.c:2065) while a table sync is finishing (sub_create
  with sync_data, `sub_resync_table`, zodan add_node).
- Assert: liveness. `sub_drop` returns within a bound. No backend sits in
  wait_event `LWLock:spock context lock` for more than N seconds. A fast
  shutdown finishes.

### F2. Insert-insert race between concurrent writers becomes a "data exception" and, by default, discards the whole remote transaction (HIGH)

`spock_apply_heap_insert` (src/spock_apply_heap.c:837) checks and then
acts, with no retry:
`FindReplTupleInLocalRel` (dirty-snapshot index lookup, waits only for
writers it can already see) → if not found → `ExecSimpleRelationInsert`.
The source has `TODO: do we need a retry finding a tuple?` (line ~874).
If another apply worker (a different upstream) or a local backend inserts
the same key after the lookup, the unique check waits for that writer and
then raises `23505 unique_violation`.

`apply_work`'s PG_CATCH (src/spock_apply.c:3867ff) treats only connection
errors, `40P01` (deadlock), `55P03` (lock timeout) and class `53` as
transient and retries them (commit f3d4935e). `23505` is not on that list,
so it goes down the exception path. The default
`spock.exception_behaviour = transdiscard` (src/spock.c:1144-1150) then
replays the transaction read-only (`begin_replication_step` sets
`transaction_read_only`) and logs every row to `spock.exception_log`. So
**the whole upstream transaction is dropped on this node**, though a
re-lookup would have turned it into a resolvable `insert_exists` decided by
last-update-wins. `sub_disable` mode disables the subscription. The same
holds for an UPDATE whose new key collides with a concurrent insert
(`update_exists`, src/spock_apply_heap.c:740).
- Antithesis: three or more nodes. Write the same PKs concurrently on two
  nodes while a third applies both streams. Add network delay so the two
  streams arrive at the same moment. Also write the same keys locally on
  the receiving node.
- Assert: convergence (every node has the same row set and values once
  quiescent). `spock.exception_log` is empty in a workload that only
  produces resolvable conflicts.

### F3. UPDATE/DELETE "retry" does not wait; out-of-order arrival from different upstreams becomes `update_missing` → TRANSDISCARD (HIGH, design-level)

`spock_apply_heap_update`/`_delete` retry `spock.read_retry_count` (default
5, src/spock.c:181) times and call `wait_for_previous_transaction()`
between tries (src/spock_apply_heap.c:996, 1118). That function returns at
once when `required_commit_ts == 0` (src/spock_apply.c:308). That value is
always 0 unless slot groups are in use, because the walsender sends
`slot_group_last_commit_ts`, which stays 0 (src/spock_output_plugin.c:647).
So the retries re-scan in a tight loop with **no wait**.
- CLAIM (docs/conflict_types.md:98, docs/configuring.md:283): "Spock
  retries the lookup several times (with short waits) in case the row is
  being inserted by a concurrent transaction."
- Example: n2 inserts row R, which reaches n3; n3 updates R; n3's update
  reaches n1 before n2's insert does (different apply workers, different
  links). Result: `update_missing` → `elog(ERROR)` → exception path →
  under TRANSDISCARD all of n3's transaction is dropped on n1, and n2's
  later insert leaves n1 permanently different from n2/n3.
- Antithesis: asymmetric latency or partitions between pairs in a 3-node
  mesh; workload chains insert-on-A → update-on-B.
- Assert: convergence. Also, an `update_missing` exception_log row should
  only appear when the row truly never exists anywhere.

### F4. `pause_apply_workers` / slot-creation pause is instance-wide, not counted per caller, and can time out (HIGH for add_node correctness)

Purpose (src/spock_sync.c:~700-860, `spock_create_slot_and_read_progress`):
pause apply workers on the **provider** so that
`pg_replication_origin_status.remote_lsn` (live, not MVCC) matches the slot
snapshot used for COPY. The resume LSNs read here become the new node's
starting points (`spock_group_progress_force_set_list`). Problems:
- `SpockCtx->pause_apply` is a single global flag
  (src/spock_functions.c:4067, 4138). `resume_apply_workers` sets it to 0
  unconditionally. Two concurrent add_node / sub_create(sync) runs against
  the same provider undo each other's pause, because A's resume opens the
  window B relies on.
- Each paused worker gives up on its own after `spock.pause_timeout` (10 s)
  and **writes 0 globally** (`maybe_pause_for_slot_creation`,
  src/spock_apply.c:565-585). That unpauses everyone while the
  orchestrator may still be inside `CREATE_REPLICATION_SLOT`, which waits
  for running transactions and can take longer than 10 s under load or when
  a transaction is stuck. The orchestrator is not told.
- The comment says "all apply workers in this database", but the flag
  pauses workers in **every database** of the instance.
- The completeness check reads `w->proc->xid` and the plain bool
  `w->worker.apply.paused` with no lock or barrier
  (src/spock_functions.c:4080-4100). A worker that saw the flag as 0 and has
  already started a transaction, but has no xid yet, counts as "paused".
  Snapbuild probably covers this narrow case (the slot waits for running
  xids), but nothing re-checks it.
- If the orchestrator ERRORs or is partitioned between pause and resume,
  the flag stays 1 until each worker's 10 s timeout.
- Result if the window is open: an apply commit lands between the slot
  snapshot and the `ros.remote_lsn` read. The resume LSN then covers a
  transaction the COPY snapshot does not contain, and the **new node never
  receives it** (silent loss on the new node).
- Antithesis: run zodan add_node (or two at once) under steady 3-node
  write load. Add I/O delay or a long-running transaction on the provider
  so slot creation takes longer than `pause_timeout`. Partition the
  orchestrator.
- Assert: after add_node finishes and the cluster is quiet, the new node
  equals the others. Log lines `apply worker pause timed out` should be
  treated as a warning sign.

### F5. Crashed sync worker slot is never cleaned up, so the apply worker can wait forever (MEDIUM-HIGH, liveness)

`spock_worker_detach(crash=true)` (src/spock_worker.c:410) leaves
`worker_type=SYNC` and sets `terminated_at`; only a clean exit resets the
slot to NONE. `wait_for_sync_status_change` (src/spock_sync.c:2639) breaks
out only when `spock_sync_find(...)` returns NULL. A crashed sync slot is
still found (and its `proc` is NULL), so the apply worker, called from
`process_syncing_tables` waiting for SYNCDONE (src/spock_apply.c:~4550),
loops every 60 s **forever**. Only the apply worker restarts sync workers,
and it is the one blocked. Recovery comes only by luck: another
registration in the same DB reuses that slot (`find_empty_worker_slot`
reuses terminated slots with the same dboid), which makes the wait return
false and hit `elog(ERROR, "a table synchronisation operation is failed")`.
- Sync workers in CATCHUP use `apply_work`, so any provider disconnect
  (partition, provider restart, `apply_idle_timeout`) makes them exit with
  an error, which is exactly this case.
- Also: `Assert(spock_worker_running(worker))` at src/spock_apply.c:4532
  fails when the sync worker died while in SYNCWAIT. In a cassert build,
  that **abort makes the postmaster restart every backend on the node**.
  The comment says "suppose that it should be always exist in testing
  environment."
- Restarting a sync whose catalog status is past INIT goes to
  `Assert(sync->stop_on_error)` / FAILED (src/spock_sync.c:1851-1866), so
  the table can end up permanently FAILED after a single network drop.
- Antithesis: partition the provider during table resync catch-up, or
  kill/pause the provider's walsender.
- Assert: `spock.sub_show_table` status eventually reaches `R` (ready) for
  every table. No node restarts every backend because of an assertion
  failure.

### F6. Concurrent writers of `resource.dat` share one temp path; a bad file can stop the node from starting (MEDIUM-HIGH)

`spock_group_resource_dump` (src/spock_group.c:534) always writes
`$PGDATA/spock/resource.dat.tmp` with `O_CREAT|O_TRUNC`, then
`durable_rename`. It is called from several processes with no
inter-process serialization of the file (the LWLock covers only the hash
walk):
- supervisor `before_shmem_exit` (src/spock.c:895),
- every apply worker finishing initial sync
  (`spock_group_progress_force_set_list`, src/spock_sync.c:1736),
- every sync worker finishing COPY (`spock_group_progress_update_list` via
  `copy_tables_data`, src/spock_sync.c:1309).

zodan add_node creates several subscriptions on the new node, and they can
finish initial sync at the same time. Two writers truncating and
interleaving on the same inode give a mixed file. The second writer's
rename fails with ENOENT → `ereport(ERROR)` **after** the COPY committed
(the apply/sync worker errors out at the end of a successful sync).
`spock_group_resource_load` (src/spock_group.c:621) runs in the postmaster
inside `shmem_startup_hook`. A short read or a header count that does not
match (`read_buf` → `ereport(ERROR)`, src/spock_common.c:604) is then
FATAL **at postmaster start**: the node cannot restart until someone
deletes the file. The source asks "XXX: Do we need any kind of CRC here?"
- Antithesis: add_node with several peers, plus a node restart soon after.
- Assert: a node always restarts (reachability). ERRORs with
  `could not rename "…resource.dat.tmp"` never appear.

### F7. Slot-group ("parallel apply") code is still live on main and turns on based on the slot name (MEDIUM; workload hazard)

`spock_output_join_slot_group` (src/spock_output_plugin.c:1281) puts any
walsender whose slot name ends in `_<digit>` into a shared group. In
`pg_decode_begin_txn` (line 535ff), a member **skips** transactions another
member already sent (`slot_group->last_lsn >= txn->end_lsn`). Generated
slot names are `spk_<db>_<provider>_<subname>` (src/spock_functions.c:3666),
so a subscription named e.g. `sub_1` or `n2-1` (`-` becomes `_`) turns this
on. Two different subscribers whose subscription names differ only in the
trailing digit, on the same provider DB, would split one provider's stream
between them, and each would silently miss transactions. The fix
f6887c7a ("Disable parallel apply: reject grouped slot names") sits only on
branch `origin/block-parallel-apply` and is **not an ancestor of HEAD**.
Further concurrency faults in that code:
- `spock_output_leave_slot_group` decrements `nattached` without a lock
  (lock calls commented out, src/spock_output_plugin.c:1376-1381).
- If every group is in use, `free_group` stays NULL and is dereferenced.
- Apply side: `wait_for_previous_transaction` waits for an exact match of
  `prev_remote_ts` (src/spock_apply.c:308), with no timeout. A predecessor
  that is skipped, empty, filtered, or whose commit_ts is not larger than
  the stored one (non-monotonic origin clock: `progress_update_struct` only
  moves forward by `remote_commit_ts`, src/spock_group.c:309) hangs the
  worker forever.
- Antithesis: keep subscription and slot names in the workload free of a
  trailing `_<digit>` unless this feature is the test target. If it is,
  assert that no transactions are lost.

### F8. Exception-log shared entries are keyed by subscription name, shared by the apply and sync workers, and never freed (MEDIUM)

`handle_begin` (src/spock_apply.c:660, 722-830) finds its
`exception_log_ptr[i]` with `namestrcmp(slot_name, MySubscription->name)`:
- The sync worker in CATCHUP runs `apply_work` with the same
  `MySubscription->name` (only `slot_name` changes, src/spock_sync.c:~2000).
  So the apply worker and the sync worker for one subscription read and
  write **the same** `commit_lsn`, `failed_action` and
  `initial_error_message` without a lock. Commit LSNs come from the same
  provider WAL, so a sync-worker failure recorded at LSN Z can make a
  restarted apply worker treat transaction Z as already failed. It then
  replays it read-only, and under TRANSDISCARD/SUB_DISABLE discards it or
  disables the subscription.
- Subscriptions with the same name in two databases of one instance
  collide the same way.
- Entries are never released ("TODO: What happens if a subscription is
  dropped? Memory leak", ~line 798). After `max_worker_processes` distinct
  subscription names, every new apply worker fails with
  `unable to find an empty exception log slot` (a restart loop). Node
  add/remove churn with fresh names reaches this.
- The first search (line 726) reads without the lock. The slot-claim race
  is closed by the second, locked search.

### F9. Manager's worker list is used after `SpockCtx->lock` is released (MEDIUM-LOW)

`manage_apply_workers` (src/spock_manager.c:41) gets `spock_apply_find_all`
pointers under the lock, releases it (line 54), then reads `subid`,
`proc` and `terminated_at`, and finally **SIGTERMs and possibly
clears** every slot left in the list (lines 160-176). Meanwhile an apply
worker in the same DB can call `spock_worker_register` for a sync worker,
which may reuse a terminated apply slot (`find_empty_worker_slot`,
src/spock_worker.c:101). Possible effects: the manager mistakes a sync
worker for an apply worker, SIGTERMs the wrong process (for example a
healthy apply worker, or a sync worker in the middle of COPY), or resets
`worker_type=NONE` on a slot it no longer owns. Related unlocked writes:
`wait_for_worker_startup` sets `worker->terminated_at` without the lock
(src/spock_worker.c:~270), as does the failure path of
`RegisterDynamicBackgroundWorker` (~line 195). Reusing a terminated slot
also erases that worker's `terminated_at`, so the crashed worker loses its
restart backoff (`restart_delay`).

### F10. Other lock/latch observations

- The global `SpockCtx->lock` is taken SHARED once per applied row
  (`handle_stats_counter`), EXCLUSIVE for each new (db,sub,rel) stats key,
  and EXCLUSIVE around catalog transactions (F1). Slow I/O inside F1's
  window stalls apply in every DB.
- `spock_drop_subscription` kills only the **apply** worker
  (src/spock_functions.c:808-836) and waits on a latch loop. Running sync
  workers of the dropped subscription are not killed; they keep their
  remote slots (`<slot>_<hash>`) and local origins. The apply worker
  ignores SIGTERM while blocked on a heavyweight lock (§0), so `sub_drop`
  waits as long as any local transaction blocks the apply worker.
  Restarting the apply worker during that wait is prevented only because
  the manager's `get_local_node(true)` takes ShareUpdateExclusiveLock on
  `spock.local_node` (src/spock_node.c:721), the same lock `sub_drop` holds.
  The side effect is that **all apply-worker (re)starts in that DB stop**
  while any admin function that calls `get_local_node(true, …)` is open
  (src/spock_functions.c:338, 491, 566, 776, 879, 915, 950, 1027, 1058,
  1351; src/spock_sequences.c:200).
- Supervisor: `subscriptions_changed` is set without a latch on manager
  crash (`spock_worker_detach`). Restart therefore relies on the
  postmaster's `bgw_notify_pid` SIGUSR1 to the supervisor (it registered
  the manager). If that is missed, the next attempt comes from the 180 s
  timeout. The flag is cleared without a lock; the comment says this is
  safe.
- `progress_update_struct` keeps the maximum by `remote_commit_ts`, not by
  LSN. If the origin's commit timestamps go backwards (clock skew or step),
  `remote_commit_lsn`, `prev_remote_ts` and `last_updated_ts` in
  `spock.progress` freeze until the clock catches up. zodan reads
  `spock.progress.remote_commit_lsn` as resume_lsn on the new node
  (samples/Z0DAN/zodan.sql:2637-2660; that value comes from force-set, not
  from the max-by-ts merge, so the impact is mainly lag/monitoring). The
  sync worker attaches to the same group entry as the apply worker
  (`apply_work` → `spock_apply_worker_attach`, src/spock_apply.c:3431), so
  its catch-up commits also update the entry.
- `spock.apply_idle_timeout` and `apply_delay` compare against
  `GetCurrentTimestamp()`. A forward clock jump triggers spurious
  reconnects. These are classified as connection errors, so this is safe
  (fixed in 8dcfbcd5).
- Serialization failures (`40001`) are **not** treated as transient. A
  cluster-wide `default_transaction_isolation=repeatable read|serializable`
  makes concurrent local writes send apply into the exception path (the
  comment at src/spock_apply.c:~3955 admits this). Neither is
  `57014 query_canceled` (statement_timeout, or `pg_cancel_backend` on the
  apply worker): with a global `statement_timeout`, a slow apply under
  contention becomes a TRANSDISCARD.
- `spock_apply_heap_delete` counts deletes as `SPOCK_STATS_UPDATE_COUNT`
  (src/spock_apply_heap.c:1083). This is a stats bug only; do not build an
  invariant on delete counters.

---

## 2. Properties worth asserting (concurrency-derived)

1. **Convergence under concurrent multi-upstream writes**: with
   `exception_behaviour` at its default, after the cluster is quiet, every
   node has the same rows. The F2/F3 races are the most likely way this
   breaks.
2. **No silent discards for resolvable conflicts**: any exception_log row
   whose error is 23505 or update_missing, in a workload built to produce
   only resolvable conflicts, is a bug signal (F2/F3).
3. **Admin ops terminate**: `sub_drop`, `sub_resync_table`, `sub_create`
   (with sync) and zodan `add_node`/`remove_node` return or fail within a
   bound. No process waits on `LWLock:spock context lock` for more than N
   seconds (F1, F5).
4. **Node restartability**: a node restarted at any time comes back up
   (F6).
5. **add_node completeness**: the new node equals the others after
   add_node under write load, including when two add_nodes overlap or
   slot creation is slow (F4).
6. **No assertion-failure crashes** in cassert builds (F5's `Assert`,
   `progress_update_struct` asserts at src/spock_group.c:345-360).
7. **Worker table sanity**: at most one live apply worker per
   (db, subid), and at most one live sync worker per subscription
   (checked via `spock.sub_show_status` / `pg_stat_activity`
   `application_name` "spock apply …").

## 3. Ways to steer timing

- Build with `make SPOCK_RANDOM_DELAYS=1` (src/spock_injection.c,
  include/spock_injection.h). This adds random sleeps at worker attach
  (src/spock_worker.c:350), detach (423) and `handle_begin`
  (src/spock_apply.c:668), and in the walsender after BEGIN
  (`SPOCK_OUTPUT_TXN_STALL`). It widens the F1/F5/F9 windows. CI already
  has a workflow for this (a94dec82).
- GUC `spock.output_delay` (ms sleep per transaction in the output plugin;
  src/spock.c:1439) changes the cross-upstream arrival order (F2/F3).
- Lower `spock.pause_timeout` (min?) and `spock.restart_delay_default` to
  make F4 and restart races more frequent.

## Areas examined

src/spock.c (supervisor, `start_manager_workers`, GUCs);
src/spock_worker.c (slot registry, attach/detach, xact callback, stats);
src/spock_manager.c; src/spock_shmem.c; src/spock_group.c;
src/spock_progress_recovery.c; src/spock_apply.c (wait/CV helpers, pause,
handle_begin/commit, exception classification, main loop,
process_syncing_tables); src/spock_apply_heap.c (insert/update/delete,
conflict apply); src/spock_sync.c (cswp slot+pause, sync main,
wait_for_sync_status_change, sync-status catalog);
src/spock_output_plugin.c (slot groups, begin_txn); src/spock_functions.c
(sub_drop, disable, resync, pause/resume, stats);
src/spock_failover_slots.c (lock use, skimmed only); include/*.h for these.
Docs: docs/conflict_types.md, docs/configuring.md. History:
f3d4935e, f6887c7a (not merged), 5afd80e6, bcd61601, dfb3ee49, b743cca8,
c08652c3. samples/Z0DAN/zodan.sql (progress use).

## Assumptions

- The Antithesis build is likely a cassert build. Several leads (F5, the
  progress asserts) differ between assert and non-assert builds.
- `spock_ch_stats` (the channel-counter GUC, src/spock.c:168/1275) is on.
  It defaults to true and gates `handle_stats_counter`.
- One database per instance in the test topology. The cross-DB effects
  (F4 global pause, F8 name collisions) need two or more DBs.
- PostgreSQL's `simple_heap_update` waits on an in-progress updater or
  deleter's xid and only then fails with "tuple concurrently
  updated/deleted". F1 depends on this.
- `XACT_EVENT_COMMIT` callbacks run before heavyweight locks are released
  (standard PG ordering in `CommitTransaction`).

## Open Questions

1. Can F1 actually happen? Does `spock_drop_subscription` ever run while
   the apply worker is in SYNCWAIT handling, or does something serialize
   them (e.g. a lock on `spock.subscription` taken by the apply worker)? I
   found nothing that does.
2. Does snapbuild's wait for running xids fully cover the xid-not-yet-
   assigned window in `pause_apply_workers`, so that F4 depends only on the
   timeout path and on overlapping add_nodes?
3. F5: is there another path (the manager, or `spock.sub_show_table`
   callers) that clears a crashed SYNC slot so the apply worker's wait
   ends?
4. Is the `pause_apply` instance-wide scope intended? Is the
   10 s worker-side self-unpause intended to override an orchestrator that
   is still running?
5. Should 23505 on INSERT (F2) be retried as `insert_exists`, as the
   `TODO` suggests? Is TRANSDISCARD-on-race an accepted limitation?
6. Will slot-group gating (f6887c7a) be merged to main, or should the
   workload just avoid `_<digit>` subscription names?
