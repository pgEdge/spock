# Spock Release Notes

## Spock 6.1.0

### Quorum layer

Spock can now consult an external quorum system, selected with
`spock.quorum_provider`: an etcd cluster, or the pgraft or pgBully extension
running inside PostgreSQL. With the default of `none` nothing is consulted
and behaviour is unchanged. Two new superuser functions report what the
layer sees, `spock.quorum_status()` and `spock.quorum_members()`. Nothing in
Spock acts on the answers yet. See
[Consulting a Quorum System](managing/quorum_layer.md).

New settings: `spock.quorum_provider`, `spock.quorum_timeout`,
`spock.quorum_cluster_id`, `spock.quorum_etcd_endpoints`.

### Upgrading

`ALTER EXTENSION spock UPDATE TO '6.1.0'` adds the two functions. No catalog
changes, no restart.

## Spock 6.0.0-beta.2

This section lists what changed since 6.0.0-beta.1, for those testing the
beta.  Each item is covered in full in the 6.0.0 notes below.  This section
will be removed at general availability.

### Upgrading from beta 1

* Beta 1 and beta 2 both install extension version `6.0.0`, but the catalog
  differs between them, so a plain `ALTER EXTENSION spock UPDATE` does
  nothing on a beta 1 node.  Update a beta 1 node in two steps instead:

  1. Pause DDL on the cluster.
  2. Install the beta 2 binaries and restart the node.
  3. In every database where Spock is installed, run:

     ```sql
     ALTER EXTENSION spock UPDATE TO '6.0.0-beta1-to-beta2';
     ALTER EXTENSION spock UPDATE TO '6.0.0';
     ```

  4. Repeat for each node, then resume DDL.
  5. On each primary, check that every Spock slot has the `failover` flag:

     ```sql
     SELECT slot_name, failover
     FROM pg_replication_slots
     WHERE plugin = 'spock_output';
     ```

     For any slot still showing `false`, pause the subscriber that holds it
     and run `SELECT spock.slot_enable_failover();` on the primary.

  The first command adds the objects beta 2 needs, removes
  `spock.wait_for_apply_worker()`, and sets the `failover` flag on existing
  slots.  The second only sets the version name back to `6.0.0`.

  The `failover` flag matters on PostgreSQL 17 and 18, where native slot sync
  copies only flagged slots to a standby.  Beta 1's upgrade from 5.x did not
  flag the slots that already existed, so a beta 1 node upgraded from 5.x may
  have slots that would be missing on the standby after a failover.  Slots
  created by 6.0.0 already have the flag.  The first command flags the rest,
  but skips any slot in use at that moment and prints a NOTICE naming it.  On
  PostgreSQL 16 and older, or with Spock's own slot sync worker on 17, the
  flag is not used and step 5 can be skipped.

  Until a database has been updated, AutoDDL, adding tables to a replication
  set and structure sync fail there with `catalog "spock.reserved_object"
  does not exist`.  Running the commands on a node that already has beta 2's
  catalog changes nothing.  These two update steps will be removed at general
  availability.
* The upgrade from 5.0.x now starts at 5.0.12.  A 5.0.11 node still
  upgrades in one `ALTER EXTENSION spock UPDATE`, through 5.0.12.
* On a server with PostgreSQL's fix for CVE-2026-6471, `spock_output` must be
  listed in `output_plugin_libraries`.  See *Upgrading* below.

### GUC changes

* New `spock.sync_timeout` (seconds, default `0`, `USERSET`): the time
  limit for a single wait in the node management routines.  `0` keeps each
  routine's built-in limit.
* New `spock.failover_slots_naptime` (milliseconds, default `1000`,
  `SIGHUP`) and `spock.failover_slots_feedback_naptime` (milliseconds,
  default `10000`, `SIGHUP`): how often Spock's failover-slots worker
  syncs slots.  It used to wait a fixed 60 seconds.
* `spock.pause_timeout`: the 300-second maximum is removed.
* `spock.restart_delay_default`, `spock.restart_delay_on_exception` and
  `spock.output_delay` are now declared in milliseconds, so they accept
  values with units such as `'5s'`.
* `spock.restart_delay_default` now applies to every apply-worker restart,
  including after a lost connection or a temporary error.

### SQL function and catalog changes

* New table `spock.reserved_object`, listing the schemas and extensions Spock
  keeps out of the structure-sync dump, out of replication sets, or out of
  DDL replication.
* New `spock.reserved_object_add(p_name name, p_kind text,
  p_exclude_from_dump boolean DEFAULT true, p_block_in_repset boolean
  DEFAULT true, p_replicate_ddl boolean DEFAULT NULL)`.
* New `spock.reserved_object_remove(p_name name, p_kind text)`.
* New `spock.slot_enable_failover() RETURNS integer`, called by the 5.x
  upgrade.
* Removed `spock.wait_for_apply_worker(p_subbid bigint, timeout int)`.
* `spock.repset_add_all_tables()` now skips a table it cannot add, with a
  warning, instead of failing the whole call.

### Other changes

* Direct DDL against the `spock` and `snowflake` schemas is refused while
  DDL replication is on.
* Large objects stored by lolor can be replicated, and Zodan `add_node`
  copies them to the new node.
* Zodan `add_node` can add a 6.0.0 node to a cluster of 5.0.9 or later
  nodes, and copies the source node's replication sets to the new node.
* `forward_origins` cannot be active on a subscription while another
  subscription on the node is enabled.
* The apply worker restarts and tries again after a temporary error, such
  as a deadlock or lock timeout, instead of treating it as a data exception.
* `pg_upgrade` of a Spock node on PostgreSQL 17 and later no longer fails
  with `resource manager with ID 144 not registered`.
* Bug fixes from 5.0.11 and 5.0.12.
* Builds against PostgreSQL 19 beta 3 and 4.

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
* **Automatic node metadata propagation** — a node's `location`, `country`,
  and `info` (including its conflict-resolution `tiebreaker`) now
  propagate automatically to every direct subscriber on change, via the
  new `spock.node_alter()` function or a plain `UPDATE`; no more silently
  disagreeing tiebreakers from a forgotten `spock.node_refresh_info()`.
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
* **Reserved schemas and extensions are configurable** — a new
  `spock.reserved_object` catalog controls which schemas and extensions are
  left out of structure sync, replication sets and DDL replication.
* **Mixed-version node addition** — Zodan `add_node` can add a 6.0.0 node
  to a cluster of 5.0.9 or later nodes.
* **Large object replication** — tables of the lolor extension can join a
  replication set, and Zodan `add_node` copies large objects to the new
  node.
* **PostgreSQL 19 support** — compatibility work across core patches and
  version-specific API changes (replication-origin session state folded into
  `replorigin_xact_state`, `CLUSTER` folded into `REPACK`, the `pgstat` and
  recovery-conflict signalling changes, and the `RepOriginId` rename).
  Spock builds against PostgreSQL 19 beta 3 and 4. This support is preliminary:
  PostgreSQL 19 is still in beta, and Spock on 19 is not supported for
  production use.

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

### Automatic node metadata propagation

A node's `location`, `country`, and `info` (including a `tiebreaker` key
used to break same-timestamp conflicts -- see *Tiebreaker* in
[conflict_types.md](conflict_types.md)) previously had to be manually
re-fetched onto every other node with `spock.node_refresh_info()` after
any change; a node left unrefreshed would silently keep disagreeing with
the rest of the cluster about that peer's tiebreaker.

v6.0 propagates such a change automatically to every node that
subscribes to it *directly*, via a new `AFTER UPDATE` trigger on
`spock.node` and a custom logical-replication message -- deliberately
direct-subscribers-only, not forwarded through a cascade topology, so it
introduces no message-ordering dependency on the existing replication
stream. The new `spock.node_alter()` function is the recommended way to
make the change: it validates a `tiebreaker` value (must be a whole JSON
number that fits a 32-bit integer) and merges an `info` patch rather than
replacing it wholesale; a raw `UPDATE spock.node` on the node's own row
continues to work and propagates the same way. `spock.node_refresh_info()`
updates a node whose cached row missed a change, for example because the
transaction carrying it was skipped or discarded, and `spock.sub_resync_table()`
warns when the provider's row differs from the cached one. See
[Automatic Node Metadata Propagation](spock_functions/node_mgmt.md#automatic-node-metadata-propagation)
and [spock.node_alter](spock_functions/functions/spock_node_alter.md) for
details.

### Cascade replication origin tracking

v6.0 adds support for tracking and forwarding replication origins in
cascade topologies (Node A → Node B → Node C).  The origin name is now
included in ORIGIN messages when the protocol version is 5 or higher.
This ensures that conflict evaluation on Node C has accurate origin
information even when changes pass through intermediate Node B.

If Node C also has a disabled subscription directly to Node A, Spock now
advances that subscription's replication origin as forwarded changes from
Node A arrive through Node B.  When the direct subscription is later
enabled, it starts from where the forwarded changes left off, so rows
already received through Node B are not sent again.

A subscription cannot activate `forward_origins` while another subscription
is already enabled on the same node, and a subscription cannot be enabled
while another has forwarding active; clear `forward_origins`
(`spock.sub_alter_options`) or disable the other subscription first.  See
[Origin Forwarding](spock_functions/sub_mgmt.md#origin-forwarding) for
details.

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

An incompatible upstream is now rejected early: `create_subscription()`
runs the version check at DDL time when `synchronize_structure` is
requested, and a structure sync from a newer-major upstream is refused
(pg_dump cannot read a newer server) instead of failing opaquely after a
slot and snapshot were created.

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
* **Mixed versions** — `add_node` can add a 6.0.0 node to a cluster whose
  nodes run 5.0.9 or later, instead of requiring every node to be upgraded
  first.  Existing nodes may already be mixed.  The new node must run the
  same or a newer version than every existing node.
* **Replication sets are copied** — the new node gets the source node's
  replication sets, including user-created sets, column lists, row filters,
  and tables removed from a set.  Before, the subscriptions named only the
  three built-in sets, so tables in a user-created set were neither sent
  nor received.
* **Large objects** — the new node may have lolor installed as long as its
  tables are empty, and must have it when the source replicates lolor
  tables.  The initial data sync copies the large objects.
* **Longer waits** — the new `spock.sync_timeout` GUC raises the time limit
  on each wait in the node management routines, which was fixed at about
  three minutes and too short for large databases.  `spock.pause_timeout`
  no longer has a 300-second maximum.
* The old Python versions, `zodan.py` and `zodremove.py`, are removed.
  Use the SQL procedures.

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
* **Temporary-relation DDL not replicated** — `CREATE TABLE … (LIKE temp)`
  and `CREATE TABLE … AS SELECT … FROM temp` are skipped, since the
  temporary relation does not exist on the subscriber.
* **Replication-set stickiness on `ALTER TABLE`** — with
  `spock.include_ddl_repset` enabled, `ALTER TABLE` no longer evicts a
  table from a user-defined replication set unless it adds or drops a
  primary key / replica identity.  Inline `ADD COLUMN … PRIMARY KEY` and
  `REPLICA IDENTITY FULL` tables are now classified correctly.
* **Safe `search_path` interpolation** — replicated DDL ships a valid
  `SET search_path` even when the session path is empty.
* **Direct DDL against `spock` and `snowflake` is refused**
  (behaviour change) — while `spock.enable_ddl_replication` is on, a
  statement whose target schema is one of the built-in extension-owned
  schemas now fails outright:

  ```
  ERROR:  cannot run DDL against schema snowflake while DDL replication is enabled
  DETAIL:  The schema is managed by an extension and its objects are not replicated.
  HINT:  For a deliberate node-local change, run the statement with spock.enable_ddl_replication = off.
  ```

  These schemas are populated by extension scripts, where AutoDDL is
  already suppressed, so a runtime statement against them is almost always
  a mistake.  Previously such a statement half-applied: the command text
  replicated to peers while the relation was silently kept out of every
  replication set.  See *Upgrading* for what this affects.
* **An extension's own DDL during `DROP EXTENSION` stays node-local** —
  with `spock.allow_ddl_from_functions` on, DDL an extension ran while being
  dropped was queued for replication, even though every peer runs the same
  cleanup when it applies the `DROP EXTENSION`.  For lolor this left peers
  unable to drop the extension and stalled apply.  The `DROP EXTENSION`
  itself still replicates.

### Reserved schemas and extensions

Spock keeps some schemas and extensions out of the structure-sync dump and
out of replication sets.  That list used to be fixed in the code.  It is now
the `spock.reserved_object` catalog, with three settings per row:

* `exclude_from_dump` — left out of the structure-sync dump.
* `block_in_repset` — its tables may not be added to a replication set.
* `replicate_ddl` (schemas only) — when `false`, DDL against the schema runs
  only on the node where it is issued.

The built-in rows cannot be changed or removed:

| Object       | exclude_from_dump | block_in_repset | replicate_ddl |
|--------------|-------------------|-----------------|---------------|
| `spock`      | yes               | yes             | yes           |
| `snowflake`  | yes               | yes             | yes           |
| `lolor`      | yes               | no              | yes           |
| `coldfront`  | yes               | no              | yes           |
| `pgedge_ace` | yes               | yes             | no            |

Add your own with `spock.reserved_object_add()` and remove them with
`spock.reserved_object_remove()`.  Your rows are kept across dump and
restore.  See
[Reserved Schemas and Extensions](spock_functions/repset_mgmt.md#reserved-schemas-and-extensions)
for details.

Exclusion from the dump now applies whether or not the object exists on the
subscriber.  Before, an object present only on the provider was never
excluded.

### `repset_add_all_tables()` skips tables it cannot add

`spock.repset_add_all_tables()` used to fail, and add nothing, when any one
table had no replica identity index.  It now adds the tables it can and
prints a warning naming each table it skipped.  Tables in a reserved schema
or owned by a reserved extension are skipped the same way.  Naming a
reserved schema in the call is still an error, and
`spock.repset_add_table()` still fails for a table it cannot add.

The message now says "replica identity index" instead of blaming a missing
primary key, since a table with a primary key and `REPLICA IDENTITY FULL`
or `NOTHING` is also rejected.

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
* **Un-appliable TRUNCATE loop** — in `discard` mode a TRUNCATE that failed
  on the subscriber (e.g. the relation does not exist) crash-looped the
  apply worker.  It is now wrapped in a subtransaction, logged, and
  discarded like other DML.
* **`pg_upgrade` failed on PostgreSQL 17 and later** — `pg_upgrade` decodes
  each logical slot's remaining WAL to check it is drained, and Spock's
  resource manager was not registered in the servers `pg_upgrade` starts.
  The check failed with `resource manager with ID 144 not registered`.
* **Apply idle timeout treated as a data exception** — when
  `spock.apply_idle_timeout` fired in the middle of a transaction, the error
  went down the data-exception path, so the subscription could be disabled or
  a good transaction discarded.  It is now handled like a lost connection.
* **Clock skew in progress tracking** — an origin commit timestamp ahead of
  the subscriber's clock, or forwarded transactions whose timestamps do not
  rise with the provider's WAL position, tripped an assertion in
  assert-enabled builds.  `remote_commit_lsn` now advances independently of
  the timestamp fields.
* **Replay entries restored from the spill file were not terminated** — a
  truncated or malformed record read back from disk could be scanned past
  the end of its buffer instead of being rejected.
* **Peer sessions use a fixed time format** — Spock reads commit timestamps
  from other nodes as text, and their meaning depended on each side's
  `DateStyle` and `TimeZone`.  Where the two differed, the same text could
  mean a different moment, which matters when a timestamp picks the LSN to
  advance a slot to during `add_node`.  Peer connections now request
  `datestyle=ISO`, and a peer timestamp without an explicit UTC offset is
  rejected.
* **Initial sync with a row filter on a table with a dropped column** —
  rows were read at the wrong offsets after a dropped column, giving corrupt
  rows or a crash.
* **Sync worker lost the original error** — a failure while creating the
  slot during table sync was reported as `errstart was not called` instead
  of the real error.

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
* **Windows support removal** — dropped Win32-specific code paths; Spock
  targets POSIX-only environments.
* **`--exclude-extension`** — extended use of the pg_dump option
  (PostgreSQL 17+).
* **PostgreSQL 18 support** — compatibility work across core patches,
  initdb, row filters, and compiler warnings.
* **Source tree restructured** under `src/` and `include/` directories.
* **Packaging** — the repository now builds the `spock60` RPM and DEB
  packages itself.  Debian bullseye, which has reached end of life, is no
  longer built.
* **Documentation** — a new guide on sizing PostgreSQL resources for Spock
  by node and database count (see [Sizing](sizing.md)), a `SECURITY.md`
  explaining how to report vulnerabilities, and the `output_plugin_libraries`
  requirement in the README.

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
* `spock.log_verbosity` (enum `normal`/`debug1`/`debug2`, default
  `normal`, `SUSET`) — promotes Spock's own `DEBUG1`/`DEBUG2` messages to
  `LOG` so they survive a normal `log_min_messages`.
* `spock.apply_change_logging` (enum `none`/`key_only`/`verbose`, default
  `none`, `SUSET`) — emits per-change JSON from the apply worker
  (action, table, key, origin, commit timestamp; plus row data in
  `verbose`).
* `spock.read_retry_count` allows for configuring the number of retries
  when an expected row is not found. The default matches the previously
  hard-coded value of 5 (there is 1ms of sleep between each retry).
  Setting it to 0 disables retries. This helps when a node has a large
  lag and we do not want to slow down processing.
* `spock.sync_timeout` (int seconds, default `0`, `USERSET`) — the time
  limit for one wait in the node management routines: for a sync event to
  arrive, for a peer to catch up, or for a subscription to start
  replicating.  Raise it on large databases, where catching up takes longer
  than the built-in limits allow.  `0` keeps each routine's built-in limit.
  It can be set for one operation, for example
  `SET spock.sync_timeout = '2h'`.
* `spock.failover_slots_naptime` (int milliseconds, default `1000`, range
  1–3600000, `SIGHUP`) — how long Spock's failover-slots worker sleeps
  between slot sync passes.  It used to be a fixed 60 seconds, which let a
  standby's slots fall up to a minute behind.
* `spock.failover_slots_feedback_naptime` (int milliseconds, default
  `10000`, range 1–3600000, `SIGHUP`) — the shorter retry interval the
  failover-slots worker uses while waiting for the standby to receive the
  WAL a slot needs.  Both failover-slots settings matter only where Spock's
  own worker runs: PostgreSQL 15 and 16, and 17 when
  `sync_replication_slots` is off.

**Removed**

* `spock.use_spi` — no longer used; the legacy SPI apply path is gone.
* `spock.feedback_frequency` — replaced by internal pacing.
* `spock.batch_inserts` - unused.

**Changed**

* `spock.exception_replay_queue_size`: default `4194304` → `4`, unit
  changed from bytes to MB, semantics changed from a hard threshold (with
  publisher refetch) to a soft cap (with disk spill).  See above.
* `spock.pause_timeout`: the 300-second maximum is removed, for very large
  or long-running transactions.  The default is still 10 seconds.
* `spock.restart_delay_default`, `spock.restart_delay_on_exception` and
  `spock.output_delay` are now declared in milliseconds, so they accept
  values with units (`'5s'`) and `SHOW` reports the unit.  Their values do
  not change.
* `spock.restart_delay_default` now applies to every apply-worker restart,
  including after a lost connection or a temporary error, so a problem that
  does not clear cannot become a tight restart loop.

### Catalog changes

* New: `spock.sub_id_generator` sequence (replaces inline oid-from-counter
  generation for subscription rows).
* New: `spock.reserved_object` table, the list of reserved schemas and
  extensions (see *Reserved schemas and extensions* above).  Built-in rows
  are protected by a trigger, and only user-added rows are dumped.
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
* `spock.reserved_object_add(p_name name, p_kind text,
  p_exclude_from_dump boolean DEFAULT true, p_block_in_repset boolean
  DEFAULT true, p_replicate_ddl boolean DEFAULT NULL)` — reserve a schema
  or extension, or change an existing row.
* `spock.reserved_object_remove(p_name name, p_kind text)` — remove a
  reserved schema or extension you added.
* `spock.slot_enable_failover() RETURNS integer` — sets the `failover` flag
  on Spock's logical slots on PostgreSQL 17 and later, and returns how many
  it changed.  The upgrade from 5.x calls it.  EXECUTE is revoked from
  PUBLIC.
* `spock.node_alter(p_location text, p_country text, p_info_patch jsonb)`
  — validated way to change the local node's own location/country/info
  (merging info, validating a `tiebreaker` patch); see *Automatic node
  metadata propagation* above.
* `spock.node_info_emit()` / `spock.node_info_apply()` /
  `spock.node_info_broadcast()` (trigger function, backing the new
  `node_info_broadcast_trigger` on `spock.node`) — internal plumbing
  behind automatic node metadata propagation; not intended to be called
  directly (`EXECUTE` revoked from `PUBLIC`).

### Removed functions

* `spock.convert_column_to_int8(regclass, smallint)` — superseded.
* `spock.convert_sequence_to_snowflake(regclass)` — superseded.
* `spock.wait_for_apply_worker(p_subbid bigint, timeout int)` — had no
  callers since SpockCtrl was removed.

### Bug fixes carried forward from the 5.0.x line

These shipped in 5.0.6 – 5.0.12 and are included in 6.0.0:

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
* A lost provider connection under `SUB_DISABLE` could disable the
  subscription: the resent transaction was mistaken for one that had failed
  to apply.
* The apply worker retries after temporary errors — deadlocks,
  `lock_timeout`, running out of a resource (SQLSTATE class 53), or a
  provider that is restarting or in recovery (57P02, 57P03) — instead of
  treating them as data exceptions that disable the subscription or discard
  the transaction.  The worker exits without advancing the replication
  origin and the provider resends the transaction.
* Restarting an apply worker in the middle of a transaction could disable
  the subscription under `SUB_DISABLE`.  The failure marker is now cleared
  when the worker exits on `SIGTERM`.
* An error between transactions left the apply worker in replay mode for
  the next transaction, which had never failed, so under `TRANSDISCARD` or
  `SUB_DISABLE` it could be discarded or disable the subscription.
* Two subscriptions whose names share a prefix (such as `sub` and
  `sub_parallel`) shared one exception-log slot.  The lookup now compares
  the whole name, and no longer reads past the end of the array.
* `spock.get_lsn_from_commit_ts()` could hang on an idle node.  Its WAL scan
  now stops at the end of WAL as it was when the scan began.
* The failover-slots worker died whenever the walreceiver reconnected to
  the primary, when `spock.primary_dsn` was not set.  It now waits for the
  next cycle.
* Two retry messages lowered from LOG to DEBUG1 still reached the server
  log with default settings, because the level check was backwards.
* A column that exists on the provider but not on the subscriber put the
  apply worker in a restart loop.  It is now handled like a missing table,
  and the error names every missing column.
* Tuple data from the provider is checked against the local column
  definition before use, so a tuple that does not fit is rejected instead of
  applied.  Names and attribute counts in RELATION messages are checked too,
  and a subscriber built without lz4 rejects an lz4-compressed value.

### Upgrading

The upgrade from 5.0.12 to 6.0.0 is a single `ALTER EXTENSION spock UPDATE`
once the binaries are swapped.  Earlier 5.0.x releases upgrade in the same
single step, through 5.0.12.  The upgrade:

* drops the legacy `spock.progress` table and recreates it as a view,
* replaces the `spock.lag_tracker` view definition,
* migrates `spock.resolutions.conflict_type` values,
* adds the new functions, the `sub_id_generator` sequence and the
  `spock.reserved_object` catalog,
* drops `spock.wait_for_apply_worker()`,
* adds the `node_info_broadcast_trigger` trigger on `spock.node`,
* refreshes the parallel-safety attributes on `spock.md5_agg_sfunc` and
  `spock.spock_gen_slot_name`,
* turns on the `failover` flag for existing logical slots by calling
  `spock.slot_enable_failover()`, so PostgreSQL 17 and 18 slot synchronization
  picks them up. This is a no-op on PostgreSQL 16 and older and on a standby,
  and it skips slots that are in use at the time. See
  [Logical Slot Failover](logical_slot_failover.md) for how to handle any
  skipped slots.

Check your runbooks and automation for direct DDL against the `spock` or
`snowflake` schemas before upgrading.  Statements such as
`DROP TABLE snowflake.x` or `CREATE INDEX` on a `spock` table succeeded on
5.0.x and now raise an error (see *AutoDDL improvements* above).  Any
procedure that needs to keep doing this must set
`spock.enable_ddl_replication = off` for the session first, which is also
what the error hint says.  The restriction covers only the built-in
extension-owned schemas: schemas you reserve yourself with
`spock.reserved_object_add()` are unaffected, and `pgedge_ace` continues to
accept DDL and keep it node-local.

PostgreSQL's 2026 security fix for CVE-2026-6471 added the
`output_plugin_libraries` parameter, and its default leaves out
`spock_output`, so logical decoding fails on a server with the fix.  Set
`output_plugin_libraries = 'pgoutput, test_decoding, spock_output'` on every
node, physical standbys included, and only on servers that have the
parameter.  See [Configuring Spock](configuring.md).

The apply worker now restarts and tries again after a temporary error such
as a deadlock or lock timeout.  If the problem never clears, expect the
worker to restart every `spock.restart_delay_default` (5 seconds by default)
instead of a disabled subscription or a discarded transaction.

## Spock 5.0.12

### Upgrade Notes
* There are no schema changes in 5.0.12.

* PostgreSQL's 2026 security fix for CVE-2026-6471 (back-patched to every
  supported major) added the `output_plugin_libraries` parameter, and a library
  may no longer be used as an output plugin unless it is listed there. Its
  default excludes `spock_output`, so on a server carrying the fix logical
  decoding fails with `library "spock_output" may not be used as an output
  plugin`. The check runs whenever decoding starts, not only at slot creation,
  so this stops an established cluster after a minor-version upgrade - not just
  new subscriptions. Set
  `output_plugin_libraries = 'pgoutput, test_decoding, spock_output'` on every
  node, physical standbys included, and only on servers that have the parameter
  - on older releases an unrecognised parameter stops the server from starting.
  See [Configuring Spock](configuring.md). The regression and TAP test suites
  and the Docker test image now check for the parameter and set it themselves.

* When the apply worker fails for a reason that has nothing to do with the
  data (a deadlock, a lock timeout, a provider that is restarting), it now
  restarts and tries again instead of treating the failure as an exception.
  See Bug Fixes. If the problem never goes away, you will see the apply worker
  restart every `spock.restart_delay_default` (5 seconds by default) rather
  than a disabled subscription or a discarded transaction.

### Bug Fixes
* The apply worker now retries after temporary errors. Some errors have
  nothing to do with the replicated data: PostgreSQL picked the apply worker
  as a deadlock victim, `lock_timeout` fired, the server briefly ran out of a
  resource (SQLSTATE class 53), or the provider was restarting or still in
  recovery (57P02, 57P03). All of these succeed if tried again. Before, they
  went down the same path as a permanent data error, so depending on
  `spock.exception_behaviour` the subscription was disabled or the transaction
  was written to `spock.exception_log` and thrown away, even though the
  provider would happily have sent it again. Now the worker exits without
  moving the replication origin, the manager starts it again, and the
  provider resends the transaction. Every restart path, including the
  existing one for a lost connection, now waits `spock.restart_delay_default`
  before starting again, so a problem that does not clear cannot turn into a
  tight restart loop.

* Tables with `GENERATED ALWAYS AS ... STORED` columns caused replication
  errors. Generated columns were handled like ordinary columns during the
  initial table copy, in the replication protocol, when filling in defaults
  for missing columns, and during conflict resolution. They are now left out
  everywhere, and the subscriber computes them from the column definition.

* AutoDDL failed after utility commands that run outside a transaction
  block, such as `CLUSTER` with no table name. These commands commit after
  each table, so by the time the AutoDDL hook ran there was no open
  transaction and no snapshot, and the catalog lookups and the queue insert
  failed. AutoDDL now starts a transaction and takes a snapshot itself when it
  needs to.

* `spock.get_lsn_from_commit_ts()` could hang on an idle node. The function
  scans the node's WAL for the last local commit at or before a timestamp,
  but the scan had no stopping point, so once it caught up it sat waiting for
  WAL that nobody was going to write. An `add_node` run was seen stuck behind
  this call for over eleven minutes. The scan now stops at the end of WAL as
  it stood when it began, takes the commit timestamp and origin from the WAL
  record instead of `pg_commit_ts`, counts local two-phase commits written by
  other applications, and refuses to run on a server in recovery. A timestamp
  with no matching commit still returns the slot's `restart_lsn`, now logged
  at DEBUG1.

* A failure between transactions could make the apply worker mishandle the
  next one. When a transaction fails to apply, the worker restarts, the
  provider resends it, and the worker runs it again in what the code calls
  replay mode: each row is tried in a subtransaction so the failing row can
  be written to `spock.exception_log` and `spock.exception_behaviour` can
  decide what to do with it. Replay mode is meant for that one transaction.
  But an error raised between transactions switched the worker into replay
  mode with no failed transaction to attach it to, and the flag stayed set
  for whatever the provider sent next. That transaction, which had never
  failed, ran as a replay and under `TRANSDISCARD` or `SUB_DISABLE` was
  thrown away or used to disable the subscription. The worker now turns
  replay mode on only for the transaction that actually failed, and any
  other transaction clears the recorded failure.

* A replayed transaction that applied nothing was still committed. Under
  `TRANSDISCARD` and `SUB_DISABLE` every row of a replay runs in a
  subtransaction that is always rolled back, so a replay applies no rows. The
  check for "replayed but hit no error" ran only after the replication origin
  had moved forward and the transaction had committed, so the origin ended up
  past a transaction that was never applied. The transaction was lost while
  the log said it had been discarded on purpose. The check now runs first and
  the transaction is rolled back instead, so the provider resends it.
  Transactions skipped with `spock.sub_alter_skiplsn` are exempt.

* Two subscriptions whose names share a prefix (for example `sub` and
  `sub_parallel`) shared one exception-log slot, because the lookup compared
  only the first few characters. Sharing the slot means sharing the commit
  LSN that marks a transaction as having already failed, so a failure
  recorded by one subscription could push the other into replay mode for a
  transaction that never failed. The lookup now compares the whole name. The
  same code also read, and could have written, one entry past the end of the
  array.

* The failover-slots worker died whenever the walreceiver reconnected to the
  primary. Without `spock.primary_dsn` the worker takes the primary's
  connection string from the walreceiver, which blanks that string for the
  whole of every connection attempt, not only at standby startup. The
  connection then failed, the worker exited, and failover slots stopped
  syncing until it restarted. The worker now waits for the next cycle.

* Two retry messages for serialization failures are lowered from LOG to
  DEBUG1, but the check that decides whether to print them at the new level
  was backwards. With default settings they went to the server log no matter
  what `log_min_messages` said. Also marked a deliberate switch fall-through
  in the apply worker so clang stops warning about it on every build before
  PostgreSQL 19.

* Restarting an apply worker in the middle of a transaction could disable the
  subscription. The worker records the commit LSN of every transaction it
  begins, not only ones that fail, and a clean shutdown left the marker
  behind, so the provider's resend of the interrupted transaction looked like
  a transaction that had already failed. Under `SUB_DISABLE` that disabled
  the subscription for no real error. The marker is now cleared when the
  worker exits on `SIGTERM`.

* A column that exists on the provider but not on the subscriber put the
  apply worker in a restart loop. The error was raised while opening the
  table, before the per-row subtransaction exception handling needs, so
  `spock.exception_behaviour` never got a say and the error came back on
  every retry without end. A missing column is now handled like a missing
  table: the first attempt raises the error, the retry discards the change
  and logs it through the normal exception path. The message also names every
  column the local table is missing, so repairing a drifted schema no longer
  costs one column per apply attempt.

* Tuple data arriving on the wire is now checked against the local column
  definition before it is used. Each attribute is copied out of the message
  into its own buffer and its length checked, so a tuple that does not fit
  the local column is rejected rather than applied. That is what happens
  after a provider-only `ALTER COLUMN TYPE` with DDL replication off: the
  apply worker exits and retries until the two schemas agree. Names and
  attribute counts in the RELATION message are validated too, and a
  subscriber built without lz4 now rejects an lz4-compressed value instead
  of storing it.

### Other Changes
* Refreshed the `attoptions` server patch for the `heap_update()` change in
  PostgreSQL 17.11, 18.5 and 19 beta 3. One hunk's context lines no longer
  matched and the patch was rejected. Only context lines changed.

* Spock builds against PostgreSQL 19 beta 3 and 4, with a new `compat/19` layer for
  the API changes in that beta (`CLUSTER` folded into `REPACK`, the
  recovery-conflict signalling changes, tuple-descriptor finalisation, and
  the flattened `ReorderBufferTXN` commit-time field). `CREATE EXTENSION`
  accepts major version 19, and CI and the release packaging cover it. This
  is preliminary: PostgreSQL 19 is still in beta, the compatibility layer
  will change before it is released, and Spock on 19 is not supported for
  production use.

* Dropped Debian bullseye from the platforms the release workflow builds
  packages for. It has reached end of life.

* Removed the old Z0DAN Python files and their TAP test. `add_node` and
  `remove_node` are provided by the SQL implementation.

* New documentation on running logical slot failover under Patroni on
  PostgreSQL 17 and later. It covers the parameters you need, the settings to
  put in the bootstrap DCS, and what to do about `synchronized_standby_slots`
  on a switchover. A sample Patroni `on_role_change` callback,
  `samples/set_synchronized_standby_slots.sh`, resets
  `synchronized_standby_slots` after a promotion. See
  [Logical Slot Failover](logical_slot_failover.md).

* Documented the `wait_if_disabled` argument of `spock.wait_for_sync_event()`.

* TAP suite: tests share one set of log and wait helpers instead of each
  carrying a copy, cluster startup waits for the servers to be ready instead
  of sleeping 17 seconds, and a single test can be run on its own with
  `prove`. New tests cover retry after temporary errors, real deadlocks,
  replay mode carrying over between transactions,
  `spock.get_lsn_from_commit_ts()`, a worker restart in the middle of a
  transaction, and a column missing on the subscriber.

## Spock 5.0.11

### New Features
* Add `spock.use_native_failover_slots` (default off, PGC_POSTMASTER). When
  enabled, spock marks logical slots with the FAILOVER flag on PG17+, yields to
  PostgreSQL's native slotsync worker on PG17 when `sync_replication_slots=on`,
  and does not register spock's own failover-slot worker on PG18+. Off preserves
  the existing worker-based behavior. Read on the subscriber node that creates
  the logical replication slot; changing it requires a server restart. See
  [Logical Slot Failover](logical_slot_failover.md) for setup steps and the
  required post-promotion `synchronized_standby_slots` runbook.

* Sync failover slots to the standby every 1s by default instead of a
  hard-coded 60s, shrinking the window in which a promotion can find a stale
  slot. The interval is now tunable via `spock.failover_slots_naptime` (and the
  feedback-wait retry via `spock.failover_slots_feedback_naptime`), both
  SIGHUP-settable in milliseconds

* Never copy the `pgedge_ace` schema to a node joining via `add_node`. ACE
  state is node-local, so its objects are now excluded from both the schema
  copy and the data sync, even when an ACE table belongs to a replication set.

### Bug Fixes

* Fixed a bug where a transient provider connection loss could incorrectly
  disable a subscription under SUB_DISABLE exception handling. A transaction
  retransmitted after a reconnect is no longer misclassified as an apply
  failure, so replication resumes normally instead of stopping.


## Spock 5.0.10

### Bug Fixes
* Improve apply performance on tables with a unique index over a frequently
  NULL column. Rows with a NULL in such a key are now recognized as
  non-conflicting without an unnecessary index scan, avoiding a slowdown that
  grew with table size.
* Correctly handle conflicts on `NULLS NOT DISTINCT` unique indexes.
  On these indexes (PostgreSQL 15+) two NULL values are treated as equal, so
  matching NULL-keyed rows are now resolved through normal conflict resolution
  (last-update-wins) instead of failing with a duplicate-key error.
* Fix a `could not open relation` error in the apply worker when an index is
  dropped while replication is running. The worker now refreshes its cached
  view of a table's indexes before using it.
* Fix gradual memory growth during a transaction that logs to
  `spock.exception_log`. Memory used while recording exceptions is now released
  per row instead of accumulating until the transaction commits.
* Record the real cause of a discarded transaction in `spock.exception_log`
  instead of the opaque placeholder `unavailable`. The failing command's
  message is now stored (prefixed with its SQLSTATE where informative), and the
  other rows of the transaction note that they were discarded as collateral,
  making it possible to provide the root cause of the exception.
* Fix ZODAN (`add_node`) version checking. Spock versions were compared as
  text, so `5.0.10` sorted below `5.0.4` and a valid node was wrongly rejected.
  Versions are now compared numerically, and nodes may differ in patch level as
  long as their major.minor matches, allowing rolling upgrades.
* Fix a spurious "tiebreaker values are equal" WARNING on timestamp-tied
  conflicts in single-writer topologies (and on node-id hash collisions). The
  tiebreaker now compares the applying node against the remote sender, and
  node-id collisions are detected at node creation.

## Spock 5.0.9

### New Features
* Initial PostgreSQL 19 support. Adds the server-side patches required to build
  and run Spock against PostgreSQL 19.

### Bug Fixes
* Fix silently dropped writes after a synchronous-standby failover.
  Spock could report an incorrect replication position to the publisher, so a
  promoted standby resumed from the wrong point and lost the changes in
  between. The position reported to the publisher is now always taken from the
  publisher's own WAL stream.
* Fix `spock_failover_slots` stalling on PG17+ standbys. Slot
  synchronization could hold replication-slot and proc-array locks
  exclusively long enough to block every backend trying to start up on the
  standby, freezing the worker and any new connections. The sync path now
  uses shorter, shared locks matching PostgreSQL's own slot code.
* Fix manager-worker respawn loop when databases are dropped or have
  connections disabled (`datconnlimit = -2`) concurrently with Spock
  starting a per-database worker. The database OID is now revalidated
  immediately before the worker is registered to avoid race.
* Reduce per-row work and memory growth in the apply path. Replicated
  changes no longer re-open a table's indexes for every row, and transient
  memory is freed per row instead of building up over the transaction.

### Performance
* Skip building conflict log messages that would not be logged. When the log
  level is suppressed, Spock no longer formats the conflicting rows for an
  `ereport()` that would be discarded, speeding up apply on high-conflict
  workloads. Recording conflicts in `spock.resolutions` is unaffected.

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
