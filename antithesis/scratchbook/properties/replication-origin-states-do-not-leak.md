# replication-origin-states-do-not-leak

## Summary

PostgreSQL keeps replication-origin progress in a fixed shared array of
`max_active_replication_origins` states (PG18 default **10**, postmaster-only).
States are written to `pg_logical/replorigin_checkpoint` at every checkpoint and
reloaded at startup, so a leaked state survives restarts. When the array is full,
`replorigin_advance` and `replorigin_session_setup` raise
`ERRCODE_CONFIGURATION_LIMIT_EXCEEDED` "could not find free replication state
slot" (`origin.c:975-980` in PG18). Code reading found three Spock paths that
add states nothing removes:

1. **Crash redo creates states numbered by node id** (side effect of L1). Apply
   commits carry `replorigin_session_origin = remote node id`
   (`handle_origin`, `src/spock_apply.c:1332`). On crash recovery,
   `xact_redo_commit` calls `replorigin_advance(origin_id = node id, ...)`
   (PG18 `xact.c:6258`), which takes a free state for that id. No
   `pg_replication_origin` catalog row has that id, so nothing ever drops it.
   These states show up in `pg_replication_origin_status` with
   `external_id IS NULL` (`pg_show_replication_origin_status` leaves the name
   null when `replorigin_by_oid` finds nothing, `origin.c:~1580`). One state per
   distinct remote node id whose commits were replayed; it grows with node churn
   under fresh names.
2. **Table-sync origins leak on the FAILED path.** A table resync creates a local
   origin named `<sub slot>_<8-hex hash of table>` and advances it with
   `wal_log=true` (`src/spock_sync.c:1883-1900`). If the sync worker dies after
   that (COPY or CATCHUP) by ERROR exit, connection loss or crash restart, the
   apply worker starts a new sync worker. That worker sees a status other than
   INIT, marks the table FAILED (`:1851-1866`) and calls
   `spock_sync_worker_finish` -> `spock_sync_worker_cleanup` (`:1429-1468`).
   Cleanup drops the **remote** slot but drops the local origin only
   `if (replorigin_session_origin != InvalidRepOriginId)`, which is not set on
   this path. The same guard also skips the origin drop when the
   `PG_ENSURE_ERROR_CLEANUP` callback runs on an ERROR during COPY
   (`:1888-1913`): the session origin is only set up later, at catch-up
   (`:2045-2050`). So any failure before catch-up leaves the origin. So the origin and its state stay. A later `sub_resync_table`
   reuses the same name, so the leak is bounded per (subscription, table) while
   the subscription lives.
3. **`sub_drop` leaves table-sync origins.** `spock_drop_subscription`
   (`src/spock_functions.c:762-870`) drops only `sub->slot_name`'s origin. It
   does not stop running sync workers or drop their origins. ZODAN `remove_node`
   uses `sub_drop` (`samples/Z0DAN/zodremove.sql:189, 227`), so a resync that was
   interrupted before a remove_node leaves its origin for ever. The manager
   kills only APPLY workers (`spock_apply_find_all`, `src/spock_worker.c:539-554`;
   `src/spock_manager.c:158-175`), so the sync worker keeps running. Its next
   `set_table_sync_status` raises "status not found" (`spock_sync.c:2606-2607`;
   the row was deleted by `drop_subscription_sync_status`) outside any cleanup
   block, so it exits leaving both the origin and its table-sync slot. If the
   drop lands while it waits in SYNCWAIT, `wait_for_sync_status_change` returns
   with `lsn` invalid, and `Assert(lsn == status_lsn)` (`:2042`) fails in an
   assert-enabled build, which crash-restarts the node. Re-adding the
   node under a new name creates new subscription names, so the leak grows.

In the planned topology each node needs 2 to 3 states for its live
subscriptions (plus one temporarily per table resync). With the PG18 default of
10, a few crash restarts with fresh node names, or a few interrupted resyncs
followed by remove_node, can fill the array. Then:

- In the **startup process** during crash recovery, the redo ERROR becomes FATAL
  and the **node will not start** (violates V7, node restartability).
- In an apply worker (`replorigin_session_setup` at start), it is SQLSTATE class
  53, so the worker retries every 5 s for ever. The subscription is stuck, while
  `sub_show_status` still reports it via the worker slot.
- In `sub_create` with a disabled subscription (the ZODAN path creates the origin
  at once), the call fails.

## Property

The number of replication-origin states on each node stays equal to what its
live subscriptions (plus in-flight table syncs) need. Leaked states never pile
up until the "no free replication state slot" error appears.

## Assertions (all missing)

1. Workload-side `Unreachable("replication origin state table full")`: the
   workload (or a log tailer) scans every node's server log for
   `could not find free replication state slot` and
   `could not find free replication state, increase`. Reaching it in any
   process is a failure, and in the startup process it is also a restart
   failure.
2. Workload-side `Always(...)` after quiescence, two separate messages:
   - "no unnamed origin states": `SELECT count(*) FROM
     pg_replication_origin_status WHERE external_id IS NULL` = 0 on every node.
     Fires on path 1 (L1 side effect).
   - "no orphan named origins": every `pg_replication_origin.roname` on a node
     that starts with `spk_` matches a `spock.subscription.sub_slot_name` on
     that node, or a table-sync slot of a table currently in a non-final sync
     state. Fires on paths 2 and 3.

`Always` after quiescence fits (2): with no syncs in flight, any extra state is a
leak. That does not depend on timing. `Unreachable` fits (1) because the error
is the actual harm.

## Fault requirements

- Path 1: SIGKILL of the postmaster or any backend between checkpoints while
  apply commits are flowing (large `checkpoint_timeout` helps), on a node that
  subscribes to peers. Fresh-name node churn makes the count grow.
- Path 2: kill or partition during `sub_resync_table` COPY or catch-up. The
  workload must issue table resyncs.
- Path 3: `remove_node` while a resync is incomplete.
- A config variant that keeps `max_active_replication_origins` near the PG18
  default (10) turns slow growth into the visible failure within one run. The
  current deployment guidance (">= (N-1) * DBs" plus headroom) delays it.

## Synthesis note (2026-10-13)

Kept separate from `crash-redo-leaves-no-node-id-origin-state`. The "no
unnamed origin states" quiescent check listed above is the same check as that
property's `Unreachable` and is owned there; this property keeps the
`Unreachable("replication origin state table full")` log check and the "no
orphan named origins" `Always`, which cover the table-sync FAILED path and the
`sub_drop` / `remove_node` path as well as redo-created states.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (implementability CW7/CW8); see `evaluation/synthesis.md`.

Current catalog line: Priority: P2 · Topology: v1 (capacity part: `v2/small-capacity`) · Faults: node kill between checkpoints, kills/partitions during resync

- Evaluation note (2026-10-13): the log scan reads server logs through `logging_collector` and `pg_read_file`. In the main configuration (`max_active_replication_origins = 32`) the "state table full" message is not expected; the capacity route belongs to `v2/small-capacity`.

## Open questions

- Commit records stamped with the remote node id are deliberate (conflict
  detection reads it back from commit timestamps). Is the resulting persistent
  node-id origin state after crash redo accepted, or should Spock clean it up
  (or avoid it)? `(needs human input)`
- Should `spock_sync_worker_cleanup` drop the table-sync origin by name
  whatever the session state is? No code or doc gives a reason to keep it, and
  a later resync re-creates and resets it anyway. If owners want it kept, the
  orphan check must allow FAILED tables. `(needs human input)`

### Investigation Log

#### Is the L1 behaviour (commit records stamped with the node id) intended to create persistent node-id origin states?

- Examined: `handle_origin` (`src/spock_apply.c:1299-1334`); output plugin
  ORIGIN message (`src/spock_output_plugin.c:598-632`); `get_tuple_origin`
  (`src/spock_conflict.c:219-270`); PG18 `xact_redo_commit`
  (`~/dev/pgedge/postgresql` REL_18_STABLE, `xact.c:6254-6259`) and
  `replorigin_advance` (`origin.c:925-990`), checkpoint/startup load
  (`origin.c:805-825`); pgEdge PG18 patches (`patches/18/*.diff`).
- Found: the provider sends its own node id (`MyOutputNodeId`) for local
  transactions and the forwarded origin id otherwise. The subscriber sets
  `replorigin_session_origin` to it on purpose (comment: PG's roident "has
  nothing to do with the actual origin"). Commit timestamps record this id and
  conflict handling reads it back through `TransactionIdGetCommitTsData`, so
  changing it would break conflict detection; an "L1 fix" that changes
  `replorigin_session_origin` is unlikely. PG18 redo calls
  `replorigin_advance(origin_id, ...)` with no catalog check and takes a free
  state; checkpoints write every state with a valid id, and startup PANICs if
  the file holds more states than `max_active_replication_origins`. The pgEdge
  PG18 patches do not touch this redo path. Side observation: node ids are
  16-bit name hashes and real roidents are small integers, so if a node id
  equals a live subscription's roident, redo advances **that** origin with the
  remote node's LSN (rare; belongs with `crash-redo-leaves-no-node-id-origin-state`).
- Not found: any comment, doc or test that mentions the redo-created states.
- Conclusion: the stamping is intended; the persistent states are an
  undocumented side effect. Whether that is accepted is an owner decision.
  Tagged `(needs human input)`. The property's checks do not change.

#### Should `spock_sync_worker_cleanup` drop the table-sync origin regardless of session state?

- Examined: `spock_sync_worker_cleanup` (`src/spock_sync.c:1427-1468`), the
  FAILED path (`:1840-1866`), COPY-phase cleanup block (`:1878-1913`),
  `spock_sync_main` (`:2002-2090`), `ensure_replication_origin` (`:477`), and
  every `replorigin_drop_by_name` caller (`spock_sync.c:1464`,
  `spock_functions.c:862`).
- Found: the drop is guarded by `replorigin_session_origin != InvalidRepOriginId`
  because it is paired with `replorigin_session_reset()`, which needs a session.
  The session is set only at catch-up, so the FAILED path and every ERROR during
  COPY skip the drop. The FAILED comment says only "mark the status and exit";
  nothing says the origin is kept for later. A later resync reuses the same
  name through `ensure_replication_origin` and resets it with
  `replorigin_advance(..., go_backward=true, ...)` (`:1894-1899`), so keeping it
  buys nothing.
- Not found: an owner statement of intent.
- Conclusion: the code reads like an oversight (the guard protects the session
  reset, not the drop), but intent is an owner call. Tagged
  `(needs human input)`. Recommendation: keep the "no orphan named origins"
  check strict, and report origins of FAILED tables under their own message so
  a hit is easy to classify.

#### What is the intended relationship between `max_active_replication_origins` and the topology?

- Examined: `docs/sizing.md:188-203`, `docs/install_spock.md:138-147`,
  `docs/logical_slot_failover.md:70-73`.
- Found: the docs give one rule: `max_active_replication_origins =
  max_replication_slots` on PG18, and on PG15-17 say the slot formula "should
  make it impossible for there to be more origins than slots". Neither counts
  redo-created node-id states nor orphaned table-sync origins, so the docs
  claim is not true once those exist (on PG15-17 the same states also come out
  of the `max_replication_slots`-sized pool).
- Conclusion: resolved. The intended sizing is one state per slot with no
  allowance for leaked states. That makes the leak a defect against the
  documented sizing (or a doc gap); either way the `Unreachable` on the
  "no free replication state" error stands as written.
