# Spock Release Notes

## Spock 6.0

The following describes the changes since Spock 5.0.7.

---

## Highlights

- **Catastrophic Node Failure Recovery** — New ACE-based recovery workflow with origin-preserving repair prevents silent data divergence after node loss.
- **Progress Tracking** — Replication progress moved from catalog tables to WAL + shared memory, eliminating heavyweight catalog writes in the apply hot path.
- **Exception Handling Improvements. Code refactored, made more stable and more detailed error messages are provided.
- **Delta Apply Reimplemented via Security Labels** — No longer requires PostgreSQL core patches; configuration replicates automatically across nodes.
- **More Granular Conflict Classification** — Seven conflict types (up from four) with smarter origin-aware suppression.
- **Per-Subscription Conflict Statistics** — New pgstat-based conflict counters on PostgreSQL 18+.
- **Liveness and Feedback Refactoring** — TCP-keepalive-based liveness replaces the fragile `wal_sender_timeout` workaround.
- **Rolling upgrade support** — Multi-protocol negotiation (Protocol 4 for v5.0.x, Protocol 5 for v6.0+) enables zero-downtime rolling upgrades.

---

## Catastrophic Node Failure Recovery

Spock 6.0 documents and supports a structured recovery workflow for the scenario where a node fails permanently and one or more surviving nodes are lagging behind. Using the [Active Consistency Engine (ACE)](https://github.com/pgEdge/ace), operators can:

1. Identify which rows are missing on lagging survivors using `table-diff --preserve-origin`.
2. Repair the lagging node from a fully-synchronized survivor using `table-repair --recovery-mode --source-of-truth --preserve-origin`.

The `--preserve-origin` flag is critical: it ensures that repaired rows retain their original origin ID and commit timestamp, so replication metadata stays correct and the cluster remains conflict-free. Without it, repaired rows would appear as local changes and could trigger false conflicts.

Both single-node and multi-node failure scenarios are covered. See `docs/recovery/catastrophic_node_failure.md` for the full guide.

---

## Spock Progress Tracking

Replication progress is no longer tracked in the `spock.progress` catalog table. Instead, Spock tracks it in shared memory and exposes changes as a view.

- Maintains apply progress in shared memory, eliminating catalog writes from the apply hot path.
- Logs progress to WAL via resource manager so it survives crash recovery.
- Persists a snapshot to `$PGDATA/spock/resource.dat` on clean shutdown.
- Integrates with PostgreSQL's checkpoint mechanism via a checkpoint hook — at each checkpoint, group data and per-group progress records are emitted to WAL.

The `spock.progress` view is retained for compatibility but is now backed by a set-returning function reading from shared memory.

---

## Exception Handling Improvements

- Fixed TRANSDISCARD/SUB_DISABLE handling during the commit phase in retry mode, preventing apply worker death loops.
- Eliminated "(unknown action)" in error context strings and NULL error messages in `exception_log`, making troubleshooting issues much easier.
- Added `initial_operation` field to track which DML operation caused a transaction discard.
- Subscriptions stuck in an unrecoverable synchronization stage are now disabled rather than restarted indefinitely.

---

## Delta Apply Reimplemented via Security Labels

The delta-apply feature (which computes column deltas rather than overwriting values) has been completely reimplemented:

| Aspect | v5.0 | v6.0 |
|---|---|---|
| Configuration mechanism | PostgreSQL core patches adding `attoptions` (`log_old_value`, `delta_apply_function`) | PostgreSQL security labels (`SECURITY LABEL FOR spock ON COLUMN ...`) |
| Core patches required | Yes (one per PG version) | No — pure extension |
| Cross-node replication | Manual setup required on each node | Automatic — `SECURITY LABEL` commands are replicated by AutoDDL |
| Nullable columns | Silently fell back to plain NEW value when OLD was NULL | Explicitly rejected as an error (`ERRCODE_NULL_VALUE_NOT_ALLOWED`) |
| Replica identity | Manual configuration | Automatically set to `REPLICA IDENTITY FULL` when delta_apply is enabled; reverted when the last label is removed |

Management functions:
- `spock.delta_apply(relation, column, function)` — enable delta apply.
- `spock.delta_apply_remove(relation, column)` — disable delta apply.

---

## More Granular Conflict Classification

v5.0 classified conflicts into four types. v6.0 expands this to seven, adopting PostgreSQL-native conflict type naming:

| v5.0 Type | v6.0 Type(s) | What Changed |
|---|---|---|
| `insert_exists` | `insert_exists` | No change |
| `update_update` | `update_exists` / `update_origin_differs` | Spock now distinguishes between an update arriving for a row whose local origin matches the incoming origin (suppressed silently) and an update where the local row's origin differs (evaluated through resolution). update_exists is used for update constraint violations. |
| `update_delete` | `update_missing` | Renamed for clarity |
| `delete_delete` | `delete_missing` / `delete_origin_differs` | Similar to updates — Spock now logs whether the missing row was last modified by a different origin. |
| *(new)* | `delete_exists` | A remote DELETE arrives, but the local row has been updated more recently than the delete's timestamp. The newer local version is preserved. |

**Migration**: Existing `spock.resolutions` data is automatically migrated (`update_update` → `update_exists`, `update_delete` → `update_missing`, `delete_delete` → `delete_missing`).

---

## Delete Operations Now Use Conflict Resolution

In v5.0, when a DELETE found a matching local row, it was applied immediately without consulting conflict resolution. In v6.0, DELETE operations go through timestamp-based resolution, just like updates. This enables the new `delete_exists` classification — Spock can determine whether a delete should be applied or whether a newer local version should be preserved.

---

## Cascade Replication Origin Tracking

v6.0 adds support for tracking and forwarding replication origins in cascade topologies (Node A → Node B → Node C). The origin name is now included in ORIGIN messages when the protocol version is 5 or higher. This ensures that conflict evaluation on Node C has accurate origin information even when changes pass through intermediate Node B.

---

## Per-Subscription Conflict Statistics

On PostgreSQL 18+, Spock registers a custom pgstat kind (`SPOCK_PGSTAT_KIND_LRCONFLICTS`) to count replication conflicts per subscription. New SQL functions:

- `spock.get_subscription_stats(oid)` — returns conflict counts by type.
- `spock.reset_subscription_stats(oid)` — resets counters.

On PostgreSQL versions before 18, these functions raise a feature-not-supported error.

---

## Memory and Stability Improvements

### Replay Queue Spill to Disk

The in-memory replay queue used during exception replay now spills to disk when it exceeds `spock.exception_replay_queue_size` (default 4 MB), instead of triggering a worker restart on overflow. This eliminates the unpredictable worker restarts and replication lag spikes that previously occurred with large transactions. The GUC retains its name but now controls the spill threshold rather than a hard cap.

### Resource Leak Fixes

- Fixed resource leaks in row filter processing that could cause the resource owner to grow very large when many rows are filtered out.
- Fixed memory leak in conflict reporting path (freed `remotetuple` after use).
- Fixed cleared-memory access in the COMMIT callback when `signal_workers` list was allocated in `TopTransactionContext` and accessed after abort — now allocated in `TopMemoryContext`.

---

## Bug Fixes

### WAL Recovery Crash After Apply Worker Failure

When an apply worker crashes and triggers a server restart, WAL recovery could fail due to improperly initialized shared memory structures. The shared memory initialization has been refactored to handle startup, checkpointer, and background worker processes correctly.

### Remote Insert LSN Lost After Crash Recovery

The `remote_insert_lsn` value was not included in WAL records and defaulted to 0 after crash recovery, breaking lag tracking in `spock.lag_tracker`. Now included in the custom WAL resource manager records.

### Replication Errors with Generated Columns

Tables containing generated columns (`GENERATED ALWAYS AS ... STORED`) caused replication errors — generated columns were treated as regular columns during COPY, protocol messages, default-value filling, and conflict resolution. Now properly excluded.

### Replica Index Lookup with REPLICA IDENTITY FULL

Cached index information was not invalidated before calling `RelationGetReplicaIndex()`, causing incorrect index usage when switching between replica identity modes.

### Hash Table Iteration Safety

Fixed multiple hash table safety issues: removal during iteration causing corruption, missing NULL checks for `HASH_FIXED_SIZE` tables, and torn reads of 64-bit counters without spinlock protection.

### Skip LSN Mechanism

A successfully skipped transaction in `SUB_DISABLE` mode would incorrectly disable the subscription again due to LSN mismatch between the skip point (BEGIN LSN) and the clear point (COMMIT LSN). Exception handling state is now cleared after a successful skip.

### Table Sync Failure Detection

Previously, COPY failures during table sync were silently swallowed and the sync worker retried indefinitely. Now `PQgetResult()` is called after `PQputCopyEnd()` to detect failures. A new `SYNC_STATUS_FAILED` state stops retry loops and surfaces clear error messages.

---

## AutoDDL Improvements

AutoDDL has been refactored and hardened across five commits:

- **Centralized in `spock_autoddl.c`**: All AutoDDL plumbing moved into a single module for maintainability.
- **Simplified control flow**: Dropped recursive tag-matching heuristic in favor of clearer early-exit filters.
- **Extension script guard**: Internal subcommands during `CREATE EXTENSION` / `ALTER EXTENSION UPDATE` are no longer replicated.
- **Transaction guards**: AutoDDL hook no longer fails when utility commands (e.g., `CLUSTER` without a table name) execute outside a transaction context.
- **Filtered non-transactional DDL**: Commands that cannot execute inside transaction blocks on subscribers (e.g., `CLUSTER` on partitioned tables, `VACUUM`) are filtered on the publisher side before being queued.

---

## Security Improvements

### DSN Password Obfuscation

Passwords in DSN connection strings are no longer visible in error messages or log output. A message filter hook wipes password characters from error messages before they are written.

---

## Read-Only Mode Refactoring

Read-only mode has been refactored to use PostgreSQL's native `DefaultXactReadOnly` mechanism instead of manual command-type filtering. Key changes:
- `READONLY_USER` renamed to `READONLY_LOCAL` (the old name is retained as a backward-compatible alias) to clarify that it restricts local (non-replication) connections.
- In `READONLY_ALL` mode, the apply worker sends keepalive feedback but skips applying new transactions.
- Read-only mode changes are detected before applying the next transaction (moved `CHECK_FOR_INTERRUPTS` to top of replay loop).

---

## Liveness and Feedback Refactoring

The `wal_sender_timeout`-based liveness mechanism has been replaced with a cleaner two-layer model:
- **TCP keepalive** as the primary liveness detector (detects dead network/host in ~25 seconds).
- **`wal_sender_timeout=0`** on replication connections so the walsender never disconnects due to missing feedback.
- **New GUC `spock.apply_idle_timeout`** (default 300s) as a subscriber-side safety net for hung-but-connected walsenders.

This replaces the `maybe_send_feedback()` workaround that coupled subscriber behavior to a server GUC it cannot control.

---

## ZODAN Data Loss Fix: Adding a Node Under Write Load

When adding a node while existing nodes were handling writes, the new node could possibly permanently miss rows or accumulate stale updates. The root cause was that apply workers were not paused during slot creation (sub-second operation), so the captured resume LSN could fall before the COPY boundary. The fix pauses apply workers during slot creation and captures the resume LSN deterministically.

---

## Other Notable Changes

- **New `spock.sub_alter_options()`** for bulk subscription option changes, with input validation and no-op restart skipping.
- **New `spock.resolutions_retention_days` GUC and `spock.cleanup_resolutions()` function** to bound the size of the `spock.resolutions` table.
- **`spock.batch_inserts` GUC removed** along with the multi-insert apply machinery.
- **Centralized shared memory initialization**: Refactored into a dedicated `spock_shmem.c` module with proper handling of multiple processes.
- **Progress view scoped to database**: `spock.progress` now shows data only for the current database.
- **Protocol cleanup**: Removed unused SPI API support from the Spock protocol. Fixed multiple protocol parameter validation issues.
- **Prevented adding tables from ignored schemas to replication sets.**
- **Snowflake removal**: Removed snowflake-related functions and documentation.
- **SpockCtrl removal**: Removed the SpockCtrl utility code.
- **PostgreSQL 18 support**: Compatibility work across core patches, initdb, row filters, and compiler warnings.
- **Source tree restructured** under `src/` and `include/` directories.

## Spock 5.0.6

### New Features
* New `spock.feedback_frequency` GUC that controls how often feedback is sent to the WAL sender. Feedback is sent every *n* messages, where *n* is the configured value. Note that feedback is also sent every wal_sender_feedback / 2 seconds.
* New `spock.log_origin_change` GUC to control logging of row origin changes to the PostgreSQL log. Origin changes caused by replication are no longer written to the `spock.resolutions` table, as they are informational and not true conflicts. Three modes are available:
    * `none` — Do not log origin changes (default)
    * `remote_only_differs` — Log only when a row from one remote publisher is updated by a different remote publisher
    * `since_sub_creation` — Log origin changes for tuples modified after subscription creation (suppresses noise from pg_restored data)
* New `sub_created_at` column on `spock.subscription` to help distinguish pre-existing data (e.g. from pg_restore) from post-subscription data.
* COPY TO is considered read-only and can now be run when a node is in read-only mode.

### Performance Improvements
* Deferred `spock.progress` catalog writes. The progress table was previously updated on every committed transaction and every keepalive, causing significant table bloat and I/O overhead. Progress catalog writes are now batched and flushed at most once per second from the main apply loop. Shared memory is still updated immediately internally for correctness.

### Bug Fixes
* Fix initdb assertion failure in attoptions patch for PG15/16/17.
* Fix two bugs in the table re-sync routine: WAL sending is now switched off during truncate and re-sync to prevent data loss, and the infinite wait was fixed when no more DML is committed by using the last committed LSN instead of the last received LSN.
* Use NULL for unknown `local_origin` in `spock.resolutions` instead of an invalid origin ID when origin cannot be determined (e.g. pg_dump, frozen transactions, truncated commit timestamps). Also fixed off-by-one errors in `spock_conflict_row_to_json()` that were overwriting the `local_origin` NULL flag.
* Fix Z0DAN initialization issue: `present_final_cluster_state` now executes a COMMIT to allow newly created subscriptions to update their state, and final cluster state now checks all subscriptions across the cluster.
* Suppress hot_standby_feedback off error messages in log in case a read replica is used for reporting and not failover (it is required for failover).
* Fix bug when applying changes to a table that has been dropped.

### Operational Improvements
* `add_node` is now restricted to run only on a new (uninitialized) node, preventing accidental misuse.

## Spock 5.0.5 on Feb 12, 2026

* Fix segfault that occurs when using new Postgres minor releases like 18.2.
* Zero Downtime Add Node (Zodan) minor bug fixes and improvements
* Updated documentation

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
