-- This should be done with pg_regress's --create-role option
-- but it's blocked by bug 37906
SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn
SET client_min_messages = 'warning';
DROP USER IF EXISTS nonsuper;
DROP USER IF EXISTS super;

CREATE USER nonsuper WITH replication;
CREATE USER super SUPERUSER;

\c :subscriber_dsn
SET client_min_messages = 'warning';
DROP USER IF EXISTS nonsuper;
DROP USER IF EXISTS super;

CREATE USER nonsuper WITH replication;
CREATE USER super SUPERUSER;

-- Can't because of bug 37906
--GRANT ALL ON DATABASE regress TO nonsuper;
--GRANT ALL ON DATABASE regress TO nonsuper;

\c :provider_dsn
GRANT ALL ON SCHEMA public TO nonsuper;

DO $$
BEGIN
	IF (SELECT setting::integer/100 FROM pg_settings WHERE name = 'server_version_num') >= 1000 THEN
		CREATE OR REPLACE FUNCTION public.pg_current_xlog_location() RETURNS pg_lsn
		LANGUAGE SQL AS 'SELECT pg_current_wal_lsn()';
		ALTER FUNCTION public.pg_current_xlog_location() OWNER TO super;
	END IF;
END; $$;

\c :subscriber_dsn
GRANT ALL ON SCHEMA public TO nonsuper;
SELECT E'\'' || current_database() || E'\'' AS subdb;
\gset

\c :provider_dsn
SET client_min_messages = 'warning';

CREATE EXTENSION IF NOT EXISTS spock;

-- Check default settings of installed Spock extension
SELECT
  extnamespace::regnamespace,
  extrelocatable,
  extconfig,
  extcondition,
  obj_description(oid) AS comment
FROM pg_extension WHERE extname = 'spock';

SELECT * FROM spock.node_create(node_name := 'test_provider', dsn := (SELECT provider_dsn FROM spock_regress_variables()) || ' user=super');

\c :subscriber_dsn
SET client_min_messages = 'warning';

CREATE EXTENSION IF NOT EXISTS spock;

SELECT * FROM spock.node_create(node_name := 'test_subscriber', dsn := (SELECT subscriber_dsn FROM spock_regress_variables()) || ' user=super');

BEGIN;
SELECT 1 FROM spock.sub_create(
    subscription_name := 'test_subscription',
    provider_dsn := (SELECT provider_dsn FROM spock_regress_variables()) || ' user=super',
	synchronize_structure := true,
	synchronize_data := true,
	forward_origins := '{}');
/*
 * Remove the function we added in preseed because otherwise the restore of
 * schema will fail. We do this in same transaction as sub_create()
 * because the subscription process will only start on commit.
 */
DROP FUNCTION IF EXISTS public.spock_regress_variables();
COMMIT;

BEGIN;
SET LOCAL statement_timeout = '30s';
SELECT spock.sub_wait_for_sync('test_subscription');
COMMIT;

SELECT sync_kind, sync_subid, sync_nspname, sync_relname, sync_status IN ('y', 'r') FROM spock.local_sync_status ORDER BY 2,3,4;

-- Make sure we see the slot and active connection
\c :provider_dsn
SELECT plugin, slot_type, active FROM pg_replication_slots;
SELECT count(*) FROM pg_stat_replication;

CREATE OR REPLACE FUNCTION fetch_last_xid(action char DEFAULT 'U')
RETURNS xid
LANGUAGE plpgsql
AS $$
DECLARE
    remote_xid xid;
    i INTEGER;
    slot TEXT;
BEGIN
    -- Wait up to 10 seconds (100 x 0.1s) for an inactive slot
    FOR i IN 1..100 LOOP
        IF EXISTS (SELECT 1 FROM pg_replication_slots WHERE active = false) THEN
            EXIT;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;

    -- Get slot name
    SELECT slot_name INTO slot FROM pg_replication_slots LIMIT 1;

    -- Fetch the remote xid of last UPDATE ('U') action
    SELECT xid
    INTO remote_xid
    FROM pg_logical_slot_peek_changes(
            slot,
            NULL,
            10,
            'min_proto_version', '4',
            'max_proto_version', '5',
            'startup_params_format', '1',
            'proto_format', 'json',
            'spock.replication_set_names', 'default,ddl_sql'
        ) AS changes(lsn, xid, data)
    WHERE data IS NOT NULL
      AND data <> ''
      AND data::json->>'action' = action
    LIMIT 1;

    RETURN remote_xid;
END;
$$;

\c :subscriber_dsn
CREATE OR REPLACE FUNCTION skiplsn_and_enable_sub(
    sub_name text,
    p_remote_xid bigint
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    skiplsn text;
BEGIN
    -- Extract skip_lsn from exception_log
    SELECT quote_literal((regexp_match(error_message, 'skip_lsn = ([0-9A-F/]+)'))[1])
    INTO skiplsn
    FROM spock.exception_log
    WHERE remote_xid = p_remote_xid
      AND operation = 'SUB_DISABLE'
    LIMIT 1;

    IF skiplsn IS NULL THEN
        RAISE EXCEPTION 'skip_lsn not found for remote_xid = %', p_remote_xid;
    END IF;

    -- Alter subscription to skip the problematic LSN
    EXECUTE format('SELECT spock.sub_alter_skiplsn(%L, %s)', sub_name, skiplsn);

    -- Re-enable the subscription
    EXECUTE format('SELECT spock.sub_enable(%L, true)', sub_name);
END;
$$;
