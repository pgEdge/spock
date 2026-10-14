# sync-wait-functions-honor-contract

## Summary

`spock.sub_wait_for_sync(sub)` and `spock.table_wait_for_sync(sub, rel)` are
the SQL API's "is the initial copy / table resync done?" calls. Their only
outcomes are: return normally (done), raise an ERROR (a table with
`stop_on_error` reached FAILED), or keep waiting. Two contract points:

1. **Return means synchronized.** When either returns normally, the copied
   data is present: every row that was committed on the provider before the
   sync started is visible on the subscriber.
2. **No silent wait on a terminal failure.** They must not keep waiting once
   the sync can no longer finish without an operator: the subscription has
   been disabled (initial sync failed in a nonrecoverable step) or a table is
   FAILED.

## Code paths

- `spock_wait_for_sync_complete` `src/spock_functions.c:3462-3561`. Loop every
  200 ms, no timeout:
  - `isdone = subsync->status == SYNC_STATUS_READY`, then for a table:
    ERROR if `stop_on_error && status == FAILED`, else done only on READY
    (`'r'`); for the whole sub: done when `get_unsynced_tables()` is empty,
    ERROR on any FAILED table with `stop_on_error`.
  - Never reads `sub_enabled`; never looks at worker state.
- `stop_on_error` is always true for table sync rows
  (`src/spock_sync.c:2218`).
- Nonrecoverable initial-sync step: `spock_sync_subscription`
  `src/spock_sync.c:1517-1546` disables the subscription and FATALs while the
  sub-level status stays `s`/`d`/`c`. Nothing moves that status afterwards.
- Table sync worker death after INIT leaves `p`/`d`/`w`/`u` until a later sync
  attempt sets FAILED (`src/spock_sync.c:1851-1866`); per lead L12 a sync
  worker that died with an error keeps `worker_type=SYNC` and the apply worker
  waits in `wait_for_sync_status_change` indefinitely, so FAILED may never be
  written.
- ZODAN avoids the C function: "Avoid rare hangs in C-level sub_wait_for_sync
  by using a bounded SQL loop" (`samples/Z0DAN/zodan.sql:2457`, from
  dd0cef7d). That comment is the maintainers' own acknowledgement of hangs.

## Failure scenarios

- Sub created with `synchronize_data := true`; provider partition or provider
  kill during COPY -> sync fails in `d` -> subscription disabled ->
  `sub_wait_for_sync` loops forever (expected non-liveness of the sync itself,
  but the API never reports it).
- `sub_resync_table` while the provider drops the connection in CATCHUP -> L12
  -> `table_wait_for_sync` loops forever while `sub_show_status` says
  `replicating`.
- Return-correctness: READY is written by the apply worker when its stream
  passes the sync worker's `SYNCDONE` LSN (`process_syncing_tables`
  `src/spock_apply.c:4456-4635`). A missing sync-status row is treated as READY
  (`:4487-4494`, [F11]); if that happens, `table_wait_for_sync` could return
  while nothing was copied.

## Invariant

Two workload-side `Always` assertions with distinct messages:

- "sub/table_wait_for_sync returned only after data is present": scenario where
  the workload quiesces writes for table X, calls
  `sub_resync_table(sub, X, truncate := true)` on S (and, if in scope, a fresh
  `sub_create(..., synchronize_data := true)` for n4 outside ZODAN), then
  `table_wait_for_sync`/`sub_wait_for_sync`. On normal return, compare X's
  ledger rows on S with P's at the resync start: every P row present.
- "sync wait reports FAILED table instead of waiting" (narrowed 2026-10-13;
  the disabled-subscription clause was dropped because the docs promise an
  indefinite wait): call with `statement_timeout = T` (T well above the
  expected copy time). If it times out, read `spock.local_sync_status` for
  that sub; assert NOT (sub-level row is `'r'` and the target table, or any
  unsynced table for `sub_wait_for_sync`, is `'f'`).

`Always` fits both: each call is an evaluation that must satisfy the rule.

## Workload boundaries

- Only resync in a quiesced window: resync of one table in a 3-node mesh while
  other nodes write is lossy by design (the subscriber truncates rows that came
  from a third node and will never get them again from P).
- Interrupted syncs ending disabled/FAILED are expected; the property only
  flags the wait functions not reporting it.

## Investigation update (2026-10-13)

- **The disabled-subscription half is outside the documented contract.**
  `docs/spock_functions/functions/spock_sub_wait_for_sync.md` and
  `spock_table_wait_for_sync.md` both say the function "will continue
  waiting indefinitely until synchronization completes, so callers should
  ensure the subscription is actively processing and that there are no
  blocking issues". The code matches (no `sub_enabled` check, no timeout).
  So the second assertion is narrowed: drop the "subscription disabled"
  clause and keep only "a FAILED table row is reported, not waited on".
- **The FAILED check only runs once the subscription-level row is READY.**
  In `spock_wait_for_sync_complete` (`src/spock_functions.c:3462-3561`) both
  the table path and the whole-sub path test `stop_on_error && FAILED` only
  inside `if (isdone)`, i.e. after the subscription's own sync status is
  `r`. The narrowed assertion is therefore: if the sub-level status is `r`
  and the target table (or any unsynced table, for `sub_wait_for_sync`) is
  `f`, the call raises instead of hitting `statement_timeout`. The L12 case
  (sync worker died, status never moves to `f`) is a sync-status bug, not a
  wait-function bug; it belongs to the sync-worker properties.
- **ZODAN never calls the C wait function.** ZODAN creates one subscription
  with `synchronize_data := true` (src -> new node, `samples/Z0DAN/zodan.sql`
  ~:2339-2346) but waits with its own bounded SQL loop (:2457ff), which
  treats `y` (SYNCDONE) as done as well as `r`. So `sub_wait_for_sync` is
  exercised only if the workload calls it, either on its own
  `sub_create(..., synchronize_data := true)` or, after ZODAN finishes, on
  the ZODAN-created src -> new subscription.

Property change: the second `Always` becomes "sync wait raises on a FAILED
table once the subscription row is READY" (message
"sync wait reports FAILED table instead of waiting"). The disabled case
becomes a documentation note, not an assertion.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (implementability CW5); see `evaluation/synthesis.md`.

Current catalog line: Priority: P2 · Topology: v1 (needs admin-churn phase) · Faults: partition / node kill during COPY

- Evaluation note (2026-10-13): resyncs target a dedicated single-writer table (Assumption 5), so a `truncate := true` resync loses nothing and CATCHUP still has work.

## Open questions

- Should the wait functions report a disabled subscription instead of waiting? `(needs human input)` `(partial: docs say they wait indefinitely and the caller must ensure the subscription is processing; assertion dropped from the property)`

### Investigation Log

#### Is `sub_wait_for_sync` meant to raise when the subscription has been disabled?

- Examined: `src/spock_functions.c:3455-3561`;
  `docs/spock_functions/functions/spock_sub_wait_for_sync.md`,
  `spock_table_wait_for_sync.md`.
- Found: docs promise an indefinite wait and put liveness on the caller;
  FAILED is checked only after the sub-level status is READY.
- Not found: any doc promising an error on a disabled subscription.
- Conclusion: documented as "waits"; disabled clause removed, FAILED clause
  kept and narrowed. A design question remains for the team.

#### Will the workload call `sub_create(..., synchronize_data := true)` outside ZODAN?

- Examined: `samples/Z0DAN/zodan.sql` sub creation (:2339-2350) and Phase 7
  wait loop (:2450-2485).
- Found: ZODAN uses `synchronize_data := true` for src -> new and avoids the
  C wait ("Avoid rare hangs in C-level sub_wait_for_sync").
- Conclusion: workload design choice, not a SUT question. The sub-level half
  is reachable by calling `sub_wait_for_sync` on the ZODAN-created
  subscription after add_node, or via `sub_resync_table`; no own
  `sub_create` needed. Resolved for the catalog.
