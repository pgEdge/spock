## Configuring Spock

You can use the following configuration parameters (or GUCs) on the command line with a `SET` statement or in a PostgreSQL configuration file.

**`spock.allow_ddl_from_functions`**

`spock.allow_ddl_from_functions` will enable spock to automatically replicate DDL statements that are called within functions to also be automatically replicated. This can be turned off if these functions are expected to run on every node.  When this is set to `off`, statements replicated from functions adhere to the same rule previously described for 'include_ddl_repset.' If a table possesses a defined primary key, it will be added into the 'default' replication set; alternatively, they will be added to the 'default_insert_only' replication set.

**`spock.batch_inserts`**

`spock.batch_inserts` tells Spock to use batch insert mechanism if possible. The batch mechanism uses PostgreSQL internal batch insert mode which is also used by `COPY` command.

**`spock.channel_counters`** 

`spock.channel_counters` is a boolean value (the default is `true`) that enables or disables the Spock channel statistic information collection. This option can only be set when the postmaster starts.

**`spock.conflict_prune_interval`** 

`spock.conflict_prune_interval` specifies the time interval after which the `conflict_tracker` table will be pruned. This option can only be set at postmaster startup or by changing the configuration file and sending the HUP signal to the postmaster or a backend process. The parameter accepts values from `0` - `3600` seconds (the default is `30` seconds).

**`spock.conflict_log_level`**

`spock.conflict_log_level` sets the log level for reporting detected conflicts when `spock.conflict_resolution` is set to anything else than error. The primary use for this setting is to suppress logging of conflicts.  The possible values are same as for the [`log_min_messages`](https://www.postgresql.org/docs/16/runtime-config-logging.html#GUC-LOG-MIN-MESSAGES) PostgreSQL parameter setting.  The default is `LOG`.

**`spock.conflict_resolution`**

`spock.conflict_resolution` sets the resolution method for any detected conflicts between local data and incoming changes. Possible values are:

* `error` - the replication will stop on error if conflict is detected and manual action is needed for resolving
* `apply_remote` - always apply the change that's conflicting with local data
* `keep_local` - keep the local version of the data and ignore the conflicting change that is coming from the remote node
* `last_update_wins` - the version of data with newest commit timestamp will be kept (this can be either local or remote version)

For conflict resolution, the `track_commit_timestamp` PostgreSQL setting must be enabled.

**`spock.deny_all_ddl`**

`spock.deny_all_ddl` is a boolean value (the default is `false`) that enables or disables the execution of DDL statements within a Spock configured cluster. This option can be set at postmaster startup, with the SIGHUP mechanism, or on the command line with SQL if you're a superuser.

**`spock.enable_ddl_replication`**

`spock.enable_ddl_replication` enables replication of ddl statements through the default replication set. 

**`spock.extra_connection_options`**

You can use the `spock.extra_connection_options` parameter in the `postgresql.conf` file to assign connection options that apply to all connections made by Spock. This can be a useful place to set up custom keepalive options, etc.

`spock` defaults to enabling TCP keepalives to ensure that it notices when the upstream server disappears unexpectedly. To disable them add `keepalives = 0` to `spock.extra_connection_options`.

**`spock.include_ddl_repset`**

`spock.include_ddl_repset` enables spock to automatically add tables to replication sets at the time they are created on each node. Tables with primary keys will be added to the `default` replication set, and tables without primary keys will be added to the `default_insert_only` replication set. Altering a table to add or remove a primary key will make the correct adjustment to which replication set the table is part of. Setting a table to unlogged will remove it from replication. Detaching a partition will not remove it from replication.

**`spock.replicate_ddl`**

The `spock.replicate_ddl` function instructs Spock to checks the statement type of each transaction, and execute and replicate DDL statements.

**`spock.save_resolutions`** is a boolean value (the default is `false`) that logs all conflict resolutions to the 
`spock.resolutions table`. This option can only be set when the postmaster starts.

**`spock.stats_max_entries`** 

`spock.stats_max_entries` specifies the maximum number of entries that can be stored into the Spock channel statistic. This option can only be set when the postmaster starts.  The parameter accepts values from `-1` to `INT_MAX` (the default is `-1`).

**`spock.temp_directory`**

  `spock.temp_directory` defines the system path where temporary files needed for schema synchronization are written. 
  This path needs to exist and be writable by the user running PostgreSQL. The default is `empty`, which tells Spock to use the default temporary directory based on environment or operating system settings.


