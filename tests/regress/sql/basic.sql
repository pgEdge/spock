-- basic builtin datatypes
SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn
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

\c :subscriber_dsn

ALTER TABLE public.basic_dml ADD COLUMN subonly integer;
ALTER TABLE public.basic_dml ADD COLUMN subonly_def integer DEFAULT 99;

\c :provider_dsn

-- check basic insert replication
INSERT INTO basic_dml(other, data, something)
VALUES (5, 'foo', '1 minute'::interval),
       (4, 'bar', '12 weeks'::interval),
       (3, 'baz', '2 years 1 hour'::interval),
       (2, 'qux', '8 months 2 days'::interval),
       (1, NULL, NULL);
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
\c :subscriber_dsn
SELECT id, other, data, something, subonly, subonly_def FROM basic_dml ORDER BY id;

-- update one row
\c :provider_dsn
UPDATE basic_dml SET other = '4', data = NULL, something = '3 days'::interval WHERE id = 4;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
\c :subscriber_dsn
SELECT id, other, data, something FROM basic_dml ORDER BY id;

-- update multiple rows
\c :provider_dsn
UPDATE basic_dml SET other = id, data = data || id::text;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
\c :subscriber_dsn
SELECT id, other, data, something FROM basic_dml ORDER BY id;

\c :provider_dsn
UPDATE basic_dml SET other = id, something = something - '10 seconds'::interval WHERE id < 3;
UPDATE basic_dml SET other = id, something = something + '10 seconds'::interval WHERE id > 3;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
\c :subscriber_dsn
SELECT id, other, data, something, subonly, subonly_def FROM basic_dml ORDER BY id;

-- delete one row
\c :provider_dsn
DELETE FROM basic_dml WHERE id = 2;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
\c :subscriber_dsn
SELECT id, other, data, something FROM basic_dml ORDER BY id;

-- delete multiple rows
\c :provider_dsn
DELETE FROM basic_dml WHERE id < 4;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
\c :subscriber_dsn
SELECT id, other, data, something FROM basic_dml ORDER BY id;

-- truncate
\c :provider_dsn
TRUNCATE basic_dml;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
\c :subscriber_dsn
SELECT id, other, data, something FROM basic_dml ORDER BY id;

-- copy
\c :provider_dsn
\COPY basic_dml FROM STDIN WITH CSV
9000,1,aaa,1 hour
9001,2,bbb,2 years
9002,3,ccc,3 minutes
9003,4,ddd,4 days
\.
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
\c :subscriber_dsn
SELECT id, other, data, something FROM basic_dml ORDER BY id;

\c :provider_dsn
\set VERBOSITY terse
SELECT spock.replicate_ddl($$
	DROP TABLE public.basic_dml CASCADE;
$$);

SELECT '''' || provider_dsn || ' password=abc' || '''' AS fakecreds
FROM spock_regress_variables()
\gset

-- Check password will not be exposed
SELECT spock.sub_create(
  subscription_name := 'subscription1',
  provider_dsn := :fakecreds);

CREATE FUNCTION call_fn(creds text) RETURNS void AS $$
  SELECT spock.sub_create(
    subscription_name := 'subscription1',
    provider_dsn := creds);
$$ LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE;

SELECT call_fn(:fakecreds);

--
-- Check that spock-related commands aren't came to the queue.
--

SET spock.enable_ddl_replication = 'on';

CREATE EXTENSION IF NOT EXISTS spock;
COMMENT ON EXTENSION spock IS 'test comment';
ALTER EXTENSION spock ADD FUNCTION call_fn(creds text);

-- Zero records should be found here
SELECT count(*) FROM spock.queue WHERE message::text LIKE '%spock%';

RESET spock.enable_ddl_replication;