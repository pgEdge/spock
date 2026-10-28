# sub-disable-enable-cycle-loses-and-duplicates-nothing

## Why this property

Operators (and ZODAN, and `sub_alter_*` functions) stop and restart apply
workers on a live cluster all the time. Every one of those calls goes through
`alter_subscription()` (`src/spock_node.c:~1124-1214`), which ends with
`spock_subscription_changed(sub->id, true)`. At COMMIT,
`signal_worker_xact_callback` (`src/spock_worker.c:~679-740`) SIGTERMs the
running apply worker (`item->kill`). So `sub_disable`, `sub_enable`,
`sub_alter_interface`, `sub_alter_options` and friends all kill the worker at
an arbitrary point in its stream, including in the middle of a remote
transaction. `sub_disable(immediate := true)` additionally kills it
immediately (`src/spock_functions.c:872-904`), still before the catalog change
commits.

Two past fixes are in exactly this lifecycle path:

- `ed0a9945` "Fix spurious SUB_DISABLE on mid-transaction worker restart":
  `handle_begin()` stamps the shmem exception marker `commit_lsn` on every
  BEGIN; a SIGTERM mid-transaction left it set, the retransmitted transaction
  matched it and was replayed under the exception policy (disabled the sub
  under SUB_DISABLE, would discard under TRANSDISCARD). Fix: `apply_work()`
  calls `clear_transient_exception_state("subscription worker restart")` when
  it falls out on `got_SIGTERM` (`src/spock_apply.c:~4140-4155`).
- `db380dd8` / `f16a004a` (TAP 105) "Fix SUB_DISABLE reconnect
  retransmission": same shape for connection-class errors after BEGIN.

Validated by reading the code at HEAD: the clearing exists, but it is a no-op
when `MyApplyWorker->use_try_block` or `xact_had_exception` is set
(`clear_transient_exception_state`, `src/spock_apply.c:418-436`), so a
SIGTERM during an in-process exception replay keeps the marker. That is
correct for a genuine failure. The property is that the operator lifecycle
(disable, enable, alter) never itself causes loss, duplication or an
exception row.

## Code path

- `spock_alter_subscription_disable/enable` -> `alter_subscription` ->
  `spock_subscription_changed(..., kill=true)`.
- Worker: SIGTERM -> `handle_sigterm` sets `got_SIGTERM` -> inner loop
  `break` (`src/spock_apply.c:3597`) -> outer `while (!got_SIGTERM)` exits ->
  marker cleared if in a remote txn -> `PQfinish` -> `proc_exit(0)`
  (`spock_apply_main`, `:4790-4798`).
- `before_shmem_exit` LIFO: `spock_apply_worker_shmem_exit` (`:2305-2325`)
  clears `replorigin_session_origin*` **before** `ShutdownPostgres` aborts the
  open transaction, so the abort does not advance the origin. This callback is
  only registered from `spock_apply_worker_attach()` at the top of
  `apply_work()` (`:3431`, `:2298/2367`); a worker that exits before that has
  no open remote transaction.
- Clean exit: `spock_worker_detach(crash=false)` resets slot to NONE and does
  not latch the manager, so re-enable restarts within the manager's next tick
  (<= `restart_delay_default`, 5 s). Enable itself latches the manager at
  COMMIT.
- Re-enable: manager registers a new worker; it resumes from
  `replorigin_session_get_progress()`; provider starts at
  max(origin, slot `confirmed_flush`).

## Failure scenarios worth exploring

1. SIGTERM lands after BEGIN, before COMMIT of a large remote txn. Expected:
   marker cleared, abort does not move origin, retransmission applies once.
2. SIGTERM lands while `handle_commit()` is between `CommitTransactionCommand`
   and the next message; feedback already sent or not. Expected: no resend of
   a committed txn beyond what origin dedup handles.
3. `sub_disable` while the worker is in in-process replay of a real data
   error: marker kept on purpose; on enable the txn is replayed under policy.
   Only a valid outcome if a real data error existed (scope: the conflict-free
   workload never has one).
4. `sub_disable` while the worker is blocked in a lock wait (SIGTERM not seen)
   -> worker keeps going, commits, then exits. Fine, but check no hang.
5. Rapid disable/enable/disable where enable commits while the old worker is
   still exiting: manager sees `spock_worker_running(apply)` true and skips;
   next tick starts the new one. Check that two workers never run for one sub
   (would collide on `replorigin_session_setup` -> ERROR 55006 "already active",
   which is not on the transient list -> data-exception path?). Open question.
6. `sub_disable` during initial sync (add_node Phase 5 sub on n4): sync code
   checks `got_SIGTERM` only in cleanup and `wait_for_sync_status_change`, so
   COPY runs to completion; then the worker exits. See
   `initial-sync-ends-ready-or-visibly-disabled`.

## Invariant and assertions

- Workload (Always, at quiescence after the last enable): for every
  `(origin_node, seq)` ledger row committed on its origin, each other node
  holds exactly one copy; delta-apply counter totals equal committed
  increments; `spock.exception_log` has no rows created during the run (the
  workload is conflict-free for this check); every subscription the workload
  left enabled has `sub_enabled = true`.
- Why Always: loss or a duplicate after a disable/enable cycle is never
  acceptable; there is no "sometimes".
- SUT-side (missing, no existing assertions): `Sometimes(in_remote_transaction)`
  with message "apply worker SIGTERM landed inside a remote transaction" at the
  `if (got_SIGTERM) clear_transient_exception_state(...)` site in
  `apply_work()`. This shows Antithesis actually reached the dangerous timing;
  without it a green run means little.
- SUT-side (missing): `Reachable("apply worker exited on SIGTERM during exception replay")`
  when `got_SIGTERM && MyApplyWorker->use_try_block` at the same site, to
  confirm the kept-marker branch is exercised in the conflict variant only.

## Fault requirements

- Workload-driven lifecycle ops: random `sub_disable(name, immediate)`,
  `sub_enable`, `sub_alter_interface` to the same DSN, on random subs, while
  all three nodes write. Large transactions (thousands of rows) widen the
  mid-transaction window.
- Thread pausing / CPU modulation to move SIGTERM delivery around.
- Network faults so some cycles coincide with reconnects.
- Node termination is not required (and kill -9 tests a different path, L1).

## Findings from open-question investigation (HEAD 69d9228f, code read, not run)

- **A replacement worker can start while the old one still holds the origin
  session, and it is harmless.** Exit order of the old worker:
  `before_shmem_exit` callbacks run LIFO — `spock_apply_worker_shmem_exit`
  (resets the session variables, does not release the origin slot),
  `ShutdownPostgres` (aborts the transaction; abort does not release the
  session origin), then `spock_worker_on_exit` (frees the Spock worker slot,
  `proc = NULL`). Only after that do `on_shmem_exit` callbacks run, including
  PG's `ReplicationOriginExitCleanup`, registered with `on_shmem_exit` in
  `replorigin_session_setup` (PG 17 `src/backend/replication/logical/origin.c:1055-1106`;
  no Spock patch touches `origin.c`). A new worker registered in that gap
  calls `replorigin_session_setup` in `spock_apply_main`
  (`src/spock_apply.c:~4749`) before `apply_work`'s PG_TRY and before any
  remote BEGIN, so it exits with a plain ERROR (55006), writes nothing to
  `spock.exception_log`, and is restarted after `restart_delay_default`.
  The gap is short (the new process still has to fork and run InitPostgres),
  but thread pausing can widen it. Scenario 5 is therefore a restart blip,
  not a loss/duplication path; the invariant needs no exception for it.
- **`immediate` on `sub_enable` does nothing beyond refusing to run inside a
  transaction block** (`src/spock_functions.c:923-932`).

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit CW2, implementability CW6); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 (admin-churn phase) · Faults: admin churn, partition, thread pause

- "Empty `exception_log`" changed to "no rows outside the expected-exception registry".

## Implementation (2026-10-28)

- Template `main`, so the existing ledger writer, barriers and ledger
  checks are reused; the subscription changes are a second lifecycle
  disturbance next to graceful restarts.
- `test/v1/main/parallel_driver_sub_cycle.py`: runs in a per-timeline share
  {0, 30, 100}% of its calls, picks a live subscription on a random mesh
  node (one driver per subscription, `flock`), watches up to {0, 2, 10} s
  for its apply worker (`application_name = 'spock apply <dboid>:<subid>'`)
  to hold a transaction, then does one of:
  - `sub_disable(sub, immediate)`, wait {0, 1, 5, 30} s, `sub_enable(sub)`
    (retried for 120 s);
  - `sub_alter_interface` to a second interface of the origin with the same
    DSN, created on first use, alternating back on the next call (the same
    interface returns false without any change).
- `helper_subcycle.py`: a disabled subscription is recorded before
  `sub_disable` and the record removed after `sub_enable`. The eventually
  command terminates the driver's sessions (so a `sub_disable` in flight
  cannot commit later), re-enables recorded subscriptions, then runs the
  barriers. A disabled subscription with no record is not the driver's.
- Checks (`eventually_mesh_barriers.py`), in timelines with at least one
  change issued and no crash recovery on any mesh node: every subscription
  enabled (and every recorded one re-enabled), no `insert_exists` on the
  ledger, no ledger `exception_log` row, same ledger rows on every node.
- SUT-side `Sometimes("apply worker SIGTERM landed inside a remote
  transaction")` evaluated with `in_remote_transaction` where `apply_work()`
  clears transient state on `got_SIGTERM`. Postmaster shutdown SIGTERMs
  (graceful restarts) reach it too.
- Local check: 8 changes of all three kinds under writes on all nodes gave
  91323 identical ledger rows per node and every Always held; a
  subscription left disabled with a record was re-enabled by the eventually
  command.
- Not yet: delta counters, the `use_try_block` Reachable (needs the
  conflict variant), other `sub_alter_*` calls.

## Open questions

- None open. (Checked against the PG 17 source tree at `~/dev/pg/postgresql`;
  the PG 18 tree was not available locally, so PG 18's exit order is assumed
  to be the same.)

### Investigation Log

#### Can a replacement worker start while the old one still holds the origin session?

- Examined: `src/spock_worker.c` attach/detach and callback registration
  order, `src/spock_manager.c` `manage_apply_workers`, `src/spock_apply.c`
  `spock_apply_main` (`replorigin_session_setup` at ~4750, outside PG_TRY).
- Found: slot freed in a `before_shmem_exit` callback; restart check uses
  `spock_worker_running` (proc != NULL); setup error is outside PG_TRY.
- Not found: exact point where stock PG releases the session origin on exit
  (assumed `on_shmem_exit` `ReplicationOriginExitCleanup`; not read in the
  patched tree).
- Update: read PG 17 `origin.c` — `ReplicationOriginExitCleanup` is an
  `on_shmem_exit` callback, so it runs after every `before_shmem_exit`
  callback, including Spock's slot release. Checked `patches/15-19`: none
  touch `origin.c`. `replorigin_session_setup` is outside PG_TRY in
  `spock_apply_main`.
- Conclusion: resolved. The gap exists; a new worker that lands in it fails
  before its first BEGIN with a plain ERROR and is retried. No data effect, no
  exception_log row.

#### Is the immediate flag on sub_enable meaningful?

- Examined: `spock_alter_subscription_enable` (`src/spock_functions.c:907-935`).
- Found: `immediate` only raises an error if called inside a transaction
  block.
- Conclusion: resolved; no effect on the property.
