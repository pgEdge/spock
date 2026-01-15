# Installing and Configuring the Spock Extension

The Spock extension can be installed with pgEdge Postgres packages
or built from source. pgEdge Postgres deployments provide a simplified
upgrade path that allows you to take advantage of important new features
quickly and easily.

Spock is open-source, with code available for review at
[Github](https://github.com/pgEdge).

!!! warning

    Spock uses files stored in the `spock` schema to provide replication
    functionality.  Do not delete, create, or modify files in the `spock`
    schema directly; use Spock functions and procedures to manage replication.

For detailed information about using Spock to create a two-node cluster,
visit [here](two_node_cluster.md).


## Installing Spock with pgEdge Distributed or Enterprise Postgres

The latest Spock extension is automatically installed and created with any
[pgEdge Distributed or Enterprise Postgres](https://docs.pgedge.com/)
installation. A pgEdge deployment provides quick and easy access to:

*  the latest minor version of your preferred Postgres version.
*  Spock [functions and procedures](spock_functions/index.md).
*  [ACE consistency monitoring](https://docs.pgedge.com/platform/ace).
*  [Snowflake sequences](https://docs.pgedge.com/platform/snowflake).
*  [pgBackRest](https://docs.pgedge.com/platform/managing/pgbackrest)
   for simplified backup and restore capabilities.
*  [LOLOR](https://docs.pgedge.com/lolor/v1-2-2/) large object support.
*  management tools for your active-active distributed cluster.

### Building the Extension from Source

Spock is available as an
[open-source project](https://github.com/pgEdge/spock) that you can build
from source code distributed at the Github project page.  The Spock extension
must be built on a version-specific build of Postgres that is patched to
provide 'hooks' so `spock` can access the Postgres engine.

To patch the Postgres source code, download the source code from the
[Postgres project](https://www.postgresql.org/ftp/source/), and move into
the source directory.  Then, clone the `spock` directory:

`git clone https://github.com/pgEdge/spock.git`

Then, apply the `.diff` files from the `spock/patches/version` directory
that match your build version. To apply a patch, use the command:

  `patch -p1 < path_to_patch/patch_name`

After applying version-specific patches, you can configure, `make`, and
`make install` the Postgres server as described in the
[Postgres documentation](https://www.postgresql.org/docs/current/installation.html).
When the build completes, add the location of your `pg_config` file to your
`PATH` variable:

  `export PATH=path_to_pg_config_file`

Before invoking `make` and `make install`, install the
[jansson library](https://jansson.readthedocs.io/en/1.1/gettingstarted.html)
to meet Spock prerequisites.

Then, move into the `spock` directory, and use a build process much like any
other Postgres extension:

`make`

`make-install`

Then, update your `postgresql.conf` file, setting:

```bash
shared_preload_libraries = 'spock'
track_commit_timestamp = on # needed for conflict resolution
```

Then, connect to the database with psql, and use the `CREATE EXTENSION`
command to create the Spock extension:

  `CREATE EXTENSION spock;`


### Basic Configuration and Usage

!!! info

    pgEdge Distributed and Enterprise Postgres simplify installation and
    management of a distributed multi-master active-active replication
    cluster.  When deployed with pgEdge Postgres, replication clusters are
    automatically configured and deployed with Spock, ACE, Snowflake, and
    more.

If you're not deploying a cluster with pgEdge Postgres, you will need to
configure your server to support logical decoding:

```sql
    wal_level = 'logical'
    max_worker_processes = 10   # one per database needed on provider node
                                # one per node needed on subscriber node
    max_replication_slots = 10  # one per node needed on provider node
    max_wal_senders = 10        # one per node needed on provider node
    shared_preload_libraries = 'spock'
    track_commit_timestamp = on # needed for conflict resolution
```

Also, you will need to configure your `pg_hba.conf` file to allow logical
replication connections from localhost. Logical replication connections are
treated by `pg_hba.conf` as regular connections to the provider database.

Then, use the `spock.node_create` command to create the provider node:

```sql
    SELECT spock.node_create(
        node_name := 'provider1',
        dsn := 'host=providerhost port=5432 dbname=db'
    );
```

Then, add the tables in the `public` schema to the `default` replication
set.

```sql
    SELECT spock.repset_add_all_tables('default', ARRAY['public']);
```

Once the provider node is configured, you can add subscribers. First create
the subscriber node:

```sql
    SELECT spock.node_create(
        node_name := 'subscriber1',
        dsn := 'host=thishost port=5432 dbname=db'
    );
```

Then, create the subscription which will start synchronization and
replication on the subscriber node:

```sql
    SELECT spock.sub_create(
        subscription_name := 'subscription1',
        provider_dsn := 'host=providerhost port=5432 dbname=db'
    );

    SELECT spock.sub_wait_for_sync('subscription1');
```

### Advanced Configuration Options for Spock

You can use the following configuration parameters (GUCs) on the psql
command line with a `SET` statement or in a Postgres configuration file
(like `postgresql.conf`) to configure a Spock installation.

#### `spock.allow_ddl_from_functions`

`spock.allow_ddl_from_functions` enables spock to automatically replicate
DDL statements that are called within functions to also be automatically
replicated. This can be turned `off` if these functions are expected to run
on every node. When this is set to `off`, statements replicated from
functions adhere to the same rule previously described for
`include_ddl_repset`. If a table possesses a defined primary key, it will be
added into the `default` replication set; alternatively, they will be added
to the `default_insert_only` replication set.

#### `spock.batch_inserts`

`spock.batch_inserts` tells Spock to use batch insert mechanism if
possible. The batch mechanism uses Postgres internal batch insert mode which
is also used by `COPY` command.

#### `spock.channel_counters`

`spock.channel_counters` is a boolean value (the default is `true`) that
enables or disables the Spock channel statistic information collection. This
option can only be set when the postmaster starts.

#### `spock.check_all_uc_indexes`

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

#### `spock.conflict_resolution`

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

#### `spock.deny_all_ddl`

`spock.deny_all_ddl` is a boolean value (the default is `false`) that
enables or disables the execution of DDL statements within a Spock
configured cluster. This option can be set at postmaster startup, with the
SIGHUP mechanism, or on the command line with SQL if you're a superuser.

#### `spock.enable_ddl_replication`

`spock.enable_ddl_replication` enables
[automatic replication](managing/spock_autoddl.md) of ddl statements through
the `default` replication set.

#### <a name="spock-exception_behaviour"></a>`spock.exception_behaviour`

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

#### `spock.exception_logging`

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

#### `spock.exception_replay_queue_size` - DEPRECATED

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

#### `spock.extra_connection_options`

You can use the `spock.extra_connection_options` parameter in the
`postgresql.conf` file to assign connection options that apply to all
connections made by Spock. This can be a useful place to set up custom
keepalive options, etc.

`spock` defaults to enabling TCP keepalives to ensure that it notices when
the upstream server disappears unexpectedly. To disable them add
`keepalives = 0` to `spock.extra_connection_options`.

#### `spock.include_ddl_repset`

`spock.include_ddl_repset` enables spock to automatically add tables to
replication sets at the time they are created on each node. Tables with
primary keys will be added to the `default` replication set, and tables
without primary keys will be added to the `default_insert_only` replication
set. Altering a table to add or remove a primary key will make the correct
adjustment to which replication set the table is part of. Setting a table to
unlogged will remove it from replication. Detaching a partition will not
remove it from replication.

#### `spock.save_resolutions`

`spock.save_resolutions` is a boolean value (the default is `false`) that
logs all conflict resolutions to the `spock.resolutions table`. This option
can only be set when the postmaster starts.

#### `spock.stats_max_entries`

`spock.stats_max_entries` specifies the maximum number of entries that can
be stored into the Spock channel statistic. This option can only be set when
the postmaster starts.  The parameter accepts values from `-1` to `INT_MAX`
(the default is `-1`).

#### `spock.temp_directory`

  `spock.temp_directory` defines the system path where temporary files
  needed for schema synchronization are written. This path needs to exist
  and be writable by the user running Postgres. The default is `empty`,
  which tells Spock to use the default temporary directory based on
  environment or operating system settings.


