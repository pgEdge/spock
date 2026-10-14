# lock-contention-retried-not-discarded

## What led here

Apply vs local writers on the same keys (concurrency focus). The classifier
fix f3d4935e moved 40P01 / 55P03 / class 53 from the discard path to a retry
(sut-analysis 5.1, Pattern A). This property is the regression check for that
fix from the concurrency side: contention between apply workers and local
sessions must never cost data. It shares its oracle (exception_log) with the
broader "transient errors never discard" claim S3, but targets contention that
the workload creates on purpose, not infrastructure faults.

## Code path

- Apply row lookup and lock: `SpockRelationFindReplTupleByIndex`
  (`src/spock_common.c:334-480`). Dirty-snapshot index scan, waits on in-progress
  writers (`XactLockTableWait`, `:428`), then `table_tuple_lock` with
  `LockWaitBlock`; on `TM_Updated` / `TM_Deleted` it `goto retry` with no limit
  (`:459-475`). Waiting here is a heavyweight lock wait, so PG's deadlock
  detector covers it; the victim gets 40P01.
- `lock_timeout` set by `ALTER DATABASE/ROLE` is applied to the apply worker
  (sut-analysis 11.4) and gives 55P03.
- `apply_work` `PG_CATCH` (`src/spock_apply.c:3867-4133`): 40P01 and 55P03 ->
  `prepare_transient_error_retry` (`:443-456`, logs
  `transient error (deadlock/lock timeout), will restart and retry`) and
  rethrow. The worker exits, the origin stays at the last durable commit, the
  manager restarts it after `restart_delay_default`, and the transaction is
  re-streamed. Retry is indefinite.
- Not covered (documented / admitted): 40001 under cluster-wide RR/SERIALIZABLE
  (`:3951-3957`); 57014 from `pg_cancel_backend` on the apply pid (lead L5).
  The workload must not set `default_transaction_isolation` above READ
  COMMITTED and must not cancel apply backends in this scenario.
- Dangerous neighbour: under DISCARD replay, any per-row error, including
  40P01, is swallowed (lead L8). This property runs with TRANSDISCARD or
  SUB_DISABLE only.

## Failure scenario this guards

A local session updates rows R1 then R2 in one transaction; a remote
transaction being applied updates R2 then R1. Deadlock detector picks one. If
it picks the apply worker and the error went down the data-error path, under
TRANSDISCARD the remote transaction would be logged and dropped on this node
only. Today the code retries; a regression (new error path, wrapper that
changes the SQLSTATE, a lock wait inside a subtransaction that re-raises as
something else) would bring the loss back silently.

## Invariant

- Workload-side `Always("contention never lands in exception_log")`: after each
  quiescent barrier, no `spock.exception_log` row on any node has
  `error_message` matching `deadlock detected` or
  `canceling statement due to lock timeout` or `could not obtain lock`.
  `Always` because these are transient by Spock's own rule.
- Workload-side `Always` convergence companion on the contention table: every
  node holds the same rows after quiescence (the table has only resolvable
  conflicts: same-PK UPDATEs of rows inserted during setup, no deletes, so it
  stays inside §12 boundaries).
- Suggested SUT-side `Sometimes("apply worker lost deadlock to local session and
  will retry")` (**missing**) in the 40P01 branch, and
  `Sometimes("apply worker hit lock_timeout and will retry")` in the 55P03
  branch. These show the workload really produces the contention; without them
  the `Always` passes vacuously.

## Fault / timing requirements

- No injected fault needed. Workload creates contention:
  - local transactions on each node that lock hot rows in an order opposite to
    the remote writers, and hold them briefly (`pg_sleep` of tens of ms);
  - optionally `ALTER DATABASE ... SET lock_timeout = '200ms'` on one node for a
    phase to produce 55P03 in the apply worker.
- Thread pausing and CPU modulation help line up the lock orders.

## Open questions

None remaining. Both earlier questions are answered below.

## Resolved

- **The `goto retry` loop in `SpockRelationFindReplTupleByIndex` blocks; it
  does not spin.** Each retry follows either `XactLockTableWait` on the
  in-progress xid seen through the dirty snapshot (`src/spock_common.c:420-430`)
  or `table_tuple_lock(..., LockWaitBlock, ...)` returning `TM_Updated` /
  `TM_Deleted` (`:440-475`), and both only return after the other transaction
  has ended. The loop makes one pass per finished competing writer, the same
  shape as PG's own `RelationFindReplTupleByIndex`. A steady stream of local
  updates on one row can still delay apply (liveness, lag growth), never lose
  data. Both waits are heavyweight lock waits, so `lock_timeout` (55P03) and
  the deadlock detector (40P01) apply to them. The retries log at
  `SPOCK_DEBUG1` (LOG or DEBUG1 by `spock.log_verbosity`, `include/spock.h:110`),
  not ERROR. No property change; a lag-bound `Sometimes` on the hot table stays
  optional.
- **`ALTER DATABASE ... SET lock_timeout` reaches the apply worker.** The
  worker connects with `BackgroundWorkerInitializeConnectionByOid(dboid,
  InvalidOid, 0)` (`src/spock_worker.c:390`). PG18 `InitPostgres` calls
  `process_settings(MyDatabaseId, GetSessionUserId())` unconditionally for
  non-bootstrap processes (`postinit.c:1200`); with no role given, a bgworker
  runs as the bootstrap superuser. So database-level settings apply, and
  role-level settings apply only via `ALTER ROLE <bootstrap superuser>`
  (normally `postgres`), not a separate "apply role". Spock does not override
  `lock_timeout` for the apply worker (only for the sync worker's libpq
  sessions to the provider, `src/spock_sync.c:898-930`). Settings are read
  once at worker start, so the workload must restart the apply workers (or
  set the value before the subscription starts) for a change to take effect.

### Investigation Log

#### Can the unbounded goto retry spin without waiting under a hot local writer?

- Examined: `src/spock_common.c:334-480`, `include/spock.h:108-113`.
- Found: every retry is preceded by a blocking wait on the competing
  transaction (xact lock wait or `LockWaitBlock` tuple lock).
- Not found: any path that loops without waiting.
- Conclusion: resolved; starvation is at most a lag issue.

#### Does ALTER DATABASE lock_timeout reach the apply worker on PG18?

- Examined: `src/spock_worker.c:385-396`; PG 18.3 `src/backend/utils/init/postinit.c:1190-1200,1305-1330`;
  grep for `lock_timeout` in `src/`.
- Found: database settings are applied at connection start for bgworkers;
  the worker runs as the bootstrap superuser; Spock does not reset
  `lock_timeout` in apply.
- Not found: nothing missing.
- Conclusion: resolved, yes (needs a worker restart after the ALTER).
