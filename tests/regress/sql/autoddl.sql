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

-- Reset the configuration to the default value
\c :provider_dsn
ALTER SYSTEM SET spock.enable_ddl_replication = 'off';
ALTER SYSTEM SET spock.include_ddl_repset = 'off';
ALTER SYSTEM SET spock.allow_ddl_from_functions = 'off';
SELECT pg_reload_conf();
