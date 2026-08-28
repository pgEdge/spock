# Sizing Postgres Resources for Spock

Spock replication consumes three separate, independently-configured Postgres
resources: background worker slots, walsender slots, and replication
slots/origins. Each is governed by a different parameter, and each is sized
from a different property of your cluster.

Many of the values shown in the tutorials are a starting point for a small
test cluster, not a recommendation for production. This page explains what
Spock actually launches so you can size each parameter deliberately.

!!! warning

    Every parameter on this page requires a **server restart** to change.
    Under-sizing them is not a soft failure: Spock raises an `ERROR` when a
    worker cannot be registered and the supervisor retries in a loop, so
    replication does not start at all. Size with headroom.

## What Spock Runs on Each Node

| Process | How many | Counts against |
|---|---|---|
| Supervisor | 1 per instance, always running | `max_worker_processes` |
| Failover-slots worker | 1 per instance on PostgreSQL 15-17; not registered on 18+ | `max_worker_processes` |
| Manager | 1 per **connectable database** in the instance | `max_worker_processes` |
| Apply worker | 1 per enabled subscription | `max_worker_processes` |
| Sync worker | at most 1 concurrently per subscription | `max_worker_processes` |
| Walsender | 1 per subscriber streaming from this node, plus 1 more per subscriber during table sync | `max_wal_senders` |

Two of these counts are commonly misjudged.

**Managers are launched for every connectable database, not just the ones
using Spock.** The supervisor cannot determine whether a database contains a
Spock node without connecting to it, and a background worker cannot switch
databases. So it launches a manager for every database in `pg_database` with
`datallowconn = true`; managers that find no Spock node exit immediately.
On a default cluster that means `postgres` and `template1` each get a
short-lived manager in addition to your replicated database. `template0` is
excluded because it does not allow connections.

**Walsenders are not background workers.** They are governed by
`max_wal_senders` and counted separately in `MaxBackends`. Raising
`max_worker_processes` does nothing for walsender exhaustion, and vice versa.

## Sizing `max_worker_processes`

For one node, at peak:

```
spock_workers = 1    # supervisor
              + 1    # failover-slots worker (PostgreSQL 15-17 only; 0 on 18+)
              + D    # connectable databases in this instance
              + S    # apply workers: one per enabled subscription
              + S    # sync workers: worst case, one per subscription

max_worker_processes = spock_workers
                     + max_parallel_workers        # shared pool - see below
                     + other_extension_workers     # pg_cron, pg_squeeze, ...
                     + 2                           # headroom
```

Where:

- `D` is the number of databases in the instance with `datallowconn = true`,
  including `postgres` and `template1` — **not** just the databases
  participating in replication.
- `S` is the total number of enabled subscriptions across all databases in
  the instance. In a fully-meshed cluster of `N` nodes with a single
  replicated database, `S = N - 1`.

!!! warning

    `max_worker_processes` is a **shared pool**. Parallel query workers
    (`max_parallel_workers`, default `8`), native logical replication workers
    (`max_logical_replication_workers`), and background workers belonging to
    other extensions all draw from the same allocation. A parallel-heavy
    workload can starve replication of worker slots. Autovacuum workers are
    the exception — they have their own `autovacuum_max_workers` allocation.

### Recommended Minimums

Assuming a single replicated database alongside `postgres` and `template1`
(`D = 3`), the default `max_parallel_workers = 8`, and no other worker-using
extensions:

| Cluster | Spock Workers | Total Workers |
|---|---|---|
| 2-node | 6-7 | 20 |
| 3-node | 8-9 | 20 |
| 4-node | 10-11 | 24 |
| 5-node | 12-13 | 24 |
| 8-node | 18-19 | 32 |

The totals are rounded up to leave room for growth; there is no meaningful
cost to over-provisioning `max_worker_processes` beyond a small amount of
shared memory, and the parameter cannot be changed without a restart.

Add to these numbers if your instance hosts more databases, replicates more
than one database, or runs other extensions that register background workers.

## Sizing `max_wal_senders`

Each node needs a walsender for every subscriber that streams from it, plus
one additional walsender per subscriber while that subscriber is
synchronizing tables. Sync workers open their own replication connection
alongside the ongoing apply stream.

```
max_wal_senders = 2 * subscribers_of_this_node
                + physical_standbys
                + 2                              # pg_basebackup, ad-hoc tooling
```

In a fully-meshed cluster of `N` nodes, `subscribers_of_this_node = N - 1`,
so a 5-node mesh needs at least `2 * 4 = 8` walsenders per node before
accounting for physical standbys.

Sync workers also open a second, non-replication connection to run `COPY`,
which draws from `max_connections` rather than `max_wal_senders`.

## Sizing `max_replication_slots` and Replication Origins

Each node holds a logical replication slot for every node subscribing to it,
plus a transient slot for each in-progress table sync. Sync slots are created
as persistent slots (not temporary), so they occupy a slot until the sync
completes and the slot is dropped.

```
max_replication_slots = 2 * subscribers_of_this_node
                      + physical_and_failover_slots
                      + 2                              # headroom
```

Replication *origins* are tracked separately from slots, and where they are
configured depends on your Postgres version:

- **PostgreSQL 15-17**: `max_replication_slots` governs both replication
  slots *and* replication origin states. Size it for the sum: add one origin
  per subscription this node applies (`N - 1` in a full mesh) on top of the
  slot count above.
- **PostgreSQL 18+**: `max_active_replication_origins` governs origin states
  independently. Its default is `10`, which may be insufficient for larger
  clusters. Set it to at least the number of subscriptions plus headroom.

## Worked Example: 3-Node Mesh on PostgreSQL 17

Three nodes, each with a single replicated database `app`, plus the default
`postgres` and `template1` databases. Each node subscribes to the other two,
and each node has one physical standby.

Per node: `D = 3`, `S = 2`, `subscribers_of_this_node = 2`.

```ini
# Background workers:
#   1 supervisor + 1 failover-slots + 3 managers + 2 apply + 2 sync = 9
#   + 8 max_parallel_workers + 2 headroom = 19, rounded up
max_worker_processes = 20

# Walsenders: (2 subscribers x 2) + 1 physical standby + 2 spare = 7
max_wal_senders = 10

# Slots: (2 subscribers x 2) + 1 physical + 2 origins (PG 17) + 2 spare = 9
max_replication_slots = 12

wal_level = logical
shared_preload_libraries = 'spock'
track_commit_timestamp = on
```

## Verifying Your Configuration

List the Spock workers currently running on a node:

```sql
SELECT pid, backend_type, datname
  FROM pg_stat_activity
 WHERE backend_type LIKE 'spock%'
 ORDER BY backend_type;
```

Each Spock worker reports its role and the OIDs it serves in `backend_type` -
for example `spock supervisor`, `spock manager 16384`, and
`spock apply 16384:1`.

Compare the number of background workers in use against the limit:

```sql
SELECT current_setting('max_worker_processes')::int AS worker_limit,
       count(*) AS in_use
  FROM pg_stat_activity
 WHERE backend_type NOT IN (
         'client backend', 'walsender', 'autovacuum launcher',
         'autovacuum worker', 'checkpointer', 'background writer',
         'walwriter', 'walreceiver', 'walsummarizer', 'archiver',
         'startup', 'io worker', 'slotsync worker', 'standalone backend');
```

The exclusion list names the client backends and auxiliary processes that do
not draw on `max_worker_processes`; everything left over does. The list of
auxiliary process types changes between major versions, so check it against
[`pg_stat_activity`](https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-ACTIVITY-VIEW)
for your version.

## Diagnosing Exhaustion

**`worker registration failed, you might want to increase max_worker_processes setting`**

Postgres refused to register a background worker because
`max_worker_processes` is fully allocated. Recompute with the formula above,
remembering that parallel query workers share the pool, and restart.

**`could not register spock worker: all background worker slots are already used`**

Spock's own worker-tracking array — sized to `max_worker_processes` at
startup — has no free entry. A worker that exits cleanly releases its entry
immediately, but a worker that *crashes* leaves its entry reserved for the
same database until that database's manager (or the supervisor) reclaims it.
Repeated worker crashes across many different databases can therefore exhaust
the array while Postgres still reports free worker slots. Check the server log
for the preceding crash and address that; raising `max_worker_processes`
enlarges the array but does not fix the underlying failures.

**Subscription stuck in `initializing`**

Usually `max_replication_slots` or `max_wal_senders` on the *provider*. A
subscription that is initializing needs a slot and walsender for its sync
worker in addition to those already held by its apply stream, which is why a
cluster that replicates fine in steady state can fail to add or resync a
table. See [Troubleshooting](troubleshooting.md).

**Increasing replication lag with idle apply workers**

If `spock.lag_tracker` shows growing lag but apply workers are not running,
check the server log for worker registration failures — the manager retries
registration on a delay, so an exhausted worker pool presents as intermittent
apply rather than a hard stop.
