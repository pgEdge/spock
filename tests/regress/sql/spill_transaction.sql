--
-- Test: replay queue spill-to-disk for large transactions
--
-- Verifies that a bulk-loaded transaction is successfully replicated when
-- the replay queue exceeds the in-memory limit and spills to a temp file.
-- Tests all three exception_behaviour modes, both without and with a
-- conflict on the last record.
--

SELECT * FROM spock_regress_variables()
\gset

\c :subscriber_dsn
TRUNCATE spock.resolutions;
TRUNCATE spock.exception_log;
ALTER SYSTEM SET spock.save_resolutions = on;
-- Force spilling by setting a very low queue size limit (1 MB)
ALTER SYSTEM SET spock.exception_replay_queue_size = 1;
SELECT pg_reload_conf();

-- Create the test table on both nodes via replicated DDL
\c :provider_dsn
SELECT spock.replicate_ddl($$
  CREATE TABLE public.test_spill (
	id integer PRIMARY KEY, payload serial);
  CREATE UNIQUE INDEX payload_idx ON test_spill (payload);
$$);

SELECT * FROM spock.repset_add_table('default', 'test_spill');

-- ============================================================
-- TRANSDISCARD mode — no conflict
-- ============================================================
\c :subscriber_dsn
ALTER SYSTEM SET spock.exception_behaviour = 'transdiscard';
SELECT pg_reload_conf();

\c :provider_dsn
COPY test_spill (id) FROM PROGRAM 'seq 1 50000' WITH (FORMAT text);

SELECT spock.sync_event() as sync_lsn
\gset

\c :subscriber_dsn
CALL spock.wait_for_sync_event(NULL, 'test_provider', :'sync_lsn', 30);
SELECT count(*), sum(payload) FROM test_spill;

-- ============================================================
-- DISCARD mode — no conflict
-- ============================================================
\c :subscriber_dsn
ALTER SYSTEM SET spock.exception_behaviour = 'discard';
SELECT pg_reload_conf();

\c :provider_dsn
TRUNCATE test_spill RESTART IDENTITY;
COPY test_spill (id) FROM PROGRAM 'seq 1 50000' WITH (FORMAT text);

SELECT spock.sync_event() as sync_lsn
\gset

\c :subscriber_dsn
CALL spock.wait_for_sync_event(NULL, 'test_provider', :'sync_lsn', 30);
SELECT count(*), sum(payload) FROM test_spill;

-- ============================================================
-- SUB_DISABLE mode — no conflict
-- ============================================================
\c :subscriber_dsn
ALTER SYSTEM SET spock.exception_behaviour = 'sub_disable';
SELECT pg_reload_conf();

\c :provider_dsn
TRUNCATE test_spill RESTART IDENTITY;
COPY test_spill (id) FROM PROGRAM 'seq 1 50000' WITH (FORMAT text);

SELECT spock.sync_event() as sync_lsn
\gset

\c :subscriber_dsn
CALL spock.wait_for_sync_event(NULL, 'test_provider', :'sync_lsn', 30);
SELECT count(*), sum(payload) FROM test_spill;

-- ============================================================
-- TRANSDISCARD mode — conflict on last record
-- The entire transaction is discarded; only the pre-inserted
-- conflicting row remains on the subscriber.
-- ============================================================
\c :subscriber_dsn
ALTER SYSTEM SET spock.exception_behaviour = 'transdiscard';
SELECT pg_reload_conf();

\c :provider_dsn
TRUNCATE test_spill RESTART IDENTITY;
SELECT spock.sync_event() as sync_lsn
\gset

\c :subscriber_dsn
CALL spock.wait_for_sync_event(NULL, 'test_provider', :'sync_lsn', 30);
INSERT INTO test_spill (id, payload) VALUES (-1, 50000);

\c :provider_dsn
COPY test_spill (id) FROM PROGRAM 'seq 1 50000' WITH (FORMAT text);

SELECT spock.sync_event() as sync_lsn
\gset

\c :subscriber_dsn
CALL spock.wait_for_sync_event(NULL, 'test_provider', :'sync_lsn', 30);

-- Check: COPY transaction discarded, single record presented
SELECT id, payload FROM test_spill;

SELECT operation AS opt, remote_new_tup FROM spock.exception_log
ORDER BY command_counter DESC LIMIT 5;

-- ============================================================
-- DISCARD mode — conflict on last record
-- The conflict is resolved per-row; all 50000 rows arrive.
-- ============================================================
\c :subscriber_dsn
TRUNCATE spock.exception_log;
ALTER SYSTEM SET spock.exception_behaviour = 'discard';
SELECT pg_reload_conf();

\c :provider_dsn
TRUNCATE test_spill RESTART IDENTITY;
SELECT spock.sync_event() as sync_lsn
\gset

\c :subscriber_dsn
CALL spock.wait_for_sync_event(NULL, 'test_provider', :'sync_lsn', 30);
INSERT INTO test_spill (id, payload) VALUES (-1, 50000);

\c :provider_dsn
COPY test_spill (id) FROM PROGRAM 'seq 1 50000' WITH (FORMAT text);

SELECT spock.sync_event() as sync_lsn
\gset

\c :subscriber_dsn
CALL spock.wait_for_sync_event(NULL, 'test_provider', :'sync_lsn', 30);
-- Check 49999 COPY records applied plus older one has been kept
SELECT count(*), sum(id), sum(payload) FROM test_spill;

SELECT operation AS opt,remote_new_tup FROM spock.exception_log
ORDER BY command_counter DESC LIMIT 5;

-- ============================================================
-- SUB_DISABLE mode — conflict on last record
-- The subscription is disabled on conflict. Remove the
-- conflicting row, re-enable, and verify the transaction
-- is applied successfully.
-- ============================================================

\c :provider_dsn
TRUNCATE test_spill RESTART IDENTITY;
SELECT spock.sync_event() as sync_lsn \gset

\c :subscriber_dsn
CALL spock.wait_for_sync_event(NULL, 'test_provider', :'sync_lsn', 30);
TRUNCATE spock.exception_log;
ALTER SYSTEM SET spock.exception_behaviour = 'sub_disable';
SELECT pg_reload_conf();

-- Check that all works and clean on subscriber
SELECT status FROM spock.sub_show_status('test_subscription');
SELECT * FROM test_spill; -- empty

INSERT INTO test_spill (id, payload) VALUES (-1, 50000); -- Add conflicting record

\c :provider_dsn
COPY test_spill (id) FROM PROGRAM 'seq 1 50000' WITH (FORMAT text);

-- Wait for the subscription to become disabled (apply worker may still
-- be processing the conflict asynchronously).
\c :subscriber_dsn
DO $$
BEGIN
  SET LOCAL statement_timeout = '30s';
  WHILE (SELECT status FROM spock.sub_show_status('test_subscription')) <> 'disabled' LOOP
    PERFORM pg_sleep(0.1);
  END LOOP;
END;
$$;

-- Remove the conflicting row and re-enable
DELETE FROM test_spill WHERE id = -1;
SELECT spock.sub_enable('test_subscription', true);

\c :provider_dsn
SELECT spock.sync_event() as sync_lsn
\gset

\c :subscriber_dsn
CALL spock.wait_for_sync_event(NULL, 'test_provider', :'sync_lsn', 30);
-- Check: COPY passed successfully
SELECT count(*), sum(id), sum(payload) FROM test_spill;

-- Check how the conflict has been processed.
SELECT node_name,relname,idxname,conflict_type,conflict_resolution,
  local_tuple,remote_tuple FROM spock.resolutions;
SELECT operation AS opt, remote_new_tup FROM spock.exception_log
ORDER BY command_counter DESC LIMIT 5;

-- ============================================================
-- Cleanup
-- ============================================================
ALTER SYSTEM RESET spock.exception_behaviour;
ALTER SYSTEM RESET spock.exception_replay_queue_size;
ALTER SYSTEM RESET spock.save_resolutions;
SELECT pg_reload_conf();

\c :provider_dsn
SELECT spock.replicate_ddl('DROP TABLE public.test_spill CASCADE;');

SELECT spock.sync_event() as sync_lsn
\gset

\c :subscriber_dsn
CALL spock.wait_for_sync_event(NULL, 'test_provider', :'sync_lsn', 30);
