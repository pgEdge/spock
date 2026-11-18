## Creating a Subscriber Node with pg_basebackup

Spock supports creating a subscriber node by cloning the provider with [`pg_basebackup`](https://www.postgresql.org/docs/current/app-pgbasebackup.html) and starting it as a Spock subscriber. Use the `spock_create_subscriber` utility (located in the `bin` directory of your pgEdge platform installation) to register the node.

### Synopsis:

  `spock_create_subscriber [OPTION]...`

**Options**

Specify the following options as needed.

| Option   | Description
|----------|-------------
| `-D`, `--pgdata=DIRECTORY` | The `data` directory to be used for new node. This can be either an empty/non-existing directory, or a directory populated using the `pg_basebackup -X stream` command.
| `--databases`              |  An optional list of databases to replicate.
| `-n`, `--subscriber-name=NAME` | The name of the newly created subscriber.
| `--subscriber-dsn=CONNSTR` | A connection string to the newly created subscriber.
| `--provider-dsn=CONNSTR` | A connection string to the provider.
| `--replication-sets=SETS` | A comma-separated list of replication set names.
| `--apply-delay=DELAY` | The apply delay in seconds (by default 0).
| `--drop-slot-if-exists` | Drop replication slot of conflicting name.
| `-s`, `--stop` | Stop the server once the initialization is done.
| `-v` | Increase logging verbosity.
| `--extra-basebackup-args` | Additional arguments to pass to `pg_basebackup`. Safe options are: `-T`, `-c`, `--xlogdir`/`--waldir`
| `--text-types` | Transfer all column values as text rather than binary during initial sync. Use this when provider and subscriber differ in endianness or type representation.

**Configuration files overrides**

You can use the following options to override the location of the configuration files.

| Option   | Description
|----------|-------------
|`--hba-conf` | path to the new `pg_hba.conf`
| `--postgresql-conf` | path to the new `postgresql.conf`
| `--postgresql-auto-conf` | settings to override in `postgresql.auto.conf`
| `--recovery-conf` | path to the template recovery configuration

Unlike `spock.sub_create`'s other data sync options, this method of cloning ignores replication sets and copies all tables on all databases. However, it's often much faster, especially over high-bandwidth connections.

**New node configuration**

After the configuration overrides are applied, the utility checks the new node's configuration and stops if `wal_level` is not `logical` or `shared_preload_libraries` does not include `spock`. With `--bidirectional`, `track_commit_timestamp` must also be `on`.

### Joining a multi-master cluster

With `--bidirectional`, the utility joins the new node to an existing multi-master cluster: the new node subscribes to every existing node, and every existing node subscribes to it. The provider named by `--provider-dsn` is the source node; the other nodes are discovered from its subscriptions. The replication sets are taken from the source's subscriptions, so `--replication-sets`, `--apply-delay` and `--text-types` cannot be combined with `--bidirectional`.

| Option   | Description
|----------|-------------
| `--bidirectional` | Join an existing multi-master cluster.
| `--stall-timeout=SECS` | Once PostgreSQL accepts connections, the number of seconds without replay progress before giving up (default 600). It does not bound PostgreSQL's own startup.
| `--max-wait=SECS` | A hard ceiling, in seconds, on the catchup wait after the connection is made (default: unbounded). It does not bound PostgreSQL's own startup.
| `--cleanup` | Remove the partial state of an interrupted join and exit. Stops PostgreSQL if it is running in `--pgdata`.
| `--force` | With `--cleanup`, also remove the data directory. Required when the manifest records a completed join.

`--subscriber-dsn` must be an address the existing nodes can use to connect back to the new node. The join requires:

- Spock 6.0.0 or later on every node.
- `track_commit_timestamp = on` on the source and on every peer.
- Every node in the cluster subscribed to every other node, with all those subscriptions replicating.
- No unreplicated changes pending from the source to an existing peer.
- Exactly one Spock database on the source, and no enabled native logical subscriptions.
- The same replication sets, with the same tables, row filters and table schemas, on the source and on each peer.

Until the join completes, keep the new node unreachable by other clients, for example with a private address or a restrictive `pg_hba.conf` set through `--hba-conf` or `--postgresql-conf`; the utility does not do this.

The utility records the objects it creates on the other nodes in `spock_bidirectional_manifest.json` in `--pgdata`, and in `<pgdata>.spock_bidir_pending.json` until the base backup is complete. If a join fails or is interrupted, run the utility with `--bidirectional --cleanup --pgdata=DIRECTORY` to remove the subscriptions and replication slots it created. Add `--force` to also remove the data directory.
