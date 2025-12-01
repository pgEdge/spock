-- ============================================================================
-- Spock Recovery Procedures (Forwarding-Based)
--
-- Simple recovery mechanism using forward_origins to cascade transactions
-- from a source node to a target node after a node failure.
--
-- How It Works:
-- ------------
-- When a node (e.g., n1) fails, transactions that originated from n1 may
-- exist on other nodes (e.g., n3) but not on the lagging node (e.g., n2).
-- 
-- By default, subscriptions filter out transactions with remote origins.
-- This recovery mechanism updates the target node's subscription to forward
-- all origins (including the failed node's origin), allowing the missing
-- transactions to be replicated from the source to the target.
--
-- Advantages:
-- -----------
-- * No recovery slots needed
-- * No WAL retention requirements
-- * No catalog_xmin filtering issues
-- * Works regardless of time gap
-- * Simple implementation - just updates subscription settings
--
-- Requirements:
--   * Spock 6.0.1-devel or newer
--   * Target node must have a subscription to the source node
--
-- Usage:
-- ------
--   CALL spock.recover_run(
--       failed_node_name := 'n1',
--       source_node_name := 'n3',
--       source_dsn       := 'host=localhost port=5453 dbname=pgedge user=pge',
--       target_node_name := 'n2',
--       target_dsn       := 'host=localhost port=5452 dbname=pgedge user=pge',
--       verb             := true
--   );
--
-- Example Scenario:
-- -----------------
-- Before crash:
--   n1: Has rows 1-90 (locally originated)
--   n3: Has rows 1-90 (origin = n1, received via sub_n1_n3)
--   n2: Has rows 1-20 (origin = n1, received via sub_n1_n2)
--
-- After n1 crashes:
--   n1: DOWN
--   n3: Has rows 1-90 (origin = n1)
--   n2: Has rows 1-20 (origin = n1)
--
-- Recovery:
--   1. Find subscription sub_n3_n2 (from n2 to n3)
--   2. Update forward_origins to {all}
--   3. Enable subscription if disabled
--   4. n3 forwards rows 21-90 (with origin = n1) to n2
--   5. n2 receives and applies all missing rows
--
-- Result:
--   n2: Has rows 1-90 (all with origin = n1)
--   Recovery complete!
-- ============================================================================

-- ============================================================================
-- Procedure: spock.recover_run
-- 
-- Configures the target node's subscription to the source node to forward
-- transactions from the failed node's origin.
--
-- This procedure must be called on the TARGET node (where recovery is needed).
--
-- Parameters:
--   failed_node_name - Name of the failed node (e.g., 'n1')
--   source_node_name - Name of the node that has the missing data (e.g., 'n3')
--   source_dsn       - DSN to connect to the source node (for validation)
--   target_node_name - Name of the node that needs recovery (e.g., 'n2')
--   target_dsn       - DSN to connect to the target node (for validation)
--   verb             - Verbose output flag (default: false)
-- ============================================================================
DROP PROCEDURE IF EXISTS spock.recover_run(
    text, text, text, text, text, boolean
);

-- ============================================================================
-- Procedure: spock.recover_run
-- Forwarding-based recovery implementation
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.recover_run(
    failed_node_name text,
    source_node_name text,
    source_dsn text,
    target_node_name text,
    target_dsn text,
    verb boolean DEFAULT false
)
LANGUAGE plpgsql
AS $$
DECLARE
    failed_node_id oid;
    source_node_id oid;
    target_node_id oid;
    current_forward_origins text[];
    recovery_sub_name text;
BEGIN
    -- Validate inputs
    IF failed_node_name IS NULL OR source_node_name IS NULL OR 
       target_node_name IS NULL OR source_dsn IS NULL OR target_dsn IS NULL THEN
        RAISE EXCEPTION 'All parameters must be provided';
    END IF;

    IF verb THEN
        RAISE INFO '[RECOVERY] Starting recovery: failed=%, source=%, target=%',
            failed_node_name, source_node_name, target_node_name;
    END IF;

    -- Get node IDs
    SELECT node_id INTO failed_node_id
    FROM spock.node WHERE node_name = failed_node_name;
    
    IF failed_node_id IS NULL THEN
        RAISE EXCEPTION 'Failed node % does not exist', failed_node_name;
    END IF;

    SELECT node_id INTO source_node_id
    FROM spock.node WHERE node_name = source_node_name;
    
    IF source_node_id IS NULL THEN
        RAISE EXCEPTION 'Source node % does not exist', source_node_name;
    END IF;

    SELECT node_id INTO target_node_id
    FROM spock.node WHERE node_name = target_node_name;
    
    IF target_node_id IS NULL THEN
        RAISE EXCEPTION 'Target node % does not exist', target_node_name;
    END IF;

    -- Verify this function is being called on the target node
    IF NOT EXISTS (
        SELECT 1 FROM spock.local_node WHERE node_id = target_node_id
    ) THEN
        RAISE EXCEPTION 'This function must be called on the target node (%), not on the current node',
            target_node_name;
    END IF;

    -- Find subscription from target to source
    SELECT sub_name INTO recovery_sub_name
    FROM spock.subscription
    WHERE sub_target = target_node_id
      AND sub_origin = source_node_id;
    
    IF recovery_sub_name IS NULL THEN
        RAISE EXCEPTION 'No subscription found from target % to source %',
            target_node_name, source_node_name;
    END IF;

    IF verb THEN
        RAISE INFO '[RECOVERY] Found subscription: %', recovery_sub_name;
    END IF;

    -- Get current forward_origins
    SELECT sub_forward_origins INTO current_forward_origins
    FROM spock.subscription
    WHERE sub_name = recovery_sub_name;

    -- Update forward_origins to forward all origins
    IF current_forward_origins IS NULL OR NOT ('all' = ANY(current_forward_origins)) THEN
        UPDATE spock.subscription
        SET sub_forward_origins = ARRAY['all']::text[]
        WHERE sub_name = recovery_sub_name;
        
        IF verb THEN
            RAISE INFO '[RECOVERY] Updated subscription % forward_origins to {all}',
                recovery_sub_name;
        END IF;
    ELSE
        IF verb THEN
            RAISE INFO '[RECOVERY] Subscription % already forwards all origins',
                recovery_sub_name;
        END IF;
    END IF;

    -- Enable subscription if disabled
    IF NOT EXISTS (
        SELECT 1 FROM spock.subscription 
        WHERE sub_name = recovery_sub_name AND sub_enabled = true
    ) THEN
        PERFORM spock.sub_enable(recovery_sub_name);
        IF verb THEN
            RAISE INFO '[RECOVERY] Enabled subscription %', recovery_sub_name;
        END IF;
    END IF;

    IF verb THEN
        RAISE INFO '[RECOVERY] Recovery configuration complete';
        RAISE INFO '[RECOVERY] Subscription % will forward all transactions (including from origin %)',
            recovery_sub_name, failed_node_name;
        RAISE INFO '[RECOVERY] Recovery will proceed automatically via normal replication';
        RAISE INFO '[RECOVERY] Monitor progress using: SELECT * FROM spock.sub_show_status(%)',
            recovery_sub_name;
    END IF;
END;
$$;

-- ============================================================================
-- Helper: Check recovery status
-- 
-- Monitor the subscription to see if recovery is progressing.
-- ============================================================================
CREATE OR REPLACE FUNCTION spock.recover_status(
    target_node_name text,
    source_node_name text,
    verb boolean DEFAULT false
)
RETURNS TABLE(
    subscription_name text,
    enabled boolean,
    forward_origins text[],
    status text
)
LANGUAGE plpgsql
AS $$
DECLARE
    target_node_id oid;
    source_node_id oid;
    sub_rec RECORD;
BEGIN
    -- Get node IDs
    SELECT node_id INTO target_node_id
    FROM spock.node WHERE node_name = target_node_name;
    
    IF target_node_id IS NULL THEN
        RAISE EXCEPTION 'Target node % does not exist', target_node_name;
    END IF;

    SELECT node_id INTO source_node_id
    FROM spock.node WHERE node_name = source_node_name;
    
    IF source_node_id IS NULL THEN
        RAISE EXCEPTION 'Source node % does not exist', source_node_name;
    END IF;

    -- Find subscription from target to source
    FOR sub_rec IN
        SELECT sub_name, sub_enabled, sub_forward_origins
        FROM spock.subscription
        WHERE sub_target = target_node_id
          AND sub_origin = source_node_id
    LOOP
        subscription_name := sub_rec.sub_name;
        enabled := sub_rec.sub_enabled;
        forward_origins := sub_rec.sub_forward_origins;
        
        IF sub_rec.sub_enabled AND ('all' = ANY(sub_rec.sub_forward_origins)) THEN
            status := 'Recovery active - forwarding all origins';
        ELSIF sub_rec.sub_enabled THEN
            status := 'Subscription enabled but not forwarding all origins';
        ELSE
            status := 'Subscription disabled';
        END IF;
        
        RETURN NEXT;
    END LOOP;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No subscription found from target % to source %',
            target_node_name, source_node_name;
    END IF;
END;
$$;

-- ============================================================================
-- Helper: Verify recovery completion
--
-- Checks if the target node has caught up with the source node by comparing
-- row counts on a specified table.
--
-- Parameters:
--   target_dsn       - DSN to connect to target node
--   source_dsn       - DSN to connect to source node
--   table_name       - Table to compare (e.g., 'crash_test')
--   schema_name      - Schema name (default: 'public')
-- ============================================================================
CREATE OR REPLACE FUNCTION spock.recover_verify(
    target_dsn text,
    source_dsn text,
    table_name text,
    schema_name text DEFAULT 'public'
)
RETURNS TABLE(
    target_rows bigint,
    source_rows bigint,
    rows_match boolean,
    message text
)
LANGUAGE plpgsql
AS $$
DECLARE
    target_count bigint;
    source_count bigint;
BEGIN
    -- Get row count from target
    PERFORM dblink_connect('target_conn', target_dsn);
    SELECT INTO target_count
        count FROM dblink('target_conn',
            format('SELECT count(*) FROM %I.%I', schema_name, table_name)
        ) AS t(count bigint);
    PERFORM dblink_disconnect('target_conn');
    
    -- Get row count from source
    PERFORM dblink_connect('source_conn', source_dsn);
    SELECT INTO source_count
        count FROM dblink('source_conn',
            format('SELECT count(*) FROM %I.%I', schema_name, table_name)
        ) AS t(count bigint);
    PERFORM dblink_disconnect('source_conn');
    
    target_rows := target_count;
    source_rows := source_count;
    rows_match := (target_count = source_count);
    
    IF rows_match THEN
        message := format('Recovery complete: both nodes have %s rows', target_count);
    ELSE
        message := format('Recovery in progress: target has %s rows, source has %s rows (missing %s)',
            target_count, source_count, source_count - target_count);
    END IF;
    
    RETURN NEXT;
END;
$$;
