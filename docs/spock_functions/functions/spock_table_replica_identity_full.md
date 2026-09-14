## NAME

spock.table_replica_identity_full()

### SYNOPSIS

spock.table_replica_identity_full (relation regclass,
include_partitions boolean DEFAULT true)

### RETURNS

  - true if at least one table's identity was changed.

  - false if every target was already REPLICA IDENTITY FULL.

### DESCRIPTION

Sets `REPLICA IDENTITY FULL` on a table that has a `PRIMARY KEY`.

Spock supports `REPLICA IDENTITY FULL` only together with a `PRIMARY KEY`:
FULL decides what is written to WAL (the whole old row, TOAST values
included), and the `PRIMARY KEY` is what the subscriber uses to find the
row. A table without a `PRIMARY KEY` is refused with an error. This is the
check that a plain `ALTER TABLE ... REPLICA IDENTITY FULL` does not make.

For a partitioned table, every partition is switched and the parent is left
alone, because PostgreSQL never cascades `REPLICA IDENTITY` to partitions
and the partitions hold the rows. Calling with `include_partitions` set to
false on a partitioned table is an error, since there would be nothing to
alter.

Whatever replica identity the table has now is replaced, including
`REPLICA IDENTITY USING INDEX` and `REPLICA IDENTITY NOTHING`. This is the
one path that overrides a deliberate identity:
[`spock.repset_replica_identity_full()`](spock_repset_replica_identity_full.md)
and
[`spock.auto_replica_identity_full`](../../configuring.md#spockauto_replica_identity_full)
both leave those alone, because there the table was reached by walking a
set rather than named.

Replication set membership is not checked or changed. A table already in a
replication set keeps its membership.

The change is local to the node, like every `spock.repset_*` function. It
does not pass through the DDL replication path, so it is not replicated
even when `spock.enable_ddl_replication` is on. Run it on every node, the
way you run `spock.repset_add_table()` on every node. A hand-typed
`ALTER TABLE ... REPLICA IDENTITY FULL` behaves differently: with AutoDDL
on it is replicated to the other nodes.

The caller must own the table, or be a superuser. For a partitioned table
with `include_partitions` set to true, the caller must own every partition
that will change: ownership is checked as each one is altered, so a call
that reaches a partition the caller does not own fails and rolls back every
identity it had already changed, even when the caller owns the parent.

The function takes an `AccessExclusiveLock` on the table, and on each
partition, for the rest of the transaction: the lock
`ALTER TABLE ... REPLICA IDENTITY` takes. It therefore blocks, and is
blocked by, any concurrent use of the table. Run it in a short
transaction.

!!! warning

    Every node in the cluster must run Spock 6.0 before you switch any
    table to `REPLICA IDENTITY FULL`. A 5.x subscriber has no `PRIMARY
    KEY` fallback for a FULL table: it finds rows by a whole-row
    sequential scan, and reports rows that have diverged as
    `update_missing`. Finish the rolling upgrade first.

### ARGUMENTS

relation

    The table, as a regclass (for example `'public.orders'`).

include_partitions

    For a partitioned table, whether to switch its partitions. Default
    true. false on a partitioned table is an error.

### EXAMPLE

    postgres=# SELECT spock.table_replica_identity_full('public.orders');
     table_replica_identity_full
    -----------------------------
     t

A second call finds nothing to do:

    postgres=# SELECT spock.table_replica_identity_full('public.orders');
     table_replica_identity_full
    -----------------------------
     f

A table without a PRIMARY KEY is refused:

    postgres=# SELECT spock.table_replica_identity_full('public.log');
    ERROR:  table log has no PRIMARY KEY
    DETAIL:  REPLICA IDENTITY FULL is supported only together with a PRIMARY KEY, which the subscriber uses to find the row.
    HINT:  Add a PRIMARY KEY to the table first.
