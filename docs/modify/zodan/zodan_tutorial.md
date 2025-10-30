# Tutorial - Adding a Node to a Cluster with Zero Downtime

In this detailed walk through, we'll add a fourth node to a three-node cluster with zero downtime. In our example, our cluster nodes are `n1` (the source node), `n2`, `n3`, and our new node is `n4`.

!!! Warning

    **Important Prerequisites and Warnings**

        - The new node should not be accessible to users while adding the node.
        - Disable `auto_ddl` on all cluster nodes.
        - Do not modify your DDL during node addition.
        - The users must be identical on the source and target node. You must create any users on the target node
          before proceeding; the permissions must be *identical* for all users on both the source and target nodes.
          The ZODAN process now validates that all users from the source node exist on the new node before proceeding
          with cluster addition. This prevents replication failures caused by missing user permissions.
        - The spock configuration must be *identical* on both the source and the target node.
        - All nodes in your cluster must be available to the Spock extension for the duration of the node addition.
        - The procedure should be performed on the new node being added
        - The dblink extension must be installed on the new node from which commands like `SELECT spock.add_node()` are being run
        - Prepare the new node to meet the prerequisites described here.
    
    If the process fails, don't immediately retry a command until you ensure that all artifacts created by the workflow have been removed!

**Creating a Node Manually**

If you are not using `spock.node_create` to create the new node, you will need to:

- Initialize the new node with `initdb`
- Create a database
- Create a database user
- Follow the instructions at the [Github repository](https://github.com/pgEdge/spock) to build and install the Spock extension on the database
- Add `spock` to the `shared_preload_library` parameter in the `postgresql.conf` file
- Restart the server to update the configuration
- Then, use the `CREATE EXTENSION spock` command to create the spock extension

**Sample Configuration and New Node Creation Steps**

In our example, the details about our cluster configuration are:

- Database: `inventory`
- User: `pgedge`
- Password: `1safepassword`
- n1 (source): port 5432
- n2 (replica): port 5433
- n3 (replica): port 5434
- n4 (new node): port 5435
- Host: 127.0.0.1

The steps used to configure our new node (n4) are:

```bash
# Initialize database
initdb -D /path/to/data

# Start PostgreSQL
pg_ctl -D /path/to/data start

# Create database and user
psql -c "CREATE DATABASE inventory;"
psql -c "CREATE USER pgedge WITH PASSWORD '1safepassword';"
psql -c "GRANT ALL ON DATABASE inventory TO pgedge;"

# Install Spock extension
psql -d inventory -c "CREATE EXTENSION spock;"
psql -d inventory -c "CREATE EXTENSION dblink;"
```

**Using the Z0DAN Procedure to Add a Node** 

After creating the node, you can use Z0DAN scripts to simplify adding a node to a cluster. To use the SQL script, connect to the new node that you wish to add to the pgedge cluster:
```bash
psql -h 127.0.0.1 -p 5432 -d inventory -U pgedge
```

Load the ZODAN procedures:
```sql
\i /path/to/zodan.sql
```

Then, use `spock.add_node()` from the new node to create the node definition:

```sql
CALL spock.add_node(
    src_node_name := 'n1',
    src_dsn := 'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
    new_node_name := 'n4',
    new_node_dsn := 'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    verb := true,
    new_node_location := 'Los Angeles',
    new_node_country := 'USA',
    new_node_info := '{"key": "value"}'::jsonb
);
```

The `spock.add_node` function executes the steps required to add a node to the cluster; a detailed explanation of the steps performed follows below.

Should a problem occur during this process, you can source the `zodremove.sql` script and call the `spock.remove_node` procedure to remove the node or reverse partially completed steps. `spock.remove_node` should be called on the node being removed.

## Manually adding a Node to a Cluster

The steps that follow outline the process the Z0DAN procedure goes through when adding a node.  You can manually perform the same steps to add a node to a cluster instead of using `spock.add_node` above.

### Check the Spock Version Compatibility

!!! info

    Before starting the node addition, verify that all nodes (n1, n2, n3, and n4) are running the exact same version of Spock.  This prevents compatibility issues during replication setup.  
    
    If any node has a different version, the process will abort with an error.

On the orchestrator node:

```sql
-- Check source node version
SELECT extversion 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
    'SELECT extversion FROM pg_extension WHERE extname = ''spock'''
) AS t(version text);
-- Expected: 6.0.0-devel

-- Check new node version
SELECT extversion 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'SELECT extversion FROM pg_extension WHERE extname = ''spock'''
) AS t(version text);
-- Expected: 6.0.0-devel

-- Check all existing cluster nodes (n2, n3)
SELECT node_name, version
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5432 user=alice password=1safepassword',
    'SELECT n.node_name, 
            (SELECT extversion FROM pg_extension WHERE extname = ''spock'') as version
     FROM spock.node n'
) AS t(node_name text, version text);

-- Expected output:
--  node_name |   version    
-- -----------+--------------
--  n1        | 6.0.0-devel
--  n2        | 6.0.0-devel
--  n3        | 6.0.0-devel
```

### Validate Prerequisites

!!! info

    Perform safety checks to ensure node `n4` is a clean slate:

        - n4 must have the database and Spock extension installed.
        - n4 must have no user data or existing replication configuration.
        - Verify that a node named n4 doesn't already exist in the cluster.

    If any prerequisite fails, the process aborts to prevent conflicts.

**Confirm that the database exists on n4**

Try to connect to the database on n4. If this fails, the database doesn't exist and needs to be created first.

```sql
SELECT 1 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword',
    'SELECT 1'
) AS t(dummy int);
-- If no error, database exists
```

**Confirm that n4 has no user-created tables**

The new node must be empty - there can be no user tables in user schemas (system tables and extension tables are OK). If user tables exist, ZODAN will abort because syncing would overwrite existing data.

```sql
SELECT count(*) 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword',
    'SELECT count(*) FROM pg_tables 
     WHERE schemaname NOT IN (''information_schema'', ''pg_catalog'', ''pg_toast'', ''spock'')
     AND schemaname NOT LIKE ''pg_temp_%''
     AND schemaname NOT LIKE ''pg_toast_temp_%'''
) AS t(count integer);
-- Expected: 0
```

**Confirm that n4 doesn't exist in the cluster**

Check if a node with the name n4 is already registered in the cluster. If it exists, ZODAN aborts to prevent duplicate node names.

```sql
-- On orchestrator node (connected to n1)
SELECT count(*) FROM spock.node WHERE node_name = 'n4';
-- Expected: 0
```

**Confirm that n4 contains no subscriptions**

```sql
SELECT count(*) 
FROM spock.subscription s 
JOIN spock.node n ON s.sub_origin = n.node_id 
WHERE n.node_name = 'n4';
-- Expected: 0
```

**Confirm that n4 contains no replication sets**

```sql
SELECT count(*) 
FROM spock.replication_set rs 
JOIN spock.node n ON rs.set_nodeid = n.node_id 
WHERE n.node_name = 'n4';
-- Expected: 0
```

### Create a Replication Node on n4

!!! info

    In this step, you will create a Spock node object on n4:

        - This registers n4 as a participant in the replication cluster.
        - Think of it like giving n4 an ID badge that says "I'm part of this cluster now".
        
    After this step, n4 is visible in the spock.node table on all nodes

**Create a node on n4**

Using `dblink`, we connect to n4 and run `spock.node_create()` to register the node. The DSN tells other nodes how to connect to n4.

```sql
-- Via dblink to n4
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword',
    'SELECT spock.node_create(
        node_name := ''n4'',
        dsn := ''host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword'',
        location := ''Los Angeles'',
        country := ''USA'',
        info := ''{\"key\": \"value\"}''::jsonb
    )'
) AS t(node_id oid);

-- Expected output:
--  node_id 
-- ---------
--    16389
```

**Confirm the initial node count**

```sql
SELECT count(*) 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5432 user=alice password=1safepassword',
    'SELECT count(*) FROM spock.node'
) AS t(count integer);
-- Expected: 4 (n1, n2, n3, n4)
```


### Create Disabled Subscriptions and Slots

!!! info

    This is the critical "bookmarking" stage; during this stage, we'll:

        - Create subscriptions from n2→n4 and n3→n4, but keep them DISABLED.
        - Before creating each subscription, trigger a sync_event() which returns an LSN (log sequence number).  You can think of the LSN as a bookmark in the replication stream.
        - Save these bookmarks in a temporary table for later use.
        - When enabling these subscriptions later, transactions will start from exactly the right position.  This ensures no data is missed or duplicated.
        - Subscriptions remain disabled because n4 should get ALL its initial data from n1 (the source) in one clean sync.
        
    The n2→n4 and n3→n4 subscriptions are just being prepared now, but won't start moving data until later


**Identify all existing nodes**

Query the cluster to find all of the nodes (n1, n2, n3, n4) and their connection strings.

```sql
SELECT n.node_name, i.if_dsn 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5432 user=alice password=1safepassword',
    'SELECT n.node_name, i.if_dsn 
     FROM spock.node n 
     JOIN spock.node_interface i ON n.node_id = i.if_nodeid'
) AS t(node_name text, if_dsn text);

-- Expected output:
--  node_name |                              if_dsn                              
-- -----------+------------------------------------------------------------------
--  n1        | host=127.0.0.1 dbname=inventory port=5432 user=alice password=...
--  n2        | host=127.0.0.1 dbname=inventory port=5433 user=alice password=...
--  n3        | host=127.0.0.1 dbname=inventory port=5434 user=alice password=...
--  n4        | host=127.0.0.1 dbname=inventory port=5435 user=alice password=...
```

**For n2 → n4 (Trigger sync event on n2 and store LSN)**

We call `sync_event()` on n2, which inserts a special marker into n2's replication stream and returns the LSN where it was inserted. We store this LSN (0/1A7D1E0) in a temp table. Later, when we enable the sub_n2_n4 subscription, we'll use this stored LSN to ensure the subscription starts from exactly this point - guaranteeing no data loss.

```sql
-- Trigger sync event on n2
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5433 user=alice password=1safepassword',
    'SELECT spock.sync_event()'
) AS t(sync_lsn pg_lsn);
-- Returns: 0/1A7D1E0

-- Store in temp table
CREATE TEMP TABLE IF NOT EXISTS temp_sync_lsns (
    origin_node text PRIMARY KEY,
    sync_lsn text NOT NULL
);

INSERT INTO temp_sync_lsns (origin_node, sync_lsn)
VALUES ('n2', '0/1A7D1E0')
ON CONFLICT (origin_node) DO UPDATE SET sync_lsn = EXCLUDED.sync_lsn;
```

**Create a replication slot on n2**

A replication slot is like a queue that holds all changes from n2 that need to be sent to n4. Even though the subscription is *disabled*, the slot starts collecting changes immediately. This ensures no data is lost between now and when we enable the subscription.

```sql
-- On n2
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5433 user=alice password=1safepassword',
    'SELECT slot_name, lsn 
     FROM pg_create_logical_replication_slot(
         ''spk_inventory_n2_sub_n2_n4'',
         ''spock_output''
     )'
) AS t(slot_name text, lsn pg_lsn);

-- Expected output:
--         slot_name         |    lsn     
-- --------------------------+------------
--  spk_inventory_n2_sub_n2_n4 | 0/1A7D1E8
```

**Create disabled subscription on n4 from n2**

We create the subscription object on n4, but with `enabled := false`. This tells n4 *you will eventually subscribe to n2, but not yet*. The subscription knows about the slot on n2 but isn't actively pulling data yet.

```sql
-- On n4
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword',
    'SELECT spock.sub_create(
        subscription_name := ''sub_n2_n4'',
        provider_dsn := ''host=127.0.0.1 dbname=inventory port=5433 user=alice password=1safepassword'',
        replication_sets := ARRAY[''default'', ''default_insert_only'', ''ddl_sql''],
        synchronize_structure := false,
        synchronize_data := false,
        forward_origins := ARRAY[]::text[],
        apply_delay := ''0''::interval,
        enabled := false,
        force_text_transfer := false,
        skip_schema := ARRAY[]::text[]
    )'
) AS t(subscription_id oid);
```

**Repeat the previous steps for n3 → n4**

```sql
-- Trigger sync event on n3
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5434 user=alice password=1safepassword',
    'SELECT spock.sync_event()'
) AS t(sync_lsn pg_lsn);
-- Returns: 0/1B8E2F0

-- Store LSN
INSERT INTO temp_sync_lsns (origin_node, sync_lsn)
VALUES ('n3', '0/1B8E2F0')
ON CONFLICT (origin_node) DO UPDATE SET sync_lsn = EXCLUDED.sync_lsn;

-- Create replication slot on n3
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5434 user=alice password=1safepassword',
    'SELECT slot_name, lsn 
     FROM pg_create_logical_replication_slot(
         ''spk_inventory_n3_sub_n3_n4'',
         ''spock_output''
     )'
) AS t(slot_name text, lsn pg_lsn);

-- Create disabled subscription on n4 from n3
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword',
    'SELECT spock.sub_create(
        subscription_name := ''sub_n3_n4'',
        provider_dsn := ''host=127.0.0.1 dbname=inventory port=5434 user=alice password=1safepassword'',
        replication_sets := ARRAY[''default'', ''default_insert_only'', ''ddl_sql''],
        synchronize_structure := false,
        synchronize_data := false,
        forward_origins := ARRAY[]::text[],
        apply_delay := ''0''::interval,
        enabled := false,
        force_text_transfer := false,
        skip_schema := ARRAY[]::text[]
    )'
) AS t(subscription_id oid);
```

### Configure Cross-Node Replication

!!! info

    Now we'll prepare for replication directing the data flow *FROM* n4 TO the replica nodes (n2, n3):

        - Create replication slots on n2 and n3 that will hold changes from n4.
        - These slots will be used later when creating subscriptions for n2 and n3 to receive data from n4.
        - We create these slots early so they start buffering any changes from n4 immediately, even before the subscriptions are created.
    
    This prevents data loss if n4 receives writes during the setup process.


**Create a slot on n2 for a future subscription (sub_n4_n2)**

Create a replication slot on n2 named `spk_inventory_n2_sub_n4_n2`. This slot will queue up changes from n4 that need to be sent to n2. The slot is ready, but there's no subscription using it yet - that comes later.

```sql
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5433 user=alice password=1safepassword',
    'SELECT slot_name, lsn 
     FROM pg_create_logical_replication_slot(
         ''spk_inventory_n2_sub_n4_n2'',
         ''spock_output''
     )'
) AS t(slot_name text, lsn pg_lsn);
```

**Create a slot on n3 for a future subscription (sub_n4_n3)**

```sql
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5434 user=alice password=1safepassword',
    'SELECT slot_name, lsn 
     FROM pg_create_logical_replication_slot(
         ''spk_inventory_n3_sub_n4_n3'',
         ''spock_output''
     )'
) AS t(slot_name text, lsn pg_lsn);
```


### Trigger a Sync on Other Nodes, Wait on Source

!!! info

    Before copying data from n1 to n4, ensure n1 has ALL the latest data from n2 and n3
    
        - Any writes that happened on n2 or n3 must be fully replicated to n1 first.
        - For example, if a user inserted data on n2 one second ago - that data must be on n1 before copying n1's data to n4 or n4 would be missing that recent insert.
        - By triggering a sync event on n2 and waiting for it on n1, you can confirm that n1 has received everything from n2 up to this exact moment.

    Process: Trigger sync_event on n2 (inserts a marker into n2's replication stream) → Wait on n1 for that marker to arrive → Repeat for n3

**Sync n2 → n1**

Call the `sync_event()` function on n2, which returns an LSN (0/1C9F400). Then on n1, wait for that specific LSN to be replicated. When `wait_for_sync_event()` completes, we're guaranteed that n1 has received all changes from n2 up to and including that LSN.

```sql
-- Trigger sync event on n2
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5433 user=alice password=1safepassword',
    'SELECT spock.sync_event()'
) AS t(sync_lsn pg_lsn);
-- Returns: 0/1C9F400

-- Wait for sync event on n1
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5432 user=alice password=1safepassword',
    'CALL spock.wait_for_sync_event(true, ''n2'', ''0/1C9F400''::pg_lsn, 1200000)'
) AS t(result text);
```

**Sync n3 → n1**

Perform the same process on n3. Trigger `sync_event()` on n3, get the LSN (0/1D0E510), and then wait for that LSN on n1. After both syncs complete, n1 is fully caught up with both n2 and n3.

```sql
-- Trigger sync event on n3
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5434 user=alice password=1safepassword',
    'SELECT spock.sync_event()'
) AS t(sync_lsn pg_lsn);
-- Returns: 0/1D0E510

-- Wait for sync event on n1
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5432 user=alice password=1safepassword',
    'CALL spock.wait_for_sync_event(true, ''n3'', ''0/1D0E510''::pg_lsn, 1200000)'
) AS t(result text);
```

### Copy the Source to New Subscription

!!! info

    It's time for the BIG data copy 
        
        - Create an ENABLED subscription on n4 from n1 with synchronize_structure=true and synchronize_data=true.
        - This causes: Spock to dump the entire schema (tables, indexes, constraints, etc.) from n1 → Restore that schema on n4 → Copy ALL table data from n1 to n4.
        - Before creating the subscription, detect if n4 has any existing schemas that should be omitted from the sync (like monitoring tools, management schemas).  Build a skip_schema` array with these schema names.  When Spock syncs the structure, it excludes these schemas using `pg_dump --exclude-schema`.  When copying data, Spock also skips tables in these schemas.  This prevents overwriting local tools/extensions on n4.
    
    This can take minutes to hours depending on database size (a 100GB database might take 30+ minutes to sync)

**Detect existing schemas on n4**

Query n4's information_schema to find all user-created schemas (excluding system schemas like pg_catalog, information_schema, spock, public). If schemas like "mgmt_tools" or "monitoring" are found, they'll be excluded from replication.

```sql
SELECT string_agg(schema_name, ',') as schemas
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword',
    'SELECT schema_name
     FROM information_schema.schemata
     WHERE schema_name NOT IN (''information_schema'', ''pg_catalog'', ''pg_toast'', ''spock'', ''public'')
     AND schema_name NOT LIKE ''pg_temp_%''
     AND schema_name NOT LIKE ''pg_toast_temp_%'''
) AS t(schema_name text);
-- Returns: 'mgmt_tools,monitoring' (if any exist)
```

**Create an enabled subscription on n4 from n1**

Create a subscription (`sub_n1_n4`) on n4, pointing to n1 as the provider.

Key parameters:
- synchronize_structure := true - Dump and restore schema from n1
- synchronize_data := true - Copy all table data from n1
- enabled := true - Start replicating immediately
- skip_schema := ARRAY['mgmt_tools','monitoring']::text[] - Exclude detected schemas
- forward_origins := ARRAY[]::text[] - Don't forward changes that originated elsewhere

What Spock does internally:
- Run pg_dump on n1 with --exclude-schema=mgmt_tools --exclude-schema=monitoring
- Restore dump on n4
- For each table in replication sets on n1: Skip tables in mgmt_tools and monitoring schemas → Run COPY command to transfer data from n1 to n4
- Once initial sync completes, start streaming ongoing changes from n1 to n4

```sql
-- Build skip_schema array based on detected schemas
-- If schemas found: ARRAY['mgmt_tools','monitoring']::text[]
-- If no schemas: ARRAY[]::text[]

SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword',
    'SELECT spock.sub_create(
        subscription_name := ''sub_n1_n4'',
        provider_dsn := ''host=127.0.0.1 dbname=inventory port=5432 user=alice password=1safepassword'',
        replication_sets := ARRAY[''default'', ''default_insert_only'', ''ddl_sql''],
        synchronize_structure := true,
        synchronize_data := true,
        forward_origins := ARRAY[]::text[],
        apply_delay := ''0''::interval,
        enabled := true,
        force_text_transfer := false,
        skip_schema := ARRAY[''mgmt_tools'',''monitoring'']::text[]
    )'
) AS t(subscription_id oid);
```


### Trigger a Sync on the Source Node and Wait on the New Node

!!! info 
    
    After the initial bulk data copy, there might be a small lag (to recover changes that happened on n1 while the copy was in progress).

        - This confirms that n4 has caught up completely with n1 before proceeding.
        - Trigger a sync_event on n1 (marking the current position in n1's stream); then, wait on n4 for that marker to arrive.  When it arrives, n4 has received and applied everything from n1 up to this point.
        
    For example: We start copying 100GB at 10:00 AM, but while copying, users insert 1000 rows on n1 between 10:00-10:30.  The copy completes at 10:30, but those 1000 rows are still being streamed - we have to wait until all 1000 rows have been applied on n4 so we don't lose data.

**Trigger sync event on n1**

Insert a sync marker into n1's replication stream at the current position. The LSN returned (0/1E1F620) represents *this exact moment in n1's transaction log*.

```sql
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5432 user=alice password=1safepassword',
    'SELECT spock.sync_event()'
) AS t(sync_lsn pg_lsn);
-- Returns: 0/1E1F620
```

**Wait for sync event on n4**

On n4, wait for the sync marker that matches the returned LSN (0/1E1F620) to arrive and be processed. This is a blocking call - it won't return until n4's subscription from n1 has replicated up to this LSN. The timeout (1200000 milliseconds = 20 minutes) prevents waiting forever if something goes wrong.

```sql
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword',
    'CALL spock.wait_for_sync_event(true, ''n1'', ''0/1E1F620''::pg_lsn, 1200000)'
) AS t(result text);
```


### Check the Commit Timestamp and Advance Slots

!!! info

    This is a critical optimization step!
    
        - Earlier, n4 received a full copy of all data from n1, which includes data that originally came from n2 and n3.  Those nodes now have disabled subscriptions waiting to activate (sub_n2_n4 and sub_n3_n4).  The replication slots on n2 and n3 have been buffering changes.

        - Problem: If we enable those subscriptions now, n4 would receive duplicate data (it already has n2's data via n1, then would get it again directly from n2).
        - Solution: Use the lag_tracker to find the EXACT timestamp when n4 last received data from n2 (even though it came via n1).  Then advance n2's replication slot to skip past all data up to that timestamp.  When enabling sub_n2_n4 later, it only sends NEW changes that happened after the sync, not old data n4 that already exists.
    
    Steps for each replica node: Check n4's lag_tracker to get the commit_timestamp for the last change from n2. On n2, convert that timestamp to an LSN using get_lsn_from_commit_ts(). Then, advance n2's replication slot to that LSN. Repeat these steps for n3.

**Get the commit timestamp for n2 → n4**

Query n4's lag_tracker table, which tracks replication progress. Find the row where origin_name='n2' and receiver_name='n4'. The commit_timestamp tells us "the last time n4 received a change that originated from n2". Even though the change came through n1, lag_tracker tracks the original source.

```sql
SELECT commit_timestamp 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword',
    'SELECT commit_timestamp 
     FROM spock.lag_tracker 
     WHERE origin_name = ''n2'' AND receiver_name = ''n4'''
) AS t(commit_timestamp timestamp);
-- Returns: 2025-01-15 10:30:45.123456
```

**Advance the slot on n2**

This is a two-step process: Use `spock.get_lsn_from_commit_ts()` to convert the timestamp (2025-01-15 10:30:45.123456) into an LSN that corresponds to that point in n2's transaction log. Then, use `pg_replication_slot_advance()` to move the slot's `restart_lsn` forward to that position.

The slot `spk_inventory_n2_sub_n2_n4` has been buffering ALL changes to n2. By advancing it, you discard everything up to this LSN (n4 already has it). Now the slot only contains NEW changes that n4 needs.

```sql
-- Get LSN from commit timestamp
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5433 user=alice password=1safepassword',
    'WITH lsn_cte AS (
         SELECT spock.get_lsn_from_commit_ts(
             ''spk_inventory_n2_sub_n2_n4'',
             ''2025-01-15 10:30:45.123456''::timestamp
         ) AS lsn
     )
     SELECT pg_replication_slot_advance(''spk_inventory_n2_sub_n2_n4'', lsn) 
     FROM lsn_cte'
) AS t(result text);
```

**Repeat for n3 → n4**

```sql
-- Get commit timestamp
SELECT commit_timestamp 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword',
    'SELECT commit_timestamp 
     FROM spock.lag_tracker 
     WHERE origin_name = ''n3'' AND receiver_name = ''n4'''
) AS t(commit_timestamp timestamp);
-- Returns: 2025-01-15 10:30:46.789012

-- Advance the slot on n3
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5434 user=alice password=1safepassword',
    'WITH lsn_cte AS (
         SELECT spock.get_lsn_from_commit_ts(
             ''spk_inventory_n3_sub_n3_n4'',
             ''2025-01-15 10:30:46.789012''::timestamp
         ) AS lsn
     )
     SELECT pg_replication_slot_advance(''spk_inventory_n3_sub_n3_n4'', lsn) 
     FROM lsn_cte'
) AS t(result text);
```


### Enable Disabled Subscriptions

In this step, we activate subscriptions from replica nodes to new node using stored sync LSNs.

*  **What happens:** Remember when we created disabled subscriptions and stored sync LSNs? Now we bring it all together. We enable those subscriptions (sub_n2_n4 and sub_n3_n4), and use the STORED LSNs from to verify they start from the correct position.

*  **Why the stored LSNs matter:** When we created sub_n2_n4 and triggered sync_event on n2, we got LSN 0/1A7D1E0. That LSN marked the exact moment we created the replication slot. Between then and now, hours may have passed. The replication slot has been buffering changes. But we need to ensure the subscription starts processing from that original bookmark point, not skipping ahead.

*  **The verification:** After enabling each subscription, we call wait_for_sync_event() with the stored LSN. This confirms that the subscription has processed up to at least that sync point before we continue.

* **After the slot advancement:** The slots were advanced to skip duplicate data. Now when we enable the subscriptions, they'll only send NEW changes that happened after the initial sync - exactly what we want.

**Enable sub_n2_n4 on n4**

Next, we'll call `spock.sub_enable()` on n4 to activate the subscription. The subscription worker process starts, connects to n2, and begins pulling changes from the replication slot.

```sql
-- Enable the subscription
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword',
    'SELECT spock.sub_enable(
        subscription_name := ''sub_n2_n4'',
        immediate := true
    )'
) AS t(result text);
```

**Wait for stored sync event from n2**

Then, retrieve the LSN we stored (0/1A7D1E0) and use it in wait_for_sync_event(). This is the key to the entire ZODAN approach: we're verifying that the subscription has caught up to the sync point we marked when we first set things up. This guarantees data consistency.

```sql
-- Retrieve stored LSN
SELECT sync_lsn FROM temp_sync_lsns WHERE origin_node = 'n2';
-- Returns: 0/1A7D1E0

-- Wait for that sync event on n4
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword',
    'CALL spock.wait_for_sync_event(true, ''n2'', ''0/1A7D1E0''::pg_lsn, 1200000)'
) AS t(result text);
```

**Verify the subscription is replicating**

Check the subscription status using `sub_show_status()`. We want to see `status='replicating'`, which means the subscription worker is active, connected to n2, and successfully applying changes. Any other status (down, initializing) would indicate a problem.

```sql
-- Check subscription status on n4
SELECT subscription_name, status, provider_node
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword',
    'SELECT subscription_name, status, provider_node 
     FROM spock.sub_show_status() 
     WHERE subscription_name = ''sub_n2_n4'''
) AS t(subscription_name text, status text, provider_node text);

-- Expected output:
--  subscription_name |   status    | provider_node 
-- -------------------+-------------+---------------
--  sub_n2_n4         | replicating | n2
```

**Repeat the steps for sub_n3_n4**

```sql
-- Enable subscription
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword',
    'SELECT spock.sub_enable(
        subscription_name := ''sub_n3_n4'',
        immediate := true
    )'
) AS t(result text);

-- Retrieve stored LSN
SELECT sync_lsn FROM temp_sync_lsns WHERE origin_node = 'n3';
-- Returns: 0/1B8E2F0

-- Wait for stored sync event
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword',
    'CALL spock.wait_for_sync_event(true, ''n3'', ''0/1B8E2F0''::pg_lsn, 1200000)'
) AS t(result text);

-- Verify status
SELECT subscription_name, status, provider_node
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword',
    'SELECT subscription_name, status, provider_node 
     FROM spock.sub_show_status() 
     WHERE subscription_name = ''sub_n3_n4'''
) AS t(subscription_name text, status text, provider_node text);
```


### Create Subscriptions from Other Nodes to New Node

This will enable bidirectional replication from n4 to all other nodes.

* **What happens:** Up to this point, data has been flowing TO n4 from other nodes. Now we set up the reverse paths - data flowing FROM n4 TO other nodes. We create subscriptions on n1, n2, and n3 that subscribe FROM n4.

* **Why now and not earlier?** We waited until n4 was fully populated with data before allowing other nodes to subscribe to it. If we had created these subscriptions earlier, the other nodes would try to sync from an empty n4, which would cause problems.

* **Key point - no data sync:** These subscriptions have `synchronize_structure=false` and `synchronize_data=false` because n1, n2, and n3 already have all the data. We only want them to receive NEW changes that happen ON n4 from now on, not copy existing data.

* **The result:** After this, the cluster is fully bidirectional:
    
    - n1 sends to n4, n4 sends to n1
    - n2 sends to n4, n4 sends to n2
    - n3 sends to n4, n4 sends to n3


**Create sub_n4_n1 on n1**

Create a subscription *ON* n1 that points TO n4 as the provider. This is commonly misunderstood: the subscription is created on the RECEIVER node (n1), not the sender (n4). After this, any INSERT/UPDATE/DELETE that happens directly on n4 will replicate to n1.

```sql
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5432 user=alice password=1safepassword',
    'SELECT spock.sub_create(
        subscription_name := ''sub_n4_n1'',
        provider_dsn := ''host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword'',
        replication_sets := ARRAY[''default'', ''default_insert_only'', ''ddl_sql''],
        synchronize_structure := false,
        synchronize_data := false,
        forward_origins := ARRAY[]::text[],
        apply_delay := ''0''::interval,
        enabled := true,
        force_text_transfer := false,
        skip_schema := ARRAY[]::text[]
    )'
) AS t(subscription_id oid);
```

**Create sub_n4_n2 on n2**

This is the same concept - we create a subscription on n2 that pulls from n4. Now n2 will receive changes that happen on n4.

```sql
SELECT * 
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5433 user=alice password=1safepassword',
    'SELECT spock.sub_create(
        subscription_name := ''sub_n4_n2'',
        provider_dsn := ''host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword'',
        replication_sets := ARRAY[''default'', ''default_insert_only'', ''ddl_sql''],
        synchronize_structure := false,
        synchronize_data := false,
        forward_origins := ARRAY[]::text[],
        apply_delay := ''0''::interval,
        enabled := true,
        force_text_transfer := false,
        skip_schema := ARRAY[]::text[]
    )'
) AS t(subscription_id oid);
```

**Create sub_n4_n3 on n3**

```sql
SELECT * FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5434 user=alice password=1safepassword',
    'SELECT spock.sub_create(
        subscription_name := ''sub_n4_n3'',
        provider_dsn := ''host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword'',
        replication_sets := ARRAY[''default'', ''default_insert_only'', ''ddl_sql''],
        synchronize_structure := false,
        synchronize_data := false,
        forward_origins := ARRAY[]::text[],
        apply_delay := ''0''::interval,
        enabled := true,
        force_text_transfer := false,
        skip_schema := ARRAY[]::text[]
    )'
) AS t(subscription_id oid);
```


### Monitor Replication Lag

Next, we'll verify that n4 is keeping up with n1.

* **What happens:** We monitor the lag_tracker table on n4 to ensure replication from n1 is keeping up. The lag_tracker shows the time difference between when a transaction was committed on n1 and when it was applied on n4.

* **Why this matters:** If lag is growing (e.g., 5 seconds, then 10 seconds, then 30 seconds), it means n4 can't keep up with the write load from n1. This could indicate:
- Network bandwidth issues.
- n4's hardware is slower than n1.
- Long-running transactions blocking replication.

* **Target:** We want lag under 59 seconds, or lag_bytes=0 (meaning n4 has processed everything). If lag stays consistently low, n4 is successfully integrated.

```sql
-- Monitor lag from n1 → n4 on n4
DO $$
DECLARE
    lag_interval interval;
    lag_bytes bigint;
BEGIN
    LOOP
        SELECT now() - commit_timestamp, replication_lag_bytes 
        INTO lag_interval, lag_bytes
        FROM dblink(
            'host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword',
            'SELECT now() - commit_timestamp, replication_lag_bytes 
             FROM spock.lag_tracker 
             WHERE origin_name = ''n1'' AND receiver_name = ''n4'''
        ) AS t(lag_interval interval, lag_bytes bigint);

        RAISE NOTICE 'n1 → n4 lag: % (bytes: %)', 
            COALESCE(lag_interval::text, 'NULL'),
            COALESCE(lag_bytes::text, 'NULL');

        EXIT WHEN lag_interval IS NOT NULL 
                  AND (extract(epoch FROM lag_interval) < 59 OR lag_bytes = 0);

        PERFORM pg_sleep(1);
    END LOOP;

    RAISE NOTICE 'Replication lag monitoring complete';
END;
$$;

-- Expected output:
-- NOTICE:  n1 → n4 lag: 00:00:02.345 (bytes: 1024)
-- NOTICE:  n1 → n4 lag: 00:00:01.123 (bytes: 512)
-- NOTICE:  n1 → n4 lag: 00:00:00.456 (bytes: 0)
-- NOTICE:  Replication lag monitoring complete
```


### Show All Nodes

Next, we'll verify that all of the nodes are registered in the cluster.

```sql
SELECT n.node_id, n.node_name, n.location, n.country, i.if_dsn
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5432 user=alice password=1safepassword',
    'SELECT n.node_id, n.node_name, n.location, n.country, i.if_dsn 
     FROM spock.node n 
     JOIN spock.node_interface i ON n.node_id = i.if_nodeid 
     ORDER BY n.node_name'
) AS t(node_id integer, node_name text, location text, country text, if_dsn text);

-- Expected output:
--  node_id | node_name |  location   | country |                           if_dsn                           
-- ---------+-----------+-------------+---------+------------------------------------------------------------
--    16385 | n1        | New York    | USA     | host=127.0.0.1 dbname=inventory port=5432 user=alice ...
--    16386 | n2        | Chicago     | USA     | host=127.0.0.1 dbname=inventory port=5433 user=alice ...
--    16387 | n3        | Boston      | USA     | host=127.0.0.1 dbname=inventory port=5434 user=alice ...
--    16389 | n4        | Los Angeles | USA     | host=127.0.0.1 dbname=inventory port=5435 user=alice ...
```


### Show the Status of all Subscriptions

Next, we want to verify that all subscriptions are replicating.

```sql
-- Get subscriptions from all nodes
SELECT node_name, subscription_name, status, provider_node
FROM (
    -- n1 subscriptions
    SELECT 'n1' as node_name, *
    FROM dblink(
        'host=127.0.0.1 dbname=inventory port=5432 user=alice password=1safepassword',
        'SELECT subscription_name, status, provider_node FROM spock.sub_show_status()'
    ) AS t(subscription_name text, status text, provider_node text)
    
    UNION ALL
    
    -- n2 subscriptions
    SELECT 'n2' as node_name, *
    FROM dblink(
        'host=127.0.0.1 dbname=inventory port=5433 user=alice password=1safepassword',
        'SELECT subscription_name, status, provider_node FROM spock.sub_show_status()'
    ) AS t(subscription_name text, status text, provider_node text)
    
    UNION ALL
    
    -- n3 subscriptions
    SELECT 'n3' as node_name, *
    FROM dblink(
        'host=127.0.0.1 dbname=inventory port=5434 user=alice password=1safepassword',
        'SELECT subscription_name, status, provider_node FROM spock.sub_show_status()'
    ) AS t(subscription_name text, status text, provider_node text)
    
    UNION ALL
    
    -- n4 subscriptions
    SELECT 'n4' as node_name, *
    FROM dblink(
        'host=127.0.0.1 dbname=inventory port=5435 user=alice password=1safepassword',
        'SELECT subscription_name, status, provider_node FROM spock.sub_show_status()'
    ) AS t(subscription_name text, status text, provider_node text)
) combined
ORDER BY node_name, subscription_name;

-- Expected output (12 rows):
--  node_name | subscription_name |   status    | provider_node 
-- -----------+-------------------+-------------+---------------
--  n1        | sub_n2_n1         | replicating | n2
--  n1        | sub_n3_n1         | replicating | n3
--  n1        | sub_n4_n1         | replicating | n4
--  n2        | sub_n1_n2         | replicating | n1
--  n2        | sub_n3_n2         | replicating | n3
--  n2        | sub_n4_n2         | replicating | n4
--  n3        | sub_n1_n3         | replicating | n1
--  n3        | sub_n2_n3         | replicating | n2
--  n3        | sub_n4_n3         | replicating | n4
--  n4        | sub_n1_n4         | replicating | n1
--  n4        | sub_n2_n4         | replicating | n2
--  n4        | sub_n3_n4         | replicating | n3
```


### Verification

Next, we perform a series of tests to verify that the cluster is replicating between n1 and n4.

```sql
-- On n1
CREATE TABLE test_replication (id serial primary key, data text, created_at timestamp default now());
INSERT INTO test_replication (data) VALUES ('Test from n1');

-- On n4 (wait a few seconds)
SELECT * FROM test_replication;
-- Expected: Row appears on n4
```

### Test Replication between n4 and n1

```sql
-- On n4
INSERT INTO test_replication (data) VALUES ('Test from n4');

-- On n1 (wait a few seconds)
SELECT * FROM test_replication;
-- Expected: Both rows appear on n1
```


### Our Final Cluster Topology

```
        ┌──────┐
        │  n1  │ (source)
        └──┬───┘
     ┌─────┼─────┬─────┐
     │     │     │     │
  ┌──▼──┐ │  ┌──▼──┐ ┌▼────┐
  │ n2  │◄┼──┤ n3  │ │ n4  │ (new)
  └──┬──┘ │  └──┬──┘ └┬────┘
     │    │     │     │
     └────┴─────┴─────┘
```

**All nodes are bidirectionally replicating:**
- n1 ↔ n2 ↔ n3 ↔ n4
- Total subscriptions: 12 (each node subscribes to 3 others)

---

## Troubleshooting

### Subscription stuck in 'initializing' or 'down'

```sql
-- Check subscription status
SELECT * FROM spock.sub_show_status();

-- Check worker processes
SELECT * FROM spock.sub_show_table(subscription_name);

-- Check logs
SELECT * FROM pg_stat_replication;
```

### Replication lag too high

```sql
-- Check lag on receiver node
SELECT origin_name, receiver_name, 
       now() - commit_timestamp as lag,
       replication_lag_bytes
FROM spock.lag_tracker
ORDER BY lag DESC;
```

### Slot not advancing

```sql
-- Check slot status
SELECT slot_name, slot_type, active, restart_lsn, confirmed_flush_lsn
FROM pg_replication_slots
WHERE slot_name LIKE 'spk_%';
```


## Key Differences from the Manual Process

1. **Sync LSN Storage:** ZODAN stores sync LSNs and uses them later to ensuring subscriptions start from the correct point even if hours pass between steps.

2. **Auto Schema Detection:** ZODAN automatically detects existing schemas on n4 and populates `skip_schema` parameter, preventing conflicts during structure sync.

3. **Version Compatibility Check:** ZODAN verifies all nodes run the same Spock version before starting.

4. **Verification Steps:** ZODAN includes `verify_subscription_replicating()` after enabling subscriptions to ensure they reach 'replicating' status.

5. **2-node vs Multi-node Logic:** ZODAN handles 2-node scenarios differently (no disabled subscriptions needed when adding to single-node cluster).

6. **Comprehensive Status:** ZODAN shows final status of all nodes and subscriptions across entire cluster, not just the new node.

---

## References

- [pgEdge ZODAN Tutorial](https://docs.pgedge.com/spock_ext/modify/zodan_tutorial)
- [Spock Documentation](https://github.com/pgEdge/spock)
- ZODAN Implementation: [samples/Z0DAN/zodan.sql](https://github.com/pgEdge/spock/tree/main/samples/Z0DAN)

