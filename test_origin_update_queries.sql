-- ============================================================
-- Step 1: CREATE TABLE on port 5451 and INSERT 10 rows
-- ============================================================
-- Run on port 5451
CREATE TABLE IF NOT EXISTS test_origin_update (
    id SERIAL PRIMARY KEY,
    data TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO test_origin_update (data)
SELECT 'row_' || generate_series(1, 10);

-- ============================================================
-- Step 2: Verify on n3 (port 5453)
-- ============================================================
-- Run on port 5453
SELECT COUNT(*) as row_count FROM test_origin_update;
SELECT id, data, xmin FROM test_origin_update ORDER BY id;

-- ============================================================
-- Step 3: Get the origin node
-- ============================================================
-- Run on port 5453
SELECT 
    id, 
    data, 
    xmin,
    (spock.xact_commit_timestamp_origin(xmin)).roident as origin_id,
    spock.update_xact_origin_node(xmin, 'LOCAL'::name) as origin_node
FROM test_origin_update 
ORDER BY id;

-- ============================================================
-- Step 4: Update the origin node mapping
-- Note: Since node_name has a unique constraint, we need to
-- swap the names temporarily or update node_id 49708 to point to n2
-- Option A: Swap n1 and n2 names (temporary)
-- ============================================================
-- Run on port 5453 (or any node)
-- First, update n2 to a temporary name
UPDATE spock.node SET node_name = 'n2_temp' WHERE node_id = 26863;
-- Then update n1 (49708) to n2
UPDATE spock.node SET node_name = 'n2' WHERE node_id = 49708;
-- Then update the temp name back to n1
UPDATE spock.node SET node_name = 'n1' WHERE node_id = 26863;

-- ============================================================
-- Step 5: Get the origin node again (should now show n2)
-- ============================================================
-- Run on port 5453
SELECT 
    id, 
    data, 
    xmin,
    (spock.xact_commit_timestamp_origin(xmin)).roident as origin_id,
    spock.update_xact_origin_node(xmin, 'LOCAL'::name) as origin_node
FROM test_origin_update 
ORDER BY id;

-- ============================================================
-- Optional: Restore original mapping
-- ============================================================
-- UPDATE spock.node SET node_name = 'n1' WHERE node_id = 49708;
-- UPDATE spock.node SET node_name = 'n2' WHERE node_id = 26863;
