# luw-final-version-has-max-commit-ts — Contested rows end at the max-commit-ts version on every node

## Synthesis note

Merged from `luw-final-value-is-newest-commit` (F1) and
`luw-final-version-has-max-commit-ts` (F7). Both state the same claim
(`docs/conflicts.md:60-64`, S1): after quiescence each contested row holds the
version with the largest origin commit timestamp. Both use the same oracle
(writer records its xid, reads `pg_xact_commit_timestamp(xid)` on the origin
after COMMIT).

Difference resolved: F1 also scored ties ("lower tiebreaker wins"); F7 skipped
keys whose top two timestamps are equal and left ties to
`luw-tiebreak-against-third-origin-row-reached` and
`contested-rows-converge-after-quiesce`. The merged property follows F7 and
scores only keys with a unique maximum, because the tie rule's intended
meaning is an open question (docs say "lower tiebreaker of the two writers",
code compares applying node vs sender, L2). Tied keys are reported in details
but not asserted here. F1's suggested `Sometimes` markers for both LUW
directions are kept as SUT-side companions. Both focuses chose `Always`; no
conflict on assertion type.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (wildcard W2, implementability CW10/CW4); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 · Faults: clock skew + node kill, partition

- Evaluation note (2026-10-13): split as in `contested-rows-converge-after-quiesce` (explained by L3 vs unexplained). The L3 route needs a backward skip larger than restart plus recovery plus one write; if Antithesis skips are small, a per-node offset custom fault (libfaketime) is needed. The restart is scripted with the crash helper.

## Gap-fill extensions (2026-10-13)

From the gap-fill step; see `discovery/gap-c-provider-dml.md` and `evaluation/synthesis.md`.

- If the workload uses two-phase writers (`PREPARE TRANSACTION` /
  `COMMIT PREPARED`), take their commit ts from a peer (or from the origin
  after a restart), not from the origin's live `pg_xact_commit_timestamp`,
  which is the unbumped value for prepared transactions (patched PG18
  `twophase.c:2310-2358`). See `prepared-commit-ts-matches-sent-ts`.

## Open questions

- Is the restart-unsafe commit clock (patch 025 TODO, unchanged through PG19, no fix on any branch) an accepted limit? `(needs human input)`
- Which tie rule is intended: lower tiebreaker of the two writers (docs, pre-64ea462d code) or applying node vs sender (current code)? Decides whether tied keys can be scored. `(needs human input)`
- What clock-skip sizes does Antithesis use? The L3 route needs a backward skip larger than a restart plus crash recovery plus one write; a skip of tens of milliseconds cannot reach it. `(partial: Antithesis docs show only a 65 ms example; ask the Antithesis contact; fallback is a libfaketime per-node offset custom fault)`

Resolved: the origin's `pg_xact_commit_timestamp(xid)` is the adjusted
timestamp and equals the one peers receive and store (see log), so the
oracle as designed is valid. L3 is reachable with Antithesis' built-in global
backward clock skip plus a node restart; no per-node clock is needed. Under
cassert, clock-fault runs need the SPOC-688 fix (removes the `handle_commit`
progress Assert) or a non-cassert build.

## Source: `luw-final-version-has-max-commit-ts` (F7 Distributed)

### What the property says

For contested rows (seeded once, replicated everywhere, then only UPDATEd from
several nodes; no deletes), after quiesce every node holds the version written
by the transaction with the **largest commit timestamp**, whenever that
largest timestamp is unique among the writes to that row.

This is stronger than "all nodes agree": nodes could agree on the wrong
version (for example after a restart-related clock regression, or a dropped
apply). It is the literal claim in `docs/conflicts.md:60-64`: "the version of
data with newest commit timestamp is kept" (S1).

### How the workload knows each write's commit timestamp

- Each update writes a payload `(writer_node, writer_seq)`.
- In the writing session: `BEGIN; UPDATE ...; SELECT txid_current(); COMMIT;`
  then `SELECT pg_xact_commit_timestamp(<xid>)` on the same node. This is the
  timestamp recorded in `pg_commit_ts` after the commit-clock patch adjusted it
  (`EnsureMonotonicTransactionStopTimestamp` rewrites `xact_time` and
  `xactStopTimestamp`), so it is the value peers compare against.
- On peers, the applied version carries the origin's timestamp
  (`replorigin_session_origin_timestamp`, used by `RecordTransactionCommit` for
  commit-ts), so `pg_xact_commit_timestamp(xmin)` of the row on each node
  should equal the winner's recorded timestamp. That gives a second check.

Because the oracle uses recorded commit timestamps rather than wall clock,
clock skew that changes *which* write wins does not trigger it (that is
expected per sut-analysis section 12); only a node keeping a version that is
not the max does.

### Code paths

- `conflict_resolve_by_timestamp` (`src/spock_conflict.c:99-201`).
- Local tuple ts from `get_tuple_origin` (`:219-275`): frozen xmin or
  truncated commit-ts gives ts 0, so remote wins. That still picks the max.
- Commit-clock patch: local commits are bumped above every ts the node has
  applied (until restart, L3).
- `spock_handle_conflict_and_apply` (`src/spock_apply_heap.c:589-790`).

### Ways it can fail

- **L3 (restart + clock behind)**: node X applies T1 (ts 100), restarts,
  clock resets to 0, X updates the row with wall ts 91. X keeps its own write
  locally (a plain local UPDATE); peers keep T1 (100 > 91). Max ts is T1, but
  X holds the 91 version. Both this property and the convergence property
  fire; this one names the wrong node.
- **Dropped apply**: a transaction misclassified and discarded under
  TRANSDISCARD (L5) on one node leaves an older version there. Scope: exclude
  keys with `spock.exception_log` rows and report those under the
  classifier/exception properties instead.
- **Delta columns**: do not put delta-apply columns in this table (the forced
  update keeps the local ts via patch 030 and is not a plain LUW write).

### Scope (workload boundaries, sut-analysis section 12)

- Rows seeded on one node and barrier-confirmed on all nodes before contention
  (no `update_missing`).
- No DELETE, no INSERT of contested keys, one unique index (PK).
- Unique tiebreakers per node (`node_create(... info '{"tiebreaker":"N"}')`).
- Skip a key when the two highest commit timestamps are equal (ties belong to
  `luw-tiebreak-against-third-origin-row-reached` / the convergence property).
- Skip writes whose client did not get a COMMIT acknowledgment (unknown
  outcome); include them only if the row shows their payload.
- A write lost because its node was permanently removed is out of scope (not
  planned for n1-n3).

### Assertion

Workload, in the quiesced check after barriers for every ordered pair:
`Always(final_payload_on_node == payload_of_max_ts_write, "contested row holds max commit-ts version on every node")`,
one evaluation per (node, key). Always fits: the guarantee is claimed for
every resolved conflict.

### Fault requirements

- Node termination (restart) and clock skew together reach L3.
- Partitions/latency to vary arrival order.

### Original open-question notes (detail for the combined list above)
- Is the restart-unsafe commit clock (patch TODO) an accepted limit? If yes,
  scope this property to timelines with no restart of a node whose clock is
  behind; if no, L3 is a bug this property should catch. (needs human input;
  the patch's own TODO and the absence of any clock-sync requirement in docs
  are all that was found.)
- Does `pg_xact_commit_timestamp(xid)` on the origin always equal the
  timestamp the walsender sends? Expected yes because the hook rewrites
  `xlrec->xact_time` before the record is inserted and decoding reads the
  commit record. If not, the oracle needs the timestamp from a peer instead.

## Source: `luw-final-value-is-newest-commit` (F1 Data Integrity)

### What the property says

For each contested row (same workload as
`contested-rows-converge-after-quiesce`), the version every node holds after
quiescence is the committed version with the largest origin commit timestamp;
when the largest timestamp is shared by versions from different nodes, it is
the version from the node with the lower tiebreaker.

This is stronger than convergence: all nodes could agree on the wrong
version (for example the older one), which convergence alone would not catch.

### Claimed guarantee

- `docs/conflicts.md:60-64`: "the version of data with newest commit
  timestamp is kept".
- `docs/conflict_types.md:173-176`: on equal timestamps "the node with the
  lower tiebreaker value wins".
- sut-analysis S1.

### Mechanism

- The commit ts used for comparison is the one in `pg_commit_ts` of the
  origin's commit, carried to peers in BEGIN (`replorigin_session_origin_timestamp
  = commit_time`, `src/spock_apply.c:~684`) and stamped on applied rows. The
  logical-clock patch can raise a local commit's ts above wall time; the value
  in `pg_commit_ts` on the origin is the one that matters.
- `conflict_resolve_by_timestamp` (`src/spock_conflict.c:99-200`). For the
  equal-ts case the code compares the applying node's tiebreaker with the
  remote origin's (L2), which does not always implement "lower tiebreaker of
  the two writers wins" with 3+ nodes.
- Delta-apply columns must not be in this table (delta forces apply and
  changes the value; covered elsewhere).

### Oracle design

- For each writer transaction on node N: inside the transaction run `SELECT
  pg_current_xact_id()`; after a successful COMMIT, on the same node, run
  `SELECT pg_xact_commit_timestamp(:xid)` and record `(row id, writer N,
  wseq, commit_ts)`. If N crashes before the lookup, look it up after restart
  (`track_commit_timestamp` keeps it).
- Expected winner per row: max by (commit_ts, then lower tiebreaker of the
  writer). Tiebreakers are set by the harness in `spock.node.info` and known
  to the workload.
- Check after barriers: `Always(on every node, (writer, wseq) of each
  contested row equals the expected winner)`. On failure report both versions'
  commit ts and writers, and whether the clocks of the nodes involved were
  restarted (L3) or tied (L2).
- Unknown-outcome commits: resolve them on the origin node before the check
  (the version is committed if its xid has a commit ts); otherwise skip rows
  that had an unknown-outcome write.

`Always`: the claim holds per row with no exceptions in scope.

### Fault requirements

- Clock jitter / skew between nodes (makes "newest" differ from arrival order
  and produces ties).
- Node restart with a node behind in time (L3: the restarted node may stamp an
  older ts than a version it has already applied; the property then reports
  the true newest version, and the node's own row will lose on peers but win
  locally).
- Partitions/latency to reorder arrival.

### SUT-side instrumentation (missing)

- In `conflict_resolve_by_timestamp`, `Sometimes(resolution ==
  KeepLocal && cmp < 0, "LUW kept a newer local row over an older remote
  row")` and `Sometimes(cmp > 0, "LUW applied a newer remote row")`, to show
  both directions are exercised.

### Original open-question notes (detail for the combined list above)
- Is "lower tiebreaker of the two writers wins" the intended meaning of the
  docs, or "lower tiebreaker of the applying node vs sender"? These give
  different winners with 3+ nodes. The answer decides the expected-winner rule
  for ties; until then, rows whose winner was decided by a tie could be
  reported separately (sut-analysis Open Question 4).
- Is the commit ts in `pg_commit_ts` on the origin always equal to the ts
  carried to peers in BEGIN? The patch rewrites `xact_time` in the commit record
  before insert; if `pg_commit_ts` got the un-adjusted value, the oracle needs
  to read the ts some other way (e.g. `spock.xact_commit_timestamp_origin` on a
  peer). Worth a one-off check when building the workload.

### Investigation Log

_Entries carried over from `luw-final-version-has-max-commit-ts`:_

#### Is the restart-unsafe commit clock an accepted limit?

- Examined: `patches/18/pg18-025-logical_commit_clock.diff` (TODO comment),
  `docs/` for "clock", "skew", "NTP" (only internals spec mentions publisher
  clock skew, for progress recovery), `docs/FAQ.md` time-change note.
- Found: TODO says "This is not postmaster restart safe"; no user doc requires
  synchronized clocks or bounds skew.
- Not found: any statement that cross-node divergence after restart is
  accepted.
- Conclusion: needs human input.

#### Does the origin's `pg_xact_commit_timestamp(xid)` equal the ts sent to peers?

- Examined: PG18 source with pgEdge patches (`~/dev/pgedge/postgresql`,
  `xact.c` `RecordTransactionCommit` lines 1458-1486, `GetCurrentTransactionStopTimestamp`
  at 907), PG17 equivalent (`~/dev/pgedge8/postgresql`, lines 1447-1473),
  patch 025 hook, `decode.c:672-679`, `src/spock_apply.c:685,1056`.
- Found: `RecordTransactionCommit` calls `XactLogCommitRecord` first; inside
  `XLogInsert` the hook rewrites both `xlrec->xact_time` and the backend's
  `xactStopTimestamp`. Afterwards, for a session with no replication origin,
  `replorigin_session_origin_timestamp = GetCurrentTransactionStopTimestamp()`
  (returns the rewritten `xactStopTimestamp`) and that value goes to
  `TransactionTreeSetCommitTsData`. Decoding sends `parsed->xact_time` (the
  rewritten WAL field; `origin_timestamp` only for forwarded transactions).
  Redo (`xact.c:6198`) also uses the WAL field. On peers, `handle_begin`
  sets `replorigin_session_origin_timestamp = commit_time`, which is what
  their `pg_commit_ts` stores.
- Conclusion: resolved, yes. The workload can read the ts on the origin, or
  `pg_xact_commit_timestamp(xmin)` on any peer, and get the same value (except
  delta-apply columns, already out of scope).

#### Can Antithesis reach L3 without per-node clocks?

- Examined: Antithesis fault-type docs (clock skips are global, forward or
  backward); patch 025.
- Found: after a global backward skip of D, a node that restarts within D
  starts with logical clock 0 and stamps wall time, which is below versions it
  applied before the skip; nodes that did not restart keep their clock and
  keep the older-but-higher-ts version.
- Conclusion: resolved; built-in backward skip plus node restart is enough.

#### Which tie rule is intended?

- Examined: `git show 64ea462d`, `src/spock_conflict.c:131-200`, docs.
- Found: before 64ea462d the code compared writer vs writer (converges); the
  commit's stated reasons are covered by the same-origin shortcut it also
  added. Details in `contested-rows-converge-after-quiesce`.
- Conclusion: `(needs human input)`.

#### Is the restart-unsafe commit clock accepted? (follow-up)

- Examined additionally: PG15-PG19 patch history (`git log --all -p`),
  all branches, `src/` for `XLogSetLastTransactionStopTimestamp`.
- Found: TODO unchanged in every version; Spock never seeds the clock;
  no fix branch.
- Conclusion: still `(needs human input)`.
