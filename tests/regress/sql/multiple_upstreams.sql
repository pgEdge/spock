SELECT * FROM spock_regress_variables()
\gset

\c :subscriber_dsn
GRANT ALL ON SCHEMA public TO nonsuper;
SELECT E'\'' || current_database() || E'\'' AS subdb;
\gset

\c :provider1_dsn
SET client_min_messages = 'warning';

GRANT ALL ON SCHEMA public TO nonsuper;

SET client_min_messages = 'warning';

DO $$
BEGIN
        IF (SELECT setting::integer/100 FROM pg_settings WHERE name = 'server_version_num') = 904 THEN
                CREATE EXTENSION IF NOT EXISTS spock_origin;
        END IF;
END;$$;

CREATE EXTENSION IF NOT EXISTS spock;

SELECT * FROM spock.node_create(node_name := 'test_provider1', dsn := (SELECT provider1_dsn FROM spock_regress_variables()) || ' user=super');

\c :provider_dsn
-- add these entries to provider
SELECT spock.replicate_ddl($$
      CREATE TABLE public.multi_ups_tbl(id integer primary key, key text unique not null, data text);
$$);

INSERT INTO multi_ups_tbl VALUES(1, 'key1', 'data1');
INSERT INTO multi_ups_tbl VALUES(2, 'key2', 'data2');
INSERT INTO multi_ups_tbl VALUES(3, 'key3', 'data3');

SELECT * FROM spock.repset_add_table('default', 'multi_ups_tbl', true);
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :provider1_dsn

-- add these entries to provider1
CREATE TABLE multi_ups_tbl(id integer primary key, key text unique not null, data text);
INSERT INTO multi_ups_tbl VALUES(4, 'key4', 'data4');
INSERT INTO multi_ups_tbl VALUES(5, 'key5', 'data5');
INSERT INTO multi_ups_tbl VALUES(6, 'key6', 'data6');

SELECT * FROM spock.repset_add_table('default', 'multi_ups_tbl');

\c :subscriber_dsn

-- We'll use the already existing spock node
-- notice synchronize_structure as false when table definition already exists
SELECT * FROM spock.sub_create(
    subscription_name := 'test_subscription1',
    provider_dsn := (SELECT provider1_dsn FROM spock_regress_variables()) || ' user=super',
	synchronize_structure := false,
        synchronize_data := true,
	forward_origins := '{}');

BEGIN;
SET LOCAL statement_timeout = '10s';
SELECT spock.sub_wait_for_sync('test_subscription1');
COMMIT;

SELECT subscription_name, status, provider_node, replication_sets, forward_origins FROM spock.sub_show_status();

SELECT sync_kind, sync_subid, sync_nspname, sync_relname, sync_status IN ('y', 'r') FROM spock.local_sync_status ORDER BY 2,3,4;

SELECT * from multi_ups_tbl ORDER BY id;

-- Make sure we see the slot and active connection
\c :provider1_dsn
SELECT plugin, slot_type, active FROM pg_replication_slots;
SELECT count(*) FROM pg_stat_replication;

-- cleanup
\c :provider_dsn
\set VERBOSITY terse
SELECT spock.replicate_ddl($$
        DROP TABLE public.multi_ups_tbl CASCADE;
$$);

\c :provider1_dsn
SELECT * FROM spock.node_drop(node_name := 'test_provider1');
\set VERBOSITY terse
DROP TABLE public.multi_ups_tbl CASCADE;

\c :subscriber_dsn
SELECT * FROM spock.sub_drop('test_subscription1');

\c :provider1_dsn
SELECT * FROM spock.node_drop(node_name := 'test_provider1');
SELECT plugin, slot_type, active FROM pg_replication_slots;
SELECT count(*) FROM pg_stat_replication;
