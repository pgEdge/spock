# 11 — Unproven Assumptions

SUT: Spock @ 69d9228f (main). Focus: implicit axioms the code relies on but never checks.
Everything below is from reading code, tests, docs and git history. Nothing was run.
"Hypothesis" means the code reading points to a bug that still needs a run to confirm.

Findings are ranked by how likely they are to produce a real, visible property violation under
Antithesis faults (kill/restart, partition, latency, clock skew).

---

## Findings

### A1. Spock node id is written into WAL as the origin of applied commits, so crash redo advances the wrong origin (Hypothesis, high value)

**The assumption.** The subscription's replication origin (roident from
`replorigin_create(slot_name)`, `src/spock_functions.c:751`, `src/spock_sync.c:479-482`) is
assumed to survive a crash at its last committed position. The design doc says so outright:
"The correctness-critical 'where do I resume from' question is handled entirely by stock
logical-replication protocol" (`docs/internals-doc/specs/spock-progress-no-checkpoint-hook-design.md:26`).
The header of `tests/tap/t/022_rmgr_progress_post_checkpoint_crash.pl:17-18` makes the same claim:
"WAL recovery advances pg_replication_origin ... (via xact_redo_commit → replorigin_advance_by_xlog)".

**Why it may not hold.**
- The worker sets up the session with the slot's roident (`spock_apply.c:4745-4750`).
- `handle_origin()` then **overwrites `replorigin_session_origin` with the remote Spock node id**
  (`spock_apply.c:1332`: `replorigin_session_origin = remote_origin_id;`). The comment at
  `spock_progress_recovery.c:120-127` confirms that this value is what ends up in pg_commit_ts.
- In stock PG, `XactLogCommitRecord` stamps the commit record's origin with
  `replorigin_session_origin`. `xact_redo_commit` then calls
  `replorigin_advance(origin_id = record origin, parsed->origin_lsn, ...)`. So crash redo advances an
  origin **numbered by the node id**, not the subscription's roident. At commit time the in-memory
  advance (`replorigin_session_advance`) goes to the slot roident, but nothing makes it durable
  except a checkpoint.
- Supporting evidence: `tests/tap/t/027_remote_commit_ts_recovery.pl:92-94` runs CHECKPOINT
  before SIGKILL because "Without this, after SIGKILL the origin may roll back to round-1". Test 022
  also checkpoints first, so it never tests the redo path. `016_crash_recovery_progress` was
  skipped (commit 69722443).
- Commit 401197ab says "replorigin_advance() does no catalog validation" and WAL-logs the
  *forwarded* origin advance itself (`maybe_advance_forwarded_origin`, `spock_apply.c:5165-5190`,
  `wal_log=true`). The direct-provider origin gets no such treatment.

**Consequences under Antithesis (kill -9 of a subscriber between checkpoints):**
1. **Re-apply after crash.** The subscription origin falls back to its last checkpoint value, so
   the provider re-sends transactions that were already applied and committed.
   - INSERT becomes insert_exists, UPDATE runs again. Last-update-wins with equal timestamps takes
     the same-origin shortcut (`spock_conflict.c:153-158`), so plain columns end up correct.
   - **Delta-apply columns get the delta added twice.** `spock_handle_conflict_and_apply`
     (`spock_apply_heap.c:653-692`) forces `apply = true` and adds `new - old` on top of the
     current local value regardless of who won. The code says idempotency is not handled:
     "delta-apply idempotency is tracked separately" (`spock_apply.c:5160-5162`).
   - DELETEs that run again become delete_missing (skipped). That is harmless unless a later
     INSERT has already happened.
2. **Wrong origin pushed forward.** If a node id's numeric value equals some *other* local
   roident (roidents are small, 1..N, and reused; node ids are `hash_any(name) & 0xffff`,
   `spock_node.c:369-371`), redo moves that unrelated origin forward into a different WAL LSN
   space. The subscription that owns that roident then resumes past data it never applied, which
   is **silent data loss**. You can pick node names that trigger this on purpose:
   `SELECT hashtext(name) & 65535` should match the id (hash_any over the name bytes; verify
   against `spock.node.node_id`).
3. **Leftover origin states.** Every crash recovery creates in-memory origin states keyed by
   node id. The end-of-recovery checkpoint writes them to `pg_logical/replorigin_checkpoint`. With
   a tight `max_replication_slots` / `max_active_replication_origins`, redo may hit "could not find
   free replication state slot" and recovery fails.

**How to check (cheap):** 2 nodes, `track_commit_timestamp=on`. Apply about 100 transactions to
n2 with no checkpoint (set a large `checkpoint_timeout`), then SIGKILL n2 and restart. Compare
`pg_replication_origin_status` before and after. Look for a row with `local_id = <n1 node_id>` and
a regressed `remote_lsn` for the subscription's roident. Then repeat with a delta-apply column
(`ALTER TABLE ... ALTER COLUMN c SET (delta_apply_function=...)`) and compare `sum(c)` across nodes.

**Property:** "After any crash and restart of any node, the number of applied delta updates for
each provider transaction is exactly 1", that is, `sum(delta_col)` matches on all nodes once
quiescent. Also: "a subscription's origin `remote_lsn` never goes backward past a transaction
whose effects are visible locally."

---

### A2. Node ids are assumed unique and valid cluster-wide, but they are 16-bit name hashes checked only locally

- `create_node()` (`spock_node.c:367-384`) computes `hash_any(name) & 0xffff` and checks for a
  collision **only against the local catalog**. The test header of `t/024_node_id_collision.pl`
  admits "no cluster-wide coordination". A collision is caught only when two nodes subscribe to
  each other directly (PK violation on `spock.node`). In a cascade (A→B→C with
  `forward_origins='all'`) a collision between A and C is never caught.
- **The ids 0 and 65535 are never rejected.**
  - A hash of `0` leaves `node->id == InvalidOid == InvalidRepOriginId`. That node's
    transactions look local everywhere: `pg_decode_origin_filter` never filters origin 0
    (`spock_output_plugin.c:1208`), so this can cause replication echo loops.
  - A hash of `0xffff` equals `DoNotReplicateId`. Commits applied from that node skip
    origin/commit-ts bookkeeping (`spock_apply.c:1123`, `2958`), so last-update-wins would use
    *local* timestamps.
  - Both are reachable through the node name alone (probability 2/65536 per name).
    Antithesis can choose names that hit them.
- `docs/limitations.md:191-199` admits that Spock node ids overlap the native RepOriginId space
  "if Spock and native logical replication run on the same database". But Spock's own
  subscription origins *are* native RepOriginIds, so the overlap exists in plain Spock too (see
  A1.2).
- Tiebreaker defaults to the node id (`spock_node.c:525,532`). Equal tiebreakers resolve as
  "apply remote" on **both** sides (`spock_conflict.c:165-185`), which swaps the values and leaves
  the nodes diverged. The code only logs a WARNING.

---

### A3. The equal-timestamp tiebreaker uses the *applying* node's value, not the local tuple's origin, so 3+ nodes can diverge (Hypothesis, logic bug)

`conflict_resolve_by_timestamp` (`spock_conflict.c:131-200`) compares `tiebreaker(applying
node)` with `tiebreaker(remote origin)` when commit timestamps are exactly equal. Commit 64ea462d
deliberately switched to this. When the local row came from a *third* node, the winner depends on
the order of arrival:

Example: tiebreakers A=2, B=1, C=3 (lower wins). A and C write the same row at the same ts.
- On A: C's change arrives. A(2)<C(3), so A keeps local: **A's value**.
- On C: A's change arrives. C(3)>A(2), so C applies remote: **A's value**.
- On B: C's change arrives first and is applied. Then A's arrives. B(1)<A(2), so B keeps local:
  **C's value**. Divergence.

This needs commit timestamps that are equal to the microsecond. That is rare on real clocks but
may be reachable under a controlled or virtual clock. The logical-clock patch only bumps local
commits (`patches/18/pg18-025-logical_commit_clock.diff`, `EnsureMonotonicTransactionStopTimestamp`),
so two nodes can still produce identical timestamps.

**Property:** after quiescence, every replicated table has the same contents on all nodes.

---

### A4. Last-update-wins assumes the logical clock survives restarts, but it does not (TODO in the patch)

- The pgEdge PG patch keeps `XLogCtl->lastTransactionStopTimestamp` (zeroed shared memory, never
  recovered) and bumps local commit timestamps past any remote timestamp seen so far. The patch
  itself says: "TODO: This is not postmaster restart safe. If the local system clock is further
  behind other nodes than it takes for the postmaster to restart ... local transactions will not
  be bumped into the future correctly." (`pg18-025-logical_commit_clock.diff`, ~line 140).
- Effect under clock skew combined with a restart: node X with a slow clock applies a remote
  update at ts=T, restarts, then updates the same row locally at a wall-clock time less than T.
  - X keeps its local write. The local write is not checked against anything.
  - Peers receive it, see a remote ts below their local T, and keep theirs (`cmp < 0`, KeepLocal).
  - Result: **permanent divergence**, with no error and no conflict-log row on X.
- On vanilla PG (no pgEdge patches) the monotonic bump doesn't exist at all. The extension does
  not detect whether it is running on a patched server. The docs (`docs/conflicts.md`,
  `docs/conflict_types.md:168-176`) never mention clock synchronization as a requirement.
- `begin_replication_step` (`spock_apply.c:880-900`) has "FIXME: deal with overflow?" for
  `apply_delay` arithmetic under clock drift.

**Antithesis:** clock skew on one node plus restarting that node plus writes to the same keys
from several nodes. Check that the cluster converges.

---

### A5. Apply assumes changes from different origins arrive in causal order (update_missing and delete_missing)

- An UPDATE whose row is missing raises `elog(ERROR, "logical replication did not find row to be
  updated...")` (`spock_apply_heap.c:1036-1040`). With the default
  `spock.exception_behaviour = transdiscard` (`spock_exception_handler.c:78`) the **whole remote
  transaction is discarded** and the origin moves forward.
- Scenario: A inserts row r. B receives it and updates r. C is cut off from A but not from B, so
  B's UPDATE reaches C first, finds nothing, and is discarded. A's INSERT arrives later, and C ends
  up with the stale row forever. The docs (`docs/conflict_types.md:92-103`) call this
  "not resolvable".
- Same shape for DELETE: delete_missing is skipped (`spock_apply_heap.c:1210-1222`). If the
  INSERT arrives after the DELETE, the row comes back to life on that node only.
- Nothing orders per-row changes across origins, and Spock does not keep tombstones.

**Property:** under partitions that leave each node reachable by some path, eventual
consistency holds for workloads that update or delete rows inserted elsewhere. Expect this to
fail. It is useful as a measured "known-unsafe" baseline, and the exception_log row count is a
good signal.

---

### A6. Transient-vs-permanent error classification is an allowlist; anything not on it is treated as bad data and discarded

`apply_work` PG_CATCH (`spock_apply.c:3880-4000`) retries only the following:
- connection-class codes (08006/08000/08003, 57P01-57P03, or `PQstatus==CONNECTION_BAD`)
- deadlock (40P01)
- lock_not_available (55P03)
- class 53

Everything else goes into the exception/replay path. With TRANSDISCARD, that path drops the
transaction. Codes not on the list that are not data faults:
- **57014 query_canceled.** The apply bgworker picks up per-database and per-role GUCs, and
  Spock does not override `statement_timeout` (only `synchronous_commit`,
  `session_replication_role`, `check_function_bodies`, `spock_apply.c:4700-4715`). So
  `ALTER DATABASE ... SET statement_timeout` or `pg_cancel_backend()` on an apply worker drops a
  good transaction.
- **40001 serialization_failure**, which the code admits in a comment: "a cluster-wide
  default_transaction_isolation can still produce 40001, which then takes the exception path"
  (`spock_apply.c:3960-3965`).
- Untagged `elog(ERROR)` from the stream path. Commit 8dcfbcd5 fixed one such case (the idle
  timeout was misclassified and discarded a good transaction). Test
  `t/046_apply_worker_exception_misclassification.pl` exists because this keeps happening.

**Property:** "no row reaches `spock.exception_log` unless a real data conflict was injected".
Run a workload with no conflicts plus faults. Any exception_log row means a transient error
caused data loss.

---

### A7. add_node assumes apply workers stay paused for the whole slot-create and progress-read window

`spock_create_slot_and_read_progress` (`spock_sync.c:~660-860`) runs:
`spock.pause_apply_workers()`, then `CREATE_REPLICATION_SLOT`, then imports the snapshot, then
reads `pg_replication_origin_status.remote_lsn` (shared memory, not MVCC), then resumes. The
progress read is assumed to match the snapshot exactly. That assumption breaks three ways:
1. **Worker-side timeout.** `maybe_pause_for_slot_creation` (`spock_apply.c:563-584`) gives up
   after `spock.pause_timeout` (default 10s, `spock.c:177`). On timeout the worker **clears the
   global flag itself** and resumes. `CREATE_REPLICATION_SLOT` waits for all running xids on the
   provider, so under load, paused processes or added latency it can take longer than 10s. Apply
   then commits peer transactions that are outside the COPY snapshot but inside the
   `remote_lsn` that is read next. The new node then starts its peer subscriptions after those
   transactions, which is **data loss on the new node**.
2. **Check-side gap.** `spock_pause_apply_workers` (`spock_functions.c:4060-4125`) counts as
   "paused" any worker with no xid. A worker that has received BEGIN but not yet done its first
   DML has no xid. It will apply and commit a whole transaction before it reaches
   `maybe_pause_for_slot_creation`, which is only called after commit (`spock_apply.c:1186`).
3. **Workers starting up are skipped** (`w->proc == NULL`, `spock_functions.c:~4090`). A
   restarted apply worker can commit one transaction during the window.
- Also: the loop counts `waited_ms++` per `pg_usleep(1000)` and ignores the time the scan itself
  takes, so the real timeout is longer than configured. If add_node fails after pausing, resume is
  never called, and the workers' own 10s timeout is the only way out.

**Antithesis:** add a node under steady writes on every existing node, with process pauses and
latency on the provider. Then compare the new node's tables with the others.

---

### A8. Slot-group (parallel walsender) assumptions: chosen by name pattern, lock-free leave, NULL free group

`spock_output_plugin.c:1281-1380`:
- **Triggered by name.** Any slot whose name ends in `_<single digit>` joins a "slot-group". Slot
  names are `spk_<db>_<provider>_<subname>`, each part cut to 16 characters
  (`spock_functions.c:3666-3687`), so a subscription named e.g. `sub_1` turns it on by accident.
  Group members skip any transaction whose `end_lsn <= last_lsn` (`:559-573`).
  - If a member claims a transaction (sets `last_lsn`) and then dies or loses its connection
    before sending it, other members skip it.
  - When the member restarts, the group is still attached, so it skips the transaction too.
  - Nobody ever delivers that transaction.
- **Unlocked decrement.** `spock_output_leave_slot_group` decrements `nattached` with the lock
  commented out (`/* LWLockAcquire(...) */`, `:1377-1384`), racing `join` which does take the lock.
- **NULL dereference.** In `join`, if no group matches and none is free, `free_group` stays NULL
  and is dereferenced (`strlcpy(NameStr(slot_group->name)...)`). The code assumes
  `max_worker_processes` groups are always enough.
- The feature is not documented anywhere under docs/.

---

### A9. Assumptions in the sync (table resync) path

- `spock_apply.c:4526-4535`: "TODO: What if the SYNC worker has gone? ... For now, suppose that it
  should be always exist in testing environment." followed by
  `Assert(spock_worker_running(worker))`. In an `--enable-cassert` build, killing the sync worker
  between SYNCWAIT and CATCHUP crashes the apply worker. The assert also triggers a postmaster
  crash-restart of every node process.
- `spock_apply.c:4560-4566`: a failed `wait_for_sync_status_change` raises
  `elog(ERROR, "a table synchronisation operation is failed")`. That is `INTERNAL_ERROR`, so
  under A6 the exception path treats it as a data fault.
- `spock_apply.c:4487-4494`: when the sync status row is missing, the code
  "assume[s] table is not relevant for us anymore" and marks it READY.

---

### A10. Exception-log shared memory slots are keyed by subscription name and never freed

`handle_begin` (`spock_apply.c:720-815`) finds or claims a slot in `exception_log_ptr` (size
`max_worker_processes`, `spock_worker.c:796`) by subscription **name only**:
- not by database
- `clear_exception_log_entry` (`:387-395`) never clears `slot_name`
- "TODO: What happens if a subscription is dropped? Memory leak" (`:801`)

Consequences:
- After enough distinct subscription names since the last postmaster start (node add/remove
  cycles), BEGIN fails with "unable to find an empty exception log slot" on every attempt.
- Two databases using the same subscription name share one slot, so their commit_lsn and
  use_try_block state can mix.

---

### A11. `wait_for_sync_event` assumes "origin remote_lsn ≥ L" means "the data is visible"

`spock.wait_for_sync_event` (`sql/spock--6.0.0.sql:685-762`) polls
`pg_replication_origin_status.remote_lsn`. That value is advanced in shared memory:
- during commit, before the transaction is visible in the procarray, and
- immediately for empty or non-transactional sync events (`spock_apply.c:1123-1127`, `2955-2964`)
- apply runs `synchronous_commit=off` (`spock_apply.c:4700`), so the advance is not durable.

ZODAN, and any test that waits and then checks, can see the old state.
- Small race on its own.
- After a crash, A1 can push `remote_lsn` *backward* after a wait has already returned true.
- The wait covers only the direct origin. Transactions forwarded from third nodes are not
  covered.

---

### A12. Smaller "can't happen" items worth a property

- `spock_group.c:683-700`: `resource.dat` is read with no CRC ("XXX: Do we need any kind of CRC
  here?"). A torn or corrupt file loads silently. Duplicate keys only cause `Assert(!ret)` plus a
  WARNING.
- `spock_group.c:380-400`, `475-484`, `545-551`: missing shared memory makes progress updates
  disappear silently (WARNING), or makes `apply_worker_get_prev_remote_ts` ERROR.
- `wait_for_previous_transaction` (`spock_apply.c:295-337`) waits forever, polling every 1ms, until
  `prev_remote_ts == required_commit_ts`. This is used only with slot-groups. It assumes the
  predecessor transaction will eventually commit through *some* group member, and it has no
  timeout (see A8).
- `handle_message` (`spock_apply.c:2920-2928`): a bad prefix or LSN on a logical message is FATAL
  ("protocol breach"). The worker restarts and probably loops.
- `spock_common.c:458-475`: TM_Updated and TM_Deleted retry without limit ("XXX: Improve
  handling").
- `spock_relcache.c:252,290`: "XXX Should we validate the relation against local schema here?"
  A remote column missing locally raises `elog(ERROR, "unknown column name")`
  (`:398`), which is A6 again: the transaction is discarded. The code assumes DDL was applied
  everywhere before the DML that depends on it. Nothing orders DDL from one origin against DML
  from another.
- Hardcoded libpq settings with no stated reason: `connect_timeout=30`, `keepalives_idle=10`,
  `keepalives_interval=5` (`spock.c:399-410`, the same in `spock_failover_slots.c:506`).
  `ConditionVariableTimedSleep(..., 1ms)` busy-polls in `wait_for_previous_transaction`.
- `spock_failover_slots.c:830`: "This shouldn't happen for existing slots unless someone else
  messed with our physical replication slot". Sync is then skipped with a WARNING.
  `:990` "TODO: Don't stop synchronization of other slots for this": one slot that is behind blocks
  syncing of all the others.
- `get_tuple_origin` with `track_commit_timestamp=off` treats every local row as coming from the
  remote (`spock_conflict.c:225-233`), which quietly turns last-update-wins into apply-remote.
  Spock does not refuse to start in this setup.
- `spock_progress_recovery.c:120-131`: the pg_commit_ts scan filter is "not
  subscription-unique". The comment calls this forensic only.

---

## Areas examined

- `src/spock_conflict.c`: conflict resolution, tiebreaker, `get_tuple_origin`, report filtering.
- `src/spock_apply.c`:
  - begin, commit, origin and commit_order handlers
  - pause for slot creation
  - error classification in `apply_work` PG_CATCH
  - sync-table handling
  - exception-log slot allocation
  - forwarded-origin advance
  - feedback and sync-replica hold
- `src/spock_apply_heap.c`: insert/update/delete conflict and delta-apply paths.
- `src/spock_node.c`: node id generation and collision check, tiebreaker parsing.
- `src/spock_output_plugin.c`: begin/commit callbacks, origin filter, slot-groups,
  `MyWalSenderIdx` LSN offset.
- `src/spock_progress_recovery.c`, `src/spock_group.c`, `src/spock_rmgr.c`: progress
  persistence and reconcile.
- `src/spock_sync.c`: create slot plus read peer progress, pause and resume.
  `src/spock_functions.c`: pause/resume, `gen_slot_name`.
- `src/spock_relcache.c`, `src/spock_common.c` (tuple lock retry), `src/spock_manager.c`,
  `src/spock_failover_slots.c`.
- `patches/18/pg18-025-logical_commit_clock.diff`.
- `sql/spock--6.0.0.sql`: `wait_for_sync_event`, `node_create`.
- `docs/conflict_types.md`, `docs/limitations.md`,
  `docs/internals-doc/specs/spock-progress-no-checkpoint-hook-design.md`.
- TAP tests 016, 022, 024, 027, 046.
- Commits 401197ab, 69722443, 94f4ad6d, 8dcfbcd5, 64ea462d.

## Assumptions (mine)

- Stock PG behavior I relied on but did not re-read in a PG tree:
  - `XactLogCommitRecord` / `XLogRecordAssemble` stamp `replorigin_session_origin` as the record
    origin.
  - `xact_redo_commit` calls `replorigin_advance(record_origin, origin_lsn, ...)`.
  - `RecordTransactionCommit` skips origin and commit-ts bookkeeping when the origin equals
    `DoNotReplicateId`.
  - Bgworkers pick up `ALTER DATABASE/ROLE SET` GUCs.

  A1 and the 0/65535 cases in A2 depend on these.
- `SELECT hashtext(name) & 65535` reproduces Spock's node id. This is unverified; check it against
  `spock.node`.
- The pgEdge-patched PG is the intended target (needed for A4).

## Open questions

1. Does PG redo really advance the node-id-numbered origin and leave the subscription's roident
   alone (A1)? A one-hour TAP run settles it: SIGKILL with no CHECKPOINT, then inspect
   `pg_replication_origin_status`. If confirmed, A1 is the top Antithesis target.
2. Is the slot-group feature (A8) reachable in supported deployments, or only through
   subscription names that end in `_N`?
3. Is TRANSDISCARD the intended production default given A5 and A6? Should Antithesis runs also
   use `sub_disable` so failures are visible instead of silent?
4. Is there any intended runtime check for clock skew between nodes, or a documented maximum skew?
5. Is equal-commit-timestamp tie-breaking (A3) expected to converge for 3+ nodes? If so, which
   tiebreaker should be used?
