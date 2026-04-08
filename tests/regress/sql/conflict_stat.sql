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
  confl_delete_origin_differs,confl_delete_missing,confl_delete_exists
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
  confl_delete_origin_differs,confl_delete_missing,confl_delete_exists
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
  confl_delete_origin_differs,confl_delete_missing,confl_delete_exists
FROM spock.get_subscription_stats(:test_sub_id);

-- Test reset: clear the stats and verify counter goes back to zero
SELECT spock.reset_subscription_stats(:test_sub_id);

-- ============================================================
-- Test INSERT_EXISTS: insert a row on subscriber, then insert the same key on
-- provider.  The apply worker detects the duplicate and resolves the conflict
-- (last_update_wins converts the insert into an update).
-- ============================================================

-- Re-seed rows so both sides have data again
\c :provider_dsn
INSERT INTO conflict_stat_test VALUES (10, 'provider10');
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

-- Pre-insert a conflicting row on the subscriber
INSERT INTO conflict_stat_test VALUES (20, 'sub-only');
TRUNCATE spock.exception_log;

\c :provider_dsn

-- This INSERT will conflict with the row already on subscriber
INSERT INTO conflict_stat_test VALUES (20, 'from-provider');
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

-- The row should now reflect the resolved value (remote wins)
SELECT * FROM conflict_stat_test WHERE id = 20;

-- Verify INSERT_EXISTS counter incremented
SELECT confl_insert_exists
FROM spock.get_subscription_stats(:test_sub_id);
SELECT spock.reset_subscription_stats(:test_sub_id);

-- ============================================================
-- Test DELETE_MISSING: delete a row on subscriber first, then delete the same
-- row on provider.  The apply worker cannot find the row and reports
-- DELETE_MISSING.
-- ============================================================
TRUNCATE spock.exception_log;

-- Remove the row on subscriber before provider sends its DELETE
DELETE FROM conflict_stat_test WHERE id = 10;

\c :provider_dsn

DELETE FROM conflict_stat_test WHERE id = 10;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

-- Row should still be absent
SELECT * FROM conflict_stat_test WHERE id = 10;

SELECT confl_update_missing,
  confl_insert_exists,confl_update_origin_differs,confl_update_exists,
  confl_delete_origin_differs,confl_delete_missing,confl_delete_exists
FROM spock.get_subscription_stats(:test_sub_id);

SELECT spock.reset_subscription_stats(:test_sub_id);

-- ============================================================
-- Test UPDATE_EXISTS: an UPDATE from the provider violates a secondary
-- unique constraint on the subscriber.  The apply worker detects the
-- unique violation, logs update_exists to the PostgreSQL log, counts
-- it in conflict stats, and records it in exception_log.
-- Default exception_behaviour is TRANSDISCARD: the worker errors on
-- the first attempt, restarts, replays read-only logging each failing
-- row to exception_log, then advances the LSN.
-- ============================================================

\c :provider_dsn

-- Create a table with a secondary unique index
SELECT spock.replicate_ddl($$
	CREATE TABLE public.conflict_ue_test (
		id integer PRIMARY KEY,
		uval integer NOT NULL,
		data text
	);
	CREATE UNIQUE INDEX conflict_ue_test_uval_idx
		ON public.conflict_ue_test (uval);
$$);

SELECT * FROM spock.repset_add_table('default', 'conflict_ue_test');

-- Seed rows on both sides via replication
INSERT INTO conflict_ue_test VALUES (1, 100, 'row1');
INSERT INTO conflict_ue_test VALUES (2, 200, 'row2');
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

-- Insert a row only on the subscriber to set up the conflict
INSERT INTO conflict_ue_test VALUES (3, 300, 'sub_only');
SELECT * FROM conflict_ue_test ORDER BY id;

-- Reset stats
SELECT spock.reset_subscription_stats(:test_sub_id);
TRUNCATE spock.exception_log;

\c :provider_dsn

-- This UPDATE sets uval=300 on row id=2.  It succeeds on the provider
-- (no row with uval=300 here), but on the subscriber row id=3 already
-- has uval=300, so the secondary unique index is violated.
UPDATE conflict_ue_test SET uval = 300, data = 'should_conflict' WHERE id = 2;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

-- Row id=2 should still have its original value (update was discarded)
SELECT * FROM conflict_ue_test ORDER BY id;

-- The conflict should be logged in exception_log
SELECT operation, table_name FROM spock.exception_log;

-- Verify UPDATE_EXISTS counter incremented
SELECT confl_update_exists
FROM spock.get_subscription_stats(:test_sub_id);

SELECT spock.reset_subscription_stats(:test_sub_id);
TRUNCATE spock.exception_log;

-- Cleanup
\c :provider_dsn
SELECT spock.replicate_ddl($$ DROP TABLE public.conflict_ue_test CASCADE; $$);

-- Cleanup original test table
TRUNCATE spock.exception_log;
SELECT spock.replicate_ddl($$ DROP TABLE public.conflict_stat_test CASCADE; $$);
