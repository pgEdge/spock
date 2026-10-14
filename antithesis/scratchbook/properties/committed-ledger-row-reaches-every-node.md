# committed-ledger-row-reaches-every-node

## What the property says

Every row the workload committed on any mesh node (client got a successful
COMMIT) is eventually present, with the same content, on every other node that
was a full member of the mesh at commit time, once faults stop and a
`sync_event` / `wait_for_sync_event` barrier has passed for every ordered pair.

The table is an insert-only "ledger" with a key the workload owns:
`ledger(origin_node text, seq bigint, txn_tag bigint, payload text,
PRIMARY KEY(origin_node, seq))`. No updates, no deletes, no shared keys. So the
ledger causes no conflicts of any kind, and there is no documented reason
(sut-analysis section 12) for Spock to drop or keep back any row of it.

## Why this is the base data-integrity property

Spock's product promise is that a transaction committed on one node reaches
the others. With conflict-free traffic, the only ways to lose a ledger row are
Spock bugs:

- **Error classifier gaps (L5)**: an infrastructure error that is not on the
  transient allow-list (57014 from `pg_cancel_backend`, class 58 I/O errors,
  FATAL paths that skip `PG_CATCH` and leave the shmem `commit_lsn` marker) is
  treated as a data fault. Under the default `transdiscard` the whole upstream
  transaction is replayed read-only, logged to `spock.exception_log` and the
  origin is advanced past it (`handle_commit`, `src/spock_apply.c:996-1009`).
  The row never arrives. `PG_CATCH` is `src/spock_apply.c:3867-4133`.
- **Replay origin advance (L7)**: `AbortOutOfAnyTransaction()` at
  `src/spock_apply.c:~4065` runs with `replorigin_session_origin_lsn =
  commit_lsn` still set; stock `RecordTransactionAbort` advances the session
  origin. A graceful exit during replay could then skip the transaction with
  no exception row.
- **add_node pause window (L4)** for rows written while n4 is joining (covered
  separately by an add-node property; see scope below).
- **Slot groups (L10)**: a slot name ending in `_<digit>` makes walsenders of
  different subscribers skip each other's transactions. Workload boundaries
  forbid such names, so a hit here means a name slipped through.
- **FAILED table sync (L12)**: apply skips changes for tables not READY while
  the origin advances (`should_apply_changes_for_rel`,
  `src/spock_apply.c:464-484`).
- **Async apply commit + feedback**: apply runs with `synchronous_commit=off`
  (`src/spock_apply.c:4699-4716`). Feedback only reports a flush position
  whose local commit is at or below `GetFlushRecPtr()` (`send_feedback`,
  `src/spock_apply.c:3237`). If that rule were broken (pattern B in bug
  history, e.g. 5f654e34 and L9), a subscriber crash would lose an applied
  transaction that the provider already considers confirmed.

## Oracle design (workload side)

- Each writer picks a node, opens a transaction, inserts K ledger rows with a
  fresh `txn_tag` and `seq` values from a per-node counter kept in the
  workload, commits. The client records the outcome:
  - COMMIT returned OK -> "committed".
  - Error before COMMIT was sent -> "not committed".
  - Connection lost during COMMIT, or COMMIT error of unknown kind ->
    "unknown". Unknown rows are allowed to be present or absent, but must be
    present on all nodes or none (all-or-none across nodes is checked here
    too; see Open Questions).
- Node `synchronous_commit` for client sessions stays at the default `on`, so
  a committed row is durable on its origin node before the ack.
- Check phase: stop writes, wait until all faults are healed, then for every
  ordered pair (P, S) run `spock.sync_event()` on P and
  `CALL spock.wait_for_sync_event(NULL, P_id, lsn, timeout)` on S with a
  timeout of at least `spock.apply_idle_timeout` + slack. Then read the ledger
  on every node and compare to the committed set.
- Assertion: `Always(every committed (origin_node, seq) is present on every
  mesh node with identical payload)`. On failure, include the missing keys,
  the node, and whether `spock.exception_log` on that node has a row for the
  same remote commit (this tells L5/L7-style drops apart from silent loss).

`Always` is right: this must hold at every check, and one missing row is a
bug.

## Scope

- Mesh members: n1, n2, n3 for the whole run. n4 only for rows committed
  after a **successful** add_node returned (rows committed during add_node are
  the subject of the add-node property; an add_node that failed means n4 is
  not checked).
- Nodes that are killed and restarted on the same data directory stay in
  scope. Permanently removed nodes do not (documented: needs ACE).
- Exception behaviour `transdiscard` or `sub_disable`. With `sub_disable`, a
  disabled subscription stops the barrier; the workload should record that as
  a failure of this property too (with infrastructure faults only, Spock
  claims no subscription becomes disabled, S3), or re-enable and re-check.
- If the barrier times out (liveness problem), report that through a liveness
  property and skip this check for that round rather than reporting loss.

## Fault requirements

- Network partitions and latency between pairs (connection-class errors).
- Node termination (kill -9 of postmaster) and restart on same PGDATA.
- Process pause of providers/subscribers (apply idle timeout path).
- A custom fault or test command that runs `pg_cancel_backend` /
  `pg_terminate_backend` on apply workers (graceful single-worker exits,
  57014). Postmaster kill alone wipes shmem and hides L5/L7.

## SUT-side instrumentation (all missing; no Antithesis assertions exist)

- `Unreachable("apply entered exception replay in a conflict-free run")` at
  the "caught initial exception" branch in `apply_work` `PG_CATCH`
  (`src/spock_apply.c:~4040-4080`). Only meaningful in a test template where
  the workload produces no conflicts; guard it behind a GUC or build flag set
  only in that template.
- `Reachable("apply worker exited via connection-class rethrow")` at the
  connection branch of the classifier, to confirm faults actually hit the
  path.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit CW1/CW2, implementability CW2/CW6, coverage-balance F10, wildcard W2); see `evaluation/synthesis.md`.

Current catalog line: Priority: P0 · Topology: v1 · Faults: worker exit (test cmd), partition, node kill

- Evaluation note (2026-10-13): cancel (57014) and `terminate_active_transactions` (40001) test commands run in a separate classifier template until L5 and the 40001 path are fixed or accepted, so in the main template a missing row points at a new cause. Workload-side `Sometimes("cancel or terminate reached an apply worker with backend_xid set")` shows the dangerous state was reached without SUT instrumentation.
- Missing-row message split into explained (recorded classifier error) and unexplained. The SUT-side `Unreachable("apply entered exception replay in a conflict-free run")` is guarded by a placeholder GUC such as `antithesis.conflict_free`, set per configuration.

## Open questions

- None open. Both earlier questions were settled by code reading; see the
  Investigation Log. The decisions they produced:
  - **Unknown-outcome commits** are resolved against the origin node after
    it is back (rows are durable there before the ack because client
    `synchronous_commit=on`). Present on the origin -> treat as committed and
    require it on every node; absent on the origin -> require it absent
    everywhere. The checked rule is "same on every node as on the origin".
  - **`sub_disable` is not loss.** In that mode the origin is not advanced
    past the failing transaction, so it is re-sent after re-enable. A disabled
    subscription in a conflict-free run is reported by its own `Always`
    ("no subscription disabled with infrastructure faults only", S3); the
    check phase then re-enables, re-runs the barrier and checks for loss.

### Investigation Log

#### How should "unknown" commits be treated?

- Examined: the oracle design above; client `synchronous_commit=on`
  (harness config); `handle_commit` origin advance rules,
  `src/spock_apply.c:996-1009`; no 2PC or synchronous standby in scope.
- Found: with `synchronous_commit=on` and no sync standbys, a COMMIT that
  wrote its commit record and flushed it is committed on the origin and
  survives a crash; one that did not flush is gone. The origin node is
  therefore the authority for every unknown outcome once it is reachable
  again. Spock only ever ships what the origin committed.
- Not found: any Spock path that could deliver a transaction the origin did
  not commit.
- Conclusion: resolved. Decide each unknown by reading the origin after it
  returns; then the normal "present on every node" rule applies. All-or-none
  inside one transaction on one node is the job of
  `remote-transaction-all-or-nothing-per-node`.

#### Does `sub_disable` count as loss?

- Examined: `handle_commit`, `src/spock_apply.c:996-1009` (origin LSN is set
  to `end_lsn` only when there was no exception and not `use_try_block` under
  `SUB_DISABLE`, or the mode is DISCARD/TRANSDISCARD); `:1067-1084` (after
  committing exception rows, `SUB_DISABLE` throws an ERROR before the
  `lsn_mapping` entry is pushed, so no feedback confirms it); PG_CATCH
  disable path `:4013-4030`; `docs/configuring.md:160-184`.
- Found: under `sub_disable` the failing transaction is not skipped. The
  origin is left at the BEGIN `commit_lsn` and decoding re-sends a
  transaction whose commit record starts at the restart point, so re-enable
  re-applies it.
- Conclusion: resolved. Disabled = availability failure (separate Always),
  not loss; re-enable and re-check before judging loss.
