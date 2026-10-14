# worker-respawn-rate-bounded — Spock worker respawns stay paced

## Synthesis note

Merged from `worker-respawn-rate-bounded` (F5) and
`apply-worker-respawn-rate-bounded` (F8). Same lead (L23:
`restart_delay_on_exception` defaults to 0 and is installed on every BEGIN;
manager ERROR on bgworker-slot exhaustion is restarted with no delay).

Assertion disagreement: F5 proposed a workload log tailer
`Always(n <= 3, ...)` over 5 s windows of "exiting with error" lines; F8
proposed SUT-side `Unreachable` when one subscription's worker is registered
20 times within 10 s. Resolution: keep F5's workload `Always` as the primary
check (no SUT change, works today) but loosen nothing; keep F8's SUT-side
`Unreachable` as a second, distinctly named check that does not depend on
log parsing and counts registrations rather than exits. Windows that contain
a postmaster start or an injected kill are excluded from both. F5 confidence
medium, F8 low; merged confidence medium.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (implementability CW7/CW8); see `evaluation/synthesis.md`.

Current catalog line: Priority: P3 · Topology: v1 (capacity part: `v2/small-capacity`) · Faults: worker exit, small capacity

- Evaluation note (2026-10-13): the log tailer reads server logs through `logging_collector` and `pg_read_file`; the small-capacity part runs in the separate `v2/small-capacity` configuration.

## Open questions

None remaining (see the Investigation Log at the bottom). What the answers
changed:

- The zero `restart_delay_on_exception` was added (`fc4cf74e`, 2024) so the
  worker could restart quickly to replay a failed row. Replay is now done
  in-process (`goto stream_replay`), so data errors no longer exit the
  worker. Every exit branch in `apply_work`'s PG_CATCH sets
  `restart_delay_default` or disables the subscription. By code reading, no
  infrastructure fault in the v1 topology reaches the ~1 ms path. The
  property is a **regression guard**; keep it, priority unchanged.
- **Correction:** the manager does not respawn with no delay when
  `RegisterDynamicBackgroundWorker` fails. The failed apply slot keeps
  `terminated_at = now` and `restart_delay = restart_delay_default`, so the
  next manager waits 5 s before trying that subscription again: about one
  manager error exit per 5 s per failing subscription, which is inside the
  threshold. The no-delay manager loop needs Spock's own slot table to be full
  (`find_empty_worker_slot() == -1`), which in a single-database harness
  needs every one of `max_worker_processes` Spock slots held by a live
  worker.
- **Correction:** `spock.readonly=all` does not drive the FATAL at
  `src/spock_apply.c:2982` (that FATAL is unreachable; see
  `readonly-all-never-commits-remote-txn`). Under readonly=all the worker
  stays alive and reconnects every `apply_idle_timeout` with the 5 s default
  delay. SIGTERM / `pg_terminate_backend` give a clean exit ("detaching
  cleanly"), not an error exit.
- Remaining ~1 ms sources, all rare: the protocol-violation FATAL
  "incorrect spock message" (`:2928`), and an ERROR raised inside
  `apply_work`'s PG_CATCH itself before a pacing branch runs (for example a
  failing exception-log or disable write). The L27 loop (SUB_DISABLE disable
  rolled back) exits cleanly, so the "exiting with error" counter does not
  see it; it is paced only by the manager's poll interval or latch.

## Source: `worker-respawn-rate-bounded` (F5 Resources)

### Summary

Spock restarts its own workers. The manager restarts apply workers at
`terminated_at + restart_delay` (`manage_apply_workers`,
`src/spock_manager.c:39-160`). The supervisor restarts managers as soon as
`subscriptions_changed` is set (`src/spock.c:787-855, 940-960`). Several paths
set the delay to zero or skip it entirely, so a fault that persists becomes a
tight respawn loop. Each loop iteration costs a bgworker fork, a database
connection, a provider connection with a walsender fork on the peer, and log
volume. In a simulator this also burns the time budget and can hide other work.

Paths (HEAD 69d9228f):

- `handle_begin` sets `restart_delay = restart_delay_on_exception` (default
  **0**, `src/spock_apply.c:676`) on every BEGIN. The manager clamps this to
  `SPOCK_RESTART_MIN_DELAY = 1 ms` (`include/spock.h:38`;
  `src/spock_manager.c:155-159`). Any exit after a BEGIN that does not go
  through a branch that resets the delay respawns after about 1 ms:
  - FATAL sites that skip `PG_CATCH`: `"incorrect spock message"` (`:2928`),
    the read-only FATAL (`:2982`, unreachable by code reading),
    `spock_start_replication` FATAL (before the first BEGIN, so it keeps
    the default delay).
  - The successful-replay and SUB_DISABLE paths set `restart_delay = 0`
    explicitly (`:954, 1049, 1081`).
  - Commit `f3d4935e` measured 83 restarts per second before transient errors
    were paced. Transient branches now reset to `restart_delay_default`
    (`:448-452, 3929-3938`).
- `spock_worker_register` failure (no Spock slot, or
  `RegisterDynamicBackgroundWorker` false when PG's `max_worker_processes` is
  used up by parallel query or other extensions) raises ERROR **inside the
  manager** (`src/spock_worker.c:136-141, 195-204`). Manager error exit sets
  `subscriptions_changed` (`:455-458`), the supervisor is woken through
  `bgw_notify_pid`, and a new manager starts at once. *(Corrected after
  investigation:)* for the `RegisterDynamicBackgroundWorker` case the apply
  slot was already claimed with `restart_delay = restart_delay_default` and
  gets `terminated_at = now` (`:155-159, 197-198`), so the new manager's
  `manage_apply_workers` waits 5 s before retrying (`src/spock_manager.c:104-130`).
  Only the "no Spock slot" case (`find_empty_worker_slot() == -1`) loops with
  no delay.
- Manager timing uses wall-clock `terminated_at` (L22). A backward clock step
  delays restarts but does not speed them up. Out of scope here.

A whole-instance crash restart (SIGKILL of any backend) also restarts every
worker. That is fault-driven and must be excluded from the count.

### Property

Outside postmaster restarts, no Spock worker for the same subscription (or the
same database's manager) exits with an error more than a small number of times
within any `restart_delay_default` window.

### Assertions (all missing)

1. Workload-side (log tailer) `Always(n <= 3, "apply worker error exits per
   subscription per 5 s window")`: count `apply worker [pid] at slot N
   generation G exiting with error` lines (`src/spock_worker.c:431-435`) per
   subscription. Map slot to subscription via the preceding
   `SPOCK <sub>: connected` line or `spock.sub_show_status`. Skip windows that
   contain a postmaster start (`database system is ready to accept
   connections`) or a SIGKILL injected by the harness on that node.
2. Workload-side `Always(n <= 3, "manager error exits per database per 5 s
   window")` on `manager worker [...] exiting with error` lines.
3. SUT-side `Sometimes(restart_delay == 0 at error exit, "apply worker exiting
   with zero restart delay")` in `spock_worker_detach(crash=true)`. This
   reachability marker shows which fault reaches the 1 ms path, so the run log
   explains any firing of (1).

`Always` over a sliding window fits: pacing is a guarantee on every window, not
an eventual condition.

### Fault requirements

- ~~`spock.readonly=all` toggled while transactions are in flight (FATAL at
  `:2982`).~~ Not a source: that FATAL is unreachable, and readonly=all leads
  to paced idle-timeout reconnects instead (see Investigation Log).
- `pg_cancel_backend` / SIGINT on apply workers (57014) goes to in-process
  replay (L5), not to an exit, so it is not a respawn source. Protocol
  corruption is the remaining unpaced FATAL. A plain partition should stay paced (connection
  class), which makes it a good negative control.
- Config variant: PG `max_worker_processes` small, plus workload parallel
  queries (`max_parallel_workers_per_gather > 0` on large scans) that use up
  bgworker slots while subscriptions restart.

### Original open-question notes (detail for the combined list above)
- Is the 1 ms respawn after an unclassified error intended (the GUC default of
  0 suggests "retry the failed transaction quickly")? If yes, the threshold in
  (1) needs to allow it for data errors and flag only FATAL-driven loops.
- Should a manager that cannot register an apply worker back off instead of
  exiting? If the loop is intended, (2) belongs in a config-limits note, not a
  bug.

## Source: `apply-worker-respawn-rate-bounded` (F8 Lifecycle)

### Why this property

Restart pacing is set per worker in `MySpockWorker->restart_delay`:

- registration: `restart_delay_default` (5000 ms, `src/spock_worker.c:158`);
- first BEGIN: `restart_delay_on_exception` (default **0**, `handle_begin`,
  `src/spock_apply.c:676`);
- transient branches (connection, deadlock/lock timeout, class 53) reset to
  default (`:452`, `:3938`); exception-replay entry uses default (`:845`);
- successful TRANSDISCARD / skip / SUB_DISABLE paths set 0 (`:954`, `:1049`,
  `:1081`).

The manager clamps to `SPOCK_RESTART_MIN_DELAY = 1 ms`
(`include/spock.h:38`, `src/spock_manager.c:~175`). So any **persistent**
failure that exits the worker after its first BEGIN without going through a
pacing branch respawns about every millisecond (lead L23). `f3d4935e`
measured 83 restarts per second before pacing was added for the known cases.
Remaining candidates: FATAL paths mid-transaction (`handle_message` "incorrect
spock message"), ERRORs raised outside `apply_work`'s PG_TRY after the first
BEGIN, and a manager that ERRORs in `spock_worker_register` (no slot) being
respawned by the supervisor with no delay.

This is a lifecycle liveness/safety hybrid: a hot respawn loop burns CPU,
floods logs, and (with a stale exception marker) can repeat the exception
policy each time.

### Invariant and assertions

- SUT-side (missing, no existing assertions): in `manage_apply_workers`, keep
  a small per-subid ring buffer of registration timestamps (manager-local
  memory). `Unreachable("apply worker for one subscription registered 20 times within 10 s")`.
  Unreachable because with the documented pacing (`restart_delay_default` for
  every transient class) such a rate is never the intended behaviour.
- SUT-side (missing): `Unreachable("supervisor re-registered a manager 20 times within 10 s")`
  in `start_manager_workers`.
- Workload fallback: count "starting apply worker" / "worker ... exiting with
  error" log lines per sub per 10 s window if logs are collected.

### Antithesis angle

Faults that produce persistent errors: provider stuck in crash recovery
(57P03 is paced), provider with the slot missing (see
`enabled-subscription-always-has-provider-slot`), process pause of the provider
during START_REPLICATION, disk-full on the subscriber.

### Fault requirements

Node termination / restart of providers, network partitions, process pause.
Nothing exotic; the question is which persistent error classes exist.

### Original open-question notes (detail for the combined list above)
- Is a 1 ms respawn loop acceptable for any error class? (sut-analysis Q14.)
  If some are intentional (e.g. after a successful TRANSDISCARD the worker
  keeps running, so 0 is harmless there), the threshold stays; if the team
  says any rate is acceptable, drop the property.
- Which persistent errors happen after the first BEGIN in the v1 topology? If
  none, the property only guards regressions (still cheap).

### Investigation Log

#### Is the ~1 ms respawn after an unclassified error intended for any error class?

- Examined: `git show fc4cf74e` (introduced `restart_delay_on_exception`),
  `src/spock.c:1327-1351` (GUC definitions), `src/spock_apply.c:660-680`
  (`handle_begin`), `:836-846`, `:940-960`, `:1040-1085`, `:3867-4135`
  (every PG_CATCH branch), `:4793-4800` (exit after `apply_work`).
- Found: the commit message says the zero delay "will be used in case the
  apply-worker was attempting a row operation. This allows for very fast
  exception handling", which is from when exception handling meant a
  restart. At HEAD, a first-time data error goes to in-process replay
  (`need_replay`, `goto stream_replay`), so it does not exit. Exit branches:
  connection class, deadlock/lock timeout and class 53 set
  `restart_delay_default`; the replay BEGIN sets `restart_delay_default`
  (`:845`) before "error during exception handling" can rethrow; SUB_DISABLE
  disables the subscription (the manager skips disabled subscriptions).
- Not found: any statement that a 1 ms respawn is wanted for errors that do
  exit.
- Conclusion: resolved: the zero delay was meant for restart-based row
  replay, which no longer exists. The threshold does not need to allow data
  errors. Keep the property as a regression guard.

#### Should a manager that cannot register a worker back off instead of exiting?

- Examined: `src/spock_worker.c:101-205` (`find_empty_worker_slot`,
  `spock_worker_register`), `:440-470` (`spock_worker_detach`),
  `src/spock_manager.c:39-175` (`manage_apply_workers`),
  `src/spock.c:788-960` (supervisor), `src/spock_shmem.c:132-159`
  (`total_workers = max_worker_processes`).
- Found: for `RegisterDynamicBackgroundWorker` failure the claimed apply slot
  gets `terminated_at` and the default delay before the ERROR, and the next
  manager honours it. So the manager already backs off, at one error exit
  per `restart_delay_default` per failing subscription. With no free Spock
  slot no slot is marked and the supervisor restarts the manager at once,
  which retries at once. Terminated slots are reusable only by the same
  database (`:109-112`), so this needs either all slots held by live workers
  or multiple databases.
- Conclusion: resolved: back-off already happens for the realistic case
  (PG bgworker slots used up). The no-delay case needs Spock's slot table
  to be full, which the single-database harness will not reach. The
  small-`max_worker_processes` config variant is expected to stay within
  `n <= 3` per 5 s; if the manager assertion fires there, it is a real
  finding.

#### Which persistent errors happen after the first BEGIN in the v1 topology?

- Examined: the PG_CATCH classifier (`src/spock_apply.c:3867-4135`), FATAL
  sites (`:2928`, `:2982`), SIGTERM handling (`src/spock_worker.c:83-93`,
  `src/spock_apply.c:4140-4160`, `:4793-4800`), the readonly loop
  (`:3600-3631`), `process_syncing_tables` call (inside the PG_TRY),
  PG `ProcessRecoveryConflictInterrupt` behaviour for
  `terminate_active_transactions` (40001 ERROR in a transaction).
- Found: infra faults (partition, provider restart, pause, disk full)
  produce connection-class or class 53 errors, which are paced. Query
  cancel (57014) and recovery-conflict cancel (40001) go to in-process
  replay (L5 territory), not to an exit. SIGTERM is a clean exit. The
  readonly FATAL cannot be reached. What is left is the protocol FATAL
  "incorrect spock message" and errors raised inside the PG_CATCH itself.
- Not found: a persistent, fault-driven error that exits with delay 0 in the
  v1 topology. Not checked at runtime.
- Conclusion: resolved: none known. The property only guards regressions
  (still cheap). The `Sometimes(restart_delay == 0 at error exit)` marker
  (assertion 3) is expected to be rarely or never hit; treat it as a
  diagnostic, not a coverage goal.
