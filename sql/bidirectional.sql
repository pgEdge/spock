
SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn
SELECT E'\'' || current_database() || E'\'' AS pubdb;
\gset

\c :provider_dsn
DO $$
BEGIN
	IF (SELECT setting::integer/100 FROM pg_settings WHERE name = 'server_version_num') = 904 THEN
		CREATE EXTENSION IF NOT EXISTS spock_origin;
	END IF;
END;$$;

SELECT * FROM spock.sub_create(
    subscription_name := 'test_bidirectional',
    provider_dsn := (SELECT subscriber_dsn FROM spock_regress_variables()) || ' user=super',
    synchronize_structure := false,
    synchronize_data := false,
    forward_origins := '{}');

BEGIN;
SET LOCAL statement_timeout = '10s';
SELECT spock.sub_wait_for_sync('test_bidirectional');
COMMIT;

\c :subscriber_dsn
SELECT spock.replicate_ddl($$
    CREATE TABLE public.basic_dml (
        id serial primary key,
        other integer,
        data text,
        something interval
    );
$$);

SELECT * FROM spock.repset_add_table('default', 'basic_dml');

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :provider_dsn

SELECT * FROM spock.repset_add_table('default', 'basic_dml');

-- check basic insert replication
INSERT INTO basic_dml(other, data, something)
VALUES (5, 'foo', '1 minute'::interval),
       (4, 'bar', '12 weeks'::interval),
       (3, 'baz', '2 years 1 hour'::interval),
       (2, 'qux', '8 months 2 days'::interval),
       (1, NULL, NULL);

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT id, other, data, something FROM basic_dml ORDER BY id;

UPDATE basic_dml SET other = id, something = something - '10 seconds'::interval WHERE id < 3;
UPDATE basic_dml SET other = id, something = something + '10 seconds'::interval WHERE id > 3;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :provider_dsn
SELECT id, other, data, something FROM basic_dml ORDER BY id;

\c :provider_dsn
\set VERBOSITY terse
SELECT spock.replicate_ddl($$
    DROP TABLE public.basic_dml CASCADE;
$$);

SELECT spock.sub_drop('test_bidirectional');

SET client_min_messages = 'warning';
DROP EXTENSION IF EXISTS spock_origin;

\c :subscriber_dsn
\a
SELECT slot_name FROM pg_replication_slots WHERE database = current_database();
SELECT count(*) FROM pg_stat_replication WHERE application_name = 'test_bidirectional';
