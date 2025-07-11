# Spock Multi-Master Replication for PostgreSQL

## Table of Contents
- [Building the Spock Extension](README.md#building-the-spock-extension)
- [Basic Configuration and Usage](README.md#basic-configuration-and-usage)
- [Upgrading a Spock Installation](README.md#upgrading)
- [Conflict Management Options](docs/conflicts.md)
- [Advanced Configuration Options](docs/guc_settings.md)
- [Spock Functions](docs/spock_functions.md)
- [Using Spock in Read Only Mode](docs/read_only.md)
- [Tutorial - Adding a Node with Zero Downtime](docs/zodan.md)
- [Using spockctrl management functions](docs/spockctrl.md)
- [Limitations](docs/limitations.md)
- [FAQ](docs/FAQ.md)
- [Release Notes](docs/spock_release_notes.md)

# Spock Multi-Master Replication for PostgreSQL

The SPOCK extension provides multi-master replication for PostgreSQL versions 15 and later.

You must install the `spock` extension on each provider and subscriber node in your cluster.  If you're performing a major version upgrade, the old node can be running a recent version of pgLogical2 before upgrading it to become a Spock node.

All tables on the provider and subscriber must have the same names and reside in the same schema. Tables must also have the same columns, with the same data types in each column. `CHECK` constraints and `NOT NULL` constraints must be the same or more permissive on the subscriber than the provider.

Your tables must also have the same `PRIMARY KEY`s. 

For more information about the Spock extension's advanced functionality, visit [here](docs/features.md).

## Building the Spock Extension

The Spock extension must be built on a version-specific build of PostgreSQL that is patched to provide 'hooks' so `spock` can access the Postgres engine. When building Spock from source, you'll need to first build the PostgreSQL database from the source available at the [Postgres project](https://www.postgresql.org/ftp/source/), applying version-specific `.diff` files from the `patches` directory (also in the `spock` repository). To apply a patch, use the command:

  `patch -p1 < path_to_patch/patch_name`

After applying version-specific patches, you can configure, `make`, and `make install` the Postgres server as described in the [PostgreSQL documentation](https://www.postgresql.org/docs/17/installation.html). When the build completes, add the location of your `pg_config` file to your `PATH` variable:

  `export PATH=path_to_pg_config_file`

Then, build the Spock extension from source code. Before building the extension, copy the files in the version-specific `compatXX` file (where XX is your Postgres version) in the spock repository into the base directory of the repository. After copying the files, use a build process much like any other PostgreSQL extension; you will need to make and make-install the code.

Then, update your PostgreSQL `postgresql.conf` file, setting:

```bash
shared_preload_libraries = 'spock' 
track_commit_timestamp = on # needed for conflict resolution
```

Then, connect to the server and use the `CREATE EXTENSION` command to install the spock extension on each node in the database you wish to replicate:

  `CREATE EXTENSION spock;`


### Basic Configuration and Usage

First, you will need to configure your PostgreSQL server to support logical decoding:

    wal_level = 'logical'
    max_worker_processes = 10   # one per database needed on provider node
                                # one per node needed on subscriber node
    max_replication_slots = 10  # one per node needed on provider node
    max_wal_senders = 10        # one per node needed on provider node
    shared_preload_libraries = 'spock'
    track_commit_timestamp = on # needed for conflict resolution

Also, you will need to configure your `pg_hba.conf` file to allow logical replication connections from localhost. Logical replication connections are treated by `pg_hba.conf` as regular connections to the provider database.

Then, use the `spock.node_create` command to create the provider node:

    SELECT spock.node_create(
        node_name := 'provider1',
        dsn := 'host=providerhost port=5432 dbname=db'
    );

Then, add the tables in the `public` schema to the `default` replication set.

    SELECT spock.repset_add_all_tables('default', ARRAY['public']);

Once the provider node is configured, you can add subscribers. First create the
subscriber node:

    SELECT spock.node_create(
        node_name := 'subscriber1',
        dsn := 'host=thishost port=5432 dbname=db'
    );

Then, create the subscription which will start synchronization and replication on the subscriber node:

    SELECT spock.sub_create(
        subscription_name := 'subscription1',
        provider_dsn := 'host=providerhost port=5432 dbname=db'
    );

    SELECT spock.sub_wait_for_sync('subscription1');

### Upgrading

You cannot roll back an upgrade because of changes to the catalog tables; before starting an upgrade, make sure you have a current backup of your cluster so you can recreate the original cluster if needed.

Then, to upgrade the version of Spock that you use to manage your replication cluster, you can remove, build, and upgrade the Spock extension like you would any other [PostgreSQL extension](https://www.postgresql.org/docs/17/extend-extensions.html#EXTEND-EXTENSIONS-UPDATES).




Spock is licensed under the [pgEdge Community License v1.0](PGEDGE-COMMUNITY-LICENSE.md)
