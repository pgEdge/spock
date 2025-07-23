-- Adds a new node to the cluster of Spock.

-- Usage:
-- CALL add_node(
--   'source_node_name',
--   'source_node_dsn',
--   'new_node_name',
--   'new_node_dsn',
--   'new_node_location', -- optional
--   'new_node_country',  -- optional
--   new_node_info        -- optional (jsonb)
-- );

-- Example:
-- CALL add_node(
--   'n1',
--   'host=127.0.0.1 dbname=pgedge port=5431 user=pgedge password=pgedge',
--   'n4',
--   'host=127.0.0.1 dbname=pgedge port=5434 user=pgedge password=pgedge'
-- );


-- ============================================================================


-- ============================================================================
-- Function: get_spock_nodes
-- Purpose : Retrieves all Spock nodes and their DSNs from a remote cluster.
-- Arguments:
--   remote_dsn - DSN string to connect to the remote cluster.
-- Returns  : Table of node_id, node_name, location, country, info, dsn.
-- Usage    : SELECT * FROM get_spock_nodes('host=... dbname=... user=... password=...');
-- ============================================================================

CREATE OR REPLACE FUNCTION get_spock_nodes(remote_dsn text)
RETURNS TABLE (
    node_id    integer,
    node_name  text,
    location   text,
    country    text,
    info       text,
    dsn        text
)
LANGUAGE plpgsql
AS
$$
BEGIN
    -- Build and execute remote SQL to fetch node details and DSNs
    RETURN QUERY
    SELECT *
    FROM dblink(
        remote_dsn,
        'SELECT n.node_id, n.node_name, n.location, n.country, n.info, i.if_dsn
         FROM spock.node n
         JOIN spock.node_interface i ON n.node_id = i.if_nodeid'
    ) AS t(
        node_id integer,
        node_name text,
        location text,
        country text,
        info text,
        dsn text
    );

    -- LOG: Successfully fetched Spock nodes from remote cluster
    RAISE LOG E'[STEP] get_spock_nodes: Retrieved nodes from remote DSN: %', remote_dsn;
END;
$$;


-- ============================================================================


-- ============================================================================
-- Function: create_sub
-- Purpose : Creates a Spock subscription on a remote node via dblink.
-- Arguments:
--   node_dsn              - DSN string to connect to the remote node.
--   subscription_name     - Name of the subscription to create.
--   provider_dsn          - DSN string of the provider node.
--   replication_sets      - Text array of replication sets.
--   synchronize_structure - Whether to synchronize structure (boolean).
--   synchronize_data      - Whether to synchronize data (boolean).
--   forward_origins       - Text array of origins to forward.
--   apply_delay           - Interval for apply delay.
--   enabled               - Whether to enable the subscription (boolean).
-- Returns  : void
-- Usage    : PERFORM create_sub(...);
-- ============================================================================

CREATE OR REPLACE FUNCTION create_sub(
    node_dsn text,
    subscription_name text,
    provider_dsn text,
    replication_sets text,
    synchronize_structure boolean,
    synchronize_data boolean,
    forward_origins text,
    apply_delay interval,
    enabled boolean
)
RETURNS void
LANGUAGE plpgsql
AS
$$
DECLARE
    sid oid;
    remotesql text;
    exists_count int;
BEGIN
    -- ============================================================================
    -- Step 1: Check if subscription already exists on remote node
    -- ============================================================================
    remotesql := format(
        'SELECT count(*) FROM spock.subscription WHERE sub_name = %L',
        subscription_name
    );

    RAISE INFO E'
    [STEP 1] Remote SQL for subscription existence check: %
    ', remotesql;

    SELECT * FROM dblink(node_dsn, remotesql) AS t(count int) INTO exists_count;

    RAISE INFO E'
    [STEP 1] Subscription existence check for "%": found % record(s).
    ', subscription_name, exists_count;

    IF exists_count > 0 THEN
        RAISE LOG E'
        [STEP 1] Subscription "%" already exists on remote node. Skipping creation.
        ', subscription_name;
        RETURN;
    END IF;


    -- ============================================================================
    -- Step 2: Build remote SQL for subscription creation
    -- ============================================================================
    remotesql := format(
        'SELECT spock.sub_create(
            subscription_name := %L,
            provider_dsn := %L,
            replication_sets := %s,
            synchronize_structure := %L,
            synchronize_data := %L,
            forward_origins := %L,
            apply_delay := %L,
            enabled := %L
        )',
        subscription_name,
        provider_dsn,
        replication_sets,
        synchronize_structure::text,
        synchronize_data::text,
        forward_origins,
        apply_delay::text,
        enabled::text
    );

    RAISE INFO E'
    [STEP 2] Remote SQL for subscription creation: %
    ', remotesql;


    -- ============================================================================
    -- Step 3: Execute subscription creation on remote node using dblink
    -- ============================================================================
    BEGIN
        SELECT * FROM dblink(node_dsn, remotesql) AS t(sid oid) INTO sid;

        RAISE LOG E'
        [STEP 3] Subscription "%" created with id % on remote node.
        ', subscription_name, sid;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION E'
            [STEP 3] Subscription "%" creation failed on remote node! Error: %
            ', subscription_name, SQLERRM;
    END;
END;
$$;


-- ============================================================================


-- ============================================================================
-- Function: create_replication_slot
-- Purpose : Creates a logical replication slot on a remote node via dblink.
-- Arguments:
--   node_dsn   - DSN string to connect to the remote node.
--   slot_name  - Name of the replication slot to create.
--   plugin     - Logical decoding plugin (default: 'spock_output').
-- Returns  : void
-- Usage    : PERFORM create_replication_slot(...);
-- ============================================================================

CREATE OR REPLACE FUNCTION create_replication_slot(
    node_dsn text,
    slot_name text,
    plugin text DEFAULT 'spock_output'
)
RETURNS void
LANGUAGE plpgsql
AS
$$
DECLARE
    remotesql text;
    result RECORD;
    exists_count int;
BEGIN
    -- ============================================================================
    -- Step 1: Check if replication slot already exists on remote node
    -- ============================================================================
    remotesql := format(
        'SELECT count(*) FROM pg_replication_slots WHERE slot_name = %L',
        slot_name
    );

    SELECT * FROM dblink(node_dsn, remotesql) AS t(count int) INTO exists_count;

    IF exists_count > 0 THEN
        RAISE LOG E'
        [STEP 1] Replication slot "%" already exists on remote node. Skipping creation.',
        slot_name;
        RETURN;
    END IF;


    -- ============================================================================
    -- Step 2: Build remote SQL for replication slot creation
    -- ============================================================================
    remotesql := format(
        'SELECT slot_name, lsn FROM pg_create_logical_replication_slot(%L, %L)',
        slot_name, plugin
    );

    RAISE INFO E'
    [STEP 2] Remote SQL for slot creation: %
    ', remotesql;


    -- ============================================================================
    -- Step 3: Execute replication slot creation on remote node using dblink
    -- ============================================================================
    BEGIN
        SELECT * FROM dblink(node_dsn, remotesql) AS t(slot_name text, lsn pg_lsn) INTO result;
        RAISE LOG E'
        [STEP 3] Created replication slot "%" with plugin "%" on remote node.',
        slot_name, plugin;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE INFO E'
            [STEP 3] Replication slot "%" may already exist or creation failed. Error: %
            ', slot_name, SQLERRM;
    END;
END;
$$;


-- ============================================================================


-- ============================================================================
-- Function: sync_event
-- Purpose : Triggers a sync event on a remote node and returns the resulting LSN.
-- Arguments:
--   node_dsn - DSN string to connect to the remote node.
-- Returns  : pg_lsn (the LSN of the sync event)
-- Usage    : SELECT sync_event('host=... dbname=... user=... password=...');
-- ============================================================================

CREATE OR REPLACE FUNCTION sync_event(node_dsn text)
RETURNS pg_lsn
LANGUAGE plpgsql
AS
$$
DECLARE
    sync_rec RECORD;
    remotesql text;
BEGIN
    -- Build remote SQL to trigger sync event
    remotesql := 'SELECT spock.sync_event();';

    RAISE INFO E'[STEP] Remote SQL for sync event: %', remotesql;

    -- Execute remote SQL and capture the returned LSN
    SELECT * FROM dblink(node_dsn, remotesql) AS t(lsn pg_lsn) INTO sync_rec;

    RAISE LOG E'[STEP] Sync event triggered on remote node: % with LSN %', node_dsn, sync_rec.lsn;

    RETURN sync_rec.lsn;
END;
$$;


-- ============================================================================


-- ============================================================================
-- Function: wait_for_sync_event
-- Purpose : Waits for a sync event to be confirmed on a remote node via dblink.
-- Arguments:
--   node_dsn       - DSN string to connect to the remote node.
--   wait_for_all   - Boolean, whether to wait for all providers.
--   provider_node  - Name of the provider node.
--   sync_lsn       - The LSN to wait for.
--   timeout_ms     - Timeout in milliseconds.
-- Returns  : void
-- Usage    : PERFORM wait_for_sync_event(...);
-- ============================================================================

CREATE OR REPLACE FUNCTION wait_for_sync_event(
    node_dsn text,
    wait_for_all boolean,
    provider_node text,
    sync_lsn pg_lsn,
    timeout_ms integer
)
RETURNS void
LANGUAGE plpgsql
AS
$$
DECLARE
    remotesql text;
    dummy RECORD; -- Capture dblink result
BEGIN
    -- Build remote SQL to call spock.wait_for_sync_event
    remotesql := format(
        'CALL spock.wait_for_sync_event(%L, %L, %L::pg_lsn, %s);',
        wait_for_all,
        provider_node,
        sync_lsn::text,
        timeout_ms
    );

    RAISE INFO E'
    [STEP] Remote SQL for waiting for sync event: %
    ', remotesql;

    -- Execute remote SQL via dblink and capture result
    SELECT * INTO dummy
    FROM dblink(node_dsn, remotesql) AS t(result text);

    RAISE LOG E'
    [STEP] Waited for sync event on remote node: %
    ', node_dsn;
END;
$$;


-- ============================================================================


-- ============================================================================
-- Procedure: create_node
-- Purpose  : Creates a Spock node on a remote cluster via dblink.
-- Arguments:
--   node_name - Name of the node to create.
--   dsn       - DSN string to connect to the remote cluster.
--   location  - Location of the node (default: 'NY').
--   country   - Country of the node (default: 'USA').
--   info      - Additional node info (default: '{}'::jsonb).
-- Returns   : void
-- Usage     : CALL create_node(...);
-- ============================================================================

CREATE OR REPLACE PROCEDURE create_node(
    node_name text,
    dsn text,
    location text DEFAULT 'NY',
    country text DEFAULT 'USA',
    info jsonb DEFAULT '{}'::jsonb
)
LANGUAGE plpgsql
AS
$$
DECLARE
    joinid oid;
    remotesql text;
    exists_count int;
BEGIN
    -- ============================================================================
    -- Step 1: Check if node already exists on remote cluster
    -- ============================================================================
    remotesql := format(
        'SELECT count(*) FROM spock.node WHERE node_name = %L',
        node_name
    );

    RAISE INFO E'
    [STEP 1] Remote SQL for node existence check: %
    ', remotesql;

    SELECT * FROM dblink(dsn, remotesql) AS t(count int) INTO exists_count;

    RAISE INFO E'
    [STEP 1] Remote node existence check for node "%": found % record(s).
    ', node_name, exists_count;

    IF exists_count > 0 THEN
        RAISE LOG E'
        [STEP 1] Node "%" already exists remotely. Skipping creation.
        ', node_name;
        RETURN;
    END IF;


    -- ============================================================================
    -- Step 2: Build remote SQL for node creation
    -- ============================================================================
    remotesql := format(
        'SELECT spock.node_create(
            node_name := %L,
            dsn := %L,
            location := %L,
            country := %L,
            info := %L::jsonb
        )',
        node_name, dsn, location, country, info::text
    );

    RAISE INFO E'
    [STEP 2] Remote SQL for node creation: %
    ', remotesql;


    -- ============================================================================
    -- Step 3: Execute node creation on remote cluster using dblink
    -- ============================================================================
    BEGIN
        SELECT * FROM dblink(dsn, remotesql) AS t(joinid oid) INTO joinid;

        IF joinid IS NOT NULL THEN
            RAISE LOG E'
            [STEP 3] Node "%" created remotely with id % and DSN: %
            ', node_name, joinid, dsn;
        ELSE
            RAISE EXCEPTION E'
            [STEP 3] Node "%" creation failed remotely!
            ', node_name;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION E'
            [STEP 3] Node "%" creation failed remotely! Error: %
            ', node_name, SQLERRM;
    END;

END;
$$;


-- ============================================================================


-- ============================================================================
-- Function: get_commit_timestamp
-- Purpose : Retrieves the commit timestamp for replication lag between two nodes.
-- Arguments:
--   node_dsn - DSN string to connect to the remote node.
--   n1       - Origin node name.
--   n2       - Receiver node name.
-- Returns  : Timestamp of the commit for the lag entry.
-- Usage    : SELECT get_commit_timestamp(node_dsn, 'n1', 'n2');
-- ============================================================================

CREATE OR REPLACE FUNCTION get_commit_timestamp(
    node_dsn text,
    n1 text,
    n2 text
)
RETURNS timestamp
LANGUAGE plpgsql
AS
$$
DECLARE
    ts_rec RECORD;
    remotesql text;
BEGIN
    -- Build remote SQL to fetch commit timestamp from lag_tracker
    remotesql := format(
        'SELECT commit_timestamp FROM spock.lag_tracker WHERE origin_name = %L AND receiver_name = %L',
        n1, n2
    );

    RAISE INFO E'[STEP] Remote SQL for getting commit timestamp: %', remotesql;

    -- Execute remote SQL and capture the commit timestamp
    SELECT * FROM dblink(node_dsn, remotesql) AS t(commit_timestamp timestamp) INTO ts_rec;

    RAISE LOG E'[STEP] Commit timestamp for lag between "%" and "%": %', n1, n2, ts_rec.commit_timestamp;

    RETURN ts_rec.commit_timestamp;
END;
$$;


-- ============================================================================


-- ============================================================================
-- Function: advance_replication_slot
-- Purpose : Advances a logical replication slot to a specific commit timestamp on a remote node via dblink.
-- Arguments:
--   node_dsn      - DSN string to connect to the remote node.
--   slot_name     - Name of the replication slot to advance.
--   sync_timestamp- Commit timestamp to advance the slot to.
-- Returns  : void
-- Usage    : PERFORM advance_replication_slot(node_dsn, slot_name, sync_timestamp);
-- ============================================================================

CREATE OR REPLACE FUNCTION advance_replication_slot(
    node_dsn text,
    slot_name text,
    sync_timestamp timestamp
)
RETURNS void
LANGUAGE plpgsql
AS
$$
DECLARE
    remotesql text;
    slot_advance_result RECORD;
BEGIN
    -- ============================================================================
    -- Step 1: Check if sync_timestamp is NULL
    -- ============================================================================
    IF sync_timestamp IS NULL THEN
        RAISE INFO E'
        [STEP 1] Commit timestamp is NULL, skipping slot advance for slot "%".
        ', slot_name;
        RETURN;
    END IF;

    -- ============================================================================
    -- Step 2: Build remote SQL for advancing replication slot
    -- ============================================================================
    remotesql := format(
        'WITH lsn_cte AS (
            SELECT spock.get_lsn_from_commit_ts(%L, %L::timestamp) AS lsn
        )
        SELECT pg_replication_slot_advance(%L, lsn) FROM lsn_cte;',
        slot_name, sync_timestamp::text, slot_name
    );

    RAISE INFO E'
    [STEP 2] Remote SQL for advancing replication slot: %
    ', remotesql;
    RAISE INFO E'
    [STEP 2] Remote node DSN: %
    ', node_dsn;

    -- ============================================================================
    -- Step 3: Execute slot advance on remote node using dblink
    -- ============================================================================
    SELECT * FROM dblink(node_dsn, remotesql) INTO slot_advance_result;

    RAISE LOG E'
    [STEP 3] Replication slot "%" advanced to commit timestamp % on remote node: %',
    slot_name, sync_timestamp, node_dsn;
END;
$$;


-- ============================================================================


-- ============================================================================
-- Function: enable_sub
-- Purpose : Enables a Spock subscription on a remote node via dblink.
-- Arguments:
--   node_dsn   - DSN string to connect to the remote node.
--   sub_name   - Name of the subscription to enable.
--   immediate  - Whether to enable immediately (default: true).
-- Returns  : void
-- Usage    : PERFORM enable_sub(node_dsn, sub_name, immediate);
-- ============================================================================

CREATE OR REPLACE FUNCTION enable_sub(
    node_dsn text,
    sub_name text,
    immediate boolean DEFAULT true
)
RETURNS void
LANGUAGE plpgsql
AS
$$
DECLARE
    remotesql text;
BEGIN
    -- ============================================================================
    -- Step 1: Build remote SQL for enabling subscription
    -- ============================================================================
    remotesql := format(
        'SELECT spock.sub_enable(subscription_name := %L, immediate := %L);',
        sub_name, immediate::text
    );

    RAISE INFO E'
    [STEP 1] Remote SQL for enabling subscription: %
    ', remotesql;

    -- ============================================================================
    -- Step 2: Execute enabling subscription on remote node using dblink
    -- ============================================================================
    PERFORM * FROM dblink(node_dsn, remotesql) AS t(result text);

    RAISE LOG E'
    [STEP 2] Enabled subscription "%" on remote node: %
    ', sub_name, node_dsn;
END;
$$;


-- ============================================================================


-- ============================================================================
-- Function: monitor_replication_lag
-- Purpose : Monitors replication lag between nodes on a remote cluster via dblink.
-- Arguments:
--   node_dsn - DSN string to connect to the remote node.
-- Returns  : void
-- Usage    : PERFORM monitor_replication_lag(node_dsn);
-- ============================================================================

CREATE OR REPLACE FUNCTION monitor_replication_lag(node_dsn text)
RETURNS void
LANGUAGE plpgsql
AS
$$
DECLARE
    remotesql text;
BEGIN
    -- ============================================================================
    -- Step 1: Build remote SQL for monitoring replication lag
    -- ============================================================================
    remotesql := $sql$
        DO '
        DECLARE
            lag_n1_n4 interval;
            lag_n2_n4 interval;
            lag_n3_n4 interval;
        BEGIN
            LOOP
                -- Calculate lag from n1 to n4
                SELECT now() - commit_timestamp INTO lag_n1_n4
                FROM spock.lag_tracker
                WHERE origin_name = ''n1'' AND receiver_name = ''n4'';

                -- Calculate lag from n2 to n4
                SELECT now() - commit_timestamp INTO lag_n2_n4
                FROM spock.lag_tracker
                WHERE origin_name = ''n2'' AND receiver_name = ''n4'';

                -- Calculate lag from n3 to n4
                SELECT now() - commit_timestamp INTO lag_n3_n4
                FROM spock.lag_tracker
                WHERE origin_name = ''n3'' AND receiver_name = ''n4'';

                -- Log current lag values
                RAISE NOTICE ''[MONITOR] n1 → n4 lag: %, n2 → n4 lag: %, n3 → n4 lag: %'',
                             COALESCE(lag_n1_n4::text, ''NULL''),
                             COALESCE(lag_n2_n4::text, ''NULL''),
                             COALESCE(lag_n3_n4::text, ''NULL'');

                -- Exit loop when all lags are below 59 seconds
                EXIT WHEN lag_n1_n4 IS NOT NULL AND lag_n2_n4 IS NOT NULL AND lag_n3_n4 IS NOT NULL
                          AND extract(epoch FROM lag_n1_n4) < 59
                          AND extract(epoch FROM lag_n2_n4) < 59
                          AND extract(epoch FROM lag_n3_n4) < 59;

                -- Sleep for 1 second before next check
                PERFORM pg_sleep(1);
            END LOOP;
        END
        ';
    $sql$;

    -- ============================================================================
    -- Step 2: Execute remote monitoring SQL via dblink
    -- ============================================================================
    PERFORM dblink(node_dsn, remotesql);

    -- ============================================================================
    -- Step 3: Log completion of monitoring
    -- ============================================================================
    RAISE LOG E'[STEP] monitor_replication_lag: Monitoring replication lag completed on remote node: %', node_dsn;
END;
$$;



/* =============================================================================
 * Procedure: add_node
 *
 * Description:
 *   Adds a new node to an existing Spock-based logical replication cluster.
 *   The procedure:
 *     - Creates the new node
 *     - Sets up replication subscriptions between the new node and existing nodes
 *     - Creates necessary replication slots
 *     - Triggers synchronization events
 *     - Advances replication slots to ensure consistent replication
 *     - Enables all subscriptions for bidirectional replication
 *
 * Parameters:
 *   src_node_name     - Name of the source node initiating the add operation
 *   src_dsn           - DSN of the source node
 *   new_node_name     - Name of the node to be added
 *   new_node_dsn      - DSN of the new node
 *   new_node_location - Location (default: 'NY')
 *   new_node_country  - Country (default: 'USA')
 *   new_node_info     - JSONB object with additional metadata (default: '{}')
 *
 * Notes:
 *   - Assumes `create_node`, `create_sub`, `enable_sub`, `create_replication_slot`,
 *     `sync_event`, `wait_for_sync_event`, `get_commit_timestamp`,
 *     and `advance_replication_slot` are already defined and available.
 *   - Ensures minimal interruption and consistency using sync + slot advance.
 * =============================================================================
 */


CREATE OR REPLACE PROCEDURE add_node(
    src_node_name text,
    src_dsn text,
    new_node_name text,
    new_node_dsn text,
    new_node_location text DEFAULT 'NY',
    new_node_country text DEFAULT 'USA',
    new_node_info jsonb DEFAULT '{}'::jsonb
)
LANGUAGE plpgsql
AS
$$
DECLARE
    rec RECORD;
    dbname text;
    slot_name text;
    sync_lsn pg_lsn;
    sync_timestamp timestamp;
    timeout_ms integer;
    node_count integer;
BEGIN
    -- ============================================================================
    -- Step 1: Create the new node
    -- ============================================================================
    CALL create_node(
        new_node_name,
        new_node_dsn,
        new_node_location,
        new_node_country,
        new_node_info
    );

    RAISE LOG E'
    [STEP 1] New node "%" created with DSN: %
    ', new_node_name, new_node_dsn;


    -- ============================================================================
    -- Step 2: Create subscriptions from all source nodes to the new node
    -- ============================================================================
    FOR rec IN
        SELECT * FROM get_spock_nodes(src_dsn)
    LOOP
        IF rec.node_name = src_node_name THEN
            CONTINUE;
        END IF;
        PERFORM create_sub(
            new_node_dsn,
            'sub_'|| rec.node_name || '_' || new_node_name,
        rec.dsn,
            'ARRAY[''default'', ''default_insert_only'', ''ddl_sql'']',
            false,
            false,
            '{}',
            '0'::interval,
            false
        );
    END LOOP;


    -- ============================================================================
    -- Step 3: Determine timeout based on node count
    -- ============================================================================
    select count(*) into node_count FROM get_spock_nodes(src_dsn);
    IF node_count < 2 then
        timeout_ms=10;
    ELSE
        timeout_ms=10000;
    END IF;
    RAISE INFO 'Node count %',node_count;


    -- ============================================================================
    -- Step 4: Create replication slots on all source nodes for the new node
    -- ============================================================================
    FOR rec IN
        SELECT * FROM get_spock_nodes(src_dsn)
    LOOP
        IF rec.node_name = src_node_name THEN
            CONTINUE;
        END IF;
        RAISE LOG E'
        [STEP 4] Node: %, Location: %, Country: %, DSN: %
        ', rec.node_name, rec.location, rec.country, rec.dsn;
        dbname := substring(rec.dsn from 'dbname=([^\s]+)');
        IF dbname IS NULL THEN
            dbname := 'pgedge';
        END IF;
        slot_name := left('spk_' || dbname || '_' || rec.node_name || '_sub_' || rec.node_name || '_' || new_node_name, 64);
        PERFORM create_replication_slot(
            rec.dsn,
            slot_name,
            'spock_output'
        );
    END LOOP;


    -- ============================================================================
    -- Step 5: Trigger sync events on all source nodes except the source node
    -- ============================================================================
    FOR rec IN
        SELECT * FROM get_spock_nodes(src_dsn)
    LOOP
        IF rec.node_name != src_node_name THEN
            SELECT sync_event(rec.dsn) INTO sync_lsn;
            PERFORM wait_for_sync_event(src_dsn, true, rec.node_name, sync_lsn,timeout_ms);
        END IF;
    END LOOP;


    -- ============================================================================
    -- Step 6: Create subscription from new node to source node and enable it
    -- ============================================================================
    PERFORM create_sub(
        new_node_dsn,
        'sub_' || src_node_name || '_' || new_node_name,
        src_dsn,
        'ARRAY[''default'', ''default_insert_only'', ''ddl_sql'']',
        true,
        true,
        '{}',
        '0'::interval,
        true
    );
    SELECT sync_event(src_dsn) INTO sync_lsn;
    PERFORM wait_for_sync_event(new_node_dsn, true, src_node_name, sync_lsn, timeout_ms);


    -- ============================================================================
    -- Step 7: Advance replication slots on all source nodes except the source node
    -- ============================================================================
    FOR rec IN
        SELECT * FROM get_spock_nodes(src_dsn)
    LOOP
        IF rec.node_name != src_node_name THEN
        SELECT get_commit_timestamp(new_node_dsn, src_node_name, rec.node_name) INTO sync_timestamp;
        slot_name := 'spk_' || dbname || '_' || src_node_name || '_sub_' || rec.node_name || '_' || new_node_name;
        PERFORM advance_replication_slot(rec.dsn, slot_name, sync_timestamp);
     END IF;
    END LOOP;


    -- ============================================================================
    -- Step 8: Create subscriptions from all source nodes to the new node and enable them
    -- ============================================================================
    FOR rec IN
        SELECT * FROM get_spock_nodes(src_dsn)
    LOOP
        PERFORM create_sub(
            rec.dsn,
            'sub_'|| new_node_name || '_' || rec.node_name,
            new_node_dsn,
            'ARRAY[''default'', ''default_insert_only'', ''ddl_sql'']',
  false,
            false,
            '{}',
            '0'::interval,
            true
        );
    END LOOP;


    -- ============================================================================
    -- Step 9: Enable subscriptions on the new node for all source nodes except itself
    -- ============================================================================
    FOR rec IN
        SELECT * FROM get_spock_nodes(src_dsn)
    LOOP
        IF rec.node_name = new_node_name THEN
            CONTINUE;
        END IF;
        PERFORM enable_sub(
            new_node_dsn,
            'sub_'|| rec.node_name || '_' || new_node_name);
    END LOOP;
END;
$$;
