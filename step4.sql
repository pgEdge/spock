-- STEP 4: Update the origin_id of transactions from n1 to n3
-- Run: psql -p 5453 -d pgedge -f step4.sql
-- Note: Changes transaction origin_id in commit timestamps from n1's node_id to n3's node_id
--       Does NOT change node names in spock.node table
--
-- IMPORTANT: PostgreSQL's commit timestamp data is stored in shared memory and cannot be
--            directly updated via SQL. This script uses a workaround by updating the replication
--            origin mapping. For a complete solution, a C function would be needed to update
--            the actual commit timestamp data.

DO $$
DECLARE
    n1_node_id oid;
    n3_node_id oid;
    n1_roident oid;
    n3_roident oid;
    xid_val xid;
    origin_rec RECORD;
    updated_count int := 0;
BEGIN
    -- Get node IDs for n1 and n3 (these are used as roident in Spock)
    SELECT node_id INTO n1_node_id FROM spock.node WHERE node_name = 'n1';
    SELECT node_id INTO n3_node_id FROM spock.node WHERE node_name = 'n3';
    
    IF n1_node_id IS NULL THEN
        RAISE EXCEPTION 'Node n1 not found in spock.node';
    END IF;
    
    IF n3_node_id IS NULL THEN
        RAISE EXCEPTION 'Node n3 not found in spock.node';
    END IF;
    
    RAISE NOTICE 'n1 node_id (roident): %, n3 node_id (roident): %', n1_node_id, n3_node_id;
    
    -- In Spock, the origin_id in commit timestamps is the node_id (roident)
    -- We need to update all transactions that have origin_id = n1_node_id to n3_node_id
    -- However, PostgreSQL doesn't provide a direct SQL interface to update commit timestamps
    
    -- Workaround: Update replication origin status to reflect the change
    -- This updates the replication origin tracking, but NOT the actual commit timestamp data
    
    -- Find replication origins for n1
    FOR origin_rec IN
        SELECT ro.roident, ro.roname
        FROM pg_catalog.pg_replication_origin ro
        WHERE ro.roname LIKE format('spk_%%_n1_%%')
           OR ro.roname LIKE format('spk_%%_%s_%%', n1_node_id::text)
    LOOP
        n1_roident := origin_rec.roident;
        RAISE NOTICE 'Found n1 replication origin: roident=%, name=%', n1_roident, origin_rec.roname;
        
        -- Update replication origin name to reflect n3 instead of n1
        -- Note: This is a workaround - the actual commit timestamp origin_id in shared memory
        --       would need to be updated via a C function
        UPDATE pg_catalog.pg_replication_origin
        SET roname = replace(roname, '_n1_', '_n3_')
        WHERE roident = n1_roident
          AND roname LIKE '%_n1_%';
        
        GET DIAGNOSTICS updated_count = ROW_COUNT;
        IF updated_count > 0 THEN
            RAISE NOTICE 'Updated replication origin name for roident % (workaround)', n1_roident;
        END IF;
    END LOOP;
    
    -- Note: The actual commit timestamp data (pg_xact_commit_timestamp) stores origin_id
    --       which points to the roident. To truly change transactions from n1 to n3,
    --       we would need to update all commit timestamp entries where origin_id = n1_node_id
    --       to origin_id = n3_node_id. This requires a C function as PostgreSQL doesn't
    --       provide SQL access to modify commit timestamp data.
    
    RAISE NOTICE '';
    RAISE NOTICE 'WARNING: This script updates replication origin names as a workaround.';
    RAISE NOTICE 'The actual commit timestamp origin_id values in shared memory are NOT changed.';
    RAISE NOTICE 'To fully update transaction origins, a C function is required to modify';
    RAISE NOTICE 'pg_xact_commit_timestamp data directly.';
    RAISE NOTICE '';
    RAISE NOTICE 'For transactions to show n3 instead of n1, the commit timestamp origin_id';
    RAISE NOTICE 'must be changed from % (n1) to % (n3) in the commit timestamp data.', n1_node_id, n3_node_id;
END;
$$;

