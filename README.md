# Spock
![Spockbench tests](https://github.com/pgedge/spock-private/actions/workflows/spockbench.yml/badge.svg)
## Multi-Master Replication with Conflict Resolution & Avoidance


This SPOCK extension provides multi-master replication for PostgreSQL 14+.
We originally leveraged the [pgLogical](https://github.com/2ndQuadrant/pglogical) and [BDR2](https://github.com/2ndQuadrant/bdr/tree/REL0_9_94b2) 
projects as a solid foundation to build upon for this enterprise-class extension. 

**Version 4.0** is our current version under active development.  It presently includes the following important enhancements beyond v3.3:

* Full re-work of paralell slots implementation to support mixed OLTP workloads
* Improved support for delta_apply columns to support various data types
* Improved regression test coverage
* Support for [Large Object LOgical Replication](https://github.com/pgedge/lolor)
* Support for pg17beta

Our current production version is v3.3 and includes the following enhancements over v3.2:

* Automatic replication of DDL statements

Our previous production version was v3.2 and includes the following important enhancements beyond Spock v3.1:

* Support for pg14
* Support for [Snowflake Sequences](https://github.com/pgedge/snowflake)
* Support for Auto DDL
* Support for setting a database to ReadOnly
* A couple small bug fixes from pgLogical
* Native support for Failover Slots via integrating pg_failover_slots extension
* Paralell slots support for insert only workloads


Our initial production version was 3.1 and included the following:

* Support for both pg15 **AND** pg16
* Prelim testing for online upgrades between pg15 & pg16
* Regression testing improvements
* Improved support for in-region shadow nodes (in different AZ's)
* Improved and document support for replication and maintaining partitioned tables.


Our beta version was 3.0 and includes the following important enhancements beyond its bdr/pg_logical base:

* Support for pg15 (support for pg10 thru pg14 dropped)
* Support for Asynchronous Multi-Master Replication with conflict resolution
* Conflict-free delta-apply columns
* Replication of partitioned tables (to help support geo-sharding) 
* Making database clusters location aware (to help support geo-sharding)
* Better error handling for conflict resolution
* Better management & monitoring stats and integration
* A 'pii' table for making it easy for personally identifiable data to be kept in country
* Better support for minimizing system interuption during switch-over and failover


We use the following terms, borrowed from [Jan's](https://www.linkedin.com/in/jan-wieck-3140812) well known [Slony](https://slony.info) project, to describe data streams between nodes:
* Nodes - PostgreSQL database instances
* Providers and Subscribers - roles taken by Nodes
* Replication Set - a collection of tables

Use cases supported are:
* Asynchronous multi-active replication with conflict resolution
* Upgrades between major versions
* Full database replication
* Selective replication of sets of tables using replication sets
* Selective replication of table rows at either publisher or subscriber side (row_filter)
* Selective replication of partitioned tables
* Selective replication of table columns at publisher side
* Data gather/merge from multiple upstream servers

Architectural details:
* Spock works on a per-database level, not whole server level like physical streaming replication
* One Provider may feed multiple Subscribers without incurring additional disk write overhead
* One Subscriber can merge changes from several origins and detect conflict
  between changes with automatic and configurable conflict resolution (some,
  but not all aspects required for multi-master).
* Cascading replication is implemented in the form of changeset forwarding.

# Major New Features

## Snowflake Sequences
[Snowflake Sequences](https://github.com/pgEdge/snowflake-sequences) is a PostgreSQL extension providing an int8 and sequence based unique ID solution to optionally replace the PostgreSQL built-in bigserial data type. This extension allows Snowflake IDs that are unique within one sequence across multiple PostgreSQL instances in a distributed cluster.

## Automatic Replication of DDL
DDL statements can now be automatically replicated. This feature can be enabled by setting the following to on: `spock.enable_ddl_replication`, `spock.include_ddl_repset`, and `spock.allow_ddl_from_functions`. It is recommended to set these to on only when the database schema matches exactly on all nodes- either when all databases have no objects, or when all databases have exactly the same objects and all tables are added to replication sets.

By default, these settings are set to off. When these settings are on, it is recommended that DDL statements dangerous for replication be executed in a maintenance window to avoid errors that will impact replication.

`spock.enable_ddl_replication` will enable replication of ddl statements through the default replication set. Some DDL statements are intentionally not replicated (ie. CREATE DATABASE), and some are replicated but could cause issues in two ways. Some DDL statements could lead to inconsistent data (ie. CREATE TABLE... AS...) since the DDL statement is replicated before the table is added to the replication set. Some DDL statements are replicated, but are potentially an issue in a 3+ node cluster (ie. DROP TABLE).

`spock.include_ddl_repset` will enable spock to automatically add tables to replication sets at the time they are created on each node. Tables with Primary Keys will be added to the default replication set, and tables without Primary Keys will be added to the default_insert_only replication set. Altering a table to add or remove a Primary Key will make the correct adjustment to which replication set the table is part of. Setting a table to unlogged will remove it from replication. Detaching a partition will not remove it from replication.

`spock.allow_ddl_from_functions` will enable spock to automatically replicate DDL statements that are called within functions to also be automatically replicated. This can be turned off if these functions are expected to run on every node.When this is set to off statements replicated from functions adhere to the same rule previously described for 'include_ddl_repset.' If a table possesses a defined primary key, it will be added into the 'default' replication set; alternatively, they will be added to the 'default_insert_only' replication set.

During the auto replication process, various messages are generated to provide information about the execution. Here are the descriptions for each message:
- "DDL statement replicated."
This message is a INFO level message. It is displayed whenever a DDL statement is successfully replicated. To include these messages in the server log files, the configuration must have "log_min_messages=INFO" set.
- "DDL statement replicated, but could be unsafe."
This message serves as a warning. It is generated when certain DDL statements, though successfully replicated, are deemed potentially unsafe. For example, statements like "CREATE TABLE... AS..." will trigger this warning.
- "This DDL statement will not be replicated."
This warning message is generated when auto replication is active, but the specific DDL is either unsupported or intentionally excluded from replication.4- "table 'test' was added to 'default' replication set." This is a LOG message providing information about the replication set used for a given table when 'spock.include_ddl_repset' is set.


## Replication of Partitioned Tables

Partitioned tables can now be replicated. By default, when adding a partitioned table to a replication set, it will include all of its present partitions. The later partitions can be added using the `partition_add` function. The DDL for the partitioned and partitions should be present on the subscriber nodes (same as for normal tables).

Similarly, when removing a partitioned table from a replication set, by default, the partitions of the table will also be removed.

The replication of partitioned tables is a bit different from normal tables. When doing initial synchronization, we query the partitioned table (or parent) to get all the rows for synchronization purposes and don't synchronize the individual partitions. However, after the initial sync of data, the normal operations resume i.e. the partitions start replicating like normal tables.

It's possible to add individual partitions to the replication set in which case they will be replicated like regular tables (to the table of the same name as the partition on the subscriber). This has performance advantages when partitioning definition is the same on both provider and subscriber, as the partitioning logic does not have to be executed.

**Note:** There is an exception to individual partition replication, which is, the individual partitions won't sync up the existing data. It's equivalent to setting `synchronize_data = false`.

When partitions are replicated through a partitioned table, the exception is the TRUNCATE command which always replicates with the list of affected tables or partitions.

Additionally, `row_filter` can also be used with partitioned tables, as well as with individual partitions.


## Conflict-Free Delta-Apply Columns (Conflict Avoidance)

Logical Multi-Master replication can get itself into trouble on running sums (such as a YTD balance).  Unlike other
solutions, we do NOT have a special data type for this.   Any numeric data type will do (including numeric, float, double precision, int4, int8, etc).

Suppose that a running bank account sum contains a balance of `$1,000`.   Two transactions "conflict" because they overlap with each from two different multi-master nodes.   Transaction A is a `$1,000` withdrawal from the account.  Transaction B is also a `$1,000` withdrawal from the account.  The correct balance is `$-1,000`.  Our Delta-Apply algorithm fixes this problem and highly conflicting workloads with this scenario (like a tpc-c like benchmark) now run correctly at lightning speeds.

This feature is powerful AND simple in its implementation as follows:

  - A small diff patch to PostgreSQL core
    - a very small PostgreSQL licensed patch is applied to a core PostgreSQL source tree before building a PG binary.
    - the above diff patch adds functionality to support ALTER TABLE t1 ALTER COLUMN c1 SET(log_old_value=true)
    - this patch will be submitted to pg16 core PostgreSQL and discussed at the Ottawa Conference.

  - When an update occurs on a 'log_old_value' column
    - First, the old value for that column is captured to the WAL 
    - Second, the new value comes in the transaction to be applied to a subscriber
    - Before the new value overwrites the old value, a delta value is created from the above two steps and it is correctly applied

Note that on a conflicting transaction, the delta column will get correctly calculated and applied.  The configured conflict resolution strategy applies to non-delta columns (normally last-update-wins).

As a special safety-valve feature.  If the user ever needs to re-set a log_old_value column you can temporarily alter the column to "log_old_value" is false.

## Conflicts Overview

In case the node is subscribed to multiple providers, or when local writes
happen on a subscriber, conflicts can arise for the incoming changes. These
are automatically detected and can be acted on depending on the configuration.

The configuration of the conflicts resolver is done via the
`spock.conflict_resolution` setting.

The resolved conflicts are logged using the log level set using
`spock.conflict_log_level`. This parameter defaults to `LOG`. If set to
lower level than `log_min_messages` the resolved conflicts won't appear in
the server log.

## Conflict Configuration options

Some aspects of Spock can be configured using configuration options that
can be either set in `postgresql.conf` or via `ALTER SYSTEM SET`.

- `spock.conflict_resolution`
  Sets the resolution method for any detected conflicts between local data
  and incoming changes.

  Possible values:
  - `error` - the replication will stop on error if conflict is detected and
    manual action is needed for resolving
  - `apply_remote` - always apply the change that's conflicting with local
    data
  - `keep_local` - keep the local version of the data and ignore the
     conflicting change that is coming from the remote node
  - `last_update_wins` - the version of data with newest commit timestamp
     will be kept (this can be either local or remote version)

  For conflict resolution, the `track_commit_timestamp` PostgreSQL setting 
  is always enabled.

- `spock.conflict_log_level`
  Sets the log level for reporting detected conflicts when the
  `spock.conflict_resolution` is set to anything else than `error`.

  Main use for this setting is to suppress logging of conflicts.

  Possible values are same as for `log_min_messages` PostgreSQL setting.

  The default is `LOG`.

- `spock.batch_inserts`
  Tells Spock to use batch insert mechanism if possible. Batch mechanism
  uses PostgreSQL internal batch insert mode which is also used by `COPY`
  command.


## Requirements

The `spock` extension must be installed on both provider and subscriber.
You must `CREATE EXTENSION spock` on both.  For major version upgrades, the old node 
can be running a recent version of pgLogical2 before it is upgraded to become a Spock node.

Tables on the provider and subscriber must have the same names and be in the
same schema. Future revisions may add mapping features.

Tables on the provider and subscriber must have the same columns, with the same
data types in each column. `CHECK` constraints, `NOT NULL` constraints, etc., must
be the same or weaker (more permissive) on the subscriber than the provider.

Tables must have the same `PRIMARY KEY`s. It is not recommended to add additional
`UNIQUE` constraints other than the `PRIMARY KEY` (see below).

Some additional requirements are covered in [Limitations and Restrictions](#limitations-and-restrictions).

## Usage

This section describes basic usage of the Spock replication extension.  
It should be noted the pgEdge, when you install the Spock extension, does this quick setup for you (and more).

### Quick setup


First the PostgreSQL server has to be properly configured to support logical
decoding:

    wal_level = 'logical'
    max_worker_processes = 10   # one per database needed on provider node
                                # one per node needed on subscriber node
    max_replication_slots = 10  # one per node needed on provider node
    max_wal_senders = 10        # one per node needed on provider node
    shared_preload_libraries = 'spock'
    track_commit_timestamp = on # needed for conflict resolution

`pg_hba.conf` has to allow logical replication connections from
localhost. Logical replication connections are treated
by `pg_hba.conf` as regular connections to the provider database.

Next the `spock` extension has to be installed on all nodes in the database to be replicated:

    CREATE EXTENSION spock;

Now create the provider node:

    SELECT spock.node_create(
        node_name := 'provider1',
        dsn := 'host=providerhost port=5432 dbname=db'
    );

Add all tables in `public` schema to the `default` replication set.

    SELECT spock.repset_add_all_tables('default', ARRAY['public']);

Optionally you can also create additional replication sets and add tables to
them (see [Replication sets](#replication-sets)).

It's usually better to create replication sets before subscribing so that all
tables are synchronized during initial replication setup in a single initial
transaction. However, users of bigger databases may instead wish to create them
incrementally for better control.

Once the provider node is setup, subscribers can be subscribed to it. First the
subscriber node must be created:

    SELECT spock.node_create(
        node_name := 'subscriber1',
        dsn := 'host=thishost port=5432 dbname=db'
    );

And finally on the subscriber node you can create the subscription which will
start synchronization and replication process in the background:

    SELECT spock.sub_create(
        subscription_name := 'subscription1',
        provider_dsn := 'host=providerhost port=5432 dbname=db'
    );

    SELECT spock.sub_wait_for_sync('subscription1');

### Creating subscriber nodes with base backups

In addition to the SQL-level node and subscription creation, spock also
supports creating a subscriber by cloning the provider with `pg_basebackup` and
starting it up as a spock subscriber. This is done with the
`spock_create_subscriber` tool; see the `--help` output.

Unlike `spock.sub_create`'s data sync options, this clone ignores
replication sets and copies all tables on all databases. However, it's often
much faster, especially over high-bandwidth links.

### Node management

Nodes can be added and removed dynamically using the SQL interfaces.

#### spock-node-create
- `spock.node_create(node_name name, dsn text)`
  Creates a node.

  Parameters:
  - `node_name` - name of the new node, only one node is allowed per database
  - `dsn` - connection string to the node, for nodes that are supposed to be
    providers, this should be reachable from outside


#### spock-node-drop
- `spock.node_drop(node_name name, ifexists bool)`
  Drops the spock node.

  Parameters:
  - `node_name` - name of an existing node
  - `ifexists` - if true, error is not thrown when subscription does not exist,
    default is false

#### spock-node-add-interface
- `spock.node_add_interface(node_name name, interface_name name, dsn text)`
  Adds additional interface to a node.

  When node is created, the interface for it is also created with the `dsn`
  specified in the `create_node` and with the same name as the node. This
  interface allows adding alternative interfaces with different connection
  strings to an existing node.

  Parameters:
  - `node_name` - name of an existing node
  - `interface_name` - name of a new interface to be added
  - `dsn` - connection string to the node used for the new interface

#### spock-node-drop-interface
- `spock.node_drop_interface(node_name name, interface_name name)`
  Remove existing interface from a node.

  Parameters:
  - `node_name` - name of and existing node
  - `interface_name` - name of an existing interface

### Subscription management

#### spock-sub-create
- `spock.sub_create(subscription_name name, provider_dsn text,
  repsets text[], sync_structure boolean,
  sync_data boolean, forward_origins text[], apply_delay interval)`
  Creates a subscription from current node to the provider node. Command does
  not block, just initiates the action.

  Parameters:
  - `subscription_name` - name of the subscription, must be unique
  - `provider_dsn` - connection string to a provider
  - `repsets` - array of replication sets to subscribe to, these must
    already exist, default is "{default,default_insert_only,ddl_sql}"
  - `sync_structure` - specifies if to synchronize structure from
    provider to the subscriber, default false
  - `sync_data` - specifies if to synchronize data from provider to
    the subscriber, default true
  - `forward_origins` - array of origin names to forward, currently only
    supported values are empty array meaning don't forward any changes
    that didn't originate on provider node (this is useful for two-way
    replication between the nodes), or "{all}" which means replicate all
    changes no matter what is their origin, default is "{all}"
  - `apply_delay` - how much to delay replication, default is 0 seconds
  - `force_text_transfer` - force the provider to replicate all columns
    using a text representation (which is slower, but may be used to
    change the type of a replicated column on the subscriber), default
    is false

  The `subscription_name` is used as `application_name` by the replication
  connection. This means that it's visible in the `pg_stat_replication`
  monitoring view. It can also be used in `synchronous_standby_names` when
  spock is used as part of
  [synchronous replication](#synchronous-replication) setup.

  Use `spock.sub_wait_for_sync(subscription_name)` to wait for the
  subscription to asynchronously start replicating and complete any needed
  schema and/or data sync.

#### spock-sub-drop
- `spock.sub_drop(subscription_name name, ifexists bool)`
  Disconnects the subscription and removes it from the catalog.

  Parameters:
  - `subscription_name` - name of the existing subscription
  - `ifexists` - if true, error is not thrown when subscription does not exist,
    default is false

#### spock-sub-disable
- `spock.sub_disable(subscription_name name, immediate bool)`
   Disables a subscription and disconnects it from the provider.

  Parameters:
  - `subscription_name` - name of the existing subscription
  - `immediate` - if true, the subscription is stopped immediately, otherwise
    it will be only stopped at the end of current transaction, default is false

#### spock-sub-enable
- `spock.sub_enable(subscription_name name, immediate bool)`
  Enables disabled subscription.

  Parameters:
  - `subscription_name` - name of the existing subscription
  - `immediate` - if true, the subscription is started immediately, otherwise
    it will be only started at the end of current transaction, default is false

#### spock-sub-alter-interface
- `spock.sub_alter_interface(subscription_name name, interface_name name)`
  Switch the subscription to use different interface to connect to provider
  node.

  Parameters:
  - `subscription_name` - name of an existing subscription
  - `interface_name` - name of an existing interface of the current provider
    node

#### spock-sub-sync
- `spock.sub_sync(subscription_name name, truncate bool)`
  All unsynchronized tables in all sets are synchronized in a single operation.
  Tables are copied and synchronized one by one. Command does not block, just
  initiates the action. Use `spock.wait_for_sub_sync`
  to wait for completion.

  Parameters:
  - `subscription_name` - name of the existing subscription
  - `truncate` - if true, tables will be truncated before copy, default false

#### spock-sub-resync-table
- `spock.sub_resync_table(subscription_name name, relation regclass)`
  Resynchronize one existing table. The table may not be the target of any
  foreign key constraints.
  **WARNING: This function will truncate the table immediately, and only then
  begin synchronising it, so it will be empty while being synced**

  Does not block, use `spock.wait_for_table_sync` to wait for
  completion.

  Parameters:
  - `subscription_name` - name of the existing subscription
  - `relation` - name of existing table, optionally qualified

#### spock-sub-wait-for-sync
- `spock.sub_wait_for_sync(subscription_name name)`

   Wait for a subscription to finish synchronization after a
   `spock.sub_create` or `spock.sub_sync`.

  This function waits until the subscription's initial schema/data sync,
  if any, are done, and until any tables pending individual resynchronisation
  have also finished synchronising.

  For best results, run `SELECT spock.wait_slot_confirm_lsn(NULL, NULL)` on the
  provider after any replication set changes that requested resyncs, and only
  then call `spock.sub_wait_for_sync` on the subscriber.

#### spock-sub-wait-table-sync
- `spock.sub_wait_table_sync(subscription_name name, relation regclass)`

  Same as `spock.sub_wait_for_sync`, but waits only for
  the subscription's initial sync and the named table. Other tables pending
  resynchronisation are ignored.

- `spock.wait_slot_confirm_lsn`

  `SELECT spock.wait_slot_confirm_lsn(NULL, NULL)`

  Wait until all replication slots on the current node have replayed up to the
  xlog insert position at time of call on all providers. Returns when
  all slots' `confirmed_flush_lsn` passes the `pg_current_wal_insert_lsn()` at
  time of call.

  Optionally may wait for only one replication slot (first argument).
  Optionally may wait for an arbitrary LSN passed instead of the insert lsn
  (second argument). Both are usually just left null.

  This function is very useful to ensure all subscribers have received changes
  up to a certain point on the provider.

#### spock-sub-show-status
- `spock.sub_show_status(subscription_name name)`
  Shows status and basic information about subscription.

  Parameters:
  - `subscription_name` - optional name of the existing subscription, when no
    name was provided, the function will show status for all subscriptions on
    local node

#### spock-sub-show-table
- `spock.sub_show_table(subscription_name name, relation regclass)`
  Shows synchronization status of a table.

  Parameters:
  - `subscription_name` - name of the existing subscription
  - `relation` - name of existing table, optionally qualified

#### spock-sub-add-repset
- `spock.sub_add_repset(subscription_name name, replication_set name)`
  Adds one replication set into a subscriber. Does not synchronize, only
  activates consumption of events.

  Parameters:
  - `subscription_name` - name of the existing subscription
  - `replication_set` - name of replication set to add

#### spock-sub-remove-repset
- `spock.sub_remove_repset(subscription_name name, replication_set name)`
  Removes one replication set from a subscriber.

  Parameters:
  - `subscription_name` - name of the existing subscription
  - `replication_set` - name of replication set to remove


There is also a `postgresql.conf` parameter,
`spock.extra_connection_options`, that may be set to assign connection
options that apply to all connections made by spock. This can be a useful
place to set up custom keepalive options, etc.

spock defaults to enabling TCP keepalives to ensure that it notices
when the upstream server disappears unexpectedly. To disable them add
`keepalives = 0` to `spock.extra_connection_options`.

### Replication sets

Replication sets provide a mechanism to control which tables in the database
will be replicated and which actions on those tables will be replicated.

Each replicated set can specify individually if `INSERTs`, `UPDATEs`,
`DELETEs` and `TRUNCATEs` on the set are replicated. Every table can be in
multiple replication sets and every subscriber can subscribe to multiple
replication sets as well. The resulting set of tables and actions replicated
is the union of the sets the table is in. The tables are not replicated until
they are added into a replication set.

There are three preexisting replication sets named "default",
"default_insert_only" and "ddl_sql". The "default" replication set is defined
to replicate all changes to tables in it. The "default_insert_only" only
replicates INSERTs and is meant for tables that don't have primary key (see
[Limitations](#primary-key-required) section for details).
The "ddl_sql" replication set is defined to replicate schema changes specified by
`spock.replicate_ddl`

The following functions are provided for managing the replication sets:

#### spock-repset-create
- `spock.repset_create(set_name name, replicate_insert bool, replicate_update bool, replicate_delete bool, replicate_truncate bool)`
  This function creates a new replication set.

  Parameters:
  - `set_name` - name of the set, must be unique
  - `replicate_insert` - specifies if `INSERT` is replicated, default true
  - `replicate_update` - specifies if `UPDATE` is replicated, default true
  - `replicate_delete` - specifies if `DELETE` is replicated, default true
  - `replicate_truncate` - specifies if `TRUNCATE` is replicated, default true

#### spock-repset-alter
- `spock.repset_alter(set_name name, replicate_inserts bool, replicate_updates bool, replicate_deletes bool, replicate_truncate bool)`
  This function changes the parameters of the existing replication set.

  Parameters:
  - `set_name` - name of the existing replication set
  - `replicate_insert` - specifies if `INSERT` is replicated, default true
  - `replicate_update` - specifies if `UPDATE` is replicated, default true
  - `replicate_delete` - specifies if `DELETE` is replicated, default true
  - `replicate_truncate` - specifies if `TRUNCATE` is replicated, default true

#### spock-repset-drop
- `spock.repset_drop(set_name text)`
  Removes the replication set.

  Parameters:
  - `set_name` - name of the existing replication set

#### spock-repset-add-table
- `spock.repset_add_table(set_name name, relation regclass, sync_data boolean, columns text[], row_filter text)`
  Adds a table to replication set.

  Parameters:
  - `set_name` - name of the existing replication set
  - `relation` - name or OID of the table to be added to the set
  - `sync_data` - if true, the table data is synchronized on all
    subscribers which are subscribed to given replication set, default false
  - `columns` - list of columns to replicate. Normally when all columns
    should be replicated, this will be set to NULL which is the
    default
  - `row_filter` - row filtering expression, default NULL (no filtering),
    see [Row Filtering](#row-filtering) for more info.
  **WARNING: Use caution when synchronizing data with a valid row filter.**
Using `sync_data=true` with a valid `row_filter` is like a one-time operation for a table.
Executing it again with modified `row_filter` won't synchronize data to subscriber. Subscribers
may need to call `spock.alter_sub_resync_table()` to fix it.

#### spock-repset-add-all-tables
- `spock.repset_add_all_tables(set_name name, schema_names text[], sync_data boolean)`
  Adds all tables in given schemas. Only existing tables are added, table that
  will be created in future will not be added automatically. For how to ensure
  that tables created in future are added to correct replication set, see
  [Automatic assignment of replication sets for new tables](#automatic-assignment-of-replication-sets-for-new-tables).

  Parameters:
  - `set_name` - name of the existing replication set
  - `schema_names` - array of names name of existing schemas from which tables
    should be added
  - `sync_data` - if true, the table data is synchronized on all
    subscribers which are subscribed to given replication set, default false

#### spock-repset-remove-table
- `spock.repset_remove_table(set_name name, relation regclass)`
  Remove a table from replication set.

  Parameters:
  - `set_name` - name of the existing replication set
  - `relation` - name or OID of the table to be removed from the set

#### spock-repset-add-seq
*Warning:* For a multi master system, adding sequences to replication sets is not recomended. Use our new [Snowflake Sequences](https://github.com/pgEdge/snowflake-sequences) instead.
- `spock.repset_add_seq(set_name name, relation regclass, sync_data boolean)`
  Adds a sequence to a replication set.

  Parameters:
  - `set_name` - name of the existing replication set
  - `relation` - name or OID of the sequence to be added to the set
  - `sync_data` - if true, the sequence value will be synchronized immediately, default false

#### spock-repset-add-all-seqs
*Warning:* For a multi master system, adding sequences to replication sets is not recomended. Use our new [Snowflake Sequences](https://github.com/pgEdge/snowflake-sequences) instead.
- `spock.repset_add_all_seqs(set_name name, schema_names text[], sync_data boolean)`
  Adds all sequences from the given schemas. Only existing sequences are added, any sequences that
  will be created in future will not be added automatically.

  Parameters:
  - `set_name` - name of the existing replication set
  - `schema_names` - array of names name of existing schemas from which tables
    should be added
  - `sync_data` - if true, the sequence value will be synchronized immediately, default false

#### spock-repset-remove-seq
- `spock.repset_remove_seq(set_name name, relation regclass)`
  Remove a sequence from a replication set.

  Parameters:
  - `set_name` - name of the existing replication set
  - `relation` - name or OID of the sequence to be removed from the set

You can view the information about which table is in which set by querying the
`spock.tables` view.

#### Automatic assignment of replication sets for new tables

The event trigger facility can be used for describing rules which define
replication sets for newly created tables.

Example:

    CREATE OR REPLACE FUNCTION spock_assign_repset()
    RETURNS event_trigger AS $$
    DECLARE obj record;
    BEGIN
        FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands()
        LOOP
            IF obj.object_type = 'table' THEN
                IF obj.schema_name = 'config' THEN
                    PERFORM spock.repset_add_table('configuration', obj.objid);
                ELSIF NOT obj.in_extension THEN
                    PERFORM spock.repset_add_table('default', obj.objid);
                END IF;
            END IF;
        END LOOP;
    END;
    $$ LANGUAGE plpgsql;

    CREATE EVENT TRIGGER spock_assign_repset_trg
        ON ddl_command_end
        WHEN TAG IN ('CREATE TABLE', 'CREATE TABLE AS')
        EXECUTE PROCEDURE spock_assign_repset();

The above example will put all new tables created in schema `config` into
replication set `configuration` and all other new tables which are not created
by extensions will go to `default` replication set.

### Additional functions

#### spock-replicate-ddl
- `spock.replicate_ddl(command text, repsets text[])`
  Execute locally and then send the specified command to the replication queue
  for execution on subscribers which are subscribed to one of the specified
  `repsets`.

  Parameters:
  - `command` - DDL query to execute
  - `repsets` - array of replication sets which this command should be
    associated with, default "{ddl_sql}"

#### spock-seq-sync
- `spock.seq_sync(relation regclass)`
  Push sequence state to all subscribers. Unlike the subscription and table
  synchronization function, this function should be run on provider. It forces
  update of the tracked sequence state which will be consumed by all
  subscribers (replication set filtering still applies) once they replicate the
  transaction in which this function has been executed.

  Parameters:
  - `relation` - name of existing sequence, optionally qualified

### Row Filtering

Spock allows row based filtering both on provider side and the subscriber
side.

#### Row Filtering on Provider

On the provider the row filtering can be done by specifying `row_filter`
parameter for the `spock.repset_add_table` function. The
`row_filter` is normal PostgreSQL expression which has the same limitations
on what's allowed as the `CHECK` constraint.

Simple `row_filter` would look something like `row_filter := 'id > 0'` which
would ensure that only rows where values of `id` column is bigger than zero
will be replicated.

It's allowed to use volatile function inside `row_filter` but caution must
be exercised with regard to writes as any expression which will do writes
will throw error and stop replication.

It's also worth noting that the `row_filter` is running inside the replication
session so session specific expressions such as `CURRENT_USER` will have
values of the replication session and not the session which did the writes.

#### Row Filtering on Subscriber

On the subscriber the row based filtering can be implemented using standard
`BEFORE TRIGGER` mechanism.

It is required to mark any such triggers as either `ENABLE REPLICA` or
`ENABLE ALWAYS` otherwise they will not be executed by the replication
process.

## Synchronous Replication

Synchronous replication is supported using same standard mechanism provided
by PostgreSQL for physical replication.

The `synchronous_commit` and `synchronous_standby_names` settings will affect
when `COMMIT` command reports success to client if spock subscription
name is used in `synchronous_standby_names`. Refer to PostgreSQL
documentation for more info about how to configure these two variables.

  The batch inserts will improve replication performance of transactions that
  did many inserts into one table. Spock will switch to batch mode when
  transaction did more than 5 INSERTs.

  It's only possible to switch to batch mode when there are no
  `INSTEAD OF INSERT` and `BEFORE INSERT` triggers on the table and when
  there are no defaults with volatile expressions for columns of the table.
  Also the batch mode will only work when `spock.conflict_resolution` is
  set to `error`.

  The default is `true`.

- `spock.use_spi`
  Tells Spock to use SPI interface to form actual SQL
  (`INSERT`, `UPDATE`, `DELETE`) statements to apply incoming changes instead
  of using internal low level interface.

  This is mainly useful for debugging purposes.

  The default in PostgreSQL is `false`.

  This can be set to `true` only when `spock.conflict_resolution` is set to `error`.
In this state, conflicts are not detected.

- `spock.temp_directory`
  Defines system path where to put temporary files needed for schema
  synchronization. This path need to exist and be writable by user running
  Postgres.

  Default is empty, which tells Spock to use default temporary directory
  based on environment and operating system settings.

## Limitations and restrictions

### Superuser is required

Currently spock replication and administration requires superuser
privileges. It may be later extended to more granular privileges.

### `UNLOGGED` and `TEMPORARY` not replicated

`UNLOGGED` and `TEMPORARY` tables will not and cannot be replicated, much like
with physical streaming replication.

### One database at a time

To replicate multiple databases you must set up individual provider/subscriber
relationships for each. There is no way to configure replication for all databases
in a PostgreSQL install at once.

### PRIMARY KEY or REPLICA IDENTITY required

`UPDATE`s and `DELETE`s cannot be replicated for tables that lack a `PRIMARY
KEY` or other valid replica identity such as using an index, which must be unique,
not partial, not deferrable, and include only columns marked NOT NULL.
Replication has no way to find the tuple that should be updated/deleted since
there is no unique identifier.
`REPLICA IDENTITY FULL` is not supported yet.


### Only one unique index/constraint/PK

If more than one upstream is configured or the downstream accepts local writes
then only one `UNIQUE` index should be present on downstream replicated tables.
Conflict resolution can only use one index at a time so conflicting rows may
`ERROR` if a row satisfies the `PRIMARY KEY` but violates a `UNIQUE` constraint
on the downstream side. This will stop replication until the downstream table
is modified to remove the violation.

It's fine to have extra unique constraints on an upstream if the downstream only
gets writes from that upstream and nowhere else. The rule is that the downstream
constraints must *not be more restrictive* than those on the upstream(s).

Partial secondary unique indexes are permitted, but will be ignored for
conflict resolution purposes.

### Unique constraints must not be deferrable

On the downstream end spock does not support index-based constraints
defined as `DEFERRABLE`. It will emit the error

    ERROR: spock doesn't support index rechecks needed for deferrable indexes
    DETAIL: relation "public"."test_relation" has deferrable indexes: "index1", "index2"

if such an index is present when it attempts to apply changes to a table.

### DDL

Automatic DDL replication is not supported. Managing DDL so that the provider and
subscriber database(s) remain compatible is the responsibility of the user.

spock provides the `spock.replicate_ddl` function to allow DDL
to be run on the provider and subscriber at a consistent point.

### No replication queue flush

There's no support for freezing transactions on the master and waiting until
all pending queued xacts are replayed from slots. Support for making the
upstream read-only for this will be added in a future release.

This means that care must be taken when applying table structure changes. If
there are committed transactions that aren't yet replicated and the table
structure of the provider and subscriber are changed at the same time in a way
that makes the subscriber table incompatible with the queued transactions
replication will stop.

Administrators should either ensure that writes to the master are stopped
before making schema changes, or use the `spock.replicate_ddl`
function to queue schema changes so they're replayed at a consistent point
on the replica.

Once multi-master replication support is added then using
`spock.replicate_ddl` will not be enough, as the subscriber may be
generating new xacts with the old structure after the schema change is
committed on the publisher. Users will have to ensure writes are stopped on all
nodes and all slots are caught up before making schema changes.

### FOREIGN KEYS

Foreign keys constraints are not enforced for the replication process - what
succeeds on provider side gets applied to subscriber even if the `FOREIGN KEY`
would be violated.

### TRUNCATE

Using `TRUNCATE ... CASCADE` will only apply the `CASCADE` option on the
provider side.

(Properly handling this would probably require the addition of `ON TRUNCATE CASCADE`
support for foreign keys in PostgreSQL).

`TRUNCATE ... RESTART IDENTITY` is not supported. The identity restart step is
not replicated to the replica.

### Sequences

We strongly recommend that you use our new [Snowflake Sequences](https://github.com/pgEdge/snowflake-sequences) rather
than using the legacy sequences described below.

The state of sequences added to replication sets is replicated periodically
and not in real-time. Dynamic buffer is used for the value being replicated so
that the subscribers actually receive future state of the sequence. This
minimizes the chance of subscriber's notion of sequence's `last_value` falling
behind but does not completely eliminate the possibility.

It might be desirable to call `sync_sequence` to ensure all subscribers
have up to date information about given sequence after "big events" in the
database such as data loading or during the online upgrade.

It's generally recommended to use `bigserial` and `bigint` types for sequences
on multi-node systems as smaller sequences might reach end of the sequence
space fast.

Users who want to have independent sequences on provider and subscriber can
avoid adding sequences to replication sets and create sequences with step
interval equal to or greater than the number of nodes. And then setting a
different offset on each node. Use the `INCREMENT BY` option for
`CREATE SEQUENCE` or `ALTER SEQUENCE`, and use `setval(...)` to set the start
point.

### Triggers

Apply process and the initial COPY process both run with
`session_replication_role` set to `replica` which means that `ENABLE REPLICA`
and `ENABLE ALWAYS` triggers will be fired.

### PostgreSQL Version differences

Spock can replicate across PostgreSQL major versions. Despite that, long
term cross-version replication is not considered a design target, though it may
often work. Issues where changes are valid on the provider but not on the
subscriber are more likely to arise when replicating across versions.

It is safer to replicate from an old version to a newer version since PostgreSQL
maintains solid backward compatibility but only limited forward compatibility.
Initial schema synchronization is only supported when replicating between same
version of PostgreSQL or from lower version to higher version.

Replicating between different minor versions makes no difference at all.

### Database encoding differences

Spock does not support replication between databases with different
encoding. We recommend using `UTF-8` encoding in all replicated databases.

### Large objects

PostgreSQL's logical decoding facility does not support decoding changes
to [large objects](https://www.postgresql.org/docs/current/largeobjects.html), 
so spock cannot replicate large objects.

Also any DDL limitations apply so extra care need to be taken when using
`replicate_ddl_command()`.


## Spock Read Only

Spock support enabling a cluster to be operated in read-only mode.

The read-only status is managed only in (shared) memory with a global flag. SQL
functions are provided to set the flag, to unset the flag and to query the flag.
The current functionality does not allow to store the read-only status in a
permanent way.

The flag is at cluster level: either all databases are read-only or all database
are read-write (the usual setting).

The read-only mode is implemented by filtering SQL statements:

- SELECT statements are allowed if they don't call functions that write.
- DML (INSERT, UPDATE, DELETE) and DDL statements including TRUNCATE are forbidden entirely.
- DCL statements GRANT and REVOKE are also forbidden.

This means that the databases are in read-only mode at SQL level: however, the
checkpointer, background writer, walwriter and the autovacuum launcher are still
running; this means that the database files are not read-only and that in some
cases the database may still write to disk.

### Functions

Spock read only supports following functions:
- set_cluster_readonly
  This function is for setting the cluster in read-only mode.

- unset_cluster_readonly
  This function is for setting cluster in read-write mode.

- get_cluster_readonly
  This function can be used to query the cluster status. It returns true if the
  cluster is read-only and false if not.

- terminate_active_transactions
  This function is to terminate any active transactions.

Spock is licensed under the [pgEdge Community License v1.0](PGEDGE-COMMUNITY-LICENSE.md)
