# contested-rows-converge-after-quiesce

## What the property says

For a workload of concurrent UPDATEs to the same pre-existing rows from all
mesh nodes (no deletes, no inserts of contested keys), once writes stop,
faults heal and the barriers pass, every node holds byte-identical contents
for every contested row.

## Why the scope is this narrow

sut-analysis section 12 lists documented divergence that must not be flagged:
no tombstones (DELETE vs UPDATE), `update_missing` ordering in 3+ node meshes
(UPDATE of a row inserted elsewhere reaching a third node first), permanent
node loss, `discard` mode, `skip_lsn`, `repair_mode`, frozen tuples, sequences.
Pre-seeding the rows (insert once, barrier, then only UPDATE) removes all of
them. What is left is the core claim: LUW gives one deterministic winner per
row (`docs/conflicts.md:60-64`, `docs/conflict_types.md:173-176`, S1).

## Mechanism

- `spock_handle_conflict_and_apply` (`src/spock_apply_heap.c:589-790`) reads
  the local row's commit ts and origin from `pg_commit_ts`
  (`get_tuple_origin`, `src/spock_conflict.c:219-275`) and calls
  `conflict_resolve_by_timestamp` (`:99-200`): later ts wins; equal ts with the
  same origin applies remote; otherwise compares the tiebreaker of **this
  applying node** with the remote origin node; lower keeps local.
- The pgEdge commit-clock patch (025) keeps each node's local commit ts above
  any remote ts it has applied (until restart, L3).

## Ways it could break (leads)

- **L2 equal timestamps with 3+ writers**: the tiebreak compares the applying
  node, not the writer of the local row (introduced by 64ea462d, comment at
  `src/spock_conflict.c:131-146` explains why). Example with lower-wins,
  tiebreakers A=2, B=1, C=3, A and C write the same row at equal ts: A keeps
  A's version; C applies A's; B receives C's first and then A's, B(1) < A(2)
  keeps C's -> B differs from A and C. Equal tiebreakers apply remote on both
  sides and swap values.
- **L3 commit clock not restart safe**: after a restart a node behind in wall
  time can stamp a local update with a ts lower than a remote version it
  already holds; it keeps its own row, peers keep the remote one.
- **L5/L7 drops** and **L6a insert/insert race** turn a resolvable conflict
  into a dropped transaction on one node (with an `exception_log` row).
- **Frozen xmin / truncated commit_ts**: local ts 0 -> remote always wins,
  unlogged. Workload should keep the run short enough or set
  `vacuum_freeze_min_age` high; note as fairness issue.

## Oracle design

- Setup: `contested(id int primary key, writer text, wseq bigint, v text)`,
  R rows (small R, e.g. 20, to force collisions), inserted on one node,
  barrier.
- Writers on all three nodes: `UPDATE contested SET writer=:node,
  wseq=:seq, v=:random WHERE id = :r`, single-row and multi-row transactions.
- Check: after barriers for every ordered pair, read all rows from each node
  ordered by id and compare. `Always(all mesh nodes return identical rows)`.
  On failure, report the differing ids with each node's (writer, wseq) and
  `pg_xact_commit_timestamp_origin(xmin)` per node, and whether the two
  candidate versions had equal commit ts (to separate L2 from other causes).

`Always`: any difference after quiescence, in scope, is a violation.

## Fault requirements

- Network partitions/latency between pairs (changes arrival order so that
  different nodes see versions in different orders).
- Clock jitter that makes equal commit ts likely (L2) and node restarts with
  a node behind in time (L3). Without clock faults, L2/L3 are unlikely to fire,
  but the property is still valuable against drop paths.
- Node termination and graceful worker exits (drop paths).

## SUT-side instrumentation (missing)

- In `conflict_resolve_by_timestamp`, equal-ts branch:
  `Reachable("LUW tiebreak used with distinct origins")` so the run confirms
  the L2 state was reached. Also `Sometimes(cmp == 0 && local_origin !=
  remote_origin, "equal commit ts conflict between different origins")`.
- `Unreachable("equal tiebreaker values between applying node and remote")`
  at the WARNING at `:167-182` (nodes created by the harness have unique
  tiebreakers).

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (wildcard W2); see `evaluation/synthesis.md`.

Current catalog line: Priority: P0 · Topology: v1 · Faults: clock skew, partition, latency, node kill

- Evaluation note (2026-10-13): the divergence message is split into "divergent key last written by a node within N s after its restart that followed a backward clock skip" (explained by L3), "divergent key whose top versions tie on commit ts" (L2, reported) and "divergent key, unexplained". Only the unexplained message counts as a new finding while L2/L3 are open.

## Open questions

- Is the applying-node tiebreak (64ea462d), which lets 3 nodes diverge on equal commit ts, intended? `(needs human input)`
- Is divergence from the restart-unsafe commit clock (L3) an accepted limit? `(needs human input)`

Resolved during investigation (see log): the strict form (no exception-log
"explanation") stays, because this workload produces no documented-unresolvable
conflicts; Antithesis clock skips are global, and a global **backward** skip is
enough to reach both L2 ties and L3 (no per-node clock needed). Under a cassert
build any backward skip also trips the `handle_commit` progress Assert
(`apply-survives-provider-clock-ahead`), so clock-fault runs need the
SPOC-688 fix (branch `task/SPOC-688/apply-clock-skew-fix`, removes that
Assert) or a non-cassert build.

If the team says the L2 rule is intended: scope the `Always` to rows whose
final candidate versions had distinct commit ts and keep the `Reachable`
markers. If L3 is accepted: exclude rows written by a node after a restart
while its wall clock was behind the newest version it held.

## Fault requirements update

Clock faults: Antithesis "clock skips" move all nodes together (shared virtual
time). Backward skips reach L2 and L3 (see `clock-step-forward-makes-commit-ts-ties`
and `local-overwrite-gets-later-commit-ts`). Per-node offsets need a custom
fault and are not required for this property.

### Investigation Log

#### Is convergence under equal timestamps with 3+ writers intended (L2)?

- Examined: `git show 64ea462d` (message and diff), `src/spock_conflict.c:99-201`
  at HEAD, `docs/conflict_types.md:173-176`, `tests/tap/t/025_tiebreaker_equal_warning.pl`,
  `git log --all -- src/spock_conflict.c` (no later change to this rule on any branch).
- Found: before 64ea462d the equal-ts branch compared the **tuple's origin
  node** (or this node, if the row was written locally) with the sender. That
  rule compares the two writers on every node, so it converges with any number
  of writers. 64ea462d switched to "this applying node vs sender" to stop a
  spurious equal-tiebreaker WARNING in a single-writer topology and on node-id
  hash collisions. The same commit also added the same-origin shortcut
  (`local_origin_id == remote_origin_id` -> apply remote) and a collision check
  at node creation; together those already remove both stated causes, so the
  switch to the applying node is not needed for either. The only test
  (025) is 2-node, single writer. Docs say "the node with the lower
  tiebreaker value wins", which reads as the writer.
- Not found: any statement that 3-node divergence on ties is accepted.
- Conclusion: the code history points to an unintended side effect of a
  warning fix, but intent needs the team. `(needs human input)`

#### Is clock-skew-plus-restart divergence (L3) accepted?

- Examined: patch `025-logical_commit_clock` for PG15-19 (`git log --all -p`),
  `src/` for `XLogSetLastTransactionStopTimestamp`, `docs/` for clock/skew/NTP.
- Found: the "not postmaster restart safe" TODO is in every version, including
  the newest PG19 patch. Spock never sets the logical clock
  (`XLogSetLastTransactionStopTimestamp` is unused outside core). Spock does
  scan `pg_commit_ts` at restart (`recover_progress_timestamps_from_commit_ts`,
  `src/spock_progress_recovery.c:295`) but only for progress, not the clock.
  No user doc bounds clock skew.
- Conclusion: no fix on any branch; acceptance needs the team. `(needs human input)`

#### Should exception_log rows "explain" a difference?

- Examined: the oracle design in this file and sut-analysis section 12.
- Found: the workload pre-seeds rows and only UPDATEs, so none of the
  documented unresolvable conflict types can occur.
- Conclusion: resolved, keep the strict form; an exception_log row in this
  table is itself a finding for the classifier/exception properties.

#### Can Antithesis produce the clock states L2/L3 need?

- Examined: `snouty docs show /docs/product/writing_tests/controlling_faults/fault_types/`.
- Found: "Clock skips affect every node simultaneously because Antithesis
  simulates a shared wall clock"; skips move forward or backward, temporary or
  permanent. With patch 025, after a global backward skip every node's
  logical clock is ahead of its wall clock, so local commits are stamped
  `clock + 1 us`; two nodes whose last clock move was applying the same remote
  commit stamp the same value (L2 tie). A node restarted inside the skip loses
  its clock and stamps wall time below versions it holds (L3).
- Conclusion: resolved; built-in global backward skips are enough.
