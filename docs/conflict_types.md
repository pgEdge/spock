## Conflict Types

For conflict *avoidance* using delta-apply columns, see
[Conflict Avoidance and Delta-Apply Columns](conflicts.md).

In a multi-master replication environment, conflicts occur when two or
more nodes make changes to the same row (as identified by a primary key
or replica identity) at overlapping times. Spock detects these conflicts
during the apply phase on the subscribing node and resolves them
according to a configurable resolution strategy.

Each conflict is classified as one of the types described below.
Resolvable conflicts are recorded in the `spock.resolutions` table
(when `spock.save_resolutions` is enabled); non-resolvable conflicts
are recorded in `spock.exception_log`.

### Summary Table

| Conflict Type              | DML       | Resolvable                          |
|----------------------------|-----------|-------------------------------------|
| `insert_exists`            | INSERT    | Yes                                 |
| `update_origin_differs`    | UPDATE    | N/A (normal flow, not recorded)     |
| `update_exists`            | UPDATE    | No (unique constraint violated), saved in `spock.exception_log` |
| `update_missing`           | UPDATE    | No (row not found), saved in `spock.exception_log`              |
| `delete_origin_differs`    | DELETE    | N/A (normal flow, not recorded)     |
| `delete_missing`           | DELETE    | Yes                                 |
| `delete_exists`            | DELETE    | Yes                                 |

A conflict is **resolvable** when Spock can automatically choose a
winning tuple and continue replication without operator intervention.
`update_missing` and `update_exists` are not resolvable and result in
an ERROR that is recorded in `spock.exception_log`.

---

### `insert_exists`

A remote INSERT arrives but a row with the same primary key (or replica
identity) already exists on the local node. This typically happens when
two nodes independently insert a row with the same key.

Spock detects the conflict by looking up the incoming tuple against
unique indexes (primary key, replica identity, and optionally all
unique constraints when `spock.check_all_uc_indexes` is enabled).

**Resolution:** The configurable conflict resolver (default
`last_update_wins`) compares the commit timestamps of the local and
remote rows. The winner's values are applied as an UPDATE to the
existing row.

---

### `update_origin_differs`

A remote UPDATE targets a row whose local copy was last modified by a
different replication origin. In a multi-master topology this is the
normal flow of replication -- two nodes each modify a row and the
changes propagate -- so Spock does not treat it as a true conflict.
PostgreSQL's native logical replication does classify it as a conflict,
however, so Spock tracks the type for completeness and supports
optional logging via the `spock.log_origin_change` GUC.

Spock detects this by comparing `replorigin_session_origin` (the
source of the incoming change) with the origin recorded on the local
tuple. Changes from the same origin or the same local transaction are
silently applied without any conflict reporting.

**Resolution:** The configurable conflict resolver (default
`last_update_wins`) determines the winner. Since this is normal
replication flow, the event is not written to `spock.resolutions`
regardless of which side wins.

---

### `update_exists`

A remote UPDATE is applied successfully via the replica identity, but
the new row values violate a unique constraint on a different index.
For example, the UPDATE changes a column that is part of a secondary
unique index and the new value collides with another existing row.

This conflict type matches the definition used by PostgreSQL 18's
native logical replication. Spock reports it to the PostgreSQL server
log and PG18 conflict statistics when the unique constraint violation
is detected.

**Resolution:** This conflict is **not** automatically resolvable. The
error is written to `spock.exception_log`.

---

### `update_missing`

A remote UPDATE cannot find the target row on the local node. The row
may have been deleted locally, or it may never have arrived due to a
replication gap.

Spock retries the lookup several times (with short waits) in case the
row is being inserted by a concurrent transaction. If the row still
cannot be found after retries, the conflict is raised.

**Resolution:** This conflict is **not resolvable**. Spock raises an
ERROR, which is logged to `spock.exception_log`.

---

### `delete_origin_differs`

A remote DELETE targets a row that exists locally but was last modified
by a different replication origin. As with `update_origin_differs`,
this is normal replication flow rather than a true conflict -- one node
deletes a row while another node's earlier update is still in flight.
Spock tracks the type because PostgreSQL's native logical replication
considers it a conflict, and supports optional logging via
`spock.log_origin_change`.

If the local tuple came from the same origin as the incoming delete,
or from the same local transaction, the delete is applied silently
with no conflict reporting.

**Resolution:** The configurable conflict resolver (default
`last_update_wins`) determines the winner. When the remote DELETE
wins, the delete proceeds. When the local tuple wins (it is newer),
the delete is skipped and the row is preserved; this case is reported
as `delete_exists` instead.

---

### `delete_missing`

A remote DELETE cannot find the target row on the local node. The row
was likely already deleted by a local or other replicated transaction.

As with `update_missing`, Spock retries the lookup several times
before confirming the row is absent.

**Resolution:** The conflict is automatically resolved by skipping the
delete (`skip`). Since the row is already gone, the desired end state
has been achieved. The event is recorded in the `spock.resolutions`
table.

---

### `delete_exists`

A remote DELETE arrives but the local copy of the row has a more
recent commit timestamp than the delete. This is unique to Spock and
does not have a counterpart in native PostgreSQL logical replication.

This occurs when one node deletes a row while another node updates it
with a later timestamp. The delete is the older operation, so the
updated row should be preserved.

**Resolution:** The delete is skipped and the local (newer) row is
kept (`skip` / `keep_local`). The event is recorded in the
`spock.resolutions` table.

---

### Conflict Resolution Strategies

The `spock.conflict_resolution` GUC controls how resolvable conflicts
(all types except `update_missing` and `update_exists`) are decided:

| Strategy              | Behavior                                                  |
|-----------------------|-----------------------------------------------------------|
| `last_update_wins`    | The row with the most recent commit timestamp wins (default). |
| `first_update_wins`   | The row with the earliest commit timestamp wins.          |
| `apply_remote`        | Always apply the incoming remote change.                  |
| `keep_local`          | Always keep the local row.                                |
| `error`               | Raise an ERROR on any conflict.                           |

The timestamp-based strategies (`last_update_wins` and
`first_update_wins`) require `track_commit_timestamp = on` in
`postgresql.conf`.

**Tiebreaker:** When two rows have identical commit timestamps, Spock
uses the `tiebreaker` value from the `spock.node` configuration to
determine a winner. The node with the lower tiebreaker value wins. By
default the tiebreaker is set to the node's unique ID.

### Frozen Tuples and Missing Timestamp Data

Timestamp-based conflict resolution depends on commit timestamp and
origin information being available for the local tuple. There are two
cases where this information is missing:

**Frozen tuples.** PostgreSQL periodically "freezes" old row versions,
replacing their transaction ID with `FrozenTransactionId`. Once
frozen, the original commit timestamp and origin can no longer be
retrieved. When Spock encounters a frozen local tuple during conflict
resolution, it treats the local timestamp as zero. Since any real
remote timestamp is greater than zero, the remote change always wins.
No conflict is logged because the local origin could not be
determined.

**`track_commit_timestamp = off`.** If commit timestamp tracking is
disabled, Spock cannot retrieve origin or timestamp information for
any local tuple. In this case, Spock copies the remote origin and
timestamp into the local values. The same-origin check then sees
matching origins and treats the change as normal replication flow --
no conflict is detected or logged. This effectively makes conflict
resolution invisible: the remote change is always applied silently.

For reliable conflict detection and resolution,
`track_commit_timestamp` must be set to `on`.

### Conflict Logging

- **`spock.save_resolutions`** (default `off`) -- When enabled,
  resolved conflicts are written to the `spock.resolutions` table
  with full tuple details in JSON format.
- **`spock.conflict_log_level`** (default `LOG`) -- Controls the
  PostgreSQL log level at which detected conflicts are reported. Set
  to a level below `log_min_messages` to suppress log output.
- **`spock.log_origin_change`** (default `none`) -- Controls whether
  `update_origin_differs` and `delete_origin_differs` events (normal
  replication flow) are logged to the PostgreSQL server log. These
  events are never written to `spock.resolutions`. Options: `none`,
  `remote_only_differs`, `since_sub_creation`.

### Comparison with PostgreSQL 18 Native Logical Replication

PostgreSQL 18 introduced built-in conflict detection for logical
replication. Spock's conflict types are aligned with PostgreSQL's
definitions (same names, same enum ordering) so that the two systems
report conflicts in a consistent way. The key differences are in how
each system *resolves* conflicts and where it *records* them.

| Conflict Type           | PostgreSQL 18                          | Spock (with last update wins)                |
|-------------------------|----------------------------------------|----------------------------------------------|
| `insert_exists`         | Logs and raises ERROR.                 | Resolves via `last_update_wins`; transforms INSERT into UPDATE of the winning tuple. |
| `update_origin_differs` | Logs and always applies the remote tuple. | Resolves via `last_update_wins`; local tuple can win. Treated as normal replication flow (not a true conflict) with optional logging via `log_origin_change`. |
| `update_exists`         | Detects unique constraint violation on updated row; logs. | Logs and records in `spock.exception_log`. |
| `update_missing`        | Logs and skips.                        | Logs and records in `spock.exception_log`. |
| `delete_origin_differs` | Logs and always applies the delete.    | Resolves via `last_update_wins`; local tuple can win (reported as `delete_exists`). Treated as normal replication flow (not a true conflict) with optional logging. |
| `delete_missing`        | Logs and skips.                        | Logs and skips. Records in `spock.resolutions`. |
| `delete_exists`         | No equivalent.                         | Unique to Spock. The local row is newer than the remote DELETE, so the delete is skipped and the row is preserved. |

**Resolution.** PostgreSQL 18 does not resolve conflicts -- it either
applies the remote change unconditionally or skips the operation, and
logs the event. Spock adds configurable resolution strategies (default
`last_update_wins`) with a tiebreaker mechanism, allowing the local
tuple to win when it is more recent.

**Persistence.** PostgreSQL 18 writes conflicts only to the PostgreSQL
server log. Spock additionally persists certain conflicts in the
`spock.resolutions` table (with full tuple details in JSON) --
specifically `insert_exists`, `delete_missing`, and `delete_exists` --
and non-resolvable conflicts (`update_missing`, `update_exists`) in
`spock.exception_log`. Origin-differs events are not persisted to
either table.

**Statistics.** On PostgreSQL 18, Spock reports all conflict types to
the native `pgstat` subscription conflict statistics, so they appear
in the same views used by built-in logical replication.
