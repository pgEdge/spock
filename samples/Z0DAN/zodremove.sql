-- ============================================================================
-- ZODAN - Node Removal Script (zodremove.sql)
-- Purpose: Systematically remove a node from Spock cluster
-- Order: subscription (includes slots) -> repsets -> node
--
-- Limitation: Must currently run this on the node you wish to remove
-- ============================================================================

-- Enable dblink extension if not already enabled
CREATE EXTENSION IF NOT EXISTS dblink;

-- ============================================================================
-- Function to check if replication set exists on a node
-- ============================================================================
CREATE OR REPLACE FUNCTION spock.check_repset_exists_on_node(
    node_dsn text,
    repset_name text
) RETURNS boolean AS $$
DECLARE
    result boolean := false;
    remotesql text;
BEGIN
    remotesql := format('SELECT EXISTS (SELECT 1 FROM spock.replication_set WHERE set_name = %L)', repset_name);
    SELECT * FROM dblink(node_dsn, remotesql) AS t(exists boolean) INTO result;
    RETURN result;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- Function to check if replication slot exists on a node
-- ============================================================================
CREATE OR REPLACE FUNCTION spock.check_slot_exists_on_node(
    node_dsn text,
    slot_name text
) RETURNS boolean AS $$
DECLARE
    result boolean := false;
    remotesql text;
BEGIN
    remotesql := format('SELECT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = %L)', slot_name);
    SELECT * FROM dblink(node_dsn, remotesql) AS t(exists boolean) INTO result;
    RETURN result;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- Function to check if node exists in cluster
-- ============================================================================
CREATE OR REPLACE FUNCTION spock.check_node_exists(
    node_name text
) RETURNS boolean AS $$
BEGIN
    RETURN EXISTS (SELECT 1 FROM spock.node WHERE spock.node.node_name = check_node_exists.node_name);
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- Function to get all replication slots for a node
-- ============================================================================
CREATE OR REPLACE FUNCTION spock.get_node_slots(
    node_name text
) RETURNS TABLE(slot_name text) AS $$
BEGIN
    RETURN QUERY
    SELECT slot_name::text
    FROM spock.node n
    JOIN spock.subscription sub ON sub.sub_origin = n.node_id
    WHERE n.node_name = get_node_slots.node_name;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- Phase 1: Validate node removal prerequisites
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.validate_node_removal_prerequisites(
    target_node_name text,    -- Name of the node to remove
    target_node_dsn text,     -- DSN of the node to remove
    verbose_mode boolean DEFAULT true
) AS $$
DECLARE
    node_count integer;
BEGIN
    IF verbose_mode THEN
        RAISE NOTICE 'Phase 1: Validating node removal prerequisites';
    END IF;

    -- Check if node exists in cluster
    IF NOT spock.check_node_exists(target_node_name) THEN
        RAISE EXCEPTION 'Node % does not exist in cluster', target_node_name;
    END IF;

    -- Get total node count in cluster
    SELECT count(*) INTO node_count FROM spock.node;

    IF verbose_mode THEN
        RAISE NOTICE '    ✓ Node % exists in cluster', target_node_name;
        RAISE NOTICE '    ✓ Total nodes in cluster: %', node_count;
    END IF;

    -- Validate that we're not trying to remove the last node
    IF node_count <= 1 THEN
        RAISE EXCEPTION 'Cannot remove the last node from cluster';
    END IF;

    IF verbose_mode THEN
        RAISE NOTICE '    ✓ Node removal validation passed';
    END IF;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- Phase 2: Gather cluster information
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.gather_cluster_info_for_removal(
    target_node_name text,    -- Name of the node to remove
    verbose_mode boolean DEFAULT true
) AS $$
BEGIN
    IF verbose_mode THEN
        RAISE NOTICE 'Phase 2: Gathering cluster information';
    END IF;

    -- Clear existing temp tables
    TRUNCATE temp_spock_nodes, temp_removal_status;

    -- Gather all nodes in cluster except the target node
    INSERT INTO temp_spock_nodes (node_id, node_name, location, country, info, dsn)
    SELECT n.node_id, n.node_name, n.location, n.country, n.info, ni.if_dsn
    FROM spock.node n
    JOIN spock.node_interface ni ON ni.if_nodeid = n.node_id
    WHERE n.node_name != target_node_name;

    IF verbose_mode THEN
        RAISE NOTICE '    ✓ Gathered information for % nodes', (SELECT count(*) FROM temp_spock_nodes);
        RAISE NOTICE '    ✓ Cluster information ready for node removal';
    END IF;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- Phase 3: Remove subscriptions
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.remove_node_subscriptions(
    target_node_name text,    -- Name of the node to remove
    verbose_mode boolean DEFAULT true
) AS $$
DECLARE
    sub_rec RECORD;
    result bool := false;
    remotesql text;
    subscription_name text;
BEGIN
    IF verbose_mode THEN
        RAISE NOTICE 'Phase 3: Removing subscriptions';
    END IF;

    -- Fetch sub_name(s) from remote nodes
    -- Loop through these remote nodes and drop subscriptions on them first
    -- Then drop local subscriptions on the target node

    FOR sub_rec IN SELECT * FROM temp_spock_nodes LOOP
        BEGIN
            -- get subscription name from remote nodes
            remotesql := format(
                'SELECT sub.sub_name AS sub_name
                FROM spock.subscription sub
                JOIN spock.node n
                ON sub.sub_target = n.node_id
                WHERE sub.sub_origin = (
                    SELECT node_id FROM spock.node WHERE node_name = %L
                )
                AND n.node_name = %L',
                target_node_name,
                sub_rec.node_name
            );

            SELECT t.sub_name INTO subscription_name
                FROM dblink(sub_rec.dsn, remotesql) AS t(sub_name text);

            IF verbose_mode THEN
                RAISE NOTICE '  Checking subscription: %', subscription_name;
            END IF;

            -- Remove subscription from remote nodes
            remotesql := format('SELECT spock.sub_drop(%L, true)', subscription_name);
            SELECT t.result INTO result
                FROM dblink(sub_rec.dsn, remotesql) AS t(result boolean);

            IF result THEN
                INSERT INTO temp_removal_status (component_type, component_name, status, message)
                    VALUES ('subscription', subscription_name, 'REMOVED', 'Successfully removed from target node');

                IF verbose_mode THEN
                    RAISE NOTICE '    ✓ Removed subscription: %', subscription_name;
                END IF;
            ELSE
                INSERT INTO temp_removal_status (component_type, component_name, status, message)
                    VALUES ('subscription', subscription_name, 'NOT_FOUND', 'Subscription not found on target node');

                IF verbose_mode THEN
                    RAISE NOTICE '    - Subscription % not found on target node', subscription_name;
                END IF;
            END IF;

        EXCEPTION WHEN OTHERS THEN
            INSERT INTO temp_removal_status (component_type, component_name, status, message)
            VALUES ('subscription', subscription_name, 'ERROR', SQLERRM);

            IF verbose_mode THEN
                RAISE NOTICE '    ✗ Error removing subscription %: %', subscription_name, SQLERRM;
            END IF;
        END;
    END LOOP;

    -- Now drop local subscriptions on the target node
    FOR sub_rec IN select sub_name from spock.subscription LOOP
        BEGIN
            IF verbose_mode THEN
                RAISE NOTICE '  Checking local subscription: %', sub_rec.sub_name;
            END IF;

            -- Remove local subscription
            PERFORM spock.sub_drop(sub_rec.sub_name, true);

            INSERT INTO temp_removal_status (component_type, component_name, status, message)
                VALUES ('subscription', sub_rec.sub_name, 'REMOVED', 'Successfully removed from local node');

            IF verbose_mode THEN
                RAISE NOTICE '    ✓ Removed local subscription: %', sub_rec.sub_name;
            END IF;

        EXCEPTION WHEN OTHERS THEN
            INSERT INTO temp_removal_status (component_type, component_name, status, message)
            VALUES ('subscription', sub_rec.sub_name, 'ERROR', SQLERRM);

            IF verbose_mode THEN
                RAISE NOTICE '    ✗ Error removing local subscription %: %', sub_rec.sub_name, SQLERRM;
            END IF;
        END;
    END LOOP;

    IF verbose_mode THEN
        RAISE NOTICE '    ✓ Subscription removal phase completed';
    END IF;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- Phase 4: Remove replication sets
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.remove_node_replication_sets(
    target_node_dsn text,     -- DSN of the node to remove
    verbose_mode boolean DEFAULT true
) AS $$
DECLARE
    repset_rec RECORD;
BEGIN
    IF verbose_mode THEN
        RAISE NOTICE 'Phase 4: Removing replication sets';
    END IF;

    -- Replication sets are local to each node, so we only need to drop them
    -- directly on the target node.
    FOR repset_rec IN SELECT set_name AS repset_name FROM spock.replication_set LOOP
        BEGIN
            IF verbose_mode THEN
                RAISE NOTICE '  Checking replication set: %', repset_rec.repset_name;
            END IF;

            -- Check if repset exists on target node
            IF spock.check_repset_exists_on_node(target_node_dsn, repset_rec.repset_name) THEN
                -- Remove repset from target node
                PERFORM spock.repset_drop(repset_rec.repset_name, true);

                INSERT INTO temp_removal_status (component_type, component_name, status, message)
                    VALUES ('repset', repset_rec.repset_name, 'REMOVED', 'Successfully removed from target node');

                IF verbose_mode THEN
                    RAISE NOTICE '    ✓ Removed replication set: %', repset_rec.repset_name;
                END IF;
            ELSE
                INSERT INTO temp_removal_status (component_type, component_name, status, message)
                    VALUES ('repset', repset_rec.repset_name, 'NOT_FOUND', 'Replication set not found on target node');

                IF verbose_mode THEN
                    RAISE NOTICE '    - Replication set % not found on target node', repset_rec.repset_name;
                END IF;
            END IF;

        EXCEPTION WHEN OTHERS THEN
            INSERT INTO temp_removal_status (component_type, component_name, status, message)
            VALUES ('repset', repset_rec.repset_name, 'ERROR', SQLERRM);

            IF verbose_mode THEN
                RAISE NOTICE '    ✗ Error removing replication set %: %', repset_rec.repset_name, SQLERRM;
            END IF;
        END;
    END LOOP;

    IF verbose_mode THEN
        RAISE NOTICE '    ✓ Replication set removal phase completed';
    END IF;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- Phase 5: Remove node from cluster
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.remove_node_from_cluster_registry(
    target_node_name text,    -- Name of the node to remove
    verbose_mode boolean DEFAULT true
) AS $$
BEGIN
    IF verbose_mode THEN
        RAISE NOTICE 'Phase 5: Removing node from cluster registry';
    END IF;

    BEGIN
        IF spock.check_node_exists(target_node_name) THEN
            -- Remove node from cluster
            PERFORM spock.node_drop(target_node_name, true);

            INSERT INTO temp_removal_status (component_type, component_name, status, message)
            VALUES ('node', target_node_name, 'REMOVED', 'Successfully removed from cluster');

            IF verbose_mode THEN
                RAISE NOTICE '    ✓ Removed node: %', target_node_name;
            END IF;
        ELSE
            INSERT INTO temp_removal_status (component_type, component_name, status, message)
            VALUES ('node', target_node_name, 'NOT_FOUND', 'Node not found in cluster');

            IF verbose_mode THEN
                RAISE NOTICE '    - Node % not found in cluster', target_node_name;
            END IF;
        END IF;

    EXCEPTION WHEN OTHERS THEN
        INSERT INTO temp_removal_status (component_type, component_name, status, message)
        VALUES ('node', target_node_name, 'ERROR', SQLERRM);

        IF verbose_mode THEN
            RAISE NOTICE '    ✗ Error removing node %: %', target_node_name, SQLERRM;
        END IF;
    END;

    IF verbose_mode THEN
        RAISE NOTICE '    ✓ Node removal phase completed';
    END IF;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- Phase 6: Final cleanup and status report
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.finalize_node_removal(
    target_node_name text,    -- Name of the node to remove
    verbose_mode boolean DEFAULT true
) AS $$
DECLARE
    total_processed integer;
    successfully_removed integer;
    errors_encountered integer;
    status_rec RECORD;
BEGIN
    IF verbose_mode THEN
        RAISE NOTICE 'Phase 6: Final cleanup and status report';
    END IF;

    -- Calculate summary statistics
    SELECT count(*), count(*) FILTER (WHERE status = 'REMOVED'), count(*) FILTER (WHERE status = 'ERROR')
    INTO total_processed, successfully_removed, errors_encountered
    FROM temp_removal_status;

    -- Display summary
    IF verbose_mode THEN
        RAISE NOTICE 'NODE REMOVAL SUMMARY';
        RAISE NOTICE 'Node removed: %', target_node_name;
        RAISE NOTICE 'Total components processed: %', total_processed;
        RAISE NOTICE 'Successfully removed: %', successfully_removed;
        RAISE NOTICE 'Errors encountered: %', errors_encountered;

        -- Show detailed status
        RAISE NOTICE 'Detailed Status:';
        FOR status_rec IN SELECT * FROM temp_removal_status ORDER BY removed_at LOOP
            RAISE NOTICE '  %: % - % - %', status_rec.component_type, status_rec.component_name, status_rec.status, status_rec.message;
        END LOOP;
    END IF;

    IF verbose_mode THEN
        RAISE NOTICE '    ✓ Node removal process completed';
    END IF;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- Main procedure: Remove node from Spock cluster (Phase-based approach)
-- Each phase includes a 2-line description and an example for n1,n2,n3,n4 removing n4
-- ============================================================================
CREATE OR REPLACE PROCEDURE spock.remove_node(
    target_node_name text,    -- Name of the node to remove
    target_node_dsn text,     -- DSN of the node to remove
    verbose_mode boolean DEFAULT true
) AS $$
BEGIN

    -- Do not allow removing the node if script is run on a different node
    IF (spock.node_info()).node_name != target_node_name THEN
        RAISE EXCEPTION 'This procedure must be run on the node being removed (%). Current node is %', target_node_name, (spock.node_info()).node_name;
    END IF;

    -- ============================================================================
    -- Temporary table for tracking removal status
    -- ============================================================================
    CREATE TEMP TABLE IF NOT EXISTS temp_removal_status (
        component_type text,
        component_name text,
        status text,
        message text,
        removed_at timestamp DEFAULT now()
    );

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

    -- Phase 1: Validate prerequisites.
    -- Ensure node n4 is eligible for removal (e.g., not a provider for others).
    -- Example: Check n4 is safe to remove from cluster n1,n2,n3,n4.
    CALL spock.validate_node_removal_prerequisites(target_node_name, target_node_dsn, verbose_mode);

    -- Phase 2: Gather cluster information.
    -- Collect all relevant cluster metadata and dependencies for n4.
    -- Example: Gather info about n4's subscriptions, slots, and sets in n1,n2,n3,n4.
    CALL spock.gather_cluster_info_for_removal(target_node_name, verbose_mode);

    -- Phase 3: Remove subscriptions (before removing replication sets).
    -- Note that this will also remove slots on the provider and the node
    -- and node interface info if no other subscription relies on it.
    -- Unsubscribe n4 from all providers and remove its own subscriptions.
    -- Example: Remove all subscriptions to and from n4 in n1,n2,n3,n4.
    CALL spock.remove_node_subscriptions(target_node_name, verbose_mode);

    -- Phase 4: Remove replication sets.
    -- Drop replication sets associated with n4 to prevent further data flow.
    -- Example: Remove n4's replication sets from cluster n1,n2,n3,n4.
    CALL spock.remove_node_replication_sets(target_node_dsn, verbose_mode);

    -- Phase 5: Remove node from cluster registry.
    -- Delete n4 from the Spock node registry so it is no longer part of the cluster.
    -- Example: Remove n4 from the node list in n1,n2,n3,n4.
    CALL spock.remove_node_from_cluster_registry(target_node_name, verbose_mode);

    -- Phase 6: Final cleanup and status report.
    -- Summarize the removal process and report any errors or issues.
    -- Example: Show summary of n4 removal from cluster n1,n2,n3,n4.
    CALL spock.finalize_node_removal(target_node_name, verbose_mode);

END;
$$ LANGUAGE plpgsql;
