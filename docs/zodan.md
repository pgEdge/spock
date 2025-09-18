
## Manually Adding a Node to a Cluster with Zero Downtime

In this tutorial, we'll walk you through the process of adding a fourth node to a three-node cluster.  In our example, our cluster nodes are `n1` (the source node), `n2`, `n3`, and our new node is `n4`.

* The new node should not be accessible to users while adding the node.

* Do not modify your DDL during node addition.

* All nodes in your cluster must be available to the Spock extension for the duration of the addition.

* If the process fails, don't immediately retry a command until you ensure that all artifacts created by the workflow have been removed!

If you are not using `spock.node_create` to create the new node, you will need to: 

* Initialize the new node with [`initdb`](https://www.postgresql.org/docs/17/app-initdb.html).
* Create a Postgres database.
* Create a database user. 
* Follow the instructions at the Github repository to build and install the Spock extension on the database.
* Add `spock` to the `shared_preload_library` parameter in the `postgresql.conf` file.
* Restart the server to update the configuration.
* Then, use the `CREATE EXTENSION spock` command to create the spock extension.

For our example, we'll create and register a new node with the `spock.node_create` command.  In the example:

* Our sample database is named: `inventory`
* Our database user is named: `alice`
* Our password is represented by: `1safepassword`
* The port of `n1` (our source node) is `5432`.
* The port of `n2` (a replica node) is `5433`.
* The port of `n3` (a replica node) is `5434`.
* The port of `n4` (our new node) is `5435`.

In our example, the host dsn is `localhost`; as you replace the host address to suit your own environment, remember that each node must have security and firewall rules that allow communication between each node in the network.

1. On `n4` (the host of our new node), use `spock.node_create` to create and register our new node; the new node will contain an empty database, and the Spock extension is installed:

```sql
    SELECT spock.node_create(
       node_name := 'n4',
        dsn := 'host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword',
        location := 'Los Angeles',
        country := 'USA',
        info := '{"key": "value"}'
    );
```

2. On `n4`, create a **disabled** subscription from `n2` to `n4`. We initially want all of the data on our new node (`n4`) to come from our source node (`n1`), so creating the subscription in a disabled state allows us to prepare for replication without actually moving data between nodes:

```sql
SELECT spock.sub_create(
    sub_name := 'sub_n2_n4',
    provider_dsn := 'host=127.0.0.1 dbname=inventory port=5433 user=alice password=1safepassword',
    replication_sets := ARRAY['default', 'default_insert_only', 'ddl_sql'],
    synchronize_structure := false,
    synchronize_data := false,
    forward_origins := ARRAY[]::text[],
    apply_delay := '0'::interval,
    force_text_transfer := false,
    enabled := false
);
```

3. Next, on `n2` we'll create a replication slot to handle traffic for our new subscription; we do this step for each new disabled subscription we create.  Spock looks for a very specific replication slot name format that includes the name of the database (in our case `inventory`), the node name (`n2`), and the subscription name (`sub_n2_n4`) - our new replication slot is named `spk_inventory_n2_sub_n2_n4`:

```sql
SELECT pg_create_logical_replication_slot(
    'spk_inventory_n2_sub_n2_n4',
    'spock_output'
);
```

Always provide slot names in the form `spk_database-name_node-name_subscription-name` where:

* `spk` is the prefix of the replication slot name.
* `database-name` is the name of your database. 
* `node-name` is the name of the existing replica node.
* `subscription-name` is the subscription name.


4. On `n4`, create a **disabled** subscription from `n3` to `n4`. We initially want all of the data on our new node (`n4`) to come from our source node (`n1`), so creating the subscription in a disabled state allows us to prepare for replication without actually moving data between nodes:

```sql
SELECT spock.sub_create(
    sub_name := 'sub_n3_n4',
    provider_dsn := 'host=127.0.0.1 dbname=inventory port=5434 user=alice password=1safepassword',
    replication_sets := ARRAY['default', 'default_insert_only', 'ddl_sql'],
    synchronize_structure := false,
    synchronize_data := false,
    forward_origins := ARRAY[]::text[],
    apply_delay := '0'::interval,
    force_text_transfer := false,
    enabled := false
);
```

5. Next, on `n3` we'll create a replication slot to handle traffic for our new subscription.  Spock looks for a very specific name format that includes the name of the database (in our case `inventory`), the node name (`n3`), and the subscription name (`sub_n3_n4`) - our new replication slot is named `spk_inventory_n3_sub_n3_n4`:

```sql
SELECT pg_create_logical_replication_slot(
    'spk_inventory_n3_sub_n3_n4',
    'spock_output'
);
```

You need to create a replication slot manually for any subscription that is created in a disabled state.  Create one disabled subscription/replication slot pair for each node in your cluster minus one (the subscription to the source node is created in an enabled state).

6. In the next step, we use a `spock.sync_event` to confirm transactions are caught up on our source node; we want to ensure that all of the transactions from `n3` are part of the `n1` data set:

On `n3`:

```sql
SELECT spock.sync_event();

 sync_event
------------
 0/19F8A58
(1 row)
```
Use the returned value of the sync event when querying the source node; for example,  `spock.sync_event` on `n3` returned `0/19F8A58`, so we use that in the call to `spock.wait_for_sync_event`:

```sql
CALL spock.wait_for_sync_event(true, 'n3', '0/19F8A58'::pg_lsn, 1200000)
```

7. Next, use a `spock.sync_event` to confirm transactions from `n2` are caught up on our provider node: 

On `n2`:

```sql
SELECT spock.sync_event();

 sync_event
------------
 0/1A67F40
(1 row)
```

Use the value returned by `spock.sync_event` in the next call to `spock.wait_for_sync_event` on `n1`:

```sql
CALL spock.wait_for_sync_event(true, 'n2', '0/1A67F40'::pg_lsn, 1200000)
```

Repeat the sync_event and wait_for_sync_event commands between each replica node in your cluster and the source node to ensure that all data is moved to the source node.

8. Then, to start moving data from our source node (`n1`) to our new node (`n4`), we create an **enabled** subscription named (`sub_n1_n4`) on `n4`:

Note that `synchronize_structure`, `synchronize_data`, and `enabled` are `true`.

```sql
SELECT spock.sub_create(
    subscription_name := 'sub_n1_n4',
    provider_dsn := 'host=127.0.0.1 dbname=inventory port=5432 user=alice password=1safepassword',
    replication_sets := ARRAY['default', 'default_insert_only', 'ddl_sql'],
    synchronize_structure := true,
    synchronize_data := true,
    forward_origins := '{}'::text[],
    apply_delay := '0'::interval,
    force_text_transfer := false,
    enabled := true
);
```
Optionally, include the `skip_schema` parameter and a comma-delimited array of schemas that you would like to omit when synchronizing the database structure.  The parameter can be useful in cases where the source machine contains extensions that you do not wish to propagate to other nodes on your network.

The `skip_schema` parameter is only enforced when `synchronize_structure` is set to `true`.  For example:

```sql
synchronize_structure = true,
skip_schema := ARRAY['schema-name-1', 'schema-name-2', 'schema-name-3'],
```

9. Next, we use a `spock.sync_event` to confirm that all of the transactions have been synced from our provider node (`n1`) to our new subscriber node (`n4`):

On `n1`:

```sql
SELECT spock.sync_event();
 sync_event
------------
 0/1A7D1E0
(1 row)
```

Use the value returned by `spock.sync_event` in the call to `spock.wait_for_sync_event` on `n4`:

```sql
CALL spock.wait_for_sync_event(true, 'n4', '0/1A7D1E0'::pg_lsn, 1200000)
```

The last argument in the `spock.wait_for_sync_event` command specifies a timeout value (in our example, 1200000 ms.). You can adjust the timeout to meet your network requirements.

10. Then, on `n4` we check  the `spock.lag_tracker` to confirm that all of the content from `n1` has been replicated:

```sql
SELECT commit_timestamp FROM spock.lag_tracker WHERE origin_name = 'n1' AND receiver_name = 'n4'
```

On `n1`, we check for the last LSN that was received; that transaction should also be present on `n4`:

```sql
WITH lsn_cte AS (SELECT spock.get_lsn_from_commit_ts('spk_inventory_n1_sub_n1_n4', 'timestamp_returned_by_last_command'::timestamp) AS lsn) SELECT pg_replication_slot_advance('spk_inventory_n1_sub_n1_n4', lsn) FROM lsn_cte
```

11. On `n1`, create a subscription (named `sub_n4_n1`) between `n4` and `n1`.  This step prepares our new node to stream transactions received on `n4` to `n1`:  

```sql
    SELECT spock.sub_create(
        sub_name := 'sub_n4_n1',
        provider_dsn := 'host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword',
        replication_sets := ARRAY['default', 'default_insert_only', 'ddl_sql'],
        synchronize_structure := false,
        synchronize_data := false,
        forward_origins := ARRAY[]::text[],
        apply_delay := '0'::interval,
        force_text_transfer := false,
        enabled := true
    );
```

12. On `n2`, create a subscription (named `sub_n4_n2`) between `n4` and `n2`.  This step prepares our new node to stream transactions received on `n4` to `n2`:  

```sql
    SELECT spock.sub_create(
        sub_name := 'sub_n4_n2',
        provider_dsn := 'host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword',
        replication_sets := ARRAY['default', 'default_insert_only', 'ddl_sql'],
        synchronize_structure := false,
        synchronize_data := false,
        forward_origins := ARRAY[]::text[],
        apply_delay := '0'::interval,
        force_text_transfer := false,
        enabled := true
    );
```

13. On `n3`, create a subscription (named `sub_n4_n3`) between `n4` and `n3`. This step prepares our new node to stream transactions received on `n4` to `n3`: 

```sql
    SELECT spock.sub_create(
        sub_name := 'sub_n4_n3',
        provider_dsn := 'host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword',
        replication_sets := ARRAY['default', 'default_insert_only', 'ddl_sql'],
        synchronize_structure := false,
        synchronize_data := false,
        forward_origins := ARRAY[]::text[],
        apply_delay := '0'::interval,
        force_text_transfer := false,
        enabled := true
    );
```

You need to create a new subscription with the new node as a provider and a pre-existing node as the subscriber for each node in your replication cluster (including the source node).

14. Then, on `n4`, we enable the subscription on `n2`; this allows any transactions buffered on `n2` (that came in during the node addition) to replicate to `n4`:

```sql
SELECT spock.sub_enable(
    subscription_name := 'sub_n2_n4',
    immediate := true
);
```

15. Then, on `n4`, we enable the subscription on `n3`; this allows any transactions buffered on `n2` (that came in during the node addition) to replicate to `n4`:

```sql
SELECT spock.sub_enable(
    subscription_name := 'sub_n3_n4',
    immediate := true
);
```

Enable the disabled subscriptions between the new node and each replica node in your cluster except the source node; when creating the subscription for the source node, it is already in an enabled state. 

16. Finally, on `n4`, we can use a SQL command to verify that [replication lag](features.md) is at an acceptable level on all nodes:

``` sql
DO $$
    DECLARE
      lag_n1_n4 interval;
      lag_n2_n4 interval;
      lag_n3_n4 interval;
      BEGIN
        LOOP
          SELECT now() - commit_timestamp INTO lag_n1_n4
            FROM spock.lag_tracker
            WHERE origin_name = 'n1' AND receiver_name = 'n4';
                                        
          SELECT now() - commit_timestamp INTO lag_n2_n4
            FROM spock.lag_tracker
            WHERE origin_name = 'n2' AND receiver_name = 'n4';

          SELECT now() - commit_timestamp INTO lag_n3_n4
            FROM spock.lag_tracker
            WHERE origin_name = 'n3' AND receiver_name = 'n4';
                                                        
          RAISE NOTICE 'n1 → n4 lag: %, n2 → n4 lag: %, n3 → n4 lag: %',
            COALESCE(lag_n1_n4::text, 'NULL'),
            COALESCE(lag_n2_n4::text, 'NULL');
            COALESCE(lag_n3_n4::text, 'NULL');
                                                                                                  
          EXIT WHEN lag_n1_n4 IS NOT NULL AND lag_n2_n4 IS NOT NULL AND lag_n3_n4 IS NOT NULL
            AND extract(epoch FROM lag_n1_n4) < 59
            AND extract(epoch FROM lag_n2_n4) < 59
            AND extract(epoch FROM lag_n3_n4) < 59;
                                                                                                  
          PERFORM pg_sleep(1);
          END LOOP;
        END
    $$;
```

In the clause: `extract(epoch FROM lag_n1_n4) < 59`, 59 represents a 59 second timeout; you can adjust this value for your environment.  This step is optional.  You can always check your [replication lag](features.md) to confirm that it is at an acceptable lag level and adjust your resources as needed. 

