SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn

SELECT * FROM spock.repset_create('parallel');

\c :subscriber_dsn

-- FIXME: The statment below is commented out temporarily.
-- SELECT * FROM spock.sub_create(
--     subscription_name := 'test_subscription_parallel',
--     provider_dsn := (SELECT provider_dsn FROM spock_regress_variables()) || ' user=super',
-- 	replication_sets := '{parallel,default}',
-- 	forward_origins := '{}',
-- 	synchronize_structure := false,
-- 	synchronize_data := false
-- );

SELECT * FROM spock.sub_create(
    subscription_name := 'test_subscription_parallel',
    provider_dsn := (SELECT provider_dsn FROM spock_regress_variables()) || ' user=super',
	replication_sets := '{parallel}',
	forward_origins := '{}',
	synchronize_structure := false,
	synchronize_data := false
);

BEGIN;
SET LOCAL statement_timeout = '10s';
SELECT spock.sub_wait_for_sync('test_subscription_parallel');
COMMIT;

SELECT sync_kind, sync_subid, sync_nspname, sync_relname, sync_status IN ('y', 'r') FROM spock.local_sync_status ORDER BY 2,3,4;

SELECT * FROM spock.sub_show_status();

-- Make sure we see the slot and active connection
\c :provider_dsn
SELECT plugin, slot_type, database, active FROM pg_replication_slots;
SELECT count(*) FROM pg_stat_replication;

SELECT spock.replicate_ddl($$
    CREATE TABLE public.basic_dml1 (
        id serial primary key,
        other integer,
        data text,
        something interval
    );
    CREATE TABLE public.basic_dml2 (
        id serial primary key,
        other integer,
        data text,
        something interval
    );
$$);

SELECT * FROM spock.repset_add_table('default', 'basic_dml1');
SELECT * FROM spock.repset_add_table('parallel', 'basic_dml2');

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

WITH one AS (
INSERT INTO basic_dml1(other, data, something)
VALUES (5, 'foo', '1 minute'::interval),
       (4, 'bar', '12 weeks'::interval),
       (3, 'baz', '2 years 1 hour'::interval),
       (2, 'qux', '8 months 2 days'::interval),
       (1, NULL, NULL)
RETURNING *
)
INSERT INTO basic_dml2 SELECT * FROM one;

BEGIN;
UPDATE basic_dml1 SET other = id, something = something - '10 seconds'::interval WHERE id < 3;
DELETE FROM basic_dml2 WHERE id < 3;
COMMIT;

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

SELECT * FROM basic_dml1;
SELECT * FROM basic_dml2;

\c :subscriber_dsn

SELECT * FROM basic_dml1;
SELECT * FROM basic_dml2;

SELECT spock.sub_drop('test_subscription_parallel');

\c :provider_dsn
\set VERBOSITY terse
SELECT * FROM spock.repset_drop('parallel');

SELECT spock.replicate_ddl($$
    DROP TABLE public.basic_dml1 CASCADE;
    DROP TABLE public.basic_dml2 CASCADE;
$$);
