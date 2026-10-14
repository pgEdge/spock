# 06 — Bug History and Density

Focus: where bugs have clustered in Spock's history, which fixes look narrow,
and which recurring bug patterns point at systemic weaknesses worth aiming
Antithesis faults at.

SUT: `~/dev/pgedgea/spock` at `69d9228f` (main). History: 1510
commits, 2022-06 .. 2026-09. Commit volume and fix volume both rose sharply
in 2025-2026 (2025: 478 commits / 92 "fix|bug"; 2026 to date: 462 / 162).
The source tree moved to `src/` in `d0498a2c` (2025-08-20), so per-file counts
below mainly cover the last ~13 months; earlier fixes live under the old
top-level `spock_apply.c` etc.

Everything below about a past bug is based on reading the fix diff, not just
the commit title. "Claim" means the commit message or a code comment says it;
it is not verified.

---

## 1. Findings

### 1.1 Fix density by file (src/*.c, since restructure)

Columns: commits matching `fix|bug|crash|race|leak|regress` / all commits /
matching since 2025-10-01 / current line count.

| file | fix | all | fix since 2025-10 | LOC |
|---|---|---|---|---|
| spock_apply.c | 57 | 91 | 50 | 5183 |
| spock_functions.c | 29 | 57 | 22 | 4567 |
| spock.c | 27 | 55 | 19 | 1530 |
| spock_sync.c | 24 | 52 | 23 | 2729 |
| spock_group.c | 16 | 28 | 16 | 826 |
| spock_failover_slots.c | 15 | 30 | 12 | 1940 |
| spock_node.c | 14 | 23 | 12 | 1516 |
| spock_worker.c | 12 | 20 | 11 | 1003 |
| spock_conflict.c | 11 | 32 | 8 | 1098 |
| spock_apply_heap.c | 11 | 30 | 6 | 1228 |
| spock_output_plugin.c | 11 | 22 | 9 | 1715 |
| spock_rmgr.c | 5 | 9 | 5 | 249 |
| spock_proto_native.c | 4 | 12 | 3 | 1228 |
| spock_queue.c | 3 | 8 | 2 | 189 |
| spock_sequences.c | 2 | 5 | 1 | 355 |
| spock_progress_recovery.c | 1 | 3 | 1 | 380 |

Plus `samples/Z0DAN/zodan.sql` (add-node orchestration): 56 commits, ~25
fix-type commits, several of them data-loss fixes.

**Hotspots (by real-bug content, not just keyword hits):**
1. The apply worker's exception / retry state machine (`spock_apply.c`
   `apply_work()` PG_CATCH, `handle_begin()`, `handle_commit()`,
   shared-memory `exception_log_ptr[]`). By far the densest.
2. Replication-origin / LSN bookkeeping (when origin advances, which LSN is
   used for what). Spread over `spock_apply.c`, `spock_sync.c`,
   `spock_functions.c`, `zodan.sql`.
3. Add-node (Z0DAN) catch-up / slot-position correctness: `spock_sync.c`
   `read_peer_progress` path, `zodan.sql`, `spock_group.c` progress.
4. `spock.progress` persistence across crashes (`spock_group.c`,
   `spock_rmgr.c`, `spock_progress_recovery.c`): redesigned three times in
   seven months.
5. Failover slots (`spock_failover_slots.c`): 8 fixes in April 2026, but
   only active on PG15/16 (PG18 uses native slot sync, `3bd075a0`).
6. Worker lifecycle / shared-memory ordering (`spock_worker.c`, `spock.c`
   supervisor/manager).

**Quiet components (few or no fixes):** `spock_output_plugin.c` (decoding
side; ~3 genuine fixes: `3c4f3c2e` protocol, `1c3ca201` origin name,
`fdd9587e` non-transactional sync_event startup ordering),
`spock_proto_native.c`, `spock_queue.c` (DDL queue replication),
`spock_sequences.c`, `spock_rpc.c`, `spock_conflict_stat.c`,
`spock_readonly.c`. Of these, the output plugin, the DDL queue and sequence
sync sit directly on the data path yet see almost no fault-oriented testing
(no TAP test kills a walsender mid-decode, no test covers sequence sync under
failover). Quiet here likely means "untested under faults", not "solid".

---

### 1.2 Recurring pattern A — transient failures misread as data faults (exception state machine)

**Mechanism.** `handle_begin()` (`src/spock_apply.c` ~l.700-880) writes the
incoming `commit_lsn` into the subscription's shared-memory slot
`exception_log_ptr[my_exception_log_index].commit_lsn` on *every* BEGIN. When
a worker starts and the first BEGIN's `commit_lsn` equals the stored value
(l.834), it concludes "this transaction failed before" and sets
`MyApplyWorker->use_try_block = true`, which replays the transaction under
`spock.exception_behaviour` (DISCARD / TRANSDISCARD / SUB_DISABLE). Under
TRANSDISCARD the transaction is dropped; under SUB_DISABLE the subscription
is disabled. The slot is keyed by subscription name, lives in shared memory,
and survives worker exit (it is reset only by postmaster shared-memory
re-init).

So any way the worker can die mid-transaction *without* clearing that marker
turns a retransmitted, healthy transaction into a "failed" one. This has been
fixed piecemeal at least eight times:

| commit | date | path that leaked the marker / mode | fix |
|---|---|---|---|
| `72625daa` | 2025-02 | DISCARD didn't advance origin to end_lsn → error loop | advance origin |
| `5b88e2de` | 2025-06 | origin advanced despite exception → failed txn skipped after re-enable | conditional advance |
| `3cf97588` | 2025-12 | skip_lsn compared BEGIN lsn vs end_lsn; state not cleared after skip → re-disable | fix both |
| `d286f3df` | 2026-05 | connection loss: stale fd + generic PG_CATCH → AbortOutOfAnyTransaction advanced origin to in-flight `final_lsn` (**data loss**) | tag errors `ERRCODE_CONNECTION_FAILURE`, rethrow, clear `replorigin_session_*` in `spock_apply_worker_shmem_exit` (before_shmem_exit LIFO ordering) |
| `db380dd8` | 2026-07 | connection loss left `commit_lsn` → SUB_DISABLE on retransmit | `clear_transient_exception_state_on_connection_loss()` |
| `f3d4935e` | 2026-07 | deadlock 40P01, lock_timeout 55P03, class 53, 57P02/57P03 went to the data-fault path → DISCARD/TRANSDISCARD lost rows | classify as transient, rethrow, `restart_delay_default` |
| `acf6cdae` | 2026-08 | error *between* transactions left `use_try_block` set → next unrelated txn replayed read-only and discarded | derive flag from commit_lsn comparison (l.836-873) |
| `b8993cb5` | 2026-08 | slot lookup by `strncmp(prefix)` → `sub` and `sub_x` shared one slot → one sub's failure made the other discard | `namestrcmp` |
| `0f7f068b` | 2026-08 | off-by-one `i <= total_workers` → read/write past the array | `<` |
| `ed0a9945` | 2026-09 | SIGTERM (e.g. `sub_alter_options()` restart) mid-transaction left marker | clear on `got_SIGTERM` exit (l.~4155) |
| `8dcfbcd5` | 2026-09 | `spock.apply_idle_timeout` raised bare `elog(ERROR)` (XX000) → treated as data fault | tag `ERRCODE_CONNECTION_FAILURE` |

Related exception-path fixes: `162dc562` (DISCARD retry of an un-appliable
TRUNCATE escaped as ERROR → infinite restart loop), `940e500d`, `216970cb`,
`47d4a003` (dangling `local_tuple`), `eb30df11`/`51ae2d84`/`5147a87a`
(memory contexts in PG_CATCH), `4cb409cb` (unbounded memory in replay).

**Is the current fix complete? No — it is an allow-list, and gaps remain.**
The current discriminator (`apply_work()` PG_CATCH, ~l.3917-3993) treats as
transient only: `08006, 08000, 08003, 57P01, 57P02, 57P03`, `PQstatus ==
CONNECTION_BAD`, `40P01`, `55P03`, and class `53`. Everything else that
happens mid-transaction is treated as a permanent data fault. Gaps I can see:

- **40001 serialization failure** — the code comment admits it: the worker's
  isolation is not pinned to READ COMMITTED, so a cluster-wide
  `default_transaction_isolation` produces 40001, which goes down the
  discard/disable path.
- **57014 query_canceled** (`statement_timeout` set for the worker's role or
  database, or `pg_cancel_backend()` from an operator/monitoring tool) —
  not on the list.
- **Class 58 / XX001 / XX002 I/O errors** (EIO, ENOSPC raised as 53100 is
  covered but `could not write`/`could not fsync` as 58030 is not).
- **Exits that bypass PG_CATCH entirely**: `FATAL` raised anywhere in the
  apply path, or `proc_exit()` from a code path other than the
  `got_SIGTERM` loop exit. The marker is cleared only at (a) the PG_CATCH
  transient branches, (b) clean `got_SIGTERM` exit, (c) a successful commit.
  Any other mid-transaction death leaves `commit_lsn` in shared memory and
  the next worker will replay the retransmitted txn under the exception
  policy. (A SIGKILL of the worker causes a postmaster crash-restart, which
  re-inits shared memory and is therefore safe; a FATAL or clean
  `proc_exit` is not.)
- **Two subscriptions from the same provider** still share commit LSNs by
  design; the prefix bug (`b8993cb5`) was the only thing letting them share
  a slot, but `exception_log` slot exhaustion (`"unable to find an empty
  exception log slot"`, l.~790; TODO: slot leak on DROP SUBSCRIPTION, l.~800)
  is unfixed.

Antithesis relevance: very high. Process pause longer than
`spock.apply_idle_timeout` (default 300 s), network partitions, provider
restarts and local lock contention all hit these paths. The bug signature is
"row present on provider, missing on subscriber, logged in
`spock.exception_log` as discarded" or "subscription disabled with no real
conflict". Test 046 (`046_apply_worker_exception_misclassification.pl`) and
105 cover two scenarios each with injection points; nothing covers the 40001,
57014 or FATAL paths.

---

### 1.3 Recurring pattern B — LSN from the wrong stream, or the wrong end of a record

Six separate fixes where one LSN was used where another was meant:

- `5f654e34` (2026-06): the sync-standby hold queue sent the **subscriber's
  local** `XactLastCommitEnd` to the publisher as `confirmed_flush_lsn`. After
  a failover the publisher skipped every commit between the real position and
  the wrong LSN — **silent data loss**. Fix splits `RemoteSyncPosition` into
  `local_commit_lsn` (gating) vs `remote_*pos` (feedback)
  (`append_feedback_position()` l.3142, `get_feedback_position()` ~l.3213).
  Test `020_sync_standby_feedback_lsn.pl` is **not in any schedule**.
- `986ad069` (2026-04): `spock.progress.remote_commit_lsn` stored `commit_lsn`
  (start of COMMIT record) while `pg_replication_origin_status.remote_lsn`
  uses `end_lsn` → add-node Phase 7 set origin slightly low → duplicates.
- `3cf97588` (2025-12): skip_lsn set from BEGIN `commit_lsn`, cleared with
  `end_lsn`.
- `401197ab` (2026-07): forwarded-origin advance; explicitly chose
  `XactLastCommitEnd` (local) rather than the provider's `end_lsn`.
  `maybe_advance_forwarded_origin()` (l.5165) calls `replorigin_advance()`
  **after** the data commit, as a separate WAL record. Claim (commit message):
  "a crash may replay the latest transaction, preserving at-least-once
  semantics; delta-apply idempotency remains a separate follow-up." So a crash
  in that window replays a transaction; for delta-apply columns that is a
  double-count. Not fixed.
- `8de96369` (2026-08): `spock.get_lsn_from_commit_ts()` (a) never stopped
  reading at end of WAL, (b) read ts=0 from a truncated `pg_commit_ts` and
  picked a *later* LSN ("the direction that loses data"), (c) returned the
  slot's `restart_lsn` on no match. Now returns NULL; no in-tree caller found
  (`samples/`, `utils/`), so external callers must handle NULL.
- `dcbba6bb` (2026-04): `pg_replication_origin_status.remote_lsn` is updated
  in `RecordTransactionCommit` *before* `ProcArrayEndTransaction`, so the
  add-node COPY snapshot could exclude a transaction whose LSN was already
  read as "resume from here" → **permanent loss on the new node**.

Antithesis relevance: any assertion comparing per-origin row sets across
nodes after failover or add-node will catch this class.

### 1.4 Add-node (Z0DAN) catch-up correctness — repeatedly fixed, still racy

Data-loss fixes in the add-node path: `a9bc8652`, `f38da44a` (origin
advance from slot-creation LSN instead of the lag_tracker
timestamp→LSN conversion), `dcbba6bb` (pause barrier), `986ad069`,
`b7fc7022` (Phase 3 wait compared `received_lsn`, which keepalives bump past
the slot's consistent point with zero rows applied → rows in
`(src_apply_progress, slot_consistent_point]` missed by COPY and never
streamed), `fa52495a` (resync lost data; waited forever), `7d21b807`
(resync with `truncate=true` on a read-only subscriber truncated and then
failed COPY → **permanent loss**), `8de96369`.

**The `dcbba6bb` pause barrier looks narrow.** Mechanism:
`spock_pause_apply_workers()` (`src/spock_functions.c` ~l.4060) sets
`SpockCtx->pause_apply = 1` and waits until each same-database apply worker
either has `paused == true` or `!TransactionIdIsValid(proc->xid)`. Workers
check the flag in `maybe_pause_for_slot_creation()` (`src/spock_apply.c`
l.565), called from `begin_replication_step()` only when
`!IsTransactionState()`. Then `spock_sync.c` (~l.704-857) runs
`CREATE_REPLICATION_SLOT`, reads peer progress, and calls
`spock.resume_apply_workers()`. Two holes from reading the code (not
tested):

1. **Worker-side timeout resumes on its own.** In
   `maybe_pause_for_slot_creation()`, after `spock.pause_timeout` (default
   10 s) the worker logs a WARNING, **clears the global flag**, and
   continues. Nothing makes the add-node side notice. `CREATE_REPLICATION_SLOT`
   waits for running transactions on the origin to finish, so a long user
   transaction, a paused process or slow I/O easily exceeds 10 s; workers
   then commit while the progress/snapshot pair is being captured, which
   reopens exactly the `dcbba6bb` loss window.
2. **xid is assigned lazily.** A worker that passed the flag check, started
   its transaction, but has not yet written a row has no xid; the pause
   function counts it as paused. It can then write and commit inside the
   window.

`b743cca8` also reverted a Phase 9 `sync_event` handshake because it
deadlocked against this code path — another sign this is fragile.

### 1.5 `spock.progress` persistence — three designs in seven months

- `b8f1eea9` (2025-10): custom WAL rmgr writes `SPOCK_RMGR_APPLY_PROGRESS` per
  commit; redo restores shmem.
- `c4368188` (2025-12): crash in `spock_rmgr_redo()` after an apply worker
  crash (startup process had no hash pointers).
- `a43f4b82` (2026-02): WAL record omitted `remote_insert_lsn` → 0 after crash.
- `a4e34ce2` + `a4b93e87` (2026-04): checkpoint hook; regular checkpoints
  skipped the dump → stale progress after crash if idle longer than
  `checkpoint_timeout`.
- `2f9a686c` (2026-05): **removed** the checkpoint hook, the per-commit WAL
  record and the core patch; replaced with a shutdown-only `resource.dat`,
  `reconcile_progress_with_origin()` at worker start, a forced keepalive, and
  `recover_progress_timestamps_from_commit_ts()` (`src/spock_progress_recovery.c`).
- `69722443`: as a result, `016_crash_recovery_progress.pl` is **skipped**
  ("Re-enable when fail-safe progress tracking is restored").
- `5ee6276e` (2026-08): progress entries allocated with garbage fields
  (`remote_commit_ts` when source NULL) fed into
  `spock_group_progress_update()`; `nattached` permanently inflated by
  `sub_create()`.
- `11b9d385` (2026-09): `nattached` decrement ran after the worker slot was
  released and reused (on_proc_exit vs before_shmem_exit ordering).

After SIGKILL, progress now depends on origin LSN (durable) plus a scan of
`pg_commit_ts` for timestamps. Add-node reads this progress from peers
(`read_peer_progress`) to place new slots, so a crash of an existing node
during add-node feeds reconstructed progress into slot placement. Crash
tests `022_rmgr_progress_post_checkpoint_crash.pl` (scheduled),
`027_remote_commit_ts_recovery.pl`, `029_..._clean_shutdown.pl`,
`023_forced_keepalive_timing.pl`, `026_no_double_wal_flush.pl` (none of the
last four are scheduled).

### 1.6 Conflict resolution — a recent fix that looks like it introduced a convergence bug

`64ea462d` (2026-06) "fix spurious tiebreaker-equal WARNING". In
`conflict_resolve_by_timestamp()` (`src/spock_conflict.c` l.99-200), when
`remote_ts == local_ts`:

- **Before:** `loc_node = get_node(local_origin_id)` — the node that wrote
  the existing local tuple — compared against the remote origin. Every node
  compares the same pair (writer A vs writer B), so all nodes pick the same
  winner.
- **After:** `loc_node = get_local_node()->node` — the node *applying* the
  change. Plus a shortcut: same origin → apply remote.

With three or more nodes this is order-dependent. Example: tiebreakers n1=1,
n2=2, n3=3 (lower keeps local). n1 and n2 update the same row with equal
commit timestamps. n1 keeps A (1<2); n2 applies A (2>1). On n3: if A arrives
first, B then compares n3(3) vs n2(2) → apply B. If B arrives first, A then
compares n3 vs n1 → apply A. So n3 can end up with B while n1 and n2 have A —
**divergence**. The test that came with it (`025_tiebreaker_equal_warning.pl`)
is single-writer and does not cover three writers.

Equal timestamps are more likely than they look. The core patch
`patches/18/pg18-025-logical_commit_clock.diff`
(`EnsureMonotonicTransactionStopTimestamp`) forces a local commit's
timestamp to `last_seen + 1 µs` when the local clock is behind. Two nodes
whose clocks lag, both having last seen the same remote commit, will both
stamp `T+1`. **Clock skew makes ties likely**, which Antithesis can inject.
The same patch has a TODO: the logical clock is "not postmaster restart
safe" — after a restart a lagging node can stamp commits *older* than ones it
already saw, so last-update-wins picks the wrong winner. Also `get_node()`
uses the 16-bit `node_id` (hash of name, `024_node_id_collision.pl`); a
collision is now rejected at `create_node` (`64ea462d`), but existing clusters
can still hit it.

`7057507a` (2025-08) earlier fixed `get_tuple_origin()` returning an
uninitialized timestamp/origin (epoch) for tuples from the current
transaction and the DELETE-DELETE case.

### 1.7 Connection liveness and timeouts

- `2535c3fa` (2026-03): sets `wal_sender_timeout=0` on replication
  connections and relies on TCP keepalive (`keepalives_idle=10,
  interval=5, count=3` ≈ 25 s) plus `spock.apply_idle_timeout` (300 s).
  Also fixed `last_receive_timestamp` being reset on every empty poll, which
  meant `apply_idle_timeout` *never fired*. Consequence: a **paused**
  (SIGSTOP) peer still has its kernel answering keepalives, so the provider's
  walsender stays attached indefinitely and the subscriber waits up to 300 s;
  when that fires mid-transaction it now goes through the
  `ERRCODE_CONNECTION_FAILURE` branch (only since `8dcfbcd5`, three weeks
  ago).
- `4dfe7496` / `d286f3df`: stale socket fd reused after libpq closed it →
  `epoll_ctl(EINVAL)` cascade (`019_stale_fd_epoll_after_conn_death.pl`).
- `fdd9587e`: non-transactional `sync_event` message could arrive before
  the startup message on a new slot → protocol mismatch crashed the worker.

### 1.8 Worker lifecycle / shared-memory ordering

- `24c3c01f`: `signal_workers` list in TopTransactionContext used after abort.
- `a95e44fb`: worker detach signalled a manager whose memory was already gone.
- `11b9d385`: on_proc_exit ran after the worker slot was handed to a new
  worker (see 1.5).
- `327757ab` (test `103_manager_worker_dboid_race.pl`): supervisor registered a
  manager for a database dropped mid-scan → FATAL respawn loop. **Fix is a
  narrowing, not a close**: it re-checks the `pg_database` syscache just
  before `spock_worker_register()` (`src/spock.c` `start_manager_workers()`),
  but the database can still be dropped between that check and the worker
  attaching.
- `f1e4f718`: hash removal during iteration; NULL from full
  `HASH_FIXED_SIZE` tables; torn 64-bit counter reads.
- `dcbba6bb`'s `pause_apply` flag is **global** (`SpockCtx`), not per
  database, while the wait only checks same-database workers.

### 1.9 Failover slots (PG15/16 only)

April 2026: `7339cb80` (InvalidTransactionId in xmin compare), `84bb1111`
(primary stops before promote → uncaught ERROR released the slot →
**slot loss**), `7779df6b`, `1ab8dd62` (restart_lsn below standby redo →
PANIC loop), `6f3c775d` (flush LSN 0 → Assert/SIGABRT, cluster reset),
`8220306d` (lock order, Invalid confirmed_flush). `f2d4bbbb`
(hot_standby_feedback=off error loop). On PG18 the spock worker is not
registered (`3bd075a0`), so this cluster matters only if the harness runs
PG15/16.

### 1.10 Other notable single fixes

- `4c7ed47a`: cached relation reused without `AcceptInvalidationMessages()` →
  an index dropped under the worker → "could not open relation with OID"
  (and before `f3d4935e`, that went down the discard path).
- `f84b853d`: use-after-free on replay-queue entries at COMMIT (spill-to-disk
  feature `078e8965`, March 2026 — new code, one UAF already found).
- `3efae112`: delta-apply subtransaction resource owner (buffer-pin error).
- `16ce5af5`: REPLICA IDENTITY FULL used a stale cached replica index.
- `34d473dc` / `f21e71bc` (2026-08): peer sessions now pinned to
  `datestyle=ISO`; before that, text-transferred timestamps (progress rows,
  and user data under `force_text_transfer` or cross-major) could be read as a
  different instant. Relevant to Antithesis only if TimeZone/DateStyle differ
  between nodes.

---

### 1.11 TAP tests mapped to their fix commits

Scheduled = in `tests/tap/schedule` (every PR); nightly = `schedule-nightly`;
**unscheduled** = runs only by hand.

| test | fix commit(s) | bug | schedule |
|---|---|---|---|
| 013_exception_handling | `043409b5` | exception modes | PR |
| 013_origin_change_restore | `85688477`, `9d33ca88` | resolutions logging | PR |
| 014_pgdump_restore_conflict | — | | PR |
| 015_skip_lsn | `3cf97588` | skip_lsn re-disable / LSN mismatch | PR |
| 015_forward_origin_advance | `401197ab` | forwarded origin | PR |
| 015_resync_readonly_origin | `7d21b807` | resync truncate on read-only → loss | **unscheduled** |
| 016_sub_disable_missing_relation | `47d4a003` | dangling local_tuple | PR |
| 016_crash_recovery_progress | `a43f4b82` | remote_insert_lsn lost after crash | **skipped** (`69722443`) |
| 018_forward_origins | `1c3ca201` | cascade origin name | PR |
| 018_failover_slots | `84bb1111` etc. | slot loss on promote | PR |
| 019_stale_fd_epoll_after_conn_death | `4dfe7496` | stale fd | PR |
| 020_exception_root_cause | `8dbfa492`, `ea13e724` | root cause text | **unscheduled** |
| 020_sync_standby_feedback_lsn | `5f654e34` | wrong-stream LSN → loss after failover | **unscheduled** |
| 021_uc_null_key_skip | `5223a1db` | NULLS NOT DISTINCT | PR |
| 022_apply_mem_context | `4cb409cb` | unbounded memory | PR |
| 022_rmgr_progress_post_checkpoint_crash | `a4b93e87`/`2f9a686c` | stale progress after crash | PR |
| 023_forced_keepalive_timing | `2f9a686c` | | **unscheduled** |
| 024_node_id_collision | `94f4ad6d`, `64ea462d` | 16-bit node_id collision | PR |
| 025_tiebreaker_equal_warning | `64ea462d` | (see 1.6) | PR |
| 026_no_double_wal_flush | `2f9a686c` | | **unscheduled** |
| 027_remote_commit_ts_recovery / 029 | `2f9a686c` | commit_ts recovery after crash | **unscheduled** |
| 030_autoddl_repset_stickiness | `804a10b6` | | PR |
| 030_read_retry_count_guc | `8f64833d` | | **unscheduled** |
| 031_discard_truncate_missing_relation | `162dc562` | TRUNCATE restart loop | PR |
| 035/036 deadlock retry | `f3d4935e` | deadlock → discard | nightly |
| 037_wire_format_datestyle | `34d473dc` | | PR |
| 039_no_replay_mode_leak | `acf6cdae` | replay-mode leak | PR |
| 045_lsn_from_commit_ts | `8de96369` | unbounded scan / wrong LSN | PR |
| 046_apply_worker_exception_misclassification | `ed0a9945`, `8dcfbcd5` | SIGTERM / idle-timeout misclassification | PR (needs injection points) |
| 099_zodan_mixed_version | `40c7b39a`, `f8f78b2e` | mixed-version add_node | nightly |
| 101_clean_exit_on_conn_loss, 102_no_origin_leak_on_disconnect | `d286f3df` | origin advanced past aborted txn | **unscheduled (manual)** |
| 103_manager_worker_dboid_race | `327757ab` | dboid race | PR |
| 104_iptables_conn_block | — | firewall outage | **unscheduled (manual)** |
| 105_sub_disable_retransmit_after_disconnect | `db380dd8` | SUB_DISABLE on retransmit | PR |
| 800_standby_hot_standby_feedback | `f2d4bbbb` | | **unscheduled** |
| 005_daylight_savings, 006_sync_during_write, 011_zodan_sync_third, 014_rolling_upgrade | — | | **unscheduled / commented out** |

Pattern: the tests that inject the kind of faults Antithesis will
(SIGKILL crash recovery, connection blocking, failover to a sync standby)
are mostly the unscheduled ones. Those paths have the least regression
protection.

---

### 1.12 Suggested Antithesis targets, ranked by bug history

1. **Exception misclassification → silent discard / spurious disable.** Run
   with `spock.exception_behaviour` = `transdiscard` and `sub_disable`; inject
   partitions, provider restarts, process pauses past
   `spock.apply_idle_timeout`, local lock contention, and worker FATALs.
   Property: no row in `spock.exception_log` and no subscription disabled
   unless a real data conflict was created by the workload.
2. **Convergence under equal timestamps (3+ writers, clock skew).** Property:
   all nodes hold the same row value after quiesce (see 1.6).
3. **Add-node during load with a long-running transaction on the source
   (>`spock.pause_timeout`) and crashes/pauses of the joining backend.**
   Property: new node's row set equals the others' (see 1.4).
4. **Crash between data commit and forwarded-origin advance** in
   `forward_origins='all'` topologies; delta-apply columns double-count.
5. **Failover of a subscriber's synchronous standby** (`5f654e34`).
6. **SIGKILL + restart while `spock.progress` is read by add-node** (1.5).
7. Worker churn: `sub_alter_options()` / `sub_disable`/`sub_enable` storms
   while applying (`ed0a9945`, `11b9d385`, `acf6cdae`).

## 2. Areas examined

- `git log` over the whole history: fix-keyword lists, per-file counts over
  `src/*.c`, per-year totals, `samples/Z0DAN` history.
- Fix diffs read: `ed0a9945`, `8dcfbcd5`, `db380dd8`, `64ea462d` (full
  conflict function), `327757ab`; commit bodies and `--stat` of `acf6cdae`,
  `0f7f068b`, `b8993cb5`, `d286f3df`, `f3d4935e`, `a43f4b82`, `a4b93e87`,
  `2f9a686c`, `c4368188`, `5ee6276e`, `11b9d385`, `986ad069`, `dcbba6bb`,
  `401197ab`, `2948d567`, `1c3ca201`, `5f654e34`, `f21e71bc`, `34d473dc`,
  the failover-slot series, `fa52495a`, `7d21b807`, `b743cca8`, `f84b853d`,
  `4c7ed47a`, `162dc562`, `3cf97588`, `24c3c01f`, `a95e44fb`, `1bbcc877`,
  `dfb3ee49`, `f1e4f718`, `3efae112`, `2535c3fa`, `8de96369`, `fdd9587e`,
  `4cf06eac`, `f38da44a`, `b7fc7022`, `5b88e2de`, `86d6c13c`, `72625daa`,
  `20e8e148`, `40c7b39a`, `69722443`.
- Current code: `src/spock_apply.c` (`clear_transient_exception_state`
  l.418, `prepare_transient_error_retry` l.443, `maybe_pause_for_slot_creation`
  l.565, `handle_begin` l.660-900, `handle_origin` l.1299,
  `spock_apply_worker_shmem_exit` l.2305, PG_CATCH l.3880-4100,
  `maybe_advance_forwarded_origin` l.5165); `src/spock_conflict.c` l.95-320;
  `src/spock_functions.c` `spock_pause_apply_workers` l.4060;
  `src/spock_sync.c` l.690-870; `src/spock_group.c` header;
  `patches/18/pg18-025-logical_commit_clock.diff`;
  `tests/tap/schedule`, `tests/tap/schedule-nightly`, headers of TAP tests
  024 and 103.

## 3. Assumptions

- Commit-message keyword matching overcounts (doc/test "fix" commits) and
  undercounts (fixes without the word); I used it for density and then read
  the individual diffs for the bugs I call out.
- PG18 is the likely Antithesis target (per the build memory), so the
  failover-slot worker is de-prioritized.
- Shared-memory `exception_log` is re-initialized on postmaster
  crash-restart (`spock_shmem.c` init path); I did not trace every
  `ShmemInitStruct` call to confirm `found == false` on restart.
- The three-node tiebreaker divergence (1.6) and both pause-barrier holes
  (1.4) come from reading the code; I have not reproduced them.

## 4. Open Questions

- Does any apply-path code raise `FATAL` or call `proc_exit()` mid-transaction
  other than the `got_SIGTERM` exit? Each such site leaves a stale
  `commit_lsn` in the exception log.
- Is the `64ea462d` change to compare the applying node, not the tuple's
  origin, intentional for multi-writer clusters? Docs on LWW tie-breaking
  should say which pair is compared.
- What does the add-node path do when `spock.pause_timeout` expires on the
  worker side while `CREATE_REPLICATION_SLOT` is still waiting? Nothing in
  `spock_sync.c` re-checks that workers stayed paused.
- Who calls `spock.get_lsn_from_commit_ts()` now that it can return NULL
  (no in-tree caller found)?
- Is the at-least-once replay of forwarded transactions after a crash
  (`401197ab`) acceptable for delta-apply columns, or is the follow-up still
  planned?
- Why are crash/fault TAP tests (020_sync_standby, 023, 026, 027, 029,
  101, 102, 104) left out of every schedule?
