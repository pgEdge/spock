# Spock Node Monitoring: Design of the spock_monitor subsystem

**Date:** 2026-09-23
**Status:** Implemented, regression tested
**Component:** `src/spock_monitor.c`, `include/spock_monitor.h`
**PostgreSQL:** 15 to 19

A Word version of this document is kept next to it as
`spock-monitor-design.docx`.

## 1. Summary

Operators of a Spock cluster have had to read the PostgreSQL server log to
answer routine questions: is every subscription replicating, did a worker
restart overnight, why was a subscription disabled, how much WAL is a slot
holding back, did the extension get upgraded. The catalog and the existing
statistics views describe configuration and cumulative counters but not
state changes or failures.

The monitoring subsystem records state changes as events and keeps
per-subscription activity counters in shared memory, and exposes them
together with worker, slot and replication progress through seven views in
the `spock` schema. A query against `spock.node_status` or
`spock.subscription_status` gives the complete picture of a node;
`spock.events` gives the recent history. The module is also the single home
of all monitoring C code, absorbing the channel counters, the apply group
progress function and the slot confirmation wait.

## 2. Goals and non-goals

### Goals

* Replace log reading for day to day operation: every notable state change
  is queryable.
* One row per node, per subscription, per worker and per slot, with column
  names that need no legend.
* Cheap on the apply hot path: a spinlock and a few integer adds per
  message, no catalog writes, no WAL.
* Safe in error paths: recording an error must never allocate memory, block
  or raise.
* Same source on every supported PostgreSQL version; version specific data
  such as the PG18 conflict counters degrade to NULL.
* One module for all monitoring code, with PostgreSQL naming and layout
  conventions.

### Non-goals

* Durability across a postmaster restart. Events and counters live in
  shared memory only; the catalog and pgstat remain the durable stores.
* Transactional semantics. An event is recorded when the reporting code
  runs, whether or not its transaction commits.
* Cluster wide aggregation. Each node reports about itself; a fleet view is
  left to external tooling that reads the views on every node.

## 3. Architecture

The subsystem has three layers: shared memory structures written by spock
processes, C functions that read them and return rows, and SQL views that
join those rows with the catalogs and with core views such as
`pg_stat_replication` and `pg_stat_activity`.

| Layer | Elements | Owner |
|-------|----------|-------|
| Shared memory | Event ring (`SpockMonitorShmem`), per-subscription counters (`SpockMonitorStatsHash`) | `spock_monitor.c`, allocated by `spock_shmem.c` |
| Producers | Worker attach and detach, apply loop, sync worker, output plugin, node and subscription management functions, exception handler, extension manager, `emit_log_hook` | One call at each site |
| SQL functions | `get_worker_status`, `get_events`, `get_apply_stats`, `get_slot_groups`, `get_monitor_summary`, `reset_events`, `reset_subscription_stats`, `get_channel_stats`, `reset_channel_stats`, `apply_group_progress`, `wait_slot_confirm_lsn` | `spock_monitor.c` |
| Views | `node_status`, `subscription_status`, `subscription_stats`, `worker_status`, `slot_status`, `table_sync_status`, `events` | `sql/spock--6.0.0.sql` and the 5.0.11 upgrade script |

Producers never format SQL or touch the catalog. They call one of a handful
of functions declared in `spock_monitor.h`, which copy fixed size data into
shared memory under a lock. Readers take a consistent copy of each entry
and build tuples outside any spinlock.

## 4. Shared memory

### 4.1 Event ring

Events are stored in a fixed size ring inside one `ShmemInitStruct`
allocation named `spock monitor`. The capacity is the
`spock.event_history_size` GUC (default 1024, `PGC_POSTMASTER`).

```c
typedef struct SpockMonitorEvent
{
    uint64      event_id;      /* increases by one, never reused */
    TimestampTz event_time;
    SpockMonitorEventType event_type;
    Oid         dboid;         /* database of the reporting process */
    Oid         subid;         /* subscription, or InvalidOid */
    int         pid;
    int         sqlerrcode;    /* SQLSTATE of an error event, else 0 */
    XLogRecPtr  lsn;           /* origin LSN, if any */
    char        detail[512];
} SpockMonitorEvent;
```

The header holds the LWLock, the time shared memory was initialized
(reported as `spock_started_at`), the next event id, and head and count
indexes. Appending when full advances the head, so the oldest event is
dropped. Event ids keep increasing across resets, which lets a poller detect
both new events and gaps. The ring is cluster wide; the views filter on the
current database and keep events without a database, such as those of the
supervisor.

Each event type has a fixed name and severity in a table indexed by the
enum, so adding a type means adding one enum member and one table row.
Severities are `info`, `warning` and `error`; `warning` covers state changes
an operator would want to know about even when they were requested, such as
a subscription being disabled, repair mode being switched on or a
transaction being skipped.

### 4.2 Per-subscription counters

Counters live in a fixed size shared hash keyed by `(dboid, subid)`, sized
at `max(64, 4 * max_worker_processes)` entries. The multiple leaves room for
disabled subscriptions whose history should survive while they are down.

```c
typedef struct SpockMonitorStatsEntry
{
    SpockMonitorStatsKey key;
    int64       counter[SPOCK_MONITOR_NUM_COUNTERS];
    TimestampTz counter_time[SPOCK_MONITOR_NUM_COUNTERS];
    XLogRecPtr  last_error_lsn;
    int         last_error_sqlerrcode;
    int         last_error_pid;
    char        last_error_message[512];
    TimestampTz stats_reset;
    slock_t     mutex;
} SpockMonitorStatsEntry;
```

Every counter carries the time of its last increment. That one rule gives
the view its `last_worker_start`, `last_provider_connect`,
`last_xact_applied` and `last_apply_error` columns without separate fields,
and keeps the reader generic: two small tables in `spock_get_apply_stats()`
map counters to count columns and to timestamp columns, checked at compile
time against the column enum.

| Counter | Incremented when |
|---------|------------------|
| `worker_starts` | An apply or sync worker attaches to its shared memory slot. |
| `worker_failures` | A worker detaches after an error exit. |
| `provider_connects` | `START_REPLICATION` succeeded. |
| `provider_disconnects` | `apply_work()` classified an error as connection loss. |
| `idle_timeouts` | `spock.apply_idle_timeout` forced a reconnect. |
| `messages_received`, `bytes_received` | A data message was read from the stream. |
| `xacts_applied` | A remote transaction committed locally. |
| `xacts_skipped` | A transaction was skipped through `sub_skip_lsn`. |
| `xacts_discarded` | A transaction was discarded under `transdiscard`. |
| `apply_errors`, `sync_errors` | An ERROR was raised in an apply or sync worker (section 6). |
| `deadlocks`, `lock_timeouts`, `constraint_violations`, `resource_errors` | The same errors classified by SQLSTATE. |
| `tables_synced` | A sync worker finished a table without failure. |

A worker caches a pointer to its entry in `MySpockMonitorStats` when it
attaches. Entries in a `HASH_FIXED_SIZE` shared hash are never moved, so the
pointer stays valid for the life of the process. Counting is then a
spinlock, an add and a timestamp. Backends that only record events do not
touch the hash.

Subscription ids come from a cycling sequence, so an id can be reused.
Each entry counts the workers attached to it. Dropping a subscription
removes the entry at once when no worker is attached; otherwise the entry
is only marked dropped and the last worker to detach removes it, so a
worker never writes through a pointer into a freed element. A worker that
attaches to an entry marked dropped, because the id was reused, resets it.

### 4.3 Locking

* One LWLock in the tranche `spock_monitor` protects the ring and the hash
  structure. Individual entries have a spinlock for their counters.
* The monitor lock is a leaf: no other lock is taken while holding it. It
  may be acquired while `SpockCtx->lock` is held, never the other way round.
* The error reporting path uses `LWLockConditionalAcquire` and skips the
  event if the lock is busy, so error reporting can never block.
* Readers hold the monitor lock only while copying the ring or the entries
  into local memory, so that error reporting, which only tries the lock,
  is not held off while a result is formatted.

## 5. Instrumentation points

Each producer adds one call at the place where the state change is already
logged, so the event and the log line always agree.

| Event type | Call site |
|------------|-----------|
| `node_created`, `node_dropped` | `spock_create_node()`, `spock_drop_node()` after the catalog change |
| `subscription_created`, `subscription_dropped` | `spock_create_subscription()`, `spock_drop_subscription()` |
| `subscription_enabled`, `subscription_disabled` | `spock_alter_subscription_enable()`, `spock_alter_subscription_disable()`, `spock_disable_subscription()` in the exception handler |
| `subscription_altered` | Interface change, replication set add and remove, `skip_lsn`, options, synchronize and resynchronize table |
| `worker_started`, `worker_stopped`, `worker_failed` | `spock_worker_attach()` and `spock_worker_detach()`; the failure detail carries the last recorded error message |
| `worker_error` | `emit_log_hook`, for any ERROR or FATAL in a spock worker |
| `provider_connected`, `provider_disconnected` | `spock_start_replication()`; the connection loss branch of `apply_work()` |
| `transaction_skipped`, `transaction_discarded` | `stop_skipping_changes()`; the `transdiscard` branch of `handle_commit()` |
| `sync_started`, `sync_finished`, `sync_failed` | `spock_sync_main()` and `spock_sync_worker_finish()` |
| `slot_created`, `stream_started`, `stream_stopped` | `pg_decode_startup()` with and without `is_init`; `pg_decode_shutdown()` |
| `apply_paused`, `apply_resumed` | `spock_pause_apply_workers()`, `spock_resume_apply_workers()` |
| `repair_mode_enabled`, `repair_mode_disabled` | `spock_repair_mode()` |
| `extension_upgraded` | `spock_manage_extension()` after `ALTER EXTENSION UPDATE` |

Worker start and stop are recorded in the generic attach and detach code,
so the manager, every apply worker and every sync worker are covered by two
call sites. The detach hook runs before `SpockCtx->lock` is taken, which
keeps the lock order simple.

## 6. Error capture

Rather than instrumenting each error site, the module hooks the existing
`emit_log_hook` installed by `spock.c`. `spock_monitor_report_error()` is
called for every report and applies these rules:

1. Ignore unless the process is a spock worker (`MySpockWorker` is set) or
   a walsender running the spock output plugin, and shared memory is
   attached.
2. Ignore levels below ERROR and at or above PANIC; a PANIC path must not
   take locks.
3. Ignore connection class errors (connection failure, admin shutdown,
   cannot connect now and the related codes), in a worker and in a
   walsender: a peer going away or an administrator terminating the
   process is not a fault of this node. The apply worker reports its
   connection losses as `provider_disconnected` and flags the rethrow that
   follows so it is not counted a second time. `apply_work()` uses the same
   predicate to choose its connection-loss branch.
4. In a walsender, record a `stream_error` event with the slot name, the
   SQLSTATE and the message. The output plugin marks the process at
   startup and clears the mark at shutdown.
5. For apply and sync workers, bump `apply_errors` or `sync_errors` and the
   matching class counter (deadlock, lock timeout, constraint violation,
   resource error), and store the message, SQLSTATE, pid and the current
   origin LSN as the last error.
6. Record a `worker_error` event with the message and SQLSTATE, using a
   conditional lock acquire.

The message stored is the error message followed by the DETAIL and CONTEXT
lines, so a constraint violation carries the failing row and the apply
context. The function is guarded against re-entry and does no allocation:
the text is formatted with `snprintf` into fixed buffers.

An ERROR caught by a `PG_CATCH` is never emitted: PostgreSQL longjmps
before `EmitErrorReport()`, and the apply worker's handler copies and
flushes the error. The hook therefore only sees errors that end the worker.
The two paths of `apply_work()` that swallow an error, the first exception
that enters replay and the `sub_disable` path, call
`spock_monitor_report_error()` on the copied `ErrorData` themselves; the
paths that rethrow leave it to the hook so that an error is counted once.
Row level errors during a `discard` replay are not counted again, so
`apply_errors` counts failed transactions rather than failed rows.

## 7. SQL surface

### 7.1 Functions

Functions return raw shared memory rows and are the tooling interface. Set
returning functions use `InitMaterializedSRF` and OUT parameters; the C
code checks the column count against its enum with an assertion.

| Function | Returns |
|----------|---------|
| `spock.get_worker_status()` | Every worker slot in the cluster plus the supervisor, with `database_id` |
| `spock.get_events()` | Every event in the ring, oldest first, with `database_id` |
| `spock.get_apply_stats()` | Counters of every subscription of the current database, with PG18 conflict counters |
| `spock.get_slot_groups()` | Slot groups with attached walsenders |
| `spock.get_monitor_summary()` | One row: start time, supervisor pid, slot and capacity usage |
| `spock.get_system_info()` | One row: host name, operating system, CPU, memory, load averages, `statvfs()` of the data directory and of `pg_wal`, postmaster start, PostgreSQL and spock versions |
| `spock.get_pending_exceptions()` | Exception log slots with a recorded error: the transactions being retried |
| `spock.report_section(title, query, expanded)` | The rows of a query as text, values in PostgreSQL text form |
| `spock.spock_info(recent)` | The whole node as a text report, one section per view |
| `spock.reset_events()` | Empties the ring; ids keep increasing |
| `spock.reset_subscription_stats(subid)` | Resets activity and, on PG18, conflict counters of one or all subscriptions |
| `spock.redact_dsn(text)` | Connection string with the password hidden, keyword and URI forms |

### 7.2 Views

Views are named by what they show: `*_status` for state, `*_stats` for
counters. Columns use full words, never abbreviations, and the same word for
the same thing everywhere (`subscription_name`, `provider_node`,
`worker_pid`, `replication_lag_bytes`).

| View | Rows | Built from |
|------|------|------------|
| `spock.system_status` | Exactly one | `get_system_info()`, `pg_stat_activity`, `pg_prepared_xacts`, `pg_stat_replication`, `pg_database`, `pg_stat_database`, `pg_stat_archiver`, `pg_ls_waldir()` |
| `spock.node_status` | Exactly one | `get_monitor_summary()`, `local_node`, `pg_extension`, aggregates over the other views, `pg_ls_waldir()` |
| `spock.subscription_status` | One per subscription | `subscription`, `node`, `node_interface`, `local_sync_status`, `get_worker_status()` (lateral, running worker preferred), `pg_stat_activity`, `progress`, `pg_replication_origin_status`, `subscription_stats` |
| `spock.subscription_stats` | One per subscription | `get_apply_stats()` and `channel_summary_stats`, counters coalesced to zero |
| `spock.worker_status` | One per worker | `get_worker_status()`, `pg_stat_activity`, `pg_blocking_pids()` for the session holding a lock the worker waits for |
| `spock.slot_status` | One per spock slot | `pg_replication_slots`, `pg_stat_replication`, `get_slot_groups()`, current or replay WAL position |
| `spock.table_sync_status` | One per sync row | `local_sync_status` with readable kind and status |
| `spock.peer_status` | One per node and subscription | `node`, `node_interface`, `subscription_status` |
| `spock.replication_set_status` | One per replication set | `replication_set` with counts over its tables, sequences and subscriptions |
| `spock.settings` | One per parameter | `pg_settings`, spock parameters and the core replication parameters, DSNs redacted |
| `spock.events` | One per event | `get_events()`, `subscription` and `node` for the provider name |

The status text of a subscription is computed in SQL with the same rule as
`spock.sub_show_status()`: `replicating`, `initializing` or `unknown` while
a worker runs, otherwise `disabled` or `down`. Computing it in the view
keeps `node_status` usable before a local node exists, where the function
would raise an error.

The slot view uses only columns present in `pg_replication_slots` since
PostgreSQL 15, because one SQL script serves every version. It falls back
to `pg_last_wal_replay_lsn()` on a standby so it never raises during
recovery.

### 7.3 The report

`spock.spock_info()` is a plpgsql function that calls
`spock.report_section()` once per view. The formatter runs the query twice:
once through `row_to_json` to learn the column names in query order, then
with every column cast to text so that values appear as PostgreSQL prints
them rather than as JSON. Each section's query runs inside its own
exception block, so a failing view produces one error line instead of
aborting the report. Passwords never appear: the views already redact
connection strings, and `spock.settings` redacts the DSN parameters.

The exception handler keeps one shared slot per subscription with the
commit LSN of the transaction in flight and the first error raised for it.
`spock.get_pending_exceptions()` reports only slots with an error, because
the LSN alone is set for every transaction.

## 8. Compatibility and upgrade

* The same SQL section is appended to `spock--6.0.0.sql` and to
  `spock--5.0.11--6.0.0.sql`. Every catalog column the views reference
  exists since 5.0.6, so an upgraded node ends with the same objects as a
  fresh install.
* `spock.get_apply_worker_status()` is removed; nothing in the repository
  used it. `spock.get_worker_status()` and `spock.worker_status` replace it.
* `spock_monitoring.c` is removed. `spock.wait_slot_confirm_lsn()`,
  `spock.get_channel_stats()`, `spock.reset_channel_stats()` and
  `spock.apply_group_progress()` keep their SQL definitions and C symbols
  and now live in `spock_monitor.c`.
* `spock.reset_subscription_stats()` keeps its SQL definition and C symbol,
  so the existing upgrade script needs no change, but it now resets both
  counter sets and no longer raises before PostgreSQL 18.
* Conflict counters are fetched through the pgstat entry under
  `PG_VERSION_NUM >= 180000` and are NULL otherwise.
* Shared memory grows by the ring (about 300 bytes per event, 300 kB at the
  default) plus the hash (about 400 bytes per entry).

## 9. Testing

The regression test `tests/regress/sql/monitor.sql` runs after `basic` and
checks, on the provider, `node_status`, `worker_status`, `slot_status` and
the provider side events, and on the subscriber, `subscription_status`,
`worker_status`, `table_sync_status`, `subscription_stats` after real
traffic, the events of subscription creation and worker start, both reset
functions, and that disabling and enabling a subscription produces the
expected events and a worker restart that is visible in the counters.
Values that vary between runs are compared, not printed. The full suite of
41 tests passes on PostgreSQL 18.

## 10. Limitations and future work

* `spock.node_status` calls `pg_ls_waldir()` and therefore needs the
  `pg_monitor` role or a superuser. A version without the WAL size column
  would be readable by any user.
* The ring is cluster wide, so a database with heavy activity can age out
  the events of a quiet one. A per-database ring would remove this at the
  cost of more shared memory.
* Events and counters are lost at postmaster restart. If history across
  restarts is wanted, a background worker could periodically append events
  to a spock catalog table.
* `pg_replication_slots` columns added in PostgreSQL 17 (`failover`,
  `invalidation_reason`, `inactive_since`) are not shown; a version
  conditional view would be needed.
* Replication set changes on the provider (table added or removed) are not
  events; they are visible in the catalog and could be added with two call
  sites.
