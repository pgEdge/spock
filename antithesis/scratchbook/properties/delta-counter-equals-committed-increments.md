# delta-counter-equals-committed-increments

## What the property says

For a table whose counter column is a delta-apply column
(`log_old_value=true, delta_apply_function=spock.delta_apply`, NOT NULL), after
quiescence and barriers, on every mesh node:
`counter(row) == initial(row) + sum of every committed increment to that row
on any node`.

## Claimed guarantee

`docs/conflicts.md:10-34`: "the delta-apply column will be correctly
calculated and applied" on conflicting transactions; the bank example ends at
the correct total. sut-analysis S12.

## Mechanism (code-checked)

- Provider ships old and new values for `log_old_value` columns (core patch
  `pgNN-015-attoptions.diff`).
- On every remote UPDATE where the local row is found,
  `spock_handle_conflict_and_apply` (`src/spock_apply_heap.c:589-790`) runs LUW
  and then, if the table has delta columns, builds
  `local + (remote_new - remote_old)` (`build_delta_tuple`, `:510-582`). If LUW
  kept the local row, `apply` is forced true and the update runs in a
  subtransaction whose commit ts/origin is overwritten with the local winner's
  (`SubTransactionIdSetCommitTsData`, patch 030, `:775-780`).
- A remote INSERT that finds an existing row uses a zero "old" tuple
  (`init_tuple_with_defaults`, `:897-906`), so concurrent inserts of the same
  key add up. The workload avoids this by pre-seeding rows.
- A NULL old value (source had `log_old_value` off) falls back to plain
  overwrite (`:545-556`). Workload boundaries forbid this.

**Delta apply is not idempotent.** Any redelivery double counts; any dropped
transaction under-counts. So this property is the sharpest exactly-once
oracle in the catalog.

## Leads that break it

- L1: subscriber crash between checkpoints -> origin rolls back -> resend ->
  double count (see `ledger-row-applied-exactly-once-per-peer`).
- L5/L7: transaction dropped by the exception path -> under-count (with an
  `exception_log` row for L5, possibly without one for L7).
- L19: forwarded-origin advance after commit (only with `forward_origins`;
  out of v1 scope).
- Crash between `COMMIT_TS_SUBTRANS_TS` and the commit record (L32 item):
  should be atomic since both are in one transaction, but untested.
- `sub_alter_skiplsn` and `repair_mode` drop changes by design; the workload
  must not use them.

## Oracle design

- Setup (quiesced, before faults): `counters(id int primary key, val bigint
  not null)`, set the column options on **every** node, insert R rows with
  `val = 0` on one node, barrier until all nodes have them.
- Writers: `UPDATE counters SET val = val + k WHERE id = r` with k chosen at
  random (positive and negative), one or several rows per transaction. Record
  committed k per row (unknown-outcome commits recorded separately; see Open
  Questions).
- Check: after barriers, `Always(for each row, val on every node equals the
  sum of committed k)`. On failure report node, row, expected, actual and the
  difference (a difference equal to one committed k points at a single lost or
  doubled transaction).
- Also check `SUM(val)` across rows as a quick first signal.

`Always`: one wrong counter is a violation.

## Fault requirements

- Node termination with restart on same PGDATA (required for L1). Large
  `checkpoint_timeout`.
- Graceful apply exits (`pg_cancel_backend`, `pg_terminate_backend`) and
  partitions (L5, L7).
- Clock jitter is not needed; LUW outcome does not change the delta result.

## SUT-side instrumentation (missing)

- `Reachable("delta apply forced on a row where LUW kept local")` at
  `is_delta_apply = true` (`src/spock_apply_heap.c:~679`), to confirm the
  workload produces real concurrent updates.
- `Reachable("delta apply with NULL old value fell back to overwrite")` at
  `:545` should never be hit in v1; make it
  `Unreachable("delta column received NULL old value")` in the v1 template.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit CW1, wildcard W2, coverage-balance F5, implementability CW4); see `evaluation/synthesis.md`.

Current catalog line: Priority: P0 · Topology: v1 · Faults: node kill between checkpoints, worker exit

- Evaluation note (2026-10-13): the wrong-total message is split into "delta total off on a node that crashed since the increment and shows a node-id origin state" (explained by L1) and "delta total off, unexplained". Crash timing comes from the crash helper (kill within the unconfirmed window after a burst), with the same workload-side `Sometimes` as `ledger-row-applied-exactly-once-per-peer`. n4's counters are checked by `add-node-success-new-node-has-every-row`.

## Open questions

- Does the team treat at-least-once on direct subscriptions as a bug? `(needs human input)` If not, delta columns are unsafe under any subscriber crash (L1 is confirmed on PG18, see `ledger-row-applied-exactly-once-per-peer`) and `docs/conflicts.md` needs a caveat; the property still stands as a test of the documented claim.

Resolved: unknown-outcome commits (see Investigation Log). Decision: each
writer transaction also inserts a marker row `(origin_node, txn_tag, k per
row)` into a plain insert-only table in the same transaction. After the
origin is back, the marker decides whether the increments count. The check
stays exact (no ranges).

### Investigation Log

#### How to handle unknown-outcome commits?

- Examined: client `synchronous_commit=on` on the origin (harness config);
  apply atomicity (`handle_begin`..`handle_commit` in one local transaction,
  `src/spock_apply.c`); the delta subtransaction
  `src/spock_apply_heap.c:~713-782` (re-throws on error, so it cannot commit
  half a remote transaction).
- Found: the origin node is the authority for whether a transaction
  committed; a marker row in the same transaction is committed or not
  together with the increments, on the origin and (via all-or-nothing apply)
  on every peer.
- Conclusion: resolved by workload design. Read markers on the origin after
  it returns; count only marked transactions. A marker present on a peer but
  absent on the origin is itself a finding.

#### Is at-least-once on direct subscriptions accepted?

- Examined: same sources as the exactly-once property's log; in particular
  `src/spock_apply.c:5157-5161` ("last_update_wins handles the duplicate;
  delta-apply idempotency is tracked separately", written for forwarded
  origins).
- Found: the team knows delta apply is not idempotent and calls it out for
  forwarded origins; nothing covers direct subscriptions. L1 is confirmed at
  code level on the PG18 target, so a subscriber kill -9 between checkpoints
  should double-count in this run.
- Conclusion: `(needs human input)` for intent. The property and `Always`
  stay; a failure here maps to L1 when the difference equals one committed k
  and the node was killed just before.
