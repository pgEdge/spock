# Detecting TOAST Divergence

PostgreSQL stores large column values out of line, in a TOAST table, and
does not write such a value to WAL when an `UPDATE` leaves it unchanged.
The replicated change therefore carries a marker instead of the value, and
the subscriber keeps whatever it already holds for that column.

On a table at `REPLICA IDENTITY DEFAULT`, that is correct as long as the two
nodes already agreed on the column. It goes wrong when they did not. If
node A changes a large column and node B changes a small column of the same
row at nearly the same time, and B's change is newer, B's row wins on both
nodes. A installs B's small column but keeps its own large value, because
B's message did not carry one. The two nodes now agree who won and hold
different rows, and nothing corrects it.

Spock records the rows that may have diverged.

Switching the table to `REPLICA IDENTITY FULL` is no way around it: Spock
does not support FULL on its own for `UPDATE` and `DELETE` (see
[Limitations](limitations.md)), and when a table's replica identity is
changed to FULL, AutoDDL takes the table out of its replication set.

## What is recorded

The apply worker recognizes the moment of divergence from facts it already
holds. When an `UPDATE` from another node wins a conflict, and it carries at
least one large column it did not change, and the local row was last written
by a different origin, the row is written to `spock.toast_suspect`. A row
updated again by the node that last wrote it is not recorded: both sides
usually agree on the column, except in the mesh case listed under "What
this does not cover". Tables at `REPLICA IDENTITY FULL` are
never recorded, because the whole old row travels with the change, and
neither are tables with no replica identity key on the receiving node,
since there is nothing to name the row by.

The "last written by a different origin" test cannot tell a concurrent
update from a later one: if node A writes a row and node B updates it an
hour later, nothing conflicted, but the row is recorded.

A row last written before the subscription the change arrives on was created
is not recorded. That covers the rows copied by the initial table sync when
a node joins, which carry an epoch commit timestamp, and data restored
before replication was set up. Without this, the first such update to every
copied row on a new node would be recorded. A divergence detected here needs
a local write that raced the incoming change, and such a write is newer than
the subscription; differences that predate replication are outside what
detection covers (see below). This is the same test
`spock.log_origin_change = since_sub_creation` applies. It assumes the
sending node had already applied this node's earlier writes when the
subscription was created. A write made here before then, which the sender
had not yet applied, can still be lost to a newer change from the sender and
is not recorded, so let a node catch up before other nodes subscribe to it
while it takes writes. A subscription created before Spock 5.0.6 has no
recorded creation time, so this test does not apply to it: the rows its
initial sync copied are recorded on their first such update.

A row whose commit timestamp can no longer be read is not recorded either.
Its last write is older than PostgreSQL keeps commit timestamps for, which
is also true of every row written before a `pg_upgrade`, so it is not a
recent local write. The same gap applies: a write made here just before a
`pg_upgrade`, or just before `track_commit_timestamp` was turned on, that
a sender had not applied yet can be lost to that sender's newer change and
is not recorded.

Detection needs `track_commit_timestamp = on`, which `last_update_wins`
conflict resolution already requires. With it off, nothing is recorded.

One entry is kept per row. A repeat detection replaces it and increments its
count, at the cap too. The table is approximately capped by
`spock.toast_divergence_max_suspects`: each apply worker checks the row
count at most once every 10 seconds, so the table can be pushed past the cap
by whatever detections land inside that window. At the cap the apply worker
adds no new rows until the table drains, and logs a warning once an hour
when it skips one. Entries are keyed by the table's replica identity index,
the primary key unless `REPLICA IDENTITY USING INDEX` names another. An
`UPDATE` that changes the key leaves an earlier entry under the old key,
naming a row that no longer exists; remove it with
`spock.toast_divergence_clear()`. An entry for a table that has since been
dropped no longer shows in `spock.toast_divergence` but still counts toward
the cap until it is removed; delete it from `spock.toast_suspect` by its
`relid`.

Each row recorded, or recorded again, is written in its own subtransaction,
so a failure to record it only logs a warning and never discards the change
being applied. Each such subtransaction takes a transaction id. A remote
transaction that records more than 64 rows overflows PostgreSQL's
per-backend subtransaction cache, which slows snapshots on the node until
that transaction commits.

Detection is on by default and can be switched off with
`spock.toast_divergence_detection`.

The queue is local to the node that recorded the entries. It is not
replicated, and `pg_dump` does not include it, since its entries key on the
local OIDs of the tables they name.

## Reading the list

```sql
SELECT schema_name, table_name, pkey, columns, winner_node, detect_count,
       detected_at
  FROM spock.toast_divergence;
```

Each row may differ from the winner in the named columns. The winner holds
the value that row-level last-update-wins says every node should converge
on.

## Repairing

To repair a row, for example with ACE's table repair using
`--preserve-origin`, remove the entry afterwards:

```sql
SELECT spock.toast_divergence_clear('public.orders', '{"id": "42"}');
```

## What this does not cover

Detection is forward-only. Rows that diverged before this feature was
enabled, or while detection was off, are never recorded. Use ACE for a
baseline comparison; from then on this feature finds what diverges. An
empty list does not mean a consistent cluster unless the cluster was
consistent when detection started.

Delete divergence, where one node deleted a row another node updated, is
not detected here.

In a mesh of three or more nodes, a node can take a large column from a
third node, then update another column of the row. When that update
reaches this node before the third node's change, the row here was last
written by the sending node, so it is not recorded, and the third node's
change then loses here to the newer update. This node keeps its old value
of the column.

When the winning change reached a node through another node, on a
subscription with `forward_origins`, the forwarding node cannot be used to
check it: it applied the same unchanged column and may hold a stale value
itself. Spock does not allow a direct subscription to the originating node
while forwarding is active, so such an entry is kept with no winner
subscription and a `last_error` saying so. Use ACE to compare the row with
the originating node, then `spock.toast_divergence_clear()`.
