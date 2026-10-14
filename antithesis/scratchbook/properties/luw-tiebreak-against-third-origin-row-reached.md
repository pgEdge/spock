# luw-tiebreak-against-third-origin-row-reached

## What the property says

During a run, at least once, the equal-timestamp tiebreak in
`conflict_resolve_by_timestamp` runs on a node B where the existing local row
came from a third node C (local tuple origin is neither B nor the remote
sender A). This is the only state in which lead L2 can make nodes disagree, and
it is rare enough that Antithesis needs a marker to steer toward it.

## Code path

- `try_resolve_conflict` (`src/spock_conflict.c:281-320`) passes
  `local_origin` (from `pg_commit_ts` via `get_tuple_origin`, `:219-275`) and
  `replorigin_session_origin` (the real origin node id set by `handle_origin`,
  `src/spock_apply.c:1331-1332`) into `conflict_resolve_by_timestamp`
  (`src/spock_conflict.c:99-201`).
- Equal timestamps (`cmp == 0`):
  - same origin on both sides -> apply remote (`:153-158`);
  - otherwise compare the tiebreaker of **this applying node**
    (`get_local_node`, `:160-162`) with the remote origin's tiebreaker
    (`:165-200`). Lower keeps local.
- This rule was introduced by 64ea462d ("fix spurious tiebreaker-equal WARNING
  in single-writer topology"). Before it, the local side was the tuple's
  origin node. The commit message explains the change only in terms of the
  two-node single-writer case.

## Why the third-origin case diverges (L2, code-checked)

Tiebreakers A=2, B=1, C=3 (lower wins). A and C update the same row with equal
commit ts.

- On A: local row is A's; C's change arrives; A(2) < C(3) -> keep A.
- On C: local row is C's; A's change arrives; C(3) > A(2) -> apply A.
- On B, if C's change arrives first it is applied normally (ts newer than the
  seed). Then A's change arrives with equal ts, local origin C. Compare
  B(1) vs A(2) -> keep local -> B holds C's version. A and C hold A's version.

If B gets A first, it holds A's version and all agree. So the outcome depends
on arrival order at the third node, which is exactly what network faults vary.
Docs say "The node with the lower tiebreaker value wins"
(`docs/conflict_types.md:173-176`); with the current code, on B "the node"
compared is B itself, which never wrote the row.

## How equal timestamps happen

- Without clock faults, two nodes committing in the same microsecond is
  unlikely.
- The commit-clock patch (`patches/18/pg18-025-logical_commit_clock.diff`,
  `EnsureMonotonicTransactionStopTimestamp`) bumps a local commit to
  `logical_clock + 1 us` when the wall clock is at or behind the clock. If two
  nodes with lagging wall clocks both applied the same remote commit at ts T
  and then each write the same row locally, both commits get ts T+1us. So
  clock skew makes ties likely (also noted by F6).
- Forcing: put one node's clock ahead; let it commit to a seed row; then
  update the same row on the two lagging nodes.

## Suggested instrumentation (missing; no Antithesis assertions exist today)

In `conflict_resolve_by_timestamp`, inside the equal-ts branch after the
same-origin shortcut:

```c
SOMETIMES(local_origin_id != InvalidRepOriginId &&
          local_origin_id != remote_origin_id &&
          local_origin_id != applying_node->node->id,
          "LUW equal-ts tiebreak with local row from a third node", ...)
```

Details to include: applying node id, local origin, remote origin, both
tiebreakers, the resolution. A second `Reachable` on the plain equal-ts branch
is useful as a coarser checkpoint.

## Relationship to other properties

The safety oracle for this state is the contested-row convergence property
(`contested-rows-converge-after-quiesce`, written by another focus). This
property only makes sure the run reaches the state; without it a green
convergence result may just mean no tie ever happened.

## Fault requirements

- Clock control (jitter or per-node skew) is needed in practice.
- Network latency/partitions between pairs to vary arrival order at the third
  node.
- 3 writers on the same keys (the planned n1-n3 mesh).

## Open questions

- Which pair is the tiebreaker meant to compare: the two writers (pre-64ea462d rule, docs wording) or the applying node vs the sender (current code)? `(needs human input)`

Resolved: Antithesis clock skips are global (shared virtual time), and a global
backward skip is enough to make ties likely (see log). No test-only knob or
per-node clock is needed. Fault requirement updated below.

## Fault requirements update

- Clock: global **backward** clock skips (built in, but must be enabled for the
  tenant). Per-node forward offsets also work but need a custom fault.
- Under a cassert build every backward skip also trips the `handle_commit`
  progress Assert (`apply-survives-provider-clock-ahead`). Build the image
  from a tree with the SPOC-688 fix (branch `task/SPOC-688/apply-clock-skew-fix`,
  commit 4e0988de removes the Assert) or run clock faults without cassert;
  otherwise the run crash-loops before reaching this state.

### Investigation Log

#### Is per-container clock skew available?

- Examined: Antithesis docs, `snouty docs show /docs/product/writing_tests/controlling_faults/fault_types/`.
- Found: "Clock skips affect every node simultaneously because Antithesis
  simulates a shared wall clock, called virtual time"; skips go forward or
  backward. Patch 025 (`EnsureMonotonicTransactionStopTimestamp`): apply
  commits set `clock = max(clock, own xact_time, remote ts)`; local commits
  with `clock >= wall` are stamped `clock + 1 us`. After a global backward
  skip of D, every node is in the bumped mode until wall time catches up.
  If n1 commits (ts c), and n2 and n3 both apply it and then each make their
  first local commit, both are stamped `c + 1 us`. Concurrent updates of the
  same row from n2 and n3 then tie, and n1 (a third node) sees one of them
  first, which is exactly this property's state.
- Conclusion: resolved. Global backward skips reach the state; no per-node
  clock and no test-only knob needed.

#### Which pair is the tiebreaker meant to compare?

- Examined: `git show 64ea462d`, `src/spock_conflict.c:131-200`,
  `docs/conflict_types.md:173-176`, `tests/tap/t/025_tiebreaker_equal_warning.pl`.
- Found: the pre-64ea462d rule compared the tuple's origin (or this node for a
  locally written row) with the sender, i.e. writer vs writer, which converges.
  64ea462d's stated reasons (single-writer spurious WARNING, node-id hash
  collisions) are both handled by the same-origin shortcut and the creation-time
  collision check added in the same commit. Only a 2-node test covers it.
- Not found: any doc or comment that accepts 3-node divergence on ties.
- Conclusion: code history suggests an unintended side effect, but intent
  needs the team. `(needs human input)`
