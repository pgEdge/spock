# prepared-commit-ts-matches-sent-ts

Surfaced by evaluation gap (c), item 5 (wildcard W9). Code checked at Spock
69d9228f and the patched PG18 tree at `~/dev/pgedge/postgresql`
(REL_18_STABLE with the pgEdge patches applied).

## What the property says

For a transaction committed on its origin with `PREPARE TRANSACTION` /
`COMMIT PREPARED`, the commit timestamp the origin stores for it in
`pg_commit_ts` equals the commit timestamp its peers receive (and store for
the applied copy). Last-update-wins compares these timestamps; if the origin
and its peers hold different values for the same transaction, they can pick
different winners for the same row.

## Mechanism (confirmed by code reading, not run)

1. Patch 025 (`patches/18/pg18-025-logical_commit_clock.diff`) installs
   `EnsureMonotonicTransactionStopTimestamp` as `XLogReserveInsertHook`
   inside `XactLogCommitRecord()`. For a local transaction
   (`remoteTransactionStopTimestamp == 0`), when the shared logical clock
   is `>= xlrec->xact_time`, it bumps `xlrec->xact_time` to `clock + 1` and
   also writes the bumped value to the backend global `xactStopTimestamp`.
   The CRC is recomputed, so the WAL commit record carries the bumped time.
2. Normal commits: `RecordTransactionCommit()` (patched `xact.c`, around
   line 1458-1486) passes `GetCurrentTransactionStopTimestamp()` to
   `XactLogCommitRecord` and afterwards calls it **again** for
   `TransactionTreeSetCommitTsData`. The second call reads the bumped
   `xactStopTimestamp`, so WAL and `pg_commit_ts` agree.
3. Prepared commits: `RecordTransactionCommitPrepared()`
   (`src/backend/access/transam/twophase.c:2297-2358` in the patched tree)
   takes `TimestampTz committs = GetCurrentTimestamp()` into a local
   variable, passes it to `XactLogCommitRecord`, and then records
   `replorigin_session_origin_timestamp = committs` (no replication origin
   in a client session) in `TransactionTreeSetCommitTsData`. The hook's bump
   changes only the WAL copy and `xactStopTimestamp`; the local `committs`
   is unchanged. So `pg_commit_ts` on the origin keeps the **unbumped**
   time, while the WAL record holds the **bumped** time.
4. Spock has no two-phase callbacks (`src/spock_output_plugin.c:133-140`;
   `include/spock_output_plugin.h:27` says so). A prepared transaction is
   decoded at `COMMIT PREPARED` like a normal commit, and the 'C' message
   carries `SpockTxnCommitTime(txn)` = the WAL `xact_time` = bumped value.
5. On a peer, `handle_commit` sets `replorigin_session_origin_timestamp =
   commit_time` (`src/spock_apply.c:685`) and the stock commit path stores
   that in the peer's `pg_commit_ts`. Peers hold the bumped time.
6. Conflict resolution reads the local row's commit ts with
   `TransactionIdGetCommitTsData(xmin)` (`src/spock_conflict.c:255,269`).
   The origin therefore compares later remote writes against the smaller
   value; its peers compare against the larger one.

When does the bump happen? Whenever the shared logical clock is already at
or past `committs`. `committs` is read before `START_CRIT_SECTION`; any other
commit (local or apply) that inserts its commit record first with a later or
equal time sets the clock past it. So plain concurrency produces bumps of a
few microseconds. A backward clock jump produces bumps as large as the jump,
because the clock keeps the pre-jump time.

After a crash of the origin, redo rebuilds `pg_commit_ts` from the WAL
record (`xact_redo_commit` uses the parsed `xact_time`), so the origin then
holds the bumped value too. The mismatch is visible only between the commit
and the next crash recovery, which means the property is checked on live
nodes; a check after a restart can pass even though the earlier conflict
decisions used the wrong value.

## Failure scenario (divergence)

Row r. Origin A commits a prepared transaction that writes r: `pg_commit_ts`
on A = t, WAL and peers = t' > t. Node B writes r with commit ts tb where
t < tb < t'.
- On A: B's write arrives, local ts t < tb, remote wins: r = B's version.
- On C, if A's version arrived first: local ts t' > tb, local wins: r = A's
  version. B itself (holding A's version with t') also keeps A's version.
Result: A differs from B and C, with no exception row (both outcomes are
ordinary LUW decisions, possibly logged in `spock.resolutions` with
inconsistent timestamps). The window is t' - t: microseconds under plain
concurrency, seconds after a backward clock jump.

## Workload and oracle design

- Option: `max_prepared_transactions > 0` on all nodes; a share of writers
  use `BEGIN; ...; PREPARE TRANSACTION 'g'; COMMIT PREPARED 'g'`, sometimes
  with a short delay between PREPARE and COMMIT PREPARED (wider bump window,
  more concurrent commits in between).
- The workload must always finish what it prepares (COMMIT or ROLLBACK
  PREPARED), retrying after a node restart. An orphaned prepared transaction
  holds row locks forever and blocks the apply worker on that row; that is
  standard PostgreSQL behaviour, not a Spock bug, and would show up as a
  liveness failure elsewhere.
- Record each prepared transaction's xid (`txid_current()` before PREPARE)
  and a marker row it writes.
- Check (direct, cheap): after a barrier, on the origin read
  `pg_xact_commit_timestamp(xid)`; on each peer read
  `pg_xact_commit_timestamp(xmin)` of the marker row (a peer stores the
  remote commit ts for the applying transaction). Skip a pair if the origin
  restarted between the commit and the check (redo rewrites the value) or if
  the peer row was since overwritten. `Always("prepared transaction's
  commit ts on its origin equals the commit ts its peers applied")`.
- Companion `Sometimes("prepared transaction committed while the logical
  clock was ahead of its commit time")` — workload-side: the peer value is
  greater than the origin value (would show the bump path ran), or SUT-side
  in the hook if PG core gets instrumented (deployment plan leaves core
  uninstrumented; workload-side is enough).
- Contested-row variant: let prepared writers and normal writers on other
  nodes update the same contested keys; the existing convergence and
  `luw-final-version-has-max-commit-ts` checks then show the consequence.
  Those oracles read `pg_xact_commit_timestamp` on the origin: for prepared
  writers that value is the wrong one, so the oracle must use the peer value
  (or the value after an origin restart) as the truth.

## Fault requirements

- None needed for the direct check: concurrent commits make small bumps.
- Global backward clock jump makes the bump window large enough for the
  contested-row divergence to happen often. Thread pausing between PREPARE
  and COMMIT PREPARED widens it.
- Node kill of the origin turns the value consistent (redo), which hides
  the mismatch; the check must note restarts.

## Instrumentation

All missing. Workload-side checks are enough. Optional PG-core assertion in
`RecordTransactionCommitPrepared` (`committs == xlrec time`) if core is ever
instrumented.

## Second-pass refinements (2026-10-13)

From the second evaluation pass on the gap-fill properties; see `evaluation/synthesis.md` "Second pass (gap-fill)".

- Placement: the direct check fires without faults on the first prepared
  transaction that commits while the logical clock is ahead (plain
  concurrent commits make microsecond bumps). Expected to fire
  deterministically — confirm with TAP first, then gate the direct message
  out of the main template. Antithesis keeps the consequence (contested rows
  diverging under backward clock skips and thread pauses between PREPARE and
  COMMIT PREPARED), scored by `contested-rows-converge-after-quiesce` with a
  2PC attribution message.
- Setup: `max_prepared_transactions > 0` on every node in the runs that use
  two-phase writers, and the writer always finishes what it prepares
  (COMMIT or ROLLBACK PREPARED, retried after restarts).

## Open questions

- Is two-phase commit a supported client feature for Spock clusters? Docs
  say nothing either way (`grep -ri prepared docs/` finds nothing). If
  unsupported, this is a documentation finding; if supported, it is a
  patch-025 bug (fix: re-read `xactStopTimestamp` or have the hook update
  the caller's `committs`). Decides priority. `(needs human input)`
- Does the same gap exist in patch 025 for PG15-17 and PG19? Only PG18 was
  read. Matters for the mixed-version topologies.
- Are there other callers of `XactLogCommitRecord` that keep their own copy
  of the time? Only `RecordTransactionCommit` and
  `RecordTransactionCommitPrepared` call it in PG18 (checked by grep); the
  abort path does not use the hook.

### Investigation Log

#### Does patch 025's logical clock apply in RecordTransactionCommitPrepared?

- Examined: `patches/18/pg18-025-logical_commit_clock.diff`;
  patched `twophase.c:2297-2358`; patched `xact.c` `RecordTransactionCommit`
  and `XactLogCommitRecord`; `src/spock_output_plugin.c:133-140`;
  `include/spock_output_plugin.h:23-37`; `src/spock_apply.c:685`;
  `src/spock_conflict.c:240-270`.
- Found: the hook runs (it is installed inside `XactLogCommitRecord`, which
  the prepared path calls) and rewrites the WAL time, but the prepared path
  stores its own unbumped local `committs` in `pg_commit_ts`.
- Conclusion: mismatch confirmed by code reading; not run.

#### Does Spock decode and replicate prepared transactions?

- Examined: output plugin callbacks; the header comment in
  `include/spock_output_plugin.h`.
- Found: no `prepare_cb`/`commit_prepared_cb`; decoding sends the whole
  transaction at `COMMIT PREPARED`; `ROLLBACK PREPARED` sends nothing. Spock
  slots are created without two-phase.
- Conclusion: replicated as ordinary commits; the only issue found is the
  timestamp mismatch.

#### Do the docs say whether two-phase commit is supported?

- Examined: `grep -ri prepared docs/`; `docs/limitations.md`.
- Found: nothing either way.
- Conclusion: `(needs human input)`; the team decides between a
  documentation finding and a patch-025 bug.
