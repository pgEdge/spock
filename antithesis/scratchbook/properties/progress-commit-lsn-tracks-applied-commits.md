# progress-commit-lsn-tracks-applied-commits

## What the property says

Once subscriber S has applied a transaction T from provider P (the workload
sees T's row on S), `spock.progress.remote_commit_lsn` on S for the pair
(S, P) is at or beyond T's commit LSN on P. In short: the per-pair progress
that `spock.progress` and `spock.lag_tracker` show, and that ZODAN Phase 3
waits on, does not fall behind what has actually been applied.

## Code (code-checked)

- `handle_commit` builds a progress record with
  `remote_commit_ts = commit_time`, `remote_commit_lsn = end_lsn`
  (`src/spock_apply.c:~1148-1177`) and calls
  `spock_group_progress_update_ptr`.
- `progress_update_struct` (`src/spock_group.c:309-362`) copies the commit
  fields **only if `dest->remote_commit_ts < src->remote_commit_ts`**. Its
  comment says commit order follows timestamp order, so an older ts cannot
  arrive.
- That assumption fails when the provider's commit timestamps go backwards in
  commit order, which the commit-clock patch allows after a provider restart
  (L3: logical clock resets to 0; if the provider's wall clock is behind its
  last commit ts, new commits get smaller ts). Until P's ts passes the old
  maximum, every commit S applies from P leaves `remote_commit_lsn` frozen.
  `received_lsn` and `remote_insert_lsn` still advance (separate max checks),
  so `lag_tracker.replication_lag_bytes`
  (`remote_insert_lsn - remote_commit_lsn`, `sql/spock--6.0.0.sql:823-845`)
  grows while nothing is actually behind.

## Who reads it

- `spock.lag_tracker`, `spock.progress` (monitoring).
- ZODAN Phase 3 (`samples/Z0DAN/zodan.sql:~1885-1960`): after creating the
  slot X->new, it issues `sync_event(true)` on X and polls src's
  `spock.progress.remote_commit_lsn` for X until it reaches that LSN, with a
  `spock.sync_timeout()` budget. A frozen entry makes add_node time out
  (fails, does not corrupt).
- ZODAN Phase 7 reads `spock.progress.remote_commit_lsn` **on the new node**
  (`:2638-2648`). Those entries were force-set from
  `spock.read_peer_progress`, which now returns the origin's `remote_lsn`
  rather than the shmem `remote_commit_lsn` (`sql/spock--6.0.0.sql:127-215`,
  `COALESCE(rec.ros_remote_lsn, '0/0')`). So the freeze does not feed directly
  into Phase 7 slot placement; it does affect Phase 3.
- `wait_for_previous_transaction` uses the ts fields (dormant without slot
  groups).

## Workload check

On P, in the writing session, before COMMIT: `SELECT pg_current_wal_insert_lsn()`
(a lower bound for T's commit end LSN). After the row is seen on S, on S:
`SELECT remote_commit_lsn FROM spock.progress WHERE node_id = <S> AND remote_node_id = <P>`.
`Always(remote_commit_lsn >= lower_bound, "spock.progress commit LSN covers applied txn")`.

Scope: skip if S restarted between T's apply and the check (after a restart the
entry is rebuilt by `reconcile_progress_with_origin`,
`src/spock_progress_recovery.c:153-275`, which may lag differently; that is a
separate crash property), and skip if P has two subscriptions on S (they share
one progress entry, L16).

## Suggested SUT-side instrumentation (missing)

In `progress_update_struct`, in the branch where `src->remote_commit_lsn >
dest->remote_commit_lsn` but `src->remote_commit_ts <= dest->remote_commit_ts`:
`Unreachable("progress commit LSN update dropped because commit ts went backwards")`
with both ts and both LSNs. It hits the exact state, without depending on the
workload's timing.

## Fault requirements

- Provider restart (node termination or clean restart): required.
- Clock skew where the provider's clock is behind the ts it last committed
  (behind a peer whose commits it applied, or a backward step): required.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (implementability (property finding)); see `evaluation/synthesis.md`.

Current catalog line: Priority: P3 · Topology: v1 · Faults: clock skew + node kill of provider

- Priority note: lowered from P2: monitoring accuracy and add_node availability only, no data loss. Evaluation: cannot find a bug once 4e0988de is in the image (that commit makes `progress_update_struct` advance `remote_commit_lsn` whatever the timestamps), and the image without it runs no clock faults; kept only as a regression guard for the fix.
- The SUT-side `Unreachable` site does not exist in the patched code (`git show 4e0988de -- src/spock_group.c`).

## Open questions

None remain open (see Investigation Log).

## Findings (2026-10-13)

- **What a freeze breaks.** The apply worker never starts from
  `spock.progress` (it uses the replication origin,
  `src/spock_apply.c:4749-4751`), and Phase 7 now gets its LSNs from
  `ros.remote_lsn`, not this column. So a frozen `remote_commit_lsn` is a
  monitoring error (`spock.progress`, `lag_tracker.replication_lag_bytes`)
  plus an **add_node liveness** problem: ZODAN Phase 3 polls src's
  `remote_commit_lsn` for each peer X until it reaches the post-slot
  sync_event LSN (`samples/Z0DAN/zodan.sql:1925-1975`) and raises "Timed out
  waiting for source node ..." after `spock.sync_timeout()`. That fails the
  add; it does not lose data. Phase 12 `monitor_replication_lag` uses
  `remote_insert_lsn - received_lsn` (`:1066-1072`), not this column, so it
  is not affected. Suggest medium/low priority (monitoring + add_node
  availability).
- **Trigger confirmed in the core patch.** `patches/18/pg18-025-logical_commit_clock.diff`
  (`EnsureMonotonicTransactionStopTimestamp`): for a local commit the
  timestamp is bumped above the last stop timestamp, which apply commits
  raise to the remote commit ts; that value lives in `XLogCtl` and the
  patch's own TODO says it is "not postmaster restart safe". So after a
  provider restart, its local commits use its wall clock again; if that is
  behind the highest ts it had before (its own or one pulled up by a peer
  ahead in time), the ts it sends goes backwards and
  `progress_update_struct` (`src/spock_group.c:309-334`, update only if
  `dest->remote_commit_ts < src->remote_commit_ts`) stops moving
  `remote_commit_lsn` until wall time passes the old maximum. Without a
  provider restart plus a clock behind that maximum, this cannot fire.
- Another way the column can be "wrong" without skew: a table resync writes
  the provider's progress into the subscriber's row (max by ts), which can
  put it **ahead** of what was applied (see
  `progress-reconcile-anomaly-unreachable`). That does not violate this
  property (which checks "at or beyond"), but the workload must not use this
  column as an upper bound.

### Investigation Log

#### Is `spock.progress` accurate coordination state or advisory?

- Examined: `src/spock_apply.c:4740-4770`, `src/spock_sync.c:775-850`
  (resume LSN from `ros.remote_lsn`), ZODAN Phase 3 (`:1912-1975`), Phase 7
  (`:2637-2662`), Phase 12 (`:1060-1100`), design spec line 130.
- Found: steady-state replication ignores it; add_node waits on it (Phase 3)
  and reads n4's force-set rows (Phase 7), which come from the origin, not
  from the frozen column.
- Conclusion: resolved. A freeze is a monitoring bug that can also make
  add_node time out; not a data bug.

#### Can this fire without a provider restart plus clock skew?

- Examined: `patches/18/pg18-025-logical_commit_clock.diff:100-150`,
  `src/spock_group.c:309-362`, `src/spock_apply.c:1148-1177`.
- Found: commit ts is monotonic per provider while the postmaster stays up
  (the hook bumps local commits); the reset at startup is the only way for
  it to go backwards.
- Conclusion: resolved. Needs provider restart and a provider clock behind
  its previous logical maximum; both faults stay required.
