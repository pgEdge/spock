---
sut_path: /home/msharp/dev/pgedgea/spock
commit: 69d9228f5df363761dc3ae6eebf7e2fcfe49b8e5
updated: 2026-10-13
external_references: []
---

# Property discovery, focus 9: Idempotency and Replay

Lens: duplicate handling, at-least-once delivery, reprocessing safety.

Spock delivers each remote transaction **at least once**: resume position is
the subscription's replication origin and the provider slot's
`confirmed_flush`, and several paths can re-send or re-run a transaction. Of
the operations Spock applies, only plain-row INSERT/UPDATE are close to
idempotent (same origin + equal commit ts -> apply again). Delta-apply
columns, queued DDL, and plain rows that another origin changed in between
are not.

Already covered by other agents' evidence files, and therefore **not
repeated here** (they are the main outcome oracles for this lens and should
be read together with this file):

- `ledger-row-applied-exactly-once-per-peer` (L1 duplicate apply after a
  subscriber crash; audit-trigger oracle).
- `delta-counter-equals-committed-increments` (S12, delta double counting).
- `exception-replay-only-after-recorded-error` (stale shmem marker).
- `lock-contention-retried-not-discarded` (deadlock / lock-timeout retry).
- `sub-disable-enable-cycle-loses-and-duplicates-nothing`,
  `remote-transaction-all-or-nothing-per-node`.

The properties below are the ones this lens adds.

## Category: Redelivery consequences beyond counters

### causally-deleted-row-stays-deleted — A row deleted after its insert reached every node never comes back

| | |
|---|---|
| **Type** | Safety |
| **Property** | A row inserted on node A, seen on every node, and then deleted on a different node B is absent on every node after quiescence, across subscriber crashes and restarts. |
| **Invariant** | Workload `Always(no deleted id is present on any node)` checked after faults heal and every ordered pair passes a sync_event barrier. Keys are `(node, seq)` so there are no insert/insert conflicts, and nothing else writes these rows, which keeps the check clear of the documented no-tombstone cases. `Always` because a single resurrected row is a violation. |
| **Antithesis Angle** | Needs kill -9 of the subscriber S between checkpoints (large `checkpoint_timeout`). If the redo bug (L1) is real, S's A->S origin rewinds and A re-sends the INSERT. Whether B's DELETE is re-sent, and in which order the two subscriptions re-apply, is a race across two apply workers that Antithesis can explore. Network latency between B and S widens it. |
| **Why It Matters** | The comment on `maybe_advance_forwarded_origin` (`src/spock_apply.c:5150-5165`) assumes "last_update_wins handles the duplicate". It does not here: the re-sent INSERT finds no row (deleted by B) and inserts it (`spock_apply_heap_insert`, `src/spock_apply_heap.c:837-930`), with no conflict and no exception row. The result is permanent divergence that looks like deleted data coming back on one node. |

**Open Questions:**

- Does stock redo in the patched PG18 tree advance `XLogRecGetOrigin(record)` (the node id) rather than the subscription origin?
- How wide is the "applied but not yet confirmed" window during idle periods (feedback only on batches and keepalives)?
- Is at-least-once delivery on direct subscriptions accepted by the team? `(needs human input)`

Confidence: medium (mechanism code-checked; depends on L1 being real on PG18)
Evidence file: properties/causally-deleted-row-stays-deleted.md

### redelivered-ddl-not-turned-into-exception — Re-sent DDL does not produce exception rows or disable a subscription

| | |
|---|---|
| **Type** | Safety |
| **Property** | A replicated DDL transaction that reaches a subscriber a second time does not create an `exception_log` row, disable the subscription, or drop data. |
| **Invariant** | Workload `Always`: after quiescence, no `spock.exception_log` row has `ddl_statement` set with an "already exists" / "does not exist" error (42P07, 42701, 42710, 42P01, 42704), and no subscription is disabled unless the workload disabled it. The workload runs DDL only in quiesced phases, so such an error can only come from redelivery. Suggested SUT-side `Unreachable("replicated DDL failed because its object already exists")` in the queued-SQL exception path (missing). |
| **Antithesis Angle** | Kill a subscriber postmaster shortly after a DDL phase's barrier (the barrier reads the in-memory origin, which is what rewinds). Run both `transdiscard` and `sub_disable` variants. |
| **Why It Matters** | `handle_insert` -> `handle_queued_message` -> `spock_execute_sql_command` (`src/spock_apply.c:1715-1745, 2754-2898, 4285`) re-runs queued SQL with no record of what already ran; `spock.queue` has no primary key (`sql/spock--6.0.0.sql:598-604`). Any redelivery (L1, L19, add_node overlap) turns into a 42-class error, which is not on the transient list. Under `sub_disable` a healthy subscription is disabled and needs an operator; under `transdiscard` the exception log reports a failure that did not happen. |

**Open Questions:**

- Is DDL redelivery considered possible, and should apply record executed queue entries or prevent redelivery? `(needs human input)`
- Should "already exists" on queued DDL count as already applied? (Would also hide real schema drift.)

Confidence: medium (re-execution is code-checked; frequency depends on L1)
Evidence file: properties/redelivered-ddl-not-turned-into-exception.md

## Category: Exception replay must not re-run or skip

### exception-replay-never-reruns-committed-transaction — In-process replay never replays a transaction the worker already committed

| | |
|---|---|
| **Type** | Safety |
| **Property** | The in-process exception replay only replays a remote transaction that this worker has not committed. |
| **Invariant** | SUT-side `Unreachable("exception replay entered for a transaction this worker already committed")` (missing): track the BEGIN `commit_lsn` of the last committed transaction right after `CommitTransactionCommand()` in `handle_commit`; in `handle_begin` case 4 (`use_try_block = true`) fire if the incoming `commit_lsn` equals it. `Unreachable` because re-running a committed transaction is never valid. |
| **Antithesis Angle** | `handle_commit` commits at `src/spock_apply.c:1058` but resets the replay queue only at `:1248`. In between, `maybe_pause_for_slot_creation()` (`:1186`) sleeps up to `spock.pause_timeout` during add_node and checks interrupts, so `pg_cancel_backend` on the apply worker raises 57014 there; `maybe_advance_forwarded_origin()` (`:1137`) can raise 55006 (2948d567). Either error takes the first-exception branch (`:4065-4128`), and the queue still holds the committed transaction, whose `commit_lsn` still matches the shmem marker. Needs a test command that cancels apply workers at random, ideally while the n4 add_node driver runs. |
| **Why It Matters** | Under `discard` every row is applied twice (insert_exists updates, delta columns double-count). Under `transdiscard` the exception log claims rows were discarded that were in fact applied, which corrupts the "every difference is explained" oracle. Under `sub_disable` a good subscription is disabled. The guard proposed in `exception-replay-only-after-recorded-error` does not catch this, because an initial error message is recorded. |

**Open Questions:**

- Is a query cancel on an apply worker a supported operator action? (The ordering bug stands either way.) `(needs human input)`
- Does `ConditionVariableTimedSleep` in the patched PG18 tree still call `CHECK_FOR_INTERRUPTS()`?

Confidence: medium (path code-checked end to end; trigger needs a cancel or a cascade race)
Evidence file: properties/exception-replay-never-reruns-committed-transaction.md

### interrupted-exception-replay-resends-transaction — A data-error transaction whose replay is interrupted is re-sent, not silently skipped

| | |
|---|---|
| **Type** | Safety |
| **Property** | If the in-process replay of a failed remote transaction T is cut short by a worker exit or crash, T is delivered again and ends in exactly one documented outcome on the subscriber (discarded with `exception_log` rows, or subscription disabled), never silently missing. |
| **Invariant** | Workload `Always`: for each deliberately poisoned transaction (a local-only CHECK on one subscriber makes it fail there), on that subscriber the transaction's rows are absent and `exception_log` has at least one row with its `remote_xid` (`transdiscard`), or the subscription is disabled and the rows appear once after fix + `sub_enable` (`sub_disable`). Supporting SUT-side `Sometimes("apply worker exited during in-process exception replay")` and `Sometimes("exception replay read entries from the spill file")` (missing) prove the state is reached. |
| **Antithesis Angle** | `AbortOutOfAnyTransaction()` in the first-exception branch (`src/spock_apply.c:4065`) runs with the origin still set, so the shared origin moves to T's `commit_lsn` before replay. Whether T is re-sent then rests on the strict decoding skip test (`commit_lsn < start`) and on feedback never passing T. Interrupt the replay with `pg_terminate_backend`, partitions, `apply_idle_timeout`, or kill -9 (control); use large transactions to hit the spill-file path. |
| **Why It Matters** | Spock's own comment (`src/spock_apply.c:2305-2325`) says such an abort-time advance "silently skips that txn on reconnect" and fixes it only for the worker-exit path. If the boundary is off by one anywhere, the result is silent loss with no exception row, which is the worst outcome under the default policy. |

**Open Questions:**

- Does `RecordTransactionAbort` in PG18 advance the session origin on abort? `(partial: Spock's comment says yes; not re-read in the PG18 tree)`
- Is the PG18 skip test still strict (`<`)?
- Is the `sub_disable` resume-at-`commit_lsn` design meant to rely on the same strict test? `(needs human input)`

Confidence: medium (abort-time advance code-checked; the outcome rests on PG internals)
Evidence file: properties/interrupted-exception-replay-resends-transaction.md

## Category: Resume-position rules

### feedback-never-confirms-past-inflight-transaction — Flush feedback never tells the provider to skip an unapplied transaction

| | |
|---|---|
| **Type** | Safety |
| **Property** | While a worker is inside a remote transaction it has not committed, the flush position it reports to the provider is never beyond that transaction's commit record start. |
| **Invariant** | SUT-side `Always("feedback flush position does not pass the in-flight remote transaction")` (missing) in `send_feedback` (`src/spock_apply.c:3237-3300`): `!in_remote_transaction || flushpos <= replorigin_session_origin_lsn`. Companion `Sometimes("feedback sent while inside a remote transaction")` (missing) so a pass is not vacuous. `Always` because every feedback message must satisfy it. |
| **Antithesis Angle** | With no outstanding local commits, `send_feedback` reports `flush = recvpos`; on keepalives that is the walsender's `endpos`, sent unconditionally even mid-transaction and during replay (`:3767`). Large transactions, congestion and thread pausing make keepalives interleave with a transaction's changes; exception replay exercises the replay-mode path. |
| **Why It Matters** | The provider resumes at max(start, `confirmed_flush`) and skips commits strictly below it. A flush report past an unapplied transaction makes the next reconnect or restart lose it silently. This function already has one known defect (L9, sync-standby hold overwritten). |

**Open Questions:**

- Are the late `sentPtr` update and the strict skip test unchanged in patched PG18?
- Is unconditional keepalive feedback during `sub_disable` replay intended? `(needs human input)`

Confidence: medium (holds by reasoning about stock walsender; the assertion is a guard)
Evidence file: properties/feedback-never-confirms-past-inflight-transaction.md

### sync-event-barrier-stable-across-crash — A reached sync_event barrier is reached again after a subscriber crash

| | |
|---|---|
| **Type** | Liveness |
| **Property** | After `wait_for_sync_event(P, L)` returned true on S, a subscriber crash followed by a quiet period (no new writes on P) still lets the same call return true within a bound. |
| **Invariant** | Workload `Always(true within timeout)` evaluated once at the end of a quiet window after S restarted, for the newest marker L that had been reached before the crash; timeout at least `apply_idle_timeout` plus restart delays. `Always` on that single end-of-window evaluation expresses the bounded liveness. |
| **Antithesis Angle** | Kill S after a marker is reached and before a checkpoint; keep P quiet afterwards. The non-transactional marker and empty transactions advance the origin with `replorigin_session_advance` only, no WAL (`src/spock_apply.c:1113-1131, 2955-2964`); feedback has already moved `confirmed_flush` past L, so the marker is not re-sent and `remote_lsn` stays below L until P commits something new. |
| **Why It Matters** | `docs/monitoring/spock_sync_event.md` presents the barrier as the way to know changes were applied; ZODAN and every convergence oracle use it. A barrier that silently un-reaches makes re-checks hang until timeout. |

**Open Questions:**

- Is it intended that `remote_lsn` may stay below a previously reached marker after a crash until the next real transaction? `(needs human input)`
- Would a WAL-logged advance for markers be acceptable cost?

Confidence: medium (mechanism code-checked; whether it is a bug is a contract question)
Evidence file: properties/sync-event-barrier-stable-across-crash.md

### forwarded-origin-advance-no-double-apply — Switching from a forwarding subscription to a direct one applies nothing twice

| | |
|---|---|
| **Type** | Safety |
| **Property** | In a cascade (C subscribes to B with `forward_origins='{all}'` and holds a disabled direct subscription to A), enabling the direct A->C subscription neither re-applies A transactions C already got through B nor skips any. |
| **Invariant** | Workload `AlwaysOrUnreachable` on C after the switch: delta counters equal committed increments and each ledger row has exactly one apply-audit row. `AlwaysOrUnreachable` because only runs that reach the switch evaluate it. Suggested SUT-side `Reachable("forwarded origin advanced for a pre-created subscription")` (missing). |
| **Antithesis Angle** | Separate cascade test template (forbidden in the v1 mesh). Kill C between the data commit and the separate `replorigin_advance` WAL record in `maybe_advance_forwarded_origin` (`src/spock_apply.c:1137, 5167-5183`); race disable/enable of the two subscriptions to hit 55006 after commit. |
| **Why It Matters** | 401197ab admits at-least-once ("delta-apply idempotency is tracked separately"); no such tracking exists. A crash in the window double-counts delta columns when the direct subscription takes over. |

**Open Questions:**

- Is cascade-then-direct a supported production flow, given ZODAN never sets `forward_origins`? `(needs human input)`
- Should the advance be written inside the data transaction?

Confidence: low (out of v1 topology; mechanism admitted in the commit comment)
Evidence file: properties/forwarded-origin-advance-no-double-apply.md

## Areas examined

- `src/spock_apply.c`: `handle_begin` (shmem marker, `:660-905`),
  `handle_commit` (origin LSN choice, commit, post-commit steps and queue reset
  order, `:912-1262`), `handle_origin` / forwarded-origin resolution
  (`:1277-1360`), `handle_message` sync_event (`:2901-2970`), queued
  DDL/SQL/table-sync/sequence handling (`:2546-2898`), `handle_insert` queue
  branch (`:1715-1745`), `get_flush_position` / `send_feedback`
  (`:3082-3300`), `apply_work` main loop and PG_CATCH classifier
  (`:3398-4133`), replay queue and spill (`:4973-5140`),
  `maybe_advance_forwarded_origin` (`:5150-5183`),
  `spock_apply_worker_shmem_exit` (`:2305-2325`), worker start
  (`:4735-4790`).
- `src/spock_apply_heap.c`: `build_delta_tuple`,
  `spock_handle_conflict_and_apply`, INSERT-exists zero old tuple,
  `spock_apply_heap_insert` (`:500-930`).
- `src/spock_conflict.c`: same-origin shortcut, `get_tuple_origin`,
  `spock_report_conflict` logging rules (`:95-460`).
- `src/spock_progress_recovery.c`: reconcile trusts origin; confirms commit
  records carry the publisher node id (`:120-132, 240-275`).
- `src/spock_exception_handler.c` `spock_disable_subscription`;
  `src/spock_readonly.c` `terminate_active_transactions`;
  `src/spock_node.c` node id generation.
- `sql/spock--6.0.0.sql` (`spock.queue` without PK, `resolutions`,
  `exception_log`, `delta_apply` functions); `samples/Z0DAN/zodan.sql`
  (`forward_origins` never set).
- Commits 401197ab, 2948d567 (messages).
- Other agents' evidence files in `properties/` to avoid duplicates.

Considered and not turned into properties:

- Deadlock / lock-timeout retry re-applying a partial transaction: the whole
  local transaction is aborted on exit and the origin is cleared first
  (`spock_apply_worker_shmem_exit`), so the retry starts clean. Covered by
  `lock-contention-retried-not-discarded`.
- `handle_table_sync` redelivery: skips if a sync status already exists;
  idempotent.
- Sequence `setval` redelivery: re-sets the same value in order; sequences
  are out of scope (S11).
- Provider-only crash: the subscriber passes its origin as the start point,
  which is above the provider's possibly older `confirmed_flush`, so no
  duplicates. Crashing **both** sides widens the L1 window to the provider's
  last slot save; noted for the ledger property, not a new property.
- ZODAN Phase 7 producing duplicates on the new node: possible only if
  `read_peer_progress` reads a progress entry older than the copy snapshot
  (window between `CommitTransactionCommand` and the progress update in
  `handle_commit`, with the "no xid counts as paused" rule, L4b). Very narrow;
  left to the add-node properties.

## Assumptions affecting multiple properties

1. **Stock PG redo/abort origin behaviour holds in patched PG18**: commit
   records carry `replorigin_session_origin` (the node id here), redo advances
   `XLogRecGetOrigin(record)`, and `RecordTransactionAbort` advances the
   session origin when one is set. Affects `causally-deleted-row-stays-deleted`,
   `redelivered-ddl-not-turned-into-exception`,
   `interrupted-exception-replay-resends-transaction`,
   `sync-event-barrier-stable-across-crash`.
2. **Decoding skip test is strict** (`commit ptr < start_decoding_at`) and a
   logical walsender's `sentPtr` (keepalive `endpos`) is updated only after a
   record is fully processed. Affects
   `feedback-never-confirms-past-inflight-transaction` and
   `interrupted-exception-replay-resends-transaction`.
3. **The workload can send query cancels and graceful terminations to Spock
   workers** (test command over SQL). Antithesis node kill alone wipes shared
   memory and masks the in-process replay paths. Affects
   `exception-replay-never-reruns-committed-transaction` and
   `interrupted-exception-replay-resends-transaction`.
4. **Node termination is enabled and PGDATA survives it**, with large
   `checkpoint_timeout`, so redelivery windows are not closed by checkpoints.
   Affects every redelivery property here.
5. **Apply sessions run with `synchronous_commit=off`** (default
   `spock.synchronous_commit=off`), so feedback lags local flush by up to the
   walwriter delay; this is part of what keeps the "applied but not
   confirmed" window open.
