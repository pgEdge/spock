# Slow apply and large WAL retention from a single big transaction

## What you are seeing

A single large transaction on the publisher (for example, one INSERT that
loads 60,000 rows or more into a table with many indexes) shows three
symptoms on the subscriber side:

- The apply worker takes a long time to finish (tens of minutes for the
  big examples we tested).
- The publisher's logical replication slot does not move forward.
  `restart_lsn` stays frozen for the full duration of the apply.
- The publisher accumulates a lot of WAL on disk during that window.
  In one of our reproductions a 600,000 row INSERT held ~28 GB of WAL
  pinned for about 17 minutes.

## Why this happens

A logical replication slot cannot release WAL that belongs to a
transaction that has not yet committed on the subscriber side. The slot
position can only move past a transaction once that transaction's
COMMIT has been applied.

When a single big transaction takes 10 to 30 minutes to apply, that is
10 to 30 minutes during which:

- The slot's `restart_lsn` does not move.
- Every WAL segment written on the publisher since the BEGIN of that
  transaction is kept on disk.
- The subscriber does not show any of those rows yet (count stays at 0
  until the final COMMIT).

If the table also has `spock.check_all_uc_indexes = on` and several
secondary unique indexes, the apply path scans every secondary unique
index for every row, which makes each row noticeably more expensive and
stretches the apply window further.

## This is a workload pattern, not a Spock bug

We reproduced the same behaviour on a clean Spock build with no
patches. The slot stays pinned for the entire apply of a single large
transaction. That is how logical replication slots are designed to
work in PostgreSQL: a slot must keep enough WAL on the publisher to be
able to start streaming the transaction from the beginning. There is
nothing on the Spock side that can release WAL before the transaction
commits on the subscriber.

## What you can do today

The two changes below address the symptom directly and do not require
a Spock upgrade.

### 1. Break the big transaction into smaller chunks

This is the most effective change. Instead of one INSERT that loads
60,000 rows in a single transaction, load them in batches of, for
example, 1,000 or 5,000 rows per transaction. Each COMMIT lets the
slot's `restart_lsn` move forward, and the publisher reclaims the WAL
behind it. Apply lag becomes incremental and bounded instead of one
long pin.

A typical pattern:

```sql
-- instead of one big INSERT
DO $$
DECLARE
  batch_size int := 5000;
  start_id   int;
BEGIN
  FOR start_id IN 1 .. 60000 BY batch_size LOOP
    INSERT INTO my_table SELECT ... FROM ... WHERE id BETWEEN start_id
                                          AND start_id + batch_size - 1;
    COMMIT;
  END LOOP;
END $$;
```

The exact batch size depends on your row width and acceptable
throughput. Most workloads we have seen are comfortable in the 1,000
to 10,000 row per transaction range.

**Important: you give up all-or-nothing rollback.** Once you split one
large transaction into many smaller ones, each batch commits on its
own. If batch 7 of 12 fails, the first 6 batches are already committed
and visible to readers; only batch 7 and later are missing. You are
responsible for handling that case. Practical ways to handle it:

- Track the last successful batch (for example, the last `id` range
  that committed) so you can resume from that point.
- Make the INSERT idempotent (`INSERT ... ON CONFLICT DO NOTHING`, or
  re-run on a staging table and then merge) so re-running a partially
  applied batch is safe.
- Wrap the loop in your own error handling that records which batch
  failed and either retries it or stops and alerts an operator.

If your original use of the big transaction was specifically to get
"either all rows land or none of them land" semantics, batching breaks
that guarantee. Decide before you change anything whether your
downstream consumers can tolerate seeing a partial load.

### 2. Turn off `spock.check_all_uc_indexes` for that workload

`spock.check_all_uc_indexes` makes the apply worker scan every
secondary unique index for every INSERT, to catch conflicts on unique
columns that are not the primary key. It is an opt-in feature
(default `off`) and is documented as experimental.

If your bulk load does not produce real conflicts on those secondary
unique indexes (which is the normal case for a one-time load), turn it
off for the session that runs the load:

```sql
-- on the subscriber side, before the bulk load on the publisher
ALTER SYSTEM SET spock.check_all_uc_indexes = off;
SELECT pg_reload_conf();
```

Re-enable it once the load is finished if you want the conflict
protection for normal traffic:

```sql
ALTER SYSTEM SET spock.check_all_uc_indexes = on;
SELECT pg_reload_conf();
```

**Important: you lose unique-index conflict protection while it is
off.** With the GUC on, Spock catches the case where an incoming row
collides with an existing local row on a secondary unique index (not
the primary key or replica identity) and resolves it through the normal
conflict path. With the GUC off, that detection does not happen. If
a colliding row arrives, the apply worker still tries the INSERT, the
heap rejects it with a duplicate-key violation, and (because the
default `spock.exception_behaviour` is `sub_disable`) the subscription
is disabled until an operator inspects `spock.exception_log` and
re-enables it.

So turn the GUC off only when one of these is true:

- The bulk load is genuinely first-time data on the subscriber and you
  know no row in the batch can collide with an existing local row on a
  non-PK unique column.
- The unique columns are produced by the publisher in a way that
  guarantees no overlap with what is already on the subscriber
  (sequence-allocated IDs, UUIDs, time-bucketed keys, etc.).
- You have a recovery plan in place for the case where the subscription
  is disabled by a duplicate-key error mid-load.

If you are not sure, leave the GUC on and rely on batching alone for
the apply-time improvement.

Combining the two changes (smaller transactions plus the GUC off) gives
the biggest reduction in apply time and WAL retention for a bulk load
window, but only if both caveats above are acceptable for your
workload.

## Use C collation on TEXT columns that participate in unique indexes

This is the single biggest performance lever for tables shaped like
yours (many indexes, with several compound unique indexes on TEXT
columns). It is worth doing even if you also apply the two
mitigations above.

Under a UTF-8 (or similar locale-aware) collation, every comparison
on a TEXT key calls `strcoll`, which on glibc is several hundred
nanoseconds per call. For an apply path that has to consult several
secondary unique indexes per row, with compound TEXT keys, that cost
compounds quickly.

In our reproduction on a customer-shaped table (4 compound unique
indexes on TEXT columns, plus ~16 other indexes):

- With the default UTF-8 collation on those TEXT columns the apply
  path is roughly **2x slower** (around 100% overhead) compared to a
  baseline with no unique-index conflict checking.
- With `C` collation on the same TEXT columns the apply path is
  roughly **1.2x slower** (around 20% overhead).

That is a 5x improvement on the apply-side overhead for the same
schema and the same data, purely from the collation change.

How to change it:

```sql
ALTER TABLE my_table
  ALTER COLUMN account TYPE text COLLATE "C",
  ALTER COLUMN slug    TYPE text COLLATE "C",
  ALTER COLUMN uri     TYPE text COLLATE "C";
-- repeat for every TEXT column that appears in a unique index
```

Before changing, verify that no part of your application depends on
collation-aware ordering of those columns. `C` collation orders by
raw byte value, which differs from natural-language order for
non-ASCII strings. If you sort or compare those columns in queries
and the order matters to your users, you need to keep the locale-aware
collation, or move it to an expression / generated column for sorting
only.

## Behaviour when conflicts actually happen

The mitigations above target the no-conflict case (the apply worker
scans secondary unique indexes and finds nothing). When a real
conflict is found, the apply path has to do more work:

- The row is updated in place on the local table.
- Every index on the table is updated to reflect the new row version.

For a table with 20 indexes, that index-update work alone dominates
the per-conflict cost. In our measurements, **more than half of the
time spent handling a conflict row is inside PostgreSQL updating the
row and its indexes**, not in any Spock-specific code. There is no
Spock-side tuning that changes that ratio; it is the price of having
many indexes on a table that takes conflicting writes.

If the conflict rate is high and the per-row cost is the bottleneck,
the only real options are reducing the index count on the conflicting
table, or moving the high-conflict columns to a separate narrower
table that does not carry the full index set.

## Additional levers if the load is still heavy

- **Reduce conflict logging overhead.** Each conflict event is logged
  at `LOG` level by default. If your bulk load produces many of them
  and `log_min_messages` is at `info` or lower, the logging itself
  becomes a measurable cost. Set:

  ```ini
  log_min_messages          = warning
  spock.conflict_log_level  = debug
  ```

  so the per-conflict line is below the server threshold and is not
  written. There is also an in-progress Spock change that removes some
  extra work the apply path was doing when conflict logging is
  effectively disabled; once it ships, the cost of conflict-heavy
  apply with the GUCs above is lower again.

## Longer-term direction

PostgreSQL's logical replication has a `streaming` option that streams
an in-progress transaction to the subscriber instead of buffering it
on the publisher until COMMIT. With `streaming = parallel` (PostgreSQL
16 and later) the subscriber can apply incoming changes in parallel as
they arrive. For workloads dominated by one very large transaction
this would remove the reorder-buffer disk spill on the publisher (the
largest disk consumer in the customer profile we looked at, around
148 GB per slot) and start applying rows before the publisher-side
COMMIT.

Wiring this option into Spock's apply worker is a larger piece of
work. It is on the longer-term list, not a short-term fix. Until that
lands, the two mitigations above are the right answer for the
immediate problem.

## Quick checklist

In rough order of impact for the workload we have seen:

- **Switch TEXT columns that participate in unique indexes to `C`
  collation.** ~5x improvement on apply-side overhead in our test.
  Confirm no application code depends on locale-aware ordering of
  those columns first.
- **Split the large transaction into batches of 1,000 to 10,000 rows**
  with a COMMIT between batches.
  Be aware: each batch commits independently; a failure mid-load leaves
  earlier batches visible. Plan how you will resume or recover.
- **Turn `spock.check_all_uc_indexes` off for the bulk-load window.**
  Be aware: while off, a row that conflicts on a non-PK unique index
  will not be caught by Spock; the heap will raise a duplicate-key
  error and (under `sub_disable`) disable the subscription. Use this
  only when the bulk-load data cannot collide with existing rows on a
  secondary unique index.
- If you still see conflict-log noise, set `log_min_messages = warning`
  and `spock.conflict_log_level = debug`.
- If the table sees a high conflict rate and per-row cost is still the
  bottleneck, the cost is dominated by PostgreSQL updating the row and
  its indexes. The remedy there is fewer indexes on the conflicting
  table, not a Spock tuning change.
