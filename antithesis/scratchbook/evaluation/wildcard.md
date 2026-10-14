---
sut_path: /home/msharp/dev/pgedgea/spock
commit: 69d9228f5df363761dc3ae6eebf7e2fcfe49b8e5
updated: 2026-10-13
external_references: []
---

# Evaluation — Lens 4: Wildcard

Scope: questions the framing of the SUT analysis and the catalog, looks for
failure scenarios and usage patterns nobody modelled, and looks across the
other lenses for properties that are high value but hard to run in their
current form. Read in full: `property-catalog.md`, `sut-analysis.md`,
`deployment-topology.md`; skimmed `property-relationships.md` and the
evidence files named below. Code facts cited here were re-read at HEAD
69d9228f. Statements about stock PostgreSQL behaviour come from memory
of stock PG, not from a tree read in this pass (scope was "just this
directory"). They are marked **unverified**.

---

## Catalog-wide findings

### W1. The harness's timeout settings will cause reconnect churn on idle links and may stop large transactions from ever applying

**Properties:** catalog-wide; mainly `mesh-barriers-complete-after-partition-heal`,
`convergence-check-runs-after-faults`, `crashed-node-returns-to-streaming`,
`apply-worker-restarted-within-bound-after-exit`, `replay-spill-file-lifecycle`.

**Concern.** Catalog Assumption 4 and the topology set
`spock.apply_idle_timeout` to about 30 s and keep `wal_sender_timeout` at
60 s ("do not lower it further"). The idle timer resets only when a message
arrives (`src/spock_apply.c:3548-3562`, reset at `:3686`). Spock sends no
timed feedback (catalog, `causally-deleted-row-stays-deleted`). A stock
walsender with nothing to send only sends a keepalive when
`wal_sender_timeout / 2` has passed since the last reply (**unverified**,
stock `WalSndKeepaliveIfNecessary`). That is about 30 s here. So on an idle
pair, or while the provider decodes one large transaction before sending its
first byte (Spock has no streaming callbacks, sut-analysis 2.1), the gap
between messages is about the same as `apply_idle_timeout`. The worker then
raises "no data received ... reconnecting", restarts after
`restart_delay_default`, and the provider decodes again from `restart_lsn`.
For a transaction whose decode takes longer than the idle timeout, this can
loop forever: a livelock.

**Why it matters beyond the harness.** `docs/configuring.md:227-252` tells
users to set `wal_sender_timeout = '5min'` and keeps `apply_idle_timeout =
300`. The keepalive gap is then 150 s, which is fine. A user who goes further
(for example `wal_sender_timeout = '10min'`) gets a 300 s gap, equal to the
default idle timeout, and the same reconnect churn in production. No property
covers "a healthy link never reconnects" or "a large transaction always
eventually applies".

**Suggested action.**
1. Harness: set `apply_idle_timeout` well above `wal_sender_timeout / 2`
   (for example 90 s with `wal_sender_timeout = 60s`), and widen the
   liveness bounds to match. Or run one variant with the documented values
   (5 min / 300 s), so that findings cannot be dismissed as "unsupported
   config".
2. Add a property, for example `healthy-link-never-hits-idle-timeout`: a
   workload log scan `Unreachable` on "no data received for" over windows in
   which neither the pair's network nor either process had a fault injected.
   Add a companion `Sometimes("transaction larger than N MB applied after
   decode longer than apply_idle_timeout")`.
3. Ask the team whether Spock should reject or warn when `apply_idle_timeout
   <= wal_sender_timeout / 2`, or send its own periodic feedback.

### W2. Many P0/P1 properties are expected to fail on the first try; widen the SPOC-688 "gate" idea to cover them

**Properties:** `crash-redo-leaves-no-node-id-origin-state`,
`ledger-row-applied-exactly-once-per-peer`, `delta-counter-equals-committed-increments`,
`causally-deleted-row-stays-deleted`, `redelivered-ddl-not-turned-into-exception`,
`sync-event-barrier-survives-subscriber-restart` (all L1);
`local-overwrite-gets-later-commit-ts`, `luw-final-version-has-max-commit-ts`,
`contested-rows-converge-after-quiesce` (L3, no fix on any branch);
`apply-survives-provider-clock-ahead`; `apply-search-path-not-leaked-across-transactions`
("Expected to fail"); `readonly-local-keeps-inbound-ddl-flowing` (fires
whenever the DDL role is not a superuser); `remove-node-clean-report-no-leftovers`
("Expected to fire at HEAD"); `apply-cancel-retried-not-discarded` and
`terminate-active-transactions-never-discards-inbound` (fire whenever a
cancel lands mid-transaction); `replicated-values-mean-same-on-every-node`
(domain and OID cases are fixed by configuration); `luw-unchanged-toast-no-mixed-rows`.

**Concern.** About 15 of the 75 properties are expected to fail as soon as
their trigger is reached. Several of those triggers are a single fault or a
single setting. The catalog treats only SPOC-688 as a gate. After an
Antithesis `Always` has failed once, later failures from a different cause
under the same message add nothing to the report. So the duplicate, loss and
convergence oracles go blind to any second cause the first time L1 or L3
fires. Examples of second causes: L7, the feedback bug, add_node overlap, L2.
`property-relationships.md` says to "read them as one finding". That handles
triage, but it does not bring the lost sensitivity back.

**Suggested action.**
- Reproduce each deterministic one with TAP before spending Antithesis time
  on it: readonly-local DDL, search_path leak, domain/OID transfer,
  remove_node report, 57014 / 40001 classification, proto5 'S' replay, and
  the L9 probe in W8. Then either put the fix in the image or switch the
  property off for v1.
- For L1 and L3, where no fix is coming soon, split each consequence
  property's message by attribution. Examples: "duplicate on a node that
  crashed since the row committed and shows a node-id origin state"
  (explained by L1) vs "duplicate with no crash or no node-id state"
  (unexplained). For L3: "divergent key last written by a node within N s
  after its restart" vs everything else. Only the unexplained messages count
  as new findings. This keeps the oracles sensitive while L1 and L3 stay
  open.

### W3. The "every difference is explained" oracle is relied on but never catalogued, and the workload bans the most common multi-master pattern instead of checking it

**Properties:** catalog-wide (referenced in `exception-replay-never-reruns-committed-transaction`,
the Category J intro, `exception-log-matches-discarded-transactions`,
`redelivered-ddl-not-turned-into-exception`, `resolutions-rows-match-applied-outcome`,
`convergence-check-runs-after-faults`).

**Concern.** SUT claim S2 ("non-resolvable conflicts are recorded in
`spock.exception_log`") is the documented contract that makes the known
divergences acceptable. At least four properties call it "the harness's
oracle", but no property states it or owns it. The catalog avoids it instead:
contested tables have no deletes, nothing updates a row that was inserted on
another node, and the ledger is insert-only. Updating rows that were inserted
elsewhere (create in region A, edit in region B) is the most common reason
people buy multi-master. As a result, no table in the run looks like a real
application, and the `update_missing` / `delete_exists` / TRANSDISCARD
paths are only reached through deliberate poison transactions.

**Suggested action.** Add a property, for example
`every-divergence-explained-by-spock-records`. Use an "app" table driven by
realistic traffic (insert anywhere, update and delete anywhere, mostly
non-overlapping keys with some overlap). After quiescence, every key whose
contents differ between nodes must have, on at least one of the differing
nodes, an `exception_log` row for a transaction that touched that key (or a
documented no-tombstone pattern visible in the workload's own history).
`Always`. This turns the §12 "expected divergence" list from rules about
what the workload may not do into a checked contract. It also reaches the
cross-upstream ordering paths (L6b) with real timing.

### W4. The exemptions add up; there is no evidence that the strict checks ran in a fully healthy cluster, and no operator-recovery loop

**Properties:** `remote-transaction-all-or-nothing-per-node` (skips non-`r`
nodes), `committed-ledger-row-reaches-every-node` (disabled subs reported
separately), `graceful-restart-preserves-exactly-once` (kill windows
excluded), every bounded check (clock-jump windows skipped), every data check
(timed-out barrier skips the round), `initial-sync-ends-ready-or-visibly-disabled`
and `sync-wait-functions-honor-contract` ("visibly failed" is acceptable).

**Concern.** Each exemption makes sense on its own. Together, in a run with
all faults on, the state the strict checks actually see may be a small,
easy slice. `convergence-check-runs-after-faults` has
`Sometimes("ran with all subscriptions enabled")`, but none for "all tables
READY on every node", "n4 joined", or "no exemption applied". The catalog
also stops at "visible failure is acceptable". Spock relies on operators for
recovery (`sub_resync_table` for a FAILED table, `sub_enable`,
`zodan_cleanup` / `remove_node` and retry, dropping orphan slots, ACE), and
whether those steps are safe under faults is never tested. The candidate
`table-resync-under-faults-ends-ready` (G1) is one example.

**Suggested action.** Have the workload act as the operator. When it sees a
visible failure (FAILED table, disabled sub, failed add_node, orphan slot),
it runs the documented recovery step, still under faults. At the end of the
run, add a final strict round with no exemptions: every table `r`, every sub
enabled, full ledger. Add `Sometimes` markers for "strict round completed
with zero exemptions" and "documented recovery step ran and the next strict
round passed". Catalog G1 as part of this.

### W5. Single-process signals can be sent from SQL today, without helper containers

**Properties:** every property that needs "worker exit (test cmd)", "graceful
stop (test command)" or single-process pause: `apply-cancel-retried-not-discarded`,
`interrupted-exception-replay-still-records-txn`, `sub-disable-enable-cycle-loses-and-duplicates-nothing`,
`graceful-restart-preserves-exactly-once`, `fast-shutdown-completes-within-bound`,
`feedback-never-confirms-undurable-apply`, `exception-replay-only-after-recorded-error`,
`apply-never-waits-on-dead-sync-worker`, `add-node-pause-held-until-progress-read`.

**Concern / cross-cut.** Lens 3 will likely list the missing helpers as a
blocker ("Graceful-stop and single-worker-exit helpers. Not built yet"). The
nodes use `trust` auth and the workload connects as a superuser, so
`COPY (SELECT 1) TO PROGRAM 'kill -<SIG> <pid>'` runs as the postgres OS user
on the target node. One evidence file already uses this idea for `pg_ctl
stop` (`properties/graceful-restart-preserves-exactly-once.md:81`). Used more
widely, it gives:
- `SIGKILL` of one apply, sync or walsender pid: PostgreSQL does a crash
  restart inside the container (shared memory wiped, page cache kept). This
  is a third kind of crash, different from a container kill.
- `SIGSTOP` / `SIGCONT` of one walsender: a silent, one-direction stall of
  one pair, while the rest of the node keeps running. This gives the
  `apply_idle_timeout` path and the add_node `CREATE_REPLICATION_SLOT`
  stretch (L4) without pausing a whole container.
- `SIGTERM` to a sync worker in COPY: the candidate G7.

**Suggested action.** Standardise on one SQL helper (a `SECURITY DEFINER`
function or plain `COPY TO PROGRAM`) for the signal set above. Choose pids
from `pg_stat_activity.backend_type`. Warn that SIGSTOP of a backend holding
an LWLock can stall the whole node: treat liveness results in those windows
as scoped.

### W6. Two of the top leads live in core PostgreSQL patches, which are not instrumented

**Properties:** `crash-redo-leaves-no-node-id-origin-state` (L1, `xact_redo`
origin advance), `local-overwrite-gets-later-commit-ts` and the L3 cluster
(patch 025 hook), `clock-step-forward-makes-commit-ts-ties`.

**Concern.** The topology instruments only `spock.so` ("Postgres core: Not
instrumented at first"). The L1 mechanism (redo advancing
`XLogRecGetOrigin`) and the L3 mechanism (`EnsureMonotonicTransactionStopTimestamp`)
are in core code that the image already builds from source with in-tree
patches. Coverage guidance therefore cannot steer toward "the hook bumped a
local commit" or "redo advanced an origin with no `pg_replication_origin`
row". The catalog's markers for these are all on the workload side, after
the fact.

**Suggested action.** Add a small test-only patch next to `patches/18/` with
SDK `Sometimes` / `Reachable` markers at: the hook's local-bump branch, the
hook's first call after startup (logical clock == 0), and `xact_redo_commit`
when the record's origin id has no catalog entry. The cost is small because
PG is already built from source.

### W7. The crash-semantics question is asked from the wrong side

**Properties:** `resource-dat-dumps-serialized`, `crashed-node-returns-to-streaming`,
`feedback-never-confirms-undurable-apply`, all of the L1 cluster.

**Concern.** The catalog asks whether node termination "keeps fsynced
writes". What decides reachability for several properties is whether it
**drops unfsynced writes** (page cache). If a container kill keeps the
shared kernel's page cache, then `resource.dat` without fsync, ordering
mistakes in `durable_rename`, and the async-commit window narrow to
"process died before write()", and power-loss bugs cannot be reached. The
L1 redo path does not depend on this.

**Suggested action.** Ask both halves. If unfsynced data survives, say in
`resource-dat-dumps-serialized` and `crashed-node-returns-to-streaming` that
short-file and fsync-ordering bugs are only reachable when the dumping
process itself is killed mid-write.

---

## Missing angles and property-specific findings

### W8. A cheap way to test L9 and the hold-list memory growth without a standby container

**Properties:** `feedback-never-confirms-undurable-apply` (L9 part deferred to
v2/standby), `apply-worker-memory-bounded` (hold-list part deferred to
v2/standby).

**Concern / cross-cut.** High value (failover data loss, claim S9), but put
off as "needs a sixth container". The hold path is gated only on
`WalSndCtl->sync_standbys_status & SYNC_STANDBY_DEFINED`
(`src/spock_apply.c:1060` in `handle_commit`, `:3253` in `send_feedback`), which is true whenever
`synchronous_standby_names` is non-empty. Set
`synchronous_standby_names = 'phantom'` on one subscriber that has no
standby. `WalSndCtl->lsn[SYNC_REP_WAIT_FLUSH]` then never moves, so correct
code never releases a hold (`get_feedback_position`, `:3213`). The
provider's `confirmed_flush_lsn` for that subscription's slot must therefore
stay where it was when the setting took effect. Under L9,
`get_flush_position` resets `flushpos = recvpos` (`:3259-3266`) and the slot
advances. The same setup grows the hold list by one entry per applied
transaction, which reaches the memory property.

**Suggested action.** This is probably deterministic, so reproduce it with
TAP first. In Antithesis it fits a short config variant. Clients on that
node must use `synchronous_commit = local`, or their commits will block.
Keep v2/standby for the real promote-and-check property (S9).

### W9. Two-phase commit clients are not modelled, and patch 025 may not cover COMMIT PREPARED

**Properties:** new; affects the Category D LUW properties and their oracle
(`luw-final-version-has-max-commit-ts` reads `pg_xact_commit_timestamp` on
the origin).

**Concern (hypothesis, unverified).** Patch 025 changes `xact.c` and `xlog.c`
only (`grep '^diff' patches/18/pg18-025-logical_commit_clock.diff`). The hook
rewrites `xlrec->xact_time` and `xactStopTimestamp` inside
`XactLogCommitRecord`. In stock PG, `RecordTransactionCommitPrepared`
(`twophase.c`) passes its own local `committs` both to `XactLogCommitRecord`
and afterwards to `TransactionTreeSetCommitTsData` (**unverified**, from
memory). If so, when the hook bumps a prepared transaction's time, the
WAL record (and so what decoding sends to peers) carries the bumped time,
while the origin's own `pg_commit_ts` keeps the unbumped one. The origin
then judges later conflicts on that row with a different timestamp than its
peers use. That is divergence with no record, and only under the clock
conditions the catalog already creates. Spock's docs say nothing about
prepared transactions either way, and application servers using XA enable
them.

**Suggested action.** Check `RecordTransactionCommitPrepared` in the patched
PG18 tree. If the mismatch is real, add a property
`prepared-commit-ts-matches-sent-ts`: the workload compares
`pg_xact_commit_timestamp(xid)` on the origin with the ts recorded on a peer
(`pg_xact_commit_timestamp_origin(xmin)` of the applied row). Also add a
workload option with `max_prepared_transactions > 0`, where some writers use
`PREPARE TRANSACTION` / `COMMIT PREPARED`.

### W10. Partitioned tables with row movement are not in the workload

**Properties:** new or variant of `contested-rows-converge-after-quiesce` /
W3.

**Concern.** Partitioned tables are common. An UPDATE that changes the
partition key is decoded as DELETE on the old leaf plus INSERT on the new
leaf. A concurrent UPDATE of the same row on another node therefore turns a
resolvable update/update conflict into delete/update plus `update_missing`,
which under TRANSDISCARD drops the other node's whole transaction. The team
has met partition moves: `src/spock.c:1085` and `src/spock_common.c:464`
handle the "tuple to be locked was already moved to another partition"
message. §12 bans only "late partitions".

**Suggested action.** Add a partitioned table with occasional partition-key
updates to the W3 "app" table, scored by the explained-divergence oracle. If
the team considers the outcome a bug and not a documented limit, add a
dedicated property.

### W11. Slot groups can be turned on by ordinary node names; add a guard to every run

**Properties:** out-of-scope list (L10/L30); `readonly-all-never-commits-remote-txn`.

**Concern.** The catalog handles slot groups only as a separate config and
keeps v1 names safe. But the trigger is a naming style users pick without
knowing the risk: `node-1`, `db_east_1`, or uppercase `N1` all end up with a
`_<digit>` slot name (sut-analysis L10). A ZODAN-built cluster named that
way splits one stream across subscribers without any error. The harness can
also hit it by accident if anyone renames nodes.

**Suggested action.** Add a SUT-side `Unreachable("walsender joined a slot
group")` in `spock_output_join_slot_group` to every v1 run (no cost; guards
the harness). Keep the targeted config for when the team answers sut-analysis
Q8. Until f6887c7a lands, the property belongs to "real users hit this", not
"exotic".

### W12. Several databases on one instance are not modelled (low)

**Properties:** `exception-log-slots-never-exhausted`, `add-node-pause-held-until-progress-read`.

**Concern.** Running one Spock database per tenant on one instance is a
plausible setup. ZODAN gives subscriptions the same names in every database
(`sub_<new>_<X>`), so they share exception-log entries keyed by name (L14),
and the pause flag is instance-wide (L4d). From code reading, the effects
look mild (extra pauses, markers cleared). Not worth v1 time, but Assumption
13 ("one database") should be listed as a scope limit in the catalog, not
only in the SUT analysis.

### W13. Slot invalidation is not modelled (low)

**Concern.** Operators who protect disks set `max_slot_wal_keep_size`. A
subscriber that is down longer than that sees its slot invalidated. Nothing
checks that this ends in a visible, stable error rather than a silent gap or
a hidden drop-and-recreate on reconnect. The catalog's "Hold readonly=all
shorter than WAL retention" assumes retention is unlimited.

**Suggested action.** One config variant with a small `max_slot_wal_keep_size`
and a long partition. Property: after invalidation the subscription is never
`replicating` with a gap; the ledger either converges or a visible error
persists.

### W14. Oracles that read `spock.resolutions` at the end can be fooled by its own cleanup (low)

**Properties:** `ledger-row-applied-exactly-once-per-peer` (oracle 2),
`insert-conflict-recorded-in-resolutions`, `resolutions-rows-match-applied-outcome`.

**Concern.** Every apply worker runs `DELETE FROM spock.resolutions WHERE
log_time < now() - '<retention> days'` about once per day of wall time
(`src/spock_apply.c:3564-3582`, `src/spock_conflict.c:933-936`; retention
default 100 days). Clock skips are global and do not stop during quiet
periods. A forward jump past the retention period removes rows that these
oracles read at the end of the run. The jump size makes this unlikely, but
it would fail silently in the "missing record" direction.

**Suggested action.** Have the workload copy `spock.resolutions` and
`spock.exception_log` rows into its own store as soon as they appear, and
score against that copy. Or set `spock.resolutions_retention_days = 0` in
the harness.

---

## Odd things

- **Harness settings are ones the docs advise against.** `wal_sender_timeout
  = 60s` is what `docs/configuring.md:236-238` warns "can cause spurious
  disconnects" during large transactions. Findings that involve walsender
  timeouts can be dismissed as "unsupported config". See W1. Run at least
  one variant with the documented settings.
- **The catalog's description of the audit trigger can mislead.** Row 163
  says "an `ENABLE ALWAYS` trigger that fires only under
  `session_replication_role = replica`". ALWAYS triggers fire in every mode.
  The evidence file (`ledger-row-applied-exactly-once-per-peer.md:96-99`)
  has the body check `current_setting('session_replication_role') =
  'replica'`, which is what makes it right. Anyone building the workload
  from the catalog table alone would write audit rows for local inserts too,
  and `no-change-applied-on-its-origin-node` would then fire falsely. Fix the
  wording, or use `ENABLE REPLICA`.
- **Some properties need a conflict-free run and others need deliberate
  errors.** Several properties require "no `exception_log` row at all"
  (`terminate-active-transactions-never-discards-inbound`,
  `sub-disable-enable-cycle-...`, `graceful-restart-...`,
  `apply-cancel-...`). Others inject poison transactions and insert/insert
  races in the same run (`interrupted-exception-replay-...`,
  `exception-log-matches-...`, `insert-race-...`, `proto5-...`). The checks
  need a shared "expected exception" registry (the workload records each
  poison transaction's origin, xid and commit ts), and "no rows at all" should
  become "no rows outside the registry". Otherwise they will contradict each
  other.
- **`apply-survives-provider-clock-ahead` is P0 for an Assert the team has
  already removed on a branch.** It is really a build step (include 4e0988de),
  not a property worth exploring. The catalog says so, but it still counts
  in the P0 total.

---

## Passes

- The catalog reasons carefully about clock skips being global (a backward
  skip plus a restart reaches L3) and re-checks bounded waits across jumps.
- It handles client commits whose outcome is unknown (marker rows read back
  on the origin), which many replication harnesses get wrong.
- It separates postmaster crashes, which wipe shared memory, from graceful
  single-worker exits, and says which leads each one reaches.
- `convergence-check-runs-after-faults` and the dominance notes in
  `property-relationships.md` show the catalog knows its oracles can be
  empty or misleading. W2 and W4 extend that.

## Uncertainties

- The walsender keepalive cadence (`wal_sender_timeout / 2` after the last
  reply) and the `RecordTransactionCommitPrepared` timestamp handling are
  from memory of stock PG. They were not read in a tree during this pass. A
  short run (W1) or a code check (W9) settles each.
- Whether Antithesis node termination keeps the page cache (W7).
- Whether `COPY TO PROGRAM` and `kill` are usable as the postgres OS user in
  the Antithesis node image (W5). Same uid, so signalling should work.
- W8 assumes nothing else releases holds when no standby ever connects.
  Lines 3213-3229 suggest so, but this has not been run.
