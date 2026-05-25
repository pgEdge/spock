# Spock Release Notes

## Spock 6.0.0

The on-disk catalog format and the GUC surface both change in this release;
see *Upgrading* below before running `ALTER EXTENSION spock UPDATE`.

### Highlights

* **Catastrophic node failure recovery** — new ACE-based workflow with
  origin-preserving repair prevents silent data divergence after node loss.
* **Progress tracking moved to WAL + shared memory** — eliminates
  heavyweight catalog writes in the apply hot path; `spock.progress` is now
  a view backed by `spock.apply_group_progress()`.
* **More granular conflict classification** — seven conflict types (up from
  four), with origin-aware suppression and DELETE conflicts now resolved
  through timestamp-based resolution.
* **Per-subscription conflict statistics** on PostgreSQL 18+ via a custom
  pgstat kind.
* **Liveness and feedback refactor** — TCP keepalive replaces the fragile
  `wal_sender_timeout` workaround; new `spock.apply_idle_timeout` GUC.
* **Logical slot failover** uses native PostgreSQL slotsync on PG17+ /
  PG18+.
* **Rolling upgrade support** — protocol negotiation (v4 for 5.0.x, v5 for
  6.0+) enables zero-downtime rolling upgrades.
* **Exception handling refactor** — stable behaviour under TRANSDISCARD /
  SUB_DISABLE; original error messages preserved in `spock.exception_log`.
* **Replay queue spills to disk** instead of refetching from the publisher.

### Catastrophic node failure recovery

Spock 6.0 documents and supports a structured recovery workflow for the
scenario where a node fails permanently and one or more surviving nodes are
lagging behind.  Using the
[Active Consistency Engine (ACE)](https://github.com/pgEdge/ace), operators
can:

1. Identify which rows are missing on lagging survivors using
   `table-diff --preserve-origin`.
2. Repair the lagging node from a fully-synchronized survivor using
   `table-repair --recovery-mode --source-of-truth --preserve-origin`.

The `--preserve-origin` flag is important: it ensures that repaired rows
retain their original origin ID and commit timestamp, so replication
metadata stays correct and the cluster remains conflict-free.  Without it,
repaired rows would appear as local changes and could trigger false
conflicts.

Both single-node and multi-node failure scenarios are covered.  See
[Catastrophic Node Failure Recovery](recovery/catastrophic_node_failure.md)
for the full guide.

### Replication progress tracking

Replication progress is no longer tracked in the `spock.progress` catalog
table.  Spock now tracks it live in shared memory and persists a snapshot
to `$PGDATA/spock/resource.dat`.  On apply-worker startup, Spock
reconciles the snapshot against the durable replication-origin LSN: if
`resource.dat` is stale, `remote_commit_lsn` is advanced from the origin
and stale timestamp fields are cleared (to be refreshed by subsequent
apply).

A custom resource manager (id 144) emits one WAL record per
`SpockGroupHash` entry at each `resource.dat` dump event, visible via
`pg_waldump` for debugging, not used for state recovery.

The catalog surface has been restructured accordingly:

* `spock.progress` is now a **view** over the new `spock.apply_group_progress()`
  set-returning function, filtered to the current database.  Code that read
  the previous *table* of the same name continues to work, but writes are
  no longer possible.  Use `apply_group_progress()` directly (or the view)
  for live data, and use the new
  `spock.read_peer_progress(slot, provider_node_id, subscriber_node_id)`
  function during slot snapshot import.
* `spock.lag_tracker` view redefined.  The old `last_received_lsn` column
  has been renamed to `commit_lsn` to reflect what it actually is, and a
  new `received_lsn` column reports the last LSN sent by the publisher
  (matching the `pgoutput` protocol convention).
* `remote_insert_lsn` is now updated on every incoming WAL record rather
  than only on COMMIT, so lag readings are more responsive.

### Exception handling improvements

* Fixed TRANSDISCARD / SUB_DISABLE handling during the commit phase in
  retry mode, preventing apply-worker death loops.
* Eliminated "(unknown action)" in error-context strings and NULL error
  messages in `exception_log`.  The originally-failing row now carries the
  real error message; bystander rows in the same transaction refer to the
  entry containing the root cause message.
* Added `initial_operation` field to track which DML operation caused a
  transaction discard.
* Subscriptions stuck in an unrecoverable synchronization stage are now
  disabled rather than restarted indefinitely.

### Exception replay: spill to disk

`spock.exception_replay_queue_size` has changed semantics.

* **Before**: a single byte threshold (default 4 MiB ≈ 4194304).  When the
  in-memory queue exceeded the threshold, Spock could not replay the
  transaction and would refetch it from the publisher.
* **Now**: a soft cap (default `4` MB, unit `MB`).  When the queue exceeds
  the cap, subsequent entries spill to a temporary file on disk.  Set to
  `0` to disable spilling and allow unbounded memory use (improves
  throughput for very large transactions; allocation failure falls back to
  `spock.exception_behaviour`).

`spock.exception_behaviour` continues to control the action on
unrecoverable errors:

| Value          | Action                                                   |
|----------------|----------------------------------------------------------|
| `discard`      | Skip the failed transaction and continue replication.    |
| `transdiscard` | Roll back the failed transaction and continue.           |
| `sub_disable`  | Disable the subscription and exit cleanly.               |

### Logical Slot Failover

* On **PostgreSQL 17+**, Spock creates all logical replication slots with
  the `FAILOVER` flag, allowing PostgreSQL's built-in slotsync worker
  (`sync_replication_slots = on`) to automatically synchronize them to
  physical standbys.
* On **PostgreSQL 18+**, Spock's own `spock_failover_slots` background
  worker is no longer registered.  The native PostgreSQL slotsync worker
  fully replaces it.  See the
  [Logical Slot Failover](configuring.md#logical-slot-failover-ha-standby)
  section of the configuration guide for required `postgresql.conf`
  settings.
* On **PostgreSQL 17**, Spock's worker remains active but automatically
  yields to the native slotsync worker if `sync_replication_slots = on`
  is set, preventing conflicts.

### More granular conflict classification

v5.0 classified conflicts into four types.  v6.0 expands this to seven,
adopting PostgreSQL-native conflict-type naming:

| v5.0 type       | v6.0 type(s)                                | What changed                                                                                                                                                                                                                                                                |
|-----------------|---------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `insert_exists` | `insert_exists`                             | No change.                                                                                                                                                                                                                                                                  |
| `update_update` | `update_exists` / `update_origin_differs`   | Spock now distinguishes between an update whose local origin matches the incoming origin (suppressed silently) and one whose local origin differs (evaluated through resolution).  `update_exists` is used for update constraint violations.                               |
| `update_delete` | `update_missing`                            | Renamed for clarity.                                                                                                                                                                                                                                                        |
| `delete_delete` | `delete_missing` / `delete_origin_differs`  | Spock now logs whether the missing row was last modified by a different origin.                                                                                                                                                                                              |
| *(new)*         | `delete_exists`                             | A remote DELETE arrives, but the local row has been updated more recently than the delete's timestamp.  The newer local version is preserved.                                                                                                                                |

Existing `spock.resolutions` data is migrated automatically during
`ALTER EXTENSION spock UPDATE` (see *Catalog changes* below).

### DELETE operations now use conflict resolution

In v5.0, when a DELETE found a matching local row, it was applied
immediately without consulting conflict resolution.  In v6.0, DELETE
operations go through timestamp-based resolution, just like updates.  This
enables the new `delete_exists` classification — Spock can determine
whether a delete should be applied or whether a newer local version should
be preserved.

### Cascade replication origin tracking

v6.0 adds support for tracking and forwarding replication origins in
cascade topologies (Node A → Node B → Node C).  The origin name is now
included in ORIGIN messages when the protocol version is 5 or higher.
This ensures that conflict evaluation on Node C has accurate origin
information even when changes pass through intermediate Node B.

### Per-subscription conflict statistics

On PostgreSQL 18+, Spock registers a custom pgstat kind
(`SPOCK_PGSTAT_KIND_LRCONFLICTS`) to count replication conflicts per
subscription.  New SQL functions
`spock.get_subscription_stats(subid, peer_node_id)` and
`spock.reset_subscription_stats(subid)` expose per-subscription apply
statistics.  On PostgreSQL versions before 18 these functions raise a
feature-not-supported error.

### Liveness and feedback refactoring

The `wal_sender_timeout`-based liveness mechanism has been replaced with a
cleaner two-layer model:

* **TCP keepalive** as the primary liveness detector (detects dead network
  or host in ~25 seconds).
* **`wal_sender_timeout=0`** on replication connections so the walsender
  never disconnects due to missing feedback.
* **`spock.apply_idle_timeout`** (default 300s) as a subscriber-side
  safety net for hung-but-connected walsenders.

This replaces the `maybe_send_feedback()` workaround that coupled
subscriber behaviour to a server GUC it cannot control.

### Read-only mode refactoring

Read-only mode has been refactored to use PostgreSQL's native
`DefaultXactReadOnly` mechanism instead of manual command-type filtering:

* `READONLY_USER` renamed to `READONLY_LOCAL` (the old name is retained as
  a backward-compatible alias) to clarify that it restricts local
  (non-replication) connections.
* In `READONLY_ALL` mode, the apply worker sends keepalive feedback but
  skips applying new transactions.
* Read-only mode changes are detected before applying the next
  transaction (`CHECK_FOR_INTERRUPTS` moved to top of the replay loop).

### Rolling upgrade via protocol negotiation

Spock now negotiates an output-plugin protocol version between publisher
and subscriber (Protocol 4 for v5.0.x, Protocol 5 for v6.0+).  This
enables zero-downtime rolling upgrades: a v6.0 subscriber can apply from
a v5 publisher and vice versa, with protocol-5-only features (such as
cascade origin forwarding) activated only when both sides support them.

### Zodan: data-loss fix when adding a node under write load

When adding a node while existing nodes were handling writes, the new
node could permanently miss rows or accumulate stale updates.  The root
cause was that apply workers were not paused during slot creation
(sub-second operation), so the captured resume LSN could fall before the
COPY boundary.  The fix pauses apply workers during slot creation and
captures the resume LSN deterministically.

Additional Zodan fixes in 6.0:

* Slots and subscriptions are now named consistently as
  `sub_{provider}_{subscriber}` via the new `spock.gen_sub_name()` helper.
* `remove_node` drops subscriptions from the `spock.subscription` catalog
  instead of guessing names.
* Phase 3 catch-up wait aligned and `spock.sync_event()` parameterised to
  avoid the Phase 9 handshake deadlock.

### AutoDDL improvements

AutoDDL has been refactored and hardened:

* **Centralized in `spock_autoddl.c`** — all AutoDDL plumbing moved into a
  single module for maintainability.
* **Simplified control flow** — dropped the recursive tag-matching
  heuristic in favour of clearer early-exit filters.
* **Extension script guard** — internal subcommands during
  `CREATE EXTENSION` / `ALTER EXTENSION UPDATE` are no longer replicated.
* **Transaction guards** — AutoDDL hook no longer fails when utility
  commands (e.g., `CLUSTER` without a table name) execute outside a
  transaction context.
* **Filtered non-transactional DDL** — commands that cannot execute inside
  transaction blocks on subscribers (e.g., `CLUSTER` on partitioned
  tables, `VACUUM`) are filtered on the publisher side before being
  queued.

### Memory and stability

* **Replay queue spills to disk** (see *Exception replay* above) instead of
  triggering a worker restart, eliminating the unpredictable restarts and
  replication lag spikes seen with large transactions.
* **Resource leak fixes**:
  * Row filter processing no longer leaks resource-owner entries when many
    rows are filtered out.
  * `remotetuple` is now freed after use in the conflict reporting path.
* **Shared memory initialization** centralized in `spock_shmem.c` with
  proper handling of startup, checkpointer, and background-worker
  processes.

### Bug fixes specific to 6.0

* **WAL recovery crash after apply-worker failure** — when an apply worker
  crashed and triggered a server restart, WAL recovery could fail due to
  improperly initialized shared memory structures.  Shared memory init has
  been refactored to handle startup, checkpointer, and background-worker
  processes correctly.
* **`remote_insert_lsn` lost after crash recovery** — the value was not
  included in WAL records and defaulted to 0 after crash recovery,
  breaking lag tracking in `spock.lag_tracker`.
* **Generated columns** — tables containing `GENERATED ALWAYS AS … STORED`
  columns caused replication errors because generated columns were treated
  as regular columns during COPY, protocol messages, default-value
  filling, and conflict resolution.  Now properly excluded.
* **Replica index lookup with `REPLICA IDENTITY FULL`** — cached index
  information was not invalidated before calling
  `RelationGetReplicaIndex()`, causing incorrect index usage when
  switching between replica identity modes.
* **Hash table iteration safety** — fixed removal-during-iteration
  corruption, missing NULL checks for `HASH_FIXED_SIZE` tables, and torn
  reads of 64-bit counters without spinlock protection.
* **Skip LSN mechanism** — a successfully skipped transaction in
  `SUB_DISABLE` mode would incorrectly disable the subscription again due
  to LSN mismatch between the skip point (BEGIN LSN) and the clear point
  (COMMIT LSN).  Exception-handling state is now cleared after a
  successful skip.
* **Table sync failure detection** — COPY failures during table sync were
  silently swallowed and the sync worker retried indefinitely.
  `PQgetResult()` is now called after `PQputCopyEnd()` to detect failures,
  and a new `SYNC_STATUS_FAILED` state stops retry loops and surfaces
  clear error messages.

### Security

* **DSN password obfuscation** — passwords in DSN connection strings are
  no longer visible in error messages or log output.  A message-filter
  hook wipes password characters from error messages before they are
  written.

### Other notable changes

* **Protocol cleanup** — removed unused SPI API support from the Spock
  protocol; fixed multiple protocol parameter validation issues.
* **Prevented adding tables from ignored schemas to replication sets.**
* **Snowflake removal** — removed snowflake-related functions and
  documentation since it is now in its own repository.
* **SpockCtrl removal** — removed the SpockCtrl utility code.
* **PostgreSQL 18 support** — compatibility work across core patches,
  initdb, row filters, and compiler warnings.
* **Source tree restructured** under `src/` and `include/` directories.

### GUC changes

**New**

* `spock.apply_idle_timeout` (int seconds, default `300`, `SIGHUP`) —
  safety net for detecting a hung walsender that keeps the TCP
  connection alive but stops sending data.  The timer resets on any
  received message.  Set to `0` to disable and rely solely on TCP
  keepalive for liveness detection.
* `spock.output_delay` (int milliseconds, default `0`, range 0–60000,
  `SIGHUP`) — artificial delay in the publisher-side output plugin.
  Used to reproduce conflict and lag scenarios in tests.
* `spock.resolutions_retention_days` (int days, default `100`,
  `SIGHUP`) — TTL for rows in `spock.resolutions`.  Rows older than
  this are deleted periodically by the apply worker.  Set to `0` to
  disable automatic cleanup.  Complements
  `spock.cleanup_resolutions(days)` and the new index on
  `resolutions(log_time)`.
* `spock.enable_quiet_mode` (bool, default `off`, `SIGHUP`) — when
  enabled, downgrades DDL replication INFO/WARNING messages to LOG
  level and suppresses dependent-object reporting in `DROP CASCADE`
  operations.  Intended for regression tests and production
  environments where less verbose output is desired.
* `spock.read_retry_count` allows for configuring the number of retries
  when an expected row is not found. The default matches the previously
  hard-coded value of 5 (there is 1ms of sleep between each retry).
  Setting it to 0 disables retries. This helps when a node has a large
  lag and we do not want to slow down processing.

**Removed**

* `spock.use_spi` — no longer used; the legacy SPI apply path is gone.
* `spock.feedback_frequency` — replaced by internal pacing.
* `spock.batch_inserts` - unused.

**Changed**

* `spock.exception_replay_queue_size`: default `4194304` → `4`, unit
  changed from bytes to MB, semantics changed from a hard threshold (with
  publisher refetch) to a soft cap (with disk spill).  See above.

### Catalog changes

* New: `spock.sub_id_generator` sequence (replaces inline oid-from-counter
  generation for subscription rows).
* New index `spock.resolutions(log_time)` to support
  `spock.cleanup_resolutions()`.
* `spock.resolutions.conflict_type` values renamed during upgrade:
  `update_update` → `update_exists`, `update_delete` → `update_missing`,
  `delete_delete` → `delete_missing`.  `insert_exists` is unchanged.
* `spock.subscription.sub_skip_schema` is now correctly typed as `text[]`
  (the column was added as `text` in 5.0.2 but the C code always treated
  the bytes as `text[]`; the 5.0.7 step migration relabels the catalog so
  no rewrite or downtime is required).

### New functions

* `spock.apply_group_progress()` — set-returning health view (backs
  `spock.progress`).
* `spock.read_peer_progress(slot, provider_node_id, subscriber_node_id)`
  — used by zodan when importing a slot snapshot.
* `spock.get_subscription_stats(subid, peer_node_id)` /
  `spock.reset_subscription_stats(subid)` — per-subscription apply
  statistics.
* `spock.cleanup_resolutions(days int DEFAULT NULL)` — TTL-based cleanup
  of the resolutions log.  Default permissions revoke EXECUTE from
  PUBLIC.
* `spock.sub_alter_options(subscription_name name, options text[])` —
  bulk subscription option changes, with input validation and no-op
  restart skipping.

### Removed functions

* `spock.convert_column_to_int8(regclass, smallint)` — superseded.
* `spock.convert_sequence_to_snowflake(regclass)` — superseded.

### Bug fixes carried forward from the 5.0.x line

These shipped in 5.0.6 – 5.0.8 and are included in 6.0.0:

* Handle upstream connection loss cleanly without replication-origin
  advance leak.  Previously a stale libpq socket fd produced an
  `epoll_ctl(EINVAL)` cascade and the recovery path could silently
  advance the replication origin past an in-flight remote transaction,
  causing it to be missed on reconnect (and, with
  `spock.exception_behaviour = transdiscard`, its rows would land in
  `spock.exception_log` with `error_message = unknown`).  The apply
  worker now `PG_RE_THROW`s on connection-class errors and the manager
  respawns it from the last durably-committed remote LSN.
* Preserve the original error message in `spock.exception_log` when
  applying under `transdiscard` / `sub_disable`.  The originally-failing
  row now carries the real error message; bystander rows in the same
  transaction are recorded as `unavailable` instead of `unknown`.
* zodan: name slots and subscriptions consistently
  (`sub_{provider}_{subscriber}`) via the new `spock.gen_sub_name()`
  helper; `remove_node` drops subscriptions from the
  `spock.subscription` catalog instead of guessing names; pause apply
  workers during slot creation to prevent data loss when adding a new
  node; align Phase 3 catch-up wait and parameterise
  `spock.sync_event()` to avoid the Phase 9 handshake deadlock.
* Spock now registers its own `pg_seclabel` provider (added in 5.0.8).
  The new `spock.delta_apply(rel, att_name, to_drop)` plpgsql wrapper in
  6.0.0 uses it to attach and clear the `spock.delta_apply` label on
  individual columns.
* Prevent data loss on `resync_table` when the subscriber is read-only
  (SPOC-440).
* Fix stale `local_tuple` pointer in the INSERT exception path for a
  missing relation; `SUB_DISABLE` now exits cleanly instead of
  dereferencing freed memory.
* Suppress repeated `hot_standby_feedback off` ERROR spam when a standby
  is used for reporting (not failover).
* Fix stack-use-after-scope in `spock_connect_base()` (ASan finding).
* Fix resource owner bug
* `apply_replay_bytes` `int` → `uint64` overflow fix (`b4ba9bdf`)

### Upgrading

The upgrade from 5.0.8 to 6.0.0 is a single `ALTER EXTENSION spock UPDATE`
once the binaries are swapped.  The upgrade:

* drops the legacy `spock.progress` table and recreates it as a view,
* replaces the `spock.lag_tracker` view definition,
* migrates `spock.resolutions.conflict_type` values,
* adds the new functions and the `sub_id_generator` sequence,
* refreshes the parallel-safety attributes on `spock.md5_agg_sfunc` and
  `spock.spock_gen_slot_name`.

## Spock 5.0.8

### Bug Fixes
* Fix subscriber crash on transactions larger than 2 GB. `apply_replay_bytes`
  was declared as `int`, causing signed-integer overflow and a crash when a
  single replicated transaction exceeded 2 GB of WAL data. Changed to
  `uint64`.
* The apply worker now exits cleanly when the upstream connection dies
  (firewall reload, walsender SIGKILL/RST, walsender ping timeout) and the
  manager respawns it from the last durably-committed remote LSN.  Previously
  a stale libpq socket fd produced an `epoll_ctl()` cascade with a follow-on
  `error during exception handling` per disconnect, and a corner of the
  recovery path could silently advance the replication origin past the
  in-flight remote transaction, causing it to be skipped on reconnect.
* Removed native PG17+/PG18 slot-sync integration. Spock no longer creates
  slots with (FAILOVER), does not defer to PostgreSQL's slotsync worker,
  and keeps spock_failover_slots active on PG18; the spock worker is once
  again the only path for failover-slot sync on 5.x.
* spock_failover_slots: handle primary disconnects and post-promotion edge
  cases. Reconnects to the primary on transient failure during sync; fixes
  a PG15/16 PANIC where a freshly promoted standby could enter a crash loop
  because the synchronized slot's restart_lsn was below the standby's WAL
  floor; tolerates invalid/zero LSNs and catalog_xmin values that previously
  tripped assertions.

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
  `remove_node` to fail when looking up subscriptions by name. A
  new `spock.gen_sub_name(provider_node, subscriber_node)` helper is now used
  in place of inline name concatenations.
* ZODAN: the `remove_node` cleanup loop tried to drop subscriptions by
  guessing names and nodes, which broke whenever `cross_wire` and `add_node`
  used different naming conventions. It now performs a per-node `DROP` of
  every subscription read directly from the `spock.subscription` catalog.
* Since 5.0.2 there was a bug with spock.subscription.sub_skip_schema having
  the incorrect type, it should be text[]. Fixed, including in the
  spock-5.0.6--5.0.7.sql migration script to repair.
* Fix a rare bug where under high concurrency when using delta apply columns
  a ResourceOwner exception may occur.
* Have more meaningful messages appear in spock.exception_log.

### Operational Improvements
* Documentation: filled out `snowflake.md`; revised `upgrading_spock.md`;
  fixed event-trigger syntax (`EXECUTE FUNCTION` instead of the deprecated
  `EXECUTE PROCEDURE`); standardized function-reference filenames to match
  function names exactly; removed obsolete `batch_inserts.md`
* Test infrastructure aligned with `main`: `run_tests.sh` and `SpockTest.pm`
  now use absolute `TESTLOGDIR` paths, derive per-test log filenames, and
  isolate `psql` from a developer's `psqlrc`/history. New regression tests
  added for failover slots (018), exception-handling/TRANSDISCARD error
  quality (013), and the stale-fd-after-connection-death scenario (019).
* Avoid unnecessarily waiting after sync_event()

## Spock 5.0.6

### New Features
* New `spock.feedback_frequency` GUC that controls how often feedback is
  sent to the WAL sender. Feedback is sent every *n* messages, where *n*
  is the configured value. Note that feedback is also sent every
  `wal_sender_timeout / 2` seconds.
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
* Fix Zodan initialization issue: `present_final_cluster_state` now executes
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
      samples/Zodan/zodremove.sql) and python script
      (samples/Zodan/zodremove.py). This also handles removing nodes that
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

* Full re-work of parallel slots implementation to support mixed OLTP
  workloads
* Improved support for delta_apply columns to support various data types
* Improved regression test coverage
* Support for
  [Large Object Logical Replication](https://github.com/pgedge/lolor)
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
* Improved and documented support for replication and maintaining partitioned
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
* Better support for minimizing system interruption during switch-over and
  failover
