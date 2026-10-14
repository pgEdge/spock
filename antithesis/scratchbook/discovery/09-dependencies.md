# 09 — External Dependencies and Integration Points

SUT: pgEdge Spock @ 69d9228f (main), SPOCK_VERSION "6.0.0" (include/spock.h:27).
Focus: things Spock depends on but does not control, how failures in each are
handled, and what a container build needs.

---

## Findings

### 1. PostgreSQL core and the pgEdge core patches

**Supported PG majors:** 15, 16, 17, 18, 19 (README.md:48; CI matrices in
.github/workflows/installcheck.yml:38, nightly_tap.yml:91, zodan_sync.yml:19,
random-delays-regress.yml:22). Per-major code lives in `src/compat/{15..19}`
(Makefile `vpath % src src/compat/$(PGVER)`). CI builds against the newest
`REL_<major>_*` tag for each major (tests/postgres-build.conf:
`pg15_ref=tag` ... `pg19_ref=tag`, resolved by tests/resolve-pg-ref.sh).

**The patches are required, not optional.** The built `spock.so` has
undefined symbols that only exist in a patched server:
`remoteTransactionStopTimestamp`, `SubTransactionIdSetCommitTsData`
(checked with `nm -D --undefined-only spock.so`), and spock_relcache.c:148-171
reads `aopt->delta_apply_function`, a struct field the attoptions patch adds.
On vanilla PostgreSQL Spock does not compile, and a mismatched .so fails to
load from `shared_preload_libraries`, so the postmaster does not start.
(Dockerfile-step-1.el9 prints "No patches found ... continuing with vanilla
source" if `patches/${PGVER}` is empty; Spock's build would then fail.)
The `NO_LOG_OLD_VALUE` make flag only removes `build_delta_tuple()`
(spock_apply_heap.c:105, 508-581); it does not make the patches optional.

Patches by version (`patches/<major>/`, applied with `patch -p1` in file order):

| Patch | Versions | What it changes in core | Spock feature that needs it |
|---|---|---|---|
| `pgNN-010-allow_logical_decoding_on_standbys.diff` | 15 only | Backport of PG16 logical decoding on standby (`pg_log_standby_snapshot()`, decode.c, logical.c, slot.c, walsender.c, xlog.c). Last change 11576186 rearranged it for the back-patched upstream fix aae05622a7c. | No direct call in `src/` (grep finds no `pg_log_standby_snapshot`/`LogStandbySnapshot`). Presumably needed for failover-slot / standby decoding on PG15. |
| `pgNN-015-attoptions.diff` | 15–19 | Adds two per-column attribute options in reloptions.c: `log_old_value` (bool) and `delta_apply_function` (string), adds fields to `AttributeOpts` (attoptcache.h). heapam.c: new `HeapDetermineLogOldColumns()`; `ExtractReplicaIdentity()` merges columns marked `log_old_value` into the old-key tuple written to WAL for UPDATE (skipped for catalog relations). | Delta-apply conflict avoidance (`ALTER TABLE ... ALTER COLUMN ... SET (log_old_value=true, delta_apply_function=...)`). Provider side ships old values; subscriber side spock_relcache.c:126-171 looks up the function, spock_apply_heap.c `build_delta_tuple()` computes `f(old_remote, new_remote, local)`. |
| `pgNN-025-logical_commit_clock.diff` | 15–19 | xact.c/xlog.c: a "Lamport" logical clock in shared memory (`XLogCtl->lastTransactionStopTimestamp`). New hook `XLogReserveInsertHook` called **while holding the WAL insert spinlock** in `ReserveXLogInsertLocation()` / `ReserveXLogSwitch()`; `XactLogCommitRecord()` installs `EnsureMonotonicTransactionStopTimestamp`. For a local commit, if `logical_clock >= xact_time` the commit's `xact_time` is set to `logical_clock+1` and the WAL record CRC is recomputed (`XLogRecordCorrectCRC`). For an apply-worker commit (`remoteTransactionStopTimestamp != 0`) the clock only moves forward to `max(clock, xact_time, remote_ts)`; the apply transaction's own timestamp is not changed. | Last-update-wins conflict resolution: makes local commit timestamps increase in commit-LSN order, and pushes a node's local clock past any remote commit timestamp it has applied (so a later local write beats the remote row even if this node's wall clock is behind). Spock sets `remoteTransactionStopTimestamp = commit_time` just before `CommitTransactionCommand()` in `handle_commit` and clears it afterwards (spock_apply.c:1056-1063). `spock.get_lsn_from_commit_ts()` (spock_functions.c ~4250-4275) scans WAL and stops at the first local commit with `xact_time > target`, which is only correct if local commit timestamps are monotonic in LSN order. |
| `pgNN-030-per-subtrans-commit-ts.diff` | 15–19 | commit_ts.c: `SubTransactionIdSetCommitTsData(xid, ts, nodeid)` keeps a per-backend override list (TopMemoryContext) consulted by `TransactionTreeSetCommitTsData()` so a subtransaction xid gets its own commit ts/origin; writes a new WAL record `COMMIT_TS_SUBTRANS_TS` (0x20) and replays it in `commit_ts_redo`. | Delta-apply forced updates: when last-update-wins would keep the local row but delta-apply must still change it, spock_apply_heap.c:740-780 runs the update in `BeginInternalSubTransaction("SpockDeltaApply")` and calls `SubTransactionIdSetCommitTsData(GetCurrentTransactionId(), local_ts, local_origin)` so the row keeps its **original** commit ts/origin instead of taking the apply transaction's. |

Patches no longer shipped (mentioned in code): `pg18-020-LOG-to-DEBUG1` is now
done by Spock's `emit_log_hook` (`log_message_filter`, spock.c ~1076-1110);
`check_simple_rowfilter_expr()` was moved into compat/19 instead of patching
core (52981976). `tests/docker/spock.patches/commit_order_test.patch` is a
stale patch against `spock--4.1.0.sql` and nothing applies it.

**Antithesis-relevant claims and weak points in the patches:**

- **The logical clock is not restart-safe (stated in the patch).**
  `EnsureMonotonicTransactionStopTimestamp` comment: *"TODO: This is not
  postmaster restart safe. If the local system clock is further behind other
  nodes than it takes for the postmaster to restart ... local transactions will
  not be bumped into the future correctly."* `lastTransactionStopTimestamp`
  lives only in `XLogCtl` shared memory, is not WAL-logged, and is not rebuilt
  during recovery. After a crash/restart, local commit timestamps fall back to
  the wall clock until the next applied remote commit raises the clock again.
  Fault combination to try: clock skew (node behind) + kill/restart + local
  write to a row that was last written by a remote node → the newer local
  write may get an older timestamp and **lose** LUW on peers (and on this node
  too when the remote change is re-sent), i.e. divergence or a lost update.
  Also breaks the "monotonic in LSN order" assumption behind
  `spock.get_lsn_from_commit_ts()` across a restart (early `break` → returns an
  earlier LSN than intended).
- The same restart problem applies after **physical standby promotion**: the
  promoted node's clock starts from its wall clock.
- The hook runs inside the WAL insertion spinlock and edits the record after
  the CRC was computed; any bug there corrupts WAL (CRC recompute only when
  `XLogReserveInsertHookModifiedRecord`). Global hook variables are reset in
  `StartTransaction` and after `XLogInsert` in `XactLogCommitRecord`.
- Commit-ts override list in the startup process during redo: entries added by
  `COMMIT_TS_SUBTRANS_TS` replay are cleared when the next commit is replayed
  (cleanup in `TransactionTreeSetCommitTsData`). Matching is by xid, so a stale
  entry from an aborted transaction should be harmless, but a crash between the
  `COMMIT_TS_SUBTRANS_TS` record and the commit record is an interesting
  recovery case (delta-apply + kill).
- Delta-apply requires columns `NOT NULL` + `log_old_value=true`. If the old
  value arrives NULL (setting was off on the provider when the UPDATE was
  logged), Spock applies the plain new value (spock_apply_heap.c ~545-556,
  "useful in case a server ever gets out of sync"). Toggling `log_old_value`
  on one node only is a divergence lead.

### 2. Other PostgreSQL core infrastructure Spock relies on

- **`shared_preload_libraries = 'spock'` is mandatory.** `_PG_init` errors
  `"spock is not in shared_preload_libraries"` (spock.c ~1118). It registers the
  supervisor bgworker (`bgw_restart_time = 5`, `BgWorkerStart_RecoveryFinished`,
  spock.c ~1500-1517), shared memory sized from `max_worker_processes`
  (spock_shmem.c:92-116), the failover-slot worker (PG<18), an
  `emit_log_hook`, and on PG18+ a custom pgstat kind for conflict stats.
- **Custom WAL resource manager** `spock_custom_rmgr`, ID **144**
  (include/spock_rmgr.h:29-30, `RegisterCustomRmgr` at spock_rmgr.c:64,
  record type `SPOCK_RMGR_RESOURCE_DUMP` 0x10). Registered even under binary
  upgrade because pg_upgrade's slot catch-up check decodes WAL (spock.c
  comment above `spock_rmgr_init()`). Consequence: **any server that replays
  this WAL must load spock** — a physical standby, PITR, or `pg_waldump`
  without the library fails with "resource manager with ID 144 not
  registered". Used for apply progress (release notes: "Progress tracking moved
  to WAL + shared memory"; tests 008_rmgr, 022_rmgr_progress_post_checkpoint_crash,
  016_crash_recovery_progress, 027/029 remote_commit_ts_recovery).
- **Output plugin library `spock_output`** is a thin shim (src/spock_output.c)
  that `load_external_function("spock", "_PG_output_plugin_init")`. Callbacks
  registered (spock_output_plugin.c:133-140): startup, begin, change, commit,
  message, truncate, filter_by_origin, shutdown. **No streaming or 2PC
  callbacks**, so large transactions are fully decoded (spilled to disk under
  `logical_decoding_work_mem`) on the provider before any byte is sent, and
  prepared transactions are sent only at COMMIT PREPARED.
- **`output_plugin_libraries` GUC (new upstream security fix 2a29b607dbb).**
  PG 15.19, 16.15, 17.11, 18.6 and 19 refuse to create a slot with plugin
  `spock_output` unless it is listed: `ERROR: library "spock_output" may not be
  used as an output plugin` (README.md:197; commits dbf52b03, 1b0dd35d). Must be
  additive: `output_plugin_libraries = 'pgoutput, test_decoding, spock_output'`.
  On older minors the GUC does not exist and putting it in postgresql.conf stops
  the postmaster; harnesses probe with `postgres --describe-config`
  (tests/docker/entrypoint.sh, SpockTest.pm `output_plugin_libraries_conf`,
  Makefile `_regress_output_plugin_config`). Since CI resolves the newest tag,
  an Antithesis image built today will need this line.
- **`track_commit_timestamp`.** `spock.conflict_resolution` defaults to
  `last_update_wins` (spock.c:1125-1133) and its check hook
  (`spock_conflict_resolver_check_hook`, spock_conflict.c:800-815) rejects
  anything except `apply_remote`/`error` when `track_commit_timestamp` is off.
  Because the boot value is `last_update_wins`, I expect the postmaster to fail
  at `_PG_init` when commit timestamps are off (PG's `InitializeOneGUCOption`
  treats a failing check hook on the boot value as FATAL) — not verified by
  running it. If it is off and resolution is `apply_remote`, `get_tuple_origin`
  (spock_conflict.c:207-233) pretends every local tuple came from the remote
  origin, so conflicts are never detected (docs/conflict_types.md:193-200).
- **Commit-ts data loss / frozen tuples.** When the local tuple's xmin is
  frozen or the commit_ts SLRU was truncated, `local_ts = 0` and the remote
  always wins with no conflict logged (spock_conflict.c:235-250,
  docs/conflict_types.md:~185). Long runs with aggressive vacuum/freeze change
  conflict outcomes.
- **Replication slots** (provider): created by the sync worker over a
  replication connection: `CREATE_REPLICATION_SLOT "<slot>" LOGICAL spock_output
  [(FAILOVER)]` (spock_sync.c:414-431). `(FAILOVER)` is added when the *remote*
  server is PG17+ (`PQserverVersion(sql_conn) >= 170000`). If the slot exists
  and is inactive it is dropped and recreated (`goto retry`, spock_sync.c:440-455);
  the newer `spock_create_slot_and_read_progress` path also pre-drops an
  inactive slot (spock_sync.c:~668-677) and pauses apply workers on the provider
  while it creates the slot (`spock.pause_timeout`). Slot naming:
  `spk_<db>_<provider>_<subname>` (zodan `spock_gen_slot_name`).
  Slots pin WAL on the provider; a long partition grows WAL without limit unless
  `max_slot_wal_keep_size` is set, in which case the slot may be invalidated and
  the subscription needs a resync.
- **Replication origins** (subscriber): one per subscription, named the same as
  the slot. Created by `ensure_replication_origin()` (spock_sync.c:476-485) or
  `spock_functions.c:751`. Apply worker: `replorigin_by_name(...,false)` +
  `replorigin_session_setup()`; the start position sent in `START_REPLICATION`
  is `replorigin_session_get_progress(false)` (spock_apply.c:4745-4771).
  The sync worker advances the origin to the slot's creation LSN in its own
  committed transaction **before** structure/data copy finishes
  (spock_sync.c:~1673-1685); a crash in between depends on sync-status
  handling to avoid skipping data (lead for focus areas on sync).
  On PG18+ the number of origin states is `max_active_replication_origins`
  (default 10), separate from `max_replication_slots` (docs/install_spock.md).
- **Walsender / `wal_sender_timeout`.** Docs (docs/configuring.md:227-240)
  recommend `wal_sender_timeout = '5min'` because the default 60s disconnects a
  subscriber busy with a large transaction. **The 6.0.0 release notes are stale:**
  docs/spock_release_notes.md:190-196 claims Spock sets `wal_sender_timeout=0` on
  replication connections; commit 7a8a9858 removed that, and
  `spock_connect_base` sets no such option. With PG defaults the walsender can
  time out during long applies — normal reconnect path, but it is a source of
  disconnects that Antithesis will see without any injected fault.
- **Apply runs with `synchronous_commit = off`** (or `local` if
  `spock.synchronous_commit`, PGC_POSTMASTER, default false; spock_apply.c:4700).
  Flush feedback to the provider is gated by `get_flush_position()` comparing
  each applied transaction's local end LSN with `GetFlushRecPtr()`
  (spock_apply.c:3082-3117), so the provider slot should only advance past
  durably flushed work. With a **synchronous** standby configured
  (`SYNC_STANDBY_DEFINED`), feedback is further held until the sync standby has
  flushed (`append_feedback_position`/`get_feedback_position`,
  spock_apply.c:3120-3200). With an **asynchronous** standby there is no such
  hold: after failing over a subscriber to its async standby, the provider's
  slot may already be past what the standby received → lost changes on the
  promoted node. Same consideration for the provider side, handled by
  `synchronized_standby_slots` (PG17+) or `spock.pg_standby_slot_names`.
- **Postmaster crash-restart semantics.** All spock workers are bgworkers in the
  same instance; a SIGKILL/segfault of any one apply/sync/manager worker makes
  the postmaster reset the whole instance (with `restart_after_crash=on`), which
  also resets the logical clock above. Apply workers are `BGW_NEVER_RESTART`
  (spock_worker.c:195) and are restarted by the manager after
  `spock.restart_delay_default` (5000 ms, PGC_POSTMASTER) or
  `spock.restart_delay_on_exception` (spock_manager.c:49-117).
- **pg_dump / pg_restore executables.** Structure sync forks the subscriber's
  own `pg_dump -Fc -s --snapshot=<exported>` and `pg_restore`
  (spock_sync.c:72-73, 128-166, 240-360). `get_pg_executable()` requires them
  next to the `postgres` binary with the **same major version**, and a separate
  check refuses an upstream newer than the subscriber's pg_dump supports
  (spock_sync.c:~365-390, error at ~1593). Weak points:
  - `exec_cmd` does a blocking `waitpid()` with no interrupt checks; the sync
    worker cannot react to SIGTERM until pg_dump exits.
  - pg_dump connects with the raw node DSN, **not** through
    `spock_connect_base`, so it gets no keepalives/connect_timeout unless the
    DSN has them. A network partition during structure sync can hang pg_dump
    (and therefore the sync worker) until the kernel gives up on TCP.
  - On `execv` failure, the child (a forked backend) runs `ereport(ERROR)`
    (spock_sync.c:139-144) — error handling in a forked copy of a backend.
  - `fork()` returning -1 is not checked; `waitpid(-1, ...)` would then wait
    for any child.
  - The dump file is written to `spock.temp_directory`, default `$TMPDIR` or
    `/tmp` (spock.c:969-989), named `spock-<pid>.dump`.
  - The exported snapshot is tied to the open replication connection
    `origin_conn_repl` (spock_sync.c:~1659); losing that connection mid-dump
    fails the sync.

### 3. libpq connections between nodes

All Spock-initiated peer connections go through `spock_connect_base()`
(spock.c:366-463):

- Parameters forced after the DSN (keys after `dbname` override what the DSN
  says, because libpq processes `expand_dbname` keys in array order):
  `connect_timeout=30`, `keepalives=1`, `keepalives_idle=10`,
  `keepalives_interval=5`, `keepalives_count=3`, `replication=database` for
  streaming connections, and
  `options="<user options> -c datestyle=ISO -c intervalstyle=postgres -c extra_float_digits=3"`
  (34d473dc). Dead peer detection by keepalive ≈ 10 + 5×3 = ~25 s
  (release notes: "detects dead network or host in ~25 seconds").
  Note that TCP keepalive only applies while the socket is idle; when there is
  unacknowledged data in flight, Linux uses the retransmission timeout
  (`tcp_retries2`, ~15 min) instead — unless `tcp_user_timeout` is set, and
  Spock does not set it. Under a partition that drops packets while the
  walsender is sending, detection on the provider side may take much longer
  than 25 s.
- **`spock.extra_connection_options` appears to be ignored.** It is appended
  only to the StringInfo `s` (spock.c:379-382), which is used solely in the
  error `errdetail("dsn was: %s", s.data)`; `vals[0]` is the raw `connstr`.
  docs/configuring.md:216-225 says it applies to all connections and that
  `keepalives = 0` there disables keepalives. As written, it cannot override
  anything. Unchanged since the initial pglogical import per `git log -L`.
  (Caller should double-check; this is a doc/code mismatch.)
- Connection failure handling: `PQconnectdbParams` failing → `ereport(ERROR,
  "could not connect to the postgresql server ...")`; the worker exits and the
  manager restarts it after the restart delay.
- Apply loop (spock_apply.c:3510-3560): `PQstatus == CONNECTION_BAD` →
  `ERRCODE_CONNECTION_FAILURE` "connection to other side has died";
  `spock.apply_idle_timeout` (default 300 s, PGC_SIGHUP, spock.c:1461-1475)
  raises `ERRCODE_CONNECTION_FAILURE` "no data received for %d seconds". Both
  are tagged as connection failures so the exception handler does not treat
  them as data errors (fix 8dcfbcd5 "spurious apply-idle-timeout
  misclassification"; test 046). The timeout uses `GetCurrentTimestamp()` (wall
  clock): a forward clock jump can trigger a spurious reconnect, a backward
  jump delays detection. Liveness tests: 019_stale_fd_epoll_after_conn_death,
  101_clean_exit_on_conn_loss, 102_no_origin_leak_on_disconnect,
  104_iptables_conn_block, 105_sub_disable_retransmit_after_disconnect,
  023_forced_keepalive_timing.
- On (re)connect the apply worker sends a status update with
  `replyRequested=1` to get an immediate keepalive
  (`request_initial_status_update`, spock_apply.c:3329-3370).
- Failover-slot worker (PG<18) uses its own `remote_connect()` with the same
  hard-coded keepalive set (spock_failover_slots.c:488-530), DSN from
  `spock.primary_dsn` or falling back to `primary_conninfo`.
- DSNs are stored in `spock.node_interface` and used verbatim by apply/sync
  workers, by pg_dump, and by zodan's dblink calls. Containers need resolvable
  hostnames (`host=n1 ...`) and `pg_hba.conf` entries for both `all` and
  `replication`.

### 4. Commit timestamps and system clock

- LUW compares the remote commit timestamp with the local tuple's commit
  timestamp (`conflict_resolve_by_timestamp`, spock_conflict.c:98-200). Ties go
  to the node `tiebreaker` (from `spock.node.info->>'tiebreaker'`, defaults to
  node id, spock_node.c:499-532); equal tiebreakers → apply remote with a
  WARNING (test 025).
- Remote commit timestamps are the provider's wall-clock time (adjusted by
  patch 025's logical clock on that provider). Clock skew between nodes
  directly decides conflict winners. The logical clock compensates only for
  remote transactions this node has already applied, and only until restart
  (see §1).
- Other clock uses: `apply_delay` (spock_apply.c:881-899; `pg_usleep`, not
  interruptible), `spock.resolutions_retention_days` cleanup,
  `apply_idle_timeout`, manager restart scheduling (spock_manager.c:110),
  zodan wait loops (`clock_timestamp()` with `spock.sync_timeout()` budget).
  Containers in tests/docker set `TZ=America/Toronto`; peer sessions force
  `datestyle=ISO`. Test 005_daylight_savings is commented out of the schedule.

### 5. dblink and the ZODAN add-node procedures

- ZODAN is **not** part of the extension SQL (`sql/spock--6.0.0.sql` has no
  dblink or add_node). It is a sample script, `samples/Z0DAN/zodan.sql`
  (93 dblink uses), plus `zodremove.sql`, `zodan_cleanup.sql`,
  `wait_subscription.sql`. It must be loaded with `psql -f` and needs
  `CREATE EXTENSION dblink` (contrib) on the new node (tests/docker/entrypoint.sh).
- `spock.add_node(...)` (zodan.sql:2882) runs on the **new** node and drives 14
  phases over dblink to the source and every other node: version check, prereqs,
  create nodes, create disabled subs + slots, sync events, src→new sub, wait,
  `check_commit_timestamp_and_advance_slot` (Phase 7), mirror repsets (via a
  dblink loopback to avoid a lock deadlock), enable subs, new→src sub, report.
- Failure handling is mostly "warn and continue": many steps wrap work in
  `EXCEPTION WHEN OTHERS THEN RAISE WARNING ... proceeding anyway`
  (e.g. the READY wait in Phase 7, the src→new slot check). Waits are bounded
  by `spock.sync_timeout()` (GUC `spock.sync_timeout`, default 180 s) and then
  **continue** with a WARNING.
- Phase 7 non-atomic step: remote `pg_replication_slot_advance()` over dblink
  commits immediately on the other node, then `pg_replication_origin_advance()`
  runs locally inside the CALL. A crash/partition between the two leaves the
  remote slot advanced and the local origin not. If `spock.progress` has no row
  for an origin node, the target falls back to the remote's
  `pg_current_wal_lsn()` ("WARNING: No spock.progress entry ... falling back"),
  which can skip changes committed on that node between snapshot and now.
  These are prime Antithesis targets (kill/partition during add_node).
- dblink connections use the DSN as given: no keepalives or connect_timeout
  unless the DSN includes them, so a partition can hang a dblink call.
- Tests: 009_zodan_add_remove_nodes, 011_zodan_sync_third (nightly, flaky-loop
  example in schedule), 012_zodan_basics, 017_zodan_3n_timeout,
  033_zodan_lolor_add_node, 099_zodan_mixed_version.

### 6. lolor and other pgEdge extensions

- `lolor` (large-object support) is external: tests clone
  `https://github.com/pgEdge/lolor.git` and build it at test time
  (SpockTest.pm ~180-192). Spock treats it as a reserved object: excluded from
  pg_dump but allowed in replication sets (`spock.reserved_object` seed rows,
  sql/spock--6.0.0.sql:355-366). Also reserved: `snowflake` (sequences),
  `pgedge_ace` (consistency checker). None are in this tree; an Antithesis
  image must pre-build lolor if those tests' scenarios are wanted (no network
  at run time).
- docs/install_spock.md says the jansson library is a prerequisite; no source
  file references jansson and `SHLIB_LINK` is only `$(libpq)`. The base image
  installs `jansson-devel` anyway. Likely stale doc.

### 7. Physical standbys, failover slots, hot_standby_feedback

- PG15/16 (and PG17 when `sync_replication_slots=off`): Spock's own
  `spock_failover_slots worker` (bgw_restart_time 60,
  `BgWorkerStart_ConsistentState`) syncs logical slots from the primary while in
  recovery; it only does work when `hot_standby_feedback` is on (otherwise long
  naps, fix tested in 800_standby_hot_standby_feedback). GUCs:
  `spock.synchronize_slot_names` (default `name_like:%%`),
  `spock.drop_extra_slots` (true), `spock.primary_dsn`,
  `spock.pg_standby_slot_names`, `spock.standby_slots_min_confirmed` (-1 = all),
  `spock.failover_slots_naptime` (1000 ms), `spock.failover_slots_feedback_naptime`
  (10000 ms) (spock_failover_slots.c:1837-1939). Also installs a
  `ClientAuthentication_hook` (`attach_to_walsender`) on PG<18.
- PG17: yields to native slotsync when `sync_replication_slots=on`.
- PG18+: Spock's worker is not registered; native `sync_replication_slots=on`,
  `synchronized_standby_slots` on the primary, `primary_slot_name`,
  `hot_standby_feedback=on`, `primary_conninfo` with `dbname` are required
  (docs/logical_slot_failover.md).
- `spock.slot_enable_failover()` turns on `failover` for old slots (PG17+,
  skips active/invalidated/synced slots).
- After promotion, subscribers must be repointed manually:
  `sub_disable` → `node_add_interface` → `sub_alter_interface` → `sub_enable`
  (tests/tap/t/018_failover_slots.pl:502-540). Standbys must have spock in
  `shared_preload_libraries` because of the custom rmgr (§2).

### 8. OS dependencies

- iptables: only test 104_iptables_conn_block (needs root or passwordless sudo;
  not in the schedule). Uses REJECT `tcp-reset`; comments note loopback blocks
  often stall instead of reset — "both are safe".
- Core dumps: compose mounts `/cores`, `cap_add: SYS_PTRACE, SYS_ADMIN`.
- `fork`/`execv` of pg_dump/pg_restore; writes to `$TMPDIR`.

### 9. Building and running in a container

Existing harness: `tests/docker/` (Rocky Linux 9).

- **Base image** (Dockerfile-base.el9): "Development Tools" plus bison, flex,
  gcc/clang, llvm-devel, readline, zlib, lz4, zstd, openssl, icu, libxml2,
  libxslt, uuid, krb5, openldap, pam, systemd-devel, python3-devel, perl +
  IPC::Run + Test::More (TAP), jansson-devel, libpq-devel.
- **Step 1** (Dockerfile-step-1.el9):
  1. Fetch PG source `--depth 1` at the ref from tests/resolve-pg-ref.sh (needs
     network at build time).
  2. Apply `patches/${PGVER}/*` with `patch -p1`.
  3. `./configure --prefix=/home/pgedge/pgedge/pg${PGVER} --enable-debug
     --enable-cassert --enable-tap-tests --with-zstd --with-lz4 --with-icu
     --with-libxml --with-libxslt --with-uuid=ossp --with-openssl --with-llvm
     --with-python ... [--enable-injection-points] CFLAGS="-g -O0"`; build and
     install core + contrib (contrib gives dblink).
  4. Spock: `make PG_CONFIG=... [SPOCK_RANDOM_DELAYS=1]` and `make install`.
  5. Also clones and installs spockbench (network).
- Build flags useful for Antithesis:
  `SPOCK_RANDOM_DELAYS=1` → random 1–100 ms sleeps at worker start/finish and
  after a transaction's BEGIN is sent by the output plugin
  (include/spock_injection.h; Makefile). `--enable-injection-points` (PG17+)
  → named points `spock-worker-delay`, `spock-output-txn-stall` attachable via
  the core `injection_points` module. Not both at once.
  `NO_LOG_OLD_VALUE` disables delta-apply.
- **postgresql.conf minimum** (entrypoint.sh, SpockTest.pm, regress conf):
  ```
  shared_preload_libraries = 'spock'
  wal_level = logical
  track_commit_timestamp = on
  max_worker_processes = 32      # supervisor + slot-sync + 1 manager/db + 1 apply/sub + 1 sync/sub (+ parallel query)
  max_replication_slots = 32     # >= 2*R*(N-1), plus physical standby slots
  max_wal_senders = 32           # same as slots
  max_active_replication_origins = ...   # PG18+, >= (N-1)*R
  output_plugin_libraries = 'pgoutput, test_decoding, spock_output'  # only if the GUC exists
  listen_addresses = '*'
  wal_sender_timeout = '5min'    # docs recommendation
  spock.conflict_resolution = 'last_update_wins'
  spock.enable_ddl_replication = on; spock.include_ddl_repset = on   # AutoDDL, as in TAP
  spock.exception_behaviour = sub_disable   # TAP default; regress uses default
  ```
  pg_hba: `host all all 0.0.0.0/0 trust` and `host replication all ... trust`.
  Sizing formulas: docs/sizing.md.
- Cluster bootstrap in tests/docker/entrypoint.sh: n1 runs
  `spock.node_create(... info := '{"tiebreaker":"1"}')`; other nodes load
  zodan.sql and `CALL spock.add_node(src 'n1', ...)` during container init, then
  stop and restart postgres as PID 1. docker-compose.yml orders n2/n3 after n1
  is healthy (healthcheck: `pg_isready` + `/tmp/spock_init_complete`). Container
  lifecycle is tied to postgres (`exec postgres -D $PGDATA -k /tmp`).
- Network at build time only: PG source, lolor, spockbench must be fetched
  into the image; nothing at run time needs the internet.

---

## Areas examined

- patches/15..19 (all four patch kinds, full `+` lines of the PG18 set),
  patches/attic, tests/docker/spock.patches.
- Makefile, spock.control.in, src/spock_output.c.
- src/spock.c (`spock_connect_base`, `_PG_init`, GUCs, temp-dir hook,
  `log_message_filter`), src/spock_apply.c (commit path, feedback, main loop
  timeouts, worker start), src/spock_apply_heap.c (delta apply), src/spock_relcache.c,
  src/spock_conflict.c, src/spock_sync.c (slot/origin creation, pg_dump/pg_restore),
  src/spock_failover_slots.c, src/spock_worker.c, src/spock_manager.c,
  src/spock_functions.c (`get_lsn_from_commit_ts`), include/spock_rmgr.h,
  include/spock_injection.h.
- samples/Z0DAN/zodan.sql (add_node and Phase 7 in detail).
- sql/spock--6.0.0.sql (reserved objects).
- docs: install_spock.md, configuring.md, conflict_types.md,
  logical_slot_failover.md, sizing.md, spock_release_notes.md, managing/lolor.md;
  README.md.
- tests/docker (Dockerfiles, entrypoint.sh, compose, pgedge.env),
  tests/postgres-build.conf, tests/regress/*.conf, tests/tap/t/SpockTest.pm,
  tests/tap/schedule, headers of 018_failover_slots.pl, 104_iptables_conn_block.pl,
  800_standby_hot_standby_feedback.pl.
- git history: 2535c3fa, 7a8a9858 (wal_sender_timeout), dbf52b03/1b0dd35d
  (output_plugin_libraries), 29d7799e (connect stack bug), 11576186, 52981976.
- `nm -D` on the prebuilt spock.so in the repo root for patched-core symbols.

## Assumptions

- libpq's `PQconnectdbParams(expand_dbname=true)` processes keys in array
  order, so keys after `dbname` override DSN values (libpq documented
  behavior; not re-verified by test here).
- PostgreSQL's `XLOGShmemInit` zeroes `XLogCtl`, so the logical clock starts at
  0 after every postmaster start (consistent with the patch's own TODO).
- A failing GUC check hook on the boot value is FATAL during `_PG_init`; hence
  my expectation that `track_commit_timestamp=off` + spock prevents startup.
  Not run.
- The prebuilt `spock.so` in the repo root matches current sources closely
  enough for the symbol check (it may come from another branch).

## Open Questions

1. Is `spock.extra_connection_options` really unused (spock.c:379-382)? If so,
   users cannot change keepalives/timeouts other than through the DSN — and even
   the DSN cannot override the hard-coded keepalive/connect_timeout values.
2. How should the logical clock behave after restart/promotion? Is there any
   mitigation (e.g. seeding from the max commit ts in WAL or from
   `spock.progress.remote_commit_ts`) — tests 027/029 "remote_commit_ts_recovery"
   suggest the *progress* remote_commit_ts is recovered, but I found nothing
   that seeds `lastTransactionStopTimestamp` from it.
3. Does the sync worker's COPY transaction (not an apply commit, so
   `remoteTransactionStopTimestamp == 0`) stamp copied rows with the local copy
   time, and can that make later-arriving catch-up changes with older remote
   timestamps lose LUW? The same-origin shortcut in
   `conflict_resolve_by_timestamp` only applies on equal timestamps; the
   reporting path suppresses same-origin conflicts but resolution happens
   first. Needs checking by whoever owns conflict resolution / sync.
4. What is the purpose of the PG15-only patch 010 for Spock specifically?
   No spock code calls its new functions.
5. With async physical standbys of a subscriber node, is the loss window on
   failover (provider slot already past what the standby has) accepted and
   documented?
6. pg_dump hang under partition: is there any timeout around structure sync
   apart from the DSN? (`exec_cmd` has none.)
7. Release notes (wal_sender_timeout=0) and install doc (jansson) look stale;
   confirm with maintainers.
