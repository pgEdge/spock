# exception-log-matches-discarded-transactions

## Summary

Under `spock.exception_behaviour = transdiscard` (the default) a remote
transaction that hits a data error is replayed read-only, every row is written
to `spock.exception_log`, and the origin moves past it
(`docs/configuring.md:160-184`, `docs/conflict_types.md:12-15`). Operators and
ACE repair rely on that table to know what was dropped. The property: the
table is an accurate record of what happened on that node.

- **Accurate attribution.** Each row's `(remote_origin, remote_xid,
  remote_commit_ts)` identifies a real transaction that originated on node
  `remote_origin`, and the row's `table_schema/table_name/operation/
  remote_new_tup/remote_old_tup` is one of that transaction's changes.
- **Complete for discarded transactions.** For a transaction with any
  TRANSDISCARD entry on node S, S has one entry per replicated change of that
  transaction (with `exception_logging = all`, the default), exactly one of
  them carries the real error, and none of the transaction's changes are
  visible on S.
- **Nothing dropped without a row.** A provider transaction whose changes are
  missing on S (and not explained by the documented boundaries) has an entry.

## Code paths

- `log_insert_exception` `src/spock_apply.c:1508-1559` -> 
  `add_entry_to_exception_log` `src/spock_exception_handler.c:87-...`:
  `remote_origin = remote_origin_id` (from `handle_origin`),
  `remote_commit_ts = replorigin_session_origin_timestamp` (from BEGIN),
  `remote_xid` (from BEGIN), `command_counter = exception_command_counter`.
- TRANSDISCARD replay rows: `handle_insert` `:1630-1655` (and the update,
  delete, truncate equivalents at `:1826`, `:1959`, `:2174`): only the row whose
  `xact_action_counter == failed_action` gets the real message, others get
  `discard_collateral_message()` (`:1439-1476`).
- `should_log_exception` `:357-370`: TRANSDISCARD always logs when
  `exception_logging != none`.
- Origin advance past the discarded transaction: `handle_commit` `:1002-1009`;
  the exception rows commit in the same local transaction (`:1020-1058`).
- Exception marker in shared memory keyed by subscription name
  (`handle_begin` `:722-879`); the apply worker and a sync worker in CATCHUP
  share it (L15).

## Ways it can go wrong

- `remote_origin_id` is reset in `handle_begin` (`:687`) and set only by `O`.
  If `O` is missing the rows say `remote_origin = 0` (see
  apply-stream-framing-and-lsn-order).
- L7: a graceful exit during in-process replay after the abort record advanced
  the origin can lose the transaction with **no** row.
- L15: a sync worker's failure recorded under the apply worker's marker can
  make the apply worker replay (and log) a transaction that never failed for it.
- `acf6cdae`, `d286f3df`, `ed0a9945`, `8dcfbcd5` (bug history Pattern A): a
  transient error treated as a data fault produces rows for transactions that
  were fine; the error text then names a connection or deadlock code. With only
  infrastructure faults, any row is suspicious (S3).
- `retry_errored_at` is part of the PK and is a per-row wall-clock value, so a
  replay repeated after a worker restart produces a second set of rows; the
  check must treat them as sets and tell replays apart by the rows' `xmin`.

## Invariant

Workload-side `Always` checks, run after quiescence on every node, each with
its own message:

1. "exception_log row names a real transaction": workload records for each
   transaction it commits `(node, txid_current() & 0xffffffff,
   pg_xact_commit_timestamp(xid))` and its write set. Every row's
   `(remote_origin node id, remote_xid, remote_commit_ts)` matches one record,
   and its key is in that record's write set.
2. "discarded transaction is logged completely and applied nowhere on that
   node": for each transaction that has rows on S, the logged keys equal its
   replicated write set and none of its insert-only ledger rows exist on S.
3. "exactly one root-cause entry per discarded transaction": among the rows of
   one replay, exactly one `error_message` does not start with
   `transdiscard: ... discarded`. **Group a replay by `(remote_origin,
   remote_commit_ts, xmin)`, not by `retry_errored_at`**: `retry_errored_at`
   is `GetCurrentTimestamp()` taken per row (`src/spock_exception_handler.c:199`),
   so rows of one replay usually have different values. All rows of one
   replay are inserted by the same local apply transaction, so the
   exception_log rows' `xmin` system column identifies the replay.
   Two edge cases from the code: (a) rows logged through the
   "Spock can't find relation" path carry that text, not collateral wording,
   so a transaction touching two missing relations has two non-collateral
   rows (out of scope: the workload never drops a replicated table);
   (b) if `failed_action` is set but `initial_error_message` is empty, the
   failing row gets collateral wording too (`discard_collateral_message`,
   `src/spock_apply.c:1439-1458`), giving zero root-cause rows. Report zero
   under its own message ("root cause not captured") rather than folding it
   into this one.

Plus `Sometimes(transaction discarded under TRANSDISCARD)` so the path is
known to run (driven by the documented `update_missing` boundary or a
deliberate constraint violation on one node).

## Scope

- Only `transdiscard` runs. `discard` is non-atomic by design; under
  `sub_disable` a logged transaction is applied later after re-enable.
- Tables in the default repsets only; `exception_logging = all`.
- Exclude rows written while the subscription was syncing a table (changes for
  not-ready tables are skipped, not logged).

## Resolved questions (see Investigation Log)

- `remote_xid` holds the 32-bit `TransactionId` sent in BEGIN
  (`pq_sendint(out, txn->xid, 4)`, `src/spock_proto_native.c:232`; stored with
  `TransactionIdGetDatum` into a `bigint` column). The workload records
  `txid_current() & 0xffffffff` (or `pg_current_xact_id()::xid`) and compares
  32-bit values. No epoch.
- Rows for a relation the subscriber cannot open have `table_schema = ''` and
  `table_name = ''` (empty strings, not NULL), `remote_new_tup` and
  `remote_old_tup` NULL, and `error_message = 'Spock can't find relation'`.
  Check 1 must accept those rows by error text and skip the key match.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (implementability CW6, wildcard (odd things)); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 · Faults: worker exit, partition, workload data errors

- Evaluation note (2026-10-13): poison and `update_missing` writes go to their own tables and into the expected-exception registry (origin, remote xid, table; `spock.exception_log.remote_xid` exists), so their documented divergence and rows do not fail other properties.

## Gap-fill extensions (2026-10-13)

From the gap-fill step; see `discovery/gap-a-divergence.md` and `evaluation/synthesis.md`.

- Use the app table's natural `update_missing` drops (from
  `every-divergence-explained-by-spock-records`) as a second traffic source,
  in addition to the deliberate poison transactions. Those drops are
  recorded per change under TRANSDISCARD and are matched by
  `(remote_origin, remote_commit_ts)` against the workload history.

## Open questions

None remaining.

### Investigation Log

#### Should `remote_xid` be compared as a 32-bit value?

- Examined: `src/spock_proto_native.c:232` (BEGIN write), `:684-696` (BEGIN
  read), `src/spock_exception_handler.c:146`, `sql/spock--6.0.0.sql:54-71`.
- Found: the publisher sends `txn->xid` as 4 bytes; the subscriber reads it with
  `pq_getmsgint(in, 4)` into a `TransactionId`; the row stores it with
  `TransactionIdGetDatum` into a `bigint` column, so the stored value is the
  plain 32-bit xid (0..2^32-1), without epoch.
- Not found: nothing.
- Conclusion: resolved. Compare against `txid_current() & 0xffffffff`.

#### Does the replay log changes for relations the subscriber lacks with a NULL table name?

- Examined: `handle_insert` `src/spock_apply.c:1591-1615` (same shape in update,
  delete), `spock_read_insert/update/delete` `src/spock_proto_native.c:813-928`
  (return NULL only when `use_try_block`), `spock_relation_open`
  `src/spock_relcache.c:105-110, 200-205`, `add_entry_to_exception_log`
  `src/spock_exception_handler.c:104-105, 158-175`.
- Found: on replay a missing relation logs a row with `rel = NULL`, `newtup =
  NULL`, message "Spock can't find relation"; `add_entry_to_exception_log`
  writes `""` for schema and table (not NULL) and NULL tuples. The row is
  logged with `failed = true`, so its message is not collateral wording.
- Also found while reading (not a listed question): `retry_errored_at` is set
  per row from `GetCurrentTimestamp()` (`:199`), so it cannot group a replay;
  invariant 3 now groups by `xmin`.
- Conclusion: resolved. Check 1 allows empty schema/table with that message;
  check 3 counts such rows as root-cause rows.
