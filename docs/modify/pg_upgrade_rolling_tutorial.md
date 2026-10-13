# Tutorial: Upgrading the Postgres Version In Place with pg_upgrade

If your database is too large for your system's free storage to hold
a second full copy, you can upgrade the node's existing data directory
in place with `pg_upgrade`.

`pg_upgrade` migrates a node's existing data directory to a new
PostgreSQL major version in place. Run with `--link`, it hard-links
the new cluster's files to the old cluster's rather than copying them.
This avoids doubling storage: the new data directory shares disk
blocks with the old one instead of duplicating them.

The trade-off is downtime for that one node. Unlike the rolling
replacement strategy, there is no freshly built node standing by to
take over its traffic while it upgrades - the node goes down, runs
`pg_upgrade`, and comes back up on the new version before it rejoins
the cluster. The upgrade is zero-downtime for the application only
because the other nodes in the cluster keep serving traffic during
that window; it is not zero-downtime for the node itself.

This tutorial upgrades a three-node cluster (`n1`, `n2`, `n3`) running
PostgreSQL 16 to PostgreSQL 18, one node at a time, without a second
data directory for any node. When a node also carries a physical
standby for high availability, rebuilding that standby and bringing
it under Patroni folds into the same per-node loop, so high
availability is preserved before you move on to the next node.

## Prerequisites and Warnings

!!! Warning

    Important Prerequisites and Warnings

    - The cluster needs at least three nodes. With one node down for
      its upgrade, at least two others must remain available to serve
      the application.
    - Your load balancer, connection pooler, or application must be
      able to stop routing traffic to a node before it goes down for
      upgrade, and resume routing to it afterward. There is no
      replacement node to absorb that traffic automatically.
    - Disable `auto_ddl` on every node, and do not run DDL on the
      cluster for the duration of the rollout.
    - `pg_upgrade --link` requires the old and new data directories to
      be on the same filesystem, so that hard links are possible. A
      filesystem that does not support hard links, or old and new data
      directories on separate volumes, falls back to a full copy and
      loses the storage savings.
    - `--link` mode ties the old and new clusters' data files
      together. Once you start the new cluster, you cannot go back to
      running the old one; treat the old `postgresql.conf`,
      `pg_hba.conf`, and any other node-specific configuration as
      reference material to port forward, not something you can
      revert to.
    - `pg_upgrade` only carries a node's logical replication slots
      forward when the node's current version is PostgreSQL 17 or
      later. Upgrading from PostgreSQL 15 or 16, the slots are not
      preserved, and every other node's subscription to this node
      needs a full resync after the upgrade - see step 20 below.
    - Run `pg_upgrade --check` against the node before running the
      real upgrade, and resolve everything it reports.
    - A node's physical standby cannot continue streaming once the
      node's major version changes; the standby must be rebuilt from
      the upgraded node, not upgraded in place alongside it.

## Upgrading the Cluster with pg_upgrade

Repeat the following steps once per node, moving from `n1` to `n3` in
our example. Finish all steps for one node before starting the next.

1. Drain traffic from the node being upgraded at the load balancer,
   pooler, or application layer, and confirm no new connections are
   arriving at it.

2. Confirm the node has no unreplicated work in either direction:

    ```sql
    CALL spock.show_all_subscription_status(
      'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
      true
    );
    ```

    Every subscription to and from `n1` should report `replicating`,
    with no significant lag, before you continue.

3. If this node already runs under Patroni, pause it first so that
   manually stopping PostgreSQL below does not trigger an automatic
   restart - Patroni's own documentation names major-version upgrades
   as the intended use case for this mode:

    ```bash
    patronictl -c /path/to/n1_patroni.yml pause n1-cluster
    ```

    Then stop PostgreSQL on the node:

    ```bash
    pg_ctl -D /path/to/data/n1 stop
    ```

4. Install the target PostgreSQL version and Spock on the host,
   alongside the existing installation; see [Installing pgEdge
   Enterprise Postgres](../getting_started.md#install-pgedge-enterprise-postgres-recommended-path).
   For PostgreSQL 18 on RHEL, Rocky Linux, or AlmaLinux:

    ```bash
    sudo dnf install -y pgedge-postgres18-server pgedge-postgres18-contrib pgedge-spock18
    ```

    On Ubuntu or Debian:

    ```bash
    sudo apt install -y pgedge-postgres18-server pgedge-postgres18-contrib pgedge-spock18
    ```

5. Initialize a new data directory on the target PostgreSQL version.
   `pg_upgrade` migrates data into an already-initialized cluster; it
   does not create one. The new cluster must match the old cluster's
   encoding and checksum setting exactly, or `pg_upgrade --check`
   fails - confirm both first. `pg_controldata` reports checksums, but
   not encoding, which is a per-database setting:

    ```bash
    psql -p 5432 -c "SHOW server_encoding;"
    pg_controldata /path/to/data/n1 | grep "checksum version"
    ```

    Pass the encoding you found to `initdb`, and include
    `--data-checksums` only if the checksum version above is `1`:

    ```bash
    /path/to/pg18/bin/initdb -D /path/to/data/n1_new \
      --encoding=UTF8 --data-checksums
    ```

6. Run `pg_upgrade --check` first, against the target version's
   binaries, to confirm there are no blocking issues:

    ```bash
    pg_upgrade \
      --old-datadir /path/to/data/n1 \
      --new-datadir /path/to/data/n1_new \
      --old-bindir /path/to/pg16/bin \
      --new-bindir /path/to/pg18/bin \
      --check
    ```

    Then run the upgrade itself, adding `--link` to hard-link the
    data files instead of copying them:

    ```bash
    pg_upgrade \
      --old-datadir /path/to/data/n1 \
      --new-datadir /path/to/data/n1_new \
      --old-bindir /path/to/pg16/bin \
      --new-bindir /path/to/pg18/bin \
      --link
    ```

7. `pg_upgrade` does not carry configuration files forward; the new
   data directory has only the defaults `initdb` wrote. Copy
   `pg_hba.conf` as-is, since authentication rules do not change with
   the PostgreSQL version:

    ```bash
    cp /path/to/data/n1/pg_hba.conf /path/to/data/n1_new/pg_hba.conf
    ```

    Then add the Spock-specific settings to the new data directory's
    `postgresql.conf`:

    ```ini
    shared_preload_libraries = 'spock'
    output_plugin_libraries = 'pgoutput, test_decoding, spock_output'

    # PostgreSQL 18 and later only:
    max_active_replication_origins = 10
    ```

    `output_plugin_libraries` requires a minimum patch version of the
    target PostgreSQL major version; confirm the new binaries meet it
    before starting the node. The following table describes the
    minimum patch version each major version needs:

    | PostgreSQL major version | Minimum patch version |
    |---|---|
    | 15 | 15.19 |
    | 16 | 16.15 |
    | 17 | 17.11 |
    | 18 | 18.6 |

8. Start PostgreSQL on the new version:

    ```bash
    pg_ctl -D /path/to/data/n1_new -o "-p 5432" start
    ```

9. If this node runs behind a physical standby for high availability,
   stop it now - physical replication cannot continue once the
   primary's major version changes. Skip steps 9 through 11 if the
   node does not use a physical standby.

    ```bash
    pg_ctl -D /path/to/data/n1_standby stop
    ```

10. Install the target PostgreSQL version on the standby's host,
    alongside its existing installation, the same way you did for the
    primary in step 4.

    ### Updating Patroni to use the Upgraded Instance

11. If this standby pair already runs under Patroni, you can reuse
    this node's own existing Patroni cluster and the DCS (Distributed
    Configuration Store) behind it, rather than standing up either
    from scratch.

    **Optional:** if this is the first time this node and its standby
    are being brought under Patroni, install Patroni and a DCS on both
    hosts first. This tutorial uses `etcd` as the DCS, the most common
    choice for Patroni:

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
    initial-cluster-token: n1-etcd
    initial-cluster-state: new
    ```

    ```bash
    etcd --config-file /etc/etcd/etcd.yml
    ```

    Confirm both hosts can reach the DCS before continuing, whether it
    is freshly started or already serving this pair:

    ```bash
    etcdctl --endpoints=127.0.0.1:2379 endpoint health
    ```

12. Point this node's Patroni configuration at the upgraded instance.
    If this is the first time the node is being brought under Patroni,
    write a new config for it as the leader of a new Patroni cluster,
    rather than letting Patroni bootstrap it from scratch - the data
    directory is already initialized and already running the data
    `pg_upgrade` produced, and Patroni only runs its bootstrap process
    against an empty `data_dir`; pointing it at the existing, populated
    directory makes Patroni adopt the running instance as the
    cluster's first member instead. If the node was already under
    Patroni before this upgrade, update its existing config's
    `data_dir` and `bin_dir` to the values below instead of writing a
    new file. `pg_upgrade` preserves roles and their passwords, and
    step 7 above already copied `pg_hba.conf` forward, so a
    `replicator` role and its `pg_hba.conf` entry from an existing
    standby still work unchanged.

    **Optional:** set a password on the `postgres` superuser only if
    one is not already set:

    ```bash
    psql -p 5432 -c "ALTER ROLE postgres WITH PASSWORD 'superpassword';"
    ```

    ```yaml
    scope: n1-cluster
    namespace: /service/
    name: n1

    restapi:
      listen: 127.0.0.1:8541
      connect_address: 127.0.0.1:8541

    etcd3:
      hosts: 127.0.0.1:2379

    postgresql:
      listen: 127.0.0.1:5432
      connect_address: 127.0.0.1:5432
      data_dir: /path/to/data/n1_new
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

13. If the node was already under Patroni, reload its configuration -
    this restarts Patroni, not PostgreSQL, so it is safe while the
    instance is paused - then resume the cluster to lift the pause
    from step 3:

    ```bash
    patronictl -c /path/to/n1_patroni.yml reload n1-cluster n1
    patronictl -c /path/to/n1_patroni.yml resume n1-cluster
    ```

    **Optional:** if this is the first time the node is being brought
    under Patroni, start it against the running instance instead:

    ```bash
    patroni /path/to/n1_patroni.yml
    ```

    Then, for `n1_standby`'s own Patroni config: if it was already
    under Patroni before this upgrade, its Patroni process is already
    running rather than needing a fresh start. Update its `bin_dir` to
    the new version's path and reload Patroni's own configuration -
    this restarts Patroni, not PostgreSQL, so it is safe while the
    member is down - then tell Patroni to rebuild the member's data
    directory from the upgraded primary; its existing data directory
    still holds the old, now-incompatible major version:

    ```bash
    patronictl -c /path/to/n1_patroni.yml reload n1-cluster n1_standby
    patronictl -c /path/to/n1_patroni.yml reinit n1-cluster n1_standby --force
    ```

    **Optional:** if this is the first time `n1_standby` is being
    brought under Patroni, run a second Patroni instance - on the
    standby's own host, separate from the instance managing `n1` in
    step 13 - pointed at the same `scope` and DCS endpoint, under the
    member name `n1_standby`, with an empty `data_dir`, instead of
    reinitializing an existing one. Patroni finds the existing cluster
    in the DCS and, on first start, runs `pg_basebackup` itself against
    `n1` to populate that empty directory:

    ```yaml
    scope: n1-cluster
    namespace: /service/
    name: n1_standby

    restapi:
      listen: 127.0.0.1:8542
      connect_address: 127.0.0.1:8542

    etcd3:
      hosts: 127.0.0.1:2379

    postgresql:
      listen: 127.0.0.1:5442
      connect_address: 127.0.0.1:5442
      data_dir: /path/to/data/n1_standby_new
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
    patroni /path/to/n1_standby_patroni.yml
    ```

14. Confirm `n1_standby` joined and is streaming before moving on:

    ```bash
    patronictl -c /path/to/n1_patroni.yml list n1-cluster
    ```

15. Also confirm, on `n1`, that the slot backing the standby has
    synced:

    ```sql
    SELECT slot_name, synced, failover, invalidation_reason
    FROM pg_replication_slots
    WHERE NOT temporary;
    ```

16. `synchronized_standby_slots` names a Patroni-managed physical
    slot, and Patroni auto-creates one such slot per standby member -
    on whichever node is currently primary - named after that standby
    member rather than after its role. Today that slot is named
    `n1_standby` and exists on `n1`; if `n1_standby` is ever promoted,
    that slot disappears and a new one named `n1` appears on
    `n1_standby` instead, representing `n1` as the new standby. Add an
    `on_role_change` callback to both nodes' Patroni configuration so a
    future promotion resets the setting to name whichever member is
    then the standby:

    ```yaml
    postgresql:
      callbacks:
        on_role_change: /path/to/set_synchronized_standby_slots.sh
    ```

    The following script, deployed on `n1` with `SIBLING_MEMBER` set
    to `n1_standby` and `LOCAL_PORT` set to `5432` (and on
    `n1_standby` with them set to `n1` and `5442`), sets
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
    SIBLING_MEMBER="n1_standby"
    LOCAL_PORT="5432"

    if [ "$ROLE" = "master" ] || [ "$ROLE" = "primary" ]; then
      psql -p "${LOCAL_PORT}" -U postgres -c \
        "ALTER SYSTEM SET synchronized_standby_slots = '${SIBLING_MEMBER}';"
      psql -p "${LOCAL_PORT}" -U postgres -c "SELECT pg_reload_conf();"
    fi
    ```

17. The callback only fires on a future promotion, so set the initial
    value by hand now, on `n1` while it is still the leader:

    ```bash
    psql -p 5432 -U postgres -c \
      "ALTER SYSTEM SET synchronized_standby_slots = 'n1_standby';"
    psql -p 5432 -U postgres -c "SELECT pg_reload_conf();"
    ```

18. A later promotion of `n1_standby` is a separate event from this
    setup, and needs its own plan: Spock's subscriptions on `n2` and
    `n3` connect to `n1` using whichever address was configured when
    those subscriptions were created, and Patroni does not repoint
    that address for them. If `n1` is reachable only through a VIP or
    DNS record that Patroni (or `keepalived` alongside it) moves to
    whichever member is primary, no further Spock-level action is
    needed after a promotion. Without such an abstraction in front of
    the pair, repoint each subscription by hand after a promotion,
    from any node whose subscription still points at the old address.

    `node_add_interface` writes to the node catalog, which replicates
    to the rest of the mesh like any other table, so run it once,
    connected directly to any single reachable node (`n2` or `n3`, not
    `n1` itself if it is down):

    ```sql
    SELECT spock.node_add_interface('n1', 'n1_standby_interface',
      'host=127.0.0.1 dbname=inventory port=5442 user=pgedge password=1safepassword');
    ```

    Subscriptions are not replicated between nodes, so run
    `sub_alter_interface` locally on each node whose subscription has
    `n1` as its provider - on this cluster, that is `n2` and `n3`:

    ```sql
    SELECT spock.sub_alter_interface('sub_n1_n2', 'n1_standby_interface');
    ```

    `spock.gen_sub_name(provider_node, subscriber_node)` names each
    subscription, so `sub_n1_n2` is the subscription on `n2` whose
    provider is `n1`; confirm the exact names for your cluster with
    `SELECT sub_name FROM spock.subscription;` on each node before
    repointing them.

19. Check the node's replication slots before restoring traffic, and
    compare the slot names against what the node had before the
    upgrade:

    ```sql
    SELECT slot_name, slot_type, active
    FROM pg_replication_slots;
    ```

20. Whether the slots survived depends on the node's version *before*
    the upgrade, not the target version. If the node was running
    PostgreSQL 17 or later, its slots carried forward; confirm the
    node's subscribers reconnected and are replicating rather than
    erroring:

    ```sql
    CALL spock.show_all_subscription_status(
      'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
      true
    );
    ```

    !!! hint

        If the node was running PostgreSQL 15 or 16, its slots did not
        survive `pg_upgrade` regardless of what the query above shows -
        a freshly created slot has no memory of what its subscribers
        already received, so each subscription that depended on one of
        this node's slots needs a full resync rather than a
        table-by-table patch.

21. If the node was running PostgreSQL 15 or 16 before the upgrade, on
    every other node that subscribes to the node you just upgraded,
    drop and recreate that subscription. The following example
    recreates the subscription on `n2` whose provider is `n1`:

    ```sql
    SELECT spock.sub_drop('sub_n2_n1', true);

    SELECT spock.sub_create('sub_n2_n1',
      'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
      synchronize_structure := false,
      synchronize_data := true
    );

    SELECT spock.sub_wait_for_sync('sub_n2_n1');
    ```

    `synchronize_structure := false` is correct here - the schema did
    not change, only the node's PostgreSQL major version did.
    `synchronize_data := true` forces Spock to copy every table fresh,
    since the new slot cannot resume from the old one's position.

    Repeat this for every subscription that pointed at the upgraded
    node, on every other node in the cluster, before restoring that
    node's traffic to the application.

22. Restore traffic to the node at the load balancer, pooler, or
    application layer.

With `n1` upgraded, repeat steps 1 through 22 for `n2` and `n3`.

Each node's standby must be built from a `pg_basebackup` against that
specific node, never against another one - `n2_standby` streams from
`n2`, not from `n1`, even though Spock keeps their table data
identical.

!!! hint

    A physical standby is tied to the exact system identifier and
    Spock catalog rows (its own `spock.node`/`spock.subscription`
    entries) of the instance it shadows, so it can be promoted into
    that instance's exact identity; a standby built from `n1` and
    promoted in place of `n2` would still carry `n1`'s identity and
    subscriptions, breaking the mesh rather than replacing `n2`.

Each node's physical standby, if it has one, also belongs under its
own Patroni scope (`n2-cluster`, `n3-cluster`) with its own leader -
never add `n2` or `n3` as a member of `n1-cluster`. Patroni elects one
primary per scope, and `n1`, `n2`, and `n3` each remain independent
primaries in the Spock mesh, not standbys of one another. The DCS
deployment itself can still be shared: one etcd cluster can serve
every node's Patroni scope, so long as each scope's name is unique.

## Verifying the Rollout

Once every node has been upgraded, confirm the whole cluster runs the
target PostgreSQL version and reports a clean replication topology:

```sql
SELECT * FROM dblink(
  'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
  'SHOW server_version'
) AS t(pg_version text);

CALL spock.show_all_nodes(
  'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
  true
);
```

The following table describes what to check in the output before
considering the rollout complete:

| Field | What to confirm |
|---|---|
| PostgreSQL version | Every node reports the target version. |
| Subscription status | Every subscription between every pair of nodes reports `replicating`. |

## Troubleshooting

- **`pg_upgrade --check` reports an incompatible extension version.**
  Install the Spock build for the target PostgreSQL version on the
  node before upgrading; `pg_upgrade` checks that every extension in
  the old cluster has a matching library available for the new one.

- **`pg_upgrade --link` falls back to copying files, or fails with an
  error about renaming across filesystems.** The old and new data
  directories are on different filesystems or volumes. Place the new
  data directory on the same filesystem as the old one, or accept the
  storage cost of a full copy.

- **A node's replication slots are missing after the upgrade.** Expected
  when upgrading from PostgreSQL 15 or 16; see step 20 above.

- **The application still routes traffic to a node that is down for
  upgrade.** Confirm the load balancer, pooler, or application-level
  routing actually removed the node from rotation in step 1 before you
  stopped it in step 3, rather than relying on connection failures to
  redirect traffic.

For more information, review the following resources:

- [Modifying a Cluster](index.md)
- [Logical Slot Failover (HA Standby)](../logical_slot_failover.md)
- [Tutorial: Updating the Postgres Version with a Rolling
  Update](zodan/zodan_rolling_pg_version_tutorial.md)
