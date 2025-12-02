--Tuple Origin
SELECT * FROM spock_regress_variables()
\gset

-- This is to ensure that the test runs with the correct configuration
\c :provider_dsn
ALTER SYSTEM SET spock.enable_ddl_replication = 'on';
ALTER SYSTEM SET spock.include_ddl_repset = 'on';
ALTER SYSTEM SET spock.allow_ddl_from_functions = 'on';
SELECT pg_reload_conf();

\c :provider_dsn

-- Create schema with tables on provider (node 1)
CREATE SCHEMA hollywood
    CREATE TABLE films (title text, release date, awards text[])
    CREATE TABLE shorts (title text, release date, awards text[]);

-- Create a test table on provider (node 1)
CREATE TABLE test1 (id int primary key, name text);

-- Create a function that creates two tables when called on provider (node 1)
CREATE FUNCTION auto_ddl_test() RETURNS void AS $func$
BEGIN
    EXECUTE 'CREATE TABLE test2 (id int primary key, name text)';
    EXECUTE 'CREATE TABLE test3 (id int primary key, name text)';
END;
$func$ LANGUAGE plpgsql;

-- Call function to create tables test2 and test3
SELECT auto_ddl_test();
INSERT INTO test1 VALUES (1, 'one'), (2, 'two');

-- Generate a sync event
SELECT spock.sync_event() as sync_event
\gset

\c :subscriber_dsn

-- Wait for sync event to be processed on subscriber (node 2)
CALL spock.wait_for_sync_event(true, 'test_provider', :'sync_event');

-- Check schema, table and function appear on subscriber (node 2)
SELECT count(*) FROM spock.tables where nspname = 'hollywood' AND set_name IS NOT NULL;
SELECT count(*) FROM spock.tables where relname = 'test1' AND set_name IS NOT NULL;
SELECT count(*) FROM spock.tables where (relname = 'test2' or relname = 'test3') AND set_name IS NOT NULL;

\c :provider_dsn

-- auto-ddl and transaction state: check that auto-ddl initiates a new
-- transaction if it is not inside one.
CREATE TABLE test_380 (x serial PRIMARY KEY, y integer);
CREATE INDEX test_380_y_idx ON test_380 (y);
ALTER TABLE test_380 CLUSTER ON test_380_y_idx;
CLUSTER; -- Do not replicate
CLUSTER test_380 USING test_380_y_idx; -- Replicate
DROP TABLE test_380 CASCADE;

-- CLUSTER on partitioned table can't be performed inside a transaction.
-- Check this special use case.
CREATE TABLE test_383 (a int) PARTITION BY RANGE (a);
CREATE TABLE test_383_1 PARTITION OF clstrpart FOR VALUES FROM (1) TO (10);
CREATE TABLE test_383_2 PARTITION OF clstrpart1 FOR VALUES FROM (1) TO (5);
CREATE INDEX test_383_y_idx ON test_383 (a);
CLUSTER test_383 USING test_383_y_idx; -- Should not be replicated
DROP TABLE test_383 CASCADE;

\c :provider_dsn
\set VERBOSITY terse
-- Check propagation of security labels
CREATE TABLE slabel1 (x integer NOT NULL, y text PRIMARY KEY);

SELECT spock.delta_apply('slabel1', 'x');
SELECT spock.delta_apply('slabel1', 'y'); -- ERROR
SELECT spock.delta_apply('slabel1', 'z'); -- ERROR
SELECT spock.delta_apply('slabel1', 'x'); -- repeating call do nothing
SELECT objname, label FROM pg_seclabels;

-- Short round trip to check that subscriber has the security label
\c :subscriber_dsn
SELECT objname, label FROM pg_seclabels;
\c :provider_dsn

SELECT spock.delta_apply('slabel1', 'x', true);
-- Short round trip to check that subscriber has removed the security label too
\c :subscriber_dsn
SELECT objname, label FROM pg_seclabels;
\c :provider_dsn

-- Reset the configuration to the default value
ALTER SYSTEM SET spock.enable_ddl_replication = 'off';
ALTER SYSTEM SET spock.include_ddl_repset = 'off';
ALTER SYSTEM SET spock.allow_ddl_from_functions = 'off';
SELECT pg_reload_conf();
