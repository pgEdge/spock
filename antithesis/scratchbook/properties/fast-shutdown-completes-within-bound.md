# fast-shutdown-completes-within-bound

## Why this property

V6 in sut-analysis: shutdown should be bounded. Code claims: the supervisor
drain is capped at 5 s "short enough to avoid blocking postmaster shutdown on
a stuck worker" (`src/spock.c:~860-875`, `spock_supervisor_on_exit`
`:878-897`). But shutdown also needs every spock worker to see SIGTERM, and
spock's SIGTERM handler only sets a flag (`handle_sigterm`,
`src/spock_worker.c:84`): it is not seen inside heavyweight-lock waits,
LWLock waits, blocking libpq calls (`PQexec` of IDENTIFY_SYSTEM /
START_REPLICATION, sync-path COPY), `pg_usleep` (apply_delay) or
`exec_cmd`'s blocking `waitpid` for pg_dump. Specific hangs:

- L11 (`sub-drop-vs-table-sync-no-deadlock`): undetectable LWLock /
  heavyweight lock cycle on `SpockCtx->lock`. `spock_worker_detach` (a
  `before_shmem_exit` callback) takes `SpockCtx->lock`, so every worker's exit
  blocks and fast shutdown never finishes.
- `spock_sync_worker_cleanup` loops without bound while the remote slot is
  active (`src/spock_sync.c:1429-1468`, `while (!got_SIGTERM)` — exits on
  SIGTERM, good, but the libpq calls inside block).
- `sub_drop`'s wait-for-apply-exit loop has no timeout but does
  `CHECK_FOR_INTERRUPTS`, so fast shutdown can cancel it.
- Initial sync running `pg_dump`/`pg_restore` against a paused or partitioned
  provider: blocking `waitpid` with no interrupt check (L32).
- Walsenders: stock PG makes a logical walsender wait for its receiver to
  confirm before exiting at shutdown; with the subscriber paused that is
  bounded by `wal_sender_timeout` (5 min recommended).

## Invariant and assertions

- Workload (Always): `pg_ctl stop -m fast` on any node returns within
  `wal_sender_timeout + 60 s`; after it returns, no postgres process from the
  old postmaster remains. Always: an unbounded shutdown is never acceptable
  (it blocks upgrades and failover scripts).
- SUT-side (missing, no existing assertions): none needed for the bound; the
  coverage markers from `graceful-restart-preserves-exactly-once` (drain
  timeout Sometimes) show the slow path was reached.

## Antithesis angle

Issue a fast stop while: a table sync is finishing (SYNCWAIT), `sub_drop` is
in progress, add_node is running pg_dump, a provider is paused (SIGSTOP), and
apply is blocked on a row lock held by a local session. CPU modulation widens
the windows.

## Fault requirements

Graceful-stop helper (same as `graceful-restart-preserves-exactly-once`),
process pause, network partition.

## Resolved findings (investigation pass, 2026-10-13)

- **The bound is `wal_sender_timeout` + margin, measured on postmaster exit,
  not on `pg_ctl`'s return code.** In stock PostgreSQL (PG18 tree checked),
  a logical walsender asked to stop calls `WalSndDone()`
  (`src/backend/replication/walsender.c:3521`), which exits only once the
  receiver has confirmed flush up to `sentPtr`; otherwise it keeps sending
  keepalives, and only `WalSndCheckTimeOut()` (wal_sender_timeout) ends the
  wait. Fast shutdown never SIGKILLs children, so this wait, and any Spock
  worker that ignores SIGTERM, delays the postmaster's exit. `pg_ctl stop`
  gives up after its own wait (60 s default, `PGCTLTIMEOUT`/`-t`) and
  reports failure while the server is still shutting down. So the workload
  must run `pg_ctl stop -m fast -t <bound>` (or poll for the postmaster PID
  to disappear) with bound = `wal_sender_timeout + 60 s`. A stop held up by a
  paused or partitioned peer for up to `wal_sender_timeout` is PostgreSQL
  core behaviour and is inside the bound; the property must not flag it.
  With `wal_sender_timeout = 0` the bound does not exist; the harness must
  keep it non-zero.
- **pg_dump/pg_restore children do get SIGTERM at postmaster shutdown.**
  Every postmaster child calls `setsid()` (`InitPostmasterChild`,
  `src/backend/utils/init/miscinit.c:141`), and `signal_child()` sends
  SIGTERM to both the child and its process group (`kill(-pid, ...)`,
  `src/backend/postmaster/postmaster.c:3469`). `exec_cmd()`
  (`src/spock_sync.c:128-151`) forks with no `setsid`/`setpgid`, so pg_dump
  is in the worker's group and dies; `waitpid` returns and `exec_cmd`
  reports failure. The pg_dump hang (L32) therefore does **not** apply to
  postmaster-driven shutdown. It still applies to Spock's own worker kills:
  `spock_worker_kill()` (`src/spock_worker.c`) does `kill(pid, SIGTERM)` on
  the worker only, so `sub_disable`/`sub_drop` during an initial sync waits
  for pg_dump to finish. That case belongs to the disable/drop properties,
  not this one.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (implementability CW3 and property finding); see `evaluation/synthesis.md`.

Current catalog line: Priority: P2 · Topology: v1 · Faults: graceful stop (test command), pause, admin churn

- Evaluation note (2026-10-13): runs as a test command inside the node container (`pg_ctl stop -m fast -t <bound>`); "no processes from the old postmaster remain" needs `ps` in the node image. The node wrapper restarts postgres afterwards.

## Implementation (2026-10-28)

- Measured on the stops of `parallel_driver_graceful_restart.sh` (node
  containers). Before the stop it records `wal_sender_timeout` and every
  process in the process group of the postmaster or of one of its
  children, whatever its name (children call `setsid()`, so a `pg_dump`
  a sync worker forks stays in that worker's group), as `pid:pgid`. It
  signals with `pg_ctl stop -m fast -W` and takes the stop time from the
  entrypoint's `exits.log` line for that boot, waiting up to 420 s (past
  the 5min variant's 360 s bound). Then it counts recorded processes still
  alive in the same group. The postmaster reaps its own children before
  exiting, so in this workload, which starts no table syncs or add_node,
  that count is 0 by construction; it guards the forked-child case.
- `eventually_mesh_barriers.py` checks every signalled stop, including on
  nodes that crashed later: `Always` within `wal_sender_timeout + 60 s`,
  `Always` no old process left, reach claim `Sometimes` slower than 5 s.
  Stops during a node pause (the driver saw a clock gap over 5 s) are not
  timed.
- Run cc5efb7fc91df5442f7ccf293e30703b-64-9 already showed one slow path:
  an apply worker in a blocking libpq call during a partition ignored
  SIGTERM past the supervisor's 5 s drain.
- Gap: a stop still hanging when the eventually command starts writes no
  record (the driver is killed and the node cannot be read). It is caught
  by the sync barrier `Always` (the node never answers), not by this
  property's.
- Not yet: stops aimed at table syncs, `sub_drop` or add_node.

## Open questions

- None remaining from discovery. (Both resolved above; the scenario list
  under "Antithesis angle" keeps "add_node running pg_dump" as a coverage
  case, but it is no longer a suspected hang.)

### Investigation Log

#### Is `wal_sender_timeout` the right bound, or `pg_ctl`'s 60 s default?

- Examined: PG18 `walsender.c` (`WalSndDone`, `WalSndLoop`,
  `WalSndCheckTimeOut`), `postmaster.c` fast-shutdown handling and
  `signal_child`; Spock `send_feedback`/`get_flush_position`
  (`src/spock_apply.c:3082-3300`); `docs/configuring.md:227-241`.
- Found: the walsender waits for receiver flush confirmation of everything
  sent, ended only by `wal_sender_timeout`. A healthy Spock subscriber
  reports `recvpos` as flushed when nothing is outstanding, so normal stops
  are quick. `pg_ctl`'s timeout only controls how long the client waits.
- Not found: any Spock-side cap on walsender shutdown (the spock output
  plugin runs inside the core walsender).
- Conclusion: resolved. Bound = `wal_sender_timeout + 60 s`, measured on
  postmaster exit. Assertion type unchanged (Always).

#### Does pg_dump's child get SIGTERM from postmaster?

- Examined: `exec_cmd` (`src/spock_sync.c:128-151`), PG18
  `miscinit.c:141` (`setsid`), `postmaster.c:3435-3475` (`signal_child`),
  `spock_worker_kill`.
- Found: same process group, postmaster signals the group for SIGTERM.
- Not found: nothing contrary.
- Conclusion: resolved. Yes at shutdown; no for Spock's own `kill(pid)`.
