/* First test whether a table's replication set can be properly manipulated */
SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn

SELECT spock.replicate_ddl($$
CREATE SCHEMA normalschema;
CREATE SCHEMA "strange.schema-IS";
CREATE TABLE public.test_publicschema(id serial primary key, data text);
CREATE TABLE normalschema.test_normalschema(id serial primary key);
CREATE TABLE "strange.schema-IS".test_strangeschema(id serial primary key);
CREATE TABLE public.test_nopkey(id int);
CREATE UNLOGGED TABLE public.test_unlogged(id int primary key);
$$);

SELECT nspname, relname, set_name FROM spock.tables
 WHERE relname IN ('test_publicschema', 'test_normalschema', 'test_strangeschema', 'test_nopkey') ORDER BY 1,2,3;

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

-- show initial replication sets
SELECT nspname, relname, set_name FROM spock.tables
 WHERE relname IN ('test_publicschema', 'test_normalschema', 'test_strangeschema', 'test_nopkey') ORDER BY 1,2,3;

-- not existing replication set
SELECT * FROM spock.repset_add_table('nonexisting', 'test_publicschema');

-- create some replication sets
SELECT * FROM spock.repset_create('repset_replicate_all');
SELECT * FROM spock.repset_create('repset_replicate_instrunc', replicate_update := false, replicate_delete := false);
SELECT * FROM spock.repset_create('repset_replicate_insupd', replicate_delete := false, replicate_truncate := false);

-- add tables
SELECT * FROM spock.repset_add_table('repset_replicate_all', 'test_publicschema');
SELECT * FROM spock.repset_add_table('repset_replicate_instrunc', 'normalschema.test_normalschema');
SELECT * FROM spock.repset_add_table('repset_replicate_insupd', 'normalschema.test_normalschema');
SELECT * FROM spock.repset_add_table('repset_replicate_insupd', '"strange.schema-IS".test_strangeschema');

-- should fail
SELECT * FROM spock.repset_add_table('repset_replicate_all', 'test_unlogged');
SELECT * FROM spock.repset_add_table('repset_replicate_all', 'test_nopkey');
-- success
SELECT * FROM spock.repset_add_table('repset_replicate_instrunc', 'test_nopkey');
SELECT * FROM spock.repset_alter('repset_replicate_insupd', replicate_truncate := true);
-- fail again
SELECT * FROM spock.repset_add_table('repset_replicate_insupd', 'test_nopkey');
SELECT * FROM spock.repset_add_all_tables('default', '{public}');
SELECT * FROM spock.repset_alter('repset_replicate_instrunc', replicate_update := true);
SELECT * FROM spock.repset_alter('repset_replicate_instrunc', replicate_delete := true);

-- Adding already-added fails
\set VERBOSITY terse
SELECT * FROM spock.repset_add_table('repset_replicate_all', 'public.test_publicschema');
\set VERBOSITY default

-- check the replication sets
SELECT nspname, relname, set_name FROM spock.tables
 WHERE relname IN ('test_publicschema', 'test_normalschema', 'test_strangeschema', 'test_nopkey') ORDER BY 1,2,3;

SELECT * FROM spock.repset_add_all_tables('default_insert_only', '{public}');

SELECT nspname, relname, set_name FROM spock.tables
 WHERE relname IN ('test_publicschema', 'test_normalschema', 'test_strangeschema', 'test_nopkey') ORDER BY 1,2,3;

--too short
SELECT spock.repset_create('');

-- Can't drop table while it's in a repset
DROP TABLE public.test_publicschema;

-- Can't drop table while it's in a repset
BEGIN;
SELECT spock.replicate_ddl($$
DROP TABLE public.test_publicschema;
$$);
ROLLBACK;

-- Can CASCADE though, even outside ddlrep
BEGIN;
DROP TABLE public.test_publicschema CASCADE;
ROLLBACK;

-- ... and can drop after repset removal
SELECT spock.repset_remove_table('repset_replicate_all', 'public.test_publicschema');
SELECT spock.repset_remove_table('default_insert_only', 'public.test_publicschema');
BEGIN;
DROP TABLE public.test_publicschema;
ROLLBACK;

\set VERBOSITY terse
SELECT spock.replicate_ddl($$
	DROP TABLE public.test_publicschema CASCADE;
	DROP SCHEMA normalschema CASCADE;
	DROP SCHEMA "strange.schema-IS" CASCADE;
	DROP TABLE public.test_nopkey CASCADE;
	DROP TABLE public.test_unlogged CASCADE;
$$);

\c :subscriber_dsn
SELECT * FROM spock.replication_set;

-- Issue SPOC-102

-- Being on subscriber, set the exception behaviour to transdiscard
ALTER SYSTEM SET spock.exception_behaviour = 'transdiscard';
SELECT pg_reload_conf();

\c :provider_dsn

 -- Table spoc_102g must be on each node and inside the replication set.
SELECT spock.replicate_ddl('CREATE TABLE spoc_102g (x integer PRIMARY KEY);');
SELECT spock.repset_add_table('default', 'spoc_102g');

-- Must be disabled
SHOW spock.enable_ddl_replication;
SHOW spock.include_ddl_repset;

CREATE TABLE spoc_102l (x integer PRIMARY KEY); -- local for the publisher
INSERT INTO spoc_102l VALUES (1); -- Should be invisible for the subscriber node.
INSERT INTO spoc_102g VALUES (-1);
SELECT spock.repset_add_table('default', 'spoc_102l');
INSERT INTO spoc_102g VALUES (-2);
INSERT INTO spoc_102l VALUES (2); -- Should cause an error that will be just skipped
INSERT INTO spoc_102g VALUES (-3);
BEGIN; -- All its changes must be skipped
INSERT INTO spoc_102l VALUES (3);
INSERT INTO spoc_102g VALUES (-4); -- NOT replicated
END;
INSERT INTO spoc_102g VALUES (-5);

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
\c :subscriber_dsn
-- Check replication state before the problem fixation
SELECT * FROM spoc_102g ORDER BY x;
SELECT * FROM spoc_102l ORDER BY x; -- ERROR, does not exist yet

-- Now, fix the issue with absent table
BEGIN;
SELECT spock.repair_mode(true) \gset
CREATE TABLE spoc_102l (x integer PRIMARY KEY);
END;

-- Check that replication works
INSERT INTO spoc_102l VALUES (4);
-- XXX: Why we don't synchronize the state of the table and don't see rows
-- publisher has added before?
SELECT * FROM spoc_102l ORDER BY x;

-- Return to provider and check that it doesn't see value (4).
-- Afterwards, add value 5 that must be replicated
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
\c :provider_dsn
SELECT * FROM spoc_102l ORDER BY x;
INSERT INTO spoc_102l VALUES (5);

-- Re-check that subscription works properly
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
\c :subscriber_dsn
SELECT * FROM spoc_102l ORDER BY x;

--
-- Now, let's check the 'discard' mode
--

ALTER SYSTEM SET spock.exception_behaviour = 'discard';
SELECT pg_reload_conf();

\c :provider_dsn
TRUNCATE spoc_102g;
SELECT spock.replicate_ddl('DROP TABLE spoc_102l CASCADE');

CREATE TABLE spoc_102l (x integer PRIMARY KEY); -- local for the publisher
INSERT INTO spoc_102l VALUES (1);
INSERT INTO spoc_102g VALUES (-1);
SELECT spock.repset_add_table('default', 'spoc_102l');
INSERT INTO spoc_102g VALUES (-2);
INSERT INTO spoc_102l VALUES (2); -- table does not exist yet, skip
INSERT INTO spoc_102g VALUES (-3);
BEGIN; -- Skip INSERT to spoc_102l and apply INSERT to spoc_102g
INSERT INTO spoc_102l VALUES (3);
INSERT INTO spoc_102g VALUES (-4);
END;
INSERT INTO spoc_102g VALUES (-5);

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
\c :subscriber_dsn
-- Check replication state before the problem fixation
SELECT * FROM spoc_102g ORDER BY x;
SELECT * FROM spoc_102l ORDER BY x; -- ERROR, does not exist yet

-- Now, fix the issue with absent table. Use 'IF NOT EXISTS' hack to create
-- the table where it is absent.
\c :provider_dsn
SELECT spock.replicate_ddl('CREATE TABLE IF NOT EXISTS spoc_102l (x integer PRIMARY KEY)');
INSERT INTO spoc_102l VALUES (4);
INSERT INTO spoc_102g VALUES (-6);

SELECT spock.wait_slot_confirm_lsn(NULL, NULL); -- required after changes
\c :subscriber_dsn
SELECT * FROM spoc_102g ORDER BY x;
SELECT * FROM spoc_102l ORDER BY x;

-- Check exception log format
SELECT
  command_counter,table_schema,table_name,operation,
  remote_new_tup,
  -- Replace OIDs with <OID> placeholder for deterministic test output
  regexp_replace(
    regexp_replace(error_message,
      'oid \d+', 'oid <OID>', 'g'),
    'OID \d+', 'OID <OID>', 'g'
  ) AS error_message
FROM spock.exception_log
ORDER BY command_counter;

\c :provider_dsn
SELECT spock.replicate_ddl('DROP TABLE IF EXISTS spoc_102g,spoc_102l CASCADE');

--
-- UPDATE row of an absent relation
--

SELECT spock.replicate_ddl('CREATE TABLE spoc_102g_u (x integer PRIMARY KEY);');
SELECT spock.repset_add_table('default', 'spoc_102g_u');

CREATE TABLE spoc_102l_u (x integer PRIMARY KEY); -- local for the publisher
INSERT INTO spoc_102l_u VALUES (1);
INSERT INTO spoc_102g_u VALUES (-1), (0);
SELECT spock.repset_add_table('default', 'spoc_102l_u');
UPDATE spoc_102g_u SET x = -2 WHERE x = -1;
UPDATE spoc_102l_u SET x = 2 WHERE x = 1;
BEGIN;
UPDATE spoc_102l_u SET x = 3 WHERE x = 2;
UPDATE spoc_102g_u SET x = -3 WHERE x = -2;
END;
UPDATE spoc_102g_u SET x = 1 WHERE x = 0;

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
\c :subscriber_dsn
-- Check replication state before the problem fixation
SELECT * FROM spoc_102g_u ORDER BY x;
SELECT * FROM spoc_102l_u ORDER BY x; -- ERROR, does not exist yet

-- Now, fix the issue with absent table
\c :provider_dsn
SELECT spock.replicate_ddl('CREATE TABLE IF NOT EXISTS spoc_102l_u (x integer PRIMARY KEY)');
UPDATE spoc_102l_u SET x = -3 WHERE x = 3;
INSERT INTO spoc_102l_u VALUES (4);
UPDATE spoc_102l_u SET x = 5 WHERE x = 4;

-- Check that replication works
SELECT spock.wait_slot_confirm_lsn(NULL, NULL); -- required
\c :subscriber_dsn
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
SELECT * FROM spoc_102l_u ORDER BY x;
SELECT * FROM spoc_102g_u ORDER BY x;

SELECT
  command_counter,table_schema,table_name,operation,
  remote_new_tup,
  -- Replace OIDs with <OID> placeholder for deterministic test output
  regexp_replace(
    regexp_replace(error_message,
      'oid \d+', 'oid <OID>', 'g'),
    'OID \d+', 'OID <OID>', 'g'
  ) AS error_message
FROM spock.exception_log
ORDER BY command_counter;

\c :provider_dsn
SELECT spock.replicate_ddl('DROP TABLE IF EXISTS spoc_102g_u,spoc_102l_u CASCADE');

--
-- DELETE row from an absent relation
--

SELECT spock.replicate_ddl('CREATE TABLE spoc_102g_d (x integer PRIMARY KEY);');
SELECT spock.repset_add_table('default', 'spoc_102g_d');

CREATE TABLE spoc_102l_d (x integer PRIMARY KEY);
INSERT INTO spoc_102l_d VALUES (1), (2);
INSERT INTO spoc_102g_d VALUES (-1), (-2), (-3);
SELECT spock.repset_add_table('default', 'spoc_102l_d');
DELETE FROM spoc_102g_d WHERE x = -1;
DELETE FROM spoc_102l_d WHERE x = 1;
DELETE FROM spoc_102g_d WHERE x = -2;

-- Check the state of replication on the subscriber node
SELECT spock.wait_slot_confirm_lsn(NULL, NULL); -- required
\c :subscriber_dsn
SELECT * FROM spoc_102l_d ORDER BY x; -- ERROR, not existed yet.
SELECT * FROM spoc_102g_d ORDER BY x; -- See one record (-3).

-- Create table where needed
\c :provider_dsn
SELECT spock.replicate_ddl('CREATE TABLE IF NOT EXISTS spoc_102l_d (x integer PRIMARY KEY)');

-- Do something with tables to enable replication
INSERT INTO spoc_102g_d VALUES (-4), (-5);
INSERT INTO spoc_102l_d VALUES (3), (4);
UPDATE spoc_102g_d SET x = -6 WHERE x = -4;
UPDATE spoc_102l_d SET x = 5 WHERE x = 3;
DELETE FROM spoc_102g_d WHERE x = -3 OR x = -6;
DELETE FROM spoc_102l_d WHERE x = 1 OR x = 5;

-- Check the state of replication on the subscriber node
SELECT spock.wait_slot_confirm_lsn(NULL, NULL); -- required
\c :subscriber_dsn
SELECT * FROM spoc_102l_d ORDER BY x; -- See (4)
SELECT * FROM spoc_102g_d ORDER BY x; -- See (-5).

-- Cleanup
\c :provider_dsn
SELECT spock.replicate_ddl('DROP TABLE IF EXISTS spoc_102g_d,spoc_102l_d CASCADE');
