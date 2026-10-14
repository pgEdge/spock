# every-divergence-explained-by-spock-records

Surfaced by: evaluation gap (a) (coverage-balance F1, wildcard W3).

## Why this property exists

Spock's documented contract for conflicts that it cannot resolve is that they
are recorded: "Resolvable conflicts are recorded in the `spock.resolutions`
table (when `spock.save_resolutions` is enabled); non-resolvable conflicts
are recorded in `spock.exception_log`" (`docs/conflict_types.md:12-15`;
also `docs/configuring.md:191-195`). This is SUT claim S2 in
`sut-analysis.md` §6. It is what makes the documented divergences in §12
("no tombstones", cross-origin `update_missing`) acceptable: the user can see
them and repair them (ACE).

The catalog leans on this claim in several places (Category J intro,
`exception-log-matches-discarded-transactions`,
`resolutions-rows-match-applied-outcome`,
`redelivered-ddl-not-turned-into-exception`,
`exception-replay-never-reruns-committed-transaction`,
`convergence-check-runs-after-faults`) but no property owns it. Instead every
data property uses a narrowed table (insert-only ledger, update-only
contested rows, causal-only deletes). So the most common multi-master
pattern, "create on one node, edit or delete on another", never runs, and the
`update_missing`, `delete_exists` and `delete_missing` paths are reached only
through deliberate poison transactions.

This property puts that pattern back and checks the documented contract
instead of avoiding it: on an "app" table written with INSERT, UPDATE and
DELETE from every node, every per-key difference between nodes after
quiescence must be matched by a Spock record on the node(s) that differ.

It also covers gap (a) item 3: delete conflicts other than causal deletes
(delete/update, delete/delete, delete-before-insert at a third node). No
separate property is needed for those; they get their own `Sometimes`
markers here.

## Code facts (verified at 69d9228f)

Which conflict produces which row. All conflict handling for heap tables is in
`src/spock_apply_heap.c`; reporting is `spock_report_conflict`
(`src/spock_conflict.c:371-626`), table write is `spock_conflict_log_table`
(`:628-760`), gated by `spock.save_resolutions` (default off, so the harness
must set it on, which `deployment-topology.md` already does).

| Event on the applying node N | Code | Row written | Effect on N |
|---|---|---|---|
| Remote INSERT, key exists (`insert_exists`) | `spock_handle_conflict_and_apply(..., is_insert=true)`, `src/spock_apply_heap.c:647` | `spock.resolutions`, type `insert_exists`, both when remote wins (`apply_remote`) and when local wins (`keep_local`); not in the same-origin skip (that skip only covers UPDATE_EXISTS and DELETE_ORIGIN_DIFFERS, `src/spock_conflict.c:394`) | LUW winner kept; should converge |
| Remote UPDATE, row found, local version from another origin (`update_origin_differs`) | same function, `SPOCK_CT_UPDATE_EXISTS` remapped at `src/spock_conflict.c:412-413` | **none**: `save_in_resolutions = false` for both outcomes (`:415-419`; commit 3bb8ad84 extended this to the local-wins case). Server log only, and only per `spock.log_origin_change` | LUW winner kept; should converge |
| Remote UPDATE, row found, same origin or same xact | `src/spock_conflict.c:401-409` | none (returns early) | applied |
| Remote UPDATE violates a secondary unique index (`update_exists`) | `PG_CATCH` at `src/spock_apply_heap.c:740-770` logs, then re-throws 23505 | no resolutions row; the re-thrown error goes to the exception path, so under TRANSDISCARD an `exception_log` row | whole remote txn dropped on N |
| Remote UPDATE, row not found after `spock.read_retry_count` lookups (`update_missing`) | `src/spock_apply_heap.c:982-1049`, `elog(ERROR, "logical replication did not find row to be updated ...")` | `exception_log` (via the replay path); never resolutions (comment at `:1021`) | whole remote txn dropped on N under TRANSDISCARD |
| Remote DELETE, row found, local version newer (`delete_exists`) | `try_resolve_conflict` returns false, `src/spock_apply_heap.c:1160-1176` | resolutions, type `delete_exists`, resolution `skip` | row kept on N |
| Remote DELETE, row found, delete newer, local version from another origin (`delete_origin_differs`) | `:1178-1196` | none (`save_in_resolutions = false`) | row deleted |
| Remote DELETE, row not found (`delete_missing`) | `:1203-1221` | resolutions, type `delete_missing`, resolution `skip`; `remote_tuple` built from the old key only | nothing to do |
| Any ERROR in a remote txn under TRANSDISCARD | `handle_insert`/`handle_update`/`handle_delete` dry-run branches, `src/spock_apply.c:1632-1650` and siblings; `log_insert_exception` `:1513-1560`; `add_entry_to_exception_log` `src/spock_exception_handler.c` | one `exception_log` row **per change of the discarded txn**, with `remote_origin`, `remote_commit_ts`, `remote_xid`, `operation`, `remote_old_tup`/`remote_new_tup` JSON. The root-cause row carries the real error (with `[SQLSTATE xxxxx]` prefix unless it is an internal-error `elog`, `errmsg_with_sqlstate` `:1478-1493`); the others carry `discard_collateral_message` (`:1439-1459`) | nothing of the txn applied on N |

Notes from the code:

- `update_missing` retries do not wait unless slot groups are on
  (`wait_for_previous_transaction` returns at once when
  `required_commit_ts == 0`, sut-analysis L6c), so in v1 an UPDATE that
  arrives before its INSERT fails almost every time.
- Under TRANSDISCARD every change in the dropped transaction gets a row,
  including INSERTs of new keys. So a dropped transaction that inserted key
  k2 explains k2 being absent on N. Under `exception_logging = none` nothing
  is written; the harness must keep the default `all`
  (`src/spock.c:1153-1160`).
- A resolutions row is written inside the apply transaction. If that
  transaction later fails and is discarded, the row rolls back and the
  dry-run replay writes `exception_log` rows instead. The two tables never
  both describe one applied change.
- `exception_log.remote_origin` and `resolutions.remote_origin` hold the
  RepOriginId, which in Spock is the provider's node id (sut-analysis §2.3),
  so the workload can map them to a node through `spock.node`.
  `remote_commit_ts` / `remote_timestamp` is
  `replorigin_session_origin_timestamp`, the origin's commit timestamp after
  patch 025 adjusted it (the same value `pg_xact_commit_timestamp(xid)`
  returns on the origin; already relied on by `luw-final-version-has-max-commit-ts`).
- Spock never deletes `exception_log` rows (no DELETE/TRUNCATE in `src/` or
  `sql/`). It does delete `spock.resolutions` rows: see "Resolutions cleanup
  and the wall clock" below.

### Divergences that leave no row

These are the cases where nodes can differ with no `exception_log` or
`resolutions` row. Each must be either kept out of the workload or tracked
by the workload's own history.

| Case | Documented? | How this property handles it |
|---|---|---|
| update/update conflict where nodes pick different winners (equal commit ts with 3+ writers, L2) | No (docs say lower tiebreaker wins; code compares the applying node, 64ea462d) | Attributed to L2 when the two newest writes of the key from different origins have equal commit ts; reported under a separate message |
| Local write after restart with a lagging commit clock (L3) | Patch TODO admits it | Attributed to L3 when the version a node holds was written by a client on that node within W seconds after that node's postmaster start; separate message |
| Redelivery after subscriber crash re-inserts a deleted row (L1) | No (design doc reads as exactly-once) | Attributed to L1 when the differing node's `pg_postmaster_start_time()` changed after the key's first write and its version equals an earlier version from the history; separate message |
| Frozen local tuple or truncated commit_ts: remote always wins, not logged (`get_tuple_origin`, `src/spock_conflict.c:243-254`) | Yes (`docs/conflict_types.md`, "Frozen Tuples") | Remote wins on every node, so it does not by itself diverge. Workload must not run `VACUUM FREEZE` on the app table; runs are far below `vacuum_freeze_min_age` |
| Rows copied by initial sync / add_node carry origin ts `'epoch'` (`src/spock_sync.c:944-947`) so any later remote change wins | Implicit | For n4: a difference on n4 whose n4 version came from the join copy (commit ts = epoch) belongs to `add-node-success-new-node-has-every-row`; tagged in details, not scored as unexplained |
| Table in FAILED sync state: apply skips it while the origin advances (L12) | No | App table is never resynced by the workload. If it is ever non-`r` on a node, the check reports it under the strict round (`strict-final-round-has-no-exemptions`) and does not score that node here |
| `discard` exception mode (partial txns) | Yes | Recorded per failing change, so it is explainable by key; v1 scores TRANSDISCARD runs (see open questions) |
| `sub_alter_skiplsn`, `repair_mode` | Yes | Not used on the app table |
| Deferrable unique constraints, secondary unique indexes, sequences/serial keys | Yes (§12) | App table: PK only, keys generated by the workload |
| Permanent node loss or `remove_node` | Yes | Only nodes in the mesh at check time are compared |

## Workload design (the "app" table)

Table, created with the other oracle tables before the mesh is built and
added to the default replication set on every node:

```sql
CREATE TABLE app_items (
  id        bigint PRIMARY KEY,   -- only unique index
  ver_node  int    NOT NULL,      -- node of the client txn that wrote this version
  ver_seq   bigint NOT NULL,      -- per-node txn sequence of that write
  payload   text   NOT NULL,
  qty       int    NOT NULL       -- plain column, not delta-apply
);
```

Every client write stamps `(ver_node, ver_seq)` with the writing
transaction's own id, so a row's content names the transaction that wrote it.

Keys:

- Own range per node: `id = node_id * 1e12 + local_counter`. Inserts here
  never collide.
- Shared pool: a few hundred keys inserted by any node, to produce
  `insert_exists`.
- No re-insert of a deleted key, except a small reserved range that does it
  on purpose (keeps the analysis of no-tombstone cases readable).

Operations (driver per node, 1-3 statements per txn, `RETURNING` to record
what actually changed):

- INSERT a new own-range or shared-pool key.
- UPDATE a key picked from the workload's history across all origins,
  biased toward keys created on other nodes in the last few seconds (to hit
  "update before the insert reached a third node") and toward a small hot
  set (to hit concurrent update/update and delete/update).
- DELETE a key picked the same way (any origin).
- An UPDATE or DELETE that affects 0 rows commits and is recorded as no-op.

History per transaction: origin node, `pg_current_xact_id()`, write set
`[(id, op, ver_node, ver_seq)]`, and after commit the origin's
`pg_xact_commit_timestamp(xid)`. If the client did not see the COMMIT
result, the driver later asks the origin `pg_xact_status(xid)` and records
the txn as committed or aborted. The driver also records each node's
`pg_postmaster_start_time()` at every poll, to know when a node restarted.

Partitioned variant (wildcard W10): an optional second app table partitioned
by a column the workload sometimes updates, so cross-partition moves decode
as DELETE + INSERT and turn update/update into delete/update plus
`update_missing`. Scored by the same oracle.

## Oracle (after faults stop and barriers pass)

Preconditions: all in-scope subscriptions enabled, `sync_event` +
`wait_for_sync_event(..., wait_if_disabled := true)` true for every ordered
pair; `exception_behaviour = transdiscard`, `exception_logging = all`,
`save_resolutions = on` on every node. If a precondition fails, the check
is skipped (and the strict round reports it).

1. Dump `app_items` from every in-scope node: `id -> (ver_node, ver_seq,
   payload, qty)` or absent.
2. Read `spock.exception_log` rows for `app_items` (plus rows with empty
   schema/table, matched by `(remote_origin, remote_commit_ts)`), and the
   union of all `spock.resolutions` snapshots (below).
3. For each key whose versions differ: group nodes by version (absent is a
   version). For each node N, N carries an explaining record for key k if
   one of these holds:
   - **E1** `exception_log` on N names a dropped txn that wrote k: match
     `(remote_origin, remote_commit_ts)` to a history txn whose write set has
     k, or the key appears in `remote_new_tup`/`remote_old_tup`.
   - **E2** `resolutions` on N has `delete_exists` for k, and N's version of
     k is the one the `local_tuple` shows (N kept its newer row against an
     older delete).
   - **E3** `resolutions` on N has `delete_missing` for k, and N's version
     of k was written by a history txn that INSERTed k (the no-tombstone
     resurrection: the delete arrived before the insert).
   `insert_exists` rows do not explain a difference (LUW should converge);
   they are listed in the details.
4. **Rule:** the key is explained if at most one version group has no node
   carrying an explaining record. (With two groups this is "at least one
   side has a record"; with three or more it is stronger, and it matches
   every documented pattern worked through below.)
5. Unexplained keys are then tested against the attribution classes
   (L1, L2, L3, add-node copy) above, in that order; a key that matches one
   goes to that class's message, the rest to the main message.

Worked patterns (3 nodes A, B, C; all should pass):

- Delete on A at t_A, concurrent update on B at t_B > t_A. A: B's update
  finds no row, `update_missing`, B's txn dropped, E1 on A. B: A's delete
  finds a newer row, `delete_exists`, E2 on B. C: either order; E1 or E2.
  Groups {absent}, {B's version}: both have records.
- Same with t_A > t_B: B and C delete (no record, `delete_origin_differs`);
  A drops B's update (E1). All absent: no difference.
- A inserts k; B updates k after seeing it; C gets B's update first:
  `update_missing`, E1 on C; then A's insert arrives and C holds A's
  version. Groups {A,B: B's version}, {C: A's version (E1)}: explained.
  Later writes to k from anyone overwrite C (full row), so the difference
  may heal; that is fine.
- A inserts k; C deletes k after seeing it; B gets C's delete first:
  `delete_missing` (E3 on B), then A's insert: B holds k, others absent.
  Explained.
- Concurrent deletes on A and B: each receiver logs `delete_missing`; all
  absent; no difference. If any node still holds k with only a
  `delete_missing` record and no INSERT-written version, E3 does not apply
  and the key is unexplained: a real finding.
- Insert/insert on a shared-pool key: `insert_exists` on receivers,
  converges. If the cross-upstream lookup-then-insert race (L6a) turns it
  into 23505, the txn is dropped and E1 explains it; the root cause is
  reported in details (the drop itself is owned by
  `insert-race-resolved-not-discarded`).

## Assertions

Workload-side:

- `Always(no unexplained key, "app table: every cross-node difference is explained by exception_log or resolutions")`.
  Details per key: each node's version, which history txn wrote it, the
  records found per node, root-cause message of any E1 record, whether the
  key had equal-ts writes, node restarts in the key's lifetime.
- `Always(no key in class, "app table: unexplained difference attributed to redelivery after crash (L1)")`.
- `Always(no key in class, "app table: unexplained difference attributed to equal commit ts tie (L2)")`.
- `Always(no key in class, "app table: unexplained difference attributed to commit clock reset after restart (L3)")`.
  These three keep the main message sensitive while L1/L2/L3 stay open
  (wildcard W2). Keys on n4 explained by the join copy go to the details of
  the main check, not to an assertion.
- `Sometimes(k explained by E1 with root cause update_missing, "app table: update arrived before its insert and was recorded in exception_log")`.
- `Sometimes(k explained by E2, "app table: delete_exists kept a newer row against an older delete")`.
- `Sometimes(k explained by E3, "app table: delete_missing followed by a resurrecting insert")`.
- `Sometimes(concurrent delete/delete on k ended absent everywhere, "app table: concurrent deletes converged")`.
- `Sometimes(check completed with at least N differing keys, "app table: explained-divergence check ran on a diverged table")`
  so a green result is not a check of a table that never diverged.

SUT-side (optional, all missing today): `Reachable` markers in
`spock_apply_heap_delete` for the `delete_exists` and `delete_missing`
branches, and in `spock_apply_heap_update` for the `update_missing` ERROR,
to guide exploration toward those branches.

## Resolutions cleanup and the wall clock

The apply worker deletes `spock.resolutions` rows with
`log_time < now() - spock.resolutions_retention_days` (default 100;
`src/spock_conflict.c:927-960`, called from `src/spock_apply.c:3565-3583`).
`last_cleanup_timestamp` starts at 0, so the cleanup runs at **every apply
worker start** and then every 24 h of wall clock. `log_time` is the wall
clock at apply time. A forward clock jump larger than the retention, or a
harness that lowers the retention to exercise cleanup, would delete rows the
oracle needs.

Two options:

- Keep cleanup on (it is real code worth running): the workload snapshots
  `spock.resolutions` on every node during the run and the oracle reads the
  union. Do **not** poll with `id > last_seen`: ids come from a sequence
  taken before commit, so two apply workers on one node can commit a lower
  id after a higher id was read. Re-read the whole table each poll and
  union by `(node, id)`; rows only leave through cleanup.
- Or set `spock.resolutions_retention_days = 0` (documented as "disable
  automatic cleanup", `src/spock.c:1184-1193`) on runs that score this
  property. Simpler, but the cleanup path is then never run.

Recommendation: snapshot, keep the default retention.

Second-pass decision (2026-10-13): the main configuration already sets
`spock.resolutions_retention_days = 0` for every run (deployment topology,
evaluation R18), and a value of 0 skips the cleanup entirely
(`src/spock_conflict.c:978`, `src/spock_apply.c:3572`). So in v1 no row can
leave `spock.resolutions` and the snapshot is not needed. Keep the snapshot
design only for a variant that turns cleanup back on.

## Fault requirements

None of its own beyond the run's usual set. Latency and partitions between
pairs make "update before insert" and delete/update races common; node kills
reach L1 and L3; global clock skips reach L2. Graceful worker exits during
replay (L7) and misclassified transient errors (L5) are what would produce
real unexplained differences.

## What a failure means

An unexplained key is a change that one node has and another lacks, with no
trace in Spock's audit tables: silent divergence that repair tools and
operators cannot see. Likely causes: L5 (transient error discarded without a
complete record), L7 (origin advanced past a txn whose replay never
committed), L12 (table skipped while FAILED), an unknown path where a change
is skipped without a record, or a harness bug (check the history first).

## Instrumentation

None exists (`existing-assertions.md`). Everything above is new.

## Open questions

- Which `exception_behaviour` values should score this property? The
  design assumes `transdiscard`. Under `discard` the oracle still works if
  E1 matches by key only (the DISCARD branches log only the change that
  failed, `log_insert_exception(true, ...)` at `src/spock_apply.c:1693,
  1862, 1995`; the other changes of the txn are applied), so it can run
  there with that change. Under `sub_disable` an `update_missing` disables
  the subscription and re-enabling replays the same failure, so the app
  table cannot be used without `sub_alter_skiplsn`. Decides which runs
  enable this property. `(partial: DISCARD logs only the failing change, code-checked; which modes the team wants scored is open)`
- Is the "at most one unexplained group" rule what the team means by S2, or
  only "at least one differing node has a record"? With 3+ version groups
  the two differ.
- Should differences explained only because a transient-class error (57014,
  40P01, 08xxx) was written to `exception_log` count as explained? The rows
  exist, so S2 holds, but S3 says they should never be discarded. Current
  design counts them as explained and leaves the drop to the classifier
  properties; the details field names the root cause.


### Investigation Log

#### Which conflict types produce which rows, and which leave none?

- Examined: `src/spock_conflict.c` (`spock_report_conflict`,
  `spock_conflict_log_table`, `conflict_resolve_by_timestamp`,
  `get_tuple_origin`), `src/spock_apply_heap.c` (insert/update/delete apply
  and `spock_handle_conflict_and_apply`), `src/spock_apply.c`
  (`should_log_exception`, `log_insert_exception`, dry-run branches,
  `handle_commit`), `src/spock_exception_handler.c`, `docs/conflict_types.md`,
  commit 3bb8ad84.
- Found: table above. `insert_exists`, `delete_exists`, `delete_missing` ->
  resolutions; `update_missing`, `update_exists` -> exception_log via the
  error path; origin-differs (update and delete) -> no row for either
  outcome. Under TRANSDISCARD every change of a dropped txn gets its own
  exception_log row.
- Conclusion: resolved; the matching rules E1-E3 follow from it.

#### Can resolutions rows disappear before the oracle reads them?

- Examined: `spock_cleanup_resolutions*` and its caller in the apply loop.
- Found: cleanup at every apply worker start and then every 24 h, by wall
  clock and `log_time`. No cleanup of `exception_log` anywhere in `src/` or
  `sql/`.
- Not found: the maximum Antithesis clock jump size (not in the tree).
- Conclusion: snapshot design above. Second pass: the main configuration
  sets `resolutions_retention_days = 0`, which skips cleanup
  (`src/spock_conflict.c:978`), so the jump size no longer matters for v1
  and the question was dropped.

#### Which exception_behaviour values can score the property?

- Examined: DISCARD branches of `handle_insert/update/delete`
  (`log_insert_exception(true, ...)` at `src/spock_apply.c:1693, 1862,
  1995`); SUB_DISABLE path in `handle_commit` (`:1067-1084`).
- Found: DISCARD logs only the change that failed and applies the rest of
  the transaction, so E1 must match by key there; SUB_DISABLE disables the
  subscription on the first `update_missing`, and re-enabling replays the
  same failure.
- Conclusion: `(partial: DISCARD logs only the failing change, code-checked; which modes the team wants scored is open)`.
  Designed for `transdiscard`; `discard` with key matching; not
  `sub_disable`.
