# mesh-barriers-complete-after-partition-heal

## What the property says

After any mix of network partitions between subsets of the mesh (one node cut
off, a pair cut from the third, one-way loss, flapping links) and node pauses,
once faults stop, a `spock.sync_event()` issued on every node P is reached on
every other member S (`spock.wait_for_sync_event` returns true) within a fixed
bound. Spock is leaderless, so there is no quorum to lose: every ordered pair
(P, S) is its own replication channel and each must recover on its own.

## Claims

- Release notes: the apply worker "exits cleanly when the upstream connection
  dies ... and the manager respawns it from the last durably-committed remote
  LSN" (`docs/spock_release_notes.md:603-610`).
- "Subscribers reconnect automatically" (`docs/logical_slot_failover.md:310`).
- Partitioned users are told to "wait for connectivity to return"
  (`docs/recovery/catastrophic_node_failure.md`).
- `wait_for_sync_event` true means "all changes up to [LSN] on the provider
  have been received and applied" (`docs/monitoring/spock_sync_event.md`).

## Recovery path per pair (what has to work)

1. Subscriber S notices the dead link: TCP keepalive (forced by
   `spock_connect_base`, `src/spock.c:366-475`: idle 10 s, interval 5 s,
   count 3, about 25 s) when idle; with unacknowledged data in flight there is
   no `tcp_user_timeout`, so the backstop is `spock.apply_idle_timeout`
   (default 300 s; harness sets it to 120 s;
   `src/spock_apply.c:~3676-3682`).
2. The error is connection-class (08006 etc., or idle timeout tagged
   connection-class since 8dcfbcd5) -> rethrow, worker exits, manager restarts
   it after `restart_delay_default` (5 s), wall-clock based
   (`src/spock_manager.c:107-131`).
3. New connection: `connect_timeout=30`. `START_REPLICATION` fails with "slot
   is active" while the provider's old walsender still holds the slot; the
   provider only drops it after `wal_sender_timeout` (docs recommend 5 min,
   `docs/configuring.md:227-241`). Retries every ~5 s until then.
4. Stream resumes from max(origin `remote_lsn`, slot `confirmed_flush`).

Partition shapes that matter in a 3-node mesh: when n1 is cut from n2 but both
still reach n3, n3 keeps applying from both; n1 and n2 each fall behind on one
channel only. Nothing in Spock relays n2's changes to n1 through n3
(`forward_origins='{}'`), so each broken channel must heal itself; there is no
other path. The workload must check all 6 (or 12 with n4) ordered pairs.

## Assertion

Run in an `eventually_` (or `finally_`) test command, after faults stop:

- For each node P: `lsn := spock.sync_event()`.
- For each other member S: `CALL spock.wait_for_sync_event(NULL, P, lsn, <bound>, false)`.
- `Always(result is true, "sync barrier P->S completes within bound after faults heal")`
  once per ordered pair.

Always (in a quiet period) rather than Sometimes: once faults are gone, each
pair failing to recover inside the bound is a liveness bug every time. The
bound: `wal_sender_timeout + spock.apply_idle_timeout + restart_delay_default
+ connect_timeout + catch-up margin`. With harness values (wal_sender_timeout
60 s, apply_idle_timeout 120 s) about 4-5 minutes; with the doc-recommended 5 min
`wal_sender_timeout`, about 7 minutes.

`spock.sub_show_status = 'replicating'` must not be used as the success signal:
it only checks that a worker process exists and sub-level sync is READY
(`src/spock_functions.c:1437-1540`), not that data flows.

## Scope

- Exclude pairs whose subscription is disabled (`spock.subscription.sub_enabled
  = false`) and report those under the exception/disable properties; with
  `wait_if_disabled=false` the wait returns early on a disabled sub.
- Exclude pairs involving a node removed by `remove_node`, and n4 before a
  successful add_node.
- Interrupted initial or table sync (L12, L13) is expected non-liveness when it
  is visible (`sub_show_table` status not ready); record, then exclude.

## Things that can break it

- L26: blocking libpq calls with no timeout (`IDENTIFY_SYSTEM`,
  `START_REPLICATION` via `PQexec`, `src/spock.c:~626/763`); a half-open
  connection during these calls is not covered by `apply_idle_timeout`, only by
  keepalives (which do cover an idle socket).
- L22: a backward clock step after a worker exit delays its restart by about
  the step.
- L23: 1 ms respawn loops on unclassified errors.
- L11 / L12: workers stuck on `SpockCtx->lock` or waiting for a dead sync
  worker; `sub_show_status` still says `replicating`.
- `wait_for_sync_event` polls origin `remote_lsn` every 200 ms using wall time
  (`sql/spock--6.0.0.sql:685-780`); a forward clock jump can end the wait early
  with false. Re-run the barrier once before failing.

## Fault requirements

- Network partitions (symmetric and one-way), node pause. Required.
- Node termination helps (restart path), not required.
- A quiet period long enough for the bound.

## Findings from the investigation pass (2026-10-13)

- **The "slot is active" wait after a heal is usually shorter than
  `wal_sender_timeout`.** The provider's walsender times out
  `wal_sender_timeout` after the subscriber's *last reply* (PG18
  `walsender.c`, `WalSndCheckTimeOut`), not after the heal. If the
  partition lasted longer than `wal_sender_timeout`, the old walsender is
  already gone at heal time. If it was shorter, the subscriber's apply
  worker has usually already exited and closed its socket, so the next
  packet the walsender sends after the heal (data, or a keepalive at
  `wal_sender_timeout/2` without replies) is answered with a TCP reset and
  the walsender exits. The bound in this file stays as the worst case.
- **`wal_sender_timeout` is a harness choice with no correctness effect in
  Spock.** The docs recommend 5 min only to avoid disconnects while a
  subscriber is busy with a large transaction (`docs/configuring.md:227-241`);
  Spock apply code does not read it. Use 60 s in the harness for shorter
  quiet periods; a spurious disconnect under load just exercises the
  reconnect path more, which is wanted.
- **Clock skips continue during `ANTITHESIS_STOP_FAULTS` quiet periods**
  (Antithesis "Pausing faults" docs). That makes the existing advice
  (re-run the barrier once before failing, since `wait_for_sync_event`
  uses wall time) required, not optional. `eventually_`/`finally_` commands
  stop "all faults"; whether that includes clock skips is not stated.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (wildcard W1, implementability CW8/CW11); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 · Faults: partition, one-way loss, pause

- Evaluation note (2026-10-13): with `wal_sender_timeout = 60s` and `spock.apply_idle_timeout = 120s` (raised from about 30 s so an idle link is not cut between walsender keepalives, which come about every `wal_sender_timeout / 2`), the bound is about 60 + 120 + 5 + 30 s plus catch-up margin, roughly 4-5 minutes per quiet period.

## Open questions

- What recovery bound does the team consider acceptable after a partition
  heals? Sets the timeout. `(needs human input)`

### Investigation Log

#### What recovery bound does the team consider acceptable after a partition heals?

- Examined: `docs/FAQ.md:64` ("~5 minutes", about clock changes),
  `docs/configuring.md` timeout sections, `docs/logical_slot_failover.md`,
  `docs/recovery/catastrophic_node_failure.md`, release notes.
- Found: component timeouts only; no end-to-end target.
- Not found: any stated recovery time after a partition.
- Conclusion: `(needs human input)`. The derived bound stays.

#### Should the harness keep `wal_sender_timeout` at 60 s or the doc-recommended 5 min?

- Examined: `docs/configuring.md:227-241`, grep for `wal_sender_timeout`
  in `src/` (used only by the failover-slot wait, `src/spock_failover_slots.c:1565`, and in comments about feedback cadence), PG18 walsender timeout
  and keepalive logic.
- Found: the value only sets how long a provider keeps a dead walsender
  (and the shutdown wait). Spock's correctness does not depend on it.
- Conclusion: resolved as a harness decision: 60 s. The bound formula
  stays parametric in `wal_sender_timeout`.
