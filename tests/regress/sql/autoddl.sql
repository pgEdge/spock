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

-- CLUSTER without a table commits after every table it processes, and so
-- does CLUSTER on a partitioned table, one partition at a time.  Neither can
-- be replayed inside the apply worker's transaction: AutoDDL must warn and
-- leave them out of the queue, while CLUSTER on one plain table replicates.
-- The hook fires for the table-less form outside a transaction, which
-- AutoDDL has to handle.
CREATE TABLE test_380 (x serial PRIMARY KEY, y integer);
CREATE INDEX test_380_y_idx ON test_380 (y);
ALTER TABLE test_380 CLUSTER ON test_380_y_idx;
CLUSTER;
CLUSTER test_380;
CREATE TABLE test_380_part (x integer, y integer) PARTITION BY RANGE (x);
CREATE TABLE test_380_part1 PARTITION OF test_380_part
    FOR VALUES FROM (0) TO (100);
CREATE INDEX test_380_part_y_idx ON test_380_part (y);
CLUSTER test_380_part USING test_380_part_y_idx;

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

-- test_380 arrived with its clustered index and replication went on.
SELECT indisclustered FROM pg_index WHERE indexrelid = 'test_380_y_idx'::regclass;
SELECT status FROM spock.sub_show_status();

-- Reset the configuration to the default value
\c :provider_dsn
DROP TABLE test_380 CASCADE;
DROP TABLE test_380_part CASCADE;
ALTER SYSTEM SET spock.enable_ddl_replication = 'off';
ALTER SYSTEM SET spock.include_ddl_repset = 'off';
ALTER SYSTEM SET spock.allow_ddl_from_functions = 'off';
SELECT pg_reload_conf();
