--
-- Test: Exception behaviour modes (DISCARD, TRANSDISCARD, SUB_DISABLE)
--
-- Common scenario: three tables on provider, one broken on subscriber.
-- A single transaction with DMLs on all three tables triggers an error
-- on the broken table.  The first DML (INSERT into drl_t1) also creates
-- a conflict (INSERT_EXISTS) to verify that dry-run modes do not log
-- it to spock.resolutions, while DISCARD mode does.
--
-- Each mode uses a different breakage method:
--   TRANSDISCARD: absent table   (DROP TABLE on subscriber)
--   DISCARD:      truncated table (TRUNCATE on subscriber, row missing)
--   SUB_DISABLE:  deleted row     (DELETE on subscriber, row missing)
--
SELECT * FROM spock_regress_variables()
\gset

-- ============================================================
-- Setup: create the three tables on the provider, enable
-- resolution logging so we can verify resolutions behavior.
-- ============================================================
\c :provider_dsn
ALTER SYSTEM SET spock.save_resolutions = on;
SELECT pg_reload_conf();

SELECT spock.replicate_ddl($$
  CREATE TABLE public.drl_t1 (x integer PRIMARY KEY);
  CREATE TABLE public.drl_t2 (x integer PRIMARY KEY);
  CREATE TABLE public.drl_t3 (x integer PRIMARY KEY);
$$);
SELECT spock.repset_add_table('default', 'drl_t1');
SELECT spock.repset_add_table('default', 'drl_t2');
SELECT spock.repset_add_table('default', 'drl_t3');

INSERT INTO drl_t1 VALUES (0);
INSERT INTO drl_t2 VALUES (0);
INSERT INTO drl_t3 VALUES (0);
SELECT spock.sync_event() AS sync_lsn \gset

-- Verify initial data arrived
\c :subscriber_dsn
CALL spock.wait_for_sync_event(NULL, 'test_provider', :'sync_lsn', 30);
SELECT * FROM drl_t1;
SELECT * FROM drl_t2;
SELECT * FROM drl_t3;

-- ============================================================
-- TRANSDISCARD mode  (error: absent table)
--
-- drl_t1: pre-insert row x=1 on subscriber to set up INSERT_EXISTS
-- drl_t2: DROP TABLE to provoke "can't find relation" error
-- ============================================================
\c :subscriber_dsn
TRUNCATE spock.exception_log;
TRUNCATE spock.resolutions;
ALTER SYSTEM SET spock.exception_behaviour = 'transdiscard';
SELECT pg_reload_conf();

-- Set up INSERT_EXISTS conflict on drl_t1
INSERT INTO drl_t1 VALUES (1);
-- Drop table_2 on subscriber to provoke error
DROP TABLE drl_t2;

\c :provider_dsn
BEGIN;
INSERT INTO drl_t1 VALUES (1);       -- conflict: INSERT_EXISTS
UPDATE drl_t2 SET x = 1 WHERE x = 0; -- error: missing relation
UPDATE drl_t3 SET x = 1 WHERE x = 0; -- ok
END;
SELECT spock.sync_event() AS sync_lsn \gset
\c :subscriber_dsn
CALL spock.wait_for_sync_event(NULL, 'test_provider', :'sync_lsn', 30);

-- None of the DMLs should have been applied (entire TX discarded)
SELECT * FROM drl_t1 ORDER BY x;
SELECT * FROM drl_t3;

-- Three records in exception_log; only drl_t2 has a non-NULL error_message.
SELECT table_name, operation, (error_message <> '') AS has_error
FROM spock.exception_log
ORDER BY command_counter;

-- Resolutions must be empty: dry-run never executes DML, so no
-- conflict detection happens.
SELECT COUNT(*) AS resolutions_count FROM spock.resolutions;

-- ============================================================
-- TRANSDISCARD with DDL in the transaction
--
-- Verify that a queued DDL operation inside a failing transaction
-- produces exactly one exception_log entry, not a duplicate.
-- ============================================================
\c :subscriber_dsn
TRUNCATE spock.exception_log;
TRUNCATE drl_t3;

\c :provider_dsn
BEGIN;
UPDATE drl_t1 SET x = 2 WHERE x = 1;
SELECT spock.replicate_ddl('CREATE TABLE IF NOT EXISTS public.drl_dummy (x int)');
UPDATE drl_t3 SET x = 2 WHERE x = 1;  -- error: row missing after TRUNCATE
END;
SELECT spock.sync_event() AS sync_lsn \gset
\c :subscriber_dsn
CALL spock.wait_for_sync_event(NULL, 'test_provider', :'sync_lsn', 30);

-- Expect no duplicate DDL entries: one record per operation.
SELECT table_name, operation, (error_message <> '') AS has_error, ddl_statement
FROM spock.exception_log
ORDER BY command_counter;

-- Check data:
SELECT x FROM drl_t1 WHERE x = 2; -- Record has not been updated
SELECT * FROM drl_dummy; -- ERROR, table doesn't exist

-- Cleanup the dummy table
\c :provider_dsn
SELECT spock.replicate_ddl('DROP TABLE IF EXISTS public.drl_dummy');

-- ============================================================
-- Reset for next test
-- ============================================================
\c :provider_dsn
SELECT spock.replicate_ddl($$
  DROP TABLE IF EXISTS public.drl_t1 CASCADE;
  DROP TABLE IF EXISTS public.drl_t2 CASCADE;
  DROP TABLE IF EXISTS public.drl_t3 CASCADE;
  CREATE TABLE public.drl_t1 (x integer PRIMARY KEY);
  CREATE TABLE public.drl_t2 (x integer PRIMARY KEY);
  CREATE TABLE public.drl_t3 (x integer PRIMARY KEY);
$$);
SELECT spock.repset_add_table('default', 'drl_t1');
SELECT spock.repset_add_table('default', 'drl_t2');
SELECT spock.repset_add_table('default', 'drl_t3');
INSERT INTO drl_t1 VALUES (0);
INSERT INTO drl_t2 VALUES (0);
INSERT INTO drl_t3 VALUES (0);
SELECT spock.sync_event() AS sync_lsn \gset

\c :subscriber_dsn
CALL spock.wait_for_sync_event(NULL, 'test_provider', :'sync_lsn', 30);
SELECT * FROM drl_t1;
SELECT * FROM drl_t2;
SELECT * FROM drl_t3;

-- ============================================================
-- DISCARD mode  (error: truncated table, row missing)
--
-- drl_t1: pre-insert row x=1 to set up INSERT_EXISTS conflict
-- drl_t2: TRUNCATE so the UPDATE can't find the row
-- ============================================================
\c :subscriber_dsn
TRUNCATE spock.exception_log;
TRUNCATE spock.resolutions;
ALTER SYSTEM SET spock.exception_behaviour = 'discard';
SELECT pg_reload_conf();

-- Set up INSERT_EXISTS conflict on drl_t1
INSERT INTO drl_t1 VALUES (1);
-- Truncate table_2 on subscriber so the UPDATE can't find the row
TRUNCATE drl_t2;

\c :provider_dsn
BEGIN;
INSERT INTO drl_t1 VALUES (1);       -- conflict: INSERT_EXISTS (resolved)
UPDATE drl_t2 SET x = 1 WHERE x = 0; -- error: row missing after TRUNCATE
UPDATE drl_t3 SET x = 1 WHERE x = 0; -- ok
END;
SELECT spock.sync_event() AS sync_lsn \gset
\c :subscriber_dsn
CALL spock.wait_for_sync_event(NULL, 'test_provider', :'sync_lsn', 30);

-- In DISCARD mode: drl_t1 INSERT conflict resolved, drl_t2 failed,
-- drl_t3 applied
SELECT * FROM drl_t1 ORDER BY x;
SELECT * FROM drl_t2;
SELECT * FROM drl_t3;

-- The failed DML (drl_t2) should appear in exception_log
SELECT table_name, operation, (error_message <> '') AS has_error
FROM spock.exception_log
WHERE table_name IS NOT NULL
ORDER BY command_counter;

-- Resolutions should contain the INSERT_EXISTS conflict for drl_t1
SELECT relname, conflict_type FROM spock.resolutions
WHERE relname = 'public.drl_t1';

-- ============================================================
-- Reset for next test
-- ============================================================
\c :provider_dsn
SELECT spock.replicate_ddl($$
  DROP TABLE IF EXISTS public.drl_t1 CASCADE;
  DROP TABLE IF EXISTS public.drl_t2 CASCADE;
  DROP TABLE IF EXISTS public.drl_t3 CASCADE;
  CREATE TABLE public.drl_t1 (x integer PRIMARY KEY);
  CREATE TABLE public.drl_t2 (x integer PRIMARY KEY);
  CREATE TABLE public.drl_t3 (x integer PRIMARY KEY);
$$);
SELECT spock.repset_add_table('default', 'drl_t1');
SELECT spock.repset_add_table('default', 'drl_t2');
SELECT spock.repset_add_table('default', 'drl_t3');
INSERT INTO drl_t1 VALUES (0);
INSERT INTO drl_t2 VALUES (0);
INSERT INTO drl_t3 VALUES (0);
SELECT spock.sync_event() AS sync_lsn \gset

\c :subscriber_dsn
CALL spock.wait_for_sync_event(NULL, 'test_provider', :'sync_lsn', 30);
SELECT * FROM drl_t1;
SELECT * FROM drl_t2;
SELECT * FROM drl_t3;

-- ============================================================
-- SUB_DISABLE mode  (error: deleted row)
--
-- drl_t1: pre-insert row x=1 to set up INSERT_EXISTS conflict
-- drl_t2: DELETE the row so the UPDATE can't find it
-- ============================================================
\c :subscriber_dsn
TRUNCATE spock.exception_log;
TRUNCATE spock.resolutions;
ALTER SYSTEM SET spock.exception_behaviour = 'sub_disable';
SELECT pg_reload_conf();

-- Set up INSERT_EXISTS conflict on drl_t1
INSERT INTO drl_t1 VALUES (1);
-- Delete the row from table_2 on subscriber so the UPDATE can't find it
DELETE FROM drl_t2 WHERE x = 0;

\c :provider_dsn
BEGIN;
INSERT INTO drl_t1 VALUES (1);       -- conflict: INSERT_EXISTS
UPDATE drl_t2 SET x = 1 WHERE x = 0; -- error: row missing after DELETE
UPDATE drl_t3 SET x = 1 WHERE x = 0; -- ok
END;

-- Fetch the xid of the last UPDATE so we can skip it later
SELECT fetch_last_xid('U') AS remote_xid \gset

\c :subscriber_dsn

-- Subscription should be disabled now
SELECT sub_enabled FROM spock.subscription
  WHERE sub_name = 'test_subscription';

-- Three DML records plus one SUB_DISABLE record in exception_log.
SELECT table_name, operation, (error_message <> '') AS has_error
FROM spock.exception_log
ORDER BY command_counter;

-- None of the DMLs should have been applied
SELECT * FROM drl_t1 ORDER BY x;
SELECT * FROM drl_t3;

-- Resolutions must be empty: dry-run never executes DML
SELECT COUNT(*) AS resolutions_count FROM spock.resolutions;

-- Re-enable subscription for cleanup
SELECT skiplsn_and_enable_sub('test_subscription', :remote_xid);

\c :provider_dsn
SELECT spock.sync_event() AS sync_lsn \gset
\c :subscriber_dsn
CALL spock.wait_for_sync_event(NULL, 'test_provider', :'sync_lsn', 30);

-- ============================================================
-- Cleanup
-- ============================================================
ALTER SYSTEM RESET spock.exception_behaviour;
SELECT pg_reload_conf();

\c :provider_dsn
ALTER SYSTEM SET spock.save_resolutions = off;
SELECT pg_reload_conf();

SELECT spock.replicate_ddl($$
  DROP TABLE IF EXISTS public.drl_t1 CASCADE;
  DROP TABLE IF EXISTS public.drl_t2 CASCADE;
  DROP TABLE IF EXISTS public.drl_t3 CASCADE;
$$);
