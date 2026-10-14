# 08 — Failure and Degradation Modes

SUT: spock @ 69d9228f (main). Focus: what happens between "fully up" and
"fully down": error classification in the apply worker, exception-handling
modes, retry/restart pacing, connection-loss detection, sync-worker failure,
spill files, health reporting.

Line numbers are for `src/spock_apply.c` unless another file is named.

---

## Findings

### F1. The whole apply-worker failure model is one PG_TRY/PG_CATCH that sorts errors by SQLSTATE

`apply_work()` (3398–4160) wraps the receive/apply loop in a single
`PG_TRY`. The `PG_CATCH` (3867–4133) decides what to do in this order:

1. **Connection-class**, then rethrow and the worker exits (3920–3939):
   `08006 CONNECTION_FAILURE`, `08000`, `08003`, `57P01 ADMIN_SHUTDOWN`,
   `57P02 CRASH_SHUTDOWN`, `57P03 CANNOT_CONNECT_NOW`, **or** `PQstatus(applyconn)
   == CONNECTION_BAD`. It calls `clear_transient_exception_state()`, sets
   `restart_delay = restart_delay_default` (5 s), and rethrows.
2. **Deadlock / lock_timeout**, rethrow (3966–3972): `40P01`, `55P03`.
   `prepare_transient_error_retry()` (443–456) does the same bookkeeping.
3. **Class 53** (disk full, OOM, too many connections), rethrow (3988–3992).
4. **SUB_DISABLE**, when `xact_had_exception || use_try_block`:
   `spock_disable_subscription()` and return (4014–4029).
5. **use_try_block && !xact_had_exception** ("error during exception
   handling"): log and rethrow (4041–4048).
6. **Otherwise (first data error)**: `AbortOutOfAnyTransaction()`, save
   `initial_error_message` and `failed_action` into the shmem exception-log
   entry, reset contexts, `apply_replay_queue_start_replay()`,
   `first_begin_at_startup = true`, then `goto stream_replay` with
   `use_try_block = true` (4057–4139). This replays the buffered messages
   **in the same process** under the configured `spock.exception_behaviour`.

Consequence for testing: **any error whose SQLSTATE is not in lists 1–3 is
treated as a permanent data fault.** Under the default
`spock.exception_behaviour = transdiscard` (src/spock.c GUC default
`TRANSDISCARD`), that means the whole remote transaction is logged to
`spock.exception_log` and **dropped**, and the origin is advanced past it
(handle_commit 1002–1009). Under `discard`, the failing rows are dropped.
Under `sub_disable`, the subscription is disabled.

The recent history shows this classification has been wrong several times,
and each mistake meant silent data loss:
- `f3d4935e` "Retry the apply worker's transaction on transient errors":
  40P01/55P03/class 53/57P02/57P03 used to go down the discard path.
- `8dcfbcd5` "Fix spurious apply-idle-timeout misclassification": the idle
  timeout error was untagged `XX000`, so a slow provider caused discard or
  disable.
- `d286f3df` "handle upstream connection loss without origin-advance leak".
- `db380dd8` / `ed0a9945` / `acf6cdae`: a stale shmem `commit_lsn` marker
  made a transaction that was simply retransmitted look like an earlier
  failure.
- Tests: `tests/tap/t/046_apply_worker_exception_misclassification.pl`,
  `035_deadlock_retry.pl`, `036_real_deadlock_retry.pl`,
  `102_no_origin_leak_on_disconnect.pl`,
  `105_sub_disable_retransmit_after_disconnect.pl`,
  `019_stale_fd_epoll_after_conn_death.pl`.

**Errors that are still unclassified (they take the data-fault path) but can be
transient or caused by the environment:**
- `57014 QUERY_CANCELED`. Bgworkers with `BGWORKER_BACKEND_DATABASE_CONNECTION`
  get PG's `StatementCancelHandler` for SIGINT, so `pg_cancel_backend(<apply
  pid>)` (or a fault tool that sends SIGINT) while a transaction is being
  applied → TRANSDISCARD drops a good transaction. (Assumption: spock does not
  override SIGINT; `spock_worker_attach()` only installs a custom SIGTERM
  handler, src/spock_worker.c ~330–356.)
- `40001 SERIALIZATION_FAILURE`: called out in the comment at 3957–3965 as
  possible if `default_transaction_isolation` is cluster-wide RR/SERIALIZABLE.
- `58030 IO_ERROR` and other class 58 errors (e.g. EIO on spill-file write or
  relation extend): not class 53, so they go to the data path.
- `55006 OBJECT_IN_USE` and similar errors from DDL that runs at the same time
  as apply.
- Any `elog(ERROR)` without an errcode (XX000) raised from transient
  infrastructure, e.g. `process_syncing_tables()` →
  `"a table synchronisation operation is failed"` (4566).
- **FATAL never reaches PG_CATCH.** `handle_message()` "incorrect spock
  message" (2928), `replication_handler()` read-only FATAL (2982), and
  `spock_start_replication()` FATAL (src/spock.c ~766). When FATAL happens
  mid-transaction, the shmem `commit_lsn` marker set by `handle_begin()` is
  **not** cleared. The replacement worker sees the retransmitted transaction
  with the same `commit_lsn`, turns on `use_try_block`, and applies the policy
  (TRANSDISCARD discards it; SUB_DISABLE disables). This is the same shape as
  the bugs fixed in `ed0a9945`/`db380dd8`, through a path those fixes don't
  cover. (Only the read-only FATAL and protocol FATAL are reachable
  mid-transaction. The read-only one needs `spock.readonly=all` to change
  between the check at ~3585 and the handler, which is a narrow window.)

**Property to assert:** after any sequence of network faults, process
pause/kill and provider restarts, with no real data conflicts injected,
`spock.exception_log` gets no new rows and no subscription is disabled
(`sub_enabled` stays true). Every committed provider row eventually shows up
on every subscriber. Use `sometimes` assertions on the log lines
`"connection error during apply, exiting via rethrow"`,
`"transient error (deadlock/lock timeout)"`, `"transient resource error"` to
show each retry branch is reached. Use an `unreachable`-style assertion on
`"caught initial exception"` in runs with no injected conflicts.

### F2. DISCARD replay catches *every* error per row, including transient ones

In replay mode (`use_try_block`) under `discard`, `handle_insert/update/delete`
(1657–1690, 1832–1880, ~1960–2010), `handle_truncate` (2188–2230) and
`handle_sql_or_exception` (2790–2815) wrap each operation in a subtransaction
whose `PG_CATCH` swallows **any** error and sets `xact_had_exception = true`.
The transient classification in F1 runs only at the outer catch, on the first
pass. So during a DISCARD replay, a deadlock against a local user transaction
(40P01), lock_timeout, OOM, disk full or query cancel on row *k* **discards
row k for good**, and `handle_commit` advances the origin anyway (DISCARD
always advances, 1002–1009). Getting there needs one real data error in the
transaction first, then a transient fault during the replay. That ordering is
plausible under Antithesis with a conflicting local workload.

### F3. TRANSDISCARD / SUB_DISABLE never re-execute the transaction

In replay mode with TRANSDISCARD/SUB_DISABLE, `begin_replication_step()` sets
`transaction_read_only=on` (620–631) and every DML/DDL is **skipped**. It is
only logged to `spock.exception_log` (`exception_log` is a user_catalog_table,
so `CatalogTupleInsert` still works). The decision to discard rests entirely
on the single first-pass error. Any misclassified transient error from F1 is
therefore final: there is no second attempt.

`handle_commit()` under SUB_DISABLE replay sets the origin to the BEGIN
`commit_lsn` rather than `end_lsn` (996–1009), commits the exception-log rows,
then `elog(ERROR)` (1067–1085). The PG_CATCH then disables the subscription in
a new transaction. The claim (docs/configuring.md:172–180) is that on
re-enable "replication will resume with the transaction that caused the
exception". This relies on logical decoding not skipping a transaction whose
commit record starts exactly at the restart LSN
(`SnapBuildXactNeedsSkip`: `ptr < start_decoding_at`).

### F4. First-pass data error: origin is advanced by the abort record before replay finishes

The first-exception branch calls `AbortOutOfAnyTransaction()` (4065) while
`replorigin_session_origin`/`_lsn` are still set (`handle_begin()` set
`_lsn = commit_lsn`). In PG18, `RecordTransactionAbort()` calls
`replorigin_session_advance(replorigin_session_origin_lsn, ...)` and writes
origin info into the abort record. If the failed transaction got an XID,
the origin moves to the failing transaction's `commit_lsn`, and the move is
durable through redo (`xact_redo_abort` → `replorigin_advance`). This happens
before the in-process replay has committed anything.

The connection-error path (d286f3df) works hard to avoid this, and the
comments at 3884–3897 and in `spock_apply_worker_shmem_exit()` (2305–2325)
say that an abort-time advance "silently skips that txn on reconnect". The
replay path does the same thing on purpose. Either the comment overstates the
risk (resuming at exactly `commit_lsn` re-sends the transaction because the
skip test is strict `<`), or a crash or kill during replay (before its commit)
loses the transaction. **Open question; worth a targeted Antithesis
scenario:** a constraint-violation transaction, then kill the subscriber
postmaster during replay, then check whether the transaction ends up applied
or in the exception log.

### F5. Shared-memory exception-log slots: never freed, and running out causes an out-of-bounds write plus a self-deadlock

`exception_log_ptr` is an array of `max_worker_processes` entries
(src/spock_worker.c:794–797, 872–880), keyed by **subscription name**. Entries
are claimed in `handle_begin()` (722–826) and **never released** ("TODO: What
happens if a subscription is dropped? Memory leak", 798–800). After
`max_worker_processes` distinct subscription names in one postmaster lifetime:
- `handle_begin()` raises `elog(ERROR, "unable to find an empty exception log
  slot")` (793) **while holding `SpockCtx->lock` LW_EXCLUSIVE** (taken at 762).
- No transaction is open, so `AbortOutOfAnyTransaction()` in PG_CATCH does
  nothing (PG18 xact.c ~4907: "Not in a transaction, do nothing") and **the
  LWLock is not released**.
- PG_CATCH then runs
  `snprintf(exception_log_ptr[my_exception_log_index]...)` with
  `my_exception_log_index == -1` (4077–4096). That is an **out-of-bounds write
  into shared memory** in front of the array.
- `goto stream_replay`, then the next `handle_begin()` calls
  `LWLockAcquire(SpockCtx->lock)` again. That is a self-deadlock. After that,
  the manager (`manage_apply_workers`), `sub_show_status`, worker
  attach/detach, and anything else that takes `SpockCtx->lock` hang
  node-wide.

Antithesis relevance: workloads that create and drop subscriptions with
**new** names (add/remove node cycles that make up unique names) will hit
this. Names that get reused (`sub_n1_n2`) reuse the slot. A sync worker uses
the *same* entry as its apply worker, because it looks it up by
`MySubscription->name` (only `slot_name` changes, 2004–2008 in spock_sync.c),
so two processes write one entry without a lock. In practice they run one
after the other (the apply worker is blocked in `wait_for_sync_status_change`).

### F6. Initial subscription sync: a transient failure becomes permanent disablement

`spock_sync_subscription()` (src/spock_sync.c:1488–1812):
- Statuses `INIT` and `CATCHUP` can be recovered after a crash. **Any other
  persisted status (`s` STRUCTURE, `d` DATA, `c` CONSTRAINTS) → the default
  branch forces `exception_behaviour = SUB_DISABLE`, disables the
  subscription, and raises FATAL "initialization failed during nonrecoverable
  step"** (1520–1548).
- The status is set to `d` before `copy_replication_sets_data()` (1716–1721).
  A network partition, provider restart or subscriber kill during COPY
  therefore needs an operator to recover. `PG_ENSURE_ERROR_CLEANUP` (1659)
  drops the remote slot and the local origin on ERROR, but **not** on SIGKILL
  or postmaster crash. The cleanup callback itself opens a new connection to
  the provider (`spock_sync_worker_cleanup`, 1429–1467), so during a partition
  it fails too and the slot leaks on the provider (WAL retention).
- The pre-slot step `spock_create_slot_and_read_progress()` (650–866) calls
  `spock.pause_apply_workers()` on the **provider**. If the sync worker or the
  connection dies before `resume_apply_workers()`, the provider's apply
  workers stay paused until `spock.pause_timeout` (default 10 s) runs out and
  each worker clears the global flag itself (`maybe_pause_for_slot_creation`,
  557–581).

### F7. Pause/resume for add_node: when the timeout fires, the "exact progress" claim breaks

`spock_pause_apply_workers()` (src/spock_functions.c:4060–4126) claims that
afterwards `pg_replication_origin_status` "reflects only committed state".
Weak points:
- It treats a worker as paused if `w->proc->xid` is invalid. An apply worker
  that has started its local transaction but has not yet written (no XID yet)
  counts as paused. It can then write and commit between
  `CREATE_REPLICATION_SLOT` (snapshot) and the progress read, so the progress
  LSN covers a transaction that is not in the COPY snapshot.
- On the **worker** side, `spock.pause_timeout` (10 s) also auto-resumes:
  `maybe_pause_for_slot_creation()` writes `pause_apply=0` and keeps going.
  `CREATE_REPLICATION_SLOT` waits for every running XID to finish, so a long
  user transaction or a paused (SIGSTOP) process on the provider pushes
  capture past 10 s. Workers then resume in the middle of the capture.
- `pause_apply` is one global flag across all databases and all concurrent
  add_node operations. One caller's resume clears another's pause.

Possible result: the new node's origin for a third peer is ahead of its copied
data, so it never receives some rows. (This overlaps the ZODAN focus; it is
listed here because it is a fallback that kicks in on timeout.)

### F8. Table-level sync (sub_resync_table / sub_add_table): a transient failure marks the table FAILED and silently stops replicating it

- `spock_sync_table()` (src/spock_sync.c:1816–1920): if the status is not
  `INIT` on entry (for example `STARTED`/`DATA` left by a sync worker that was
  killed or lost its connection), it sets **`SYNC_STATUS_FAILED`** and
  returns. There is no retry (1851–1867).
- The apply worker's `should_apply_changes_for_rel()` (465–484) **skips all
  changes** for any table whose status is not READY (or SYNCDONE at or below
  the origin LSN). A FAILED table therefore stops receiving replicated changes
  for good, and the origin keeps advancing past those changes.
  `process_syncing_tables()` ignores FAILED tables (4507–4514, 4594–4597).
- Health reporting hides this. `sync_status_to_string()`
  (src/spock_functions.c:1358–1381) has no case for `'f'` (FAILED) or `'p'`
  (STARTED), so `spock.sub_show_table` prints **"unknown"**, and
  `sub_show_status` still says "replicating" (only the subscription-level
  status is checked).
- SYNCWAIT handling: `Assert(spock_worker_running(worker))` (4532) fires if
  the sync worker died. On a cassert build the apply worker aborts, which
  restarts the whole postmaster. On a production build, the
  `wait_for_sync_status_change()` loop (src/spock_sync.c:2639–2693) uses
  `spock_sync_find()`. That function does **not** check `terminated_at`, so a
  sync worker that crashed (worker_type still SYNC, `terminated_at != 0`) still
  counts as alive. The **apply worker can then block in 60 s WaitLatch loops
  indefinitely**: it stops reading the stream, the provider's
  `wal_sender_timeout` closes the connection, and the subscription is stuck
  until the slot is reused. `sub_show_status` still reports "replicating"
  throughout.

### F9. Connection-loss detection: real worst-case latency is apply_idle_timeout (300 s), not keepalives

- Keepalive settings are hard-coded in `spock_connect_base()`
  (src/spock.c:366–475): `connect_timeout=30, keepalives=1,
  keepalives_idle=10, keepalives_interval=5, keepalives_count=3`. They come
  after the expanded `dbname` entry, so they **override** anything in the
  subscription DSN. `tcp_user_timeout` is not set.
- **`spock.extra_connection_options` is not used at all.** It is appended to
  StringInfo `s`, which only appears in the `errdetail` of a failed connect.
  It is never passed to `PQconnectdbParams`. docs/configuring.md (~218–228)
  says it applies to all connections and can set or disable keepalives. That
  claim is false in the code. The failover-slots connector
  (src/spock_failover_slots.c:488–535) has its own hard-coded values (20/20/5)
  and ignores the GUC too.
- During a silent partition (packets dropped, no RST), the apply worker keeps
  sending feedback. Unacknowledged data in the send queue stops keepalive
  probes, and without `tcp_user_timeout` the kernel retransmit timeout (~15
  min) applies. In practice the detector is `spock.apply_idle_timeout`
  (default 300 s, 3548–3563): if no data arrives for that long it raises
  ERROR 08006, then the worker rethrows and restarts. The provider walsender
  relies on `wal_sender_timeout` (docs recommend 5 min). **Liveness properties
  in Antithesis must allow at least 300 s + restart_delay (5 s) to recover
  after a partition heals, or the workload should lower
  `spock.apply_idle_timeout`.**
- The stale-fd / epoll_ctl(EINVAL) cascade is fixed by refreshing
  `PQsocket()` each iteration (3443–3485; commits 4dfe7496, d286f3df). At the
  `stream_replay:` label a dead connection makes `apply_work()` return quietly
  (3449–3454), which leads to proc_exit(0), a "clean" detach, and a normal
  restart by the manager.
- Blocking libpq calls with no timeout: `IDENTIFY_SYSTEM`/`START_REPLICATION`
  (`PQexec`, src/spock.c ~626/763) and all sync-path `PQexec`/COPY calls in
  spock_sync.c / spock_rpc.c. A partition right after TCP connect leaves the
  worker stuck in libpq until the TCP timeout. Spock's SIGTERM handler only
  sets `got_SIGTERM`, so `sub_disable`/`sub_drop`/`sub_alter_options` cannot
  stop such a worker quickly.
- A reconnect while the old walsender still holds the slot leads to
  START_REPLICATION failing with FATAL and a restart every
  `restart_delay_default` until the old walsender times out. That is
  degraded, not broken.

### F10. Restart pacing and the manager loop

- Apply workers are dynamic bgworkers with `BGW_NEVER_RESTART`
  (src/spock_worker.c:195). Restarts come from `manage_apply_workers()`
  (src/spock_manager.c:40–186) using `terminated_at + restart_delay`. The
  floor is `SPOCK_RESTART_MIN_DELAY` = **1 ms** (include/spock.h:38).
- `handle_begin()` sets `restart_delay = restart_delay_on_exception`
  (**default 0**, PGC_POSTMASTER) on every BEGIN (680). Retry branches
  (connection, transient, replay-entry) set it back to
  `restart_delay_default` (5 s). Paths that exit *without* going through
  them, such as FATALs inside the apply loop or errors after BEGIN that escape
  some other way, restart almost immediately. Commit f3d4935e measured 141
  restarts, peaking at 83 in one second, before pacing was added.
- On a clean exit (proc_exit(0): SIGTERM, the SUB_DISABLE return, a dead
  connection at `stream_replay:`) the slot is freed (worker_type=NONE). The
  manager's latch is **not** set, so the restart waits for the manager's next
  wake-up (up to `restart_delay_default`).
- A hard crash of any spock worker (SIGKILL, segfault, Assert) makes the
  postmaster do a full crash-restart. **All shmem state is lost:** exception-log
  markers, `pause_apply`, slot-group state, `SpockCtx->workers`, and the group
  progress hash (reloaded from `PGDATA/spock/resource.dat` plus a
  reconcile step; see the header comment of src/spock_group.c). Killing a
  process in Antithesis therefore exercises the "everything lost" path, not
  the "worker restarted" path. Both paths need coverage: kill the postmaster
  versus SIGTERM a single worker or `pg_terminate_backend`.

### F11. Spill files for the replay queue

- The in-memory replay queue holds every message of the current transaction.
  Past `spock.exception_replay_queue_size` (default **4 MB**, 0 = unlimited)
  it spills to `BufFileCreateTemp(true)` (5032–5121). Docs call the GUC
  DEPRECATED, but it is still active.
- Spill write: the counter goes up before writing, so a short write leaves
  `count >` the records on disk. On read, a corrupt or short record raises
  `elog(ERROR, "corrupt replay spill file")` (4876–4927) with no errcode
  (XX000). On the first pass that sends the transaction down the
  data-exception path. During replay it ends up "error during exception
  handling", rethrow, restart.
- A disk-full (ENOSPC → 53100) during a spill write on the first pass is
  transient and retried. EIO (58030) is not, and goes to the discard/disable
  path.
- The queue is reset only in `handle_commit()` via
  `apply_replay_queue_reset()` (4935–4966). If the worker exits mid-replay,
  the temp file goes away when the process ends.
- Large transactions over 4 MB are common in a stress workload. The
  spill-to-disk code is marked "XXX: keep DEBUG1 logging until spill-to-disk
  code is proven stable" (several places), so treat it as not well proven.

### F12. SUB_DISABLE edge: disabling inside an open apply transaction is rolled back

After the inner loop, `if (xact_had_exception && exception_behaviour ==
SUB_DISABLE)` calls `spock_disable_subscription()` and then `return` (3807–3826).
Under SUB_DISABLE, `xact_had_exception` is set during replay only on the
"Spock can't find relation" paths (1590–1610 etc.). If the inner loop stops
in the middle of a transaction (no more data buffered yet), a remote
transaction is still open. `spock_disable_subscription()`
(src/spock_exception_handler.c:232–276) writes into **that** transaction
because `IsTransactionState()` is true. Then `apply_work` returns, and
`spock_apply_main` runs `PQfinish` and `proc_exit(0)`. ShutdownPostgres
aborts the open transaction, so both the disable and the exception-log row
are **rolled back**. The worker exits cleanly, the manager restarts it, it
enters replay again, and the loop repeats. Only reachable with a
missing-relation transaction that arrives in more than one network read.
(Release notes ~474 say "SUB_DISABLE now exits cleanly" for the missing
relation case, so check test `016_sub_disable_missing_relation.pl`. It may
only cover the single-read case.)

### F13. Unbounded waits inside the apply worker

- `wait_for_previous_transaction()` (300–336) spins on a 1 ms CV sleep until
  `prev_remote_ts == required_commit_ts`, with **no timeout**. It only matters
  for slot groups (slot name ending `_<digit>`;
  src/spock_output_plugin.c:1280–1360), which normal deployments do not use.
  If commit-order state is lost (provider walsender restart resets
  `slot_group->last_commit_ts`; subscriber shmem resets) the worker can spin
  forever. Called from handle_commit, handle_sql_or_exception, and the heap
  update/delete retry loops.
- `spock_apply_heap_update/delete` retry "row not found"
  `spock.read_retry_count` times (default 5) with
  `wait_for_previous_transaction()` between tries and no sleep or backoff
  otherwise (src/spock_apply_heap.c:982–999, 1104–1121). It then raises a
  plain ERROR (XX000) "did not find row to be updated", which goes to the
  data-exception path. In a 3+ node mesh where a row's INSERT reaches a node
  late through another path (normal under partitions), an UPDATE that arrives
  first is **discarded under TRANSDISCARD**. This is designed behaviour, but
  it is a big source of divergence under fault injection.
- `find tuple / table_tuple_lock` in src/spock_common.c:438–481 does
  `goto retry` on TM_Updated/TM_Deleted with no limit and no backoff. That is
  fine for liveness only while the contention eventually stops.
- Mid-transaction `spock.readonly = all`: the inner loop `break`s
  (3585–3608) and the open remote transaction holds its locks until
  `apply_idle_timeout` fires (300 s), then reconnects.

### F14. Health reporting does not show degraded states

`spock.sub_show_status` (src/spock_functions.c:1437–1540) reports:
- `replicating`: the worker slot has `proc != NULL` and is not terminated,
  **and** subscription sync is READY. It does not check the connection or
  progress. A worker stuck in `wait_for_sync_status_change` (F8), in blocking
  libpq (F9), paused (F7), in `wait_for_previous_transaction` (F13), or
  restarting in a fast loop between attaches all show "replicating" or flip
  between "down" and "replicating".
- `down`: enabled but no running worker, which includes the gap of up to 5 s
  between restarts.
- `disabled`: SUB_DISABLE fired or an operator disabled it.
- `initializing`: subscription-level sync is not READY. Per-table FAILED
  shows as "unknown" (F8).
`get_apply_worker_status()` (src/spock_functions.c:4380–4460) exposes
`worker_status` (RUNNING/STOPPED), which is set before each wait and on error.
Lag views (`spock.progress`, `lag_tracker`) come from in-memory group progress
updated after each commit. They are **not** in the same WAL record as the
commit: `spock_group_progress_update_ptr` runs after
`CommitTransactionCommand` (1170). The persisted copy is
`resource.dat` + reconcile.

**Workload guidance:** do not treat `sub_show_status = replicating` as
"caught up". Use `spock.wait_for_sync_event` or row-count/checksum
convergence with a timeout of at least `apply_idle_timeout`.

---

## Areas examined

- `src/spock_apply.c`: apply_work, the PG_CATCH discriminator, handle_begin,
  handle_commit, exception-log marker logic, replay queue and spill, feedback
  (`send_feedback`, `get_flush_position`, sync-standby hold),
  process_syncing_tables, spock_apply_main, shmem-exit callbacks,
  wait_for_previous_transaction, maybe_pause_for_slot_creation.
- `src/spock_exception_handler.c`: add_entry_to_exception_log,
  spock_disable_subscription.
- `src/spock_manager.c`, `src/spock_worker.c`: restart pacing, slot reuse,
  crash detection, `spock_sync_find`.
- `src/spock_sync.c`: spock_sync_subscription, spock_sync_table,
  spock_sync_main, cleanup callbacks, pause/slot creation,
  wait_for_sync_status_change.
- `src/spock_functions.c`: pause/resume_apply_workers,
  show_subscription_status/table, sync_status_to_string.
- `src/spock.c`: GUC defaults, `spock_connect_base` (keepalives,
  extra_connection_options), START_REPLICATION error path.
- `src/spock_apply_heap.c`: read_retry_count loops. `src/spock_common.c`:
  tuple-lock retry.
- `src/spock_output_plugin.c`: slot groups / commit order,
  SPOCK_OUTPUT_TXN_STALL.
- `include/spock_injection.h`, `src/spock_injection.c`: `SPOCK_RANDOM_DELAYS`
  build flag (random 1–100 ms delays at worker start/finish and after the
  provider-side BEGIN) and `USE_INJECTION_POINTS` names `spock-worker-delay`,
  `spock-output-txn-stall`. Both are useful hooks for Antithesis.
- docs/configuring.md (exception_behaviour, extra_connection_options,
  wal_sender_timeout, apply_idle_timeout), release notes.
- git history: f3d4935e, 8dcfbcd5, ed0a9945, db380dd8, d286f3df, acf6cdae,
  4dfe7496, a4b93e87, 8f64833d, 162dc562.
- PG18 core `xact.c` (RecordTransactionAbort / AbortOutOfAnyTransaction) and
  `snapbuild.c` (`SnapBuildXactNeedsSkip`), read **from a local PG source
  copy** only to check what spock's comments assume. Not part of the SUT.

Not examined in depth: `spock_failover_slots.c` worker error loop,
output-plugin-side error handling, autoddl failure paths,
`spock_progress_recovery.c` reconcile logic (other agents' areas).

## Assumptions

- PG bgworkers with a DB connection use `StatementCancelHandler` for SIGINT,
  and spock does not override it (only SIGTERM is customised), so
  `pg_cancel_backend` produces 57014 inside the apply loop.
- `statement_timeout` / `idle_in_transaction_session_timeout` do not apply to
  bgworkers (enabled only in the PostgresMain command loop), so they are not
  sources of 57014/FATAL here.
- libpq: later entries in the keyword array override values expanded from
  `dbname`, so the hard-coded keepalives win over DSN settings.
- With the Antithesis default of killing processes, killing one spock worker
  leads to a postmaster crash-restart (`restart_after_crash=on`), which wipes
  shmem.
- `max_worker_processes` sets the number of exception-log slots.

## Open Questions

1. F4: does the abort-record origin advance in the first-exception replay
   path ever lose the transaction if the node crashes during replay? The
   comments in the connection path say yes; the strict `<` skip test in
   decoding suggests no. A targeted scenario would settle it.
2. F1: should 57014 (cancel), 40001, class 58 and FATAL-mid-transaction be
   classified as transient? Today they can silently discard data under the
   default TRANSDISCARD.
3. F5: confirm the self-deadlock on `SpockCtx->lock` after the
   exception-log slots run out. Is there anything that releases LWLocks
   between the PG_CATCH and the next `handle_begin`? None found.
4. F8: is there any automatic recovery from `SYNC_STATUS_FAILED`, or from a
   sync worker that crashed in SYNCWAIT/CATCHUP? None found. The code has TODOs
   at 4524–4531 and 4567–4571.
5. F7: is `spock.pause_timeout` auto-resume during slot capture expected to
   be safe? Nothing re-checks that capture finished inside the pause.
6. F9: is ignoring `spock.extra_connection_options` intended (dead GUC), or a
   regression? `git log -S` shows only renames and cleanup commits touching it.
7. Does `016_sub_disable_missing_relation.pl` cover the case where a
   transaction arrives in more than one network read (F12)?
