---
sut_path: /home/msharp/dev/pgedgea/spock
commit: 69d9228f5df363761dc3ae6eebf7e2fcfe49b8e5
updated: 2026-10-13
external_references: []
---

# Property discovery — focus 5: Resource boundaries

Lens: exhaustion, leaks, backpressure, capacity limits, queue depths. Every
SUT-side assertion suggested here is **missing** (the tree has no Antithesis
instrumentation; see `existing-assertions.md`).

Two kinds of resource problem showed up:

- **Fixed-size shared tables that only grow** (exception-log slots, the
  progress hash, PG replication-origin states). Each fills up after enough
  node churn and then fails in a way much worse than "table full".
- **Things that outlive their owner** (logical slots, origins, temp files,
  connections, worker restarts). These are best checked once the cluster is
  quiet.

## Category A — Fixed-capacity shared tables under node churn

These need a workload loop that adds and removes the spare node under **fresh
node names**, and preferably a config variant with small `max_worker_processes`
and the PG18 default `max_active_replication_origins = 10`, so the limits are
reached within one run.

### exception-log-slots-never-exhausted — Exception-log slots are never used up by dropped subscriptions

| | |
|---|---|
| **Type** | Safety |
| **Property** | While a node has fewer live subscriptions than `max_worker_processes`, an apply worker never fails to find an exception-log slot, and an ERROR in `handle_begin` never leaves `SpockCtx->lock` held or writes outside the slot array. |
| **Invariant** | SUT-side `Unreachable("exception log slot table full")` just before `elog(ERROR, "unable to find an empty exception log slot")` (`src/spock_apply.c:~788`). Unreachable because, with live subscriptions under capacity, this state should never occur at all. Plus SUT-side `AlwaysOrUnreachable(my_exception_log_index >= 0, "exception marker index valid in PG_CATCH")` before the `initial_error_message` write (`:~4074`), which catches the out-of-bounds write whatever the cause. A workload liveness check (every pair passes a `sync_event` barrier after each churn cycle) shows the node-wide hang. |
| **Antithesis Angle** | Churn, not faults: slots are claimed per subscription **name** and never freed (`TODO ... Memory leak`, `:797-806`); only a postmaster restart clears them, so SIGKILL makes this harder to reach. Code reading: the ERROR fires while holding `SpockCtx->lock` EXCLUSIVE; `AbortOutOfAnyTransaction` with no open transaction does not release it; `PG_CATCH` writes `exception_log_ptr[-1]` (1 KB message) out of bounds; replay calls `handle_begin` again, which takes the same LWLock again → self-deadlock → every apply row, the manager, admin calls and shutdown block. |
| **Why It Matters** | An ordinary operation (add/remove nodes with new names, about `max_worker_processes` times without a restart) turns into a whole-node replication stop that cannot be interrupted, plus shared-memory corruption. Lead L14; six focuses agreed on the leak. |

**Open Questions:**

- Is a transaction ever open when `handle_begin` runs? If yes, the lock is released and only the out-of-bounds write remains. `(partial: mechanism present in code; not run)`
- What shared-memory struct sits just before `"spock_exception_log"` on PG18 (what the -1 write corrupts)?
- Should a re-created subscription with a reused name inherit the old marker?

Confidence: high (mechanism, code-checked); medium (reachability within one run without the small-capacity variant)
Evidence file: properties/exception-log-slots-never-exhausted.md

### progress-hash-capacity-survives-node-churn — The progress hash never fills with entries for removed nodes

| | |
|---|---|
| **Type** | Safety |
| **Property** | While the number of live (local, remote) node pairs is below `max_worker_processes`, inserting into `SpockGroupHash` (`spock.progress`) never fails. |
| **Invariant** | SUT-side `Unreachable` at each of the four insert sites, one message each ("spock progress hash full at sub_create / apply attach / resource load / force-set"). This needs `HASH_ENTER` changed to `HASH_ENTER_NULL` (or a count check), because today's `entry == NULL` branches are dead code: on a full shared fixed-size table PG18 `HASH_ENTER` raises "out of shared memory" (53200) and never returns NULL (`dynahash.c:1085-1096`). Workload `Sometimes(progress rows > live pairs + 2, "progress hash holds stale entries")` as a reachability signal. |
| **Antithesis Angle** | Entries are never deleted (`src/spock_group.c:41-42`) and are written to `resource.dat` and reloaded on every start, including crash restarts. So unlike the exception slots, kills do **not** reset it. Fresh-name node churn adds one entry per cycle per existing node. When full: `sub_create` fails with a vague "out of shared memory"; an apply worker attaching after a restart gets class 53 and retries every 5 s for ever. |
| **Why It Matters** | A long-lived cluster that has rotated nodes can no longer add subscriptions, or loses a subscription after a restart, with a misleading error. Lead L16. |

**Open Questions:**

- Is "never deleted" a deliberate design choice (stable pointers), and is the intended fix deletion on node drop or a larger table?
- Can anything delete entries today? (No `HASH_REMOVE` in `src/spock_group.c`.)

Confidence: high (mechanism); medium (impact ranking: needs many fresh-name cycles or a small-capacity variant)
Evidence file: properties/progress-hash-capacity-survives-node-churn.md

### replication-origin-states-do-not-leak — Replication-origin states do not pile up until no free state remains

| | |
|---|---|
| **Type** | Safety |
| **Property** | Each node's replication-origin states are only those its live subscriptions and in-flight table syncs need; "could not find free replication state slot" never occurs. |
| **Invariant** | Workload log scan `Unreachable("replication origin state table full")` on `could not find free replication state` in any process (in the startup process it also means the node cannot restart). After quiescence, two `Always` checks with separate messages: "no unnamed origin states" (`pg_replication_origin_status.external_id IS NULL` count = 0) and "no orphan named origins" (every `spk_%` origin matches a live `sub_slot_name` or a table-sync slot of a table not yet READY/FAILED). Always after quiescence fits: with nothing in flight, any extra state is a leak. |
| **Antithesis Angle** | Three code-read sources: (1) crash redo of apply commits calls `replorigin_advance(node id)` (L1 side effect), creating states with no catalog row that are checkpointed for ever; (2) a table sync killed after its origin was advanced is later marked FAILED, and cleanup drops the remote slot but not the local origin (`src/spock_sync.c:1459-1466` only drops when a session origin is set); (3) `sub_drop`/`remove_node` drop only the subscription's own origin. Needs SIGKILL between checkpoints, kills/partitions during `sub_resync_table`, and remove_node after an interrupted resync. |
| **Why It Matters** | PG18's default limit is 10. Filling it stops subscriptions (class 53, retried for ever), stops `sub_create`, and, if hit during crash-recovery redo, prevents the node from starting at all. |

**Open Questions:**

- Is stamping apply commits with the node id (and so creating node-id states at redo) intended? An L1 fix would remove source (1).
- Should table-sync cleanup drop the local origin by name on the FAILED path?
- How should `max_active_replication_origins` be sized? `docs/sizing.md` does not count redo-created states.

Confidence: medium (source 1 depends on stock PG redo behaviour checked in a local PG18 tree; sources 2 and 3 code-checked; none run)
Evidence file: properties/replication-origin-states-do-not-leak.md

## Category B — Leftovers and backpressure after faults (quiescent checks)

All checks here run after faults stop, documented cleanup has run, and every
ordered pair has passed a `sync_event` barrier, with quiet time longer than
`wal_sender_timeout` + `apply_idle_timeout`.

### no-orphan-slot-pins-wal-after-quiesce — No Spock slot pins WAL without a consumer

| | |
|---|---|
| **Type** | Safety |
| **Property** | After quiescence and documented cleanup, every `spock_output` logical slot belongs to a live subscription (or an in-progress table sync) and has confirmed past a marker LSN taken after quiescence began. |
| **Invariant** | Workload-side `Always(orphan_spock_slots == 0, "no spock slot without owning subscription after quiesce")` and `Always(lagging_owned_slots == 0, "every owned spock slot confirms past the quiesce marker")`, plus `Sometimes(..., "sub_drop could not reach provider")` from the log to show the warned path ran (the workload then drops those slots as the warning tells it to). Always at a quiescent point: a leftover slot is wrong whenever the check runs. |
| **Antithesis Angle** | Orphans come from `sub_drop` with the provider unreachable (warned), `sub_drop` during a table resync (sync worker and its `<slot>_<hash>` slot left alone, **not warned**, L28), SIGKILL during initial sync (cleanup runs only on ERROR, L13), and orchestrator death during add_node (L20). Partitions during remove_node and kills during resync and add_node explore these. The lag check also catches owned slots whose consumer is stuck. |
| **Why It Matters** | An ownerless slot keeps WAL for ever (Spock sets no `max_slot_wal_keep_size`), so the provider's disk eventually fills and the provider stops. |

**Open Questions:**

- Should `sub_drop` stop sync workers and drop table-sync slots?
- Is a `max_slot_wal_keep_size` recommendation intended (orphan becomes a lost slot instead of a full disk)?

Confidence: high (paths code-checked); medium (whether each is classed as a bug)
Evidence file: properties/no-orphan-slot-pins-wal-after-quiesce.md

### replay-spill-file-lifecycle — Replay spill files live only as long as their transaction

| | |
|---|---|
| **Type** | Safety |
| **Property** | Apply-worker spill files exist only while their remote transaction is in progress; after quiescence none remain, and spilled entries read back without reporting corruption. |
| **Invariant** | Workload `Always(n == 0, "no apply-worker temp files after quiesce")` via `pg_ls_tmpdir()` joined to Spock apply PIDs. SUT-side `Unreachable("corrupt replay spill file")` at the header and body read checks (`src/spock_apply.c:4894, 4908`; two messages). SUT-side `Reachable("replay queue spilled to disk")` (`:5051`) and `Reachable("replay read back a spilled entry")` (`:4922`) as exploration markers. |
| **Antithesis Angle** | Every remote transaction over `exception_replay_queue_size` (4 MB) spills on every subscriber, not just failing ones. Faults during a large transaction (partition, provider restart, SIGTERM) and a real data error that forces read-back explore reset, exit and replay ordering. Disk-full / `temp_file_limit` becomes a class 53 error, retried for ever (a silent stall). |
| **Why It Matters** | New code, marked "until spill-to-disk code is proven stable", with a past use-after-free (`f84b853d`). Leaked temp files use up disk; a false "corrupt" read is XX000 and under SUB_DISABLE disables the subscription. Lead L29. |

**Open Questions:**

- Is retrying for ever on a spill-induced 53100/53400 intended?
- Can the worker leave and re-enter the apply loop in the same process with a spill file still open (idle-timeout path)?
- Exact PG18 `backend_type` string for Spock bgworkers (needed to join temp files to apply PIDs).

Confidence: medium
Evidence file: properties/replay-spill-file-lifecycle.md

### spock-connections-match-subscriptions-after-quiesce — Provider connections match enabled subscriptions after quiescence

| | |
|---|---|
| **Type** | Safety |
| **Property** | After quiescence, each provider has exactly one Spock walsender per enabled subscription to it (plus one per in-progress table sync) and no leftover short-lived Spock helper sessions. |
| **Invariant** | Workload `Always(extra_walsenders == 0, "spock walsenders match enabled subscriptions after quiesce")` (`pg_stat_replication` joined to `spock_output` slots compared with subscriptions on peers) and `Always(stray_sessions == 0, "no leftover spock helper sessions after quiesce")` (`pg_stat_activity` `application_name` with Spock purpose suffixes). |
| **Antithesis Angle** | Connections are named `<sub>_<purpose>` (`spock_connect_base`, `src/spock.c:366-475`). Code reading: `sub_create` and `sub_drop` do not `PQfinish` on ERROR (`src/spock_functions.c:573-596, 845-859`), so the leak lives as long as the calling session; sync workers outlive `sub_drop`; the sync cleanup loop holds a connection with no time limit. Partitions and RSTs during admin calls on a reused workload connection, and provider pauses that leave old walsenders behind, explore this. |
| **Why It Matters** | Leaked or stuck sessions use up provider `max_connections` / `max_wal_senders` and keep slots marked active, so a returning subscriber cannot attach. |

**Open Questions:**

- Exact purpose suffixes per `spock_connect*` call site (enumerate before implementing).
- Is a connection leaked by a failed admin call in a session that will end soon considered a bug?

Confidence: medium
Evidence file: properties/spock-connections-match-subscriptions-after-quiesce.md

## Category C — Restart pacing and fd reuse

### worker-respawn-rate-bounded — Spock worker respawns stay paced

| | |
|---|---|
| **Type** | Safety |
| **Property** | Outside postmaster restarts, no apply worker (per subscription) or manager (per database) exits with an error more than 3 times in any 5 s window. |
| **Invariant** | Workload log tailer: `Always(n <= 3, "apply worker error exits per subscription per 5 s window")` and `Always(n <= 3, "manager error exits per database per 5 s window")` on the `... exiting with error` lines from `spock_worker_detach` (`src/spock_worker.c:431-435`), skipping windows with a postmaster start or an injected SIGKILL. SUT-side `Sometimes(restart_delay == 0 at error exit, "apply worker exiting with zero restart delay")` to show which faults reach the unpaced path. Always over a sliding window: pacing must hold in every window. |
| **Antithesis Angle** | `restart_delay_on_exception` defaults to 0 and is set on every BEGIN (`src/spock_apply.c:676`), so FATAL exits that skip `PG_CATCH` (read-only FATAL `:2982`, "incorrect spock message" `:2928`) respawn after about 1 ms. Bgworker-slot exhaustion makes the **manager** raise ERROR (`src/spock_worker.c:136-141, 195-204`), and the supervisor restarts it with no delay. Readonly toggles, SIGINT/cancel on apply, and a small `max_worker_processes` with parallel queries explore it; a plain partition is the paced control. |
| **Why It Matters** | A respawn loop forks a worker and a provider walsender every few ms, floods logs and uses up CPU. `f3d4935e` measured 83 restarts/s before pacing. Lead L23. |

**Open Questions:**

- Is the 1 ms respawn after an unclassified error intended?
- Should a manager that cannot register a worker back off instead of exiting?

Confidence: medium
Evidence file: properties/worker-respawn-rate-bounded.md

### apply-stale-socket-never-polled — The apply worker never waits on a closed libpq socket

| | |
|---|---|
| **Type** | Safety |
| **Property** | No Spock worker ever waits on a socket that libpq has already closed. |
| **Invariant** | Workload log scan `Unreachable("spock worker epoll_ctl failure")` on `epoll_ctl() failed` from Spock workers. SUT-side `Always(fd == PQsocket(applyconn), "apply waits on live libpq socket")` and `Always(PQstatus(applyconn) != CONNECTION_BAD, "apply waits on a connected libpq handle")` before the only `WaitLatchOrSocket` (`src/spock_apply.c:3492`). SUT-side `Reachable("apply detected dead connection at stream_replay")` at the early return (`:~3450`). |
| **Antithesis Angle** | Regression for `4dfe7496`/`d286f3df`: connection death during in-process replay left a stale fd that `epoll_ctl` rejected, and the error path lost a transaction. A closed fd number is soon reused by the spill temp file or relation files. Walsender kills and RSTs while the subscriber is replaying a failed, spilling transaction recreate the original timing; TAP 101/102 that cover it are in no schedule. |
| **Why It Matters** | The original bug caused silent data loss under ordinary connection drops. This is a cheap tripwire for any regression of that fix. |

**Open Questions:**

- None about the mechanism (only one socket-wait site exists; grep in the investigation log).

Confidence: high (regression target); low (expectation of new findings)
Evidence file: properties/apply-stale-socket-never-polled.md

## Category D — Memory

### apply-worker-memory-bounded — Apply worker memory does not grow with transactions applied

| | |
|---|---|
| **Type** | Safety |
| **Property** | Under sustained load, faults and in-process replays, an apply worker's process-lifetime memory stays below a fixed bound that does not grow with the number of transactions applied. |
| **Invariant** | SUT-side `AlwaysOrUnreachable(MemoryContextMemAllocated(TopMemoryContext, true) < 256 MB, "apply worker memory stays bounded")` in `handle_commit` after commit (rate-limited). SUT-side `AlwaysOrUnreachable(len(sync_replica_lsn) < bound, "sync-standby hold list bounded")` in `append_feedback_position` (phase 2 topology). Workload backup: `Always(rss_growth_kb < 500000, "apply worker RSS growth bounded")` from `ps` per PID, as TAP 022 does. AlwaysOrUnreachable because a short run may not push enough through one worker. |
| **Antithesis Angle** | Code-read growth paths: the sync-standby hold list gets one `TopMemoryContext` entry per applied transaction while the subscriber's sync standby lags or is paused, and is walked in full under `SyncRepLock` EXCLUSIVE on every message (`src/spock_apply.c:3147-3236`); spilled replay entries leak one message per caught exception (`:3725-3745` vs `PG_CATCH`). Long runs, many data errors on large transactions, and pausing a standby explore these. |
| **Why It Matters** | Past leak `4cb409cb` reached about 800 MB at 200k rows. An unbounded list under a global lock also slows every committing backend on the subscriber. |

**Open Questions:**

- Is unbounded growth of the sync-standby hold list while the standby is down accepted?
- What memory bound would the team accept for an apply worker?

Confidence: medium (hold list: high on mechanism, needs a standby container; general leak: speculative)
Evidence file: properties/apply-worker-memory-bounded.md

---

## Areas examined

- Exception-log slot array: claim, clear, error path, `PG_CATCH` use
  (`src/spock_apply.c:120, 386-395, 658-880, 3867-4133`; `src/spock_worker.c:860-880`;
  `include/spock_exception_handler.h:56-61`).
- `SpockGroupHash` sizing, insert sites, `resource.dat` load/dump
  (`src/spock_group.c`), and PG18 `dynahash.c` `HASH_ENTER` behaviour on full
  shared tables (local PG18 source tree).
- Channel stats hash `SpockHash` (`src/spock_worker.c:928-990`): **handled
  correctly**. It checks the entry count before `HASH_ENTER`, logs "channel
  counter hash table full" once and stops counting. Capacity
  `1000 * max_worker_processes`. No property.
- Spock worker slot table and bgworker registration (`src/spock_worker.c:95-205,
  404-480`), manager restart logic (`src/spock_manager.c:39-160`), supervisor
  (`src/spock.c:787-960`).
- Replay queue and spill file (`src/spock_apply.c:4800-5130`), GUC default
  (`src/spock.c:1406-1418`).
- Feedback lists `lsn_mapping` and `sync_replica_lsn`
  (`src/spock_apply.c:173, 231, 1100-1110, 3085-3240`).
- Slot creation, table-sync slot/origin naming and cleanup
  (`src/spock_sync.c:395-460, 1429-1470, 1838-1960, 2005-2090`); `sub_drop`
  (`src/spock_functions.c:762-870`); ZODAN remove path
  (`samples/Z0DAN/zodremove.sql:189, 227`) and Phase 10 error handling
  (`samples/Z0DAN/zodan.sql:2219-2270`).
- PG18 replication-origin state array, checkpoint persistence, redo advance,
  `pg_show_replication_origin_status` NULL names (`origin.c`, `xact.c` in a
  local PG18 tree).
- Connection setup and `application_name` (`src/spock.c:366-475`); socket waits
  (only `src/spock_apply.c:3492`).
- Not turned into properties: `spock.exception_log` / `spock.queue` /
  `spock.resolutions` table growth (the last has a retention GUC; the first
  two grow without limit, but too slowly to matter in a run); provider-side
  reorder-buffer spill (stock PG); slot-group array exhaustion (L10, config
  that the workload avoids); `lsn_mapping` (bounded by WAL flush delay).

## Assumptions affecting multiple properties

1. **PG18 is the target and the build is cassert** (sut-analysis §16). The
   dynahash, origin and redo behaviour above was read in a local stock PG18
   tree; the pgEdge patches do not touch `dynahash.c`, `origin.c` or the
   origin part of `xact_redo_commit`.
2. **Node churn with fresh names is part of the workload**, or at least of a
   variant. Without it, the three Category A properties are hard to reach.
   Re-adding the spare node under the same name reuses all three kinds of entry.
3. **A small-capacity config variant is acceptable** (`max_worker_processes`
   about 10, `max_active_replication_origins` at the PG18 default 10), so
   limits are hit within one run. The deployment guidance suggests generous
   values, which delays these failures but does not remove them.
4. **Quiescent checks need a long quiet period**: at least
   `wal_sender_timeout` + `apply_idle_timeout` after the last fault (the
   deployment notes suggest lowering `apply_idle_timeout` to about 30 s and
   `wal_sender_timeout` to match), and documented cleanup (warned slot drops,
   `zodan_cleanup.sql` after failed add_node) must run before the checks.
5. **SIGKILL of any backend crash-restarts the postmaster** and clears
   in-memory tables (exception slots) but not files (`resource.dat`,
   `replorigin_checkpoint`, temp files are removed at restart only when
   `remove_temp_files_after_crash=on`). This decides which leaks kills hide.
6. **One database per instance** in v1. The cross-database sharing of
   exception slots (same subscription name in two databases) is not covered.
