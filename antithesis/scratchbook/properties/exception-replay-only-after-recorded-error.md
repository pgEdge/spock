# exception-replay-only-after-recorded-error

## Why this property

The shmem exception marker (`exception_log_ptr[]`, keyed by subscription
name) is how a restarted apply worker decides that the first transaction it
receives "failed last time" and must be replayed under
`spock.exception_behaviour` (`handle_begin`, `src/spock_apply.c:~661-860`,
case 4: `exception_log->commit_lsn == commit_lsn` ->
`use_try_block = true`). `handle_begin()` stamps `commit_lsn` on **every**
BEGIN, so the marker is only meaningful if every non-failure exit path clears
it. Bug history shows that is where bugs keep appearing: `ed0a9945` (SIGTERM
mid-txn), `db380dd8`/`f16a004a` (connection error mid-txn, TAP 105),
`f3d4935e` (deadlock / lock timeout / class 53), `acf6cdae` (stale
`use_try_block`), `b8993cb5` (prefix match), `0f7f068b` (off-by-one).
Each one turned a lifecycle event (restart, reconnect) into a discarded or
disabled transaction.

## Key observation (code-checked at HEAD)

A genuine first failure always goes through `apply_work()`'s PG_CATCH
"caught initial exception" branch (`src/spock_apply.c:~4065-4100`), which
writes `initial_error_message` into the same marker before replay. Every path
that resolves the failure clears the whole entry with
`clear_exception_log_entry()` (`:387-395`), which empties the message too.
So: **when case 4 matches, a non-empty `initial_error_message` must be
present**. A match with an empty message means the marker came from a plain
BEGIN of a transaction that never failed, i.e. a lifecycle exit skipped the
clear. Known remaining paths that can do that:

- FATAL mid-transaction (bypasses PG_CATCH and the `got_SIGTERM` clear):
  `handle_message` "incorrect spock message" (`:~2928`), readonly FATAL in
  `replication_handler` (`:2981-2983`). Note: with default (non slot-group)
  names the readonly FATAL looks unreachable: `spock.readonly` is
  re-read only by `ProcessConfigFile` at `:3503`, `:3600` (both before the
  `READONLY_ALL` check at `:3610`) and inside `wait_for_previous_transaction`
  (`:316`, dormant unless slot groups). So a reload cannot land between the
  check and the handler. Treat the readonly FATAL as an `Unreachable` target.
- A table-sync worker in CATCHUP runs `apply_work` with the same
  `MySubscription->name` and so writes the same marker (lead L15). If it exits
  after stamping a commit_lsn the apply worker later receives as its first
  BEGIN after a restart, case 4 matches with no message.
- Any future exit path added without the clear.

SIGKILL / postmaster crash-restart wipes shmem and is safe for this property.

## Invariant and assertions

- SUT-side (missing, no existing assertions):
  `Unreachable("exception replay entered without a recorded initial error")`
  in `handle_begin()` case 4, guarded by
  `exception_log->initial_error_message[0] == '\0'`. Unreachable fits: this
  state is never valid.
- SUT-side (missing): `Unreachable("apply worker readonly FATAL in replication_handler")`
  at `src/spock_apply.c:2982`. If it fires, it is both a lifecycle surprise and
  a stale-marker source.
- SUT-side (missing): `Reachable("exception replay entered with recorded initial error")`
  in the same branch when the message is non-empty — only in a run variant
  that injects a real data error, to prove the branch is covered.
- Workload cross-check (Always, conflict-free variant): `spock.exception_log`
  stays empty and no sub is disabled.

## Antithesis angle

Kill/terminate/cancel apply and sync workers, partition providers, and toggle
`spock.readonly` at random points; sub_resync_table in a later variant to
reach the sync-worker overlap (L15).

## Fault requirements

Graceful exits (SIGTERM / `pg_terminate_backend`) and network faults are the
main drivers. Postmaster kill does not reach this property (shmem wiped).

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (implementability (property finding)); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 · Faults: worker exit, partition, readonly toggles

- Evaluation note (2026-10-13): set-up step for the `transaction_timeout` source: `ALTER DATABASE ... SET transaction_timeout` (PG17+ arms it in `StartTransaction`, which the apply worker uses), then restart the apply workers so they pick it up at connect.

## Open questions

- Does a table-sync worker's last stamped commit_lsn ever equal the apply
  worker's first BEGIN after a restart? `(partial: normally the sync worker
  stops on the transaction the apply worker last committed, which the apply
  worker never receives again; only when the sync stream's first transaction
  already ends past replay_stop_lsn does it stamp a transaction the apply
  worker has not seen; needs sub_resync_table in the workload)`

## Resolved: other FATAL / proc_exit sites reachable mid-transaction

Checked against PG 18.3 and Spock HEAD. Each FATAL below skips `PG_CATCH` and
the `got_SIGTERM` clear (`src/spock_apply.c:4150-4157`), and
`spock_apply_worker_shmem_exit` (`:2305-2325`) resets only the origin, not the
marker. So each one is a stale-marker source the `Unreachable` targets. No
change to the property; they widen what the workload can do to reach it:

- **`transaction_timeout` (PG 17+), FATAL 25P04.** Armed in every
  `StartTransaction()` (PG18 `xact.c:2238`) for bgworkers too; raised as FATAL
  in `ProcessInterrupts` (`postgres.c:3491-3500`). Spock does not override it
  for apply. A run variant with `ALTER DATABASE ... SET transaction_timeout`
  shorter than the largest remote transaction reaches this path on every large
  transaction (and may loop, since the replayed attempt is timed too).
- **Recovery-conflict FATAL 40001 inside a subtransaction**, from
  `spock.terminate_active_transactions()` on a primary (PG18
  `postgres.c:3142-3230`). Apply opens subtransactions for delta-apply in all
  modes (`src/spock_apply_heap.c:722`) and per row in DISCARD replay. See
  `terminate-active-transactions-never-discards-inbound`.
- **`elog(FATAL, "incorrect spock message")`** (`:2928`): effectively
  unreachable. The output plugin drops every message whose prefix is not
  Spock's (`src/spock_output_plugin.c:755-756`), and a decoded transactional
  message always has a valid LSN. Keep it as an `Unreachable` target.
- **Readonly FATAL in `replication_handler`** (`:2981-2983`): confirmed
  unreachable outside slot groups (config is re-read only at `:3503`/`:3600`,
  both before the `READONLY_ALL` check at `:3610`). Note: `docs/managing/read_only.md`
  says that in `all` mode "each worker raises a FATAL and exits"; the code
  instead breaks out of the inner loop at `:3610-3630` and keeps the worker
  alive, idle, possibly inside an open remote transaction. Docs and code
  disagree; that belongs to a readonly property, not this one.
- **`proc_exit(1)` on postmaster death** (`:3513`, `:3626`) and the sync
  worker's `proc_exit(0)` after SYNCDONE (`:1238`): the first wipes shmem
  (safe); the second is the L15 case in the open question above.
- PG-side FATALs not reachable in apply on a primary: idle-in-transaction and
  idle-session timeouts (armed only in `PostgresMain`), statement timeout
  (armed only in `start_xact_command`). `pg_terminate_backend` sends SIGTERM,
  which Spock handles gracefully (`src/spock_worker.c:83-93`).

### Investigation Log

#### Are there other FATAL/proc_exit sites reachable mid-transaction in apply?

- Examined: grep for `FATAL|proc_exit` in `src/spock_apply.c`,
  `src/spock_apply_heap.c`, `src/spock_conflict.c`, `src/spock_common.c`,
  `src/spock_proto_native.c`, `src/spock_exception_handler.c`;
  `src/spock_apply.c:2290-2325, 2915-2985, 3440-3630, 4140-4160`;
  `src/spock_output_plugin.c:745-775`; PG 18.3 `postgres.c:3140-3230,
  3440-3500, 2814, 4578-4595`, `xact.c:2238`, `postinit.c:755-770`;
  `docs/managing/read_only.md`.
- Found: transaction_timeout FATAL (25P04) and recovery-conflict FATAL (40001
  in a subtransaction) are reachable from outside; "incorrect spock message"
  and the readonly FATAL are not; postmaster-death exits are safe. The marker
  is not cleared on any FATAL exit.
- Not found: any other FATAL in Spock's apply path.
- Conclusion: resolved. Two new stale-marker sources; property unchanged.
  Side finding: read_only.md describes a FATAL in `all` mode that the code no
  longer raises.

#### Does a table-sync worker's last stamped commit_lsn equal the apply worker's first BEGIN after a restart?

- Examined: `src/spock_apply.c:1186-1240` (`replay_stop_lsn` stop and
  `proc_exit(0)` in `handle_commit`), `:4510-4560` (apply worker hands its
  origin LSN to the sync worker as `replay_stop_lsn`, then waits for
  SYNCDONE), `:690-880` (slot lookup by subscription name in `handle_begin`),
  `src/spock_output_plugin.c:521-600` (BEGIN is sent for every decoded
  transaction; row filtering happens later).
- Found: the sync worker sees the same transactions as the apply worker and
  stops on the first one whose `end_lsn >= replay_stop_lsn`. Usually that is
  the transaction the apply worker last committed (its origin is that
  `end_lsn`), which the apply worker will not receive again. If the sync
  slot's stream begins past that point, the sync worker's first transaction
  is one the apply worker has not applied, and its `commit_lsn` stays in the
  shared marker with an empty message. The apply worker only checks the
  marker on its first BEGIN after a start or an exception, so a match also
  needs an apply restart before that transaction.
- Not found: whether the sync slot can start past `replay_stop_lsn` in
  practice (depends on resync slot creation timing).
- Conclusion: partial; needs `sub_resync_table` in a run.
