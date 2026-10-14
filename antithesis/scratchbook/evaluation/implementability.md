---
sut_path: /home/msharp/dev/pgedgea/spock
commit: 69d9228f5df363761dc3ae6eebf7e2fcfe49b8e5
updated: 2026-10-13
external_references: []
---

# Evaluation — Lens 3: Implementability

Question asked of every property: can it be checked with the planned topology
(n1-n3 mesh, spare n4, one workload container, PG18 patched, cassert), the
planned workload, and the codebase as it is, and does the catalog account for
the SUT changes it needs?

Method: read the catalog, the SUT analysis and the deployment topology in
full; read evidence files where a property's set-up was unclear; checked the
code paths that decide whether a check can be observed or a precondition
built (cited below). Antithesis product facts come from the local copy of the
Antithesis docs (`snouty docs`, pages named inline); they are not SUT
claims.

Findings are ordered catalog-wide first, then by property. Each ends with a
suggested action.

---

## Catalog-wide findings

### CW1. There is no Antithesis C SDK; every SUT-side assertion needs a shim that the plan does not describe

- **Properties:** catalog-wide. About 40 properties carry SUT-side
  assertions; for these the SUT side is the main or only check:
  `exception-replay-only-after-recorded-error`,
  `exception-replay-never-reruns-committed-transaction`,
  `proto5-replay-reparses-startup-message`, `apply-stream-framing-and-lsn-order`,
  `progress-reconcile-anomaly-unreachable`, `add-node-pause-held-until-progress-read`,
  `feedback-never-confirms-undurable-apply`, `resource-dat-dumps-serialized`,
  `manager-kill-targets-only-listed-worker`, `apply-search-path-not-leaked-across-transactions`,
  `apply-identity-restored-after-queued-sql`, `exception-log-slots-never-exhausted`,
  `progress-hash-capacity-survives-node-churn`, `luw-tiebreak-against-third-origin-row-reached`,
  `readonly-all-never-commits-remote-txn`, `apply-worker-memory-bounded`.
- **Concern:** the topology says "Antithesis C SDK (`antithesis_sdk.h`)". The
  docs page `reference/sdk/c_sdk` says only "Contact us about the availability
  of the C SDK". `antithesis_sdk.h` is the C++ SDK: header-only, C++20, Clang
  16+ (`reference/sdk/cpp`). Spock is C built with PGXS. Two routes exist:
  (a) one C++ file compiled into `spock.so` with `extern "C"` wrappers (needs
  clang++ and libstdc++ linked into a backend module; C++ exceptions must
  never cross a `longjmp`), or (b) the Fallback SDK: a small C writer that
  appends JSONL to `$ANTITHESIS_OUTPUT_DIR/sdk.jsonl`
  (`reference/sdk/fallback/assert`). With (b), every assertion must also be
  **declared at startup** (`hit: false`); otherwise a `Sometimes`/`Reachable`
  that never fires is never listed and cannot fail. That matters here because
  many properties use a SUT-side `Sometimes` to show the matching `Always` was
  not vacuous. Writes come from many forked backends, so each line must be one
  `write()` on an `O_APPEND` descriptor, and `ANTITHESIS_OUTPUT_DIR` must reach
  the postmaster's environment.
- **Evidence:** `snouty docs show reference/sdk/c_sdk`; `reference/sdk/cpp`;
  `reference/sdk/fallback/assert`.
- **Suggested action:** add an "SUT assertion shim" item to the plan: choose
  (a) or (b), declare every SUT-side message from `_PG_init` (runs once in the
  postmaster under `shared_preload_libraries`), and fix the topology's SDK line.

### CW2. Some SUT-side checks need new state or change behaviour, and some need to know which test is running

- **Properties:** `add-node-pause-held-until-progress-read` (pausing backend's
  PID in `SpockCtx`), `resource-dat-dumps-serialized` (shared atomic
  "dumpers inside" counter), `proto5-replay-reparses-startup-message`
  (parse version stored per replay-queue entry),
  `exception-replay-never-reruns-committed-transaction` (last committed
  `commit_lsn`), `apply-search-path-not-leaked-across-transactions`
  (boot `search_path` copy), `progress-hash-capacity-survives-node-churn`
  (`HASH_ENTER` -> `HASH_ENTER_NULL`), `committed-ledger-row-reaches-every-node`
  ("template-guarded" `Unreachable`).
- **Concern:** most of these are small and the catalog names them. Two need
  more thought. (1) `HASH_ENTER_NULL` changes what the SUT does on a full
  table (an ERROR becomes a NULL return into branches that are dead today), so
  the instrumented build would no longer test the shipped error path; a count
  check before the insert observes the same state without changing it.
  (2) "Template-guarded" assertions (`Unreachable("apply entered exception
  replay in a conflict-free run")`) need a way for the harness to tell the SUT
  which mode it is in. Nothing in the plan provides that.
- **Suggested action:** use a count check instead of `HASH_ENTER_NULL`. For
  mode flags, set a custom placeholder GUC in `postgresql.conf` per test
  configuration (for example `antithesis.conflict_free = on`, read with
  `GetConfigOption`), and list it in the setup notes.

### CW3. The node container plan conflicts with the graceful-stop and crash helpers the catalog relies on

- **Properties:** `graceful-restart-preserves-exactly-once`,
  `fast-shutdown-completes-within-bound`, and every property whose fault list
  says "graceful stop (test cmd)" or relies on a test-command `kill -9`
  (see CW4).
- **Concern:** the topology says "Run postgres in the foreground under
  `init: true`. Killing the container then kills the postmaster with it." The
  catalog (Assumption 6) assumes "the node container runs a supervisor loop so
  a graceful stop does not end the container". With postgres as the main
  process, `pg_ctl stop` or `kill -9 <postmaster>` ends the container, and the
  docs recommend no compose restart policy (`controlling_faults/fault_types`,
  Node termination note), so nothing brings the node back. Also, the
  workload container cannot run `pg_ctl` on another container. Test commands
  can live in any container (`test_templates/first_test`: "Sharing test
  templates across multiple containers"), so the helpers can sit in the node
  containers, but the node image must then keep running after postgres exits.
  A second point: Antithesis "node stop" (graceful termination) sends the
  container's stop signal. Under `init: true` that is SIGTERM to postgres,
  which is a **smart** shutdown; it waits for client sessions (workload,
  dblink), so in practice it ends as a kill after Docker's grace period.
- **Evidence:** `deployment-topology.md` "Run postgres in the foreground";
  `property-catalog.md` Assumption 6; Antithesis `fault_types` page.
- **Suggested action:** change the node entrypoint to a small loop that starts
  postgres, waits, records how it exited (clean or not) in a file outside
  PGDATA, and restarts it unless a "stay down" flag file exists. Put
  `pg_ctl stop -m fast`, `kill -9 <postmaster>` and per-worker signal helpers
  as test commands in the node containers. Set `stop_signal: SIGINT` (fast
  shutdown) on node services so that Antithesis node stop, if it uses the
  container stop signal, exercises fast shutdown (unverified, see
  Uncertainties).

### CW4. Many P0/P1 properties need a crash at a moment the workload chooses; random node termination rarely lands there

- **Properties:** `ledger-row-applied-exactly-once-per-peer`,
  `delta-counter-equals-committed-increments`, `causally-deleted-row-stays-deleted`
  (kill within the unconfirmed window after a burst on a provider that then
  goes quiet); `sync-event-barrier-survives-subscriber-restart` (provider
  quiet, marker reached, kill before the provider's next transaction);
  `feedback-never-confirms-undurable-apply` (kill within the flush delay after
  a graceful worker exit); `redelivered-ddl-not-turned-into-exception` (kill
  after a DDL barrier, before a checkpoint); `enabled-subscription-always-has-provider-slot`
  (kill between the remote slot drop and the local commit of `sub_drop`);
  `add-node-after-peer-restart-captures-every-peer` (source restart just
  before add_node); `local-overwrite-gets-later-commit-ts` (restart while the
  clock is behind).
- **Concern:** Antithesis node faults are scheduled independently of the
  workload and do not overlap on one container
  (`fault_types`, "Overlapping faults"). `crash-redo-leaves-no-node-id-origin-state`
  is fine with random kills (any applied remote commit since the last
  checkpoint is enough), but the redelivery properties need the kill inside a
  window of milliseconds to about `wal_sender_timeout/2`, tied to workload
  steps. Without a workload-driven kill these will mostly pass without being
  tested. The catalog's Open Questions treat the `kill -9` helper only as a
  fallback for when node termination is off.
- **Suggested action:** make the workload-driven crash helper (CW3) a planned
  part of the harness, not a fallback. Let the workload pick, with SDK
  randomness, whether to call it at each of these points. Keep Antithesis node
  termination on as well for kills at unplanned moments.

### CW5. The "admin churn" phase as described breaks the shared ledger, delta and convergence oracles

- **Properties:** `apply-never-waits-on-dead-sync-worker`,
  `sync-wait-functions-honor-contract`, `remote-transaction-all-or-nothing-per-node`
  (FAILED-table path), `resource-dat-dumps-serialized`,
  `exception-log-slots-never-exhausted` (claim-race route),
  `progress-reconcile-anomaly-unreachable` (resync route),
  `exception-replay-only-after-recorded-error` (L15 route),
  `sub-drop-vs-table-sync-no-deadlock`, `manager-kill-targets-only-listed-worker`,
  `enabled-subscription-always-has-provider-slot`, `no-orphan-slot-pins-wal-after-quiesce`,
  `spock-connections-match-subscriptions-after-quiesce`; and, as victims of
  false failures, every ledger/delta/convergence property.
- **Concern:**
  - `sub_resync_table(..., truncate := true)` truncates the table on the
    subscriber in a local (repair-mode) transaction
    (`src/spock_functions.c:1281-1336`, `skip_wal_records_decoding(true)`
    then `truncate_table`), then copies the provider's snapshot. On a table
    that several nodes write, rows that S had from itself or from a third
    node, and that P did not yet have at its snapshot, are gone from S for
    good. With `truncate := false` the plain COPY fails on existing keys and
    the table ends FAILED (noted in the
    `apply-never-waits-on-dead-sync-worker` evidence file). One evidence file
    already says "only resync in a quiesced window"; another wants the
    resynced table "also being written, so CATCHUP has work". Both can hold
    only with a table written by P alone.
  - `sub_drop` then re-create of a mesh subscription: initial sync does not
    truncate (`truncate_table` is only called from the resync and
    `sub_alter_sync` paths, `src/spock_functions.c:1214, 1333`), so
    `synchronize_data := true` fails on the existing rows; with
    `synchronize_data := false` the new slot starts at the current LSN and the
    gap since the drop is never sent. Either way the ledger property fires for
    a reason the workload caused.
  - Any table left FAILED is skipped by apply from then on.
- **Suggested action:** add to Assumptions: (1) resyncs target dedicated
  single-writer tables (for example one `resync_<P>` table per provider,
  written only on P, replicated to everyone), so truncation loses nothing and
  CATCHUP still has work; (2) drop/re-create and `sub_drop`-during-sync
  scenarios use throwaway subscriptions with their own replication set and
  table (an extra subscription between the same two nodes is allowed;
  `sub_create` only warns when replication sets overlap,
  `src/spock_functions.c:646-669`); (3) ledger, delta, contested and
  convergence checks exclude those tables.

### CW6. Deliberate data errors conflict with the "no exception rows at all" checks

- **Properties:** properties that inject poison transactions or rely on data
  errors: `interrupted-exception-replay-still-records-txn`,
  `exception-log-matches-discarded-transactions`, `proto5-replay-reparses-startup-message`,
  `progress-insert-lsn-never-ahead-of-provider` (needs a data error to fire),
  `replay-spill-file-lifecycle`, `apply-worker-memory-bounded`. Properties that
  assert no exception rows: `terminate-active-transactions-never-discards-inbound`
  ("no `exception_log` row at all on that node"),
  `sub-disable-enable-cycle-loses-and-duplicates-nothing`,
  `graceful-restart-preserves-exactly-once`, `apply-cancel-retried-not-discarded`,
  `readonly-toggle-resumes-without-loss`, `rolling-upgrade-node-restart-loses-nothing`,
  plus the SUT-side `Unreachable("apply entered exception replay in a
  conflict-free run")` in `committed-ledger-row-reaches-every-node`.
- **Concern:** run in one workload, the first group makes the second group
  fail. `exception-log-matches-discarded-transactions` also leans on the
  documented `update_missing` ordering, which leaves permanent, documented
  divergence on whatever table it uses.
- **Suggested action:** keep poison and `update_missing` writes on their own
  tables, record their remote xids (`spock.exception_log.remote_xid` exists,
  `sql/spock--6.0.0.sql:54-73`), and have the "no exception rows" checks
  ignore rows for those xids and tables. Gate the SUT-side `Unreachable` with
  the CW2 mode GUC, or run the poison properties in a separate test template.

### CW7. Several checks read server logs, which the workload cannot reach in the planned topology; `exception_log` has no SQLSTATE column

- **Properties:** `apply-survives-provider-clock-ahead` (TRAP line,
  "terminated by signal 6"), `worker-respawn-rate-bounded` ("exiting with
  error", `src/spock_worker.c:431-435`), `replication-origin-states-do-not-leak`
  ("could not find free replication state"), `apply-stale-socket-never-polled`
  ("epoll_ctl() failed"), `progress-reconcile-anomaly-unreachable` (log
  fallback), `no-orphan-slot-pins-wal-after-quiesce` ("could not drop slot"),
  `remove-node-clean-report-no-leftovers` (WARNING in n4's log); and every
  property that matches `exception_log` by error code: `apply-cancel-retried-not-discarded`,
  `lock-contention-retried-not-discarded`, `insert-race-resolved-not-discarded`,
  `redelivered-ddl-not-turned-into-exception` (lists SQLSTATEs 42P07 etc.),
  `readonly-local-keeps-inbound-ddl-flowing` (25006).
- **Concern:** the topology runs postgres in the foreground; its stderr goes
  to the container log, which Antithesis keeps but the workload cannot read.
  `spock.exception_log` stores only `error_message` text, no SQLSTATE
  (`sql/spock--6.0.0.sql:54-73`), so error-code checks become text matches
  that depend on `lc_messages`.
- **Suggested action:** set `logging_collector = on` with a fixed
  `log_directory` and `log_line_prefix`, and have the workload read logs with
  `pg_ls_logdir()` / `pg_read_file()` as superuser (Assert TRAP output goes to
  stderr, which the collector captures). Pin `lc_messages = 'C'` on every
  node. Rewrite the SQLSTATE lists in `redelivered-ddl-not-turned-into-exception`
  and `readonly-local-keeps-inbound-ddl-flowing` as message texts.

### CW8. Settings in the three documents disagree, and the small-capacity variant is really a separate configuration

- **Properties:** `mesh-barriers-complete-after-partition-heal`,
  `fast-shutdown-completes-within-bound`, `convergence-check-runs-after-faults`,
  `crashed-node-returns-to-streaming` (bounds built on `wal_sender_timeout`);
  `exception-log-slots-never-exhausted`, `progress-hash-capacity-survives-node-churn`,
  `worker-respawn-rate-bounded`, `replication-origin-states-do-not-leak`
  (small-capacity); the L1 properties (checkpoint spacing).
- **Concern:**
  - `wal_sender_timeout`: catalog Assumption 4 says 60 s and "do not lower
    it"; the SUT analysis's minimum config (§15) says `'5min'`; the topology
    does not say. Every liveness bound is computed from 60 s. If setup copies
    §15, the bounds are wrong by 4 minutes.
  - Capacity: topology says `max_worker_processes` 32 and the catalog says
    `max_active_replication_origins` at least 32 (so L1 redo does not stop on a
    full array); the small-capacity variant wants about 10 for both. These
    cannot be one configuration, and with 10 origin states a crash with L1
    states present may stop the node starting, which would fire
    `crashed-node-returns-to-streaming` for a sizing reason.
  - Exception-log exhaustion is reset by any restart of that node, so the
    small-capacity runs need node termination off (or at least not on the
    churned node).
  - Large `checkpoint_timeout` alone does not keep checkpoints away under
    sustained writes; `max_wal_size` triggers them too.
- **Suggested action:** add `wal_sender_timeout = 60s` and a large
  `max_wal_size` to the topology's required configuration. Name the
  small-capacity variant as its own configuration (for example
  `v2/small-capacity`, node kills off) instead of "v1 + small-capacity".

### CW9. Thread pausing cannot stretch windows that sit inside PostgreSQL core

- **Properties:** `sync-event-barrier-implies-visible` (own-transaction check:
  window between the origin advance in `RecordTransactionCommit` and
  `ProcArrayEndTransaction`), `insert-race-resolved-not-discarded` (window ends
  at the unique check inside core `ExecSimpleRelationInsert`),
  `add-node-pause-held-until-progress-read` (slot creation waiting in core
  snapbuild).
- **Concern:** thread pausing acts only on instrumented code
  (`fault_types`, Thread pausing). The plan instruments `spock.so` only and
  leaves core uninstrumented on purpose. These windows are in core, so only
  CPU modulation and whole-node pause reach them, and those are coarse.
- **Suggested action:** lower the reachability expectation for these three in
  the catalog, or instrument the few core files involved (`xact.c`,
  `execReplication.c`, `snapbuild.c`) in a later image. For the add-node case
  a workload precondition works better anyway (see that property below).

### CW10. Clock-skip size decides whether the L3 properties can fire at all

- **Properties:** `local-overwrite-gets-later-commit-ts`,
  `luw-final-version-has-max-commit-ts` (L3 part),
  `progress-commit-lsn-tracks-applied-commits`, and less so
  `luw-tiebreak-against-third-origin-row-reached`,
  `clock-step-forward-makes-commit-ts-ties`.
- **Concern:** clock skips are global and can be temporary or permanent
  (`fault_types`, Clock skips); the docs' only example is a 65 ms jump undone
  one second later. L3 needs a backward skip larger than the time for a node
  restart plus crash recovery plus one local write (several seconds), because
  once wall time passes the old maximum the restarted node stamps correct
  times again. If skips are mostly tens of milliseconds, these properties
  cannot fire. The Assert crash (`apply-survives-provider-clock-ahead`) and
  equal-timestamp ties need much smaller skips, so they are likely fine.
- **Suggested action:** ask the Antithesis contact what skip sizes are used.
  If they are small, add a per-node clock offset as a custom fault (for
  example libfaketime preloaded in node containers, reading an offset file the
  fault writes). That also gives per-node skew, which the global skip cannot.

### CW11. Time budget: quiet periods and ZODAN runs are long

- **Properties:** all quiet-period checks; all add_node properties;
  `zodan-readd-node-progress-not-stale`, `exception-log-slots-never-exhausted`,
  `progress-hash-capacity-survives-node-churn` (repeat cycles).
- **Concern:** one barrier round needs about `wal_sender_timeout` (60) +
  `apply_idle_timeout` (30) + `restart_delay_default` (5) + `connect_timeout`
  (30) + margin, so 2.5-3 minutes per quiet period. A successful add_node
  under writes takes minutes: fixed `pg_sleep(5)` calls
  (`samples/Z0DAN/zodan.sql:2031, 2262, 2316, 2354`), a lag monitor that waits
  up to 60 s for zero lag (`:992-1027`; under constant writes on n1-n3 lag is
  rarely zero), and 180 s waits. A re-add also needs n4's user tables dropped
  first: add_node refuses a database with user tables (`:1577-1592`) and
  checks that n4 has every role the source has (`:1595`). Neither step is in
  the catalog's re-add description.
- **Suggested action:** put add_node and node-churn properties in their own
  test template; add "drop user tables on n4 and create roles" to the re-add
  steps; consider lowering `spock.sync_timeout` and pausing writes briefly
  around Phase 12 so add_node does not sit in the lag monitor.

### CW12. The workload needs to tell planned restarts, Antithesis kills and fresh boots apart

- **Properties:** `graceful-restart-preserves-exactly-once` ("windows touched
  by a kill excluded"), `sync-event-barrier-survives-subscriber-restart`
  (clean-restart message), `worker-respawn-rate-bounded` (skip windows with a
  kill), `exception-log-slots-never-exhausted` (no kills), `crashed-node-returns-to-streaming`.
- **Concern:** Antithesis does not tell the workload when it kills a node.
  The docs also say a restarted node "may lose all of their modified data and
  boot fresh from their image" (`fault_types`, Node termination). If the
  entrypoint runs `initdb` on an empty volume, the node returns as a blank
  Postgres with no Spock node and every data and liveness property fires.
- **Suggested action:** have the node wrapper (CW3) keep a boot counter and
  last-exit kind in a file the workload can read with `pg_read_file`, and
  compare `pg_control_system().system_identifier` across checks to detect a
  fresh boot; skip and report (`Sometimes`) instead of asserting when that
  happens. Get the PGDATA durability question answered before the first run.

---

## Property-specific findings

### ledger-row-applied-exactly-once-per-peer (also `no-change-applied-on-its-origin-node`, `add-node-success-new-node-has-every-row`)

- **Concern:** the audit trigger is described as "`ENABLE ALWAYS` trigger that
  fires only under `session_replication_role = replica`". `ENABLE ALWAYS`
  fires in both roles, so local client inserts would also add audit rows; the
  one-entry-per-peer count would be off and `no-change-applied-on-its-origin-node`
  ("no apply_audit row on N has origin_node = N") would fire on every local
  write.
- **Evidence:** PostgreSQL trigger firing rules; the property text.
- **Checks that do work:** oracle (2) is sound: `spock_report_conflict` drops
  same-origin reports only for `UPDATE_EXISTS` and `DELETE_ORIGIN_DIFFERS`
  (`src/spock_conflict.c:393-461`), so a redelivered INSERT's `insert_exists`
  row is saved. For n4, the initial COPY session sets
  `session_replication_role = 'replica'` (`src/spock_sync.c:923-930`), so
  copied rows fire a replica-mode trigger once each and the "one audit entry
  per n4 row" check holds for copied rows too.
- **Suggested action:** use `ENABLE REPLICA` (or `ENABLE ALWAYS` with a body
  that returns early unless `current_setting('session_replication_role') =
  'replica'`).

### crash-redo-leaves-no-node-id-origin-state

- **Concern:** small. The workload probe works: `pg_show_replication_origin_status()`
  lists every used state and leaves `external_id` NULL when
  `replorigin_by_oid(..., missing_ok = true)` finds no catalog row (local
  PostgreSQL tree, `src/backend/replication/logical/origin.c`,
  `pg_show_replication_origin_status`). The same NULL appears for a moment
  when an origin is dropped while the view is read (`sub_drop`, sync
  cleanup). The SUT-side version cannot read `replication_states` (static in
  `origin.c`); it would need SPI on the same view.
- **Suggested action:** assert only on a NULL-name row seen in two samples a
  few seconds apart (or in a quiet period); implement the SUT-side check with
  SPI or drop it in favour of the workload probe.

### feedback-never-confirms-undurable-apply

- **Concern:** check (3) (`local_lsn <= GetFlushRecPtr()` at a new worker's
  first feedback) needs the old worker's async apply commits still unflushed
  when the new worker starts. Two things close that window in the planned
  workload: client sessions on S commit with `synchronous_commit = on`, and
  each such commit flushes all earlier WAL, including the apply commits; and
  after a clean exit the manager is not woken, so the restart takes up to
  `restart_delay_default` (5 s), far longer than `wal_writer_delay` (200 ms).
  Only a fast `sub_disable` -> `sub_enable` cycle (the enable wakes the
  manager) or a quiet S leaves a gap. The loss itself also needs a crash in
  that gap (CW4).
- **Suggested action:** add a phase with no client writes on S, use
  `sub_disable`/`sub_enable` back to back as the exit, and run a variant with
  `wal_writer_delay` raised (for example 5-10 s). Drive the follow-up kill
  from the crash helper.

### sync-event-barrier-survives-subscriber-restart

- **Concern:** needs P quiet, the marker applied, then S killed before P's
  next transaction. Random kills almost never line up with "P quiet for this
  pair". Restart detection is easy (`pg_postmaster_start_time()`).
- **Suggested action:** run as a scripted sequence: stop P's writers, take a
  marker, wait for it on S, call the crash helper on S, then re-check.

### sync-event-barrier-implies-visible

- **Concern:** the main check is fine. The own-transaction check's window is
  inside core commit (CW9), so thread pausing will not widen it.
- **Suggested action:** keep the check; note that CPU modulation and luck are
  the only drivers.

### add-node-pause-held-until-progress-read

- **Concern:** the workload cannot see the paused state: the pause sleep uses
  `WAIT_EVENT_LOGICAL_APPLY_MAIN` (`src/spock_apply.c:571-575`), the same wait
  event as a normal idle apply worker, and `MyApplyWorker->paused` is not
  exposed. The catalog relies on "pause of provider during slot creation",
  but a node pause stops the apply workers too, so their timers and slot
  creation stall together.
- **Better precondition (workload-built):** hold an open transaction that has
  an xid on the source for longer than `spock.pause_timeout` while add_node
  creates the slot; snapshot building waits for that xid while each paused
  apply worker self-resumes after `pause_timeout`. Lowering
  `spock.pause_timeout` to 1 s with `ALTER SYSTEM` (the worker reads its own
  session value) makes the gap almost certain.
- **Suggested action:** add the long-transaction step and the
  `pause_timeout` setting to the workload notes; keep the SUT-side
  `Unreachable` as the main check.

### exception-replay-never-reruns-committed-transaction

- **Concern:** the cancel must land while the source's apply worker sleeps in
  `maybe_pause_for_slot_creation()` right after a commit. That state is not
  visible (same wait event as above). The workload can see the slot creation
  itself (the walsender's `query` in `pg_stat_activity` on the source shows
  `CREATE_REPLICATION_SLOT`) and cancel all apply workers on the source then.
- **Suggested action:** describe that trigger in the evidence file; expect a
  low hit rate and rely on the SUT-side `Unreachable`.

### progress-commit-lsn-tracks-applied-commits

- **Concern:** the property cannot find a bug in either planned image. It
  needs clock skew, but the catalog requires the SPOC-688 fix (4e0988de) in
  any image that runs clock faults, and that commit also changes
  `progress_update_struct` to advance `remote_commit_lsn` whatever the
  timestamps are (`git show 4e0988de -- src/spock_group.c`). The SUT-side
  `Unreachable` site ("update dropped because commit ts went backwards") does
  not exist in the patched code. On the image without the fix there are no
  clock faults.
- **Evidence:** `git show 4e0988de`; `git merge-tree --write-tree HEAD
  4e0988de` merges without conflicts.
- **Suggested action:** keep it as a regression guard for the fix (workload
  check only) and say so in the catalog, or drop it. It is P3 already.

### apply-survives-provider-clock-ahead

- **Concern:** none for the gate itself: 4e0988de is on
  `origin/task/SPOC-688/apply-clock-skew-fix`, is one commit past the merge
  base, merges onto HEAD without conflicts and removes the Assert at
  `src/spock_apply.c:1173-1174`. The workload `Unreachable` reads the log
  (CW7).
- **Suggested action:** record the merge check in the evidence file; pin the
  clock-fault image to HEAD + 4e0988de.

### local-overwrite-gets-later-commit-ts, luw-final-version-has-max-commit-ts

- **Concern:** clock-skip size (CW10) and restart timing (CW4). The
  per-overwrite check itself is easy (`pg_xact_commit_timestamp(xmin)` inside
  the `FOR UPDATE` transaction, `pg_xact_commit_timestamp` of the saved xid
  after commit).
- **Suggested action:** as in CW10; script "restart X, then overwrite a row X
  took from a peer" with the crash helper.

### graceful-restart-preserves-exactly-once, fast-shutdown-completes-within-bound

- **Concern:** both need `pg_ctl` run inside the node container (CW3).
  `fast-shutdown-completes-within-bound` also checks "no processes from the
  old postmaster remain", which SQL cannot see once the postmaster is gone; it
  needs `ps` in the node container. `pg_ctl` launched from SQL with
  `COPY ... TO PROGRAM` is a child of a backend and is signalled with the
  backend's process group at shutdown, so it is not a safe substitute.
- **Suggested action:** node-container test commands for both; the wrapper
  from CW3 restarts postgres afterwards.

### zodan-readd-node-progress-not-stale

- **Concern:** the re-add needs the n4 database emptied of user tables
  (CW11). `spock.progress` is not filtered by database
  (`get_apply_group_progress`, `src/spock_functions.c:4483-4520` reports every
  entry with its dbid), so the stale rows from n4's first life stay visible
  whether the workload drops tables or recreates the database. The
  "ZODAN-side marker" (Phase 7 logging `last_updated_ts`) is a change to
  `samples/Z0DAN/zodan.sql`; the catalog does not list it among SUT changes.
- **Suggested action:** add the cleanup step and list the zodan.sql change.

### exception-log-slots-never-exhausted, progress-hash-capacity-survives-node-churn

- **Concern:** the two need different churn. Exception-log slots are claimed
  per **subscription name** on the first BEGIN, so the cheapest route is
  throwaway subscriptions with fresh names (`sub_create`, one write, wait,
  `sub_drop`), roughly `max_worker_processes` times on one node with no
  restart of that node. ZODAN node churn would take several minutes per
  cycle. The progress hash is keyed by (dbid, node_id, remote_node_id)
  (`src/spock_group.c:17, 186-191`), so subscription churn does not grow it;
  only fresh **node** names do.
- **Suggested action:** say in each evidence file which churn it needs; run
  both in the small-capacity configuration with node termination off (CW8).

### sub-drop-vs-table-sync-no-deadlock

- **Concern:** the sampler works: the LWLock tranche is named
  `"spock context lock"` (`src/spock_shmem.c:119`), which is what
  `pg_stat_activity.wait_event` shows. The scenario needs `sub_drop` of a
  subscription whose table sync is in SYNCWAIT; on a mesh subscription that
  breaks the oracles (CW5). The window is short and none of the existing delay
  hooks (`SPOCK_RANDOM_DELAYS` sites) sit in it.
- **Suggested action:** use a throwaway subscription with a dedicated table;
  loop resync-then-drop many times per timeline.

### enabled-subscription-always-has-provider-slot

- **Concern:** the kill must land between the remote slot drop and the local
  commit inside `sub_drop`, a short window; random kills will rarely hit it,
  and dropping mesh subscriptions breaks the oracles (CW5).
- **Suggested action:** throwaway subscription; start `sub_drop` and call the
  crash helper after a small random delay.

### initial-sync-ends-ready-or-visibly-disabled

- **Concern:** the expected pg_dump hang (no keepalives, blocking `waitpid`)
  also blocks the workload's `CALL spock.add_node`. If that call runs in the
  same driver as the quiet-period checks, the checks never run.
- **Suggested action:** run add_node in its own test command with a
  client-side timeout, and let the check read n4's sync status separately.

### terminate-active-transactions-never-discards-inbound

- **Concern:** `spock.terminate_active_transactions()` also cancels the
  workload's own client sessions on that node. Those commits have unknown
  outcome.
- **Suggested action:** treat client 57014 errors after a call as "unknown
  outcome" and resolve them through the marker row, as the ledger already
  does for lost connections.

### exception-replay-only-after-recorded-error

- **Concern:** none; the `transaction_timeout` FATAL source is reachable from
  outside: PostgreSQL arms it in `StartTransaction()` (local tree,
  `src/backend/access/transam/xact.c:2175-2176`), which the apply worker uses,
  and the worker picks up `ALTER DATABASE ... SET transaction_timeout` at
  connect. Restart the apply workers after setting it.
- **Suggested action:** add that set-up step to the evidence file.

### apply-cancel-retried-not-discarded (and other "worker exit" properties)

- **Concern:** none. Spock leaves `bgw_type` empty, so PostgreSQL uses
  `bgw_name` as `backend_type`: `spock apply <dboid>:<subid>`,
  `spock sync <rel> <dboid>:<subid>`, `spock manager <dboid>`
  (`src/spock_worker.c:170-191`). The workload, as superuser, can find and
  `pg_cancel_backend` / `pg_terminate_backend` them over SQL; no node-side
  helper is needed for single-worker exits.

### readonly-all-never-commits-remote-txn, apply-worker-memory-bounded (hold list), forwarded-origin-advance-no-double-apply, provider-slot-owned-by-one-subscription, Category N

- **Concern:** already scoped by the catalog to other topologies or configs
  (slot groups, standby, cascade, colliding names, mixed version, mixed PG
  major). Nothing to add except that "v1 (best with slot groups)" for
  `readonly-all-never-commits-remote-txn` means it will mostly report
  unreached in v1.

---

## Passes

These look implementable with the v1 plan once the catalog-wide items above
are handled (mainly CW4 crash helper, CW5 table scoping, CW7 log access):

- Workload-observable with SQL only: `committed-ledger-row-reaches-every-node`,
  `delta-counter-equals-committed-increments`, `contested-rows-converge-after-quiesce`,
  `luw-unchanged-toast-no-mixed-rows`, `insert-conflict-recorded-in-resolutions`,
  `resolutions-rows-match-applied-outcome`, `remote-transaction-all-or-nothing-per-node`
  (main path), `mesh-barriers-complete-after-partition-heal`,
  `convergence-check-runs-after-faults` (`ANTITHESIS_STOP_FAULTS` exists and,
  as the catalog says, clock skips continue in quiet periods —
  `controlling_faults/pause_faults`), `sub-show-status-reflects-apply-state`,
  `apply-worker-restarted-within-bound-after-exit`, `spock-connections-match-subscriptions-after-quiesce`,
  `replay-spill-file-lifecycle` (`pg_ls_tmpdir`), `progress-insert-lsn-never-ahead-of-provider`,
  `replicated-values-mean-same-on-every-node` (deterministic; a TAP test would
  find it faster), `readonly-local-keeps-inbound-ddl-flowing`,
  `readonly-toggle-resumes-without-loss`, `sub-disable-enable-cycle-loses-and-duplicates-nothing`,
  `lock-contention-retried-not-discarded` (`ALTER DATABASE SET lock_timeout`
  plus worker restart over SQL), `apply-cancel-retried-not-discarded`.
- `crash-redo-leaves-no-node-id-origin-state` is the most reliably reachable
  P0: any random subscriber kill after an applied remote commit and before the
  next checkpoint.
- `luw-tiebreak-against-third-origin-row-reached`, `clock-step-forward-makes-commit-ts-ties`
  and `apply-survives-provider-clock-ahead` need only small global clock
  skips.
- The SPOC-688 gate is buildable: 4e0988de merges onto HEAD cleanly.

## Uncertainties

- Clock-skip sizes and how long skips last are not documented beyond a 65 ms
  example; CW10 depends on it.
- Whether Antithesis "node stop" uses the compose `stop_signal` (CW3) is not
  stated in the docs.
- Whether node termination and clock faults are enabled for the tenant, and
  whether PGDATA survives a kill (already open in the catalog), decide how
  much of CW4/CW12 matters.
- libfaketime with a patched PG18 under Antithesis has not been tried.
- The PostgreSQL source checked for `transaction_timeout` and the origin
  status view is a local development tree (`~/dev/pg/postgresql`), not the
  patched PG18 tree; the pgEdge patches do not touch those functions per the
  SUT analysis.
- Whether thread pausing needs coverage instrumentation in every process
  image, or only in the code it should pause, is assumed from the docs'
  wording ("requires instrumentation to take effect").
