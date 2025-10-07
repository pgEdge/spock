/* First test whether a table's replication set can be properly manipulated */

SELECT * FROM spock_regress_variables()
\gset

--
-- Test resynchronization
--

\c :provider_dsn
SELECT spock.replicate_ddl('CREATE TABLE test_sync(x integer primary key)');
SELECT * FROM spock.repset_add_table('default', 'test_sync');
INSERT INTO test_sync (x) SELECT value FROM generate_series(1,10) AS value;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
SELECT sum(x), count(*) FROM test_sync;

\c :subscriber_dsn
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
SELECT sum(x), count(*) FROM test_sync;
SELECT * FROM spock.local_sync_status;

SELECT spock.sub_resync_table('test_subscription', 'test_sync', true);
SELECT spock.table_wait_for_sync('test_subscription', 'test_sync');
SELECT sum(x), count(*) FROM test_sync;
SELECT * FROM spock.local_sync_status;

SELECT spock.sub_resync_table('test_subscription', 'test_sync', true);
SELECT spock.table_wait_for_sync('test_subscription', 'test_sync');
SELECT sum(x), count(*) FROM test_sync;
SELECT * FROM spock.local_sync_status;

\c :provider_dsn
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
SELECT sum(x), count(*) FROM test_sync;

-- Add more values and check they were added
INSERT INTO test_sync (x) SELECT -value FROM generate_series(1,10) AS value;
SELECT sum(x), count(*) FROM test_sync;

\c :subscriber_dsn
-- Restart syncing this specific table, wait until the process finish and check
-- all the data stay consistent
SELECT * FROM spock.local_sync_status;
SELECT spock.sub_resync_table('test_subscription', 'test_sync', true);
SELECT spock.table_wait_for_sync('test_subscription', 'test_sync');
SELECT sum(x), count(*) FROM test_sync;
SELECT * FROM spock.local_sync_status;

-- Last check all data still in place
\c :provider_dsn
SELECT sum(x), count(*) FROM test_sync;

-- Cleanup
SELECT spock.repset_remove_table('default', 'test_sync', true);
DROP TABLE test_sync;
