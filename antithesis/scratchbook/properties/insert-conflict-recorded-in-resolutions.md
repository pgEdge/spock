# insert-conflict-recorded-in-resolutions

## What the property says

With `spock.save_resolutions=on`, when two nodes both commit a client INSERT
of the same primary key (so neither saw the other's row first), each node that
later receives the other's INSERT records an `insert_exists` row for that key
in its `spock.resolutions` table, in the same transaction that applies (or
declines) the remote row. If the remote transaction was instead dropped, the
node has a `spock.exception_log` row for it. A resolved conflict is never
silent.

## Claimed guarantee

- `docs/conflict_types.md:13-15`: "Resolvable conflicts are recorded in the
  `spock.resolutions` table (when `spock.save_resolutions` is enabled);
  non-resolvable conflicts are recorded in `spock.exception_log`."
- Summary table (`:19-27`): `insert_exists`, `delete_missing`,
  `delete_exists` are resolvable and recorded; `update_origin_differs` and
  `delete_origin_differs` are "normal flow, not recorded".
- `docs/configuring.md:506-510`: `save_resolutions` "logs all conflict
  resolutions".

Note the code and the newer docs agree that **update/update conflicts are
not recorded** (`spock_report_conflict`, `src/spock_conflict.c:~395-445`,
`save_in_resolutions = false` for origin-differs, regardless of which side
wins, commit 3bb8ad84). So a property "every resolved conflict is recorded"
would fire on documented behaviour for UPDATEs. This property is scoped to
`insert_exists`, where the code path always saves:
`spock_handle_conflict_and_apply` calls `spock_report_conflict(SPOCK_CT_INSERT_EXISTS, ...)`
(`src/spock_apply_heap.c:647`), which skips the origin-differs block for
inserts and calls `spock_conflict_log_table` (`src/spock_conflict.c:~465-475`,
`CatalogTupleInsert` at `:~752`) inside the apply transaction.

## Why it matters

Operators (and ACE) rely on `spock.resolutions` to see where LUW threw away a
version. An insert_exists that overwrote or kept a row without a record is
silent data loss from the user's point of view. Paths that could skip it:

- **L6a insert/insert race**: apply looks up the key, finds nothing, then
  inserts (`spock_apply_heap_insert`, `src/spock_apply_heap.c:837-930`, `TODO:
  do we need a retry finding a tuple?`). A concurrent local insert or another
  apply worker inserting the same key makes the INSERT fail with 23505, which
  is not transient -> `transdiscard` drops the whole upstream transaction ->
  only `exception_log` gets a row. This still satisfies this property (an
  exception row exists), but the convergence property will flag the
  divergence; together they tell the two cases apart.
- **Crash between apply and log**: both are in one transaction, so a crash
  loses both; on redelivery the conflict is logged again. Expected to hold.
- **Retention cleanup**: `spock.resolutions_retention_days` (default 100,
  cleanup in the apply loop, `src/spock_apply.c:~3572`) must not remove rows
  during a run.

## Oracle design

- Table `dupkeys(k int primary key, writer text, wseq bigint)`. Writers on
  different nodes INSERT keys drawn from a small shared range; a client INSERT
  that fails with 23505 locally is "not committed" (the other node's row had
  already arrived).
- For each key where at least two nodes' INSERTs committed (writers W1 on N1,
  W2 on N2): after barriers, for each such Ni, receiving the other writer's
  INSERT must have produced a record on Ni. Check:
  `Always(Ni.spock.resolutions has a row with conflict_type='insert_exists'
  for relname 'public.dupkeys' and the key in remote_tuple, OR Ni.spock.exception_log
  has a row for the other writer's transaction)`.
- The third node N3 receives both INSERTs; the second arrival must also be
  recorded on N3. Include it.
- Read `spock.resolutions` with `local_tuple` / `remote_tuple` JSON to find the
  key.

`Always` because each such pair must leave a record.

## Fault requirements

- Partitions/latency so that both nodes commit the same key before either
  sees the other (needed to create the conflict at all).
- Node termination (checks that the record survives with the applied change).

## SUT-side instrumentation (missing)

- In `spock_report_conflict`, `AlwaysOrUnreachable(save_in_resolutions ||
  conflict_type is origin-differs, "non-origin-differs conflict is saved")`
  when `spock_save_resolutions` is on. This turns the doc table into a
  code-level check.
- `Reachable("insert_exists conflict resolved")` to confirm the workload
  produces the conflict.

## Resolved questions (see Investigation Log)

- Not recording `update_origin_differs` (either winner) is intended: commit
  3bb8ad84 states it on purpose ("Origin-differs events ... are no longer
  written to spock.resolutions when the local tuple wins"), and
  `docs/conflict_types.md:66-71` says the same. The property stays scoped to
  `insert_exists`. The sentence in `docs/configuring.md:506-510` ("logs all
  conflict resolutions") is stale doc wording, not a reason to widen the
  property.
- `spock.resolutions` is not replicated: the `spock` schema and extension are
  built-in reserved objects with `block_in_repset = true`
  (`sql/spock--6.0.0.sql:357-360`), and `EnsureRelationNotIgnored`
  (`src/spock_node.c:1487-1517`) refuses to add such a table to any
  replication set; `add_all_tables` skips them (`src/spock_functions.c:1978,
  2043-2056`). Each row carries the recording node's name
  (`src/spock_conflict.c:664-666`). Filter on `node_name` anyway; it costs
  nothing.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (wildcard W14); see `evaluation/synthesis.md`.

Current catalog line: Priority: P2 · Topology: v1 · Faults: partition, latency, node kill

- Evaluation note (2026-10-13): the harness sets `spock.resolutions_retention_days = 0` (or copies `spock.resolutions` rows as they appear), so a forward clock skip past the retention period cannot delete rows this check reads at the end.

## Open questions

None remaining.

### Investigation Log

#### Should `update_origin_differs` with KeepLocal go unrecorded?

- Examined: `spock_report_conflict` `src/spock_conflict.c:393-470`; commits
  3bb8ad84 and 85688477 (messages and stats); `docs/conflict_types.md:60-71`;
  `docs/configuring.md:500-510`.
- Found: for UPDATE/DELETE origin-differs the code sets
  `save_in_resolutions = false` before looking at the winner; the KeepLocal
  case still reaches the server-log message and PG18 stats, but no table row.
  3bb8ad84's message states the KeepLocal exclusion was added deliberately;
  85688477 explains the reasoning ("informational ... not true conflicts").
- Not found: anything in code or newer docs that asks for KeepLocal rows.
- Conclusion: resolved, intended. `configuring.md` wording is stale. Property
  scope unchanged (insert_exists only).

#### Does `spock.resolutions` itself get replicated?

- Examined: `sql/spock--6.0.0.sql:340-361, 450-478` (reserved objects,
  resolutions DDL), `EnsureRelationNotIgnored` `src/spock_node.c:1487-1517`,
  `add_all_tables` path `src/spock_functions.c:1970-2056`,
  `spock_conflict_log_table` `src/spock_conflict.c:649-666`.
- Found: the table is `user_catalog_table` (so logical decoding would see its
  changes), but no replication set can contain it because the `spock` schema
  is reserved with `block_in_repset = true`; the output plugin only sends
  tables in a subscribed set.
- Not found: a path that adds a `spock` table to a set except deleting the
  built-in reserved row by hand, which the harness does not do.
- Conclusion: resolved, not replicated. Keep the `node_name` filter as a cheap
  guard.
