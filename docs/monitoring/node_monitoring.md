# Monitoring a Node with the Spock Status Views

Spock keeps the state of a node in shared memory and exposes it through a
set of views in the `spock` schema. Together they answer the questions an
operator would otherwise take to the server log: is every subscription
replicating, which workers are running, how far behind is each provider,
how much WAL is a slot holding back, and what happened recently.

| View | One row per | Purpose |
|------|-------------|---------|
| `spock.system_status` | host | Host and instance health: disk, load, connections, long transactions, wraparound age, archiving. |
| `spock.node_status` | node | The whole node on one row: versions, counts, WAL, lag, last events. |
| `spock.subscription_status` | subscription | Configuration, status, serving worker, replication position and lag, last error. |
| `spock.subscription_stats` | subscription | Activity counters: worker starts, connects, transactions, tuples, conflicts, errors. |
| `spock.worker_status` | spock process | Supervisor, manager, apply and sync workers with their state. |
| `spock.slot_status` | replication slot | Provider side: walsender state, positions and retained WAL per spock slot. |
| `spock.table_sync_status` | subscription or table | Initial synchronization state in readable form. |
| `spock.peer_status` | known node | Every node this node knows, with the subscription that brings its changes here. |
| `spock.replication_set_status` | replication set | Replication sets of the local node with table, sequence and subscriber counts. |
| `spock.settings` | parameter | The spock parameters and the core parameters replication depends on. |
| `spock.events` | event | Recent state changes: enable, disable, restarts, errors, upgrades. |

`spock.spock_info()` runs all of them one after another and returns the
node as a single text report; see [The full report](#the-full-report).

All views are scoped to the current database. `spock.lag_tracker`,
`spock.progress` and the `spock.channel_*_stats` views remain available and
feed the views above.

## System status

`spock.system_status` is one row about the host and the PostgreSQL
instance. It answers the questions that come before any replication
question: is the disk full, is the machine overloaded, are connections
exhausted, is a long or idle transaction holding back vacuum and the
replication slots, is WAL archiving failing.

| Column | Description |
|--------|-------------|
| `hostname`, `os_name`, `os_release`, `architecture`, `cpu_count`, `memory_bytes` | The host. |
| `load_average_1min`, `load_average_5min`, `load_average_15min` | System load averages. |
| `data_directory`, `data_disk_total_bytes`, `data_disk_free_bytes` | The data directory and the space on its volume. |
| `wal_disk_total_bytes`, `wal_disk_free_bytes`, `wal_size_bytes` | The volume holding `pg_wal`, measured separately in case it is a symlink, and the size of `pg_wal`. |
| `database_size_bytes` | Size of the current database. |
| `postgres_version`, `postmaster_pid`, `postmaster_start_time`, `uptime`, `in_recovery` | The instance. |
| `max_connections`, `connections`, `active_connections`, `idle_in_transaction` | Client connections and their state. |
| `longest_transaction`, `longest_idle_in_transaction` | Age of the oldest open transaction and of the oldest idle one; both hold back vacuum and slot `catalog_xmin`. |
| `waiting_on_locks` | Sessions currently waiting for a lock. |
| `prepared_transactions` | Prepared transactions, which hold locks and xmin until resolved. |
| `physical_standbys` | Streaming replicas other than spock subscribers. |
| `oldest_xid_age` | Age of the database's oldest transaction id, towards wraparound. |
| `xact_commit`, `xact_rollback`, `deadlocks`, `recovery_conflicts`, `temp_files`, `temp_bytes`, `checksum_failures`, `database_stats_reset` | From `pg_stat_database` for this database. |
| `archive_mode`, `archived_count`, `last_archived_time`, `archive_failed_count`, `last_archive_failure` | WAL archiving state; a failing archiver fills the WAL volume. |

```sql
SELECT pg_size_pretty(data_disk_free_bytes) AS data_free,
       pg_size_pretty(wal_disk_free_bytes) AS wal_free,
       load_average_1min, connections, max_connections,
       longest_transaction, idle_in_transaction, deadlocks,
       archive_failed_count, last_archive_failure
  FROM spock.system_status;
```

## Node status

`spock.node_status` always returns exactly one row, even before a node has
been created.

| Column | Description |
|--------|-------------|
| `node_id`, `node_name`, `location`, `country` | The local node, NULL when none exists. |
| `database_name` | The current database. |
| `hostname`, `operating_system`, `postmaster_start_time` | The host and the server start. |
| `spock_version` | Version of the loaded shared library. |
| `extension_version` | Version of the installed extension in the catalog. |
| `extension_update_pending` | True when the library is newer than the extension; the manager runs `ALTER EXTENSION UPDATE` on its next start. |
| `postgres_version` | Server version. |
| `spock_started_at` | When spock shared memory was initialized, normally the postmaster start. |
| `postmaster_pid`, `supervisor_pid`, `manager_pid` | Process ids of the postmaster, the supervisor and this database's manager. |
| `readonly_mode` | Current value of `spock.readonly`. |
| `apply_paused` | True while `spock.pause_apply_workers()` is in effect. |
| `worker_slots`, `worker_slots_used` | Background worker slots spock can use and how many are taken. |
| `subscriptions`, `subscriptions_enabled`, `subscriptions_replicating` | Subscription counts. |
| `replication_slots`, `replication_slots_active` | Spock slots of this database and how many have a connected walsender. |
| `apply_workers`, `sync_workers` | Running worker counts. |
| `workers_restart_pending` | Workers that exited with an error and wait for the manager to restart them. |
| `pending_exceptions` | Transactions currently being retried under `spock.exception_behaviour`. |
| `replicated_tables`, `unreplicated_tables` | Tables of this node in some replication set, and tables in none. |
| `current_wal_lsn` | Current WAL position, replay position on a standby. |
| `wal_size_bytes` | Size of `pg_wal`. |
| `data_disk_free_bytes`, `wal_disk_free_bytes` | Free space on the volumes holding the data directory and `pg_wal`. |
| `max_retained_wal_bytes` | WAL held back by the slowest spock slot. |
| `max_replication_lag_bytes`, `max_replication_lag` | Largest lag over all subscriptions. |
| `exceptions_logged` | Rows in `spock.exception_log`. |
| `last_event_time`, `last_error_event_time` | Time of the newest event, and of the newest error event. |
| `events_retained`, `events_recorded` | Events kept in the history and recorded since start. |

```sql
SELECT node_name, extension_update_pending, subscriptions_replicating,
       replication_slots_active, workers_restart_pending,
       pg_size_pretty(max_retained_wal_bytes) AS retained_wal,
       max_replication_lag, last_error_event_time
  FROM spock.node_status;
```

## Subscription status

`spock.subscription_status` is the first place to look when replication
seems stuck.

| Column | Description |
|--------|-------------|
| `subscription_id`, `subscription_name`, `enabled` | The subscription. |
| `status` | `replicating`, `initializing`, `down` (enabled but no worker), `disabled` or `unknown`. |
| `provider_node`, `provider_dsn` | The provider; the password in the DSN is replaced with asterisks. |
| `slot_name`, `replication_sets`, `forward_origins`, `apply_delay`, `skip_lsn`, `skip_schema`, `force_text_transfer`, `created_at` | Configuration. |
| `sync_status` | Initial synchronization state of the subscription as a whole. |
| `worker_pid`, `worker_status`, `worker_started_at` | The apply worker. `worker_status` is `restart pending` after a failure. |
| `worker_terminated_at`, `worker_restart_delay` | When the last worker failed and how long the manager waits before restarting it, in milliseconds. |
| `worker_paused` | True while the worker sleeps because apply is paused. |
| `in_exception_handling` | True while the worker replays a failed transaction under `spock.exception_behaviour`. |
| `pending_exception_lsn`, `pending_exception_error` | Commit LSN and first error of the transaction being retried, if any. |
| `origin_lsn` | Last durably applied provider LSN from `pg_replication_origin_status`. |
| `remote_commit_lsn`, `remote_commit_ts`, `remote_insert_lsn`, `received_lsn` | Positions from `spock.progress`. |
| `replication_lag_bytes` | WAL the provider has written that this node has not yet applied. |
| `replication_lag` | Time between the last applied commit on the provider and its apply here. |
| `last_message_received`, `last_xact_applied` | When data last arrived from the provider and when a transaction was last committed here. |
| `time_since_last_message` | How long ago data last arrived; a silent provider shows here first. |
| `worker_blocked_by_pids`, `worker_blocking_pid`, `worker_blocking_query` | Set while the worker waits for a lock: the sessions holding it and what the first one runs. |
| `worker_starts`, `worker_failures`, `xacts_applied`, `apply_errors` | Counters from `spock.subscription_stats`. |
| `last_apply_error`, `last_error_sqlstate`, `last_error_pid`, `last_error_message` | The most recent error of the apply worker: when, its SQLSTATE, the process that raised it, and the message with DETAIL and CONTEXT. |

```sql
SELECT subscription_name, status, worker_status, replication_lag,
       pg_size_pretty(replication_lag_bytes) AS lag, last_error_message
  FROM spock.subscription_status;
```

## Subscription statistics

`spock.subscription_stats` has one row for every subscription with the
counters collected by its apply and sync workers. Counters survive worker
restarts and are reset with `spock.reset_subscription_stats(subid)`, or for
all subscriptions with no argument. Every counter has a matching `last_*`
timestamp of its most recent change.

| Column | Description |
|--------|-------------|
| `worker_starts`, `worker_failures` | Worker starts, and exits with an error. |
| `provider_connects`, `provider_disconnects`, `idle_timeouts` | Connections to the provider, connection losses, and reconnects forced by `spock.apply_idle_timeout`. |
| `messages_received`, `bytes_received` | Data messages received from the provider. |
| `xacts_applied`, `xacts_skipped`, `xacts_discarded` | Transactions committed locally, skipped through `sub_skip_lsn`, and discarded under `transdiscard`. |
| `apply_errors`, `sync_errors` | Errors raised in apply and in sync workers. An apply error counts once per failed transaction. |
| `deadlocks`, `lock_timeouts`, `constraint_violations`, `resource_errors` | The same errors classified by SQLSTATE: deadlock detected, lock not available, class 23 and class 53. |
| `tables_synced` | Tables whose initial synchronization completed. |
| `n_tup_ins`, `n_tup_upd`, `n_tup_del`, `n_conflict`, `n_dca` | Tuple counters, summed from `spock.channel_table_stats`. |
| `confl_*` | Conflict counters by type; NULL before PostgreSQL 18. |
| `last_error_message`, `last_error_lsn`, `last_error_sqlstate`, `last_error_pid` | The most recent worker error with DETAIL and CONTEXT, the provider LSN it happened at, its SQLSTATE and the process that raised it. |
| `stats_reset` | When the counters were last reset. |

## Workers

`spock.worker_status` lists the supervisor, the manager of this database,
and every apply and sync worker, including slots of failed workers that are
waiting to be restarted.

| Column | Description |
|--------|-------------|
| `worker_slot`, `worker_type`, `pid` | Slot in shared memory, `supervisor`, `manager`, `apply` or `sync`, and process id. |
| `worker_status` | `starting`, `running`, `idle`, `stopping`, `stopped`, `failed` or `restart pending`. |
| `subscription_id`, `subscription_name` | For apply and sync workers. |
| `sync_schema_name`, `sync_table_name` | The table a sync worker copies. |
| `started_at`, `xact_start`, `backend_state`, `wait_event_type`, `wait_event` | From `pg_stat_activity`. |
| `blocked_by_pids`, `blocking_pid`, `blocking_xact_start`, `blocking_query` | Set while the worker waits for a lock held by another session, from `pg_blocking_pids()`. |
| `paused`, `in_exception_handling`, `sync_pending` | Apply worker flags. |
| `replay_stop_lsn`, `remote_wal_insert_lsn` | Positions the worker works towards and has last seen on the provider. |
| `generation`, `terminated_at`, `restart_delay` | Registration counter, time of the last failure, restart delay in milliseconds. |

## Replication slots

`spock.slot_status` is the provider side view: one row per spock
replication slot of the current database, joined with the walsender that
serves it.

| Column | Description |
|--------|-------------|
| `slot_name`, `active`, `active_pid` | The slot and its walsender. |
| `client_name`, `client_addr`, `connected_at`, `state` | The connected subscriber, from `pg_stat_replication`. |
| `restart_lsn`, `confirmed_flush_lsn`, `sent_lsn`, `write_lsn`, `flush_lsn`, `replay_lsn` | Positions. |
| `retained_wal_bytes` | WAL kept on disk for this slot. |
| `pending_wal_bytes` | WAL the subscriber has not confirmed yet. |
| `write_lag`, `flush_lag`, `replay_lag`, `last_reply_time` | Feedback timing. |
| `wal_status`, `safe_wal_size`, `catalog_xmin`, `catalog_xmin_age`, `temporary`, `two_phase` | From `pg_replication_slots`; a growing `catalog_xmin_age` means the slot holds back catalog vacuum. |
| `decoded_txns`, `decoded_bytes`, `spill_*`, `stream_*`, `decode_stats_reset` | Decoding work done for the slot, from `pg_stat_replication_slots`. Growing `spill_bytes` means transactions larger than `logical_decoding_work_mem`. |
| `slot_group_*` | Shared state of the slot group, for parallel slots only. |

```sql
SELECT slot_name, active, state, pg_size_pretty(retained_wal_bytes) AS retained,
       pg_size_pretty(pending_wal_bytes) AS pending, replay_lag
  FROM spock.slot_status;
```

## Peers, replication sets and settings

`spock.peer_status` lists every node in `spock.node` with its interfaces
(passwords hidden), whether it is the local node, and the subscription that
brings its changes here with that subscription's status and lag. A node
with several subscriptions has one row per subscription.

`spock.replication_set_status` lists the replication sets of the local node
with their replicate flags, the number of tables and sequences in each, and
how many local subscriptions include the set. Tables that are in no set at
all are listed by `spock.tables` where `set_name IS NULL`.

`spock.settings` shows every `spock.*` parameter and the core parameters
replication depends on (`wal_level`, `max_worker_processes`,
`max_replication_slots`, `max_wal_senders`, `max_slot_wal_keep_size`,
`track_commit_timestamp`, `shared_preload_libraries`, the walsender and
walreceiver timeouts, synchronous commit settings and
`logical_decoding_work_mem`), with unit, source and whether a restart is
pending. Connection strings in parameters have their password hidden.

## Events

`spock.events` is a ring of recent state changes kept in shared memory,
oldest first. The number of events kept is set by
`spock.event_history_size`. The history is cleared by a postmaster restart
and by `spock.reset_events()`.

| Column | Description |
|--------|-------------|
| `event_id` | Increases by one per event and is never reused. |
| `event_time`, `event_type`, `severity` | When, what, and `info`, `warning` or `error`. |
| `sqlstate` | The SQLSTATE of a `worker_error` or `stream_error` event. |
| `subscription_id`, `subscription_name`, `provider_node` | The subscription concerned, if any, and the node its changes come from. |
| `pid` | The reporting process. |
| `lsn` | The provider LSN the event refers to: the start position of a stream, the commit LSN of a skipped, discarded or failed transaction, the position a subscription was disabled at. NULL for lifecycle events such as worker starts. |
| `detail` | A short description. |

Event types:

| Type | Recorded when |
|------|---------------|
| `node_created`, `node_dropped` | `spock.node_create()` and `spock.node_drop()` complete. |
| `subscription_created`, `subscription_dropped` | A subscription is created or dropped. |
| `subscription_enabled`, `subscription_disabled` | A subscription is enabled or disabled, by an operator or by exception handling. |
| `subscription_altered` | Interface, replication sets, `skip_lsn`, options or a synchronization request changed. |
| `worker_started`, `worker_stopped`, `worker_failed` | A manager, apply or sync worker starts, exits cleanly, or exits with an error. |
| `worker_error` | An error is raised inside an apply or sync worker. The detail carries the message with DETAIL and CONTEXT. |
| `provider_connected`, `provider_disconnected` | The replication connection to the named provider is established, with the start LSN, or lost, with the error. |
| `transaction_skipped`, `transaction_discarded` | A transaction is skipped through `sub_skip_lsn` or discarded under `transdiscard`. |
| `sync_started`, `sync_finished`, `sync_failed` | Initial copy of a table. |
| `slot_created`, `stream_started`, `stream_stopped`, `stream_error` | Provider side: a spock slot is created, a walsender starts streaming to a subscriber (its address, spock version and protocol in the detail, the slot position in `lsn`), stops, or fails with an error while decoding. |
| `apply_paused`, `apply_resumed` | `spock.pause_apply_workers()` and `spock.resume_apply_workers()`. |
| `repair_mode_enabled`, `repair_mode_disabled` | `spock.repair_mode()`. |
| `extension_upgraded` | The manager updated the extension to the library version. |

Events are recorded when the reporting code runs, whether or not the
surrounding transaction commits.

```sql
SELECT event_time, event_type, subscription_name, detail
  FROM spock.events
 WHERE severity <> 'info'
 ORDER BY event_id DESC
 LIMIT 20;
```

## The full report

`spock.spock_info()` returns the whole node as text, section by section:
system status, installed extensions, settings, node status, peers,
subscriptions, subscription statistics, workers, pending exceptions,
replication slots, replication sets, tables in no replication set, table
synchronization, lag by node pair, recent exceptions, recent conflict
resolutions and recent events. Wide views are printed one row per block,
lists as aligned tables. A section whose query fails, for example
`node_status` for a user without `pg_monitor`, prints one error line and
the report continues.

```sql
SELECT * FROM spock.spock_info();
SELECT * FROM spock.spock_info(200);   -- list up to 200 events, exceptions and resolutions
```

In `psql`, `\pset format unaligned` and `\o report.txt` before the call
produce a plain file that can be attached to a ticket. The report contains
no passwords.

`spock.report_section(title, query, expanded)` is the formatter behind
the report and can render any query the same way.

## Common tasks

The recipes below cover the questions that used to require the server log.
Run them in `psql` with expanded output (`\x`) when a row is wide.

### Is the node healthy?

One row answers it. Anything other than zero in `workers_restart_pending`,
a difference between `subscriptions_enabled` and `subscriptions_replicating`,
or a `last_error_event_time` that is more recent than you expect deserves a
look.

```sql
SELECT node_name, extension_update_pending,
       subscriptions_enabled, subscriptions_replicating,
       workers_restart_pending, apply_paused, readonly_mode,
       pg_size_pretty(max_retained_wal_bytes) AS retained_wal,
       max_replication_lag, last_error_event_time
  FROM spock.node_status;
```

### Why is a subscription not replicating?

Start with the subscription row. `status` tells whether a worker runs at
all, `worker_status` and `worker_terminated_at` show a failed worker
waiting for its restart delay, and `last_error_message` is the error the
worker last raised, without opening the log.

```sql
SELECT subscription_name, status, enabled, worker_status,
       worker_terminated_at, worker_restart_delay,
       in_exception_handling, last_apply_error, last_error_message
  FROM spock.subscription_status
 WHERE status <> 'replicating';
```

Then read the events of that subscription, newest first:

```sql
SELECT event_time, event_type, severity, detail
  FROM spock.events
 WHERE subscription_name = 'sub_n2_n1'
 ORDER BY event_id DESC
 LIMIT 20;
```

A subscription that was disabled by exception handling shows a
`subscription_disabled` event with the detail `disabled by exception
handling` and the origin LSN of the failing transaction in `lsn`; the row in
`spock.exception_log` has the failing tuple.

### Is a worker blocked or deadlocking?

A worker waiting for a lock shows `wait_event_type = 'Lock'` and the
session holding the lock in `blocked_by_pids` and `blocking_query`. A
deadlock or lock timeout aborts the transaction; the worker exits and is
restarted, and the error is classified.

```sql
SELECT worker_type, subscription_name, wait_event_type, wait_event,
       blocked_by_pids, blocking_pid, blocking_xact_start, blocking_query
  FROM spock.worker_status
 WHERE blocked_by_pids IS NOT NULL;

SELECT subscription_name, deadlocks, lock_timeouts,
       constraint_violations, resource_errors,
       last_error_sqlstate, last_apply_error, last_error_message
  FROM spock.subscription_stats;
```

### Is a worker restarting in a loop?

`worker_starts` and `worker_failures` climb together when a worker crashes
on every attempt. The events show the interval and the reason.

```sql
SELECT subscription_name, worker_starts, worker_failures,
       last_worker_failure, last_error_message
  FROM spock.subscription_stats
 WHERE worker_failures > 0;

SELECT event_time, event_type, detail
  FROM spock.events
 WHERE event_type IN ('worker_started', 'worker_failed', 'worker_error')
 ORDER BY event_id DESC
 LIMIT 30;
```

### What changed overnight?

Everything that is not routine has a severity above `info`.

```sql
SELECT event_time, event_type, severity, subscription_name, detail
  FROM spock.events
 WHERE event_time > now() - interval '12 hours'
   AND severity <> 'info'
 ORDER BY event_id;
```

Enable and disable calls, interface switches, replication set changes,
`sub_skip_lsn`, pause and resume, repair mode and extension upgrades are
all `info` or `warning` events with the operator's backend pid in `pid`.

### How far behind is each provider?

```sql
SELECT subscription_name, provider_node,
       pg_size_pretty(replication_lag_bytes) AS lag_bytes,
       replication_lag, remote_commit_ts, received_lsn, origin_lsn
  FROM spock.subscription_status
 ORDER BY replication_lag_bytes DESC NULLS LAST;
```

`replication_lag_bytes` is WAL the provider has written that this node has
not applied yet. `replication_lag` is the time between the last applied
commit on the provider and its apply here. Both come from
`spock.progress` and are also available per node pair in
`spock.lag_tracker`.

### Is a slot holding back WAL on the provider?

Run this on the provider. A slot with `active = false` or a growing
`retained_wal_bytes` points at a subscriber that is down or lagging.

```sql
SELECT slot_name, active, client_name, state,
       pg_size_pretty(retained_wal_bytes) AS retained,
       pg_size_pretty(pending_wal_bytes) AS pending,
       replay_lag, last_reply_time, wal_status
  FROM spock.slot_status
 ORDER BY retained_wal_bytes DESC;
```

### Is the initial synchronization finished?

```sql
SELECT subscription_name, schema_name, table_name, sync_kind, sync_status
  FROM spock.table_sync_status
 WHERE sync_status NOT IN ('ready', 'synchronized');
```

The row without a table is the subscription itself. Sync workers in flight
are listed in `spock.worker_status` with `worker_type = 'sync'` and the
table they copy.

### Did the extension get upgraded?

`spock.node_status` compares the loaded library with the installed
extension. After a binary upgrade the manager updates the extension on its
next start and records the change.

```sql
SELECT spock_version, extension_version, extension_update_pending
  FROM spock.node_status;

SELECT event_time, detail
  FROM spock.events
 WHERE event_type = 'extension_upgraded';
```

### Starting a fresh measurement

Counters and events accumulate since the postmaster started. Reset them
before a benchmark or after fixing an incident so that the next numbers are
clean.

```sql
SELECT spock.reset_subscription_stats();   -- all subscriptions
SELECT spock.reset_subscription_stats(sub_id)
  FROM spock.subscription WHERE sub_name = 'sub_n2_n1';
SELECT spock.reset_events();
```

`spock.reset_channel_stats()` clears the per-table tuple counters
separately.

### Watching from outside

The views are plain SQL, so any monitoring agent can poll them. Poll
`spock.events` by `event_id` to fetch only new rows, and treat a gap in
ids as history that was dropped because `spock.event_history_size` was too
small for the polling interval. `spock.get_monitor_summary()` reports how
full the event ring and the counters table are.

## Underlying functions

The views are built on functions that return the raw shared memory
contents. They are useful for tooling that wants unfiltered rows.

| Function | Returns |
|----------|---------|
| `spock.get_worker_status()` | Every worker slot of the cluster, with `database_id`. |
| `spock.get_events()` | Every event in the history, with `database_id`. |
| `spock.get_apply_stats()` | The counters of every subscription of the current database. |
| `spock.get_slot_groups()` | Slot groups with attached walsenders. |
| `spock.get_monitor_summary()` | Capacity and usage of the shared memory structures. |
| `spock.get_system_info()` | Host name, operating system, CPU, memory, load averages, disk space of the data and WAL volumes, postmaster start, PostgreSQL and spock versions. |
| `spock.get_pending_exceptions()` | Transactions being retried under exception handling, with their first error. |
| `spock.reset_events()` | Clears the event history. |
| `spock.reset_subscription_stats(subid)` | Resets the activity and conflict counters of one or all subscriptions. |
| `spock.redact_dsn(text)` | Returns a connection string with its password hidden. |
