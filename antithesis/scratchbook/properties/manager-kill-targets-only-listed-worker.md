# manager-kill-targets-only-listed-worker

## What led here

Concurrency note F9, sut-analysis lead L21. Re-read at HEAD 69d9228f. While
re-reading, a variant was found that needs no second process: the manager can
reuse, in its own registration step, a slot that it is about to kill.

## Code path

`manage_apply_workers` (`src/spock_manager.c:41-180`):

1. Under `SpockCtx->lock`: `workers = spock_apply_find_all(dboid)` (`:52-54`),
   a list of **pointers into shared memory** (`SpockCtx->workers[]`). Lock
   released.
2. For each enabled subscription, remove its worker from `workers`
   (`:80-90`). What is left are workers for disabled or dropped subscriptions,
   plus terminated slots of those.
3. Register new apply workers (`spock_worker_register`, `:138-150`). Register
   calls `find_empty_worker_slot` (`src/spock_worker.c:101-117`), which returns
   any slot that is `SPOCK_WORKER_NONE` **or terminated (`terminated_at != 0`)
   in the same database**. The chosen slot is overwritten (`memcpy`, new
   `generation`, `terminated_at = 0`) and `wait_for_worker_startup` waits until
   the new process attaches.
4. Under the lock again: for every pointer still in `workers`,
   `spock_worker_kill(worker)` (SIGTERM if running), and if `terminated_at != 0`
   reset the slot to `NONE` (`:156-170`).

Between 1 and 4 the slot behind a pointer can change owner:

- **Same-process variant:** subscription U's apply worker crashed earlier (slot
  S terminated, same DB) and U is now disabled or dropped, so S stays in
  `workers`. In the same pass subscription T needs a worker; step 3 picks S
  (terminated, same DB) for T. Step 4 then SIGTERMs T's brand-new worker.
- **Cross-process variant:** an apply worker in the same DB registers a **sync**
  worker (`start_sync_worker`, `src/spock_apply.c:4638`) between steps 1 and 4
  and gets slot S. Step 4 SIGTERMs the sync worker, possibly mid-COPY. If the
  sync worker is in COPY, the SIGTERM is ignored until COPY ends and then
  makes the sync worker skip catch-up (see "What a SIGTERM does to a sync
  worker" below): silent drift for that table, a stuck subscription, or a
  node crash-restart in a cassert build.
- If the reused slot later terminates before step 4, the reset to `NONE` erases
  the new owner's `terminated_at`, losing its restart backoff.

`spock_worker_kill` (`src/spock_worker.c:666-676`) checks only
`spock_worker_running`, not type, subscription or generation.

## Invariant

- Suggested SUT-side assertion (**missing**): record each listed slot's
  `generation` and `worker_type` in step 1; in step 4, before
  `spock_worker_kill`,
  `Always(slot->generation == listed_generation && slot->worker_type == SPOCK_WORKER_APPLY,
  "manager kills only the apply worker slot it listed")`.
  `Always` because killing any other occupant is never intended.
- Workload-side `Always("at most one apply worker per subscription")`: sample
  `pg_stat_activity` on each node; group by `backend_type` /
  `application_name` matching `spock apply <dboid>:<subid>`; count <= 1 per
  subid. Cheap check of the slot table's main promise. (Expected to hold; it
  guards against a different slot-reuse bug in the same code.)
- Workload-side `Sometimes("enabled subscription had its apply worker
  restarted after a kill")`: reached when a worker the harness killed is seen
  running again. Liveness companion; shows the restart path is exercised.

## Fault / timing requirements

- SIGKILL of a single apply worker would crash-restart the whole postmaster and
  wipe the slot table, so it does **not** reach this. Needs a graceful error
  exit of an apply worker (`pg_terminate_backend` gives a clean exit, slot
  reset to NONE — also not enough; an ERROR exit is needed, e.g. a provider
  partition so the worker exits with a connection error, which leaves
  `terminated_at` set).
- Workload: disable (`sub_disable`) or drop a subscription whose worker just
  exited with an error, while enabling / creating another subscription or
  while a table resync starts in the same DB.
- Thread pausing on the manager between the list and the kill widens the
  window.

## What a SIGTERM does to a sync worker (resolved, code read, not run)

Sync workers use Spock's SIGTERM handler, which only sets `got_SIGTERM` and
the latch (`src/spock_worker.c:83-93`, installed in `spock_worker_attach`).
The sync code checks the flag only in `spock_sync_worker_cleanup`'s loop
(`src/spock_sync.c:1437`) and in `wait_for_sync_status_change`
(`:2650`). The COPY loop (`copy_table_data`, `:1197-1205`, blocking
`PQgetCopyData`/`PQputCopyData`) never looks at it. So:

1. **SIGTERM during COPY:** ignored. COPY finishes and commits, progress is
   dumped, status goes to `w` SYNCWAIT (`:2033-2037`).
2. `wait_for_sync_status_change(..., CATCHUP, &lsn)` returns false at once
   with `lsn = InvalidXLogRecPtr`, because the loop condition is already false.
3. `Assert(lsn == status_lsn)` (`:2042`): **cassert build aborts -> postmaster
   crash-restart of the whole node.**
4. Non-cassert: the worker sets up its origin and compares `status_lsn` with
   `MyApplyWorker->replay_stop_lsn` (`:2057`). That field was set at
   registration to the apply worker's origin position at that time
   (`start_sync_worker`, `src/spock_apply.c:4650`), which is before the sync
   slot was created, so normally `status_lsn >= replay_stop_lsn` and the worker
   **marks the table SYNCDONE at `status_lsn` and exits cleanly without
   catching up.** Apply skipped this table's changes while it was `p`/`d`/`w`
   (`should_apply_changes_for_rel`, `src/spock_apply.c:464-484`) and resumes
   only once it sees SYNCDONE with `statuslsn <= origin_lsn`. Every change to
   the table between `status_lsn` and the apply worker's position at that
   moment is never applied: **silent drift, table shown as `replicating`.**
5. If the apply worker already took its SYNCWAIT branch and moved
   `replay_stop_lsn` forward before step 4, the sync worker instead starts
   catch-up; `apply_work` returns at once on `got_SIGTERM` and
   `spock_sync_main` calls `proc_exit(1)` (`:2088-2092`), an error exit with
   `terminated_at` set. The apply worker then waits on it forever
   (`apply-never-waits-on-dead-sync-worker`).
6. SIGTERM during catch-up (status `u`): same as 5.

A SIGTERM before COPY starts (status `p`, inside slot creation) is also
ignored; the same sequence follows once COPY ends.

Who sends a lone SIGTERM to a sync worker: this manager bug, and an operator's
`pg_terminate_backend`. Fast shutdown during COPY does not reach step 4
because it also terminates the local backend that receives the COPY, so the
sync worker gets an ERROR from `PQputCopyData` and takes the error-cleanup
path. **Correction (gap-fill, 2026-10-13):** that holds only during COPY.
During SYNCWAIT there is no COPY backend; the postmaster SIGTERMs the sync
worker while commits still work, the wait returns an invalid LSN, and the
worker skips catch-up. So fast shutdown **can** reach the skip in SYNCWAIT.
That consequence is now its own property,
`sync-worker-sigterm-never-skips-catchup`; this property keeps the manager's
misdirected kill as one of its causes.

So the cross-process variant can end in silent data drift, which raises this
property's weight. The SIGTERM-ignoring sync worker is a defect in its own
right; consider a separate SUT-side assertion
`Unreachable("sync worker skipped catch-up after SIGTERM")` in
`spock_sync_main` when `wait_for_sync_status_change` returns false.

## Is the same-process variant reachable? (resolved, code read, not run)

Yes, with this sequence: subscription U's apply worker exits with an ERROR
(e.g. provider partition), leaving slot S terminated with U's subid; while U
is in its restart back-off (`restart_delay_default`, 5 s), U is disabled or
dropped. The disable COMMIT latches the manager. In that pass U is skipped
(disabled), so S stays in `workers`. If the same pass also starts a worker for
T (T just enabled/created, or T's own back-off expired) and S is the lowest
free slot, `spock_worker_register` hands S to T and `wait_for_worker_startup`
waits until T's worker has attached. Step 4 then SIGTERMs it. T's worker is an
apply worker, so it exits cleanly and is restarted on a later pass: a
restart blip, not data loss (it behaves like a disable/enable cycle). Step 4
also resets S to NONE if T's worker has already terminated, dropping T's
back-off. The cross-process variant above is the one that matters.

## Open questions

- None open; both questions were answered from code (see the Investigation
  Log).

### Investigation Log

#### How does a sync worker react to SIGTERM in the middle of COPY?

- Examined: `handle_sigterm` (`src/spock_worker.c:83`), all `got_SIGTERM`
  checks in `src/spock_sync.c`, `copy_table_data`, `spock_sync_table`,
  `spock_sync_main` (`:1930-2092`), `start_sync_worker`
  (`src/spock_apply.c:4636-4655`), `should_apply_changes_for_rel`.
- Found: SIGTERM ignored during COPY; afterwards the worker skips catch-up
  and marks SYNCDONE (non-cassert) or hits an Assert (cassert); or, if apply
  moved `replay_stop_lsn` first, exits with error and stalls the
  subscription.
- Not found: any `got_SIGTERM` check in the COPY path or before SYNCWAIT.
- Conclusion: resolved. Worse than either option the question offered:
  silent drift without a FAILED mark, a stall, or a node restart.

#### Is the same-process variant reachable?

- Examined: `manage_apply_workers` (`src/spock_manager.c:41-180`),
  `find_empty_worker_slot`, `spock_worker_register`,
  `wait_for_worker_startup`, `spock_worker_detach`.
- Found: reachable when a disabled/dropped sub's error-terminated slot is the
  lowest free slot and another sub starts in the same pass; effect is an
  unnecessary kill and restart of the other sub's apply worker.
- Conclusion: resolved; liveness blip only.
