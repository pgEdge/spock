-- toast_divergence: catalog shape, GUC defaults, clear() and verify() on an
-- empty queue.  Detection itself needs two nodes and lives in TAP 053.
SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn

SHOW spock.toast_divergence_detection;
SHOW spock.toast_divergence_max_suspects;
SHOW spock.toast_divergence_stamps;
SHOW spock.toast_divergence_repair;
SHOW spock.toast_divergence_interval;
SHOW spock.toast_divergence_retry_interval;
SHOW spock.toast_divergence_conn_lifetime;
SHOW spock.toast_divergence_lock_timeout;
SHOW spock.toast_divergence_batch;
SHOW spock.toast_divergence_fetch_bytes;

SELECT column_name, data_type, is_nullable
  FROM information_schema.columns
 WHERE table_schema = 'spock' AND table_name = 'toast_suspect'
 ORDER BY ordinal_position;

SELECT conname, contype
  FROM pg_constraint
 WHERE conrelid = 'spock.toast_suspect'::regclass
 ORDER BY conname;

SELECT column_name
  FROM information_schema.columns
 WHERE table_schema = 'spock' AND table_name = 'toast_divergence'
 ORDER BY ordinal_position;

-- The queue is not replicated: it belongs to no replication set.
SELECT count(*) FROM spock.replication_set_table
 WHERE set_reloid = 'spock.toast_suspect'::regclass;

-- clear() on a row that is not there.
CREATE TABLE public.td_t (id int PRIMARY KEY, small text, big text);
SELECT spock.toast_divergence_clear('public.td_t', '{"id": "1"}');

-- A synthetic entry, visible through the view, then cleared.
INSERT INTO spock.toast_suspect
       (relid, pkey, attnums, winner_subid, winner_origin, winner_ts)
VALUES ('public.td_t'::regclass, '{"id": "1"}', '{3}', 0, 0, now());
SELECT schema_name, table_name, pkey, columns, state, detect_count
  FROM spock.toast_divergence;
SELECT spock.toast_divergence_clear('public.td_t', '{"id": "1"}');
SELECT count(*) FROM spock.toast_suspect;

-- The state check.
\set VERBOSITY terse
INSERT INTO spock.toast_suspect
       (relid, pkey, attnums, state, winner_subid, winner_origin, winner_ts)
VALUES ('public.td_t'::regclass, '{"id": "2"}', '{3}', 'bogus', 0, 0, now());

-- verify() on an empty queue does nothing and reports zeros.
SELECT * FROM spock.toast_divergence_verify();
SELECT * FROM spock.toast_divergence_verify(10);
-- An entry for a table that no longer exists is cleared.
CREATE TABLE public.td_gone (id int PRIMARY KEY, big text);
INSERT INTO spock.toast_suspect (relid, pkey, attnums, winner_subid, winner_origin, winner_ts)
VALUES ('public.td_gone'::regclass, '{"id": "1"}', '{2}', 0, 0, now());
DROP TABLE public.td_gone;
SELECT * FROM spock.toast_divergence_verify();
SELECT count(*) FROM spock.toast_suspect;

-- A renamed key column: the entry's key no longer names every column of the
-- table, so the entry is reported as failed rather than compared against
-- whatever row a partial key happens to match.
CREATE TABLE public.td_ck (a int, b int, big text, PRIMARY KEY (a, b));
INSERT INTO spock.toast_suspect (relid, pkey, attnums, winner_subid, winner_origin, winner_ts)
VALUES ('public.td_ck'::regclass, '{"a": "1", "b": "2"}', '{3}', 0, 0, now());
ALTER TABLE public.td_ck RENAME COLUMN b TO b2;
SELECT * FROM spock.toast_divergence_verify();
SELECT state, last_error, verified_at IS NOT NULL AS attempted
  FROM spock.toast_suspect
 WHERE relid = 'public.td_ck'::regclass;
SELECT spock.toast_divergence_clear('public.td_ck', '{"a": "1", "b": "2"}');
DROP TABLE public.td_ck;

DROP TABLE public.td_t;

-- spock.toast_stamp(): the version stamp of an out-of-line value, read from
-- the commit timestamp of the transaction that wrote its first chunk.
CREATE TABLE public.td_stamp (id int PRIMARY KEY, small text, big text);
ALTER TABLE public.td_stamp ALTER COLUMN big SET STORAGE EXTERNAL;
INSERT INTO public.td_stamp VALUES (1, 'a', repeat('x', 10000)), (2, 'b', 'short');
CREATE TEMP TABLE td_stamp0 AS SELECT id, spock.toast_stamp(big) AS s FROM public.td_stamp;
-- out of line: the local node, the writing transaction, the raw size (10000 + 4)
SELECT id, split_part(s, '/', 1)::oid = (SELECT node_id FROM spock.node_info()) AS local_node,
       split_part(s, '/', 3) AS rawsize FROM td_stamp0 WHERE id = 1;
-- inline and non-varlena: NULL
SELECT s IS NULL AS inline_null FROM td_stamp0 WHERE id = 2;
SELECT spock.toast_stamp(1) IS NULL AS int_null;
-- kept by an UPDATE leaving the column alone; changed by a rewrite of the same text
UPDATE public.td_stamp SET small = 'a2' WHERE id = 1;
SELECT spock.toast_stamp(big) = s AS same_after_update FROM public.td_stamp JOIN td_stamp0 USING (id) WHERE id = 1;
UPDATE public.td_stamp SET big = repeat('x', 10000) WHERE id = 1;
SELECT spock.toast_stamp(big) <> s AS new_after_rewrite FROM public.td_stamp JOIN td_stamp0 USING (id) WHERE id = 1;
-- a value written under the initial sync's stamp (origin session, epoch
-- timestamp) has no usable stamp
SELECT pg_replication_origin_create('td_stamp_sync') > 0 AS origin_created;
BEGIN;
SELECT pg_replication_origin_session_setup('td_stamp_sync');
SELECT pg_replication_origin_xact_setup('0/0', 'epoch');
UPDATE public.td_stamp SET big = repeat('y', 10000) WHERE id = 1;
COMMIT;
SELECT pg_replication_origin_session_reset();
SELECT spock.toast_stamp(big) IS NULL AS sync_stamp_null FROM public.td_stamp WHERE id = 1;
SELECT pg_replication_origin_drop('td_stamp_sync');
UPDATE public.td_stamp SET big = repeat('x', 10000) WHERE id = 1;
-- VACUUM FULL rewrites the chunks: still readable, never an error
VACUUM FULL public.td_stamp;
SELECT spock.toast_stamp(big) IS NOT NULL AS readable_after_vacuum_full FROM public.td_stamp WHERE id = 1;
DROP TABLE public.td_stamp;

-- The queue holds row keys and the functions read or change user tables,
-- so none is open to PUBLIC.  USAGE on the schema is granted so that each
-- object's own check is the one tested.
CREATE ROLE td_noaccess;
GRANT USAGE ON SCHEMA spock TO td_noaccess;
SET ROLE td_noaccess;
SELECT count(*) FROM spock.toast_suspect;
SELECT count(*) FROM spock.toast_divergence;
SELECT spock.toast_divergence_clear('pg_class', '{}');
SELECT * FROM spock.toast_divergence_verify();
SELECT * FROM spock.toast_read_as_owner('pg_class', 'SELECT 1', '{}', 0) AS t(x int);
RESET ROLE;
REVOKE USAGE ON SCHEMA spock FROM td_noaccess;
DROP ROLE td_noaccess;
