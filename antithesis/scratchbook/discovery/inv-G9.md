# Investigation summary: group G9

PG18 source used: `~/dev/pgedge/postgresql` (REL_18_STABLE). Reading only; nothing was built or run.

## exception-log-slots-never-exhausted
- resolved: a transaction is never open at `handle_begin`, so the node-wide hang (lock kept, then waiting on itself) is real by code reading; memory just before `spock_exception_log` is `spock_context` (tail of `SpockCtx->workers[]`): the index -1 write is about 70-100 bytes of message plus 4 bytes, most likely landing in unused worker slots; reusing a name after `sub_drop` cannot pick up a stale replay (LSNs cannot match).
- remaining:
  - Apply and sync workers of one subscription share one entry; does overwriting/clearing each other's `commit_lsn` break restart classification? `(partial: overwrite and clear confirmed in code; effect on the classifier not traced)`
- property changed?: yes. New defect: the locked rescan raises "no free slot" when it finds its own name (the ERROR check runs before `slot_found` is used), so apply and sync workers racing on their first BEGIN hang the node even below capacity. Added `Unreachable` for the race (separate message), plus `AlwaysOrUnreachable(!LWLockHeldByMe(SpockCtx->lock))` at the end of PG_CATCH. Corrected the out-of-bounds write size. The invariant is unchanged.
- invalidated?: no

## progress-hash-capacity-survives-node-churn
- resolved: no hook removes `SpockGroupHash` entries (no HASH_REMOVE; drop_node/sub_drop don't touch it).
- remaining:
  - Is never-delete (for pointer stability) meant to also accept growth with node churn, and is the fix delete-when-`nattached`=0 or bigger sizing? `(needs human input)`
- property changed?: yes. Found a fifth `HASH_ENTER` site with the same dead NULL check (`spock_progress_recovery.c:173`, reconcile at apply-worker start). Added it to the code-path list and to assertion 1 ("...full at apply reconcile").
- invalidated?: no

## replication-origin-states-do-not-leak
- resolved: the sizing docs say origins = `max_replication_slots`, counting no redo-created or orphaned states, so the leak goes against the documented sizing.
- remaining:
  - Commit records stamped with the node id are deliberate (conflict detection uses them). Is the resulting persistent node-id origin state after crash redo accepted? `(needs human input)`
  - Should `spock_sync_worker_cleanup` drop the table-sync origin by name whatever the session state is (no reason found to keep it)? `(needs human input)`
- property changed?: yes (wording only). Path 2 is wider: an ERROR during COPY also skips the origin drop. Path 3 detail: the manager kills only APPLY workers, so after `sub_drop` the sync worker fails at its next status write and leaves its origin and slot. In SYNCWAIT, `Assert(lsn == status_lsn)` (`spock_sync.c:2042`) fails in assert builds and crash-restarts the node. Side note: if a node id equals a real roident, redo would advance the wrong origin.
- invalidated?: no

## no-orphan-slot-pins-wal-after-quiesce
- resolved: leaving the table-sync slot behind on `sub_drop` goes against the docs ("removes all associated metadata"), so it is a defect and is not an expected leftover. The project's stance is unlimited WAL retention: the upgrade test requires `max_slot_wal_keep_size = -1`, so the harm is a full disk.
- remaining: none
- property changed?: yes (wording only). Check 1 must not treat table-sync slots of dropped subscriptions as expected. Spelled out the slot outcome for each sync phase.
- invalidated?: no

## replay-spill-file-lifecycle
- resolved: retrying 53100/53400 for ever is intended (stated in the class 53 code comment), which leaves a doc gap and a stale release note. A live worker cannot keep a spill file past its transaction (every way out of the loop ends the process or replays the same transaction; every handled COMMIT resets the queue). `backend_type` is `spock apply …` / `spock sync …`.
- remaining: none
- property changed?: yes (wording only). The lifetime concern is narrowed. The quiesce query now also covers `spock sync%`.
- invalidated?: no

## spock-connections-match-subscriptions-after-quiesce
- resolved: listed every suffix (`create`, `cleanup`, `sync`, `snap`, `copy`, `copy_slot`, `catchup`; the apply stream uses the slot name with no suffix).
- remaining:
  - Is a PGconn leaked in the calling session by a failed `sub_create`/`sub_alter_sync`/`sub_drop` a bug? `(needs human input)`
- property changed?: yes. Check 2 now closes the workload's admin sessions before it runs, matches on the suffix only, and includes walsenders. Leak triggers are confirmed: "not a spock node" on a healthy connection, and "remote slot drop failed" while the slot is still active (this also orphans the slot).
- invalidated?: no

## apply-worker-memory-bounded
- resolved: none fully
- remaining:
  - Is the sync-standby hold list (a failover-safety feature, #491) meant to grow with no limit while the standby is down? `(needs human input)`
  - What memory bound would the team accept for an apply worker? `(partial: TAP 022 accepts TopTransactionContext < 5 MB during exception replay and RSS growth < 500 MB, noting a legitimate ~270 MB RSS peak; no in-process bound is stated)`
- property changed?: yes (wording only). Feedback walks the list per keepalive or batch, not per message. About 64 B per entry, so about 4M transactions to reach 256 MB. The RSS check needs a small `shared_buffers`.
- invalidated?: no
