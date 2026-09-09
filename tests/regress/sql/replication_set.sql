/* First test whether a table's replication set can be properly manipulated */
SELECT * FROM spock_regress_variables()
\gset

-- Cleanup in advance to make the test more stable
\c :subscriber_dsn
TRUNCATE spock.exception_log;
\c :provider_dsn
TRUNCATE spock.exception_log;

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

-- test_publicschema has landed in 'default' as well now; take it back out so
-- that the checks below see the same replication sets as before
SELECT spock.repset_remove_table('default', 'public.test_publicschema');
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

-- First time come by to the subscriber node. Clean the history in exception_log
TRUNCATE spock.exception_log;

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
  table_schema,table_name,operation,
  remote_new_tup,
  -- Replace OIDs with <OID> placeholder for deterministic test output
  regexp_replace(
    regexp_replace(error_message,
      'oid \d+', 'oid <OID>', 'g'),
    'OID \d+', 'OID <OID>', 'g'
  ) AS error_message
FROM spock.exception_log
ORDER BY table_schema COLLATE "C",table_name COLLATE "C",remote_commit_ts;

-- Check exception_log
SELECT table_schema, table_name, operation, remote_new_tup, error_message
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
  table_schema,table_name,operation,
  remote_new_tup,
  -- Replace OIDs with <OID> placeholder for deterministic test output
  regexp_replace(
    regexp_replace(error_message,
      'oid \d+', 'oid <OID>', 'g'),
    'OID \d+', 'OID <OID>', 'g'
  ) AS error_message
FROM spock.exception_log
ORDER BY table_schema COLLATE "C",table_name COLLATE "C",remote_commit_ts;

-- Check exception_log
SELECT table_schema, table_name, operation, remote_new_tup, error_message
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

--
-- What does spock.repset_add_all_tables() collect, and what does it leave behind?
--
\set VERBOSITY default

CREATE SCHEMA spoc410_ok;
CREATE SCHEMA spoc410_r1;
CREATE SCHEMA spoc410_r2;
CREATE SCHEMA spoc410_r3;
CREATE SCHEMA spoc410_r4;

-- accepted: single-column PRIMARY KEY, REPLICA IDENTITY DEFAULT
CREATE TABLE spoc410_ok.t_pk (id int PRIMARY KEY, payload text);

-- accepted: composite PRIMARY KEY
CREATE TABLE spoc410_ok.t_pk_multi (a int, b text, payload text,
	PRIMARY KEY (a, b));

-- accepted: custom identity -- a unique index over NOT NULL columns
CREATE TABLE spoc410_ok.t_using_index (a int NOT NULL, b int NOT NULL,
	payload text);
CREATE UNIQUE INDEX t_using_index_ri ON spoc410_ok.t_using_index (a, b);
ALTER TABLE spoc410_ok.t_using_index REPLICA IDENTITY USING INDEX t_using_index_ri;

-- accepted: the partitioned table AND every partition of it.  Partitions are
-- plain 'r' relations, so they are collected one by one, in their own right.
CREATE TABLE spoc410_ok.t_part (id int, ts date, PRIMARY KEY (id, ts))
	PARTITION BY RANGE (ts);
CREATE TABLE spoc410_ok.t_part_2025 PARTITION OF spoc410_ok.t_part
	FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
CREATE TABLE spoc410_ok.t_part_2026 PARTITION OF spoc410_ok.t_part
	FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');

-- never collected: wrong relkind, or not permanent
CREATE VIEW spoc410_ok.v_view AS SELECT * FROM spoc410_ok.t_pk;
CREATE MATERIALIZED VIEW spoc410_ok.m_matview AS SELECT * FROM spoc410_ok.t_pk;
CREATE SEQUENCE spoc410_ok.s_seq;
CREATE UNLOGGED TABLE spoc410_ok.u_unlogged (id int PRIMARY KEY);

-- skipped: a UNIQUE NOT NULL index is not enough, the identity is still
-- DEFAULT and there is no PRIMARY KEY for DEFAULT to point at
CREATE TABLE spoc410_r1.t_unique_no_pk (id int NOT NULL UNIQUE, payload text);

-- skipped: REPLICA IDENTITY FULL is not an index
CREATE TABLE spoc410_r2.t_full (id int NOT NULL, payload text);
ALTER TABLE spoc410_r2.t_full REPLICA IDENTITY FULL;

-- skipped: PRIMARY KEY present, but the identity is switched off
CREATE TABLE spoc410_r3.t_nothing (id int PRIMARY KEY, payload text);
ALTER TABLE spoc410_r3.t_nothing REPLICA IDENTITY NOTHING;

-- skipped: no identity of any kind
CREATE TABLE spoc410_r4.t_no_identity (id int, payload text);

-- Reports the replica identity of every relation of the test schemas, plus
-- the replication sets it belongs to.  identity_index is exactly what the
-- relcache would put into rd_replidindex, i.e. NULL means "this table cannot be
-- replicated by a set that replicates UPDATEs or DELETEs".
CREATE VIEW public.spoc410_state AS
	SELECT n.nspname, c.relname, c.relkind, c.relpersistence, c.relreplident,
		   CASE c.relreplident
			   WHEN 'd' THEN (SELECT i.indexrelid::regclass::text
								FROM pg_index i
							   WHERE i.indrelid = c.oid AND i.indisprimary)
			   WHEN 'i' THEN (SELECT i.indexrelid::regclass::text
								FROM pg_index i
							   WHERE i.indrelid = c.oid AND i.indisreplident)
		   END AS identity_index,
		   s.set_name
	  FROM pg_class c
		   JOIN pg_namespace n ON n.oid = c.relnamespace
		   LEFT JOIN (SELECT t.set_reloid, r.set_name
						FROM spock.replication_set_table t
							 JOIN spock.replication_set r ON r.set_id = t.set_id
							 JOIN spock.local_node l ON l.node_id = r.set_nodeid)
			 AS s ON s.set_reloid = c.oid
	 WHERE n.nspname LIKE 'spoc410\_%'
	   AND c.relkind IN ('r', 'p', 'v', 'm', 'S');

-- Which relations repset_add_all_tables() will even consider
SELECT nspname, relname, relkind, relpersistence,
	   (relkind IN ('r', 'p') AND relpersistence = 'p') AS candidate
  FROM public.spoc410_state
 ORDER BY nspname, relname;

-- The identity matrix of those candidates.  An empty identity_index is what
-- makes the table unreplicatable.
SELECT nspname, relname, relreplident, identity_index
  FROM public.spoc410_state
 WHERE relkind IN ('r', 'p') AND relpersistence = 'p'
 ORDER BY nspname, relname;

-- A replication set with the default flags replicates UPDATEs and DELETEs, so
-- the identity requirement is in force.  One call over all five schemas: the
-- four unreplicatable tables are named and skipped, everything else is added.
SELECT spock.repset_create('spoc410_upd') IS NOT NULL AS created;

SELECT spock.repset_add_all_tables('spoc410_upd',
	'{spoc410_ok,spoc410_r1,spoc410_r2,spoc410_r3,spoc410_r4}');

-- The well-identified tables of spoc410_ok are in -- including the partitioned
-- parent and each of its partitions as a member of its own.
SELECT set_name, nspname, relname, relkind
  FROM public.spoc410_state
 WHERE set_name IS NOT NULL
 ORDER BY set_name, nspname, relname;

-- An INSERT-only replication set never has to identify a row, so the identity
-- of the table is irrelevant and every candidate is collected, silently.
SELECT spock.repset_create('spoc410_ins',
	replicate_update := false, replicate_delete := false) IS NOT NULL AS created;

SELECT spock.repset_add_all_tables('spoc410_ins',
	'{spoc410_ok,spoc410_r1,spoc410_r2,spoc410_r3,spoc410_r4}');

SELECT set_name, nspname, relname, relkind
  FROM public.spoc410_state
 WHERE set_name IS NOT NULL
 ORDER BY set_name, nspname, relname;

-- Repeating a call costs nothing for the tables that are already members, so
-- there is no duplicate key failure.  A skipped table never became a member
-- though, so it is considered again -- and warned about again.
SELECT spock.repset_add_all_tables('spoc410_ins',
	'{spoc410_ok,spoc410_r1,spoc410_r2,spoc410_r3,spoc410_r4}');

SELECT spock.repset_add_all_tables('spoc410_upd',
	'{spoc410_ok,spoc410_r1,spoc410_r2,spoc410_r3,spoc410_r4}');

SELECT set_name, count(*) AS members
  FROM public.spoc410_state
 WHERE set_name IS NOT NULL
 GROUP BY set_name ORDER BY set_name;

-- ... and a set filled that way still cannot be promoted to replicate UPDATEs
-- or DELETEs.
SELECT spock.repset_alter('spoc410_ins', replicate_update := true);

-- spock.repset_add_table() is unaffected by all this: asked for one table by
-- name, it still refuses rather than silently doing nothing.
SELECT spock.repset_add_table('spoc410_upd', 'spoc410_r1.t_unique_no_pk');

-- Now give each skipped table an index-based identity.  r1 only needs its
-- existing unique index promoted.
ALTER TABLE spoc410_r1.t_unique_no_pk
	REPLICA IDENTITY USING INDEX t_unique_no_pk_id_key;

-- r2: adding a PRIMARY KEY makes the FULL table admissible.  The whole old
-- row is WAL-logged for UPDATEs and the PRIMARY KEY serves for row lookup.
ALTER TABLE spoc410_r2.t_full ADD PRIMARY KEY (id);

SELECT spock.repset_add_all_tables('spoc410_upd', '{spoc410_r2}');

ALTER TABLE spoc410_r2.t_full REPLICA IDENTITY DEFAULT;

-- r3 had a PRIMARY KEY all along, only the identity was switched off
ALTER TABLE spoc410_r3.t_nothing REPLICA IDENTITY DEFAULT;

-- r4 genuinely had nothing to identify a row by
ALTER TABLE spoc410_r4.t_no_identity ADD PRIMARY KEY (id);

-- With every table replicatable the same call warns about nothing
SELECT spock.repset_add_all_tables('spoc410_upd',
	'{spoc410_r1,spoc410_r2,spoc410_r3,spoc410_r4}');

SELECT DISTINCT nspname, relname, relreplident, identity_index
  FROM public.spoc410_state
 WHERE nspname <> 'spoc410_ok'
 ORDER BY nspname, relname;

SELECT set_name, count(*) AS members
  FROM public.spoc410_state
 WHERE set_name IS NOT NULL
 GROUP BY set_name ORDER BY set_name;

-- A schema that does not exist is still an error, not a skip
SELECT spock.repset_add_all_tables('spoc410_ins', '{spoc410_nosuch}');

-- Cleanup.  Drop the replication sets first so that dropping the schemas does
-- not have to cascade through the memberships.
SELECT spock.repset_drop('spoc410_upd');

SELECT spock.repset_drop('spoc410_ins');

DROP VIEW public.spoc410_state;
-- the cascade notice just lists the schema contents, keep it out of the output
SET client_min_messages = warning;
DROP SCHEMA spoc410_ok, spoc410_r1, spoc410_r2, spoc410_r3, spoc410_r4 CASCADE;
RESET client_min_messages;

--
-- Check: one table that does not satisfy replication restrictions must not cost
-- the caller the whole schema

CREATE SCHEMA spoc410_mix;
-- a_pk sorts before m_orphan and z_pk after it, so this also shows that the
-- scan carries on past the table it skips
CREATE TABLE spoc410_mix.a_pk (id int PRIMARY KEY, payload text);
CREATE TABLE spoc410_mix.m_orphan (id int, payload text);
CREATE TABLE spoc410_mix.z_pk (id int PRIMARY KEY, payload text);

-- Reports the members of the sets built below.
CREATE VIEW public.spoc410_members AS
	SELECT r.set_name, n.nspname, c.relname
	  FROM spock.replication_set_table t
		   JOIN spock.replication_set r ON r.set_id = t.set_id
		   JOIN spock.local_node l ON l.node_id = r.set_nodeid
		   JOIN pg_class c ON c.oid = t.set_reloid
		   JOIN pg_namespace n ON n.oid = c.relnamespace
	 WHERE n.nspname = 'spoc410_mix';

SELECT spock.repset_create('spoc410_mix_upd') IS NOT NULL AS created;

SELECT spock.repset_add_all_tables('spoc410_mix_upd', '{spoc410_mix}');

-- a_pk and z_pk are in, only m_orphan stayed out
SELECT set_name, nspname, relname FROM public.spoc410_members
 ORDER BY 1, 2, 3;

-- The same schema named twice must not turn into a duplicate key failure, and
-- must not report the same relation twice either.
SELECT spock.repset_add_all_tables('spoc410_mix_upd',
	'{spoc410_mix,spoc410_mix}');

SELECT set_name, nspname, relname FROM public.spoc410_members
 ORDER BY 1, 2, 3;

-- Naming that same table explicitly is still an error: the caller asked for
-- this one table, so silently doing nothing would be worse than failing.
SELECT spock.repset_add_table('spoc410_mix_upd', 'spoc410_mix.m_orphan');

-- A schema no replication set may draw from is reported once and passed over,
-- not once per relation it holds.
SELECT spock.repset_add_all_tables('spoc410_mix_upd', '{spock}');

-- The requirement belongs to the replication set, not to the routine: an
-- INSERT-only set never has to identify a row, so m_orphan goes in too.
SELECT spock.repset_create('spoc410_mix_ins',
	replicate_update := false, replicate_delete := false) IS NOT NULL AS created;

SELECT spock.repset_add_all_tables('spoc410_mix_ins', '{spoc410_mix}');

SELECT set_name, nspname, relname FROM public.spoc410_members
 ORDER BY 1, 2, 3;

-- Give m_orphan a PRIMARY KEY and a later call picks it up, without touching
-- the members already there.
ALTER TABLE spoc410_mix.m_orphan ADD PRIMARY KEY (id);

SELECT spock.repset_add_all_tables('spoc410_mix_upd', '{spoc410_mix}');

SELECT set_name, nspname, relname FROM public.spoc410_members
 ORDER BY 1, 2, 3;

-- Every table of the schema is replicatable by now, so the only thing the next
-- call reports is the failure itself.  Schemas are resolved one at a time, as
-- the loop reaches them: spoc410_mix is scanned and all of it added to the
-- fresh set before the second name is looked up and fails.  Everything the
-- routine writes is an ordinary catalog insert, so that work goes with it.
SELECT spock.repset_create('spoc410_mix_err') IS NOT NULL AS created;

SELECT spock.repset_add_all_tables('spoc410_mix_err',
	'{spoc410_mix,nosuchschema}');

-- ... and the set is left empty, not half full
SELECT count(*) AS members FROM public.spoc410_members
 WHERE set_name = 'spoc410_mix_err';

-- Same for a relation of an extension no replication set may draw from.
CREATE TABLE spoc410_mix.e_ext (id int PRIMARY KEY, payload text);
ALTER EXTENSION spock ADD TABLE spoc410_mix.e_ext;

SELECT spock.repset_add_all_tables('spoc410_mix_upd', '{spoc410_mix}');

SELECT set_name, nspname, relname FROM public.spoc410_members
 ORDER BY 1, 2, 3;

ALTER EXTENSION spock DROP TABLE spoc410_mix.e_ext;

SELECT spock.repset_drop('spoc410_mix_err');

SELECT spock.repset_drop('spoc410_mix_upd');

SELECT spock.repset_drop('spoc410_mix_ins');

DROP VIEW public.spoc410_members;
SET client_min_messages = warning;
DROP SCHEMA spoc410_mix CASCADE;
RESET client_min_messages;
