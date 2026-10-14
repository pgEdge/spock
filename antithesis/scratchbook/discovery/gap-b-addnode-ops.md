---
sut_path: /home/msharp/dev/pgedgea/spock
commit: 69d9228f5df363761dc3ae6eebf7e2fcfe49b8e5
updated: 2026-10-13
external_references: []
---

# Gap (b): add-node completion, pause-flag liveness, investigation candidates

Three new properties, five candidates judged to be extensions, already covered,
or setup checks. All SUT-side assertions named below are missing (no
Antithesis instrumentation exists).

## New properties

### add-node-returns-within-bound — ZODAN add_node returns or raises within a bound after faults stop

| | |
|---|---|
| **Type** | Liveness |
| **Property** | Once faults stop, a running `CALL spock.add_node(...)` returns, successfully or with an error, within a bound derived from `spock.sync_timeout()`. |
| **Invariant** | Workload `Always(add_node returned or raised within B after faults stopped, "add_node returns within bound after faults stop")`, B = sum of ZODAN's own wait budgets (about 12·S + 90 s for v1, S = `sync_timeout` set in the session) plus margin. Second message from sampling `pg_stat_activity` on n4: `Always(no add_node backend waits in DblinkConnect/DblinkGetResult longer than S + margin after faults stopped, "add_node dblink call does not outlive its budget after faults stop")`, which names the stuck step. `Always` with a bound because the guarantee is "every add_node ends", checked once per quiet period. Companion `Sometimes("a peer was partitioned or paused while add_node had a dblink call open to it")`. |
| **Antithesis Angle** | Every `dblink(dsn, ...)` in `samples/Z0DAN/zodan.sql` uses the DSN as given (no `connect_timeout`, OS keepalive idle about 2 h). A peer killed while partitioned from n4 during an open dblink call (Phase 4's remote `wait_for_sync_event` lasts up to S) may leave n4 reading a half-open socket after the heal. Phase 3's `set_config('statement_timeout','5s')` around its probe never takes effect (the timer is armed only at top-level statement start). Long partitions outlast the peer's retransmits; pauses and connect attempts to partitioned hosts add delay. Budgets use wall clock, so backward clock skips stretch them. |
| **Why It Matters** | V5 claims add_node completes or fails within a `sync_timeout`-derived bound. A hung add_node holds a transaction on n4, half-created slots on peers pinning WAL, and blocks the operator's retry (cleanup must wait for it). |

**Open Questions:**

- What total bound does the team expect for add_node after faults stop? `(needs human input)`
- Does an Antithesis node kill during a partition leave the other end's socket half-open after the heal? Decides whether the main scenario fires or the property is a regression guard.
- Is Phase 3's `statement_timeout = '5s'` meant to bound the probe? `(partial: code reading shows it never takes effect inside the CALL; intent unknown)`

Priority: P2 — claimed guarantee with a plausible hang (no dblink timeouts) but the main trigger depends on Antithesis network teardown; long time budget per check.
Topology: v1 (dedicated add_node test template)
Key faults: partition + node kill of a peer during add_node, process pause of a peer, node kill of n4
Confidence: medium (dblink and timeout behaviour code-checked; half-open trigger unverified)
Surfaced by: Evaluation gap b
Evidence: properties/add-node-returns-within-bound.md

### add-node-pause-released-after-caller-dies — Apply on the source resumes within pause_timeout after the pausing caller dies

| | |
|---|---|
| **Type** | Liveness |
| **Property** | When the sync worker that called `spock.pause_apply_workers()` on a provider dies or loses its connection before calling resume, every provider apply worker commits its next remote transaction within `spock.pause_timeout` plus normal apply latency. |
| **Invariant** | Workload `Always(each peer's marker row is visible on src within pause_timeout + margin after the caller was killed, "provider apply resumes within pause_timeout after the pausing caller dies")`, scored only when Antithesis did not fault src or that peer in the window. `Always` with a bound because the claim (V3) is a bound on every occurrence. Precondition marker `Sometimes("pausing caller killed while provider CREATE_REPLICATION_SLOT was in progress")`. SUT-side `Reachable("apply worker self-resumed after the pausing caller was gone")` in the timeout branch of `maybe_pause_for_slot_creation`, using the pausing-backend PID that `add-node-pause-held-until-progress-read` also needs. |
| **Antithesis Angle** | The workload holds an xid-assigned transaction on src so `CREATE_REPLICATION_SLOT` waits; while that shows in src's `pg_stat_activity` the flag is set. It then kills the caller (terminate the provider backend that ran the pause, kill n4, or partition n4 from src). Each worker self-resumes after its own monotonic `pause_timeout` and clears the flag without a broadcast; an idle provider keeps the flag set indefinitely and stalls the next remote transaction once. |
| **Why It Matters** | The sync worker's error path relies on this ("the workers' CV timeout will recover them"). An unbounded pause would stop all inbound replication to the source with no error. The errhint advises raising `pause_timeout`, which lengthens this stall. |

**Open Questions:**

- Is the stale flag on an idle provider (one extra `pause_timeout` stall on the next remote transaction, possibly much later) acceptable, or should the pause be cleared when the caller's backend exits?

Priority: P3 — regression guard: code reading shows the bound holds (per-worker monotonic timeout, flag reset at crash-restart); cheap once the shared PID instrumentation exists.
Topology: v1
Key faults: worker exit (terminate the provider-side pausing backend), node kill of n4, partition n4-src during slot creation
Confidence: high (mechanism code-checked; not run)
Surfaced by: Evaluation gap b
Evidence: properties/add-node-pause-released-after-caller-dies.md

### sync-worker-sigterm-never-skips-catchup — A SIGTERMed table-sync worker never marks its table done without catch-up

| | |
|---|---|
| **Type** | Safety |
| **Property** | A table-sync worker that receives SIGTERM before reaching catch-up never marks its table SYNCDONE without applying the changes the apply worker skipped for that table. |
| **Invariant** | SUT-side `Unreachable("sync worker left SYNCWAIT without reaching CATCHUP")` in `spock_sync_main` (`src/spock_sync.c:2039-2042`) when `wait_for_sync_status_change` returns false, placed before the `Assert(lsn == status_lsn)` so it fires on cassert and non-cassert builds. `Unreachable` because no intended path ends a table sync this way. Workload marker `Sometimes("graceful stop or worker terminate issued while a table sync was in SYNCWAIT")`. Outcome is caught by `committed-ledger-row-reaches-every-node` when resyncs target ledger tables. |
| **Antithesis Angle** | Sync workers only set a flag on SIGTERM. A SIGTERM during COPY or SYNCWAIT makes the wait return at once with an invalid LSN; on non-cassert the worker then marks the table SYNCDONE at its COPY LSN, while the apply worker has already skipped the table's later changes. Fast shutdown reaches it during SYNCWAIT (postmaster SIGTERMs bgworkers; commits still work), as do `pg_terminate_backend` and the manager's misdirected kill. SYNCWAIT is long while the apply worker is busy, lock-blocked, paused, disconnected, or its subscription is disabled. |
| **Why It Matters** | Non-cassert builds lose the table's changes permanently with no exception row, and the table shows `replicating`; cassert builds crash the node during shutdown and leave the table FAILED. A routine restart during a resync is enough. |

**Open Questions:**

- Is a fast shutdown during a table resync supported without data loss, or must operators re-run resyncs after restarts? `(needs human input)`
- On SIGTERM in SYNCWAIT, should the worker exit with an error (table goes FAILED, visible) or keep `w` and resume after restart? Affects the fix only.

Priority: P1 — silent permanent drift from an ordinary graceful restart during a resync, confirmed by code reading on the main path.
Topology: v1 (admin-churn phase with table resyncs plus graceful stops)
Key faults: graceful stop (test command) during resync, worker terminate, admin churn (sub_disable during resync)
Confidence: high (mechanism code-checked on both builds; not run); medium that v1 runs resyncs
Surfaced by: Evaluation gap b (investigation candidate G7)
Evidence: properties/sync-worker-sigterm-never-skips-catchup.md

## Candidates judged not to need a new property

- **Re-add of n4 under the same name** — covered by
  `zodan-readd-node-progress-not-stale` (its `Sometimes("add_node succeeded on
  a node that had been removed before")` and ledger `Always`). Extension below.
- **`table-resync-under-faults-ends-ready`** — as worded it contradicts the
  designed behaviour (a sync restarted after it started goes FAILED,
  `src/spock_sync.c:1846-1866`), and the FAILED-intent question is still open.
  Folded into `apply-never-waits-on-dead-sync-worker` as a retry step
  (extension below): retrying resync of a FAILED table must reach `r`. Code
  reading shows nothing blocks the retry (`sub_resync_table` accepts FAILED,
  `src/spock_functions.c:1306-1314`; slot and origin are re-used through the
  `ensure_*` helpers).
- **`stuck-table-not-shown-as-replicating`** — not a fault-driven property:
  `sync_status_to_string` (`src/spock_functions.c:1359-1382`) maps only `r` to
  "replicating" and FAILED to "unknown", deterministically. The "unknown"
  label is a display gap for TAP or docs. The real "shown as replicating while
  stale" case is the drift in `sync-worker-sigterm-never-skips-catchup`.
- **`clean-apply-exit-respawn-paced`** — already covered by the second check
  of `worker-respawn-rate-bounded`, which counts worker registrations per
  subscription rather than error exits, so clean-exit respawn loops count too.
  The clean-exit path (`src/spock_apply.c:3450-3454`, worker freed, manager
  restarts at once) needs a fresh exception with the connection already bad
  on each cycle, which does not repeat by itself.
- **`node-id-never-equals-local-origin-id`** — a setup check, not a property.
  Node ids are `hash_any(name) & 0xffff` (`src/spock_node.c:370-371`) and
  local roidents are small integers, so a collision is fixed by the node names
  chosen. Add to catalog Assumption 5 and the workload setup: after cluster
  creation, after every add_node and after resyncs, assert no `spock.node`
  node_id equals any `pg_replication_origin.roident` on any node (fail setup,
  rename nodes).

## Suggested extensions to existing properties

- **`add-node-pause-held-until-progress-read`** — the primary
  `Unreachable("apply worker self-resumed while the pausing backend is still
  alive")` can fire with no harm: when n4 is partitioned from src, the n4 sync
  worker errors out after keepalive detection, but the provider-side backend
  that ran the pause stays alive (idle in ClientRead) until server TCP
  keepalive, about 2 h with OS defaults, because the server does not set
  `tcp_keepalives_*`. Suggest firing only when the same backend later reaches
  `spock_resume_apply_workers` (the caller really went on to read progress),
  or have the harness set server `tcp_keepalives_idle` / `client_connection_check_interval`
  low and accept the remaining gap. Also note: worker timeouts do not
  broadcast, and an idle worker never clears the flag, so `pause_apply` can be
  1 long after any caller is gone; the `Always(pause_apply == 1)` at resume is
  unaffected.
- **`zodan-readd-node-progress-not-stale`** — add the re-add steps: run
  `remove_node`; on n4 drop the workload's user **schemas** (not only tables)
  and keep the roles the source has. add_node's prereq check counts only
  tables (`zodan.sql:1577-1592`), but `create_sub` turns every pre-existing
  non-`public` user schema on n4 into `skip_schema` (`zodan.sql:347-372`), and
  `skip_schema` removes that schema from both the structure dump and the data
  sync (`src/spock_sync.c:1388-1393`). An emptied-but-kept schema therefore
  passes the prereqs and leaves n4 without that schema's tables, which the
  property would score as missing rows (a harness artefact). New open
  question for the team: is skipping an empty pre-existing schema on the new
  node intended? If not, it is a real operator trap.
- **`apply-never-waits-on-dead-sync-worker`** — absorb
  `table-resync-under-faults-ends-ready`: after faults stop, re-run
  `sub_resync_table` on every table left FAILED (up to k tries) and
  `Always("retried table resync reaches READY after faults stop")`; then
  include those tables in the ledger checks instead of skipping the node.
- **`manager-kill-targets-only-listed-worker`** — correct the evidence note
  "Fast shutdown does not reach step 4": that holds for a SIGTERM during COPY,
  not during SYNCWAIT. The consequence is now its own property,
  `sync-worker-sigterm-never-skips-catchup`.
- **Catalog Assumption 5** — add the node-id vs roident setup check above.
