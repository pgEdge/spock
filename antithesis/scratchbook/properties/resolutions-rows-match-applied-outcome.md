# resolutions-rows-match-applied-outcome

## Summary

With `spock.save_resolutions = on` (planned in the topology), Spock writes a
row to `spock.resolutions` for `insert_exists`, `delete_exists` and
`delete_missing` conflicts (`docs/conflict_types.md:240-250`). The rows are the
basis for the harness's "explained divergence" oracle and for operators. The
property: each row records the conflict that actually happened and a decision
consistent with the documented last-update-wins rule.

Note from the docs and code: `update_origin_differs` and
`delete_origin_differs` are **never** written to `spock.resolutions`, whichever
side wins (`src/spock_conflict.c:394-450`, commit 85688477, documented at
`docs/conflict_types.md:66-71`). So a remote UPDATE thrown away because the
local row is newer leaves no row in either table. Any oracle that expects
"every difference is explained by exception_log or resolutions" must not count
on update/update conflicts appearing.

## Code paths

- `spock_report_conflict` `src/spock_conflict.c:371-600`;
  `spock_conflict_log_table` `:628-757` (insert in the apply transaction, so it
  rolls back with it).
- Recorded fields: `remote_origin = replorigin_session_origin` (node id set by
  `handle_origin`), `remote_timestamp = replorigin_session_origin_timestamp`,
  `remote_lsn = replorigin_session_origin_lsn` (BEGIN commit_lsn),
  `local_origin/local_timestamp` from `get_tuple_origin` (`:219-275`,
  `pg_commit_ts` of the local tuple's xmin; NULL timestamp when 0).
- Decision: `conflict_resolve_by_timestamp` `:99-200`: remote newer -> apply
  remote; local newer -> keep local; equal and same origin -> apply remote;
  equal -> compare tiebreaker of **this node** vs the remote node; lower keeps
  local; equal tiebreakers -> apply remote + WARNING.
- Call sites: insert_exists `src/spock_apply_heap.c:647`; delete_exists
  `:1168` (recorded with resolution `skip`); delete_missing `:1216`.
- Delta-apply forced updates rewrite the subtransaction's commit ts/origin to
  the local winner's (`:745-780`, patch 030), which feeds later
  `local_timestamp/local_origin` readings.

## Invariant

Workload-side `Always`, each a distinct message, run after quiescence
(check 2 on non-delta tables only; see resolved questions):

1. "resolutions remote side names the real writer": `remote_origin` is a peer
   node id (never the recording node's own id) and `(remote_origin,
   remote_xid, remote_timestamp)` matches a transaction the workload committed
   on that node; for `insert_exists`, `remote_tuple` equals the row that
   transaction inserted.
2. "resolutions local side names the real local version": for rows with
   `local_tuple`, the version tag in `local_tuple` belongs to a workload
   transaction whose origin is `local_origin` (0 = this node) and whose commit
   ts equals `local_timestamp`.
3. "resolution decision follows last-update-wins": for `insert_exists`,
   `conflict_resolution = 'apply_remote'` iff `local_timestamp IS NULL` or
   `remote_timestamp > local_timestamp` or (equal and (same origin or not
   tiebreaker(node_name) < tiebreaker(remote_origin))); for `delete_exists`,
   `local_timestamp >= remote_timestamp` with the same tie rule. Tiebreakers
   read from each node's own `spock.node.info`.
4. "delete_missing has no local tuple".

Check 3 is close to restating the code, but it catches values recorded from a
different source than the one decided on, and it gives L2 (tiebreaker values
that differ between nodes' catalogs) a visible symptom.

## Antithesis angle

Asymmetric latency and partitions produce real insert/insert and
delete/update races; clock jitter produces equal timestamps; node restarts
reset the logical clock (L3), which affects who wins but must not make the
recorded row disagree with what was decided.

## Resolved questions (see Investigation Log)

- A remote UPDATE that loses to a newer local row is intentionally not written
  to `spock.resolutions` (commit 3bb8ad84, by a maintainer, states the KeepLocal
  case was excluded on purpose; `docs/conflict_types.md:66-71` agrees). It
  reaches only the server log at `spock.conflict_log_level` and, on PG18, the
  per-subscription conflict counters. No "every keep_local is recorded"
  property is added. Any "explained divergence" oracle must not expect a row
  for update/update conflicts.
- Delta-apply tables are out of scope for check 2 only. After a delta
  update, `SubTransactionIdSetCommitTsData(..., local_ts, local_origin)`
  (`src/spock_apply_heap.c:774-778`) stamps the new tuple version with the
  previous local winner's commit time and origin, and the tuple value is a
  sum of several writers' deltas, so its version tag names no single workload
  transaction. Check 3 can include delta tables: `spock_report_conflict` is
  called with the last-update-wins decision (`src/spock_apply_heap.c:647`)
  before the delta code overrides `apply = false` to `true` (`:675-681`), so
  the recorded `conflict_resolution` is still the LUW decision even when the
  delta is applied anyway. Checks 1, 3 and 4 may run on delta tables; check 2
  runs on non-delta tables only.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (wildcard W14); see `evaluation/synthesis.md`.

Current catalog line: Priority: P2 · Topology: v1 · Faults: latency, partition, clock skew

- Evaluation note (2026-10-13): same retention guard as `insert-conflict-recorded-in-resolutions`.

## Gap-fill extensions (2026-10-13)

From the gap-fill step; see `discovery/gap-a-divergence.md` and `evaluation/synthesis.md`.

- Score `delete_exists` and `delete_missing` rows produced by the app-table
  traffic of `every-divergence-explained-by-spock-records` (create on one
  node, update or delete on others). Until now those rows came only from
  narrow races.

## Open questions

None remaining.

### Investigation Log

#### Is it intended that a remote UPDATE losing to a newer local row is not persisted anywhere?

- Examined: `spock_report_conflict` `src/spock_conflict.c:393-470`; commit
  messages of 3bb8ad84 and 85688477; `docs/conflict_types.md:60-71`.
- Found: `save_in_resolutions = false` for all origin-differs events whatever
  the resolution; 3bb8ad84 says "Origin-differs events ... are no longer
  written to spock.resolutions when the local tuple wins; previously only the
  remote-wins case was excluded". The KeepLocal case still logs to the server
  log and PG18 stats.
- Not found: any newer statement reversing this.
- Conclusion: resolved as intended. Previous tag `(needs human input)` dropped:
  the maintainer's commit message answers it. `docs/configuring.md:506-510`
  still says "logs all conflict resolutions"; that wording is stale.

#### Are delta-apply tables in scope for check 2?

- Examined: `src/spock_apply_heap.c:700-780` (delta-apply update in a
  subtransaction, then `SubTransactionIdSetCommitTsData`), `get_tuple_origin`
  `src/spock_conflict.c:219-275`.
- Found: the recorded `local_timestamp/local_origin` for a delta-apply tuple is
  the earlier winner's, copied onto the new version by design; the stored
  value is a merged sum.
- Also found: the resolution row is written at `:647` before the delta
  override at `:675-681`, so it records the LUW decision, not the forced apply.
- Conclusion: resolved by scoping; exclude delta-apply tables from check 2
  only. Checks 1, 3 and 4 apply to them. Small widening of the invariant's
  "non-delta tables" scope.
