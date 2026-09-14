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

Tables already at `REPLICA IDENTITY FULL` are passed over silently. A table
without a `PRIMARY KEY` is passed over with a WARNING naming it, the way
`spock.repset_add_all_tables()` reports what it cannot take instead of
failing the whole call. Partitioned parents are skipped; their partitions
are members in their own right and are handled on their own.

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

### ARGUMENTS

set_name

    The name of an existing replication set on this node.

### EXAMPLE

    postgres=# SELECT spock.repset_replica_identity_full('default');
    WARNING:  skipping table public.events for REPLICA IDENTITY FULL
    DETAIL:  Table has no PRIMARY KEY, which REPLICA IDENTITY FULL needs for row lookup on the subscriber.
     repset_replica_identity_full
    ------------------------------
                                7
