-- Test: conflict statistics for UPDATE_MISSING conflicts (PG18+ only)
SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn

-- Create a simple table for conflict testing
SELECT spock.replicate_ddl($$
	CREATE TABLE public.conflict_stat_test (
		id integer PRIMARY KEY,
		data text
	);
$$);

SELECT * FROM spock.repset_add_table('default', 'conflict_stat_test');

-- Seed initial rows
INSERT INTO conflict_stat_test VALUES (1, 'row1');
INSERT INTO conflict_stat_test VALUES (2, 'row2');
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

-- Get subscription OID for stats queries
SELECT sub_id AS test_sub_id FROM spock.subscription
	WHERE sub_name = 'test_subscription' \gset

-- Reset conflict stats before the test
SELECT spock.reset_subscription_stats(:test_sub_id);

-- Verify counters are zero initially
SELECT confl_update_missing,
  confl_insert_exists,confl_update_origin_differs,confl_update_exists,
  confl_delete_origin_differs,confl_delete_missing
FROM spock.get_subscription_stats(:test_sub_id);

-- Delete a row on subscriber only to set up UPDATE_MISSING
DELETE FROM conflict_stat_test WHERE id = 1;
TRUNCATE spock.exception_log;

\c :provider_dsn

-- Update the row that no longer exists on subscriber
UPDATE conflict_stat_test SET data = 'updated_row1' WHERE id = 1;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

-- Row id=1 should still be missing on subscriber (update was skipped)
SELECT * FROM conflict_stat_test ORDER BY id;

-- The UPDATE_MISSING conflict should be logged in exception_log
SELECT operation, table_name FROM spock.exception_log;

-- Verify that the UPDATE_MISSING conflict was counted
SELECT confl_update_missing,
  confl_insert_exists,confl_update_origin_differs,confl_update_exists,
  confl_delete_origin_differs,confl_delete_missing
FROM spock.get_subscription_stats(:test_sub_id);

-- Provoke a second UPDATE_MISSING to confirm counter increments
DELETE FROM conflict_stat_test WHERE id = 2;
TRUNCATE spock.exception_log;

\c :provider_dsn

UPDATE conflict_stat_test SET data = 'updated_row2' WHERE id = 2;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

SELECT * FROM conflict_stat_test ORDER BY id;

-- Counter should now be 2
SELECT confl_update_missing,
  confl_insert_exists,confl_update_origin_differs,confl_update_exists,
  confl_delete_origin_differs,confl_delete_missing
FROM spock.get_subscription_stats(:test_sub_id);

-- Test reset: clear the stats and verify counter goes back to zero
SELECT spock.reset_subscription_stats(:test_sub_id);

SELECT confl_update_missing,
  confl_insert_exists,confl_update_origin_differs,confl_update_exists,
  confl_delete_origin_differs,confl_delete_missing
FROM spock.get_subscription_stats(:test_sub_id);

-- Cleanup
TRUNCATE spock.exception_log;
\c :provider_dsn
SELECT spock.replicate_ddl($$ DROP TABLE public.conflict_stat_test CASCADE; $$);
