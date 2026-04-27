# Spock Release Notes

## Spock 5.0.7

### New Features

Logical Slot Failover Improvements

* On **PostgreSQL 17+**, Spock now creates all logical replication slots with
  the `FAILOVER` flag, allowing PostgreSQL's built-in slotsync worker
  (`sync_replication_slots = on`) to automatically synchronize them to
  physical standbys.
* On **PostgreSQL 18+**, Spock's own `spock_failover_slots` background worker
  is no longer registered. The native PostgreSQL slotsync worker fully
  replaces it. See the [Logical Slot Failover](configuring.md#logical-slot-failover-ha-standby)
  section in the configuration guide for required `postgresql.conf` settings.
* On **PostgreSQL 17**, Spock's worker remains active but automatically yields
  to the native slotsync worker if `sync_replication_slots = on` is set,
  preventing conflicts.

### Bug Fixes
* Preserve the original error message in `spock.exception_log` when applying
  in `TRANSDISCARD` or `SUB_DISABLE` mode. Previously the original error was
  written only to the server log and lost before the retry pass; every row in
  the discarded transaction was logged with `error_message = NULL` (stored as
  "unknown"). The originally-failing row now carries the real error message,
  while the bystander rows in the same transaction are recorded as
  "unavailable" instead of the misleading "unknown" fallback.
* Fix missing data when adding a new node. An apply worker that committed
  between `ensure_replication_slot_snapshot` and `adjust_progress_info` could
  advance `spock.progress` past the COPY snapshot boundary, causing the new
  node to permanently skip those changes. Apply workers are now paused via an
  atomic flag and condition variable in `SpockContext` for the duration of
  slot creation and resumed once `adjust_progress_info` completes.
* Fix apply worker crash with `epoll_ctl() failed: Invalid argument` after a
  provider connection died. The socket fd captured before `stream_replay:`
  was never refreshed, so a stale fd was passed to `WaitLatchOrSocket` on
  re-entry. The fd is now refreshed at `stream_replay:` and the worker exits
  cleanly so the postmaster can restart and reconnect it.
* Fix PG15/16 failover slot loss on promotion: reconnect with retry and guard
  against a zero WAL flush LSN.
* ZODAN: `create_sub_on_new_node_to_src_node` (Phase 9 of `add_node`) was
  generating subscription names as `sub_{subscriber}_{provider}` instead of
  the expected `sub_{provider}_{subscriber}` convention, causing
  `remove_node` to fail when looking up subscriptions by name (SPOC-503). A
  new `spock.gen_sub_name(provider_node, subscriber_node)` helper is now used
  in place of inline name concatenations.
* ZODAN: the `remove_node` cleanup loop tried to drop subscriptions by
  guessing names and nodes, which broke whenever `cross_wire` and `add_node`
  used different naming conventions. It now performs a per-node `DROP` of
  every subscription read directly from the `spock.subscription` catalog.

### Operational Improvements
* ZODAN now uses the 5-argument form of `wait_for_sync_event` with explicit
  timeout-result checking and raises an `EXCEPTION` on timeout or failure.
* Documentation: filled out `snowflake.md`; revised `upgrading_spock.md`;
  fixed event-trigger syntax (`EXECUTE FUNCTION` instead of the deprecated
  `EXECUTE PROCEDURE`); standardized function-reference filenames to match
  function names exactly; removed obsolete `batch_inserts.md` (SPOC-493).
* Test infrastructure aligned with `main`: `run_tests.sh` and `SpockTest.pm`
  now use absolute `TESTLOGDIR` paths, derive per-test log filenames, and
  isolate `psql` from a developer's `psqlrc`/history. New regression tests
  added for failover slots (018), exception-handling/TRANSDISCARD error
  quality (013), and the stale-fd-after-connection-death scenario (019).

## Spock 5.0.6

### New Features
* New `spock.feedback_frequency` GUC that controls how often feedback is sent
  to the WAL sender. Feedback is sent every *n* messages, where *n* is the
  configured value. Note that feedback is also sent every
  wal_sender_feedback / 2 seconds.
* New `spock.log_origin_change` GUC to control logging of row origin changes
  to the PostgreSQL log. Origin changes caused by replication are no longer
  written to the `spock.resolutions` table, as they are informational and not
  true conflicts. Three modes are available:
    * `none` — Do not log origin changes (default)
    * `remote_only_differs` — Log only when a row from one remote publisher
      is updated by a different remote publisher
    * `since_sub_creation` — Log origin changes for tuples modified after
      subscription creation (suppresses noise from pg_restored data)
* New `sub_created_at` column on `spock.subscription` to help distinguish
  pre-existing data (e.g. from pg_restore) from post-subscription data.
* COPY TO is considered read-only and can now be run when a node is in
  read-only mode.

### Performance Improvements
* Deferred `spock.progress` catalog writes. The progress table was previously
  updated on every committed transaction and every keepalive, causing
  significant table bloat and I/O overhead. Progress catalog writes are now
  batched and flushed at most once per second from the main apply loop.
  Shared memory is still updated immediately internally for correctness.

### Bug Fixes
* Fix initdb assertion failure in attoptions patch for PG15/16/17.
* Fix two bugs in the table re-sync routine: WAL sending is now switched off
  during truncate and re-sync to prevent data loss, and the infinite wait was
  fixed when no more DML is committed by using the last committed LSN instead
  of the last received LSN.
* Use NULL for unknown `local_origin` in `spock.resolutions` instead of an
  invalid origin ID when origin cannot be determined (e.g. pg_dump, frozen
  transactions, truncated commit timestamps). Also fixed off-by-one errors in
  `spock_conflict_row_to_json()` that were overwriting the `local_origin`
  NULL flag.
* Fix Z0DAN initialization issue: `present_final_cluster_state` now executes
  a COMMIT to allow newly created subscriptions to update their state, and
  final cluster state now checks all subscriptions across the cluster.
* Suppress hot_standby_feedback off error messages in log in case a read
  replica is used for reporting and not failover (it is required for
  failover).
* Fix bug when applying changes to a table that has been dropped.

### Operational Improvements
* `add_node` is now restricted to run only on a new (uninitialized) node,
  preventing accidental misuse.

## Spock 5.0.5 on Feb 12, 2026

* Fix segfault that occurs when using new Postgres minor releases like 18.2.
* Zero Downtime Add Node (Zodan) minor bug fixes and improvements
* Updated documentation

## Spock 5.0.4 on Oct 8, 2025

* Reduce memory usage for transactions with many inserts.
* When a subscriber’s apply worker updates a row that came from the same
  origin, spock will no longer log it in the `spock.resolutions` table,
  reversing behavior that has been in place since 5.0.0.
  - Improved handling to block replicating DDL when adding an extension.
  - Improved documentation
  - Zero Downtime Add Node Improvements:
    - New health checks and verifications (ex: version compatibility) before
      and during the add node process.
    - New remove node SQL procedure (`spock.remove_node()` in
      samples/Z0DAN/zodremove.sql) and python script
      (samples/Z0DAN/zodremove.py). This also handles removing nodes that
      were partially added when the user decided to undo this work.
    - Handle DSN strings that contain quotes.

- Bug fixes:
    - Log messages containing credentials will now obfuscate password
      information.
    - Fix bug when the subscriber receives DML for tables that do not exist.
      This case will be handled according to the configured
      `spock.exception_behaviour` setting (`SUB_DISABLE`, `DISCARD`,
      `TRANSDISCARD`).
    - Fix bug where spock incorrectly outputs a message that DDL was
      replicated when a transaction is executing in repair mode.


## v5.0.3 on Sep 26, 2025

* Spock 5.0.3 adds support for Postgres 18.
* When using row filters with Postgres 18 such as in the functions
  spock.repset_add_table() or spock.repset_add_partition(), allowable filters
  are now stricter. Expressions may not use UDFs nor reference another table,
  similar to native logical replication in Postgres.

## v5.0.2 on Sept 22, 2025

* Improved logging for all Zodan phases in both the stored procedure and
  Python examples.
* You can use the new Zodan skip_schema parameter to exclude schemas when
  you're adding a node, preventing local extension metadata from being copied.
    * Added skip_schema option to sub_create. When synchronize_structure =
      true, schemas listed in skip_schema are not synced.
    * dblink-based stored procedure for add node leverages skip_schema to
      skip preexisting schemas on the new node, avoiding failures on already
      existing schemas.
    * Python add_node now mirrors stored procedure semantics, including
      skip_schema handling, structure sync, and logging. It works as a direct
      alternative to the procedure and no longer requires the dblink
      extension.
* Spock has been updated to use the PostgreSQL License.


## v5.0.1 on Aug 27, 2025

* Bug fix for an incorrect commit timestamp being used for the case of
  updating a row that was inserted in the same transaction. A consequence was
  possible incorrect resolution handling for updates.
* Use the default search_path in the replicate_ddl() function.
* Prevent false positives for conflict detection when using partial unique
  indexes.
* New sample files for adding nodes with zero downtime.
    * Python example
    * Added enhanced add node support in stored procedures in
      samples/zodan.sql
        * Add a second node when there is only one node.
        * Extended support for adding 3rd, 4th and subsequent nodes.
        * Chain adding new nodes off of the previously added new node (eg:
          add N2 off N1, then add N3 off N2).

## v5.0 on July 15, 2025

* Spock functions and stored procedures now support node additions and major
  PostgreSQL version. This means:
    * existing nodes are able to maintain full read and write capability
      while a new node is populated and added to the cluster.
    * You can perform PostgreSQL major version upgrades as a rolling upgrade
      by adding a new node with the new major PostgreSQL version, and then
      removing old nodes hosting the previous version.
* Exception handling performance improvements are now managed with the
  spock.exception_replay_queue_size GUC.
* Previously, replication lag was estimated on the source node; this meant
  that if there were no transactions being replicated, the reported lag could
  continue to increase. Lag tracking is now calculated at the target node,
  with improved accuracy.
* Spock 5.0 implements LSN Checkpointing with `spock.sync()` and
  `spock.wait_for_sync_event()`. This feature allows you to identify a
  checkpoint in the source node WAL files, and watch for the LSN of the
  checkpoint on a replica node. This allows you to guarantee that a DDL
  change, has replicated from the source node to all other nodes before
  publishing an update.
* The `spockctrl` command line utility and sample workflows simplify the
  management of a Spock multi-master replication setup for PostgreSQL.
  `spockctrl` provides a convenient interface for:
    * node management
    * replication set management
    * subscription management
    * ad-hoc SQL execution
    * workflow automation
* Previously, replicated `DELETE` statements that attempted to delete a
  *missing* row were logged as exceptions. Since the purpose of a `DELETE`
  statement is to remove a row, we no longer log these as exceptions. Instead
  these are now logged in the `Resolutions` table.
* `INSERT` conflicts resulting from a duplicate primary key or identity
  replica are now transformed into an `UPDATE` that updates all columns of
  the existing row, using Last-Write-Wins (LWW) logic. The transaction is
  then logged in the node’s `Resolutions` table, as either:
    * `keep local` if the local node’s `INSERT` has a later timestamp than
      the arriving `INSERT`
    * `apply remote` if the arriving `INSERT` from the remote node had a
      later timestamp
* In a cluster composed of distributed and physical replica nodes, Spock 5.0
  improves performance by tracking the Log Sequence Numbers (LSNs) of
  transactions that have been applied locally but are still waiting for
  confirmation from physical replicas. A final `COMMIT` confirmation is
  provided only after those LSNs are confirmed on the physical replica. This
  provides a two-phase acknowledgment:
   * Once when the target node has received and applied the transaction.
   * Once when the physical replica confirms the commit.
* The `spock.check_all_uc_indexes` GUC is an experimental feature (`disabled`
  by default); use this feature at your own risk. If this GUC is `enabled`,
  Spock will continue to check unique constraint indexes, after checking the
  primary key / replica identity index. Only one conflict will be resolved,
  using Last-Write-Wins logic. If a second conflict occurs, an exception is
  recorded in the `spock.exception_log` table.


## Version 4.1
* Hardening Parallel Slots for OLTP production use.
  - Commit Order
  - Skip LSN
  - Optionally stop replicating in an Error
* Enhancements to Automatic DDL replication

## Version 4.0

* Full re-work of paralell slots implementation to support mixed OLTP
  workloads
* Improved support for delta_apply columns to support various data types
* Improved regression test coverage
* Support for
  [Large Object LOgical Replication](https://github.com/pgedge/lolor)
* Support for pg17

Our current production version is v3.3 and includes the following
enhancements over v3.2:

* Automatic replication of DDL statements

## Version 3.2

* Support for pg14
* Support for [Snowflake Sequences](https://github.com/pgedge/snowflake)
* Support for setting a database to ReadOnly
* A couple small bug fixes from pgLogical
* Native support for Failover Slots via integrating pg_failover_slots
  extension
* Parallel slots support for insert only workloads

## Version 3.1

* Support for both pg15 *and* pg16
* Prelim testing for online upgrades between pg15 & pg16
* Regression testing improvements
* Improved support for in-region shadow nodes (in different AZ's)
* Improved and document support for replication and maintaining partitioned
  tables.

**Version 3.0 (Beta)** includes the following important enhancements beyond
the BDR/pg_logical base:

* Support for pg15 (support for pg10 thru pg14 dropped)
* Support for Asynchronous Multi-Master Replication with conflict resolution
* Conflict-free delta-apply columns
* Replication of partitioned tables (to help support geo-sharding)
* Making database clusters location aware (to help support geo-sharding)
* Better error handling for conflict resolution
* Better management & monitoring stats and integration
* A 'pii' table for making it easy for personally identifiable data to be
  kept in country
* Better support for minimizing system interuption during switch-over and
  failover
