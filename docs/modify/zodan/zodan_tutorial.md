# Tutorial: Adding a Node to a Cluster with Zero Downtime

In this detailed walkthrough, we add a fourth node to a three-node cluster
with zero downtime. In our example, the cluster nodes are `n1` (the source
node), `n2`, `n3`, and the new node is `n4`.

!!! Warning

    Important Prerequisites and Warnings

    - The new node should not be accessible to users while adding the node.
    - Disable `auto_ddl` on all cluster nodes.
    - Do not modify your DDL during node addition.
    - The users must be identical on the source and target node. You must
      create any users on the target node before proceeding; the
      permissions must be identical for all users on both the source and
      target nodes.
    - The ZODAN process validates that all users from the source node exist
      on the new node before proceeding with cluster addition. This
      prevents replication failures caused by missing user permissions.
    - The Spock configuration must be identical on both the source and the
      target node.
    - All nodes in your cluster must be available to Spock for the duration
      of the node addition.
    - The procedure should be performed on the new node being added.
    - The `dblink` extension must be installed on the node from which
      commands like `SELECT spock.add_node()` are being run.
    - Prepare the new node to meet all of the prerequisites described here.
    - If the process fails, do not immediately retry a command until you
      ensure that all artifacts created by the workflow have been removed.
    - The automated `spock.add_node()` procedure allows 180 seconds
      (3 minutes) for each wait for a sync event between nodes. If
      replication lag exceeds this window, the procedure will raise an
      exception. Ensure network latency and replication lag are within
      acceptable limits before starting, or raise the budget for the
      session with
      [`spock.sync_timeout`](../../configuring.md#spock-sync_timeout), as
      described in [Setting the Synchronisation
      Timeout](#setting-the-synchronisation-timeout) below. When following
      the manual workflow below, you call `spock.wait_for_sync_event()`
      directly and supply your own timeout (the examples use 1200
      seconds), so neither the default nor `spock.sync_timeout` applies.

## Creating a Node Manually

If you are not using `spock.node_create` to create the new node, you will
need to complete the following steps:

- Initialize the new node with `initdb`.
- Create a database.
- Create a database user.
- Follow the instructions at the [GitHub repository](https://github.com/pgEdge/spock)
  to build and install Spock on the database.
- Add `spock` to the `shared_preload_libraries` parameter in the
  `postgresql.conf` file.
- Restart the server to update the configuration.
- Use the `CREATE EXTENSION spock` command to create the Spock extension.

## Sample Configuration and New Node Creation Steps

In our example, the cluster configuration details include the following
information:

- Database: `inventory`
- User: `pgedge`
- Password: `1safepassword`
- n1 (source): port 5432
- n2 (replica): port 5433
- n3 (replica): port 5434
- n4 (new node): port 5435
- Host: 127.0.0.1

The steps used to configure the new node (n4) include the following commands.
The commands initialize the database and install Spock:

```bash
# Initialize database
initdb -D /path/to/data

# Start Postgres
pg_ctl -D /path/to/data start

# Create database and user
psql -c "CREATE DATABASE inventory;"
psql -c "CREATE USER pgedge WITH PASSWORD '1safepassword';"
psql -c "GRANT ALL ON DATABASE inventory TO pgedge;"

# Install Spock extension
psql -d inventory -c "CREATE EXTENSION spock;"
psql -d inventory -c "CREATE EXTENSION dblink;"
```

## Using the Zodan Procedure to Add a Node

After creating the node, you can use [Zodan scripts](zodan_readme.md) to
simplify adding a node to a cluster.

To use the SQL script, connect to the new node that you wish to add to the
pgEdge cluster. In the following example, the `psql` command connects to the
new node:

```bash
psql -h 127.0.0.1 -p 5435 -d inventory -U pgedge
```

Load the Zodan procedures with the following command:

```sql
\i /path/to/zodan.sql
```

Then, use `spock.add_node()` from the new node to create the node
definition. In the following example, the `spock.add_node` procedure adds node `n4` to
the cluster:

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

The `spock.add_node` function executes the steps required to add a node to
the cluster; a detailed explanation of the steps performed follows below.

Should a problem occur during this process, you can source the
`zodremove.sql` script and call the `spock.remove_node` procedure to
remove the node or reverse partially completed steps. The
`spock.remove_node` procedure should be called on the node being removed.

### Setting the Synchronisation Timeout

`spock.add_node()` waits at several points for the nodes to synchronise -
for a sync event to arrive on a peer, for the new node to catch up, and
for a subscription to start replicating. Each of those waits is allowed
180 seconds (3 minutes) by default, which is sized for a small cluster
where a node joins in seconds. On a large database, catchup can
legitimately take minutes or hours, and the procedure fails with a timeout
long before the work is done.

To raise the budget, set
[`spock.sync_timeout`](../../configuring.md#spock-sync_timeout) in the
same session, before calling the add_node procedure:

```sql
SET spock.sync_timeout = '2h';
```

The new value applies to every synchronisation wait the procedure
performs, and it reverts when the session ends, so a long-running node
addition does not need a cluster-wide configuration change. To raise the
limit for every session, set the parameter in `postgresql.conf` instead.

The setting bounds a whole wait, not an individual probe of a remote node;
steps that also bound each remote probe - so that one unresponsive peer
cannot consume the entire budget - keep their own, much smaller limit for
that purpose.


## Manually Adding a Node to a Cluster

The steps that follow outline the process Zodan goes through
when adding a node. You can manually perform the same steps to add a node
to a cluster instead of using `spock.add_node` above.

### Check the Spock Version Compatibility

Before starting the node addition, check the Spock version on every node
(n1, n2, n3, and n4):

- Every node must run Spock 5.0.9 or later.
- Patch versions may differ.
- The new node may run a newer major.minor version than the existing
  nodes (for example, a 6.0 node joining 5.0 nodes), but never an older
  one.
- The manual steps in this tutorial assume the new node, n4, runs Spock
  6.0.0 or later.

!!! info

    `spock.add_node()` aborts with an error if any node fails these
    checks.

Each node's version has to be read on that node, so query the node list
on n1 and then connect to each node in turn. On the orchestrator node, run
the following commands:

```sql
-- Check the new node
SELECT version
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'SELECT extversion FROM pg_extension WHERE extname = ''spock'''
) AS t(version text);
-- Returns: 6.0.0

-- Check every node already in the cluster
SELECT n.node_name, v.version
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
    'SELECT n.node_name, i.if_dsn
     FROM spock.node n
     JOIN spock.node_interface i ON n.node_id = i.if_nodeid'
) AS n(node_name text, if_dsn text)
CROSS JOIN LATERAL dblink(
    n.if_dsn,
    'SELECT extversion FROM pg_extension WHERE extname = ''spock'''
) AS v(version text)
ORDER BY n.node_name;

-- Expected output:
--  node_name | version
-- -----------+---------
--  n1        | 6.0.0
--  n2        | 6.0.0
--  n3        | 6.0.0
```

### Validate Prerequisites

You should ensure that the new node is in good condition before adding the
node to your replicating cluster.

Perform safety checks to ensure node `n4` is a clean slate:

- The n4 node must have the database and Spock extension installed.
- The n4 node must have no user data or existing replication configuration.
- Verify that a node named n4 does not already exist in the cluster.
- Every role on n1 must also exist on n4.
- Every subscription already in the cluster must be enabled.
- If the cluster replicates large objects with lolor, n4 must have the
  lolor extension installed and its lolor tables must be empty.

!!! info

    If any prerequisite fails, the process aborts to prevent conflicts.

#### Confirm that the Database Exists on n4

Try to connect to the database on n4. If this fails, the database does not
exist and needs to be created first.

In the following example, the query checks whether the database exists on
n4:

```sql
SELECT 1
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'SELECT 1'
) AS t(dummy int);
-- If no error, database exists
```

#### Confirm that n4 Has No User-Created Tables

The new node must be empty; there can be no user tables in user schemas
(system tables and extension tables are acceptable). If user tables exist,
ZODAN will abort because syncing would overwrite existing data.

In the following example, the query checks for user-created tables on n4:

```sql
SELECT count(*)
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'SELECT count(*) FROM pg_tables
     WHERE schemaname NOT IN (''information_schema'', ''pg_catalog'', ''pg_toast'', ''spock'', ''lolor'')
     AND schemaname NOT LIKE ''pg_temp_%''
     AND schemaname NOT LIKE ''pg_toast_temp_%'''
) AS t(count integer);
-- Expected: 0
```

#### Confirm that n4 Has Every Role from n1

The structure copy keeps object owners and grants, so it fails on n4 if a
role that owns an object or is granted access to one is missing there.
That includes roles that cannot log in. The following query lists the
roles that exist on n1 but not on n4:

```sql
SELECT rolname
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
    'SELECT rolname FROM pg_roles WHERE rolname !~ ''^pg_'''
) AS s(rolname text)
EXCEPT
SELECT rolname
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'SELECT rolname FROM pg_roles WHERE rolname !~ ''^pg_'''
) AS t(rolname text);
-- Expected: no rows
```

Create any role the query returns on n4 before going on.

#### Confirm that Every Existing Subscription Is Enabled

A disabled subscription between the existing nodes means one of them may
be missing changes, and the waits later in this process would not finish.
The following query lists disabled subscriptions on every node:

```sql
SELECT n.node_name, s.sub_name
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
    'SELECT n.node_name, i.if_dsn
     FROM spock.node n
     JOIN spock.node_interface i ON n.node_id = i.if_nodeid'
) AS n(node_name text, if_dsn text)
CROSS JOIN LATERAL dblink(
    n.if_dsn,
    'SELECT sub_name FROM spock.subscription WHERE NOT sub_enabled'
) AS s(sub_name text);
-- Expected: no rows
```

#### Check lolor, if the Cluster Uses It

Skip this step if the lolor extension is not installed on n1. If n1
replicates the lolor tables, n4 needs the extension too, and its lolor
tables must be empty so the large objects from n1 can be copied in.

```sql
-- On n1: are lolor tables in a replication set?
SELECT count(*)
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
    'SELECT count(*) FROM spock.tables
     WHERE nspname = ''lolor'' AND set_name IS NOT NULL'
) AS t(count integer);
-- If greater than 0, lolor must be installed on n4

-- On n4: is lolor installed?
SELECT installed
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = ''lolor'')'
) AS t(installed boolean);

-- On n4, if lolor is installed: are its tables empty?
SELECT row_count
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'SELECT (SELECT count(*) FROM lolor.pg_largeobject)
          + (SELECT count(*) FROM lolor.pg_largeobject_metadata)'
) AS t(row_count bigint);
-- Expected: 0
```

#### Confirm that n4 Does Not Exist in the Cluster

Check if a node with the name n4 is already registered in the cluster. If
the node exists, ZODAN aborts to prevent duplicate node names. The
following example checks to see if n4 already exists in the cluster:

```sql
-- On orchestrator node (connected to n1)
SELECT count(*) FROM spock.node WHERE node_name = 'n4';
-- Expected: 0
```

#### Confirm that n4 Contains No Subscriptions

In the following example, the query checks whether n4 has any existing
subscriptions:

```sql
SELECT count(*)
FROM spock.subscription s
JOIN spock.node n ON s.sub_origin = n.node_id
WHERE n.node_name = 'n4';
-- Expected: 0
```

#### Confirm that n4 Contains No Replication Sets

In the following example, the query checks whether n4 has any replication
sets:

```sql
SELECT count(*)
FROM spock.replication_set rs
JOIN spock.node n ON rs.set_nodeid = n.node_id
WHERE n.node_name = 'n4';
-- Expected: 0
```

### Create a Replication Node on n4

After confirming the state of the new node, you can add the node to your
cluster. In this step, you will create a Spock node object on n4:

- This registers n4 as a participant in the replication cluster.
- Think of this like giving n4 an ID badge that says "I'm part of this
  cluster now."

!!! info

    After this step, n4 is registered in its own `spock.node` table only.
    Each of the other nodes learns about n4 later, when it subscribes to
    n4.

#### Create a Node on n4

Using `dblink`, connect to n4 and run `spock.node_create()` to register
the node. The DSN tells other nodes how to connect to n4.

In the following example, the `spock.node_create` function registers n4 as
a cluster participant:

```sql
-- Via dblink to n4
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'SELECT spock.node_create(
        node_name := ''n4'',
        dsn := ''host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword'',
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

#### Confirm the Initial Node Count

In the following example, the query retrieves the node count on n1. n1
does not know about n4 yet, so the count is still three. It becomes four
once n1 subscribes to n4 near the end of the process:

```sql
SELECT count(*)
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
    'SELECT count(*) FROM spock.node'
) AS t(count integer);
-- Expected: 3 (n1, n2, n3)
```


### Create Disabled Subscriptions and Slots

This is the critical bookmarking stage. For each of n2 and n3, the process
completes the following steps:

- Create the replication slot for the future subscription to n4. From this
  point on, the slot keeps every change on that node for n4.
- Trigger a `sync_event()`, which commits a marker on the node and returns
  its LSN (log sequence number). Because the marker is committed after the
  slot was created, it gives the wait that follows a position it can
  reach even when the node is otherwise idle.
- Wait until n1 has applied that node's changes up to the marker. n4 gets
  its initial data from n1, so this proves that everything the node
  committed before the slot existed will be in that copy.
- Create the subscription on n4, but keep it disabled. n4 should get all
  initial data from n1 (the source) in one clean sync.

!!! info

    The n2 to n4 and n3 to n4 subscriptions are just being prepared now,
    but will not start moving data until later.

#### Identify All Existing Nodes

Query n1 to find the existing nodes (n1, n2, n3) and their connection
strings. In the following example, the query retrieves all nodes
and their DSNs:

```sql
SELECT n.node_name, i.if_dsn
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
    'SELECT n.node_name, i.if_dsn
     FROM spock.node n
     JOIN spock.node_interface i ON n.node_id = i.if_nodeid'
) AS t(node_name text, if_dsn text);

-- Expected output:
--  node_name |                              if_dsn
-- -----------+------------------------------------------------------------------
--  n1        | host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=...
--  n2        | host=127.0.0.1 dbname=inventory port=5433 user=pgedge password=...
--  n3        | host=127.0.0.1 dbname=inventory port=5434 user=pgedge password=...
```

#### Create a Replication Slot on n2

A replication slot is like a queue that holds all changes from n2 that
need to be sent to n4. Even though the subscription does not exist yet,
the slot starts collecting changes immediately. This ensures no data is
lost between now and when the subscription is enabled.

The slot name follows the pattern `spk_<database>_<provider>_<subscription>`.
On PostgreSQL 17 and later, create the slot with `failover := true` so
that native slot sync (`sync_replication_slots = on`) copies it to any
physical standby of n2. Spock 6.0.0 and later sets this flag on the
slots it creates through `spock.sub_create()`; a slot you create by hand
does not get it unless you ask for it. On PostgreSQL 15 and 16, leave the
`failover` argument out.

Keep the returned LSN; it is the slot LSN for n2.

In the following example, the commands create a replication slot on n2:

```sql
-- On n2
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5433 user=pgedge password=1safepassword',
    'SELECT slot_name, lsn
     FROM pg_create_logical_replication_slot(
         slot_name := ''spk_inventory_n2_sub_n2_n4'',
         plugin := ''spock_output'',
         failover := true
     )'
) AS t(slot_name text, lsn pg_lsn);

-- Expected output:
--          slot_name          |    lsn
-- ----------------------------+-----------
--  spk_inventory_n2_sub_n2_n4 | 0/1A7D1E0
```

#### Trigger a Sync Event on n2 and Store the LSN

Call `sync_event(true)` on n2. It commits a marker into the n2
replication stream and returns the LSN of that commit. Store it together
with the slot LSN in a temporary table on the orchestrator node. You use
the sync LSN in the next step, and again as a check before you advance
the slot.

In the following example, the commands trigger a sync event and store
both LSNs:

```sql
-- Trigger sync event on n2
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5433 user=pgedge password=1safepassword',
    'SELECT spock.sync_event(true)'
) AS t(sync_lsn pg_lsn);
-- Returns: 0/1A7D2F8

-- Store both LSNs
CREATE TEMP TABLE IF NOT EXISTS temp_sync_lsns (
    origin_node text PRIMARY KEY,
    sync_lsn pg_lsn NOT NULL,
    slot_lsn pg_lsn
);

INSERT INTO temp_sync_lsns (origin_node, sync_lsn, slot_lsn)
VALUES ('n2', '0/1A7D2F8', '0/1A7D1E0')
ON CONFLICT (origin_node) DO UPDATE
    SET sync_lsn = EXCLUDED.sync_lsn,
        slot_lsn = EXCLUDED.slot_lsn;
```

#### Wait for n1 to Apply n2's Changes up to the Sync LSN

Poll `spock.progress` on n1 until the last n2 commit that n1 has applied
is at or past the sync LSN. Apply is in commit order, so once n1 is past
the marker it has every n2 commit from before the slot was created, and
the copy from n1 to n4 later on will include them.

Use `remote_commit_lsn` here. `received_lsn` is not safe for this check
because it also moves on keepalive messages, before any n2 change has
been applied on n1. On nodes running Spock older than 6.0.0 the column
is named `remote_lsn`.

The loop gives up after 1200 seconds. If it does, replication from n2 to
n1 is not working. Fix that before going on, because the copy from n1
would otherwise miss changes from n2.

```sql
DO $$
DECLARE
    applied pg_lsn;
    started timestamptz := clock_timestamp();
BEGIN
    LOOP
        SELECT lsn INTO applied
        FROM dblink(
            'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
            'SELECT p.remote_commit_lsn
             FROM spock.progress p
             JOIN spock.node n ON n.node_id = p.remote_node_id
             WHERE p.node_id = (SELECT node_id FROM spock.node_info())
               AND n.node_name = ''n2'''
        ) AS t(lsn pg_lsn);

        EXIT WHEN applied >= '0/1A7D2F8';

        IF clock_timestamp() - started > interval '1200 seconds' THEN
            RAISE EXCEPTION 'n1 has not applied n2 changes up to 0/1A7D2F8 (last seen: %)',
                            applied;
        END IF;

        PERFORM pg_sleep(0.5);
    END LOOP;
END;
$$;
```

#### Create a Disabled Subscription on n4 from n2

First, drop any replication origin left on n4 by an earlier attempt to add
the node. The origin has the same name as the slot. A stale origin would
make the subscription start from an old position.

Then create the subscription on n4 with `enabled := false`. This tells n4
that it will eventually subscribe to n2, but not yet.

Subscribe to every replication set n2 has, not just the three built-in
sets. A table that only belongs to a set you created yourself would
otherwise never reach n4, and nothing would report it. List the sets on
n2 with:

```sql
SELECT set_name
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5433 user=pgedge password=1safepassword',
    'SELECT rs.set_name
     FROM spock.replication_set rs
     JOIN spock.local_node ln ON rs.set_nodeid = ln.node_id
     ORDER BY rs.set_name'
) AS t(set_name text);
-- Returns: ddl_sql, default, default_insert_only
```

Then drop the stale origin and create the subscription:

```sql
-- On n4: drop a stale origin, if there is one
SELECT dblink_exec(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'DO $x$
     BEGIN
         IF EXISTS (SELECT 1 FROM pg_replication_origin
                    WHERE roname = ''spk_inventory_n2_sub_n2_n4'') THEN
             PERFORM pg_replication_origin_drop(''spk_inventory_n2_sub_n2_n4'');
         END IF;
     END $x$'
);

-- On n4: create the disabled subscription
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'SELECT spock.sub_create(
        subscription_name := ''sub_n2_n4'',
        provider_dsn := ''host=127.0.0.1 dbname=inventory port=5433 user=pgedge password=1safepassword'',
        replication_sets := ARRAY[''ddl_sql'', ''default'', ''default_insert_only''],
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

#### Repeat the Previous Steps for n3 to n4

In the following example, the commands perform the same operations for n3
to n4:

```sql
-- Create replication slot on n3
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5434 user=pgedge password=1safepassword',
    'SELECT slot_name, lsn
     FROM pg_create_logical_replication_slot(
         slot_name := ''spk_inventory_n3_sub_n3_n4'',
         plugin := ''spock_output'',
         failover := true
     )'
) AS t(slot_name text, lsn pg_lsn);
-- Returns: spk_inventory_n3_sub_n3_n4 | 0/1B8E2F0

-- Trigger sync event on n3
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5434 user=pgedge password=1safepassword',
    'SELECT spock.sync_event(true)'
) AS t(sync_lsn pg_lsn);
-- Returns: 0/1B8E408

-- Store both LSNs
INSERT INTO temp_sync_lsns (origin_node, sync_lsn, slot_lsn)
VALUES ('n3', '0/1B8E408', '0/1B8E2F0')
ON CONFLICT (origin_node) DO UPDATE
    SET sync_lsn = EXCLUDED.sync_lsn,
        slot_lsn = EXCLUDED.slot_lsn;

-- Wait for n1 to apply n3's changes up to the sync LSN
DO $$
DECLARE
    applied pg_lsn;
    started timestamptz := clock_timestamp();
BEGIN
    LOOP
        SELECT lsn INTO applied
        FROM dblink(
            'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
            'SELECT p.remote_commit_lsn
             FROM spock.progress p
             JOIN spock.node n ON n.node_id = p.remote_node_id
             WHERE p.node_id = (SELECT node_id FROM spock.node_info())
               AND n.node_name = ''n3'''
        ) AS t(lsn pg_lsn);

        EXIT WHEN applied >= '0/1B8E408';

        IF clock_timestamp() - started > interval '1200 seconds' THEN
            RAISE EXCEPTION 'n1 has not applied n3 changes up to 0/1B8E408 (last seen: %)',
                            applied;
        END IF;

        PERFORM pg_sleep(0.5);
    END LOOP;
END;
$$;

-- On n4: drop a stale origin, if there is one
SELECT dblink_exec(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'DO $x$
     BEGIN
         IF EXISTS (SELECT 1 FROM pg_replication_origin
                    WHERE roname = ''spk_inventory_n3_sub_n3_n4'') THEN
             PERFORM pg_replication_origin_drop(''spk_inventory_n3_sub_n3_n4'');
         END IF;
     END $x$'
);

-- Create disabled subscription on n4 from n3
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'SELECT spock.sub_create(
        subscription_name := ''sub_n3_n4'',
        provider_dsn := ''host=127.0.0.1 dbname=inventory port=5434 user=pgedge password=1safepassword'',
        replication_sets := ARRAY[''ddl_sql'', ''default'', ''default_insert_only''],
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

### Trigger a Sync on Other Nodes, Wait on Source

Before copying data from n1 to n4, ensure n1 has all the latest data from
n2 and n3.

- Any writes that happened on n2 or n3 must be fully replicated to n1 first.
- For example, if a user inserted data on n2 one second ago, that data
  must be on n1 before copying n1's data to n4, or n4 would be missing
  that recent insert.
- By triggering a sync event on n2 and waiting for the event on n1, you can
  confirm that n1 has received everything from n2 up to this exact moment.

!!! info

    Process: Trigger `sync_event` on n2 (inserts a marker into the n2
    replication stream), wait on n1 for that marker to arrive, and repeat
    for n3.

#### Sync n2 to n1

Call the `sync_event()` function on n2, which returns an LSN (0/1C9F400).
Then on n1, wait for that specific LSN to be replicated. When
`wait_for_sync_event()` completes, you are guaranteed that n1 has received
all changes from n2 up to and including that LSN.

In the following example, the commands trigger a sync event and wait for
completion:

```sql
-- Trigger sync event on n2
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5433 user=pgedge password=1safepassword',
    'SELECT spock.sync_event()'
) AS t(sync_lsn pg_lsn);
-- Returns: 0/1C9F400

-- Wait for sync event on n1
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
    'CALL spock.wait_for_sync_event(true, ''n2'', ''0/1C9F400''::pg_lsn, 1200)'
) AS t(result bool);
```

#### Sync n3 to n1

Perform the same process on n3. Trigger `sync_event()` on n3, get the LSN
(0/1D0E510), and then wait for that LSN on n1. After both syncs complete,
n1 is fully caught up with both n2 and n3.

In the following example, the commands trigger a sync event on n3 and wait
for completion on n1:

```sql
-- Trigger sync event on n3
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5434 user=pgedge password=1safepassword',
    'SELECT spock.sync_event()'
) AS t(sync_lsn pg_lsn);
-- Returns: 0/1D0E510

-- Wait for sync event on n1
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
    'CALL spock.wait_for_sync_event(true, ''n3'', ''0/1D0E510''::pg_lsn, 1200)'
) AS t(result bool);
```

### Copy the Source to New Subscription

This is the big data copy step.

- Create an enabled subscription on n4 from n1 with
  `synchronize_structure=true` and `synchronize_data=true`.
- This causes Spock to dump the entire schema (tables, indexes,
  constraints, etc.) from n1, restore that schema on n4, and copy all
  table data from n1 to n4.
- Before creating the subscription, detect if n4 has any existing schemas
  that should be omitted from the sync (like monitoring tools, management
  schemas). Build a `skip_schema` array with these schema names. When
  Spock syncs the structure, Spock excludes these schemas using `pg_dump
  --exclude-schema`. When copying data, Spock also skips tables in these
  schemas. This prevents overwriting local tools or extensions on n4.

!!! info

    This can take minutes to hours depending on database size (a 100GB
    database might take 30+ minutes to sync).

#### Detect Existing Schemas on n4

Query the n4 `information_schema` to find all user-created schemas
(excluding system schemas like `pg_catalog`, `information_schema`,
`spock`, `public`, `lolor`). If schemas like `mgmt_tools` or `monitoring`
are found, they will be excluded from replication.

Keep `lolor` out of this list. Spock already leaves it out of the
structure copy, and adding it to `skip_schema` would also leave the lolor
tables out of the initial data copy.

In the following example, the query detects existing schemas on n4:

```sql
SELECT string_agg(schema_name, ',') as schemas
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'SELECT schema_name
     FROM information_schema.schemata
     WHERE schema_name NOT IN (''information_schema'', ''pg_catalog'', ''pg_toast'', ''spock'', ''public'', ''lolor'')
     AND schema_name NOT LIKE ''pg_temp_%''
     AND schema_name NOT LIKE ''pg_toast_temp_%'''
) AS t(schema_name text);
-- Returns: 'mgmt_tools,monitoring' (if any exist)
```

#### Create an Enabled Subscription on n4 from n1

Create a subscription (`sub_n1_n4`) on n4, pointing to n1 as the provider.

The key parameters include:

- `replication_sets` - Every replication set n1 has, listed with the
  same query you ran against n2 above, pointed at n1.
- `synchronize_structure := true` - Dump and restore schema from n1.
- `synchronize_data := true` - Copy all table data from n1.
- `enabled := true` - Start replicating immediately.
- `skip_schema := ARRAY['mgmt_tools','monitoring']::text[]` - Exclude
  detected schemas.
- `forward_origins := ARRAY[]::text[]` - Do not forward changes that
  originated elsewhere.

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
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'SELECT spock.sub_create(
        subscription_name := ''sub_n1_n4'',
        provider_dsn := ''host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword'',
        replication_sets := ARRAY[''ddl_sql'', ''default'', ''default_insert_only''],
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

After the initial bulk data copy, there might be a small lag to recover
changes that happened on n1 while the copy was in progress.

- This confirms that n4 has caught up completely with n1 before proceeding.
- Trigger a `sync_event` on n1 (marking the current position in the n1
  stream); then, wait on n4 for that marker to arrive. When the marker
  arrives, n4 has received and applied everything from n1 up to this point.

!!! info

    For example: You start copying 100GB at 10:00 AM, but while copying,
    users insert 1000 rows on n1 between 10:00-10:30. The copy completes
    at 10:30, but those 1000 rows are still being streamed. You must wait
    until all 1000 rows have been applied on n4 so you do not lose data.

#### Trigger a Sync Event on n1

Insert a sync marker into the n1 replication stream at the current
position. The LSN returned (0/1E1F620) represents this exact moment in the
n1 transaction log.

In the following example, the command triggers a sync event on n1:

```sql
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
    'SELECT spock.sync_event()'
) AS t(sync_lsn pg_lsn);
-- Returns: 0/1E1F620
```

#### Wait for Sync Event on n4

On n4, wait for the sync marker that matches the returned LSN (0/1E1F620)
to arrive and be processed. This is a blocking call; the call will not
return until the n4 subscription from n1 has replicated up to this LSN.
The timeout (1200 seconds = 20 minutes) is a value chosen for this manual
example to give plenty of headroom; tune it to suit your environment. It
prevents waiting forever if something goes wrong. (The automated
`spock.add_node()` procedure uses a shorter 180-second internal timeout
for its sync waits, as noted in the prerequisites.)

In the following example, the command waits for the sync event on n4:

```sql
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'CALL spock.wait_for_sync_event(true, ''n1'', ''0/1E1F620''::pg_lsn, 1200)'
) AS t(result bool);
```


### Advance the Slots and Origins

n4 now has a full copy of n1, and that copy includes the changes that
first happened on n2 and n3 and reached n1 before the copy was taken.
Meanwhile the slots on n2 and n3 have been keeping every change since
they were created.

!!! warning

    If you enable `sub_n2_n4` and `sub_n3_n4` now, n4 receives those
    changes a second time, directly from n2 and n3.

To avoid that, move each slot and the matching replication origin on n4
to the last commit from that node that is already in the copy. When the
COPY from n1 finishes, Spock records that position in `spock.progress` on
n4: one row per origin node, with the last commit from that node that n1
had applied when the copy was taken.

This relies on n4 running Spock 6.0.0 or later, which takes the position
from the replication origins on n1 when the copy snapshot is taken.
Spock 5.0.x on the new node reads it from n1's `spock.progress` table
instead, which can trail the commits included in the copy, so a change
could be applied twice after the slot is advanced. To add a node that
runs 5.0.x, follow the documentation and `zodan.sql` of that release.

!!! info

    For each of n2 and n3: wait until `sub_n1_n4` is ready, read the
    position for that node from `spock.progress` on n4, advance the slot on
    the node to it, then advance the replication origin with the same name
    on n4 to it.

#### Wait for sub_n1_n4 to Be Ready

The position in `spock.progress` is only written once the initial copy is
complete. Check on n4 that no table of `sub_n1_n4` is still being
synchronized; repeat the query until it returns 0:

```sql
SELECT pending
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'SELECT count(*)
     FROM spock.local_sync_status ls
     JOIN spock.subscription s ON s.sub_id = ls.sync_subid
     WHERE s.sub_name = ''sub_n1_n4''
       AND ls.sync_status NOT IN (''y'', ''r'')'
) AS t(pending bigint);
-- Returns: 0
```

#### Get the Position for n2

Read the last n2 commit contained in the copy from `spock.progress` on n4.

```sql
SELECT lsn
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'SELECT p.remote_commit_lsn
     FROM spock.progress p
     JOIN spock.node n ON n.node_id = p.remote_node_id
     WHERE n.node_name = ''n2'''
) AS t(lsn pg_lsn);
-- Returns: 0/1A80B48
```

Because you waited for n1 to apply n2's changes up to the sync LSN before
the copy, this position is always at or past the sync LSN you stored for
n2. If the query returns no row, or a position before that sync LSN,
stop and find out why before going on. Enabling the subscription in that
state can lose or repeat changes.

#### Advance the Slot on n2 and the Origin on n4

Advance the slot `spk_inventory_n2_sub_n2_n4` on n2 to that position. This
discards the changes n4 already has.

Then advance the replication origin of the same name on n4 to the same
position. The origin is where n4 records how far it has applied from n2,
and `sub_n2_n4` resumes from it. Advance both, or n4 and n2 disagree
about where the subscription starts.

```sql
-- On n2: advance the slot
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5433 user=pgedge password=1safepassword',
    'SELECT * FROM pg_replication_slot_advance(
         ''spk_inventory_n2_sub_n2_n4'', ''0/1A80B48''::pg_lsn)'
) AS t(slot_name name, end_lsn pg_lsn);

-- On n4: advance the origin, creating it first if it is missing
SELECT dblink_exec(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'DO $x$
     BEGIN
         IF NOT EXISTS (SELECT 1 FROM pg_replication_origin
                        WHERE roname = ''spk_inventory_n2_sub_n2_n4'') THEN
             PERFORM pg_replication_origin_create(''spk_inventory_n2_sub_n2_n4'');
         END IF;
         PERFORM pg_replication_origin_advance(''spk_inventory_n2_sub_n2_n4'',
                                               ''0/1A80B48''::pg_lsn);
     END $x$'
);
```

#### Repeat for n3 to n4

In the following example, the commands perform the same operations for n3
to n4:

```sql
-- Get the position for n3 from n4
SELECT lsn
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'SELECT p.remote_commit_lsn
     FROM spock.progress p
     JOIN spock.node n ON n.node_id = p.remote_node_id
     WHERE n.node_name = ''n3'''
) AS t(lsn pg_lsn);
-- Returns: 0/1B90C10

-- On n3: advance the slot
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5434 user=pgedge password=1safepassword',
    'SELECT * FROM pg_replication_slot_advance(
         ''spk_inventory_n3_sub_n3_n4'', ''0/1B90C10''::pg_lsn)'
) AS t(slot_name name, end_lsn pg_lsn);

-- On n4: advance the origin
SELECT dblink_exec(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'DO $x$
     BEGIN
         IF NOT EXISTS (SELECT 1 FROM pg_replication_origin
                        WHERE roname = ''spk_inventory_n3_sub_n3_n4'') THEN
             PERFORM pg_replication_origin_create(''spk_inventory_n3_sub_n3_n4'');
         END IF;
         PERFORM pg_replication_origin_advance(''spk_inventory_n3_sub_n3_n4'',
                                               ''0/1B90C10''::pg_lsn);
     END $x$'
);
```

### Mirror the Replication Sets onto n4

The structure sync creates the tables on n4, but not n1's replication set
definitions and memberships. n4 needs them before it starts acting as a
provider for n1, n2, and n3, or it would only send what happened to land
in the built-in sets.

`zodan.sql` includes a helper that copies them from n1. Load `zodan.sql`
on n4 and call it there:

```sql
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'SELECT spock.sync_repsets_from_source(
        ''host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword'',
        ''n4'', true)'
) AS t(summary text);
```

You can also do this by hand with `spock.repset_create()`,
`spock.repset_add_table()` and `spock.repset_add_seq()` on n4, matching
what `spock.replication_set`, `spock.replication_set_table` and
`spock.replication_set_seq` show on n1.

If someone changes a replication set on n1 while the node is being added,
n4 does not pick that up. Compare the sets on both nodes when you are done
and fix any difference with `spock.repset_add_table()` or
`spock.repset_remove_table()` on n4.

### Enable Disabled Subscriptions

In this step, enable the subscriptions from n2 and n3 to n4 and check that
they have caught up.

The slots and origins now point at the first change n4 does not have yet,
so each subscription starts sending only new changes from that point.

After enabling each subscription, trigger a new sync event on its
provider and wait for it on n4. That shows the subscription is running
and that n4 has applied everything the slot kept while the subscription
was disabled.

#### Enable sub_n2_n4 on n4

Next, call `spock.sub_enable()` on n4 to activate the subscription. The
subscription worker process starts, connects to n2, and begins pulling
changes from the replication slot.

The following example enables the subscription:

```sql
-- Enable the subscription
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'SELECT spock.sub_enable(
        subscription_name := ''sub_n2_n4'',
        immediate := true
    )'
) AS t(result bool);
```

#### Wait for n4 to Catch Up with n2

The sync LSN you stored for n2 is older than the position you advanced the
origin to, so waiting for it would return at once and prove nothing.
Trigger a new sync event on n2 instead and wait for it on n4. The new
marker is committed after everything the slot has kept, so once n4 reaches
it, n4 has applied the whole backlog from n2. The call returns `true` on
success and `false` if the timeout runs out first.

If it returns `false`, stop here. Find out why n4 is behind and repeat the
wait until it returns `true`. Do not create the subscriptions from n4 to
the other nodes before that.

```sql
-- Trigger a new sync event on n2
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5433 user=pgedge password=1safepassword',
    'SELECT spock.sync_event()'
) AS t(sync_lsn pg_lsn);
-- Returns: 0/1A93C20

-- Wait for that sync event on n4
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'CALL spock.wait_for_sync_event(true, ''n2'', ''0/1A93C20''::pg_lsn, 1200)'
) AS t(result bool);
-- Returns: t
```

#### Verify the Subscription is Replicating

Check the subscription status using the `sub_show_status()` function. We
want to see `status='replicating'`, which means the subscription worker
is active, connected to n2, and successfully applying changes. Any other
status (down, initializing) would indicate a problem.

The following example checks the subscription status on n4:

```sql
-- Check subscription status on n4
SELECT subscription_name, status, provider_node
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'SELECT subscription_name, status, provider_node
     FROM spock.sub_show_status()
     WHERE subscription_name = ''sub_n2_n4'''
) AS t(subscription_name text, status text, provider_node text);

-- Expected output:
--  subscription_name |   status    | provider_node
-- -------------------+-------------+---------------
--  sub_n2_n4         | replicating | n2
```

#### Repeat the Steps for sub_n3_n4

In the following example, commands enable the subscription and verify
replication:

```sql
-- Enable subscription
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'SELECT spock.sub_enable(
        subscription_name := ''sub_n3_n4'',
        immediate := true
    )'
) AS t(result bool);

-- Trigger a new sync event on n3
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5434 user=pgedge password=1safepassword',
    'SELECT spock.sync_event()'
) AS t(sync_lsn pg_lsn);
-- Returns: 0/1BA4D38

-- Wait for that sync event on n4
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'CALL spock.wait_for_sync_event(true, ''n3'', ''0/1BA4D38''::pg_lsn, 1200)'
) AS t(result bool);
-- Returns: t. If it returns f, stop and resolve it before going on.

-- Verify status
SELECT subscription_name, status, provider_node
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'SELECT subscription_name, status, provider_node
     FROM spock.sub_show_status()
     WHERE subscription_name = ''sub_n3_n4'''
) AS t(subscription_name text, status text, provider_node text);
```


### Create Subscriptions from Other Nodes to New Node

This step enables bidirectional replication from n4 to all other nodes.

Up to this point, data has been flowing TO n4 from other nodes. Now
we set up the reverse paths. Data will flow FROM n4 TO other nodes. We
create subscriptions on n1, n2, and n3 that subscribe FROM n4.

We waited until n4 was fully populated with data before allowing other
nodes to subscribe to it. If we had created these subscriptions earlier,
the other nodes would try to sync from an empty n4, which would cause
problems.

These subscriptions have `synchronize_structure=false` and
`synchronize_data=false` because n1, n2, and n3 already have all the
data. We only want them to receive NEW changes that happen ON n4 from
now on, not copy existing data.

Subscribe to every replication set n4 has after the mirroring step, so
that tables in sets you created yourself are included. List them with:

```sql
SELECT set_name
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'SELECT rs.set_name
     FROM spock.replication_set rs
     JOIN spock.local_node ln ON rs.set_nodeid = ln.node_id
     ORDER BY rs.set_name'
) AS t(set_name text);
-- Returns: ddl_sql, default, default_insert_only
```

The examples below show the three built-in sets. If the query returns
more, add them to the `replication_sets` array of each subscription.

You do not create any slots for these subscriptions yourself:
`spock.sub_create()` creates each slot on the provider, n4.

After this, the cluster is fully bidirectional:

- n1 sends to n4, n4 sends to n1
- n2 sends to n4, n4 sends to n2
- n3 sends to n4, n4 sends to n3


#### Create sub_n4_n1 on n1

Create a subscription *ON* n1 that *points TO* n4 as the provider. This is
commonly misunderstood; the subscription is created on the RECEIVER node
(n1), not the sender (n4). After this, any INSERT/UPDATE/DELETE that
happens directly on n4 will replicate to n1.

The following example creates the subscription:

```sql
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
    'SELECT spock.sub_create(
        subscription_name := ''sub_n4_n1'',
        provider_dsn := ''host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword'',
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

#### Create sub_n4_n2 on n2

This is the same concept. We create a subscription on n2 that pulls from
n4. Now n2 will receive changes that happen on n4.

In the following example, the command creates the subscription on n2:

```sql
SELECT *
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5433 user=pgedge password=1safepassword',
    'SELECT spock.sub_create(
        subscription_name := ''sub_n4_n2'',
        provider_dsn := ''host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword'',
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

#### Create sub_n4_n3 on n3

The following command creates the subscription on n3:

```sql
SELECT * FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5434 user=pgedge password=1safepassword',
    'SELECT spock.sub_create(
        subscription_name := ''sub_n4_n3'',
        provider_dsn := ''host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword'',
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

#### Check the Failover Flag on the New Slots

Skip this step on PostgreSQL 15 and 16, or if n4 has no physical standby.

On PostgreSQL 17 and later, the slots just created on n4 are marked for
failover when the subscribing node runs Spock 6.0.0 or later. A
subscriber on an older version may create its slot without the flag, and
native slot sync does not copy such a slot to a standby.

`spock.sub_create()` returns before the subscription has created its slot
on n4. Repeat the following query until it lists all three slots, then
check the flag on each:

```sql
SELECT slot_name, active, failover
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
    'SELECT slot_name, active, failover
     FROM pg_replication_slots
     WHERE plugin = ''spock_output''
     ORDER BY slot_name'
) AS t(slot_name text, active boolean, failover boolean);

-- Expected output:
--          slot_name          | active | failover
-- ----------------------------+--------+----------
--  spk_inventory_n4_sub_n4_n1 | t      | t
--  spk_inventory_n4_sub_n4_n2 | t      | t
--  spk_inventory_n4_sub_n4_n3 | t      | t
```

For a slot that shows `failover` as `f`:

1. Disable the subscription that uses it, on the subscribing node.
2. Repeat the query above until the slot shows `active` as `f`. The
   helper skips a slot that is still in use.
3. Run `SELECT spock.slot_enable_failover();` on n4 as a superuser.
4. Run the query again and confirm that `failover` is now `t`.
5. Enable the subscription again.

### Monitor Replication Lag

Next, we will verify that n4 is keeping up with n1.

We monitor the lag_tracker table on n4 to ensure replication from n1 is
keeping up. The lag_tracker shows the time difference between when a
transaction was committed on n1 and when the transaction was applied
on n4.

If lag is growing (for example, 5 seconds, then 10 seconds, then 30
seconds), n4 cannot keep up with the write load from n1. This could
indicate the following issues:

- Network bandwidth issues.
- n4 hardware is slower than n1.
- Long-running transactions blocking replication.

We want lag under 59 seconds, or lag_bytes=0 (meaning n4 has processed
everything). If lag stays consistently low, n4 is successfully integrated.

The following example monitors replication lag:

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
            'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
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

Next, we will verify that all of the nodes are registered; the following
query displays all registered nodes:

```sql
SELECT n.node_id, n.node_name, n.location, n.country, i.if_dsn
FROM dblink(
    'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
    'SELECT n.node_id, n.node_name, n.location, n.country, i.if_dsn
     FROM spock.node n
     JOIN spock.node_interface i ON n.node_id = i.if_nodeid
     ORDER BY n.node_name'
) AS t(node_id integer, node_name text, location text, country text, if_dsn text);

-- Expected output:
--  node_id | node_name |  location   | country |                           if_dsn
-- ---------+-----------+-------------+---------+------------------------------------------------------------
--    16385 | n1        | New York    | USA     | host=127.0.0.1 dbname=inventory port=5432 user=pgedge ...
--    16386 | n2        | Chicago     | USA     | host=127.0.0.1 dbname=inventory port=5433 user=pgedge ...
--    16387 | n3        | Boston      | USA     | host=127.0.0.1 dbname=inventory port=5434 user=pgedge ...
--    16389 | n4        | Los Angeles | USA     | host=127.0.0.1 dbname=inventory port=5435 user=pgedge ...
```

### Show the Status of all Subscriptions

Next, we want to verify that all subscriptions are replicating. In the
following example, the query displays subscription status across all nodes:

```sql
-- Get subscriptions from all nodes
SELECT node_name, subscription_name, status, provider_node
FROM (
    -- n1 subscriptions
    SELECT 'n1' as node_name, *
    FROM dblink(
        'host=127.0.0.1 dbname=inventory port=5432 user=pgedge password=1safepassword',
        'SELECT subscription_name, status, provider_node FROM spock.sub_show_status()'
    ) AS t(subscription_name text, status text, provider_node text)

    UNION ALL

    -- n2 subscriptions
    SELECT 'n2' as node_name, *
    FROM dblink(
        'host=127.0.0.1 dbname=inventory port=5433 user=pgedge password=1safepassword',
        'SELECT subscription_name, status, provider_node FROM spock.sub_show_status()'
    ) AS t(subscription_name text, status text, provider_node text)

    UNION ALL

    -- n3 subscriptions
    SELECT 'n3' as node_name, *
    FROM dblink(
        'host=127.0.0.1 dbname=inventory port=5434 user=pgedge password=1safepassword',
        'SELECT subscription_name, status, provider_node FROM spock.sub_show_status()'
    ) AS t(subscription_name text, status text, provider_node text)

    UNION ALL

    -- n4 subscriptions
    SELECT 'n4' as node_name, *
    FROM dblink(
        'host=127.0.0.1 dbname=inventory port=5435 user=pgedge password=1safepassword',
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

Next, we perform a series of tests to verify that the cluster is
replicating between n1 and n4.

First, we create a test table and insert data:

```sql
-- On n1
CREATE TABLE test_replication (id serial primary key, data text, created_at timestamp default now());
INSERT INTO test_replication (data) VALUES ('Test from n1');

-- On n4 (wait a few seconds)
SELECT * FROM test_replication;
-- Expected: Row appears on n4
```

### Test Replication between n4 and n1

Next, we insert data on n4:

```sql
INSERT INTO test_replication (data) VALUES ('Test from n4');
```
Then, verify replication on n1:

```sql
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

All nodes are now bidirectionally replicating:

- n1, n2, n3, and n4 are all bidirectionally connected.
- Total subscriptions: 12 (each node subscribes to 3 others).


## Troubleshooting

The following sections share commands that can help diagnose issues you
encounter while adding a node:

### Subscription Status Stuck in 'initializing' or 'down'

The following commands can help you identify places where a node is
encountering issues with replication status:

```sql
-- Check subscription status
SELECT * FROM spock.sub_show_status();

-- Check table sync status
SELECT * FROM spock.sub_show_table('sub_n2_n4', 'public.test_replication');

-- Check logs
SELECT * FROM pg_stat_replication;
```

### Node Addition Fails with a Timeout

If `spock.add_node()` raises a timeout while waiting for a sync event or
for the new node to catch up, the node is likely larger than the default
3-minute budget allows for. Remove the partially added node with
`spock.remove_node`, then retry with a longer budget, as described in
[Setting the Synchronisation
Timeout](#setting-the-synchronisation-timeout):

```sql
SET spock.sync_timeout = '2h';
```

Use the lag query below to gauge how long catchup actually takes before
choosing a value.

### Replication Lag Too High

Use the following command to check replication lag on a subscribing node:

```sql
-- Check lag on receiver node
SELECT origin_name, receiver_name,
       now() - commit_timestamp as lag,
       replication_lag_bytes
FROM spock.lag_tracker
ORDER BY lag DESC;
```

### Slot Not Advancing

Use the following command to check the status of a replication slot:

```sql
-- Check slot status
SELECT slot_name, slot_type, active, restart_lsn, confirmed_flush_lsn
FROM pg_replication_slots
WHERE slot_name LIKE 'spk_%';
```

