# redelivered-ddl-not-turned-into-exception

## What the property says

When a replicated DDL transaction (AutoDDL or `spock.replicate_ddl()`) is
delivered to a subscriber that has already applied it, the redelivery does not
produce an `exception_log` row, does not disable the subscription, and does not
drop data. In practice: a run with DDL only in quiesced phases and only
infrastructure faults has no `exception_log` row whose `operation` is `SQL` /
`ddl_statement` is set, and no subscription disabled for a DDL error.

## Why it matters

DDL is the one replicated operation that is not idempotent at the SQL level.
`CREATE TABLE t` run twice fails with 42P07, `ALTER TABLE ADD COLUMN c` with
42701, `CREATE INDEX i` with 42P07, `DROP TABLE t` with 42P01. Any redelivery
of a DDL transaction therefore turns into a data-fault exception:

- `transdiscard` (default): the redelivered transaction is discarded. The data
  is not harmed (the first apply committed it), but an `exception_log` row
  appears for an operation that did not fail, and S2-style "every difference
  is explained by exception_log" oracles get noise.
- `sub_disable` (TAP harness default, and a planned run variant): the
  subscription is **disabled** and needs an operator, although nothing is
  wrong. Replication from that provider stops.
- If the DDL transaction also carried DML from the same origin (DDL and DML
  can share a transaction, `src/spock_queue.c` writes the queue row in the
  DDL's transaction), that DML is handled the same way; under TRANSDISCARD
  that is fine because it was already applied once.

## Mechanism (code-checked)

- Provider: DDL text is inserted into `spock.queue` in the same transaction
  as the DDL (`queue_message`, `src/spock_queue.c`). The output plugin sends
  it as an INSERT into `spock.queue`.
- Subscriber: `handle_insert` applies the row into `spock.queue` (the table has
  **no primary key**, `sql/spock--6.0.0.sql:598-604`, so a redelivered queue
  row is inserted again, no conflict) and then, because the relation is
  `QueueRelid`, calls `handle_queued_message` (`src/spock_apply.c:1715-1745`).
- `handle_queued_message` (`:2862-2898`) -> `handle_sql_or_exception`
  (`:2754-2860`) -> `handle_sql` -> `spock_execute_sql_command`
  (`:4285-...`). Nothing checks whether this queue entry was already executed
  (no `queued_at`/origin dedup). The SQL is run again.
- The error is not on the transient list (`apply_work` PG_CATCH,
  `:3917-3992`), so it takes the exception path.
- `QUEUE_COMMAND_TYPE_TABLESYNC` is idempotent (`handle_table_sync` skips a
  table already being synced, `:2546-2566`). `QUEUE_COMMAND_TYPE_SEQUENCE` is a
  `setval` (re-running it sets the same value; sequences are out of scope,
  sut-analysis S11).

Redelivery sources:

- **L1** (crash redo advances the node-id origin, not the subscription's
  origin): a subscriber kill -9 between checkpoints re-sends every transaction
  not yet confirmed to the provider.
- **L19** forwarded-origin advance after commit (cascade only).
- ZODAN add_node, if the Phase 7 slot/origin positions for a peer end below
  what the new node already has from COPY (S13 "no duplicates").

## Workload design

- DDL only in quiesced phases (sut-analysis §12): stop writes, run
  `spock.replicate_ddl('ALTER TABLE ... ADD COLUMN ...')` or a `CREATE TABLE`,
  barrier all pairs, resume writes.
- Faults (crashes) may land at any time, including right after a DDL phase.
  To make the window likely, a test command can kill a subscriber postmaster
  shortly after the DDL barrier returns (the barrier reads the in-memory
  origin, which is what rewinds under L1).
- Check (Always, workload): after quiescence, `spock.exception_log` has no row
  with `ddl_statement IS NOT NULL` and an `error_message` matching
  "already exists" / "does not exist" (SQLSTATE 42P07, 42701, 42710, 42P01,
  42704), and no subscription has `sub_enabled = false` unless the workload
  disabled it.

## Assertion choice

`Always` in the workload. The workload controls all DDL and runs it only when
quiesced, so a DDL "already exists" error on a subscriber can only come from
redelivery.

## SUT-side instrumentation (missing; no existing assertions)

- In `handle_sql_or_exception` / the PG_CATCH first-exception branch, when
  `errcallback_arg.action_name` is `QUEUED_SQL` and the SQLSTATE is in class
  42 "duplicate object" (42P07, 42701, 42710, 42P06):
  `Unreachable("replicated DDL failed because its object already exists")`.
  Useful because the workload check only sees the end state, while this marks
  the exact redelivery moment for triage.

## What happens on redelivery, by exception mode (code-checked)

The first attempt always runs the DDL (no `use_try_block`), fails, and goes
through `apply_work`'s PG_CATCH -> `AbortOutOfAnyTransaction` -> in-process
replay (`src/spock_apply.c:4060-4135`). On the replay pass
(`handle_sql_or_exception`, `:2771-2840`):

- TRANSDISCARD / SUB_DISABLE: the DDL is **not run again**; its text is
  extracted and (unless `spock.exception_logging = none`) an `exception_log`
  row is written with `operation = 'SQL'`,
  `ddl_statement` set and the first error message (42P07 etc.). SUB_DISABLE
  then disables the subscription.
- DISCARD: the DDL runs again in a subtransaction, fails again, is rolled
  back and logged with `operation = 'SQL'`; the rest of the transaction is
  applied (again).

So the workload check (`ddl_statement IS NOT NULL` and a 42xxx "already
exists / does not exist" message) matches what the code writes. DDL that is
idempotent as written (`IF NOT EXISTS`, `CREATE OR REPLACE`) will not show a
redelivery; the workload must use plain, non-idempotent DDL.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (implementability CW7/CW4, wildcard W2); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 · Faults: node kill after a DDL phase

- Evaluation note (2026-10-13): split into "re-sent DDL failed on a node that crashed since the DDL and shows a node-id origin state" (explained by L1) and "re-sent DDL failed, unexplained". The kill after a DDL barrier and before a checkpoint comes from the crash helper.
- The SQLSTATE list in the invariant is now matched as message text ("already exists" / "does not exist") because `spock.exception_log` has no SQLSTATE column (`sql/spock--6.0.0.sql:54-73`); the harness pins `lc_messages = 'C'`.

## Gap-fill extensions (2026-10-13)

From the gap-fill step; see `discovery/gap-c-provider-dml.md` and `evaluation/synthesis.md`.

- DDL-then-DML: in each DDL phase add same-origin pairs "ADD COLUMN, then
  DML that writes the new column" on a ledger-checked table. Same-origin
  order is guaranteed (the DDL is queued in the same transaction stream),
  so a lost or doubly applied DDL shows up as missing DML rows on the peer
  (counted by `committed-ledger-row-reaches-every-node`), not only as a
  42-class exception row. Lock-timeout and deadlock errors on queued DDL
  are retried (`src/spock_apply.c:3966-3972`), so they are not a cause.

## Open questions

- Is redelivery of a DDL transaction expected by the team, and should DDL apply be made idempotent (record applied queue entries) or should redelivery be prevented? `(needs human input)`
- Should 42P07-class errors on queued DDL be treated as "already applied" rather than as data faults? (Changing that would hide a genuinely diverged schema; the answer decides whether the property should allow such rows when the schema matches.) `(needs human input)`

### Investigation Log

#### Is redelivery of a DDL transaction possible (is L1 real on PG18)?

- Examined: `src/spock_apply.c:1322-1333` (`handle_origin` sets
  `replorigin_session_origin = remote_origin_id`), `:4744-4750` (session
  set up on the slot-named origin), `src/spock_output_plugin.c:501, 524,
  596-635` (`forward_changeset_origins` is always set to true, so every
  transaction carries an origin message, including the provider's own);
  PostgreSQL `xact.c` commit redo (`replorigin_advance(origin_id, ...)` at
  `:6162`, `:6285`; local REL_17_STABLE tree used as a stand-in for 18);
  `patches/18/*.diff` (the only xact.c change, `pg18-025`, adds a
  logical-clock record and does not touch origin redo);
  `docs/internals-doc/specs/spock-progress-no-checkpoint-hook-design.md`
  (states that `pg_commit_ts` records the publisher's node id because of
  `handle_origin`); `src/spock_progress_recovery.c` (reconciles only the
  monitoring entry against the origin LSN; it does not move the origin).
- Found: commit records carry the publisher's node id as origin, so crash
  redo advances an origin numbered by that id, while the subscription's
  slot-named origin is durable only as of the last checkpoint. After a
  subscriber kill -9 between checkpoints, the worker resumes from the older
  value, and the provider re-sends whatever it has not had confirmed
  (feedback reports flushed positions only). Any queued DDL in that range is
  run again. Nothing on the apply side checks whether a queue entry was
  already run (no handling of 42P07/42701/42710/42P01 anywhere in `src/`
  apply code).
- Not found: a runtime confirmation (no cluster runs in this pass), and
  whether the team considers this redelivery window acceptable.
- Conclusion: `(needs human input)` for the design choice. By code reading
  the redelivery is possible, so the property is expected to be reachable
  with a subscriber kill between checkpoints, not only a guard.

#### Should 42P07-class errors on queued DDL be treated as "already applied"?

- Examined: `grep` for `DUPLICATE_TABLE` / `DUPLICATE_OBJECT` /
  `DUPLICATE_COLUMN` / `42P07` in `src/` (only `spock_sync.c:446`, which
  is structure sync, not apply); `handle_sql_or_exception`; `spock.queue`
  definition (`sql/spock--6.0.0.sql:598-604`, no applied marker).
- Found: no special handling; these errors take the normal exception path.
- Conclusion: `(needs human input)`: a design decision. The property stays
  `Always` "no such row" until the team decides.
