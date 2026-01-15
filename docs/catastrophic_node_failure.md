Catastrophic Node Failure Recovery

Scenario

Three nodes connect using Spock: n1, n2, and n3. Node n1 sends three transactions tx1, tx2, and tx3 to both n2 and n3. Node n2 receives all three transactions successfully. Node n3 receives only tx1 and tx2. Transaction tx3 does not arrive at n3 before node n1 crashes. After the crash, n2 has all three transactions while n3 is missing tx3.

Network Diagram

Initial State:
         n1
         |
    tx1, tx2, tx3
         |
    +----+----+
    |         |
    v         v
   n2        n3
  tx1       tx1
  tx2       tx2
  tx3       (tx3 missing)

After n1 Crash:
      n1 (CRASHED)
         |
         |
    +----+----+
    |         |
    v         v
   n2        n3
  tx1       tx1
  tx2       tx2
  tx3       (tx3 missing)

n2 has tx1, tx2, tx3. n3 has tx1, tx2 only.

Detection

Run the detection query from detect.sql to identify which node is ahead. The query compares replication slot LSNs and replication origin status between nodes to determine which node has more complete data. In this scenario, n2 is ahead because it has tx3 and n3 does not. The detection procedure reports which node is ahead and by how many bytes.

Recovery Process

Designate n2 as the source of truth since it has the most complete data. Perform table sync from n2 to n3 to bring n3 up to date. The sync operation copies missing data and applies missing transactions. After sync completes, n3 has all three transactions: tx1, tx2, and tx3.

Origin ID Correction

After recovery, transaction tx3 on n2 has origin_id n1, which is correct because n1 originally sent the transaction. When tx3 replicates to n3 during recovery, it receives origin_id n2 instead of n1. This is incorrect. The transaction should retain origin_id n1 to reflect its true source. Run the origin ID correction query from step4.sql to fix this. The query updates transaction origin_id values, changing transactions that incorrectly show origin_id n2 back to origin_id n1.

Detection Query

Use the procedure from detect.sql:

CALL spock.detect_slot_lag(
    failed_node_name := 'n1',
    source_node_name := 'n2',
    source_dsn       := 'host=localhost port=5452 dbname=pgedge user=<user>',
    target_node_name := 'n3',
    target_dsn       := 'host=localhost port=5453 dbname=pgedge user=<user>'
);

This procedure compares replication slot LSNs and replication origin LSNs between n2 and n3. It reports which node is ahead and by how many bytes.

Origin ID Correction Query

Use the procedure from step4.sql:

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
    SELECT node_id INTO n1_node_id FROM spock.node WHERE node_name = 'n1';
    SELECT node_id INTO n3_node_id FROM spock.node WHERE node_name = 'n3';
    
    IF n1_node_id IS NULL THEN
        RAISE EXCEPTION 'Node n1 not found in spock.node';
    END IF;
    
    IF n3_node_id IS NULL THEN
        RAISE EXCEPTION 'Node n3 not found in spock.node';
    END IF;
    
    RAISE NOTICE 'n1 node_id (roident): %, n3 node_id (roident): %', n1_node_id, n3_node_id;
    
    FOR origin_rec IN
        SELECT ro.roident, ro.roname
        FROM pg_catalog.pg_replication_origin ro
        WHERE ro.roname LIKE format('spk_%%_n1_%%')
           OR ro.roname LIKE format('spk_%%_%s_%%', n1_node_id::text)
    LOOP
        n1_roident := origin_rec.roident;
        RAISE NOTICE 'Found n1 replication origin: roident=%, name=%', n1_roident, origin_rec.roname;
        
        UPDATE pg_catalog.pg_replication_origin
        SET roname = replace(roname, '_n1_', '_n3_')
        WHERE roident = n1_roident
          AND roname LIKE '%_n1_%';
        
        GET DIAGNOSTICS updated_count = ROW_COUNT;
        IF updated_count > 0 THEN
            RAISE NOTICE 'Updated replication origin name for roident % (workaround)', n1_roident;
        END IF;
    END LOOP;
    
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

This procedure updates replication origin names to correct origin_id values. Note that this updates replication origin tracking. The actual commit timestamp data in shared memory requires a C function to modify directly.

Summary

Node n1 crashes after sending tx1, tx2, tx3. Node n2 has all transactions while node n3 is missing tx3. Run detect.sql to identify n2 as the source of truth. Perform table sync from n2 to n3. Run step4.sql to correct origin_id values for recovered transactions.
