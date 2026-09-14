## NAME

spock.repset_replica_identity_full()

### SYNOPSIS

spock.repset_replica_identity_full (set_name name)

### RETURNS

  - The number of tables whose identity was changed.

### DESCRIPTION

Sets `REPLICA IDENTITY FULL` on every `PRIMARY KEY` table in one replication
set. This is the bulk counterpart of
[`spock.auto_replica_identity_full`](../../configuring.md#spockauto_replica_identity_full),
which acts only on tables as they join a set; use this function for tables
that are already members.

Tables already at `REPLICA IDENTITY FULL` are passed over silently.
Partitioned parents are skipped; their partitions are members in their own
right and are handled on their own.

Two kinds of table are passed over with a WARNING naming them, the way
`spock.repset_add_all_tables()` reports what it cannot take instead of
failing the whole call:

  - a table without a `PRIMARY KEY`, which is what the subscriber would
    look the row up by; and

  - a table at `REPLICA IDENTITY USING INDEX` or `REPLICA IDENTITY
    NOTHING`, which was chosen deliberately. This matches
    [`spock.auto_replica_identity_full`](../../configuring.md#spockauto_replica_identity_full),
    which also changes only tables at `REPLICA IDENTITY DEFAULT`. To
    override such a table's identity, name it to
    [`spock.table_replica_identity_full()`](spock_table_replica_identity_full.md).

The replication set must replicate `UPDATE` or `DELETE`. An insert-only set
is refused with an error, since `REPLICA IDENTITY FULL` changes nothing for
`INSERT` and `TRUNCATE`.

The set name is required. There is no form that covers every set: switching
every table on a node to `REPLICA IDENTITY FULL` means the whole old row,
TOAST values included, is written to WAL and sent on every `UPDATE` and
`DELETE`, and that decision should be made one set at a time.

The change is local to the node, like every `spock.repset_*` function. It
is not replicated as DDL. Run it on every node.

The function runs in the caller's transaction. If it fails part-way, every
identity it changed is rolled back.

The caller must own the tables or be a superuser.

Every member of the set is inspected under an `AccessShareLock`, which is
released again at once. Only a table whose identity will actually change is
then locked with an `AccessExclusiveLock` for the rest of the transaction:
the lock `ALTER TABLE ... REPLICA IDENTITY` takes. Such a table blocks, and
is blocked by, any concurrent use of it until the transaction commits, so
run the call in a short transaction. A set whose tables are all already
`REPLICA IDENTITY FULL` takes no exclusive lock at all.

### ARGUMENTS

set_name

    The name of an existing replication set on this node.

### EXAMPLE

    postgres=# SELECT spock.repset_replica_identity_full('default');
    WARNING:  skipping table public.events for REPLICA IDENTITY FULL
    DETAIL:  Table has no PRIMARY KEY, which REPLICA IDENTITY FULL needs for row lookup on the subscriber.
    WARNING:  skipping table public.ledger for REPLICA IDENTITY FULL
    DETAIL:  Table has REPLICA IDENTITY USING INDEX, which was chosen deliberately; use spock.table_replica_identity_full() to override it.
     repset_replica_identity_full
    ------------------------------
                                7
