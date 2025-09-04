-- row based filtering
SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn

-- Do not run for Postgres 18 or higher
SELECT current_setting('server_version_num') >= '180000' as is_pg18_or_higher \gset
\if :is_pg18_or_higher
	\q
\endif

-- testing volatile sampling function in row_filter
SELECT spock.replicate_ddl($$
	CREATE TABLE public.test_tablesample (id int primary key, name text) WITH (fillfactor=10);
$$);
-- use fillfactor so we don't have to load too much data to get multiple pages
INSERT INTO test_tablesample
  SELECT i, repeat(i::text, 200) FROM generate_series(0, 9) s(i);

create or replace function funcn_get_system_sample_count(integer, integer) returns bigint as
$$ (SELECT count(*) FROM test_tablesample TABLESAMPLE SYSTEM ($1) REPEATABLE ($2)); $$
language sql volatile;

create or replace function funcn_get_bernoulli_sample_count(integer, integer) returns bigint as
$$ (SELECT count(*) FROM test_tablesample TABLESAMPLE BERNOULLI ($1) REPEATABLE ($2)); $$
language sql volatile;

SELECT * FROM spock.repset_add_table('default', 'test_tablesample', false, row_filter := $rf$id > funcn_get_system_sample_count(100, 3) $rf$);
SELECT * FROM spock.repset_remove_table('default', 'test_tablesample');
SELECT * FROM spock.repset_add_table('default', 'test_tablesample', true, row_filter := $rf$id > funcn_get_bernoulli_sample_count(10, 0) $rf$);

SELECT * FROM test_tablesample ORDER BY id limit 5;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

BEGIN;
SET LOCAL statement_timeout = '10s';
SELECT spock.table_wait_for_sync('test_subscription', 'test_tablesample');
COMMIT;

SELECT sync_kind, sync_nspname, sync_relname, sync_status FROM spock.local_sync_status WHERE sync_relname = 'test_tablesample';

SELECT * FROM test_tablesample ORDER BY id limit 5;

\c :provider_dsn
\set VERBOSITY terse
DROP FUNCTION funcn_get_system_sample_count(integer, integer);
DROP FUNCTION funcn_get_bernoulli_sample_count(integer, integer);
SELECT spock.replicate_ddl($$
	DROP TABLE public.test_tablesample CASCADE;
$$);
