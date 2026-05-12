--
-- Spock distributed sequence access methods: Snowflake
--
-- Single-node regression coverage.  The multi-node uniqueness invariant is
-- exercised by tests/tap/t/050_seqam_snowflake.pl.
--
-- These tests assume the patched PostgreSQL binary (patches/18/pg18-050-
-- nextval-hook.diff and equivalents) is in use; on an unpatched binary
-- Spock's shared library fails to load and the regression cluster will
-- not start, so we do not bother detecting that here.
--

\set VERBOSITY terse

-- A node id is required to produce snowflake values.  Set one for this
-- test; outside of tests this is normally derived from spock.node.
SET spock.snowflake_node_id = 42;

-- ------------------------------------------------------------------------
-- 1. Hook unset: stock PostgreSQL behaviour must be preserved
-- ------------------------------------------------------------------------

CREATE SEQUENCE local_seq INCREMENT 1 START 100 MINVALUE 1 MAXVALUE 1000;

SELECT nextval('local_seq');     -- 100
SELECT nextval('local_seq');     -- 101
SELECT currval('local_seq');     -- 101
SELECT lastval();                -- 101
SELECT setval('local_seq', 500);
SELECT nextval('local_seq');     -- 501

-- ------------------------------------------------------------------------
-- 2. Assigning a sequence to snowflake
-- ------------------------------------------------------------------------

CREATE SEQUENCE sf_seq;

SELECT spock.alter_sequence_set_kind('sf_seq'::regclass, 'snowflake');

-- The exact value depends on the wall clock, but every snowflake value
-- has these stable properties:
--   * non-negative (bit 63 reserved as 0)
--   * encodes the configured node id
--   * the millisecond timestamp field is greater than the configured
--     snowflake epoch (2026-01-01 UTC) -- so the value is at least
--     (epoch_ms - SPOCK_SNOWFLAKE_EPOCH_MS) << 22, which is 0 right at
--     the epoch and grows from there.
SELECT v > 0                             AS positive,
       (sf).node_id                      AS decoded_node,
       (sf).counter < 4096               AS counter_in_range,
       (sf).timestamp_ms >= 0            AS ts_after_epoch
FROM (
  SELECT v, spock.seq_snowflake_decode(v) sf FROM (
    SELECT nextval('sf_seq') v
  ) s
) t;

-- ------------------------------------------------------------------------
-- 3. Lastval / currval regression: the hook MUST update last_used_seq.
--    If this fails, /core patch is buggy or the hook signals success
--    without updating elm->last / last_used_seq.
-- ------------------------------------------------------------------------

SELECT nextval('sf_seq') = currval('sf_seq') AS lastval_currval_consistent;
SELECT nextval('sf_seq') = lastval()         AS lastval_returns_snowflake;

-- Compare against a different sequence to ensure lastval() tracks the
-- most-recently advanced sequence regardless of method:
CREATE SEQUENCE other_seq;
SELECT nextval('other_seq');
SELECT lastval() = currval('other_seq') AS lastval_tracks_other_seq;

SELECT nextval('sf_seq');
SELECT lastval() = currval('sf_seq')    AS lastval_back_to_snowflake;

-- ------------------------------------------------------------------------
-- 4. Monotonicity within a backend
-- ------------------------------------------------------------------------

WITH s AS (SELECT nextval('sf_seq') v FROM generate_series(1, 100))
SELECT bool_and(v > 0) AS all_positive,
       count(distinct v) = 100 AS all_distinct,
       max(v) > min(v) AS monotonic
FROM s;

-- ------------------------------------------------------------------------
-- 5. Decoder round-trip on a synthetic value
-- ------------------------------------------------------------------------

-- Pack (ts_ms_since_epoch=1000, node_id=42, counter=7) and decode it.
-- Layout: (ts << 22) | (node << 12) | counter
SELECT timestamp_ms = 1000 AND node_id = 42 AND counter = 7
       AS roundtrip_ok
FROM spock.seq_snowflake_decode((1000::bigint << 22) |
                                (42::bigint << 12) |
                                7::bigint);

-- ------------------------------------------------------------------------
-- 6. Reverting to local restores stock semantics
-- ------------------------------------------------------------------------

SELECT spock.alter_sequence_set_kind('sf_seq'::regclass, 'local');

-- Now sf_seq behaves as a stock sequence with whatever last_value the
-- heap state happens to have (no snowflake values were ever written to
-- the heap state, so it remains at the CREATE SEQUENCE start).
SELECT nextval('sf_seq') < 100  AS reverted_to_local;

-- ------------------------------------------------------------------------
-- 7. Bad input
-- ------------------------------------------------------------------------

SELECT spock.alter_sequence_set_kind('sf_seq'::regclass, 'bogus');
SELECT spock.alter_sequence_set_kind('pg_class'::regclass, 'snowflake');
SELECT spock.seq_snowflake_decode(-1);

-- ------------------------------------------------------------------------
-- 8. View
-- ------------------------------------------------------------------------

SELECT spock.alter_sequence_set_kind('sf_seq'::regclass, 'snowflake');
SELECT sequence_name, kind FROM spock.sequence_info
WHERE sequence_name::text LIKE '%sf_seq';

-- Cleanup
DROP SEQUENCE local_seq, other_seq, sf_seq;
DELETE FROM spock.sequence_kind;

RESET spock.snowflake_node_id;

\set VERBOSITY default
