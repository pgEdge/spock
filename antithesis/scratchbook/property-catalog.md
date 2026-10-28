---
sut_path: /home/msharp/dev/pgedgea/spock
commit: 81aa0aecc4897475a6b6d784e9247cafc2712eba
updated: 2026-10-28
external_references: []
---

# Property Catalog — Spock (pgEdge multi-master replication)

## Summary

88 properties: 75 merged from eleven focus catalogs (92 candidates, 17 removed
as duplicates in 15 merges), plus 12 from the gap-fill step (topics a-c) and 1
from evaluation extra gap E2 (2026-10-13). Every property has one evidence
file at `properties/{slug}.md`. No Antithesis instrumentation exists in the tree, so
every SUT-side assertion named below is new work (see `existing-assertions.md`).

- **P0: 13**, **P1: 35**, **P2: 31**, **P3: 9** (after the open-question
  investigation pass, the evaluation refinements, the gap-fill step and its
  second evaluation pass; see the "Priority note" lines). P3 marks regression guards with no known path to failure at HEAD,
  or checks a TAP test does better: run them if cheap.
- 76 properties run in the v1 topology (n1-n3 full mesh, spare n4 joined by
  ZODAN, one workload client, PG18 pgEdge-patched, cassert build). 12 need a
  different topology, configuration or run length (`v2/mixed-version`,
  `v2/mixed-pg-major`, `v2/cascade`, `v2/colliding-names`, `v2/slot-groups`,
  `v2/small-capacity`, soak or `v2/standby`, `v2/phantom-sync-standby`, and
  the v1 `sub_disable` run variant).
- **Lead L1 is confirmed by code reading on patched PG18** (two investigation
  groups): crash redo advances an origin numbered by the provider's node id,
  not the subscription origin. `crash-redo-leaves-no-node-id-origin-state` is
  expected to fire on the first subscriber crash between checkpoints, and the
  redelivery properties built on L1 are reachable, not only guards. Node
  termination with PGDATA kept is what reaches them.
- **Clock faults are global.** Antithesis clock skips move all containers
  together, forward or backward. A global backward skip is enough to reach
  the LUW leads L2 and (with a restart) L3; no per-container skew is needed.
- **Gate before clock faults:** `apply-survives-provider-clock-ahead` is
  confirmed by code reading (`src/spock_apply.c:1173-1174`, Assert marked
  "Don't care in production yet"). On the cassert build any backward clock
  skip crash-loops every node. The team's fix exists on branch
  `task/SPOC-688/apply-clock-skew-fix` (commit 4e0988de, not in main at
  69d9228f): build the clock-fault image from main plus 4e0988de, or every
  clock timeline turns into that one failure.
- Many properties need **single-worker graceful exits** (`pg_cancel_backend`,
  `pg_terminate_backend`, `sub_disable`, `pg_ctl stop -m fast`) driven by a
  test command or custom fault. Antithesis node termination is a postmaster
  SIGKILL, which wipes Spock shared memory and skips those paths. These
  helpers are required harness components, not fallbacks (see
  `deployment-topology.md`): single-worker cancels and terminates go over SQL
  (`pg_cancel_backend` / `pg_terminate_backend` on pids picked by
  `backend_type`, or `COPY ... TO PROGRAM 'kill -<SIG> <pid>'`); `pg_ctl` and
  postmaster kills run as test commands inside the node containers.
- **Evaluation refinements (2026-10-13)**, applied below; see
  `evaluation/synthesis.md`:
  - Properties whose bug fires on the first trigger carry the line
    "Placement: Expected to fire deterministically — confirm with TAP first,
    then gate out of the main template": `crash-redo-leaves-no-node-id-origin-state`,
    `apply-cancel-retried-not-discarded`, `terminate-active-transactions-never-discards-inbound`,
    `readonly-local-keeps-inbound-ddl-flowing`, `apply-search-path-not-leaked-across-transactions`,
    `luw-unchanged-toast-no-mixed-rows`, `replicated-values-mean-same-on-every-node`
    (domain/OID cases), `remove-node-clean-report-no-leftovers`,
    `proto5-replay-reparses-startup-message`. Their P0/P1 rank is a severity
    rank, not a measure of how much Antithesis adds.
  - Properties that L1 or L3 make fail split their messages into "explained
    by L1/L3" and "unexplained". Only the unexplained messages count as new
    findings while L1 and L3 are open, so a second cause is not hidden behind
    the first.
  - "No `exception_log` rows" means no rows outside the workload's
    expected-exception registry (poison transactions and `update_missing`
    writes, recorded by origin, remote xid and table) and only on non-poison
    tables.
  - Properties that need a crash at a moment the workload picks use a
    workload-driven crash helper (one custom fault or node-container test
    command that does the action and then `kill -9` of the postmaster after a
    random 0-300 ms delay). Antithesis node termination stays on for kills at
    unplanned moments.
  - There is no Antithesis C SDK. SUT-side assertions go through a small C++
    shim compiled into `spock.so` with `extern "C"` wrappers, or a fallback
    JSONL writer; every SUT-side message is declared at `_PG_init`.
  - `spock.exception_log` has no SQLSTATE column: checks match message text,
    with `lc_messages = 'C'` on every node. Server-log checks read the logs
    through `logging_collector` and `pg_read_file`.
- **Gap-fill (2026-10-13)**, see `discovery/gap-*.md` and the "Second pass
  (gap-fill)" section of `evaluation/synthesis.md`: an explained-divergence
  oracle on a realistic mixed-DML app table
  (`every-divergence-explained-by-spock-records`), a strict final round with
  no state exemptions, operator recovery steps, add_node bounds, the
  SIGTERMed sync worker, provider-side and less common paths (TRUNCATE, 2PC
  commit timestamps, the sync-standby hold, subscriber failover), two
  harness guards (idle timeout on quiet links, slot-group names), and the
  `sub_disable` outcome (extra gap E2, lead L27). Extra gap E1 (slot
  invalidation) did not become a property; see "Out of scope".
  `prepared-commit-ts-matches-sent-ts` and
  `sync-standby-hold-freezes-provider-confirmed-flush` (mechanism 1) are
  also expected to fire deterministically: confirm with TAP first.

"Faults" below names what the property needs to be able to fail. "Worker exit"
means a test command that cancels or terminates one Spock backend; "admin churn"
means a workload phase that runs `sub_resync_table`, `sub_disable`/`sub_enable`
and `sub_drop`/re-create during writes.

## Priority overview

| Slug | Type | Assertion | Priority | Topology | Key fault |
|---|---|---|---|---|---|
| committed-ledger-row-reaches-every-node | Safety | Always | P0 | v1 | worker exit, partition, node kill |
| ledger-row-applied-exactly-once-per-peer | Safety | Always | P0 | v1 | node kill between checkpoints |
| delta-counter-equals-committed-increments | Safety | Always | P0 | v1 | node kill, worker exit |
| causally-deleted-row-stays-deleted | Safety | Always | P1 | v1 | node kill between checkpoints |
| remote-transaction-all-or-nothing-per-node | Safety | Always | P1 | v1 | worker exit, admin churn |
| graceful-restart-preserves-exactly-once | Safety | Always | P1 | v1 | graceful stop (test cmd) |
| no-change-applied-on-its-origin-node | Safety | Always | P3 | v1 | worker restarts |
| truncate-ordered-with-same-origin-dml | Safety | Always | P2 | v1 | worker exit, node kill between checkpoints |
| sync-event-barrier-implies-visible | Safety | Always | P0 | v1 | CPU modulation, worker exit |
| sync-event-barrier-survives-subscriber-restart | Liveness | Always (bounded) | P1 | v1 | node kill between checkpoints |
| sync-wait-functions-honor-contract | Safety | Always | P2 | v1 | partition / kill during COPY |
| apply-cancel-retried-not-discarded | Safety | Always | P0 | v1 | worker exit (cancel) |
| terminate-active-transactions-never-discards-inbound | Safety | Always | P1 | v1 | test cmd during apply |
| lock-contention-retried-not-discarded | Safety | Always | P1 | v1 | thread pause, local lock contention |
| insert-race-resolved-not-discarded | Safety | Always | P1 | v1 | latency, thread pause |
| exception-replay-only-after-recorded-error | Safety | Unreachable | P1 | v1 | worker exit, partition |
| exception-replay-never-reruns-committed-transaction | Safety | Unreachable | P1 | v1 | worker exit (cancel) during add_node |
| interrupted-exception-replay-still-records-txn | Safety | Always | P1 | v1 | worker exit during replay |
| proto5-replay-reparses-startup-message | Safety | Always + Unreachable | P2 | v1 | reconnect + data error |
| redelivered-ddl-not-turned-into-exception | Safety | Always | P1 | v1 | node kill after DDL |
| readonly-local-keeps-inbound-ddl-flowing | Safety | Always | P1 | v1 | none (ordering); readonly toggles |
| worker-respawn-rate-bounded | Safety | Always + Unreachable | P3 | v1 | worker exit (capacity part: v2/small-capacity) |
| sub-disable-error-ends-disabled-and-recorded | Liveness | Always (bounded) + Unreachable | P2 | v1 (`sub_disable` variant) | latency, worker exit during replay |
| contested-rows-converge-after-quiesce | Safety | Always | P0 | v1 | clock skew, partition |
| luw-final-version-has-max-commit-ts | Safety | Always | P1 | v1 | clock skew + node kill |
| local-overwrite-gets-later-commit-ts | Safety | Always | P1 | v1 | clock skew + node kill |
| luw-tiebreak-against-third-origin-row-reached | Reachability | Sometimes | P1 | v1 | clock skew, latency |
| clock-step-forward-makes-commit-ts-ties | Reachability | Sometimes | P2 | v1 | clock step (global backward) |
| apply-survives-provider-clock-ahead | Safety | Unreachable | P2 | v1 | clock skew |
| luw-unchanged-toast-no-mixed-rows | Safety | Always | P0 | v1 | latency, partition |
| prepared-commit-ts-matches-sent-ts | Safety | Always | P1 | v1 (+ 2PC writers) | none (direct check); clock skip |
| add-node-success-new-node-has-every-row | Safety | Always | P0 | v1 | pause provider, partition, node kill |
| add-node-pause-held-until-progress-read | Safety | Unreachable + Always | P0 | v1 | source xid held past `pause_timeout` (1 s) during slot creation |
| add-node-success-has-sub-from-every-peer | Safety | Always | P2 | v1 | partition during Phase 3 |
| add-node-after-peer-restart-captures-every-peer | Safety | Always + Unreachable | P2 | v1 | node kill of source before add_node |
| initial-sync-ends-ready-or-visibly-disabled | Liveness | Always (bounded) | P1 | v1 | kill / partition during sync |
| zodan-readd-node-progress-not-stale | Safety | Always | P2 | v1 | re-add + source restart |
| remove-node-clean-report-no-leftovers | Safety | Always | P3 | v1 | partition / latency during remove_node |
| add-node-returns-within-bound | Liveness | Always (bounded) | P2 | v1 | partition + kill of a peer during add_node |
| add-node-pause-released-after-caller-dies | Liveness | Always (bounded) + Reachable | P3 | v1 | kill of the pausing caller |
| feedback-never-confirms-undurable-apply | Safety | Always | P0 | v1 | worker exit then node kill |
| crash-redo-leaves-no-node-id-origin-state | Safety | Unreachable | P0 | v1 | node kill between checkpoints |
| apply-stream-framing-and-lsn-order | Safety | Always | P2 | v1 | walsender kill, reconnect |
| progress-insert-lsn-never-ahead-of-provider | Safety | Always | P2 | v1 | reconnect + data error |
| progress-reconcile-anomaly-unreachable | Safety | Unreachable | P2 | v1 | node kill during add_node |
| progress-commit-lsn-tracks-applied-commits | Safety | Always | P3 | v1 | clock skew + node kill |
| enabled-subscription-always-has-provider-slot | Safety | Always | P1 | v1 | node kill during sub_drop |
| provider-slot-owned-by-one-subscription | Safety | Always | P2 | v2/colliding-names | partition during initial sync |
| forwarded-origin-advance-no-double-apply | Safety | AlwaysOrUnreachable | P2 | v2/cascade | node kill after commit |
| sync-standby-hold-freezes-provider-confirmed-flush | Safety | Always | P1 | v2/phantom-sync-standby | none (L9); restarts, walsender kills |
| promoted-subscriber-standby-has-every-confirmed-txn | Safety | Always | P2 | v2/standby | standby pause, subscriber kill |
| walsender-never-joins-slot-group | Safety | Unreachable | P3 | v1 | none (setup guard) |
| sub-disable-enable-cycle-loses-and-duplicates-nothing | Safety | Always | P1 | v1 | admin churn |
| readonly-toggle-resumes-without-loss | Safety | Always | P1 | v1 | readonly toggles + partitions |
| readonly-all-never-commits-remote-txn | Safety | AlwaysOrUnreachable | P2 | v2/slot-groups | readonly toggles, thread pause |
| sub-drop-vs-table-sync-no-deadlock | Liveness | Always (bounded) | P1 | v1 | admin churn, thread pause |
| apply-never-waits-on-dead-sync-worker | Liveness | Unreachable + Always | P1 | v1 | partition during resync |
| manager-kill-targets-only-listed-worker | Safety | Always | P1 | v1 | admin churn + worker error exit |
| resource-dat-dumps-serialized | Safety | Always | P1 | v1 | concurrent resyncs, node kill |
| fast-shutdown-completes-within-bound | Liveness | Always (bounded) | P2 | v1 | graceful stop (test cmd) |
| sync-worker-sigterm-never-skips-catchup | Safety | Unreachable | P1 | v1 | graceful stop / terminate during resync |
| crashed-node-returns-to-streaming | Liveness | Always (bounded) | P1 | v1 | node kill |
| mesh-barriers-complete-after-partition-heal | Liveness | Always (bounded) | P1 | v1 | partition, pause |
| apply-worker-restarted-within-bound-after-exit | Liveness | Always (bounded) | P2 | v1 | worker exit, clock step back |
| sub-show-status-reflects-apply-state | Safety | Always | P2 | v1 | silent partition, pause |
| operator-recovery-steps-restore-replication | Liveness | Always (bounded) | P1 | v1 | kill / partition during sync and add_node |
| quiet-link-never-hits-idle-timeout | Safety | Unreachable | P3 | v1 | none in checked windows |
| exception-log-slots-never-exhausted | Safety | Unreachable | P1 | v1 (race route); v2/small-capacity (capacity route) | resync right after restart; fresh-name subscription churn |
| progress-hash-capacity-survives-node-churn | Safety | Unreachable | P2 | v2/small-capacity | node churn (fresh node names) |
| replication-origin-states-do-not-leak | Safety | Unreachable + Always | P2 | v1 | node kill, resync interrupts |
| no-orphan-slot-pins-wal-after-quiesce | Safety | Always | P1 | v1 | partition during sub_drop, kills |
| replay-spill-file-lifecycle | Safety | Always + Unreachable | P2 | v1 | faults during large txns |
| spock-connections-match-subscriptions-after-quiesce | Safety | Always | P2 | v1 | partition during admin calls |
| apply-stale-socket-never-polled | Safety | Unreachable | P2 | v1 | walsender kill during replay |
| apply-worker-memory-bounded | Safety | AlwaysOrUnreachable | P2 | soak / v2/standby | long runs, data errors |
| exception-log-matches-discarded-transactions | Safety | Always | P1 | v1 | worker exit, data errors |
| insert-conflict-recorded-in-resolutions | Safety | Always | P2 | v1 | partition, latency |
| resolutions-rows-match-applied-outcome | Safety | Always | P2 | v1 | latency, clock skew |
| every-divergence-explained-by-spock-records | Safety | Always | P1 | v1 | latency, partition, node kill, clock skip |
| replicated-values-mean-same-on-every-node | Safety | Always | P1 | v1 | none (config); reconnects |
| apply-search-path-not-leaked-across-transactions | Safety | Always | P1 | v1 | worker restarts |
| apply-identity-restored-after-queued-sql | Safety | Always | P3 | v1 | worker exit during DDL |
| convergence-check-runs-after-faults | Liveness | Sometimes + Always | P0 | v1 | all (oracle health) |
| strict-final-round-has-no-exemptions | Liveness | Always + Sometimes | P0 | v1 | all (oracle health) |
| mixed-version-add-node-loses-nothing | Safety | Always | P2 | v2/mixed-version | pause, partition, node kill |
| mixed-version-mesh-applies-exactly-once | Safety | Always | P2 | v2/mixed-version | same as v1 mesh |
| rolling-upgrade-node-restart-loses-nothing | Safety | Always | P2 | v2/mixed-version | node kill during upgrade |
| cross-pg-major-links-replicate-identically | Safety | Always | P3 | v2/mixed-pg-major | none (config) |

---

## Category A — Delivery: no loss, no duplicates

The base promise: every committed transaction reaches every peer once. These
use the shared oracle tables (insert-only `ledger` keyed `(origin_node, seq)`,
a delta-apply `counters` table, local `apply_audit` trigger tables) and run
after `sync_event` barriers on every ordered pair.

### committed-ledger-row-reaches-every-node — Committed rows reach every mesh node

| | |
|---|---|
| **Type** | Safety |
| **Property** | Every ledger row whose client COMMIT succeeded on any mesh node is present, with the same content, on every other mesh node once faults stop and pairwise `sync_event`/`wait_for_sync_event` barriers pass. |
| **Invariant** | Workload `Always`: for each committed `(origin_node, seq)` of the insert-only, conflict-free ledger, every node in scope (n1-n3; n4 for rows committed after a successful add_node) returns the row with identical payload. A commit whose outcome the client did not see (connection lost during COMMIT) is decided by reading the origin node after it returns; the row must then be on every node exactly as on the origin. A subscription disabled under `sub_disable` is not loss (its origin is not advanced past the failing transaction, `src/spock_apply.c:996-1009, 1067-1084`): it is reported through its own `Always`, re-enabled, and the ledger re-checked. Details name missing keys and whether that node's `spock.exception_log` has a row for the remote commit; the missing-row message is split into "ledger row missing, discarded with a recorded classifier error" (explained by L5 or the 40001 path while those stay open) and "ledger row missing with no exception_log row" (unexplained). Supporting SUT-side `Unreachable("apply entered exception replay in a conflict-free run")` at the "caught initial exception" branch of `apply_work` `PG_CATCH`, guarded by a per-configuration placeholder GUC (for example `antithesis.conflict_free = on` in `postgresql.conf`, read with `GetConfigOption`) that is off in templates that inject poison transactions. `Always` because one missing row is a bug: the ledger has no conflicts, so no documented divergence applies. |
| **Antithesis Angle** | Graceful apply exits (cancel 57014, terminate, FATAL paths) and partitions drive the error classifier (L5) and the replay origin advance (L7); provider pauses drive `apply_idle_timeout`; postmaster kills drive async apply commit plus feedback. Postmaster kill alone wipes shared memory and hides L5/L7, so single-worker exits need a test command. |
| **Why It Matters** | Under default `transdiscard`, every misclassified infrastructure error silently drops an upstream transaction (only an `exception_log` row). The classifier has at least eleven past fixes of this shape. |

**Open Questions:**

None

Priority: P0 · Topology: v1 · Faults: worker exit (test cmd), partition, node kill
Confidence: high · Surfaced by: F1 Data Integrity (also the data check behind F7's `mesh-barriers-complete-after-partition-heal`)
Evidence: properties/committed-ledger-row-reaches-every-node.md
Evaluation note (2026-10-13): cancel (57014) and `terminate_active_transactions` (40001) test commands run in a separate classifier template until L5 and the 40001 path are fixed or accepted, so in the main template a missing row points at a new cause. Workload-side `Sometimes("cancel or terminate reached an apply worker with backend_xid set")` shows the dangerous state was reached without SUT instrumentation.
Partly implemented (2026-10-15): `test/v1/main/eventually_mesh_barriers.py`, after every ordered pair's sync barrier passes, reads the ledger on n1-n3 as `md5(l::text)` per row (all columns) sorted by `(origin, seq)` and compares the lists. One `Always("every mesh node holds the same ledger rows after sync barriers")`; details give rows per node, the number of differing rows, up to 20 sample keys with each node's hash or `missing`, and each node's count of `spock.exception_log` rows for `ledger`. Reach claim `Sometimes("ledger rows were compared on every mesh node after sync barriers")`. Skipped when any barrier missed or a subscription was disabled (reported by the barrier property), or when a writer session survived termination. Not yet: the client-side committed/unknown record (a row lost on every node, including its origin, is not caught), the explained/unexplained split by exception_log row, n4, and the SUT-side `Unreachable`.

### ledger-row-applied-exactly-once-per-peer — No transaction is applied twice on a peer

| | |
|---|---|
| **Type** | Safety |
| **Property** | Each committed ledger row from origin O is applied exactly once on each peer S, across subscriber crashes, worker restarts and reconnects. |
| **Invariant** | Three workload `Always` messages after barriers. (1) "ledger row has exactly one apply-audit entry per peer": the local, non-replicated `apply_audit` table on S (filled by an `ENABLE REPLICA` trigger, which fires only in sessions with `session_replication_role = replica`: apply and initial-copy sessions; an `ENABLE ALWAYS` trigger would also fire for local client inserts) has exactly one row per `(origin, seq)`; a redelivered INSERT becomes an `insert_exists` UPDATE and fires the trigger again. (2) "no insert_exists on insert-once ledger": `spock.resolutions` has no `insert_exists` row for the ledger tables; the resolutions row commits in the same transaction as the duplicate, so it survives exactly when the duplicate does. (3) "no two exception_log rows share (remote_origin, remote_commit_ts, command_counter)": a redelivered transaction that TRANSDISCARD drops again shows only as a second set of `exception_log` rows (never in resolutions). Suggested SUT-side `Always("incoming BEGIN commit_lsn is above the subscription origin's progress")` in `handle_begin`. `Always` because one double apply is a violation. |
| **Antithesis Angle** | Kill -9 of a subscriber postmaster between checkpoints (large `checkpoint_timeout`, no manual CHECKPOINT). Crash redo advances the origin numbered by the commit record's origin (the provider's node id, `handle_origin`, `src/spock_apply.c:1332`), not the subscription origin, so the subscription origin falls back to its checkpoint value and the provider resends committed but unconfirmed transactions (L1, confirmed by code reading on stock PG17 and patched PG18). Each redo-created node-id state takes a `max_active_replication_origins` slot (default 10) and persists; the harness sets it to 32 so redo does not stop on a full array. TAP 022/027 checkpoint before SIGKILL, so this path is untested. Oracle (2) also catches add-node overlap (rows copied with `'epoch'` ts). |
| **Why It Matters** | Plain rows mostly hide duplicates (same-origin equal-ts shortcut), but delta counters double count and triggers repeat side effects. The design doc reads as exactly-once for direct subscriptions. |

**Open Questions:**

- Does the team intend exactly-once or at-least-once on direct subscriptions? `(needs human input)`

Priority: P0 · Topology: v1 · Faults: node kill between checkpoints
Confidence: high (L1 mechanism code-checked on PG17 and patched PG18; not run) · Surfaced by: F1 Data Integrity, F11 Wildcard (oracle 2); also noted by F3 and F9
Evidence: properties/ledger-row-applied-exactly-once-per-peer.md
Evaluation note (2026-10-13): each of messages (1)-(3) is split by attribution: "... explained by L1" when S crashed since the row committed and S shows a node-id origin state (the `crash-redo-leaves-no-node-id-origin-state` probe), and "... unexplained" otherwise. Only the unexplained messages count as new findings while L1 is open. The kill must land inside the unconfirmed window after a burst, so the workload drives it with the crash helper and emits `Sometimes("subscriber killed within the unconfirmed window after an apply burst, no checkpoint since")`. Oracle (2) reads `spock.resolutions`: the harness sets `spock.resolutions_retention_days = 0` (or copies rows as they appear) so a forward clock skip cannot trigger the daily cleanup.
Merge note: F1's audit-trigger check and F11's insert-once/`insert_exists` check (merged in from its own candidate) test the same guarantee with two oracles; kept as two messages of one property so a split result points at the oracle.

### delta-counter-equals-committed-increments — Delta-apply counters equal the sum of committed increments

| | |
|---|---|
| **Type** | Safety |
| **Property** | For a NOT NULL delta-apply column (`log_old_value=true`, `delta_apply_function=spock.delta_apply` on every node) on pre-seeded rows, each row's value on every mesh node equals its initial value plus every committed increment from any node. |
| **Invariant** | Workload `Always` after barriers: per row, `val == initial + sum(committed k)` on every node; details report the difference (one k points at one lost or doubled transaction). Each increment transaction also writes a marker row; a commit whose outcome the client did not see is decided by reading the marker on the origin after it returns, so the expected total stays exact rather than a range. Supporting SUT-side `Reachable("delta apply forced on a row where LUW kept local")` and `Unreachable("delta column received NULL old value")` at `build_delta_tuple` (`src/spock_apply_heap.c:545`). `Always`: one wrong total is a violation. |
| **Antithesis Angle** | Delta apply is not idempotent (`spock_handle_conflict_and_apply`, `src/spock_apply_heap.c:589-790`), so any redelivery (L1 under postmaster kill) adds twice and any drop (L5/L7 under graceful exits and partitions) under-counts. Concurrent updates from all nodes exercise the forced-apply subtransaction with commit-ts override (patch 030). |
| **Why It Matters** | Spock claims the delta column "will be correctly calculated and applied" (`docs/conflicts.md:10-34`); the feature exists for balances and counters. |

**Open Questions:**

- Does the team treat at-least-once on direct subscriptions as a bug? If not, `docs/conflicts.md` needs a caveat for crashes. `(needs human input)`

Priority: P0 · Topology: v1 · Faults: node kill between checkpoints, worker exit
Confidence: high · Surfaced by: F1 Data Integrity (named as main oracle by F8, F9)
Evidence: properties/delta-counter-equals-committed-increments.md
Evaluation note (2026-10-13): the wrong-total message is split into "delta total off on a node that crashed since the increment and shows a node-id origin state" (explained by L1) and "delta total off, unexplained". Crash timing comes from the crash helper (kill within the unconfirmed window after a burst), with the same workload-side `Sometimes` as `ledger-row-applied-exactly-once-per-peer`. n4's counters are checked by `add-node-success-new-node-has-every-row`.

### causally-deleted-row-stays-deleted — A row deleted after its insert reached every node never comes back

| | |
|---|---|
| **Type** | Safety |
| **Property** | A row inserted on node A, seen on every node, and then deleted on a different node B is absent on every node after quiescence, across subscriber crashes and restarts. |
| **Invariant** | Workload `Always(no deleted id is present on any node)` after faults heal and every ordered pair passes a barrier. Keys are `(node, seq)` and nothing else writes these rows, which keeps the check clear of the documented no-tombstone cases. `Always` because one resurrected row is a violation. |
| **Antithesis Angle** | Kill -9 of subscriber S between checkpoints. L1 (confirmed by code reading on patched PG18) rewinds S's A->S origin and A resends the INSERT; whether B's DELETE is resent, and in which order the two subscriptions re-apply, is a race between two apply workers. Latency between B and S widens it. The window of applied-but-unconfirmed commits is up to `wal_sender_timeout/2` (30 s by default) on a quiet provider and about the walwriter delay under steady provider WAL (Spock sends no timed feedback), so kill S within that time after a burst and do not lower `wal_sender_timeout`. |
| **Why It Matters** | The resent INSERT finds no row and inserts it (`spock_apply_heap_insert`) with no conflict and no exception row: deleted data comes back on one node, permanently. The comment on `maybe_advance_forwarded_origin` assumes "last_update_wins handles the duplicate"; it does not here. |

**Open Questions:**

- Does the team treat at-least-once as acceptable for direct subscriptions? `(needs human input)`

Priority: P1 · Topology: v1 · Faults: node kill between checkpoints, latency
Confidence: medium (L1 confirmed by code reading on PG18; resurrection needs the re-apply order race) · Surfaced by: F9 Idempotency
Evidence: properties/causally-deleted-row-stays-deleted.md
Evaluation note (2026-10-13): split into "resurrected row on a node that crashed since the delete and shows a node-id origin state" (explained by L1) and "resurrected row, unexplained". The kill must land within the unconfirmed window after a burst on A followed by quiet; the workload drives it with the crash helper rather than waiting for a random kill.

### remote-transaction-all-or-nothing-per-node — Remote transactions are visible whole or not at all

| | |
|---|---|
| **Type** | Safety |
| **Property** | A multi-row, multi-table transaction from origin O is, at every moment a reader on another node looks, visible there completely or not at all (exception mode `transdiscard` or `sub_disable`). |
| **Invariant** | Workload `Always`, checked continuously during the fault phase: in one REPEATABLE READ snapshot per node, for every `txn_tag` seen across `ledger` and `ledger_b`, the row count equals the K the writer committed. Nodes with any `local_sync_status` other than `r`, and n4 before add_node returns, are skipped (non-`r` state recorded and counted, so a FAILED table is never hidden by the skip). Suggested SUT-side: `Sometimes("apply skipped a change for a FAILED table")` coverage marker in `should_apply_changes_for_rel` (`src/spock_apply.c:463-484`; skipping for FAILED is intended, 6a063b22), `Reachable("table sync marked FAILED after an interrupted attempt")` in `spock_sync_table` (`src/spock_sync.c:1846-1866`), and `Always("transdiscard commit wrote no user-table rows")` in `handle_commit`. |
| **Antithesis Angle** | Graceful exits during large transactions drive the replay paths; table resync under writes reaches the per-table filter that applies part of a transaction while skipping tables that are not READY (any restart of a table-sync worker after STARTED marks the table FAILED, not only data errors); postmaster kills check crash atomicity (control). Initial subscription sync copies all tables under one snapshot in one target transaction, so it cannot expose part of a transaction. |
| **Why It Matters** | Partial transactions break application invariants (order and its lines, debit and credit) that no single-row convergence check would show. |

**Open Questions:**

- Should an infrastructure fault during a single-table resync (connection loss, worker or node kill) leave the table FAILED with its changes skipped until an operator resyncs? `(needs human input)`

Priority: P1 · Topology: v1 (FAILED-table path needs the admin-churn phase) · Faults: worker exit, admin churn, node kill
Confidence: medium · Surfaced by: F1 Data Integrity
Evidence: properties/remote-transaction-all-or-nothing-per-node.md
Evaluation note (2026-10-13): the FAILED-table path uses resyncs of a dedicated single-writer table (`resync_<P>`, written only on P), because a `truncate := true` resync of a table several nodes write loses rows for good and would fire the ledger checks for a reason the workload caused (see Assumption 5).

### graceful-restart-preserves-exactly-once — A graceful stop and restart of any node loses and duplicates nothing

| | |
|---|---|
| **Type** | Safety |
| **Property** | Across `pg_ctl stop -m fast` and restart of any node under writes, every node ends with exactly one copy of each committed ledger row, exact delta counters, no exception rows outside the expected-exception registry, all subs enabled, and the restarted node accepts connections within a bound. |
| **Invariant** | Workload `Always` at quiescence (graceful-stop variant only, or windows touched by a kill excluded). `Always` because the shutdown checkpoint makes origins durable, so even if crash restart is not exact (L1), graceful restart must be. Coverage marker (SUT-side): `Sometimes("supervisor shutdown drain timed out with apply workers still attached")` at `spock_supervisor_on_exit` (`src/spock.c`). |
| **Antithesis Angle** | Stops at random points: mid large transaction, during table sync or add_node, while peers reconnect. Exercises the SIGTERM path, the 5 s supervisor drain, `resource.dat` dump/load and reconcile at apply start. Fast mode only: smart shutdown waits for every client backend, including peers' plain connections. A stopping node's logical walsender waits for the subscriber's flush confirm, bounded by `wal_sender_timeout` (`WalSndDone`). The helper is a required harness component: a test command inside the node container runs `pg_ctl stop -m fast`, and the node wrapper loop restarts postgres (`COPY ... TO PROGRAM` is not a safe route for `pg_ctl`: it is a child of a backend and is signalled at shutdown). |
| **Why It Matters** | Baseline for upgrades and maintenance; separates "restart is broken" from "crash redo is broken" (L1), which otherwise look the same in a failing run. |

**Open Questions:**

None

Priority: P1 · Topology: v1 · Faults: graceful stop (test command), partition
Confidence: medium · Surfaced by: F8 Lifecycle
Evidence: properties/graceful-restart-preserves-exactly-once.md
Evaluation note (2026-10-13): "windows touched by a kill" are found through the node wrapper's boot counter and last-exit kind, which the workload reads with `pg_read_file` (Antithesis does not announce kills).
Implemented (2026-10-28): node-side driver `node/test/v1/main/parallel_driver_graceful_restart.sh` (Bash: the node image has no Python; it makes no assertions) runs `pg_ctl stop -m fast` on a mesh node (n4 skipped) and leaves the restart to `node-entrypoint.sh` after a delay from the menu {0, 1, 4, 5, 6, 30} s (around `spock.restart_delay_default` = 5 s), passed through the one-shot `/data/state/restart_delay` so the node comes back even if the driver is killed. Restart weight swarmed per node and timeline: {0, 10, 50}%, with at least 120 s between restarts of one node (lowered on 2026-10-28 after run cc5efb7fc91df5442f7ccf293e30703b-64-9, where {0, 20, 100}% and 60 s halved the eventually checks and cut writer runs by a quarter). Before stopping it watches for up to {0, 2, 10} s for a ledger writer or an apply worker inside a remote transaction and stops when one shows up (the same run met a writer in 0 of 278 stops at random moments). Each restart is a `/data/state/graceful.log` line (stop time, delay, seconds to accept connections, writer sessions and apply workers with `backend_xid` at the stop). Assertions in `test/v1/main/eventually_mesh_barriers.py`: per record `Always("a gracefully stopped node accepts connections within 2 minutes of starting again")`; reach claims `Sometimes("graceful stop cut short a ledger writer's transaction")` and `Sometimes("graceful stop cut short an apply worker's remote transaction")`, counted from the xids open at the stop that `pg_xact_status()` reports aborted after the restart. In a timeline with at least one clean postmaster exit (`exit=0` in `exits.log`) and no crash recovery on any mesh node (`automatic recovery in progress` in the server log; this also catches a backend crash, which restarts the postmaster in place with no `exits.log` line): `Reachable("exactly-once checked after a graceful restart with no crash")`, `Always("every subscription is enabled after graceful restarts")`, `Always("no ledger row applied twice across graceful restarts")` (no `insert_exists` row for `public.ledger` in `spock.resolutions`), and, when the sync barriers passed, `Always("every mesh node holds the same ledger rows after graceful restarts")` and `Always("no ledger transaction discarded across graceful restarts")`. SUT-side `Sometimes("supervisor shutdown drain timed out with apply workers still attached")` in `spock_supervisor_on_exit`. Not yet: delta counters (no counters table), the expected-exception registry (the ledger expects none), stops during table sync or add_node (no such drivers yet).

### no-change-applied-on-its-origin-node — No replication echo

| | |
|---|---|
| **Type** | Safety |
| **Property** | In a default mesh (`forward_origins` empty), a change from node N is never applied back on N, and on every other node it is stamped with N's node id as origin. |
| **Invariant** | Workload `Always`, checkable during the run: no `apply_audit` row on N has `origin_node = N`, and `pg_xact_commit_timestamp_origin(xmin).roident` of applied, not-yet-overwritten ledger rows equals the origin's node id. Setup check: no node id (`hashtext(name) & 65535`) is 0 or 65535 in the default template. Suggested SUT-side `Unreachable("apply received a transaction whose origin is this node")`, `Unreachable("apply received origin id 0 or 65535")` in `handle_origin`, and `Unreachable("walsender sent a non-local transaction while forward_origins is empty")` in `pg_decode_begin_txn`. |
| **Antithesis Angle** | Worker restarts and exits exercise origin set-up and reset. An ORIGIN-less transaction cannot reach apply (the native protocol always sends ORIGIN in v5 and v6; subscribers never request json). A targeted config with a node name hashing to id 0 or 65535 reaches L24. |
| **Why It Matters** | With node id 0 a change is echoed one extra hop back onto its origin node and no origin progress is recorded; with 65535 there is no echo but still no origin progress, so barriers hang and transactions are redelivered. Either gives duplicate side effects and delta double counting. |

**Open Questions:**

- Should node creation reject ids 0 and 65535? `(needs human input)`

Priority: P3 · Topology: v1 · Faults: worker restarts
Priority note: lowered from P2 in evaluation: in v1 the real failure (node id 0 or 65535) is a configuration the harness avoids, so the id check is a setup assertion plus a small TAP test for ids 0/65535; the runtime checks stay as cheap guards.
Confidence: medium · Surfaced by: F1 Data Integrity
Evidence: properties/no-change-applied-on-its-origin-node.md
Evaluation note (2026-10-13): the "no apply_audit row on N has origin_node = N" check depends on the audit trigger being `ENABLE REPLICA` (see `ledger-row-applied-exactly-once-per-peer`); with `ENABLE ALWAYS` it would fire on every local write.

### truncate-ordered-with-same-origin-dml — TRUNCATE and nearby inserts from one origin reach every peer in order

| | |
|---|---|
| **Type** | Safety |
| **Property** | On a table written only by its owner node, after a barrier every peer's copy equals the owner's: TRUNCATE and the inserts before and after it are applied in commit order, none dropped, none applied twice in a way that changes the result. |
| **Invariant** | Workload `Always("single-owner table after TRUNCATE has the same rows on every peer as on its owner")`, comparing `(epoch, seq)` sets after the owner-to-peer barrier. Companions `Sometimes("TRUNCATE applied on a peer within a transaction that also inserted")` and `Sometimes("TRUNCATE-bearing transaction passed through exception replay")`. |
| **Antithesis Angle** | Worker exits and walsender kills during TRUNCATE-bearing transactions push them through the exception and replay paths in `handle_truncate` (`src/spock_apply.c:2135-2210`), each of which has a recent fix (940e500d, 162dc562); subscriber kills between checkpoints redeliver them (L1); reader locks make apply wait on AccessExclusiveLock; a resync of the table during faults makes apply skip the TRUNCATE and rely on the sync. |
| **Why It Matters** | TRUNCATE is banned from the workload today and no property covers the 'T' message or `pg_decode_truncate`. A single-owner table avoids the documented cross-origin ordering problem, so TRUNCATE can run under faults. A dropped TRUNCATE leaves stale rows on one node with nothing to repair them. |

**Open Questions:**

- Is a TRUNCATE-only redelivery (TRUNCATE replayed without the inserts committed after it) possible? `(partial: none found; all are in one transaction and the origin advances at commit)`
- Should TRUNCATE respect the subscription's replication sets? It does not today (TAP finding under "Out of scope"); not reachable in v1 because every subscription uses the same default sets.

Priority: P2 · Topology: v1 (one `trunc_<node>` table per node, written only by that node) · Faults: worker exit, walsender kill, node kill between checkpoints, reader lock contention
Confidence: medium (paths code-checked; no open lead) · Surfaced by: Evaluation gap c
Evidence: properties/truncate-ordered-with-same-origin-dml.md
Second-pass note (2026-10-13): the `trunc_<node>` tables are excluded from the ledger, delta, contested and convergence checks; the Assumption 5 TRUNCATE ban stays for shared tables.

---

## Category B — Sync barriers

`spock.sync_event()` + `wait_for_sync_event()` is how ZODAN, operators and
this harness decide that replication caught up. Every convergence check above
assumes the barrier is correct.

### sync-event-barrier-implies-visible — A satisfied sync barrier means the provider's earlier commits are visible

| | |
|---|---|
| **Type** | Safety |
| **Property** | When `wait_for_sync_event(P, L)` returns true on S, a new snapshot on S sees every effect of every P-originated transaction committed before `sync_event()` was called on P, or `spock.exception_log` names that transaction. |
| **Invariant** | Workload `Always("barrier true implies earlier provider rows visible")` after each successful barrier, run repeatedly during faults, not only at the end; on failure re-read after 1 s to separate a visibility race (rows appear) from a drop (rows stay missing). Expected to hold: a guard. Separate `Always` message for rows written inside a `sync_event(true)` caller's own transaction; that is where firings are expected. Companion `Sometimes("transactional barrier satisfied in the same apply transaction as ledger rows")`. |
| **Antithesis Angle** | The procedure polls `pg_replication_origin_status.remote_lsn` (`sql/spock--6.0.0.sql:685-762`). For rows committed before `sync_event()` this is safe: messages apply in order and each commit finishes (ProcArrayEndTransaction included) before the next message, so they are visible before the origin reaches L. For DML in the caller's own transaction T, a concurrent commit on P after the marker record can move S's origin past L before T arrives, and T's own commit advances the origin before T is visible. That window is inside core commit (`RecordTransactionCommit` to `ProcArrayEndTransaction`), which thread pausing does not reach while core is uninstrumented, so only CPU modulation and luck widen it. TRANSDISCARD drops also advance the origin. |
| **Why It Matters** | Every convergence oracle and ZODAN itself rely on this barrier (dcbba6bb fixed the same ordering on the add-node path). A wrong barrier gives false alarms or hides loss. Scored P0 for that reason. |

**Open Questions:**

- Is DML in the transaction that calls `sync_event(true)` meant to be covered by the barrier? `(needs human input)` `(partial: code cannot guarantee it — a concurrent commit after the marker record can move the origin past L before T arrives, and T's own commit advances the origin before T is visible; rows committed before the call are covered)`
- Should the barrier report true when the origin passed L only because a transaction was discarded? `(needs human input)` `(partial: handle_commit advances the origin on DISCARD/TRANSDISCARD on purpose and the docs describe discard as "skip the failed transaction and continue"; nothing says what a barrier should report)`

Priority: P0 · Topology: v1 · Faults: CPU modulation, worker exit (thread pausing reaches the own-transaction window only if core `xact.c` is instrumented)
Confidence: medium (mechanism code-checked on PG18; main check expected to hold, own-transaction check expected to fire) · Surfaced by: F1 Data Integrity, F4 Protocol
Evidence: properties/sync-event-barrier-implies-visible.md

### sync-event-barrier-survives-subscriber-restart — A reached sync barrier is reached again after the subscriber restarts

| | |
|---|---|
| **Type** | Liveness |
| **Property** | Once `wait_for_sync_event(P, L)` returned true on S, after S restarts the same call returns true again within a bound even when P commits nothing new. |
| **Invariant** | Workload `Always("re-check of a reached sync_event marker returns true after subscriber restart")`: once per restart of S (crash or clean), with P's writers paused for that pair, `wait_for_sync_event(P, highest_reached_L, timeout => T)` returns true. Second message `Always("subscription origin remote_lsn never goes backwards across a clean restart")` on the raw value, for clean restarts only: after a crash the origin legitimately falls back over applied-but-unflushed async commits, which are re-sent. Companion `Sometimes("subscriber restarted after a marker was applied and before the next provider transaction")`. |
| **Antithesis Angle** | Node termination of S between checkpoints. Non-transactional markers and empty transactions advance the origin in shared memory only (L18, `src/spock_apply.c:1113-1131, 2955-2964`); normal commits are redone against the node-id origin (L1, confirmed by code reading on patched PG18). Feedback already moved P's `confirmed_flush` past L, so P never resends. |
| **Why It Matters** | ZODAN and operators re-check barriers after restarts, often while writes are stopped; such a re-check hangs (forever with the default `timeout = 0`) until unrelated traffic arrives. |

**Open Questions:**

- Is subscriber-side durability of marker progress part of the barrier contract, or must callers issue a fresh marker after any restart? `(needs human input)`
- Would WAL-logging the non-transactional advance be acceptable cost? `(needs human input)` `(partial: replorigin_advance() errors on the session-held origin, so a fix needs a direct XLOG_REPLORIGIN_SET write; a commit-based fix depends on fixing L1)`

Priority: P1 · Topology: v1 · Faults: node kill between checkpoints
Confidence: medium · Surfaced by: F3 Failure Recovery, F4 Protocol, F9 Idempotency
Evidence: properties/sync-event-barrier-survives-subscriber-restart.md
Evaluation note (2026-10-13): random kills rarely line up with "P quiet for this pair", so this runs as a scripted sequence: stop P's writers, take a marker, wait for it on S, call the crash helper on S, then re-check. Failures after a crash restart are reported as "explained by L1/L18"; failures after a clean restart are the unexplained message.
Resolution: F4 called this Safety (origin must not go backwards), F3 and F9 Liveness (re-check must complete). Catalogued as Liveness because the user-visible failure is a hang; F4's raw-value check is kept as a second message.

### sync-wait-functions-honor-contract — sub_wait_for_sync / table_wait_for_sync return only when synced and report a FAILED table instead of waiting

| | |
|---|---|
| **Type** | Safety |
| **Property** | When `sub_wait_for_sync` or `table_wait_for_sync` returns normally the copied data is present; and once the subscription-level sync status is `r`, they report a FAILED table instead of waiting on it. |
| **Invariant** | Two workload `Always` messages: (1) on normal return after a quiesced `sub_resync_table` (or a subscription created with data sync), every provider ledger row from the resync start is on S; (2) "sync wait reports FAILED table instead of waiting": if the subscription-level status is `r` and the target table (or any unsynced table, for `sub_wait_for_sync`) is `f`, the call raises rather than hitting the workload's `statement_timeout`. |
| **Antithesis Angle** | Partition or provider kill during COPY or table catch-up. The code checks FAILED only after the subscription-level row is `r`. ZODAN never calls the C wait function (it uses its own SQL loop, which also accepts `y`), so the workload calls `sub_wait_for_sync` itself, on the ZODAN-created src -> n4 subscription or after a resync. A sync worker that dies without reaching `f` (L12) belongs to the sync-worker properties. |
| **Why It Matters** | Scripts calling these without their own timeout would hang with no error on a failed table, and a false "done" would hide missing rows. The docs say both functions wait indefinitely and the caller must make sure the subscription keeps processing, so a disabled subscription is outside the contract. |

**Open Questions:**

- Should the wait functions report a disabled subscription instead of waiting? `(needs human input)` `(partial: docs say they wait indefinitely and the caller must ensure the subscription is processing; assertion dropped from the property)`

Priority: P2 · Topology: v1 (needs admin-churn phase) · Faults: partition / node kill during COPY
Confidence: medium · Surfaced by: F4 Protocol
Evidence: properties/sync-wait-functions-honor-contract.md
Evaluation note (2026-10-13): resyncs target a dedicated single-writer table (Assumption 5), so a `truncate := true` resync loses nothing and CATCHUP still has work.

---

## Category C — Apply error classifier and exception replay

The apply worker's `PG_CATCH` decides "retry the same transaction" vs "this
data is bad, run the exception policy". A wrong choice silently drops a
transaction (TRANSDISCARD) or disables a subscription (SUB_DISABLE). This is
the densest bug-history area (sut-analysis §13 rank 1).

### apply-cancel-retried-not-discarded — A query cancel on an apply worker is retried, not discarded

| | |
|---|---|
| **Type** | Safety |
| **Property** | A `pg_cancel_backend` (SQLSTATE 57014) on an apply worker leads to a retry of the same remote transaction; it never produces `exception_log` rows or a disabled subscription in a conflict-free workload. |
| **Invariant** | Workload `Always` after quiesce: no exception_log row mentions 57014 / "canceling statement due to user request", all subscriptions enabled, all ledger rows present. SUT-side `Unreachable("apply worker entered exception replay for a query-cancel error")` before `AbortOutOfAnyTransaction()` at `src/spock_apply.c:4065`, with separate messages for class 58 and 40001; `Reachable` markers on each retry branch. |
| **Antithesis Angle** | A test command cancels apply backends at random times; CPU modulation keeps apply inside a remote transaction when the cancel lands. 57014 is not on the retry allow-list (08xxx subset, 57P01-03, 40P01, 55P03, class 53), so it goes to in-process replay and TRANSDISCARD drops the whole transaction on that node only. Other codes reachable from outside: 40001 from `terminate_active_transactions` (own property) and FATAL 25P04 from `transaction_timeout`, which bypasses PG_CATCH and is caught by `exception-replay-only-after-recorded-error`. |
| **Why It Matters** | Lead L5. Monitoring tools that cancel long-running backends by pid would cause logged, permanent divergence. Same shape as eleven earlier classifier fixes. |

**Open Questions:**

- Is 57014 (query cancel of an apply worker) meant to be a data fault or a transient retry? `(needs human input)`

Priority: P0 · Topology: v1 · Faults: worker exit (cancel test command), CPU modulation
Confidence: high (allow-list code-checked; stock bgworker SIGINT handler not overridden) · Surfaced by: F3 Failure Recovery
Evidence: properties/apply-cancel-retried-not-discarded.md
Placement: Expected to fire deterministically — confirm with TAP first, then gate out of the main template.
Evaluation note (2026-10-13): any cancel that lands inside a remote transaction triggers it; Antithesis adds only where in the transaction. Confirm with a TAP script (`pg_cancel_backend` on an apply pid mid-transaction), then run the cancel test command in a separate classifier template until a fix is in the image; afterwards it is a good regression guard. Pids come from `pg_stat_activity.backend_type` (`spock apply <dboid>:<subid>`). Workload-side `Sometimes("cancel sent while the apply worker had backend_xid set")`. "No exception_log row" checks ignore rows in the expected-exception registry.

### terminate-active-transactions-never-discards-inbound — The readonly helper does not drop replicated data

| | |
|---|---|
| **Type** | Safety |
| **Property** | Calling `spock.terminate_active_transactions()` on a node never makes that node discard, skip or disable an inbound replicated transaction. |
| **Invariant** | Workload `Always` after quiescence following any call: no `exception_log` row outside the expected-exception registry on that node (the checked tables are conflict-free, and the FATAL path leaves rows without the "conflict with recovery" text), all ledger rows present everywhere, no disabled subscription. SUT-side `Sometimes(in_remote_transaction, "apply worker received recovery-conflict cancel mid-transaction")` in apply `PG_CATCH` to show the interleaving was reached. |
| **Antithesis Angle** | The function cancels every backend with a valid vxid, including an apply worker mid-transaction, or inside a per-row subtransaction (DISCARD mode, or delta apply in any mode), which turns it into FATAL 40001. A walsender hit by the call only cuts the stream (the subscriber retries). Large transactions, provider pauses and CPU throttling widen the window. |
| **Why It Matters** | The cancel raises ERROR 40001, which is not on the transient list (admitted at `src/spock_apply.c:3951-3957`), so a routine read-only toolkit action discards an inbound transaction under TRANSDISCARD or disables the subscription under SUB_DISABLE. |

**Open Questions:**

- Is `terminate_active_transactions()` meant to skip Spock's own workers? If yes this is a bug; if no, the docs need a warning. `(needs human input)`

Priority: P1 · Topology: v1 · Faults: test command calling the function during apply; CPU modulation
Confidence: high (mechanism checked in Spock and PG18 source) · Surfaced by: F6 Security
Evidence: properties/terminate-active-transactions-never-discards-inbound.md
Placement: Expected to fire deterministically — confirm with TAP first, then gate out of the main template.
Evaluation note (2026-10-13): the function also cancels the workload's own client sessions on that node; client 57014 errors after a call are unknown-outcome commits, resolved through the marker row like lost connections. Runs in the classifier template with the cancel commands.

### lock-contention-retried-not-discarded — Apply/local lock contention is retried, never discarded

| | |
|---|---|
| **Type** | Safety |
| **Property** | Deadlocks and lock timeouts between apply workers and local sessions make the apply worker retry the transaction; they never produce exception_log rows or dropped transactions. |
| **Invariant** | Workload `Always`: no `spock.exception_log` row matches `deadlock detected`, `canceling statement due to lock timeout` or `could not obtain lock`, checked after each barrier; companion convergence `Always` on the contention table. SUT-side `Sometimes("apply worker lost deadlock to local session and will retry")` and `Sometimes("apply worker hit lock_timeout and will retry")` so the `Always` is not vacuous. |
| **Antithesis Angle** | Local transactions lock hot rows in the opposite order to remote writers; optional `lock_timeout` phase (`ALTER DATABASE ... SET lock_timeout` reaches the apply worker, which reads settings at start, so restart the workers after the ALTER; an `ALTER ROLE` must target the bootstrap superuser the worker runs as). Thread pausing lines up lock orders so the deadlock detector picks the apply worker. The `goto retry` in `SpockRelationFindReplTupleByIndex` blocks on the competing writer (lag, not a spin). Runs with TRANSDISCARD or SUB_DISABLE (DISCARD swallows per-row errors by design). |
| **Why It Matters** | Regression guard for f3d4935e. Contention between local and replicated writes is normal in active-active use. |

**Open Questions:**

None

Priority: P1 · Topology: v1 · Faults: thread pause, workload lock contention
Confidence: high (that the code retries today; regression guard) · Surfaced by: F2 Concurrency
Evidence: properties/lock-contention-retried-not-discarded.md

### insert-race-resolved-not-discarded — Insert/insert race is resolved by LUW, not discarded

| | |
|---|---|
| **Type** | Safety |
| **Property** | When an apply worker's INSERT races with a same-key INSERT from another upstream's apply worker or a local session, Spock resolves it as an `insert_exists` conflict instead of dropping the upstream transaction. |
| **Invariant** | Workload `Always`: after each barrier, no `spock.exception_log` row has `duplicate key value violates unique constraint` for a table whose only unique index is the PK. Companion `Always`: per-key payload identical on all nodes. SUT-side `Unreachable("apply insert lost unique-key race to concurrent writer")` in `apply_work` `PG_CATCH` for 23505 on an INSERT into such a relation; `Sometimes("apply insert found row inserted by concurrent upstream")`. |
| **Antithesis Angle** | The window is between `FindReplTupleInLocalRel` returning "not found" and the unique check inside `ExecSimpleRelationInsert` (`src/spock_apply_heap.c:873-925`). Thread pausing stretches it; latency aligns two upstream streams at the third node. 23505 is not on the transient list. |
| **Why It Matters** | Under TRANSDISCARD the whole upstream transaction, including unrelated rows, is silently dropped on one node; under SUB_DISABLE the subscription stops. Source TODO at `:873` admits the gap. |

**Open Questions:**

- Is the TRANSDISCARD-on-race outcome an accepted limit, or should the INSERT path retry as `insert_exists`? `(needs human input)`
- How wide is the lookup-to-insert window in practice? `(partial: spans heap insert, BEFORE ROW triggers and constraint checks up to the unique check; apply workers of different upstreams run in parallel; not yet seen in a run)`

Priority: P1 · Topology: v1 · Faults: latency, thread pause
Confidence: medium (mechanism high; reachability under real timing not shown) · Surfaced by: F2 Concurrency (F7 reached the same lead L6a and deferred to this entry)
Evidence: properties/insert-race-resolved-not-discarded.md
Evaluation note (2026-10-13): the window ends at the unique check inside core `ExecSimpleRelationInsert`, which thread pausing does not reach while core is uninstrumented; latency and CPU modulation are the drivers. Optional SUT-side `Sometimes("update_missing retry found the row on a later attempt")` (L6c: the retry wait returns at once) shows whether the retries ever help; if never, that is a documentation finding.

### exception-replay-only-after-recorded-error — A restarted worker enters exception replay only for a transaction that really failed

| | |
|---|---|
| **Type** | Safety |
| **Property** | When `handle_begin()` matches the shared-memory exception marker's `commit_lsn` and switches to exception replay, the marker always carries the initial error recorded by a real failure. |
| **Invariant** | SUT-side `Unreachable("exception replay entered without a recorded initial error")` in `handle_begin()` case 4 when `initial_error_message[0] == '\0'`. Companion `Unreachable("apply worker readonly FATAL in replication_handler")` at `src/spock_apply.c:2982`, which code reading says cannot be reached with default slot names. |
| **Antithesis Angle** | Graceful worker exits, cancels, network drops and readonly toggles at random points; `transaction_timeout` (FATAL 25P04, PG17+) and `terminate_active_transactions` calls during apply (FATAL 40001 inside a subtransaction) are the known stale-marker sources; table resync reaches the apply/sync shared-marker case (L15). Postmaster kills wipe shared memory and do not reach it. |
| **Why It Matters** | Each missed exit path in the eleven past classifier/marker fixes turned a restart into a silently discarded or disabled transaction. This catches the whole class at its source. |

**Open Questions:**

- Does a table-sync worker's last stamped `commit_lsn` ever equal the apply worker's first BEGIN after a restart? `(partial: normally the sync worker stops on the transaction the apply worker last committed; only when the sync stream starts past replay_stop_lsn does it stamp an unseen transaction; needs sub_resync_table in a run)`

Priority: P1 · Topology: v1 · Faults: worker exit, partition, readonly toggles
Confidence: medium · Surfaced by: F8 Lifecycle
Evidence: properties/exception-replay-only-after-recorded-error.md
Evaluation note (2026-10-13): set-up step for the `transaction_timeout` source: `ALTER DATABASE ... SET transaction_timeout` (PG17+ arms it in `StartTransaction`, which the apply worker uses), then restart the apply workers so they pick it up at connect.

### exception-replay-never-reruns-committed-transaction — In-process replay never replays a transaction the worker already committed

| | |
|---|---|
| **Type** | Safety |
| **Property** | The in-process exception replay only replays a remote transaction that this worker has not committed. |
| **Invariant** | SUT-side `Unreachable("exception replay entered for a transaction this worker already committed")`: record the BEGIN `commit_lsn` right after `CommitTransactionCommand()` in `handle_commit`; in `handle_begin` case 4 fire if the incoming `commit_lsn` equals it. |
| **Antithesis Angle** | `handle_commit` commits at `src/spock_apply.c:1058` but resets the replay queue only at `:1248`. In between, `maybe_pause_for_slot_creation()` (`:1186`) sleeps up to `spock.pause_timeout` during add_node and checks interrupts, so a cancel raises 57014 there; `maybe_advance_forwarded_origin()` can raise 55006. Either takes the first-exception branch with the committed transaction still queued. Needs a cancel test command, ideally while add_node runs. |
| **Why It Matters** | Under `discard` every row is applied twice; under `transdiscard` the exception log claims rows were discarded that were applied, which corrupts the "every difference is explained" oracle; under `sub_disable` a good subscription is disabled. |

**Open Questions:**

- Is a query cancel delivered to an apply worker a supported operator action? (The ordering bug stands either way.) `(needs human input)`

Priority: P1 · Topology: v1 · Faults: worker exit (cancel) during add_node
Confidence: medium · Surfaced by: F9 Idempotency
Evidence: properties/exception-replay-never-reruns-committed-transaction.md
Evaluation note (2026-10-13): the paused state is not visible (the pause sleep uses the same wait event as an idle apply worker), so the trigger is a combined test command: while add_node runs, watch the source's `pg_stat_activity` for a walsender whose `query` shows `CREATE_REPLICATION_SLOT`, then cancel all apply workers on the source. Expect a low hit rate; the SUT-side `Unreachable` is the main check.

### interrupted-exception-replay-still-records-txn — A failing transaction whose replay is interrupted is still handled by policy

| | |
|---|---|
| **Type** | Safety |
| **Property** | If in-process exception replay of a failing remote transaction T is interrupted (worker SIGTERM, disconnect, idle timeout, crash), T is delivered again and ends in exactly one documented outcome: TRANSDISCARD leaves exception_log rows for T's remote xid and none of T's rows; SUB_DISABLE leaves the subscription disabled, and T applies once after fix and `sub_enable`. |
| **Invariant** | Workload `Always("poison transaction is either applied-nowhere-and-logged or subscription disabled on every target node")` after quiesce for every poison T (a local-only trigger or CHECK that fails on one subscriber). SUT-side `AlwaysOrUnreachable` in the keepalive branch: while replaying, the flush sent is not past the marker's `commit_lsn`. `Sometimes("apply worker exited during in-process exception replay")` and `Sometimes("exception replay read entries from the spill file")`. |
| **Antithesis Angle** | `AbortOutOfAnyTransaction()` in the first-exception branch (`src/spock_apply.c:4065`) advances the session origin to T's `commit_lsn` before replay (PG17 and PG18 `RecordTransactionAbort`). T is still resent: the decoding skip test is strict `<` on PG18, a keepalive endpos cannot pass T's commit while T is unrecorded, and `sub_disable` resume at `commit_lsn` is the documented design. Large poison transactions (spill path) with terminates, partitions, idle timeout and kill -9 (control) during replay. |
| **Why It Matters** | Lead L7. Spock's own comment (`src/spock_apply.c:2305-2325`) says such an abort-time advance "silently skips that txn on reconnect" and fixes it only for the worker-exit path. Off by one anywhere means silent loss with no exception row. |

**Open Questions:**

- Is a second set of exception_log rows for the same T (crash after replay commit, L1) acceptable? `(needs human input)`

Priority: P1 · Topology: v1 · Faults: worker exit during replay, partition, node kill
Confidence: high that it holds today (regression guard, code-checked on PG17 and PG18; no known bug) on a path with dense bug history · Surfaced by: F3 Failure Recovery, F9 Idempotency
Evidence: properties/interrupted-exception-replay-still-records-txn.md
Gap-fill note (2026-10-13): the SUB_DISABLE outcome without interrupts, its bound, lead L27 and the `sub_disable` run variant are owned by `sub-disable-error-ends-disabled-and-recorded`.
Evaluation note (2026-10-13): poison transactions go to dedicated poison tables and are recorded in the expected-exception registry (origin, remote xid, table), so the "no exception rows" checks of other properties ignore them.

### proto5-replay-reparses-startup-message — Exception replay re-reads the startup message with protocol-5 framing

| | |
|---|---|
| **Type** | Safety |
| **Property** | When the apply worker replays its queue after a data error, every queued message is parsed with the protocol framing it was received with; the startup message ('S', never prefixed) is not re-read as a protocol-5 message. |
| **Invariant** | SUT-side: store the parse version on each replay-queue entry; at replay `Always(entry version == current parse version, "replayed message parsed with the protocol version it was received with")`. `Unreachable("apply received unknown protocol action")` in the `replication_handler` default case. `Sometimes("replay starts with 'S' at queue head")` as an exploration hint. Workload consequence check: `progress-insert-lsn-never-ahead-of-provider`. |
| **Antithesis Angle** | Needs a fresh connection (partition, worker or node restart, idle timeout) whose first committed remote transaction hits a data error not already recorded. The 'S' entry stays at the queue head until the first COMMIT. Code reading: replay reads `'S' 0x01 "max_pr"` as LSN `53016D61/785F7072`, stores it in `spock.progress`, then fails with `unknown action of type o`. |
| **Why It Matters** | Corrupts `spock.progress.remote_insert_lsn` permanently (max-kept, dumped to `resource.dat`, copied to new nodes by add_node), costs one extra worker restart, and under SUB_DISABLE records a disable whose stated cause is wrong. Code reading rules out a silent drop: the abort leaves the origin at `commit_lsn`, the strict skip test resends T, and the next worker handles T from the shared-memory marker. Introduced with the v5 header (72b7980a). |

**Open Questions:**

None

Priority: P2 · Topology: v1 · Faults: reconnect (partition / worker restart) plus a workload data error
Priority note: lowered from P1: impact narrowed to progress corruption, an extra restart and a wrong-cause disable row; no silent drop.
Confidence: high (mechanism read end to end, not run; a TAP repro is the cheap check); medium (downstream impact) · Surfaced by: F10 Versions
Evidence: properties/proto5-replay-reparses-startup-message.md
Placement: Expected to fire deterministically — confirm with TAP first, then gate out of the main template.

### redelivered-ddl-not-turned-into-exception — Re-sent DDL does not produce exception rows or disable a subscription

| | |
|---|---|
| **Type** | Safety |
| **Property** | A replicated DDL transaction that reaches a subscriber a second time does not create an `exception_log` row, disable the subscription, or drop data. |
| **Invariant** | Workload `Always`: after quiescence, no `spock.exception_log` row has `ddl_statement` set with an `error_message` containing "already exists" or "does not exist" (the 42P07, 42701, 42710, 42P01, 42704 texts; `exception_log` stores no SQLSTATE, so the harness pins `lc_messages = 'C'`), and no subscription is disabled unless the workload disabled it. DDL runs only in quiesced phases, so such an error can only come from redelivery. SUT-side `Unreachable("replicated DDL failed because its object already exists")` in the queued-SQL exception path. |
| **Antithesis Angle** | Kill a subscriber postmaster shortly after a DDL phase's barrier, before the next checkpoint (the barrier reads the in-memory origin, which is what rewinds; L1 is confirmed by code reading, so this is reachable, not only a guard). Workload DDL must be non-idempotent (no `IF NOT EXISTS` / `OR REPLACE`) or redelivery is invisible. Run `transdiscard` and `sub_disable` variants (both skip the DDL and log `operation='SQL'` with `ddl_statement`). |
| **Why It Matters** | Queued SQL is re-run with no record of what already ran (`spock.queue` has no primary key). Any redelivery (L1, L19, add_node overlap) becomes a 42-class error. Under `sub_disable` a healthy subscription is disabled; under `transdiscard` the log reports a failure that did not happen. |

**Open Questions:**

- Is redelivery of a DDL transaction expected by the team, and should DDL apply be made idempotent or redelivery prevented? `(needs human input)`
- Should 42P07-class errors on queued DDL be treated as "already applied" rather than as data faults? `(needs human input)`

Priority: P1 · Topology: v1 · Faults: node kill after a DDL phase
Confidence: medium-high (L1 code-confirmed; frequency depends on kill timing) · Surfaced by: F9 Idempotency
Evidence: properties/redelivered-ddl-not-turned-into-exception.md
Gap-fill note (2026-10-13): each DDL phase adds same-origin pairs "ADD COLUMN, then DML that writes the new column" on a ledger-checked table, so a lost or doubly applied DDL also shows up as missing DML rows on the peer (`committed-ledger-row-reaches-every-node`), not only as a 42-class exception row. Same-origin DDL-then-DML order is guaranteed; lock-timeout and deadlock errors on queued DDL are retried (`src/spock_apply.c:3966-3972`).
Evaluation note (2026-10-13): split into "re-sent DDL failed on a node that crashed since the DDL and shows a node-id origin state" (explained by L1) and "re-sent DDL failed, unexplained". The kill after a DDL barrier and before a checkpoint comes from the crash helper.

### readonly-local-keeps-inbound-ddl-flowing — readonly=local does not block replicated DDL

| | |
|---|---|
| **Type** | Safety |
| **Property** | While a subscriber is in `spock.readonly=local`, every inbound replicated transaction commits on it, including queued DDL that a non-superuser role issued on the origin. |
| **Invariant** | Workload `Always`, after the quiet period following any phase where a node was in `local` mode: that node's `spock.exception_log` has no row whose `error_message` contains "read-only transaction" (25006, matched as text with `lc_messages = 'C'`), test-table columns match on all nodes, and ledger rows match. |
| **Antithesis Angle** | Varies when the readonly reload lands relative to DDL arrival (the apply worker re-reads the GUC only at message boundaries or in `wait_for_previous_transaction`), plus worker restarts. Mostly an ordering-independent bug: it fires whenever the DDL role is not a superuser. A TAP test would also catch it. |
| **Why It Matters** | The readonly hooks test `superuser()` on the current user; the apply worker switches to the queued role before parse analysis (`src/spock_apply.c:4342-4361`), so the DDL fails with 25006, which is not transient. Under TRANSDISCARD the DDL is discarded for good and later DML fails on the schema difference. Docs promise inbound replication "continues normally". |

**Open Questions:**

None

Priority: P1 · Topology: v1 (workload must issue DDL as a non-superuser role) · Faults: none required; readonly toggles, worker restarts
Confidence: high (mechanism); medium (maintainers will call it a bug) · Surfaced by: F6 Security
Evidence: properties/readonly-local-keeps-inbound-ddl-flowing.md
Placement: Expected to fire deterministically — confirm with TAP first, then gate out of the main template.
Evaluation note (2026-10-13): until a fix is in the image, readonly=local phases in the main template use superuser DDL or no DDL; this property runs in its own template. After a fix it stays as a P3 regression guard (the reload-vs-DDL-arrival timing is the only Antithesis part).

### worker-respawn-rate-bounded — Spock worker respawns stay paced

| | |
|---|---|
| **Type** | Safety |
| **Property** | Outside postmaster restarts, no apply worker (per subscription) or manager (per database) is restarted in a hot loop. |
| **Invariant** | Workload log tailer `Always(n <= 3, "apply worker error exits per subscription per 5 s window")` and `Always(n <= 3, "manager error exits per database per 5 s window")` on `... exiting with error` lines (`src/spock_worker.c:431-435`), skipping windows with a postmaster start or injected kill. SUT-side `Unreachable("apply worker for one subscription registered 20 times within 10 s")` in `manage_apply_workers` and `Unreachable("supervisor re-registered a manager 20 times within 10 s")`. `Sometimes("apply worker exiting with zero restart delay")` to show which faults reach the unpaced path. |
| **Antithesis Angle** | `restart_delay_on_exception` defaults to 0 and is set on every BEGIN (`src/spock_apply.c:676`), but every exit branch of `apply_work`'s PG_CATCH now sets `restart_delay_default` or disables the subscription, so no known infrastructure fault reaches the ~1 ms path (rare sources left: the "incorrect spock message" FATAL and an ERROR inside PG_CATCH itself). A failed `RegisterDynamicBackgroundWorker` is paced at `restart_delay_default` (5 s) through the claimed slot's `terminated_at`; only a full Spock slot table loops with no delay. Cancels (57014) go to replay, SIGTERM is a clean exit, and readonly=all keeps the worker alive. Worker exits and small `max_worker_processes`; a plain partition is the paced control. |
| **Why It Matters** | Regression guard for `f3d4935e`, which measured 83 restarts/s before pacing. A respawn loop forks a worker and a provider walsender every few ms, floods logs and burns CPU. Lead L23. |

**Open Questions:**

None

Priority: P3 · Topology: v1 (capacity part: `v2/small-capacity`) · Faults: worker exit, small capacity
Priority note: lowered from P2: regression guard; code reading found no infrastructure fault that reaches the unpaced path.
Confidence: medium · Surfaced by: F5 Resources, F8 Lifecycle
Evidence: properties/worker-respawn-rate-bounded.md
Evaluation note (2026-10-13): the log tailer reads server logs through `logging_collector` and `pg_read_file`; the small-capacity part runs in the separate `v2/small-capacity` configuration.
Resolution: F5 proposed a workload log `Always` (≤3 exits per 5 s), F8 a SUT-side `Unreachable` (20 registrations in 10 s). Both kept with distinct messages: the log check needs no SUT change; the SUT check counts registrations and does not depend on log text.

### sub-disable-error-ends-disabled-and-recorded — Under sub_disable a failing transaction ends with the subscription disabled and recorded

| | |
|---|---|
| **Type** | Liveness |
| **Property** | With `spock.exception_behaviour = sub_disable`, a remote transaction T that fails on a subscriber ends, within a bound after faults stop, with that subscription disabled, a `SUB_DISABLE` row in `spock.exception_log` and the origin not past T; after the cause is fixed and `sub_enable`, T is applied once. The subscription never sits in a restart loop with nothing recorded. |
| **Invariant** | Workload `Always("sub_disable: failing transaction ends with its subscription disabled and a SUB_DISABLE row within bound after faults stop")` (bound as for barriers) and `Always("sub_disable: after fix and sub_enable the failing transaction is applied exactly once")`. SUT-side `Unreachable("SUB_DISABLE disable written inside a remote transaction that is then rolled back")` at the inner-loop call (`src/spock_apply.c:3811`) and in the `PG_CATCH` SUB_DISABLE branch when a transaction is still open. `Sometimes("sub_disable: failing transaction spanned more than one network read")` (SUT-side) and workload `Sometimes("sub_disable: worker exit landed during replay")`. |
| **Antithesis Angle** | Lead L27, confirmed by code reading: during read-only replay a change whose relation is missing on the subscriber sets `xact_had_exception` mid-transaction; the inner-loop check after each read batch calls `spock_disable_subscription` while T is still open, `apply_work` returns, `proc_exit(0)` aborts, and the disable, the `SUB_DISABLE` row and every replay row are rolled back. The clean exit restarts the worker at once and the shared-memory marker sends it into the same replay: a loop with nothing recorded. Whether T's COMMIT is in the same read batch depends on transaction size and how the link splits reads (latency, CPU throttling). Other errors during replay (cancel, terminate) take the same rolled-back route once and then recover; a node kill between the exception-row commit and the disable commit writes the rows twice. |
| **Why It Matters** | S7 says a failing transaction disables the subscription and resumes from it after the fix; no property or run variant covered it. The L27 loop stops replication from one provider with no record, no disable and a status that alternates between `replicating` and `down`. |

**Open Questions:**

- Should the inner-loop route commit the disable (or exit with FATAL so the next start disables), or should the inner-loop check wait for COMMIT? Affects the fix only. `(needs human input)`
- Is the `sub_disable` run variant in scope for the first runs? `(needs human input)`

Priority: P2 · Topology: v1 `sub_disable` run variant (`spock.exception_behaviour = sub_disable` on every node) · Faults: latency and CPU throttling on the provider link, worker cancel / terminate during replay, node kill between the two commits
Confidence: high for the L27 mechanism (code-checked, not run); TAP 016 covers only the single-read case and passes · Surfaced by: Evaluation extra gap E2 (coverage-balance F2, risk map)
Evidence: properties/sub-disable-error-ends-disabled-and-recorded.md
Placement: the multi-read case can be reproduced in TAP with a large transaction and a table dropped on the subscriber — confirm with TAP first; Antithesis keeps the interrupt and kill timings.

---

## Category D — Conflict resolution, clocks and convergence

Last-update-wins on commit timestamps, the per-node tiebreaker, and core patch
025's logical commit clock. Contested tables stay inside the sut-analysis §12
boundaries (seeded once, UPDATE only, PK only, no deletes, no delta columns).

### contested-rows-converge-after-quiesce — Concurrently updated rows converge

| | |
|---|---|
| **Type** | Safety |
| **Property** | For pre-seeded rows updated concurrently from all mesh nodes (no deletes, no inserts of contested keys), all nodes hold identical row contents after quiescence and barriers. |
| **Invariant** | Workload `Always(ordered row dumps of the contested table are equal on all mesh nodes)`. Details: each node's `(writer, wseq)`, `pg_xact_commit_timestamp_origin(xmin)`, and whether competing versions had equal commit ts. SUT-side `Sometimes(cmp == 0 && local_origin != remote_origin, "equal commit ts conflict between different origins")` in `conflict_resolve_by_timestamp` and `Unreachable` at the equal-tiebreaker WARNING. |
| **Antithesis Angle** | Partitions and latency reorder arrival. Antithesis clock skips are global (all containers jump together); a backward skip is enough to produce equal commit ts across nodes, where the tiebreak compares the applying node rather than the two writers (L2, `src/spock_conflict.c:131-200`), which can diverge with 3+ writers; a backward skip plus a restart breaks the commit clock (L3); graceful exits drop transactions (L5). Clock runs on the cassert image need the SPOC-688 Assert fix (see `apply-survives-provider-clock-ahead`). |
| **Why It Matters** | Spock claims LUW gives one deterministic winner (`docs/conflicts.md:60-64`). Divergence is silent: update/update conflicts are not recorded in `spock.resolutions`. |

**Open Questions:**

- Is the applying-node tiebreak (64ea462d), which lets 3 nodes diverge on equal commit ts, intended? `(needs human input)`
- Is divergence from the restart-unsafe commit clock (L3) an accepted limit? `(needs human input)`

Priority: P0 · Topology: v1 · Faults: clock skew, partition, latency, node kill
Confidence: high · Surfaced by: F1 Data Integrity
Evidence: properties/contested-rows-converge-after-quiesce.md
Evaluation note (2026-10-13): the divergence message is split into "divergent key last written by a node within N s after its restart that followed a backward clock skip" (explained by L3), "divergent key whose top versions tie on commit ts" (L2, reported) and "divergent key, unexplained". Only the unexplained message counts as a new finding while L2/L3 are open.
Partly implemented (2026-10-28) in its own template, `test/v1/updates/`, so its conflicts stay apart from the conflict-free ledger in `main`: table `kv(origin, n, val, writer, wseq)`, key `(origin, n)` owned by the inserting node. `parallel_driver_update_kv.py` mixes inserts with updates of keys it has confirmed are on every mesh node (team decision 2026-10-28: an update that reaches a node before the row is `update_missing`, documented as unresolvable, so the check stays strict); per timeline it swarms writer nodes, update share {0.2, 0.6, 0.95}, contested share {0, 0.5, 1} (keys from any origin vs its own) and a hot set of {1, 10, 1000} keys per origin. `eventually_kv_converges.py` runs the shared sync barriers (`main/helper_barriers.py`, symlinked) and asserts `Always("every mesh node holds the same kv rows after sync barriers")` (md5 per row, sorted) and `Always("no kv transaction is discarded on any mesh node")`. Reach claims: `Reachable("kv update committed on keys present on every mesh node")`, `Sometimes("kv update committed on a row another node inserted")`, `Sometimes("a kv row was last updated by a node other than its origin")`. Not yet: the L2/L3 explained/unexplained split, the SUT-side equal-commit-ts `Sometimes` and `Unreachable`, per-version commit ts in the details, TOAST and delta columns (separate later work), deletes (known divergence).

### luw-final-version-has-max-commit-ts — Contested rows end at the max-commit-ts version on every node

| | |
|---|---|
| **Type** | Safety |
| **Property** | For contested rows, every node's final version is the write with the largest recorded origin commit timestamp, whenever that maximum is unique. |
| **Invariant** | Workload `Always(final payload on node == payload of max-ts write, "contested row holds max commit-ts version on every node")`, per (node, key) after barriers. Each write's ts comes from `pg_xact_commit_timestamp(xid)` on its origin after commit (the adjusted value peers compare). Keys whose top two timestamps are equal are reported, not asserted. SUT-side `Sometimes("LUW kept a newer local row over an older remote row")` and `Sometimes("LUW applied a newer remote row")`. |
| **Antithesis Angle** | A backward clock skip (global is enough) plus a restart reaches L3: a node that applied a later remote version restarts with its logical clock at 0 and overwrites the row with a smaller ts; it keeps its own write while peers keep the remote one. Partitions vary arrival order. The oracle is sound: patch 025 rewrites the commit time before `TransactionTreeSetCommitTsData`, so the origin's `pg_commit_ts` value is the one sent to peers. |
| **Why It Matters** | Convergence alone accepts all nodes agreeing on the wrong version and does not name the node holding it. Wrong winners are silent. |

**Open Questions:**

- Is the restart-unsafe commit clock (patch 025 TODO, unchanged through PG19, no fix on any branch) an accepted limit? `(needs human input)`
- Which tie rule is intended: lower tiebreaker of the two writers (docs, pre-64ea462d code) or applying node vs sender (current code)? `(needs human input)`
- What clock-skip sizes does Antithesis use? The L3 route needs a backward skip larger than a restart plus crash recovery plus one write. `(partial: Antithesis docs show only a 65 ms example; ask the Antithesis contact; fallback is a libfaketime per-node offset custom fault)`

Priority: P1 · Topology: v1 · Faults: clock skew + node kill, partition
Confidence: medium · Surfaced by: F1 Data Integrity, F7 Distributed
Evidence: properties/luw-final-version-has-max-commit-ts.md
Gap-fill note (2026-10-13): if the workload uses two-phase writers, take their commit ts from a peer (or from the origin after a restart), not from the origin's live `pg_xact_commit_timestamp`, which is the unbumped value for prepared transactions (see `prepared-commit-ts-matches-sent-ts`).
Evaluation note (2026-10-13): split as in `contested-rows-converge-after-quiesce` (explained by L3 vs unexplained). The L3 route needs a backward skip larger than restart plus recovery plus one write; if Antithesis skips are small, a per-node offset custom fault (libfaketime) is needed. The restart is scripted with the crash helper.
Resolution: F1 also scored ties by the docs' rule; F7 skipped them. Ties are left unscored here until the tie rule's intent is settled; `contested-rows-converge-after-quiesce` and `luw-tiebreak-against-third-origin-row-reached` cover them.

### local-overwrite-gets-later-commit-ts — A local overwrite commits after the version it replaced, and wins everywhere

| | |
|---|---|
| **Type** | Safety |
| **Property** | When a client on node X reads a row version (`FOR UPDATE`) and overwrites it, the overwrite's commit timestamp is strictly greater than the replaced version's, including right after X restarts; and with no later writes elsewhere every node ends holding X's write. |
| **Invariant** | Workload `Always(new_ts > seen_ts, "local overwrite commit ts exceeds the version it replaced")` per overwrite (`seen_ts = pg_xact_commit_timestamp(xmin)` read in the same transaction, NULL skipped). Workload `Always("causal overwrite holds on every node after quiesce")` for a reserved key range driven as causal chains (P writes, X observes P's version, X writes). `Sometimes("causal overwrite after restart with lagging clock")` to show the dangerous state was reached. |
| **Antithesis Angle** | A backward clock skip (global is fine) and a restart of X: the logical clock in `XLogCtl` resets to 0 at restart (patch says "This is not postmaster restart safe"; no restore exists or is in progress on any branch), then X updates a row it had taken from a peer within the first seconds after restart. Skew between nodes is not needed. |
| **Why It Matters** | Lead L3. X keeps its update while every peer keeps the remote version: permanent divergence with no exception or resolution row. Read-modify-write is the most common application pattern. The per-write form fails on the node where it happens, so triage points at the clock. |

**Open Questions:**

- Is the restart gap in the commit clock an accepted limit, and is a maximum clock skew documented? `(needs human input)`
- What clock-skip sizes does Antithesis use? A skip of tens of milliseconds cannot reach L3; it needs one larger than a restart plus crash recovery plus one write. `(partial: Antithesis docs show only a 65 ms example; ask the Antithesis contact; fallback is a libfaketime per-node offset custom fault)`

Priority: P1 · Topology: v1 · Faults: clock skew + node kill
Confidence: high on mechanism (patch TODO) and on reachability (global backward skip plus restart) · Surfaced by: F1 Data Integrity, F3 Failure Recovery, F7 Distributed
Evidence: properties/local-overwrite-gets-later-commit-ts.md
Gap-fill note (2026-10-13): if the workload uses two-phase writers, take their commit ts from a peer (or from the origin after a restart), not from the origin's live `pg_xact_commit_timestamp`, which is the unbumped value for prepared transactions (see `prepared-commit-ts-matches-sent-ts`).
Evaluation note (2026-10-13): the per-overwrite message is split into "... within N s after X restarted following a backward clock skip" (explained by L3) and "... otherwise" (unexplained). "Restart X, then overwrite a row X took from a peer" is scripted with the crash helper. Core patch 025 markers (local-bump branch, first call after startup) are an option in a test-only PG patch.

### luw-tiebreak-against-third-origin-row-reached — Equal-ts tiebreak runs against a row from a third node

| | |
|---|---|
| **Type** | Reachability |
| **Property** | At least once per run, the equal-timestamp branch of `conflict_resolve_by_timestamp` runs on a node whose local row came from a third node (neither the applying node nor the sender), the only state where L2 can make nodes disagree. |
| **Invariant** | SUT-side `Sometimes(local_origin != Invalid && local_origin != remote_origin && local_origin != applying node id, "LUW equal-ts tiebreak with local row from a third node")` after the same-origin shortcut (`src/spock_conflict.c:153-158`). A rare, meaningful state Antithesis should be steered to; not an invariant. |
| **Antithesis Angle** | A global backward clock skip makes cross-node ties likely: lagging nodes that applied a commit at T stamp their next local commit T+1 µs (patch 025), so two of them can tie; latency varies which tied version reaches the third node first. No test-only knob needed. Clock runs on the cassert image need the SPOC-688 Assert fix. |
| **Why It Matters** | Without it, a green contested-row result may only mean no tie with a third-origin row ever occurred. With tiebreakers A=2, B=1, C=3 and A, C tied, B keeps C's version if C arrives first while A and C hold A's (code-checked). |

**Open Questions:**

- Which pair is the tiebreaker meant to compare: the two writers (pre-64ea462d rule, docs wording) or the applying node vs the sender (current code)? `(needs human input)`

Priority: P1 · Topology: v1 · Faults: clock skew, latency
Confidence: high · Surfaced by: F7 Distributed
Evidence: properties/luw-tiebreak-against-third-origin-row-reached.md

### clock-step-forward-makes-commit-ts-ties — One forward clock step drags peers' commit timestamps ahead

| | |
|---|---|
| **Type** | Reachability |
| **Property** | A clock step (a global backward skip, or a forward step on one node) leads nodes to stamp local commits ahead of their own wall clocks, and two nodes to stamp local commits with identical timestamps. |
| **Invariant** | Workload `Sometimes("local commit stamped ahead of local wall clock by the logical clock")`: right after a local commit, `pg_xact_commit_timestamp(xid) > clock_timestamp()`. `Sometimes("two nodes committed local writes with identical commit timestamps")` from ledger commit timestamps after quiescence. No SUT change. |
| **Antithesis Angle** | Patch 025 raises the instance clock to any applied remote commit time and stamps later local commits `clock + 1 µs`. After a backward skip on every node (Antithesis steps all clocks at once), or after one node jumps ahead and commits, the others stamp `T + 1 µs`, `T + 2 µs`, ..., so same-row updates tie and go to the tiebreaker (L2). The +1 µs bump only promises per-node order, so cross-node ties are expected. |
| **Why It Matters** | L2 needs only one forward step bigger than replication latency, not aligned clocks. While the window is open, LUW winners depend on commit counts, not real time, which matters during triage. |

**Open Questions:**

- Is the applying-node tiebreak intended (L2)? Decides how much these ties matter. `(needs human input)`

Priority: P2 · Topology: v1 · Faults: clock step (global backward, or per-node forward via a custom fault)
Confidence: medium · Surfaced by: F11 Wildcard
Evidence: properties/clock-step-forward-makes-commit-ts-ties.md
Evaluation note (2026-10-13): needs only small global skips. Optional core markers in a test-only PG patch at the patch 025 hook would let coverage guidance steer toward the bump branch.

### apply-survives-provider-clock-ahead — A subscriber behind its provider's clock does not crash

| | |
|---|---|
| **Type** | Safety |
| **Property** | A subscriber whose wall clock is behind its provider's keeps applying; applying a remote transaction whose commit timestamp is ahead of the local clock never crash-restarts the subscriber. |
| **Invariant** | Workload `Unreachable("spock apply process aborted by an Assert")` from the node logs (TRAP line from a spock source file, or a postmaster restart with "terminated by signal 6" outside injected kills). SUT-side locator `AlwaysOrUnreachable(sap.last_updated_ts >= sap.remote_commit_ts, "applied remote commit ts is not ahead of local wall clock")` just before the Assert. |
| **Antithesis Angle** | Any skew where provider time exceeds subscriber time by more than apply latency. Antithesis clock skips are global, so any backward skip trips it on every node at once; no per-container clock is needed. The commit clock spreads a fast clock to nodes that apply its transactions. On cassert the Assert aborts, the postmaster restarts the node, the transaction is resent, and it fails again while skew lasts: a crash loop. |
| **Why It Matters** | **Confirmed by code reading** at `src/spock_apply.c:1169-1174`: `.last_updated_ts = GetCurrentTimestamp()` then `/* XXX: Don't care in production yet */ Assert(sap.last_updated_ts >= sap.remote_commit_ts)`. It acts as a gate: on the cassert image every clock timeline becomes this crash loop and hides L2/L3. The team already treats the Assert as wrong: branch `task/SPOC-688/apply-clock-skew-fix` (commit 4e0988de, not in main at 69d9228f) removes it. Building the image from main plus 4e0988de turns this into a regression guard. |

**Open Questions:**

- Will the SPOC-688 fix (branch task/SPOC-688/apply-clock-skew-fix, removes the Assert) be merged, and should the Antithesis image include it before clock faults are enabled? `(partial: team already treats the Assert as wrong; branch not yet in main at 69d9228f; 4e0988de merges onto HEAD without conflicts, so the clock-fault image is built from main plus 4e0988de)`

Priority: P2 · Topology: v1 · Faults: clock skew
Priority note: lowered from P0 in evaluation: the gate is now a build step (the clock-fault image is built from main plus 4e0988de, which merges onto HEAD without conflicts), so in that image this is a regression guard. On an image without the fix, keep clock faults off.
Confidence: high (confirmed by code reading; team fix exists on a branch; not run) · Surfaced by: F3 Failure Recovery, F7 Distributed
Evidence: properties/apply-survives-provider-clock-ahead.md
Placement: build step — the clock-fault image includes 4e0988de; after that a regression guard. The workload `Unreachable` reads the TRAP line through `logging_collector` and `pg_read_file`.
Resolution: F3 proposed `AlwaysOrUnreachable` on the state, F7 `Unreachable` on reaching it. The state itself is normal under skew; the defect is the crash, so the catalog's primary check is `Unreachable` on the Assert abort, with F3's check kept as a SUT-side locator.

### luw-unchanged-toast-no-mixed-rows — Conflict winners never mix in the loser's TOAST value

| | |
|---|---|
| **Type** | Safety |
| **Property** | After quiescence, every row of a table with out-of-line TOAST columns is identical on all nodes and equals the full post-image of a single update. |
| **Invariant** | Workload `Always("toast rows identical across nodes after quiesce")` over an ordered text dump; `Always("toast row version tags consistent within the row")` where each update writes the same `<node>:<seq>` tag into the small column and the TOAST payload; `Always("toast row equals the recorded post-image of its version")` using each update's `RETURNING` post-image `(ver, small, md5(big))`. SUT-side `Reachable` in `slot_modify_data` when the remote won a conflict and a varlena column was filled from the local slot because it arrived as `'u'`. |
| **Antithesis Angle** | Latency and partitions let two nodes update the same row (one the TOAST column, one a small column) before seeing each other. The provider sends unchanged TOAST columns as `'u'` (`src/spock_proto_native.c:515-519`); when the remote wins, `spock_handle_conflict_and_apply` merges with the local row (`src/spock_apply_heap.c:636-640`). |
| **Why It Matters** | Breaks the documented whole-row LUW (`docs/conflicts.md:60-64`); divergence is permanent and logs nothing. Later updates that skip the TOAST column never repair it. Existing tests use small rows. |

**Open Questions:**

- Is the partial-row merge on remote-wins with an unchanged TOAST column known and accepted? (Inherited unchanged from pglogical; not documented in either.) `(needs human input)`

Priority: P0 · Topology: v1 · Faults: latency, partition (no clock or kill needed)
Confidence: high (two focuses found the mechanism independently; not yet run) · Surfaced by: F4 Protocol, F11 Wildcard
Evidence: properties/luw-unchanged-toast-no-mixed-rows.md
Placement: Expected to fire deterministically — confirm with TAP first, then gate out of the main template.
Evaluation note (2026-10-13): the state can be forced in TAP (disable the two subscriptions, update the TOAST column on one node and a small column on the other, re-enable). Under Antithesis it happens naturally under latency, so it stays as a P0 regression check that needs no clock or kill. P0 reflects severity.

### prepared-commit-ts-matches-sent-ts — A prepared transaction's commit timestamp is the same on its origin and its peers

| | |
|---|---|
| **Type** | Safety |
| **Property** | For a transaction committed with `PREPARE TRANSACTION` / `COMMIT PREPARED`, the commit timestamp the origin stores in `pg_commit_ts` equals the commit timestamp its peers receive and store for the applied copy. |
| **Invariant** | Workload `Always("prepared transaction's commit ts on its origin equals the commit ts its peers applied")`: after a barrier, origin `pg_xact_commit_timestamp(xid)` equals each peer's `pg_xact_commit_timestamp(xmin)` of the transaction's marker row; pairs where the origin restarted in between (redo rewrites the value) or the row was overwritten are skipped. Companion `Sometimes("prepared transaction committed while the logical clock was ahead of its commit time")` (peer value greater than origin value). `Always` because any mismatch lets LUW pick different winners on different nodes. |
| **Antithesis Angle** | Patch 025's hook bumps the WAL commit time when the shared logical clock is already at or past it; `RecordTransactionCommitPrepared` (patched `twophase.c:2310-2358`) keeps its own unbumped `committs` for `pg_commit_ts`. Plain concurrent commits make microsecond bumps (so the check fires without faults); a global backward clock jump makes the bump, and so the divergence window for contested rows, as large as the jump. Thread pausing between PREPARE and COMMIT PREPARED widens it. |
| **Why It Matters** | Confirmed by code reading: the origin judges later conflicts on that row with a smaller timestamp than every peer, so nodes can keep different versions with no exception row. Application servers using XA use two-phase commit; Spock's docs say nothing about it. The catalog's LUW oracles read the origin's commit ts and would use the wrong value for these transactions. |

**Open Questions:**

- Is two-phase commit a supported client feature on Spock clusters (doc finding vs patch-025 bug)? `(needs human input)`
- Does patch 025 for PG15-17 and PG19 have the same gap? Only PG18 was read.
- Are there other callers of `XactLogCommitRecord` that keep their own copy of the time? Only `RecordTransactionCommit` and `RecordTransactionCommitPrepared` in PG18 (grep); the abort path does not use the hook.

Priority: P1 · Topology: v1 + workload option (`max_prepared_transactions > 0`, some writers use 2PC) · Faults: none for the direct check; global backward clock jump and thread pause for the contested-row divergence
Confidence: high for the mismatch (code-checked in patched PG18); medium for divergence frequency · Surfaced by: Evaluation gap c
Evidence: properties/prepared-commit-ts-matches-sent-ts.md
Placement: Expected to fire deterministically — confirm with TAP first, then gate out of the main template (the direct message). Antithesis keeps the contested-row divergence under clock skips.
Second-pass note (2026-10-13): two-phase writers must always finish what they prepare (COMMIT or ROLLBACK PREPARED, retried after restarts); an orphaned prepared transaction holds row locks and blocks apply on those rows indefinitely (stock PG behaviour).

---

## Category E — Membership changes (ZODAN add_node / remove_node)

ZODAN coordinates several nodes over dblink: pause on the provider, slot
creation, peer progress capture, slot advance, subscription creation. Nothing
is atomic across phases, and the area has seven past data-loss fixes.

### add-node-success-new-node-has-every-row — A successful add_node leaves the new node with exactly the committed rows

| | |
|---|---|
| **Type** | Safety |
| **Property** | If ZODAN `spock.add_node` for n4 returns without error while n1-n3 keep writing under faults, n4 ends with exactly the committed ledger rows (none missing, none applied twice) and delta counters equal to the committed totals; a failed add_node leaves n1-n3 intact. |
| **Invariant** | Workload `Always(set(n4 ledger) == union of acknowledged rows on n1..n3, "add_node success: new node has every committed row")` after a full barrier round; `Always("add_node success: each n4 ledger row has one apply-audit entry")`; `Always("add_node success: n4 delta counters equal initial plus every committed increment")` on the `counters` table, with increments in flight on all three nodes during add_node (a copied value plus a re-received increment double-counts, a missed one under-counts, and copied rows carry `'epoch'` timestamps so every later remote change wins); on add_node error `Always` n1-n3 still satisfy the ledger properties. `Sometimes("add_node succeeded while writes were in flight on all three nodes")`. Workload reports any success that logged "falling back to pg_current_wal_lsn()" (a regression guard: code reading shows the fallback cannot be reached on a successful add). SUT-side `Reachable` in the pause self-resume branch of `maybe_pause_for_slot_creation`. |
| **Antithesis Angle** | Pausing the source during `CREATE_REPLICATION_SLOT` past `spock.pause_timeout` (workers self-resume, L4: the live loss path); long transactions on peers; a source restart just before add_node (empty `spock.progress` makes `read_peer_progress` drop a peer, which gives duplicates on n4, not loss); partitions during Phases 3-7 (a missing Phase 3 subscription now fails add_node at Phase 9); orchestrator kill. |
| **Why It Matters** | The tutorial says add_node "ensures no data is missed or duplicated". A gap here is permanent silent loss on the new node that only an external repair tool finds. |

**Open Questions:**

None

Priority: P0 · Topology: v1 · Faults: pause of source, partition, node kill of source, long transactions
Confidence: high (claim explicit; several mechanisms code-checked) · Surfaced by: F1 Data Integrity, F7 Distributed
Evidence: properties/add-node-success-new-node-has-every-row.md
Evaluation note (2026-10-13): add_node and node-churn properties run in their own test template (one add_node takes minutes: fixed `pg_sleep(5)` calls, a lag monitor that waits for zero lag, 180 s waits). Run add_node in its own test command with a client-side timeout so a hang does not block the quiet-period checks.

### add-node-pause-held-until-progress-read — add_node's provider pause is still in force when peer progress is read

| | |
|---|---|
| **Type** | Safety |
| **Property** | Between `pause_apply_workers` and `resume_apply_workers` on the add_node source provider, no apply worker on that provider resumes, so the peer resume LSNs captured for the new node match the COPY snapshot. |
| **Invariant** | Primary SUT-side `Unreachable("apply worker self-resumed while the pausing backend is still alive")` in the worker timeout branch of `maybe_pause_for_slot_creation` (needs the pausing backend's PID recorded in `SpockCtx`; does not fire for a crashed caller, the intended self-resume case). The flag check `Always(pause_apply == 1, "add_node pause still in effect when progress capture resumes workers")` only on the success-path call of `resume_apply_workers` (`src/spock_sync.c:857`); the PG_CATCH call (`:1644`) legitimately sees 0. `Sometimes("add_node progress capture overlapped in-flight apply work on provider")` when the first pause scan found a worker mid-transaction. |
| **Antithesis Angle** | Each paused worker self-resumes after `spock.pause_timeout` (10 s) and clears the instance-wide flag for everyone (`src/spock_apply.c:565-586`) while `CREATE_REPLICATION_SLOT` may still wait on running transactions; self-resume is meant only for a dead caller (b8b1443b). Required harness settings (not optional): `spock.pause_timeout = 1` in each node's `postgresql.conf` (USERSET; each worker reads its own value), and a workload step that holds an xid-assigned transaction open on the source across add_node Phase 5, so snapshot building waits on that xid while each paused worker self-resumes. A whole-container pause of the provider freezes slot creation and the worker timers together and rarely opens the window, and thread pausing cannot stretch the core snapbuild wait. Writes from other peers give provider apply workers something to commit in the gap. The pause scan reads worker fields without `SpockCtx->lock`; xid-less in-transaction workers count as paused, and the snapshot builder does not cover them (narrow, needs a thread pause between the flag read and the first write). Two captures against one provider are out of v1 scope. |
| **Why It Matters** | A provider apply commit after the slot snapshot but before the progress read is in neither the COPY nor any stream n4 will receive: silent permanent loss with no exception row. Five past fixes in this class. |

**Open Questions:**

None

Priority: P0 · Topology: v1 (add-node template, `spock.pause_timeout = 1`) · Faults: source transaction held open past `pause_timeout` during slot creation, writes on peers
Confidence: high (mechanism; L4 agreed by seven research focuses); medium (exact flag-level contract) · Surfaced by: F2 Concurrency
Evidence: properties/add-node-pause-held-until-progress-read.md
Gap-fill note (2026-10-13): the `Unreachable` can fire with no harm under a partition: n4's sync worker errors out, but the provider-side backend that ran the pause stays alive (idle in ClientRead) until server TCP keepalive, about 2 h with OS defaults (the server sets no `tcp_keepalives_*`). Fire it only when the same backend later reaches `spock_resume_apply_workers`, or have the harness set server `tcp_keepalives_idle` / `client_connection_check_interval` low and accept the remaining gap. Worker timeouts do not broadcast and an idle worker never clears the flag, so `pause_apply` can stay 1 long after any caller is gone; the `Always(pause_apply == 1)` at resume is unaffected. The stall bound is `add-node-pause-released-after-caller-dies`.
Evaluation note (2026-10-13): the paused state is not visible to the workload (same wait event as an idle apply worker; `paused` not exposed), so the workload emits `Sometimes("source held an xid-assigned transaction open longer than pause_timeout across add_node slot creation")` from its own actions.
Dominance: cause of `add-node-success-new-node-has-every-row`; kept separate because it fires even when no commit lands in the gap.

### add-node-success-has-sub-from-every-peer — A successful add_node produces a full mesh around the new node

| | |
|---|---|
| **Type** | Safety |
| **Property** | When ZODAN `spock.add_node` returns without error, n4 has an enabled subscription from every node that was a member when it started, and every such node has an enabled subscription from n4. |
| **Invariant** | Workload, right after add_node returns and again after barriers: `Always(every member has enabled sub to and from n4, "add_node success implies full mesh around new node")` from `spock.subscription` joined to `spock.node` on each node. |
| **Antithesis Angle** | Partition or pause between n4 and one existing node X (or n4's own loopback dblink) during Phase 3. `create_sub` failures are caught with `EXCEPTION WHEN OTHERS THEN RAISE NOTICE` (`zodan.sql:2017-2036`), but at HEAD Phase 9 calls `sub_enable` (missing_ok=false) on every peer's subscription and re-raises, and Phase 10 re-raises too (3250807a), so add_node fails. Regression guard for L20. |
| **Why It Matters** | A missing X->n4 subscription means X's changes after the COPY never reach n4, while the slot pins WAL on X. Before 3250807a the only trace was a NOTICE. Cheaper and more specific than the row check, and names the cause. |

**Open Questions:**

None

Priority: P2 · Topology: v1 · Faults: partition / pause during Phase 3
Priority note: lowered from P1: regression guard; the L20 lead is closed at HEAD.
Confidence: high (code-checked; L20 closed at HEAD) · Surfaced by: F7 Distributed
Evidence: properties/add-node-success-has-sub-from-every-peer.md

### add-node-after-peer-restart-captures-every-peer — add_node right after a source restart still captures every peer

| | |
|---|---|
| **Type** | Safety |
| **Property** | A successful add_node captures a catch-up point for every peer of the source, including when the source restarted shortly before, so the new node does not re-receive a peer's changes already in the COPY. |
| **Invariant** | SUT-side `Always(rows == expected, "read_peer_progress returned every peer of the source")` in `spock_create_slot_and_read_progress`. Workload outcome check on the duplicate side: each n4 ledger row has one apply-audit entry. Workload `Unreachable("add_node succeeded after falling back to pg_current_wal_lsn()")` on the NOTICE text of a successful add stays as a regression guard (code reading shows it cannot be reached on success). |
| **Antithesis Angle** | `read_peer_progress` inner-joins shared-memory `spock.progress`; after a crash restart without a fresh `resource.dat`, the source's entry for peer X exists only once its apply worker for X reattaches. Kills of the source between add_node phases and partitions of the source from one peer explore the gap. |
| **Why It Matters** | A dropped peer X leaves n4's row for X at the 0/0 `ensure_entry` value, so Phase 7 skips the slot advance and n4 re-receives X's changes from the Phase 3 slot point: duplicates (delta double counts, resurrected deletes), not loss. Distinct trigger from the pause window (L4). |

**Open Questions:**

- How wide is the gap between a source crash-restart and its X worker recreating the progress row, vs the Phase 5 `read_peer_progress` call (incl. n4 sync-worker retry)? `(partial: Phase 3/4 waits close the window before Phase 4 ends; the row is recreated at worker start before connecting to X, so a partition from X does not widen it; exact gap not measured)`

Priority: P2 · Topology: v1 · Faults: node kill of the source before/during add_node, partition
Priority note: lowered from P1: the outcome is duplicates on n4, not loss, and the fallback is unreachable on success.
Confidence: medium (mechanism code-checked; window not measured) · Surfaced by: F8 Lifecycle
Evidence: properties/add-node-after-peer-restart-captures-every-peer.md
Evaluation note (2026-10-13): "source restart just before add_node" is scripted (crash helper on the source, then add_node) rather than left to a random kill.

### initial-sync-ends-ready-or-visibly-disabled — Initial sync ends READY or visibly disabled, never stuck

| | |
|---|---|
| **Type** | Liveness |
| **Property** | Every subscription that starts initial sync ends, after faults stop, either enabled with sync status `r` and `replicating`, or disabled with a "nonrecoverable step" record or a raised add_node error; never enabled and stuck in `i`/`s`/`d`/`c`/`u`. |
| **Invariant** | Workload `Always` at the end of a quiet period of at least `spock.sync_timeout + apply_idle_timeout`. SUT-side `Reachable("initial sync restarted from INIT after a previous attempt")`, `Reachable("initial sync interrupted in nonrecoverable step; subscription disabled")`, `Unreachable("initial sync COPY started with sync status past DATA")`. |
| **Antithesis Angle** | Kills, partitions and pauses during each phase of add_node's src -> n4 sync: slot creation, pg_dump, COPY, post-data, catch-up; `sub_disable` mid-COPY (sync code ignores SIGTERM until it finishes). pg_dump gets only the user DSN (no keepalives or `connect_timeout`) and runs under a blocking `waitpid` that SIGTERM cannot break, so a provider restart or kill during a partition hangs n4 in status `s` for minutes to hours: an expected way for the `Always` to fire. After outcome (b) the workload must drop and re-create (`sub_enable` alone re-disables, since the status stays `s`/`d`/`c`). |
| **Why It Matters** | Interrupted sync becoming disabled is documented; a hang or a silent half-state is not. The pg_dump hang points at a fix: give pg_dump the same keepalive and `connect_timeout` options as `spock_connect`. |

**Open Questions:**

None

Priority: P1 · Topology: v1 · Faults: node kill, partition, pause during add_node sync
Confidence: medium · Surfaced by: F8 Lifecycle
Evidence: properties/initial-sync-ends-ready-or-visibly-disabled.md
Evaluation note (2026-10-13): the expected pg_dump hang also blocks the workload's `CALL spock.add_node`; run add_node in its own test command with a client-side timeout, and read n4's sync status from a separate session.

### zodan-readd-node-progress-not-stale — Re-adding a node does not reuse its old progress rows

| | |
|---|---|
| **Type** | Safety |
| **Property** | Every successful add_node, including second and later adds of a node on the same instance, leaves the joined node with exactly the cluster's committed rows, with no duplicates. |
| **Invariant** | Workload `Always("re-added node holds exactly the cluster's rows")` after each successful add and quiescence (ledger completeness, no extra rows, plus the `insert_exists` oracle of `ledger-row-applied-exactly-once-per-peer` on the joined node); `Sometimes("add_node succeeded on a node that had been removed before")`. ZODAN-side marker: Phase 7 logs whether the chosen `spock.progress` row's `last_updated_ts` is after the add_node start; workload asserts it always is. |
| **Antithesis Angle** | `SpockGroupHash` entries are never deleted (only a new initdb clears them) and survive restarts via `resource.dat`. Same-name re-add is supported and tested (TAP 011/012/017/033). ZODAN Phase 7 reads `spock.progress` by `remote_node_id` only, without the local `node_id` filter Phase 3 uses, with non-STRICT `SELECT INTO`. When `read_peer_progress` omits a peer (source restart), a row from the node's previous life is used, the slot is not advanced, and the new node re-receives changes already in the COPY; it also triggers a RECONCILE ANOMALY at Phase 9. |
| **Why It Matters** | Re-join is in the deployment plan, so the harness will exercise this path anyway. A duplicated INSERT of a row deleted elsewhere before the snapshot resurrects it on the joined node only. |

**Open Questions:**

- Is skipping an empty pre-existing user schema on the new node intended? If not, an operator who empties a node by dropping tables gets a node with whole schemas missing and no error. `(needs human input)`

Priority: P2 · Topology: v1 (needs remove + re-add of n4) · Faults: node kill of source, re-add
Confidence: medium (scenario confirmed by code reading; not run) · Surfaced by: F11 Wildcard
Evidence: properties/zodan-readd-node-progress-not-stale.md
Gap-fill note (2026-10-13): the re-add drops n4's user **schemas**, not only its tables. add_node's prerequisite counts only tables (`samples/Z0DAN/zodan.sql:1577-1592`), but `create_sub` turns every pre-existing non-`public` user schema on n4 into `skip_schema` (`:347-372`), which removes it from both the structure dump and the data sync (`src/spock_sync.c:1388-1393`); an emptied-but-kept schema would show as missing rows (a harness artefact).
Evaluation note (2026-10-13): a re-add first drops n4's user tables (add_node refuses a database with user tables, `samples/Z0DAN/zodan.sql:1577-1592`) and makes sure n4 has every role the source has (`:1595`). Stale `spock.progress` rows stay visible either way (not filtered by database). The Phase 7 `last_updated_ts` marker is a change to `samples/Z0DAN/zodan.sql` and is listed as a SUT change. Runs in the add-node template.

### remove-node-clean-report-no-leftovers — remove_node reports every link to the removed node it could not remove

| | |
|---|---|
| **Type** | Safety |
| **Property** | When ZODAN `spock.remove_node(n4)` finishes, every survivor slot or subscription it left behind for n4 is reported in its `temp_removal_status` table. |
| **Invariant** | Workload records n4's `sub_slot_name`s before the call and reads `temp_removal_status` in the same session after it. For each recorded slot still present on a survivor (and any survivor subscription from n4), `Always(a status row names it as not removed, "remove_node reports every replication link it could not remove")`. Until the open question is answered, a matching "could not drop slot" WARNING in n4's server log also counts as reported. Expected to fire at HEAD (known gap) when only the status table counts. |
| **Antithesis Angle** | `sub_drop` succeeding when the remote slot drop fails is intended (`src/spock_functions.c:838-860`); zodremove then records `REMOVED`. It happens without a partition too: `pg_drop_replication_slot` errors at once while X's walsender still holds the slot, which is normal under latency and lasts up to `wal_sender_timeout` under a one-way or silent partition. A full n4-X partition usually shows as `ERROR` in the first loop; the hidden case is a link that fails, or a walsender that lingers, between the two loops. remove_node has no "all nodes available" precondition, so partitions are in scope. |
| **Why It Matters** | The unreported slot on X holds WAL until an operator notices a WARNING in a log, eventually filling a survivor's disk while the removal reported success. |

**Open Questions:**

- Should zodremove record `sub_drop`'s "could not drop slot" WARNING in `temp_removal_status` instead of `REMOVED`? `(needs human input)`

Priority: P3 · Topology: v1 · Faults: partition during remove_node
Priority note: lowered from P2 in evaluation: a reporting gap with a known code cause that happens without a partition too; file it as a code-reading finding with a TAP repro and keep this as a cheap check.
Confidence: medium · Surfaced by: F7 Distributed
Evidence: properties/remove-node-clean-report-no-leftovers.md
Placement: Expected to fire deterministically — confirm with TAP first, then gate out of the main template.
Evaluation note (2026-10-13): the WARNING in n4's server log is read through `logging_collector` and `pg_read_file`.

### add-node-returns-within-bound — ZODAN add_node returns or raises within a bound after faults stop

| | |
|---|---|
| **Type** | Liveness |
| **Property** | Once faults stop, a running `CALL spock.add_node(...)` returns, successfully or with an error, within a bound derived from `spock.sync_timeout()`. |
| **Invariant** | Workload `Always(add_node returned or raised within B after faults stopped, "add_node returns within bound after faults stop")`, B = sum of ZODAN's own wait budgets (about 12·S + 90 s for v1, S = `sync_timeout` set in the session) plus margin. Second message from sampling `pg_stat_activity` on n4: `Always(no add_node backend waits in DblinkConnect/DblinkGetResult longer than S + margin after faults stopped, "add_node dblink call does not outlive its budget after faults stop")`, which names the stuck step. Companion `Sometimes("a peer was partitioned or paused while add_node had a dblink call open to it")`. |
| **Antithesis Angle** | Every `dblink(dsn, ...)` in `samples/Z0DAN/zodan.sql` uses the DSN as given (no `connect_timeout`, OS keepalive idle about 2 h). A peer killed while partitioned from n4 during an open dblink call (Phase 4's remote `wait_for_sync_event` lasts up to S) may leave n4 reading a half-open socket after the heal. Phase 3's `set_config('statement_timeout','5s')` around its probe never takes effect (the timer is armed only at top-level statement start). Long partitions outlast the peer's retransmits; pauses and connect attempts to partitioned hosts add delay. Budgets use wall clock, so backward clock skips stretch them. |
| **Why It Matters** | V5 claims add_node completes or fails within a `sync_timeout`-derived bound. A hung add_node holds a transaction on n4, half-created slots on peers pinning WAL, and blocks the operator's retry (cleanup must wait for it). |

**Open Questions:**

- What total bound does the team expect for add_node after faults stop? `(needs human input)`
- Does an Antithesis node kill during a partition leave the other end's socket half-open after the heal? Decides whether the main scenario fires or the property is a regression guard.
- Is Phase 3's `statement_timeout = '5s'` meant to bound the probe? `(partial: code reading shows it never takes effect inside the CALL; intent unknown)`

Priority: P2 · Topology: v1 (add-node template) · Faults: partition + node kill of a peer during add_node, process pause of a peer, node kill of n4
Confidence: medium (dblink and timeout behaviour code-checked; half-open trigger unverified) · Surfaced by: Evaluation gap b
Evidence: properties/add-node-returns-within-bound.md
Note: the same client-side timeout that keeps a hung add_node from blocking the quiet-period checks (evaluation note on `add-node-success-new-node-has-every-row`) is set above B, so this property, not the harness, reports the hang.

### add-node-pause-released-after-caller-dies — Apply on the source resumes within pause_timeout after the pausing caller dies

| | |
|---|---|
| **Type** | Liveness |
| **Property** | When the sync worker that called `spock.pause_apply_workers()` on a provider dies or loses its connection before calling resume, every provider apply worker commits its next remote transaction within `spock.pause_timeout` plus normal apply latency. |
| **Invariant** | Workload `Always(each peer's marker row is visible on src within pause_timeout + margin after the caller was killed, "provider apply resumes within pause_timeout after the pausing caller dies")`, scored only when Antithesis did not fault src or that peer in the window. Precondition marker `Sometimes("pausing caller killed while provider CREATE_REPLICATION_SLOT was in progress")`. SUT-side `Reachable("apply worker self-resumed after the pausing caller was gone")` in the timeout branch of `maybe_pause_for_slot_creation`, using the pausing-backend PID that `add-node-pause-held-until-progress-read` also needs. |
| **Antithesis Angle** | The workload holds an xid-assigned transaction on src so `CREATE_REPLICATION_SLOT` waits; while that shows in src's `pg_stat_activity` the flag is set. It then kills the caller (terminate the provider backend that ran the pause, kill n4, or partition n4 from src). Each worker self-resumes after its own monotonic `pause_timeout` and clears the flag without a broadcast; an idle provider keeps the flag set indefinitely and stalls the next remote transaction once. |
| **Why It Matters** | The sync worker's error path relies on this ("the workers' CV timeout will recover them"). An unbounded pause would stop all inbound replication to the source with no error. The errhint advises raising `pause_timeout`, which lengthens this stall. |

**Open Questions:**

- Is the stale flag on an idle provider (one extra `pause_timeout` stall on the next remote transaction, possibly much later) acceptable, or should the pause be cleared when the caller's backend exits?

Priority: P3 · Topology: v1 (add-node template) · Faults: worker exit (terminate the provider-side pausing backend), node kill of n4, partition n4-src during slot creation
Confidence: high (mechanism code-checked; not run) · Surfaced by: Evaluation gap b
Evidence: properties/add-node-pause-released-after-caller-dies.md
Priority note: regression guard: code reading shows the bound holds (per-worker monotonic timeout, flag reset at crash-restart); cheap once the shared PID instrumentation exists.

---

## Category F — Feedback, origins, slots and the stream protocol

What the subscriber tells the provider (flush feedback), what it records
(replication origins, `spock.progress`), and the per-message protocol rules.
Errors here become silent skips or duplicates.

### feedback-never-confirms-undurable-apply — Flush feedback never confirms a transaction the subscriber has not durably applied

| | |
|---|---|
| **Type** | Safety |
| **Property** | The flush position the apply worker reports to the provider never passes a provider transaction that is in flight or whose local commit on the subscriber (or its sync standby) is not yet durable. |
| **Invariant** | Three SUT-side `Always` checks with distinct messages: (1) in `send_feedback()`, `!in_remote_transaction || flushpos <= replorigin_session_origin_lsn` ("feedback flush position does not pass the in-flight remote transaction"); (2) in `send_feedback()`, `flushpos < remote_end` for every `lsn_mapping` entry with `local_end > GetFlushRecPtr()` and every held sync-standby entry; (3) in `request_initial_status_update()` and the first empty-mapping feedback of a process, the session origin's `local_lsn <= GetFlushRecPtr()`. Companions `Sometimes("feedback sent while inside a remote transaction")`, `Sometimes("apply worker restarted while its origin local_lsn was unflushed")`. |
| **Antithesis Angle** | Graceful apply-worker exit (terminate, `sub_disable`/`sub_enable`, provider disconnect) followed within the async-commit flush delay by a subscriber node kill: the new worker reports `flush = origin_startpos` read without a flush, the provider confirms, crash recovery loses the commit. Check (3) can fail only with `spock.synchronous_commit=off` (the default), so the workload keeps the default or randomises it. Check (1) is a guard: the strict skip test and late `sentPtr` update are unchanged in PG18. L9 (sync-standby hold overwritten) needs a standby container. |
| **Why It Matters** | A violation is permanent silent loss: the provider never resends and no exception row exists. Same family as 5f654e34. |

**Open Questions:**

- Is there any WAL flush between the old worker's last commit and the new worker's initial feedback report? `(partial: none in spock's exit/start path or in PG18 worker exit; only spock.synchronous_commit=on closes the window; not yet shown in a run)`
- Is `flush = recvpos` with an empty mapping right after a worker restart accepted (it matches stock PG18 worker.c), limiting a fix to the explicit initial report? `(needs human input)`
- Is unconditional keepalive feedback during `sub_disable` replay intended? `(needs human input)` `(partial: safe by stream order — keepalives are read only from the live socket, after earlier messages)`

Priority: P0 · Topology: v1 (sync-standby part: v2/standby) · Faults: worker exit then node kill within flush delay, thread pause
Confidence: medium · Surfaced by: F4 Protocol, F9 Idempotency
Evidence: properties/feedback-never-confirms-undurable-apply.md
Gap-fill note (2026-10-13): L9 has a second path: every apply worker start sends `request_initial_status_update(origin_startpos)` as flushed (`src/spock_apply.c:4778`) with no sync-standby check, and the hold list is gone after a restart; the SUT-side held-entry check of check (2) cannot see it. Both paths are owned by `sync-standby-hold-freezes-provider-confirmed-flush` (phantom variant, no standby container); the failover outcome by `promoted-subscriber-standby-has-every-confirmed-txn` (`v2/standby`).
Evaluation note (2026-10-13): check (3) needs the old worker's async apply commits still unflushed when the new worker starts; client commits on S with `synchronous_commit = on` flush them, and a clean exit restarts only after `restart_delay_default` (5 s). So: a phase with no client writes on S, `sub_disable` then `sub_enable` back to back as the exit (enable wakes the manager), a run variant with `wal_writer_delay` raised (5-10 s), and the follow-up kill from the crash helper. The sync-standby part of check (2) can be reached without a standby container: `synchronous_standby_names = 'phantom'` on one subscriber (clients there use `synchronous_commit = local`); confirm with TAP first.

### crash-redo-leaves-no-node-id-origin-state — Crash recovery restores only real replication origins

| | |
|---|---|
| **Type** | Safety |
| **Property** | After any crash recovery, `pg_replication_origin_status` contains no progress row whose id has no `pg_replication_origin` entry (no node-id-numbered states created by redo). |
| **Invariant** | Workload `Unreachable("pg_replication_origin_status has a progress row with no pg_replication_origin entry")` from a LEFT JOIN probe after every node restart and in every quiet-period check; The workload asserts only on a NULL-name row seen in two samples a few seconds apart (or in a quiet period), since a dropped origin shows the same NULL for a moment. SUT-side: the same check through SPI on `pg_show_replication_origin_status()` in `spock_apply_main` (`replication_states` is static in `origin.c`), or drop it in favour of the workload probe. Never legitimate. |
| **Antithesis Angle** | Kill a subscriber between checkpoints while it applies. Redo advances `XLogRecGetOrigin(record)` (the provider's node id set by `handle_origin`) instead of the slot-named origin, so the subscription origin falls back to its last checkpoint value. Confirmed by code reading on patched PG18 (the patches touch only the commit-timestamp hook; `spock_rmgr` redo only logs and reconcile trusts the regressed origin). |
| **Why It Matters** | Direct, cheap detector of lead L1, which otherwise shows only as rare duplicates. Expected to fire on the first subscriber crash with an applied remote transaction since the last checkpoint: a likely finding, not a guard. Duplicates double-count delta columns; orphan states are never dropped and can fill `max_active_replication_origins`, which stops a node from starting. TAP 008/022 add a CHECKPOINT before SIGKILL, which hides this. |

**Open Questions:**

- Is the node-id origin state an intended side effect? `(partial: TAP 022's header and the no-checkpoint-hook design doc both assume redo restores the slot-named origin, and no doc mentions node-id states; looks unintended)`
- Should the workload rotate node names (or run many concurrent table resyncs) to push origin-state use toward `max_active_replication_origins`? `(partial: steady state is about 6-8 of the default 10 per node in the planned topology; exhaustion needs churn under new names)`

Priority: P0 · Topology: v1 · Faults: node kill between checkpoints
Priority note: kept P0: L1 now confirmed at code level on patched PG18 (two investigation groups); expected to fire, not a guard.
Confidence: high (mechanism code-checked on PG17 and patched PG18; reachable with plain crash faults; not run) · Surfaced by: F3 Failure Recovery (same states seen by F5 in `replication-origin-states-do-not-leak`)
Evidence: properties/crash-redo-leaves-no-node-id-origin-state.md
Placement: Expected to fire deterministically — confirm with TAP first, then gate out of the main template.
Evaluation note (2026-10-13): confirm by TAP (kill -9 without CHECKPOINT). Keep it in Antithesis as the root signal for the L1 cluster only while the consequence properties use their "explained by L1" split; otherwise it fires every run and hides second causes. Workload-side `Sometimes("subscriber restarted with applied remote commits since its last checkpoint")`. A test-only PG patch can add a marker in `xact_redo_commit` when the record's origin id has no catalog entry.
Resolution: kept separate from `replication-origin-states-do-not-leak`. This property owns the "no unnamed origin state" check; the leak property keeps capacity and orphan-named-origin checks.

### apply-stream-framing-and-lsn-order — Apply stream follows the protocol grammar and LSN order

| | |
|---|---|
| **Type** | Safety |
| **Property** | On every replication connection the subscriber sees STARTUP first (announcing protocol 5 on 6.0 <-> 6.0 links), then transactions framed as BEGIN, ORIGIN, changes, COMMIT with matching commit LSN and commit time, strictly increasing end LSN, and no transaction starting below the origin's recorded progress. |
| **Invariant** | SUT-side checks in the apply worker, each with its own message: `Always` first non-keepalive message is STARTUP; `Always` announced `proto_version == 5` when both sides are 6.0 (compile-time constant; no version-cap GUC at HEAD); `Always` no BEGIN inside an open remote transaction (replayed BEGINs do not trip it); `Always` ORIGIN precedes the first change (tested on `remote_origin_id`, which `handle_begin` resets; `replorigin_session_origin` is never per-transaction Invalid); `Always` COMMIT `commit_lsn` == BEGIN `commit_lsn` and `end_lsn > commit_lsn`; `Always` `end_lsn` strictly increases per connection; `Always` BEGIN `commit_lsn` >= origin progress (no legitimate re-delivery below it). `Reachable` for a non-transactional sync_event before the first BEGIN, and at the `pg_decode_message` branch that sends 'S' before a sync_event (fdd9587e path; sync_event is the only Spock message on the wire). |
| **Antithesis Angle** | Walsender kills mid-decode, provider restarts, drops between BEGIN and COMMIT, reconnect while the old walsender holds the slot, CPU pauses in the output plugin; reconnects followed by workload or ZODAN `sync_event` calls make the first decoded item a non-transactional message. |
| **Why It Matters** | A missing ORIGIN stamps commits with the previous transaction's node id (wrong LUW, echo); a redelivered transaction double-applies; a non-STARTUP first message under v5 is misparsed (fdd9587e). Several rules are not checked at all today. |

**Open Questions:**

None

Priority: P2 · Topology: v1 · Faults: walsender kill, partition, provider restart
Confidence: medium (rules clear from code; no known violation under v1 naming) · Surfaced by: F4 Protocol, F10 Versions
Evidence: properties/apply-stream-framing-and-lsn-order.md
Evaluation note (2026-10-13): cheap checks evaluated on every message of every timeline and guards for the other oracles: put them in the first SUT-instrumentation batch regardless of rank.

### progress-insert-lsn-never-ahead-of-provider — Recorded provider LSNs never exceed the provider's WAL

| | |
|---|---|
| **Type** | Safety |
| **Property** | For every subscriber S and provider P, `spock.progress.remote_insert_lsn` and `received_lsn` for P on S never exceed the highest WAL insert LSN P has reached. |
| **Invariant** | Workload `Always(remote_insert_lsn <= maxP && received_lsn <= maxP)`: read S's `spock.progress` first, then P's `pg_current_wal_insert_lsn()`, with `maxP` the highest value ever observed on P (safe if P loses unflushed WAL in a crash). Checked at every check point. |
| **Antithesis Angle** | Passive cross-node oracle. Fires on any header offset error in v5 (prefix on every message) or v4 (suffix on COMMIT) parsing, on stream or replay, including the 'S' replay misparse. |
| **Why It Matters** | `remote_insert_lsn` feeds lag monitoring, add_node progress seeding and `resource.dat`. Wrong values are silent; no Assert catches a too-large value. |

**Open Questions:**

None

Priority: P2 · Topology: v1 · Faults: reconnect plus a data error (see `proto5-replay-reparses-startup-message`)
Priority note: lowered from P1 in evaluation: `spock.progress` is monitoring in steady state, and the only known cause is the protocol-5 replay misparse; this runs as that property's workload consequence check and as a passive guard on v4 links.
Confidence: medium-high · Surfaced by: F10 Versions
Evidence: properties/progress-insert-lsn-never-ahead-of-provider.md

### progress-reconcile-anomaly-unreachable — Progress entry is never ahead of the origin at apply start

| | |
|---|---|
| **Type** | Safety |
| **Property** | Without manual origin changes, `reconcile_progress_with_origin()` never finds the `SpockGroupHash` entry ahead of the subscription origin (the `RECONCILE_FILE_ANOMALY` branch is never taken). |
| **Invariant** | SUT-side `Unreachable("progress entry ahead of replication origin at apply start")` in the ANOMALY branch (`src/spock_progress_recovery.c:~245-270`); workload fallback `Unreachable` on the log text "ahead of origin ... trusting origin". The code attributes this state to operator action or corruption, but code reading found no-operator paths (see Antithesis Angle). |
| **Antithesis Angle** | Kill the joining node between ZODAN Phase 5 force-set (keys `(db, n4, X)`, the live subscription's key) and Phase 7 origin advance; re-add or retry add_node with a peer omitted, so a stale entry meets a reset origin; table resync that writes provider progress into the subscriber's live row, followed by a worker restart. |
| **Why It Matters** | `spock.progress` is monitoring in steady state and coordination input for ZODAN Phase 3/7. ANOMALY trusts the origin, so a hit is a progress-accuracy finding, not loss; it shows some path wrote progress it did not own (L16/L17). |

**Open Questions:**

- Does the v1 workload run table resyncs (`sub_resync_table` / `repset_add_table` with sync)? If yes ANOMALY is reachable with no operator action and the Unreachable must exclude those timelines or be treated as a progress-accuracy finding. `(partial: path confirmed in code; workload choice not made yet)`

Priority: P2 · Topology: v1 · Faults: node kill during add_node, add_node retry
Confidence: medium · Surfaced by: F3 Failure Recovery
Evidence: properties/progress-reconcile-anomaly-unreachable.md

### progress-commit-lsn-tracks-applied-commits — spock.progress keeps up with what was applied

| | |
|---|---|
| **Type** | Safety |
| **Property** | Once S has applied P's transaction T, `spock.progress.remote_commit_lsn` on S for (S, P) is at or beyond T's commit LSN on P. |
| **Invariant** | Workload: read `pg_current_wal_insert_lsn()` on P before T's COMMIT (a lower bound on T's end LSN); after T's row is visible on S, `Always(remote_commit_lsn(S,P) >= bound, "spock.progress commit LSN covers applied txn")`; skip if S restarted in between. SUT-side `Unreachable("progress commit LSN update dropped because commit ts went backwards")` in `progress_update_struct` (`src/spock_group.c:309-362`) applies only to an image without 4e0988de; in the clock-fault image that site does not exist, so the check is workload-only there. |
| **Antithesis Angle** | `progress_update_struct` updates the commit LSN only when the commit ts grows. After a provider restart with its clock behind its last logical maximum (L3, confirmed in the patch 025 TODO; a global backward skip plus restart reaches it), P's new commits carry smaller ts and S's entry freezes until P's ts passes the old maximum. |
| **Why It Matters** | `spock.lag_tracker` reports lag that is not real, and ZODAN Phase 3 waits on this value, so add_node times out. Not data loss: Phase 7 uses the origin's `remote_lsn`. |

**Open Questions:**

None

Priority: P3 · Topology: v1 · Faults: clock skew + node kill of provider
Priority note: lowered from P2: monitoring accuracy and add_node availability only, no data loss. Evaluation: cannot find a bug once 4e0988de is in the image (that commit makes `progress_update_struct` advance `remote_commit_lsn` whatever the timestamps), and the image without it runs no clock faults; kept only as a regression guard for the fix.
Confidence: medium · Surfaced by: F7 Distributed
Evidence: properties/progress-commit-lsn-tracks-applied-commits.md

### enabled-subscription-always-has-provider-slot — An enabled subscription never loses its provider slot

| | |
|---|---|
| **Type** | Safety |
| **Property** | In a quiet period with all nodes up, every enabled, READY subscription has its replication slot on its provider. |
| **Invariant** | Workload `Always` per subscription row (`sub_enabled`, sync status READY) that `pg_replication_slots` on the provider contains `sub_slot_name`. `Sometimes("orphan slot found for a dropped subscription")` for the documented leak path. SUT-side `Reachable("sub_drop dropped remote slot before local commit")`. |
| **Antithesis Angle** | `spock_drop_subscription` drops the remote slot over a new connection before the local transaction commits. A kill of the subscriber node or of the `sub_drop` / `remove_node` session in that window rolls back the catalog delete but not the slot drop. |
| **Why It Matters** | Leaves a subscription that retries START_REPLICATION every 5 s forever: the failure is a plain ERROR outside PG_TRY, so no exception row, and `sub_show_status` alternates between `replicating` and `down`. No monitoring reports the missing slot. Permanent silent divergence; `remove_node` hits the same code on every peer. |

**Open Questions:**

- Is dropping the remote slot before the local commit a deliberate trade-off (vs. drop after commit and accept orphan slots)? Order unchanged since the pglogical import, no rationale recorded. `(needs human input)`

Priority: P1 · Topology: v1 · Faults: node kill during sub_drop / remove_node
Confidence: medium · Surfaced by: F8 Lifecycle
Evidence: properties/enabled-subscription-always-has-provider-slot.md
Evaluation note (2026-10-13): run on a throwaway subscription with its own replication set and table (dropping a mesh subscription breaks the shared oracles); start `sub_drop` and call the crash helper after a small random delay, since random kills rarely land between the remote slot drop and the local commit.

### provider-slot-owned-by-one-subscription — A provider slot is used by one subscription only

| | |
|---|---|
| **Type** | Safety |
| **Property** | Each `spock_output` slot on a provider belongs to exactly one subscription in the cluster, and no subscription loses changes because another node's subscription created, dropped or consumed its slot. |
| **Invariant** | Workload `Always("provider slot used by at most one subscription")` from a cross-node join of `spock.subscription` (provider, slot name), plus the ledger completeness check for the subscribers involved. SUT-side `Unreachable` in `spock_create_slot_and_read_progress` and `spock_sync_worker_cleanup` when the slot about to be dropped has been confirmed past anything this subscription's origin knows. |
| **Antithesis Angle** | Slot name `spk_<subscriber db>_<provider>_<sub name>` omits the subscriber node, and every character outside `[a-z0-9_]` is mapped to `_`. So names that follow the documented rule ("Must be unique across the cluster", not enforced) still collide: `sub_A` on n2 and `sub_B` on n3 share one slot on n1. The test configuration uses such names (avoiding mapped names ending `_<digit>`, which turn on slot groups). A partition or restart of one subscriber while the other runs initial sync lets the second drop and recreate the slot. Identical names on two nodes is the user-error case (should be rejected; lower priority). |
| **Why It Matters** | Silent permanent loss through a documented-valid configuration that every per-node check accepts. ZODAN's `sub_<provider>_<subscriber>` names are safe; hand-made meshes are not. |

**Open Questions:**

- Should slot names include the subscriber node (or record an owner)? Affects upgrades, origins and four ZODAN `spock_gen_slot_name` call sites. `(needs human input)`

Priority: P2 · Topology: v2/colliding-names (separate config with clashing subscription names) · Faults: partition / restart during initial sync
Confidence: high · Surfaced by: F11 Wildcard
Evidence: properties/provider-slot-owned-by-one-subscription.md

### forwarded-origin-advance-no-double-apply — Switching from a forwarding subscription to a direct one skips nothing and replays at most one transaction per crash

| | |
|---|---|
| **Type** | Safety |
| **Property** | In a cascade (C subscribes to B with `forward_origins='{all}'` and holds a disabled direct subscription to A), enabling the direct A->C subscription skips no A transaction, and re-applies one only within the documented bound: at most one replayed transaction per crash of C. |
| **Invariant** | Three workload `AlwaysOrUnreachable` messages on C after the switch: "no A transaction missing on C after switching to the direct subscription"; "duplicates on C bounded by C crashes" (per A transaction, extra applies through `sub_A_C` <= C crashes while the forwarding path was active); "no duplicates without a crash". Duplicates are attributed by the applying subscription (recorded in the apply-audit row), because L1 can also make B resend to C through the forwarding subscription. SUT-side `Reachable("forwarded origin advanced for a pre-created subscription")`. `AlwaysOrUnreachable` because only runs that reach the switch evaluate it. |
| **Antithesis Angle** | Kill C between the data commit and the separate `replorigin_advance` WAL record in `maybe_advance_forwarded_origin` (`src/spock_apply.c:1137, 5167-5183`); race disable/enable of the two subscriptions to hit 55006 after commit (switch order constrained by `enforce_forwarding_exclusivity`). |
| **Why It Matters** | A documented, supported flow (`docs/spock_functions/sub_mgmt.md` "Origin Forwarding", v6.0 release notes, TAP 015). The advance cannot be atomic with the commit using PostgreSQL's origin API, so 401197ab documents at-least-once with at most one replay per crash; delta columns double-count within that bound. More than one replay per crash, or any duplicate without a crash, is a bug. |

**Open Questions:**

None

Priority: P2 · Topology: v2/cascade · Faults: node kill after commit, subscription enable/disable races
Priority note: kept P2: invariant restated as the documented at-least-once bound (at most one replay per crash); needs the cascade topology.
Confidence: medium (flow and bound documented; code-checked, not run) · Surfaced by: F9 Idempotency
Evidence: properties/forwarded-origin-advance-no-double-apply.md

### sync-standby-hold-freezes-provider-confirmed-flush — A subscriber's sync-standby hold keeps the provider slot behind unconfirmed transactions

| | |
|---|---|
| **Type** | Safety |
| **Property** | While a subscriber's synchronous standby has not flushed a transaction's local commit, the provider's `confirmed_flush_lsn` for that subscription does not pass that transaction. |
| **Invariant** | Config variant with `synchronous_standby_names = 'phantom'` (no standby ever connects) on one subscriber S. Workload records S's origin `remote_lsn` at the switch (`R0`) and `E`, the first observed value above `R0`; then `Always("provider slot of a subscriber with an unconfirmed sync standby stays below its first held transaction")`: provider `confirmed_flush_lsn < E` on every poll. Companions `Sometimes("subscriber with phantom sync standby applied a provider transaction")` and `Sometimes("apply worker of the held subscription reconnected")`. |
| **Antithesis Angle** | Two code-confirmed ways to break it: `send_feedback()` sets `flushpos = recvpos` once `lsn_mapping` drains, ignoring the hold list (L9, `src/spock_apply.c:3253-3266`, deterministic); and every apply worker start sends `request_initial_status_update(origin_startpos)` (`:4778`) with no standby check, and the in-memory hold list is gone. Partitions, idle-timeout reconnects, walsender kills and node restarts reach the second path, which a fix to the first leaves open. |
| **Why It Matters** | Claimed guarantee in the code (`:3120-3125`) and S9. A provider that confirmed past what the standby has frees that WAL, and failover of the subscriber then loses those transactions silently. Needs no sixth container. |

**Open Questions:**

- Should a restarted apply worker hold feedback until the sync standby passes the origin's `local_lsn`, i.e. is the restart path in scope? `(needs human input)`
- Can confirming filtered-out WAL ahead of a held transaction happen in correct code? `(partial: by stream order a keepalive's sentPtr is past every earlier sent transaction, so that is mechanism 1, not a false positive)`

Priority: P1 · Topology: v2/phantom-sync-standby (v1 containers, one subscriber with a phantom `synchronous_standby_names` and `synchronous_commit = local`) · Faults: none for L9; partitions, worker / walsender kills, node restarts for the restart path
Confidence: high (both paths code-checked; L9 deterministic) · Surfaced by: Evaluation gap c
Evidence: properties/sync-standby-hold-freezes-provider-confirmed-flush.md
Placement: Expected to fire deterministically (mechanism 1) — confirm with TAP first, then gate out of the main template; the Antithesis variant targets the restart path.
Dominance: check (2) of `feedback-never-confirms-undurable-apply` is the SUT-side detector for mechanism 1; this is the workload-side outcome for both mechanisms.

### promoted-subscriber-standby-has-every-confirmed-txn — Failing a subscriber over to its sync standby loses no replicated transaction

| | |
|---|---|
| **Type** | Safety |
| **Property** | After a subscriber is killed and its synchronous physical standby is promoted, every provider transaction the provider's slot had confirmed for that subscriber is present on the promoted node once it resumes replication; rows the old subscriber originated and peers received are also present. |
| **Invariant** | Workload `Always("promoted subscriber standby has every provider transaction its provider had confirmed")` after promotion and barriers from every provider to the promoted node (equivalently, `committed-ledger-row-reaches-every-node` evaluated with the promoted node). `Always("rows the failed subscriber originated and peers received exist on the promoted standby")` for its `synchronous_commit=on` client rows. `Sometimes("subscriber standby promoted while its provider slot was ahead of the standby's replay position")`. |
| **Antithesis Angle** | Pause the standby so it lags, keep providers writing, kill the subscriber primary, promote. L9 and the restart path let the provider confirm past what the standby has; a logical slot never streams from before `confirmed_flush` (`logical.c:558-577`), so those transactions are skipped for good. |
| **Why It Matters** | S9 is one of Spock's strongest written claims ("resumes ... with no data loss") and the evaluation found no standalone `v2/standby` property. This is the end-to-end user outcome behind the phantom check. |

**Open Questions:**

- Is subscriber failover a supported scenario, and how are other nodes pointed at the promoted node (`sub_alter_interface`, DNS alias)? `(needs human input)`
- Does a promoted standby start Spock workers cleanly with the same node id (shared memory, `resource.dat`, progress)?
- Expected to fail at HEAD if the provider confirmed past what the standby had (L9); run `sync-standby-hold-freezes-provider-confirmed-flush` first, then this checks the end-to-end claim after a fix.

Priority: P2 · Topology: v2/standby (n1-n3 mesh plus a sync physical standby of n2 with `sync_replication_slots = on`) · Faults: process pause of the standby, node kill of the subscriber primary, latency between primary and standby
Confidence: medium (loss path code-checked; failover runbook unknown) · Surfaced by: Evaluation gap c
Evidence: properties/promoted-subscriber-standby-has-every-confirmed-txn.md

### walsender-never-joins-slot-group — No walsender joins a slot group outside the slot-group config

| | |
|---|---|
| **Type** | Safety |
| **Property** | In every run except a deliberate slot-group variant, no Spock walsender joins a slot group. |
| **Invariant** | SUT-side `Unreachable("walsender joined a slot group")` in `spock_output_join_slot_group` right after the name test succeeds (`src/spock_output_plugin.c:1300-1313`); plus a setup check that no `spock_output` slot name matches `_[0-9]$`. |
| **Antithesis Angle** | None from faults. Guards the harness: any subscriber node named like `node-1`, `db_east_1` or `N1` gives a slot name ending `_<digit>` through `gen_slot_name` (`src/spock_functions.c:3666-3687`) and ZODAN's `sub_<provider>_<subscriber>` names, which would turn every ledger check into a slot-group finding. |
| **Why It Matters** | Users pick such names without knowing; the reject fix (f6887c7a) is not on main. Zero-cost guard in every run. |

**Open Questions:**

- Will f6887c7a (reject grouped slot names) merge to main? `(needs human input)`

Priority: P3 · Topology: v1 (disabled in the deliberate `v2/slot-groups` variant) · Faults: none
Confidence: high (name mapping code-checked) · Surfaced by: Evaluation gap c
Evidence: properties/walsender-never-joins-slot-group.md

---

## Category G — Operator actions and worker lifecycle

Subscription disable/enable/drop, read-only mode, table resync, shutdown.
Each of these stops an apply or sync worker at an arbitrary point, which is
where the exception-marker bugs keep coming from.

### sub-disable-enable-cycle-loses-and-duplicates-nothing — Disable/enable/alter cycles under load lose and duplicate nothing

| | |
|---|---|
| **Type** | Safety |
| **Property** | Any sequence of `sub_disable` (immediate or not), `sub_enable` and other `sub_alter_*` calls on live subscriptions, followed by re-enabling them all, leaves every node with exactly one copy of each committed ledger row, exact delta counters, no `spock.exception_log` rows and all subscriptions enabled. |
| **Invariant** | Workload `Always` at quiescence after the last enable (exactly-once per `(origin, seq)`, delta totals, no `exception_log` rows outside the expected-exception registry, `sub_enabled = true`). SUT-side `Sometimes(in_remote_transaction, "apply worker SIGTERM landed inside a remote transaction")` at the `got_SIGTERM` clear site at the end of `apply_work()`. |
| **Antithesis Angle** | `alter_subscription()` kills the worker at COMMIT via `signal_worker_xact_callback`; Antithesis decides where in a large remote transaction the SIGTERM lands and whether it coincides with a reconnect, lock wait or `handle_commit`. Tests the `ed0a9945` and `db380dd8`/TAP 105 fixes against nearby timings. |
| **Why It Matters** | Two recent fixes in this exact path (spurious SUB_DISABLE; silent TRANSDISCARD of a retransmitted transaction). A miss means a routine operator action silently drops a transaction on one node. |

**Open Questions:**

None

Priority: P1 · Topology: v1 (admin-churn phase) · Faults: admin churn, partition, thread pause
Confidence: high · Surfaced by: F8 Lifecycle
Evidence: properties/sub-disable-enable-cycle-loses-and-duplicates-nothing.md

### readonly-toggle-resumes-without-loss — readonly on/off cycles lose and duplicate nothing

| | |
|---|---|
| **Type** | Safety |
| **Property** | After any number of `spock.readonly` changes (`off -> all -> off/local`) on any node at random times relative to traffic and faults, once readonly returns to `off` everywhere every node ends with exactly one copy of each committed ledger row, exact delta counters, no unexpected exception rows and all subs enabled. |
| **Invariant** | Workload `Always` at quiescence after readonly windows end, using the shared ledger and delta oracles. Readonly=all windows stay shorter than slot WAL retention. SUT-side `Sometimes(in_remote_transaction, "apply loop stopped for readonly=all inside a remote transaction")` at the readonly `break`; `Reachable("apply idle timeout fired while readonly=all")`; `Reachable("readonly=all observed while xact_had_exception")`. |
| **Antithesis Angle** | Toggles landing between rows, just before 'C', during in-process exception replay, during table-sync catch-up and during add_node pauses, plus kills and partitions while a node is read-only. Under readonly=all the worker `break`s and stays connected, still sending feedback, so the provider's `wal_sender_timeout` is not hit; the chain is a mid-transaction stop with locks held, the `apply_idle_timeout` reconnect loop (fixed as connection-class only in `8dcfbcd5`), then resume and retransmit. The docs' "FATAL and exit" for `all` mode is stale. |
| **Why It Matters** | The documented maintenance procedure; docs promise resume "from where it left off". The idle-timeout classification was misfiled as a data error until four commits ago. |

**Open Questions:**

- Is a sync worker's COPY meant to be blocked by readonly=all? `(needs human input)`

Priority: P1 · Topology: v1 · Faults: readonly toggles (ALTER SYSTEM + reload), partition, node kill
Confidence: high · Surfaced by: F6 Security, F8 Lifecycle
Evidence: properties/readonly-toggle-resumes-without-loss.md
Evaluation note (2026-10-13): "no unexpected exception rows" means none outside the expected-exception registry. Any non-superuser DDL during readonly=local phases is kept out of this template until `readonly-local-keeps-inbound-ddl-flowing` is fixed.

### readonly-all-never-commits-remote-txn — No remote transaction commits while readonly=all is in effect

| | |
|---|---|
| **Type** | Safety |
| **Property** | While `spock.readonly = all` is in effect in an apply or sync worker, that worker never commits a replicated transaction or COPY. |
| **Invariant** | SUT-side `AlwaysOrUnreachable(spock_readonly != READONLY_ALL, "apply committed a remote transaction while spock.readonly=all")` before `CommitTransactionCommand()` in `handle_commit()`. The sync-worker COPY assertion is left out until the second open question is answered (a superuser DSN's COPY is exempt by design since e1aa238f). Workload cross-check: remote-origin ledger rows on that node stop growing after a settle time. `AlwaysOrUnreachable` because the point is reached with the value set only when a reload lands after the per-message check (the readonly FATAL in `replication_handler` is unreachable at HEAD). Companion `Sometimes("handle_commit reached with spock.readonly=all")` so a pass without evaluation is visible. |
| **Antithesis Angle** | A reload landing while the worker waits in `wait_for_previous_transaction` (called from `handle_commit`, `handle_sql`, `handle_relation`, after the per-message check). Without slot groups `required_commit_ts` is 0 and the function breaks out on its first check with no interrupt or config-reload call (`src/spock_apply.c:301-312`), so in v1 there is no wait and no window; it needs slot groups. Thread pauses widen the wait there. Initial sync on n4 and table-sync catch-up for the COPY side. |
| **Why It Matters** | Docs promise readonly=all stops apply (S8); operators use it to freeze a node before manual repair or an ACE comparison. One more inbound commit or queued DDL breaks that. |

**Open Questions:**

- Is committing the one remote transaction already in flight when the worker observes `all` acceptable? `(needs human input)`
- Is the sync worker's COPY (initial or table sync) meant to be blocked by readonly=all? `(needs human input)`

Priority: P2 · Topology: v2/slot-groups (unreachable in v1) · Faults: readonly toggles, thread pause
Confidence: medium with slot groups; not v1 coverage · Surfaced by: F6 Security, F8 Lifecycle
Evidence: properties/readonly-all-never-commits-remote-txn.md

### sub-drop-vs-table-sync-no-deadlock — sub_drop / sub_alter_sync never deadlock with a finishing table sync

| | |
|---|---|
| **Type** | Liveness |
| **Property** | `spock.sub_drop` (and `sub_alter_sync`) issued while a table sync of that subscription is finishing returns within a bound, and no backend waits on `SpockCtx->lock` indefinitely. |
| **Invariant** | Workload `Always("sub_drop returns within bound during table sync")` (client timer, ~60 s plus fault time). Workload `Always("no backend waits on spock context lock beyond bound")`: a `pg_stat_activity` sampler sees no pid with `wait_event='spock context lock'` unchanged across samples 30 s apart. SUT-side `Reachable("apply SYNCWAIT catalog update under SpockCtx lock")` before `set_table_sync_status` (`src/spock_apply.c:~4538`). |
| **Antithesis Angle** | Apply takes `SpockCtx->lock` EXCLUSIVE then updates the sync-status row (`src/spock_apply.c:4519-4550`); `sub_drop` deletes those rows uncommitted (`src/spock_functions.c:779`) then takes the same LWLock (`:808`). Nothing serialises them; the window is the whole drop transaction, and the sync worker's `w` write must commit before the drop's DELETE. Neither side can be cancelled and the deadlock detector cannot see it. Needs `sub_resync_table` then drop or `sub_alter_sync` of that subscription while it finishes; thread pausing widens the window. |
| **Why It Matters** | The LWLock variant freezes every applied row on the node (`handle_stats_counter` takes the lock per row), the manager, worker attach/detach and fast shutdown until a crash-restart. |

**Open Questions:**

- Is `sub_drop` (or `sub_alter_sync`) during an active table sync a supported operation? Docs do not forbid it. `(needs human input)`

Priority: P1 · Topology: v1 (admin-churn phase) · Faults: admin churn, thread pause
Confidence: medium (cycle confirmed in code; needs a specific admin interleaving) · Surfaced by: F2 Concurrency
Evidence: properties/sub-drop-vs-table-sync-no-deadlock.md
Evaluation note (2026-10-13): use a throwaway subscription with a dedicated table (dropping a mesh subscription during SYNCWAIT breaks the shared oracles) and loop resync-then-drop many times per timeline; no `SPOCK_RANDOM_DELAYS` site sits in the window. The sampler's wait event name `spock context lock` is confirmed (`src/spock_shmem.c:119`).

### apply-never-waits-on-dead-sync-worker — Apply worker never waits on a sync worker that already died

| | |
|---|---|
| **Type** | Liveness |
| **Property** | When a table-sync worker exits with an error during the SYNCWAIT/CATCHUP handoff, the apply worker notices and the subscription keeps replicating (the table ends READY or visibly FAILED). |
| **Invariant** | SUT-side `Unreachable("apply waits on sync worker that already exited with error")` in `wait_for_sync_status_change` when `spock_sync_find` returns a slot with `terminated_at != 0`; `Unreachable("sync worker missing at SYNCWAIT handoff")` before the `Assert` at `src/spock_apply.c:4532`. Workload `Always("subscription barrier completes after table resync")` within `apply_idle_timeout + restart_delay + margin` after faults stop; `Sometimes("table resync under faults reached ready or visible failure")`; `Always("retried table resync reaches READY after faults stop")` for tables left FAILED (gap-fill retry step). |
| **Antithesis Angle** | Partition or restart the provider during resync catch-up (sync workers in CATCHUP run `apply_work`, so a disconnect is an error exit), or SIGTERM a sync worker in catch-up (`proc_exit(1)`, same stall). The crashed slot keeps `worker_type=SYNC`, `spock_sync_find` ignores `terminated_at`, and nothing but same-database slot reuse or a SIGTERM to the apply worker ends the 60 s wait loop. Sync gone at SYNCWAIT trips a cassert `Assert` (node-wide crash-restart). The workload resyncs with the default `truncate := true` (`false` always fails on a populated PK table). |
| **Why It Matters** | The stuck apply worker reads nothing, so the whole subscription stops while `sub_show_status` says `replicating`. The non-cassert SYNCWAIT path leads to FAILED tables that apply skips silently. |

**Open Questions:**

- Is a FAILED table that apply silently skips (no exception_log row, shown as `unknown`) acceptable as long as `table_wait_for_sync` reports it? `(needs human input)`

Priority: P1 · Topology: v1 (admin-churn phase with table resyncs) · Faults: partition / provider restart during resync
Confidence: high (mechanism); medium (that the v1 workload does resyncs) · Surfaced by: F2 Concurrency
Evidence: properties/apply-never-waits-on-dead-sync-worker.md
Gap-fill note (2026-10-13): absorbs candidate `table-resync-under-faults-ends-ready` as a retry step. After faults stop, the workload re-runs `sub_resync_table` on every table left FAILED (up to k tries; tables stuck in `u`/`w` first need the apply worker restarted) and asserts `Always("retried table resync reaches READY after faults stop")`; those tables then rejoin the ledger checks instead of the node being skipped. Nothing blocks the retry in code (`sub_resync_table` accepts FAILED, `src/spock_functions.c:1306-1314`; slot and origin re-used through the `ensure_*` helpers). Also covers the `repset_add_table(..., synchronize_data := true)` entry path on a new single-writer table. `operator-recovery-steps-restore-replication` runs this step but does not assert it again.
Evaluation note (2026-10-13): resyncs target a dedicated single-writer table (`resync_<P>`, written only on P), so `truncate := true` loses nothing and CATCHUP still has work; the ledger, delta and convergence checks exclude it (Assumption 5).

### manager-kill-targets-only-listed-worker — Manager SIGTERMs only the worker slot it listed

| | |
|---|---|
| **Type** | Safety |
| **Property** | When the manager kills workers of disabled or dropped subscriptions, it kills only the apply worker it originally listed, never a new occupant of that shared-memory slot. |
| **Invariant** | SUT-side: record each listed slot's `generation` and `worker_type` in `manage_apply_workers` step 1; before `spock_worker_kill` in the final loop, `Always(generation unchanged && worker_type == APPLY, "manager kills only the apply worker slot it listed")`. Workload `Always("at most one apply worker per subscription")` from `pg_stat_activity`. `Sometimes("enabled subscription had its apply worker restarted after a kill")`. |
| **Antithesis Angle** | `manage_apply_workers` (`src/spock_manager.c:41-180`) keeps raw slot pointers after releasing `SpockCtx->lock`, then registers new workers via `find_empty_worker_slot`, which reuses terminated same-DB slots. A concurrent `start_sync_worker` can also take the slot. Needs an apply worker ERROR exit, then disable/drop of that sub while another sub is enabled or a resync starts. SIGKILL does not reach it. |
| **Why It Matters** | A just-started apply worker is killed (a restart blip), or a sync worker is SIGTERMed. A sync worker ignores SIGTERM until COPY ends and then skips catch-up (the consequence is owned by `sync-worker-sigterm-never-skips-catchup`: silent drift on non-cassert, node crash-restart on cassert), or it error-exits and stalls apply (`apply-never-waits-on-dead-sync-worker`). Five prior fixes in this pattern. |

**Open Questions:**

None

Priority: P1 · Topology: v1 (admin-churn phase) · Faults: partition (worker error exit) + admin churn
Priority note: raised from P2: the cross-process variant can cause silent drift (sync worker skips catch-up after SIGTERM), not just a FAILED table.
Confidence: medium (both variants confirmed by code reading; not run) · Surfaced by: F2 Concurrency
Evidence: properties/manager-kill-targets-only-listed-worker.md
Gap-fill correction (2026-10-13): the evidence note "fast shutdown does not reach step 4" holds only for a SIGTERM during COPY. During SYNCWAIT there is no COPY backend, so fast shutdown **can** make a sync worker skip catch-up; that consequence is now `sync-worker-sigterm-never-skips-catchup`, and this property is one of its causes.

### resource-dat-dumps-serialized — resource.dat is written by one process at a time

| | |
|---|---|
| **Type** | Safety |
| **Property** | `spock_group_resource_dump` never runs in two processes at once, so `resource.dat` is never renamed while half written and a dump never fails after its COPY committed. |
| **Invariant** | SUT-side atomic "dumpers inside" counter: `Always(count_after_increment == 1, "resource.dat dump has a single writer")`. `Unreachable("resource.dat temp rename failed")` at `src/spock_group.c:606`. `Unreachable("resource.dat short read at startup")` in `spock_group_resource_load`. |
| **Antithesis Angle** | One fixed temp name with `O_TRUNC`, lock held only SHARED (`src/spock_group.c:534-611`). Callers: supervisor exit, every COPY finish (`src/spock_sync.c:1309`), add_node force-set. Two resyncs finishing together on one node, or shutdown during a resync, give two writers; node termination right after turns a short file into a postmaster that will not start. |
| **Why It Matters** | `resource.dat` is a startup seed (origins are authoritative; a missing or mismatched file is tolerated), so a startup ERROR on a short file (FATAL in the postmaster) is a bug either way: the node cannot restart without manual file removal. Interleaved writers can also leave duplicate keys, which trip `Assert(!ret)` at load on a cassert postmaster. A rename failure during add_node initial sync leaves status `d` and the subscription disabled; one after a resync COPY drops its slot and origin and leaves the table FAILED. No CRC on the file. |

**Open Questions:**

- How often do two dumps on one node overlap? One sync worker per subscription, so overlap needs concurrent resyncs on different subscriptions of one node. `(partial: reachable by design with two concurrent resyncs on different subscriptions of one node; frequency unmeasured)`
- Does Antithesis node termination drop unfsynced writes (page cache)? If it keeps them, a short file and fsync-ordering mistakes are reachable only when the dumping process itself is killed mid-write. `(partial: docs say a restarted node may lose modified data or boot fresh from its image; page-cache behaviour not stated; ask the Antithesis contact)`

Priority: P1 · Topology: v1 (admin-churn phase with concurrent resyncs) · Faults: concurrent resyncs, node kill, graceful stop
Priority note: raised from P2 in evaluation: two writers to one fixed temp file plus a kill right after is a race plus crash timing that TAP cannot place, and the outcome is a node that will not restart without manual file removal. Conditional on the admin-churn phase running concurrent resyncs on two subscriptions of one node (throwaway subscriptions with their own tables).
Confidence: medium · Surfaced by: F2 Concurrency
Evidence: properties/resource-dat-dumps-serialized.md

### fast-shutdown-completes-within-bound — Fast shutdown finishes within a bound

| | |
|---|---|
| **Type** | Liveness |
| **Property** | `pg_ctl stop -m fast` on any node returns within `wal_sender_timeout + 60 s` and leaves no processes from the old postmaster. |
| **Invariant** | Workload `Always` on each graceful stop: the postmaster exits within `wal_sender_timeout + 60 s` (run `pg_ctl stop -m fast -t <bound>` or poll for the postmaster PID; `pg_ctl`'s own 60 s wait is not the bound) and no processes from the old postmaster remain. A stop held up to `wal_sender_timeout` by a paused or partitioned peer is core walsender behaviour and inside the bound. The harness keeps `wal_sender_timeout` non-zero. |
| **Antithesis Angle** | Spock's SIGTERM handler only sets a flag, so exit depends on every worker reaching a check: lock waits, LWLock cycles (L11) and blocking libpq can hold shutdown. pg_dump/pg_restore children do get SIGTERM at postmaster shutdown (process-group kill), so add_node's pg_dump is coverage here, not a suspected hang. Stops issued while syncs finish, `sub_drop` runs, providers are paused and apply waits on local row locks. |
| **Why It Matters** | A stuck shutdown blocks upgrades, failover scripts and container restarts; L11 would make it permanent. |

**Open Questions:**

None

Priority: P2 · Topology: v1 · Faults: graceful stop (test command), pause, admin churn
Confidence: medium · Surfaced by: F8 Lifecycle
Evidence: properties/fast-shutdown-completes-within-bound.md
Evaluation note (2026-10-13): runs as a test command inside the node container (`pg_ctl stop -m fast -t <bound>`); "no processes from the old postmaster remain" needs `ps` in the node image. The node wrapper restarts postgres afterwards.

### sync-worker-sigterm-never-skips-catchup — A SIGTERMed table-sync worker never marks its table done without catch-up

| | |
|---|---|
| **Type** | Safety |
| **Property** | A table-sync worker that receives SIGTERM before reaching catch-up never marks its table SYNCDONE without applying the changes the apply worker skipped for that table. |
| **Invariant** | SUT-side `Unreachable("sync worker left SYNCWAIT without reaching CATCHUP")` in `spock_sync_main` (`src/spock_sync.c:2039-2042`) when `wait_for_sync_status_change` returns false, placed before the `Assert(lsn == status_lsn)` so it fires on cassert and non-cassert builds. Workload marker `Sometimes("graceful stop or worker terminate issued while a table sync was in SYNCWAIT")`. Outcome is caught by `committed-ledger-row-reaches-every-node` when resyncs target ledger tables, and by the resync table's single-writer check otherwise. |
| **Antithesis Angle** | Sync workers only set a flag on SIGTERM. A SIGTERM during COPY or SYNCWAIT makes the wait return at once with an invalid LSN; on non-cassert the worker then marks the table SYNCDONE at its COPY LSN, while the apply worker has already skipped the table's later changes. Fast shutdown reaches it during SYNCWAIT (postmaster SIGTERMs bgworkers; commits still work), as do `pg_terminate_backend` and the manager's misdirected kill. SYNCWAIT is long while the apply worker is busy, lock-blocked, paused, disconnected, or its subscription is disabled. |
| **Why It Matters** | Non-cassert builds lose the table's changes permanently with no exception row, and the table shows `replicating`; cassert builds crash the node during shutdown and leave the table FAILED. A routine restart during a resync is enough. |

**Open Questions:**

- Is a fast shutdown during a table resync supported without data loss, or must operators re-run resyncs after restarts? `(needs human input)`
- On SIGTERM in SYNCWAIT, should the worker exit with an error (table goes FAILED, visible) or keep `w` and resume after restart? Affects the fix only.

Priority: P1 · Topology: v1 (admin-churn phase with table resyncs plus graceful stops) · Faults: graceful stop (test command) during resync, worker terminate, admin churn (sub_disable during resync)
Confidence: high (mechanism code-checked on both builds; not run); medium that v1 runs resyncs · Surfaced by: Evaluation gap b (investigation candidate G7)
Evidence: properties/sync-worker-sigterm-never-skips-catchup.md
Dominance: `manager-kill-targets-only-listed-worker` is one cause (misdirected SIGTERM); fast shutdown and `pg_terminate_backend` are the others.

---

## Category H — Recovery and progress (liveness)

After faults stop, replication must come back by itself within a bound.
These run in quiet periods after a fault phase.

### crashed-node-returns-to-streaming — A crashed node streams again within a bound

| | |
|---|---|
| **Type** | Liveness |
| **Property** | After a node is killed and faults stop, within a fixed bound it accepts connections and every subscription into and out of it passes a fresh sync_event barrier. |
| **Invariant** | Workload `Always("crashed node streams again within bound")` per restarted node per quiet period. SUT-side `Reachable("spock supervisor started after crash recovery")`, `Unreachable("resource.dat load failed")` at the ERROR sites in `spock_group_resource_load`, `Sometimes(reconcile result == STALE)`. |
| **Antithesis Angle** | Kills at random points, including during apply, sync, add_node, and soon after a previous restart. Exercises redo (node-id origin states needing free slots), `resource.dat` load in the postmaster (no CRC, ERROR stops startup), the supervisor's 5 s static restart and rebuild of dynamic workers, reconcile + 1M-xid `pg_commit_ts` scan, a slot still held by the old walsender (short for an in-container crash-restart, up to `wal_sender_timeout` for a container kill), and crash loops from Asserts that fire again on resent input. A restarted container may change IP, so DSNs use hostnames. |
| **Why It Matters** | Any of these steps failing leaves a node down or crash-looping after an ordinary power loss. |

**Open Questions:**

- What recovery bound does the team expect? `(needs human input)`
- Is a node that fails to start on a full replication-state array a Spock bug or a sizing error? `(partial: extra states come from L1's node-id origin states, which sizing.md does not budget and SQL cannot drop; steady 3-node mesh fits in 10, node churn accumulates them; harness should use the documented value)`
- Does Antithesis node termination keep fsynced PGDATA writes, and does it drop unfsynced ones (page cache)? `(needs human input)`

Priority: P1 · Topology: v1 · Faults: node kill
Confidence: medium · Surfaced by: F3 Failure Recovery
Evidence: properties/crashed-node-returns-to-streaming.md
Evaluation note (2026-10-13): Antithesis may restart a node fresh from its image. The node wrapper keeps a boot counter and last-exit kind outside PGDATA, and the workload compares `pg_control_system().system_identifier` across checks; a fresh boot is reported with `Sometimes` and skipped, not asserted. With `max_active_replication_origins = 32` in the main configuration a full state array is not expected here; the small-capacity case belongs to `v2/small-capacity`.

### mesh-barriers-complete-after-partition-heal — Every ordered pair recovers after partitions heal

| | |
|---|---|
| **Type** | Liveness |
| **Property** | After any mix of subset partitions, one-way loss and node pauses, once faults stop, `spock.sync_event()` on every node P is reached on every other member S within a fixed bound. |
| **Invariant** | In an `eventually_`/`finally_` test command, per ordered pair `CALL spock.wait_for_sync_event(NULL, P, lsn, bound, false)`; `Always(result, "sync barrier P->S completes within bound after faults heal")`. Bound = `wal_sender_timeout` (60 s in the harness) `+ apply_idle_timeout + restart_delay_default + connect_timeout + catch-up margin`. Clock skips continue during quiet periods, so a `false` from the wall-clock wait before the workload's monotonic deadline waits again, and a pair that misses the deadline gets one 5 s re-check before it is scored. |
| **Antithesis Angle** | Partitions that cut one pair while both still reach the third node, one-way loss (old walsender keeps the slot active until `wal_sender_timeout`), silent drops with data in flight (only `apply_idle_timeout` notices), provider pauses. A default mesh does not relay through the third node. |
| **Why It Matters** | Users are told to wait for connectivity to return; a pair that never resumes is silent while `sub_show_status` says `replicating`. It is also the gate for every data check after a fault phase. |

**Open Questions:** none. Resolved 2026-10-14: the recovery bound is 5 minutes from when faults stop (the team's choice; it matches the derived worst case of about 215 s plus catch-up).

Priority: P1 · Topology: v1 · Faults: partition, one-way loss, pause
Confidence: medium · Surfaced by: F7 Distributed
Evidence: properties/mesh-barriers-complete-after-partition-heal.md
Evaluation note (2026-10-13): with `wal_sender_timeout = 60s` and `spock.apply_idle_timeout = 120s` (raised from about 30 s so an idle link is not cut between walsender keepalives, which come about every `wal_sender_timeout / 2`), the bound is about 60 + 120 + 5 + 30 s plus catch-up margin, roughly 4-5 minutes per quiet period.
Implemented (2026-10-14): `test/v1/main/eventually_mesh_barriers.py`, one `Always("sync barrier P->S completes within 5 minutes after faults stop")` evaluated per ordered pair (deadline on the workload's monotonic clock; a `false` from the wall-clock wait before the deadline waits again). Details carry each pair's backlog bytes when faults stopped. Writers cap payload at 25 MB per run so catch-up fits the bound. Reach claims: a slot inactive on its provider when faults stopped, every pair checked (no disabled subscription skipped), a barrier needing more than 30 s. Load from `parallel_driver_write_ledger.py` (swarmed writer nodes; since 2026-10-15 about 15% of transactions are large). Before taking sync events the command terminates leftover writer sessions (`pg_terminate_backend`; a backend already committing finishes, one without COMMIT rolls back) and waits up to 10 s for them to go, so no ledger commit lands after the barrier LSN. Not yet: n4 pairs (no add_node template), a mid-run check with `ANTITHESIS_STOP_FAULTS`.

### apply-worker-restarted-within-bound-after-exit — A dead apply worker comes back within a bound

| | |
|---|---|
| **Type** | Liveness |
| **Property** | After any apply-worker exit for an enabled subscription with a reachable provider, a new worker is running and `replicating` within `restart_delay_default + connect_timeout + margin`. |
| **Invariant** | Workload `Always` in a quiet period: the gap between "no worker / not replicating" and "worker present and replicating" is within the bound. Clock skips are not stopped by quiet periods, so the workload compares a monotonic clock with wall time across the window and skips or scopes the check after a jump. SUT-side `Sometimes("manager deferred apply restart by more than twice restart_delay")`; `Reachable("manager restarted crashed apply worker")`, `Reachable("manager restarted cleanly exited apply worker")` and `Reachable("manager exited before attach")` in `wait_for_worker_startup`'s "exited prematurely" branch. |
| **Antithesis Angle** | Restart time is `terminated_at + restart_delay` on wall clock; a backward clock step after an exit defers the restart by about the step (L22; PG core does the same for its own bgworkers). Bgworker exit notification is reliable after attach, and clean exits are restarted at once. The remaining gap: a manager that dies before `spock_worker_attach` never sets `subscriptions_changed`, so that database has no manager until another change. Admin calls holding the local-node lock stall the manager. |
| **Why It Matters** | Spock claims workers are restarted (V2). A sub that stays down silently grows lag and pins WAL on the provider. |

**Open Questions:**

- Is a restart delayed by the size of a backward clock step acceptable? `(needs human input)`

Priority: P2 · Topology: v1 · Faults: worker exit, clock step backward
Confidence: medium · Surfaced by: F8 Lifecycle
Evidence: properties/apply-worker-restarted-within-bound-after-exit.md

### sub-show-status-reflects-apply-state — sub_show_status "replicating" is truthful within a bound

| | |
|---|---|
| **Type** | Safety |
| **Property** | `sub_show_status()` does not keep reporting `replicating` for a subscription whose provider has unapplied changes for it beyond the documented detection bound, and reports `disabled` once a subscription has been disabled for longer than the worker exit delay. |
| **Invariant** | Workload `Always`: during a barrier wait with timeout B (B > `apply_idle_timeout + restart_delay_default + connect_timeout + margin`), if the barrier times out, not every status sample may have been `replicating`. Second message: `sub_enabled = false` in two samples at least `restart_delay_default + 5 s` apart implies the later status is `disabled`. |
| **Antithesis Angle** | Faults that leave the worker alive but stuck: silent partitions, SIGSTOP of the provider, a sync worker that died in CATCHUP (L12), pauses (L4), blocking libpq calls. The status comes only from "worker has a proc" plus the sub-level sync row. |
| **Why It Matters** | Docs say `replicating` means "changes from the provider are being applied normally" (a gloss written from the C source, 84edbd74); ZODAN and operators gate on it. A FAILED table is table-scoped by design (6a063b22) and is out of this property; `sub_show_table` printing `unknown` for `p`/`f` is a separate display gap. |

**Open Questions:**

- Is `replicating` meant to mean "worker exists and initial sync done" (code) or "changes are being applied" (docs)? `(needs human input)`

Priority: P2 · Topology: v1 · Faults: silent partition, pause
Confidence: medium (mismatch certain from code; bug status depends on intent) · Surfaced by: F4 Protocol
Evidence: properties/sub-show-status-reflects-apply-state.md

### operator-recovery-steps-restore-replication — Documented recovery steps bring replication back

| | |
|---|---|
| **Type** | Liveness |
| **Property** | When faults are off, each documented operator step taken on a visible failure restores replication within a bound: `sub_enable` on a disabled subscription, drop and re-create after an interrupted initial sync, `remove_node` plus retry after a failed add_node (and `sub_resync_table` on a FAILED table, asserted by `apply-never-waits-on-dead-sync-worker`). |
| **Invariant** | Workload `Always(bounded)`, one message per step: "operator recovery: re-enabled subscription replicates again within bound", "... re-created subscription after interrupted initial sync replicates within bound", "... add_node retry after cleanup succeeds". `Sometimes("operator recovery: <step> ran and the next strict round passed")` per step, including the resync step. Steps also run during fault phases but are scored only with faults off. `Always` because a documented recovery that does not recover with faults off is a failure each time. |
| **Antithesis Angle** | Faults create the visible failures (kills and partitions during table sync, initial sync, add_node; admin churn); the strict round and requested quiet periods then test that the recovery path works on the state those faults left: stale SYNC worker slots (L12), sync workers ignoring SIGTERM until COPY ends (G7), ZODAN leftovers (L20), stale progress rows on re-add. |
| **Why It Matters** | Spock relies on operators for these recoveries and the catalog treats "visible failure" as a pass. If the documented step does not work, a visible failure is in practice permanent. |

**Open Questions:**

- Is drop and re-create the intended recovery for a subscription whose initial sync stopped in `s`/`d`/`c`? `sub_enable` re-disables it and the docs give no step.
- Should v1 run `sub_resync_table` during fault phases? (Catalog-wide open question; this property needs it at least in the final round.)
- What bound does the team accept for each step? (Same as `mesh-barriers-complete-after-partition-heal`.)

Priority: P1 · Topology: v1 · Faults: kill / partition during table sync, initial sync and add_node; admin churn
Confidence: medium (steps from docs and code; bounds are harness choices) · Surfaced by: Evaluation gap a
Evidence: properties/operator-recovery-steps-restore-replication.md
Merge note (2026-10-13): gap (a) and gap (b) both proposed absorbing candidate G1 (`table-resync-under-faults-ends-ready`). The resync retry assertion lives in `apply-never-waits-on-dead-sync-worker`; this property runs the step and counts it, without asserting it twice.

### quiet-link-never-hits-idle-timeout — Links with no fault never take the idle-timeout reconnect

| | |
|---|---|
| **Type** | Safety |
| **Property** | On a link whose two nodes and network had no fault, and with no wall-clock jump, the apply worker never raises the `spock.apply_idle_timeout` "no data received" error. |
| **Invariant** | Workload `Unreachable("apply worker hit the idle timeout on a link with no fault and no clock jump")`, from a log scan (or apply-worker restart count) over windows that start `apply_idle_timeout` seconds into each quiet period and drop any window with a detected clock jump. Companion `Sometimes("transaction of at least N changes applied on every peer")` so long replays run. |
| **Antithesis Angle** | Faults before the quiet period leave reconnect states that must recover; the window checks that steady state is reached and stays quiet. The provider only pings every `wal_sender_timeout / 2` on an idle link (`walsender.c:4117-4146`), and long decodes keep that cadence via `update_progress_txn` (`reorderbuffer.c:2598-2602`), so any config with `apply_idle_timeout` at or below that churns forever, and long replays can be cut off and restarted. |
| **Why It Matters** | Reconnect churn re-decodes from `restart_lsn` and inflates every liveness bound. The harness timeouts (`wal_sender_timeout = 60s`, `apply_idle_timeout = 120s`, and 5 min / 300 s in the documented-defaults variant) meet the rule `apply_idle_timeout >= wal_sender_timeout / 2 + 30 s`, so this should pass; Spock does not warn about a bad combination. |

**Open Questions:**

- Should Spock reject or warn when `apply_idle_timeout <= wal_sender_timeout / 2`, or send its own periodic status message? `(needs human input)`
- Can a subscriber slow to drain buffered data reply to a keepalive later than `wal_sender_timeout`, so the walsender cuts a large transaction off every time under CPU throttling? Not traced.

Priority: P3 · Topology: v1 and the documented-defaults variant · Faults: faults off in the checked windows; clock jumps detected and excluded
Confidence: high for the cadence (stock walsender code read); medium that nothing else stalls messages · Surfaced by: Evaluation gap c
Evidence: properties/quiet-link-never-hits-idle-timeout.md
Priority note: lowered from P2 in the second pass: the gap-c draft assumed a 30 s idle timeout; the topology already uses 60 s / 120 s (checked consistent on 2026-10-13), so this is a guard, not a known failure.

---

## Category I — Resource leaks and fixed capacity

Fixed-size shared tables that only grow (exception-log slots, the progress
hash, replication-origin states), and things that outlive their owner (slots,
temp files, connections). Capacity checks need churn under fresh names and
run in their own `v2/small-capacity` configuration (`max_worker_processes`
~10, `max_active_replication_origins` 10, node kills off because restarts
reset some of these tables); counting routes are cheaper in TAP and should be
confirmed there first. Leftover checks run after a long quiet period and
documented cleanup.

### exception-log-slots-never-exhausted — Exception-log slots are never used up by dropped subscriptions

| | |
|---|---|
| **Type** | Safety |
| **Property** | While a node has fewer live subscriptions than `max_worker_processes`, an apply or sync worker never fails to find an exception-log slot, and an ERROR in `handle_begin` never leaves `SpockCtx->lock` held or writes outside the slot array. |
| **Invariant** | SUT-side `Unreachable("exception log slot table full")` before `elog(ERROR, "unable to find an empty exception log slot")` (`src/spock_apply.c:~788`) when the locked rescan did not find its own name; separate `Unreachable("exception log claim raised no-free-slot although own entry was found")` at the same line for the claim race. SUT-side `AlwaysOrUnreachable(my_exception_log_index >= 0, "exception marker index valid in PG_CATCH")` before the `initial_error_message` write (`:~4074`) and `AlwaysOrUnreachable(!LWLockHeldByMe(SpockCtx->lock), "apply PG_CATCH does not keep SpockCtx->lock")` at the end of the first-error branch. Workload liveness: every pair passes a barrier after each churn cycle. |
| **Antithesis Angle** | Two routes. Churn: slots are claimed per subscription name and never freed (`TODO ... Memory leak`, `:797-806`); only a postmaster restart clears them. Race, below capacity: the "no free slot" check runs before the locked rescan's own-name result is used, so an apply worker and a table-sync worker of the same subscription taking their first BEGIN together (e.g. `sub_resync_table` right after a node restart) raise it with free entries left. No transaction is open at `handle_begin`, so the ERROR keeps `SpockCtx->lock` EXCLUSIVE and the node hangs. On the capacity route `PG_CATCH` also writes `exception_log_ptr[-1]` out of bounds (about 70-100 bytes of message plus 4 bytes, most likely into unused worker slots). |
| **Why It Matters** | Adding and removing nodes with new names about `max_worker_processes` times without a restart, or one unlucky resync, turns into a whole-node replication stop that cannot be interrupted. Lead L14. |

**Open Questions:**

- Apply and sync workers of one subscription share one entry; does overwriting/clearing each other's `commit_lsn` break restart classification? `(partial: overwrite and clear confirmed in code; effect on the classifier not traced)`

Priority: P1 · Topology: v1 (race route); v2/small-capacity with node kills off (capacity route) · Faults: table resyncs right after a restart (race); fresh-name subscription churn (capacity)
Confidence: high (mechanism); medium (reachability within one run) · Surfaced by: F5 Resources
Evidence: properties/exception-log-slots-never-exhausted.md
Evaluation note (2026-10-13): slots are claimed per subscription name, so the capacity route uses throwaway subscriptions with fresh names (`sub_create`, one write, wait, `sub_drop`) about `max_worker_processes` times on one node without a restart, not ZODAN node churn; a TAP loop reaches it faster, so confirm there first. The race route (apply and sync workers of one subscription claiming at their first BEGIN together, below capacity) is real timing and stays in v1; it may become its own property (gap-fill decision).

### progress-hash-capacity-survives-node-churn — The progress hash never fills with entries for removed nodes

| | |
|---|---|
| **Type** | Safety |
| **Property** | While the number of live (local, remote) node pairs is below `max_worker_processes`, inserting into `SpockGroupHash` (`spock.progress`) never fails. |
| **Invariant** | SUT-side `Unreachable` at each of the five insert sites, one message each ("spock progress hash full at sub_create / apply attach / apply reconcile / resource load / force-set"; the reconcile site is `spock_progress_recovery.c:173`). Implement as a count check before each insert rather than switching to `HASH_ENTER_NULL`, which would change what the shipped code does on a full table; on a full shared table PG18 `HASH_ENTER` raises "out of shared memory" and never returns NULL, so today's `entry == NULL` branches are dead. Workload `Sometimes(progress rows > live pairs + 2, "progress hash holds stale entries")`. |
| **Antithesis Angle** | Entries are never deleted (`src/spock_group.c:41-42`) and are dumped to `resource.dat` and reloaded on every start, so kills do not reset it. Fresh-name churn adds one entry per cycle per existing node. |
| **Why It Matters** | A long-lived cluster that rotated nodes can no longer add subscriptions, or loses one after a restart (class 53, retried every 5 s forever), with a misleading error. Lead L16. |

**Open Questions:**

- Is never-delete (for pointer stability) meant to also accept growth with node churn, and is the fix delete-when-`nattached`=0 or bigger sizing? `(needs human input)`

Priority: P2 · Topology: v2/small-capacity (fresh-name node churn; confirm with a TAP loop first) · Faults: node churn
Confidence: high (mechanism); medium (reach within a run) · Surfaced by: F5 Resources
Evidence: properties/progress-hash-capacity-survives-node-churn.md
Evaluation note (2026-10-13): the hash is keyed by (dbid, node_id, remote_node_id), so only fresh node names grow it; subscription churn does not. Reaching about `max_worker_processes` ZODAN cycles in one Antithesis run is slow, so a TAP loop is the cheaper first check.

### replication-origin-states-do-not-leak — Replication-origin states do not pile up until no free state remains

| | |
|---|---|
| **Type** | Safety |
| **Property** | Each node's replication-origin states are only those its live subscriptions and in-flight table syncs need; "could not find free replication state slot" never occurs. |
| **Invariant** | Workload log scan `Unreachable("replication origin state table full")` on `could not find free replication state` in any process. After quiescence, `Always("no orphan named origins")`: every `spk_%` origin matches a live `sub_slot_name` or a table-sync slot of a table not yet READY/FAILED. (The "no unnamed origin states" check belongs to `crash-redo-leaves-no-node-id-origin-state`.) |
| **Antithesis Angle** | Three sources: (1) crash redo creating node-id states (L1, confirmed by code reading on PG18); (2) a table sync that errors during COPY or is killed after its origin advanced, later marked FAILED, whose cleanup drops the remote slot but not the local origin (`src/spock_sync.c:1459-1466`); (3) `sub_drop`/`remove_node` dropping only the subscription's own origin: the manager kills only apply workers, so the sync worker fails at its next status write and leaves its origin and slot (in SYNCWAIT, `Assert(lsn == status_lsn)` at `spock_sync.c:2042` crash-restarts a cassert node). |
| **Why It Matters** | PG18's default limit is 10, and `docs/sizing.md` sets origins equal to `max_replication_slots`, counting no redo-created or orphaned states. Filling it stops subscriptions (class 53, retried forever), stops `sub_create`, and if hit during redo prevents the node from starting. |

**Open Questions:**

- Commit records stamped with the node id are deliberate (conflict detection uses them). Is the resulting persistent node-id origin state after crash redo accepted? `(needs human input)`
- Should `spock_sync_worker_cleanup` drop the table-sync origin by name whatever the session state is (no reason found to keep it)? `(needs human input)`

Priority: P2 · Topology: v1 (capacity part: `v2/small-capacity`) · Faults: node kill between checkpoints, kills/partitions during resync
Confidence: medium · Surfaced by: F5 Resources
Evidence: properties/replication-origin-states-do-not-leak.md
Evaluation note (2026-10-13): the log scan reads server logs through `logging_collector` and `pg_read_file`. In the main configuration (`max_active_replication_origins = 32`) the "state table full" message is not expected; the capacity route belongs to `v2/small-capacity`.

### no-orphan-slot-pins-wal-after-quiesce — No Spock slot pins WAL without a consumer

| | |
|---|---|
| **Type** | Safety |
| **Property** | After quiescence and documented cleanup, every `spock_output` logical slot belongs to a live subscription (or an in-progress table sync of a live subscription) and has confirmed past a marker LSN taken after quiescence began. |
| **Invariant** | Workload `Always(orphan_spock_slots == 0, "no spock slot without owning subscription after quiesce")` and `Always(lagging_owned_slots == 0, "every owned spock slot confirms past the quiesce marker")`, plus `Sometimes("sub_drop could not reach provider")` from the log (the workload then drops those slots as the warning tells it to). |
| **Antithesis Angle** | Orphans come from `sub_drop` with the provider unreachable (warned), `sub_drop` during a table resync (sync slot left, not warned, L28), SIGKILL during initial sync (cleanup runs only on ERROR, L13), and orchestrator death during add_node (L20). |
| **Why It Matters** | An ownerless slot keeps WAL forever: the project expects unlimited retention (the upgrade test requires `max_slot_wal_keep_size = -1`), so the provider's disk eventually fills and it stops. A table-sync slot left by `sub_drop` goes against the docs ("removes all associated metadata") and is a defect, not an expected leftover. |

**Open Questions:**

None

Priority: P1 · Topology: v1 · Faults: partition during sub_drop/remove_node, kills during sync and add_node
Confidence: high (paths code-checked); medium (whether each is classed as a bug) · Surfaced by: F5 Resources
Evidence: properties/no-orphan-slot-pins-wal-after-quiesce.md

### replay-spill-file-lifecycle — Replay spill files live only as long as their transaction

| | |
|---|---|
| **Type** | Safety |
| **Property** | Apply-worker spill files exist only while their remote transaction is in progress; after quiescence none remain, and spilled entries read back without reporting corruption. |
| **Invariant** | Workload `Always(n == 0, "no apply-worker temp files after quiesce")` via `pg_ls_tmpdir()` joined to Spock worker PIDs (`backend_type` like `spock apply%` or `spock sync%`). SUT-side `Unreachable("corrupt replay spill file")` at the header and body read checks (`src/spock_apply.c:4894, 4908`; two messages). `Reachable("replay queue spilled to disk")` (`:5051`) and `Reachable("replay read back a spilled entry")` (`:4922`). |
| **Antithesis Angle** | Every remote transaction over `exception_replay_queue_size` (4 MB) spills on every subscriber. Faults during a large transaction and a real data error that forces read-back explore reset, exit and replay ordering. A live worker cannot keep a spill file past its transaction (every way out of the loop ends the process or replays the same transaction). Disk-full / `temp_file_limit` becomes class 53, retried forever by design (code comment; the docs and a release note say otherwise). |
| **Why It Matters** | New code "until spill-to-disk code is proven stable", with a past use-after-free (`f84b853d`). Leaked files use disk; a false "corrupt" read is XX000 and under SUB_DISABLE disables the subscription. Lead L29. |

**Open Questions:**

None

Priority: P2 · Topology: v1 · Faults: partition / worker exit during large transactions, data errors
Confidence: medium · Surfaced by: F5 Resources
Evidence: properties/replay-spill-file-lifecycle.md

### spock-connections-match-subscriptions-after-quiesce — Provider connections match enabled subscriptions after quiescence

| | |
|---|---|
| **Type** | Safety |
| **Property** | After quiescence, each provider has exactly one Spock walsender per enabled subscription to it (plus one per in-progress table sync) and no leftover short-lived Spock helper sessions. |
| **Invariant** | Workload `Always(extra_walsenders == 0, "spock walsenders match enabled subscriptions after quiesce")` and `Always(stray_sessions == 0, "no leftover spock helper sessions after quiesce")`: `pg_stat_activity` client backends and walsenders whose `application_name` ends in a short-lived suffix (`_create`, `_cleanup`, `_sync`, `_snap`, `_copy`, `_copy_slot`, `_catchup`; matched on the suffix only, since long names are hashed), minus sessions of a table sync still in progress. The workload closes its own admin sessions before the check, so what remains has no live owner. |
| **Antithesis Angle** | Connections are named `<sub>_<purpose>`. `sub_create` and `sub_drop` do not `PQfinish` on ERROR, so the leak lives as long as the calling session; confirmed triggers are "not a spock node" on a healthy connection and "remote slot drop failed" while the slot is still active (which also orphans the slot). Sync workers outlive `sub_drop`; the sync cleanup loop holds a connection with no time limit. Partitions and RSTs during admin calls explore it. |
| **Why It Matters** | Leaked or stuck sessions use up provider `max_connections` / `max_wal_senders` and keep slots active, so a returning subscriber cannot attach. |

**Open Questions:**

- Is a PGconn leaked in the calling session by a failed `sub_create`/`sub_alter_sync`/`sub_drop` a bug? `(needs human input)`

Priority: P2 · Topology: v1 · Faults: partition during admin calls, provider pause
Confidence: medium · Surfaced by: F5 Resources
Evidence: properties/spock-connections-match-subscriptions-after-quiesce.md

### apply-stale-socket-never-polled — The apply worker never waits on a closed libpq socket

| | |
|---|---|
| **Type** | Safety |
| **Property** | No Spock worker ever waits on a socket that libpq has already closed. |
| **Invariant** | Workload log scan `Unreachable("spock worker epoll_ctl failure")` on `epoll_ctl() failed` from Spock workers. SUT-side `Always(fd == PQsocket(applyconn), "apply waits on live libpq socket")` and `Always(PQstatus(applyconn) != CONNECTION_BAD, "apply waits on a connected libpq handle")` before the only `WaitLatchOrSocket` (`src/spock_apply.c:3492`). `Reachable("apply detected dead connection at stream_replay")`. |
| **Antithesis Angle** | Regression for `4dfe7496`/`d286f3df`: connection death during in-process replay left a stale fd; a closed fd number is soon reused by the spill file or relation files. Walsender kills and RSTs while the subscriber replays a failed, spilling transaction recreate the timing; TAP 101/102 are in no schedule. |
| **Why It Matters** | The original bug caused silent data loss under ordinary connection drops. Cheap tripwire. |

**Open Questions:**

- Does the failover-slots worker (PG<18, out of first scope) wait on a cached socket? Not checked.

Priority: P2 · Topology: v1 · Faults: walsender kill / connection reset during replay
Confidence: high (regression target); low (expectation of new findings) · Surfaced by: F5 Resources
Evidence: properties/apply-stale-socket-never-polled.md

### apply-worker-memory-bounded — Apply worker memory does not grow with transactions applied

| | |
|---|---|
| **Type** | Safety |
| **Property** | Under sustained load, faults and in-process replays, an apply worker's process-lifetime memory stays below a fixed bound that does not grow with the number of transactions applied. |
| **Invariant** | SUT-side `AlwaysOrUnreachable(MemoryContextMemAllocated(TopMemoryContext, true) < 256 MB, "apply worker memory stays bounded")` in `handle_commit` (rate-limited); SUT-side `AlwaysOrUnreachable(len(sync_replica_lsn) < bound, "sync-standby hold list bounded")` in `append_feedback_position`. Workload backup `Always(rss_growth_kb < 500000, "apply worker RSS growth bounded")` per PID. `AlwaysOrUnreachable` because a short run may not push enough through one worker. |
| **Antithesis Angle** | The sync-standby hold list gets one `TopMemoryContext` entry (about 64 bytes) per applied transaction while the standby lags, so about 4M transactions reach 256 MB; feedback walks it in full under `SyncRepLock` EXCLUSIVE on every keepalive or batch (`src/spock_apply.c:3147-3236`). Spilled replay entries leak one message per caught exception. Long runs and many data errors on large transactions. The RSS check needs a small `shared_buffers`. |
| **Why It Matters** | Past leak `4cb409cb` reached about 800 MB at 200k rows. An unbounded list under a global lock also slows every committing backend. |

**Open Questions:**

- Is the sync-standby hold list (a failover-safety feature, #491) meant to grow with no limit while the standby is down? `(needs human input)`
- What memory bound would the team accept for an apply worker? `(partial: TAP 022 accepts TopTransactionContext < 5 MB during exception replay and RSS growth < 500 MB, noting a legitimate ~270 MB RSS peak; no in-process bound is stated)`

Priority: P2 · Topology: soak run or v2/standby (not v1 coverage) · Faults: long runs, data errors on large transactions, standby pause
Confidence: medium (hold list high on mechanism, needs a standby; general leak speculative) · Surfaced by: F5 Resources
Evidence: properties/apply-worker-memory-bounded.md
Evaluation note (2026-10-13): the hold-list mechanism needs a standby and about 4M transactions per worker to reach 256 MB, far beyond Antithesis workload throughput under faults; the general RSS check is a soak test. A `synchronous_standby_names = 'phantom'` subscriber grows the hold list without a standby container, but still needs a long run.

---

## Category J — Audit tables and explained divergence

`spock.exception_log` and `spock.resolutions` are the record of what Spock
dropped or decided. The harness's "every difference is explained" oracle and
repair tooling depend on them. Update/update conflicts are by design never
written to either table.

### exception-log-matches-discarded-transactions — exception_log is an accurate and complete record of discarded transactions

| | |
|---|---|
| **Type** | Safety |
| **Property** | Under TRANSDISCARD, every `exception_log` row names a real transaction from its `remote_origin` and one of its changes; each discarded transaction is logged completely, with exactly one root-cause row, and none of its changes are visible on that node. |
| **Invariant** | Workload `Always` (four messages): row names a real transaction (matching the workload's `(node, 32-bit xid, commit ts, write set)` record; rows with message "Spock can't find relation" have empty schema and table and are matched by text); discarded transaction logged completely and applied nowhere on that node; exactly one root-cause entry per discarded transaction, grouping one replay by `(remote_origin, remote_commit_ts, xmin)` (not `retry_errored_at`, which is a per-row timestamp); and "root cause not captured" when a replay has zero root-cause rows. `Sometimes("transaction discarded under TRANSDISCARD")`. |
| **Antithesis Angle** | Data errors (documented `update_missing` ordering, deliberate constraint violations) mixed with graceful exits during replay (L7), sync workers sharing the marker (L15), transient errors misread as data faults and missing ORIGIN messages. |
| **Why It Matters** | Repair (ACE) and operators use the table to find what was dropped. Rows that name the wrong transaction, miss rows, or exist for applied transactions mislead repair. |

**Open Questions:**

None

Priority: P1 · Topology: v1 · Faults: worker exit, partition, workload data errors
Confidence: medium · Surfaced by: F4 Protocol
Evidence: properties/exception-log-matches-discarded-transactions.md
Gap-fill note (2026-10-13): the app table's natural `update_missing` drops (`every-divergence-explained-by-spock-records`) are a second traffic source, in addition to the deliberate poison transactions.
Evaluation note (2026-10-13): poison and `update_missing` writes go to their own tables and into the expected-exception registry (origin, remote xid, table; `spock.exception_log.remote_xid` exists), so their documented divergence and rows do not fail other properties.

### insert-conflict-recorded-in-resolutions — insert_exists conflicts are recorded

| | |
|---|---|
| **Type** | Safety |
| **Property** | With `spock.save_resolutions=on`, when two nodes both commit a client INSERT of the same key, every node that receives the second-arriving INSERT records an `insert_exists` row for that key in `spock.resolutions`, or an `exception_log` row if the transaction was dropped. |
| **Invariant** | Workload `Always` after barriers: for each key with two or more committed client INSERTs on different nodes, each receiving node (including the third node) has a matching `spock.resolutions` row (`conflict_type='insert_exists'`, filtered by `node_name`) or an `exception_log` row for that transaction. SUT-side `AlwaysOrUnreachable(save_in_resolutions || origin-differs, ...)` in `spock_report_conflict`. Scoped to inserts because update/update "origin differs" events are documented as not recorded. |
| **Antithesis Angle** | Partitions and latency let both nodes commit the same key first; concurrent apply workers inserting the same key reach the lookup-then-insert race (L6a) that turns the conflict into 23505 and a dropped transaction; postmaster kills check that the record and the change commit together. |
| **Why It Matters** | `spock.resolutions` is how operators and repair tooling see which version LUW threw away; an unrecorded overwrite is silent loss from the user's view. |

**Open Questions:**

None

Priority: P2 · Topology: v1 · Faults: partition, latency, node kill
Confidence: medium · Surfaced by: F1 Data Integrity
Evidence: properties/insert-conflict-recorded-in-resolutions.md
Evaluation note (2026-10-13): the harness sets `spock.resolutions_retention_days = 0` (or copies `spock.resolutions` rows as they appear), so a forward clock skip past the retention period cannot delete rows this check reads at the end.

### resolutions-rows-match-applied-outcome — spock.resolutions rows describe the conflict that happened and the LUW decision taken

| | |
|---|---|
| **Type** | Safety |
| **Property** | Each `spock.resolutions` row names the real remote writer and local version, and its `conflict_resolution` agrees with the documented last-update-wins and tiebreaker rule given the recorded timestamps. |
| **Invariant** | Workload `Always` (four messages): remote side names the real writer (and `remote_tuple` matches for `insert_exists`); local side names the real local version (non-delta tables only: the delta override runs after the resolution row is written); decision follows LUW with the tie rule; `delete_missing` rows have no local tuple. Checks 1, 3 and 4 include delta tables. A losing remote UPDATE (KeepLocal) is not recorded by design (3bb8ad84). |
| **Antithesis Angle** | Asymmetric latency and partitions create insert/insert and delete/update races; global clock skips produce equal timestamps; node restarts reset the logical clock. None should make the recorded row disagree with the decision. |
| **Why It Matters** | Resolutions are the only persistent trace of resolved conflicts. |

**Open Questions:**

None

Priority: P2 · Topology: v1 · Faults: latency, partition, clock skew
Confidence: medium · Surfaced by: F4 Protocol
Evidence: properties/resolutions-rows-match-applied-outcome.md
Gap-fill note (2026-10-13): also scores `delete_exists` and `delete_missing` rows produced by the app-table traffic of `every-divergence-explained-by-spock-records` (until now those came only from narrow races).
Evaluation note (2026-10-13): same retention guard as `insert-conflict-recorded-in-resolutions`.

### every-divergence-explained-by-spock-records — Every cross-node difference on a realistic table is recorded by Spock

| | |
|---|---|
| **Type** | Safety |
| **Property** | On an "app" table written with INSERT, UPDATE and DELETE from every node (create on one node, edit or delete on others), every per-key difference between nodes after quiescence is matched by an `exception_log` or `resolutions` row on the differing node(s). |
| **Invariant** | Workload `Always("app table: every cross-node difference is explained by exception_log or resolutions")` after barriers. Group nodes by the key's version (absent counts); a node explains it with E1 an `exception_log` row for a dropped txn that wrote the key (matched by `(remote_origin, remote_commit_ts)` against the workload history, or by key in the tuple JSON), E2 a `delete_exists` resolution with that node's row, or E3 a `delete_missing` resolution where the node's version came from an INSERT; `insert_exists` explains nothing. Explained if at most one version group lacks a record. Unexplained keys that match an open lead go to their own `Always` messages ("... attributed to redelivery after crash (L1)", "... equal commit ts tie (L2)", "... commit clock reset after restart (L3)"). `Sometimes` markers for update-before-insert recorded, `delete_exists` kept a row, `delete_missing` then resurrecting insert, concurrent deletes converged, and "check ran on a diverged table". |
| **Antithesis Angle** | Latency and partitions between pairs make an UPDATE or DELETE from one node reach a third node before the INSERT from another (`update_missing`, no waiting retries in v1), and make delete/update and delete/delete races; node kills reach L1 and L3; global clock skips reach L2; graceful worker exits during replay (L7) and misclassified transient errors (L5) are what would leave a change dropped with no record. |
| **Why It Matters** | Spock claims "non-resolvable conflicts are recorded in `spock.exception_log`" and resolvable ones in `spock.resolutions` (`docs/conflict_types.md:12-15`); that is what makes the documented no-tombstone and `update_missing` divergences acceptable and repairable (ACE). Several properties cite this oracle; none owned it, and the catalog banned the most common multi-master pattern instead of checking it. Also covers delete conflicts beyond causal deletes (gap a item 3). |

**Open Questions:**

- Which `exception_behaviour` values score it? Designed for `transdiscard`; `discard` works if E1 matches by key only; `sub_disable` cannot use the app table. `(partial: DISCARD logs only the failing change, code-checked; which modes the team wants scored is open)`
- Is "at most one unexplained version group" what the team means by S2, or only "some differing node has a record"?
- Should a difference explained only by a transient-class error row (57014, 40P01, 08xxx) count as explained, or be left to the classifier properties as now?

Priority: P1 · Topology: v1 (app table on top of the main workload) · Faults: latency, partition, node kill, global clock skip, worker exit
Confidence: medium (row-per-conflict mapping code-checked; the matching rule is new and untested) · Surfaced by: Evaluation gap a
Evidence: properties/every-divergence-explained-by-spock-records.md
Second-pass note (2026-10-13): the main configuration sets `spock.resolutions_retention_days = 0`, which skips cleanup entirely (`src/spock_conflict.c:978`), so no `resolutions` row can disappear in v1; the snapshot-and-union design is needed only in a variant that turns cleanup back on, and the clock-jump-size question was dropped. `spock.exception_logging` must stay at its default `all`. The app table is never resynced (a resync would erase the differences scored here).

---

## Category K — Value fidelity

### replicated-values-mean-same-on-every-node — Replicated values are identical on every node

| | |
|---|---|
| **Type** | Safety |
| **Property** | After quiescence every replicated row renders to the same text on every node, whatever the transfer encoding (internal binary, send/recv, text) and per-node session settings, and no valid transaction is dropped because a node numbers its types differently. |
| **Invariant** | Workload `Always("replicated rows render identically on all nodes")` (ordered `row::text` checksum per table, fixed DateStyle/TimeZone/extra_float_digits on every node); `Always("no exception_log rows for type mismatch on valid data")`; `Always("force_text_transfer subscription agrees with binary subscriptions")`. SUT-side `Unreachable` in `decide_datum_transfer` (`src/spock_proto_native.c:641-671`) for (a) `'b'` chosen for a domain over a user array or composite, (b) `'i'`/`'b'` chosen for an OID-alias type (`regclass`, `regtype`, `oid`, ...). |
| **Antithesis Angle** | Mostly configuration-driven. OIDs differ between nodes as soon as n4 gets its schema through ZODAN's pg_dump/pg_restore or objects are created in a different order. Domains pass the send/recv test the code uses to exclude arrays/composites; the receiver's `array_recv`/`record_recv` raises 42804, a data error, so TRANSDISCARD drops the whole transaction. OID-alias types travel as raw `'i'` bytes and silently mean another object. Reconnects re-run binary/text negotiation. |
| **Why It Matters** | Valid user data is silently dropped (domains) or changed (reg* types); such drops also look like the fault-driven silent-discard bugs during triage. 34d473dc/f21e71bc fixed one settings class already; TimeZone and `lc_monetary` are still not pinned. |

**Open Questions:**

- Is the raw 'i' transfer of OID-alias types accepted, given no doc says binary transfer needs identical OIDs? `(needs human input)`
- Is `money` supported across nodes with different `lc_monetary`? `(partial: default 'i' copies raw int64 so meaning follows each node's locale; text path uses unpinned lc_monetary on both sides)`

Priority: P1 · Topology: v1 (schema with domains over user arrays on n4 after add_node) · Faults: none required; reconnects
Confidence: high for the domain/OID cases; low for the session-settings cases · Surfaced by: F4 Protocol, F11 Wildcard
Evidence: properties/replicated-values-mean-same-on-every-node.md
Placement: Expected to fire deterministically — confirm with TAP first, then gate out of the main template. (Domain-over-user-array and OID-alias cases: they fail whenever OIDs differ, which ZODAN's pg_dump/pg_restore makes true on n4 every time.)
Evaluation note (2026-10-13): after a TAP test with one domain column and one `regclass` column, the Antithesis part is binary/text negotiation after reconnects; P1 is a severity rank.

---

## Category L — Apply session identity

The apply worker runs as a superuser and switches roles to run queued SQL.
These check that the switch and its session settings do not leak into later
transactions. Expected to need few faults; restarts decide how long a leak
lasts.

### apply-search-path-not-leaked-across-transactions — Queued SQL does not change the apply session's search_path

| | |
|---|---|
| **Type** | Safety |
| **Property** | At the start of every remote transaction, the apply worker's `search_path` equals its value at worker start, whatever queued SQL ran before. |
| **Invariant** | SUT-side `Always(strcmp(namespace_search_path, apply_boot_search_path)==0, "apply worker search_path unchanged at remote BEGIN")` in `handle_begin`. Workload alternative: an `ENABLE REPLICA` canary trigger (fires only in replica-role sessions, so local writes add no rows) that writes `current_setting('search_path')`, `current_user` and `session_replication_role` to a local audit table. Expected to fail. |
| **Antithesis Angle** | The leaked value lasts until the apply worker restarts, so later behaviour depends on fault-driven restart history. Readers of the leaked value: queued commands sent without a `SET search_path` prefix (CLUSTER), the unqualified `delta_apply_function` lookup on the DML path, user code in constraints, defaults, index expressions and REPLICA/ALWAYS triggers, and the daily `spock.resolutions` cleanup SPI query (unqualified `now()` and operators), which a forward clock step can trigger. |
| **Why It Matters** | Not intended (the code comment says "Restore the GUC variables"; the origin side uses `GUC_ACTION_SAVE`). The `SET search_path` prefix shipped with each `replicate_ddl` is a plain session SET kept on commit (`src/spock_apply.c:4345,4410`); the superuser apply worker then keeps a search_path chosen by the origin user, which can put a user schema before `pg_catalog` for replicated DML, not only DDL. |

**Open Questions:**

None

Priority: P1 · Topology: v1 · Faults: worker restarts, clock step forward
Priority note: raised from P2: confirmed unintended, and the DML path (delta-function lookup, user code) reads the leaked value.
Confidence: high (persistence); medium (impact in practice) · Surfaced by: F6 Security
Evidence: properties/apply-search-path-not-leaked-across-transactions.md
Placement: Expected to fire deterministically — confirm with TAP first, then gate out of the main template.
Evaluation note (2026-10-13): expected to fail on the first `replicate_ddl` that ships a `SET search_path` prefix; fault history only changes how long the leak lasts. TAP repro and fix, then a P3 regression guard. P1 is a severity rank.

### apply-identity-restored-after-queued-sql — Apply worker returns to its own identity after every queued-SQL error path

| | |
|---|---|
| **Type** | Safety |
| **Property** | Whenever the apply worker begins a remote transaction or applies a remote row, its effective user is its own superuser with no `SECURITY_LOCAL_USERID_CHANGE`, and `session_replication_role` is `replica`. |
| **Invariant** | SUT-side `Always` in `handle_begin` and at the start of `handle_insert/update/delete` comparing `GetUserIdAndSecContext()` with the boot values and checking `SessionReplicationRole`. The stale `in_spock_queue_ddl_command` flag is left out (short window, minor effects). Workload cross-check through the canary trigger. Expected to hold; regression guard (every catch inside the identity switch aborts a (sub)transaction, and the catches that swallow errors cannot be reached from replicated DDL). |
| **Antithesis Angle** | Make queued DDL fail many ways: lock_timeout or deadlock against local sessions, a role missing on one node, cancel of the apply pid, `terminate_active_transactions()`, a kill mid-DDL; in all three exception modes; then look at the next transaction. |
| **Why It Matters** | `SetUserIdAndSecContext` to the queued role (`src/spock_apply.c:4342`) and to `BOOTSTRAP_SUPERUSERID` in `spock_object_access` are undone only on success; error paths rely on (sub)transaction abort. A missed path would run later replicated changes under the wrong identity. |

**Open Questions:**

None

Priority: P3 · Topology: v1 · Faults: worker exit during DDL, lock contention
Priority note: lowered from P2: regression guard; code reading found no error path that keeps the switched identity.
Confidence: medium · Surfaced by: F6 Security
Evidence: properties/apply-identity-restored-after-queued-sql.md
Evaluation note (2026-10-13): the canary trigger is `ENABLE REPLICA` (see `apply-search-path-not-leaked-across-transactions`).

---

## Category M — Oracle health

### convergence-check-runs-after-faults — Convergence checks actually run in hard states

| | |
|---|---|
| **Type** | Liveness |
| **Property** | During a run, the full cross-node convergence check completes at least once after a node kill, after a healed partition, with real data from every origin, with all subscriptions enabled, and on the joined node; and a barrier result is never accepted for a disabled subscription. |
| **Invariant** | Workload `Sometimes`, separate messages: "convergence check completed after at least one node kill", "... after a partition healed", "... covered rows from every origin" (at least N ledger rows per origin), "... ran with all subscriptions enabled", "... ran on the joined node". Plus `Always("barrier returned true only for enabled subscriptions")`. |
| **Antithesis Angle** | Continuous faults can keep barriers from ever completing; silent partitions take up to `apply_idle_timeout` to detect; `wait_for_sync_event` returns early for disabled subscriptions unless `wait_if_disabled`. Any of these makes the convergence `Always`s pass without checking. The driver requests its own quiet period (`ANTITHESIS_STOP_FAULTS <s>`, plus `eventually_`/`finally_` commands) sized for barriers; clock skips continue inside it. A timed-out barrier is retried or skipped here; the liveness failure belongs to `mesh-barriers-complete-after-partition-heal`. |
| **Why It Matters** | Without this, a green run can mean "never checked". It also catches harness bugs where the check compares a non-replicating pair. |

**Open Questions:**

None

Priority: P0 (every data property depends on it) · Topology: v1 · Faults: all
Confidence: high · Surfaced by: F11 Wildcard
Evidence: properties/convergence-check-runs-after-faults.md
Evaluation note (2026-10-13): quiet periods must be sized for the new barrier bound (`wal_sender_timeout` 60 s + `apply_idle_timeout` 120 s + restart delay + connect timeout + margin, about 4-5 minutes). The strict no-exemption final round is now `strict-final-round-has-no-exemptions`; its zero-exemption marker is stronger than this property's "ran with all subscriptions enabled" (no change to the assertions here).

### strict-final-round-has-no-exemptions — A final round runs every convergence check with no state exemptions

| | |
|---|---|
| **Type** | Liveness |
| **Property** | After faults stop and the workload has run the operator recovery steps, every convergence check runs at least once in a fully healthy cluster (all subscriptions enabled and replicating, every table `r` on every node, readonly off, n4 joined or cleanly removed, every ordered barrier passed) with no state exemption, and passes. |
| **Invariant** | In a `finally_` command (plus an `eventually_` copy): workload `Always("strict round: <check> passed with no state exemptions")`, one message per existing oracle (ledger, exactly-once audit, delta counters, contested rows, all-or-nothing, app table explained, TRUNCATE tables, no orphan slots, connections). `Sometimes("strict round completed with zero exemptions in a fully healthy cluster")`, `Sometimes("strict round reached full health after recovering from exemptions")`, `Sometimes("strict round included the joined node")`. History attributions (L1, L3, n4 copy) keep their own messages. If health is not reached, the round records it and does not score (the failure belongs to `operator-recovery-steps-restore-replication`). |
| **Antithesis Angle** | Runs at the end of timelines that left disabled subscriptions, FAILED tables, partial add_node and readonly toggles behind. A check that passes normally but fails here shows that an exemption hid a real problem. |
| **Why It Matters** | Each exemption is reasonable alone, but together they can mean the strict checks only ever ran on an easy slice of the cluster. Without this, a green run does not show that any check ever ran with every table READY and n4 joined. |

**Open Questions:**

- Is the terminal quiet period of a `finally_` command long enough for recovery plus barriers plus checks?
- Must n4 be joined in the strict round (retry add_node), or is clean removal acceptable?
- Must a reached barrier stay reached across a restart? (Catalog-wide barrier contract question; barriers run twice until settled.)

Priority: P0 · Topology: v1 · Faults: all (needs runs that leave visible failures behind)
Confidence: high that it is needed; the check list is a harness choice · Surfaced by: Evaluation gap a
Evidence: properties/strict-final-round-has-no-exemptions.md
Dominance: aggregates the convergence checks; a failure here names the owning property's check, which is the one to triage. Stronger than the "ran with all subscriptions enabled" marker of `convergence-check-runs-after-faults`.

---

## Category N — Version compatibility (later topologies)

Need a 5.0.11 build next to 6.0 (`v2/mixed-version`: n1 on 5.0.11, n2/n3 on
6.0, n4 joins on 6.0) or two PG majors. Not reachable in v1.

### mixed-version-add-node-loses-nothing — A 6.0 node joins a 5.x or mixed cluster without missing or duplicating rows

| | |
|---|---|
| **Type** | Safety |
| **Property** | An add_node of a 6.0 node into a cluster with at least one 5.0.x node, under writes and faults, either fails visibly or leaves the new node with exactly the union of committed rows. |
| **Invariant** | Workload `Always` after a successful add and quiesce: ledger rows from every existing node present exactly once on the new node, with source and peer versions in the details. `Sometimes(add succeeded with a 5.x source)` and `Sometimes(add succeeded with a 5.x non-source peer)`. SUT-side `Unreachable`: sync worker on the pre-6.0 path read zero peer rows while the provider has enabled subscriptions from other nodes. |
| **Antithesis Angle** | Pause the 5.x provider during slot creation (5.0.11's pause code is the same as HEAD's, dcbba6bb backported as 2503b2c1, so a loss through the L4 window is a shared-design bug, not 5.x-only), partition or kill a 5.x peer between Phase 3 and Phase 7, restart the source between its binary swap and its extension update (the "6.0 binary, 5.x catalog" window where Phase 7 can fall back to `pg_current_wal_lsn()`). |
| **Why It Matters** | New code (f8f78b2e, adfd708b, 40c7b39a: three fixes in two weeks) on the highest-risk feature, and the path users are told to use to start an upgrade. The only test (099, nightly) has no faults and no per-row check. |

**Open Questions:**

- Is adding a node supported while some existing node runs the 6.0 binary with a 5.x catalog (before its ALTER EXTENSION UPDATE finishes)? `(needs human input)`

Priority: P2 (first property to run in v2/mixed-version) · Topology: v2/mixed-version · Faults: pause, partition, node kill
Confidence: medium · Surfaced by: F10 Versions
Evidence: properties/mixed-version-add-node-loses-nothing.md

### mixed-version-mesh-applies-exactly-once — Protocol-4 links in a mixed mesh keep exactly-once and convergence

| | |
|---|---|
| **Type** | Safety |
| **Property** | In a mesh where some nodes run 5.0.11 and some 6.0, every committed ledger row reaches every node exactly once and documented-resolvable conflicts converge, on v4 links as on v5 links. |
| **Invariant** | Reuse the single-version ledger and convergence `Always` checks, with each link's protocol version in the details. `Sometimes(a protocol-4 link carried a transaction that hit a conflict)`. |
| **Antithesis Angle** | Same faults as the v1 mesh. New interleavings come from v4 framing (`remote_insert_lsn` only at COMMIT), the 5.x progress table lagging up to 1 s, and 5.0.11 code that lacks the progress redesign, 401197ab and 986ad069 (the pause, sync_event and tiebreak fixes are backported). On PG18, build PG with v5_STABLE's patch set: 5.0.11's `spock.so` needs patch 035's exported `check_simple_rowfilter_expr` (035 changes no behaviour). |
| **Why It Matters** | Mixed clusters are a documented state during every 5.0 -> 6.0 upgrade; the 6.0 v4 code paths have no other way to run; `014_rolling_upgrade` is commented out of the schedule. |

**Open Questions:**

- Must 5.0.9/5.0.10 be covered in mixed runs (zodan floor is 5.0.9 with the old tiebreak; an in-place upgrade needs 5.0.11)? `(needs human input)`
- Are 5.0.x-only weaknesses (progress table and its crash handling, no 401197ab/986ad069) accepted during an upgrade, so failures on 5.0.x-subscriber links are filtered? `(needs human input)`

Priority: P2 · Topology: v2/mixed-version · Faults: same as v1 mesh
Confidence: medium · Surfaced by: F10 Versions
Evidence: properties/mixed-version-mesh-applies-exactly-once.md

### rolling-upgrade-node-restart-loses-nothing — Swapping one node from 5.0.11 to 6.0 under load loses and duplicates nothing

| | |
|---|---|
| **Type** | Safety |
| **Property** | Restarting one node on the 6.0 binary while others keep writing loses and duplicates no transaction on any link, the node's catalog reaches 6.0.0, and every subscription resumes with the right protocol. |
| **Invariant** | Workload `Always` at quiesce: ledger exactly-once; every node's `extversion` equals its library `spock.spock_version()`; no subscription disabled and no `exception_log` rows outside the expected-exception registry in the upgrade phase. `Sometimes(extversion reached 6.0.0 on the upgraded node)` within a bound that allows for lock waits: the automatic `ALTER EXTENSION UPDATE` waits with no `lock_timeout` on locks on `spock.progress`, `lag_tracker` and `resolutions`, so the workload avoids long readers of those during the swap. On PG18 the swap needs PG built with v5_STABLE's patch set. |
| **Antithesis Angle** | Kill during the manager's automatic `ALTER EXTENSION UPDATE` (script also calls non-transactional `slot_enable_failover()`), partitions during catch-up through v4 walsenders, first 6.0 start with no `resource.dat`. |
| **Why It Matters** | The documented upgrade procedure; release notes claim zero downtime; the upgrade script drops and recreates `spock.progress` and touches slots. |

**Open Questions:**

- Is the "6.0 binary, 5.x catalog" window meant to serve walsenders and peer SQL, or should they refuse until the catalog is updated? `(needs human input)`

Priority: P2 · Topology: v2/mixed-version · Faults: node kill during upgrade, partition
Confidence: medium · Surfaced by: F10 Versions
Evidence: properties/rolling-upgrade-node-restart-loses-nothing.md

### cross-pg-major-links-replicate-identically — Text-transfer links between PG majors replicate identically

| | |
|---|---|
| **Type** | Safety |
| **Property** | On a link from an older to a newer PG major (text datum transfer), every row arrives with the same value and exactly once, as on same-major (binary) links. |
| **Invariant** | Workload `Always` at quiesce: ordered per-row text dumps equal across nodes and ledger exactly-once, on old-to-new links (or, on new-to-old links, only for types and values both majors accept). `Sometimes(a cross-major link applied a transaction)`. |
| **Antithesis Angle** | Little beyond the same-major mesh; the risk is mostly deterministic type round-trips. The cheaper route is one `force_text_transfer = true` subscription in v1 (covered by `replicated-values-mean-same-on-every-node`). |
| **Why It Matters** | v5.0 release notes claim PG major upgrades by adding a new-major node and removing old ones; `docs/limitations.md` treats a cross-major cluster as a transition state only, and binary transfer is only allowed for equal majors. A `force_text_transfer` subscription runs exactly the same Spock text path, so it is the cheaper route. |

**Open Questions:**

None

Priority: P3 · Topology: v2/mixed-pg-major · Faults: none required
Priority note: lowered from P2 in evaluation: the risk is deterministic type round-trips; cover it with the `force_text_transfer` message in `replicated-values-mean-same-on-every-node` plus a TAP round-trip test, and run this only if the mixed-major topology is built anyway.
Confidence: low · Surfaced by: F10 Versions
Evidence: properties/cross-pg-major-links-replicate-identically.md

---

## Assumptions

1. **Target build.** PG18 with the pgEdge patches, Spock at HEAD 69d9228f,
   cassert on (an Assert is a whole-node crash-restart). Stock PG behaviour
   that several properties rest on (commit records carry
   `replorigin_session_origin`; redo advances `XLogRecGetOrigin(record)`;
   `RecordTransactionCommit` advances the session origin before
   `ProcArrayEndTransaction`; `RecordTransactionAbort` advances it on abort;
   the decoding skip test is strict `<`) was read in stock PG17, stock
   REL_18_STABLE and the patched PG18 tree; the pgEdge patches touch only the
   commit-timestamp hook in `xact.c`. Clock-fault runs use an image built
   from main plus the SPOC-688 fix (4e0988de) or they crash-loop on the first
   backward skip.
2. **Workload oracles.** The workload owns: insert-only `ledger`/`ledger_b`
   keyed `(origin_node, seq)` with `txn_tag`; a `contested` table (seeded,
   UPDATE only); a `counters` table with a delta-apply column; a `dupkeys`
   table for insert/insert conflicts; a TOAST table; a many-types table; and
   on every node a local, non-replicated `apply_audit` table filled by an
   `ENABLE REPLICA` trigger (fires only when `session_replication_role =
   replica`; `ENABLE ALWAYS` would also fire for local writes). It
   records per transaction `(node, 32-bit xid, commit ts, write set)` and
   resolves unknown-outcome commits by reading the origin (a marker row in
   the same transaction) after it returns. Poison transactions and
   `update_missing` writes use their own tables and are recorded in an
   expected-exception registry (origin, remote xid, table); every "no
   `exception_log` rows" check means "none outside the registry". The
   workload copies `spock.resolutions` and `spock.exception_log` rows into
   its own store as they appear, or the harness sets
   `spock.resolutions_retention_days = 0`.
3. **Barriers as the quiesce signal.** Data checks run only after
   `sync_event` + `wait_for_sync_event` pass for every ordered pair, with a
   timeout above `wal_sender_timeout + apply_idle_timeout +
   restart_delay_default + connect_timeout` plus margin, never on
   `sub_show_status = replicating`. A timed-out barrier skips that round's
   data checks and is reported by the liveness properties. A barrier wait
   that spans a detected clock jump is re-run.
4. **Exception mode and settings.** Main runs use `transdiscard` with
   `spock.save_resolutions=on`; a `sub_disable` variant is possible; `discard`
   is excluded (non-atomic by design). Harness settings:
   `wal_sender_timeout = 60s` (shutdown and recovery bounds depend on it; do
   not lower it further) with `spock.apply_idle_timeout = 120s`, well above
   `wal_sender_timeout / 2` (an idle walsender sends a keepalive only about
   that often, and the idle timer resets only on a received message,
   `src/spock_apply.c:3548-3562, 3686`); one variant runs the documented
   values (`wal_sender_timeout = '5min'`, `apply_idle_timeout = 300`).
   `max_active_replication_origins` at least 32 (redo-created node-id states
   from L1 each take one and cannot be dropped); per-node DateStyle/TimeZone
   pinned; `lc_messages = 'C'`; `logging_collector = on` so the workload can
   read logs with `pg_read_file`; `spock.pause_timeout = 1`. Client sessions
   use `synchronous_commit=on`; apply sessions keep Spock's default
   `synchronous_commit=off` (or a run variant randomises it).
   `checkpoint_timeout` is 5min and `max_wal_size` 1GB (a day and 8GB
   filled the disk; see `deployment-topology.md`), and the workload
   issues no manual CHECKPOINT. `spock.exception_logging` stays at its
   default `all` (the explained-divergence oracle needs every row). These
   timeouts meet the rule `apply_idle_timeout >= wal_sender_timeout / 2 +
   30 s` (checked against `deployment-topology.md` on 2026-10-13; see
   `quiet-link-never-hits-idle-timeout`). The `sub_disable` variant sets
   `spock.exception_behaviour = sub_disable` on every node and hosts
   `sub-disable-error-ends-disabled-and-recorded`; runs with two-phase
   writers set `max_prepared_transactions > 0`.
5. **Workload boundaries** (sut-analysis §12): PK is the only unique index on
   checked tables, no deletes on contested tables, no cross-node
   update-after-insert, no TRUNCATE in conflict phases, READ COMMITTED,
   lowercase names not ending in `_<digit>`, default `forward_origins`,
   unique tiebreakers per node, node names that do not hash to id 0/65535.
   Workload local writes use a non-superuser role (the readonly hooks skip
   superusers). Workload DDL is non-idempotent (no `IF NOT EXISTS` /
   `OR REPLACE`) so a redelivered DDL shows up. `sub_resync_table` uses the
   default `truncate := true` (`false` always fails on a populated PK table).
   Admin churn is scoped so it cannot break the shared oracles: resyncs
   target dedicated single-writer tables (one `resync_<P>` table per
   provider, written only on P), so truncation loses nothing and CATCHUP
   still has work; drop/re-create and `sub_drop`-during-sync scenarios use
   throwaway subscriptions with their own replication set and table; ledger,
   delta, contested and convergence checks exclude those tables.
   Gap-fill additions (2026-10-13): the app table of
   `every-divergence-explained-by-spock-records` is the one place where
   cross-node update-after-insert and deletes are allowed (scored only by
   that oracle, never resynced); TRUNCATE runs only on single-owner
   `trunc_<node>` tables; any two-phase writer always finishes what it
   prepares (COMMIT or ROLLBACK PREPARED, retried after restarts), since an
   orphaned prepared transaction blocks apply on its rows; a re-add of n4
   drops its user schemas, not only its tables. Setup check: after cluster
   creation, after every add_node and after resyncs, no `spock.node`
   node_id equals any `pg_replication_origin.roident` on any node (node ids
   are `hash_any(name) & 0xffff`, `src/spock_node.c:370-371`; a clash is
   fixed by renaming nodes), and no `spock_output` slot name ends in
   `_<digit>` (`walsender-never-joins-slot-group`).
6. **Fault tools.** Node termination keeps PGDATA (named volume). Required
   harness components (see `deployment-topology.md`): a node wrapper loop that
   restarts postgres after `pg_ctl stop` or `kill -9` and records a boot
   counter and last-exit kind outside PGDATA; SQL routes for single-worker
   cancel/terminate/signal; node-container test commands for `pg_ctl stop -m
   fast` and postmaster kills; and a workload-driven crash helper that does an
   action and then kills the postmaster after a short random delay. The
   workload detects fresh boots by comparing
   `pg_control_system().system_identifier`. DSNs use hostnames (a restarted
   container may change IP). An admin-churn phase (resync, disable/enable,
   drop/re-create) and a readonly-toggle action exist. Some DDL is issued via
   `spock.replicate_ddl` as a non-superuser role present on every node.
7. **Node churn.** The workload may remove n4 and join it again (same
   PGDATA); a separate `v2/small-capacity` configuration (node kills off)
   churns with fresh names to reach the fixed-table limits.
8. **Clock faults** (Antithesis docs, checked in the investigation pass).
   Clock skips are global: all containers jump together, forward or
   backward, and jumps can stack. A backward jump reaches L2 ties and, with a
   restart, L3, and trips the cassert Assert in `handle_commit` on every
   node. `ANTITHESIS_STOP_FAULTS` quiet periods do not stop clock skips, so
   every bounded-time check in a quiet period detects jumps (monotonic vs
   wall clock) and re-runs or skips when one happened.
9. **Test templates.** Main (conflict-free checked tables plus registered
   poison tables; no cancel/terminate commands; readonly=local phases with
   superuser DDL only), classifier (cancel and `terminate_active_transactions`
   commands), add-node and node churn (own template; one add_node takes
   minutes), and the `v2/small-capacity` configuration. Properties marked
   "Expected to fire deterministically" are confirmed with TAP first and kept
   out of the main template until fixed or accepted.
10. **SUT-side assertions.** No Antithesis C SDK exists. Either a small C++
   file compiled into `spock.so` with `extern "C"` wrappers (C++ SDK,
   clang++; exceptions must never cross a `longjmp`), or a fallback writer
   that appends one JSONL line per `write()` on an `O_APPEND` descriptor in
   `$ANTITHESIS_OUTPUT_DIR`. Either way every SUT-side message is declared
   at `_PG_init`, so an unreached `Sometimes`/`Reachable` still shows up.
   Mode flags (for example `antithesis.conflict_free`) are placeholder GUCs
   set per configuration.

## Open Questions

- **Is node termination with PGDATA kept enabled for this tenant, does it
  keep fsynced writes, and does it drop unfsynced ones (page cache)?** L1 (now confirmed by code reading), L18 and L3 need
  it; about a third of the P0/P1 set cannot fail without it. If off, a
  test-command fallback (`kill -9` of the postmaster) is needed. Per-container
  clock skew is no longer needed: global backward skips reach the LUW leads.
- **SPOC-688 fix in the image.** Will branch
  `task/SPOC-688/apply-clock-skew-fix` (4e0988de) be merged, and should the
  Antithesis image include it before clock faults are enabled? Without it,
  every backward clock skip crash-loops all cassert nodes.
- **Exactly-once vs at-least-once.** Several P0/P1 properties
  (`ledger-row-applied-exactly-once-per-peer`,
  `delta-counter-equals-committed-increments`,
  `causally-deleted-row-stays-deleted`, `redelivered-ddl-not-turned-into-exception`,
  `interrupted-exception-replay-still-records-txn`) assume the team intends
  exactly-once on direct subscriptions. L1 makes redelivery after a crash
  reachable, so the answer now decides whether these are bugs or
  documentation findings for delta columns and DDL. (The cascade switch in
  `forwarded-origin-advance-no-double-apply` is documented at-least-once and
  is scored against that bound.)
- **Is the node-id origin state after crash redo intended?** Decides whether
  `crash-redo-leaves-no-node-id-origin-state` and
  `replication-origin-states-do-not-leak` are bugs or sizing guidance.
- **Barrier contract.** Rows committed before `sync_event()` are covered by
  code; open are DML in the caller's own transaction, discard-advanced
  origins, and whether a reached barrier must stay reached across a
  subscriber restart. Until answered, checks re-read after a short delay and
  re-run barriers after any restart.
- **Is query cancel / `terminate_active_transactions()` on an apply worker a
  supported operator action?** Decides whether the 57014 / 40001 findings are
  bugs or doc gaps; the workload needs the answer to decide how often to
  inject them.
- **Tie rule and commit clock.** Is the applying-node tiebreak (64ea462d)
  intended, and is the restart-unsafe commit clock (patch 025 TODO) an
  accepted limit? Decides how the LUW properties score ties and L3
  divergence.
- **Graceful-stop, single-worker-exit and crash helpers.** Now required
  components in `deployment-topology.md` (node wrapper loop, SQL signal
  routes, node-container test commands, workload-driven crash helper); not
  built yet. Many lifecycle, classifier and redelivery properties never run
  without them.
- **Clock-skip sizes.** What sizes and durations do Antithesis clock skips
  use? L3 needs a backward skip larger than a restart plus recovery plus one
  write; if skips are small, a libfaketime per-node offset custom fault is
  needed.
- **SUT assertion route.** C++ SDK shim in `spock.so`, or the fallback JSONL
  writer? Both need every message declared at `_PG_init`.
- **Table resyncs in v1.** Running `sub_resync_table` reaches several leads
  (L12, L15, the exception-log claim race, the SIGTERM-ignoring sync worker)
  but also makes `progress-reconcile-anomaly-unreachable` reachable with no
  operator action. Decide whether v1 runs resyncs and how that property
  treats those timelines. Gap-fill properties that need resyncs at least in
  the final round: `sync-worker-sigterm-never-skips-catchup`,
  `operator-recovery-steps-restore-replication` and the retry step of
  `apply-never-waits-on-dead-sync-worker`.
- **`sub_disable` run variant.** `sub-disable-error-ends-disabled-and-recorded`
  and the SUB_DISABLE half of `interrupted-exception-replay-still-records-txn`
  need it; is it in scope for the first runs?
- **Two-phase commit and subscriber failover.** Are `PREPARE TRANSACTION`
  clients and failing a subscriber over to its standby supported? Decides
  whether `prepared-commit-ts-matches-sent-ts` and
  `promoted-subscriber-standby-has-every-confirmed-txn` report bugs or
  documentation findings.

## Out of scope / not testable by Antithesis

Fixed findings from code reading that do not depend on timing or faults.
Noted here for a human or TAP follow-up; not run.

- **`spock.replicate_ddl(..., role)` role check.** The caller-supplied role is
  used for `SetUserIdAndSecContext` locally and on every peer with no
  membership/privilege check, and the function is not revoked from PUBLIC.
  The only barrier is USAGE on schema `spock`. Needs a security review.
- **`spock.terminate_active_transactions()` is not revoked from PUBLIC.** A
  role with USAGE on `spock` can cancel transactions it would not be allowed
  to cancel with `pg_cancel_backend`. The runtime effect on apply workers is
  covered by `terminate-active-transactions-never-discards-inbound`.
- **`spock.queue` is a trust boundary.** Rows run on subscribers as the
  recorded role; default grants are safe, but any `GRANT INSERT ON
  spock.queue` hands over remote superuser execution. Worth a doc warning.
- **Reserved schema/object guards** (TAP 027/034/038) and **extension upgrade
  schema equality** (TAP 018): deterministic, better left to TAP.
- **`output_plugin_libraries` on PG 18.6+** must list `spock_output` on every
  node including n4: a setup requirement, already handled by the harness
  entrypoint probe.
- **Failover slots and physical standbys** (L9 sync-standby hold, S9): now
  covered by `sync-standby-hold-freezes-provider-confirmed-flush` (phantom
  variant, no extra container) and `promoted-subscriber-standby-has-every-confirmed-txn`
  (`v2/standby`); whether to build `v2/standby` is still a scope decision.
- **Slot groups** (subscription/slot names ending in `_<digit>`, L10/L30): a
  separate `v2/slot-groups` config; `readonly-all-never-commits-remote-txn`
  now lives there.
- **One database per instance.** Several Spock databases on one instance
  (shared exception-log entries keyed by subscription name, instance-wide
  pause flag) are not modelled; effects look mild from code reading.
- **Capacity counting routes** (`exception-log-slots-never-exhausted`
  capacity route, `progress-hash-capacity-survives-node-churn`) and the
  deterministic first-hit bugs are cheaper to confirm in TAP; Antithesis
  keeps them as regression guards or in `v2/small-capacity`.

TAP-only findings from the gap-fill step (2026-10-13), deterministic, not
run:

- **TRUNCATE ignores the subscription's replication sets.**
  `pg_decode_truncate` (`src/spock_output_plugin.c:1147-1196`) tests
  `get_table_replication_sets(local_node_id, relid)` (every set on the node)
  instead of the subscription's sets, which insert, update and delete use
  (`:942-943, 1054-1055`). A subscriber gets TRUNCATE for a table it does
  not subscribe to: it truncates its own copy, or, if the table is missing,
  raises "Spock can't find relation" and under TRANSDISCARD drops the whole
  transaction. Present since e2f4405a. Not reachable in v1 (one set of
  replication sets everywhere).
- **Re-adding a table to a replication set with `synchronize_data` is
  skipped if the subscriber still has a sync status row.**
  `handle_table_sync` skips when any `local_sync_status` row exists for the
  table (`src/spock_apply.c:2555-2566`), including the READY row the initial
  sync writes (`src/spock_sync.c:1738-1766`); nothing removes it when the
  table leaves the set. Rows written while the table was out of the set are
  never copied. Same logic as pglogical; may be known.
- **L27 single-read vs multi-read.** TAP 016 covers a one-row
  missing-relation transaction under `sub_disable` and passes; the
  multi-read case (`sub-disable-error-ends-disabled-and-recorded`) should be
  reproduced in TAP with a large transaction first.
- **`sub_show_table` prints `unknown` for a FAILED table**
  (`sync_status_to_string`, `src/spock_functions.c:1359-1382`, maps only `r`
  to "replicating"): a display gap for TAP or docs, not a fault-driven
  property (was candidate `stuck-table-not-shown-as-replicating`).
- **Directly fired checks** of `prepared-commit-ts-matches-sent-ts` and of
  mechanism 1 of `sync-standby-hold-freezes-provider-confirmed-flush`: both
  fire without faults; confirm in TAP, then keep only the fault-driven
  parts in Antithesis.
- **Slot invalidation (`max_slot_wal_keep_size`, extra gap E1).** Not a
  property. Code reading: Spock has no handling of its own; after
  invalidation `START_REPLICATION` fails and the apply worker exits with
  FATAL (`src/spock.c` `spock_start_replication`, "could not send
  replication command"), restarting every `restart_delay_default`: a visible,
  paced loop, not a silent gap. Nothing re-creates the subscription slot on
  reconnect; the only re-create path is a new initial sync or table sync,
  which drops an inactive slot of the same name and copies data fresh
  (`src/spock_sync.c:430-445, 663-675`). `sub_show_status` shows `down`
  most of the time and `replicating` while each new worker is briefly up, a display gap close
  to `sub-show-status-reflects-apply-state`. The project expects unlimited
  retention (the upgrade test requires `max_slot_wal_keep_size = -1`), and
  the outcome does not depend on timing, so a TAP test (invalidate a slot,
  check the log and status) is the better tool.

## Investigation candidates: outcome

The open-question investigation pass suggested eight candidates; the
evaluation passed them to the gap-fill step (2026-10-13). What happened to
each:

- `table-resync-under-faults-ends-ready` (G1): folded into
  `apply-never-waits-on-dead-sync-worker` as a retry step
  (`Always("retried table resync reaches READY after faults stop")`). As
  worded it contradicted the designed behaviour (a sync restarted after it
  started goes FAILED). `operator-recovery-steps-restore-replication` runs the
  step but does not assert it again.
- `sync-worker-sigterm-never-skips-catchup` (G7): catalogued at P1 in
  Category G. `manager-kill-targets-only-listed-worker` is now one of its
  causes; its evidence note on fast shutdown was corrected (fast shutdown
  reaches the skip during SYNCWAIT).
- Exception-log first-BEGIN race (G9): stays inside
  `exception-log-slots-never-exhausted` as its own `Unreachable` message.
- `node-id-never-equals-local-origin-id`: a setup check, not a property;
  added to Assumption 5 (run after cluster creation, every add_node and
  resyncs).
- `stuck-table-not-shown-as-replicating` (G8): not fault-driven
  (`sync_status_to_string` is deterministic); listed under "Out of scope" as
  a display gap. The real "shown as replicating while stale" case is the
  drift in `sync-worker-sigterm-never-skips-catchup`.
- `clean-apply-exit-respawn-paced` (G8): already covered by the second check
  of `worker-respawn-rate-bounded`, which counts registrations per
  subscription, so clean-exit respawn loops count too. The L27 loop of
  `sub-disable-error-ends-disabled-and-recorded` is one such loop.
- `readonly-all-stopped-worker-input-bounded` (G4 side lead) and
  `delta-apply-never-sees-toast-placeholder` (G5 side lead): not taken up by
  any gap topic and still unverified. Kept here as leads for a later pass;
  the first would sit next to `readonly-toggle-resumes-without-loss`, the
  second next to `luw-unchanged-toast-no-mixed-rows`.
