# apply-cancel-retried-not-discarded

## What the property says

A query cancel delivered to an apply worker (`pg_cancel_backend(<apply pid>)`,
SIGINT, SQLSTATE 57014) is a transient, operator- or tool-caused interruption.
It must lead to a retry of the same remote transaction (worker restart, resend
from the origin), never to exception replay. In a conflict-free workload:

- no `spock.exception_log` row has an `error_message` containing
  `canceling statement due to user request` or SQLSTATE 57014, and
- no subscription becomes disabled (`spock.subscription.sub_enabled` stays
  true),

and every ledger row committed on a provider eventually appears on the
subscriber whose apply worker was cancelled.

## Why (retry semantics, lead L5)

`apply_work()` has one `PG_TRY`; the `PG_CATCH` (`src/spock_apply.c:3867-4133`)
retries only on an allow-list:

1. connection class: 08006, 08000, 08003, 57P01, 57P02, 57P03, or
   `PQstatus == CONNECTION_BAD` (`:3916-3932`)
2. 40P01, 55P03 (`:3967-3973`)
3. class 53 (`:3990-3994`)

Everything else is a "first occurrence of an exception" (`:4063-4070`):
`AbortOutOfAnyTransaction()`, `elog(LOG, "SPOCK: caught initial exception -
%s")`, save the message in the shmem marker, `apply_replay_queue_start_replay()`,
`use_try_block = true`, replay in the same process. Under default TRANSDISCARD
the replay is read-only, every row goes to `spock.exception_log`, and
`handle_commit` advances the origin past the transaction (`:996-1009`). Under
SUB_DISABLE the subscription is disabled.

57014 is not on the list. Its comment block (`:3945-3957`) only discusses
40001; 57014 is not mentioned anywhere in the classifier.

Reachability (assumption 6 in sut-analysis, settled in 11.4): DB-connected
bgworkers keep PG's `StatementCancelHandler` for SIGINT (stock `bgworker.c`),
Spock replaces only SIGTERM (`handle_sigterm`, `src/spock_worker.c:84`). So
`pg_cancel_backend()` on the apply pid sets `QueryCancelPending`, and the next
`CHECK_FOR_INTERRUPTS()` inside apply (heap ops, index lookups, the loop at
`:3615`) raises 57014. `statement_timeout` is not armed in the apply path, so
cancel is the realistic source. Monitoring scripts and tools that cancel
"long-running" backends by pid are the real-world trigger.

Spock claims the opposite outcome for transient faults: "resumes from the last
durably-committed origin LSN and re-streams the aborted txn"
(`src/spock_apply.c:3893-3897`; release notes `docs/spock_release_notes.md:603-610`).
This property verifies that claim for cancel.

Not covered by `lock-contention-retried-not-discarded`, which scopes 57014
out.

## Failure scenario

1. n1 commits a multi-row ledger transaction T.
2. n2's apply worker is applying T; the workload (or a custom fault) runs
   `SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE backend_type
   LIKE 'spock apply%'` on n2.
3. 57014 in the first pass -> replay -> TRANSDISCARD discards T on n2 and logs
   its rows. n1 and n3 keep T; n2 never gets it. Permanent, logged divergence
   caused by an operator action.

The window is the time the apply worker spends inside a remote transaction.
Large transactions and `spock.output_delay`/injection-point stalls widen it.
Cancel between transactions is harmless (no `in_remote_transaction`; the
error goes down the same path but the next BEGIN clears the stale state via
case 3 in `handle_begin`, `:847-874`).

## Assertions

- **Workload-side:** after quiesce + barriers,
  `Always(count(exception_log rows mentioning 57014 or 'canceling statement') == 0
  and all subscriptions enabled)`. Always: must hold at every check.
- **SUT-side (missing, no existing assertions):** in the `PG_CATCH` just
  before `AbortOutOfAnyTransaction()` at `:4065`,
  `Unreachable("apply worker entered exception replay for a query-cancel error")`
  when `edata->sqlerrcode == ERRCODE_QUERY_CANCELED`. Separate message for
  class 58 (`ERRCODE_TO_CATEGORY == ERRCODE_SYSTEM_ERROR`, I/O errors) and
  40001, so each gap is reported on its own.
- **SUT-side companion (missing):** `Reachable` markers on each retry branch
  ("connection-class retry", "deadlock/lock-timeout retry", "class-53 retry")
  so a run shows which retry paths fault injection reached.

## Fault requirements

- Custom fault / test command: `pg_cancel_backend` on Spock apply backends at
  random times on random nodes. Antithesis does not send SIGINT to a chosen
  backend by itself.
- CPU modulation / thread pausing helps keep apply inside a transaction when
  the cancel lands.
- Workload: insert-only ledger rows with per-node keys (no conflicts), so any
  exception_log row is unexplained.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit CW1, wildcard W2/W5, implementability (backend_type), coverage-balance F10); see `evaluation/synthesis.md`.

Current catalog line: Priority: P0 · Topology: v1 · Faults: worker exit (cancel test command), CPU modulation

- Placement: Expected to fire deterministically — confirm with TAP first, then gate out of the main template.
- Evaluation note (2026-10-13): any cancel that lands inside a remote transaction triggers it; Antithesis adds only where in the transaction. Confirm with a TAP script (`pg_cancel_backend` on an apply pid mid-transaction), then run the cancel test command in a separate classifier template until a fix is in the image; afterwards it is a good regression guard. Pids come from `pg_stat_activity.backend_type` (`spock apply <dboid>:<subid>`). Workload-side `Sometimes("cancel sent while the apply worker had backend_xid set")`. "No exception_log row" checks ignore rows in the expected-exception registry.

## Open questions

- **Is 57014 meant to be a data fault?** If the team says cancel of an apply
  worker is an operator error that may drop data, this property is scoped to
  "logged, not silent" and the Always would check only that each dropped
  transaction has exception_log rows. If transient, the current code is a bug
  (pattern A in the bug history: eleven earlier fixes of the same shape).
  `(needs human input)`

## Resolved: other interrupt-raised codes reachable from outside

Answered from the PG 18.3 tree (`~/dev/pgedge/postgresql`, with the Spock
patches applied; none of them touch the interrupt code). 57014 is **not** the
only gap, so adding one code to the allow-list would not close it:

- **40001 on a primary.** `spock.terminate_active_transactions()` sends a
  recovery-conflict SNAPSHOT signal to every backend with a vxid, apply
  workers included, and the handler does not check `RecoveryInProgress()`.
  Result: ERROR 40001 at top level, FATAL 40001 inside a subtransaction
  (DISCARD-mode replay, delta-apply subtransactions). The earlier note "only on
  standbys" was wrong. Covered by
  `terminate-active-transactions-never-discards-inbound`.
- **25P04 `transaction_timeout` (PG 17+), FATAL.** `StartTransaction()`
  (`xact.c:2238`) arms the timer for any backend, bgworkers included, and
  `ProcessInterrupts` raises `ereport(FATAL, ERRCODE_TRANSACTION_TIMEOUT)`
  (`postgres.c:3491-3500`). Spock never sets `transaction_timeout` for apply,
  so a value from `postgresql.conf` or `ALTER DATABASE` applies. FATAL skips
  `PG_CATCH` entirely, so the classifier never sees it; the worker exits with
  the shmem marker still set, and the resent transaction is then replayed under
  the policy (see `exception-replay-only-after-recorded-error`). Not a 57014
  issue but the same outcome class.
- **Not reachable in apply:** `statement_timeout` (armed only by
  `start_xact_command` in `postgres.c:2814`), `idle_in_transaction_session_timeout`
  (armed only in `PostgresMain`'s idle loop), client-connection checks (need
  `MyProcPort`). `pg_terminate_backend` sends SIGTERM, which Spock replaces
  with `handle_sigterm` (`src/spock_worker.c:83-93`, only sets
  `got_SIGTERM`), so 57P01 never comes from it; the loop exits cleanly.
- 55P03 (`lock_timeout`) and 40P01 are already retried.

Effect on this property: none on the invariant. The SUT-side `Unreachable`
should keep separate messages for 57014 and 40001 (both reach `PG_CATCH`). The
25P04 FATAL cannot be asserted in `PG_CATCH`; it is caught by the stale-marker
`Unreachable` in `exception-replay-only-after-recorded-error`.

### Investigation Log

#### Is 57014 handled anywhere in the classifier?

- Examined: `src/spock_apply.c:3867-4133` (full `PG_CATCH`),
  `clear_transient_exception_state` `:418-436`,
  `prepare_transient_error_retry` `:443-456`.
- Found: allow-list is 08xxx subset, 57P01/57P02/57P03, 40P01, 55P03,
  class 53. No reference to `ERRCODE_QUERY_CANCELED`.
- Not found: any SIGINT handler override in Spock workers.
- Conclusion: gap present in code; intent `(needs human input)`.

#### Are there other CHECK_FOR_INTERRUPTS-raised codes reachable from outside?

- Examined: PG 18.3 `src/backend/tcop/postgres.c:3440-3500` (`ProcessInterrupts`
  cancel and transaction-timeout branches), `:2814` (`enable_statement_timeout`
  caller), `:4578-4595` (idle-in-transaction arming);
  `src/backend/access/transam/xact.c:2238` (transaction timeout armed in
  `StartTransaction`); `src/backend/utils/init/postinit.c:755-770` (timeouts
  registered for all non-bootstrap backends); `src/backend/postmaster/bgworker.c:756-758`
  (SIGINT -> `StatementCancelHandler`); Spock `src/spock_worker.c:83-93,339`,
  `src/spock_readonly.c:49-81`; grep for `transaction_timeout|statement_timeout|lock_timeout`
  in `src/` (only sync-worker libpq sessions set them).
- Found: 57014 (cancel), 40001 (terminate_active_transactions, on a primary),
  and FATAL 25P04 (transaction_timeout, PG 17+) are all reachable from outside.
  Statement and idle timeouts are not armed in a bgworker. SIGTERM is handled
  by Spock and never becomes 57P01.
- Not found: nothing else that raises from `CHECK_FOR_INTERRUPTS` in an apply
  worker on a primary.
- Conclusion: resolved. One extra code does not cover the gap; 25P04 is a
  FATAL that bypasses the classifier altogether.

#### Is 57014 meant to be a data fault?

- Examined: `PG_CATCH` comments in `src/spock_apply.c:3870-3990` (connection,
  deadlock/lock-timeout and class-53 blocks), `docs/spock_release_notes.md`
  (transient-error fixes), `docs/configuring.md:160-185`
  (`spock.exception_behaviour`), `docs/troubleshooting.md`, git log of the
  classifier commits.
- Found: the comments define the replay path as "for permanent data faults"
  and list the reason each transient class is retried ("no fault of the
  replicated data"); a cancel fits that description. No comment, doc or commit
  mentions query cancel of an apply worker either way.
- Not found: any statement of intent for 57014.
- Conclusion: `(needs human input)`. The code gap is confirmed; only the
  maintainers can say whether cancel is supposed to be retried.
