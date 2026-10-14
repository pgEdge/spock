# apply-never-waits-on-dead-sync-worker

## What led here

Concurrency note F5, sut-analysis lead L12 and contradiction 11.3 (resolved:
clean exit vs error exit behave differently). Re-read at HEAD 69d9228f. Not run.

## Code path: the apply/sync handoff

Per-table resync handshake (`process_syncing_tables`,
`src/spock_apply.c:4456-4635`; sync worker `spock_sync_main`,
`src/spock_sync.c:1960ff`):

`i` INIT -> `p` STARTED -> `d` DATA (COPY) -> `w` SYNCWAIT -> apply hands its
LSN as `replay_stop_lsn`, sets `u` CATCHUP -> sync streams to that LSN, sets
`y` SYNCDONE -> apply sets `r` READY.

How the apply worker learns the sync worker is gone:

- `spock_sync_find` (`src/spock_worker.c:560-578`) matches on
  `worker_type == SPOCK_WORKER_SYNC` + db + subid + table name. It ignores
  `terminated_at` and `proc`.
- `spock_worker_detach(crash=true)` (`src/spock_worker.c:410-480`) keeps
  `worker_type = SYNC`, sets `terminated_at`, clears `proc`. Only a clean exit
  sets the type to `NONE`.
- `wait_for_sync_status_change` (`src/spock_sync.c:2639-2693`), used after the
  apply worker sets CATCHUP (`src/spock_apply.c:4553-4566`), loops: read
  status; if not SYNCDONE, `spock_sync_find`; exit only if it returns NULL;
  else `WaitLatch(60 s)`.

So a sync worker that exits **with an error** during CATCHUP leaves a slot that
`spock_sync_find` still returns. The apply worker sleeps 60 s, re-checks, sleeps
again — for ever. Only the apply worker starts sync workers, and it is the one
stuck. It escapes only if some other registration in the same DB reuses that
terminated slot (`find_empty_worker_slot` reuses terminated same-DB slots), at
which point the wait returns false and the apply worker raises
`elog(ERROR, "a table synchronisation operation is failed")` (`:4566`), an
XX000 that the classifier treats as a data error (lead L5).

While stuck, the apply worker reads nothing from its provider: **the whole
subscription stops**, not only the table. `sub_show_status` keeps saying
`replicating` (`src/spock_functions.c:1437-1540`).

Sync workers in CATCHUP run `apply_work` against the provider, so any provider
disconnect (partition, provider restart, `apply_idle_timeout`) during catch-up
produces exactly this error exit.

Related branches:

- Sync worker gone at SYNCWAIT: `Assert(spock_worker_running(worker))`
  (`src/spock_apply.c:4532`) aborts the apply worker in a cassert build ->
  postmaster crash-restart of the whole node. Comment: "suppose that it should
  be always exist in testing environment". Non-cassert: branch skipped, a new
  sync worker is started, finds status `w` (not INIT), marks the table FAILED
  (`src/spock_sync.c:1851-1866`); FAILED tables are skipped by apply while the
  origin advances.

## Invariant

- Suggested SUT-side assertion (**missing**): in `wait_for_sync_status_change`,
  after `spock_sync_find` returns a non-NULL worker,
  `Unreachable("apply waits on sync worker that already exited with error")`
  when `worker->terminated_at != 0`. Reaching that line means the wait has no
  way to end by itself. (`proc == NULL` alone is not enough: a just-registered
  worker has `proc == NULL` and `terminated_at == 0` before it attaches.)
- Suggested SUT-side `Unreachable("sync worker missing at SYNCWAIT handoff")`
  placed just before the existing `Assert` at `src/spock_apply.c:4532`, so a
  non-cassert build also reports it and a cassert build reports it before the
  abort.
- Workload-side liveness, `Sometimes("table resync under faults reached ready
  or visible failure")`: after each `sub_resync_table` the workload polls
  `spock.local_sync_status` for that table; true when it reaches `r` (or `f`,
  which is acceptable per §12 as long as it is visible) within a bound after
  faults stop. Paired with an `Always("subscription barrier completes after
  table resync")`: a `sync_event` on the provider followed by
  `wait_for_sync_event` on the subscriber completes within
  `apply_idle_timeout + restart_delay + margin` once faults stop. The barrier
  is what catches the whole-subscription stall.

## Fault / timing requirements

- Network partition between subscriber and provider, or provider restart,
  **during table resync catch-up**. Provider process pause long enough for
  `apply_idle_timeout` (120 s in the harness, kept above `wal_sender_timeout / 2`; evaluation 2026-10-13).
- Not SIGKILL of the sync worker: that crash-restarts the node and wipes the
  slot table (different path).
- Workload: periodic `sub_resync_table(sub, table)` with the default
  `truncate := true` on a table that is also being written, so CATCHUP has
  work to do. **Correction:** `truncate := false` is not usable here. The sync
  COPY is a plain `COPY ... FROM STDIN` (`src/spock_sync.c:1176-1200`), so on a
  subscriber table that already holds the rows it fails with a unique
  violation, and the table ends FAILED every time. All regression tests use
  `truncate := true` (`tests/regress/expected/sync_table.out`).
- Another way to reach the stall: a SIGTERM to a sync worker in CATCHUP (e.g.
  from the manager slot-reuse bug, see `manager-kill-targets-only-listed-worker`,
  or `pg_terminate_backend`) makes `apply_work` return and `spock_sync_main`
  call `proc_exit(1)` (`src/spock_sync.c:2088-2092`), which is an error exit
  with `terminated_at` set.

## Findings from open-question investigation (HEAD 69d9228f, code read, not run)

- **No path clears a crashed SYNC slot except reuse.** Every write of
  `SPOCK_WORKER_NONE` / `terminated_at` was checked: clean detach
  (`src/spock_worker.c:466-469`), registration (`:150-158`), startup-failure
  marking (`:269-281`), and the manager's reset (`src/spock_manager.c:164-174`),
  which only walks `spock_apply_find_all` (APPLY slots). The slot is freed only
  when `find_empty_worker_slot` (`src/spock_worker.c:101-117`) hands it to a
  new registration in the same database, and it returns the **lowest** free
  slot, so reuse happens only if no lower slot is free.
- **What ends the wait.** Besides slot reuse, any SIGTERM to the apply worker
  ends it: `wait_for_sync_status_change` loops `while (!got_SIGTERM)`
  (`src/spock_sync.c:2650`), returns false, and the apply worker raises
  "a table synchronisation operation is failed". So `sub_disable`, any
  `sub_alter_*`, `sub_drop`, or `pg_terminate_backend` of the apply worker
  breaks the stall. Nothing automatic does. The `Unreachable` stays: reaching
  the line means the subscription is stopped until someone acts.
- **What happens after the stall is broken.** The restarted apply worker
  finds status `u` (not SYNCWAIT), launches a new sync worker, which sees a
  status other than INIT and marks the table FAILED
  (`src/spock_sync.c:1846-1866`). From then on apply skips the table
  (`src/spock_apply.c:4497-4506`). `sub_show_table` shows FAILED as
  `unknown` (`sync_status_to_string` has no case for it,
  `src/spock_functions.c:1355-1380`). `spock.table_wait_for_sync` raises
  "synchronization of table ... failed" with a hint to retry.
- **Intended recovery for FAILED is "operator resyncs".** The regression test
  `tests/regress/expected/sync_table.out` (`test_sync_fail`) shows exactly
  that: COPY fails, status `f`, `table_wait_for_sync` errors, operator fixes the
  cause and calls `sub_resync_table` again. `sub_resync_table` accepts
  FAILED but **refuses** `i`/`p`/`d`/`w`/`u` with "already being synchronized"
  (`src/spock_functions.c:1303-1316`), so a table stuck in CATCHUP cannot be
  resynced until the apply worker is restarted and the table turns FAILED.
- **Truncate:** with the default `truncate := true` the table is truncated in
  the caller's transaction (`src/spock_functions.c:1332-1333`); if the sync
  then fails, the table stays empty and FAILED until resync (the test above
  shows count 0). That is visible (`table_wait_for_sync` errors) and is the
  documented failure mode, not silent loss.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (implementability CW5); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 (admin-churn phase with table resyncs) · Faults: partition / provider restart during resync

- Evaluation note (2026-10-13): resyncs target a dedicated single-writer table (`resync_<P>`, written only on P), so `truncate := true` loses nothing and CATCHUP still has work; the ledger, delta and convergence checks exclude it (Assumption 5).

## Gap-fill extensions (2026-10-13)

From the gap-fill step; see `discovery/gap-b-addnode-ops.md` and `evaluation/synthesis.md`.

- Absorbs the investigation candidate `table-resync-under-faults-ends-ready`
  as a retry step instead of a separate property (as worded it contradicted
  the designed behaviour: a sync restarted after it started goes FAILED,
  `src/spock_sync.c:1846-1866`). After faults stop, the workload re-runs
  `sub_resync_table` on every table left FAILED (up to k tries; a table in
  `u`/`w` first needs the apply worker restarted, since resync refuses those
  states, `src/spock_functions.c:1306-1314`) and asserts
  `Always("retried table resync reaches READY after faults stop")`. Those
  tables then rejoin the ledger checks instead of the node being skipped.
- Code reading shows nothing blocks the retry: `sub_resync_table` accepts
  FAILED, and the slot and origin are re-used through the `ensure_*`
  helpers (an inactive leftover slot of the same name is dropped and
  re-created, `src/spock_sync.c:430-445`).
- Also covers the `repset_add_table(..., synchronize_data := true)` entry
  path on a new single-writer table (gap c item 2), which queues the same
  table sync.
- `operator-recovery-steps-restore-replication` lists this resync retry as
  one of its operator steps but does not assert it again; this property
  owns the message.

## Open questions

- Is a FAILED table that apply silently skips (no exception_log row, shown as
  `unknown`) acceptable as long as `table_wait_for_sync` reports it, or should
  apply stop / the status be surfaced in `sub_show_status`? Decides whether
  the workload's `Sometimes(... ready or visible failure)` may count `f`
  without also checking that the workload saw the error. `(needs human input)`

### Investigation Log

#### Is there another path that clears a crashed SYNC slot?

- Examined: all `SPOCK_WORKER_NONE` / `terminated_at` writes in
  `src/spock_worker.c` and `src/spock_manager.c`; `spock_sync_find`,
  `find_empty_worker_slot`, `wait_for_sync_status_change`.
- Found: only slot reuse by a later same-DB registration (lowest free slot
  first) or a SIGTERM to the apply worker ends the wait.
- Not found: any manager, supervisor or `sub_show_*` code that resets SYNC
  slots.
- Conclusion: resolved; the `Unreachable` stays as written.

#### What is the intended recovery for FAILED tables and a sync worker that dies in CATCHUP?

- Examined: `process_syncing_tables` FAILED handling and comment ("ignored
  until someone processes the error and changes the status"),
  `spock_alter_subscription_resynchronize_table`, `sync_status_to_string`,
  `tests/regress/expected/sync_table.out` (`test_sync_fail`).
- Found: operator resync is the designed recovery; `u`/`w` block resync until
  the apply worker restarts and the table becomes FAILED.
- Not found: user docs describing FAILED or the `unknown` display.
- Conclusion: `(partial: recovery is operator resync per regression test; whether the silent skip is acceptable needs the team)`; kept as the
  needs-human-input question above.

#### Should the workload use truncate := false?

- Examined: `copy_table_data` COPY statements (`src/spock_sync.c:1120-1200`),
  resync truncate (`src/spock_functions.c:1332`), regression tests.
- Found: plain COPY with no conflict handling; `truncate := false` on a
  populated table with a primary key fails with a unique violation.
- Conclusion: resolved; use the default `truncate := true`. The earlier
  advice in this file was wrong and has been corrected above.
