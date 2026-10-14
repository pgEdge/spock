---
sut_path: /home/msharp/dev/pgedgea/spock
commit: 69d9228f5df363761dc3ae6eebf7e2fcfe49b8e5
updated: 2026-10-13
external_references: []
---

# Property discovery — focus 2: Concurrency

Lens: races, atomicity, ordering and shared mutable state. Every mechanism
below was re-read in code at HEAD 69d9228f; none has been run. No Antithesis
instrumentation exists in the tree, so every SUT-side assertion named here is
**missing** and would be new work.

## Category: Concurrent writers on the same keys (apply vs apply, apply vs local)

### insert-race-resolved-not-discarded — Insert/insert race is resolved by LUW, not discarded

| | |
|---|---|
| **Type** | Safety |
| **Property** | When an apply worker's INSERT races with a same-key INSERT from another upstream's apply worker or a local session, Spock resolves it as an `insert_exists` conflict instead of dropping the upstream transaction. |
| **Invariant** | Workload `Always`: after each quiescent barrier, no `spock.exception_log` row on any node has `error_message` matching `duplicate key value violates unique constraint`, in a table whose only conflicts are same-PK inserts (PK is the only unique index). `Always` because any such row is a resolvable conflict turned into data loss. Companion `Always`: per-key payload identical on all nodes after quiescence. Suggested SUT-side (missing): `Unreachable("apply insert lost unique-key race to concurrent writer")` in `apply_work` PG_CATCH for 23505 on an INSERT into a relation whose only unique index is the RI index; `Sometimes("apply insert found row inserted by concurrent upstream")` to prove the race traffic exists. |
| **Antithesis Angle** | The window is between `FindReplTupleInLocalRel` returning "not found" and the unique check inside `ExecSimpleRelationInsert` (`src/spock_apply_heap.c:873-925`). Thread pausing / CPU modulation stretches it; network latency aligns two upstream streams at the third node. 23505 is not on the transient list (`src/spock_apply.c:3920-3990`), so it takes the replay path. |
| **Why It Matters** | Under default TRANSDISCARD the whole upstream transaction — including unrelated conflict-free rows — is silently dropped on one node; under SUB_DISABLE the subscription stops. Whether a conflict is resolved or discarded depends on microsecond timing. Source TODO at `:873` admits the gap. |

Confidence: medium (mechanism high; reachability under real timing not shown)
Evidence file: properties/insert-race-resolved-not-discarded.md

**Open Questions:**

- Is TRANSDISCARD-on-race an accepted limit, or should the INSERT path retry as `insert_exists`? `(needs human input)`
- How wide is the lookup-to-unique-check window in practice?

### lock-contention-retried-not-discarded — Apply/local lock contention is retried, never discarded

| | |
|---|---|
| **Type** | Safety |
| **Property** | Deadlocks and lock timeouts between apply workers and local sessions make the apply worker retry the transaction; they never produce exception_log rows or dropped transactions. |
| **Invariant** | Workload `Always`: no `spock.exception_log` row matches `deadlock detected`, `canceling statement due to lock timeout` or `could not obtain lock`, checked after each quiescent barrier; companion convergence `Always` on the contention table. Suggested SUT-side (missing): `Sometimes("apply worker lost deadlock to local session and will retry")` and `Sometimes("apply worker hit lock_timeout and will retry")` in the 40P01 / 55P03 branches so the `Always` is not vacuous. |
| **Antithesis Angle** | Workload runs local transactions that lock hot rows in the opposite order to remote writers and holds them briefly; optional `ALTER DATABASE SET lock_timeout` phase. Thread pausing lines up lock orders so the deadlock detector picks the apply worker. Runs with TRANSDISCARD or SUB_DISABLE (DISCARD swallows per-row errors by design, L8). |
| **Why It Matters** | Regression guard for f3d4935e, one of eleven fixes in the classifier where a missed error code became silent loss. Contention between local and replicated writes is normal in active-active use. |

Confidence: high (that the code retries today); the property's value is as a regression check
Evidence file: properties/lock-contention-retried-not-discarded.md

**Open Questions:**

- Can the unbounded `goto retry` in `SpockRelationFindReplTupleByIndex` starve the apply worker under a hot local writer (lag, not loss)?
- Does `ALTER DATABASE ... SET lock_timeout` reach the apply worker on PG18?

## Category: Admin operations racing with workers

### sub-drop-vs-table-sync-no-deadlock — sub_drop / sub_alter_sync never deadlock with a finishing table sync

| | |
|---|---|
| **Type** | Liveness |
| **Property** | `spock.sub_drop` (and `sub_alter_sync`) issued while a table sync of that subscription is finishing returns within a bound, and no backend waits on `SpockCtx->lock` indefinitely. |
| **Invariant** | Workload `Always("sub_drop returns within bound during table sync")`: each such call returns (ok or error) within ~60 s plus fault time, measured by a client timer. Workload `Always("no backend waits on spock context lock beyond bound")`: a `pg_stat_activity` sampler sees no pid with `wait_event_type='LWLock' AND wait_event='spock context lock'` unchanged across samples 30 s apart. `Always` on a bounded wait is how this liveness claim is checked continuously; an LWLock wait that long only happens in the deadlock. Suggested SUT-side (missing): `Reachable("apply SYNCWAIT catalog update under SpockCtx lock")` before `set_table_sync_status` at `src/spock_apply.c:~4538`. |
| **Antithesis Angle** | Apply worker takes `SpockCtx->lock` EXCLUSIVE then updates the sync-status row (`src/spock_apply.c:4519-4550`); `sub_drop` deletes those rows uncommitted (`src/spock_functions.c:779`) then takes the same LWLock (`:808`). Apply waits on drop's xid holding the LWLock; drop waits on the LWLock; neither can be cancelled and the deadlock detector cannot see it. Same cycle via `signal_worker_xact_callback` at COMMIT for `sub_alter_sync`. A cancellable variant exists at the SYNCDONE->READY update (heavyweight wait vs `sub_drop`'s latch loop). Needs workload admin churn: start `sub_resync_table`, then drop/alter that subscription while it finishes. Thread pausing widens the window. |
| **Why It Matters** | The LWLock variant freezes every applied row on the node (`handle_stats_counter` takes the lock per row), the manager, worker attach/detach and fast shutdown — the node's whole Spock layer hangs until a crash-restart. |

Confidence: medium (cycle confirmed in code; needs a specific admin interleaving)
Evidence file: properties/sub-drop-vs-table-sync-no-deadlock.md

**Open Questions:**

- Does anything serialise `sub_drop` against the apply worker's SYNCWAIT handling? `(partial: no serialising lock found in code; not run)`
- Is dropping or altering a subscription during an active table sync a supported operation? `(needs human input)`

### manager-kill-targets-only-listed-worker — Manager SIGTERMs only the worker slot it listed

| | |
|---|---|
| **Type** | Safety |
| **Property** | When the manager kills workers of disabled/dropped subscriptions, it kills only the apply worker it originally listed, never a new occupant of that shared-memory slot. |
| **Invariant** | Suggested SUT-side (missing): record each listed slot's `generation` and `worker_type` in `manage_apply_workers` step 1; before `spock_worker_kill` in the final loop, `Always(generation unchanged && worker_type == APPLY, "manager kills only the apply worker slot it listed")`. Workload `Always("at most one apply worker per subscription")` from `pg_stat_activity` (`spock apply <db>:<subid>`). Workload `Sometimes("enabled subscription had its apply worker restarted after a kill")` for the restart path. |
| **Antithesis Angle** | `manage_apply_workers` (`src/spock_manager.c:41-180`) keeps raw slot pointers after releasing `SpockCtx->lock`, then registers new workers via `find_empty_worker_slot`, which reuses terminated same-DB slots (`src/spock_worker.c:101-117`) — possibly one still in its kill list. A concurrent `start_sync_worker` from an apply worker can also take the slot. Needs an apply worker ERROR exit (provider partition), then `sub_disable`/drop of that sub while another sub is enabled or a resync starts. SIGKILL does not reach it (crash-restart wipes the table). |
| **Why It Matters** | A just-started apply worker is killed (restart blip), or a sync worker is killed mid-COPY, which can leave the table FAILED and silently skipped by apply (L12). Pattern E in bug history (worker lifecycle / shmem ordering) has five prior fixes. |

Confidence: medium (same-process reuse confirmed in code; effect on sync workers depends on their SIGTERM handling)
Evidence file: properties/manager-kill-targets-only-listed-worker.md

**Open Questions:**

- Does a sync worker SIGTERMed mid-COPY exit cleanly or with ERROR (decides FAILED table vs retried sync)?
- Is the same-process variant reachable given that disabling a sub makes the manager kill its worker in the same pass?

## Category: Apply/sync handoff and add-node coordination

### apply-never-waits-on-dead-sync-worker — Apply worker never waits on a sync worker that already died

| | |
|---|---|
| **Type** | Liveness |
| **Property** | When a table-sync worker exits with an error during the SYNCWAIT/CATCHUP handoff, the apply worker notices and the subscription keeps replicating (the table ends READY or visibly FAILED). |
| **Invariant** | Suggested SUT-side (missing): `Unreachable("apply waits on sync worker that already exited with error")` in `wait_for_sync_status_change` when `spock_sync_find` returns a slot with `terminated_at != 0`; `Unreachable("sync worker missing at SYNCWAIT handoff")` just before the `Assert` at `src/spock_apply.c:4532`. Workload `Always("subscription barrier completes after table resync")`: `sync_event` + `wait_for_sync_event` for that subscription completes within `apply_idle_timeout + restart_delay + margin` after faults stop. Workload `Sometimes("table resync under faults reached ready or visible failure")`. |
| **Antithesis Angle** | Partition the provider or restart it during table resync catch-up (sync workers in CATCHUP run `apply_work`, so any disconnect is an error exit). The crashed slot keeps `worker_type=SYNC` (`src/spock_worker.c:451-468`), `spock_sync_find` ignores `terminated_at` (`:560-578`), and the apply worker loops on a 60 s wait with no way out except unrelated slot reuse. Sync gone at SYNCWAIT trips a cassert `Assert` -> whole-node crash-restart. |
| **Why It Matters** | The stuck apply worker reads nothing, so the **entire subscription** stops while `sub_show_status` says `replicating`. Non-cassert SYNCWAIT path leads to FAILED tables that apply skips silently. |

Confidence: high (mechanism); medium (that the v1 workload does table resyncs)
Evidence file: properties/apply-never-waits-on-dead-sync-worker.md

**Open Questions:**

- Is there any other path that clears a crashed SYNC slot? `(partial: manager lists only apply workers; none found)`
- What is the intended recovery for a sync worker that dies in CATCHUP, and for FAILED tables? `(needs human input)`

### add-node-pause-held-until-progress-read — add_node's provider pause is still in force when peer progress is read

| | |
|---|---|
| **Type** | Safety |
| **Property** | Between `pause_apply_workers` and `resume_apply_workers` on the add_node source provider, no apply worker on that provider resumes, so the peer resume LSNs captured for the new node match the COPY snapshot. |
| **Invariant** | Suggested SUT-side (missing): in `spock_resume_apply_workers`, `Always(pause_apply == 1, "add_node pause still in effect when progress capture resumes workers")`. Its only caller is `spock_create_slot_and_read_progress` (`src/spock_sync.c:852`), right after the progress read, so a 0 flag means a worker timeout or another caller ended the pause early. `Always` matches the function's own contract comment (`src/spock_functions.c:4050-4058`). Suggested `Sometimes("add_node progress capture overlapped in-flight apply work on provider")` when the first pause scan found a worker mid-transaction. Workload companion: after a successful add_node, n4 holds every committed ledger row. |
| **Antithesis Angle** | Each paused worker self-resumes after `spock.pause_timeout` (10 s) and clears the instance-wide flag for everyone (`src/spock_apply.c:565-586`), while `CREATE_REPLICATION_SLOT` may still be waiting on running transactions. Process pause on the provider or a long workload transaction on it during add_node stretches slot creation; writes from other peers give provider apply workers something to commit in the gap. The pause scan reads worker fields without `SpockCtx->lock`, and xid-less in-transaction workers count as paused (thread pausing). |
| **Why It Matters** | A provider apply commit after the slot snapshot but before the progress read is in neither the COPY nor any stream the new node will receive: silent permanent loss on the new node, no exception row. Five past fixes in this class (dcbba6bb, b7fc7022, f38da44a, a9bc8652, 986ad069). |

Confidence: high (mechanism, seven focuses agree on L4); medium (exact flag-level contract)
Evidence file: properties/add-node-pause-held-until-progress-read.md

**Open Questions:**

- Is the worker-side self-resume meant to override a capture that is still running? `(needs human input)`
- Does the snapshot builder's wait cover the xid-less window, or can such a worker commit after the consistent point?
- Overlapping captures against one provider are not reachable in the v1 topology (one spare node).

## Category: Shared files written by several processes

### resource-dat-dumps-serialized — resource.dat is written by one process at a time

| | |
|---|---|
| **Type** | Safety |
| **Property** | `spock_group_resource_dump` never runs in two processes at once, so `resource.dat` is never renamed while half written and a dump never fails after its COPY committed. |
| **Invariant** | Suggested SUT-side (missing): atomic "dumpers inside" counter; `Always(count_after_increment == 1, "resource.dat dump has a single writer")`. `Unreachable("resource.dat temp rename failed")` at `src/spock_group.c:606`. `Unreachable("resource.dat short read at startup")` in `spock_group_resource_load`. Restartability (`Always` node comes back after kill) is shared with the V7 property. |
| **Antithesis Angle** | One fixed temp name with `O_TRUNC`, lock held only SHARED (`src/spock_group.c:534-611`). Callers: supervisor exit, every COPY finish (`src/spock_sync.c:1309`), add_node force-set (`:1736`). Two table resyncs on one node finishing together, or shutdown during a resync, give two writers; node termination right after turns a short file into a postmaster that will not start (`read_buf` ERROR in `shmem_startup_hook`). |
| **Why It Matters** | Node cannot restart without manual file removal; or a successful sync errors at the end, drops its slot/origin and leaves the table FAILED or the subscription disabled. No CRC on the file. |

Confidence: medium (race confirmed in code; needs a workload with concurrent resyncs, not in the default add_node path)
Evidence file: properties/resource-dat-dumps-serialized.md

**Open Questions:**

- Is `resource.dat` monitoring-only or crash-durable dedupe state? `(needs human input)`
- How often do two table syncs on one node finish close enough to overlap?

---

## Areas examined

- `src/spock_apply.c`: `maybe_pause_for_slot_creation` (565-586), `begin_replication_step` (600-631), `handle_commit` pause point (1186), `apply_work` PG_CATCH classifier (3867-4133), `prepare_transient_error_retry` (443-456), `process_syncing_tables` SYNCWAIT/CATCHUP/READY (4456-4635).
- `src/spock_apply_heap.c`: `spock_apply_heap_insert` (837-930), update conflict path (731-745).
- `src/spock_common.c`: `SpockRelationFindReplTupleByIndex` dirty-snapshot wait and `goto retry` (334-480); `read_buf` (604-640).
- `src/spock_functions.c`: `spock_drop_subscription` (762-860), `spock_alter_subscription_resynchronize_table` (1271-1340), `spock_alter_subscription_synchronize` (1162-1232), `spock_pause_apply_workers` / `spock_resume_apply_workers` (4060-4145).
- `src/spock_sync.c`: `spock_create_slot_and_read_progress` (650-866), sync start / FAILED path (1840-1930), `drop_*_sync_status` (2146, 2331, 2366), `set_table_sync_status` (2572), `wait_for_sync_status_change` (2639-2693), `spock_sync_main` slot naming.
- `src/spock_worker.c`: `find_empty_worker_slot` (101-117), `spock_worker_register` (130-200), `wait_for_worker_startup` (217-300), `spock_worker_detach` (410-480), `spock_sync_find` (560-578), `spock_worker_kill` (666-676), `signal_worker_xact_callback` (679), `spock_subscription_changed` (763), `handle_stats_counter` (930-960).
- `src/spock_manager.c`: `manage_apply_workers` (41-180).
- `src/spock_group.c`: `spock_group_resource_dump` (534-611), `spock_group_resource_load` (621-704), `progress_update_list` / `force_set_list` (714-823).
- `src/spock_shmem.c` lock tranche names (119, 156).
- `sql/spock--6.0.0.sql`: `read_peer_progress` (127-200), exception_log schema (54-73); grep of `samples/`, `sql/`, `tests/tap/t` for pause/resume callers.
- Considered and not turned into properties here: slot-group `nattached` unlocked decrement and `free_group` NULL (L10; workload avoids `_<digit>` names, other focuses cover it); apply and sync workers sharing one exception-log slot by subscription name (L15; the apply worker is blocked in `wait_for_sync_status_change` while the sync worker is in CATCHUP, so they rarely overlap); global pause across databases (needs 2+ DBs, out of v1); supervisor `subscriptions_changed` without latch (180 s fallback, liveness only).

## Assumptions affecting multiple properties

- PG `simple_heap_update` / `CatalogTupleUpdate` waits on an in-progress updater's or deleter's xid before failing, and `XACT_EVENT_COMMIT` callbacks run before row locks are released (sub-drop-vs-table-sync-no-deadlock).
- PG's unique check at index insert waits for a concurrent inserter and then raises 23505 when it commits (insert-race-resolved-not-discarded).
- SIGKILL of any Spock worker crash-restarts the whole postmaster and wipes the worker table, pause flag and exception slots; so slot-reuse and handoff races need **graceful/ERROR exits** (network partitions, provider restarts) rather than process kills (manager-kill-targets-only-listed-worker, apply-never-waits-on-dead-sync-worker).
- The Antithesis build is cassert, so the SYNCWAIT `Assert` becomes a node-wide crash.
- The workload will include an admin-churn phase (table resyncs, sub drop and re-create, sub disable/enable) during writes. Without it, sub-drop-vs-table-sync-no-deadlock, manager-kill-targets-only-listed-worker, apply-never-waits-on-dead-sync-worker and resource-dat-dumps-serialized are not reached in v1.
- Convergence companions assume tables stay inside sut-analysis §12 boundaries: PK as the only unique index, no deletes on checked tables, no cross-node update-after-insert, `transdiscard` or `sub_disable` (never `discard`), READ COMMITTED default isolation, and no clock faults on tables whose winner depends on equal timestamps (L2).
- One database per instance.
