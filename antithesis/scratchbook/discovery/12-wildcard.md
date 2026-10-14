# 12 — Wildcard: odd, cross-cutting and fragile characteristics of Spock

SUT: `~/dev/pgedgea/spock` @ 69d9228f (main). Everything below is from reading
the tree and its git history. Items marked **Lead** are reasoning from code, not
something I reproduced. Line numbers refer to HEAD.

The common thread: Spock's correctness depends on several things that are true *by
accident of ordering, naming, or process-exit path*, not by construction. Fault
injection (kill, pause, partition, clock skew) is exactly what breaks those accidents.

---

## Findings

### W1. The WAL commit record's origin is the *Spock node id*, not the subscription's replication origin. Crash redo advances the wrong origin. (Lead, high value)

- `handle_origin()` (`src/spock_apply.c:1301-1334`) does
  `replorigin_session_origin = remote_origin_id;` where `remote_origin_id` is the
  16-bit Spock node id (`src/spock_node.c:367-371`, `hash_any(name) & 0xffff`). The
  session itself was set up on the subscription's real origin
  (`replorigin_session_setup(originid)`, `spock_apply.c:4745-4750`).
- At runtime this works: `RecordTransactionCommit` calls
  `replorigin_session_advance()`, which advances the *session* state (the subscription
  origin). But the commit WAL record carries `XLogRecGetOrigin() == node id`.
- In crash recovery, core `xact_redo_commit` calls
  `replorigin_advance(origin_id = node id, ...)` (checked in a PG tree:
  `src/backend/access/transam/xact.c:6162`). So redo advances an unregistered "fake"
  origin keyed by the node id. **The subscription origin goes back to its last
  checkpointed value after a crash.**
- What follows: after `kill -9` of the subscriber postmaster, the apply worker starts
  from `replorigin_session_get_progress()` at the checkpointed LSN. The provider
  walsender jumps forward to the slot's `confirmed_flush`. Every transaction between
  `confirmed_flush` and what the subscriber had flushed locally is **re-applied**. Plain
  rows end up the same again (same-origin, equal-timestamp shortcut in
  `conflict_resolve_by_timestamp`, `src/spock_conflict.c:99-150`). **Delta-apply
  columns are not idempotent** (W2), so they double-count.
- Side effect: each fake origin takes a replication-state slot during redo.
  `docs/sizing.md:188-203` sizes `max_active_replication_origins = max_replication_slots`
  and does not count these fake origins. With enough peers, redo could hit "could not
  find free replication state slot" and the startup process would fail. (Unverified.)
- The comment on `maybe_advance_forwarded_origin()` (`spock_apply.c:5158-5165`)
  explicitly says "at-least-once semantics. last_update_wins handles the duplicate;
  delta-apply idempotency is tracked separately". I found no such tracking (W2).
- Why tests miss it: `016_crash_recovery_progress.pl`, `022_rmgr_progress_post_checkpoint_crash.pl`
  and `027_remote_commit_ts_recovery.pl` check the `spock.progress` view, not whether
  rows were applied twice. Delta columns are not crashed mid-stream anywhere I saw.

**Antithesis property:** for a table with a delta-apply column receiving only `+1`
increments from all nodes, final value on every node == total committed increments.
Kill subscriber postmasters between checkpoints.

### W2. Delta-apply is non-idempotent and overrides the conflict decision

- `src/spock_apply_heap.c:650-690`: when `rel->has_delta_columns`, the delta
  (`new - old` from the remote tuple) is **always** added to whichever tuple won. If
  the local tuple won, `apply` is forced to `true` (`is_delta_apply`).
- The delta is applied inside an internal subtransaction whose commit-ts entry is then
  overwritten with the *local* winner's ts/origin
  (`SubTransactionIdSetCommitTsData`, `spock_apply_heap.c:720-780`). That needs core
  patch `pg18-030-per-subtrans-commit-ts.diff` (new WAL record `COMMIT_TS_SUBTRANS_TS`).
  So one row can end up with a commit-ts that differs from its xmin transaction's
  commit-ts. Any later tool that reads `pg_commit_ts` by xid (progress recovery, W8;
  conflict detection on the next update) sees a subxact whose origin/ts came from a
  *different* node.
- Any redelivery path (W1, W3, W5's retry logic, zodan's slot/origin advance in W9)
  turns into silent counter drift.

### W3. An in-process exception retry advances the replication origin past the failed transaction before the retry finishes (Lead, high value)

- Core `RecordTransactionAbort` advances the session origin to
  `replorigin_session_origin_lsn` when an origin is set (PG `xact.c:1805-1808`).
  Spock knows this: the comment on `spock_apply_worker_shmem_exit()`
  (`spock_apply.c:2305-2325`) says that without clearing the origin first,
  "RecordTransactionAbort advances the origin to the in-flight transaction's stale
  final_lsn, silently skipping that txn on reconnect". That fix depends on the LIFO
  order of `before_shmem_exit` callbacks.
- But the *in-process* path does not clear it. In `apply_work()`'s PG_CATCH, the
  first-occurrence branch calls `AbortOutOfAnyTransaction()` (`spock_apply.c:~4065`)
  while `replorigin_session_origin` and `replorigin_session_origin_lsn` (set to the
  remote commit LSN in `handle_begin`, `spock_apply.c:686`) are still set. If the
  failing transaction had an xid, the shared-memory origin moves to that
  transaction's commit LSN *before* it is retried from the replay queue.
- If the retry is then cut short in a way that does not restart the postmaster (a
  connection error while the rest of the transaction is still streaming in, SIGTERM,
  FATAL, apply_idle_timeout), the new worker resumes *after* the transaction. **The
  transaction is skipped**, and it is not in `exception_log` because it never reached
  commit. A crash-restart is "safe" here only because of W1 (redo advances the fake
  origin).
- The odd shape: a graceful worker restart loses data, while a postmaster crash does not.

**Antithesis scenario:** a workload that triggers a real apply error partway through a
large transaction (e.g. a secondary unique index clash under `check_all_uc_indexes`, or
a missing relation), plus a network partition or provider pause during the replay.

### W4. Exit paths other than SIGTERM still leave a stale `exception_log.commit_lsn` → transaction misread as already failed

- `handle_begin` writes `exception_log->commit_lsn` on *every* BEGIN
  (`spock_apply.c:878`). On restart, a matching commit LSN means "this transaction
  failed before" → `use_try_block = true` (`spock_apply.c:834`), and the configured
  policy applies: **default `spock.exception_behaviour = transdiscard`**
  (`src/spock.c:1144-1150`) throws away the whole transaction.
- Fix ed0a9945 clears the marker only when `got_SIGTERM`. Other mid-transaction exits
  still leave it:
  - `replication_handler()` raises `elog(FATAL, ... read-only mode ...)` on *every
    message* when `spock.readonly = all` (`spock_apply.c:2981-2983`). Switching
    readonly to `all` mid-transaction exits through FATAL, which skips PG_CATCH, so
    the marker stays.
  - Any other FATAL (e.g. `pg_terminate_backend` turns into a die-FATAL if the
    worker's handler path differs), or a before/after-commit exit path.
- Related: the allow-list of "retryable" SQLSTATEs (`spock_apply.c:3917-3992`: class 08
  subset, 57P01/57P02/57P03, 40P01, 55P03, class 53) is how infrastructure faults get
  told apart from data faults. **Anything not on the list goes down the data-loss
  path.** Gaps I can see: `57014 query_canceled` (statement_timeout / lock wait cancel
  set by role or database), `40001` (the comment admits this), `58030` I/O errors,
  `25006` read_only_sql_transaction, and any bare `elog(ERROR)` (XX000) on a path that
  depends on timing. 8dcfbcd5 (`apply_idle_timeout` was untagged XX000) shows this kind
  of bug really happens.
- `exception_log` shared-memory slots are keyed by **subscription name only**
  (`namestrcmp(&exception_log->slot_name, MySubscription->name)`,
  `spock_apply.c:729-770`). There is no database oid. Two databases with a
  same-named subscription share a slot. Dropped subscriptions never release their slot
  (`/* TODO: What happens if a subscription is dropped? Memory leak */`,
  `spock_apply.c:802-805`). After enough create/drop cycles (zodan add/remove loops),
  `unable to find an empty exception log slot` is raised as a bare ERROR in
  `handle_begin`. A re-created subscription with the same name inherits the old entry.
- `SpockExceptionLog.local_tuple` is a **process-private pointer stored in shared memory**.

**Antithesis property:** with a conflict-free workload (each node writes disjoint keys),
`spock.exception_log` must stay empty and no subscription may become disabled, no
matter what faults are injected.

### W5. The sync-standby feedback hold is overwritten in `send_feedback()` (Lead)

- `send_feedback()` (`spock_apply.c:3237-3330`): when `SYNC_STANDBY_DEFINED`, it calls
  `get_feedback_position(&recvpos, &writepos, &flushpos, ...)` to hold back the
  positions until the subscriber's sync standby has flushed. Right after that,
  `get_flush_position(&writepos, &flushpos)` **unconditionally resets both to Invalid
  and recomputes them** from `lsn_mapping` (local flush only). If `lsn_mapping` is
  empty, `flushpos = writepos = recvpos`, and when no hold was released `recvpos` is
  still the caller's `last_received` / keepalive `endpos`.
- So with the local WAL flushed (the apply worker runs `synchronous_commit=off`, and
  walwriter flushes within ~200 ms) but the sync standby lagging, the publisher can be
  told "flushed" past what the standby has. The fix in 5f654e34 (#491) handled the
  wrong-LSN-space bug. Its test (`020_sync_standby_feedback_lsn.pl`) promotes a
  standby that is not lagging, so it would not see this.
- This is exactly the case where Antithesis pausing the standby container matters:
  pause the subscriber's sync standby, keep the provider writing, kill the subscriber
  primary, promote the standby, then check for missing rows.

### W6. Parallel "slot groups" are switched on by the *slot name's spelling*, and can silently split one stream between two subscribers (Lead, high value)

- `spock_output_join_slot_group()` (`src/spock_output_plugin.c:1281-1360`), called from
  the startup callback (`:232`) for every walsender. If the slot name ends in
  `_<single digit>`, the suffix is cut off and the rest is used as a **shared-memory
  group name**. Members of a group share `last_lsn`; a member that sees
  `txn->end_lsn <= last_lsn` **skips the transaction**
  (`spock_output_plugin.c:535-583`, `slot_group_skip_xact`).
- Slot names are `spk_<db>_<provider>_<sub>`, and every character outside `[a-z0-9_]`
  is replaced with `_` (`gen_slot_name`, `src/spock_functions.c:3666-3687`).
  **Uppercase is replaced too.** Node names `N1`, `N2`, `N3` give a subscription
  `sub_N1_N2` → slot `spk_<db>__1_sub__1__2`. On provider N1 the slots for N2 and N3
  both reduce to group `spk_<db>__1_sub__1_`. The two walsenders then *share* one
  transaction stream: each subscriber gets part of N1's transactions. User-chosen
  subscription names like `sub_a_1` (≤16 chars, so `shorten_hash` leaves them alone,
  `src/spock.c:213-229`) do the same.
- On the subscriber, the `COMMIT_ORDER` message carries the group's previous commit ts,
  and `wait_for_previous_transaction()` (`spock_apply.c:295-338`) spins until
  `apply_group->progress.prev_remote_ts == required_commit_ts`. When the predecessor
  went to a *different* subscriber, that never happens. So the second symptom is an
  **apply worker that hangs forever** (1 ms CV timed sleeps), not an error.
- The feature is real (release notes 4.0/4.1, "parallel slots") but absent from current
  docs. c0bcad19 calls it a "prototype" and fixes "missing transactions … when actually
  using parallel slots". Even when used on purpose, group `last_lsn` is shared memory
  that is reset only when `nattached` reaches 0 (`:1350-1357`). One member reconnecting
  from an earlier LSN while another stays attached skips everything up to `last_lsn`.
  `11b9d385` (nattached leak) is in the same area.
- Antithesis workloads almost certainly use `n1/n2` names and never reach this. I
  recommend one configuration using uppercase or `_<digit>`-suffixed node names.

### W7. The Lamport "logical commit clock" lives only in memory and only covers local commits

Core patch `patches/1x/pg1x-025-logical_commit_clock.diff`:
- `XLogCtl->lastTransactionStopTimestamp` is updated inside `ReserveXLogInsertLocation`
  while holding `insertpos_lck`. The hook rewrites `xl_xact_commit.xact_time` and
  `xactStopTimestamp` after the record was assembled, then recomputes the CRC
  (`XLogRecordCorrectCRC`). It works, but it is a WAL-format change done under a
  spinlock in core.
- **Not restart-safe, and the patch says so**: `TODO: This is not postmaster restart
  safe. If the local system clock is further behind other nodes than it takes for the
  postmaster to restart … local transactions will not be bumped`. The clock starts at 0
  after every restart, crash recovery and standby promotion (it is not rebuilt from WAL).
- Applied (remote) transactions are *not* bumped. The clock only takes `max()` of
  them (`remoteTransactionStopTimestamp`, set at `spock_apply.c:1056`). Their
  `pg_commit_ts` value is the origin's timestamp, so commit-ts on the subscriber is not
  monotonic in LSN order.
- What follows:
  1. Last-update-wins can let a *causally later* local update lose to an earlier remote
     one after restart + clock skew. Antithesis's clock skew plus restart hits this
     directly.
  2. `spock.get_lsn_from_commit_ts()` (`src/spock_functions.c:~4220-4300`) scans WAL
     and `break`s at the first commit whose `xact_time > committs`. It assumes
     commit-ts is monotonic over *all* commit records. Applied transactions (local
     wall time, not bumped) and post-restart resets break that, so an early break
     returns an LSN that is too low.
- Spock calls `remoteTransactionStopTimestamp` directly, so it will not build without
  the patch. But the memory notes say some local PG builds (pg17-back, pg18) lack the
  patches. The Antithesis image must use patched PG, or the build fails (or worse,
  links against a different libpq/headers mix).

### W8. `spock.progress` is called "monitoring" but drives add-node correctness, and is rebuilt after a crash by heuristics

- Design doc `docs/internals-doc/specs/spock-progress-no-checkpoint-hook-design.md`
  calls it monitoring, then admits the `force_set_list` entries "are *deduplication
  state* for forwarded transactions in a mesh (not just monitoring)".
- `resource.dat` is written only on clean supervisor exit, add_node and table-sync
  (`src/spock_group.c:510-830`). The clean-shutdown dump runs from the supervisor's
  `before_shmem_exit` after a ~5 s poll for apply workers to finish. A slow worker
  means the dump records stale state.
- After a crash, `remote_commit_ts` is rebuilt by scanning `pg_commit_ts` backward
  (`src/spock_progress_recovery.c:45-47, 286-340`). It stops after 1000 commits from
  that origin. The justification ("publisher's in-flight xacts bounded by
  max_connections") is an argument nobody has checked. Delta-apply subxact overrides
  (W2) put entries with *other* origins' timestamps into the scanned range.
- zodan (`samples/Z0DAN/zodan.sql:2637-2650`) reads `spock.progress.remote_commit_lsn`
  on the new node to advance peer slots and origins. **If the entry is missing it logs
  a WARNING and falls back to `pg_current_wal_lsn()` on the peer**, which skips every
  peer commit between the snapshot and now. A new-node restart or crash between COPY
  and this step (before the post-loop dump) can remove the entry. Data loss shows up
  only as a NOTICE/WARNING line.

### W9. The node-add protocol is a 3,274-line PL/pgSQL "sample" run over dblink

- `samples/Z0DAN/zodan.sql` is the add-node orchestrator (used by TAP 009/011/012/017/033/099).
  It is not atomic. Each step runs in a separate dblink session on different nodes
  (create slot → `sync_event` → poll `spock.progress` → COPY → advance slots/origins →
  enable subs). It assumes `apply is in commit order` (`:1905-1910`), single apply worker,
  no slot groups (W6). If the orchestrator dies partway (a client-side fault, not a
  server one), slots, origins and disabled subscriptions are left behind
  (`zodan_cleanup.sql` exists for this). Any Antithesis add-node workload should
  kill the *orchestrator* too, not just servers.
- `spock_create_subscriber` in the repo root is a prebuilt aarch64 binary from 2025
  with no source in the tree. `002_create_subscriber.pl` uses whatever is installed.

### W10. Fake replication origins and 16-bit node ids

- Node ids are `hash(name) & 0xffff` (`src/spock_node.c:367-385`). The collision check
  is only against the *local* `spock.node` catalog at create time (024_node_id_collision
  test). These ids are used as `RepOriginId` in WAL, in `pg_commit_ts`, and in
  conflict decisions (`local_tuple_origin == replorigin_session_origin`,
  `spock_conflict.c:400`). A node id that happens to equal a real local
  `pg_replication_origin.roident` (small integers) would make conflict detection treat
  rows from one source as coming from another. Unlikely (about 1/65536 per pair), but
  the design assumes the two id spaces never overlap and nothing enforces that.

### W11. Smaller oddities worth a look

- Custom WAL rmgr id **144** (`src/spock_rmgr.c`, `include/spock_rmgr.h`) is purely
  diagnostic (redo only logs). Any server replaying Spock WAL, including physical
  standbys for failover slots, PITR restores and `pg_waldump`, **must have spock in
  `shared_preload_libraries` or recovery fails**. c2d87f5e moved registration before
  the `IsBinaryUpgrade` return for this reason. In a container harness, a standby
  image without the preload setting will not start.
- Timeouts use wall-clock `GetCurrentTimestamp()` (`apply_idle_timeout`,
  `pause_timeout`, `sync_timeout`, zodan's `clock_timestamp()` budgets). Antithesis
  clock jumps fire them early. After 8dcfbcd5 the idle timeout is connection-class, but
  zodan budgets then fail add_node.
- `spock_random_delay()` (`src/spock_injection.c`, build flag `SPOCK_RANDOM_DELAYS=1`)
  uses `pg_global_prng_state` and adds 1–100 ms sleeps at `spock-worker-delay` and
  `spock-output-txn-stall`. That is a cheap build variant for Antithesis to widen
  timing windows. `USE_INJECTION_POINTS` gives named hooks
  (`include/spock_injection.h:40-50`).
- `remote_insert_lsn` etc. are refreshed by a "forced keepalive" right after connect
  (TAP 023). `request_initial_status_update` must not touch `send_feedback`'s static
  state. Those statics (`last_flushpos` etc.) are per process and only move forward,
  but the slot can be advanced by zodan out of band. If that ever makes the subscriber's
  view move backwards, the `max()` clamp hides it.
- The `pg_decode_origin_filter` (`spock_output_plugin.c:1202-1222`) is all-or-nothing:
  `forward_origins` non-empty forwards *every* origin, whatever the list contains.

---

## Areas examined
- `patches/18/*.diff` (logical commit clock, per-subtrans commit-ts); spot-checked PG core
  `xact.c` in a local PG tree for redo/abort origin behaviour.
- `src/spock_apply.c` (handle_begin/origin/commit, exception catch, feedback, readonly,
  shmem exit), `src/spock_apply_heap.c` (delta apply), `src/spock_conflict.c`,
  `src/spock_output_plugin.c` (slot groups, origin filter, commit order),
  `src/spock_rmgr.c`, `src/spock_group.c`, `src/spock_progress_recovery.c`,
  `src/spock_node.c`, `src/spock_functions.c` (slot naming, get_lsn_from_commit_ts),
  `src/spock_readonly.c`, `src/spock_injection.c`, `src/spock.c` GUCs.
- `docs/internals-doc/specs/spock-progress-no-checkpoint-hook-design.md`, `docs/sizing.md`,
  `docs/limitations.md`, release notes; `samples/Z0DAN/zodan.sql`.
- git log/show: 8dcfbcd5, ed0a9945, 5f654e34, c0bcad19, c4368188, f21e71bc, 2f9a686c.
- TAP test list (`tests/tap/t`).

## Assumptions
- Core PG behaviour (redo uses the record's origin; abort advances the session origin)
  matches the PG tree I checked (`~/dev/pg/postgresql`, not the SUT). pgEdge
  patches do not touch these paths (I read the 18.x patches; they don't).
- The `handle_origin` → `replorigin_session_origin = node id` path runs for every
  transaction under the native protocol (`write_origin` is always set there).
- I did not run anything. W1, W3, W5, W6 are leads that need a focused repro.

## Open Questions
1. W1: after a subscriber crash between checkpoints, does `pg_replication_origin_status`
   for the subscription origin roll back? Do fake origins with roident == node id
   appear? (A quick TAP check: crash, then `SELECT * FROM pg_replication_origin_status`.)
2. W3: does the first-occurrence catch path ever see a transaction with an assigned xid
   (so an abort record is written)? If yes, is the shared-memory origin past the failed
   transaction during replay?
3. W5: was overwriting `writepos`/`flushpos` after `get_feedback_position` intended?
4. W6: is any deployment (pgEdge CLI/Helm) known to use uppercase or `_<digit>` node
   names? Is the parallel-slot feature still supported?
5. W8: how often does zodan hit the `pg_current_wal_lsn()` fallback in CI logs?
6. W7: is there a plan to persist `lastTransactionStopTimestamp` (e.g. recompute it
   from the last commit record during redo)?
