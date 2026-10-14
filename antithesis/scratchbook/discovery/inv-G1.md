# Open-question investigation, group G1

PG source used: `~/dev/pgedge/postgresql` (REL_18_STABLE 18.3 with the pgEdge
patches applied in the working tree) and `~/dev/pg/postgresql` (stock 17.10).

## committed-ledger-row-reaches-every-node
- resolved: unknown-outcome commits (decide by reading the origin node after it returns; then "same on every node as on origin"); `sub_disable` is not loss (origin not advanced past the failing txn, `src/spock_apply.c:996-1009, 1067-1084`), so report a disabled sub through its own Always, re-enable, re-check.
- remaining: none
- property changed?: yes — prose refinement of the oracle (unknown commits decided by origin; sub_disable handling in check phase). Invariant and Always unchanged.
- invalidated?: no

## ledger-row-applied-exactly-once-per-peer
- resolved: PG18 patched redo advances `XLogRecGetOrigin(record)` like PG17 (`xact.c:6255-6259`; patch 025 does not touch it), so L1 exists on the target; redo-created node-id states each need a free `max_active_replication_origins` slot (default 10), ERROR in startup stops recovery, states persist forever; TRANSDISCARD redelivery shows only as a second set of `exception_log` rows (same remote_origin, remote_commit_ts, command_counter; new retry_errored_at), never in resolutions.
- remaining:
  - Does the team intend exactly-once or at-least-once on direct subscriptions? `(needs human input)`
- property changed?: yes — add a companion workload Always "no two exception_log rows share (remote_origin, remote_commit_ts, command_counter)"; harness should set `max_active_replication_origins` = 32. Side finding: a node id equal to a local roident would make redo advance the wrong subscription forward (loss).
- invalidated?: no

## delta-counter-equals-committed-increments
- resolved: unknown-outcome commits (marker row in the same txn, read on the origin after it returns; check stays exact).
- remaining:
  - Does the team treat at-least-once on direct subscriptions as a bug? `(needs human input)`
- property changed?: yes — prose refinement (marker-row oracle replaces range check).
- invalidated?: no

## causally-deleted-row-stays-deleted
- resolved: PG18 redo question (yes, L1 exists); unconfirmed window: up to `wal_sender_timeout/2` (30 s default) on a quiet provider, about walwriter delay with steady provider WAL (Spock sends no timed feedback; walsender's caught-up ping gets an early reply before the async commit is flushed, then sleeps).
- remaining:
  - Does the team treat at-least-once as acceptable for direct subscriptions? `(needs human input)`
- property changed?: no (fault-timing notes added: kill S within wal_sender_timeout/2 after a burst; don't lower wal_sender_timeout).
- invalidated?: no

## remote-transaction-all-or-nothing-per-node
- resolved: skipping changes for a FAILED table is intended (6a063b22, `src/spock_apply.c:4500-4507`, regress `sync_table.sql`); initial subscription sync copies all tables under one snapshot in one target transaction.
- remaining:
  - Should an infrastructure fault during a single-table resync (connection loss, worker or node kill) leave the table FAILED with its changes skipped until an operator resyncs? `(needs human input)`
- property changed?: yes — suggested SUT assertion changed from `Unreachable("apply skipped a change for a FAILED table")` to a `Sometimes` coverage marker, plus `Reachable` at the FAILED branch in `spock_sync_table`; suggests a separate property that a resync started under faults ends `r`. Finding: any restart of a table-sync worker after STARTED yields FAILED (`src/spock_sync.c:1846-1875`), not only data errors.
- invalidated?: no

## graceful-restart-preserves-exactly-once
- resolved: helper does not exist yet (harness not built; two designs written down); smart shutdown waits for all client backends including peers' plain connections, so fast only; logical walsender on a stopping node waits for subscriber flush confirm, bounded by `wal_sender_timeout` (`WalSndDone`, `walsender.c:3521-3550`).
- remaining: none at code level (helper must be built with the harness).
- property changed?: no (fault requirements made concrete: supervisor loop in node container so pg_ctl stop doesn't end the container).
- invalidated?: no

## no-change-applied-on-its-origin-node
- resolved: ORIGIN-less transactions cannot reach apply (native protocol always sends ORIGIN in v5 and v6; subscribers never request json). Node-id 0/65535 effects confirmed in code: id 0 -> one-hop echo onto the origin node and no origin progress; 65535 -> no echo but no origin progress (barriers hang, redelivery). `hashtext(name) & 65535` reproduces Spock's id.
- remaining:
  - Should node creation reject ids 0 and 65535? `(needs human input)`
- property changed?: yes — prose refinement: "loop" corrected to one extra hop; setup check that no node id is 0/65535 in the default template.
- invalidated?: no
