-- ============================================================================
-- ZODAN Cleanup Script
-- Purpose: Drops everything created by zodan.sql
-- 
-- Note: Updated to match the corrected zodan.sql file with proper phase numbering
-- and all duplicate definitions removed.
-- ============================================================================

-- Drop all procedures and functions created by zodan.sql
DROP PROCEDURE IF EXISTS get_spock_nodes(text, boolean);
DROP PROCEDURE IF EXISTS create_sub(text, text, text, text, boolean, boolean, text, interval, boolean, boolean, boolean);
DROP PROCEDURE IF EXISTS create_replication_slot(text, text, boolean, text);
DROP PROCEDURE IF EXISTS sync_event(text, boolean, pg_lsn);
DROP PROCEDURE IF EXISTS create_node(text, text, boolean, text, text, jsonb);
DROP PROCEDURE IF EXISTS get_commit_timestamp(text, text, text, boolean, timestamp);
DROP PROCEDURE IF EXISTS advance_replication_slot(text, text, timestamp, boolean);
DROP PROCEDURE IF EXISTS enable_sub(text, text, boolean, boolean);
DROP PROCEDURE IF EXISTS monitor_replication_lag(text, boolean);
DROP PROCEDURE IF EXISTS monitor_replication_lag(text, text, text, boolean);
DROP PROCEDURE IF EXISTS monitor_replication_lag_wait(text, text, integer, integer, boolean);
DROP PROCEDURE IF EXISTS monitor_multiple_replication_lags(jsonb, integer, integer, boolean);
DROP PROCEDURE IF EXISTS wait_for_n3_sync(integer, integer, boolean);
DROP PROCEDURE IF EXISTS monitor_lag_with_dblink(text, text, text, boolean);
DROP PROCEDURE IF EXISTS verify_node_prerequisites(text, text, text, text, boolean);
DROP PROCEDURE IF EXISTS create_nodes_only(text, text, text, text, boolean, text, text, jsonb, integer);
DROP PROCEDURE IF EXISTS create_replication_slots(text, text, text, text, boolean);
DROP PROCEDURE IF EXISTS create_disable_subscriptions_and_slots(text, text, text, text, boolean);
DROP PROCEDURE IF EXISTS enable_disabled_subscriptions(text, text, text, text, boolean);
DROP PROCEDURE IF EXISTS create_sub_on_new_node_to_src_node(text, text, text, text, boolean);
DROP PROCEDURE IF EXISTS create_new_to_source_subscription(text, text, text, text, boolean);
DROP PROCEDURE IF EXISTS create_source_to_new_subscription(text, text, text, text, boolean);
DROP PROCEDURE IF EXISTS trigger_sync_on_other_nodes_and_wait_on_source(text, text, text, text, boolean);
DROP PROCEDURE IF EXISTS check_commit_timestamp_and_advance_slot(text, text, text, text, boolean);
DROP PROCEDURE IF EXISTS check_node_lag(text, text, boolean, interval);
DROP PROCEDURE IF EXISTS trigger_sync_and_wait(text, text, text, text, boolean);
DROP PROCEDURE IF EXISTS present_final_cluster_state(integer, boolean);
DROP PROCEDURE IF EXISTS add_node(text, text, text, text, boolean, text, text, jsonb);

-- Drop temporary table if it exists
DROP TABLE IF EXISTS temp_spock_nodes;

-- Clean up any remaining temporary objects
DO $$
BEGIN
    -- Drop any remaining temporary tables that might have been created
    DROP TABLE IF EXISTS temp_spock_nodes CASCADE;
    
    -- Clean up any temporary schemas or objects
    -- (This is a safety measure in case any temporary objects were created)
    
    RAISE NOTICE 'ZODAN cleanup completed successfully';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Cleanup completed with warnings: %', SQLERRM;
END;
$$;
