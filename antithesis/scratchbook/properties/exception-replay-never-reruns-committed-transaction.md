# exception-replay-never-reruns-committed-transaction

## What the property says

The in-process exception replay (`apply_work` PG_CATCH "caught initial
exception" -> `apply_replay_queue_start_replay()` -> `goto stream_replay`)
must only replay a remote transaction that this worker has **not** committed.
It must never replay a transaction whose local commit already happened.

## Why it matters

If it does:

- `spock.exception_behaviour = discard`: every row of the already-applied
  transaction is applied a second time, each in its own subtransaction.
  Duplicate INSERTs become `insert_exists` -> UPDATE; delta-apply columns
  double-count (`spock_handle_conflict_and_apply`,
  `src/spock_apply_heap.c:650-690`).
- `transdiscard` (default): the replay is read-only and writes one
  `spock.exception_log` row per change saying it was discarded, but the data
  **was** applied. The exception log, which S2 makes the explanation for every
  inter-node difference, then lies.
- `sub_disable`: the subscription is disabled for a transaction that applied
  fine.

## Mechanism (code-checked at HEAD)

`handle_commit()` (`src/spock_apply.c:912-1262`) runs in this order:

1. `CommitTransactionCommand()` at `:1058` — the remote transaction T is now
   committed locally, and the session origin is advanced to T's `end_lsn`.
2. `maybe_advance_forwarded_origin()` at `:1137` (`replorigin_advance`, can
   raise `ERRCODE_OBJECT_IN_USE`).
3. Progress hash update (`:1140-1180`, Asserts only).
4. `awake_transaction_waiters()` `:1182`.
5. **`maybe_pause_for_slot_creation()` at `:1186`** — while add_node holds
   `SpockCtx->pause_apply`, this sleeps in `ConditionVariableTimedSleep` for up
   to `spock.pause_timeout` (10 s). ConditionVariableTimedSleep runs
   `CHECK_FOR_INTERRUPTS()`, so a pending query cancel (SIGINT,
   `pg_cancel_backend(<apply pid>)`) raises ERROR 57014 here.
6. The `replay_stop_lsn` branch (`:1192-1240`, sync workers in CATCHUP): new
   transaction to set SYNCDONE, `XLogFlush`, `PQfinish`, `proc_exit`.
7. **`apply_replay_queue_reset()` at `:1248`** — only here is T's queued
   messages dropped.

Any ERROR raised in steps 2-6 reaches `apply_work`'s PG_CATCH
(`:3867-4133`). The error is not connection-class, not 40P01/55P03, not class
53 (57014 and 55006 are not on the list), `use_try_block` and
`xact_had_exception` are false (T applied normally), so it takes the
first-exception branch: `AbortOutOfAnyTransaction()` (nothing to abort),
save the message, `apply_replay_queue_start_replay()` with the queue **still
holding T's B..C messages**, `first_begin_at_startup = true`, `goto
stream_replay` with `use_try_block = true`.

Replayed BEGIN of T: `handle_begin` finds the subscription's shmem slot; its
`commit_lsn` was stamped with T's `commit_lsn` by T's own BEGIN (`:877-878`)
and the success path of `handle_commit` does not clear it. So case 4 matches
(`:834`), `use_try_block = true`, and T is replayed under the policy. The
`initial_error_message` is non-empty (the cancel / object-in-use message), so
the guard proposed in `exception-replay-only-after-recorded-error` does not
catch this case.

### Reachable triggers

- **Query cancel during add_node pause** (v1 topology): add_node of n4 sets
  the pause flag on the provider while it creates the slot. Each apply worker
  on that node that commits a transaction then sleeps in step 5. A
  `pg_cancel_backend` on that worker in the window replays T. The window is up
  to `pause_timeout` per paused worker per add_node.
- **Forwarded-origin advance race** (cascade configuration only): 2948d567
  states that `replorigin_advance()` raises `ERRCODE_OBJECT_IN_USE` when
  another worker owns the target origin, and that "normal apply error handling
  then disables the entire forwarding subscription". The fix,
  `enforce_forwarding_exclusivity()` (`src/spock_functions.c:488`), checks
  catalog state, not which workers are still running, so a quick disable of
  one subscription and enable of the other can still race. With TRANSDISCARD
  or DISCARD, the error after commit replays T rather than disabling.
- **Sync worker SYNCDONE update** (step 6): an error in
  `set_table_sync_status` (other than 55P03/40P01) during a table resync
  catch-up replays the last caught-up transaction in the sync worker.

Connection-class and class-53 errors in steps 2-6 rethrow and exit the worker;
the origin was already advanced in memory by the commit, so no replay
(redelivery after a crash is L1, covered elsewhere).

## Assertion

SUT-side, **missing** (no existing assertions):

- Keep a per-process `static XLogRecPtr last_committed_commit_lsn`, set right
  after `CommitTransactionCommand()` in `handle_commit` to the BEGIN
  `commit_lsn` of T.
- In `handle_begin`, where case 4 sets `use_try_block = true`:
  `Unreachable("exception replay entered for a transaction this worker already committed")`
  when `commit_lsn == last_committed_commit_lsn`.

`Unreachable` fits: re-running a committed transaction is never valid.

Workload cross-check (DISCARD variant only): more than one `apply_audit` row
for one ledger row (the trigger-based audit in
`ledger-row-applied-exactly-once-per-peer`), or a delta counter above the
committed sum (`delta-counter-equals-committed-increments`). In TRANSDISCARD runs:
an `exception_log` row whose `remote_commit_ts`/`remote_xid` belongs to a
transaction whose rows are present on that node.

## Antithesis angle

- Needs a cancel source: Antithesis does not send SIGINT to single processes.
  Add a test command that runs `SELECT pg_cancel_backend(pid) FROM
  pg_stat_activity WHERE backend_type LIKE 'spock apply%'` against a random
  node at random times, most usefully while the add_node driver is running.
- Thread pausing / CPU modulation stretches the pause window.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit CW3, implementability (property finding)); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 · Faults: worker exit (cancel) during add_node

- Evaluation note (2026-10-13): the paused state is not visible (the pause sleep uses the same wait event as an idle apply worker), so the trigger is a combined test command: while add_node runs, watch the source's `pg_stat_activity` for a walsender whose `query` shows `CREATE_REPLICATION_SLOT`, then cancel all apply workers on the source. Expect a low hit rate; the SUT-side `Unreachable` is the main check.

## Open questions

- Is a query cancel delivered to an apply worker considered a supported
  operator action? If not, the first trigger reduces to the cascade race. The
  code-level bug (queue reset after the last possible ERROR site) stands
  either way, and the fix is cheap (reset the queue right after commit).
  `(needs human input)`

## Resolved

- **`ConditionVariableTimedSleep` still checks interrupts in the patched PG18
  tree.** `src/backend/storage/lmgr/condition_variable.c:155-195` (PG 18.3,
  Spock patches applied; none touch this file) calls `CHECK_FOR_INTERRUPTS()`
  on every wake-up, after `WaitLatch`. `pg_cancel_backend` sets the latch, so
  a cancel during the add_node pause raises 57014 right away. Bgworkers with a
  database connection keep `StatementCancelHandler` for SIGINT
  (`bgworker.c:756-758`) and the apply worker is not reading a client command
  (`DoingCommandRead` false), so the cancel becomes `ERROR 57014`
  (`postgres.c:3461-3466`). The first trigger is reachable as described.
- Also confirmed: `replorigin_advance()` raises `ERRCODE_OBJECT_IN_USE` when
  another process holds the origin (PG18 `origin.c:964-968`), so the cascade
  trigger's error is real.

### Investigation Log

#### Does ConditionVariableTimedSleep call CHECK_FOR_INTERRUPTS each loop in the patched PG18 tree?

- Examined: PG 18.3 `src/backend/storage/lmgr/condition_variable.c:140-200`;
  `patches/18/*.diff` file lists (no patch touches it);
  `src/backend/postmaster/bgworker.c:756-758`; `src/backend/tcop/postgres.c:3456-3466`;
  Spock `src/spock_apply.c:565-586` (`maybe_pause_for_slot_creation`) and
  `:1060-1262` (`handle_commit` after `CommitTransactionCommand`).
- Found: yes; a cancel lands as ERROR 57014 inside the pause, after T
  committed and before `apply_replay_queue_reset()` at `:1248`.
- Conclusion: resolved.

#### Is a query cancel to an apply worker a supported operator action?

- Examined: classifier comments `src/spock_apply.c:3870-3990`, docs
  (`configuring.md`, `troubleshooting.md`, release notes), add_node docs for
  any warning about cancelling apply workers.
- Found: nothing either way.
- Conclusion: `(needs human input)`; same question as
  `apply-cancel-retried-not-discarded`.
