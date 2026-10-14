---
sut_path: /home/msharp/dev/pgedgea/spock
commit: 69d9228f5df363761dc3ae6eebf7e2fcfe49b8e5
updated: 2026-10-13
external_references: []
---

# Evaluation — Lens 1: Antithesis Fit

Question asked of every property: does testing it need a state space that a
deterministic test (TAP, pg_regress) cannot reach — timing, concurrency,
partial failure, or fault combinations? Or is it a fixed-input check that
spends Antithesis search budget for nothing?

Inputs read: `property-catalog.md` (all 75 entries plus the candidate list),
`sut-analysis.md`, `deployment-topology.md`, and the evidence file for
`add-node-pause-held-until-progress-read`. Code checked:
`wait_for_previous_transaction` and `maybe_pause_for_slot_creation`
(`src/spock_apply.c:294-340, 565-586`).

## Summary

Most of the catalog fits Antithesis well. The delivery, classifier, add_node,
sync-handshake and liveness properties all need random-time faults or
interleavings that the TAP suite does not produce (sut-analysis §8: no test
combines 3+ writers, random-time faults and a full data comparison).

The main problem is at catalog level, not with single properties. About a
dozen entries are **expected to fire on the first try** from a mechanism that
does not depend on timing (L1 after any crash, L5 on any cancel, the readonly
DDL bug, the search_path leak, the clock Assert). Each of these is a one-shot
deterministic reproduction. If they all run in the main template, every run
will spend its budget re-finding the same few root causes, and the downstream
data properties (ledger, delta, causal delete, DDL redelivery, barriers) will
fire from them too, which hides new bugs.

A smaller group is plain TAP territory (config- or schema-driven, no fault
needed), and three `AlwaysOrUnreachable`/`Sometimes` checks are effectively
out of reach in the v1 topology.

## Catalog-wide findings

### CW1. Known deterministic root causes will flood the main template

| Root cause | Property that detects it | Downstream properties it will also fire |
|---|---|---|
| L1 crash redo advances node-id origin | `crash-redo-leaves-no-node-id-origin-state` ("expected to fire on the first subscriber crash") | `ledger-row-applied-exactly-once-per-peer`, `delta-counter-equals-committed-increments`, `causally-deleted-row-stays-deleted`, `redelivered-ddl-not-turned-into-exception`, `sync-event-barrier-survives-subscriber-restart`, `replication-origin-states-do-not-leak`, `exception-log-matches-discarded-transactions` (second row set) |
| L5 57014 not on retry list | `apply-cancel-retried-not-discarded` (allow-list code-checked) | `committed-ledger-row-reaches-every-node`, `delta-counter-…`, `remote-transaction-all-or-nothing-per-node`, `sub-disable-enable-cycle-…`, `readonly-toggle-resumes-without-loss` |
| 40001 from `terminate_active_transactions` | `terminate-active-transactions-never-discards-inbound` | same as L5 |
| readonly=local blocks non-superuser queued DDL | `readonly-local-keeps-inbound-ddl-flowing` ("fires whenever the DDL role is not a superuser") | DDL discarded -> later DML errors on schema difference -> ledger and exception_log checks |
| search_path leak | `apply-search-path-not-leaked-across-transactions` ("Expected to fail") | none directly, but fires every run with `replicate_ddl` |
| cassert clock Assert | `apply-survives-provider-clock-ahead` | every clock-fault property (already gated in the catalog) |

Evidence: catalog lines 24-29, 352-355, 365-366, 512, 1490; sut-analysis
L1/L5. All mechanisms are described as code-checked and not timing-bound.

Why it matters for fit: a deterministic bug needs one TAP run to confirm, not
hours of exploration. Antithesis triage groups by assertion message, so the
first finding is useful; every later timeline that hits the same root cause
is wasted search, and the downstream `Always` failures look like new findings
until someone traces them back.

Suggested action:
1. Confirm L1, the 57014 cancel, the 40001 terminate path, the readonly-local
   DDL bug and the search_path leak with short TAP scripts first (each is a
   few lines: kill -9 without CHECKPOINT; `pg_cancel_backend` on an apply pid
   mid-transaction; etc.). The catalog already notes this for
   `proto5-replay-reparses-startup-message`; extend it to these.
2. Apply the same gating idea the catalog already uses for the clock Assert
   (SPOC-688): until a fix is in the image, keep the trigger out of the main
   template. Concretely: the apply-cancel and `terminate_active_transactions`
   test commands go in a separate template; readonly=local phases use
   superuser DDL or no DDL in the main template; node kills stay in (they are
   needed for many other leads) but the L1-dependent exactly-once checks either
   wait for a fix or are scoped (for example, compare against an
   "at-least-once, duplicates explained by a kill" rule, as
   `forwarded-origin-advance-no-double-apply` already does).
3. Record in the catalog, per property, whether it is "expected to fire
   deterministically" so the workload skill can place it.

### CW2. Poison-transaction properties and "exception_log must be empty" properties cannot share one oracle

`interrupted-exception-replay-still-records-txn`,
`exception-log-matches-discarded-transactions`,
`proto5-replay-reparses-startup-message`, `replay-spill-file-lifecycle` (read-back
path) and `apply-stale-socket-never-polled` need the workload to cause real
data errors. `apply-cancel-retried-not-discarded`,
`terminate-active-transactions-never-discards-inbound`,
`sub-disable-enable-cycle-loses-and-duplicates-nothing`,
`graceful-restart-preserves-exactly-once` and `readonly-local-…` assert **no**
`exception_log` rows at all ("conflict-free workload").

Fit angle: the interesting Antithesis states for the replay family are the
fault-during-replay interleavings, so data errors must be frequent. If they
run in the same template as the "empty exception_log" checks, either the
empty checks need a filter (by table or by poison marker) or the two families
need separate templates.

Suggested action: state in each "no exception_log rows" invariant that it
filters to non-poison tables, or assign the replay family its own template.

### CW3. Fault-tool coupling: some properties need two faults in a tight order that Antithesis will rarely line up

Antithesis picks fault timing independently of test-command timing. Properties
that need "test-command action, then node kill within a short window" will
rarely hit by chance:

- `feedback-never-confirms-undurable-apply`: graceful apply exit, then a node
  kill within the async-commit flush delay (about the walwriter delay, 200 ms
  by default).
- `exception-replay-never-reruns-committed-transaction`: a cancel landing in
  `maybe_pause_for_slot_creation` after `CommitTransactionCommand`, which only
  happens while add_node has set the pause flag.
- `enabled-subscription-always-has-provider-slot`: a kill between the remote
  slot drop and the local commit of `sub_drop`.

Suggested action: build these as single custom faults / test commands that
do both steps (for example "terminate the apply worker, sleep 0-300 ms at
random, kill -9 the postmaster"; "start a cancel loop on the source's apply
workers only while add_node runs"). Keep the `Sometimes` companions the
catalog already lists so a green result is not vacuous.

## Property-specific findings

### Unit/TAP territory (low Antithesis value as written)

**`replicated-values-mean-same-on-every-node`** (P1). Faults: "none required".
The domain-over-user-array and OID-alias cases are fixed-input: they fail
whenever OIDs differ between nodes, which ZODAN's pg_dump/pg_restore makes
true on n4 every time. A TAP test with one domain column and one `regclass`
column covers it. Only the "reconnects re-run binary/text negotiation" part
needs Antithesis. Suggested action: move the domain/OID cases to TAP; keep a
P2-P3 Antithesis check for negotiation after reconnects, or fold it into the
general convergence dump.

**`cross-pg-major-links-replicate-identically`** (P2). The catalog itself
says "Little beyond the same-major mesh; the risk is mostly deterministic type
round-trips", and a `force_text_transfer` subscription in v1 runs the same
code. Suggested action: drop from the Antithesis list; cover with the
`force_text_transfer` message already inside
`replicated-values-mean-same-on-every-node` plus a TAP type round-trip test.

**`readonly-local-keeps-inbound-ddl-flowing`** (P1). "Mostly an
ordering-independent bug ... A TAP test would also catch it." Suggested
action: TAP repro now; after a fix, keep as P3 regression guard in
Antithesis (the reload-vs-DDL-arrival timing is the only Antithesis part).

**`apply-search-path-not-leaked-across-transactions`** (P1). Expected to fail
on the first `replicate_ddl` that ships a `SET search_path` prefix. Fault
history only changes how long the leak lasts. Suggested action: TAP repro and
fix; then P3 guard. Its P1 rank is a severity rank, not an Antithesis-value
rank.

**`remove-node-clean-report-no-leftovers`** (P2). "Expected to fire at HEAD
(known gap)"; "happens without a partition too" (an active walsender holding
the slot is normal). It is a reporting gap with a known code cause
(`zodremove` records `REMOVED` after a WARNING). Suggested action: file as a
code-reading finding with a TAP repro; keep at most a P3 check.

**`no-change-applied-on-its-origin-node`** (P2). The real failure (node id 0
or 65535) is configuration: v1 deliberately avoids those names (Assumption 5),
so in v1 this is a pure guard. Suggested action: make the id check a setup
assertion and a small TAP test for ids 0/65535; drop the runtime property to
P3 or merge its SUT-side `Unreachable`s into `apply-stream-framing-and-lsn-order`.

**`progress-hash-capacity-survives-node-churn`** (P2) and the capacity route
of **`exception-log-slots-never-exhausted`** (P1). Both are counting problems:
N fresh-named subscription creations without a restart. Reaching about
`max_worker_processes` ZODAN add/remove cycles inside one Antithesis run is
slow (each cycle is minutes of `pg_sleep(5)`s and sync waits), and node kills,
which Antithesis injects freely, reset the exception-log table. A TAP loop of
`sub_create`/`sub_drop` with fresh names hits both deterministically.
Suggested action: move the capacity routes to TAP. Keep in Antithesis only the
**race route** of `exception-log-slots-never-exhausted` (apply and sync
workers of one subscription claiming an entry at their first BEGIN together,
below capacity) — that one is real timing and fits well; consider making it
its own property as the catalog's G9 note offers.

**`crash-redo-leaves-no-node-id-origin-state`** (P0). Good detector, but it is
expected to fire on the first crash, so after one finding it adds nothing.
Suggested action: confirm by TAP (kill -9 without CHECKPOINT); keep it in
Antithesis as an `Unreachable` only if the L1-dependent properties are gated
as in CW1, otherwise it fires every run.

**`apply-cancel-retried-not-discarded`** (P0) and
**`terminate-active-transactions-never-discards-inbound`** (P1). The mechanism
(57014 / 40001 not on the allow-list) is deterministic: any cancel that lands
inside a remote transaction triggers it. Antithesis adds only "where in the
transaction". Suggested action: TAP confirm, then gate per CW1. After a fix,
these are good Antithesis regression guards (the retry path under random
timing is where past classifier fixes broke).

**`luw-unchanged-toast-no-mixed-rows`** (P0). The bug needs one update/update
conflict where one side changed only the TOAST column and the other only a
small column, and the remote wins. That state can be forced deterministically
in TAP (disable the two subscriptions, update on each node, re-enable). Under
Antithesis it will happen naturally under latency, so it is reachable, but
Antithesis is not needed to find it. Suggested action: TAP confirm first;
keep in Antithesis as a regression check. P0 reflects severity, not
Antithesis value.

### Assertion type does not match what v1 can reach

**`readonly-all-never-commits-remote-txn`** (P2, `AlwaysOrUnreachable`). The
only window named is a reload landing while the worker waits in
`wait_for_previous_transaction`. In v1 (no slot groups) `required_commit_ts`
is 0, so that function breaks out on its first check with no
`CHECK_FOR_INTERRUPTS` or `ProcessConfigFile` call (`src/spock_apply.c:301-312`,
code-checked). There is no wait, so a reload cannot land there. The assertion
will pass without ever being evaluated with `readonly = all`. Suggested
action: move to the `v2/slot-groups` config, or add a `Sometimes("handle_commit
reached with spock.readonly=all")` so a vacuous pass is visible; do not count
it as v1 coverage.

**`apply-worker-memory-bounded`** (P2). The named mechanism (sync-standby hold
list) needs a standby, which v1 lacks, and about 4M transactions per worker to
reach 256 MB. Antithesis workload throughput under fault injection is far
below that. The general-leak RSS check is a soak test. Suggested action: move
to `v2/standby` or a non-Antithesis soak run; the `AlwaysOrUnreachable` form
already admits it is unlikely to be evaluated.

**`add-node-pause-held-until-progress-read`** (P0). Fit is good, but the
primary `Unreachable` needs `CREATE_REPLICATION_SLOT` to take longer than
`spock.pause_timeout` (10 s) while provider apply workers keep running. A
whole-container pause of the provider freezes both the slot creation and the
worker timers, so container pause alone rarely opens the window. The evidence
file lists a workload-held long transaction on the provider and an optional
lower `spock.pause_timeout`. Suggested action: make both **required** harness
settings, not optional: `spock.pause_timeout = 1` in the node
`postgresql.conf` (it is USERSET, and each worker reads its own value), and a
workload step that holds an xid-assigned transaction open on the source across
add_node Phase 5. Without them the `Unreachable` is reachable only by luck.

**`luw-tiebreak-against-third-origin-row-reached`** (P1, `Sometimes`).
Reachable with global backward skips, but it needs microsecond-equal commit
timestamps on the same key from two nodes and arrival at a third node in a
given order. Fine as a `Sometimes`; noting that it is the hardest `Sometimes`
in the catalog and depends on the SPOC-688 image. If it never fires, the
contested-row properties are weaker than they look. Suggested action: none
beyond what the catalog has; watch it in the first runs.

### Antithesis value underestimated

**`resource-dat-dumps-serialized`** (P2). Two writers to one fixed temp file
plus a node kill right after: a race plus crash timing that TAP cannot place,
and the outcome is a node that will not restart without manual file removal.
Suggested action: consider P1, conditional on the admin-churn phase running
concurrent resyncs on two subscriptions of one node.

**`apply-stream-framing-and-lsn-order`** (P2). A set of cheap SUT-side
`Always` checks that are evaluated on every message of every timeline,
including walsender kills and reconnects. Cost is low and it covers paths no
other property watches directly (ORIGIN before change, end_lsn order). P2 is
fine; it should be in the first SUT-instrumentation batch regardless of rank,
since it guards the other oracles.

**Candidate `sync-worker-sigterm-never-skips-catchup`** (G7, not catalogued).
A sync worker that ignores SIGTERM until COPY ends and then marks SYNCDONE
without catch-up is silent drift, reachable only through a timing race
(manager slot reuse) or a terminate at the right moment. That is squarely an
Antithesis state. Suggested action: catalogue it (P1) rather than leave it
inside `manager-kill-targets-only-listed-worker`.

**Candidate `table-resync-under-faults-ends-ready`** (G1). Antithesis-native,
but at HEAD any sync-worker restart after STARTED marks the table FAILED by
design, so it would fire constantly until the team decides intent. Suggested
action: hold until the open question on FAILED tables is answered.

**Candidate `node-id-never-equals-local-origin-id`** (G1/G9). Setup check,
deterministic. TAP / setup assertion, not an Antithesis property.

## Passes (good fit, no change)

- Delivery core: `committed-ledger-row-reaches-every-node`,
  `remote-transaction-all-or-nothing-per-node` (checked continuously during
  faults, which only Antithesis gives), `graceful-restart-preserves-exactly-once`,
  `causally-deleted-row-stays-deleted` (two-worker re-apply race).
- Classifier/replay: `lock-contention-retried-not-discarded`,
  `insert-race-resolved-not-discarded`, `exception-replay-only-after-recorded-error`,
  `interrupted-exception-replay-still-records-txn`, `replay-spill-file-lifecycle`,
  `apply-stale-socket-never-polled`.
- Barriers: `sync-event-barrier-implies-visible` (thread pause stretches the
  commit-to-visible window), `sync-event-barrier-survives-subscriber-restart`.
- LUW and clocks: `contested-rows-converge-after-quiesce`,
  `luw-final-version-has-max-commit-ts`, `local-overwrite-gets-later-commit-ts`,
  `clock-step-forward-makes-commit-ts-ties` — clock faults are the only way to
  reach L2/L3 and no TAP test does (005 is `todo_skip`).
- Membership: `add-node-success-new-node-has-every-row`,
  `initial-sync-ends-ready-or-visibly-disabled`,
  `add-node-after-peer-restart-captures-every-peer`,
  `zodan-readd-node-progress-not-stale`.
- Lifecycle and liveness: `sub-drop-vs-table-sync-no-deadlock` (pure
  interleaving, undetectable by the deadlock detector),
  `apply-never-waits-on-dead-sync-worker`, `manager-kill-targets-only-listed-worker`,
  `sub-disable-enable-cycle-loses-and-duplicates-nothing`,
  `readonly-toggle-resumes-without-loss`, `crashed-node-returns-to-streaming`,
  `mesh-barriers-complete-after-partition-heal`,
  `fast-shutdown-completes-within-bound`,
  `apply-worker-restarted-within-bound-after-exit`,
  `sub-show-status-reflects-apply-state`.
- Leaks after faults: `no-orphan-slot-pins-wal-after-quiesce`,
  `replication-origin-states-do-not-leak` (orphan-named part),
  `spock-connections-match-subscriptions-after-quiesce`.
- Audit: `insert-conflict-recorded-in-resolutions`,
  `resolutions-rows-match-applied-outcome`,
  `exception-log-matches-discarded-transactions`.
- Oracle health: `convergence-check-runs-after-faults` — right use of
  `Sometimes` to stop vacuous passes.
- Regression guards ranked P3 (`worker-respawn-rate-bounded`,
  `progress-commit-lsn-tracks-applied-commits`,
  `apply-identity-restored-after-queued-sql`) are correctly ranked low.
- v2 properties (`mixed-version-*`, `rolling-upgrade-*`,
  `forwarded-origin-advance-no-double-apply`,
  `provider-slot-owned-by-one-subscription`) need faults during upgrade or
  initial sync; good fit for their topologies.

## Uncertainties

- Whether node termination and clock faults are enabled for the tenant
  (catalog open question). If node termination is off, CW1's L1 flood does not
  happen but a third of P0/P1 cannot fail; the trade-off changes.
- Exact throughput of the workload under Antithesis, which decides whether the
  capacity routes (exception-log slots, progress hash) are reachable in one
  run. I assumed they are not without a small-capacity config and many
  minutes of ZODAN churn.
- Whether Antithesis thread pausing can target a single walsender (for
  `add-node-pause-held-until-progress-read`) without instrumenting PG core; the
  topology plan instruments only `spock.so`.
- Whether the team will call L1 / 57014 / readonly-local bugs (open human
  questions). If they are accepted behaviour, CW1's gating becomes permanent
  scoping instead of a temporary gate.
