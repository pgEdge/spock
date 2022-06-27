SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn
SELECT E'\'' || current_database() || E'\'' AS pubdb;
\gset

\c :orig_provider_dsn
SET client_min_messages = 'warning';

GRANT ALL ON SCHEMA public TO nonsuper;

SET client_min_messages = 'warning';

DO $$
BEGIN
        IF (SELECT setting::integer/100 FROM pg_settings WHERE name = 'server_version_num') = 904 THEN
                CREATE EXTENSION IF NOT EXISTS spock_origin;
        END IF;
END;$$;

DO $$
BEGIN
        IF version() ~ 'Postgres-XL' THEN
                CREATE EXTENSION IF NOT EXISTS spock;
        ELSE
                CREATE EXTENSION IF NOT EXISTS spock VERSION '1.0.0';
        END IF;
END;
$$;
ALTER EXTENSION spock UPDATE;

SELECT * FROM spock.create_node(node_name := 'test_orig_provider', dsn := (SELECT orig_provider_dsn FROM spock_regress_variables()) || ' user=super');

\c :provider_dsn
SET client_min_messages = 'warning';
-- test_provider spock node already exists here.

BEGIN;
SELECT * FROM spock.create_subscription(
    subscription_name := 'test_orig_subscription',
    provider_dsn := (SELECT orig_provider_dsn FROM spock_regress_variables()) || ' user=super',
	synchronize_structure := false,
	forward_origins := '{}');
COMMIT;

BEGIN;
SET LOCAL statement_timeout = '10s';
SELECT spock.wait_for_subscription_sync_complete('test_orig_subscription');
COMMIT;

SELECT subscription_name, status, provider_node, replication_sets, forward_origins FROM spock.show_subscription_status();

SELECT sync_kind, sync_subid, sync_nspname, sync_relname, sync_status IN ('y', 'r') FROM spock.local_sync_status ORDER BY 2,3,4;

-- Make sure we see the slot and active connection
\c :orig_provider_dsn
SELECT plugin, slot_type, active FROM pg_replication_slots;
SELECT count(*) FROM pg_stat_replication;

-- Table that replicates from top level provider to mid-level spock node.

\c :orig_provider_dsn

SELECT spock.replicate_ddl_command($$
	CREATE TABLE public.top_level_tbl (
		id serial primary key,
		other integer,
		data text,
		something interval
	);
$$);

SELECT * FROM spock.replication_set_add_table('default', 'top_level_tbl');
INSERT INTO top_level_tbl(other, data, something)
VALUES (5, 'foo', '1 minute'::interval),
       (4, 'bar', '12 weeks'::interval),
       (3, 'baz', '2 years 1 hour'::interval),
       (2, 'qux', '8 months 2 days'::interval),
       (1, NULL, NULL);

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :provider_dsn
SELECT id, other, data, something FROM top_level_tbl ORDER BY id;

-- Table that replicates from top level provider to mid-level spock node.
SELECT spock.replicate_ddl_command($$
	CREATE TABLE public.mid_level_tbl (
		id serial primary key,
		other integer,
		data text,
		something interval
	);
$$);

SELECT * FROM spock.replication_set_add_table('default', 'mid_level_tbl');
INSERT INTO mid_level_tbl(other, data, something)
VALUES (5, 'foo', '1 minute'::interval),
       (4, 'bar', '12 weeks'::interval),
       (3, 'baz', '2 years 1 hour'::interval),
       (2, 'qux', '8 months 2 days'::interval),
       (1, NULL, NULL);

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT id, other, data, something FROM mid_level_tbl ORDER BY id;

-- drop the tables
\c :orig_provider_dsn
\set VERBOSITY terse
SELECT spock.replicate_ddl_command($$
	DROP TABLE public.top_level_tbl CASCADE;
$$);

\c :provider_dsn
\set VERBOSITY terse
SELECT spock.replicate_ddl_command($$
	DROP TABLE public.mid_level_tbl CASCADE;
$$);

\c :provider_dsn
SELECT * FROM spock.drop_subscription('test_orig_subscription');

\c :orig_provider_dsn
SELECT * FROM spock.drop_node(node_name := 'test_orig_provider');

SELECT plugin, slot_type, active FROM pg_replication_slots;
SELECT count(*) FROM pg_stat_replication;
