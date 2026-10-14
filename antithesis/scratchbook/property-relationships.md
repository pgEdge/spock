---
sut_path: /home/msharp/dev/pgedgea/spock
commit: 69d9228f5df363761dc3ae6eebf7e2fcfe49b8e5
updated: 2026-10-13
external_references: []
---

# Property Relationships

## Summary

Groups of catalog properties that share code paths, failure mechanisms or
oracles, plus suspected dominance (one property's failure likely implies
another's). Lightweight: connections noticed during synthesis, not deep
analysis, updated after the open-question investigation pass, the
evaluation refinements and the gap-fill step with its second evaluation pass
(2026-10-13; see `evaluation/synthesis.md`). Every slug here is in
`property-catalog.md`.

## Shared foundations (build these first)

Three pieces of workload infrastructure underpin most of the catalog. A bug in
any of them gives false alarms or silent passes everywhere downstream.

1. **The sync barrier.** `sync-event-barrier-implies-visible` and
   `sync-event-barrier-survives-subscriber-restart` are the contract every
   data check waits on. `mesh-barriers-complete-after-partition-heal` is the
   gate that lets a check round run at all, and
   `convergence-check-runs-after-faults` proves rounds actually ran in hard
   states. If the barrier returns early, the convergence and ledger checks
   report false loss; if it hangs after a restart, they never run. Code
   reading says the main "rows committed before the call are visible" check
   holds; the expected firings are DML in the caller's own transaction and
   the re-check after a subscriber crash (L18, L1).
2. **The ledger oracle** (insert-only `ledger` keyed `(origin_node, seq)`,
   `txn_tag`, per-transaction `(node, xid, commit ts, write set)` record,
   unknown-outcome resolution). Used by `committed-ledger-row-reaches-every-node`,
   `ledger-row-applied-exactly-once-per-peer`,
   `remote-transaction-all-or-nothing-per-node`,
   `add-node-success-new-node-has-every-row`,
   `zodan-readd-node-progress-not-stale`,
   `sub-disable-enable-cycle-loses-and-duplicates-nothing`,
   `readonly-toggle-resumes-without-loss`,
   `graceful-restart-preserves-exactly-once`,
   `terminate-active-transactions-never-discards-inbound`,
   `apply-cancel-retried-not-discarded`,
   `exception-log-matches-discarded-transactions`,
   `progress-commit-lsn-tracks-applied-commits`, and the v2 properties
   `mixed-version-mesh-applies-exactly-once`,
   `mixed-version-add-node-loses-nothing`,
   `rolling-upgrade-node-restart-loses-nothing`,
   `cross-pg-major-links-replicate-identically`,
   `forwarded-origin-advance-no-double-apply`. The oracle comes with an
   expected-exception registry (poison and `update_missing` transactions on
   their own tables, recorded by origin, remote xid and table); every "no
   `exception_log` rows" check means "none outside the registry".
3. **Duplicate detectors**: the local `apply_audit` trigger table and the
   `insert_exists` rows in `spock.resolutions` (both inside
   `ledger-row-applied-exactly-once-per-peer`; the trigger is `ENABLE
   REPLICA`, so local writes add no rows), plus the delta counter
   (`delta-counter-equals-committed-increments`, and on n4 through
   `add-node-success-new-node-has-every-row`). The lifecycle outcome
   properties reuse them for their "duplicates nothing" half.

Commit-timestamp recording (writer reads `pg_xact_commit_timestamp(xid)` on
the origin after COMMIT) is a fourth shared need for the LUW cluster below.
For two-phase writers the origin's value is wrong (it is the unbumped
time); read it from a peer instead (`prepared-commit-ts-matches-sent-ts`).

Two oracle-level properties sit on top of these foundations:
`every-divergence-explained-by-spock-records` scores a realistic mixed-DML
app table against the audit tables (cluster 11), and
`strict-final-round-has-no-exemptions` re-runs every convergence check once
with no state exemptions (cluster 12).

## Clusters

### 1. Crash redo and origin bookkeeping (lead L1, L18)

Mechanism: crash redo advances the node-id origin from the commit record
instead of the subscription origin; non-transactional markers advance the
origin in memory only. L1 is now confirmed by code reading on stock PG17,
stock REL_18_STABLE and the patched PG18 tree (the pgEdge patches touch only
the commit-timestamp hook; Spock's rmgr redo only logs and reconcile trusts
the regressed origin). Not yet run.

- `crash-redo-leaves-no-node-id-origin-state` — direct detector of the L1
  mechanism; expected to fire on the first subscriber crash between
  checkpoints.
- `ledger-row-applied-exactly-once-per-peer`,
  `delta-counter-equals-committed-increments`,
  `causally-deleted-row-stays-deleted`,
  `redelivered-ddl-not-turned-into-exception` — four visible consequences of
  redelivery (plain duplicate, double count, resurrected row, re-run DDL).
- `interrupted-exception-replay-still-records-txn` — a redelivered poison
  transaction writes a second set of `exception_log` rows (also caught by the
  repeated-row check in `ledger-row-applied-exactly-once-per-peer`).
- `truncate-ordered-with-same-origin-dml` — a redelivered TRUNCATE-bearing
  transaction on a single-owner table (code reading: the whole transaction is
  resent, so the result should not change; a guard).
- `every-divergence-explained-by-spock-records` — on the app table, L1
  resurrections show up as unexplained differences under their own
  "attributed to redelivery after crash (L1)" message.
- `sync-event-barrier-survives-subscriber-restart` — L18 and L1 seen through
  the barrier.
- `replication-origin-states-do-not-leak` — capacity side of the same
  redo-created states; `crashed-node-returns-to-streaming` — a full state
  array stops redo, so the node does not start (harness sets
  `max_active_replication_origins` to 32 to keep this a separate signal).
- `forwarded-origin-advance-no-double-apply` (v2/cascade) — L1 can resend to
  C through the forwarding subscription; duplicates must be attributed to the
  applying subscription so they are not blamed on the documented
  one-replay-per-crash bound.

Dominance: `crash-redo-leaves-no-node-id-origin-state` is the root signal.
When it fires, expect the consequence properties to fire in the same
timelines whenever a resend hits keys they watch; read them as one finding
(L1) unless the detector stays silent. Whether the consequences are bugs or
documentation findings depends on the team's exactly-once vs at-least-once
answer. `graceful-restart-preserves-exactly-once` is the control: the
shutdown checkpoint persists origins, so it should pass while the crash
properties fail.

Evaluation refinement: one L1 hit would otherwise blind every consequence
oracle to a second cause (an `Always` reports once per message). Each
consequence property therefore splits its message into "explained by L1"
(the node crashed since the change committed and shows a node-id origin
state) and "unexplained"; only the unexplained messages are new findings
while L1 is open. `crash-redo-leaves-no-node-id-origin-state` is expected to
fire deterministically: confirm with TAP first. The redelivery properties
need the kill inside the unconfirmed window after a burst, so they use the
workload-driven crash helper.

### 2. Apply error classifier and exception replay (leads L5, L7, L15, L23)

Shared code: `apply_work` `PG_CATCH`, the shared-memory exception marker in
`handle_begin`, the replay queue and spill file, `handle_commit`.

- Misclassification entry points: `apply-cancel-retried-not-discarded`
  (57014), `terminate-active-transactions-never-discards-inbound` (40001),
  `lock-contention-retried-not-discarded` (40P01/55P03, regression guard),
  `insert-race-resolved-not-discarded` (23505),
  `readonly-local-keeps-inbound-ddl-flowing` (25006),
  `redelivered-ddl-not-turned-into-exception` (42xxx).
- Marker and replay correctness: `exception-replay-only-after-recorded-error`,
  `exception-replay-never-reruns-committed-transaction`,
  `interrupted-exception-replay-still-records-txn`,
  `proto5-replay-reparses-startup-message`, `replay-spill-file-lifecycle`,
  `apply-stale-socket-never-polled`.
- Pacing after exits: `worker-respawn-rate-bounded` (regression guard; no
  known infrastructure fault reaches the unpaced path; the L27 loop below is
  a clean-exit respawn loop it would count).
- SUB_DISABLE outcome: `sub-disable-error-ends-disabled-and-recorded` (S7,
  lead L27: a disable written into a still-open remote transaction is rolled
  back at exit, and the worker loops with nothing recorded). Runs in the
  `sub_disable` variant; complements the SUB_DISABLE half of
  `interrupted-exception-replay-still-records-txn` (interrupts) with the
  uninterrupted bound and the read-boundary route.
- TRUNCATE in the replay path: `truncate-ordered-with-same-origin-dml`
  (`handle_truncate` exception and replay branches, recent fixes 940e500d,
  162dc562).
- Outcome oracles: `committed-ledger-row-reaches-every-node`,
  `exception-log-matches-discarded-transactions`.

Dominance: each misclassification property implies a
`committed-ledger-row-reaches-every-node` failure on the conflict-free ledger
(under TRANSDISCARD), and the specific property names the SQLSTATE. 
`proto5-replay-reparses-startup-message` forces a graceful exit during replay
right after the origin moved to `commit_lsn`, which is exactly the trigger of
`interrupted-exception-replay-still-records-txn`; code reading says the
latter holds there (T is resent, no silent drop), so the visible consequence
is the corrupted progress value caught by
`progress-insert-lsn-never-ahead-of-provider`.
`exception-replay-never-reruns-committed-transaction` fires with a recorded
initial error, so `exception-replay-only-after-recorded-error` does not catch
it; they are complementary, not overlapping.

Evaluation refinement: `apply-cancel-retried-not-discarded` (57014) and
`terminate-active-transactions-never-discards-inbound` (40001) fire on any
cancel that lands mid-transaction, and `readonly-local-keeps-inbound-ddl-flowing`
on any non-superuser DDL: all three are expected to fire deterministically.
Confirm them with TAP, then keep the cancel/terminate commands in a separate
classifier template and non-superuser DDL out of readonly=local phases in
the main template, so a `committed-ledger-row-reaches-every-node` failure
in the main template points at a new cause. The ledger property also splits
"missing, explained by a recorded classifier error" from "missing, no
exception row". Poison-transaction properties
(`interrupted-exception-replay-still-records-txn`,
`exception-log-matches-discarded-transactions`,
`proto5-replay-reparses-startup-message`, `replay-spill-file-lifecycle`,
`apply-stale-socket-never-polled`) share the main template only through the
expected-exception registry.

### 3. Feedback and resume position

Shared code: `send_feedback`, `get_flush_position`,
`request_initial_status_update`, the provider's `confirmed_flush`.

- `feedback-never-confirms-undurable-apply` (three checks).
- `interrupted-exception-replay-still-records-txn` (keepalive during replay is
  the one way the provider could confirm past T; its SUT-side check overlaps
  check (1) of the feedback property).
- `apply-stream-framing-and-lsn-order` (BEGIN not below origin progress: the
  other side of the same resume rule).

- `sync-standby-hold-freezes-provider-confirmed-flush` (phantom sync
  standby variant): both L9 paths, `flushpos = recvpos` once the mapping
  drains and the restart sending `origin_startpos` as flushed.
- `promoted-subscriber-standby-has-every-confirmed-txn` (`v2/standby`): the
  end-to-end outcome of the same cause after failover.

Dominance: a violation of `feedback-never-confirms-undurable-apply` shows up
as a `committed-ledger-row-reaches-every-node` failure with no exception row;
the feedback property names the cause. For the sync-standby hold, check (2)
of the feedback property is the SUT-side detector of L9 path 1, the phantom
property is the workload-side check of both paths, and the promote property
is the user-visible loss; expect them to fire in that order, and run the
phantom variant (no sixth container) before building `v2/standby`.

### 4. LUW, commit clock and clocks (leads L2, L3)

Shared code: `conflict_resolve_by_timestamp`, `get_tuple_origin`, core patch
025 (`EnsureMonotonicTransactionStopTimestamp`), `handle_commit` progress.

- Gate: `apply-survives-provider-clock-ahead` (confirmed Assert). Antithesis
  clock skips are global, so any backward skip crash-loops every cassert
  node. The clock-fault image is built from main plus the SPOC-688 fix
  (4e0988de, merges onto HEAD without conflicts), which turns this into a
  P2 regression guard; an image without the fix runs no clock faults.
- Reachability: `clock-step-forward-makes-commit-ts-ties` (a global backward
  skip, or one forward step, produces cross-node ties) →
  `luw-tiebreak-against-third-origin-row-reached` (the tie meets a
  third-origin row, where L2 can diverge). A backward skip plus a restart
  reaches L3; no per-container skew is needed.
- Safety: `contested-rows-converge-after-quiesce` (agreement),
  `luw-final-version-has-max-commit-ts` (right winner),
  `local-overwrite-gets-later-commit-ts` (L3 at the moment of the write),
  `progress-commit-lsn-tracks-applied-commits` (L3 froze progress at HEAD;
  4e0988de removes that, so in the clock-fault image it cannot find a bug
  and is only a regression guard),
  `resolutions-rows-match-applied-outcome` (recorded decisions follow the
  rule).
- Same table, different mechanism: `luw-unchanged-toast-no-mixed-rows` (needs
  no clock fault; immune to winner changes).
- Two-phase commit: `prepared-commit-ts-matches-sent-ts` (patch 025 bumps
  the WAL commit time but `RecordTransactionCommitPrepared` stores its own
  unbumped value in `pg_commit_ts`, so the origin and its peers judge later
  conflicts with different timestamps). Joins this cluster through the same
  patch-025 hook; a global backward skip widens the gap to the size of the
  jump.
- Explained divergence: `every-divergence-explained-by-spock-records`
  attributes L2 and L3 differences on the app table under their own
  messages, a second source for the same leads with realistic traffic.

Dominance: an L3 hit makes `local-overwrite-gets-later-commit-ts` fire first
(per write, on the node with the clock problem), then
`luw-final-version-has-max-commit-ts` and
`contested-rows-converge-after-quiesce` on the same keys. An L2 hit needs
`luw-tiebreak-against-third-origin-row-reached` to have been reached and
shows up only in `contested-rows-converge-after-quiesce` (ties are not scored
by the max-ts property). The L3 consequences split "explained by L3" (key
last written by a node within N s after its restart following a backward
skip) from "unexplained". Whether L3 can fire at all depends on Antithesis
clock-skip sizes (open question); `luw-unchanged-toast-no-mixed-rows` needs
no clock and keeps this cluster non-empty when clocks are off. A 2PC
mismatch makes `contested-rows-converge-after-quiesce` fail on keys last
written by a prepared transaction with no exception row;
`prepared-commit-ts-matches-sent-ts` names the cause, and its direct check
fires without faults (TAP first). LUW oracles must not take a prepared
transaction's commit ts from the origin.

### 5. Add-node and membership (leads L4, L16, L17, L20)

Shared code: ZODAN `samples/Z0DAN/zodan.sql` Phases 3-7,
`spock_create_slot_and_read_progress`, `read_peer_progress`,
`maybe_pause_for_slot_creation`, `SpockGroupHash`.

- Outcome: `add-node-success-new-node-has-every-row` (both halves: no row
  missing, no row applied twice).
- Loss cause: `add-node-pause-held-until-progress-read` (pause self-resume,
  L4) is the live loss path at HEAD.
- Duplicate causes: `add-node-after-peer-restart-captures-every-peer` (a
  peer dropped from `read_peer_progress` after a source restart leaves n4's
  row at 0/0, so Phase 7 skips the advance and n4 re-receives that peer's
  changes) and `zodan-readd-node-progress-not-stale` (stale progress row from
  an earlier life of n4; also trips `progress-reconcile-anomaly-unreachable`
  at Phase 9). The `pg_current_wal_lsn()` fallback is unreachable on a
  successful add (regression guard).
- Regression guard: `add-node-success-has-sub-from-every-peer` (L20 closed at
  HEAD: Phase 9/10 re-raise, 3250807a).
- `progress-reconcile-anomaly-unreachable` (progress ahead of origin after
  force-set, re-add, or a table resync followed by a worker restart).
- Sync phase: `initial-sync-ends-ready-or-visibly-disabled`,
  `sync-wait-functions-honor-contract`.
- Liveness of add_node itself: `add-node-returns-within-bound` (V5; dblink
  calls with no timeouts can hang on half-open sockets) and
  `add-node-pause-released-after-caller-dies` (V3; regression guard for the
  self-resume path that `add-node-pause-held-until-progress-read` says must
  not fire while the caller is alive). The pause pair shares the
  pausing-backend PID instrumentation and is two sides of one rule: never
  self-resume while the caller lives, always self-resume once it is gone.
  Under a partition the provider-side caller backend can outlive the n4
  sync worker for about 2 h (no server TCP keepalives), so the "held" check
  fires only when that backend later reaches resume.
- Removal: `remove-node-clean-report-no-leftovers` (restated as "every
  leftover link is reported"; an unreported slot it misses also fails
  `no-orphan-slot-pins-wal-after-quiesce` unless the workload drops it).
- v2: `mixed-version-add-node-loses-nothing` repeats this cluster across
  versions.

Dominance: the loss cause implies the "every row" half of
`add-node-success-new-node-has-every-row` fails when a commit lands in the
gap; the duplicate causes imply its "one apply-audit entry" half and its new
n4 delta-counter check (a duplicate double-counts, a gap under-counts).
The whole cluster runs in its own add-node template; the pause property
needs `spock.pause_timeout = 1` and a workload-held source transaction. The cause
properties can fire without visible damage and name the mechanism when it
is visible. Kept separate on purpose.

### 6. Table sync and worker slots (leads L11, L12, L13, L15)

Shared code: `process_syncing_tables`, `wait_for_sync_status_change`,
`spock_sync_find`, `find_empty_worker_slot`, `manage_apply_workers`,
`SpockCtx->lock`, `spock_group_resource_dump`.

- `apply-never-waits-on-dead-sync-worker`, `sub-drop-vs-table-sync-no-deadlock`,
  `manager-kill-targets-only-listed-worker`, `resource-dat-dumps-serialized`,
  `exception-log-slots-never-exhausted` (apply/sync first-BEGIN claim race),
  `replication-origin-states-do-not-leak` (sync origins left by errors and
  `sub_drop`), `progress-reconcile-anomaly-unreachable`,
  `remote-transaction-all-or-nothing-per-node` (FAILED-table skip),
  `sub-show-status-reflects-apply-state` (stuck worker still "replicating"),
  `fast-shutdown-completes-within-bound` (LWLock cycle blocks shutdown).

Shared workload need: an admin-churn phase with `sub_resync_table` (default
`truncate := true`) during writes. Without it, this whole cluster is
unreached in v1. Resyncs target dedicated single-writer tables and
drop/re-create scenarios use throwaway subscriptions, so the churn does not
break the shared ledger, delta and convergence oracles.
`resource-dat-dumps-serialized` is now P1 (needs concurrent resyncs on two
subscriptions of one node).

- `sync-worker-sigterm-never-skips-catchup` (gap-fill): the consequence
  side of a SIGTERM to a sync worker in COPY or SYNCWAIT.
- `apply-never-waits-on-dead-sync-worker` now also owns the retry step
  "retried table resync reaches READY after faults stop" (absorbed
  candidate G1, "table resync under faults ends ready").

Dominance: a SIGTERM to a sync worker (from the manager bug in
`manager-kill-targets-only-listed-worker`, a fast shutdown during SYNCWAIT,
or an operator's `pg_terminate_backend`) is ignored until COPY ends, then
either skips catch-up (`sync-worker-sigterm-never-skips-catchup`: silent
drift for that table while it shows `replicating`; cassert: node
crash-restart) or error-exits into the stall of
`apply-never-waits-on-dead-sync-worker`. So a manager-kill firing can
explain a sigterm-skip firing, and both can explain a later ledger or
convergence failure confined to one resynced table. Fast shutdown reaches
the skip without the manager bug, so the sigterm property can fire alone.

### 7. Operator lifecycle

- Subscriptions: `sub-disable-enable-cycle-loses-and-duplicates-nothing`,
  `enabled-subscription-always-has-provider-slot`,
  `no-orphan-slot-pins-wal-after-quiesce`, and (v2/colliding-names)
  `provider-slot-owned-by-one-subscription`. All four are about the
  one-slot-per-subscription link between a provider slot and its owner; they
  share the same slot-drop code in `spock_drop_subscription` and sync cleanup.
- Read-only mode: `readonly-toggle-resumes-without-loss`,
  `readonly-all-never-commits-remote-txn` (v2/slot-groups only: unreachable
  without slot groups),
  `readonly-local-keeps-inbound-ddl-flowing`,
  `terminate-active-transactions-never-discards-inbound`.
- Restart and shutdown: `graceful-restart-preserves-exactly-once`,
  `fast-shutdown-completes-within-bound`, `crashed-node-returns-to-streaming`,
  `apply-worker-restarted-within-bound-after-exit`, `worker-respawn-rate-bounded`.

- Recovery steps: `operator-recovery-steps-restore-replication` (re-enable,
  drop and re-create after an interrupted initial sync, add_node retry after
  `remove_node`; the resync step is asserted by
  `apply-never-waits-on-dead-sync-worker`). Its failures explain a strict
  round that never reaches full health (cluster 12).

`graceful-restart-preserves-exactly-once` separates "restart is broken" from
"crash redo is broken" (cluster 1): if the crash-based properties fail and
this one passes, the cause is redo, not the restart path.

### 8. Fixed-capacity shared tables and leftovers

- Never-shrinking tables: `exception-log-slots-never-exhausted` (reset by
  postmaster restart), `progress-hash-capacity-survives-node-churn` (persisted
  in `resource.dat`, not reset), `replication-origin-states-do-not-leak`
  (checkpointed, not reset).
- Leftovers after quiesce: `no-orphan-slot-pins-wal-after-quiesce`,
  `spock-connections-match-subscriptions-after-quiesce`,
  `replay-spill-file-lifecycle`, `apply-worker-memory-bounded`.

Shared workload need: fresh-name churn in the separate `v2/small-capacity`
configuration with node kills off (exception-log slots need fresh
subscription names; the progress hash needs fresh node names); the counting
routes are cheaper in TAP. `apply-worker-memory-bounded` belongs to a soak
run or `v2/standby`, not v1. Note the two progress-hash consumers:
`zodan-readd-node-progress-not-stale` (stale entries reused) and
`progress-hash-capacity-survives-node-churn` (stale entries fill the table)
come from the same "entries never deleted" design.

### 9. Protocol and progress values

- `apply-stream-framing-and-lsn-order` (first SUT-instrumentation batch),
  `proto5-replay-reparses-startup-message`,
  `progress-insert-lsn-never-ahead-of-provider` (P2; the workload
  consequence check of the proto5 misparse),
  `progress-commit-lsn-tracks-applied-commits`,
  `progress-reconcile-anomaly-unreachable`,
  `no-change-applied-on-its-origin-node` (ORIGIN message handling).
- v2: `mixed-version-mesh-applies-exactly-once`,
  `rolling-upgrade-node-restart-loses-nothing` exercise the protocol-4
  branches of the same reader/writer.

### 10. Value fidelity and apply session state

- `replicated-values-mean-same-on-every-node`,
  `luw-unchanged-toast-no-mixed-rows` (both: a row no single transaction
  wrote, or a value that means something else, with nothing logged),
  `cross-pg-major-links-replicate-identically` (v2 form of the text path).
- `apply-search-path-not-leaked-across-transactions`,
  `apply-identity-restored-after-queued-sql`: share the canary
  `ENABLE REPLICA` trigger that records `search_path`, `current_user` and
  `session_replication_role`.
- `replicated-values-mean-same-on-every-node` (domain/OID cases),
  `apply-search-path-not-leaked-across-transactions` and
  `luw-unchanged-toast-no-mixed-rows` are expected to fire deterministically;
  confirm with TAP first.

### 11. Audit tables

`exception-log-matches-discarded-transactions`,
`insert-conflict-recorded-in-resolutions`,
`resolutions-rows-match-applied-outcome`. They make the "every difference is
explained" oracle, `every-divergence-explained-by-spock-records`, trustworthy:
if one of them fails, a difference the oracle counts as explained may rest on
a wrong row, so triage the audit property first. The app table also feeds
them more traffic (natural `update_missing` drops, `delete_exists` and
`delete_missing` rows). Update/update conflicts are never recorded by
design, so `contested-rows-converge-after-quiesce` and
`luw-final-version-has-max-commit-ts` must compare nodes directly rather than
rely on these tables. `exception-replay-never-reruns-committed-transaction`
can make the exception log claim a discard that did not happen, which would
show up here as a row for an applied transaction.

### 12. Oracle health, final round and harness guards

- `convergence-check-runs-after-faults` (rounds ran in hard states),
  `strict-final-round-has-no-exemptions` (one round with no state
  exemptions in a fully healthy cluster), `operator-recovery-steps-restore-replication`
  (the recovery that gets the cluster to full health).
- Harness guards that keep the other oracles meaningful:
  `quiet-link-never-hits-idle-timeout` (timeouts that do not churn healthy
  links, so liveness bounds mean something) and
  `walsender-never-joins-slot-group` (node names that do not turn on slot
  groups).

Dominance: the strict round aggregates the convergence checks of clusters
1, 2, 4, 6 and 11; a failure there names the check, and the owning
property's message is the one to triage. Its zero-exemption `Sometimes`
dominates the "ran with all subscriptions enabled" marker of
`convergence-check-runs-after-faults`. If the strict round does not reach
full health, the failure belongs to `operator-recovery-steps-restore-replication`.
A firing of `walsender-never-joins-slot-group` invalidates every ledger
result in that run; a firing of `quiet-link-never-hits-idle-timeout` makes
bounded liveness failures in the same timeline suspect.

## Fault-requirement groups

- **Node termination with PGDATA kept**: clusters 1, 4 (with clock), parts of
  5 (`add-node-after-peer-restart-captures-every-peer`,
  `progress-reconcile-anomaly-unreachable`), `crashed-node-returns-to-streaming`,
  `enabled-subscription-always-has-provider-slot`,
  `feedback-never-confirms-undurable-apply`.
- **Clock skips** (global in Antithesis; backward skips are enough; not
  stopped by quiet periods, so bounded-time checks must detect them):
  cluster 4 (including `prepared-commit-ts-matches-sent-ts`),
  `every-divergence-explained-by-spock-records` (L2/L3 attribution),
  `apply-worker-restarted-within-bound-after-exit`,
  `apply-search-path-not-leaked-across-transactions` (forward step triggers the
  cleanup query).
- **Single-worker graceful exits (test command)**: cluster 2,
  `feedback-never-confirms-undurable-apply`,
  `sub-disable-enable-cycle-loses-and-duplicates-nothing`,
  `graceful-restart-preserves-exactly-once`,
  `fast-shutdown-completes-within-bound`,
  `sync-worker-sigterm-never-skips-catchup` (graceful stop during resync),
  `sub-disable-error-ends-disabled-and-recorded`,
  `add-node-pause-released-after-caller-dies` (terminate the pausing
  backend). Postmaster SIGKILL wipes shared memory and skips these paths.
- **Table resyncs** (admin churn): cluster 6 (including
  `sync-worker-sigterm-never-skips-catchup`),
  `operator-recovery-steps-restore-replication`,
  `exception-log-slots-never-exhausted` (race),
  `remote-transaction-all-or-nothing-per-node` (FAILED tables).
- **Workload-driven crash helper** (action, then postmaster kill after a
  random 0-300 ms delay; random node termination rarely lands in these
  windows): `ledger-row-applied-exactly-once-per-peer`,
  `delta-counter-equals-committed-increments`,
  `causally-deleted-row-stays-deleted`,
  `sync-event-barrier-survives-subscriber-restart`,
  `feedback-never-confirms-undurable-apply`,
  `redelivered-ddl-not-turned-into-exception`,
  `enabled-subscription-always-has-provider-slot`,
  `add-node-after-peer-restart-captures-every-peer`,
  `local-overwrite-gets-later-commit-ts`, `luw-final-version-has-max-commit-ts`.
- **Partitions / pauses only** (reachable even with kills and clocks off):
  `luw-unchanged-toast-no-mixed-rows`, `add-node-pause-held-until-progress-read`,
  `add-node-success-has-sub-from-every-peer`,
  `mesh-barriers-complete-after-partition-heal`,
  `remove-node-clean-report-no-leftovers`,
  `insert-race-resolved-not-discarded`, `sync-event-barrier-implies-visible`,
  `add-node-returns-within-bound` (partition plus a peer kill),
  `every-divergence-explained-by-spock-records` (latency and partitions
  order the cross-node writes).
  (For the add-node pause property a workload-held source transaction, not
  a container pause, opens the window; thread pausing does not reach the
  core windows of the last two or of snapbuild while core is uninstrumented.)

## Placement (evaluation, 2026-10-13)

- **Expected to fire deterministically — confirm with TAP first, then gate
  out of the main template:** `crash-redo-leaves-no-node-id-origin-state`,
  `apply-cancel-retried-not-discarded`,
  `terminate-active-transactions-never-discards-inbound`,
  `readonly-local-keeps-inbound-ddl-flowing`,
  `apply-search-path-not-leaked-across-transactions`,
  `luw-unchanged-toast-no-mixed-rows`,
  `replicated-values-mean-same-on-every-node` (domain/OID cases),
  `remove-node-clean-report-no-leftovers`,
  `proto5-replay-reparses-startup-message`, `prepared-commit-ts-matches-sent-ts`
  (direct check), `sync-standby-hold-freezes-provider-confirmed-flush`
  (mechanism 1); the multi-read L27 case of
  `sub-disable-error-ends-disabled-and-recorded` is reproduced in TAP first.
  Build step: `apply-survives-provider-clock-ahead` (image includes 4e0988de).
- **Templates and configurations:** main; classifier (cancel/terminate);
  add-node and node churn; `v2/small-capacity` (kills off); `v2/slot-groups`
  (`readonly-all-never-commits-remote-txn`); soak or `v2/standby`
  (`apply-worker-memory-bounded`, `promoted-subscriber-standby-has-every-confirmed-txn`);
  `v2/phantom-sync-standby` (`sync-standby-hold-freezes-provider-confirmed-flush`);
  the `sub_disable` run variant (`sub-disable-error-ends-disabled-and-recorded`);
  the documented-defaults variant (second home of
  `quiet-link-never-hits-idle-timeout`); plus the existing `v2/mixed-version`,
  `v2/mixed-pg-major`, `v2/cascade`, `v2/colliding-names`. The add-node
  template also hosts `add-node-returns-within-bound` and
  `add-node-pause-released-after-caller-dies`.
