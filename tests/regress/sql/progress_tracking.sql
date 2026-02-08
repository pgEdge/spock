--
-- Test that spock.progress is properly maintained during sync,
-- specifically that adjust_progress_info() correctly upserts
-- forwarding entries in a 3-node cascade scenario.
--
-- Topology: orig_provider (sourcedb) -> provider (regression) -> subscriber (postgres)
--
-- The key behavior under test: when subscriber resyncs a table with provider,
-- adjust_progress_info() copies progress entries from provider's progress
-- table into subscriber's progress table for all remote_node_ids other than
-- subscriber itself. With the old UPDATE-only code, this would fail when
-- the subscriber had no pre-existing entry for orig_provider. The new
-- UPSERT code correctly INSERTs the forwarding entry.
--

SELECT * FROM spock_regress_variables()
\gset

-- ============================================================
-- Record subscriber's initial progress state (before cascade)
-- ============================================================
\c :subscriber_dsn

SELECT count(*) AS initial_progress_count
FROM spock.progress
WHERE node_id = (SELECT node_id FROM spock.local_node);

-- ============================================================
-- Set up the orig_provider node (top of the cascade)
-- ============================================================
\c :orig_provider_dsn
SET client_min_messages = 'warning';

GRANT ALL ON SCHEMA public TO nonsuper;

DO $$
BEGIN
        IF (SELECT setting::integer/100 FROM pg_settings WHERE name = 'server_version_num') = 904 THEN
                CREATE EXTENSION IF NOT EXISTS spock_origin;
        END IF;
END;$$;

DO $$
BEGIN
        CREATE EXTENSION IF NOT EXISTS spock;
END;
$$;
ALTER EXTENSION spock UPDATE;

-- Suppress the OID output by wrapping in a DO block
DO $$
BEGIN
    PERFORM spock.node_create(node_name := 'test_orig_provider',
        dsn := (SELECT orig_provider_dsn FROM spock_regress_variables()) || ' user=super');
END;
$$;

-- ============================================================
-- Subscribe provider to orig_provider
-- ============================================================
\c :provider_dsn
SET client_min_messages = 'warning';

BEGIN;
-- Suppress OID output
DO $$
BEGIN
    PERFORM spock.sub_create(
        subscription_name := 'test_orig_subscription',
        provider_dsn := (SELECT orig_provider_dsn FROM spock_regress_variables()) || ' user=super',
        synchronize_structure := false,
        synchronize_data := true,
        forward_origins := '{}');
END;
$$;
COMMIT;

BEGIN;
SET LOCAL statement_timeout = '10s';
SELECT spock.sub_wait_for_sync('test_orig_subscription');
COMMIT;

SELECT subscription_name, status, provider_node FROM spock.sub_show_status();

-- ============================================================
-- Create a table on orig_provider and replicate data to provider.
-- This ensures the provider has a non-trivial progress entry for
-- orig_provider (with real LSN and timestamp values).
-- Note: subscriber won't get this data due to forward_origins='{}',
-- but that's fine -- we just need the progress entry on the provider.
-- ============================================================
\c :orig_provider_dsn

SELECT spock.replicate_ddl($$
    CREATE TABLE public.orig_data_tbl (
        id serial primary key,
        data text
    );
$$);

SELECT * FROM spock.repset_add_table('default', 'orig_data_tbl');

INSERT INTO orig_data_tbl(data) VALUES ('from_orig_1'), ('from_orig_2'), ('from_orig_3');

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

-- Verify provider received the data from orig_provider
\c :provider_dsn
SELECT id, data FROM orig_data_tbl ORDER BY id;

-- Verify provider now has a progress entry for orig_provider
-- with a real (non-zero) LSN and a valid timestamp
SELECT
    (p.remote_lsn <> '0/0') AS has_nonzero_lsn,
    (p.remote_commit_ts > 'epoch'::timestamptz) AS has_valid_timestamp
FROM spock.progress p
JOIN spock.node_interface n ON n.if_nodeid = p.remote_node_id
WHERE p.node_id = (SELECT node_id FROM spock.local_node)
  AND n.if_name = 'test_orig_provider';

-- ============================================================
-- Create a table on the PROVIDER and add it to the default repset.
-- This table will replicate to the subscriber, giving us something
-- to resync that triggers adjust_progress_info().
-- ============================================================

SELECT spock.replicate_ddl($$
    CREATE TABLE public.resync_target_tbl (
        id serial primary key,
        data text
    );
$$);

SELECT * FROM spock.repset_add_table('default', 'resync_target_tbl');

INSERT INTO resync_target_tbl(data) VALUES ('prov1'), ('prov2'), ('prov3');

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

-- Verify subscriber received the data
\c :subscriber_dsn

DO $$
BEGIN
    FOR i IN 1..100 LOOP
        IF EXISTS (
            SELECT 1 FROM spock.local_sync_status
            WHERE sync_relname = 'resync_target_tbl'
              AND sync_status IN ('y', 'r')
        ) THEN
            RETURN;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
END;
$$;

SELECT id, data FROM resync_target_tbl ORDER BY id;

-- ============================================================
-- Check subscriber's progress BEFORE table resync.
-- The initial sync of resync_target_tbl may have already
-- triggered adjust_progress_info. Check that we have at least
-- the basic entry for the direct subscription.
-- ============================================================

SELECT count(*) >= 1 AS has_progress_entries
FROM spock.progress
WHERE node_id = (SELECT node_id FROM spock.local_node);

-- ============================================================
-- Now trigger a table resync on subscriber. This calls
-- adjust_progress_info() which should UPSERT the forwarding
-- entry for orig_provider into subscriber's progress table.
-- ============================================================

SELECT * FROM spock.sub_resync_table('test_subscription', 'resync_target_tbl');

-- Wait for resync to complete
DO $$
BEGIN
    FOR i IN 1..200 LOOP
        IF EXISTS (
            SELECT 1 FROM spock.local_sync_status
            WHERE sync_relname = 'resync_target_tbl'
              AND sync_status IN ('y', 'r')
        ) THEN
            RETURN;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
END;
$$;

-- Verify the data is intact after resync
SELECT id, data FROM resync_target_tbl ORDER BY id;

-- ============================================================
-- KEY ASSERTIONS: verify subscriber's progress table after resync.
--
-- After adjust_progress_info() runs during resync, subscriber
-- should have a forwarding entry for orig_provider in addition
-- to its direct subscription entry for provider.
-- ============================================================

-- The subscriber should have at least 2 progress entries:
-- 1. (subscriber_id, provider_id)       - direct subscription
-- 2. (subscriber_id, orig_provider_id)  - forwarding entry from resync
SELECT count(*) >= 2 AS has_forwarding_entries
FROM spock.progress
WHERE node_id = (SELECT node_id FROM spock.local_node);

-- All progress entries should have node_id = local node id
SELECT count(*) = 0 AS all_entries_local
FROM spock.progress
WHERE node_id <> (SELECT node_id FROM spock.local_node);

-- Verify we have at least one entry where remote_node_id is NOT the
-- direct subscription origin (provider). This is the forwarding entry.
SELECT count(*) >= 1 AS has_non_provider_entry
FROM spock.progress p
WHERE p.node_id = (SELECT node_id FROM spock.local_node)
  AND p.remote_node_id NOT IN (
      SELECT sub_origin FROM spock.subscription
  );

-- ============================================================
-- Cleanup
-- ============================================================
\c :provider_dsn

DO $$
BEGIN
    FOR i IN 1..100 LOOP
        IF EXISTS (SELECT 1 FROM pg_stat_replication) THEN
            RETURN;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
END;
$$;

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\set VERBOSITY terse

SELECT spock.replicate_ddl($$
    DROP TABLE public.resync_target_tbl CASCADE;
$$);

\c :orig_provider_dsn
\set VERBOSITY terse
SELECT spock.replicate_ddl($$
    DROP TABLE public.orig_data_tbl CASCADE;
$$);

\c :provider_dsn
SELECT * FROM spock.sub_drop('test_orig_subscription');

\c :orig_provider_dsn
SELECT * FROM spock.node_drop(node_name := 'test_orig_provider');

SELECT plugin, slot_type, active FROM pg_replication_slots;
SELECT count(*) FROM pg_stat_replication;
