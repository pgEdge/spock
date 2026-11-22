/* spock--6.0.0--6.1.0.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '6.1.0'" to load this file. \quit

-- ----------------------------------------------------------------------
-- TOAST divergence detection, verification and repair
-- ----------------------------------------------------------------------
-- Rows whose TOAST columns may have diverged from the node that won a
-- conflict.  Written by the apply worker (spock_toast_suspect_record()),
-- verified by spock.toast_divergence_verify().  Local to this node and
-- never replicated: it describes local state.
CREATE TABLE spock.toast_suspect (
    relid           oid          NOT NULL,
    pkey            jsonb        NOT NULL,
    attnums         int2[]       NOT NULL,
    state           text         NOT NULL DEFAULT 'suspect'
                    CHECK (state IN ('suspect', 'confirmed', 'remote_missing')),
    winner_subid    oid          NOT NULL,
    winner_origin   oid          NOT NULL,
    winner_ts       timestamptz  NOT NULL,
    local_origin    oid,
    local_ts        timestamptz,
    detect_count    integer      NOT NULL DEFAULT 1,
    detected_at     timestamptz  NOT NULL DEFAULT now(),
    verified_at     timestamptz,
    differing       int2[],
    last_error      text,
    -- Per entry of attnums, the version stamp the sender sent for that
    -- column (see spock.toast_stamp()), or NULL when it sent none.
    winner_stamps   text[],
    -- How sure detection was that the row differs: stamp_mismatch (the
    -- stamps or sizes differ; after a rewrite or initial sync on either node
    -- the values can still agree), no_local_stamp (the local version
    -- could not be read or compared) or no_stamp (the sender sent none).
    reason          text
                    CHECK (reason IN ('stamp_mismatch', 'no_local_stamp', 'no_stamp')),
    PRIMARY KEY (relid, pkey)
)
-- The queue churns: one insert per divergence detected, one delete when it
-- is cleared or repaired.  A low fillfactor keeps re-detection UPDATEs (which
-- touch only non-key columns) on the HOT path, and an aggressive, size-
-- independent autovacuum reclaims the dead tuples from deletes promptly.
WITH (fillfactor = 70,
      autovacuum_vacuum_scale_factor = 0.0, autovacuum_vacuum_threshold = 200,
      autovacuum_analyze_scale_factor = 0.0, autovacuum_analyze_threshold = 200);

CREATE VIEW spock.toast_divergence AS
SELECT n.nspname                AS schema_name,
       c.relname                AS table_name,
       s.pkey,
       (SELECT array_agg(a.attname ORDER BY a.attnum)
          FROM pg_attribute a
         WHERE a.attrelid = s.relid AND a.attnum = ANY (s.attnums))
                                AS columns,
       (SELECT array_agg(a.attname ORDER BY a.attnum)
          FROM pg_attribute a
         WHERE a.attrelid = s.relid AND a.attnum = ANY (s.differing))
                                AS differing_columns,
       s.state,
       sub.sub_name             AS winner_subscription,
       wn.node_name             AS winner_node,
       s.winner_ts,
       s.local_ts,
       s.detect_count,
       s.detected_at,
       s.verified_at,
       s.last_error,
       s.reason
  FROM spock.toast_suspect s
  JOIN pg_class c ON c.oid = s.relid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  LEFT JOIN spock.subscription sub ON sub.sub_id = s.winner_subid
  LEFT JOIN spock.node wn ON wn.node_id = sub.sub_origin;

-- The version stamp of a value stored out of line, as
-- 'nodeid/commit_ts_microseconds/rawsize', or NULL when it cannot be read.
CREATE FUNCTION spock.toast_stamp("any")
RETURNS text STRICT STABLE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_toast_stamp';

-- Remove one entry after repairing the row by other means.  The function
-- pins search_path, so an object another user created in a schema on the
-- caller's path is never called in place of a built-in one.
CREATE FUNCTION spock.toast_divergence_clear(relation regclass, pkey jsonb)
RETURNS boolean STRICT VOLATILE
SET search_path = pg_catalog, pg_temp
LANGUAGE sql AS $$
    WITH d AS (
        DELETE FROM spock.toast_suspect
         WHERE relid = $1 AND pkey = $2
        RETURNING 1)
    SELECT count(*) > 0 FROM d;
$$;
REVOKE ALL ON FUNCTION spock.toast_divergence_clear(regclass, jsonb) FROM PUBLIC;

-- Check pending suspects against the node that won: equal hashes clear the
-- entry, a difference confirms it, a row missing on the winner is marked
-- remote_missing.  Returns how many entries went each way.  The SET clauses
-- pin search_path, as clear() does, and text output so hashes match the
-- winner's; keep them in step with TOAST_SEARCH_PATH and toast_pinned_output
-- (spock_toast_internal.h and spock_toast_util.c) and PIN_OUTPUT_SETTINGS_SQL
-- in spock_toast_conn.c.
CREATE FUNCTION spock.toast_divergence_verify(max_rows integer DEFAULT 1000,
    OUT cleared integer, OUT confirmed integer,
    OUT remote_missing integer, OUT failed integer)
RETURNS record STRICT VOLATILE
SET search_path = pg_catalog, pg_temp
SET bytea_output = 'hex'
SET DateStyle = 'ISO, MDY'
SET IntervalStyle = 'postgres'
SET extra_float_digits = 3
SET TimeZone = 'UTC'
SET lc_monetary = 'C'
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_toast_divergence_verify';
REVOKE ALL ON FUNCTION spock.toast_divergence_verify(integer) FROM PUBLIC;

-- Runs the read of a table that another node's verify() or repair worker
-- sends here, as the table's owner, so code the owner defined (casts,
-- operators, row level security) does not run as the connecting role.  The
-- query runs under the same pinned search_path as the caller's own SQL.
CREATE FUNCTION spock.toast_read_as_owner(rel regclass, query text,
    param jsonb, nstamp integer)
RETURNS SETOF record VOLATILE STRICT
SET search_path = pg_catalog, pg_temp
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_toast_read_as_owner';
REVOKE ALL ON FUNCTION spock.toast_read_as_owner(regclass, text, jsonb, integer) FROM PUBLIC;

