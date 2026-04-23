# Upgrading the Spock Extension

!!! note
    If you build the Spock extension from source, you can remove, build,
    and upgrade the Spock extension like you would any other 
    [Postgres extension](https://www.postgresql.org/docs/17/extend-extensions.html#EXTEND-EXTENSIONS-UPDATES).

If you're upgrading a secure production environment, shut down each node
sequentially and perform the following steps:

1. Disable auto-DDL.
2. Stop the Postgres server.
3. Build the updated Spock binaries for your Postgres version.
4. Restart the Postgres server; this will trigger an automatic update of the
   binary if a newer binary is available.
5. Use the psql command line to verify the Spock version in use and the node
   status.
6. After upgrading all of the nodes in your cluster, enable Auto-DDL and
   restart the service on each node.

A detailed description of each step in the upgrade process is provided below.

## Disabling Auto-DDL

Before stopping a node, disable DDL replication to prevent schema changes
during the upgrade. Connect to each node and run:

```sql
SELECT spock.replicate_ddl('ALTER SYSTEM SET spock.enable_ddl_replication = off');
SELECT pg_reload_conf();
```

Or, set the following parameter in `postgresql.conf` on each node:

```
spock.enable_ddl_replication = off
```

Then, reload the configuration:

```sql
SELECT pg_reload_conf();
```

!!! warning
    This step is essential if old and new versions are incompatible.

## Stopping the Postgres Server

Before upgrading the Spock binary, stop the Postmaster on the server that
you're working on:

```bash
pg_ctl -D /path/to/data1 stop -m fast
```

!!! warning
    This step is essential if old and new versions are incompatible.

## Building the New Spock Binaries

Before building the extension, you'll need to obtain updated Spock source
code. If you regularly build the Spock extension from source code (available
at https://github.com/pgEdge/spock), use git to obtain an updated source set;
then:

```bash
cd /path/to/spock-5.0.1
make clean
make
sudo make install
```

The installation copies the following files:

- `spock.so` → `$(pg_config --pkglibdir)/`;
- `spock.control` → `$(pg_config --sharedir)/extension/`;
- `spock--5.0.1.sql` and `spock--5.0.0--5.0.1.sql` → `$(pg_config --sharedir)/extension/`.

Next, you should verify that the updated Spock files are installed. You can
use the following commands to confirm the version update.

Check the library timestamp:

```bash
ls -l $(pg_config --pkglibdir)/spock.so
```

Check the control file:

```bash
ls -l $(pg_config --sharedir)/extension/spock.control
```

Check that an upgraded .sql file exists; for example:

```bash
ls -l $(pg_config --sharedir)/extension/spock--5.0.0--5.0.1.sql
```

## Restarting the Postgres Server

Then, use pg_ctl to restart the Postgres postmaster
process:

```bash
pg_ctl -D /path/to/data1 start
```

When the server restarts, Spock's database manager background worker
automatically detects the version mismatch and upgrades the extension schema
(with `spock_manage_extension()` in `spock.c`).


## Verifying the Extension Upgrade

After building the extension, you can verify the version of the extension that
is in use and the state of your replication cluster.  Use the psql command
line to invoke the commands that follow.

Connect to the database with psql:

```bash
psql -d database_name -p port_number
```

Verify the Spock version that is in use:

```sql
SELECT extname, extversion FROM pg_extension WHERE extname = 'spock';
```

Then, verify that the node is replicating. Check that subscriptions are 
active with the following commands:

```sql
SELECT sub_name, sub_enabled, sub_slot_name, sub_replication_sets
FROM spock.subscription;
```

Check the replication slots:

```sql
SELECT slot_name, active, restart_lsn FROM pg_replication_slots;
```

Check the node status:

```sql
SELECT * FROM spock.node;
```

## Enabling Auto-DDL and Restarting the Service on Each Node

After upgrading all of the nodes in your cluster, connect to each node with
psql and enable DDL replication:

```sql
ALTER SYSTEM SET spock.enable_ddl_replication = on;
SELECT pg_reload_conf();
```

Or you can modify the parameter in the `postgresql.conf` file:

```
spock.enable_ddl_replication = on
```

Reload the configuration:

```sql
SELECT pg_reload_conf();
```

Then, on each node, restart the service:

```bash
pg_ctl -D /path/to/data1 start
```

## Final Verification

After performing the steps listed above on each server in the cluster, use
the following command to verify the replication status of each node:

```sql
SELECT application_name, state, sync_state, write_lag, flush_lag, replay_lag
FROM pg_stat_replication;
```

You should confirm that:

- all nodes report consistent versions (5.0.1).
- replication lag is minimal or zero.
- no errors appear in PostgreSQL or Spock logs.




