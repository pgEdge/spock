# Creating a Spock Cluster: End-to-End Installation Guide

This guide walks you through installing Spock and creating a two-node
active-active replication cluster.

Before you begin, ensure you have met the following prerequisites:

- Each node must be a physical or virtual machine with network connectivity.
- You must have administrative access to both nodes.
- A basic familiarity with PostgreSQL and command-line operations is required.

The installation process follows these steps.

1. Add the pgEdge repository and install pgEdge Postgres with Spock.
2. Configure PostgreSQL parameters for logical replication.
3. Create the Spock extension on both nodes.
4. Set up node definitions and bidirectional subscriptions.
5. Enable automatic DDL replication across the cluster.
6. Test the cluster to verify bidirectional replication works correctly.

## Install pgEdge Enterprise Postgres (Recommended Path)

This section describes how to install pgEdge Enterprise Postgres with
Spock using the pgEdge repository.

First, on each node, add the pgEdge repository to your system. 

For RHEL/Rocky Linux/AlmaLinux 10, first install EPEL:

```bash
sudo dnf -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm
```

On RHEL 10, also enable the CodeReady Builder repository:

```bash
sudo subscription-manager repos --enable codeready-builder-for-rhel-10-$(arch)-rpms
```

On Rocky Linux 10 or AlmaLinux 10, enable the equivalent CRB repository instead:

```bash
sudo dnf config-manager --set-enabled crb
```

Version-specific commands for RHEL, OEL, Alma, and Rocky are available in the 
[pgEdge Enterprise Postgres documentation](https://docs.pgedge.com/enterprise/el/configure-repo/).

For Ubuntu/Debian:

Before configuring local access to the pgedge repository, you should ensure that your system does 
not contain any community Postgres packages. Then, install the platform-specific prerequisites 
for your system with the commands:

```bash
sudo apt-get update
sudo apt-get install -y curl
sudo apt-get install -y gnupg2
sudo apt-get install -y lsb-release
```

Then, create the repository with the commands:

```bash
sudo curl -sSL https://apt.pgedge.com/repodeb/pgedge-release_latest_all.deb -o /tmp/pgedge-release.deb
sudo dpkg -i /tmp/pgedge-release.deb
sudo rm -f /tmp/pgedge-release.deb
sudo apt update
```

!!! note

    For detailed information about using the pgEdge repository, see the 
    [pgEdge Enterprise Postgres documentation](https://docs.pgedge.com/enterprise/).


After creating the repository, install your preferred PostgreSQL version.
The examples use PostgreSQL 18, but you can substitute 15, 16, or 17.

For RHEL/Rocky Linux/AlmaLinux:

```bash
sudo dnf install -y pgedge-postgres18-server pgedge-postgres18-contrib pgedge-spock18
```

For Ubuntu/Debian:

```bash
sudo apt install -y pgedge-postgres18-server pgedge-postgres18-contrib pgedge-spock18
```

On each node, initialize the PostgreSQL database cluster.

For RHEL/Rocky Linux/AlmaLinux:

```bash
sudo /usr/pgsql-18/bin/postgresql-18-setup initdb
sudo systemctl enable postgresql-18
sudo systemctl start postgresql-18
```

For Ubuntu/Debian:

```bash
sudo /usr/lib/postgresql/18/bin/initdb -D /var/lib/postgresql/18/data
sudo systemctl enable postgresql-18
sudo systemctl start postgresql-18
```

In the following example, the `psql` command connects to PostgreSQL to
verify the installation:

```bash
sudo -u postgres psql -U postgres -p 5432
```

Once connected, confirm that you can see the configuration file locations.

In the following example, the `SHOW` commands display the PostgreSQL
configuration file locations:

```sql
postgres=# SHOW data_directory;
     data_directory
------------------------
 /var/lib/pgsql/18/data
(1 row)

postgres=# SHOW config_file;
              config_file
----------------------------------------
 /var/lib/pgsql/18/data/postgresql.conf
(1 row)

postgres=# SHOW hba_file;
              hba_file
------------------------------------
 /var/lib/pgsql/18/data/pg_hba.conf
(1 row)
```

The pgEdge Enterprise Postgres installation automatically includes the
following components:

- The latest minor version of your chosen Postgres version.
- The Spock extension (pre-installed, ready to enable).
- Spock functions and procedures.
- ACE consistency monitoring.
- Snowflake sequences.
- pgBackRest for simplified backup and restore.
- LOLOR large object support.
- Management tools for active-active distributed clusters.

## Install from Source (Alternative Path)

If you need to build Spock from source instead of using pgEdge Enterprise
Postgres, follow these steps.

1. Download PostgreSQL source code from the [Postgres project](https://www.postgresql.org/ftp/source/)
    and navigate to the source directory.

2. Clone the Spock repository with the following command:

    ```bash
    git clone https://github.com/pgEdge/spock.git
    ```

3. Apply the version-specific patches with the following command:

    ```bash
    patch -p1 < spock/patches/version/patch_name
    ```

4. Configure, build, and install PostgreSQL as described in the
    [Postgres documentation](https://www.postgresql.org/docs/current/installation.html).

5. Add the `pg_config` file location to your PATH with this command:

    ```bash
    export PATH=path_to_pg_config_file
    ```

6. Install the [jansson library](https://jansson.readthedocs.io/en/1.1/gettingstarted.html)
    (required for Spock).

7. Build and install Spock with the following commands:

    ```bash
    cd spock
    make
    make install
    ```

Repeat the installation process on both nodes.

After building from source, use [initdb](https://www.postgresql.org/docs/18/app-initdb.html)
to initialize a PostgreSQL cluster on each node.

## Configure PostgreSQL for Spock Replication

On each node, edit the `postgresql.conf` file and add the required
parameters to the end of the file.

In the following example, the configuration parameters enable logical
replication and load the Spock extension:

```sql
 wal_level = logical
max_worker_processes = 10   # one per database on provider, one per node on subscriber
max_replication_slots = 10  # one per node on provider
max_wal_senders = 10        # one per node on provider
shared_preload_libraries = 'spock'
track_commit_timestamp = on # needed for conflict resolution
listen_addresses = '*'
```

!!! note

    - PostgreSQL 15-17: The `max_replication_slots` parameter controls
      both slots and replication origin states. Account for both when
      sizing (typically one origin per subscription).

    - PostgreSQL 18+: A new parameter `max_active_replication_origins`
      separately controls origin states. The default value is 10, which
      may be insufficient. Set the value to at least the number of
      subscriptions plus headroom.

After modifying `postgresql.conf`, restart PostgreSQL using your
OS-specific command.

In the following example, the `systemctl` commands restart and verify
the PostgreSQL service:

```bash
sudo systemctl restart postgresql-18
sudo systemctl status postgresql-18
```

Verify the service is active and running.

On each node, modify the [`pg_hba.conf`](https://www.postgresql.org/docs/18/auth-pg-hba-conf.html)
file to allow connections between the nodes.

Add entries for both regular and replication connections. Replace
`<node_1_IP_address>` and `<node_2_IP_address>` with your actual IP
addresses.

In the following example, the configuration entries allow connections
from both nodes:

```conf
# Regular connections
host    all          all          <node_1_IP_address>/32    trust
host    all          all          <node_2_IP_address>/32    trust
host    all          all          <subnet_address>/24     trust

# Replication connections
host    replication  all          <node_1_IP_address>/32    trust
host    replication  all          <node_2_IP_address>/32    trust
```

!!! warning

    The example above uses `trust` authentication for simplicity and is
    not recommended for production systems. In production, use
    appropriate authentication methods like `scram-sha-256` or `md5`.

After modifying `pg_hba.conf`, reload the server configuration to apply the
changes (no restart required):

```sql
SELECT pg_reload_conf();
```

## Create the Spock Extension

On each node, connect to PostgreSQL and create the Spock extension.

In the following example, the `CREATE EXTENSION` command creates the
Spock extension:

```sql
sudo -u postgres psql -U postgres -p 5432

postgres=# CREATE EXTENSION spock;
CREATE EXTENSION
postgres=#
```

!!! warning

    Spock uses the `spock` schema to provide replication functionality.
    Do not delete, create, or modify files in the `spock` schema
    directly. Use Spock functions and procedures to manage replication.

## Create Nodes and Configure Replication

This section describes how to set up bidirectional replication between the two nodes.
For this guide, the nodes are named `n1` and `n2`.

### On Node 1 (n1)

Follow these steps to create the node definition and add tables to the
replication set.

1. Create the node definition with the following command:

    ```sql
    SELECT spock.node_create(
        node_name := 'n1',
        dsn := 'host=<n1_ip_address> port=<n1_port> dbname=<db_name>'
    );
    ```

2. Add tables to the default replication set with this command:

    ```sql
    SELECT spock.repset_add_all_tables('default', ARRAY['public']);
    ```

    If you are working in a schema other than `public`, adjust the schema
    name accordingly.

### On Node 2 (n2)

Follow these steps to create the node definition, add tables, and create
the subscription.

1. Create the node definition with the following command:

    ```sql
    SELECT spock.node_create(
        node_name := 'n2',
        dsn := 'host=<n2_ip_address> port=<n2_port> dbname=<db_name>'
    );
    ```

2. Add tables to the default replication set with this command:

    ```sql
    SELECT spock.repset_add_all_tables('default', ARRAY['public']);
    ```

3. Create the subscription from n2 to n1 with these commands:

    ```sql
    SELECT spock.sub_create(
        subscription_name := 'sub_n2_n1',
        provider_dsn := 'host=<n1_ip_address> port=<n1_port> dbname=<db_name>'
    );

    SELECT spock.sub_wait_for_sync('sub_n2_n1');
    ```

### On Node 1 (n1)

Create the reverse subscription from n1 to n2 with the following commands:

```sql
SELECT spock.sub_create(
    subscription_name := 'sub_n1_n2',
    provider_dsn := 'host=<n2_ip_address> port=<n2_port> dbname=<db_name>'
);

SELECT spock.sub_wait_for_sync('sub_n1_n2');
```

### On Both Nodes (n1 and n2)

To ensure DDL statements are automatically replicated across your cluster,
run these commands on both nodes.

In the following example, the `ALTER SYSTEM` commands enable automatic
DDL replication:

```sql
ALTER SYSTEM SET spock.enable_ddl_replication = on;
ALTER SYSTEM SET spock.include_ddl_repset = on;
SELECT pg_reload_conf();
```

These settings enable the following features:

- DDL statements are automatically replicated through the default replication set.
- New tables are automatically added to replication sets; tables with primary keys are added to the default set, and tables without primary keys are added to the default_insert_only set.

## Verify the Cluster

On each node, use the following command to verify that nodes are properly
configured.

In the following example, the `SELECT` command displays the configured
nodes:

```sql
SELECT * FROM spock.node;
```

Expected output:

```sql
postgres=# SELECT * FROM spock.node;
-[ RECORD 1 ]----
node_id   | 26863
node_name | n2
location  |
country   |
info      |
-[ RECORD 2 ]----
node_id   | 49708
node_name | n1
location  |
country   |
info      |

```

Then, use the following command to verify that subscriptions are active
and replicating.

In the following example, the `SELECT` command displays the subscription
status:

```sql
SELECT * FROM spock.sub_show_status();
```

Expected output:

```sql
 postgres=# SELECT * FROM spock.sub_show_status();
-[ RECORD 1 ]-----+--------------------------------------------------------------------
subscription_name | sub_n1
status            | replicating
provider_node     | n2
provider_dsn      | host=192.168.105.11 dbname=postgres user=postgres password=password
slot_name         | spk_postgres_n2_sub_n1
replication_sets  | {default,default_insert_only,ddl_sql}
forward_origins   |
```

The `status` field should display `replicating`.

## Test Replication

Perform a simple replication test using the following steps.

1. On n1, create a test table with the following commands:

    ```sql
    CREATE TABLE test (
        id SERIAL PRIMARY KEY,
        message TEXT
    );

    INSERT INTO test (message) VALUES ('Hello from n1');
    ```

2. On n2, verify the table exists and contains the data with this query:

    ```sql
    SELECT * FROM test;
    ```

    Expected output:

    ```sql
    postgres=# SELECT * FROM test;
    -[ RECORD 1 ]------
    id      | 1
    message | Hello from n1
    ```

3. On n2, insert a new row with the following command:

    ```sql
    INSERT INTO test (message) VALUES ('Hello from n2');
    ```

4. On n1, verify both rows are present with this query:

    ```sql
    SELECT * FROM test;
    ```

    Expected output:

    ```sql
    postgres=# SELECT * FROM test;
    -[ RECORD 1 ]------
    id      | 1
    message | Hello from n1
    -[ RECORD 2 ]------
    id      | 2
    message | Hello from n2
    ```

Both messages should appear on both nodes, confirming that bidirectional replication is working.

## Next Steps

Your two-node Spock cluster is now operational. The following documents describe the next steps for configuring and managing the cluster.

- The [Configuring Spock](configuring.md) document describes conflict resolution settings and advanced configuration options.
- The [Spock Functions Reference](spock_functions/index.md) document provides detailed information about monitoring functions and replication management.
- The [Managing DDL Replication](managing/spock_autoddl.md) document explains how to control automatic DDL replication behavior.

## Troubleshooting

If you encounter issues, review the following common problems and solutions.

- Check the `pg_hba.conf` entries and ensure the nodes can connect to each other if replication is not starting.
- Verify that `max_replication_slots` and `max_wal_senders` are set to sufficient values when a subscription is stuck initializing.
- If DDL is not replicating, confirm that the automatic DDL replication settings are enabled on both nodes.
- If errors are not clear, review the PostgreSQL logs for detailed error messages.

For more information, see the following resources:

- The [Spock Functions Reference](spock_functions/index.md) document provides detailed function documentation.
- The [Advanced Configuration Options](configuring.md) document describes additional configuration parameters.
- The [Managing DDL Replication](managing/spock_autoddl.md) document explains DDL replication features.
