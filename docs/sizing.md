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
| Walsender | 1 per subscription streaming from this node, plus 1 more per subscription during table sync | `max_wal_senders` |

Three of these counts are commonly misjudged.

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

**Subscriptions are per database, not per node.** A Spock node is created
inside a single database, and each subscription connects one database on this
instance to the corresponding database on one other instance. An instance that
replicates several databases therefore hosts one Spock node per replicated
database, and each of those nodes carries its own full set of subscriptions.
Everything downstream of the subscription count — apply workers, sync workers,
walsenders, slots, and origins — scales with **node count multiplied by
replicated database count**, not node count alone.

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

- `N` is the number of Spock nodes in the cluster.
- `D` is the number of databases in the instance with `datallowconn = true`,
  including `postgres` and `template1` — **not** just the databases
  participating in replication.
- `R` is the number of databases in this instance that actually participate
  in Spock replication (`R <= D`). It is `1` in most deployments.
- `S` is the total number of enabled subscriptions across all databases in
  the instance. In a fully-meshed cluster of `N` nodes each replicating the
  same `R` databases, `S = R * (N - 1)`. With a single replicated database
  that reduces to the familiar `S = N - 1`.

!!! warning

    `max_worker_processes` is a **shared pool**. Parallel query workers
    (`max_parallel_workers`, default `8`), native logical replication workers
    (`max_logical_replication_workers`), and background workers belonging to
    other extensions all draw from the same allocation. A parallel-heavy
    workload can starve replication of worker slots. Autovacuum workers are
    the exception — they have their own `autovacuum_max_workers` allocation.

### Recommended Minimums

Assuming a single replicated database alongside `postgres` and `template1`
(`D = 3`, `R = 1`), the default `max_parallel_workers = 8`, and no other
worker-using extensions:

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
Each **additional replicated database** costs `1` manager (if the database is
not already counted in `D`) plus `2 * (N - 1)` workers for its apply and sync
workers, so a 3-node cluster replicating three databases needs `3 * 2 * 2 = 12`
apply and sync workers per instance rather than `4`.

## Sizing `max_wal_senders`

Each node needs a walsender for every subscription that streams from it, plus
one additional walsender per subscription while that subscriber is
synchronizing tables. Sync workers open their own replication connection
alongside the ongoing apply stream. Because subscriptions are per database, an
instance replicating several databases serves one set of walsenders per
replicated database.

```
max_wal_senders = 2 * subscriptions_served     # apply stream + sync stream
                + physical_standbys
                + 2                            # pg_basebackup, ad-hoc tooling
```

In a fully-meshed cluster of `N` nodes each replicating `R` databases,
`subscriptions_served = R * (N - 1)`, giving:

```
max_wal_senders = 2 * R * (N - 1)
                + physical_standbys
                + 2
```

A 5-node mesh with one replicated database needs at least `2 * 1 * 4 = 8`
walsenders per node; the same mesh replicating three databases needs
`2 * 3 * 4 = 24`, before accounting for physical standbys in either case.

Sync workers also open a second, non-replication connection to run `COPY`,
which draws from `max_connections` rather than `max_wal_senders`.

## Sizing `max_replication_slots` and Replication Origins

Each node holds a logical replication slot for every database subscription,
plus a transient slot for each in-progress table sync. Sync slots are created
as persistent slots (not temporary), so they occupy a slot until the sync
completes and the slot is dropped.

Consider this formula for determining the max slot count, where `N` is the
number of Spock nodes and `R` the number of synchronized databases:

    max_replication_slots = 2 * R * (N - 1)
                          + physical_and_failover_slots
                          + 2  # headroom

The number of synced databases in a Spock cluster is 1 in most cases.

Postgres uses *origins* to track local state for remote replication slots.
Internally, Postgres tracks replication origins separately from slots and
pins their count to `max_replication_slots` in Postgres versions 15-17. Our
formula should make it impossible for there to be more origins than slots in
those versions of Postgres.

However, Postgres 18 introduces `max_active_replication_origins` with a
default value of 10, which may be too low for an active Spock cluster. For
the sake of simplicity, we encourage using this simple formula for that
parameter:

    max_active_replication_origins = max_replication_slots

This should cause Postgres 18+ to operate with a sufficiently large origin
pool.

## Worked Example: 3-Node Mesh on PostgreSQL 17

Three nodes, each with a single replicated database `app`, plus the default
`postgres` and `template1` databases. Each node subscribes to the other two,
and each node has one physical standby.

Per node: `D = 3`, `R = 1`, `S = R * (N - 1) = 2`.

```ini
# Background workers:
#   1 supervisor + 1 failover-slots + 3 managers + 2 apply + 2 sync = 9
#   + 8 max_parallel_workers + 2 headroom = 19, rounded up
max_worker_processes = 20

# Walsenders: (2 subscriptions x 2) + 1 physical standby + 2 spare = 7
max_wal_senders = 10

# Slots: 2 x 1 database x 2 subscribers + 1 physical + 2 headroom = 7
max_replication_slots = 12

wal_level = logical
shared_preload_libraries = 'spock'
track_commit_timestamp = on
```

If each of those three instances replicated **two** databases instead of one,
the same topology would need `D = 4`, `R = 2`, and `S = 4`. Per node that is 14
Spock workers at peak (1 supervisor + 1 failover-slots + 4 managers + 4 apply +
4 sync), `2 * 2 * 2 = 8` subscription walsenders, and `2 * 2 * 2 = 8`
subscription slots - so `max_worker_processes = 26`, `max_wal_senders = 12`,
and `max_replication_slots = 12` once the standby and headroom are included.

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
