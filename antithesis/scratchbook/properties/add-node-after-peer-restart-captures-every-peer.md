# add-node-after-peer-restart-captures-every-peer

## Why this property

Lifecycle angle on the add_node catch-up path: what the source node knows
about its peers right after it restarts.

During initial sync of `src -> new`, the new node's sync calls
`spock.read_peer_progress()` **on the source** under the copy snapshot
(`src/spock_sync.c:~650-866`, `sql/spock--6.0.0.sql:127-200`). The function
returns one row per peer subscription on the source, built with an **inner
join** on `spock.progress` (shmem `SpockGroupHash`). Rows are force-set into
the new node's `spock.progress`; ZODAN Phase 7
(`samples/Z0DAN/zodan.sql:2625-2680`) reads them to advance each peer X's
slot `X -> new`. If a peer is missing it logs
`RAISE NOTICE '    WARNING: No spock.progress entry for %, falling back to pg_current_wal_lsn()'`
and advances X's slot to X's **current** WAL end. Any X transaction the
source had not applied at snapshot time is then never sent to the new node:
silent loss on the new node.

When is a (source, X) entry missing? `SpockGroupHash` lives in shared memory.
It is filled by:

- `spock_group_resource_load` at shmem startup, from `resource.dat`, which is
  written only at clean shutdown, add_node force-set and table-sync COPY
  (`src/spock.c:895`, `src/spock_group.c:734, 822`);
- `spock_group_attach` when the apply worker for X reaches `apply_work()`
  (`src/spock_apply.c:3431`), i.e. after it connected and START_REPLICATION
  succeeded.

So after a **crash** restart of the source (no fresh `resource.dat`; in the v1
topology the n1-n3 mesh is built with `sub_create`, so `resource.dat` may never
have been written), the entry for X is absent until the source's apply worker
for X has reconnected to X. If X is partitioned from the source, paused, or
also restarting, that window is long. An add_node that runs its Phase 5
during that window drops X silently.

This differs from L4 (pause window) and from the ZODAN agents' properties: the
trigger is purely lifecycle ordering (restart of the source before its
workers are back), with no long transaction or pause needed.

## Invariant and assertions

- Workload (Unreachable on success): when `CALL spock.add_node(...)` completes
  without error, none of its NOTICEs contain "falling back to
  pg_current_wal_lsn()". The workload captures notices from the CALL.
  Unreachable because the fallback on a successful add means at least one
  peer's catch-up point was guessed.
- Workload (Always): after a successful add_node and quiescence, n4 holds
  every ledger row committed on n1-n3 (shared with the ZODAN data properties;
  this property contributes the trigger and the notice check).
- SUT-side (missing, no existing assertions): in
  `spock_create_slot_and_read_progress`, compare the number of peer rows
  returned with the number of enabled subscriptions on the provider other
  than from the new node (a second remote query in the same snapshot);
  `Always(rows == expected)` with message "read_peer_progress returned every
  peer of the source". Note: placing it in C keeps the PL/pgSQL untouched.

## Antithesis angle

Kill and restart the add_node source shortly before or during add_node;
partition the source from one peer while it restarts; pause a peer.

## Fault requirements

Node termination (required, for the crash restart without a fresh
`resource.dat`), network partition between source and one peer.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (implementability CW4); see `evaluation/synthesis.md`.

Current catalog line: Priority: P2 · Topology: v1 · Faults: node kill of the source before/during add_node, partition

- Evaluation note (2026-10-13): "source restart just before add_node" is scripted (crash helper on the source, then add_node) rather than left to a random kill.

## Open questions

- How wide is the window between a source crash-restart and the source's
  apply worker for X recreating its `spock.progress` row, relative to the
  Phase 5 `read_peer_progress` call (including n4's sync worker retrying
  after the source restarts)? `(partial: Phase 3/4 waits close the window before Phase 4 ends; the row is recreated at worker start before connecting to X, so a partition from X does not widen it; exact gap not measured)`

## Findings (2026-10-13): outcome is duplicates, not loss

- **The `pg_current_wal_lsn()` fallback is not what happens when X is
  dropped from `read_peer_progress`.** n4 already has a `spock.progress` row
  for (n4, X): `spock.sub_create` on n4 (Phase 3) calls
  `spock_group_ensure_entry` (`src/spock_functions.c:710`), which creates it
  with zero LSNs. Phase 7 reads `0/0`, not NULL, prints "already at or
  beyond", and advances neither the X->n4 slot nor n4's origin. When Phase 9
  enables `sub_<X>_<n4>`, n4 starts from the Phase 3 slot position and
  receives again the X commits that src had already applied before its COPY
  snapshot. So the outcome is **duplicates on n4** (insert_exists on
  insert-only rows, double-counted delta columns, and a row deleted on a
  third node before the snapshot can come back on n4 only), not loss.
- The fallback (NULL) is reachable only when n4 has no sub from X, and then
  Phase 9 `sub_enable` raises and add_node fails (see
  `add-node-success-has-sub-from-every-peer`). So the workload
  `Unreachable("add_node succeeded after falling back to pg_current_wal_lsn()")`
  is a pure regression guard; it is right as a guard but will not be the
  check that fires for this trigger.
- **Property change:** the outcome check for this trigger is the
  duplicate side (each n4 ledger row has exactly one apply_audit entry, no
  `insert_exists` on n4 for insert-only tables), not "n4 has every row".
  The SUT-side `Always(rows == expected, "read_peer_progress returned every
  peer of the source")` still names the cause and is unchanged.
- **Window correction:** the source's row for (src, X) is recreated by
  `reconcile_progress_with_origin` (`HASH_ENTER`, `src/spock_progress_recovery.c:153-200`)
  from `spock_init_progress_state`, which runs right after
  `replorigin_session_setup` and **before** `spock_connect_replica` to X
  (`src/spock_apply.c:4745-4757`). So a partition between src and X does
  not keep the row missing; only the time until the manager relaunches the
  worker for X (or a disabled/crash-looping worker) does.
- **Should `read_peer_progress` use a LEFT JOIN?** The resume LSN already
  comes from `pg_replication_origin_status` and `peer_progress_from_row`
  accepts a NULL commit ts (`src/spock_sync.c:534`), so a LEFT JOIN with
  `remote_node_id` taken from `sub.sub_origin` looks workable. This is a fix
  choice for the team; it does not change the property, so it is dropped
  from the list.

### Investigation Log

#### Is the fallback to `pg_current_wal_lsn()` ever correct?

- Examined: `samples/Z0DAN/zodan.sql:2625-2680` (Phase 7), Phase 3
  `create_sub` (`:1983-2036`), Phase 9 (`:2144-2210`),
  `src/spock_functions.c:690-715, 908-912`.
- Found: correct only if X committed nothing replicated between src's
  snapshot and Phase 7. Reachable only when n4 lacks the X->n4 sub, which
  makes Phase 9 fail.
- Conclusion: resolved; Unreachable stays as a guard, no scoping needed.

#### Should `read_peer_progress` use a LEFT JOIN?

- Examined: `sql/spock--6.0.0.sql:127-215`, `src/spock_sync.c:518-575, 775-850`.
- Found: only the INNER JOIN on `spock.progress` drops the row; all values
  that matter can come from the subscription and origin tables.
- Conclusion: resolved as a fix decision outside the property.

#### How wide is the window really?

- Examined (first pass): Phase 3 wait on src's `spock.progress` for X,
  Phase 4 `wait_for_sync_event` (`zodan.sql:~1910-1975`).
- Examined (2026-10-13): worker start order in `src/spock_apply.c:4740-4770`;
  `reconcile_progress_with_origin`; `spock_create_slot_and_read_progress`
  (`src/spock_sync.c:650-866`), which runs from n4's sync worker and is
  retried if src restarts mid-sync.
- Found: row is recreated at worker start before any connection to X; the
  remaining gap is src's restart to its manager starting the X worker. The
  sync worker retry after a src restart can land in that gap.
- Not found: a measurement; needs a run.
- Conclusion: `(partial)`, see list.
