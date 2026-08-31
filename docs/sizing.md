# Sizing Postgres Resources for Spock

Spock replication consumes three separate, independently-configured Postgres
resources: background worker slots, walsender slots, and replication
slots/origins. Each is governed by a different parameter, and each is sized
from a different property of your cluster.

Many of the values shown in the tutorials are a starting point for a small
test cluster, not a recommendation for production. This page explains what
Spock actually launches so you can size each parameter deliberately.

!!! warning

    Every parameter on this page backed by an explicit recommendation requires
    a **server restart** to change. Under-sizing them is not a soft failure:
    Spock raises an `ERROR` when a worker cannot be registered and the
    supervisor retries in a loop, so replication does not start at all. Formulas
    include a small amount of headroom partially to prevent this.

## What Spock Runs on Each Node

| Process | How many | Counts against |
|---|---|---|
| Supervisor | 1 per instance, always running | `max_worker_processes` |
| Slot sync worker | 1 per instance | `max_worker_processes` |
| Manager | 1 per **connectable database** in the instance | `max_worker_processes` |
| Apply worker | 1 per enabled subscription | `max_worker_processes` |
| Table sync worker | at most 1 concurrently per subscription | `max_worker_processes` |
| Walsender | 1 per subscription streaming from this node, plus 1 more per subscription during table sync | `max_wal_senders` |

Four of these counts are commonly misjudged.

**A slot sync worker exists on every node, not just standbys.** These workers
copy logical replication slots to each physical standby so that failovers do
not force a full resync of every subscriber. These workers remain idle on
primary nodes but still consume a worker slot, so are included in the formula.
See [Slot Synchronization](#slot-synchronization) below for more information.

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
Everything downstream of the subscription count such as apply workers, table
sync workers, walsenders, slots, and origins, all scale with **node count
multiplied by replicated database count**, not node count alone.

### Slot Synchronization

Slot synchronization is not optional for a cluster with a physical standby: a
promotion without it forces every subscriber to recreate its slot and re-sync
its tables. What changes between PostgreSQL versions is only *who supplies the
worker*.

| PostgreSQL | Supplied by | Charged to `max_worker_processes` |
|---|---|---|
| 15, 16 | Spock's `spock_failover_slots` background worker | Yes |
| 17 | Either, depending on `sync_replication_slots` | Yes - Spock registers its worker regardless, and it stands down when the native one is enabled |
| 18+ | PostgreSQL's native slotsync worker | No - it is a dedicated postmaster process, counted separately in `MaxBackends` |

Budget a worker for it on every node and every version. Where PostgreSQL
supplies the worker the budgeted slot simply becomes headroom, which costs
nothing beyond a little shared memory and spares you a version-dependent
formula. [Logical Slot Failover](logical_slot_failover.md) covers the
configuration each mechanism needs.

## Sizing `max_worker_processes`

For one node, at peak:

    spock_workers = 1    # supervisor
                  + 1    # slot sync worker
                  + D    # connectable databases in this instance
                  + S    # apply workers: one per enabled subscription
                  + S    # table sync workers: worst case, one per subscription

    max_worker_processes = spock_workers
                         + max_parallel_workers        # shared pool - see below
                         + other_extension_workers     # pg_cron, pg_squeeze, ...
                         + 2                           # headroom

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
| 2-node | 7 | 20 |
| 3-node | 9 | 20 |
| 4-node | 11 | 24 |
| 5-node | 13 | 24 |
| 8-node | 19 | 32 |

The totals are rounded up to leave room for growth; there is no meaningful
cost to over-provisioning `max_worker_processes` beyond a small amount of
shared memory, and the parameter cannot be changed without a restart.

Add to these numbers if your instance hosts more databases, replicates more
than one database, or runs other extensions that register background workers.
Each **additional replicated database** costs `1` manager (if the database is
not already counted in `D`) plus `2 * (N - 1)` workers for its apply and sync
workers, so a 3-node cluster replicating three databases needs `3 * 2 * 2 = 12`
apply and sync workers per instance rather than `4`.

## Sizing `max_replication_slots` and `max_wal_senders`

Each node holds a logical replication slot for every subscription that streams
from it, plus a transient slot for each in-progress table sync. Sync slots are
created as persistent slots (not temporary), so each one occupies a slot until
the sync finishes and the slot is dropped. Every one of those slots has a
walsender behind it while it is streaming, so **set both parameters to the same
value** and compute it once, from the slot count.

!!! note "Default values"

    The default is 10 for `max_replication_slots` and `max_wal_senders`. Consider
    this a minimum value for each. If any formulas provide a value below 10,
    simply retain the default value.

Where `N` is the number of Spock nodes and `R` the number of replicated
databases in the instance:

    max_replication_slots = 2 * R * (N - 1)   # apply slot + sync slot per subscription
                          + physical_and_failover_slots
                          + 2                 # headroom for pg_basebackup and ad-hoc tooling

    max_wal_senders = max_replication_slots

`R` is 1 in most deployments. A 5-node mesh replicating a single database, with
one physical standby per node, needs `2 * 1 * 4 + 1 + 2 = 11` for both
parameters; the same mesh replicating three databases needs
`2 * 3 * 4 + 1 + 2 = 27`.

!!! note "Why the two values are equal"

    PostgreSQL's logical replication documentation recommends setting
    `max_wal_senders` to at least `max_replication_slots` plus the number of
    physical replicas connected at the same time. That extra term covers
    physical standbys that stream without a slot; the formula above already
    gives each physical standby a slot in `physical_and_failover_slots`, so
    adding them a second time would double-count. Sizing every node from the
    same formula, standbys included, also satisfies the separate rule that a
    standby's `max_wal_senders` be at least as high as its primary's.

Not every replication connection is a walsender. Table sync workers open a
second, non-replication connection to run `COPY`, which draws from
`max_connections`. The slot sync worker on a standby likewise reaches the
primary over an ordinary connection. Both Spock's worker and PostgreSQL's
native one cost the primary a `max_connections` slot, not a walsender.

## Replication Origins

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

## Worked Examples

Because these settings require so many inputs, this documentation provides
some examples.

### 3-Node Mesh

Three nodes, each with a single replicated database `app`, plus the default
`postgres` and `template1` databases. Each node subscribes to the other two,
and each node has one physical standby.

Per node: `D = 3`, `R = 1`, `S = R * (N - 1) = 2`.

```ini
# Background workers:
#   1 supervisor + 1 slot sync + 3 managers + 2 apply + 2 table sync = 9
#   + 8 max_parallel_workers + 2 headroom = 19; 20 to match the table above
max_worker_processes = 20

# Slots and walsenders, set equal:
#   (2 x 1 database x 2 subscribers) + 1 physical standby + 2 headroom = 7;
#   This is lower than the default of 10, so do not reduce.
max_replication_slots = 10
max_wal_senders = 10
```

### 5-Node Mesh

Five nodes, each with replicated databases `app` and `ledger`, plus the default
`postgres` and `template1` databases. Each node subscribes to the other four,
and each node has two physical standbys, common in clusters leveraging safe
synchronous replication.

Per node: `D = 4`, `R = 2`, `S = R * (N - 1) = 8`.

```ini
# Background workers:
#   1 supervisor + 1 slot sync + 4 managers + 8 apply + 8 table sync = 22
#   + 8 max_parallel_workers + 2 headroom = 32
max_worker_processes = 32

# Slots and walsenders, set equal:
#   (2 x 2 databases x 4 subscribers) + 2 standbys + 2 headroom = 20
max_replication_slots = 20
max_wal_senders = 20
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
         'startup', 'io worker', 'standalone backend');
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
