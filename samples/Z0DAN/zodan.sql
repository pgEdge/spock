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
-- Procedure: get_spock_nodes
-- Purpose : Retrieves all Spock nodes and their DSNs from a remote cluster.
-- Arguments:
--   remote_dsn - DSN string to connect to the remote cluster.
--   verb - Verbose output flag
-- Usage    : CALL get_spock_nodes('host=... dbname=... user=... password=...', true);
-- ============================================================================

DROP PROCEDURE IF EXISTS get_spock_nodes(text, boolean);
CREATE OR REPLACE PROCEDURE get_spock_nodes(src_dsn text, verb boolean)
LANGUAGE plpgsql
AS
$$
BEGIN
    -- Build and execute remote SQL to fetch node details and DSNs
    -- Note: Procedures cannot return tables directly, so we'll use RAISE NOTICE
    -- to display the results or store them in a temporary table
    
    IF verb THEN
        RAISE NOTICE E'[STEP] get_spock_nodes: Retrieved nodes from remote DSN: %', src_dsn;
    END IF;
    
    -- Create a temporary table to store results
    CREATE TEMP TABLE IF NOT EXISTS temp_spock_nodes (
        node_id    integer,
        node_name  text,
        location   text,
        country    text,
        info       text,
        dsn        text
    );
    
    -- Clear previous results
    DELETE FROM temp_spock_nodes;
    
    -- Insert results into temp table
    IF verb THEN
        RAISE NOTICE '[QUERY] SELECT n.node_id, n.node_name, n.location, n.country, n.info, i.if_dsn FROM spock.node n JOIN spock.node_interface i ON n.node_id = i.if_nodeid';
    END IF;
    INSERT INTO temp_spock_nodes
    SELECT *
    FROM dblink(
        src_dsn,
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
    
    IF verb THEN
        RAISE NOTICE 'Retrieved % nodes from remote cluster', (SELECT count(*) FROM temp_spock_nodes);
    END IF;
END;
$$;

-- ============================================================================
-- Temporary table to store spock nodes information
-- ============================================================================
CREATE TEMP TABLE IF NOT EXISTS temp_spock_nodes (
    node_id integer,
    node_name text,
    location text,
    country text,
    info text,
    dsn text
);

-- ============================================================================
-- Procedure to get all spock nodes from the source node
-- ============================================================================
CREATE OR REPLACE PROCEDURE get_spock_nodes(
    src_dsn text,  -- Source node DSN to query from
    verb boolean DEFAULT false
)
LANGUAGE plpgsql AS $$
BEGIN
    -- Clear existing data
    DELETE FROM temp_spock_nodes;
    
    -- Get all nodes from the source node
    IF verb THEN
        RAISE NOTICE '[QUERY] SELECT n.node_id, n.node_name, n.location, n.country, n.info, i.if_dsn FROM spock.node n JOIN spock.node_interface i ON n.node_id = i.if_nodeid';
    END IF;
    INSERT INTO temp_spock_nodes
    SELECT t.node_id, t.node_name, t.location, t.country, t.info, t.dsn
    FROM dblink(src_dsn, 
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
END;
$$;

-- ============================================================================
-- Procedure: create_sub
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
--   verb                  - Verbose output flag
-- Usage    : CALL create_sub(...);
-- ============================================================================

CREATE OR REPLACE PROCEDURE create_sub(
    node_dsn text,
    subscription_name text,
    provider_dsn text,
    replication_sets text,
    synchronize_structure boolean,
    synchronize_data boolean,
    forward_origins text,
    apply_delay interval,
    enabled boolean,
    force_text_transfer boolean,
    verb boolean
)
LANGUAGE plpgsql
AS
$$
DECLARE
    sid oid;
    remotesql text;
    exists_count int;
BEGIN
    remotesql := format(
        'SELECT spock.sub_create(
            subscription_name := %L,
            provider_dsn := %L,
            replication_sets := %s,
            synchronize_structure := %L,
            synchronize_data := %L,
            forward_origins := %L,
            apply_delay := %L,
            enabled := %L,
            force_text_transfer := %L
        )',
        subscription_name,
        provider_dsn,
        replication_sets,
        synchronize_structure::text,
        synchronize_data::text,
        forward_origins,
        apply_delay::text,
        enabled::text,
        force_text_transfer::text
    );

    IF verb THEN
        RAISE NOTICE '[QUERY] SQL: %', remotesql;
    END IF;
    
    BEGIN
        SELECT * FROM dblink(node_dsn, remotesql) AS t(sid oid) INTO sid;

    EXCEPTION
        WHEN OTHERS THEN
            IF verb THEN
                RAISE EXCEPTION E'
            [STEP 3] Subscription "%" creation failed on remote node! Error: %
            ', subscription_name, SQLERRM;
            END IF;
    END;
END;
$$;


-- ============================================================================


-- ============================================================================
-- Procedure: create_replication_slot
-- Purpose : Creates a logical replication slot on a remote node via dblink.
-- Arguments:
--   node_dsn   - DSN string to connect to the remote node.
--   slot_name  - Name of the replication slot to create.
--   verb       - Verbose output flag
--   plugin     - Logical decoding plugin (default: 'spock_output').
-- Usage    : CALL create_replication_slot(...);
-- ============================================================================

CREATE OR REPLACE PROCEDURE create_replication_slot(
    node_dsn text,
    slot_name text,
    verb boolean,
    plugin text DEFAULT 'spock_output'
)
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

    IF verb THEN
        RAISE NOTICE '[QUERY] %', remotesql;
    END IF;

    SELECT * FROM dblink(node_dsn, remotesql) AS t(count int) INTO exists_count;

    IF exists_count > 0 THEN
        IF verb THEN
            RAISE NOTICE E'
        [STEP 1] Replication slot "%" already exists on remote node. Skipping creation.',
        slot_name;
        END IF;
        RETURN;
    END IF;


    -- ============================================================================
    -- Step 2: Build remote SQL for replication slot creation
    -- ============================================================================
    remotesql := format(
        'SELECT slot_name, lsn FROM pg_create_logical_replication_slot(%L, %L)',
        slot_name, plugin
    );

    IF verb THEN
        RAISE NOTICE '[QUERY] %', remotesql;
    END IF;


    -- ============================================================================
    -- Step 3: Execute replication slot creation on remote node using dblink
    -- ============================================================================
    BEGIN
        SELECT * FROM dblink(node_dsn, remotesql) AS t(slot_name text, lsn pg_lsn) INTO result;
        IF verb THEN
            RAISE NOTICE E'
        [STEP 3] Created replication slot "%" with plugin "%" on remote node.',
        slot_name, plugin;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            IF verb THEN
                RAISE NOTICE E'
            [STEP 3] Replication slot "%" may already exist or creation failed. Error: %
            ', slot_name, SQLERRM;
            END IF;
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

-- ============================================================================
-- Procedure: sync_event
-- Purpose : Triggers a sync event on a remote node and returns the resulting LSN.
-- Arguments:
--   node_dsn - DSN string to connect to the remote node.
--   verb - Verbose output flag
--   sync_lsn - OUT parameter to receive the LSN
-- Usage    : CALL sync_event('host=... dbname=... user=... password=...', true, NULL);
-- ============================================================================

CREATE OR REPLACE PROCEDURE sync_event(
    node_dsn text, 
    verb boolean,
    INOUT sync_lsn pg_lsn DEFAULT NULL
)
LANGUAGE plpgsql
AS
$$
DECLARE
    sync_rec RECORD;
    remotesql text;
BEGIN
    -- Build remote SQL to trigger sync event
    remotesql := 'SELECT spock.sync_event();';

    IF verb THEN
        RAISE NOTICE '[QUERY] %', remotesql;
    END IF;

    -- Execute remote SQL and capture the returned LSN
    SELECT * FROM dblink(node_dsn, remotesql) AS t(lsn pg_lsn) INTO sync_rec;

    IF verb THEN
        RAISE NOTICE E'[STEP] Sync event triggered on remote node: % with LSN %', node_dsn, sync_rec.lsn;
    END IF;

    sync_lsn := sync_rec.lsn;
END;
$$;


-- ============================================================================






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
    verb boolean,
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
    IF verb THEN
        RAISE NOTICE 'Checking if node % exists on remote cluster', node_name;
    END IF;
    -- ============================================================================
    -- Step 1: Check if node already exists on remote cluster
    -- ============================================================================
    remotesql := format(
        'SELECT count(*) FROM spock.node WHERE node_name = %L',
        node_name
    );

    IF verb THEN
        RAISE NOTICE '[QUERY] %', remotesql;
    END IF;

    SELECT * FROM dblink(dsn, remotesql) AS t(count int) INTO exists_count;

    IF verb THEN
        RAISE NOTICE E'
    [STEP 1] Remote node existence check for node "%": found % record(s).
    ', node_name, exists_count;
    END IF;

    IF exists_count > 0 THEN
        IF verb THEN
            RAISE NOTICE 'Node % already exists remotely. Skipping creation.', node_name;
        END IF;
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

    IF verb THEN
        RAISE NOTICE '[QUERY] %', remotesql;
    END IF;


    -- ============================================================================
    -- Step 3: Execute node creation on remote cluster using dblink
    -- ============================================================================
    BEGIN
        SELECT * FROM dblink(dsn, remotesql) AS t(joinid oid) INTO joinid;

        IF joinid IS NOT NULL THEN
            IF verb THEN
                RAISE NOTICE 'Node % created remotely with id % and DSN: %', node_name, joinid, dsn;
            END IF;
        ELSE
            IF verb THEN
                RAISE EXCEPTION E'
            [STEP 3] Node "%" creation failed remotely!
            ', node_name;
            END IF;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            IF verb THEN
                RAISE EXCEPTION E'
            [STEP 3] Node "%" creation failed remotely! Error: %
            ', node_name, SQLERRM;
            END IF;
    END;

END;
$$;


-- ============================================================================


-- ============================================================================
-- Procedure: get_commit_timestamp
-- Purpose : Retrieves the commit timestamp for replication lag between two nodes.
-- Arguments:
--   node_dsn - DSN string to connect to the remote node.
--   n1       - Origin node name.
--   n2       - Receiver node name.
--   verb     - Verbose output flag
--   commit_ts - OUT parameter to receive the commit timestamp
-- Usage    : CALL get_commit_timestamp(node_dsn, 'n1', 'n2', true, NULL);
-- ============================================================================

CREATE OR REPLACE PROCEDURE get_commit_timestamp(
    node_dsn text,
    n1 text,
    n2 text,
    verb boolean,
    INOUT commit_ts timestamp DEFAULT NULL
)
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

    IF verb THEN
        RAISE NOTICE '[QUERY] %', remotesql;
    END IF;

    -- Execute remote SQL and capture the commit timestamp
    SELECT * FROM dblink(node_dsn, remotesql) AS t(commit_timestamp timestamp) INTO ts_rec;

    IF verb THEN
        RAISE NOTICE E'[STEP] Commit timestamp for lag between "%" and "%": %', n1, n2, ts_rec.commit_timestamp;
    END IF;

    commit_ts := ts_rec.commit_timestamp;
END;
$$;


-- ============================================================================


-- ============================================================================
-- Procedure: advance_replication_slot
-- Purpose : Advances a logical replication slot to a specific commit timestamp on a remote node via dblink.
-- Arguments:
--   node_dsn      - DSN string to connect to the remote node.
--   slot_name     - Name of the replication slot to advance.
--   sync_timestamp- Commit timestamp to advance the slot to.
--   verb          - Verbose output flag
-- Usage    : CALL advance_replication_slot(node_dsn, slot_name, sync_timestamp, true);
-- ============================================================================

CREATE OR REPLACE PROCEDURE advance_replication_slot(
    node_dsn text,
    slot_name text,
    sync_timestamp timestamp,
    verb boolean
)
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
        IF verb THEN
            RAISE NOTICE E'
        [STEP 1] Commit timestamp is NULL, skipping slot advance for slot "%".
        ', slot_name;
        END IF;
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

    IF verb THEN
        RAISE NOTICE '[QUERY] %', remotesql;
    END IF;
    IF verb THEN
        RAISE NOTICE E'
    [STEP 2] Remote node DSN: %
    ', node_dsn;
    END IF;

    -- ============================================================================
    -- Step 3: Execute slot advance on remote node using dblink
    -- ============================================================================
    SELECT * FROM dblink(node_dsn, remotesql) AS t(result text) INTO slot_advance_result;

    IF verb THEN
        RAISE NOTICE E'
    [STEP 3] Replication slot "%" advanced to commit timestamp % on remote node: %',
    slot_name, sync_timestamp, node_dsn;
    END IF;
END;
$$;


-- ============================================================================


-- ============================================================================
-- Procedure: enable_sub
-- Purpose : Enables a Spock subscription on a remote node via dblink.
-- Arguments:
--   node_dsn   - DSN string to connect to the remote node.
--   sub_name   - Name of the subscription to enable.
--   verb       - Verbose output flag
--   immediate  - Whether to enable immediately (default: true).
-- Usage    : CALL enable_sub(node_dsn, sub_name, true, true);
-- ============================================================================

CREATE OR REPLACE PROCEDURE enable_sub(
    node_dsn text,
    sub_name text,
    verb boolean,
    immediate boolean DEFAULT true
)
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

    IF verb THEN
        RAISE NOTICE '[QUERY] %', remotesql;
    END IF;

    -- ============================================================================
    -- Step 2: Execute enabling subscription on remote node using dblink
    -- ============================================================================
    PERFORM * FROM dblink(node_dsn, remotesql) AS t(result text);

    IF verb THEN
        RAISE NOTICE E'
    [STEP 2] Enabled subscription "%" on remote node: %
    ', sub_name, node_dsn;
    END IF;
END;
$$;


-- ============================================================================


-- ============================================================================
-- Procedure: monitor_replication_lag
-- Purpose : Monitors replication lag between nodes on a remote cluster via dblink.
-- Arguments:
--   node_dsn - DSN string to connect to the remote node.
--   verb     - Verbose output flag
-- Usage    : CALL monitor_replication_lag(node_dsn, true);
-- ============================================================================

CREATE OR REPLACE PROCEDURE monitor_replication_lag(node_dsn text, verb boolean)
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
    IF verb THEN
        RAISE NOTICE E'[STEP] monitor_replication_lag: Executing remote monitoring SQL on node: %', node_dsn;
    END IF;
    PERFORM dblink(node_dsn, remotesql);

    -- ============================================================================
    -- Step 3: Log completion of monitoring
    -- ============================================================================
    IF verb THEN
        RAISE NOTICE E'[STEP] monitor_replication_lag: Monitoring replication lag completed on remote node: %', node_dsn;
    END IF;
END;
$$;

-- ============================================================================
-- Procedure to monitor replication lag between nodes
-- ============================================================================

CREATE OR REPLACE PROCEDURE monitor_replication_lag_wait(
    origin_node text,
    receiver_node text,
    max_lag_seconds integer DEFAULT 59,
    check_interval_seconds integer DEFAULT 1,
    verb boolean DEFAULT true
)
LANGUAGE plpgsql
AS $$
DECLARE
    lag_interval interval;
    start_time timestamp := now();
    elapsed_interval interval;
BEGIN
    IF verb THEN
        RAISE NOTICE 'Monitoring replication lag from % to % (max lag: % seconds)', 
                     origin_node, receiver_node, max_lag_seconds;
    END IF;

    LOOP
        -- Get current lag
        SELECT now() - commit_timestamp INTO lag_interval
        FROM spock.lag_tracker
        WHERE origin_name = origin_node AND receiver_name = receiver_node;

        -- Calculate elapsed time
        elapsed_interval := now() - start_time;

        IF verb THEN
            RAISE NOTICE '% → % lag: % (elapsed: %)',
                         origin_node, receiver_node,
                         COALESCE(lag_interval::text, 'NULL'),
                         elapsed_interval::text;
        END IF;

        -- Exit when lag is within acceptable limits
        EXIT WHEN lag_interval IS NOT NULL 
                  AND extract(epoch FROM lag_interval) < max_lag_seconds;

        -- Sleep before next check
        PERFORM pg_sleep(check_interval_seconds);
    END LOOP;

    IF verb THEN
        RAISE NOTICE 'Replication lag from % to % is now within acceptable limits (% seconds)', 
                     origin_node, receiver_node, max_lag_seconds;
    END IF;
END;
$$;

-- ============================================================================
-- Procedure to monitor multiple replication paths simultaneously
-- ============================================================================

CREATE OR REPLACE PROCEDURE monitor_multiple_replication_lags(
    lag_configs jsonb,
    max_lag_seconds integer DEFAULT 59,
    check_interval_seconds integer DEFAULT 1,
    verb boolean DEFAULT true
)
LANGUAGE plpgsql
AS $$
DECLARE
    lag_record record;
    lag_interval interval;
    all_within_limits boolean;
    start_time timestamp := now();
    elapsed_interval interval;
    config jsonb;
    max_wait_seconds integer := 60;
    wait_count integer := 0;
    lag_data record;
BEGIN
    IF verb THEN
        RAISE NOTICE 'Monitoring multiple replication lags (max lag: % seconds, timeout: % seconds)', 
                     max_lag_seconds, max_wait_seconds;
        RAISE NOTICE 'Monitoring % paths', jsonb_array_length(lag_configs);
    END IF;

    -- Wait for initial data to appear
    WHILE NOT EXISTS (SELECT 1 FROM spock.lag_tracker LIMIT 1) AND wait_count < 10 LOOP
        IF verb THEN
            RAISE NOTICE 'Waiting for lag_tracker data to appear... (attempt %/10)', wait_count + 1;
        END IF;
        PERFORM pg_sleep(2);
        wait_count := wait_count + 1;
    END LOOP;

    IF NOT EXISTS (SELECT 1 FROM spock.lag_tracker LIMIT 1) THEN
        RAISE NOTICE 'No lag_tracker data available after waiting - skipping lag monitoring';
        RETURN;
    END IF;

    LOOP
        all_within_limits := true;
        
        IF verb THEN
            RAISE NOTICE 'Checking lag for % paths...', jsonb_array_length(lag_configs);
        END IF;
        
        -- Check each replication path
        FOR config IN SELECT * FROM jsonb_array_elements(lag_configs)
        LOOP
            IF verb THEN
                RAISE NOTICE 'Checking path: % → %', config->>'origin', config->>'receiver';
            END IF;
            
            SELECT now() - commit_timestamp INTO lag_interval
            FROM spock.lag_tracker
            WHERE origin_name = config->>'origin' 
              AND receiver_name = config->>'receiver';

            IF verb THEN
                RAISE NOTICE '% → % lag: %',
                             config->>'origin', config->>'receiver',
                             COALESCE(lag_interval::text, 'NULL');
            END IF;

            -- Check if this path is within limits
            IF lag_interval IS NULL OR extract(epoch FROM lag_interval) >= max_lag_seconds THEN
                all_within_limits := false;
            END IF;
        END LOOP;
        
        -- Also show all available lag data for debugging
        IF verb THEN
            RAISE NOTICE 'All available lag data:';
            FOR lag_data IN SELECT origin_name, receiver_name, commit_timestamp, replication_lag FROM spock.lag_tracker LOOP
                RAISE NOTICE '  % → %: commit_ts=%s, lag=%s', 
                    lag_data.origin_name, lag_data.receiver_name, 
                    lag_data.commit_timestamp, lag_data.replication_lag;
            END LOOP;
        END IF;

        -- Calculate elapsed time
        elapsed_interval := now() - start_time;

        IF verb THEN
            RAISE NOTICE 'All paths within limits: % (elapsed: %)', 
                         all_within_limits, elapsed_interval::text;
        END IF;

        -- Exit when all paths are within acceptable limits
        EXIT WHEN all_within_limits;
        
        -- Exit if we've been waiting too long
        IF extract(epoch FROM elapsed_interval) > max_wait_seconds THEN
            IF verb THEN
                RAISE NOTICE 'Timeout reached (% seconds) - exiting lag monitoring', max_wait_seconds;
            END IF;
            EXIT;
        END IF;

        -- Sleep before next check
        PERFORM pg_sleep(check_interval_seconds);
    END LOOP;

    IF verb THEN
        IF all_within_limits THEN
            RAISE NOTICE 'All replication lags are now within acceptable limits (% seconds)', max_lag_seconds;
        ELSE
            RAISE NOTICE 'Lag monitoring completed with timeout - some paths may still have high lag';
        END IF;
    END IF;
END;
$$;

-- ============================================================================
-- Example usage procedure (equivalent to the workflow logic)
-- ============================================================================

CREATE OR REPLACE PROCEDURE wait_for_n3_sync(
    max_lag_seconds integer DEFAULT 59,
    check_interval_seconds integer DEFAULT 1,
    verb boolean DEFAULT true
)
LANGUAGE plpgsql
AS $$
DECLARE
    lag_configs jsonb;
BEGIN
    -- Define the replication paths to monitor
    lag_configs := '[
        {"origin": "n1", "receiver": "n3"},
        {"origin": "n2", "receiver": "n3"}
    ]'::jsonb;

    -- Monitor both paths
    CALL monitor_multiple_replication_lags(
        lag_configs, 
        max_lag_seconds, 
        check_interval_seconds, 
        verb
    );
END;
$$;

-- ============================================================================

-- ============================================================================
-- Procedure to monitor lag using dblink
-- ============================================================================

CREATE OR REPLACE PROCEDURE monitor_lag_with_dblink(
    src_node_name text,
    new_node_name text,
    new_node_dsn text,
    verb boolean DEFAULT true
)
LANGUAGE plpgsql
AS $$
DECLARE
    lag_interval interval;
    max_wait_seconds integer := 60;
    start_time timestamp := now();
    elapsed_interval interval;
    loop_count integer := 0;
    lag_sql text;
    lag_result record;
BEGIN
    RAISE NOTICE '    Monitoring lag from % to % using dblink...', src_node_name, new_node_name;
    LOOP
        loop_count := loop_count + 1;
        lag_sql := format(
            'SELECT now() - commit_timestamp AS lag_interval FROM spock.lag_tracker WHERE origin_name = %L AND receiver_name = %L',
            src_node_name, new_node_name
        );
        -- Use dblink to get lag from remote node
        EXECUTE format(
            'SELECT * FROM dblink(%L, %L) AS t(lag_interval interval)',
            new_node_dsn, lag_sql
        ) INTO lag_result;

        lag_interval := lag_result.lag_interval;
        elapsed_interval := now() - start_time;

        RAISE NOTICE '% → % lag: % (elapsed: %, loop: %)',
            src_node_name, new_node_name,
            COALESCE(lag_interval::text, 'NULL'),
            elapsed_interval::text, loop_count;

        EXIT WHEN lag_interval IS NOT NULL AND extract(epoch FROM lag_interval) < 59;
        IF extract(epoch FROM elapsed_interval) > max_wait_seconds THEN
            RAISE NOTICE 'Timeout reached (% seconds) - exiting lag monitoring', max_wait_seconds;
            EXIT;
        END IF;
        PERFORM pg_sleep(1);
    END LOOP;

    IF lag_interval IS NOT NULL AND extract(epoch FROM lag_interval) < 59 THEN
        RAISE NOTICE '    ✓ Replication lag monitoring completed';
    ELSE
        RAISE NOTICE '    - Replication lag monitoring timed out';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '    ✗ Replication lag monitoring failed';
        RAISE;
END;
$$;

-- ============================================================================




-- ============================================================================
-- Procedure to verify prerequisites for adding a new node
-- (Combines Phase 1: Validating source node prerequisites and Phase 2: Validating new node prerequisites)
-- ============================================================================
CREATE OR REPLACE PROCEDURE verify_node_prerequisites(
    src_node_name text,
    src_dsn text,
    new_node_name text,
    new_node_dsn text,
    verb boolean
) LANGUAGE plpgsql AS $$
DECLARE
    src_exists integer;
    src_sub_exists integer;
    src_repset_exists integer;
    new_exists integer;
    new_sub_exists integer;
    new_repset_exists integer;
BEGIN
    RAISE NOTICE 'Phase 1: Validating source and new node prerequisites';
    -- Validating source node prerequisites
    SELECT count(*) INTO src_exists FROM spock.node WHERE node_name = src_node_name;
    IF src_exists > 0 THEN
        RAISE NOTICE '    ✗ %', rpad('Checking source node ' || src_node_name || ' already exists', 120, ' ');
        RAISE EXCEPTION 'Exiting add_node: Source node % already exists', src_node_name;
    ELSE
        RAISE NOTICE '    ✓ %', rpad('Checking source node ' || src_node_name || ' does not exist', 120, ' ');
    END IF;

    SELECT count(*) INTO src_sub_exists FROM spock.subscription s JOIN spock.node n ON s.sub_origin = n.node_id WHERE n.node_name = src_node_name;
    IF src_sub_exists > 0 THEN
        RAISE NOTICE '    %[FAILED]', rpad('Checking source node "' || src_node_name || '" has subscriptions', 60, ' ');
        RAISE EXCEPTION 'Exiting add_node: Source node % has subscriptions', src_node_name;
    ELSE
        RAISE NOTICE '    ✓ %', rpad('Checking source node ' || src_node_name || ' has no subscriptions', 120, ' ');
    END IF;

    SELECT count(*) INTO src_repset_exists FROM spock.replication_set rs JOIN spock.node n ON rs.set_nodeid = n.node_id WHERE n.node_name = src_node_name;
    IF src_repset_exists > 0 THEN
        RAISE NOTICE '    %[FAILED]', rpad('Checking source node "' || src_node_name || '" has replication sets', 60, ' ');
        RAISE EXCEPTION 'Exiting add_node: Source node % has replication sets', src_node_name;
    ELSE
        RAISE NOTICE '    ✓ %', rpad('Checking source node ' || src_node_name || ' has no replication sets', 120, ' ');
    END IF;

    -- Validating new node prerequisites
    SELECT count(*) INTO new_exists FROM spock.node WHERE node_name = new_node_name;
    IF new_exists > 0 THEN
        RAISE NOTICE '    %[FAILED]', rpad('Checking new node "' || new_node_name || '" already exists', 60, ' ');
        RAISE EXCEPTION 'Exiting add_node: New node % already exists', new_node_name;
    ELSE
        RAISE NOTICE '    ✓ %', rpad('Checking new node ' || new_node_name || ' does not exist', 120, ' ');
    END IF;
    SELECT count(*) INTO new_sub_exists FROM spock.subscription s JOIN spock.node n ON s.sub_origin = n.node_id WHERE n.node_name = new_node_name;
    IF new_sub_exists > 0 THEN
        RAISE NOTICE '    %[FAILED]', rpad('Checking new node "' || new_node_name || '" has subscriptions', 60, ' ');
        RAISE EXCEPTION 'Exiting add_node: New node % has subscriptions', new_node_name;
    ELSE
        RAISE NOTICE '    ✓ %', rpad('Checking new node ' || new_node_name || ' has no subscriptions', 120, ' ');
    END IF;
    SELECT count(*) INTO new_repset_exists FROM spock.replication_set rs JOIN spock.node n ON rs.set_nodeid = n.node_id WHERE n.node_name = new_node_name;
    IF new_repset_exists > 0 THEN
        RAISE NOTICE '    %[FAILED]', rpad('Checking new node "' || new_node_name || '" has replication sets', 60, ' ');
        RAISE EXCEPTION 'Exiting add_node: New node % has replication sets', new_node_name;
    ELSE
        RAISE NOTICE '    ✓ %', rpad('Checking new node ' || new_node_name || ' has no replication sets', 120, ' ');
    END IF;
END;
$$;

-- ============================================================================
-- Procedure to create nodes only
-- ============================================================================
CREATE OR REPLACE PROCEDURE create_nodes_only(
    src_node_name text,
    src_dsn text,
    new_node_name text,
    new_node_dsn text,
    verb boolean,
    new_node_location text,
    new_node_country text,
    new_node_info jsonb,
    INOUT initial_node_count integer
) LANGUAGE plpgsql AS $$
BEGIN
    -- Phase 2: Creating nodes
    RAISE NOTICE 'Phase 2: Creating nodes';
    BEGIN
        CALL create_node(src_node_name, src_dsn, verb);
        RAISE NOTICE '    ✓ %', rpad('Creating source node ' || src_node_name || '...', 120, ' ');
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE '    ✗ %', rpad('Creating source node ' || src_node_name || '...', 120, ' ');
            RAISE;
    END;

    BEGIN
        CALL create_node(new_node_name, new_node_dsn, verb, new_node_location, new_node_country, new_node_info);
        RAISE NOTICE '    ✓ %', rpad('Creating new node ' || new_node_name || '...', 120, ' ');
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE '    ✗ %', rpad('Creating new node ' || new_node_name || '...', 120, ' ');
            RAISE;
    END;

    -- Get initial node count from source node using inline dblink
    SELECT count INTO initial_node_count
    FROM dblink(src_dsn, 'SELECT count(*) FROM spock.node')
        AS t(count integer);
END;
$$;

-- ============================================================================
-- Procedure to configure cross-node replication
-- ============================================================================
CREATE OR REPLACE PROCEDURE create_replication_slots(
    src_node_name text,
    src_dsn text,
    new_node_name text,
    new_node_dsn text,
    verb boolean
) LANGUAGE plpgsql AS $$
DECLARE
    rec RECORD;
    dbname text;
    slot_name text;
BEGIN
    -- Phase 4: Configuring cross-node replication
    RAISE NOTICE 'Phase 4: Configuring cross-node replication';
    BEGIN
        FOR rec IN SELECT * FROM temp_spock_nodes LOOP
            
            IF rec.node_name = src_node_name THEN
                CONTINUE;
            END IF;
            dbname := substring(rec.dsn from 'dbname=([^\s]+)');
            IF dbname IS NULL THEN
                dbname := 'pgedge';
            END IF;
            slot_name := left('spk_' || dbname || '_' || rec.node_name || '_sub_' || rec.node_name || '_' || new_node_name, 64);
            CALL create_replication_slot(
                rec.dsn,
                slot_name,
                verb,
                'spock_output'
            );
            RAISE NOTICE '    ✓ %', rpad('Creating replication slot ' || slot_name || '...', 120, ' ');
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE '    ✗ Creating replication slots...';
            RAISE;
    END;
END;
$$;


-- ============================================================================
-- Procedure to create disabled subscriptions and slots
-- ============================================================================
CREATE OR REPLACE PROCEDURE create_disable_subscriptions_and_slots(
    src_node_name text,  -- Source node name
    src_dsn text,        -- Source node DSN
    new_node_name text,  -- New node name
    new_node_dsn text,   -- New node DSN
    verb boolean         -- Verbose flag
) LANGUAGE plpgsql AS $$
DECLARE
    rec RECORD;
    subscription_count integer := 0;
    remotesql text;
    dbname text;
    slot_name text;
BEGIN
    RAISE NOTICE 'Phase 4: Creating disabled subscriptions and slots';
    
    -- Get all existing nodes (excluding source and new)
    CALL get_spock_nodes(src_dsn, verb);
    
    -- Check if there are any "other" nodes (not source, not new)
    IF (SELECT count(*) FROM temp_spock_nodes WHERE node_name != src_node_name AND node_name != new_node_name) = 0 THEN
        RAISE NOTICE '    - No other nodes exist, skipping disabled subscriptions';
        RETURN;
    END IF;
    
    -- For each "other" node (not source, not new), create disabled subscription and slot
    FOR rec IN SELECT * FROM temp_spock_nodes WHERE node_name != src_node_name AND node_name != new_node_name LOOP
        -- Create replication slot on the "other" node
        BEGIN
            dbname := substring(rec.dsn from 'dbname=([^\s]+)');
            IF dbname IS NULL THEN dbname := 'pgedge'; END IF;
            slot_name := left('spk_' || dbname || '_' || rec.node_name || '_sub_' || rec.node_name || '_' || new_node_name, 64);
            
            remotesql := format('SELECT slot_name, lsn FROM pg_create_logical_replication_slot(%L, ''spock_output'');', slot_name);
            IF verb THEN
                RAISE NOTICE '    Remote SQL for slot creation: %', remotesql;
            END IF;
            
            PERFORM * FROM dblink(rec.dsn, remotesql) AS t(slot_name text, lsn pg_lsn);
            RAISE NOTICE '    ✓ %', rpad('Creating replication slot ' || slot_name || ' on node ' || rec.node_name, 120, ' ');
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE '    ✗ %', rpad('Creating replication slot ' || slot_name || ' on node ' || rec.node_name, 120, ' ');
                CONTINUE;
        END;
        
        -- Create disabled subscription on new node from "other" node
        BEGIN
            CALL create_sub(
                new_node_dsn,                                 -- Create on new node
                'sub_' || rec.node_name || '_' || new_node_name, -- sub_<other_node>_<new_node>
                rec.dsn,                                      -- Provider is other node
                'ARRAY[''default'', ''default_insert_only'', ''ddl_sql'']', -- Replication sets
                false,                                        -- synchronize_structure
                false,                                        -- synchronize_data
                '{}',                                         -- forward_origins
                '0'::interval,                                -- apply_delay
                false,                                        -- enabled (disabled)
                false,                                        -- force_text_transfer
                verb                                          -- verbose
            );
            RAISE NOTICE '    ✓ %', rpad('Creating initial subscription sub_' || rec.node_name || '_' || new_node_name || ' on node ' || rec.node_name, 120, ' ');
            subscription_count := subscription_count + 1;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE '    ✗ %', rpad('Creating initial subscription sub_' || rec.node_name || '_' || new_node_name || ' on node ' || rec.node_name, 120, ' ');
        END;
    END LOOP;
    
    IF subscription_count = 0 THEN
        RAISE NOTICE '    - No disabled subscriptions created';
    END IF;
END;
$$;

-- ============================================================================
-- Procedure to enable disabled subscriptions
-- ============================================================================
CREATE OR REPLACE PROCEDURE enable_disabled_subscriptions(
    src_node_name text,
    src_dsn text,
    new_node_name text,
    new_node_dsn text,
    verb boolean
) LANGUAGE plpgsql AS $$
DECLARE
    rec RECORD;
BEGIN
    RAISE NOTICE 'Phase 9: Enabling disabled subscriptions';
    
    -- Check if this is a 2-node scenario (only source and new node)
    IF (SELECT count(*) FROM temp_spock_nodes WHERE node_name != src_node_name AND node_name != new_node_name) = 0 THEN
        -- 2-node scenario: enable the disabled subscription from source to new node
        BEGIN
            CALL enable_sub(
                new_node_dsn,
                'sub_' || src_node_name || '_' || new_node_name,
                verb,  -- verb
                true   -- immediate
            );
            RAISE NOTICE '    ✓ %', rpad('Enabling subscription sub_' || src_node_name || '_' || new_node_name || '...', 120, ' ');
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE '    ✗ %', rpad('Enabling subscription sub_' || src_node_name || '_' || new_node_name || '...', 120, ' ');
                RAISE;
        END;
        RETURN;
    END IF;
    
    -- Multi-node scenario: original logic for other nodes
    -- Enable the initially disabled subscriptions
    BEGIN
        DECLARE
            subscription_count integer := 0;
        BEGIN
            FOR rec IN SELECT * FROM temp_spock_nodes LOOP
                IF rec.node_name = src_node_name THEN   
                    CONTINUE;  -- Skip source node as it's handled separately
                END IF;
                IF rec.node_name = new_node_name THEN
                    CONTINUE;  -- Skip new node to avoid self-subscription
                END IF;
                
                CALL enable_sub(
                    new_node_dsn,
                    'sub_'|| rec.node_name || '_' || new_node_name,
                    verb,  -- verb
                    true   -- immediate
                );
                RAISE NOTICE '    ✓ %', rpad('Enabling subscription sub_' || rec.node_name || '_' || new_node_name || '...', 120, ' ');
                subscription_count := subscription_count + 1;
            END LOOP;
            
            IF subscription_count = 0 THEN
                RAISE NOTICE '    - %', rpad('No subscriptions to enable', 120, ' ');
            END IF;
        END;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE '    ✗ Enabling disabled subscriptions...';
            RAISE;
    END;
END;
$$;

-- ============================================================================
-- Procedure to create a subscription from new node to source node only
-- ============================================================================
CREATE OR REPLACE PROCEDURE create_sub_on_new_node_to_src_node(
    src_node_name   text,  -- Source node name
    src_dsn         text,  -- Source node DSN
    new_node_name   text,  -- New node name
    new_node_dsn    text,  -- New node DSN
    verb            boolean  -- Verbose flag
) LANGUAGE plpgsql AS $$
BEGIN
    RAISE NOTICE 'Phase 10: Creating subscription from new node to source node';
    CALL create_sub(
        src_dsn,                                      -- Create on source node
        'sub_' || new_node_name || '_' || src_node_name, -- sub_<new_node>_<src_node>
        new_node_dsn,                                 -- Provider is new node
        'ARRAY[''default'', ''default_insert_only'', ''ddl_sql'']', -- Replication sets
        false,                                        -- synchronize_structure
        false,                                        -- synchronize_data
        '{}',                                         -- forward_origins
        '0'::interval,                                -- apply_delay
        true,                                         -- enabled
        false,                                        -- force_text_transfer
        verb                                          -- verbose
    );
    RAISE NOTICE '    ✓ %', rpad('Creating subscription sub_' || new_node_name || '_' || src_node_name || ' on node ' || src_node_name || '...', 120, ' ');
END;
$$;

-- ============================================================================
-- Procedure to create new to source node subscription
-- ============================================================================
CREATE OR REPLACE PROCEDURE create_new_to_source_subscription(
    src_node_name text,
    src_dsn text,
    new_node_name text,
    new_node_dsn text,
    verb boolean
) LANGUAGE plpgsql AS $$
BEGIN
    RAISE NOTICE 'Phase 10: Creating new to source node subscription';
    
    -- Create subscription from new node to source node (enabled with sync)
    CALL create_sub(
        src_dsn,
        'sub_' || new_node_name || '_' || src_node_name,
        new_node_dsn,
        'ARRAY[''default'', ''default_insert_only'', ''ddl_sql'']',
        false,   -- synchronize_structure
        false,   -- synchronize_data
        '{}',
        '0'::interval,
        true,   -- enabled
        false,   -- force_text_transfer
        verb
    );
    RAISE NOTICE '    ✓ %', rpad('Creating subscription sub_' || new_node_name || '_' || src_node_name || ' on node ' || new_node_name || '...', 120, ' ');
END;
$$;

-- ============================================================================
-- Procedure to create source to new node subscription
-- ============================================================================
CREATE OR REPLACE PROCEDURE create_source_to_new_subscription(
    src_node_name   text,  -- Source node name
    src_dsn         text,  -- Source node DSN
    new_node_name   text,  -- New node name
    new_node_dsn    text,  -- New node DSN
    verb            boolean  -- Verbose flag
) LANGUAGE plpgsql AS $$
BEGIN
    RAISE NOTICE 'Phase 5: Creating source to new node subscription';
    
    -- Create subscription from source to new node (enabled with sync)
    CALL create_sub(
        new_node_dsn,                                 -- Create on new node
        'sub_' || src_node_name || '_' || new_node_name, -- sub_<src_node>_<new_node>
        src_dsn,                                      -- Provider is source node
        'ARRAY[''default'', ''default_insert_only'', ''ddl_sql'']', -- Replication sets
        true,                                         -- synchronize_structure
        true,                                         -- synchronize_data
        '{}',                                         -- forward_origins
        '0'::interval,                                -- apply_delay
        true,                                         -- enabled
        false,                                        -- force_text_transfer
        verb                                          -- verbose
    );
    RAISE NOTICE '    ✓ %', rpad('Creating subscription sub_' || src_node_name || '_' || new_node_name || ' on node ' || new_node_name || '...', 120, ' ');
END;
$$;

-- ============================================================================
-- Procedure to trigger sync events on other nodes and wait on source
-- ============================================================================
CREATE OR REPLACE PROCEDURE trigger_sync_on_other_nodes_and_wait_on_source(
    src_node_name text,  -- Source node name
    src_dsn text,        -- Source node DSN
    new_node_name text,  -- New node name
    new_node_dsn text,   -- New node DSN
    verb boolean         -- Verbose flag
) LANGUAGE plpgsql AS $$
DECLARE
    rec RECORD;
    sync_lsn pg_lsn;
    timeout_ms integer := 1200000;  -- 20 minutes timeout
    remotesql text;
BEGIN
    RAISE NOTICE 'Phase 6: Triggering sync events on other nodes and waiting on source';
    
    -- Check if this is a 2-node scenario (only source and new node)
    IF (SELECT count(*) FROM temp_spock_nodes WHERE node_name != src_node_name AND node_name != new_node_name) = 0 THEN
        RAISE NOTICE '    - No other nodes exist, skipping sync events';
        RETURN;
    END IF;
    
    -- Multi-node scenario: trigger sync on "other" nodes and wait on source
    FOR rec IN SELECT * FROM temp_spock_nodes WHERE node_name != src_node_name AND node_name != new_node_name LOOP
        -- Trigger sync event on "other" node
        BEGIN
            remotesql := 'SELECT spock.sync_event();';
            IF verb THEN
                RAISE NOTICE '    Remote SQL for sync event on %: %', rec.node_name, remotesql;
            END IF;
            
            SELECT * FROM dblink(rec.dsn, remotesql) AS t(lsn pg_lsn) INTO sync_lsn;
            RAISE NOTICE '    ✓ %', rpad('Triggering sync event on node ' || rec.node_name || ' (LSN: ' || sync_lsn || ')...', 120, ' ');
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE '    ✗ %', rpad('Triggering sync event on node ' || rec.node_name || '...', 120, ' ');
                CONTINUE;
        END;
        
        -- Wait for sync event on source node
        BEGIN
            remotesql := format('CALL spock.wait_for_sync_event(true, %L, %L::pg_lsn, %s);', 
                               rec.node_name, sync_lsn, timeout_ms);
            IF verb THEN
                RAISE NOTICE '    Remote SQL for waiting sync event: %', remotesql;
            END IF;
            
            PERFORM * FROM dblink(src_dsn, remotesql) AS t(result text);
            RAISE NOTICE '    ✓ %', rpad('Waiting for sync event from ' || rec.node_name || ' on source node ' || src_node_name || '...', 120, ' ');
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE '    ✗ %', rpad('Waiting for sync event from ' || rec.node_name || ' on source node ' || src_node_name || '...', 120, ' ');
        END;
    END LOOP;
END;
$$;

-- ============================================================================
-- Procedure to check commit timestamp and advance replication slot
-- ============================================================================
CREATE OR REPLACE PROCEDURE check_commit_timestamp_and_advance_slot(
    src_node_name text,  -- Source node name
    src_dsn text,        -- Source node DSN
    new_node_name text,  -- New node name
    new_node_dsn text,   -- New node DSN
    verb boolean         -- Verbose flag
) LANGUAGE plpgsql AS $$
DECLARE
    rec RECORD;
    commit_ts timestamp;
    slot_name text;
    dbname text;
    remotesql text;
BEGIN
    RAISE NOTICE 'Phase 8: Checking commit timestamp and advancing replication slot';
    
    -- Check if this is a 2-node scenario (only source and new node)
    IF (SELECT count(*) FROM temp_spock_nodes WHERE node_name != src_node_name AND node_name != new_node_name) = 0 THEN
        RAISE NOTICE '    - No other nodes exist, skipping commit timestamp check';
        RETURN;
    END IF;
    
    -- Multi-node scenario: check commit timestamp for "other" nodes to new node
    FOR rec IN SELECT * FROM temp_spock_nodes WHERE node_name != src_node_name AND node_name != new_node_name LOOP
        -- Check commit timestamp for lag from "other" node to new node
        BEGIN
            remotesql := format('SELECT commit_timestamp FROM spock.lag_tracker WHERE origin_name = %L AND receiver_name = %L', 
                               rec.node_name, new_node_name);
            IF verb THEN
                RAISE NOTICE '    Remote SQL for commit timestamp check: %', remotesql;
            END IF;
            
            SELECT * FROM dblink(new_node_dsn, remotesql) AS t(ts timestamp) INTO commit_ts;
            
            IF commit_ts IS NOT NULL THEN
                RAISE NOTICE '    ✓ %', rpad('Found commit timestamp for ' || rec.node_name || '->' || new_node_name || ': ' || commit_ts, 120, ' ');
            ELSE
                RAISE NOTICE '    - %', rpad('No commit timestamp found for ' || rec.node_name || '->' || new_node_name, 120, ' ');
                CONTINUE;
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE '    ✗ %', rpad('Checking commit timestamp for ' || rec.node_name || '->' || new_node_name, 120, ' ');
                CONTINUE;
        END;
        
        -- Advance replication slot based on commit timestamp
        BEGIN
            dbname := substring(rec.dsn from 'dbname=([^\s]+)');
            IF dbname IS NULL THEN dbname := 'pgedge'; END IF;
            slot_name := left('spk_' || dbname || '_' || rec.node_name || '_sub_' || rec.node_name || '_' || new_node_name, 64);
            
            -- First check if slot exists and get current LSN
            remotesql := format('SELECT restart_lsn FROM pg_replication_slots WHERE slot_name = %L', slot_name);
            IF verb THEN
                RAISE NOTICE '    Remote SQL for slot check: %', remotesql;
            END IF;
            
            DECLARE
                current_lsn pg_lsn;
                target_lsn pg_lsn;
            BEGIN
                SELECT * FROM dblink(rec.dsn, remotesql) AS t(lsn pg_lsn) INTO current_lsn;
                
                IF current_lsn IS NULL THEN
                    RAISE NOTICE '    - Slot % does not exist, skipping advancement', slot_name;
                    CONTINUE;
                END IF;
                
                -- Get target LSN from commit timestamp
                remotesql := format('SELECT spock.get_lsn_from_commit_ts(%L, %L::timestamp)', slot_name, commit_ts);
                IF verb THEN
                    RAISE NOTICE '    Remote SQL for LSN lookup: %', remotesql;
                END IF;
                
                SELECT * FROM dblink(rec.dsn, remotesql) AS t(lsn pg_lsn) INTO target_lsn;
                
                IF target_lsn IS NULL OR target_lsn <= current_lsn THEN
                    RAISE NOTICE '    - Slot % already at or beyond target LSN (current: %, target: %)', slot_name, current_lsn, target_lsn;
                    CONTINUE;
                END IF;
                
                -- Advance the slot
                remotesql := format('SELECT pg_replication_slot_advance(%L, %L::pg_lsn)', slot_name, target_lsn);
                IF verb THEN
                    RAISE NOTICE '    Remote SQL for slot advancement: %', remotesql;
                END IF;
                
                PERFORM * FROM dblink(rec.dsn, remotesql) AS t(result text);
                RAISE NOTICE '    ✓ %', rpad('Advanced slot ' || slot_name || ' from ' || current_lsn || ' to ' || target_lsn, 120, ' ');
            END;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE '    ✗ %', rpad('Advancing slot ' || slot_name || ' to timestamp ' || commit_ts || ' (error: ' || SQLERRM || ')', 120, ' ');
                -- Continue with other nodes even if this one fails
        END;
    END LOOP;
END;
$$;

-- ============================================================================
-- Simple procedure to check lag between specific nodes (simplified)
-- ============================================================================

CREATE OR REPLACE PROCEDURE check_node_lag(
    origin_node text,
    receiver_node text,
    verb boolean DEFAULT true,
    INOUT lag_interval interval DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Check for the specific path
    SELECT now() - commit_timestamp INTO lag_interval
    FROM spock.lag_tracker
    WHERE origin_name = origin_node AND receiver_name = receiver_node;
    
    IF lag_interval IS NOT NULL THEN
        IF verb THEN
            RAISE NOTICE '% → % lag: %', origin_node, receiver_node, lag_interval;
        END IF;
    ELSE
        IF verb THEN
            RAISE NOTICE '% → % lag: NULL (no data)', origin_node, receiver_node;
        END IF;
    END IF;
END;
$$;

-- ============================================================================
-- Procedure to trigger sync event on source and wait on new node
-- ============================================================================
CREATE OR REPLACE PROCEDURE trigger_sync_and_wait(
    src_node_name text,
    src_dsn text,
    new_node_name text,
    new_node_dsn text,
    verb boolean
) LANGUAGE plpgsql AS $$
DECLARE
    sync_lsn pg_lsn;
    timeout_ms integer := 1200000;  -- 20 minutes timeout
    remotesql text;
BEGIN
    RAISE NOTICE 'Phase 7: Triggering sync event on source and waiting on new node';
    
    -- Trigger sync event on source node using dblink
    BEGIN
        -- First, let's check the current state of replication slots on the source node
        IF verb THEN
            remotesql := 'SELECT slot_name, plugin, slot_type, restart_lsn, confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name LIKE ''spk_%'' ORDER BY slot_name;';
            RAISE NOTICE '    Checking replication slots on source node:';
            PERFORM * FROM dblink(src_dsn, remotesql) AS t(slot_name text, plugin text, slot_type text, restart_lsn pg_lsn, confirmed_flush_lsn pg_lsn);
            
            -- Check replication workers on source node
            remotesql := 'SELECT pid, application_name, state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication ORDER BY application_name;';
            RAISE NOTICE '    Checking replication workers on source node:';
            PERFORM * FROM dblink(src_dsn, remotesql) AS t(pid integer, application_name text, state text, sent_lsn pg_lsn, write_lsn pg_lsn, flush_lsn pg_lsn, replay_lsn pg_lsn);
        END IF;
        
        remotesql := 'SELECT spock.sync_event();';
        IF verb THEN
            RAISE NOTICE '    Remote SQL for sync event: %', remotesql;
        END IF;
        
        SELECT * FROM dblink(src_dsn, remotesql) AS t(lsn pg_lsn) INTO sync_lsn;
        RAISE NOTICE '    ✓ %', rpad('Triggering sync event on source node ' || src_node_name || ' (LSN: ' || sync_lsn || ')...', 120, ' ');
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE '    ✗ %', rpad('Triggering sync event on source node ' || src_node_name || '...', 120, ' ');
            RAISE;
    END;
    
    -- Wait for sync event on new node using dblink
    BEGIN
        -- First, let's check the current state of subscriptions on the new node
        IF verb THEN
            remotesql := 'SELECT subname, subenabled, subconninfo FROM pg_subscription ORDER BY subname;';
            RAISE NOTICE '    Checking subscriptions on new node:';
            PERFORM * FROM dblink(new_node_dsn, remotesql) AS t(subname text, subenabled boolean, subconninfo text);
            
            -- Check replication workers on new node
            remotesql := 'SELECT pid, application_name, state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication ORDER BY application_name;';
            RAISE NOTICE '    Checking replication workers on new node:';
            PERFORM * FROM dblink(new_node_dsn, remotesql) AS t(pid integer, application_name text, state text, sent_lsn pg_lsn, write_lsn pg_lsn, flush_lsn pg_lsn, replay_lsn pg_lsn);
        END IF;
        
        remotesql := format('CALL spock.wait_for_sync_event(true, %L, %L::pg_lsn, %s);', 
                           src_node_name, sync_lsn, timeout_ms);
        IF verb THEN
            RAISE NOTICE '    Remote SQL for waiting sync event: %', remotesql;
        END IF;
        
        DECLARE
            wait_result text;
        BEGIN
            SELECT result INTO wait_result FROM dblink(new_node_dsn, remotesql) AS t(result text);
            RAISE NOTICE '    ✓ %', rpad('Waiting for sync event on new node ' || new_node_name || ' (result: ' || wait_result || ')', 120, ' ');
        END;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE '    ✗ %', rpad('Waiting for sync event on new node ' || new_node_name || '...', 120, ' ');
            RAISE;
    END;
END;
$$;

-- ============================================================================
-- Procedure to present final cluster state
-- ============================================================================
CREATE OR REPLACE PROCEDURE present_final_cluster_state(
    initial_node_count integer,
    verb boolean DEFAULT false
) LANGUAGE plpgsql AS $$
DECLARE
    rec RECORD;
    sub_status text;
    wait_count integer := 0;
    max_wait_count integer := 300; -- Wait up to 300 seconds
BEGIN
    -- Phase 11: Presenting final cluster state
    RAISE NOTICE 'Phase 11: Presenting final cluster state';
    
    -- Wait for replication to be active
    RAISE NOTICE '    Waiting for replication to be active...';
    LOOP
        wait_count := wait_count + 1;
        
        -- Check subscription status
        IF verb THEN
            RAISE NOTICE '[QUERY] SELECT status FROM spock.sub_show_status() LIMIT 1';
        END IF;
        SELECT status INTO sub_status FROM spock.sub_show_status() LIMIT 1;
        
        IF sub_status = 'replicating' THEN
            RAISE NOTICE '    ✓ Replication is active (status: %)', sub_status;
            EXIT;
        ELSIF wait_count >= max_wait_count THEN
            RAISE NOTICE '    ⚠ Timeout waiting for replication to be active (current status: %)', sub_status;
            EXIT;
        ELSE
            RAISE NOTICE '    Waiting for replication... (status: %, attempt %/%)', sub_status, wait_count, max_wait_count;
            PERFORM pg_sleep(1);
        END IF;
    END LOOP;
    
    -- Print nodes in psql-style table format
    RAISE NOTICE '';
    RAISE NOTICE 'Current Spock Nodes:';
    RAISE NOTICE ' node_id | node_name | location | country | info';
    RAISE NOTICE '---------+-----------+----------+---------+------';
    
    IF verb THEN
        RAISE NOTICE '[QUERY] SELECT node_id, node_name, location, country, info FROM spock.node ORDER BY node_id';
    END IF;
    FOR rec IN SELECT node_id, node_name, location, country, info FROM spock.node ORDER BY node_id LOOP
        RAISE NOTICE ' % | % | % | % | %', 
            rpad(rec.node_id::text, 7, ' '), 
            rpad(rec.node_name, 9, ' '), 
            rpad(COALESCE(rec.location, ''), 9, ' '), 
            rpad(COALESCE(rec.country, ''), 7, ' '), 
            COALESCE(rec.info::text, '');
    END LOOP;
    RAISE NOTICE '';
    
    -- Show subscription status
    RAISE NOTICE 'Subscription Status:';
    IF verb THEN
        RAISE NOTICE '[QUERY] SELECT * FROM spock.sub_show_status()';
    END IF;
    FOR rec IN SELECT * FROM spock.sub_show_status() LOOP
        RAISE NOTICE '  %: % (provider: %)', rec.subscription_name, rec.status, rec.provider_node;
    END LOOP;
    RAISE NOTICE '';
END;
$$;

-- ============================================================================
-- Procedure to monitor replication lag
-- ============================================================================
CREATE OR REPLACE PROCEDURE monitor_replication_lag(
    src_node_name text,
    new_node_name text,
    new_node_dsn text,
    verb boolean
) LANGUAGE plpgsql AS $$
BEGIN
    -- Phase 12: Monitor replication lag
    RAISE NOTICE 'Phase 12: Monitoring replication lag';
    CALL monitor_lag_with_dblink(src_node_name, new_node_name, new_node_dsn, verb);
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
    verb boolean,
    new_node_location text DEFAULT 'NY',
    new_node_country text DEFAULT 'USA',
    new_node_info jsonb DEFAULT '{}'::jsonb
)
LANGUAGE plpgsql
AS
$$
DECLARE
    initial_node_count integer;
BEGIN

    -- Phase 1: Verify prerequisites (source and new node validation)
    CALL verify_node_prerequisites(src_node_name, src_dsn, new_node_name, new_node_dsn, verb);

    -- Phase 2: Create nodes
    CALL create_nodes_only(src_node_name, src_dsn, new_node_name, new_node_dsn, verb, new_node_location, new_node_country, new_node_info, initial_node_count);

    -- Phase 4: Create disabled subscriptions and slots
    CALL create_disable_subscriptions_and_slots(src_node_name, src_dsn, new_node_name, new_node_dsn, verb);

    -- Phase 5: Create source to new node subscription
    CALL create_source_to_new_subscription(src_node_name, src_dsn, new_node_name, new_node_dsn, verb);

    -- Phase 6: Trigger sync events on other nodes and wait on source
    CALL trigger_sync_on_other_nodes_and_wait_on_source(src_node_name, src_dsn, new_node_name, new_node_dsn, verb);

    -- Phase 8: Check commit timestamp and advance replication slot
    CALL check_commit_timestamp_and_advance_slot(src_node_name, src_dsn, new_node_name, new_node_dsn, verb);

    -- Phase 9: Enable disabled subscriptions
    CALL enable_disabled_subscriptions(src_node_name, src_dsn, new_node_name, new_node_dsn, verb);

    -- Phase 10: Create subscription from new node to source node
    CALL create_sub_on_new_node_to_src_node(src_node_name, src_dsn, new_node_name, new_node_dsn, verb);

    -- Phase 11: Present final cluster state
    CALL present_final_cluster_state(initial_node_count, verb);

    

    -- Phase 12: Monitor replication lag
    CALL monitor_replication_lag(src_node_name, new_node_name, new_node_dsn, verb);
END;
$$;

