---
sut_path: /home/msharp/dev/pgedgea/spock
commit: 69d9228f5df363761dc3ae6eebf7e2fcfe49b8e5
updated: 2026-10-13
external_references: []
---

# Evaluation — Lens 2: Coverage Balance

Question: is this the right set of 75 properties for the risks in
`sut-analysis.md` and the components in `deployment-topology.md`?

Inputs read in full: `property-catalog.md`, `sut-analysis.md`,
`deployment-topology.md`; `property-relationships.md` (fault groups);
targeted greps over `properties/*.md`.

## 1. Risk map vs property count

Ranks from `sut-analysis.md` §13. "Props" counts properties whose main target
is that area (a property can count once only).

| Rank | Area (leads) | Props | Assessment |
|---|---|---|---|
| 1 | Exception classifier + shmem marker (L5, L7, L8, L14, L15, L23, L27) | 11 (Category C plus `exception-log-matches-discarded-transactions`) | Well covered. L8 (DISCARD) deliberately excluded. L27 only mentioned inside two evidence files, no assertion of its own. |
| 2 | Origin/LSN bookkeeping across crashes (L1, L18, L19, L9) | 9 (`ledger-row-applied-exactly-once-per-peer`, `delta-counter-...`, `causally-deleted-...`, `redelivered-ddl-...`, `crash-redo-...`, `sync-event-barrier-survives-...`, `replication-origin-states-...`, `feedback-never-confirms-...`, `forwarded-origin-...`) | Heavy, and justified by L1 being code-confirmed. Concentration risk: see F3. L9 has no v1 property. |
| 3 | ZODAN add_node + pause + peer progress (L4, L17, L20, L16) | 8 (Category E minus remove_node, plus `progress-reconcile-...`) | Good on safety. No bounded-completion liveness for add_node itself (V5). No delta-counter check on n4 (F5). |
| 4 | LUW, clocks, equal ts (L2, L3) | 6 (Category D minus toast) + 2 audit | Proportionate, but every L2/L3 property depends on clock faults plus the SPOC-688 image (F4). |
| 5 | Multi-upstream races (L6) | 2 (`insert-race-...`, `insert-conflict-recorded-...`) | Thin. L6c (retry loop with no wait vs docs' "short waits") has no property. |
| 6 | Table/initial sync (L11, L12, L13) | 5 | Adequate, but most need an admin-churn phase whose inclusion in v1 is still open. |
| 7 | Worker lifecycle and pacing (L21, L22, L23) | 4 | Adequate. |
| 8 | Connection-loss detection (L25, L26) | 2 (`mesh-barriers-...`, `sub-show-status-...`) | Adequate; L25 is deterministic. |
| 9 | Slot groups (L10, L30) | 0 in v1 | Deliberately out of scope; acceptable given workload avoids the names. |
| 10 | Failover / standbys (L9, S9) | 0 standalone (partial inside 2) | Gap among v2 topologies (F6). |
| 11 | Progress persistence (`resource.dat`, reconcile) (L16, L17) | 5 (`resource-dat-...`, `progress-hash-...`, `progress-reconcile-...`, `progress-insert-lsn-...`, `progress-commit-lsn-...`) | Over-weighted relative to rank (F8). |
| 12 | Spill replay queue (L29) | 1 | Proportionate. |

Claimed guarantees (§6, §7) with no property:

- **S2 "every inter-node difference is explained"** — no property (F1).
- **S7 SUB_DISABLE resume** — only inside `interrupted-exception-replay-still-records-txn`, and only when replay is interrupted; the `sub_disable` run variant is "possible", not planned (F2).
- **S9 failover slots lose nothing** — none (F6).
- **V3 pause bounded after caller dies** — none (F9).
- **V5 add_node completes or fails within a bound** — none (F7).
- S11 sequences — correctly not asserted.

## 2. Assertion-type balance

From the priority table: 64 Safety, 9 Liveness, 2 Reachability.
Primary assertion column: `Always` 47, `Always (bounded)` 7, `Unreachable` 8,
mixed Always/Unreachable 7, `AlwaysOrUnreachable` 3, `Sometimes` 2,
`Sometimes + Always` 1.

- Only 3 properties have `Sometimes` as a primary check
  (`luw-tiebreak-against-third-origin-row-reached`,
  `clock-step-forward-makes-commit-ts-ties`, `convergence-check-runs-after-faults`).
  Most reachability guidance lives in companion markers: about 16 named as
  SUT-side `Sometimes`/`Reachable`, and about 40 `Sometimes(` mentions overall.
  Most of those companions are in `spock.so` and need the C SDK work.
  If SUT instrumentation lands late, the catalog has almost no
  workload-side evidence that the dangerous states were reached (F10).
- Liveness is 9/75. Given that §7 lists seven liveness claims (V1-V7) and
  the analysis stresses hangs (L11, L12, L13, L20, L26, L30), the share is
  low but each main claim except V3 and V5 has one. Fine apart from F7/F9.

## 3. Component distribution (deployment topology)

| Component | Coverage |
|---|---|
| n1-n3 apply worker | Most of the catalog. |
| n1-n3 sync worker | 5-6 properties, mostly admin-churn dependent. |
| n1-n3 manager/supervisor | `worker-respawn-rate-bounded`, `apply-worker-restarted-...`, `manager-kill-...`, `fast-shutdown-...`. Adequate. |
| Provider side (walsender + `spock_output`) | Only two SUT-side markers in the output plugin (`no-change-applied-...` in `pg_decode_begin_txn`, `apply-stream-framing-...` in `pg_decode_message`). No property checks repset/row filtering, the origin filter (other than echo), or TRUNCATE 'T' messages. §8 names `spock_output_plugin.c`, `spock_proto_native.c`, `spock_queue.c` as "quiet but on the data path and untested under faults" (F11). |
| n4 spare / ZODAN | Good (8 properties). |
| Workload client | `convergence-check-runs-after-faults` is a good harness-health guard. |

## 4. Fault-dependency concentration

Tally of the "Key fault" column (a property can count in several rows):
node kill 21, partition 18, worker exit 12, pause 10, clock 9, latency 6,
admin churn 4, readonly 3, graceful stop 2.

- **18 properties (4 of them P0)** name worker exit, graceful stop, cancel or
  admin churn as the fault that makes them fail: `committed-ledger-row-...`,
  `delta-counter-...`, `apply-cancel-...`, `feedback-never-confirms-...` (P0);
  plus `remote-transaction-...`, `graceful-restart-...`,
  `terminate-active-...`, `exception-replay-only-...`,
  `exception-replay-never-reruns-...`, `interrupted-exception-replay-...`,
  `sub-disable-enable-...`, `sub-drop-vs-table-sync-...`, `manager-kill-...`,
  `exception-log-matches-...` (P1); and 4 P2/P3. The catalog says these
  helpers "are not built yet". Nothing in the topology file lists them as a
  required deliverable (it calls them a fallback / custom fault). If they
  slip, the rank-1 risk area runs with only postmaster kills, which wipe the
  shmem marker and hide L5/L7 (F2).
- 21 need node termination with PGDATA kept; 9 need clock faults plus the
  SPOC-688 image. Both are open tenant questions (F4).

## 5. Findings

### F1 (catalog-wide) No "explained divergence" property; all data oracles run on restricted tables

- Concern: S2 ("non-resolvable conflicts are recorded"; every difference
  after quiescence is explained by `exception_log` or `resolutions`) is the
  main user-facing claim for a realistic workload, and the catalog mentions
  that oracle twice (catalog lines 439, 1394) but never defines it. Every
  data property uses a narrowed table: insert-only ledger, update-only
  contested rows, causal-only deletes, PK-only dupkeys. The documented
  divergence cases (no tombstones, cross-origin `update_missing`,
  delete/update) are excluded from the workload instead of being scored.
- Evidence: §6 S2, §12 "Expected divergence"; catalog Category J covers row
  accuracy of the audit tables but not completeness against actual
  differences; `exception-log-matches-discarded-transactions` checks
  discarded transactions it already knows about, not unexplained diffs.
- Suggested action: add one property on a mixed INSERT/UPDATE/DELETE table
  written from all nodes: after quiescence every per-key difference between
  nodes has a matching `exception_log` row (or a documented `delete_exists`
  resolution) on the node that differs. This also covers delete conflict
  paths, which today are only reached through `resolutions-rows-match-applied-outcome`.

### F2 (catalog-wide) Rank-1 area depends on helpers that the topology does not commit to

- Concern: 18 properties, including 4 P0, need single-worker graceful exits,
  cancels, `pg_ctl stop -m fast` or admin churn, driven by test commands that
  do not exist. `deployment-topology.md` lists them only as a fallback
  ("Custom faults could also SIGKILL..."), and SIGKILL is the wrong tool (it
  crash-restarts the instance).
- Evidence: catalog summary line 40-43; topology "Fault Requirements"
  fallback paragraph; tally in section 4.
- Suggested action: move the worker-exit/cancel/terminate/fast-stop helper
  and the node-container supervisor loop into the topology as required
  components, not fallbacks. Also plan the `sub_disable` exception-mode run
  variant explicitly (S7, L27 have no other route).

### F3 (catalog-wide) Five P0/P1 properties hinge on one unanswered question

- Concern: `ledger-row-applied-exactly-once-per-peer`,
  `delta-counter-equals-committed-increments`, `causally-deleted-row-stays-deleted`,
  `redelivered-ddl-not-turned-into-exception`, `crash-redo-leaves-no-node-id-origin-state`
  (plus parts of `sync-event-barrier-survives-subscriber-restart` and
  `replication-origin-states-do-not-leak`) all fire on the same L1 mechanism.
  If the team answers "at-least-once is accepted", most become doc findings at
  once, and the crash-recovery portfolio thins to `crashed-node-returns-to-streaming`
  and `graceful-restart-preserves-exactly-once`.
- Evidence: catalog Open Questions "Exactly-once vs at-least-once".
- Suggested action: keep them, but mark them as one cluster in triage so one
  L1 hit is not counted as five bugs; add a bounded at-least-once variant
  (like `forwarded-origin-advance-no-double-apply` already does: duplicates
  per crash at most the unconfirmed window) so the cluster still guards
  something if the answer is at-least-once.

### F4 (catalog-wide) Clock-dependent LUW properties share a single gate

- Concern: 9 properties need clock faults; on the HEAD cassert image every
  backward skip trips the Assert in `apply-survives-provider-clock-ahead` and
  crash-loops every node, so all of rank-4 coverage depends on building from
  main + 4e0988de and on clock jitter being enabled for the tenant.
- Evidence: catalog summary lines 33-39; topology Open Questions.
- Suggested action: record in the topology which image runs clock faults;
  keep one LUW property that needs no clock (`luw-unchanged-toast-no-mixed-rows`
  already qualifies, `contested-rows-converge-after-quiesce` partly) at P0 so
  rank 4 is not empty when clocks are off.

### F5 (property-specific: `add-node-success-new-node-has-every-row`, `delta-counter-equals-committed-increments`) add_node x delta apply not checked

- Concern: cross-cutting. The add_node property checks the insert-only
  ledger only; the delta property checks "every mesh node" and its evidence
  file mentions n4 only in passing. Delta columns are where a COPY-snapshot
  boundary error is visible as a wrong number (copied value plus a re-received
  increment double-counts; a missed one under-counts), and copied rows carry
  `'epoch'` timestamps so every later remote change wins.
- Evidence: grep of both evidence files; §2.5 delta non-idempotent; §11.10.
- Suggested action: extend the add_node invariant to include the counters
  table on n4 (value == initial + all committed increments), with in-flight
  increments on all three nodes during add_node.

### F6 (catalog-wide) v2 topologies are unbalanced: mixed-version has 3 properties, standby has none

- Concern: §6 S9 is one of the strongest written claims ("resumes ... with no
  data loss"), L9 is code-checked by two focuses, and PG18 native slot sync
  is the target. Yet `v2/standby` has no standalone property; the hold-list
  and sync-standby check are buried inside `feedback-never-confirms-undurable-apply`
  and `apply-worker-memory-bounded`. `v2/mixed-version` has three P2
  properties and `v2/mixed-pg-major` one.
- Suggested action: add one `v2/standby` property ("after promoting the
  subscriber's sync standby, no provider transaction confirmed by the old
  primary is missing"), so the v2 plan has a concrete target for L9.

### F7 (property-specific: missing) No bounded-completion liveness for add_node itself

- Concern: V5 says add_node returns or raises within a bound derived from
  `spock.sync_timeout`. L20 names dblink calls with no timeout (a paused peer
  hangs add_node) and wall-clock budgets. `initial-sync-ends-ready-or-visibly-disabled`
  covers only the src->n4 sync, not the orchestrator.
- Suggested action: add `add-node-returns-within-bound` (Liveness,
  `Always (bounded)`): after faults stop, the `CALL spock.add_node` session
  returns or errors within `k * sync_timeout`; companion `Sometimes` that a
  peer was paused during a dblink phase.

### F8 (catalog-wide) spock.progress accuracy is over-weighted for a monitoring value

- Concern: five properties target `spock.progress`/`resource.dat` values
  (`progress-insert-lsn-never-ahead-of-provider` P1,
  `progress-reconcile-anomaly-unreachable` P2, `progress-commit-lsn-tracks-applied-commits` P3,
  `progress-hash-capacity-survives-node-churn` P2, `resource-dat-dumps-serialized` P2),
  plus `proto5-replay-reparses-startup-message` whose consequence check is
  progress-insert-lsn. The analysis ranks this area 11 of 12 and code
  comments call it monitoring only.
- Suggested action: keep `resource-dat-dumps-serialized` (restartability) and
  `progress-hash-capacity-...`; consider folding `progress-insert-lsn-...`
  into `proto5-replay-...` and lowering it to P2, since its only known cause
  is that misparse.

### F9 (property-specific: missing) Pause flag left set by a dead caller (V3)

- Concern: §7 V3 and L4(e): a dead `pause_apply_workers` caller leaves the
  instance-wide flag until each worker's `pause_timeout`; with `PGC_USERSET`
  this is per-worker session value. No property bounds how long apply stays
  paused after an orchestrator kill. `add-node-pause-held-until-progress-read`
  checks the opposite direction (resumed too early).
- Suggested action: small liveness: after killing the add_node session
  between pause and resume, every provider apply worker commits again within
  `pause_timeout + margin`.

### F10 (catalog-wide) Few workload-side Sometimes; reachability relies on SUT instrumentation

- Concern: only 3 properties have `Sometimes` as a primary check. The many
  companion `Sometimes`/`Reachable` markers are mostly in C and need the SDK
  in `spock.so`. Key fault-state markers that a workload can emit on its own
  are missing, e.g. "node killed within N s after an apply burst with no
  checkpoint since" (the L1 window), "provider paused longer than
  `pause_timeout` during add_node slot creation" (L4), "cancel landed while
  apply was inside a remote transaction".
- Suggested action: for each P0 safety property, add one workload-side
  `Sometimes` that shows its triggering fault state was reached, independent
  of SUT instrumentation.

### F11 (catalog-wide) Provider-side code and some DML kinds have no properties

- Concern: TRUNCATE ('T' message, `pg_decode_truncate`) has no property;
  repset membership changes under load (`repset_add_table`, `sub_add_repset`,
  `sub_remove_repset`) and repset filtering have none; DDL-then-DML ordering
  from one origin (§2.7: queued in the same transaction) has none.
  `spock_queue.c` and `spock_output_plugin.c` are named as untested under faults.
- Suggested action: lower priority than F1-F7. Add one P2 property for
  "a table added to a repset under load ends identical on all nodes" and
  allow TRUNCATE in a quiesced phase with a convergence check; DDL ordering
  can ride on `redelivered-ddl-not-turned-into-exception` with an
  ADD COLUMN followed by DML using the column.

### F12 (property-specific: `insert-race-resolved-not-discarded`) L6c retry loop

- Concern: `update_missing` retries call a wait that returns at once
  (code-checked), contrary to the documented "short waits". No property; the
  only consequence today is documented `update_missing` divergence, which the
  workload avoids.
- Suggested action: optional SUT-side `Sometimes("update_missing retry found
  the row on a later attempt")` to show whether retries ever help; if never,
  that is a finding about the docs.

## 6. Passes

- Rank 1-3 risks have dense, layered coverage (SUT-side `Unreachable` at the
  source plus workload outcome checks).
- Every code-confirmed lead with a reachable v1 path (L1, L4, L5, L7, L11,
  L12, L14, L16, toast merge, readonly=local DDL, search_path leak) has at
  least one property.
- Liveness claims V1, V2, V4, V6, V7 each have one bounded property.
- `convergence-check-runs-after-faults` guards against vacuous passes, and
  barrier correctness is treated as a foundation.
- Over-investment is limited: low-value areas are mostly at P2/P3 already
  (`worker-respawn-rate-bounded`, `apply-identity-restored-...`,
  `progress-commit-lsn-...`).
- Scope exclusions (slot groups, sequences, discard mode, failover) are
  stated with reasons.

## 7. Uncertainties

- Counts are from the catalog's summary table and keyword greps; some evidence
  files may cover more than their table row shows (e.g. n4 delta checks
  described in prose).
- Whether v1 includes the admin-churn phase (resyncs) changes the weight of
  rank 6 by about five properties.
- F1's oracle needs a precise rule for which differences each `exception_log`
  row explains; feasibility not checked here.
