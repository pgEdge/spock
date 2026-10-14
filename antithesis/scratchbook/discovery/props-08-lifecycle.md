---
sut_path: /home/msharp/dev/pgedgea/spock
commit: 69d9228f5df363761dc3ae6eebf7e2fcfe49b8e5
updated: 2026-10-13
external_references: []
---

# Property discovery — focus 8: lifecycle transitions

Lens: startup, shutdown, worker restart, subscription enable/disable/drop,
initial sync phases, add_node ordering after restarts, read-only mode
toggling, extension upgrade. All SUT-side assertions suggested here are
**missing** (the tree has no Antithesis instrumentation,
`existing-assertions.md`).

## Category A — Operator lifecycle on a live subscription

Disabling, enabling, altering and dropping subscriptions while all nodes
write. Every one of these SIGTERMs the apply worker at an arbitrary point in
its stream, which is exactly where the exception-marker bugs keep coming
from.

### sub-disable-enable-cycle-loses-and-duplicates-nothing — Disable/enable/alter cycles under load lose and duplicate nothing

| | |
|---|---|
| **Type** | Safety |
| **Property** | Any sequence of `sub_disable` (immediate or not), `sub_enable` and other `sub_alter_*` calls on live subscriptions, followed by re-enabling them all, leaves every node with exactly one copy of each committed ledger row, exact delta counters, no `spock.exception_log` rows and all subscriptions enabled. |
| **Invariant** | Workload `Always` at quiescence after the last enable: per-`(origin, seq)` exactly-once on every node, delta totals equal committed increments, `exception_log` empty (conflict-free workload), `sub_enabled = true` for every sub the workload left enabled. `Always` because loss or duplication from an operator action is never acceptable. Coverage marker (missing, SUT-side): `Sometimes(in_remote_transaction)` "apply worker SIGTERM landed inside a remote transaction" at the `got_SIGTERM` clear site at the end of `apply_work()`. |
| **Antithesis Angle** | `alter_subscription()` kills the worker at COMMIT via `signal_worker_xact_callback`; Antithesis decides where in a (large) remote transaction the SIGTERM lands, and whether it coincides with a reconnect, a lock wait or `handle_commit`. Tests the `ed0a9945` and `db380dd8`/TAP 105 fixes against nearby timings. |
| **Why It Matters** | Two recent fixes in this exact path (spurious SUB_DISABLE / silent TRANSDISCARD of a retransmitted transaction). A miss means a routine operator action silently drops a transaction on one node. |

**Open Questions:**

- Can a replacement worker start while the old one still holds the origin session, and can that ever happen after a BEGIN? `(partial: slot is freed before origin cleanup, but the setup error is raised before PG_TRY and before any BEGIN, so it is a paced restart)`

Confidence: high
Evidence file: properties/sub-disable-enable-cycle-loses-and-duplicates-nothing.md

### exception-replay-only-after-recorded-error — A restarted worker enters exception replay only for a transaction that really failed

| | |
|---|---|
| **Type** | Safety |
| **Property** | When `handle_begin()` matches the shmem exception marker's `commit_lsn` and switches to exception replay, the marker always carries the initial error recorded by a real failure. |
| **Invariant** | SUT-side (missing) `Unreachable("exception replay entered without a recorded initial error")` in `handle_begin()` case 4 when `initial_error_message[0] == '\0'`. `Unreachable` because a match with an empty message means a lifecycle exit (FATAL, sync worker sharing the slot, a new exit path) left a stale marker from a plain BEGIN. Companion `Unreachable("apply worker readonly FATAL in replication_handler")` at `src/spock_apply.c:2982`, which code reading says cannot be reached with default slot names. |
| **Antithesis Angle** | Graceful worker exits, cancels, network drops and readonly toggles at random points; table resync in a later variant reaches the apply/sync shared-marker case (L15). Postmaster kills wipe shmem and do not reach it. |
| **Why It Matters** | Eleven past fixes in the classifier/marker; each missed exit path turned a restart into a silently discarded (TRANSDISCARD) or disabled (SUB_DISABLE) transaction. This assertion catches the whole class at its source, not just the paths already known. |

**Open Questions:**

- Which other FATAL / `proc_exit` sites are reachable mid-transaction in apply?
- Does a table-sync worker's last stamped `commit_lsn` ever equal the apply worker's first BEGIN after a restart (needs `sub_resync_table` in the workload)?

Confidence: medium
Evidence file: properties/exception-replay-only-after-recorded-error.md

### enabled-subscription-always-has-provider-slot — An enabled subscription never loses its provider slot

| | |
|---|---|
| **Type** | Safety |
| **Property** | In a quiet period with all nodes up, every enabled, READY subscription has its replication slot on its provider. |
| **Invariant** | Workload `Always` per subscription row (`sub_enabled`, sync status READY) that `pg_replication_slots` on the provider contains `sub_slot_name`. `Always` because an enabled sub without a slot never recovers by itself. `Sometimes("orphan slot found for a dropped subscription")` records the documented leak path. Coverage marker (missing, SUT-side): `Reachable("sub_drop dropped remote slot before local commit")`. |
| **Antithesis Angle** | `spock_drop_subscription` drops the remote slot over a new connection before the local transaction commits. A kill of the subscriber node or the `sub_drop` / `remove_node` session in that window rolls back the catalog delete but not the slot drop. |
| **Why It Matters** | The result is a subscription that retries START_REPLICATION every 5 s forever with no exception row: permanent silent divergence that needs an operator. `remove_node` hits the same code on every peer. |

**Open Questions:**

- Is dropping the remote slot before the local commit a deliberate trade-off (orphan slot vs enabled sub without slot)?
- Does any monitoring show "slot missing" to the operator?

Confidence: medium
Evidence file: properties/enabled-subscription-always-has-provider-slot.md

## Category B — Worker restart and pacing

### apply-worker-restarted-within-bound-after-exit — A dead apply worker comes back within a bound

| | |
|---|---|
| **Type** | Liveness |
| **Property** | After any apply-worker exit for an enabled subscription with a reachable provider, a new worker is running and `replicating` within `restart_delay_default + connect_timeout + margin`. |
| **Invariant** | Workload `Always` in a quiet period: measured gap between "no worker / not replicating" and "worker present and replicating" is within the bound. Coverage markers (missing, SUT-side): `Sometimes(restart_time - now > 2 * restart_delay)` "manager deferred apply restart by more than twice restart_delay"; `Reachable("manager restarted crashed apply worker")` and `Reachable("manager restarted cleanly exited apply worker")` as two distinct outcomes. |
| **Antithesis Angle** | Restart time is `terminated_at + restart_delay` on wall clock; a backward clock step after an exit defers the restart by about the step (L22). Clean exits are not signalled to the manager. Admin calls holding the local-node lock stall the manager. Kills, terminates, partitions and clock steps explore these. |
| **Why It Matters** | Spock claims workers are restarted (V2). A sub that stays down silently grows lag and pins WAL on the provider. |

**Open Questions:**

- Is a restart delayed by the size of a backward clock step acceptable?
- Does the bgworker notify reliably wake the supervisor when a manager crashes, or can a DB be without a manager for up to 180 s?

Confidence: medium
Evidence file: properties/apply-worker-restarted-within-bound-after-exit.md

### apply-worker-respawn-rate-bounded — No hot respawn loop for apply workers or managers

| | |
|---|---|
| **Type** | Safety |
| **Property** | No subscription's apply worker, and no database's manager, is re-registered 20 times within 10 seconds. |
| **Invariant** | SUT-side (missing) `Unreachable("apply worker for one subscription registered 20 times within 10 s")` in `manage_apply_workers` (per-subid ring buffer of registration times), and `Unreachable("supervisor re-registered a manager 20 times within 10 s")` in `start_manager_workers`. `Unreachable` because the documented pacing never produces that rate. |
| **Antithesis Angle** | `restart_delay_on_exception = 0` is installed on the first BEGIN and only the known transient branches restore the 5 s default; any persistent exit after a BEGIN that skips them respawns every ~1 ms (L23). Persistent provider faults, disk-full, worker-slot exhaustion explore it. |
| **Why It Matters** | A 1 ms loop burns CPU and floods logs (`f3d4935e` measured 83/s); combined with a stale marker it repeats the exception policy each time. |

**Open Questions:**

- Is a 1 ms respawn acceptable for any error class?
- Which persistent errors happen after the first BEGIN in the v1 topology?

Confidence: low
Evidence file: properties/apply-worker-respawn-rate-bounded.md

## Category C — Node shutdown and restart

### graceful-restart-preserves-exactly-once — A graceful stop and restart of any node loses and duplicates nothing

| | |
|---|---|
| **Type** | Safety |
| **Property** | Across `pg_ctl stop -m fast` and restart of any node under writes, every node ends with exactly one copy of each committed ledger row, exact delta counters, no exception rows, all subs enabled, and the restarted node accepts connections within a bound. |
| **Invariant** | Workload `Always` at quiescence (only graceful stops in this variant, or windows touched by a kill excluded). `Always` because the shutdown checkpoint makes origins durable, so even if crash restart is not exact (L1), graceful restart must be. Coverage marker (missing, SUT-side): `Sometimes(spock_any_apply_worker_running())` "supervisor shutdown drain timed out with apply workers still attached" at `src/spock.c:891`. |
| **Antithesis Angle** | Stops at random points: mid large transaction, during table sync or add_node, while peers reconnect. Exercises the SIGTERM path, the 5 s supervisor drain, `resource.dat` dump/load and reconcile at apply start. |
| **Why It Matters** | Baseline correctness for upgrades and maintenance; separates "restart is broken" from "crash redo is broken" (L1), which otherwise look the same in a failing run. |

**Open Questions:**

- Is a graceful-stop helper available in the harness? Without it this property never runs.
- Does a logical walsender on a stopping node wait for a paused subscriber to confirm?

Confidence: medium
Evidence file: properties/graceful-restart-preserves-exactly-once.md

### fast-shutdown-completes-within-bound — Fast shutdown finishes within a bound

| | |
|---|---|
| **Type** | Liveness |
| **Property** | `pg_ctl stop -m fast` on any node returns within `wal_sender_timeout + 60 s` and leaves no processes from the old postmaster. |
| **Invariant** | Workload `Always` on each graceful stop: elapsed time within the bound and no leftover processes. `Always` because an unbounded shutdown is never acceptable. |
| **Antithesis Angle** | Spock's SIGTERM handler only sets a flag, so exit depends on every worker reaching a check: lock waits, LWLock cycles (L11), blocking libpq and pg_dump `waitpid` can hold shutdown. Antithesis issues stops while syncs finish, `sub_drop` runs, providers are paused and apply waits on local row locks. |
| **Why It Matters** | A stuck shutdown blocks upgrades, failover scripts and container restarts; L11 would make it permanent. |

**Open Questions:**

- Should the bound include `wal_sender_timeout` (stop blocked by a paused peer counted as acceptable)?
- Does pg_dump's child get postmaster's SIGTERM?

Confidence: medium
Evidence file: properties/fast-shutdown-completes-within-bound.md

## Category D — Read-only mode transitions

### readonly-all-never-commits-remote-txn — No remote transaction commits while readonly=all is in effect

| | |
|---|---|
| **Type** | Safety |
| **Property** | While `spock.readonly = all` is in effect in an apply or sync worker, that worker never commits a replicated transaction or COPY. |
| **Invariant** | SUT-side (missing) `AlwaysOrUnreachable(spock_readonly != READONLY_ALL)` "apply committed a remote transaction while spock.readonly=all" before `CommitTransactionCommand()` in `handle_commit()`, plus its own message for the sync worker's COPY commit. `AlwaysOrUnreachable` because it must hold on every commit evaluated under readonly. Workload cross-check: remote-origin ledger rows on that node do not grow after a settle time; non-superuser writes fail with 25006. |
| **Antithesis Angle** | Toggles readonly at random points relative to remote transactions, exception replay, initial sync on n4 and table-sync catch-up. The GUC is re-read only at reload points, so the interleaving of SIGHUP with the apply loop matters. |
| **Why It Matters** | Docs promise readonly=all stops apply (S8); operators rely on it for maintenance windows. Note that superusers bypass the local check, which the workload must account for. |

**Open Questions:**

- Is initial sync (COPY into the new node) meant to be blocked by readonly=all?
- Is the readonly FATAL in `replication_handler` reachable at all with default slot names?

Confidence: medium
Evidence file: properties/readonly-all-never-commits-remote-txn.md

### readonly-toggle-resumes-without-loss — Leaving readonly mode resumes replication without loss or duplicates

| | |
|---|---|
| **Type** | Safety |
| **Property** | After `spock.readonly` returns to `off` on every node, replication resumes and every node ends with exactly one copy of each committed ledger row, exact delta counters, no exception rows and all subs enabled. |
| **Invariant** | Workload `Always` at quiescence after readonly windows end. Coverage markers (missing, SUT-side): `Sometimes(in_remote_transaction)` "apply loop stopped for readonly=all inside a remote transaction" at the readonly `break`; `Reachable("apply idle timeout fired while readonly=all")`. |
| **Antithesis Angle** | A readonly window drives a chain of lifecycle events: mid-transaction stop with locks held, `apply_idle_timeout` reconnect loop (fixed as connection-class only in `8dcfbcd5`, HEAD~4), walsender timeout, then resume and retransmit. Random window lengths plus partitions and provider restarts explore it. |
| **Why It Matters** | Docs promise lossless resume. The idle-timeout classification was misfiled as a data error until four commits ago, which would have discarded a real transaction on every long readonly window. |

**Open Questions:**

- Is the reconnect churn every `apply_idle_timeout` under readonly intended?

Confidence: high
Evidence file: properties/readonly-toggle-resumes-without-loss.md

## Category E — Initialization and add-node ordering

### initial-sync-ends-ready-or-visibly-disabled — Initial sync ends READY or visibly disabled, never stuck

| | |
|---|---|
| **Type** | Liveness |
| **Property** | Every subscription that starts initial sync ends, after faults stop, either enabled with sync status `r` and `replicating`, or disabled with a "nonrecoverable step" record or a raised add_node error; never enabled and stuck in `i`/`s`/`d`/`c`/`u`. |
| **Invariant** | Workload `Always` at the end of a quiet period of at least `spock.sync_timeout + apply_idle_timeout`. Coverage markers (missing, SUT-side): `Reachable("initial sync restarted from INIT after a previous attempt")`, `Reachable("initial sync interrupted in nonrecoverable step; subscription disabled")`; guard `Unreachable("initial sync COPY started with sync status past DATA")`. |
| **Antithesis Angle** | Kills, partitions and pauses during each phase of add_node's src -> n4 sync: slot creation, pg_dump, COPY, post-data, catch-up; `sub_disable` mid-COPY (sync code ignores SIGTERM until it finishes). |
| **Why It Matters** | Interrupted sync becoming disabled is documented; a hang or a silent half-state is not, and pg_dump / blocking libpq without timeouts make a hang plausible. |

**Open Questions:**

- What is the intended operator recovery after a nonrecoverable-step disable?
- Can pg_dump (raw DSN, no keepalives) hang after a healed partition?

Confidence: medium
Evidence file: properties/initial-sync-ends-ready-or-visibly-disabled.md

### add-node-after-peer-restart-captures-every-peer — add_node right after a source restart still captures every peer

| | |
|---|---|
| **Type** | Safety |
| **Property** | A successful add_node never falls back to a peer's current WAL position for that peer's catch-up point, including when the source node restarted shortly before. |
| **Invariant** | Workload `Unreachable` on success: no add_node NOTICE containing "falling back to pg_current_wal_lsn()". SUT-side (missing): `Always(rows == expected)` "read_peer_progress returned every peer of the source" in `spock_create_slot_and_read_progress`. `Unreachable` because a guessed catch-up point on a successful add silently skips transactions. |
| **Antithesis Angle** | `read_peer_progress` inner-joins shared-memory `spock.progress`; after a crash restart without a fresh `resource.dat`, the source's entry for peer X exists only once its apply worker for X reattaches. Kills of the source between add_node phases, plus partitions of the source from one peer, explore the gap. |
| **Why It Matters** | Leads to permanent silent loss on the new node; the add-node area has two past data-loss fixes. This is a restart-ordering trigger distinct from the pause-window lead (L4). |

**Open Questions:**

- Is the fallback ever correct (e.g. a peer that never wrote)?
- How wide is the window after Phase 3/4 waits? `(partial: Phase 3 and Phase 4 waits confirmed to require the entry; Phase 4-5 gap not measured)`

Confidence: low
Evidence file: properties/add-node-after-peer-restart-captures-every-peer.md

## Areas examined

- Supervisor: `spock_supervisor_main`, `start_manager_workers`,
  `spock_supervisor_on_exit` shutdown drain and `resource.dat` dump
  (`src/spock.c:780-960`); `bgw_restart_time = 5` (`:1516`).
- Manager: `manage_apply_workers` restart scheduling, clean exit when no local
  node, `spock_manage_extension` (`src/spock_manager.c`, `src/spock.c:560-600`).
- Worker table lifecycle: register / `wait_for_worker_startup` / attach /
  detach and crash vs clean exit; `signal_worker_xact_callback`
  (`src/spock_worker.c:150-480, 640-760`).
- Apply worker startup ordering in `spock_apply_main` (sync before connect,
  origin setup, START_REPLICATION), `before_shmem_exit` ordering
  (`spock_apply_worker_shmem_exit`, `spock_apply_worker_on_exit`), the
  `got_SIGTERM` exit path, PG_CATCH classifier, `handle_begin` marker logic,
  `handle_commit` SUB_DISABLE / TRANSDISCARD handling, idle timeout
  (`src/spock_apply.c`).
- `sub_disable` / `sub_enable` / `alter_subscription` / `sub_drop`
  (`src/spock_functions.c:762-930`, `src/spock_node.c:1080-1260`).
- Initial sync state machine and restart behaviour (`src/spock_sync.c:1488-1700`).
- Read-only mode: GUC, apply loop handling, hooks (`src/spock_readonly.c`).
- ZODAN Phase 3 / 7 waits and the fallback (`samples/Z0DAN/zodan.sql`).
- TAP 105 and commits `ed0a9945`, `f16a004a` (retransmit fixes), `8dcfbcd5`.
- **Extension upgrade (ALTER EXTENSION):** the manager runs
  `ALTER EXTENSION spock UPDATE` at start when the .so version differs from
  the catalog (`spock_manage_extension`). Exercising it needs two builds in
  one run (mixed-version rolling upgrade). The v1 topology uses one image, so
  no property was written; it belongs with the phase-2 rolling-upgrade
  topology (sut-analysis Q22).

## Assumptions affecting multiple properties

- The harness provides a way to run `pg_ctl stop -m fast` and to SIGTERM
  individual spock workers (test command or SQL helper). Antithesis node
  termination alone is a hard kill and wipes shmem, which skips the
  graceful-exit paths that most lifecycle properties target.
- The conflict-free variant of the workload produces no genuine apply errors,
  so any `exception_log` row or disabled subscription is attributable to a
  lifecycle path.
- Stock PG behaviour: `before_shmem_exit` callbacks run LIFO before
  `on_shmem_exit` (origin session release); `ShutdownPostgres` aborts the open
  transaction after spock's callback clears the session origin. Checked in
  comments and code at HEAD, not in the patched PG tree.
- `spock.apply_idle_timeout` is lowered in the harness (about 30 s) so the
  readonly and silent-partition paths complete within a run.
- Workload local writes for read-only checks use a non-superuser role
  (superusers bypass the read-only hooks).
- Clock-step faults are available for the restart-delay property; without them
  it only checks the normal-time bound.
