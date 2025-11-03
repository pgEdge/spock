# Spock Release Notes

## Spock 5.1 on xxx

This release deprecates the spock.exception_replay_queue_size GUC. Previously Spock restored transaction changes up to the size defined by the spock.exception_replay_queue_size GUC. If an error occurred, the transaction was replayed, and if the size was less than the exception queue, the cache was used. If the size was greater than the limit, it was resent from the origin.

Now no restriction exists. Spock will use memory until memory is exhausted (improving performance for huge transactions). If an allocation fails, Spock performs as specified by the spock.exception_behavior GUC:
- 'discard': Skip failed transaction and continue
- 'transdiscard': Rollback transaction and continue
- 'sub_disable': Disable subscription and exit cleanly

* Change Spock replication health tracking routines and views: apply_group_progress, spock.progress, and spock.lag_tracker.
  - rename last_received_lsn with commit_lsn to more precisely identify the underlying value.
  - introduce received_lsn - points to the last LSN, sent by the publisher, exactly like pgoutput protocol do.
  - remote_insert_lsn reported more frequently, on each incoming WAL record, not only on a COMMIT, as it was before.
## Spock 5.0.4 on Oct 8, 2025

* Reduce memory usage for transactions with many inserts.
* When a subscriber’s apply worker updates a row that came from the same origin, spock will no longer log it in the `spock.resolutions` table, reversing behavior that has been in place since 5.0.0.
  - Improved handling to block replicating DDL when adding an extension.
  - Improved documentation
  - Zero Downtime Add Node Improvements:
    - New health checks and verifications (ex: version compatibility) before and during the add node process.
    - New remove node SQL procedure (`spock.remove_node()` in samples/Z0DAN/zodremove.sql) and python script (samples/Z0DAN/zodremove.py). This also handles removing nodes that were partially added when the user decided to undo this work.
    - Handle DSN strings that contain quotes.

- Bug fixes:
    - Log messages containing credentials will now obfuscate password information.
    - Fix bug when the subscriber receives DML for tables that do not exist. This case will be handled according to the configured `spock.exception_behaviour` setting (`SUB_DISABLE`, `DISCARD`, `TRANSDISCARD`).
    - Fix bug where spock incorrectly outputs a message that DDL was replicated when a transaction is executing in repair mode.


## v5.0.3 on Sep 26, 2025

* Spock 5.0.3 adds support for Postgres 18.
* When using row filters with Postgres 18 such as in the functions spock.repset_add_table() or spock.repset_add_partition(), allowable filters are now stricter. Expressions may not use UDFs nor reference another table, similar to native logical replication in Postgres.

## v5.0.2 on Sept 22, 2025

* Improved logging for all Zodan phases in both the stored procedure and Python examples.
* You can use the new Zodan skip_schema parameter to exclude schemas when you're adding a node, preventing local extension metadata from being copied.
    * Added skip_schema option to sub_create. When synchronize_structure = true, schemas listed in skip_schema are not synced.
    * dblink-based stored procedure for add node leverages skip_schema to skip preexisting schemas on the new node, avoiding failures on already existing schemas.
    * Python add_node now mirrors stored procedure semantics, including skip_schema handling, structure sync, and logging. It works as a direct alternative to the procedure and no longer requires the dblink extension.
* Spock has been updated to use the PostgreSQL License.


## v5.0.1 on Aug 27, 2025

* Bug fix for an incorrect commit timestamp being used for the case of updating a row that was inserted in the same transaction. A consequence was possible incorrect resolution handling for updates.
* Use the default search_path in the replicate_ddl() function.
* Prevent false positives for conflict detection when using partial unique indexes.
* New sample files for adding nodes with zero downtime.
    * Python example
    * Added enhanced add node support in stored procedures in samples/zodan.sql
        * Add a second node when there is only one node.
        * Extended support for adding 3rd, 4th and subsequent nodes.
        * Chain adding new nodes off of the previously added new node (eg: add N2 off N1, then add N3 off N2).

## v5.0 on July 15, 2025

* Spock functions and stored procedures now support node additions and major PostgreSQL version.  This means:
    * existing nodes are able to maintain full read and write capability while a new node is populated and added to the cluster.
    * You can perform PostgreSQL major version upgrades as a rolling upgrade by adding a new node with the new major PostgreSQL version, and then removing old nodes hosting the previous version.
* Exception handling performance improvements are now managed with the spock.exception_replay_queue_size GUC.
* Previously, replication lag was estimated on the source node; this meant that if there were no transactions being replicated, the reported lag could continue to increase.  Lag tracking is now calculated at the target node, with improved accuracy.
* Spock 5.0 implements LSN Checkpointing with `spock.sync()` and `spock.wait_for_sync_event()`.  This feature allows you to identify a checkpoint in the source node WAL files, and watch for the LSN of the checkpoint on a replica node.  This allows you to guarantee that a DDL change, has replicated from the source node to all other nodes before publishing an update.
* The `spockctrl` command line utility and sample workflows simplify the management of a Spock multi-master replication setup for PostgreSQL. `spockctrl` provides a convenient interface for:
    * node management
    * replication set management
    * subscription management
    * ad-hoc SQL execution
    * workflow automation
* Previously, replicated `DELETE` statements that attempted to delete a *missing* row were logged as exceptions.  Since the purpose of a `DELETE` statement is to remove a row, we no longer log these as exceptions. Instead these are now logged in the `Resolutions` table.
* `INSERT` conflicts resulting from a duplicate primary key or identity replica are now transformed into an `UPDATE` that updates all columns of the existing row, using Last-Write-Wins (LWW) logic.  The transaction is then logged in the node’s `Resolutions` table, as either:
    * `keep local` if the local node’s `INSERT` has a later timestamp than the arriving `INSERT`
    * `apply remote` if the arriving `INSERT` from the remote node had a later timestamp
* In a cluster composed of distributed and physical replica nodes, Spock 5.0 improves performance by tracking the Log Sequence Numbers (LSNs) of transactions that have been applied locally but are still waiting for confirmation from physical replicas.  A final `COMMIT` confirmation is provided only after those LSNs are confirmed on the physical replica.
This provides a two-phase acknowledgment:
   * Once when the target node has received and applied the transaction.
   * Once when the physical replica confirms the commit.
* The `spock.check_all_uc_indexes` GUC is an experimental feature (`disabled` by default); use this feature at your own risk.  If this GUC is `enabled`, Spock will continue to check unique constraint indexes, after checking the primary key / replica identity index.  Only one conflict will be resolved, using Last-Write-Wins logic.  If a second conflict occurs, an exception is recorded in the `spock.exception_log` table.


## Version 4.1
* Hardening Parallel Slots for OLTP production use.
  - Commit Order
  - Skip LSN
  - Optionally stop replicating in an Error
* Enhancements to Automatic DDL replication

## Version 4.0

* Full re-work of paralell slots implementation to support mixed OLTP workloads
* Improved support for delta_apply columns to support various data types
* Improved regression test coverage
* Support for [Large Object LOgical Replication](https://github.com/pgedge/lolor)
* Support for pg17

Our current production version is v3.3 and includes the following enhancements over v3.2:

* Automatic replication of DDL statements

## Version 3.2

* Support for pg14
* Support for [Snowflake Sequences](https://github.com/pgedge/snowflake)
* Support for setting a database to ReadOnly
* A couple small bug fixes from pgLogical
* Native support for Failover Slots via integrating pg_failover_slots extension
* Parallel slots support for insert only workloads

## Version 3.1

* Support for both pg15 *and* pg16
* Prelim testing for online upgrades between pg15 & pg16
* Regression testing improvements
* Improved support for in-region shadow nodes (in different AZ's)
* Improved and document support for replication and maintaining partitioned tables.


**Version 3.0 (Beta)** includes the following important enhancements beyond the BDR/pg_logical base:

* Support for pg15 (support for pg10 thru pg14 dropped)
* Support for Asynchronous Multi-Master Replication with conflict resolution
* Conflict-free delta-apply columns
* Replication of partitioned tables (to help support geo-sharding)
* Making database clusters location aware (to help support geo-sharding)
* Better error handling for conflict resolution
* Better management & monitoring stats and integration
* A 'pii' table for making it easy for personally identifiable data to be kept in country
* Better support for minimizing system interuption during switch-over and failover
