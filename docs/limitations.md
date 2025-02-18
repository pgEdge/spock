## Spock Limitations and Restrictions

### Superuser privileges are required

Currently spock replication and administration requires superuser privileges.

### `UNLOGGED` and `TEMPORARY` tables are not replicated

`UNLOGGED` and `TEMPORARY` tables will not and cannot be replicated, much like
with physical streaming replication.

### One database at a time

To replicate multiple databases you must set up individual provider/subscriber
relationships for each. There is no way to configure replication for all databases
in a PostgreSQL installation at once.

### PRIMARY KEY or REPLICA IDENTITY required

Spock cannot replicate `UPDATE`s and `DELETE`s for tables that lack a `PRIMARY
KEY` or other valid replica identity such as using an index, which must be unique,
not partial, not deferrable, and include only columns marked NOT NULL.
Without a primary key or replica identity, replication has no way to find the tuple that should be updated/deleted.

### `REPLICA IDENTITY FULL` is not yet supported

### Only one unique index/constraint/PK is allowed

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
defined as `DEFERRABLE`. It will emit the error:

`ERROR: spock doesn't support index rechecks needed for deferrable indexes`
`DETAIL: relation "public"."test_relation" has deferrable indexes: "index1", "index2"`

if such an index is present when it attempts to apply changes to a table.

### No replication queue flush

There is no support for freezing transactions on the master and waiting until
all pending queued xacts are replayed from slots.

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

We strongly recommend that you use pgEdge [Snowflake Sequences](../platform/advanced/snowflake.md) rather
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

### Spock read-only support

Spock supports enabling a cluster to be operated in read-only mode.

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
