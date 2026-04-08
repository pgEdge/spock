# Configuring Spock

Add the following `postgresql.conf` settings on each node in your Spock 
replication scenario before creating the Spock extension:

```sql
    wal_level = 'logical'
    max_worker_processes = 10   # one per database needed on provider node
                                # one per node needed on subscriber node
    max_replication_slots = 10  # one per node needed on provider node
    max_wal_senders = 10        # one per node needed on provider node
    shared_preload_libraries = 'spock'
    track_commit_timestamp = on # needed for conflict resolution
```

After modifying the parameters and restarting the Postgres server
with your OS-specific restart command, connect with psql and create the Spock
extension:

```sql
[pg18]$ sudo -u postgres psql -U postgres -p 5432
psql (18.1)
Type "help" for help.

postgres=# CREATE EXTENSION spock;
CREATE EXTENSION
```

You will also need to modify your
[`pg_hba.conf` file](https://www.postgresql.org/docs/18/auth-pg-hba-conf.html)
to allow logical replication connections from localhost and between nodes.
Logical replication connections are treated by `pg_hba.conf` as regular
connections to the provider database.

After modifying the pg_hba.conf file on each node, restart the server to apply
the changes.


## Advanced Configuration Options for Spock

You can use the following configuration parameters (GUCs) on the psql
command line with a `SET` statement or in a Postgres configuration file
(like `postgresql.conf`) to configure a Spock installation.

### `spock.allow_ddl_from_functions`

`spock.allow_ddl_from_functions` enables spock to automatically replicate
DDL statements that are called within functions to also be automatically
replicated. This can be turned `off` if these functions are expected to run
on every node. When this is set to `off`, statements replicated from
functions adhere to the same rule previously described for
`include_ddl_repset`. If a table possesses a defined primary key, it will be
added into the `default` replication set; alternatively, they will be added
to the `default_insert_only` replication set.

### `spock.batch_inserts`

`spock.batch_inserts` tells Spock to use batch insert mechanism if
possible. The batch mechanism uses Postgres internal batch insert mode which
is also used by `COPY` command.

### `spock.channel_counters`

`spock.channel_counters` is a boolean value (the default is `true`) that
enables or disables the Spock channel statistic information collection. This
option can only be set when the postmaster starts.

### `spock.check_all_uc_indexes`

!!! info

    This feature is experimental and `OFF` by default. Use this feature at
    your own risk.

This parameter enhances conflict resolution during `INSERT` operations in
scenarios where a row  exists that meets unique constraints defined on the
table (rather than primary keys or replication identity).

If this GUC is `enabled`, Spock will continue to check unique constraint
indexes, after checking the primary key / replica identity index.  Only one
conflict will be resolved, using Last-Write-Wins logic.  This includes the
primary key / replica identity index. If a second conflict occurs, an
exception is recorded in the `spock.exception_log` table.

Partial unique constraints are supported, but nullable unique constraints
are not. Deferable constraints are not supported, are filtered out and are
not checked, and therefore may still cause an exception during the final
commit.

Unique constraint indexes are checked in OID order, after the primary key.
It is therefore possible for the resolution of a unique constraint to change
the primary key value.

Child tables / foreign keys are not checked or handled. Therefore, if
resolving a unique constraint changes the primary key value, you can
inadvertently create orphaned foreign key records.

### `spock.conflict_resolution`

`spock.conflict_resolution` sets the resolution method for any detected
conflicts between local data and incoming changes. Possible values are:

* `error` - the replication will stop on error if conflict is detected and
  manual action is needed for resolving
* `apply_remote` - always apply the change that's conflicting with local
  data
* `keep_local` - keep the local version of the data and ignore the
  conflicting change that is coming from the remote node
* `last_update_wins` - the version of data with newest commit timestamp
  will be kept (this can be either local or remote version)

To enable conflict resolution, the `track_commit_timestamp` setting must be
enabled.

### `spock.deny_all_ddl`

`spock.deny_all_ddl` is a boolean value (the default is `false`) that
enables or disables the execution of DDL statements within a Spock
configured cluster. This option can be set at postmaster startup, with the
SIGHUP mechanism, or on the command line with SQL if you're a superuser.

### `spock.enable_ddl_replication`

`spock.enable_ddl_replication` enables
[automatic replication](managing/spock_autoddl.md) of ddl statements through
the `default` replication set.

### <a name="spock-exception_behaviour"></a>`spock.exception_behaviour`

Use this GUC to specify the commit behavior of Postgres when it encounters
an ERROR within a transaction:

* `transdiscard` (the default) - Set `spock.exception_behaviour` to
  `transdiscard` to instruct the server to discard a transaction if any
  operation within that transaction returns an `ERROR`.
* `discard` - Set `spock.exception_behaviour` to `discard` to continue
  processing (and replicating) without interrupting server use. The server
  will commit any operation (any portion of a transaction) that does not
  return an `ERROR` statement.
* `sub_disable` - Set `spock.exception_behaviour` to `sub_disable` to
  disable the subscription for the node on which the exception was reported.
  Transactions for the disabled node will be added to a queue that is
  written to the WAL log file; when the subscription is enabled, replication
  will resume with the transaction that caused the exception, followed by
  the other queued transactions. You can use the
  `spock.alter_sub_skip_lsn` function to skip the transaction that caused
  the exception and resume processing with the next transaction in the
  queue.

Note that the value you choose for `spock.exception_behaviour` could
potentially result in a large WAL log if transactions are allowed to
accumulate.

### `spock.exception_logging`

Use this GUC to specify which operations/transactions are written to the
exception log table:

* `all` (the default) - Set `spock.exception_logging` to `all` to instruct
  the server to record all transactions that contain one or more failed
  operations in the `spock.exception_log` table. Note that this setting will
  log all operations that are part of a transaction if one operation fails.
* `discard` - Add a row to the `spock.exception_log` table for any
  discarded operation; successful transactions are not logged.
* `none` - Instructs the server to not log any operation or transactions to
  the exception log table.

### `spock.exception_replay_queue_size` - DEPRECATED

This parameter will not be supported after version 5.X.

When Spock encounters a replication exception, it attempts to resolve the
exception by entering exception-handling mode, based on the value of
`spock.exception_behaviour`.  Spock then writes any transaction up to a
default size of `4MB` to memory, and the apply worker replays the
transaction from memory.  This provides a massive speed and performance
increase in the handling of the vast majority of exceptions.  The memory
size is configurable with `spock.exception_replay_queue_size`.

Now, Spock performs as specified by the
[`spock.exception_behaviour`](#spock-exception_behaviour) parameter.

### `spock.extra_connection_options`

You can use the `spock.extra_connection_options` parameter in the
`postgresql.conf` file to assign connection options that apply to all
connections made by Spock. This can be a useful place to set up custom
keepalive options, etc.

`spock` defaults to enabling TCP keepalives to ensure that it notices when
the upstream server disappears unexpectedly. To disable them add
`keepalives = 0` to `spock.extra_connection_options`.

### `wal_sender_timeout`

For Spock replication, set `wal_sender_timeout` to a conservative value such
as `5min` (300000ms) on each node in `postgresql.conf`:

```
wal_sender_timeout = '5min'
```

The default PostgreSQL value of `60s` can cause spurious disconnects when
the subscriber is busy applying a large transaction and cannot send feedback
in time. A higher value gives the apply worker enough headroom while still
detecting truly dead connections. Liveness detection is primarily handled by
TCP keepalives, and `spock.apply_idle_timeout` provides an additional
subscriber-side safety net.

### `spock.apply_idle_timeout`

Maximum idle time (in seconds) before the apply worker reconnects to the
provider. This acts as a safety net for detecting a hung walsender that keeps
the TCP connection alive but stops sending data. The timer resets on any
received message. Set to `0` to disable and rely solely on TCP keepalive for
liveness detection. Default: `300` (5 minutes).

```
spock.apply_idle_timeout = 300
```

### `spock.include_ddl_repset`

`spock.include_ddl_repset` enables spock to automatically add tables to
replication sets at the time they are created on each node. Tables with
primary keys will be added to the `default` replication set, and tables
without primary keys will be added to the `default_insert_only` replication
set. Altering a table to add or remove a primary key will make the correct
adjustment to which replication set the table is part of. Setting a table to
unlogged will remove it from replication. Detaching a partition will not
remove it from replication.

### `spock.log_origin_change`

`spock.log_origin_change` indicates whether changes to a row's
origin should be logged to the PostgreSQL log. Rows may be being updated
locally by regular SQL operations, or by replication from apply workers.
Note that rows that are changed locally (not from replication) have the
origin value of 0.

The default of `none` is recommended because otherwise the amount of entries
may become numerous. The other options allow for monitoring when updates
occur outside expected patterns.

The following configuration values are possible:

* `none` (the default)-  do not log any origin change information
* `remote_only_differs`- only log origin changes when the existing row
   was from one remote publisher and was changed by another
   remote publisher
* `since_sub_creation`- log origin changes whether a publisher changed
   a row that was previously from another publisher or updated it locally,
   but only since the time when the subscription was created.

### `spock.save_resolutions`

`spock.save_resolutions` is a boolean value (the default is `false`) that
logs all conflict resolutions to the `spock.resolutions` table. This option
can only be set when the postmaster starts.

### `spock.resolutions_retention_days`

`spock.resolutions_retention_days` controls how long rows are kept in the
`spock.resolutions` table. Rows with a `log_time` older than this many days
are deleted automatically by the apply worker, which runs the cleanup at most
once per day. The default is `100` days. Set to `0` to disable automatic
cleanup entirely.

This GUC has no effect when `spock.save_resolutions` is `off`.

Cleanup can also be triggered manually at any time by a superuser:

```sql
SELECT spock.cleanup_resolutions();
```

### `spock.stats_max_entries`

`spock.stats_max_entries` specifies the maximum number of entries that can
be stored into the Spock channel statistic. This option can only be set when
the postmaster starts.  The parameter accepts values from `-1` to `INT_MAX`
(the default is `-1`).

### `spock.temp_directory`

  `spock.temp_directory` defines the system path where temporary files
  needed for schema synchronization are written. This path needs to exist
  and be writable by the user running Postgres. The default is `empty`,
  which tells Spock to use the default temporary directory based on
  environment or operating system settings.


