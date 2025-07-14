## Advanced Configuration Options for Spock

You can use the following configuration parameters (GUCs) on the psql command line with a `SET` statement or in a PostgreSQL configuration file (like `postgresql.conf`) to configure a Spock installation.

**`spock.allow_ddl_from_functions`**

`spock.allow_ddl_from_functions` enables spock to automatically replicate DDL statements that are called within functions to also be automatically replicated. This can be turned `off` if these functions are expected to run on every node. When this is set to `off`, statements replicated from functions adhere to the same rule previously described for `include_ddl_repset`. If a table possesses a defined primary key, it will be added into the `default` replication set; alternatively, they will be added to the `default_insert_only` replication set.

**`spock.batch_inserts`**

`spock.batch_inserts` tells Spock to use batch insert mechanism if possible. The batch mechanism uses PostgreSQL internal batch insert mode which is also used by `COPY` command.

**`spock.channel_counters`** 

`spock.channel_counters` is a boolean value (the default is `true`) that enables or disables the Spock channel statistic information collection. This option can only be set when the postmaster starts.

**`spock.check_all_uc_indexes`**

**Note:** This feature is experimental and `OFF` by default. Use this feature at your own risk.

This parameter enhances conflict resolution during `INSERT` operations in scenarios where a row  exists that meets unique constraints defined on the table (rather than primary keys or replication identity).

If this GUC is `enabled`, Spock will continue to check unique constraint indexes, after checking the primary key / replica identity index.  Only one conflict will be resolved, using Last-Write-Wins logic.  This includes the primary key / replica identity index. If a second conflict occurs, an exception is recorded in the `spock.exception_log` table.

Partial unique constraints are supported, but nullable unique constraints are not.
Deferable constraints are not supported, are filtered out and are not checked, and therefore may still cause an exception during the final commit.

Unique constraint indexes are checked in OID order, after the primary key.  It is therefore possible for the resolution of a unique constraint to change the primary key value.

Child tables / foreign keys are not checked or handled. Therefore, if resolving a unique constraint changes the primary key value, you can inadvertently create orphaned foreign key records.

**`spock.conflict_resolution`**

`spock.conflict_resolution` sets the resolution method for any detected conflicts between local data and incoming changes. Possible values are:

* `error` - the replication will stop on error if conflict is detected and manual action is needed for resolving
* `apply_remote` - always apply the change that's conflicting with local data
* `keep_local` - keep the local version of the data and ignore the conflicting change that is coming from the remote node
* `last_update_wins` - the version of data with newest commit timestamp will be kept (this can be either local or remote version)

To enable conflict resolution, the `track_commit_timestamp` PostgreSQL setting must be enabled.

**`spock.deny_all_ddl`**

`spock.deny_all_ddl` is a boolean value (the default is `false`) that enables or disables the execution of DDL statements within a Spock configured cluster. This option can be set at postmaster startup, with the SIGHUP mechanism, or on the command line with SQL if you're a superuser.

**`spock.enable_ddl_replication`**

`spock.enable_ddl_replication` enables [automatic replication](../spock_ext/managing/spock_autoddl.mdx) of ddl statements through the `default` replication set.

**`spock.exception_behaviour`** 

Use this GUC to specify the commit behavior of pgEdge platform when it encounters an ERROR within a transaction:

* `transdiscard` (the default) - Set `spock.exception_behaviour` to `transdiscard` to instruct the server to discard a transaction if any operation within that transaction returns an `ERROR`.
* `discard` - Set `spock.exception_behaviour` to `discard` to continue processing (and replicating) without interrupting server use. The server will commit any operation (any portion of a transaction) that does not return an `ERROR` statement.
* `sub_disable` - Set `spock.exception_behaviour` to `sub_disable` to disable the subscription for the node on which the exception was reported. Transactions for the disabled node will be added to a queue that is written to the WAL log file; when the subscription is enabled, replication will resume with the transaction that caused the exception, followed by the other queued transactions. You can use the `spock.alter_sub_skip_lsn` function to skip the transaction that caused the exception and resume processing with the next transaction in the queue.

Note that the value you choose for `spock.exception_behaviour` could potentially result in a large WAL log if transactions are allowed to accumulate.

**`spock.exception_logging`**  

Use this GUC to specify which operations/transactions are written to the exception log table: 

* `all` (the default) - Set `spock.exception_logging` to `all` to instruct the server to record all transactions that contain one or more failed operations in the `spock.exception_log` table. Note that this setting will log all operations that are part of a transaction if one operation fails.
* `discard` - Add a row to the `spock.exception_log` table for any discarded operation; successful transactions are not logged.
* `none` - Instructs the server to not log any operation or transactions to the exception log table.

**`spock.exception_replay_queue_size`**

When Spock encounters a replication exception, it attempts to resolve the exception by entering exception-handling mode, based on the value of `spock.exception_behaviour`.  Spock then writes any transaction up to a default size of `4MB` to memory, and the apply worker replays the transaction from memory.  This provides a massive speed and performance increase in the handling of the vast majority of exceptions.  The memory size is configurable with `spock.exception_replay_queue_size`. 

**`spock.extra_connection_options`**

You can use the `spock.extra_connection_options` parameter in the `postgresql.conf` file to assign connection options that apply to all connections made by Spock. This can be a useful place to set up custom keepalive options, etc.

`spock` defaults to enabling TCP keepalives to ensure that it notices when the upstream server disappears unexpectedly. To disable them add `keepalives = 0` to `spock.extra_connection_options`.

**`spock.include_ddl_repset`**

`spock.include_ddl_repset` enables spock to automatically add tables to replication sets at the time they are created on each node. Tables with primary keys will be added to the `default` replication set, and tables without primary keys will be added to the `default_insert_only` replication set. Altering a table to add or remove a primary key will make the correct adjustment to which replication set the table is part of. Setting a table to unlogged will remove it from replication. Detaching a partition will not remove it from replication.

**`spock.save_resolutions`**

`spock.save_resolutions` is a boolean value (the default is `false`) that logs all conflict resolutions to the `spock.resolutions table`. This option can only be set when the postmaster starts.

**`spock.stats_max_entries`** 

`spock.stats_max_entries` specifies the maximum number of entries that can be stored into the Spock channel statistic. This option can only be set when the postmaster starts.  The parameter accepts values from `-1` to `INT_MAX` (the default is `-1`).

**`spock.temp_directory`**

  `spock.temp_directory` defines the system path where temporary files needed for schema synchronization are written. 
  This path needs to exist and be writable by the user running PostgreSQL. The default is `empty`, which tells Spock to use the default temporary directory based on environment or operating system settings.


