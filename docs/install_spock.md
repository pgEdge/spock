# Installing and Configuring the Spock Extension

The Spock extension can be installed with pgEdge Postgres packages
or built from source. pgEdge Postgres deployments provide a simplified
upgrade path that allows you to take advantage of important new features
quickly and easily.

Spock is open-source, with code available for review at
[Github](https://github.com/pgEdge).

!!! warning

    Spock uses files stored in the `spock` schema to provide replication
    functionality.  Do not delete, create, or modify files in the `spock`
    schema directly; use Spock functions and procedures to manage replication.

For detailed information about using Spock to create a two-node cluster,
visit [here](two_node_cluster.md).


## Installing Spock with pgEdge Enterprise Postgres

The latest Spock extension is automatically installed with any
[pgEdge Enterprise Postgres](https://docs.pgedge.com/enterprise) installation.
A pgEdge deployment provides quick and easy access to:

*  the latest minor version of your preferred Postgres version.
*  Spock [functions and procedures](spock_functions/index.md).
*  [ACE consistency monitoring](https://docs.pgedge.com/platform/ace).
*  [Snowflake sequences](https://docs.pgedge.com/platform/snowflake).
*  [pgBackRest](https://docs.pgedge.com/platform/managing/pgbackrest)
   for simplified backup and restore capabilities.
*  [LOLOR](https://docs.pgedge.com/lolor/v1-2-2/) large object support.
*  management tools for your active-active distributed cluster.


## Building the Extension from Source

Spock is available as an
[open-source project](https://github.com/pgEdge/spock) that you can build
from source code distributed at the Github project page.  The Spock extension
must be built on a version-specific build of Postgres that is patched to
provide 'hooks' so `spock` can access the Postgres engine.

To patch the Postgres source code, download the source code from the
[Postgres project](https://www.postgresql.org/ftp/source/), and move into
the source directory.  Then, clone the `spock` directory:

`git clone https://github.com/pgEdge/spock.git`

Then, apply the `.diff` files from the `spock/patches/version` directory
that match your build version. To apply a patch, use the command:

  `patch -p1 < path_to_patch/patch_name`

After applying version-specific patches, you can configure, `make`, and
`make install` the Postgres server as described in the
[Postgres documentation](https://www.postgresql.org/docs/current/installation.html).
When the build completes, add the location of your `pg_config` file to your
`PATH` variable:

  `export PATH=path_to_pg_config_file`

Before invoking `make` and `make install`, install the
[jansson library](https://jansson.readthedocs.io/en/1.1/gettingstarted.html)
to meet Spock prerequisites.

Then, move into the `spock` directory, and use a build process much like any
other Postgres extension:

`make`

`make-install`


## Configuring Spock for Replication

After installing Postgres on each node that will host a spock instance,
use [initdb](https://www.postgresql.org/docs/18/app-initdb.html) to initialize
a Postgres cluster. After initializing the cluster, you can connect
with psql, and query the server for file locations and cluster details:

```sql
[sdouglas@lima-pg3 pg18]$ sudo -u postgres psql -U postgres -p 5432
psql (18.1)
Type "help" for help.

postgres=# SHOW data_directory;
SHOW config_file;
SHOW hba_file;

     data_directory     
------------------------
 /var/lib/pgsql/18/data
(1 row)

              config_file               
----------------------------------------
 /var/lib/pgsql/18/data/postgresql.conf
(1 row)

              hba_file              
------------------------------------
 /var/lib/pgsql/18/data/pg_hba.conf
(1 row)
```

Then, use your choice of editor to update the `postgresql.conf` file, adding
required Postgres parameters to the end of the file:

```sql
wal_level = logical
max_worker_processes = 10
max_replication_slots = 10
max_wal_senders = 10
shared_preload_libraries = 'spock'
track_commit_timestamp = on
```

After modifying the Postgres parameters, use your OS-specific command to 
restart the Postgres server:

```bash
[sdouglas@lima-pg3 pg18]$ sudo systemctl restart postgresql-18
[sdouglas@lima-pg3 pg18]$ sudo systemctl status postgresql-18
● postgresql-18.service - PostgreSQL 18 database server
     Loaded: loaded (/usr/lib/systemd/system/postgresql-18.service; enabled; preset: disabled)
     Active: active (running) since Wed 2026-02-11 11:44:11 EST; 7s ago
```

Then, connect to the psql command line, and create the spock extension:
  
```sql
postgres=# CREATE EXTENSION spock;
CREATE EXTENSION
postgres=# 
```


### Creating a Replication Scenario

After configuring the nodes, connect to the psql command line of the first
provider node, and use the `spock.node_create` command to create the provider
node:

```sql
    SELECT spock.node_create(
        node_name := 'provider1',
        dsn := 'host=providerhost port=5432 dbname=db'
    );
```

Then, add the tables in the `public` schema to the `default` replication
set.

```sql
    SELECT spock.repset_add_all_tables('default', ARRAY['public']);
```

Once the provider node is configured, you can add subscribers. First create
the subscriber node:

```sql
    SELECT spock.node_create(
        node_name := 'subscriber1',
        dsn := 'host=thishost port=5432 dbname=db'
    );
```

Then, create the subscription which will start synchronization and
replication on the subscriber node:

```sql
    SELECT spock.sub_create(
        subscription_name := 'subscription1',
        provider_dsn := 'host=providerhost port=5432 dbname=db'
    );

    SELECT spock.sub_wait_for_sync('subscription1');
```
