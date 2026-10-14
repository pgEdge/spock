# 05 — Liveness Guarantees (Spock)

Focus: progress properties Spock claims or relies on ("eventually reconnects",
"manager restarts dead workers", "sync completes", "add_node completes or fails
cleanly"), the timeouts and retry constants that bound them, and places where
progress is unbounded, waits on a human, or depends on the wall clock.

Everything below is a **claim or code fact, not a verified guarantee**.
File:line refers to HEAD 69d9228f.

---

## Findings

### L1. Process supervision tree and restart pacing

| Process | Who restarts it | Delay / bound | Where |
|---|---|---|---|
| `spock supervisor` (static bgworker) | postmaster | `bgw_restart_time = 5` s | src/spock.c:1516 |
| `spock manager <dboid>` (dynamic, `BGW_NEVER_RESTART`) | supervisor, when `SpockCtx->subscriptions_changed` is set | **no delay**; supervisor otherwise sleeps 180 s (`WaitLatch(..., 180000L)`) | src/spock.c:938-960, src/spock_worker.c:455-462 |
| `spock apply <db>:<subid>` (dynamic, `BGW_NEVER_RESTART`) | manager `manage_apply_workers()` | `terminated_at + restart_delay` (ms) | src/spock_manager.c:103-131 |
| `spock sync ...` (per-table copy) | apply worker `process_syncing_tables()` launches one at a time | runs each time the apply loop goes round outside a transaction | src/spock_apply.c:4588-4614 |
| `spock_failover_slots worker` (PG15–17 only) | postmaster | `bgw_restart_time = 60` s | src/spock_failover_slots.c:1940-1950 |

- Crash reporting: `spock_worker_detach(crash)` (src/spock_worker.c:410-480)
  stamps `terminated_at = GetCurrentTimestamp()` and, for an apply/sync worker,
  `SetLatch`es the manager. For a manager it sets `subscriptions_changed = true`
  so the supervisor re-runs `start_manager_workers()`.
  Comment (src/spock_worker.c:440-446): "The crash logic only works because all
  of the workers are attached to shmem and the serious crashes that we can't
  catch here cause postmaster to restart whole server". **A SIGKILL of any
  spock worker is therefore a whole-instance crash-restart.** That is a
  separate liveness path from the `terminated_at` one, and Antithesis
  process-kill will exercise it.
- A worker that dies before it attaches to shmem: `wait_for_worker_startup()`
  marks `terminated_at` using the generation counter (src/spock_worker.c:240-290).
- Manager loop: `manage_apply_workers()` returns the smallest pending restart
  delay, never more than `restart_delay_default`, and never less than
  `SPOCK_RESTART_MIN_DELAY` = 1 ms (include/spock.h:38, src/spock_manager.c:179-182).
  So the manager wakes at least every `spock.restart_delay_default` (5000 ms
  default, `PGC_POSTMASTER`, src/spock.c:1327-1338).
- Which `restart_delay` gets used depends on the code path:
  - At registration: `restart_delay_default` (src/spock_worker.c:158). This
    paces initial connect failures, for example a provider that cannot be
    reached at all.
  - Once the first BEGIN arrives (`handle_begin`): `restart_delay_on_exception`,
    **default 0** (src/spock_apply.c:670-676, GUC src/spock.c:1340-1351).
  - Connection-class, deadlock / lock-timeout and class-53 errors are reset to
    `restart_delay_default` (src/spock_apply.c:3938, 448-452). Commit
    f3d4935e: "To stop that becoming a hot loop, every retry branch ... now sets
    restart_delay to spock.restart_delay_default (5s)".
  - After an exception has been handled, `restart_delay = 0` again
    (src/spock_apply.c:954, 1049, 1081). An error inside exception handling
    resets it to the default (src/spock_apply.c:840-845).
  - **Lead:** any ERROR that is not classified (a data fault outside
    `use_try_block`, or a FATAL such as the readonly check in
    `replication_handler`, src/spock_apply.c:2999-3001) restarts the worker
    after only 1 ms. That is a tight respawn loop by design.
- `spock_worker_register()` failure (no free spock slot, or
  `RegisterDynamicBackgroundWorker` fails with `max_worker_processes`
  exhausted) raises ERROR **inside the manager**, so the manager crashes and
  the supervisor respawns it with no delay (src/spock_worker.c:136-141,
  197-203). Possible hot loop when worker slots run out.

### L2. Apply worker: reconnect after network loss (claimed)

Claims:
- docs/spock_release_notes.md:603-610 (5.0.7): "The apply worker now exits
  cleanly when the upstream connection dies (firewall reload, walsender
  SIGKILL/RST, walsender ping timeout) and the manager respawns it from the
  last durably-committed remote LSN."
- docs/logical_slot_failover.md:310: "Subscribers reconnect automatically."
- docs/internals-doc/OUTPUT.md:33-37: "If the client disconnects or crashes it
  can reconnect and resume replay from the last message that client processed."

How the code detects a dead or stuck connection (src/spock_apply.c:3397-3570):
1. `PQstatus == CONNECTION_BAD` / `PQsocket == PGINVALID_SOCKET` at the top of
   each loop raises `ERRCODE_CONNECTION_FAILURE`.
2. TCP keepalives on every peer connection, hard-coded in `spock_connect_base`
   (src/spock.c:399-413): `connect_timeout=30`, `keepalives=1`,
   `keepalives_idle=10`, `keepalives_interval=5`, `keepalives_count=3`. A
   silent peer is detected about 25 s after the link goes idle. These can be
   overridden through `spock.extra_connection_options`, which is prepended so
   later keys win (src/spock.c:1263-1270, 380-382). **No `tcp_user_timeout`.**
   When data is unacknowledged, keepalives do not fire and the kernel's
   `tcp_retries2` (about 15 min) applies instead.
3. `spock.apply_idle_timeout` (default 300 s, `PGC_SIGHUP`, 0 disables;
   src/spock.c:1461-1475). The check is at src/spock_apply.c:3548-3563.
   `last_receive_timestamp` is updated only when `PQgetCopyData` returns
   `r > 0` (src/spock_apply.c:3676-3682), so any message counts, including
   `'k'` keepalives. GUC text: "Safety net for detecting a hung walsender that
   keeps the TCP connection alive but stops sending data."
   - **This is the only thing that catches a SIGSTOP-paused provider.** The
     peer kernel still ACKs keepalives, so detection takes up to 300 s, plus
     the walsender's `wal_sender_timeout` on its side.
   - Fix 8dcfbcd5: the idle-timeout error used to be untagged and was
     misclassified as a data fault, which disabled or discarded the
     subscription. It is now `ERRCODE_CONNECTION_FAILURE`. This is a
     regression target: a slow provider must not cause SUB_DISABLE.
4. `PG_CATCH` classifier (src/spock_apply.c:3870-3942): codes
   08006/08000/08003/57P01/57P02/57P03, or `PQstatus == CONNECTION_BAD`,
   lead to `clear_transient_exception_state()`,
   `restart_delay = restart_delay_default`, and `PG_RE_THROW`. The rethrow
   aborts without advancing the origin. The comment says the respawned worker
   "resumes from the last durably-committed origin LSN and re-streams the
   aborted txn". 57P04 (database dropped) and 08P01 (protocol violation) are
   **deliberately excluded**, because they "would then retry forever".
5. Deadlock (40P01) and `lock_not_available` (55P03) on the subscriber are
   retried **without limit** at 5 s intervals (src/spock_apply.c:3945-3975):
   "Retry is INDEFINITE ... contention that never clears surfaces as a
   restarting worker". Class 53 (disk full, OOM, too many connections) is
   handled the same way (src/spock_apply.c:3977-3996). Serialization failure
   40001 is **not** retried. It goes down the exception path, which can
   discard data.
6. On (re)connect, `request_initial_status_update()` sends `'r'` with
   `replyRequested=1` so lag stats refresh without waiting for
   `wal_sender_timeout/2` (src/spock_apply.c:3327-3376). Test
   023_forced_keepalive_timing.pl.

Expected liveness property: after any network partition, packet-drop window
or provider restart ends, each enabled subscription returns to `replicating`
within roughly `restart_delay_default + connect_timeout + 25 s keepalive`, or
`apply_idle_timeout` for a hung peer. All rows committed during the outage
then arrive, with no spurious `spock.exception_log` rows and no
`sub_enabled=false`. TAP tests 101, 102, 104 and 105 assert this for single
blips. Antithesis can stress repeated and mid-transaction blips.

Ways a subscription stops making progress without crashing:
- **Apply blocked on a local lock with no `lock_timeout`.** The apply
  transaction waits as long as the local session does. While it waits it
  sends no feedback. The provider's walsender eventually hits
  `wal_sender_timeout` and drops the connection, but the apply worker only
  notices once the lock is granted. Docs (docs/configuring.md:227-241)
  recommend `wal_sender_timeout = '5min'` because the default 60 s "can cause
  spurious disconnects when the subscriber is busy applying a large
  transaction".
- **`spock.readonly = all`.** The inner loop `break`s before reading
  (src/spock_apply.c:3610-3631), so no data is received and
  `apply_idle_timeout` fires every 300 s, causing a reconnect loop.
  `replication_handler()` FATALs if a message gets through
  (src/spock_apply.c:2999-3001). Progress stops by design. It must resume
  once readonly is turned off.
- **Pause for slot creation** (L5): bounded by `spock.pause_timeout`.

### L3. Exception handling turns liveness into a human-intervention problem

- `spock.exception_behaviour` defaults to `TRANSDISCARD`
  (src/spock_exception_handler.c:78). With `SUB_DISABLE`, a data fault
  disables the subscription (`spock_disable_subscription`,
  src/spock_apply.c:3785-3800, 4021-4036) and replication from that origin
  **never resumes without an operator**.
- Liveness hazard tied to safety: any *transient* condition that gets
  misclassified as a data fault wrongly kills progress under SUB_DISABLE.
  Past instances:
  - 8dcfbcd5: idle-timeout misclassification.
  - ed0a9945: a stale `exception_log->commit_lsn` after a clean SIGTERM made
    the retransmitted transaction look like a prior failure, and the
    subscription was disabled.
  - db380dd8: SUB_DISABLE reconnect retransmission.
  - docs/spock_release_notes.md:535-538: "a transient provider connection loss
    could incorrectly disable a subscription under SUB_DISABLE".

  Test 046_apply_worker_exception_misclassification.pl covers this.
  Antithesis property: **a subscription is never disabled unless a genuine
  data fault was injected**.
- The in-process replay spill file is checked for corruption. A short read
  raises ERROR, which "triggers a clean worker restart"
  (src/spock_apply.c:4840-4856, 4874-4900).

### L4. Initial subscription sync and per-table sync: do not eventually complete after an interruption

- `spock_sync_subscription()` (src/spock_sync.c:1488-1560) handles the
  subscription status as follows:
  - `INIT` and `CATCHUP`: recoverable after a crash.
  - **Any other status (`STRUCTURE 's'`, `DATA 'd'`, `CONSTRAINTS 'c'`)
    disables the subscription and raises FATAL**: "Spock's subscriber %s
    initialization failed during nonrecoverable step (%c). Subscription
    disabled."

  So a kill, network loss or provider restart during the structure/data COPY
  of a new subscription leaves it permanently disabled. It fails, but
  recovering requires an operator. This is exactly the zodan Phase 5 path (L6).
- On ERROR (not SIGKILL), `spock_sync_worker_cleanup()` drops the remote slot.
  It connects to the origin and then loops, **without a bound**, while
  `spock_remote_slot_active()` is true (`WaitLatch` 1 s, exits only on
  SIGTERM; src/spock_sync.c:1440-1468). If the origin is unreachable,
  `spock_connect` fails (30 s `connect_timeout`) inside error cleanup.
- Per-table sync (`spock_sync_table`, src/spock_sync.c:1816-1870): if the
  table status is anything other than `INIT`, `READY` or `SYNCDONE` when a
  sync worker starts, the status becomes **`FAILED`** permanently. The
  comment says "Do not continue if any error happened during a previous SYNC
  attempt". So killing a table-sync worker mid-COPY means that table never
  syncs until an operator calls `sub_resync_table`. The apply worker ignores
  FAILED tables ("Failed SYNC operation should be ignored until someone
  processes the error", src/spock_apply.c:4500-4507).
- Handshake between apply and sync workers (src/spock_apply.c:4516-4570):
  - The apply worker `Assert(spock_worker_running(worker))` in SYNCWAIT, with
    the comment "TODO: What if the SYNC worker has gone? ... For now, suppose
    that it should be always exist in testing environment."
    **On a cassert build, a sync worker dying while in SYNCWAIT makes the
    apply worker hit the Assert, which crash-restarts the whole postmaster.**
  - `wait_for_sync_status_change()` polls every 60 s (`WaitLatch 60000L`,
    src/spock_sync.c:2639-2690). It returns false when the sync worker is
    gone, and the apply worker then raises `ERROR "a table synchronisation
    operation is failed"`.
  - The sync worker waits for CATCHUP in the same function.
- SQL waits: `spock.sub_wait_for_sync()` and `spock.table_wait_for_sync()`
  (src/spock_functions.c:3456-3561) poll every 200 ms with **no timeout**.
  They return when the status is READY, or raise ERROR if a table is FAILED
  with `stop_on_error`. If a subscription stays disabled in `'d'`, the
  subscription-level wait **spins forever** unless the client sets
  `statement_timeout`.

### L5. Pause/resume of apply workers during slot creation (add_node)

- `spock_create_slot_and_read_progress()` (src/spock_sync.c:640-760) runs
  `SELECT spock.pause_apply_workers()` **on the provider** over libpq, then
  `CREATE_REPLICATION_SLOT`, reads peer progress, and resumes. The flag
  `SpockCtx->pause_apply` is **instance-wide shmem**, not per database.
- `spock_pause_apply_workers()` (src/spock_functions.c:4049-4124) waits up to
  `spock.pause_timeout` (default 10 s, `PGC_USERSET`, no upper cap since
  b784924e; src/spock.c:1353-1366). It counts `pg_usleep(1000)` iterations,
  not wall time, so the real wait is longer under load. On timeout it clears
  the flag and raises `ERRCODE_LOCK_NOT_AVAILABLE`.
- If the subscriber dies after pausing and the resume never arrives, each
  paused apply worker gives up itself after `spock_pause_timeout` in
  `ConditionVariableTimedSleep` and **clears the global flag**
  (src/spock_apply.c:565-586): "apply worker pause timed out after %ds,
  resuming". The comment at src/spock_sync.c:1636-1640 relies on this: "the
  workers' CV timeout will recover them".
  - Liveness bound: a pause lasts at most about `pause_timeout`.
  - Note: if a worker times out while a legitimate slot creation is slow,
    workers resume early. That is a safety issue (the data-loss bug that
    5.0.7 fixed), not a liveness one.
  - While paused, the worker reads nothing from the socket. If
    `pause_timeout` is larger than `wal_sender_timeout` or
    `apply_idle_timeout`, the connection is dropped as well.

### L6. Zodan add_node: "completes or fails cleanly"?

samples/Z0DAN/zodan.sql (3274 lines, plpgsql + dblink, run on the new node).
Every step is a separate remote transaction, so there is **no atomicity and no
automatic rollback**. Docs (docs/modify/zodan/index.md:18-22): "Zodan
simplifies removing partially added nodes created during failed node add
operations. Additional cleanup steps may be required before attempting another
node deployment".

Timeouts and bounds:

| Wait | Bound | Where |
|---|---|---|
| `spock.sync_timeout()` helper | `spock.sync_timeout` GUC if > 0, else **180 s** | zodan.sql:46-52 |
| Phase 4: wait for src to apply other node's changes through `_catchup_lsn` (reads `spock.progress` via dblink) | `sync_timeout()`. Each probe is limited by a local `statement_timeout = 5s`. Probe errors are swallowed and retried every 0.5 s. | zodan.sql:1905-1980 |
| Phases 6, 8 and 9: `CALL spock.wait_for_sync_event(true, origin, lsn, timeout_s, wait_if_disabled => true)` on the new node | `sync_timeout()` | zodan.sql:2074-2104, 2160-2181, 2700-2740, 2371-2401 |
| `verify_subscription_replicating` | 120 iterations of 1 s plus a dblink round trip | zodan.sql:756-791 |
| `wait_for_replication_catchup_with_dblink` | `max_wait_seconds` 180 | zodan.sql:1045-1106 |
| Phase 11 final state | `sync_timeout()` wall budget | zodan.sql:2745-2760 |
| Phase 12 `monitor_replication_lag` | 60 s, then **just exits with NOTICE** (not an error) | zodan.sql:985-1030 |
| Fixed sleeps | `pg_sleep(5)` after each `create_sub`, and so on | zodan.sql:2031, 2262, 2316, 2354 |

Points for testing:
- `spock.sync_timeout` (src/spock.c:1368-1386) is **only read by zodan
  through `pg_settings`**. No C code uses `spock_sync_timeout`. Its GUC
  description ("waiting for a sync event to arrive, for a peer to catch up")
  describes zodan's behaviour, not the C functions'.
- Phase 3, creating a disabled subscription on the new node per other node,
  catches `WHEN OTHERS` and only emits **NOTICE** (zodan.sql:2025-2036).
  add_node keeps going with a missing subscription. It neither completes
  fully nor fails cleanly.
- `wait_if_disabled => true` with Phase 5's initial sync: if the src→new
  subscription is disabled by L4 (killed during COPY), Phase 6 polls until
  `sync_timeout` (180 s) and then raises. That is a clean failure, but it
  leaves behind the node, slots on the other nodes, disabled subscriptions
  and origins.
- 17_zodan_3n_timeout.pl asserts that a missing `sync_event` fails "quickly
  ... (not timeout)".
- Any dblink call without its own `statement_timeout` (most of them) blocks
  for as long as the remote backend does. A paused (SIGSTOP) peer hangs
  add_node **without limit**, because keepalives are ACKed by the kernel.
  Only the Phase 4 probe sets 5 s.
- Clock: every zodan budget uses `clock_timestamp()`. A clock jump on the new
  node shortens or lengthens the budgets.
- Past liveness bug, 8de96369: `spock.get_lsn_from_commit_ts()` (used by
  Phase 7, slot advance) waited for WAL that never came on an idle node.
  "SPOC-648 saw an add-node workflow stall behind this call for over eleven
  minutes". It is now bounded by `GetFlushRecPtr` taken up front
  (src/spock_functions.c:4160-4260).

### L7. sync_event / wait_for_sync_event

- `spock.sync_event(transactional bool DEFAULT false)`
  (src/spock_functions.c:3983-4045) writes a logical message with an explicit
  WAL flush. Comment: "waiters cannot hang because of a caller-side rollback"
  (non-transactional). For transactional=true: "if the calling transaction
  rolls back, the marker is discarded and any waiter will hang until its own
  timeout fires."
- Apply side (src/spock_apply.c:2936-2965): a non-transactional marker calls
  `replorigin_session_advance(lsn, InvalidXLogRecPtr)`. This is in-memory
  origin progress with **no local WAL commit**. It becomes durable only at
  checkpoint or the next real commit. After a subscriber crash,
  `remote_lsn` can **go back** below a marker that a waiter has already seen
  satisfied. Empty transactions also advance via `replorigin_session_advance`
  (src/spock_apply.c:1113-1128).
- `spock.wait_for_sync_event(OUT result, origin, lsn, timeout int DEFAULT 0,
  wait_if_disabled bool DEFAULT false)` (sql/spock--6.0.0.sql:685-780) works
  like this:
  - **`timeout = 0` means wait forever.**
  - It polls `pg_replication_origin_status.remote_lsn` every 200 ms
    (`ROLLBACK; pg_sleep(0.2)`).
  - It raises if the subscription is missing or disabled, unless
    `wait_if_disabled`.
  - Budget measured with `clock_timestamp()` (wall clock).
- Property: for every `sync_event()` LSN L on origin O, `wait_for_sync_event`
  on each subscriber of O eventually returns true, provided the subscription
  stays enabled and connectivity eventually returns. A transactional marker
  only does so if its transaction committed.
- `spock.wait_slot_confirm_lsn(slot, lsn)` (src/spock_monitoring.c:30-110):
  "It may get stuck in an infinite loop if no replication slots available ...
  No timeout is offered, use a statement_timeout." With slot = NULL it waits
  on **every** in-use slot, including physical slots and orphaned inactive
  ones, so a single dead slot blocks it forever.

### L8. Failover slot synchronization (PG15–17; disabled on PG18)

- On PG18 the worker is not registered. The code says to use native
  `sync_replication_slots = on` (src/spock_failover_slots.c:1912-1922). On
  PG17 it yields if `sync_replication_slots` is on (src/spock_failover_slots.c:1355-1373).
- Main loop: `spock.failover_slots_naptime` (default 1000 ms) and
  `spock.failover_slots_feedback_naptime` (default 10000 ms), both SIGHUP
  (src/spock_failover_slots.c:64-65, 117-124, 1890-1905). When the server is
  not in recovery or `hot_standby_feedback` is off, it naps `naptime * 10`.
- `wait_for_primary_slot_catchup()` (src/spock_failover_slots.c:557-760):
  - Waits **without limit** for the primary's slot to pass the local
    reserved position.
  - Reconnects on failure every `wal_retrieve_retry_interval`.
  - Exits on promotion ("interrupted by promotion"), when the remote slot
    vanishes, or when the walreceiver has no conninfo (fix 24f3bff8).
  - Oddity: the log throttle uses `Min(wal_retrieve_retry_interval * 5,
    PG_WAIT_EXTENSION)`, where `PG_WAIT_EXTENSION` is a wait-event class
    constant, not milliseconds (line about 735). It only affects logging.
- Primary-side walsender hold-back, `wait_for_standby_confirmation()`
  (src/spock_failover_slots.c:1456-1590):
  - Logical walsenders **block** until the slots in
    `spock_failover_slots.pg_standby_slot_names` confirm the commit LSN.
  - Polls every 100 ms. After `wal_sender_timeout` it does
    `proc_exit(0)` with COMMERROR "terminating walsender process due to
    spock_failover_slots.pg_standby_slot_names replication timeout".
  - **A partitioned physical standby therefore stops all logical replication
    from that primary**, with walsenders cycling every `wal_sender_timeout`.
    This is intended (failover safety), but it is a liveness dependency on
    the standby.
- Docs (docs/logical_slot_failover.md:300-310): after PG15/16 promotion
  "Spock's worker ... stops synchronizing slots ... Subscribers reconnect
  automatically" (after the DSN is changed by hand on PG17+).

### L9. Recovery and catch-up after a crash

- Restart resumes from the durable replication origin
  (`replorigin_session_get_progress(false)`, src/spock_apply.c:4757-4761).
  `spock_init_progress_state()` reconciles shmem progress loaded from
  `PGDATA/spock/resource.dat` against the origin. If the file is stale it
  scans pg_commit_ts, bounded by `SPOCK_TS_RECOVERY_SCAN_LIMIT = 1,000,000`
  xids in batches of 1000 (src/spock_progress_recovery.c:20-60). The scan has
  a bound, so recovery cannot hang on it.
- On clean shutdown, the supervisor waits for apply workers at most
  50 × 100 ms = 5 s before writing the resource dump
  (src/spock.c:856-890). Postmaster shutdown is not blocked for longer.
- Feedback and slot advance: `send_feedback()` reports the flush position
  from `lsn_mapping` (local flush of applied commits). When nothing is
  outstanding it reports `recvpos` (src/spock_apply.c:3237-3300).
  - Under `use_try_block` with TRANSDISCARD or SUB_DISABLE, feedback is
    **suppressed** until the exception transaction finishes
    (src/spock_apply.c:3803-3818).
  - docs/internals-doc/OUTPUT.md:68-70: "The client *must* send feedback,
    otherwise `pg_xlog` on the server will eventually fill up". A
    disabled subscription keeps its slot and holds WAL on the provider
    without limit, so it is a disk-full liveness risk for the *provider*.

### L10. Wall-clock dependence (clock-skew faults)

Every timer below uses `GetCurrentTimestamp()` or `clock_timestamp()`, which
is wall time, not monotonic time:
- **Manager restart scheduling** (src/spock_manager.c:107-131):
  `restart_time = terminated_at + restart_delay`, compared with `now`, and
  the manager sleeps for the difference. A **backward clock step of Δ after
  a worker dies delays its restart by about Δ**. Each manager pass after the
  first `restart_delay_default` recomputes the delay, which is still
  positive, so the worker stays down until wall time catches up. This is a
  strong Antithesis target: kill an apply worker, step the clock back, and
  check the time to resume.
- `apply_idle_timeout` (src/spock_apply.c:3548-3563): a forward jump of more
  than 300 s causes a spurious reconnect (tagged as connection-class, so it
  is harmless). A backward jump delays detection of a hung walsender.
- `wait_for_sync_event`, zodan budgets, and the failover-slot
  `wal_sender_timeout` check at src/spock_failover_slots.c:1565 all use wall
  time.
- `apply_delay` (src/spock_apply.c:881-900) sleeps with
  `pg_usleep` (cannot be interrupted, so SIGTERM is ignored) for at most
  `apply_delay`. It is guarded by `current > origin_timestamp`, so skew
  cannot make the sleep longer than the configured delay.
- `spock.pause_timeout` uses CV timed sleep and an iteration count, so it is
  not affected by wall-clock jumps.

### L11. Other unbounded waits worth noting

- `wait_for_previous_transaction()` (src/spock_apply.c:294-340), called up to
  `spock.read_retry_count` (default 5) times from heap UPDATE/DELETE when a
  row is missing (src/spock_apply_heap.c:983-998, 1105-1118):
  - Loops until `prev_remote_ts == required_commit_ts`, with **no timeout**
    (1 ms CV sleeps).
  - `required_commit_ts` comes from the provider's slot-group
    `last_commit_ts`. It is 0 unless the provider's slot name ends in
    `_<single digit>` (`spock_output_join_slot_group`,
    src/spock_output_plugin.c:1280-1320). Slot names are
    `spk_<db>_<provider>_<subname>`, so a subscription named like `sub_1`
    turns this on.
  - include/spock_group.h:100 says `prev_remote_ts` "seems do nothing at the
    moment". Possible hang (see Open Questions).
- Drop-subscription path: waits without limit (1 s polls) for the apply
  worker to exit after `spock_worker_kill` (src/spock_sync.c:1408-1428).
- `wait_for_worker_startup()`: polls every 1 s, with no timeout, until the
  bgworker is STARTED and attached, or STOPPED (src/spock_worker.c:230-300).
  Runs in the manager and supervisor.

---

## Candidate liveness properties for Antithesis

1. **Reconnect:** after any fault window ends (partition, kill, pause,
   provider restart), every enabled subscription reaches `replicating`, and
   `spock.lag_tracker` replication lag reaches 0 bytes once writes stop,
   within roughly `restart_delay_default + 30 s connect + 25 s keepalive`,
   or `apply_idle_timeout` (300 s) for a paused peer.
2. **Convergence:** once writes stop and faults heal, every node's table
   contents become equal. A `sync_event()` marker issued on each node is
   observed by `wait_for_sync_event` on every peer.
3. **No spurious disable:** `spock.subscription.sub_enabled` never flips to
   false, and `spock.exception_log` gains no rows, unless a genuine data
   conflict was injected (L3).
4. **Restart pacing:** an apply worker that dies is restarted. No
   crash-loop faster than `restart_delay_default` for connection-class
   errors.
5. **Pause bounded:** `SpockCtx->pause_apply` never stays set longer than
   about `spock.pause_timeout` after the add_node caller dies (L5).
6. **add_node outcome:** `spock.add_node` either returns success with a
   fully meshed new node, or raises within a bound derived from
   `sync_timeout`. Watch for silent partial success (Phase 3 NOTICE
   swallow) and indefinite hangs on paused peers.
7. **Expected non-liveness (record, don't flag):** a subscription or table
   whose initial sync was interrupted ends up disabled or FAILED and needs an
   operator (L4). With `SUB_DISABLE`, a real data fault stops replication.

## Areas examined

- src/spock.c (GUCs, `spock_connect_base` keepalives, supervisor, shutdown drain)
- src/spock_manager.c, src/spock_worker.c (register, startup wait, detach, restart)
- src/spock_apply.c (`apply_work` loop, `PG_CATCH` classifier, idle timeout,
  feedback, pause, sync_event handling, `process_syncing_tables`,
  `spock_apply_main`)
- src/spock_apply_heap.c (read-retry), src/spock_output_plugin.c (slot groups,
  output_delay)
- src/spock_sync.c (subscription/table sync state machines, cleanup, slot
  creation with pause)
- src/spock_functions.c (sync_event, pause/resume, wait_for_sync_complete,
  WAL scan), src/spock_monitoring.c (`wait_slot_confirm_lsn`)
- src/spock_failover_slots.c, src/spock_progress_recovery.c
- sql/spock--6.0.0.sql (`wait_for_sync_event`), samples/Z0DAN/zodan.sql
- docs/configuring.md, docs/logical_slot_failover.md, docs/modify/zodan/index.md,
  docs/spock_release_notes.md, docs/internals-doc/OUTPUT.md
- git: 8dcfbcd5, ed0a9945, f3d4935e, 24f3bff8, 8de96369, b784924e, 11b9d385, db380dd8
- TAP test headers: 017, 101–105, 046 (by name)

## Assumptions

- `GetCurrentTimestamp()` and `clock_timestamp()` follow the container's
  wall clock, which Antithesis can skew.
- The bgworker SIGUSR1 notify (`bgw_notify_pid`) sets the supervisor's
  latch, which is standard PG behaviour. It was not verified for the
  supervisor specifically.
- A FATAL or `proc_exit(1)` in a spock worker counts as `crash=true` in
  `spock_worker_detach` (on_shmem_exit code != 0).
- The Antithesis build may use `--enable-cassert`. If so, the Assert in L4
  becomes a whole-instance crash.

## Open Questions

1. Backward clock step: does the manager really keep a dead apply worker
   down for the size of the step? It looks like it. Confirm and decide
   whether this is in scope.
2. With `restart_delay_on_exception = 0`, is a 1 ms respawn loop on an
   unclassified ERROR acceptable? (Example: an apply worker FATAL in readonly
   mode, or a permanent protocol error 08P01.) It could starve the CPU in
   the simulation.
3. Can `wait_for_previous_transaction()` hang when slot-group mode is
   triggered by a subscription name ending in `_<digit>`?
   `prev_remote_ts` must match `required_commit_ts` exactly.
4. Non-transactional sync_event moves the origin forward without WAL. After a
   subscriber crash `remote_lsn` can go back below a marker a waiter has
   already accepted. Does zodan depend on that marker being durable?
5. Is `spock.sync_timeout` intentionally used only by zodan? The GUC
   description reads as if C routines honour it.
6. Zodan Phase 3 swallows `create_sub` errors as NOTICE. Is add_node
   expected to finish successfully with a missing subscription?
7. Running `pause_apply_workers` in one database pauses apply workers
   instance-wide (the flag is global). The wait loop checks only
   `MyDatabaseId`. Workers in other databases also pause until resume or
   timeout. Is that intended?
