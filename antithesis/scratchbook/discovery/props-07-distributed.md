---
sut_path: /home/msharp/dev/pgedgea/spock
commit: 69d9228f5df363761dc3ae6eebf7e2fcfe49b8e5
updated: 2026-10-13
external_references: []
---

# Property discovery, focus 7: distributed coordination

Spock is leaderless. There is no consensus, quorum or leader election, so
"split brain" is the normal operating mode: every node accepts writes and
conflicts are settled after the fact by last-update-wins (LUW) on commit
timestamps. The coordination that does exist is:

- the conflict rule itself (timestamp, then per-node tiebreaker), which has to
  give the same answer on every node no matter the arrival order;
- the commit-clock patch (025), a Lamport-style clock that keeps a node's
  local commits later than anything it has applied;
- per-pair replication channels that must heal on their own after
  partitions (no relaying in a default mesh);
- `spock.progress`, a per-pair progress record used for lag monitoring and by
  ZODAN;
- ZODAN add_node / remove_node, PL/pgSQL scripts that coordinate several nodes
  over dblink (pause on the provider, slot creation, progress capture, slot
  advance, subscription creation).

The properties below target those points. Four of them were also written in
parallel by other focuses under different slugs (noted per entry). Reaching
the same property from two directions is a confidence signal; the synthesis
step should merge them.

## Category A: LUW determinism across 3+ writers and clocks

Whether every node picks the same winner for a contested row, and whether the
winner is the one the docs promise.

### luw-tiebreak-against-third-origin-row-reached — Equal-ts tiebreak runs against a row from a third node

| | |
|---|---|
| **Type** | Reachability |
| **Property** | At least once per run, the equal-timestamp branch of `conflict_resolve_by_timestamp` runs on a node whose local row came from a third node (neither the applying node nor the sender), which is the only state where lead L2 can make nodes disagree. |
| **Invariant** | SUT-side `Sometimes(local_origin != Invalid && local_origin != remote_origin && local_origin != applying node id, "LUW equal-ts tiebreak with local row from a third node")` in `src/spock_conflict.c` after the same-origin shortcut (`:153-158`). Sometimes fits: this is a rare, meaningful state Antithesis should be steered to and confirm it reached; it is not an invariant. Missing today (no Antithesis assertions exist). |
| **Antithesis Angle** | Clock skew makes ties likely: after a node with a fast clock commits at T, lagging nodes that applied it stamp their next local commit T+1us (patch 025), so two of them can tie. Network latency then varies which of the tied versions reaches the third node first; the outcome on that node depends on that order. |
| **Why It Matters** | Without this marker, a green contested-row convergence result may only mean no tie with a third-origin row ever occurred. With tiebreakers A=2, B=1, C=3 and A, C tied, B keeps C's version if C arrives first, while A and C hold A's version (code-checked; rule from 64ea462d). |

**Open Questions:**

- Does Antithesis clock jitter give containers different clocks? If not, ties need a test-only knob.
- Which pair is the tiebreaker meant to compare (applying node vs sender, or tuple origin vs sender)? Decides whether the divergent outcome is a bug or a limit.

Confidence: high (mechanism code-checked; marker placement is direct)
Evidence file: properties/luw-tiebreak-against-third-origin-row-reached.md
Related: `contested-rows-converge-after-quiesce` (safety oracle, other focus), `clock-step-forward-makes-commit-ts-ties` (other focus, same reachability goal from the clock side).

### luw-final-version-has-max-commit-ts — Contested rows end at the max-commit-ts version on every node

| | |
|---|---|
| **Type** | Safety |
| **Property** | For rows seeded everywhere and then only updated from several nodes, every node's final version is the write with the largest recorded commit timestamp whenever that maximum is unique. |
| **Invariant** | Workload `Always(final payload on node == payload of max-ts write, "contested row holds max commit-ts version on every node")`, evaluated per (node, key) after barriers on all ordered pairs. Each write's ts comes from `pg_xact_commit_timestamp(txid)` on its origin after commit, so the oracle uses the adjusted commit ts that peers compare, not wall clock. Always fits: Spock claims this for every resolved conflict (`docs/conflicts.md:60-64`). |
| **Antithesis Angle** | Restart plus clock skew reaches L3: a node that applied a later remote version restarts with its logical clock at 0 and overwrites the row with a smaller ts; it keeps its own write while peers keep the remote one. Partitions vary arrival order. |
| **Why It Matters** | Convergence alone misses nodes agreeing on the wrong version, and does not name which node holds the wrong one. Wrong winners are silent: no exception row, no resolution row for origin-differs updates. |

**Open Questions:**

- Is the restart-unsafe commit clock (patch 025 TODO) an accepted limit? `(needs human input)`
- Does the origin's `pg_xact_commit_timestamp(xid)` always equal the timestamp sent to peers?

Confidence: medium (oracle well defined; whether L3 is a bug is not settled)
Evidence file: properties/luw-final-version-has-max-commit-ts.md
Overlap: same property as `luw-final-value-is-newest-commit` (other focus, which also defines the tie case).

### local-overwrite-gets-later-commit-ts — A local overwrite commits after the version it replaced

| | |
|---|---|
| **Type** | Safety |
| **Property** | When a client on node X reads a row version with `FOR UPDATE` and overwrites it, the overwrite's commit timestamp is strictly greater than the replaced version's, including right after X restarts. |
| **Invariant** | Workload `Always(new_ts > seen_ts, "local overwrite commit ts exceeds the version it replaced")` per overwrite, with `seen_ts = pg_xact_commit_timestamp(xmin)` read in the same transaction and `new_ts` read after commit. Skip NULL `seen_ts`. Always fits: the commit-clock patch states the guarantee for every local commit. |
| **Antithesis Angle** | Needs node restart and a node clock behind a peer's (or a backward step). The window is the first seconds after restart, up to the size of the skew; Antithesis's restart timing explores whether a client write lands in it. |
| **Why It Matters** | Detects L3 at the moment it happens and on the node where it happens. A violation means the causally later write loses on every peer while the writing node keeps it, a permanent divergence. |

**Open Questions:**

- Is the restart gap an accepted limit, and is there a documented maximum clock skew? `(needs human input)`
- Does Antithesis clock jitter apply per container?

Confidence: high on mechanism (patch TODO states it), medium on it being treated as a bug
Evidence file: properties/local-overwrite-gets-later-commit-ts.md
Overlap: same property as `local-commit-ts-above-overwritten-version` and close to `local-overwrite-after-remote-read-wins-everywhere` (other focuses).

### apply-survives-provider-clock-ahead — A subscriber behind its provider's clock does not crash

| | |
|---|---|
| **Type** | Safety |
| **Property** | A subscriber whose wall clock is behind its provider's keeps applying; the `handle_commit` progress Assert `last_updated_ts >= remote_commit_ts` (`src/spock_apply.c:~1174`, "XXX: Don't care in production yet") is never violated. |
| **Invariant** | SUT-side `Unreachable("handle_commit progress assert: remote commit ts ahead of local clock")` just before the existing Assert, with both timestamps. Unreachable fits: Spock's conflict model exists because clocks differ, so reaching this state is the defect. Missing today. Workload backup: no postmaster restart with "terminated by signal 6" for a spock apply process outside injected kills. |
| **Antithesis Angle** | Any skew where provider time exceeds subscriber time by more than the replication delay. In the cassert build the Assert aborts, the postmaster restarts the node, the same transaction is resent, and it fails again while skew lasts: a crash loop. |
| **Why It Matters** | Decides whether clock faults can run with the planned cassert image at all; if it fires, every clock timeline becomes a crash loop that hides the LUW properties. It is also a real defect for debug builds and CI. |

**Open Questions:**

- Build without cassert for clock runs, or fix the Assert first? `(needs human input)`
- Does Antithesis skew clocks per container, or is a per-node offset fault needed?

Confidence: high (direct code reading)
Evidence file: properties/apply-survives-provider-clock-ahead.md
Overlap: same property as `no-assert-crash-when-remote-commit-ts-ahead` (other focus).

## Category B: Partitions and per-pair recovery

How the leaderless mesh behaves when subsets are cut off and then healed,
and whether the reported progress tells the truth.

### mesh-barriers-complete-after-partition-heal — Every ordered pair recovers after partitions heal

| | |
|---|---|
| **Type** | Liveness |
| **Property** | After any mix of subset partitions, one-way loss and node pauses, once faults stop, `spock.sync_event()` on every node P is reached on every other member S within a fixed bound. |
| **Invariant** | In an `eventually_`/`finally_` test command: per ordered pair, `CALL spock.wait_for_sync_event(NULL, P, lsn, bound, false)`; `Always(result, "sync barrier P->S completes within bound after faults heal")`. Always (in the quiet period) rather than Sometimes because, with faults gone, a pair that does not recover within the bound is a liveness failure every time. Bound = `wal_sender_timeout + apply_idle_timeout + restart_delay_default + connect_timeout + catch-up margin`. |
| **Antithesis Angle** | Partitions that cut one pair while both still reach the third node, one-way loss (old walsender keeps the slot "active", new START_REPLICATION fails until `wal_sender_timeout`), silent drops with data in flight (only `apply_idle_timeout` notices), pauses of a provider. Each channel must heal on its own; a default mesh does not relay through the third node. |
| **Why It Matters** | Users are told to "wait for connectivity to return" (`docs/recovery/catastrophic_node_failure.md`) and that subscribers reconnect automatically. A pair that never resumes is silent: `sub_show_status` still says `replicating` (`src/spock_functions.c:1437-1540`). |

**Open Questions:**

- What recovery bound does the team accept after a partition heals?
- Keep `wal_sender_timeout` at 60 s in the harness, or the documented 5 min?

Confidence: medium (claim is clear; exact bound depends on harness settings)
Evidence file: properties/mesh-barriers-complete-after-partition-heal.md
Related: `apply-worker-restarted-within-bound-after-exit`, `committed-ledger-row-reaches-every-node` (other focuses; the latter is the data check that runs after these barriers).

### progress-commit-lsn-tracks-applied-commits — spock.progress keeps up with what was applied

| | |
|---|---|
| **Type** | Safety |
| **Property** | Once S has applied P's transaction T, `spock.progress.remote_commit_lsn` on S for (S, P) is at or beyond T's commit LSN on P. |
| **Invariant** | Workload: read `pg_current_wal_insert_lsn()` on P before T's COMMIT (a lower bound on T's end LSN); after T's row is visible on S, `Always(remote_commit_lsn(S,P) >= bound, "spock.progress commit LSN covers applied txn")`. Skip if S restarted in between. SUT-side alternative (missing): `Unreachable("progress commit LSN update dropped because commit ts went backwards")` in `progress_update_struct` (`src/spock_group.c:309-362`). Always fits: progress must cover every applied commit for its readers to be right. |
| **Antithesis Angle** | `progress_update_struct` updates the commit LSN only when the commit ts grows. After a provider restart with its clock behind its last commit ts (L3), P's new commits carry smaller ts and S's entry freezes until P's ts passes the old maximum. Needs restart plus skew. |
| **Why It Matters** | `spock.lag_tracker` then reports growing byte lag that is not real, and ZODAN Phase 3 (`zodan.sql:~1885-1960`) waits on this value, so add_node times out. Phase 7 is not affected since `read_peer_progress` now returns the origin's `remote_lsn`. |

**Open Questions:**

- Is `spock.progress` coordination state or advisory monitoring (code comments vs design doc vs ZODAN use)?
- Like the other L3 properties, it cannot fire without restart plus skew.

Confidence: medium (freeze mechanism code-checked; impact depends on the progress contract)
Evidence file: properties/progress-commit-lsn-tracks-applied-commits.md

## Category C: ZODAN membership changes

Adding and removing a node is the one place where Spock coordinates several
nodes in sequence. Nothing in it is atomic across phases.

### add-node-success-new-node-has-every-row — A successful add_node leaves the new node complete

| | |
|---|---|
| **Type** | Safety |
| **Property** | If ZODAN `spock.add_node` returns without error while n1-n3 keep writing under faults, then after barriers n4's ledger equals the union of acknowledged ledger rows on n1-n3 (none missing, none extra). |
| **Invariant** | Workload `Always(set(n4 ledger) == union of acknowledged rows on n1..n3, "add_node success: new node has every committed row")` after a successful add_node and a full barrier round; missing and extra keys reported in details. Always fits: S13 is claimed for every successful add (`zodan_tutorial.md:376, 415, 444`). Suggested SUT marker (missing): `Reachable` in the pause self-resume branch of `maybe_pause_for_slot_creation` (`src/spock_apply.c:~565-586`). |
| **Antithesis Angle** | Pause of src stretches `CREATE_REPLICATION_SLOT` past `spock.pause_timeout` so apply workers self-resume and commit inside the window (L4); partitions during Phase 3 make `create_sub` fail with only a NOTICE (L20); restarts of src drop progress entries so `read_peer_progress` skips a peer (INNER JOIN). |
| **Why It Matters** | Several past data-loss fixes in this exact path (dcbba6bb, a9bc8652, f38da44a, 986ad069, b7fc7022). A new node silently missing rows is permanent divergence that only an external repair tool finds. |

**Open Questions:**

- Is add_node expected to succeed when a Phase 3 subscription could not be created?
- How often does the `pg_current_wal_lsn()` fallback fire in CI logs?

Confidence: high (claim explicit; several mechanisms code-checked)
Evidence file: properties/add-node-success-new-node-has-every-row.md
Overlap: same property as `add-node-success-implies-complete-ledger-on-new-node` (other focus). Mechanism property for L4: `add-node-pause-held-until-progress-read` (other focus).

### add-node-success-has-sub-from-every-peer — A successful add_node produces a full mesh around the new node

| | |
|---|---|
| **Type** | Safety |
| **Property** | When ZODAN `spock.add_node` returns without error, n4 has an enabled subscription from every node that was a member when it started, and every such node has an enabled subscription from n4. |
| **Invariant** | Workload, right after add_node returns and again after barriers: `Always(every member has enabled sub to and from n4, "add_node success implies full mesh around new node")`, using `spock.subscription` joined to `spock.node` on each node. Always fits: it is a postcondition of a reported success. |
| **Antithesis Angle** | Partition or pause between n4 and one existing node X (or n4's own loopback dblink) during Phase 3. `create_sub` fails inside `EXCEPTION WHEN OTHERS THEN RAISE NOTICE` (`zodan.sql:2017-2036`), and the remaining phases run and return normally. |
| **Why It Matters** | A missing X->n4 subscription means X's changes after the COPY never reach n4, while the X->n4 slot pins WAL on X. The only trace is a NOTICE line. Cheaper and more specific than the row-level check, and it names the cause. |

**Open Questions:**

- Is "success with a missing Phase 3 subscription" intended (best effort) or should add_node fail? `(needs human input)`

Confidence: high (code-checked; other failure steps in the same procedure raise)
Evidence file: properties/add-node-success-has-sub-from-every-peer.md

### remove-node-clean-report-no-leftovers — A clean remove_node leaves no links to the removed node

| | |
|---|---|
| **Type** | Safety |
| **Property** | When ZODAN `spock.remove_node(n4)` finishes with no `ERROR` rows in its `temp_removal_status` table, no survivor still has a subscription from n4 or a slot that served one of n4's subscriptions. |
| **Invariant** | Workload records n4's `sub_slot_name`s before the call, reads `temp_removal_status` in the same session after it, and if there are no `ERROR` rows checks each survivor: `Always(no leftover slot or subscription for n4, "remove_node clean report means survivors have no links to removed node")`. Always fits: it is a postcondition of a reported clean removal. |
| **Antithesis Angle** | Partition between n4 and a survivor X during remove_node Phase 3. n4's local `sub_drop` cannot reach X, logs only `WARNING "could not drop slot ... drop it manually"` (`src/spock_functions.c:840-860`) and returns true; zodremove records `REMOVED`. |
| **Why It Matters** | The orphan slot on X has no consumer and holds WAL forever, eventually filling a survivor's disk, while the removal reported success. Data from n4 is not checked (documented that it may exist on some survivors only). |

**Open Questions:**

- Is reporting success when the remote slot could not be dropped intended? If yes, the property becomes "the WARNING is surfaced in the report".
- Is "all nodes available" a precondition for remove_node, as it is for add_node?

Confidence: medium (mechanism code-checked; contract unclear)
Evidence file: properties/remove-node-clean-report-no-leftovers.md
Related: `no-orphan-slot-pins-wal-after-quiesce` (other focus, general orphan-slot check).

## Areas examined

- Conflict resolution: `src/spock_conflict.c:99-320` (`conflict_resolve_by_timestamp`, `try_resolve_conflict`), `get_tuple_origin`; tiebreaker loading `src/spock_node.c:480-532`; node id collision check `:360-383`; commit 64ea462d and its message.
- Commit clock: `patches/18/pg18-025-logical_commit_clock.diff` (`EnsureMonotonicTransactionStopTimestamp`, TODO on restart safety); `handle_commit` setting `remoteTransactionStopTimestamp`.
- Progress: `handle_commit` progress block `src/spock_apply.c:~1140-1180` (found the clock Assert), `progress_update_struct` `src/spock_group.c:309-362`, `spock_group_ensure_entry` `:245-283`, force-set `:745-825`, `read_provider_progress` key build `src/spock_sync.c:520-560`, `spock.progress` / `spock.lag_tracker` / `read_peer_progress` in `sql/spock--6.0.0.sql`.
- Pause: `spock_pause_apply_workers` `src/spock_functions.c:4059-4125`, `maybe_pause_for_slot_creation` `src/spock_apply.c:~565-586`.
- Origins and forwarding: `handle_origin`, `resolve_forwarded_origin_for_transaction`, `maybe_advance_forwarded_origin` `src/spock_apply.c:1299-1360, 5148-5183`.
- Cross-upstream insert race: `spock_apply_heap_insert` `src/spock_apply_heap.c:837-925`, `FindReplTupleInLocalRel` `:394-438`, `src/spock_common.c` lock/retry. Not written up here because `insert-race-resolved-not-discarded` (other focus) already covers L6a with the same mechanism.
- ZODAN: `samples/Z0DAN/zodan.sql` Phase 3 (`:1794-2040`, catch-up wait `:1885-1960`), Phase 7 (`:2530-2680`), `create_sub` dblink path; `samples/Z0DAN/zodremove.sql` (`remove_node`, `remove_node_subscriptions`, registry removal); `sub_drop` remote slot handling `src/spock_functions.c:840-860`; `node_drop` slot cleanup `:335-360`.
- Docs: `docs/conflicts.md`, `docs/conflict_types.md:165-180`, `docs/modify/zodan/*`, `docs/FAQ.md`, grep of `docs/` for clock/skew/NTP (no clock-sync requirement found).

Not turned into properties:

- **Forwarded origins**: every ZODAN `create_sub` passes `forward_origins = ARRAY[]` (`zodan.sql:2024, 2252, 2347`) and the planned topology is a default mesh, so `maybe_advance_forwarded_origin` is not reachable in v1. Echo prevention in the mesh is covered by `no-change-applied-on-its-origin-node` (other focus). A cascade topology would be needed for L19.
- **Concurrent add_nodes / stale resume from another caller** (L4d, one global pause flag): the topology has one spare node, so two overlapping add_nodes are not planned.
- **Phase 7 reading `0/0` instead of NULL**: when src lacks a progress entry for X, n4 still has a zero entry from `spock_group_ensure_entry`, so Phase 7 skips the slot advance rather than falling back. That gives re-delivery (duplicates, delta double-count), not loss; covered by the exactly-once/delta properties of other focuses and noted in `add-node-success-new-node-has-every-row`.

## Assumptions affecting multiple properties

- **Clock control.** The L2/L3 properties (`luw-tiebreak-against-third-origin-row-reached`, `luw-final-version-has-max-commit-ts`, `local-overwrite-gets-later-commit-ts`, `progress-commit-lsn-tracks-applied-commits`) and `apply-survives-provider-clock-ahead` assume Antithesis can give different nodes different clocks or step one node's clock. If it cannot, they will pass without being exercised.
- **cassert and clocks interact.** With the planned cassert image, any provider-ahead skew triggers the `handle_commit` Assert and crash-loops the subscriber, which would hide the other clock properties. Resolve `apply-survives-provider-clock-ahead` (fix, or run clock faults on a non-cassert build) before reading results of the others.
- **Workload records commit timestamps.** The LUW oracles read `pg_xact_commit_timestamp(txid)` on the origin right after commit; this assumes the value stored in `pg_commit_ts` is the one the walsender sends (the patch rewrites `xlrec->xact_time` before insertion, so decoding should see the same value).
- **Contested table shape.** Seeded once and barrier-confirmed on all nodes, then UPDATE only, PK only, no deletes, no delta columns, unique tiebreakers per node; keeps all properties clear of the documented `update_missing` and no-tombstone divergence (sut-analysis section 12).
- **Barriers as the quiesce signal.** Convergence-style checks run only after `sync_event` / `wait_for_sync_event` succeed for every ordered pair, never on `sub_show_status = replicating`.
- **ZODAN is the add/remove path** (`samples/Z0DAN/zodan.sql`, `zodremove.sql`), run on n4 over dblink; a failed add or remove is acceptable, only a reported success is held to a postcondition.
