# remote-transaction-all-or-nothing-per-node

## What the property says

A multi-row transaction committed on origin O is visible on any other node S
either completely or not at all, at every moment a reader on S looks (not only
after quiescence). With `exception_behaviour` = `transdiscard` or
`sub_disable`, a transaction that hits a data error is dropped as a whole.

## Claimed guarantee

- Apply wraps each upstream transaction in one local transaction
  (`handle_begin` .. `handle_commit`, `src/spock_apply.c:~651-1140`), so stock
  PostgreSQL atomicity covers normal running and crashes.
- `docs/configuring.md:160-184`: `transdiscard` discards the whole
  transaction; `sub_disable` disables the subscription and leaves the origin
  at the start of the bad transaction; only `discard` commits the
  non-failing parts (excluded by workload boundaries).
- sut-analysis S2 ("under TRANSDISCARD each remote transaction is
  all-or-nothing per node").

## Ways it could break

- **Per-table apply filtering (L12)**: `should_apply_changes_for_rel`
  (`src/spock_apply.c:463-484`) skips changes for any table whose sync status
  is not READY (or SYNCDONE caught up) while still applying the rest of the
  transaction and advancing the origin. A transaction touching a table that is
  being resynced, or that is stuck FAILED, is applied partly. During an
  intended table resync this is by design (the sync worker delivers the
  skipped part later); with a FAILED table it lasts until an operator runs
  `sub_resync_table` again. FAILED is reached not only on a data error during
  COPY: any restart of a table-sync worker after it set STARTED (connection
  loss, kill, node crash during the resync) makes the next attempt set FAILED
  (`spock_sync_table`, `src/spock_sync.c:1846-1866`). Infrastructure faults
  can therefore create a permanently skipped table.
- **Replay paths**: under `transdiscard` the replay is read-only
  (`begin_replication_step`, `src/spock_apply.c:~620-631`) and `handle_commit`
  commits only the exception rows (`:1015-1047`). Any replay path that left a
  successful row write in place would make a partial transaction visible. The
  classifier has a dense fix history (sut-analysis 5.1) and the replay path
  for "use_try_block" has had stale-state bugs (acf6cdae).
- **Delta-apply subtransaction** (`src/spock_apply_heap.c:~713-782`): an error
  inside it is re-thrown; if a future change caught it, rows before it would
  commit without it.
- **L27**: `sub_disable` writes the disable and exception rows into the open
  remote transaction; if `apply_work` returns mid-transaction, proc exit
  aborts it. That is all-or-nothing for data rows but loops.

## Oracle design

- Table `ledger` (from `committed-ledger-row-reaches-every-node`) plus a second
  table `ledger_b` with the same key shape. Each writer transaction inserts K
  rows (K random in 2..20) split across `ledger` and `ledger_b`, all tagged
  with one `txn_tag`, and records K.
- Reader task, run continuously during the fault phase against every node:
  in one REPEATABLE READ transaction, `SELECT txn_tag, count(*) FROM (ledger
  UNION ALL ledger_b) GROUP BY txn_tag` and compare to the recorded K.
- `Always(for every txn_tag seen on S, count == K)`.
- Skip a node while any of its `spock.local_sync_status` rows is not `r`
  (resync or initial sync in progress), and n4 until its add_node returned.
  A table stuck in a non-`r` state is a separate (liveness/silent-drift)
  finding; record it via `sub_show_table` so it is not hidden.

`Always`: partial visibility is never allowed in scope.

## Fault requirements

- Node termination mid-apply (crash atomicity; expected to hold, good
  control).
- Graceful apply exits during a large transaction (cancel, terminate,
  partition) to drive the replay paths.
- Table resync (`spock.sub_resync_table`) under writes, in a quiesced-DDL
  phase, to reach the per-table filter; this is where a FAILED status would
  show up.

## SUT-side instrumentation (missing)

- In `handle_commit` on the replay path for `transdiscard`:
  `Always("transdiscard commit wrote no user-table rows")`, e.g. check that
  `XactReadOnly` holds (there is already `Assert(XactReadOnly)` at
  `src/spock_apply.c:~1048`, which only fires in cassert builds and crashes
  the instance).
- In `should_apply_changes_for_rel` when it returns false:
  `Reachable("apply skipped a change for a table not yet READY")` and, when the
  status is FAILED, `Sometimes("apply skipped a change for a FAILED table")`
  as a coverage marker. Skipping for FAILED is intended (6a063b22), so it is
  not `Unreachable`; whether a FAILED status caused by an infrastructure fault
  is acceptable is the open question below.
- In `spock_sync_table` at the "previous attempt did not finish -> FAILED"
  branch (`src/spock_sync.c:1846-1866`): `Reachable("table sync marked FAILED
  after an interrupted attempt")`, to show faults reach it.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (implementability CW5); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 (FAILED-table path needs the admin-churn phase) · Faults: worker exit, admin churn, node kill

- Evaluation note (2026-10-13): the FAILED-table path uses resyncs of a dedicated single-writer table (`resync_<P>`, written only on P), because a `truncate := true` resync of a table several nodes write loses rows for good and would fire the ledger checks for a reason the workload caused (see Assumption 5).

## Open questions

- Should an infrastructure fault during a single-table resync (connection loss, worker or node kill) leave the table FAILED with its changes skipped until an operator resyncs? `(needs human input)`

Resolved (see Investigation Log): skipping changes for a FAILED table is
intended and the property already excludes nodes with any non-`r` table;
initial subscription sync copies all tables under one snapshot and commits
them in one target transaction, so it cannot expose part of a transaction.

Consequence for the workload: keep the non-`r` skip rule, but count how often
a node is skipped for FAILED and report it through a separate check
("every resync started under faults ends `r` after the workload retries it"),
so a FAILED table is never hidden by this property's skip rule.

### Investigation Log

#### Is skipping changes for a FAILED table intended?

- Examined: `should_apply_changes_for_rel`, `src/spock_apply.c:463-484`
  (false for any status other than READY or caught-up SYNCDONE);
  `process_syncing_tables` `:4490-4510` ("Failed SYNC operation should be
  ignored until someone processes the error and changes the status") and
  `:4600-4615`; `spock_sync_table`, `src/spock_sync.c:1820-1875`;
  `sub_resync_table`, `src/spock_functions.c:1300-1330` (accepts FAILED);
  commit 6a063b22 ("stop table sync on failure instead of retrying");
  `docs/spock_release_notes.md:331-335`; regress test
  `tests/regress/sql/sync_table.sql:112-152` (CHECK-constraint COPY failure ->
  FAILED -> `table_wait_for_sync` ERROR -> resync after fix).
- Found: FAILED and the skip are intended for data errors, and are visible
  through `local_sync_status` and `table_wait_for_sync`. But the trigger is
  "the sync worker re-entered and found a non-INIT status". The status is set
  to STARTED and committed before connecting (`:1873-1875`), then DATA before
  COPY (`:1903-1905`); on any error the cleanup callback only drops the slot
  and origin (`spock_sync_worker_cleanup`, `:1429-1468`). So a network fault
  or kill during COPY or catch-up also ends in FAILED. Only the data-error
  case is tested.
- Not found: any retry or reset to INIT for connection-class errors.
- Conclusion: skipping for FAILED is intended (resolved). Whether an
  infrastructure fault should reach FAILED is `(needs human input)`. The
  property's skip rule stays.

#### Are multi-table transactions copied under one snapshot during initial sync?

- Examined: `spock_sync_subscription`, `src/spock_sync.c:~1500-1560`;
  `copy_replication_sets_data` `:1322-...`; `start_copy_origin_tx` /
  `start_copy_target_tx` `:889-960` (origin: `REPEATABLE READ, READ ONLY`
  with `SET TRANSACTION SNAPSHOT` of the slot's exported snapshot; target: one
  `READ COMMITTED` transaction with `session_replication_role = replica`).
- Found: all tables of the subscription's replication sets are copied in one
  origin transaction under the slot snapshot and written in one target
  transaction, committed once at the end. Single-table resync uses its own
  slot and snapshot per table (`spock_sync_table`, `:1878-1905`), so tables
  resynced separately can be at different points until catch-up ends.
- Conclusion: resolved. Initial subscription sync cannot show part of a
  transaction. Separate per-table resyncs can until they reach `r`; the
  non-`r` skip rule covers that.
