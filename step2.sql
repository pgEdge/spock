-- STEP 2: Verify on n3 (port 5453)
-- Run: psql -p 5453 -d pgedge -f step2.sql

SELECT COUNT(*) as row_count FROM test_origin_update;
SELECT id, data, xmin FROM test_origin_update ORDER BY id;






