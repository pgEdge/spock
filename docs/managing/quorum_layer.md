# Consulting a Quorum System

Spock decides on its own, from local catalogs, whether a peer is alive. That
is enough for replication, but not for the decisions that need agreement
between nodes: whether this node is part of a majority, whether it should act
for the cluster, and whether a peer that stopped answering is down or merely
out of reach from here.

The quorum layer lets Spock ask an external system those questions. Spock does
not implement consensus itself, and it does not depend on any one
implementation. Three systems are supported, selected with one setting:

| `spock.quorum_provider` | System | Where it runs |
|---|---|---|
| `none` | nothing is consulted (the default) | |
| `etcd` | an etcd cluster, over its v3 HTTP gateway | separate daemon |
| `pgraft` | the [pgraft](https://github.com/pgElephant/pgraft) extension | inside PostgreSQL |
| `pgbully` | the [pgBully](https://github.com/pgElephant/pgbully) extension | inside PostgreSQL |

With `none`, nothing is consulted and Spock behaves exactly as it did before
the layer existed. Enabling a provider is always a deliberate act.

## What the layer answers

Every answer is three-valued: yes, no, or unknown. Unknown is the honest reply
when the provider is unreachable, slow, or not installed, and Spock treats it
exactly like no. The two are kept apart so that an operator can tell a cluster
that lost quorum from a provider that stopped answering, which call for
different responses during an incident.

Two functions expose what the layer sees. Both take a fresh reading from the
provider when called, and both are restricted to superusers.

`spock.quorum_status()` returns one row:

| Column | Meaning |
|---|---|
| `provider` | the provider in force |
| `has_quorum` | whether this node is inside a quorum; NULL when no answer could be obtained |
| `is_leader` | whether this node should act for the cluster; NULL outside a quorum |
| `leader` | the Spock name of the node that leads, when known |
| `last_consulted` | when the last definite answer was obtained |
| `last_error` | why the last consult failed, or NULL |

`spock.quorum_members()` returns one row per member the layer would act on:
the provider's membership, restricted to nodes present in `spock.node`, with
each member's liveness in the provider's judgement and, where the provider
tracks it, when it was last heard from. It is empty while this node is not in
a quorum, because a node outside a quorum has no trustworthy opinion about who
else is alive.

A node that is removed with `spock.node_drop()` stops counting at once, even
if the quorum system still lists it: an etcd registration lingers until its
lease expires, and a pgraft or pgBully membership entry stays until the
cluster manager itself is reconfigured. Filtering through `spock.node` is what
keeps the layer's view consistent with Spock's.

## The rules every provider obeys

Anything able to influence what Spock does with WAL has to be safe by
construction, so the layer holds every provider to the same rules:

* **Uncertainty means no.** An error, a timeout, or an unreachable provider
  yields the behaviour of having no provider at all.
* **One reading at a time.** Quorum, leadership, the leader's name and the
  membership come from a single request, one etcd transaction or one SQL
  statement, so they describe the same instant.
* **Deadlines.** Every consult is bounded by `spock.quorum_timeout`. A
  provider that overruns it is treated as not answering. etcd gets the
  deadline as an HTTP timeout; the in-database providers get a timer that
  interrupts the query.
* **Off the hot path.** Providers are consulted only from the functions
  above, never from an apply worker, a walsender, or anything a client waits
  on.
* **Nothing is stored.** The provider is asked for judgements, never for
  storage; Spock keeps its durable state in its own catalogs.

## Configuration

All settings are `PGC_SIGHUP`: change them in `postgresql.conf` or with
`ALTER SYSTEM`, then reload. A session cannot change them.

### `spock.quorum_provider`

`none` (the default), `etcd`, `pgraft` or `pgbully`.

### `spock.quorum_timeout`

The deadline for one call to the provider, in milliseconds. The default is
`2000`; the range is `100` to `60000`.

### `spock.quorum_cluster_id`

A prefix identifying this Spock cluster in etcd. Required by the `etcd`
provider and ignored by the others, which are one per cluster by
construction. There is no default, because two clusters sharing one prefix
would each count the other's nodes as its own members.

### `spock.quorum_etcd_endpoints`

A comma-separated list of etcd base URLs, for example
`http://10.0.1.11:2379,http://10.0.1.12:2379`. One endpoint is tried per
call, rotating on failure, so one unreachable etcd member costs one call
rather than every call.

## Setting up each provider

### etcd

```ini
spock.quorum_provider = 'etcd'
spock.quorum_cluster_id = 'orders-prod'
spock.quorum_etcd_endpoints = 'http://10.0.1.11:2379,http://10.0.1.12:2379,http://10.0.1.13:2379'
```

Each Spock node registers itself under `<cluster_id>/nodes/<node_name>` with
a lease, and the node holding `<cluster_id>/leader` leads. Presence under the
prefix is liveness: etcd expires the key of a node that stops renewing, so
the judgement is the cluster's, not that of whichever node is asking. Quorum
is proved by completing a linearizable read, which etcd only answers from
within a majority.

The gateway is spoken to without authentication or TLS. Put a local proxy in
front of an etcd that requires either and point the endpoints at it.

### pgraft

```ini
shared_preload_libraries = 'spock,pgraft'
spock.quorum_provider = 'pgraft'
pgraft.name = 'n1'
pgraft.initial_cluster = 'n1=http://10.0.1.11:7001,n2=http://10.0.1.12:7001,n3=http://10.0.1.13:7001'
```

Give every pgraft member the same name as its Spock node. That name is how
the provider matches a raft member to a node; a member whose name matches no
`spock.node` row is ignored. Quorum follows pgraft's leader: a leader is
elected only from within a majority, and with `CheckQuorum` enabled a leader
that loses contact with a majority steps down within an election timeout.
Liveness is raft's own view of which followers have been heard from, which
only the leader has; a follower reports every member live, the reading that
releases nothing.

### pgBully

```ini
shared_preload_libraries = 'spock,pgbully'
spock.quorum_provider = 'pgbully'
pgbully.node_id = 1
pgbully.nodes = '1: host=10.0.1.11 port=5432 dbname=postgres, 2: host=10.0.1.12 port=5432 dbname=postgres, 3: host=10.0.1.13 port=5432 dbname=postgres'
```

pgBully members are connection strings, and Spock holds one for every node in
`spock.node_interface`. A peer is matched to a node by host and port, as
libpq parses them, so the `pgbully.nodes` entries must reach the same
PostgreSQL instances as Spock's own node interfaces. pgBully reports whether
each peer is reachable and when it was last heard from; the provider uses
that for liveness, and additionally requires a majority of peers to be
reachable before reporting quorum, since a leader id alone can outlive a
partition for a short while.

## Reading the status during an incident

```sql
SELECT * FROM spock.quorum_status();
SELECT * FROM spock.quorum_members();
```

| What you see | What it means |
|---|---|
| `has_quorum` is NULL and `last_error` is set | the provider could not be consulted; the error says why |
| `has_quorum` is false and `last_error` is NULL | the provider answered: this node is not in a majority |
| `has_quorum` is true, a member is not live | the cluster, not just this node, considers that member down |
| `is_leader` is NULL while `has_quorum` is true | the provider could not say who leads |

A provider that fails to start, because the extension is not installed or
`spock.quorum_cluster_id` is unset for etcd, is retried on the next consult
once the cause is fixed. Nothing needs restarting.

## What is not built yet

The layer reports; nothing in Spock acts on it yet. The intended first
consumer is group slot eviction: releasing the WAL a member that the cluster
considers down would still need, after a long and explicit grace period, so
that one unreachable node cannot pin WAL on every survivor indefinitely.
That lives behind its own setting, off by default, on a separate branch.
