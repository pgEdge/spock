---
sut_path: /home/msharp/dev/pgedgea/spock
commit: 69d9228f5df363761dc3ae6eebf7e2fcfe49b8e5
updated: 2026-10-13
external_references: []
---

# Property discovery — Focus 11: Wildcard

Lens: things the other ten focuses are unlikely to check. Three themes came
out of it:

- **Values and names that are local to one node** but get shipped as if they
  were global: unchanged TOAST columns filled from the local row, type OIDs
  inside binary datums, slot names without the subscriber in them, progress
  rows from an earlier life of the same node.
- **Faults that reach a known lead by a cheaper route than planned**: one
  forward clock step on one node makes commit-timestamp ties common across the
  cluster.
- **The oracle itself**: duplicates hidden by `insert_exists`, and
  convergence checks that pass because they never ran in a hard state.

No SUT-side Antithesis assertion exists in the tree (`existing-assertions.md`);
every SUT-side suggestion below is missing.

## Category: Value and identity fidelity across nodes

### luw-unchanged-toast-no-mixed-rows — Conflict winners never mix in the loser's TOAST value

| | |
|---|---|
| **Type** | Safety |
| **Property** | After quiescence, every row of a table with out-of-line TOAST columns is identical on all nodes, and each row equals a version some single transaction produced. |
| **Invariant** | Workload `Always("toast rows identical across nodes after quiesce")` over an ordered text dump of the TOAST table, plus `Always("toast row version tags consistent within the row")` where each update writes the same `<node>:<seq>` tag into the small column and into the TOAST payload. Suggested SUT-side `Reachable` in `slot_modify_data` (`src/spock_apply_heap.c:338-383`) when the remote won a conflict and a varlena column was filled from the local slot because it arrived as `'u'`. `Always` because one mixed row is a violation. |
| **Antithesis Angle** | Latency and partitions between node pairs let two nodes update the same row (one the TOAST column, one a small column) before seeing each other. The provider sends unchanged TOAST columns as `'u'` (`src/spock_proto_native.c:515-519`); when the remote wins, `spock_handle_conflict_and_apply` merges with the **local** row (`src/spock_apply_heap.c:636-640`), so one node ends with the remote's small column plus its own TOAST value while the origin keeps its old one. |
| **Why It Matters** | Spock claims whole-row LUW (`docs/conflicts.md:60-64`). This divergence is permanent, logs nothing (`update_origin_differs` is never saved to `spock.resolutions`), and later updates that do not touch the TOAST column never repair it. Existing tests use small rows, so this path is untested. |

**Open Questions:**

- Is the partial-row merge a known limitation or a bug?
- Does `REPLICA IDENTITY FULL` make the provider send unchanged TOAST columns in full?

Confidence: high
Evidence file: properties/luw-unchanged-toast-no-mixed-rows.md

### replicated-values-mean-same-on-every-node — Replicated values render the same on every node

| | |
|---|---|
| **Type** | Safety |
| **Property** | After quiescence every replicated row renders to the same text on every node, and no valid transaction is dropped because a node numbers its types differently. |
| **Invariant** | Workload `Always("replicated rows render identically on all nodes")` (ordered `row::text` checksum per table, same session settings everywhere) and `Always("no exception_log rows for type mismatch on valid data")`. Suggested SUT-side `Unreachable` in `decide_datum_transfer` (`src/spock_proto_native.c:641-671`) for (a) `'b'` chosen for a domain over a user array or composite, and (b) `'i'`/`'b'` chosen for an OID-alias type (`regclass`, `regtype`, `oid`, ...). `Always` because one wrong value is a violation. |
| **Antithesis Angle** | Mostly fault-independent; it breaks as soon as OIDs differ between nodes, which happens when n4 gets its schema through `pg_restore` or any node creates objects in another order. Domains have `typtype='d'`, `typelem=0` (checked on PG18), so they pass the send/recv test that the code comment says excludes arrays/composites "due to the embedded oids"; the receiver's `array_recv`/`record_recv` raises 42804, a data error, so TRANSDISCARD drops the whole transaction. OID-alias types go as raw `'i'` bytes and silently mean another object. |
| **Why It Matters** | Valid user data is silently dropped (domains) or silently changed (reg* types). It also breaks hash-based convergence oracles and produces TRANSDISCARD drops that look like the fault-driven silent-discard bugs (L5) during triage. |

**Open Questions:**

- Is the `'i'` transfer of OID-alias types documented or accepted anywhere?
- Does `force_text_transfer` avoid both cases? (expected yes, not run)

Confidence: high
Evidence file: properties/replicated-values-mean-same-on-every-node.md

### provider-slot-owned-by-one-subscription — A provider slot is used by one subscription only

| | |
|---|---|
| **Type** | Safety |
| **Property** | Each `spock_output` slot on a provider belongs to exactly one subscription in the cluster, and no subscription loses changes because another node's subscription created, dropped or consumed its slot. |
| **Invariant** | Workload `Always("provider slot used by at most one subscription")` from a cross-node join of `spock.subscription` (provider, slot name), plus the ledger completeness check at quiescence for the subscribers involved. Suggested SUT-side `Unreachable` in `spock_create_slot_and_read_progress` (`src/spock_sync.c:665-676`) and `spock_sync_worker_cleanup` (`:1428-1465`) when the slot about to be dropped has been confirmed past anything this subscription's origin knows. `Always` because one shared slot loses data. |
| **Antithesis Angle** | Slot name is `spk_<subscriber db>_<provider>_<sub name>` with uppercase mapped to `_` (`gen_slot_name`, `src/spock_functions.c:3666-3687`); the subscriber node is not in it. Two subscribers with the same subscription name (or names that differ only in uppercase letters) share one slot. A partition or restart of one subscriber while the other runs initial sync lets the second drop and recreate the slot (`NOT active` drop); a failed create triggers error cleanup that waits for the slot to go idle and drops it; `sub_drop` drops it too. Each subscriber then confirms positions the other never received. |
| **Why It Matters** | Silent, permanent data loss from a naming choice that every per-node check accepts. ZODAN and the docs use `sub_<provider>_<subscriber>`, so default paths are safe; hand-made meshes are not. Needs its own test configuration, not the main mesh. |

**Open Questions:**

- Is cluster-wide subscription-name uniqueness a documented requirement? `(partial: not found in sub_create docs or getting-started)`
- Should Spock reject the collision up front (changes the assertion to "rejected")?

Confidence: high
Evidence file: properties/provider-slot-owned-by-one-subscription.md

## Category: Oracle side channels and oracle health

### insert-once-keys-never-hit-insert-exists — Insert-only ledgers never produce insert_exists

| | |
|---|---|
| **Type** | Safety |
| **Property** | In a workload where every key is inserted once in the whole cluster, no node ever records an `insert_exists` resolution for those tables. |
| **Invariant** | Workload `Always("no insert_exists on insert-once ledger")`: `count(*) FROM spock.resolutions WHERE conflict_type='insert_exists' AND relname IN (<ledger tables>)` is 0, checked periodically and at quiescence; details record local/remote origin and timestamps. Companion `Always` for no `delete_missing` on tables never deleted from twice. Suggested SUT-side `Unreachable` for `local_origin_id == remote_origin_id && local_ts == remote_ts` on an INSERT in `conflict_resolve_by_timestamp` (limited to the ledger tables). `Always` because there is no legitimate source of these rows. |
| **Antithesis Angle** | A redelivered INSERT is turned into an UPDATE with the same values (`insert_exists`, apply remote), so plain ledger presence checks pass. The resolutions row is written inside the apply transaction (`spock_conflict_log_table`, `src/spock_conflict.c:628-756`), so it survives crashes exactly when the duplicate does. Catches L1 (kill -9 between checkpoints), L7, L18, L19, echo (S6), and add-node overlap (rows copied with `'epoch'` ts, `src/spock_sync.c:938-947`). |
| **Why It Matters** | Duplicate delivery is invisible to the obvious oracle but double counts delta columns, repeats trigger side effects, and can resurrect deleted rows on a joined node. This uses a table the product already writes (`save_resolutions=on`), so it costs no harness trigger. Complements focus 1's audit-trigger check `ledger-row-applied-exactly-once-per-peer`. |

**Open Questions:**

- Under TRANSDISCARD replay, does a duplicate of a previously failed transaction show only in `exception_log`?

Confidence: high
Evidence file: properties/insert-once-keys-never-hit-insert-exists.md

### convergence-check-runs-after-faults — Convergence checks actually run in hard states

| | |
|---|---|
| **Type** | Liveness |
| **Property** | During a run, the full cross-node convergence check completes at least once after a node kill, after a healed partition, with real data from every origin, with all subscriptions enabled, and on the joined node; and a barrier result is never accepted for a disabled subscription. |
| **Invariant** | Workload `Sometimes` with separate messages: "convergence check completed after at least one node kill", "... after a partition healed", "... covered rows from every origin" (at least N ledger rows per origin), "... ran with all subscriptions enabled", "... ran on the joined node". Plus `Always("barrier returned true only for enabled subscriptions")`. `Sometimes` because each is a state the run must reach at least once for the safety `Always`s to mean anything. |
| **Antithesis Angle** | Continuous faults can keep barriers from ever completing; silent partitions take up to `apply_idle_timeout` (300 s default) to detect; `wait_for_sync_event` returns early for disabled subscriptions unless `wait_if_disabled`. Any of these makes convergence `Always`s pass without checking. |
| **Why It Matters** | Without this, a green run can mean "never checked". It also catches harness bugs where the check silently compares a non-replicating pair. |

**Open Questions:**

- Are Antithesis quiet periods long enough for barriers, or does the template need explicit "stop faults, then check" phases?
- Is a timed-out barrier a liveness failure or a retry?

Confidence: high
Evidence file: properties/convergence-check-runs-after-faults.md

## Category: Cross-cuts with clock and lifecycle faults

### clock-step-forward-makes-commit-ts-ties — One forward clock step drags peers' commit timestamps ahead

| | |
|---|---|
| **Type** | Reachability |
| **Property** | A forward clock step on one node leads peers to stamp local commits ahead of their own wall clocks, and two nodes to stamp local commits with identical timestamps. |
| **Invariant** | Workload `Sometimes("local commit stamped ahead of local wall clock by the logical clock")`: right after a local commit, `pg_xact_commit_timestamp(xid) > clock_timestamp()` on that node. Second `Sometimes("two nodes committed local writes with identical commit timestamps")` from ledger commit timestamps after quiescence. `Sometimes` because these are states the run must reach so that the equal-ts conflict path (asserted in focus 1's `contested-rows-converge-after-quiesce`) is explored. No SUT change: the mechanism lives in core patch 025. |
| **Antithesis Angle** | Patch 025 (`EnsureMonotonicTransactionStopTimestamp`) raises the instance clock to any applied remote commit time and stamps later local commits `clock + 1 µs`. After n1 jumps ahead and commits, n2 and n3 both stamp their next local commits `T + 1 µs`, `T + 2 µs`, ..., so same-row updates tie exactly and go to the tiebreaker (L2). L2 then needs only one forward step bigger than replication latency, not frozen or aligned clocks. |
| **Why It Matters** | Changes the fault plan and the priority of L2: equal-timestamp divergence with three writers is reachable with ordinary per-node clock jitter. While the window is open, LUW winners depend on commit counts, not real time, which matters during triage. |

**Open Questions:**

- Does Antithesis step one container's clock at a time, or all together?
- Was the `+1 µs` bump expected to keep cross-node ties rare?

Confidence: medium
Evidence file: properties/clock-step-forward-makes-commit-ts-ties.md

### zodan-readd-node-progress-not-stale — Re-adding a node does not reuse its old progress rows

| | |
|---|---|
| **Type** | Safety |
| **Property** | Every successful add_node, including second and later adds of a node on the same instance, leaves the joined node with exactly the cluster's committed rows, with no duplicates. |
| **Invariant** | Workload `Always("re-added node holds exactly the cluster's rows")` after each successful add_node and quiescence (ledger completeness, no extra rows, plus `insert-once-keys-never-hit-insert-exists` on the joined node); workload `Sometimes("add_node succeeded on a node that had been removed before")`. Suggested ZODAN-side marker (missing): Phase 7 logs whether the chosen `spock.progress` row's `last_updated_ts` is after the add_node start; the workload asserts it always is. `Always` because one stale catch-up point duplicates or loses rows. |
| **Antithesis Angle** | `SpockGroupHash` entries are never deleted and survive restarts through `resource.dat` (`src/spock_group.c:36-42`). ZODAN Phase 7 (`samples/Z0DAN/zodan.sql:2637-2662`) reads `spock.progress` by `remote_node_id` only, with non-STRICT `SELECT INTO`. When `read_peer_progress`'s INNER JOIN omits a peer (source restart), a row from the previous life of the node is used instead of the documented fallback, the slot is not advanced, and the new node re-receives changes already in the COPY. A duplicated INSERT of a row deleted elsewhere before the snapshot resurrects it on the joined node only. |
| **Why It Matters** | Add-node catch-up has been fixed at least seven times (bug-history Pattern C), always tested on fresh nodes. Re-join is in the deployment plan, so the harness will exercise this path whether or not anyone targets it. |

**Open Questions:**

- Does anything clear progress-hash entries for a dropped node?
- Is re-adding a node under the same name supported?
- Should Phase 7 filter on the local `node_id`?

Confidence: low
Evidence file: properties/zodan-readd-node-progress-not-stale.md

---

## Areas examined

- Unchanged-TOAST encoding and the UPDATE merge (`src/spock_proto_native.c`
  write/read tuple, `slot_modify_data`, `spock_handle_conflict_and_apply`).
- Datum transfer selection (`decide_datum_transfer`) and the `'b'` receive
  path; `pg_type` rows for domains and OID-alias types checked on a throwaway
  PG18 instance.
- Slot and origin naming (`gen_slot_name`, `shorten_hash`), initial-sync slot
  creation and error cleanup, `sub_drop` remote slot drop, ZODAN subscription
  naming.
- Conflict reporting and the resolutions table (`spock_report_conflict`,
  `spock_conflict_log_table`), including which conflict types are never saved,
  and retention cleanup (100 days, not a clock risk).
- Core patch 025 logical commit clock.
- ZODAN Phase 7 progress lookup, `spock.progress` view definition, progress
  hash lifetime.
- Replicated DDL execution context: search_path is reproduced
  (`append_set_search_path`, `src/spock_functions.c:2388-2420`) and the origin
  role is used (`spock_execute_sql_command`); no property, and focus 6 already
  covers apply identity and search_path leakage.
- Apply transaction boundaries: one remote transaction maps to one local
  transaction (only sync-worker table catch-up splits it); focus 1's
  `remote-transaction-all-or-nothing-per-node` covers this.
- Subscription id sequence (`CYCLE` on integer): wraparound unreachable in a run.
- Considered and not turned into properties: TRUNCATE has no LUW, so a
  TRUNCATE racing with an INSERT on another node diverges (expected class,
  same as no tombstones; keep TRUNCATE out of conflict phases);
  `session_replication_role=replica` skips FK triggers (already excluded in
  §12); builds without lz4 receiving compressed `'i'` datums (same image on all
  nodes, out of scope).

## Assumptions affecting multiple properties

- **`spock.save_resolutions=on`** on every node; the resolutions-based
  properties fail open (pass silently) without it.
- **Update/update conflicts leave no table trail.** `update_origin_differs` and
  `delete_origin_differs` are never written to `spock.resolutions`
  (`src/spock_conflict.c:393-419`, documented in `docs/conflict_types.md`).
  Any oracle of the form "every difference is explained by resolutions or
  exception_log" cannot explain update/update divergence; it must use direct
  cross-node comparison for contested rows. Note the docs disagree with each
  other here (`docs/configuring.md:506-510` says "all conflict resolutions").
- **Ambiguous client commits.** When the workload's connection drops during
  COMMIT, it does not know whether the transaction committed. Ledger checks
  must record such rows as "unknown" and resolve them by reading the origin
  node after it is reachable, or they will report phantom losses or phantom
  extra rows.
- **Convergence comparisons should use text with fixed session settings**
  (DateStyle ISO, TimeZone UTC, extra_float_digits 3), on every node, so that
  node-local settings (the existing compose file sets `TZ=America/Toronto`)
  cannot cause false differences, and so that node-local binary values
  (OIDs) do cause true ones.
- **Per-node clocks.** The clock property, and L2/L3 in general, assume
  Antithesis can step one node's clock independently of the others.
- **Re-add uses the same container and data directory** (deployment plan
  "remove it and join it again"). If n4 is re-initialised instead, the
  re-add property only applies to the peers' progress rows.
- **Names in the main mesh** follow `sub_<provider>_<subscriber>`, lowercase,
  no `_<digit>` ending; colliding names live only in a separate configuration.
