# sub-drop-vs-table-sync-no-deadlock

## What led here

Concurrency focus F1 (`discovery/03-concurrency.md`), sut-analysis lead L11 and
Open Question 12. Re-read at HEAD 69d9228f for this property. Not run.

## Code path

Apply worker side, `process_syncing_tables` (`src/spock_apply.c:4456-4635`),
SYNCWAIT branch at `:4515-4566`:

```
LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE);          /* :4519 */
worker = spock_sync_find(...);
Assert(spock_worker_running(worker));                  /* :4532 */
if (running && origin_lsn >= replay_stop_lsn) {
    StartTransactionCommand();
    set_table_sync_status(..., SYNC_STATUS_CATCHUP,..);/* catalog UPDATE */
    CommitTransactionCommand();
    ...
    LWLockRelease(SpockCtx->lock);
```

`set_table_sync_status` (`src/spock_sync.c:2572`) does `CatalogTupleUpdate` on
`spock.local_sync_status`, i.e. `simple_heap_update`, which waits on the xid of
any uncommitted transaction that already updated or deleted that row. That wait
happens while holding the instance-wide `SpockCtx->lock` EXCLUSIVE.

Other side, `spock_drop_subscription` (`src/spock_functions.c:762-860`):

1. `drop_subscription_sync_status(sub->id)` (`:779`;
   `src/spock_sync.c:2146-2173`) deletes all sync-status rows of the
   subscription. Uncommitted.
2. ... `LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE)` to find and SIGTERM the
   apply worker (`:808`).

Cycle: apply holds `SpockCtx->lock`, waits on drop's xid; drop waits on
`SpockCtx->lock`. An LWLock wait cannot be cancelled and is invisible to the
deadlock detector. Both processes hang for ever.

Second route with the same shape: `spock_alter_subscription_synchronize`
(`src/spock_functions.c:1162-1232`) deletes a table's sync row
(`drop_table_sync_status_for_sub`, `:1226`) and calls
`spock_subscription_changed` (`:1232`). At COMMIT
`signal_worker_xact_callback` (`src/spock_worker.c:679`) takes
`SpockCtx->lock`; `XACT_EVENT_COMMIT` callbacks run before the transaction's
row locks are released (standard PG ordering in `CommitTransaction`). Same
cycle.

Third route without the LWLock (cancellable, but still a hang):
after the SYNCWAIT branch, the SYNCDONE -> READY update (`:4570-4585`) also
calls `set_table_sync_status`. If `sub_drop` has already deleted that row, the
apply worker waits on drop's xid (heavyweight lock wait; Spock's SIGTERM
handler only sets a flag, so the wait is not interrupted), while `sub_drop`
loops waiting for the apply worker to exit (`:813-834`, 1 s `WaitLatch`). The
deadlock detector does not see a latch loop. The user can cancel `sub_drop`;
nothing else breaks it.

## Blast radius of the LWLock variant

Everything that takes `SpockCtx->lock` piles up behind it:

- every applied row on every apply worker of the instance
  (`handle_stats_counter`, `src/spock_worker.c:930-960`, SHARED, while
  `spock.channel_counters=on`, the default) -> all inbound replication on that
  node stops;
- manager loop, worker attach/detach (`spock_worker_detach` runs in
  `before_shmem_exit`, `:423`), so fast shutdown hangs too;
- `wait_for_sync_status_change`, `sub_show_status`, pause/resume scans.

So a single admin call at the wrong moment freezes the node's Spock layer until
a postmaster crash-restart.

## Reaching it

The SYNCWAIT branch runs only when a per-table sync worker finishes COPY:
`sub_resync_table`, `sub_alter_sync`, `sub_add_repset` with sync, or a
subscription created with `synchronize_data` and several tables. The workload
must therefore:

- start a table resync on a subscription (e.g. on n1 for the sub from n2), and
- while it runs, call `sub_drop` on that subscription (or `sub_alter_sync`), or
  run ZODAN `remove_node` that drops it.

ZODAN add_node alone does not reach it: the new node's initial sync copies in
the apply worker itself, not via per-table sync workers (`spock_sync_subscription`).

## Invariant

- Workload-side `Always("sub_drop returns within bound during table sync")`:
  every `spock.sub_drop` / `spock.sub_alter_sync` call the workload issues
  returns (success or error) within N seconds (N about 60 s plus fault time).
  Use client-side `statement_timeout`-free calls with a client timer, so the
  check measures the server, not a client timeout.
- Workload-side `Always("no backend waits on spock context lock beyond bound")`:
  a sampler on each node reads `pg_stat_activity` every few seconds; no pid
  shows `wait_event_type='LWLock' AND wait_event='spock context lock'` in two
  samples more than 30 s apart with no state change. `Always` because any
  long LWLock wait is the deadlock (LWLock hold times are meant to be short).
- Suggested SUT-side assertion (**missing**): `Reachable("apply SYNCWAIT catalog
  update under SpockCtx lock")` just before the `set_table_sync_status` call at
  `src/spock_apply.c:~4538`, so the run report shows whether the dangerous
  window is being explored at all.

## Fault / timing requirements

- No injected faults needed. Thread pausing / CPU modulation widens the window.
  `SPOCK_RANDOM_DELAYS` builds also widen attach/detach timing.
- Workload: admin churn (resync + drop/re-create of a subscription) while
  writes flow. The dropped subscription must be re-created afterwards so the
  mesh stays complete for other properties.

## Findings from open-question investigation (HEAD 69d9228f, code read, not run)

- **Nothing serialises them.** `spock_drop_subscription`
  (`src/spock_functions.c:762-858`) takes `ShareUpdateExclusiveLock` on
  `spock.local_node` (`get_local_node(true,false)`) and `RowExclusiveLock` on
  the sync-status table. The apply worker's `process_syncing_tables` touches
  neither `spock.local_node` nor `spock.subscription` in a conflicting mode;
  its catalog work is `RowExclusiveLock` on sync status, which is compatible.
- **The window is wide, not a single read-to-update gap.** All sync-status
  reads (`get_table_sync_status`, `set_table_sync_status`) use
  `systable_beginscan(..., NULL snapshot)`, i.e. an MVCC catalog snapshot.
  The drop's DELETE is uncommitted, so the apply worker still sees the row as
  `w` and still takes the SYNCWAIT branch for as long as the drop has not
  committed. `CatalogTupleUpdate` -> `heap_update` then finds the row's xmax
  in progress and waits on the drop's xid (`src/spock_sync.c:2572-2626`). So
  any SYNCWAIT pass that starts after the drop's DELETE and before its COMMIT
  enters the cycle. Precondition: the sync worker's own `w` write must be
  committed before the DELETE; if not, the sync worker itself blocks on the
  drop's xid in `spock_sync_main` (it holds no LWLock there), and the hang is
  of the cancellable kind.
- **The drop also re-takes the LWLock in its wait loop.** After the kill,
  `sub_drop` loops `LWLockAcquire(SpockCtx->lock)` once per second
  (`:813-834`). So even if the apply worker's UPDATE starts after the drop
  passed the kill step, the next loop iteration blocks on the LWLock that the
  apply worker holds while waiting on the drop's xid. The uncancellable
  variant covers the whole drop call, not only the stretch before `:808`.
- **The `sub_alter_sync` route is confirmed against PG source.** In
  `CommitTransaction` (PG 17 `xact.c`), `CallXactCallbacks(XACT_EVENT_COMMIT)`
  runs before `ResourceOwnerRelease(..., RESOURCE_RELEASE_LOCKS)`, and
  `XactLockTableWait` waits on the xid lock, which is only released there. So
  the apply worker is still waiting when `signal_worker_xact_callback`
  (`src/spock_worker.c:679-735`) asks for `SpockCtx->lock`. Its ABORT branch
  takes the same LWLock, so cancelling does not help either.
- **Third route confirmed.** Spock's SIGTERM handler only sets a flag and the
  latch (`src/spock_worker.c:83-93`); a heavyweight lock wait is not ended by
  it. The deadlock detector sees only the apply worker waiting; the drop is in
  a latch loop. Cancelling `sub_drop` breaks it.
- **Docs place no limit.** `docs/spock_functions/functions/spock_sub_drop.md`
  and `spock_sub_resync_table.md` say nothing about dropping during a resync.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (implementability CW5 and property finding); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 (admin-churn phase) · Faults: admin churn, thread pause

- Evaluation note (2026-10-13): use a throwaway subscription with a dedicated table (dropping a mesh subscription during SYNCWAIT breaks the shared oracles) and loop resync-then-drop many times per timeline; no `SPOCK_RANDOM_DELAYS` site sits in the window. The sampler's wait event name `spock context lock` is confirmed (`src/spock_shmem.c:119`).

## Open questions

- Is `sub_drop` (or `sub_alter_sync`) during an active table sync a supported
  operation? The docs do not forbid it, so as written it is a hang bug; only
  the team can say whether it should instead be a documented "don't".
  `(needs human input)`

### Investigation Log

#### Does anything serialise sub_drop against SYNCWAIT handling?

- Examined: `spock_drop_subscription` (`src/spock_functions.c:762-860`),
  `process_syncing_tables` (`src/spock_apply.c:4456-4635`),
  `set_table_sync_status` / `drop_subscription_sync_status`
  (`src/spock_sync.c:2146, 2572`), `get_local_node` lock use
  (`src/spock_node.c:721`).
- Found: drop takes `ShareUpdateExclusiveLock` on `spock.local_node` via
  `get_local_node(true,...)` and `RowExclusiveLock` on sync status; apply's
  SYNCWAIT branch takes only `RowExclusiveLock` on sync status (compatible)
  and then waits on the row's xid.
- Not found: any lock or flag that keeps the two apart.
- Conclusion: `(partial: no serialising lock found in code; not run)`.

  Update after full read: drop and apply share no conflicting lock; the
  uncommitted DELETE stays invisible to the apply worker's MVCC catalog scan,
  so it keeps taking the SYNCWAIT branch; drop's wait loop re-takes the LWLock
  every second. Conclusion: resolved, nothing serialises them (code-checked;
  not run).

#### Can the apply worker's earlier read skip the branch after the drop deletes the row?

- Examined: `get_table_sync_status` / `set_table_sync_status` scans
  (`src/spock_sync.c:2407-2626`), `process_syncing_tables` order
  (`src/spock_apply.c:4474-4566`), sync worker's SYNCWAIT write
  (`src/spock_sync.c:2033-2037`).
- Found: scans use an MVCC catalog snapshot, so an uncommitted delete is
  invisible; the branch is skipped only if the drop already committed, which
  in the deadlock case it never does.
- Not found: any recheck of the row between the read and the UPDATE.
- Conclusion: the window is the whole drop transaction, provided the `w` row
  was committed before the DELETE. Resolved.

#### Is sub_drop during an active table sync supported?

- Examined: `docs/spock_functions/functions/spock_sub_drop.md`,
  `spock_sub_resync_table.md`, `sub_mgmt.md`, `docs/troubleshooting.md`.
- Found: no restriction documented.
- Not found: any guard in `spock_drop_subscription` against syncing tables.
- Conclusion: `(needs human input)` on intent; code-wise it hangs.
