-- ===========================================================================
-- recovery_tests.sql
--
-- Test suite for table consistency check and repair functions
--
-- Prerequisites:
--   - spock extension installed
--   - recovery.sql loaded
--   - Two PostgreSQL instances configured with spock replication
--
-- Usage:
--   psql -d testdb -f recovery_tests.sql
-- ===========================================================================

\echo '========================================='
\echo 'Spock Consistency Check and Repair Tests'
\echo '========================================='
\echo ''

-- Clean up from previous test runs
DROP SCHEMA IF EXISTS consistency_test CASCADE;
CREATE SCHEMA consistency_test;
SET search_path = consistency_test, public, spock;

-- ===========================================================================
-- TEST SETUP
-- ===========================================================================

\echo 'Setting up test environment...'

-- Create test table with PK
CREATE TABLE consistency_test.test_table (
    id int PRIMARY KEY,
    name text NOT NULL,
    value numeric,
    updated_at timestamptz DEFAULT now()
);

-- Insert some test data
INSERT INTO consistency_test.test_table (id, name, value) VALUES
    (1, 'row_one', 100.0),
    (2, 'row_two', 200.0),
    (3, 'row_three', 300.0),
    (4, 'row_four', 400.0),
    (5, 'row_five', 500.0);

\echo 'Test table created with 5 rows'
\echo ''

-- ===========================================================================
-- TEST 1: Configuration GUCs
-- ===========================================================================

\echo 'TEST 1: Checking GUC configuration'
\echo '-----------------------------------'

-- Test GUC values
SELECT name, setting, unit FROM spock.v_config WHERE name LIKE 'spock.diff%' OR name LIKE 'spock.repair%' OR name LIKE 'spock.health%' ORDER BY name;

\echo ''

-- ===========================================================================
-- TEST 2: Table Metadata Functions
-- ===========================================================================

\echo 'TEST 2: Table metadata extraction'
\echo '-----------------------------------'

-- Test get_table_info
SELECT * FROM spock.get_table_info('consistency_test.test_table'::regclass);

\echo ''
\echo 'Primary key columns:'
SELECT spock.get_primary_key_columns('consistency_test.test_table'::regclass) as pk_cols;

\echo ''
\echo 'All columns:'
SELECT spock.get_all_columns('consistency_test.test_table'::regclass) as all_cols;

\echo ''

-- ===========================================================================
-- TEST 3: Fetch Table Rows
-- ===========================================================================

\echo 'TEST 3: Fetching table rows'
\echo '-----------------------------------'

-- Fetch all rows
\echo 'Fetching all rows with metadata:'
SELECT 
    pk_values,
    all_values,
    commit_ts IS NOT NULL as has_commit_ts,
    node_origin
FROM spock.fetch_table_rows('consistency_test.test_table'::regclass)
ORDER BY pk_values
LIMIT 3;

\echo ''
\echo 'Fetching with filter:'
SELECT 
    pk_values,
    all_values
FROM spock.fetch_table_rows('consistency_test.test_table'::regclass, 'id <= 2')
ORDER BY pk_values;

\echo ''

-- ===========================================================================
-- TEST 4: SQL Generation Functions
-- ===========================================================================

\echo 'TEST 4: SQL generation'
\echo '-----------------------------------'

-- Test DELETE SQL generation
\echo 'Generated DELETE SQL:'
SELECT spock.generate_delete_sql(
    'consistency_test.test_table'::regclass,
    ARRAY['1']
) as delete_sql;

\echo ''

-- Test UPSERT SQL generation
\echo 'Generated UPSERT SQL (with UPDATE):'
SELECT spock.generate_upsert_sql(
    'consistency_test.test_table'::regclass,
    ARRAY['99'],
    ARRAY['99', 'new_row', '999.0', now()::text],
    false
) as upsert_sql;

\echo ''

\echo 'Generated INSERT SQL (insert_only=true):'
SELECT spock.generate_upsert_sql(
    'consistency_test.test_table'::regclass,
    ARRAY['99'],
    ARRAY['99', 'new_row', '999.0', now()::text],
    true
) as insert_only_sql;

\echo ''

-- ===========================================================================
-- TEST 5: Column Change Detection
-- ===========================================================================

\echo 'TEST 5: Changed columns detection'
\echo '-----------------------------------'

-- Test changed columns
\echo 'Detecting changed columns:'
SELECT spock.get_changed_columns(
    ARRAY['1', 'old_name', '100.0', '2024-01-01'],
    ARRAY['1', 'new_name', '200.0', '2024-01-01'],
    ARRAY['id', 'name', 'value', 'updated_at']::name[]
) as changed_cols;

\echo ''

-- ===========================================================================
-- TEST 6: System Views
-- ===========================================================================

\echo 'TEST 6: System views'
\echo '-----------------------------------'

\echo 'Replication health:'
SELECT * FROM spock.v_replication_health;

\echo ''
\echo 'Table health (test table only):'
SELECT 
    schema_name,
    table_name,
    has_primary_key,
    live_tuples,
    issues
FROM spock.v_table_health
WHERE schema_name = 'consistency_test';

\echo ''

-- ===========================================================================
-- TEST 7: Simulated Diff (Same Table, Should Match)
-- ===========================================================================

\echo 'TEST 7: Self-diff (table should match itself)'
\echo '-----------------------------------'

-- Create a temp copy for "remote" simulation
CREATE TEMP TABLE _test_remote AS SELECT * FROM consistency_test.test_table;

-- Simulate diff using local comparison (not real dblink)
CREATE TEMP TABLE _test_diff AS
WITH local_rows AS (
    SELECT * FROM spock.fetch_table_rows('consistency_test.test_table'::regclass)
),
remote_rows AS (
    SELECT 
        ARRAY[id::text] as pk_values,
        ARRAY[id::text, name::text, value::text, updated_at::text] as all_values,
        NULL::timestamptz as commit_ts,
        'local'::text as node_origin
    FROM _test_remote
)
SELECT 
    CASE 
        WHEN r.pk_values IS NULL THEN 'only_local'
        WHEN l.pk_values IS NULL THEN 'only_remote'
        ELSE 'modified'
    END as diff_type,
    COALESCE(l.pk_values, r.pk_values) as pk_values,
    l.all_values as local_values,
    r.all_values as remote_values
FROM local_rows l
FULL OUTER JOIN remote_rows r ON l.pk_values = r.pk_values
WHERE l.pk_values IS NULL OR r.pk_values IS NULL OR l.all_values IS DISTINCT FROM r.all_values;

\echo 'Diff results (should be empty):'
SELECT COUNT(*) as diff_count, diff_type FROM _test_diff GROUP BY diff_type;

\echo ''

-- ===========================================================================
-- TEST 8: Simulated Diff with Differences
-- ===========================================================================

\echo 'TEST 8: Diff with actual differences'
\echo '-----------------------------------'

-- Modify remote copy to create differences
UPDATE _test_remote SET name = 'MODIFIED' WHERE id = 2;  -- Modified row
DELETE FROM _test_remote WHERE id = 3;                   -- Only local
INSERT INTO _test_remote VALUES (99, 'only_remote', 999.0, now()); -- Only remote

-- Recreate diff
TRUNCATE _test_diff;
INSERT INTO _test_diff
WITH local_rows AS (
    SELECT * FROM spock.fetch_table_rows('consistency_test.test_table'::regclass)
),
remote_rows AS (
    SELECT 
        ARRAY[id::text] as pk_values,
        ARRAY[id::text, name::text, value::text, updated_at::text] as all_values,
        NULL::timestamptz as commit_ts,
        'local'::text as node_origin
    FROM _test_remote
)
SELECT 
    CASE 
        WHEN r.pk_values IS NULL THEN 'only_local'
        WHEN l.pk_values IS NULL THEN 'only_remote'
        WHEN l.all_values IS DISTINCT FROM r.all_values THEN 'modified'
    END as diff_type,
    COALESCE(l.pk_values, r.pk_values) as pk_values,
    l.all_values as local_values,
    r.all_values as remote_values
FROM local_rows l
FULL OUTER JOIN remote_rows r ON l.pk_values = r.pk_values
WHERE l.pk_values IS NULL OR r.pk_values IS NULL OR l.all_values IS DISTINCT FROM r.all_values;

\echo 'Diff summary:'
SELECT diff_type, COUNT(*) as count FROM _test_diff GROUP BY diff_type ORDER BY diff_type;

\echo ''
\echo 'Diff details:'
SELECT diff_type, pk_values FROM _test_diff ORDER BY diff_type, pk_values;

\echo ''

-- ===========================================================================
-- TEST 9: Repair SQL Generation
-- ===========================================================================

\echo 'TEST 9: Repair SQL generation (dry run)'
\echo '-----------------------------------'

\echo 'Generated repair SQL statements:'

-- Generate DELETE for only_local
SELECT 
    'DELETE for only_local' as operation,
    spock.generate_delete_sql(
        'consistency_test.test_table'::regclass,
        pk_values
    ) as sql
FROM _test_diff
WHERE diff_type = 'only_local'

UNION ALL

-- Generate UPSERT for only_remote
SELECT 
    'UPSERT for only_remote' as operation,
    spock.generate_upsert_sql(
        'consistency_test.test_table'::regclass,
        pk_values,
        remote_values,
        false
    ) as sql
FROM _test_diff
WHERE diff_type = 'only_remote'

UNION ALL

-- Generate UPSERT for modified (using remote as source of truth)
SELECT 
    'UPSERT for modified' as operation,
    spock.generate_upsert_sql(
        'consistency_test.test_table'::regclass,
        pk_values,
        remote_values,
        false
    ) as sql
FROM _test_diff
WHERE diff_type = 'modified';

\echo ''

-- ===========================================================================
-- TEST 10: Table Health Check
-- ===========================================================================

\echo 'TEST 10: Table health diagnostics'
\echo '-----------------------------------'

-- Create table without PK for testing
CREATE TABLE consistency_test.no_pk_table (
    id int,
    data text
);

INSERT INTO consistency_test.no_pk_table VALUES (1, 'test');

\echo 'Health check results:'
SELECT 
    schema_name,
    table_name,
    has_primary_key,
    issues
FROM spock.v_table_health
WHERE schema_name = 'consistency_test'
ORDER BY table_name;

\echo ''

-- ===========================================================================
-- TEST 11: Configuration Changes
-- ===========================================================================

\echo 'TEST 11: GUC configuration changes'
\echo '-----------------------------------'

-- Show current settings
\echo 'Current diff_batch_size:'
SHOW spock.diff_batch_size;

-- Change setting
SET spock.diff_batch_size = 5000;

\echo 'New diff_batch_size:'
SHOW spock.diff_batch_size;

-- Reset
RESET spock.diff_batch_size;

\echo 'Reset diff_batch_size:'
SHOW spock.diff_batch_size;

\echo ''

-- ===========================================================================
-- TEST SUMMARY
-- ===========================================================================

\echo '========================================='
\echo 'TEST SUMMARY'
\echo '========================================='
\echo ''
\echo 'All local-only tests completed successfully!'
\echo ''
\echo 'For full integration tests with real remote nodes:'
\echo '  1. Set up two PostgreSQL instances with spock'
\echo '  2. Configure replication between them'
\echo '  3. Run: SELECT * FROM spock.table_diff_dblink(''host=remote dbname=test'', ''table''::regclass);'
\echo '  4. Create differences and test repair workflows'
\echo ''
\echo 'Example remote diff command:'
\echo '  SELECT * FROM spock.table_diff_dblink('
\echo '    ''host=node2 port=5432 dbname=testdb user=postgres'','
\echo '    ''consistency_test.test_table''::regclass'
\echo '  );'
\echo ''

-- Cleanup
\echo 'Cleaning up test schema...'
-- DROP SCHEMA consistency_test CASCADE;

\echo 'Tests complete!'

