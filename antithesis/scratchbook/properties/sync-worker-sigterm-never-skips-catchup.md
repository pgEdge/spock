# sync-worker-sigterm-never-skips-catchup — A SIGTERMed table-sync worker never marks its table done without catch-up

## Origin

Investigation candidate G7 ("Candidate properties from investigation" in the
catalog), found while answering an open question on
`manager-kill-targets-only-listed-worker` (see that evidence file, "What a
SIGTERM does to a sync worker"). Promoted here to a full property because this
pass found a trigger that needs no manager bug: a fast shutdown while a table
sync is in SYNCWAIT.

## Code paths (HEAD 69d9228f)

- Sync workers use Spock's SIGTERM handler, which only sets `got_SIGTERM` and
  the latch (`src/spock_worker.c:83-93`, installed at `:339`). The COPY loop
  never checks the flag.
- `spock_sync_main` (`src/spock_sync.c:1960-2093`):
  1. `spock_sync_table` does the COPY and returns; status is set to `w`
     SYNCWAIT with `status_lsn` (`:2033-2037`).
  2. `wait_for_sync_status_change(..., SYNC_STATUS_CATCHUP, &lsn)` (`:2039`;
     body `:2639-2693`) sets `*lsn = InvalidXLogRecPtr` and loops
     `while (!got_SIGTERM)`. With SIGTERM already received, or received while
     waiting, it returns false with `lsn` invalid. It also returns false if
     the sync-status row disappears (`:2657-2661`).
  3. The return value is ignored. `Assert(lsn == status_lsn)` (`:2042`) aborts
     a cassert build (whole-node crash-restart).
  4. Non-cassert: origin setup, then `if (status_lsn >= MyApplyWorker->replay_stop_lsn)`
     (`:2057`). `replay_stop_lsn` was set at registration to the apply
     worker's origin position before the sync slot existed
     (`start_sync_worker`, `src/spock_apply.c:4651`), so the test is normally
     true: the table is marked SYNCDONE at `status_lsn` and the worker exits
     cleanly with no catch-up.
- `should_apply_changes_for_rel` (`src/spock_apply.c:464-484`): while the
  table is not READY, and while SYNCDONE with `statuslsn` ahead of the apply
  origin, the apply worker skips the table's changes. By the time the sync
  worker finishes, the apply worker is usually at P > `status_lsn` (it kept
  applying other tables during COPY). Changes to the table in
  (`status_lsn`, P] were skipped by apply and never applied by the sync
  worker. The apply origin has moved past them, so they are never re-sent:
  **silent permanent drift on that table**, and `sub_show_table` shows
  `replicating` once the table goes READY.
- If the apply worker had already set CATCHUP (moved `replay_stop_lsn` to P,
  `src/spock_apply.c:4535-4537`) the sync worker instead enters catch-up,
  `apply_work` returns at once on `got_SIGTERM`, and `proc_exit(1)`
  (`:2088-2092`): an error exit that the apply worker then waits on
  (`apply-never-waits-on-dead-sync-worker`). Not this property.

## Who sends the SIGTERM

1. **Fast (or smart) shutdown.** In `PM_STOP_BACKENDS` the postmaster sends
   SIGTERM to every child including background workers
   (`src/backend/postmaster/postmaster.c` around `:2922-2998` in the patched
   PG18 tree). A sync worker in SYNCWAIT has no local COPY backend to lose, so
   it takes steps 2-4. Commits still work at that point (the shutdown
   checkpoint waits for backends to exit), so the SYNCDONE write lands.
   Correction to the `manager-kill-targets-only-listed-worker` evidence, which
   says fast shutdown does not reach step 4: that holds for a SIGTERM during
   COPY (the local COPY backend is also terminated and the sync worker takes
   the error path), not for one during SYNCWAIT.
2. `pg_terminate_backend` of a sync worker by an operator or a workload test
   command, at any point from slot creation through SYNCWAIT (during COPY the
   signal is held until COPY ends, then steps 2-4 follow).
3. The manager killing a reused slot (`manager-kill-targets-only-listed-worker`,
   L21).

SYNCWAIT lasts until the apply worker's next `process_syncing_tables` pass. It
is long when the apply worker is busy in a big remote transaction, waiting on a
local row lock, held by the add_node pause, disconnected from its provider, or
not running because the subscription was disabled (the manager kills only apply
workers, so a sync worker of a disabled subscription waits in SYNCWAIT until
the next shutdown).

## Failure scenario (non-cassert; cassert crashes instead)

Workload resyncs table T on n2 from n1 (`sub_resync_table(..., truncate :=
true)`). Writes to T on n1 continue. COPY ends at `status_lsn`; n2's apply
worker for n1 is busy (or the subscription was just disabled). The test command
runs `pg_ctl stop -m fast` on n2. The sync worker marks T SYNCDONE at
`status_lsn`; on restart the apply worker resumes at P > `status_lsn`; T's rows
from n1 committed in between are missing on n2 forever, with no exception row
and no error.

On the cassert harness build the Assert at `:2042` aborts during shutdown; the
node restarts through crash recovery and T, still in `w`, goes FAILED when its
sync worker restarts (`src/spock_sync.c:1846-1866`). Visible, but a crash.

## Fault requirements

- Table resyncs in the v1 workload (catalog-wide open question "Table resyncs
  in v1").
- Graceful-stop test command (the catalog's planned helper) issued during a
  resync, preferably when the workload sees status `w` in
  `spock.local_sync_status`; or a test command that terminates a Spock sync
  worker (`pg_stat_activity` backend_type for Spock sync workers).
- Load that keeps the apply worker busy (large transactions, local lock
  contention on the subscriber) stretches SYNCWAIT. `sub_disable` during a
  resync makes SYNCWAIT last until the next stop.
- Antithesis node termination does not reach it (SIGKILL, no handler).

## Assertions

- SUT-side (primary): in `spock_sync_main`, right after
  `wait_for_sync_status_change` returns and before the `Assert`,
  `Unreachable("sync worker left SYNCWAIT without reaching CATCHUP", {table,
  got_SIGTERM, status_lsn, replay_stop_lsn})` when it returned false. Fires on
  both builds and before the crash. `Unreachable` because the code has no
  legitimate path that should end a sync without catch-up this way; the
  closing comment at `:2089-2091` says SIGTERM "in case of sync worker is not
  expected".
- Workload marker: `Sometimes("graceful stop or worker terminate issued while
  a table sync was in SYNCWAIT")`, from reading `local_sync_status = 'w'` just
  before issuing it.
- Outcome check (workload, shares the ledger oracle): after barriers, a
  resynced ledger table on the subscriber holds every row the provider
  committed (already enforced by `committed-ledger-row-reaches-every-node` if
  resyncs target ledger tables).

## Open questions

- Is a fast shutdown during a table resync a supported operation that must not
  lose data? Code comment says SIGTERM is "not expected" for a sync worker, but
  shutdown sends it. If the team says a resync must be re-run after any
  restart, the drift is still silent (nothing tells the operator), so the
  property stands; the answer changes how the finding is framed.
  `(needs human input)`
- What should the sync worker do on SIGTERM in SYNCWAIT: exit with an error so
  the restart path marks the table FAILED (visible), or keep the status at `w`
  and resume after restart? Affects the suggested fix only.

### Investigation Log

#### Is a fast shutdown during a resync expected to keep the table's changes?

- Examined: `spock_sync_main` SIGTERM handling and the SYNCWAIT wait
  (`src/spock_sync.c:2030-2045`, `wait_for_sync_status_change`
  `:2639-2693`); postmaster fast-shutdown order (bgworkers get SIGTERM while
  commits still work); docs for `sub_resync_table`.
- Found: the code comment calls SIGTERM "not expected" for a sync worker,
  but fast shutdown sends it; on SIGTERM in SYNCWAIT the wait returns an
  invalid LSN and the non-cassert build marks the table SYNCDONE without
  catch-up.
- Not found: docs saying a resync must be re-run after a restart.
- Conclusion: `(needs human input)`; the mechanism is code-confirmed, the
  intended contract is not documented.
