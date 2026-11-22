# Detecting and Repairing TOAST Divergence

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

Spock records the rows that may have diverged and lets you confirm which
ones did.

Switching the table to `REPLICA IDENTITY FULL` is no way around it: Spock
does not support FULL on its own for `UPDATE` and `DELETE` (see
[Limitations](limitations.md)), and when a table's replica identity is
changed to FULL, AutoDDL takes the table out of its replication set.

## What is recorded

The apply worker recognizes the moment of divergence from facts it already
holds. When an `UPDATE` from another node wins a conflict, and it carries at
least one large column it did not change, and the local row was last written
by a different origin, the row is written to `spock.toast_suspect`. A row
updated again by the node that last wrote it is recorded only when version
stamps (below) show that the column differs: both sides usually agree on
it, except in a mesh where the sending node took the column from a third
node whose change has not arrived here yet. Tables at
`REPLICA IDENTITY FULL` are never recorded, because the whole old row
travels with the change, and neither are tables with no replica identity
key on the receiving node, since there is nothing to name the row by.

On its own, the "last written by a different origin" test cannot tell a
concurrent update from a later one: if node A writes a row and node B
updates it an hour later, nothing conflicted, but the test matches. Version
stamps settle this. With each unchanged large column, the sending node also
sends the column's version stamp: the node and commit timestamp of the
transaction that wrote the value, and its size. A value is never changed in
place, and Spock applies a change under the originating node's id and commit
timestamp, so every node that holds the same version of a value holds it
under the same stamp. The receiving node compares the stamp with its own
value's and records the row only when they differ, or when it cannot tell.
With stamps, sequential updates from different nodes are no longer recorded.

Each entry's `reason` says how sure detection was:

- `stamp_mismatch`: the local value is a different version from the sender's.
  Usually a real divergence, except after a table rewrite (below).
- `no_local_stamp`: the sender sent a stamp, but the local value's stamp
  could not be read, or cannot be trusted (see below).
- `no_stamp`: the sender sent no stamp, so the older rule applied.

Some rows are still recorded although their values agree, because something
rewrote a value under a new transaction without changing it: the initial
table sync on a new node, `CLUSTER`, `VACUUM FULL`, pg_repack or a
table-rewriting `ALTER TABLE` run on the receiving node alone. Values whose
commit timestamp PostgreSQL no longer keeps have no readable stamp either.
Commit timestamps are kept only for transactions newer than the database's
frozen transaction id, so on a busy cluster values older than about
`autovacuum_freeze_max_age` transactions fall back to the older rule. A
value frozen and left unwritten for about four billion transactions can
instead read a newer transaction's stamp, as transaction ids wrap around:
that records a row needlessly, and never hides one. Verification still
hashes every entry against the winner before anything is written, so these
cost a check, never a wrong repair.

A rewrite on the sending node is quiet only for some rows. A `VACUUM FULL`,
`CLUSTER`, pg_repack or a table-rewriting `ALTER TABLE` gives every value
there a new stamp naming that node, with the same size. When the receiving
row was last written by the sender and the sender's stamp names the sender
itself, detection compares only the sizes, so such rows are not recorded.
Rows this node last got from another node are recorded as the sender next
updates them, as they would be with stamps off. So are the rows a forwarding
node passes on after it rewrote the table: their stamps name the forwarding
node, not the node the change came from. If this node had lost one of the
sender's writes in a conflict, its row was then last written by another
node, and the next update from the sender to win here compared the full
stamps and recorded it. A value the sender took from a third node is
compared in full, unless a rewrite on the sender has since given it the
sender's own stamp: then only the sizes are compared, and a divergence
between values of equal size is missed.

Stamps need protocol 6, which both nodes negotiate from Spock 6.1.0, and
`spock.toast_divergence_stamps` on at the provider, which is the default.
The walsender reads the stamps while it decodes: it opens the TOAST table
once per row, then for each such column finds the value's first chunk
through the TOAST index and reads that chunk's commit timestamp. Each column
costs about as much as reading one row by its primary key, and more when the
TOAST table's pages are not in shared buffers. The subscriber reads its own
stamp at the same cost, except for a row the sender last wrote with a value
the sender wrote itself, where it compares sizes only. With stamps off,
every candidate row is recorded and verification clears the ones that did
not diverge, and a row last written by the sending node is never recorded
(see below).

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
initial sync copied are recorded on their first such update, and
verification clears them.

A row whose commit timestamp can no longer be read is not recorded either.
Its last write is older than PostgreSQL keeps commit timestamps for, which
is also true of every row written before a `pg_upgrade`, so it is not a
recent local write. The same gap applies: a write made here just before a
`pg_upgrade`, or just before `track_commit_timestamp` was turned on, that
a sender had not applied yet can be lost to that sender's newer change and
is not recorded.

Detection, verification and repair need `track_commit_timestamp = on`, which
`last_update_wins` conflict resolution already requires. With it off,
nothing is recorded, `spock.toast_divergence_verify()` raises an error, and
the repair worker is not started. A winning node with it off is reported as
a connection error on its entries.

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
the cap. `spock.toast_divergence_verify()` removes it while it is in state
`suspect`, and the repair worker while it is in state `suspect` or
`confirmed`; an entry in another state stays until you delete it from
`spock.toast_suspect`.

Each row recorded, or recorded again, is written in its own subtransaction,
so a failure to record it only logs a warning and never discards the change
being applied. Each such subtransaction takes a transaction id. A remote
transaction that records more than 64 rows overflows PostgreSQL's
per-backend subtransaction cache, which slows snapshots on the node until
that transaction commits. With version stamps only rows that really differ
are recorded, so this needs many divergent rows in one transaction.

Detection is on by default and can be switched off with
`spock.toast_divergence_detection`.

The queue is local to the node that recorded the entries. It is not
replicated, and `pg_dump` does not include it, since its entries key on the
local OIDs of the tables they name.

## Confirming a suspect

A recorded row is only a suspect. Most suspects turn out to hold the same
value as the winner, because the local node had not changed the column. Run

```sql
SELECT * FROM spock.toast_divergence_verify();
```

on the node holding the suspects. It connects to the node that won each
conflict, using the subscription's connection string, and compares a hash
of each suspect column on both sides. Entries whose values agree are
deleted. Entries that differ move to state `confirmed` and record which
columns differ. A row that no longer exists on the winner is marked
`remote_missing` and left for you, since deciding whether a deleted row
should come back is not this feature's call. An entry the verifier could
not check keeps its state and shows the reason in `last_error`.

The function runs its SQL with `search_path` set to `pg_catalog, pg_temp`,
on this node and on the winner, so a function or operator another user
created in a schema such as `public` is never called in place of a built-in
one. Key columns are compared with their type's own equality operator,
named with its schema, so a key of a type such as `citext` still matches as
that type. When that operator is outside `pg_catalog`, both sides are cast
to the operator's own type first, so an operator created on a domain over
that type is not used either. The type must be in the same schema on both
nodes.

The result is a count of entries that went each way.

## Reading the list

```sql
SELECT schema_name, table_name, pkey, differing_columns, state,
       winner_node, detect_count, detected_at
  FROM spock.toast_divergence
 WHERE state = 'confirmed';
```

A `confirmed` row differed from the winner in the named columns when it was
checked. The winner holds the value that row-level last-update-wins says
every node should converge on. A row checked while this node was behind the
winner can be `confirmed` although the change still on its way will make
the two agree; the repair worker compares again before it writes.

## Repairing

With `spock.toast_divergence_repair = on`, a background worker on each node
checks and repairs suspect rows in a single pass, handling up to
`spock.toast_divergence_batch` entries per pass. After a full batch that
settled entries, the next pass starts at once, so a backlog is worked off
without pauses. After a pass that found less than a full batch, the worker
sleeps `spock.toast_divergence_interval` (default 300 ms), so new suspects
are usually handled within a fraction of a second. After a pass that
settled nothing, because every entry it read had to wait or failed (for
example, the winning node is down), it sleeps
`spock.toast_divergence_retry_interval` (default 1 s) instead. The worker
keeps one connection to each winning node between passes and opens a fresh
one after `spock.toast_divergence_conn_lifetime` (default 5 min). It is
off by default:
turning it on lets Spock rewrite rows in your tables. It runs on every
supported PostgreSQL version.

Checking and repairing a suspect happen in one step, and only a column
whose value differs from the winner's is transferred. A row that has
already converged since it was flagged is cleared for almost no cost.

A repair is the same decision the apply worker would have made had the
winner's row arrived again on the stream. The worker locks the local row,
reads its origin and commit timestamp, fetches the winner's current values
for the suspect columns together with the winner's commit timestamp and
origin, and applies the configured conflict resolution. If the winner still
wins, the columns that differ are rewritten. The repaired row carries the
winner row's commit timestamp, so later conflicts on it resolve against the
right history, and the repair is not replicated: every other node already
holds the winner's value. It also carries the winner's origin.

If the local row was changed again since detection and is now the newer
one, the row stays as it is and the entry is removed (see below).

The worker reads and writes each table as the table's owner, on both nodes,
so casts and operators the owner defined and row level security policies
never run as a superuser. On the winning node it reads the row through
`spock.toast_read_as_owner()`, called over the subscription's connection
string. The role in that string must be a superuser, as Spock requires, or a
member of the table owner's role with the SET option, with `EXECUTE` on that
function. A row that a row level security policy hides from the owner, with
`FORCE ROW LEVEL SECURITY`, reads as missing on this node, and its entry is
removed.

Values are copied as text: the winner's column cast to `text`, and cast
back to the column's type here. Built-in types read back as the same value;
a type with a cast to `text` of its own that its input function does not
read back the same way cannot be repaired correctly.

The worker runs its SQL under the same `search_path` as
`spock.toast_divergence_verify()`, `pg_catalog, pg_temp`. User code that a
repair write runs uses that path too, whether it is reached from a trigger
enabled `ALWAYS` or `REPLICA`, a `CHECK` or domain constraint, an index
expression, a generated column or a cast. A name it does not find there
fails the write, and the entry shows the error in `last_error`. An operator
or function on a type from another schema that has an implicit cast to a
built-in type does not fail: it resolves to the built-in one, so, for
example, `=` on two `citext` values compares them as `text`, case
sensitively, with no error. The apply worker runs the same code under the
path of the last DDL it replicated, so the two can differ. Give such
functions a `SET search_path` clause of their own to avoid both. A
`SET search_path` the code runs lasts only for that statement, here and in
the read on the winning node.

If the winning node no longer keeps its row's commit timestamp, because the
row is older than that node's commit timestamp horizon, the conflict rule
cannot compare the rows. When the local row was last written by the winning
node, the winner's row is at least as new, and the row is repaired.
Otherwise the entry is removed with a warning naming the row; compare it
with ACE.

Entries whose winner subscription is disabled wait, and are repaired once
it is enabled again. Entries whose winner subscription has been dropped,
for example because that node left the cluster, can never be repaired: the
worker deletes them and logs a warning with the count. Those rows may still
differ from the last values the removed node had; compare the tables with
ACE if that matters. Entries that can be worked on are taken first, so
waiting entries do not hold up the rest of the queue. An entry that cannot
be repaired keeps its state with the reason in `last_error` and is retried
on the next pass. A row that no
longer exists on the winner is marked `remote_missing` and left for you.

The worker holds a replication origin named `spock_toast_repair_<dboid>`
while it runs. It counts against `max_replication_slots` per database on
PostgreSQL 15 to 17, and against `max_active_replication_origins` from
PostgreSQL 18.

There is no on-demand repair function. With the default settings the
worker checks the queue several times a second, so new suspects are
handled almost as soon as they are recorded.

To repair by other means, for example with ACE's table repair using
`--preserve-origin`, remove the entry afterwards:

```sql
SELECT spock.toast_divergence_clear('public.orders', '{"id": "42"}');
```

## Performance

With stamps on, which is the default, the steady cost of this feature is the
stamp lookup on the sending node. Verification and repair have work only for
rows that really differ, and for rows whose stamp could not be read. In a
cluster with occasional conflicts, the queue is empty most of the time.

### Sending stamps

The walsender for each subscriber reads a stamp for every out-of-line column
that an `UPDATE` leaves unchanged, whether or not the row conflicts. Each
lookup costs about as much as reading one row by its primary key, so a row
with many such columns costs that many lookups. The cost grows when the
TOAST table no longer fits in shared buffers, because each lookup may then
read a page from disk. A node with several subscribers does this work once
for each of them.

The lookups slow the walsender, not the writing transaction. A walsender
that cannot keep up shows as replication lag rather than as lower throughput
on the provider. In testing, that happened only with many large columns per
row, a high update rate, and a TOAST table about the size of shared buffers.

Turning `spock.toast_divergence_stamps` off at the provider removes this
cost. The subscriber then records every candidate row, and verification or
repair must clear each entry later. Clearing one entry costs far more than a
stamp lookup, because both nodes read and hash the whole value. Turning
stamps off is cheaper only for a table with many large columns, a high
update rate, and rows that another node rarely writes. The setting applies
to the whole node, not to one table. Watch the queue size against
`spock.toast_divergence_max_suspects` when stamps are off, because at the
cap new divergences are not recorded.

### Verifying and repairing

Verification and the repair worker read and hash the full value of each
suspect column on both nodes. They send one query to each winning node per
table in each batch, and a batch ends at `spock.toast_divergence_batch`
entries or `spock.toast_divergence_fetch_bytes` of values. For small values
the round trips set the pace, so the rate falls with network latency; for
large values, reading, hashing and copying the values set the pace.

A repair writes the columns that differ, plus one more version of the row
that reuses the values just written. A backlog of repairs therefore writes
about as much data as it copies, and competes for I/O like any other write
of that size. In testing, repairing 1 GB slowed concurrent `pgbench` traffic
no more than an ordinary session writing the same 1 GB.

With an empty queue, the repair worker runs one small query on
`spock.toast_suspect` every `spock.toast_divergence_interval`, which is
300 ms by default and uses a small fraction of one CPU core. A longer
interval lowers that cost and delays the repair of new entries by as much.

## What this does not cover

Nodes older than Spock 6.1.0 keep no queue, so during a rolling upgrade
nothing is recorded for changes that come from a node still on an older
release. The apply worker logs a warning once, at the first update from such
a node that wins over a row another node last wrote. Repairing from such a
node could spread a value that lost an earlier conflict, since it has no
record of its own divergences. Once every node runs 6.1.0 or later, compare
the replicated tables with ACE to find anything that diverged during the
upgrade.

If the node that lost a conflict updates the row again before the repair,
leaving the TOAST column alone, its row is then the newer one and keeps the
losing value. That update reaches the other nodes with the column
unchanged, and they record suspects of their own naming this node, so the
cluster can end on the value that lost.

Detection is forward-only. Rows that diverged before this feature was
enabled, or while detection was off, are never recorded. Use ACE for a
baseline comparison; this feature keeps a baselined cluster converged from
then on. An empty list does not mean a consistent cluster unless the
cluster was consistent when detection started.

With `spock.toast_divergence_stamps` off at a provider, a row last written
by that provider is never recorded on its subscribers. In a mesh of three or
more nodes that misses one case: node A takes a large column from node C,
then updates another column of the row, and A's update reaches node B before
C's change does. B keeps its old value, and C's change then loses to A's
newer row on B. Keep stamps on in a mesh, or compare with ACE. With stamps
on, the same case is missed when B cannot read its own value's stamp (a
value copied by the initial sync and not written since, a value older than
PostgreSQL keeps commit timestamps for, or a TOAST table locked at that
moment), or when A sent no stamp (its TOAST table was locked, the value was
replaced and vacuumed before A decoded the change, or A rewrote the table
since). Sizes are not compared then either.

A statement replicated as a statement, such as a table-rewriting
`ALTER TABLE` sent by AutoDDL or DML run through `spock.replicate_ddl()`,
runs on every node under the originating node's id and commit timestamp.
Afterwards every node holds the rewritten column under the same stamp,
whatever its contents, so a difference between values of the same size that
exists at that moment, including a write still on its way that then loses to
the rewritten row, is no longer recorded. Compare the table with ACE after
such a statement.

A change that fails to apply on a node and is thrown away under
`spock.exception_behaviour` `discard` or `transdiscard`, or skipped by LSN,
leaves that row on the older version, and the next update from the same
node keeps its large columns as they are. Detection records the row only
when the lost write changed a column's size. The thrown-away changes are
listed in `spock.exception_log`; compare those rows with ACE.

Delete divergence, where one node deleted a row another node updated, is
not detected here beyond marking a `remote_missing` entry.

When the winning change reached a node through another node, on a
subscription with `forward_origins`, the forwarding node cannot be used to
check it: it applied the same unchanged column and may hold a stale value
itself. Spock does not allow a direct subscription to the originating node
while forwarding is active, so such an entry is kept with no winner
subscription and a `last_error` saying so, and is never verified or repaired
automatically. Use ACE to compare the row with the originating node, then
`spock.toast_divergence_clear()`.

A repair that the local table rejects every time, for example through a
`CHECK` constraint or a trigger that raises an error on the winner's value,
is retried on every pass of the repair worker, and the winner's value is
fetched again each time. The entry shows the error in `last_error`. Resolve
the row by hand and remove the entry with `spock.toast_divergence_clear()`.

Automatic repair on a node relies on the node that won the conflict also
running with `spock.toast_divergence_detection` on. If a peer has detection
turned off, some divergences that node should have corrected toward can be
left unrepaired; use `spock.toast_divergence_verify()` and
`spock.toast_divergence_clear()`, or ACE, to resolve those.
