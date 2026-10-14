# Open-question investigation, group G7 (HEAD 69d9228f, code read, not run)

PG core checked against the local PG 17 tree (`~/dev/pg/postgresql`, REL_17_STABLE); no PG 18 tree found. No Spock patch touches `origin.c`.

## initial-sync-ends-ready-or-visibly-disabled
- resolved: operator recovery after nonrecoverable disable = drop + recreate (errhint; `sub_enable` just re-disables because status stays s/d/c); pg_dump bound: COPY has keepalives (~25 s), pg_dump gets only the user DSN (no keepalives/connect_timeout) and runs under blocking `waitpid` that SIGTERM cannot break, so a provider that dies unseen during a partition hangs n4 in status `s` for minutes to hours (OS TCP defaults).
- remaining: none
- property changed?: yes — prose refinement: pg_dump hang is now an expected way for the Always to fire (finding: pg_dump should get spock_connect's keepalive/connect_timeout options); workload must drop+recreate after outcome (b), not just re-enable.
- invalidated?: no

## sub-drop-vs-table-sync-no-deadlock
- resolved: nothing serialises drop vs SYNCWAIT (no conflicting locks); window is the whole drop transaction (MVCC catalog scans keep seeing the deleted `w` row; drop's 1 s wait loop re-takes SpockCtx->lock); sub_alter_sync route confirmed (PG CommitTransaction runs COMMIT callbacks before releasing xid lock); third route confirmed (SIGTERM only sets a flag).
- remaining:
  - Is `sub_drop` (or `sub_alter_sync`) during an active table sync a supported operation? Docs do not forbid it. `(needs human input)`
- property changed?: no (precondition added: the sync worker's `w` write must commit before the drop's DELETE)
- invalidated?: no

## apply-never-waits-on-dead-sync-worker
- resolved: no path clears a crashed SYNC slot except same-DB reuse (lowest free slot first) or a SIGTERM to the apply worker (disable/alter/drop/terminate turns the wait into an ERROR, table then goes FAILED); intended recovery for FAILED is operator resync (regression test `sync_table` test_sync_fail); resync refuses tables in i/p/d/w/u; FAILED shows as `unknown` in sub_show_table; truncate question: `truncate := false` always fails on a populated PK table (plain COPY), so workload must use default `truncate := true`.
- remaining:
  - Is a FAILED table that apply silently skips (no exception_log row, shown as `unknown`) acceptable as long as `table_wait_for_sync` reports it? `(needs human input)`
- property changed?: yes — workload guidance corrected (use `truncate := true`; previous `false` advice was wrong); second trigger added (SIGTERM to a sync worker in catch-up → `proc_exit(1)` → same stall).
- invalidated?: no

## manager-kill-targets-only-listed-worker
- resolved: SIGTERM to a sync worker mid-COPY is ignored until COPY ends; it then skips the CATCHUP wait (returns false, lsn invalid): cassert → `Assert(lsn == status_lsn)` aborts → node crash-restart; non-cassert → normally marks SYNCDONE at status_lsn with no catch-up → silent drift for that table while it shows `replicating`; or (if apply already moved replay_stop_lsn) error exit → apply stall. Same-process variant reachable (error-exited slot of a just-disabled sub reused for another sub in the same pass) but only causes a restart blip.
- remaining: none
- property changed?: yes — priority suggestion up: cross-process variant can cause silent data drift, not just a FAILED table. Suggest an extra SUT assertion `Unreachable("sync worker skipped catch-up after SIGTERM")` in `spock_sync_main`; the SIGTERM-ignoring sync worker may deserve its own property.
- invalidated?: no

## resource-dat-dumps-serialized
- resolved: resource.dat is a startup seed (design spec + spock_group.c header): origins are authoritative, file absent/mismatch is tolerated; so the startup ERROR on a short file (becomes FATAL in postmaster) is a bug either way. Also found: interleaved writers can produce duplicate keys → `Assert(!ret)` at load aborts a cassert postmaster; rename failure during add_node initial sync leaves status `d` → subscription disabled; supervisor shutdown drains workers up to 5 s before dumping (overlap narrowed, not removed).
- remaining:
  - How often do two dumps on one node overlap? One sync worker per subscription, so overlap needs concurrent resyncs on different subscriptions of one node. `(partial: reachable by design with two concurrent resyncs on different subscriptions of one node; frequency unmeasured)`
- property changed?: no (prose refinement: consequences listed above)
- invalidated?: no

## enabled-subscription-always-has-provider-slot
- resolved: no monitoring reports a missing slot; START_REPLICATION failure is a plain ERROR outside PG_TRY (no exception_log row); sub_show_status alternates `replicating`/`down` (corrected from "initializing").
- remaining:
  - Is dropping the remote slot before the local commit a deliberate trade-off (vs. drop after commit and accept orphan slots)? Order unchanged since the pglogical import, no rationale recorded. `(needs human input)`
- property changed?: no (prose correction on status values)
- invalidated?: no

## provider-slot-owned-by-one-subscription
- resolved: cluster-wide unique names are documented ("Must be unique across the cluster", sub_create docs) but not enforced, and the slot-name mapping (anything outside [a-z0-9_] → `_`) makes documented-valid distinct names collide (`sub_A`/`sub_B`). Slot-group note turned into a test-configuration rule (avoid mapped names ending `_<digit>`), not a question.
- remaining:
  - Should slot names include the subscriber node (or record an owner)? Affects upgrades, origins and four ZODAN `spock_gen_slot_name` call sites. `(needs human input)`
- property changed?: yes — scope refined: the test configuration should use names that obey the docs but collide after mapping (real defect, priority unchanged); identical names on two nodes is the user-error case (should be rejected; lower priority).
- invalidated?: no

## sub-disable-enable-cycle-loses-and-duplicates-nothing
- resolved: replacement worker can start while old one still holds the origin session (PG's `ReplicationOriginExitCleanup` is on_shmem_exit, after Spock frees its slot in before_shmem_exit); the new worker fails at `replorigin_session_setup` before PG_TRY and before any BEGIN, plain ERROR, retried after restart_delay — harmless. `immediate` on sub_enable only forbids a transaction block.
- remaining: none
- property changed?: no
- invalidated?: no
