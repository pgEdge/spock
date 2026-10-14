# crashed-node-returns-to-streaming

## What the property says

After a node is killed (postmaster crash-restart, or container kill with the
data directory kept) and faults stop, within a fixed bound the node:

1. accepts connections (`pg_isready` / `SELECT 1`), and
2. has every enabled subscription it owns back in streaming, shown by a
   fresh `spock.sync_event()` on each provider being reached on this node
   (`CALL spock.wait_for_sync_event(...)` returns true), and
3. its own outbound subscriptions on the peers pass the same barrier.

Bound: about `restart_delay_default (5 s) + connect_timeout (30 s) +
keepalive (~25 s) + apply_idle_timeout` (120 s in the harness since the
2026-10-13 evaluation) plus crash-recovery time. Use the same bound as the reconnect
liveness checks (V1) plus 60 s for recovery.

This is the whole-instance recovery case. Single-worker restarts are covered
by `apply-worker-restarted-within-bound-after-exit`; clean restarts by
`graceful-restart-preserves-exactly-once`.

## Why: what has to go right after a crash

In order, after the postmaster restarts (sut-analysis 2.1, 3):

1. **WAL redo** with rmgr 144 registered (spock must be in
   `shared_preload_libraries`, `src/spock_rmgr.c`). Redo of applied commits
   creates node-id-numbered origin states (L1); if
   `max_active_replication_origins` has no free state, redo errors ("could not
   find free replication state slot for replication origin with ID %d",
   PG `origin.c:955`) and the startup process fails: the node does not come
   back.
2. **`StartupReplicationOrigin`** reloads checkpointed states; error if they
   no longer fit (`origin.c:798`).
3. **`shmem_startup_hook` -> `spock_group_resource_load`**
   (`src/spock_group.c:621-700`): a missing file is fine; an unreadable file
   or short read raises ERROR in the postmaster during shared memory setup,
   which stops the postmaster. No CRC, so a mixed or truncated file from
   concurrent dumps (L16, `resource-dat-dumps-serialized`) is read as data or
   fails here.
4. **Supervisor** (`BgWorkerStart_RecoveryFinished`, restart 5 s) -> manager
   per DB -> `manage_apply_workers` starts one apply worker per enabled sub.
5. **Apply start**: `replorigin_session_setup` (can also fail on a full state
   array), `spock_init_progress_state` (reconcile + `pg_commit_ts` scan of up
   to 1M xids, `src/spock_progress_recovery.c:153-380`), connect,
   `START_REPLICATION` at max(origin, provider `confirmed_flush`).
6. **Provider side**: the old walsender for this slot may still look active
   until `wal_sender_timeout` notices the dead peer; until then
   `START_REPLICATION` FATALs ("replication slot is active") and the worker
   retries every 5 s (sut-analysis 5.3; degraded but bounded by
   `wal_sender_timeout`, 5 min recommended -> set lower in the harness).
7. **Crash loops**: any condition that makes the node crash again on the
   same input repeats (example: `apply-survives-provider-clock-ahead`
   under clock skew, or the SYNCWAIT Assert in `process_syncing_tables`,
   `src/spock_apply.c:4532`, when a table resync was in flight). A crash loop
   is a failure of this property even though each single restart "works".

## Assertions

- **Workload-side:** in the quiet-period checker after faults stop,
  `Always("crashed node streams again within bound")`, one evaluation per
  restarted node per quiet period. Always fits a bounded-eventually check:
  every restart must recover in time.
- **SUT-side (missing, no existing assertions):**
  - `Reachable("spock supervisor started after crash recovery")` in
    `spock_supervisor_main` when the server came up through crash recovery
    (check `ControlFile` state or a flag set by the shmem startup hook), so a
    run shows the path was exercised.
  - `Unreachable("resource.dat load failed")` around the ERROR sites in
    `spock_group_resource_load` (open failure other than ENOENT, short read).
    Report it before the postmaster exits.
  - `Sometimes(reconcile result == STALE)` at the end of
    `reconcile_progress_with_origin` as an anchor for "post-crash progress
    reconcile ran" (see also `progress-reconcile-anomaly-unreachable`).

## Fault requirements

- Node termination (required), at random points including during apply,
  during table/initial sync, during add_node, and soon after a previous
  restart.
- Data directory must survive the kill (deployment-topology: named volume).
- A supervisor in the container that restarts postgres after the container's
  process is killed; otherwise "does not come back" is a harness artifact.

## Findings from the investigation pass (2026-10-13)

- **Worker restart after a crash-restart.** The supervisor is a static
  bgworker with `bgw_restart_time = 5` (`src/spock.c:1506-1518`), so the
  postmaster restarts it after crash recovery. Managers, apply and sync
  workers are dynamic with `BGW_NEVER_RESTART` (`src/spock_worker.c:195`),
  so PostgreSQL forgets them at a crash-restart and the supervisor rebuilds
  them (it sets `subscriptions_changed = true` at start, `src/spock.c:919`).
- **Provider-side "slot is active" window depends on the kill type.** A
  postmaster crash-restart inside a live container closes the old sockets,
  so the provider's walsender sees EOF/RST at once. A container kill takes
  the network namespace away with no FIN; the provider's walsender then
  waits for `wal_sender_timeout` (server-side TCP keepalives are OS
  defaults, about 2 h). Restarted containers may also come back with a new
  IP (Antithesis docs, "Node termination"), so DSNs must use hostnames.
- **Antithesis durability on kill is configurable, not guaranteed.** The
  Antithesis fault docs say a restarted container "may keep durably synced
  filesystem changes, or may lose all of their modified data and boot fresh
  from their image"; per-directory durability is set up with the
  forward-deployed engineer. The property is only meaningful if PGDATA is
  configured to keep fsynced writes.
- **Quiet periods do not stop clock skips** (Antithesis "Pausing faults"
  docs). Recovery timing checks must tolerate a clock jump during the wait
  (see `apply-worker-restarted-within-bound-after-exit`).

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (implementability CW12/CW8, wildcard W7); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 · Faults: node kill

- Evaluation note (2026-10-13): Antithesis may restart a node fresh from its image. The node wrapper keeps a boot counter and last-exit kind outside PGDATA, and the workload compares `pg_control_system().system_identifier` across checks; a fresh boot is reported with `Sometimes` and skipped, not asserted. With `max_active_replication_origins = 32` in the main configuration a full state array is not expected here; the small-capacity case belongs to `v2/small-capacity`.
- Open question on node termination now asks both halves: keeps fsynced writes, and drops unfsynced ones.

## Open questions

- **What recovery bound does the team expect?** No document states one;
  the FAQ's "~5 minutes" refers only to clock changes (`docs/FAQ.md:64`).
  The bound above is derived from timeouts. `(needs human input)`
- **Is a node that does not start after a crash because of a full
  replication-state array a Spock bug or a sizing error?**
  `(partial: the extra states come from L1's node-id origin states, which
  docs/sizing.md does not budget and SQL cannot drop; steady 3-node mesh fits
  in 10, node churn accumulates them; harness should use the documented
  value)`
- **Does Antithesis node termination keep PGDATA writes that were fsynced, and does it
  drop unfsynced ones (page cache)?**
  `(needs human input)` — Antithesis docs say it may or may not; ask the
  forward-deployed engineer to configure PGDATA as durable.

### Investigation Log

#### What recovery bound does the team expect?

- Examined: `docs/FAQ.md`, `docs/configuring.md` (wal_sender_timeout,
  apply_idle_timeout), `docs/recovery/catastrophic_node_failure.md`,
  `docs/spock_release_notes.md`, supervisor/manager restart code.
- Found: only component timeouts (restart 5 s, connect 30 s, keepalive
  ~25 s, apply_idle_timeout 300 s, wal_sender_timeout 5 min recommended).
  FAQ "~5 minutes" is about clock changes.
- Not found: any stated end-to-end recovery target.
- Conclusion: `(needs human input)`. Keep the derived bound.

#### Full replication-state array after crash: bug or sizing?

- Examined: `docs/sizing.md:188-203` (`max_active_replication_origins =
  max_replication_slots`, slots = `2R(N-1) + standbys + 2`, default 10
  kept), `crash-redo-leaves-no-node-id-origin-state.md` (L1 mechanism),
  grep for `replorigin_create/drop` in `src/`.
- Found: Spock creates/drops only slot-named origins
  (`src/spock_sync.c:482,1464`, `src/spock_functions.c:751,862`). The
  node-id states created by crash redo have no `pg_replication_origin` row,
  so nothing in Spock or SQL removes them; they are re-saved at every
  checkpoint. In a steady 3-node mesh (2 subscriptions + 2 node-id states)
  10 is enough; add/remove cycles with new node names add a state per new
  node id and never free them.
- Not found: any doc or code that counts node-id states.
- Conclusion: partial. The failure would be a consequence of L1, not of
  user sizing. Whether maintainers class it as a bug depends on L1's
  verdict. Harness: use the documented sizing (exposes it).

#### Does Antithesis node termination keep fsynced PGDATA writes?

- Examined: Antithesis docs "Types of faults" -> Node termination
  (`snouty docs show product/writing_tests/controlling_faults/fault_types`),
  `deployment-topology.md`.
- Found: "may keep durably synced filesystem changes, or may lose all of
  their modified data and boot fresh from their image"; custom
  per-directory durability via the forward-deployed engineer.
- Conclusion: `(needs human input)` — tenant configuration question.
