# Tutorial: Updating the Postgres Version with a Rolling Update

Zodan's `add_node` and `remove_node` procedures move data between nodes
regardless of which PostgreSQL major version each node runs. Because
of this, the same node-replacement strategy used to roll a Spock
version forward also upgrades PostgreSQL itself. During the upgrade,
you:

- build a replacement node on the target PostgreSQL major version.
- add it to the cluster.
- confirm it is replicating.
- remove the node it replaces.

Since the replacement node is fully live and replicating before the
node it replaces is removed, the cluster never drops below its
optimal node count and the application sees no interruption - a true
zero-downtime rolling upgrade of the PostgreSQL version. When a node also carries a physical standby
for high availability, bootstrapping that standby and bringing it
under Patroni folds into the same per-node loop, so high availability
is preserved, before you move on to the next node.

In this tutorial, a three-node cluster running PostgreSQL 16 (`n1`,
`n2`, `n3`) rolls forward to PostgreSQL 18, becoming `n1b`, `n2b`, and
`n3b` in turn. If you are also moving to a newer Spock version in the
same rollout, the two upgrades combine in a single pass of
add/verify/remove per node.

!!! Warning

    Important Prerequisites and Warnings

    - Each replacement node should not be accessible to users while it
      is being added.
    - Disable `auto_ddl` on every node, and do not run DDL on the
      cluster for the duration of the rollout.
    - The users must be identical on the source and the replacement
      node. Create any users on the replacement node before
      proceeding; permissions must be identical for all users on both
      the source and the replacement node.
    - Zodan validates that all users from the source node exist on the
      replacement node before proceeding. This prevents replication
      failures caused by missing user permissions.
    - All nodes in the cluster must be available to Spock for the
      duration of each add/remove step.
    - Run each `add_node` and `remove_node` call from the node being
      added or removed.
    - The `dblink` extension must be installed on the node from which
      `add_node` or `remove_node` is called.
    - `output_plugin_libraries` must list `spock_output` on every
      node, on the minimum patch versions described in [Checking
      PostgreSQL Version Compatibility Before Each
      Step](#checking-postgresql-version-compatibility-before-each-step)
      below; a node missing this cannot create a replication slot.
    - If a step fails partway, do not immediately retry. Confirm every
      artifact the workflow created has been removed first, as
      described in [Troubleshooting](#troubleshooting) below.
    - `add_node` allows 180 seconds for each wait for a sync event
      between nodes. If replication lag exceeds this window, the call
      raises an exception. Confirm network latency and replication lag
      are within acceptable limits before starting, or raise the
      budget for the session with
      [`spock.sync_timeout`](../../configuring.md#spocksync_timeout).
    - Do not remove an old node until its replacement reports
      `replicating` status.
    - Keep at least two nodes running at all times; never remove the
      second-to-last old node and the first new node in the same
      window.
    - A rolling PostgreSQL update can only move a cluster forward.
      Unlike a Spock version mismatch, Zodan does not check PostgreSQL
      version ordering itself - see [Checking PostgreSQL Version
      Compatibility Before Each
      Step](#checking-postgresql-version-compatibility-before-each-step).

## Checking PostgreSQL Version Compatibility Before Each Step

Zodan's `check_spock_version_compatibility` procedure (invoked
automatically by `add_node`) checks only the Spock extension version;
it does not check the PostgreSQL server version. Before adding
a replacement node, you can confirm its PostgreSQL patch version
number yourself against the source node:

```sql
SELECT * FROM dblink(
  'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
  'SHOW server_version_num'
) AS t(source_version int);

SELECT * FROM dblink(
  'host=127.0.0.1 dbname=inventory port=5442 user=pgedge password=1safepassword',
  'SHOW server_version_num'
) AS t(replacement_version int);
```

The replacement node's `server_version_num` must be the same as or
greater than the source node's. The following table describes the
minimum patch version each PostgreSQL major version needs for
`output_plugin_libraries` support, required on every node before you
begin:

| PostgreSQL major version | Minimum patch version |
|---|---|
| 15 | 15.19 |
| 16 | 16.15 |
| 17 | 17.11 |
| 18 | 18.6 |

## Preparing a Replacement Node

Each replacement node needs its own host (or port, on a single host),
data directory, and a PostgreSQL and Spock build at the target
version, prepared before you call `add_node`. Add the pgEdge
repository to the replacement node's host and install pgEdge
Enterprise Postgres and Spock for the target version, as described in
[Installing pgEdge Enterprise
Postgres](../../getting_started.md#install-pgedge-enterprise-postgres-recommended-path).
For PostgreSQL 18 on RHEL, Rocky Linux, or AlmaLinux:

```bash
sudo dnf install -y pgedge-postgres18-server pgedge-postgres18-contrib pgedge-spock18
```

On Ubuntu or Debian:

```bash
sudo apt install -y pgedge-postgres18-server pgedge-postgres18-contrib pgedge-spock18
```

In our example, the replacement node runs on its own port on the same
host as the node it replaces; `n1b` runs on port `5442`. Initialize
its data directory on the target PostgreSQL version:

```bash
initdb -D /path/to/data/n1b --username=postgres
```

Before starting the replacement node for the first time, edit the
`postgresql.conf` file:

- set `shared_preload_libraries` and `output_plugin_libraries`.
- size replication origin tracking for the target version.

!!! hint

    `shared_preload_libraries` only takes effect when the server
    starts, so set it now rather than after `CREATE EXTENSION spock`
    has already run.

PostgreSQL 15 through 17 track replication origins with the
`max_replication_slots` parameter; PostgreSQL 18 and later uses the
`max_active_replication_origins` parameter. Set the parameter to the
number of subscriptions required:

```ini
shared_preload_libraries = 'spock'
output_plugin_libraries = 'pgoutput, test_decoding, spock_output'

# PostgreSQL 18 and later only:
max_active_replication_origins = 10
```

Start Postgres on the replacement node's port, then connect with
`psql` to confirm the settings took effect:

```bash
pg_ctl -D /path/to/data/n1b -o "-p 5442" start
```

```bash
psql -p 5442 -c "SHOW shared_preload_libraries;"
psql -p 5442 -c "SHOW output_plugin_libraries;"
```

Create the database and user, matching the source node exactly:

```bash
psql -p 5442 -c "CREATE DATABASE inventory;"
psql -p 5442 -c "CREATE USER pgedge WITH PASSWORD '1safepassword';"
psql -p 5442 -c "GRANT ALL ON DATABASE inventory TO pgedge;"
```

Install the Spock extension built against the target PostgreSQL
version:

```bash
psql -p 5442 -d inventory -c "CREATE EXTENSION spock;"
psql -p 5442 -d inventory -c "CREATE EXTENSION dblink;"
```

If the node it replaces runs behind a physical standby for high
availability, and the replacement node's target version is PostgreSQL
18 or later, also configure the server's native
`sync_replication_slots` mechanism before adding it to the cluster -
Spock's own failover worker does not run on PostgreSQL 18+. Both
approaches below need a replication role, a known superuser password,
and a `pg_hba.conf` entry permitting both to connect; set these up
once, on the replacement node, before choosing a path:

```bash
psql -p 5442 -c \
  "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replpassword';"
psql -p 5442 -c "ALTER ROLE postgres WITH PASSWORD 'superpassword';"
```

Add entries to `/path/to/data/n1b/pg_hba.conf` permitting the standby
host to open a replication connection and, if you choose the Patroni
path below, a superuser connection for Patroni's own health checks:

```
host replication replicator 127.0.0.1/32 md5
host all          postgres   127.0.0.1/32 md5
```

```bash
psql -p 5442 -c "SELECT pg_reload_conf();"
```

Choose one of the following approaches:

- Manage the standby pair through Patroni, as described in step 3 of
  [Rolling the Update Across the
  Cluster](#rolling-the-update-across-the-cluster) below.
- Configure the native path by hand:

    1. Create a physical replication slot on the replacement node, for
       its future standby to stream through:

        ```sql
        SELECT pg_create_physical_replication_slot('n1b_standby_slot');
        ```

    2. Take a base backup of the replacement node into the standby's
       data directory, streaming through that slot:

        ```bash
        pg_basebackup -h 127.0.0.1 -p 5442 -U replicator \
          -D /path/to/data/n1b_standby -S n1b_standby_slot -X stream -P
        ```

    3. Set `synchronized_standby_slots` in the replacement node's
       `postgresql.conf`, naming that slot:

        ```ini
        synchronized_standby_slots = 'n1b_standby_slot'
        ```

    4. On the standby itself, point it at the replacement node and
       enable native slot sync in its `postgresql.conf`:

        ```ini
        sync_replication_slots = on
        primary_conninfo = 'host=127.0.0.1 port=5442 dbname=inventory user=replicator'
        primary_slot_name = 'n1b_standby_slot'
        hot_standby_feedback = on
        ```

    5. After starting the standby, confirm the slot synchronized:

        ```sql
        SELECT slot_name, synced, failover, invalidation_reason
        FROM pg_replication_slots
        WHERE NOT temporary;
        ```

See [Logical Slot Failover (HA Standby)](../../logical_slot_failover.md)
for the full reference, including the PostgreSQL 15/16 path and
upgrading existing slots.

## Rolling the Update Across the Cluster

Repeat the following four steps once per node, moving from `n1` to
`n3` in our example. Finish all steps for one node before starting the
next.

1. Connect to the prepared replacement node and load the Zodan
   workflow:

    ```sql
    \i /path/to/zodan.sql
    ```

    !!! hint

        Both `zodan.sql` and `zodremove.sql` are located in the
        [samples/Z0DAN](https://github.com/pgEdge/spock/tree/main/samples/Z0DAN)
        directory of the [Spock GitHub](https://github.com/pgEdge/spock)
        repository.

    Then add the replacement node, sourcing it from whichever node in
    the cluster is reachable and already caught up - the node you are
    replacing is the simplest choice for the first replacement:

    ```sql
    CALL spock.add_node(
        src_node_name := 'n1',
        src_dsn := 'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
        new_node_name := 'n1b',
        new_node_dsn := 'host=127.0.0.1 dbname=inventory port=5442 user=pgedge password=1safepassword',
        verb := true,
        new_node_location := 'Los Angeles',
        new_node_country := 'USA',
        new_node_info := '{"role": "n1-replacement", "pg_version": "18"}'::jsonb
    );
    ```

2. Confirm the replacement node is fully caught up and replicating in
   both directions before touching the node it replaces:

    ```sql
    CALL spock.show_all_subscription_status(
      'host=127.0.0.1 dbname=inventory port=5442 user=pgedge password=1safepassword',
      true
    );
    ```

    Every subscription involving `n1b` should report `replicating`,
    including the subscriptions to and from `n2` and `n3` that
    `add_node` created automatically.

3. If the node being retired runs behind a physical standby for high
   availability, build a matching standby for `n1b` and bring the pair
   under Patroni, then cut over to it. Skip this step if the cluster
   does not use physical standbys.

    Patroni and a DCS (Distributed Configuration Store) must be
    installed and reachable from `n1b` and its future standby host
    before either node can run under Patroni. This tutorial uses
    `etcd` as the DCS, the most common choice for Patroni. Install
    Patroni on both hosts:

    ```bash
    pip install patroni[etcd]
    ```

    This installs Patroni's etcd client library, not the etcd server
    itself. If no etcd cluster already serves the rest of your Spock
    cluster's Patroni pairs, install and start one. Package name and
    installation method vary by platform; see the [etcd releases
    page](https://github.com/etcd-io/etcd/releases) if your package
    manager does not provide one. A production etcd deployment needs
    an odd number of members (3 or 5) for quorum; the following
    configures a single-member etcd suitable for this tutorial:

    ```yaml
    # /etc/etcd/etcd.yml
    name: etcd0
    data-dir: /path/to/data/etcd0
    listen-client-urls: http://127.0.0.1:2379
    advertise-client-urls: http://127.0.0.1:2379
    listen-peer-urls: http://127.0.0.1:2380
    initial-advertise-peer-urls: http://127.0.0.1:2380
    initial-cluster: etcd0=http://127.0.0.1:2380
    initial-cluster-token: n1b-etcd
    initial-cluster-state: new
    ```

    ```bash
    etcd --config-file /etc/etcd/etcd.yml
    ```

    Confirm `n1b` and its standby host can reach the DCS before
    continuing:

    ```bash
    etcdctl --endpoints=127.0.0.1:2379 endpoint health
    ```

    Bring `n1b` under Patroni as the leader of a new Patroni cluster,
    rather than letting Patroni bootstrap it from scratch - `n1b` is
    already initialized and already running with the data `add_node`
    populated. Patroni only runs its bootstrap process against an
    empty `data_dir`, so pointing it at `n1b`'s existing, populated
    directory makes Patroni adopt the running instance as the
    cluster's first member instead:

    ```yaml
    scope: n1b-cluster
    namespace: /service/
    name: n1b

    restapi:
      listen: 127.0.0.1:8541
      connect_address: 127.0.0.1:8541

    etcd3:
      hosts: 127.0.0.1:2379

    postgresql:
      listen: 127.0.0.1:5442
      connect_address: 127.0.0.1:5442
      data_dir: /path/to/data/n1b
      bin_dir: /usr/pgsql-18/bin
      parameters:
        sync_replication_slots: on
        hot_standby_feedback: on
      authentication:
        replication:
          username: replicator
          password: replpassword
        superuser:
          username: postgres
          password: superpassword
    ```

    `sync_replication_slots` and `hot_standby_feedback` are the two
    settings the native slot sync path needs on a standby; set them on
    both `n1b` and `n1b_standby` rather than only on whichever is the
    standby today, since either one can end up in that role after a
    promotion. `synchronized_standby_slots` is deliberately left out of
    `postgresql.parameters` here - it is set directly on whichever node
    is primary, by the `on_role_change` callback below, and declaring
    it as a static Patroni-managed parameter would fight that callback:
    Patroni reconciles managed parameters back to the value in its own
    configuration, which would undo the callback's update after every
    promotion.

    Start Patroni against the running instance:

    ```bash
    patroni /path/to/n1b_patroni.yml
    ```

    Then point a second Patroni instance at the same `scope` and DCS
    endpoint, under the member name `n1b_standby`, with an empty
    `data_dir`. Patroni finds the existing cluster in the DCS and, on
    first start, runs `pg_basebackup` itself against `n1b` to populate
    that empty directory - connecting as the `replicator` role over
    the replication connection permitted by the `pg_hba.conf` entry
    added above, using the credentials in the `authentication.replication`
    block below. No manual `pg_basebackup` step is needed on this path;
    Patroni's bootstrap process runs it for you:

    ```yaml
    scope: n1b-cluster
    namespace: /service/
    name: n1b_standby

    restapi:
      listen: 127.0.0.1:8542
      connect_address: 127.0.0.1:8542

    etcd3:
      hosts: 127.0.0.1:2379

    postgresql:
      listen: 127.0.0.1:5452
      connect_address: 127.0.0.1:5452
      data_dir: /path/to/data/n1b_standby
      bin_dir: /usr/pgsql-18/bin
      parameters:
        sync_replication_slots: on
        hot_standby_feedback: on
      authentication:
        replication:
          username: replicator
          password: replpassword
        superuser:
          username: postgres
          password: superpassword
    ```

    ```bash
    patroni /path/to/n1b_standby_patroni.yml
    ```

    Confirm `n1b_standby` joined and is streaming before moving on:

    ```bash
    patronictl -c /path/to/n1b_patroni.yml list n1b-cluster
    ```

    Also confirm, on `n1b`, that the slot backing the standby has
    synced before relying on it for failover:

    ```sql
    SELECT slot_name, synced, failover, invalidation_reason
    FROM pg_replication_slots
    WHERE NOT temporary;
    ```

    `synchronized_standby_slots` names a Patroni-managed physical
    slot, and Patroni's auto-created slots are named after the member,
    not the role - the slot named `n1b_standby` only exists while
    `n1b_standby` is not the primary. Add an `on_role_change` callback
    to both nodes' Patroni configuration so a future promotion resets
    the setting to name whichever member is then the standby:

    ```yaml
    postgresql:
      callbacks:
        on_role_change: /path/to/set_synchronized_standby_slots.sh
    ```

    The following script, deployed on `n1b` with `SIBLING_MEMBER` set
    to `n1b_standby` and `LOCAL_PORT` set to `5442` (and on
    `n1b_standby` with them set to `n1b` and `5452`), sets
    `synchronized_standby_slots` to the other member's name whenever
    this node becomes the primary:

    ```bash
    #!/bin/bash
    # Patroni on_role_change callback.
    # Patroni invokes this script as:
    #   <script> <action> <role> <scope>
    # so the role is $2, not $1.
    # Resets synchronized_standby_slots to the sibling member's name
    # whenever Patroni promotes this node to primary.
    ROLE="$2"
    SIBLING_MEMBER="n1b_standby"
    LOCAL_PORT="5442"

    if [ "$ROLE" = "master" ] || [ "$ROLE" = "primary" ]; then
      psql -p "${LOCAL_PORT}" -U postgres -c \
        "ALTER SYSTEM SET synchronized_standby_slots = '${SIBLING_MEMBER}';"
      psql -p "${LOCAL_PORT}" -U postgres -c "SELECT pg_reload_conf();"
    fi
    ```

    The callback only fires on a future promotion, so set the initial
    value by hand now, on `n1b` while it is still the leader:

    ```bash
    psql -p 5442 -U postgres -c \
      "ALTER SYSTEM SET synchronized_standby_slots = 'n1b_standby';"
    psql -p 5442 -U postgres -c "SELECT pg_reload_conf();"
    ```

    With `n1b_standby` streaming and the callback in place on both
    nodes, cut over: repoint anything that depended on the old node's
    standby - a VIP, a DNS record, or a connection string used for
    read traffic or disaster recovery - at the new Patroni cluster.
    Leave the old node's standby running until the cutover is
    confirmed; step 4 removes the old primary, and its standby can be
    stopped once the rest of the cluster is healthy.

    A later promotion of `n1b_standby` is a separate event from this
    cutover, and needs its own plan: Spock's subscriptions on `n2` and
    `n3` connect to `n1b` using the raw `host=127.0.0.1 port=5442`
    address from the `add_node` call above, and Patroni does not
    repoint that address for them. If `n1b` is reachable only through a
    VIP or DNS record that Patroni (or `keepalived` alongside it) moves
    to whichever member is primary, point `new_node_dsn` at that stable
    address instead of a node's raw host and port when you call
    `add_node`, and no further Spock-level action is needed after a
    promotion. Without such an abstraction in front of the pair, repoint
    each subscription by hand after a promotion, from any node whose
    subscription still points at the old address:

    `node_add_interface` writes to the node catalog, which replicates
    to the rest of the mesh like any other table, so run it once,
    connected directly to any single reachable node (`n2` or `n3`, not
    `n1b` itself if it is down):

    ```sql
    SELECT spock.node_add_interface('n1b', 'n1b_standby_interface',
      'host=127.0.0.1 dbname=inventory port=5452 user=pgedge password=1safepassword');
    ```

    Subscriptions are not replicated between nodes, so run
    `sub_alter_interface` locally on each node whose subscription has
    `n1b` as its provider - on this pair, that is `n2` and `n3`:

    ```sql
    SELECT spock.sub_alter_interface('sub_n1b_n2', 'n1b_standby_interface');
    ```

    `spock.gen_sub_name(provider_node, subscriber_node)` names each
    subscription, so `sub_n1b_n2` is the subscription on `n2` whose
    provider is `n1b`; confirm the exact names for your cluster with
    `SELECT sub_name FROM spock.subscription;` on each node before
    repointing them.

4. Load the removal workflow on the node being retired, and remove it
   from the cluster:

    ```sql
    \i /path/to/zodremove.sql
    ```

    ```sql
    CALL spock.remove_node(
      'n1',
      'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
      true
    );
    ```

    `remove_node` does not delete the retired node's database, data
    directory, or logs; stop the instance and reclaim its resources
    once you confirm the rest of the cluster is healthy.

With `n1` replaced by `n1b`, repeat steps 1 through 4 for `n2` and
`n3`, sourcing each new node from any node already in the cluster -
old or new - that runs a PostgreSQL version no newer than the
replacement node itself.

## Verifying the Rollout

After replacing each node, confirm the whole cluster runs the
target PostgreSQL version and reports a clean replication topology:

```sql
SELECT * FROM dblink(
  'host=127.0.0.1 dbname=inventory port=5442 user=pgedge password=1safepassword',
  'SHOW server_version'
) AS t(pg_version text);

CALL spock.show_all_nodes(
  'host=127.0.0.1 dbname=inventory port=5442 user=pgedge password=1safepassword',
  true
);
```

The following table describes what to check in the output before
considering the rollout complete:

| Field | What to confirm |
|---|---|
| PostgreSQL version | Every node reports the target version. |
| Node name | Only `n1b`, `n2b`, and `n3b` remain; no old node is listed. |
| Subscription status | Every subscription between every pair of nodes reports `replicating`. |

## Troubleshooting

- **A replacement node's replication worker crashes with `cannot
  synchronize structure from upstream server version`.** The
  replacement node's `pg_dump` cannot dump from a PostgreSQL version
  newer than itself. The node named as the source runs a newer
  PostgreSQL major version than the replacement node. Rebuild the
  replacement node on an equal or newer PostgreSQL major version, or
  source it from a different node that is not newer than the
  replacement, and retry.

- **A replacement node fails to create its replication slot.** The
  replacement node's `output_plugin_libraries` does not list
  `spock_output`, or its PostgreSQL build is older than the minimum
  patch version listed in [Checking PostgreSQL Version Compatibility
  Before Each
  Step](#checking-postgresql-version-compatibility-before-each-step).
  Correct `postgresql.conf` and restart the replacement node before
  retrying.

- **`add_node` times out waiting for a sync event on a large
  database.** Raise the wait budget for the session with
  [`spock.sync_timeout`](../../configuring.md#spocksync_timeout)
  before calling `add_node` again.

- **A step fails partway through `add_node`.** Do not retry
  immediately. Source `zodremove.sql` and call `spock.remove_node()`
  on the partially added node first, to clear any subscriptions and
  slots it created, then retry the add.

For more information, review the following resources:

- [Modifying a Cluster with Zodan](index.md)
- [Using Zodan Scripts and Workflows](zodan_readme.md)
- [Tutorial: Adding a Node to a Cluster with Zero Downtime](zodan_tutorial.md)
- [Logical Slot Failover (HA Standby)](../../logical_slot_failover.md)
