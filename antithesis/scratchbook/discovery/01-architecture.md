# 01 — Architecture and Data Flow (Spock @ 69d9228f, branch main)

Focus: components, process boundaries, wire protocol, request path from a local
commit to an applied commit on a peer, subscription creation / initial sync,
DDL and sequence replication, ZODAN add/remove node, catalogs, SQL API, and
the PostgreSQL core patches. Claims from docs/comments are marked **CLAIM**;
things I believe from reading code but have not run are marked **LEAD**.

---

## Findings

### F1. Process map (who runs where)

All Spock code runs inside the postmaster of each node (loaded through
`shared_preload_libraries`; `_PG_init` errors otherwise, `src/spock.c:1118`).
No external daemon. Per node:

| Process | Entry | Started by | Restart policy | Job |
|---|---|---|---|---|
| **supervisor** (1 per instance) | `spock_supervisor_main` `src/spock.c:903` | static bgworker registered in `_PG_init` (`src/spock.c:1505-1518`), `BgWorkerStart_RecoveryFinished`, `bgw_restart_time=5` | postmaster, 5 s | Scans `pg_database`; registers one manager per connectable DB (`start_manager_workers`, `src/spock.c:788`). Wakes on `SpockCtx->subscriptions_changed` or every 180 s. On clean exit waits up to 5 s for apply workers, then dumps `resource.dat` and writes a `SPOCK_DUMP_SHUTDOWN` WAL record (`spock_supervisor_on_exit`, `src/spock.c:878`). |
| **manager** (1 per DB) | `spock_manager_main` `src/spock_manager.c:178` | supervisor via `spock_worker_register` (dynamic bgworker, `BGW_NEVER_RESTART`) | supervisor re-registers when `terminated_at` set & `subscriptions_changed` | Exits at once if no `spock` extension. Runs `ALTER EXTENSION spock UPDATE` if the .so version differs (`spock_manage_extension`, `src/spock.c:560`). Loop `manage_apply_workers()` (`src/spock_manager.c:39`): start an apply worker per enabled subscription where this node is target; honor `restart_delay` after a crash; SIGTERM workers whose sub is gone/disabled. |
| **apply** (1 per enabled subscription) | `spock_apply_main` `src/spock_apply.c:4677` | manager | manager after `restart_delay` (`spock.restart_delay_default`=5000 ms; `spock.restart_delay_on_exception`=0 once data starts flowing, set in `handle_begin`) | Runs initial sync if needed, then streams from provider walsender and applies. |
| **sync** (per table being (re)synced) | `spock_sync_main` `src/spock_sync.c:1960` | apply worker (`start_sync_worker`, `src/spock_apply.c:4638`) | — | COPY one table, then catch up to a `replay_stop_lsn` handed over by the apply worker, then exit. |
| **walsender + `spock_output` plugin** (provider side, 1 per subscriber connection) | stock PG walsender; plugin callbacks in `src/spock_output_plugin.c` | subscriber's `START_REPLICATION` | — | Logical decoding; filters by replication set; writes native protocol. |
| **spock_failover_slots worker** (PG < 18 only) | `spock_failover_slots_main` `src/spock_failover_slots.c:1321` | static bgworker in `spock_init_failover_slot` (`src/spock_failover_slots.c:1837`), `BgWorkerStart_ConsistentState`, restart 60 s | postmaster | On a physical standby, copies logical slots from primary (`spock.synchronize_slot_names`, `spock.primary_dsn`, `spock.failover_slots_naptime`); on primary, `ClientAuthentication_hook` + `spock.pg_standby_slot_names` make walsenders wait for standby confirmation. On PG17+/18 slots are created with `(FAILOVER)` and native slot sync is the documented path (`docs/configuring.md:~330`). |

Worker bookkeeping lives in shared memory `SpockCtx` (`include/spock_worker.h`:
`SpockContext`, `SpockWorker[]`) guarded by `SpockCtx->lock` (LWLock). Each slot
has a `generation` counter used by `wait_for_worker_startup`
(`src/spock_worker.c:217`) to tell "my worker crashed before attaching" from
"slot reused". On error exit `spock_worker_detach(crash=true)` sets
`terminated_at` and latches the manager (`src/spock_worker.c:410`). Catalog
changes (sub create/enable/disable/drop) signal workers only at COMMIT through
`signal_worker_xact_callback` (`src/spock_worker.c:679`); comment notes this is
"not fully transactional" (sub-xact aborts still fire on COMMIT).

Other shared state: `SpockGroupHash` (apply progress per (dbid, node_id,
remote_node_id), `src/spock_group.c`), `SpockCtx->slot_groups` (output-side
"slot groups", see F9), per-worker `exception_log_ptr[]` (exception replay
state keyed by subscription name), `SpockCtx->pause_apply` + `pause_cv` (F6),
stats hash `SpockHash`.

Hooks installed (`spock_executor_init`, `src/spock_executor.c:328`):
`ProcessUtility_hook` (AutoDDL + `spock.deny_all_ddl`), `object_access_hook`
(dependency checks on DROP), `post_parse_analyze_hook` and `ExecutorStart_hook`
(read-only mode, `src/spock_readonly.c`), `emit_log_hook` (message filter).
Custom WAL rmgr id 144 (`src/spock_rmgr.c`) — only "resource dump" marker
records now; redo just logs.

### F2. Data path: local commit → peer commit

```
client txn on N1 ──commit──► N1 WAL (commit record, ts bumped by Lamport hook, patch 025)
   │
   ▼ (walsender for slot spk_<db>_<N1>_<sub> on N1)
 logical decoding (reorder buffer, waits for commit)
   ├─ pg_decode_origin_filter: drop txns with origin != local unless sub.forward_origins non-empty
   ├─ pg_decode_begin_txn: slot-group claim (F9); write 'B', then 'O' (origin node id + origin_lsn + name), 'L' (commit-order ts)
   ├─ pg_decode_change: spock_change_filter (repset membership, insert/update/delete flags, row filter, column list,
   │                    special-cases spock.queue and spock.replication_set) → 'R' (relation meta, once per rel) + 'I'/'U'/'D'
   ├─ pg_decode_truncate → 'T';  pg_decode_message (prefix "Spock") → 'M' (sync_event, repair mode on/off)
   └─ pg_decode_commit_txn: optional SyncRepWaitForLSN(end_lsn - walsender_idx); write 'C'
   │
   ▼ CopyBoth 'w' frames (proto v5: every 'w' payload begins with remote_insert_lsn)
N2 apply worker apply_work() (src/spock_apply.c:3398)
   ├─ 'w' → replication_handler → handle_begin / handle_origin / handle_commit_order / handle_relation /
   │        handle_insert|update|delete (→ spock_apply_heap_*) / handle_truncate / handle_startup / handle_message
   ├─ 'k' keepalive → send_feedback(endpos)
   ├─ handle_commit: wait_for_previous_transaction() (commit-order CV), advance origin LSN, set
   │                 remoteTransactionStopTimestamp, CommitTransactionCommand(), push lsn_mapping, update SpockGroupHash
   └─ send_feedback: write=recv, flush=highest remote_end whose local commit LSN <= local WAL flush ptr
```

Key details:

* **Connection**: `spock_connect_base` (`src/spock.c:~360-470`) forces
  `connect_timeout=30`, TCP keepalives idle 10 / interval 5 / count 3,
  `replication=database`, and `-c datestyle=ISO -c intervalstyle=postgres -c
  extra_float_digits=3`. `spock.extra_connection_options` adds more.
* **Start**: `spock_apply_main` → `replorigin_session_setup(origin named
  sub.slot_name)` → `origin_startpos = replorigin_session_get_progress()` →
  `IDENTIFY_SYSTEM` → `START_REPLICATION SLOT ... LOGICAL <origin_startpos>`
  with options `min/max_proto_version`, `binary.*` compatibility params,
  `spock.forward_origins`, `spock.replication_set_names`, `pg_version`,
  `spock_version(_num)` (`spock_start_replication`, `src/spock.c:697`). Then
  `request_initial_status_update` forces a keepalive so lag stats fill in fast.
  The provider starts from max(requested, slot `confirmed_flush`) (stock PG).
* **Apply session**: `synchronous_commit` = `local` if `spock.synchronous_commit`
  else **`off` (default)**; `session_replication_role=replica` (user triggers
  don't fire unless ENABLE REPLICA/ALWAYS); `check_function_bodies=off`
  (`src/spock_apply.c:4699-4716`).
* **Feedback**: `send_feedback` (`src/spock_apply.c:3237`). If every applied
  commit is flushed locally, it reports flush = recvpos (last 'w' start or
  keepalive endpos). With a sync standby defined, positions are held back until
  the standby confirms (`append_feedback_position`/`get_feedback_position`).
  Under `use_try_block` with TRANSDISCARD/SUB_DISABLE, end-of-batch feedback is
  suppressed (`src/spock_apply.c:3833-3845`).
* **Liveness**: socket readable/latch every 1 s; CONNECTION_BAD → ERROR tagged
  `ERRCODE_CONNECTION_FAILURE`; `spock.apply_idle_timeout` (300 s, SIGHUP) →
  same tag. TCP keepalive is the main dead-peer detector (~25 s).
* **Error classification in `PG_CATCH`** (`src/spock_apply.c:3862-4010`):
  connection-class sqlstates (08006/08000/08003/57P01/57P02/57P03) or
  `PQstatus==CONNECTION_BAD` → clear transient state, `restart_delay=default`,
  rethrow (worker exits, origin not advanced, txn re-streamed). Deadlock
  (40P01) / lock_not_available (55P03) / class 53 → `prepare_transient_error_retry`
  + rethrow (indefinite retry). Anything else on first occurrence → abort,
  `apply_replay_queue_start_replay()`, `use_try_block=true`, replay the
  buffered transaction from `ApplyReplayContext` (spills to disk after
  `spock.exception_replay_queue_size` MB) under `spock.exception_behaviour`:
  `discard` (per-row subtxn, skip failing rows), **`transdiscard` (default;
  whole txn made read-only, every row logged to `spock.exception_log`, then
  origin advanced past it)**, `sub_disable` (log, disable subscription, origin
  NOT advanced). A second error while in try mode → rethrow and restart.
  Serialization failures (40001) are explicitly *not* treated as transient
  (comment at `src/spock_apply.c:~3935`).
  Fix history to cite: `8dcfbcd5` (idle-timeout misclassified as data error →
  TRANSDISCARD dropped good rows), `d286f3df` (connection loss leaking origin
  advance), `f3d4935e` (transient retry), `19_stale_fd`/`101`/`102` TAP tests.
* **Origin advance at commit** (`handle_commit`, `src/spock_apply.c:912-1270`):
  `replorigin_session_origin_lsn = end_lsn` unless (exception && SUB_DISABLE).
  Empty transactions advance the origin explicitly with
  `replorigin_session_advance(end_lsn)`. Non-transactional `sync_event`
  messages also advance it directly (`handle_message`, `src/spock_apply.c:2955`).
  Forwarded transactions additionally advance a *second* origin — the local
  origin of a (possibly disabled) subscription to the original source —
  via `maybe_advance_forwarded_origin` (`src/spock_apply.c:5165`, WAL-logged
  `replorigin_advance`), used by ZODAN to pre-position subscriptions.
* **`replay_stop_lsn`**: sync workers (and limited replay) exit cleanly once
  `end_lsn >= replay_stop_lsn`; sync worker marks table `SYNCDONE`.

### F3. Origin identity: node id is used as RepOriginId (important)

* `spock.node.node_id` = `hash_any(node_name) & 0xffff` unless given
  (`create_node`, `src/spock_node.c:~366`); collisions are now rejected
  (`024_node_id_collision.pl`).
* The provider writes `MyOutputNodeId` (its node id) as the origin of local
  txns, and the stored `txn->origin_id` for forwarded ones
  (`pg_decode_begin_txn`, `src/spock_output_plugin.c:~600-630`).
* The subscriber sets `replorigin_session_origin = remote_origin_id` (a **node
  id**, not the `pg_replication_origin.roident` of the slot-named origin) in
  `handle_origin` (`src/spock_apply.c:1301-1340`). So commit records and
  `pg_commit_ts` on the subscriber carry the *origin node id*; the progress
  (`remote_lsn`) is tracked in the session state of the slot-named origin.
  The design doc says this explicitly
  (`docs/internals-doc/specs/spock-progress-no-checkpoint-hook-design.md`, Phase 3).
* Conflict resolution reads the local tuple's origin/ts from `pg_commit_ts`
  (`get_tuple_origin`, `src/spock_conflict.c:219`) and compares against
  `replorigin_session_origin` / `replorigin_session_origin_timestamp`.
* **LEAD (needs verification, high value for crash faults):** stock
  `xact_redo_commit` replays origin progress with
  `replorigin_advance(XLogRecGetOrigin(record), ...)`, i.e. with the **node
  id**, not the slot-named origin. If that is right, after a subscriber crash
  the slot-named origin's `remote_lsn` falls back to the last checkpoint's
  `replorigin_checkpoint`, not to the last durable commit. The provider then
  restarts at max(origin LSN, `confirmed_flush`). Any transaction that was
  committed+flushed on the subscriber but not yet confirmed back to the
  provider (feedback window; apply runs with `synchronous_commit=off`, so
  `lsn_mapping` entries wait for the WAL writer) would be **applied twice**.
  Plain row images mostly converge (INSERT→`insert_exists` same-origin →
  apply remote; DELETE→`delete_missing`), but **delta-apply columns
  (`delta_apply_function` attoption) would double-count**, and duplicate
  rows go through conflict logging / exception paths. A provider crash that
  also rolls back `confirmed_flush` widens the window. Redo would also need
  free replication-state slots for node-id "origins" (2× per peer). Worth a
  targeted Antithesis property: "no remote transaction is applied twice".
  None of the TAP tests I saw assert this (`016_crash_recovery_progress` is
  skipped, commit `69722443`; `027_*` only checks `remote_commit_ts` not NULL).

### F4. Wire protocol (`spock_output` plugin)

* One plugin, two encodings: `native` (binary, default) and `json`
  (`pg_decode_startup`, `src/spock_output_plugin.c:226`; json only via
  `proto_format` option). Spec in `docs/internals-doc/protocol.md`,
  `OUTPUT.md`, `DESIGN.md` (inherited from pglogical).
* Protocol versions: `SPOCK_PROTO_VERSION_NUM 5`, min 4
  (`include/spock_output_proto.h:33`). Negotiated = min(server max, client
  max). v5 prefixes every 'w' with `remote_insert_lsn`; v4 sends it at the end of
  COMMIT. v4 requires both sides ≥ 5.0.0. Mixed versions are a supported
  rolling-upgrade state (`014_rolling_upgrade.pl`, `099_zodan_mixed_version.pl`).
* Messages: `S` startup (sent lazily on first BEGIN or first sync_event),
  `B` begin(final_lsn, commit_ts, xid), `O` origin(node id, origin_lsn, name),
  `L` commit order (slot group's previous commit ts), `R` relation
  metadata (cached per walsender, invalidated by relcache callback), `I/U/D`
  rows (old key or full old tuple depending on replica identity, plus columns
  with `log_old_value`), `T` truncate, `M` logical message (prefix `Spock`;
  types `SPOCK_REPAIR_MODE_ON/OFF`, `SPOCK_SYNC_EVENT_MSG`), `C` commit(commit_lsn, end_lsn, ts).
* Binary datums: internal format only if all `binary.*` params match
  (`check_binary_compatibility`); binary send/recv if same PG major; else text.
  `force_text_transfer` sub option forces text.
* No downstream-to-upstream messages other than standby status updates
  ('r'); the downstream can't refuse data except by disconnecting (DESIGN.md).
* Unknown startup params are ignored both ways (**CLAIM**, DESIGN.md).
* Commit path on provider calls `SyncRepWaitForLSN(end_lsn - MyWalSenderIdx)`
  so a txn isn't sent to Spock peers before a physical sync standby has it
  (`pg_decode_commit_txn`, `src/spock_output_plugin.c:669`). Hack: subtracts
  walsender index from end_lsn to keep queue entries unique.
* `spock.output_delay` GUC sleeps in BEGIN (test knob); injection point
  `spock-output-txn-stall` after BEGIN is written.

### F5. Conflict handling on apply

* Row lookup: replica identity / PK index (`FindReplTupleInLocalRel`), optional
  all unique indexes for INSERT (`spock.check_all_uc_indexes`,
  `FindReplTupleByUCIndex`) — `src/spock_apply_heap.c:394-485`.
* Resolver GUC `spock.conflict_resolution` (default `last_update_wins`;
  check hook requires `track_commit_timestamp=on`). `conflict_resolve_by_timestamp`
  (`src/spock_conflict.c:99`): compare remote commit ts vs local tuple commit
  ts; equal → same origin → apply remote; else tiebreaker from
  `spock.node.info->tiebreaker` (lower wins locally); equal tiebreakers → apply
  remote + WARNING. **Correctness depends on wall clocks across nodes** —
  direct clock-skew target.
* Delta apply (`spock_handle_conflict_and_apply`, `src/spock_apply_heap.c:589`):
  if a table has `delta_apply_function` columns, even a "keep local" outcome
  is turned into an update that adds (new−old) to the current value, executed
  in a subtransaction whose commit ts / origin is overridden to the *local*
  tuple's ts/origin via `SubTransactionIdSetCommitTsData` (patch 030).
* Conflicts are logged to server log and, if `spock.save_resolutions`, to
  `spock.resolutions` (cleaned daily by the apply worker,
  `spock.resolutions_retention_days`). PG18 adds pgstat conflict counters.
* Types: `insert_exists`, `update_origin_differs`, `update_exists`,
  `update_missing`, `delete_origin_differs`, `delete_missing`,
  `delete_exists` (`docs/conflict_types.md`). `update_missing` → the row is
  converted to an insert? (see `spock_apply_heap_update`, not traced fully).

### F6. Subscription creation and initial sync

SQL `spock.sub_create(name, provider_dsn, replication_sets =
'{default,default_insert_only,ddl_sql}', synchronize_structure=false,
synchronize_data=false, forward_origins='{}', apply_delay, force_text_transfer,
enabled=true, skip_schema)` → `spock_create_subscription`
(`src/spock_functions.c:~560-770`):

1. Connect to provider, read `spock_remote_node_info`, create local copies of
   the provider's `spock.node` / `node_interface` rows.
2. Insert `spock.subscription` row; slot name `spk_<db>_<provider>_<sub>`
   (`gen_slot_name`, `src/spock_functions.c:3666`; each part ≤16 chars via
   `shorten_hash`, invalid chars → `_`).
3. `spock_group_ensure_entry` for progress.
4. `spock.local_sync_status` row: kind `i`/`s`/`d`/`f`, status `i` (INIT) if
   enabled; if created **disabled** (the ZODAN path) status is set READY and
   the replication origin is created immediately — no sync is done.
5. On COMMIT the manager is latched and starts the apply worker.

Apply worker → `spock_sync_subscription` (`src/spock_sync.c:1488`):
* `READY` → nothing. `INIT`/`CATCHUP` → (re)run. Any other status
  (`STRUCTURE`, `DATA`, `CONSTRAINTS`) → **subscription is disabled and the
  worker FATALs** ("nonrecoverable step"). So a crash/kill/network cut during
  data copy needs manual re-creation. Antithesis kill during COPY will hit this.
* INIT steps: SQL conn + replication conn to provider →
  `spock_create_slot_and_read_progress` (`src/spock_sync.c:650`):
  drop inactive old slot → **`SELECT spock.pause_apply_workers()` on the
  provider** → `CREATE_REPLICATION_SLOT ... LOGICAL spock_output [(FAILOVER)]`
  → import exported snapshot in REPEATABLE READ → read peer progress
  (`spock.read_peer_progress()` or legacy query on `spock.progress` +
  `pg_replication_origin_status`) → `spock.resume_apply_workers()`.
* Then, in its own committed txn, create/advance the local origin to the slot
  LSN **before** copying data (`src/spock_sync.c:1675-1690`). Then optional
  `pg_dump`/`pg_restore` pre-data (subprocess, temp file in
  `spock.temp_directory`), COPY of every table in the repsets
  (`copy_replication_sets_data`), set `SpockGroupHash` progress from the peer
  rows (`spock_group_progress_force_set_list`), table sync rows READY, post-data
  restore, status CATCHUP → READY.
* `pause_apply_workers` (`src/spock_functions.c:4060`) sets an
  **instance-wide** atomic flag (not per DB) and polls ≤ `spock.pause_timeout`
  (10 s) for apply workers in this DB to be idle/paused. Paused workers sleep
  on `pause_cv`; if nobody resumes, each worker self-resumes after
  `spock.pause_timeout` and clears the flag (`maybe_pause_for_slot_creation`,
  `src/spock_apply.c:565`). A subscriber crash between pause and resume
  stalls *all* apply on the provider instance for up to 10 s. Fix that
  introduced pausing: `dcbba6bb` ("resume_lsn data loss").
* Per-table resync (`sub_resync_table`, `sub_alter_sync`, `repset_add_table
  ... synchronize_data`): status rows go `i` → sync worker COPY → `SYNCWAIT`
  → apply worker hands its current LSN as `replay_stop_lsn` (`CATCHUP`) →
  sync worker streams with `spock.replicate_only_table` until there →
  `SYNCDONE` → apply worker marks READY when its own `end_lsn` passes
  (`process_syncing_tables`, `src/spock_apply.c:4456`). There is an
  `Assert(spock_worker_running(worker))` with a TODO "What if the SYNC worker
  has gone?" (`src/spock_apply.c:~4530`); and a failed `wait_for_sync_status_change`
  raises ERROR "a table synchronisation operation is failed". **LEAD:** with
  an assert-enabled build, killing a sync worker in SYNCWAIT may crash the
  apply worker → postmaster restart.

### F7. DDL replication (AutoDDL and `replicate_ddl`)

* Both paths serialize DDL as SQL text into the `spock.queue` table
  (`queue_message`, `src/spock_queue.c`) **in the same transaction** as the
  DDL, so DDL and DML stay in commit order in the WAL stream.
* AutoDDL: `spock_ProcessUtility` runs the statement, then
  `spock_autoddl_process` (`src/spock_autoddl.c:78`) if
  `spock.enable_ddl_replication` (default **off**). Skips temp/unlogged,
  database/tablespace/subscription/ALTER SYSTEM, VACUUM, DDL from inside
  functions (unless `spock.allow_ddl_from_functions`), DDL in extension scripts,
  DDL nested in DROP EXTENSION. Queues to repset `default_insert_only`
  (comment) / `ddl_sql`. If `spock.include_ddl_repset` (default off) it also
  adds new tables to `default` (has PK/RI) or `default_insert_only` and moves
  tables when PK/RI is added/dropped (`apply_repset_policy_for_reloid`).
  Guard: DDL against `spock`/`snowflake` schemas refused
  (`spock_guard_extension_owned_ddl`).
* Manual: `spock.replicate_ddl(command, replication_sets='{ddl_sql}',
  search_path, role)` executes locally and queues.
* Provider side: `spock_change_filter` special-cases `spock.queue` INSERTs —
  replicated if the message has no repset (global) or shares a repset with the
  subscription. Subscriber side: `handle_insert` on `QueueRelid` →
  `handle_queued_message` (`src/spock_apply.c:2862`): types `Q` SQL, `D` DDL,
  `A` table sync request, `S` sequence. SQL is run by
  `spock_execute_sql_command` as the recorded role.
* No cross-node DDL coordination: concurrent conflicting DDL on two nodes
  only shows up as apply errors (then TRANSDISCARD by default → silently
  dropped DDL on one side). **CLAIM** in `docs/limitations.md` ("No
  Replication Queue Flush"): users must handle schema change ordering.
* `spock.deny_all_ddl` blocks DDL entirely. `spock.repair_mode(true)` emits a
  `SPOCK_REPAIR_MODE_ON` WAL message so the rest of the txn is not decoded.

### F8. Sequences

* Catalog `spock.sequence_state(seqoid, cache_size, last_value)`. Messages are
  queued `S` entries with `last_value = current + cache_size`; subscriber does
  `setval` if ahead (`handle_sequence`, `src/spock_apply.c:2590`).
* **Periodic sync is dead code.** `synchronize_sequences()`
  (`src/spock_sequences.c:84`) has no callers; the manager loop that used to
  call it was removed in `fc4cf74e` (2024, "Customize apply-worker restart
  delay"). Only `spock.sync_seq(regclass)` (`synchronize_sequence`) and the
  initial data copy move sequence values. `docs/limitations.md` "Sequences"
  still **CLAIMs** sequences are "replicated periodically". Docs recommend
  pgEdge Snowflake sequences instead. For Antithesis: don't rely on sequence
  replication; use snowflake or per-node offsets.

### F9. Slot groups (output-side "parallel slots")

* `spock_output_join_slot_group` (`src/spock_output_plugin.c:1281`): if the
  slot name ends in `_<one digit>`, the walsender joins a shared group named by
  the prefix. In `pg_decode_begin_txn`, a txn whose `end_lsn <=
  slot_group->last_lsn` is **skipped** (another member claimed it); otherwise
  this walsender claims it. `L` message carries the group's previous commit ts;
  the subscriber's `wait_for_previous_transaction` blocks until the apply
  group's `prev_remote_ts` matches, to commit in order.
* **LEAD (possible silent loss):** (a) slot names are
  `spk_<db>_<provider>_<subname>`; any subscription name ≤16 chars ending in
  `_<digit>` (e.g. `sub_1`, `sub_2` on two different subscriber nodes from
  the same provider) makes two unrelated subscriptions share one group on the
  provider, and each transaction would go to only one of them. ZODAN's
  `sub_<provider>_<subscriber>` names avoid it unless node names end in a
  digit after `_`. (b) Even for intended use, a walsender that claims a txn
  (sets `last_lsn`) then dies before the subscriber commits it will, on
  reconnect, skip that txn because `last_lsn >= end_lsn` as long as another
  group member stays attached. No doc in `docs/` mentions slot groups.

### F10. ZODAN add-node / remove-node

Not C code: PL/pgSQL procedures in `samples/Z0DAN/zodan.sql` (3274 lines) and
`zodremove.sql`, run on the **new** node, driving all peers over `dblink`.
Nothing is atomic across phases; each phase commits remote changes
independently; most waits are polling loops bounded by `spock.sync_timeout()`.

`spock.add_node(src_name, src_dsn, new_name, new_dsn, ...)` (`zodan.sql:2882`):
* Phase 0 version check (new node must be ≥ every existing major.minor).
* Phase 1 prerequisites; Phase 2 `node_create` on new node.
* Phase 3 (`create_disable_subscriptions_and_slots`, `zodan.sql:1794`): for
  every *other* node X: create slot `X→new` on X via
  `pg_create_logical_replication_slot` (remember `slot_lsn`); `sync_event(true)`
  on X; poll src's `spock.progress.remote_commit_lsn` for X until ≥ that LSN
  (proves src has every X commit ≤ slot_lsn); drop stale origin on new node;
  create **disabled** `sub_X_new` on new node (origin created, status READY).
  2-node case just records a src sync_event.
* Phase 4 sync events on others, wait on src; Phase 5 `sub_create(src→new,
  synchronize_structure, synchronize_data, enabled)` → F6 initial sync
  (pause apply on src, slot, snapshot, peer progress, COPY).
* Phase 6 sync_event on src, `wait_for_sync_event` on new.
* Phase 7 (`check_commit_timestamp_and_advance_slot`, `zodan.sql:2426`): wait
  for src→new READY (warning-only on timeout), then for each X:
  `pg_replication_slot_advance(X slot, remote_commit_lsn of X as seen in new
  node's spock.progress)` and `pg_replication_origin_advance` on new node to
  the same LSN.
* Phase 8 mirror repsets from src; Phase 9 enable the disabled subs; Phase 10
  create subs from new node to every existing node (on those nodes); Phases
  11-14 report.
* The C side helps: forwarded transactions advance the pre-created disabled
  subscription's origin (`maybe_advance_forwarded_origin`, commit `401197ab`),
  and `spock.read_peer_progress()` captures per-peer resume LSNs under the
  copy snapshot. `forward_origins` + enabled subscription coexistence is now
  rejected (`2948d567`).
* **CLAIM** (`docs/modify/zodan/zodan_tutorial.md:415,617,975`): "starts from
  exactly this point, guaranteeing no data loss"; "guarantees data
  consistency". Failure modes worth testing: crash/partition between phases
  (half-created slots/subs, apply paused), writes on X during Phase 3-7,
  timeouts that are warnings rather than errors (Phase 7 READY wait).
* `spock.remove_node` (`zodremove.sql:404`): drop subscriptions (on target and,
  via dblink, on peers) → drop repsets → `node_drop` → report. No drain of
  in-flight changes originating on the removed node that peers haven't got
  yet (no forwarding by default), so data written on the removed node shortly
  before removal can exist on some peers and not others.

### F11. Catalogs (`sql/spock--6.0.0.sql`)

| Table | Role |
|---|---|
| `spock.node(node_id, node_name, location, country, info jsonb)` | all known nodes; `info->tiebreaker`; `user_catalog_table` |
| `spock.node_interface(if_id, if_name, if_nodeid, if_dsn)` | DSNs |
| `spock.local_node(node_id, node_local_interface)` | identifies this node |
| `spock.subscription(sub_id, sub_name, sub_origin, sub_target, ..., sub_enabled, sub_slot_name, sub_replication_sets, sub_forward_origins, sub_apply_delay, sub_force_text_transfer, sub_skip_lsn, sub_skip_schema, sub_created_at)` | ids from `spock.sub_id_generator` (CYCLE) |
| `spock.local_sync_status(sync_kind, sync_subid, sync_nspname, sync_relname, sync_status, sync_statuslsn)` | sub-level (null names) and per-table sync state machine |
| `spock.replication_set`, `replication_set_table`, `replication_set_seq` | repsets (insert/update/delete/truncate flags, row filter, att list) |
| `spock.queue(queued_at, role, replication_sets, message_type, message json)` | DDL/SQL/sequence/tablesync message bus (replicated as DML) |
| `spock.sequence_state` | sequence replication buffer |
| `spock.exception_log`, `exception_status`, `exception_status_detail` | rows discarded/failed by exception handling |
| `spock.resolutions` | conflict log (if `save_resolutions`) |
| `spock.depend`, `spock.pii`, `spock.reserved_object` | dependency tracking, PII column list, reserved names guard |
| Views: `spock.progress` (from shmem `apply_group_progress()`), `spock.lag_tracker`, `spock.channel_*_stats`, `spock.tables` | monitoring |

Progress persistence: `SpockGroupHash` in shmem, dumped to
`PGDATA/spock/resource.dat` only on clean shutdown, `add_node`, table-sync;
after a crash, reconciled against the origin and `remote_commit_ts` recovered by
scanning `pg_commit_ts` (`src/spock_progress_recovery.c`). Commit `2f9a686c`
removed the checkpoint hook (and its core patch).

### F12. SQL API surface (grouped)

* Nodes: `node_create`, `node_drop`, `node_add_interface`, `node_drop_interface`, `node_info`.
* Subscriptions: `sub_create`, `sub_drop`, `sub_enable/sub_disable(immediate)`,
  `sub_alter_interface`, `sub_add_repset`, `sub_remove_repset`,
  `sub_alter_skiplsn`, `sub_alter_options(jsonb)`, `sub_alter_sync(truncate)`,
  `sub_resync_table`, `sub_show_status`, `sub_show_table`,
  `sub_wait_for_sync`, `table_wait_for_sync`.
* Repsets: `repset_create/alter/drop`, `repset_add_table/add_all_tables/remove_table`,
  `repset_add_seq/add_all_seqs/remove_seq`, `repset_add_partition/remove_partition`,
  `repset_show_table`, `table_data_filtered`.
* Sync/coordination: `sync_event(transactional)` (logical WAL message;
  non-transactional by default, `fdd9587e`), procedure
  `wait_for_sync_event(origin_id, lsn, timeout, wait_if_disabled)`,
  `wait_slot_confirm_lsn`, `pause_apply_workers`/`resume_apply_workers`
  (superuser only), `read_peer_progress`, `get_lsn_from_commit_ts`.
* DDL: `replicate_ddl(text|text[])`, `repair_mode(bool)`.
* Sequences: `sync_seq`.
* Misc: `delta_apply(...)` helpers, `xact_commit_timestamp_origin`,
  `terminate_active_transactions` (read-only mode), `slot_enable_failover`,
  `reserved_object_add/remove`, stats getters/resetters, `cleanup_resolutions`,
  `spock_version()`, `spock_max/min_proto_version()`, `spock_gen_slot_name`.

### F13. PostgreSQL core patches (`patches/<15..19>/`)

Built against pgEdge-patched PG (memory: use pg18a/pg17a builds; stock
builds lack these). Spock code calls the patched symbols unconditionally
(`remoteTransactionStopTimestamp`, `SubTransactionIdSetCommitTsData`,
`AttributeOpts.delta_apply_function`), so it will not build against stock PG.

1. **`*-015-attoptions.diff`** — adds column options `log_old_value` (bool) and
   `delta_apply_function` (string) to `AttributeOpts`; heapam writes the old
   values of `log_old_value` columns into WAL on UPDATE
   (`HeapDetermineLogOldColumns`). Needed for delta apply (F5): the provider
   must send old+new of counter columns so the subscriber can add the
   difference.
2. **`*-025-logical_commit_clock.diff`** — Lamport-style commit clock.
   `XLogReserveInsertHook` called while holding the WAL insert lock; for commit
   records `EnsureMonotonicTransactionStopTimestamp` forces
   `xact_time > XLogCtl->lastTransactionStopTimestamp` for local commits (and
   recomputes the record CRC), and for apply commits raises the clock to
   `max(clock, local ts, remote ts)` using `remoteTransactionStopTimestamp`
   set in `handle_commit` (`src/spock_apply.c:1056`). Purpose: commit ts
   monotonic in LSN order, and a node never stamps a local commit older than a
   remote commit it already applied — protects last-update-wins from local
   clock lag. The patch's own TODO: **"This is not postmaster restart safe"**
   — the clock lives only in shared memory, so after a restart a node whose
   clock is behind can again stamp commits older than ones it already saw.
   Clock skew + restart is a direct Antithesis target.
3. **`*-030-per-subtrans-commit-ts.diff`** — `SubTransactionIdSetCommitTsData(xid, ts, nodeid)`
   plus a `COMMIT_TS_SUBTRANS_TS` WAL record, so a subtransaction can carry a
   different commit ts/origin in `pg_commit_ts`. Used for forced delta-apply
   updates so the row keeps the *local* winner's ts/origin and later conflict
   checks aren't fooled.
4. **PG15 only `pg15-010-allow_logical_decoding_on_standbys.diff`** (native in
   PG16+). `patches/attic/` holds retired patches (e.g. the old checkpoint hook).

### F14. Read-only mode, repair mode, misc GUCs relevant to faults

* `spock.readonly` = `off`/`local`/`all`: `all` also stops apply workers from
  starting new transactions (`apply_work` loop breaks) — writes from peers
  queue up on providers.
* `spock.exception_behaviour` default `transdiscard`; `spock.exception_logging`
  default `all`.
* `spock.conflict_resolution`, `spock.check_all_uc_indexes`,
  `spock.synchronous_commit` (postmaster, default off),
  `spock.apply_idle_timeout`, `spock.pause_timeout`, `spock.sync_timeout`,
  `spock.restart_delay_default/_on_exception`, `spock.read_retry_count`,
  `spock.exception_replay_queue_size`, `spock.enable_ddl_replication`,
  `spock.include_ddl_repset`, `spock.output_delay`.
* Fault-injection already in tree: `SPOCK_RANDOM_DELAYS` build flag and
  injection points `spock-worker-delay` (worker attach/detach and every
  `handle_begin`) and `spock-output-txn-stall` (`include/spock_injection.h`).

---

## Areas examined

* `src/spock.c` (init, GUCs, supervisor, connect, START_REPLICATION),
  `spock_worker.c`, `spock_manager.c`, `spock_apply.c` (main loop, begin/commit/
  origin, error classification, feedback, sync table handling, queued
  messages), `spock_apply_heap.c` (conflict + delta apply), `spock_conflict.c`,
  `spock_output_plugin.c` (startup, begin/commit/change/message/origin filter,
  slot groups), `spock_sync.c` (subscription init, slot+progress capture),
  `spock_functions.c` (sub_create, pause/resume, gen_slot_name,
  auto_replicate_ddl), `spock_autoddl.c`, `spock_executor.c`,
  `spock_sequences.c`, `spock_node.c` (node id), `spock_failover_slots.c`
  (GUCs/registration only).
* `sql/spock--6.0.0.sql`, `patches/18/*`, `samples/Z0DAN/zodan.sql` (phases
  3 and 7 read in full), `zodremove.sql` (structure),
  `docs/internals-doc/{DESIGN,protocol}.md`, the progress-recovery spec,
  `docs/limitations.md`, parts of `docs/configuring.md`.
* git log for origin/crash/sequence history (`fc4cf74e`, `2f9a686c`,
  `69722443`, `dcbba6bb`, `401197ab`, `8dcfbcd5`, `d286f3df`).
* TAP test list (`tests/tap/t/`) and `tests/docker/docker-compose.yml`
  (3-node n1/n2/n3 compose exists — good base for the Antithesis env).

## Assumptions

* Stock PG behavior of `xact_redo_commit` (origin progress replay by record
  origin id), `RecordTransactionCommit` (`replorigin_session_advance` on the
  session origin), and logical walsender start = max(requested, confirmed_flush)
  is as in upstream PG 15-18; the pgEdge patches don't touch these (checked
  patch file lists only).
* Line numbers are from HEAD 69d9228f and are approximate where marked `~`.
* `spock_output.c` is just the `_PG_output_plugin_init` shim for the
  `spock_output` module; the plugin lives in the main `spock.so`.
* Didn't verify `update_missing` handling or `spock_apply_heap_insert` paths
  in detail.

## Open Questions

1. **F3 lead**: does subscriber crash recovery really fail to restore the
   slot-named origin's `remote_lsn` past the last checkpoint (because commit
   records carry the node id as origin)? If yes, what is the real duplicate
   apply window given `synchronous_commit=off` on apply and feedback timing?
   A kill -9 of a subscriber during steady load with a delta-apply counter
   table, or a "no txn applied twice" check via a per-txn unique marker,
   would settle it.
2. **F9 lead**: are slot groups an intended/used feature in 6.0? Is the
   `_<digit>` suffix rule documented anywhere? What protects a claimed but
   unsent txn after a walsender crash?
3. Is the commit clock (patch 025) restart-safety TODO handled elsewhere
   (e.g., seeding `lastTransactionStopTimestamp` from the max `pg_commit_ts`
   at startup)? I found no such code in `src/`.
4. After a crash in sync status `d`/`s`/`c`, the subscription is disabled and
   needs manual recreation — is that the intended operator story, and does
   ZODAN detect and clean it up (zodan_cleanup.sql exists, not read)?
5. `pause_apply_workers` is instance-wide but only waits for workers in the
   calling DB; multi-DB instances get paused in other DBs too. Intended?
6. With default `transdiscard`, which non-transient errors can a fault
   (not a real data conflict) still produce — e.g. 40001 under a non-default
   isolation level, statement_timeout (57014), out-of-order DDL after a
   partition? Each would silently discard a remote transaction.
7. `spock.sub_id_generator` is `CYCLE` integer; irrelevant for tests but sub
   ids could repeat after wrap.
