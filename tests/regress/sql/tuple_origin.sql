--Tuple Origin
SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn
ALTER SYSTEM SET spock.save_resolutions = on;
SELECT pg_reload_conf();

\c :subscriber_dsn
TRUNCATE spock.resolutions;

\c :provider_dsn
SELECT spock.replicate_ddl($$
    CREATE TABLE users (id int PRIMARY KEY, mgr_id int);
$$);
SELECT * FROM spock.repset_add_table('default', 'users');

BEGIN;
INSERT INTO USERS SELECT 1, 5;
UPDATE USERS SET id = id + 1 WHERE mgr_id < 10;
UPDATE USERS SET id = id + 1 WHERE mgr_id < 10;
END;

-- Ensure that DDL and updates is confirmed as flushed to the subscriber
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
\c :subscriber_dsn
SELECT * FROM users ORDER BY id;

-- Expect 0 rows in spock.resolutions since the origin is the same
SELECT COUNT(*) FROM spock.resolutions
    WHERE relname='public.users'
    AND local_timestamp = remote_timestamp;

-- DELETE the row from subscriber first, in order to create a conflict
DELETE FROM users where id = 3;
TRUNCATE spock.resolutions;
TRUNCATE spock.exception_log;

\c :provider_dsn
-- This will create a update_missing conflict on the subscriber, row does not exist
UPDATE users SET mgr_id = 99 WHERE id = 3;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
-- Expect 0 rows in spock.resolutions
SELECT COUNT(*) FROM spock.resolutions;
-- Expect 1 row in spock.exception_log
SELECT operation, table_name FROM spock.exception_log;

\c :provider_dsn
-- This will create a conflict on the subscriber
DELETE FROM users where id = 3;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
-- Expect 1 row in spock.resolutions with NULL local_timestamp
SELECT conflict_type FROM spock.resolutions
    WHERE relname='public.users'
    AND local_timestamp IS NULL;

-- Clear out for next test
TRUNCATE spock.resolutions;
TRUNCATE spock.exception_log;

\c :provider_dsn

INSERT INTO users VALUES (3, 33);
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

-- Set up test.
-- Delete on n1 with delay, update on n2, wait, query to see conflict

-- Add 2000ms delay to the output plugin
ALTER SYSTEM SET spock.output_delay = 2000;
SELECT pg_reload_conf();

-- Let it take effect
SELECT pg_sleep(1);

DELETE FROM users WHERE id = 3;

\c :subscriber_dsn

-- With the 2 second delay, we should see the row
SELECT * FROM users;

UPDATE users SET mgr_id = 333 WHERE id = 3;

-- Wait for delay time to pass with a 1 second buffer
-- so that the delayed DELETE finally arrives (late)
SELECT pg_sleep(3);

-- We should see one resolution, delete_late
SELECT conflict_type, local_tuple FROM spock.resolutions;

-- Empty
SELECT COUNT(1) thecount FROM spock.exception_log;

SHOW spock.output_delay;

-- Reset delay
ALTER SYSTEM SET spock.output_delay = 0;
SELECT pg_reload_conf();

-- More tests

\c :provider_dsn
SELECT spock.replicate_ddl($$
	CREATE TABLE basic_conflict (
		id int primary key,
		data text);
$$);

SELECT * FROM spock.repset_add_table('default', 'basic_conflict');

INSERT INTO basic_conflict VALUES (1, 'A'), (2, 'B');

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

TRUNCATE spock.resolutions;

SELECT * FROM basic_conflict ORDER BY id;

\c :provider_dsn

UPDATE basic_conflict SET data = 'AAA' WHERE id = 1;

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

SELECT * FROM basic_conflict ORDER BY id;

--- should return nothing
SELECT relname, conflict_type FROM spock.resolutions WHERE relname = 'public.basic_conflict';

-- Enable logging when update origin changes
ALTER SYSTEM SET spock.log_update_origin_change = true;
SELECT pg_reload_conf();

-- now update row locally to set up an origin difference
UPDATE basic_conflict SET data = 'sub-A' WHERE id = 1;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :provider_dsn

-- Update on provider again so subscriber will see
-- an origin different from its local one
UPDATE basic_conflict SET data = 'pub-A' WHERE id = 1;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT * FROM basic_conflict ORDER BY id;

-- We should now see a conflict
SELECT relname, conflict_type FROM spock.resolutions WHERE relname = 'public.basic_conflict';

-- Clean
TRUNCATE spock.resolutions;

\c :provider_dsn
-- Do update in same transaction as INSERT
BEGIN;
INSERT INTO basic_conflict VALUES (3, 'C');
UPDATE basic_conflict SET data = 'pub-C' WHERE id = 3;
COMMIT;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT * FROM basic_conflict ORDER BY id;

-- We should not see a conflict
SELECT relname, conflict_type FROM spock.resolutions WHERE relname = 'public.basic_conflict';

-- insert_exists check. Add a row to conflict with
TRUNCATE spock.exception_log;
TRUNCATE spock.resolutions;
INSERT INTO basic_conflict VALUES (4, 'D');

\c :provider_dsn
INSERT INTO basic_conflict VALUES (4, 'DD');
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
-- The insert gets converted into an update, conflict type insert_exists
SELECT conflict_type, conflict_resolution, remote_tuple FROM spock.resolutions;

-- Test: log_update_origin_change = true logs update_origin_differs
\c :subscriber_dsn
TRUNCATE spock.resolutions;
ALTER SYSTEM SET spock.log_update_origin_change = true;
SELECT pg_reload_conf();

-- Update locally to change origin
UPDATE basic_conflict SET data = 'sub-A2' WHERE id = 1;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :provider_dsn
UPDATE basic_conflict SET data = 'pub-A2' WHERE id = 1;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
-- Should see update_origin_differs when log_update_origin_change is on
SELECT conflict_type FROM spock.resolutions WHERE relname = 'public.basic_conflict';

-- Test: VACUUM FREEZE prevents origin detection so no conflict is logged
-- even when log_update_origin_change = true
TRUNCATE spock.resolutions;

-- VACUUM FREEZE the table so existing tuples get FrozenTransactionId
VACUUM FREEZE basic_conflict;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :provider_dsn
-- Update on provider; subscriber's local tuple is frozen so origin is unknown
UPDATE basic_conflict SET data = 'pub-A2f' WHERE id = 1;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
-- Should NOT see update_origin_differs because local origin could not be determined
SELECT COUNT(*) FROM spock.resolutions WHERE relname = 'public.basic_conflict';

-- Test: log_update_origin_change = false suppresses update_origin_differs
TRUNCATE spock.resolutions;
ALTER SYSTEM SET spock.log_update_origin_change = false;
SELECT pg_reload_conf();

-- Update locally to change origin
UPDATE basic_conflict SET data = 'sub-A3' WHERE id = 1;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :provider_dsn
UPDATE basic_conflict SET data = 'pub-A3' WHERE id = 1;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
-- Should NOT see update_origin_differs when log_update_origin_change is off
SELECT COUNT(*) FROM spock.resolutions WHERE relname = 'public.basic_conflict';

-- Test: log_delete_origin_change = true logs delete_origin_differs
TRUNCATE spock.resolutions;
ALTER SYSTEM SET spock.log_delete_origin_change = true;
SELECT pg_reload_conf();

-- Update row locally to change its origin
UPDATE basic_conflict SET data = 'sub-B' WHERE id = 2;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :provider_dsn
-- Delete the row; subscriber should detect origin differs
DELETE FROM basic_conflict WHERE id = 2;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
-- Should see delete_origin_differs
SELECT conflict_type FROM spock.resolutions WHERE relname = 'public.basic_conflict';

-- Test: VACUUM FREEZE prevents origin detection so no delete conflict is logged
-- even when log_delete_origin_change = true
TRUNCATE spock.resolutions;

-- VACUUM FREEZE the table so existing tuples get FrozenTransactionId
VACUUM FREEZE basic_conflict;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :provider_dsn
-- Delete on provider; subscriber's local tuple is frozen so origin is unknown
DELETE FROM basic_conflict WHERE id = 4;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
-- Should NOT see delete_origin_differs because local origin could not be determined
SELECT COUNT(*) FROM spock.resolutions WHERE relname = 'public.basic_conflict';

-- Test: log_delete_origin_change = false suppresses delete_origin_differs
\c :provider_dsn
INSERT INTO basic_conflict VALUES (5, 'E');
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
TRUNCATE spock.resolutions;
ALTER SYSTEM SET spock.log_delete_origin_change = false;
SELECT pg_reload_conf();

-- Update locally to change origin
UPDATE basic_conflict SET data = 'sub-E' WHERE id = 5;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :provider_dsn
DELETE FROM basic_conflict WHERE id = 5;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
-- Should NOT see delete_origin_differs when log_delete_origin_change is off
SELECT COUNT(*) FROM spock.resolutions WHERE relname = 'public.basic_conflict';

-- cleanup
\c :provider_dsn
SELECT * FROM spock.repset_remove_table('default', 'users');
SELECT * FROM spock.repset_remove_table('default', 'basic_conflict');

SELECT spock.replicate_ddl($$
    DROP TABLE users CASCADE;
$$);
SELECT spock.replicate_ddl($$
	DROP TABLE basic_conflict;
$$);
ALTER SYSTEM SET spock.log_update_origin_change = false;
ALTER SYSTEM SET spock.log_delete_origin_change = false;
ALTER SYSTEM SET spock.save_resolutions = off;
SELECT pg_reload_conf();
