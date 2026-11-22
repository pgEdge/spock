## NAME

spock.toast_divergence_verify()

### SYNOPSIS

spock.toast_divergence_verify (max_rows integer DEFAULT 1000)

### RETURNS

A row with four integer counts: cleared, confirmed, remote_missing, failed.

### DESCRIPTION

The repair worker runs this same pass on each of its rounds when
`spock.toast_divergence_repair` is on, so calling it by hand is only needed
with the worker off.

Checks pending entries in `spock.toast_suspect` against the node that won
each conflict. For every entry in state `suspect`, up to max_rows, the
function connects to the winner and asks for a hash of each suspect column
for that row together with the row's commit timestamp and origin, and
compares with the same hash computed locally. The connection is made the
same way a replication connection is, from the subscription's connection
string and with the same connect timeout and keepalives, under the
application name `<subscription>_toastdiv`. Both sides pin the same text-output
settings (`bytea_output`, `DateStyle`, `IntervalStyle`,
`extra_float_digits`, `TimeZone`, `lc_monetary`) for the comparison, so a
value hashes the same regardless of each session's own settings. The function runs with those
settings pinned through its definition, and the calling session's own values
are back in effect when it returns.

Entries are taken oldest attempt first: those never tried before come first,
then those tried longest ago. `verified_at` records the last attempt,
whether it succeeded or not, so an entry that keeps failing cannot hold up
the rest of the queue.

- Equal hashes: the entry is deleted (cleared). The local node had not
  changed the column, so nothing diverged.
- A difference: the entry moves to `confirmed`, `differing` records which
  columns differ, and the winner's current commit timestamp and origin are
  stored (confirmed).
- Row missing on the winner: the entry moves to `remote_missing` and is
  left for the operator (remote_missing). This is delete divergence, which
  this function does not resolve.
- Row missing locally, or the table dropped, or every suspect column of the
  entry has been dropped: the entry is deleted (cleared). An entry names its
  row by the key it had when it was recorded, so after an `UPDATE` of the
  key the row is missing under the old key and the entry is cleared, even
  if the row under its new key still differs. Compare such rows with ACE.
- The subscription no longer exists, the connection to the winner fails, the
  remote hash query fails, the local hash query fails (for example after a
  column type change), a column named in the entry's key no longer exists in
  the local table (renamed or dropped), or the key matches more than one row
  here or on the winner (after the key was widened): the entry keeps its
  state, `last_error` records why, and it is retried on the next call
  (failed). Each such failure is contained to its own entry; the rest of the
  batch is still settled. Entries of the same table and winner share one
  remote query; if it fails on a data error, such as a key value the winner
  cannot read, they are retried one at a time, and any other error fails
  them all. A failed local read of a group is retried one entry at a time
  after any error except a lock timeout, which fails them all at once; a
  local `statement_timeout` ends the call. An entry whose winning
  subscription has been dropped fails on every call; it is yours to remove
  with `spock.toast_divergence_clear()`.

The comparison holds as of the call. If this node has not yet applied a
newer change to the row from the winner, the entry can be `confirmed` (or
`remote_missing`, for a delete still on its way) although the rows will
agree once that change arrives. The repair worker compares again before it
writes anything.

Entries in state `confirmed` or `remote_missing` are not re-checked. A new
detection on the same row returns it to `suspect`, and an entry the apply
worker detects again while this function is comparing it, or holds locked
because it is detecting it again, is left as it is for the next run rather
than settled from the older comparison.

The outcomes are written in one pass after the last comparison, so the
entries are locked only briefly before the function returns. Called inside a
longer transaction, they stay locked until that transaction ends, and the
apply worker waits on any of them it detects again; keep such transactions
short.

It requires `track_commit_timestamp = on` and raises an error otherwise. A
winning node with the setting off fails its entries with `last_error`
saying so, as does an entry whose winning change was forwarded by another
node.

Run it on the node holding the suspects, as a superuser, and do not grant
`EXECUTE` on it to other roles. It reads each local row as its table's
owner, as the repair worker does, so the owner's casts and row level
security settings apply. It reads the winner's row as the table's owner
there too, through `spock.toast_read_as_owner()`, so the role in the
subscription's connection string must be a superuser or a member of the
owner's role with the SET option. A row hidden from either side reads as
missing. It reads the table of the same name on the winner, so if the nodes
partition a table differently, an entry recorded for a partition can fail or
show as `remote_missing`; compare such rows with ACE. It opens one ordinary
connection, not a replication connection, per winning subscription for the
length of the call and closes them before returning. A cancel or
`statement_timeout` is acted on while it waits for a winner's answer, and
the queries still running on the winners are cancelled, but opening a
connection to an unreachable winner first waits out the connection timeout.
See [Detecting and Repairing TOAST Divergence](../../toast_divergence.md).

### ARGUMENTS

max_rows

    The most entries to check in this call. Default 1000. A negative
    value is an error.

### EXAMPLE

    postgres=# SELECT * FROM spock.toast_divergence_verify();
     cleared | confirmed | remote_missing | failed
    ---------+-----------+----------------+--------
          17 |         2 |              0 |      0
