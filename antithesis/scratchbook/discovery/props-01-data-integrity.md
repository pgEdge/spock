# Property discovery — Focus 1: Data Integrity (Spock @ 69d9228f)

Lens: consistency guarantees and invariants on stored state. No committed
transaction lost, remote transactions applied atomically, exactly-once apply,
convergence under a workload that avoids documented divergence, exact
delta-apply counters, conflicts recorded when resolved, no echo loops.

All properties assume the workload boundaries of sut-analysis section 12 and
the shared oracle tables described under "Assumptions affecting multiple
properties" below. All SUT-side assertions suggested here are **missing**
(no Antithesis instrumentation exists in the tree).

## Category: No loss, no duplicates

### committed-ledger-row-reaches-every-node — Committed rows reach every mesh node

| | |
|---|---|
| **Type** | Safety |
| **Property** | Every ledger row whose client COMMIT succeeded on any mesh node is present, with the same content, on every other mesh node once faults stop and pairwise `sync_event`/`wait_for_sync_event` barriers pass. |
| **Invariant** | Workload `Always`: for each committed `(origin_node, seq)` of the insert-only, conflict-free ledger table, every node in scope (n1-n3 always; n4 for rows committed after a successful add_node) returns the row with identical payload. Failure details name the missing keys and whether the node's `spock.exception_log` has a row for that remote commit. `Always` because one missing row is a bug: the ledger produces no conflicts, so no documented divergence applies. Supporting SUT-side `Unreachable("apply entered exception replay in a conflict-free run")` at the "caught initial exception" branch of `apply_work` `PG_CATCH` (template-guarded). |
| **Antithesis Angle** | Graceful apply exits (`pg_cancel_backend` -> 57014, `pg_terminate_backend`, FATAL paths) and partitions drive the error classifier (L5) and the replay origin advance (L7); provider pauses drive `apply_idle_timeout`; postmaster kills drive async-apply-commit + feedback correctness. Postmaster kill alone wipes shmem and hides L5/L7, so single-worker exits need a custom fault or test command. |
| **Why It Matters** | Under default `transdiscard`, every misclassified infrastructure error is a silently dropped upstream transaction (only an `exception_log` row). The classifier has at least eleven past fixes of this shape (sut-analysis 5.1). This is the base promise of the product. |

**Open Questions:**

- How should unknown-outcome commits (connection lost during COMMIT) be scored: "present on all nodes or none", or unconstrained?
- Under `sub_disable`, is a disabled subscription counted as loss here, or only as a liveness failure?

Confidence: high
Evidence file: properties/committed-ledger-row-reaches-every-node.md

### ledger-row-applied-exactly-once-per-peer — No transaction is applied twice on a peer

| | |
|---|---|
| **Type** | Safety |
| **Property** | Each committed ledger row from origin O is applied by an apply worker exactly once on each peer S, across subscriber crashes, worker restarts and reconnects. |
| **Invariant** | Workload `Always`: after barriers, for every committed `(origin, seq)` and every S != origin, the local non-replicated `apply_audit` table on S (filled by an `ENABLE ALWAYS` `AFTER INSERT OR UPDATE` trigger that fires only when `session_replication_role = replica`) has exactly one row. A redelivered INSERT becomes an `insert_exists` UPDATE, which fires the trigger again, so duplicates are counted. Suggested SUT-side `Always("incoming BEGIN commit_lsn is above the subscription origin's progress")` in `handle_begin`. `Always` because one double apply is a violation. |
| **Antithesis Angle** | Kill -9 of a subscriber postmaster between checkpoints (large `checkpoint_timeout`). Crash redo advances the origin numbered by the commit record's origin (the node id, set in `handle_origin`, `src/spock_apply.c:1332`), not the slot-named subscription origin (`:4749-4750`), so the subscription origin falls back to its checkpoint value and the provider re-sends committed-but-unconfirmed transactions (L1). TAP 022/027 checkpoint before SIGKILL, so this path is untested. |
| **Why It Matters** | Plain rows mostly hide duplicates (same-origin equal-ts shortcut), but delta-apply counters double count and user triggers repeat side effects. The design doc reads as exactly-once for direct subscriptions. |

**Open Questions:**

- Does crash redo in the patched PG18 tree advance `XLogRecGetOrigin(record)` as in stock PG17? `(partial: checked in a stock PG17 tree only; pgEdge patches do not touch these functions)`
- Does redo of node-id-numbered origins need spare replication-state slots (`max_active_replication_origins`)?
- Does the team intend exactly-once or at-least-once on direct subscriptions?

Confidence: medium
Evidence file: properties/ledger-row-applied-exactly-once-per-peer.md

### delta-counter-equals-committed-increments — Delta-apply counters equal the sum of committed increments

| | |
|---|---|
| **Type** | Safety |
| **Property** | For a NOT NULL delta-apply column (`log_old_value=true, delta_apply_function=spock.delta_apply` on every node) on pre-seeded rows, each row's value on every mesh node equals its initial value plus every committed increment from any node. |
| **Invariant** | Workload `Always` after barriers: per row, `val == sum(committed k)` on every node; report the difference (one committed k points at one lost or doubled transaction). Supporting SUT-side `Reachable("delta apply forced on a row where LUW kept local")` and, in the v1 template, `Unreachable("delta column received NULL old value")` at `build_delta_tuple` (`src/spock_apply_heap.c:545`). `Always`: a single wrong total is a violation. |
| **Antithesis Angle** | Delta apply is not idempotent (`spock_handle_conflict_and_apply`, `src/spock_apply_heap.c:589-790`), so any redelivery (L1 under postmaster kill) adds twice and any drop (L5/L7 under graceful exits and partitions) under-counts. Concurrent updates from all nodes exercise the forced-apply subtransaction with commit-ts override (patch 030). |
| **Why It Matters** | Spock claims "the delta-apply column will be correctly calculated and applied" (`docs/conflicts.md:10-34`); the feature exists for balances and counters where any error is money. |

**Open Questions:**

- How are unknown-outcome commits resolved (marker row on the origin) so the expected total is exact rather than a range?
- Is at-least-once on direct subscriptions considered a bug? If not, `docs/conflicts.md` needs a caveat for crashes.

Confidence: high
Evidence file: properties/delta-counter-equals-committed-increments.md

### add-node-success-implies-complete-ledger-on-new-node — A successful add_node leaves the new node with exactly the committed rows

| | |
|---|---|
| **Type** | Safety |
| **Property** | If ZODAN `spock.add_node` for n4 returns without error while n1-n3 take writes, n4 ends up with exactly the committed ledger rows (none missing, none applied twice), and a failed add_node leaves n1-n3 intact. |
| **Invariant** | Workload `Always` after barriers including n4: n4's ledger equals the committed set, and every n4 ledger row has exactly one `apply_audit` entry (COPY in replica role also fires ALWAYS triggers). On add_node error: `Always` n1-n3 still satisfy the other ledger properties. Plus `Sometimes(add_node succeeded while writes were in flight on all three nodes)`. Workload parses NOTICE text; a success that logged "falling back to pg_current_wal_lsn()" is reported. |
| **Antithesis Angle** | Pausing or throttling the source node during `CREATE_REPLICATION_SLOT` past `spock.pause_timeout` (workers self-resume and clear the flag, L4); long transactions on peers; a restart of the source just before add_node (empty `spock.progress` -> `read_peer_progress` INNER JOIN drops a peer -> Phase 7 fallback); partitions during Phases 3-7; orchestrator kill. |
| **Why It Matters** | The tutorial says add_node "ensures no data is missed or duplicated". Seven past fixes in this class; a gap here is permanent silent loss on the new node. |

**Open Questions:**

- Is the `pg_current_wal_lsn()` fallback ever safe while the peer is taking writes?
- Is add_node expected to succeed when a Phase 3 subscription failed (errors only NOTICE'd)?

Confidence: medium
Evidence file: properties/add-node-success-implies-complete-ledger-on-new-node.md

## Category: Atomicity and barriers

### remote-transaction-all-or-nothing-per-node — Remote transactions are visible whole or not at all

| | |
|---|---|
| **Type** | Safety |
| **Property** | A multi-row, multi-table transaction from origin O is, at every moment a reader on another node looks, visible there completely or not at all (exception mode `transdiscard` or `sub_disable`). |
| **Invariant** | Workload `Always`, checked continuously during the fault phase: in one REPEATABLE READ snapshot on each node, for every `txn_tag` seen across `ledger` and `ledger_b`, the row count equals the K the writer committed. Nodes with any `local_sync_status` other than `r`, and n4 before add_node returns, are skipped (and the non-`r` state is recorded). Suggested SUT-side `Unreachable("apply skipped a change for a FAILED table")` in `should_apply_changes_for_rel` (`src/spock_apply.c:463-484`) and `Always("transdiscard commit wrote no user-table rows")` in `handle_commit`. `Always`: partial visibility is never allowed in scope. |
| **Antithesis Angle** | Graceful exits during large transactions drive the replay paths (read-only replay, `handle_commit` exception branch); table resync under writes reaches the per-table filter that applies some of a transaction while skipping tables that are not READY; postmaster kills check crash atomicity (control). |
| **Why It Matters** | Partial transactions break application invariants (order and its lines, debit and credit) in a way no convergence check on single rows would show. |

**Open Questions:**

- Is silently skipping changes for a FAILED table intended? This decides whether partial transactions on such nodes are a bug.
- Are multi-table transactions copied under one snapshot during initial sync?

Confidence: medium
Evidence file: properties/remote-transaction-all-or-nothing-per-node.md

### sync-barrier-true-implies-rows-visible — A true sync barrier means the rows are visible

| | |
|---|---|
| **Type** | Safety |
| **Property** | When `spock.wait_for_sync_event(result, P, L, timeout)` returns true on S for an L from `spock.sync_event()` on P, a following query on S sees every ledger row committed on P before `sync_event()` was called. |
| **Invariant** | Workload `Always(barrier true -> all of C visible on S)`, where C is the set of P's committed rows recorded before calling `sync_event()`; on failure re-read after 1 s to separate a visibility race (rows appear) from a drop (rows stay missing). Run repeatedly during faults, not only at the end. `Always` because the docs promise it every time the call returns true. |
| **Antithesis Angle** | The procedure polls `pg_replication_origin_status.remote_lsn` (`sql/spock--6.0.0.sql:685-762`), which stock `RecordTransactionCommit` advances after the commit record but before `ProcArrayEndTransaction`; thread pausing/CPU modulation of the apply worker stretches that window. `transdiscard` drops also advance the origin. Subscriber crashes after a true result are expected to lose async-committed applies until re-sent (not a violation; barriers must be re-run). |
| **Why It Matters** | Every convergence oracle and ZODAN itself rely on this barrier (dcbba6bb fixed the same ordering on the add-node path). A wrong barrier gives false alarms or hides loss. |

**Open Questions:**

- Is "true" meant as "committed" or "visible"? If the race is accepted, the property becomes "eventually visible after true".
- Should the barrier report something other than true when the origin passed L only because a transaction was discarded?

Confidence: medium
Evidence file: properties/sync-barrier-true-implies-rows-visible.md

## Category: Convergence and conflict resolution

### contested-rows-converge-after-quiesce — Concurrently updated rows converge

| | |
|---|---|
| **Type** | Safety |
| **Property** | For pre-seeded rows updated concurrently from all mesh nodes (no deletes, no inserts of contested keys), all nodes hold identical row contents after quiescence and barriers. |
| **Invariant** | Workload `Always(ordered row dumps of the contested table are equal on all mesh nodes)`. Failure details give each node's `(writer, wseq)`, `pg_xact_commit_timestamp_origin(xmin)`, and whether the competing versions had equal commit ts. Supporting SUT-side `Sometimes(cmp == 0 && local_origin != remote_origin, "equal commit ts conflict between different origins")` in `conflict_resolve_by_timestamp` and `Unreachable` at the equal-tiebreaker WARNING. `Always`: in this scope no documented divergence applies. |
| **Antithesis Angle** | Partitions/latency reorder arrival between pairs; clock jitter produces equal commit ts, where the tiebreak compares the applying node rather than the two writers (L2, `src/spock_conflict.c:131-200`), which can diverge with 3+ writers; restart with a lagging clock breaks the commit-clock patch (L3); graceful exits drop transactions (L5). |
| **Why It Matters** | Spock claims LUW gives one deterministic winner (`docs/conflicts.md:60-64`). Divergence here is silent: update/update conflicts are not recorded in `spock.resolutions`. |

**Open Questions:**

- Is equal-timestamp convergence with 3+ writers intended (L2)?
- Is divergence after clock skew plus restart (L3) accepted?

Confidence: high
Evidence file: properties/contested-rows-converge-after-quiesce.md

### luw-final-value-is-newest-commit — The surviving version is the newest commit

| | |
|---|---|
| **Type** | Safety |
| **Property** | For each contested row, the version every node holds after quiescence is the committed version with the largest origin commit timestamp, with ties going to the writer with the lower tiebreaker. |
| **Invariant** | Workload `Always`: each writer records its xid (`pg_current_xact_id()` inside the transaction) and, after COMMIT, `pg_xact_commit_timestamp` on the origin; the expected winner per row is max by (commit ts, lower writer tiebreaker); every node's `(writer, wseq)` must equal it. Supporting SUT-side `Sometimes` for both LUW directions (newer local kept, newer remote applied). `Always` because the claim is per row. |
| **Antithesis Angle** | Clock skew makes "newest" differ from arrival order; clock ties reach the tiebreak (L2); restart of a node behind in time (L3) lets it stamp an older ts than a version it already applied. |
| **Why It Matters** | Convergence alone accepts all nodes agreeing on the wrong (older) version; this catches the resolver choosing badly everywhere. |

**Open Questions:**

- Does the tie rule mean "lower tiebreaker of the two writers" (docs) or "applying node vs sender" (code)?
- Is the commit ts in `pg_commit_ts` on the origin exactly the ts carried to peers after the commit-clock patch adjusts it?

Confidence: medium
Evidence file: properties/luw-final-value-is-newest-commit.md

### local-overwrite-after-remote-read-wins-everywhere — A write made after seeing a version never loses to it

| | |
|---|---|
| **Type** | Safety |
| **Property** | If a client on X reads a row version that X received from P and then updates that row on X, with no later writes elsewhere, every node ends up holding X's update. |
| **Invariant** | Workload `Always(every node holds X's version)` for rows in a reserved key range driven as causal chains (P writes, X observes P's version, X writes). Workload `Sometimes(X restarted between read and write while its clock was behind, "causal overwrite after restart with lagging clock")` to show the dangerous state was reached. `Always` because causality must hold each time. |
| **Antithesis Angle** | Needs clock skew with X behind plus a restart of X between applying P's version and the local update: `lastTransactionStopTimestamp` in `XLogCtl` is zeroed at startup, and the patch says "This is not postmaster restart safe" (L3). The divergence is silent: origin-differs is never written to `spock.resolutions`. |
| **Why It Matters** | Read-modify-write on a node is the most common application pattern; losing it silently on peers while the writer keeps it is permanent divergence with no record. |

**Open Questions:**

- Does the team accept L3 as a known limit, and is a maximum clock skew documented?
- Is a restore of the logical clock at startup planned?

Confidence: medium
Evidence file: properties/local-overwrite-after-remote-read-wins-everywhere.md

### insert-conflict-recorded-in-resolutions — insert_exists conflicts are recorded

| | |
|---|---|
| **Type** | Safety |
| **Property** | With `spock.save_resolutions=on`, when two nodes both commit a client INSERT of the same key, every node that receives the second-arriving INSERT records an `insert_exists` row for that key in `spock.resolutions`, or an `exception_log` row if the transaction was dropped. |
| **Invariant** | Workload `Always` after barriers: for each key with two or more committed client INSERTs on different nodes, each receiving node (including the third node) has a matching `spock.resolutions` row (`conflict_type='insert_exists'`, filtered by `node_name`) or an `exception_log` row for that transaction. Suggested SUT-side `AlwaysOrUnreachable(save_in_resolutions || origin-differs, ...)` in `spock_report_conflict`. Scoped to inserts because update/update and delete/update "origin differs" events are documented as not recorded (`docs/conflict_types.md:19-27`; code `src/spock_conflict.c:~395-445`). `Always`: each pair must leave a record. |
| **Antithesis Angle** | Partitions and latency let both nodes commit the same key before either sees the other; concurrent apply workers inserting the same key reach the lookup-then-insert race (L6a, `src/spock_apply_heap.c:873-925`) that turns the conflict into 23505 and a dropped transaction; postmaster kills check that the record and the applied change commit together. |
| **Why It Matters** | `spock.resolutions` is how operators and repair tooling see which version LUW threw away; an unrecorded overwrite is silent data loss from the user's view. |

**Open Questions:**

- Should a remote UPDATE thrown away because the local row is newer (`update_origin_differs` with KeepLocal) be recorded? `docs/configuring.md:506-510` says "all conflict resolutions"; `docs/conflict_types.md` says not.

Confidence: medium
Evidence file: properties/insert-conflict-recorded-in-resolutions.md

## Category: Origin filtering

### no-change-applied-on-its-origin-node — No replication echo

| | |
|---|---|
| **Type** | Safety |
| **Property** | In a default mesh (`forward_origins` empty), a change from node N is never applied back on N, and on every other node it is stamped with N's node id as origin. |
| **Invariant** | Workload `Always`, checkable during the run: no `apply_audit` row on N has `origin_node = N`, and `pg_xact_commit_timestamp_origin(xmin).roident` of applied, not-yet-overwritten ledger rows equals the origin's node id. Suggested SUT-side `Unreachable("apply received a transaction whose origin is this node")` and `Unreachable("apply received origin id 0 or 65535")` in `handle_origin` (`src/spock_apply.c:1301-1335`), and `Unreachable("walsender sent a non-local transaction while forward_origins is empty")` in `pg_decode_begin_txn`. |
| **Antithesis Angle** | Worker restarts and exits exercise the origin set-up (`src/spock_apply.c:4749-4750`) and reset (`spock_apply_worker_shmem_exit`, `:2322`) paths; any apply write that committed with no origin would be decoded as local by every walsender (`pg_decode_origin_filter`, `src/spock_output_plugin.c:1201-1222`) and loop. A targeted config with a node name hashing to id 0 reaches L24. |
| **Why It Matters** | An echo loop re-applies every change around the mesh forever: duplicate side effects, delta double counting, and unbounded WAL. |

**Open Questions:**

- Should `node_create` reject ids 0 and 65535?
- Can an ORIGIN-less transaction arrive (json protocol, mixed versions)? `handle_begin` resets only `remote_origin_id`, so the previous transaction's origin would be reused.

Confidence: medium
Evidence file: properties/no-change-applied-on-its-origin-node.md

---

## Areas examined

- `src/spock_apply.c`: `handle_begin` (~651-700), `handle_origin` (1301-1360), `handle_commit` (~940-1140, origin advance rules for each exception mode, empty-transaction origin advance), `should_apply_changes_for_rel` (463-484), `spock_apply_worker_shmem_exit` (2304-2325), worker start origin set-up (4740-4760).
- `src/spock_apply_heap.c`: `create_edata_for_relation`/`finish_edata` (trigger firing, 140-190), `build_delta_tuple` (510-582), `spock_handle_conflict_and_apply` (589-790), `spock_apply_heap_insert` (837-930).
- `src/spock_conflict.c`: `conflict_resolve_by_timestamp` (99-200), `get_tuple_origin` (219-275), `try_resolve_conflict`, `spock_report_conflict` (371-520, `save_in_resolutions` rules), `spock_conflict_log_table` (628-760).
- `src/spock_output_plugin.c`: `pg_decode_begin_txn` origin message (600-640), `pg_decode_origin_filter` (1201-1222).
- `src/spock_sync.c`: COPY session origin set-up (925-958).
- `src/spock_functions.c`: `spock_pause_apply_workers` (4055-4126).
- `sql/spock--6.0.0.sql`: `wait_for_sync_event` (685-780).
- `samples/Z0DAN/zodan.sql`: Phase 7 slot/origin advance and fallback (2620-2680).
- `docs/conflict_types.md`, `docs/conflicts.md`, `docs/configuring.md` (resolutions, delta apply, exception modes).
- sut-analysis leads L1-L7, L12, L17-L20, L24 and claims S1-S6, S12-S14; section 12 workload boundaries.

## Assumptions affecting multiple properties

- **Oracle tables.** The workload owns: an insert-only `ledger` (+ `ledger_b`)
  keyed `(origin_node, seq)` with a `txn_tag`; a `contested` table of
  pre-seeded rows for update-only conflicts; a `counters` table with a
  delta-apply column; a `dupkeys` table for insert/insert conflicts; and on
  every node a local, non-replicated `apply_audit` table filled by an
  `ENABLE ALWAYS` trigger that fires only under
  `session_replication_role = replica`. The trigger approach relies on
  Spock's apply using `ExecSimpleRelationInsert/Update` with after-trigger
  queries (code-checked) and on stock PG firing ALWAYS row triggers for
  `COPY FROM` in replica role (not checked in this tree).
- **Barrier.** Check phases use `sync_event` + `wait_for_sync_event` for every
  ordered pair with a timeout of at least `spock.apply_idle_timeout` plus
  slack, re-run after any crash. If a barrier times out, the round's safety
  checks are skipped and the failure is reported through liveness properties,
  not as data loss.
- **Exception mode.** Main runs use `transdiscard` with
  `spock.save_resolutions=on`; a `sub_disable` variant is possible. `discard`
  is excluded (non-atomic by design).
- **Client durability.** Client sessions keep `synchronous_commit=on`, so an
  acknowledged commit is durable on its origin node; apply sessions run with
  `synchronous_commit=off` (Spock default), which is fine because feedback only
  confirms flushed positions.
- **Stock PG origin behaviour** (sut-analysis Assumption 1): commit records
  carry `replorigin_session_origin`; redo advances `XLogRecGetOrigin(record)`;
  `RecordTransactionCommit` advances the session origin before
  `ProcArrayEndTransaction`. L1 and the barrier race depend on this.
- **Faults.** Several properties only bite with node termination (restart on
  the same PGDATA), clock skew, and single-worker graceful exits
  (`pg_cancel_backend`/`pg_terminate_backend` via a test command). If the
  tenant has node termination or clock faults off, these properties pass
  without being exercised; their `Sometimes`/`Reachable` companions show that.
- **Names.** Node and subscription names are lowercase, do not end in
  `_<digit>`, and do not hash to node id 0 or 65535, unless a targeted variant
  says otherwise.
