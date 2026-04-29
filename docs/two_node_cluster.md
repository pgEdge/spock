# Using Spock to Create a Two-Node Cluster

After installing and initializing Postgres and creating the Spock Extension, you can use the following steps to configure a two-node cluster.  In the examples that follow, we'll be creating a cluster that contains two nodes, named `n1` and `n2` that listen for Postgres server connections on port `5432`.

1. Connect to each node, and use the following commands to initialize a cluster:

    `sudo /usr/pgsql-17/bin/postgresql-17-setup initdb`

    `sudo systemctl enable postgresql-17`

2. Use your choice of editor to open the `postgresql.conf` file (located in `/var/lib/pgsql/17/data/postgresql.conf`) and add the following parameters to the bottom of the file:

    `wal_level = 'logical'`

    `max_worker_processes = 10`

    `max_replication_slots = 10`

    `max_wal_senders = 10`

    `shared_preload_libraries = 'spock'`

    `track_commit_timestamp = on`

3. Edit the [`pg_hba.conf` file](https://www.postgresql.org/docs/current/auth-pg-hba-conf.html) (located in `/var/lib/pgsql/current/data/postgresql.conf`) and allow connections between `n1` and `n2`; the following commands are provided as an example only, and are not recommended for production systems as they will open your system for connection from any client:

    `host all all 0.0.0.0/0 trust`

    `local replication all trust`

    `host replication all 0.0.0.0/0 trust`

4. Use the [`spock.node_create`](spock_functions/functions/spock_node_create.md) command to create the provider and subscriber nodes; on `n1`, use the command:

    `SELECT spock.node_create (node_name := 'n1', dsn := 'host=<n1_ip_address> port=<n1_port> dbname=<db_name>');`

    On `n2`:

      `SELECT spock.node_create (node_name := 'n2', dsn := 'host=<n2_ip_address> port=<n2_port> =<db_name>');`

5. On `n1`, use the [`spock.repset_add_all_tables`](spock_functions/functions/spock_repset_add_all_tables.md) command to add the tables in the `public` schema to the `default` replication set.  If you are working in another schema, customize this command as needed:

    `SELECT spock.repset_add_all_tables('default', ARRAY['public']);`

6. On n2, use the [`spock.sub_create`](spock_functions/functions/spock_sub_create.md) command to create the subscription between n2 and n1; the name of the subscription is `sub_n2_n1`:

    `SELECT spock.sub_create (subscription_name := 'sub_n2_n1', provider_dsn := 'host=<n1_ip_address> port=<n1 port> dbname=<db_name>');`

    `SELECT spock.sub_wait_for_sync('sub_n2_n1');`

7. On `n1`, create a corresponding subscription to `n2` named `sub_n1_n2`:

    `SELECT spock.sub_create (subscription_name := 'sub_n1_n2', subscriber_dsn := 'host=<n2_ip_address> port=<n2_port> dbname=<db_name>');`

8. To ensure that modifications to your [DDL statements are automatically replicated](managing/spock_autoddl.md), connect to each node with a Postgres client and invoke the following SQL commands:

    `ALTER SYSTEM SET spock.enable_ddl_replication=on;`

    `ALTER SYSTEM SET spock.include_ddl_repset=on;`

    `ALTER SYSTEM SET spock.allow_ddl_from_functions=on;`

    `SELECT pg_reload_conf();`

9. Then, check the status of each node:

```sql
  SELECT * FROM spock.node;
   node_id | node_name | location | country | info
  ---------+-------------+----------+---------+------
   22201 | subscriber1 | | |
   53107 | provider1 | | |
  (2 rows)

  SELECT * FROM spock.sub_show_status();
   subscription_name | status | provider_node | provider_dsn | slot_name | replication_sets | forward_origins
  -------------------+-------------+---------------+------------------------------------------+--------------------------------------+---------------------------------------+-----------------
   subscription1 | replicating | provider1 | host=localhost port=5432 dbname=postgres | spk_postgres_provider1_subscription1 | {default,default_insert_only,ddl_sql} |
  (1 row)
```

A simple test to check that your system is replicating is to connect to the Postgres server on `n1` and add an object (like a table), and then confirm that it is available on `n2`.  Similarly, you can create an object on `n2`, and confirm that it has been created on `n1`.

