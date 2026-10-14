---
sut_path: /home/msharp/dev/pgedgea/spock
commit: 69d9228f5df363761dc3ae6eebf7e2fcfe49b8e5
updated: 2026-10-13
external_references: []
---

# Spock SUT Analysis (synthesis of 12 discovery focuses)

## 0. How to read this document

- **Provenance tags** name the discovery focus that surfaced each finding:
  [F1] architecture, [F2] state, [F3] concurrency, [F4] safety, [F5] liveness,
  [F6] bug history, [F7] tests, [F8] failure modes, [F9] dependencies,
  [F10] product, [F11] assumptions, [F12] wildcard. [SYN] marks an observation
  made while checking code for this synthesis.
- **Claims** from docs, comments or commit messages are recorded as
  "Spock claims X (file:line); property should verify". None has been shown to
  hold.
- **Leads** (section 9) are suspected bugs from code reading. All are
  **unconfirmed** until a run reproduces them. When several focuses reached the
  same lead on their own, that is noted as a confidence signal. "Code-checked"
  means the synthesis re-read the cited code and the mechanism is present as
  described; it still has not been run.
- Line numbers are from HEAD 69d9228f; `~` means approximate.
- Section 11 lists contradictions between focuses and how they were settled by
  reading code.

---

## 1. What the SUT is

Spock 6.0.0 (`include/spock.h:27`) is a multi-master (active-active) logical
replication extension for PostgreSQL 15-19. It runs entirely inside each
node's postmaster (loaded via `shared_preload_libraries`; `_PG_init` errors
otherwise, `src/spock.c:~1118`). There is no external daemon. [F1, F9]

- **Requires a pgEdge-patched PostgreSQL.** `spock.so` references
  `remoteTransactionStopTimestamp`, `SubTransactionIdSetCommitTsData` and the
  `AttributeOpts.delta_apply_function` field, which exist only with
  `patches/<major>/` applied. It will not build or load on stock PG. [F1, F9, F10, F12]
- **Shape is a full mesh.** Default `forward_origins='{}'` means a provider sends
  only locally originated changes, so N nodes need N*(N-1) subscriptions, one
  apply worker and one provider slot each. `forward_origins={all}` is only
  allowed as the single enabled subscription on a node (cascade), enforced by
  `enforce_forwarding_exclusivity()` (`src/spock_functions.c:470-532`,
  commit 2948d567). [F1, F4, F10]
- **Conflict model**: whole-row last-update-wins (LUW) on commit timestamp,
  with a per-node tiebreaker; optional per-column "delta apply" for counters.
  No tombstones, no cross-origin ordering. [F1, F4, F10]
- **Node add/remove ("ZODAN")** is a 3,274-line PL/pgSQL sample
  (`samples/Z0DAN/zodan.sql`, `zodremove.sql`) run on the new node over
  `dblink`, not part of the extension SQL. It is nevertheless the documented
  add-node path and CI uses it to build the Docker mesh. [F1, F9, F10, F12]
- **Cluster-wide consistency repair is handed to an external tool (ACE)**
  (`docs/recovery/catastrophic_node_failure.md:19-23`, `docs/FAQ.md:73`).
  Spock does not claim nodes always converge. [F4, F10]

---

## 2. Architecture backbone

### 2.1 Processes (per PostgreSQL instance = per node) [F1, F3, F5]

| Process | Entry | Started by | Restart | Job |
|---|---|---|---|---|
| supervisor (1) | `spock_supervisor_main` `src/spock.c:903` | static bgworker, `BgWorkerStart_RecoveryFinished`, `bgw_restart_time=5` | postmaster, 5 s | Registers one manager per connectable DB (`start_manager_workers`, `src/spock.c:787`). Wakes on `SpockCtx->subscriptions_changed` or every 180 s. On clean exit waits up to 50x100 ms for apply workers, then dumps `resource.dat` (`spock_supervisor_on_exit`, `src/spock.c:~856-897`). |
| manager (1 per DB) | `spock_manager_main` `src/spock_manager.c:178` | supervisor (dynamic, `BGW_NEVER_RESTART`) | supervisor when `subscriptions_changed`, no delay | Exits if no `spock` extension. Runs `ALTER EXTENSION spock UPDATE` when .so version differs (`spock_manage_extension`, `src/spock.c:560`). `manage_apply_workers()` (`src/spock_manager.c:39-186`) starts one apply worker per enabled subscription, honours `restart_delay`, SIGTERMs workers whose sub is gone/disabled. |
| apply (1 per enabled sub) | `spock_apply_main` `src/spock_apply.c:4677` | manager | manager after `terminated_at + restart_delay` | Initial sync if needed, then streams from provider walsender and applies. |
| sync (per table resync, at most 1 running per sub) | `spock_sync_main` `src/spock_sync.c:1960` | apply worker (`start_sync_worker`, `src/spock_apply.c:4638`) | apply worker | COPY one table, catch up to `replay_stop_lsn`, exit. |
| walsender + `spock_output` plugin | stock walsender, callbacks in `src/spock_output_plugin.c:133-140` | subscriber `START_REPLICATION` | n/a | Decodes, filters by repset, writes native protocol. No streaming or 2PC callbacks, so large transactions are fully decoded (spilled under `logical_decoding_work_mem`) before any byte is sent. [F9] |
| failover-slots worker (PG15-17 only) | `spock_failover_slots_main` `src/spock_failover_slots.c:1321` | static bgworker, restart 60 s | postmaster | Copies logical slots to a physical standby. Not registered on PG18 (native `sync_replication_slots`, commit 3bd075a0). |

- **Any SIGKILL/segfault/Assert in any spock worker triggers a postmaster
  crash-restart of the whole instance** (with `restart_after_crash=on`), which
  reinitialises all shared memory: worker table, exception markers,
  `pause_apply`, slot groups, `SpockGroupHash` (reloaded from `resource.dat`),
  and the core logical commit clock. So "kill a worker" in Antithesis exercises
  the "everything in shmem lost" path, not the "manager restarts one worker"
  path. The latter needs SIGTERM / `pg_terminate_backend` / FATAL / ERROR
  exits. Both need coverage. (`src/spock_worker.c:440-446` comment.) [F2, F5, F8, F9]
- Worker bookkeeping: `SpockCtx` + `SpockWorker[max_worker_processes]`
  (`include/spock_worker.h`) under one LWLock `SpockCtx->lock`. A per-slot
  `generation` counter lets `wait_for_worker_startup` (`src/spock_worker.c:217`)
  tell "crashed before attach" from "slot reused". Error exit:
  `spock_worker_detach(crash=true)` sets `terminated_at`, leaves `worker_type`
  unchanged, latches the manager (`src/spock_worker.c:410-480`). Clean exit
  resets the slot to `SPOCK_WORKER_NONE` and does **not** latch the manager.
  [F1, F3, F8]
- Catalog changes signal workers only at COMMIT via
  `signal_worker_xact_callback` (`src/spock_worker.c:679`), which takes
  `SpockCtx->lock` at `XACT_EVENT_COMMIT` (before heavyweight locks are
  released). Comment admits "not fully transactional". [F1, F3]
- Hooks (`spock_executor_init`, `src/spock_executor.c:328`):
  `ProcessUtility_hook` (AutoDDL, `spock.deny_all_ddl`), `object_access_hook`,
  `post_parse_analyze_hook` + `ExecutorStart_hook` (read-only mode,
  `src/spock_readonly.c`), `emit_log_hook` (message filter). Custom WAL rmgr id
  **144** (`src/spock_rmgr.c`, record `SPOCK_RMGR_RESOURCE_DUMP` 0x10); redo
  only logs. [F1, F2, F9]
- Signals: all spock workers install `handle_sigterm` (sets `got_SIGTERM`,
  `SetLatch`, `src/spock_worker.c:84`). SIGTERM is cooperative and is not seen
  inside heavyweight-lock waits, LWLock waits, blocking libpq calls or
  `pg_usleep`. SIGINT keeps PG's `StatementCancelHandler` for DB-connected
  bgworkers (stock `bgworker.c:763`), so `pg_cancel_backend(<apply pid>)`
  raises 57014 inside apply. [F3, F8, SYN]

### 2.2 Data path: local commit to peer commit [F1, F2]

```
client txn on N1 -> commit (ts adjusted by patch 025 logical clock) -> WAL
  walsender for slot spk_<db>_<N1>_<sub> on N1 (logical decoding, waits for commit)
   pg_decode_origin_filter: drop non-local origins unless forward_origins non-empty (all-or-nothing)
   pg_decode_begin_txn: slot-group claim (2.9); write 'B', then 'O' (origin node id, origin_lsn, name), 'L' commit-order ts
   pg_decode_change: repset/row filter/column list; special-cases spock.queue and spock.replication_set -> 'R' + 'I'/'U'/'D'
   pg_decode_truncate 'T'; pg_decode_message prefix "Spock" -> 'M' (sync_event, repair mode on/off)
   pg_decode_commit_txn: SyncRepWaitForLSN(end_lsn - MyWalSenderIdx) when a physical sync standby exists; write 'C'
  CopyBoth 'w' frames (proto v5: each 'w' starts with remote_insert_lsn)
N2 apply worker apply_work() (src/spock_apply.c:3398)
   handle_begin / handle_origin / handle_commit_order / handle_relation / handle_insert|update|delete / handle_truncate / handle_message
   handle_commit: wait_for_previous_transaction(); origin lsn = end_lsn; remoteTransactionStopTimestamp = commit_time;
                  CommitTransactionCommand(); push lsn_mapping; update SpockGroupHash; maybe_advance_forwarded_origin()
   send_feedback after every message: flush = highest remote_end whose local commit <= GetFlushRecPtr()
```

- **Connection** (`spock_connect_base`, `src/spock.c:366-475`): forces
  `connect_timeout=30`, `keepalives=1/idle 10/interval 5/count 3` (about 25 s
  idle dead-peer detection), `replication=database` for streaming, and
  `options=... -c datestyle=ISO -c intervalstyle=postgres -c extra_float_digits=3`.
  These keys come after the expanded `dbname`, so they override the DSN. No
  `tcp_user_timeout`; no `wal_sender_timeout` option. **`spock.extra_connection_options`
  is not passed to libpq** (only used in an `errdetail`, see 11.1). [F1, F5, F8, F9, SYN]
- **Start**: `replorigin_session_setup(origin named sub slot name)` ->
  `origin_startpos = replorigin_session_get_progress()` -> `IDENTIFY_SYSTEM` ->
  `START_REPLICATION SLOT ... LOGICAL <origin_startpos>` with proto version,
  `binary.*`, `forward_origins`, `replication_set_names`, `pg_version`,
  `spock_version` (`spock_start_replication`, `src/spock.c:697`). Provider
  starts at max(requested, slot `confirmed_flush`). Then
  `request_initial_status_update` asks for an immediate keepalive (TAP 023). [F1, F5]
- **Apply session settings** (`src/spock_apply.c:4699-4716`):
  `synchronous_commit=off` (or `local` if `spock.synchronous_commit`, postmaster
  GUC, default off), `session_replication_role=replica`,
  `check_function_bodies=off`. Isolation level and `statement_timeout` are not
  pinned. [F1, F9, F11]
- **Feedback** (`send_feedback`, `src/spock_apply.c:3237`): runs after every
  message, including mid-transaction (then flush = LSN just received, below the
  commit, so the provider re-sends). With no outstanding `lsn_mapping` entries it
  reports flush = recvpos. A sync-standby hold exists
  (`append_feedback_position`/`get_feedback_position`, `:3120-3236`, fix
  5f654e34) but see lead L9. Under `use_try_block` with TRANSDISCARD/SUB_DISABLE
  end-of-batch feedback is suppressed (`:3803-3845`). [F1, F2, F4, F5]

### 2.3 Origin identity: Spock node id is used as the RepOriginId [F1, F2, F4, F11, F12]

- `spock.node.node_id = hash_any(node_name) & 0xffff` unless given
  (`create_node`, `src/spock_node.c:367-371`). Collisions are rejected only
  against the local `spock.node` catalog (`:373-383`, TAP 024). Ids 0 and 65535
  are not rejected (code-checked). [F2, F4, F11, F12]
- Provider writes its own node id as origin for local txns, and the stored
  `txn->origin_id` for forwarded ones (`pg_decode_begin_txn`,
  `src/spock_output_plugin.c:~600-630`).
- Subscriber: session origin is the slot-named roident
  (`src/spock_apply.c:4750`), but `handle_origin()` then sets
  `replorigin_session_origin = remote_origin_id` (a node id,
  `src/spock_apply.c:1332`). So commit records and `pg_commit_ts` carry the
  origin **node id**, while progress (`remote_lsn`) is kept in the session state
  of the slot-named origin. The design doc states this
  (`docs/internals-doc/specs/spock-progress-no-checkpoint-hook-design.md`,
  Phase 3). This is the root of lead L1.
- Conflict resolution reads the local tuple's origin/ts from `pg_commit_ts`
  (`get_tuple_origin`, `src/spock_conflict.c:219-275`).

### 2.4 Wire protocol [F1]

- One plugin, `native` (binary, default) or `json` encodings. Protocol
  versions: max 5, min 4 (`include/spock_output_proto.h:33`); negotiated
  min(server max, client max). v5 prefixes each 'w' with `remote_insert_lsn`.
  Mixed versions are a supported rolling-upgrade state (TAP 014, 099).
- Messages: `S` startup (sent lazily on first BEGIN or sync_event; fdd9587e
  fixed an ordering crash), `B`, `O`, `L`, `R` (cached per walsender), `I/U/D`
  (old key or full old tuple, plus `log_old_value` columns), `T`, `M`, `C`.
- Binary datums only if all `binary.*` params match; binary send/recv on same
  PG major; else text. `force_text_transfer` forces text.
- Downstream sends only standby status ('r'); it can only refuse data by
  disconnecting (DESIGN.md). Unknown startup params are ignored both ways
  (claim, DESIGN.md).
- Test knobs: `spock.output_delay` (ms sleep in BEGIN), injection point
  `spock-output-txn-stall` after BEGIN.

### 2.5 Conflict handling on apply [F1, F4, F10, F11]

- Lookup by replica identity / PK (`FindReplTupleInLocalRel`), optionally all
  unique indexes for INSERT (`spock.check_all_uc_indexes`, experimental)
  (`src/spock_apply_heap.c:394-485`).
- `spock.conflict_resolution` default `last_update_wins`; check hook rejects it
  unless `track_commit_timestamp=on` (`spock_conflict_resolver_check_hook`,
  `src/spock_conflict.c:800-815`). Expected (not run): with commit timestamps
  off, startup fails because the boot value fails its check hook. [F9]
- `conflict_resolve_by_timestamp` (`src/spock_conflict.c:99-200`): remote vs
  local commit ts; equal -> same-origin shortcut (apply remote); else compare
  tiebreaker of **this applying node** vs the remote origin (commit 64ea462d;
  code-checked at `:131-200`); lower keeps local; equal tiebreakers -> apply
  remote + WARNING on both sides. Tiebreaker defaults to node id
  (`src/spock_node.c:499-532`). See lead L2.
- Frozen xmin or truncated commit_ts -> local ts 0 -> remote always wins, not
  logged (`src/spock_conflict.c:235-250`). Rows written by initial COPY carry
  origin timestamp `'epoch'` (`pg_replication_origin_xact_setup('0/0','epoch')`,
  `src/spock_sync.c:944-947`), so later remote changes always beat them. [F4, SYN]
- `update_missing` -> `elog(ERROR)` after `spock.read_retry_count` (default 5)
  re-reads (`src/spock_apply_heap.c:982-1049`). The retries call
  `wait_for_previous_transaction()`, which returns at once when
  `required_commit_ts == 0` (`src/spock_apply.c:308`), true unless slot groups
  are active; so the retries are a tight loop with no wait (code-checked).
  `delete_missing` skipped and recorded; `delete_exists` keeps the local row.
  [F3, F4, F8, F11]
- Delta apply (`spock_handle_conflict_and_apply`, `src/spock_apply_heap.c:589-780`):
  for every remote UPDATE on a table with delta columns (not only conflicts), the
  delta `new - old` is added to the current local value, even when LUW keeps the
  local row (`apply` forced true). The forced update runs in a subtransaction
  whose commit ts/origin is overwritten with the local winner's
  (`SubTransactionIdSetCommitTsData`, patch 030). INSERT-exists uses a zero old
  tuple, so concurrent inserts of the same key add up. Old value NULL (source had
  `log_old_value` off) falls back to plain overwrite (`:545-566`). **Delta apply
  is not idempotent**: any redelivery double-counts. [F4, F9, F11, F12]
- Conflicts logged to server log and, if `spock.save_resolutions=on`, to
  `spock.resolutions` (cleanup by `spock.resolutions_retention_days`). PG18+
  pgstat conflict counters (kind 29) are reset after crash recovery; not a
  reliable oracle across crashes. [F1, F2]

### 2.6 Subscription creation and initial sync [F1, F2, F5, F8, F9]

`spock.sub_create(name, provider_dsn, replication_sets='{default,default_insert_only,ddl_sql}', synchronize_structure=false, synchronize_data=false, forward_origins='{}', apply_delay, force_text_transfer, enabled=true, skip_schema)` -> `spock_create_subscription` (`src/spock_functions.c:~560-770`):
1. Read provider node info; create local copies of provider `spock.node`/`node_interface` rows.
2. Insert `spock.subscription`; slot name `spk_<db>_<provider>_<sub>` (`gen_slot_name`, `src/spock_functions.c:3666-3687`; each part `shorten_hash`ed to 16 chars; every char outside `[a-z0-9_]`, **including uppercase**, becomes `_`, code-checked).
3. `spock_group_ensure_entry`.
4. `spock.local_sync_status` row status INIT if enabled. If created **disabled** (ZODAN path), status READY and the origin is created at once; no sync.
5. On COMMIT the manager starts the apply worker.

Apply worker -> `spock_sync_subscription` (`src/spock_sync.c:1488-1810`):
- READY: nothing. INIT/CATCHUP: run/rerun. **STRUCTURE 's' / DATA 'd' /
  CONSTRAINTS 'c' -> subscription disabled, FATAL "initialization failed during
  nonrecoverable step"** (`:1517-1546`).
- INIT: `spock_create_slot_and_read_progress` (`:650-866`): drop inactive old
  slot -> `SELECT spock.pause_apply_workers()` **on the provider** ->
  `CREATE_REPLICATION_SLOT ... LOGICAL spock_output [(FAILOVER)]` (FAILOVER when
  remote is PG17+) -> import snapshot (REPEATABLE READ) -> `spock.read_peer_progress()`
  (`sql/spock--6.0.0.sql:127-200`, INNER JOIN on `spock.progress`) ->
  `spock.resume_apply_workers()`.
- Then, in its own committed txn, create/advance the local origin to the slot
  LSN **before** copying (`:1675-1690`); optional `pg_dump`/`pg_restore`
  pre-data (forked from the subscriber, same PG major required, temp file in
  `spock.temp_directory`); COPY each table; `spock_group_progress_force_set_list`
  (writes `resource.dat`); tables READY; post-data; CATCHUP -> READY.
- `PG_ENSURE_ERROR_CLEANUP` drops slot and origin only on ERROR/FATAL, not
  SIGKILL; the cleanup itself opens a new provider connection
  (`spock_sync_worker_cleanup`, `:1429-1468`) and loops without bound while the
  remote slot is active.
- Per-table sync status chain: `i` -> `p` STARTED -> `d` -> `w` SYNCWAIT -> apply
  hands its LSN as `replay_stop_lsn` -> `u` CATCHUP (sync streams with
  `spock.replicate_only_table`) -> `y` SYNCDONE -> apply marks `r` READY
  (`process_syncing_tables`, `src/spock_apply.c:4456-4635`). Any non-INIT status
  at sync-worker start becomes `f` FAILED (`src/spock_sync.c:1851-1866`). The
  apply worker skips all changes for tables not READY/caught-up
  (`should_apply_changes_for_rel`, `src/spock_apply.c:464-484`) while still
  advancing the origin. See L12.

### 2.7 DDL replication [F1, F11]

- AutoDDL (`spock.enable_ddl_replication`, default off) and
  `spock.replicate_ddl()` both serialise DDL as SQL text into `spock.queue` in
  the **same** transaction as the DDL (`queue_message`, `src/spock_queue.c`),
  so DDL and DML from one origin stay in commit order. Subscriber:
  `handle_queued_message` (`src/spock_apply.c:2862`) types Q/D/A/S.
- No cross-node coordination: DDL from one origin is not ordered against DML
  from another. A remote column missing locally -> `elog(ERROR, "unknown column
  name")` (`src/spock_relcache.c:398`) -> exception path -> under TRANSDISCARD a
  silently dropped transaction. Docs require writes stopped and slots caught up
  before schema changes (`docs/limitations.md`). [F1, F10, F11]
- `spock.include_ddl_repset` adds new tables to `default`/`default_insert_only`;
  `spock.deny_all_ddl` blocks DDL; DDL against `spock`/`snowflake` schemas refused.
- `spock.repair_mode(true)` emits `SPOCK_REPAIR_MODE_ON` so the rest of the
  transaction is not decoded.

### 2.8 Sequences [F1, F2, F4, F10]

- `synchronize_sequences()` (`src/spock_sequences.c:84`) **has no caller**
  (code-checked; manager loop call removed in fc4cf74e). Only
  `spock.sync_seq(regclass)` and initial copy move sequence values.
  `docs/limitations.md` "Sequences" still claims periodic replication and
  `docs/spock_functions/functions/spock_repset_add_seq.md:24-25` overclaims
  consistent `nextval`. Sequences are not a valid basis for uniqueness across
  nodes; use node-prefixed keys, UUIDs or Snowflake (not in this tree).

### 2.9 Slot groups ("parallel slots") [F1, F2, F3, F5, F8, F11, F12]

- `spock_output_join_slot_group` (`src/spock_output_plugin.c:1281-1360`, called
  from startup): if the slot name ends in `_<one digit>`, the walsender joins a
  shared-memory group named by the prefix. Members skip any txn with
  `end_lsn <= slot_group->last_lsn` (`:530-583`). The `L` message carries the
  group's previous commit ts; subscriber `wait_for_previous_transaction`
  (`src/spock_apply.c:294-340`) spins with 1 ms CV sleeps and **no timeout**
  until `prev_remote_ts == required_commit_ts`.
- With normal slot names `required_commit_ts` stays 0 (static
  `slot_group_last_commit_ts`, `:546-549`), so the ordering code is dormant.
- Not documented in `docs/`. Commit c0bcad19 calls it a prototype. Fix
  f6887c7a "Disable parallel apply: reject grouped slot names" exists only on
  branch `origin/block-parallel-apply` and is **not an ancestor of HEAD**
  (code-checked with `git merge-base`). See L10.

### 2.10 ZODAN add_node / remove_node [F1, F4, F5, F9, F10, F12]

`CALL spock.add_node(src_node_name, src_dsn, new_node_name, new_node_dsn, ...)` (`samples/Z0DAN/zodan.sql:2882`), run on the new node:
- Phase 0 version check (new node >= every existing major.minor; all >= 5.0.9).
- Phase 1 prereqs; Phase 2 `node_create` on new node.
- Phase 3 (`create_disable_subscriptions_and_slots`, `:1794`): for every other
  node X: create slot X->new on X, `sync_event` on X, poll src's
  `spock.progress.remote_commit_lsn` for X until >= slot LSN (each probe has a
  local `statement_timeout=5s`, retried every 0.5 s), drop stale origin, create
  **disabled** `sub_<new>_<X>` on new node. `create_sub` errors are caught and
  only `RAISE NOTICE`d (`:2017-2036`, code-checked); add_node continues.
- Phase 4 sync events, wait on src. Phase 5 `sub_create(src->new, sync
  structure+data, enabled)` -> initial sync (2.6). Phase 6 sync_event on src,
  `wait_for_sync_event` on new.
- Phase 7 (`check_commit_timestamp_and_advance_slot`, `:2426`; core at
  `:2625-2680`, code-checked): wait for src->new READY (warning only on timeout);
  for each X: `target_lsn = spock.progress.remote_commit_lsn` on the new node
  (set by force-set from `read_peer_progress`); if NULL, `RAISE NOTICE 'WARNING:
  No spock.progress entry ... falling back to pg_current_wal_lsn()'` and use X's
  current WAL end; `pg_replication_slot_advance` on X over dblink (commits
  remotely at once), then local `pg_replication_origin_advance`.
- Phase 8 mirror repsets (dblink loopback); Phase 9 enable disabled subs;
  Phase 10 create new->X subs on X; Phases 11-14 checks/reports (Phase 12
  `monitor_replication_lag` exits with NOTICE after 60 s).
- Waits use `spock.sync_timeout()`: GUC `spock.sync_timeout` if > 0 else 180 s
  (`:46-52`). No C code reads the GUC (code-checked). Budgets use
  `clock_timestamp()` (wall clock). Most dblink calls have no timeout and use
  the DSN as given (no keepalives). Fixed `pg_sleep(5)` after each create_sub.
- C helpers: forwarded transactions advance the pre-created disabled sub's
  origin (`maybe_advance_forwarded_origin`, `src/spock_apply.c:5165-5183`,
  401197ab); `read_peer_progress` captures resume LSNs under the copy snapshot.
- `spock.remove_node` (`zodremove.sql:404`): drop subs (locally and on peers via
  dblink), repsets, `node_drop`. No drain of the removed node's in-flight
  changes, so its last writes may exist on some peers only. `zodan_cleanup.sql`
  exists for partial adds.
- Nothing is atomic across phases. If the orchestrator session dies mid-way,
  slots, origins and disabled subscriptions are left behind. [F12]

### 2.11 Catalogs and SQL API [F1, F2]

Catalogs (`sql/spock--6.0.0.sql`): `spock.node(node_id, node_name, location, country, info jsonb)`, `node_interface`, `local_node`, `subscription` (ids from CYCLE sequence `sub_id_generator`), `local_sync_status`, `replication_set`, `replication_set_table`, `replication_set_seq`, `queue`, `sequence_state`, `exception_log`, `exception_status(_detail)`, `resolutions`, `depend`, `pii`, `reserved_object`. Views: `spock.progress` (over shmem `apply_group_progress()`), `spock.lag_tracker`, `spock.channel_*_stats`, `spock.tables`.

SQL API groups: nodes (`node_create/drop`, interfaces); subscriptions (`sub_create`, `sub_drop`, `sub_enable/disable`, `sub_alter_interface`, `sub_add/remove_repset`, `sub_alter_skiplsn`, `sub_alter_options(jsonb)`, `sub_alter_sync`, `sub_resync_table`, `sub_show_status`, `sub_show_table`, `sub_wait_for_sync`, `table_wait_for_sync`); repsets; coordination (`sync_event(transactional default false)`, procedure `wait_for_sync_event(OUT result, origin, lsn, timeout default 0, wait_if_disabled default false)`, `wait_slot_confirm_lsn`, `pause/resume_apply_workers`, `read_peer_progress`, `get_lsn_from_commit_ts`); DDL (`replicate_ddl`, `repair_mode`); `sync_seq`; misc (`delta_apply`, `xact_commit_timestamp_origin`, `terminate_active_transactions`, `slot_enable_failover`, `reserved_object_add/remove`, stats getters, `cleanup_resolutions`, version functions, `spock_gen_slot_name`). [F1]

### 2.12 PostgreSQL core patches (`patches/<15..19>/`) [F1, F9, F12]

| Patch | Versions | Change | Spock use |
|---|---|---|---|
| `pgNN-015-attoptions.diff` | 15-19 | Column options `log_old_value` (bool), `delta_apply_function` (string) in `AttributeOpts`; heapam logs old values of `log_old_value` columns on UPDATE (`HeapDetermineLogOldColumns`). | Delta apply: provider ships old+new; `build_delta_tuple` (`src/spock_apply_heap.c:510-582`). |
| `pgNN-025-logical_commit_clock.diff` | 15-19 | `XLogReserveInsertHook` called **under the WAL insert spinlock**; `EnsureMonotonicTransactionStopTimestamp` forces local commit `xact_time > XLogCtl->lastTransactionStopTimestamp` and recomputes record CRC; for apply commits raises the clock to max(clock, local, `remoteTransactionStopTimestamp`) without changing the apply commit's own ts. Patch TODO: **"This is not postmaster restart safe"**. | Keeps local commit ts monotonic in LSN order and ahead of applied remote ts, protecting LUW against a lagging local clock. `handle_commit` sets/clears `remoteTransactionStopTimestamp` (`src/spock_apply.c:1056-1063`). Also assumed by `spock.get_lsn_from_commit_ts()` WAL scan. |
| `pgNN-030-per-subtrans-commit-ts.diff` | 15-19 | `SubTransactionIdSetCommitTsData(xid, ts, nodeid)` + WAL record `COMMIT_TS_SUBTRANS_TS` (0x20), replayed in `commit_ts_redo`. | Delta-apply forced updates keep the local winner's ts/origin. |
| `pg15-010-allow_logical_decoding_on_standbys.diff` | 15 only | Backport of PG16 decoding on standby. | No direct call from `src/` found [F9]. |

- `patches/attic/` holds retired patches (old checkpoint hook).
  `tests/docker/spock.patches/commit_order_test.patch` is stale and unused. [F9]
- Applied-transaction commit timestamps on the subscriber are the origin's, so
  commit-ts on a node is not monotonic in LSN order across applied txns even
  without restarts. [F4, F12]

### 2.13 Key GUCs (defaults code-checked where marked) [F1, F2, F5, F8, F9]

| GUC | Default | Context | Notes |
|---|---|---|---|
| `spock.exception_behaviour` | `transdiscard` | | `discard` / `sub_disable` alternatives. TAP harness uses `sub_disable`. |
| `spock.exception_logging` | `all` | | |
| `spock.conflict_resolution` | `last_update_wins` | | needs `track_commit_timestamp=on` |
| `spock.save_resolutions` | off | postmaster | Docker harness turns on |
| `spock.synchronous_commit` | off | postmaster | apply session `synchronous_commit` |
| `spock.restart_delay_default` | 5000 ms | postmaster | |
| `spock.restart_delay_on_exception` | 0 ms | postmaster | code-checked `src/spock.c:1340-1351`; set on every BEGIN |
| `spock.pause_timeout` | 10 s (min 1) | **USERSET** | code-checked `:1353-1366`; see L4 note |
| `spock.sync_timeout` | 0 (=> zodan 180 s) | USERSET | only zodan reads it |
| `spock.read_retry_count` | 5 (0-100) | SIGHUP | |
| `spock.exception_replay_queue_size` | 4 MB | SIGHUP | code-checked `:1406-1418`; docs call it deprecated, still active |
| `spock.apply_idle_timeout` | 300 s (0 off) | SIGHUP | tagged connection-class since 8dcfbcd5 |
| `spock.readonly` | off | SUSET | `local` / `all` |
| `spock.check_all_uc_indexes` | off | SIGHUP | experimental |
| `spock.output_delay` | 0 ms | SIGHUP | test knob |
| `spock.channel_counters` | on | | per-row `SpockCtx->lock` SHARED in `handle_stats_counter` |
| `spock.enable_ddl_replication` / `include_ddl_repset` / `allow_ddl_from_functions` | off | | TAP turns on |
| `spock.extra_connection_options` | '' | | **not applied** (11.1) |
| failover-slot GUCs | `synchronize_slot_names='name_like:%%'`, `drop_extra_slots=true`, `primary_dsn`, `pg_standby_slot_names`, `standby_slots_min_confirmed=-1`, naptimes 1000/10000 ms | | PG15-17 |

---

## 3. State and persistence

| State | Where | Survives crash? | Writers | Readers |
|---|---|---|---|---|
| Resume position per sub (`remote_lsn`) | replication origin named after the slot | Normal commit: in-memory session advance, durable only via checkpoint **or** redo of the commit record (but redo uses the node id, L1). Empty txn / non-transactional sync_event: `replorigin_session_advance` only, no WAL (`src/spock_apply.c:1113-1131, 2955-2964`). Sync: `replorigin_advance(..., wal_log=true)` (`src/spock_sync.c:1684, 1900`). Forwarded: separate WAL record after commit (`:5165-5183`). Zodan: `pg_replication_origin_advance`. | apply, sync, zodan | apply start, `wait_for_sync_event`, `read_peer_progress` |
| Provider position | logical slot `confirmed_flush`/`restart_lsn` | yes | walsender from feedback; zodan `pg_replication_slot_advance` | walsender start |
| `SpockGroupHash` (`spock.progress`) | shmem, key (dbid, node_id, remote_node_id), fixed size = `max_worker_processes` (`src/spock_group.c:137-171`) | only via `PGDATA/spock/resource.dat`, written at clean shutdown, add_node force-set, table-sync COPY; no CRC | `handle_commit`, `UpdateWorkerStats`, reconcile, force-set | `spock.progress`, zodan Phase 3/7, `read_peer_progress`, `wait_for_previous_transaction` |
| rmgr 144 records | WAL | yes | same three dump sites | `pg_waldump`; redo logs only |
| Catalog tables | heap | yes | SQL API, apply, sync | all |
| commit ts + origin per xid | `pg_commit_ts` (+ `COMMIT_TS_SUBTRANS_TS`) | yes | commit path; applied txns stamped with remote ts and remote node id | conflict resolution, progress ts recovery |
| Logical commit clock | `XLogCtl->lastTransactionStopTimestamp` | **no**; zero after any restart, crash restart, promotion | every commit | commit-time adjustment |
| Exception marker | shmem `exception_log_ptr[max_worker_processes]` keyed by **subscription name** | no | `handle_begin` on every BEGIN | `handle_begin` decides replay |
| Pause flag | `SpockCtx->pause_apply` + `pause_cv`, one per postmaster | no | `pause/resume_apply_workers`, worker timeout | `maybe_pause_for_slot_creation` |
| Slot groups | `SpockCtx->slot_groups[]` | no | walsenders with `_<digit>` slot names | `pg_decode_begin_txn` |
| Feedback mapping | per-process `lsn_mapping`, `sync_replica_lsn` | no | `handle_commit` | `send_feedback` |
| Replay queue | per-process memory + `BufFileCreateTemp` spill | no | `apply_work` | in-process replay |
| Table sync handshake | `local_sync_status` + shmem `replay_stop_lsn` | mixed | apply, sync | both |
| Conflict stats (PG18+) | pgstat kind 29 | clean shutdown only | apply | `spock.get_subscription_stats` |

[F1, F2, F3, F9, F12]

Progress-tracking history: per-commit rmgr record (b8f1eea9) -> redo crash fix (c4368188) -> missing field (a43f4b82) -> checkpoint hook (a4e34ce2/a4b93e87) -> **removed** in 2f9a686c in favour of shutdown-only `resource.dat`, `reconcile_progress_with_origin()` at every apply start (`src/spock_progress_recovery.c:153-275`; ANOMALY -> origin wins and timestamps cleared), and a backward `pg_commit_ts` scan of up to 1M xids (`:295-380`) that filters by remote node id (not subscription-unique, `:129-132`). TAP 016 has been `skip_all` since 69722443. Three designs in seven months. [F2, F6, F7]

Contract ambiguity: code comments (`src/spock_group.c:23-37`) say the progress hash is monitoring only and the origin alone decides resume; the design doc says force-set entries are "deduplication state for forwarded transactions in a mesh ... must be crash-durable"; zodan Phase 7 uses them to place peer slots. [F2, F4, F12]

---

## 4. Concurrency model [F3, F5]

- No parallel apply inside a worker. Concurrency comes from several apply
  workers (one per upstream) writing the same tables, plus local sessions.
- `SpockCtx->lock` (one LWLock) guards worker table, stats hash
  (taken SHARED on **every applied row** via `handle_stats_counter`,
  `src/spock_worker.c:930`, while `spock.channel_counters=on`), and exception-slot
  claims. Many worker fields are read without it.
- `SpockGroupHash` is created with 16 partitions but every access uses
  `apply_group_master_lock`.
- Slot groups: `slot_group_master_lock` + per-group LWLock; `leave` decrements
  `nattached` with the lock commented out (`src/spock_output_plugin.c:1366-1383`,
  code-checked).
- `pause_apply` is an atomic plus CV, instance-wide.
- Waits: apply main loop `WaitLatchOrSocket(1000 ms)`; manager
  `WaitLatch(restart_delay)`; supervisor 180 s; sync waits 60 s;
  `wait_for_previous_transaction` 1 ms CV polls.
- Admin functions calling `get_local_node(true, ...)` hold
  ShareUpdateExclusiveLock on `spock.local_node`; the manager takes the same lock,
  so **apply-worker (re)starts in that DB stop while any such admin call is open**
  (`src/spock_node.c:721`; call sites in `src/spock_functions.c:338, 491, 566,
  776, 879, 915, 950, 1027, 1058, 1351`, `src/spock_sequences.c:200`). [F3]

---

## 5. Failure-handling model

### 5.1 Apply-worker error classifier [F1, F4, F6, F8, F11, F12]

`apply_work()` wraps the receive/apply loop in one `PG_TRY`; `PG_CATCH`
(`src/spock_apply.c:3867-4133`) decides:
1. Connection class: 08006, 08000, 08003, 57P01, 57P02, 57P03, or
   `PQstatus==CONNECTION_BAD` -> `clear_transient_exception_state()`,
   `restart_delay = restart_delay_default`, rethrow. 57P04 and 08P01 deliberately
   excluded.
2. 40P01 deadlock, 55P03 lock_not_available -> `prepare_transient_error_retry()`
   (`:443-456`), rethrow; retried **indefinitely** every 5 s.
3. Class 53 -> same.
4. SUB_DISABLE with `xact_had_exception || use_try_block` -> disable, return.
5. `use_try_block && !xact_had_exception` -> "error during exception handling", rethrow.
6. Otherwise (first data error): `AbortOutOfAnyTransaction()` (`:4065`) with
   `replorigin_session_origin*` still set, save message in shmem marker,
   `apply_replay_queue_start_replay()`, `use_try_block=true`, `goto stream_replay`,
   replay in the same process under `spock.exception_behaviour`.

**Anything not in 1-3 is treated as a permanent data fault.** Under default
TRANSDISCARD the replay runs read-only (`begin_replication_step` sets
`transaction_read_only`, `:620-631`), logs every row to `spock.exception_log`,
and advances the origin past the transaction (`handle_commit`, `:996-1009`).
DISCARD wraps each row in a subtransaction whose `PG_CATCH` swallows **any**
error (`:1657-1690, 1832-1880, ~1960-2010, 2188-2230, 2790-2815`). SUB_DISABLE
sets the origin to BEGIN `commit_lsn`, commits exception rows, ERRORs, then
disables. A crash restart clears the shmem marker (safe); FATAL and other exits
that skip `PG_CATCH` do not.

Bug history in exactly this classifier/marker (at least eleven fixes): 72625daa,
5b88e2de, 3cf97588, d286f3df (data loss: origin advanced past aborted in-flight
txn on connection loss), db380dd8, f3d4935e (deadlock/lock timeout/class 53 went
to discard), acf6cdae (stale `use_try_block`), b8993cb5 (prefix match shared
slots), 0f7f068b (off-by-one), ed0a9945 (SIGTERM mid-txn), 8dcfbcd5 (idle
timeout raised as XX000; HEAD~4). Related: 162dc562, 47d4a003, 4cb409cb,
f84b853d (UAF in spill replay). The pattern: each missed error code or exit path
became silent loss or spurious disable. [F6]

### 5.2 Restart pacing [F5, F8]

- Registration: `restart_delay_default`. First BEGIN: `restart_delay_on_exception`
  (0). Retry branches reset to default; entering replay uses default.
  `SPOCK_RESTART_MIN_DELAY = 1 ms` (`include/spock.h:38`). So unclassified
  ERROR/FATAL after a BEGIN respawns after about 1 ms (f3d4935e measured 83
  restarts in one second before pacing). [F5, F8]
- `spock_worker_register()` failure (no slot, `max_worker_processes` exhausted)
  raises ERROR inside the manager, which the supervisor respawns with no delay. [F5]
- Clean exit does not latch the manager; restart waits up to
  `restart_delay_default`. [F8]
- Manager restart timing uses wall-clock `terminated_at + restart_delay`
  (`src/spock_manager.c:107-131`). [F5]

### 5.3 Connection-loss detection [F5, F6, F8, F9]

- Idle keepalive about 25 s. With unacknowledged data in flight, Linux uses
  `tcp_retries2` (about 15 min) since `tcp_user_timeout` is not set.
- `spock.apply_idle_timeout` (300 s) is the real backstop for silent
  partitions and SIGSTOP-paused providers (kernel still ACKs keepalives).
  `last_receive_timestamp` updates on any message incl. keepalives
  (`src/spock_apply.c:3676-3682`; 2535c3fa fixed it never firing).
- Blocking libpq calls with no timeout: `IDENTIFY_SYSTEM`/`START_REPLICATION`
  (`PQexec`, `src/spock.c:~626/763`), sync-path `PQexec`/COPY in
  `src/spock_sync.c`, `src/spock_rpc.c`. `pg_dump` uses the raw DSN (no
  keepalives) and `exec_cmd` does a blocking `waitpid()` with no interrupt
  check. dblink in zodan uses raw DSNs. [F8, F9]
- Reconnect while the old walsender still holds the slot -> START_REPLICATION
  FATAL, restart every 5 s until the old walsender times out (degraded, not broken). [F8]
- Stale-fd `epoll_ctl(EINVAL)` cascade fixed (4dfe7496, d286f3df; TAP 019). [F6]
- Docs recommend `wal_sender_timeout='5min'` (`docs/configuring.md:227-241`)
  because 60 s drops busy subscribers. [F5, F9]

### 5.4 Health reporting [F8]

`spock.sub_show_status` (`src/spock_functions.c:1437-1540`) says `replicating`
when the worker slot has a proc, is not terminated, and sub-level sync is READY.
It does not check connection or progress. Workers stuck in
`wait_for_sync_status_change`, blocking libpq, pause, or
`wait_for_previous_transaction` show `replicating`. `sub_show_table` maps
statuses via `sync_status_to_string` (`:1359-1382`), which has no case for `'p'`
STARTED or `'f'` FAILED, so both print `unknown` (code-checked). Do not use
`replicating` as "caught up".

---

## 6. Claimed safety guarantees (each is a property to test)

- **S1 LUW gives one deterministic winner.** Spock claims "the version of data
  with newest commit timestamp is kept" (`docs/conflicts.md:60-64`) and that on
  equal timestamps "the node with the lower tiebreaker value wins"
  (`docs/conflict_types.md:173-176`); insert_exists applies the winner as an
  UPDATE (`:46-49`); delete_exists keeps the newer local row (`:150-156`).
  Property should verify: after quiescence all nodes hold the same version per
  key, and it is the version with the largest (commit ts, tiebreaker) for
  workloads limited to documented-resolvable conflicts. Threatened by L2, L3. [F4, F10]
- **S2 Every dropped change is recorded.** Spock claims "non-resolvable
  conflicts are recorded in `spock.exception_log`" (`docs/conflict_types.md:12-15`;
  `docs/configuring.md:191-195`). Property should verify: every inter-node row
  difference after quiescence is explained by an `exception_log` or
  `resolutions` row (with `save_resolutions=on`); under TRANSDISCARD each remote
  transaction is all-or-nothing per node. Threatened by L5, L6, L7, L12. [F4, F10]
- **S3 Transient errors never discard data.** Spock claims connection-class,
  deadlock, lock-timeout and class-53 errors must not enter replay and the
  respawned worker "resumes from the last durably-committed origin LSN and
  re-streams the aborted txn" (`src/spock_apply.c:3870-3897, 3933-3976`;
  release notes `docs/spock_release_notes.md:603-610`). Admitted gap: 40001
  under cluster-wide RR/SERIALIZABLE (`:3951-3957`). Property should verify:
  with only infrastructure faults, `exception_log` stays empty and no
  subscription becomes disabled. Threatened by L5, L8. [F4, F6, F8]
- **S4 Exactly-once on a direct subscription.** Spock claims the resume point
  "is handled entirely by stock logical-replication protocol"
  (`docs/internals-doc/specs/spock-progress-no-checkpoint-hook-design.md:26`);
  TAP 022's header claims WAL recovery advances `pg_replication_origin`.
  Explicit at-least-once caveat for forwarded origins (401197ab: "delta-apply
  idempotency remains a separate follow-up"). Property should verify: each
  provider txn is applied exactly once per subscriber across kill -9 at random
  points; delta counters equal committed increments. Threatened by L1, L7, L19. [F2, F4, F11, F12]
- **S5 Commit timestamps are monotonic per node.** The patch claims the hook
  "ensure[s] that the commit timestamp is monotonically increasing in
  commit-LSN order" and bumps the local clock past remote ts; it admits it is
  not restart safe (`patches/18/pg18-025-logical_commit_clock.diff`). Property
  should verify: local-origin commit ts strictly increase across restarts, and a
  local update made after reading a remote version wins everywhere. Expected to
  fail with skew + restart (L3). [F4, F9, F11, F12]
- **S6 No replication echo.** `pg_decode_origin_filter` claims "Never filter out
  locally originated tx's"; forward all or nothing
  (`src/spock_output_plugin.c:1199-1222`). Property should verify: in a default
  mesh each user txn is applied once per peer. Risks: node id 0 (L24),
  `forward_origins` cycles, apply-process writes without an origin set. `repair_mode`
  changes never reach peers (`docs/managing/read_only.md:59-71`). [F4, F11]
- **S7 Exception modes behave as documented** (`docs/configuring.md:160-184`):
  transdiscard discards the whole txn; discard commits non-failing parts;
  sub_disable "will resume with the transaction that caused the exception" on
  re-enable (also `src/spock_apply.c:997-1004`). Property should verify: under
  SUB_DISABLE the origin stays below the bad txn's end LSN and after fix +
  `sub_enable` it and later txns apply exactly once in order. [F4, F8]
- **S8 Read-only modes.** Spock claims `local` blocks non-superuser sessions but
  not apply; `all` blocks apply too and "replication resumes from where it left
  off, provided the upstream replication slot still retains the necessary WAL"
  (`docs/managing/read_only.md:5-9, 73-83`). Property should verify: no remote
  commit while `all` is in effect; no loss or duplication after switching back.
  See L23/L34 (FATAL path). [F4, F5]
- **S9 Failover slots lose nothing.** Spock claims "replication resumes from the
  last synchronized LSN with no data loss" (`docs/logical_slot_failover.md:5,165`;
  `docs/configuring.md:305-307, 345-347`) and `spock.pg_standby_slot_names`
  holds walsenders until standbys confirm (`docs/configuring.md:389-394`).
  Counter-claim in code: the slot may "fast-forward ... skips over a gap of WAL
  ... We can't detect or prevent that" (`src/spock_failover_slots.c:1265-1276`).
  Subscriber-side sync-standby hold claim at `src/spock_apply.c:3120-3125`
  (threatened by L9). [F4, F9]
- **S10 Node ids are unique.** `src/spock_node.c:374-383` claims collisions are
  detected; only locally. ZODAN "aborts to prevent duplicate node names"
  (`docs/modify/zodan/zodan_tutorial.md:275`). [F4, F11]
- **S11 Sequences.** `docs/limitations.md:117-125` admits sequence state "does
  not completely eliminate the possibility" of falling behind; the repset_add_seq
  doc overclaims. Not a property to assert. [F4]
- **S12 Delta apply converges to the sum of deltas.** Spock claims "the
  delta-apply column will be correctly calculated and applied" and the bank
  example ends at the correct total (`docs/conflicts.md:10-34`). Property should
  verify: `SUM(counter)` equals committed increments on every node after
  quiescence, under kill/partition/skew. Threatened by L1, L5, L19, skip_lsn. [F4, F10, F12]
- **S13 ZODAN add_node misses and duplicates nothing.** Spock claims "This
  ensures no data is missed or duplicated" (`zodan_tutorial.md:375-376`),
  "guaranteeing no data loss" (`:413-415`), "no data is lost" (`:442-444`),
  `wait_for_sync_event` completion guarantees receipt (`:615-618`), "This
  guarantees data consistency" (`:973-976`). Property should verify: an add_node
  that **succeeds** under writes on all nodes leaves the new node with exactly
  the union of committed rows; a failed add_node is acceptable but must not
  corrupt existing nodes. Threatened by L4, L17, L20. Two past fixes in this exact
  class (5.0.7, 6.0). [F1, F4, F6, F10]
- **S14 `sync_event` / `wait_for_sync_event` barrier.** Spock claims a `true`
  result means "all changes up to [LSN] on the provider have been received and
  applied" (`docs/monitoring/spock_sync_event.md`). The poll reads
  `pg_replication_origin_status.remote_lsn` (`sql/spock--6.0.0.sql:685-780`),
  which is advanced in shmem during commit and, for empty/non-transactional
  markers, without WAL. Property should verify the barrier holds and stays true
  across a subscriber crash (L18). [F2, F5, F7, F11]

---

## 7. Claimed liveness guarantees

- **V1 Reconnect.** Spock claims the apply worker "exits cleanly when the
  upstream connection dies ... and the manager respawns it from the last
  durably-committed remote LSN" (`docs/spock_release_notes.md:603-610`);
  "Subscribers reconnect automatically" (`docs/logical_slot_failover.md:310`);
  clients "can reconnect and resume replay" (`docs/internals-doc/OUTPUT.md:33-37`).
  Users with a partition are told to "wait for connectivity to return"
  (`docs/recovery/catastrophic_node_failure.md`). Property should verify: after
  faults heal every enabled sub returns to streaming and lag reaches 0 within
  about `restart_delay_default + connect_timeout(30 s) + keepalive(25 s)`, or
  `apply_idle_timeout` (300 s) + 5 s for silent partitions / paused peers. [F5, F8, F10]
- **V2 Workers are restarted.** Manager restarts dead apply workers; supervisor
  restarts managers. Property should verify: no permanently missing worker; no
  respawn loop faster than `restart_delay_default` for connection-class errors.
  Threatened by L21, L22, L23, L33. [F5]
- **V3 Pause is bounded.** Comment at `src/spock_sync.c:1636-1640`: "the workers'
  CV timeout will recover them". Property should verify: `pause_apply` never stays
  set much longer than `spock.pause_timeout` after the caller dies. [F5]
- **V4 Sync completes or fails visibly.** No claim of automatic recovery;
  interrupted initial sync -> disabled; interrupted table sync -> FAILED. Treat as
  expected non-liveness (record, do not flag), but a sync that hangs forever or
  silently stops replicating a table is a bug (L12). [F5, F8]
- **V5 add_node completes or fails within a bound.** Bounded by
  `spock.sync_timeout()`; docs say partial adds may need cleanup
  (`docs/modify/zodan/index.md:18-22`). Property should verify: returns or raises
  within a bound derived from `sync_timeout`; watch for silent partial success
  (Phase 3 NOTICE) and hangs on paused peers (dblink). [F5, F9]
- **V6 Shutdown is bounded.** Supervisor waits at most about 5 s before dumping.
  Threatened by L11 (LWLock deadlock blocks `before_shmem_exit`). [F3, F5]
- **V7 Node restartability.** Implicit: a node restarted at any time comes back.
  Threatened by L16 (`resource.dat` load ERROR at postmaster start). [F2, F3]
- Expected FAQ claim: around a time change "spock replication needs some time
  (~5 minutes) to recover" (`docs/FAQ.md`). [F10]

---

## 8. Test coverage overlay [F7, F6]

| Layer | Where | Topology | Faults |
|---|---|---|---|
| pg_regress | `tests/regress`, `make regresscheck` | ONE instance; "nodes" are databases | none (random 1-100 ms delay variant) |
| TAP | `tests/tap/t/*.pl` (60 files), `SpockTest.pm`, `schedule`, `schedule-nightly` | 1-3 postmasters on 127.0.0.1 | single hand-placed faults: SIGKILL walsender/subscriber, `pg_ctl -m immediate`, cancel, one injection-point stall, iptables (unscheduled) |
| Docker 3-node | `tests/docker` | n1/n2/n3 compose, built by zodan add_node | spockbench 120 s concurrent writes on all 3 (delta apply on balances), **no faults**; check by external `spockbench-check` |
| Shell rigs | `tests/run-single-pg18-installcheck.sh`, `tests/run-cluster-upgrade.sh` | 3-node mesh | core regress as load; rolling upgrade with ACE diff |

- **No test combines conflicting writes on 3+ nodes, random-time faults, and a
  full cross-node data comparison.** No clock-skew test works
  (`005_daylight_savings` is `todo_skip`). No partition between subsets of a mesh,
  no faults during add_node/COPY, no walsender kill mid-decode, no sequence sync
  under faults. [F7]
- Crash/fault tests not in any schedule: 015_resync_readonly_origin,
  016_crash_recovery_progress (skip_all), 020_exception_root_cause,
  020_sync_standby_feedback_lsn, 023, 026, 027, 029, 030_read_retry_count_guc,
  101, 102, 104 (needs root), 800. The fault paths Antithesis will hit have the
  least regression protection. [F6, F7]
- `022_rmgr_progress_post_checkpoint_crash` and `027` run CHECKPOINT before
  SIGKILL ("Without this, after SIGKILL the origin may roll back"), so the redo
  path of L1 is never tested. [F11, F12]
- `011_zodan_sync_third` checks `sum(abalance), sum(aid), count(*)`; its pgbench
  scripts net to zero, so a whole lost or doubled txn is invisible. [F7]
- `025_tiebreaker_equal_warning` is single-writer; does not cover L2. [F6]
- `020_sync_standby_feedback_lsn` promotes a non-lagging standby; would not see L9. [F12]
- `046` is the only test attaching injection points (`spock-output-txn-stall`);
  `spock-worker-delay` is never attached. Random-delay build runs only the
  regress suite. [F7]
- TAP harness defaults: `exception_behaviour=sub_disable`, AutoDDL on,
  `exception_replay_queue_size=1MB`, `log_min_messages=debug1`;
  `cross_wire` uses `sleep 10` not a readiness wait. [F7]
- Fix density (fix-type commits since 2025-10): `spock_apply.c` 50,
  `spock_sync.c` 23, `spock_functions.c` 22, `spock.c` 19, `spock_group.c` 16,
  `spock_failover_slots.c` 12, `spock_node.c` 12, `spock_worker.c` 11; zodan.sql
  ~25 fix commits in 56. Quiet but on the data path and untested under faults:
  `spock_output_plugin.c`, `spock_proto_native.c`, `spock_queue.c`,
  `spock_sequences.c`. [F6]
- No in-tree generic "dump every replicated table on every node and compare"
  helper; Antithesis needs its own. [F7]
- `existing-assertions.md` (scratchbook) records no Antithesis SDK use in the tree.

---

## 9. Leads (suspected bugs; none confirmed by a run)

Format: ID, title, provenance, confidence signal, mechanism, faults needed,
property.

### L1. Crash redo advances an origin numbered by the node id, not the subscription origin -> duplicate apply after subscriber crash [F1, F11, F12]
- Agreement: three focuses independently; synthesis code-checked both sides.
- Mechanism: `handle_origin` sets `replorigin_session_origin = node id`
  (`src/spock_apply.c:1332`); session state belongs to the slot roident (`:4750`).
  Stock PG: commit record carries `replorigin_session_origin`
  (`xloginsert.c:842-846`); `RecordTransactionCommit` advances the session state
  in memory (`xact.c:1441`); redo calls `replorigin_advance(XLogRecGetOrigin(record), ...)`
  (`xact.c:6162, 6324-6325`) — checked in a local stock PG 17 tree, not the
  patched tree, but the pgEdge patches do not touch these paths [F1, F12].
  Later confirmed at code level on patched PG18 (code reading, not run); see
  `properties/crash-redo-leaves-no-node-id-origin-state.md`, "Investigation
  update (2026-10-13)".
  So after kill -9 between checkpoints, the subscription origin falls back to
  its last checkpoint value; the provider resumes at max(that, `confirmed_flush`),
  re-sending txns committed and flushed locally but not yet confirmed back.
- Effects: plain rows mostly re-converge (same-origin equal-ts shortcut);
  **delta-apply columns double-count**; duplicates hit conflict logging; if a
  node id equals some local roident, redo advances that unrelated origin into a
  different LSN space -> **silent loss** for that subscription (node names can be
  chosen to force it; `hashtext(name) & 65535` should equal the id, verify);
  redo needs free replication-state slots for node-id "origins", which
  `docs/sizing.md:188-203` does not count -> possible "could not find free
  replication state slot" at recovery. [F11, F12]
- Faults: node termination (SIGKILL postmaster) between checkpoints; large
  `checkpoint_timeout`.
- Property: exactly-once ledger per (origin, seq); delta counter = committed
  increments; subscription `remote_lsn` never goes back past a txn whose effects
  are visible.

### L2. Equal-timestamp tiebreak compares the applying node, so 3+ writers can diverge [F6, F10, F11]
- Agreement: three focuses; code-checked (`src/spock_conflict.c:131-200`,
  introduced by 64ea462d which compared the tuple's origin before).
- Example (lower wins): A=2, B=1, C=3; A and C write the same row with equal
  ts. A keeps A; C applies A; B gets C first then A: B(1)<A(2) keeps C -> divergence.
- Also: equal tiebreakers -> both sides apply remote -> values swap [F4, F11];
  tiebreakers in `spock.node.info` are per-node local catalog rows and can differ
  between nodes [F4]. Lamport bumps (`last_seen + 1 us`) make equal ts more likely
  when two lagging nodes saw the same remote commit [F6].
- Faults: clock control / jitter (freeze or align clocks), 3+ writers on same keys.
- Property: scoped convergence with equal-ts collisions forced.

### L3. Logical commit clock is not restart safe [F1, F2, F4, F9, F11, F12]
- Agreement: six focuses; stated in the patch's own TODO.
- `lastTransactionStopTimestamp` lives in `XLogCtl`, zeroed at every postmaster
  start, crash restart and promotion; not rebuilt from WAL or `pg_commit_ts`.
- Scenario: node X behind in wall time applies remote T1 (ts 100), restarts,
  then updates the row locally with wall ts 91. X keeps its write; peers keep T1
  (or later) -> **permanent divergence**, no exception row; causality broken.
- Side effects: `spock.get_lsn_from_commit_ts()` `break`s at the first commit
  with ts > target, assuming monotonic ts -> too-low LSN after restart [F9, F12]
  (no in-tree caller now [F6]); `progress_update_struct` keeps max by
  `remote_commit_ts` (`src/spock_group.c:309-334`), so `spock.progress` freezes
  when an origin's ts goes backwards [F2, F3].
- Faults: clock skew (node behind) + node restart + writes to rows last written remotely.
- Property: per-node local commit ts monotonic across restarts; causal LUW.

### L4. add_node pause window can reopen -> permanent row loss on the new node [F2, F3, F4, F6, F8, F11, F12]
- Agreement: seven focuses; code-checked (`src/spock_functions.c:4060-4126`,
  `src/spock_apply.c:565-586`).
- Holes: (a) each paused worker self-resumes after `spock.pause_timeout` (10 s)
  and **clears the global flag**, while `CREATE_REPLICATION_SLOT` may still be
  waiting for running xids (long txn, SIGSTOP, slow I/O); nothing re-checks.
  (b) "paused" = `paused || !TransactionIdIsValid(proc->xid)`: a worker inside a
  txn with no xid yet passes and can commit in the window. (c) `proc == NULL`
  (starting) workers skipped. (d) One flag for all DBs and all concurrent
  callers; any `resume` clears another caller's pause. (e) Not tied to caller
  session; dead caller leaves pause until timeout. (f) Scan reads worker fields
  without `SpockCtx->lock`. (g) `waited_ms++` per 1 ms sleep ignores scan time.
- [SYN] `spock.pause_timeout` is `PGC_USERSET`: raising it in the add_node caller
  session (the documented errhint) extends only the caller's wait; each apply
  worker uses its own session value for its self-resume timeout.
- Related: `read_peer_progress` INNER JOINs `spock.progress`; a missing shmem
  entry for (P, C) (after P crash/restart before C's apply worker attached)
  silently drops C, then zodan Phase 7 falls back to C's `pg_current_wal_lsn()`
  (as a NOTICE) [F2, F4, F12]. Snapbuild's wait for running xids may cover (b)
  (open question) [F3].
- Past fixes in this class: dcbba6bb (pause introduced), b7fc7022, f38da44a,
  a9bc8652, 986ad069. b743cca8 reverted a handshake that deadlocked against this
  path [F6].
- Faults: process pause / long txn on provider during add_node; latency
  provider<->new node; kill orchestrator between pause and resume; two
  overlapping add_nodes.
- Property: S13; WARNING "apply worker pause timed out" is a warning sign.

### L5. Error classifier allow-list: infrastructure errors still take the discard/disable path [F1, F4, F6, F8, F11, F12]
- Agreement: six focuses; the classifier list code-checked.
- Gaps: 57014 via `pg_cancel_backend` / SIGINT on the apply pid; 40001 under
  cluster-wide `default_transaction_isolation` (admitted in comment); class 58
  I/O errors (EIO on spill write or relation extend); 55006 from concurrent
  DDL; 25006; bare `elog(ERROR)` (XX000) on timing-dependent paths, e.g.
  `"a table synchronisation operation is failed"` (`src/spock_apply.c:4566`),
  "corrupt replay spill file" (`:4876-4927`), "ORIGIN message sent out of order".
- FATAL bypasses `PG_CATCH` and leaves the shmem `commit_lsn` marker:
  `handle_message` "incorrect spock message" (`:2928`), readonly FATAL in
  `replication_handler` (`:2982`), `spock_start_replication` FATAL. The next worker
  sees the retransmitted txn with the same `commit_lsn` and replays it under the
  policy -> TRANSDISCARD drops it / SUB_DISABLE disables (same shape as
  ed0a9945/db380dd8). SIGKILL is safe only because it wipes shmem. [F6, F8, F12]
- Resolution vs [F11]: `statement_timeout` set by `ALTER DATABASE/ROLE` is
  probably not armed in the apply worker (PG arms it only in
  `start_xact_command`, `postgres.c:2771-2787`); `pg_cancel_backend` is the
  reachable 57014 source. See 11.4.
- Faults: process signals (SIGINT to apply), I/O errors / disk faults, readonly
  toggles, DDL concurrent with apply.
- Property: S3 (no exception_log rows / no disabled subs with only infra faults);
  `unreachable` on "caught initial exception" in conflict-free runs.

### L6. Cross-upstream races turn resolvable conflicts into discarded transactions [F3, F4, F8, F10, F11]
- (a) Insert/insert race: `spock_apply_heap_insert` (`src/spock_apply_heap.c:837`,
  `TODO: do we need a retry finding a tuple?` ~874) looks up then inserts; a
  concurrent writer (other apply worker or local session) inserting the same key
  yields 23505, not on the transient list -> TRANSDISCARD drops the whole
  upstream txn instead of resolving `insert_exists`. Same for `update_exists`
  (`:740`). [F3 only]
- (b) Out-of-order arrival: n2 updates a row inserted by n3; n1 gets n2's update
  first -> `update_missing` -> TRANSDISCARD -> n1 permanently differs. Docs call
  `update_missing` "not resolvable" and admit "replication gap"
  (`docs/conflict_types.md:92-103`), so this is **expected** divergence for
  workloads that update rows inserted elsewhere (see Workload boundaries). The
  "short waits" claim (`docs/conflict_types.md:98`, `docs/configuring.md:283`) is
  not what the code does (L6c). [F3, F4, F8, F10, F11]
- (c) `read_retry_count` retries do not wait (`wait_for_previous_transaction`
  returns when `required_commit_ts == 0`). [F3, code-checked]
- Faults: asymmetric latency / partitions between pairs in a 3-node mesh;
  concurrent same-key inserts from several nodes.
- Property: no `exception_log` row with 23505 for workloads producing only
  insert/insert conflicts.

### L7. In-process replay: abort record advances origin to the failing txn's commit_lsn before replay commits [F2, F8, F12]
- Agreement: three focuses; `AbortOutOfAnyTransaction()` at `:4065` with
  `replorigin_session_origin_lsn = commit_lsn` (`:686`) code-checked; stock
  `RecordTransactionAbort` advances the session origin (`xact.c:1807`).
- The d286f3df comment says such an advance "silently skips that txn on
  reconnect"; [F8] notes decoding skips only when `commit ptr < start_decoding_at`
  (strict), so restart exactly at `commit_lsn` may resend. Unresolved (Open Q).
- If skip is real: a graceful exit during replay (connection error, SIGTERM,
  FATAL, idle timeout) loses the txn with no `exception_log` row; a postmaster
  crash does not (because of L1). [F12]
- Faults: real data error in a large txn + partition / provider pause / SIGTERM
  during replay.

### L8. DISCARD replay swallows transient errors per row [F8]
- During `discard` replay each row's subtransaction catch takes any error,
  including 40P01/55P03/OOM/disk full/cancel, and the origin advances anyway.
  Needs one real data error first, then a transient fault in replay.

### L9. Sync-standby feedback hold is overwritten in `send_feedback()` [F4, F12]
- Agreement: two focuses; code-checked (`src/spock_apply.c:3237-3277`).
  `get_feedback_position` sets positions only when a hold is released;
  `get_flush_position` then resets `writepos/flushpos` and, since
  `append_feedback_position` already drained `lsn_mapping`, returns true ->
  `flushpos = writepos = recvpos` (latest received). The publisher can be told
  "flushed" past what the subscriber's sync standby has.
- Faults: pause the subscriber's sync standby, keep provider writing, kill
  subscriber primary, promote standby.
- Property: P9.2 (no provider txn missing on the promoted subscriber).

### L10. Slot groups are switched on by slot-name spelling -> one stream split between subscribers, or apply hangs [F1, F2, F3, F5, F8, F11, F12]
- Agreement: seven focuses; code-checked.
- Any slot name ending `_<digit>`: subscription names like `sub_1`, `n2-1`
  (`-` -> `_`), or uppercase node names (`N1` -> `_1`, so `sub_N1_N2` on
  provider N1 for N2 and N3 both reduce to the same group) [F12]. Members skip
  txns another member claimed -> each subscriber silently misses part of the
  stream; subscriber side `wait_for_previous_transaction` may spin forever.
- Also: claimed-then-crashed member's txn never delivered while another member
  stays attached; unlocked `nattached--`; `free_group` NULL dereference when all
  groups are in use. f6887c7a (reject grouped names) not on main.
- Workload: keep names free of `_<digit>` endings and uppercase unless this is
  the target; consider one targeted config.

### L11. Undetectable deadlock: `SpockCtx->lock` held across a catalog transaction in SYNCWAIT [F3]
- Code-checked: `process_syncing_tables` takes `SpockCtx->lock` EXCLUSIVE then
  runs `set_table_sync_status` + commit (`src/spock_apply.c:4517-4552`).
  `spock_drop_subscription` deletes sync-status rows (uncommitted) then takes
  `SpockCtx->lock` (`src/spock_functions.c:779, 808`). Apply waits on B's xid
  holding the LWLock; B waits on the LWLock. Neither is cancellable; everything
  touching `SpockCtx->lock` (every applied row, manager, attach/detach,
  shutdown) piles up. Similar with `signal_worker_xact_callback` at COMMIT.
- Faults: none beyond timing; run `sub_drop`/`sub_remove_table`/`DROP TABLE`
  while a table sync finishes. `SPOCK_RANDOM_DELAYS` widens it.
- Property: admin ops return within a bound; no backend waits on
  `LWLock:spock context lock` for more than N s; fast shutdown completes.

### L12. Crashed sync worker / FAILED table: silent stop or indefinite wait [F2, F3, F5, F8, F11]
- Code-checked: error exit keeps `worker_type=SYNC` (`src/spock_worker.c:451-468`);
  `spock_sync_find` ignores `terminated_at` (`:560-578`); so
  `wait_for_sync_status_change` (`src/spock_sync.c:2639-2693`) keeps looping 60 s
  until the slot is reused, while the apply worker reads nothing (provider
  `wal_sender_timeout` drops it); `sub_show_status` still says `replicating`.
- `Assert(spock_worker_running(worker))` (`src/spock_apply.c:4532`) fires in a
  cassert build when the sync worker is gone -> whole-instance crash restart.
- Restart of a sync whose status is past INIT -> FAILED; FAILED tables are
  skipped by apply while the origin advances -> **silent permanent drift**;
  `sub_show_table` prints `unknown`. Sync workers in CATCHUP use `apply_work`, so
  any provider disconnect is enough.
- Also: missing sync-status row -> table assumed READY (`:4487-4494`) [F11].
- Faults: partition / provider restart / kill during table resync catch-up.
- Property: every table eventually `replicating` or visibly failed; no silent
  per-table skipping.

### L13. Initial sync interrupted in s/d/c -> permanently disabled subscription; slot leak [F1, F2, F5, F8, F9]
- Documented-ish behaviour ("nonrecoverable step"). Slot/origin cleanup needs
  ERROR (not SIGKILL) and a working provider connection; else the remote slot
  stays and pins WAL. `sub_wait_for_sync` polls every 200 ms with no timeout
  (`src/spock_functions.c:3456-3561`). Record as expected non-liveness; flag only
  hangs and leaked slots that grow WAL without bound.

### L14. Exception-log shmem slots leak; exhaustion -> LWLock held, out-of-bounds write, self-deadlock [F2, F3, F6, F8, F11, F12]
- Agreement on the leak: six focuses. Code-checked: slots keyed by sub name,
  never freed (TODO at `src/spock_apply.c:~798`); `elog(ERROR, "unable to find an
  empty exception log slot")` raised while holding `SpockCtx->lock` EXCLUSIVE
  (`:762-793`); no `LWLockReleaseAll` in the `PG_CATCH`; `AbortOutOfAnyTransaction`
  does nothing outside a txn. [F8] adds: `PG_CATCH` then writes
  `exception_log_ptr[-1]` (OOB into shmem) and the next `handle_begin` blocks on
  the lock it already holds -> node-wide hang.
- Reached after `max_worker_processes` distinct subscription names since
  postmaster start (add/remove-node cycles with fresh names). Same-named subs in
  two DBs share a slot; a re-created sub inherits old state;
  `SpockExceptionLog.local_tuple` is a process-private pointer in shmem. [F11, F12]
- Faults: none; workload churn of uniquely named subscriptions.

### L15. Apply and sync workers share one exception slot (same sub name) [F3, F8]
- Sync worker in CATCHUP runs `apply_work` with the same `MySubscription->name`;
  both write `commit_lsn` unlocked. A sync failure at LSN Z can make a later
  apply worker replay Z as already failed. Mostly sequential in practice.

### L16. `SpockGroupHash` never shrinks; `resource.dat` races and no CRC [F2, F3, F11, F12]
- Entries never deleted (`src/spock_group.c:41-42`); fixed size; full table ->
  `ERROR out of shared memory` (53200, assumed PG dynahash behaviour), which apply
  treats as transient (retry forever); at postmaster start
  (`spock_group_resource_load` in `shmem_startup_hook`) -> node does not start.
  Two subs to one provider share one entry (no sub id in key). [F2]
- `spock_group_resource_dump` (`:534-611`, code-checked): fixed tmp name,
  `O_TRUNC`, `apply_group_master_lock` only SHARED, `durable_rename`. Concurrent
  dumpers (several syncs finishing at once in add_node; shutdown dump while a sync
  runs) can interleave; second rename ENOENT -> ERROR **after** COPY committed,
  inside `PG_ENSURE_ERROR_CLEANUP` (drops slot and origin, status stays `d` ->
  disabled on restart). Short read at load -> ERROR at postmaster start. No CRC. [F2, F3]
- Faults: node restart soon after multi-peer add_node.
- Property: a node always restarts; no `could not rename "...resource.dat.tmp"`.

### L17. Reconcile resets add-node force-set progress [F2]
- `reconcile_progress_with_origin` runs at every apply start. On the new node,
  force-set wrote (N, C) before Phase 7 advances the origin; if that apply worker
  starts first (enabled early, or retry after partial failure), reconcile resets
  the entry to the origin LSN; Phase 7 then skips or falls back to
  `pg_current_wal_lsn()`.

### L18. Origin advances without WAL; `wait_for_sync_event` result not stable across a crash [F2, F5, F11]
- Empty txns and non-transactional `sync_event` call `replorigin_session_advance`
  only. After a subscriber crash `remote_lsn` can go back below a marker already
  reported reached; provider will not resend (slot already confirmed); origin
  stays behind until the next real txn. Also `remote_lsn` is advanced before the
  txn is visible in the procarray. Oracle note: re-run barriers after crashes.

### L19. Forwarded-origin advance is a separate WAL record after commit [F2, F4, F6, F12]
- `maybe_advance_forwarded_origin` (`src/spock_apply.c:5165-5183`) after
  `CommitTransactionCommand`. Crash in between -> direct sub (enabled later)
  re-receives -> delta double-count. Admitted in 401197ab. Also ERRCODE_OBJECT_IN_USE
  races (2948d567: "cannot prevent worker races").

### L20. ZODAN orchestration is non-atomic and partly "warn and continue" [F4, F5, F9, F10, F12]
- Phase 3 `create_sub` errors only NOTICE'd (code-checked); Phase 7 READY wait is
  warning-only; Phase 7 slot advance commits remotely before the local origin
  advance; fallback to `pg_current_wal_lsn()` logged as NOTICE; dblink calls have
  no timeout (a SIGSTOP'd peer hangs add_node); budgets use wall clock; orchestrator
  death leaves slots/origins/disabled subs (`zodan_cleanup.sql`). Past liveness
  bug 8de96369 (get_lsn_from_commit_ts waited over eleven minutes).
- Faults: kill orchestrator, partition, pause peers, clock jumps during add_node.

### L21. Manager uses worker pointers after releasing `SpockCtx->lock` [F3]
- `manage_apply_workers` (`src/spock_manager.c:41-176`) collects pointers under
  the lock, releases at `:54`, then reads/SIGTERMs/clears them. Concurrent sync
  registration can reuse a terminated slot -> SIGTERM to the wrong process or
  clearing a slot it no longer owns; reuse also erases a crashed worker's
  `terminated_at` (loses backoff). Unlocked writes in `wait_for_worker_startup`.

### L22. Backward clock step delays apply-worker restart by about the step [F5]
- `restart_time = terminated_at + restart_delay` vs wall-clock now. Faults:
  kill/terminate an apply worker, then step the clock back.

### L23. 1 ms respawn loops on unclassified errors / FATAL [F5, F8]
- `restart_delay_on_exception=0`; e.g. readonly FATAL, protocol 08P01, repeated
  data error outside replay. Could load CPU heavily in simulation.

### L24. Node-id edge values and id-space overlap [F2, F11, F12]
- Id 0 (`InvalidRepOriginId`): origin filter never filters it -> echo loops.
  Id 65535 (`DoNotReplicateId`): apply commits skip origin/commit-ts bookkeeping
  (`src/spock_apply.c:1123, 2958`) -> LUW uses local ts. Not rejected
  (code-checked). Node ids share the 16-bit space with real local roidents
  (`src/spock_conflict.c:400` compares them). Cascades never detect A/C collisions.

### L25. `spock.extra_connection_options` is ignored [F8, F9] (docs claim it applies, `docs/configuring.md:~216-228`)
- Code-checked (11.1). Users cannot change keepalives/timeouts; harness must not
  rely on it.

### L26. Partition / pause detection gaps [F5, F6, F8, F9]
- No `tcp_user_timeout`; real worst case is `apply_idle_timeout` (300 s). Blocking
  libpq, pg_dump and dblink without timeouts. SIGTERM cannot interrupt them.

### L27. SUB_DISABLE disable rolled back when the inner loop stops mid-transaction [F8]
- `spock_disable_subscription` writes into the open remote txn
  (`src/spock_exception_handler.c:232-276`), `apply_work` returns, proc_exit aborts
  it -> disable and exception row rolled back -> loop. Missing-relation txn split
  across network reads. TAP 016 may cover only the single-read case.

### L28. `sub_drop` side effects [F2, F3]
- Drops remote slot before local commit (non-transactional); orphaned slot if
  provider unreachable (WARNING only); running sync workers of the sub not killed
  (keep `<slot>_<hash>` slots and origins); waits as long as any local lock blocks
  the apply worker.

### L29. Spill-file replay queue not well proven [F6, F8]
- "keep DEBUG1 logging until spill-to-disk code is proven stable"; counter bumped
  before write; corrupt read -> XX000; EIO not transient; f84b853d already found a
  UAF. Default threshold 4 MB, easy to exceed in stress.

### L30. `wait_for_previous_transaction` exact-match wait with no timeout [F3, F5, F8, F11]
- Dormant unless slot groups; then a skipped, empty, filtered or non-monotonic
  predecessor hangs the worker. `include/spock_group.h:100` says `prev_remote_ts`
  "seems do nothing at the moment".

### L31. `spock.readonly=all` behaviour [F4, F5, F8, F12]
- Loop `break`s before reading; open remote txn holds locks until
  `apply_idle_timeout`, then reconnect loop every 300 s; FATAL per message if one
  gets through (marker left, L5). GUC re-read only on reload.

### L32. Smaller items
- `spock_apply_heap_delete` counts deletes as `SPOCK_STATS_UPDATE_COUNT`
  (`src/spock_apply_heap.c:1083`); do not build invariants on delete counters. [F3]
- Supervisor: manager crash sets `subscriptions_changed` without a latch; restart
  relies on `bgw_notify_pid` SIGUSR1 else 180 s. [F3]
- 327757ab (dboid race) narrowed, not closed: DB can be dropped between the
  syscache check and attach. [F6]
- `spock_common.c:438-481` `goto retry` on TM_Updated/TM_Deleted without limit. [F8, F11]
- `pg_dump` fork/exec: `fork()` -1 unchecked, child `ereport(ERROR)` in a forked
  backend, blocking `waitpid`. [F9]
- `get_tuple_origin` with commit ts off treats every row as remote-origin
  (silently apply-remote). [F9, F11]
- `wait_slot_confirm_lsn(NULL)` waits on every slot incl. dead ones, no timeout
  (`src/spock_monitoring.c:30-110`). [F5]
- `apply_delay` uses uninterruptible `pg_usleep`; "FIXME: deal with overflow?". [F5, F11]
- Failover-slot worker (PG15-17): one lagging slot blocks syncing others
  (`src/spock_failover_slots.c:990` TODO); log throttle uses `PG_WAIT_EXTENSION`
  as ms; partitioned physical standby stops all logical replication from that
  primary (walsenders cycle every `wal_sender_timeout`), by design. [F5, F11]
- Commit-ts subxact override entries and a crash between `COMMIT_TS_SUBTRANS_TS`
  and the commit record (delta apply + kill). [F9]
- Toggling `log_old_value` on one node only -> NULL old value -> plain overwrite
  -> delta lost. [F9]

---

## 10. Bug-history patterns mapped to components [F6]

- **Pattern A — transient failure misread as data fault** (5.1): eleven fixes;
  L5, L8, L23 are the remaining gaps.
- **Pattern B — LSN from the wrong stream or wrong end of a record**: 5f654e34
  (sync-standby sent local LSN as `confirmed_flush` -> loss after failover),
  986ad069 (progress stored commit start vs end -> duplicates), 3cf97588,
  401197ab, 8de96369 (`get_lsn_from_commit_ts` read ts=0 and picked a later LSN,
  "the direction that loses data"; now returns NULL), dcbba6bb (origin updated
  before `ProcArrayEndTransaction` -> loss on new node). L1, L7, L9 are this
  pattern.
- **Pattern C — add-node catch-up**: a9bc8652, f38da44a, dcbba6bb, 986ad069,
  b7fc7022 (keepalives bumped `received_lsn` past slot point), fa52495a,
  7d21b807 (resync on read-only subscriber truncated then failed -> loss),
  8de96369. L4, L17, L20.
- **Pattern D — progress persistence**: section 3 history; 5ee6276e garbage
  fields; 11b9d385 `nattached` decrement after slot reuse. L16, L18.
- **Pattern E — worker lifecycle / shmem ordering**: 24c3c01f, a95e44fb,
  11b9d385, 327757ab, f1e4f718 (NULL from full fixed-size hash, torn 64-bit reads).
  L11, L14, L21.
- **Failover slots** (PG15/16): 7339cb80, 84bb1111 (slot loss on promote),
  1ab8dd62 (PANIC loop), 6f3c775d (Assert/SIGABRT), 8220306d, f2d4bbbb. Lower
  priority on PG18.
- Other single fixes worth knowing: 4c7ed47a (relcache without
  `AcceptInvalidationMessages`), 3efae112, 16ce5af5, 34d473dc/f21e71bc (peer
  sessions pinned to ISO datestyle; peer timestamps must carry UTC offset),
  fdd9587e, 64ea462d (introduced L2).

---

## 11. Contradictions between focuses, resolved by reading code

1. **`spock.extra_connection_options`** — [F1] "adds more", [F5] "prepended so
   later keys win" vs [F8, F9] "ignored". **Resolved: ignored.** `src/spock.c:378-381`
   appends it only to StringInfo `s`, used solely in `errdetail("dsn was: %s")`;
   `vals[0] = connstr`. The hard-coded keepalive/connect_timeout keys follow
   `dbname`, so they also override the DSN.
2. **`wal_sender_timeout=0` on replication connections** — [F6] (2535c3fa sets it)
   vs [F9] (removed by 7a8a9858). **Resolved: not set.** `spock_connect_base` sets
   no such option; release notes `docs/spock_release_notes.md:190-196` are stale.
3. **Crashed sync worker** — [F5] "wait returns false when the sync worker is
   gone" vs [F3, F8] "waits forever". **Resolved: both, by exit kind.** Clean
   exit resets `worker_type` to NONE -> `spock_sync_find` returns NULL -> ERROR
   "a table synchronisation operation is failed". Error exit keeps
   `worker_type=SYNC` (`src/spock_worker.c:451-468`) and `spock_sync_find` ignores
   `terminated_at` -> wait continues every 60 s until slot reuse.
4. **`statement_timeout` as a 57014 source** — [F11] "`ALTER DATABASE SET
   statement_timeout` drops a good txn" vs [F8] "statement_timeout does not apply
   to bgworkers". **Resolved toward [F8]:** stock PG arms statement_timeout in
   `start_xact_command()` (`postgres.c:2771-2787`), which the apply path does not
   use; spock never sets it. `pg_cancel_backend`/SIGINT remains a real 57014
   source (`bgworker.c:763` installs `StatementCancelHandler` for DB-connected
   workers). `lock_timeout` from ALTER DATABASE does fire but is 55P03 (transient).
5. **ZODAN Phase 7 resume LSN source** — [F10] (tutorial: `spock.lag_tracker`
   commit_ts converted with `spock.get_lsn_from_commit_ts()`) vs [F1, F2, F4]
   (`spock.progress.remote_commit_lsn`). **Resolved: code uses `spock.progress`**
   (`samples/Z0DAN/zodan.sql:2638-2648`); `lag_tracker` is only used for lag
   monitoring (`:1003, 1071`). The tutorial describes an older method;
   `get_lsn_from_commit_ts` has no in-tree caller [F6].
6. **Fallback log level** — [F4] "NOTICE", [F9, F12] "WARNING". **Resolved:**
   `RAISE NOTICE '    WARNING: No spock.progress entry ...'`. A filter on log
   level WARNING will miss it; match on text.
7. **`pause_timeout` and wall clock** — [F12] lists it among wall-clock timers;
   [F5] says not. **Resolved toward [F5]:** worker side uses
   `ConditionVariableTimedSleep`; caller side counts 1 ms `pg_usleep` iterations.
   Neither reads wall time, so clock jumps do not shift it.
8. **`exception_replay_queue_size` default** — [F1] gives units only, [F8] says
   4 MB. **Resolved: 4 MB** (`src/spock.c:1406-1418`).
9. **Phase 3 failure handling** — [F5] "only NOTICE", [F9] "warn and continue".
   Same meaning; code is `RAISE NOTICE` in `EXCEPTION WHEN OTHERS`
   (`zodan.sql:2033-2036`).
10. **Initial-copy row timestamps** — [F9] asked whether copied rows carry the
    local copy time and could beat later changes. **Resolved (code reading):** the
    COPY target session runs `pg_replication_origin_xact_setup('0/0','epoch')`
    (`src/spock_sync.c:944-947`), so copied rows carry an epoch ts and lose every
    later LUW comparison [F4]; they do not beat later changes.
11. **Line numbers** for the readonly FATAL differ (2981-2983 vs 2999-3001);
    current HEAD is `src/spock_apply.c:2982`. Classifier ranges differ by a few
    lines between focuses; 3867-4133 is the `PG_CATCH` block.

---

## 12. Workload boundaries (avoid false positives)

The workload must respect these, or properties must be scoped to allow them.
[F10 unless noted, plus F4, F7, F8, F11]

**Expected divergence (documented; do not flag as bugs):**
- **No tombstones.** Concurrent DELETE (n1) and later UPDATE (n2): n2 keeps the
  row (`delete_exists`), n1 logs `update_missing` and (TRANSDISCARD) drops n2's
  txn. A late INSERT after `delete_missing` resurrects the row on that node only.
- **`update_missing` ordering in 3+ node meshes.** An UPDATE/DELETE of a row
  inserted on another node can reach a third node before the INSERT
  (`docs/conflict_types.md:92-103`, "may never have arrived due to a replication
  gap"). Permanent divergence plus an `exception_log` row is documented
  behaviour.
- **Permanent node loss needs ACE.** Survivors that missed some of a dead node's
  txns are not repaired by Spock (`docs/recovery/catastrophic_node_failure.md`).
  Do not assert survivor convergence after permanently removing a node; kill and
  restart with the same data dir must converge. Same for `remove_node`: the
  removed node's last writes may exist on some peers only.
- Clock skew changing which write wins is expected; different winners on
  different nodes is not.
- `discard` mode makes remote txns non-atomic by design.
- `sub_alter_skiplsn` and `repair_mode` drop changes by design.
- Interrupted initial sync -> disabled; interrupted table sync -> FAILED. Needs an
  operator (record, but flag silent skipping and hangs).
- Frozen tuples / truncated commit_ts -> remote always wins, unlogged.
- Deferrable unique constraints -> duplicates (documented).
- Sequences are not replicated in real time; `serial` keys on several nodes
  collide (insert_exists overwrite looks like a lost row). The periodic sync is
  dead code (2.8).

**Workload must not (v1):**
- UPDATE/DELETE on tables without PK / valid replica identity; standalone
  `REPLICA IDENTITY FULL`.
- More than one UNIQUE index/constraint per replicated table (only one is used;
  `check_all_uc_indexes` is experimental).
- DDL while writes are in flight or during fault phases (no cross-origin DDL
  ordering; AutoDDL `DROP TABLE` and `CREATE TABLE AS` unsafe in 3+ nodes). Keep
  DDL in quiesced phases with slots caught up.
- Rely on FK enforcement or `TRUNCATE ... CASCADE` / `RESTART IDENTITY` across
  nodes.
- Use UNLOGGED/TEMP tables, large objects (needs lolor), volatile row filters,
  column filters or late partitions in v1.
- Mix Spock with native logical replication in the same DB (shared 16-bit
  origin space); modify the `spock` schema directly.
- Use `forward_origins` inside a mesh (only allowed for a single-sub cascade;
  any non-empty value forwards every origin).
- Use subscription/node names that end in `_<digit>` or contain uppercase
  letters (slot groups, L10) unless that is the test target.
- Use delta-apply columns that are nullable, or toggle `log_old_value` on one node
  only.
- Hold `spock.readonly=all` longer than slot WAL retention.
- Treat `sub_show_status = replicating` as "caught up"; use
  `sync_event` + `wait_for_sync_event` for every ordered node pair, with timeouts
  of at least `apply_idle_timeout` (or lower that GUC).
- ZODAN preconditions: auto_ddl off on all nodes, no DDL during add, identical
  roles and Spock config, all nodes available, new node not serving clients,
  clean up with `remove_node` before retry. An add_node that fails under faults is
  acceptable; one that succeeds with missing or duplicated rows is a bug.
- Use `exception_behaviour=discard` when checking per-txn atomicity (use
  `transdiscard` or `sub_disable`).
- Set cluster-wide `default_transaction_isolation` above READ COMMITTED (40001 ->
  discard path; admitted gap) unless testing that.
- Use `pgbench`-style net-zero scripts as the only convergence check (TAP 011
  weakness); use per-row ledgers / ordered checksums.

**Fairness notes:** PG18+ conflict stats reset after crash; `spock.progress` is
rebuilt heuristically after crash; delete counters are wrong (L32). None are
reliable oracles across crashes.

---

## 13. Failure-prone areas / attack surfaces ranked for Antithesis

| Rank | Area | Leads | Why |
|---|---|---|---|
| 1 | Apply exception classifier + shmem marker (`apply_work` PG_CATCH, `handle_begin`, `handle_commit`) | L5, L7, L8, L14, L15, L23, L27 | densest bug history; every miss is silent loss or spurious disable; default TRANSDISCARD hides it |
| 2 | Origin/LSN bookkeeping across crashes | L1, L18, L19, L9 | L1 has three-way agreement and code support; duplicates break delta counters |
| 3 | ZODAN add_node + provider pause + peer progress | L4, L17, L20, L16 | seven-way agreement on L4; repeated data-loss fixes; non-atomic orchestration |
| 4 | LUW with clock skew, restarts, equal timestamps | L2, L3 | untested (005 disabled); core patch TODO admits L3 |
| 5 | Multi-upstream apply ordering and races | L6 | no tests with concurrent conflicting writers + faults |
| 6 | Table/initial sync handshake | L12, L13, L11 | Assert in cassert; silent FAILED skip; LWLock deadlock |
| 7 | Worker lifecycle and pacing | L21, L22, L23, L32 | wall-clock restart timing; slot reuse races |
| 8 | Connection loss detection | L26, L25 | 300 s worst case; blocking libpq/dblink/pg_dump |
| 9 | Slot groups (configuration-triggered) | L10, L30 | silent stream split; only with certain names |
| 10 | Failover / standbys | L9, S9 | second-phase topology; L9 needs standby container |
| 11 | Progress persistence (`resource.dat`, reconcile) | L16, L17 | restartability; feeds ZODAN |
| 12 | Spill-to-disk replay queue | L29 | new code, one UAF already |

---

## 14. Fault-type requirements

| Lead / property | Node termination (kill -9 / postmaster crash) | Graceful worker exit (SIGTERM / pg_terminate / pg_cancel) | Network partition / latency | Process pause (SIGSTOP) | Clock jitter / skew / step | Other |
|---|---|---|---|---|---|---|
| L1 duplicate apply after crash | **required** (between checkpoints) | | | | | large `checkpoint_timeout`; delta columns |
| L2 tiebreak divergence | | | helps order arrival | | **required** (equal ts) | 3+ writers same keys |
| L3 clock not restart safe | **required** (restart) | | | | **required** (node behind) | |
| L4 add_node pause window | kill orchestrator / provider | | latency provider<->new | **required** (stall slot creation > 10 s) | | long txn on provider; concurrent add_nodes |
| L5 classifier gaps | (SIGKILL is safe path) | **required** (SIGINT/cancel, FATAL paths) | | | | I/O error injection; readonly toggle; DDL during apply |
| L6 cross-upstream races | | | **required** (asymmetric) | | | concurrent same-key inserts |
| L7 replay origin advance | compare with crash | **required** (exit during replay) | partition during replay | provider pause | | real data error in large txn |
| L8 DISCARD per-row swallow | | cancel | | | | lock contention during replay |
| L9 sync-standby hold | **required** (kill subscriber primary) | | | **required** (pause standby) | | standby container + promote |
| L10 slot groups | walsender kill | | | | | names ending `_<digit>` / uppercase |
| L11 LWLock deadlock | | | | | | timing only; `SPOCK_RANDOM_DELAYS` |
| L12 sync worker death | kill sync worker (cassert -> crash) | ERROR exit | **required** (during catch-up) | provider pause | | |
| L14 exception slot exhaustion | (restart clears) | | | | | subscription churn with unique names |
| L16 resource.dat | restart after add_node | | | | | multi-peer add_node |
| L18 sync_event durability | **required** | | | | | |
| L19 forwarded origin | **required** | | | | | cascade with `forward_origins` |
| L20 ZODAN non-atomic | kill orchestrator / peers | | **required** | pause peers (dblink hang) | step clock (budgets) | |
| L22 restart delay | | **required** (kill worker) | | | **required** (step back) | |
| L26 detection gaps | | | **required** (silent drop) | **required** | forward jump -> spurious reconnect | |
| V1 reconnect | yes | yes | yes | yes | | allow >= 305 s or lower `apply_idle_timeout` |

Notes:
- Distinguish **postmaster-level kill** (wipes shmem; masks L5/L7 marker bugs, exposes L1/L3/L18) from **single-worker graceful exits** (exposes L5/L7). Antithesis process kill of any backend usually means the former.
- Clock faults are the only way to reach L2/L3; existing tests never run nodes with different clocks (containers share the host kernel clock unless Antithesis virtualises it).
- Process pause is the only cheap way to stretch `CREATE_REPLICATION_SLOT` beyond `pause_timeout` (L4).

---

## 15. Build & environment notes for setup [F7, F9, F12]

- **Patched PostgreSQL is mandatory.** Build PG from source with every file in
  `patches/<major>/` applied in lexical order (`patch -p1`). Local builds
  without the patches (per user notes: pg17-back, pg18) will not work. PG18 is
  the likely target; version-switching TAP tests need PG18. On PG18 the
  failover-slot worker is not registered.
- **Reuse `tests/docker`**: `Dockerfile-base.el9` (Rocky 9 + deps, published as
  `ghcr.io/pgedge/base-test-image:latest`) and `Dockerfile-step-1.el9` (args
  `PGVER`, `PG_REF`, `SPOCK_RANDOM_DELAYS`, `ENABLE_INJECTION_POINTS`, `MAKE_JOBS`).
  Configure: `--enable-debug --enable-cassert --enable-tap-tests
  [--enable-injection-points] --with-llvm --with-python ... CFLAGS="-g -O0"`.
  **cassert is on**, so the SYNCWAIT Assert (L12) and progress Asserts
  (`src/spock_group.c:345-361, 449-451`) turn into whole-instance crashes.
- **Hermeticity**: Dockerfile fetches PG source (`tests/resolve-pg-ref.sh` reads
  `tests/postgres-build.conf`, all majors `tag` = newest `REL_<major>_*`) and
  clones spockbench master unpinned. Pin `PG_REF`, vendor or drop spockbench;
  lolor (only for 032/033 scenarios) must be prebuilt. Nothing needs the network
  at run time.
- **Compose today**: services n1/n2/n3, `TZ=America/Toronto`, host ports
  15432-15434, `cap_add SYS_PTRACE SYS_ADMIN`, `/cores` mounts, data dir **not a
  volume**, postgres is PID 1 (a crash ends the container; no restart policy),
  `depends_on` chain with healthcheck (`pg_isready` + `/tmp/spock_init_complete`).
  `entrypoint.sh` builds the mesh at container start (n1 `node_create` with
  `info '{"tiebreaker":"1"}'`; n2/n3 load zodan.sql and `CALL spock.add_node`).
  For Antithesis: move cluster formation to a separate setup step, replace
  `depends_on` with readiness waits, and run postgres under a supervisor so
  kill/restart does not end the container.
- **postgresql.conf minimum**:
  ```
  shared_preload_libraries = 'spock'
  wal_level = logical
  track_commit_timestamp = on
  max_worker_processes = 32          # supervisor + manager/db + apply/sub + sync/sub (+ exception slots = this value, L14)
  max_replication_slots = 32         # >= 2 * subs, plus physical/standby slots
  max_wal_senders = 32
  max_active_replication_origins = >= (N-1) * DBs   # PG18+; consider extra headroom for L1 redo states
  output_plugin_libraries = 'pgoutput, test_decoding, spock_output'   # only if the GUC exists (PG 15.19/16.15/17.11/18.6/19+)
  listen_addresses = '*'
  wal_sender_timeout = '5min'
  spock.conflict_resolution = 'last_update_wins'
  spock.save_resolutions = on        # for "explained divergence" oracle
  spock.exception_behaviour = transdiscard   # default; run a sub_disable variant too
  # Consider: spock.apply_idle_timeout lower (e.g. 30-60 s) to shorten liveness windows
  ```
  `pg_hba.conf`: `host all all 0.0.0.0/0 trust` and `host replication all ... trust`.
  Probe `output_plugin_libraries` with `postgres --describe-config` (as
  `entrypoint.sh`, `SpockTest.pm` do); setting it on an older minor stops the
  postmaster. DSNs must use resolvable hostnames.
- **rmgr 144**: any server replaying Spock WAL (physical standby, PITR,
  `pg_waldump`) must have spock in `shared_preload_libraries` or recovery fails
  with "resource manager with ID 144 not registered". Standby images need the
  preload line (c2d87f5e moved registration before the binary-upgrade return).
- **Timing helpers**: `make SPOCK_RANDOM_DELAYS=1` adds 1-100 ms sleeps at worker
  attach (`src/spock_worker.c:350`), detach (`:423`), `handle_begin`
  (`src/spock_apply.c:668`) and after BEGIN in the walsender
  (`src/spock_output_plugin.c:662`). With `--enable-injection-points` (PG17+),
  named points `spock-worker-delay` and `spock-output-txn-stall` via the core
  `injection_points` module. Not both at once. `spock.output_delay` GUC changes
  cross-upstream arrival order. `NO_LOG_OLD_VALUE` disables delta apply. These
  hook sites are natural places for Antithesis SDK assertions.
- **pg_dump/pg_restore** must sit next to `postgres` with the same major
  (structure sync). Temp dump files go to `spock.temp_directory` (default
  `$TMPDIR`/`/tmp`).
- **ZODAN** needs `CREATE EXTENSION dblink` on the new node and
  `psql -f samples/Z0DAN/zodan.sql`; `spock.sync_timeout` controls its waits.
- **Topology for v1** (consensus of [F4, F10]): 3-node full mesh, one DB, default
  `forward_origins`, TRANSDISCARD, `save_resolutions=on`, AutoDDL off during
  faults, lowercase names without `_<digit>` endings. Phase 2: standby
  containers (L9, S9), add/remove node loops (L4, L14), mixed-version rolling
  upgrade (two builds).

### 15.1 Oracles available
- `spock.sync_event()` + `CALL spock.wait_for_sync_event(NULL, origin, lsn, timeout, wait_if_disabled)` per ordered pair (`timeout=0` waits forever; polls every 200 ms using wall time).
- `spock.wait_slot_confirm_lsn(NULL, NULL)` (no timeout; blocked by dead slots).
- `spock.exception_log`, `spock.exception_status(_detail)`, `spock.resolutions`, `spock.subscription.sub_enabled`, `spock.sub_show_status`, `spock.sub_show_table`, `spock.lag_tracker`, `spock.progress`, `pg_replication_origin_status`, `pg_replication_slots`, `spock.xact_commit_timestamp_origin(xid)`, `pg_xact_commit_timestamp_origin(xmin)`.
- `spock.apply_change_logging=key_only|verbose` per-change JSON for triage.
- Log lines worth `sometimes`/`unreachable`: "connection error during apply, exiting via rethrow", "transient error (deadlock/lock timeout)", "transient resource error", "caught initial exception", "apply worker pause timed out", "falling back to pg_current_wal_lsn()", "have equal tiebreaker value", "wins over %d by tiebreaker", "unable to find an empty exception log slot", "could not rename", "initialization failed during nonrecoverable step".
- Build own: ordered per-table checksum after quiesce; append-only ledger
  `(origin_node, seq)` for exactly-once; delta counter table for idempotency;
  payload columns `(node_name, local_seq)` for LUW winner checks.

---

## 16. Assumptions

1. **Stock PG origin behaviour** (L1, L7): commit records carry
   `replorigin_session_origin`; `xact_redo_commit/abort` advance
   `XLogRecGetOrigin(record)`; `RecordTransactionAbort` advances the session
   origin when set. Checked in a local stock PG 17 tree (`REL_17_10`+), not in the
   patched PG18 tree; the pgEdge patch file lists do not touch these functions.
   Matters because L1 and L7 depend on it.
2. **Decoding skip rule** is strict `commit ptr < start_decoding_at`
   (`SnapBuildXactNeedsSkip`), and the walsender raises a start below
   `confirmed_flush` to `confirmed_flush`. Matters for L7 and S7.
3. **PG dynahash** `HASH_ENTER` on a full `HASH_FIXED_SIZE` shared table raises
   53200 rather than returning NULL. Matters for L16.
4. **`XLogShmemInit` zeroes `XLogCtl`**, so the logical clock restarts at 0
   after every postmaster start (consistent with the patch TODO). Matters for L3.
5. **`simple_heap_update` waits on an in-progress updater/deleter xid**, and
   `XACT_EVENT_COMMIT` callbacks run before heavyweight locks are released.
   Matters for L11.
6. **Bgworker signals**: DB-connected bgworkers get `StatementCancelHandler` for
   SIGINT; spock overrides only SIGTERM. `statement_timeout` is not armed in the
   apply path. Matters for L5.
7. **libpq** processes `expand_dbname` keys in array order, so later keys
   override DSN values. Matters for keepalive settings and L25.
8. **Postmaster crash-restart** (`restart_after_crash=on`) follows SIGKILL of any
   backend/bgworker and reinitialises shmem, including the exception array (not
   traced through every `ShmemInitStruct`). Matters for which leads a kill can reach.
9. **The Antithesis build will be cassert** (as `Dockerfile-step-1.el9`), so
   Asserts are crashes.
10. **Target is PG18**, so failover-slot worker leads are lower priority.
11. **`hashtext(name) & 65535` equals Spock's node id** (both `hash_any` over the
    name bytes) — unverified; check against `spock.node` before choosing
    colliding names for L1/L24.
12. **spockbench** produces overlapping-row conflicts with delta apply on
    balances; `spockbench-check` content is external and unknown.
13. **One database per instance** in v1; cross-DB effects of the global pause
    flag and name-keyed exception slots need two or more DBs.
14. The `spock.add_node` used is `samples/Z0DAN/zodan.sql` (no in-extension
    version).
15. **`pg_replication_origin_xact_setup` before `BEGIN` in the same multi-statement
    query** applies to the COPY transaction (so copied rows carry epoch ts). Matters
    for 11.10.

---

## 17. Open Questions

1. **L1:** after a subscriber SIGKILL between checkpoints, does the subscription
   origin roll back and do node-id-numbered origin states appear in
   `pg_replication_origin_status`? *Why:* if yes, exactly-once and delta-apply
   properties fail under plain crash faults; it may be the top target. A short
   TAP run settles it. [F1, F11, F12]
2. **L7 / S7:** does restart exactly at `commit_lsn` resend the transaction, or
   skip it (d286f3df says skip)? *Why:* decides whether graceful exits during
   replay lose data and whether SUB_DISABLE resume works as claimed. [F2, F8, F12]
3. **L4:** is the worker-side `pause_timeout` self-resume intended to override a
   still-running orchestrator, and does snapbuild cover the xid-less window?
   Is the instance-wide flag intended? *Why:* defines whether add_node loss
   under slow slot creation is a bug or a tuning issue. [F2, F3, F5, F6, F8, F11]
4. **L2:** is equal-timestamp tie-breaking meant to converge with 3+ writers?
   Which pair should be compared? *Why:* determines whether equal-ts divergence
   is a bug or a documented limit. [F6, F10, F11]
5. **L3:** is there any plan or existing code to restore the logical clock at
   startup or promotion (from WAL, `pg_commit_ts` or `spock.progress`)? Is a
   maximum clock skew documented? *Why:* clock+restart divergence is otherwise
   expected and must be scoped out. [F1, F4, F9, F11, F12]
6. **Convergence contract:** does the team accept no-tombstone and cross-origin
   `update_missing` divergence (strict vs "explained by exception_log")? *Why:*
   chooses the main convergence property's form. [F4, F10, F11]
7. **Progress contract:** is `spock.progress` monitoring or deduplication state
   (design doc vs code comments)? *Why:* decides whether L16/L17/L18 are
   correctness or monitoring bugs. [F2, F4, F12]
8. **L10:** are slot groups supported? Will f6887c7a be merged? Do any
   deployment tools generate uppercase or `_<digit>` names? *Why:* decides
   whether to test or just avoid this configuration. [F1, F3, F11, F12]
9. **L9:** is overwriting `writepos/flushpos` after `get_feedback_position`
   intended? *Why:* sync-standby failover safety claim depends on it. [F4, F12]
10. **L12/L13:** what is the intended recovery for FAILED tables and for a sync
    worker that dies in SYNCWAIT/CATCHUP? Is silently skipping a FAILED table's
    changes intended? *Why:* separates expected non-liveness from silent drift.
    [F2, F5, F8]
11. **L5:** should 57014, 40001, class 58 and FATAL-mid-transaction be treated as
    transient? Which other FATAL/proc_exit sites exist mid-transaction? *Why:*
    each is a silent-discard path under default TRANSDISCARD. [F6, F8, F11]
12. **L11:** can `sub_drop` ever run while the apply worker is in SYNCWAIT
    handling, or does something serialise them? *Why:* confirms a hang that
    blocks shutdown. [F3]
13. **L14:** confirm the self-deadlock and OOB write after exception-slot
    exhaustion. *Why:* add/remove-node loops will reach it. [F8]
14. **Restart pacing (L22, L23):** is a dead worker staying down for the size of a
    backward clock step acceptable? Is a 1 ms respawn loop acceptable? *Why:*
    defines liveness bounds and CPU behaviour in simulation. [F5]
15. **ZODAN:** is add_node expected to "succeed" with a Phase 3 subscription
    missing? Does `remove_node` reliably clean up partial adds so a retry is
    valid? How often does the `pg_current_wal_lsn()` fallback fire in CI logs?
    *Why:* defines "fails cleanly or succeeds correctly". [F5, F10, F12]
16. **`spock.extra_connection_options`:** dead GUC or regression (docs say it
    applies)? *Why:* harness cannot tune keepalives through it. [F8, F9]
17. **Unscheduled fault tests** (020_sync_standby, 023, 026, 027, 029, 101, 102,
    104): why are they out of every schedule — flaky, slow, or need root? *Why:*
    flakiness would point straight at Antithesis targets. [F6, F7]
18. **`spockbench-check`:** does it compare across nodes or only per node, and can
    spockbench be pinned? *Why:* reuse as an oracle in a hermetic image. [F7]
19. **Async physical standby of a subscriber:** is the loss window on failover
    (provider slot already past what the standby received) accepted and
    documented? *Why:* scopes S9 properties. [F9]
20. **pg_dump under partition:** any timeout around structure sync besides the
    DSN? *Why:* a hang blocks add_node and sub_create with sync indefinitely. [F9]
21. **Recovery windows:** what lag/recovery bound after clock jumps (FAQ "~5
    minutes") and partitions should liveness properties allow? *Why:* sets
    property timeouts. [F5, F10]
22. **Scope:** are physical-standby failover and mixed-version rolling upgrade in
    scope for the first harness? *Why:* each needs extra containers or a second
    build. [F10]
23. **`read_peer_progress` INNER JOIN:** under what crash timings is a peer's
    progress entry missing on the provider after restart? *Why:* missing entry
    silently drops a peer from add_node catch-up. [F2, F4]
24. **Docs drift:** the ZODAN tutorial describes the `lag_tracker` +
    `get_lsn_from_commit_ts` method, release notes claim `wal_sender_timeout=0`,
    install docs list jansson, limitations claim periodic sequence sync. Should
    property wording follow code or docs? *Why:* claims quoted in properties must
    match what the code does. [F2, F4, F9, SYN]
