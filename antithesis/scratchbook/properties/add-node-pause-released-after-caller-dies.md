# add-node-pause-released-after-caller-dies — Apply on the source resumes within pause_timeout after the pausing caller dies

## Origin

Evaluation gap (b) / coverage-balance F9. Claim V3 (sut-analysis §7): the
comment in the sync worker's error path, "If the connection is broken this
will fail silently — the workers' CV timeout will recover them"
(`src/spock_sync.c:1636-1640`). L4(e): the pause is not tied to the caller's
session. `add-node-pause-held-until-progress-read` checks the other direction
(resumed too early while the caller is alive).

## Code paths (HEAD 69d9228f)

- Caller: the n4 sync worker during initial sync (`SYNC_STATUS_INIT` branch,
  `src/spock_sync.c:1553-1650`) calls `spock_create_slot_and_read_progress`
  (`:649-865`). Over `origin_conn` (a normal backend on the provider) it runs
  `SELECT spock.pause_apply_workers()` (`:704`), then
  `CREATE_REPLICATION_SLOT` on a second replication connection (`:719`), then
  imports the snapshot and reads peer progress, then
  `SELECT spock.resume_apply_workers()` (`:857`, WARNING only on failure). On
  ERROR, PG_CATCH resumes only if `origin_conn` is still `CONNECTION_OK`
  (`:1641-1648`). Every initial sync does this, not only add_node.
- Provider side: `spock_pause_apply_workers` (`src/spock_functions.c:4060-4126`)
  sets the instance-wide `SpockCtx->pause_apply = 1`, waits up to
  `spock.pause_timeout` for apply workers to be between transactions, and on
  its own timeout clears the flag and raises. `spock_resume_apply_workers`
  (`:4135-4144`) clears and broadcasts `pause_cv`.
- Worker side: `maybe_pause_for_slot_creation` (`src/spock_apply.c:564-586`),
  called from `begin_replication_step` before a new transaction. If the flag is
  set, the worker sleeps on `pause_cv` with `ConditionVariableTimedSleep(...,
  spock_pause_timeout * 1000)`. On timeout it logs WARNING "apply worker pause
  timed out after %ds, resuming", writes 0 to the flag, and goes on. It does
  **not** broadcast, so other sleeping workers each wait out their own
  timeout. `ConditionVariableTimedSleep` measures with `INSTR_TIME`
  (monotonic), so wall-clock skips do not stretch it.
- `spock.pause_timeout` is USERSET, 1 .. INT_MAX/1000 s, default 10
  (`src/spock.c:1353-1366`). Each worker uses its own session value (from
  `postgresql.conf`), not the caller's.
- Sync workers in catch-up on the provider use `apply_work` too, so they pause
  the same way.

## What the bound is

Each provider apply worker that reaches `begin_replication_step` while the flag
is set resumes within its own `pause_timeout` of starting to sleep. So after
the caller dies, every provider apply worker commits its next remote
transaction within about `pause_timeout` plus normal apply latency. Nothing
clears the flag if no worker has work: an idle provider keeps
`pause_apply = 1` indefinitely after a dead caller, and the next remote
transaction that arrives (minutes or hours later) stalls that worker for one
more `pause_timeout`. Bounded, but the flag itself is not a usable oracle.

Code reading found no path to an unbounded pause: a worker SIGTERMed while
sleeping exits, its replacement sees the flag, sleeps one full timeout, and
clears it; postmaster crash-restart re-initialises the flag to 0
(`src/spock_shmem.c:160`). The property is a regression guard for V3.

Risk worth noting for operators: the errhint at
`src/spock_functions.c:4120` says to raise `spock.pause_timeout` when add_node
fails. If an operator raises it in `postgresql.conf` (to minutes), a dead
caller stalls inbound apply on the source for that long.

## Ways the caller dies with the flag set

- n4 node termination while its sync worker is between `:704` and `:857`.
- Partition between n4 and src during slot creation: n4's `PQexec` on the
  replication connection fails after keepalive detection (spock_connect sets
  keepalives), PG_CATCH finds `origin_conn` broken, no resume.
- `pg_terminate_backend` of the provider-side backend that ran the pause
  (application_name contains the sub name and "snap"): resume then fails on
  the n4 side. This is the cheapest workload-driven trigger.
- Note: in the partition case the provider-side backend stays alive (idle in
  ClientRead) until server TCP keepalive notices, which with OS defaults is
  about 2 h, because the server does not set `tcp_keepalives_*`. So "the
  pausing backend is still alive" is not the same as "the caller is still
  proceeding" (see the extension note on `add-node-pause-held-until-progress-read`).

## Making the window reachable

The window between pause and resume is milliseconds unless slot creation is
slow. The workload holds an xid-assigned transaction open on src across
add_node Phase 5 (as recommended for `add-node-pause-held-until-progress-read`):
`CREATE_REPLICATION_SLOT` waits for it, and the walsender's query in
`pg_stat_activity` on src shows `CREATE_REPLICATION_SLOT` for the sync slot.
While that is visible, the pause has been called and not yet released: the
workload kills the caller then (one of the triggers above), and only then ends
its long transaction.

## Workload / oracle design

- Precondition marker: `Sometimes("pausing caller killed while provider
  CREATE_REPLICATION_SLOT was in progress")`, emitted when the workload issued
  the kill while the slot creation was visible on src.
- Check: right after the kill, insert a marker row on each peer X != src (and
  keep the normal write load running), then wait for each marker on src.
  `Always(every peer's marker is visible on src within pause_timeout +
  apply-latency margin after the caller was killed, "provider apply resumes
  within pause_timeout after the pausing caller dies")`. Use the harness's
  `pause_timeout` (10 s default, or 1 s if the harness lowers it for the L4
  property) and a margin of a few seconds. Only score timelines where no
  partition/pause between X and src is active during the window (the
  workload's own kill is not an Antithesis fault; run in a quiet period, or
  skip the check if Antithesis faulted X or src in the window).
- Clock skips do not affect the SUT side (monotonic) but do affect the
  workload's wall clock: measure the window with a monotonic clock.

## Instrumentation (all missing)

- Shares the instrumentation proposed for
  `add-node-pause-held-until-progress-read`: record the pausing backend's PID
  in `SpockCtx` in `spock_pause_apply_workers`. In the worker timeout branch,
  `Reachable("apply worker self-resumed after the pausing caller was gone")`
  when `BackendPidGetProc(owner_pid) == NULL`. Distinct message from the P0
  property's `Unreachable` for the alive case.
- Optional `Sometimes(pause_apply still set when a worker entered
  maybe_pause_for_slot_creation more than pause_timeout after the last pause
  call, "stale pause flag stalled an idle-then-busy apply worker")`: shows the
  "idle provider keeps the flag" state is explored.

## Open questions

- Is a stale flag on an idle provider (one extra `pause_timeout` stall on the
  next remote transaction, possibly hours later) acceptable, or should the
  flag be tied to the caller's session (cleared at backend exit)? Does not
  change the assertion; decides whether the companion `Sometimes` is a finding.
