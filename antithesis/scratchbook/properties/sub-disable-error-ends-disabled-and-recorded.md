# sub-disable-error-ends-disabled-and-recorded — Under sub_disable a failing transaction ends with the subscription disabled and recorded

Surfaced by the evaluation as extra gap E2 (coverage-balance F2 and risk map:
claim S7 and lead L27 had no property and no planned run variant). Code
checked at 69d9228f. Not built or run.

## What the property says

With `spock.exception_behaviour = sub_disable`, a remote transaction T that
fails on a subscriber ends, within a bound after faults stop, in the
documented state: the subscription is disabled, `spock.exception_log` has a
`SUB_DISABLE` row for T (plus the per-change rows of the read-only replay),
and the subscription's origin is not past T. After the workload removes the
cause and calls `sub_enable`, T is applied once and replication goes on.
The subscription never sits in a restart loop with nothing recorded.

## Mechanism (code-checked)

Normal path:

1. First attempt fails -> `apply_work` `PG_CATCH` "caught initial exception"
   branch: `AbortOutOfAnyTransaction()`, save the error text, switch to
   in-process replay (`need_replay`, `use_try_block = true`,
   `src/spock_apply.c:4060-4140`).
2. Replay is read-only: under TRANSDISCARD and SUB_DISABLE every change of T
   is skipped and logged with `log_insert_exception(false, ...)`
   (`:1633-1650`, `:1811-1830`, `:1944-1960`, TRUNCATE `:2156-2175`, queued
   SQL `:2775-2790`).
3. `handle_commit`: the origin is **not** advanced under SUB_DISABLE with
   `use_try_block` (`:997-1009`); the exception rows commit; then
   `clear_exception_log_entry` and `elog(ERROR, "disabling subscription due
   to exception in SUB_DISABLE mode")` (`:1067-1084`).
4. `PG_CATCH` `SUB_DISABLE` branch (`:4013-4027`): no transaction is open,
   so `spock_disable_subscription` starts and commits its own
   (`src/spock_exception_handler.c:232-276`): `enabled = false` plus a
   `SUB_DISABLE` exception_log row naming the skip LSN.

Lead L27 (inner-loop route):

- During replay, a change whose relation is missing on the subscriber makes
  `spock_read_insert/update/delete` return NULL (only in try mode,
  `src/spock_proto_native.c:813-819`), and `handle_insert/update/delete`
  set `xact_had_exception = true` mid-transaction (`:1590-1611`,
  `:1776-1790`, `:1905-1920`).
- After each batch of messages read from the socket, the inner loop checks
  `xact_had_exception` (`src/spock_apply.c:3803-3826`) and, under
  SUB_DISABLE, calls `spock_disable_subscription` and `return`s from
  `apply_work`. If T's COMMIT was not in the same batch, T's transaction is
  still open: `spock_disable_subscription` does not commit it (its header
  says the caller must commit or FATAL), `spock_apply_main` calls
  `proc_exit(0)` (`:4793-4797`), and exit-time abort rolls back the disable,
  the `SUB_DISABLE` row and every replay row.
- The worker exit is clean, so the manager restarts it; the shared-memory
  marker still holds T's `commit_lsn`, so the next worker enters replay for
  T again and repeats. Result: the subscription stays enabled, nothing is
  recorded, nothing from that provider applies, and `sub_show_status`
  alternates between `replicating` and `down`.
- Whether COMMIT lands in the same batch depends on how T's messages are
  split across network reads: a small T usually arrives whole, a large T or
  a slow link splits it. TAP 016 (`tests/tap/t/016_sub_disable_missing_relation.pl`)
  covers the single-read case with a one-row insert and passes.

Interrupted disable (self-healing, guard only):

- Any other ERROR during replay (for example a cancel) reaches the same
  `PG_CATCH` SUB_DISABLE branch while T's transaction is still open (state
  is still in progress before abort), so that disable is also rolled back at
  exit. Here the marker survives, the next worker replays T, reaches
  `handle_commit`, and disables normally. A node kill between the
  exception-row commit and the disable commit loses the marker; the next
  worker fails T again and writes a second set of rows before disabling
  (duplicate rows, no loss).

## Invariant

- Workload `Always("sub_disable: failing transaction ends with its subscription disabled and a SUB_DISABLE row within bound after faults stop")`,
  bound about `apply_idle_timeout + restart_delay_default + connect_timeout`
  plus margin (the same quiet-period budget as the barriers).
- Workload `Always("sub_disable: after fix and sub_enable the failing transaction is applied exactly once")`,
  checked with the ledger oracle on the poison transaction's other rows.
- SUT-side `Unreachable("SUB_DISABLE disable written inside a remote transaction that is then rolled back")`:
  at the inner-loop call (`:3811`) and in the `PG_CATCH` SUB_DISABLE branch
  when `IsTransactionState()` is true before the call. The inner-loop site
  is always followed by an abort at exit, so any hit there is the bug.
- `Sometimes("sub_disable: failing transaction spanned more than one network read")`
  (SUT-side, at the inner-loop check while `in_remote_transaction`), and
  workload `Sometimes("sub_disable: worker exit landed during replay")`.

## Workload and faults

- Run variant: `spock.exception_behaviour = sub_disable` on every node
  (deployment topology, new configuration). The main template's poison
  tables are reused; the app table of
  `every-divergence-explained-by-spock-records` is not (an `update_missing`
  would disable the subscription and replay the same failure).
- Poison kinds: a local-only CHECK or trigger on one subscriber (fix: drop
  it), and a table missing on one subscriber (the table is added to the
  replication set on the origin and dropped locally on that subscriber;
  fix: re-create it). Mix small and large transactions (many rows, some
  above the spill threshold) so some span several reads.
- Faults: latency and CPU throttling on the provider-to-subscriber link
  (decide where reads split), worker terminate or cancel during replay,
  node kill between the two commits, partitions during replay.
- After each disable: fix, `sub_enable`, barrier, ledger check.

## Instrumentation

Missing. The two SUT-side messages above are new; the workload part needs
only SQL (`spock.sub_show_status`, `spock.exception_log`).

## Related properties

- `interrupted-exception-replay-still-records-txn`: same replay code; it
  checks the outcome after interrupts (TRANSDISCARD and SUB_DISABLE). This
  property adds the bound, the inner-loop route and the run variant.
- `sub-disable-enable-cycle-loses-and-duplicates-nothing`: operator
  disables, not error disables.
- `worker-respawn-rate-bounded`: the L27 loop is a clean-exit respawn loop
  and also shows up in its registration count.

## Open questions

- Should the inner-loop route commit the disable (or exit with FATAL so the
  next start disables), or should the inner-loop check wait for COMMIT?
  Affects the fix only. `(needs human input)`
- Is the `sub_disable` run variant in scope for the first runs? The
  topology lists it as a planned variant pending the exception-mode
  decision. `(needs human input)`

### Investigation Log

#### Does the inner-loop SUB_DISABLE call commit its writes?

- Examined: `src/spock_apply.c:3780-3830` (inner-loop check),
  `:4785-4797` (`spock_apply_main` after `apply_work`),
  `src/spock_exception_handler.c:217-276` (`spock_disable_subscription`),
  `:1580-1615` (missing-relation path in `handle_insert`),
  `src/spock_proto_native.c:813-819`.
- Found: the call runs while T is open (`xact_had_exception` is set before
  COMMIT); the function commits only a transaction it started; the caller
  returns and the process exits with `proc_exit(0)`, which aborts the open
  transaction.
- Not found: any commit between the `return` and `proc_exit`.
- Conclusion: L27 confirmed by code reading for a T whose COMMIT is not in
  the same read batch as the failing change; not run.

#### What does TAP already cover?

- Examined: `tests/tap/t/016_sub_disable_missing_relation.pl`,
  `105_sub_disable_retransmit_after_disconnect.pl`.
- Found: 016 drops a table on the subscriber and inserts one row on the
  provider; it expects `disabled` and a `SUB_DISABLE` row and passes, which
  matches the single-read path.
- Not found: a test with a large transaction or a split read.
- Conclusion: `(partial: TAP covers the single-read case; the multi-read case is untested and can be reproduced in TAP with a large transaction before Antithesis)`

#### Which errors reach the inner-loop route under SUB_DISABLE?

- Examined: every `xact_had_exception = true` in `src/spock_apply.c`.
- Found: under TRANSDISCARD and SUB_DISABLE replay, DML is skipped, so
  only the missing-relation branches (insert, update, delete) set the flag
  mid-transaction; the other sites are DISCARD-only.
- Conclusion: the route needs a relation missing on the subscriber; that
  needs an operator drop or a cross-node DDL race, so the workload creates
  it on purpose.
