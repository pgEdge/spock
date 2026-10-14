---
sut_path: /home/msharp/dev/pgedgea/spock
commit: 69d9228f5df363761dc3ae6eebf7e2fcfe49b8e5
updated: 2026-10-13
external_references: []
---

# Evaluation Synthesis

## Summary

Four lenses (`antithesis-fit.md` AF, `coverage-balance.md` CB,
`implementability.md` IM, `wildcard.md` W) produced 82 findings with an
action attached (AF 22, CB 12, IM 30, W 18, counting each property-specific
item once). After merging duplicates across lenses there are 56 entries;
some findings feed both a refinement and a bias:

| Category | Count | Action |
|---|---|---|
| Refinement | 40 | Applied to `property-catalog.md`, `properties/*.md`, `property-relationships.md` and `deployment-topology.md` |
| Gap | 12 | 10 handed to gap-fill agents (topics a-c); 2 extra gaps (E1, E2) investigated in the merge step (see "Second pass (gap-fill)") |
| Bias | 4 | Collected for the human with the judgement needed |

Lens passes (no action) are not counted. Priorities after refinement: P0 12,
P1 30, P2 27, P3 6; 66 properties in v1, 9 in other topologies or
configurations. After the gap-fill merge and its second pass: 88 properties,
P0 13, P1 35, P2 32, P3 8; 76 in v1, 12 in other topologies or
configurations.

## Refinements (applied)

Lens IDs: AF-CW1 means antithesis-fit catalog-wide finding 1; "prop" means a
property-specific finding in that lens.

### Catalog-wide

| # | Finding | Lenses | What changed, where |
|---|---|---|---|
| R1 | About a dozen properties fire deterministically on the first trigger and will flood the main template | AF-CW1, W2, AF prop (TAP territory) | Catalog Summary and each property: "Placement: Expected to fire deterministically — confirm with TAP first, then gate out of the main template" on `crash-redo-leaves-no-node-id-origin-state`, `apply-cancel-retried-not-discarded`, `terminate-active-transactions-never-discards-inbound`, `readonly-local-keeps-inbound-ddl-flowing`, `apply-search-path-not-leaked-across-transactions`, `luw-unchanged-toast-no-mixed-rows`, `replicated-values-mean-same-on-every-node` (domain/OID), `remove-node-clean-report-no-leftovers`, `proto5-replay-reparses-startup-message`; `apply-survives-provider-clock-ahead` marked as a build step. Relationships: new "Placement" section; cluster 2 notes |
| R2 | One L1/L3 hit blinds the consequence oracles to second causes | W2, CB-F3, AF-CW1 | Messages split into "explained by L1/L3" vs "unexplained" in `ledger-row-applied-exactly-once-per-peer`, `delta-counter-equals-committed-increments`, `causally-deleted-row-stays-deleted`, `redelivered-ddl-not-turned-into-exception`, `sync-event-barrier-survives-subscriber-restart` (crash vs clean), `contested-rows-converge-after-quiesce`, `luw-final-version-has-max-commit-ts`, `local-overwrite-gets-later-commit-ts`; `committed-ledger-row-reaches-every-node` splits "explained by a recorded classifier error" vs "no exception row". Relationships clusters 1 and 4 |
| R3 | Poison-transaction properties and "no exception_log rows" properties contradict each other in one run | AF-CW2, IM-CW6, W odd things | Assumption 2: expected-exception registry (origin, remote xid, table), poison and `update_missing` writes on their own tables; "no rows" means "none outside the registry" in `terminate-active-...`, `sub-disable-enable-...`, `graceful-restart-...`, `apply-cancel-...`, `readonly-toggle-...`, `rolling-upgrade-...`, `interrupted-exception-replay-...`, `exception-log-matches-...`. SUT-side conflict-free `Unreachable` in `committed-ledger-...` guarded by a placeholder GUC (IM-CW2) |
| R4 | Properties needing a crash at a workload-chosen moment rarely get it from random node termination | IM-CW4, AF-CW3 | Assumption 6 and per-property notes: workload-driven crash helper (action + kill after random 0-300 ms) for `ledger-row-...`, `delta-counter-...`, `causally-deleted-...`, `sync-event-barrier-survives-...` (scripted sequence), `feedback-never-confirms-...`, `redelivered-ddl-...`, `enabled-subscription-...`, `add-node-after-peer-restart-...`, `local-overwrite-...`, `luw-final-...`, `exception-replay-never-reruns-...` (cancel during slot creation). Relationships: new fault group. Topology: required helper |
| R5 | Worker-exit / graceful-stop helpers and the node supervisor are listed only as fallbacks | CB-F2, IM-CW3, W5 | Topology: node wrapper loop, `stop_signal: SIGINT`, `ps`, SQL signal routes (`backend_type`, `COPY TO PROGRAM 'kill -SIG pid'`), node-container `pg_ctl`/kill commands, all marked required. Catalog Summary, Assumption 6, `graceful-restart-...`, `fast-shutdown-...` |
| R6 | There is no Antithesis C SDK | IM-CW1 | Topology SDK section rewritten (C++ shim with `extern "C"` wrappers, or fallback JSONL writer; declare all at `_PG_init`); catalog Assumption 10 and file-level open question |
| R7 | `HASH_ENTER_NULL` changes shipped behaviour; template-guarded assertions need a mode flag | IM-CW2 | `progress-hash-capacity-survives-node-churn` uses a count check; placeholder GUC `antithesis.conflict_free` (catalog, topology) |
| R8 | Admin churn (resync truncate, drop/re-create) breaks the shared oracles | IM-CW5 | Assumption 5: dedicated single-writer resync tables, throwaway subscriptions, oracle exclusions; notes in `remote-transaction-all-or-nothing-...`, `sync-wait-functions-...`, `sub-drop-vs-table-sync-...`, `enabled-subscription-...`, `apply-never-waits-...`, `resource-dat-...`; relationships cluster 6 |
| R9 | Workload cannot read server logs; `exception_log` has no SQLSTATE | IM-CW7 | Topology: `logging_collector`, `lc_messages = 'C'`, `pg_read_file`. SQLSTATE lists rewritten as message text in `redelivered-ddl-...` and `readonly-local-...`; log notes in `worker-respawn-...`, `replication-origin-...`, `remove-node-...`, `apply-survives-...` |
| R10 | Settings disagree (60 s vs '5min'); idle timeout at the keepalive boundary; checkpoints via `max_wal_size`; small capacity mixed into v1 | IM-CW8, W1, W odd things | Topology and Assumption 4: `wal_sender_timeout = 60s` with `apply_idle_timeout = 120s` (above `wal_sender_timeout/2`, `src/spock_apply.c:3548-3562, 3686`), one documented-defaults variant, sut-analysis §15 '5min' reconciled; large `max_wal_size`; `v2/small-capacity` as its own configuration with kills off, capacity 32 otherwise. Bounds updated in `mesh-barriers-...`, `convergence-check-...` and seven evidence files that said 30 s |
| R11 | Thread pausing cannot stretch windows inside core PG; core patch areas uninstrumented | IM-CW9, W6 | Notes in `sync-event-barrier-implies-visible` (fault column now CPU modulation), `insert-race-...`, `add-node-pause-...`, `crash-redo-...`, `local-overwrite-...`, `clock-step-...`. Topology: optional test-only PG patch with SDK markers in `xact_redo_commit` and the patch 025 hook |
| R12 | Clock-skip size decides whether L3 can fire | IM-CW10 | New open question in `local-overwrite-...` and `luw-final-...` (catalog and evidence); topology question and libfaketime per-node offset custom fault |
| R13 | ZODAN runs are long; re-add needs n4 cleanup and roles | IM-CW11 | Add-node template; `zodan-readd-...` re-add steps (`samples/Z0DAN/zodan.sql:1577-1595`) and zodan.sql marker listed as SUT change; topology n4 section |
| R14 | Workload must tell planned restarts, kills and fresh boots apart | IM-CW12 | Wrapper boot counter and last-exit kind; `system_identifier` comparison (topology, Assumption 6, `crashed-node-...`, `graceful-restart-...`) |
| R15 | Page-cache behaviour of node termination decides reachability of short-file bugs | W7 | New open question in `resource-dat-...`; `crashed-node-...` question now asks both halves; topology and catalog open questions |
| R16 | Few workload-side `Sometimes` showing triggering fault states | CB-F10 | Workload-side `Sometimes` added to `committed-ledger-...`, `ledger-row-...`, `apply-cancel-...`, `add-node-pause-...`, `crash-redo-...` |
| R17 | `spock.progress` accuracy over-weighted | CB-F8 | `progress-insert-lsn-never-ahead-of-provider` lowered P1 to P2 and described as the consequence check of `proto5-...` (kept separate as a v4 guard) |
| R18 | `spock.resolutions` cleanup can delete rows oracles read | W14 | `spock.resolutions_retention_days = 0` (topology, Assumption 2); notes in `ledger-row-...`, `insert-conflict-...`, `resolutions-rows-...` |
| R19 | Several databases per instance not modelled | W12 | Added to catalog "Out of scope" |
| R20 | Clock gate needs an image decision | CB-F4, IM prop | Topology "Image builds": clock-fault image is main + 4e0988de or non-cassert |
| R21 | L9 and hold-list growth reachable without a standby container | W8 | Topology optional phantom sync-standby configuration (TAP first); notes in `feedback-...`, `apply-worker-memory-...` |

### Property-specific

| # | Property | Lenses | Change |
|---|---|---|---|
| R22 | `ledger-row-applied-exactly-once-per-peer`, `no-change-applied-on-its-origin-node`, `apply-search-path-...`, `apply-identity-...` | IM prop, W odd things | "`ENABLE ALWAYS` trigger that fires only under replica" replaced with `ENABLE REPLICA` (catalog, Assumption 2, evidence, relationships cluster 10) |
| R23 | `add-node-pause-held-until-progress-read` | AF prop, IM prop | `spock.pause_timeout = 1` and a workload-held xid-assigned source transaction across Phase 5 are required; container pause noted as ineffective; topology config |
| R24 | `resource-dat-dumps-serialized` | AF prop | Raised to P1 (race plus crash timing TAP cannot place; node will not restart) |
| R25 | `readonly-all-never-commits-remote-txn` | AF prop, IM prop | Moved to `v2/slot-groups` (no wait in v1, `src/spock_apply.c:301-312`); companion `Sometimes("handle_commit reached with spock.readonly=all")` |
| R26 | `apply-worker-memory-bounded` | AF prop | Moved to soak / `v2/standby` |
| R27 | `progress-commit-lsn-tracks-applied-commits` | IM prop | Marked unable to find a bug once 4e0988de is in the image; SUT-side site absent in patched code; regression guard only |
| R28 | `apply-survives-provider-clock-ahead` | W odd things, IM prop | Lowered P0 to P2 (build step, regression guard); merge check recorded |
| R29 | `add-node-success-new-node-has-every-row` | CB-F5 | Extended to n4's delta `counters` table with increments in flight on all three nodes; own test command with client timeout |
| R30 | `remove-node-clean-report-no-leftovers` | AF prop | Deterministic tag; lowered to P3 |
| R31 | `no-change-applied-on-its-origin-node` | AF prop | Lowered to P3; id check becomes setup assertion plus TAP |
| R32 | `cross-pg-major-links-replicate-identically` | AF prop | Lowered to P3; covered by `force_text_transfer` message plus TAP |
| R33 | `exception-log-slots-never-exhausted`, `progress-hash-capacity-survives-node-churn` | AF prop, IM prop | Capacity routes TAP-first and in `v2/small-capacity`; exception-log slots need fresh subscription names, progress hash fresh node names; race route stays in v1 |
| R34 | `crash-redo-leaves-no-node-id-origin-state` | IM prop | Assert only on a NULL-name row seen in two samples; SUT-side via SPI or dropped |
| R35 | `feedback-never-confirms-undurable-apply` | IM prop | Quiet-S phase, back-to-back `sub_disable`/`sub_enable`, `wal_writer_delay` variant, crash helper |
| R36 | `initial-sync-ends-ready-or-visibly-disabled` | IM prop | add_node in its own test command with client timeout |
| R37 | `terminate-active-transactions-never-discards-inbound` | IM prop | Client 57014 errors are unknown-outcome commits resolved by marker row |
| R38 | `exception-replay-only-after-recorded-error` | IM prop | `ALTER DATABASE ... SET transaction_timeout` set-up step, then restart apply workers |
| R39 | `apply-stream-framing-and-lsn-order` | AF prop | First SUT-instrumentation batch regardless of rank |
| R40 | `insert-race-resolved-not-discarded` | CB-F12 | Optional SUT-side `Sometimes("update_missing retry found the row on a later attempt")` (L6c) |

Not changed after checking: `luw-tiebreak-against-third-origin-row-reached`
(AF: hardest `Sometimes`, watch in first runs); `sub-drop-vs-table-sync-no-deadlock`
sampler (IM confirmed the wait event name; only the throwaway-subscription
note was added); `apply-cancel-retried-not-discarded` worker lookup (IM
confirmed `backend_type` names; recorded in topology).

## Gaps (handed to gap-fill agents)

| # | Gap | Lenses | Topic |
|---|---|---|---|
| G1 | No "every divergence is explained by Spock records" property; all data oracles use narrowed tables; no realistic mixed-DML table | CB-F1, W3 | (a) |
| G2 | No strict final round with zero exemptions, and no operator-recovery loop under faults | W4 | (a) |
| G3 | No bounded-completion liveness for add_node itself (V5) | CB-F7 | (b) |
| G4 | No bound on how long apply stays paused after the add_node caller dies (V3) | CB-F9 | (b) |
| G5 | Investigation candidates: `table-resync-under-faults-ends-ready`, `sync-worker-sigterm-never-skips-catchup` (AF: catalogue at P1), `stuck-table-not-shown-as-replicating`, `clean-apply-exit-respawn-paced`, `node-id-never-equals-local-origin-id` (AF: setup/TAP); re-add | AF props, catalog candidates | (b) |
| G6 | Provider side and DML kinds: TRUNCATE, repset changes under load, DDL-then-DML ordering | CB-F11 | (c) |
| G7 | Partition-key moves turning update/update into delete/update | W10 | (c) |
| G8 | 2PC: patch 025 may not cover `COMMIT PREPARED` commit ts | W9 | (c) |
| G9 | Healthy links never hit the idle timeout; large transactions always eventually apply | W1 | (c) |
| G10 | Slot-group join guard `Unreachable` in every v1 run; standby promote property for `v2/standby` (S9) | W11, CB-F6 | (c) |

**Extra gaps beyond topics (a)-(c):**

- **E1. Slot invalidation (`max_slot_wal_keep_size`)** (W13): no property
  checks that a subscriber whose slot was invalidated ends in a visible,
  stable error rather than a silent gap or a hidden drop-and-recreate. Needs
  a config variant with a small `max_slot_wal_keep_size` and a long partition.
- **E2. SUB_DISABLE run variant and L27** (CB-F2, CB risk map): S7
  (SUB_DISABLE resume) and L27 (the disable and exception rows written into
  the open remote transaction are rolled back when the inner loop stops
  mid-transaction, `src/spock_exception_handler.c:232-276`) have no property
  of their own and no planned run variant. A property such as "after a data
  error under `sub_disable` the subscription ends disabled with an exception
  row, not in a retry loop" would need the `sub_disable` variant to be
  planned.

## Biases (for the human)

**B1. The P0/P1 set leans toward known, code-confirmed bugs.**
Evidence: AF-CW1, W2, CB-F3. About 15 of 75 properties (4 of the 13 P0s
before refinement directly, plus 2 P0s that L1 makes fail) are expected to fire on their first trigger: L1, 57014,
40001, readonly=local DDL, search_path leak, TOAST merge, domain/OID
transfer, the clock Assert. Antithesis adds little for these beyond the
first hit, and the refinements now gate them. Judgement needed: confirm
these with TAP and fix them before the first Antithesis runs (so the run
budget goes to unknown bugs), or run with the gates and the explained /
unexplained split? And are L1 (at-least-once after a crash), 57014/40001
(cancel of an apply worker) and readonly=local DDL bugs, or accepted
behaviour? If accepted, the gates become permanent scoping and the L1
cluster shrinks to documentation findings.

**B2. The workload avoids realistic multi-master traffic instead of scoring
it.** Evidence: CB-F1, W3, W10. Every data oracle runs on tables built to
dodge documented divergence (insert-only ledger, update-only contested rows,
no cross-node update-after-insert, no deletes on contested tables, no
partition-key moves), which is not how applications use the product. Gap
(a) adds an explained-divergence property, but the weight is a judgement:
how much run time goes to realistic-traffic tables scored only by "every
difference is explained" versus the strict narrowed oracles that can name a
bug exactly? And is documented divergence (no tombstones, `update_missing`
ordering) itself something you want reported?

**B3. The harness configuration is not the documented production
configuration.** Evidence: W1 and W odd things, IM-CW8. The main
configuration uses `wal_sender_timeout = 60s` (which `docs/configuring.md`
warns can cause spurious disconnects), a lowered `apply_idle_timeout`,
`spock.pause_timeout = 1` and a cassert build, to fit liveness checks into
quiet periods and to open timing windows. A documented-defaults variant is
now planned. Judgement needed: which configuration is primary for findings
you will act on, and are findings that appear only under the tightened
settings in scope?

**B4. The plan centres on one same-version v1 mesh.** Evidence: CB-F6, CB
risk map ranks 9-10, W8. Failover and physical standbys (claim S9, "resumes
with no data loss", PG18 slot sync) have no standalone property, slot groups
are out of v1, and mixed-version has three P2 properties. Gap (c) adds a
`v2/standby` promote property, but whether to build that topology at all is
a scope decision: is failover in scope for this engagement, and should
`v2/standby` or `v2/mixed-version` come before deepening v1?

## Second evaluation pass

Gap topics (a) and (c) each add a new kind of property (explained-divergence
oracle with operator recovery; provider-side DML and 2PC). If gap-fill
produces those as planned, a short second evaluation pass on the new
properties is worthwhile; (b) adds properties to an existing cluster and
does not need one on its own. Done: see the next section.

## Second pass (gap-fill)

Merge of `discovery/gap-a-divergence.md`, `gap-b-addnode-ops.md` and
`gap-c-provider-dml.md` into the catalog, plus extra gaps E1 and E2, then a
short re-check of the new categories with the three main lenses (Antithesis
fit, implementability against `deployment-topology.md`, overlap with the
existing catalog). 13 properties added (12 from gap-fill, 1 from E2); none
was a real duplicate of an existing property, one assertion was claimed by
two of them and is now owned by one.

### Merge results

| Gap | Outcome |
|---|---|
| G1, G2 (topic a) | `every-divergence-explained-by-spock-records` (P1), `strict-final-round-has-no-exemptions` (P0), `operator-recovery-steps-restore-replication` (P1). Delete conflicts beyond causal deletes are inside the first. |
| G3, G4, G5 (topic b) | `add-node-returns-within-bound` (P2), `add-node-pause-released-after-caller-dies` (P3), `sync-worker-sigterm-never-skips-catchup` (P1). Other candidates: see the catalog's "Investigation candidates: outcome". |
| G6-G10 (topic c) | `prepared-commit-ts-matches-sent-ts` (P1), `sync-standby-hold-freezes-provider-confirmed-flush` (P1), `promoted-subscriber-standby-has-every-confirmed-txn` (P2), `quiet-link-never-hits-idle-timeout` (P3 after this pass), `walsender-never-joins-slot-group` (P3), `truncate-ordered-with-same-origin-dml` (P2). Repset changes under load and partition-key moves judged covered; DDL-then-DML became an extension. Two TAP-only findings recorded under the catalog's "Out of scope". |
| E1 slot invalidation | Not a property (below). |
| E2 SUB_DISABLE / L27 | `sub-disable-error-ends-disabled-and-recorded` (P2, `sub_disable` run variant). |

Extensions applied to existing properties (catalog line plus evidence-file
section): `apply-never-waits-on-dead-sync-worker` (absorbs
`table-resync-under-faults-ends-ready` as a retry step),
`zodan-readd-node-progress-not-stale` (drop user schemas on re-add; new
needs-human-input question on skipped empty schemas),
`add-node-pause-held-until-progress-read` (benign firing under partition),
`redelivered-ddl-not-turned-into-exception` (ADD COLUMN then DML pairs),
`manager-kill-targets-only-listed-worker` (correction: fast shutdown can
reach the skip during SYNCWAIT), `feedback-never-confirms-undurable-apply`
(second L9 path), `luw-final-version-has-max-commit-ts` and
`local-overwrite-gets-later-commit-ts` (2PC commit ts from a peer),
`exception-log-matches-discarded-transactions` and
`resolutions-rows-match-applied-outcome` (app-table traffic),
`convergence-check-runs-after-faults` and
`interrupted-exception-replay-still-records-txn` (cross-references).
Catalog Assumptions 4 and 5 gained the settings and workload boundaries the
new properties need (node-id vs roident setup check, 2PC writers, TRUNCATE
on single-owner tables, `exception_logging = all`).

### E1: slot invalidation (`max_slot_wal_keep_size`)

- Examined: `src/spock.c` `spock_start_replication` (FATAL "could not send
  replication command" when `START_REPLICATION` fails), `src/spock_apply.c`
  apply start (`:4740-4780`), slot create and drop paths in
  `src/spock_sync.c` (`ensure_replication_slot_snapshot` `:403-470`, the
  drop-if-inactive query `:663-675`), `src/spock_functions.c` status logic
  (`:1495-1520`), docs and tests for `max_slot_wal_keep_size`.
- Found: Spock has no handling of its own. An invalidated subscription slot
  makes every apply start fail with FATAL, paced by `restart_delay_default`;
  nothing re-creates the subscription slot on reconnect, so there is no
  silent gap and no hidden drop-and-recreate. The only re-create paths are a
  new initial sync or a table sync, which drop an inactive slot of the same
  name and copy data fresh. `sub_show_status` shows `down`, and briefly
  `replicating` while each new worker starts. The project expects unlimited
  retention (the upgrade test requires `max_slot_wal_keep_size = -1`).
- Conclusion: not an Antithesis property. The outcome is visible, stable and
  independent of timing; a TAP test (invalidate a slot, check the log and the
  status) and a doc note on the recovery step (drop and re-create the
  subscription) cover it. Recorded under the catalog's "Out of scope".

### E2: SUB_DISABLE run variant and L27

- Examined: `src/spock_apply.c` replay paths (`:1580-1615`, `:1633-1650`,
  `:1770-1790`, `:2150-2175`, `:2765-2790`), `handle_commit` SUB_DISABLE
  path (`:997-1084`), inner-loop check (`:3780-3830`), `PG_CATCH`
  SUB_DISABLE branch (`:4005-4027`), `spock_apply_main` exit (`:4793-4797`),
  `src/spock_exception_handler.c:217-276`, `src/spock_proto_native.c:813-819`,
  TAP `016_sub_disable_missing_relation.pl`.
- Found: L27 confirmed by code reading. In read-only replay, a relation
  missing on the subscriber sets `xact_had_exception` mid-transaction; the
  inner-loop check calls `spock_disable_subscription` while T is open, which
  does not commit; `apply_work` returns, `proc_exit(0)` aborts, and the
  disable and every exception row are rolled back. The clean exit restarts
  the worker, the shared-memory marker sends it into the same replay, and
  the loop repeats with nothing recorded. It needs T's COMMIT to arrive in a
  later read batch than the failing change, which depends on transaction
  size and on how the link splits reads; TAP 016 covers only the one-read
  case and passes. Other errors during replay take the same rolled-back
  route once and then recover.
- Conclusion: real and partly timing-dependent; catalogued as
  `sub-disable-error-ends-disabled-and-recorded` (P2) with a new `sub_disable`
  run variant in the topology. Reproduce the multi-read case in TAP first.

### Second-pass findings on the new categories

| # | Finding | Lens | Category | Action |
|---|---|---|---|---|
| S1 | `operator-recovery-steps-restore-replication` and the `apply-never-waits-on-dead-sync-worker` extension both claimed the resync-retry assertion (gap a and gap b each absorbed candidate G1) | overlap | Refinement | One owner: `apply-never-waits-on-dead-sync-worker` asserts "retried table resync reaches READY after faults stop"; the operator-recovery property runs the step and counts it in its `Sometimes`. Catalog, both evidence files, relationships cluster 6 and 7 |
| S2 | The explained-divergence oracle planned a snapshot of `spock.resolutions` against cleanup, but the main configuration already sets `resolutions_retention_days = 0`, which skips cleanup (`src/spock_conflict.c:978`) | implementability | Refinement | Snapshot kept only for a cleanup-on variant; open question on clock-jump size dropped (catalog and evidence) |
| S3 | `prepared-commit-ts-matches-sent-ts` direct check and mechanism 1 of `sync-standby-hold-freezes-provider-confirmed-flush` fire without faults | Antithesis fit | Refinement | Placement line "confirm with TAP first, then gate out of the main template"; Antithesis keeps the clock-skip divergence and the restart path. Catalog Summary, entries, relationships Placement |
| S4 | `quiet-link-never-hits-idle-timeout` was written against a 30 s idle timeout; the topology already uses 60 s / 120 s, which meets the rule | implementability | Refinement | Evidence and catalog corrected; topology confirmed consistent (catalog Assumption 4 says the same); priority P2 to P3 (guard) |
| S5 | The strict round needs recovery, barriers and every check in one fault-free stretch; `finally_` alone may score on few timelines | implementability | Refinement | Also run it as an `eventually_` command (catalog and evidence) |
| S6 | Strict round re-checks properties that already have messages; risk of double counting | overlap | Refinement | Recorded as dominance: the strict round names the check, the owning property's message is triaged (catalog, relationships cluster 12) |
| S7 | 2PC shares the patch-025 hook with the LUW leads; LUW oracles read the origin's commit ts, which is wrong for prepared transactions | overlap | Refinement | 2PC placed in relationships cluster 4; notes in `luw-final-...` and `local-overwrite-...`; two-phase writers must always finish what they prepare (Assumption 5) |
| S8 | Sync-standby phantom check and the existing feedback check (2) both target L9 path 1 | overlap | Refinement | Kept separate (SUT-side detector vs workload outcome); dominance order recorded in relationships cluster 3 |
| S9 | `truncate-ordered-with-same-origin-dml` conflicts on its face with the Assumption 5 TRUNCATE ban | implementability | Refinement | Single-owner `trunc_<node>` tables, excluded from shared oracles; ban stays for shared tables (Assumption 5) |
| S10 | `promoted-subscriber-standby-has-every-confirmed-txn` needs a sixth container and a failover runbook the docs do not have | Antithesis fit | Bias (B4) | No change; run the phantom variant first; whether to build `v2/standby` stays a human scope decision |
| S11 | `add-node-returns-within-bound`'s main trigger depends on how Antithesis tears down container networking (half-open sockets) | Antithesis fit | Refinement | Kept at P2 with that open question; the workload's own add_node client timeout is set above the property's bound so the property, not the harness, reports a hang (catalog note) |
| S12 | Operator recovery and the strict round need resyncs at least in the final round, which ties them to the open "resyncs in v1" question | implementability | Refinement | Catalog-wide open question now lists the gap-fill properties that need resyncs |
| S13 | Two investigation side leads (`readonly-all-stopped-worker-input-bounded`, `delta-apply-never-sees-toast-placeholder`) were not taken up by any gap topic | coverage | Gap | Kept as unverified leads in the catalog's "Investigation candidates: outcome"; not catalogued |

No lens found a new property that fails the Antithesis-fit test outright:
each new safety property either needs fault timing for its main trigger or
is marked TAP-first with its fault-driven part kept.
