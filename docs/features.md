
## Features

- [Automatic DDL Replication](features.md#automatic-replication-of-ddl)
- [Replicating Partitioned Tables](features.md#replicating-partitioned-tables)
- [Conflict-Free Delta-Apply Columns](features.md#conflict-free-delta-apply-columns-conflict-avoidance)
- [Using Batch Inserts](features.md#using-batch-inserts)
- [Filtering](features.md#filtering)
- [Using Spock with Snowflake Sequences](features.md#using-spock-with-snowflake-sequences)
- [Using Spock in Read-Only Mode](features.md#using-spock-in-read-only-mode)

The Spock extension is designed to support the following use cases:

* Asynchronous multi-active replication with conflict resolution
* Upgrades between major versions
* Full database replication
* Selective replication of sets of tables using replication sets
* Selective replication of table rows at either publisher or subscriber side (row_filter)
* Selective replication of partitioned tables
* Selective replication of table columns at publisher side
* Data gather/merge from multiple upstream servers

Note that:
* Spock works on a per-database level instead of a whole server level like physical streaming replication.
* One provider may feed multiple subscribers without incurring additional disk write overhead
* One subscriber can merge changes from several origins and detect conflict between changes with automatic and configurable conflict resolution (some, but not all aspects required for multi-master).
* Cascading replication is implemented in the form of changeset forwarding.


## Automatic DDL Replication

The Spock extension can automatically replicate DDL statements. To enable automatic DDL replication, set the following parameters to `on`: 

* `spock.enable_ddl_replication` enables replication of ddl statements through the default replication set. Some DDL statements are intentionally not replicated (like `CREATE DATABASE`).  Other DDL statements are replicated, but can cause lead to replication issues (like the `CREATE TABLE... AS...` statement).  In the case of `CREATE TABLE... AS...`, the DDL statement is replicated before the table is added to the replication set, leading to potential data irregularities.  Some DDL statements are replicated, but might potentially create an issue in a 3+ node cluster (ie. `DROP TABLE`).

* `spock.include_ddl_repset` enables spock to automatically add tables to replication sets at the time they are created on each node. Tables with Primary Keys will be added to the `default` replication set, and tables without Primary Keys will be added to the `default_insert_only` replication set. Altering a table to add or remove a Primary Key will also modify which replication set the table is a member of. Setting a table to `unlogged` removes the table from replication. Detaching a partition will not remove a table from replication.

* `spock.allow_ddl_from_functions` enables spock to automatically replicate DDL statements that are called within functions. You can turned this `off` if the functions are expected to run on every node. When  set to `off`, statements replicated from functions adhere to the same rule previously described for `include_ddl_repset`. If a table possesses a primary key, it will be added into the `default` replication set; alternatively, they will be added to the `default_insert_only` replication set.

It's best to set these parameters to `on` only when the database schema matches exactly on all nodes - either when all databases have no objects, or when all databases have exactly the same objects and all tables are added to replication sets.

During the auto replication process, spock generates messages that provide information about the execution. Here are the descriptions for each message:

- `DDL statement replicated.`

  This message is a INFO level message. It is displayed whenever a DDL statement is successfully replicated. To include these messages in the server log files, the configuration must have `log_min_messages=INFO` set.

- `DDL statement replicated, but could be unsafe.`

  This message serves as a warning. It is generated when certain DDL statements, though successfully replicated, are deemed potentially unsafe. For example, statements like `CREATE TABLE... AS...` will trigger this warning.

- `This DDL statement will not be replicated.`

  This warning message is generated when auto replication is active, but the specific DDL is either unsupported or intentionally excluded from replication.

- `table 'test' was added to default replication set.` 

  This is a LOG message providing information about the replication set used for a given table when `spock.include_ddl_repset` is set.


## Replicating Partitioned Tables

By default, when you add a partitioned table to a Spock replication set, Spock will include all the current partitions of a partitioned table. If you partition a table, or add partitions to a partitioned table at a later date, you will need to use the `spock.repset_add_partition` function to add them to your replication sets. The DDL for the partitioned table and partitions must reside on the subscriber nodes (like a non-partitioned table).

When you remove a partitioned table from a replication set, by default, the partitions of the table will also be removed.  You should use `spock.repset_remove_partition` to update the cluster's meta-data.

Replication of partitioned tables is a bit different from normal tables. During an initial synchronization, we query the partitioned table (or parent) to get all the rows for synchronization purposes and don't synchronize the individual partitions. After the initial sync of data, the normal operations resume and the partitions start replicating like normal tables.

If you add individual partitions to a replication set, they will be replicated like regular tables (to the table of the same name as the partition on each subscriber). This has performance advantages if your partitioning definition is the same on both provider and subscriber, as the partitioning logic does not have to be executed with each sync.

During the initial cluster setup and sync, table partitions are not synced directly. Instead, the parent table is synced with the source with data from all partitions, and the partitions are populated properly on the destination preserving the table structure. This partitioning behavior is equivalent to setting `synchronize_data = false` for individual partitions during the initial sync.

When setup completes (after the initial sync), both the parent table and partitions are monitored for modifications, and changes are replicated as they are made.

When partitions are replicated through a partitioned table, `TRUNCATE` commands alway replicate to the complete list of affected tables or partitions.

You can use a `row_filter` clause with a partitioned table, as well as with individual partitions.

## Conflict-Free Delta-Apply Columns (Conflict Avoidance)

Conflicts can arise if a node is subscribed to multiple providers, or when local writes happen on a subscriber. The Spock extension automatically detects and acts to remediate conflicts depending on settings of your configuration parameters.

Logical Multi-Master replication can get itself into trouble when running sums (such as a YTD balance).  Unlike other solutions, we do NOT have a special data type for this.   Any numeric data type will work with the spock extension (including numeric, float, double precision, int4, int8, etc).

Suppose that a running bank account sum contains a balance of `$1,000`.   Two transactions "conflict" because they overlap with each from two different multi-master nodes.   Transaction A is a `$1,000` withdrawal from the account.  Transaction B is also a `$1,000` withdrawal from the account.  The correct balance is `$-1,000`.  Our Delta-Apply algorithm fixes this problem and highly conflicting workloads with this scenario (like a tpc-c like benchmark) now run correctly at lightning speeds.

This feature is powerful *and* simple in its implementation; when an update occurs on a `log_old_value` column:

  - First, the old value for that column is captured to the WAL files.
  - Second, the new value comes in the transaction to be applied to a subscriber.
  - Before the new value overwrites the old value, a delta value is created from the above two steps and is correctly applied.

Note that on a conflicting transaction, the delta column will be correctly calculated and applied.  The conflict resolution strategy applies to non-delta columns (normally `last-update-wins`).  As a special safety-valve feature, if you ever need to re-set a `log_old_value` column you can temporarily alter the column to `log_old_value` is `false`.

### Conflict Configuration options

You can configure some aspects of Spock using configuration options in either `postgresql.conf` or via `ALTER SYSTEM SET`. Use the following parameters to control Spock's conflict behavior:

- `spock.conflict_resolution`
  Sets the resolution method for any detected conflicts between local data and incoming changes.

  Possible values:
  - `error` - the replication will stop on error if conflict is detected and manual action is needed for resolving
  - `apply_remote` - always apply the change that's conflicting with local
    data
  - `keep_local` - keep the local version of the data and ignore the
     conflicting change that is coming from the remote node
  - `last_update_wins` - the version of data with newest commit timestamp
     will be kept (this can be either local or remote version)

- For conflict resolution, the `track_commit_timestamp` PostgreSQL setting is always enabled.

- `spock.conflict_log_level`
  Sets the log level for reporting detected conflicts when `spock.conflict_resolution` is set to anything other than `error`.  The primary use for this setting is to suppress conflict logging.

  Possible values: 
  - Accepted values are the same as for the [`log_min_messages`](https://www.postgresql.org/docs/17/runtime-config-logging.html#GUC-LOG-MIN-MESSAGES) PostgreSQL parameter; the default setting is `LOG`.


## Using Batch Inserts

Using batch inserts improves replication performance for transactions that perform multiple inserts into a single table. To enable batch mode, modify the `spock.batch_inserts` parameter, setting it to `true` and `spock.conflict_resolution` parameter, setting it to `error`.  Once enabled, Spock will switch to batch mode when a transaction does more than five `INSERT`s.

**Note:** You can only use batch mode if there are no `INSTEAD OF INSERT` and `BEFORE INSERT` triggers on the table, and when there are no defaults with volatile expressions for columns of the table. 


## Filtering

### Row Filtering

Spock allows row based filtering on both the provider side and the subscriber side.

**Row Filtering on Provider**

On the provider, you can implement row filtering with the `row_filter` property of the `spock.repset_add_table` function. The `row_filter` is a normal PostgreSQL expression with the same limitations as the `CHECK` constraint.

A simple `row_filter` would look something like `row_filter := 'id > 0'`; this would ensure that only rows where values of `id` column is bigger than zero are replicated.

You can use a volatile function inside `row_filter` but use caution with regard to `writes` as any expression that will do writes could potentially throw an error and stop replication.

It's also worth noting that the `row_filter` is running inside the replication session, so session specific expressions such as `CURRENT_USER` will have the values of the replication session and not the session that did the writes.


**Row Filtering on Subscriber**

On the subscriber the row based filtering can be implemented using standard
`BEFORE TRIGGER` mechanism.

It is required to mark any such triggers as either `ENABLE REPLICA` or
`ENABLE ALWAYS` otherwise they will not be executed by the replication
process.


## Using Spock with Snowflake Sequences

We strongly recommend that you use Snowflake Sequences instead of legacy PostgreSQL sequences.

[Snowflake](https://github.com/pgEdge/snowflake-sequences) is a PostgreSQL extension that provides an `int8` and sequence based unique ID solution to optionally replace the PostgreSQL built-in `bigserial` data type. This extension allows Snowflake IDs that are unique within one sequence across multiple PostgreSQL instances in a distributed cluster.

The Spock extension includes the following functions to help you manage Snowflake sequences:

* spock.convert_sequence_to_snowflake
* spock.convert_column_to_int8

## Using Spock in Read-Only Mode

Spock supports operating a cluster in read-only mode.  Read-only status is managed using a GUC (Grand Unified Configuration) parameter named `spock.readonly`. This parameter can be set to enable or disable the read-only mode. Read-only mode restricts non-superusers to read-only operations, while superusers can still perform both read and write operations regardless of the setting.

The flag is at cluster level: either all databases are read-only or all databases
are read-write (the usual setting).

Read-only mode is implemented by filtering SQL statements:

- `SELECT` statements are allowed if they don't call functions that write.
- DML (`INSERT`, `UPDATE`, `DELETE`) and DDL statements including `TRUNCATE` are 
  forbidden entirely.
- DCL statements `GRANT` and `REVOKE` are also forbidden.

This means that the databases are in read-only mode at SQL level: however, the
checkpointer, background writer, walwriter, and the autovacuum launcher are still
running. This means that the database files are not read-only and that in some
cases the database may still write to disk.

#### Setting Read-Only Mode

You can control read-only mode with the Spock parameter `spock.readonly`; only a superuser can modify this setting. When the cluster is set to read-only mode, non-superusers will be restricted to read-only operations, while superusers will still be able to perform read and write operations regardless of the setting.

This value can be changed using the `ALTER SYSTEM` command.

```sql
ALTER SYSTEM SET spock.readonly = 'on';
SELECT pg_reload_conf();
```

To set the cluster to read-only mode for a session, use the `SET` command. Here are the steps:

```sql
SET spock.readonly TO on;
```

To query the current status of the cluster, you can use the following SQL command:
  
```sql
SHOW spock.readonly;
```

This command will return on if the cluster is in read-only mode and off if it is not.

Notes:
 - Only superusers can set and unset the `spock.readonly` parameter.
 - When the cluster is in read-only mode, only non-superusers are restricted to read-only operations. Superusers can continue to perform both read and write operations.
 - By using a GUC parameter, you can easily manage the cluster's read-only status through standard PostgreSQL configuration mechanisms.

