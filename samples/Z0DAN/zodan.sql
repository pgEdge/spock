-- ============================================================================
-- ZODAN (Zero Downtime Add Node) - Spock Extension
-- Version: 1.0.0
-- Required Spock Version: 5.0.4 or later
-- ============================================================================
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
-- Procedure: check_spock_version_compatibility
-- Purpose: Verify all nodes have the same Spock version before adding a node
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.check_spock_version_compatibility(
    src_dsn text,
    new_node_dsn text,
    verb boolean DEFAULT false
) LANGUAGE plpgsql AS $$
DECLARE
    min_required_version text := '5.0.4';
    src_version text;
    new_version text;
    node_rec RECORD;
    remotesql text;
    node_version text;
    version_mismatch boolean := false;
BEGIN
    -- Get source node Spock version
    remotesql := 'SELECT extversion FROM pg_extension WHERE extname = ''spock''';
    IF verb THEN
        RAISE NOTICE 'Checking Spock version on source node';
    END IF;
    SELECT * FROM dblink(src_dsn, remotesql) AS t(version text) INTO src_version;

    IF src_version IS NULL THEN
        RAISE EXCEPTION 'Spock extension not found on source node';
    END IF;

    -- Check source node has required version (strip -devel suffix for comparison)
    IF regexp_replace(src_version, '-devel$', '') < min_required_version THEN
        RAISE EXCEPTION 'Spock version mismatch: source node has version %, but minimum required version is %. Please upgrade all nodes to at least %.',
            src_version, min_required_version, min_required_version;
    END IF;

    -- Get new node Spock version
    IF verb THEN
        RAISE NOTICE 'Checking Spock version on new node';
    END IF;
    SELECT * FROM dblink(new_node_dsn, remotesql) AS t(version text) INTO new_version;

    IF new_version IS NULL THEN
        RAISE EXCEPTION 'Spock extension not found on new node';
    END IF;

    -- Check new node has required version (strip -devel suffix for comparison)
    IF regexp_replace(new_version, '-devel$', '') < min_required_version THEN
        RAISE EXCEPTION 'Spock version mismatch: new node has version %, but minimum required version is %. Please upgrade all nodes to at least %.',
            new_version, min_required_version, min_required_version;
    END IF;

    IF regexp_replace(new_version, '-devel$', '') != regexp_replace(src_version, '-devel$', '') THEN
        RAISE EXCEPTION 'Spock version mismatch: new node has version %, but source version is %. Please ensure that they match.',
            new_version, src_version;
    END IF;

    -- Check all existing nodes in cluster
    FOR node_rec IN
        SELECT node_name, if_dsn
        FROM dblink(src_dsn,
            'SELECT n.node_name, i.if_dsn FROM spock.node n JOIN spock.node_interface i ON n.node_id = i.if_nodeid'
        ) AS t(node_name text, if_dsn text)
    LOOP
        SELECT * FROM dblink(node_rec.if_dsn, remotesql) AS t(version text) INTO node_version;

        IF node_version IS NULL THEN
            RAISE EXCEPTION 'Spock extension not found on node %', node_rec.node_name;
        END IF;

        IF regexp_replace(node_version, '-devel$', '') < min_required_version THEN
            version_mismatch := true;
            RAISE EXCEPTION 'Spock version mismatch: node % has version %, but required version is at least %. All nodes must have version % or later.',
                node_rec.node_name, node_version, min_required_version, min_required_version;
        END IF;

        IF regexp_replace(node_version, '-devel$', '') != regexp_replace(new_version, '-devel$', '') THEN
            RAISE EXCEPTION 'Spock version mismatch: new node has version %, but found node version %. Please ensure that they match.',
                new_version, node_version;
        END IF;
    END LOOP;

    IF verb THEN
        RAISE NOTICE 'Version check passed: All nodes running Spock version % or later. Source version is %, new node version is %', min_required_version, src_version, new_version;
    END IF;
END;
$$;

-- ============================================================================
-- Procedure: get_spock_nodes
-- Purpose : Retrieves all Spock nodes and their DSNs from a remote cluster.
-- Arguments:
--   remote_dsn - DSN string to connect to the remote cluster.
--   verb - Verbose output flag
-- Usage    : CALL get_spock_nodes('host=... dbname=... user=... password=...', true);
-- ============================================================================

DROP PROCEDURE IF EXISTS spock.get_spock_nodes(text, boolean);
CREATE OR REPLACE PROCEDURE spock.get_spock_nodes(src_dsn text, verb boolean)
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
--   force_text_transfer   - Whether to force text transfer (boolean).
--   verb                  - Verbose output flag
-- Usage    : CALL create_sub(...);
-- ============================================================================

CREATE OR REPLACE PROCEDURE spock.create_sub(
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
    skip_schema_list text;
    existing_schemas text;
    remotesql_schema text;
BEGIN
    -- Auto-detect existing schemas on new node when synchronize_structure is true
    skip_schema_list := 'ARRAY[]::text[]';

    IF synchronize_structure THEN
        BEGIN
            -- Query existing schemas on the new node (excluding system schemas)
            remotesql_schema := 'SELECT string_agg(schema_name, '','') as schemas
                                FROM information_schema.schemata
                                WHERE schema_name NOT IN (''information_schema'', ''pg_catalog'', ''pg_toast'', ''spock'', ''public'')
                                AND schema_name NOT LIKE ''pg_temp_%''
                                AND schema_name NOT LIKE ''pg_toast_temp_%''';

            IF verb THEN
                RAISE NOTICE '[QUERY] Detecting existing schemas on new node: %', remotesql_schema;
            END IF;

            SELECT schemas INTO existing_schemas FROM dblink(node_dsn, remotesql_schema) AS t(schemas text);

            IF existing_schemas IS NOT NULL AND existing_schemas != '' THEN
                skip_schema_list := 'ARRAY[''' || replace(existing_schemas, ',', ''',''') || ''']::text[]';
                IF verb THEN
                    RAISE NOTICE '[INFO] Found existing schemas to skip: %', existing_schemas;
                END IF;
            ELSE
                IF verb THEN
                    RAISE NOTICE '[INFO] No existing user schemas found on new node';
                END IF;
            END IF;

        EXCEPTION
            WHEN OTHERS THEN
                IF verb THEN
                    RAISE NOTICE '[WARNING] Failed to detect existing schemas: %', SQLERRM;
                END IF;
                skip_schema_list := 'ARRAY[]::text[]';
        END;
    END IF;

    remotesql := format(
        'SELECT spock.sub_create(
            subscription_name := %L,
            provider_dsn := %L,
            replication_sets := %s,
            synchronize_structure := %L,
            synchronize_data := %L,
            forward_origins := %s,
            apply_delay := %L,
            enabled := %L,
            force_text_transfer := %L,
            skip_schema := %s
        )',
        subscription_name,
        provider_dsn,
        replication_sets,
        synchronize_structure::text,
        synchronize_data::text,
        forward_origins,
        apply_delay::text,
        enabled::text,
        force_text_transfer::text,
        skip_schema_list
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

CREATE OR REPLACE PROCEDURE spock.create_replication_slot(
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

CREATE OR REPLACE PROCEDURE spock.sync_event(
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

CREATE OR REPLACE PROCEDURE spock.create_node(
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
-- Procedure: enable_sub
-- Purpose : Enables a Spock subscription on a remote node via dblink.
-- Arguments:
--   node_dsn   - DSN string to connect to the remote node.
--   sub_name   - Name of the subscription to enable.
--   verb       - Verbose output flag
--   immediate  - Whether to enable immediately (default: true).
-- Usage    : CALL enable_sub(node_dsn, sub_name, true, true);
-- ============================================================================

CREATE OR REPLACE PROCEDURE spock.enable_sub(
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
-- Procedure: verify_subscription_replicating
-- Purpose : Verifies that a subscription is actively replicating after being enabled
-- Arguments:
--   node_dsn           - DSN of the node where subscription exists
--   subscription_name  - Name of the subscription to verify
--   verb              - Verbose output flag
--   max_attempts      - Maximum verification attempts in seconds (default: 120 = 2 minutes)
-- Usage    : CALL spock.verify_subscription_replicating(node_dsn, 'sub_name', true);
-- Notes   : Raises exception if subscription fails to reach 'replicating' status within timeout
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.verify_subscription_replicating(
    node_dsn text,
    subscription_name text,
    verb boolean DEFAULT true,
    max_attempts integer DEFAULT 120  -- 2 minutes (120 seconds)
) LANGUAGE plpgsql AS $$
DECLARE
    sub_status text;
    verify_count integer := 0;
BEGIN
    LOOP
        verify_count := verify_count + 1;

        -- Check subscription status on the target node
        SELECT status INTO sub_status
        FROM dblink(node_dsn,
            format('SELECT status FROM spock.sub_show_status() WHERE subscription_name = %L',
                   subscription_name)) AS t(status text);

        IF sub_status = 'replicating' THEN
            IF verb THEN
                RAISE NOTICE '    SUCCESS: %', rpad('Verified subscription ' || subscription_name || ' is replicating', 120, ' ');
            END IF;
            EXIT;
        ELSIF verify_count >= max_attempts THEN
            RAISE EXCEPTION 'Subscription % verification timeout after % seconds (final status: %)',
                          subscription_name, max_attempts, COALESCE(sub_status, 'unknown');
        ELSE
            IF verb THEN
                RAISE NOTICE '    ⏳ %', rpad('Waiting for subscription ' || subscription_name || ' to start replicating (status: ' || COALESCE(sub_status, 'unknown') || ', attempt ' || verify_count || '/' || max_attempts || ')', 120, ' ');
            END IF;
            PERFORM pg_sleep(1);
        END IF;
    END LOOP;
END;
$$;

-- ============================================================================
-- Procedure: show_all_nodes
-- Purpose : Shows comprehensive node status across all nodes in cluster
-- Arguments:
--   cluster_dsn - DSN of any node in the cluster to query cluster state
--   verb        - Verbose output flag
-- Usage    : CALL spock.show_all_nodes('host=127.0.0.1 dbname=pgedge port=5431 user=pgedge password=pgedge', true);
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.show_all_nodes(
    cluster_dsn text,
    verb boolean DEFAULT true
) LANGUAGE plpgsql AS $$
DECLARE
    node_rec RECORD;
    total_nodes integer := 0;
BEGIN
    IF verb THEN
        RAISE NOTICE '';
        RAISE NOTICE 'COMPREHENSIVE NODE STATUS REPORT';
        RAISE NOTICE '====================================';
    END IF;

    -- Get all nodes from the cluster using the provided DSN
    FOR node_rec IN
        SELECT node_id, node_name, location, country, info, dsn
        FROM dblink(cluster_dsn, 'SELECT n.node_id, n.node_name, n.location, n.country, n.info, i.if_dsn FROM spock.node n JOIN spock.node_interface i ON n.node_id = i.if_nodeid ORDER BY n.node_name')
        AS t(node_id integer, node_name text, location text, country text, info text, dsn text)
    LOOP
        total_nodes := total_nodes + 1;

        IF verb THEN
            RAISE NOTICE '    [NODE] %: % (%s, %s) - %s', node_rec.node_name, node_rec.node_id, node_rec.location, node_rec.country, regexp_replace(node_rec.dsn, ' password=pgedge', ' password=***');
        END IF;
    END LOOP;

    -- Summary
    IF verb THEN
        RAISE NOTICE '';
        RAISE NOTICE 'NODE STATUS SUMMARY';
        RAISE NOTICE '==================';
        RAISE NOTICE 'Total nodes: %', total_nodes;
    END IF;

    -- Raise exception if no nodes are found
    IF total_nodes = 0 THEN
        RAISE EXCEPTION 'No nodes found in the cluster';
    END IF;
END;
$$;

-- ============================================================================
-- Procedure: show_all_subscription_status
-- Purpose : Shows comprehensive subscription status across all nodes in the cluster
-- Arguments:
--   cluster_dsn - DSN of any node in the cluster to query cluster state
--   verb        - Verbose output flag
-- Usage    : CALL spock.show_all_subscription_status('host=127.0.0.1 dbname=pgedge port=5431 user=pgedge password=pgedge', true);
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.show_all_subscription_status(
    cluster_dsn text,
    verb boolean DEFAULT true
) LANGUAGE plpgsql AS $$
DECLARE
    node_rec RECORD;
    sub_rec RECORD;
    total_subscriptions integer := 0;
    replicating_count integer := 0;
    error_count integer := 0;
BEGIN
    IF verb THEN
        RAISE NOTICE '';
        RAISE NOTICE 'COMPREHENSIVE SUBSCRIPTION STATUS REPORT';
        RAISE NOTICE '==========================================';
    END IF;

    -- Get all nodes from the cluster using the provided DSN
    FOR node_rec IN
        SELECT node_id, node_name, location, country, info, dsn
        FROM dblink(cluster_dsn, 'SELECT n.node_id, n.node_name, n.location, n.country, n.info, i.if_dsn FROM spock.node n JOIN spock.node_interface i ON n.node_id = i.if_nodeid ORDER BY n.node_name')
        AS t(node_id integer, node_name text, location text, country text, info text, dsn text)
    LOOP
        IF verb THEN
            RAISE NOTICE '';
            RAISE NOTICE 'Node: % (DSN: %)', node_rec.node_name, node_rec.dsn;
            RAISE NOTICE 'Subscriptions:';
        END IF;

        -- Get all subscriptions from this node
        FOR sub_rec IN
            SELECT subscription_name, status, provider_node, provider_dsn, slot_name, replication_sets, forward_origins
            FROM dblink(node_rec.dsn, 'SELECT * FROM spock.sub_show_status() ORDER BY subscription_name')
            AS t(subscription_name text, status text, provider_node text, provider_dsn text,
                 slot_name text, replication_sets text[], forward_origins text)
        LOOP
            total_subscriptions := total_subscriptions + 1;

            CASE sub_rec.status
                WHEN 'replicating' THEN
                    replicating_count := replicating_count + 1;
                    IF verb THEN
                        RAISE NOTICE '  [OK] %: % (provider: %, sets: %)',
                            sub_rec.subscription_name, sub_rec.status,
                            sub_rec.provider_node,
                            array_to_string(sub_rec.replication_sets, ',');
                    END IF;
                WHEN 'disabled' THEN
                    IF verb THEN
                        RAISE NOTICE '  [DISABLED] %: % (provider: %, sets: %)',
                            sub_rec.subscription_name, sub_rec.status,
                            sub_rec.provider_node,
                            array_to_string(sub_rec.replication_sets, ',');
                    END IF;
                WHEN 'initializing' THEN
                    IF verb THEN
                        RAISE NOTICE '  [INITIALIZING] %: % (provider: %, sets: %)',
                            sub_rec.subscription_name, sub_rec.status,
                            sub_rec.provider_node,
                            array_to_string(sub_rec.replication_sets, ',');
                    END IF;
                WHEN 'syncing' THEN
                    IF verb THEN
                        RAISE NOTICE '  [SYNCING] %: % (provider: %, sets: %)',
                            sub_rec.subscription_name, sub_rec.status,
                            sub_rec.provider_node,
                            array_to_string(sub_rec.replication_sets, ',');
                    END IF;
                WHEN 'down' THEN
                    error_count := error_count + 1;
                    IF verb THEN
                        RAISE NOTICE '  [ERROR] %: % (provider: %, sets: %)',
                            sub_rec.subscription_name, sub_rec.status,
                            sub_rec.provider_node,
                            array_to_string(sub_rec.replication_sets, ',');
                    END IF;
                ELSE
                    IF verb THEN
                        RAISE NOTICE '  [UNKNOWN] %: % (provider: %, sets: %)',
                            sub_rec.subscription_name, sub_rec.status,
                            sub_rec.provider_node,
                            array_to_string(sub_rec.replication_sets, ',');
                    END IF;
            END CASE;
        END LOOP;

        -- Check if node has no subscriptions
        IF NOT FOUND THEN
            IF verb THEN
                RAISE NOTICE '  (no subscriptions found)';
            END IF;
        END IF;
    END LOOP;

    -- Summary
    IF verb THEN
        RAISE NOTICE '';
        RAISE NOTICE 'SUBSCRIPTION STATUS SUMMARY';
        RAISE NOTICE '==========================';
        RAISE NOTICE 'Total subscriptions: %', total_subscriptions;
        RAISE NOTICE 'Replicating: %', replicating_count;
        RAISE NOTICE 'With errors/issues: %', error_count;

        IF total_subscriptions > 0 THEN
            RAISE NOTICE 'Success rate: %%%',
                round((replicating_count::numeric / total_subscriptions::numeric) * 100, 1);
        END IF;

        IF replicating_count = total_subscriptions AND total_subscriptions > 0 THEN
            RAISE NOTICE 'SUCCESS: All subscriptions are replicating successfully!';
        ELSIF error_count > 0 THEN
            RAISE NOTICE 'WARNING: Some subscriptions have issues - check details above';
        ELSE
            RAISE NOTICE 'INFO: Subscriptions are in various states - check details above';
        END IF;
    END IF;

    -- Raise exception if no subscriptions are replicating
    IF total_subscriptions > 0 AND replicating_count = 0 THEN
        RAISE EXCEPTION 'No subscriptions are in replicating state after node addition';
    END IF;
END;
$$;

-- ============================================================================
-- Procedure to monitor lag using dblink
-- ============================================================================

CREATE OR REPLACE PROCEDURE spock.monitor_lag_with_dblink(
    src_node_name text,
    new_node_name text,
    new_node_dsn text,
    verb boolean DEFAULT true
)
LANGUAGE plpgsql
AS $$
DECLARE
    lag_interval interval;
    lag_bytes bigint;
    max_wait_seconds integer := 60;
    start_time timestamp := clock_timestamp();
    elapsed_interval interval;
    loop_count integer := 0;
    lag_sql text;
    lag_result record;
BEGIN
    RAISE NOTICE '    Monitoring lag from % to % using dblink...', src_node_name, new_node_name;
    LOOP
        loop_count := loop_count + 1;
        lag_sql := format(
            'SELECT now() - commit_timestamp AS lag_interval, replication_lag_bytes AS lag_bytes FROM spock.lag_tracker WHERE origin_name = %L AND receiver_name = %L',
            src_node_name, new_node_name
        );
        -- Use dblink to get lag from remote node
        EXECUTE format(
            'SELECT * FROM dblink(%L, %L) AS t(lag_interval interval, lag_bytes bigint)',
            new_node_dsn, lag_sql
        ) INTO lag_result;

        lag_interval := lag_result.lag_interval;
        lag_bytes := lag_result.lag_bytes;
        elapsed_interval := clock_timestamp() - start_time;

        RAISE NOTICE '% → % lag: % (bytes: %, elapsed: %, loop: %)',
            src_node_name, new_node_name,
            COALESCE(lag_interval::text, 'NULL'),
            COALESCE(lag_bytes::text, 'NULL'),
            elapsed_interval::text, loop_count;

        EXIT WHEN lag_interval IS NOT NULL AND (extract(epoch FROM lag_interval) < 59 OR lag_bytes = 0);
        IF extract(epoch FROM elapsed_interval) > max_wait_seconds THEN
            RAISE NOTICE 'Timeout reached (% seconds) - exiting lag monitoring', max_wait_seconds;
            EXIT;
        END IF;
        PERFORM pg_sleep(1);
    END LOOP;

    IF lag_interval IS NOT NULL AND (extract(epoch FROM lag_interval) < 59 OR lag_bytes = 0) THEN
        IF lag_bytes = 0 THEN
            RAISE NOTICE '    OK: Replication lag monitoring completed (lag_bytes = 0)';
        ELSE
            RAISE NOTICE '    OK: Replication lag monitoring completed';
        END IF;
    ELSE
        RAISE NOTICE '    - Replication lag monitoring timed out';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '%', '    ✗ Replication lag monitoring failed' || ' (error: ' || SQLERRM || ')';
        RAISE;
END;
$$;

-- ============================================================================

--
-- Utility routine to correctly extract database name from the DSN string.
--
-- The purpose here is to centralise this specific logic: people may complain
-- about more flexibility in writing the DSN: using upper-case letters in
-- keywords, as an example.
--
CREATE OR REPLACE FUNCTION spock.extract_dbname_from_dsn(dsn text)
RETURNS text AS $$
DECLARE
	dbname text;
BEGIN
	dbname := substring(dsn from 'dbname=([^\s]+)');
    IF dbname IS NOT NULL THEN
        dbname := TRIM(BOTH '''' FROM dbname);
    END IF;
    IF dbname IS NULL THEN
		-- We can't rely on the PGDATABASE environment variable here.
		-- Also, it seems unreliable to guess or use a default name.
		-- So, complain.
        RAISE EXCEPTION 'Exiting add_node: Database name must be explicitly included into the DSN string %', dsn;
    END IF;

	RETURN dbname;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================================
-- Procedure to verify prerequisites for adding a new node
-- (Combines Phase 1: Validating source node prerequisites and Phase 2: Validating new node prerequisites)
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.verify_node_prerequisites(
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
    new_db_name text;
    new_db_exists boolean;
BEGIN
    RAISE NOTICE 'Phase 1: Validating source and new node prerequisites';

    -- Check if database specified in new_node_dsn exists on new node

    SELECT spock.extract_dbname_from_dsn(new_node_dsn) INTO new_db_name;
    BEGIN
        SELECT EXISTS(SELECT 1 FROM dblink(new_node_dsn, 'SELECT 1') AS t(dummy int)) INTO new_db_exists;
        RAISE NOTICE '    OK: %', rpad('Checking database ' || new_db_name || ' exists on new node', 120, ' ');
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE '    [FAILED] %', rpad('Database ' || new_db_name || ' does not exist on new node', 60, ' ');
            RAISE EXCEPTION 'Exiting add_node: Database % does not exist on new node. Please create it first.', new_db_name;
    END;

    -- Check if they previously installed lolor on the destination.
    -- They should not have run CREATE EXTENSION yet
    DECLARE
        user_table_count integer;
        remotesql text;
    BEGIN
        remotesql := 'SELECT count(*) FROM pg_tables WHERE schemaname = ''lolor''';
        SELECT * FROM dblink(new_node_dsn, remotesql) AS t(count integer) INTO user_table_count;

        IF user_table_count > 0 THEN
            RAISE NOTICE '    [FAILED] %', rpad('Database ' || new_db_name || ' has the lolor extension installed or remaining lolor data.', 120, ' ');
            RAISE EXCEPTION 'Exiting add_node: Database % has the lolor extension installed or remaining lolor user data.', new_db_name;
        ELSE
            RAISE NOTICE '    OK: %', rpad('Checking database ' || new_db_name || ' to ensure lolor is not installed', 120, ' ');
        END IF;
    END;

    -- Check if database has user-created tables in user-created schemas
    DECLARE
        user_table_count integer;
        remotesql text;
    BEGIN
        remotesql := 'SELECT count(*) FROM pg_tables WHERE schemaname NOT IN (''information_schema'', ''pg_catalog'', ''pg_toast'', ''spock'') AND schemaname NOT LIKE ''pg_temp_%'' AND schemaname NOT LIKE ''pg_toast_temp_%''';
        SELECT * FROM dblink(new_node_dsn, remotesql) AS t(count integer) INTO user_table_count;

        IF user_table_count > 0 THEN
            RAISE NOTICE '    [FAILED] %', rpad('Database ' || new_db_name || ' has ' || user_table_count || ' user-created tables', 60, ' ');
            RAISE EXCEPTION 'Exiting add_node: Database % on new node has user-created tables. It must be a freshly created database with no user tables (only system and extension tables allowed).', new_db_name;
        ELSE
            RAISE NOTICE '    OK: %', rpad('Checking database ' || new_db_name || ' has no user-created tables', 120, ' ');
        END IF;
    END;

    -- Check that new node has all users that source node has
    DECLARE
        missing_users text := '';
        user_rec RECORD;
        user_exists boolean;
        src_users_sql text;
        check_user_sql text;
    BEGIN
        src_users_sql := 'SELECT rolname FROM pg_roles WHERE rolcanlogin = true AND rolname NOT IN (''postgres'', ''rdsadmin'', ''rdsrepladmin'', ''rds_superuser'') ORDER BY rolname';

        FOR user_rec IN
            SELECT * FROM dblink(src_dsn, src_users_sql) AS t(rolname text)
        LOOP
            -- Build the SQL with the rolname embedded (properly escaped)
            check_user_sql := format('SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname = %L AND rolcanlogin = true)', user_rec.rolname);
            SELECT * FROM dblink(new_node_dsn, check_user_sql) AS t(exists boolean) INTO user_exists;

            IF NOT user_exists THEN
                IF missing_users = '' THEN
                    missing_users := user_rec.rolname;
                ELSE
                    missing_users := missing_users || ', ' || user_rec.rolname;
                END IF;
            END IF;
        END LOOP;

        IF missing_users != '' THEN
            RAISE NOTICE '    [FAILED] %', rpad('New node missing users: ' || missing_users, 60, ' ');
            RAISE EXCEPTION 'Exiting add_node: New node is missing the following users that exist on source node: %. Please create these users on the new node before adding it to the cluster.', missing_users;
        ELSE
            RAISE NOTICE '    OK: %', rpad('Checking new node has all source node users', 120, ' ');
        END IF;
    END;

    -- Check: all nodes, included in the cluster, have only enabled subscriptions.
	--
	-- Connect to each node in the cluster and pass through the spock.subscription
	-- table to check subscriptions statuses. Using it we try to avoid cases
	-- when somewhere in the middle a crash or disconnection happens that may
	-- be aggravated by add_node.
    DECLARE
		status_rec     record;
		dsn_rec        record;
		dsns_sql       text;
		sub_status_sql text;
    BEGIN
        dsns_sql := 'SELECT if_dsn,node_name
					 FROM spock.node JOIN spock.node_interface
					 ON (if_nodeid = node_id)
					 WHERE node_id NOT IN (SELECT node_id FROM spock.local_node)';
		sub_status_sql := 'SELECT sub_name, sub_enabled FROM spock.subscription';

        FOR dsn_rec IN SELECT * FROM dblink(src_dsn, dsns_sql)
													AS t(dsn text, node name)
		LOOP
			FOR status_rec IN SELECT * FROM dblink(dsn_rec.dsn, sub_status_sql)
													AS t(name text, status text)
			LOOP
			    IF status_rec.status != 't' THEN
                    RAISE EXCEPTION '    [FAILED] %', rpad('Node ' || dsn_rec.node || ' has disabled subscription ' || status_rec.name, 60, ' ');
                ELSIF verb THEN
                    RAISE NOTICE '    OK: %', rpad('Node with DSN ' || dsn_rec.dsn || ' has enabled subscription ' || status_rec.name, 120, ' ');
                END IF;
			END LOOP;
        END LOOP;
		RAISE NOTICE '    OK: %', rpad('Checking each Spock node has only active subscriptions', 120, ' ');
    END;

    -- Validating new node prerequisites
    SELECT count(*) INTO new_exists FROM spock.node WHERE node_name = new_node_name;
    IF new_exists > 0 THEN
        RAISE NOTICE '    %[FAILED]', rpad('Checking new node "' || new_node_name || '" already exists', 60, ' ');
        RAISE EXCEPTION 'Exiting add_node: New node % already exists', new_node_name;
    ELSE
        RAISE NOTICE '    OK: %', rpad('Checking new node ' || new_node_name || ' does not exist', 120, ' ');
    END IF;
    SELECT count(*) INTO new_sub_exists FROM spock.subscription s JOIN spock.node n ON s.sub_origin = n.node_id WHERE n.node_name = new_node_name;
    IF new_sub_exists > 0 THEN
        RAISE NOTICE '    %[FAILED]', rpad('Checking new node "' || new_node_name || '" has subscriptions', 60, ' ');
        RAISE EXCEPTION 'Exiting add_node: New node % has subscriptions', new_node_name;
    ELSE
        RAISE NOTICE '    OK: %', rpad('Checking new node ' || new_node_name || ' has no subscriptions', 120, ' ');
    END IF;
    SELECT count(*) INTO new_repset_exists FROM spock.replication_set rs JOIN spock.node n ON rs.set_nodeid = n.node_id WHERE n.node_name = new_node_name;
    IF new_repset_exists > 0 THEN
        RAISE NOTICE '    %[FAILED]', rpad('Checking new node "' || new_node_name || '" has replication sets', 60, ' ');
        RAISE EXCEPTION 'Exiting add_node: New node % has replication sets', new_node_name;
    ELSE
        RAISE NOTICE '    OK: %', rpad('Checking new node ' || new_node_name || ' has no replication sets', 120, ' ');
    END IF;
END;
$$;

-- ============================================================================
-- Procedure to create nodes only
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.create_nodes_only(
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
        CALL spock.create_node(src_node_name, src_dsn, verb);
        RAISE NOTICE '    OK: %', rpad('Creating source node ' || src_node_name || '...', 120, ' ');
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE '    ✗ %', rpad('Creating source node ' || src_node_name  || ' (error: ' || SQLERRM || ')', 120, ' ');
            RAISE;
    END;

    BEGIN
        CALL spock.create_node(new_node_name, new_node_dsn, verb, new_node_location, new_node_country, new_node_info);
        RAISE NOTICE '    OK: %', rpad('Creating new node ' || new_node_name || '...', 120, ' ');
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION '    ✗ %', rpad('Creating new node ' || new_node_name || ' (error: ' || SQLERRM || ')', 120, ' ');
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
CREATE OR REPLACE PROCEDURE spock.create_replication_slots(
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

		    -- Extract dbname and handle both quoted and unquoted values
			SELECT spock.extract_dbname_from_dsn(rec.dsn) INTO dbname;

		    -- Remove single quotes if present
            IF dbname IS NOT NULL THEN
                dbname := TRIM(BOTH '''' FROM dbname);
            END IF;

		    -- Remove single quotes if present
            IF dbname IS NOT NULL THEN
                dbname := TRIM(BOTH '''' FROM dbname);
            END IF;
            IF dbname IS NULL THEN
                dbname := 'pgedge';
            END IF;

            slot_name := spock.spock_gen_slot_name(
							dbname, rec.node_name,
							'sub_' || rec.node_name || '_' || new_node_name);

            CALL spock.create_replication_slot(
                rec.dsn,
                slot_name,
                verb,
                'spock_output'
            );
            RAISE NOTICE '    OK: %', rpad('Creating replication slot ' || slot_name || '...', 120, ' ');
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE '%', '    ✗ Creating replication slots...' || ' (error: ' || SQLERRM || ')';
            RAISE;
    END;
END;
$$;


-- ============================================================================
-- Procedure to create disabled subscriptions and slots
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.create_disable_subscriptions_and_slots(
    src_node_name text,  -- Source node name
    src_dsn text,        -- Source node DSN
    new_node_name text,  -- New node name
    new_node_dsn text,   -- New node DSN
    verb boolean         -- Verbose flag
) LANGUAGE plpgsql AS $$
DECLARE
    rec                RECORD;
    subscription_count integer := 0;
    remotesql          text;
    dbname             text;
    slot_name          text;
	sub_name           text;
    _commit_lsn        pg_lsn;
BEGIN
    RAISE NOTICE 'Phase 3: Creating disabled subscriptions and slots';

    -- Get all existing nodes (excluding source and new)
    CALL spock.get_spock_nodes(src_dsn, verb);

    -- Create temporary table to store sync LSNs
    CREATE TEMP TABLE IF NOT EXISTS temp_sync_lsns (
        origin_node text PRIMARY KEY,
        sync_lsn text NOT NULL,
        commit_lsn pg_lsn
    );

    -- Check if there are any "other" nodes (not source, not new)
    IF (SELECT count(*) FROM temp_spock_nodes WHERE node_name != src_node_name AND node_name != new_node_name) = 0 THEN
        -- 2-node scenario: trigger sync event on source node and store it
        BEGIN
            RAISE NOTICE '    - 2-node scenario';
            SELECT * INTO remotesql
            FROM dblink(src_dsn, 'SELECT spock.sync_event()') AS t(sync_lsn text);

            -- Store the sync LSN for later use when enabling subscriptions
            INSERT INTO temp_sync_lsns (origin_node, sync_lsn)
            VALUES (src_node_name, remotesql)
            ON CONFLICT (origin_node) DO UPDATE SET sync_lsn = EXCLUDED.sync_lsn;

            RAISE NOTICE '    OK: %', rpad('Triggering sync event on node ' || src_node_name || ' (LSN: ' || remotesql || ')', 120, ' ');
        EXCEPTION
            WHEN OTHERS THEN
                RAISE EXCEPTION '    ✗ %', rpad('Triggering sync event on node ' || src_node_name || ' (error: ' || SQLERRM || ')', 120, ' ');
        END;

        RAISE NOTICE '    - 2-node scenario: sync event stored, skipping disabled subscriptions';
        RETURN;
    END IF;

    -- For each "other" node (not source, not new), create disabled subscription and slot
    FOR rec IN SELECT * FROM temp_spock_nodes
	           WHERE node_name != src_node_name AND node_name != new_node_name
	LOOP
        -- Trigger sync event on origin node and store LSN
        BEGIN
            RAISE NOTICE '    - 3+ node scenario: sync event stored, skipping disabled subscriptions';
            SELECT * INTO remotesql
            FROM dblink(rec.dsn, 'SELECT spock.sync_event()') AS t(sync_lsn text);

            -- Store the sync LSN for later use when enabling subscriptions
            INSERT INTO temp_sync_lsns (origin_node, sync_lsn)
            VALUES (rec.node_name, remotesql)
            ON CONFLICT (origin_node) DO UPDATE SET sync_lsn = EXCLUDED.sync_lsn;

            RAISE NOTICE '    OK: %', rpad('Triggering sync event on node ' || rec.node_name || ' (LSN: ' || remotesql || ')', 120, ' ');
        EXCEPTION
            WHEN OTHERS THEN
                RAISE EXCEPTION '    ✗ %', rpad('Triggering sync event on node ' || rec.node_name || ' (error: ' || SQLERRM || ')', 120, ' ');
                CONTINUE;
        END;

        -- Create replication slot on the "other" node
        BEGIN
            -- Extract dbname and handle both quoted and unquoted values
            SELECT spock.extract_dbname_from_dsn(rec.dsn) INTO dbname;

            -- Remove single quotes if present
            IF dbname IS NOT NULL THEN
                dbname := TRIM(BOTH '''' FROM dbname);
            END IF;

            -- Remove single quotes if present
            IF dbname IS NOT NULL THEN
                dbname := TRIM(BOTH '''' FROM dbname);
            END IF;
            IF dbname IS NULL THEN dbname := 'pgedge'; END IF;

			slot_name := spock.spock_gen_slot_name(
							dbname, rec.node_name,
							'sub_' || rec.node_name || '_' || new_node_name);

            remotesql := format('SELECT slot_name, lsn FROM pg_create_logical_replication_slot(%L, ''spock_output'');', slot_name);
            IF verb THEN
                RAISE NOTICE '    Remote SQL for slot creation: %', remotesql;
            END IF;

            SELECT lsn INTO _commit_lsn
                FROM dblink(rec.dsn, remotesql) AS t(slot_name text, lsn pg_lsn);
            UPDATE temp_sync_lsns SET commit_lsn = _commit_lsn
                WHERE origin_node = rec.node_name;
            RAISE NOTICE '    OK: %', rpad('Creating replication slot ' || slot_name || ' (LSN: ' || _commit_lsn || ')' || ' on node ' || rec.node_name, 120, ' ');
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE '    ✗ %', rpad('Creating replication slot ' || slot_name || ' on node ' || rec.node_name || ' (error: ' || SQLERRM || ')', 120, ' ');
                CONTINUE;
        END;

        -- Create disabled subscription on new node from "other" node
        BEGIN
			sub_name := 'sub_' || rec.node_name || '_' || new_node_name;
            CALL spock.create_sub(
                new_node_dsn,                                 -- Create on new node
                sub_name, 									  -- sub_<new_node>_<other_node>
                rec.dsn,                                      -- Provider is other node
                'ARRAY[''default'', ''default_insert_only'', ''ddl_sql'']', -- Replication sets
                false,                                        -- synchronize_structure
                false,                                        -- synchronize_data
                'ARRAY[]::text[]',                            -- forward_origins
                '0'::interval,                                -- apply_delay
                false,                                        -- enabled (disabled)
                false,                                        -- force_text_transfer
                verb                                          -- verbose
            );
            RAISE NOTICE '    ✓ %', rpad('Creating initial subscription ' || sub_name || ' on node ' || rec.node_name, 120, ' ');
            PERFORM pg_sleep(5);
            subscription_count := subscription_count + 1;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE '    ✗ %', rpad('Creating initial subscription ' || sub_name || ' on node ' || rec.node_name || ' (error: ' || SQLERRM || ')', 120, ' ');
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
CREATE OR REPLACE PROCEDURE spock.enable_disabled_subscriptions(
    src_node_name text,
    src_dsn text,
    new_node_name text,
    new_node_dsn text,
    verb boolean
) LANGUAGE plpgsql AS $$
DECLARE
    rec      RECORD;
	sub_name text;
BEGIN
    RAISE NOTICE 'Phase 8: Enabling disabled subscriptions';

    -- Check if this is a 2-node scenario (only source and new node)
    IF (SELECT count(*) FROM temp_spock_nodes WHERE node_name != src_node_name AND node_name != new_node_name) = 0 THEN
        -- 2-node scenario: enable the disabled subscription from source to new node

		sub_name := 'sub_' || src_node_name || '_' || new_node_name;

        BEGIN
            CALL spock.enable_sub( new_node_dsn, sub_name, verb, true);

            -- Wait for the sync event that was captured when subscription was created
            -- This ensures the subscription starts replicating from the correct sync point
            DECLARE
                sync_lsn text;
                timeout_ms integer := 1200;  -- 20 minutes
                temp_table_exists boolean;
            BEGIN
                -- Check if temp_sync_lsns table exists
                SELECT EXISTS (
                    SELECT 1 FROM pg_tables
                    WHERE tablename = 'temp_sync_lsns'
                    AND schemaname = 'pg_temp'
                ) INTO temp_table_exists;

                IF temp_table_exists THEN
                    -- Get the stored sync LSN from when subscription was created
                    SELECT tsl.sync_lsn INTO sync_lsn
                    FROM temp_sync_lsns tsl
                    WHERE tsl.origin_node = src_node_name;

                    IF sync_lsn IS NOT NULL THEN
                        IF verb THEN
                            RAISE NOTICE '    OK: %', rpad('Using stored sync event from origin node ' || src_node_name || ' (LSN: ' || sync_lsn || ')...', 120, ' ');
                        END IF;

                        -- Wait for this sync event on the new node where the subscription exists
                        PERFORM * FROM dblink(new_node_dsn,
                            format('CALL spock.wait_for_sync_event(true, %L, %L::pg_lsn, %s)',
                                   src_node_name, sync_lsn, timeout_ms)) AS t(result text);

                        IF verb THEN
                            RAISE NOTICE '    OK: %', rpad('Waiting for sync event from ' || src_node_name || ' on new node ' || new_node_name || '...', 120, ' ');
                        END IF;
                    ELSE
                        RAISE NOTICE '    WARNING: %', rpad('No stored sync LSN found for ' || src_node_name || ', skipping sync wait', 120, ' ');
                    END IF;
                ELSE
                    -- For 2-node scenario where temp_sync_lsns doesn't exist, skip sync wait
                    IF verb THEN
                        RAISE NOTICE '    INFO: %', rpad('2-node scenario detected, no sync LSN table available, skipping sync wait', 120, ' ');
                    END IF;
                END IF;
            END;

            -- Verify subscription is replicating after enabling (2-node scenario)
            CALL spock.verify_subscription_replicating(
                new_node_dsn,
                'sub_' || src_node_name || '_' || new_node_name,
                verb
            );

            RAISE NOTICE '    ✓ %', rpad('Enabling subscription ' || sub_name || '...', 120, ' ');
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE '    ✗ %', rpad('Enabling subscription ' || sub_name || ' (error: ' || SQLERRM || ')', 120, ' ');
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

				sub_name := 'sub_'|| rec.node_name || '_' || new_node_name;

                CALL spock.enable_sub(new_node_dsn, sub_name, verb, true);

                -- Wait for the sync event that was captured when subscription was created
                -- This ensures the subscription starts replicating from the correct sync point
                DECLARE
                    sync_lsn text;
                    timeout_ms integer := 1200;  -- 20 minutes
                BEGIN
                    -- Get the stored sync LSN from when subscription was created
                    SELECT tsl.sync_lsn INTO sync_lsn
                    FROM temp_sync_lsns tsl
                    WHERE tsl.origin_node = rec.node_name;

                    IF sync_lsn IS NOT NULL THEN
                        IF verb THEN
                            RAISE NOTICE '    OK: %', rpad('Using stored sync event from origin node ' || rec.node_name || ' (LSN: ' || sync_lsn || ')...', 120, ' ');
                        END IF;

                        -- Wait for this sync event on the new node where the subscription exists
                        PERFORM * FROM dblink(new_node_dsn,
                            format('CALL spock.wait_for_sync_event(true, %L, %L::pg_lsn, %s)',
                                   rec.node_name, sync_lsn, timeout_ms)) AS t(result text);

                        IF verb THEN
                            RAISE NOTICE '    OK: %', rpad('Waiting for sync event from ' || rec.node_name || ' on new node ' || new_node_name || '...', 120, ' ');
                        END IF;
                    ELSE
                        RAISE NOTICE '    WARNING: %', rpad('No stored sync LSN found for ' || rec.node_name || ', skipping sync wait', 120, ' ');
                    END IF;
                END;

                -- Verify subscription is replicating after enabling
                CALL spock.verify_subscription_replicating(
                    new_node_dsn,
                    'sub_'|| rec.node_name || '_' || new_node_name,
                    verb
                );

                RAISE NOTICE '    ✓ %', rpad('Enabling subscription ' || sub_name || '...', 120, ' ');
                subscription_count := subscription_count + 1;
            END LOOP;

            IF subscription_count = 0 THEN
                RAISE NOTICE '    - %', rpad('No subscriptions to enable', 120, ' ');
            END IF;
        END;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE '%', '    ✗ Enabling disabled subscriptions...' || ' (error: ' || SQLERRM || ')';
            RAISE;
    END;
END;
$$;

-- ============================================================================
-- Procedure to create a subscription from new node to source node only
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.create_sub_on_new_node_to_src_node(
    src_node_name   text,  -- Source node name
    src_dsn         text,  -- Source node DSN
    new_node_name   text,  -- New node name
    new_node_dsn    text,  -- New node DSN
    verb            boolean  -- Verbose flag
) LANGUAGE plpgsql AS $$
DECLARE
    rec                RECORD;
    subscription_count integer := 0;
	sub_name           text;
BEGIN
    RAISE NOTICE 'Phase 9: Creating subscriptions from all other nodes to new node';

    -- Get all existing nodes (excluding new node)
    CALL spock.get_spock_nodes(src_dsn, verb);

    -- For each existing node (excluding new node), create subscription TO the new node
    FOR rec IN SELECT * FROM temp_spock_nodes WHERE node_name != new_node_name LOOP
	    sub_name := 'sub_' || rec.node_name || '_' || new_node_name;
        BEGIN
            CALL spock.create_sub(
                rec.dsn,                                      -- Create on existing node
                sub_name, 									  -- sub_<new_node>_<existing_node>
                new_node_dsn,                                 -- Provider is new node
                'ARRAY[''default'', ''default_insert_only'', ''ddl_sql'']', -- Replication sets
                false,                                        -- synchronize_structure
                false,                                        -- synchronize_data
                'ARRAY[]::text[]',                            -- forward_origins
                '0'::interval,                                -- apply_delay
                true,                                         -- enabled
                false,                                        -- force_text_transfer
                verb                                          -- verbose
            );
            RAISE NOTICE '    ✓ %', rpad('Creating subscription ' || sub_name || ' on node ' || rec.node_name || '...', 120, ' ');
            PERFORM pg_sleep(5);
            subscription_count := subscription_count + 1;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE '    ✗ %', rpad('Creating subscription ' || sub_name || ' on node ' || rec.node_name || ' (error: ' || SQLERRM || ')', 120, ' ');
        END;
    END LOOP;

    IF subscription_count = 0 THEN
        RAISE NOTICE '    - No subscriptions created (no other nodes found)';
    ELSE
        RAISE NOTICE '    OK: Created % subscriptions from other nodes to new node', subscription_count;
    END IF;
END;
$$;

-- ============================================================================
-- Procedure to create new to source node subscription
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.create_new_to_source_subscription(
    src_node_name text,
    src_dsn text,
    new_node_name text,
    new_node_dsn text,
    verb boolean
) LANGUAGE plpgsql AS $$
DECLARE
    sub_name text := 'sub_' || new_node_name || '_' || src_node_name;
BEGIN
    RAISE NOTICE 'Phase 10: Creating new to source node subscription';

    -- Create subscription from new node to source node (enabled with sync)
    CALL spock.create_sub(
        src_dsn,
        sub_name,
        new_node_dsn,
        'ARRAY[''default'', ''default_insert_only'', ''ddl_sql'']',
        false,   -- synchronize_structure
        false,   -- synchronize_data
        'ARRAY[]::text[]',
        '0'::interval,
        true,   -- enabled
        false,   -- force_text_transfer
        verb
    );
    RAISE NOTICE '    ✓ %', rpad('Creating subscription ' || sub_name || ' on node ' || new_node_name || '...', 120, ' ');
    PERFORM pg_sleep(5);
END;
$$;

-- ============================================================================
-- Procedure to create source to new node subscription
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.create_source_to_new_subscription(
    src_node_name   text,  -- Source node name
    src_dsn         text,  -- Source node DSN
    new_node_name   text,  -- New node name
    new_node_dsn    text,  -- New node DSN
    verb            boolean  -- Verbose flag
) LANGUAGE plpgsql AS $$
DECLARE
    sub_name text := 'sub_' || src_node_name || '_' || new_node_name;
BEGIN
    RAISE NOTICE 'Phase 4: Creating source to new node subscription';

    -- Create subscription from source to new node (enabled with sync)
    CALL spock.create_sub(
        new_node_dsn,                                 -- Create on new node
        sub_name, 									  -- sub_<new_node>_<src_node>
        src_dsn,                                      -- Provider is source node
        'ARRAY[''default'', ''default_insert_only'', ''ddl_sql'']', -- Replication sets
        true,                                         -- synchronize_structure
        true,                                         -- synchronize_data
        'ARRAY[]::text[]',                            -- forward_origins
        '0'::interval,                                -- apply_delay
        true,                                         -- enabled
        false,                                        -- force_text_transfer
        verb                                          -- verbose
    );
    RAISE NOTICE '    ✓ %', rpad('Creating subscription ' || sub_name || ' on node ' || new_node_name || '...', 120, ' ');
    PERFORM pg_sleep(5);
END;
$$;

-- ============================================================================
-- Procedure to trigger sync events on other nodes and wait on source
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.trigger_sync_on_other_nodes_and_wait_on_source(
    src_node_name text,  -- Source node name
    src_dsn text,        -- Source node DSN
    new_node_name text,  -- New node name
    new_node_dsn text,   -- New node DSN
    verb boolean         -- Verbose flag
) LANGUAGE plpgsql AS $$
DECLARE
    rec RECORD;
    sync_lsn pg_lsn;
    timeout_ms integer := 1200;  -- 20 minutes timeout
    remotesql text;
BEGIN
    RAISE NOTICE 'Phase 5: Triggering sync events on other nodes and waiting on source';

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
            RAISE NOTICE '    OK: %', rpad('Triggering sync event on node ' || rec.node_name || ' (LSN: ' || sync_lsn || ')...', 120, ' ');
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE '    ✗ %', rpad('Triggering sync event on node ' || rec.node_name || ' (error: ' || SQLERRM || ')', 120, ' ');
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
            RAISE NOTICE '    OK: %', rpad('Waiting for sync event from ' || rec.node_name || ' on source node ' || src_node_name || '...', 120, ' ');
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE '    ✗ %', rpad('Waiting for sync event from ' || rec.node_name || ' on source node ' || src_node_name || ' (error: ' || SQLERRM || ')', 120, ' ');
        END;
    END LOOP;
END;
$$;

-- ============================================================================
-- Procedure to check commit timestamp and advance replication slot
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.check_commit_timestamp_and_advance_slot(
    src_node_name text,  -- Source node name
    src_dsn text,        -- Source node DSN
    new_node_name text,  -- New node name
    new_node_dsn text,   -- New node DSN
    verb boolean         -- Verbose flag
) LANGUAGE plpgsql AS $$
DECLARE
    rec RECORD;
    commit_lsn pg_lsn;
    slot_name text;
    dbname text;
    remotesql text;
BEGIN
    RAISE NOTICE 'Phase 7: Checking commit timestamp and advancing replication slot';

    -- Check if this is a 2-node scenario (only source and new node)
    IF (SELECT count(*) FROM temp_spock_nodes WHERE node_name != src_node_name AND node_name != new_node_name) = 0 THEN
        RAISE NOTICE '    - No other nodes exist, skipping commit timestamp check';
        RETURN;
    END IF;

    -- Multi-node scenario: check commit timestamp for "other" nodes to new node
    FOR rec IN SELECT * FROM temp_spock_nodes WHERE node_name != src_node_name AND node_name != new_node_name LOOP
        BEGIN
            IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'temp_sync_lsns' AND relpersistence = 't') THEN
                -- Get the stored sync LSN from when subscription was created
                SELECT tsl.commit_lsn INTO commit_lsn
                FROM temp_sync_lsns tsl
                WHERE tsl.origin_node = rec.node_name;

                IF commit_lsn IS NOT NULL THEN
                    RAISE NOTICE '    OK: %', rpad('Found commit LSN for ' || rec.node_name || ' (LSN: ' || commit_lsn || ')...', 120, ' ');
                ELSE
                    RAISE NOTICE '    - %', rpad('No commit LSN found for ' || rec.node_name || '->' || new_node_name, 120, ' ');
                    CONTINUE;
                END IF;
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE '    ✗ %', rpad('Checking commit LSN for ' || rec.node_name || '->' || new_node_name || ' (error: ' || SQLERRM || ')', 120, ' ');
                CONTINUE;
        END;

        -- Advance replication slot based on commit timestamp
        BEGIN
            -- Extract dbname and handle both quoted and unquoted values
            SELECT spock.extract_dbname_from_dsn(rec.dsn) INTO dbname;

            -- Remove single quotes if present
            IF dbname IS NOT NULL THEN
                dbname := TRIM(BOTH '''' FROM dbname);
            END IF;

            -- Remove single quotes if present
            IF dbname IS NOT NULL THEN
                dbname := TRIM(BOTH '''' FROM dbname);
            END IF;
            IF dbname IS NULL THEN dbname := 'pgedge'; END IF;

			slot_name := spock.spock_gen_slot_name(dbname, rec.node_name, 'sub_' || rec.node_name || '_' || new_node_name);

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

                target_lsn := commit_lsn;
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
                RAISE NOTICE '    OK: %', rpad('Advanced slot ' || slot_name || ' from ' || current_lsn || ' to ' || target_lsn, 120, ' ');
            END;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE '    ✗ %', rpad('Advancing slot ' || slot_name || ' to LSN ' || commit_lsn || ' (error: ' || SQLERRM || ')', 120, ' ');
                -- Continue with other nodes even if this one fails
        END;
    END LOOP;
END;
$$;

-- ============================================================================
-- Procedure to trigger sync on source node and wait for it on new node using sync_event and wait_for_sync_event
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.trigger_source_sync_and_wait_on_new_node(
    src_node_name text,
    src_dsn text,
    new_node_name text,
    new_node_dsn text,
    verb boolean,
    sync_check_on_new_node boolean DEFAULT false
) LANGUAGE plpgsql AS $$
DECLARE
    remotesql text;
    sync_lsn pg_lsn;
    timeout_ms integer := 1200;  -- 20 minutes timeout
BEGIN
    RAISE NOTICE 'Phase 6: Triggering sync on source node and waiting on new node';

    -- Trigger sync event on source node and wait for it on new node
    BEGIN
        remotesql := 'SELECT spock.sync_event();';
        IF verb THEN
            RAISE NOTICE '    Remote SQL for sync_event on source node %: %', src_node_name, remotesql;
        END IF;
        SELECT * FROM dblink(src_dsn, remotesql) AS t(lsn pg_lsn) INTO sync_lsn;
        RAISE NOTICE '    OK: %', rpad('Triggered sync_event on source node ' || src_node_name || ' (LSN: ' || sync_lsn || ')...', 120, ' ');
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE '    ✗ %', rpad('Triggering sync_event on source node ' || src_node_name || ' (error: ' || SQLERRM || ')', 120, ' ');
            RAISE;
    END;

    -- Wait for sync event on new node
    BEGIN
        remotesql := format('CALL spock.wait_for_sync_event(true, %L, %L::pg_lsn, %s);', src_node_name, sync_lsn, timeout_ms);
        IF verb THEN
            RAISE NOTICE '    Remote SQL for wait_for_sync_event on new node %: %', new_node_name, remotesql;
        END IF;
        PERFORM * FROM dblink(new_node_dsn, remotesql) AS t(result text);
        RAISE NOTICE '    OK: %', rpad('Waiting for sync event from ' || src_node_name || ' on new node ' || new_node_name || '...', 120, ' ');
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION '    ✗ %', rpad('Unable to wait for sync event from ' || src_node_name || ' on new node ' || new_node_name || ' (error: ' || SQLERRM || ')', 120, ' ');
    END;
END;
$$;

-- ============================================================================
-- Procedure to present final cluster state
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.present_final_cluster_state(
    src_dsn            text,
    initial_node_count integer,
    verb boolean DEFAULT false
) LANGUAGE plpgsql AS $$
DECLARE
    node_rec RECORD;
    sub_rec  RECORD;
    rec RECORD;
    wait_count integer := 0;
    max_wait_count integer := 300; -- Wait up to 300 seconds
BEGIN
    -- Let remote subscriptions update their subscription's state.
    COMMIT;

    -- Phase 10: Presenting final cluster state
    RAISE NOTICE 'Phase 10: Presenting final cluster state';

    -- Wait for replication to be active
    RAISE NOTICE '    Waiting for replication to be active...';
    LOOP
        wait_count := wait_count + 1;
        sub_rec := NULL;

        -- Pass through all subscriptions and detect if some of them is not
		-- replicating.
        FOR node_rec IN SELECT dsn
            FROM dblink(src_dsn, '
                        SELECT i.if_dsn
                        FROM spock.node n JOIN spock.node_interface i
                        ON n.node_id = i.if_nodeid ORDER BY n.node_name'
            ) AS t(dsn text)
        LOOP
            SELECT sub_name, status INTO sub_rec
                FROM dblink(node_rec.dsn, '
                            SELECT subscription_name, status
                            FROM spock.sub_show_status()
                            WHERE status <> ''replicating''
                            ORDER BY subscription_name LIMIT 1'
                ) AS t(sub_name text, status text);
            EXIT WHEN sub_rec IS NOT NULL;
        END LOOP;

        IF sub_rec IS NULL THEN
            RAISE NOTICE '    OK: Replication is active';
            EXIT;
        ELSIF wait_count >= max_wait_count THEN
            RAISE NOTICE '    WARNING: Timeout waiting for subscription % to become active (current status: %)', sub_rec.sub_name, sub_rec.status;
            EXIT;
        ELSE
            RAISE NOTICE '    Waiting for replication... (subscription: %, status: %, attempt %/%)',
                sub_rec.sub_name, sub_rec.status, wait_count, max_wait_count;
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
CREATE OR REPLACE PROCEDURE spock.monitor_replication_lag(
    src_node_name text,
    new_node_name text,
    new_node_dsn text,
    verb boolean
) LANGUAGE plpgsql AS $$
BEGIN
    -- Phase 11: Monitor replication lag
    RAISE NOTICE 'Phase 11: Monitoring replication lag';
    CALL spock.monitor_lag_with_dblink(src_node_name, new_node_name, new_node_dsn, verb);
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
 *   verb			   - verbose, show more information during the process (default: false)
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
CREATE OR REPLACE PROCEDURE spock.add_node(
    src_node_name text,
    src_dsn text,
    new_node_name text,
    new_node_dsn text,
    verb boolean DEFAULT false,
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
    -- Phase 0: Check Spock version compatibility across all nodes
    -- Example: Ensure all nodes are running the same Spock version before proceeding
    CALL spock.check_spock_version_compatibility(src_dsn, new_node_dsn, verb);

    -- Phase 1: Verify prerequisites for source and new node.
    -- Example: Ensure n1 (source) and n4 (new) are ready before adding n4 to cluster n1,n2,n3.
    CALL spock.verify_node_prerequisites(src_node_name, src_dsn, new_node_name, new_node_dsn, verb);

    -- Phase 2: Create node objects in the cluster.
    -- Example: Register n4 as a new node alongside n1, n2, n3.
    CALL spock.create_nodes_only(src_node_name, src_dsn, new_node_name, new_node_dsn, verb, new_node_location, new_node_country, new_node_info, initial_node_count);

    -- Phase 3: Create disabled subscriptions and replication slots.
    -- Example: Prepare n4 for replication but keep subscriptions disabled initially.
    CALL spock.create_disable_subscriptions_and_slots(src_node_name, src_dsn, new_node_name, new_node_dsn, verb);

    -- Phase 4: Trigger sync events on other nodes and wait on source.
    -- Example: Sync n2 and n3, then wait for n1 to acknowledge before proceeding with n4.
    CALL spock.trigger_sync_on_other_nodes_and_wait_on_source(src_node_name, src_dsn, new_node_name, new_node_dsn, verb);

    -- Phase 5: Create subscription from source to new node.
    -- Example: Set up n1 to replicate to n4.
    CALL spock.create_source_to_new_subscription(src_node_name, src_dsn, new_node_name, new_node_dsn, verb);

    -- Phase 6: Trigger sync on source node and wait on new node.
    -- Example: Ensure n1 and n4 are fully synchronized before continuing.
    CALL spock.trigger_source_sync_and_wait_on_new_node(src_node_name, src_dsn, new_node_name, new_node_dsn, verb, true);

    -- Phase 7: Check commit timestamp and advance replication slot.
    -- Example: Confirm n4 is caught up to n1's latest changes.
    CALL spock.check_commit_timestamp_and_advance_slot(src_node_name, src_dsn, new_node_name, new_node_dsn, verb);

    -- Phase 8: Enable previously disabled subscriptions.
    -- Example: Activate replication paths for n4.
    CALL spock.enable_disabled_subscriptions(src_node_name, src_dsn, new_node_name, new_node_dsn, verb);

    -- Phase 9: Create subscription from new node to source node.
    -- Example: Set up n4 to replicate back to n1 for bidirectional sync.
    CALL spock.create_sub_on_new_node_to_src_node(src_node_name, src_dsn, new_node_name, new_node_dsn, verb);

    -- Phase 10: Present final cluster state.
    -- Example: Show n1, n2, n3, n4 as fully connected and synchronized.
    CALL spock.present_final_cluster_state(src_dsn, initial_node_count, verb);

    -- Phase 11: Monitor replication lag.
    -- Example: Check that n4 is keeping up with n1, n2, n3 after joining.
    CALL spock.monitor_replication_lag(src_node_name, new_node_name, new_node_dsn, verb);

    -- Phase 12: Show comprehensive node status across all nodes.
    -- Example: Display all nodes in n1, n2, n3, n4, n5 cluster.
    CALL spock.show_all_nodes(src_dsn, verb);

    -- Phase 13: Show comprehensive subscription status across all nodes.
    -- Example: Display status of all subscriptions in n1, n2, n3, n4, n5 cluster.
    CALL spock.show_all_subscription_status(src_dsn, verb);
END;
$$;

-- ============================================================================
-- Procedure: health_check
-- Purpose : Validate cluster health before or after ZODAN node addition
--           Similar to pg_upgrade -c (check) option
-- Arguments:
--   src_node_name  - Source node name
--   src_dsn        - Source node DSN
--   new_node_name  - New node name (optional for cluster-wide check)
--   new_node_dsn   - New node DSN (optional for cluster-wide check)
--   check_type     - Check type: 'pre' (before add_node) or 'post' (after add_node)
--   verb           - Verbose output flag
-- Usage    :
--   -- Pre-check before adding a node
--   CALL spock.health_check('n1', 'host=localhost dbname=pgedge port=5431 user=pgedge password=pgedge',
--                           'n3', 'host=localhost dbname=pgedge port=5433 user=pgedge password=pgedge',
--                           'pre', true);
--
--   -- Post-check after adding a node
--   CALL spock.health_check('n1', 'host=localhost dbname=pgedge port=5431 user=pgedge password=pgedge',
--                           'n3', 'host=localhost dbname=pgedge port=5433 user=pgedge password=pgedge',
--                           'post', true);
--
--   -- Cluster-wide check (no new node)
--   CALL spock.health_check('n1', 'host=localhost dbname=pgedge port=5431 user=pgedge password=pgedge',
--                           NULL, NULL, 'pre', true);
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.health_check(
    src_node_name text,
    src_dsn text,
    new_node_name text DEFAULT NULL,
    new_node_dsn text DEFAULT NULL,
    check_type text DEFAULT 'pre',
    verb boolean DEFAULT false
) LANGUAGE plpgsql AS $$
DECLARE
    checks_passed integer := 0;
    checks_failed integer := 0;
    check_result text;
    node_rec RECORD;
    remotesql text;
    result_value text;
    result_count integer;
    src_version text;
    new_version text;
    sub_count text;
    user_table_count text;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '================================================================================';
    RAISE NOTICE 'ZODAN CLUSTER HEALTH CHECK (%-CHECK)', upper(check_type);
    RAISE NOTICE '================================================================================';

    -- ========================================================================
    -- Check 1: Spock version compatibility (if new node provided)
    -- ========================================================================
    IF new_node_dsn IS NOT NULL THEN
        BEGIN
            -- Call existing check_spock_version_compatibility procedure
            CALL spock.check_spock_version_compatibility(src_dsn, new_node_dsn, false);
            RAISE NOTICE 'PASS: Spock version compatibility check';
            checks_passed := checks_passed + 1;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'FAIL: Spock version compatibility - %', SQLERRM;
            checks_failed := checks_failed + 1;
        END;
    END IF;

    -- ========================================================================
    -- Check 2: Node connectivity - Source node
    -- ========================================================================
    BEGIN
        remotesql := 'SELECT 1';
        SELECT * FROM dblink(src_dsn, remotesql) AS t(result integer) INTO result_value;
        RAISE NOTICE 'PASS: Source node % connectivity', src_node_name;
        checks_passed := checks_passed + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'FAIL: Source node % connectivity - %', src_node_name, SQLERRM;
        checks_failed := checks_failed + 1;
    END;

    -- ========================================================================
    -- Check 3: Node connectivity - New node (if provided)
    -- ========================================================================
    IF new_node_dsn IS NOT NULL THEN
        BEGIN
            remotesql := 'SELECT 1';
            SELECT * FROM dblink(new_node_dsn, remotesql) AS t(result integer) INTO result_value;
            RAISE NOTICE 'PASS: New node % connectivity', new_node_name;
            checks_passed := checks_passed + 1;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'FAIL: New node % connectivity - %', new_node_name, SQLERRM;
            checks_failed := checks_failed + 1;
        END;
    END IF;

    -- ========================================================================
    -- Check 4: Spock extension installation - Source node
    -- ========================================================================
    BEGIN
        remotesql := 'SELECT extversion FROM pg_extension WHERE extname = ''spock''';
        SELECT * FROM dblink(src_dsn, remotesql) AS t(version text) INTO src_version;
        IF src_version IS NOT NULL THEN
            RAISE NOTICE 'PASS: Spock extension on source node (version %)', src_version;
            checks_passed := checks_passed + 1;
        ELSE
            RAISE NOTICE 'FAIL: Spock extension not installed on source node';
            checks_failed := checks_failed + 1;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'FAIL: Spock extension check on source - %', SQLERRM;
        checks_failed := checks_failed + 1;
    END;

    -- ========================================================================
    -- Check 5: Spock extension installation - New node (if provided)
    -- ========================================================================
    IF new_node_dsn IS NOT NULL THEN
        BEGIN
            remotesql := 'SELECT extversion FROM pg_extension WHERE extname = ''spock''';
            SELECT * FROM dblink(new_node_dsn, remotesql) AS t(version text) INTO new_version;
            IF new_version IS NOT NULL THEN
                RAISE NOTICE 'PASS: Spock extension on new node (version %)', new_version;
                checks_passed := checks_passed + 1;
            ELSE
                RAISE NOTICE 'FAIL: Spock extension not installed on new node';
                checks_failed := checks_failed + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'FAIL: Spock extension check on new node - %', SQLERRM;
            checks_failed := checks_failed + 1;
        END;
    END IF;

    -- ========================================================================
    -- Check 6: Cluster node enumeration
    -- ========================================================================
    BEGIN
        remotesql := 'SELECT count(*) FROM spock.node';
        SELECT * FROM dblink(src_dsn, remotesql) AS t(node_count integer) INTO result_count;
        RAISE NOTICE 'PASS: Cluster has % nodes', result_count;
        checks_passed := checks_passed + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'FAIL: Cluster node enumeration - %', SQLERRM;
        checks_failed := checks_failed + 1;
    END;

    -- ========================================================================
    -- Check 7: Active subscriptions on each node
    -- ========================================================================
    BEGIN
        FOR node_rec IN
            SELECT node_name, if_dsn
            FROM dblink(src_dsn,
                'SELECT n.node_name, i.if_dsn FROM spock.node n JOIN spock.node_interface i ON n.node_id = i.if_nodeid'
            ) AS t(node_name text, if_dsn text)
        LOOP
            BEGIN
                remotesql := 'SELECT count(*) FROM spock.subscription WHERE sub_enabled = true';
                SELECT * FROM dblink(node_rec.if_dsn, remotesql) AS t(sub_count text) INTO sub_count;
                RAISE NOTICE 'PASS: Node % has % active subscriptions', node_rec.node_name, COALESCE(sub_count, '0');
                checks_passed := checks_passed + 1;
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE 'FAIL: Node % subscription check - %', node_rec.node_name, SQLERRM;
                checks_failed := checks_failed + 1;
            END;
        END LOOP;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'FAIL: Cluster subscription check - %', SQLERRM;
        checks_failed := checks_failed + 1;
    END;

    -- ========================================================================
    -- Check 8: Database prerequisites (pre-check only)
    -- ========================================================================
    IF check_type = 'pre' AND new_node_dsn IS NOT NULL THEN
        -- Check 8a: Verify lolor extension is not installed
        BEGIN
            remotesql := 'SELECT count(*) FROM pg_tables WHERE schemaname = ''lolor''';
            SELECT * FROM dblink(new_node_dsn, remotesql) AS t(table_count text) INTO user_table_count;

            IF user_table_count IS NOT NULL AND user_table_count::integer = 0 THEN
                RAISE NOTICE 'PASS: Destination database does not have signs of lolor being installed';
                checks_passed := checks_passed + 1;
            ELSE
                RAISE NOTICE 'FAIL: Destination database has the lolor extension installed or remaining lolor user data in the lolor schema';
                checks_failed := checks_failed + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'FAIL: lolor extension check - %', SQLERRM;
            checks_failed := checks_failed + 1;
        END;

        -- Check 8b: Verify database is empty (no user tables)
        BEGIN
            remotesql := $pg_tables$
                SELECT count(*) FROM pg_tables
                WHERE schemaname NOT IN ('information_schema', 'pg_catalog', 'pg_toast', 'spock')
                AND schemaname NOT LIKE 'pg_temp_%'
                AND schemaname NOT LIKE 'pg_toast_temp_%'
            $pg_tables$;
            SELECT * FROM dblink(new_node_dsn, remotesql) AS t(table_count text) INTO user_table_count;

            IF user_table_count IS NOT NULL AND user_table_count::integer = 0 THEN
                RAISE NOTICE 'PASS: New node database is empty (fresh database)';
                checks_passed := checks_passed + 1;
            ELSE
                RAISE NOTICE 'FAIL: New node database has % user-created tables', user_table_count;
                checks_failed := checks_failed + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'FAIL: Database emptiness check - %', SQLERRM;
            checks_failed := checks_failed + 1;
        END;
    END IF;

    -- ========================================================================
    -- Check 9: Replication status (post-check only)
    -- ========================================================================
    IF check_type = 'post' AND new_node_name IS NOT NULL AND new_node_dsn IS NOT NULL THEN
        BEGIN
            remotesql := 'SELECT count(*) FROM spock.subscription WHERE sub_enabled = true';
            SELECT * FROM dblink(new_node_dsn, remotesql) AS t(sub_count text) INTO sub_count;

            IF sub_count IS NOT NULL AND sub_count::integer > 0 THEN
                RAISE NOTICE 'PASS: New node % has active subscriptions', new_node_name;
                checks_passed := checks_passed + 1;
            ELSE
                RAISE NOTICE 'FAIL: New node % has no active subscriptions', new_node_name;
                checks_failed := checks_failed + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'FAIL: Post-addition replication check - %', SQLERRM;
            checks_failed := checks_failed + 1;
        END;
    END IF;

    -- ========================================================================
    -- Summary
    -- ========================================================================
    RAISE NOTICE '';
    RAISE NOTICE '================================================================================';
    RAISE NOTICE 'HEALTH CHECK SUMMARY';
    RAISE NOTICE '================================================================================';
    RAISE NOTICE 'Checks Passed: %', checks_passed;
    RAISE NOTICE 'Checks Failed: %', checks_failed;
    RAISE NOTICE 'Total Checks:  %', checks_passed + checks_failed;
    RAISE NOTICE '';

    IF checks_failed > 0 THEN
        RAISE NOTICE 'RESULT: FAILED - Please resolve issues before proceeding';
        RAISE EXCEPTION 'Health check failed with % failed checks', checks_failed;
    ELSE
        RAISE NOTICE 'RESULT: PASSED - Cluster is ready for ZODAN node addition';
    END IF;
END;
$$;

