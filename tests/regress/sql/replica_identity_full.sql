-- REPLICA IDENTITY FULL helpers: spock.table_replica_identity_full(),
-- spock.repset_replica_identity_full() and spock.auto_replica_identity_full.
SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn

CREATE SCHEMA rif;
CREATE TABLE rif.t_pk (id int PRIMARY KEY, payload text);
CREATE TABLE rif.t_nopk (id int, payload text);
CREATE TABLE rif.t_part (id int, payload text, PRIMARY KEY (id))
	PARTITION BY RANGE (id);
CREATE TABLE rif.t_part_a PARTITION OF rif.t_part FOR VALUES FROM (0) TO (10);
CREATE TABLE rif.t_part_b PARTITION OF rif.t_part FOR VALUES FROM (10) TO (20);

CREATE VIEW rif.idents AS
	SELECT c.relname, c.relreplident
	  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
	 WHERE n.nspname = 'rif' AND c.relkind IN ('r', 'p');

-- Everything starts at DEFAULT.
SELECT * FROM rif.idents ORDER BY 1;

-- spock.table_replica_identity_full()
-- A PK table at DEFAULT is switched; the second call has nothing to do.
SELECT spock.table_replica_identity_full('rif.t_pk');
SELECT spock.table_replica_identity_full('rif.t_pk');

-- No PK: refused with a hint.
SELECT spock.table_replica_identity_full('rif.t_nopk');

-- A partitioned table: every leaf is switched, the parent is left alone,
-- because REPLICA IDENTITY never cascades in PostgreSQL and the leaves
-- hold the rows.
SELECT spock.table_replica_identity_full('rif.t_part');

-- The parent alone has nothing to alter.
SELECT spock.table_replica_identity_full('rif.t_part', include_partitions := false);

-- NULL input does nothing (STRICT).
SELECT spock.table_replica_identity_full(NULL) IS NULL AS is_null;

SELECT * FROM rif.idents ORDER BY 1;

-- spock.repset_replica_identity_full()
SELECT spock.repset_create('rif_upd') IS NOT NULL AS created;
SELECT spock.repset_create('rif_ins',
	replicate_update := false, replicate_delete := false) IS NOT NULL AS created;

CREATE TABLE rif.s1 (id int PRIMARY KEY, payload text);
CREATE TABLE rif.s2 (id int PRIMARY KEY, payload text);
CREATE TABLE rif.s3 (id int PRIMARY KEY, payload text);
CREATE TABLE rif.s4 (id int PRIMARY KEY, payload text);
ALTER TABLE rif.s4 REPLICA IDENTITY FULL;

SELECT spock.repset_add_table('rif_upd', 'rif.s1');
SELECT spock.repset_add_table('rif_upd', 'rif.s2');
SELECT spock.repset_add_table('rif_upd', 'rif.s3');
SELECT spock.repset_add_table('rif_upd', 'rif.s4');

-- Membership is not re-checked on DROP CONSTRAINT with auto-DDL off, so this
-- is how a table without a PK comes to sit in an UPDATE/DELETE set.
ALTER TABLE rif.s3 DROP CONSTRAINT s3_pkey;

-- s1 and s2 are switched, s3 is skipped with a warning, s4 was FULL already.
SELECT spock.repset_replica_identity_full('rif_upd');
-- Nothing left to do; the warning for s3 repeats.
SELECT spock.repset_replica_identity_full('rif_upd');

-- An insert-only set has no use for FULL.
SELECT spock.repset_replica_identity_full('rif_ins');
-- Unknown set.
SELECT spock.repset_replica_identity_full('rif_nosuch');
-- NULL does nothing (STRICT): no "all sets" form exists on purpose.
SELECT spock.repset_replica_identity_full(NULL) IS NULL AS is_null;

SELECT * FROM rif.idents WHERE relname LIKE 's_' ORDER BY 1;

-- spock.auto_replica_identity_full
-- Off by default: joining a set leaves the identity alone.
SHOW spock.auto_replica_identity_full;
CREATE TABLE rif.g_off (id int PRIMARY KEY, payload text);
SELECT spock.repset_add_table('rif_upd', 'rif.g_off');

SET spock.auto_replica_identity_full = on;

-- A DEFAULT PK table joining an UPDATE/DELETE set is switched.
CREATE TABLE rif.g_pk (id int PRIMARY KEY, payload text);
SELECT spock.repset_add_table('rif_upd', 'rif.g_pk');

-- A deliberate USING INDEX identity is left alone.
CREATE TABLE rif.g_idx (id int PRIMARY KEY, alt int NOT NULL);
CREATE UNIQUE INDEX g_idx_alt ON rif.g_idx (alt);
ALTER TABLE rif.g_idx REPLICA IDENTITY USING INDEX g_idx_alt;
SELECT spock.repset_add_table('rif_upd', 'rif.g_idx');

-- An insert-only set gets no identity change.
CREATE TABLE rif.g_ins (id int PRIMARY KEY, payload text);
SELECT spock.repset_add_table('rif_ins', 'rif.g_ins');

-- A table without a PK cannot join rif_upd at all, and is not touched on
-- the way out.
CREATE TABLE rif.g_nopk (id int, payload text);
SELECT spock.repset_add_table('rif_upd', 'rif.g_nopk');

-- Partitions are switched one by one; the parent is left alone.
CREATE TABLE rif.g_part (id int, payload text, PRIMARY KEY (id))
	PARTITION BY RANGE (id);
CREATE TABLE rif.g_part_a PARTITION OF rif.g_part FOR VALUES FROM (0) TO (10);
CREATE TABLE rif.g_part_b PARTITION OF rif.g_part FOR VALUES FROM (10) TO (20);
SELECT spock.repset_add_table('rif_upd', 'rif.g_part');

-- repset_add_all_tables() goes through the same path.
CREATE SCHEMA rif_all;
CREATE TABLE rif_all.a1 (id int PRIMARY KEY, payload text);
CREATE TABLE rif_all.a2 (id int PRIMARY KEY, payload text);
SELECT spock.repset_add_all_tables('rif_upd', '{rif_all}');

RESET spock.auto_replica_identity_full;

SELECT * FROM rif.idents WHERE relname LIKE 'g%' ORDER BY 1;
SELECT c.relname, c.relreplident
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'rif_all' ORDER BY 1;

-- Cleanup.
SELECT spock.repset_drop('rif_upd');
SELECT spock.repset_drop('rif_ins');
DROP VIEW rif.idents;
SET client_min_messages = warning;
DROP SCHEMA rif CASCADE;
DROP SCHEMA rif_all CASCADE;
RESET client_min_messages;
