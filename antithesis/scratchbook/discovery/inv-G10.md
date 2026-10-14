# Investigation summary: group G10

## exception-log-matches-discarded-transactions
- resolved: remote_xid is the plain 32-bit xid (compare with `txid_current() & 0xffffffff`); missing-relation rows have `table_schema = ''`, `table_name = ''`, NULL tuples, message "Spock can't find relation".
- remaining: none
- property changed?: yes — invariant 3 must group a replay by `(remote_origin, remote_commit_ts, xmin)`, not `retry_errored_at` (that column is a per-row `GetCurrentTimestamp()`); check 1 accepts empty schema/table for the missing-relation message; zero root-cause rows ("root cause not captured") gets its own message.
- invalidated?: no

## insert-conflict-recorded-in-resolutions
- resolved: not recording update_origin_differs/KeepLocal is intended (commit 3bb8ad84 says so; `docs/configuring.md:506-510` wording is stale); `spock.resolutions` is never replicated (`spock` schema is reserved with `block_in_repset = true`).
- remaining: none
- property changed?: no (scope stays insert_exists; keep the `node_name` filter as a guard)
- invalidated?: no

## resolutions-rows-match-applied-outcome
- resolved: KeepLocal UPDATE not persisted is intended (3bb8ad84), so the earlier `(needs human input)` is dropped; delta-apply tables are excluded from check 2 only. The resolution row is written before the delta override, so checks 1, 3 and 4 still apply to delta tables.
- remaining: none
- property changed?: yes — scope note: check 2 runs on non-delta tables only; checks 1, 3 and 4 may include delta tables.
- invalidated?: no

## mixed-version-add-node-loses-nothing
- resolved: the 5.x pause code is the same as HEAD's (dcbba6bb was backported as 2503b2c1 and is in v5.0.11; the earlier "not on v5_STABLE" note was wrong because the ancestor check misses cherry-picks), so the L4 holes are shared; in-core attach_node is not on HEAD (out of scope).
- remaining:
  - Is adding a node supported while some existing node runs the 6.0 binary with a 5.x catalog (before its ALTER EXTENSION UPDATE finishes)? `(needs human input)`
- property changed?: yes — prose: a loss through the pause window is a shared-design bug, not a 5.x-only one.
- invalidated?: no

## mixed-version-mesh-applies-exactly-once
- resolved: PG patch compatibility. PG15-17: one PG build serves both versions. PG18: 5.0.11's spock.so needs patch 035's exported `check_simple_rowfilter_expr` (dlopen RTLD_NOW), so build PG18 with v5_STABLE's patch set. 035 changes no behaviour, so there is no row-filter difference to avoid. Also corrected the list of which 6.0 fixes 5.0.11 lacks: pause, sync_event and tiebreak are backported; the progress redesign, 401197ab and 986ad069 are not.
- remaining:
  - Must 5.0.9/5.0.10 be covered in mixed runs (zodan floor is 5.0.9 with the old tiebreak; an in-place upgrade needs 5.0.11)? `(needs human input)`
  - Are 5.0.x-only weaknesses (progress table and its crash handling, no 401197ab/986ad069) accepted during an upgrade, so failures on 5.0.x-subscriber links are filtered? `(needs human input)`
- property changed?: yes — prose/setup: PG18 build requirement; corrected backport list.
- invalidated?: no

## rolling-upgrade-node-restart-loses-nothing
- resolved: ALTER EXTENSION can wait without limit on locks for `spock.progress`/`lag_tracker`/`resolutions` (no lock_timeout), which only delays the upgraded node's apply start; a swap without a PG rebuild works on PG15-17, and on PG18 when PG is built with v5_STABLE's patch set (not verified by building).
- remaining:
  - Is the "6.0 binary, 5.x catalog" window meant to serve walsenders and peer SQL, or should they refuse until the catalog is updated? `(needs human input)`
- property changed?: yes — the liveness bound N for `Sometimes(extversion = 6.0.0 within N s)` must allow for lock waits, or the workload must avoid long readers of `spock.progress` during the swap.
- invalidated?: no

## cross-pg-major-links-replicate-identically
- resolved: cross-major is a transition state only (`docs/limitations.md`: not a design target; old-to-new is safer); `force_text_transfer` runs exactly the same Spock text path (both make `decide_datum_transfer` return 't').
- remaining: none
- property changed?: yes — scope: new-to-old links may reject values by design; restrict equality to old-to-new links, or to types and values both majors accept. Recommendation stands: use a `force_text_transfer` subscription instead of a mixed-major build.
- invalidated?: no
