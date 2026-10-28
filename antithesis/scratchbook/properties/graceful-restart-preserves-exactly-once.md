# graceful-restart-preserves-exactly-once

## Why this property

Clean shutdown is the baseline that must be correct even if crash-restart is
not (lead L1 is about crash redo using the node id as origin). On a clean
`pg_ctl stop -m fast|smart`:

- postmaster SIGTERMs all bgworkers; apply workers leave `apply_work()` on
  `got_SIGTERM` (clearing the exception marker if mid-transaction), and exit
  with `proc_exit(0)`; open remote transactions are aborted after
  `spock_apply_worker_shmem_exit` clears the session origin (no origin advance).
- the supervisor's `before_shmem_exit` handler `spock_supervisor_on_exit`
  (`src/spock.c:878-897`) waits up to 50 x 100 ms for apply/sync workers to
  detach, then writes `PGDATA/spock/resource.dat`
  (`spock_group_resource_dump`) and an rmgr 144 SHUTDOWN record.
- the shutdown checkpoint makes replication origin progress durable
  (`CheckPointReplicationOrigin`), so the subscriber resumes from the exact
  last-applied `end_lsn`.
- walsenders on a provider being stopped send up to the shutdown checkpoint,
  then exit.

At startup: `spock_group_resource_load` (shmem startup hook) seeds
`SpockGroupHash` from `resource.dat`; supervisor
(`BgWorkerStart_RecoveryFinished`) -> manager -> apply workers; each apply
start runs `reconcile_progress_with_origin`.

Things that can go wrong in this lifecycle (from code and the leads):

- shutdown drain times out (> 5 s, e.g. worker stuck in a lock wait or
  blocking libpq call) -> `resource.dat` written while an apply worker still
  updates the hash; logged "shutdown drain timed out". Monitoring only per code
  comments, but zodan uses it.
- `resource.dat` races with a concurrent dump from a finishing table sync
  (L16; covered by `resource-dat-dumps-serialized`) -> start-up ERROR.
- feedback already told the provider "flushed" for a txn whose local commit
  was async (`synchronous_commit=off` in apply) — on clean shutdown WAL is
  flushed, so that is safe here; under crash it is not (L1 territory).

## Invariant and assertions

- Workload (Always, at quiescence after the restarted node rejoins): ledger
  exactly-once on every node for every `(origin, seq)` committed; delta
  counters equal committed increments; no `spock.exception_log` rows; every
  sub enabled. Scope: only graceful stops in this run variant (or record which
  node had which kind of stop and exclude windows touched by a kill -9). This
  separates "graceful restart is exact" from L1 (crash).
- Workload (Always): the restarted node accepts connections within a bound
  after `pg_ctl start` (V7; catches `resource.dat` load errors at shmem
  startup, which stop the postmaster).
- SUT-side (missing, no existing assertions):
  `Sometimes(spock_any_apply_worker_running())` with message
  "supervisor shutdown drain timed out with apply workers still attached" at
  `src/spock.c:891-893`, to show the slow-drain path was explored.
- No separate SUT marker for "SIGTERM at shutdown mid-transaction": inside the
  apply worker a postmaster shutdown SIGTERM looks the same as one from
  `sub_disable`. Rely on the `sub-disable-enable-cycle-loses-and-duplicates-nothing`
  Sometimes ("apply worker SIGTERM landed inside a remote transaction") for
  coverage of the mid-transaction exit.

## Antithesis angle

Graceful stop of a random node at random times under writes on all nodes,
including large transactions and while table syncs or add_node are running;
restart after a random delay; combine with partitions so the stopped node's
peers are reconnecting at the same time.

## Fault requirements

Needs a graceful-stop helper (Antithesis node termination is a hard kill).
None exists yet: the harness has not been built (only `antithesis/scratchbook/`
exists). Two workable shapes:

- A test command placed in each node container (Antithesis runs test
  commands in whatever container holds them) that runs
  `pg_ctl stop -m fast -D $PGDATA`, sleeps a random time, then
  `pg_ctl start`. The node container's entrypoint must not be the postmaster
  itself (or the container exits on stop); use a small supervisor loop that
  waits on a "stopped on purpose" flag file before restarting.
- From the workload over SQL as superuser:
  `COPY (SELECT 1) TO PROGRAM 'pg_ctl stop -m fast -D ... &'`, with the same
  supervisor loop doing the restart. Workable but harder to time.

Use `-m fast` only. Smart mode waits until every client backend is gone
(`postmaster.c:2885-2896`, `CountChildren(btmask(B_BACKEND)) == 0`), which
includes the workload and every peer's non-replication connections (Spock
sync `copy`/`cleanup` connections, Z0DAN dblink sessions), so it can wait
forever.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (implementability CW3/CW12, coverage-balance F2, antithesis-fit CW2); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 · Faults: graceful stop (test command), partition

- Evaluation note (2026-10-13): "windows touched by a kill" are found through the node wrapper's boot counter and last-exit kind, which the workload reads with `pg_read_file` (Antithesis does not announce kills).
- "No exception rows" now means none outside the expected-exception registry. The earlier note in this file about running `pg_ctl stop` through `COPY ... TO PROGRAM` is superseded: `pg_ctl` started that way is a child of a backend and gets signalled at shutdown, so the helper runs as a node-container test command.

## Implementation (2026-10-28)

- `antithesis/node/test/v1/main/parallel_driver_graceful_restart.sh`, copied
  into the node image only, so Antithesis runs it in a node container. It
  skips n4, takes a per-node lock, rolls against a per-node, per-timeline
  restart weight drawn from {0, 10, 50}% (kept in
  `/data/state/graceful_percent`) with at least 120 s between restarts,
  watches for up to {0, 2, 10} s for a ledger writer or an apply worker
  inside a remote transaction and stops when one appears, records the xids
  of those open transactions (after the restart, `pg_xact_status()` tells
  which ones the stop cut short; the reach claims count only those), writes
  a restart
  delay from {0, 1, 4, 5, 6, 30} s to `/data/state/restart_delay`, and runs
  `pg_ctl stop -m fast -W` as postgres, then waits up to 330 s (above the 5min `wal_sender_timeout` variant plus the drain) for the entrypoint's `exits.log` line for that boot and takes the exit code from it. `pg_ctl -w` is not used: with a short delay the new postmaster writes its pid file before `pg_ctl` polls again, and `pg_ctl` waits on the new one. `node-entrypoint.sh` reads and
  removes the delay after the postmaster exits, so a driver killed by an
  `eventually_` command cannot leave the node down. The driver then times
  how long the new postmaster takes to accept connections and appends a line
  to `/data/state/graceful.log`.
- Kill windows: the earlier plan used the boot counter and exit codes, but a
  backend crash (for example the ENOSPC PANIC in run
  9705b08734ec5df06d6637244b6466ed-63-13) restarts the postmaster in place
  and leaves no `exits.log` line. The check instead counts `automatic
  recovery in progress` in the server log, which every unclean stop writes.
  Any recovery on a mesh node skips the exactly-once checks for the
  timeline.
- Assertions are in `test/v1/main/eventually_mesh_barriers.py` (history read
  by `helper_restarts.py`); see the catalog entry for the list. The
  duplicate check uses oracle (2) of `ledger-row-applied-exactly-once-per-peer`:
  a redelivered ledger INSERT becomes an `insert_exists` resolution.
- SUT-side `Sometimes("supervisor shutdown drain timed out with apply
  workers still attached")` in `spock_supervisor_on_exit` (`src/spock.c`).
- Not covered yet: delta counters (no counters table in the harness), stops
  during table sync or add_node (no drivers for those), and a combined
  "partition while a peer restarts" schedule beyond what the fault injector
  does on its own.

## Open questions

- None open at the code level. The graceful-stop helper was built on 2026-10-28 (see Implementation).

Resolved (see Investigation Log): helper availability (not built; two
designs above), smart vs fast (fast only), and the provider-side wait (a
logical walsender on a stopping node waits for the subscriber's flush
confirm, bounded by `wal_sender_timeout`).

### Investigation Log

#### Is a graceful-stop helper available in the harness?

- Examined: `antithesis/` (only `scratchbook/`), `deployment-topology.md`
  (fallback section mentions `pg_ctl stop -m immediate`/kill -9 helpers only).
- Found: no harness, no helper.
- Conclusion: resolved as "must be built". Designs listed under Fault
  requirements. This is a harness task, not a SUT question.

#### Does smart shutdown wait on the workload's own sessions?

- Examined: PG18 `postmaster.c:2095-2135` (smart: stop new connections, wait
  for children), `:2885-2896` (leave PM_RUN only when no `B_BACKEND`
  remains).
- Found: smart waits for every regular client backend. Background workers
  and walsenders are not counted, but peers' plain libpq connections are.
- Conclusion: resolved. Use `-m fast`.

#### Does a logical walsender on a node being stopped wait for a paused subscriber?

- Examined: PG18 `walsender.c:3521-3550` (`WalSndDone`: exit only when
  `WalSndCaughtUp && sentPtr == flush` and nothing pending, else send a
  reply-requested keepalive); `WalSndCheckTimeOut` (terminates the walsender
  after `wal_sender_timeout` with no reply). Spock subscriber side:
  `send_feedback` on keepalive with `force = reply_requested`
  (`src/spock_apply.c:3755-3770`); with no outstanding local commits it
  reports `flush = recvpos = endpos` (`:3260-3267`).
- Found: yes. The walsender waits for the subscriber to confirm flush up to
  `sentPtr`. A live Spock subscriber confirms within one round trip (plus
  walwriter flush of its last async commit). A paused or partitioned
  subscriber holds the stop until `wal_sender_timeout` (60 s default) ends
  the walsender.
- Conclusion: resolved. Shutdown time of a provider is bounded by
  `wal_sender_timeout` plus the supervisor's 5 s drain; feed this bound into
  `fast-shutdown-completes-within-bound`.
