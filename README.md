# Spock Multi-Master Replication for PostgreSQL

[![Regression Tests and Spockbench](https://github.com/pgEdge/spock/actions/workflows/spockbench.yml/badge.svg)](https://github.com/pgEdge/spock/actions/workflows/spockbench.yml)

## Table of Contents
- [Building the Spock Extension](README.md#building-the-spock-extension)
- [Basic Configuration and Usage](README.md#basic-configuration-and-usage)
- [Upgrading a Spock Installation](README.md#upgrading)
- [Advanced Configuration Options](docs/guc_settings.md)
- [Spock Management Features](docs/features.md)
- [Modifying a Cluster](docs/modify.md)
- [Spock Functions](docs/spock_functions.md)
- [Using spockctrl Management Functions](docs/spockctrl.md)
- [Limitations](docs/limitations.md)
- [FAQ](docs/FAQ.md)
- [Release Notes](docs/spock_release_notes.md)

# Spock Multi-Master Replication for PostgreSQL

The SPOCK extension provides multi-master replication for PostgreSQL versions 15 and later.  Before configuring replication:

* Install the `Spock` extension on each node in your cluster.  If you're performing a major version upgrade, the old node can be running a recent version of pgLogical2 before upgrading it to become a Spock node.

* On each node in your cluster, tables must have the same name and reside in the same schema. To check the table name and schema name in which the table resides, you can connect to the database with [psql](https://www.postgresql.org/docs/17/app-psql.html) and use the `\d` meta-command:

`SELECT schemaname, tablename FROM pg_tables ORDER BY schemaname, tablename;`

For example:

```sql
lcdb=# \d
               List of relations
 Schema |      Name      |   Type   |  Owner   
--------+----------------+----------+----------
 public | table_a        | table    | ec2-user
 public | table_a_id_seq | sequence | ec2-user
 public | table_b        | table    | ec2-user
 public | table_b_id_seq | sequence | ec2-user
 public | table_c        | table    | ec2-user
 public | table_c_id_seq | sequence | ec2-user
(6 rows)

```

* Each Table must also have the same columns and primary keys, with the same data types in each column.  To review detailed information for all tables within a specific schema, connect to the database with psql and use the `\d schema_name.*` command; for example:

```sql
lcdb=# \d public.*
                                   Table "public.table_a"
   Column   |           Type           | Collation | Nullable |           Default            
------------+--------------------------+-----------+----------+------------------------------
 id         | bigint                   |           | not null | generated always as identity
 name       | text                     |           | not null | 
 qty        | integer                  |           | not null | 
 created_at | timestamp with time zone |           | not null | now()
Indexes:
    "table_a_pkey" PRIMARY KEY, btree (id)

                       Sequence "public.table_a_id_seq"
  Type  | Start | Minimum |       Maximum       | Increment | Cycles? | Cache 
--------+-------+---------+---------------------+-----------+---------+-------
 bigint |     1 |       1 | 9223372036854775807 |         1 | no      |     1
Sequence for identity column: public.table_a.id

     Index "public.table_a_pkey"
 Column |  Type  | Key? | Definition 
--------+--------+------+------------
 id     | bigint | yes  | id
primary key, btree, for table "public.table_a"
...
```

* `CHECK` constraints and `NOT NULL` constraints must be the same or more permissive on any standby node that acts only as a subscriber.

For more information about the Spock extension's advanced functionality, visit [here](docs/features.md).

## Building the Spock Extension

You will need to build the Spock extension on a patched PostgreSQL source tree to which you have applied version-specific `.diff` files from the `spock/patches/Postgres-version` directory. The high-level steps to build Postgres and the spock extension are:

1. Get the [Postgres source](https://www.postgresql.org/docs/current/install-getsource.html).

2. Copy the patch files to the base repository; the patches for each Postgres version are in a version-specific subdirectory of the [spock repo](https://github.com/pgEdge/spock/tree/main/patches).  Then, apply each patch, use the command:

  `patch -p1 < path_to_patch/patch_name`

   Note that you must apply the patches in the numerical order designated by their prefixes in the `spock` repository (for example, `pg16-015-patch-name`, then `pg16-020-patch-name`, then `pg16-025-patch-name`). 
  
3. `configure`, `make`, and `make install` the Postgres server as described in the [PostgreSQL documentation](https://www.postgresql.org/docs/current/install-make.html). 

4. When the build completes, add the location of your `pg_config` file to your `PATH` variable:

  `export PATH=path_to_pg_config_file`

5. Then, clone the `pgedge/spock` repository:

   `git clone https://github.com/pgEdge/spock.git`

6. Next, `make` and then `make-install` spock.

7. Then, update your Postgres `postgresql.conf` file, setting:

   ```bash
   shared_preload_libraries = 'spock' 
   track_commit_timestamp = on # needed for conflict resolution
   ```

8. Then, connect to the server and use the `CREATE EXTENSION` command to create the spock extension on each node in the database you wish to replicate:

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


**Deploying spock Clusters in Containers and with Ansible**

The pgEdge Github sites hosts repositories that contain artifacts that you can use to simplify spock cluster deployment; for more information, visit: 

* [Deploying spock with Ansible](https://github.com/pgEdge/pgedge-ansible)
* [Deploying spock in a Container](https://docs.pgedge.com/container)


### Upgrading

You cannot roll back an upgrade because of changes to the catalog tables; before starting an upgrade, make sure you have a current backup of your cluster so you can recreate the original cluster if needed.

Then, to upgrade the version of spock that you use to manage your replication cluster, you can remove, build, and upgrade the spock extension like you would any other [PostgreSQL extension](https://www.postgresql.org/docs/17/extend-extensions.html#EXTEND-EXTENSIONS-UPDATES).


To review the spock license, visit [here](LICENSE.md).
