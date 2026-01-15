-- STEP 1: CREATE TABLE on port 5451 and INSERT 10 rows
-- Run: psql -p 5451 -d pgedge -f step1.sql

CREATE TABLE IF NOT EXISTS test_origin_update (
    id SERIAL PRIMARY KEY,
    data TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO test_origin_update (data)
SELECT 'row_' || generate_series(1, 10);






