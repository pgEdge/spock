-- toast_divergence: catalog shape, GUC defaults and clear().  Detection
-- itself needs two nodes and lives in TAP 053.
SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn

SHOW spock.toast_divergence_detection;
SHOW spock.toast_divergence_max_suspects;

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

DROP TABLE public.td_t;

-- The queue holds row keys, so neither it, its view nor
-- spock.toast_divergence_clear() is open to PUBLIC.  USAGE on the schema is granted so that each
-- object's own check is the one tested.
CREATE ROLE td_noaccess;
GRANT USAGE ON SCHEMA spock TO td_noaccess;
SET ROLE td_noaccess;
SELECT count(*) FROM spock.toast_suspect;
SELECT count(*) FROM spock.toast_divergence;
SELECT spock.toast_divergence_clear('pg_class', '{}');
RESET ROLE;
REVOKE USAGE ON SCHEMA spock FROM td_noaccess;
DROP ROLE td_noaccess;
