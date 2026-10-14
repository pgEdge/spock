# clock-step-forward-makes-commit-ts-ties

## Why this property exists

Lead L2 (equal-timestamp tiebreak compares the applying node, so 3+ writers
can diverge) is listed as needing "clock control / jitter (freeze or align
clocks)". Exact microsecond ties between independent nodes look rare, so L2
looks hard to reach. They are not rare. The logical commit clock patch turns a
single forward clock step on **one** node into a cluster-wide stretch in which
the other nodes stamp local commits as "highest remote timestamp seen + k
microseconds". Two nodes that applied the same remote commit and then each
make their first local commit get **the same** timestamp.

This is a cross-cut of clock faults (focus 7/concurrency), the core patch
(focus 10) and the conflict resolver (focus 1). It changes the fault plan: L2
does not need frozen or aligned clocks, only one forward step larger than
replication latency.

## Code path (HEAD 69d9228f)

`patches/18/pg18-025-logical_commit_clock.diff`,
`EnsureMonotonicTransactionStopTimestamp`:

- Apply-worker commit (`remoteTransactionStopTimestamp != 0`): instance clock
  `= max(clock, own xact_time, remote commit ts)`. The applied txn keeps the
  remote timestamp.
- Local commit: if `clock >= xact_time` then `clock++` (1 microsecond) and the
  commit gets `clock`; else the commit keeps wall time.
- `handle_commit` sets `remoteTransactionStopTimestamp = commit_time` before
  `CommitTransactionCommand` (`src/spock_apply.c:~1056-1063`).
- `conflict_resolve_by_timestamp`, `src/spock_conflict.c:99-200`: equal
  timestamps from different origins go to the tiebreaker of **this applying
  node vs the remote origin** (L2); equal tiebreakers -> apply remote + WARNING.

## Mechanism

1. n1's clock steps forward by X (X larger than replication latency).
2. n1 commits T at W+X. n2 and n3 apply T; their instance clocks become W+X.
3. Until their wall clocks reach W+X, every local commit on n2 is
   `W+X + (number of local commits on n2 since)` microseconds, and the same on
   n3. The first local commit on n2 and the first on n3 are both W+X+1 µs.
4. If both update the same row, the conflict on every node has equal
   timestamps from different origins -> tiebreak path -> L2 divergence with
   three writers.

The window lasts about X of wall time. Further commits from n1 (still ahead)
keep pulling the others up, so ties keep happening as long as n1 stays ahead.
After a restart the clock is zero again (L3) and the node returns to wall
time.

A second effect, expected by the docs but worth knowing during triage: while
the window is open, which write wins depends on how many local commits each
node has made since the last remote apply, not on real time.

## Property

`Sometimes`: a node stamps a **local** commit with a timestamp ahead of its
own wall clock, because the logical clock was pulled forward by a remote
commit from a node whose clock is ahead. Message: "local commit stamped ahead
of local wall clock by the logical clock". This is the precondition for
cross-node ties; if it never happens, the tie path that L2 needs is not being
explored no matter how long the run is.

- Workload-side check (no SUT build change, the patch is in core): right
  after a local write transaction commits on node N, run on the same node
  `SELECT pg_xact_commit_timestamp('<xid>'::xid) > clock_timestamp()` (xid
  from `txid_current()` inside the transaction). True means the bump fired.
  Report the gap size in details.
- Second `Sometimes`, also workload-side: "two nodes committed local writes
  with identical commit timestamps", found by comparing
  `pg_xact_commit_timestamp` of ledger rows across origins after quiescence.

Relationship to other properties: the equal-timestamp conflict assertion
(`Sometimes(cmp == 0 && local_origin != remote_origin, ...)` in
`conflict_resolve_by_timestamp`) and the safety check that all nodes agree are
already part of `contested-rows-converge-after-quiesce` (focus 1). This
property does not repeat them. It adds the mechanism that makes that
`Sometimes` reachable with ordinary clock steps, and a cheap way to see
whether the run is reaching it.

## Fault requirements

- Clock jitter with forward steps on single nodes (required). If the tenant
  cannot step clocks, this property and L2 cannot be reached except with the
  `SPOCK_RANDOM_DELAYS` build plus luck.
- Concurrent updates of the same keys from at least two nodes during the
  window; three writers to reach the L2 divergence case.

## Confidence

High on the mechanism (patch read; simple arithmetic). Medium on reachability
in Antithesis: depends on the size and frequency of clock steps the platform
injects, and on whether container clocks are per node.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (wildcard W6); see `evaluation/synthesis.md`.

Current catalog line: Priority: P2 · Topology: v1 · Faults: clock step (global backward, or per-node forward via a custom fault)

- Evaluation note (2026-10-13): needs only small global skips. Optional core markers in a test-only PG patch at the patch 025 hook would let coverage guidance steer toward the bump branch.

## Open questions

- Is the applying-node tiebreak intended (L2)? Decides how much these ties matter. `(needs human input)` — tracked in `luw-tiebreak-against-third-origin-row-reached`.

## Investigation results that change this property

**Fault model changes; invariant and assertion type do not.** Antithesis
clock skips move every node together, so the "one node steps forward" route
needs a custom fault. But a global **backward** skip opens the same window on
every node at once, using built-in faults:

1. All nodes at wall W, logical clocks near W. Global skip back by D.
2. Every node's logical clock is now ahead of its wall clock, so every local
   commit is stamped `clock + 1 us` until wall time passes the clock.
3. n1 commits (ts c). n2 and n3 apply it; both clocks become c (if that is
   their max). Their next local commits are both `c + 1 us`: a tie.

So the property's `Sometimes("local commit stamped ahead of local wall clock
by the logical clock")` is reached by any backward skip; the forward-step
mechanism described above remains valid for per-node offsets. The title
"step forward" is narrower than the mechanism; prose should say "clock step
(global backward or per-node forward)".

Cassert caveat: in the same window every applied commit has a remote ts above
the subscriber's wall clock, which trips the `handle_commit` progress Assert
(`src/spock_apply.c:1173-1174`) and crash-loops the node. Clock-fault runs need
the SPOC-688 fix (branch `task/SPOC-688/apply-clock-skew-fix`, commit 4e0988de
removes that Assert) or a non-cassert build.

### Investigation Log

#### Does Antithesis step one container's clock or all at once?

- Examined: `snouty docs show /docs/product/writing_tests/controlling_faults/fault_types/`.
- Found: "Clock skips affect every node simultaneously because Antithesis
  simulates a shared wall clock, called virtual time." Skips go forward or
  backward, temporary or permanent, and stack.
- Conclusion: resolved: all at once. A forward global skip does nothing for
  this property; a backward global skip reaches it (mechanism above).

#### Can the harness fake per-node clocks?

- Examined: Spock GUCs (`apply_delay`, `spock.output_delay`), patch 025,
  Antithesis docs on custom faults and on `/etc/ld.so.preload`.
- Found: no Spock or core setting shifts commit timestamps. Antithesis supports
  custom faults run inside a chosen container; a time-offset preload library
  (for example libfaketime with an offset file the fault rewrites) is the
  usual route. Antithesis injects its own library through
  `/etc/ld.so.preload`, so a second preload via `LD_PRELOAD` on the postgres
  process should coexist, but this was not run.
- Conclusion: resolved for planning: not needed, because global backward
  skips reach the state. A per-node offset fault is optional extra coverage.

#### Is the `+1 us` bump meant to give unique timestamps across nodes?

- Examined: patch 025 comments (all PG versions), `src/spock_conflict.c:131-200`.
- Found: the patch only claims "the commit timestamp is monotonically
  increasing in commit-LSN order", i.e. per node. Equal timestamps across
  nodes are expected by design and go to the tiebreaker.
- Conclusion: resolved. Ties are expected; whether the tie rule is right is the
  L2 question above.
