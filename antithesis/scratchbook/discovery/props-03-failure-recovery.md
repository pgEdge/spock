# Properties — Focus 3: Failure Recovery

Lens: crash recovery, restart correctness, partial failure handling, retry
semantics. Leads examined: L1, L3, L5, L7, L12, L13, L16, L17, L18, L23, plus
progress recovery (`resource.dat`, reconcile, rmgr 144). Several leads were
also covered by other focuses in parallel; entries below are scoped to what
the recovery lens adds and point at the overlapping files.

All SUT-side assertions suggested here are **missing** (no Antithesis
instrumentation exists in the tree).

## Category: Origin and progress recovery after a crash

What the subscriber restores from WAL and `resource.dat` after a crash
decides where streaming resumes. Errors here turn into duplicate apply,
unstable barriers or a node that does not start.

### crash-redo-leaves-no-node-id-origin-state — Crash recovery restores only real replication origins

| | |
|---|---|
| **Type** | Safety |
| **Property** | After any crash recovery, `pg_replication_origin_status` contains no progress row whose id has no `pg_replication_origin` entry (no node-id-numbered states created by redo). |
| **Invariant** | Workload-side `Unreachable("pg_replication_origin_status has a progress row with no pg_replication_origin entry")` from a LEFT JOIN probe run after every node restart and in every quiet-period check; SUT-side (missing) `Unreachable` with the same meaning in `spock_apply_main` right after `replorigin_session_get_progress()`. Unreachable because the state is never legitimate. |
| **Antithesis Angle** | Kill a subscriber between checkpoints while it is applying. Redo advances `XLogRecGetOrigin(record)` (the provider's Spock node id set by `handle_origin`) instead of the slot-named origin, so the subscription origin falls back to its last checkpoint value. Becomes a duplicate apply when the kill lands in the about-1 s window between local flush and feedback reaching the provider, or when the provider restarts while the subscriber's origin is still behind. |
| **Why It Matters** | Lead L1 mechanism, detected directly rather than through rare visible duplicates. Duplicates double-count delta-apply columns; orphan states are never dropped and can fill `max_active_replication_origins`, which stops a node from starting. TAP 008/022 add a CHECKPOINT before SIGKILL to avoid this exact effect. |

**Open Questions:**

- Does the patched PG18 tree tag commit records and run redo exactly as REL_17 does? `(partial: confirmed on stock PG17, PG18 not inspected)`
- Is the node-id state a known side effect of using node ids as commit-record origins?
- How many origin states can accumulate in the planned topology (node-name churn)?

Confidence: high (mechanism code-checked on PG17; reachable with plain crash faults)
Evidence file: properties/crash-redo-leaves-no-node-id-origin-state.md
Overlaps: `replication-origin-states-do-not-leak` (same states, leak angle) — merge candidates.

### satisfied-barrier-stays-satisfied-after-restart — A reached sync_event barrier stays reached after a subscriber restart

| | |
|---|---|
| **Type** | Liveness |
| **Property** | If `wait_for_sync_event(P, M)` returned true on S, then after S restarts the same call for M returns true again within a bound even when P commits nothing new. |
| **Invariant** | Workload-side `Always("re-check of an already reached sync_event marker returns true after subscriber restart")` in a quiet phase with P idle, one evaluation per restart. Always fits a bounded-eventually check that must hold every time. SUT-side companion (missing): `Sometimes(origin_startpos < provider start position)` at apply start. |
| **Antithesis Angle** | Kill S after a non-transactional `sync_event` was reached and before the next checkpoint. The marker advanced the origin with `replorigin_session_advance` only (no WAL); the provider's `confirmed_flush` already passed M, so it is never resent. The origin stays below M until P sends a real transaction. |
| **Why It Matters** | Lead L18. ZODAN and operators re-check barriers after restarts, often while writes are stopped (as ZODAN requires); such a re-check hangs until unrelated traffic arrives. Docs present a `true` result as a durable fact. |

**Open Questions:**

- Is the barrier meant to be stable across a subscriber crash, or must callers issue a fresh marker after any restart?
- Should non-transactional markers be WAL-logged on the subscriber?

Confidence: medium (mechanism code-checked; impact is liveness only and needs an idle provider)
Evidence file: properties/satisfied-barrier-stays-satisfied-after-restart.md

### progress-reconcile-anomaly-unreachable — Progress entry is never ahead of the origin at apply start

| | |
|---|---|
| **Type** | Safety |
| **Property** | Without manual origin changes, `reconcile_progress_with_origin()` never finds the `SpockGroupHash` entry ahead of the subscription origin (the `RECONCILE_FILE_ANOMALY` branch is never taken). |
| **Invariant** | SUT-side (missing) `Unreachable("progress entry ahead of replication origin at apply start")` in the ANOMALY branch of `src/spock_progress_recovery.c:~245-270`; workload-side fallback: `Unreachable` on the log text "ahead of origin ... trusting origin". Unreachable because the code itself attributes this state to operator action or corruption. |
| **Antithesis Angle** | Kill the joining node between ZODAN Phase 5 force-set (writes `resource.dat`) and Phase 7 origin advance; retry add_node after cleanup so a stale never-deleted entry meets a re-created subscription with the same key; kill nodes soon after table-sync COPY force-sets. |
| **Why It Matters** | The progress hash feeds ZODAN Phase 7 slot placement. An entry ahead of the origin means some path moved an origin backwards or wrote progress it did not own; today it is silently overwritten with a WARNING. Cheap guard for leads L16/L17. |

**Open Questions:**

- Is `spock.progress` correctness state (design doc) or monitoring only (code comments)?
- Which keys does force-set write, and can one be the key of a live subscription on the same node?

Confidence: medium (branch exists and is cheap to instrument; the reaching path through add_node retry is inferred, not traced end to end)
Evidence file: properties/progress-reconcile-anomaly-unreachable.md

## Category: Retry versus discard on the apply path

The apply worker's `PG_CATCH` decides whether an error means "retry the same
transaction" or "this data is bad, run the exception policy". A wrong choice
silently drops or disables.

### apply-cancel-retried-not-discarded — A query cancel on an apply worker is retried, not discarded

| | |
|---|---|
| **Type** | Safety |
| **Property** | A `pg_cancel_backend` (SQLSTATE 57014) on an apply worker leads to a retry of the same remote transaction; it never produces `exception_log` rows or a disabled subscription in a conflict-free workload. |
| **Invariant** | Workload-side `Always` after quiesce: no exception_log row mentions 57014 / "canceling statement due to user request", all subscriptions enabled, all ledger rows present. SUT-side (missing) `Unreachable("apply worker entered exception replay for a query-cancel error")` before `AbortOutOfAnyTransaction()` at `src/spock_apply.c:4065`, with separate messages for class 58 and 40001; `Reachable` markers on each retry branch. |
| **Antithesis Angle** | Custom fault cancels apply backends at random times; CPU modulation keeps apply inside a remote transaction when the cancel lands. 57014 is not on the retry allow-list (08xxx subset, 57P01-03, 40P01, 55P03, class 53), so it goes to in-process replay and TRANSDISCARD drops the whole transaction on that node only. |
| **Why It Matters** | Lead L5. Spock claims transient failures re-stream the aborted transaction. Monitoring tools that cancel long-running backends by pid would cause logged, permanent divergence. Same shape as eleven earlier classifier fixes. |

**Open Questions:**

- Is a cancel of an apply worker meant to be a data fault? `(needs human input)`
- Are other externally triggerable cancel-type codes reachable (beyond 57P01)?

Confidence: high (allow-list code-checked; SIGINT handler confirmed in stock `bgworker.c:761-763`; Spock does not override it)
Evidence file: properties/apply-cancel-retried-not-discarded.md

### interrupted-exception-replay-still-records-txn — A failing transaction whose replay is interrupted is still handled by policy

| | |
|---|---|
| **Type** | Safety |
| **Property** | If exception replay of a failing remote transaction T is interrupted (worker SIGTERM, disconnect, idle timeout, crash), T is still eventually recorded under the policy: TRANSDISCARD leaves exception_log rows for T's remote xid and none of T's rows; SUB_DISABLE leaves the subscription disabled with origin below T's end LSN. |
| **Invariant** | Workload-side `Always("poison transaction is either applied-nowhere-and-logged or subscription disabled on every target node")` after quiesce for every poison T (poison = local-only ENABLE ALWAYS trigger raising on a marker payload). SUT-side (missing) `AlwaysOrUnreachable` in the keepalive branch: while replaying, the flush sent is not past the marker's `commit_lsn`; `Sometimes(replay interrupted before commit)` at the replay exit paths. |
| **Antithesis Angle** | Large poison transactions so replay lasts; graceful exits and kills during replay. `AbortOutOfAnyTransaction()` already advanced the session origin to T's `commit_lsn`; the strict decoding skip rule (`ptr < start_decoding_at`) should still resend T. The keepalive feedback path during replay is the one way the provider could confirm past T. |
| **Why It Matters** | Lead L7. A d286f3df comment says such an origin advance "silently skips that txn on reconnect"; if true on PG18, any exit during replay loses T with no exception_log row, which breaks the claim that every dropped change is recorded. |

**Open Questions:**

- Does a restart at exactly `commit_lsn` resend T on patched PG18? `(partial: PG17 snapbuild strict skip confirmed; PG18 not inspected)`
- Can a keepalive's endpos exceed T's commit LSN while T is being sent?
- Is a second set of exception_log rows for the same T (after crash + L1) acceptable?

Confidence: medium (code reading suggests the property holds; it is a regression guard for a path with dense bug history)
Evidence file: properties/interrupted-exception-replay-still-records-txn.md
Related: `exception-replay-only-after-recorded-error`, `exception-replay-never-reruns-committed-transaction`, `sub-disable-enable-cycle-loses-and-duplicates-nothing`.

## Category: Restart of the whole node

A crash restart wipes all Spock shared memory and the commit clock and
rebuilds them from WAL, `resource.dat` and catalogs.

### crashed-node-returns-to-streaming — A crashed node streams again within a bound

| | |
|---|---|
| **Type** | Liveness |
| **Property** | After a node is killed and faults stop, within a fixed bound it accepts connections and every subscription into and out of it passes a fresh sync_event barrier. |
| **Invariant** | Workload-side `Always("crashed node streams again within bound")` per restarted node per quiet period (bounded-eventually check that must hold every time). SUT-side (missing): `Reachable("spock supervisor started after crash recovery")`, `Unreachable("resource.dat load failed")` at the ERROR sites in `spock_group_resource_load`, `Sometimes(reconcile result == STALE)`. |
| **Antithesis Angle** | Kills at random points, including during apply, table/initial sync, add_node, and soon after a previous restart. Exercises redo (rmgr 144, node-id origin states needing free slots), `resource.dat` load in the postmaster (no CRC, ERROR stops startup), reconcile + 1M-xid `pg_commit_ts` scan, slot still held by the old walsender, and crash loops from Asserts that fire again on the resent input. |
| **Why It Matters** | V7 (node restartability) and V1. Any of these steps failing leaves a node down or crash-looping after an ordinary power loss. |

**Open Questions:**

- What recovery bound does the team expect?
- Is a node that fails to start because the replication-state array is full a Spock bug or a sizing error?
- Does Antithesis node termination keep fsynced PGDATA writes?

Confidence: medium (each step is code-checked; whether any step actually blocks restart in a run is unknown)
Evidence file: properties/crashed-node-returns-to-streaming.md
Related: `apply-worker-restarted-within-bound-after-exit` (single worker), `graceful-restart-preserves-exactly-once` (clean restart), `resource-dat-dumps-serialized`.

### no-assert-crash-when-remote-commit-ts-ahead — A provider clock ahead of the subscriber never crashes the subscriber

| | |
|---|---|
| **Type** | Safety |
| **Property** | Applying a remote transaction whose commit timestamp is ahead of the subscriber's wall clock never crash-restarts the subscriber. |
| **Invariant** | SUT-side (missing) `AlwaysOrUnreachable("applied remote commit ts is not ahead of local wall clock")` just before `Assert(sap.last_updated_ts >= sap.remote_commit_ts)` at `src/spock_apply.c:1174`; log-side `Unreachable("TRAP: failed Assert in spock source")` with file and line. AlwaysOrUnreachable because the line runs per applied commit but a run may apply none. |
| **Antithesis Angle** | Clock skew with a provider ahead by more than apply latency. The commit clock patch spreads a fast clock: nodes that apply its transactions stamp their own commits above it. In the cassert build the Assert aborts the backend, the postmaster crash-restarts the whole node, the provider resends the transaction (async commit + L1), and the Assert fires again until the local clock catches up. |
| **Why It Matters** | Turns ordinary clock drift into a crash loop on dev/cassert builds, and in Antithesis would hide every other finding while clock faults are on. Each loop is another chance for duplicate apply. The comment says "Don't care in production yet". |

**Open Questions:**

- Should the Antithesis build keep this Assert, or should clock faults be bounded below apply latency? `(needs human input)`
- Does Antithesis skew clocks per container?

Confidence: high (Assert and its inputs code-checked; fires whenever skew exceeds latency in a cassert build)
Evidence file: properties/no-assert-crash-when-remote-commit-ts-ahead.md

### local-commit-ts-above-overwritten-version — Local updates get a commit ts above the version they replace, across restarts

| | |
|---|---|
| **Type** | Safety |
| **Property** | On any node, a local update of a row commits with a timestamp strictly greater than the commit timestamp of the row version it replaced, including right after the node restarts. |
| **Invariant** | Workload-side `Always("local update commit ts is above the overwritten version's commit ts")` per checked update (read `pg_xact_commit_timestamp(xmin)` FOR UPDATE, update, compare with the new xid's ts). Always: the clock must be monotonic on every write. SUT-side companion (missing): `Sometimes("node restarted with wall clock behind newest applied remote commit ts")` at apply start, using the recovered `remote_commit_ts`. |
| **Antithesis Angle** | Node X behind in wall time applies a remote version, restarts (the logical clock in `XLogCtl` resets to 0), then updates the same row locally. The patch's own TODO says it is not restart safe. |
| **Why It Matters** | Lead L3 / claim S5. X keeps its update while every peer keeps the remote version: permanent divergence with no exception row, which is outside the documented clock-skew allowance (different winners on different nodes). This per-write form fails on one node before any conflict resolution, so triage points straight at the clock. |

**Open Questions:**

- Is there a plan to restore the clock at startup or promotion, or a documented maximum skew?
- Does Antithesis give per-container clocks?

Confidence: high that it fails under skew larger than restart time plus restart (patch TODO); medium that the tenant can produce that skew
Evidence file: properties/local-commit-ts-above-overwritten-version.md
Related: `local-overwrite-after-remote-read-wins-everywhere` (the cross-node convergence form of the same lead).

---

## Areas examined

- **Apply commit / origin / feedback path:** `handle_begin` (marker cases),
  `handle_origin`, `handle_commit`, empty-transaction and sync_event origin
  advances, `send_feedback`/`get_flush_position`/`get_feedback_position`,
  keepalive handling, `spock_apply_worker_shmem_exit`
  (`src/spock_apply.c:640-1180, 1300-1335, 2296-2325, 2915-2965, 3080-3300,
  3398-3860`).
- **Error classifier and retry pacing:** full `PG_CATCH` (`:3867-4160`),
  `clear_transient_exception_state`, `prepare_transient_error_retry`,
  manager restart scheduling (`src/spock_manager.c:95-140`). Retry storms:
  transient branches set `restart_delay_default`; the 1 ms respawn needs a
  FATAL after BEGIN. The readonly FATAL in `replication_handler` (`:2981-2983`)
  looks unreachable from `apply_work` because the loop checks `spock.readonly`
  after the reload and before the handler in the same iteration; the
  "incorrect spock message" FATAL needs a protocol breach. So the
  "FATAL leaves marker" part of L5 is narrow; 57014 is the main reachable gap.
  Respawn-rate properties already exist (`worker-respawn-rate-bounded`,
  `apply-worker-respawn-rate-bounded`), so none is added here.
- **Stock PG behaviour** in `~/dev/pg/postgresql` (REL_17_10+):
  `RecordTransactionCommit/Abort`, `xact_redo_*`, `replorigin_advance`,
  `SnapBuildXactNeedsSkip`, bgworker SIGINT handler.
- **Progress recovery:** `src/spock_progress_recovery.c` (reconcile, commit-ts
  scan), `spock_group_resource_dump/load` (`src/spock_group.c:534-700`),
  `progress_update_struct` Asserts, supervisor exit dump (`src/spock.c:850-897`),
  progress design doc.
- **Commit clock patch** `patches/18/pg18-025-logical_commit_clock.diff`.
- **Table and initial sync recovery:** `spock_sync_subscription` restart
  switch (`src/spock_sync.c:1505-1550`), table sync FAILED-on-restart
  (`:1840-1870`), `process_syncing_tables` SYNCWAIT Assert and
  "a table synchronisation operation is failed" (`src/spock_apply.c:4456-4640`).
  Not turned into new entries: `apply-never-waits-on-dead-sync-worker` and
  `initial-sync-ends-ready-or-visibly-disabled` already cover L12/L13. One
  note for them: the `elog(ERROR, "a table synchronisation operation is
  failed")` between transactions goes down the "caught initial exception"
  path but is then cleared by `handle_begin` case 3, so it does not drop data;
  in the cassert build the Assert at `:4532` fires first and crash-restarts
  the node.
- **Forwarded-origin advance (L19):** not reachable in the v1 topology
  (`forward_origins='{}'`), not added.
- **Duplicate-apply oracle note for other focuses:** with
  `save_resolutions=on`, a resend of an already applied INSERT logs an
  `insert_exists` row in `spock.resolutions` with equal local and remote
  origin and timestamp (`spock_report_conflict` only suppresses same-origin
  update/delete cases, `src/spock_conflict.c:393-420`). On per-node-owned
  insert-only keys, any such row is a duplicate apply.

## Assumptions affecting multiple properties

1. **Stock PG origin and decoding behaviour holds on patched PG18**
   (commit/abort advance the session origin; redo advances the record's
   origin; skip rule is strict `<`; walsender raises a start below
   `confirmed_flush`). Checked in a PG17 tree only. Affects
   crash-redo-leaves-no-node-id-origin-state,
   interrupted-exception-replay-still-records-txn,
   satisfied-barrier-stays-satisfied-after-restart.
2. **Antithesis node termination behaves like SIGKILL of the postmaster with
   PGDATA kept**, and the container restarts postgres. Affects every
   crash-based property here.
3. **The Antithesis build is cassert** (Asserts are crashes). Affects
   no-assert-crash-when-remote-commit-ts-ahead and crashed-node-returns-to-streaming.
4. **Per-container clock skew is available.** Without it,
   local-commit-ts-above-overwritten-version and
   no-assert-crash-when-remote-commit-ts-ahead are checked but cannot fail;
   report them as unexercised.
5. **`checkpoint_timeout` is large and the workload issues no manual
   CHECKPOINT**, keeping the crash windows of L1/L18 open.
6. **The apply session uses `synchronous_commit=off`** (default
   `spock.synchronous_commit=off`), so locally applied but unflushed commits
   are lost on crash and resent; properties allow that and only flag resends
   of flushed work or lost records.
