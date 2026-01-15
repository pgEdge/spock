-- ============================================================
-- STEP 1: CREATE TABLE on port 5451 and INSERT 10 rows
-- ============================================================
-- Run: psql -p 5451 -d pgedge -f step1.sql

CREATE TABLE IF NOT EXISTS test_origin_update (
    id SERIAL PRIMARY KEY,
    data TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO test_origin_update (data)
SELECT 'row_' || generate_series(1, 10);

-- ============================================================
-- STEP 2: Verify on n3 (port 5453)
-- ============================================================
-- Run: psql -p 5453 -d pgedge -f step2.sql

SELECT COUNT(*) as row_count FROM test_origin_update;
SELECT id, data, xmin FROM test_origin_update ORDER BY id;

-- ============================================================
-- STEP 3: Get the origin node
-- ============================================================
-- Run: psql -p 5453 -d pgedge -f step3.sql

SELECT 
    id, 
    data, 
    xmin,
    (spock.xact_commit_timestamp_origin(xmin)).roident as origin_id,
    spock.update_xact_origin_node(xmin, 'LOCAL'::name) as origin_node
FROM test_origin_update 
ORDER BY id;

-- ============================================================
-- STEP 4: Update the origin node mapping (n1 -> n2)
-- ============================================================
-- Run: psql -p 5453 -d pgedge -f step4.sql
-- Note: Swaps node names to work around unique constraint

UPDATE spock.node SET node_name = 'n2_temp' WHERE node_id = 26863;
UPDATE spock.node SET node_name = 'n2' WHERE node_id = 49708;
UPDATE spock.node SET node_name = 'n1' WHERE node_id = 26863;

-- ============================================================
-- STEP 5: Get the origin node again (should now show n2)
-- ============================================================
-- Run: psql -p 5453 -d pgedge -f step5.sql

SELECT 
    id, 
    data, 
    xmin,
    (spock.xact_commit_timestamp_origin(xmin)).roident as origin_id,
    spock.update_xact_origin_node(xmin, 'LOCAL'::name) as origin_node
FROM test_origin_update 
ORDER BY id;






