# zodan-readd-node-progress-not-stale

## Why this property exists

The deployment plan allows the workload to remove n4 and join it again on the
same container. Every add-node claim (S13: "no data is missed or duplicated")
is usually tested only on a fresh node. On a re-add, the new node's
shared-memory progress hash (`SpockGroupHash`, shown as `spock.progress`)
still holds entries from the previous incarnation: entries are never deleted
(`src/spock_group.c:36-42`) and survive restarts through `resource.dat`. ZODAN
Phase 7 reads that hash to decide where to start each peer's slot, without
checking that the entry was written during this add.

This is lifecycle (re-join) x state (progress persistence) x protocol (Phase 7
contract). It also matches Pattern C in the bug history (add-node catch-up
fixed at least seven times).

## Code path (HEAD 69d9228f)

- `samples/Z0DAN/zodan.sql:2637-2662` (Phase 7,
  `check_commit_timestamp_and_advance_slot`):
  ```
  SELECT p.remote_commit_lsn INTO target_lsn
  FROM spock.progress p
  JOIN spock.node n ON n.node_id = p.remote_node_id
  WHERE n.node_name = rec.node_name;
  ```
  - Filters only on `remote_node_id`. The `spock.progress` view already
    limits rows to the current database (`sql/spock--6.0.0.sql:118-122`), but
    there is no filter on the local `node_id`. PL/pgSQL `SELECT INTO` without `STRICT` silently takes the first
    of several rows.
  - NULL -> documented fallback to `pg_current_wal_lsn()` (NOTICE).
  - `target_lsn <= current_lsn` -> "already at or beyond", no advance.
- Entries are written by force-set from `read_peer_progress` during Phase 5
  (`spock_group_progress_force_set_list`) and by every applied commit. The
  INNER JOIN in `read_peer_progress` (`sql/spock--6.0.0.sql:127-200`) can omit
  a peer (L4 related note); then no force-set happens for it.
- Node id = `hash(node_name) & 0xffff` unless given (`src/spock_node.c:367-371`),
  so a re-add under the same name reuses the same hash key; a re-add under a
  new name on the same instance leaves the old key's rows in place next to the
  new ones.

## Failure scenarios (hypothesised, not run)

A. Re-add under the same name, and `read_peer_progress` omits peer X this
time (X's entry missing on the source after a source restart): instead of the
documented fallback, Phase 7 finds the **old** entry for X from the previous
incarnation. That LSN is in X's LSN space but older than the slot just created
in Phase 3, so Phase 7 skips the advance. The new node then receives X's
changes from slot creation onward, overlapping what the COPY from the source
already contained -> duplicates. Duplicated INSERTs show as `insert_exists`;
a duplicated INSERT of a row that a third node deleted before the COPY
snapshot **resurrects** that row on the new node only (the delete is not
re-sent), which is permanent divergence. Delta columns double count.

B. Re-add under a different name on the same instance: two rows for
`remote_node_id = X` (old local id and new local id); which one `SELECT INTO`
returns is not defined. Same outcomes as A when the stale one is chosen.

C. Reconcile (`reconcile_progress_with_origin`, L17) may rewrite entries at
apply start and hide or cause the effect depending on timing.

## Property

For every add_node that reports success, including the second and later adds
of a node on the same instance, the new node ends with exactly the union of
rows committed on the other nodes (ledger check), and no `insert_exists`
resolutions appear on insert-once tables (see
`ledger-row-applied-exactly-once-per-peer`).

- Workload-side `Always` after each successful add_node + quiescence: ledger
  completeness and no extra rows on the joined node. Message: "re-added node
  holds exactly the cluster's rows". Tag the add iteration number in details.
- Workload-side `Sometimes`: "add_node succeeded on a node that had been
  removed before" (makes sure re-adds happen at all).
- SUT-side (missing, no existing assertions; ZODAN is PL/pgSQL, so this would
  be a `RAISE`-to-log marker matched by the workload): in Phase 7, assert the
  chosen progress row was written during this add_node (its
  `last_updated_ts` column is after the add_node start). A stale row is a property
  failure even if the data happens to match.

## Fault requirements

- remove_node followed by add_node of the same container (workload action).
- Node restart of the source between the two adds (to make
  `read_peer_progress` miss a peer) helps scenario A.
- Writes on all nodes during the add (required to have something to
  duplicate or lose).

## Confidence

Low to medium. The query shape and the "never deleted" rule are confirmed in
code. Whether stale rows are actually present at Phase 7 time depends on
whether `remove_node`/`node_drop` or the new node's setup clears or overwrites
them, which was not traced through every path, and on L17 reconcile timing.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (implementability CW11 and property finding); see `evaluation/synthesis.md`.

Current catalog line: Priority: P2 · Topology: v1 (needs remove + re-add of n4) · Faults: node kill of source, re-add

- Evaluation note (2026-10-13): a re-add first drops n4's user tables (add_node refuses a database with user tables, `samples/Z0DAN/zodan.sql:1577-1592`) and makes sure n4 has every role the source has (`:1595`). Stale `spock.progress` rows stay visible either way (not filtered by database). The Phase 7 `last_updated_ts` marker is a change to `samples/Z0DAN/zodan.sql` and is listed as a SUT change. Runs in the add-node template.

## Gap-fill extensions (2026-10-13)

From the gap-fill step; see `discovery/gap-b-addnode-ops.md` and `evaluation/synthesis.md`.

- Re-add steps: run `remove_node`; on n4 drop the workload's user
  **schemas** (not only the tables) and keep every role the source has.
  add_node's prerequisite check counts only tables
  (`samples/Z0DAN/zodan.sql:1577-1592`), but `create_sub` turns every
  pre-existing non-`public` user schema on n4 into `skip_schema`
  (`:347-372`), and `skip_schema` removes that schema from both the
  structure dump and the data sync (`src/spock_sync.c:1388-1393`). An
  emptied-but-kept schema passes the prerequisite check and leaves n4
  without that schema's tables, which this property would score as missing
  rows (a harness artefact, not the stale-progress bug).
- New open question below: whether skipping an empty pre-existing schema is
  intended.

## Open questions

- Is skipping an empty pre-existing user schema on the new node intended?
  If not, an operator who empties a node by dropping tables (as the
  prerequisite check suggests) gets a node with whole schemas missing and
  no error. `(needs human input)`

## Findings (2026-10-13)

- **Nothing clears progress rows.** The only `HASH_REMOVE` calls in `src/`
  are on `SpockHash` (stats reset, `src/spock_functions.c:3840`) and the
  output plugin's caches; none on `SpockGroupHash`. `node_drop`,
  `remove_node`/`zodremove.sql` and `DROP EXTENSION` do not touch it, and
  `resource.dat` keeps the rows across clean restarts. `spock_group_ensure_entry`
  (called by `sub_create`) keeps an existing row as is (`if (!found)` only
  initialises new rows). The rows go away only with a new `initdb` (file
  gone, or `system_identifier` mismatch skips it at load).
- **Re-add on the same instance is supported and tested.** Phase 3 has
  explicit code for it: "Drop stale replication origin from a previous
  add_node cycle so create_sub starts fresh at 0/0 (avoids stale-LSN data
  loss)" (`samples/Z0DAN/zodan.sql:1986-2007`). TAP tests 011, 012, 017 and
  033 `node_drop` a node and add it back under the same name on the same
  instance. Note the asymmetry: the stale **origin** is dropped, the stale
  **progress row** is not.
- **Scenario A is confirmed in code.** Same name -> same node id
  (`hash(node_name) & 0xffff`) -> same key (n4, X). If X is in
  `read_peer_progress`, the force-set overwrites the stale row and all is
  well. If X is left out (source restart window, see
  `add-node-after-peer-restart-captures-every-peer`), Phase 7 reads the
  stale LSN, which is below the new Phase 3 slot, skips both advances, and
  n4 re-receives X's commits from the slot point: duplicates (and possible
  resurrection of rows deleted elsewhere before the snapshot). Because the
  origin was reset to 0/0 but the row is not, the X->n4 worker hits
  `RECONCILE_FILE_ANOMALY` when Phase 9 enables it (row ahead of origin),
  which links this to `progress-reconcile-anomaly-unreachable`. On a fresh
  node the same omission gives a zero row instead and the same duplicates,
  so the re-add adds the ANOMALY signal more than a new outcome.
- **Scenario B is a real query gap.** Phase 3's own progress query on src
  filters `p.node_id = (SELECT node_id FROM spock.node_info())`
  (`zodan.sql:1928-1934`); Phase 7 (`:2637-2641`) and the src->new check
  (`:2541-2545`) do not. After a re-add under a different name on the same
  instance and database, n4 has rows for both (old_id, X) and (new_id, X),
  and `SELECT ... INTO` (no `STRICT`) takes whichever comes first from the
  hash scan.
- The property itself is unchanged. The SUT-side marker idea ("chosen
  progress row was written during this add") stays; a simpler equivalent is
  a workload check that Phase 7's chosen row has `node_id` = n4's current id
  and `last_updated_ts` after the add started.

### Investigation Log

#### Does anything clear `SpockGroupHash` entries for a dropped node?

- Examined: grep `HASH_REMOVE` in `src/`; `src/spock_group.c` (header,
  `ensure_entry`, `force_set_list`, `resource_load`); `src/spock.c:860-900`
  (shutdown dump); `samples/Z0DAN/zodremove.sql`.
- Found: no removal path; load skips the file only on a `system_identifier`
  mismatch.
- Conclusion: resolved. Rows survive node_drop, remove_node and extension
  drop/recreate on the same instance; only a new initdb clears them.

#### Is re-adding a node under the same name supported?

- Examined: `zodan.sql:1986-2007`; TAP tests `011_zodan_sync_third.pl`,
  `012_zodan_basics.pl`, `017_zodan_3n_timeout.pl`,
  `033_zodan_lolor_add_node.pl`; `docs/modify/zodan/zodan_tutorial.md:28-30, 131-136`.
- Found: Phase 3 handles "a previous add_node cycle" explicitly; tests drop
  and re-add on the same instance; the docs say to run remove_node before a
  retry.
- Conclusion: resolved, yes.

#### Should Phase 7 filter on the local node id?

- Examined: Phase 3 progress query (`zodan.sql:1925-1934`), Phase 7
  (`:2637-2641`), src->new block (`:2541-2545`), view definition
  (`sql/spock--6.0.0.sql:118-122`).
- Found: Phase 3 filters on `spock.node_info()`, Phase 7 does not; nothing
  else limits the rows to the current local node.
- Conclusion: resolved: the filter is missing and its absence is
  inconsistent with Phase 3, so scenario B is a plain query gap. Adding it
  is a one-line fix for the team; the property is unchanged.

#### Does add_node copy a user schema that already exists, empty, on the new node?

- Examined: `samples/Z0DAN/zodan.sql:347-372` (`create_sub` builds
  `skip_schema` from n4's existing non-`public` schemas), `:1577-1592`
  (prerequisite counts only tables), `src/spock_sync.c:1388-1393`
  (`skip_schema` filters both the dump and the data copy).
- Found: an existing empty schema is skipped in structure and data.
- Not found: docs saying the new node must have no user schemas.
- Conclusion: `(needs human input)` on intent; the harness drops schemas
  before a re-add either way.
