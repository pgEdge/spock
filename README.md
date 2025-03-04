# Spock Multi-Master Replication for PostgreSQL

## Table of Contents
- [Building the Spock Extension](README.md#building-the-spock-extension)
- [Basic Configuration and Usage](README.md#basic-configuration-and-usage)
- [Advanced Configuration Options](docs/guc_settings.md)
- [Spock Functions](docs/spock_functions.md)
- [Using Spock in Read Only Mode](docs/read_only.md)
- [Limitations](docs/limitations.md)
- [FAQ](docs/FAQ.md)
- [Release Notes](docs/spock_release_notes.md)

# Spock Multi-Master Replication for PostgreSQL

The SPOCK extension provides multi-master replication for PostgreSQL versions 15 and later.

You must install the `spock` extension on each provider and subscriber node in your cluster; then, after installing the extension, use the command line to `CREATE EXTENSION spock` on every node.  If you're performing a major version upgrade, the old node can be running a recent version of pgLogical2 before upgrading it to become a Spock node.

All tables on the provider and subscriber must have the same names and reside in the same schema. Tables must also have the same columns, with the samedata types in each column. `CHECK` constraints, `NOT NULL` constraints must be the same or more permissive on the subscriber than the provider.

Your tables must also have the same `PRIMARY KEY`s. We do not recommend using additional `UNIQUE` constraints other than the `PRIMARY KEY`.

For more information about the Spock extension's advanced functionality, visit [here](docs/features.md).

## Building the Spock Extension

The Spock extension must reside on a version-specific build of PostgreSQL.  When building PostgreSQL from source, you will need to apply version-specific .diff files from the `patches` directory (also in this repository) before building the Postgres server.  To apply a patch, use the command:

`patch -p1 < path_to_patch/patch_name`

Then, you can configure, make, and make install the Postgres server as noted in the [PostgreSQL documentation](https://www.postgresql.org/docs/current/installation.html).  When the build completes, add the location of `pg_config` to your `PATH` variable:

`export PATH=path_to_pg_config_file`

Then, build the Spock extension from source code.  Before building the extension, copy the files in the version-specific `compatXX` file (where XX is your Postgres version) in the `spock` repository into the base directory of the repository.  After copying the files, use a build process much like any [other PostgreSQL extension](https://www.postgresql.org/docs/17/extend-extensions.html); you will need to `make` and `make-install` the code.

Then, update your PostgreSQL `postgresql.conf` file, setting:

`shared_preload_libraries = 'spock'`
`track_commit_timestamp = on # needed for conflict resolution`

Before using the [`CREATE EXTENSION`](https://www.postgresql.org/docs/17/sql-createextension.html) command to install the `spock` extension on each node in the database you wish to replicate:

`CREATE EXTENSION spock;`


### Basic Configuration and Usage

Before using the extension, configure the PostgreSQL server to support logical decoding:

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

It's usually better to create replication sets before creating subscriptions so that all tables are synchronized during initial replication setup in a single initial transaction. However, if you're using a large database, you may instead wish to create them incrementally for better control.

Once the provider node is setup, subscribers can be subscribed to it. First the
subscriber node must be created:

    SELECT spock.node_create(
        node_name := 'subscriber1',
        dsn := 'host=thishost port=5432 dbname=db'
    );

Finally, create the subscription which will start synchronization and replication on the subscriber node:

    SELECT spock.sub_create(
        subscription_name := 'subscription1',
        provider_dsn := 'host=providerhost port=5432 dbname=db'
    );

    SELECT spock.sub_wait_for_sync('subscription1');

Spock is licensed under the [pgEdge Community License v1.0](PGEDGE-COMMUNITY-LICENSE.md)
