# local-overwrite-gets-later-commit-ts — A local overwrite commits after the version it replaced, and wins everywhere

## Synthesis note

Merged from three files that target lead L3 (patch 025 commit clock is reset
to 0 at postmaster start, "This is not postmaster restart safe"):

- `local-overwrite-gets-later-commit-ts` (F7) and
  `local-commit-ts-above-overwritten-version` (F3) are the same per-write check:
  read `pg_xact_commit_timestamp(xmin)` with `FOR UPDATE`, update, compare the
  new commit ts after COMMIT. Identical invariant, identical assertion type.
- `local-overwrite-after-remote-read-wins-everywhere` (F1) is the cross-node
  outcome of the same mechanism: every node ends holding X's causally later
  write.

The merged property keeps two `Always` messages with distinct names: the
per-write check ("local overwrite commit ts exceeds the version it replaced"),
which fails on the node where the clock went back and points straight at the
clock, and the outcome check ("causal overwrite holds on every node after
quiesce") on a reserved key range. F1's `Sometimes(X restarted between read and
write while its clock was behind)` is kept as the reachability companion; F3's
SUT-side `Sometimes("node restarted with wall clock behind newest applied
remote commit ts")` is the same idea from the SUT side. All three chose
`Always`; no conflict.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (wildcard W2/W6, implementability CW10/CW4); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 · Faults: clock skew + node kill

- Evaluation note (2026-10-13): the per-overwrite message is split into "... within N s after X restarted following a backward clock skip" (explained by L3) and "... otherwise" (unexplained). "Restart X, then overwrite a row X took from a peer" is scripted with the crash helper. Core patch 025 markers (local-bump branch, first call after startup) are an option in a test-only PG patch.

## Gap-fill extensions (2026-10-13)

From the gap-fill step; see `discovery/gap-c-provider-dml.md` and `evaluation/synthesis.md`.

- If the workload uses two-phase writers (`PREPARE TRANSACTION` /
  `COMMIT PREPARED`), take their commit ts from a peer (or from the origin
  after a restart), not from the origin's live `pg_xact_commit_timestamp`,
  which is the unbumped value for prepared transactions (patched PG18
  `twophase.c:2310-2358`). See `prepared-commit-ts-matches-sent-ts`.

## Open questions

- Is the restart gap in the commit clock an accepted limit, and is a maximum clock skew documented? `(needs human input)`
- What clock-skip sizes does Antithesis use? The L3 route needs a backward skip larger than a restart plus crash recovery plus one write; a skip of tens of milliseconds cannot reach it. `(partial: Antithesis docs show only a 65 ms example; ask the Antithesis contact; fallback is a libfaketime per-node offset custom fault)`

Resolved (see log): no restore of the logical clock exists or is in progress on
any branch; Antithesis clock skips are global, but a global **backward** skip
plus a restart of node X reaches L3, so the property can fail in Antithesis
without per-node clocks.

Fault requirement correction: "clock skew between nodes" is not required.
Required: a backward clock skip (global is fine) and a restart of X that
finishes before wall time catches up, with X holding a version committed
before the skip. Under cassert, the backward skip also trips the
`handle_commit` progress Assert on every node; use a tree with the SPOC-688
fix (branch `task/SPOC-688/apply-clock-skew-fix`, commit 4e0988de) or a
non-cassert build, otherwise the crash loop hides this property.

## Source: `local-overwrite-gets-later-commit-ts` (F7 Distributed)

### What the property says

When a client on node X reads a row version (locally written or applied from
a peer) and then overwrites it in a transaction on X, the commit timestamp of
the overwrite is strictly greater than the commit timestamp of the version it
replaced. This is the causal guarantee that the commit-clock patch exists to
give: a write that has seen another write must win against it under LUW on
every node.

### Claim

The core patch `patches/18/pg18-025-logical_commit_clock.diff` adds
`EnsureMonotonicTransactionStopTimestamp`, run under the WAL insert spinlock:

- apply commits raise `XLogCtl->lastTransactionStopTimestamp` to at least the
  remote commit ts (`remoteTransactionStopTimestamp`, set by `handle_commit`,
  `src/spock_apply.c:1056-1063`);
- local commits whose `xact_time <= clock` are bumped to `clock + 1 us`.

The patch says it ensures "the commit timestamp is monotonically increasing in
commit-LSN order" and comments that it bumps local commits past remote ones
seen "in the future". Its own TODO: "This is not postmaster restart safe. If
the local system clock is further behind other nodes than it takes for the
postmaster to restart ... local transactions will not be bumped into the
future correctly."

### Failure scenario (L3)

1. n2's clock is ahead of n1's by D seconds.
2. n2 updates row k (ts = t2). n1 applies it; n1's logical clock >= t2.
3. n1 restarts (crash or clean). `XLogCtl` is re-initialised, so the logical
   clock is 0 (sut-analysis assumption 4).
4. Within D seconds, a client on n1 reads k (sees n2's version, ts t2) and
   updates it. n1's wall time < t2, clock is 0, so the commit ts is wall time
   < t2.
5. n2 and n3 receive n1's update with ts < t2 and keep the old version.
   n1 keeps its own write. Permanent divergence, no exception row, and the
   causally later write loses.

Also: a backward clock step on a node that then restarts gives the same
result even without skew between nodes.

### Workload check

On node X, one session:

```sql
BEGIN;
SELECT pg_xact_commit_timestamp(xmin) AS seen_ts, payload FROM contested WHERE k = $1 FOR UPDATE;
UPDATE contested SET payload = $2 WHERE k = $1;
SELECT txid_current();
COMMIT;
SELECT pg_xact_commit_timestamp($xid);
```

`Always(new_ts > seen_ts, "local overwrite commit ts exceeds the version it replaced")`.
Skip when `seen_ts` is NULL (frozen xmin or truncated commit-ts). The
`FOR UPDATE` keeps an apply worker from replacing the row between read and
write.

This catches L3 at the moment it happens, on the node where it happens,
instead of waiting for a later convergence check.

### Suggested SUT-side instrumentation (missing; no Antithesis assertions exist)

The clock hook is in PostgreSQL core (patch 025), which the topology plan
does not instrument at first. An `ALWAYS` inside the hook would be true by
construction, so it adds nothing. The useful marker is at the start of a
postmaster lifetime: `SOMETIMES(first local commit after startup has xact_time
below the largest commit ts already in pg_commit_ts, "commit clock restarted
behind applied history")`. It tells Antithesis the L3 window was reached even
when no client happened to overwrite a row inside it. Spock itself cannot see
the logical clock, so the workload check above stays the main oracle.

### Scope

- Contested table only; no delta columns (patch 030 forces the local winner's
  ts onto the delta subtransaction).
- `track_commit_timestamp=on` (required anyway).

### Fault requirements

- Node termination or restart: **required**.
- Clock skew between nodes or a backward step: **required**.
Without both, this property is expected to pass and gives no signal.

### Original open-question notes (detail for the combined list above)
- Is the restart gap an accepted limit (the TODO), and is there a documented
  maximum clock skew? If accepted, this property becomes a documented-limit
  marker (report, do not fail) and should be scoped to timelines with no
  restart. (needs human input; see investigation log in
  `luw-final-version-has-max-commit-ts`.)
- Does Antithesis clock jitter give different containers different clocks? If
  not, the property cannot fire and should be deprioritised for this tenant.

## Source: `local-commit-ts-above-overwritten-version` (F3 Failure Recovery)

### What the property says

On any node X, a local transaction that updates a row gets a commit timestamp
strictly greater than the commit timestamp of the row version it replaced,
including the first local transactions after X restarts (clean restart,
crash restart, or promotion).

Workload check, all in one session on X:

```sql
BEGIN;
SELECT pg_xact_commit_timestamp(xmin) AS old_ts FROM t WHERE k = $1 FOR UPDATE;
UPDATE t SET payload = $2 WHERE k = $1 RETURNING xmin;   -- remember new xid
COMMIT;
SELECT pg_xact_commit_timestamp($new_xid) AS new_ts;
```

`Always(new_ts > old_ts)`. Focus on rows whose current version arrived from
another node (`pg_xact_commit_timestamp_origin(xmin)` origin != 0).

This is a direct, per-write form of the clock guarantee. It needs no
quiescence and no cross-node comparison, so a failure points at the commit
clock and nothing else. The convergence effect is covered by
`local-overwrite-gets-later-commit-ts`.

### Why (lead L3, commit clock reset)

- Patch `patches/18/pg18-025-logical_commit_clock.diff` adds
  `EnsureMonotonicTransactionStopTimestamp()` (diff lines ~97-152) under the
  WAL insert lock. Apply commits raise `XLogCtl->lastTransactionStopTimestamp`
  to max(clock, own xact_time, `remoteTransactionStopTimestamp`); local
  commits are bumped to `clock + 1 us` when the wall clock is not ahead.
- `handle_commit` sets `remoteTransactionStopTimestamp = commit_time` just
  before `CommitTransactionCommand()` and clears it after
  (`src/spock_apply.c:~1053-1060`).
- The patch's own TODO (diff line 133): "This is not postmaster restart safe.
  If the local system clock is further behind other nodes than it takes for
  the postmaster to restart ... local transactions will not be bumped into the
  future correctly." The clock lives in `XLogCtl`, zeroed at shared memory
  init; nothing rebuilds it from WAL, `pg_commit_ts` or `spock.progress`
  (sut-analysis assumption 4).
- Result: X behind in wall time by more than its restart time; X applied
  remote version V (ts 100) before the restart; after restart the clock is 0,
  a local update of the same row gets X's wall ts (say 91). X keeps its
  update (local write, no conflict on X); every peer keeps V (newer ts) when
  X's update arrives. Permanent divergence with no exception row.

Not expected divergence under the workload boundaries (§12): "Clock skew
changing which write wins is expected; different winners on different nodes
is not." The broken step here is on one node, before any conflict
resolution.

### Assertions

- **Workload-side:** `Always("local update commit ts is above the overwritten
  version's commit ts")` per checked update. Always: the clock must be
  monotonic for every write.
- **SUT-side (missing, no existing assertions; needs the core patch to be
  instrumented, which deployment-topology defers):** in
  `EnsureMonotonicTransactionStopTimestamp`, local branch,
  `Sometimes(logical_clock == 0 && first local commit since startup)` as an
  anchor that the reset state is reached, and
  `AlwaysOrUnreachable(local xact_time > newest commit ts in pg_commit_ts)`
  would be the exact SUT-side check, but it is too costly for every commit.
- **Spock-side alternative (missing):** at apply-worker start, compare
  `GetCurrentTimestamp()` with the recovered `remote_commit_ts` from
  `recover_progress_timestamps_from_commit_ts` and
  `Sometimes("node restarted with wall clock behind newest applied remote commit ts")`.
  It marks the dangerous state without touching core.

### Fault requirements

- **Clock skew** (X's clock behind the writer of V by more than X's restart
  time) — required. Containers share the host kernel clock unless Antithesis
  virtualises clocks per container (deployment-topology open question).
- **Node restart** of X (termination or clean restart via test command).
- Writes on two nodes to the same rows: remote write first, local update on X
  after the restart.

### Original open-question notes (detail for the combined list above)
- **Is there a plan to restore the clock at startup or promotion?** If the
  team accepts the TODO as a known limit with a documented maximum skew,
  scope the workload's clock faults below the restart time and keep this
  property as a guard. Otherwise the property is expected to fail under skew.
  (sut-analysis Open Question 5.)
- **Does Antithesis give per-container clocks?** If not, the property is still
  checked but cannot fail; record it as unexercised rather than passing.
- **Promotion path:** with no standby in v1 the promotion half is out of
  scope.

## Source: `local-overwrite-after-remote-read-wins-everywhere` (F1 Data Integrity)

### What the property says

If a client on node X reads a row version that X received from another node,
and then (after that read) updates the same row on X, and no other node writes
that row afterwards, then after quiescence every node holds X's update. In
other words, LUW respects causality: a write made after seeing a version
never loses to that version.

### Claimed guarantee

The pgEdge commit-clock patch `pgNN-025-logical_commit_clock.diff` claims to
"ensure that the commit timestamp is monotonically increasing in commit-LSN
order", and for apply commits raises the clock to at least the applied
remote ts (`remoteTransactionStopTimestamp`, set in `handle_commit`,
`src/spock_apply.c:~1050-1056`). So the next local commit on X gets a ts above
the remote version's ts and wins LUW everywhere. sut-analysis S5.

The patch also admits: **"This is not postmaster restart safe"**.
`lastTransactionStopTimestamp` lives in `XLogCtl`, which is zeroed at every
postmaster start, crash restart and promotion (sut-analysis Assumption 4).

### Failure scenario (L3)

1. Node X's wall clock is behind peer P's by d.
2. P commits T1 on row r (ts 100); X applies it (clock raised to >= 100).
3. X restarts (crash or clean). Clock state is gone.
4. Client on X reads r (sees T1), updates r; X stamps wall time 100 - d (e.g.
   91).
5. X keeps its own version (local row is its own). P and the third node
   compare 91 < 100 and keep T1. **Permanent divergence, no exception row, no
   resolutions row** (origin-differs is not recorded, `src/spock_conflict.c:400-445`).

Without a restart, the patch should prevent this; that half is a regression
guard for the patch itself.

### Oracle design

- Use the contested table but a separate key range reserved for causal
  chains, so the general contested workload does not overwrite them.
- Sequence per chain: writer on P updates row r; workload waits until a reader
  on X sees P's version (poll `writer`/`wseq`); then writer on X updates r with
  a new wseq. No other node writes r in that chain.
- After barriers: `Always(every node holds X's version of r)`.
- Record for triage whether X restarted between steps 2 and 4 and the clock
  offsets at that time.

`Always`: causality must hold every time.

### Fault requirements

- **Clock skew with node X behind** (required; containers otherwise share one
  clock).
- **Node restart of X** between applying P's version and X's local update
  (required for L3).
- Without both, the property passes trivially; flag with
  `Sometimes(restarted between read and write while behind, "causal overwrite
  after restart with lagging clock")` in the workload so the run shows whether
  the state was reached.

### SUT-side instrumentation (missing)

- In the commit path (patched core, or in Spock's `handle_commit` for applied
  transactions and an `XACT_EVENT_PRE_COMMIT` callback for local ones):
  `Always("local commit ts on this node is above the max applied remote ts
  since startup")` would localise L3 without needing the final comparison.
  This is SUT-side only and would need a new shared-memory high-water mark,
  so it is a larger change.

### Original open-question notes (detail for the combined list above)
- Does the team accept L3 as a known limit (sut-analysis Open Question 5)?
  If the answer is "max clock skew must be below X ms and restarts are rare",
  scope clock faults to that bound; if a maximum skew is not documented, the
  property stays strict.
- Is there any planned restore of the logical clock at startup (from WAL,
  `pg_commit_ts` or `spock.progress`)? A fix would make this property a
  regression test.

### Investigation Log

#### Is the restart gap an accepted limit, with a documented maximum skew?

- Examined: patch 025 for PG15-PG19 (`git log --all -p -- 'patches/*/*logical_commit_clock*'`),
  `docs/` for clock/skew/NTP/chrony, `docs/internals-doc/specs/spock-progress-no-checkpoint-hook-design.md`.
- Found: the TODO is unchanged in every version including PG19. No user doc
  states a maximum skew or a clock-sync requirement; the internals spec only
  discusses publisher skew for progress recovery.
- Conclusion: `(needs human input)`.

#### Is a restore of the logical clock at startup or promotion planned?

- Examined: all local and remote branches (`git log --all --grep` for
  clock/lamport/commit_ts/restart safe), `src/` and `include/` for
  `XLogSetLastTransactionStopTimestamp`/`XLogGetLastTransactionStopTimestamp`,
  `src/spock_progress_recovery.c`.
- Found: no branch touches the clock restore. Spock never calls the setter.
  At restart Spock already scans `pg_commit_ts` backward
  (`recover_progress_timestamps_from_commit_ts`, `src/spock_progress_recovery.c:295`)
  to rebuild `remote_commit_ts` per origin, which would be a natural place to
  seed the clock, but it does not. The XLogCtl field is zeroed at shared
  memory init and nothing rebuilds it from WAL.
- Conclusion: resolved: nothing exists or is in progress. Whether one is
  wanted folds into the accepted-limit question above.

#### Does Antithesis give containers different clocks?

- Examined: `snouty docs show /docs/product/writing_tests/controlling_faults/fault_types/`.
- Found: "Clock skips affect every node simultaneously" (shared virtual
  time); skips can go backward. Reasoning with patch 025: n2 commits version V
  at ts 100; n1 applies it. Global skip back to 91. n1 restarts (clock = 0),
  a client reads V and updates it: commit ts is wall time (~91+) < 100. n2 and
  n3 were not restarted; their clocks stay >= 100 and they keep V when n1's
  update arrives.
- Conclusion: resolved. Per-container clocks are not needed; a backward
  global skip plus a restart is enough. The per-write `Always` fires on n1 at
  the moment of the bad commit.
