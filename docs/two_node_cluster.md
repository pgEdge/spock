# Using Spock to Create a Two-Node Cluster

After installing Postgres, you can use the following steps to create the 
Spock extension and configure a two-node cluster.  In the
examples that follow, we'll be creating a cluster that contains two nodes,
named `n1` and `n2` that listen for Postgres server connections on port
`5432`.


    ```sql
    sudo /usr/pgsql-17/bin/postgresql-17-setup initdb
    sudo systemctl enable postgresql-17
    ```

!!! hint

    SELECT version(); SHOW data_directory; SHOW config_file;

1. After installing Postgres and initializing a cluster, on each node, use 
   your choice of editor to open the `postgresql.conf` file and add the 
   following parameters to the bottom of the file:

    ```sql
    wal_level = 'logical'
    max_worker_processes = 10
    max_replication_slots = 10
    max_wal_senders = 10
    shared_preload_libraries = 'spock'
    track_commit_timestamp = on
    ```

2. On each node that will host spock, edit the 
   [`pg_hba.conf` file](https://www.postgresql.org/docs/current/auth-pg-hba-conf.html)
   (located in `/var/lib/pgsql/17/data/pg_hba.conf`) and allow
   connections between `n1` and `n2`. The following commands are provided as
   an example only, and are not recommended for production systems as they
   will open your system for connection from any client:

    ```sql
    host    all          all          <node_1_IP_address>/32    trust
    host    all          all          <node_2_IP_address>/32    trust

    host    replication  all          <node_1_IP_address>/32    trust
    host    replication  all          <node_2_IP_address>/32    trust
    ```

3. Use your platform-specific command to restart the server on each node.

4. Then, on each node, connect to the Postgres server with psql and create the
   spock extension:
   
    ```sql
    CREATE EXTENSION spock;
    ```

5. Then, use the
   [`spock.node_create`](spock_functions/functions/spock_node_create.md)
   command to create the provider and subscriber nodes; on node `n1`:

    ```sql
    SELECT spock.node_create 
        (node_name := 'n1', 
        dsn :='host=<node_1_IP_address> port=<n1_port> dbname=<db_name>');
    ```

    On `n2`:

    ```sql
    SELECT spock.node_create (node_name := 'n2', 
           dsn :='host=<node_2_IP_address> port=<n2_port> dbname=<db_name>');`
    ```

6. On `n1`, use the
   [`spock.repset_add_all_tables`](spock_functions/functions/spock_repset_add_all_tables.md)
   command to add the tables in the `public` schema to the `default`
   replication set.  If you are working in another schema, customize this
   command as needed:

    ```sql
    SELECT spock.repset_add_all_tables('default', ARRAY['public']);
    ```

7. On n2, use the following commands
   to create the subscription between n2 and n1 and wait for the subscription
   to sync; the name of the subscription is `sub_n2_n1`:

    ```sql
    SELECT spock.sub_create (subscription_name := 'sub_n2_n1',
        provider_dsn := 'host=<node_1_IP_address> port=<n1_port> dbname=<db_name>');

    SELECT spock.sub_wait_for_sync('sub_n2_n1');
    ```

8.  On `n1`, create a corresponding subscription to `n2` named `sub_n1_n2`:

    ```sql
    SELECT spock.sub_create (subscription_name := 'sub_n1_n2',
        subscriber_dsn := 'host=<node_2_IP_address> port=<n2_port> dbname=<db_name>');
    ```

9.  To ensure that modifications to your [DDL statements are automatically
   replicated](managing/spock_autoddl.md), connect to each node with a
   Postgres client and invoke the following SQL commands:

    ```sql
    ALTER SYSTEM SET spock.enable_ddl_replication=on;
    ALTER SYSTEM SET spock.include_ddl_repset=on;
    ALTER SYSTEM SET spock.allow_ddl_from_functions=on;
    SELECT pg_reload_conf();
    ```

10. Then, check the status of each node:

    ```sql
    SELECT * FROM spock.node;
     node_id | node_name | location | country | info
    ---------+-------------+----------+---------+------
     22201 | subscriber1 | | |
     53107 | provider1 | | |
    (2 rows)

    SELECT * FROM spock.sub_show_status();
     subscription_name | status | provider_node | provider_dsn |
     slot_name | replication_sets | forward_origins
    -------------------+-------------+---------------+--------------+
    -------------+----------------------+-----------------
     subscription1 | replicating | provider1 | host=localhost
     port=5432 dbname=postgres | spk_postgres_provider1_subscription1 |
     {default,default_insert_only,ddl_sql} |
    (1 row)
    ```

A simple test to check that your system is replicating is to connect to the
Postgres server on `n1` and add an object (like a table), and then confirm
that it is available on `n2`.  Similarly, you can create an object on `n2`,
and confirm that it has been created on `n1`.

