## NAME

spock.toast_stamp()

### SYNOPSIS

spock.toast_stamp (value "any")

### RETURNS

  - The version stamp of a value stored out of line, as
    `nodeid/commit_ts/rawsize`: the Spock node id and commit timestamp
    (microseconds since 2000-01-01) of the transaction that wrote the value,
    and its raw size.

  - NULL when the value is not stored out of line, or its stamp cannot be
    read: the transaction's commit timestamp is no longer kept, the value was
    written by the initial table sync, a lock on the TOAST table is held,
    `track_commit_timestamp` is off, or the node is a standby.

### DESCRIPTION

Shows the stamp a provider sends with an unchanged TOAST column and a
subscriber compares with its own, to record a TOAST suspect only when the
versions differ. Every node that holds the same version of a value shows the
same stamp, because Spock applies a change under the originating node's id
and commit timestamp.

The stamp changes whenever the value is written again, even with the same
contents, and when `CLUSTER` or `VACUUM FULL` rewrites the table. An UPDATE
that leaves the column alone keeps it.

A stamp names the transaction that wrote a value, not the write. When one
transaction writes the same column of a row twice with values of the same
size, both carry the same stamp. If a subscriber applies only the first
write, as `spock.exception_behaviour = discard` can when the second one
fails there, the two nodes hold different values under the same stamp, and
detection does not record the row. The skipped change is listed in
`spock.exception_log`.

Pass a column of a table, not an expression: only a value read from the
table carries its stamp. Needs `track_commit_timestamp = on`.

### ARGUMENTS

value

    A table column.

### EXAMPLE

    postgres=# SELECT id, spock.toast_stamp(big) FROM public.orders WHERE id = 42;
     id |         toast_stamp
    ----+------------------------------
     42 | 49708/847587278919297/200004
