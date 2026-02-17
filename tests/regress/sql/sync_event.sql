-- Test sync_event() and wait_for_sync_event() procedures
SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn

-- Create a test table on provider
CREATE TABLE sync_test (id int primary key, data text);
SELECT * FROM spock.repset_add_table('default', 'sync_test');

\c :subscriber_dsn

-- Create the same table on subscriber (structure sync)
CREATE TABLE sync_test (id int primary key, data text);

\c :provider_dsn

-- Insert some data
INSERT INTO sync_test VALUES (1, 'first'), (2, 'second');

-- Test 1: Basic sync_event() returns a valid LSN
SELECT spock.sync_event() IS NOT NULL AS sync_event_returns_lsn;

-- Capture the sync event LSN for later tests
SELECT spock.sync_event() as sync_lsn
\gset

\c :subscriber_dsn

-- Test 2: wait_for_sync_event with node name (should succeed)
-- Note: First arg is OUT parameter, use placeholder value
CALL spock.wait_for_sync_event(NULL, 'test_provider', :'sync_lsn', 30);

-- Verify data arrived
SELECT * FROM sync_test ORDER BY id;

\c :provider_dsn

-- Insert more data
INSERT INTO sync_test VALUES (3, 'third');

-- Create another sync event
SELECT spock.sync_event() as sync_lsn2
\gset

-- Get provider node_id for testing with OID
SELECT node_id as provider_node_id FROM spock.node WHERE node_name = 'test_provider'
\gset

\c :subscriber_dsn

-- Test 3: wait_for_sync_event with node OID (should succeed)
CALL spock.wait_for_sync_event(NULL, :provider_node_id, :'sync_lsn2', 30);

-- Verify new data arrived
SELECT * FROM sync_test ORDER BY id;

-- Test 4: wait_for_sync_event with timeout (should return false for future LSN)
-- Use a very high LSN that won't be reached
CALL spock.wait_for_sync_event(NULL, 'test_provider', 'FFFFFFFF/FFFFFFFF', 2);

-- Test 5: wait_for_sync_event with non-existent node name (should error)
\set ON_ERROR_STOP 0
CALL spock.wait_for_sync_event(NULL, 'nonexistent_node', '0/0', 1);
\set ON_ERROR_STOP 1

-- Test 6: wait_for_sync_event with NULL origin_id (should error)
\set ON_ERROR_STOP 0
CALL spock.wait_for_sync_event(NULL, NULL::oid, '0/0', 1);
\set ON_ERROR_STOP 1

-- Cleanup
\c :provider_dsn
SELECT * FROM spock.repset_remove_table('default', 'sync_test');
DROP TABLE sync_test;
\c :subscriber_dsn
DROP TABLE sync_test;
\c :provider_dsn
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
