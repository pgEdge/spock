SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn
SELECT * FROM spock.node_drop(node_name := 'test_provider');

SELECT plugin, slot_type, active FROM pg_replication_slots;
SELECT count(*) FROM pg_stat_replication;

\c :subscriber_dsn
SELECT * FROM spock.sub_drop('test_subscription');
SELECT * FROM spock.node_drop(node_name := 'test_subscriber');

\c :provider_dsn

-- Check corner-case of wait function when no replication slots exist.
SELECT slot_name FROM pg_replication_slots; -- must be empty
SET statement_timeout = '100ms';
SELECT spock.wait_slot_confirm_lsn(NULL, NULL); -- trigger the statement_timeout ERROR

SELECT * FROM spock.node_drop(node_name := 'test_provider');

\c :subscriber_dsn
DROP OWNED BY nonsuper, super CASCADE;

\c :provider_dsn
DROP OWNED BY nonsuper, super CASCADE;

\c :provider1_dsn
DROP OWNED BY nonsuper, super CASCADE;

\c :orig_provider_dsn
DROP OWNED BY nonsuper, super CASCADE;

\c :subscriber_dsn
SET client_min_messages = 'warning';
DROP ROLE IF EXISTS nonsuper, super;

\c :provider_dsn
SET client_min_messages = 'warning';
DROP ROLE IF EXISTS nonsuper, super;

\c :provider1_dsn
SET client_min_messages = 'warning';
DROP ROLE IF EXISTS nonsuper, super;

\c :orig_provider_dsn
SET client_min_messages = 'warning';
DROP ROLE IF EXISTS nonsuper, super;
