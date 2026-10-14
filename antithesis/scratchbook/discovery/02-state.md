# 02 — State Management and Persistence (Spock @ 69d9228f)

Focus: where Spock keeps state, how it moves between processes and nodes, what
survives a crash, and what happens to in-flight state when something fails.
Everything here comes from this tree (src/, include/, sql/, patches/,
samples/Z0DAN, docs/internals-doc, git history). Claims taken from comments or
docs are marked **CLAIM**; they have not been checked.

---

## 1. State inventory (what lives where)

| State | Where | Durable? | Owner / writers | Readers |
|---|---|---|---|---|
| Resume position per subscription (`remote_lsn`) | PG replication origin named `sub_slot_name` (`pg_replication_origin_status`) | Yes: commit and abort WAL records carry the origin LSN, and checkpoints save it | Apply worker commit (`RecordTransactionCommit` → `replorigin_session_advance`), empty-txn path `replorigin_session_advance` (spock_apply.c:1125-1130, **not WAL-logged**), sync `replorigin_advance(..., wal_log=true)` (spock_sync.c:1684, 1900), forwarded-origin advance (spock_apply.c:5181), Z0DAN `pg_replication_origin_advance` (zodan.sql:2559, 2671) | Apply startup `replorigin_session_get_progress` (spock_apply.c:4751), `spock.wait_for_sync_event`, `spock.read_peer_progress` |
| Provider-side position | Logical slot on provider (`confirmed_flush`, `restart_lsn`) | Yes (slot state file) | walsender from subscriber feedback (`send_feedback`, spock_apply.c:3237); Z0DAN `pg_replication_slot_advance` | walsender start position |
| Apply-group progress (`spock.progress` view) | Shared-memory hash `SpockGroupHash`, key (dbid, node_id, remote_node_id) (include/spock_group.h:57-145) | **Only through** `PGDATA/spock/resource.dat` snapshots, written at clean shutdown, add_node force-set and table sync | `handle_commit` (spock_apply.c:1150-1179), `UpdateWorkerStats` on every message (3380-3392), reconcile at worker start, force-set / update-list from sync | `spock.progress` view; Z0DAN Phase 7 (zodan.sql:2542, 2638); `spock.read_peer_progress()` JOIN; `wait_for_previous_transaction` (prev_remote_ts) |
| Forensic progress records | Custom WAL rmgr id 144, `SPOCK_RMGR_RESOURCE_DUMP` (src/spock_rmgr.c) | WAL | Same 3 dump call sites | `pg_waldump` only. Redo only prints a LOG line (spock_rmgr.c:92-118) |
| Catalog tables | `spock.node`, `node_interface`, `local_node`, `subscription`, `local_sync_status`, `replication_set*`, `sequence_state`, `exception_log`, `exception_status(_detail)`, `resolutions`, `queue`, `depend`, `pii`, `reserved_object` (sql/spock--6.0.0.sql) | Yes (heap) | SQL functions, apply worker (exception_log, sub_skip_lsn, sync status), sync worker | Manager/apply/sync workers, output plugin (repsets, node names) |
| Commit timestamps + origin per xid | `pg_commit_ts` (needs `track_commit_timestamp=on`), plus the pgEdge per-subtransaction entries `COMMIT_TS_SUBTRANS_TS` (patches/18/pg18-030) | WAL-logged | PG commit path; applied xacts are stamped with the **remote** commit ts and **remote spock node id** as the origin (handle_begin sets `replorigin_session_origin_timestamp`; handle_origin sets `replorigin_session_origin = remote node id`, spock_apply.c:1335) | Conflict resolution `get_tuple_origin` (spock_conflict.c:219-275); ts recovery scan |
| Logical commit clock | `XLogCtl->lastTransactionStopTimestamp` (patches/18/pg18-025-logical_commit_clock.diff) | **No**. Set to zero when shared memory is reinitialized (postmaster restart, crash restart) | Every commit, under the WAL insert spinlock | Commit-time adjustment of local `xact_time` |
| Exception classification marker | Shared-memory array `exception_log_ptr[total_workers]` (`SpockExceptionLog`: slot_name, commit_lsn, local_tuple, initial_error_message) (spock_worker.c:864-872) | No | `handle_begin` stamps `commit_lsn` on **every** BEGIN (spock_apply.c:837-838) | `handle_begin` decides `use_try_block` (replay mode) on the first BEGIN after restart |
| Add-node pause flag | `SpockCtx->pause_apply` atomic + `pause_cv` (one per postmaster, shared by all DBs) | No | `spock.pause_apply_workers()` / `resume_apply_workers()` (spock_functions.c:4060-4142); worker timeout clears it (spock_apply.c:575-580) | `maybe_pause_for_slot_creation` (spock_apply.c:564-586) |
| Output slot-group state | `SpockCtx->slot_groups[]` (`last_lsn`, `last_commit_ts`, nattached) (spock_output_plugin.c:1280-1383) | No | walsenders whose slot name ends in `_<digit>` | Decides whether to skip a txn (`slot_group->last_lsn >= txn->end_lsn`, :561) and the COMMIT_ORDER message |
| Feedback mapping | Per-process `lsn_mapping` list (local_end ↔ remote_end) and `sync_replica_lsn` list (spock_apply.c:173, 3082-3235) | No (process memory) | handle_commit | send_feedback |
| Replay queue for exception handling | Per-process `ApplyReplayContext` + `BufFileCreateTemp` spill (spock_apply.c:148, 5051) | No | apply_work | in-process replay after an ERROR |
| Table sync handshake | `local_sync_status.sync_status` and `sync_statuslsn` (catalog) + `worker.apply.replay_stop_lsn` (shmem) + `MyApplyWorker->sync_pending` | Mixed | apply worker `process_syncing_tables` (spock_apply.c:4455-4635), sync worker `spock_sync_main` | both |
| Conflict counters | pgstat custom kind 29, `write_to_file=true` (spock_conflict_stat.c:62-80), PG18+ only | Saved only on clean shutdown (pgstat drops stats after crash recovery) | apply worker | `spock.get_subscription_stats` |
| Sequence state | `spock.sequence_state` (seqoid, cache_size, last_value) | Yes | `spock.sync_seq()` only. The periodic `synchronize_sequences()` (spock_sequences.c:84) **has no caller** in src/ | queue → `handle_sequence` on subscriber |

---

## 2. Findings

### F1. Add-node resume LSN read relies on a pause that can expire or be bypassed (possible permanent row loss on the new node)

Path: the new node's sync worker → `spock_create_slot_and_read_progress()` (spock_sync.c:650-866):
1. `SELECT spock.pause_apply_workers()` on the provider P (:704).
2. `CREATE_REPLICATION_SLOT ... LOGICAL spock_output` over the replication connection; this returns the snapshot used for COPY (:718-748).
3. Import the snapshot, then `spock.read_peer_progress()` (sql/spock--6.0.0.sql:127-200), which returns, for each peer C, `resume_lsn = pg_replication_origin_status.remote_lsn` of P's subscription from C.
4. `resume_apply_workers()`.
Later, `spock_group_progress_force_set_list()` stores those LSNs in the new node's `SpockGroupHash` and resource.dat (spock_group.c:755-826). Z0DAN Phase 7 reads `spock.progress.remote_commit_lsn` on the new node and calls `pg_replication_slot_advance` on C and `pg_replication_origin_advance` locally (zodan.sql:2638-2671).

**CLAIM** (read_peer_progress comment): "With apply workers paused, ros.remote_lsn is exact: it reflects only committed transactions whose effects are visible in the slot snapshot."

Ways it can break:
- **The pause times out while slot creation is still running.** Each paused worker sleeps with `ConditionVariableTimedSleep(..., spock_pause_timeout*1000)`. On timeout it clears the global flag itself and carries on applying (spock_apply.c:572-580; GUC `spock.pause_timeout`, default 10 s, spock.c:177, 1353). `CREATE_REPLICATION_SLOT` has to wait for P's running transactions to finish before its snapshot is consistent, so a long local transaction on P, or a paused or slow P process, can push it past 10 s. Nothing in the sync code checks afterwards that the workers stayed paused. If C's transaction T is applied on P after the slot snapshot and before step 3, then:
  - T is missing from the COPY snapshot;
  - P's slot for N does not send T, because it is a forwarded origin and the default `forward_origins={}` filters it out;
  - `ros.remote_lsn` already counts T, so N's slot on C is advanced past T.
  T is never applied on N.
- **The paused check uses the xid.** `spock_pause_apply_workers` treats a worker as paused when `w->proc->xid` is invalid (spock_functions.c:4097-4098). The pause check itself only runs in `begin_replication_step` when `!IsTransactionState()`, and in `handle_commit` (spock_apply.c:600-612, 1185). A worker that has started its local transaction but has not yet been assigned an xid (the xid comes with the first heap write) passes as "paused" and goes on to commit. That is the same window as above, but it needs no timeout, only an unlucky interleaving. `w->proc == NULL` (a worker still starting) is also skipped (:4090).
- **The pause is not tied to the caller's session.** If the sync worker dies with SIGKILL, or is partitioned, between pause and resume, P's workers stay paused until their timeout. The sync worker only makes a best-effort resume in PG_CATCH (spock_sync.c:1634-1648), and it only happens if the connection still works. `SpockCtx->pause_apply` is one flag for the whole postmaster: pausing one database pauses apply in every database.
- **A missing progress row silently drops a peer.** `read_peer_progress` INNER JOINs `spock.progress`, which is shared memory. If P has no `SpockGroupHash` entry for (P, C), C is left out with no error. That happens after a P crash/restart when resource.dat has no entry for that pair (resource.dat comes only from the last clean shutdown) and P's apply worker from C has not started yet, for example because the subscription is disabled or the manager has not relaunched it. Z0DAN then logs "No spock.progress entry … falling back to pg_current_wal_lsn()" (zodan.sql:2643-2648) and advances N's slot on C to C's current WAL end. Any C transaction that P had not applied by snapshot time is skipped on N.

Antithesis angle: run add_node (Z0DAN) under load from ≥2 writers while pausing or killing P's processes, adding latency on P↔N, and holding a long transaction on P. Oracle: after quiescence every table matches on every node, and `spock.exception_log` is empty when the workload never conflicts.

### F2. `SpockGroupHash` only grows; entries are never deleted, and resource.dat brings them back

- Size is fixed: `ShmemInitHash(..., nworkers, nworkers, HASH_FIXED_SIZE|HASH_PARTITION)` with `nworkers = max_worker_processes` (spock_group.c:137-171; spock_shmem.c:116).
- The comment "Entries are never deleted during normal operation" (spock_group.c:41-42) is accurate. `sub_drop`/`node_drop` do not remove entries (spock_functions.c:762-866). Every clean shutdown writes all entries to resource.dat (`spock_supervisor_on_exit`, spock.c:877-897), and every startup loads them all back (spock_group.c:621-704).
- Node ids are 16-bit hashes of the node name (spock_node.c:368-371), so each new peer name adds a new key. A node that goes through repeated add/remove-node cycles with fresh names gains about one entry per peer, and per peer on the new node during force-set.
- When the hash is full, PG's dynahash with `HASH_ENTER` on a shared table raises `ERROR "out of shared memory"` (SQLSTATE 53200). It does not return NULL. (This is an assumption about PG internals; see Assumptions.) So the `entry == NULL` checks in spock_group.c:219, 268, 413, 777 and spock_progress_recovery.c:175 never run. Effects:
  - `spock_group_attach` and `reconcile_progress_with_origin` raise ERROR at worker start, and the apply worker restart-loops.
  - `spock_group_resource_load` runs in the postmaster's `shmem_startup_hook`. An ERROR there aborts postmaster startup, so the node will not start. This happens if resource.dat holds more entries than fit, for example after many cycles, or after lowering `max_worker_processes`.
  - In the apply worker, class 53 errors are treated as transient and retried forever (spock_apply.c:3966-3971).
- The hash key has no subscription id. Two subscriptions to the same provider (not prevented; see the comment at spock_apply.c:1279-1283) share one progress entry, and their reconciles fight (STALE/ANOMALY flip-flop).

A similar leak exists in the shared-memory exception-log slots: `handle_begin` claims a slot per **subscription name** (spock_apply.c:760-813, "TODO: What happens if a subscription is dropped? Memory leak"). `clear_exception_log_entry` never clears `slot_name` (spock_apply.c:387-395). After `total_workers` distinct subscription names since postmaster start, the next new subscription fails at its first BEGIN with "unable to find an empty exception log slot" and restart-loops. Only a postmaster restart clears the slots.

### F3. resource.dat: when it is written, concurrent writers, and stale files

- Writers: supervisor at clean shutdown (code==0 only); sync worker after add_node force-set (spock_group.c:822); sync worker after a table COPY (spock_group.c:734, via `copy_tables_data`, spock_sync.c:1308-1309).
- `spock_group_resource_dump` (spock_group.c:534-611) always writes the same temp path `spock/resource.dat.tmp` with `O_TRUNC`, takes `apply_group_master_lock` only in **LW_SHARED** mode, and then calls `durable_rename`. So two dumpers can run at once: two sync workers for different subscriptions or databases, or a shutdown dump while a sync worker is still running (the supervisor's drain wait gives up after a fixed number of retries and dumps anyway, spock.c:885-893). They write the same tmp file. One rename succeeds and the other fails with ENOENT → `ereport(ERROR)`. In the sync worker that ERROR happens inside `PG_ENSURE_ERROR_CLEANUP(spock_sync_worker_cleanup_error_cb)` (spock_sync.c:1655-1736), which drops the remote slot and the local origin. The subscription status stays `d` (DATA) and is then disabled with FATAL on restart (see F6). The renamed file can also mix two writers' bytes. It has no CRC ("XXX: Do we need any kind of CRC here?", spock_group.c:683), and a short read in the loader is an ERROR during postmaster startup.
- Nothing deletes resource.dat after loading or after a crash. Each crash restart reloads the **last clean-shutdown** snapshot and drops the live in-memory progress (a crash restart reinitializes shared memory). Reconcile at worker start then trusts the origin. **CLAIM** (spock_group.c:23-37 and docs/internals-doc/specs/spock-progress-no-checkpoint-hook-design.md): the progress hash is monitoring data, and the replication origin alone decides the resume point. The same design doc also says the force-set entries are "*deduplication state* for forwarded transactions in a mesh (not just monitoring), so they must be crash-durable". The only reader that depends on them for correctness is Z0DAN Phase 7 (F1).
- The system-identifier check protects against copying PGDATA between clusters, not between a primary and its physical clone (same sysid).

### F4. Reconcile can reset add-node progress to zero

`reconcile_progress_with_origin` (spock_progress_recovery.c:153-275) runs at **every** apply-worker start (spock_apply.c:4753), not only after a crash:
- If the entry exists and file LSN > origin LSN (ANOMALY), the origin wins: `remote_commit_lsn = origin_lsn` and the timestamps are cleared.
- On the new node, force-set wrote `remote_commit_lsn = resume_lsn` for (N, C) **before** Z0DAN Phase 7 creates or advances the origin for N's subscription from C. If that subscription's apply worker starts before Phase 7 (enabled early, or the operator retries add_node after a partial failure), reconcile resets the entry to the origin LSN (0/0 or wherever it is). Phase 7 then reads `target_lsn <= current_lsn` and skips the advance (zodan.sql:2650-2653), or falls back to `pg_current_wal_lsn()`.
- STALE/ABSENT also triggers a backward `pg_commit_ts` scan of up to 1M xids (spock_progress_recovery.c:295-380) before replication starts. This makes startup slower on a busy node. It filters on the remote node id, which is not unique to one subscription (comment :129-132).

### F5. Commit and origin advance: consistency, and the in-flight / abort paths

- Normal commit: the origin advance travels in the same commit record (`replorigin_session_origin_lsn = end_lsn`, spock_apply.c:1003-1009, then `CommitTransactionCommand`). Apply runs with `synchronous_commit=off` unless `spock.synchronous_commit` is set (spock_apply.c:4700-4702; default false, spock.c:165). A crash can lose recently applied transactions together with their origin advance. That is consistent, provided feedback never reports an unflushed commit as flushed. `get_flush_position` (spock_apply.c:3082-3117) only reports `remote_end` once `local_end <= GetFlushRecPtr()`. With no outstanding entries, `send_feedback` reports `flush = recvpos` (3265-3272), the same as PG core. A sync-standby variant exists (`append_feedback_position`, fix 5f654e34).
- `send_feedback(last_received)` runs after **every** message, including in the middle of a transaction (spock_apply.c:3830-3836). In the middle of a transaction `lsn_mapping` is empty, so flush = the LSN of the change just received. That is below the commit LSN, so the provider resends the transaction, as in core.
- Progress-hash update and forwarded-origin advance both happen **after** `CommitTransactionCommand`:
  - `maybe_advance_forwarded_origin` calls `replorigin_advance(forwarded_local_origin_id, remote_origin_lsn, local_lsn, go_backward=false, wal_log=true)` as a separate WAL record (spock_apply.c:1146, 5165-5183). A crash between the commit and that record loses the forwarded-origin advance. If the matching direct subscription is enabled later, it re-receives transactions that already arrived through the forwarder (insert_exists / update conflicts).
  - Commit 2948d567 refuses configurations where a forwarding subscription and another enabled subscription coexist, because concurrent ownership makes `replorigin_advance` fail with ERRCODE_OBJECT_IN_USE, which then disables the forwarder. Its own comment: "This catalog check cannot prevent worker races or direct catalog changes." The window is a worker that is still running between sub_disable/enable and its exit.
- Empty transactions (for example a sync_event, or all changes filtered out) advance the origin with `replorigin_session_advance(end_lsn, InvalidXLogRecPtr)` (spock_apply.c:1113-1131). This writes no WAL. The advance only lasts once a checkpoint saves origin state. After a crash `remote_lsn` can fall back below a sync_event LSN that `spock.wait_for_sync_event` (which reads `pg_replication_origin_status`, sql:740-745) already reported as reached. The provider will not resend it, because its slot already got flush ≥ that LSN. The origin stays behind until the next non-empty transaction from that provider. Oracle impact: a "sync reached" observation is not stable across a subscriber crash.
- Abort path: `handle_begin` sets `replorigin_session_origin_lsn = commit_lsn` (the start of the remote commit record) before applying (spock_apply.c:686). Commit d286f3df explains that `RecordTransactionAbort` moves the origin to that LSN if the session origin variables are still set. The fix clears them in a `before_shmem_exit` callback (spock_apply.c:2305-2325) and relies on callback ordering (LIFO). The **in-process** PG_CATCH replay path (data errors, TRANSDISCARD/DISCARD/SUB_DISABLE) still aborts with the variables set. As a result `ros.remote_lsn` can show a remote transaction that has not been applied (also relevant to F1's "only committed state" claim). Whether a restart at exactly `commit_lsn` resends that transaction or skips it is an open question (Q3). d286f3df calls it a skip and loss mode.
- The comment at spock_apply.c:3894 refers to `flush_progress_if_needed(true)`, which no longer exists. The comment is stale.

### F6. Initial and table sync state machine: crashes during sync are not recoverable

- `spock_sync_subscription` (spock_sync.c:1488-1810). Only `INIT` and `CATCHUP` can resume after a crash (:1517-1519). A crash or SIGKILL while the status is `s` (structure), `d` (data) or `c` (constraints) leads, on restart, to `spock_disable_subscription` + `FATAL "initialization failed during nonrecoverable step"` (:1521-1546). The origin was advanced to the slot LSN in a separately committed transaction **before** the COPY (:1677-1688). The `PG_ENSURE_ERROR_CLEANUP` that drops the slot and origin only fires on ERROR/FATAL, not on SIGKILL or power loss. After a hard crash the remote slot is left behind (its WAL retention keeps growing on the provider until the next attempt drops it, :666-676).
- Per-table sync (`spock_sync_table`, :1816-1919). Any status other than INIT when a sync worker starts is turned into `FAILED` (:1851-1866). So a sync worker killed in `p`/`d`/`w`/`u` leaves the table permanently FAILED. `should_apply_changes_for_rel` (spock_apply.c:464-483) returns false for FAILED (and every other status that is not READY / caught-up SYNCDONE). The apply worker therefore **silently skips all changes for that table** while advancing the origin, and the table drifts with no error. `process_syncing_tables` only `Assert`s that the sync worker is alive when the status is SYNCWAIT (spock_apply.c:4527); in production builds it just waits. `replay_stop_lsn` lives only in shared memory.
- In the add_node force-set, the progress hash and resource.dat are written after the COPY commits but before `local_sync_status` rows are marked READY (spock_sync.c:1736-1768).

### F7. The logical commit clock (pgEdge core patch) does not survive a restart

`EnsureMonotonicTransactionStopTimestamp` (patches/18/pg18-025-logical_commit_clock.diff) keeps `XLogCtl->lastTransactionStopTimestamp`:
- remote applies push it up to max(remote ts, local ts);
- local commits get `xact_time = max(wall clock, clock+1)`.
The patch's own TODO: "This is not postmaster restart safe. If the local system clock is further behind other nodes than it takes for the postmaster to restart … local transactions will not be bumped into the future correctly." The clock starts again at 0 when shared memory is reinitialized. Nothing reseeds it from WAL or pg_commit_ts.
- Effect with clock skew plus a restart: a local UPDATE after the restart can get a commit ts lower than the remote version it overwrote. Under `last_update_wins` (the only allowed resolver, enforced by a GUC check per the design doc), peers then keep the older remote version. Convergence still holds because the comparison is deterministic, but "the last writer wins" in real time does not. Commit timestamps are also not monotonic in LSN order across a restart.
- Effect on `spock.progress`: `progress_update_struct` only moves `remote_commit_lsn` forward when `remote_commit_ts` increases (spock_group.c:319-334). A provider whose commit ts goes backwards (restart plus skew), or a forwarded transaction carrying an older origin ts, leaves `remote_commit_lsn` in the view behind the real origin. Z0DAN Phase 7 reads this column on the new node (it was force-set from ros, so not directly affected; F1/F4 are the bigger risks).
- Conflict resolution reads `pg_commit_ts` of the local tuple's xmin (spock_conflict.c:219-275). Frozen xmin or truncated commit_ts → `local_ts=0`, and the remote side always wins. When the timestamps are equal, the tiebreaker comes from `spock.node.info->tiebreaker`, which defaults to the node id (spock_node.c:499-532).
- `apply_delay` compares the remote commit ts with the local wall clock (spock_apply.c:887-905). Skew changes the actual delay.

### F8. Exception state in shared memory and silent discard (default TRANSDISCARD)

- Default `spock.exception_behaviour = transdiscard` (spock.c:1144-1151; spock_exception_handler.c:78). In DISCARD/TRANSDISCARD the origin advances past a failed transaction by design (spock_apply.c:1003-1009). The rows go to `spock.exception_log`, which is user_catalog_table heap and is written in the same (read-only) transaction.
- The decision to enter replay comes from shared memory: `exception_log_ptr[i].commit_lsn == BEGIN's commit_lsn` on the first BEGIN after an apply_work restart (spock_apply.c:829-879). Because every BEGIN stamps that marker, any non-data failure in the middle of a transaction that does not take the "transient" branch (spock_apply.c:3914-3971: connection class 08xxx subset, 57P01/57P02/57P03, deadlock 40P01, lock_not_available 55P03, class 53) is treated as a data fault, and the retransmitted transaction is **discarded**. Recent fixes in this area: ed0a9945 (SIGTERM mid-txn), 8dcfbcd5 (apply_idle_timeout raised as XX000), acf6cdae (stale use_try_block), f3d4935e (transient retry), d286f3df. Error sources not on the list that faults can trigger: 57014 query_canceled / statement_timeout, 40001 if the default isolation is changed, internal `elog(ERROR)` sites such as "a table synchronisation operation is failed" (spock_apply.c:4566), I/O errors (58xxx), and the "ORIGIN message sent out of order" protocol checks.
- A crash restart reinitializes this array. That clears the marker, which is safe.
- Oracle: with a workload that never conflicts, any new `spock.exception_log` / `exception_status` row, or a disabled subscription, is a bug.

### F9. Other state-handling notes (lower priority)

- `sub_drop` drops the **remote slot before the local transaction commits**, and the drop is not transactional (spock_functions.c:845-862). If the drop transaction then aborts, the subscription is left without a slot. If the provider is unreachable, the slot is orphaned on the provider (WARNING only), and the provider retains WAL with no limit.
- Output-plugin slot groups (only slot names ending `_<digit>`): `spock_output_leave_slot_group` changes `nattached` with the lock commented out (spock_output_plugin.c:1366-1383). Txn skipping relies on the shared `last_lsn`. Likely unused with default slot names (`gen_slot_name`).
- Node id is `hash(name) & 0xffff` and is used directly as the `RepOriginId` written into commit records and commit_ts (handle_origin). The collision check only compares against `spock.node` (spock_node.c:373-383), not against local `pg_replication_origin.roident` values, which share the same 16-bit space.
- Conflict stats (PG18+) use pgstat, which is reset on crash recovery and counts non-transactionally. They are not a reliable oracle across crashes.
- `synchronize_sequences()` is dead code. Sequence state only moves through manual `spock.sync_seq()`. That limits sequence-related properties to snowflake/other schemes outside this tree.
- Failover slots (spock_failover_slots.c) copy slot state to physical standbys. They matter only if the topology includes standbys.

---

## 3. Suggested properties / probes for Antithesis (state-focused)

1. **No lost committed writes after quiescence**: every row committed on any node (with the client acknowledged) exists on every node once faults stop. Run this under add_node (F1), table resync (F6), and subscriber/provider crashes (F5).
2. **Resume-position safety**: on each node, for each subscription, `pg_replication_origin_status.remote_lsn` ≤ the provider slot's `confirmed_flush` + ε, and nothing reported as flushed was missing after a crash. Measured indirectly by property 1.
3. **No spurious exception handling**: when the workload never conflicts, `spock.exception_log` stays empty and no subscription becomes disabled (F8).
4. **Restart liveness**: after any number of add/remove-node cycles plus clean restarts, every node starts and every apply worker reaches streaming (F2, F3).
5. **No permanently FAILED / non-READY sync rows** after quiescence (F6).
6. **Progress-view sanity** (weak, informational): `remote_insert_lsn >= remote_commit_lsn` and `received_lsn >= remote_commit_lsn`. The code has Asserts for these (spock_group.c:348-361, 449-451), so a cassert build turns violations into crashes that Antithesis would see.

---

## Areas examined

- src/spock_group.c, include/spock_group.h (shared-memory hash, resource.dat dump/load, force-set/update-list)
- src/spock_progress_recovery.c (reconcile, pg_commit_ts scan)
- src/spock_rmgr.c, include/spock_rmgr.h (rmgr 144)
- src/spock_shmem.c, src/spock.c (shmem hooks, supervisor exit dump, GUC defaults)
- src/spock_apply.c: handle_begin/commit/origin/commit_order, feedback, UpdateWorkerStats, apply_work loop and PG_CATCH classification, process_syncing_tables, should_apply_changes_for_rel, maybe_pause_for_slot_creation, forwarded-origin advance, spock_apply_main startup, shmem-exit callbacks
- src/spock_sync.c: slot+snapshot+peer progress, spock_sync_subscription / spock_sync_table / spock_sync_main, copy_tables_data
- src/spock_functions.c: pause/resume, sub_create ensure_entry, sub_drop, enforce_forwarding_exclusivity
- src/spock_conflict.c (LWW, tiebreaker, get_tuple_origin), src/spock_conflict_stat.c
- src/spock_output_plugin.c (slot groups, origin/commit-order messages)
- src/spock_sequences.c, src/spock_node.c (node id), src/spock_exception_handler.c (exception_behaviour default)
- sql/spock--6.0.0.sql (catalogs, spock.progress view, read_peer_progress, wait_for_sync_event)
- samples/Z0DAN/zodan.sql Phase 7 (2440-2680)
- patches/18/*: logical commit clock, per-subtransaction commit ts, attoptions
- docs/internals-doc/specs/spock-progress-no-checkpoint-hook-design.md
- git history: 2f9a686c, a4b93e87, 69722443, d286f3df, ed0a9945, 8dcfbcd5, acf6cdae, 2948d567, 401197ab, 5ee6276e, 11b9d385, 5f654e34, f3d4935e
- TAP test names in tests/tap/t (016_crash_recovery_progress is skipped per 69722443; 022/027/029/100 cover progress recovery; 046/105 cover misclassification)

## Assumptions

- PG dynahash: `hash_search(HASH_ENTER)` on a full shared `HASH_FIXED_SIZE` table raises `ERROR out of shared memory` (53200) instead of returning NULL. Only `HASH_ENTER_NULL` returns NULL. This is from knowledge of PG, not from this tree.
- PG ≥15 `RecordTransactionAbort` advances the session replication origin when `replorigin_session_origin` is set. Commit d286f3df and the comment at spock_apply.c:2313-2318 say so.
- Logical decoding skips a transaction iff its commit record start `< start_decoding_at`. The walsender raises a requested start below `confirmed_flush` up to `confirmed_flush`. This is PG knowledge and matters for Q3.
- Killing any backend or bgworker with SIGKILL triggers a crash restart of the whole postmaster. Shared memory is reinitialized, which clears SpockGroupHash, the exception markers, the pause flag and the logical clock.
- Commit timestamps in `pg_commit_ts` for applied transactions carry the remote commit ts and the remote spock node id as origin (stock PG behaviour when `replorigin_session_origin_timestamp` is set; consistent with spock_progress_recovery.c:122-128).

## Open Questions

1. Q1: Does any process check, after `read_peer_progress`, that apply workers on the provider stayed paused for the whole window between slot creation and the progress read? None was found. Is losing T in F1 reproducible by forcing `CREATE_REPLICATION_SLOT` to take longer than `spock.pause_timeout`?
2. Q2: In the field, are subscriptions on a new node ever started before Z0DAN Phase 7 advances their origins (F4)? Does Z0DAN retry after a partial failure reuse the stale force-set entries?
3. Q3: After an in-process data-error abort (origin moved to the in-flight `commit_lsn`), is the transaction resent when restart starts exactly at `commit_lsn`? d286f3df says it is skipped; snapbuild semantics suggest it is resent. Testing should decide.
4. Q4: Is the shared temp file name in `spock_group_resource_dump` ever written by two processes at once in practice? Can Z0DAN or `sub_resync_table` run syncs in parallel on one node?
5. Q5: What is the intended recovery for a table left `FAILED` (F6)? Is silently skipping its changes intended, or should the apply worker stop?
6. Q6: Can `slot_group` mode (slot names ending `_N`) be reached with default configuration? If not, the `wait_for_previous_transaction` / `prev_remote_ts` paths are dormant.
7. Q7: The design doc says force-set entries are "deduplication state" while code comments say the progress hash is "informational". Which is the contract? It decides whether F3/F4 are correctness bugs or monitoring bugs.
