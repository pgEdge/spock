# apply-worker-restarted-within-bound-after-exit

## Why this property

Spock claims the manager respawns dead apply workers and the supervisor
respawns managers (V2; `docs/spock_release_notes.md:603-610`). The restart
schedule is wall-clock based and depends on how the worker exited:

| Exit kind | Slot state after exit | Who wakes the manager | Restart time |
|---|---|---|---|
| ERROR / FATAL (`spock_worker_detach(crash=true)`, `src/spock_worker.c:~440-470`) | `terminated_at = GetCurrentTimestamp()`, type kept | manager latched | `terminated_at + restart_delay` |
| clean `proc_exit(0)` (SIGTERM, CONNECTION_BAD pre-check return `src/spock_apply.c:~3450`, sub disabled) | type -> NONE | postmaster SIGUSR1 to `bgw_notify_pid` (the manager that registered it) | at once, no `restart_delay` (corrected in investigation pass; timer tick only if the registering manager has since been replaced) |
| crash before attach | `wait_for_worker_startup` sets `terminated_at` | | as ERROR |
| postmaster crash-restart | shmem rebuilt | supervisor start | supervisor -> manager -> worker |

Manager check (`manage_apply_workers`, `src/spock_manager.c:105-131`):
`restart_time = terminated_at + restart_delay; if (restart_time >= now) skip`.
A **backward** wall-clock step of X after the exit delays the restart by about
X (lead L22, code-checked: `terminated_at` and `now` both come from
`GetCurrentTimestamp()`). The manager re-checks at most every
`restart_delay_default` (`ret` starts at it), so the delay is not unbounded,
but it tracks the size of the clock step. A forward step only makes restart
sooner.

Other ordering hazards in this lifecycle:

- Manager exits cleanly when it cannot find the local node
  (`src/spock_manager.c:59-61`) — expected on n4 before `node_create`.
  `node_create` signals `spock_subscription_changed(InvalidOid)` which sets
  `subscriptions_changed` and latches the supervisor at COMMIT.
- Manager crash (e.g. `spock_worker_register` ERROR when
  `max_worker_processes` is exhausted, `src/spock_worker.c:~200-204`) sets
  `subscriptions_changed` without a latch; supervisor relies on
  `bgw_notify_pid` SIGUSR1 (`src/spock_worker.c:196`), else 180 s (L32).
- Supervisor itself has `bgw_restart_time = 5` (`src/spock.c:1516`); while it
  is down, `SpockCtx->supervisor` still points at its old PGPROC.
- Manager uses worker pointers after dropping `SpockCtx->lock` (L21); a slot
  reuse could lose a crashed worker's `terminated_at`.
- Admin calls that hold `get_local_node(true, ...)`'s ShareUpdateExclusiveLock
  on `spock.local_node` block the manager's `get_local_node(true, true)`
  (`src/spock_node.c:721`), so worker restarts stop while such a call is open
  (e.g. a `sub_drop` waiting for its worker, or a long add_node helper).

## Invariant and assertions

- Workload (Always, evaluated in a quiet period after faults stop and the
  clock is stable): for each enabled subscription whose provider is reachable,
  the time from "no apply worker for this sub" (seen in `pg_stat_activity`,
  `backend_type`/`application_name` of the spock apply worker, or
  `spock.sub_show_status` not `replicating`) to "worker present and
  `sub_show_status = replicating`" is at most
  `restart_delay_default + connect_timeout (30 s) + margin`. Always because the
  bound must hold every time in the quiet period.
- SUT-side (missing, no existing assertions):
  `Sometimes(restart_time - now > 2 * restart_delay)` with message
  "manager deferred apply restart by more than twice restart_delay" inside the
  `restart_time >= now` branch. This marks that the L22 situation (backward
  step) was reached, so a green Always is meaningful.
- SUT-side (missing): `Reachable("manager restarted crashed apply worker")`
  right before `spock_worker_register` when `apply && apply->terminated_at != 0`,
  and `Reachable("manager restarted cleanly exited apply worker")` when
  `apply == NULL` for an enabled sub that previously had a worker. Two distinct
  outcomes, not one broad "restart" marker.

## Antithesis angle

Kill or `pg_terminate_backend` apply workers, partition providers, step the
clock back by tens of seconds on a subscriber just after an exit, and pause the
manager process. Interleave with admin calls that take the local-node lock.

## Fault requirements

Graceful worker exits (required), clock step backwards (required for L22),
network partitions, process pause. Node termination exercises the
crash-restart row of the table.

## Findings from the investigation pass (2026-10-13)

- **Bgworker exit notification is reliable once a worker has attached.**
  When a dynamic bgworker exits with status 0 or 1, the postmaster calls
  `ReportBackgroundWorkerExit()` (PG18 `postmaster.c:2675`,
  `bgworker.c:483-506`), which forgets `BGW_NEVER_RESTART` workers and then
  sends SIGUSR1 to `bgw_notify_pid`. Spock workers are registered with
  `bgw_notify_pid = MyProcPid` (`src/spock_worker.c:196`) and keep the
  default `procsignal_sigusr1_handler` (bgworkers with a DB connection get
  it in `bgworker.c:759`; Spock only overrides SIGTERM and SIGHUP), and
  that handler ends with `SetLatch(MyLatch)` (`procsignal.c:722`). So:
  - Manager ERROR/FATAL after attach: `spock_worker_detach(crash=true)`
    sets `SpockCtx->subscriptions_changed` (`src/spock_worker.c:461`)
    before the process exits; the SIGUSR1 after exit wakes the supervisor,
    whose loop then calls `start_manager_workers()`. No 180 s wait.
  - Apply worker clean exit: the SIGUSR1 wakes the manager, which finds no
    worker and restarts it at once (no `restart_delay`). This is relevant
    to `worker-respawn-rate-bounded`: a worker that keeps returning cleanly
    (e.g. the CONNECTION_BAD pre-check) is respawned with no delay.
  - Supervisor ERROR in `start_manager_workers()` (e.g. "all background
    worker slots are already used"): the supervisor exits and the
    postmaster restarts it after 5 s; it sets `subscriptions_changed` at
    start, so it retries every ~5 s.
- **Remaining gap: a manager that dies before `spock_worker_attach()`.**
  `wait_for_worker_startup()` marks `terminated_at` but nothing sets
  `subscriptions_changed`, and the supervisor's loop only calls
  `start_manager_workers()` when that flag is set (`src/spock.c:938-956`;
  the 180 s timeout alone does nothing). That database then has no manager
  until some other change sets the flag. Reaching this needs a fork failure
  or a death before attach (attach is the first thing the manager does and
  registers the exit hook before connecting), so it is narrow. A
  `Reachable("manager exited before attach")` marker in
  `wait_for_worker_startup`'s "exited prematurely" branch would show
  whether a run ever hit it.
- **PostgreSQL core restarts its own bgworkers on wall-clock time too**
  (`rw_crashed_at = GetCurrentTimestamp()`, PG18 `postmaster.c:2665`), so
  the L22 behaviour matches core practice.
- **Clock skips are not stopped by quiet periods.** Antithesis docs
  ("Pausing faults"): `ANTITHESIS_STOP_FAULTS` stops every fault "except
  clock skips", and jumps can go backwards and stack. The Invariant's "the
  clock is stable" condition therefore cannot be arranged by the harness;
  the workload has to detect it (compare a monotonic clock with wall time
  across the measured window, and skip or scope the check when they
  disagree by more than a few seconds).

## Open questions

- Is a restart delayed by the size of a backward clock step acceptable?
  (sut-analysis Q14) If yes, the bound must be scoped to "no backward clock
  step during the window" and the Sometimes stays as a coverage marker only.
  If no, the Always as written will fail under clock faults, which is the
  intended finding. `(needs human input)` — PostgreSQL core has the same
  wall-clock restart arithmetic, which suggests it is accepted practice, but
  nothing in Spock states it.

### Investigation Log

#### Is a restart delayed by the size of a backward clock step acceptable?

- Examined: `manage_apply_workers` (`src/spock_manager.c:105-131`),
  `spock_worker_detach`, PG18 `postmaster.c` bgworker restart scheduling,
  docs/FAQ.md:64, Antithesis clock-skip docs.
- Found: Spock and PG core both schedule restarts on wall time; the
  manager re-checks at least every `restart_delay_default`; Antithesis clock
  skips continue during quiet periods.
- Not found: any statement of intent about clock steps in Spock docs or
  commits.
- Conclusion: `(needs human input)`. The workload must detect clock jumps
  itself either way.

#### Does PG's bgworker notify (SIGUSR1 to `bgw_notify_pid`) set the supervisor's latch reliably on manager exit?

- Examined: PG18 `bgworker.c:483-506, 750-770`, `postmaster.c:2640-2680,
  4275-4295`, `procsignal.c:722`; Spock `spock_worker_register`,
  `wait_for_worker_startup`, `spock_worker_attach`, `spock_worker_detach`
  (`src/spock_worker.c`), `spock_supervisor_main` (`src/spock.c:903-960`).
- Found: yes for any exit after attach (flag set by detach, latch set by
  SIGUSR1). Not for a manager that dies before attach (flag never set).
- Conclusion: resolved; the 180 s concern is replaced by the narrower
  "never restarted" gap above.
