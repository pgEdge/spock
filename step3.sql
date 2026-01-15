-- STEP 3: Get the origin node
-- Run: psql -p 5453 -d pgedge -f step3.sql

SELECT 
    id, 
    data, 
    xmin,
    (spock.xact_commit_timestamp_origin(xmin)).roident as origin_id,
    spock.update_xact_origin_node(xmin, 'LOCAL'::name) as origin_node
FROM test_origin_update 
ORDER BY id;






