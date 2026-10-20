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
PostgreSQL 16 to PostgreSQL 18, one node at a time, without a second full copy
of any node's data. `pg_upgrade` still needs a new, empty data directory for
each node, but in link mode it holds hard links to the old files rather than
copies of them. When a node also carries a physical standby for high
availability, rebuilding that standby and bringing it under Patroni folds into
the same per-node loop, so high availability is preserved before you move on to
the next node.

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
      be on the same filesystem, so that hard links are possible. On a
      filesystem without hard links, or with the directories on
      separate volumes, `pg_upgrade` stops with `could not create hard
      link between old and new data directories`; it does not fall back
      to copying.
    - `--link` mode ties the old and new clusters' data files
      together. After you start the new cluster, you cannot go back to
      running the old one; treat the old `postgresql.conf`,
      `pg_hba.conf`, and any other node-specific configuration as
      reference material to port forward, not something you can
      revert to.
    - `pg_upgrade` does not carry Spock's replication origins over, on
      any PostgreSQL version. This procedure records them before the
      upgrade and restores them afterwards (steps 2 and 19), and drops
      and recreates the other nodes' subscriptions to the node without
      copying data (steps 3 and 20).
    - While a node is down, the other nodes keep WAL for their
      subscriptions to it. If `max_slot_wal_keep_size` is set, make
      sure it allows for the whole upgrade window, or those slots can
      be invalidated and the node will need a full rebuild.
    - `spock.show_all_subscription_status()` and `spock.show_all_nodes()`
      are Zodan procedures. Load `zodan.sql` from the Spock
      distribution, which needs the `dblink` extension, on the node you
      run them from.
    - Run `pg_upgrade --check` against the node before running the
      real upgrade, and resolve everything it reports.
    - A node's physical standby cannot continue streaming once the
      node's major version changes; the standby must be rebuilt from
      the upgraded node, not upgraded in place alongside it.

!!! note

    The examples run every instance on one host and use `127.0.0.1`.
    When a node and its standby, or the nodes of the cluster, run on
    separate hosts, use addresses each host can reach in connection
    strings, `listen` and `connect_address`, and the etcd URLs, and
    point every Patroni member of a scope at the same DCS. Replace the
    `<...>` password placeholders with your own unique secrets.

## Upgrading the Cluster with pg_upgrade

Repeat the following steps once per node, moving from `n1` to `n3` in
our example. Finish all steps for one node before starting the next.

1. Drain traffic from the node being upgraded at the load balancer,
   pooler, or application layer, and confirm no new connections are
   arriving at it.

2. Make sure every other node has applied everything `n1` committed,
   and record what the upgrade will lose. With traffic drained, emit a
   sync event on `n1`:

    ```sql
    -- On n1
    SELECT spock.sync_event();
    ```

    Wait for it on every other node, passing the LSN it returned. The
    `result` column must come back `t`:

    ```sql
    -- On n2, then on n3
    CALL spock.wait_for_sync_event(NULL, 'n1'::name, '<lsn-from-sync_event>'::pg_lsn, 600);
    ```

    Then confirm on `n1` that every slot has confirmed past that LSN;
    this query must return no rows:

    ```sql
    -- On n1
    SELECT slot_name, confirmed_flush_lsn
    FROM pg_replication_slots
    WHERE confirmed_flush_lsn IS NULL
       OR confirmed_flush_lsn < '<lsn-from-sync_event>'::pg_lsn;
    ```

    `pg_upgrade` does not carry Spock's replication origins over, so
    record where each of `n1`'s subscriptions has applied up to. Every
    row must show an LSN; a `NULL` means a subscription with no origin,
    which you must resolve before upgrading:

    ```sql
    -- On n1
    SELECT s.sub_name, s.sub_slot_name, o.remote_lsn
    FROM spock.subscription s
    LEFT JOIN pg_replication_origin_status o
           ON o.external_id = s.sub_slot_name;
    ```

    Also record, on every other node, the definition of its
    subscription to `n1`, so you can recreate it unchanged in step 20:

    ```sql
    -- On n2 (sub_n1_n2), then on n3 (sub_n1_n3)
    SELECT sub_name, sub_replication_sets, sub_forward_origins,
           sub_apply_delay, sub_force_text_transfer, sub_skip_schema
    FROM spock.subscription
    WHERE sub_name = 'sub_n1_n2';
    ```

    `spock.gen_sub_name(provider_node, subscriber_node)` names each
    subscription, so `sub_n1_n2` is the subscription on `n2` whose
    provider is `n1`. Confirm the names for your cluster with
    `SELECT sub_name FROM spock.subscription;` on each node.

3. Disable `n1`'s own subscriptions, so it stops applying, and wait
   until `SELECT * FROM spock.sub_show_status();` on `n1` no longer
   shows any as `replicating`:

    ```sql
    -- On n1, once per subscription
    SELECT spock.sub_disable('sub_n2_n1');
    SELECT spock.sub_disable('sub_n3_n1');
    ```

    While `n1` is still running, drop every other node's subscription
    to it. `sub_drop` removes the subscription's slot on `n1` only
    when it can reach `n1`; a subscription dropped later leaves its slot
    behind on `n1`. No data is lost, because step 2 confirmed that every
    node had applied all of `n1`'s changes:

    ```sql
    -- On n2, then the matching subscription on n3
    SELECT spock.sub_drop('sub_n1_n2');
    ```

    If this node already runs under Patroni, pause it so that
   manually stopping PostgreSQL below does not trigger an automatic
   restart - Patroni's own documentation names major-version upgrades
   as the intended use case for this mode:

    ```bash
    patronictl -c /path/to/n1_patroni.yml pause n1-cluster
    ```

    Before stopping the node, record its encoding; step 5 needs it and
    the server cannot answer once it is down:

    ```bash
    psql -p 5432 -c "SHOW server_encoding;"
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
   encoding, locale and checksum setting exactly, or
   `pg_upgrade --check` fails. Use the encoding you recorded in step 3,
   and read the checksum setting from the stopped data directory:

    ```bash
    pg_controldata /path/to/data/n1 | grep "checksum version"
    ```

    Pass the recorded encoding to `initdb`. If the checksum version is
    `1`, enable checksums:

    ```bash
    /path/to/pg18/bin/initdb -D /path/to/data/n1_new \
      --encoding=<recorded-encoding> --data-checksums
    ```

    If it is `0`, disable them explicitly. PostgreSQL 18 `initdb`
    enables checksums by default, so leaving the option out does not
    match a cluster without them:

    ```bash
    /path/to/pg18/bin/initdb -D /path/to/data/n1_new \
      --encoding=<recorded-encoding> --no-data-checksums
    ```

    `pg_upgrade` does not carry configuration files forward; the new
    data directory has only the defaults `initdb` wrote. Configure it
    now, before step 6: `pg_upgrade --check` reads `wal_level`,
    `max_replication_slots` and `output_plugin_libraries` from the new
    cluster, and fails if they cannot hold the old cluster's logical
    slots when the old cluster is PostgreSQL 17 or later. Copy
    `pg_hba.conf` as-is, since authentication rules do not change with
    the PostgreSQL version:

    ```bash
    cp /path/to/data/n1/pg_hba.conf /path/to/data/n1_new/pg_hba.conf
    ```

    Then add the Spock settings to the new data directory's
    `postgresql.conf`, using the old node's values where they are
    larger. `max_replication_slots` must be at least the number of
    logical slots on the old node:

    ```ini
    wal_level = logical
    max_worker_processes = 20
    max_replication_slots = 10
    max_wal_senders = 10
    shared_preload_libraries = 'spock'
    track_commit_timestamp = on
    output_plugin_libraries = 'pgoutput, test_decoding, spock_output'

    # PostgreSQL 18 and later only:
    max_active_replication_origins = 10
    ```

    `output_plugin_libraries` exists only from the patch versions in
    the table below. Set it only if the new binaries have it: on an
    older patch version the server does not recognize the parameter and
    will not start. Check with
    `SELECT current_setting('output_plugin_libraries', true);`, which
    returns NULL when the parameter does not exist. The following
    table describes the first patch version of each major version that
    has it:

    | PostgreSQL major version | Minimum patch version |
    |---|---|
    | 15 | 15.19 |
    | 16 | 16.15 |
    | 17 | 17.11 |
    | 18 | 18.6 |

6. Run `pg_upgrade --check` first, against the target version's
   binaries, to confirm there are no blocking issues:

    ```bash
    /path/to/pg18/bin/pg_upgrade \
      --old-datadir /path/to/data/n1 \
      --new-datadir /path/to/data/n1_new \
      --old-bindir /path/to/pg16/bin \
      --new-bindir /path/to/pg18/bin \
      --link --check
    ```

    Pass `--link` to the check too, so it also confirms hard links
    work between the two directories.

    Then run the upgrade itself, adding `--link` to hard-link the
    data files instead of copying them:

    ```bash
    /path/to/pg18/bin/pg_upgrade \
      --old-datadir /path/to/data/n1 \
      --new-datadir /path/to/data/n1_new \
      --old-bindir /path/to/pg16/bin \
      --new-bindir /path/to/pg18/bin \
      --link
    ```

7. Port any other settings the node needs from the old
   `postgresql.conf` (memory, logging, connection limits and similar)
   to the new one before you start it. Review each one against the
   target version's documentation rather than copying the whole file,
   since parameters are renamed or removed between major versions.

8. Start PostgreSQL on the new version:

    ```bash
    pg_ctl -D /path/to/data/n1_new -o "-p 5432" start
    ```

9. If this node runs behind a physical standby for high availability,
   stop it now - physical replication cannot continue once the
   primary's major version changes. Skip steps 9 through 18 if the
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
    step 5 above already copied `pg_hba.conf` forward, so a
    `replicator` role and its `pg_hba.conf` entry from an existing
    standby still work unchanged.

    **Optional:** set a password on the `postgres` superuser only if
    one is not already set:

    ```bash
    psql -p 5432 -c "ALTER ROLE postgres WITH PASSWORD '<postgres-password>';"
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
          password: <replicator-password>
        superuser:
          username: postgres
          password: <postgres-password>
    ```

13. If the node was already under Patroni, its DCS still records the
    old cluster's system identifier, and `pg_upgrade` gave the
    upgraded cluster a new one. Patroni refuses to manage a data
    directory whose system identifier does not match, so the old
    cluster state has to go before Patroni can adopt the upgraded
    instance. Stop the Patroni process on both `n1` and `n1_standby`,
    then remove the scope's state from the DCS. `patronictl remove`
    asks you to type the cluster name and confirm:

    ```bash
    patronictl -c /path/to/n1_patroni.yml remove n1-cluster
    ```

    This deletes only the DCS keys for `n1-cluster`, not any data
    directory. It also deletes the scope's dynamic configuration, which
    ends the pause from step 3 and drops any settings you applied with
    `patronictl edit-config`; record those first with
    `patronictl -c /path/to/n1_patroni.yml show-config n1-cluster` and
    apply them again once Patroni is running.

    Whether the node was already under Patroni or is being brought
    under it for the first time, start Patroni on `n1` with the
    configuration from step 12. With no cluster state in the DCS and
    PostgreSQL already running on a populated `data_dir`, Patroni
    adopts the running instance as the leader rather than
    bootstrapping a new one:

    ```bash
    patroni /path/to/n1_patroni.yml
    ```

    Then bring up `n1_standby` as a new member: its old data directory
    holds the old, now-incompatible major version and cannot be
    reused. Run Patroni on the standby's own host, pointed at the same
    `scope` and DCS, under the member name `n1_standby`, with an empty
    `data_dir`. Patroni finds the cluster in the DCS and, on first
    start, runs `pg_basebackup` itself against `n1` to populate that
    empty directory. If `n1_standby` was already under Patroni, edit
    its existing config to the values below:

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
          password: <replicator-password>
        superuser:
          username: postgres
          password: <postgres-password>
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

    `node_add_interface` writes only to the local node catalog; it is
    not replicated. Run it on every node whose subscription you will
    repoint, here `n2` and `n3`, since `sub_alter_interface` looks the
    interface up locally:

    ```sql
    SELECT spock.node_add_interface('n1', 'n1_standby_interface',
      'host=127.0.0.1 dbname=inventory port=5442 user=pgedge password=<pgedge-password>');
    ```

    Then run `sub_alter_interface` on each of those nodes. The
    subscriptions it names are the ones step 20 recreates, so this only
    applies once step 20 is done:

    ```sql
    SELECT spock.sub_alter_interface('sub_n1_n2', 'n1_standby_interface');
    ```

    `spock.gen_sub_name(provider_node, subscriber_node)` names each
    subscription, so `sub_n1_n2` is the subscription on `n2` whose
    provider is `n1`; confirm the exact names for your cluster with
    `SELECT sub_name FROM spock.subscription;` on each node before
    repointing them.

19. Put `n1`'s replication origins back where step 2 recorded them,
    before its subscriptions run again. For each subscription, create
    the origin if `pg_upgrade` did not keep it, then advance it to the
    recorded LSN:

    ```sql
    -- On n1, once per row recorded in step 2
    SELECT pg_replication_origin_create('<sub_slot_name>')
    WHERE NOT EXISTS (SELECT 1 FROM pg_replication_origin
                      WHERE roname = '<sub_slot_name>');
    SELECT pg_replication_origin_advance('<sub_slot_name>', '<remote_lsn>'::pg_lsn);
    ```

    Confirm each origin now shows its recorded LSN:

    ```sql
    SELECT external_id, remote_lsn FROM pg_replication_origin_status;
    ```

20. On every other node, recreate its subscription to `n1` from the
    definition recorded in step 2. Do not copy data: step 2 made sure
    every node already held all of `n1`'s changes, and `n1` has taken
    no writes since. The following example recreates the subscription
    on `n2` whose provider is `n1`:

    ```sql
    -- On n2, then the matching subscription on n3
    SELECT spock.sub_create(
      subscription_name     := 'sub_n1_n2',
      provider_dsn          := 'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=<pgedge-password>',
      replication_sets      := '<recorded sub_replication_sets>',
      forward_origins       := '<recorded sub_forward_origins>',
      apply_delay           := '<recorded sub_apply_delay>',
      force_text_transfer   := <recorded sub_force_text_transfer>,
      skip_schema           := '<recorded sub_skip_schema>',
      synchronize_structure := false,
      synchronize_data      := false
    );
    ```

    Do not set `synchronize_data := true` here. The data sync copies
    each table into the existing one without emptying it first, so it
    fails on the rows the node already holds.

21. Re-enable `n1`'s own subscriptions, then confirm every
    subscription to and from `n1` reports `replicating`:

    ```sql
    -- On n1, once per subscription
    SELECT spock.sub_enable('sub_n2_n1', true);
    SELECT spock.sub_enable('sub_n3_n1', true);
    ```

    Then check the status of every subscription in the cluster:

    ```sql
    CALL spock.show_all_subscription_status(
      'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=<pgedge-password>',
      true
    );
    ```

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

When every node has been upgraded, confirm the whole cluster runs the
target PostgreSQL version and reports a clean replication topology:

```sql
SELECT * FROM dblink(
  'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=<pgedge-password>',
  'SHOW server_version'
) AS t(pg_version text);

CALL spock.show_all_subscription_status(
  'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=<pgedge-password>',
  true
);
```

Run the `dblink` query once per node, changing the port.

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

- **`pg_upgrade --link` fails with `could not create hard link between
  old and new data directories`.** The old and new data directories
  are on different filesystems or volumes. Place the new data
  directory on the same filesystem as the old one, or run without
  `--link` and accept the storage cost of a full copy.

- **A subscription on the upgraded node fails because its replication
  origin does not exist.** The origin was not restored before the
  subscription was enabled. Disable it, restore the origin as in step
  19 from the position recorded in step 2, then enable it again.

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
