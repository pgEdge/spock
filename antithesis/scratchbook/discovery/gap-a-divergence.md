# Gap (a): realistic multi-master traffic, explained divergence, strict final round

Surfaced by: evaluation gap (a) (coverage-balance F1, wildcard W3, W4).
Code checked at 69d9228f. Three new properties. Gap item 3 (delete
conflicts beyond causal deletes) is covered inside the first property, not
as a separate one.

### every-divergence-explained-by-spock-records — Every cross-node difference on a realistic table is recorded by Spock

| | |
|---|---|
| **Type** | Safety |
| **Property** | On an "app" table written with INSERT, UPDATE and DELETE from every node (create on one node, edit or delete on others), every per-key difference between nodes after quiescence is matched by an `exception_log` or `resolutions` row on the differing node(s). |
| **Invariant** | Workload `Always("app table: every cross-node difference is explained by exception_log or resolutions")` after barriers. Group nodes by the key's version (absent counts); a node explains it with E1 an `exception_log` row for a dropped txn that wrote the key (matched by `(remote_origin, remote_commit_ts)` against the workload history, or by key in the tuple JSON), E2 a `delete_exists` resolution with that node's row, or E3 a `delete_missing` resolution where the node's version came from an INSERT; `insert_exists` explains nothing. Explained if at most one version group lacks a record. Unexplained keys that match an open lead go to their own `Always` messages ("... attributed to redelivery after crash (L1)", "... equal commit ts tie (L2)", "... commit clock reset after restart (L3)"). `Sometimes` markers for update-before-insert recorded, `delete_exists` kept a row, `delete_missing` then resurrecting insert, concurrent deletes converged, and "check ran on a diverged table". `Always` because one silent difference breaks the documented contract. |
| **Antithesis Angle** | Latency and partitions between pairs make an UPDATE or DELETE from one node reach a third node before the INSERT from another (`update_missing`, no waiting retries in v1), and make delete/update and delete/delete races; node kills reach L1 and L3; global clock skips reach L2; graceful worker exits during replay (L7) and misclassified transient errors (L5) are what would leave a change dropped with no record. |
| **Why It Matters** | Spock claims "non-resolvable conflicts are recorded in `spock.exception_log`" and resolvable ones in `spock.resolutions` (`docs/conflict_types.md:12-15`); that is what makes the documented no-tombstone and `update_missing` divergences acceptable and repairable (ACE). Several properties cite this oracle; none owns it, and the catalog bans the most common multi-master pattern instead of checking it. |

**Open Questions:**

- Which `exception_behaviour` values score it? Designed for `transdiscard`; `discard` works if E1 matches by key only; `sub_disable` cannot use the app table. `(partial: DISCARD logs only the failing change, code-checked)`
- Is "at most one unexplained version group" what the team means by S2, or only "some differing node has a record"?
- Should a difference explained only by a transient-class error row (57014, 40P01, 08xxx) count as explained, or be left to the classifier properties as now?
- How large can an Antithesis clock jump be? Decides whether the resolutions snapshot is required or only safer.

Priority: P1 — the main user-facing claim (S2) for realistic traffic, and the only property that runs create-here/edit-there.
Topology: v1
Key faults: latency, partition, node kill, global clock skip, worker exit
Confidence: medium (row-per-conflict mapping code-checked; the matching rule is new and untested)
Surfaced by: Evaluation gap a
Evidence file: properties/every-divergence-explained-by-spock-records.md

Design notes carried in the evidence file:

- Conflict to row map (code-checked): `insert_exists` -> resolutions (both
  outcomes); `update_origin_differs` and `delete_origin_differs` -> no row
  for either outcome (3bb8ad84 extended this to local-wins); `update_missing`
  and `update_exists` -> `exception_log` via the error path; `delete_exists`
  and `delete_missing` -> resolutions. Under TRANSDISCARD every change of a
  dropped txn gets its own `exception_log` row.
- Divergences with no row: L1 redelivery resurrection, L2 equal-ts tie, L3
  restart clock, rows copied with `'epoch'` ts on n4 (owned by the add_node
  property), FAILED table skipped by apply (L12). Frozen tuples make remote
  win everywhere, so they do not diverge by themselves.
- `spock.resolutions` cleanup runs at **every apply worker start** and then
  every 24 h of wall clock, deleting `log_time < now() - retention_days`
  (default 100). Snapshot the table during the run by re-reading it in full
  and taking the union by `(node, id)`; do not poll `id > last_seen`
  (sequence values are taken before commit, so concurrent apply workers
  commit them out of order). Or set `resolutions_retention_days = 0`.
  `exception_log` is never cleaned by Spock.
- Workload: PK-only table with a `(ver_node, ver_seq)` version stamp per
  write; own-range keys plus a small shared pool; updates and deletes biased
  toward keys just created on other nodes; history records xid, write set
  and origin commit ts; unknown commits settled with `pg_xact_status(xid)`;
  `pg_postmaster_start_time()` polled per node for L1/L3 attribution.
  Optional partitioned variant for partition-key moves (wildcard W10).

### strict-final-round-has-no-exemptions — A final round runs every convergence check with no state exemptions

| | |
|---|---|
| **Type** | Liveness |
| **Property** | After faults stop and the workload has run the operator recovery steps, every convergence check runs at least once in a fully healthy cluster (all subscriptions enabled and replicating, every table `r` on every node, readonly off, n4 joined or cleanly removed, every ordered barrier passed) with no state exemption, and passes. |
| **Invariant** | In a `finally_` command: workload `Always("strict round: <check> passed with no state exemptions")`, one message per existing oracle (ledger, exactly-once audit, delta counters, contested rows, all-or-nothing, app table explained, no orphan slots, connections). `Sometimes("strict round completed with zero exemptions in a fully healthy cluster")`, `Sometimes("strict round reached full health after recovering from exemptions")`, `Sometimes("strict round included the joined node")`. History attributions (L1, L3, n4 copy) are kept under their own messages, not removed. If health is not reached, the round records it and does not score (the failure belongs to `operator-recovery-steps-restore-replication`). `Sometimes` for the anti-vacuity markers because the round is not guaranteed to run on every timeline; `Always` for the checks because each must hold whenever the round runs. |
| **Antithesis Angle** | Runs at the end of timelines that left disabled subscriptions, FAILED tables, partial add_node and readonly toggles behind. A check that passes normally but fails here shows that an exemption hid a real problem. |
| **Why It Matters** | Each exemption is reasonable alone, but together they can mean the strict checks only ever ran on an easy slice of the cluster. Without this, a green run does not show that any check ever ran with every table READY and n4 joined. |

**Open Questions:**

- Is the terminal quiet period of a `finally_` command long enough for recovery plus barriers plus checks?
- Must n4 be joined in the strict round (retry add_node), or is clean removal acceptable?
- Must a reached barrier stay reached across a restart? (Catalog-wide barrier contract question; barriers run twice until settled.)

Priority: P0 — oracle health: without it every exemption in the P0/P1 data properties can hide a failure for the whole run.
Topology: v1
Key faults: all (needs runs that leave visible failures behind)
Confidence: high that it is needed; the check list is a harness choice
Surfaced by: Evaluation gap a
Evidence file: properties/strict-final-round-has-no-exemptions.md

### operator-recovery-steps-restore-replication — Documented recovery steps bring replication back

| | |
|---|---|
| **Type** | Liveness |
| **Property** | When faults are off, each documented operator step taken on a visible failure restores replication within a bound: `sub_enable` on a disabled subscription, `sub_resync_table` on a FAILED or stuck table, drop and re-create after an interrupted initial sync, `remove_node` plus retry after a failed add_node. |
| **Invariant** | Workload `Always(bounded)`, one message per step: "operator recovery: re-enabled subscription replicates again within bound", "... resynced table reaches READY within bound", "... re-created subscription after interrupted initial sync replicates within bound", "... add_node retry after cleanup succeeds". `Sometimes("operator recovery: <step> ran and the next strict round passed")` per step. Steps also run during fault phases but are scored only with faults off. `Always` because a documented recovery that does not recover with faults off is a failure each time. |
| **Antithesis Angle** | Faults create the visible failures (kills and partitions during table sync, initial sync, add_node; admin churn); the strict round and requested quiet periods then test that the recovery path works on the state those faults left: stale SYNC worker slots (L12), sync workers ignoring SIGTERM until COPY ends (G7), ZODAN leftovers (L20), stale progress rows on re-add. |
| **Why It Matters** | Spock relies on operators for these recoveries and the catalog treats "visible failure" as a pass. If the documented step does not work, a visible failure is in practice permanent. |

**Open Questions:**

- Is drop and re-create the intended recovery for a subscription whose initial sync stopped in `s`/`d`/`c`? `sub_enable` re-disables it and the docs give no step.
- Should v1 run `sub_resync_table` during fault phases? (Catalog-wide open question; this property needs it at least in the final round.)
- What bound does the team accept for each step? (Same as `mesh-barriers-complete-after-partition-heal`.)

Priority: P1 — tests the recovery the catalog currently assumes works; absorbs candidate G1 (`table-resync-under-faults-ends-ready`).
Topology: v1
Key faults: kill / partition during table sync, initial sync and add_node; admin churn
Confidence: medium (steps from docs and code; bounds are harness choices)
Surfaced by: Evaluation gap a
Evidence file: properties/operator-recovery-steps-restore-replication.md

## Gap items judged already covered

- **Item 3, delete conflicts beyond causal deletes:** covered by
  `every-divergence-explained-by-spock-records` (delete/update,
  delete/delete, delete-before-insert at a third node, each with its own
  `Sometimes`). The accuracy of the `delete_exists` / `delete_missing` rows
  themselves is already `resolutions-rows-match-applied-outcome`. No
  separate property.
- Concurrent insert/insert being dropped instead of resolved is already
  `insert-race-resolved-not-discarded`; here it only shows as an explained
  difference with its root cause in the details.

## Suggested extensions to existing properties

- `convergence-check-runs-after-faults`: cross-reference the strict round;
  its "ran with all subscriptions enabled" marker is weaker than
  "strict round completed with zero exemptions". No change to its
  assertions needed.
- `exception-log-matches-discarded-transactions`: use the app table's
  natural `update_missing` drops as a traffic source in addition to the
  deliberate poison transactions.
- `resolutions-rows-match-applied-outcome`: score `delete_exists` and
  `delete_missing` rows produced by app-table traffic (today those come
  only from narrow races).
- `contested-rows-converge-after-quiesce`: no change; the app table's
  L2/L3 attribution messages are a second source for the same leads with
  realistic traffic.
- `deployment-topology.md` node config: add
  `spock.exception_logging = all` (default, but must not be changed) and
  decide `resolutions_retention_days` (snapshot vs 0).
- Catalog candidate G1 (`table-resync-under-faults-ends-ready`): fold into
  `operator-recovery-steps-restore-replication`.
