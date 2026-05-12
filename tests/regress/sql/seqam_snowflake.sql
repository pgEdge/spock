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
-- TODO: tests/regress/expected/seqam_snowflake.out needs to be generated
-- against a working patched build.  Run `make check TESTS=seqam_snowflake`
-- once, inspect the resulting `results/seqam_snowflake.out`, and commit
-- it under `expected/`.
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

-- Every snowflake value should decode to the configured node id, have
-- a counter and timestamp that match the on-the-wire layout, and be
-- greater than the previous value emitted by the same backend.
WITH s AS (
  SELECT nextval('sf_seq') AS v1, nextval('sf_seq') AS v2
)
SELECT v1 > 0                                     AS first_positive,
       v2 > v1                                    AS strictly_increasing,
       (spock.seq_snowflake_decode(v1)).node_id = 42 AS decoded_node_correct,
       (spock.seq_snowflake_decode(v1)).counter >= 0 AS counter_non_negative,
       (spock.seq_snowflake_decode(v1)).timestamp_ms > 0 AS ts_after_epoch
FROM s;

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

-- After revert to local, nextval() reads the heap-stored last_value.
-- Snowflake never wrote that field while it managed the sequence, so
-- the first stock value is the sequence's start (1 by default).  This
-- is what we test, not a magic "< 100" -- a future change to the
-- default start would otherwise make the test pass by accident.
SELECT nextval('sf_seq') AS local_value;
-- local_value must be small (definitely below 2^22, which is the
-- smallest possible snowflake value).
SELECT currval('sf_seq') < (1::bigint << 22) AS reverted_to_local;

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
